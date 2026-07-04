import Foundation

// MARK: - PSN Session Manager
/// Manages PSN Remote Play sessions and device listing
@MainActor
class PSNSessionManager: ObservableObject {
    static let shared = PSNSessionManager()
    
    @Published var devices: [PSNDevice] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var isWebSocketConnected = false
    
    private let authService = PSNAuthService()
    private let webSocketService = PSNWebSocketService.shared
    
    // Current session info
    private var currentSessionId: String?
    private var sessionCreatedContinuation: CheckedContinuation<String, Error>?
    
    // API Endpoints (from chiaki-ng)
    private static let baseURL = "https://web.np.playstation.com"
    private static let sessionManagerURL = "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions"
    private static let devicesURL = "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients"
    private static let commandsURL = "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/commands"
    
    init() {
        setupWebSocketCallbacks()
    }
    
    private func setupWebSocketCallbacks() {
        webSocketService.onSessionCreated = { [weak self] (sessionId: String) in
            DebugLog.print("[PSNSession] WebSocket: Session created with ID: \(sessionId)")
            self?.currentSessionId = sessionId
            self?.sessionCreatedContinuation?.resume(returning: sessionId)
            self?.sessionCreatedContinuation = nil
        }
        
        webSocketService.onMemberCreated = { [weak self] () in
            DebugLog.print("[PSNSession] WebSocket: Member created")
            _ = self  // Silence warning
        }
        
        webSocketService.onSessionMessage = { (message: [String: Any]) in
            DebugLog.print("[PSNSession] WebSocket: Session message received")
        }
    }
    
    // MARK: - Device Listing
    
    /// List all PlayStation devices associated with the PSN account
    func listDevices() async throws -> [PSNDevice] {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        let accessToken = try await authService.getAccessToken()
        
        guard let url = URL(string: Self.devicesURL) else {
            throw PSNSessionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        DebugLog.print("[PSNSession] Listing devices...")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNSessionError.invalidResponse
        }
        
        DebugLog.print("[PSNSession] List devices status: \(httpResponse.statusCode)")
        
        if let responseStr = String(data: data, encoding: .utf8) {
            DebugLog.print("[PSNSession] Response: \(responseStr.prefix(500))")
        }
        
        if httpResponse.statusCode == 401 {
            // Token expired, try refreshing
            try await authService.refreshAccessToken()
            return try await listDevices()
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PSNSessionError.requestFailed(httpResponse.statusCode, errorMessage)
        }
        
        let devicesResponse = try JSONDecoder().decode(PSNDevicesResponse.self, from: data)
        devices = devicesResponse.clients ?? []
        
        DebugLog.print("[PSNSession] Found \(devices.count) devices")
        return devices
    }
    
    // MARK: - Session Management
    
    /// Create a Remote Play session on the PSN server
    /// Following chiaki-ng flow: 1) Connect WebSocket 2) Create HTTP session 3) Wait for notification
    func createSession(for device: PSNDevice) async throws -> PSNSession {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        let accessToken = try await authService.getAccessToken()
        
        // Step 1: Connect WebSocket FIRST (required before HTTP session creation)
        if !webSocketService.isConnected {
            DebugLog.print("[PSNSession] Connecting WebSocket before session creation...")
            try await webSocketService.connect(accessToken: accessToken)
            isWebSocketConnected = true
            DebugLog.print("[PSNSession] ✅ WebSocket connected!")
        }
        
        // Use the pushContextId from WebSocket service
        let pushContextId = webSocketService.currentPushContextId
        
        guard let url = URL(string: Self.sessionManagerURL) else {
            throw PSNSessionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Headers from chiaki-ng that are required for session API
        request.setValue("RpNetHttpUtilImpl", forHTTPHeaderField: "User-Agent")
        request.setValue("jp", forHTTPHeaderField: "Accept-Language")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        
        // Format from chiaki-ng: remotePlaySessions array with members
        let sessionJson: [String: Any] = [
            "remotePlaySessions": [
                [
                    "members": [
                        [
                            "accountId": "me",
                            "deviceUniqueId": "me",
                            "platform": "me",
                            "pushContexts": [
                                ["pushContextId": pushContextId]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: sessionJson)
        
        DebugLog.print("[PSNSession] Creating session for device: \(device.name ?? device.deviceId)")
        DebugLog.print("[PSNSession] Using pushContextId: \(pushContextId)")
        DebugLog.print("[PSNSession] Token (first 20 chars): \(String(accessToken.prefix(20)))...")
        if let bodyStr = String(data: request.httpBody ?? Data(), encoding: .utf8) {
            DebugLog.print("[PSNSession] Request body: \(bodyStr)")
        }
        
        // Step 2: Send HTTP session creation request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNSessionError.invalidResponse
        }
        
        DebugLog.print("[PSNSession] Create session status: \(httpResponse.statusCode)")
        
        if let responseStr = String(data: data, encoding: .utf8) {
            DebugLog.print("[PSNSession] Create session response: \(responseStr.prefix(500))")
        }
        
        if httpResponse.statusCode == 401 {
            // Token issue - disconnect WebSocket and retry
            webSocketService.disconnect()
            isWebSocketConnected = false
            try await authService.refreshAccessToken()
            return try await createSession(for: device)
        }
        
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PSNSessionError.sessionCreationFailed(errorMessage)
        }
        
        // Parse response - may have different structure
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessions = json["remotePlaySessions"] as? [[String: Any]],
           let firstSession = sessions.first,
           let sessionId = firstSession["sessionId"] as? String {
            DebugLog.print("[PSNSession] ✅ Session created: \(sessionId)")
            currentSessionId = sessionId
            return PSNSession(sessionId: sessionId, status: "created", createdAt: nil)
        }
        
        // Try standard decode as fallback
        let session = try JSONDecoder().decode(PSNSession.self, from: data)
        DebugLog.print("[PSNSession] ✅ Session created: \(session.sessionId ?? "N/A")")
        currentSessionId = session.sessionId
        
        return session
    }
    
    /// Send a command to start Remote Play on a device
    func sendRemotePlayCommand(to device: PSNDevice, session: PSNSession) async throws {
        let accessToken = try await authService.getAccessToken()
        
        guard let url = URL(string: Self.commandsURL) else {
            throw PSNSessionError.invalidURL
        }
        
        // Generate data1 and data2 for the connection
        let data1 = generateRandomData(16).base64EncodedString()
        let data2 = generateRandomData(16).base64EncodedString()
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        // Build initialParams JSON string separately to avoid escape issues
        let sessionIdValue = session.sessionId ?? ""
        let initialParamsJson = """
        {"clientType":"visionOS","data1":"\(data1)","data2":"\(data2)","roomId":0,"protocolVer":"10.0","sessionId":"\(sessionIdValue)"}
        """
        
        // Command format from chiaki-ng
        let commandJson: [String: Any] = [
            "commandDetail": [
                "commandType": "remotePlay",
                "duid": device.deviceId,
                "messageDestination": "SQS",
                "parameters": [
                    "initialParams": initialParamsJson
                ],
                "platform": device.deviceType ?? "PS5"
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: commandJson)
        
        DebugLog.print("[PSNSession] Sending remotePlay command to device")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNSessionError.invalidResponse
        }
        
        DebugLog.print("[PSNSession] Command status: \(httpResponse.statusCode)")
        
        if let responseStr = String(data: data, encoding: .utf8) {
            DebugLog.print("[PSNSession] Command response: \(responseStr.prefix(500))")
        }
    }
    
    /// Start a Remote Play session with a specific device
    func startSession(_ session: PSNSession, device: PSNDevice) async throws -> PSNSessionStartResponse {
        isLoading = true
        defer { isLoading = false }
        
        let accessToken = try await authService.getAccessToken()
        
        guard let sessionId = session.sessionId,
              let url = URL(string: "\(Self.sessionManagerURL)/\(sessionId)/start") else {
            throw PSNSessionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let startRequest = PSNSessionStartRequest(
            deviceId: device.deviceId,
            duid: generateDUID()
        )
        
        request.httpBody = try JSONEncoder().encode(startRequest)
        
        DebugLog.print("[PSNSession] Starting session: \(sessionId)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PSNSessionError.invalidResponse
        }
        
        DebugLog.print("[PSNSession] Start session status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PSNSessionError.sessionStartFailed(errorMessage)
        }
        
        let startResponse = try JSONDecoder().decode(PSNSessionStartResponse.self, from: data)
        DebugLog.print("[PSNSession] ✅ Session started successfully")
        
        return startResponse
    }
    
    /// Delete a session
    func deleteSession(_ session: PSNSession) async throws {
        let accessToken = try await authService.getAccessToken()
        
        guard let sessionId = session.sessionId,
              let url = URL(string: "\(Self.sessionManagerURL)/\(sessionId)") else {
            throw PSNSessionError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        DebugLog.print("[PSNSession] Deleting session: \(sessionId)")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            throw PSNSessionError.sessionDeleteFailed
        }
        
        DebugLog.print("[PSNSession] ✅ Session deleted")
    }
    
    // MARK: - DUID Generation
    
    /// Generate a unique device identifier (DUID) for the client
    private func generateDUID() -> String {
        // Format: base64 of 36 random bytes (like chiaki-ng)
        var bytes = [UInt8](repeating: 0, count: 36)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
    
    /// Generate a push context ID for session creation
    private func generatePushContextId() -> String {
        // UUID format for push context
        return UUID().uuidString.lowercased()
    }
    
    /// Generate random data for connection parameters
    private func generateRandomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Data Models

struct PSNDevice: Codable, Identifiable {
    var id: String { deviceId }
    
    let deviceId: String
    let name: String?
    let deviceType: String?
    let status: String?
    let remotePlayEnabled: Bool?
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "duid"
        case name
        case deviceType = "type"
        case status
        case remotePlayEnabled = "remoteplay_enabled"
    }
}

struct PSNDevicesResponse: Codable {
    let clients: [PSNDevice]?
}

struct PSNSession: Codable {
    let sessionId: String?
    let status: String?
    let createdAt: String?
    
    init(sessionId: String?, status: String?, createdAt: String?) {
        self.sessionId = sessionId
        self.status = status
        self.createdAt = createdAt
    }
    
    enum CodingKeys: String, CodingKey {
        case sessionId = "id"
        case status
        case createdAt = "created_at"
    }
}

struct PSNSessionCreateRequest: Codable {
    let deviceId: String
    let deviceType: String
    let clientType: String
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceType = "device_type"
        case clientType = "client_type"
    }
}

struct PSNSessionStartRequest: Codable {
    let deviceId: String
    let duid: String
    
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case duid
    }
}

struct PSNSessionStartResponse: Codable {
    let sessionId: String?
    let peerAddress: String?
    let peerPort: Int?
    let data1: String?
    let data2: String?
    
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case peerAddress = "peer_address"
        case peerPort = "peer_port"
        case data1
        case data2
    }
}

// MARK: - Errors

enum PSNSessionError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(Int, String)
    case sessionCreationFailed(String)
    case sessionStartFailed(String)
    case sessionDeleteFailed
    case noDevicesFound
    case webSocketConnectionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from PSN"
        case .requestFailed(let code, let message):
            return "Request failed (\(code)): \(message)"
        case .sessionCreationFailed(let message):
            return "Session creation failed: \(message)"
        case .sessionStartFailed(let message):
            return "Session start failed: \(message)"
        case .sessionDeleteFailed:
            return "Failed to delete session"
        case .noDevicesFound:
            return "No PlayStation devices found"
        case .webSocketConnectionFailed:
            return "WebSocket connection failed"
        }
    }
}
