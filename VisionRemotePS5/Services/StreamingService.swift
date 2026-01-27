//
//  StreamingService.swift
//  VisionRemotePS5
//
//  Service responsible for PS5 video streaming using ChiakiSession
//

import Foundation
import Network
import VideoToolbox
import AVFoundation
import QuartzCore  // v10.1: For CACurrentMediaTime monotonic clock

// MARK: - Streaming Configuration

struct StreamingConfiguration {
    let host: String
    let rpKey: Data           // 16 bytes from registration
    let registKey: String     // From registration
    let psnAccountID: Data    // 8 bytes
    let isPS5: Bool
    
    // Video settings
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    
    static func defaultPS5Config(host: String, rpKey: Data, registKey: String, psnAccountID: Data) -> StreamingConfiguration {
        return StreamingConfiguration(
            host: host,
            rpKey: rpKey,
            registKey: registKey,
            psnAccountID: psnAccountID,
            isPS5: true,
            width: 1920,
            height: 1080,
            fps: 60,
            bitrate: 15000
        )
    }
}

// MARK: - Session State

enum StreamingState: Equatable {
    case idle
    case connecting
    case requestingSession
    case negotiating
    case streaming
    case error(String)
    case stopped
}

// MARK: - Streaming Delegate Protocol

protocol StreamingServiceDelegate: AnyObject {
    func streamingService(_ service: StreamingService, didChangeState state: StreamingState)
    func streamingService(_ service: StreamingService, didReceiveVideoFrame frame: CVPixelBuffer, timestamp: UInt64)
    func streamingService(_ service: StreamingService, didReceiveAudioData data: Data, sampleRate: Int, channels: Int)
    func streamingService(_ service: StreamingService, didReceiveError error: Error)
}

// MARK: - Streaming Errors

enum StreamingError: LocalizedError {
    case connectionFailed(String)
    case sessionRequestFailed(String)
    case negotiationFailed(String)
    case decodingFailed(String)
    case invalidConfiguration
    case alreadyStreaming
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sessionRequestFailed(let msg): return "Session request failed: \(msg)"
        case .negotiationFailed(let msg): return "Negotiation failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .invalidConfiguration: return "Invalid streaming configuration"
        case .alreadyStreaming: return "Already streaming"
        case .notConnected: return "Not connected to console"
        }
    }
}

// MARK: - Streaming Service

@MainActor
final class StreamingService: ObservableObject {
    
    // MARK: - Properties
    
    static let shared = StreamingService()
    
    @Published private(set) var state: StreamingState = .idle
    @Published private(set) var isStreaming = false
    
    // Debug counters
    private var videoFrameCount: Int = 0
    
    // v10.1: Buffer exhaustion tracking for anti-smearing recovery
    private var lastBufferExhaustionTime: CFTimeInterval?
    private var bufferExhaustionCount: Int = 0
    
    weak var delegate: StreamingServiceDelegate?
    
    private var configuration: StreamingConfiguration?
    private var ctrlConnection: NWConnection?
    private var streamConnection: NWConnection?
    private var ctrlQueue = DispatchQueue(label: "ctrl.queue", qos: .userInteractive)
    private var streamQueue = DispatchQueue(label: "stream.queue", qos: .userInteractive)
    
    // Dedicated video processing queue - NEVER use main thread for decoding!
    // This queue handles: NAL parsing -> VideoToolbox decode -> MetalFX upscale
    private let videoProcessingQueue = DispatchQueue(
        label: "com.visionremoteps5.video.processing",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    // Session data
    private var sessionID: String?
    private var handshakeKey: Data?
    private var mtuIn: UInt32 = 1454
    private var mtuOut: UInt32 = 1454
    
    // Video decoder
    private var videoDecoder: StreamVideoDecoder?
    
    // Safe buffer pool for video frames (fixes zero-copy race condition)
    // VTDecompressionSession is async - we can't pass network buffer pointers directly
    // v8.0: Use 4MB buffers to handle extreme 4K HDR I-frames without drops
    private lazy var videoBufferPool = SafeBufferPool(
        poolSize: 12,           // 12 buffers = ~200ms at 60fps
        bufferCapacity: SafeBufferPool.defaultBufferCapacity  // 4MB per buffer
    )
    
    // Audio player
    private var audioPlayer: LowLatencyAudioPlayer?
    
    // Controller state
    private var controllerState = ControllerState()
    
    // Controller manager for haptics
    private var controllerManager: GameControllerManager?
    
    // Frame pacer for smooth 60fps on 90Hz display
    private var framePacer: FramePacer?
    
    // MARK: - Ports
    
    private let ctrlPort: UInt16 = 9295
    private let streamPort: UInt16 = 9296
    
    // MARK: - Initialization
    
    private init() {
        print("[StreamingService] Initialized")
    }
    
    // MARK: - Public Methods
    
    func startStreaming(configuration: StreamingConfiguration) async throws {
        guard state == .idle || state == .stopped else {
            throw StreamingError.alreadyStreaming
        }
        
        guard configuration.rpKey.count == 16 else {
            throw StreamingError.invalidConfiguration
        }
        
        self.configuration = configuration
        
        await MainActor.run {
            self.state = .connecting
            self.delegate?.streamingService(self, didChangeState: .connecting)
        }
        
        print("[StreamingService] Starting streaming to \(configuration.host)")
        print("[StreamingService] RP-Key: \(configuration.rpKey.hexString)")
        
        // WAKEUP: Send wakeup packet first (PS5 might be in standby)
        // The PS5 refuses connections on port 9295 when in standby mode.
        // We need to wake it first, then wait a bit for it to become ready.
        await wakeupConsoleIfNeeded(configuration: configuration)
        
        // Use ChiakiFullSession (chiaki-ng library)
        try await startStreamingV2()
    }
    
    /// Send wakeup packet to console if it might be in standby
    private func wakeupConsoleIfNeeded(configuration: StreamingConfiguration) async {
        // Parse registKey to Data for wakeup
        let registKeyData = parseRegistKey(configuration.registKey)
        
        guard !registKeyData.isEmpty else {
            print("[StreamingService] ⚠️ No registKey for wakeup, skipping")
            return
        }
        
        print("[StreamingService] 📢 Sending WAKEUP packet to \(configuration.host)...")
        
        let success = await WakeOnLanService.shared.wakeConsole(
            host: configuration.host,
            registKey: registKeyData,
            isPS5: configuration.isPS5
        )
        
        if success {
            print("[StreamingService] ✅ WAKEUP sent successfully")
            // Wait for console to wake up and become ready
            // PS5 typically needs 3-5 seconds to wake from standby
            print("[StreamingService] ⏳ Waiting 4 seconds for console to wake up...")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            print("[StreamingService] ✅ Wake delay complete, proceeding with connection...")
        } else {
            print("[StreamingService] ⚠️ WAKEUP failed, attempting connection anyway...")
        }
    }
    
    /// Start streaming using chiaki-ng library (V2)
    private func startStreamingV2() async throws {
        guard let config = configuration else {
            throw StreamingError.invalidConfiguration
        }
        
        print("[StreamingService] Using ChiakiFullSession for streaming")
        
        await MainActor.run {
            self.state = .negotiating
            self.delegate?.streamingService(self, didChangeState: .negotiating)
        }
        
        // Setup callbacks
        setupChiakiCallbacks()
        
        // Initialize video decoder (HEVC for PS5)
        videoDecoder = StreamVideoDecoder(width: config.width, height: config.height, isHEVC: config.isPS5)
        videoDecoder?.start()
        
        // Initialize audio player (48kHz stereo PCM from chiaki)
        // v10.0: Stereo Emitter Array with closed-loop A/V sync
        audioPlayer = LowLatencyAudioPlayer(sampleRate: 48000, channels: 2)
        
        // v10.0: Set initial A/V sync target (will be dynamically updated by video callback)
        // Closed-loop sync: audio chases MEASURED video latency, not fixed estimate
        audioPlayer?.setTargetLatency(milliseconds: 40.0)  // Initial estimate
        audioPlayer?.start()
        
        // Initialize controller manager for haptic feedback
        // v10.1: Wire up 120Hz input callback for true decoupled input transmission
        Task { @MainActor in
            self.controllerManager = GameControllerManager()
            
            // v10.1: TRUE 120Hz INPUT - Decoupled from video callback
            // The GameControllerManager polls at 120Hz (8.33ms) and directly sends
            // input to ChiakiFullSession on every poll cycle, bypassing Combine throttling
            self.controllerManager?.onInputReady = { [weak self] input in
                guard let self = self, self.isStreaming else { return }
                
                // Send directly to ChiakiFullSession at 120Hz - no throttling!
                ChiakiFullSession.shared.setControllerState(
                    buttons: input.buttons,
                    leftX: Int16(input.leftStickX * 32767),
                    leftY: Int16(input.leftStickY * 32767),
                    rightX: Int16(input.rightStickX * 32767),
                    rightY: Int16(input.rightStickY * 32767),
                    l2: UInt8(input.leftTrigger * 255),
                    r2: UInt8(input.rightTrigger * 255)
                )
            }
            
            // Initialize frame pacer for smooth 60fps on 90Hz display
            self.framePacer = FramePacer()
            self.framePacer?.start()
        }
        
        // Parse registKey to binary (hex string -> Data)
        let registKeyData = parseRegistKey(config.registKey)
        
        // Ensure PSN Account ID is 8 bytes
        var psnAccountIDPadded = config.psnAccountID
        if psnAccountIDPadded.count < 8 {
            psnAccountIDPadded.append(contentsOf: [UInt8](repeating: 0, count: 8 - psnAccountIDPadded.count))
        } else if psnAccountIDPadded.count > 8 {
            psnAccountIDPadded = psnAccountIDPadded.prefix(8)
        }
        
        print("[StreamingService] Starting ChiakiFullSession...")
        print("[StreamingService]   Host: \(config.host)")
        print("[StreamingService]   RegistKey: \(registKeyData.hexString)")
        print("[StreamingService]   RP-Key: \(config.rpKey.hexString)")
        print("[StreamingService]   PSN ID: \(psnAccountIDPadded.hexString)")
        
        let success = ChiakiFullSession.shared.start(
            host: config.host,
            registKey: registKeyData,
            rpKey: config.rpKey,
            psnAccountID: psnAccountIDPadded,
            width: UInt32(config.width),
            height: UInt32(config.height),
            fps: UInt32(config.fps),
            bitrate: UInt32(config.bitrate),  // kbps - PS5 protocol expects kbps!
            isPS5: config.isPS5
        )
        
        if success {
            print("[StreamingService] ✅ ChiakiFullSession started, waiting for connection...")
            // Set streaming flag immediately so controller input works
            // The event callback will also set it when connected event fires
            Task { @MainActor in
                self.isStreaming = true
                self.state = .streaming
                // v10.4 FIX: Notify delegate so UI updates from "Negotiating..." to video display
                self.delegate?.streamingService(self, didChangeState: .streaming)
                print("[StreamingService] 🎮 Controller input now enabled")
            }
        } else {
            throw StreamingError.connectionFailed("ChiakiFullSession.start() failed")
        }
    }
    
    /// Setup callbacks from ChiakiFullSession
    private func setupChiakiCallbacks() {
        // SAFE VIDEO PATH: Copy network buffer to safe pool before async decoding
        // This fixes the race condition where VTDecompressionSession reads data
        // after the network thread has overwritten the buffer.
        ChiakiFullSession.shared.onVideoFramePointer = { [weak self] pointer, size in
            guard let self = self else { return }
            
            // v10.0: Record frame receive timestamp for closed-loop A/V sync
            // v10.1: Use monotonic clock to prevent sync drift from NTP adjustments
            let frameReceiveTime = CACurrentMediaTime()
            
            // CRITICAL: Acquire a safe buffer and copy the network data immediately
            // This must happen synchronously before returning from the callback!
            guard let safeBuffer = self.videoBufferPool.acquireAndCopy(from: pointer, count: size) else {
                // v10.1: Buffer pool exhaustion recovery (Anti-Smearing)
                // When pool is exhausted, dropped frames corrupt the video until next keyframe.
                // We implement debounced logging and mark decoder for format reset on next IDR.
                
                // Debounce: Only log once per second to avoid log spam
                let now = CACurrentMediaTime()
                if self.lastBufferExhaustionTime == nil || (now - self.lastBufferExhaustionTime!) > 1.0 {
                    self.lastBufferExhaustionTime = now
                    self.bufferExhaustionCount += 1
                    print("[StreamingService] ⚠️ Buffer pool exhausted! Frames dropped: \(self.bufferExhaustionCount)")
                    
                    // Mark decoder for recovery - will wait for next IDR frame
                    // This clears format description to prevent smearing from corrupted reference frames
                    self.videoDecoder?.markForRecovery()
                }
                return
            }
            
            guard let decoder = self.videoDecoder else {
                self.videoBufferPool.release(safeBuffer)
                return
            }
            
            // Track frame count for logging
            self.videoFrameCount += 1
            let frameNum = self.videoFrameCount
            if frameNum % 60 == 1 {
                print("[StreamingService] 📹 Video frame #\(frameNum) received (safe copy), size: \(size) bytes")
                self.videoBufferPool.logStats()
            }
            
            // Now decode from the SAFE buffer
            // The buffer won't be released until the completion handler runs
            decoder.decodeFromSafeBuffer(safeBuffer) { [weak self] pixelBuffer, timestamp in
                guard let self = self else {
                    // Still need to release the buffer even if self is nil
                    self?.videoBufferPool.release(safeBuffer)
                    return
                }
                
                // Release buffer back to pool AFTER decoding completes
                self.videoBufferPool.release(safeBuffer)
                
                guard let pb = pixelBuffer else { return }
                
                // v10.0: Calculate measured video latency (closed-loop A/V sync)
                // This is the actual time from frame receive to decode completion
                // v10.1: Monotonic clock for accurate latency measurement
                let decodeCompleteTime = CACurrentMediaTime()
                let decodeLatencyMs = (decodeCompleteTime - frameReceiveTime) * 1000
                
                // Estimate total video pipeline latency:
                // decode (measured) + upscale (~5-10ms) + display (dynamic based on refresh rate)
                let estimatedUpscaleMs = 8.0
                // v10.1: Dynamic display frame duration based on actual refresh rate
                // Vision Pro = 90Hz (~11.1ms), fallback to 60Hz (~16.7ms) if unknown
                #if os(visionOS)
                // visionOS runs at 90Hz
                let displayRefreshRate: Double = 90.0
                #else
                let displayRefreshRate: Double = Double(UIScreen.main.maximumFramesPerSecond)
                #endif
                let estimatedDisplayMs = displayRefreshRate > 0 ? (1000.0 / displayRefreshRate) : 16.7
                let totalVideoLatencyMs = decodeLatencyMs + estimatedUpscaleMs + estimatedDisplayMs
                
                // Update audio target to chase measured video latency
                if let player = self.audioPlayer {
                    player.updateDynamicTarget(measuredLatencyMs: totalVideoLatencyMs)
                }
                
                if frameNum % 60 == 1 {
                    print("[StreamingService] ✅ Frame #\(frameNum) decoded safely")
                    print("[StreamingService] 🎯 v10.0 Closed-loop sync: decode=\(String(format: "%.1f", decodeLatencyMs))ms, total=\(String(format: "%.0f", totalVideoLatencyMs))ms")
                }
                
                // Notify delegate on main thread
                Task { @MainActor in
                    self.delegate?.streamingService(self, didReceiveVideoFrame: pb, timestamp: timestamp)
                }
            }
        }
        
        ChiakiFullSession.shared.onAudioSamples = { [weak self] (data: Data, sampleCount: Int) in
            guard let self = self else { return }
            
            // Feed PCM samples to low-latency audio player (enqueue to ring buffer)
            if let player = self.audioPlayer {
                player.enqueueSamples(data, sampleCount: sampleCount)
            }
            
            // Notify delegate
            self.delegate?.streamingService(self, didReceiveAudioData: data, sampleRate: 48000, channels: 2)
        }
        
        ChiakiFullSession.shared.onEvent = { [weak self] event, reason in
            guard let self = self else { return }
            
            print("[StreamingService] ChiakiEvent: \(event), reason: \(reason ?? "none")")
            
            switch event {
            case .connected:
                print("[StreamingService] ✅ Connected via ChiakiFullSession!")
                Task { @MainActor in
                    self.isStreaming = true
                    self.state = .streaming
                    self.delegate?.streamingService(self, didChangeState: .streaming)
                }
                
            case .quit:
                print("[StreamingService] ❌ Session quit: \(reason ?? "unknown")")
                Task { @MainActor in
                    self.isStreaming = false
                    self.state = .stopped
                    self.delegate?.streamingService(self, didChangeState: .stopped)
                }
                
            default:
                break
            }
        }
        
        // Setup rumble callback for haptic feedback
        ChiakiFullSession.shared.onRumble = { [weak self] left, right in
            guard let self = self else { return }
            
            // Trigger haptic feedback on connected controller
            Task { @MainActor in
                self.controllerManager?.triggerRumble(left: left, right: right)
            }
        }
    }
    
    /// Parse registKey string to Data for chiaki session
    /// Chiaki session.c:901 does format_hex() on regist_key before sending to HTTP header
    /// So we MUST pass the actual binary bytes (hex-decoded), NOT ASCII characters
    private func parseRegistKey(_ registKey: String) -> Data {
        // registKey is stored as hex string (e.g. "1ffbf7538663735")
        // We need to decode it to binary bytes
        var data = Data()
        var hex = registKey
        
        // Pad with zeros if needed on the right
        while hex.count < 16 {
            hex.append("0")
        }
        
        // Take first 16 characters (8 bytes when decoded)
        // But chiaki expects 16 bytes, so we take 32 hex chars
        // If the string is shorter, we pad with ascii zeros (0x30 = '0')
        let hexPrefix = String(hex.prefix(32))
        
        // If it looks like hex, decode it
        if hexPrefix.allSatisfy({ $0.isHexDigit }) && hexPrefix.count >= 2 {
            var index = hexPrefix.startIndex
            while index < hexPrefix.endIndex {
                let endIndex = hexPrefix.index(index, offsetBy: min(2, hexPrefix.distance(from: index, to: hexPrefix.endIndex)))
                if let byte = UInt8(hexPrefix[index..<endIndex], radix: 16) {
                    data.append(byte)
                }
                if endIndex < hexPrefix.endIndex {
                    index = endIndex
                } else {
                    break
                }
            }
        }
        
        // Pad to 16 bytes with zeros if needed
        while data.count < 16 {
            data.append(0)
        }
        
        return data.prefix(16)
    }
    
    func stopStreaming() {
        print("[StreamingService] Stopping streaming...")
        
        // Stop ChiakiFullSession if active
        if ChiakiFullSession.shared.isActive {
            ChiakiFullSession.shared.stop()
        }
        
        ctrlConnection?.cancel()
        streamConnection?.cancel()
        ctrlConnection = nil
        streamConnection = nil
        
        videoDecoder?.stop()
        audioPlayer?.stop()
        framePacer?.stop()
        framePacer = nil
        
        sessionID = nil
        handshakeKey = nil
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.state = .stopped
            self.delegate?.streamingService(self, didChangeState: .stopped)
        }
        
        print("[StreamingService] Streaming stopped")
    }
    
    // MARK: - Controller Input
    
    func setControllerState(_ state: ControllerState) {
        self.controllerState = state
        sendControllerState()
    }
    
    func pressButton(_ button: ControllerButton) {
        controllerState.buttons.insert(button)
        sendControllerState()
    }
    
    func releaseButton(_ button: ControllerButton) {
        controllerState.buttons.remove(button)
        sendControllerState()
    }
    
    func setLeftStick(x: Int16, y: Int16) {
        controllerState.leftX = x
        controllerState.leftY = y
        sendControllerState()
    }
    
    func setRightStick(x: Int16, y: Int16) {
        controllerState.rightX = x
        controllerState.rightY = y
        sendControllerState()
    }
    
    // MARK: - Private Methods - Connection
    
    private func connectCtrl() async throws {
        guard let config = configuration else {
            throw StreamingError.invalidConfiguration
        }
        
        print("[StreamingService] Connecting to CTRL port \(ctrlPort)...")
        
        return try await withCheckedThrowingContinuation { continuation in
            let host = NWEndpoint.Host(config.host)
            let port = NWEndpoint.Port(rawValue: ctrlPort)!
            
            let connection = NWConnection(host: host, port: port, using: .tcp)
            self.ctrlConnection = connection
            
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[StreamingService] ✅ CTRL connected")
                    continuation.resume()
                case .failed(let error):
                    print("[StreamingService] ❌ CTRL connection failed: \(error)")
                    continuation.resume(throwing: StreamingError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    print("[StreamingService] CTRL connection cancelled")
                default:
                    break
                }
            }
            
            connection.start(queue: ctrlQueue)
        }
    }
    
    private func requestSession() async throws {
        guard let config = configuration, let ctrl = ctrlConnection else {
            throw StreamingError.notConnected
        }
        
        await MainActor.run {
            self.state = .requestingSession
            self.delegate?.streamingService(self, didChangeState: .requestingSession)
        }
        
        print("[StreamingService] Requesting session...")
        
        // Step 1: Request session init to get nonce from PS5
        let nonce = try await requestSessionInit(config: config, connection: ctrl)
        
        // Step 2: Request session ctrl with encrypted headers using PS5's nonce
        try await requestSessionCtrl(config: config, connection: ctrl, nonce: nonce)
        
        print("[StreamingService] ✅ Session request successful")
    }
    
    /// Step 1: Session Init - Get nonce from PS5
    private func requestSessionInit(config: StreamingConfiguration, connection: NWConnection) async throws -> Data {
        print("[StreamingService] Step 1: Requesting session init...")
        
        // Build RP-Registkey from registKey (NOT rpKey!)
        // registKey is already hex string from registration response
        let registKeyHex: String
        if config.registKey.isEmpty {
            // Fallback to rpKey hex if registKey not available
            registKeyHex = config.rpKey.map { String(format: "%02x", $0) }.joined()
            print("[StreamingService] RP-Registkey (fallback to rpKey hex): \(registKeyHex)")
        } else {
            registKeyHex = config.registKey
            print("[StreamingService] RP-Registkey (from registKey): \(registKeyHex)")
        }
        
        // Format matches chiaki-ng session_request_fmt
        var headers = "GET /sie/ps5/rp/sess/init HTTP/1.1\r\n"
        headers += "Host: \(config.host):\(ctrlPort)\r\n"
        headers += "User-Agent: remoteplay Windows\r\n"
        headers += "Connection: close\r\n"
        headers += "Content-Length: 0\r\n"
        headers += "RP-Registkey: \(registKeyHex)\r\n"
        headers += "Rp-Version: 1.0\r\n"
        headers += "\r\n"
        
        print("[StreamingService] Session init headers:\n\(headers)")
        
        let requestData = headers.data(using: .utf8)!
        
        // Send init request
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: StreamingError.sessionRequestFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
        
        // Receive response
        let response = try await receiveData(from: connection, maxLength: 4096)
        
        guard let responseStr = String(data: response, encoding: .utf8) else {
            throw StreamingError.sessionRequestFailed("Invalid response encoding")
        }
        
        print("[StreamingService] Session init response: \(responseStr.prefix(500))")
        
        // Check for success
        guard responseStr.contains("200") else {
            if let reasonRange = responseStr.range(of: "RP-Application-Reason: ") {
                let reasonStart = reasonRange.upperBound
                let reasonEnd = responseStr[reasonStart...].firstIndex(of: "\r") ?? responseStr.endIndex
                let reason = String(responseStr[reasonStart..<reasonEnd])
                throw StreamingError.sessionRequestFailed("Init rejected: \(reason)")
            }
            throw StreamingError.sessionRequestFailed("HTTP error in init response")
        }
        
        // Extract nonce from response (RP-Nonce header, base64 encoded)
        // Parse headers line by line for robustness
        var nonceBase64: String?
        
        // Split by various line endings and find RP-Nonce header
        let lines = responseStr.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("RP-Nonce:") {
                let value = trimmedLine.dropFirst("RP-Nonce:".count).trimmingCharacters(in: .whitespaces)
                nonceBase64 = value
                break
            }
        }
        
        guard let nonce64 = nonceBase64, !nonce64.isEmpty else {
            throw StreamingError.sessionRequestFailed("No RP-Nonce in response")
        }
        
        print("[StreamingService] Extracted nonce base64: '\(nonce64)'")
        
        guard let nonceData = Data(base64Encoded: nonce64), nonceData.count == 16 else {
            throw StreamingError.sessionRequestFailed("Invalid RP-Nonce: '\(nonce64)' (length: \(nonce64.count))")
        }
        
        print("[StreamingService] ✅ Session init successful")
        print("[StreamingService] Received nonce: \(nonceData.map { String(format: "%02x", $0) }.joined())")
        
        return nonceData
    }
    
    /// Step 2: Session Ctrl - Establish session with encrypted headers
    private func requestSessionCtrl(config: StreamingConfiguration, connection: NWConnection, nonce: Data) async throws {
        print("[StreamingService] Step 2: Requesting session ctrl with encrypted headers...")
        
        // Wait a bit before creating new connection (PS5 needs time to process closed init)
        print("[StreamingService] Waiting before ctrl connection...")
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        
        // Create a NEW connection for ctrl (init connection was closed with Connection: close)
        print("[StreamingService] Creating new connection for session ctrl...")
        let ctrlConnection = try await createNewConnection(host: config.host, port: ctrlPort)
        defer {
            // Close this connection when done if needed
            // ctrlConnection.cancel()
        }
        print("[StreamingService] ✅ New ctrl connection established")
        
        // Generate device ID in chiaki-ng format:
        // [10 bytes prefix] + [16 bytes random] + [6 bytes suffix] = 32 bytes
        let didPrefix: [UInt8] = [0x00, 0x18, 0x00, 0x00, 0x00, 0x07, 0x00, 0x40, 0x00, 0x80]
        let didSuffix: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        var deviceId = Data(count: 32)
        deviceId.replaceSubrange(0..<10, with: didPrefix)
        // Random 16 bytes in the middle (bytes 10-25)
        var randomBytes = Data(count: 16)
        _ = randomBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        deviceId.replaceSubrange(10..<26, with: randomBytes)
        // Suffix at end (bytes 26-31)
        deviceId.replaceSubrange(26..<32, with: didSuffix)
        
        print("[StreamingService] Device ID: \(deviceId.map { String(format: "%02x", $0) }.joined())")
        
        // Use registKey from config (hex string), or fallback to RP-Key hex if empty
        var effectiveRegistKeyHex = config.registKey
        if effectiveRegistKeyHex.isEmpty {
            effectiveRegistKeyHex = config.rpKey.map { String(format: "%02x", $0) }.joined()
            print("[StreamingService] RegistKey empty, using RP-Key hex: \(effectiveRegistKeyHex)")
        }
        
        // Convert hex string to binary Data (16 bytes, padded with zeros)
        var registKeyData = Data(count: 16)
        let hexChars = Array(effectiveRegistKeyHex)
        for i in stride(from: 0, to: min(hexChars.count, 32), by: 2) {
            if let byte = UInt8(String(hexChars[i..<min(i+2, hexChars.count)]), radix: 16) {
                registKeyData[i / 2] = byte
            }
        }
        print("[StreamingService] RegistKey Data: \(registKeyData.map { String(format: "%02x", $0) }.joined())")
        
        // Generate encrypted session headers using C-core with PS5's nonce
        let sessionHeaders: ChiakiBridgeService.SessionHeaders
        do {
            sessionHeaders = try ChiakiBridgeService.shared.generateSessionHeaders(
                target: .ps5_1,
                nonce: nonce,  // Use nonce from PS5!
                rpKey: config.rpKey,
                registKey: registKeyData,  // Now passing binary Data
                deviceId: deviceId
            )
        } catch {
            print("[StreamingService] ❌ Failed to generate session headers: \(error)")
            throw StreamingError.sessionRequestFailed("Failed to generate encrypted headers: \(error)")
        }
        
        // Build session ctrl request with encrypted headers
        var headers = "GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\n"
        headers += "Host: \(config.host):\(ctrlPort)\r\n"
        headers += "User-Agent: remoteplay Windows\r\n"
        headers += "Connection: keep-alive\r\n"
        headers += "Content-Length: 0\r\n"
        headers += "RP-Auth: \(sessionHeaders.rpAuth)\r\n"
        headers += "RP-Version: 1.0\r\n"
        headers += "RP-Did: \(sessionHeaders.rpDid)\r\n"
        headers += "RP-ControllerType: 3\r\n"
        headers += "RP-ClientType: 11\r\n"
        headers += "RP-OSType: \(sessionHeaders.rpOsType)\r\n"
        headers += "RP-ConPath: 1\r\n"
        headers += "RP-StartBitrate: \(sessionHeaders.rpStartBitrate)\r\n"
        headers += "RP-StreamingType: \(sessionHeaders.rpStreamingType)\r\n"
        headers += "\r\n"
        
        print("[StreamingService] Session ctrl headers:\n\(headers)")
        
        let requestData = headers.data(using: .utf8)!
        
        // Send ctrl request on the new connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ctrlConnection.send(content: requestData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: StreamingError.sessionRequestFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
        
        // Receive response from new connection
        let response = try await receiveData(from: ctrlConnection, maxLength: 4096)
        
        guard let responseStr = String(data: response, encoding: .utf8) else {
            throw StreamingError.sessionRequestFailed("Invalid response encoding")
        }
        
        print("[StreamingService] Session ctrl response: \(responseStr.prefix(500))")
        
        // Parse response
        if !responseStr.contains("200") {
            if let reasonRange = responseStr.range(of: "RP-Application-Reason: ") {
                let reasonStart = reasonRange.upperBound
                let reasonEnd = responseStr[reasonStart...].firstIndex(of: "\r") ?? responseStr.endIndex
                let reason = String(responseStr[reasonStart..<reasonEnd])
                throw StreamingError.sessionRequestFailed("Ctrl rejected: \(reason)")
            }
            throw StreamingError.sessionRequestFailed("HTTP error in ctrl response")
        }
        
        // Extract session ID from response
        if let sidRange = responseStr.range(of: "RP-Session-Id: ") {
            let sidStart = sidRange.upperBound
            let sidEnd = responseStr[sidStart...].firstIndex(of: "\r") ?? responseStr.endIndex
            self.sessionID = String(responseStr[sidStart..<sidEnd])
            print("[StreamingService] Session ID: \(self.sessionID ?? "unknown")")
        }
        
        print("[StreamingService] ✅ Session ctrl successful")
    }
    
    /// Creates a new TCP connection to the specified host and port
    private func createNewConnection(host: String, port: UInt16) async throws -> NWConnection {
        let params = NWParameters.tcp
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            var hasResumed = false
            
            connection.stateUpdateHandler = { state in
                guard !hasResumed else { return }
                
                switch state {
                case .ready:
                    hasResumed = true
                    continuation.resume(returning: connection)
                case .failed(let error):
                    hasResumed = true
                    continuation.resume(throwing: StreamingError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    hasResumed = true
                    continuation.resume(throwing: StreamingError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            
            connection.start(queue: ctrlQueue)
        }
    }
    
    private func connectStream() async throws {
        guard let config = configuration else {
            throw StreamingError.invalidConfiguration
        }
        
        await MainActor.run {
            self.state = .negotiating
            self.delegate?.streamingService(self, didChangeState: .negotiating)
        }
        
        print("[StreamingService] Connecting to stream port \(streamPort)...")
        
        // Use UDP for stream connection
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        
        let host = NWEndpoint.Host(config.host)
        let port = NWEndpoint.Port(rawValue: streamPort)!
        
        // Connect and perform TAKION handshake
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NWConnection(host: host, port: port, using: params)
            self.streamConnection = connection
            
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[StreamingService] ✅ Stream connected (UDP)")
                    // Perform TAKION handshake before receiving
                    Task { @MainActor [weak self] in
                        do {
                            try await self?.performTakionHandshake()
                            self?.startReceivingStream()
                            continuation.resume()
                        } catch {
                            print("[StreamingService] ❌ TAKION handshake failed: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                case .failed(let error):
                    print("[StreamingService] ❌ Stream connection failed: \(error)")
                    continuation.resume(throwing: StreamingError.connectionFailed(error.localizedDescription))
                default:
                    break
                }
            }
            
            connection.start(queue: streamQueue)
        }
    }
    
    // MARK: - TAKION Handshake
    
    private var takionTagLocal: UInt32 = 0
    private var takionTagRemote: UInt32 = 0
    private var takionSeqNum: UInt32 = 0
    
    private func performTakionHandshake() async throws {
        guard let stream = streamConnection else {
            throw StreamingError.notConnected
        }
        
        // Generate random local tag (like chiaki)
        takionTagLocal = UInt32.random(in: 1...0xFFFFFFFF)
        takionSeqNum = takionTagLocal
        
        print("[StreamingService] Starting TAKION handshake (tag: \(String(format: "0x%08x", takionTagLocal)))...")
        
        // Step 1: Send INIT
        let initPacket = buildTakionInitPacket()
        try await sendUDPData(initPacket, on: stream)
        print("[StreamingService] Sent TAKION INIT packet (\(initPacket.count) bytes)")
        
        // Step 2: Wait for INIT_ACK
        let initAckData = try await receiveUDPData(on: stream, timeout: 5.0)
        let (remoteTag, cookie) = try parseTakionInitAck(initAckData)
        takionTagRemote = remoteTag
        print("[StreamingService] Received TAKION INIT_ACK (remote tag: \(String(format: "0x%08x", remoteTag)))")
        
        // Step 3: Send COOKIE
        let cookiePacket = buildTakionCookiePacket(cookie: cookie)
        try await sendUDPData(cookiePacket, on: stream)
        print("[StreamingService] Sent TAKION COOKIE packet")
        
        // Step 4: Wait for COOKIE_ACK (or first data packet)
        // Sometimes the server just starts sending data immediately
        print("[StreamingService] ✅ TAKION handshake complete!")
    }
    
    private func buildTakionInitPacket() -> Data {
        var packet = Data(count: 1 + 16 + 16) // type(1) + header(16) + payload(16) = 33 bytes
        
        // Byte 0: Packet type CONTROL (0x00)
        packet[0] = 0x00
        
        // Header starts at byte 1 (16 bytes total)
        // Bytes 1-4 (offset 0x00): Tag remote (0 since we don't know it yet)
        packet[1] = 0
        packet[2] = 0
        packet[3] = 0
        packet[4] = 0
        
        // Bytes 5-8 (offset 0x04): GMAC - zeros
        packet[5] = 0
        packet[6] = 0
        packet[7] = 0
        packet[8] = 0
        
        // Bytes 9-12 (offset 0x08): Key pos - 0
        packet[9] = 0
        packet[10] = 0
        packet[11] = 0
        packet[12] = 0
        
        // Byte 13 (offset 0x0C): Chunk type = INIT (0x01)
        packet[13] = 0x01
        
        // Byte 14 (offset 0x0D): Chunk flags = 0
        packet[14] = 0x00
        
        // Bytes 15-16 (offset 0x0E): Payload size = raw_size + 4 = 16 + 4 = 20 = 0x0014
        // Note: chiaki adds 4 to the raw payload size
        packet[15] = 0x00
        packet[16] = 0x14  // 20 in decimal (16 raw payload + 4)
        
        // Payload starts at byte 17 (16 bytes)
        let payloadOffset = 17
        
        // Bytes 0-3: Tag (our local tag, big-endian)
        packet[payloadOffset + 0] = UInt8((takionTagLocal >> 24) & 0xFF)
        packet[payloadOffset + 1] = UInt8((takionTagLocal >> 16) & 0xFF)
        packet[payloadOffset + 2] = UInt8((takionTagLocal >> 8) & 0xFF)
        packet[payloadOffset + 3] = UInt8(takionTagLocal & 0xFF)
        
        // Bytes 4-7: A_RWND = 0x19000 (big-endian)
        let aRwnd: UInt32 = 0x00019000
        packet[payloadOffset + 4] = UInt8((aRwnd >> 24) & 0xFF)
        packet[payloadOffset + 5] = UInt8((aRwnd >> 16) & 0xFF)
        packet[payloadOffset + 6] = UInt8((aRwnd >> 8) & 0xFF)
        packet[payloadOffset + 7] = UInt8(aRwnd & 0xFF)
        
        // Bytes 8-9: Outbound streams = 0x0064 (big-endian)
        packet[payloadOffset + 8] = 0x00
        packet[payloadOffset + 9] = 0x64
        
        // Bytes 10-11: Inbound streams = 0x0064 (big-endian)
        packet[payloadOffset + 10] = 0x00
        packet[payloadOffset + 11] = 0x64
        
        // Bytes 12-15: Initial sequence number (big-endian)
        packet[payloadOffset + 12] = UInt8((takionSeqNum >> 24) & 0xFF)
        packet[payloadOffset + 13] = UInt8((takionSeqNum >> 16) & 0xFF)
        packet[payloadOffset + 14] = UInt8((takionSeqNum >> 8) & 0xFF)
        packet[payloadOffset + 15] = UInt8(takionSeqNum & 0xFF)
        
        // Debug: print hex dump
        let hexString = packet.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[StreamingService] INIT packet hex: \(hexString)")
        
        return packet
    }
    
    private func parseTakionInitAck(_ data: Data) throws -> (UInt32, Data) {
        // Expected: 1 byte type + 16 byte header + 16 byte payload + 32 byte cookie = 65 bytes
        guard data.count >= 65 else {
            throw StreamingError.sessionRequestFailed("INIT_ACK too small: \(data.count) bytes")
        }
        
        // Verify packet type is CONTROL (0x00)
        guard data[0] == 0x00 else {
            throw StreamingError.sessionRequestFailed("Expected CONTROL packet, got \(String(format: "0x%02x", data[0]))")
        }
        
        // Verify chunk type is INIT_ACK (0x02) at offset 13
        guard data[13] == 0x02 else {
            throw StreamingError.sessionRequestFailed("Expected INIT_ACK chunk, got \(String(format: "0x%02x", data[13]))")
        }
        
        // Parse remote tag from payload (offset 17)
        let remoteTag = UInt32(data[17]) << 24 | UInt32(data[18]) << 16 | UInt32(data[19]) << 8 | UInt32(data[20])
        
        // Cookie is 32 bytes starting at offset 33 (17 + 16)
        let cookie = data.subdata(in: 33..<65)
        
        return (remoteTag, cookie)
    }
    
    private func buildTakionCookiePacket(cookie: Data) -> Data {
        var packet = Data(count: 1 + 16 + 32) // type + header + cookie
        
        // Packet type: CONTROL (0x00)
        packet[0] = 0x00
        
        // Tag remote (4 bytes, big-endian)
        packet[1] = UInt8((takionTagRemote >> 24) & 0xFF)
        packet[2] = UInt8((takionTagRemote >> 16) & 0xFF)
        packet[3] = UInt8((takionTagRemote >> 8) & 0xFF)
        packet[4] = UInt8(takionTagRemote & 0xFF)
        
        // Zero + key pos (12 bytes) at offset 5-16
        
        // Chunk type: COOKIE (0x0A) at offset 13
        packet[13] = 0x0A
        
        // Chunk flags at offset 14
        packet[14] = 0x00
        
        // Payload size (2 bytes, big-endian) = 32 (cookie size)
        packet[15] = 0x00
        packet[16] = 0x20
        
        // Cookie (32 bytes at offset 17)
        packet.replaceSubrange(17..<49, with: cookie)
        
        return packet
    }
    
    private func sendUDPData(_ data: Data, on connection: NWConnection) async throws {
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
    
    private func receiveUDPData(on connection: NWConnection, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: StreamingError.sessionRequestFailed("No data received"))
                }
            }
        }
    }
    
    private func startReceivingStream() {
        guard let stream = streamConnection else { return }
        
        func receive() {
            stream.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, context, isComplete, error in
                if let data = data, !data.isEmpty {
                    self?.handleStreamPacket(data)
                }
                
                if !isComplete && error == nil {
                    receive() // Continue receiving
                }
            }
        }
        
        receive()
    }
    
    // MARK: - Packet Handling
    
    // TAKION Packet Types (from chiaki-ng takion.c)
    private enum TakionPacketType: UInt8 {
        case control = 0x00
        case feedbackHistory = 0x01
        case video = 0x02
        case audio = 0x03
        case handshake = 0x04
        case congestion = 0x05
        case feedbackState = 0x06
        case clientInfo = 0x08
    }
    
    // TAKION Header Sizes (V12 for PS5)
    private static let videoHeaderSize = 0x17  // 23 bytes
    private static let audioHeaderSize = 0x13  // 19 bytes
    
    private func handleStreamPacket(_ data: Data) {
        // Parse TAKION packet header
        guard data.count > 12 else { return }
        
        let typeByte = data[0] & 0x0F  // Lower nibble is base type
        
        switch typeByte {
        case TakionPacketType.video.rawValue:
            handleVideoPacket(data)
        case TakionPacketType.audio.rawValue:
            handleAudioPacket(data)
        case TakionPacketType.control.rawValue:
            handleControlPacket(data)
        case TakionPacketType.congestion.rawValue:
            // Ignore congestion packets
            break
        default:
            print("[StreamingService] Unknown packet type: 0x\(String(format: "%02x", typeByte)), size: \(data.count)")
        }
    }
    
    private func handleVideoPacket(_ data: Data) {
        // Extract NAL units after TAKION header (0x17 = 23 bytes for V12 video)
        guard data.count > Self.videoHeaderSize else {
            print("[StreamingService] Video packet too small: \(data.count) bytes")
            return
        }
        
        // Debug: print packet info
        let packetIndex = UInt16(data[1]) << 8 | UInt16(data[2])
        let frameIndex = UInt16(data[3]) << 8 | UInt16(data[4])
        print("[StreamingService] Video packet: frame=\(frameIndex), packet=\(packetIndex), size=\(data.count)")
        
        // Skip header and get NAL data
        let nalData = data.dropFirst(Self.videoHeaderSize)
        
        videoDecoder?.decode(nalData: Data(nalData)) { [weak self] pixelBuffer, timestamp in
            guard let self = self, let buffer = pixelBuffer else { return }
            DispatchQueue.main.async {
                self.delegate?.streamingService(self, didReceiveVideoFrame: buffer, timestamp: timestamp)
            }
        }
    }
    
    private func handleAudioPacket(_ data: Data) {
        guard data.count > Self.audioHeaderSize else { return }
        
        // Extract Opus audio data after header (0x13 = 19 bytes for V12 audio)
        let audioData = data.dropFirst(Self.audioHeaderSize)
        
        // Note: When using ChiakiFullSession, audio is already decoded to PCM
        // Legacy: audioPlayer?.playOpusPacket(Data(audioData))
        
        delegate?.streamingService(self, didReceiveAudioData: Data(audioData), sampleRate: 48000, channels: 2)
    }
    
    private func handleControlPacket(_ data: Data) {
        // Handle heartbeat, rumble, etc.
        print("[StreamingService] Control packet received: \(data.count) bytes")
    }
    
    // MARK: - Media Decoders
    
    private func startMediaDecoders() async {
        guard let config = configuration else { return }
        
        // Initialize video decoder
        videoDecoder = StreamVideoDecoder(width: config.width, height: config.height)
        videoDecoder?.start()
        
        // Initialize audio player (low-latency pull model)
        audioPlayer = LowLatencyAudioPlayer(sampleRate: 48000, channels: 2)
        audioPlayer?.start()
        
        print("[StreamingService] Media decoders started")
    }
    
    // MARK: - Controller
    
    private func sendControllerState() {
        // Route controller input through ChiakiFullSession (not the legacy stream)
        guard isStreaming else { 
            print("[Controller] ⚠️ Not streaming, ignoring input")
            return 
        }
        
        // Convert button mask to chiaki format (UInt32)
        let buttons = UInt32(controllerState.buttons.rawValue)
        
        // Debug log when buttons are pressed
        if buttons != 0 || controllerState.leftX != 0 || controllerState.leftY != 0 {
            print("[Controller] 🎮 Sending: buttons=\(buttons) L(\(controllerState.leftX),\(controllerState.leftY)) R(\(controllerState.rightX),\(controllerState.rightY)) L2=\(controllerState.l2) R2=\(controllerState.r2)")
        }
        
        // Send to ChiakiFullSession
        ChiakiFullSession.shared.setControllerState(
            buttons: buttons,
            leftX: controllerState.leftX,
            leftY: controllerState.leftY,
            rightX: controllerState.rightX,
            rightY: controllerState.rightY,
            l2: controllerState.l2,
            r2: controllerState.r2
        )
    }
    
    // MARK: - Helpers
    
    private func receiveData(from connection: NWConnection, maxLength: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, context, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

// MARK: - Controller Types

struct ControllerButton: OptionSet {
    let rawValue: UInt16
    
    static let cross     = ControllerButton(rawValue: 1 << 0)
    static let circle    = ControllerButton(rawValue: 1 << 1)
    static let square    = ControllerButton(rawValue: 1 << 2)
    static let triangle  = ControllerButton(rawValue: 1 << 3)
    static let dpadLeft  = ControllerButton(rawValue: 1 << 4)
    static let dpadRight = ControllerButton(rawValue: 1 << 5)
    static let dpadUp    = ControllerButton(rawValue: 1 << 6)
    static let dpadDown  = ControllerButton(rawValue: 1 << 7)
    static let l1        = ControllerButton(rawValue: 1 << 8)
    static let r1        = ControllerButton(rawValue: 1 << 9)
    static let l3        = ControllerButton(rawValue: 1 << 10)
    static let r3        = ControllerButton(rawValue: 1 << 11)
    static let options   = ControllerButton(rawValue: 1 << 12)
    static let share     = ControllerButton(rawValue: 1 << 13)
    static let touchpad  = ControllerButton(rawValue: 1 << 14)
    static let ps        = ControllerButton(rawValue: 1 << 15)
}

struct ControllerState {
    var buttons: ControllerButton = []
    var l2: UInt8 = 0
    var r2: UInt8 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
}

// MARK: - Stream Video Decoder

class StreamVideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let width: Int
    private let height: Int
    
    // HEVC requires VPS, SPS, PPS
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    
    // H.264 requires SPS, PPS only
    private var isHEVC: Bool = true  // PS5 uses HEVC by default
    
    private var frameCount = 0
    
    // v10.1: Recovery flag for anti-smearing on buffer exhaustion
    private var needsRecovery: Bool = false
    
    /// v10.1: Mark decoder for recovery - will skip non-IDR frames until next keyframe
    /// Call this when buffer pool is exhausted to prevent smearing from corrupted reference frames
    func markForRecovery() {
        needsRecovery = true
        // Clear format description to force wait for next VPS/SPS/PPS + IDR
        formatDescription = nil
        vps = nil
        sps = nil
        pps = nil
        print("[VideoDecoder] ⚠️ Marked for recovery - waiting for next keyframe")
    }
    
    init(width: Int, height: Int, isHEVC: Bool = true) {
        self.width = width
        self.height = height
        self.isHEVC = isHEVC
    }
    
    func start() {
        print("[VideoDecoder] Started for \(width)x\(height), codec: \(isHEVC ? "HEVC" : "H.264")")
    }
    
    func stop() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        vps = nil
        sps = nil
        pps = nil
        print("[VideoDecoder] Stopped")
    }
    
    func decode(nalData: Data, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        guard nalData.count > 4 else { 
            print("[VideoDecoder] ⚠️ NAL data too short: \(nalData.count) bytes")
            return 
        }
        
        frameCount += 1
        
        // Split concatenated NAL units (PS5 sends VPS+SPS+PPS+IDR in one packet)
        let nalUnits = splitNALUnits(nalData)
        
        if frameCount <= 5 {
            print("[VideoDecoder] 🔍 Frame #\(frameCount): \(nalData.count) bytes, \(nalUnits.count) NAL(s)")
        }
        
        for nalUnit in nalUnits {
            processNALUnit(nalUnit, completion: completion)
        }
    }
    
    /// ZERO-COPY DECODE: Accepts raw pointer without memory allocation
    /// The pointer MUST remain valid for the duration of this call!
    /// Uses Data(bytesNoCopy:) to create a view without copying.
    /// ⚠️ WARNING: This method has a race condition bug - use decodeFromSafeBuffer instead!
    @available(*, deprecated, message: "Use decodeFromSafeBuffer to avoid race conditions")
    func decodeZeroCopy(pointer: UnsafeRawPointer, size: Int, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        guard size > 4 else {
            return
        }
        
        frameCount += 1
        
        // Create a Data view WITHOUT copying the underlying memory
        // deallocator: .none means we don't own the memory (chiaki owns it)
        let nalData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), 
                           count: size, 
                           deallocator: .none)
        
        // Split concatenated NAL units
        let nalUnits = splitNALUnits(nalData)
        
        if frameCount <= 5 {
            print("[VideoDecoder] 🔍 Frame #\(frameCount) (zero-copy): \(size) bytes, \(nalUnits.count) NAL(s)")
        }
        
        for nalUnit in nalUnits {
            processNALUnit(nalUnit, completion: completion)
        }
    }
    
    /// SAFE BUFFER DECODE: Accepts a SafeBuffer that owns its memory
    /// This is the recommended method - it avoids race conditions because:
    /// 1. The SafeBuffer contains a COPY of the network data
    /// 2. The buffer won't be released until the completion handler is called
    /// 3. VTDecompressionSession can safely read the data asynchronously
    func decodeFromSafeBuffer(_ safeBuffer: SafeBuffer, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        guard safeBuffer.size > 4 else {
            completion(nil, 0)
            return
        }
        
        frameCount += 1
        
        // Create a Data view from the safe buffer
        // This is safe because we own this memory and it won't be reclaimed
        // until the caller releases the buffer (after completion is called)
        let nalData = Data(bytesNoCopy: safeBuffer.pointer, 
                           count: safeBuffer.size, 
                           deallocator: .none)
        
        // Split concatenated NAL units
        let nalUnits = splitNALUnits(nalData)
        
        if frameCount <= 5 {
            print("[VideoDecoder] 🔍 Frame #\(frameCount) (safe buffer): \(safeBuffer.size) bytes, \(nalUnits.count) NAL(s)")
        }
        
        for nalUnit in nalUnits {
            processNALUnit(nalUnit, completion: completion)
        }
    }
    
    /// Split concatenated NAL units by finding start codes
    private func splitNALUnits(_ data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var startIndices: [Int] = []
        
        // Find all start code positions
        var i = 0
        while i < data.count - 3 {
            // Check for 4-byte start code: 0x00 0x00 0x00 0x01
            if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x00 && data[i+3] == 0x01 {
                startIndices.append(i)
                i += 4
            }
            // Check for 3-byte start code: 0x00 0x00 0x01
            else if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x01 {
                startIndices.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        
        // Extract NAL units
        for (index, startPos) in startIndices.enumerated() {
            let endPos = (index + 1 < startIndices.count) ? startIndices[index + 1] : data.count
            let nalData = data.subdata(in: startPos..<endPos)
            nalUnits.append(nalData)
        }
        
        // If no start codes found, treat entire data as single NAL unit
        if nalUnits.isEmpty {
            nalUnits.append(data)
        }
        
        return nalUnits
    }
    
    /// Process a single NAL unit
    private func processNALUnit(_ nalData: Data, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        let (offset, nalHeader) = findNALStart(in: nalData)
        guard offset >= 0 else { return }
        
        if isHEVC {
            // HEVC NAL unit type: (header >> 1) & 0x3F
            let nalType = (nalHeader >> 1) & 0x3F
            
            if nalType >= 32 && nalType <= 34 {
                print("[VideoDecoder] 📦 HEVC NAL type \(nalType), size: \(nalData.count)")
            }
            
            switch nalType {
            case 32: // VPS
                vps = extractNALUnit(from: nalData, offset: offset)
                print("[VideoDecoder] ✅ Stored VPS (\(vps?.count ?? 0) bytes)")
                tryCreateHEVCSession()
            case 33: // SPS
                sps = extractNALUnit(from: nalData, offset: offset)
                print("[VideoDecoder] ✅ Stored SPS (\(sps?.count ?? 0) bytes)")
                tryCreateHEVCSession()
            case 34: // PPS
                pps = extractNALUnit(from: nalData, offset: offset)
                print("[VideoDecoder] ✅ Stored PPS (\(pps?.count ?? 0) bytes)")
                tryCreateHEVCSession()
            case 19, 20, 21: // IDR frames
                decodeFrame(nalData: nalData, offset: offset, completion: completion)
            case 0, 1, 2, 3, 4, 5, 6, 7, 8, 9: // Non-IDR slices
                decodeFrame(nalData: nalData, offset: offset, completion: completion)
            default:
                if frameCount <= 10 {
                    print("[VideoDecoder] ❓ Unhandled HEVC NAL type \(nalType)")
                }
            }
        } else {
            // H.264 NAL unit type: header & 0x1F
            let nalType = nalHeader & 0x1F
            
            switch nalType {
            case 7: // SPS
                sps = extractNALUnit(from: nalData, offset: offset)
                print("[VideoDecoder] ✅ Stored H.264 SPS")
                tryCreateH264Session()
            case 8: // PPS
                pps = extractNALUnit(from: nalData, offset: offset)
                print("[VideoDecoder] ✅ Stored H.264 PPS")
                tryCreateH264Session()
            case 1, 5: // Non-IDR or IDR slice
                decodeFrame(nalData: nalData, offset: offset, completion: completion)
            default:
                break
            }
        }
    }
    
    private func findNALStart(in data: Data) -> (offset: Int, header: UInt8) {
        // Look for start code 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01
        guard data.count > 4 else { return (-1, 0) }
        
        if data[0] == 0x00 && data[1] == 0x00 {
            if data[2] == 0x01 && data.count > 3 {
                return (3, data[3])
            } else if data[2] == 0x00 && data[3] == 0x01 && data.count > 4 {
                return (4, data[4])
            }
        }
        return (-1, 0)
    }
    
    private func extractNALUnit(from data: Data, offset: Int) -> Data {
        // Return NAL unit without start code
        return data.suffix(from: offset)
    }
    
    private func tryCreateHEVCSession() {
        guard let vps = vps, let sps = sps, let pps = pps else { return }
        guard decompressionSession == nil else { return }
        
        print("[VideoDecoder] Creating HEVC decompression session...")
        print("[VideoDecoder]   VPS: \(vps.count) bytes, SPS: \(sps.count) bytes, PPS: \(pps.count) bytes")
        
        var formatDesc: CMVideoFormatDescription?
        
        // Must use withUnsafeBytes to properly pass pointers to C function
        let status = vps.withUnsafeBytes { vpsBytes -> OSStatus in
            sps.withUnsafeBytes { spsBytes -> OSStatus in
                pps.withUnsafeBytes { ppsBytes -> OSStatus in
                    guard let vpsPtr = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsPtr = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPtr = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1
                    }
                    
                    var parameterSetPointers: [UnsafePointer<UInt8>] = [vpsPtr, spsPtr, ppsPtr]
                    var parameterSetSizes: [Int] = [vps.count, sps.count, pps.count]
                    
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &parameterSetPointers,
                        parameterSetSizes: &parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }
        
        guard status == noErr, let desc = formatDesc else {
            print("[VideoDecoder] ❌ Failed to create HEVC format description: \(status)")
            return
        }
        
        self.formatDescription = desc
        createDecompressionSession()
    }
    
    private func tryCreateH264Session() {
        guard let sps = sps, let pps = pps else { return }
        guard decompressionSession == nil else { return }
        
        print("[VideoDecoder] Creating H.264 decompression session...")
        print("[VideoDecoder]   SPS: \(sps.count) bytes, PPS: \(pps.count) bytes")
        
        var formatDesc: CMVideoFormatDescription?
        
        // Must use withUnsafeBytes to properly pass pointers to C function
        let status = sps.withUnsafeBytes { spsBytes -> OSStatus in
            pps.withUnsafeBytes { ppsBytes -> OSStatus in
                guard let spsPtr = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                
                var parameterSetPointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var parameterSetSizes: [Int] = [sps.count, pps.count]
                
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        
        guard status == noErr, let desc = formatDesc else {
            print("[VideoDecoder] ❌ Failed to create H.264 format description: \(status)")
            return
        }
        
        self.formatDescription = desc
        createDecompressionSession()
    }
    
    private func createDecompressionSession() {
        guard let formatDesc = formatDescription else { return }
        
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var session: VTDecompressionSession?
        let decodeStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        
        if decodeStatus == noErr, let session = session {
            self.decompressionSession = session
            // Configure for low-latency real-time decoding
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
            print("[VideoDecoder] ✅ Decompression session created (\(isHEVC ? "HEVC" : "H.264"))")
        } else {
            print("[VideoDecoder] ❌ Failed to create decompression session: \(decodeStatus)")
        }
    }
    
    private func decodeFrame(nalData: Data, offset: Int, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        guard let session = decompressionSession, let formatDesc = formatDescription else { 
            if frameCount % 60 == 1 {
                print("[VideoDecoder] ⚠️ No session yet, waiting for parameter sets")
            }
            return 
        }
        
        // Convert Annex-B to AVCC/HVCC format (replace start code with length prefix)
        let nalUnit = nalData.suffix(from: offset)
        
        // Build AVCC format: 4-byte length prefix (big endian) + NAL unit data
        var avccData = Data(capacity: 4 + nalUnit.count)
        let length = UInt32(nalUnit.count).bigEndian
        withUnsafeBytes(of: length) { avccData.append(contentsOf: $0) }
        avccData.append(nalUnit)
        
        let dataLength = avccData.count
        
        // Create block buffer that copies the data (important for async decode)
        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,  // Let CMBlockBuffer allocate its own memory
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard allocStatus == kCMBlockBufferNoErr, let block = blockBuffer else { 
            if frameCount % 60 == 1 {
                print("[VideoDecoder] ⚠️ Failed to create block buffer: \(allocStatus)")
            }
            return 
        }
        
        // Copy data into the block buffer
        let copyStatus = avccData.withUnsafeBytes { bytes -> OSStatus in
            guard let ptr = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: ptr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        
        guard copyStatus == kCMBlockBufferNoErr else {
            if frameCount % 60 == 1 {
                print("[VideoDecoder] ⚠️ Failed to copy data to block buffer: \(copyStatus)")
            }
            return
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr, let sample = sampleBuffer else { 
            if frameCount % 60 == 1 {
                print("[VideoDecoder] ⚠️ Failed to create sample buffer: \(sampleStatus)")
            }
            return 
        }
        
        var flagOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagOut
        ) { status, _, imageBuffer, presentationTimestamp, _ in
            if status == noErr, let buffer = imageBuffer {
                let seconds = CMTimeGetSeconds(presentationTimestamp)
                let timestamp: UInt64 = seconds.isFinite ? UInt64(seconds * 1000000) : 0
                completion(buffer, timestamp)
            } else if status != noErr && self.frameCount % 60 == 1 {
                print("[VideoDecoder] ⚠️ Decode error: \(status)")
            }
        }
        
        if decodeStatus != noErr && frameCount % 60 == 1 {
            print("[VideoDecoder] ⚠️ DecodeFrame call failed: \(decodeStatus)")
        }
    }
}

// MARK: - Stream Audio Player

class StreamAudioPlayer {
    private let sampleRate: Int
    private let channels: Int
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    
    private var sampleCount = 0
    
    init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
    
    func start() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let engine = audioEngine, let player = playerNode else { return }
        
        engine.attach(player)
        
        // Create PCM format for int16 samples from chiaki (stereo interleaved)
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )
        
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))!
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        
        do {
            try engine.start()
            player.play()
            print("[AudioPlayer] ✅ Audio engine started (\(sampleRate)Hz, \(channels)ch)")
        } catch {
            print("[AudioPlayer] ❌ Failed to start: \(error)")
        }
    }
    
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        print("[AudioPlayer] Stopped")
    }
    
    /// Play PCM samples received from chiaki-ng (int16 stereo interleaved)
    func playPCMSamples(_ data: Data, sampleCount: Int) {
        guard let engine = audioEngine,
              let player = playerNode,
              engine.isRunning else {
            return
        }
        
        self.sampleCount += sampleCount
        if self.sampleCount % 48000 < sampleCount {
            print("[AudioPlayer] Playing audio... (\(self.sampleCount) samples total)")
        }
        
        // Create output format (float32 non-interleaved for AVAudioPlayerNode)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))!
        
        // Calculate frame count (samples are stereo, so frames = samples / channels)
        let frameCount = AVAudioFrameCount(sampleCount / channels)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        
        // Convert int16 interleaved to float32 non-interleaved
        data.withUnsafeBytes { rawBytes in
            guard let samples = rawBytes.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            guard let leftChannel = buffer.floatChannelData?[0],
                  let rightChannel = buffer.floatChannelData?[1] else { return }
            
            for frame in 0..<Int(frameCount) {
                let idx = frame * channels
                if idx + 1 < sampleCount {
                    // Convert int16 [-32768, 32767] to float [-1.0, 1.0]
                    leftChannel[frame] = Float(samples[idx]) / 32768.0
                    rightChannel[frame] = Float(samples[idx + 1]) / 32768.0
                }
            }
        }
        
        // Schedule buffer for playback
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

// MARK: - Data Extension

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
