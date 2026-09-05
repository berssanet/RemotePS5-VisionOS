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
ring.reset()
precondition(ring.read(output, count: 960) == 0)
precondition((0..<960).allSatisfy { output[$0] == 0 })

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
print("PASS: seven-second stall bounded to 200ms; catch-up to 40ms; stereo alignment; concurrent wraparound; silence")
