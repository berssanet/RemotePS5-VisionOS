//
//  StreamingService.swift
//  VisionRemotePS5
//
//  Service responsible for PS5 video streaming using ChiakiSession
//

import Foundation
import os
import Network
import VideoToolbox
import AVFoundation
import QuartzCore  // v10.1: For CACurrentMediaTime monotonic clock

// MARK: - Streaming Configuration

struct PSNStreamingConnection: Sendable {
    let token: String
    let deviceID: Data
}

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
    var psnConnection: PSNStreamingConnection? = nil

    var hasValidCredentials: Bool {
        if let psnConnection {
            return !psnConnection.token.isEmpty && psnConnection.deviceID.count == 32 && psnAccountID.count == 8
        }
        return rpKey.count == 16
    }
}

// MARK: - Session State

enum StreamingState: Equatable {
    case idle
    case connecting
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
    case invalidConfiguration
    case alreadyStreaming
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .invalidConfiguration: return "Invalid streaming configuration"
        case .alreadyStreaming: return "Already streaming"
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
    
    weak var delegate: StreamingServiceDelegate?
    
    private var configuration: StreamingConfiguration?
    private var psnStartTask: Task<Void, Error>?
    private var isStopping = false
    @Published private(set) var connectionStatusMessage = ""

    // Video decoder
    private var videoDecoder: StreamVideoDecoder?
    
    // Audio player
    private var audioPlayer: LowLatencyAudioPlayer?
    
    // Controller state
    private var controllerState = ControllerState()
    
    // Controller manager for haptics
    private var controllerManager: GameControllerManager?
    /// Read on the 120 Hz input thread: true only while the console has acked the session.
    private let inputGate = OSAllocatedUnfairLock(initialState: false)
    // MARK: - Initialization
    
    private init() {
        DebugLog.info("StreamingService", "Initialized")
    }
    
    // MARK: - Public Methods
    
    func startStreaming(configuration: StreamingConfiguration) async throws {
        guard (state == .idle || state == .stopped), psnStartTask == nil, !isStopping else {
            throw StreamingError.alreadyStreaming
        }
        
        guard configuration.hasValidCredentials else {
            throw StreamingError.invalidConfiguration
        }
        
        self.configuration = configuration
        connectionStatusMessage = configuration.psnConnection == nil
            ? "Connecting on the local network…" : "Connecting through PlayStation Network…"
        
        await MainActor.run {
            self.state = .connecting
            self.delegate?.streamingService(self, didChangeState: .connecting)
        }
        
        DebugLog.print("[StreamingService] Starting streaming to \(configuration.host)")
        
        // WAKEUP: Send wakeup packet first (PS5 might be in standby)
        // The PS5 refuses connections on port 9295 when in standby mode.
        // We need to wake it first, then wait a bit for it to become ready.
        if configuration.psnConnection == nil {
            await wakeupConsoleIfNeeded(configuration: configuration)
        }
        
        // Use ChiakiFullSession (chiaki-ng library)
        do {
            try Task.checkCancellation()
            try await startStreamingV2()
        } catch {
            stopStreaming()
            throw error
        }
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
        
        // Initialize video decoder (HEVC for PS5)
        videoDecoder = StreamVideoDecoder(width: config.width, height: config.height, isHEVC: config.isPS5)
        videoDecoder?.start()
        
        // Initialize audio player (48kHz stereo PCM from chiaki)
        // v10.0: Stereo Emitter Array with closed-loop A/V sync
        audioPlayer = LowLatencyAudioPlayer(sampleRate: 48000, channels: 2)
        
        // Small fixed audio buffer; presentation diagnostics measure the local video path separately.
        audioPlayer?.setTargetLatency(milliseconds: 40.0)  // 40 ms jitter budget
        audioPlayer?.start()
        
        // Initialize controller manager for haptic feedback
        // v10.1: Wire up 120Hz input callback for true decoupled input transmission
        // startStreamingV2 already runs on the main actor: create the pad wiring
        // inline so a synchronous start failure cannot outrun stopStreaming().
        do {
            self.controllerManager?.tearDown()
            self.controllerManager = GameControllerManager()
            
            // v10.1: TRUE 120Hz INPUT - Decoupled from video callback
            // The GameControllerManager polls at 120Hz (8.33ms) and directly sends
            // input to ChiakiFullSession on every poll cycle, bypassing Combine throttling
            self.controllerManager?.onInputReady = { [weak self] input in
                // Runs on the 120 Hz input thread: only lock-guarded state here.
                guard let self = self, self.inputGate.withLock({ $0 }) else { return }
                
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
            

        }
        
        setupChiakiCallbacks()

        if let psnConnection = config.psnConnection {
            try await startPSNStreaming(connection: psnConnection, config: config)
            return
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
    
    private func startPSNStreaming(connection: PSNStreamingConnection, config: StreamingConfiguration) async throws {
        let session = ChiakiFullSession.shared
        connectionStatusMessage = "Connecting through PlayStation Network…"
        let startTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try session.startPSN(
                token: connection.token, consoleDUID: connection.deviceID,
                isPS5: config.isPS5, psnAccountID: config.psnAccountID,
                autoRegist: false,
                width: UInt32(config.width), height: UInt32(config.height),
                fps: UInt32(config.fps), bitrate: UInt32(config.bitrate)
            )
            try Task.checkCancellation()
        }
        psnStartTask = startTask
        var timedOut = false
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
            } catch { return }
            timedOut = true
            session.cancelPSN()
        }
        defer {
            timeoutTask.cancel()
            psnStartTask = nil
        }
        do {
            try await withTaskCancellationHandler {
                try await startTask.value
                try Task.checkCancellation()
            } onCancel: {
                startTask.cancel()
                session.cancelPSN()
            }
        } catch {
            if timedOut {
                throw PSNRemotePlayCoordinator.CoordinatorError.timeout(stage: connectionStatusMessage)
            }
            throw error
        }
        if timedOut {
            throw PSNRemotePlayCoordinator.CoordinatorError.timeout(stage: connectionStatusMessage)
        }
    }

    /// Setup callbacks from ChiakiFullSession
    private func setupChiakiCallbacks() {
        // Capture session-owned decoder, never read actor state from the network thread.
        let decoder = videoDecoder
        ChiakiFullSession.shared.onVideoFramePointer = { pointer, size, lost, recovered in
            decoder?.submit(pointer: pointer, size: size, framesLost: lost, recovered: recovered) { buffer, timestamp in
                VideoDelivery.shared.submit(buffer, timestamp: timestamp)
            } ?? false
        }

        let sessionAudioPlayer = audioPlayer
        ChiakiFullSession.shared.onAudioSamples = { (data: Data, sampleCount: Int) in
            
            // Feed PCM samples to low-latency audio player (enqueue to ring buffer)
            if let player = sessionAudioPlayer {
                player.enqueueSamples(data, sampleCount: sampleCount)
            }
            
            // Notify delegate

        }
        
        ChiakiFullSession.shared.onEvent = { [weak self] event, reason in
            guard let self = self else { return }
            
            DebugLog.print("[StreamingService] ChiakiEvent: \(event), reason: \(reason ?? "none")")
            
            switch event {
            case .connected:
                DebugLog.info("StreamingService", "✅ Connected via ChiakiFullSession!")
                Task { @MainActor in
                    guard !self.isStopping, self.state == .connecting || self.state == .negotiating else { return }
                    // Phase 5.21: state is the single source of truth; isStreaming derives from it.
                    self.state = .streaming
                    self.inputGate.withLock { $0 = true }
                    self.delegate?.streamingService(self, didChangeState: .streaming)
                }

            case .quit:
                DebugLog.print("[StreamingService] ❌ Session quit: \(reason ?? "unknown")")
                Task { @MainActor in
                    self.inputGate.withLock { $0 = false }
                    // The console never sends a final rumble-0 and the endless player
                    // latches its last intensity: silence the pad ourselves.
                    self.controllerManager?.triggerRumble(left: 0, right: 0)
                    guard !self.isStopping, self.state != .stopped else { return }
                    self.state = .error(reason ?? "The console ended the session")
                    self.delegate?.streamingService(self, didChangeState: self.state)
                }

            case .holepunch:
                if let reason, let stage = PSNConnectionStage(rawValue: reason) {
                    Task { @MainActor in
                        self.connectionStatusMessage = stage.message
                    }
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
        guard !isStopping else { return }
        isStopping = true
        inputGate.withLock { $0 = false }
        // The pad belongs to the session: stop the input thread and the haptic
        // engine and hand PS / Create / Options back to the system.
        controllerManager?.triggerRumble(left: 0, right: 0)
        controllerManager?.tearDown()
        controllerManager = nil
        DebugLog.info("StreamingService", "Stopping streaming...")
        
        // Stop ChiakiFullSession if active
        let startTask = psnStartTask
        startTask?.cancel()
        ChiakiFullSession.shared.cancelPSN()
        
        videoDecoder?.stop()

        Task { @MainActor in
            _ = await startTask?.result
            await Task.detached(priority: .userInitiated) {
                ChiakiFullSession.shared.teardown()
            }.value
            // Native callbacks are joined before resetting producer-owned audio buffers.
            self.audioPlayer?.stop()
            self.audioPlayer = nil
            self.videoDecoder = nil
            self.configuration = nil
            self.connectionStatusMessage = ""
            self.isStopping = false
            // Phase 5.21: state drives isStreaming.
            self.state = .stopped
            self.delegate?.streamingService(self, didChangeState: .stopped)
        }
        
        DebugLog.info("StreamingService", "Streaming stopped")
    }
    
    // MARK: - Controller Input
    
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

final class StreamVideoDecoder: @unchecked Sendable {
    private let queue: DispatchQueue
    // Bound CPU submissions only. An asynchronous VT output must never hold an
    // admission slot: some streams need further input before producing output.
    private let capacity = DispatchSemaphore(value: 12)
    private struct Lifecycle {
        var running = false
        var generation: UInt64 = 0
        var accepted: UInt64 = 0
        var rejected: UInt64 = 0
        var outputs: UInt64 = 0
        var errors: UInt64 = 0
        var sessions: UInt64 = 0
        var repairedReferences: UInt64 = 0
        var lastReport: Double = 0
        var epoch: UInt64 = 0
    }
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private let isHEVC: Bool

    init(width: Int, height: Int, isHEVC: Bool = true,
         submissionQueue: DispatchQueue = DispatchQueue(label: "video.decode", qos: .userInteractive)) {
        self.isHEVC = isHEVC
        self.queue = submissionQueue
    }
    var diagnostics: (accepted: UInt64, rejected: UInt64, outputs: UInt64, errors: UInt64, sessions: UInt64) {
        lifecycle.withLock { ($0.accepted, $0.rejected, $0.outputs, $0.errors, $0.sessions) }
    }

    func start() { lifecycle.withLock { $0.running = true } }
    func stop() {
        lifecycle.withLock { $0.running = false; $0.generation &+= 1; $0.epoch &+= 1 }
        queue.async { self.resetSession() }
    }

    private func resetSession() {
        if let session = decompressionSession { VTDecompressionSessionInvalidate(session) }
        decompressionSession = nil
        formatDescription = nil
        // Keep valid parameter sets: an IDR need not repeat VPS/SPS/PPS.
        lifecycle.withLock { $0.epoch &+= 1 }
    }

    private func recordDecodeError(_ status: OSStatus) {
        let count = lifecycle.withLock { $0.errors &+= 1; return $0.errors }
        if count <= 3 || count % 60 == 0 {
            DebugLog.print("[VideoDecoder] Decode error=\(status), count=\(count)")
        }
        // Lost references are repaired by Chiaki. Only a genuinely invalid VT
        // session requires recreation; never flush a working reference pool on loss.
        if status == kVTInvalidSessionErr {
            let epoch = lifecycle.withLock { $0.epoch }
            queue.async {
                if self.lifecycle.withLock({ $0.epoch == epoch }) { self.resetSession() }
            }
        }
    }

    /// True means accepted by the decoder pipeline. False ALWAYS means not queued.
    /// Chiaki uses this result to decide which frames may be used as references.
    func submit(pointer: UnsafeRawPointer, size: Int, framesLost: Int32, recovered: Bool,
                completion: @escaping (CVPixelBuffer, UInt64) -> Void) -> Bool {
        guard size > 4, size <= 10_000_000 else { return false }
        let state = lifecycle.withLock { $0 }
        guard state.running else { return false }
        guard capacity.wait(timeout: .now()) == .success else {
            let count = lifecycle.withLock { $0.rejected &+= 1; return $0.rejected }
            if count <= 3 || count % 60 == 0 {
                DebugLog.print("[VideoDecoder] Submission queue full; rejected=\(count)")
            }
            // Keep existing references so Chiaki can remap the next P frame to them.
            return false
        }
        let data = Data(bytes: pointer, count: size)
        let receivedAt = UInt64(CACurrentMediaTime() * 1_000_000)
        lifecycle.withLock { $0.accepted &+= 1; if recovered { $0.repairedReferences &+= 1 } }
        queue.async {
            defer { self.capacity.signal() }
            let current = self.lifecycle.withLock { $0 }
            guard current.running, current.generation == state.generation else { return }
            // recovered is a reference remap, NOT FEC. framesLost is metadata,
            // not an instruction to erase VideoToolbox's surviving references.
            let finished = ContinuationGate()
            let finish: (CVPixelBuffer?) -> Void = { buffer in
                guard finished.tryResume(), let buffer else { return }
                self.lifecycle.withLock { $0.outputs &+= 1 }
                completion(buffer, receivedAt)
            }
            self.decodeAccessUnit(data, receivedAt: receivedAt, generation: state.generation, finish: finish)
            let report = self.lifecycle.withLock { value -> String? in
                let now = CACurrentMediaTime()
                guard now - value.lastReport >= 2 else { return nil }
                value.lastReport = now
                return "[VideoDecoder] accepted=\(value.accepted) outputs=\(value.outputs) rejected=\(value.rejected) errors=\(value.errors) sessions=\(value.sessions) referenceRepairs=\(value.repairedReferences)"
            }
            if let report { DebugLog.print(report) }
        }
        return true
    }

    /// Annex-B ranges, without allocating Data objects for every slice.
    static func nalRanges(_ data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var starts: [(Int, Int)] = []
            var i = 0
            while i + 2 < bytes.count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                    if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                        starts.append((i, i + 4)); i += 4; continue
                    }
                }
                i += 1
            }
            return starts.enumerated().compactMap { index, start in
                let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
                return start.1 < end ? start.1..<end : nil
            }
        }
    }

    private func decodeAccessUnit(_ data: Data, receivedAt: UInt64, generation: UInt64,
                                  finish: @escaping (CVPixelBuffer?) -> Void) {
        let ranges = Self.nalRanges(data)
        guard !ranges.isEmpty else { recordDecodeError(kVTVideoDecoderBadDataErr); finish(nil); return }
        var slices: [Range<Int>] = []
        var changedParameters = false
        for range in ranges {
            let type = isHEVC ? (data[range.lowerBound] >> 1) & 0x3f : data[range.lowerBound] & 0x1f
            if isHEVC && range.count < 2 { recordDecodeError(kVTVideoDecoderBadDataErr); finish(nil); return }
            if (isHEVC && type == 32) {
                let value = data.subdata(in: range)
                changedParameters = changedParameters || (vps != nil && vps != value)
                vps = value
            } else if (isHEVC && type == 33) || (!isHEVC && type == 7) {
                let value = data.subdata(in: range)
                changedParameters = changedParameters || (sps != nil && sps != value)
                sps = value
            } else if (isHEVC && type == 34) || (!isHEVC && type == 8) {
                let value = data.subdata(in: range)
                changedParameters = changedParameters || (pps != nil && pps != value)
                pps = value
            } else if (isHEVC && type <= 31) || (!isHEVC && (type == 1 || type == 5)) {
                slices.append(range)
            }
        }
        if changedParameters { resetSession() }
        guard !slices.isEmpty else { finish(nil); return }
        if isHEVC { tryCreateHEVCSession() } else { tryCreateH264Session() }
        guard let session = decompressionSession, let format = formatDescription else { finish(nil); return }
        // One sample for the COMPLETE access unit, including every VCL slice.
        let length = slices.reduce(0) { $0 + 4 + $1.count }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { recordDecodeError(kVTVideoDecoderBadDataErr); finish(nil); return }
        var offset = 0
        let copied = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            for range in slices {
                var size = UInt32(range.count).bigEndian
                let prefixStatus = withUnsafeBytes(of: &size) {
                    CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                        offsetIntoDestination: offset, dataLength: 4)
                }
                guard prefixStatus == noErr,
                      CMBlockBufferReplaceDataBytes(with: base.advanced(by: range.lowerBound), blockBuffer: block,
                        offsetIntoDestination: offset + 4, dataLength: range.count) == noErr else { return false }
                offset += 4 + range.count
            }
            return true
        }
        guard copied else { recordDecodeError(kVTVideoDecoderBadDataErr); finish(nil); return }
        var size = length
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(receivedAt), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { recordDecodeError(kVTVideoDecoderBadDataErr); finish(nil); return }
        let epoch = lifecycle.withLock { $0.epoch }
        var flags: VTDecodeInfoFlags = []
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: &flags) { status, _, image, _, _ in
                let current = self.lifecycle.withLock { $0 }
                guard current.running, current.generation == generation, current.epoch == epoch else {
                    finish(nil); return
                }
                if status != noErr { self.recordDecodeError(status) }
                finish(status == noErr ? image : nil)
            }
        if status != noErr { recordDecodeError(status); finish(nil) }
        else if flags.contains(.frameDropped) { finish(nil) }
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
            lifecycle.withLock { $0.sessions &+= 1 }
            // Configure for low-latency real-time decoding
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
            DebugLog.print("[VideoDecoder] ✅ Decompression session created (\(isHEVC ? "HEVC" : "H.264"))")
        } else {
            DebugLog.print("[VideoDecoder] ❌ Failed to create decompression session: \(decodeStatus)")
        }
    }
    
}
// MARK: - Data Extension

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
