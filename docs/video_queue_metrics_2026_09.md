# Video queues, resource reuse and memory — 2026-09-07

Task 01.05 instruments the existing bounded video path. Host and GPU validation
is complete and the physical slow-consumer test finished. The user confirmed
normal operation and recovery on this build; task01.05 is complete. Task 01.04 is complete
following the user's confirmation of buttons and analog sticks. Task 01.03 was
waived by the user; none of these measurements supplies a presentation endpoint.

## Counter meanings

| Observation | Meaning and scope |
|---|---|
| Decoder `rejectedNew` | New encoded callback rejected because all 12 CPU admission slots are occupied; no input copy is queued. |
| Decoder slots / payload bytes | Current and peak admitted CPU submissions, including input copy and queued work, until `decodeAccessUnit` returns. These do not include asynchronous VideoToolbox output or its internal pool. |
| Decoder invalid / stopped / cancelled | Invalid input, submission while stopped, and work cancelled before decode are separate from capacity rejection. |
| Mailbox `overwrittenBeforeAcquire` | A decoded frame is replaced before any renderer acquires it. |
| Mailbox `acquired` | Distinct frames handed to a renderer, including attempts that subsequently fail. Repeated redraws do not increase this count. |
| Mailbox occupancy | Zero or one retained decoded buffer, including the last acquired frame kept for redraw. This is not just pending work. |
| Mailbox cleared / disabled / stale | Release before acquisition, disabled publication and publication from an inactive/old session are separate events. |
| Renderer busy / idle / throttled | Draw attempts skipped for capacity, no new frame/settings, or the explicit Debug stress test. These are not counts of distinct dropped video frames. |
| Renderer drawable unavailable / encode failed | Failures after acquisition, before submitting GPU work. |
| Renderer submitted / completed / GPU failed | Actual render command submissions and terminal GPU outcomes; completion is not presentation. Current/peak in-flight is session scoped. |
| Renderer reused outputs | Successful upscaler encodes returning the same output texture identity as the previous encode for that upscaler on this renderer, including reuse across a stream restart. Native CVMetalTexture wrappers are excluded. |

Mailbox acquisition captures and marks the same frame under one lock. A read-only
snapshot does not consume it. Session identity accompanies the buffer even when
its timing is unavailable; missing timing never discards otherwise valid video.
Start resets the mailbox's counters while preserving display settings and monotonic
render IDs. A delayed output/end from an old session cannot replace/clear the new
session's buffer.

Renderer terminal callbacks capture both session identity and whether the
submission was counted. Only counted commands drain their session's gauge,
including after end; callbacks from a replaced session are ignored. GPU capacity
is released independently of measurement acceptance. Native connected/quit tasks
also check their captured session before changing actor-owned state or input.

## Memory and texture scopes

The two upscalers expose persistent texture counts and the sum of those textures'
`MTLResource.allocatedSize`. MetalFX owns one output; Enhanced owns intermediate
and output textures. The renderer reports all currently retained upscalers, so
switching modes can legitimately keep both allocations. Renderer ID identifies
which instance last reported those values. This is not an inventory of all
renderer instances or private framework resources.

Five-second Debug reports collect:

- Process `task_vm_info.phys_footprint`, or `unavailable` if the query fails.
- The Metal device's `currentAllocatedSize` for process allocations on that device.
- The latest renderer's owned upscaler texture count and bytes.
- Decoder admitted payload bytes and logical `CVPixelBufferGetDataSize` retained
  by the mailbox. The latter may also be retained by decoder/renderer/snapshots.

These scopes overlap and must not be added together. They do not expose the
VideoToolbox pool size, deduplicate IOSurfaces or claim that a new texture wrapper
means a new physical allocation. SDK signatures were checked in the installed
Xcode 27 xros SDK (`MTLResource.h`, `MTLDevice.h`, `mach/task_info.h`).

`VideoQueueMetrics` retains at most 64 chronological memory samples per session,
with a separate overwritten-sample count. Logs report the retained footprint
window's first-to-last delta and peak; warm-up allocations and mode changes are
expected explanations to examine before attributing growth to a leak. Repeated
samples through overload/recovery expose growth for review. A short stable run
cannot prove absence of leaks; sustained baseline and overhead remain 01.09/01.08.
Snapshots/formatting/process queries run every five seconds outside video/input
callbacks. Per-frame observations use fixed counters. The finite stress helper
and periodic reports are Debug only; no stress starts without the launch flag.

## Opt-in physical procedure

Launch the Debug app with `-VideoQueueMetricsStress`, connect to the PS5, and
play through 45 seconds after the renderer first receives a frame:

1. 15 seconds baseline at normal display cadence.
2. 15 seconds admitting at most 20 rendering attempts per second. The PS5 producer
   retains its existing 1080p/60-fps request; latest-frame replacement should rise.
3. 15 seconds recovery at normal cadence, then `phase=complete` automatically.

The helper skips draw admission before acquiring the mailbox frame. It adds no
sleep, queue, source-frame generation, codec change or input scheduling change.
Use monotonic phase times to select reports; counters are cumulative, so compare
deltas rather than interpreting totals as phase values. Mode changes should be
recorded if made. Stop or reconnect closes/replaces the reporting session.

## Validation

MacBook Pro M3 Pro, Xcode 27.0 (`27A5252f`):

- `scripts/test_video_decoder.sh`: H.264/HEVC regressions passed. Blocking the CPU
  queue accepts exactly 12 submissions, rejects the 13th without increasing
  retained bytes, then drains slots/bytes to zero. Stop/cancel and invalid input
  have separate tested counters.
- `scripts/test_video_mailbox.sh`: passed. A 100-frame producer before one acquire
  yields 99 overwritten frames, occupancy one and stable logical bytes. Read-only
  snapshots, repeated acquire, clearing, disabled/stale publication and timestamp
  absence are covered. Four producers/two consumers exercise 10,000 publications
  with exact accounting conservation.
- `scripts/test_video_gpu.sh`: passed with existing pixel/border/timing checks.
  Three encodes retain identical output identity and stable ownership: MetalFX
  one texture / 33,423,360 bytes, Enhanced two / 66,846,720 bytes on this host.
  Physical-device allocation sizes may differ.
- `scripts/test_video_queue_metrics.sh`: passed. Bounded chronological memory,
  unavailable samples, event separation, concurrent recording, restart isolation,
  end-session drain and fake-clock stress boundaries (0/15/30/45 seconds).
- Streaming metrics host regressions passed with the mailbox change.
- Final signed Debug and unsigned Release builds passed without compiler warning
  or error diagnostics; project plist and `git diff --check` passed.
- Signed Debug installed and launched on the paired Vision Pro with the explicit
  stress argument. The finite physical test completed as recorded below.

Local evidence files use `/tmp/VisionRemotePS5-0105-` prefixes: `decoder.log`,
`gpu.log`, `queue-metrics.log`; mailbox/clock tests also passed from their scripts.
Raw device logs can contain existing native session data. Only filtered metric
fields belong in this report; no automatic report upload is implemented.


## Physical slow-consumer result

Apple Vision Pro `RealityDevice14,1`, visionOS 27.0 (`24M5361a`), native rendering,
PS5 stream requesting 1920×1080 at 60 fps. Same renderer instance throughout the
measured interval. This short check does not control game/network/power conditions
and is not the sustained baseline.

Phase host timestamps (microseconds) were baseline `48328803657`, slow consumer
`48343814470`, recovery `48358814162`, complete `48373813745`. Each phase lasted
approximately 15 seconds. The helper reached complete and stopped throttling.

The table uses differences between consecutive cumulative queue reports whose
adjacent memory sample times are **both inside the same phase**. These approximate
five-second observation intervals are not exact frame timestamps or whole-phase
averages. Intervals crossing boundaries are excluded from this table only.

| Phase | Complete observation intervals | Decoded publications/s | Render submissions/s | Replaced before acquire, per interval |
|---|---:|---|---|---|
| Baseline | 2 | 59.74; 60.02 | 58.74; 58.23 | 5; 9 |
| Slow consumer, <=20 Hz | 2 | 59.79; 60.04 | 18.00; 17.93 | 209; 216 |
| Recovery | 1 | 59.67 | 56.89 | 14 |

The first report after completion recorded 2,721 decoded publications, 682
replaced before acquisition and 2,039 acquired/submitted/completed frames.
Renderer busy, unavailable drawable, encode errors and GPU failures were zero;
1,080 draw attempts were deliberately throttled. These attempts are not the same
as the 682 distinct overwritten frames. GPU in-flight peak was one (limit two),
CPU admission peak three (limit twelve), admitted payload peak 37,844 bytes, and
new-frame capacity rejection was zero. Physical decoder saturation was not needed:
the host test separately validates rejection at all twelve occupied slots.

Mailbox occupancy stayed one, with 8,294,464 logical pixel-buffer bytes. All nine
memory observations through the first completion report stayed within
121,914,208–122,831,712 process footprint bytes, ending 917,504 bytes below the
first observation. Device allocation samples alternated between 55,836,672 and
64,143,360 bytes and returned to 55,836,672 after completion. These observations
show bounded sampled values in this window; they do not prove no allocation spikes
between samples or no long-term leak. Native mode correctly reports zero owned
upscaler textures/reuse; the existing GPU harness validates both upscalers above.

The user confirmed that everything is functioning normally on this build after
the test, completing the visual recovery and controller regression check.
Evidence: `/tmp/VisionRemotePS5-0105-device-console.log`, final Debug build at
`/tmp/VisionRemotePS5-sdk27-build.log`, Release at
`/tmp/VisionRemotePS5-0105-release.log`. Only filtered, non-credential metric
fields were used here.
