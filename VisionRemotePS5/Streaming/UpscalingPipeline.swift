import Foundation
import Metal
import CoreVideo
import Combine
import os

/// Native mode avoids the extra 4K GPU passes. Settings change only on main.
enum UpscalerType: String, CaseIterable, Sendable {
    case native = "1080p"
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
    }

    private struct Storage {
        var value = State()
        var diagnostics = Diagnostics()
        var frameWasAcquired = false

        mutating func clearFrame() {
            if value.frame != nil && !frameWasAcquired {
                diagnostics.clearedBeforeAcquire &+= 1
            }
            value.frame = nil
            frameWasAcquired = false
            diagnostics.occupancy = 0
            diagnostics.retainedPixelBytes = 0
        }
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: Storage())

    /// Session changes preserve display settings and rendering IDs. Counters
    /// describe only the new session, so releasing the old frame is not its drop.
    func beginSession(_ session: MetricSessionID) {
        state.withLockUnchecked { current in
            current.clearFrame()
            current.diagnostics = Diagnostics(session: session, isActive: true)
        }
    }

    /// A delayed stop cannot release the current connection's frame.
    func endSession(_ session: MetricSessionID) {
        state.withLockUnchecked { current in
            guard current.diagnostics.session == session else { return }
            current.diagnostics.isActive = false
            current.clearFrame()
        }
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
                    current.diagnostics.staleSubmissions &+= 1
                    return
                }
            }
            guard current.value.enabled else {
                current.diagnostics.disabledSubmissions &+= 1
                return
            }
            if current.value.frame != nil && !current.frameWasAcquired {
                current.diagnostics.overwrittenBeforeAcquire &+= 1
            }
            current.value.nextID &+= 1
            current.value.frame = Frame(pixelBuffer: buffer, receivedAt: timestamp,
                                        id: current.value.nextID, metrics: metrics,
                                        session: session ?? metrics?.frame.session)
            current.frameWasAcquired = false
            current.diagnostics.published &+= 1
            current.diagnostics.occupancy = 1
            current.diagnostics.peakOccupancy = 1
            current.diagnostics.retainedPixelBytes = CVPixelBufferGetDataSize(buffer)
            current.diagnostics.peakRetainedPixelBytes = max(
                current.diagnostics.peakRetainedPixelBytes,
                current.diagnostics.retainedPixelBytes)
        }
    }

    /// Reading settings or diagnostics does not consume the pending frame.
    func snapshot() -> State { state.withLockUnchecked { $0.value } }
    var diagnostics: Diagnostics { state.withLockUnchecked { $0.diagnostics } }

    /// Captures and marks the exact frame in one critical section. Acquisition
    /// means handed to a renderer, not GPU completion or visible presentation.
    /// The last frame remains available for redraw without another acquisition.
    func acquireForRendering() -> State {
        state.withLockUnchecked { current in
            if current.value.frame != nil && !current.frameWasAcquired {
                current.frameWasAcquired = true
                current.diagnostics.acquiredFrames &+= 1
            }
            return current.value
        }
    }

    func configure(enabled: Bool, mode: UpscalerType, sharpness: Float) {
        state.withLockUnchecked { current in
            current.value.enabled = enabled
            current.value.mode = mode
            current.value.sharpness = sharpness
            if !enabled { current.clearFrame() }
        }
    }
}

@MainActor
final class UpscalingPipeline: ObservableObject {
    static let shared = UpscalingPipeline()
    nonisolated let frames = VideoDelivery.shared
    @Published private(set) var isEnabled = false
    @Published var upscalerType: UpscalerType = .native { didSet { configure() } }
    @Published var sharpenStrength: Float = 0.5 { didSet { configure() } }
    private init() {}
    func initialize() {} // GPU resources are created lazily on the renderer queue.
    func enable() { isEnabled = true; configure() }
    func disable() { isEnabled = false; configure() }
    private func configure() {
        frames.configure(enabled: isEnabled, mode: upscalerType, sharpness: sharpenStrength)
    }
}

 enum VideoDelivery {
    static let shared = VideoFrameMailbox()
}
