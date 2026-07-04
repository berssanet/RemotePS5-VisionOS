import Foundation
import Network
import CryptoKit

// MARK: - PSN WebSocket Service
/// Manages WebSocket connection for PSN push notifications (required before session creation)
/// Uses manual WebSocket handshake over NWConnection for full header control
@MainActor
class PSNWebSocketService: NSObject, ObservableObject {
    static let shared = PSNWebSocketService()
    
    @Published var isConnected = false
    @Published var error: String?
    
    private var connection: NWConnection?
    private var pushContextId: String = ""
    private var receiveTask: Task<Void, Never>?
    
    // Shared URLSession with cookie storage to emulate chiaki-ng's CURLOPT_SHARE
    private lazy var sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()
    
    // Store cookies from FQDN request to forward to WebSocket
    private var sessionCookies: [HTTPCookie] = []
    
    // API Endpoints (from chiaki-ng)
    private static let fqdnAPIURL = "https://mobile-pushcl.np.communication.playstation.net/np/serveraddr?version=2.1&fields=keepAliveStatus&keepAliveStatusType=3"
    
    // Notification callbacks
    var onSessionCreated: ((String) -> Void)?
    var onMemberCreated: (() -> Void)?
    var onSessionMessage: (([String: Any]) -> Void)?
    var onDisconnected: (() -> Void)?
    
    override init() {
        super.init()
        pushContextId = UUID().uuidString.lowercased()
    }
    
    // MARK: - Public Methods
    
    var currentPushContextId: String {
        return pushContextId
    }
    
    /// Connect to PSN WebSocket for push notifications
    func connect(accessToken: String) async throws {
        DebugLog.print("[PSNWebSocket] Starting WebSocket connection...")
        
        // Step 1: Get WebSocket FQDN
        let fqdn = try await getWebSocketFQDN(accessToken: accessToken)
        DebugLog.print("[PSNWebSocket] Got FQDN: \(fqdn)")
        
        // Step 2: Connect to WebSocket with manual handshake
        try await connectWebSocket(fqdn: fqdn, accessToken: accessToken)
    }
    
    /// Disconnect WebSocket
    func disconnect() {
        receiveTask?.cancel()
        connection?.cancel()
        connection = nil
        isConnected = false
        DebugLog.print("[PSNWebSocket] Disconnected")
    }
    
    // MARK: - Private Methods
    
    /// Get WebSocket FQDN from PSN API (uses shared session for cookie sharing)
    private func getWebSocketFQDN(accessToken: String) async throws -> String {
        guard let url = URL(string: Self.fqdnAPIURL) else {
            throw PSNWebSocketError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // chiaki-ng only sends Authorization header for FQDN request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        DebugLog.print("[PSNWebSocket] Fetching FQDN from: \(Self.fqdnAPIURL)")
        
        // Use shared session to maintain cookies (like chiaki-ng's CURLOPT_SHARE)
        let (data, response) = try await sharedSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNWebSocketError.invalidResponse
        }
        
        DebugLog.print("[PSNWebSocket] FQDN API status: \(httpResponse.statusCode)")
        
        // Capture cookies from the response
        if let headerFields = httpResponse.allHeaderFields as? [String: String] {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            sessionCookies.append(contentsOf: cookies)
            DebugLog.print("[PSNWebSocket] Captured \(cookies.count) cookies from FQDN response")
            for cookie in cookies {
                DebugLog.print("[PSNWebSocket]   Cookie: \(cookie.name)=\(cookie.value.prefix(20))...")
            }
        }
        
        // Also get cookies from shared storage
        if let storedCookies = HTTPCookieStorage.shared.cookies(for: url) {
            for cookie in storedCookies where !sessionCookies.contains(where: { $0.name == cookie.name }) {
                sessionCookies.append(cookie)
            }
            DebugLog.print("[PSNWebSocket] Total cookies in storage: \(storedCookies.count)")
        }
        
        if let responseStr = String(data: data, encoding: .utf8) {
            DebugLog.print("[PSNWebSocket] FQDN response: \(responseStr)")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw PSNWebSocketError.fqdnFetchFailed(httpResponse.statusCode)
        }
        
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fqdn = json["fqdn"] as? String else {
            throw PSNWebSocketError.invalidFQDNResponse
        }
        
        return fqdn
    }
    
    /// Connect to WebSocket using manual HTTP handshake for full header control
    private func connectWebSocket(fqdn: String, accessToken: String) async throws {
        let wsPath = "/np/pushNotification"
        
        DebugLog.print("[PSNWebSocket] Connecting to: wss://\(fqdn)\(wsPath)")
        
        // Create TLS parameters
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        
        // Create endpoint
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(fqdn),
            port: .https
        )
        
        // Create raw TCP+TLS connection (no WebSocket protocol layer)
        let conn = NWConnection(to: endpoint, using: parameters)
        self.connection = conn
        
        // Wait for connection to be ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    DebugLog.print("[PSNWebSocket] TCP+TLS connection ready")
                    if gate.tryResume() {
                        continuation.resume()
                    }

                case .failed(let error):
                    DebugLog.print("[PSNWebSocket] ❌ Connection failed: \(error)")
                    if gate.tryResume() {
                        continuation.resume(throwing: PSNWebSocketError.connectionFailed(error.localizedDescription))
                    }

                case .cancelled:
                    if gate.tryResume() {
                        continuation.resume(throwing: PSNWebSocketError.connectionFailed("Connection cancelled"))
                    }

                case .waiting(let error):
                    DebugLog.print("[PSNWebSocket] Waiting: \(error)")

                case .preparing:
                    DebugLog.print("[PSNWebSocket] Preparing connection...")

                default:
                    break
                }
            }

            conn.start(queue: .main)

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if gate.tryResume() {
                    conn.cancel()
                    continuation.resume(throwing: PSNWebSocketError.connectionFailed("Connection timeout"))
                }
            }
        }
        
        // Perform WebSocket handshake manually
        try await performWebSocketHandshake(connection: conn, host: fqdn, path: wsPath, accessToken: accessToken)
        
        // Start receiving WebSocket frames
        isConnected = true
        startReceivingFrames()
        
        DebugLog.print("[PSNWebSocket] ✅ WebSocket connected with manual handshake!")
    }
    
    /// Perform WebSocket handshake with custom headers
    private func performWebSocketHandshake(connection: NWConnection, host: String, path: String, accessToken: String) async throws {
        // Generate WebSocket key
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        let wsKey = Data(keyBytes).base64EncodedString()
        
        // Build HTTP upgrade request (matching chiaki-ng headers exactly)
        // Use explicit string concatenation to ensure proper HTTP format (no extra newlines)
        var request = "GET \(path) HTTP/1.1\r\n"
        request += "Host: \(host)\r\n"
        request += "Upgrade: websocket\r\n"
        request += "Connection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(wsKey)\r\n"
        request += "Sec-WebSocket-Version: 13\r\n"
        request += "Sec-WebSocket-Protocol: np-pushpacket\r\n"
        request += "Authorization: Bearer \(accessToken)\r\n"
        request += "User-Agent: WebSocket++/0.8.2\r\n"
        request += "X-PSN-APP-TYPE: REMOTE_PLAY\r\n"
        request += "X-PSN-APP-VER: RemotePlay/1.0\r\n"
        request += "X-PSN-KEEP-ALIVE-STATUS-TYPE: 3\r\n"
        request += "X-PSN-OS-VER: Windows/10.0\r\n"
        request += "X-PSN-PROTOCOL-VERSION: 2.1\r\n"
        request += "X-PSN-RECONNECTION: false\r\n"
        
        // Add cookies from FQDN request (like chiaki-ng's CURLOPT_SHARE)
        if !sessionCookies.isEmpty {
            let cookieString = sessionCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request += "Cookie: \(cookieString)\r\n"
            DebugLog.print("[PSNWebSocket] Adding Cookie header with \(sessionCookies.count) cookies")
        }
        
        request += "\r\n"  // End of headers
        
        guard let requestData = request.data(using: .utf8) else {
            throw PSNWebSocketError.connectionFailed("Failed to encode request")
        }
        
        DebugLog.print("[PSNWebSocket] Sending handshake request...")
        // Show first 200 bytes as hex to verify format
        let previewBytes = Array(requestData.prefix(200))
        let hexStr = previewBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        DebugLog.print("[PSNWebSocket] First 200 bytes (hex): \(hexStr)")
        // Also log escaping CR/LF
        let escapedRequest = request.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        DebugLog.print("[PSNWebSocket] Request (escaped): \(escapedRequest.prefix(500))...")
        
        // Send handshake request
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: PSNWebSocketError.connectionFailed("Send failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
        
        // Receive handshake response
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
                if let error = error {
                    continuation.resume(throwing: PSNWebSocketError.connectionFailed("Receive failed: \(error.localizedDescription)"))
                } else if let data = content {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PSNWebSocketError.connectionFailed("No response data"))
                }
            }
        }
        
        // Parse response
        guard let response = String(data: responseData, encoding: .utf8) else {
            throw PSNWebSocketError.connectionFailed("Failed to decode response")
        }
        
        DebugLog.print("[PSNWebSocket] Handshake response: \(response.prefix(200))...")
        
        // Check for 101 Switching Protocols
        guard response.contains("101") && response.lowercased().contains("upgrade") else {
            // Extract HTTP status code from response
            if let statusLine = response.components(separatedBy: "\r\n").first {
                throw PSNWebSocketError.connectionFailed("Handshake failed: \(statusLine)")
            }
            throw PSNWebSocketError.connectionFailed("Invalid handshake response")
        }
        
        // Verify Sec-WebSocket-Accept (non-critical check)
        let expectedAccept = calculateWebSocketAccept(key: wsKey)
        if !response.contains(expectedAccept) {
            DebugLog.print("[PSNWebSocket] ⚠️ Sec-WebSocket-Accept mismatch (may still work)")
        }
        
        DebugLog.print("[PSNWebSocket] ✅ WebSocket handshake successful!")
    }
    
    /// Calculate expected Sec-WebSocket-Accept value
    private func calculateWebSocketAccept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let hash = SHA1.hash(data: Data(combined.utf8))
        return Data(hash).base64EncodedString()
    }
    
    /// Start receiving WebSocket frames
    private func startReceivingFrames() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let connection = self.connection else { break }
                
                do {
                    let frame = try await self.receiveWebSocketFrame(connection: connection)
                    await self.handleWebSocketFrame(frame)
                } catch {
                    DebugLog.print("[PSNWebSocket] Receive error: \(error)")
                    await MainActor.run {
                        self.isConnected = false
                        self.onDisconnected?()
                    }
                    break
                }
            }
        }
    }
    
    /// Receive a single WebSocket frame
    private func receiveWebSocketFrame(connection: NWConnection) async throws -> WebSocketFrame {
        // Read first 2 bytes for header
        let header = try await receiveBytes(connection: connection, count: 2)
        
        let fin = (header[0] & 0x80) != 0
        let opcode = header[0] & 0x0F
        let masked = (header[1] & 0x80) != 0
        var payloadLength = Int(header[1] & 0x7F)
        
        // Extended payload length
        if payloadLength == 126 {
            let extended = try await receiveBytes(connection: connection, count: 2)
            payloadLength = Int(extended[0]) << 8 | Int(extended[1])
        } else if payloadLength == 127 {
            let extended = try await receiveBytes(connection: connection, count: 8)
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | Int(extended[i])
            }
        }
        
        // Read masking key if present
        var maskingKey: [UInt8]?
        if masked {
            maskingKey = try await receiveBytes(connection: connection, count: 4)
        }
        
        // Read payload
        var payload = [UInt8]()
        if payloadLength > 0 {
            payload = try await receiveBytes(connection: connection, count: payloadLength)
            
            // Unmask if needed
            if let mask = maskingKey {
                for i in 0..<payload.count {
                    payload[i] ^= mask[i % 4]
                }
            }
        }
        
        return WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }
    
    private func receiveBytes(connection: NWConnection, count: Int) async throws -> [UInt8] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = content {
                    continuation.resume(returning: [UInt8](data))
                } else {
                    continuation.resume(throwing: PSNWebSocketError.connectionFailed("Connection closed"))
                }
            }
        }
    }
    
    /// Handle received WebSocket frame
    private func handleWebSocketFrame(_ frame: WebSocketFrame) async {
        switch frame.opcode {
        case 0x1: // Text frame
            if let text = String(data: Data(frame.payload), encoding: .utf8) {
                DebugLog.print("[PSNWebSocket] Received text: \(text.prefix(200))...")
                await parseNotification(text)
            }
            
        case 0x2: // Binary frame
            DebugLog.print("[PSNWebSocket] Received binary: \(frame.payload.count) bytes")
            if let text = String(data: Data(frame.payload), encoding: .utf8) {
                await parseNotification(text)
            }
            
        case 0x8: // Close frame
            DebugLog.print("[PSNWebSocket] Received close frame")
            isConnected = false
            onDisconnected?()
            
        case 0x9: // Ping frame
            DebugLog.print("[PSNWebSocket] Received ping, sending pong")
            await sendPong(payload: frame.payload)
            
        case 0xA: // Pong frame
            DebugLog.print("[PSNWebSocket] Received pong")
            
        default:
            DebugLog.print("[PSNWebSocket] Unknown opcode: \(frame.opcode)")
        }
    }
    
    /// Send pong response
    private func sendPong(payload: [UInt8]) async {
        guard let connection = connection else { return }
        
        // Build pong frame (0x8A = fin + pong opcode)
        var frame = [UInt8]()
        frame.append(0x8A) // FIN + Pong
        frame.append(UInt8(payload.count))
        frame.append(contentsOf: payload)
        
        connection.send(content: Data(frame), completion: .contentProcessed { error in
            if let error = error {
                DebugLog.print("[PSNWebSocket] Failed to send pong: \(error)")
            }
        })
    }
    
    /// Parse notification from WebSocket
    private func parseNotification(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        // Check dataType for notification type
        if let dataType = json["dataType"] as? String {
            DebugLog.print("[PSNWebSocket] Notification type: \(dataType)")
            
            switch dataType {
            case "psn:sessionManager:sys:remotePlaySession:created":
                if let sessionId = extractSessionId(from: json) {
                    await MainActor.run {
                        self.onSessionCreated?(sessionId)
                    }
                }
                
            case "psn:sessionManager:sys:rps:members:created":
                await MainActor.run {
                    self.onMemberCreated?()
                }
                
            case "psn:sessionManager:sys:rps:sessionMessage:created":
                await MainActor.run {
                    self.onSessionMessage?(json)
                }
                
            default:
                DebugLog.print("[PSNWebSocket] Unhandled notification: \(dataType)")
            }
        }
    }
    
    /// Extract session ID from notification
    private func extractSessionId(from json: [String: Any]) -> String? {
        if let body = json["body"] as? [String: Any],
           let dataObj = body["data"] as? [String: Any],
           let sessions = dataObj["remotePlaySessions"] as? [[String: Any]],
           let firstSession = sessions.first,
           let sessionId = firstSession["sessionId"] as? String {
            return sessionId
        }
        return nil
    }
    
    /// Send ping to keep connection alive
    func sendPing() async {
        guard let connection = connection else { return }
        
        // Build ping frame (0x89 = fin + ping opcode)
        let frame: [UInt8] = [0x89, 0x00]
        
        connection.send(content: Data(frame), completion: .contentProcessed { error in
            if let error = error {
                DebugLog.print("[PSNWebSocket] Ping failed: \(error)")
            } else {
                DebugLog.print("[PSNWebSocket] Ping sent")
            }
        })
    }
}

// MARK: - WebSocket Frame

private struct WebSocketFrame {
    let fin: Bool
    let opcode: UInt8
    let payload: [UInt8]
}

// MARK: - SHA1 for WebSocket Accept (using CryptoKit would be better but SHA1 isn't directly available)

private struct SHA1 {
    static func hash(data: Data) -> [UInt8] {
        // Using Insecure.SHA1 from CryptoKit
        let digest = Insecure.SHA1.hash(data: data)
        return Array(digest)
    }
}

// MARK: - Errors

enum PSNWebSocketError: LocalizedError {
    case invalidURL
    case invalidResponse
    case fqdnFetchFailed(Int)
    case invalidFQDNResponse
    case connectionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .invalidResponse:
            return "Invalid response"
        case .fqdnFetchFailed(let code):
            return "FQDN fetch failed with code \(code)"
        case .invalidFQDNResponse:
            return "Invalid FQDN response"
        case .connectionFailed(let message):
            return "WebSocket connection failed: \(message)"
        }
    }
}
