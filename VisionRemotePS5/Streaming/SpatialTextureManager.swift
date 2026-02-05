//
//  SpatialTextureManager.swift
//  VisionRemotePS5
//
//  GPU memory manager for spatial rendering textures.
//  GOLDEN RULE: Never allocate a new TextureResource per frame.
//  Use LowLevelTexture.replace(using:) to update existing VRAM.
//

import RealityKit
import CoreVideo
import Metal

/// Manages GPU textures for spatial 3D rendering.
/// Reuses texture resources using LowLevelTexture pattern for maximum performance.
@available(visionOS 2.0, *)
@MainActor
final class SpatialTextureManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = SpatialTextureManager()
    
    // MARK: - Published Properties
    
    @Published private(set) var hasVideoTexture: Bool = false
    @Published private(set) var hasDepthTexture: Bool = false
    
    // MARK: - LowLevelTexture Resources (for efficient GPU updates)
    
    private var videoLLTexture: LowLevelTexture?
    private var depthLLTexture: LowLevelTexture?
    private var videoResource: TextureResource?
    private var depthResource: TextureResource?
    private var commandQueue: MTLCommandQueue?
    
    // Size tracking for reinitialization
    private var videoSize: (width: Int, height: Int) = (0, 0)
    private var depthSize: (width: Int, height: Int) = (0, 0)
    
    // Initialization state
    private var isVideoInitialized = false
    private var isVideoInitializing = false
    private var isDepthInitialized = false
    private var isDepthInitializing = false
    
    // Frame counters
    private var videoFrameCount: UInt64 = 0
    private var depthFrameCount: UInt64 = 0
    
    // MARK: - Initialization
    
    private init() {
        print("[SpatialTextureManager] Initialized")
    }
    
    // MARK: - Video Texture (60fps - High Priority)
    
    /// Updates the video texture from an MTLTexture.
    /// Fast path: uses LowLevelTexture.replace for GPU-side updates.
    /// - Parameter sourceTexture: Video frame texture (typically 1920x1080 or 3840x2160)
    /// - Returns: The updated TextureResource, or nil if not ready
    func updateVideo(from sourceTexture: MTLTexture) -> TextureResource? {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        // Check if we need to reinitialize
        if isVideoInitialized && videoSize == newSize {
            copyVideoContent(from: sourceTexture)
            return videoResource
        }
        
        // Start async initialization if not already in progress
        if !isVideoInitializing {
            isVideoInitializing = true
            Task { @MainActor in
                await initializeVideoTexture(from: sourceTexture)
            }
        }
        
        return nil
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
            isVideoInitializing = false
            hasVideoTexture = true
            
            print("[SpatialTextureManager] ✅ Video texture: \(sourceTexture.width)x\(sourceTexture.height)")
            
            copyVideoContent(from: sourceTexture)
            
        } catch {
            isVideoInitializing = false
            print("[SpatialTextureManager] ❌ Video init failed: \(error)")
        }
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
        
        videoFrameCount += 1
    }
    
    // MARK: - Depth Texture (~30fps - Lower Priority)
    
    /// Updates the depth texture from the AI-generated depth map.
    /// - Parameter sourceTexture: Depth map texture (typically grayscale)
    /// - Returns: The updated TextureResource, or nil if not ready
    func updateDepth(from sourceTexture: MTLTexture) -> TextureResource? {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        if isDepthInitialized && depthSize == newSize {
            copyDepthContent(from: sourceTexture)
            return depthResource
        }
        
        if !isDepthInitializing {
            isDepthInitializing = true
            Task { @MainActor in
                await initializeDepthTexture(from: sourceTexture)
            }
        }
        
        return nil
    }
    
    private func initializeDepthTexture(from sourceTexture: MTLTexture) async {
        do {
            if commandQueue == nil {
                guard let device = MTLCreateSystemDefaultDevice() else { return }
                commandQueue = device.makeCommandQueue()
            }
            
            // Use r8Unorm for grayscale depth
            let descriptor = LowLevelTexture.Descriptor(
                pixelFormat: .r8Unorm,
                width: sourceTexture.width,
                height: sourceTexture.height,
                depth: 1,
                mipmapLevelCount: 1,
                textureUsage: [.shaderRead, .shaderWrite]
            )
            
            let llTexture = try LowLevelTexture(descriptor: descriptor)
            let resource = try await TextureResource(from: llTexture)
            
            depthLLTexture = llTexture
            depthResource = resource
            depthSize = (sourceTexture.width, sourceTexture.height)
            isDepthInitialized = true
            isDepthInitializing = false
            hasDepthTexture = true
            
            print("[SpatialTextureManager] ✅ Depth texture: \(sourceTexture.width)x\(sourceTexture.height)")
            
            copyDepthContent(from: sourceTexture)
            
        } catch {
            isDepthInitializing = false
            print("[SpatialTextureManager] ❌ Depth init failed: \(error)")
        }
    }
    
    private func copyDepthContent(from sourceTexture: MTLTexture) {
        guard let llTexture = depthLLTexture,
              let queue = commandQueue,
              isDepthInitialized,
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
        
        depthFrameCount += 1
        
        // Log stats periodically
        if depthFrameCount % 30 == 0 {
            print("[SpatialTextureManager] 📊 Depth:\(depthFrameCount), Video:\(videoFrameCount)")
        }
    }
    
    // MARK: - Accessors
    
    /// Get the current video texture resource.
    var currentVideoResource: TextureResource? {
        return videoResource
    }
    
    /// Get the current depth texture resource.
    var currentDepthResource: TextureResource? {
        return depthResource
    }
    
    // MARK: - Cleanup
    
    /// Reset all textures and free GPU memory.
    func reset() {
        videoLLTexture = nil
        depthLLTexture = nil
        videoResource = nil
        depthResource = nil
        commandQueue = nil
        videoSize = (0, 0)
        depthSize = (0, 0)
        videoFrameCount = 0
        depthFrameCount = 0
        isVideoInitialized = false
        isVideoInitializing = false
        isDepthInitialized = false
        isDepthInitializing = false
        hasVideoTexture = false
        hasDepthTexture = false
        print("[SpatialTextureManager] 🔄 Reset complete")
    }
}
