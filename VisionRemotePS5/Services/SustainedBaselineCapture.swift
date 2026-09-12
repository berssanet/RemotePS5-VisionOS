import Foundation
import os
import Darwin

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
        let captureID = UUID()
        // Initialization has no I/O. Only this explicitly started capture owns a sink.
        let sink = NativeBaselineFileSink(captureID: captureID)
        task = Task {
            await SustainedBaselineRunner.run(session: session, cancellation: cancellation,
                captureID: captureID, capture: capture,
                emit: { try await sink.append($0) }, status: { Swift.print($0) })
        }
    }

    func stop(reason: Reason = .sessionEnded) {
        cancellation.cancel(reason)
        task?.cancel()
    }
}

/// Emission is claimed under the same lock as cancellation. Once claimed, one
/// file write cannot be recalled; captureID + sequence + kind identify it.
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
        case outputFailed
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

/// One private file per opt-in capture. Checkpoints stay unpublished in .partial;
/// only a successful terminal write, sync, close and move publish the .ndjson.
/// All file operations run on actors, never on MainActor or streaming callbacks.
actor NativeBaselineFileSink {
    struct Limits: Sendable {
        static let maximumLineBytes = 64 * 1_024
        static let maximumLines = SustainedBaselineTimeline.maximumCaptures + 1
        static let maximumRunBytes = maximumLineBytes * maximumLines
        let lineBytes: Int
        let lines: Int
        let runBytes: Int

        init(lineBytes: Int = maximumLineBytes, lines: Int = maximumLines,
             runBytes: Int = maximumRunBytes) {
            self.lineBytes = min(max(lineBytes, 1), Self.maximumLineBytes)
            self.lines = min(max(lines, 1), Self.maximumLines)
            self.runBytes = min(max(runBytes, 1), Self.maximumRunBytes)
        }
    }

    /// The production operations are injectable only to exercise I/O failures.
    struct Operations: Sendable {
        var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
        var synchronize: @Sendable (FileHandle) throws -> Void = { try $0.synchronize() }
        var close: @Sendable (FileHandle) throws -> Void = { try $0.close() }
        var publish: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    }

    enum Failure: Error { case outputFailed }
    private let captureID: UUID
    private let directory: URL?
    private let limits: Limits
    private let operations: Operations
    private var handle: FileHandle?
    private var partialURL: URL?
    private var publishedURL: URL?
    private var session: String?
    private var lineCount = 0
    private var byteCount = 0
    private var busy = false
    private var ended = false

    init(captureID: UUID, directory: URL? = nil, limits: Limits = Limits(),
         operations: Operations = Operations()) {
        self.captureID = captureID
        self.directory = directory
        self.limits = limits
        self.operations = operations
    }

    deinit { try? handle?.close() }

    func append(_ line: String) async throws {
        guard !ended, !busy else { throw Failure.outputFailed }
        busy = true
        defer { busy = false }
        do {
            let prefix = "[NativeBaseline] "
            guard line.hasPrefix(prefix), !line.contains("\n"), !line.contains("\r"),
                  line.utf8.count < limits.lineBytes else { throw Failure.outputFailed }
            let record = try JSONDecoder().decode(NativeBaselineRecord.self,
                from: Data(line.dropFirst(prefix.count).utf8))
            guard record.captureID == captureID.uuidString, UUID(uuidString: record.session) != nil,
                  session == nil || session == record.session,
                  record.scope == "retainedWindow", record.processingMode == "native" else {
                throw Failure.outputFailed
            }
            let terminal = record.kind != .checkpoint
            // Re-encode the typed allowlist, never preserve unknown JSON properties.
            let data = Data((try record.line() + "\n").utf8)
            guard data.count <= limits.lineBytes, data.count <= limits.runBytes - byteCount,
                  lineCount < limits.lines, terminal || lineCount < limits.lines - 1 else {
                throw Failure.outputFailed
            }
            if handle == nil {
                let file = try await NativeBaselineFileDirectory.shared.create(captureID: captureID,
                                                                              directory: directory)
                handle = file.handle
                partialURL = file.partial
                publishedURL = file.published
            }
            guard let handle else { throw Failure.outputFailed }
            try operations.write(handle, data)
            session = record.session
            lineCount += 1
            byteCount += data.count
            if terminal {
                try operations.synchronize(handle)
                try operations.close(handle)
                self.handle = nil
                try operations.publish(partialURL!, publishedURL!)
                ended = true
            }
        } catch {
            ended = true
            try? handle?.close()
            handle = nil
            // A partial artifact is never published, including one whose terminal
            // bytes reached the cache before synchronize/close/publication failed.
            throw Failure.outputFailed
        }
    }
}

/// Serializes creation/retention across reconnects. Only canonical UUID names
/// carrying our filesystem ownership marker are candidates for removal.
/// The four-file bound also applies to old partials with an open handle. More
/// than four rapid reconnects can evict an old run; its later publication then
/// fails explicitly, preserving space for the newest capture without a registry.
private actor NativeBaselineFileDirectory {
    static let shared = NativeBaselineFileDirectory()
    private static let ownershipAttribute = "com.visionremote.native-baseline-v1"
    private static let retainedFiles = 4

    struct File: Sendable { let handle: FileHandle; let partial: URL; let published: URL }

    func create(captureID: UUID, directory: URL?) throws -> File {
        let manager = FileManager.default
        guard let folder = directory ?? manager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("NativeBaseline", isDirectory: true) else {
            throw NativeBaselineFileSink.Failure.outputFailed
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let directoryValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw NativeBaselineFileSink.Failure.outputFailed
        }
        let published = folder.appendingPathComponent(captureID.uuidString + ".ndjson")
        let partial = folder.appendingPathComponent(captureID.uuidString + ".ndjson.partial")
        guard !manager.fileExists(atPath: published.path), !manager.fileExists(atPath: partial.path) else {
            throw NativeBaselineFileSink.Failure.outputFailed
        }
        let candidates = try manager.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            .filter { url in
                let name = url.lastPathComponent
                let suffix = name.hasSuffix(".ndjson.partial") ? ".ndjson.partial" : ".ndjson"
                guard name.hasSuffix(suffix), let id = UUID(uuidString: String(name.dropLast(suffix.count))),
                      id.uuidString + suffix == name,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return false }
                var marker: UInt8 = 0
                return getxattr(url.path, Self.ownershipAttribute, &marker, 1, 0, XATTR_NOFOLLOW) == 1 && marker == 1
            }.sorted { first, second in
                let a = (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a == b ? first.lastPathComponent < second.lastPathComponent : a < b
            }
        for old in candidates.prefix(max(0, candidates.count - (Self.retainedFiles - 1))) {
            try manager.removeItem(at: old)
        }
        let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NativeBaselineFileSink.Failure.outputFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var marker: UInt8 = 1
        guard fsetxattr(descriptor, Self.ownershipAttribute, &marker, 1, 0, 0) == 0 else {
            try? handle.close()
            try? manager.removeItem(at: partial)
            throw NativeBaselineFileSink.Failure.outputFailed
        }
        return File(handle: handle, partial: partial, published: published)
    }
}

enum SustainedBaselineRunner {
    /// Injected sleep/output are for deterministic host tests. Production has
    /// exactly one format/JSON/output task in flight and awaits its completion.
    @MainActor
    static func run(session: MetricSessionID, cancellation: BaselineCaptureCancellation,
                    captureID: UUID = UUID(),
                    capture: @escaping @MainActor @Sendable () throws -> PerformanceReportSnapshot,
                    sleep: @escaping @Sendable () async throws -> Void = {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    },
                    format: @escaping @Sendable (PerformanceReportSnapshot) throws -> String = {
                        try PerformanceReportFormatter.render($0, history: .latest)
                    },
                    emit: @escaping @Sendable (String) async throws -> Void,
                    status: @escaping @Sendable (String) -> Void = { _ in }) async {
        let captureID = captureID.uuidString
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
                let line: String
                do {
                    let report = try format(snapshot)
                    let record = NativeBaselineRecord(kind: .checkpoint, captureID: captureID,
                        session: session.logIdentifier, sequence: checkpoint.sequence,
                        startedHostUs: checkpoint.startedHostUs, capturedHostUs: checkpoint.capturedHostUs,
                        elapsedUs: checkpoint.elapsedUs, scope: "retainedWindow", processingMode: "native",
                        reportText: report, reason: nil)
                    line = try record.line()
                } catch { return .formattingFailed }
                guard cancellation.claimCheckpointEmission() else { return .cancelled }
                do { try await emit(line) }
                catch { return .outputFailed }
                status(progress(captureID: captureID, sequence: checkpoint.sequence,
                    elapsedUs: checkpoint.elapsedUs, kind: .checkpoint, reason: nil))
                return .emitted
            }.value
            switch outcome {
            case .formattingFailed: failure = .formattingFailed
            case .outputFailed: failure = .outputFailed
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
            let kind: NativeBaselineRecord.Kind = finalFailure == .outputFailed ? .failed : stopReason != nil ? .stopped
                : (finalCompleted ? .completed : .failed)
            let start = finalTimeline.startedHostUs
            let end = finalTimeline.capturedHostUs
            let record = NativeBaselineRecord(kind: kind, captureID: captureID,
                session: session.logIdentifier, sequence: finalTimeline.sequence,
                startedHostUs: start, capturedHostUs: end,
                elapsedUs: start.flatMap { begin in end.map { $0 - begin } },
                scope: "retainedWindow", processingMode: "native", reportText: nil,
                reason: finalFailure == .outputFailed ? "outputFailed" : stopReason?.rawValue ?? finalFailure?.rawValue)
            do {
                try await emit(record.line())
                status(progress(captureID: captureID, sequence: record.sequence,
                    elapsedUs: record.elapsedUs, kind: kind, reason: record.reason))
            } catch {
                status(progress(captureID: captureID, sequence: record.sequence,
                    elapsedUs: record.elapsedUs, kind: .failed, reason: "outputFailed"))
            }
        }.value
    }

    private static func progress(captureID: String, sequence: Int, elapsedUs: UInt64?,
                                 kind: NativeBaselineRecord.Kind, reason: String?) -> String {
        "[NativeBaselineStatus] captureID=\(captureID) sequence=\(sequence) elapsedUs=\(elapsedUs.map(String.init) ?? "unavailable") kind=\(kind.rawValue)" + (reason.map { " reason=\($0)" } ?? "")
    }

    private enum EmissionOutcome { case emitted, cancelled, formattingFailed, outputFailed }
}
