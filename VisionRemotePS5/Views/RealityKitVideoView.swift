//
//  RealityKitVideoView.swift
//  VisionRemotePS5
//
//  COMPLETE REWRITE: Uses a global coordinator to prevent SwiftUI from
//  recreating entities on every state change.
//

import SwiftUI
import RealityKit
import Metal

// MARK: - Video Texture Coordinator

/// Global coordinator that manages texture lifecycle independently of SwiftUI
@available(visionOS 2.0, *)
@MainActor
final class VideoTextureCoordinator {
    static let shared = VideoTextureCoordinator()
    
    private var lowLevelTexture: LowLevelTexture?
    private var textureResource: TextureResource?
    private var commandQueue: MTLCommandQueue?
    private var textureSize: (Int, Int) = (0, 0)
    private var isInitialized = false
    private var isInitializing = false
    
    // Entity managed by this coordinator - persists across view recreations
    private(set) var videoEntity: ModelEntity?
    private(set) var hasValidTexture = false
    
    private init() {}
    
    /// Create the video entity ONCE, return existing if already created
    func getOrCreateEntity(width: Float, height: Float) -> ModelEntity {
        if let existing = videoEntity {
            return existing
        }
        
        let mesh = MeshResource.generatePlane(width: width, height: height)
        let entity = ModelEntity(mesh: mesh)
        
        // Start with CLEAR material (invisible until texture ready)
        var material = UnlitMaterial()
        material.color = .init(tint: .clear)
        entity.model?.materials = [material]
        entity.position = [0, 0, 0]
        entity.name = "VideoPlane"
        
        videoEntity = entity
        
        print("[VideoTextureCoordinator] ✅ Entity created: \(width)x\(height)")
        
        return entity
    }
    
    /// Update texture from source - call every frame
    func updateTexture(from sourceTexture: MTLTexture) {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        // Fast path: already initialized with same size
        if isInitialized && textureSize == newSize {
            copyTextureContent(from: sourceTexture)
            return
        }
        
        // Need initialization
        guard !isInitializing else { return }
        isInitializing = true
        
        Task { @MainActor in
            await initializeTexture(from: sourceTexture)
        }
    }
    
    private func initializeTexture(from sourceTexture: MTLTexture) async {
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
            
            lowLevelTexture = llTexture
            textureResource = resource
            textureSize = (sourceTexture.width, sourceTexture.height)
            isInitialized = true
            isInitializing = false
            hasValidTexture = true
            
            print("[VideoTextureCoordinator] ✅ Texture: \(sourceTexture.width)x\(sourceTexture.height)")
            
            // Apply texture to entity
            applyToEntity()
            
            // Copy initial content
            copyTextureContent(from: sourceTexture)
            
        } catch {
            isInitializing = false
            print("[VideoTextureCoordinator] ❌ Failed: \(error)")
        }
    }
    
    func applyToEntity() {
        guard let entity = videoEntity, let resource = textureResource else { return }
        
        var material = UnlitMaterial()
        material.color = .init(texture: .init(resource))
        entity.model?.materials = [material]
    }
    
    private func copyTextureContent(from sourceTexture: MTLTexture) {
        guard let llTexture = lowLevelTexture,
              let queue = commandQueue,
              isInitialized else { return }
        
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        
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
    }
    
    /// Reset when streaming stops
    func reset() {
        lowLevelTexture = nil
        textureResource = nil
        commandQueue = nil
        textureSize = (0, 0)
        isInitialized = false
        isInitializing = false
        videoEntity = nil
        hasValidTexture = false
        print("[VideoTextureCoordinator] 🔄 Reset")
    }
}

// MARK: - RealityKit Video View

@available(visionOS 2.0, *)
struct RealityKitVideoView: View {
    let texture: MTLTexture?
    let frameId: UInt64
    
    var body: some View {
        GeometryReader { geometry in
            RealityView { content in
                // Calculate plane size
                let aspectRatio: Float = 16.0 / 9.0
                let viewWidth = Float(geometry.size.width)
                let viewHeight = Float(geometry.size.height)
                
                var planeWidth: Float
                var planeHeight: Float
                
                if viewWidth / viewHeight > aspectRatio {
                    planeHeight = viewHeight / 1000.0
                    planeWidth = planeHeight * aspectRatio
                } else {
                    planeWidth = viewWidth / 1000.0
                    planeHeight = planeWidth / aspectRatio
                }
                
                planeWidth = max(planeWidth, 0.4)
                planeHeight = max(planeHeight, 0.225)
                
                // Get or create entity from coordinator (SINGLETON)
                let coordinator = VideoTextureCoordinator.shared
                let entity = coordinator.getOrCreateEntity(width: planeWidth, height: planeHeight)
                
                // Only add if not already in a scene
                if entity.parent == nil {
                    content.add(entity)
                }
                
            } update: { content in
                // Update texture every frame - coordinator handles initialization
                if let tex = texture {
                    VideoTextureCoordinator.shared.updateTexture(from: tex)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(16/9, contentMode: .fit)
    }
}

#Preview {
    if #available(visionOS 2.0, *) {
        RealityKitVideoView(texture: nil, frameId: 0)
    } else {
        Text("Requires visionOS 2.0+")
    }
}
