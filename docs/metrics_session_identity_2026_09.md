# Metrics session/frame identity — 2026-09-07

Task 01.02 adds opaque identities and an atomic recorder to
[StreamingMetrics.swift](../VisionRemotePS5/Services/StreamingMetrics.swift).
Late callbacks cannot append an old session's measurements to a new one.
This 01.02 infrastructure was tested independently. Subsequent
[01.03 video integration](video_metrics_instrumentation_2026_09.md) adds live
video callbacks; its physical timestamp validation remains pending.

## Identity and lifecycle

- `MetricSessionID` holds a UUID created by `beginSession`, unrelated to console,
  account, or network identifiers. A new start gets a new identity even on the
  same recorder. IDs are not caller-constructible outside the implementation file.
- `MetricFrameID` combines that identity and an increasing UInt64 sequence.
  `nextFrame(in:)` assigns numbers under a lock and only for the active session.
  Exhaustion returns nil instead of wrapping. Sequence 1 in a new session is
  distinct from sequence 1 in its predecessor.
- `IdentifiedMetricInterval` carries session, optional frame, and the validated
  interval. Video/GPU metrics require a frame; input metrics require session-only
  identity so input timing does not depend on a video frame.
- `endSession(oldID)` cannot end a newer session. A matching end disables writes
  and frame creation while retaining the final snapshot for inspection.

Callbacks must capture their session/frame when work is scheduled. Looking up
the current identity at completion would incorrectly relabel old work; future
integration must not do that. For example:

```swift
let recorder = StreamingMetricsRecorder()
let session = recorder.beginSession()
let frame = recorder.nextFrame(in: session)
// Capture session and frame in the asynchronous operation.
// On completion, pass the captured values to record(_:session:frame:).
```

`record` checks active session, frame/session agreement, valid issued sequence,
and metric scope, then writes under the **same** `OSAllocatedUnfairLock`.
There is no check-then-append gap in which a restart can interleave. Out-of-order
completions within the same session are allowed and retain their own frame IDs.
Rejected samples return false without changing retained data.

## Bounded storage

Each recorder reserves a fixed ring (default 256 samples, positive capacity
required). At capacity, new samples replace the oldest and a saturating counter
records overwrites. Starting a new session clears the ring/counter and replaces
identity. `snapshot` copies retained samples in recording order and includes
session, active state, and overwrite count. A copied snapshot is independent
of subsequent starts. Snapshot copying is an explicit inspection operation,
not intended for an input tick.

There are no external closures, I/O, GPU waits, or per-frame UUID allocations
inside record/frame assignment. This does not establish measured lock overhead;
runtime collection limits and overhead still need later validation. The ring is
temporary bounded retention, not a complete export or aggregation system.

## Tests and evidence

Environment: M3 Pro MacBook Pro, macOS 26.6.2 (`25G83`), Xcode 27.0 (`27A5252f`).
Base revision `059a71c`, branch `docs/active-streaming-paths`, with the pending
01.01 implementation and stage 00 reports preserved.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
bash scripts/test_streaming_metrics.sh
```

Exit 0. Existing timing tests remain passing. Added checks:

- Hold a callback with semaphores, restart, release it, and reject its sample.
- Reject the old callback's frame allocation and prevent its delayed stop from
  stopping the new session.
- Reuse a frame sequence across sessions without identity collision; reject a
  frame from the wrong session or a session from another recorder.
- Require frame identity for video and session-only identity for input.
- Accept same-session out-of-order completion, bound retention, count overwrites,
  and retain stopped-session reports while rejecting new writes.
- Race four old-session writers (500 attempts each) against restart and 64
  current-session concurrent frame allocations/records. Final snapshot contains
  only the current session and 64 unique frame identities. No ordering or timing
  requirement is imposed on the competing writers.

Log: `/tmp/VisionRemotePS5-0102-metrics.log`. These tests exercise concurrency but
do not constitute an exhaustive interleaving proof or ThreadSanitizer run.

Release build with SDK `xros27.0` also passed, exit 0, no warning/error diagnostics.
Log: `/tmp/VisionRemotePS5-0102-release.log`; unsigned artifact replaces the earlier
temporary `/tmp/VisionRemotePS5-immersive-build` output. `git diff --check` passed.
No app installation, live metric collection, or device performance claim.

Next task: 01.03, propagate captured identity through reception/decode/mailbox/
presentation callbacks and distinguish GPU completion from actual presentation.
