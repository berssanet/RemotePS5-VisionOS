import Foundation
import QuartzCore
import os

/// Host monotonic time, in integer microseconds (the decoder's existing unit).
/// Never initialize this with Date/Unix time or console/network timestamps.
/// Zero represents unavailable timing, including an unavailable presentedTime.
struct MetricTimestamp: Equatable, Sendable {
    let microseconds: UInt64

    init?(microseconds: UInt64) {
        guard microseconds > 0 else { return nil }
        self.microseconds = microseconds
    }

    /// Converts Core Animation/Metal host seconds, truncating below one microsecond.
    /// Guard before integer conversion: NaN, infinity and overflow must not trap.
    init?(hostSeconds: Double) {
        let scaled = hostSeconds * 1_000_000
        guard scaled.isFinite, scaled >= 1, scaled < Double(UInt64.max) else { return nil }
        self.microseconds = UInt64(scaled)
    }
}

/// Elapsed time, distinct from an absolute timestamp. Zero is a valid duration.
struct MetricDuration: Equatable, Sendable {
    let microseconds: UInt64
    var milliseconds: Double { Double(microseconds) / 1_000 }
    var seconds: Double { Double(microseconds) / 1_000_000 }
}

enum StreamingMetric: String, CaseIterable, Sendable {
    case receiveToDecode
    case receiveToGPUCompletion
    case receiveToPresentation
    case gpuExecution
    case inputTickInterval
    case inputSendDuration

    fileprivate var requiresFrame: Bool {
        switch self {
        case .receiveToDecode, .receiveToGPUCompletion, .receiveToPresentation, .gpuExecution:
            return true
        case .inputTickInterval, .inputSendDuration:
            return false
        }
    }
}

enum MetricIntervalError: Error, Equatable {
    case missingStart
    case missingEnd
    case reversedTimestamps
}

/// One validated interval. Live instrumentation and export are separate tasks.
struct MetricInterval: Equatable, Sendable {
    let metric: StreamingMetric
    let start: MetricTimestamp
    let end: MetricTimestamp
    let duration: MetricDuration

    init(metric: StreamingMetric, start: MetricTimestamp?, end: MetricTimestamp?) throws {
        guard let start else { throw MetricIntervalError.missingStart }
        guard let end else { throw MetricIntervalError.missingEnd }
        guard end.microseconds >= start.microseconds else {
            throw MetricIntervalError.reversedTimestamps
        }
        self.metric = metric
        self.start = start
        self.end = end
        // Subtract integers first, preserving small deltas at large host uptimes.
        duration = MetricDuration(microseconds: end.microseconds - start.microseconds)
    }
}

enum StreamingMetricsClock {
    /// Same host time basis as the existing decoder's CACurrentMediaTime stamps.
    /// This is not wall time and must not be mixed across hosts/boots.
    static func now() -> MetricTimestamp? {
        MetricTimestamp(hostSeconds: CACurrentMediaTime())
    }
}

/// Opaque identity; generated per start, independent of console/account identity.
struct MetricSessionID: Hashable, Sendable {
    fileprivate let value: UUID
    var logIdentifier: String { value.uuidString }
}

enum PresentationMetricError: String, Error, Sendable {
    case unavailableTimestamp
    case invalidTimestamp
    case beforeReceipt
    case inactiveSession
}

/// Captured at encoded-video callback entry and carried with the decoded buffer.
/// It keeps its original identity even after the recorder starts another session.
struct VideoFrameMetrics: Sendable {
    let frame: MetricFrameID
    let receivedAt: MetricTimestamp
    private let recorder: StreamingMetricsRecorder

    init?(recorder: StreamingMetricsRecorder, session: MetricSessionID,
          receivedAt: MetricTimestamp?) {
        guard let receivedAt, let frame = recorder.nextFrame(in: session) else { return nil }
        self.recorder = recorder
        self.frame = frame
        self.receivedAt = receivedAt
    }

    var logIdentifier: String { "session=\(frame.session.logIdentifier) frame=\(frame.sequence)" }

    @discardableResult
    func decoded(at timestamp: MetricTimestamp?) -> MetricDuration? {
        record(.receiveToDecode, start: receivedAt, end: timestamp)
    }

    /// GPU completion is recorded only for a successful command, using GPU host
    /// timestamps rather than the delayed CPU completion-callback arrival time.
    @discardableResult
    func gpuCompleted(success: Bool, startSeconds: Double, endSeconds: Double) -> MetricDuration? {
        guard success else { return nil }
        let start = MetricTimestamp(hostSeconds: startSeconds)
        let end = MetricTimestamp(hostSeconds: endSeconds)
        _ = record(.gpuExecution, start: start, end: end)
        return record(.receiveToGPUCompletion, start: receivedAt, end: end)
    }

    /// Call exclusively from a drawable's presented handler. Zero/skipped and
    /// invalid presentation times never become latency samples.
    @discardableResult
    func presented(atHostSeconds seconds: Double) -> MetricDuration? {
        try? presentationResult(atHostSeconds: seconds).get()
    }

    /// Diagnose the endpoint without replacing it with callback arrival time.
    /// Session acceptance is checked atomically by record, not by a snapshot.
    func presentationResult(atHostSeconds seconds: Double) -> Result<MetricDuration, PresentationMetricError> {
        guard seconds != 0 else { return .failure(.unavailableTimestamp) }
        guard let end = MetricTimestamp(hostSeconds: seconds) else {
            return .failure(.invalidTimestamp)
        }
        guard let interval = try? MetricInterval(metric: .receiveToPresentation, start: receivedAt, end: end) else {
            return .failure(.beforeReceipt)
        }
        guard recorder.record(interval, session: frame.session, frame: frame) else {
            return .failure(.inactiveSession)
        }
        return .success(interval.duration)
    }

    private func record(_ metric: StreamingMetric, start: MetricTimestamp?,
                        end: MetricTimestamp?) -> MetricDuration? {
        guard let interval = try? MetricInterval(metric: metric, start: start, end: end),
              recorder.record(interval, session: frame.session, frame: frame) else { return nil }
        return interval.duration
    }
}

/// Sequence numbers may restart in a new session; the full identity never does.
struct MetricFrameID: Hashable, Sendable {
    let session: MetricSessionID
    let sequence: UInt64
    fileprivate init(session: MetricSessionID, sequence: UInt64) {
        self.session = session
        self.sequence = sequence
    }
}

struct IdentifiedMetricInterval: Equatable, Sendable {
    let session: MetricSessionID
    let frame: MetricFrameID?
    let interval: MetricInterval
}

struct MetricSessionSnapshot: Sendable {
    let session: MetricSessionID
    let isActive: Bool
    /// Oldest to newest retained sample, in completion/recording order.
    let samples: [IdentifiedMetricInterval]
    let overwrittenSamples: UInt64
}

/// Atomic session validation and bounded storage. Async work must capture its
/// session/frame when scheduled, never look up a new session when it completes.
/// Video callbacks use this recorder; input instrumentation is a separate task.
final class StreamingMetricsRecorder: Sendable {
    private struct State {
        var session: MetricSessionID?
        var active = false
        var lastFrame: UInt64 = 0
        var slots: [IdentifiedMetricInterval?]
        var nextSlot = 0
        var count = 0
        var overwritten: UInt64 = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int = 256) {
        precondition(capacity > 0)
        #if DISABLE_PERFORMANCE_COLLECTION
        // Keep functional connection identity without allocating sample storage.
        state = OSAllocatedUnfairLock(initialState: State(slots: []))
        #else
        state = OSAllocatedUnfairLock(initialState: State(slots: Array(repeating: nil, count: capacity)))
        #endif
    }

    @discardableResult
    func beginSession() -> MetricSessionID {
        let session = MetricSessionID(value: UUID())
        state.withLock {
            $0 = State(session: session, active: true,
                       slots: Array(repeating: nil, count: $0.slots.count))
        }
        return session
    }

    /// A late stop from a previous connection cannot end the current session.
    func endSession(_ session: MetricSessionID) {
        state.withLock { if $0.session == session { $0.active = false } }
    }

    func nextFrame(in session: MetricSessionID) -> MetricFrameID? {
        #if DISABLE_PERFORMANCE_COLLECTION
        return nil
        #else
        state.withLock {
            guard $0.active, $0.session == session, $0.lastFrame < UInt64.max else { return nil }
            $0.lastFrame += 1
            return MetricFrameID(session: session, sequence: $0.lastFrame)
        }
        #endif
    }

    /// Rejects stale sessions and mismatched frame identities without changing
    /// samples. A check followed by a separate append would race with beginSession.
    @discardableResult
    func record(_ interval: MetricInterval, session: MetricSessionID,
                frame: MetricFrameID? = nil) -> Bool {
        #if DISABLE_PERFORMANCE_COLLECTION
        return false
        #else
        state.withLock {
            guard $0.active, $0.session == session else { return false }
            guard (frame != nil) == interval.metric.requiresFrame else { return false }
            if let frame {
                guard frame.session == session, frame.sequence > 0,
                      frame.sequence <= $0.lastFrame else { return false }
            }
            $0.slots[$0.nextSlot] = IdentifiedMetricInterval(session: session, frame: frame, interval: interval)
            $0.nextSlot = ($0.nextSlot + 1) % $0.slots.count
            if $0.count < $0.slots.count { $0.count += 1 }
            else if $0.overwritten < UInt64.max { $0.overwritten += 1 }
            return true
        }
        #endif
    }

    /// Copies are explicit, for inspection/export; never call on each input tick.
    /// A stopped session remains readable until the next beginSession replaces it.
    func snapshot() -> MetricSessionSnapshot? {
        state.withLock { current in
            guard let session = current.session else { return nil }
            let oldest = current.count == current.slots.count ? current.nextSlot : 0
            let samples = (0..<current.count).compactMap { offset in
                current.slots[(oldest + offset) % current.slots.count]
            }
            return MetricSessionSnapshot(session: session, isActive: current.active,
                                         samples: samples, overwrittenSamples: current.overwritten)
        }
    }
}
