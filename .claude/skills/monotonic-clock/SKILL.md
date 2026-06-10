---
name: monotonic-clock
description: Guardrail requiring CACurrentMediaTime() (monotonic) for all streaming-pipeline time deltas — never CFAbsoluteTimeGetCurrent(), Date(), DispatchTime, or ContinuousClock. Load before editing StreamingService.swift, anything under Streaming/, or writing any new code that measures latency or time deltas in the pipeline. Severity high — wall-clock time breaks latency math under NTP drift.
user-invocable: false
---

# Monotonic Clock — `CACurrentMediaTime()` ONLY

**Status:** enforced | **Severity:** high — NTP drift bug
**Applies to:** `VisionRemotePS5/Services/StreamingService.swift`, `VisionRemotePS5/Streaming/VideoDecoder.swift`, `VisionRemotePS5/Streaming/UpscalingPipeline.swift`, `VisionRemotePS5/Streaming/AudioVideoSyncController.swift`, `VisionRemotePS5/Streaming/LowLatencyAudioPlayer.swift`, any new Swift code computing time deltas in the streaming pipeline
**Evidence:** `StreamingService.swift:12` (`import QuartzCore  // v10.1: For CACurrentMediaTime monotonic clock`), `StreamingService.swift:337,347,390` (`CACurrentMediaTime()` usage), `TODO.md:30-35` (Phase 1.2 — Monotonic Clock fix)

## Reality

The streaming pipeline measures latencies in the millisecond range and uses time deltas for:
- Video decode latency (`decodeCompleteTime - frameReceiveTime`).
- Buffer-exhaustion debouncing (`now - lastBufferExhaustionTime`).
- A/V drift correction window thresholds (20 ms, 50 ms, 100 ms).
- Audio dynamic-target chase loop.

`CFAbsoluteTimeGetCurrent()` returns wall-clock time and is subject to NTP step adjustments. A single 50 ms jump (typical NTP correction) corrupts every in-flight latency calculation in the pipeline, triggering false buffer-overflow emergency drops, audio resync seeks, and visible A/V desync.

The fix (TODO.md §1.2): replace ALL `CFAbsoluteTimeGetCurrent()` with `CACurrentMediaTime()`, which wraps `mach_absolute_time()` — guaranteed monotonic, immune to NTP.

```swift
// StreamingService.swift:12 — required import
import QuartzCore  // v10.1: For CACurrentMediaTime monotonic clock
```

## Hallucination vector

An LLM will:
- Re-introduce `CFAbsoluteTimeGetCurrent()` because Foundation imports it implicitly and it "looks more standard".
- Use `Date()` arithmetic (`Date().timeIntervalSince(start)`) — also wall-clock, also broken.
- Use `DispatchTime.now()` arithmetic — monotonic but uses `UInt64` nanoseconds with overflow risk in `Int` casts and inconsistent units.
- Use `ContinuousClock()` (Swift 5.7+) — monotonic but returns `Duration`, not `CFTimeInterval`, breaking the existing codebase's interop with chiaki C timestamps.

## Hard rules

You MUST NEVER:

1. Call `CFAbsoluteTimeGetCurrent()` anywhere in `VisionRemotePS5/Services/Streaming*.swift`, `VisionRemotePS5/Streaming/**`, `VisionRemotePS5/Controllers/HighFrequencyInputController.swift`, or `VisionRemotePS5/Services/VirtualSteeringWheelService.swift`.
2. Compute time deltas from `Date()` instances in those files.
3. Use `DispatchTime.now()` to compute streaming-pipeline latencies (acceptable only for `DispatchQueue` deadline scheduling, not for measurement).
4. Replace `CACurrentMediaTime()` with `ContinuousClock()` or `SuspendingClock()` in existing code.
5. Remove `import QuartzCore` from any file that uses `CACurrentMediaTime()` — without the import, it does not resolve.

You MUST:

- Use `CACurrentMediaTime()` for ALL time deltas in the streaming pipeline.
- Type all such deltas as `CFTimeInterval` (alias for `Double`, in seconds), matching existing code.
- When converting to milliseconds for logging or downstream APIs, multiply by `1000` inline.
- When adding a new file that touches streaming timestamps, `import QuartzCore` at the top with the comment `// CACurrentMediaTime monotonic clock`.

## Verification

If you suspect a regression, grep:

```
grep -rn "CFAbsoluteTimeGetCurrent\|Date()\.timeInterval" VisionRemotePS5/Streaming VisionRemotePS5/Services/Streaming
```

The expected output is **zero matches**. Any hit is a regression to the v10.0 NTP-drift bug.

## Before/After

```swift
// BEFORE (LLM regression — REJECT):
let frameReceiveTime = CFAbsoluteTimeGetCurrent()
// ... later ...
let decodeLatencyMs = (CFAbsoluteTimeGetCurrent() - frameReceiveTime) * 1000

// AFTER (the only correct form):
import QuartzCore  // CACurrentMediaTime monotonic clock
let frameReceiveTime = CACurrentMediaTime()
// ... later ...
let decodeLatencyMs = (CACurrentMediaTime() - frameReceiveTime) * 1000
```
