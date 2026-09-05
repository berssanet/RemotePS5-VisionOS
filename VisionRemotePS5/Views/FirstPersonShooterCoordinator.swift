//
//  FirstPersonShooterCoordinator.swift
//  VisionRemotePS5
//
//  v13.1 "Controller Test Range" — first-person shooting range. A wall of
//  targets stands in front of the player, a gun is held in view, and a reticle
//  is swept across the wall with the right stick. Everything is driven by the
//  virtual controller with NO PS5 session:
//    right stick → move the aim reticle,
//    R2          → fire (hit the target under the reticle),
//    L2          → aim down / steady (tighter, slower reticle),
//    left stick  → strafe / step the range (parallax),
//    □ (square)  → respawn the targets.
//  Hit-testing is a 2D distance on the wall plane (reticle and targets share
//  the wall frame), so it needs no head-pose read — robust and deterministic.
//

import Foundation
import UIKit
import RealityKit
import simd

@MainActor
final class FirstPersonShooterCoordinator: ObservableObject {

    /// Range root (targets + reticle) — added to the RealityView content.
    let root = Entity()
    /// The held gun — the view parents this under an AnchorEntity(.head) so it
    /// stays in first-person view. Cosmetic only (not used for hit-testing).
    let gunRoot = Entity()

    private let wall = Entity()
    private let reticle = Entity()
    private var targets: [ModelEntity] = []
    private var targetAlive: [Bool] = []

    private(set) var score: Int = 0
    private(set) var shots: Int = 0

    /// v13.5 real-time tuning diagnostic (input → aim/score), matching the
    /// third-person coordinator so the logs read the same in both modes.
    var debugSummary: String {
        String(format: "aim=(%+.2f,%+.2f) hits=%d shots=%d", aim.x, aim.y, score, shots)
    }

    // Aim state (wall-local metres).
    private var aim: SIMD2<Float> = .zero
    private var recoil: Float = 0
    private var prevFire = false
    private var prevRespawn = false

    // Tuning.
    private static let wallZ: Float = -3.0
    private static let wallHalfW: Float = 1.35
    private static let wallHalfH: Float = 0.65
    private static let aimSpeed: Float = 2.4       // m/s at full stick
    private static let hitRadius: Float = 0.2
    private static let targetRadius: Float = 0.16
    private static let strafeSpeed: Float = 1.2

    init() {
        build()
    }

    // MARK: - Construction

    private func build() {
        root.name = "ShootingRange"
        wall.position = [0, 1.4, Self.wallZ]
        root.addChild(wall)

        addBackboard()
        addTargets()
        addReticle()
        buildGun()
    }

    private func addBackboard() {
        let board = ModelEntity(
            mesh: .generateBox(width: 2 * Self.wallHalfW + 0.4, height: 2 * Self.wallHalfH + 0.4, depth: 0.05, cornerRadius: 0.08),
            materials: [SimpleMaterial(color: UIColor(white: 0.13, alpha: 1.0), roughness: 0.9, isMetallic: false)]
        )
        board.position = [0, 0, -0.06]
        wall.addChild(board)
    }

    private func addTargets() {
        let cols: [Float] = [-1.0, -0.33, 0.33, 1.0]
        let rows: [Float] = [-0.45, 0.1, 0.55]
        for y in rows {
            for x in cols {
                var material = UnlitMaterial()
                material.color = .init(tint: UIColor.systemOrange.withAlphaComponent(0.95))
                let target = ModelEntity(mesh: .generateSphere(radius: Self.targetRadius), materials: [material])
                target.position = [x, y, 0]
                wall.addChild(target)
                targets.append(target)
                targetAlive.append(true)
            }
        }
    }

    private func addReticle() {
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor.green.withAlphaComponent(0.95))
        let bar = MeshResource.generateBox(width: 0.09, height: 0.008, depth: 0.008)
        let barV = MeshResource.generateBox(width: 0.008, height: 0.09, depth: 0.008)
        let h = ModelEntity(mesh: bar, materials: [material])
        let v = ModelEntity(mesh: barV, materials: [material])
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [material])
        reticle.addChild(h)
        reticle.addChild(v)
        reticle.addChild(dot)
        reticle.position = [0, 0, 0.05]
        wall.addChild(reticle)
    }

    private func buildGun() {
        gunRoot.name = "FPSGun"
        let body = ModelEntity(
            mesh: .generateBox(width: 0.07, height: 0.10, depth: 0.34, cornerRadius: 0.02),
            materials: [SimpleMaterial(color: UIColor(white: 0.2, alpha: 1.0), roughness: 0.5, isMetallic: true)]
        )
        let barrel = ModelEntity(
            mesh: .generateBox(width: 0.035, height: 0.035, depth: 0.24, cornerRadius: 0.015),
            materials: [SimpleMaterial(color: UIColor(white: 0.1, alpha: 1.0), roughness: 0.4, isMetallic: true)]
        )
        barrel.position = [0, 0.02, -0.26]
        let grip = ModelEntity(
            mesh: .generateBox(width: 0.06, height: 0.14, depth: 0.07, cornerRadius: 0.02),
            materials: [SimpleMaterial(color: UIColor(white: 0.15, alpha: 1.0), roughness: 0.6, isMetallic: false)]
        )
        grip.position = [0, -0.10, 0.12]
        grip.orientation = simd_quatf(angle: 0.25, axis: [1, 0, 0])
        body.addChild(barrel)
        body.addChild(grip)
        // Held low-right, angled toward the centre of view.
        body.position = [0.22, -0.28, -0.5]
        body.orientation = simd_quatf(angle: -0.08, axis: [0, 1, 0])
        gunRoot.addChild(body)
    }

    // MARK: - Game loop

    /// Advance one frame. Returns true if this frame landed a hit (for HUD/audio).
    @discardableResult
    func update(aim aimStick: SIMD2<Float>, fire: Bool, aimDown: Float,
                move: SIMD2<Float>, buttons: UInt32, dt: Float) -> Bool {
        // Aim: right stick sweeps the reticle; L2 steadies it (slower, tighter).
        let steady = 1.0 - 0.6 * min(max(aimDown, 0), 1)
        aim.x += aimStick.x * Self.aimSpeed * steady * dt
        aim.y += -aimStick.y * Self.aimSpeed * steady * dt   // stick up (-Y) = reticle up
        aim.x = min(max(aim.x, -Self.wallHalfW), Self.wallHalfW)
        aim.y = min(max(aim.y, -Self.wallHalfH), Self.wallHalfH)
        recoil = max(0, recoil - dt * 6)
        reticle.position = [aim.x, aim.y, 0.05]
        reticle.scale = SIMD3<Float>(repeating: (1.0 + recoil) * Float(0.6 + 0.4 * (1 - min(max(aimDown, 0), 1))))

        // Range parallax (left stick): step/strafe the whole range.
        root.position.x = min(max(root.position.x + move.x * Self.strafeSpeed * dt, -1.5), 1.5)
        root.position.z = min(max(root.position.z - move.y * Self.strafeSpeed * dt, -0.8), 1.0)

        // □ restocks the targets (rising edge) WITHOUT wiping score/shots —
        // that is the panel's separate "Reset" button (onReset → reset()).
        let respawn = buttons & PSButtonMask.square != 0
        if respawn, !prevRespawn { respawnTargets() }
        prevRespawn = respawn

        // Fire on rising edge of R2.
        var hitThisFrame = false
        if fire, !prevFire {
            shots += 1
            recoil = 0.6
            hitThisFrame = fireShot()
        }
        prevFire = fire
        return hitThisFrame
    }

    private func fireShot() -> Bool {
        var bestIndex = -1
        var bestDist = Self.hitRadius
        for i in targets.indices where targetAlive[i] {
            let t = targets[i].position
            let d = simd_length(SIMD2<Float>(t.x, t.y) - aim)
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        guard bestIndex >= 0 else { return false }
        targetAlive[bestIndex] = false
        targets[bestIndex].isEnabled = false
        score += 1
        if !targetAlive.contains(true) { respawnTargets() }  // cleared the wall
        return true
    }

    private func respawnTargets() {
        for i in targets.indices {
            targetAlive[i] = true
            targets[i].isEnabled = true
        }
    }

    /// Reset the round (respawn targets, recentre aim and range).
    func reset() {
        score = 0
        shots = 0
        aim = .zero
        root.position = .zero
        respawnTargets()
    }
}
