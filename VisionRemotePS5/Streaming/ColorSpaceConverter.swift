//
//  ColorSpaceConverter.swift
//  VisionRemotePS5
//
//  Metal compute shader for YUV→RGB color space conversion.
//  Supports BT.709 (SDR) and BT.2020 (HDR) with PQ EOTF (ST.2084).
//  Designed for P010 (10-bit YUV 4:2:0) input from VideoToolbox.
//

import Foundation
import Metal
import CoreVideo

/// Color primaries for YUV→RGB conversion matrix selection
enum ColorPrimaries: Int {
    case bt709 = 0      // SDR (most games)
    case bt2020 = 1     // HDR (HDR-enabled games)
}

/// Transfer function for HDR tonemapping
enum TransferFunction {
    case sdr        // Standard gamma 2.2
    case pq         // ST.2084 (HDR10)
}

/// Metal-based color space converter for HDR video processing.
/// Converts P010 YUV 4:2:0 → Linear RGB with proper color matrices.
final class ColorSpaceConverter {
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - Compute Pipelines
    
    private var yuv420ToRGBPipeline: MTLComputePipelineState?
    private var bgraPassthroughPipeline: MTLComputePipelineState?
    
    // MARK: - Output Texture
    
    private var outputTexture: MTLTexture?
    private var outputWidth: Int = 1920
    private var outputHeight: Int = 1080
    
    // MARK: - Configuration
    
    /// Current color primaries (auto-detected or manually set)
    var colorPrimaries: ColorPrimaries = .bt709
    
    /// Current transfer function
    var transferFunction: TransferFunction = .sdr
    
    /// EDR headroom (1.0 = SDR, 2.0 = 2x HDR brightness)
    var edrHeadroom: Float = 2.0
    
    // MARK: - Stats
    
    private var frameCount: UInt64 = 0
    
    // MARK: - Shader Source
    
    private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    
    // BT.709 YUV→RGB matrix (SDR)
    constant float3x3 bt709Matrix = float3x3(
        float3(1.0,      1.0,       1.0),
        float3(0.0,     -0.21482,   2.12798),
        float3(1.28033, -0.38059,   0.0)
    );
    
    // BT.2020 YUV→RGB matrix (HDR)
    constant float3x3 bt2020Matrix = float3x3(
        float3(1.0,      1.0,       1.0),
        float3(0.0,     -0.11457,   2.07293),
        float3(1.67867, -0.65069,   0.0)
    );
    
    // PQ (ST.2084) EOTF for HDR
    // Converts PQ signal to linear light (normalized to 0-1 for ~1000 nits display)
    float3 pqEOTF(float3 pq) {
        const float m1 = 0.1593017578125;
        const float m2 = 78.84375;
        const float c1 = 0.8359375;
        const float c2 = 18.8515625;
        const float c3 = 18.6875;
        
        float3 pqPow = pow(pq, 1.0 / m2);
        float3 num = max(pqPow - c1, 0.0);
        float3 den = c2 - c3 * pqPow;
        float3 linear = pow(num / den, 1.0 / m1);
        
        // Normalize from 10000 nits reference to EDR range
        // Vision Pro supports ~1600 nits, so we scale accordingly
        return linear * 10.0;  // Returns 0-10 for EDR (10 = 1000 nits)
    }
    
    // ============================================================
    // v10.1 FIX: ACES Filmic Tone Mapping (replaces Reinhard)
    // ACES preserves saturation and HDR "pop" better than Reinhard
    // which tends to wash out bright colors on EDR displays.
    // Reference: https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
    // ============================================================
    
    // ACES input transform (RRT + ODT for sRGB)
    float3 ACESFilm(float3 x) {
        float a = 2.51;
        float b = 0.03;
        float c = 2.43;
        float d = 0.59;
        float e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }
    
    // Luminance-preserving ACES (balances saturation with highlight roll-off)
    float3 tonemapACES(float3 col, float exposure) {
        // Apply exposure
        col = col * exposure;
        
        // ACES Filmic curve
        float3 mapped = ACESFilm(col);
        
        return mapped;
    }
    
    // Legacy Reinhard (kept for fallback/comparison)
    float3 tonemapLuminance(float3 col, float maxBrightness) {
        // Calculate luminance using Rec.2020 coefficients
        float luma = 0.2627 * col.r + 0.6780 * col.g + 0.0593 * col.b;
        if (luma < 0.0001) return col;  // Avoid divide by zero for blacks
        
        // Apply Reinhard to luminance only
        float newLuma = luma / (1.0 + luma / maxBrightness);
        
        // Reconstruct color with compressed luminance, preserving saturation
        return col * (newLuma / luma);
    }
    
    // Convert P010 YUV420 to RGB
    // Y: 10-bit luma in texture0
    // CbCr: 10-bit chroma interleaved in texture1 (subsampled 2x)
    // v8.0: Bilinear chroma + luminance tone mapping
    kernel void yuv420ToRGB(
        texture2d<float, access::read> yTexture [[texture(0)]],
        texture2d<float, access::sample> cbcrTexture [[texture(1)]],  // v8.0: sample access
        texture2d<float, access::write> output [[texture(2)]],
        constant int& colorSpace [[buffer(0)]],      // 0=BT709, 1=BT2020
        constant int& transferFunc [[buffer(1)]],    // 0=SDR, 1=PQ
        constant float& edrHeadroom [[buffer(2)]],   // EDR multiplier (dynamic)
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        
        // Read Y (luma) - full resolution
        float y = yTexture.read(gid).r;
        
        // ============================================================
        // v8.0 FIX: Bilinear Chroma Sampling
        // Previous: uint2 chromaPos = gid / 2 (nearest-neighbor, pixelated)
        // New: Bilinear interpolation for smooth edges on colored text/UI
        // ============================================================
        constexpr sampler chromaSampler(filter::linear, coord::pixel);
        float2 chromaCoord = float2(gid) * 0.5 + 0.25;  // Center of 2x2 block
        float2 cbcr = cbcrTexture.sample(chromaSampler, chromaCoord).rg;
        
        // ============================================================
        // v7.0 FIX: Limited Range → Full Range Expansion
        // PS5 outputs video in Limited Range (Y: 16-235, CbCr: 16-240)
        // Apple expects Full Range (0-255) for true OLED black levels
        // ============================================================
        
        // Expand Y from Limited Range [16,235] to Full Range [0,1]
        y = (y - (16.0 / 255.0)) * (255.0 / (235.0 - 16.0));
        y = clamp(y, 0.0, 1.0);
        
        // Expand CbCr from Limited Range [16,240] to Full Range
        float cb = cbcr.x;
        float cr = cbcr.y;
        cb = (cb - (16.0 / 255.0)) * (255.0 / (240.0 - 16.0));
        cr = (cr - (16.0 / 255.0)) * (255.0 / (240.0 - 16.0));
        
        // Prepare YUV vector (Cb and Cr centered at 0.5, shift to -0.5..0.5)
        float3 yuv = float3(y, cb - 0.5, cr - 0.5);
        
        // Select color matrix based on color space
        float3x3 matrix = (colorSpace == 1) ? bt2020Matrix : bt709Matrix;
        
        // YUV → RGB conversion
        float3 rgb = matrix * yuv;
        
        // Apply transfer function (EOTF)
        if (transferFunc == 1) {
            // PQ/HDR10: Apply ST.2084 EOTF
            rgb = pqEOTF(rgb);
            
            // ============================================================
            // v10.1 FIX: ACES Filmic Tone Mapping (replaces Reinhard)
            // ACES preserves saturation and HDR "pop" on Vision Pro EDR
            // ============================================================
            float exposure = edrHeadroom / 5.0;  // Scale to EDR capability
            rgb = tonemapACES(rgb, exposure);
            
            // Scale to EDR headroom (ACES outputs 0-1, scale to display capability)
            rgb = rgb * edrHeadroom;
        } else {
            // SDR: Apply sRGB gamma (optional, Metal can handle this)
            rgb = clamp(rgb, 0.0, 1.0);
        }
        
        // Clamp to valid EDR range (0 to EDR headroom)
        rgb = clamp(rgb, 0.0, edrHeadroom);
        
        output.write(float4(rgb, 1.0), gid);
    }
    
    // Passthrough for BGRA input (SDR path, no conversion needed)
    kernel void bgraPassthrough(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        output.write(input.read(gid), gid);
    }
    """
    
    // MARK: - Initialization
    
    init?() {
        DebugLog.print("[ColorSpaceConverter] 🚀 Starting initialization...")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            DebugLog.print("[ColorSpaceConverter] ❌ No Metal device available")
            return nil
        }
        
        guard let commandQueue = device.makeCommandQueue() else {
            DebugLog.print("[ColorSpaceConverter] ❌ Failed to create command queue")
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Create texture cache
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            DebugLog.print("[ColorSpaceConverter] ❌ Failed to create texture cache: \(status)")
            return nil
        }
        self.textureCache = textureCache
        
        // Compile shaders
        guard compileShaders() else {
            return nil
        }
        
        DebugLog.print("[ColorSpaceConverter] ✅ Initialized")
        DebugLog.print("[ColorSpaceConverter]   Supported: BT.709 (SDR), BT.2020 + PQ (HDR10)")
    }
    
    private func compileShaders() -> Bool {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            
            guard let yuv420Func = library.makeFunction(name: "yuv420ToRGB"),
                  let passthroughFunc = library.makeFunction(name: "bgraPassthrough") else {
                DebugLog.print("[ColorSpaceConverter] ❌ Failed to find shader functions")
                return false
            }
            
            yuv420ToRGBPipeline = try device.makeComputePipelineState(function: yuv420Func)
            bgraPassthroughPipeline = try device.makeComputePipelineState(function: passthroughFunc)
            
            DebugLog.print("[ColorSpaceConverter] ✅ Shaders compiled")
            return true
        } catch {
            DebugLog.print("[ColorSpaceConverter] ❌ Shader compilation failed: \(error)")
            return false
        }
    }
    
    // MARK: - Output Texture Management
    
    private func ensureOutputTexture(width: Int, height: Int) -> MTLTexture? {
        if outputTexture != nil && outputWidth == width && outputHeight == height {
            return outputTexture
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,  // HDR-capable format
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            DebugLog.print("[ColorSpaceConverter] ❌ Failed to create output texture")
            return nil
        }
        
        outputTexture = texture
        outputWidth = width
        outputHeight = height
        DebugLog.print("[ColorSpaceConverter] ✅ Created output texture: \(width)x\(height) (RGBA16Float)")
        
        return texture
    }
    
    // MARK: - Conversion
    
    /// Convert CVPixelBuffer (P010 or BGRA) to linear RGB MTLTexture
    func convert(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard textureCache != nil else { return nil }
        
        frameCount += 1
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // Ensure output texture
        guard let outputTexture = ensureOutputTexture(width: width, height: height) else {
            return nil
        }
        
        // Log first frame details
        if frameCount == 1 {
            let formatName = formatDescription(format)
            DebugLog.print("[ColorSpaceConverter] 📹 First frame: \(width)x\(height), format=\(formatName)")
            DebugLog.print("[ColorSpaceConverter]   Color primaries: \(colorPrimaries == .bt2020 ? "BT.2020" : "BT.709")")
            DebugLog.print("[ColorSpaceConverter]   Transfer: \(transferFunction == .pq ? "PQ (HDR10)" : "SDR")")
        }
        
        // Route to appropriate converter based on pixel format
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            // P010: 10-bit YUV 4:2:0 (HDR path)
            return convertYUV420(pixelBuffer, to: outputTexture)
            
        case kCVPixelFormatType_32BGRA:
            // BGRA: 8-bit SDR (passthrough with optional conversion)
            return convertBGRA(pixelBuffer, to: outputTexture)
            
        default:
            if frameCount <= 5 {
                DebugLog.print("[ColorSpaceConverter] ⚠️ Unsupported format: \(format)")
            }
            return nil
        }
    }
    
    private func convertYUV420(_ pixelBuffer: CVPixelBuffer, to outputTexture: MTLTexture) -> MTLTexture? {
        guard let textureCache = textureCache,
              let pipeline = yuv420ToRGBPipeline else { return nil }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // P010 has 2 planes: Y (luma) and CbCr (chroma interleaved)
        // Plane 0: Y at full resolution
        // Plane 1: CbCr at half resolution (subsampled 4:2:0)
        
        var yTexture: CVMetalTexture?
        var cbcrTexture: CVMetalTexture?
        
        // Create Y texture (plane 0)
        var status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .r16Unorm,  // 16-bit for P010, only top 10 bits are significant
            width, height, 0, &yTexture
        )
        guard status == kCVReturnSuccess, let yTexture = yTexture,
              let yMtl = CVMetalTextureGetTexture(yTexture) else {
            if frameCount <= 5 {
                DebugLog.print("[ColorSpaceConverter] ❌ Failed to create Y texture: \(status)")
            }
            return nil
        }
        
        // Create CbCr texture (plane 1)
        status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .rg16Unorm,  // 2-component for Cb and Cr
            width / 2, height / 2, 1, &cbcrTexture
        )
        guard status == kCVReturnSuccess, let cbcrTexture = cbcrTexture,
              let cbcrMtl = CVMetalTextureGetTexture(cbcrTexture) else {
            if frameCount <= 5 {
                DebugLog.print("[ColorSpaceConverter] ❌ Failed to create CbCr texture: \(status)")
            }
            return nil
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Set pipeline and textures
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(yMtl, index: 0)
        encoder.setTexture(cbcrMtl, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        
        // Set uniforms
        var colorSpaceValue = colorPrimaries.rawValue
        var transferValue = transferFunction == .pq ? 1 : 0
        var headroom = edrHeadroom
        
        encoder.setBytes(&colorSpaceValue, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setBytes(&transferValue, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBytes(&headroom, length: MemoryLayout<Float>.size, index: 2)
        
        // Dispatch
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if frameCount % 60 == 0 {
            DebugLog.print("[ColorSpaceConverter] 📊 Frame \(frameCount) converted (P010→RGBA16F)")
        }
        
        return outputTexture
    }
    
    private func convertBGRA(_ pixelBuffer: CVPixelBuffer, to outputTexture: MTLTexture) -> MTLTexture? {
        guard let textureCache = textureCache,
              let pipeline = bgraPassthroughPipeline else { return nil }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create BGRA texture
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvTexture,
              let inputMtl = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputMtl, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if frameCount % 60 == 0 {
            DebugLog.print("[ColorSpaceConverter] 📊 Frame \(frameCount) passthrough (BGRA→RGBA16F)")
        }
        
        return outputTexture
    }
    
    // MARK: - Utilities
    
    private func formatDescription(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA:
            return "BGRA 8-bit"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return "P010 (Video Range)"
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return "P010 (Full Range)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "NV12 8-bit (Video Range)"
        default:
            return "Unknown(\(format))"
        }
    }
}
