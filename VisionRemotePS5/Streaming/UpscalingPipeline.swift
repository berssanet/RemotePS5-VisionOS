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
    }
    struct State {
        var enabled = false
        var frame: Frame?
        var nextID: UInt64 = 0
        var mode: UpscalerType = .native
        var sharpness: Float = 0.5
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    func submit(_ buffer: CVPixelBuffer, timestamp: UInt64) {
        state.withLockUnchecked {
            guard $0.enabled else { return }
            $0.nextID &+= 1
            $0.frame = Frame(pixelBuffer: buffer, receivedAt: timestamp, id: $0.nextID)
        }
    }
    func snapshot() -> State { state.withLockUnchecked { $0 } }
    func configure(enabled: Bool, mode: UpscalerType, sharpness: Float) {
        state.withLockUnchecked {
            $0.enabled = enabled
            $0.mode = mode
            $0.sharpness = sharpness
            if !enabled { $0.frame = nil }
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
