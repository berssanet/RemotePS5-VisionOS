import Foundation
import Synchronization
import os

/// The result of a local controller-state submission, not a network acknowledgement.
enum InputSendOutcome: Equatable, Sendable {
    case submitted
    case inactive
    case busy
    case failed(Int32)
}

/// Input keeps session identity without depending on a video frame or its clock endpoints.
enum InputMetricsSample: Equatable, Sendable {
    case tick(start: MetricTimestamp, end: MetricTimestamp,
              interval: MetricDuration?, workDuration: MetricDuration)
    case send(start: MetricTimestamp, end: MetricTimestamp,
              duration: MetricDuration, outcome: InputSendOutcome)
}

struct InputMetricsSnapshot: Sendable {
    let session: MetricSessionID
    let isActive: Bool
    /// Counts describe accepted collection events, including samples since overwritten.
    let ticks: UInt64
    let calls: UInt64
    let slowCalls: UInt64
    let errors: UInt64
    let busy: UInt64
    let inactive: UInt64
    /// Events omitted because collection was busy. Never included in timing percentiles.
    let missedSamples: UInt64
    let invalidSamples: UInt64
    let overwrittenSamples: UInt64
    /// Oldest to newest in recording order. Tick and send completions may interleave.
    let samples: [InputMetricsSample]

    /// Cursor for accepted collection events, rather than their asynchronous timestamps.
    var acceptedSampleCount: UInt64 {
        let sum = ticks.addingReportingOverflow(calls)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    /// Returns newly recorded samples that remain in the bounded ring. A delayed
    /// completion belongs to this recording batch even if its endpoints precede it.
    /// Keep a separate cursor per recorder; a larger previous cursor starts afresh.
    /// Events overwritten between snapshots cannot be recovered by this helper.
    func samplesRecorded(after previousCount: UInt64) -> [InputMetricsSample] {
        let currentCount = acceptedSampleCount
        guard previousCount <= currentCount else { return samples }
        let newlyRecorded = currentCount - previousCount
        let retainedNewCount = Int(min(newlyRecorded, UInt64(samples.count)))
        return Array(samples.suffix(retainedNewCount))
    }
}

/// A session owns this recorder for its entire lifetime; end() is terminal.
/// A fixed ring and a separate try-lock keep video/export contention off the input path.
/// Only initialization and explicit snapshot() allocate; record calls never format or log.
final class InputMetricsRecorder: Sendable {
    static let slowCallThresholdMicroseconds: UInt64 = 8_333
    let session: MetricSessionID

    private struct State {
        var active = true
        var slots: [InputMetricsSample?]
        var nextSlot = 0
        var count = 0
        var ticks: UInt64 = 0
        var calls: UInt64 = 0
        var slowCalls: UInt64 = 0
        var errors: UInt64 = 0
        var busy: UInt64 = 0
        var inactive: UInt64 = 0
        var invalid: UInt64 = 0
        var overwritten: UInt64 = 0

        mutating func append(_ sample: InputMetricsSample) {
            slots[nextSlot] = sample
            nextSlot = (nextSlot + 1) % slots.count
            if count < slots.count { count += 1 }
            else { InputMetricsRecorder.increment(&overwritten) }
        }
    }

    private let state: OSAllocatedUnfairLock<State>
    private let missed = Atomic<UInt64>(0)

    init(session: MetricSessionID, capacity: Int = 2_048) {
        precondition(capacity > 0)
        self.session = session
        state = OSAllocatedUnfairLock(initialState: State(slots: Array(repeating: nil, count: capacity)))
    }

    /// Called outside a tick. An already accepted event finishes before this returns.
    func end() {
        state.withLock { $0.active = false }
    }

    /// previous=nil starts a new interval chain (first tick or unavailable prior clock).
    /// An absent or reversed endpoint is rejected, never replaced by elapsed wall time.
    @discardableResult
    func recordTick(previous: MetricTimestamp?, start: MetricTimestamp?, end: MetricTimestamp?) -> Bool {
        let accepted = state.withLockIfAvailable { current -> Bool in
            guard current.active else { return false }
            guard let start, let end, end.microseconds >= start.microseconds,
                  previous == nil || previous!.microseconds <= start.microseconds else {
                Self.increment(&current.invalid)
                return false
            }
            let interval = previous.map { MetricDuration(microseconds: start.microseconds - $0.microseconds) }
            let work = MetricDuration(microseconds: end.microseconds - start.microseconds)
            current.append(.tick(start: start, end: end, interval: interval, workDuration: work))
            Self.increment(&current.ticks)
            return true
        }
        return finishCollection(accepted)
    }

    @discardableResult
    func recordSend(start: MetricTimestamp?, end: MetricTimestamp?, outcome: InputSendOutcome) -> Bool {
        let accepted = state.withLockIfAvailable { current -> Bool in
            guard current.active else { return false }
            guard let start, let end, end.microseconds >= start.microseconds else {
                Self.increment(&current.invalid)
                return false
            }
            let duration = MetricDuration(microseconds: end.microseconds - start.microseconds)
            current.append(.send(start: start, end: end, duration: duration, outcome: outcome))
            Self.increment(&current.calls)
            if duration.microseconds >= Self.slowCallThresholdMicroseconds {
                Self.increment(&current.slowCalls)
            }
            switch outcome {
            case .submitted: break
            case .inactive: Self.increment(&current.inactive)
            case .busy: Self.increment(&current.busy)
            case .failed: Self.increment(&current.errors)
            }
            return true
        }
        return finishCollection(accepted)
    }

    /// Copies into independent storage. Never call from an input tick/send callback.
    /// Concurrent missed-event accounting is observational, not a stop-the-world snapshot.
    func snapshot() -> InputMetricsSnapshot {
        state.withLock { current in
            let oldest = current.count == current.slots.count ? current.nextSlot : 0
            let samples = (0..<current.count).compactMap { offset in
                current.slots[(oldest + offset) % current.slots.count]
            }
            return InputMetricsSnapshot(session: session, isActive: current.active,
                ticks: current.ticks, calls: current.calls, slowCalls: current.slowCalls,
                errors: current.errors, busy: current.busy, inactive: current.inactive,
                missedSamples: missed.load(ordering: .relaxed), invalidSamples: current.invalid,
                overwrittenSamples: current.overwritten, samples: samples)
        }
    }

    private func finishCollection(_ accepted: Bool?) -> Bool {
        guard let accepted else {
            // One bounded atomic RMW, with no CAS retry loop. This diagnostic counter
            // wraps only after UInt64.max misses; it does not affect ring ownership.
            _ = missed.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        return accepted
    }

    private static func increment(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }

#if INPUT_METRICS_TESTING
    /// Host-only gate proves collection returns while another thread owns the lock.
    func withCollectionLockForTesting(_ body: @Sendable () -> Void) {
        state.withLock { _ in body() }
    }
#endif
}
