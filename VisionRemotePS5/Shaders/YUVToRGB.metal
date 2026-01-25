//
//  YUVToRGB.metal
//  VisionRemotePS5
//
//  High-performance compute shader for YUV to RGB conversion
//  Optimized for Apple Silicon GPU with SIMD instructions
//  Supports BT.709 (SDR) and BT.2020 (HDR) color spaces
//

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// MARK: - Color Space Matrices (Compile-time constants for GPU register allocation)
// ============================================================================

/// BT.709 YUV to RGB matrix (HDTV standard, SDR)
/// Optimized: Pre-computed coefficients avoid runtime division
constant float3x3 kBT709Matrix = float3x3(
    float3(1.0,       1.0,       1.0),
    float3(0.0,      -0.18732,   1.8556),
    float3(1.5748,   -0.46812,   0.0)
);

/// BT.2020 YUV to RGB matrix (UHDTV standard, HDR/Wide Gamut)
/// Used by PS5 when outputting HDR content
constant float3x3 kBT2020Matrix = float3x3(
    float3(1.0,       1.0,       1.0),
    float3(0.0,      -0.16455,   1.8814),
    float3(1.4746,   -0.57135,   0.0)
);

/// BT.601 YUV to RGB matrix (Legacy SDTV)
constant float3x3 kBT601Matrix = float3x3(
    float3(1.0,       1.0,       1.0),
    float3(0.0,      -0.34414,   1.772),
    float3(1.402,    -0.71414,   0.0)
);

// ============================================================================
// MARK: - Pre-computed Constants (Avoid ALU ops in hot path)
// ============================================================================

/// Video range conversion constants (16-235 → 0-1)
constant float kYOffset = 16.0 / 255.0;
constant float kYScale = 255.0 / 219.0;
constant float kUVOffset = 128.0 / 255.0;
constant float kUVScale = 255.0 / 224.0;

/// HDR 10-bit video range constants (64-940 → 0-1 for 10-bit normalized)
constant float kY10BitOffset = 64.0 / 1023.0;
constant float kY10BitScale = 1023.0 / 876.0;
constant float kUV10BitOffset = 512.0 / 1023.0;
constant float kUV10BitScale = 1023.0 / 896.0;

// ============================================================================
// MARK: - Color Space Enum (Passed via buffer)
// ============================================================================

/// Color space selection for runtime switching
enum ColorSpace : uint {
    ColorSpaceBT709 = 0,    // SDR (default)
    ColorSpaceBT2020 = 1,   // HDR Wide Gamut
    ColorSpaceBT601 = 2     // Legacy
};

/// Uniform buffer for runtime configuration
struct ConversionParams {
    uint colorSpace;        // ColorSpace enum
    uint isFullRange;       // 0 = video range, 1 = full range
    uint is10Bit;           // 0 = 8-bit, 1 = 10-bit HDR
    float hdrHeadroom;      // EDR headroom multiplier (1.0 for SDR, up to 4.0 for HDR)
};

// ============================================================================
// MARK: - Optimized Inline Functions
// ============================================================================

/// SIMD-optimized matrix selection (branchless where possible)
inline float3x3 selectColorMatrix(uint colorSpace) {
    // GPU-friendly: Use select() for branchless execution on uniform data
    // Note: For truly uniform data, branch prediction works well on Apple GPUs
    switch (colorSpace) {
        case ColorSpaceBT2020: return kBT2020Matrix;
        case ColorSpaceBT601:  return kBT601Matrix;
        default:               return kBT709Matrix;
    }
}

/// Video range YUV normalization (8-bit)
/// Uses fma() for fused multiply-add - single GPU instruction
inline float3 normalizeYUV_VideoRange(float y, float2 uv) {
    // fma(a, b, c) = a * b + c, but in a single instruction
    float yNorm = fma(y - kYOffset, kYScale, 0.0);
    float2 uvNorm = (uv - kUVOffset) * kUVScale;
    return float3(saturate(yNorm), uvNorm.x, uvNorm.y);
}

/// Video range YUV normalization (10-bit HDR)
inline float3 normalizeYUV_VideoRange10Bit(float y, float2 uv) {
    float yNorm = fma(y - kY10BitOffset, kY10BitScale, 0.0);
    float2 uvNorm = (uv - kUV10BitOffset) * kUV10BitScale;
    return float3(saturate(yNorm), uvNorm.x, uvNorm.y);
}

/// Full range YUV normalization
inline float3 normalizeYUV_FullRange(float y, float2 uv) {
    return float3(y, uv.x - 0.5, uv.y - 0.5);
}

/// Apply PQ EOTF (Perceptual Quantizer) for HDR10
/// Converts PQ-encoded values to linear light
inline float3 pqToLinear(float3 pq) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    
    float3 powPQ = pow(pq, float3(1.0 / m2));
    float3 num = max(powPQ - c1, float3(0.0));
    float3 den = c2 - c3 * powPQ;
    return pow(num / den, float3(1.0 / m1));
}

// ============================================================================
// MARK: - Main Kernels
// ============================================================================

/// Primary YUV to RGB kernel with dynamic color space support
/// Optimized for Apple Silicon with SIMD operations
kernel void yuvToRGBConvert(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    constant ConversionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Early bounds check with SIMD-friendly comparison
    const uint2 dims = uint2(yTexture.get_width(), yTexture.get_height());
    if (any(gid >= dims)) return;
    
    // Sample Y at full resolution
    const float y = yTexture.read(gid).r;
    
    // Sample UV at half resolution (4:2:0 chroma subsampling)
    const float2 uv = uvTexture.read(gid >> 1).rg;
    
    // Normalize YUV based on range
    float3 yuv;
    if (params.is10Bit) {
        yuv = normalizeYUV_VideoRange10Bit(y, uv);
    } else if (params.isFullRange) {
        yuv = normalizeYUV_FullRange(y, uv);
    } else {
        yuv = normalizeYUV_VideoRange(y, uv);
    }
    
    // Color matrix conversion (SIMD mat3*vec3)
    const float3x3 matrix = selectColorMatrix(params.colorSpace);
    float3 rgb = matrix * yuv;
    
    // HDR headroom scaling for EDR displays (Vision Pro supports up to 4x SDR)
    if (params.hdrHeadroom > 1.0) {
        rgb *= params.hdrHeadroom;
    }
    
    // Clamp to valid range (saturate = clamp(x, 0, 1))
    rgb = saturate(rgb);
    
    // Write BGRA output
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}

/// Simplified SDR-only kernel (faster when HDR not needed)
/// Uses compile-time constants for maximum performance
kernel void yuvToRGBConvertSDR(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uint2(yTexture.get_width(), yTexture.get_height()))) return;
    
    // Inline everything for maximum ILP (Instruction-Level Parallelism)
    const float y = yTexture.read(gid).r;
    const float2 uv = uvTexture.read(gid >> 1).rg;
    
    // BT.709 video range conversion - all constants, no branching
    const float yNorm = saturate((y - kYOffset) * kYScale);
    const float2 uvNorm = (uv - kUVOffset) * kUVScale;
    
    // Direct matrix multiply (compiler will optimize to SIMD)
    const float3 yuv = float3(yNorm, uvNorm.x, uvNorm.y);
    const float3 rgb = saturate(kBT709Matrix * yuv);
    
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}

/// HDR10 kernel with PQ EOTF and BT.2020 gamut
/// For Vision Pro's Micro-OLED HDR display
kernel void yuvToRGBConvertHDR10(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    constant float& hdrHeadroom [[buffer(0)]],  // EDR multiplier
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uint2(yTexture.get_width(), yTexture.get_height()))) return;
    
    const float y = yTexture.read(gid).r;
    const float2 uv = uvTexture.read(gid >> 1).rg;
    
    // 10-bit video range normalization
    const float3 yuv = normalizeYUV_VideoRange10Bit(y, uv);
    
    // BT.2020 color conversion
    float3 rgb = kBT2020Matrix * yuv;
    
    // PQ to linear for proper HDR tone reproduction
    rgb = pqToLinear(saturate(rgb));
    
    // Apply EDR headroom (Vision Pro supports up to 4x SDR luminance)
    rgb *= hdrHeadroom;
    
    // Note: No saturate here - EDR allows values > 1.0
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}

/// High-quality kernel with bilinear UV interpolation
/// Reduces chroma subsampling artifacts at edges
kernel void yuvToRGBConvertHQ(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::sample> uvTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    sampler uvSampler [[sampler(0)]],
    constant ConversionParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint2 dims = uint2(yTexture.get_width(), yTexture.get_height());
    if (any(gid >= dims)) return;
    
    const float y = yTexture.read(gid).r;
    
    // Bilinear interpolation for chroma (reduces blocking artifacts)
    const float2 uvCoord = (float2(gid) + 0.5) / float2(dims);
    const float2 uv = uvTexture.sample(uvSampler, uvCoord).rg;
    
    // Normalize based on range
    float3 yuv;
    if (params.is10Bit) {
        yuv = normalizeYUV_VideoRange10Bit(y, uv);
    } else if (params.isFullRange) {
        yuv = normalizeYUV_FullRange(y, uv);
    } else {
        yuv = normalizeYUV_VideoRange(y, uv);
    }
    
    const float3x3 matrix = selectColorMatrix(params.colorSpace);
    float3 rgb = matrix * yuv;
    
    if (params.hdrHeadroom > 1.0) {
        rgb = pqToLinear(saturate(rgb)) * params.hdrHeadroom;
    } else {
        rgb = saturate(rgb);
    }
    
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}

/// Full-range simple kernel (backward compatibility)
kernel void yuvToRGBConvertFullRange(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uint2(yTexture.get_width(), yTexture.get_height()))) return;
    
    const float y = yTexture.read(gid).r;
    const float2 uv = uvTexture.read(gid >> 1).rg - 0.5;
    
    const float3 yuv = float3(y, uv.x, uv.y);
    const float3 rgb = saturate(kBT709Matrix * yuv);
    
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}
