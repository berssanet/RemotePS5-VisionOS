import Foundation

/// Pure formatting of the numeric export allowlist. No service, configuration
/// object, environment, raw log, file access or network access belongs here.
enum PerformanceReportFormatter {
    /// Controls emitted history rows only. Summary populations and all seven
    /// duration distributions continue to use the complete retained snapshots.
    enum History: Sendable { case retained, latest }

    private struct DurationPoint {
        let microseconds: UInt64
        let start: UInt64?
        let end: UInt64
    }

    static func render(_ snapshot: PerformanceReportSnapshot, history: History = .retained) throws -> String {
        try validateSessions(snapshot)
        var lines = [
            "VisionRemotePS5 performance report",
            "formatVersion=1",
            "session=\(snapshot.video.session.logIdentifier)",
            "capturedHostUs=\(integer(snapshot.capturedAt?.microseconds)) active=\(snapshot.video.isActive)",
            "Scope: local monotonic host observations; domains were copied independently, not atomically.",
            "Percentiles describe retained samples only, not the entire session or end-to-end latency.",
            "Method: nearest-rank ceil(p*n)-1 after sorting integer microseconds; zero duration is valid.",
            "Missing data is unavailable, never a fabricated zero. Each distribution has its own host-time bounds.",
            "Counts are cumulative within each session-owned source unless explicitly marked retained.",
            ""
        ]
        lines.append("Shutdown observations can precede final draining and may leave an unpaired last audio/video sample. Cached decoder capture time is reported separately.")
        if let config = snapshot.configuration {
            lines.append("configuration requestedWidth=\(config.width) requestedHeight=\(config.height) requestedFramesPerSecond=\(config.framesPerSecond) requestedBitrateKbps=\(config.bitrateKbps)")
        } else { lines.append("configuration unavailable") }

        lines += ["", "VIDEO DURATION DISTRIBUTIONS", "video retainedSamples=\(snapshot.video.samples.count) overwrittenSamples=\(snapshot.video.overwrittenSamples) invalidSamples=unavailable"]
        for metric: StreamingMetric in [.receiveToDecode, .receiveToGPUCompletion, .gpuExecution, .receiveToPresentation] {
            let points = snapshot.video.samples.filter { $0.interval.metric == metric }.map {
                DurationPoint(microseconds: $0.interval.duration.microseconds,
                              start: $0.interval.start.microseconds, end: $0.interval.end.microseconds)
            }
            lines.append(distribution("video.\(metric.rawValue)", points))
        }
        lines.append("GPU completion describes finished work; presentation requires a valid drawable endpoint. Neither measures a button-to-image delay.")

        lines += ["", "INPUT DURATION DISTRIBUTIONS"]
        var tickIntervals: [DurationPoint] = []
        var tickWork: [DurationPoint] = []
        var handoffs: [DurationPoint] = []
        if let input = snapshot.input {
            var failureCodes: [Int32: Int] = [:]
            for sample in input.samples {
                switch sample {
                case .tick(let start, let end, let interval, let work):
                    if let interval {
                        let previous = start.microseconds >= interval.microseconds ? start.microseconds - interval.microseconds : nil
                        tickIntervals.append(DurationPoint(microseconds: interval.microseconds, start: previous, end: start.microseconds))
                    }
                    tickWork.append(DurationPoint(microseconds: work.microseconds, start: start.microseconds, end: end.microseconds))
                case .send(let start, let end, let duration, let outcome):
                    handoffs.append(DurationPoint(microseconds: duration.microseconds, start: start.microseconds, end: end.microseconds))
                    if case .failed(let code) = outcome { failureCodes[code, default: 0] += 1 }
                }
            }
            lines.append("input active=\(input.isActive) ticks=\(input.ticks) localHandoffCalls=\(input.calls) slowCalls=\(input.slowCalls) nativeErrors=\(input.errors) busyCalls=\(input.busy) inactiveCalls=\(input.inactive)")
            lines.append("input.retention retainedSamples=\(input.samples.count) overwrittenSamples=\(input.overwrittenSamples) missedSamples=\(input.missedSamples) invalidSamples=\(input.invalidSamples)")
            lines.append("input.nativeFailureCodes retained=" + (failureCodes.isEmpty ? "none" : failureCodes.keys.sorted().map { "\($0):\(failureCodes[$0]!)" }.joined(separator: ",")))
        } else { lines.append("input unavailable") }
        lines.append(distribution("input.tickInterval", tickIntervals))
        lines.append(distribution("input.tickWork", tickWork))
        lines.append(distribution("input.localHandoff", handoffs))
        lines.append("Input handoff includes retained local outcomes; it is not network acknowledgement or PS5 processing time.")

        lines += ["", "QUEUES, DROPS AND RESOURCE REUSE"]
        if let decoder = snapshot.decoder {
            lines.append("decoder capturedHostUs=\(integer(decoder.capturedAt?.microseconds)) capacitySubmissions=12 admittedSubmissions=\(decoder.admittedSubmissions) peakAdmittedSubmissions=\(decoder.peakAdmittedSubmissions) admittedPayloadBytes=\(decoder.admittedPayloadBytes) peakAdmittedPayloadBytes=\(decoder.peakAdmittedPayloadBytes)")
            lines.append("decoder.events accepted=\(decoder.accepted) outputs=\(decoder.outputs) errors=\(decoder.errors) rejectedNew=\(decoder.rejectedNew) rejectedInvalid=\(decoder.rejectedInvalid) rejectedStopped=\(decoder.rejectedStopped) cancelledBeforeDecode=\(decoder.cancelledBeforeDecode)")
        } else { lines.append("decoder unavailable") }
        lines.append("Decoder gauges cover admitted CPU submissions and payload copies until decode submission returns; they do not measure the internal VideoToolbox queue or pool.")
        if let mailbox = snapshot.mailbox {
            lines.append("mailbox active=\(mailbox.isActive) capacity=1 occupancy=\(mailbox.occupancy) peakOccupancy=\(mailbox.peakOccupancy) retainedPixelBytes=\(mailbox.retainedPixelBytes) peakRetainedPixelBytes=\(mailbox.peakRetainedPixelBytes)")
            lines.append("mailbox.events published=\(mailbox.published) overwrittenBeforeAcquire=\(mailbox.overwrittenBeforeAcquire) acquiredFrames=\(mailbox.acquiredFrames) clearedBeforeAcquire=\(mailbox.clearedBeforeAcquire) disabledSubmissions=\(mailbox.disabledSubmissions) staleSubmissions=\(mailbox.staleSubmissions)")
        } else { lines.append("mailbox unavailable") }
        if let renderer = snapshot.renderer {
            lines.append("renderer active=\(renderer.isActive) busyDraws=\(renderer.busyDraws) idleDraws=\(renderer.idleDraws) throttledDraws=\(renderer.throttledDraws) drawableUnavailable=\(renderer.drawableUnavailable) encodeFailures=\(renderer.encodeFailures)")
            lines.append("renderer.gpu submitted=\(renderer.submitted) completed=\(renderer.completed) gpuFailures=\(renderer.gpuFailures) inFlight=\(renderer.inFlight) peakInFlight=\(renderer.peakInFlight)")
            lines.append("renderer.resources rendererID=\(renderer.rendererID?.uuidString ?? "unavailable") ownedTextureCount=\(renderer.ownedTextureCount) ownedTextureBytes=\(renderer.ownedTextureBytes) reusedOutputs=\(renderer.reusedOutputs)")
        } else { lines.append("renderer unavailable") }
        lines.append("Mailbox overwrite means never acquired by the renderer. Draw attempts, busy/idle skips, GPU failures and persistent output reuse are separate counts; do not sum them as dropped frames.")
        lines.append("Owned textures are persistent upscaler resources only; input wrappers, decoder pools and internal MetalFX resources are excluded. Values describe the last reporting renderer.")

        if history == .latest {
            lines.append("history rowScope=latest summaries=sourceRetained independentSampleTime=true")
        }
        appendMemory(snapshot.renderer, history: history, to: &lines)
        appendAudioThermal(snapshot.audioThermal, history: history, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Shared with the opt-in baseline's warmup checks, which need no formatting.
    static func validateSessions(_ snapshot: PerformanceReportSnapshot) throws {
        let session = snapshot.video.session
        if let value = snapshot.configuration, value.session != session { throw PerformanceReportError.inconsistentSession }
        if let value = snapshot.input, value.session != session { throw PerformanceReportError.inconsistentSession }
        if let value = snapshot.renderer, value.session != session { throw PerformanceReportError.inconsistentSession }
        if let value = snapshot.mailbox, value.session != session { throw PerformanceReportError.inconsistentSession }
        if let value = snapshot.decoder, value.session != session { throw PerformanceReportError.inconsistentSession }
        if let value = snapshot.audioThermal, value.session != session { throw PerformanceReportError.inconsistentSession }
        for sample in snapshot.video.samples {
            guard sample.session == session, sample.frame == nil || sample.frame?.session == session else {
                throw PerformanceReportError.inconsistentSession
            }
        }
    }

    private static func distribution(_ name: String, _ points: [DurationPoint]) -> String {
        let sorted = points.map(\.microseconds).sorted()
        let first = points.compactMap(\.start).min()
        let last = points.map(\.end).max()
        // Integer rank arithmetic avoids floating-point selection near UInt64 limits.
        func percentile(_ percent: Int) -> String {
            guard !sorted.isEmpty else { return "unavailable" }
            let n = sorted.count
            let rank = (n / 100) * percent + ((n % 100) * percent + 99) / 100
            return milliseconds(sorted[max(0, rank - 1)])
        }
        return "\(name) count=\(points.count) startHostUs=\(integer(first)) endHostUs=\(integer(last)) p50Ms=\(percentile(50)) p95Ms=\(percentile(95)) p99Ms=\(percentile(99))"
    }

    private static func appendMemory(_ renderer: VideoQueueMetrics.Snapshot?, history: History,
                                     to lines: inout [String]) {
        lines += ["", "MEMORY HISTORY"]
        guard let renderer else { lines.append("memory unavailable"); return }
        let samples = renderer.memorySamples.sorted { $0.hostUs < $1.hostUs }
        let footprintValues = samples.compactMap(\.physicalFootprint)
        lines.append("memory retainedSamples=\(samples.count) overwrittenSamples=\(renderer.overwrittenMemorySamples) startHostUs=\(integer(samples.first?.hostUs)) endHostUs=\(integer(samples.last?.hostUs))")
        lines.append("memory.footprint validSamples=\(footprintValues.count) firstBytes=\(integer(samples.first?.physicalFootprint)) lastBytes=\(integer(samples.last?.physicalFootprint)) minBytes=\(integer(footprintValues.min())) maxBytes=\(integer(footprintValues.max())) firstToLastDeltaBytes=\(difference(samples.first?.physicalFootprint, samples.last?.physicalFootprint))")
        lines.append("Process footprint, Metal device allocations and owned/retained resources overlap. Do not add these scopes; growth alone is not a leak diagnosis.")
        lines.append("Memory rows are chronological; unavailable footprint does not mean zero allocation.")
        let emitted = samples.suffix(history == .latest ? 1 : samples.count)
        if history == .latest {
            lines.append("memory.rows rowScope=latest sourceRetained=\(samples.count) emittedRows=\(emitted.count) independentSampleTime=true")
        }
        for sample in emitted {
            lines.append("memory.sample hostUs=\(sample.hostUs) footprintBytes=\(integer(sample.physicalFootprint)) deviceAllocatedBytes=\(sample.deviceAllocatedBytes) ownedTextureCount=\(sample.ownedTextureCount) ownedTextureBytes=\(sample.ownedTextureBytes) decoderSubmissions=\(sample.decoderSubmissions) decoderPayloadBytes=\(sample.decoderPayloadBytes) mailboxPixelBytes=\(sample.mailboxPixelBytes)")
        }
    }

    private static func appendAudioThermal(_ value: AudioThermalMetrics.Snapshot?, history: History,
                                           to lines: inout [String]) {
        lines += ["", "AUDIO AND THERMAL HISTORY"]
        guard let value else { lines.append("audioThermal unavailable"); return }
        lines.append("audioThermal active=\(value.isActive) sampleCount=\(value.sampleCount) retainedSamples=\(value.samples.count) overwrittenSamples=\(value.overwrittenSamples) invalidSamples=\(value.invalidSamples)")
        lines.append("thermal currentState=\(value.currentThermal?.label ?? "unavailable") rawState=\(value.currentThermal.map { String($0.rawValue) } ?? "unavailable") changes=\(value.thermalChanges) notificationsReceived=\(value.notificationsReceived) rejectedObservations=\(value.rejectedThermalObservations) eventCount=\(value.thermalEventCount) retainedEvents=\(value.thermalEvents.count) overwrittenEvents=\(value.overwrittenThermalEvents)")
        lines.append("Audio counters are cumulative interleaved PCM samples, not stereo frames. Divide samples by sampleRate*channels for seconds; ring capacity/peak are logical buffering.")
        lines.append("prePCM counters are inclusive subsets of underflow/missing totals before first aligned PCM input. Contention emits silence but is separate from buffer underflow and recovery episodes.")
        lines.append("PCM ring fields share a lock snapshot; contention/oversized atomics are sampled independently. The first report in a session has no intervalStartUs; retained histories may begin later. Match audio/video batches only by identical hostUs.")
        lines.append("Thermal state is an OS pressure category, not temperature. Event hostUs is local observation time; initial state is not a thermal change.")
        let samples = value.samples.sorted { $0.at.microseconds < $1.at.microseconds }
        let emittedSamples = samples.suffix(history == .latest ? 1 : samples.count)
        if history == .latest {
            lines.append("audio.rows rowScope=latest sourceRetained=\(samples.count) emittedRows=\(emittedSamples.count) independentSampleTime=true")
        }
        for sample in emittedSamples {
            let audio = sample.audio
            let pcm = audio.buffer
            let queued = audio.sampleRate > 0 && audio.channels > 0 ? decimal(audio.queuedMilliseconds) : "unavailable"
            let peak = audio.sampleRate > 0 && audio.channels > 0 ? decimal(audio.peakMilliseconds) : "unavailable"
            lines.append("audio.sample sequence=\(sample.sequence) intervalStartUs=\(integer(sample.intervalStart?.microseconds)) hostUs=\(sample.at.microseconds) sampleRate=\(audio.sampleRate) channels=\(audio.channels) targetSamples=\(audio.targetSamples) queuedSamples=\(pcm.availableSamples) queuedMs=\(queued) peakQueuedMs=\(peak) capacitySamples=\(pcm.capacity) writtenSamples=\(pcm.writtenSamples) readSamples=\(pcm.readSamples) readCalls=\(pcm.readCalls) underflowReads=\(pcm.underflowReads) missingSamples=\(pcm.missingSamples) prePCMUnderflowReads=\(pcm.prePCMUnderflowReads) prePCMMissingSamples=\(pcm.prePCMMissingSamples) underflowEpisodes=\(pcm.underflowEpisodes) recoveryEvents=\(pcm.recoveryEvents) contentionReads=\(pcm.contentionReads) contentionRequestedSamples=\(pcm.contentionRequestedSamples) overflowDiscardedSamples=\(pcm.overflowDiscardedSamples) catchUpDiscardedSamples=\(pcm.catchUpDiscardedSamples) catchUpEvents=\(pcm.catchUpEvents) oversizedRenderRequests=\(audio.oversizedRenderRequests) thermalState=\(sample.thermal.label) rawThermalState=\(sample.thermal.rawValue)")
        }
        let events = value.thermalEvents.sorted { $0.at.microseconds < $1.at.microseconds }
        let emittedEvents = events.suffix(history == .latest ? 1 : events.count)
        if history == .latest {
            lines.append("thermal.rows rowScope=latest sourceRetained=\(events.count) emittedRows=\(emittedEvents.count) independentSampleTime=true")
        }
        for event in emittedEvents {
            lines.append("thermal.event sequence=\(event.sequence) hostUs=\(event.at.microseconds) state=\(event.state.label) rawState=\(event.state.rawValue) source=\(event.source.rawValue) initial=\(event.isInitial)")
        }
    }

    private static func integer(_ value: UInt64?) -> String { value.map(String.init) ?? "unavailable" }

    /// Exact microsecond resolution with a locale-independent decimal dot.
    private static func milliseconds(_ microseconds: UInt64) -> String {
        let fraction = String(microseconds % 1_000)
        return "\(microseconds / 1_000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
    }

    private static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func difference(_ first: UInt64?, _ last: UInt64?) -> String {
        guard let first, let last else { return "unavailable" }
        return last >= first ? String(last - first) : "-\(first - last)"
    }
}
