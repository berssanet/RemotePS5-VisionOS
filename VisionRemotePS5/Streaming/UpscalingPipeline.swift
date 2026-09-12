import Foundation
import Metal
import CoreVideo
import Combine
import os

/// Native mode avoids the extra 4K GPU passes. Settings change only on main.
enum UpscalerType: String, CaseIterable, Sendable {
    case native = "Original"
    case metalFX = "MetalFX"
    case enhanced = "Enhanced"
}

/// One decoded frame, replaced when the display falls behind. Never queues video in SwiftUI.
final class VideoFrameMailbox: @unchecked Sendable {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let receivedAt: UInt64
        let id: UInt64
        let metrics: VideoFrameMetrics?
        let session: MetricSessionID?
    }
    struct State {
        var enabled = false
        var frame: Frame?
        var nextID: UInt64 = 0
        var mode: UpscalerType = .native
        var sharpness: Float = 0.5
        var comparisonEnabled = false
        var comparisonPosition: Float = 0.5
        var isInspectionFrozen = false
        var inspectionZoom: Float = 1
        var inspectionCenter = SIMD2<Float>(repeating: 0.5)
    }

    struct Diagnostics: Sendable {
        var session: MetricSessionID?
        var isActive = false
        var published: UInt64 = 0
        var overwrittenBeforeAcquire: UInt64 = 0
        var acquiredFrames: UInt64 = 0
        var disabledSubmissions: UInt64 = 0
        var staleSubmissions: UInt64 = 0
        var clearedBeforeAcquire: UInt64 = 0
        var occupancy = 0
        var peakOccupancy = 0
        // Logical size of the single buffer retained here, not unique physical
        // memory: the renderer, decoder, or a snapshot can also retain it.
        var retainedPixelBytes = 0
        var peakRetainedPixelBytes = 0
        // The optional inspection image is one additional logical reference.
        // Latest-frame counters above still describe only the live mailbox slot.
        var inspectionFrameCount = 0
        var inspectionPixelBytes = 0
    }

    private struct Storage {
        var value = State()
        var diagnostics = Diagnostics()
        var frameWasAcquired = false
        var selectionRequired = false
        var selectedConsumer: UUID?
        var frozenFrame: Frame?
        var inspectionChanged: (@Sendable () -> Void)?

        func permits(_ consumer: UUID?) -> Bool {
            !selectionRequired || (consumer != nil && consumer == selectedConsumer)
        }

        func permitsSession(_ session: MetricSessionID?) -> Bool {
            diagnostics.session == session && (session == nil || diagnostics.isActive)
        }

        func renderingState(for consumer: UUID?) -> State {
            var result = value
            if !permits(consumer) {
                result.enabled = false
                result.frame = nil
            } else if let frozenFrame {
                result.frame = frozenFrame
            }
            return result
        }

        mutating func clearInspection() {
            frozenFrame = nil
            value.isInspectionFrozen = false
            #if !DISABLE_PERFORMANCE_COLLECTION
            diagnostics.inspectionFrameCount = 0
            diagnostics.inspectionPixelBytes = 0
            #endif
        }

        mutating func clearFrame() {
            #if !DISABLE_PERFORMANCE_COLLECTION
            if value.frame != nil && !frameWasAcquired {
                diagnostics.clearedBeforeAcquire &+= 1
            }
            frameWasAcquired = false
            diagnostics.occupancy = 0
            diagnostics.retainedPixelBytes = 0
            #endif
            value.frame = nil
            clearInspection()
        }
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: Storage())

    /// Session changes preserve display settings and rendering IDs. Counters
    /// describe only the new session, so releasing the old frame is not its drop.
    func beginSession(_ session: MetricSessionID) {
        let notify = state.withLockUnchecked { current -> (@Sendable () -> Void)? in
            let wasFrozen = current.value.isInspectionFrozen
            current.clearFrame()
            current.diagnostics = Diagnostics(session: session, isActive: true)
            return wasFrozen ? current.inspectionChanged : nil
        }
        notify?()
    }

    /// A delayed stop cannot release the current connection's frame.
    func endSession(_ session: MetricSessionID) {
        let notify = state.withLockUnchecked { current -> (@Sendable () -> Void)? in
            guard current.diagnostics.session == session else { return nil }
            let wasFrozen = current.value.isInspectionFrozen
            current.diagnostics.isActive = false
            current.clearFrame()
            return wasFrozen ? current.inspectionChanged : nil
        }
        notify?()
    }

    func submit(_ buffer: CVPixelBuffer, timestamp: UInt64,
                metrics: VideoFrameMetrics? = nil, session: MetricSessionID? = nil) {
        state.withLockUnchecked { current in
            if let activeSession = current.diagnostics.session {
                // The explicit identity also protects frames whose host clock
                // was unavailable and therefore have no VideoFrameMetrics.
                let submittedSession = session ?? metrics?.frame.session
                guard current.diagnostics.isActive, submittedSession == activeSession,
                      metrics == nil || metrics?.frame.session == activeSession else {
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    current.diagnostics.staleSubmissions &+= 1
                    #endif
                    return
                }
            }
            guard current.value.enabled else {
                #if !DISABLE_PERFORMANCE_COLLECTION
                current.diagnostics.disabledSubmissions &+= 1
                #endif
                return
            }
            #if !DISABLE_PERFORMANCE_COLLECTION
            if current.value.frame != nil && !current.frameWasAcquired {
                current.diagnostics.overwrittenBeforeAcquire &+= 1
            }
            #endif
            current.value.nextID &+= 1
            current.value.frame = Frame(pixelBuffer: buffer, receivedAt: timestamp,
                                        id: current.value.nextID, metrics: metrics,
                                        session: session ?? metrics?.frame.session)
            #if !DISABLE_PERFORMANCE_COLLECTION
            current.frameWasAcquired = false
            current.diagnostics.published &+= 1
            current.diagnostics.occupancy = 1
            current.diagnostics.peakOccupancy = 1
            current.diagnostics.retainedPixelBytes = CVPixelBufferGetDataSize(buffer)
            current.diagnostics.peakRetainedPixelBytes = max(
                current.diagnostics.peakRetainedPixelBytes,
                current.diagnostics.retainedPixelBytes)
            #endif
        }
    }

    /// Reading settings or diagnostics does not consume the pending frame.
    func snapshot() -> State { state.withLockUnchecked { $0.value } }
    var diagnostics: Diagnostics { state.withLockUnchecked { $0.diagnostics } }

    /// Renderer preview is read-only and respects both the selected consumer
    /// and the optional frozen image. Telemetry snapshot() stays on live video.
    func snapshotForRendering(consumerID: UUID? = nil) -> State {
        state.withLockUnchecked { $0.renderingState(for: consumerID) }
    }

    /// Called only for explicit freeze changes or lifecycle invalidation, never
    /// for per-frame publication. Observers run after releasing the mailbox lock.
    func observeInspectionChanges(_ observer: (@Sendable () -> Void)?) {
        state.withLockUnchecked { $0.inspectionChanged = observer }
    }

    @discardableResult
    func setInspectionFrozen(_ frozen: Bool) -> Bool {
        let change = state.withLockUnchecked { current -> (Bool, (@Sendable () -> Void)?) in
            let wasFrozen = current.value.isInspectionFrozen
            if frozen, current.value.enabled, let frame = current.value.frame,
               current.permitsSession(frame.session) {
                if current.frozenFrame == nil {
                    // Inspection redraws are not fresh delivery-latency samples.
                    current.frozenFrame = Frame(pixelBuffer: frame.pixelBuffer,
                        receivedAt: frame.receivedAt, id: frame.id, metrics: nil, session: frame.session)
                    current.value.isInspectionFrozen = true
                    #if !DISABLE_PERFORMANCE_COLLECTION
                    current.diagnostics.inspectionFrameCount = 1
                    current.diagnostics.inspectionPixelBytes = CVPixelBufferGetDataSize(frame.pixelBuffer)
                    #endif
                }
            } else { current.clearInspection() }
            let isFrozen = current.value.isInspectionFrozen
            return (isFrozen, wasFrozen != isFrozen ? current.inspectionChanged : nil)
        }
        change.1?()
        return change.0
    }

    /// Selecting a presentation never clears video or changes its generation.
    /// After the first selection, nil disables all consumers; it is no bypass.
    func selectConsumer(_ id: UUID?) {
        state.withLockUnchecked { current in
            current.selectionRequired = true
            current.selectedConsumer = id
        }
    }

    func isSelectedConsumer(_ id: UUID?) -> Bool {
        state.withLockUnchecked { $0.permits(id) }
    }

    /// Revalidate immediately before encoding or notifying an actor: an earlier
    /// snapshot may outlive a reconnect even when its consumer ID is unchanged.
    func permitsRendering(consumerID: UUID?, session: MetricSessionID?) -> Bool {
        state.withLockUnchecked { $0.value.enabled && $0.permits(consumerID) && $0.permitsSession(session) }
    }

    /// Captures and marks the exact frame in one critical section. Acquisition
    /// means handed to a renderer, not GPU completion or visible presentation.
    /// The last frame remains available for redraw without another acquisition.
    func acquireForRendering(consumerID: UUID? = nil) -> State {
        state.withLockUnchecked { current in
            let result = current.renderingState(for: consumerID)
            guard result.enabled, let displayedFrame = result.frame else { return result }
            #if !DISABLE_PERFORMANCE_COLLECTION
            // A frozen redraw must not consume a newer live frame merely
            // because both are retained by this mailbox.
            if current.value.frame?.id == displayedFrame.id && !current.frameWasAcquired {
                current.frameWasAcquired = true
                current.diagnostics.acquiredFrames &+= 1
            }
            #endif
            return result
        }
    }

    func configure(enabled: Bool, mode: UpscalerType, sharpness: Float,
                   comparisonEnabled: Bool = false, comparisonPosition: Float = 0.5,
                   inspectionZoom: Float = 1, inspectionCenter: SIMD2<Float> = .init(repeating: 0.5)) {
        let notify = state.withLockUnchecked { current -> (@Sendable () -> Void)? in
            let wasFrozen = current.value.isInspectionFrozen
            current.value.enabled = enabled
            current.value.mode = mode
            current.value.sharpness = sharpness
            current.value.comparisonEnabled = comparisonEnabled
            current.value.comparisonPosition = comparisonPosition.isFinite
                ? min(max(comparisonPosition, 0), 1) : 0.5
            // Restrict the inspection UI to bounded 1× / 2× / 4× magnification.
            let zoom: Float = inspectionZoom.isFinite
                ? (inspectionZoom >= 4 ? 4 : inspectionZoom >= 2 ? 2 : 1) : 1
            let inset = 0.5 / zoom
            current.value.inspectionZoom = zoom
            current.value.inspectionCenter = SIMD2<Float>(
                inspectionCenter.x.isFinite ? min(max(inspectionCenter.x, inset), 1 - inset) : 0.5,
                inspectionCenter.y.isFinite ? min(max(inspectionCenter.y, inset), 1 - inset) : 0.5)
            if !enabled { current.clearFrame() }
            return wasFrozen && !current.value.isInspectionFrozen ? current.inspectionChanged : nil
        }
        notify?()
    }
}

@MainActor
final class UpscalingPipeline: ObservableObject {
    static let shared = UpscalingPipeline()
    nonisolated let frames = VideoDelivery.shared
    @Published private(set) var isEnabled = false
    @Published var upscalerType: UpscalerType = UserDefaults.standard
        .string(forKey: "video_image_filter_v1").flatMap(UpscalerType.init(rawValue:)) ?? .metalFX {
        didSet {
            UserDefaults.standard.set(upscalerType.rawValue, forKey: "video_image_filter_v1")
            configure()
        }
    }
    @Published var sharpenStrength: Float = 0.5 { didSet { configure() } }
    @Published var comparisonEnabled = false { didSet { configure() } }
    @Published var comparisonPosition: Float = 0.5 { didSet { configure() } }
    @Published private(set) var inspectionFrozen = false
    @Published var inspectionZoom: Float = 1 { didSet { configure() } }
    @Published var inspectionCenter = SIMD2<Float>(repeating: 0.5) { didSet { configure() } }
    private init() {
        frames.observeInspectionChanges { [weak self] in
            Task { @MainActor [weak self] in self?.refreshInspectionState() }
        }
    }
    func initialize() {} // GPU resources are created lazily on the renderer queue.
    func enable() { isEnabled = true; configure() }
    func disable() { isEnabled = false; configure() }
    func setInspectionFrozen(_ frozen: Bool) {
        inspectionFrozen = frames.setInspectionFrozen(frozen)
    }
    private func refreshInspectionState() {
        // Read the current value rather than applying a possibly stale queued
        // notification from the session that just ended.
        inspectionFrozen = frames.snapshot().isInspectionFrozen
    }
    private func configure() {
        frames.configure(enabled: isEnabled, mode: upscalerType, sharpness: sharpenStrength,
                         comparisonEnabled: comparisonEnabled, comparisonPosition: comparisonPosition,
                         inspectionZoom: inspectionZoom, inspectionCenter: inspectionCenter)
        refreshInspectionState()
    }
}

 enum VideoDelivery {
    static let shared = VideoFrameMailbox()
}
