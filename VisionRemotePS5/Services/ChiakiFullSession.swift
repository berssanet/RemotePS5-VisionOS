//
//  ChiakiFullSession.swift
//  VisionRemotePS5
//
//  Swift wrapper for the chiaki_fullsession_* C API
//  Handles full PS5 streaming protocol via chiaki-ng library
//

import Foundation
import CoreVideo
import os  // Phase 5.10: os_unfair_lock for the cross-thread shutdown flag

// MARK: - Chiaki Event Types (from chiaki session.h)

enum ChiakiEventType: Int32 {
    case connected = 0
    case loginPinRequest = 1
    case holepunch = 2
    case regist = 3
    case nicknameReceived = 4
    case keyboardOpen = 5
    case keyboardTextChange = 6
    case keyboardRemoteClose = 7
    case rumble = 8
    case quit = 9
    case triggerEffects = 10
    case motionReset = 11
    case ledColor = 12
    case playerIndex = 13
    case hapticIntensity = 14
    case triggerIntensity = 15
}

// MARK: - Session Callbacks

/// Zero-Copy: Called with raw pointer + size (avoids memory copy)
typealias VideoFramePointerHandler = (UnsafeRawPointer, Int, Int32, Bool) -> Bool

/// Called when audio samples are received
typealias AudioSamplesHandler = (Data, Int) -> Void

/// Called for session events (connect, disconnect, etc)
typealias SessionEventHandler = (ChiakiEventType, String?) -> Void

/// Called for rumble events (leftIntensity, rightIntensity)
typealias RumbleEventHandler = (UInt8, UInt8) -> Void

// MARK: - Session State (matching Android StreamSession)

enum SessionState: Equatable {
    case idle
    case connecting
    case connected
    case loginPinRequest
    case streaming
    case quit(reason: String?)
    
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .streaming, .loginPinRequest:
            return true
        default:
            return false
        }
    }
}

enum PSNStartError: LocalizedError, Equatable {
    case sessionBusy
    case invalidIdentity
    case consoleDidNotJoin
    case requestFailed(code: UInt32)

    var errorDescription: String? {
        switch self {
        case .sessionBusy:
            return "A Remote Play session is already running."
        case .invalidIdentity:
            return "The PSN console identifier or Account ID has an invalid length."
        case .consoleDidNotJoin:
            return "PSN accepted the connection request, but the PS5 did not join the session. Turn on the PS5, confirm it is connected to PSN with this account, and close other Remote Play sessions. If this also fails in the official app from another network, check the console's internet and rest-mode settings."
        case .requestFailed(let code):
            return "PSN connection setup failed (Chiaki error \(code)). Check the connection-stage messages in the log."
        }
    }
}

// MARK: - ChiakiFullSession

/// Swift wrapper for the chiaki-ng full streaming session
final class ChiakiFullSession: ObservableObject {
    
    // MARK: - Properties
    
    static let shared = ChiakiFullSession()
    
    /// Current session state (observable)
    /// Note: fileprivate(set) allows internal callbacks to update state
    @Published fileprivate(set) var state: SessionState = .idle {
        didSet {
            shutdownLock.lock()
            _stateIsActive = state.isActive
            shutdownLock.unlock()
        }
    }
    /// Mirror of `state.isActive` for off-main readers (input thread, chiaki callbacks).
    private var _stateIsActive: Bool = false
    /// Lock-protected read of the mirrored flag; safe from any thread.
    fileprivate var stateIsActive: Bool {
        shutdownLock.lock(); defer { shutdownLock.unlock() }
        return _stateIsActive
    }
    
    /// Flag to prevent callback access during shutdown.
    /// Phase 5.10: lock-protected so C callback threads and the Swift main
    /// thread observe a coherent value without the deadlock-prone
    /// callbackQueue.sync barrier the previous design used.
    fileprivate var isShuttingDown: Bool {
        get {
            shutdownLock.lock(); defer { shutdownLock.unlock() }
            return _isShuttingDown
        }
        set {
            shutdownLock.lock(); defer { shutdownLock.unlock() }
            _isShuttingDown = newValue
        }
    }
    private var _isShuttingDown: Bool = false
    private let shutdownLock = NSLock()
    /// Held across every Swift-originated C call that reads or frees g_active_session.
    /// The 120 Hz input thread try-locks it (a tick is skipped rather than parked behind
    /// a teardown); stop()/teardown() hold it across chiaki_fullsession_stop_wrapper so
    /// the session can never be freed while a controller call is in flight.
    private let controllerCallLock = OSAllocatedUnfairLock()
    
    /// Legacy isActive property for compatibility
    var isActive: Bool { stateIsActive && !isShuttingDown }
    
    // Callbacks
    /// Zero-Copy callback: receives raw pointer without memory copy
    var onVideoFramePointer: VideoFramePointerHandler?
    var onAudioSamples: AudioSamplesHandler?
    var onEvent: SessionEventHandler?
    var onRumble: RumbleEventHandler?
    
    // MARK: - Initialization
    
    private init() {
        DebugLog.info("ChiakiFullSession", "Initialized")
    }
    
    // MARK: - Public API
    
    /// Start streaming with full protocol handling
    func start(
        host: String,
        registKey: Data,        // 16 bytes
        rpKey: Data,            // 16 bytes (morning)
        psnAccountID: Data,     // 8 bytes
        width: UInt32 = 1920,
        height: UInt32 = 1080,
        fps: UInt32 = 60,
        bitrate: UInt32 = 15_000,  // kbps (15 Mbps) - PS5 protocol expects kbps!
        isPS5: Bool = true
    ) -> Bool {
        
        // Allow restart if idle or after any quit (regardless of reason)
        let canStart: Bool
        switch state {
        case .idle:
            canStart = true
        case .quit:
            canStart = true
        default:
            canStart = false
        }
        
        guard canStart else {
            DebugLog.print("[ChiakiFullSession] ❌ Session already active (state: \(state))")
            return false
        }
        
        state = .connecting
        
        // Validate input sizes
        guard registKey.count == 16, rpKey.count == 16 else {
            DebugLog.print("[ChiakiFullSession] ❌ Invalid key sizes: registKey=\(registKey.count), rpKey=\(rpKey.count)")
            return false
        }
        
        DebugLog.print("[ChiakiFullSession] Starting session to \(host)")
        DebugLog.print("[ChiakiFullSession]   Resolution: \(width)x\(height)@\(fps)fps")
        DebugLog.print("[ChiakiFullSession]   Bitrate: \(bitrate) bps")
        DebugLog.print("[ChiakiFullSession]   PS5: \(isPS5)")
        
        // Register rumble callback
        chiaki_set_rumble_callback_wrapper(rumbleCallback)
        
        // Call C wrapper
        let result = host.withCString { hostPtr in
            registKey.withUnsafeBytes { registKeyPtr in
                rpKey.withUnsafeBytes { rpKeyPtr in
                    psnAccountID.withUnsafeBytes { psnIdPtr in
                        chiaki_fullsession_start_wrapper(
                            hostPtr,
                            registKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            rpKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            psnIdPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            width,
                            height,
                            fps,
                            bitrate,
                            isPS5,
                            videoCallback,
                            audioCallback,
                            eventCallback,
                            nil // user_data
                        )
                    }
                }
            }
        }
        
        if result == CHIAKI_ERR_SUCCESS {
            state = .connected
            DebugLog.info("ChiakiFullSession", "✅ Session started successfully")
            return true
        } else {
            DebugLog.print("[ChiakiFullSession] ❌ Session start failed with error: \(result)")
            return false
        }
    }
    
    /// Stop the current session
    func stop() {
        guard isActive else {
            DebugLog.info("ChiakiFullSession", "No active session to stop")
            return
        }
        
        DebugLog.info("ChiakiFullSession", "Stopping session...")
        if chiaki_fullsession_is_active_wrapper(), !chiaki_fullsession_is_started_wrapper() {
            // A PSN start is still in its holepunch phase: only a cancel is legal here.
            cancelPSN()
            return
        }

        // CRITICAL: Set shutdown flag BEFORE stopping to prevent callback crashes
        // C callbacks will check this flag and bail out immediately
        isShuttingDown = true

        // Phase 5.10: replaced the `callbackQueue.sync { }` barrier (which
        // could deadlock when invoked from main while a callback was waiting
        // on main) with a brief drain window. The lock-protected flag
        // guarantees in-flight callbacks see the new value.
        Thread.sleep(forTimeInterval: 0.01)

        let result = controllerCallLock.withLock { chiaki_fullsession_stop_wrapper() }
        
        state = .idle
        
        // Reset shutdown flag after stop completes
        isShuttingDown = false
        
        if result == CHIAKI_ERR_SUCCESS {
            DebugLog.info("ChiakiFullSession", "✅ Session stopped")
        } else {
            DebugLog.print("[ChiakiFullSession] ⚠️ Session stop returned: \(result)")
        }
    }
    
    // MARK: - PSN (holepunch) session — no PIN, no IP

    /// Registered-host payload captured from CHIAKI_EVENT_REGIST (PSN auto-registration).
    struct PSNRegisteredHost {
        let rpKey: Data          // 16 bytes (morning)
        let registKey: String    // hex of the raw regist key bytes, zero padding stripped
        let serverMAC: [UInt8]   // 6 bytes
        let nickname: String
        let consoleIP: String    // address selected by the holepunch (the LAN IP when local)
    }

    /// Start a session through PSN. Blocking for several seconds (push WebSocket,
    /// notifications, holepunch): call from a background thread. With `autoRegist` the
    /// library stops right after `.regist`; read the keys with `copyRegisteredHost()`
    /// and then call `teardown()`.
    func startPSN(
        token: String,
        consoleDUID: Data,      // 32 bytes (PSN device duid, hex decoded)
        isPS5: Bool,
        psnAccountID: Data,     // 8 bytes
        autoRegist: Bool,
        width: UInt32 = 1920,
        height: UInt32 = 1080,
        fps: UInt32 = 60,
        bitrate: UInt32 = 15_000
    ) throws {
        switch state {
        case .idle, .quit:
            break
        default:
            DebugLog.print("[ChiakiFullSession] ❌ Session already active (state: \(state))")
            throw PSNStartError.sessionBusy
        }
        guard consoleDUID.count == 32, psnAccountID.count == 8 else {
            DebugLog.print("[ChiakiFullSession] ❌ PSN start: duid=\(consoleDUID.count) bytes, accountId=\(psnAccountID.count) bytes")
            throw PSNStartError.invalidIdentity
        }
        publishState(.connecting)
        DebugLog.print("[ChiakiFullSession] Starting PSN session (autoRegist=\(autoRegist), ps5=\(isPS5))")
        Self.installCABundle()
        chiaki_set_rumble_callback_wrapper(rumbleCallback)
        let result = token.withCString { tokenPtr in
            consoleDUID.withUnsafeBytes { duidPtr in
                psnAccountID.withUnsafeBytes { idPtr in
                    chiaki_fullsession_start_psn_wrapper(
                        tokenPtr,
                        duidPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        isPS5,
                        idPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        autoRegist,
                        width, height, fps, bitrate,
                        videoCallback, audioCallback, eventCallback,
                        nil
                    )
                }
            }
        }
        if result == CHIAKI_ERR_SUCCESS {
            // Stay `.connecting` (active); the event callback owns `.streaming` / `.quit`.
            DebugLog.info("ChiakiFullSession", "✅ PSN session started")
            return
        }
        publishState(.quit(reason: "PSN session failed (\(result.rawValue))"))
        DebugLog.print("[ChiakiFullSession] ❌ PSN session start failed: \(result)")
        if result == CHIAKI_ERR_HOST_DOWN {
            throw PSNStartError.consoleDidNotJoin
        }
        throw PSNStartError.requestFailed(code: result.rawValue)
    }

    /// Abort a PSN start that is still in its blocking holepunch phase.
    func cancelPSN() {
        chiaki_fullsession_cancel_psn_wrapper()
    }

    /// `state` is observed on main; the blocking wrappers run off-main.
    private func publishState(_ newState: SessionState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    /// Keys + console address captured at `.regist` (PSN auto-registration).
    func copyRegisteredHost() -> PSNRegisteredHost? {
        var rpKey = [UInt8](repeating: 0, count: 16)
        var registKey = [UInt8](repeating: 0, count: 16)
        var mac = [UInt8](repeating: 0, count: 6)
        var nickname = [CChar](repeating: 0, count: 64)
        var ip = [CChar](repeating: 0, count: 64)
        let ok = chiaki_fullsession_copy_registered_host_wrapper(
            &rpKey, &registKey, &mac, &nickname, nickname.count, &ip, ip.count)
        guard ok else { return nil }
        // Same convention as ChiakiBridgeService: the regist key is raw bytes up to the first zero.
        let keyBytes = registKey.prefix { $0 != 0 }
        return PSNRegisteredHost(
            rpKey: Data(rpKey),
            registKey: keyBytes.map { String(format: "%02x", $0) }.joined(),
            serverMAC: mac,
            nickname: String(cString: nickname),
            consoleIP: String(cString: ip)
        )
    }

    /// Stop + free the library session regardless of the Swift state (a session that
    /// already emitted `.quit` is not `isActive`, but the C side still holds it).
    func teardown() {
        guard chiaki_fullsession_is_active_wrapper() else {
            publishState(.idle)
            return
        }
        guard chiaki_fullsession_is_started_wrapper() else {
            // Holepunch phase still running: cancel it; the start wrapper frees itself.
            cancelPSN()
            return
        }
        isShuttingDown = true
        Thread.sleep(forTimeInterval: 0.01)
        let result = controllerCallLock.withLock { chiaki_fullsession_stop_wrapper() }
        publishState(.idle)
        isShuttingDown = false
        DebugLog.info("ChiakiFullSession", "Teardown returned \(result)")
    }

    /// The library's curl (mbedTLS) has no system trust store: hand it the bundled cacert.pem.
    private static func installCABundle() {
        guard let path = Bundle.main.path(forResource: "cacert", ofType: "pem") else {
            DebugLog.print("[ChiakiFullSession] ❌ cacert.pem missing from the app bundle; PSN TLS will fail")
            return
        }
        path.withCString { chiaki_set_ca_bundle_path_wrapper($0) }
    }

    /// Client DUID in PSN format, generated by the library ("0000000700410080" + 32 hex).
    static func makeClientDUID() -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard chiaki_generate_client_duid_wrapper(&buffer, buffer.count) else { return nil }
        return String(cString: buffer)
    }

    /// Update controller state
    func setControllerState(
        buttons: UInt32,
        leftX: Int16, leftY: Int16,
        rightX: Int16, rightY: Int16,
        l2: UInt8, r2: UInt8
    ) {
        // Never park the 120 Hz thread behind a teardown: skip the tick instead.
        guard controllerCallLock.lockIfAvailable() else { return }
        defer { controllerCallLock.unlock() }
        // The C side is the truth for "started": a PSN start still in its holepunch
        // phase holds a zeroed ChiakiSession whose mutexes are not initialized yet.
        guard isActive, chiaki_fullsession_is_started_wrapper() else { return }
        
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = chiaki_fullsession_set_controller_wrapper(
            buttons,
            leftX, leftY,
            rightX, rightY,
            l2, r2
        )
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        if elapsed > 8.33 || result != CHIAKI_ERR_SUCCESS {
            DebugLog.print("[Input] native update=\(String(format: "%.2f", elapsed))ms status=\(result.rawValue)")
        }

    }
}

// MARK: - C Callbacks (with Robust Guards)

/// Type-safe wrapper for raw buffer pointer from C
/// Encapsulates UnsafeRawPointer with bounds checking
struct SafeBufferView {
    let baseAddress: UnsafeRawPointer
    let count: Int
    
    /// Safely create Data by copying bytes (validates bounds)
    func toData() -> Data {
        guard count > 0, count < 50_000_000 else { // 50MB max sanity check
            return Data()
        }
        return Data(bytes: baseAddress, count: count)
    }
}

/// Video frame callback from C
/// ROBUST: Guards against null pointers, invalid sizes, and shutdown state
private let videoCallback: ChiakiWrapperVideoCallback = { buf, bufSize, lost, recovered, user in
    guard !ChiakiFullSession.shared.isShuttingDown,
          ChiakiFullSession.shared.stateIsActive,
          let buf, bufSize > 0, bufSize <= 10_000_000 else { return false }
    return ChiakiFullSession.shared.onVideoFramePointer?(buf, bufSize, lost, recovered) ?? false
}

/// Audio samples callback from C
/// ROBUST: Guards against null pointers and shutdown state
private let audioCallback: ChiakiWrapperAudioCallback = { buf, samplesCount, user in
    // GUARD 1: Check shutdown state
    guard !ChiakiFullSession.shared.isShuttingDown else {
        return
    }
    
    // GUARD 2: Validate session is active
    guard ChiakiFullSession.shared.stateIsActive else {
        return
    }
    
    // GUARD 3: Validate buffer pointer
    guard let buf = buf else {
        return
    }
    
    // GUARD 4: Validate sample count
    guard samplesCount > 0, samplesCount < 100_000 else {
        return
    }
    
    // Convert samples to bytes (int16_t = 2 bytes per sample)
    let byteCount = samplesCount * 2
    let safeBuffer = SafeBufferView(baseAddress: buf, count: byteCount)
    
    // Audio can stay on background thread - AudioPlayer handles its own threading
    if let audioHandler = ChiakiFullSession.shared.onAudioSamples {
        let data = safeBuffer.toData()
        guard !data.isEmpty else { return }
        audioHandler(data, Int(samplesCount))
    }
}

/// Session event callback from C
/// ROBUST: Guards against shutdown and validates event types
private let eventCallback: ChiakiWrapperEventCallback = { eventType, reason, user in
    // Note: We DO process quit events even during shutdown
    // to properly update state, but skip others
    let isQuitEvent = eventType == ChiakiEventType.quit.rawValue
    
    guard !ChiakiFullSession.shared.isShuttingDown || isQuitEvent else {
        return
    }
    
    let event = ChiakiEventType(rawValue: eventType) ?? .quit
    var reasonStr: String? = nil
    
    // Safely convert C string to Swift (guards against invalid pointer)
    if let reason = reason {
        reasonStr = String(cString: reason)
    }
    
    DispatchQueue.main.async {
        // Double-check session still exists (paranoid but safe)
        let session = ChiakiFullSession.shared
        
        // Update state based on event
        switch event {
        case .connected:
            session.state = .streaming
        case .loginPinRequest:
            session.state = .loginPinRequest
        case .quit:
            session.state = .quit(reason: reasonStr)
        case .rumble:
            // Rumble handled by dedicated callback
            break
        default:
            break
        }
        
        session.onEvent?(event, reasonStr)
    }
}

/// Rumble callback from C
/// ROBUST: Guards against shutdown state
private let rumbleCallback: ChiakiWrapperRumbleCallback = { left, right, user in
    // GUARD: Skip if shutting down
    guard !ChiakiFullSession.shared.isShuttingDown else {
        return
    }
    
    guard ChiakiFullSession.shared.stateIsActive else {
        return
    }
    
    // Rumble values are already validated by C layer (0-255)
    DispatchQueue.main.async {
        ChiakiFullSession.shared.onRumble?(left, right)
    }
}
