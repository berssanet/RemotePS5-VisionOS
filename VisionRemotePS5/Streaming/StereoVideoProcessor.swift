import CoreVideo
import Foundation
import Metal

/// Synthesizes a matched left/right pair from one color frame and estimated
/// inverse depth. Confined to the video render queue; never waits for inference.
/// The two halves contain 1080p views, not two independently generated images.
final class StereoVideoProcessor {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let flatDepth: MTLTexture

    /// Persistent processor-owned storage only. Source/depth inputs and the
    /// stereo render target are owned and accounted for by their callers.
    var ownedTextureCount: Int { 1 }
    var ownedTextureBytes: Int { flatDepth.allocatedSize }

    init?(device: MTLDevice) {
        self.device = device
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct StereoVertex { float4 position [[position]]; float2 uv; };
        vertex StereoVertex stereoVertex(uint id [[vertex_id]]) {
            const float2 position[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
            const float2 uv[3] = {float2(0,1), float2(2,1), float2(0,-1)};
            return {float4(position[id],0,1), uv[id]};
        }
        float flatRegionMask(float2 uv, bool protectHUD) {
            float border = min(min(uv.x, 1-uv.x), min(uv.y, 1-uv.y));
            float mask = smoothstep(0.0, 0.045, border);
            if (protectHUD) {
                // Manual screen regions, not semantic HUD detection. This
                // protects common edge text and the central aiming reticle.
                mask *= smoothstep(0.10, 0.18, border);
                mask *= smoothstep(0.65, 1.0, length((uv-0.5)/float2(0.055,0.08)));
            }
            return mask;
        }
        fragment float4 stereoFragment(StereoVertex in [[stage_in]],
            texture2d<float> color [[texture(0)]],
            texture2d<float> depth [[texture(1)]],
            sampler linearClamp [[sampler(0)]],
            constant float4& settings [[buffer(0)]]) {
            bool right = in.position.x >= settings.z;
            float2 uv = float2((in.position.x - (right ? settings.z : 0.0))/settings.z, in.uv.y);
            float mask = flatRegionMask(uv, settings.y > 0.5);
            // Positive total disparity places the far scene behind the screen:
            // a far feature is shifted left for the left eye and right for the
            // right eye. Near features converge on the physical screen plane.
            float shift = (right ? -0.5 : 0.5) * settings.x * mask;
            float2 sourceUV = uv;
            // Inverse-warp solve, limited to horizontal displacement. Clamping
            // fills uncovered borders with source edges; hidden geometry cannot
            // be reconstructed from this monocular stream.
            for (uint step=0; step<4; ++step) {
                float d = depth.sample(linearClamp, sourceUV).r;
                d = isfinite(d) ? clamp(d, 0.0, 1.0) : 1.0;
                sourceUV.x = clamp(uv.x + shift * (1.0-d), 0.0, 1.0);
            }
            float4 result = color.sample(linearClamp, sourceUV);
            // Source BGRA stores encoded SDR values. The sRGB target encodes
            // on write; decode once here so RealityKit samples correct linear RGB.
            result.rgb = select(pow((result.rgb+0.055)/1.055, float3(2.4)),
                                result.rgb/12.92, result.rgb <= 0.04045);
            result.a = 1;
            return result;
        }
        """
        guard let library = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "stereoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "stereoFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        let sampling = MTLSamplerDescriptor()
        sampling.minFilter = .linear
        sampling.magFilter = .linear
        sampling.sAddressMode = .clampToEdge
        sampling.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sampling) else { return nil }
        self.sampler = sampler
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        textureCache = cache
        let flat = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
            width: 1, height: 1, mipmapped: false)
        flat.storageMode = .shared
        flat.usage = .shaderRead
        guard let flatDepth = device.makeTexture(descriptor: flat) else { return nil }
        self.flatDepth = flatDepth
        var plane: Float = 1
        flatDepth.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0,
                          withBytes: &plane, bytesPerRow: MemoryLayout<Float>.size)
    }

    /// Both eyes use the exact same color frame; nil depth makes identical 2D
    /// views. Total disparity is capped at 1.2% of the screen width.
    func encode(frame: VideoFrameMailbox.Frame, depth: MTLTexture?, strength: Float,
                confidence: Float, protectHUD: Bool, commandBuffer: MTLCommandBuffer,
                target: MTLTexture) -> Bool {
        guard target.pixelFormat == .bgra8Unorm_srgb, target.width > 1, target.width % 2 == 0,
              target.device.registryID == device.registryID,
              commandBuffer.device.registryID == device.registryID,
              CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA else { return false }
        let map = depth ?? flatDepth
        guard map.pixelFormat == .r32Float, map.device.registryID == device.registryID else { return false }
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, frame.pixelBuffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer),
            0, &wrapper) == kCVReturnSuccess,
              let wrapper, let native = CVMetalTextureGetTexture(wrapper) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let amount = strength.isFinite ? min(max(strength, 0), 1) : 0
        let reliability = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        var settings = SIMD4<Float>(depth == nil ? 0 : amount * reliability * 0.012,
                                    protectHUD ? 1 : 0, Float(target.width / 2), 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(native, index: 0)
        encoder.setFragmentTexture(map, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime((frame.pixelBuffer, wrapper, native, map)) {}
        }
        return true
    }
}
