//
//  GameControllerManager.swift
//  VisionRemotePS5
//
//  Adopts the Bluetooth gamepad paired with the Vision Pro, samples it on the
//  dedicated 120 Hz input thread (HighFrequencyInputController) and forwards each
//  snapshot through onInputReady. Console rumble plays on the pad's own haptic
//  engine, created once per pad (creating it per packet on the main thread was a
//  hang source).
//

import Foundation
import GameController
import CoreHaptics
import UIKit
import os

/// Manages game controller input and maps to PS controller layout
@MainActor
class GameControllerManager: ObservableObject {
    @Published var connectedController: GCController?

    /// Called on the 120 Hz input thread with every sampled snapshot. Consumers must
    /// only touch lock-guarded or thread-safe state (ChiakiFullSession is).
    var onInputReady: ((ControllerInput) -> Void)? {
        get { inputShared.withLockUnchecked { $0.onInputReady } }
        set { inputShared.withLockUnchecked { $0.onInputReady = newValue } }
    }

    // Button bit flags. Must match ChiakiControllerButton / ChiakiControllerAnalogButton
    // in chiaki/controller.h: the mask is handed to the library unchanged.
    struct ButtonMask {
        static let cross: UInt32       = 1 << 0
        static let circle: UInt32      = 1 << 1
        static let square: UInt32      = 1 << 2
        static let triangle: UInt32    = 1 << 3
        static let dpadLeft: UInt32    = 1 << 4
        static let dpadRight: UInt32   = 1 << 5
        static let dpadUp: UInt32      = 1 << 6
        static let dpadDown: UInt32    = 1 << 7
        static let l1: UInt32          = 1 << 8
        static let r1: UInt32          = 1 << 9
        static let l3: UInt32          = 1 << 10
        static let r3: UInt32          = 1 << 11
        static let options: UInt32     = 1 << 12
        static let share: UInt32       = 1 << 13
        static let touchpad: UInt32    = 1 << 14
        static let psButton: UInt32    = 1 << 15
        static let l2: UInt32          = 1 << 16
        static let r2: UInt32          = 1 << 17
    }

    /// Written on the main actor, read on the input thread.
    private struct InputShared {
        var gamepad: GCExtendedGamepad?
        var onInputReady: ((ControllerInput) -> Void)?
    }

    /// Owned by the input thread; the lock keeps the access exclusive.
    private struct InputDiagnostics {
        var lastButtons: UInt32 = 0
        var ticks: UInt64 = 0
        var lastReportTime: TimeInterval = 0
    }

    private let inputShared = OSAllocatedUnfairLock(uncheckedState: InputShared())
    private let inputDiagnostics = OSAllocatedUnfairLock(initialState: InputDiagnostics())
    private let inputLoop = HighFrequencyInputController()

    // CoreHaptics engine on the headset itself (Vision Pro reports no support)
    private var hapticEngine: CHHapticEngine?
    private var isHapticsSupported: Bool = false

    // DualSense haptics: one engine and one endless player per adopted pad.
    // CHHapticEngine exposes no running state, so it is tracked here: the engine
    // stops behind our back on app suspension, audio interruption or a server error.
    private enum ControllerEngineState { case stopped, starting, running }
    private var controllerHapticEngine: CHHapticEngine?
    private var controllerEngineState: ControllerEngineState = .stopped
    private var controllerEngineRetryAt: TimeInterval = 0
    private var rumblePlayer: CHHapticAdvancedPatternPlayer?

    init() {
        setupNotifications()
        checkForConnectedControllers()
        setupHapticEngine()
    }

    deinit {
        // deinit may run on any thread; the loop and the engines are safe to stop there.
        nonisolated(unsafe) let loop = inputLoop
        nonisolated(unsafe) let controllerEngine = controllerHapticEngine
        nonisolated(unsafe) let engine = hapticEngine
        loop.stop()
        controllerEngine?.stop(completionHandler: nil)
        engine?.stop(completionHandler: nil)
    }

    // MARK: - Lifecycle

    /// Start the 120 Hz input thread. Independent of the display refresh rate.
    func startPolling() {
        inputLoop.onInputReady = { [weak self] in self?.inputTick() }
        inputLoop.start()
        DebugLog.print("[Controller] ✅ 120 Hz input thread started")
    }

    func stopPolling() {
        inputLoop.stop()
    }

    /// Releases the pad for the rest of the process: stops the input thread and the
    /// haptic engine and hands PS / Create / Options back to the system. The elements
    /// belong to the system-owned GCController, so deinit alone cannot undo them.
    func tearDown() {
        stopPolling()
        tearDownControllerHaptics()
        let gamepad = inputShared.withLockUnchecked { shared -> GCExtendedGamepad? in
            defer {
                shared.gamepad = nil
                shared.onInputReady = nil
            }
            return shared.gamepad
        }
        if let gamepad {
            restoreSystemGestures(gamepad)
        }
        connectedController = nil
    }

    // MARK: - Input thread

    /// Runs on the input thread: read the pad, log transitions, forward the snapshot.
    nonisolated private func inputTick() {
        let shared = inputShared.withLockUnchecked { ($0.gamepad, $0.onInputReady) }
        guard let gamepad = shared.0 else { return }
        let input = Self.readGamepadState(gamepad)
        logInputDiagnostics(input, gamepad: gamepad)
        shared.1?(input)
    }

    /// Rate-limited: one line per button transition, one stats line every 5 s.
    nonisolated private func logInputDiagnostics(_ input: ControllerInput, gamepad: GCExtendedGamepad) {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let report = inputDiagnostics.withLock { diagnostics -> (buttonsChanged: Bool, rate: Double?) in
            diagnostics.ticks += 1
            let changed = input.buttons != diagnostics.lastButtons
            diagnostics.lastButtons = input.buttons
            var rate: Double?
            if diagnostics.lastReportTime == 0 {
                diagnostics.lastReportTime = now
                diagnostics.ticks = 0
            } else if now - diagnostics.lastReportTime >= 5 {
                rate = Double(diagnostics.ticks) / (now - diagnostics.lastReportTime)
                diagnostics.lastReportTime = now
                diagnostics.ticks = 0
            }
            return (changed, rate)
        }
        if report.buttonsChanged {
            DebugLog.print("[Controller] 🎮 buttons=0x\(String(input.buttons, radix: 16)) L(\(input.leftStickX),\(input.leftStickY)) R(\(input.rightStickX),\(input.rightStickY))")
        }
        if let rate = report.rate {
            DebugLog.print("[Controller] 📊 Input thread \(String(format: "%.1f", rate)) Hz, lastEvent=\(String(format: "%.3f", gamepad.lastEventTimestamp))")
        }
        #endif
    }

    /// Pure read of the whole gamepad into one snapshot (any thread).
    nonisolated private static func readGamepadState(_ gamepad: GCExtendedGamepad) -> ControllerInput {
        var input = ControllerInput()

        // GameController: +Y is up. PlayStation / chiaki feedback: up is negative Y.
        input.leftStickX = gamepad.leftThumbstick.xAxis.value
        input.leftStickY = -gamepad.leftThumbstick.yAxis.value
        input.rightStickX = gamepad.rightThumbstick.xAxis.value
        input.rightStickY = -gamepad.rightThumbstick.yAxis.value
        input.leftTrigger = gamepad.leftTrigger.value
        input.rightTrigger = gamepad.rightTrigger.value

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
        if let dualSense = gamepad as? GCDualSenseGamepad, dualSense.touchpadButton.isPressed {
            buttons |= ButtonMask.touchpad
        }
        if gamepad.dpad.up.isPressed { buttons |= ButtonMask.dpadUp }
        if gamepad.dpad.down.isPressed { buttons |= ButtonMask.dpadDown }
        if gamepad.dpad.left.isPressed { buttons |= ButtonMask.dpadLeft }
        if gamepad.dpad.right.isPressed { buttons |= ButtonMask.dpadRight }
        input.buttons = buttons

        return input
    }

    // MARK: - Discovery

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    private func checkForConnectedControllers() {
        // A pad paired before launch is already in controllers(); adopt it now
        // instead of waiting for the wireless discovery to time out.
        if let controller = Self.preferredController(in: GCController.controllers()) {
            setupController(controller)
            return
        }
        GCController.startWirelessControllerDiscovery { [weak self] in
            Task { @MainActor [weak self] in
                if let controller = Self.preferredController(in: GCController.controllers()) {
                    self?.setupController(controller)
                }
            }
        }
    }

    private static func preferredController(in controllers: [GCController]) -> GCController? {
        controllers.first { $0.extendedGamepad != nil } ?? controllers.first
    }

    @objc private func controllerConnected(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        // Keep the pad already in use unless it lacks an extended profile.
        if let current = connectedController, current !== controller, current.extendedGamepad != nil {
            return
        }
        setupController(controller)
    }

    @objc private func controllerDisconnected(_ notification: Notification) {
        guard let controller = notification.object as? GCController, controller === connectedController else { return }
        DebugLog.print("[Controller] ⛔️ Controller disconnected")
        connectedController = nil
        inputShared.withLockUnchecked { $0.gamepad = nil }
        stopPolling()
        tearDownControllerHaptics()
    }

    /// applicationSuspended stops the pad's engine; Apple says restart it on foreground return.
    @objc private func applicationWillEnterForeground(_ notification: Notification) {
        guard controllerHapticEngine != nil, rumblePlayer == nil else { return }
        restartControllerHaptics()
    }

    private func setupController(_ controller: GCController) {
        connectedController = controller
        DebugLog.print("[Controller] 🎮 Using \(controller.vendorName ?? "controller") (\(controller.productCategory)), extendedGamepad=\(controller.extendedGamepad != nil)")
        if let gamepad = controller.extendedGamepad {
            configureGamepad(gamepad)
        }
        inputShared.withLockUnchecked { $0.gamepad = controller.extendedGamepad }
        prepareControllerHaptics(controller)
        startPolling()
    }

    private func configureGamepad(_ gamepad: GCExtendedGamepad) {
        // visionOS binds PS / Create / Options to system gestures, which delays or
        // swallows the press. The console needs them, so take them exclusively.
        gamepad.buttonHome?.preferredSystemGestureState = .disabled
        gamepad.buttonOptions?.preferredSystemGestureState = .disabled
        gamepad.buttonMenu.preferredSystemGestureState = .disabled
        #if DEBUG
        // Fires on the handler queue independently of the input thread: proves delivery.
        // Pressed-state edges only: the analog triggers change value on every report.
        var lastPressed: [ObjectIdentifier: Bool] = [:]
        gamepad.valueChangedHandler = { _, element in
            guard let button = element as? GCControllerButtonInput else { return }
            let pressed = button.isPressed
            let key = ObjectIdentifier(button)
            guard lastPressed[key] != pressed else { return }
            lastPressed[key] = pressed
            DebugLog.print("[Controller] 🔔 \(element.localizedName ?? "button") pressed=\(pressed)")
        }
        #endif
    }

    private func restoreSystemGestures(_ gamepad: GCExtendedGamepad) {
        gamepad.buttonHome?.preferredSystemGestureState = .enabled
        gamepad.buttonOptions?.preferredSystemGestureState = .enabled
        gamepad.buttonMenu.preferredSystemGestureState = .enabled
        #if DEBUG
        gamepad.valueChangedHandler = nil
        #endif
    }

    // MARK: - Haptics

    /// Rumble from the console (0-255 per motor).
    func triggerRumble(left: UInt8, right: UInt8) {
        let leftIntensity = Float(left) / 255.0
        let rightIntensity = Float(right) / 255.0
        if let player = rumblePlayer {
            sendRumble(to: player, leftIntensity: leftIntensity, rightIntensity: rightIntensity)
            return
        }
        if controllerHapticEngine != nil {
            // Engine stopped externally or still starting: re-arm and drop this packet.
            restartControllerHaptics()
            return
        }
        if isHapticsSupported {
            triggerCoreHaptics(leftIntensity: leftIntensity, rightIntensity: rightIntensity)
        }
    }

    /// Dynamic parameters on the endless player: no allocation per rumble packet.
    private func sendRumble(to player: CHHapticAdvancedPatternPlayer, leftIntensity: Float, rightIntensity: Float) {
        let intensity = max(leftIntensity, rightIntensity)
        let sharpness = rightIntensity / max(leftIntensity + rightIntensity, 0.001)
        do {
            try player.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
        } catch {
            DebugLog.print("[Haptics] Controller rumble error: \(error)")
        }
    }

    /// createEngine and start talk to the haptics daemon over XPC: once per pad, never per packet.
    private func prepareControllerHaptics(_ controller: GCController) {
        tearDownControllerHaptics()
        guard let haptics = controller.haptics,
              let engine = haptics.createEngine(withLocality: .default) else { return }
        engine.isAutoShutdownEnabled = false
        let engineID = ObjectIdentifier(engine)
        // Both handlers arrive off the main thread: touch state on the actor only,
        // and only while this engine is still the adopted one.
        engine.stoppedHandler = { [weak self] reason in
            DebugLog.print("[Haptics] Controller engine stopped: \(reason.rawValue)")
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentControllerEngine(engineID) else { return }
                self.rumblePlayer = nil
                self.controllerEngineState = .stopped
                // A pad disconnect is followed by controllerDisconnected; suspension is
                // re-armed on foreground return; anything else by the next rumble packet.
            }
        }
        engine.resetHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentControllerEngine(engineID) else { return }
                self.controllerEngineState = .stopped
                self.controllerEngineRetryAt = 0
                self.restartControllerHaptics()
            }
        }
        controllerHapticEngine = engine
        restartControllerHaptics()
    }

    private func isCurrentControllerEngine(_ engineID: ObjectIdentifier) -> Bool {
        controllerHapticEngine.map { ObjectIdentifier($0) == engineID } ?? false
    }

    /// Idempotent re-arm: one start in flight at a time, at most one attempt per second,
    /// and only a fresh player when the engine is already running.
    private func restartControllerHaptics() {
        guard let engine = controllerHapticEngine, controllerEngineState != .starting else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= controllerEngineRetryAt else { return }
        controllerEngineRetryAt = now + 1
        rumblePlayer = nil
        if controllerEngineState == .running {
            installRumblePlayer()
            // A player that cannot start means the engine is not really running.
            if rumblePlayer == nil { controllerEngineState = .stopped }
            return
        }
        controllerEngineState = .starting
        let engineID = ObjectIdentifier(engine)
        engine.start { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentControllerEngine(engineID) else { return }
                if let error {
                    self.controllerEngineState = .stopped
                    DebugLog.print("[Haptics] Controller engine start failed: \(error)")
                    return
                }
                self.controllerEngineState = .running
                self.installRumblePlayer()
            }
        }
    }

    /// Endless continuous event at full intensity, muted by an initial intensity control
    /// of 0. Base sharpness is 0 because hapticSharpnessControl is additive (only the
    /// intensity control multiplies), so the left/right ratio lands unchanged.
    private func installRumblePlayer() {
        guard let engine = controllerHapticEngine else { return }
        let motor = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0)
            ],
            relativeTime: 0,
            duration: TimeInterval(GCHapticDurationInfinite)
        )
        let muted = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [motor], parameters: [muted])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            rumblePlayer = player
            DebugLog.print("[Haptics] ✅ Controller rumble player ready")
        } catch {
            DebugLog.print("[Haptics] Controller player error: \(error)")
        }
    }

    private func tearDownControllerHaptics() {
        rumblePlayer = nil
        controllerEngineState = .stopped
        controllerEngineRetryAt = 0
        controllerHapticEngine?.stop(completionHandler: nil)
        controllerHapticEngine = nil
    }

    private func setupHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            DebugLog.print("[Haptics] Device does not support CoreHaptics")
            return
        }

        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.stoppedHandler = { [weak self] reason in
                DebugLog.print("[Haptics] Engine stopped: \(reason)")
                Task { @MainActor [weak self] in self?.isHapticsSupported = false }
            }
            hapticEngine?.resetHandler = { [weak self] in
                DebugLog.print("[Haptics] Engine reset, restarting...")
                Task { @MainActor [weak self] in
                    do {
                        try self?.hapticEngine?.start()
                        self?.isHapticsSupported = true
                    } catch {
                        DebugLog.print("[Haptics] Failed to restart: \(error)")
                    }
                }
            }
            try hapticEngine?.start()
            isHapticsSupported = true
            DebugLog.print("[Haptics] ✅ CoreHaptics engine initialized")
        } catch {
            DebugLog.print("[Haptics] ❌ Failed to create engine: \(error)")
        }
    }

    private func triggerCoreHaptics(leftIntensity: Float, rightIntensity: Float) {
        guard let engine = hapticEngine, isHapticsSupported else { return }
        guard leftIntensity > 0 || rightIntensity > 0 else { return }

        do {
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
