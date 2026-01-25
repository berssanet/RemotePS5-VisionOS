//
//  YUVToRGB.metal
//  VisionRemotePS5
//
//  Compute shader for converting YUV (NV12/Bi-Planar) to RGB
//  Used before MetalFX Spatial Scaler which requires RGB input
//

#include <metal_stdlib>
using namespace metal;

// BT.709 YUV to RGB conversion matrix (HDTV standard)
// This matches the color space typically used by PS5/H.265 streams
constant float3x3 yuvToRGBMatrix = float3x3(
    float3(1.0,      1.0,      1.0),
    float3(0.0,     -0.18732, 1.8556),
    float3(1.5748,  -0.46812,  0.0)
);

// Alternative: BT.601 matrix for legacy content
constant float3x3 yuvToRGBMatrix601 = float3x3(
    float3(1.0,      1.0,      1.0),
    float3(0.0,     -0.34414,  1.772),
    float3(1.402,   -0.71414,  0.0)
);

/// Main YUV to RGB conversion kernel
/// Reads from bi-planar NV12: Y (luminance) and CbCr (chrominance)
/// Outputs BGRA8 suitable for MetalFX Spatial Scaler
kernel void yuvToRGBConvert(
    texture2d<float, access::read> yTexture [[texture(0)]],      // Luminance (Y)
    texture2d<float, access::read> uvTexture [[texture(1)]],     // Chrominance (CbCr)
    texture2d<float, access::write> rgbTexture [[texture(2)]],   // Output BGRA
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 ySize = uint2(yTexture.get_width(), yTexture.get_height());
    
    // Bounds check
    if (gid.x >= ySize.x || gid.y >= ySize.y) {
        return;
    }
    
    // Sample Y (full resolution)
    float y = yTexture.read(gid).r;
    
    // Sample UV (half resolution, so divide coordinates by 2)
    uint2 uvCoord = gid / 2;
    float2 uv = uvTexture.read(uvCoord).rg;
    
    // Convert from video range [16/255, 235/255] to full range [0, 1]
    // Y: (Y - 16/255) * (255/219)
    // UV: (UV - 128/255) * (255/224)
    float yNorm = (y - 16.0/255.0) * (255.0/219.0);
    float2 uvNorm = (uv - 128.0/255.0) * (255.0/224.0);
    
    // Clamp Y to valid range
    yNorm = clamp(yNorm, 0.0, 1.0);
    
    // Build YUV vector: Y, Cb, Cr -> Y, U, V
    float3 yuv = float3(yNorm, uvNorm.x, uvNorm.y);
    
    // BT.709 conversion
    float3 rgb = yuvToRGBMatrix * yuv;
    
    // Clamp to valid range
    rgb = clamp(rgb, float3(0.0), float3(1.0));
    
    // Write as BGRA (for bgra8Unorm format)
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}

/// Alternative kernel for full-range YUV (used by some codecs)
kernel void yuvToRGBConvertFullRange(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> uvTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 ySize = uint2(yTexture.get_width(), yTexture.get_height());
    
    if (gid.x >= ySize.x || gid.y >= ySize.y) {
        return;
    }
    
    float y = yTexture.read(gid).r;
    uint2 uvCoord = gid / 2;
    float2 uv = uvTexture.read(uvCoord).rg;
    
    // Full range: no scaling needed for Y, just offset UV
    float2 uvNorm = uv - 0.5;  // Center around 0
    
    float3 yuv = float3(y, uvNorm.x, uvNorm.y);
    float3 rgb = yuvToRGBMatrix * yuv;
    rgb = clamp(rgb, float3(0.0), float3(1.0));
    
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}

/// High-quality YUV to RGB with bilinear UV interpolation
/// Better quality at edges where chroma subsampling causes artifacts
kernel void yuvToRGBConvertHQ(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::sample> uvTexture [[texture(1)]],  // Note: access::sample
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    sampler uvSampler [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 ySize = uint2(yTexture.get_width(), yTexture.get_height());
    
    if (gid.x >= ySize.x || gid.y >= ySize.y) {
        return;
    }
    
    float y = yTexture.read(gid).r;
    
    // Calculate UV coordinates with proper centering for bilinear sampling
    float2 uvCoord = (float2(gid) + 0.5) / float2(ySize);
    float2 uv = uvTexture.sample(uvSampler, uvCoord).rg;
    
    // Video range conversion
    float yNorm = (y - 16.0/255.0) * (255.0/219.0);
    float2 uvNorm = (uv - 128.0/255.0) * (255.0/224.0);
    yNorm = clamp(yNorm, 0.0, 1.0);
    
    float3 yuv = float3(yNorm, uvNorm.x, uvNorm.y);
    float3 rgb = yuvToRGBMatrix * yuv;
    rgb = clamp(rgb, float3(0.0), float3(1.0));
    
    rgbTexture.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}
