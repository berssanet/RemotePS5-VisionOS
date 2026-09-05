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
    private let handlerQueue = DispatchQueue(label: "controller.events", qos: .userInteractive)
    private let samplingLock = NSLock()

    private let rumble = ControllerRumbleWorker()

    init() {
        setupNotifications()
        checkForConnectedControllers()
    }

    deinit {
        nonisolated(unsafe) let loop = inputLoop
        let worker = rumble
        loop.stop()
        worker.stop()
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
        rumble.stop()
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
        samplingLock.lock()
        defer { samplingLock.unlock() }
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
        let sendNeutral = inputShared.withLockUnchecked { shared -> ((ControllerInput) -> Void)? in
            shared.gamepad = nil
            return shared.onInputReady
        }
        if let gamepad = controller.extendedGamepad { restoreSystemGestures(gamepad) }
        handlerQueue.async { [self] in
            samplingLock.lock()
            defer { samplingLock.unlock() }
            sendNeutral?(ControllerInput())
        }
        stopPolling()
        rumble.stop()
    }

    /// applicationSuspended stops the pad's engine; Apple says restart it on foreground return.
    @objc private func applicationWillEnterForeground(_ notification: Notification) {
        guard UserDefaults.standard.object(forKey: "enableHaptics") as? Bool != false else { return }
        if let controller = connectedController { rumble.adopt(controller) }
    }

    private func setupController(_ controller: GCController) {
        controller.handlerQueue = handlerQueue
        connectedController = controller
        DebugLog.print("[Controller] 🎮 Using \(controller.vendorName ?? "controller") (\(controller.productCategory)), extendedGamepad=\(controller.extendedGamepad != nil)")
        if let gamepad = controller.extendedGamepad {
            configureGamepad(gamepad)
        }
        inputShared.withLockUnchecked { $0.gamepad = controller.extendedGamepad }
        if UserDefaults.standard.object(forKey: "enableHaptics") as? Bool != false {
            rumble.adopt(controller)
        }
        startPolling()
    }

    private func configureGamepad(_ gamepad: GCExtendedGamepad) {
        // visionOS binds PS / Create / Options to system gestures, which delays or
        // swallows the press. The console needs them, so take them exclusively.
        gamepad.buttonHome?.preferredSystemGestureState = .disabled
        gamepad.buttonOptions?.preferredSystemGestureState = .disabled
        gamepad.buttonMenu.preferredSystemGestureState = .disabled
        // Capture transitions immediately; 120 Hz polling remains for stick motion and heartbeat.
        // Serialization with polling prevents a stale sampled release overtaking a new press.
        gamepad.valueChangedHandler = { [weak self] _, _ in self?.inputTick() }
    }

    private func restoreSystemGestures(_ gamepad: GCExtendedGamepad) {
        gamepad.buttonHome?.preferredSystemGestureState = .enabled
        gamepad.buttonOptions?.preferredSystemGestureState = .enabled
        gamepad.buttonMenu.preferredSystemGestureState = .enabled
        gamepad.valueChangedHandler = nil
    }

    func triggerRumble(left: UInt8, right: UInt8) {
        rumble.submit(left: left, right: right)
    }
}

/// All XPC/engine/player calls run on this serial worker, never on main or input.
/// A service failure disables rumble until reconnect/foreground, not per-packet retry.
final class ControllerRumbleWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "controller.haptics", qos: .utility)
    private struct State {
        var generation: UInt64 = 0
        var enabled = false
        var pending: (UInt8, UInt8)?
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    func adopt(_ controller: GCController) {
        let generation = state.withLock { value -> UInt64 in
            value.generation &+= 1
            value.enabled = false
            value.pending = nil
            return value.generation
        }
        queue.async { [self] in
            guard state.withLock({ $0.generation == generation }) else { return }
            releaseEngine()
            guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
            self.engine = engine
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] _ in self?.disable(generation: generation) }
            engine.resetHandler = { [weak self] in self?.disable(generation: generation) }
            do {
                try engine.start()
                let motor = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0)
                ], relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
                let muted = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
                let pattern = try CHHapticPattern(events: [motor], parameters: [muted])
                let player = try engine.makeAdvancedPlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                self.player = player
                let current = state.withLock { value -> Bool in
                    guard value.generation == generation else { return false }
                    value.enabled = true
                    return true
                }
                if !current { releaseEngine() }
            } catch {
                disable(generation: generation)
                DebugLog.print("[Haptics] Disabled after service failure; video/input remain active: \(error)")
            }
        }
    }

    func submit(left: UInt8, right: UInt8) {
        let schedule = state.withLock { value -> Bool in
            guard value.enabled else { return false }
            value.pending = (left, right)
            guard !value.scheduled else { return false }
            value.scheduled = true
            return true
        }
        guard schedule else { return }
        // One coalesced update per interval, even if the console sends a burst.
        queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
            let work = state.withLock { value -> ((UInt8, UInt8)?, UInt64) in
                defer { value.scheduled = false; value.pending = nil }
                return (value.enabled ? value.pending : nil, value.generation)
            }
            guard let (left, right) = work.0, let player else { return }
            let l = Float(left) / 255
            let r = Float(right) / 255
            do {
                try player.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: max(l, r), relativeTime: 0),
                    CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: r / max(l + r, 0.001), relativeTime: 0)
                ], atTime: CHHapticTimeImmediate)
            } catch {
                disable(generation: work.1)
                DebugLog.print("[Haptics] Disabled after rumble error: \(error)")
            }
        }
    }
    private func disable(generation: UInt64) {
        let current = state.withLock { value -> Bool in
            guard value.generation == generation else { return false }
            value.enabled = false; value.pending = nil
            return true
        }
        if current {
            queue.async { [self] in
                if state.withLock({ $0.generation == generation }) { releaseEngine() }
            }
        }
    }
    func stop() {
        state.withLock { $0.generation &+= 1; $0.enabled = false; $0.pending = nil }
        queue.async { [self] in releaseEngine() }
    }
    private func releaseEngine() {
        player = nil
        engine?.stoppedHandler = { _ in }
        engine?.resetHandler = {}
        engine?.stop(completionHandler: nil)
        engine = nil
    }
}
