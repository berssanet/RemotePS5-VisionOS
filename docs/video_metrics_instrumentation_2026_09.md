# Video metrics instrumentation — 2026-09-07

Task 01.03 was **waived by the user on 2026-09-07** after the device probe.
Implementation and host/GPU tests remain available, but physical presentation
timestamps were not validated. Investigation is closed at the user’s request;
this waiver is not a passed test and no longer blocks further tasks.

## Live path

`StreamingService` owns the recorder and begins a new metrics session after
configuration validation. Explicit stop or the captured session's native quit
event closes recording. Session identity is captured when callbacks are set up;
an old quit cannot close a newer recorder session.

At `onVideoFramePointer` entry, the service captures monotonic host time and
creates `VideoFrameMetrics` with a session/frame identity. This marks receipt
of the complete encoded callback in Swift, not the first network packet or PS5
capture time. IDs count callbacks; decoder rejection can leave sequence gaps.
Missing timing never prevents video submission.

The decoder completion records receive-to-decode and submits the same context
with the decoded pixel buffer to `VideoFrameMailbox`. The mailbox's presentation
ID and existing timestamp remain intact; a new optional metrics field carries
the original context. The renderer snapshots it before scheduling GPU work.

| Interval | Endpoint source |
|---|---|
| `receiveToDecode` | Host clock at the successful decoded-buffer callback |
| `gpuExecution` | `MTLCommandBuffer.gpuStartTime` → `gpuEndTime`, successful command only |
| `receiveToGPUCompletion` | Captured receive time → `gpuEndTime`, successful command only |
| `receiveToPresentation` | Captured receive time → drawable `presentedTime`, exclusively from `addPresentedHandler` |

GPU completion uses the reported GPU endpoint rather than delayed CPU callback
arrival. It never synthesizes a presentation sample. The installed SDK's
`Metal.framework/Headers/MTLCommandBuffer.h` documents these GPU values as host
seconds, with zero when unavailable. `MTLDrawable.h` documents presentation host
time and zero for unpresented/skipped frames. Zero, nonfinite, reversed, or
stale-session intervals are rejected by the shared validation path.

Every presented handler can record, while Debug log lines remain rate-limited
using the existing two-second renderer reporting cadence. Correlated log lines
include a random session UUID, frame sequence, and local interval; UUIDs are
generated locally and are not console/account identifiers. No automatic export
or transmission is added. A repeated draw of the same decoded frame retains its
frame identity and may produce additional GPU/presentation samples.

The existing 12-slot decoder admission limit, latest-frame mailbox, and two-job
GPU capacity are preserved. No GPU wait is added. Metrics keep at most 256
intervals; older records are overwritten with a counter. This is a short rolling
diagnostic window, not a complete-session statistical report. Input/audio paths
and native archives are unchanged. Per-frame lock/callback overhead has not yet
been measured; stage 01 overhead checks still apply.

## Automated validation

Base revision `059a71c`, branch `docs/active-streaming-paths`, plus pending
01.01/01.02 and this task's changes. MacBook Pro M3 Pro, macOS 26.6.2 (`25G83`),
Xcode 27.0 (`27A5252f`). No test assertions were disabled.

- `test_streaming_metrics.sh`: exit 0. Existing timing/identity tests plus
  decode/GPU/presentation endpoint correlation, no presentation after GPU-only
  completion, rejection of invalid presentation times, mailbox propagation, and
  late decode/GPU/presentation callbacks after restart. The sandbox emitted
  CoreVideo/IOSurface environment diagnostics; buffer creation and assertions passed.
- `test_video_gpu.sh`: exit 0 outside sandbox. MetalFX/Enhanced pixel/reuse tests
  pass. Actual Metal timestamps produce two valid GPU intervals for each of six
  frame identities; no presentation sample is inferred from offscreen GPU work.
- `test_video_decoder.sh`: exit 0 outside sandbox. H.264/HEVC dependent-frame,
  reference-preservation, admission-overflow, stop, and parser regressions pass.
- Signed Debug visionOS build: exit 0, `BUILD SUCCEEDED`, no compiler warning/error
  diagnostics. No new Release build is claimed for this task.
- `git diff --check` passes.

Local evidence: `/tmp/VisionRemotePS5-0103-metrics.log`,
`/tmp/VisionRemotePS5-0103-gpu.log`, `/tmp/VisionRemotePS5-0103-decoder.log`,
`/tmp/VisionRemotePS5-0103-debug-build.log`. The reused 00.06 test log paths and
SDK27 Debug build path now refer to these runs; historical summaries remain.

## Device validation procedure and current status

The signed instrumented app was installed on the Vision Pro, `devicectl` exit 0.
A launch with `--console` was requested, directing output to
`/tmp/VisionRemotePS5-0103-device-console.log`. At preparation time no console
lines had arrived; launch/streaming and timestamp evidence remain unconfirmed.
Raw console output may contain existing app/native credentials and addresses;
review/redact before sharing. Only filtered metric lines belong in the report.

The user has been asked to connect in 1080p/Native, play for approximately one
minute, then close/reopen the PS5 session. Required evidence before completion:

1. Successful GPU and presentation log lines for matching session/frame IDs,
   with finite nonnegative presentation intervals from real drawable timestamps.
2. A different session UUID after reconnect, with no accepted old-session samples
   entering the new recorder. Automated stale-callback tests supplement this check.
3. User confirmation that video, audio, and controller behavior remain functional.

If the platform supplies only zero/unavailable presentation times, keep those
samples rejected and record the limitation; do not substitute GPU completion.
This is a functional instrumentation check, not p95 latency or overhead approval.

### Follow-up: Xcode console and rejection diagnostics

The `devicectl --console` connection failed; it did not capture the user's run.
The Xcode 27 beta console was subsequently read directly through the UI while
the Native PS5 session was running. Matching frame logs included GPU intervals
of 7.190 ms (frame 16856) and 13.715 ms (frame 18306), each accompanied by the
old generic presentation-rejection message. These are individual local samples,
not percentiles or end-to-end latency. No valid presentation endpoint or
reconnect identity was established by this observation.

The generic message did not identify whether the endpoint was zero, invalid,
before receipt, or rejected by session lifetime. The updated instrumentation
reports `unavailableTimestamp`, `invalidTimestamp`, `beforeReceipt`, or
`inactiveSession`, alongside the raw `presentedSeconds` and `receivedUs`.
Recording and classification use one validation path and atomic recorder
acceptance. The two-second log cadence is retained; invalid values never produce
synthetic intervals. A zero value alone cannot distinguish a skipped drawable
from a platform timing limitation.

Host tests cover each rejection reason, unchanged storage on rejection, valid
presentation recording, and stale-session callbacks. The diagnostics test run
passed (`/tmp/VisionRemotePS5-0103-diagnostics-tests.log`), and the signed Debug
build passed with no compiler warnings/errors (`/tmp/VisionRemotePS5-sdk27-build.log`).
The new build was launched from Xcode and the PS5 stream resumed with a new
metrics session identity. Direct console reads confirmed `unavailableTimestamp`
and `presentedSeconds=0.0` for frames 5, 123, 243, 364, 486 and later frames
through 2513 (about 42 seconds between the first and last receipt timestamps).
For example, frame 123 had receive-to-GPU=6.204 ms with receivedUs=43608146816;
frame 2513 had receive-to-GPU=6.589 ms with receivedUs=43648446406. Both presentation
endpoints were zero. These observations establish unavailable endpoints in this
run, not a reversed clock or recorder rejection. They do not prove every frame
was dropped, nor establish a general visionOS limitation. The user confirmed visible moving video and normal gameplay after this restart.
This rules out a completely absent/frozen stream in this run, but does not prove
that each sampled drawable reached the display. Audio and haptics were not
separately reconfirmed. At that checkpoint, 01.03 remained open because a valid physical
presentation timestamp was missing; the user subsequently waived the task.

The subsequent [standalone physical probe](../Diagnostics/PresentationProbe/device-result-2026-09-07.md)
reproduced zero timestamps in both the standard MTKView path and queued layer
acquisition, including a bounded 100-ms reread of one drawable. The probe links
no streaming code. The user confirmed changing colors in both modes; the report preserves
the exact observed checkpoints and limits. Do not treat callback arrival, GPU
completion, or predicted display time as a measured presentation endpoint.

The handler placement follows Apple's
[addPresentedHandler documentation](https://developer.apple.com/documentation/metal/mtldrawable/addpresentedhandler(_:));
the installed SDK header documents zero for an unpresented or skipped drawable.
Neither fact establishes the cause of the rejected samples on this device.
