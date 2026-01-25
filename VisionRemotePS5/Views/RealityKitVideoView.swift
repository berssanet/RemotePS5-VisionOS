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

// MARK: - Video Texture Coordinator

/// Global coordinator that manages texture lifecycle independently of SwiftUI.
///
/// This coordinator enables a high-performance rendering pipeline:
/// - **Decoder Thread**: CVPixelBuffer from VideoToolbox
/// - **Metal Pipeline**: Texture conversion and upscaling
/// - **RealityKit**: Direct texture update via LowLevelTexture
///
/// The `updateTexture(from: CVPixelBuffer)` method is THREAD-SAFE and can be called
/// directly from the VideoToolbox decoder callback without dispatching to MainActor.
///
/// **HDR Support**: Uses `.bgra10_xr` (Extended Range) format for EDR values > 1.0
@available(visionOS 2.0, *)
final class VideoTextureCoordinator: @unchecked Sendable {
    static let shared = VideoTextureCoordinator()
    
    // MARK: - Metal Resources
    
    private var device: MTLDevice?
    private var textureCache: CVMetalTextureCache?
    private var lowLevelTexture: LowLevelTexture?
    private var textureResource: TextureResource?
    private var commandQueue: MTLCommandQueue?
    private var textureSize: (Int, Int) = (0, 0)
    
    // MARK: - MTLEvent Synchronization
    
    /// Shared event for GPU-GPU synchronization with upstream pipeline
    private var syncEvent: MTLSharedEvent?
    
    /// Last event value waited for
    private var lastEventValue: UInt64 = 0
    
    // MARK: - HDR Configuration
    
    /// Pixel format for HDR Extended Range (supports EDR > 1.0)
    static let hdrPixelFormat: MTLPixelFormat = .bgra10_xr
    
    /// Whether HDR mode is enabled
    var hdrEnabled: Bool = true
    
    // MARK: - State
    
    private var isInitialized = false
    private var isInitializing = false
    private let lock = NSLock()
    
    // MARK: - Entity (MainActor only)
    
    @MainActor private(set) var videoEntity: ModelEntity?
    @MainActor private(set) var hasValidTexture = false
    
    // MARK: - Initialization
    
    private init() {
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[VideoTextureCoordinator] ❌ No Metal device")
            return
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // Create shared event for GPU sync
        self.syncEvent = device.makeSharedEvent()
        
        // Create CVMetalTextureCache for zero-copy pixel buffer -> texture conversion
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        
        if status == kCVReturnSuccess, let cache = cache {
            self.textureCache = cache
            print("[VideoTextureCoordinator] ✅ Metal initialized (HDR: bgra10_xr, MTLEvent enabled)")
        } else {
            print("[VideoTextureCoordinator] ⚠️ Failed to create texture cache: \(status)")
        }
    }
    
    // MARK: - Entity Management (MainActor)
    
    /// Create the video entity ONCE, return existing if already created
    @MainActor
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
    
    // MARK: - High-Performance Frame Update (Thread-Safe)
    
    /// Update texture directly from CVPixelBuffer.
    /// **Thread-Safe**: Can be called from any thread (decoder callback).
    /// This is the HOT PATH for the video pipeline.
    func updateTexture(from pixelBuffer: CVPixelBuffer) {
        guard let textureCache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create MTLTexture from CVPixelBuffer (zero-copy via IOSurface)
        // Use bgra10_xr for HDR Extended Range support
        let pixelFormat: MTLPixelFormat = hdrEnabled ? Self.hdrPixelFormat : .bgra8Unorm
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }
        
        // Forward to existing MTLTexture-based pipeline
        updateTexture(from: metalTexture)
    }
    
    /// Update texture with MTLEvent synchronization (waits for upstream GPU work)
    func updateTexture(from pixelBuffer: CVPixelBuffer, waitForEvent event: MTLSharedEvent, value: UInt64) {
        guard let textureCache = textureCache,
              let queue = commandQueue else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let pixelFormat: MTLPixelFormat = hdrEnabled ? Self.hdrPixelFormat : .bgra8Unorm
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }
        
        // Create command buffer that waits for upstream event
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        
        // Wait for upstream GPU work (e.g., MetalFX upscaling)
        commandBuffer.encodeWaitForEvent(event, value: value)
        lastEventValue = value
        
        // Forward texture update
        updateTexture(from: metalTexture, commandBuffer: commandBuffer)
    }
    
    /// Update texture from MTLTexture source
    func updateTexture(from sourceTexture: MTLTexture) {
        let newSize = (sourceTexture.width, sourceTexture.height)
        
        // Thread-safe check for initialization state
        lock.lock()
        let needsInit = !isInitialized || textureSize != newSize
        let alreadyInitializing = isInitializing
        if needsInit && !alreadyInitializing {
            isInitializing = true
        }
        lock.unlock()
        
        if !needsInit {
            // Fast path: already initialized with same size
            copyTextureContent(from: sourceTexture, commandBuffer: nil)
            return
        }
        
        if alreadyInitializing {
            // Already initializing, skip this frame
            return
        }
        
        // Need initialization - dispatch to MainActor
        Task { @MainActor in
            await initializeTexture(from: sourceTexture)
        }
    }
    
    /// Update with existing command buffer (for MTLEvent chaining)
    func updateTexture(from sourceTexture: MTLTexture, commandBuffer: MTLCommandBuffer?) {
        lock.lock()
        let initialized = isInitialized
        lock.unlock()
        
        if initialized {
            copyTextureContent(from: sourceTexture, commandBuffer: commandBuffer)
        } else {
            // Initialize first
            Task { @MainActor in
                await initializeTexture(from: sourceTexture)
            }
        }
    }
    
    @MainActor
    private func initializeTexture(from sourceTexture: MTLTexture) async {
        do {
            // Use bgra10_xr for HDR Extended Range (supports EDR values > 1.0)
            let pixelFormat: MTLPixelFormat = hdrEnabled ? Self.hdrPixelFormat : .bgra8Unorm
            
            let descriptor = LowLevelTexture.Descriptor(
                pixelFormat: pixelFormat,
                width: sourceTexture.width,
                height: sourceTexture.height,
                depth: 1,
                mipmapLevelCount: 1,
                textureUsage: [.shaderRead, .shaderWrite]
            )
            
            let llTexture = try LowLevelTexture(descriptor: descriptor)
            let resource = try await TextureResource(from: llTexture)
            
            lock.lock()
            lowLevelTexture = llTexture
            textureResource = resource
            textureSize = (sourceTexture.width, sourceTexture.height)
            isInitialized = true
            isInitializing = false
            lock.unlock()
            
            hasValidTexture = true
            
            let formatName = hdrEnabled ? "bgra10_xr (HDR/EDR)" : "bgra8Unorm (SDR)"
            print("[VideoTextureCoordinator] ✅ Texture: \(sourceTexture.width)x\(sourceTexture.height) [\(formatName)]")
            
            // Apply texture to entity with EDR support
            applyToEntity()
            
            // Copy initial content
            copyTextureContent(from: sourceTexture, commandBuffer: nil)
            
        } catch {
            lock.lock()
            isInitializing = false
            lock.unlock()
            print("[VideoTextureCoordinator] ❌ Failed: \(error)")
        }
    }
    
    @MainActor
    func applyToEntity() {
        guard let entity = videoEntity, let resource = textureResource else { return }
        
        // Create UnlitMaterial configured for EDR/HDR
        // UnlitMaterial supports values > 1.0 when using Extended Range textures
        var material = UnlitMaterial()
        
        // Apply texture with proper color handling
        material.color = .init(texture: .init(resource))
        
        // Note: RealityKit UnlitMaterial automatically handles Extended Range
        // when the input texture is in a compatible format (bgra10_xr)
        // Values > 1.0 will be rendered as HDR on capable displays
        
        entity.model?.materials = [material]
        
        print("[VideoTextureCoordinator] 🎨 Material applied (EDR enabled: \(hdrEnabled))")
    }
    
    private func copyTextureContent(from sourceTexture: MTLTexture, commandBuffer existingBuffer: MTLCommandBuffer?) {
        lock.lock()
        let initialized = isInitialized
        lock.unlock()
        
        guard initialized else { return }
        
        // If we have an existing command buffer (from MTLEvent chain), use it
        // Otherwise dispatch to MainActor for a new command buffer
        if let existingBuffer = existingBuffer {
            Task { @MainActor in
                self.performTextureCopy(from: sourceTexture, using: existingBuffer)
            }
        } else {
            Task { @MainActor in
                self.performTextureCopy(from: sourceTexture, using: nil)
            }
        }
    }
    
    @MainActor
    private func performTextureCopy(from sourceTexture: MTLTexture, using existingBuffer: MTLCommandBuffer?) {
        guard let llTexture = lowLevelTexture,
              let queue = commandQueue else { return }
        
        // Use existing buffer or create new one
        let commandBuffer: MTLCommandBuffer
        if let existing = existingBuffer {
            commandBuffer = existing
        } else {
            guard let newBuffer = queue.makeCommandBuffer() else { return }
            commandBuffer = newBuffer
        }
        
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
        
        // Only commit if we created the buffer
        if existingBuffer == nil {
            commandBuffer.commit()
        }
    }
    
    /// Reset when streaming stops
    @MainActor
    func reset() {
        lock.lock()
        lowLevelTexture = nil
        textureResource = nil
        textureSize = (0, 0)
        isInitialized = false
        isInitializing = false
        lock.unlock()
        
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
