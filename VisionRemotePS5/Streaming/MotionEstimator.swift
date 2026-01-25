//
//  MotionEstimator.swift
//  VisionRemotePS5
//
//  Estimates motion vectors between consecutive video frames using Metal compute shaders.
//  Required for MetalFX Temporal Scaler to achieve high-quality upscaling.
//

import Foundation
import Metal

/// Motion vector estimator using block matching algorithm.
/// Outputs motion vectors in RG16Float format (direction from current to previous frame).
final class MotionEstimator {
    
    // MARK: - Constants
    
    /// Block size for motion estimation (16x16 is standard for video codecs)
    private static let blockSize = 16
    
    /// Search radius for block matching (pixels)
    private static let searchRadius = 16
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var computePipeline: MTLComputePipelineState?
    
    // MARK: - Motion Vector Texture
    
    /// Output motion vector texture (RG16Float: R=dx, G=dy)
    private(set) var motionVectorTexture: MTLTexture?
    
    /// Previous frame for comparison
    private var previousFrameTexture: MTLTexture?
    
    // MARK: - State
    
    private var isFirstFrame = true
    private var frameCount: UInt64 = 0
    
    // MARK: - Initialization
    
    init?(device: MTLDevice, width: Int, height: Int) {
        self.device = device
        
        guard let queue = device.makeCommandQueue() else {
            print("[MotionEstimator] ❌ Failed to create command queue")
            return nil
        }
        self.commandQueue = queue
        
        // Create motion vector texture (render resolution)
        let mvDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,  // MetalFX expects RG16Float
            width: width,
            height: height,
            mipmapped: false
        )
        mvDescriptor.usage = [.shaderRead, .shaderWrite]
        mvDescriptor.storageMode = .private
        
        guard let mvTexture = device.makeTexture(descriptor: mvDescriptor) else {
            print("[MotionEstimator] ❌ Failed to create motion vector texture")
            return nil
        }
        self.motionVectorTexture = mvTexture
        
        // Create previous frame storage texture
        let prevDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        prevDescriptor.usage = [.shaderRead, .shaderWrite]
        prevDescriptor.storageMode = .private
        
        guard let prevTexture = device.makeTexture(descriptor: prevDescriptor) else {
            print("[MotionEstimator] ❌ Failed to create previous frame texture")
            return nil
        }
        self.previousFrameTexture = prevTexture
        
        // Create compute pipeline
        guard setupComputePipeline() else {
            return nil
        }
        
        print("[MotionEstimator] ✅ Initialized (\(width)x\(height), block=\(Self.blockSize))")
    }
    
    // MARK: - Compute Pipeline Setup
    
    private func setupComputePipeline() -> Bool {
        // Metal shader for block matching motion estimation
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        // Block matching motion estimation kernel
        // Computes motion vectors by finding best matching block in previous frame
        kernel void estimateMotionVectors(
            texture2d<float, access::read> currentFrame [[texture(0)]],
            texture2d<float, access::read> previousFrame [[texture(1)]],
            texture2d<float, access::write> motionVectors [[texture(2)]],
            constant int& blockSize [[buffer(0)]],
            constant int& searchRadius [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            const int width = currentFrame.get_width();
            const int height = currentFrame.get_height();
            
            // Each thread handles one pixel
            if (gid.x >= uint(width) || gid.y >= uint(height)) return;
            
            // Sample current pixel color
            float4 currentColor = currentFrame.read(gid);
            
            // Find best matching position in previous frame
            float bestSAD = 1e10;  // Sum of Absolute Differences
            float2 bestMotion = float2(0.0);
            
            // Search window in previous frame
            for (int dy = -searchRadius; dy <= searchRadius; dy++) {
                for (int dx = -searchRadius; dx <= searchRadius; dx++) {
                    int2 searchPos = int2(gid) + int2(dx, dy);
                    
                    // Boundary check
                    if (searchPos.x < 0 || searchPos.x >= width ||
                        searchPos.y < 0 || searchPos.y >= height) {
                        continue;
                    }
                    
                    // Compute SAD for this offset
                    float4 prevColor = previousFrame.read(uint2(searchPos));
                    float sad = abs(currentColor.r - prevColor.r) +
                                abs(currentColor.g - prevColor.g) +
                                abs(currentColor.b - prevColor.b);
                    
                    if (sad < bestSAD) {
                        bestSAD = sad;
                        // Motion vector points from current to previous (MetalFX convention)
                        bestMotion = float2(-dx, -dy);
                    }
                }
            }
            
            // Write motion vector (RG16Float: R=horizontal, G=vertical)
            motionVectors.write(float4(bestMotion.x, bestMotion.y, 0, 0), gid);
        }
        
        // Simple copy kernel for storing previous frame
        kernel void copyTexture(
            texture2d<float, access::read> source [[texture(0)]],
            texture2d<float, access::write> dest [[texture(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
            dest.write(source.read(gid), gid);
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            
            guard let motionFunc = library.makeFunction(name: "estimateMotionVectors") else {
                print("[MotionEstimator] ❌ Failed to find estimateMotionVectors function")
                return false
            }
            
            computePipeline = try device.makeComputePipelineState(function: motionFunc)
            
            print("[MotionEstimator] ✅ Compute pipeline created")
            return true
        } catch {
            print("[MotionEstimator] ❌ Failed to create compute pipeline: \(error)")
            return false
        }
    }
    
    // MARK: - Motion Estimation
    
    /// Estimate motion vectors between current and previous frame
    /// - Parameters:
    ///   - currentFrame: Current frame texture (BGRA)
    ///   - commandBuffer: Command buffer to encode into
    /// - Returns: true if motion vectors are valid, false for first frame
    func estimateMotion(currentFrame: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipeline = computePipeline,
              let mvTexture = motionVectorTexture,
              let prevTexture = previousFrameTexture else {
            return false
        }
        
        frameCount += 1
        
        // First frame: no previous frame, so no valid motion vectors
        if isFirstFrame {
            // Just copy current frame to previous for next iteration
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(from: currentFrame,
                                sourceSlice: 0,
                                sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                sourceSize: MTLSize(width: currentFrame.width,
                                                   height: currentFrame.height,
                                                   depth: 1),
                                to: prevTexture,
                                destinationSlice: 0,
                                destinationLevel: 0,
                                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blitEncoder.endEncoding()
            }
            isFirstFrame = false
            print("[MotionEstimator] 📹 First frame - no motion vectors yet")
            return false
        }
        
        // Compute motion vectors
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setTexture(currentFrame, index: 0)
        computeEncoder.setTexture(prevTexture, index: 1)
        computeEncoder.setTexture(mvTexture, index: 2)
        
        var blockSize = Int32(Self.blockSize)
        var searchRadius = Int32(Self.searchRadius)
        computeEncoder.setBytes(&blockSize, length: MemoryLayout<Int32>.size, index: 0)
        computeEncoder.setBytes(&searchRadius, length: MemoryLayout<Int32>.size, index: 1)
        
        // Dispatch threads
        let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadGroups = MTLSize(
            width: (currentFrame.width + 7) / 8,
            height: (currentFrame.height + 7) / 8,
            depth: 1
        )
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        
        // Copy current frame to previous for next iteration
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(from: currentFrame,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(width: currentFrame.width,
                                               height: currentFrame.height,
                                               depth: 1),
                            to: prevTexture,
                            destinationSlice: 0,
                            destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blitEncoder.endEncoding()
        }
        
        if frameCount % 60 == 0 {
            print("[MotionEstimator] 📊 Frame \(frameCount) - motion vectors computed")
        }
        
        return true
    }
    
    /// Reset motion estimation state (call on scene cuts)
    func reset() {
        isFirstFrame = true
        print("[MotionEstimator] 🔄 Reset - next frame will skip motion estimation")
    }
}
