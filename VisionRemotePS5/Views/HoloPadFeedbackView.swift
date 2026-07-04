//
//  HoloPadFeedbackView.swift
//  VisionRemotePS5
//
//  v12.5 "Arcane HUD" — per-joint anchoring. Every fingertip orb is a child
//  of its OWN `AnchorEntity(.hand(..., location: .joint(for:)))` at position
//  .zero: the visionOS compositor places it exactly on the joint, with
//  predicted tracking. No world-space math, no hand-local frame math, no
//  calibration — alignment is guaranteed by the system.
//
//  History: v12.3 placed feedback with ARKit world coordinates (drifted off
//  the hands — ARKit and RealityKit scene origins differ in an
//  ImmersiveSpace); v12.4 parented to a wrist anchor with skeleton-local
//  offsets (rotated around the wrist — the RealityKit anchor frame does not
//  match the ARKit skeleton frame). Per-joint anchors remove the frame
//  problem entirely. Skeleton threads were removed with the frame math;
//  reintroducing them requires SpatialTrackingSession-readable transforms.
//
//  The ring HUD rides a `.palm` anchor; press flares, trigger arc, summon
//  bloom and the stick ember remain driven by the service's 90Hz snapshots
//  (state only — never positions).
//

import SwiftUI
import RealityKit
import QuartzCore  // CACurrentMediaTime monotonic clock

// MARK: - Per-hand holographic ring

@available(visionOS 2.0, *)
@MainActor
private final class ArcaneRing {

    /// Ring assembly root — parented under the hand's `.palm` anchor.
    let root = Entity()
    private let spinner = Entity()
    private var segments: [ModelEntity] = []
    private var glyphs: [HoloPadHandSnapshot.Point: ModelEntity] = [:]
    private let ember: ModelEntity
    private let isRight: Bool

    private var spinAngle: Float = 0
    private var lastSpinTime: CFTimeInterval?
    private var summonActive = false
    private(set) var lastUpdateTime: CFTimeInterval = 0

    private static let ringRadius: Float = 0.055
    private static let segmentCount = 24
    /// Hover distance from the palm along the palm anchor's local up axis.
    /// If the ring appears INSIDE/behind the hand on device, flip the sign.
    private static let hoverOffset: Float = 0.05
    private static let spinSpeed: Float = 0.6  // rad/s — slow, alive, not busy

    /// Gameplay glyph colors per tap point.
    private static func gameplayColor(for point: HoloPadHandSnapshot.Point, isRight: Bool) -> UIColor {
        guard isRight else { return .cyan }           // left hand: D-pad, uniform cyan
        switch point {
        case .middleTip: return .systemBlue           // ✕
        case .ringTip: return .systemRed              // ○
        case .pinkyTip: return .systemPink            // □
        case .indexSide: return .green                // △
        default: return .white
        }
    }

    /// System (summon) glyph colors per tap point — same on both hands.
    private static func systemColor(for point: HoloPadHandSnapshot.Point) -> UIColor {
        switch point {
        case .middleTip: return .orange               // Options
        case .ringTip: return .cyan                   // Share
        case .pinkyTip: return .white                 // PS
        case .indexSide: return .purple               // Touchpad
        default: return .white
        }
    }

    /// Cardinal placement of each tappable point's glyph on the ring.
    private static let glyphLayout: [(HoloPadHandSnapshot.Point, SIMD3<Float>)] = [
        (.indexSide, SIMD3<Float>(0, 0, -1)),   // north
        (.ringTip, SIMD3<Float>(1, 0, 0)),      // east
        (.middleTip, SIMD3<Float>(0, 0, 1)),    // south
        (.pinkyTip, SIMD3<Float>(-1, 0, 0))     // west
    ]

    init(isRight: Bool) {
        self.isRight = isRight

        // Ember: the stick indicator drifting inside the ring.
        let emberMesh = MeshResource.generateSphere(radius: 0.006)
        var emberMaterial = UnlitMaterial()
        emberMaterial.color = .init(tint: UIColor.orange.withAlphaComponent(0.95))
        ember = ModelEntity(mesh: emberMesh, materials: [emberMaterial])
        ember.name = "ArcaneEmber"

        root.name = "ArcaneRing.\(isRight ? "R" : "L")"
        root.position = [0, Self.hoverOffset, 0]
        root.addChild(spinner)
        root.addChild(ember)

        buildSegments()
        buildGlyphs()
    }

    private func buildSegments() {
        let mesh = MeshResource.generateBox(width: 0.012, height: 0.0015, depth: 0.004)
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor.cyan.withAlphaComponent(0.55))
        for i in 0..<Self.segmentCount {
            let angle = Float(i) / Float(Self.segmentCount) * 2 * .pi
            let segment = ModelEntity(mesh: mesh, materials: [material])
            segment.position = [Self.ringRadius * sin(angle), 0, Self.ringRadius * cos(angle)]
            segment.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            spinner.addChild(segment)
            segments.append(segment)
        }
    }

    private func buildGlyphs() {
        for (point, direction) in Self.glyphLayout {
            let mesh = MeshResource.generateSphere(radius: 0.007)
            var material = UnlitMaterial()
            material.color = .init(tint: Self.gameplayColor(for: point, isRight: isRight).withAlphaComponent(0.9))
            let glyph = ModelEntity(mesh: mesh, materials: [material])
            glyph.position = direction * (Self.ringRadius + 0.014)
            root.addChild(glyph)
            glyphs[point] = glyph
        }
    }

    private func applyGlyphPalette(system: Bool) {
        for (point, glyph) in glyphs {
            let color = system
                ? Self.systemColor(for: point)
                : Self.gameplayColor(for: point, isRight: isRight)
            var material = UnlitMaterial()
            material.color = .init(tint: color.withAlphaComponent(0.9))
            glyph.model?.materials = [material]
        }
    }

    /// State-only update — the palm anchor owns position/orientation.
    func update(with snapshot: HoloPadHandSnapshot) {
        let now = CACurrentMediaTime()
        lastUpdateTime = now

        // Slow orbital spin (monotonic clock).
        if let last = lastSpinTime {
            spinAngle += Float(now - last) * Self.spinSpeed
        }
        lastSpinTime = now
        spinner.orientation = simd_quatf(angle: spinAngle, axis: [0, 1, 0])

        // Summon bloom: scale up + swap glyph palette (transition only).
        if snapshot.isPalmUp != summonActive {
            summonActive = snapshot.isPalmUp
            applyGlyphPalette(system: summonActive)
        }
        root.scale = SIMD3<Float>(repeating: summonActive ? 1.35 : 1.0)

        // Trigger arc: light up segments proportional to curl.
        let litCount = Int(snapshot.triggerValue * Float(segments.count))
        for (i, segment) in segments.enumerated() {
            segment.scale = SIMD3<Float>(repeating: i < litCount ? 1.7 : 1.0)
        }

        // Stick ember drifts with deflection; grows while engaged.
        let engaged = snapshot.stickOrigin != nil
        ember.position = [
            snapshot.stickValue.x * Self.ringRadius * 0.6,
            0.004,
            snapshot.stickValue.y * Self.ringRadius * 0.6
        ]
        ember.scale = SIMD3<Float>(repeating: engaged ? 1.8 : 1.0)

        // Glyph flares on active taps.
        for (point, glyph) in glyphs {
            let active = snapshot.activePoints.contains(point)
            glyph.scale = SIMD3<Float>(repeating: active ? 1.9 : 1.0)
        }
    }
}

// MARK: - Coordinator

@available(visionOS 2.0, *)
@MainActor
final class HoloPadFeedbackCoordinator {

    static let shared = HoloPadFeedbackCoordinator()

    let root = Entity()

    /// Joint bound to each feedback point — the whole alignment story.
    /// (RealityKit's own HandJoint enum, not ARKit's HandSkeleton.JointName.)
    private static let jointForPoint: [HoloPadHandSnapshot.Point: AnchoringComponent.Target.HandLocation.HandJoint] = [
        .thumbTip: .thumbTip,
        .indexTip: .indexFingerTip,
        .indexSide: .indexFingerIntermediateBase,
        .middleTip: .middleFingerTip,
        .ringTip: .ringFingerTip,
        .pinkyTip: .littleFingerTip
    ]

    private struct HandAssembly {
        var anchors: [AnchorEntity] = []
        var orbs: [HoloPadHandSnapshot.Point: ModelEntity] = [:]
        var ring: ArcaneRing
    }
    private var assemblies: [Bool: HandAssembly] = [:]  // key: isRight

    /// Spatial click played on tap activation — audio substitutes haptics.
    private var clickResource: AudioFileResource?
    private var previousActive: [Bool: Set<HoloPadHandSnapshot.Point>] = [:]

    private init() {
        Task { @MainActor in
            do {
                clickResource = try await AudioFileResource(named: "holopad_click.wav")
            } catch {
                DebugLog.warning("HoloPad", "Click sound unavailable: \(error)")
            }
        }
    }

    private func assembly(isRight: Bool) -> HandAssembly {
        if let existing = assemblies[isRight] { return existing }

        let chirality: AnchoringComponent.Target.Chirality = isRight ? .right : .left
        var assembly = HandAssembly(ring: ArcaneRing(isRight: isRight))

        // One system anchor PER JOINT; the orb sits at .zero inside it.
        for (point, jointName) in Self.jointForPoint {
            let anchor = AnchorEntity(
                .hand(chirality, location: .joint(for: jointName)),
                trackingMode: .predicted
            )
            anchor.name = "HoloPadJoint.\(isRight ? "R" : "L").\(point)"

            let mesh = MeshResource.generateSphere(radius: 0.005)
            var material = UnlitMaterial()
            material.color = .init(tint: UIColor.white.withAlphaComponent(0.7))
            let orb = ModelEntity(mesh: mesh, materials: [material])
            anchor.addChild(orb)

            root.addChild(anchor)
            assembly.anchors.append(anchor)
            assembly.orbs[point] = orb
        }

        // Ring HUD rides the palm anchor.
        let palmAnchor = AnchorEntity(
            .hand(chirality, location: .palm),
            trackingMode: .predicted
        )
        palmAnchor.name = "HoloPadPalm.\(isRight ? "R" : "L")"
        palmAnchor.addChild(assembly.ring.root)
        root.addChild(palmAnchor)
        assembly.anchors.append(palmAnchor)

        assemblies[isRight] = assembly
        return assembly
    }

    /// Called from HandGestureControllerService at up to 90Hz per hand.
    /// Positions are system-owned; this only animates STATE (flares, arc,
    /// ember, bloom, clicks).
    func update(with snapshot: HoloPadHandSnapshot) {
        let assembly = assembly(isRight: snapshot.isRight)
        assembly.ring.update(with: snapshot)

        for (point, orb) in assembly.orbs {
            let active = snapshot.activePoints.contains(point)
            orb.scale = SIMD3<Float>(repeating: active ? 2.2 : 1.0)
        }

        // Spatial click on every NEW tap activation (rising edge only).
        let previous = previousActive[snapshot.isRight] ?? []
        let risen = snapshot.activePoints.subtracting(previous)
        if !risen.isEmpty, let clickResource {
            for point in risen {
                assembly.orbs[point]?.playAudio(clickResource)
            }
        }
        previousActive[snapshot.isRight] = snapshot.activePoints

        // Hand-tracking staleness: hide a hand's whole assembly when its
        // snapshots stop arriving.
        assembly.anchors.forEach { $0.isEnabled = true }
        let now = CACurrentMediaTime()
        if let other = assemblies[!snapshot.isRight],
           now - other.ring.lastUpdateTime > 0.5 {
            other.anchors.forEach { $0.isEnabled = false }
        }
    }

    /// Remove all feedback entities (VR exit / mode switch).
    func reset() {
        root.children.forEach { $0.removeFromParent() }
        root.removeFromParent()
        assemblies.removeAll()
        previousActive.removeAll()
    }
}

// MARK: - Hosting view

/// RealityView hosting the feedback entities and wiring the service callback.
@available(visionOS 2.0, *)
struct HoloPadFeedbackView: View {
    let service: HandGestureControllerService

    var body: some View {
        RealityView { content in
            let coordinator = HoloPadFeedbackCoordinator.shared
            content.add(coordinator.root)
            service.onHandsUpdated = { snapshot in
                coordinator.update(with: snapshot)
            }
            DebugLog.info("HoloPad", "✨ Arcane HUD attached (per-joint anchors)")
        }
    }
}
