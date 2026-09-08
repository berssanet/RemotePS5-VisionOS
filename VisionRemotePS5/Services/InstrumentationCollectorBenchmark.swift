import Darwin
import Foundation
import Synchronization

/// Opt-in, private numeric fixtures only. Measures marginal, uncontended collector
/// call CPU cost, not live streaming overhead, latency, GPU work, or clock capture.
/// Budget checks bound additional work; OS descheduling can delay wall-clock exit.
@MainActor
final class InstrumentationCollectorBenchmark {
    private let session: MetricSessionID
    private let cancellation = CollectorBenchmarkCancellation()
    private var started = false

    init(session: MetricSessionID) { self.session = session }
    deinit { cancellation.cancel() }

    func start() {
        guard !started, !cancellation.isCancelled else { return }
        started = true
        let session = session
        let cancellation = cancellation
        let thread = Thread {
            let result = CollectorBenchmark.run(cancellation: cancellation)
            // Intentionally available in Release, once per explicitly requested run.
            Swift.print(result.log(session: session))
        }
        thread.name = "InstrumentationCollectorBenchmark"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { cancellation.cancel() }
}

final class CollectorBenchmarkCancellation: Sendable {
    private let cancelled = Atomic<Bool>(false)
    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
    func cancel() { cancelled.store(true, ordering: .relaxed) }
}

enum CollectorBenchmark {
    enum Population: String, CaseIterable, Sendable {
        // One operation comprises the two named public methods.
        case inputTickAndSend
        case videoFrameAndRecord
    }

    enum Status: String, Sendable {
        case completed, cancelled, cpuBudget, wallBudget, clockUnavailable, invalidFixture
    }

    struct Configuration {
        var operations = 1_024
        var pairs = 6
        var warmupOperations = 2_048
        // Leave headroom below the requested 100 ms CPU / 5 s wall limits.
        var cpuBudgetNS: UInt64 = 90_000_000
        var wallBudgetNS: UInt64 = 4_900_000_000
    }

    struct Pair: Sendable {
        let population: Population
        let controlNS: UInt64
        let collectionNS: UInt64
        let operations: Int
        let controlFirst: Bool
        var differencePerOperation: Double {
            Self.signedDifference(collectionNS, controlNS) / Double(operations)
        }

        static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
            lhs >= rhs ? Double(lhs - rhs) : -Double(rhs - lhs)
        }
    }

    struct Result: Sendable {
        let status: Status
        let pairs: [Pair]
        let checksum: UInt64
        let cpuNS: UInt64
        let wallNS: UInt64

        func log(session: MetricSessionID) -> String {
#if DISABLE_PERFORMANCE_COLLECTION
            let mode = "OFF_inputCallsitesElided_videoPublicNoops"
#else
            let mode = "ON_privateUncontendedCollectors"
#endif
            let prefix = "[InstrumentationBenchmark] session=\(session.logIdentifier) mode=\(mode)"
            var lines = ["\(prefix) status=\(status.rawValue) cpuMs=\(Double(cpuNS) / 1e6) wallMs=\(Double(wallNS) / 1e6) checksum=\(checksum) scope=marginalCollectorCallsOnly excludes=clockCapture,contention,snapshot,logging,audio,GPU,wholePipeline"]
            for population in Population.allCases {
                let values = pairs.filter { $0.population == population }
                guard !values.isEmpty else { continue }
                let control = median(values.map { Double($0.controlNS) / Double($0.operations) })
                let collection = median(values.map { Double($0.collectionNS) / Double($0.operations) })
                let differences = values.map(\.differencePerOperation)
                lines.append("\(prefix) population=\(population.rawValue) methodsPerOp=2 pairs=\(values.count) operationsPerBatch=\(values[0].operations) controlNsPerOp=\(control) collectionNsPerOp=\(collection) signedPairedDeltaNsPerOp=\(median(differences)) deltaMin=\(differences.min()!) deltaMax=\(differences.max()!)")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func threadCPUNanoseconds() -> UInt64? {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0,
              value.tv_sec >= 0, value.tv_nsec >= 0 else { return nil }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    static func run(cancellation: CollectorBenchmarkCancellation,
                    configuration: Configuration = Configuration(),
                    cpuNow: () -> UInt64? = threadCPUNanoseconds,
                    wallNow: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> Result {
        let wallStart = wallNow()
        guard let cpuStart = cpuNow() else {
            return Result(status: .clockUnavailable, pairs: [], checksum: 0, cpuNS: 0, wallNS: 0)
        }
        var lastCPU = cpuStart
        var lastWall = wallStart
        var status: Status = .completed
        var pairs: [Pair] = []
        var checksum: UInt64 = 0
        let operations = min(max(configuration.operations, 1), 2_048)
        let pairCount = min(max(configuration.pairs, 1), 8)
        let warmup = min(max(configuration.warmupOperations, 0), 4_096)
        let cpuBudget = min(configuration.cpuBudgetNS, 90_000_000)
        let wallBudget = min(configuration.wallBudgetNS, 4_900_000_000)

        func checkBudget() -> Bool {
            if cancellation.isCancelled { status = .cancelled; return false }
            let currentWall = wallNow()
            guard currentWall >= lastWall else { status = .clockUnavailable; return false }
            lastWall = currentWall
            if lastWall - wallStart >= wallBudget { status = .wallBudget; return false }
            guard let currentCPU = cpuNow(), currentCPU >= lastCPU else {
                status = .clockUnavailable; return false
            }
            lastCPU = currentCPU
            if lastCPU - cpuStart >= cpuBudget { status = .cpuBudget; return false }
            return true
        }

        func result() -> Result {
            Result(status: status, pairs: pairs, checksum: checksum,
                   cpuNS: lastCPU >= cpuStart ? lastCPU - cpuStart : 0,
                   wallNS: lastWall >= wallStart ? lastWall - wallStart : 0)
        }

        guard checkBudget() else { return result() }
        // Recorders are never shared with the app's live collectors or exports.
        let video = StreamingMetricsRecorder()
        let privateSession = video.beginSession()
#if !DISABLE_PERFORMANCE_COLLECTION
        let input = InputMetricsRecorder(session: privateSession)
#endif
        let previous = MetricTimestamp(microseconds: 1)!
        let start = MetricTimestamp(microseconds: 2)!
        let end = MetricTimestamp(microseconds: 3)!
        let interval = try! MetricInterval(metric: .receiveToDecode, start: start, end: end)

        func batch(_ population: Population, collect: Bool, count: Int) -> (UInt64, UInt64)? {
            guard checkBudget() else { return nil }
            guard let before = cpuNow(), before >= lastCPU else {
                status = .clockUnavailable; return nil
            }
            lastCPU = before
            var digest: UInt64 = 14_695_981_039_346_656_037
            for index in 0..<count {
                if index.isMultiple(of: 64), !checkBudget() { return nil }
                var accepted: UInt64
#if DISABLE_PERFORMANCE_COLLECTION
                accepted = 0
#else
                accepted = population == .inputTickAndSend ? 2 : 1
#endif
                if collect {
                    switch population {
                    case .inputTickAndSend:
                        // InputMetricsRecorder itself is ungated: mirror the app's
                        // compile-time removal of its allocation and call sites.
#if !DISABLE_PERFORMANCE_COLLECTION
                        let tick = input.recordTick(previous: previous, start: start, end: end)
                        let send = input.recordSend(start: start, end: end, outcome: .submitted)
                        accepted = (tick ? 1 : 0) + (send ? 1 : 0)
#endif
                    case .videoFrameAndRecord:
                        let frame = video.nextFrame(in: privateSession)
                        let recorded = video.record(interval, session: privateSession, frame: frame)
                        accepted = recorded && frame != nil ? 1 : 0
                    }
                }
                digest = (digest ^ UInt64(index) ^ accepted) &* 1_099_511_628_211
            }
            guard let after = cpuNow(), after >= before, after >= lastCPU else {
                status = .clockUnavailable; return nil
            }
            lastCPU = after
            checksum = (checksum &* 1_099_511_628_211) ^ digest
            guard checkBudget() else { return nil }
            return (after - before, digest)
        }

        for population in Population.allCases {
            if warmup > 0 {
                guard batch(population, collect: false, count: warmup) != nil,
                      batch(population, collect: true, count: warmup) != nil else { return result() }
            }
            for index in 0..<pairCount {
                let controlFirst = index.isMultiple(of: 2)
                guard let first = batch(population, collect: !controlFirst, count: operations),
                      let second = batch(population, collect: controlFirst, count: operations) else {
                    return result()
                }
                guard first.1 == second.1 else { status = .invalidFixture; return result() }
                pairs.append(Pair(population: population,
                                  controlNS: controlFirst ? first.0 : second.0,
                                  collectionNS: controlFirst ? second.0 : first.0,
                                  operations: operations, controlFirst: controlFirst))
            }
        }
        _ = checkBudget()
        return result()
    }
}
