//
//  HandGestureControllerService.swift
//  VisionRemotePS5
//
//  v12.2 "HoloPad": full gesture-based virtual DualSense using ARKit hand
//  tracking (90Hz on visionOS 2). Every input is self-haptic — the player
//  always feels skin contact — solving the "can't feel virtual buttons"
//  problem of panel-based overlays:
//
//  RIGHT hand                            LEFT hand
//    thumb → middle fingertip = ✕          thumb → middle fingertip = D-Up
//    thumb → ring fingertip   = ○          thumb → ring fingertip   = D-Down
//    thumb → pinky fingertip  = □          thumb → pinky fingertip  = D-Left
//    thumb → index side       = △          thumb → index side       = D-Right
//    thumb+index pinch-drag   = R stick    thumb+index pinch-drag   = L stick
//    index curl (no contact)  = R2         index curl (no contact)  = L2
//
//  Detection uses hysteresis (press < 2.2cm, release > 3.2cm) and an
//  extension gate so a closed fist does not fire false taps.
//

import Foundation
import ARKit
import simd
import QuartzCore  // CACurrentMediaTime monotonic clock (stillness recenter)

/// Chiaki controller button bitmask (mirrors ChiakiControllerButton).
enum PSButtonMask {
    static let cross: UInt32 = 0x0001
    static let circle: UInt32 = 0x0002
    static let square: UInt32 = 0x0004
    static let triangle: UInt32 = 0x0008
    static let dpadLeft: UInt32 = 0x0010
    static let dpadRight: UInt32 = 0x0020
    static let dpadUp: UInt32 = 0x0040
    static let dpadDown: UInt32 = 0x0080
    static let l1: UInt32 = 0x0100
    static let r1: UInt32 = 0x0200
    static let l3: UInt32 = 0x0400
    static let r3: UInt32 = 0x0800
    static let options: UInt32 = 0x1000
    static let share: UInt32 = 0x2000
    static let touchpad: UInt32 = 0x4000
    static let ps: UInt32 = 0x8000
}

/// Per-frame snapshot consumed by the holographic feedback layer.
///
/// COORDINATE SPACE: every position here is LOCAL TO THE HAND ANCHOR
/// (wrist frame), NOT world space. The feedback layer parents each hand's
/// entities under an `AnchorEntity(.hand(...))`, so the system composites
/// them glued to the hand with prediction — immune to the ARKit-vs-RealityKit
/// scene-origin offset that made world-space placement drift off the hands.
/// (Gesture DETECTION still runs in world space inside the service; relative
/// distances are rigid-invariant, but stick drag needs world motion.)
struct HoloPadHandSnapshot {
    enum Point: CaseIterable {
        case thumbTip, indexTip, indexSide, middleTip, ringTip, pinkyTip
    }
    let isRight: Bool
    var points: [Point: SIMD3<Float>] = [:]
    var activePoints: Set<Point> = []
    var stickOrigin: SIMD3<Float>?
    var stickCurrent: SIMD3<Float>?
    var stickValue: SIMD2<Float> = .zero
    var triggerValue: Float = 0
    /// Palm anchor for the ring HUD (center of palm + outward normal),
    /// in hand-anchor-local coordinates.
    var palmCenter: SIMD3<Float> = .zero
    var palmNormal: SIMD3<Float> = [0, 1, 0]
    /// Summon mode: palm rotated toward the sky (system-button layer).
    var isPalmUp: Bool = false
}

/// HoloPad input profile.
enum HoloPadInputProfile: String, CaseIterable {
    /// v12.2: every button is a thumb-to-finger contact (occlusion-proof).
    case thumbTaps = "Thumb Taps"
    /// v12.4 "Cyborg": each finger is an independent paddle pressed DOWN
    /// against the resting surface (thigh/armrest) — real passive haptics,
    /// chord-capable, thumb reserved for the stick. Inspired by the
    /// Cyborg II keypad: the hand never travels; keys live under the fingers.
    ///   index  = analog trigger by press depth; LIFT of the index = bumper
    ///   middle/ring/pinky presses = ✕/○/□ (right) or D-Up/Down/Left (left)
    ///   thumb→index-side tap = △ / D-Right (unchanged)
    case cyborgPaddles = "Cyborg Paddles"
}

/// Gesture-based virtual controller ("HoloPad") — tracks 27 joints per hand
/// and converts self-contact gestures into a full DualSense state.
@MainActor
final class HandGestureControllerService: ObservableObject {

    /// Active input profile (switchable from the floating control panel).
    /// v12.7: Cyborg is the default — user direction: thumb is the stick,
    /// no pinching (pinch interrupts continuous movement).
    /// v12.9.1: switching profiles resets ALL per-hand state — review found
    /// a stale wrist reference surviving cyborg→taps→cyborg (phantom spin).
    @Published var inputProfile: HoloPadInputProfile = .cyborgPaddles {
        didSet {
            guard inputProfile != oldValue else { return }
            leftHand = HandState()
            rightHand = HandState()
            buttonsBitmask = 0
            leftStick = .zero
            rightStick = .zero
            leftTrigger = 0
            rightTrigger = 0
        }
    }

    // MARK: - Output state (read by the 120Hz input timer — not published,
    // SwiftUI must not churn at 90Hz)

    private(set) var buttonsBitmask: UInt32 = 0
    private(set) var leftStick: SIMD2<Float> = .zero
    private(set) var rightStick: SIMD2<Float> = .zero
    private(set) var leftTrigger: Float = 0
    private(set) var rightTrigger: Float = 0

    /// Both hands currently tracked (published — drives HUD state only).
    @Published private(set) var isTracking: Bool = false

    /// 90Hz feedback stream for the holographic layer (non-SwiftUI path).
    var onHandsUpdated: ((HoloPadHandSnapshot) -> Void)?

    // MARK: - Tuning constants (meters)

    private let tapPressDistance: Float = 0.022
    private let tapReleaseDistance: Float = 0.032
    private let stickRadius: Float = 0.06          // full deflection at 6cm drag
    private let fingerExtendedGate: Float = 0.10   // tip-to-wrist: taps only when finger not fisted
    private let curlExtendedDistance: Float = 0.085 // index tip-to-knuckle when straight
    private let curlFullDistance: Float = 0.040     // when fully curled

    // MARK: - Tracking

    private var arkitSession: ARKitSession?
    private var handTrackingProvider: HandTrackingProvider?
    private var trackingTask: Task<Void, Never>?

    private struct HandState {
        var stickOrigin: SIMD3<Float>? = nil
        var tapActive: [HoloPadHandSnapshot.Point: Bool] = [:]
        var tracked = false
        /// Summon mode (palm facing the sky) — taps become system buttons.
        var palmUp = false
        /// v12.7.2 gameplay posture: palm facing DOWN (hand resting) — the
        /// Cyborg paddles/stick only operate here. Raised/vertical hands are
        /// NEUTRAL: no phantom input while gesticulating (live telemetry
        /// showed ring+pinky stuck pressed after baselines were captured
        /// with raised, extended hands).
        var restingPose = false
        /// Bumper (L1/R1): middle-finger curl "grip", with hysteresis.
        var bumperActive = false
        /// Stick click (L3/R3): middle finger joins the pinch while dragging.
        var stickClickActive = false
        /// Cyborg profile: adaptive rest-pose curl baseline per finger
        /// (keyed by the fingertip point) and current paddle press states.
        var fingerRest: [HoloPadHandSnapshot.Point: Float] = [:]
        var paddlePressed: Set<HoloPadHandSnapshot.Point> = []
        /// Cyborg profile: index finger lifted off the surface = bumper.
        var indexLifted = false
        /// Cyborg profile: middle finger lifted = △ / D-Right (v12.7).
        var middleLifted = false
        /// Cyborg v12.7 thumb stick: adaptive center in hand-local space.
        var thumbRest: SIMD3<Float>? = nil
        /// Stillness tracking for the recenter deadlock fix (v12.7.1).
        var lastThumbLocal: SIMD3<Float>? = nil
        var lastThumbTime: CFTimeInterval = 0
        var stillSince: CFTimeInterval? = nil
        /// v12.9.1: shallow-latch escape — a "pressed" paddle whose delta sits
        /// below the ENTER threshold for a sustained time is a latch, not a
        /// hold (real holds stay deep); tracked per paddle point.
        var pressedShallowSince: [HoloPadHandSnapshot.Point: CFTimeInterval] = [:]
        /// v12.9.1: wrist height at settle — raising the hand >20cm exits
        /// gameplay (reaching for an object no longer ghosts input).
        var settledWristY: Float? = nil
        /// v12.9.1: summon entry debounce (mirror of the resting debounce).
        var palmUpCandidateSince: CFTimeInterval? = nil
        /// v12.8 wrist stick: reference orientation (yaw/pitch of the hand's
        /// forward axis) captured when the hand settles.
        var wristRefYaw: Float? = nil
        var wristRefPitch: Float? = nil
        /// v12.8.1 settling machinery — closes the whole reference-deadlock
        /// class (thumb center, curl baselines, wrist reference):
        /// entry debounce, settling window, and saturation escape.
        var restingCandidateSince: CFTimeInterval? = nil
        var settleUntil: CFTimeInterval = 0
        var stickSaturatedSince: CFTimeInterval? = nil
    }

    /// v12.8.1 settling parameters.
    private let restingEntryDebounce: CFTimeInterval = 0.3
    private let settleWindow: CFTimeInterval = 0.8
    private let settleAdaptRate: Float = 0.3
    private let saturationEscapeAfter: CFTimeInterval = 1.5
    private let saturationEscapeRate: Float = 0.15

    /// v12.8.2 "essential core" stabilization: lifts (R1/L1, △/D-Right) and
    /// the side-tap stick click were the flap-prone gestures in telemetry.
    /// Disabled until the core (wrist sticks + index triggers + finger
    /// presses) proves stable on device; re-enable ONE AT A TIME.
    private let liftsEnabled = false
    private let sideTapEnabled = false

    /// v12.8 wrist-tilt stick (user direction: "ajudar a câmera com o
    /// movimento do punho"): tilt the resting hand like a flight stick.
    /// Orientation tracking has no position-baseline deadlocks — the wrist
    /// returns to its natural pose and the stick self-centers.
    private let wristDeadzone: Float = 0.10   // rad (~6°)
    private let wristFullTilt: Float = 0.35   // rad (~20°) = full deflection
    private let wristRefAdaptRate: Float = 0.03

    /// v12.7 thumb positional stick (Cyborg profile): the thumb IS the
    /// analog stick — deflection from an adaptive center, no pinch gesture.
    private let thumbStickRadius: Float = 0.04      // full deflection at 4cm
    private let thumbStickDeadzone: Float = 0.012   // 12mm neutral zone
    private let thumbRestAdaptRate: Float = 0.05    // recenter inside deadzone
    /// v12.7.1 stillness recenter — fixes the stuck-deflection deadlock
    /// (center could never recover if the thumb settled outside the
    /// deadzone, leaving the camera spinning forever): a thumb that stays
    /// nearly still for a moment BECOMES the new center, wherever it is.
    private let stillnessSpeed: Float = 0.015       // m/s — "not moving"
    private let stillnessDuration: CFTimeInterval = 0.6
    private let stillnessAdaptRate: Float = 0.25
    /// Hand-local axis mapping (tune signs on device via the ember).
    private let thumbAxisLateral: Int = 2   // local z = left/right
    private let thumbAxisForward: Int = 0   // local x = forward/back (wrist→fingers)

    /// Bumper (middle-finger curl) hysteresis on normalized curl.
    private let bumperEnterCurl: Float = 0.65
    private let bumperExitCurl: Float = 0.45

    /// Cyborg paddle deltas — relative to the adaptive rest baseline, in
    /// normalized-curl units, so finger length and posture cancel out.
    private let paddleEnterDelta: Float = 0.16
    private let paddleExitDelta: Float = 0.08
    // v12.7.1: lifts demand a more deliberate extension — with hands held in
    // the air the old -0.14 threshold fired phantom △/D-Right constantly.
    private let liftEnterDelta: Float = -0.22
    private let liftExitDelta: Float = -0.12
    /// Index press depth at which the analog trigger reaches 1.0.
    private let triggerFullDelta: Float = 0.45
    /// Rest-baseline EMA rate while the finger is idle (~2s at 90Hz).
    private let restAdaptRate: Float = 0.02

    /// Palm-up hysteresis on dot(palmNormal, worldUp).
    private let palmUpEnter: Float = 0.55
    private let palmUpExit: Float = 0.35
    private var leftHand = HandState()
    private var rightHand = HandState()
    private var stickLogCounter: UInt64 = 0

    // MARK: - Lifecycle

    func startTracking() async throws {
        guard handTrackingProvider == nil else { return }

        let provider = HandTrackingProvider()
        handTrackingProvider = provider
        let session = ARKitSession()
        arkitSession = session

        try await session.run([provider])
        DebugLog.info("HoloPad", "✅ Hand tracking started")

        trackingTask = Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard let self else { break }
                self.processHandUpdate(update.anchor)
            }
            DebugLog.warning("HoloPad", "Anchor updates loop ended")
        }
    }

    func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        arkitSession?.stop()
        arkitSession = nil
        handTrackingProvider = nil

        leftHand = HandState()
        rightHand = HandState()
        buttonsBitmask = 0
        leftStick = .zero
        rightStick = .zero
        leftTrigger = 0
        rightTrigger = 0
        isTracking = false
        DebugLog.info("HoloPad", "Hand tracking stopped")
    }

    // MARK: - Gesture engine

    private func processHandUpdate(_ anchor: HandAnchor) {
        let isRight = anchor.chirality == .right

        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            if isRight { rightHand = HandState(); rightStick = .zero; rightTrigger = 0 }
            else { leftHand = HandState(); leftStick = .zero; leftTrigger = 0 }
            refreshCompositeState()
            return
        }

        let origin = anchor.originFromAnchorTransform
        func world(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let transform = origin * joint.anchorFromJointTransform
            return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }
        /// Occlusion-tolerant read: in the lap pose (Cyborg paddles) the
        /// fingertips hide under the hand; ARKit still infers their pose.
        func worldAny(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let transform = origin * skeleton.joint(name).anchorFromJointTransform
            return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }
        /// Hand-anchor-LOCAL position (wrist frame) — feedback layer space.
        func localPos(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let transform = skeleton.joint(name).anchorFromJointTransform
            return SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        guard let thumbTip = world(.thumbTip),
              let indexTip = world(.indexFingerTip),
              let indexSide = world(.indexFingerIntermediateBase),
              let indexKnuckle = world(.indexFingerKnuckle),
              let middleKnuckle = world(.middleFingerKnuckle),
              let littleKnuckle = world(.littleFingerKnuckle),
              let wrist = world(.wrist) else {
            // v12.9.1: a per-joint dropout must NEUTRALIZE this hand, not
            // freeze it — review found a held R2 kept firing (and a pan kept
            // panning) for the whole dropout because the early return left
            // the last committed outputs in place. Baselines are kept (the
            // dropout is transient); pressed/held states are released.
            if isRight {
                rightHand.paddlePressed.removeAll()
                rightHand.tapActive.removeAll()
                rightHand.indexLifted = false
                rightHand.middleLifted = false
                rightStick = .zero
                rightTrigger = 0
            } else {
                leftHand.paddlePressed.removeAll()
                leftHand.tapActive.removeAll()
                leftHand.indexLifted = false
                leftHand.middleLifted = false
                leftStick = .zero
                leftTrigger = 0
            }
            refreshCompositeState()
            return
        }
        let middleTip = worldAny(.middleFingerTip)
        let ringTip = worldAny(.ringFingerTip)
        let pinkyTip = worldAny(.littleFingerTip)
        let ringKnuckle = worldAny(.ringFingerKnuckle)

        var state = isRight ? rightHand : leftHand
        state.tracked = true
        var snapshot = HoloPadHandSnapshot(isRight: isRight)
        // Feedback positions are HAND-ANCHOR-LOCAL (see snapshot docs): the
        // feedback layer parents them under AnchorEntity(.hand), so they stay
        // glued to the hand regardless of any ARKit/RealityKit origin offset.
        snapshot.points = [
            .thumbTip: localPos(.thumbTip),
            .indexTip: localPos(.indexFingerTip),
            .indexSide: localPos(.indexFingerIntermediateBase),
            .middleTip: localPos(.middleFingerTip),
            .ringTip: localPos(.ringFingerTip),
            .pinkyTip: localPos(.littleFingerTip)
        ]

        // --- Palm pose (ring HUD anchor + summon detection) ---------------
        // Right hand: cross(wrist→index, wrist→little) points out of the palm;
        // mirrored anatomy flips it for the left hand.
        // World normal drives the summon (needs gravity); the local pair
        // drives the ring HUD placement.
        var palmNormal = simd_normalize(simd_cross(indexKnuckle - wrist, littleKnuckle - wrist))
        if !isRight { palmNormal = -palmNormal }
        let localWrist = localPos(.wrist)
        var localPalmNormal = simd_normalize(simd_cross(
            localPos(.indexFingerKnuckle) - localWrist,
            localPos(.littleFingerKnuckle) - localWrist
        ))
        if !isRight { localPalmNormal = -localPalmNormal }
        snapshot.palmCenter = (localWrist + localPos(.middleFingerKnuckle)) * 0.5
        snapshot.palmNormal = localPalmNormal

        let upness = simd_dot(palmNormal, SIMD3<Float>(0, 1, 0))
        let wasPalmUp = state.palmUp
        let palmNow = CACurrentMediaTime()
        if state.palmUp {
            state.palmUp = upness > palmUpExit
        } else if upness > palmUpEnter {
            // v12.9.1: 0.25s sustained debounce — a transient palm-up while
            // lowering an object was instantly arming Options/Share/PS.
            if state.palmUpCandidateSince == nil { state.palmUpCandidateSince = palmNow }
            if palmNow - (state.palmUpCandidateSince ?? palmNow) > 0.25 {
                state.palmUp = true
            }
        } else {
            state.palmUpCandidateSince = nil
        }
        if state.palmUp != wasPalmUp {
            // v12.9.1: layer flip invalidates held contacts — review found a
            // held summon Touchpad tap remapping to a held R3 on the way
            // down (and □ becoming PS on the way up). Fresh contact required.
            state.tapActive.removeAll()
            state.palmUpCandidateSince = nil
        }
        snapshot.isPalmUp = state.palmUp

        // v12.7.2: gameplay posture = palm down (resting hand).
        // v12.8.1: wide hysteresis (0.5 enter / 0.15 exit) + 0.3s sustained
        // entry debounce — telemetry showed a hovering hand flapping across
        // the old boundary and recapturing jumpy references each time.
        let downness = -upness
        let wasResting = state.restingPose
        let postureNow = CACurrentMediaTime()
        if state.restingPose {
            // v12.9: exit ONLY past vertical — tilting the hand up for
            // camera-up was crossing the old 0.15 exit and ejecting the hand
            // from gameplay mid-gesture (telemetry: repeated re-settling).
            // v12.9.1: ALSO exit when the hand RISES >20cm above its settled
            // height — reaching for an object in view was ghosting stick and
            // paddle input all the way (palm stays below vertical on a reach).
            let raised = state.settledWristY.map { wrist.y > $0 + 0.20 } ?? false
            state.restingPose = downness > 0.0 && !raised
        } else if downness > 0.5 {
            if state.restingCandidateSince == nil {
                state.restingCandidateSince = postureNow
            }
            if postureNow - (state.restingCandidateSince ?? postureNow) > restingEntryDebounce {
                state.restingPose = true
            }
        } else {
            state.restingCandidateSince = nil
        }
        if state.restingPose && !wasResting {
            // The hand just settled: open the SETTLING WINDOW — all input
            // stays neutral while every baseline converges to the true
            // settled pose (capturing at the threshold-crossing instant was
            // the pinned-stick bug: the hand was still mid-motion).
            state.settleUntil = postureNow + settleWindow
            state.fingerRest.removeAll()
            state.thumbRest = nil
            state.wristRefYaw = nil
            state.wristRefPitch = nil
            state.paddlePressed.removeAll()
            state.pressedShallowSince.removeAll()
            state.indexLifted = false
            state.middleLifted = false
            state.restingCandidateSince = nil
            state.settledWristY = wrist.y
            DebugLog.print("[HoloPad] 🫳 \(isRight ? "R" : "L") resting — settling \(settleWindow)s")
        }
        let settling = state.restingPose && postureNow < state.settleUntil

        // --- Analog stick (profile-dependent) ------------------------------
        var stick = SIMD2<Float>.zero
        var stickEngaged = false

        if inputProfile == .cyborgPaddles, !state.restingPose {
            // Outside the resting pose the stick is neutral and references
            // are discarded (recaptured when the hand settles again).
            state.wristRefYaw = nil
            state.wristRefPitch = nil
        } else if inputProfile == .cyborgPaddles {
            // v12.8: WRIST-TILT stick. v12.9: the forward axis comes from
            // the RIGID hand-anchor transform (its x-axis points wrist →
            // fingers), NOT from knuckle positions — telemetry showed
            // middle-finger presses rocking the middleKnuckle and bursting
            // the stick (button input leaking into the camera: the
            // "commands feel swapped" symptom).
            // v12.9.2: angles are measured RELATIVE TO THE FOREARM, not the
            // world — telemetry showed right-hand yaw pinned at +1.00 when
            // the whole relaxed arm rolled on the thigh (indistinguishable
            // from a deliberate hold in world space). Forearm and hand move
            // together on arm drift → relative angle unchanged → no phantom;
            // a true wrist flick (radial deviation / flexion) is the input,
            // and the wrist's own anatomy is the return spring.
            let anchorX = origin.columns.0
            let forward = simd_normalize(SIMD3<Float>(anchorX.x, anchorX.y, anchorX.z))
            let forearmPos = worldAny(.forearmArm)
            let forearmDir = simd_normalize(wrist - forearmPos)   // elbow → wrist
            var lateral = simd_cross(forearmDir, SIMD3<Float>(0, 1, 0))
            let lateralLength = simd_length(lateral)
            // Degenerate only when the forearm points straight up/down —
            // not a gameplay pose; hold the stick neutral there.
            let frameValid = lateralLength > 0.05
            lateral = frameValid ? lateral / lateralLength : SIMD3<Float>(1, 0, 0)
            let upInFrame = simd_cross(lateral, forearmDir)
            let yawNow = atan2(simd_dot(forward, lateral), simd_dot(forward, forearmDir))
            let pitchNow = asin(max(-1, min(1, simd_dot(forward, upInFrame))))

            var refYaw = state.wristRefYaw ?? yawNow
            var refPitch = state.wristRefPitch ?? pitchNow

            func shortestAngle(_ a: Float) -> Float {
                var angle = a
                while angle > .pi { angle -= 2 * .pi }
                while angle < -.pi { angle += 2 * .pi }
                return angle
            }

            // Settling window: fast-converge the reference to wherever the
            // hand is actually coming to rest; stick stays neutral.
            if settling {
                refYaw += shortestAngle(yawNow - refYaw) * settleAdaptRate
                refPitch += (pitchNow - refPitch) * settleAdaptRate
            }

            let deltaYaw = shortestAngle(yawNow - refYaw)
            let deltaPitch = pitchNow - refPitch

            func axisValue(_ delta: Float) -> Float {
                let magnitude = abs(delta)
                guard magnitude > wristDeadzone else { return 0 }
                let usable = (magnitude - wristDeadzone) / (wristFullTilt - wristDeadzone)
                return min(usable, 1) * (delta > 0 ? 1 : -1)
            }

            // Thumb touching the index side = stick click (R3/L3): freeze
            // the stick during the click so it can't jerk the camera.
            // v12.9.1: ONLY while the side tap is enabled — review found the
            // freeze silently killing the stick for hands that rest the
            // thumb against the index (a natural relaxed pose).
            let sideContact = sideTapEnabled &&
                simd_length(thumbTip - indexSide) < tapReleaseDistance

            // (v12.9.2: the old cos(pitch) conditioning was a world-frame
            // artifact; forearm-relative angles are well-conditioned in any
            // resting pose.)
            if !sideContact && !state.palmUp && !settling && frameValid {
                stick = SIMD2<Float>(
                    axisValue(deltaYaw),          // flick right = camera right
                    -axisValue(deltaPitch)        // flick up = stick up (PS -Y)
                )
                stickEngaged = simd_length(stick) > 0.01
                if stickEngaged {
                    snapshot.stickOrigin = localPos(.thumbTip)
                    snapshot.stickCurrent = localPos(.thumbTip)
                }
            }

            // Reference adapts ONLY inside the deadzone. v12.9.1: the v12.9
            // "mid-range bleed" and the saturation escape are GONE — the
            // adversarial review proved both destroy legitimate gameplay
            // (every sustained pan/walk decayed mid-hold and rubber-banded
            // in reverse on release; full-tilt holds glitched at 1.5s).
            // With the rigid anchor axis + settling window + entry debounce
            // the bad-reference sources are fixed at the root; the manual
            // escape for a rare bad capture is simply lifting the hand or
            // flipping the palm and resting again (fresh 0.8s settle).
            if abs(deltaYaw) < wristDeadzone && abs(deltaPitch) < wristDeadzone {
                refYaw += deltaYaw * wristRefAdaptRate
                refPitch += deltaPitch * wristRefAdaptRate
            }

            state.wristRefYaw = refYaw
            state.wristRefPitch = refPitch
        } else {
            // Thumb-taps profile keeps the original pinch-drag stick.
            let pinchDistance = simd_length(thumbTip - indexTip)
            let pinchPoint = (thumbTip + indexTip) * 0.5
            if state.palmUp {
                state.stickOrigin = nil
            } else if state.stickOrigin == nil, pinchDistance < tapPressDistance {
                state.stickOrigin = pinchPoint
            } else if state.stickOrigin != nil, pinchDistance > tapReleaseDistance {
                state.stickOrigin = nil
            }

            if let stickOrigin = state.stickOrigin {
                let drag = pinchPoint - stickOrigin
                // ARKit +Y is up; PS convention: up = negative Y.
                stick = SIMD2<Float>(
                    max(-1, min(1, drag.x / stickRadius)),
                    max(-1, min(1, -drag.y / stickRadius))
                )
                // Feedback position in hand-anchor-local space.
                let localPinch = (localPos(.thumbTip) + localPos(.indexFingerTip)) * 0.5
                snapshot.stickOrigin = localPinch
                snapshot.stickCurrent = localPinch
            }
            stickEngaged = state.stickOrigin != nil
        }
        snapshot.stickValue = stick

        // --- Trigger / paddles (profile-dependent) -------------------------
        var trigger: Float = 0
        if inputProfile == .cyborgPaddles {
            // v12.4 Cyborg: each finger is an independent paddle. Press =
            // curl above an ADAPTIVE rest baseline (EMA while idle), so
            // finger length, hand size and posture cancel out. Pressing
            // down onto the resting surface (thigh) is the passive haptic.
            let paddleDefs: [(HoloPadHandSnapshot.Point, SIMD3<Float>, SIMD3<Float>)] = [
                (.indexTip, indexTip, indexKnuckle),
                (.middleTip, middleTip, middleKnuckle),
                (.ringTip, ringTip, ringKnuckle),
                (.pinkyTip, pinkyTip, littleKnuckle)
            ]
            for (point, tip, knuckle) in paddleDefs {
                let separation = simd_length(tip - knuckle)
                // v12.9.1: clamp — outer fingertips are INFERRED in the lap
                // pose (worldAny) and inference garbage was poisoning the
                // baselines with out-of-range curls.
                let curl = max(-0.5, min(1.5,
                    (curlExtendedDistance - separation) /
                    (curlExtendedDistance - curlFullDistance)))
                var rest = state.fingerRest[point] ?? curl
                let delta = curl - rest

                // v12.7.2: paddles operate ONLY in the resting pose (palm
                // down); summon and the settling window also suppress them.
                let suppressed = state.palmUp || !state.restingPose || settling
                if settling {
                    // Converge the curl baseline to the true settled pose
                    // (persisted by the trailing fingerRest assignment).
                    rest += (curl - rest) * settleAdaptRate
                }
                var pressed = state.paddlePressed.contains(point)
                if suppressed {
                    pressed = false
                } else if pressed {
                    pressed = delta > paddleExitDelta
                } else {
                    pressed = delta > paddleEnterDelta
                }
                // v12.9.1 shallow-latch escape: a real hold keeps the finger
                // DEEP (delta ≥ enter); a "pressed" state whose delta sits in
                // the shallow band for 1.5s is a stuck latch from posture
                // drift — release it and re-baseline to the current curl.
                if pressed, delta < paddleEnterDelta {
                    if state.pressedShallowSince[point] == nil {
                        state.pressedShallowSince[point] = postureNow
                    }
                    if postureNow - (state.pressedShallowSince[point] ?? postureNow) > 1.5 {
                        pressed = false
                        rest = curl
                        state.pressedShallowSince[point] = nil
                    }
                } else {
                    state.pressedShallowSince[point] = nil
                }

                if pressed { state.paddlePressed.insert(point) } else { state.paddlePressed.remove(point) }

                if point == .indexTip {
                    // Analog trigger: press depth beyond the button threshold.
                    if pressed {
                        trigger = max(0, min(1, (delta - paddleEnterDelta) /
                                                (triggerFullDelta - paddleEnterDelta)))
                    }
                    // Lift off the surface = bumper (the keypad's up-lever).
                    if suppressed || !liftsEnabled {
                        state.indexLifted = false
                    } else if state.indexLifted {
                        state.indexLifted = delta < liftExitDelta
                    } else {
                        state.indexLifted = delta < liftEnterDelta
                    }
                }
                if point == .middleTip {
                    // v12.7: middle-finger lift = △ / D-Right (relocated from
                    // the thumb, which is now the stick).
                    if suppressed || !liftsEnabled {
                        state.middleLifted = false
                    } else if state.middleLifted {
                        state.middleLifted = delta < liftExitDelta
                    } else {
                        state.middleLifted = delta < liftEnterDelta
                    }
                }

                // Adapt the baseline ONLY while idle — an active press or
                // lift must never be absorbed into "rest".
                let lifting = (point == .indexTip && state.indexLifted) ||
                              (point == .middleTip && state.middleLifted)
                if !pressed && !lifting && !suppressed {
                    rest += (curl - rest) * restAdaptRate
                }
                state.fingerRest[point] = rest

                if pressed { snapshot.activePoints.insert(point) }
            }
        } else {
            // Thumb-taps profile: index curl is the trigger (suppressed
            // while pinched or in summon).
            if !stickEngaged && !state.palmUp {
                let indexExtension = simd_length(indexTip - indexKnuckle)
                trigger = max(0, min(1, (curlExtendedDistance - indexExtension) /
                                         (curlExtendedDistance - curlFullDistance)))
            }
            // Clear any paddle residue from a profile switch.
            state.paddlePressed.removeAll()
            state.indexLifted = false
            state.fingerRest.removeAll()
        }
        snapshot.triggerValue = trigger

        // --- Face/D-pad taps: thumb to fingertip / index side ------------
        // Extension gate: a fisted finger's tip sits near the thumb anyway;
        // only extended fingers are tappable, killing fist false-positives.
        func updateTap(_ point: HoloPadHandSnapshot.Point, target: SIMD3<Float>, gated: Bool) {
            let distance = simd_length(thumbTip - target)
            let wasActive = state.tapActive[point] ?? false
            if wasActive {
                state.tapActive[point] = distance < tapReleaseDistance
            } else {
                state.tapActive[point] = gated && distance < tapPressDistance
            }
            if state.tapActive[point] == true { snapshot.activePoints.insert(point) }
        }

        // --- Bumpers (L1/R1): middle-finger curl grip (taps profile only;
        // Cyborg uses the index LIFT for bumpers) ------------------------
        if inputProfile == .cyborgPaddles {
            state.bumperActive = false
        } else {
            let middleCurl = max(0, min(1, (curlExtendedDistance - simd_length(middleTip - middleKnuckle)) /
                                            (curlExtendedDistance - curlFullDistance)))
            if state.palmUp || state.tapActive[.middleTip] == true {
                state.bumperActive = false
            } else if state.bumperActive {
                state.bumperActive = middleCurl > bumperExitCurl
            } else {
                state.bumperActive = middleCurl > bumperEnterCurl
            }
        }

        // --- Stick click (L3/R3) ------------------------------------------
        // Thumb-taps profile: middle finger joins the pinch while dragging.
        // Cyborg profile: thumb tap on the index side (handled in the
        // composite mask via tapActive[.indexSide]).
        if inputProfile == .thumbTaps, stickEngaged {
            let middleToThumb = simd_length(middleTip - thumbTip)
            if state.stickClickActive {
                state.stickClickActive = middleToThumb < tapReleaseDistance
            } else {
                state.stickClickActive = middleToThumb < tapPressDistance
            }
        } else {
            state.stickClickActive = false
        }

        // Fingertip thumb-taps drive gameplay in the taps profile; in the
        // Cyborg profile they are ONLY the summon (palm-up) system layer —
        // gameplay buttons come from the paddles instead.
        let fingertipTapsEnabled = inputProfile == .thumbTaps || state.palmUp

        // middleTip tap suppressed while the stick is engaged — a middle
        // finger joining the pinch there means L3/R3, not ✕/D-Up.
        updateTap(.middleTip, target: middleTip,
                  gated: fingertipTapsEnabled && !stickEngaged && simd_length(middleTip - wrist) > fingerExtendedGate)
        if stickEngaged {
            state.tapActive[.middleTip] = false
            snapshot.activePoints.remove(.middleTip)
        }
        updateTap(.ringTip, target: ringTip,
                  gated: fingertipTapsEnabled && simd_length(ringTip - wrist) > fingerExtendedGate)
        updateTap(.pinkyTip, target: pinkyTip,
                  gated: fingertipTapsEnabled && simd_length(pinkyTip - wrist) > fingerExtendedGate)
        // Index side (△ / D-Right): not while pinching, and thumb must be
        // closer to the side segment than to the fingertip.
        // Cyborg: the side tap IS the stick click (contact already zeroes
        // the stick), gated on the resting pose like all gameplay input.
        // v12.8.2: disabled in the essential core (summon keeps it for
        // Touchpad, hence the palmUp escape).
        let sideGate = inputProfile == .cyborgPaddles
            ? (state.restingPose && sideTapEnabled) || state.palmUp
            : !stickEngaged
        let sideEligible = sideGate &&
            simd_length(thumbTip - indexSide) < simd_length(thumbTip - indexTip)
        updateTap(.indexSide, target: indexSide, gated: sideEligible)
        if inputProfile == .thumbTaps, stickEngaged {
            state.tapActive[.indexSide] = false
            snapshot.activePoints.remove(.indexSide)
        }
        if stickEngaged { snapshot.activePoints.insert(.indexTip) }

        // --- Commit per-hand outputs -------------------------------------
        if isRight {
            rightHand = state
            rightStick = stick
            rightTrigger = trigger
        } else {
            leftHand = state
            leftStick = stick
            leftTrigger = trigger
        }
        refreshCompositeState()

        onHandsUpdated?(snapshot)
    }

    /// Rebuild the button bitmask from both hands' tap states.
    /// Summon mode (palm up) remaps that hand's taps to the system layer.
    private func refreshCompositeState() {
        var mask: UInt32 = 0
        let cyborg = inputProfile == .cyborgPaddles
        if rightHand.palmUp {
            if rightHand.tapActive[.middleTip] == true { mask |= PSButtonMask.options }
            if rightHand.tapActive[.ringTip] == true { mask |= PSButtonMask.share }
            if rightHand.tapActive[.pinkyTip] == true { mask |= PSButtonMask.ps }
            if rightHand.tapActive[.indexSide] == true { mask |= PSButtonMask.touchpad }
        } else if cyborg {
            // Right hand (v12.7): paddle presses = face buttons, middle lift
            // = △, index lift = R1, thumb tap on index side = R3.
            if rightHand.paddlePressed.contains(.middleTip) { mask |= PSButtonMask.cross }
            if rightHand.paddlePressed.contains(.ringTip) { mask |= PSButtonMask.circle }
            if rightHand.paddlePressed.contains(.pinkyTip) { mask |= PSButtonMask.square }
            if rightHand.middleLifted { mask |= PSButtonMask.triangle }
            if rightHand.tapActive[.indexSide] == true { mask |= PSButtonMask.r3 }
            if rightHand.indexLifted { mask |= PSButtonMask.r1 }
        } else {
            // Right hand → face buttons
            if rightHand.tapActive[.middleTip] == true { mask |= PSButtonMask.cross }
            if rightHand.tapActive[.ringTip] == true { mask |= PSButtonMask.circle }
            if rightHand.tapActive[.pinkyTip] == true { mask |= PSButtonMask.square }
            if rightHand.tapActive[.indexSide] == true { mask |= PSButtonMask.triangle }
        }
        if leftHand.palmUp {
            if leftHand.tapActive[.middleTip] == true { mask |= PSButtonMask.options }
            if leftHand.tapActive[.ringTip] == true { mask |= PSButtonMask.share }
            if leftHand.tapActive[.pinkyTip] == true { mask |= PSButtonMask.ps }
            if leftHand.tapActive[.indexSide] == true { mask |= PSButtonMask.touchpad }
        } else if cyborg {
            // Left hand (v12.7): paddle presses = D-pad, middle lift =
            // D-Right, index lift = L1, thumb tap on index side = L3.
            if leftHand.paddlePressed.contains(.middleTip) { mask |= PSButtonMask.dpadUp }
            if leftHand.paddlePressed.contains(.ringTip) { mask |= PSButtonMask.dpadDown }
            if leftHand.paddlePressed.contains(.pinkyTip) { mask |= PSButtonMask.dpadLeft }
            if leftHand.middleLifted { mask |= PSButtonMask.dpadRight }
            if leftHand.tapActive[.indexSide] == true { mask |= PSButtonMask.l3 }
            if leftHand.indexLifted { mask |= PSButtonMask.l1 }
        } else {
            // Left hand → D-pad
            if leftHand.tapActive[.middleTip] == true { mask |= PSButtonMask.dpadUp }
            if leftHand.tapActive[.ringTip] == true { mask |= PSButtonMask.dpadDown }
            if leftHand.tapActive[.pinkyTip] == true { mask |= PSButtonMask.dpadLeft }
            if leftHand.tapActive[.indexSide] == true { mask |= PSButtonMask.dpadRight }
        }
        // Bumpers (taps profile grip) and stick clicks (pinch + middle)
        if rightHand.bumperActive { mask |= PSButtonMask.r1 }
        if leftHand.bumperActive { mask |= PSButtonMask.l1 }
        if rightHand.stickClickActive { mask |= PSButtonMask.r3 }
        if leftHand.stickClickActive { mask |= PSButtonMask.l3 }
        if mask != buttonsBitmask {
            // Tuning telemetry (Debug builds only): every bitmask edge.
            DebugLog.print("[HoloPad] 🎛 mask=\(String(format: "%04x", mask)) L2=\(String(format: "%.2f", leftTrigger)) R2=\(String(format: "%.2f", rightTrigger))")
        }
        buttonsBitmask = mask

        // Throttled stick telemetry while deflected (~1Hz at 90Hz updates).
        stickLogCounter += 1
        if simd_length(rightStick) > 0.05 || simd_length(leftStick) > 0.05 {
            DebugLog.every(stickLogCounter, interval: 90, "HoloPad",
                           "🕹 L=(\(String(format: "%+.2f", leftStick.x)),\(String(format: "%+.2f", leftStick.y))) R=(\(String(format: "%+.2f", rightStick.x)),\(String(format: "%+.2f", rightStick.y)))")
        }

        let nowTracking = leftHand.tracked && rightHand.tracked
        if nowTracking != isTracking {
            isTracking = nowTracking
            DebugLog.info("HoloPad", nowTracking ? "🖐️ Both hands tracked" : "Hand tracking incomplete")
        }
    }
}
