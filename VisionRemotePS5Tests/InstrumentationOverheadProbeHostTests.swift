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

@MainActor
final class ProbeHarness {
    var clock: UInt64? = 1_000_000
    var lines: [String] = []
    var waits: [UInt64] = []
    var queries = 0
    var validations: [Bool] = []
    var onSleep: ((Int) throws -> Void)?
    var transform: ((InstrumentationProbeSample, Int) -> InstrumentationProbeSample)?
    var validateResult: ((Bool, Int) -> InstrumentationProbeFailure?)?
    let session = StreamingMetricsRecorder().beginSession()
    var configuration = InstrumentationProbeConfiguration(width: 1920, height: 1080, fps: 60, bitrate: 15000)

    func makeProbe() -> InstrumentationOverheadProbe {
        InstrumentationOverheadProbe(session: session, configuration: configuration, validate: { required in
            self.validations.append(required)
            return self.validateResult?(required, self.validations.count)
        }, environment: .init(now: { self.clock }, observe: {
            self.queries += 1
            let now = self.clock ?? 0
            let value = InstrumentationProbeSample(hostUs: self.clock, wallTicks: now * 10,
                userTicks: now, systemTicks: now, footprintBytes: 123_456, thermalRaw: 0)
            return self.transform?(value, self.queries) ?? value
        }, sleep: { nanoseconds in
            self.waits.append(nanoseconds)
            self.clock = (self.clock ?? 0) + nanoseconds / 1_000
            try self.onSleep?(self.waits.count)
            await Task.yield()
        }, emit: { self.lines.append($0) }))
    }

    var records: [[String: String]] {
        lines.map { line in
            check(line.hasPrefix("[InstrumentationProbe] ") && !line.contains("\n")
                && line.utf8.count + 1 <= 1024, "Every complete console record is one bounded line")
            return Dictionary(uniqueKeysWithValues: line.split(separator: " ").dropFirst().map {
                let fields = $0.split(separator: "=", maxSplits: 1)
                check(fields.count == 2, "Every allowlisted field has exactly one key/value pair")
                return (String(fields[0]), String(fields[1]))
            })
        }
    }

    func settle() async {
        for _ in 0..<2_000 {
            if records.contains(where: { ["complete", "failed", "stopped"].contains($0["phase"] ?? "") }) {
                for _ in 0..<20 { await Task.yield() }
                return
            }
            await Task.yield()
        }
        fatalError("Injected lifecycle must terminate without real-time waiting")
    }

    func assertTerminal(_ phase: String, _ reason: String, index: Int? = nil) {
        let terminal = records.filter { ["complete", "failed", "stopped"].contains($0["phase"] ?? "") }
        check(terminal.count == 1 && terminal[0]["phase"] == phase && terminal[0]["reason"] == reason,
              "Exactly one terminal with the expected outcome and fixed reason")
        if let index { check(terminal[0]["index"] == String(index), "Terminal index is the last accepted sample") }
        if phase != "complete" { check(!records.contains { $0["phase"] == "complete" }, "An invalid/interrupted run cannot complete") }
    }
}

func withCPU(_ value: InstrumentationProbeSample, wall: UInt64?, user: UInt64?, system: UInt64?) -> InstrumentationProbeSample {
    InstrumentationProbeSample(hostUs: value.hostUs, wallTicks: wall, userTicks: user,
        systemTicks: system, footprintBytes: value.footprintBytes, thermalRaw: value.thermalRaw)
}
func withHost(_ value: InstrumentationProbeSample, _ host: UInt64?) -> InstrumentationProbeSample {
    InstrumentationProbeSample(hostUs: host, wallTicks: value.wallTicks, userTicks: value.userTicks,
        systemTicks: value.systemTicks, footprintBytes: value.footprintBytes, thermalRaw: value.thermalRaw)
}

let completeRun = ProbeHarness()
let completeProbe = completeRun.makeProbe()
completeProbe.start()
completeProbe.start()
await completeRun.settle()
completeRun.assertTerminal("complete", "none", index: 12)
completeProbe.stop()
completeProbe.start()
check(completeRun.lines.count == 15, "Repeated start/stop after completion adds no observers or terminal records")
check(completeRun.waits == [30_000_000_000] + Array(repeating: UInt64(5_000_000_000), count: 12),
      "Thirty seconds warmup followed by exactly twelve five-second waits")
check(completeRun.validations == [false] + Array(repeating: true, count: 13),
      "Startup guard needs no video; every measurement endpoint validates current video/session/mode")
let expectedKeys: Set<String> = ["schema", "session", "mode", "processingMode", "phase", "reason", "index",
    "requestedWidth", "requestedHeight", "requestedFPS", "requestedBitrateKbps", "startedHostUs", "hostUs",
    "firstHostUs", "lastHostUs", "firstWallTicks", "firstUserTicks", "firstSystemTicks", "lastWallTicks",
    "lastUserTicks", "lastSystemTicks", "cpuProcessPercent", "footprintBytes", "thermalRaw"]
for record in completeRun.records {
    check(Set(record.keys) == expectedKeys, "Schema v2 emits only the exact allowlist")
    check(record["schema"] == "2" && record["session"] == completeRun.session.logIdentifier
        && record["processingMode"] == "native" && record["startedHostUs"] == "1000000",
          "Schema, immutable session, required Native mode and warmup identity remain consistent")
    #if DISABLE_PERFORMANCE_COLLECTION
    check(record["mode"] == "disabled", "OFF reports its actual compilation variant")
    #else
    check(record["mode"] == "enabled", "ON reports its actual compilation variant")
    #endif
    check(record["requestedWidth"] == "1920" && record["requestedHeight"] == "1080"
        && record["requestedFPS"] == "60" && record["requestedBitrateKbps"] == "15000", "Requested settings are explicit")
}
let rows = completeRun.records
check(rows[0]["phase"] == "warmup" && rows[0]["firstHostUs"] == "unavailable", "Warmup does not invent an OS endpoint")
check(rows[1]["phase"] == "measureStart" && rows[1]["index"] == "0"
    && rows[1]["hostUs"] == "31000000", "Measured interval starts after the actual thirty-second warmup")
for index in 1...12 {
    let row = rows[index + 1]
    check(row["phase"] == "sample" && row["index"] == String(index) && row["cpuProcessPercent"] == "20.000",
          "Accepted samples are uniquely ordered with valid process CPU percentages")
    for key in ["HostUs", "WallTicks", "UserTicks", "SystemTicks"] {
        check(row["first" + key] == rows[index]["last" + key], "Every interval chains raw endpoints exactly")
    }
    check(row["hostUs"] == row["lastHostUs"], "Observation host timestamp identifies the last endpoint")
}
for key in ["HostUs", "WallTicks", "UserTicks", "SystemTicks"] {
    check(rows.last!["first" + key] == rows[1]["last" + key]
        && rows.last!["last" + key] == rows[13]["last" + key], "Completion spans exact first/last raw endpoints")
}
check(rows.last!["lastHostUs"] == "91000000", "Completion covers sixty seconds of actual host time")
print("PASS: bounded complete lifecycle, strict schema, raw endpoint chaining, identity and ON/OFF labels")

for beforeStart in [true, false] {
    let fixture = ProbeHarness()
    let probe = fixture.makeProbe()
    if beforeStart {
        probe.stop(reason: .modeChanged)
        probe.start()
    } else {
        fixture.onSleep = { _ in probe.stop(reason: .sessionEnded) }
        probe.start()
    }
    await fixture.settle()
    probe.stop()
    fixture.assertTerminal("stopped", beforeStart ? "modeChanged" : "sessionEnded", index: 0)
    check(fixture.queries == 0, "Cancellation before measurement adds no OS query")
    fixture.onSleep = nil
}
let betweenObservations = ProbeHarness()
let switchedProbe = betweenObservations.makeProbe()
betweenObservations.onSleep = { if $0 == 3 { switchedProbe.stop(reason: .modeChanged) } }
switchedProbe.start()
await betweenObservations.settle()
betweenObservations.assertTerminal("stopped", "modeChanged", index: 1)
betweenObservations.onSleep = nil
print("PASS: stop before start, during warmup and between observations is terminal and idempotent")

for (failure, validationIndex) in [(InstrumentationProbeFailure.incompatibleDiagnostics, 1),
                                  (.modeChanged, 1), (.videoUnavailable, 2), (.videoStalled, 4), (.sessionEnded, 5)] {
    let fixture = ProbeHarness()
    fixture.validateResult = { _, call in call == validationIndex ? failure : nil }
    let probe = fixture.makeProbe()
    probe.start()
    await fixture.settle()
    fixture.assertTerminal("failed", failure.rawValue)
    check(fixture.queries == max(0, validationIndex - 2), "Invalid guard prevents the next OS observation")
}
let interrupted = ProbeHarness()
interrupted.onSleep = { _ in throw CancellationError() }
let interruptedProbe = interrupted.makeProbe()
interruptedProbe.start()
await interrupted.settle()
interrupted.assertTerminal("failed", "interrupted", index: 0)
print("PASS: session/mode/video/diagnostic guards and interrupted waits cannot create false completion")

for badClock: UInt64? in [nil, 0] {
    let fixture = ProbeHarness()
    fixture.clock = badClock
    let probe = fixture.makeProbe()
    probe.start()
    await fixture.settle()
    fixture.assertTerminal("failed", "invalidClock", index: 0)
    check(fixture.waits.isEmpty && fixture.queries == 0, "Invalid startup clock refuses the run immediately")
}
for badHost: UInt64? in [nil, 0, 31_000_000, 30_999_999] {
    let fixture = ProbeHarness()
    fixture.transform = { value, query in query == 2 ? withHost(value, badHost) : value }
    let probe = fixture.makeProbe()
    probe.start()
    await fixture.settle()
    fixture.assertTerminal("failed", "invalidClock", index: 0)
}
for caseName in ["warmupShort", "warmupLong", "gap", "durationShort", "durationLong"] {
    let fixture = ProbeHarness()
    fixture.onSleep = { count in
        switch caseName {
        case "warmupShort": if count == 1 { fixture.clock = 30_999_999 }
        case "warmupLong": if count == 1 { fixture.clock = 46_000_001 }
        case "gap": if count == 2 { fixture.clock! += 10_000_001 }
        case "durationShort": if count > 1 { fixture.clock! -= 1_000_000 }
        case "durationLong": if count > 1 { fixture.clock! += 3_000_000 }
        default: break
        }
    }
    let probe = fixture.makeProbe()
    probe.start()
    await fixture.settle()
    fixture.assertTerminal("failed", caseName == "gap" ? "sampleGap" : "durationOutOfBounds")
    fixture.onSleep = nil
}
// Inclusive bounds remain valid: 45 s warmup, 90 s measured duration, one 15 s gap.
let boundary = ProbeHarness()
boundary.onSleep = { count in
    if count == 1 { boundary.clock! += 15_000_000 }
    else if count == 2 { boundary.clock! += 10_000_000 }
    else if count <= 6 { boundary.clock! += 5_000_000 }
}
let boundaryProbe = boundary.makeProbe()
boundaryProbe.start()
await boundary.settle()
boundary.assertTerminal("complete", "none", index: 12)
boundary.onSleep = nil
print("PASS: unavailable/backward host clocks, warmup limits, gaps and actual duration with inclusive boundaries")

for issue in ["missingFirst", "missingMiddle", "zeroWall", "backwardWall", "backwardUser", "backwardSystem", "overflow"] {
    let fixture = ProbeHarness()
    fixture.transform = { value, query in
        if issue == "missingFirst" && query == 1 { return withCPU(value, wall: value.wallTicks, user: nil, system: value.systemTicks) }
        if query != 3 { return value }
        switch issue {
        case "missingMiddle": return withCPU(value, wall: value.wallTicks, user: value.userTicks, system: nil)
        case "zeroWall": return withCPU(value, wall: 0, user: value.userTicks, system: value.systemTicks)
        case "backwardWall": return withCPU(value, wall: 1, user: value.userTicks, system: value.systemTicks)
        case "backwardUser": return withCPU(value, wall: value.wallTicks, user: 1, system: value.systemTicks)
        case "backwardSystem": return withCPU(value, wall: value.wallTicks, user: value.userTicks, system: 1)
        case "overflow": return withCPU(value, wall: value.wallTicks, user: UInt64.max, system: UInt64.max)
        default: return value
        }
    }
    let probe = fixture.makeProbe()
    probe.start()
    await fixture.settle()
    fixture.assertTerminal("failed", "invalidCPU", index: issue == "missingFirst" ? 0 : 1)
    check(fixture.queries <= 3, "A bad intermediate CPU sample stops before a later recovery could hide it")
}
let unavailableMemory = ProbeHarness()
unavailableMemory.transform = { value, _ in
    InstrumentationProbeSample(hostUs: value.hostUs, wallTicks: value.wallTicks,
        userTicks: value.userTicks, systemTicks: value.systemTicks, footprintBytes: nil, thermalRaw: 4)
}
let memoryProbe = unavailableMemory.makeProbe()
memoryProbe.start()
await unavailableMemory.settle()
unavailableMemory.assertTerminal("complete", "none")
check(unavailableMemory.records.last?["footprintBytes"] == "unavailable"
    && unavailableMemory.records.last?["thermalRaw"] == "4", "Memory absence and unknown thermal categories stay explicit")
print("PASS: every CPU endpoint/delta is validated; memory availability is independently reported")

for invalidConfig in [InstrumentationProbeConfiguration(width: 0, height: 1080, fps: 60, bitrate: 15000),
                      .init(width: 1920, height: 16_385, fps: 60, bitrate: 15000),
                      .init(width: 1920, height: 1080, fps: 241, bitrate: 15000),
                      .init(width: 1920, height: 1080, fps: 60, bitrate: Int.max)] {
    let fixture = ProbeHarness()
    fixture.configuration = invalidConfig
    let probe = fixture.makeProbe()
    probe.start()
    await fixture.settle()
    fixture.assertTerminal("failed", "invalidConfiguration")
    check(fixture.queries == 0 && fixture.records[0]["requestedBitrateKbps"] == "unavailable",
          "Invalid settings cannot become a measured configuration")
}
let maximumDelta = InstrumentationProbeCPUDelta.between(sample(wall: 1, user: 0, system: 0),
    sample(wall: 2, user: UInt64.max, system: 0))!
let maximumSample = InstrumentationProbeSample(hostUs: UInt64.max, wallTicks: UInt64.max,
    userTicks: UInt64.max, systemTicks: UInt64.max, footprintBytes: UInt64.max, thermalRaw: Int.min)
for phase: InstrumentationProbePhase in [.warmup, .measureStart, .sample, .complete, .failed, .stopped] {
    let line = InstrumentationProbeRecord(session: completeRun.session,
        configuration: .init(width: 16_384, height: 16_384, fps: 240, bitrate: 1_000_000),
        phase: phase, reason: .incompatibleDiagnostics, index: 12,
        startedHostUs: UInt64.max, hostUs: UInt64.max, first: maximumSample, last: maximumSample,
        delta: maximumDelta).line()
    check(line.utf8.count + 1 <= 1024 && !line.contains("\n"), "Worst-width integers, ratio, labels and newline remain below the transport limit")
}
print("PASS: safe configuration bounds and maximum-width console records including newline")

// Optional cross-language fixture: only the exact production formatter output
// from the successful simulated lifecycle, never raw logs or OS observations.
if CommandLine.arguments.count == 2 {
    try (completeRun.lines.joined(separator: "\n") + "\n").write(
        toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
}
