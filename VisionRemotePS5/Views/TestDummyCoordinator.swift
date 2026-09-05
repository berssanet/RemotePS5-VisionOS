//
//  TestDummyCoordinator.swift
//  VisionRemotePS5
//
//  v13.0 "Controller Test Range": a procedural humanoid built from rounded
//  boxes + spheres (no external asset, keeping the project minimalist).
//  v13.1: it is now the THIRD-PERSON game character — it runs, jumps, and
//  turns to face its movement, driven by the virtual controller with no PS5
//  session. Face-button orbs above the head still flare so button presses are
//  visible while testing. All motion is lerp/phase-smoothed.
//
//  Hierarchy (so locomotion and animation compose cleanly):
//    root          — ground position (x,z) + jump lift (y), set per frame
//      facingPivot — yaw toward the movement direction
//        leftHip / rightHip — leg swing (run cycle)
//        bodyPivot          — torso + arms + head; run bob
//          leftShoulder / rightShoulder — arm swing (run cycle)
//          headPivot                    — subtle head bob
//          face orbs (✕ ○ □ △)          — flare on button press
//

import Foundation
import UIKit
import RealityKit
import simd

/// Plain snapshot of the virtual controller, consumed locally by the test
/// range (character/shooter + HUD) instead of being forwarded to the PS5.
/// Mirrors the seven values HandGestureControllerService exposes.
struct TrainingInputSample: Equatable {
    var buttons: UInt32 = 0
    var leftStick: SIMD2<Float> = .zero
    var rightStick: SIMD2<Float> = .zero
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0

    func isPressed(_ mask: UInt32) -> Bool { buttons & mask != 0 }
}

/// Builds and animates the procedural character. Kept as a @StateObject by the
/// owning coordinator so it survives body re-evaluation; all mutation happens
/// on the MainActor game loop.
@MainActor
final class TestDummyCoordinator: ObservableObject {

    /// Character root — the third-person coordinator sets its world position.
    let root = Entity()

    private let facingPivot = Entity()  // yaw toward movement
    private let bodyPivot = Entity()    // torso + arms + head; run bob
    private let headPivot = Entity()
    private let leftShoulder = Entity()
    private let rightShoulder = Entity()
    private let leftHip = Entity()
    private let rightHip = Entity()

    /// Face-button orbs keyed by their PSButtonMask bit.
    private var faceOrbs: [UInt32: ModelEntity] = [:]
    private var orbScale: [UInt32: Float] = [:]

    // Animation state.
    private var runPhase: Float = 0
    private var facingYaw: Float = 0
    private var swing: Float = 0        // smoothed run amplitude 0…1

    // Palette.
    private static let bodyColor = UIColor(white: 0.82, alpha: 1.0)
    private static let jointColor = UIColor(red: 0.0, green: 0.45, blue: 0.95, alpha: 1.0)
    private static let visorColor = UIColor(white: 0.08, alpha: 1.0)

    // Tuning.
    private static let runCadence: Float = 9.0    // rad/s of the leg cycle at full speed
    private static let maxArmSwing: Float = 0.7   // rad
    private static let maxLegSwing: Float = 0.8   // rad

    init() {
        build()
    }

    // MARK: - Construction

    private func build() {
        root.name = "TestCharacter"
        root.addChild(facingPivot)

        addLegs()

        bodyPivot.position = [0, 0.92, 0]
        facingPivot.addChild(bodyPivot)

        addTorso()
        addArms()
        addHeadAndFace()
    }

    private func addLegs() {
        for (side, hip) in [(Float(-1), leftHip), (Float(1), rightHip)] {
            hip.position = [side * 0.11, 0.9, 0]
            facingPivot.addChild(hip)

            let thigh = makeLimb(length: 0.42, thickness: 0.14, color: Self.bodyColor)
            thigh.position = [0, -0.22, 0]
            hip.addChild(thigh)

            let knee = makeJoint(radius: 0.075)
            knee.position = [0, -0.44, 0]
            hip.addChild(knee)

            let shin = makeLimb(length: 0.44, thickness: 0.12, color: Self.bodyColor)
            shin.position = [0, -0.66, 0]
            hip.addChild(shin)

            let foot = ModelEntity(
                mesh: .generateBox(width: 0.13, height: 0.07, depth: 0.24, cornerRadius: 0.03),
                materials: [SimpleMaterial(color: Self.bodyColor, roughness: 0.7, isMetallic: false)]
            )
            foot.position = [0, -0.87, 0.05]
            hip.addChild(foot)
        }
    }

    private func addTorso() {
        let pelvis = makeJoint(radius: 0.12, color: Self.jointColor)
        pelvis.position = [0, 0.02, 0]
        bodyPivot.addChild(pelvis)

        for i in 0..<3 {
            let ring = ModelEntity(
                mesh: .generateBox(width: 0.24, height: 0.03, depth: 0.16, cornerRadius: 0.015),
                materials: [SimpleMaterial(color: Self.jointColor, roughness: 0.4, isMetallic: true)]
            )
            ring.position = [0, 0.12 + Float(i) * 0.07, 0]
            bodyPivot.addChild(ring)
        }

        let chest = ModelEntity(
            mesh: .generateBox(width: 0.34, height: 0.28, depth: 0.19, cornerRadius: 0.08),
            materials: [SimpleMaterial(color: Self.bodyColor, roughness: 0.6, isMetallic: false)]
        )
        chest.position = [0, 0.46, 0]
        bodyPivot.addChild(chest)
    }

    private func addArms() {
        for (side, shoulder) in [(Float(-1), leftShoulder), (Float(1), rightShoulder)] {
            let joint = makeJoint(radius: 0.085, color: Self.jointColor)
            joint.position = [side * 0.24, 0.56, 0]
            bodyPivot.addChild(joint)

            shoulder.position = [side * 0.24, 0.56, 0]
            bodyPivot.addChild(shoulder)

            let upper = makeLimb(length: 0.30, thickness: 0.10, color: Self.bodyColor)
            upper.position = [0, -0.17, 0]
            shoulder.addChild(upper)

            let elbow = makeJoint(radius: 0.06)
            elbow.position = [0, -0.34, 0]
            shoulder.addChild(elbow)

            let fore = makeLimb(length: 0.28, thickness: 0.085, color: Self.bodyColor)
            fore.position = [0, -0.50, 0]
            shoulder.addChild(fore)

            let hand = makeJoint(radius: 0.065, color: Self.jointColor)
            hand.position = [0, -0.66, 0]
            shoulder.addChild(hand)
        }
    }

    private func addHeadAndFace() {
        let neck = makeJoint(radius: 0.06, color: Self.jointColor)
        neck.position = [0, 0.64, 0]
        bodyPivot.addChild(neck)

        headPivot.position = [0, 0.70, 0]
        bodyPivot.addChild(headPivot)

        let head = ModelEntity(
            mesh: .generateSphere(radius: 0.13),
            materials: [SimpleMaterial(color: Self.bodyColor, roughness: 0.5, isMetallic: false)]
        )
        headPivot.addChild(head)

        let visor = ModelEntity(
            mesh: .generateBox(width: 0.16, height: 0.06, depth: 0.04, cornerRadius: 0.02),
            materials: [UnlitMaterial(color: Self.visorColor)]
        )
        visor.position = [0, 0.01, 0.11]
        headPivot.addChild(visor)

        let layout: [(UInt32, UIColor, Float)] = [
            (PSButtonMask.square, .systemPink, -0.18),
            (PSButtonMask.triangle, .systemGreen, -0.06),
            (PSButtonMask.circle, .systemRed, 0.06),
            (PSButtonMask.cross, .systemBlue, 0.18)
        ]
        for (mask, color, xOffset) in layout {
            let orb = ModelEntity(
                mesh: .generateSphere(radius: 0.028),
                materials: [UnlitMaterial(color: color.withAlphaComponent(0.85))]
            )
            orb.position = [xOffset, 0.30, 0.02]
            headPivot.addChild(orb)
            faceOrbs[mask] = orb
            orbScale[mask] = 1.0
        }
    }

    // MARK: - Locomotion (driven by ThirdPersonGameCoordinator)

    /// Place the character on the ground and face its movement direction.
    /// `groundPos` is the world x/z; `lift` is the jump height above ground.
    func place(groundPos: SIMD2<Float>, lift: Float, moveDir: SIMD2<Float>) {
        root.position = [groundPos.x, lift, groundPos.y]
        if simd_length(moveDir) > 0.05 {
            let targetYaw = atan2(moveDir.x, -moveDir.y)   // forward = -Z
            facingYaw += shortestAngle(targetYaw - facingYaw) * 0.2
        }
        facingPivot.orientation = simd_quatf(angle: facingYaw, axis: [0, 1, 0])
    }

    /// Advance the run cycle. `speed` is 0…1 (fraction of full run speed).
    func animate(speed: Float, dt: Float) {
        swing += (min(max(speed, 0), 1) - swing) * 0.2
        runPhase += Self.runCadence * max(speed, 0.0) * dt
        let s = sin(runPhase) * swing

        leftShoulder.orientation = simd_quatf(angle: Self.maxArmSwing * s, axis: [1, 0, 0])
        rightShoulder.orientation = simd_quatf(angle: -Self.maxArmSwing * s, axis: [1, 0, 0])
        leftHip.orientation = simd_quatf(angle: -Self.maxLegSwing * s, axis: [1, 0, 0])
        rightHip.orientation = simd_quatf(angle: Self.maxLegSwing * s, axis: [1, 0, 0])

        // Vertical bob + slight forward lean while running.
        let bob = abs(sin(runPhase)) * 0.04 * swing
        bodyPivot.position = [0, 0.92 + bob, 0]
        bodyPivot.orientation = simd_quatf(angle: 0.18 * swing, axis: [1, 0, 0])
        headPivot.orientation = simd_quatf(angle: -0.10 * swing, axis: [1, 0, 0])
    }

    /// Flare the face orbs matching the pressed buttons (lerp-smoothed).
    func flash(buttons: UInt32) {
        for (mask, orb) in faceOrbs {
            let target: Float = (buttons & mask != 0) ? 2.1 : 1.0
            let current = orbScale[mask] ?? 1.0
            let next = current + (target - current) * 0.3
            orbScale[mask] = next
            orb.scale = SIMD3<Float>(repeating: next)
        }
    }

    // MARK: - Helpers

    private func shortestAngle(_ a: Float) -> Float {
        var angle = a
        while angle > .pi { angle -= 2 * .pi }
        while angle < -.pi { angle += 2 * .pi }
        return angle
    }

    private func makeLimb(length: Float, thickness: Float, color: UIColor) -> ModelEntity {
        ModelEntity(
            mesh: .generateBox(width: thickness, height: length, depth: thickness,
                               cornerRadius: thickness * 0.5),
            materials: [SimpleMaterial(color: color, roughness: 0.6, isMetallic: false)]
        )
    }

    private func makeJoint(radius: Float, color: UIColor? = nil) -> ModelEntity {
        ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [SimpleMaterial(color: color ?? Self.jointColor, roughness: 0.4, isMetallic: true)]
        )
    }
}
