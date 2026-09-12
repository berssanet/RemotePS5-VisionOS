import Combine
// Metal's Objective-C resources lack Sendable annotations. Each command buffer
// is transferred once from MainActor to the serial worker, never encoded by both.
@preconcurrency import Metal
import RealityKit
import SwiftUI
import os

/// Owns one cinema surface. RealityKit texture replacement is main-actor work;
/// video encoding and commitment share the window renderer's serial GPU queue.
@MainActor
final class ImmersiveCinemaRenderer: ObservableObject {
    enum Failure: Error { case unavailable, preparationFailed, cancelled }

    @Published private(set) var processingStatus = "Preparing cinema…"
    @Published private(set) var horizontalCoverage = CinemaScreenGeometry.defaultHorizontalCoverage
    @Published private(set) var screenAdjustmentError: String?
    private let frames: VideoFrameMailbox
    private let surfaceID: UUID
    private let worker: CinemaGPUWorker
    private let targetWidth: Int
    private let targetHeight: Int
    private let tickPending = OSAllocatedUnfairLock(initialState: false)
    private var subscription: EventSubscription?
    private var texture: LowLevelTexture?
    private var screen: ModelEntity?
    private var stopped = false
    private var inFlight = 0
    private var lastKey: FrameKey?
    private var mayConsume: ((MetricSessionID) -> Bool)?
    private var onFailure: (() -> Void)?

    private struct FrameKey: Equatable {
        let generation: MetricSessionID
        let frame: UInt64
        let mode: UpscalerType
        let sharpness: Float
        let comparison: Bool
        let position: Float
        let frozen: Bool
        let zoom: Float
        let center: SIMD2<Float>
    }

    init(frames: VideoFrameMailbox, surfaceID: UUID) {
        self.frames = frames
        self.surfaceID = surfaceID
        let requested = StreamingService.shared.requestedVideoSize
        // The cinema screen must not shrink its presentation texture with the
        // network profile. Match the default window's 1440p target for low-bandwidth
        // sources; the shared processor scales directly to this texture.
        targetWidth = min(3840, max(2560, requested.width * 2))
        targetHeight = min(2160, max(1440, requested.height * 2))
        worker = CinemaGPUWorker(frames: frames, surfaceID: surfaceID)
    }

    /// No frame or selection is required: readiness must precede the handoff.
    func prepare() async throws -> ModelEntity {
        guard !stopped else { throw Failure.cancelled }
        if let screen { return screen }
        guard await worker.prepare() else { throw Failure.unavailable }
        try Task.checkCancellation()
        guard !stopped else { throw Failure.cancelled }

        // The shared shader preserves SDR encoded colors for an sRGB target.
        // RealityKit decodes them while sampling; disable the artistic tone map.
        let texture = try LowLevelTexture(descriptor: .init(
            pixelFormat: .bgra8Unorm_srgb, width: targetWidth, height: targetHeight,
            textureUsage: [.shaderRead, .renderTarget]))
        guard let commandBuffer = VideoGPUContext.shared.commandQueue?.makeCommandBuffer() else {
            throw Failure.unavailable
        }
        let target = texture.replace(using: commandBuffer)
        let cleared = await worker.initializeBlack(target: target, commandBuffer: commandBuffer,
                                                   texture: texture)
        guard cleared else { throw Failure.preparationFailed }
        let resource = try await TextureResource(from: texture)
        try Task.checkCancellation()
        guard !stopped else { throw Failure.cancelled }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(resource))
        material.faceCulling = .back
        let screen = ModelEntity(mesh: try Self.makeScreenMesh(horizontalCoverage: horizontalCoverage),
                                 materials: [material])
        screen.name = "CinemaScreen"
        self.texture = texture
        self.screen = screen
        reportScreenCoverage()
        processingStatus = "Waiting for video…"
        return screen
    }

    /// Curvature changes only the presentation mesh. The current video texture,
    /// material, frame consumer and GPU submission lifetime remain in place.
    func setHorizontalCoverage(_ degrees: Float) {
        let coverage = CinemaScreenGeometry.normalizedCoverage(degrees)
        guard !stopped, coverage != horizontalCoverage,
              let screen, var model = screen.model else { return }
        do {
            let mesh = try Self.makeScreenMesh(horizontalCoverage: coverage)
            model.mesh = mesh
            screen.model = model
            horizontalCoverage = coverage
            screenAdjustmentError = nil
            reportScreenCoverage()
        } catch {
            // Keep the last working geometry and slider position on failure.
            screenAdjustmentError = "The screen could not be adjusted. Try again."
            DebugLog.print("[CinemaVideo] Screen geometry update failed")
        }
    }

    private static func makeScreenMesh(horizontalCoverage: Float) throws -> MeshResource {
        let geometry = CinemaScreenGeometry.make(horizontalCoverage: horizontalCoverage)
        var descriptor = MeshDescriptor(name: "CurvedCinemaScreen")
        descriptor.positions = MeshBuffers.Positions(geometry.positions)
        descriptor.normals = MeshBuffers.Normals(geometry.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(geometry.textureCoordinates)
        descriptor.primitives = .triangles(geometry.triangleIndices)
        return try MeshResource.generate(from: [descriptor])
    }

    private func reportScreenCoverage() {
        DebugLog.print("[CinemaVideo] Curved screen: horizontal=\(horizontalCoverage) vertical=\(horizontalCoverage * 9 / 16)")
    }

    func start(content: RealityViewContent,
               mayConsume: @escaping (MetricSessionID) -> Bool,
               onFailure: @escaping () -> Void) {
        guard !stopped, texture != nil, subscription == nil else { return }
        self.mayConsume = mayConsume
        self.onFailure = onFailure
        let pending = tickPending
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            // The SDK does not annotate the event handler as MainActor. Keep
            // at most one actor hop pending even if the UI is temporarily busy.
            guard pending.withLock({ value in
                guard !value else { return false }
                value = true
                return true
            }) else { return }
            Task { @MainActor [weak self] in
                pending.withLock { $0 = false }
                self?.tick()
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        subscription?.cancel()
        subscription = nil
        worker.stop()
        mayConsume = nil
        onFailure = nil
        screen?.isEnabled = false
        screen = nil
        texture = nil
    }

    private func tick() {
        guard !stopped, inFlight < 2, let texture,
              frames.isSelectedConsumer(surfaceID) else { return }
        let candidate = frames.snapshotForRendering(consumerID: surfaceID)
        guard candidate.enabled, let candidateFrame = candidate.frame,
              let generation = candidateFrame.session, mayConsume?(generation) == true else { return }
        let key = FrameKey(generation: generation, frame: candidateFrame.id,
                           mode: candidate.mode, sharpness: candidate.sharpness,
                           comparison: candidate.comparisonEnabled, position: candidate.comparisonPosition,
                           frozen: candidate.isInspectionFrozen, zoom: candidate.inspectionZoom,
                           center: candidate.inspectionCenter)
        guard key != lastKey else { return }
        let state = frames.acquireForRendering(consumerID: surfaceID)
        guard state.enabled, let frame = state.frame, let session = frame.session,
              mayConsume?(session) == true,
              let commandBuffer = VideoGPUContext.shared.commandQueue?.makeCommandBuffer() else { return }
        let admittedKey = FrameKey(generation: session, frame: frame.id, mode: state.mode,
                                   sharpness: state.sharpness, comparison: state.comparisonEnabled,
                                   position: state.comparisonPosition, frozen: state.isInspectionFrozen,
                                   zoom: state.inspectionZoom, center: state.inspectionCenter)
        let target = texture.replace(using: commandBuffer)
        inFlight += 1
        lastKey = admittedKey
        worker.submit(frame: frame, state: state, target: target,
                      commandBuffer: commandBuffer, texture: texture) { [weak self] success, status in
            guard let self else { return }
            self.inFlight -= 1
            guard !self.stopped, self.frames.permitsRendering(consumerID: self.surfaceID, session: session),
                  self.mayConsume?(session) == true else { return }
            if success, let status {
                if self.processingStatus != status {
                    self.processingStatus = status
                    // Only applied processing/status changes, never one log per frame.
                    DebugLog.print("[CinemaVideo] Processing: \(status)")
                }
            } else {
                self.screen?.isEnabled = false
                self.processingStatus = "Cinema video unavailable"
                let fail = self.onFailure
                self.stop()
                fail?()
            }
        }
    }
}

/// Mutable processor state belongs only to the shared render queue. The small
/// stop flag is independent so disappearing UI can revoke queued work at once.
private final class CinemaGPUWorker: @unchecked Sendable {
    private let frames: VideoFrameMailbox
    private let surfaceID: UUID
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private var processor: VideoFrameProcessor?
    init(frames: VideoFrameMailbox, surfaceID: UUID) {
        self.frames = frames
        self.surfaceID = surfaceID
    }

    func prepare() async -> Bool {
        await withCheckedContinuation { continuation in
            VideoGPUContext.shared.renderQueue.async {
                guard !self.stopped.withLock({ $0 }),
                      let device = VideoGPUContext.shared.device else {
                    continuation.resume(returning: false)
                    return
                }
                self.processor = VideoFrameProcessor(device: device)
                continuation.resume(returning: self.processor != nil)
            }
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        VideoGPUContext.shared.renderQueue.async { self.processor = nil }
    }

    func initializeBlack(target: MTLTexture, commandBuffer: MTLCommandBuffer,
                         texture: LowLevelTexture) async -> Bool {
        await withCheckedContinuation { continuation in
            VideoGPUContext.shared.renderQueue.async {
                let encoded = Self.clearBlack(target, using: commandBuffer)
                commandBuffer.addCompletedHandler { completed in
                    withExtendedLifetime((texture, target)) {}
                    continuation.resume(returning: encoded && completed.status == .completed)
                }
                commandBuffer.commit()
            }
        }
    }

    func submit(frame: VideoFrameMailbox.Frame, state: VideoFrameMailbox.State,
                target: MTLTexture, commandBuffer: MTLCommandBuffer, texture: LowLevelTexture,
                completion: @escaping @MainActor (Bool, String?) -> Void) {
        VideoGPUContext.shared.renderQueue.async {
            let processor = self.processor
            let permitted = !self.stopped.withLock({ $0 })
                && self.frames.permitsRendering(consumerID: self.surfaceID, session: frame.session)
            let result = permitted ? processor?.encode(frame: frame, state: state,
                commandBuffer: commandBuffer, target: target) : nil
            // replace(using:) already promised this command buffer to RealityKit.
            // A revoked or failed submission must still initialize its texture
            // and commit, without acquiring another session's frame.
            if result == nil { _ = Self.clearBlack(target, using: commandBuffer) }
            #if !DISABLE_PERFORMANCE_COLLECTION
            let submitted = result != nil && frame.session.map {
                VideoQueueMetrics.shared.record(.submitted, session: $0)
            } == true
            if permitted, let session = frame.session {
                if let result {
                    // LowLevelTexture's internal texture pool is RealityKit-owned;
                    // this row describes persistent processor textures only.
                    VideoQueueMetrics.shared.resources(session: session, renderer: self.surfaceID,
                        count: result.ownedTextureCount, bytes: result.ownedTextureBytes)
                    if result.reusedOutput { VideoQueueMetrics.shared.record(.reusedOutput, session: session) }
                } else { VideoQueueMetrics.shared.record(.encodeFailed, session: session) }
            }
            #endif
            commandBuffer.addCompletedHandler { completed in
                // Includes both successful processing and any partially encoded
                // work preceding failure. No resource is released before GPU use.
                withExtendedLifetime((processor, texture, target, frame.pixelBuffer)) {}
                let success = result != nil && completed.status == .completed
                #if !DISABLE_PERFORMANCE_COLLECTION
                if submitted, let session = frame.session {
                    VideoQueueMetrics.shared.record(success ? .completed : .gpuFailed, session: session)
                    _ = frame.metrics?.gpuCompleted(success: success,
                        startSeconds: completed.gpuStartTime, endSeconds: completed.gpuEndTime)
                }
                #endif
                // GPU completion is not a RealityKit presentation timestamp.
                Task { @MainActor in completion(success, result?.status) }
            }
            commandBuffer.commit()
        }
    }

    private static func clearBlack(_ target: MTLTexture, using commandBuffer: MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        return true
    }
}
