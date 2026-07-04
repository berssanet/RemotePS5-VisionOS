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
    
    /// Fallback texture for manual copy when CVMetalTexture fails
    private var fallbackTexture: MTLTexture?
    
    // MARK: - MTLEvent Synchronization
    
    /// Shared event for GPU-GPU synchronization with upstream pipeline
    private var syncEvent: MTLSharedEvent?
    
    /// Last event value waited for
    private var lastEventValue: UInt64 = 0
    
    // MARK: - HDR Configuration
    
    /// Pixel format for HDR Extended Range (supports EDR > 1.0)
    static let hdrPixelFormat: MTLPixelFormat = .bgra10_xr
    
    /// Pixel format for high-precision HDR (maximum fidelity)
    static let hdrHighPrecisionFormat: MTLPixelFormat = .rgba16Float
    
    /// Whether HDR mode is enabled
    var hdrEnabled: Bool = true
    
    /// Use high-precision format (rgba16Float) for maximum HDR fidelity
    var useHighPrecision: Bool = false
    
    /// Current EDR headroom (1.0 = SDR, 2.0-4.0 = typical HDR)
    /// Updated based on content metadata from MetalFXUpscaler
    var currentEDRHeadroom: Float = 2.0
    
    /// Get the appropriate pixel format based on HDR mode and precision
    var currentPixelFormat: MTLPixelFormat {
        guard hdrEnabled else { return .bgra8Unorm }
        return useHighPrecision ? Self.hdrHighPrecisionFormat : Self.hdrPixelFormat
    }
    
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
            DebugLog.print("[VideoTextureCoordinator] ❌ No Metal device")
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
            DebugLog.print("[VideoTextureCoordinator] ✅ Metal initialized (HDR: bgra10_xr, MTLEvent enabled)")
        } else {
            DebugLog.print("[VideoTextureCoordinator] ⚠️ Failed to create texture cache: \(status)")
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
        
        DebugLog.print("[VideoTextureCoordinator] ✅ Entity created: \(width)x\(height)")
        
        return entity
    }
    
    /// Update texture directly from CVPixelBuffer.
    /// **Thread-Safe**: Can be called from any thread (decoder callback).
    /// This is the HOT PATH for the video pipeline.
    func updateTexture(from pixelBuffer: CVPixelBuffer) {
        guard let textureCache = textureCache,
              let device = device else {
            DebugLog.print("[VideoTextureCoordinator] ❌ No texture cache or device")
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // Log first frame for debugging
        lock.lock()
        let shouldLog = !isInitialized
        lock.unlock()
        
        if shouldLog {
            let formatStr: String
            switch pixelFormat {
            case kCVPixelFormatType_32BGRA: formatStr = "BGRA"
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: formatStr = "YUV420 (Video)"
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: formatStr = "YUV420 (Full)"
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: formatStr = "P010 (HDR)"
            default: formatStr = String(format: "0x%X", pixelFormat)
            }
            
            // Check IOSurface backing - CRITICAL for Metal compatibility
            let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)
            let hasIOSurface = ioSurface != nil
            DebugLog.print("[VideoTextureCoordinator] 📥 First frame: \(width)x\(height) format=\(formatStr) IOSurface=\(hasIOSurface ? "YES" : "NO")")
        }
        
        // CRITICAL: CVMetalTextureCacheCreateTextureFromImage ONLY supports bgra8Unorm for BGRA buffers!
        let metalFormat: MTLPixelFormat
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            metalFormat = .bgra8Unorm
        default:
            DebugLog.print("[VideoTextureCoordinator] ⚠️ Unsupported format, expected BGRA")
            return
        }
        
        // Try CVMetalTexture path first
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            metalFormat,
            width,
            height,
            0,
            &cvTexture
        )
        
        if status == kCVReturnSuccess,
           let cvTexture = cvTexture,
           let metalTexture = CVMetalTextureGetTexture(cvTexture) {
            // Fast path: Zero-copy Metal texture
            if shouldLog {
                DebugLog.print("[VideoTextureCoordinator] ✅ Zero-copy CVMetalTexture created")
            }
            updateTexture(from: metalTexture)
            return
        }
        
        // Fallback: Manual copy to Metal texture (slower but always works)
        if shouldLog {
            DebugLog.print("[VideoTextureCoordinator] ⚠️ CVMetalTexture failed (\(status)), using manual copy fallback")
        }
        
        // Lock pixel buffer for CPU access
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            if shouldLog {
                DebugLog.print("[VideoTextureCoordinator] ❌ Failed to get pixel buffer base address")
            }
            return
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Create Metal texture if needed
        lock.lock()
        if fallbackTexture == nil || fallbackTexture!.width != width || fallbackTexture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            fallbackTexture = device.makeTexture(descriptor: descriptor)
            if shouldLog {
                DebugLog.print("[VideoTextureCoordinator] 📦 Created fallback texture: \(width)x\(height)")
            }
        }
        lock.unlock()
        
        guard let texture = fallbackTexture else {
            return
        }
        
        // Copy pixel data to Metal texture
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )
        
        // Forward to texture update pipeline
        updateTexture(from: texture)
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
    /// Counter for debug logging
    private static var updateCounter: Int = 0
    
    func updateTexture(from sourceTexture: MTLTexture) {
        let newSize = (sourceTexture.width, sourceTexture.height)
        Self.updateCounter += 1
        
        // Thread-safe check for initialization state
        lock.lock()
        let needsInit = !isInitialized || textureSize != newSize
        let alreadyInitializing = isInitializing
        let currentlyInitialized = isInitialized
        if needsInit && !alreadyInitializing {
            isInitializing = true
        }
        lock.unlock()
        
        // Debug log every 60 frames
        if Self.updateCounter % 60 == 0 {
            DebugLog.print("[VideoTextureCoordinator] 📊 Frame \(Self.updateCounter): needsInit=\(needsInit), initialized=\(currentlyInitialized), initializing=\(alreadyInitializing)")
        }
        
        if !needsInit {
            // Fast path: already initialized with same size
            copyTextureContent(from: sourceTexture, commandBuffer: nil)
            return
        }
        
        if alreadyInitializing {
            // Already initializing, skip this frame
            if Self.updateCounter <= 10 {
                DebugLog.print("[VideoTextureCoordinator] ⏳ Frame \(Self.updateCounter): Skipping (already initializing)")
            }
            return
        }
        
        DebugLog.print("[VideoTextureCoordinator] 🔧 Frame \(Self.updateCounter): Starting initialization")
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
            // CRITICAL: Use the SAME pixel format as the source texture!
            // The source comes from CVMetalTexture which is always bgra8Unorm
            // Using a different format (like bgra10_xr) would cause blit copy failures
            let pixelFormat: MTLPixelFormat = sourceTexture.pixelFormat
            
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
            
            lock.withLock {
                lowLevelTexture = llTexture
                textureResource = resource
                textureSize = (sourceTexture.width, sourceTexture.height)
                isInitialized = true
                isInitializing = false
            }
            
            hasValidTexture = true
            
            let formatName = hdrEnabled ? "bgra10_xr (HDR/EDR)" : "bgra8Unorm (SDR)"
            DebugLog.print("[VideoTextureCoordinator] ✅ Texture: \(sourceTexture.width)x\(sourceTexture.height) [\(formatName)]")
            
            // Apply texture to entity with EDR support
            applyToEntity()
            
            // Copy initial content
            copyTextureContent(from: sourceTexture, commandBuffer: nil)
            
        } catch {
            lock.withLock {
                isInitializing = false
            }
            DebugLog.print("[VideoTextureCoordinator] ❌ Failed: \(error)")
        }
    }
    
    @MainActor
    func applyToEntity() {
        guard let entity = videoEntity, let resource = textureResource else { return }
        
        // Create UnlitMaterial configured for EDR/HDR
        // UnlitMaterial supports values > 1.0 when using Extended Range textures
        var material = UnlitMaterial()
        
        if hdrEnabled {
            // HDR/EDR Configuration:
            // 1. Use white tint to preserve HDR values (no color multiplication)
            // 2. Set full opacity to ensure no alpha blending reduces brightness
            // 3. The bgra10_xr texture format allows values > 1.0 (Extended Range)
            //
            // Vision Pro Micro-OLED can display up to ~4x SDR white (EDR headroom 4.0)
            // PS5 HDR content typically uses BT.2020 + PQ with peak ~1000-4000 nits
            
            // Configure for maximum HDR fidelity
            material.color = .init(
                tint: .white.withAlphaComponent(1.0),  // Preserve HDR values
                texture: .init(resource)
            )
            
            // Blending mode: Use opaque for EDR to avoid alpha premultiplication
            // reducing peak brightness. Values > 1.0 will "bloom" on HDR display.
            material.blending = .opaque
            
            DebugLog.print("[VideoTextureCoordinator] 🎨 HDR Material applied (EDR-optimized, opaque blending)")
        } else {
            // SDR Configuration: Standard texture application
            material.color = .init(texture: .init(resource))
            DebugLog.print("[VideoTextureCoordinator] 🎨 SDR Material applied")
        }
        
        entity.model?.materials = [material]
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
    
    private static var copyCounter: Int = 0
    
    @MainActor
    private func performTextureCopy(from sourceTexture: MTLTexture, using existingBuffer: MTLCommandBuffer?) {
        guard let llTexture = lowLevelTexture,
              let queue = commandQueue else {
            DebugLog.print("[VideoTextureCoordinator] ❌ performTextureCopy: Missing llTexture or queue")
            return
        }
        
        Self.copyCounter += 1
        
        // Use existing buffer or create new one
        let commandBuffer: MTLCommandBuffer
        if let existing = existingBuffer {
            commandBuffer = existing
        } else {
            guard let newBuffer = queue.makeCommandBuffer() else {
                DebugLog.print("[VideoTextureCoordinator] ❌ performTextureCopy: Failed to create command buffer")
                return
            }
            commandBuffer = newBuffer
        }
        
        let destTexture = llTexture.replace(using: commandBuffer)
        
        // CRITICAL: Check format compatibility before blit
        if sourceTexture.pixelFormat != destTexture.pixelFormat {
            if Self.copyCounter <= 5 || Self.copyCounter % 60 == 0 {
                DebugLog.print("[VideoTextureCoordinator] ⚠️ Format mismatch: source=\(sourceTexture.pixelFormat.rawValue), dest=\(destTexture.pixelFormat.rawValue)")
            }
        }
        
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            DebugLog.print("[VideoTextureCoordinator] ❌ performTextureCopy: Failed to create blit encoder")
            return
        }
        
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
        
        // Log first few copies
        if Self.copyCounter <= 5 {
            DebugLog.print("[VideoTextureCoordinator] 📦 Copy #\(Self.copyCounter): \(copyWidth)x\(copyHeight)")
        } else if Self.copyCounter % 60 == 0 {
            DebugLog.print("[VideoTextureCoordinator] 📦 Copy #\(Self.copyCounter): \(copyWidth)x\(copyHeight) (periodic)")
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
        DebugLog.print("[VideoTextureCoordinator] 🔄 Reset")
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
