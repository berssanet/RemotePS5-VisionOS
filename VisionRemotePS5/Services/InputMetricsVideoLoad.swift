#if DEBUG
import Foundation
import Metal
import os

/// Synthetic GPU/memory traffic for the input diagnostic, not video decoding.
/// Create and control this object outside the input polling path.
final class InputMetricsVideoLoad: @unchecked Sendable {
    struct Snapshot: Sendable {
        let submitted: UInt64
        let completed: UInt64
        let failed: UInt64
        let skipped: UInt64
    }

    private struct Counters {
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
        var failed: UInt64 = 0
        var skipped: UInt64 = 0
    }

    private static let bufferLength = 1920 * 1080 * 4
    private let commandQueue: MTLCommandQueue
    private let firstBuffer: MTLBuffer
    private let secondBuffer: MTLBuffer
    private let submissionQueue = DispatchQueue(
        label: "com.visionremote.ps5.input-metrics-video-load",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let capacity = DispatchSemaphore(value: 1)
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    // Accessed only on submissionQueue, except after exclusive destruction.
    private var timer: DispatchSourceTimer?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let firstBuffer = device.makeBuffer(
                length: Self.bufferLength, options: .storageModePrivate
              ),
              let secondBuffer = device.makeBuffer(
                length: Self.bufferLength, options: .storageModePrivate
              ) else { return nil }
        self.commandQueue = commandQueue
        self.firstBuffer = firstBuffer
        self.secondBuffer = secondBuffer
        commandQueue.label = "Input metrics synthetic GPU load"
        firstBuffer.label = "Input metrics synthetic buffer A"
        secondBuffer.label = "Input metrics synthetic buffer B"
        submissionQueue.setSpecific(key: queueKey, value: 1)
    }

    /// Repeated calls while running do nothing. Counters span this instance's life.
    func start() {
        onSubmissionQueue {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: submissionQueue)
            source.schedule(
                deadline: .now(), repeating: .nanoseconds(16_666_667),
                leeway: .milliseconds(1)
            )
            source.setEventHandler { [weak self] in self?.submitIfAvailable() }
            timer = source
            source.resume()
        }
    }

    /// When this returns, no further work is submitted until another start().
    /// A command already committed finishes independently; this never waits on GPU.
    func stop() {
        onSubmissionQueue {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    func snapshot() -> Snapshot {
        counters.withLock { state in
            Snapshot(
                submitted: state.submitted, completed: state.completed,
                failed: state.failed, skipped: state.skipped
            )
        }
    }

    private func onSubmissionQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            submissionQueue.sync(execute: body)
        }
    }

    private func submitIfAvailable() {
        guard timer != nil else { return }
        guard capacity.wait(timeout: .now()) == .success else {
            counters.withLock { $0.skipped += 1 }
            return
        }
        guard let command = commandQueue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            counters.withLock { $0.failed += 1 }
            capacity.signal()
            return
        }

        // 8,294,400 bytes filled, followed by eight full 8,294,400-byte copies.
        // One command in flight ensures these two private buffers are never raced.
        command.label = "Input metrics synthetic fill and eight copies"
        blit.fill(buffer: firstBuffer, range: 0..<Self.bufferLength, value: 0x7F)
        for index in 0..<8 {
            let source = index.isMultiple(of: 2) ? firstBuffer : secondBuffer
            let destination = index.isMultiple(of: 2) ? secondBuffer : firstBuffer
            blit.copy(
                from: source, sourceOffset: 0, to: destination,
                destinationOffset: 0, size: Self.bufferLength
            )
        }
        blit.endEncoding()
        command.addCompletedHandler { [self] completedCommand in
            // Retain this instance and its buffers until its own work completes,
            // including after stop() or replacement by a new diagnostic phase.
            let succeeded = completedCommand.status == .completed
            counters.withLock { state in
                if succeeded {
                    state.completed += 1
                } else {
                    state.failed += 1
                }
            }
            capacity.signal()
        }
        counters.withLock { $0.submitted += 1 }
        command.commit()
    }

    deinit {
        timer?.cancel()
    }
}
#endif
