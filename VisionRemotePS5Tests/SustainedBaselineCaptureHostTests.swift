import Foundation
import os

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

func snapshot(_ video: StreamingMetricsRecorder, at micros: UInt64?) -> PerformanceReportSnapshot {
    PerformanceReportSnapshot(capturedAt: micros.flatMap(MetricTimestamp.init(microseconds:)),
                              video: video.snapshot()!)
}

func expectFailure(_ expected: SustainedBaselineTimeline.Failure,
                   _ body: () throws -> Void) {
    do { try body(); fatalError("Expected \(expected)") }
    catch let actual as SustainedBaselineTimeline.Failure { require(actual == expected, "Expected \(expected), got \(actual)") }
    catch { fatalError("Unexpected failure type") }
}

func advance(_ timeline: inout SustainedBaselineTimeline, video: StreamingMetricsRecorder,
             through endpoint: UInt64, step: UInt64 = 5_000_000) throws -> SustainedBaselineTimeline.Checkpoint? {
    var checkpoint: SustainedBaselineTimeline.Checkpoint?
    while timeline.capturedHostUs! < endpoint {
        checkpoint = try timeline.observe(snapshot(video, at: min(timeline.capturedHostUs! + step, endpoint)))
    }
    return checkpoint
}

final class CapturedLines: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ line: String) { storage.withLock { $0.append(line) } }
    var lines: [String] { storage.withLock { $0 } }
    var records: [NativeBaselineRecord] {
        lines.map {
            require($0.hasPrefix("[NativeBaseline] "), "Only allowlisted prefix emitted")
            require(!$0.contains("\n"), "A JSON checkpoint is exactly one physical line")
            return try! JSONDecoder().decode(NativeBaselineRecord.self,
                from: Data($0.dropFirst("[NativeBaseline] ".count).utf8))
        }
    }
}

@main
struct SustainedBaselineCaptureHostTests {
    @MainActor
    static func main() async {
        let video = StreamingMetricsRecorder()
        let session = video.beginSession()
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-sink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        var timeline = SustainedBaselineTimeline(session: session)
        require(try! timeline.observe(snapshot(video, at: 1)) == nil, "Initial snapshot starts warmup")
        require(try! advance(&timeline, video: video, through: 30_000_000) == nil, "29.999999 seconds is insufficient warmup")
        let first = try! timeline.observe(snapshot(video, at: 30_000_001))!
        require(first.sequence == 1 && first.elapsedUs == 0 && !first.isComplete, "Warmup endpoint starts measured duration")
        let before = try! advance(&timeline, video: video, through: 1_230_000_000)!
        require(!before.isComplete, "One microsecond before 20 minutes cannot complete")
        let complete = try! timeline.observe(snapshot(video, at: 1_230_000_001))!
        require(complete.isComplete && complete.elapsedUs == 1_200_000_000, "Exact 20 minutes completes")
        expectFailure(.regressedClock) { _ = try timeline.observe(snapshot(video, at: 1_230_000_001)) }
        expectFailure(.regressedClock) { _ = try timeline.observe(snapshot(video, at: 1)) }
        expectFailure(.unavailableClock) { _ = try timeline.observe(snapshot(video, at: nil)) }

        var warmupGap = SustainedBaselineTimeline(session: session)
        _ = try! warmupGap.observe(snapshot(video, at: 1))
        require(try! warmupGap.observe(snapshot(video, at: 15_000_001)) == nil, "Exactly 15 seconds is valid during warmup")
        expectFailure(.captureGapExceeded) { _ = try warmupGap.observe(snapshot(video, at: 30_000_002)) }
        require(warmupGap.capturedHostUs == 15_000_001 && warmupGap.startedHostUs == nil, "Rejected warmup gap cannot advance the baseline")
        var activeGap = SustainedBaselineTimeline(session: session)
        _ = try! activeGap.observe(snapshot(video, at: 1))
        _ = try! advance(&activeGap, video: video, through: 30_000_001)
        require(try! activeGap.observe(snapshot(video, at: 45_000_001))!.elapsedUs == 15_000_000, "Exactly 15 seconds is valid after warmup")
        expectFailure(.captureGapExceeded) { _ = try activeGap.observe(snapshot(video, at: 60_000_002)) }
        require(activeGap.capturedHostUs == 45_000_001, "Rejected capture gap leaves the last accepted clock intact")
        var upper = SustainedBaselineTimeline(session: session)
        _ = try! upper.observe(snapshot(video, at: 1))
        _ = try! advance(&upper, video: video, through: 30_000_001)
        require(try! advance(&upper, video: video, through: 1_830_000_001, step: 15_000_000)!.isComplete, "30-minute upper bound is inclusive")
        expectFailure(.durationExceeded) { _ = try upper.observe(snapshot(video, at: 1_830_000_002)) }

        let otherVideo = StreamingMetricsRecorder()
        let otherSession = otherVideo.beginSession()
        var mixed = SustainedBaselineTimeline(session: session)
        expectFailure(.inconsistentSession) { _ = try mixed.observe(snapshot(otherVideo, at: 1)) }
        var nested = snapshot(video, at: 1)
        nested.input = InputMetricsRecorder(session: otherSession).snapshot()
        expectFailure(.inconsistentSession) { _ = try mixed.observe(nested) }
        otherVideo.endSession(otherSession)
        var inactive = SustainedBaselineTimeline(session: otherSession)
        expectFailure(.inactiveSession) { _ = try inactive.observe(snapshot(otherVideo, at: 1)) }

        var finite = SustainedBaselineTimeline(session: session)
        for index in 1...SustainedBaselineTimeline.maximumCaptures {
            _ = try! finite.observe(snapshot(video, at: UInt64(index)))
        }
        expectFailure(.captureLimit) { _ = try finite.observe(snapshot(video, at: 1_000)) }

        let lines = CapturedLines()
        let progress = CapturedLines()
        let fileID = UUID()
        let fileDirectory = testRoot.appendingPathComponent("complete")
        let fileSink = NativeBaselineFileSink(captureID: fileID, directory: fileDirectory)
        require(!FileManager.default.fileExists(atPath: fileDirectory.path), "Sink initialization performs no I/O")
        var captures = 0
        await SustainedBaselineRunner.run(session: session, cancellation: BaselineCaptureCancellation(),
            captureID: fileID,
            capture: {
                defer { captures += 1 }
                return snapshot(video, at: 1 + UInt64(captures) * 5_000_000)
            }, sleep: {}, emit: { try await fileSink.append($0); lines.append($0) },
            status: { progress.append($0) })
        let records = lines.records
        require(captures == 247, "30-second warmup + 20 minutes uses 247 bounded captures")
        require(records.count == 242, "241 checkpoints and one terminal record")
        require(records.last!.kind == .completed && records.last!.elapsedUs == 1_200_000_000, "Completion uses captured clock")
        require(Set(records.map(\.captureID)).count == 1, "One opaque identifier joins a run")
        require(records.allSatisfy { $0.session == session.logIdentifier && $0.scope == "retainedWindow" && $0.processingMode == "native" }, "Explicit session and retained scope")
        let checkpoints = records.filter { $0.kind == .checkpoint }
        require(checkpoints.map(\.sequence) == Array(1...241), "Checkpoint identities are monotonic")
        require(checkpoints[0].reportText?.contains("session=\(session.logIdentifier)") == true, "Production formatter used")
        require(checkpoints[0].reportText?.contains("capturedHostUs=30000001") == true, "Report and envelope describe the same snapshot")
        let published = fileDirectory.appendingPathComponent(fileID.uuidString + ".ndjson")
        let fileLines = try! String(contentsOf: published, encoding: .utf8).split(separator: "\n").map(String.init)
        require(fileLines == lines.lines, "Every isolated file line round-trips without console interleaving")
        let decodedFile = CapturedLines()
        fileLines.forEach { decodedFile.append($0) }
        require(decodedFile.records.count == 242 && decodedFile.records.last!.kind == .completed,
                "Every stored checkpoint and terminal decodes")
        require(!FileManager.default.fileExists(atPath: published.path + ".partial"), "Only successful terminal publication removes partial")
        let permissions = try! FileManager.default.attributesOfItem(atPath: published.path)
        require((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Metric file is private")
        let directoryPermissions = try! FileManager.default.attributesOfItem(atPath: fileDirectory.path)
        require((directoryPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Metric directory is private")
        require(progress.lines.count == 242 && progress.lines.allSatisfy {
            $0.hasPrefix("[NativeBaselineStatus] ") && $0.utf8.count < 256 && !$0.contains("reportText") && !$0.contains("{")
        }, "Console progress is short and never carries JSON reports")
        require(progress.lines.last!.contains("kind=completed"), "Completed status follows successful publication")

        let preCancelled = BaselineCaptureCancellation()
        preCancelled.cancel(.modeChanged)
        preCancelled.cancel(.sessionEnded)
        let preLines = CapturedLines()
        var preCaptures = 0
        await SustainedBaselineRunner.run(session: session, cancellation: preCancelled,
            capture: { preCaptures += 1; return snapshot(video, at: 1) }, sleep: {}, emit: { preLines.append($0) })
        require(preCaptures == 0 && preLines.records.count == 1, "Stop-before-start captures no data")
        require(preLines.records[0].kind == .stopped && preLines.records[0].reason == "modeChanged", "First stop reason is terminal")

        var ownedCaptures = 0
        let owner = SustainedBaselineCapture(session: session) {
            ownedCaptures += 1
            return snapshot(video, at: 1)
        }
        owner.stop(reason: .modeChanged)
        owner.stop()
        owner.start()
        owner.start()
        await Task.yield()
        require(ownedCaptures == 0, "Public stop-before-start is terminal and idempotent")

        let lateCancellation = BaselineCaptureCancellation()
        let lateLines = CapturedLines()
        var lateCaptures = 0
        await SustainedBaselineRunner.run(session: session, cancellation: lateCancellation,
            capture: {
                defer { lateCaptures += 1 }
                return snapshot(video, at: 1 + UInt64(lateCaptures) * 5_000_000)
            }, sleep: {}, format: { _ in
                lateCancellation.cancel(.sessionEnded)
                return "secret-that-must-not-be-emitted\nlate-report"
            }, emit: { lateLines.append($0) })
        require(lateCaptures == 7 && lateLines.records.count == 1, "Late formatter output discarded before emission")
        require(lateLines.records[0].kind == .stopped && lateLines.records[0].reportText == nil, "Only fixed terminal emitted")
        require(!lateLines.lines.joined().contains("secret-that"), "Cancelled report does not reach output")

        let captureCancellation = BaselineCaptureCancellation()
        let captureLines = CapturedLines()
        await SustainedBaselineRunner.run(session: session, cancellation: captureCancellation,
            capture: {
                captureCancellation.cancel(.modeChanged)
                return snapshot(video, at: 1)
            }, sleep: {}, format: { _ in fatalError("Stopped capture must never reach formatting") },
            emit: { captureLines.append($0) })
        require(captureLines.records.count == 1 && captureLines.records[0].reason == "modeChanged",
                "Cancellation inside capture preserves only fixed terminal")

        enum PrivateFailure: Error { case secretPath }
        let failureLines = CapturedLines()
        await SustainedBaselineRunner.run(session: session, cancellation: BaselineCaptureCancellation(),
            capture: { throw PrivateFailure.secretPath }, sleep: {}, emit: { failureLines.append($0) })
        require(failureLines.records[0].reason == "captureFailed" && !failureLines.lines[0].contains("secretPath"), "Raw errors do not enter output")

        let gapLines = CapturedLines()
        var gapCaptures = 0
        await SustainedBaselineRunner.run(session: session, cancellation: BaselineCaptureCancellation(),
            capture: {
                defer { gapCaptures += 1 }
                return snapshot(video, at: gapCaptures == 0 ? 1 : 15_000_002)
            }, sleep: {}, emit: { gapLines.append($0) })
        require(gapCaptures == 2 && gapLines.records.count == 1, "Runner terminates at the excessive gap")
        require(gapLines.records[0].kind == .failed && gapLines.records[0].reason == "captureGapExceeded",
                "Gap failure emits the fixed label, never completion")

        let escaped = NativeBaselineRecord(kind: .checkpoint, captureID: "fixture", session: "fixture",
            sequence: 1, startedHostUs: 1, capturedHostUs: 2, elapsedUs: 1,
            scope: "retainedWindow", processingMode: "native", reportText: "one\ntwo\t\"quote\"\\slash", reason: nil)
        let escapedLines = CapturedLines()
        escapedLines.append(try! escaped.line())
        require(escapedLines.records[0].reportText == escaped.reportText, "JSON preserves text while escaping control characters")

        let claim = BaselineCaptureCancellation()
        require(claim.claimCheckpointEmission(), "Active checkpoint may begin emission")
        claim.cancel(.cancelled)
        require(!claim.claimCheckpointEmission(), "No new checkpoint begins after stop")
        require(claim.claimTerminalEmission() && !claim.claimTerminalEmission(), "Exactly one terminal emission")
        await testFileFailures(root: testRoot, video: video, session: session)
        await testLimitsAndRetention(root: testRoot, session: session)
        print("Sustained baseline capture tests passed")
    }

    static func fixture(_ id: UUID, session: MetricSessionID, kind: NativeBaselineRecord.Kind = .checkpoint,
                        report: String = "fixture") -> String {
        try! NativeBaselineRecord(kind: kind, captureID: id.uuidString, session: session.logIdentifier,
            sequence: 1, startedHostUs: 1, capturedHostUs: 1_200_000_001, elapsedUs: 1_200_000_000,
            scope: "retainedWindow", processingMode: "native",
            reportText: kind == .checkpoint ? report : nil, reason: nil).line()
    }

    static func expectOutputFailure(_ body: () async throws -> Void) async {
        do { try await body(); fatalError("Expected output failure") }
        catch NativeBaselineFileSink.Failure.outputFailed {}
        catch { fatalError("Raw I/O failure escaped the sink") }
    }

    @MainActor
    static func testFileFailures(root: URL, video: StreamingMetricsRecorder, session: MetricSessionID) async {
        enum SyntheticIOError: Error { case privatePath }
        for phase in ["write", "synchronize", "close", "publish"] {
            let id = UUID()
            let directory = root.appendingPathComponent(phase)
            var operations = NativeBaselineFileSink.Operations()
            switch phase {
            case "write": operations.write = { _, _ in throw SyntheticIOError.privatePath }
            case "synchronize": operations.synchronize = { _ in throw SyntheticIOError.privatePath }
            case "close": operations.close = { _ in throw SyntheticIOError.privatePath }
            default: operations.publish = { _, _ in throw SyntheticIOError.privatePath }
            }
            let sink = NativeBaselineFileSink(captureID: id, directory: directory, operations: operations)
            let statuses = CapturedLines()
            var captures = 0
            await SustainedBaselineRunner.run(session: session, cancellation: BaselineCaptureCancellation(),
                captureID: id, capture: {
                    defer { captures += 1 }
                    return snapshot(video, at: 1 + UInt64(captures) * 5_000_000)
                }, sleep: {}, format: { _ in "fixture" }, emit: { try await sink.append($0) },
                status: { statuses.append($0) })
            require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".ndjson").path),
                    "\(phase) failure never publishes a successful file")
            require(statuses.lines.last!.contains("kind=failed") && statuses.lines.last!.contains("reason=outputFailed"),
                    "\(phase) failure is explicitly reported")
            require(!statuses.lines.contains { $0.contains("kind=completed") || $0.contains("privatePath") },
                    "\(phase) failure cannot announce success or leak the raw error")
        }

        let occupied = root.appendingPathComponent("not-a-directory")
        try! Data("keep".utf8).write(to: occupied)
        // A matching UUID makes directory creation, not envelope validation, fail.
        let invalidID = UUID()
        let createFailure = NativeBaselineFileSink(captureID: invalidID, directory: occupied)
        await expectOutputFailure { try await createFailure.append(fixture(invalidID, session: session)) }
        require(try! String(contentsOf: occupied, encoding: .utf8) == "keep", "Creation failure preserves unrelated files")

        let lines = CapturedLines()
        var attempts = 0
        await SustainedBaselineRunner.run(session: session, cancellation: BaselineCaptureCancellation(), capture: {
            defer { attempts += 1 }
            return snapshot(video, at: 1 + UInt64(attempts) * 5_000_000)
        }, sleep: {}, emit: { line in
            let decoded = try JSONDecoder().decode(NativeBaselineRecord.self, from: Data(line.dropFirst("[NativeBaseline] ".count).utf8))
            if decoded.kind == .checkpoint { throw SyntheticIOError.privatePath }
            lines.append(line)
        })
        require(lines.records.count == 1 && lines.records[0].kind == .failed && lines.records[0].reason == "outputFailed",
                "Throwing emitter prevents completion and preserves fixed failed terminal when writable")
    }

    @MainActor
    static func testLimitsAndRetention(root: URL, session: MetricSessionID) async {
        let exactID = UUID()
        let exactLine = fixture(exactID, session: session)
        let exact = NativeBaselineFileSink(captureID: exactID, directory: root.appendingPathComponent("exact-line"),
            limits: .init(lineBytes: exactLine.utf8.count + 1))
        try! await exact.append(exactLine)
        try! await exact.append(fixture(exactID, session: session, kind: .completed))

        let largeID = UUID()
        let largeDirectory = root.appendingPathComponent("too-large")
        let large = NativeBaselineFileSink(captureID: largeID, directory: largeDirectory)
        await expectOutputFailure {
            try await large.append(fixture(largeID, session: session, report: String(repeating: "x", count: 65_536)))
        }
        require(!FileManager.default.fileExists(atPath: largeDirectory.path), "Oversized lines fail before creating a file")

        let countID = UUID()
        let count = NativeBaselineFileSink(captureID: countID, directory: root.appendingPathComponent("count"), limits: .init(lines: 3))
        try! await count.append(fixture(countID, session: session))
        try! await count.append(fixture(countID, session: session))
        await expectOutputFailure { try await count.append(fixture(countID, session: session)) }
        let reservedID = UUID()
        let reserved = NativeBaselineFileSink(captureID: reservedID, directory: root.appendingPathComponent("reserved"), limits: .init(lines: 3))
        try! await reserved.append(fixture(reservedID, session: session))
        try! await reserved.append(fixture(reservedID, session: session))
        try! await reserved.append(fixture(reservedID, session: session, kind: .completed))

        let bytesID = UUID()
        let checkpoint = fixture(bytesID, session: session)
        let terminal = fixture(bytesID, session: session, kind: .completed)
        let bytes = NativeBaselineFileSink(captureID: bytesID, directory: root.appendingPathComponent("bytes"),
            limits: .init(runBytes: checkpoint.utf8.count + terminal.utf8.count + 1))
        try! await bytes.append(checkpoint)
        await expectOutputFailure { try await bytes.append(terminal) }
        require(NativeBaselineFileSink.Limits.maximumLineBytes == 65_536
                && NativeBaselineFileSink.Limits.maximumLines == 362
                && NativeBaselineFileSink.Limits.maximumRunBytes == 23_724_032, "Production bounds are explicit")

        let folder = root.appendingPathComponent("retention")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unrelated = folder.appendingPathComponent(UUID().uuidString + ".ndjson")
        try! Data("keep".utf8).write(to: unrelated)
        let link = folder.appendingPathComponent(UUID().uuidString + ".ndjson")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        let malformedName = folder.appendingPathComponent("not-a-uuid.ndjson")
        try! Data("also-keep".utf8).write(to: malformedName)
        var created: [URL] = []
        for index in 0..<6 {
            let id = UUID()
            let sink = NativeBaselineFileSink(captureID: id, directory: folder)
            try! await sink.append(fixture(id, session: session))
            if index != 0 { try! await sink.append(fixture(id, session: session, kind: .completed)) }
            let path = folder.appendingPathComponent(id.uuidString + (index == 0 ? ".ndjson.partial" : ".ndjson"))
            try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: path.path)
            created.append(path)
        }
        require(created.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 4, "Retention bounds owned completed and abandoned partial files")
        require(!FileManager.default.fileExists(atPath: created[0].path) && !FileManager.default.fileExists(atPath: created[1].path), "Oldest owned runs removed")
        require(try! String(contentsOf: unrelated, encoding: .utf8) == "keep"
                && FileManager.default.fileExists(atPath: link.path)
                && FileManager.default.fileExists(atPath: malformedName.path), "Unmarked UUID files, symlinks and other names remain untouched")
        let retainedID = UUID(uuidString: created.last!.deletingPathExtension().lastPathComponent)!
        let duplicate = NativeBaselineFileSink(captureID: retainedID, directory: folder)
        let before = try! Data(contentsOf: created.last!)
        await expectOutputFailure { try await duplicate.append(fixture(retainedID, session: session)) }
        require(try! Data(contentsOf: created.last!) == before, "Existing UUID file is never overwritten")

        let wrongID = UUID()
        let wrong = NativeBaselineFileSink(captureID: wrongID, directory: root.appendingPathComponent("wrong-uuid"))
        await expectOutputFailure { try await wrong.append(fixture(UUID(), session: session)) }
        let linkedFolder = root.appendingPathComponent("linked-folder")
        try! FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: folder)
        let linkedID = UUID()
        let linkedSink = NativeBaselineFileSink(captureID: linkedID, directory: linkedFolder)
        await expectOutputFailure { try await linkedSink.append(fixture(linkedID, session: session)) }

        let liveFolder = root.appendingPathComponent("live-eviction")
        var liveIDs: [UUID] = []
        var liveSinks: [NativeBaselineFileSink] = []
        for index in 0..<5 {
            let id = UUID()
            let sink = NativeBaselineFileSink(captureID: id, directory: liveFolder)
            try! await sink.append(fixture(id, session: session))
            let path = liveFolder.appendingPathComponent(id.uuidString + ".ndjson.partial")
            try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: path.path)
            liveIDs.append(id)
            liveSinks.append(sink)
        }
        await expectOutputFailure {
            try await liveSinks[0].append(fixture(liveIDs[0], session: session, kind: .completed))
        }
        require(!FileManager.default.fileExists(atPath: liveFolder.appendingPathComponent(liveIDs[0].uuidString + ".ndjson").path),
                "Evicted open partial cannot publish completed")
        try! await liveSinks[4].append(fixture(liveIDs[4], session: session, kind: .completed))
        let newest = try! String(contentsOf: liveFolder.appendingPathComponent(liveIDs[4].uuidString + ".ndjson"), encoding: .utf8)
        require(newest.contains(liveIDs[4].uuidString) && !newest.contains(liveIDs[0].uuidString),
                "New capture publishes independently after old partial eviction")
    }
}
