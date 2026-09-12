import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func timestamp(_ micros: UInt64) -> MetricTimestamp { MetricTimestamp(microseconds: micros)! }
func makeSession() -> MetricSessionID { StreamingMetricsRecorder().beginSession() }

/// Inspect machine-readable values without coupling checks to explanatory prose.
func rows(_ identifier: String, in report: String) -> [[String: String]] {
    let lines = report.split(separator: "\n").map(String.init)
    let matches = lines.filter { $0.hasPrefix(identifier + " ") || $0 == identifier }
    return matches.map { line in
        Dictionary(uniqueKeysWithValues: line.split(separator: " ").dropFirst().compactMap {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }
}

func values(_ identifier: String, in report: String) -> [String: String] {
    let matches = rows(identifier, in: report)
    check(matches.count == 1, "Expected one row for \(identifier), found \(matches.count)")
    return matches[0]
}

func checkDuration(_ identifier: String, report: String, count: Int,
                   p50: String, p95: String, p99: String) {
    let row = values(identifier, in: report)
    check(row["count"] == String(count), "\(identifier): retained count")
    check(row["p50Ms"] == p50 && row["p95Ms"] == p95 && row["p99Ms"] == p99,
          "\(identifier): nearest-rank percentiles with explicit millisecond units: \(row)")
}

func render(_ snapshot: PerformanceReportSnapshot, history: PerformanceReportFormatter.History = .retained) -> String {
    do { return try PerformanceReportFormatter.render(snapshot, history: history) }
    catch { fatalError("Valid report failed: \(error)") }
}

func rejectMixedSession(_ snapshot: PerformanceReportSnapshot, _ reason: String) {
    for history: PerformanceReportFormatter.History in [.retained, .latest] {
        do {
            _ = try PerformanceReportFormatter.render(snapshot, history: history)
            fatalError("Accepted inconsistent report: \(reason)")
        } catch PerformanceReportError.inconsistentSession {
            // Expected: never silently combine current and previous connections.
        } catch { fatalError("Unexpected error for \(reason): \(error)") }
    }
}

func appendVideo(_ recorder: StreamingMetricsRecorder, session: MetricSessionID,
                 metric: StreamingMetric = .receiveToDecode, start: UInt64, duration: UInt64) {
    let frame = recorder.nextFrame(in: session)!
    let interval = try! MetricInterval(metric: metric, start: timestamp(start),
                                      end: timestamp(start + duration))
    check(recorder.record(interval, session: session, frame: frame), "Fixture sample accepted")
}

let video = StreamingMetricsRecorder(capacity: 256)
let session = video.beginSession()
// Deliberately descending recording order: sorting timestamps or trusting
// append order instead of durations would produce incorrect nearest ranks.
for milliseconds in (1...100).reversed() {
    appendVideo(video, session: session, start: 1_000_000,
                duration: UInt64(milliseconds) * 1_000)
}
appendVideo(video, session: session, metric: .gpuExecution, start: 7_000_000, duration: 0)
// Integer subtraction must happen before converting high-uptime endpoints.
let largeUptime: UInt64 = 9_000_000_000_000_000_000
appendVideo(video, session: session, metric: .receiveToGPUCompletion,
            start: largeUptime, duration: 5)
var basic = PerformanceReportSnapshot(capturedAt: timestamp(largeUptime + 10), video: video.snapshot()!)
basic.configuration = PerformanceReportConfiguration(session: session, width: 1920,
    height: 1080, framesPerSecond: 60, bitrateKbps: 15_000)
let basicReport = render(basic)
checkDuration("video.receiveToDecode", report: basicReport, count: 100,
              p50: "50.000", p95: "95.000", p99: "99.000")
checkDuration("video.gpuExecution", report: basicReport, count: 1,
              p50: "0.000", p95: "0.000", p99: "0.000")
checkDuration("video.receiveToGPUCompletion", report: basicReport, count: 1,
              p50: "0.005", p95: "0.005", p99: "0.005")
checkDuration("video.receiveToPresentation", report: basicReport, count: 0,
              p50: "unavailable", p95: "unavailable", p99: "unavailable")
let decodeWindow = values("video.receiveToDecode", in: basicReport)
check(decodeWindow["startHostUs"] == "1000000" && decodeWindow["endHostUs"] == "1100000",
      "Decode bounds use only decode samples, not GPU or capture time")
let gpuWindow = values("video.receiveToGPUCompletion", in: basicReport)
check(gpuWindow["startHostUs"] == String(largeUptime)
      && gpuWindow["endHostUs"] == String(largeUptime + 5),
      "Host microseconds remain exact at large uptimes")
let unavailableWindow = values("video.receiveToPresentation", in: basicReport)
check(unavailableWindow["startHostUs"] == "unavailable"
      && unavailableWindow["endHostUs"] == "unavailable",
      "No samples have no observed time window")
print("PASS: unsorted nearest-rank p50/p95/p99, singleton, valid zero, unavailable timing and exact high-uptime subtraction")

let input = InputMetricsRecorder(session: session, capacity: 3)
check(input.recordTick(previous: timestamp(3_000_000), start: timestamp(3_008_000),
                       end: timestamp(3_008_200)), "Fixture tick")
check(input.recordSend(start: timestamp(4_000_000), end: timestamp(4_000_000), outcome: .submitted),
      "Fixture zero-duration local call")
check(input.recordSend(start: timestamp(4_010_000), end: timestamp(4_012_000), outcome: .busy),
      "Fixture busy call")
// First tick's interval is unavailable; it still contributes work duration.
check(input.recordTick(previous: nil, start: timestamp(5_000_000), end: timestamp(5_000_100)),
      "Fixture first-tick work")
basic.input = input.snapshot()
let inputReport = render(basic)
checkDuration("input.tickInterval", report: inputReport, count: 0,
              p50: "unavailable", p95: "unavailable", p99: "unavailable")
checkDuration("input.tickWork", report: inputReport, count: 1,
              p50: "0.100", p95: "0.100", p99: "0.100")
checkDuration("input.localHandoff", report: inputReport, count: 2,
              p50: "0.000", p95: "2.000", p99: "2.000")
let workWindow = values("input.tickWork", in: inputReport)
check(workWindow["startHostUs"] == "5000000" && workWindow["endHostUs"] == "5000100",
      "Tick-work window excludes overwritten tick and local-call bounds")
let handoffWindow = values("input.localHandoff", in: inputReport)
check(handoffWindow["startHostUs"] == "4000000" && handoffWindow["endHostUs"] == "4012000",
      "Local handoff keeps its own retained measurement window")
let intervalInput = InputMetricsRecorder(session: session)
check(intervalInput.recordTick(previous: timestamp(6_000_000), start: timestamp(6_010_000),
                               end: timestamp(6_011_000)), "Fixture interval")
var intervalSnapshot = basic
intervalSnapshot.input = intervalInput.snapshot()
let intervalReport = render(intervalSnapshot)
checkDuration("input.tickInterval", report: intervalReport, count: 1,
              p50: "10.000", p95: "10.000", p99: "10.000")
let intervalWindow = values("input.tickInterval", in: intervalReport)
check(intervalWindow["startHostUs"] == "6000000" && intervalWindow["endHostUs"] == "6010000",
      "Tick interval spans previous-start to current-start, not callback work end")
print("PASS: separate input interval/work/local-call populations, unavailable first interval and independent retained windows")

let boundedVideo = StreamingMetricsRecorder(capacity: 3)
let boundedSession = boundedVideo.beginSession()
for duration in 1...7 {
    appendVideo(boundedVideo, session: boundedSession, start: UInt64(duration) * 1_000_000,
                duration: UInt64(duration) * 1_000)
}
let bounded = PerformanceReportSnapshot(capturedAt: timestamp(8_000_000), video: boundedVideo.snapshot()!)
let boundedReport = render(bounded)
checkDuration("video.receiveToDecode", report: boundedReport, count: 3,
              p50: "6.000", p95: "7.000", p99: "7.000")
let boundedWindow = values("video.receiveToDecode", in: boundedReport)
check(boundedWindow["startHostUs"] == "5000000" && boundedWindow["endHostUs"] == "7007000",
      "Overwritten video samples do not enter percentiles or measurement bounds")
check(boundedReport.count < 100_000, "A bounded capture produces a compact report")
let boundedRetention = values("video", in: boundedReport)
check(boundedRetention["retainedSamples"] == "3" && boundedRetention["overwrittenSamples"] == "4",
      "Video export separates retained samples from lifetime overwrite count")
let inputRetention = values("input.retention", in: inputReport)
check(inputRetention["retainedSamples"] == "3" && inputRetention["overwrittenSamples"] == "1",
      "Input export separates retained samples from lifetime overwrite count")
var missedFixture = basic
missedFixture.input = InputMetricsSnapshot(session: session, isActive: true,
    ticks: 700, calls: 800, slowCalls: 3, errors: 4, busy: 5, inactive: 6,
    missedSamples: 117, invalidSamples: 19, overwrittenSamples: 1_497, samples: basic.input!.samples)
let missedReport = render(missedFixture)
let missedRetention = values("input.retention", in: missedReport)
check(missedRetention["missedSamples"] == "117" && missedRetention["invalidSamples"] == "19"
      && missedRetention["overwrittenSamples"] == "1497" && missedRetention["retainedSamples"] == "3",
      "Lost/invalid/overwritten observations remain distinct from retained population size")
checkDuration("input.localHandoff", report: missedReport, count: 2,
              p50: "0.000", p95: "2.000", p99: "2.000")
print("PASS: bounded video population and retained-window percentiles")

var full = basic
full.decoder = PerformanceDecoderSnapshot(session: session, accepted: 100, rejectedNew: 11,
    outputs: 97, errors: 2, admittedSubmissions: 3, peakAdmittedSubmissions: 12,
    admittedPayloadBytes: 12_345, peakAdmittedPayloadBytes: 54_321, rejectedInvalid: 13,
    rejectedStopped: 17, cancelledBeforeDecode: 19)
full.decoder!.capturedAt = timestamp(12_345_678)
full.mailbox = VideoFrameMailbox.Diagnostics(session: session, isActive: true,
    published: 97, overwrittenBeforeAcquire: 23, acquiredFrames: 72, disabledSubmissions: 29,
    staleSubmissions: 31, clearedBeforeAcquire: 1, occupancy: 1, peakOccupancy: 1,
    retainedPixelBytes: 4_096, peakRetainedPixelBytes: 8_192)
let queue = VideoQueueMetrics(memoryCapacity: 3)
queue.beginSession(session)
for (index, footprint) in [UInt64?(90_000), 80_000, 10_000, nil, 9_000].enumerated() {
    queue.recordMemory(VideoQueueMetrics.MemorySample(hostUs: UInt64(index + 1) * 5_000_000,
        physicalFootprint: footprint, deviceAllocatedBytes: 6_000, ownedTextureCount: 2,
        ownedTextureBytes: 3_000, decoderSubmissions: 3, decoderPayloadBytes: 12_345,
        mailboxPixelBytes: 4_096), session: session)
}
queue.resources(session: session, renderer: UUID(), count: 2, bytes: 3_000)
for event: VideoQueueMetrics.Event in [.busyDraw, .idleDraw, .idleDraw, .throttledDraw,
    .drawableUnavailable, .encodeFailed, .submitted, .submitted, .completed, .gpuFailed, .reusedOutput] {
    check(queue.record(event, session: session), "Fixture renderer event accepted")
}
full.renderer = queue.snapshot()
let pcm = AudioRingBuffer(capacity: 19_200, alignment: 2)
var destination = [Int16](repeating: 0, count: 128)
destination.withUnsafeMutableBufferPointer { _ = pcm.read($0.baseAddress!, count: $0.count) }
let pcmSamples = [Int16](repeating: 1_234, count: 3_840)
pcmSamples.withUnsafeBufferPointer { _ = pcm.write($0.baseAddress!, count: $0.count) }
func audioState() -> AudioThermalMetrics.AudioState {
    AudioThermalMetrics.AudioState(sampleRate: 48_000, channels: 2, targetSamples: 3_840,
        buffer: pcm.diagnostics, oversizedRenderRequests: 7)
}
let audioThermal = AudioThermalMetrics(session: session, capacity: 3)
audioThermal.observeThermal(ThermalReading(.nominal), at: timestamp(1_000_000), source: .initial)
_ = audioThermal.recordSample(audio: audioState(), thermal: ThermalReading(.nominal), at: timestamp(5_000_000))
destination.withUnsafeMutableBufferPointer { _ = pcm.read($0.baseAddress!, count: $0.count) }
audioThermal.observeThermal(ThermalReading(rawValue: 37), at: timestamp(9_000_000), source: .notification)
_ = audioThermal.recordSample(audio: audioState(), thermal: ThermalReading(rawValue: 37), at: timestamp(10_000_000))
full.audioThermal = audioThermal.snapshot()
let fullReport = render(full)
check(values("decoder", in: fullReport)["capturedHostUs"] == "12345678",
      "Decoder gauges preserve their own exact capture timestamp, independent of report capture time")
let decoderEvents = values("decoder.events", in: fullReport)
check(decoderEvents["rejectedNew"] == "11" && decoderEvents["rejectedInvalid"] == "13"
      && decoderEvents["rejectedStopped"] == "17" && decoderEvents["cancelledBeforeDecode"] == "19",
      "Decoder rejection causes remain separately named")
let mailboxEvents = values("mailbox.events", in: fullReport)
check(mailboxEvents["overwrittenBeforeAcquire"] == "23" && mailboxEvents["clearedBeforeAcquire"] == "1"
      && mailboxEvents["disabledSubmissions"] == "29" && mailboxEvents["staleSubmissions"] == "31",
      "Mailbox overwrites, clear and rejected publication causes remain separate")
let rendererEvents = values("renderer", in: fullReport)
let rendererGPU = values("renderer.gpu", in: fullReport)
check(rendererEvents["busyDraws"] == "1" && rendererEvents["idleDraws"] == "2"
      && rendererEvents["throttledDraws"] == "1" && rendererGPU["completed"] == "1"
      && rendererGPU["gpuFailures"] == "1" && rendererGPU["inFlight"] == "0"
      && rendererGPU["peakInFlight"] == "2", "Renderer attempts are not silently combined with GPU outcomes")
let memory = values("memory", in: fullReport)
let footprint = values("memory.footprint", in: fullReport)
check(memory["retainedSamples"] == "3" && memory["overwrittenSamples"] == "2"
      && memory["startHostUs"] == "15000000" && memory["endHostUs"] == "25000000",
      "Memory uses retained bounds and preserves overwritten history count")
check(footprint["validSamples"] == "2" && footprint["firstBytes"] == "10000"
      && footprint["lastBytes"] == "9000" && footprint["minBytes"] == "9000"
      && footprint["maxBytes"] == "10000" && footprint["firstToLastDeltaBytes"] == "-1000",
      "Memory bytes and signed decline exclude unavailable footprint from extrema")
let memoryRows = rows("memory.sample", in: fullReport)
check(memoryRows.count == 3 && memoryRows[1]["footprintBytes"] == "unavailable"
      && memoryRows.allSatisfy { $0["deviceAllocatedBytes"] == "6000"
          && $0["ownedTextureBytes"] == "3000" && $0["decoderPayloadBytes"] == "12345"
          && $0["mailboxPixelBytes"] == "4096" }, "Overlapping memory scopes have explicit byte fields")
var missingFootprint = full
missingFootprint.renderer!.memorySamples = Array(full.renderer!.memorySamples.dropFirst())
let missingFootprintValues = values("memory.footprint", in: render(missingFootprint))
check(missingFootprintValues["firstBytes"] == "unavailable"
      && missingFootprintValues["firstToLastDeltaBytes"] == "unavailable",
      "Missing endpoint cannot become an invented memory-growth delta")
let audioRows = rows("audio.sample", in: fullReport)
check(audioRows.count == 2 && audioRows[0]["queuedSamples"] == "3840"
      && audioRows[0]["queuedMs"] == "40.000" && audioRows[1]["queuedMs"] == "38.667"
      && audioRows[0]["sampleRate"] == "48000" && audioRows[0]["channels"] == "2",
      "Stereo interleaved PCM converts to milliseconds using both sample rate and channels")
check(audioRows[0]["intervalStartUs"] == "unavailable" && audioRows[1]["intervalStartUs"] == "5000000"
      && audioRows[1]["hostUs"] == "10000000", "Audio retains exact paired reporting boundaries")
check(audioRows[0]["underflowReads"] == "1" && audioRows[0]["prePCMUnderflowReads"] == "1"
      && audioRows[0]["missingSamples"] == "128" && audioRows[1]["recoveryEvents"] == "1"
      && audioRows[1]["oversizedRenderRequests"] == "7", "Audio underflow, startup subset and recovery remain distinct")
let thermal = values("thermal", in: fullReport)
let thermalRows = rows("thermal.event", in: fullReport)
check(thermal["currentState"] == "unknown(37)" && thermal["rawState"] == "37"
      && thermal["changes"] == "1" && thermal["notificationsReceived"] == "1"
      && thermalRows[0]["initial"] == "true" && thermalRows[1]["initial"] == "false"
      && thermalRows[1]["source"] == "notification", "Thermal categories and initial/change observations preserve provenance")
var emptyDomains = basic
emptyDomains.renderer = VideoQueueMetrics.Snapshot(session: session)
emptyDomains.audioThermal = AudioThermalMetrics(session: session).snapshot()
let emptyDomainsReport = render(emptyDomains)
check(values("memory", in: emptyDomainsReport)["retainedSamples"] == "0"
      && values("memory.footprint", in: emptyDomainsReport)["minBytes"] == "unavailable"
      && values("thermal", in: emptyDomainsReport)["currentState"] == "unavailable"
      && rows("audio.sample", in: emptyDomainsReport).isEmpty,
      "Available collectors with empty histories do not invent observations")
check(basicReport.contains("renderer unavailable") && basicReport.contains("mailbox unavailable")
      && basicReport.contains("decoder unavailable") && basicReport.contains("audioThermal unavailable")
      && basicReport.contains("memory unavailable"), "Missing optional sources are explicit")
check(fullReport.contains("do not sum them as dropped frames")
      && fullReport.contains("Do not add these scopes") && fullReport.contains("not temperature"),
      "Export explains the non-additive counter/memory scopes and categorical thermal units")
print("PASS: distinct queue/drop events, retained memory byte scopes, unavailable endpoints, PCM units and thermal provenance")

// Compact baseline output selects rows, not source populations. Feed reversed
// snapshots to prove "latest" means chronological newest rather than array.last.
let longMemory = VideoQueueMetrics(memoryCapacity: 64)
longMemory.beginSession(session)
for index in 1...70 {
    longMemory.recordMemory(VideoQueueMetrics.MemorySample(hostUs: UInt64(index) * 5_000_000,
        physicalFootprint: UInt64(index) * 1_000, deviceAllocatedBytes: 6_000,
        ownedTextureCount: 2, ownedTextureBytes: 3_000, decoderSubmissions: 0,
        decoderPayloadBytes: 0, mailboxPixelBytes: 4_096), session: session)
}
let longAudio = AudioThermalMetrics(session: session, capacity: 32)
for index in 1...38 {
    _ = longAudio.recordSample(audio: audioState(),
        thermal: ThermalReading(index.isMultiple(of: 2) ? .fair : .nominal),
        at: timestamp(UInt64(index) * 5_000_000))
}
var longHistory = full
longHistory.renderer = longMemory.snapshot()
longHistory.renderer!.memorySamples.reverse()
longHistory.audioThermal = longAudio.snapshot()
longHistory.audioThermal!.samples.reverse()
longHistory.audioThermal!.thermalEvents.reverse()
let retainedHistory = render(longHistory)
let latestHistory = render(longHistory, history: .latest)
check(try! PerformanceReportFormatter.render(longHistory) == retainedHistory,
      "The default API remains identical to explicit retained-history output")
check(!retainedHistory.contains("rowScope="), "Default export adds no compact-history metadata")
check(rows("memory.sample", in: retainedHistory).count == 64
      && rows("audio.sample", in: retainedHistory).count == 32
      && rows("thermal.event", in: retainedHistory).count == 32,
      "Default export preserves every retained history row")
let latestMemory = rows("memory.sample", in: latestHistory)
let latestAudio = rows("audio.sample", in: latestHistory)
let latestThermal = rows("thermal.event", in: latestHistory)
check(latestMemory.count == 1 && latestMemory[0]["hostUs"] == "350000000"
      && latestAudio.count == 1 && latestAudio[0]["hostUs"] == "190000000"
      && latestThermal.count == 1 && latestThermal[0]["hostUs"] == "190000000",
      "Latest rows independently select each source's newest chronological observation")
for identifier in ["memory", "memory.footprint", "audioThermal", "thermal"] {
    check(values(identifier, in: latestHistory) == values(identifier, in: retainedHistory),
          "\(identifier) summary still describes the actual retained history")
}
check(values("memory", in: latestHistory)["retainedSamples"] == "64"
      && values("memory.footprint", in: latestHistory)["firstToLastDeltaBytes"] == "63000"
      && values("audioThermal", in: latestHistory)["retainedSamples"] == "32",
      "Compact rows cannot mislabel 64/32 retained samples as one or invent zero memory growth")
check(values("memory.rows", in: latestHistory)["sourceRetained"] == "64"
      && values("audio.rows", in: latestHistory)["sourceRetained"] == "32"
      && values("thermal.rows", in: latestHistory)["sourceRetained"] == "32"
      && values("history", in: latestHistory)["independentSampleTime"] == "true",
      "Compact output explicitly states row scope, original population and independent times")
let independentLatest = render(full, history: .latest)
check(values("thermal.event", in: independentLatest)["hostUs"] == "9000000"
      && values("audio.sample", in: independentLatest)["hostUs"] == "10000000"
      && values("memory.sample", in: independentLatest)["hostUs"] == "25000000",
      "An older latest thermal event keeps its observed time; capture cannot invent paired or fresh observations")
for identifier in ["video.receiveToDecode", "video.receiveToGPUCompletion", "video.gpuExecution",
                   "video.receiveToPresentation", "input.tickInterval", "input.tickWork", "input.localHandoff"] {
    check(values(identifier, in: latestHistory) == values(identifier, in: retainedHistory),
          "\(identifier) keeps all retained counts, bounds and percentiles in compact output")
}
let latestMissing = render(basic, history: .latest)
check(latestMissing.contains("memory unavailable") && latestMissing.contains("audioThermal unavailable")
      && rows("memory.sample", in: latestMissing).isEmpty
      && rows("audio.sample", in: latestMissing).isEmpty
      && rows("thermal.event", in: latestMissing).isEmpty,
      "Missing optional collectors stay unavailable in compact output")
let latestEmpty = render(emptyDomains, history: .latest)
for identifier in ["memory.rows", "audio.rows", "thermal.rows"] {
    let row = values(identifier, in: latestEmpty)
    check(row["sourceRetained"] == "0" && row["emittedRows"] == "0",
          "\(identifier) with no retained observations emits no invented row")
}
check(values("memory.footprint", in: latestEmpty)["firstToLastDeltaBytes"] == "unavailable",
      "Empty compact memory history has no growth delta")
var lastFootprintMissing = longHistory
let latestMemoryTime = lastFootprintMissing.renderer!.memorySamples[0].hostUs
lastFootprintMissing.renderer!.memorySamples[0] = VideoQueueMetrics.MemorySample(hostUs: latestMemoryTime,
    physicalFootprint: nil, deviceAllocatedBytes: 6_000, ownedTextureCount: 2,
    ownedTextureBytes: 3_000, decoderSubmissions: 0, decoderPayloadBytes: 0, mailboxPixelBytes: 4_096)
let lastMissingReport = render(lastFootprintMissing, history: .latest)
check(values("memory.sample", in: lastMissingReport)["footprintBytes"] == "unavailable"
      && values("memory.footprint", in: lastMissingReport)["maxBytes"] == "69000"
      && values("memory.footprint", in: lastMissingReport)["firstToLastDeltaBytes"] == "unavailable",
      "Missing latest footprint remains missing while extrema still use older valid retained observations")
check(render(longHistory, history: .latest) == latestHistory,
      "Selecting or editing an independent compact fixture never mutates captured source history")
print("PASS: latest history rows preserve complete summaries, all seven distributions, chronology and unavailable sources")

// A report owns immutable copies. Continuing collection, ending the session,
// and starting another session must not change an already captured report.
let immutableText = render(basic)
appendVideo(video, session: session, start: 10_000_000, duration: 99_000)
_ = input.recordSend(start: timestamp(10_000_000), end: timestamp(10_099_000), outcome: .failed(-7))
video.endSession(session)
input.end()
let ended = PerformanceReportSnapshot(capturedAt: timestamp(11_000_000), video: video.snapshot()!,
                                     input: input.snapshot())
let endedText = render(ended)
let nextSession = video.beginSession()
appendVideo(video, session: nextSession, start: 12_000_000, duration: 1_000)
check(render(basic) == immutableText, "Current capture remains immutable after recorder mutations")
check(render(ended) == endedText, "Ended capture remains immutable after replacement session")
check(endedText.contains(session.logIdentifier) && !endedText.contains(nextSession.logIdentifier),
      "Ended report preserves the previous opaque identity")
let next = PerformanceReportSnapshot(capturedAt: nil, video: video.snapshot()!)
let nextText = render(next)
check(nextText.contains(nextSession.logIdentifier) && !nextText.contains(session.logIdentifier),
      "Replacement report contains only its own opaque identity")
print("PASS: immutable current and ended capture, restart isolation and absent capture clock")

let otherSession = makeSession()
var mixed = basic
mixed.configuration = PerformanceReportConfiguration(session: otherSession, width: 1920,
    height: 1080, framesPerSecond: 60, bitrateKbps: 15_000)
rejectMixedSession(mixed, "configuration")
mixed = basic
mixed.input = InputMetricsRecorder(session: otherSession).snapshot()
rejectMixedSession(mixed, "input")
mixed = basic
mixed.renderer = VideoQueueMetrics.Snapshot(session: otherSession)
rejectMixedSession(mixed, "renderer")
mixed.renderer = VideoQueueMetrics.Snapshot()
rejectMixedSession(mixed, "renderer missing identity")
mixed = basic
mixed.mailbox = VideoFrameMailbox.Diagnostics(session: otherSession)
rejectMixedSession(mixed, "mailbox")
mixed.mailbox = VideoFrameMailbox.Diagnostics()
rejectMixedSession(mixed, "mailbox missing identity")
mixed = basic
mixed.decoder = PerformanceDecoderSnapshot(session: otherSession, accepted: 1, rejectedNew: 0,
    outputs: 1, errors: 0, admittedSubmissions: 0, peakAdmittedSubmissions: 1,
    admittedPayloadBytes: 0, peakAdmittedPayloadBytes: 128, rejectedInvalid: 0,
    rejectedStopped: 0, cancelledBeforeDecode: 0)
rejectMixedSession(mixed, "decoder")
mixed = basic
mixed.audioThermal = AudioThermalMetrics(session: otherSession).snapshot()
rejectMixedSession(mixed, "audio/thermal")
let mismatchedInterval = basic.video.samples[0]
let wrongRecordSession = IdentifiedMetricInterval(session: otherSession,
    frame: mismatchedInterval.frame, interval: mismatchedInterval.interval)
rejectMixedSession(PerformanceReportSnapshot(capturedAt: nil,
    video: MetricSessionSnapshot(session: session, isActive: false,
        samples: [wrongRecordSession], overwrittenSamples: 0)), "video sample session")
let foreignFrame = video.nextFrame(in: nextSession)!
let wrongFrame = IdentifiedMetricInterval(session: session, frame: foreignFrame,
                                         interval: mismatchedInterval.interval)
rejectMixedSession(PerformanceReportSnapshot(capturedAt: nil,
    video: MetricSessionSnapshot(session: session, isActive: false,
        samples: [wrongFrame], overwrittenSamples: 0)), "video frame session")
print("PASS: each optional domain, each video record and each video frame reject mixed session identity")

// The only exportable connection fields are this explicit numeric allowlist.
// A secret in ambient process state must not become part of a report.
let configurationFields = Mirror(reflecting: basic.configuration!).children.compactMap(\.label)
check(configurationFields == ["session", "width", "height", "framesPerSecond", "bitrateKbps"],
      "Connection export DTO requires deliberate review before adding fields")
let sentinel = "report-test-secret-7e8d9f-account-192.0.2.42-payload"
setenv("VISION_PERFORMANCE_REPORT_TEST_SECRET", sentinel, 1)
let privateReport = render(basic)
unsetenv("VISION_PERFORMANCE_REPORT_TEST_SECRET")
check(!privateReport.contains(sentinel), "Formatting never includes ambient secrets")
check(privateReport == immutableText, "Ambient process fields do not alter export")
print("PASS: explicit configuration allowlist and absence of ambient secrets")
