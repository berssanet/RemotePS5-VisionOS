---
skill: direct-stereo-audio
status: enforced
severity: high
applies_to:
  - VisionRemotePS5/Streaming/LowLatencyAudioPlayer.swift
evidence:
  - VisionRemotePS5/Streaming/LowLatencyAudioPlayer.swift:50-57    # the flag and rationale
  - VisionRemotePS5/Streaming/LowLatencyAudioPlayer.swift:325-339  # Direct Stereo branch
  - VisionRemotePS5/Streaming/LowLatencyAudioPlayer.swift:341-350  # HRTF + fallback branch
  - TODO.md:58-72   # Phase 2.1/2.2 — Direct Stereo / N/A spatialization
---

# Skill: Direct Stereo Audio (HRTF Bypass) Is The Default

## Reality

The PS5's Tempest 3D Audio Engine produces binaural audio internally. Re-applying HRTF on the visionOS side via `AVAudioEnvironmentNode` causes double-spatialization, which sounds like:
- Metallic ringing on transients.
- Phantom positional shift outside the intended sound field.
- 5–10 dB peak attenuation on stereo-panned effects.

Fix (`LowLatencyAudioPlayer.swift:50-57`):

```swift
// MARK: - v10.1 Direct Stereo Mode (Bypass HRTF)
/// v10.1: Enable spatial audio (HRTF processing)
/// Set to FALSE for "Direct Stereo" when PS5 Tempest Engine already provides binaural audio.
/// This prevents double-processing that causes metallic/echo artifacts.
/// Default: false for optimal PS5 Remote Play audio quality.
var spatialAudioEnabled: Bool = false
```

The Direct Stereo branch (`LowLatencyAudioPlayer.swift:325-339`) connects L/R sources directly to `mainMixerNode` with `pan = -1.0` / `pan = +1.0`. The HRTF branch is preserved for users who explicitly opt in.

## Hallucination vector

An LLM will:
- "Restore spatial audio" by flipping the default to `true` because "this is visionOS, spatial audio is the whole point".
- Remove the Direct Stereo branch entirely as "dead code".
- Remove the fallback branch at `:344-349` because the early return at `:338` "makes it unreachable" (it isn't — it's reachable when `spatialAudioEnabled = true` AND the env node fails to allocate).
- Replace `engine.connect(leftSource, to: engine.mainMixerNode, format: format)` with a `PHASE`-engine spatializer because PHASE is "more modern".

## Hard rules

You MUST NEVER:

1. Change the default value of `spatialAudioEnabled` from `false` to `true` in `LowLatencyAudioPlayer.swift:57`.
2. Delete the Direct Stereo branch (the `if !spatialAudioEnabled { ... return }` block at `:327-339`).
3. Delete the fallback path at `:344-349` (the `guard let envNode = environmentNode else { ... }`).
4. Replace `AVAudioEngine` with `PHASEEngine`. The lock-free SPSC ring buffer (`AudioRingBuffer.swift`) feeds `AVAudioSourceNode` via render block — PHASE has different threading guarantees.
5. Add a `PHASE` import to this file or to `AudioDecoder.swift`.
6. Reorder the connection sequence: it must be `leftSource → mixer`, `rightSource → mixer`, then pan assignments. The pan must be set AFTER the connect (otherwise format negotiation overwrites it on some iOS versions; same applies on visionOS).
7. Remove the `DebugLog.info("LowLatencyAudio", "🎧 Direct Stereo enabled (HRTF bypassed, Tempest preserved)")` log line — it is the user-facing confirmation of mode in the console.

You MUST:

- If the user explicitly asks to enable spatial audio, change the call site that sets `spatialAudioEnabled` (e.g., a `SettingsView` toggle), NOT the default in `LowLatencyAudioPlayer.swift`.
- If you add a new audio output mode, add it as a new value of an enum (e.g., `enum AudioOutputMode { case directStereo, hrtf, custom }`) rather than another `Bool` flag.
- Preserve the comment block at `:50-56` verbatim as the rationale anchor.

## Before/After

```swift
// BEFORE (LLM "modernization" — REJECT):
var spatialAudioEnabled: Bool = true  // Spatial audio is the visionOS default
// ... later ...
private func setupStereoEmitterArray() {
    // [Direct Stereo branch removed as "unused"]
    environmentNode = AVAudioEnvironmentNode()
    // ...
}

// AFTER (the only correct form):
/// Default: false for optimal PS5 Remote Play audio quality.
var spatialAudioEnabled: Bool = false
// ... later ...
if !spatialAudioEnabled {
    engine.connect(leftSource, to: engine.mainMixerNode, format: format)
    engine.connect(rightSource, to: engine.mainMixerNode, format: format)
    leftSource.pan = -1.0
    rightSource.pan = +1.0
    DebugLog.info("LowLatencyAudio", "🎧 Direct Stereo enabled (HRTF bypassed, Tempest preserved)")
    return
}
// HRTF path with fallback follows...
```
