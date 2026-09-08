# Instrumentation overhead comparison — 2026-09-07

Task 01.08 is in progress. Host parity, signed Release builds and the physical
ON/OFF collection are complete. The user confirmed normal image, audio and
controls in both variants. This completes the comparative functional check.
The observed CPU difference does not isolate total instrumentation overhead
under varying gameplay; current game/mode/power details remain unreported.
The quantitative limit remains open and must not be silently treated as passed.

## Comparison protocol and limits

The user will continue normal gameplay with changing scenes. The whole-process
CPU comparison is therefore observational: scene complexity, network behavior,
OS scheduling, temperature and session startup can all differ between runs.
A difference between the two CPU readings cannot be attributed solely to
instrumentation. No resolution, requested cadence or bitrate is reduced.

Use the same source and Xcode 27.0 (`27A5252f`) optimized, signed Release builds,
changing only `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to
`DISABLE_PERFORMANCE_COLLECTION` for the disabled variant. Normal builds keep
collection enabled. Run on the paired physical Vision Pro `RealityDevice14,1`,
visionOS 27.0 (`24M5361a`). Record game, processing mode and power when provided.

Each launch with `-InstrumentationOverheadProbe` starts one finite observer when
PS5 streaming connects: 15 s warmup, an initial observation, then 12 observations
at approximately 5 s intervals. Use the actual monotonic interval, not console
arrival times. The same OS-query/printing code runs in both variants. A cancelled
run has no completed measurement. This short comparison does not satisfy the
20–30 minute baseline in 01.09.

Report process CPU with 100% equal to one occupied core; multiple cores may
exceed 100%. `TASK_ABSOLUTETIME_INFO` supplies cumulative `total_user` and
`total_system` in Mach timebase units, including live/terminated threads.
`100 * (deltaUser + deltaSystem) / deltaMachAbsoluteWall` gives the average over
the actual interval. Do not add `threads_user`/`threads_system`, which are
subsets. Missing, regressing or overflowing endpoints remain unavailable.
Independent `TASK_VM_INFO.phys_footprint` and thermal category observations are
point samples, not a synchronized memory transaction or temperature in Celsius.

Sources inspected: installed SDK `mach/task_info.h` and Apple's
[XNU task implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c),
[recount definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/recount.h).
The opt-in probe retains no history and emits only fixed labels, numbers and an
opaque random session identifier under `[InstrumentationProbe]`.

The previously waived 01.03 endpoint remains unavailable. CPU, GPU completion,
user-reported responsiveness and actual presentation latency are distinct.
No quantitative presentation or button-to-image latency claim is possible from
this comparison. Record persistent visible/input symptoms reported by the user;
silence in the logs does not prove their absence.

## Isolated collector reference

`-InstrumentationCollectorBenchmark` separately opts into one short utility
thread using private recorders and fixed numeric fixtures. It touches no live
game input, PCM, decoder, renderer or export history. When used alongside the
process probe, it starts during the 15 s warmup. Inspect its completed status and
duration before using the later process interval; an incomplete run is not a
completed benchmark.

`clock_gettime(CLOCK_THREAD_CPUTIME_ID)` measures CPU consumed by that thread.
After warmup, six pairs of 1,024 operations alternate control/collection order.
The populations are input `recordTick + recordSend` and video
`nextFrame + record`. The control keeps the loop/checksum/budget checks with
successful-result fixtures; each pair must produce the same checksum. OFF
removes input call sites just as the app does, and calls the video recorder's
disabled public methods. No live recorder is reused.

Report median control/collection nanoseconds per two-method operation and the
median/range of signed paired differences. Negative differences remain negative
and indicate noise. Budget checks are cooperative, target at most 90 ms thread
CPU / 4.9 s wall with headroom, and cannot guarantee a wall deadline under OS
descheduling. Cancellation stops subsequent work without waiting on the UI.

This reference measures only uncontended collector calls. It excludes capture
of each event's clock, audio/decoder inline counters, GPU callbacks, snapshots,
logging, real contention and the rest of the pipeline. Its numbers cannot be
presented as the app's total instrumentation overhead. Changing scenes still
affect scheduling/cache/clock frequency; thread CPU avoids summing the game's
other CPU work but does not eliminate all environmental variation.

## Disabled variant

The compile flag removes performance timing/recording in the video callbacks,
decoder counters, mailbox diagnostics, renderer counters/GPU timing handlers,
input tick/send observations, PCM diagnostic counters, and periodic audio,
thermal and memory collection. Export returns a clear unavailable message.
Bounded metric histories are not allocated in the disabled recorder paths.

Both variants preserve session UUID guards, frame identifiers needed by delivery,
decoder PTS and recovery, 12-slot CPU admission, 2-slot GPU admission, PCM copying
and silence/catch-up/overflow behavior, input scheduling/native calls, resource
ownership through GPU completion, presentation, UI status and the existing
thermal fallback. Operational error/status diagnostics are preserved; this is
not a claim that every clock or every diagnostic in the app/native library is
removed. The probe itself is a deliberately common observer in both variants.

## Automated evidence

Host: MacBook Pro M3 Pro, macOS 26.6.2, selected Xcode 27 beta.

| Check | Result and scope |
|---|---|
| `scripts/test_instrumentation_parity.sh` | ON/OFF passed; identical PCM digest `f45e1e99024588cf` across 254 writes / 258 reads; functional input callbacks and thread restart preserved. |
| `scripts/test_video_instrumentation_parity.sh` | Optimized ON/OFF passed with real H.264/HEVC decode; pixels, dependent frames, monotonic PTS, 12-slot saturation/drain/recovery and mailbox session isolation. Does not exercise MTKView presentation. |
| `scripts/test_instrumentation_overhead_probe.sh` | ON/OFF passed; exact CPU ratios, zero/multicore usage, missing/regressing/overflowing counters, small deltas at large uptimes and independent memory validity. |
| `scripts/test_instrumentation_collector_benchmark.sh` | Optimized ON/OFF passed; real private fixtures, AB/BA/checksum, signed integer differences, cancellation before/during work, CPU/wall budgets and missing/partially regressing clocks at boundaries and inside batches. |
| Enabled audio/input/decoder/GPU suites | Passed following compile-gate changes. Actual host GPU/VideoToolbox access was used where needed. |
| Signed Release ON/OFF visionOS builds | Both passed without compiler warnings/errors. Deployment validation follows. |

Local logs: `/tmp/VisionRemotePS5-0108-parity.log`,
`/tmp/VisionRemotePS5-0108-video-parity.log`,
`/tmp/VisionRemotePS5-0108-probe-host.log`,
`/tmp/VisionRemotePS5-0108-collector-benchmark.log`,
`/tmp/VisionRemotePS5-0108-audio.log`, `/tmp/VisionRemotePS5-0108-input.log`,
`/tmp/VisionRemotePS5-0108-decoder.log`, `/tmp/VisionRemotePS5-0108-gpu.log`,
`/tmp/VisionRemotePS5-0108-release-on.log` and
`/tmp/VisionRemotePS5-0108-release-off.log`.

## Device deployment

Both final Release variants built successfully, with no compiler warnings/errors.
Both variants were installed and launched, then connected to PS5 for the
measurements below. Game, processing mode and current power conditions have been
requested but not yet reported for these runs.

| Variant | Executable SHA-256 |
|---|---|
| ON | `1d50fdd6f6e815b141bf694e776100fdd83e35157d5103acd65028130900d294` |
| OFF | `32ae9bfced43fa69fb264a2c028bc514a39d9f156f173013c7817a9a39f58b2f` |

Artifacts: `/tmp/VisionRemotePS5-overhead-on/Build/Products/Release-xros/VisionRemotePS5.app`
and the equivalent `VisionRemotePS5-overhead-off` path. Installation evidence:
`/tmp/VisionRemotePS5-0108-install-on.log` and
`/tmp/VisionRemotePS5-0108-install-off.log`. Each comparison launch used both
opt-in flags. After capture, the normal ON artifact was reinstalled and launched
without either diagnostic flag, restoring normal collection and export.
Restoration evidence: `/tmp/VisionRemotePS5-0108-restore-on.log` and
`/tmp/VisionRemotePS5-0108-restored-console.log`.

## Physical observations

Each variant had an initial connection that ended during warmup, followed by a
connection with a complete CPU interval. The initial connections have no CPU
measurement and are excluded from that comparison; the reason for their ending
has not been established. Their completed isolated benchmarks are retained below.
No partial interval is presented as a completed run.

For each completed interval, all12 numbered samples chain their raw Mach
endpoints exactly; the final summary matches the initial/final observations.
CPU percentages recalculated from integer raw differences agree with the printed
rounding. The benchmark finished within10 ms wall in every connection, well
before the process measurement after15 s of warmup.

| Observation | Collection ON | Collection OFF |
|---|---:|---:|
| Actual measured duration from host markers | 60.928282 s | 61.183475 s |
| Mean process CPU (one core =100%) | 15.874624% | 23.951034% |
| Approximately5 s CPU intervals, min–max | 14.783–18.991% | 17.179–28.828% |
| Median of interval CPU observations | 15.2735% | 26.1910% |
| Physical footprint, min–max | 126.048–126.095 MiB | 126.657–193.985 MiB |
| Last minus first physical footprint | 0 bytes | +68,190,208 bytes (+65.031 MiB) |
| Sampled OS thermal category | nominal throughout | nominal throughout |
| Raw elapsed wall ticks | 1,462,278,755 | 1,468,403,412 |
| Raw elapsed process CPU ticks | 232,131,249 | 351,697,797 |

OFF consumed about8.08 percentage points more process CPU in this particular
pair. This is not negative instrumentation overhead or evidence that enabling
metrics improves performance. Changing scenes, unconfirmed processing mode and
other uncontrolled session conditions prevent causal attribution. Likewise, the
OFF footprint increase is an observation requiring follow-up, not an established
leak or an instrumentation effect; no steady-memory claim is made for that run.
Thermal categories provide no numerical temperature comparison.

The isolated results below use signed paired median differences in nanoseconds
per two-method operation; each population has six pairs of1,024 operations.
CPU/wall totals include benchmark setup, warmup and budget checks and are not
per-operation costs. All four benchmarks completed successfully.

| Connection | Input tick+send delta (ns/op) | Video frame+record delta (ns/op) | Benchmark CPU / wall (ms) |
|---|---:|---:|---:|
| ON, initial warmup-only stream | +47.159 | +573.242 | 5.604 /8.953 |
| ON, completed CPU stream | +90.108 | +617.330 | 6.351 /9.962 |
| OFF, initial warmup-only stream | 0.000 | −0.000488 | 0.717 /0.942 |
| OFF, completed CPU stream | 0.000 | −0.040527 | 0.332 /0.372 |

Within the completed ON stream, input pair differences span86.710–90.698 ns/op
and video539.021–688.640 ns/op. In the completed OFF stream, input differences
span0–4.517 ns/op and video−1.343–0.041 ns/op. These near-zero signed controls
remain noise; they are not clamped or interpreted as a performance gain. The
measurable ON costs apply only to the two private, uncontended populations, with
the exclusions stated above. They do not estimate full production collection.

Allowlisted source logs: `/tmp/VisionRemotePS5-0108-device-on-console.log` and
`/tmp/VisionRemotePS5-0108-device-off-console.log`. Derived, numeric/opaque-ID-only
summaries are `/tmp/VisionRemotePS5-0108-on-summary.json` and
`/tmp/VisionRemotePS5-0108-off-summary.json`; the local analysis script is
`/tmp/VisionRemotePS5-0108-analyze.py`. Raw app logs remain private and must not be
committed or shared without separate review.

## Profiler limitation

The paired device appeared in both CoreDevice and `xctrace list devices`.
CoreDevice reported the app process, but Time Profiler attachment by app name
and then by its observed PID failed with process-not-found errors. No valid
trace was produced. This does not prove the platform is unsupported: Apple's
[visionOS performance guide](https://developer.apple.com/documentation/visionos/analyzing-the-performance-of-your-visionos-app)
describes Instruments profiling. The common in-process OS observer above avoids
relying on the failed process discovery. It is not a Time Profiler trace.

Evidence: `/tmp/VisionRemotePS5-0108-profiler-probe.log` and
`/tmp/VisionRemotePS5-0108-profiler-pid-probe.log`. Raw device/app logs stay local;
review only the allowlisted measurement prefixes before recording results.
