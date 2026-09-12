# Instrumentation overhead comparison — 2026-09-09

The revised eight-run ON/OFF study is complete, with 96 valid intervals and an
inconclusive result for attributing process CPU cost to instrumentation. Signed
pair differences have a median of +0.239336 percentage points, opposite block
contrasts, and variation within each variant above 8 points. This is neither
zero overhead nor a performance gain/approval. Task 01.08's quantitative
requirement remains open under the recorded acceptance criteria.

The normal ON app has been restored without diagnostic arguments. The user
previously confirmed normal image/audio/controls in the original comparison;
current-study physical conditions and functional confirmation are pending.
Historical observations below remain separate from the revised study.

## Revised capture protocol

The opt-in observer was strengthened before another physical comparison.
It remains identical in compiled ON/OFF variants; the production collection
gates stay compile-time gates. Run only `-InstrumentationOverheadProbe`, with
Native selected. Combining it with the collector benchmark, Native baseline or
synthetic input/video load refuses the comparison. No setting is changed by the
probe. A mode change, including a switch restored between checkpoints, ends it.

The revised run uses 30 seconds of warmup, followed by 12 observations spaced
approximately five seconds apart. Valid host-clock warmup is 30–45 seconds and
valid measurement duration is 60–90 seconds; a sampling gap above 15 seconds,
missing/regressing clocks or invalid CPU counter interval prevents completion.
Session validity is checked throughout. After warmup, the functional mailbox
must have a frame from the current session and its identifier must advance at
each observation. This common ON/OFF check does not measure delivered frame
rate, GPU completion or physical presentation. Memory stays an independent
observation: missing footprint does not invent zero or invalidate valid CPU.

Predeclared comparison: eight fresh runs in order **ON–OFF–OFF–ON / ON–OFF–OFF–ON**,
using the same source revision/toolchain and recording both executable hashes.
Keep the same device boot throughout this round. The analyzer requires each
run's warmup to start after the preceding measured endpoint, preventing
overlapping or reordered files from being accepted as the planned sequence.
Allow about 12 minutes of timed observation plus installation/reconnection time.
Use the same requested video configuration, Native mode, external power, local
connection and window placement/size. A stable PS5 menu was proposed to reduce
content variation; on 2026-09-09 the user reported the Vision Pro ready to test.
The app was opened with instructions to connect in Native and keep the menu still.
Current-run physical conditions and functional results still need confirmation. Do not
substitute a fixed-content claim if the user continues playing. No title is
required or recorded. Retain interrupted/failed attempts and their fixed reasons;
any replacement must be documented rather than silently removing an outlier.

Each complete run is one observation. Recalculate CPU from its cumulative raw
Mach endpoints over the actual interval. Report signed ON−OFF differences for
four adjacent pairs and their median/range, plus two ABBA block contrasts
`mean(ON1, ON4) − mean(OFF2, OFF3)` (and the second block equivalently).
Describe the range of repeated observations within each variant and thermal/
footprint changes. The 12 internal intervals are not independent repetitions.
Conflicting contrasts, startup/thermal drift or a difference comparable to
same-variant variation leave attribution inconclusive. No automatic acceptance,
confidence interval or universal overhead percentage follows from this small
experiment. Its scope is incremental process CPU in the recorded condition;
GPU cost, energy and physical latency remain outside that estimate.

Versioned console records contain only fixed labels, safe requested video
numbers, OS observations and opaque session IDs. The analyzer must reject
malformed, incomplete or inconsistent sequences without repairing records or
printing unrelated app output. Historical captures below used the older runner;
the revised checks must not be applied retroactively as if they ran on-device.

Preparation validation on 2026-09-08: optimized host tests passed in ON/OFF,
including lifecycle cancellation, invalid clocks/CPU, elapsed-duration boundaries,
configuration bounds and maximum-width records. The actual Swift formatter's
valid synthetic run passed the Python analyzer in both variants. The analyzer
also passed 14 independent synthetic invalid-record, privacy and ABBA tests,
including chronological order, overlap rejection and same-variant ranges.
These are simulated inputs and host checks, not new device measurements.

Signed Release ON/OFF builds passed with Xcode 27, without compiler warnings or
errors. Source: `d9c044d` plus the current uncommitted baseline/probe changes.
The initial sandboxed attempts could not access the signing profile; the builds
succeeded when run with the required access. This preparation step did not
deploy the artifacts; deployment and measurements on September 9 follow below.

| Prepared variant | Executable SHA-256 |
|---|---|
| ON | `3ebd49abf1ebf1c6dbafb506b0e039fb815c8b51f90f74111defd6bc37f5ee89` |
| OFF | `93c1d858cc03a1893cb0b958e2b16b4b75231f3b37d14e3dd9ececa4bbd4eca2` |

Artifacts are in `/tmp/VisionRemotePS5-overhead-validated-{on,off}/Build/Products/Release-xros/VisionRemotePS5.app`.
Evidence: `/tmp/VisionRemotePS5-0108-probe-v2-host.log`,
`/tmp/VisionRemotePS5-0108-probe-analysis.log`,
`/tmp/VisionRemotePS5-0108-validated-release-on-unsandboxed.log` and
`/tmp/VisionRemotePS5-0108-validated-release-off-unsandboxed.log`.
For each future capture, use `python3 scripts/analyze_instrumentation_probe.py CAPTURE`;
for all eight in recorded order, add `--abba` and supply each file explicitly.
The output contains numeric/opaque-ID summaries, fixed failure codes and
`performanceAccepted: null`; it neither prints raw app lines nor auto-approves
the experiment. A failed/interrupted attempt must remain in the evidence.

## Revised device comparison — 2026-09-09

Verified both prepared executable hashes above before deployment. The paired
Vision Pro reports visionOS 27.0 (`24M5361a`) with developer mode enabled.
Installed the prepared artifacts and launched each measured process with only
`-InstrumentationOverheadProbe`. All eight accepted runs have distinct sessions,
Native mode, requested 1920×1080/60/15000 and increasing, nonoverlapping host
clock intervals. These settings and frame progress do not establish equivalent
delivered frame rates or physical presentation latency.

First-run evidence paths: `/tmp/VisionRemotePS5-0108-v2-install-01-on.log` and
`/tmp/VisionRemotePS5-0108-v2-run-01-on-console.log`. These remain local; only
strictly parsed numeric probe records may be used in the analysis. The planned
order was ON–OFF–OFF–ON / ON–OFF–OFF–ON. The result below describes observed CPU
differences; it does not establish a causal overhead value.

The first console connection subsequently ended with XPC/CoreDevice
`connection_invalidated` (code 3), without receiving any probe records. This is
a missing capture, not evidence of an app crash or an overhead measurement.
The user confirmed streaming. Preserved that file and relaunched the same ON
artifact for replacement attempt 2, captured separately at
`/tmp/VisionRemotePS5-0108-v2-run-01-on-attempt02-console.log`.
This attempt completed after a valid 30.416671-second warmup in Native with requested
1920×1080/60/15000. The replacement was chosen for
missing transport evidence before any CPU result, not for its measured value.

All eight runs are technically complete, each with 15 records / 12 valid
intervals and zero rejected records or analysis inconsistencies. The requested
configuration is unchanged and all observed thermal categories are nominal (0).
The accepted set contains 120 records and 96 intervals with zero rejected
records. Current-study menu/power/network/window conditions and functional
observations still await user confirmation. The three additional attempts
described below are retained separately and are not repaired or used as completed
CPU observations. No measured result was removed for its CPU value.

| Run | Collection | Warmup (s) | Measured (s) | Process CPU (% of one core) | Maximum gap (s) |
|---|---|---:|---:|---:|---:|
| 1, replacement attempt 2 | ON | 30.416671 | 61.498996 | 29.114524 | 5.280471 |
| 2 | OFF | 30.298064 | 61.757626 | 26.741618 | 5.314048 |
| 3 | OFF | 30.759617 | 61.478609 | 28.687645 | 5.309887 |
| 4 | ON | 30.149558 | 61.558905 | 21.431261 | 5.273060 |
| 5 | ON | 30.243666 | 61.622576 | 20.444705 | 5.322850 |
| 6, replacement attempt 2 | OFF | 30.268118 | 61.662567 | 22.338938 | 5.333534 |
| 7 | OFF | 30.233386 | 61.098652 | 20.067659 | 5.264296 |
| 8, replacement attempt 2 | ON | 30.296631 | 61.767296 | 22.659184 | 5.327321 |

Measured CPU intervals total 492.445227 seconds (8min12.445s), plus
242.665711 seconds of accepted warmup. From the first warmup to the last measured
endpoint, the round spans 2,921.976973 seconds (48min41.977s), including restarts,
waiting and additional attempts. The longest gap between accepted runs is
1,090.813809 seconds (18min10.814s), before the replacement eighth run. This
time separation leaves room for drift; it is not continuous sustained sampling.

The four signed adjacent-pair differences ON−OFF, in planned order, are
**+2.372906, −7.256384, −1.894233, +2.591525 percentage points**. Their median is
**+0.239336 points**, with range **−7.256384 to +2.591525 points**. ABBA block
contrasts are **−2.441739** and **+0.348646 points**, with opposite signs.

Across four complete observations, ON ranges from 20.444705% to 29.114524%
(spread 8.669819 points); OFF ranges from 20.067659% to 28.687645%
(spread 8.619986 points). Same-variant adjacent differences are OFF2→3
**+1.946027**, ON4→5 **−0.986556**, and OFF6→7 **−2.271279 points**.
These are descriptive differences, not confidence intervals or measurement
error bounds. The 96 internal intervals are not 96 independent replications.

Under the predeclared interpretation, the study is **inconclusive for attributing
instrumentation cost**: the block contrasts disagree and the observed median is
small relative to variation between sessions with the same variant. Do not call
the median a measured causal overhead, clamp negative differences, infer a
speedup, or declare zero/negligible overhead. No acceptance threshold was changed
after seeing these results, and no new repetition is selected to seek a preferred
CPU value. The study was executed; the existing quantitative requirement is not
silently converted to passed. GPU cost, energy, presentation and button-to-image
latency are outside this observation; 01.03 remains waived and 01.10 deferred.

All 104 independent footprint observations were available. ON point samples
span 113.126–126.767 MiB and OFF 124.954–134.438 MiB across separate processes.
Run 7 has a transient observed peak of 134.438 MiB and ends at 126.501 MiB.
Per-run last-minus-first changes range from −0.296875 to +0.046875 MiB. These
short, independent samples do not establish memory overhead or a leak, and do
not replace the sustained Native baseline. Every sampled thermal category was
nominal (0); neither numerical temperature nor intervening category changes
were measured by this probe.

Individual allowlisted summaries: `/tmp/VisionRemotePS5-0108-v2-run-01-on-summary.json`
and the corresponding summary files for runs 2–8. The local
`/tmp/VisionRemotePS5-0108-v2-manifest.json` records all planned runs and the
three additional attempts. The final allowlisted packet is
`/tmp/VisionRemotePS5-0108-v2-final-evidence.json`: eight technically valid runs,
their ABBA analysis and all three preserved attempts. All 11 input files were
stable during final analysis and have SHA-256 hashes recorded there. The parser
keeps `performanceAccepted` and `physicalConditionsVerified` null. An independent
review recomputed all eight CPU means from integer raw tick deltas and checked
the ordering, signs, medians and block contrasts.

Run 6's first process ended by signal 9 (SIGKILL) before emitting any probe
record; its console remains at `/tmp/VisionRemotePS5-0108-v2-run-06-off-console.log`.
Unlike run 1's XPC failure, this is an observed app termination. The log does not
identify its origin or establish a crash, jetsam or watchdog event. In response
to the specific question about this attempt, the user confirmed closing the app
manually. Record it as a user-closed attempt before measurement, not an app crash.
Relaunched the same OFF artifact once for attempt 2, which completed validly.
No CPU value was available when deciding this replacement. Preserve these two unmeasured
attempts alongside the eight planned observations. This explains that interruption;
current-run physical conditions and broader functional review remain separate.

Run 8's first attempt produced 12 valid intermediate intervals but its terminal
line was rejected as `invalid_encoding`. That 550-byte line contains non-ASCII
bytes despite the probe's numeric ASCII-only format; the precise source of the
corruption is not established. The strict analysis retains no accepted terminal
or total CPU mean for this attempt. It remains at
`/tmp/VisionRemotePS5-0108-v2-run-08-on-console.log`, with its separate invalid
summary. Repeated only run 8 using the identical binary, flags and console
transport; valid replacement evidence is at
`/tmp/VisionRemotePS5-0108-v2-run-08-on-attempt02-console.log`. No record was repaired
and no partial mean was substituted for a completed run. Short console lines
are not a guarantee against transport corruption.

After the eighth valid terminal, successfully relaunched the installed ON
artifact without any diagnostic argument. Normal collection/export are restored;
the finite comparison observer is inactive. Restoration evidence:
`/tmp/VisionRemotePS5-0108-v2-restored-normal-launch.log`. The user may reconnect
and use the app normally. No app source change, new build, commit or push was
performed during this device study. Task 01.08 remains open under the current
quantitative criterion, with current-study condition/function confirmation pending.

## Original comparison protocol and limits

The user continued normal gameplay with changing scenes. That whole-process
CPU comparison was therefore observational: scene complexity, network behavior,
OS scheduling, temperature and session startup can all differ between runs.
A difference between the two CPU readings cannot be attributed solely to
instrumentation. No resolution, requested cadence or bitrate is reduced.

Use the same source and Xcode 27.0 (`27A5252f`) optimized, signed Release builds,
changing only `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to
`DISABLE_PERFORMANCE_COLLECTION` for the disabled variant. Normal builds keep
collection enabled. Run on the paired physical Vision Pro `RealityDevice14,1`,
visionOS 27.0 (`24M5361a`). Record processing mode and power when provided.

The original launch with `-InstrumentationOverheadProbe` started one finite observer when
PS5 streaming connected: 15 s warmup, an initial observation, then 12 observations
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
game input, PCM, decoder, renderer or export history. In the original comparison
it ran alongside the process probe during the 15 s warmup. Its completed status
and duration were reviewed before using that later process interval. The revised
protocol requires separate launches; combining these flags now refuses them.

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

## Original device deployment

Both final Release variants built successfully, with no compiler warnings/errors.
Both variants were installed and launched, then connected to PS5 for the
measurements below. Processing mode and power conditions were not established
for these runs; later baseline conditions do not retroactively establish them.

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

## Original physical observations

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
