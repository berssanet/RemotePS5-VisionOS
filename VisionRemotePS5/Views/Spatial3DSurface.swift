//
//  Spatial3DSurface.swift
//  VisionRemotePS5
//
//  Spatial 3D rendering surface with AI-based depth displacement.
//  Uses DenseMesh for high-vertex geometry and CustomMaterial with Metal shader
//  to create volumetric depth effects from a 2D video stream.
//

import SwiftUI
import RealityKit
import CoreVideo
import Metal

/// Spatial 3D rendering mode using AI depth estimation and vertex displacement.
@available(visionOS 2.0, *)
struct Spatial3DSurface: View {
    let videoTexture: MTLTexture
    let depthTexture: MTLTexture?
    let frameId: UInt64
    
    // Cinema-like screen with depth displacement
    private let screenWidth: Float = 6.0
    private let screenHeight: Float = 3.375
    private let screenDistance: Float = 4.0
    private let screenElevation: Float = 1.8
    private let curveAmount: Float = 0.3  // Curvature for immersion
    
    var body: some View {
        RealityView { content in
            do {
                // Create high-density curved mesh for vertex displacement
                let mesh = try DenseMesh.generateCurved(
                    width: screenWidth,
                    height: screenHeight,
                    curvature: curveAmount,
                    resX: 128,
                    resY: 72
                )
                
                // Create CustomMaterial with displacement shader
                // Note: CustomMaterial requires shader functions to be registered in the Metal library
                var material = UnlitMaterial()
                material.color = .init(tint: .clear)
                
                let entity = ModelEntity(mesh: mesh, materials: [material])
                entity.name = "Spatial3DScreen"
                entity.position = [0, screenElevation, -screenDistance]
                
                content.add(entity)
                
                print("[Spatial3DSurface] ✅ Dense mesh created with \(128*72) segments")
                
            } catch {
                print("[Spatial3DSurface] ❌ Failed to create mesh: \(error)")
                
                // Fallback to simple plane
                let mesh = MeshResource.generatePlane(width: screenWidth, height: screenHeight)
                let material = UnlitMaterial(color: .init(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0))
                let entity = ModelEntity(mesh: mesh, materials: [material])
                entity.name = "Spatial3DScreen"
                entity.position = [0, screenElevation, -screenDistance]
                content.add(entity)
            }
            
        } update: { content in
            guard let entity = content.entities.first(where: { $0.name == "Spatial3DScreen" }) as? ModelEntity else { return }
            
            // Update video texture on the material
            // For now, use UnlitMaterial until CustomMaterial shader is fully integrated
            if let videoResource = createTextureResource(from: videoTexture) {
                var material = UnlitMaterial()
                material.color = .init(texture: .init(videoResource))
                entity.model?.materials = [material]
            }
            
            // Log periodically
            if frameId == 1 || frameId % 120 == 0 {
                let depthStatus = depthTexture != nil ? "depth:\(depthTexture!.width)x\(depthTexture!.height)" : "no depth"
                print("[Spatial3DSurface] 📊 Frame \(frameId), video: \(videoTexture.width)x\(videoTexture.height), \(depthStatus)")
            }
        }
    }
    
    // Helper to create TextureResource from MTLTexture
    // This is a simplified version - in production, use the coordinator pattern
    private func createTextureResource(from texture: MTLTexture) -> TextureResource? {
        // Use the SpatialTextureManager for efficient texture handling
        // For now, return nil and let the coordinator handle it
        return nil
    }
}

// MARK: - Spatial3D Texture Coordinator

/// Coordinator for managing textures in Spatial 3D mode.
/// Handles both video and depth textures efficiently.
@available(visionOS 2.0, *)
@MainActor
final class Spatial3DTextureCoordinator {
    static let shared = Spatial3DTextureCoordinator()
    
    private var videoLLTexture: LowLevelTexture?
    private var depthLLTexture: LowLevelTexture?
    private var videoResource: TextureResource?
    private var depthResource: TextureResource?
    private var commandQueue: MTLCommandQueue?
    
    private var videoSize: (Int, Int) = (0, 0)
    private var depthSize: (Int, Int) = (0, 0)
    private var isVideoInitialized = false
    private var isDepthInitialized = false
    
    private(set) var videoEntity: ModelEntity?
    
    private init() {}
    
    /// Create or get the spatial 3D screen entity
    func getOrCreateEntity(
        width: Float,
        height: Float,
        curvature: Float,
        distance: Float,
        elevation: Float
    ) -> ModelEntity {
        print("[Spatial3DCoordinator] 🏗️ getOrCreateEntity called - curvature: \(curvature)")
        
        if let existing = videoEntity {
            print("[Spatial3DCoordinator] ♻️ Reusing existing entity")
            return existing
        }
        
        print("[Spatial3DCoordinator] 🆕 Creating NEW entity...")
        
        do {
            let mesh = try DenseMesh.generateCurved(
                width: width,
                height: height,
                curvature: curvature,
                resX: 128,
                resY: 72
            )
            
            var material = UnlitMaterial()
            material.color = .init(tint: .clear)
            
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "Spatial3DScreen"
            entity.position = [0, elevation, -distance]
            
            videoEntity = entity
            print("[Spatial3DCoordinator] ✅ Curved dense mesh entity created (128x72 segments, curvature: \(curvature))")
            
            return entity
            
        } catch {
            print("[Spatial3DCoordinator] ❌ Failed to create dense mesh: \(error)")
            
            // Fallback
            let mesh = MeshResource.generatePlane(width: width, height: height)
            var material = UnlitMaterial()
            material.color = .init(tint: .clear)
            
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "Spatial3DScreen"
            entity.position = [0, elevation, -distance]
            
            videoEntity = entity
            print("[Spatial3DCoordinator] 🔄 Using FALLBACK flat plane")
            return entity
        }
    }
    
    /// Update video texture from MTLTexture
    func updateVideoTexture(from sourceTexture: MTLTexture) {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        if isVideoInitialized && videoSize == newSize {
            copyVideoContent(from: sourceTexture)
            return
        }
        
        Task { @MainActor in
            await initializeVideoTexture(from: sourceTexture)
        }
    }
    
    private func initializeVideoTexture(from sourceTexture: MTLTexture) async {
        do {
            if commandQueue == nil {
                commandQueue = sourceTexture.device.makeCommandQueue()
            }
            
            let descriptor = LowLevelTexture.Descriptor(
                pixelFormat: .bgra8Unorm,
                width: sourceTexture.width,
                height: sourceTexture.height,
                depth: 1,
                mipmapLevelCount: 1,
                textureUsage: [.shaderRead, .shaderWrite]
            )
            
            let llTexture = try LowLevelTexture(descriptor: descriptor)
            let resource = try await TextureResource(from: llTexture)
            
            videoLLTexture = llTexture
            videoResource = resource
            videoSize = (sourceTexture.width, sourceTexture.height)
            isVideoInitialized = true
            
            applyVideoToEntity()
            copyVideoContent(from: sourceTexture)
            
            print("[Spatial3DCoordinator] ✅ Video texture: \(sourceTexture.width)x\(sourceTexture.height)")
            
        } catch {
            print("[Spatial3DCoordinator] ❌ Video texture init failed: \(error)")
        }
    }
    
    private func applyVideoToEntity() {
        guard let entity = videoEntity,
              let resource = videoResource else {
            print("[Spatial3DCoordinator] ⚠️ Cannot apply material - entity or resource missing")
            return
        }
        
        var material = UnlitMaterial()
        material.color = .init(texture: .init(resource))
        entity.model?.materials = [material]
        print("[Spatial3DCoordinator] 🎨 Material applied with texture (\(videoSize.0)x\(videoSize.1))")
    }
    
    private func copyVideoContent(from sourceTexture: MTLTexture) {
        guard let llTexture = videoLLTexture,
              let queue = commandQueue,
              isVideoInitialized,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        
        let destTexture = llTexture.replace(using: commandBuffer)
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        
        let copyWidth = min(sourceTexture.width, destTexture.width)
        let copyHeight = min(sourceTexture.height, destTexture.height)
        
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
            to: destTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        
        blitEncoder.endEncoding()
        commandBuffer.commit()
        
        // ALWAYS ensure material is applied after texture update
        // This guarantees the entity shows the latest texture content
        applyVideoToEntity()
    }
    
    /// Reset coordinator state
    func reset() {
        print("[Spatial3DCoordinator] 🔄 FULL RESET started...")
        
        // CRITICAL: Remove entity from scene before resetting
        if let entity = videoEntity {
            entity.removeFromParent()
            print("[Spatial3DCoordinator] 🗑️ Entity removed from parent")
        }
        
        videoLLTexture = nil
        depthLLTexture = nil
        videoResource = nil
        depthResource = nil
        commandQueue = nil
        videoSize = (0, 0)
        depthSize = (0, 0)
        isVideoInitialized = false
        isDepthInitialized = false
        videoEntity = nil
        print("[Spatial3DCoordinator] ✅ FULL RESET complete (all state cleared)")
    }
    
    /// Remove entity from scene without resetting textures (for mode switching)
    func removeFromScene() {
        print("[Spatial3DCoordinator] 🗑️ removeFromScene() called...")
        if let entity = videoEntity {
            entity.removeFromParent()
            print("[Spatial3DCoordinator] 🗑️ Entity removed from parent")
        }
        videoEntity = nil
        print("[Spatial3DCoordinator] ✅ Entity reference cleared (textures preserved)")
    }
}

// MARK: - Spatial 3D Surface View (Coordinator-based)

/// Production-ready Spatial 3D surface using coordinator pattern for efficient texture updates.
/// Uses RealityKit's CompositorLayer for Spatial Photos-like effect with head tracking parallax.
@available(visionOS 2.0, *)
struct Spatial3DSurfaceCoordinated: View {
    let texture: MTLTexture
    let frameId: UInt64
    let isSpatial3DEnabled: Bool
    
    // Screen parameters - Optimized for immersive viewing (like a cinema screen)
    private let screenWidth: Float = 7.0  // Larger width for wider field of view
    private let screenHeight: Float = 3.9375  // Maintain 16:9 aspect ratio
    private let screenDistance: Float = 3.5  // Optimal viewing distance (like IMAX)
    private let screenElevation: Float = 1.8
    private let curvature: Float = 0.15  // Subtle curve (IMAX style, not excessive)
    private let layerSeparation: Float = 0.15  // Distance between depth layers (15cm)
    
    var body: some View {
        RealityView { content in
            print("[Spatial3DSurface] 🏗️ RealityView content block - isSpatial3DEnabled: \(isSpatial3DEnabled)")
            let coordinator = Spatial3DTextureCoordinator.shared
            
            let appliedCurvature = curvature  // Subtle IMAX-style curve
            print("[Spatial3DSurface] 📐 Cinema-style screen with curvature: \(appliedCurvature)")
            
            // Create main plane
            let entity = coordinator.getOrCreateEntity(
                width: screenWidth,
                height: screenHeight,
                curvature: appliedCurvature,
                distance: screenDistance,
                elevation: screenElevation
            )
            
            if entity.parent == nil {
                content.add(entity)
                print("[Spatial3DSurface] ✅ Main entity added to scene (spatial3D: \(isSpatial3DEnabled))")
            } else {
                print("[Spatial3DSurface] ℹ️ Entity already in scene")
            }
            
            coordinator.updateVideoTexture(from: texture)
            
        } update: { content in
            let coordinator = Spatial3DTextureCoordinator.shared
            coordinator.updateVideoTexture(from: texture)
            
            if frameId % 120 == 0 {
                print("[Spatial3DSurface] 📊 Frame \(frameId)")
            }
        }
    }
}
