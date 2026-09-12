# Spatial cinema and image comparison

Implemented on 2026-09-09 on `docs/active-streaming-paths`, with the earlier local
measurement and presentation work preserved. This delivery follows the user's
request for a visible immersive experience and a way to compare the image modes.
It does not assert that upscaling improves every source or completes the entire
immersion roadmap.

The subsequent [home and stereoscopic depth delivery](stereo_depth_and_home_2026_09.md)
adds a distinct3Dmode, moves the panel to the initial viewing direction and
places the existing filters under **2D image filters**. The records below describe
the earlier2Dcinema/comparison iteration; its tests do not establish3Dacceptance.

## Visible behavior

**Superseded on 2026-09-11:** the current screen is curved horizontally and
vertically, centered on the player's initial head pose, with adjustable coverage
and a shared screen/panel recenter action. See [curved cinema](curved_cinema_2026_09_11.md)
for the active implementation and validation. The flat-screen dimensions below
describe the earlier delivery.

The streaming window now offers **Enter Cinema**. The full immersive space
contains a flat 16:9 screen, initially four meters wide and three meters away,
with dark surroundings. The revised panel appears 1.2 meters in front of the
viewer and 0.18 meters below the initial gaze direction, then stays in space.
It adjusts screen size, selects the image filter and returns to the window.
**Hide controls** collapses it; the scope button places it in front of the
current viewing direction again. Screen scaling no longer changes panel height.
The source remains 1920×1080 at 60 fps with
the existing requested bitrate; the same service owns audio and gamepad input.

Both presentations offer **1080p**, **MetalFX** and **Enhanced**. Selecting a
filter exposes **Compare with 1080p**: the left side samples the original frame
and the right side samples that same frame after processing. The divider moves
without changing coordinates, geometry or source time. Enhanced also exposes
its existing sharpening strength. Native does not display a redundant split.

**Inspect image detail** provides **Pause image**, 1×/2×/4× zoom and nine detail
positions. Both sides sample the same frame and crop; the split can still move,
and filters and sharpening can change while the image is frozen. Only the image
pauses: the game, audio and controls continue. An explicit paused-image notice
and Resume action remain visible, including when cinema controls are collapsed.
**Live / 1×** returns to the latest frame and full image. Zoom magnifies existing
pixels and does not reconstruct source detail.

Status distinguishes source, processed texture and output target dimensions.
An upscaled texture is not a native 4K stream or a measurement of perceived
resolution. Thermal/availability fallback reports the effective mode.

## Implementation and review

- [AppState](../VisionRemotePS5/VisionRemotePS5App.swift) connects the existing
  driver to actual SwiftUI open/dismiss actions. The immersive scene refreshes
  dismissal from its own environment before the outgoing window is retired.
  Selection is applied synchronously to the mailbox before retirement; a return
  prepares a new window before dismissing cinema. Cancellation, startup and
  teardown retain the coordinator's existing ownership barriers.
- [ImmersiveCinemaView](../VisionRemotePS5/Views/ImmersiveCinemaView.swift) creates
  the screen, dark surround and accessible controls. Gamepad handling is opted
  in on the focused RealityView. Window focus is reclaimed after return or a
  failed/cancelled opening. Disappearance reports its immutable surface identity.
- [ImmersiveCinemaRenderer](../VisionRemotePS5/Streaming/ImmersiveCinemaRenderer.swift)
  prepares texture, material and controls before reporting readiness. Video does
  not have to arrive to permit the handoff. One scene-update actor hop and at
  most two command buffers may be outstanding. Encoding uses the shared serial
  GPU queue; decode/audio/input do not await that queue.
- [VideoFrameProcessor](../VisionRemotePS5/Streaming/VideoFrameProcessor.swift)
  handles both renderers and the split comparison. Device/command queue are
  shared; processor state and persistent upscaler textures belong to each
  consumer. Selection changes neither mailbox generation nor the retained frame.
  Old/unselected consumers cannot acquire new work, and submitted resources
  remain alive until GPU completion.
- RealityKit uses `LowLevelTexture.replace(using:)`, with each returned texture
  initialized and its command buffer committed even if work is revoked. An sRGB
  target with explicit shader conversion preserves encoded source values;
  unlit material tone mapping is disabled. This path uses APIs available since
  visionOS2.0, compiled with SDK27. [Apple texture synchronization](https://developer.apple.com/documentation/realitykit/lowleveltexture/replace%28using%3A%29)
  and [controller handling](https://developer.apple.com/videos/play/wwdc2024/10094/)
  informed the implementation.
- Enhanced now returns failure when either compute encoder cannot be created,
  allowing the renderer to use Native instead of stale/uninitialized output.
  Retention covers a failure after the first pass as well. Filters keep their
  existing strengths; no artificial tint or exaggerated effect was introduced
  to manufacture a visible difference.
- The revised panel uses a head anchor with `.once` tracking, following Apple's
  [head-relative placement example](https://developer.apple.com/documentation/visionos/placing-entities-using-head-and-device-transform).
  It needs no head-pose readback or continuous following. An anchor may be a
  child of the root entity, as in that example. Attachment controls restore
  gamepad focus after interaction.
- Frozen inspection retains at most one additional source pixel buffer. Live
  publication continues in the existing latest-frame slot; resume selects its
  current frame. Session end/disable releases the frozen frame, and generation
  and selected-consumer checks also apply to inspection. Frozen frames carry no
  reception-to-GPU/presentation sample metadata. The opt-in Native baseline
  and overhead probe reject/stop during freezing or zoom instead of measuring
  an inspection view as ordinary playback. GPU queue accounting remains real.

## Validation

Host GPU tests ran on the Mac; they are not headset quality measurements.

| Check | Result | Local evidence under `/tmp/` |
| --- | --- | --- |
| Native fidelity and sRGB target parity | 9,472 sampled points, error at most 1/255 | `VisionRemotePS5-0204-video-processor-gpu-authorized.log` |
| Same-frame split | 37,888 points per filter match the corresponding Native/processed reference within 1/255; divider endpoints pass | Same GPU log |
| Filter execution | Synthetic chart differs from Native at 37,506 sampled points for MetalFX and 37,504 for Enhanced; this is a pixel difference, not a quality score | Same GPU log |
| Error/resource handling | Injected first/second encoder failures, thermal fallback, asynchronous texture reuse and stable owned texture bytes pass | Same GPU log |
| Mailbox | Selection/generation guards and existing bounded/concurrent regression pass | `VisionRemotePS5-0204-mailbox.log` |
| Driver | 308 assertions pass, including gate-before-retirement/dismissal, stale callbacks and cancellation | `VisionRemotePS5-cinema-driver-host.log` |
| SDK typecheck | visionOS2.0 target with Xcode27; no warnings/errors | `VisionRemotePS5-cinema-typecheck/result.log` |
| Unsigned Release | Full app build passes without compiler warnings/errors | `VisionRemotePS5-cinema-release-authorized.log` |
| Signed Debug | Full app build passes without compiler warnings/errors | `VisionRemotePS5-cinema-device-build.log` |

The initial sandboxed build was blocked by SwiftUI macro services. The first
authorized build exposed Metal concurrency annotations and a SwiftUI capture
error; both were corrected before the successful builds. These earlier logs are
retained separately. No native library, ABI, PSN credentials or source streaming
parameters changed for cinema/comparison.

## User feedback and revised validation

The user confirmed that immersive mode worked, reported that controls were too
low to access comfortably, and perceived no difference between MetalFX and the
other image mode. That confirms visible cinema, not improved image quality or
the complete audio/input/return acceptance matrix. The panel placement above
addresses the access problem. Code review found no processing bypass explaining
the absent perceived gain; MetalFX is spatial scaling and Enhanced is Lanczos
plus a custom contrast-adaptive unsharp mask, not neural reconstruction.

The revised build adds frozen/cropped comparison to make subtle differences
easier to inspect without motion or source-time changes. This is an inspection
feature, not evidence of better quality. Filter strengths are unchanged.

| Revised check | Result | Local evidence under `/tmp/` |
| --- | --- | --- |
| 2×/4× crop and same-frame split | 4,182 sampled points per filter/zoom match independent bilinear references within 1/255; sRGB parity passes | `VisionRemotePS5-inspection-gpu.log` |
| Frozen image | Pixels stay fixed after 100 new frames; resume selects the latest frame | Same GPU log |
| Bounded retention and lifecycle | One extra frozen frame; live acquisition/overwrite accounting, session/disable release, stale-generation guards and invalid crop inputs pass | `VisionRemotePS5-inspection-mailbox.log` |
| Signed Debug and unsigned Release | Full builds pass without Swift compiler warnings/errors | `VisionRemotePS5-cinema-controls-device-build.log`, `VisionRemotePS5-cinema-controls-release-build.log` |

## Physical test

CoreDevice confirmed installation and launch of the revised signed Debug build
on the Vision Pro, with no diagnostic arguments. Evidence is
`/tmp/VisionRemotePS5-cinema-controls-install.log` and
`/tmp/VisionRemotePS5-cinema-controls-console.log`; build products are under
`/tmp/VisionRemotePS5-cinema-controls-device`. The minimum OS remains2.0.
The earlier installation/launch records are retained separately in
`VisionRemotePS5-cinema-install.log` and `VisionRemotePS5-cinema-console.log`.

The next physical check is whether the revised controls are comfortable and
whether a frozen 2×/4× split reveals useful detail or artifacts. Test **Live / 1×**
after inspection and **Return to Window**. Revised panel placement/repositioning,
physical focus, image orientation/color and controller/audio continuity still
require observation; no complete acceptance is inferred from the user's first
cinema confirmation.

01.08 remains open/inconclusive; 01.03 remains waived and01.10 deferred. No
physical presentation timestamp, new performance baseline, stereoscopic depth
or neural restoration result is claimed. No commit or push was performed.
