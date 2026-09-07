import Foundation
import os

/// OS pressure category, not a temperature reading. Preserve future raw values.
struct ThermalReading: Sendable, Equatable {
    let rawValue: Int
    init(_ value: ProcessInfo.ThermalState) { rawValue = value.rawValue }
    init(rawValue: Int) { self.rawValue = rawValue }
    var label: String {
        switch rawValue {
        case ProcessInfo.ThermalState.nominal.rawValue: return "nominal"
        case ProcessInfo.ThermalState.fair.rawValue: return "fair"
        case ProcessInfo.ThermalState.serious.rawValue: return "serious"
        case ProcessInfo.ThermalState.critical.rawValue: return "critical"
        default: return "unknown(\(rawValue))"
        }
    }
}

/// Session-owned snapshots; never called by the real-time audio renderer.
final class AudioThermalMetrics: @unchecked Sendable {
    enum ThermalSource: String, Sendable { case initial, notification, poll }

    struct AudioState: Sendable {
        let sampleRate: Int
        let channels: Int
        let targetSamples: Int
        let buffer: AudioRingBuffer.Diagnostics
        let oversizedRenderRequests: UInt64
        var queuedMilliseconds: Double {
            Double(buffer.availableSamples) * 1_000 / (Double(sampleRate) * Double(channels))
        }
        var peakMilliseconds: Double {
            Double(buffer.peakBufferedSamples) * 1_000 / (Double(sampleRate) * Double(channels))
        }
    }

    struct Sample: Sendable {
        let sequence: UInt64
        let intervalStart: MetricTimestamp?
        let at: MetricTimestamp
        let audio: AudioState
        let thermal: ThermalReading
    }

    struct ThermalEvent: Sendable {
        let sequence: UInt64
        let at: MetricTimestamp
        let state: ThermalReading
        let source: ThermalSource
        let isInitial: Bool
    }

    struct Snapshot: Sendable {
        let session: MetricSessionID
        var isActive = true
        var currentThermal: ThermalReading?
        var notificationsReceived: UInt64 = 0
        var thermalChanges: UInt64 = 0
        var invalidSamples: UInt64 = 0
        var rejectedThermalObservations: UInt64 = 0
        var sampleCount: UInt64 = 0
        var thermalEventCount: UInt64 = 0
        var overwrittenSamples: UInt64 = 0
        var overwrittenThermalEvents: UInt64 = 0
        var samples: [Sample] = []
        var thermalEvents: [ThermalEvent] = []
    }

    private struct Storage {
        var value: Snapshot
        var samples: [Sample?]
        var events: [ThermalEvent?]
        var nextSample = 0
        var nextEvent = 0
        var retainedSamples = 0
        var retainedEvents = 0
        var lastSampleAt: MetricTimestamp?
        var lastThermalAt: MetricTimestamp?

        mutating func observe(_ reading: ThermalReading, at: MetricTimestamp?, source: ThermalSource) {
            if source == .notification { value.notificationsReceived &+= 1 }
            guard let at, lastThermalAt == nil || at.microseconds >= lastThermalAt!.microseconds else {
                value.rejectedThermalObservations &+= 1
                return
            }
            lastThermalAt = at
            guard value.currentThermal != reading else { return }
            let initial = value.currentThermal == nil
            value.currentThermal = reading
            if !initial { value.thermalChanges &+= 1 }
            value.thermalEventCount &+= 1
            let event = ThermalEvent(sequence: value.thermalEventCount, at: at,
                                     state: reading, source: source, isInitial: initial)
            if retainedEvents == events.count { value.overwrittenThermalEvents &+= 1 }
            events[nextEvent] = event
            nextEvent = (nextEvent + 1) % events.count
            retainedEvents = min(retainedEvents + 1, events.count)
        }
    }

    let session: MetricSessionID
    private let state: OSAllocatedUnfairLock<Storage>
    init(session: MetricSessionID, capacity: Int = 64) {
        precondition(capacity > 0)
        self.session = session
        state = OSAllocatedUnfairLock(initialState: Storage(value: Snapshot(session: session),
            samples: Array(repeating: nil, count: capacity), events: Array(repeating: nil, count: capacity)))
    }

    func end() { state.withLock { $0.value.isActive = false } }

    /// Time of local observation: the notification has no transition timestamp.
    func observeThermal(_ reading: ThermalReading, at: MetricTimestamp?, source: ThermalSource) {
        state.withLock {
            guard $0.value.isActive else { return }
            $0.observe(reading, at: at, source: source)
        }
    }

    @discardableResult
    func recordSample(audio: AudioState, thermal: ThermalReading, at: MetricTimestamp?) -> Sample? {
        state.withLock { storage in
            guard storage.value.isActive else { return nil }
            guard let at, audio.sampleRate > 0, audio.channels > 0,
                  storage.lastSampleAt == nil || at.microseconds > storage.lastSampleAt!.microseconds else {
                storage.value.invalidSamples &+= 1
                return nil
            }
            storage.observe(thermal, at: at, source: .poll)
            storage.value.sampleCount &+= 1
            let sample = Sample(sequence: storage.value.sampleCount, intervalStart: storage.lastSampleAt,
                                at: at, audio: audio, thermal: thermal)
            storage.lastSampleAt = at
            if storage.retainedSamples == storage.samples.count { storage.value.overwrittenSamples &+= 1 }
            storage.samples[storage.nextSample] = sample
            storage.nextSample = (storage.nextSample + 1) % storage.samples.count
            storage.retainedSamples = min(storage.retainedSamples + 1, storage.samples.count)
            return sample
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { storage in
            var result = storage.value
            let sampleStart = (storage.nextSample + storage.samples.count - storage.retainedSamples) % storage.samples.count
            result.samples = (0..<storage.retainedSamples).compactMap {
                storage.samples[(sampleStart + $0) % storage.samples.count]
            }
            let eventStart = (storage.nextEvent + storage.events.count - storage.retainedEvents) % storage.events.count
            result.thermalEvents = (0..<storage.retainedEvents).compactMap {
                storage.events[(eventStart + $0) % storage.events.count]
            }
            return result
        }
    }
}
