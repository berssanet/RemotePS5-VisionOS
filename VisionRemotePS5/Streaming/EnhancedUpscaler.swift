//
//  EnhancedUpscaler.swift
//  VisionRemotePS5
//
//  Custom Metal shader upscaler with Lanczos resampling and
//  Contrast Adaptive Sharpening (CAS) for improved 4K quality.
//  Lower latency alternative to CoreML-based upscaling.
//

import Foundation
import Metal
import CoreVideo

/// Enhanced GPU upscaler using custom Metal shaders.
/// Applies Lanczos-3 resampling followed by CAS sharpening.
final class EnhancedUpscaler {
    
    // MARK: - Constants
    
    static let inputWidth = 1920
    static let inputHeight = 1080
    static let outputWidth = 3840
    static let outputHeight = 2160
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - Compute Pipelines
    
    private var lanczosUpscalePipeline: MTLComputePipelineState?
    private var casSharpenPipeline: MTLComputePipelineState?
    
    // MARK: - Textures
    
    private var intermediateTexture: MTLTexture?  // After Lanczos, before CAS
    private var outputTexture: MTLTexture?         // Final output
    
    // MARK: - Settings
    
    /// CAS sharpening strength (0.0 = off, 1.0 = maximum)
    var sharpenStrength: Float = 0.5
    
    /// Enable/disable CAS pass
    var enableSharpening: Bool = true
    
    // MARK: - Stats
    
    private var frameCount: UInt64 = 0
    
    // MARK: - Shader Source
    
    private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    
    // Lanczos-3 kernel function
    float lanczos3(float x) {
        if (x == 0.0) return 1.0;
        if (abs(x) >= 3.0) return 0.0;
        float pi = 3.14159265359;
        float pix = pi * x;
        return (sin(pix) / pix) * (sin(pix / 3.0) / (pix / 3.0));
    }
    
    // Lanczos-3 upscaling kernel
    kernel void lanczosUpscale(
        texture2d<float, access::sample> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        
        // Calculate source coordinates
        float2 scale = float2(input.get_width(), input.get_height()) / 
                       float2(output.get_width(), output.get_height());
        float2 srcPos = (float2(gid) + 0.5) * scale;
        float2 srcCenter = floor(srcPos - 0.5) + 0.5;
        
        float4 result = float4(0.0);
        float weightSum = 0.0;
        
        // 6x6 Lanczos-3 filter
        for (int y = -2; y <= 3; y++) {
            for (int x = -2; x <= 3; x++) {
                float2 samplePos = srcCenter + float2(x, y);
                float2 delta = srcPos - samplePos;
                
                float weight = lanczos3(delta.x) * lanczos3(delta.y);
                
                float2 uv = samplePos / float2(input.get_width(), input.get_height());
                float4 sample = input.sample(s, uv);
                
                result += sample * weight;
                weightSum += weight;
            }
        }
        
        result /= weightSum;
        output.write(result, gid);
    }
    
    // AMD FidelityFX CAS (Contrast Adaptive Sharpening) - simplified for mobile
    kernel void casSharpening(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant float& sharpness [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        
        // Get 3x3 neighborhood
        float4 a = input.read(uint2(gid.x - 1, gid.y - 1));
        float4 b = input.read(uint2(gid.x,     gid.y - 1));
        float4 c = input.read(uint2(gid.x + 1, gid.y - 1));
        float4 d = input.read(uint2(gid.x - 1, gid.y));
        float4 e = input.read(gid);  // Center
        float4 f = input.read(uint2(gid.x + 1, gid.y));
        float4 g = input.read(uint2(gid.x - 1, gid.y + 1));
        float4 h = input.read(uint2(gid.x,     gid.y + 1));
        float4 i = input.read(uint2(gid.x + 1, gid.y + 1));
        
        // Compute local contrast (simplified CAS)
        float4 minNeighbor = min(min(min(a, b), min(c, d)), min(min(f, g), min(h, i)));
        float4 maxNeighbor = max(max(max(a, b), max(c, d)), max(max(f, g), max(h, i)));
        
        // Sharpening weight based on local contrast
        float4 contrast = maxNeighbor - minNeighbor;
        float4 sharpenWeight = sharpness * (1.0 - contrast);
        sharpenWeight = clamp(sharpenWeight, 0.0, 1.0);
        
        // Compute sharpened value
        float4 blur = (a + b + c + d + f + g + h + i) / 8.0;
        float4 sharpened = e + (e - blur) * sharpenWeight;
        
        // Clamp to valid range
        sharpened = clamp(sharpened, 0.0, 1.0);
        
        output.write(sharpened, gid);
    }
    """
    
    // MARK: - Initialization
    
    init?() {
        DebugLog.print("[EnhancedUpscaler] 🚀 Starting initialization...")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            DebugLog.print("[EnhancedUpscaler] ❌ No Metal device available")
            return nil
        }
        
        guard let commandQueue = device.makeCommandQueue() else {
            DebugLog.print("[EnhancedUpscaler] ❌ Failed to create command queue")
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Create texture cache
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            DebugLog.print("[EnhancedUpscaler] ❌ Failed to create texture cache")
            return nil
        }
        self.textureCache = textureCache
        
        // Compile shaders
        guard compileShaders() else {
            return nil
        }
        
        // Create textures
        guard createTextures() else {
            return nil
        }
        
        DebugLog.print("[EnhancedUpscaler] ✅ Initialized")
        DebugLog.print("[EnhancedUpscaler]   Input: \(Self.inputWidth)x\(Self.inputHeight)")
        DebugLog.print("[EnhancedUpscaler]   Output: \(Self.outputWidth)x\(Self.outputHeight)")
        DebugLog.print("[EnhancedUpscaler]   Sharpening: \(enableSharpening ? "ON" : "OFF") (strength: \(sharpenStrength))")
    }
    
    private func compileShaders() -> Bool {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            
            guard let lanczosFunc = library.makeFunction(name: "lanczosUpscale"),
                  let casFunc = library.makeFunction(name: "casSharpening") else {
                DebugLog.print("[EnhancedUpscaler] ❌ Failed to find shader functions")
                return false
            }
            
            lanczosUpscalePipeline = try device.makeComputePipelineState(function: lanczosFunc)
            casSharpenPipeline = try device.makeComputePipelineState(function: casFunc)
            
            DebugLog.print("[EnhancedUpscaler] ✅ Shaders compiled")
            return true
        } catch {
            DebugLog.print("[EnhancedUpscaler] ❌ Shader compilation failed: \(error)")
            return false
        }
    }
    
    private func createTextures() -> Bool {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.outputWidth,
            height: Self.outputHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        
        guard let intermediate = device.makeTexture(descriptor: descriptor),
              let output = device.makeTexture(descriptor: descriptor) else {
            DebugLog.print("[EnhancedUpscaler] ❌ Failed to create textures")
            return false
        }
        
        intermediateTexture = intermediate
        outputTexture = output
        
        DebugLog.print("[EnhancedUpscaler] ✅ Textures created: \(Self.outputWidth)x\(Self.outputHeight)")
        return true
    }
    
    // MARK: - Upscaling
    
    func upscale(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache = textureCache,
              let lanczosUpscalePipeline = lanczosUpscalePipeline,
              let intermediateTexture = intermediateTexture,
              let outputTexture = outputTexture else {
            return nil
        }
        
        frameCount += 1
        
        // Get input dimensions
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create input texture from CVPixelBuffer
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTexture = cvTexture,
              let inputTexture = CVMetalTextureGetTexture(cvTexture) else {
            if frameCount <= 5 {
                DebugLog.print("[EnhancedUpscaler] ❌ Failed to create input texture")
            }
            return nil
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        // Pass 1: Lanczos upscaling
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(lanczosUpscalePipeline)
            encoder.setTexture(inputTexture, index: 0)
            
            // Output to intermediate if sharpening enabled, otherwise to final
            let lanczosOutput = enableSharpening ? intermediateTexture : outputTexture
            encoder.setTexture(lanczosOutput, index: 1)
            
            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadGroups = MTLSize(
                width: (Self.outputWidth + 15) / 16,
                height: (Self.outputHeight + 15) / 16,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }
        
        // Pass 2: CAS sharpening (optional)
        if enableSharpening, let casSharpenPipeline = casSharpenPipeline {
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(casSharpenPipeline)
                encoder.setTexture(intermediateTexture, index: 0)
                encoder.setTexture(outputTexture, index: 1)
                
                var sharpness = sharpenStrength
                encoder.setBytes(&sharpness, length: MemoryLayout<Float>.size, index: 0)
                
                let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
                let threadGroups = MTLSize(
                    width: (Self.outputWidth + 15) / 16,
                    height: (Self.outputHeight + 15) / 16,
                    depth: 1
                )
                encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }
        }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if frameCount == 1 {
            DebugLog.print("[EnhancedUpscaler] ✅ First frame processed!")
        }
        
        if frameCount % 60 == 0 {
            DebugLog.print("[EnhancedUpscaler] 📊 Frame \(frameCount) (Lanczos+CAS)")
        }
        
        return outputTexture
    }
}
