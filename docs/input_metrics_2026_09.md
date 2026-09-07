# Input jitter and local handoff metrics — 2026-09-07

Task 01.04 is independent of the unavailable drawable endpoint in 01.03. It uses
the completed host clock and session identity work (01.01/02). 01.03 was subsequently waived by the user; its presentation endpoint remains
unvalidated. The remaining stage01 work still precedes stage02.

## Collection contract

`StreamingService` creates an `InputMetricsRecorder` for each metrics session.
The input thread and state-handoff callback capture that object. Explicit stop
and the captured native quit close it; late callbacks cannot write into a new
session. A controller reconnection creates a new polling generation with no
previous tick timestamp, so disconnected time is not counted as tick jitter.

- `HighFrequencyInputController` records start-to-start tick intervals and the
  work inside its callback. The existing deadline and no-burst resynchronization
  remain unchanged. Immediate button events are excluded from the tick count.
- The GameController callback records the duration and outcome of
  `ChiakiFullSession.setControllerState`. Calls include periodic samples,
  immediate changes and disconnect neutralization when the input gate is open.
  Legacy direct UI calls outside that callback are not included in these counts.
- `submitted` means the local native state setter accepted the call. `busy`,
  `inactive`, and native errors remain distinct. This is not UDP send duration,
  console receipt, or button-to-image latency. The threshold for a slow local
  call is 8,333 microseconds; this diagnostic threshold is not a latency budget.
- Old per-button/rate console writes and slow-native-call formatting were removed
  from the input path. The old rate mixed polling with immediate callbacks.

The recorder uses a preallocated ring of 2,048 input events and an input-only
try-lock. A contended observation is omitted rather than delaying input; an
atomic `missedSamples` counter records that loss. Invalid clocks and overwritten
retained samples have separate counters. A missed measurement does not mean a
dropped controller state. Counters describe accepted observations, not events
that could not be observed. No shared video lock, file I/O, formatting or explicit
per-event storage allocation is added to collection. Allocation/overhead profiling
remains task 01.08.

Debug reports snapshot and format on the main actor every five seconds. Each
report consumes newly recorded samples by a cumulative acceptance cursor,
including delayed completions and calls crossing reporting boundaries. It never
assigns samples by a wall-clock filter. If more events arrive than the ring can
retain, overwritten events cannot be reconstructed. Reports identify sample
counts and their host-time bounds; p95 uses nearest rank over this retained batch.
The initial report implementation used a time-window filter; the omission of
boundary-crossing calls was corrected and regression-tested before final results.

## Validation

MacBook Pro M3 Pro, Xcode 27.0 (`27A5252f`):

- `scripts/test_input_metrics.sh`: passed. Tick/work separation, local outcomes,
  slow/error injection, invalid/reversed timestamps, bounded storage, concurrent
  snapshots, deterministic contention, and late-session isolation. The actual
  input thread was exercised under concurrent synthetic video callback work,
  including a 20-ms handoff and stop/start with an old callback still pending.
  Report tests cover crossing boundaries, late insertion, repeats and overwrites.
- `scripts/test_feedback_sender.sh`: passed; press/release survives a simulated
  network stall while state updates remain responsive. No native source/archive
  or ABI change was made for this task.
- Signed Debug and unsigned Release visionOS builds: passed, no compiler warning
  or error diagnostics. The synthetic load implementation is excluded in Release.
- Project plist validation and `git diff --check`: passed.

## Physical synthetic-load check

Apple Vision Pro `RealityDevice14,1`, visionOS 27.0 (`24M5361a`), DualSense. Native
PS5 stream requests remain 1920×1080, 60 fps, and the existing bitrate. This is a
short instrumentation check, not a sustained baseline or an overhead comparison.
Game title, power and network conditions were not controlled in this run.

Debug-only launch argument `-InputMetricsVideoLoad` starts one finite test after
the PS5 connects: 15 seconds baseline, 15 seconds synthetic GPU traffic, then
15 seconds recovery. The load uses two reusable private buffers of 8,294,400
bytes, one fill and eight full-buffer copies per command at a requested 60 Hz,
with at most one command in flight. This is GPU/memory traffic, not artificial
video decoding. Source stream settings and input scheduling are unchanged.
Stop/quit cancels future submissions without waiting for GPU completion.

The corrected device run produced the following **batches entirely within each
phase**, selected by their logged host-time bounds. Batches crossing a phase
transition are excluded from this table, not from collection.

| Phase | Complete batches | Tick intervals per batch | Tick interval p95 (ms) | Tick work p95 (ms) | Local handoff p95 (ms) |
|---|---:|---|---|---|---|
| Baseline | 1 | 600 | 9.217 | 0.135 | 0.018 |
| Synthetic GPU | 2 | 602; 601 | 9.127; 8.920 | 0.251; 0.209 | 0.026; 0.021 |
| Recovery | 2 | 626; 614 | 9.063; 9.010 | 0.090; 0.097 | 0.013; 0.013 |

The DualSense appeared about nine seconds after the baseline phase started;
earlier empty reports correctly showed `unavailable`, never zero latency. Only
one baseline batch is available, so these values do not establish improvement,
regression limits or statistical significance. There is no aggregate phase p95.

By the last complete recovery batch: 4,256 observed ticks and 4,256 local calls;
zero slow calls, native errors, busy/inactive outcomes or invalid timestamps;
two missed observations due to collection contention; 2,048 retained samples
with 6,464 old events overwritten. All 902 submitted synthetic GPU commands
completed, with zero failures or skipped timer events. The load reached
`phase=complete` and stopped automatically. The counts demonstrate bounded
collection and observable losses; they do not prove the absence of input latency.

The user confirmed that buttons and analog sticks responded normally on this
corrected build. Task 01.04 is complete with the host/device evidence above.
Injected failures/slow calls were validated by the host harness, not induced in
the live native transport. Neither this run nor the probe validates presentation.

Local evidence: `/tmp/VisionRemotePS5-0104-input-metrics.log`,
`/tmp/VisionRemotePS5-0104-feedback.log`, `/tmp/VisionRemotePS5-sdk27-build.log`,
`/tmp/VisionRemotePS5-0104-release.log`, `/tmp/VisionRemotePS5-0104-device-console.log`.
The earlier device run is retained at `/tmp/VisionRemotePS5-0104-before-report-fix.log`
and is not used for the table. Raw app logs may contain existing native session
data; only filtered metric evidence belongs in shared reports.
