//
//  ControllerTestRangeView.swift
//  VisionRemotePS5
//
//  v13.0 "Controller Test Range": the content of the "TrainingRangeSpace"
//  immersive space. It lets the player rehearse and calibrate the HoloPad
//  virtual controller WITHOUT a PS5 session.
//
//  v13.1: FULL immersion (the player sees only the app) with two view modes:
//    - .thirdPerson → a runner where the character runs / jumps / collects
//      coins and the right stick orbits the camera,
//    - .firstPerson → a shooting range aimed with the right stick, R2 to fire.
//
//  The trick: with no active Chiaki session, ChiakiFullSession.setControllerState
//  drops every update at its `guard isActive`. So this view never touches
//  Chiaki — a local 90Hz timer reads the gesture service's output values
//  (buttonsBitmask / sticks / triggers) directly and drives whichever
//  mini-game is active, plus the HUD and the hand-anchored HoloPad feedback.
//

import SwiftUI
import RealityKit
import QuartzCore

struct ControllerTestRangeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @StateObject private var gestureService = HandGestureControllerService()
    @StateObject private var thirdPerson = ThirdPersonGameCoordinator()
    @StateObject private var firstPerson = FirstPersonShooterCoordinator()

    @State private var viewMode: TestRangeViewMode = .thirdPerson
    @State private var inputTimer: Timer?
    @State private var liveSample = TrainingInputSample()
    @State private var liveScore = 0
    @State private var liveShots = 0
    @State private var hudTick = 0
    @State private var diagTick = 0
    @State private var liveDebug = HandGestureControllerService.Debug()
    @State private var lastTick: CFTimeInterval = 0

    var body: some View {
        ZStack {
            RealityView { content, attachments in
                content.add(thirdPerson.root)
                content.add(firstPerson.root)

                // The FPS gun is head-locked so it stays in first-person view.
                let head = AnchorEntity(.head)
                head.addChild(firstPerson.gunRoot)
                content.add(head)

                if let panel = attachments.entity(for: "panel") {
                    let anchor = AnchorEntity(world: [0, 1.15, -1.6])
                    panel.position = .zero
                    anchor.addChild(panel)
                    content.add(anchor)
                }
                applyMode()
            } attachments: {
                Attachment(id: "panel") {
                    ControllerTutorialPanel(
                        mode: viewMode,
                        sample: liveSample,
                        score: liveScore,
                        shots: liveShots,
                        isTracking: gestureService.isTracking,
                        cyborg: gestureService.inputProfile == .cyborgPaddles,
                        debug: liveDebug,
                        onSelectMode: { selectMode($0) },
                        onToggleProfile: { toggleProfile() },
                        onRecalibrate: { gestureService.recalibrate() },
                        onReset: { resetActiveGame() },
                        onExit: { Task { await exitRange() } }
                    )
                }
            }

            // Same hand-anchored feedback used while streaming (per-joint orbs
            // + arcane ring) — reused so the practice hands look identical.
            if #available(visionOS 2.0, *) {
                HoloPadFeedbackView(service: gestureService)
            }
        }
        .onChange(of: viewMode) { applyMode() }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: - Scene mode

    private func applyMode() {
        thirdPerson.root.isEnabled = viewMode == .thirdPerson
        firstPerson.root.isEnabled = viewMode == .firstPerson
        firstPerson.gunRoot.isEnabled = viewMode == .firstPerson
    }

    private func selectMode(_ mode: TestRangeViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
    }

    // MARK: - Lifecycle

    private func start() {
        appState.isTrainingRangeActive = true
        lastTick = CACurrentMediaTime()
        DebugLog.info("TestRange", "🎯 Controller Test Range starting (mode: \(viewMode.rawValue))")
        Task {
            do {
                try await gestureService.startTracking()
            } catch {
                DebugLog.error("TestRange", "Hand tracking failed: \(error)")
            }
        }
        inputTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 90.0, repeats: true) { _ in
            // Main-runloop timer fires on the main thread (5.20 pattern).
            MainActor.assumeIsolated { tick() }
        }
    }

    /// One game step: read the controller locally (never Chiaki) and drive the
    /// active mini-game, then throttle the SwiftUI HUD to ~15Hz.
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTick, 0), 0.05))
        lastTick = now

        let tracking = gestureService.isTracking
        let sample = tracking ? TrainingInputSample(
            buttons: gestureService.buttonsBitmask,
            leftStick: gestureService.leftStick,
            rightStick: gestureService.rightStick,
            leftTrigger: gestureService.leftTrigger,
            rightTrigger: gestureService.rightTrigger
        ) : TrainingInputSample()

        switch viewMode {
        case .thirdPerson:
            thirdPerson.update(move: sample.leftStick,
                               jump: sample.isPressed(PSButtonMask.cross),
                               cameraX: sample.rightStick.x,
                               buttons: sample.buttons, dt: dt)
        case .firstPerson:
            firstPerson.update(aim: sample.rightStick,
                               fire: sample.rightTrigger > 0.5,
                               aimDown: sample.leftTrigger,
                               move: sample.leftStick,
                               buttons: sample.buttons, dt: dt)
        }

        hudTick &+= 1
        if hudTick % 6 == 0 {
            liveSample = sample
            liveScore = viewMode == .firstPerson ? firstPerson.score : thirdPerson.score
            liveShots = firstPerson.shots
            liveDebug = gestureService.debug
        }

        // v13.5 real-time tuning diagnostic (~3Hz): the input→output chain,
        // input side (sticks/triggers) paired with the bot/camera response, so
        // the hand↔bot relationship is legible in the console while tuning.
        diagTick &+= 1
        if diagTick % 30 == 0 {
            let response = viewMode == .thirdPerson ? thirdPerson.debugSummary : firstPerson.debugSummary
            DebugLog.print("[TestRange] 🤖 L=(\(fmt(sample.leftStick.x)),\(fmt(sample.leftStick.y))) R=(\(fmt(sample.rightStick.x)),\(fmt(sample.rightStick.y))) L2=\(fmt(sample.leftTrigger)) R2=\(fmt(sample.rightTrigger)) → \(response)")
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%+.2f", v) }

    private func stop() {
        inputTimer?.invalidate()
        inputTimer = nil
        gestureService.stopTracking()
        if #available(visionOS 2.0, *) {
            HoloPadFeedbackCoordinator.shared.reset()
        }
        appState.isTrainingRangeActive = false
        DebugLog.info("TestRange", "Controller Test Range stopped")
    }

    // MARK: - Actions

    private func resetActiveGame() {
        switch viewMode {
        case .thirdPerson: thirdPerson.reset()
        case .firstPerson: firstPerson.reset()
        }
    }

    private func toggleProfile() {
        gestureService.inputProfile =
            gestureService.inputProfile == .cyborgPaddles ? .thumbTaps : .cyborgPaddles
    }

    private func exitRange() async {
        await dismissImmersiveSpace()
    }
}
