# Sustained Native baseline capture

The corrected task 01.09 capture completed 20 minutes on the Vision Pro with all
236 checkpoints and its terminal intact. Structural capture validation passed,
and the user subsequently confirmed that image, audio and controls remained
normal. The user also confirmed a local connection, external power and the
expected window size. Task 01.09 is complete
as an observational Native baseline. Window geometry was confirmed qualitatively,
without an angular-size measurement; exact geometry must be recorded for
comparisons that depend on it.
The first run lost three records in console transport and remains partial
evidence; its results are separate from the corrected capture.

Launch with `-NativeBaselineCapture` to collect during a Native PS5 session.
Normal launches do not start it. The service refuses to combine this capture
with the existing overhead, collector benchmark or synthetic-load arguments.
It observes the processing selection and cancels on any switch away from Native,
including changes between periodic samples; it never changes the user's mode.

Capture uses the existing bounded, typed performance snapshot and formatter.
After 30 seconds of host-clock warmup, checkpoints are emitted about every
5 seconds until at least 20 minutes of measured host time have elapsed. A run
beyond 30 minutes or a gap over 15 seconds is rejected; a resumed app must not
mistake a long suspension for continuous capture. Session changes, unavailable
or regressing clocks, explicit stop and formatting failures cannot report success.

Each `[NativeBaseline]` line contains one JSON record with an opaque capture ID,
session, sequence, host-time bounds and escaped report text. Formatting and file
output run off the main actor with one operation in flight. The explicit capture
argument enables a bounded local metric file; normal launches do not save these
captures, and nothing is transmitted over the network. The console reports only
short progress lines for this diagnostic. Other native console logs can contain
unrelated sensitive data and are not part of the metric file. A write already
begun may finish after cancellation and remains identified by its original
capture/session.

Percentiles describe each retained window, with its own count and time bounds.
The 256 video entries cover only the newest portion of a checkpoint interval;
video gaps are expected and input windows can overlap. Never combine window
percentiles into a whole-session percentile. Compact history output emits only
the latest memory/audio/thermal row while keeping summaries over the actual
retained source history. Use independent row timestamps and cumulative counters
to reconstruct the sampled timeline; do not infer steady memory from one point.

Future baseline runs require a recorded connection type,
power conditions and repeatable Native screen placement/size. Changing game
scenes is allowed and must be documented. OS thermal categories are not numerical
temperatures, and the waived presentation endpoint remains unavailable.

Host validation is provided by `scripts/test_sustained_baseline.sh` and the
existing `scripts/test_performance_report.sh`. The former simulates elapsed time;
passing it does not substitute for playing on the Vision Pro for 20–30 minutes.

Validation on 2026-09-08 with Xcode 27: both host scripts passed, including
session validation during warmup, cancellation during formatting, exact
15-second gap boundaries and a simulated continuous 20-minute run. Signed Release
builds with collection enabled and disabled passed without compiler warnings or
errors. No new device installation or physical baseline was performed in this
validation. Local evidence: `/tmp/VisionRemotePS5-commit-report.log`,
`/tmp/VisionRemotePS5-commit-baseline.log`,
`/tmp/VisionRemotePS5-commit-release.log` and
`/tmp/VisionRemotePS5-commit-disabled.log`.

## Physical run preparation — 2026-09-08

Source: `d9c044d`, branch `docs/active-streaming-paths`. The worktree was clean
when preparation resumed. Installed the tested, signed Release artifact on the
paired Vision Pro `RealityDevice14,1`, visionOS 27.0 (`24M5361a`). CoreDevice
initially reported an inactive development connection; installation nevertheless
succeeded and the app launched with `-NativeBaselineCapture` only.

Executable SHA-256:
`55646e356bbf1e35f92ad7b6b75587c2d054ef999b53f06bc3097f8e05d2f3a0`.
Local installation evidence: `/tmp/VisionRemotePS5-0109-install.log`.
Live capture: `/tmp/VisionRemotePS5-0109-device-console.log`.

The user was asked to connect to PS5, retain 1080p/Native and the window size,
and report local/internet connection and external power. Changing scenes
is explicitly permitted. Those conditions and a completed physical duration
must be recorded before evaluating acceptance; installation is not a passed
baseline. No new commit or push was requested for this run.

The run reached a `completed` terminal at 1,200,796,805 microseconds of measured
host time (20.013 minutes). It emitted 235 checkpoints; only 232 are valid in the
console file. Three records were rejected as `invalid_json`, so sequence
validation reports `invalid_capture`, despite the app's completed terminal.
For one rejected record, a native audio stderr message interrupted the stdout
JSON exactly after 1,024 bytes; its continuation appeared on the next line.
The analyzer does not repair or accept these fragments.

Missing checkpoint sequences are 160, 222 and 230. The following ranges describe
the p95 of each of the 232 readable retained windows; they are not a p95 over the
20-minute run. Video windows have gaps and input windows can overlap.

| Measured interval | Minimum window p95 (ms) | Maximum window p95 (ms) |
| --- | ---: | ---: |
| Receive to decode | 3.817 | 7.739 |
| Receive to GPU completion | 14.734 | 18.148 |
| GPU execution | 0.787 | 3.115 |
| Input tick interval | 8.783 | 9.332 |
| Input tick work | 0.050 | 0.203 |
| Local input handoff | 0.005 | 0.012 |

Physical presentation time remains unavailable as recorded in waived task
01.03; GPU completion is not a substitute. Requested configuration stayed
1920×1080, 60 fps and 15,000 kbps; these settings are not measurements of delivered
frame rate or bitrate. Cumulative mailbox overwrites before acquisition increased
by 3,638; decoder new-frame rejections and GPU failures each increased by zero.
These counters describe separate stages and must not be summed into total drops.

There were 203 distinct memory/audio observations. Process footprint was
127.501 MiB initially, peaked at 227.376 MiB and ended at 205.407 MiB. The 53
observations in the final five-minute interval span 290.330 seconds and range
from 205.360 to 205.485 MiB, with a first-to-last change of −0.031 MiB. This is a
sampled plateau after initial growth, not a general leak verdict; Metal allocation
and process footprint overlap.

Audio counters increased by 412 underflow reads, 140 underflow episodes, 60
catch-up events and 24 contention reads, with no overflow discards or oversized
render requests. Their first/last independently timestamped observations span
1,202.872 seconds, slightly beyond the checkpoint bounds. Counters alone do not
establish audible glitches. Input native errors remained zero; six metric
observations were missed, which does not mean six control commands were lost.

The 232 readable checkpoints had no GPU failures or decoder `rejectedNew`
events, and the recorded thermal category stayed nominal. These are partial
observations, not a passed baseline. Fourteen arithmetic/configuration checks
over those checkpoints found no violations. UI/functionality and test conditions
still require the user's report. A dedicated local metric file replaces the
mixed console transport in the following correction.

Local numeric evidence: `/tmp/VisionRemotePS5-0109-summary.json` and
`/tmp/VisionRemotePS5-0109-numeric-audit.json`. The raw console stays local and is
not suitable for publication because it includes unrelated native logs.

## Dedicated capture file

The replacement transport uses the same explicit launch argument. It writes
only baseline records to
`Library/Caches/NativeBaseline/<captureID>.ndjson.partial` in the app's private
data container, then publishes `<captureID>.ndjson` after terminal write,
synchronization and close. A `.partial` file is not a published capture, even if
its contents already include a completed terminal. The analyzer enforces this
distinction. The filename extension does not change the existing
`[NativeBaseline] {JSON}` record framing. Bounds are 64 KiB per physical line,
362 lines and 23,724,032 bytes per run, reserving a line for the terminal.
There is one bounded operation in flight; no per-run array grows in the app.

The directory retains the four newest files created by this sink, including
partials. Retention recognizes canonical UUID names plus an ownership attribute;
unrelated files and symbolic links are not eviction candidates. More than four
rapid reconnections can evict an older capture still finishing its cancellation;
its later publication must fail with `outputFailed`, never report success or
mix its contents into the newer file. This limit favors the most recent capture.
Raw filesystem errors and paths are not included in progress output.

The corrected sink passed the host suite, including a complete 242-line file,
failure injection for write/synchronize/close/publication, cancellation,
permissions, size/count limits and eviction of an older open partial without
contaminating the new capture. The analyzer passed 14 synthetic tests, including
console interleaving, `outputFailed` and an unpublished partial containing a
completed terminal. Signed Release builds with collection enabled and disabled
passed without compiler warnings or errors. Local evidence:
`/tmp/VisionRemotePS5-0109-baseline-sink-tests.log`,
`/tmp/VisionRemotePS5-0109-analysis-host.log`,
`/tmp/VisionRemotePS5-0109-file-release.log` and
`/tmp/VisionRemotePS5-0109-file-disabled.log`.

Corrected Release executable SHA-256:
`0d3a11a323dbf0b011a43f43bd879b9746648893a7ad62ffb418a8424cfe5b93`.
This artifact contains the current working-tree correction on top of `d9c044d`;
no new commit or push has been requested. The only source edit after compilation
was a comment explaining the eviction behavior.

The device-copy command was verified against the installed Xcode 27 CLI help.
After a new capture publishes its final file, retrieve only the metric directory
(set `BASELINE_DEVICE` to the paired device identifier):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun devicectl device copy from --device "$BASELINE_DEVICE" \
  --domain-type appDataContainer --domain-identifier com.visionremote.ps5 \
  --source Library/Caches/NativeBaseline \
  --destination /tmp/VisionRemotePS5-0109-captures --timeout 60
```

Analyze the final file for the capture ID reported by `[NativeBaselineStatus]`.
Do not rename a partial file to bypass publication checks. An explicit failed or
stopped terminal remains unsuccessful even in a published file.

The corrected artifact was installed successfully and launched with
`-NativeBaselineCapture`. Local evidence:
`/tmp/VisionRemotePS5-0109-file-install.log` and
`/tmp/VisionRemotePS5-0109-file-device-console.log`. At the initial post-launch
check, no checkpoint had yet arrived. App launch alone does not start the
measured duration; a connected Native PS5 session and warmup are required.
The second run and final retrieval below validate this transport on the device.

## Corrected physical run — 2026-09-08

Capture `1C228C5B-50E2-43A1-9C13-250F31710E8C` completed after
1,203,054,190 microseconds of measured host time: 20 minutes and 3.054190 seconds.
The published file contains checkpoints 1–236 and one completed terminal, with
no rejected records, missing sequences, duplicate sequences, measurement-data
issues or violations in the 14 arithmetic/configuration checks. The largest
checkpoint gap was 5.331797 seconds, below the 15-second limit. Its structural
status is `complete_capture_requires_review`; `baselineAccepted` remains null.

The private final file was copied from the app data container to
`/tmp/VisionRemotePS5-0109-captures/1C228C5B-50E2-43A1-9C13-250F31710E8C.ndjson`.
It has 1,598,870 bytes and SHA-256
`ea1cf030fd2249e6fc297dd7ecbe514ed125fb7b3877c83a8f1c2de924305e61`.
An older local `.partial` copy is only an intermediate snapshot and was not used
as the final result. Initial, approximately five-, ten- and fifteen-minute copies
also had contiguous records; only the final published file establishes completion.

Requested settings remained 1920×1080, 60 fps and 15,000 kbps throughout, with
Native guarded by the capture owner. These are requested settings, not delivered
rate measurements. The following are minimum/maximum p95 values across the 236
retained windows, not aggregate percentiles over the entire run:

| Measured interval | Minimum window p95 (ms) | Maximum window p95 (ms) |
| --- | ---: | ---: |
| Receive to decode | 4.286 | 8.733 |
| Receive to GPU completion | 14.432 | 17.738 |
| GPU execution | 0.463 | 1.981 |
| Input tick interval | 8.767 | 9.270 |
| Input tick work | 0.054 | 0.226 |
| Local input handoff | 0.005 | 0.014 |

Physical presentation remains unavailable under waived task 01.03. Decoder
rejections/errors and GPU failures were zero. Mailbox overwrites before
acquisition increased by 3,879; these remain separate from decoder/GPU events.
Native input errors, busy/inactive/slow calls and invalid metric samples were
zero; 15 instrumentation observations were missed, not necessarily commands.

There were 194 independently timestamped memory/audio observations. Process
footprint started at 125.157 MiB, peaked at 133.095 MiB and ended at 125.141 MiB.
The 45 observations in the final five-minute interval span 297.731 seconds and
range from 125.141 to 125.235 MiB (first-to-last change −0.078 MiB). This supports
a sampled plateau in this run, not a general leak verdict or a comparison against
the first run under unrecorded gameplay conditions. Allocation scopes overlap.
Thermal pressure stayed nominal (raw category 0), with no observed changes;
physical temperature was not measured.

Audio counter deltas were 402 underflow reads, 385,920 missing samples, 150
underflow episodes/recoveries, 54 catch-up events discarding 394,560 samples,
5,760 overflow-discarded samples and 15 contention reads requesting 14,400
samples. Oversized render requests were zero. Pre-PCM underflow stayed at 160
reads/153,600 samples and is an inclusive subset of the counters, not extra loss.
The user subsequently confirmed normal image, audio and controls. This completes
the qualitative functional check; these counters do not automatically establish
audible glitches. No percentile or counter here resolves the total
instrumentation-cost limitation in 01.08.

Final local analysis and independent audit:
`/tmp/VisionRemotePS5-0109-file-final-summary.json`,
`/tmp/VisionRemotePS5-0109-file-final-evidence.json` and
`/tmp/VisionRemotePS5-0109-file-final-independent-evidence.json`.
Retrieval evidence: `/tmp/VisionRemotePS5-0109-file-copy.log`.
The user confirmed normal image, audio and controls, then explicitly reported
external power, a local connection and windows at the expected size. Window size
is a qualitative user report; no numerical angular size or placement measurement
was supplied, so this does not establish exact geometry for later comparisons.
Scene changes were permitted; no fixed gameplay scene is claimed.
Task 01.09 is complete as an
observational Native reference: duration, retained-window percentiles, separate
drop counters, memory and normal functional behavior are documented. Window
geometry and temperature limitations remain explicit; this is not a controlled
comparison of effects or a measurement of physical presentation latency.

This acceptance is a human review of the capture plus the user's reported test
conditions. The analyzer's `baselineAccepted: null` remains unchanged because it
does not decide performance acceptance automatically. Tasks 01.08 and 01.11
retain their separate quantitative requirements.

After final retrieval and validation, the app was relaunched successfully without
diagnostic arguments. Normal launch evidence:
`/tmp/VisionRemotePS5-0109-file-restored-console.log`. The installed correction
remains available for an explicitly requested future capture.

## Reproducible local analysis

```sh
python3 scripts/analyze_native_baseline.py /tmp/VisionRemotePS5-0109-device-console.log \
  > /tmp/VisionRemotePS5-0109-summary.json
```

The analyzer ignores unrelated raw log lines and emits only allowed numeric
fields, opaque identities and fixed status labels. It validates capture/session
identity, sequence, monotonic bounds, gaps, terminal matching and measured
duration. `captureComplete` describes recording structure only;
`baselineAccepted` remains null, requiring review of conditions and functionality.
Memory/audio samples are deduplicated by their independent source identifiers;
stale data, counter regressions and missing coverage remain explicit.

Duration results are the minimum/maximum p95 across retained windows, never
global or averaged percentiles. Decoder rejections, mailbox overwrites and GPU
failures remain separate. Memory scopes overlap and must not be summed or
interpreted automatically as a leak verdict. Synthetic host tests include the
observed 1,024-byte console interleaving pattern and require rejection without
repair. Evidence: `/tmp/VisionRemotePS5-0109-analysis-host.log`.
