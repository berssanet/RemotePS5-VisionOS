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

/// Common observer for the enabled and disabled collection variants. Production
/// sessions only instantiate this when explicitly launched with the probe flag.
/// It measures process CPU and footprint, not GPU time or causal overhead.
@MainActor
final class InstrumentationOverheadProbe {
    private let session: MetricSessionID
    private var task: Task<Void, Never>?
    private var hasStarted = false

    init(session: MetricSessionID) { self.session = session }

    /// One finite run per instance. Repeated starts cannot create more observers.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let session = session
        Self.emit(session: session, phase: "warmup", index: 0,
                  first: nil, last: nil, delta: nil)
        task = Task {
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                try Task.checkCancellation()
                let first = Self.observe()
                var previous = first
                Self.emit(session: session, phase: "measureStart", index: 0,
                          first: first, last: first, delta: nil)
                for index in 1...12 {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    try Task.checkCancellation()
                    let current = Self.observe()
                    Self.emit(session: session, phase: "sample", index: index,
                              first: previous, last: current,
                              delta: InstrumentationProbeCPUDelta.between(previous, current))
                    previous = current
                }
                Self.emit(session: session, phase: "complete", index: 12,
                          first: first, last: previous,
                          delta: InstrumentationProbeCPUDelta.between(first, previous))
            } catch {
                // Cancellation does not wait for any CPU/GPU work or add another
                // OS observation. An interrupted run has no complete measurement.
            }
        }
    }

    /// Terminal for this session-owned instance; a replacement owns a new probe.
    func stop() {
        hasStarted = true
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }

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

    private static func emit(session: MetricSessionID, phase: String, index: Int,
                             first: InstrumentationProbeSample?, last: InstrumentationProbeSample?,
                             delta: InstrumentationProbeCPUDelta?) {
        #if DISABLE_PERFORMANCE_COLLECTION
        let mode = "disabled"
        #else
        let mode = "enabled"
        #endif
        func number(_ value: UInt64?) -> String { value.map(String.init) ?? "unavailable" }
        let percent = delta.map {
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0.processPercent)
        } ?? "unavailable"
        let hostUs = last == nil ? StreamingMetricsClock.now()?.microseconds : last?.hostUs
        // Only fixed labels, numeric OS data and the opaque random session ID.
        // Printing is opt-in even in Release so the observer is common to A/B.
        print("[InstrumentationProbe] session=\(session.logIdentifier) mode=\(mode) phase=\(phase) index=\(index) hostUs=\(number(hostUs)) cpuProcessPercent=\(percent) footprintBytes=\(number(last?.footprintBytes)) thermalRaw=\(last.map { String($0.thermalRaw) } ?? "unavailable") firstWallTicks=\(number(first?.wallTicks)) firstUserTicks=\(number(first?.userTicks)) firstSystemTicks=\(number(first?.systemTicks)) lastWallTicks=\(number(last?.wallTicks)) lastUserTicks=\(number(last?.userTicks)) lastSystemTicks=\(number(last?.systemTicks)) cpuScope=process oneCorePercent=100 snapshots=independent")
    }
}
