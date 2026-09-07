import Foundation

let ring = AudioRingBuffer(capacity: 19200, alignment: 2) // 200ms @ 48k stereo
// Simulate seven seconds with no consumer, using identifiable stereo frames.
for packet in 0..<700 {
    var samples: [Int16] = []
    for i in 0..<480 {
        let value = Int16((packet * 480 + i) % 30000)
        samples.append(value); samples.append(-value)
    }
    samples.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
}
precondition(ring.availableSamples == 19200)
let output = UnsafeMutablePointer<Int16>.allocate(capacity: 960)
defer { output.deallocate() }
let read = ring.read(output, count: 960, maximumBuffered: 9600, targetBuffered: 3840)
precondition(read == 960 && ring.availableSamples == 2880) // catch up to 40ms, consume 10ms
let firstExpected = Int16((700 * 480 - 1920) % 30000)
precondition(output[0] == firstExpected, "must retain freshest 40ms, not old audio")
for i in 0..<480 { precondition(output[i*2] == -output[i*2+1], "stereo channels out of phase") }
precondition(ring.discardedSamples > 0)
let stalled = ring.diagnostics
precondition(stalled.capacity == 19200 && stalled.peakBufferedSamples == 19200)
precondition(stalled.writtenSamples == 700 * 960 && stalled.readSamples == 960)
precondition(stalled.overflowDiscardedSamples == 700 * 960 - 19200)
precondition(stalled.catchUpDiscardedSamples == 19200 - 3840 && stalled.catchUpEvents == 1)
precondition(stalled.availableSamples == 2880 && stalled.readCalls == 1 && stalled.underflowReads == 0)
ring.reset()
let reset = ring.diagnostics
precondition(reset.availableSamples == 0 && reset.peakBufferedSamples == 0 && reset.writtenSamples == 0 &&
    reset.readSamples == 0 && reset.overflowDiscardedSamples == 0 && reset.catchUpDiscardedSamples == 0 &&
    reset.catchUpEvents == 0 && reset.readCalls == 0 && reset.underflowReads == 0 && reset.missingSamples == 0 &&
    reset.prePCMUnderflowReads == 0 && reset.prePCMMissingSamples == 0 &&
    reset.underflowEpisodes == 0 && reset.recoveryEvents == 0 && reset.contentionReads == 0 &&
    reset.contentionRequestedSamples == 0)
precondition(ring.read(output, count: 960) == 0)
precondition((0..<960).allSatisfy { output[$0] == 0 })
precondition(ring.diagnostics.underflowReads == 1 && ring.diagnostics.missingSamples == 960 &&
    ring.diagnostics.prePCMUnderflowReads == 1 && ring.diagnostics.prePCMMissingSamples == 960 &&
    ring.diagnostics.underflowEpisodes == 1 && ring.diagnostics.recoveryEvents == 0)
let initialPCM: [Int16] = [100, -100]
initialPCM.withUnsafeBufferPointer { precondition(ring.write($0.baseAddress!, count: 1) == 0) }
precondition(ring.read(output, count: 2) == 0)
precondition(ring.diagnostics.prePCMUnderflowReads == 2 && ring.diagnostics.prePCMMissingSamples == 962,
    "Incomplete stereo input does not end pre-PCM observation")
initialPCM.withUnsafeBufferPointer { precondition(ring.write($0.baseAddress!, count: 2) == 2) }
precondition(ring.read(output, count: 4) == 2)
precondition(ring.diagnostics.underflowReads == 3 && ring.diagnostics.missingSamples == 964 &&
    ring.diagnostics.prePCMUnderflowReads == 2 && ring.diagnostics.prePCMMissingSamples == 962,
    "Underflow after first aligned PCM input contributes only to the overall totals")
ring.reset()

// Stress wraparound and simultaneous producer/consumer. The consumer never waits.
let completed = DispatchGroup()
completed.enter()
DispatchQueue.global().async {
    let data: [Int16] = [100, -100, 200, -200]
    for _ in 0..<20000 { data.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: 4) } }
    completed.leave()
}
for _ in 0..<20000 {
    let count = ring.read(output, count: 960, maximumBuffered: 9600, targetBuffered: 3840)
    for i in 0..<count/2 { precondition(output[i*2] == -output[i*2+1]) }
}
precondition(completed.wait(timeout: .now() + 5) == .success)
let concurrent = ring.diagnostics
precondition(concurrent.writtenSamples == 20_000 * 4 && concurrent.readCalls == 20_000)
precondition(concurrent.availableSamples <= concurrent.capacity && concurrent.peakBufferedSamples <= concurrent.capacity)
precondition(concurrent.writtenSamples == concurrent.readSamples + concurrent.overflowDiscardedSamples +
    concurrent.catchUpDiscardedSamples + UInt64(concurrent.availableSamples), "Concurrent PCM accounting must conserve input")
precondition(concurrent.underflowReads + concurrent.contentionReads <= concurrent.readCalls)
precondition(concurrent.contentionRequestedSamples == concurrent.contentionReads * 960)
precondition(concurrent.underflowEpisodes <= concurrent.underflowReads &&
    concurrent.recoveryEvents <= concurrent.underflowEpisodes)
print("PASS: seven-second stall bounded to 200ms; catch-up to 40ms; stereo alignment; concurrent wraparound; silence")

// Small identifiable stereo input proves separate overflow/catch-up accounting,
// partial underflows, episode recovery and unchanged channel alignment.
let small = AudioRingBuffer(capacity: 8, alignment: 2)
let stereo: [Int16] = [10, -10, 20, -20, 30, -30, 40, -40, 50, -50, 60, -60]
stereo.withUnsafeBufferPointer { precondition(small.write($0.baseAddress!, count: $0.count) == 8) }
precondition(small.diagnostics.writtenSamples == 12 && small.diagnostics.overflowDiscardedSamples == 4)
precondition(small.read(output, count: 2, maximumBuffered: 4, targetBuffered: 4) == 2)
precondition(output[0] == 50 && output[1] == -50)
let caughtUp = small.diagnostics
precondition(caughtUp.availableSamples == 2 && caughtUp.catchUpDiscardedSamples == 4 && caughtUp.catchUpEvents == 1 &&
    caughtUp.overflowDiscardedSamples == 4 && caughtUp.readSamples == 2 && caughtUp.peakBufferedSamples == 8)
precondition(small.read(output, count: 4) == 2)
precondition(output[0] == 60 && output[1] == -60 && output[2] == 0 && output[3] == 0)
precondition(small.diagnostics.underflowReads == 1 && small.diagnostics.missingSamples == 2 &&
    small.diagnostics.underflowEpisodes == 1 && small.diagnostics.recoveryEvents == 0)
let beforeZero = small.diagnostics
precondition(small.read(output, count: 0) == 0)
stereo.withUnsafeBufferPointer { precondition(small.write($0.baseAddress!, count: 0) == 0) }
precondition(small.diagnostics.readCalls == beforeZero.readCalls &&
    small.diagnostics.writtenSamples == beforeZero.writtenSamples &&
    small.diagnostics.underflowReads == beforeZero.underflowReads &&
    small.diagnostics.recoveryEvents == beforeZero.recoveryEvents, "Zero-count operations are not audio events")
precondition(small.read(output, count: 1) == 0)
precondition(small.diagnostics.underflowReads == 1 && small.diagnostics.recoveryEvents == 0,
    "A request smaller than one stereo frame cannot infer recovery")
precondition(small.read(output, count: 2) == 0)
precondition(small.diagnostics.underflowReads == 2 && small.diagnostics.missingSamples == 4 &&
    small.diagnostics.underflowEpisodes == 1)
stereo.withUnsafeBufferPointer { precondition(small.write($0.baseAddress!, count: 4) == 4) }
precondition(small.read(output, count: 4) == 4)
precondition(small.diagnostics.recoveryEvents == 1)
precondition(small.read(output, count: 2) == 0)
precondition(small.diagnostics.underflowEpisodes == 2 && small.diagnostics.underflowReads == 3)

stereo.withUnsafeBufferPointer { precondition(small.write($0.baseAddress!, count: 4) == 4) }
let beforeContention = small.diagnostics
small.withLockForTesting {
    output[0] = 99; output[1] = 99
    precondition(small.read(output, count: 2) == 0)
    precondition(output[0] == 0 && output[1] == 0, "Contended render must still emit silence")
}
let contended = small.diagnostics
precondition(contended.contentionReads == 1 && contended.contentionRequestedSamples == 2 &&
    contended.readCalls == beforeContention.readCalls + 1)
precondition(contended.availableSamples == beforeContention.availableSamples &&
    contended.readSamples == beforeContention.readSamples && contended.underflowReads == beforeContention.underflowReads &&
    contended.missingSamples == beforeContention.missingSamples && contended.underflowEpisodes == beforeContention.underflowEpisodes &&
    contended.recoveryEvents == beforeContention.recoveryEvents,
    "Lock contention is separate from buffer underflow and cannot consume PCM or end its episode")
precondition(small.read(output, count: 2) == 2 && small.diagnostics.recoveryEvents == 2)
precondition(small.read(output, count: 2) == 2 && small.diagnostics.recoveryEvents == 2,
    "Only the first full read after an observed underflow records recovery")
let final = small.diagnostics
precondition(final.writtenSamples == final.readSamples + final.overflowDiscardedSamples +
    final.catchUpDiscardedSamples + UInt64(final.availableSamples))
precondition(small.discardedSamples == Int(final.overflowDiscardedSamples + final.catchUpDiscardedSamples))
small.reset()
let afterReset = small.diagnostics
precondition(afterReset.contentionReads == 0 && afterReset.contentionRequestedSamples == 0 && afterReset.readCalls == 0 &&
    afterReset.underflowReads == 0 && afterReset.missingSamples == 0 && afterReset.underflowEpisodes == 0 &&
    afterReset.prePCMUnderflowReads == 0 && afterReset.prePCMMissingSamples == 0 &&
    afterReset.recoveryEvents == 0 && afterReset.writtenSamples == 0 && afterReset.peakBufferedSamples == 0)
print("PASS: separate overflow/catch-up totals, PCM conservation, underflow episodes/recovery, zero-count and deterministic contention")
print("PASS: pre-PCM underflow subsets stop at first aligned producer input and reset with the session")
