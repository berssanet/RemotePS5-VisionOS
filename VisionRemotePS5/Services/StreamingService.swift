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

    /// Phase 5.21: derived from `state` so the two can never disagree.
    /// Previously, `state` and `isStreaming` were mutated independently and
    /// drifted (controller input enabled before chiaki acknowledged the session).
    var isStreaming: Bool { state == .streaming }
    
    // Debug counters
    private var videoFrameCount: Int = 0
    
    // v10.1: Buffer exhaustion tracking for anti-smearing recovery
    private var lastBufferExhaustionTime: CFTimeInterval?
    private var bufferExhaustionCount: Int = 0
    
    weak var delegate: StreamingServiceDelegate?
    
    private var configuration: StreamingConfiguration?

    // Dedicated video processing queue - NEVER use main thread for decoding!
    // This queue handles: NAL parsing -> VideoToolbox decode -> MetalFX upscale
    private let videoProcessingQueue = DispatchQueue(
        label: "com.visionremoteps5.video.processing",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

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

    // MARK: - Initialization
    
    private init() {
        DebugLog.info("StreamingService", "Initialized")
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
        
        DebugLog.print("[StreamingService] Starting streaming to \(configuration.host)")
        DebugLog.print("[StreamingService] RP-Key: \(configuration.rpKey.hexString)")
        
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
            DebugLog.warning("StreamingService", "⚠️ No registKey for wakeup, skipping")
            return
        }
        
        DebugLog.print("[StreamingService] 📢 Sending WAKEUP packet to \(configuration.host)...")
        
        let success = await WakeOnLanService.shared.wakeConsole(
            host: configuration.host,
            registKey: registKeyData,
            isPS5: configuration.isPS5
        )
        
        if success {
            DebugLog.info("StreamingService", "✅ WAKEUP sent successfully")
            // Phase 5.18: poll the CTRL port (9295) every 500ms instead of a
            // fixed 4-second sleep. PS5 cold-wake can take 6-10 seconds; the
            // old fixed sleep often hit a half-awake console with
            // "RP-Application-Reason 0x80108b15" busy/not-ready errors.
            await waitForCtrlPort(host: configuration.host, port: 9295, timeoutSeconds: 15)
        } else {
            DebugLog.error("StreamingService", "⚠️ WAKEUP failed, attempting connection anyway...")
        }
    }

    /// Phase 5.18: probe a TCP port until it accepts a connection or timeout elapses.
    /// Returns when the port responds (PS5 ctrl ready) or when timeout hits — never throws.
    private func waitForCtrlPort(host: String, port: UInt16, timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let pollIntervalNs: UInt64 = 500_000_000  // 500ms
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let opened = await probeTCP(host: host, port: port, attemptTimeoutSeconds: 1.0)
            if opened {
                DebugLog.print("[StreamingService] ✅ CTRL port \(port) ready after \(attempt) probe(s)")
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        DebugLog.print("[StreamingService] ⚠️ CTRL port \(port) not ready after \(timeoutSeconds)s; proceeding anyway")
    }

    /// Single TCP connect attempt; resolves true on .ready, false on .failed/timeout.
    private func probeTCP(host: String, port: UInt16, attemptTimeoutSeconds: TimeInterval) async -> Bool {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let nwHost = NWEndpoint.Host(host)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
            // One-shot guard so we resume exactly once
            let gate = ContinuationGate()
            @Sendable func finish(_ value: Bool) {
                guard gate.tryResume() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:    finish(true)
                case .failed:   finish(false)
                case .cancelled: finish(false)
                default:        break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            // Per-attempt timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + attemptTimeoutSeconds) {
                finish(false)
            }
        }
    }
    
    /// Start streaming using chiaki-ng library (V2)
    private func startStreamingV2() async throws {
        guard let config = configuration else {
            throw StreamingError.invalidConfiguration
        }
        
        DebugLog.info("StreamingService", "Using ChiakiFullSession for streaming")
        
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
        
        DebugLog.info("StreamingService", "Starting ChiakiFullSession...")
        DebugLog.print("[StreamingService]   Host: \(config.host)")
        DebugLog.print("[StreamingService]   RegistKey: \(registKeyData.hexString)")
        DebugLog.print("[StreamingService]   RP-Key: \(config.rpKey.hexString)")
        DebugLog.print("[StreamingService]   PSN ID: \(psnAccountIDPadded.hexString)")
        
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
            DebugLog.info("StreamingService", "✅ ChiakiFullSession started, waiting for connection...")
            // Phase 5.21: do NOT flip state to .streaming here. Wait for the
            // chiaki .connected event so isStreaming (derived from state)
            // accurately reflects "PS5 has acked the session." The previous
            // code enabled controller input before the server was ready.
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
                    DebugLog.print("[StreamingService] ⚠️ Buffer pool exhausted! Frames dropped: \(self.bufferExhaustionCount)")
                    
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
                DebugLog.print("[StreamingService] 📹 Video frame #\(frameNum) received (safe copy), size: \(size) bytes")
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
                let estimatedDisplayMs = 1000.0 / displayRefreshRate
                #else
                let displayRefreshRate: Double = Double(UIScreen.main.maximumFramesPerSecond)
                let estimatedDisplayMs = displayRefreshRate > 0 ? (1000.0 / displayRefreshRate) : 16.7
                #endif
                let totalVideoLatencyMs = decodeLatencyMs + estimatedUpscaleMs + estimatedDisplayMs
                
                // Update audio target to chase measured video latency
                if let player = self.audioPlayer {
                    player.updateDynamicTarget(measuredLatencyMs: totalVideoLatencyMs)
                }
                
                if frameNum % 60 == 1 {
                    DebugLog.print("[StreamingService] ✅ Frame #\(frameNum) decoded safely")
                    DebugLog.print("[StreamingService] 🎯 v10.0 Closed-loop sync: decode=\(String(format: "%.1f", decodeLatencyMs))ms, total=\(String(format: "%.0f", totalVideoLatencyMs))ms")
                }
                
                // Phase 5.20: notify delegate on main via DispatchQueue.main.async
                // (lighter than `Task { @MainActor in ... }` which allocates a
                // Task object + isolation context per frame at 60-120fps).
                DispatchQueue.main.async {
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
            
            DebugLog.print("[StreamingService] ChiakiEvent: \(event), reason: \(reason ?? "none")")
            
            switch event {
            case .connected:
                DebugLog.info("StreamingService", "✅ Connected via ChiakiFullSession!")
                Task { @MainActor in
                    // Phase 5.21: state is the single source of truth; isStreaming derives from it.
                    self.state = .streaming
                    self.delegate?.streamingService(self, didChangeState: .streaming)
                }

            case .quit:
                DebugLog.print("[StreamingService] ❌ Session quit: \(reason ?? "unknown")")
                Task { @MainActor in
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
    
    /// Parse registKey string to Data for chiaki session.
    /// Chiaki session.c:901 does format_hex() on regist_key before sending to HTTP header,
    /// so we MUST pass the actual binary bytes (hex-decoded), NOT ASCII characters.
    ///
    /// Phase 5.22: validate input is exactly 32 hex chars (= 16 bytes). Anything
    /// else returns an empty Data and logs a clear warning — silent partial
    /// decodes used to surface as opaque "session request failed" errors from PS5.
    private func parseRegistKey(_ registKey: String) -> Data {
        return Self.hexDecode16Bytes(registKey, label: "registKey")
    }

    /// Shared 16-byte hex decoder used by registKey parsing.
    ///
    /// The PS5's regist key is a SHORT ASCII string (typically 8 chars) that
    /// the registration response delivers hex-encoded — i.e. 16 hex chars →
    /// 8 bytes — and chiaki expects it in a zero-padded char[16]. So any
    /// EVEN 2...32 hex-char input is legitimate: decode and zero-pad to 16.
    /// (The original 5.22 hardening required exactly 32 chars, which
    /// rejected every real console key — device log 2026-07-04:
    /// "registKey length=16 ... Invalid key sizes: registKey=0".)
    /// Odd lengths, non-hex characters, and >32 chars still fail fast.
    fileprivate static func hexDecode16Bytes(_ hex: String, label: String) -> Data {
        guard hex.count >= 2, hex.count <= 32, hex.count % 2 == 0 else {
            DebugLog.print("[StreamingService] ⚠️ \(label) length=\(hex.count), expected an even 2...32 hex chars; refusing to fabricate a key")
            return Data()
        }
        guard hex.allSatisfy({ $0.isHexDigit }) else {
            DebugLog.print("[StreamingService] ⚠️ \(label) contains non-hex characters; refusing to decode")
            return Data()
        }
        var data = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let endIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<endIndex], radix: 16) else { return Data() }
            data.append(byte)
            index = endIndex
        }
        // chiaki's regist_key is char[16]; pad the decoded ASCII with zeros.
        if data.count < 16 {
            data.append(Data(repeating: 0, count: 16 - data.count))
        }
        return data
    }
    
    func stopStreaming() {
        DebugLog.info("StreamingService", "Stopping streaming...")
        
        // Stop ChiakiFullSession if active
        if ChiakiFullSession.shared.isActive {
            ChiakiFullSession.shared.stop()
        }
        
        videoDecoder?.stop()
        audioPlayer?.stop()
        framePacer?.stop()
        framePacer = nil

        DispatchQueue.main.async {
            // Phase 5.21: state drives isStreaming.
            self.state = .stopped
            self.delegate?.streamingService(self, didChangeState: .stopped)
        }
        
        DebugLog.info("StreamingService", "Streaming stopped")
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
    
    
    // MARK: - Controller
    
    private func sendControllerState() {
        // Route controller input through ChiakiFullSession (not the legacy stream)
        guard isStreaming else { 
            DebugLog.warning("Controller", "⚠️ Not streaming, ignoring input")
            return 
        }
        
        // Convert button mask to chiaki format (UInt32)
        let buttons = UInt32(controllerState.buttons.rawValue)
        
        // Debug log when buttons are pressed
        if buttons != 0 || controllerState.leftX != 0 || controllerState.leftY != 0 {
            DebugLog.print("[Controller] 🎮 Sending: buttons=\(buttons) L(\(controllerState.leftX),\(controllerState.leftY)) R(\(controllerState.rightX),\(controllerState.rightY)) L2=\(controllerState.l2) R2=\(controllerState.r2)")
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
        DebugLog.warning("VideoDecoder", "⚠️ Marked for recovery - waiting for next keyframe")
    }
    
    init(width: Int, height: Int, isHEVC: Bool = true) {
        self.width = width
        self.height = height
        self.isHEVC = isHEVC
    }
    
    func start() {
        DebugLog.print("[VideoDecoder] Started for \(width)x\(height), codec: \(isHEVC ? "HEVC" : "H.264")")
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
        DebugLog.info("VideoDecoder", "Stopped")
    }
    
    func decode(nalData: Data, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        guard nalData.count > 4 else { 
            DebugLog.print("[VideoDecoder] ⚠️ NAL data too short: \(nalData.count) bytes")
            return 
        }
        
        frameCount += 1
        
        // Split concatenated NAL units (PS5 sends VPS+SPS+PPS+IDR in one packet)
        let nalUnits = splitNALUnits(nalData)
        
        if frameCount <= 5 {
            DebugLog.print("[VideoDecoder] 🔍 Frame #\(frameCount): \(nalData.count) bytes, \(nalUnits.count) NAL(s)")
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
            DebugLog.print("[VideoDecoder] 🔍 Frame #\(frameCount) (zero-copy): \(size) bytes, \(nalUnits.count) NAL(s)")
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
            DebugLog.print("[VideoDecoder] 🔍 Frame #\(frameCount) (safe buffer): \(safeBuffer.size) bytes, \(nalUnits.count) NAL(s)")
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
                DebugLog.print("[VideoDecoder] 📦 HEVC NAL type \(nalType), size: \(nalData.count)")
            }
            
            switch nalType {
            case 32: // VPS
                vps = extractNALUnit(from: nalData, offset: offset)
                DebugLog.print("[VideoDecoder] ✅ Stored VPS (\(vps?.count ?? 0) bytes)")
                tryCreateHEVCSession()
            case 33: // SPS
                sps = extractNALUnit(from: nalData, offset: offset)
                DebugLog.print("[VideoDecoder] ✅ Stored SPS (\(sps?.count ?? 0) bytes)")
                tryCreateHEVCSession()
            case 34: // PPS
                pps = extractNALUnit(from: nalData, offset: offset)
                DebugLog.print("[VideoDecoder] ✅ Stored PPS (\(pps?.count ?? 0) bytes)")
                tryCreateHEVCSession()
            case 19, 20, 21: // IDR frames
                decodeFrame(nalData: nalData, offset: offset, completion: completion)
            case 0, 1, 2, 3, 4, 5, 6, 7, 8, 9: // Non-IDR slices
                decodeFrame(nalData: nalData, offset: offset, completion: completion)
            default:
                if frameCount <= 10 {
                    DebugLog.print("[VideoDecoder] ❓ Unhandled HEVC NAL type \(nalType)")
                }
            }
        } else {
            // H.264 NAL unit type: header & 0x1F
            let nalType = nalHeader & 0x1F
            
            switch nalType {
            case 7: // SPS
                sps = extractNALUnit(from: nalData, offset: offset)
                DebugLog.info("VideoDecoder", "✅ Stored H.264 SPS")
                tryCreateH264Session()
            case 8: // PPS
                pps = extractNALUnit(from: nalData, offset: offset)
                DebugLog.info("VideoDecoder", "✅ Stored H.264 PPS")
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
        
        DebugLog.info("VideoDecoder", "Creating HEVC decompression session...")
        DebugLog.print("[VideoDecoder]   VPS: \(vps.count) bytes, SPS: \(sps.count) bytes, PPS: \(pps.count) bytes")
        
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
            DebugLog.print("[VideoDecoder] ❌ Failed to create HEVC format description: \(status)")
            return
        }
        
        self.formatDescription = desc
        createDecompressionSession()
    }
    
    private func tryCreateH264Session() {
        guard let sps = sps, let pps = pps else { return }
        guard decompressionSession == nil else { return }
        
        DebugLog.info("VideoDecoder", "Creating H.264 decompression session...")
        DebugLog.print("[VideoDecoder]   SPS: \(sps.count) bytes, PPS: \(pps.count) bytes")
        
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
            DebugLog.print("[VideoDecoder] ❌ Failed to create H.264 format description: \(status)")
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
            DebugLog.print("[VideoDecoder] ✅ Decompression session created (\(isHEVC ? "HEVC" : "H.264"))")
        } else {
            DebugLog.print("[VideoDecoder] ❌ Failed to create decompression session: \(decodeStatus)")
        }
    }
    
    private func decodeFrame(nalData: Data, offset: Int, completion: @escaping (CVPixelBuffer?, UInt64) -> Void) {
        guard let session = decompressionSession, let formatDesc = formatDescription else { 
            if frameCount % 60 == 1 {
                DebugLog.warning("VideoDecoder", "⚠️ No session yet, waiting for parameter sets")
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
                DebugLog.print("[VideoDecoder] ⚠️ Failed to create block buffer: \(allocStatus)")
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
                DebugLog.print("[VideoDecoder] ⚠️ Failed to copy data to block buffer: \(copyStatus)")
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
                DebugLog.print("[VideoDecoder] ⚠️ Failed to create sample buffer: \(sampleStatus)")
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
                DebugLog.print("[VideoDecoder] ⚠️ Decode error: \(status)")
            }
        }
        
        if decodeStatus != noErr && frameCount % 60 == 1 {
            DebugLog.print("[VideoDecoder] ⚠️ DecodeFrame call failed: \(decodeStatus)")
        }
    }
}
// MARK: - Data Extension

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
