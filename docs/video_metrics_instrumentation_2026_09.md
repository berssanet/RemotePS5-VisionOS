# Video metrics instrumentation — 2026-09-07

Task 01.03 implementation and host/GPU tests are ready. **Physical presentation
timestamp validation is pending**; do not mark the task complete from compilation,
installation, or the earlier functional smoke test.

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
