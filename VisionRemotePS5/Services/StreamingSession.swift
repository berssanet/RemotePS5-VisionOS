import Foundation
import Network
import CryptoKit
import Combine
import CoreVideo

/// Manages the streaming session with a PlayStation console
/// Implements the Remote Play protocol for PS5
@MainActor
class StreamingSession: ObservableObject {
    
    // MARK: - Published Properties (Slow State Only)
    @Published var state: SessionState = .disconnected
    @Published var quality: StreamQuality = .hd1080
    @Published var latency: Int = 0
    @Published var bitrate: Int = 0
    @Published var packetsReceived: UInt64 = 0
    @Published var lastError: Error?
    @Published var frameRate: Double = 0
    
    // MARK: - Decoders
    private let videoDecoder = VideoDecoder()
    private let audioDecoder = AudioDecoder()
    
    // MARK: - Private Properties
    private var console: Console?
    private var rpKey: Data?
    private var controlConnection: NWConnection?
    private var videoConnection: NWConnection?
    private var audioConnection: NWConnection?
    private var heartbeatTimer: Timer?
    private var receiveTask: Task<Void, Never>?
    private var audioReceiveTask: Task<Void, Never>?
    
    // Encryption keys derived from ECDH
    private var sessionKey: SymmetricKey?
    private var gmacKey: Data?
    private var nonce: UInt64 = 0
    
    // Protocol constants
    private let controlPort: UInt16 = 9295
    private let videoPort: UInt16 = 9296
    private let audioPort: UInt16 = 9297
    
    // MARK: - High-Performance Callbacks (bypass SwiftUI)
    
    /// Called when a video frame is decoded and ready for rendering.
    /// This is called on the VideoToolbox decoder thread, NOT MainActor.
    /// - Warning: Must be thread-safe. Do not update SwiftUI state from here.
    var onFrameReady: ((CVPixelBuffer) -> Void)?
    
    /// Legacy callbacks for raw data processing
    var onVideoFrame: ((Data) -> Void)?
    var onAudioFrame: ((Data) -> Void)?
    
    // MARK: - Types
    
    enum SessionState: Equatable {
        case disconnected
        case connecting
        case authenticating
        case negotiating
        case connected
        case streaming
        case error(String)
    }
    
    enum StreamQuality: CaseIterable {
        case sd540
        case hd720
        case hd1080
        case uhd4k
        
        var resolution: (width: Int, height: Int) {
            switch self {
            case .sd540: return (960, 540)
            case .hd720: return (1280, 720)
            case .hd1080: return (1920, 1080)
            case .uhd4k: return (3840, 2160)
            }
        }
        
        var maxBitrate: Int {
            switch self {
            case .sd540: return 6_000
            case .hd720: return 10_000
            case .hd1080: return 15_000
            case .uhd4k: return 30_000
            }
        }
        
        var displayName: String {
            switch self {
            case .sd540: return "540p"
            case .hd720: return "720p"
            case .hd1080: return "1080p"
            case .uhd4k: return "4K"
            }
        }
    }
    
    // MARK: - Initialization
    
    init() {
        print("[Session] Initialized")
        setupVideoDecoderCallback()
    }
    
    /// Configure VideoDecoder callback to forward frames to coordinator
    private func setupVideoDecoderCallback() {
        videoDecoder.onFrameDecoded = { [weak self] pixelBuffer in
            // Called on VideoToolbox thread - forward to external handler
            self?.onFrameReady?(pixelBuffer)
            
            // Update frame rate on main actor (infrequent, safe to dispatch)
            let currentFrameRate = self?.videoDecoder.frameRate ?? 0
            if currentFrameRate > 0 {
                Task { @MainActor [weak self] in
                    self?.frameRate = currentFrameRate
                }
            }
        }
    }
    
    deinit {
        // Cancel connections directly without calling MainActor method
        heartbeatTimer?.invalidate()
        receiveTask?.cancel()
        controlConnection?.cancel()
        videoConnection?.cancel()
        audioConnection?.cancel()
        print("[Session] Deinitialized")
    }
    
    // MARK: - Public Methods
    
    /// Connect to a console and start streaming
    func connect(to console: Console, rpKey: Data?) async throws {
        self.console = console
        self.rpKey = rpKey
        state = .connecting
        
        print("[Session] Connecting to \(console.name) at \(console.ipAddress)")
        
        do {
            // Step 1: Establish TCP control connection
            try await establishControlConnection()
            print("[Session] Control connection established")
            
            // Step 2: Authenticate with RP-Key and ECDH
            state = .authenticating
            try await authenticate()
            print("[Session] Authentication complete")
            
            // Step 3: Negotiate stream parameters
            state = .negotiating
            try await negotiateStreamParameters()
            print("[Session] Stream negotiation complete")
            
            // Step 4: Establish UDP data connections
            try await establishDataConnections()
            print("[Session] Data connections established")
            
            // Step 5: Start streaming
            state = .streaming
            startHeartbeat()
            startReceiving()
            print("[Session] Streaming started")
            
        } catch {
            state = .error(error.localizedDescription)
            lastError = error
            print("[Session] Error: \(error)")
            throw error
        }
    }
    
    /// Disconnect from the console
    func disconnect() {
        print("[Session] Disconnecting...")
        
        state = .disconnected
        
        // Stop timers
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        
        // Cancel receive tasks
        receiveTask?.cancel()
        receiveTask = nil
        
        audioReceiveTask?.cancel()
        audioReceiveTask = nil
        
        // Cancel connections
        controlConnection?.cancel()
        controlConnection = nil
        
        videoConnection?.cancel()
        videoConnection = nil
        
        audioConnection?.cancel()
        audioConnection = nil
        
        // Stop decoders
        videoDecoder.stop()
        audioDecoder.stop()
        
        // Clear state
        console = nil
        sessionKey = nil
        gmacKey = nil
        nonce = 0
    }
    
    /// Send controller input to the console
    func sendInput(_ input: ControllerInput) {
        guard state == .streaming else { return }
        
        let packet = createInputPacket(input)
        sendControlPacket(type: .input, payload: packet)
    }
    
    /// Wake the console from standby
    func wakeConsole() async throws {
        guard let console = console else { throw StreamError.noConsole }
        
        // Send wake packet via UDP broadcast
        let wakePacket = createWakePacket()
        
        let host = NWEndpoint.Host(console.ipAddress)
        let port = NWEndpoint.Port(rawValue: 9302)!
        
        let connection = NWConnection(host: host, port: port, using: .udp)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: wakePacket, completion: .contentProcessed { error in
                        connection.cancel()
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
                }
            }
            connection.start(queue: .main)
        }
        
        print("[Session] Wake packet sent to \(console.ipAddress)")
    }
    
    // MARK: - Private Connection Methods
    
    private func establishControlConnection() async throws {
        guard let console = console else { throw StreamError.noConsole }
        
        let host = NWEndpoint.Host(console.ipAddress)
        let port = NWEndpoint.Port(rawValue: controlPort)!
        
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        
        let connection = NWConnection(host: host, port: port, using: params)
        self.controlConnection = connection
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: StreamError.connectionCancelled)
                default:
                    break
                }
            }
            
            connection.start(queue: .main)
            
            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if !resumed {
                    resumed = true
                    connection.cancel()
                    continuation.resume(throwing: StreamError.connectionTimeout)
                }
            }
        }
    }
    
    private func authenticate() async throws {
        guard let console = console else { throw StreamError.noConsole }
        
        // The PS5 Remote Play protocol uses HTTP-like messages
        // We need to send a proper session request
        
        // Generate session ID
        let sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        
        // Build HTTP request for session
        var request = "GET /sce/rp/session HTTP/1.1\r\n"
        request += "Host: \(console.ipAddress)\r\n"
        request += "User-Agent: remoteplay Windows\r\n"
        request += "Connection: keep-alive\r\n"
        request += "RP-Version: 8.0\r\n"
        request += "RP-Auth: \(rpKeyBase64())\r\n"
        request += "RP-Registkey: \(rpKeyHex())\r\n"
        request += "RP-Ostype: Windows\r\n"
        request += "RP-Controllertype: 3\r\n"
        request += "RP-Clienttype: 11\r\n"
        request += "RP-Session-Id: \(sessionId)\r\n"
        request += "\r\n"
        
        print("[Session] Sending HTTP auth request...")
        print("[Session] Request:\n\(request)")
        
        // Send HTTP request
        guard let requestData = request.data(using: .utf8) else {
            throw StreamError.authenticationFailed
        }
        
        try await sendRawData(requestData)
        
        // Receive HTTP response
        let responseData = try await receiveRawData(timeout: 5.0)
        
        guard let responseStr = String(data: responseData, encoding: .utf8) else {
            throw StreamError.authenticationFailed
        }
        
        print("[Session] Auth response:\n\(responseStr)")
        
        // Parse HTTP response
        let lines = responseStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw StreamError.authenticationFailed
        }
        
        // Check for success (HTTP 200)
        if statusLine.contains("200") {
            print("[Session] Authentication successful!")
            state = .connected
            
            // Parse response headers for session key if provided
            for line in lines {
                if line.lowercased().hasPrefix("rp-") {
                    print("[Session] Header: \(line)")
                }
            }
        } else if statusLine.contains("403") {
            // Parse error reason
            var reason = "Unknown"
            for line in lines {
                if line.lowercased().hasPrefix("rp-application-reason:") {
                    reason = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? reason
                }
            }
            print("[Session] Authentication failed: 403 Forbidden, reason: \(reason)")
            throw StreamError.authenticationRejected(reason: reason)
        } else {
            throw StreamError.authenticationFailed
        }
    }
    
    private func rpKeyBase64() -> String {
        guard let rpKey = rpKey else { return "" }
        return rpKey.base64EncodedString()
    }
    
    private func rpKeyHex() -> String {
        guard let rpKey = rpKey else { return "" }
        return rpKey.map { String(format: "%02x", $0) }.joined()
    }
    
    private func sendRawData(_ data: Data) async throws {
        guard let connection = controlConnection else { throw StreamError.noConnection }
        
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
    
    private func receiveRawData(timeout: TimeInterval = 10.0) async throws -> Data {
        guard let connection = controlConnection else { throw StreamError.noConnection }
        
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: StreamError.timeout)
                }
            }
            
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                guard !resumed else { return }
                resumed = true
                
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: StreamError.noData)
                }
            }
        }
    }
    
    private func negotiateStreamParameters() async throws {
        let params = StreamParameters(
            resolution: quality.resolution,
            bitrate: quality.maxBitrate,
            fps: 60,
            codec: .h265
        )
        
        let jsonData = try JSONEncoder().encode(params)
        try await sendPacket(.init(type: .streamConfig, payload: jsonData))
        
        let response = try await receivePacket(timeout: 5.0)
        guard response.type == .streamConfigAck else {
            throw StreamError.negotiationFailed
        }
        
        print("[Session] Negotiated: \(quality.displayName) @ \(quality.maxBitrate) kbps")
    }
    
    private func establishDataConnections() async throws {
        guard let console = console else { throw StreamError.noConsole }
        
        let host = NWEndpoint.Host(console.ipAddress)
        
        // Video connection (UDP 9296)
        let videoParams = NWParameters.udp
        videoParams.allowLocalEndpointReuse = true
        
        videoConnection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: videoPort)!,
            using: videoParams
        )
        
        // Audio connection (UDP 9297)
        let audioParams = NWParameters.udp
        audioParams.allowLocalEndpointReuse = true
        
        audioConnection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: audioPort)!,
            using: audioParams
        )
        
        // Start both connections
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await self.waitForConnection(self.videoConnection!, name: "video")
            }
            group.addTask { @MainActor in
                try await self.waitForConnection(self.audioConnection!, name: "audio")
            }
            try await group.waitForAll()
        }
    }
    
    private func waitForConnection(_ connection: NWConnection, name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                
                switch state {
                case .ready:
                    resumed = true
                    print("[Session] \(name) connection ready")
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            
            connection.start(queue: .main)
        }
    }
    
    // MARK: - Streaming Methods
    
    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
    }
    
    private func sendHeartbeat() {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        var data = Data()
        withUnsafeBytes(of: timestamp.bigEndian) { data.append(contentsOf: $0) }
        
        sendControlPacket(type: .heartbeat, payload: data)
    }
    
    private func startReceiving() {
        // Configure video decoder for H.265
        do {
            try videoDecoder.configure(codec: .h265, width: quality.resolution.width, height: quality.resolution.height)
        } catch {
            print("[Session] Failed to configure video decoder: \(error)")
        }
        
        // Start audio playback
        do {
            try audioDecoder.start()
        } catch {
            print("[Session] Failed to start audio decoder: \(error)")
        }
        
        // Start video receive loop
        receiveTask = Task {
            await videoReceiveLoop()
        }
        
        // Start audio receive loop
        audioReceiveTask = Task {
            await audioReceiveLoop()
        }
    }
    
    private func videoReceiveLoop() async {
        print("[Session] Starting video receive loop")
        
        while state == .streaming && !Task.isCancelled {
            if let videoConnection = videoConnection {
                do {
                    let data = try await receiveUDP(from: videoConnection)
                    if let decrypted = decrypt(data) {
                        packetsReceived += 1
                        
                        // Decode video frame - callback will be invoked on decoder thread
                        try videoDecoder.decode(decrypted)
                        
                        // Callback for raw data processing (optional)
                        onVideoFrame?(decrypted)
                    }
                } catch {
                    if !Task.isCancelled {
                        print("[Session] Video receive error: \(error)")
                    }
                }
            }
            
            // Small delay to prevent tight loop
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        print("[Session] Video receive loop ended")
    }
    
    private func audioReceiveLoop() async {
        print("[Session] Starting audio receive loop")
        
        while state == .streaming && !Task.isCancelled {
            if let audioConnection = audioConnection {
                do {
                    let data = try await receiveUDP(from: audioConnection)
                    if let decrypted = decrypt(data) {
                        // Decode and play audio
                        audioDecoder.decodeAndPlay(decrypted)
                        
                        // Callback for additional processing
                        onAudioFrame?(decrypted)
                    }
                } catch {
                    if !Task.isCancelled {
                        print("[Session] Audio receive error: \(error)")
                    }
                }
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        print("[Session] Audio receive loop ended")
    }
    
    private func receiveUDP(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: StreamError.noData)
                }
            }
        }
    }
    
    // MARK: - Packet Methods
    
    private func sendControlPacket(type: PacketType, payload: Data) {
        guard let connection = controlConnection else { return }
        
        let packet = ControlPacket(type: type, payload: encrypt(payload))
        let data = packet.encode()
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[Session] Send error: \(error)")
            }
        })
    }
    
    private func sendPacket(_ packet: ControlPacket) async throws {
        guard let connection = controlConnection else { throw StreamError.noConnection }
        
        let data = packet.encode()
        
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
    
    private func receivePacket(timeout: TimeInterval = 10.0) async throws -> ControlPacket {
        guard let connection = controlConnection else { throw StreamError.noConnection }
        
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            
            // Timeout task
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: StreamError.timeout)
                }
            }
            
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                guard !resumed else { return }
                resumed = true
                
                if let error = error {
                    print("[Session] Receive error: \(error)")
                    continuation.resume(throwing: error)
                } else if let data = data {
                    // Debug: print raw data
                    let hexString = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("[Session] Received \(data.count) bytes: \(hexString)")
                    
                    // Try to decode as string (might be HTTP-like)
                    if let str = String(data: data, encoding: .utf8) {
                        print("[Session] As string: \(str.prefix(200))")
                    }
                    
                    do {
                        let packet = try ControlPacket.decode(from: data)
                        continuation.resume(returning: packet)
                    } catch {
                        print("[Session] Packet decode error: \(error)")
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: StreamError.noData)
                }
            }
        }
    }
    
    // MARK: - Encryption Methods
    
    private func encrypt(_ data: Data) -> Data {
        guard let key = sessionKey else { return data }
        
        do {
            nonce += 1
            let nonceData = withUnsafeBytes(of: nonce.bigEndian) { Data($0) }
            let gcmNonce = try AES.GCM.Nonce(data: nonceData.prefix(12).rightPadded(to: 12))
            
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: gcmNonce)
            return sealedBox.combined ?? data
        } catch {
            print("[Session] Encryption error: \(error)")
            return data
        }
    }
    
    private func decrypt(_ data: Data) -> Data? {
        guard let key = sessionKey else { return data }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            return nil
        }
    }
    
    // MARK: - Helper Methods
    
    private func createInputPacket(_ input: ControllerInput) -> Data {
        var data = Data()
        
        // Stick values (normalized -1.0 to 1.0 -> Int16)
        let lx = Int16(input.leftStickX * 32767)
        let ly = Int16(input.leftStickY * 32767)
        let rx = Int16(input.rightStickX * 32767)
        let ry = Int16(input.rightStickY * 32767)
        
        withUnsafeBytes(of: lx.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: ly.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: rx.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: ry.bigEndian) { data.append(contentsOf: $0) }
        
        // Triggers (0.0 to 1.0 -> UInt8)
        data.append(UInt8(input.leftTrigger * 255))
        data.append(UInt8(input.rightTrigger * 255))
        
        // Buttons bitmask
        withUnsafeBytes(of: input.buttons.bigEndian) { data.append(contentsOf: $0) }
        
        return data
    }
    
    private func createWakePacket() -> Data {
        // Wake-on-LAN style packet for PS5
        var data = Data("WAKEUP".utf8)
        
        // Add RP-Key if available
        if let rpKey = rpKey {
            data.append(rpKey)
        }
        
        return data
    }
}

// MARK: - Supporting Types

enum PacketType: UInt8 {
    case authRequest = 0x01
    case authResponse = 0x02
    case streamConfig = 0x03
    case streamConfigAck = 0x04
    case input = 0x05
    case heartbeat = 0x06
    case disconnect = 0x07
    case videoData = 0x10
    case audioData = 0x11
}

struct ControlPacket {
    let type: PacketType
    let payload: Data
    
    func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        
        data.append(payload)
        return data
    }
    
    static func decode(from data: Data) throws -> ControlPacket {
        guard data.count >= 5 else { throw StreamError.invalidPacket }
        
        let typeRaw = data[0]
        guard let type = PacketType(rawValue: typeRaw) else {
            throw StreamError.unknownPacketType
        }
        
        let length = data.subdata(in: 1..<5).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        
        let payload = data.subdata(in: 5..<min(5 + Int(length), data.count))
        
        return ControlPacket(type: type, payload: payload)
    }
}

struct StreamParameters: Codable {
    let width: Int
    let height: Int
    let bitrate: Int
    let fps: Int
    let codec: Codec
    
    enum Codec: String, Codable {
        case h264
        case h265
    }
    
    init(resolution: (width: Int, height: Int), bitrate: Int, fps: Int, codec: Codec) {
        self.width = resolution.width
        self.height = resolution.height
        self.bitrate = bitrate
        self.fps = fps
        self.codec = codec
    }
}

struct ControllerInput {
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var buttons: UInt32 = 0
    
    // Button bit masks (PlayStation layout)
    static let buttonCross: UInt32    = 1 << 0
    static let buttonCircle: UInt32   = 1 << 1
    static let buttonSquare: UInt32   = 1 << 2
    static let buttonTriangle: UInt32 = 1 << 3
    static let buttonL1: UInt32       = 1 << 4
    static let buttonR1: UInt32       = 1 << 5
    static let buttonL2: UInt32       = 1 << 6
    static let buttonR2: UInt32       = 1 << 7
    static let buttonShare: UInt32    = 1 << 8
    static let buttonOptions: UInt32  = 1 << 9
    static let buttonL3: UInt32       = 1 << 10
    static let buttonR3: UInt32       = 1 << 11
    static let buttonPS: UInt32       = 1 << 12
    static let buttonTouchpad: UInt32 = 1 << 13
    static let dpadUp: UInt32         = 1 << 14
    static let dpadDown: UInt32       = 1 << 15
    static let dpadLeft: UInt32       = 1 << 16
    static let dpadRight: UInt32      = 1 << 17
}

enum StreamError: LocalizedError {
    case noConsole
    case noConnection
    case noData
    case connectionCancelled
    case connectionTimeout
    case timeout
    case authenticationFailed
    case authenticationRejected(reason: String)
    case negotiationFailed
    case invalidPacket
    case unknownPacketType
    case streamingFailed
    
    var errorDescription: String? {
        switch self {
        case .noConsole: return "No console selected"
        case .noConnection: return "Not connected to console"
        case .noData: return "No data received"
        case .connectionCancelled: return "Connection was cancelled"
        case .connectionTimeout: return "Connection timed out"
        case .timeout: return "Operation timed out"
        case .authenticationFailed: return "Failed to authenticate with console"
        case .authenticationRejected(let reason): return "Authentication rejected: \(reason)"
        case .negotiationFailed: return "Failed to negotiate stream parameters"
        case .invalidPacket: return "Received invalid packet"
        case .unknownPacketType: return "Unknown packet type"
        case .streamingFailed: return "Streaming failed"
        }
    }
}

// MARK: - Data Extension

extension Data {
    func rightPadded(to length: Int) -> Data {
        if count >= length { return self }
        var padded = self
        padded.append(Data(repeating: 0, count: length - count))
        return padded
    }
}
