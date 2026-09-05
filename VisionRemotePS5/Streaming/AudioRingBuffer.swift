import Foundation

/// Bounded PCM FIFO. Index changes and overwrite are protected by a short lock.
/// The real-time consumer uses try-lock and emits silence rather than waiting.
final class AudioRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let alignment: Int
    private let buffer: UnsafeMutablePointer<Int16>
    private let lock = NSLock()
    private var readPosition = 0
    private var stored = 0
    private var discarded = 0

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
        let position = (readPosition + stored) % capacity
        let first = min(amount, capacity - position)
        let newest = samples.advanced(by: aligned - amount)
        memcpy(buffer.advanced(by: position), newest, first * 2)
        if first < amount { memcpy(buffer, newest.advanced(by: first), (amount - first) * 2) }
        stored += amount
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
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        if stored > maximumBuffered {
            let keep = min(stored, max(count, targetBuffered))
            let drop = (stored - keep) / alignment * alignment
            readPosition = (readPosition + drop) % capacity
            stored -= drop
            discarded += drop
        }
        let amount = min(count - count % alignment, stored)
        let first = min(amount, capacity - readPosition)
        memcpy(destination, buffer.advanced(by: readPosition), first * 2)
        if first < amount { memcpy(destination.advanced(by: first), buffer, (amount - first) * 2) }
        readPosition = (readPosition + amount) % capacity
        stored -= amount
        return amount
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        readPosition = 0; stored = 0; discarded = 0
    }
}
