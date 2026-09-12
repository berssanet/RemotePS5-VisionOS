import Foundation
import Synchronization
import os

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func time(_ value: UInt64) -> MetricTimestamp { MetricTimestamp(microseconds: value)! }
func session() -> MetricSessionID { StreamingMetricsRecorder().beginSession() }

let input = InputMetricsRecorder(session: session(), capacity: 32)
check(input.recordTick(previous: nil, start: time(10_000), end: time(10_100)), "First tick needs no previous endpoint")
check(input.recordTick(previous: time(10_000), start: time(18_333), end: time(18_350)), "Normal tick")
check(input.recordTick(previous: time(18_333), start: time(40_000), end: time(40_000)), "Late tick and zero work")
let initial = input.snapshot()
check(initial.isActive && initial.ticks == 3 && initial.calls == 0, "Independent tick counters")
check(initial.samples == [
    .tick(start: time(10_000), end: time(10_100), interval: nil, workDuration: MetricDuration(microseconds: 100)),
    .tick(start: time(18_333), end: time(18_350), interval: MetricDuration(microseconds: 8_333), workDuration: MetricDuration(microseconds: 17)),
    .tick(start: time(40_000), end: time(40_000), interval: MetricDuration(microseconds: 21_667), workDuration: MetricDuration(microseconds: 0))
], "Tick interval measures successive starts; work measures current callback")

check(input.recordSend(start: time(1_000), end: time(9_332), outcome: .submitted), "Below slow threshold")
check(input.recordSend(start: time(1_000), end: time(9_333), outcome: .failed(-42)), "At slow threshold, retain error code")
check(input.recordSend(start: time(1_000), end: time(1_010), outcome: .busy), "Busy call")
check(input.recordSend(start: time(1_000), end: time(1_001), outcome: .inactive), "Inactive call")
check(input.recordSend(start: time(UInt64.max - 1), end: time(UInt64.max), outcome: .submitted), "Integer boundary precision")
let outcomes = input.snapshot()
check(outcomes.calls == 5 && outcomes.slowCalls == 1 && outcomes.errors == 1 && outcomes.busy == 1 && outcomes.inactive == 1,
      "Outcomes separate attempted local submission from successful submission")
check(outcomes.samples[4] == .send(start: time(1_000), end: time(9_333), duration: MetricDuration(microseconds: 8_333), outcome: .failed(-42)),
      "Failed sample retains duration and native code")

check(!input.recordTick(previous: nil, start: nil, end: time(2)), "Missing tick start")
check(!input.recordTick(previous: nil, start: time(1), end: nil), "Missing tick end")
check(!input.recordTick(previous: nil, start: time(2), end: time(1)), "Reversed work interval")
check(!input.recordTick(previous: time(3), start: time(2), end: time(4)), "Reversed previous start")
check(!input.recordSend(start: nil, end: time(2), outcome: .submitted), "Missing send start")
check(!input.recordSend(start: time(1), end: nil, outcome: .submitted), "Missing send end")
check(!input.recordSend(start: time(2), end: time(1), outcome: .failed(7)), "Reversed send interval")
let invalid = input.snapshot()
check(invalid.invalidSamples == 7 && invalid.samples == outcomes.samples, "Invalid observations do not fabricate intervals")
check(invalid.calls == 5 && invalid.errors == 1, "Rejected events excluded from valid counters")
print("PASS: tick intervals/work, slow threshold, local outcomes, invalid clocks and integer precision")

let bounded = InputMetricsRecorder(session: session(), capacity: 2)
for value: UInt64 in 1...5 {
    check(bounded.recordSend(start: time(value), end: time(value + 1), outcome: .submitted), "Ring accepts replacement")
}
let saved = bounded.snapshot()
check(saved.samples.count == 2 && saved.calls == 5 && saved.overwrittenSamples == 3, "Bounded ring keeps aggregate accepted counters")
check(saved.samples == [
    .send(start: time(4), end: time(5), duration: MetricDuration(microseconds: 1), outcome: .submitted),
    .send(start: time(5), end: time(6), duration: MetricDuration(microseconds: 1), outcome: .submitted)
], "Ring snapshots are oldest to newest")
check(bounded.recordSend(start: time(6), end: time(7), outcome: .busy), "Record after snapshot")
check(saved.samples.count == 2 && saved.calls == 5, "Snapshot owns independent sample storage")
bounded.end()
bounded.end()
let stopped = bounded.snapshot()
check(!bounded.recordTick(previous: nil, start: time(10), end: time(11)), "Late tick rejected")
check(!bounded.recordSend(start: time(10), end: time(11), outcome: .failed(1)), "Late send rejected")
check(!stopped.isActive && bounded.snapshot().samples == stopped.samples && bounded.snapshot().errors == 0, "Terminal stop preserves retained samples")

let callbackReady = DispatchSemaphore(value: 0)
let releaseCallback = DispatchSemaphore(value: 0)
let callbackDone = DispatchSemaphore(value: 0)
let old = InputMetricsRecorder(session: session())
DispatchQueue.global().async {
    callbackReady.signal()
    releaseCallback.wait()
    check(!old.recordSend(start: time(1), end: time(2), outcome: .submitted), "Old callback cannot record after stop")
    old.end()
    callbackDone.signal()
}
check(callbackReady.wait(timeout: .now() + 2) == .success, "Old callback ready")
old.end()
let next = InputMetricsRecorder(session: session())
check(next.recordSend(start: time(1), end: time(2), outcome: .submitted), "New recorder independent")
releaseCallback.signal()
check(callbackDone.wait(timeout: .now() + 2) == .success, "Late callback returns")
check(old.session != next.session && old.snapshot().samples.isEmpty && next.snapshot().calls == 1 && next.snapshot().isActive,
      "Old callback and stop cannot mutate new session")
print("PASS: bounded retention, snapshot ownership, terminal stop and late-session isolation")

// Reporting batches follow accepted recording order, not timestamp-window containment.
let batches = InputMetricsRecorder(session: session(), capacity: 3)
check(batches.recordTick(previous: nil, start: time(4_000_000), end: time(4_100_000)), "Initial report sample")
let beforeBoundary = batches.snapshot()
check(beforeBoundary.acceptedSampleCount == 1, "Reporting cursor counts accepted ticks")
check(batches.recordSend(start: time(4_900_000), end: time(5_100_000), outcome: .submitted), "Call crosses report boundary")
let afterBoundary = batches.snapshot()
check(afterBoundary.acceptedSampleCount == 2 && afterBoundary.samplesRecorded(after: beforeBoundary.acceptedSampleCount) == [
    .send(start: time(4_900_000), end: time(5_100_000), duration: MetricDuration(microseconds: 200_000), outcome: .submitted)
], "Boundary-crossing call belongs to the next recording batch")
check(batches.recordSend(start: time(1_000_000), end: time(1_000_001), outcome: .failed(-8)), "Late completion has old endpoints")
let afterLateCompletion = batches.snapshot()
check(afterLateCompletion.samplesRecorded(after: afterBoundary.acceptedSampleCount) == [
    .send(start: time(1_000_000), end: time(1_000_001), duration: MetricDuration(microseconds: 1), outcome: .failed(-8))
], "Late recorded sample is not excluded by its endpoint timestamps")
check(afterLateCompletion.samplesRecorded(after: afterLateCompletion.acceptedSampleCount).isEmpty,
      "Advancing cursor reports late completion exactly once")
let beforeOverwrites = afterLateCompletion.acceptedSampleCount
for value: UInt64 in 10...13 {
    check(batches.recordSend(start: time(value), end: time(value + 1), outcome: .submitted), "More events than retained capacity")
}
let afterOverwrites = batches.snapshot()
check(afterOverwrites.samplesRecorded(after: beforeOverwrites) == afterOverwrites.samples && afterOverwrites.samples.count == 3,
      "Lost overwritten events do not invent samples; batch contains only retained suffix")
check(afterOverwrites.samplesRecorded(after: afterOverwrites.acceptedSampleCount).isEmpty,
      "Repeating snapshot with same cursor produces no duplicate samples")
check(afterOverwrites.samplesRecorded(after: afterOverwrites.acceptedSampleCount + 1) == afterOverwrites.samples,
      "Cursor above new recorder count returns all retained samples")
let saturatedCursor = InputMetricsSnapshot(session: session(), isActive: true,
    ticks: UInt64.max, calls: 1, slowCalls: 0, errors: 0, busy: 0, inactive: 0,
    missedSamples: 0, invalidSamples: 0, overwrittenSamples: 0, samples: [])
check(saturatedCursor.acceptedSampleCount == UInt64.max, "Reporting cursor saturates instead of overflowing")
print("PASS: reporting cursor preserves boundary-crossing/late samples, avoids duplicates and bounds overwritten batches")

let contended = InputMetricsRecorder(session: session())
let ownsLock = DispatchSemaphore(value: 0)
let releaseLock = DispatchSemaphore(value: 0)
let holderDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    contended.withCollectionLockForTesting {
        ownsLock.signal()
        check(releaseLock.wait(timeout: .now() + 5) == .success, "Collection must return before held lock is released")
    }
    holderDone.signal()
}
check(ownsLock.wait(timeout: .now() + 2) == .success, "Holder owns collection lock")
check(!contended.recordTick(previous: nil, start: time(1), end: time(2)), "Tick skips held recorder lock")
check(!contended.recordSend(start: time(1), end: time(2), outcome: .submitted), "Send skips held recorder lock")
releaseLock.signal()
check(holderDone.wait(timeout: .now() + 2) == .success, "Release collection lock")
let misses = contended.snapshot()
check(misses.missedSamples == 2 && misses.ticks == 0 && misses.calls == 0 && misses.samples.isEmpty,
      "Skipped events counted without manufacturing observations")
print("PASS: collection returns while another thread holds its lock; misses counted atomically")

let concurrent = InputMetricsRecorder(session: session(), capacity: 17)
let group = DispatchGroup()
let workers = 8
let attempts = 5_000
for worker in 0..<workers {
    group.enter()
    DispatchQueue.global().async {
        for offset in 0..<attempts {
            let start = UInt64(worker * attempts + offset + 1)
            _ = concurrent.recordSend(start: time(start), end: time(start + 1), outcome: .submitted)
            if offset.isMultiple(of: 137) { _ = concurrent.snapshot() }
        }
        group.leave()
    }
}
check(group.wait(timeout: .now() + 10) == .success, "Concurrent writers complete")
let raced = concurrent.snapshot()
check(raced.calls + raced.missedSamples == UInt64(workers * attempts), "Every attempt is accepted or an atomic miss")
check(raced.samples.count <= 17 && raced.overwrittenSamples + UInt64(raced.samples.count) == raced.calls,
      "Concurrent retention remains bounded and accounted")
check(raced.invalidSamples == 0 && raced.errors == 0, "Contention is distinct from invalid clock/send error")
print("PASS: concurrent writers/snapshots preserve bounded ring and account for every attempt")

// Exercise the actual 120-Hz scheduler while another queue continuously appends
// synthetic video callback measurements. These timestamps do not represent GPU work.
let controller = HighFrequencyInputController()
let threaded = InputMetricsRecorder(session: session(), capacity: 256)
let handoffs = Atomic<UInt64>(0)
let tickArrived = DispatchSemaphore(value: 0)
controller.onInputReady = {
    let call = handoffs.wrappingAdd(1, ordering: .relaxed).newValue
    let start = StreamingMetricsClock.now()
    if call == 3 { Thread.sleep(forTimeInterval: 0.020) }
    let outcome: InputSendOutcome
    switch call {
    case 3: outcome = .failed(-19)
    case 4: outcome = .busy
    case 5: outcome = .inactive
    default: outcome = .submitted
    }
    _ = threaded.recordSend(start: start, end: StreamingMetricsClock.now(), outcome: outcome)
    tickArrived.signal()
}
let loadRecorder = StreamingMetricsRecorder(capacity: 64)
let loadSession = loadRecorder.beginSession()
let stopLoad = Atomic<Bool>(false)
let loadCount = Atomic<UInt64>(0)
let loadReady = DispatchSemaphore(value: 0)
let loadDone = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: .userInitiated).async {
    let synthetic = try! MetricInterval(metric: .receiveToDecode, start: time(1), end: time(2))
    loadReady.signal()
    while !stopLoad.load(ordering: .relaxed) {
        let frame = loadRecorder.nextFrame(in: loadSession)!
        _ = loadRecorder.record(synthetic, session: loadSession, frame: frame)
        _ = loadCount.wrappingAdd(1, ordering: .relaxed)
    }
    loadDone.signal()
}
check(loadReady.wait(timeout: .now() + 2) == .success, "Synthetic video load started")
controller.start(metrics: threaded)
controller.start(metrics: threaded) // Already running remains idempotent.
for _ in 0..<14 {
    check(tickArrived.wait(timeout: .now() + 2) == .success, "Input thread advances under artificial video load")
}
controller.stop()
threaded.end()
stopLoad.store(true, ordering: .relaxed)
check(loadDone.wait(timeout: .now() + 2) == .success, "Synthetic load ends")
let live = threaded.snapshot()
check(live.ticks >= 12 && live.calls >= 14 && live.samples.count <= 256, "Actual scheduler generates bounded measurements")
check(live.slowCalls >= 1 && live.errors == 1 && live.busy == 1 && live.inactive == 1,
      "Real callback captures injected slow/failed/busy/inactive handoff")
check(live.samples.contains { sample in
    if case let .tick(_, _, interval, _) = sample { return (interval?.microseconds ?? 0) >= 16_000 }
    return false
}, "Slow callback remains visible as tick jitter")
check(live.samples.contains { sample in
    if case let .tick(_, _, _, work) = sample { return work.microseconds >= 16_000 }
    return false
}, "Callback work cost remains separate from start-to-start jitter")
check(loadCount.load(ordering: .relaxed) > 0 && live.invalidSamples == 0, "Independent video collector runs without invalidating input timing")
print("PASS: actual input thread under synthetic video-callback load records injected slow/error outcomes and jitter")

// A real callback from the old generation remains blocked while a fresh input
// thread starts. Releasing it must not append to either ended or current metrics.
let restart = HighFrequencyInputController()
let generationA = InputMetricsRecorder(session: session())
let generationB = InputMetricsRecorder(session: session())
let oldEntered = DispatchSemaphore(value: 0)
let letOldFinish = DispatchSemaphore(value: 0)
let oldFinished = DispatchSemaphore(value: 0)
let newEntered = DispatchSemaphore(value: 0)
restart.onInputReady = {
    oldEntered.signal()
    check(letOldFinish.wait(timeout: .now() + 5) == .success, "Release previous input generation")
    check(!generationA.recordSend(start: time(1), end: time(2), outcome: .submitted), "Old real send collection rejected")
    oldFinished.signal()
}
restart.start(metrics: generationA)
check(oldEntered.wait(timeout: .now() + 2) == .success, "Previous input generation parked")
restart.stop()
generationA.end()
restart.onInputReady = { newEntered.signal() }
restart.start(metrics: generationB)
for _ in 0..<3 {
    check(newEntered.wait(timeout: .now() + 2) == .success, "New generation proceeds without joining old callback")
}
restart.stop()
generationB.end()
letOldFinish.signal()
check(oldFinished.wait(timeout: .now() + 2) == .success, "Old generation finishes")
let restarted = generationB.snapshot()
check(generationA.snapshot().samples.isEmpty && restarted.session != generationA.session, "Real generations do not mix samples")
check(restarted.ticks >= 2 && restarted.calls == 0, "New generation retains only its own ticks")
if case let .tick(_, _, interval, _) = restarted.samples.first {
    check(interval == nil, "New generation resets previous tick instead of measuring disconnection gap")
} else { fatalError("New generation must start with a tick") }
print("PASS: actual input thread stop/start isolates a pending old callback and resets tick intervals")
print("Input metrics host tests passed. Host collection checks do not establish physical jitter or instrumentation overhead.")
