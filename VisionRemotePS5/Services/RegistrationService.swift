import Foundation
import Network
import CryptoKit
import Security

/// Type alias for ChiakiBridgeService.RegisteredHostInfo
typealias RegisteredHostInfo = ChiakiBridgeService.RegisteredHostInfo

/// Service for registering/pairing with PlayStation consoles
/// Implements the Chiaki registration protocol for PS5
@MainActor
final class RegistrationService: ObservableObject {
    
    // MARK: - Published Properties
    @Published private(set) var isRegistering: Bool = false
    @Published private(set) var registrationError: String?
    @Published private(set) var isRegistered: Bool = false
    
    // MARK: - Private Properties
    private var connection: NWConnection?
    
    // Registration uses same port as session (9295)
    private let registrationPort: UInt16 = 9295
    
    // PS5 registration endpoint
    private let registrationPath = "/sie/ps5/rp/sess/rgst"
    
    init() {
        DebugLog.print("[Registration] Service initialized")
    }
    
    deinit {
        connection?.cancel()
        DebugLog.print("[Registration] Service deinitialized")
    }
    
    // MARK: - Public Methods
    
    /// Register with a console using PIN
    @MainActor
    func register(with console: Console, pin: String, accountId: String? = nil) async -> Bool {
        guard !isRegistering else {
            DebugLog.print("[Registration] Already registering")
            return false
        }
        
        guard pin.utf8.count == 8, pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
            registrationError = "PIN must be 8 digits"
            return false
        }
        
        isRegistering = true
        registrationError = nil
        
        DebugLog.print("[Registration] Starting registration with \(console.name) at \(console.ipAddress):\(registrationPort)")
        
        do {
            // Step 1: UDP Search Handshake (CRITICAL - chiaki-ng regist.c line 322)
            // PS5 requires this UDP exchange before accepting TCP registration
            DebugLog.print("[Registration] Starting UDP search handshake...")
            let searchSuccess = await performSearchHandshake(ipAddress: console.ipAddress)
            if !searchSuccess {
                DebugLog.print("[Registration] Warning: UDP search handshake failed/timed out, continuing anyway...")
            } else {
                DebugLog.print("[Registration] ✅ UDP search handshake completed")
            }
            
            // Brief delay after search (chiaki-ng: SEARCH_REQUEST_SLEEP_MS)
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms delay
            
            // Step 2: Connect to console via TCP
            let connected = await connectToConsole(ipAddress: console.ipAddress)
            guard connected else {
                throw RegistrationError.connectionFailed
            }
            
            // Step 3: Send registration request
            let hostInfo = try await performRegistration(console: console, pin: pin, accountId: accountId)
            
            // Step 4: Create updated console with all registration data
            var registeredConsole = console
            registeredConsole.rpKey = hostInfo.rpKey
            registeredConsole.registKey = hostInfo.registKey
            registeredConsole.serverMAC = hostInfo.serverMAC
            registeredConsole.nickname = hostInfo.nickname
            // StreamingViewModel sends this 8-byte ID in the session connect info.
            registeredConsole.psnAccountId = accountId.flatMap { Data(base64Encoded: $0) }
            registeredConsole.isPaired = true
            registeredConsole.lastConnected = Date()
            
            // Step 5: Save console with ALL data using ConsoleStorageService
            await ConsoleStorageService.shared.saveRegisteredConsole(registeredConsole)
            
            isRegistering = false
            isRegistered = true
            DebugLog.print("[Registration] Successfully registered with \(console.name)")
            DebugLog.print("[Registration] Console saved to persistent storage")
            return true
            
        } catch let error as RegistrationError {
            isRegistering = false
            registrationError = error.localizedDescription
            DebugLog.print("[Registration] Error: \(error.localizedDescription)")
            return false
        } catch {
            isRegistering = false
            registrationError = "Registration failed: \(error.localizedDescription)"
            DebugLog.print("[Registration] Error: \(error)")
            return false
        }
    }
    
    /// Check if a console is registered
    func isConsoleRegistered(_ console: Console) async -> Bool {
        return await ConsoleStorageService.shared.isConsoleRegistered(ip: console.ipAddress)
    }
    
    /// Clear stored RP-Key for a console
    func clearRPKey(for console: Console) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.visionremote.ps5.rpkey",
            kSecAttrAccount as String: console.ipAddress
        ]
        SecItemDelete(query as CFDictionary)
        DebugLog.print("[Registration] Cleared RP-Key for \(console.ipAddress)")
    }
    
    // MARK: - Private Methods
    
    private func connectToConsole(ipAddress: String) async -> Bool {
        let host = NWEndpoint.Host(ipAddress)
        let port = NWEndpoint.Port(rawValue: registrationPort)!
        
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        connection = NWConnection(host: host, port: port, using: params)
        
        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate()

            connection?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.tryResume() {
                        DebugLog.print("[Registration] Connected to console on port \(self.registrationPort)")
                        continuation.resume(returning: true)
                    }

                case .failed(let error):
                    if gate.tryResume() {
                        DebugLog.print("[Registration] Connection failed: \(error)")
                        continuation.resume(returning: false)
                    }

                case .cancelled:
                    if gate.tryResume() {
                        continuation.resume(returning: false)
                    }

                default:
                    break
                }
            }

            connection?.start(queue: .main)

            // Timeout after 10 seconds
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if gate.tryResume() {
                    connection?.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Perform UDP search handshake (chiaki-ng regist_search)
    /// Sends "SRC3" packet, waits for "RES3" response
    private func performSearchHandshake(ipAddress: String) async -> Bool {
        // regist_search uses REGIST_PORT (9295), NOT discovery ports
        let searchPort: UInt16 = 9295
        
        // Create UDP connection
        let host = NWEndpoint.Host(ipAddress)
        let port = NWEndpoint.Port(rawValue: searchPort)!
        
        let params = NWParameters.udp
        let udpConnection = NWConnection(host: host, port: port, using: params)
        
        return await withCheckedContinuation { continuation in
            let gate = ContinuationGate()

            udpConnection.stateUpdateHandler = { [weak udpConnection] state in
                switch state {
                case .ready:
                    // Send "SRC3\0" packet (null-terminated string)
                    let searchPacket = Data("SRC3\0".utf8)
                    DebugLog.print("[Registration] Sending UDP search packet: SRC3")

                    udpConnection?.send(content: searchPacket, completion: .contentProcessed { error in
                        if let error = error {
                            DebugLog.print("[Registration] UDP send error: \(error)")
                            if gate.tryResume() {
                                udpConnection?.cancel()
                                continuation.resume(returning: false)
                            }
                            return
                        }

                        DebugLog.print("[Registration] UDP search packet sent, waiting for response...")

                        // Receive response
                        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, isComplete, error in
                            if let error = error {
                                DebugLog.print("[Registration] UDP receive error: \(error)")
                                if gate.tryResume() {
                                    udpConnection?.cancel()
                                    continuation.resume(returning: false)
                                }
                                return
                            }

                            if let data = data {
                                let responseStr = String(data: data, encoding: .utf8) ?? ""
                                DebugLog.print("[Registration] UDP search response: \(data.count) bytes - \(responseStr.prefix(10))")

                                // Check for "RES3" response
                                if responseStr.hasPrefix("RES3") {
                                    DebugLog.print("[Registration] ✅ Received valid RES3 response")
                                    if gate.tryResume() {
                                        udpConnection?.cancel()
                                        continuation.resume(returning: true)
                                    }
                                    return
                                }
                            }

                            // No valid response
                            if gate.tryResume() {
                                udpConnection?.cancel()
                                continuation.resume(returning: false)
                            }
                        }
                    })

                case .failed(let error):
                    DebugLog.print("[Registration] UDP connection failed: \(error)")
                    if gate.tryResume() {
                        continuation.resume(returning: false)
                    }

                case .cancelled:
                    if gate.tryResume() {
                        continuation.resume(returning: false)
                    }

                default:
                    break
                }
            }

            udpConnection.start(queue: .main)

            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if gate.tryResume() {
                    DebugLog.print("[Registration] UDP search timeout")
                    udpConnection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    private func performRegistration(console: Console, pin: String, accountId: String?) async throws -> RegisteredHostInfo {
        guard let connection = connection else {
            throw RegistrationError.connectionFailed
        }
        
        // Generate ambassador (random 16-byte key)
        var ambassador = Data(count: 16)
        _ = ambassador.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        
        // Parse PIN
        guard let pinInt = UInt32(pin) else {
            throw RegistrationError.invalidPin
        }
        
        
        // Use ChiakiBridgeService NATIVE wrapper to format the payload
        // This directly calls chiaki_regist_request_payload_format for bit-perfect parity
        let result = try ChiakiBridgeService.shared.formatRegistrationPayloadNative(
            target: .ps5_1,
            ambassador: ambassador,
            accountId: accountId,
            pin: pinInt
        )
        
        let payload = result.payload
        let payloadSize = payload.count
        
        // Build HTTP request - MUST match chiaki-ng format exactly (regist.c line 103-108)
        // Note: The unusual " HTTP/1.1\r\n" after the first line is intentional!
        // Using actual console IP for HOST header
        var request = "POST \(registrationPath) HTTP/1.1\r\n HTTP/1.1\r\n"
        request += "HOST: \(console.ipAddress)\r\n"
        request += "User-Agent: remoteplay Windows\r\n"
        request += "Connection: close\r\n"
        request += "Content-Length: \(payloadSize)\r\n"
        request += "RP-Version: 1.0\r\n"
        request += "\r\n"
        
        DebugLog.print("[Registration] Sending registration request...")
        DebugLog.print("[Registration] Endpoint: \(registrationPath)")
        DebugLog.print("[Registration] Payload size: \(payloadSize)")
        
        // Combine header and payload
        guard var requestData = request.data(using: .utf8) else {
            throw RegistrationError.protocolError("Failed to encode request")
        }
        
        // DEBUG: Hex dump of complete HTTP header for byte-level comparison
        let headerBytes = [UInt8](requestData)
        DebugLog.print("[Registration] HTTP Header (\(headerBytes.count) bytes):")
        DebugLog.print("[Registration] Header HEX: \(headerBytes.map { String(format: "%02x", $0) }.joined())")
        DebugLog.print("[Registration] Header ASCII: \(String(data: requestData, encoding: .utf8) ?? "N/A")")
        
        requestData.append(payload)
        
        // Send request
        try await sendData(requestData, connection: connection)
        
        // Receive response
        let responseData = try await receiveData(connection: connection, timeout: 10.0)
        
        DebugLog.print("[Registration] Response received: \(responseData.count) bytes")
        
        // Try ASCII decoding first (covers both UTF-8 and ASCII responses)
        guard let responseStr = String(data: responseData, encoding: .ascii) else {
            // If even ASCII fails, try to find HTTP header in binary data
            if let headerEnd = responseData.firstRange(of: Data("\r\n\r\n".utf8)) {
                let headerData = responseData[responseData.startIndex..<headerEnd.lowerBound]
                if let headerStr = String(data: headerData, encoding: .ascii) {
                    // Use COMPUTED ambassador from crypt, NOT the original random
                    return try parseRegistrationResponse(headerStr, fullData: responseData, brightKey: result.brightKey, ambassadorKey: result.ambassadorKey)
                }
            }
            throw RegistrationError.protocolError("Invalid response encoding")
        }
        
        
        // Parse response with brightKey and COMPUTED ambassador for decryption
        return try parseRegistrationResponse(responseStr, fullData: responseData, brightKey: result.brightKey, ambassadorKey: result.ambassadorKey)
    }
    
    
    private func parseRegistrationResponse(_ response: String, fullData: Data? = nil, brightKey: [UInt8]? = nil, ambassadorKey: [UInt8]? = nil) throws -> RegisteredHostInfo {
        let lines = response.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw RegistrationError.protocolError("Empty response")
        }
        DebugLog.print("[Registration] Response status: \(statusLine)")
        
        // Check status
        if statusLine.contains("200") || statusLine.contains("OK") {
            // Success! Try to decrypt response body using C-core
            if let data = fullData, let bright = brightKey, let ambassador = ambassadorKey {
                // Find the body after HTTP headers (\r\n\r\n)
                if let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) {
                    let bodyStart = headerEnd.upperBound
                    let body = data[bodyStart...]
                    
                    if !body.isEmpty {
                        let hostInfo = try ChiakiBridgeService.shared.decryptRegistrationResponse(
                            target: .ps5_1,
                            brightKey: bright,
                            ambassadorKey: ambassador,
                            encryptedData: Data(body)
                        )
                        
                        DebugLog.print("[Registration] ✅ Nickname: \(hostInfo.nickname)")
                        DebugLog.print("[Registration] ✅ MAC: \(hostInfo.serverMAC.map { String(format: "%02x", $0) }.joined())")
                        
                        connection?.cancel()
                        connection = nil
                        return hostInfo
                    }
                }
            }
            
            // Fallback: If decryption failed, create minimal host info from headers
            var rpKeyData: Data?
            var registKey = ""
            for line in lines {
                let lowercased = line.lowercased()
                if lowercased.hasPrefix("rp-key:") || lowercased.hasPrefix("rp-registkey:") {
                    let keyHex = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                    rpKeyData = Data(hexString: keyHex)
                    registKey = keyHex
                }
            }
            
            if let rpKey = rpKeyData, rpKey.count > 0 {
                connection?.cancel()
                connection = nil
                return RegisteredHostInfo(
                    rpKey: rpKey,
                    registKey: registKey,
                    serverMAC: [0, 0, 0, 0, 0, 0],
                    nickname: "PS5",
                    rpKeyType: 2
                )
            } else {
                throw RegistrationError.protocolError("No RP-Key in response and decryption failed")
            }
            
        } else if statusLine.contains("403") {
            var reason = "Unknown"
            for line in lines {
                if line.lowercased().hasPrefix("rp-application-reason:") {
                    reason = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? reason
                }
            }
            
            // Decode error reason
            let errorMessage = decodeRegistrationError(reason)
            throw RegistrationError.rejected(reason: errorMessage)
            
        } else {
            throw RegistrationError.protocolError("Unexpected response: \(statusLine)")
        }
    }
    
    private func decodeRegistrationError(_ code: String) -> String {
        // Common PS5 Remote Play error codes
        switch code {
        case "80108bff":
            return "PIN expired or invalid. Generate a new PIN on PS5."
        case "80108b02":
            return "Remote Play is disabled on PS5."
        case "80108b01":
            return "Already registered with another device."
        case "80108b03":
            return "PSN account mismatch."
        default:
            return "\(code) - Unknown error"
        }
    }
    
    private func sendData(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receiveData(connection: NWConnection, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Lock-protected one-shot gate: the timeout Task and the receive
            // callback race on different queues; a plain Bool here can double-
            // resume the continuation and crash.
            let gate = ContinuationGate()

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if gate.tryResume() {
                    continuation.resume(throwing: RegistrationError.timeout)
                }
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                guard gate.tryResume() else { return }

                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RegistrationError.protocolError("No data received"))
                }
            }
        }
    }
}

// MARK: - Registration Errors

enum RegistrationError: LocalizedError {
    case connectionFailed
    case invalidPin
    case rejected(reason: String)
    case timeout
    case protocolError(String)
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to console"
        case .invalidPin:
            return "Invalid PIN code"
        case .rejected(let reason):
            return "Registration rejected: \(reason)"
        case .timeout:
            return "Registration timed out"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        }
    }
}

// MARK: - Data Hex Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}
