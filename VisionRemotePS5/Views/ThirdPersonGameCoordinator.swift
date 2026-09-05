//
//  ThirdPersonGameCoordinator.swift
//  VisionRemotePS5
//
//  v13.1 "Controller Test Range" — third-person mini-game. A floating arena
//  in front of the player holds the procedural character (TestDummyCoordinator)
//  and a set of coins. The controller drives it with NO PS5 session:
//    left stick  → run around the arena (the character faces its motion),
//    ✕ (cross)   → jump (reach elevated coins),
//    right stick → orbit the camera (visionOS can't move the head, so the
//                  whole arena rotates — this reads as the camera circling).
//  Collect a coin by running (or jumping) into it; score is shown in the HUD.
//

import Foundation
import UIKit
import RealityKit
import simd

@MainActor
final class ThirdPersonGameCoordinator: ObservableObject {

    /// Arena root — added to the RealityView content once.
    let root = Entity()
    /// Rotated by the right stick to orbit the view around the arena.
    private let cameraPivot = Entity()
    private let character = TestDummyCoordinator()

    private struct Coin {
        let entity: ModelEntity
        let position: SIMD3<Float>   // arena-local (y = height)
        var collected = false
    }
    private var coins: [Coin] = []

    private(set) var score: Int = 0

    // Character state (arena-local).
    private var charPos: SIMD2<Float> = .zero
    private var charLift: Float = 0
    private var charVelY: Float = 0
    private var prevJump = false
    private var cameraYaw: Float = 0
    private var lastMove: SIMD2<Float> = .zero   // bot displacement this frame

    /// v13.5 real-time tuning diagnostic: what the bot/camera did this frame,
    /// so the input→output chain (hand → stick → bot) is legible in the logs.
    var debugSummary: String {
        String(format: "bot@(%+.2f,%+.2f) moved=(%+.3f,%+.3f) camYaw=%+.2f lift=%.2f coins=%d",
               charPos.x, charPos.y, lastMove.x, lastMove.y, cameraYaw, charLift, score)
    }

    // Tuning.
    private static let arenaRadius: Float = 2.1
    private static let moveSpeed: Float = 1.7      // m/s at full stick
    private static let orbitSpeed: Float = 1.4     // rad/s at full stick
    private static let gravity: Float = 9.8
    private static let jumpImpulse: Float = 3.3
    private static let collectRadius: Float = 0.45
    // Grounded reach ~0.9m collects the low coins (y≈0.15) but NOT the
    // elevated ones (y≈1.0–1.2); the jump apex (~0.56m, from jumpImpulse/
    // gravity below) lifts the character enough to reach those — so ✕ matters.
    private static let reachHeight: Float = 0.7

    init() {
        build()
    }

    // MARK: - Construction

    private func build() {
        root.name = "ThirdPersonArena"
        root.position = [0, 0, -3.0]        // life-size arena 3m ahead, on the floor
        root.addChild(cameraPivot)

        addGround()
        addObstacles()
        addCoins()
        cameraPivot.addChild(character.root)
    }

    private func addGround() {
        let disc = ModelEntity(
            mesh: .generateBox(width: 2 * Self.arenaRadius, height: 0.04, depth: 2 * Self.arenaRadius, cornerRadius: Self.arenaRadius),
            materials: [SimpleMaterial(color: UIColor(white: 0.16, alpha: 1.0), roughness: 0.9, isMetallic: false)]
        )
        disc.position = [0, -0.02, 0]
        cameraPivot.addChild(disc)

        // Glowing rim so the arena edge reads clearly.
        let rim = ModelEntity(
            mesh: .generateBox(width: 2 * Self.arenaRadius + 0.06, height: 0.02, depth: 2 * Self.arenaRadius + 0.06, cornerRadius: Self.arenaRadius),
            materials: [UnlitMaterial(color: UIColor.cyan.withAlphaComponent(0.35))]
        )
        rim.position = [0, -0.03, 0]
        cameraPivot.addChild(rim)
    }

    private func addObstacles() {
        let spots: [(Float, Float, Float)] = [
            (-1.3, -0.9, 0.5), (1.2, -1.0, 0.7), (0.0, 1.4, 0.4), (1.4, 1.0, 0.6)
        ]
        for (x, z, h) in spots {
            let block = ModelEntity(
                mesh: .generateBox(width: 0.4, height: h, depth: 0.4, cornerRadius: 0.05),
                materials: [SimpleMaterial(color: UIColor(white: 0.35, alpha: 1.0), roughness: 0.8, isMetallic: false)]
            )
            block.position = [x, h / 2, z]
            cameraPivot.addChild(block)
        }
    }

    private func addCoins() {
        // Mix of ground-level and elevated coins (elevated ones need a jump).
        let spec: [(Float, Float, Float)] = [
            (-0.8, 0.6, 0.15), (0.9, -0.3, 0.15), (0.2, 1.0, 0.15),
            (-1.4, 0.2, 1.1), (1.3, 0.6, 1.2), (0.0, -1.3, 1.0)
        ]
        for (x, z, y) in spec {
            var material = UnlitMaterial()
            material.color = .init(tint: UIColor.systemYellow.withAlphaComponent(0.95))
            let coin = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [material])
            coin.position = [x, y, z]
            cameraPivot.addChild(coin)
            coins.append(Coin(entity: coin, position: [x, y, z]))
        }
    }

    // MARK: - Game loop

    /// Advance one frame. All inputs come straight from the gesture service.
    func update(move: SIMD2<Float>, jump: Bool, cameraX: Float, buttons: UInt32, dt: Float) {
        // Camera orbit (right stick). Deadzone avoids drift from a noisy stick.
        if abs(cameraX) > 0.08 {
            cameraYaw += cameraX * Self.orbitSpeed * dt
        }
        cameraPivot.orientation = simd_quatf(angle: cameraYaw, axis: [0, 1, 0])

        // Locomotion (left stick): x = strafe, y-up = forward (-Z arena-local).
        let moveDir = SIMD2<Float>(move.x, -move.y)
        let beforePos = charPos
        charPos += moveDir * Self.moveSpeed * dt
        let dist = simd_length(charPos)
        if dist > Self.arenaRadius {
            charPos = charPos / dist * Self.arenaRadius
        }
        lastMove = charPos - beforePos

        // Jump physics (rising edge on ✕, only when grounded).
        if jump, !prevJump, charLift <= 0.001 {
            charVelY = Self.jumpImpulse
        }
        prevJump = jump
        charVelY -= Self.gravity * dt
        charLift += charVelY * dt
        if charLift <= 0 { charLift = 0; charVelY = 0 }

        character.place(groundPos: charPos, lift: charLift, moveDir: moveDir)
        character.animate(speed: simd_length(moveDir), dt: dt)
        character.flash(buttons: buttons)

        collectCoins()
    }

    private func collectCoins() {
        let charTop = charLift + Self.reachHeight
        for i in coins.indices where !coins[i].collected {
            let c = coins[i].position
            let horizontal = simd_length(SIMD2<Float>(c.x, c.z) - charPos)
            if horizontal < Self.collectRadius, c.y <= charTop + 0.2 {
                coins[i].collected = true
                coins[i].entity.isEnabled = false
                score += 1
            }
        }
    }

    /// Reset the round (respawn all coins, recentre the character).
    func reset() {
        score = 0
        charPos = .zero
        charLift = 0
        charVelY = 0
        cameraYaw = 0
        cameraPivot.orientation = .init(angle: 0, axis: [0, 1, 0])
        for i in coins.indices {
            coins[i].collected = false
            coins[i].entity.isEnabled = true
        }
    }
}
