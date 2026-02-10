//
//  Shaders.metal
//  VisionRemotePS5
//
//  Custom Metal shaders for GPU optimization on Apple Vision Pro
//  Post-processing techniques to improve visual quality of streaming
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct ShaderParams {
    float intensity;
    float edrHeadroom;
    float saturation;
    float contrast;
};

// MARK: - 1. ADAPTIVE SHARPENING
// Increases sharpness while preserving natural edges

kernel void adaptiveSharpen(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ShaderParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 center = input.read(gid);
    
    // Laplacian kernel for edge detection
    const float sharpenKernel[9] = {
        0.0, -1.0, 0.0,
        -1.0, 5.0, -1.0,
        0.0, -1.0, 0.0
    };
    
    float4 sum = float4(0.0);
    int index = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 offset = int2(dx, dy);
            uint2 coord = uint2(
                clamp(int(gid.x) + offset.x, 0, int(input.get_width() - 1)),
                clamp(int(gid.y) + offset.y, 0, int(input.get_height() - 1))
            );
            
            sum += input.read(coord) * sharpenKernel[index++];
        }
    }
    
    // Edge detection to apply sharpening only where needed
    float edgeStrength = length(sum.rgb - center.rgb);
    float adaptiveIntensity = clamp(edgeStrength * 2.0, 0.0, params.intensity);
    
    // Blend between original and sharpened
    float4 result = mix(center, sum, adaptiveIntensity);
    result.a = center.a;  // Preserve alpha
    
    output.write(result, gid);
}

// MARK: - 2. ACES TONE MAPPING
// Academy Color Encoding System - film industry standard

float3 acesFilmic(float3 x) {
    // ACES approximate coefficients (Narkowicz 2015)
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

kernel void acesToneMapping(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ShaderParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 color = input.read(gid);
    
    // Apply ACES tone mapping only for HDR values
    if (params.edrHeadroom > 1.0) {
        // Scale to HDR range
        color.rgb *= params.edrHeadroom;
        
        // Tone mapping
        color.rgb = acesFilmic(color.rgb);
    }
    
    output.write(color, gid);
}

// MARK: - 3. GAMING COLOR GRADING
// Optimized for games: more saturation, increased contrast

kernel void gamingColorGrade(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ShaderParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 color = input.read(gid);
    
    // 1. SATURATION: Increase color vibrancy
    // Rec. 709 luminance weights
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 grayscale = float3(luminance);
    color.rgb = mix(grayscale, color.rgb, params.saturation);
    
    // 2. CONTRAST: Smooth S-curve
    // Increases contrast while preserving shadow and highlight details
    color.rgb = (color.rgb - 0.5) * params.contrast + 0.5;
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    
    // 3. CRUSH BLACKS: Deeper blacks (common in gaming TVs)
    const float blackPoint = 0.02;
    color.rgb = max(color.rgb - blackPoint, 0.0) / (1.0 - blackPoint);
    
    // 4. GAMMA CORRECTION: Slightly brighter to compensate
    color.rgb = pow(color.rgb, float3(0.95));
    
    output.write(color, gid);
}

// MARK: - 4. MOTION BLUR REDUCTION
// Edge enhancement technique to reduce motion blur

kernel void reduceMotionBlur(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ShaderParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 center = input.read(gid);
    
    // High-pass filter with 3x3 kernel
    float4 sum = float4(0.0);
    int samples = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            
            uint2 coord = uint2(
                clamp(int(gid.x) + dx, 0, int(input.get_width() - 1)),
                clamp(int(gid.y) + dy, 0, int(input.get_height() - 1))
            );
            
            sum += input.read(coord);
            samples++;
        }
    }
    
    sum /= float(samples);
    
    // Detect blur magnitude (difference with neighbors)
    float4 difference = center - sum;
    float blurAmount = length(difference.rgb);
    
    // Edge-aware sharpening: stronger in areas with blur
    float sharpenStrength = clamp(blurAmount * 3.0, 0.0, params.intensity);
    float4 result = center + difference * sharpenStrength;
    result.a = center.a;
    
    output.write(result, gid);
}

// MARK: - 5. BILATERAL UPSAMPLING
// High-quality edge-preserving upsampling

kernel void bilateralUpsample(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    // Calculate coordinate in input (downsampled)
    float2 inputCoord = float2(gid) * (float2(input.get_width(), input.get_height()) / 
                                       float2(output.get_width(), output.get_height()));
    
    uint2 baseCoord = uint2(inputCoord);
    float2 frac = fract(inputCoord);
    
    // Bilinear sampling 2x2
    float4 samples[4];
    samples[0] = input.read(baseCoord);
    samples[1] = input.read(min(baseCoord + uint2(1, 0), uint2(input.get_width() - 1, input.get_height() - 1)));
    samples[2] = input.read(min(baseCoord + uint2(0, 1), uint2(input.get_width() - 1, input.get_height() - 1)));
    samples[3] = input.read(min(baseCoord + uint2(1, 1), uint2(input.get_width() - 1, input.get_height() - 1)));
    
    // Bilateral weights (considers color difference)
    float4 centerColor = samples[0];
    float weights[4];
    float weightSum = 0.0;
    const float colorSigma = 0.1;
    
    for (int i = 0; i < 4; i++) {
        float colorDiff = length(samples[i].rgb - centerColor.rgb);
        weights[i] = exp(-colorDiff * colorDiff / (2.0 * colorSigma * colorSigma));
        weightSum += weights[i];
    }
    
    // Weighted average
    float4 result = float4(0.0);
    for (int i = 0; i < 4; i++) {
        result += samples[i] * (weights[i] / weightSum);
    }
    
    output.write(result, gid);
}

// MARK: - 6. CHROMATIC ABERRATION CORRECTION
// Corrects chromatic aberration (color "bleeding" effect)

kernel void correctChromaticAberration(
    texture2d<float, access::sample> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ShaderParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    constexpr sampler textureSampler(coord::normalized,
                                     address::clamp_to_edge,
                                     filter::linear);
    
    float2 uv = float2(gid) / float2(output.get_width(), output.get_height());
    float2 centerOffset = uv - 0.5;
    
    // Radial aberration (stronger at edges)
    float distFromCenter = length(centerOffset);
    float aberrationStrength = params.intensity * distFromCenter * 0.01;
    
    // Sample RGB separately with different offset
    float2 uvR = uv + centerOffset * aberrationStrength;
    float2 uvG = uv;
    float2 uvB = uv - centerOffset * aberrationStrength;
    
    float r = input.sample(textureSampler, uvR).r;
    float g = input.sample(textureSampler, uvG).g;
    float b = input.sample(textureSampler, uvB).b;
    float a = input.sample(textureSampler, uvG).a;
    
    output.write(float4(r, g, b, a), gid);
}

// MARK: - 7. ANTI-ALIASING (FXAA-like)
// Simplified Fast Approximate Anti-Aliasing

kernel void fastAntialiasing(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 center = input.read(gid);
    
    // Sample neighbors (cross pattern)
    float4 north = input.read(uint2(gid.x, max(0u, gid.y - 1)));
    float4 south = input.read(uint2(gid.x, min(gid.y + 1, output.get_height() - 1)));
    float4 west = input.read(uint2(max(0u, gid.x - 1), gid.y));
    float4 east = input.read(uint2(min(gid.x + 1, output.get_width() - 1), gid.y));
    
    // Luminance for edge detection
    auto getLuma = [](float4 color) {
        return dot(color.rgb, float3(0.299, 0.587, 0.114));
    };
    
    float lumaCenter = getLuma(center);
    float lumaN = getLuma(north);
    float lumaS = getLuma(south);
    float lumaW = getLuma(west);
    float lumaE = getLuma(east);
    
    // Detectar contraste (edge)
    float rangeMin = min(lumaCenter, min(min(lumaN, lumaS), min(lumaW, lumaE)));
    float rangeMax = max(lumaCenter, max(max(lumaN, lumaS), max(lumaW, lumaE)));
    float range = rangeMax - rangeMin;
    
    // Threshold para aplicar AA
    const float edgeThreshold = 0.0625;  // 1/16
    
    if (range > edgeThreshold) {
        // Calcular blend factor baseado em contraste
        float blendFactor = clamp(range * 2.0, 0.0, 0.5);
        
        // Average com vizinhos
        float4 average = (north + south + west + east) * 0.25;
        float4 result = mix(center, average, blendFactor);
        output.write(result, gid);
    } else {
        output.write(center, gid);
    }
}

// MARK: - 8. EDGE DETECTION (para debug/efeitos)

kernel void detectEdges(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    // Sobel operator para edge detection
    float3 gx = float3(0.0);
    float3 gy = float3(0.0);
    
    // Kernel horizontal (Gx)
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint2 coord = uint2(
                clamp(int(gid.x) + dx, 0, int(input.get_width() - 1)),
                clamp(int(gid.y) + dy, 0, int(input.get_height() - 1))
            );
            
            float3 sample = input.read(coord).rgb;
            
            // Sobel kernels
            float kx = float(dx);
            float ky = float(dy);
            
            gx += sample * kx;
            gy += sample * ky;
        }
    }
    
    // Magnitude do gradiente
    float edge = length(gx) + length(gy);
    edge = clamp(edge, 0.0, 1.0);
    
    output.write(float4(edge, edge, edge, 1.0), gid);
}

// MARK: - 9. VIGNETTE EFFECT
// Efeito de vinheta sutil para foco central

kernel void applyVignette(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ShaderParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 color = input.read(gid);
    
    // UV coordinates (0-1)
    float2 uv = float2(gid) / float2(output.get_width(), output.get_height());
    float2 center = uv - 0.5;
    
    // Vinheta radial
    float dist = length(center);
    float vignette = smoothstep(0.8, 0.4, dist);
    vignette = mix(1.0, vignette, params.intensity);
    
    color.rgb *= vignette;
    
    output.write(color, gid);
}

// MARK: - 10. COLOR SPACE CONVERSION
// Conversão entre espaços de cor (útil para HDR)

// Rec.709 → DCI-P3
float3 rec709ToP3(float3 color) {
    // Matriz de conversão simplificada
    const float3x3 matrix = float3x3(
        float3(0.8225, 0.1774, 0.0001),
        float3(0.0331, 0.9669, 0.0000),
        float3(0.0171, 0.0724, 0.9105)
    );
    
    return matrix * color;
}

kernel void convertColorSpace(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 color = input.read(gid);
    color.rgb = rec709ToP3(color.rgb);
    output.write(color, gid);
}

