//
//  MetalTextureView.swift
//  VisionRemotePS5
//
//  Direct GPU texture rendering using MTKView.
//  Optimized for displaying upscaled 4K content from MetalFX.
//

import GameController
import SwiftUI
import MetalKit
import CoreGraphics
import CoreVideo
import QuartzCore
import os

/// A narrow bridge for the Objective-C drawable queue, not general layer access.
/// The view configures its layer on MainActor. Only the shared serial render
/// queue calls nextDrawable(), then revalidates the returned texture size and
/// retains admitted drawables through their GPU command's lifetime.
private final class MetalDrawableSource: @unchecked Sendable {
    private let layer: CAMetalLayer

    @MainActor init(layer: CAMetalLayer) { self.layer = layer }

    func nextDrawable() -> CAMetalDrawable? { layer.nextDrawable() }
}

/// A SwiftUI view that renders an MTLTexture directly on GPU.
/// Optimized for high-resolution content with minimal CPU overhead.
struct MetalTextureView: UIViewRepresentable {
    let frames: VideoFrameMailbox
    var surfaceID: UUID? = nil
    var onFirstFrame: () -> Void = {}
    var onProcessingStatus: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = VideoGPUContext.shared.device
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = true
        
        // SDR Mode: Use standard BGRA8 format for SDR content
        // NOTE: bgra10_xr (EDR) expects linear/HDR values - using it with SDR content
        // (which has gamma encoding) causes washed-out colors
        // TODO: Switch to bgra10_xr when PS5 actually sends HDR (P010) content
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        DebugLog.print("[MetalTextureView] Using SDR pixel format: bgra8Unorm")
        
        // Request the display cadence; submit GPU work only for a new decoded frame.
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 120
        if let layer = mtkView.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
            context.coordinator.configureDrawableLayer(layer)
        }
        // Presentation resolution is selected from the decoded source and the
        // native size recommendation. Window points must not downscale a 4K
        // processed image to a smaller app-owned drawable.
        mtkView.autoResizeDrawable = false
        mtkView.drawableSize = CGSize(width: 2560, height: 1440)
        
        // visionOS turns gamepad presses into gaze + pinch events unless the view
        // hosting the CAMetalLayer declares that it handles them itself. Without
        // this interaction GCExtendedGamepad values never change while streaming.
        let gamepadInteraction = GCEventInteraction()
        gamepadInteraction.handledEventTypes = .gamepad
        mtkView.addInteraction(gamepadInteraction)
        
        return mtkView
    }
    
    func updateUIView(_ mtkView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.invalidate()
        uiView.isPaused = true
        uiView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, surfaceID: surfaceID, onFirstFrame: onFirstFrame, onProcessingStatus: onProcessingStatus)
    }

    class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        private let frames: VideoFrameMailbox
        private let surfaceID: UUID?
        private let active = OSAllocatedUnfairLock(initialState: true)
        private let onFirstFrame: () -> Void
        private let onProcessingStatus: (String) -> Void
        private var lastProcessingStatus: String?
        private var lastMode: UpscalerType?
        private var lastSharpness: Float?
        private var lastComparisonEnabled: Bool?
        private var lastComparisonPosition: Float?
        private var lastInspectionFrozen: Bool?
        private var lastInspectionZoom: Float?
        private var lastInspectionCenter: SIMD2<Float>?
        private var lastDrawableSize: CGSize?
        private let renderQueue = VideoGPUContext.shared.renderQueue
        // Never wait on main for GPU capacity. At most two command buffers in flight.
        private let capacity = DispatchSemaphore(value: 2)
        private let commandQueue = VideoGPUContext.shared.commandQueue
        @MainActor private var drawableSource: MetalDrawableSource?
        private var processor: VideoFrameProcessor?
        private var attemptedSetup = false
        private var lastFrameID: UInt64 = 0
        #if !DISABLE_PERFORMANCE_COLLECTION
        private var lastTimingReport: Double = 0
        private let rendererID = UUID()
        #endif
        private var lastDrawableWarning: Double = 0
        private var announcedFirstFrame = false
        #if DEBUG && !DISABLE_PERFORMANCE_COLLECTION
        private var queueStress = VideoQueueStress()
        private var queueStressSession: MetricSessionID?
        private let queueStressEnabled = ProcessInfo.processInfo.arguments.contains("-VideoQueueMetricsStress")
        #endif

        init(frames: VideoFrameMailbox, surfaceID: UUID?, onFirstFrame: @escaping () -> Void, onProcessingStatus: @escaping (String) -> Void) {
            self.frames = frames
            self.surfaceID = surfaceID
            self.onFirstFrame = onFirstFrame
            self.onProcessingStatus = onProcessingStatus
            super.init()
        }

        func invalidate() { active.withLock { $0 = false } }

        @MainActor func configureDrawableLayer(_ layer: CAMetalLayer) {
            drawableSource = MetalDrawableSource(layer: layer)
        }

        private func canRender() -> Bool {
            active.withLock { $0 } && frames.isSelectedConsumer(surfaceID)
        }

        private func canNotify(for frame: VideoFrameMailbox.Frame) -> Bool {
            active.withLock { $0 } && frames.permitsRendering(consumerID: surfaceID, session: frame.session)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle resize if needed
        }

        private static func presentationSize(for frame: VideoFrameMailbox.Frame,
                                             preferredSize: CGSize) -> CGSize? {
            // Clamp before converting to Int. A temporarily unavailable native
            // recommendation retains the already validated 1440p floor.
            func dimension(_ value: CGFloat, minimum: Int, maximum: Int) -> Int {
                guard value.isFinite else { return minimum }
                return Int(min(max(value, CGFloat(minimum)), CGFloat(maximum)).rounded(.up))
            }
            guard let dimensions = MetalFXUpscaler.outputDimensions(
                inputWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
                inputHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
                targetWidth: dimension(preferredSize.width, minimum: 2560, maximum: 3840),
                targetHeight: dimension(preferredSize.height, minimum: 1440, maximum: 2160)) else { return nil }
            return CGSize(width: dimensions.width, height: dimensions.height)
        }
        
        @MainActor
        func draw(in view: MTKView) {
            guard canRender() else { return }
            guard capacity.wait(timeout: .now()) == .success else {
                #if !DISABLE_PERFORMANCE_COLLECTION
                if let session = frames.diagnostics.session {
                    VideoQueueMetrics.shared.record(.busyDraw, session: session)
                }
                #endif
                return
            }
            guard let device = view.device,
                  let drawableSource else {
                capacity.signal()
                return
            }
            let candidate = frames.snapshotForRendering(consumerID: surfaceID)
            guard candidate.enabled, let candidateFrame = candidate.frame,
                  canNotify(for: candidateFrame) else { capacity.signal(); return }
            let preferredSize = view.preferredDrawableSize
            if let target = Self.presentationSize(for: candidateFrame, preferredSize: preferredSize),
               view.drawableSize != target {
                view.drawableSize = target
            }
            // A source outside the 2x allocation budget retains this bounded
            // target. The processor explicitly falls back to Native for it.
            let drawableSize = view.drawableSize
            renderQueue.async { [self] in
                autoreleasepool {
                    guard canRender() else { capacity.signal(); return }
                    if !attemptedSetup {
                        attemptedSetup = true
                        processor = VideoFrameProcessor(device: device)
                    }
                    #if DEBUG && !DISABLE_PERFORMANCE_COLLECTION
                    if queueStressEnabled, let session = frames.snapshot().frame?.session {
                        if queueStressSession != session {
                            queueStressSession = session
                            queueStress = VideoQueueStress()
                        }
                        let step = queueStress.step(now: CACurrentMediaTime())
                        if let phase = step.phaseChange {
                            DebugLog.print("[VideoQueueStress] session=\(session.logIdentifier) phase=\(phase) hostUs=\(StreamingMetricsClock.now()?.microseconds ?? 0)")
                        }
                        if step.skip {
                            VideoQueueMetrics.shared.record(.throttledDraw, session: session)
                            capacity.signal()
                            return
                        }
                    }
                    #endif
                    let state = frames.acquireForRendering(consumerID: surfaceID)
                    guard state.enabled, let frame = state.frame,
                          (frame.id != lastFrameID || state.mode != lastMode || state.sharpness != lastSharpness
                           || state.comparisonEnabled != lastComparisonEnabled
                           || state.comparisonPosition != lastComparisonPosition
                           || state.isInspectionFrozen != lastInspectionFrozen
                           || state.inspectionZoom != lastInspectionZoom
                           || state.inspectionCenter != lastInspectionCenter
                           || drawableSize != lastDrawableSize) else {
                        #if !DISABLE_PERFORMANCE_COLLECTION
                        if let session = state.frame?.session {
                            VideoQueueMetrics.shared.record(.idleDraw, session: session)
                        }
                        #endif
                        capacity.signal()
                        return
                    }
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    let session = frame.session
                    #endif
                    @discardableResult
                    func record(_ event: VideoQueueMetrics.Event) -> Bool {
                        #if DISABLE_PERFORMANCE_COLLECTION
                        return false
                        #else
                        guard let session else { return false }
                        return VideoQueueMetrics.shared.record(event, session: session)
                        #endif
                    }
                    guard let processor,
                          let commandBuffer = commandQueue?.makeCommandBuffer() else {
                        record(.encodeFailed)
                        capacity.signal()
                        return
                    }
                    // Drawable acquisition may block; it belongs on the renderer queue too.
                    guard let drawable = drawableSource.nextDrawable() else {
                        record(.drawableUnavailable)
                        let now = CACurrentMediaTime()
                        if now - lastDrawableWarning >= 2 {
                            lastDrawableWarning = now
                            DebugLog.print("[Video] No drawable available; latest decoded frame=\(frame.id)")
                        }
                        capacity.signal(); return
                    }
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    let reportTiming = CACurrentMediaTime() - lastTimingReport >= 2
                    if reportTiming { lastTimingReport = CACurrentMediaTime() }
                    #endif
                    // Revalidate after drawable acquisition, which can block while
                    // the coordinator synchronously selects another consumer.
                    guard canNotify(for: frame) else { capacity.signal(); return }
                    let expectedSize = Self.presentationSize(for: frame, preferredSize: preferredSize) ?? drawableSize
                    let actualSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
                    // A new decoded size or native recommendation may have changed
                    // the layer while this submission was queued. Retry on the next
                    // draw without caching this frame as rendered at the wrong size.
                    guard actualSize == expectedSize else { capacity.signal(); return }
                    guard let result = processor.encode(frame: frame, state: state,
                        commandBuffer: commandBuffer, target: drawable.texture) else {
                        record(.encodeFailed)
                        capacity.signal()
                        return
                    }
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    if result.reusedOutput { record(.reusedOutput) }
                    if let session {
                        VideoQueueMetrics.shared.resources(session: session, renderer: rendererID,
                            count: result.ownedTextureCount, bytes: result.ownedTextureBytes)
                    }
                    #endif
                    let status = result.status
                    let capacity = self.capacity
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    let recordedSubmission = record(.submitted)
                    #endif
                    commandBuffer.addCompletedHandler { completed in
                        #if !DISABLE_PERFORMANCE_COLLECTION
                        if recordedSubmission, let session {
                            VideoQueueMetrics.shared.record(completed.status == .completed ? .completed : .gpuFailed,
                                                            session: session)
                        }
                        #endif
                        capacity.signal()
                        #if !DISABLE_PERFORMANCE_COLLECTION
                        let gpuLatency = frame.metrics?.gpuCompleted(success: completed.status == .completed,
                            startSeconds: completed.gpuStartTime, endSeconds: completed.gpuEndTime)
                        #endif
                        if completed.status == .completed {
                            self.renderQueue.async {
                                guard self.canNotify(for: frame) else { return }
                                if self.lastProcessingStatus != status {
                                    self.lastProcessingStatus = status
                                    DebugLog.print("[Video] Processing: \(status)")
                                    DispatchQueue.main.async {
                                        guard self.canNotify(for: frame) else { return }
                                        self.onProcessingStatus(status)
                                    }
                                }
                                if !self.announcedFirstFrame {
                                    self.announcedFirstFrame = true
                                    DispatchQueue.main.async {
                                        guard self.canNotify(for: frame) else { return }
                                        self.onFirstFrame()
                                    }
                                }
                            }
                            #if !DISABLE_PERFORMANCE_COLLECTION
                            if reportTiming, let timing = frame.metrics, let gpuLatency {
                                DebugLog.print("[VideoMetrics] \(timing.logIdentifier) receive-to-GPU=\(String(format: "%.3f", gpuLatency.milliseconds))ms")
                            }
                            #endif
                        } else {
                            self.renderQueue.async {
                                if self.lastFrameID == frame.id { self.lastFrameID = 0 }
                            }
                            DebugLog.print("[Video] GPU command failed")
                        }
                    }
                    lastFrameID = frame.id
                    lastMode = state.mode
                    lastSharpness = state.sharpness
                    lastComparisonEnabled = state.comparisonEnabled
                    lastComparisonPosition = state.comparisonPosition
                    lastInspectionFrozen = state.isInspectionFrozen
                    lastInspectionZoom = state.inspectionZoom
                    lastInspectionCenter = state.inspectionCenter
                    lastDrawableSize = actualSize
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    drawable.addPresentedHandler { presented in
                        guard let timing = frame.metrics else { return }
                        let presentedSeconds = presented.presentedTime
                        let result = timing.presentationResult(atHostSeconds: presentedSeconds)
                        if reportTiming {
                            switch result {
                            case .success(let latency):
                                DebugLog.print("[VideoMetrics] \(timing.logIdentifier) receive-to-present=\(String(format: "%.3f", latency.milliseconds))ms (local pipeline only)")
                            case .failure(let reason):
                                DebugLog.print("[VideoMetrics] \(timing.logIdentifier) presentation sample rejected reason=\(reason.rawValue) presentedSeconds=\(presentedSeconds) receivedUs=\(timing.receivedAt.microseconds)")
                            }
                        }
                    }
                    #endif
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                }
            }
        }
    }
}
