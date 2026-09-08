import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

typealias Benchmark = CollectorBenchmark
require(Benchmark.Pair.signedDifference(7, 10) == -3, "Signed differences must retain negatives")
require(Benchmark.Pair.signedDifference(UInt64.max, UInt64.max - 1) == 1,
        "Subtract integers before converting large timestamps")
require(Benchmark.Pair.signedDifference(UInt64.max - 1, UInt64.max) == -1, "Negative large timestamps")
let pair = Benchmark.Pair(population: .inputTickAndSend, controlNS: 10,
                          collectionNS: 7, operations: 2, controlFirst: true)
require(pair.differencePerOperation == -1.5, "Per-operation denominator is fixture operations, not method count")
require(Benchmark.median([-2, 5, -4, 3]) == 0.5, "Even median preserves signed values")
require(Benchmark.median([9, -3, 1]) == 1, "Odd median")

var configuration = Benchmark.Configuration()
configuration.operations = 128
configuration.pairs = 2
configuration.warmupOperations = 2_048
let completed = Benchmark.run(cancellation: CollectorBenchmarkCancellation(), configuration: configuration)
require(completed.status == .completed, "Small actual fixture run completed: \(completed.status)")
require(completed.pairs.count == 4, "Both populations have two complete pairs")
require(completed.pairs.map(\.controlFirst) == [true, false, true, false], "AB/BA alternates")
require(completed.pairs.allSatisfy { $0.operations == 128 }, "Operation counts are exact")
require(completed.cpuNS > 0 && completed.wallNS > 0, "Actual thread CPU and wall clocks measured")
require(completed.checksum != 0, "Numeric fixture results consumed")
let session = StreamingMetricsRecorder().beginSession()
let log = completed.log(session: session)
require(log.split(separator: "\n").allSatisfy { $0.hasPrefix("[InstrumentationBenchmark]") }, "Log prefix allowlist")
require(log.contains("scope=marginalCollectorCallsOnly"), "Scope is explicit")
#if DISABLE_PERFORMANCE_COLLECTION
require(log.contains("mode=OFF_inputCallsitesElided_videoPublicNoops"), "OFF semantics labelled")
#else
require(log.contains("mode=ON_privateUncontendedCollectors"), "ON semantics labelled")
#endif

let cancelled = CollectorBenchmarkCancellation()
cancelled.cancel()
cancelled.cancel()
let neverStarted = Benchmark.run(cancellation: cancelled)
require(neverStarted.status == .cancelled && neverStarted.pairs.isEmpty && neverStarted.checksum == 0,
        "Pre-cancel avoids allocation and warmup")

let midRunCancellation = CollectorBenchmarkCancellation()
var clockReads = 0
let duringBatch = Benchmark.run(cancellation: midRunCancellation, configuration: configuration,
    cpuNow: {
        clockReads += 1
        if clockReads == 6 { midRunCancellation.cancel() }
        return UInt64(clockReads)
    }, wallNow: { 1 })
require(duringBatch.status == .cancelled && duringBatch.pairs.isEmpty,
        "Cancellation checked inside a warmup batch; incomplete pairs omitted")
require(clockReads == 6, "No further measured work after cancellation check")

configuration.cpuBudgetNS = 0
let cpuLimit = Benchmark.run(cancellation: CollectorBenchmarkCancellation(), configuration: configuration,
                             cpuNow: { 1 }, wallNow: { 1 })
require(cpuLimit.status == .cpuBudget && cpuLimit.checksum == 0, "CPU budget checked before work")
configuration.cpuBudgetNS = 90_000_000
configuration.wallBudgetNS = 0
let wallLimit = Benchmark.run(cancellation: CollectorBenchmarkCancellation(), configuration: configuration,
                              cpuNow: { 1 }, wallNow: { 1 })
require(wallLimit.status == .wallBudget && wallLimit.checksum == 0, "Wall budget checked before work")

let noClock = Benchmark.run(cancellation: CollectorBenchmarkCancellation(), cpuNow: { nil })
require(noClock.status == .clockUnavailable && noClock.pairs.isEmpty, "Unavailable CPU clock is not a zero sample")
var reversedClockRead = 0
let reversedClock = Benchmark.run(cancellation: CollectorBenchmarkCancellation(), cpuNow: {
    reversedClockRead += 1
    return reversedClockRead == 1 ? 2 : 1
}, wallNow: { 1 })
require(reversedClock.status == .clockUnavailable, "CPU clock regression rejected")
var laterClockRead = 0
let lostClock = Benchmark.run(cancellation: CollectorBenchmarkCancellation(), cpuNow: {
    laterClockRead += 1
    return laterClockRead == 4 ? nil : UInt64(laterClockRead)
}, wallNow: { 1 })
require(lostClock.status == .clockUnavailable && lostClock.pairs.isEmpty,
        "CPU clock loss at batch boundary is not reported as completion")

var singleOperation = Benchmark.Configuration()
singleOperation.operations = 1
singleOperation.pairs = 1
singleOperation.warmupOperations = 0
for sequence: [UInt64] in [[1, 2, 3, 100, 50], [1, 2, 3, 4, 100, 50]] {
    var index = 0
    let partialRegression = Benchmark.run(cancellation: CollectorBenchmarkCancellation(),
        configuration: singleOperation, cpuNow: {
            defer { index += 1 }
            return index < sequence.count ? sequence[index] : UInt64(200 + index)
        }, wallNow: { 1 })
    require(partialRegression.status == .clockUnavailable && partialRegression.pairs.isEmpty,
            "Each CPU reading must follow the last accepted boundary or internal check")
}
var wallRead = 0
let partialWallRegression = Benchmark.run(cancellation: CollectorBenchmarkCancellation(),
    configuration: singleOperation, cpuNow: { 1 }, wallNow: {
        wallRead += 1
        return wallRead == 3 ? 15 : UInt64(wallRead * 10)
    })
require(partialWallRegression.status == .clockUnavailable && partialWallRegression.pairs.isEmpty,
        "A wall clock regression above the run's initial timestamp is still invalid")
print("Instrumentation collector benchmark tests passed")
