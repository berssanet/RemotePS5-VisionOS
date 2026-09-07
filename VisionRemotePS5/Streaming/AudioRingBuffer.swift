import Foundation
import Synchronization

/// Bounded PCM FIFO. Index changes and overwrite are protected by a short lock.
/// The real-time consumer uses try-lock and emits silence rather than waiting.
final class AudioRingBuffer: @unchecked Sendable {
    struct Diagnostics: Sendable {
        let availableSamples: Int
        let peakBufferedSamples: Int
        let capacity: Int
        /// Aligned producer input, including old input discarded by an oversized write.
        let writtenSamples: UInt64
        let readSamples: UInt64
        let overflowDiscardedSamples: UInt64
        let catchUpDiscardedSamples: UInt64
        let catchUpEvents: UInt64
        /// Positive read attempts, including the separately sampled contention count.
        let readCalls: UInt64
        let underflowReads: UInt64
        let missingSamples: UInt64
        /// Inclusive subsets of underflow/missing totals before the first aligned PCM write.
        let prePCMUnderflowReads: UInt64
        let prePCMMissingSamples: UInt64
        let underflowEpisodes: UInt64
        let recoveryEvents: UInt64
        /// These independent atomic totals may advance during a snapshot. They
        /// are not empty-buffer underflows and do not change recovery episodes.
        let contentionReads: UInt64
        let contentionRequestedSamples: UInt64
    }
    let capacity: Int
    private let alignment: Int
    private let buffer: UnsafeMutablePointer<Int16>
    private let lock = NSLock()
    private var readPosition = 0
    private var stored = 0
    private var discarded = 0
    private var peakBuffered = 0
    private var written: UInt64 = 0
    private var readSamples: UInt64 = 0
    private var overflowDiscarded: UInt64 = 0
    private var catchUpDiscarded: UInt64 = 0
    private var catchUpEvents: UInt64 = 0
    private var lockedReadCalls: UInt64 = 0
    private var underflowReads: UInt64 = 0
    private var missing: UInt64 = 0
    private var prePCMUnderflowReads: UInt64 = 0
    private var prePCMMissingSamples: UInt64 = 0
    private var underflowEpisodes: UInt64 = 0
    private var recoveryEvents: UInt64 = 0
    private var inUnderflow = false
    private let contentionReads = Atomic<UInt64>(0)
    private let contentionRequestedSamples = Atomic<UInt64>(0)

    init(capacity: Int, alignment: Int = 1) {
        precondition(capacity > 0 && alignment > 0 && capacity % alignment == 0)
        self.capacity = capacity
        self.alignment = alignment
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }
    deinit { buffer.deallocate() }
    var availableSamples: Int { lock.lock(); defer { lock.unlock() }; return stored }
    var discardedSamples: Int { lock.lock(); defer { lock.unlock() }; return discarded }
    /// Called off the render callback. PCM state is captured under its existing lock.
    var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        let contended = contentionReads.load(ordering: .relaxed)
        return Diagnostics(availableSamples: stored, peakBufferedSamples: peakBuffered, capacity: capacity,
            writtenSamples: written, readSamples: readSamples, overflowDiscardedSamples: overflowDiscarded,
            catchUpDiscardedSamples: catchUpDiscarded, catchUpEvents: catchUpEvents,
            readCalls: lockedReadCalls &+ contended, underflowReads: underflowReads, missingSamples: missing,
            prePCMUnderflowReads: prePCMUnderflowReads, prePCMMissingSamples: prePCMMissingSamples,
            underflowEpisodes: underflowEpisodes, recoveryEvents: recoveryEvents,
            contentionReads: contended,
            contentionRequestedSamples: contentionRequestedSamples.load(ordering: .relaxed))
    }

    @discardableResult
    func write(_ samples: UnsafePointer<Int16>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let aligned = count - count % alignment
        let amount = min(aligned, capacity)
        guard amount > 0 else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let drop = max(0, stored + amount - capacity)
        readPosition = (readPosition + drop) % capacity
        stored -= drop
        discarded += drop + aligned - amount
        written &+= UInt64(aligned)
        overflowDiscarded &+= UInt64(drop + aligned - amount)
        let position = (readPosition + stored) % capacity
        let first = min(amount, capacity - position)
        let newest = samples.advanced(by: aligned - amount)
        memcpy(buffer.advanced(by: position), newest, first * 2)
        if first < amount { memcpy(buffer, newest.advanced(by: first), (amount - first) * 2) }
        stored += amount
        peakBuffered = max(peakBuffered, stored)
        return amount
    }
    @discardableResult
    func write(_ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return write(base.assumingMemoryBound(to: Int16.self), count: raw.count / 2)
        }
    }

    /// Discard stale stereo frames as one operation when exceeding the latency ceiling.
    @discardableResult
    func read(_ destination: UnsafeMutablePointer<Int16>, count: Int,
              maximumBuffered: Int = Int.max, targetBuffered: Int = 0) -> Int {
        guard count > 0 else { return 0 }
        memset(destination, 0, count * 2)
        let requested = count - count % alignment
        guard lock.try() else {
            contentionReads.wrappingAdd(1, ordering: .relaxed)
            contentionRequestedSamples.wrappingAdd(UInt64(requested), ordering: .relaxed)
            return 0
        }
        defer { lock.unlock() }
        lockedReadCalls &+= 1
        if stored > maximumBuffered {
            let keep = min(stored, max(count, targetBuffered))
            let drop = (stored - keep) / alignment * alignment
            readPosition = (readPosition + drop) % capacity
            stored -= drop
            discarded += drop
            if drop > 0 {
                catchUpDiscarded &+= UInt64(drop)
                catchUpEvents &+= 1
            }
        }
        let amount = min(requested, stored)
        let first = min(amount, capacity - readPosition)
        memcpy(destination, buffer.advanced(by: readPosition), first * 2)
        if first < amount { memcpy(destination.advanced(by: first), buffer, (amount - first) * 2) }
        readPosition = (readPosition + amount) % capacity
        stored -= amount
        readSamples &+= UInt64(amount)
        if amount < requested {
            underflowReads &+= 1
            missing &+= UInt64(requested - amount)
            if written == 0 {
                prePCMUnderflowReads &+= 1
                prePCMMissingSamples &+= UInt64(requested - amount)
            }
            if !inUnderflow { underflowEpisodes &+= 1; inUnderflow = true }
        } else if requested > 0 && inUnderflow {
            recoveryEvents &+= 1
            inUnderflow = false
        }
        return amount
    }
    /// Both producer and real-time consumer must be stopped before resetting.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        readPosition = 0; stored = 0; discarded = 0
        peakBuffered = 0; written = 0; readSamples = 0
        overflowDiscarded = 0; catchUpDiscarded = 0; catchUpEvents = 0
        lockedReadCalls = 0; underflowReads = 0; missing = 0
        prePCMUnderflowReads = 0; prePCMMissingSamples = 0
        underflowEpisodes = 0; recoveryEvents = 0; inUnderflow = false
        contentionReads.store(0, ordering: .relaxed)
        contentionRequestedSamples.store(0, ordering: .relaxed)
    }

#if AUDIO_RING_BUFFER_TESTING
    /// Host harness only: force a producer/snapshot lock conflict deterministically.
    func withLockForTesting(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        body()
    }
#endif
}
