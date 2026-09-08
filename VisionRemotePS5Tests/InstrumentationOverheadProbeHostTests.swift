import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func sample(wall: UInt64? = 1_000, user: UInt64? = 100,
            system: UInt64? = 50, footprint: UInt64? = nil) -> InstrumentationProbeSample {
    InstrumentationProbeSample(hostUs: nil, wallTicks: wall, userTicks: user,
        systemTicks: system, footprintBytes: footprint, thermalRaw: 0)
}

let start = sample()
let end = sample(wall: 2_000, user: 400, system: 250)
let valid = InstrumentationProbeCPUDelta.between(start, end)!
check(valid.wallTicks == 1_000 && valid.userTicks == 300 && valid.systemTicks == 200
      && valid.processPercent == 50, "CPU ratio combines user+system deltas in the common Mach timebase")
let parallel = InstrumentationProbeCPUDelta.between(start, sample(wall: 2_000, user: 2_100, system: 550))!
check(parallel.processPercent == 250, "Multiple cores may exceed 100%; do not normalize by processor count")
let idle = InstrumentationProbeCPUDelta.between(start, sample(wall: 2_000))!
check(idle.processPercent == 0, "Valid unchanged CPU counters represent zero CPU consumption")
print("PASS: exact CPU delta, common timebase ratio, valid zero and multicore usage")

for invalid in [nil, sample(wall: nil), sample(user: nil), sample(system: nil),
                sample(wall: 999), sample(wall: 1_000), sample(wall: 2_000, user: 99),
                sample(wall: 2_000, system: 49)] {
    check(InstrumentationProbeCPUDelta.between(start, invalid) == nil,
          "Missing query/clock, zero elapsed interval and regressing counters stay unavailable")
}
for invalid in [nil, sample(wall: nil), sample(wall: 0), sample(user: nil), sample(system: nil)] {
    check(InstrumentationProbeCPUDelta.between(invalid, end) == nil,
          "Incomplete first observation cannot become a fabricated baseline")
}
let maximum = UInt64.max
check(InstrumentationProbeCPUDelta.between(sample(wall: 1, user: 0, system: 0),
    sample(wall: 2, user: maximum, system: 1)) == nil,
    "Overflowing combined CPU deltas are rejected rather than wrapped")
let high = InstrumentationProbeCPUDelta.between(
    sample(wall: maximum - 10, user: maximum - 10, system: maximum - 10),
    sample(wall: maximum, user: maximum - 7, system: maximum - 8))!
check(high.wallTicks == 10 && high.userTicks == 3 && high.systemTicks == 2
      && high.processPercent == 50, "Integer subtraction preserves small deltas at UInt64-scale uptimes")
print("PASS: unavailable endpoints, backward counters, overflow and exact large-counter differences")

let noFootprint = sample(wall: 2_000, user: 400, system: 250, footprint: nil)
check(noFootprint.footprintBytes == nil && InstrumentationProbeCPUDelta.between(start, noFootprint) == valid,
      "Independent missing memory observation does not invalidate otherwise valid CPU or invent zero bytes")
let zeroFootprint = sample(footprint: 0)
check(zeroFootprint.footprintBytes == 0, "An explicitly available zero value remains distinct from unavailable")
// Exercise the actual public Mach query once in both compilation variants. Its
// result is platform-dependent, so unavailable CPU/memory remain valid results.
let observed = InstrumentationOverheadProbe.observe()
check(observed.wallTicks.map { $0 > 0 } ?? true, "Real unavailable wall clock cannot masquerade as zero")
check((observed.userTicks == nil) == (observed.systemTicks == nil),
      "A CPU query failure marks both cumulative endpoints unavailable")
print("PASS: independent memory validity and real OS snapshot without assuming query availability")
