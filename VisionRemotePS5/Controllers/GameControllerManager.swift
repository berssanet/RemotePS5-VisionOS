import Foundation
import GameController
import Combine
import CoreHaptics

/// Manages game controller input and maps to PS controller layout
@MainActor
class GameControllerManager: ObservableObject {
    @Published var connectedController: GCController?
    @Published var isControllerConnected = false
    @Published var currentInput = ControllerInput()
    @Published var batteryLevel: Float = 1.0
    
    private var inputPublisher = PassthroughSubject<ControllerInput, Never>()
    var inputStream: AnyPublisher<ControllerInput, Never> {
        inputPublisher.eraseToAnyPublisher()
    }
    
    /// v10.1: Direct 120Hz send callback - called on EVERY poll cycle for minimal latency
    /// This bypasses Combine throttling and sends input immediately to the network
    var onInputReady: ((ControllerInput) -> Void)?
    
    private var pollTimer: Timer?
    
    // CoreHaptics engine for rumble
    private var hapticEngine: CHHapticEngine?
    private var continuousLeftPlayer: CHHapticAdvancedPatternPlayer?
    private var continuousRightPlayer: CHHapticAdvancedPatternPlayer?
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
        pollTimer?.invalidate()
        hapticEngine?.stop()
    }
    
    // MARK: - Public Methods
    
    /// Start polling controller input
    func startPolling(interval: TimeInterval = 1.0 / 120.0) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollInput()
            }
        }
    }
    
    /// Stop polling controller input
    func stopPolling() {
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
            print("[Haptics] Rumble: L=\(left) (\(leftIntensity)) R=\(right) (\(rightIntensity))")
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
    
    /// Trigger haptic feedback on DualSense (legacy method)
    func triggerHaptic(_ type: HapticType) {
        let intensity = UInt8(type.intensity * 255)
        triggerRumble(left: intensity, right: intensity)
    }
    
    // MARK: - v9.0 Adaptive Triggers (DualSense)
    
    /// Adaptive trigger modes matching PS5 DualSense
    enum AdaptiveTriggerMode {
        case off             // No resistance
        case feedback        // Resistance at specific point
        case weapon          // Resistance like pulling a gun trigger
        case vibration       // Vibrating resistance
    }
    
    /// Configure adaptive trigger resistance on DualSense controller
    /// - Parameters:
    ///   - trigger: Which trigger (left = L2, right = R2)
    ///   - mode: Effect type (feedback, weapon, vibration)
    ///   - startPosition: Where effect starts (0.0-1.0)
    ///   - strength: Resistance strength (0.0-1.0)
    func setAdaptiveTrigger(
        isLeft: Bool,
        mode: AdaptiveTriggerMode,
        startPosition: Float = 0.0,
        endPosition: Float = 1.0,
        strength: Float = 0.5
    ) {
        guard let controller = connectedController,
              let dualSense = controller.physicalInputProfile as? GCDualSenseGamepad else {
            #if DEBUG
            print("[Haptics] ⚠️ Adaptive triggers require DualSense controller")
            #endif
            return
        }
        
        let trigger = isLeft ? dualSense.leftTrigger : dualSense.rightTrigger
        
        // GCDualSenseAdaptiveTrigger configuration
        // Note: API uses ObjectiveC-style method names with "With" prefix
        switch mode {
        case .off:
            trigger.setModeOff()
        case .feedback:
            trigger.setModeFeedbackWithStartPosition(startPosition, resistiveStrength: strength)
        case .weapon:
            trigger.setModeWeaponWithStartPosition(startPosition, endPosition: endPosition, resistiveStrength: strength)
        case .vibration:
            trigger.setModeVibrationWithStartPosition(startPosition, amplitude: strength, frequency: 0.5)
        }
        
        #if DEBUG
        let side = isLeft ? "L2" : "R2"
        print("[Haptics] 🎮 \(side) Adaptive Trigger: \(mode), strength: \(strength)")
        #endif
    }
    
    /// Reset adaptive triggers to normal (no resistance)
    func resetAdaptiveTriggers() {
        setAdaptiveTrigger(isLeft: true, mode: .off)
        setAdaptiveTrigger(isLeft: false, mode: .off)
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
        isControllerConnected = false
        stopPolling()
    }
    
    private func setupController(_ controller: GCController) {
        connectedController = controller
        isControllerConnected = true
        
        // Monitor battery level
        if let battery = controller.battery {
            batteryLevel = battery.batteryLevel
        }
        
        // Configure for DualSense if available
        if let dualSense = controller.extendedGamepad {
            configureDualSense(dualSense)
        }
        
        startPolling()
    }
    
    private func configureDualSense(_ gamepad: GCExtendedGamepad) {
        // Set up value changed handlers for real-time response
        gamepad.valueChangedHandler = { [weak self] _, element in
            Task { @MainActor [weak self] in
                self?.pollInput()
            }
        }
    }
    
    private func pollInput() {
        guard let gamepad = connectedController?.extendedGamepad else { return }
        
        var input = ControllerInput()
        
        // Analog sticks
        input.leftStickX = gamepad.leftThumbstick.xAxis.value
        input.leftStickY = gamepad.leftThumbstick.yAxis.value
        input.rightStickX = gamepad.rightThumbstick.xAxis.value
        input.rightStickY = gamepad.rightThumbstick.yAxis.value
        
        // Triggers
        input.leftTrigger = gamepad.leftTrigger.value
        input.rightTrigger = gamepad.rightTrigger.value
        
        // Buttons
        var buttons: UInt32 = 0
        
        if gamepad.buttonA.isPressed { buttons |= ButtonMask.cross }
        if gamepad.buttonB.isPressed { buttons |= ButtonMask.circle }
        if gamepad.buttonX.isPressed { buttons |= ButtonMask.square }
        if gamepad.buttonY.isPressed { buttons |= ButtonMask.triangle }
        
        if gamepad.leftShoulder.isPressed { buttons |= ButtonMask.l1 }
        if gamepad.rightShoulder.isPressed { buttons |= ButtonMask.r1 }
        
        if gamepad.leftTrigger.isPressed { buttons |= ButtonMask.l2 }
        if gamepad.rightTrigger.isPressed { buttons |= ButtonMask.r2 }
        
        if gamepad.leftThumbstickButton?.isPressed ?? false { buttons |= ButtonMask.l3 }
        if gamepad.rightThumbstickButton?.isPressed ?? false { buttons |= ButtonMask.r3 }
        
        if gamepad.buttonMenu.isPressed { buttons |= ButtonMask.options }
        if gamepad.buttonOptions?.isPressed ?? false { buttons |= ButtonMask.share }
        if gamepad.buttonHome?.isPressed ?? false { buttons |= ButtonMask.psButton }
        
        // D-Pad
        if gamepad.dpad.up.isPressed { buttons |= ButtonMask.dpadUp }
        if gamepad.dpad.down.isPressed { buttons |= ButtonMask.dpadDown }
        if gamepad.dpad.left.isPressed { buttons |= ButtonMask.dpadLeft }
        if gamepad.dpad.right.isPressed { buttons |= ButtonMask.dpadRight }
        
        input.buttons = buttons
        
        currentInput = input
        
        // v10.1: Direct 120Hz send - invoke callback immediately for minimal latency
        // This sends input to network on every poll cycle (8.3ms intervals)
        onInputReady?(input)
        
        // Also publish for any Combine subscribers
        inputPublisher.send(input)
    }
    
    // MARK: - Haptics Implementation
    
    private func setupHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("[Haptics] Device does not support CoreHaptics")
            return
        }
        
        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.stoppedHandler = { [weak self] reason in
                print("[Haptics] Engine stopped: \(reason)")
                self?.isHapticsSupported = false
            }
            hapticEngine?.resetHandler = { [weak self] in
                print("[Haptics] Engine reset, restarting...")
                do {
                    try self?.hapticEngine?.start()
                    self?.isHapticsSupported = true
                } catch {
                    print("[Haptics] Failed to restart: \(error)")
                }
            }
            try hapticEngine?.start()
            isHapticsSupported = true
            print("[Haptics] ✅ CoreHaptics engine initialized")
        } catch {
            print("[Haptics] ❌ Failed to create engine: \(error)")
        }
    }
    
    private func triggerControllerHaptics(_ haptics: GCDeviceHaptics, leftIntensity: Float, rightIntensity: Float) {
        // DualSense has separate left/right haptic motors
        // Left = low frequency rumble, Right = high frequency rumble
        
        // GCDeviceHaptics requires creating a haptic pattern
        // This is device-specific and may not work on all controllers
        
        guard let engine = haptics.createEngine(withLocality: .default) else {
            print("[Haptics] Failed to create controller haptic engine")
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
            print("[Haptics] Controller haptic error: \(error)")
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
            print("[Haptics] CoreHaptics error: \(error)")
        }
    }
}

// MARK: - Haptic Types

enum HapticType {
    case light
    case medium
    case heavy
    case success
    case warning
    case error
    
    var intensity: Float {
        switch self {
        case .light: return 0.3
        case .medium: return 0.6
        case .heavy: return 1.0
        case .success: return 0.5
        case .warning: return 0.7
        case .error: return 0.9
        }
    }
    
    var sharpness: Float {
        switch self {
        case .light: return 0.3
        case .medium: return 0.5
        case .heavy: return 0.8
        case .success: return 0.6
        case .warning: return 0.7
        case .error: return 0.9
        }
    }
}
