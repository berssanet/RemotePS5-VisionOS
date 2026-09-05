import Foundation
import GameController
import Combine
import CoreHaptics
import QuartzCore  // CADisplayLink for vsync-synchronized polling

/// Manages game controller input and maps to PS controller layout
@MainActor
class GameControllerManager: ObservableObject {
    @Published var connectedController: GCController?
    
    /// v10.1: Direct 120Hz send callback - called on EVERY poll cycle for minimal latency
    /// This bypasses Combine throttling and sends input immediately to the network
    var onInputReady: ((ControllerInput) -> Void)?
    
    // MARK: - Display-Synchronized Polling (Motion-to-Photon Optimization)
    /// CADisplayLink for vsync-synchronized input polling
    /// Reduces motion-to-photon latency by reading input at the start of each frame
    private var displayLink: CADisplayLink?
    
    /// Fallback timer for when display link is not available
    private var pollTimer: Timer?
    
    /// Last polled input state (for delta detection)
    private var lastPolledInput = ControllerInput()
    
    /// Timestamp of last input poll (monotonic clock)
    private var lastPollTime: CFTimeInterval = 0
    
    /// Statistics: Average input-to-render latency in milliseconds
    @Published var inputLatencyMs: Double = 0
    private var latencySamples: [Double] = []
    private let maxLatencySamples = 60
    
    // CoreHaptics engine for rumble
    private var hapticEngine: CHHapticEngine?
    private var isHapticsSupported: Bool = false
    
    // Button bit flags (matching PS controller layout)
    struct ButtonMask {
        static let cross: UInt32       = 1 << 0
        static let circle: UInt32      = 1 << 1
        static let square: UInt32      = 1 << 2
        static let triangle: UInt32    = 1 << 3
        static let l1: UInt32          = 1 << 4
        static let r1: UInt32          = 1 << 5
        static let l2: UInt32          = 1 << 6
        static let r2: UInt32          = 1 << 7
        static let share: UInt32       = 1 << 8
        static let options: UInt32     = 1 << 9
        static let l3: UInt32          = 1 << 10
        static let r3: UInt32          = 1 << 11
        static let psButton: UInt32    = 1 << 12
        static let touchpad: UInt32    = 1 << 13
        static let dpadUp: UInt32      = 1 << 14
        static let dpadDown: UInt32    = 1 << 15
        static let dpadLeft: UInt32    = 1 << 16
        static let dpadRight: UInt32   = 1 << 17
    }
    
    init() {
        setupNotifications()
        checkForConnectedControllers()
        setupHapticEngine()
    }
    
    deinit {
        // Phase 5.14: deinit may run on any thread. CADisplayLink.invalidate()
        // must run on the same runloop it was added to (main). Capture locally
        // and dispatch the invalidation to main; the timer/engine cleanups are
        // thread-safe so they stay inline. nonisolated(unsafe): CADisplayLink
        // and Timer are not Sendable, but they are only touched on main inside
        // the dispatched block.
        nonisolated(unsafe) let link = displayLink
        nonisolated(unsafe) let timer = pollTimer
        DispatchQueue.main.async {
            link?.invalidate()
            timer?.invalidate()
        }
        hapticEngine?.stop()
    }
    
    // MARK: - Public Methods
    
    /// Start polling controller input using CADisplayLink (vsync-synchronized)
    /// This ensures input is sampled at the start of each frame for minimal latency
    /// - Parameter preferredFPS: Target polling rate (default 120Hz for Vision Pro)
    func startPolling(preferredFPS: Int = 120) {
        stopPolling()
        
        // Create CADisplayLink on main thread for vsync synchronization
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        
        // Configure for high refresh rate (120Hz on Vision Pro).
        // Phase 5.12: use the public `preferred:` initializer; the underscored
        // `__preferred:` variant is private SPI and triggers App Store rejection.
        if #available(visionOS 1.0, iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: Float(preferredFPS),
                preferred: Float(preferredFPS)
            )
        }
        
        // Add to common run loop mode for consistent firing
        displayLink?.add(to: .main, forMode: .common)
        
        lastPollTime = CACurrentMediaTime()
        DebugLog.print("[Controller] ✅ Display-linked polling started at \(preferredFPS)Hz (vsync-synchronized)")
    }
    
    /// Stop all polling methods
    func stopPolling() {
        displayLink?.invalidate()
        displayLink = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    /// Trigger rumble feedback (left = low frequency, right = high frequency)
    /// Values are 0-255, matching PS5 DualSense rumble
    func triggerRumble(left: UInt8, right: UInt8) {
        // Convert 0-255 to 0.0-1.0
        let leftIntensity = Float(left) / 255.0
        let rightIntensity = Float(right) / 255.0
        
        #if DEBUG
        if left > 0 || right > 0 {
            DebugLog.print("[Haptics] Rumble: L=\(left) (\(leftIntensity)) R=\(right) (\(rightIntensity))")
        }
        #endif
        
        // Try controller haptics first (DualSense)
        if let controller = connectedController,
           let haptics = controller.haptics {
            triggerControllerHaptics(haptics, leftIntensity: leftIntensity, rightIntensity: rightIntensity)
            return
        }
        
        // Fallback to CoreHaptics engine
        if isHapticsSupported {
            triggerCoreHaptics(leftIntensity: leftIntensity, rightIntensity: rightIntensity)
        }
    }
    
    // MARK: - Private Methods
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerConnected),
            name: .GCControllerDidConnect,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDisconnected),
            name: .GCControllerDidDisconnect,
            object: nil
        )
    }
    
    private func checkForConnectedControllers() {
        GCController.startWirelessControllerDiscovery { [weak self] in
            Task { @MainActor [weak self] in
                if let controller = GCController.controllers().first {
                    self?.setupController(controller)
                }
            }
        }
    }
    
    @objc private func controllerConnected(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        setupController(controller)
    }
    
    @objc private func controllerDisconnected(_ notification: Notification) {
        connectedController = nil
        stopPolling()
    }
    
    private func setupController(_ controller: GCController) {
        connectedController = controller
        
        // Configure for DualSense if available
        if let dualSense = controller.extendedGamepad {
            configureDualSense(dualSense)
        }
        
        startPolling()
    }
    
    private func configureDualSense(_ gamepad: GCExtendedGamepad) {
        // Note: We no longer rely on valueChangedHandler for primary input
        // Instead, we use display-synchronized polling for consistent timing
        // The handler is kept as a backup for detecting rapid button presses
        // that might occur between poll cycles
        gamepad.valueChangedHandler = { [weak self] _, element in
            // Only update on button state changes (not analog - too noisy)
            if element is GCControllerButtonInput {
                Task { @MainActor [weak self] in
                    // Mark that input changed - will be picked up on next poll
                    self?.lastPolledInput.buttons = 0xFFFFFFFF // Force delta
                }
            }
        }
    }
    
    // MARK: - Display Link Handler
    
    /// Called by CADisplayLink on every vsync (start of frame)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Measure time since last poll
        let now = link.timestamp
        let deltaTime = now - lastPollTime
        lastPollTime = now
        
        // Poll input synchronously at frame start
        pollInput()
        
        // Debug: Log frame timing every 120 frames (~1 second)
        #if DEBUG
        if Int(now * 120) % 120 == 0 {
            let fps = 1.0 / deltaTime
            DebugLog.print("[Controller] 📊 Polling at \(String(format: "%.1f", fps))Hz, latency: \(String(format: "%.2f", inputLatencyMs))ms")
        }
        #endif
    }
    
    /// Update rolling average of input latency
    private func updateLatencyStats(_ latencyMs: Double) {
        latencySamples.append(latencyMs)
        if latencySamples.count > maxLatencySamples {
            latencySamples.removeFirst()
        }
        inputLatencyMs = latencySamples.reduce(0, +) / Double(latencySamples.count)
    }
    
    /// Internal poll method - reads gamepad and dispatches input
    private func pollInput() {
        guard let gamepad = connectedController?.extendedGamepad else { return }
        
        let startTime = CACurrentMediaTime()
        
        // Read gamepad state
        let input = readGamepadState(gamepad)
        
        // Update state
        lastPolledInput = input
        
        // Measure and track latency
        let latencyMs = (CACurrentMediaTime() - startTime) * 1000.0
        updateLatencyStats(latencyMs)
        
        // v10.1: Direct send - invoke callback immediately for minimal latency
        onInputReady?(input)
    }
    
    /// Pure function to read all gamepad state into ControllerInput struct
    /// Optimized for minimal overhead - no branching on hot path
    private func readGamepadState(_ gamepad: GCExtendedGamepad) -> ControllerInput {
        var input = ControllerInput()
        
        // Analog sticks (direct memory read, no method calls)
        input.leftStickX = gamepad.leftThumbstick.xAxis.value
        input.leftStickY = gamepad.leftThumbstick.yAxis.value
        input.rightStickX = gamepad.rightThumbstick.xAxis.value
        input.rightStickY = gamepad.rightThumbstick.yAxis.value
        
        // Triggers (analog values)
        input.leftTrigger = gamepad.leftTrigger.value
        input.rightTrigger = gamepad.rightTrigger.value
        
        // Buttons - build bitmask with bitwise OR (single cycle per button)
        var buttons: UInt32 = 0
        
        // Face buttons
        if gamepad.buttonA.isPressed { buttons |= ButtonMask.cross }
        if gamepad.buttonB.isPressed { buttons |= ButtonMask.circle }
        if gamepad.buttonX.isPressed { buttons |= ButtonMask.square }
        if gamepad.buttonY.isPressed { buttons |= ButtonMask.triangle }
        
        // Shoulders
        if gamepad.leftShoulder.isPressed { buttons |= ButtonMask.l1 }
        if gamepad.rightShoulder.isPressed { buttons |= ButtonMask.r1 }
        
        // Trigger buttons (digital threshold)
        if gamepad.leftTrigger.isPressed { buttons |= ButtonMask.l2 }
        if gamepad.rightTrigger.isPressed { buttons |= ButtonMask.r2 }
        
        // Thumbstick clicks
        if gamepad.leftThumbstickButton?.isPressed ?? false { buttons |= ButtonMask.l3 }
        if gamepad.rightThumbstickButton?.isPressed ?? false { buttons |= ButtonMask.r3 }
        
        // Menu/System buttons
        if gamepad.buttonMenu.isPressed { buttons |= ButtonMask.options }
        if gamepad.buttonOptions?.isPressed ?? false { buttons |= ButtonMask.share }
        if gamepad.buttonHome?.isPressed ?? false { buttons |= ButtonMask.psButton }
        
        // D-Pad
        if gamepad.dpad.up.isPressed { buttons |= ButtonMask.dpadUp }
        if gamepad.dpad.down.isPressed { buttons |= ButtonMask.dpadDown }
        if gamepad.dpad.left.isPressed { buttons |= ButtonMask.dpadLeft }
        if gamepad.dpad.right.isPressed { buttons |= ButtonMask.dpadRight }
        
        input.buttons = buttons
        
        return input
    }
    
    // MARK: - Haptics Implementation
    
    private func setupHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            DebugLog.print("[Haptics] Device does not support CoreHaptics")
            return
        }
        
        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.stoppedHandler = { [weak self] reason in
                DebugLog.print("[Haptics] Engine stopped: \(reason)")
                self?.isHapticsSupported = false
            }
            hapticEngine?.resetHandler = { [weak self] in
                DebugLog.print("[Haptics] Engine reset, restarting...")
                do {
                    try self?.hapticEngine?.start()
                    self?.isHapticsSupported = true
                } catch {
                    DebugLog.print("[Haptics] Failed to restart: \(error)")
                }
            }
            try hapticEngine?.start()
            isHapticsSupported = true
            DebugLog.print("[Haptics] ✅ CoreHaptics engine initialized")
        } catch {
            DebugLog.print("[Haptics] ❌ Failed to create engine: \(error)")
        }
    }
    
    private func triggerControllerHaptics(_ haptics: GCDeviceHaptics, leftIntensity: Float, rightIntensity: Float) {
        // DualSense has separate left/right haptic motors
        // Left = low frequency rumble, Right = high frequency rumble
        
        // GCDeviceHaptics requires creating a haptic pattern
        // This is device-specific and may not work on all controllers
        
        guard let engine = haptics.createEngine(withLocality: .default) else {
            DebugLog.print("[Haptics] Failed to create controller haptic engine")
            return
        }
        
        do {
            try engine.start()
            
            // Create combined haptic event
            let intensity = max(leftIntensity, rightIntensity)
            let sharpness = rightIntensity / max(leftIntensity + rightIntensity, 0.001)
            
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0,
                duration: 0.1
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            
        } catch {
            DebugLog.print("[Haptics] Controller haptic error: \(error)")
        }
    }
    
    private func triggerCoreHaptics(leftIntensity: Float, rightIntensity: Float) {
        guard let engine = hapticEngine, isHapticsSupported else { return }
        
        // Skip if both are zero
        guard leftIntensity > 0 || rightIntensity > 0 else { return }
        
        do {
            // DualSense rumble: left = low freq bass, right = high freq vibration
            // Map to haptic: intensity from combined, sharpness from ratio
            let intensity = max(leftIntensity, rightIntensity)
            let sharpness = rightIntensity / max(leftIntensity + rightIntensity, 0.001)
            
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            
        } catch {
            DebugLog.print("[Haptics] CoreHaptics error: \(error)")
        }
    }
}
