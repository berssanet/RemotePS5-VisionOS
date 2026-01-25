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
    
    /// Legacy isActive property for compatibility
    var isActive: Bool { state.isActive }
    
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
        
        let result = chiaki_fullsession_stop_wrapper()
        
        state = .idle
        
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

// MARK: - C Callbacks

/// Video frame callback from C
private let videoCallback: ChiakiWrapperVideoCallback = { buf, bufSize, user in
    // Debug logging
    print("[ChiakiCallback] Video callback received: buf=\(String(describing: buf)), size=\(bufSize)")
    
    // Safety checks
    guard let buf = buf else {
        print("[ChiakiCallback] ⚠️ Video buffer is nil!")
        return
    }
    
    guard bufSize > 0 && bufSize < 10_000_000 else { // Reasonable max frame size
        print("[ChiakiCallback] ⚠️ Invalid buffer size: \(bufSize)")
        return
    }
    
    // ZERO-COPY PATH: Pass pointer directly without memory allocation
    // The caller MUST use the data synchronously before this callback returns!
    if ChiakiFullSession.shared.onVideoFramePointer != nil {
        // Pass raw pointer - NO MEMORY COPY!
        ChiakiFullSession.shared.onVideoFramePointer?(buf, bufSize)
        return
    }
    
    // FALLBACK: Legacy path with Data copy (for compatibility)
    // Only used if onVideoFramePointer is not set
    let data = Data(bytes: buf, count: bufSize)
    ChiakiFullSession.shared.onVideoFrame?(data)
}

/// Audio samples callback from C
private let audioCallback: ChiakiWrapperAudioCallback = { buf, samplesCount, user in
    guard let buf = buf else { return }
    
    // Convert samples to bytes (int16_t = 2 bytes per sample)
    let byteCount = samplesCount * 2
    let data = Data(bytes: buf, count: byteCount)
    
    // Audio can stay on background thread - AudioPlayer handles its own threading
    ChiakiFullSession.shared.onAudioSamples?(data, Int(samplesCount))
}

/// Session event callback from C
private let eventCallback: ChiakiWrapperEventCallback = { eventType, reason, user in
    let event = ChiakiEventType(rawValue: eventType) ?? .quit
    var reasonStr: String? = nil
    
    if let reason = reason {
        reasonStr = String(cString: reason)
    }
    
    DispatchQueue.main.async {
        // Update state based on event
        switch event {
        case .connected:
            ChiakiFullSession.shared.state = .streaming
        case .loginPinRequest:
            ChiakiFullSession.shared.state = .loginPinRequest
        case .quit:
            ChiakiFullSession.shared.state = .quit(reason: reasonStr)
        case .rumble:
            // Rumble is now handled by dedicated rumbleCallback (chiaki_set_rumble_callback_wrapper)
            break
        default:
            break
        }
        
        ChiakiFullSession.shared.onEvent?(event, reasonStr)
    }
}

/// Rumble callback from C (called directly from ChiakiCore.c)
private let rumbleCallback: ChiakiWrapperRumbleCallback = { left, right, user in
    DispatchQueue.main.async {
        ChiakiFullSession.shared.onRumble?(left, right)
    }
}
