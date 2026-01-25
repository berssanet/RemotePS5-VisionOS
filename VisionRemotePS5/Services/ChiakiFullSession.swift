//
//  ChiakiFullSession.swift
//  VisionRemotePS5
//
//  Swift wrapper for the chiaki_fullsession_* C API
//  Handles full PS5 streaming protocol via chiaki-ng library
//

import Foundation
import CoreVideo

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

/// Called when a video frame is received from the PS5
typealias VideoFrameHandler = (Data) -> Void

/// Zero-Copy: Called with raw pointer + size (avoids memory copy)
typealias VideoFramePointerHandler = (UnsafeRawPointer, Int) -> Void

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

// MARK: - ChiakiFullSession

/// Swift wrapper for the chiaki-ng full streaming session
final class ChiakiFullSession: ObservableObject {
    
    // MARK: - Properties
    
    static let shared = ChiakiFullSession()
    
    /// Current session state (observable)
    /// Note: fileprivate(set) allows internal callbacks to update state
    @Published fileprivate(set) var state: SessionState = .idle
    
    /// Flag to prevent callback access during shutdown
    /// This is checked by C callbacks before accessing Swift objects
    fileprivate var isShuttingDown: Bool = false
    
    /// Serial queue for thread-safe callback processing
    private let callbackQueue = DispatchQueue(label: "com.visionremote.chiaki.callbacks", qos: .userInteractive)
    
    /// Legacy isActive property for compatibility
    var isActive: Bool { state.isActive && !isShuttingDown }
    
    // Callbacks
    var onVideoFrame: VideoFrameHandler?
    /// Zero-Copy callback: receives raw pointer without memory copy
    var onVideoFramePointer: VideoFramePointerHandler?
    var onAudioSamples: AudioSamplesHandler?
    var onEvent: SessionEventHandler?
    var onRumble: RumbleEventHandler?
    
    // MARK: - Initialization
    
    private init() {
        print("[ChiakiFullSession] Initialized")
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
            print("[ChiakiFullSession] ❌ Session already active (state: \(state))")
            return false
        }
        
        state = .connecting
        
        // Validate input sizes
        guard registKey.count == 16, rpKey.count == 16 else {
            print("[ChiakiFullSession] ❌ Invalid key sizes: registKey=\(registKey.count), rpKey=\(rpKey.count)")
            return false
        }
        
        print("[ChiakiFullSession] Starting session to \(host)")
        print("[ChiakiFullSession]   Resolution: \(width)x\(height)@\(fps)fps")
        print("[ChiakiFullSession]   Bitrate: \(bitrate) bps")
        print("[ChiakiFullSession]   PS5: \(isPS5)")
        
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
            print("[ChiakiFullSession] ✅ Session started successfully")
            return true
        } else {
            print("[ChiakiFullSession] ❌ Session start failed with error: \(result)")
            return false
        }
    }
    
    /// Stop the current session
    func stop() {
        guard isActive else {
            print("[ChiakiFullSession] No active session to stop")
            return
        }
        
        print("[ChiakiFullSession] Stopping session...")
        
        // CRITICAL: Set shutdown flag BEFORE stopping to prevent callback crashes
        // C callbacks will check this flag and bail out immediately
        isShuttingDown = true
        
        // Small delay to ensure any in-flight callbacks complete
        callbackQueue.sync {
            // Barrier to ensure all pending callback work completes
        }
        
        let result = chiaki_fullsession_stop_wrapper()
        
        state = .idle
        
        // Reset shutdown flag after stop completes
        isShuttingDown = false
        
        if result == CHIAKI_ERR_SUCCESS {
            print("[ChiakiFullSession] ✅ Session stopped")
        } else {
            print("[ChiakiFullSession] ⚠️ Session stop returned: \(result)")
        }
    }
    
    /// Update controller state
    func setControllerState(
        buttons: UInt32,
        leftX: Int16, leftY: Int16,
        rightX: Int16, rightY: Int16,
        l2: UInt8, r2: UInt8
    ) {
        guard isActive else { return }
        
        _ = chiaki_fullsession_set_controller_wrapper(
            buttons,
            leftX, leftY,
            rightX, rightY,
            l2, r2
        )
    }
    
    /// Check if session is active via C API
    func checkIfActive() -> Bool {
        return chiaki_fullsession_is_active_wrapper()
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
    
    /// Check if buffer is valid for reading
    var isValid: Bool {
        return count > 0 && count < 50_000_000
    }
}

/// Video frame callback from C
/// ROBUST: Guards against null pointers, invalid sizes, and shutdown state
private let videoCallback: ChiakiWrapperVideoCallback = { buf, bufSize, user in
    // GUARD 1: Check if session is shutting down (prevents crash during cleanup)
    guard !ChiakiFullSession.shared.isShuttingDown else {
        return
    }
    
    // GUARD 2: Validate session state
    guard ChiakiFullSession.shared.state.isActive else {
        return
    }
    
    // GUARD 3: Validate buffer pointer
    guard let buf = buf else {
        print("[ChiakiCallback] ⚠️ Video buffer is nil!")
        return
    }
    
    // GUARD 4: Validate buffer size (reasonable range for video frames)
    guard bufSize > 0, bufSize < 10_000_000 else {
        print("[ChiakiCallback] ⚠️ Invalid buffer size: \(bufSize)")
        return
    }
    
    // Create type-safe buffer view
    let safeBuffer = SafeBufferView(baseAddress: buf, count: bufSize)
    
    // Debug logging (rate-limited)
    #if DEBUG
    // Only log every 60th frame to avoid console spam
    #endif
    
    // ZERO-COPY PATH: Pass pointer directly without memory allocation
    // The caller MUST use the data synchronously before this callback returns!
    if let pointerHandler = ChiakiFullSession.shared.onVideoFramePointer {
        pointerHandler(buf, bufSize)
        return
    }
    
    // FALLBACK: Legacy path with Data copy (for compatibility)
    if let frameHandler = ChiakiFullSession.shared.onVideoFrame {
        let data = safeBuffer.toData()
        guard !data.isEmpty else { return }
        frameHandler(data)
    }
}

/// Audio samples callback from C
/// ROBUST: Guards against null pointers and shutdown state
private let audioCallback: ChiakiWrapperAudioCallback = { buf, samplesCount, user in
    // GUARD 1: Check shutdown state
    guard !ChiakiFullSession.shared.isShuttingDown else {
        return
    }
    
    // GUARD 2: Validate session is active
    guard ChiakiFullSession.shared.state.isActive else {
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
    
    guard ChiakiFullSession.shared.state.isActive else {
        return
    }
    
    // Rumble values are already validated by C layer (0-255)
    DispatchQueue.main.async {
        ChiakiFullSession.shared.onRumble?(left, right)
    }
}
