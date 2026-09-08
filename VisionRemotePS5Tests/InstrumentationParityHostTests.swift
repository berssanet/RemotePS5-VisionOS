import Foundation
import Synchronization

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func diagnosticCounters(_ value: AudioRingBuffer.Diagnostics) -> [UInt64] {
    [UInt64(value.peakBufferedSamples), value.writtenSamples, value.readSamples,
     value.overflowDiscardedSamples, value.catchUpDiscardedSamples, value.catchUpEvents,
     value.readCalls, value.underflowReads, value.missingSamples,
     value.prePCMUnderflowReads, value.prePCMMissingSamples, value.underflowEpisodes,
     value.recoveryEvents, value.contentionReads, value.contentionRequestedSamples]
}

// All PCM below is a synthetic, identifiable stereo fixture. The digest covers
// return values, retained occupancy, and every output value (including silence).
let ring = AudioRingBuffer(capacity: 16, alignment: 2)
var digest: UInt64 = 14_695_981_039_346_656_037
var reads = 0
var writes = 0
func mix(_ value: UInt64) {
    for shift in stride(from: 0, to: 64, by: 8) {
        digest = (digest ^ ((value >> shift) & 255)) &* 1_099_511_628_211
    }
}
func stereo(_ values: [Int16]) -> [Int16] { values.flatMap { [$0, -$0] } }
@discardableResult
func write(_ values: [Int16], count: Int? = nil) -> Int {
    let amount = values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: count ?? $0.count) }
    writes += 1
    mix(1); mix(UInt64(amount)); mix(UInt64(ring.availableSamples))
    return amount
}
@discardableResult
func read(_ count: Int, maximum: Int = .max, target: Int = 0,
          expected: [Int16]? = nil, expectedCount: Int? = nil) -> Int {
    let output = UnsafeMutablePointer<Int16>.allocate(capacity: max(1, count))
    output.initialize(repeating: 777, count: max(1, count))
    defer { output.deallocate() }
    let amount = ring.read(output, count: count, maximumBuffered: maximum, targetBuffered: target)
    let values = Array(UnsafeBufferPointer(start: output, count: count))
    if let expected { check(values == expected, "Expected PCM values or zero-filled silence") }
    if let expectedCount { check(amount == expectedCount, "Expected number of consumed PCM values") }
    check(amount.isMultiple(of: 2) && amount <= count && ring.availableSamples <= ring.capacity,
          "Read remains aligned and bounded")
    for frame in 0..<(amount / 2) {
        check(values[frame * 2] == -values[frame * 2 + 1], "Stereo channels remain aligned")
    }
    reads += 1
    mix(2); mix(UInt64(amount)); mix(UInt64(ring.availableSamples))
    for value in values { mix(UInt64(UInt16(bitPattern: value))) }
    return amount
}

read(6, expected: [0, 0, 0, 0, 0, 0], expectedCount: 0)
check(write(stereo((1...12).map { Int16($0 * 10) })) == 16, "Oversized write keeps newest capacity")
read(4, maximum: 8, target: 8, expected: [90, -90, 100, -100], expectedCount: 4)
read(8, expected: [110, -110, 120, -120, 0, 0, 0, 0], expectedCount: 4)
write(stereo([130, 140]))
read(4, expected: [130, -130, 140, -140], expectedCount: 4)
write(stereo([150, 160, 170]))
let pendingBeforeContention = ring.availableSamples
ring.withLockForTesting {
    // Do not call diagnostics/availableSamples while holding the producer lock.
    var silence = [Int16](repeating: 777, count: 6)
    let amount = silence.withUnsafeMutableBufferPointer { ring.read($0.baseAddress!, count: 6) }
    check(amount == 0 && silence == [0, 0, 0, 0, 0, 0], "Contended callback returns zero-filled silence")
    mix(3); mix(UInt64(amount)); silence.forEach { mix(UInt64(UInt16(bitPattern: $0))) }
}
check(ring.availableSamples == pendingBeforeContention, "Contention cannot consume queued PCM")
read(6, expected: [150, -150, 160, -160, 170, -170], expectedCount: 6)
check(write(stereo([180]), count: 1) == 0, "Incomplete stereo frame cannot enter the queue")
read(1, expected: [0], expectedCount: 0)
read(0, expected: [], expectedCount: 0)
for packet in 0..<250 {
    let fixture = stereo((0..<(packet % 12 + 1)).map { Int16((packet * 47 + $0 + 1) % 30_000) })
    write(fixture)
    read([0, 1, 2, 4, 10, 18, 6][packet % 7], maximum: 8, target: 6)
}
let observed = ring.diagnostics
#if DISABLE_PERFORMANCE_COLLECTION
check(diagnosticCounters(observed).allSatisfy { $0 == 0 } && ring.discardedSamples == 0,
      "Baseline removes all PCM diagnostic counters and contention atomics")
#else
check(observed.overflowDiscardedSamples > 0 && observed.catchUpEvents > 0
      && observed.underflowReads > 0 && observed.recoveryEvents > 0
      && observed.prePCMUnderflowReads > 0 && observed.contentionReads == 1
      && observed.contentionRequestedSamples == 6 && observed.peakBufferedSamples == 16,
      "Enabled build records all exercised causes separately")
check(observed.writtenSamples == observed.readSamples + observed.overflowDiscardedSamples
      + observed.catchUpDiscardedSamples + UInt64(observed.availableSamples), "Enabled PCM accounting conserves input")
#endif
ring.reset()
check(ring.availableSamples == 0 && diagnosticCounters(ring.diagnostics).allSatisfy { $0 == 0 },
      "Reset preserves functional empty state and clears enabled diagnostics")
read(4, expected: [0, 0, 0, 0], expectedCount: 0)
print("PCM_PARITY syntheticFixtureDigest=\(String(digest, radix: 16)) writes=\(writes) reads=\(reads) remaining=\(ring.availableSamples)")

// The concurrent schedule may differ across processes, so compare its safety
// invariants rather than imposing an artificial identical scheduling history.
let concurrent = AudioRingBuffer(capacity: 19200, alignment: 2)
let producerDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    let fixture: [Int16] = [100, -100, 200, -200]
    for _ in 0..<5_000 { fixture.withUnsafeBufferPointer { _ = concurrent.write($0.baseAddress!, count: $0.count) } }
    producerDone.signal()
}
var concurrentOutput = [Int16](repeating: 0, count: 960)
for _ in 0..<5_000 {
    let amount = concurrentOutput.withUnsafeMutableBufferPointer {
        concurrent.read($0.baseAddress!, count: 960, maximumBuffered: 9600, targetBuffered: 3840)
    }
    for frame in 0..<(amount / 2) {
        check(concurrentOutput[frame * 2] == -concurrentOutput[frame * 2 + 1], "Concurrent stereo alignment")
    }
}
check(producerDone.wait(timeout: .now() + 5) == .success && concurrent.availableSamples <= concurrent.capacity,
      "Concurrent producer and nonblocking consumer complete within the hard capacity")
#if DISABLE_PERFORMANCE_COLLECTION
check(diagnosticCounters(concurrent.diagnostics).allSatisfy { $0 == 0 }, "Concurrent baseline has no diagnostic accumulation")
#endif

func recorder() -> InputMetricsRecorder {
    InputMetricsRecorder(session: StreamingMetricsRecorder().beginSession(), capacity: 64)
}
let controller = HighFrequencyInputController()
let input = recorder()
let calls = Atomic<UInt64>(0)
let inputDone = DispatchSemaphore(value: 0)
controller.onInputReady = {
    let count = calls.wrappingAdd(1, ordering: .relaxed).newValue
    if count == 3 { Thread.sleep(forTimeInterval: 0.020) }
    if count == 12 { controller.stop(); inputDone.signal() }
}
controller.start(metrics: input)
controller.start(metrics: input)
check(inputDone.wait(timeout: .now() + 5) == .success, "Input scheduler progresses after a delayed callback")
input.end()
let inputSnapshot = input.snapshot()
check(calls.load(ordering: .relaxed) == 12 && !controller.isRunning, "Duplicate start does not duplicate scheduler; stop is effective")
#if DISABLE_PERFORMANCE_COLLECTION
check(inputSnapshot.ticks == 0 && inputSnapshot.samples.isEmpty,
      "Baseline scheduler does not observe clocks or record ticks even when passed a recorder")
#else
check(inputSnapshot.ticks >= 10 && inputSnapshot.ticks <= 12 && inputSnapshot.samples.contains { sample in
    if case .tick(_, _, _, let work) = sample { return work.microseconds >= 15_000 }
    return false
}, "Enabled scheduler observes the delayed callback without changing callback execution")
#endif
controller.onInputReady = nil

let restart = HighFrequencyInputController()
let oldMetrics = recorder()
let newMetrics = recorder()
let oldEntered = DispatchSemaphore(value: 0)
let releaseOld = DispatchSemaphore(value: 0)
let oldFinished = DispatchSemaphore(value: 0)
let newFinished = DispatchSemaphore(value: 0)
let newCalls = Atomic<UInt64>(0)
restart.onInputReady = {
    oldEntered.signal()
    check(releaseOld.wait(timeout: .now() + 5) == .success, "Release stopped generation")
    oldFinished.signal()
}
restart.start(metrics: oldMetrics)
check(oldEntered.wait(timeout: .now() + 5) == .success, "Old input generation is parked in its callback")
restart.stop()
oldMetrics.end()
restart.onInputReady = {
    if newCalls.wrappingAdd(1, ordering: .relaxed).newValue == 4 {
        restart.stop(); newFinished.signal()
    }
}
restart.start(metrics: newMetrics)
check(newFinished.wait(timeout: .now() + 5) == .success, "New generation advances without joining old callback")
newMetrics.end()
releaseOld.signal()
check(oldFinished.wait(timeout: .now() + 5) == .success, "Old callback returns after replacement stops")
check(newCalls.load(ordering: .relaxed) == 4 && oldMetrics.snapshot().ticks == 0,
      "Generation isolation preserves callback execution and prevents old observations")
#if DISABLE_PERFORMANCE_COLLECTION
check(newMetrics.snapshot().ticks == 0, "Restarted baseline still does not collect ticks")
print("PASS: disabled counters and clock collection, bounded PCM and actual input lifecycle")
#else
check(newMetrics.snapshot().ticks >= 3 && newMetrics.snapshot().ticks <= 4, "New enabled generation owns its tick observations")
print("PASS: enabled counters and clock collection, bounded PCM and actual input lifecycle")
#endif
restart.onInputReady = nil
print("INPUT_PARITY callbacks=\(calls.load(ordering: .relaxed)) restartedCallbacks=\(newCalls.load(ordering: .relaxed)) stopped=\(!restart.isRunning)")
