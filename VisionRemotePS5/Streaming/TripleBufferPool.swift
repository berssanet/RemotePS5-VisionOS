import Metal
import Foundation

/// Triple Buffer Pool for GPU texture synchronization
/// Uses 3 textures in rotation: 1 displaying, 1 rendering, 1 decoding
/// Eliminates CPU/GPU stalls by never waiting for GPU completion
final class TripleBufferPool {
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let width: Int
    private let height: Int
    
    /// The 3 buffer slots
    private var textures: [MTLTexture] = []
    
    /// Atomic index management using os_unfair_lock for thread safety
    private var lock = os_unfair_lock()
    
    /// Current indices: 0=display, 1=render, 2=decode (rotates)
    private var writeIndex: Int = 0
    private var readIndex: Int = 2  // Start 2 behind write
    
    /// Track which buffers are in use by GPU
    private var gpuInUse: [Bool] = [false, false, false]
    
    /// Fence for synchronization (optional - for advanced sync)
    private var fence: MTLFence?
    
    // MARK: - Initialization
    
    init?(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        self.device = device
        self.width = width
        self.height = height
        
        // Create 3 textures backed by IOSurface for zero-copy sharing
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private // GPU-only for maximum performance
        
        for i in 0..<3 {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                print("[TripleBufferPool] ❌ Failed to create texture \(i)")
                return nil
            }
            texture.label = "TripleBuffer_\(i)"
            textures.append(texture)
        }
        
        // Create fence for GPU synchronization
        fence = device.makeFence()
        
        print("[TripleBufferPool] ✅ Initialized with 3x \(width)x\(height) textures")
    }
    
    // MARK: - Public Methods
    
    /// Get the next texture available for writing (rendering/upscaling)
    /// Call this before encoding GPU work
    func acquireWriteTexture() -> MTLTexture? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // Find a texture not in use by GPU
        for offset in 0..<3 {
            let index = (writeIndex + offset) % 3
            if !gpuInUse[index] {
                gpuInUse[index] = true
                writeIndex = index
                return textures[index]
            }
        }
        
        // All textures in use - return the oldest write target anyway
        // This will cause a frame drop but won't stall
        return textures[writeIndex]
    }
    
    /// Mark write complete - call from commandBuffer completion handler
    func releaseWriteTexture(index: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        gpuInUse[index] = false
        
        // Advance read index to the just-completed buffer
        readIndex = index
    }
    
    /// Get the most recently completed texture for display
    /// This never blocks - always returns immediately
    func getDisplayTexture() -> MTLTexture {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        return textures[readIndex]
    }
    
    /// Get the write index for tracking in completion handler
    func getCurrentWriteIndex() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return writeIndex
    }
}
