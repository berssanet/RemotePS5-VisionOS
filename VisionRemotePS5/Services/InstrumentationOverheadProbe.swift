import Foundation
import Darwin

/// Independent OS observations for the opt-in comparison. CPU counters are
/// Mach timebase ticks, not microseconds. A failed query stays unavailable.
struct InstrumentationProbeSample: Sendable {
    let hostUs: UInt64?
    let wallTicks: UInt64?
    let userTicks: UInt64?
    let systemTicks: UInt64?
    let footprintBytes: UInt64?
    let thermalRaw: Int
}

struct InstrumentationProbeCPUDelta: Equatable, Sendable {
    let wallTicks: UInt64
    let userTicks: UInt64
    let systemTicks: UInt64
    /// 100% means one fully occupied core; multiple cores can exceed 100%.
    let processPercent: Double

    static func between(_ first: InstrumentationProbeSample?,
                        _ last: InstrumentationProbeSample?) -> Self? {
        guard let first, let last,
              let firstWall = first.wallTicks, let lastWall = last.wallTicks,
              let firstUser = first.userTicks, let lastUser = last.userTicks,
              let firstSystem = first.systemTicks, let lastSystem = last.systemTicks,
              firstWall > 0, lastWall > firstWall,
              lastUser >= firstUser, lastSystem >= firstSystem else { return nil }
        // Subtract integers before conversion so long process uptimes do not
        // erase small measurement deltas. Never silently wrap a combined delta.
        let wall = lastWall - firstWall
        let user = lastUser - firstUser
        let system = lastSystem - firstSystem
        let total = user.addingReportingOverflow(system)
        guard !total.overflow else { return nil }
        // CPU and wall ticks have the same Mach timebase, which cancels in this
        // ratio. No timebase conversion or processor-count normalization needed.
        let percent = Double(total.partialValue) / Double(wall) * 100
        guard percent.isFinite else { return nil }
        return Self(wallTicks: wall, userTicks: user, systemTicks: system,
                    processPercent: percent)
    }
}

enum InstrumentationProbeFailure: String, Sendable {
    case sessionEnded, modeChanged, videoUnavailable, videoStalled
    case incompatibleDiagnostics, invalidClock, invalidCPU, sampleGap
    case durationOutOfBounds, invalidConfiguration, interrupted
}

struct InstrumentationProbeConfiguration: Equatable, Sendable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int

    var isValid: Bool {
        (1...16_384).contains(width) && (1...16_384).contains(height)
            && (1...240).contains(fps) && (1...1_000_000).contains(bitrate)
    }
}

enum InstrumentationProbePhase: String, Sendable {
    case warmup, measureStart, sample, complete, failed, stopped
}

/// One bounded, allowlisted console record. No external strings or payloads.
struct InstrumentationProbeRecord: Sendable {
    let session: MetricSessionID
    let configuration: InstrumentationProbeConfiguration
    let phase: InstrumentationProbePhase
    let reason: InstrumentationProbeFailure?
    let index: Int
    let startedHostUs: UInt64?
    let hostUs: UInt64?
    let first: InstrumentationProbeSample?
    let last: InstrumentationProbeSample?
    let delta: InstrumentationProbeCPUDelta?

    func line() -> String {
        #if DISABLE_PERFORMANCE_COLLECTION
        let mode = "disabled"
        #else
        let mode = "enabled"
        #endif
        func number(_ value: UInt64?) -> String { value.map(String.init) ?? "unavailable" }
        func setting(_ value: Int) -> String { configuration.isValid ? String(value) : "unavailable" }
        let percent = delta.map {
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0.processPercent)
        } ?? "unavailable"
        return "[InstrumentationProbe] schema=2 session=\(session.logIdentifier) mode=\(mode) processingMode=native phase=\(phase.rawValue) reason=\(reason?.rawValue ?? "none") index=\(index) requestedWidth=\(setting(configuration.width)) requestedHeight=\(setting(configuration.height)) requestedFPS=\(setting(configuration.fps)) requestedBitrateKbps=\(setting(configuration.bitrate)) startedHostUs=\(number(startedHostUs)) hostUs=\(number(hostUs)) firstHostUs=\(number(first?.hostUs)) lastHostUs=\(number(last?.hostUs)) firstWallTicks=\(number(first?.wallTicks)) firstUserTicks=\(number(first?.userTicks)) firstSystemTicks=\(number(first?.systemTicks)) lastWallTicks=\(number(last?.wallTicks)) lastUserTicks=\(number(last?.userTicks)) lastSystemTicks=\(number(last?.systemTicks)) cpuProcessPercent=\(percent) footprintBytes=\(number(last?.footprintBytes)) thermalRaw=\(last.map { String($0.thermalRaw) } ?? "unavailable")"
    }
}

/// Common observer for the enabled and disabled collection variants. This class
/// retains only initial/latest observations, and never changes the live pipeline.
@MainActor
final class InstrumentationOverheadProbe {
    /// Injected only by host tests; production uses the same OS queries and
    /// monotonic clock in both builds. No real-time waiting is required in tests.
    struct Environment {
        var now: @MainActor () -> UInt64?
        var observe: @MainActor () -> InstrumentationProbeSample
        var sleep: @MainActor (UInt64) async throws -> Void
        var emit: @MainActor (String) -> Void

        static var live: Self {
            Self(now: { StreamingMetricsClock.now()?.microseconds },
                 observe: { InstrumentationOverheadProbe.observe() },
                 sleep: { try await Task.sleep(nanoseconds: $0) },
                 emit: { Swift.print($0) })
        }
    }

    private let session: MetricSessionID
    private let configuration: InstrumentationProbeConfiguration
    private let validate: @MainActor (Bool) -> InstrumentationProbeFailure?
    private let environment: Environment
    private var task: Task<Void, Never>?
    private var hasStarted = false
    private var terminal = false
    private var startedHostUs: UInt64?
    private var first: InstrumentationProbeSample?
    private var previous: InstrumentationProbeSample?
    private var index = 0

    init(session: MetricSessionID, configuration: InstrumentationProbeConfiguration,
         validate: @escaping @MainActor (Bool) -> InstrumentationProbeFailure?,
         environment: Environment? = nil) {
        self.session = session
        self.configuration = configuration
        self.validate = validate
        self.environment = environment ?? .live
    }

    /// One finite run per instance. A stop before start is also terminal.
    func start() {
        guard !hasStarted, !terminal else { return }
        hasStarted = true
        startedHostUs = environment.now()
        guard configuration.isValid else { finish(.failed, reason: .invalidConfiguration); return }
        guard let startedHostUs, startedHostUs > 0 else { finish(.failed, reason: .invalidClock); return }
        if let failure = validate(false) { finish(.failed, reason: failure); return }
        emit(.warmup, at: startedHostUs)
        let environment = environment
        task = Task { [weak self] in
            do {
                for step in 0...12 {
                    try await environment.sleep(step == 0 ? 30_000_000_000 : 5_000_000_000)
                    try Task.checkCancellation()
                    guard let owner = self, !owner.terminal else { return }
                    guard owner.acceptObservation(step: step) else { return }
                }
            } catch {
                // Explicit stop already emitted its terminal. An unexpected
                // interrupted wait must never become a completed measurement.
                self?.finish(.failed, reason: .interrupted)
            }
        }
    }

    func stop(reason: InstrumentationProbeFailure = .sessionEnded) {
        finish(.stopped, reason: reason)
    }

    deinit { task?.cancel() }

    /// Invoked after each wait on main, so validation and observation cannot be
    /// interleaved with a mode selection on that actor.
    private func acceptObservation(step: Int) -> Bool {
        if let failure = validate(true) { finish(.failed, reason: failure); return false }
        let current = environment.observe()
        guard let host = current.hostUs, host > 0,
              let startedHostUs, host > startedHostUs else {
            finish(.failed, reason: .invalidClock); return false
        }
        guard current.wallTicks.map({ $0 > 0 }) == true,
              current.userTicks != nil, current.systemTicks != nil else {
            finish(.failed, reason: .invalidCPU); return false
        }
        if step == 0 {
            let warmup = host - startedHostUs
            guard (30_000_000...45_000_000).contains(warmup) else {
                finish(.failed, reason: .durationOutOfBounds); return false
            }
            first = current
            previous = current
            emit(.measureStart, at: host, first: current, last: current)
            return true
        }
        guard let previous, let previousHost = previous.hostUs, host > previousHost else {
            finish(.failed, reason: .invalidClock); return false
        }
        guard host - previousHost <= 15_000_000 else {
            finish(.failed, reason: .sampleGap); return false
        }
        guard let first, let firstHost = first.hostUs else {
            finish(.failed, reason: .invalidClock); return false
        }
        let elapsed = host - firstHost
        guard elapsed <= 90_000_000, step != 12 || elapsed >= 60_000_000 else {
            finish(.failed, reason: .durationOutOfBounds); return false
        }
        guard let delta = InstrumentationProbeCPUDelta.between(previous, current),
              let total = InstrumentationProbeCPUDelta.between(first, current) else {
            finish(.failed, reason: .invalidCPU); return false
        }
        index = step
        self.previous = current
        emit(.sample, at: host, first: previous, last: current, delta: delta)
        if step == 12 {
            terminal = true
            task = nil
            emit(.complete, at: host, first: first, last: current, delta: total)
            return false
        }
        return true
    }

    private func finish(_ phase: InstrumentationProbePhase, reason: InstrumentationProbeFailure) {
        guard !terminal else { return }
        terminal = true
        task?.cancel()
        task = nil
        emit(phase, at: environment.now(), first: first, last: previous, reason: reason)
    }

    private func emit(_ phase: InstrumentationProbePhase, at host: UInt64?,
                      first: InstrumentationProbeSample? = nil,
                      last: InstrumentationProbeSample? = nil,
                      delta: InstrumentationProbeCPUDelta? = nil,
                      reason: InstrumentationProbeFailure? = nil) {
        environment.emit(InstrumentationProbeRecord(session: session, configuration: configuration,
            phase: phase, reason: reason, index: index, startedHostUs: startedHostUs,
            hostUs: host, first: first, last: last, delta: delta).line())
    }

    /// These calls deliberately bypass all performance-collection compile gates.
    /// Run at the same low frequency in both variants and retain no history.
    nonisolated static func observe() -> InstrumentationProbeSample {
        var cpu = task_absolutetime_info_data_t()
        var cpuCount = mach_msg_type_number_t(
            MemoryLayout<task_absolutetime_info_data_t>.size / MemoryLayout<integer_t>.size)
        let requiredCPUCount = cpuCount
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), $0, &cpuCount)
            }
        }
        let wall = mach_absolute_time()
        let hostUs = StreamingMetricsClock.now()?.microseconds
        let cpuAvailable = cpuResult == KERN_SUCCESS && cpuCount >= requiredCPUCount

        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        // phys_footprint is present in revision 1 of task_vm_info. A shorter
        // successful legacy result must not expose a zero-initialized field.
        let footprintEnd = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)
            .map { $0 + MemoryLayout<UInt64>.size }
        let footprintAvailable = vmResult == KERN_SUCCESS
            && footprintEnd.map { Int(vmCount) * MemoryLayout<integer_t>.size >= $0 } == true
        return InstrumentationProbeSample(hostUs: hostUs, wallTicks: wall > 0 ? wall : nil,
            userTicks: cpuAvailable ? cpu.total_user : nil,
            systemTicks: cpuAvailable ? cpu.total_system : nil,
            footprintBytes: footprintAvailable ? vm.phys_footprint : nil,
            thermalRaw: ProcessInfo.processInfo.thermalState.rawValue)
    }

}
