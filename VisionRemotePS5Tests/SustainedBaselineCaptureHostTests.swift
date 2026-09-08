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
        var captures = 0
        await SustainedBaselineRunner.run(session: session, cancellation: BaselineCaptureCancellation(),
            capture: {
                defer { captures += 1 }
                return snapshot(video, at: 1 + UInt64(captures) * 5_000_000)
            }, sleep: {}, emit: { lines.append($0) })
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
        print("Sustained baseline capture tests passed")
    }
}
