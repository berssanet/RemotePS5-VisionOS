//
//  SpatialDisplacement.metal
//  VisionRemotePS5
//
//  Compute kernel that displaces the vertices of the spatial screen's
//  LowLevelMesh from an AI depth map (Depth Anything V2 relative inverse
//  depth: brighter = nearer). Replaces the abandoned CustomMaterial geometry
//  modifier from commit f3b3b73 — CustomMaterial does not exist on visionOS;
//  LowLevelMesh + compute is the supported path (visionOS 2.0+).
//
//  Vertex layout MUST match SpatialScreenCoordinator.swift:
//  offset 0: packed_float3 position, 12: packed_float3 normal, 24: float2 uv
//  (stride 32 bytes).
//

#include <metal_stdlib>
using namespace metal;

struct SpatialVertex {
    packed_float3 position;
    packed_float3 normal;
    float2 uv;
};

struct SpatialDisplaceParams {
    uint gridX;        // vertices per row    (resX + 1)
    uint gridY;        // vertices per column (resY + 1)
    float width;       // screen width  (m)
    float height;      // screen height (m)
    float curvature;   // parabolic curve depth factor (0 = flat)
    float intensity;   // max displacement toward viewer (m)
    float smoothing;   // temporal EMA blend for new depth (1 = no smoothing)
    float depthMin;    // per-frame depth normalization range (CPU-computed)
    float depthMax;
};

kernel void spatialDisplace(
    device SpatialVertex *vertices [[buffer(0)]],
    constant SpatialDisplaceParams &p [[buffer(1)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.gridX || gid.y >= p.gridY) {
        return;
    }
    uint idx = gid.y * p.gridX + gid.x;

    float u = float(gid.x) / float(p.gridX - 1);
    float v = float(gid.y) / float(p.gridY - 1);   // v = 0 → top row

    // Base geometry: concave parabolic screen (edges curve toward the user).
    float nx = (u - 0.5) * 2.0;                    // -1 ... +1
    float x = nx * p.width * 0.5;
    float y = (0.5 - v) * p.height;
    float baseZ = p.curvature * p.width * nx * nx;

    // Depth sample (Metal texture origin is top-left, matching v).
    // 5-tap bilateral: neighbors weighted by depth similarity to the center,
    // smoothing model noise without blurring across true depth edges
    // (halo reduction — Phase 7 backlog item).
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv = float2(u, v);
    float2 texel = float2(1.0 / float(depthTex.get_width()),
                          1.0 / float(depthTex.get_height()));
    float center = depthTex.sample(linearSampler, uv).r;
    float weightSum = 1.0;
    float depthSum = center;
    const float2 offsets[4] = {
        float2(texel.x, 0.0), float2(-texel.x, 0.0),
        float2(0.0, texel.y), float2(0.0, -texel.y)
    };
    float range = max(p.depthMax - p.depthMin, 1e-4);
    for (int i = 0; i < 4; i++) {
        float neighbor = depthTex.sample(linearSampler, uv + offsets[i]).r;
        // Similarity falls off with normalized depth difference.
        float w = exp(-8.0 * abs(neighbor - center) / range);
        depthSum += neighbor * w;
        weightSum += w;
    }
    float d = depthSum / weightSum;

    // Normalize the model's unbounded relative depth into 0...1.
    float dNorm = clamp((d - p.depthMin) / range, 0.0, 1.0);

    // Push near content toward the viewer; EMA damps depth flicker.
    float targetZ = baseZ + dNorm * p.intensity;
    device SpatialVertex &vert = vertices[idx];
    float z = mix(float(vert.position.z), targetZ, p.smoothing);

    vert.position = packed_float3(x, y, z);
    vert.normal = packed_float3(0.0, 0.0, 1.0);    // unlit material — lighting unused
    // RealityKit UV origin is bottom-left; flip v so the video is upright.
    vert.uv = float2(u, 1.0 - v);
}
