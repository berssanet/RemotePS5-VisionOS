# Audio buffering, recovery and thermal observations — 2026-09-07

Task 01.06 adds session-owned audio/thermal evidence correlated with video queue
and memory observations. Host/build validation and physical metric correlation
passed. The user confirmed normal sound, image and controls after reconnecting
this build; task01.06 is complete.
Task 01.05 is complete following the user's confirmation of normal operation.
Task 01.03 remains waived, without a validated physical presentation endpoint.

## Audio observations

The existing stereo PCM FIFO and AVAudioSourceNode keep their behavior: 48 kHz,
two channels, 200-ms hard capacity, catch-up above 100 ms toward the configured
40-ms target. No audio format, session category, spatialization, scratch buffer,
copy behavior or scheduling policy changes.

| Field | Meaning |
|---|---|
| queuedSamples / queuedMs | Current interleaved Int16 values retained, converted using sample rate × channels. 3,840 values at 48-kHz stereo equal 40 ms. This is queued PCM duration, not sound-to-ear latency or A/V sync error. |
| peakQueuedMs | Largest buffered occupancy observed under the FIFO lock, including brief peaks between periodic reports. |
| writtenSamples / readSamples | Valid aligned producer values supplied, including input later discarded; values consumed from the FIFO. |
| overflowSamples | Values discarded to keep the hard capacity, including an oversized write's old prefix. |
| catchUpSamples / catchUpEvents | Stale buffered values discarded when the consumer exceeds the latency ceiling, and distinct catch-up operations. |
| underflowReads / missingSamples | Reads with insufficient PCM and the missing aligned values, excluding lock contention. The existing output is zero-filled. |
| underflowEpisodes / recoveries | A run of short reads begins one episode; the first subsequent full read completes one recovery. These are local FIFO events, not proof of audible glitches or recovery of network transport. |
| prePCMUnderflowReads / prePCMMissingSamples | The subset of underflows before the first valid PCM write. The engine starts before connection, so initial silence must not be attributed to a gameplay interruption. Later underflows are not automatically network failures. |
| contentionReads / contentionRequestedSamples | Reads returning silence because the existing try-lock failed. This is separate from a known shortage of buffered data and does not open/close a buffer-underflow episode. |
| oversizedRenderRequests | AVAudioSourceNode requests beyond the existing 8,192-frame scratch limit, handled by its existing silence fallback. These bypass FIFO reads. |

PCM counters and occupancy use the FIFO's existing lock. The render callback
still uses try-lock and never waits; failed attempts increment independent atomic
counters. Those atomics can advance during a diagnostic snapshot and are not one
transaction with PCM state. Collection adds only fixed scalar counters/atomics
inside audio paths. The old periodic formatting/console output on the native
audio enqueue callback was removed. Instrumentation overhead remains task01.08.

When quiescent, `written = read + overflow + catchUp + queued` for valid aligned
values. Missing/contended demands are not producer values and must not be added
to that identity. Samples mean interleaved channel values; divide by channels to
obtain stereo frames. Counters reset only after native callbacks are joined and
the audio engine stops, preserving the existing shutdown order.

## Shared observation intervals

The five-second Debug reporter captures the session's audio player and recorder.
`AudioMetrics`, `ThermalMetrics`, `VideoMemory` and `VideoQueues` have identical
`session`, `sample`, `intervalStartUs` and `hostUs` fields for each batch. The first
sample has no inferred interval start. Cumulative counter differences between
successive observations describe the approximate reporting interval; occupancy
is a point sample and peaks are session cumulative.

All domains are read before console output. Their snapshots are nearby, not an
atomic capture across independent producer/consumer queues. `hostUs` is the shared
monotonic reporting marker, not a timestamp for each individual audio operation.
The bounded audio/thermal recorder retains at most 64 samples and 64 thermal
events, with separate overwritten counts. Stop/native quit closes the captured
recorder; an old callback cannot write into a replacement session.

## Thermal state

The recorder keeps the OS categories nominal/fair/serious/critical and preserves
future raw values. These are thermal pressure states, not degrees Celsius.
The initial state is a baseline, not a transition. Received notifications and
observed state changes have separate counters; repeat notifications/polls do not
invent changes. Older or unavailable timestamps cannot regress current state.

The installed Xcode27 `NSProcessInfo.h` requires reading `thermalState` before
registering `thermalStateDidChangeNotification`. The service does so, registers
on the default notification center with its session-owned recorder, then reads
again to reconcile the registration gap. The notification arrives on a global
queue, has no transition timestamp, and performs bounded recording only; periodic
formatting remains outside it. The recorded time is local observation time.
Observer removal happens after closing the recorder, so an already-running old
callback cannot reopen it. Polling at report time also captures observed changes.

The renderer's existing serious/critical fallback to Native remains unchanged.
No artificial thermal state or additional heat load is used in the device test.
If the device remains nominal, report that no real transition was observed;
synthetic transition tests validate recording logic, not physical notifications.

## Validation

MacBook Pro M3 Pro, Xcode27.0 (`27A5252f`):

- `scripts/test_audio_buffer.sh`: passed. Seven-second producer stall remains
  bounded to200ms, then catches up to40ms with stereo alignment. Added exact PCM
  conservation, overflow versus catch-up, underflow/recovery, zero/unaligned input,
  concurrent producer/consumer and deterministic lock-contention checks.
- `scripts/test_audio_thermal_metrics.sh`: passed. Shared video reporting clock,
  exact interval boundaries, PCM-duration units, baseline/repeated/unknown thermal
  states, delayed clocks, bounded ordered histories, end/replacement isolation,
  and4,000 concurrent notifications. Invalid observations cannot regress state.
- Signed Debug and unsigned Release visionOS builds passed with no compiler
  warnings/errors; project plist validation and `git diff --check` passed.
- The real player integration is validated by the visionOS build/device;
  the Foundation host FIFO test does not exercise AVAudioSession or render sizes.

Local evidence: `/tmp/VisionRemotePS5-0106-audio.log` and
`/tmp/VisionRemotePS5-0106-audio-thermal.log`. Only filtered metric lines from
physical logs belong here; native raw logs can contain session credentials.


## Physical playback and reconnection

Signed Debug installed and launched on Apple Vision Pro `RealityDevice14,1`,
visionOS27.0 (`24M5361a`), with normal native PS5 playback. No synthetic load,
render slowdown, audio interruption or thermal override argument was used.
The user connected and reopened the PS5 connection, producing two independent
metric sessions. This is a short instrumentation check, not the sustained baseline.

Evidence is frozen at host timestamp `49804447372` microseconds. The first
session has4 samples from `49625075439` to `49640260296` (15.185s between retained
observations); the second has25 from `49681915089` to `49804447372` (122.532s).
The first connection was reopened before a full minute; no full-minute first-run
claim is made. Durations exclude time before the first report.

All29 `(session,sample)` groups contained exactly one audio, thermal, video-memory
and video-queue report with identical start/end reporting markers. Each interval
starts at the preceding report; the new session restarts sequence1 with unavailable
first interval start. PCM conservation held in every observation.

| Observation through this cutoff | First connection | Reconnection |
|---|---:|---:|
| Sampled queue duration | 30–50ms | 10–100ms |
| Peak buffered duration | 60ms | 110ms |
| Reads short of PCM before first valid write | 150 | 151 |
| Reads short of PCM after first valid write | 4 | 4 |
| Underflow episodes / subsequent full-read recoveries | 4 / 4 | 3 / 3 |
| Hard-capacity discarded values | 0 | 0 |
| Catch-up events / discarded values | 0 / 0 | 1 / 6,720 |
| Try-lock contention reads / requested values | 0 / 0 | 5 / 4,800 |
| Oversized render requests | 0 | 0 |
| Observed thermal state / actual changes | nominal / 0 | nominal / 0 |

A natural catch-up occurred in the second session between `49799266052` and
`49804447372`. Its6,720 discarded interleaved PCM values equal70ms, consistent
with the observed110-ms peak and existing100-ms threshold/40-ms target. The next
report retains960values(10ms). At that checkpoint the exact accounting was
12,266,880 written =12,259,200 read +6,720 catch-up +960 queued; no capacity discard.

Each session had3,840 missing values(40ms) after its first valid PCM input;
initial silence is accounted separately. The second also had4,800 requested
values(50ms) served by the existing silence fallback on lock contention. These
counters identify local handling, not measured audible glitch duration, transport
loss, or causation by the instrumentation. Overhead comparison remains01.08.

Both thermal histories contain one initial nominal event, with zero changes,
notifications, invalid samples or rejected observations. A real non-nominal
transition was not observed. Synthetic state/notification tests validate recorder
logic; they do not substitute for physical thermal notifications. The two histories
retain4 and25 samples respectively, below64, with no overwrites. Decoder/mailbox/GPU
limits and accounting remained bounded, with no GPU/encoding/drawable failures.

The device measurements and reconnection are confirmed by filtered logs. The
user confirmed normal sound, image and controls after reconnecting this build,
completing the listening/regression check and task01.06.
Evidence: `/tmp/VisionRemotePS5-0106-device-console.log`,
`/tmp/VisionRemotePS5-sdk27-build.log`, `/tmp/VisionRemotePS5-0106-release.log`.
