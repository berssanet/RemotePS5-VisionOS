//
//  SpatialScreenCoordinator.swift
//  VisionRemotePS5
//
//  Spatial 3D screen: a dense curved LowLevelMesh whose vertices are
//  displaced every depth frame by the SpatialDisplacement.metal compute
//  kernel, using Depth Anything V2 output from DepthEstimationService.
//
//  This is the visionOS-native replacement for the CustomMaterial geometry
//  modifier attempt removed in commit 7e371a4 (CustomMaterial does not exist
//  on visionOS; LowLevelMesh does, since visionOS 2.0).
//
//  The video texture itself is the SAME TextureResource the flat immersive
//  screen uses (ImmersiveTextureCoordinator's LowLevelTexture) — LowLevelTexture
//  updates propagate to every material referencing it, so this coordinator
//  only manages geometry, never video pixels.
//

import RealityKit
import Metal
import CoreVideo
import QuartzCore  // CACurrentMediaTime monotonic clock

@available(visionOS 2.0, *)
@MainActor
final class SpatialScreenCoordinator {

    static let shared = SpatialScreenCoordinator()

    // MARK: - Screen geometry (matches the flat cinema screen placement)

    private let screenWidth: Float = 6.0
    private let screenHeight: Float = 3.375
    private let screenPosition: SIMD3<Float> = [0, 1.8, -4.0]
    /// Parabolic curvature factor (0 = flat). Slight concavity for immersion.
    private let curvature: Float = 0.05
    /// Maximum displacement toward the viewer, in meters.
    var displacementIntensity: Float = 0.35
    /// Temporal EMA blend applied per depth update (1 = no smoothing).
    /// ~0.35 at 30Hz depth ≈ 90ms time constant — damps model flicker.
    var temporalSmoothing: Float = 0.35

    /// Grid resolution: 160x90 segments = 161x91 = 14,651 vertices.
    private let resX = 160
    private let resY = 90
    private var gridX: Int { resX + 1 }
    private var gridY: Int { resY + 1 }
    private var vertexCount: Int { gridX * gridY }
    private var indexCount: Int { resX * resY * 6 }

    /// MUST match SpatialVertex in SpatialDisplacement.metal:
    /// packed_float3 position (0), packed_float3 normal (12), float2 uv (24).
    private let vertexStride = 32

    /// MUST match SpatialDisplaceParams in SpatialDisplacement.metal.
    private struct DisplaceParams {
        var gridX: UInt32
        var gridY: UInt32
        var width: Float
        var height: Float
        var curvature: Float
        var intensity: Float
        var smoothing: Float
        var depthMin: Float
        var depthMax: Float
    }

    // MARK: - State

    private var lowLevelMesh: LowLevelMesh?
    private(set) var screenEntity: ModelEntity?
    private var commandQueue: MTLCommandQueue?
    private var displacePipeline: MTLComputePipelineState?
    private var depthTextureCache: CVMetalTextureCache?
    private var hasVideoMaterial = false
    private var updateInProgress = false
    private var lastUpdateTime: CFTimeInterval = 0
    private var depthFrameCounter: UInt64 = 0

    private init() {}

    // MARK: - Setup

    /// In-flight creation task: RealityView can invoke its make closure again
    /// while the first MeshResource await is suspended — dedupe so we never
    /// build two meshes/entities.
    private var creationTask: Task<ModelEntity?, Never>?

    /// Create (or return) the displaced-screen entity. Async because
    /// MeshResource creation from a LowLevelMesh is awaited by RealityKit.
    func getOrCreateEntity() async -> ModelEntity? {
        if let existing = screenEntity {
            return existing
        }
        if let inFlight = creationTask {
            return await inFlight.value
        }
        let task = Task<ModelEntity?, Never> { await createEntity() }
        creationTask = task
        let entity = await task.value
        creationTask = nil
        return entity
    }

    private func createEntity() async -> ModelEntity? {
        do {
            let mesh = try makeLowLevelMesh()
            try makeComputePipeline()

            let resource = try await MeshResource(from: mesh)
            var material = UnlitMaterial()
            material.color = .init(tint: .black)  // black until video adopts

            let entity = ModelEntity(mesh: resource, materials: [material])
            entity.name = "SpatialScreen"
            entity.position = screenPosition

            lowLevelMesh = mesh
            screenEntity = entity
            hasVideoMaterial = false
            DebugLog.info("SpatialScreen", "✅ Displaced screen ready: \(vertexCount) vertices (\(resX)x\(resY) grid)")
            return entity
        } catch {
            DebugLog.error("SpatialScreen", "Setup failed: \(error)")
            return nil
        }
    }

    /// Apply the shared video TextureResource once it exists (it is created
    /// by ImmersiveTextureCoordinator on the first decoded frame).
    func adoptVideoTexture(_ resource: TextureResource) {
        guard let entity = screenEntity, !hasVideoMaterial else { return }
        var material = UnlitMaterial()
        material.color = .init(texture: .init(resource))
        entity.model?.materials = [material]
        hasVideoMaterial = true
        DebugLog.info("SpatialScreen", "🎨 Video texture adopted by spatial screen")
    }

    private func makeLowLevelMesh() throws -> LowLevelMesh {
        // Layout contract with SpatialDisplacement.metal: 8 floats per vertex.
        assert(vertexStride == 8 * MemoryLayout<Float>.stride,
               "vertexStride must match the Metal SpatialVertex layout")
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCount
        descriptor.vertexAttributes = [
            LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            LowLevelMesh.Attribute(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
            LowLevelMesh.Attribute(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24)
        ]
        descriptor.vertexLayouts = [
            LowLevelMesh.Layout(bufferIndex: 0, bufferStride: vertexStride)
        ]
        descriptor.indexCapacity = indexCount
        descriptor.indexType = .uint32

        let mesh = try LowLevelMesh(descriptor: descriptor)

        // Initial flat-curved vertices (CPU, once). Same math as the kernel
        // with depth = 0 so the screen is valid before the first depth frame.
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let floats = raw.bindMemory(to: Float.self)
            for gy in 0..<gridY {
                let v = Float(gy) / Float(gridY - 1)
                for gx in 0..<gridX {
                    let u = Float(gx) / Float(gridX - 1)
                    let nx = (u - 0.5) * 2.0
                    let base = (gy * gridX + gx) * (vertexStride / MemoryLayout<Float>.stride)
                    floats[base + 0] = nx * screenWidth * 0.5           // position
                    floats[base + 1] = (0.5 - v) * screenHeight
                    floats[base + 2] = curvature * screenWidth * nx * nx
                    floats[base + 3] = 0                                 // normal
                    floats[base + 4] = 0
                    floats[base + 5] = 1
                    floats[base + 6] = u                                 // uv (bottom-left origin)
                    floats[base + 7] = 1.0 - v
                }
            }
        }

        // Static index buffer (CCW front faces viewed from +Z).
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            var i = 0
            for gy in 0..<resY {
                for gx in 0..<resX {
                    let a = UInt32(gy * gridX + gx)
                    let below = UInt32((gy + 1) * gridX + gx)
                    indices[i] = a;         indices[i + 1] = below;     indices[i + 2] = a + 1
                    indices[i + 3] = a + 1; indices[i + 4] = below;     indices[i + 5] = below + 1
                    i += 6
                }
            }
            assert(i == indexCount, "Index fill mismatch: \(i) != \(indexCount)")
        }

        // Bounds must contain the maximum possible displacement.
        let maxZ = curvature * screenWidth + displacementIntensity + 0.01
        let bounds = BoundingBox(
            min: [-screenWidth / 2, -screenHeight / 2, -0.01],
            max: [screenWidth / 2, screenHeight / 2, maxZ]
        )
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: bounds)
        ])

        return mesh
    }

    private func makeComputePipeline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SpatialScreenError.noMetalDevice
        }
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "spatialDisplace") else {
            throw SpatialScreenError.kernelNotFound
        }
        displacePipeline = try device.makeComputePipelineState(function: function)
        commandQueue = device.makeCommandQueue()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        depthTextureCache = cache
    }

    // MARK: - Depth update (GPU vertex displacement)

    /// Displace the mesh from a new depth frame. Drops the frame if a
    /// displacement pass is still in flight (same pattern as the texture
    /// coordinators), with a 100ms monotonic watchdog.
    func updateDepth(_ depthFrame: DepthFrame) {
        let now = CACurrentMediaTime()
        if updateInProgress && (now - lastUpdateTime) > 0.1 {
            DebugLog.warning("SpatialScreen", "Displacement timeout, forcing reset")
            updateInProgress = false
        }
        guard !updateInProgress,
              let mesh = lowLevelMesh,
              let pipeline = displacePipeline,
              let queue = commandQueue,
              let depthTexture = makeDepthTexture(from: depthFrame.pixelBuffer) else { return }

        updateInProgress = true
        lastUpdateTime = now
        depthFrameCounter += 1

        guard let commandBuffer = queue.makeCommandBuffer() else {
            updateInProgress = false
            return
        }

        let vertexBuffer = mesh.replace(bufferIndex: 0, using: commandBuffer)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            updateInProgress = false
            return
        }

        var params = DisplaceParams(
            gridX: UInt32(gridX), gridY: UInt32(gridY),
            width: screenWidth, height: screenHeight,
            curvature: curvature,
            intensity: displacementIntensity,
            smoothing: temporalSmoothing,
            depthMin: depthFrame.minValue,
            depthMax: depthFrame.maxValue
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<DisplaceParams>.stride, index: 1)
        encoder.setTexture(depthTexture.metal, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: gridX, height: gridY, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()

        // Keep the CVMetalTexture alive until the GPU finishes with it.
        // The box is immutable; @unchecked Sendable only extends its lifetime
        // into the (Sendable) GPU completion handler.
        let retainedTexture = RetainedDepthTexture(depthTexture.cv)
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = retainedTexture
            DispatchQueue.main.async {
                self?.updateInProgress = false
            }
        }
        commandBuffer.commit()
    }

    private func makeDepthTexture(from buffer: CVPixelBuffer) -> (metal: MTLTexture, cv: CVMetalTexture)? {
        guard let cache = depthTextureCache else { return nil }

        let format: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half: format = .r16Float
        case kCVPixelFormatType_OneComponent32Float: format = .r32Float
        default: return nil
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (metalTexture, cvTexture)
    }

    // MARK: - Lifecycle

    /// Full reset for clean VR re-entry (mirrors ImmersiveTextureCoordinator).
    func reset() {
        screenEntity?.removeFromParent()
        screenEntity = nil
        lowLevelMesh = nil
        hasVideoMaterial = false
        updateInProgress = false
        DebugLog.info("SpatialScreen", "Reset complete")
    }
}

@available(visionOS 2.0, *)
enum SpatialScreenError: Error {
    case noMetalDevice
    case kernelNotFound
}

/// Immutable lifetime holder for a CVMetalTexture captured by a GPU
/// completion handler (CVMetalTexture itself is not Sendable).
private final class RetainedDepthTexture: @unchecked Sendable {
    private let texture: CVMetalTexture
    init(_ texture: CVMetalTexture) { self.texture = texture }
}
