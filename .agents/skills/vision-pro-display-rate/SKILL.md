---
skill: vision-pro-display-rate
status: enforced
severity: high
applies_to:
  - VisionRemotePS5/Services/StreamingService.swift
  - VisionRemotePS5/Streaming/FramePacer.swift
  - VisionRemotePS5/Streaming/AudioVideoSyncController.swift
  - any new Swift code computing display latency
evidence:
  - VisionRemotePS5/Services/StreamingService.swift:397-405
  - TODO.md:38-43    # Phase 1.3 — 90Hz Fix
---

# Skill: Vision Pro Display Refresh Rate (90Hz) Gating

## Reality

Apple Vision Pro displays at **90 Hz** (≈ 11.1 ms per frame). The `UIScreen.maximumFramesPerSecond` API is not reliably available on visionOS 1.0 / 2.0 in all build configurations, and previous code hardcoded `16ms` (assuming 60Hz), causing the audio chase loop to consistently trail video by ~5ms.

The current correct gating in `StreamingService.swift:397-405`:

```swift
// Vision Pro = 90Hz (~11.1ms), fallback to 60Hz (~16.7ms) if unknown
#if os(visionOS)
// visionOS runs at 90Hz
let displayRefreshRate: Double = 90.0
#else
let displayRefreshRate: Double = Double(UIScreen.main.maximumFramesPerSecond)
#endif
let estimatedDisplayMs = displayRefreshRate > 0 ? (1000.0 / displayRefreshRate) : 16.7
```

This value flows into `totalVideoLatencyMs` which the audio player chases via `updateDynamicTarget(measuredLatencyMs:)`.

## Hallucination vector

An LLM will:
- "Modernize" by removing `#if os(visionOS)` and unconditionally using `UIScreen.main.maximumFramesPerSecond` — but on visionOS this returns `0` or an unexpected value depending on SDK, breaking the fallback.
- "Simplify" by hardcoding `16.0` (matching the legacy comment) "because it's the same in practice" — re-introduces the original bug.
- Add a runtime query like `CADisplayLink.preferredFramesPerSecond` — not available on visionOS the same way as iOS.
- Move the constant into a shared `DisplayInfo` helper without preserving the `#if os(visionOS)` gate, dropping it under `#if !os(visionOS)`.

## Hard rules

You MUST NEVER:

1. Hardcode `16` or `16.0` or `16.7` as a display refresh constant outside the explicit fallback ternary at `StreamingService.swift:404`.
2. Remove the `#if os(visionOS)` / `#else` block at `StreamingService.swift:398-403`.
3. Replace the hardcoded `90.0` in the visionOS branch with a runtime query (`UIScreen`, `CADisplayLink`, `CAMetalLayer.maximumDrawableCount`). It MUST stay literal until visionOS exposes a stable API.
4. Use `CACurrentMediaTime() - CACurrentMediaTime()` style empirical measurement to derive the rate — drift in measurement window biases the result.
5. Apply this rate to non-display latency calculations (e.g., do not use it for input polling rate — that is fixed at 120Hz, see `120hz-input-loop` skill).

You MUST:

- When adding a new latency calculation that depends on display refresh, copy the exact `#if os(visionOS) ... #else ... #endif` block. Do NOT abstract it without first updating this skill file.
- When `UIScreen.main.maximumFramesPerSecond` returns `0` on a non-visionOS path, fall back to `16.7` (60Hz worst case), never to `0`.
- If Apple ships a visionOS API for runtime refresh-rate query (e.g., a future `XRDisplayInfo`), update this skill BEFORE migrating code — coordinate with the user.

## Before/After

```swift
// BEFORE (LLM "modernization" — REJECT):
let displayRefreshRate = Double(UIScreen.main.maximumFramesPerSecond)
let estimatedDisplayMs = 1000.0 / displayRefreshRate

// AFTER (the only correct form):
#if os(visionOS)
let displayRefreshRate: Double = 90.0
#else
let displayRefreshRate: Double = Double(UIScreen.main.maximumFramesPerSecond)
#endif
let estimatedDisplayMs = displayRefreshRate > 0 ? (1000.0 / displayRefreshRate) : 16.7
```
