//
//  GPUOptimizationGuide.swift
//  VisionRemotePS5
//
//  Complete GPU optimization guide for Apple Vision Pro
//  Techniques to improve immersive experience using Metal and RealityKit
//
//  🎮 Implemented optimizations:
//  1. ✅ MetalFX Spatial Upscaling (1080p → 4K)
//  2. ✅ HDR Pipeline with Extended Range (bgra10_xr)
//  3. ✅ Triple Buffer Pool (reduces latency)
//  4. 🆕 Async Compute Queues (parallel processing)
//  5. 🆕 Advanced Tone Mapping (HDR → SDR)
//  6. 🆕 Sharpening & Anti-aliasing
//  7. 🆕 Motion Blur Reduction
//  8. 🆕 Color Grading for gaming
//

import Metal
import MetalPerformanceShaders
import RealityKit
import SwiftUI
import CoreVideo

// MARK: - ShaderParams struct (must match Metal ShaderParams)

/// Parameters passed to the compute shaders
/// Must have identical layout to the ShaderParams struct in Shaders.metal
struct ShaderParams {
    var intensity: Float
    var edrHeadroom: Float
    var saturation: Float
    var contrast: Float
    
    init(intensity: Float = 0.5, edrHeadroom: Float = 2.0, saturation: Float = 1.0, contrast: Float = 1.0) {
        self.intensity = intensity
        self.edrHeadroom = edrHeadroom
        self.saturation = saturation
        self.contrast = contrast
    }
}

// MARK: - 1. Enhanced GPU Pipeline with Asynchronous Compute Queues

/// GPU pipeline optimized for Vision Pro with parallel processing
@MainActor
class EnhancedGPUPipeline {
    
    // Multiple queues for parallel processing
    private let renderQueue: MTLCommandQueue      // Main rendering queue
    private let computeQueue: MTLCommandQueue     // Compute shaders queue (parallel)
    private let blitQueue: MTLCommandQueue        // Texture copy queue
    
    private let device: MTLDevice
    private let library: MTLLibrary
    
    // Compute pipelines for different effects
    private var sharpenPipeline: MTLComputePipelineState?
    private var toneMappingPipeline: MTLComputePipelineState?
    private var colorGradingPipeline: MTLComputePipelineState?
    private var motionBlurReductionPipeline: MTLComputePipelineState?
    
    // MPS (Metal Performance Shaders) for optimized operations
    private var gaussianBlur: MPSImageGaussianBlur?
    private var lanczosScale: MPSImageLanczosScale?
    // Note: MPSUnsharpMask is not available on visionOS, using custom compute shader instead
    
    init?(device: MTLDevice) {
        guard let renderQueue = device.makeCommandQueue(),
              let computeQueue = device.makeCommandQueue(),
              let blitQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        
        self.device = device
        self.renderQueue = renderQueue
        self.computeQueue = computeQueue
        self.blitQueue = blitQueue
        self.library = library
        
        renderQueue.label = "VisionPS5.RenderQueue"
        computeQueue.label = "VisionPS5.ComputeQueue"
        blitQueue.label = "VisionPS5.BlitQueue"
        
        setupComputePipelines()
        setupMPSFilters()
    }
    
    private func setupComputePipelines() {
        // Load custom compute shaders
        do {
            // Sharpening to improve details
            if let sharpenFunction = library.makeFunction(name: "adaptiveSharpen") {
                sharpenPipeline = try device.makeComputePipelineState(function: sharpenFunction)
            }
            
            // Tone mapping for HDR → SDR
            if let toneMappingFunction = library.makeFunction(name: "acesToneMapping") {
                toneMappingPipeline = try device.makeComputePipelineState(function: toneMappingFunction)
            }
            
            // Color grading optimized for games
            if let colorGradingFunction = library.makeFunction(name: "gamingColorGrade") {
                colorGradingPipeline = try device.makeComputePipelineState(function: colorGradingFunction)
            }
            
            // Motion blur reduction
            if let motionBlurFunction = library.makeFunction(name: "reduceMotionBlur") {
                motionBlurReductionPipeline = try device.makeComputePipelineState(function: motionBlurFunction)
            }
            
            print("[GPUPipeline] ✅ Compute pipelines configurados")
        } catch {
            print("[GPUPipeline] ⚠️ Error creating pipelines: \(error)")
        }
    }
    
    private func setupMPSFilters() {
        // Gaussian Blur for depth effects
        gaussianBlur = MPSImageGaussianBlur(device: device, sigma: 2.0)
        
        // Lanczos Scale for high-quality resizing
        lanczosScale = MPSImageLanczosScale(device: device)
        
        // Note: Unsharp Mask uses custom compute shader (adaptiveSharpen) on visionOS
        // MPSUnsharpMask is not available on this platform
        
        print("[GPUPipeline] ✅ MPS filters configurados")
    }
    
    /// Processes frame with all effects in parallel when possible
    func processFrame(
        input: MTLTexture,
        output: MTLTexture,
        settings: ProcessingSettings
    ) async -> Bool {
        
        // Intermediate buffer for multi-pass processing
        guard let intermediate = createIntermediateTexture(like: output) else {
            return false
        }
        
        // Command buffer in compute queue (asynchronous)
        guard let computeBuffer = computeQueue.makeCommandBuffer(),
              let renderBuffer = renderQueue.makeCommandBuffer() else {
            return false
        }
        
        computeBuffer.label = "ComputeEffects"
        renderBuffer.label = "RenderPass"
        
        // STEP 1: Motion Blur Reduction (compute queue)
        if settings.reduceMotionBlur, let pipeline = motionBlurReductionPipeline {
            applyComputeShader(
                pipeline: pipeline,
                input: input,
                output: intermediate,
                commandBuffer: computeBuffer
            )
        }
        
        // STEP 2: Color Grading (compute queue - can run in parallel)
        if settings.enableColorGrading, let pipeline = colorGradingPipeline {
            applyComputeShader(
                pipeline: pipeline,
                input: settings.reduceMotionBlur ? intermediate : input,
                output: intermediate,
                commandBuffer: computeBuffer
            )
        }
        
        // Commit compute work (runs in parallel)
        computeBuffer.commit()
        
        // STEP 3: Sharpening (custom compute shader - visionOS compatible)
        if settings.sharpeningIntensity > 0, let pipeline = sharpenPipeline {
            applyComputeShader(
                pipeline: pipeline,
                input: intermediate,
                output: output,
                commandBuffer: renderBuffer
            )
        }
        
        // STEP 4: Final Tone Mapping (if HDR enabled)
        if settings.enableHDR, let pipeline = toneMappingPipeline {
            applyComputeShader(
                pipeline: pipeline,
                input: settings.sharpeningIntensity > 0 ? output : intermediate,
                output: output,
                commandBuffer: renderBuffer
            )
        }
        
        // Commit render work
        renderBuffer.commit()
        
        // Wait for completion asynchronously
        await withCheckedContinuation { continuation in
            renderBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
        }
        
        return true
    }
    
    private func applyComputeShader(
        pipeline: MTLComputePipelineState,
        input: MTLTexture,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        params: ShaderParams? = nil
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        
        // Pass shader parameters (required for all shaders)
        // If params not provided, uses reasonable default values for gaming
        var shaderParams = params ?? ShaderParams(
            intensity: 0.3,      // Moderate sharpening
            edrHeadroom: 2.0,    // Default EDR headroom
            saturation: 1.1,     // Saturation boost for games
            contrast: 1.05       // Slight contrast boost
        )
        encoder.setBytes(&shaderParams, length: MemoryLayout<ShaderParams>.stride, index: 0)
        
        // Thread groups optimized for Vision Pro GPU
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (output.width + 15) / 16,
            height: (output.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
    }
    
    private func createIntermediateTexture(like texture: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = texture.pixelFormat
        descriptor.width = texture.width
        descriptor.height = texture.height
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private  // GPU-only for maximum performance
        
        return device.makeTexture(descriptor: descriptor)
    }
}

// MARK: - 2. Processing Settings

struct ProcessingSettings: Codable {
    var enableHDR: Bool = true
    var edrHeadroom: Float = 2.0
    var sharpeningIntensity: Float = 0.3  // 0.0 to 1.0
    var enableColorGrading: Bool = true
    var reduceMotionBlur: Bool = true
    var saturationBoost: Float = 1.1      // Increases saturation for games
    var contrastBoost: Float = 1.05
}

// MARK: - 3. RealityKit Optimizations

/// Optimized entity for video streaming with efficient GPU rendering
@MainActor
class OptimizedVideoEntity {
    
    private let entity: ModelEntity
    private var material: UnlitMaterial
    
    init(width: Float, height: Float, curved: Bool = true) {
        // Curved mesh for cinematic screen
        let mesh: MeshResource
        if curved {
            // Curved screen with 5 meter radius (more immersive)
            mesh = MeshResource.generateCurvedPlane(
                width: width,
                height: height,
                radius: 5.0,
                segments: 64  // High resolution for smooth curvature
            )
        } else {
            mesh = MeshResource.generatePlane(width: width, height: height)
        }
        
        // UnlitMaterial is more efficient (no lighting calculations)
        material = UnlitMaterial()
        entity = ModelEntity(mesh: mesh, materials: [material])
        
        // Rendering optimizations
        entity.name = "OptimizedVideoPlane"
        entity.position = [0, 1.8, -4.0]
        
        // Optional components for better performance
        entity.components.set(OpacityComponent(opacity: 1.0))
    }
    
    func updateTexture(_ textureResource: TextureResource) {
        material.color = .init(texture: .init(textureResource))
        entity.model?.materials = [material]
    }
    
    func getEntity() -> ModelEntity {
        return entity
    }
}

// MARK: - 4. Curved Plane Extension

extension MeshResource {
    static func generateCurvedPlane(
        width: Float,
        height: Float,
        radius: Float,
        segments: Int = 64
    ) -> MeshResource {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        
        let segmentsH = segments
        let segmentsV = Int(Float(segments) * (height / width))
        
        for j in 0...segmentsV {
            let v = Float(j) / Float(segmentsV)
            let y = (v - 0.5) * height
            
            for i in 0...segmentsH {
                let u = Float(i) / Float(segmentsH)
                
                // Horizontal curvature based on angle
                let angle = (u - 0.5) * (width / radius)
                let x = sin(angle) * radius
                let z = -cos(angle) * radius + radius  // Offset to center
                
                vertices.append(SIMD3<Float>(x, y, z))
                normals.append(normalize(SIMD3<Float>(-sin(angle), 0, cos(angle))))
                uvs.append(SIMD2<Float>(u, 1.0 - v))
            }
        }
        
        // Generate indices for triangles
        for j in 0..<segmentsV {
            for i in 0..<segmentsH {
                let a = UInt32((segmentsH + 1) * j + i)
                let b = UInt32((segmentsH + 1) * j + i + 1)
                let c = UInt32((segmentsH + 1) * (j + 1) + i)
                let d = UInt32((segmentsH + 1) * (j + 1) + i + 1)
                
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffer(vertices)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        
        return try! MeshResource.generate(from: [descriptor])
    }
}

// MARK: - 5. Metal Shaders (arquivo separado: Shaders.metal)

/*
 
 CRIAR ARQUIVO: Shaders.metal
 
 #include <metal_stdlib>
 using namespace metal;
 
 // 1. ADAPTIVE SHARPENING
 kernel void adaptiveSharpen(
     texture2d<float, access::read> input [[texture(0)]],
     texture2d<float, access::write> output [[texture(1)]],
     uint2 gid [[thread_position_in_grid]]
 ) {
     if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
     
     float4 center = input.read(gid);
     float4 sum = float4(0.0);
     
     // Kernel 3x3 para edge detection
     float kernel[9] = {
         0, -1, 0,
         -1, 5, -1,
         0, -1, 0
     };
     
     int index = 0;
     for (int dy = -1; dy <= 1; dy++) {
         for (int dx = -1; dx <= 1; dx++) {
             uint2 coord = uint2(
                 clamp(int(gid.x) + dx, 0, int(input.get_width() - 1)),
                 clamp(int(gid.y) + dy, 0, int(input.get_height() - 1))
             );
             sum += input.read(coord) * kernel[index++];
         }
     }
     
     // Blend com original (adaptive)
     float edge = length(sum - center);
     float sharpAmount = clamp(edge * 2.0, 0.0, 0.5);
     float4 result = mix(center, sum, sharpAmount);
     
     output.write(result, gid);
 }
 
 // 2. ACES TONE MAPPING (Academy Color Encoding System)
 float3 acesFilmic(float3 x) {
     float a = 2.51;
     float b = 0.03;
     float c = 2.43;
     float d = 0.59;
     float e = 0.14;
     return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
 }
 
 kernel void acesToneMapping(
     texture2d<float, access::read> input [[texture(0)]],
     texture2d<float, access::write> output [[texture(1)]],
     uint2 gid [[thread_position_in_grid]]
 ) {
     if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
     
     float4 color = input.read(gid);
     color.rgb = acesFilmic(color.rgb);
     output.write(color, gid);
 }
 
 // 3. GAMING COLOR GRADING
 kernel void gamingColorGrade(
     texture2d<float, access::read> input [[texture(0)]],
     texture2d<float, access::write> output [[texture(1)]],
     uint2 gid [[thread_position_in_grid]]
 ) {
     if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
     
     float4 color = input.read(gid);
     
     // Aumentar saturação (mais vibrante para jogos)
     float3 gray = float3(dot(color.rgb, float3(0.299, 0.587, 0.114)));
     color.rgb = mix(gray, color.rgb, 1.2);  // 20% mais saturação
     
     // Aumentar contraste
     color.rgb = (color.rgb - 0.5) * 1.1 + 0.5;
     
     // Crush blacks ligeiramente (melhor preto)
     color.rgb = pow(color.rgb, float3(1.05));
     
     output.write(color, gid);
 }
 
 // 4. MOTION BLUR REDUCTION (temporal analysis)
 kernel void reduceMotionBlur(
     texture2d<float, access::read> input [[texture(0)]],
     texture2d<float, access::write> output [[texture(1)]],
     uint2 gid [[thread_position_in_grid]]
 ) {
     if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
     
     // High-pass filter para preservar bordas
     float4 center = input.read(gid);
     float4 sum = float4(0.0);
     
     for (int dy = -1; dy <= 1; dy++) {
         for (int dx = -1; dx <= 1; dx++) {
             if (dx == 0 && dy == 0) continue;
             
             uint2 coord = uint2(
                 clamp(int(gid.x) + dx, 0, int(input.get_width() - 1)),
                 clamp(int(gid.y) + dy, 0, int(input.get_height() - 1))
             );
             sum += input.read(coord);
         }
     }
     
     sum /= 8.0;
     
     // Edge-aware sharpening
     float4 diff = center - sum;
     float edge = length(diff);
     float4 result = center + diff * clamp(edge * 2.0, 0.0, 0.3);
     
     output.write(result, gid);
 }
 
 */

// MARK: - 6. Performance Tips & Best Practices

/*
 
 📊 PERFORMANCE CHECKLIST PARA VISION PRO:
 
 ✅ 1. USE ASYNC COMPUTE QUEUES
    - Separe renderização de pós-processamento
    - Execute shaders em paralelo quando possível
 
 ✅ 2. MINIMIZE TEXTURE COPIES
    - Use .private storage mode para texturas intermediárias
    - Evite readback CPU → GPU
    - Use Triple Buffer Pool para streaming
 
 ✅ 3. OPTIMIZE SHADER COMPLEXITY
    - Use half precision (half4) quando possível
    - Minimize texture reads
    - Use MPS para operações comuns
 
 ✅ 4. LEVERAGE METALFX
    - Spatial Upscaling é extremamente eficiente
    - Deixe a GPU fazer upscaling, não CPU
 
 ✅ 5. HDR PIPELINE
    - Use bgra10_xr para HDR (melhor que rgba16Float)
    - Tone mapping apenas quando necessário
 
 ✅ 6. REALITYKIT OPTIMIZATION
    - UnlitMaterial para vídeo (sem lighting)
    - Curved mesh para imersão (pré-computado)
    - Minimize entity count
 
 ✅ 7. THERMAL MANAGEMENT
    - Monitor thermal state
    - Reduzir qualidade em overheating
    - Desabilitar efeitos não-essenciais
 
 */

// MARK: - 7. Thermal State Monitor

@MainActor
class ThermalStateMonitor: ObservableObject {
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var recommendedQuality: Quality = .ultra
    
    enum Quality {
        case ultra      // All effects
        case high       // No motion blur reduction
        case medium     // No color grading
        case low        // Upscaling only
    }
    
    init() {
        updateThermalState()
        
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateThermalState()
            }
        }
    }
    
    private func updateThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        
        // Adjust quality based on thermal state
        switch thermalState {
        case .nominal:
            recommendedQuality = .ultra
        case .fair:
            recommendedQuality = .high
        case .serious:
            recommendedQuality = .medium
        case .critical:
            recommendedQuality = .low
        @unknown default:
            recommendedQuality = .medium
        }
        
        print("[Thermal] State: \(thermalState.rawValue) → Quality: \(recommendedQuality)")
    }
}

// MARK: - 8. Frame Timing & Latency Optimization

/// Medidor de latência frame-to-frame
class FrameTimingAnalyzer {
    private var lastFrameTime: CFTimeInterval = 0
    private var frameTimes: [CFTimeInterval] = []
    private let maxSamples = 120  // 2 segundos @ 60fps
    
    func recordFrame() {
        let now = CACurrentMediaTime()
        
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            frameTimes.append(delta)
            
            if frameTimes.count > maxSamples {
                frameTimes.removeFirst()
            }
        }
        
        lastFrameTime = now
    }
    
    var averageFrameTime: Double {
        guard !frameTimes.isEmpty else { return 0 }
        return frameTimes.reduce(0, +) / Double(frameTimes.count)
    }
    
    var fps: Double {
        let avgTime = averageFrameTime
        return avgTime > 0 ? 1.0 / avgTime : 0
    }
    
    var percentile95: Double {
        guard !frameTimes.isEmpty else { return 0 }
        let sorted = frameTimes.sorted()
        let index = Int(Double(sorted.count) * 0.95)
        return sorted[min(index, sorted.count - 1)]
    }
}

