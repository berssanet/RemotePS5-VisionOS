//
//  Spatial3DSurface.swift
//  VisionRemotePS5
//
//  Spatial 3D streaming surface: renders the PS5 stream on the depth-displaced
//  LowLevelMesh screen owned by SpatialScreenCoordinator. Video pixels flow
//  through the SAME ImmersiveTextureCoordinator LowLevelTexture as the flat
//  screen; only the geometry differs (AI depth displacement at ~30Hz).
//
//  Successor of the removed 2026-02-05 Spatial3DSurface (commit f3b3b73),
//  which relied on CustomMaterial — unavailable on visionOS.
//

import SwiftUI
import RealityKit
import Metal

@available(visionOS 2.0, *)
struct Spatial3DSurface: View {
    let texture: MTLTexture
    let frameId: UInt64

    // Virtual wheel support (parity with Immersive4KSurface)
    var showWheel: Bool = false
    private let wheelPos: SIMD3<Float> = [0, 0.9, -1.2]
    private let wheelScale: Float = 0.35

    var body: some View {
        RealityView { content in
            guard let entity = await SpatialScreenCoordinator.shared.getOrCreateEntity() else {
                DebugLog.error("Spatial3DSurface", "Failed to create spatial screen entity")
                return
            }
            if entity.parent == nil {
                content.add(entity)
                DebugLog.info("Spatial3DSurface", "✅ Spatial screen added to scene")
            }
            pushVideoFrame()

            // Load the 3D wheel into the same scene (parity with the flat
            // surface — Phase 7 backlog item). Same model, pose, and scale.
            if showWheel {
                do {
                    let wheelEntity = try await Entity(named: "MercedesF1Wheel")
                    wheelEntity.position = wheelPos
                    wheelEntity.scale = SIMD3<Float>(repeating: wheelScale)
                    wheelEntity.name = "F1WheelRoot"
                    // USDZ face points -Y; bring it toward the user, then
                    // tilt like a cockpit wheel (see Immersive4KSurface).
                    let faceToUser = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
                    let cockpitTilt = simd_quatf(angle: .pi * 0.11, axis: [1, 0, 0])
                    wheelEntity.orientation = cockpitTilt * faceToUser
                    content.add(wheelEntity)
                    DebugLog.info("Spatial3DSurface", "✅ Wheel added to spatial scene")
                } catch {
                    DebugLog.error("Spatial3DSurface", "Failed to load wheel: \(error)")
                }
            }
        } update: { _ in
            pushVideoFrame()
        }
    }

    /// Feed the current upscaled frame into the shared video texture and
    /// hand the resource to the spatial screen once it exists.
    @MainActor
    private func pushVideoFrame() {
        let videoCoordinator = ImmersiveTextureCoordinator.shared
        videoCoordinator.updateTexture(from: texture)
        if let resource = videoCoordinator.currentTextureResource {
            SpatialScreenCoordinator.shared.adoptVideoTexture(resource)
        }
    }
}
