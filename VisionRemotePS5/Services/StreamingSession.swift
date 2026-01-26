import Foundation
import Network
import CryptoKit
import Combine
import CoreVideo
import CoreMedia

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
    
    // MARK: - Buffer Pools (High-Performance Streaming)
    
    /// Buffer pool for video packets (larger buffers for video frames)
    private let videoBufferPool = StreamingBufferPool(bufferSize: 131072, poolSize: 16) // 128KB
    
    /// Buffer pool for audio packets (smaller buffers)
    private let audioBufferPool = StreamingBufferPool(bufferSize: 8192, poolSize: 8) // 8KB
    
    /// Optimized decryptor with buffer reuse
    private lazy var streamingDecryptor: StreamingDecryptor = {
        StreamingDecryptor(bufferPool: videoBufferPool)
    }()
    
    // MARK: - v10.3 Zero-Copy Network Infrastructure
    
    /// Network buffer pool for UDP reception (avoids Data allocations)
    private let networkBufferPool = NetworkBufferPool(bufferSize: 65536, poolSize: 32)
    
    /// Zero-copy decryptor that operates on raw buffer pointers
    private let zeroCopyDecryptor = ZeroCopyAESGCMDecryptor(outputBufferSize: 131072, poolSize: 16)
    
    // MARK: - Audio/Video Sync
    
    /// A/V Sync controller for PTS-based drift correction
    private let avSyncController = AudioVideoSyncController(sampleRate: 48000)
    
    // MARK: - High-Frequency Input System
    
    /// Dedicated high-frequency input controller (120Hz polling)
    private lazy var inputController: HighFrequencyInputController = {
        let controller = HighFrequencyInputController()
        controller.pollingFrequencyHz = 120
        controller.onInputPacket = { [weak self] packet in
            self?.sendInputPacket(packet)
        }
        return controller
    }()
    
    /// Parser for PS5 haptic feedback packets
    private let hapticParser = PS5HapticFeedbackParser()
    
    /// Reference to GameControllerManager for haptic output
    weak var gameControllerManager: GameControllerManager?
    
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
    
    // MARK: - v10.3 Packet Loss Detection
    
    /// Packet loss detector for video stream
    private let videoPacketLossDetector = PacketLossDetector(streamName: "Video")
    
    /// Packet loss detector for audio stream
    private let audioPacketLossDetector = PacketLossDetector(streamName: "Audio")
    
    /// Minimum time between IDR requests (avoid flooding)
    private var lastIDRRequestTime: UInt64 = 0
    private let minIDRRequestIntervalNs: UInt64 = 100_000_000  // 100ms
    
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
        print("[Session] Initialized v10.3 (Direct Texture Pipeline)")
        setupVideoDecoderCallback()
    }
    
    /// Configure VideoDecoder callback for direct texture update.
    /// This is the HOT PATH: VideoToolbox → UpscalingPipeline → VideoTextureCoordinator (bypasses SwiftUI state)
    private func setupVideoDecoderCallback() {
        videoDecoder.onFrameDecoded = { [weak self] pixelBuffer in
            // CRITICAL: Called on VideoToolbox thread - do NOT dispatch to MainActor
            guard let self = self else { return }
            
            // v10.3: Extract video PTS from CVPixelBuffer attachments for A/V sync
            // VideoToolbox includes timing info in the presentation timestamp
            let pts = self.extractVideoPTS(from: pixelBuffer)
            if pts > 0 {
                self.avSyncController.onVideoFramePresented(pts: pts)
            }
            
            // v10.4: Process through UpscalingPipeline for 4K output
            // This feeds the upscaledTexture that StreamingView displays
            let upscalingPipeline = UpscalingPipeline.shared
            if upscalingPipeline.isEnabled {
                // 4K path: Upscale and forward to UI
                let result = upscalingPipeline.processFrame(pixelBuffer)
                if result == nil {
                    // Log first failure only
                    if upscalingPipeline.textureFrameId == 0 {
                        print("[StreamingSession] ⚠️ UpscalingPipeline.processFrame returned nil")
                    }
                }
            } else {
                // Log only once
                struct Once { static var logged = false }
                if !Once.logged {
                    Once.logged = true
                    print("[StreamingSession] ⚠️ UpscalingPipeline not enabled in callback")
                }
            }
            
            // v10.3: Direct update to VideoTextureCoordinator (bypasses SwiftUI)
            // This ensures Decoder → MetalFX → RealityKit runs independently of SwiftUI layout
            if #available(visionOS 2.0, *) {
                VideoTextureCoordinator.shared.updateTexture(from: pixelBuffer)
            }
            
            // Also forward to external handler for custom processing chains
            self.onFrameReady?(pixelBuffer)
            
            // Update frame rate on main actor (infrequent, safe to dispatch)
            // Only dispatch every 60 frames to minimize overhead
            let frameCount = self.videoDecoder.droppedFrameCount
            if frameCount % 60 == 0 {
                let currentFrameRate = self.videoDecoder.frameRate
                if currentFrameRate > 0 {
                    Task { @MainActor [weak self] in
                        self?.frameRate = currentFrameRate
                    }
                }
            }
        }
    }
    
    /// Extract PTS (Presentation Timestamp) from CVPixelBuffer.
    /// Returns time in seconds, or 0 if not available.
    private func extractVideoPTS(from pixelBuffer: CVPixelBuffer) -> Double {
        // Try to get timing info from attachments
        if let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any] {
            // Check for CMSampleBuffer timing info (if forwarded)
            if let timeValue = attachments["PresentationTimeStamp"] as? CMTime {
                return CMTimeGetSeconds(timeValue)
            }
        }
        
        // Fallback: Use system time as PTS (less accurate but functional)
        // This works because video frames arrive at roughly real-time pace
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let now = mach_absolute_time()
        let nanos = now * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Double(nanos) / 1_000_000_000.0
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
    
    // MARK: - v10.3 High-Frequency Input
    
    /// Send pre-serialized input packet (called from HighFrequencyInputController)
    /// This is the fast path - no MainActor required
    private func sendInputPacket(_ packet: InputPacket) {
        guard state == .streaming else { return }
        sendControlPacket(type: .input, payload: packet.serialize())
    }
    
    /// Start the high-frequency input loop
    func startInputController() {
        inputController.start()
        
        // Configure haptic feedback callback
        hapticParser.onFeedbackChanged = { [weak self] feedback in
            Task { @MainActor in
                self?.gameControllerManager?.applyPS5Feedback(feedback)
            }
        }
        
        print("[Session] ✅ Input controller started at \(inputController.pollingFrequencyHz)Hz")
    }
    
    /// Stop the input controller
    func stopInputController() {
        inputController.stop()
        print("[Session] Input controller stopped")
    }
    
    /// Process incoming haptic feedback packet from PS5
    func processHapticFeedback(_ data: Data) {
        _ = hapticParser.parseChiakiPacket(data)
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
        
        // v10.3: Video connection (UDP 9296) with interactiveVideo priority
        let videoParams = NWParameters.udp
        videoParams.allowLocalEndpointReuse = true
        
        // Configure for lowest latency gaming traffic
        videoParams.serviceClass = .interactiveVideo  // Highest priority for real-time video
        videoParams.multipathServiceType = .handover  // Better Wi-Fi/cellular handover
        videoParams.allowFastOpen = true              // TCP Fast Open for quicker reconnects
        
        // Set IP DSCP for QoS (EF = Expedited Forwarding, highest priority)
        if let ipOptions = videoParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.disableFragmentation = false  // Allow large frames
        }
        
        videoConnection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: videoPort)!,
            using: videoParams
        )
        
        // v10.3: Audio connection (UDP 9297) with interactiveVoice priority
        let audioParams = NWParameters.udp
        audioParams.allowLocalEndpointReuse = true
        audioParams.serviceClass = .interactiveVoice  // High priority for real-time audio
        audioParams.multipathServiceType = .handover
        audioParams.allowFastOpen = true
        
        audioConnection = NWConnection(
            host: host,
            port: NWEndpoint.Port(rawValue: audioPort)!,
            using: audioParams
        )
        
        print("[Session] 🌐 Network config: Video=interactiveVideo, Audio=interactiveVoice")
        
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
        print("[Session] Starting video receive loop v10.3 (zero-copy + packet loss detection)")
        
        // Update both decryptors with session key
        streamingDecryptor.setKey(sessionKey)
        zeroCopyDecryptor.setKey(sessionKey)
        
        // Reset packet loss detector
        videoPacketLossDetector.reset()
        
        var frameCounter: UInt64 = 0
        
        while state == .streaming && !Task.isCancelled {
            if let videoConnection = videoConnection {
                do {
                    // Receive raw UDP data
                    let data = try await receiveUDP(from: videoConnection)
                    
                    // v10.3: Extract sequence number from packet header (first 4 bytes)
                    // PS5 Remote Play packets typically have: [4 bytes seq][4 bytes pts][payload]
                    var needsIDR = false
                    if data.count >= 4 {
                        let sequence = data.withUnsafeBytes { ptr -> UInt32 in
                            ptr.load(as: UInt32.self)
                        }
                        
                        // Check for packet loss
                        if videoPacketLossDetector.processPacket(sequence: sequence) {
                            needsIDR = true
                        }
                    }
                    
                    // Request IDR frame if loss detected (with rate limiting)
                    if needsIDR {
                        await requestIDRFrame()
                    }
                    
                    // v10.3: Use zero-copy decryptor for best performance
                    if let decryptedBuffer = zeroCopyDecryptor.decrypt(data: data) {
                        defer { decryptedBuffer.release() }
                        
                        packetsReceived += 1
                        frameCounter += 1
                        
                        // Decode video frame using zero-copy data view
                        try videoDecoder.decode(decryptedBuffer.dataView)
                        
                        // Callback for raw data processing (optional)
                        onVideoFrame?(decryptedBuffer.dataView)
                        
                        // Log pool stats periodically
                        if frameCounter % 1000 == 0 {
                            print("[Session] \(networkBufferPool.statistics)")
                            print("[Session] \(zeroCopyDecryptor.statistics)")
                            print("[Session] \(videoPacketLossDetector.statistics)")
                        }
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
        print("[Session] Final \(zeroCopyDecryptor.statistics)")
        print("[Session] Final \(videoPacketLossDetector.statistics)")
    }
    
    /// Request an IDR frame (keyframe) from the console.
    /// Called when packet loss is detected to quickly clear visual artifacts.
    private func requestIDRFrame() async {
        // Rate limit IDR requests to avoid flooding
        let now = mach_absolute_time()
        guard now - lastIDRRequestTime > minIDRRequestIntervalNs else {
            return
        }
        lastIDRRequestTime = now
        
        print("[Session] 📺 Requesting IDR frame (packet loss recovery)")
        
        // Send IDR request packet to console
        // Payload: [1 byte reason] where 0x01 = packet loss
        let payload = Data([0x01])
        sendControlPacket(type: .idrRequest, payload: payload)
    }
    
    private func audioReceiveLoop() async {
        print("[Session] Starting audio receive loop (buffer pooling enabled)")
        
        // Create audio-specific decryptor with audio buffer pool
        let audioDecryptor = StreamingDecryptor(bufferPool: audioBufferPool)
        audioDecryptor.setKey(sessionKey)
        
        // v10.3: Track audio packets for drift statistics
        var audioPacketCount: UInt64 = 0
        var lastDriftLogTime: UInt64 = 0
        
        while state == .streaming && !Task.isCancelled {
            if let audioConnection = audioConnection {
                do {
                    let data = try await receiveUDP(from: audioConnection)
                    
                    // Decrypt using pooled buffers
                    if let decryptedBuffer = audioDecryptor.decrypt(data) {
                        defer { decryptedBuffer.release() }
                        
                        audioPacketCount += 1
                        
                        // v10.3: Extract PTS from audio packet header (if present)
                        // Opus packets from PS5 typically have 8-byte header: [4 bytes seq][4 bytes pts]
                        let audioData = decryptedBuffer.data
                        if audioData.count >= 8 {
                            let pts = audioData.withUnsafeBytes { ptr -> Double in
                                let ptsRaw = ptr.load(fromByteOffset: 4, as: UInt32.self)
                                // Convert to seconds (90kHz clock typical for media)
                                return Double(ptsRaw) / 90000.0
                            }
                            
                            // Update A/V sync controller with audio PTS
                            avSyncController.onAudioPacketReceived(pts: pts)
                            
                            // Check for drift and log periodically
                            if audioPacketCount % 100 == 0 {
                                let driftMs = avSyncController.driftCorrector.calculateDriftMs()
                                
                                // Log if significant drift detected
                                if abs(driftMs) > 20.0 {
                                    let now = mach_absolute_time()
                                    if now - lastDriftLogTime > 1_000_000_000 { // 1 second
                                        print("[Session] ⚠️ A/V drift: \(String(format: "%+.1f", driftMs))ms")
                                        lastDriftLogTime = now
                                    }
                                }
                            }
                        }
                        
                        // Decode and play audio
                        audioDecoder.decodeAndPlay(audioData)
                        
                        // Callback for additional processing
                        onAudioFrame?(audioData)
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
        print("[Session] Final \(audioBufferPool.statistics)")
        
        // v10.3: Log final A/V sync statistics
        let stats = avSyncController.driftCorrector.stats
        print("[Session] A/V Sync: corrections=\(stats.correctionCount), skipped=\(stats.samplesSkipped), duplicated=\(stats.samplesDuplicated), emergencyDrops=\(stats.emergencyDrops)")
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
    case idrRequest = 0x08       // v10.3: Request IDR frame (keyframe) after packet loss
    case qualityReport = 0x09    // v10.3: Report network quality metrics
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

// MARK: - v10.3 Packet Loss Detector

/// Detects packet loss by tracking sequence numbers.
/// When gaps are detected, triggers callback for recovery (e.g., IDR request).
final class PacketLossDetector: @unchecked Sendable {
    
    // MARK: - Configuration
    
    /// Name for logging
    let streamName: String
    
    /// Maximum allowed sequence gap before triggering loss detection
    /// Small gaps (1-2) might be reordering, larger gaps indicate loss
    var maxAllowedGap: UInt32 = 3
    
    /// Threshold of consecutive losses before triggering recovery
    var lossThresholdForRecovery: Int = 2
    
    // MARK: - State
    
    /// Last received sequence number
    private var lastSequence: UInt32 = 0
    
    /// Whether we've received the first packet
    private var initialized = false
    
    /// Lock for thread-safety
    private let lock = NSLock()
    
    // MARK: - Statistics
    
    /// Total packets received
    private var packetsReceived: UInt64 = 0
    
    /// Total packets lost (estimated)
    private var packetsLost: UInt64 = 0
    
    /// Consecutive losses (resets on good packet)
    private var consecutiveLosses: Int = 0
    
    /// Number of loss events triggered
    private var lossEvents: Int = 0
    
    /// Last loss event time
    private var lastLossTime: UInt64 = 0
    
    // MARK: - Initialization
    
    init(streamName: String) {
        self.streamName = streamName
    }
    
    // MARK: - Sequence Tracking
    
    /// Process an incoming packet and check for loss.
    /// - Parameter sequence: The sequence number from the packet header
    /// - Returns: True if packet loss was detected and recovery is needed
    func processPacket(sequence: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        packetsReceived += 1
        
        // First packet - initialize
        if !initialized {
            lastSequence = sequence
            initialized = true
            return false
        }
        
        // Calculate expected sequence (handles wrap-around at UInt32.max)
        let expectedSequence = lastSequence &+ 1
        
        // Check for sequence gap
        let gap: Int
        if sequence >= expectedSequence {
            gap = Int(sequence - expectedSequence)
        } else if expectedSequence - sequence > UInt32.max / 2 {
            // Sequence number wrapped around
            gap = Int(UInt32.max - expectedSequence + sequence + 1)
        } else {
            // Out of order (old packet arrived late) - ignore
            return false
        }
        
        // Update last sequence
        lastSequence = sequence
        
        // No gap - reset consecutive losses
        if gap == 0 {
            consecutiveLosses = 0
            return false
        }
        
        // Gap detected - potential packet loss
        if gap <= Int(maxAllowedGap) {
            // Small gap - might be reordering, track but don't trigger yet
            packetsLost += UInt64(gap)
            consecutiveLosses += gap
            
            if consecutiveLosses >= lossThresholdForRecovery {
                return triggerLossEvent(gap: gap)
            }
            return false
        }
        
        // Large gap - definite packet loss
        packetsLost += UInt64(gap)
        consecutiveLosses += gap
        return triggerLossEvent(gap: gap)
    }
    
    private func triggerLossEvent(gap: Int) -> Bool {
        lossEvents += 1
        lastLossTime = mach_absolute_time()
        
        let lossRate = packetsReceived > 0 ? Double(packetsLost) / Double(packetsReceived + packetsLost) * 100 : 0
        print("[\(streamName)PacketLoss] ⚠️ Gap=\(gap), Total lost=\(packetsLost), Rate=\(String(format: "%.2f", lossRate))%")
        
        // Reset consecutive counter
        consecutiveLosses = 0
        
        return true
    }
    
    // MARK: - Utilities
    
    /// Get loss rate as percentage
    var lossRate: Double {
        lock.lock()
        defer { lock.unlock() }
        let total = packetsReceived + packetsLost
        guard total > 0 else { return 0 }
        return Double(packetsLost) / Double(total) * 100
    }
    
    /// Get statistics string
    var statistics: String {
        lock.lock()
        defer { lock.unlock() }
        return "[\(streamName)] recv=\(packetsReceived) lost=\(packetsLost) events=\(lossEvents) rate=\(String(format: "%.2f", lossRate))%"
    }
    
    /// Reset detector state
    func reset() {
        lock.lock()
        initialized = false
        lastSequence = 0
        packetsReceived = 0
        packetsLost = 0
        consecutiveLosses = 0
        lock.unlock()
    }
}

