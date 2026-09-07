import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func session() -> MetricSessionID { StreamingMetricsRecorder().beginSession() }
func timestamp(_ micros: UInt64) -> MetricTimestamp { MetricTimestamp(microseconds: micros)! }

let pcm = AudioRingBuffer(capacity: 19_200, alignment: 2)
let samples = [Int16](repeating: 123, count: 3_840)
samples.withUnsafeBufferPointer {
    check(pcm.write($0.baseAddress!, count: $0.count) == 3_840, "Write 40 ms of stereo PCM")
}
func audio(sampleRate: Int = 48_000, channels: Int = 2) -> AudioThermalMetrics.AudioState {
    AudioThermalMetrics.AudioState(sampleRate: sampleRate, channels: channels,
        targetSamples: 3_840, buffer: pcm.diagnostics, oversizedRenderRequests: 2)
}
let audioState = audio()
check(audioState.queuedMilliseconds == 40 && audioState.peakMilliseconds == 40,
      "3840 interleaved sample values at 48 kHz stereo equal 40 ms, not 80 ms")
check(audioState.buffer.availableSamples == 3_840 && audioState.buffer.capacity == 19_200
      && audioState.targetSamples == 3_840 && audioState.oversizedRenderRequests == 2,
      "Snapshot preserves distinct buffer, target and oversized-render diagnostics")

let nominal = ThermalReading(.nominal)
let fair = ThermalReading(.fair)
let serious = ThermalReading(.serious)
let critical = ThermalReading(.critical)
check([nominal.label, fair.label, serious.label, critical.label] == ["nominal", "fair", "serious", "critical"],
      "Label the four SDK thermal categories")
let unknown = ThermalReading(rawValue: 37)
check(unknown.rawValue == 37 && unknown.label == "unknown(37)", "Preserve future OS raw values")

let thermal = AudioThermalMetrics(session: session(), capacity: 3)
thermal.observeThermal(nominal, at: timestamp(1), source: .initial)
let initial = thermal.snapshot()
check(initial.isActive && initial.currentThermal == nominal && initial.thermalChanges == 0
      && initial.thermalEventCount == 1 && initial.notificationsReceived == 0
      && initial.thermalEvents[0].isInitial && initial.thermalEvents[0].source == .initial,
      "Initial state is retained without inventing a thermal transition or notification")
thermal.observeThermal(nominal, at: timestamp(2), source: .notification)
thermal.observeThermal(nominal, at: timestamp(3), source: .poll)
check(thermal.snapshot().notificationsReceived == 1 && thermal.snapshot().thermalEventCount == 1
      && thermal.snapshot().thermalChanges == 0,
      "Repeated notification and polling preserve state without inventing changes")
thermal.observeThermal(fair, at: timestamp(4), source: .notification)
thermal.observeThermal(unknown, at: timestamp(5), source: .notification)
check(thermal.snapshot().currentThermal == unknown && thermal.snapshot().thermalChanges == 2
      && thermal.snapshot().thermalEvents.last?.state.rawValue == 37,
      "Observed changes include an unknown raw state without normalizing it")
thermal.observeThermal(critical, at: timestamp(4), source: .notification)
thermal.observeThermal(critical, at: nil, source: .notification)
thermal.observeThermal(unknown, at: timestamp(5), source: .notification)
let rejected = thermal.snapshot()
check(rejected.currentThermal == unknown && rejected.rejectedThermalObservations == 2
      && rejected.notificationsReceived == 6 && rejected.thermalChanges == 2,
      "Late or unavailable clocks never regress current state; received notifications remain accounted")
thermal.observeThermal(serious, at: timestamp(6), source: .poll)
let recent = thermal.snapshot()
check(recent.thermalEvents.map(\.sequence) == [2, 3, 4]
      && recent.thermalEvents.map { $0.at.microseconds } == [4, 5, 6]
      && recent.overwrittenThermalEvents == 1 && recent.thermalChanges == 3,
      "Bounded event ring preserves event order and separates polls from notification counts")
check(initial.thermalEvents.count == 1 && initial.currentThermal == nominal,
      "Captured evidence is independent of later ring changes")
print("PASS: initial versus transitions, repeated notifications, unknown states, out-of-order clocks and bounded thermal events")

let paired = AudioThermalMetrics(session: session())
let videoTimes = [timestamp(1_000_000), timestamp(6_000_000), timestamp(11_000_000)]
for (index, now) in videoTimes.enumerated() {
    let sample = paired.recordSample(audio: audioState, thermal: nominal, at: now)!
    check(sample.sequence == UInt64(index + 1) && sample.at.microseconds == now.microseconds,
          "Keep the exact caller-provided video reporting timestamp")
    check(sample.intervalStart?.microseconds == (index == 0 ? nil : videoTimes[index - 1].microseconds),
          "Reporting interval starts at the preceding paired sample, with no inferred first interval")
    check(sample.audio.queuedMilliseconds == 40 && sample.thermal == nominal,
          "Paired sample carries audio and thermal observations for the same reporting boundary")
}
check(paired.recordSample(audio: audioState, thermal: critical, at: nil) == nil,
      "Reject unavailable reporting clock")
check(paired.recordSample(audio: audioState, thermal: critical, at: videoTimes.last) == nil,
      "Reject duplicate reporting clock")
check(paired.recordSample(audio: audioState, thermal: critical, at: videoTimes[0]) == nil,
      "Reject backward reporting clock")
check(paired.recordSample(audio: audio(sampleRate: 0), thermal: critical, at: timestamp(12_000_000)) == nil,
      "Reject zero sample rate before converting to milliseconds")
check(paired.recordSample(audio: audio(channels: 0), thermal: critical, at: timestamp(12_000_000)) == nil,
      "Reject zero channel count before converting to milliseconds")
let unchanged = paired.snapshot()
check(unchanged.invalidSamples == 5 && unchanged.sampleCount == 3
      && unchanged.currentThermal == nominal && unchanged.thermalChanges == 0,
      "Invalid samples cannot alter valid intervals or observed thermal state")

// A notification can be newer than a poll that was sampled earlier but acquired
// the recorder lock later. Keep that poll's audio boundary without regressing
// the current thermal state to its older observation.
paired.observeThermal(critical, at: timestamp(13_000_000), source: .notification)
let earlierPoll = paired.recordSample(audio: audioState, thermal: fair, at: timestamp(12_000_000))!
check(earlierPoll.intervalStart?.microseconds == 11_000_000 && earlierPoll.thermal == fair
      && paired.snapshot().currentThermal == critical
      && paired.snapshot().rejectedThermalObservations == 1,
      "Late-arriving valid audio sample retains its own observation without regressing newer thermal state")
let next = paired.recordSample(audio: audioState, thermal: critical, at: timestamp(16_000_000))!
check(next.intervalStart?.microseconds == 12_000_000 && next.sequence == 5,
      "Rejected inputs leave the next valid reporting interval intact")
print("PASS: shared video clock boundaries, exact reporting intervals, PCM duration units and invalid sample isolation")

for capacity in [3, 64] {
    let history = capacity == 64
        ? AudioThermalMetrics(session: session())
        : AudioThermalMetrics(session: session(), capacity: capacity)
    let total = capacity + 5
    for index in 1...total {
        _ = history.recordSample(audio: audioState,
            thermal: index.isMultiple(of: 2) ? fair : nominal,
            at: timestamp(UInt64(index) * 5_000_000))
    }
    let snapshot = history.snapshot()
    let expected = (6...total).map(UInt64.init)
    check(snapshot.samples.count == capacity && snapshot.thermalEvents.count == capacity,
          "Both sample and thermal-event histories retain their fixed capacity")
    check(snapshot.samples.map(\.sequence) == expected
          && snapshot.thermalEvents.map(\.sequence) == expected,
          "Both rings retain the newest entries in chronological recording order")
    check(snapshot.overwrittenSamples == 5 && snapshot.overwrittenThermalEvents == 5
          && snapshot.sampleCount == UInt64(total)
          && snapshot.thermalEventCount == UInt64(total)
          && snapshot.thermalChanges == UInt64(total - 1),
          "Exact overwrite and transition totals remain independent of retained history")
    check(snapshot.samples.first?.intervalStart?.microseconds == 25_000_000,
          "Oldest retained sample keeps its original interval even when its predecessor was overwritten")
}
print("PASS: default 64 and custom 3 capacities, dual ring order, exact overwrite totals and retained interval provenance")

let old = AudioThermalMetrics(session: session())
old.observeThermal(nominal, at: timestamp(1), source: .initial)
_ = old.recordSample(audio: audioState, thermal: nominal, at: timestamp(2))
let callbackReady = DispatchSemaphore(value: 0)
let releaseCallback = DispatchSemaphore(value: 0)
let callbackDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    callbackReady.signal()
    releaseCallback.wait()
    old.observeThermal(critical, at: timestamp(3), source: .notification)
    check(old.recordSample(audio: audioState, thermal: critical, at: timestamp(4)) == nil,
          "Ended recorder rejects delayed audio reporting")
    old.end()
    callbackDone.signal()
}
check(callbackReady.wait(timeout: .now() + 5) == .success, "Old session callback is waiting")
old.end()
let replacement = AudioThermalMetrics(session: session())
replacement.observeThermal(fair, at: timestamp(5), source: .initial)
_ = replacement.recordSample(audio: audioState, thermal: fair, at: timestamp(6))
releaseCallback.signal()
check(callbackDone.wait(timeout: .now() + 5) == .success, "Old session callback completed")
let ended = old.snapshot()
let current = replacement.snapshot()
check(!ended.isActive && ended.currentThermal == nominal && ended.sampleCount == 1
      && ended.notificationsReceived == 0 && ended.thermalChanges == 0,
      "Ended session retains its evidence without counting late observations")
check(current.isActive && current.session != ended.session && current.currentThermal == fair
      && current.sampleCount == 1 && current.notificationsReceived == 0
      && current.thermalChanges == 0,
      "Captured old callbacks and stops cannot alter the replacement recorder")
print("PASS: ended-session evidence, delayed callback rejection and replacement-session isolation")

let concurrent = AudioThermalMetrics(session: session(), capacity: 8)
concurrent.observeThermal(nominal, at: timestamp(1), source: .initial)
let workers = 4
let iterations = 1_000
DispatchQueue.concurrentPerform(iterations: workers) { worker in
    for index in 0..<iterations {
        let time = UInt64(worker * iterations + index + 2)
        concurrent.observeThermal(ThermalReading(rawValue: Int(time % 4)),
                                  at: timestamp(time), source: .notification)
        if index.isMultiple(of: 100) {
            let snapshot = concurrent.snapshot()
            check(snapshot.thermalEvents.count <= 8, "Concurrent event storage remains bounded")
            let times = snapshot.thermalEvents.map { $0.at.microseconds }
            check(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 },
                  "Retained concurrent thermal events cannot move backward in observed time")
        }
    }
}
let concurrentSnapshot = concurrent.snapshot()
check(concurrentSnapshot.notificationsReceived == UInt64(workers * iterations),
      "All concurrent notifications are counted, including rejected stale observations")
check(concurrentSnapshot.currentThermal?.rawValue == (workers * iterations + 1) % 4,
      "The newest observation determines state despite concurrent delivery order")
check(concurrentSnapshot.thermalEventCount == concurrentSnapshot.thermalChanges + 1
      && concurrentSnapshot.thermalEvents.count <= 8
      && concurrentSnapshot.overwrittenThermalEvents
        == concurrentSnapshot.thermalEventCount - UInt64(concurrentSnapshot.thermalEvents.count),
      "Concurrent transition accounting and bounded overwrite totals are exact")
check(concurrentSnapshot.sampleCount == 0 && concurrentSnapshot.samples.isEmpty,
      "Thermal notifications do not invent audio measurement intervals")
print("PASS: concurrent notification accounting, chronological current state and bounded event storage")
