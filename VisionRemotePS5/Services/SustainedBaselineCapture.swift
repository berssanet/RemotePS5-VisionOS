import Foundation
import os

/// Explicit Native baseline only. Captures bounded retained windows; this does
/// not turn their percentiles into a distribution over the entire elapsed run.
/// The owner checks Native mode and current session in the capture closure.
@MainActor
final class SustainedBaselineCapture {
    enum Reason: String, Sendable { case sessionEnded, modeChanged, cancelled }

    private let session: MetricSessionID
    private let capture: @MainActor @Sendable () throws -> PerformanceReportSnapshot
    private let cancellation = BaselineCaptureCancellation()
    private var task: Task<Void, Never>?
    private var started = false

    init(session: MetricSessionID,
         capture: @escaping @MainActor @Sendable () throws -> PerformanceReportSnapshot) {
        self.session = session
        self.capture = capture
    }

    deinit {
        cancellation.cancel(.cancelled)
        task?.cancel()
    }

    func start() {
        guard !started, cancellation.reason == nil else { return }
        started = true
        let session = session
        let capture = capture
        let cancellation = cancellation
        task = Task {
            await SustainedBaselineRunner.run(session: session, cancellation: cancellation,
                                             capture: capture)
        }
    }

    func stop(reason: Reason = .sessionEnded) {
        cancellation.cancel(reason)
        task?.cancel()
    }
}

/// Emission is claimed under the same lock as cancellation. Once claimed, one
/// console write cannot be recalled; captureID + sequence + kind identify it.
/// No lock spans formatting or I/O, so stop() never waits for either operation.
final class BaselineCaptureCancellation: Sendable {
    private struct State {
        var reason: SustainedBaselineCapture.Reason?
        var terminalClaimed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var reason: SustainedBaselineCapture.Reason? { state.withLock { $0.reason } }

    func cancel(_ reason: SustainedBaselineCapture.Reason) {
        state.withLock {
            guard $0.reason == nil, !$0.terminalClaimed else { return }
            $0.reason = reason
        }
    }

    func claimCheckpointEmission() -> Bool {
        state.withLock { $0.reason == nil && !$0.terminalClaimed }
    }

    func claimTerminalEmission() -> Bool {
        state.withLock {
            guard !$0.terminalClaimed else { return false }
            $0.terminalClaimed = true
            return true
        }
    }
}

/// Pure host-clock state machine. Captured host time, never sleep count, proves
/// warmup and duration. A resumed app beyond 30 minutes cannot report success.
struct SustainedBaselineTimeline {
    static let warmupUs: UInt64 = 30_000_000
    static let minimumDurationUs: UInt64 = 1_200_000_000
    static let maximumDurationUs: UInt64 = 1_800_000_000
    static let maximumCaptureGapUs: UInt64 = 15_000_000
    static let maximumCaptures = 361

    enum Failure: String, Error, Sendable {
        case unavailableClock, regressedClock, inconsistentSession, inactiveSession
        case durationExceeded, captureLimit, captureFailed, formattingFailed
        case captureGapExceeded
    }

    struct Checkpoint: Sendable {
        let sequence: Int
        let startedHostUs: UInt64
        let capturedHostUs: UInt64
        let elapsedUs: UInt64
        var isComplete: Bool { elapsedUs >= SustainedBaselineTimeline.minimumDurationUs }
    }

    let session: MetricSessionID
    private(set) var captures = 0
    private(set) var sequence = 0
    private(set) var warmupHostUs: UInt64?
    private(set) var startedHostUs: UInt64?
    private(set) var capturedHostUs: UInt64?

    mutating func observe(_ snapshot: PerformanceReportSnapshot) throws -> Checkpoint? {
        guard captures < Self.maximumCaptures else { throw Failure.captureLimit }
        captures += 1
        guard snapshot.video.session == session else { throw Failure.inconsistentSession }
        guard snapshot.video.isActive else { throw Failure.inactiveSession }
        do { try PerformanceReportFormatter.validateSessions(snapshot) }
        catch { throw Failure.inconsistentSession }
        guard let now = snapshot.capturedAt?.microseconds else { throw Failure.unavailableClock }
        guard capturedHostUs == nil || now > capturedHostUs! else { throw Failure.regressedClock }
        // Applies during warmup too: suspension must not count as observed play.
        if let previous = capturedHostUs, now - previous > Self.maximumCaptureGapUs {
            throw Failure.captureGapExceeded
        }
        capturedHostUs = now
        if warmupHostUs == nil { warmupHostUs = now }
        if startedHostUs == nil {
            guard now - warmupHostUs! >= Self.warmupUs else { return nil }
            // Excessive suspension during warmup is not a fresh measured run.
            guard now - warmupHostUs! <= Self.maximumDurationUs else { throw Failure.durationExceeded }
            startedHostUs = now
        }
        let elapsed = now - startedHostUs!
        guard elapsed <= Self.maximumDurationUs else { throw Failure.durationExceeded }
        sequence += 1
        return Checkpoint(sequence: sequence, startedHostUs: startedHostUs!,
                          capturedHostUs: now, elapsedUs: elapsed)
    }
}

struct NativeBaselineRecord: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case checkpoint, completed, stopped, failed }
    let kind: Kind
    let captureID: String
    let session: String
    let sequence: Int
    let startedHostUs: UInt64?
    let capturedHostUs: UInt64?
    let elapsedUs: UInt64?
    let scope: String
    let processingMode: String
    let reportText: String?
    let reason: String?

    func line() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(self)
        return "[NativeBaseline] " + String(decoding: json, as: UTF8.self)
    }
}

enum SustainedBaselineRunner {
    /// Injected sleep/output are for deterministic host tests. Production has
    /// exactly one format/JSON/console task in flight and awaits its completion.
    @MainActor
    static func run(session: MetricSessionID, cancellation: BaselineCaptureCancellation,
                    capture: @escaping @MainActor @Sendable () throws -> PerformanceReportSnapshot,
                    sleep: @escaping @Sendable () async throws -> Void = {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    },
                    format: @escaping @Sendable (PerformanceReportSnapshot) throws -> String = {
                        try PerformanceReportFormatter.render($0, history: .latest)
                    },
                    emit: @escaping @Sendable (String) -> Void = { Swift.print($0) }) async {
        let captureID = UUID().uuidString
        var timeline = SustainedBaselineTimeline(session: session)
        var failure: SustainedBaselineTimeline.Failure?
        var completed = false

        for attempt in 0..<SustainedBaselineTimeline.maximumCaptures {
            guard cancellation.reason == nil, !Task.isCancelled else { break }
            if attempt > 0 {
                do { try await sleep() }
                catch { cancellation.cancel(.cancelled); break }
            }
            guard cancellation.reason == nil, !Task.isCancelled else { break }
            let snapshot: PerformanceReportSnapshot
            do { snapshot = try capture() }
            catch { failure = .captureFailed; break }

            let checkpoint: SustainedBaselineTimeline.Checkpoint?
            do { checkpoint = try timeline.observe(snapshot) }
            catch let reason as SustainedBaselineTimeline.Failure { failure = reason; break }
            catch { failure = .captureFailed; break }
            guard let checkpoint else { continue }

            let outcome = await Task.detached(priority: .utility) { () -> EmissionOutcome in
                guard cancellation.reason == nil else { return .cancelled }
                do {
                    let report = try format(snapshot)
                    let record = NativeBaselineRecord(kind: .checkpoint, captureID: captureID,
                        session: session.logIdentifier, sequence: checkpoint.sequence,
                        startedHostUs: checkpoint.startedHostUs, capturedHostUs: checkpoint.capturedHostUs,
                        elapsedUs: checkpoint.elapsedUs, scope: "retainedWindow", processingMode: "native",
                        reportText: report, reason: nil)
                    let line = try record.line()
                    guard cancellation.claimCheckpointEmission() else { return .cancelled }
                    emit(line)
                    return .emitted
                } catch { return .failed }
            }.value
            switch outcome {
            case .failed: failure = .formattingFailed
            case .cancelled: break
            case .emitted: completed = checkpoint.isComplete
            }
            if outcome != .emitted || completed { break }
        }

        if !completed, failure == nil, cancellation.reason == nil {
            if Task.isCancelled { cancellation.cancel(.cancelled) }
            else { failure = .captureLimit }
        }
        let finalTimeline = timeline
        let finalFailure = failure
        let finalCompleted = completed
        await Task.detached(priority: .utility) {
            guard cancellation.claimTerminalEmission() else { return }
            let stopReason = cancellation.reason
            let kind: NativeBaselineRecord.Kind = stopReason != nil ? .stopped
                : (finalCompleted ? .completed : .failed)
            let start = finalTimeline.startedHostUs
            let end = finalTimeline.capturedHostUs
            let record = NativeBaselineRecord(kind: kind, captureID: captureID,
                session: session.logIdentifier, sequence: finalTimeline.sequence,
                startedHostUs: start, capturedHostUs: end,
                elapsedUs: start.flatMap { begin in end.map { $0 - begin } },
                scope: "retainedWindow", processingMode: "native", reportText: nil,
                reason: stopReason?.rawValue ?? finalFailure?.rawValue)
            if let line = try? record.line() { emit(line) }
        }.value
    }

    private enum EmissionOutcome { case emitted, cancelled, failed }
}
