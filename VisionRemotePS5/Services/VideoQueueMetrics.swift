import Foundation
import Darwin
import os

/// Local renderer events and a bounded, low-frequency memory history. Counts
/// describe distinct causes, not a combined "dropped frames" total.
final class VideoQueueMetrics: @unchecked Sendable {
    static let shared = VideoQueueMetrics()

    enum Event {
        case busyDraw, idleDraw, throttledDraw, drawableUnavailable, encodeFailed
        case submitted, completed, gpuFailed, reusedOutput
    }

    struct MemorySample: Sendable {
        let hostUs: UInt64
        let physicalFootprint: UInt64?
        let deviceAllocatedBytes: Int
        let ownedTextureCount: Int
        let ownedTextureBytes: Int
        let decoderSubmissions: Int
        let decoderPayloadBytes: Int
        let mailboxPixelBytes: Int
    }

    struct Snapshot: Sendable {
        var session: MetricSessionID?
        var isActive = false
        var busyDraws: UInt64 = 0
        var idleDraws: UInt64 = 0
        var throttledDraws: UInt64 = 0
        var drawableUnavailable: UInt64 = 0
        var encodeFailures: UInt64 = 0
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
        var gpuFailures: UInt64 = 0
        var reusedOutputs: UInt64 = 0
        var inFlight = 0
        var peakInFlight = 0
        // Latest reporting renderer's persistent upscaler textures. These are
        // a subset of device allocations, not values to add to process memory.
        var rendererID: UUID?
        var ownedTextureCount = 0
        var ownedTextureBytes = 0
        var memorySamples: [MemorySample] = []
        var overwrittenMemorySamples: UInt64 = 0
    }

    private struct Storage {
        var value = Snapshot()
        var samples: [MemorySample?]
        var next = 0
        var count = 0
    }
    private let state: OSAllocatedUnfairLock<Storage>

    init(memoryCapacity: Int = 64) {
        precondition(memoryCapacity > 0)
        #if DISABLE_PERFORMANCE_COLLECTION
        state = OSAllocatedUnfairLock(initialState: Storage(samples: []))
        #else
        state = OSAllocatedUnfairLock(initialState: Storage(
            samples: Array(repeating: nil, count: memoryCapacity)))
        #endif
    }

    func beginSession(_ session: MetricSessionID) {
        state.withLock { storage in
            storage.value = Snapshot(session: session, isActive: true)
            #if !DISABLE_PERFORMANCE_COLLECTION
            storage.samples = Array(repeating: nil, count: storage.samples.count)
            storage.next = 0
            storage.count = 0
            #endif
        }
    }

    func endSession(_ session: MetricSessionID) {
        state.withLock { if $0.value.session == session { $0.value.isActive = false } }
    }

    @discardableResult
    func record(_ event: Event, session: MetricSessionID) -> Bool {
        #if DISABLE_PERFORMANCE_COLLECTION
        return false
        #else
        state.withLock { storage in
            guard storage.value.session == session else { return false }
            // Terminal callbacks may drain this session after end; they never
            // affect a replacement session. Other observations require activity.
            switch event {
            case .completed, .gpuFailed:
                guard storage.value.inFlight > 0 else { return false }
            default:
                guard storage.value.isActive else { return false }
            }
            switch event {
            case .busyDraw: storage.value.busyDraws &+= 1
            case .idleDraw: storage.value.idleDraws &+= 1
            case .throttledDraw: storage.value.throttledDraws &+= 1
            case .drawableUnavailable: storage.value.drawableUnavailable &+= 1
            case .encodeFailed: storage.value.encodeFailures &+= 1
            case .reusedOutput: storage.value.reusedOutputs &+= 1
            case .submitted:
                storage.value.submitted &+= 1
                storage.value.inFlight += 1
                storage.value.peakInFlight = max(storage.value.peakInFlight, storage.value.inFlight)
            case .completed:
                storage.value.completed &+= 1
                storage.value.inFlight -= 1
            case .gpuFailed:
                storage.value.gpuFailures &+= 1
                storage.value.inFlight -= 1
            }
            return true
        }
        #endif
    }

    func resources(session: MetricSessionID, renderer: UUID, count: Int, bytes: Int) {
        #if !DISABLE_PERFORMANCE_COLLECTION
        state.withLock { storage in
            guard storage.value.isActive, storage.value.session == session else { return }
            storage.value.rendererID = renderer
            storage.value.ownedTextureCount = count
            storage.value.ownedTextureBytes = bytes
        }
        #endif
    }

    func recordMemory(_ sample: MemorySample, session: MetricSessionID) {
        #if !DISABLE_PERFORMANCE_COLLECTION
        state.withLock { storage in
            guard storage.value.isActive, storage.value.session == session else { return }
            if storage.count == storage.samples.count { storage.value.overwrittenMemorySamples &+= 1 }
            storage.samples[storage.next] = sample
            storage.next = (storage.next + 1) % storage.samples.count
            storage.count = min(storage.count + 1, storage.samples.count)
        }
        #endif
    }

    func snapshot() -> Snapshot {
        #if DISABLE_PERFORMANCE_COLLECTION
        return state.withLock { $0.value }
        #else
        state.withLock { storage in
            var result = storage.value
            let start = (storage.next + storage.samples.count - storage.count) % storage.samples.count
            result.memorySamples = (0..<storage.count).compactMap {
                storage.samples[(start + $0) % storage.samples.count]
            }
            return result
        }
        #endif
    }

    /// Process physical footprint, sampled off video/input callbacks. A failure
    /// is unavailable, never zero. This includes more than video resources.
    static func physicalFootprint() -> UInt64? {
        #if DISABLE_PERFORMANCE_COLLECTION
        return nil
        #else
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
        #endif
    }
}

#if DEBUG
/// Finite, opt-in consumer slowdown. No sleeps, extra queue, or stream-setting
/// changes: 15 s baseline, 15 s at <=20 draw admissions/s, 15 s recovery.
struct VideoQueueStress {
    private var start: Double?
    private var previousPhase = ""
    private var lastAdmission: Double = 0

    mutating func step(now: Double) -> (skip: Bool, phaseChange: String?) {
        guard now.isFinite, now > 0 else { return (false, nil) }
        if start == nil { start = now }
        let elapsed = now - (start ?? now)
        let phase = elapsed < 15 ? "baseline" : elapsed < 30 ? "slowConsumer20Hz" : elapsed < 45 ? "recovery" : "complete"
        let changed = phase != previousPhase
        previousPhase = phase
        let skip = phase == "slowConsumer20Hz" && now - lastAdmission < 0.05
        if !skip { lastAdmission = now }
        return (skip, changed ? phase : nil)
    }
}
#endif
