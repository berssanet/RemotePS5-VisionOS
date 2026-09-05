---
skill: aces-filmic-tonemap
status: enforced
severity: medium
applies_to:
  - VisionRemotePS5/Streaming/ColorSpaceConverter.swift
  - VisionRemotePS5/Shaders/YUVToRGB.metal
evidence:
  - VisionRemotePS5/Streaming/ColorSpaceConverter.swift:113-149   # ACES + legacy Reinhard side by side
  - VisionRemotePS5/Streaming/ColorSpaceConverter.swift:211-216   # active call site
  - TODO.md:79-85   # Phase 3.1 — ACES Filmic
---

# Skill: ACES Filmic Tone Mapping (Reinhard Is Legacy)

## Reality

HDR content from the PS5 (especially fire, neon, particle effects) overwhelms the Reinhard tonemapper, producing washed-out grey/white highlights. ACES Filmic preserves saturation and the HDR "pop" the Vision Pro EDR display can render via `.bgra10_xr`.

Current state (`ColorSpaceConverter.swift`):

- `ACESFilm(float3)` at `:121-128` — the curve.
- `tonemapACES(float3, float)` at `:131-139` — the active wrapper.
- `tonemapLuminance(float3, float)` at `:142-...` — the legacy Reinhard implementation, **kept intentionally** as `// Legacy Reinhard (kept for fallback/comparison)`.
- Active call site at `:211-216` uses `tonemapACES(...)`.

## Hallucination vector

An LLM will:
- Delete `tonemapLuminance()` as "dead code" (it has no callers in production).
- Replace `tonemapACES()` calls with `tonemapLuminance()` because "Reinhard is the textbook tonemapper".
- "Improve" the ACES curve coefficients (`a=2.51, b=0.03, c=2.43, d=0.59, e=0.14`) with values from a different ACES variant — the current ones are tuned for sRGB output and the EDR pixel format used.
- Convert the `.metal` shader function to use `simd_clamp` from MSL 2.4+ stdlib — fine in principle but reduces portability if the Metal version is bumped down.

## Hard rules

You MUST NEVER:

1. Delete `tonemapLuminance()` or its surrounding `// Legacy Reinhard (kept for fallback/comparison)` comment.
2. Change the active call site to invoke `tonemapLuminance()` instead of `tonemapACES()`.
3. Modify the ACES coefficients `a=2.51, b=0.03, c=2.43, d=0.59, e=0.14` without explicit user direction. They are the standard Hill ACES Fitted curve.
4. Move the tonemap functions out of `ColorSpaceConverter.swift`'s embedded shader source string into a separate `.metal` file without coordinating the build setting change with the user — the project currently uses inline-string shader compilation here.
5. Remove the EDR clamp at the end of the active shader call site (`:216`-area). It guards values > 1.0 against out-of-range writes to the texture.
6. Re-introduce sRGB gamma encoding in the tonemapped output. The pipeline writes linear values to `.bgra10_xr` (Extended Range); RealityKit + the EDR display do the gamma step.

You MUST:

- For any new tonemap experiment, ADD a new function (e.g., `tonemapHable()`) and gate the call via a feature flag — do NOT modify `tonemapACES()` in place.
- When adjusting exposure handling, modify the `exposure` parameter passed to `tonemapACES(col, exposure)`, not the curve constants inside `ACESFilm()`.

## Before/After

```c
// BEFORE (LLM "cleanup" — REJECT):
float3 tonemapACES(float3 col, float exposure) {
    col = col * exposure;
    return ACESFilm(col);
}
// [tonemapLuminance() deleted as unused]

// AFTER (the only correct form):
float3 tonemapACES(float3 col, float exposure) {
    col = col * exposure;
    float3 mapped = ACESFilm(col);
    return mapped;
}

// Legacy Reinhard (kept for fallback/comparison)
float3 tonemapLuminance(float3 col, float maxBrightness) {
    float luma = 0.2627 * col.r + 0.6780 * col.g + 0.0593 * col.b;
    if (luma < 0.0001) return col;
    float newLuma = luma / (1.0 + luma / maxBrightness);
    // Reconstruct color with compressed luminance...
    return col;
}
```
