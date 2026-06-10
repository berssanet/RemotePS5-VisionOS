---
name: buffer-pool-recovery
description: Guardrail for the buffer-pool exhaustion path — markForRecovery() (IDR re-request) plus the 1Hz lastBufferExhaustionTime debounce. Load before editing SafeBufferPool.swift, VideoDecoder.swift, StreamingService.swift, or any chiaki video-callback failure handling. Severity medium — violating it causes visible smearing or log-spam stalls.
user-invocable: false
---

# Buffer-Pool Exhaustion Recovery + 1Hz Debounce

**Status:** enforced | **Severity:** medium — visual smearing
**Applies to:** `VisionRemotePS5/Streaming/SafeBufferPool.swift`, `VisionRemotePS5/Streaming/VideoDecoder.swift`, `VisionRemotePS5/Services/StreamingService.swift`
**Evidence:** `StreamingService.swift:341-355` (buffer acquire + debounced log), `TODO.md:46-51` (Phase 1.4 — Buffer Pool Recovery / Anti-Smearing)

## Reality

When the SPSC video buffer pool exhausts (sustained burst of frames or backed-up decoder), the chiaki video callback receives a frame that cannot be safely copied. Old behaviour (v10.0): silent drop → next frame partially decodes against stale VPS/SPS/PPS → visible smearing/corruption until the next IDR keyframe naturally arrives.

Fix (TODO.md §1.4, v10.1):

1. The `guard let safeBuffer = self.videoBufferPool.acquireAndCopy(...) else { ... }` failure branch in `StreamingService.swift:341-355` calls `markForRecovery()` on the decoder.
2. `markForRecovery()` clears VPS/SPS/PPS so the decoder discards every non-IDR NAL unit until an IDR arrives — actively requesting a clean keyframe.
3. The same failure branch implements **1Hz debouncing** via `lastBufferExhaustionTime`. Without the debounce, log spam from a sustained exhaust event takes the main thread offline.

```swift
// StreamingService.swift:341-355 — DO NOT TOUCH the structure
guard let safeBuffer = self.videoBufferPool.acquireAndCopy(from: pointer, count: size) else {
    let now = CACurrentMediaTime()
    if self.lastBufferExhaustionTime == nil || (now - self.lastBufferExhaustionTime!) > 1.0 {
        self.lastBufferExhaustionTime = now
        self.bufferExhaustionCount += 1
        print("[StreamingService] ⚠️ Buffer pool exhausted! Frames dropped: \(self.bufferExhaustionCount)")
        // markForRecovery() invoked here in current code
    }
    return
}
```

## Hallucination vector

An LLM will:
- Remove the debounce because "logs are useful, more is better".
- Replace `print(...)` with an unrate-limited `DebugLog.warning(...)` — same problem, different sink.
- Move the debounce window from 1.0s to 0.1s "for better visibility" — defeats the purpose.
- Delete `markForRecovery()` because the log line "already explains the failure".
- Add a `Task { ... }` to the failure branch to "do recovery asynchronously" — adds allocation inside the chiaki callback, the very thing being avoided.
- Replace `lastBufferExhaustionTime = now` with `lastBufferExhaustionTime = .now` (Date) — would also re-introduce wall-clock dependency (see the `monotonic-clock` skill).

## Hard rules

You MUST NEVER:

1. Remove the `lastBufferExhaustionTime`-based 1Hz debounce gate.
2. Increase the log frequency above 1 per second on this code path.
3. Remove `markForRecovery()` from the failure branch (or its equivalent VPS/SPS/PPS clearing call on `VideoDecoder`).
4. Allocate inside the failure branch. No `Task { }`, no `DispatchQueue.async { }`, no `[Type]()` literal.
5. Change `CACurrentMediaTime()` here to any other clock (covered by the `monotonic-clock` skill).
6. Change the threshold from `> 1.0` (seconds) to a different value without coordinating across logs.
7. Move `bufferExhaustionCount` accumulation out of the gated branch — it must increment ONCE per emitted log, not once per dropped frame.

You MUST:

- When adding a similar pattern elsewhere (e.g., audio buffer exhaustion), MIRROR this exact debounce structure: `lastXTime` Optional, `> 1.0` window, `CACurrentMediaTime()` clock.
- When adding new failure paths in the chiaki video callback, ensure they also invoke `markForRecovery()` if the failure leaves the decoder in a partial-state risk.

## Before/After

```swift
// BEFORE (LLM "improvement" — REJECT):
guard let safeBuffer = self.videoBufferPool.acquireAndCopy(from: pointer, count: size) else {
    self.bufferExhaustionCount += 1
    DebugLog.warning("StreamingService", "Buffer pool exhausted!")  // every frame, no debounce
    return
}

// AFTER (the only correct form):
guard let safeBuffer = self.videoBufferPool.acquireAndCopy(from: pointer, count: size) else {
    let now = CACurrentMediaTime()
    if self.lastBufferExhaustionTime == nil || (now - self.lastBufferExhaustionTime!) > 1.0 {
        self.lastBufferExhaustionTime = now
        self.bufferExhaustionCount += 1
        print("[StreamingService] ⚠️ Buffer pool exhausted! Frames dropped: \(self.bufferExhaustionCount)")
        self.videoDecoder?.markForRecovery()  // request next IDR
    }
    return
}
```
