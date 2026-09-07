# Feedback Assistant draft

Status: prepared locally; not submitted.

## Title

visionOS 27: MTLDrawable.presentedTime stays zero in presented handlers while a standalone MTKView visibly animates

## Summary

On a physical Apple Vision Pro running visionOS 27.0, a standalone Metal app
visibly changes its clear color, but every presentation callback counted at the
reported checkpoints returns `presentedTime == 0.0`. This occurs with both the
standard `MTKView.currentRenderPassDescriptor`/`currentDrawable` delegate path
and a comparison path that obtains `CAMetalLayer.nextDrawable()` on a serial
queue. GPU commands complete successfully and provide nonzero GPU timestamps.

The issue prevents collecting a measured presentation endpoint through
`MTLDrawable.presentedTime`. Please investigate whether this is a runtime issue
or an expected limitation of windowed Metal content on this platform, and
clarify the supported way to obtain an actual presentation timestamp.

## Environment

- Device: Apple Vision Pro, model identifier `RealityDevice14,1`.
- Runtime: visionOS 27.0, build `24M5361a`.
- Toolchain: Xcode 27.0, build `27A5252f`, visionOS 27 SDK.
- App: standalone signed Debug visionOS app, minimum deployment target 2.0.
- Observation date: September 7, 2026.

The reproduction uses SwiftUI, MetalKit and system frameworks. It has no
streaming, networking, decoder, application metrics or third-party library
dependency. The separate streaming app's Xcode session had ended before the
probe was launched.

## Steps to reproduce

1. Open the supplied `PresentationProbe.xcodeproj`, select a signing team and a
   physical Vision Pro, and run the `PresentationProbe` scheme.
2. Wear the headset and keep the probe's window visible. Observe the gradually
   changing color and the timestamp counters. Capture `[PresentationProbe]`
   console output.
3. The initial mode is **MTKView currentDrawable**. It acquires the view's
   current render pass and drawable and encodes/presents within `draw(in:)`.
4. Twenty seconds after view startup, the app switches to **CAMetalLayer queued
   nextDrawable**. This mode acquires a drawable and encodes/presents on a
   serial queue. Continue observing for at least another 20 seconds. The picker
   can repeat either mode; initial window creation can shorten the first mode's
   visible interval.
5. Compare callback counters and `presentedSeconds` in both modes, including
   each run's `lateRead` line.

Both modes use a clear-only render pass with `.store`, `.bgra8Unorm`,
`framebufferOnly=true`, a requested 60 Hz cadence, a three-drawable pool and at
most two GPU jobs in flight. Both explicitly set `presentsWithTransaction=false`;
the logged default value is also false. The handler is registered before
`commandBuffer.present(drawable)` and `commandBuffer.commit()`.

## Expected result

For drawables that are actually displayed, `presentedTime` should report a
positive finite host timestamp through `addPresentedHandler`. It is reasonable
for an unpresented or dropped frame to report zero. This expectation follows
Apple's [presentedTime documentation](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
and [presentation-handler example](https://developer.apple.com/documentation/metal/mtldrawable/addpresentedhandler(_:)).

## Actual result

The tester confirmed visible color changes in both modes. At these logged
checkpoints, every counted callback returned zero:

| Mode | Callbacks | Zero timestamps | Positive finite | Invalid | GPU completed | GPU failed |
|---|---:|---:|---:|---:|---:|---:|
| MTKView currentDrawable | 900 | 900 | 0 | 0 | 899 | 0 |
| CAMetalLayer queued nextDrawable | 1440 | 1440 | 0 | 0 | 1439 | 0 |

These are checkpoints, not final totals or measured frame rates. Counters include
every presented callback; output is limited to the first three callbacks and
every 60th callback. Each mode has a separate run identity.

For frame 3 in each mode, the app retains one drawable for a single reread
100 ms after its callback. `presentedTime` is still `0.0` on both rereads. This
brief retention can affect drawable availability; it is not a latency baseline.

For the first three frames in each mode, console output records a zero-valued
presentation-handler entry before that frame's GPU-completion entry. For example,
the standard mode reports frame 1 with `gpuCompleted=0`, followed by its GPU
completion with `gpuStart=45177.715727625`, `gpuEnd=45177.71574429167` and
`status=4` (`completed`). This is an observation of callback logging/counter
order. It does not establish that physical presentation preceded GPU execution.

## Scope of the evidence

This is a confirmed reproduction on the device/runtime above. Visible animation
does not prove that every individual sampled drawable reached the display.
Neither callback arrival time, GPU completion time nor a predicted display time
is substituted for a real presentation timestamp. Other devices and OS versions
have not been tested for this report.

The standard delegate path reproduces the same endpoint behavior as queued
layer acquisition, so the observation does not depend on the original
application's background acquisition pattern.

## Reproduction material

- `PresentationProbe.swift` and `PresentationProbe.xcodeproj`.
- `README.md` with build and run instructions.
- `device-result-2026-09-07.md` with the validated device checkpoints.

Only probe-specific output is relevant. No external report or diagnostic upload
has been performed as part of preparing this draft.
