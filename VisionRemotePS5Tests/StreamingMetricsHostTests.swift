import Foundation
import CoreVideo

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func expectError(_ expected: MetricIntervalError,
                 start: MetricTimestamp?, end: MetricTimestamp?) {
    do {
        _ = try MetricInterval(metric: .receiveToPresentation, start: start, end: end)
        fatalError("Expected \(expected)")
    } catch let error as MetricIntervalError {
        check(error == expected, "Unexpected interval error: \(error)")
    } catch { fatalError("Unexpected error: \(error)") }
}

let start = MetricTimestamp(microseconds: 1_000_000)!
let end = MetricTimestamp(microseconds: 1_016_667)!
let interval = try MetricInterval(metric: .receiveToDecode, start: start, end: end)
check(interval.duration.microseconds == 16_667, "Integer delta")
check(abs(interval.duration.milliseconds - 16.667) < 1e-12, "Microseconds to ms")
check(abs(interval.duration.seconds - 0.016667) < 1e-12, "Microseconds to seconds")
check(MetricTimestamp(hostSeconds: 1.25)?.microseconds == 1_250_000, "Seconds to microseconds")
check(MetricTimestamp(hostSeconds: 1.0000005)?.microseconds == 1_000_000, "Sub-microsecond truncation")

for value: Double in [0, -1, -Double.leastNonzeroMagnitude, .nan, .infinity,
                      -.infinity, .greatestFiniteMagnitude, Double(UInt64.max) / 1_000_000] {
    check(MetricTimestamp(hostSeconds: value) == nil, "Reject invalid or overflowing host time")
}
check(MetricTimestamp(microseconds: 0) == nil, "Zero is unavailable, not a valid timestamp")
check(MetricTimestamp(hostSeconds: 0.0000005) == nil, "Sub-resolution near-zero timestamp")
expectError(.missingStart, start: nil, end: end)
expectError(.missingEnd, start: start, end: nil)
expectError(.reversedTimestamps, start: end, end: start)
expectError(.missingEnd, start: start, end: MetricTimestamp(hostSeconds: .nan))
expectError(.missingEnd, start: start, end: MetricTimestamp(hostSeconds: 0))
let zero = try MetricInterval(metric: .inputSendDuration, start: start, end: start)
check(zero.duration.microseconds == 0, "Equal timestamps are valid zero duration")

// Converting endpoints to Double before subtraction would erase this 1-us delta.
let large = try MetricInterval(metric: .inputTickInterval,
    start: MetricTimestamp(microseconds: UInt64.max - 1),
    end: MetricTimestamp(microseconds: UInt64.max))
check(large.duration.microseconds == 1, "Preserve tiny intervals at UInt64 boundary")
let widest = try MetricInterval(metric: .gpuExecution,
    start: MetricTimestamp(microseconds: 1), end: MetricTimestamp(microseconds: UInt64.max))
check(widest.duration.microseconds == UInt64.max - 1, "No subtraction overflow")
check(widest.duration.seconds.isFinite, "Finite duration conversion")

for metric in StreamingMetric.allCases {
    let sample = try MetricInterval(metric: metric, start: start, end: end)
    check(sample.metric == metric, "Preserve metric identity")
}
check(StreamingMetric.receiveToGPUCompletion != .receiveToPresentation,
      "GPU completion and presentation must remain separate metrics")

var previous = StreamingMetricsClock.now()!
for _ in 0..<1_000 {
    guard let current = StreamingMetricsClock.now() else { fatalError("Host clock unavailable") }
    check(current.microseconds >= previous.microseconds, "Host clock must not run backward")
    previous = current
}
print("PASS: metric units, truncation, invalid/missing/reversed intervals, zero duration, integer boundaries, monotonic clock")

let recorder = StreamingMetricsRecorder(capacity: 2)
check(recorder.snapshot() == nil, "No session before start")
let sessionA = recorder.beginSession()
let frameA = recorder.nextFrame(in: sessionA)!
check(recorder.record(interval, session: sessionA, frame: frameA), "Record initial session")

// Hold a real asynchronous callback across reconnection, then release it.
let callbackReady = DispatchSemaphore(value: 0)
let releaseCallback = DispatchSemaphore(value: 0)
let callbackDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    callbackReady.signal()
    releaseCallback.wait()
    check(!recorder.record(interval, session: sessionA, frame: frameA), "Reject late callback")
    recorder.endSession(sessionA)
    check(recorder.nextFrame(in: sessionA) == nil, "Old session cannot mint new frames")
    callbackDone.signal()
}
check(callbackReady.wait(timeout: .now() + 5) == .success, "Callback scheduled")
let sessionB = recorder.beginSession()
let frameB = recorder.nextFrame(in: sessionB)!
check(sessionA != sessionB && frameA != frameB, "Identities differ after restart")
check(frameA.sequence == frameB.sequence, "Sequence reuse is safe with session identity")
check(recorder.snapshot()!.samples.isEmpty, "Start removes previous-session data")
releaseCallback.signal()
check(callbackDone.wait(timeout: .now() + 5) == .success, "Callback completed")
check(recorder.snapshot()!.isActive, "Late stop cannot stop new session")
check(!recorder.record(interval, session: sessionB, frame: frameA), "Reject cross-session frame")
check(recorder.record(interval, session: sessionB, frame: frameB), "New-session callback accepted")

let frameB2 = recorder.nextFrame(in: sessionB)!
let frameB3 = recorder.nextFrame(in: sessionB)!
check(recorder.record(interval, session: sessionB, frame: frameB3), "Out-of-order frame completion")
check(recorder.record(interval, session: sessionB, frame: frameB2), "Earlier frame may complete later")
let full = recorder.snapshot()!
check(full.samples.map(\.frame) == [frameB3, frameB2], "Bounded completion order")
check(full.overwrittenSamples == 1, "Count overwritten retained sample")
recorder.endSession(sessionB)
check(!recorder.record(interval, session: sessionB), "No record after stop")
check(recorder.nextFrame(in: sessionB) == nil, "No frame after stop")
check(recorder.snapshot()!.samples == full.samples, "Keep stopped-session report")
let inputRecorder = StreamingMetricsRecorder()
let inputSession = inputRecorder.beginSession()
let inputFrame = inputRecorder.nextFrame(in: inputSession)!
check(inputRecorder.record(zero, session: inputSession), "Input sample needs only session identity")
check(!inputRecorder.record(zero, session: inputSession, frame: inputFrame), "Input must not be tied to video frame")
check(!inputRecorder.record(interval, session: inputSession), "Video sample must identify its frame")

// Exercise concurrent frame assignment, recording, and restart without assuming
// an ordering for competing writers. Only final-session samples may survive.
let stress = StreamingMetricsRecorder(capacity: 64)
let old = stress.beginSession()
let ready = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let done = DispatchGroup()
for _ in 0..<4 {
    done.enter()
    DispatchQueue.global().async {
        let frame = stress.nextFrame(in: old)!
        ready.signal()
        release.wait()
        for _ in 0..<500 { _ = stress.record(interval, session: old, frame: frame) }
        done.leave()
    }
}
for _ in 0..<4 { check(ready.wait(timeout: .now() + 5) == .success, "Writers ready") }
for _ in 0..<4 { release.signal() }
let fresh = stress.beginSession()
DispatchQueue.concurrentPerform(iterations: 64) { _ in
    let frame = stress.nextFrame(in: fresh)!
    check(stress.record(interval, session: fresh, frame: frame), "Concurrent current sample")
}
check(done.wait(timeout: .now() + 5) == .success, "Old writers completed")
let result = stress.snapshot()!
check(result.session == fresh && result.samples.count == 64, "Only current session retained")
check(result.samples.allSatisfy { $0.session == fresh && $0.frame?.session == fresh }, "No mixed data")
check(Set(result.samples.compactMap(\.frame)).count == 64, "Concurrent frame IDs unique")
let otherRecorder = StreamingMetricsRecorder()
let foreign = otherRecorder.beginSession()
check(!stress.record(interval, session: foreign), "Reject another recorder's session")
print("PASS: session/frame identity, late callbacks and stops, bounded storage, concurrent restart isolation")

let videoRecorder = StreamingMetricsRecorder(capacity: 32)
let videoSession = videoRecorder.beginSession()
let timing = VideoFrameMetrics(recorder: videoRecorder, session: videoSession, receivedAt: start)!
check(timing.decoded(at: end)?.microseconds == 16_667, "Decode endpoint")
check(timing.gpuCompleted(success: false, startSeconds: 1.02, endSeconds: 1.03) == nil, "Failed GPU not a completion")
check(timing.gpuCompleted(success: true, startSeconds: 0, endSeconds: 0) == nil, "Unavailable GPU times")
check(timing.gpuCompleted(success: true, startSeconds: 1.02, endSeconds: 1.03)?.microseconds == 30_000, "Use GPU endpoint")
check(!videoRecorder.snapshot()!.samples.contains { $0.interval.metric == .receiveToPresentation },
      "Completed GPU work does not imply presentation")
for invalid: Double in [0, .nan, .infinity, 0.99] {
    check(timing.presented(atHostSeconds: invalid) == nil, "Reject unavailable/invalid presentation")
}
check(timing.presented(atHostSeconds: 1.04)?.microseconds == 40_000, "Actual presentation endpoint")
let videoSamples = videoRecorder.snapshot()!.samples
check(videoSamples.map { $0.interval.metric } == [.receiveToDecode, .gpuExecution, .receiveToGPUCompletion, .receiveToPresentation],
      "Separate four stages with same captured identity")
check(videoSamples.allSatisfy { $0.frame == timing.frame }, "Correlate frame across stages")

let mailbox = VideoFrameMailbox()
mailbox.configure(enabled: true, mode: .native, sharpness: 0.5)
var pixel: CVPixelBuffer?
check(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, "Test buffer")
mailbox.submit(pixel!, timestamp: start.microseconds, metrics: timing)
let capturedFrame = mailbox.snapshot().frame!
check(capturedFrame.metrics?.frame == timing.frame, "Mailbox preserves identity")
let nextVideoSession = videoRecorder.beginSession()
check(capturedFrame.metrics?.decoded(at: end) == nil, "Late decoder after reconnect")
check(capturedFrame.metrics?.gpuCompleted(success: true, startSeconds: 1.02, endSeconds: 1.03) == nil, "Late GPU after reconnect")
check(capturedFrame.metrics?.presented(atHostSeconds: 1.04) == nil, "Late presentation after reconnect")
check(videoRecorder.snapshot()!.samples.isEmpty, "Old mailbox frame cannot contaminate new session")
let nextTiming = VideoFrameMetrics(recorder: videoRecorder, session: nextVideoSession, receivedAt: start)!
mailbox.submit(pixel!, timestamp: start.microseconds, metrics: nextTiming)
check(mailbox.snapshot().frame!.metrics?.frame == nextTiming.frame, "New frame retains new identity")
check(capturedFrame.metrics?.frame == timing.frame, "Already captured render work keeps old identity")
mailbox.configure(enabled: false, mode: .native, sharpness: 0.5)
check(mailbox.snapshot().frame == nil, "Disable releases retained frame")
print("PASS: video stage correlation, GPU versus presentation, mailbox propagation, late video callbacks")
