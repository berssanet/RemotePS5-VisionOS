import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func session() -> MetricSessionID { StreamingMetricsRecorder().beginSession() }
func memory(_ hostUs: UInt64, footprint: UInt64? = nil) -> VideoQueueMetrics.MemorySample {
    VideoQueueMetrics.MemorySample(hostUs: hostUs, physicalFootprint: footprint,
        deviceAllocatedBytes: 1_024, ownedTextureCount: 2, ownedTextureBytes: 512,
        decoderSubmissions: 3, decoderPayloadBytes: 256, mailboxPixelBytes: 128)
}

let recorder = VideoQueueMetrics(memoryCapacity: 3)
let firstSession = session()
check(recorder.snapshot().session == nil && !recorder.snapshot().isActive,
      "Unstarted recorder has no inferred session")
recorder.recordMemory(memory(1), session: firstSession)
check(recorder.snapshot().memorySamples.isEmpty, "Unstarted recorder rejects memory")
recorder.beginSession(firstSession)
for value: UInt64 in 1...5 {
    recorder.recordMemory(memory(value, footprint: value == 4 ? nil : value * 100), session: firstSession)
}
let retained = recorder.snapshot()
check(retained.memorySamples.map(\.hostUs) == [3, 4, 5] && retained.overwrittenMemorySamples == 2,
      "Bounded memory ring retains latest samples in recording order")
check(retained.memorySamples[1].physicalFootprint == nil,
      "Unavailable physical footprint stays nil rather than becoming zero")
check(retained.memorySamples[2].physicalFootprint == 500 &&
      retained.memorySamples[2].deviceAllocatedBytes == 1_024 &&
      retained.memorySamples[2].ownedTextureCount == 2 &&
      retained.memorySamples[2].ownedTextureBytes == 512 &&
      retained.memorySamples[2].decoderSubmissions == 3 &&
      retained.memorySamples[2].decoderPayloadBytes == 256 &&
      retained.memorySamples[2].mailboxPixelBytes == 128,
      "Memory samples preserve separate units and accounting domains")
recorder.recordMemory(memory(6), session: firstSession)
check(retained.memorySamples.map(\.hostUs) == [3, 4, 5] && retained.overwrittenMemorySamples == 2,
      "Copied snapshot remains stable when the live ring advances")
check(recorder.snapshot().memorySamples.map(\.hostUs) == [4, 5, 6], "Live ring advances independently")
print("PASS: bounded memory history, recording order, overwrite accounting, optional footprint and snapshot ownership")

for event: VideoQueueMetrics.Event in [.busyDraw, .idleDraw, .throttledDraw, .drawableUnavailable, .encodeFailed, .reusedOutput] {
    recorder.record(event, session: firstSession)
}
recorder.record(.completed, session: firstSession)
recorder.record(.gpuFailed, session: firstSession)
check(recorder.snapshot().completed == 0 && recorder.snapshot().gpuFailures == 0,
      "Terminal events with no pending command do not invent completions")
recorder.record(.submitted, session: firstSession)
recorder.record(.submitted, session: firstSession)
recorder.record(.completed, session: firstSession)
recorder.record(.submitted, session: firstSession)
recorder.record(.gpuFailed, session: firstSession)
let events = recorder.snapshot()
check(events.busyDraws == 1 && events.idleDraws == 1 && events.throttledDraws == 1 &&
      events.drawableUnavailable == 1 && events.encodeFailures == 1 && events.reusedOutputs == 1,
      "Draw skips, acquisition/encoding failures and output reuse remain distinct")
check(events.submitted == 3 && events.completed == 1 && events.gpuFailures == 1 &&
      events.inFlight == 1 && events.peakInFlight == 2,
      "Submission and terminal events account for current and peak GPU work")
let renderer = UUID()
recorder.resources(session: firstSession, renderer: renderer, count: 2, bytes: 512)
check(recorder.snapshot().rendererID == renderer && recorder.snapshot().ownedTextureCount == 2 &&
      recorder.snapshot().ownedTextureBytes == 512, "Resources identify their reporting renderer")

recorder.endSession(firstSession)
recorder.endSession(firstSession)
for event: VideoQueueMetrics.Event in [.busyDraw, .idleDraw, .throttledDraw, .drawableUnavailable, .encodeFailed, .reusedOutput, .submitted] {
    recorder.record(event, session: firstSession)
}
recorder.resources(session: firstSession, renderer: UUID(), count: 99, bytes: 999)
recorder.recordMemory(memory(7), session: firstSession)
let ended = recorder.snapshot()
check(!ended.isActive && ended.submitted == 3 && ended.inFlight == 1 && ended.busyDraws == 1 &&
      ended.idleDraws == 1 && ended.throttledDraws == 1 && ended.drawableUnavailable == 1 &&
      ended.encodeFailures == 1 && ended.reusedOutputs == 1,
      "Ended session rejects fresh observations while retaining pending work")
check(ended.rendererID == renderer && ended.ownedTextureBytes == 512 &&
      ended.memorySamples.map(\.hostUs) == [4, 5, 6], "Ended session retains resource and memory evidence")
let unrelatedSession = session()
recorder.record(.completed, session: unrelatedSession)
check(recorder.snapshot().inFlight == 1, "Unrelated terminal event cannot drain an ended session")
recorder.record(.completed, session: firstSession)
recorder.record(.completed, session: firstSession)
recorder.record(.gpuFailed, session: firstSession)
check(recorder.snapshot().inFlight == 0 && recorder.snapshot().completed == 2 &&
      recorder.snapshot().gpuFailures == 1, "Matching terminal callback drains once without underflow")

let replacement = session()
recorder.beginSession(replacement)
let reset = recorder.snapshot()
check(reset.isActive && reset.session == replacement && reset.submitted == 0 && reset.completed == 0 &&
      reset.gpuFailures == 0 && reset.inFlight == 0 && reset.peakInFlight == 0 &&
      reset.memorySamples.isEmpty && reset.overwrittenMemorySamples == 0 && reset.rendererID == nil &&
      reset.ownedTextureCount == 0 && reset.ownedTextureBytes == 0,
      "Replacement session resets bounded evidence and all queue/resource counters")
recorder.record(.submitted, session: replacement)
recorder.endSession(firstSession)
for event: VideoQueueMetrics.Event in [.submitted, .completed, .gpuFailed, .reusedOutput, .busyDraw] {
    check(!recorder.record(event, session: firstSession), "Stale event explicitly reports rejection")
}
recorder.resources(session: firstSession, renderer: UUID(), count: 99, bytes: 999)
recorder.recordMemory(memory(8), session: firstSession)
let isolated = recorder.snapshot()
check(isolated.isActive && isolated.session == replacement && isolated.inFlight == 1 &&
      isolated.submitted == 1 && isolated.completed == 0 && isolated.gpuFailures == 0 &&
      isolated.reusedOutputs == 0 && isolated.busyDraws == 0 && isolated.rendererID == nil && isolated.memorySamples.isEmpty,
      "Late stop, resource, memory and terminal events from old session cannot change replacement")
recorder.record(.completed, session: replacement)
let failedAfterEnd = VideoQueueMetrics(memoryCapacity: 1)
failedAfterEnd.beginSession(replacement)
failedAfterEnd.record(.submitted, session: replacement)
failedAfterEnd.endSession(replacement)
failedAfterEnd.record(.gpuFailed, session: replacement)
check(failedAfterEnd.snapshot().gpuFailures == 1 && failedAfterEnd.snapshot().inFlight == 0,
      "A failed command also drains its matching ended session")
print("PASS: distinct renderer events, queue peaks, matching terminal drain and late-session isolation")

// A renderer may already hold a frame when stop happens. Its GPU command can
// finish later, but an unrecorded submission must not drain another command.
let stopRace = VideoQueueMetrics(memoryCapacity: 1)
let stopRaceSession = session()
stopRace.beginSession(stopRaceSession)
let recordedCommandA = stopRace.record(.submitted, session: stopRaceSession)
check(recordedCommandA, "Command A submission is accepted before stop")
stopRace.endSession(stopRaceSession)
let recordedCommandB = stopRace.record(.submitted, session: stopRaceSession)
check(!recordedCommandB, "Command B submission explicitly reports rejection after stop")
if recordedCommandB { stopRace.record(.completed, session: stopRaceSession) }
check(stopRace.snapshot().inFlight == 1 && stopRace.snapshot().submitted == 1 &&
      stopRace.snapshot().completed == 0,
      "Unrecorded command B callback preserves command A's pending accounting")
if recordedCommandA {
    check(stopRace.record(.completed, session: stopRaceSession),
          "Recorded command A terminal callback is accepted after stop")
}
check(stopRace.snapshot().inFlight == 0 && stopRace.snapshot().completed == 1,
      "Only command A drains its previously accepted submission")
check(!stopRace.record(.completed, session: stopRaceSession),
      "Terminal callback explicitly reports rejection when no work remains")
print("PASS: rejected post-stop submission cannot drain another command's accepted GPU work")

let concurrent = VideoQueueMetrics(memoryCapacity: 8)
let concurrentSession = session()
concurrent.beginSession(concurrentSession)
let workers = 4
let iterations = 1_000
DispatchQueue.concurrentPerform(iterations: workers) { worker in
    for index in 0..<iterations {
        concurrent.record(.submitted, session: concurrentSession)
        concurrent.record(.reusedOutput, session: concurrentSession)
        concurrent.record(.busyDraw, session: concurrentSession)
        concurrent.record(.idleDraw, session: concurrentSession)
        concurrent.recordMemory(memory(UInt64(worker * iterations + index + 1)), session: concurrentSession)
        concurrent.record(index % 5 == 0 ? .gpuFailed : .completed, session: concurrentSession)
    }
}
let stressed = concurrent.snapshot()
let total = UInt64(workers * iterations)
check(stressed.submitted == total && stressed.completed == total * 4 / 5 && stressed.gpuFailures == total / 5 &&
      stressed.reusedOutputs == total && stressed.busyDraws == total && stressed.idleDraws == total,
      "Concurrent writers preserve exact independent event totals")
check(stressed.inFlight == 0 && stressed.peakInFlight >= 1 && stressed.peakInFlight <= workers,
      "Concurrent command accounting drains with bounded peak from known producer concurrency")
check(stressed.memorySamples.count == 8 && stressed.overwrittenMemorySamples == total - 8 &&
      Set(stressed.memorySamples.map(\.hostUs)).count == 8,
      "Concurrent memory writes keep bounded storage and exact overwrite accounting")
print("PASS: concurrent renderer and memory events preserve counts, bounded storage and drained work")

#if DEBUG
var slowdown = VideoQueueStress()
for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
    let result = slowdown.step(now: invalid)
    check(!result.skip && result.phaseChange == nil, "Unavailable debug clock does not start or throttle test")
}
var phaseChanges: [String] = []
var phaseTimes: [Double] = []
var slowAdmissions: [Double] = []
var skipped = 0
for tick in 0...5_000 {
    let elapsed = Double(tick) / 100
    let now = 100 + elapsed
    let result = slowdown.step(now: now)
    if let phase = result.phaseChange {
        phaseChanges.append(phase)
        phaseTimes.append(elapsed)
    }
    if elapsed >= 15 && elapsed < 30 {
        if result.skip { skipped += 1 } else { slowAdmissions.append(now) }
    } else {
        check(!result.skip, "Baseline, recovery and completed test retain every draw admission")
    }
}
check(phaseChanges == ["baseline", "slowConsumer20Hz", "recovery", "complete"] && phaseTimes == [0, 15, 30, 45],
      "Finite slowdown changes phases at 15, 30 and 45 seconds exactly once")
check(skipped > 0 && slowAdmissions.count <= 300 && slowAdmissions.count >= 200,
      "Consumer slowdown admits bounded work without stopping video")
for (earlier, later) in zip(slowAdmissions, slowAdmissions.dropFirst()) {
    check(later - earlier >= 0.05 - 1e-9, "Slow consumer never admits faster than 20 Hz")
}
check(!slowdown.step(now: 10_000).skip && slowdown.step(now: 10_001).phaseChange == nil,
      "Completed diagnostic never resumes throttling")
print("PASS: fake-clock 15s baseline/20Hz slowdown/recovery/complete with unchanged normal draw cadence")
#endif

if let footprint = VideoQueueMetrics.physicalFootprint() {
    check(footprint > 0, "Available physical footprint must be positive")
    print("PASS: physical footprint available in bytes")
} else {
    print("PASS: physical footprint unavailable is optional")
}
