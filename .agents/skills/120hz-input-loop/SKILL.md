---
skill: 120hz-input-loop
status: enforced
severity: medium
applies_to:
  - VisionRemotePS5/Controllers/HighFrequencyInputController.swift
  - VisionRemotePS5/Controllers/GameControllerManager.swift
  - VisionRemotePS5/Services/StreamingService.swift   # startStreamingV2() wiring point
  - VisionRemotePS5/Services/VirtualSteeringWheelService.swift
evidence:
  - TODO.md:21-27   # Phase 1.1 — Decouple Input Polling from Video Loop
---

# Skill: 120Hz Input Loop Wiring

## Reality

PS5 Remote Play accepts controller updates at high frequency. The project runs a **dedicated 120Hz input thread** (`HighFrequencyInputController.swift`) at `QoS: .userInteractive`, `threadPriority: 1.0`, **off-MainActor**. The thread fires an `onInputReady` callback at 120Hz; the callback funnels into `ChiakiFullSession.setControllerState()`.

Critical wiring (TODO.md §1.1, fixed in v10.1):

- `GameControllerManager` runs the timer at 120Hz.
- `StreamingService.startStreamingV2()` connects `onInputReady` → `ChiakiFullSession.setControllerState(...)` with `weak self` capture.
- The legacy per-event methods (`pressButton(...)`, etc.) are **kept** for the on-screen virtual UI but the 120Hz timer is what actually pushes state to the PS5 in real-time.

## Hallucination vector

An LLM will:
- Migrate `HighFrequencyInputController` to `@MainActor` "for safety" — destroys deterministic 120Hz pacing.
- Replace the dedicated `Thread` with `DispatchQueue` or `Task.detached(priority: .userInitiated)` — neither offers `.userInteractive` QoS + 120Hz wakeups reliably.
- Remove the legacy `pressButton(...)` etc. methods as "duplicated by the 120Hz path" — those are still used by the on-screen overlay UI.
- Disconnect the `onInputReady` callback in a refactor of `startStreamingV2()` — the original v10.0 bug.
- Capture `self` strongly inside the closure assigned to `onInputReady` — leaks the streaming session for the lifetime of the input controller.
- Tie the input rate to the display refresh rate (e.g., reuse the `vision-pro-display-rate` 90Hz constant) — these are independent. Input is fixed 120Hz regardless of display.

## Hard rules

You MUST NEVER:

1. Add `@MainActor` to `HighFrequencyInputController` or any of its members.
2. Replace the dedicated `Thread` (with `QoS: .userInteractive`, `threadPriority: 1.0`) with any `DispatchQueue` or `Task` construct.
3. Lower the input timer interval below `1.0/120.0` seconds (i.e., do not run faster than 120Hz — PS5 ignores excess updates and you waste CPU).
4. Disconnect or remove the `onInputReady = { [weak self] in ... self.session.setControllerState(...) }` wiring in `StreamingService.startStreamingV2()`.
5. Capture `self` strongly inside any closure assigned to `onInputReady`, the timer block, or any haptic callback. Always `[weak self]`.
6. Delete the legacy `pressButton(...)`, `releaseButton(...)`, etc. methods on `GameControllerManager`. They are called by the on-screen virtual controller overlay.
7. Re-couple the input cadence to the display refresh rate, video callback, or audio render loop.
8. Print to stdout from inside the 120Hz timer block (use `DebugLog` with rate-limit, like the buffer-exhaustion debouncer pattern from `skills/buffer-pool-recovery`).

You MUST:

- Preserve the wiring contract: `GameControllerManager.onInputReady` ↔ `ChiakiFullSession.setControllerState(...)`.
- All shared mutable state read by the 120Hz block must be either `os_unfair_lock`-guarded or `@MainActor`-isolated with explicit `MainActor.run` boundary (note: do not introduce the latter; existing code uses lock-guarded snapshots — match it).
- For new input sources (e.g., a third-party wheel), funnel through the same 120Hz timer; do NOT spin up a second high-rate thread.

## Before/After

```swift
// BEFORE (LLM "safety" refactor — REJECT):
@MainActor
final class HighFrequencyInputController {
    func start() {
        Task { @MainActor in
            while !Task.isCancelled {
                onInputReady?()
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
        }
    }
}
// And in StreamingService:
// onInputReady wiring removed during "consolidation"

// AFTER (the only correct form):
final class HighFrequencyInputController {
    private var inputThread: Thread?
    var onInputReady: (() -> Void)?

    func start() {
        let thread = Thread { [weak self] in
            Thread.current.qualityOfService = .userInteractive
            Thread.current.threadPriority = 1.0
            while !Thread.current.isCancelled {
                self?.onInputReady?()
                Thread.sleep(forTimeInterval: 1.0 / 120.0)
            }
        }
        inputThread = thread
        thread.start()
    }
}

// In StreamingService.startStreamingV2() — DO NOT REMOVE:
gameControllerManager.onInputReady = { [weak self] in
    guard let self, let session = self.chiakiSession else { return }
    session.setControllerState(self.gameControllerManager.snapshotState())
}
```
