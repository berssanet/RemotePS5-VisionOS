import Foundation
import Metal
import CoreVideo

/// All video consumers encode and commit in order on this queue. Sharing the
/// Metal command queue preserves each persistent upscaler output until its
/// render pass has read it, including when two command buffers are in flight.
final class VideoGPUContext: @unchecked Sendable {
    static let shared = VideoGPUContext()
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let renderQueue = DispatchQueue(label: "video.render.shared", qos: .userInteractive)

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
    }
}

struct VideoProcessingResult {
    let status: String
    let appliedMode: UpscalerType
    let ownedTextureCount: Int
    let ownedTextureBytes: Int
    let reusedOutput: Bool
}

/// One processor per consumer, confined to VideoGPUContext.renderQueue.
/// Encodes only; the caller owns admission, presentation and commit. Comparison
/// samples one decoded frame twice. The mailbox alone owns the optional frozen
/// inspection image; processing never accumulates a frame history.
final class VideoFrameProcessor {
    private let device: MTLDevice
    private let library: MTLLibrary
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let thermalState: () -> ProcessInfo.ThermalState
    private var pipeline: MTLRenderPipelineState?
    private var pipelineFormat: MTLPixelFormat?
    private var metalFX: MetalFXUpscaler?
    private var enhanced: EnhancedUpscaler?
    private struct SourceConfiguration: Equatable {
        let width: Int
        let height: Int
        let format: MTLPixelFormat
    }
    private var sourceConfiguration: SourceConfiguration?
    private var metalFXOutputDimensions: MetalFXUpscaler.OutputDimensions?
    private var attemptedMetalFX = false
    private var attemptedEnhanced = false
    #if VIDEO_GPU_TESTING
    var makeMetalFXForTesting: ((Int, Int, Int, Int) -> MetalFXUpscaler?)?
    #endif
    var ownedTextureCount: Int { (metalFX?.ownedTextureCount ?? 0) + (enhanced?.ownedTextureCount ?? 0) }
    var ownedTextureBytes: Int { (metalFX?.ownedTextureBytes ?? 0) + (enhanced?.ownedTextureBytes ?? 0) }
    #if !DISABLE_PERFORMANCE_COLLECTION
    private var lastMetalFXOutput: ObjectIdentifier?
    private var lastEnhancedOutput: ObjectIdentifier?
    #endif

    init?(device: MTLDevice,
          thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        self.device = device
        self.thermalState = thermalState
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VideoVertex { float4 position [[position]]; float2 uv; };
        vertex VideoVertex videoVertex(uint id [[vertex_id]]) {
            const float2 position[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            const float2 uv[3] = {float2(0, 1), float2(2, 1), float2(0, -1)};
            return {float4(position[id], 0, 1), uv[id]};
        }
        fragment float4 videoFragment(VideoVertex in [[stage_in]],
            texture2d<float> native [[texture(0)]],
            texture2d<float> processed [[texture(1)]],
            sampler sampleFilter [[sampler(0)]],
            constant float4& comparison [[buffer(0)]],
            constant float4& inspection [[buffer(1)]]) {
            // The same crop is sampled from both full-frame results. The
            // divider remains in screen coordinates rather than moving with it.
            float2 sampleUV = (in.uv - 0.5) / inspection.x + inspection.yz;
            float4 color;
            if (comparison.x > 0.5 && in.uv.x < comparison.y)
                color = native.sample(sampleFilter, sampleUV);
            else {
                color = processed.sample(sampleFilter, sampleUV);
            }
            // A single neutral display pixel marks the split. At the endpoints
            // the entire target is one side, with no border covering content.
            if (comparison.x > 0.5 && comparison.y > 0 && comparison.y < 1 &&
                abs(in.uv.x - comparison.y) < comparison.z * 0.5)
                color = float4(0.7, 0.7, 0.7, 1);
            // Decoder/upscalers contain encoded SDR samples. An sRGB render
            // target encodes on write, so decode here first; RealityKit then
            // samples that sRGB texture in linear space without double gamma.
            if (comparison.w > 0.5)
                color.rgb = select(pow((color.rgb + 0.055) / 1.055, float3(2.4)),
                                   color.rgb / 12.92, color.rgb <= 0.04045);
            return color;
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        self.library = library
        let descriptor = MTLSamplerDescriptor()
        descriptor.magFilter = .linear
        descriptor.minFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        self.sampler = sampler
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        textureCache = cache
    }

    func encode(frame: VideoFrameMailbox.Frame, state: VideoFrameMailbox.State,
                commandBuffer: MTLCommandBuffer, target: MTLTexture) -> VideoProcessingResult? {
        guard commandBuffer.device.registryID == device.registryID,
              target.device.registryID == device.registryID,
              target.pixelFormat == .bgra8Unorm || target.pixelFormat == .bgra8Unorm_srgb,
              CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        if pipelineFormat != target.pixelFormat {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "videoFragment")
            descriptor.colorAttachments[0].pixelFormat = target.pixelFormat
            guard let created = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            pipeline = created
            pipelineFormat = target.pixelFormat
        }
        guard let pipeline else { return nil }
        let buffer = frame.pixelBuffer
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
            0, &wrapper) == kCVReturnSuccess,
              let wrapper, let native = CVMetalTextureGetTexture(wrapper) else { return nil }
        let source = SourceConfiguration(width: native.width, height: native.height, format: native.pixelFormat)
        if sourceConfiguration != source {
            sourceConfiguration = source
            // Completed commands release any retired source-size generation
            // they still use on the GPU.
            metalFX = nil
            metalFXOutputDimensions = nil
            enhanced = nil
            attemptedMetalFX = false
            attemptedEnhanced = false
            #if !DISABLE_PERFORMANCE_COLLECTION
            lastMetalFXOutput = nil
            lastEnhancedOutput = nil
            #endif
        }
        // Also retain on a later encoder failure, since an upscaler may already
        // have encoded work in the command buffer before falling back to Native.
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime((buffer, wrapper)) {} }

        let thermal = thermalState()
        let mode: UpscalerType = thermal == .serious || thermal == .critical ? .native : state.mode
        var selected = native
        var appliedMode: UpscalerType = .native
        var reason: String?
        var reusedOutput = false
        if mode == .metalFX {
            let outputDimensions = MetalFXUpscaler.outputDimensions(
                inputWidth: native.width, inputHeight: native.height,
                targetWidth: target.width, targetHeight: target.height)
            if metalFXOutputDimensions != outputDimensions {
                metalFXOutputDimensions = outputDimensions
                metalFX = nil
                attemptedMetalFX = false
                #if !DISABLE_PERFORMANCE_COLLECTION
                lastMetalFXOutput = nil
                #endif
            }
            if !attemptedMetalFX {
                attemptedMetalFX = true
                if let outputDimensions {
                    #if VIDEO_GPU_TESTING
                    if let makeMetalFXForTesting {
                        metalFX = makeMetalFXForTesting(native.width, native.height,
                                                       outputDimensions.width, outputDimensions.height)
                    } else {
                        metalFX = MetalFXUpscaler(inputWidth: native.width, inputHeight: native.height,
                            outputWidth: outputDimensions.width, outputHeight: outputDimensions.height, device: device)
                    }
                    #else
                    metalFX = MetalFXUpscaler(inputWidth: native.width, inputHeight: native.height,
                        outputWidth: outputDimensions.width, outputHeight: outputDimensions.height, device: device)
                    #endif
                }
            }
            if let output = metalFX?.encode(buffer, commandBuffer: commandBuffer) {
                selected = output
                appliedMode = .metalFX
                #if !DISABLE_PERFORMANCE_COLLECTION
                let identity = ObjectIdentifier(output)
                reusedOutput = identity == lastMetalFXOutput
                lastMetalFXOutput = identity
                #endif
                if output.width < target.width || output.height < target.height {
                    reason = "Processing size capped; final display scaling"
                }
            } else {
                reason = "MetalFX unavailable for \(native.width)×\(native.height); showing Original"
            }
        } else if mode == .enhanced {
            if native.width == EnhancedUpscaler.inputWidth && native.height == EnhancedUpscaler.inputHeight {
                if !attemptedEnhanced {
                    attemptedEnhanced = true
                    enhanced = EnhancedUpscaler(device: device)
                }
                enhanced?.sharpenStrength = state.sharpness
                if let output = enhanced?.encode(buffer, commandBuffer: commandBuffer) {
                    selected = output
                    appliedMode = .enhanced
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    let identity = ObjectIdentifier(output)
                    reusedOutput = identity == lastEnhancedOutput
                    lastEnhancedOutput = identity
                    #endif
                } else { reason = "Enhanced unavailable" }
            } else { reason = "Enhanced requires a 1080p source; showing Original" }
        }
        if mode != state.mode { reason = "Temperature protection" }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(native, index: 0)
        encoder.setFragmentTexture(selected, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let position = state.comparisonPosition.isFinite ? min(max(state.comparisonPosition, 0), 1) : 0.5
        let comparisonActive = state.comparisonEnabled && state.mode != .native
        var comparison = SIMD4<Float>(comparisonActive ? 1 : 0, position,
                                      1 / Float(target.width), target.pixelFormat == .bgra8Unorm_srgb ? 1 : 0)
        encoder.setFragmentBytes(&comparison, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        let zoom: Float = state.inspectionZoom.isFinite
            ? (state.inspectionZoom >= 4 ? 4 : state.inspectionZoom >= 2 ? 2 : 1) : 1
        let inset = 0.5 / zoom
        let center = SIMD2<Float>(
            state.inspectionCenter.x.isFinite ? min(max(state.inspectionCenter.x, inset), 1 - inset) : 0.5,
            state.inspectionCenter.y.isFinite ? min(max(state.inspectionCenter.y, inset), 1 - inset) : 0.5)
        var inspection = SIMD4<Float>(zoom, center.x, center.y, 0)
        encoder.setFragmentBytes(&inspection, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let name = appliedMode == .native ? "Native" : appliedMode.rawValue
        var status = "\(name) · Source \(native.width)×\(native.height) → Output texture \(selected.width)×\(selected.height) · Display target \(target.width)×\(target.height)"
        if comparisonActive { status = "Native | \(name) · Same frame · " + status }
        if state.isInspectionFrozen { status += " · Frozen image" }
        if zoom > 1 { status += " · Detail \(Int(zoom))×" }
        if let reason { status += " · \(reason)" }
        #if DISABLE_PERFORMANCE_COLLECTION
        let ownedCount = 0
        let ownedBytes = 0
        #else
        let ownedCount = (metalFX?.ownedTextureCount ?? 0) + (enhanced?.ownedTextureCount ?? 0)
        let ownedBytes = (metalFX?.ownedTextureBytes ?? 0) + (enhanced?.ownedTextureBytes ?? 0)
        #endif
        return VideoProcessingResult(status: status, appliedMode: appliedMode,
            ownedTextureCount: ownedCount, ownedTextureBytes: ownedBytes,
            reusedOutput: reusedOutput)
    }
}
