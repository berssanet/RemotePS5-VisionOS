# Low-bandwidth source and MetalFX

## User feedback and current scope

On 2026-09-09 the user reported that the control-position button did not allow
holding and moving the panel, and that the depth experiment gave a small sense
of depth but mostly made the image shake. The user explicitly suspended depth
until upscaling is adjusted, requesting a lower-quality PS5 stream to reduce
transport load and assess MetalFX reconstruction.

The active app now has no depth controls, inference, stereo material or model
bundle. Experimental sources/assets and their earlier evidence are retained in
the repository for later work. The prior model smoke test did not validate
gameplay quality; the user's shaking report is not treated as acceptance.

## Requested profiles and actual image processing

The local Chiaki source defines these canonical presets. Both LAN and PSN
wrappers already pass the requested dimensions, maximum FPS and bitrate to the
console, using HEVC SDR for PS5. No native ABI or codec change is required.

| Profile | Requested source | Requested bitrate | MetalFX output at the default 2560×1440 window |
| --- | --- | --- | --- |
| Minimum/default | 640×360 at 60 fps | 2,000 kbps | 2560×1440 |
| Low | 960×540 at 60 fps | 6,000 kbps | 2560×1440 |
| Standard | 1280×720 at 60 fps | 10,000 kbps | 2560×1440 |
| Reference | 1920×1080 at 60 fps | 15,000 kbps | 3840×2160 |

The profile is saved on the home screen or in Settings. Startup captures it
before authentication and passes it unchanged through either connection path.
Changing it during an active session is disabled. The minimum is the smallest
canonical source preset, not a claim about the protocol's absolute bitrate
limit. FPS stays at 60 so this comparison does not also change source cadence.

The previous MetalFX implementation required a 1920×1080 buffer and otherwise
fell back to Native. It now creates a scaler from the actual decoded dimensions
and the presentation target. Output retains at least the previous 2× source
scale, grows to cover the target while preserving aspect ratio, and is bounded
by 3840×2160. A source or effective output configuration change recreates it.
Failed/invalid configurations fall back explicitly without retrying every frame.
Input usage and content dimensions follow the scaler's contract. Asynchronous
GPU completion retains the old scaler and textures through dimension changes.

Cinema allocates at least a 2560×1440 output, or 2× the session's requested
dimensions when larger, up to 4K; the window uses its drawable size. Both paths use the shared
processor and compare the same frame at matching coordinates. **Original** and
**Compare with original** replace the misleading fixed1080p labels. Requested
settings and actual decoded/processed/display sizes remain separate.

The initial filter is MetalFX; subsequent selection is saved. Enhanced is still
restricted to its supported1080p source and reports Native fallback otherwise.
The low-bandwidth comparison should use Original and MetalFX.

## Movable controls

The cinema panel has a dedicated **Move panel** handle. On visionOS26+ a spatial
DragGesture receives translation in the stationary anchor's coordinate space.
The gesture captures the panel's local origin once, then adds the total motion;
it does not accumulate incremental drift or move the anchor. Position remains
after release. Only the handle receives the drag gesture, leaving sliders,
buttons and gamepad focus handling independent. Recenter remains available.
Older supported systems retain explicit distance/recenter controls.

The implementation uses installed Helpike SwiftUI/RealityKit documentation and
the Xcode27 SDK. MetalFX behavior was checked through Helpike's MetalFX pack.
The deployment target remains visionOS2.0 with availability guards for the new
spatial gesture initializer.

## What the comparison can establish

Changing the requested bitrate from15 to2 Mbps reduces the encoder's requested
budget. It does not measure packet size, actual throughput or total latency.
The current reports cover local decode/GPU intervals, drops, retention and
memory; they do not count total network bytes. Chiaki's internal bitrate estimate
uses bytes per frame scaled by requested FPS and is not used as an independent
throughput measurement here.

MetalFX Spatial processes a decoded image. It cannot recover packets or guarantee
reconstruction of detail destroyed by compression/downsampling. Very poor input
can reveal these limits. Compare readable detail and artifacts on the frozen
same-frame split, then use live playback for motion/audio/input. Change profiles
only between connections and keep the displayed screen size comparable.

Historical baseline/overhead diagnostics retain their1080p60/15 Mbps contract;
they refuse lower requested profiles or mismatching observed frame dimensions.
To prepare them explicitly, choose the reference source profile and Original
before relaunching with diagnostic arguments. The saved filter avoids an implicit
mode override. No new baseline campaign or physical-latency study is claimed;
01.03 stays waived,01.10 deferred and01.08 open/inconclusive.

## Validation record

The integration was completed and installed by 2026-09-10.

| Check | Result and local evidence |
| --- | --- |
| GPU low-resolution correctness | 30,474 reference points across360p/540p/720p pass for bilinear reference/split/sRGB; existing1080p and freeze regressions pass. `/tmp/VisionRemotePS5-low-resolution-gpu.log` |
| GPU fallback and lifetime | Invalid dimensions/input, creation failure without retry loops, drawable resize reuse and source resize with two GPU generations in flight pass. Same GPU log. |
| Spatial drag typecheck | Xcode27 SDK, target visionOS2 with availability guard; no warnings/errors. `/tmp/VisionRemotePS5-cinema-drag-typecheck.log` |
| Historical diagnostic regression | Probe ON/OFF host and Swift→Python checks pass. `/tmp/VisionRemotePS5-low-bandwidth-probe-host.log`; private app guards also compile in full builds. |
| Signed Debug / unsigned Release | Both full app builds pass without Swift compiler warnings/errors. `/tmp/VisionRemotePS5-low-bandwidth-device-build.log`, `/tmp/VisionRemotePS5-low-bandwidth-release-build.log` |
| Depth exclusion | Fresh signed bundle has zero compiled models and no StereoVideo.usda; minimum OS remains2.0 and SDK27. |
| Device | CoreDevice confirms installation; `/tmp/VisionRemotePS5-low-bandwidth-install.log`. Normal console launch record: `/tmp/VisionRemotePS5-low-bandwidth-console.log`. |

The initial record above predates the screenshot feedback below. Physical
usability of dragging and total latency still require observation. Neither
synthetic pixel differences nor the reduced requested bitrate establish those
results. No commit or push was performed; TODO remains local/ignored.

## Screenshot feedback and final-scale correction — 2026-09-10

The user supplied two local test captures comparing Original and MetalFX,
reporting no visible improvement. Both showed a blurred console menu; the images
were removed at the user's request on 2026-09-12. This is
negative perceptual feedback, not successful image-quality acceptance.

The screenshots and the captured device console agree on the effective sizes:

- Original: source 640×360, processing 640×360, display 2560×1440.
- Previous MetalFX: source 640×360, processing 1280×720, display 2560×1440.

The device log `/tmp/VisionRemotePS5-low-bandwidth-console.log` records several
mode transitions after successful GPU completion. Code review followed the
selected texture into the final fragment binding and drawable presentation;
no hidden Native bypass was found. Comparison was off in the supplied MetalFX
capture. The unchanged source and display sizes are expected when switching
filters; they do not establish that the scaler was skipped. Conversely, the
processing-size label does not establish useful image quality.

The concrete issue was stopping MetalFX at 720p, then enlarging that result again
with bilinear sampling to the 1440p drawable. The processor now chooses an output
that covers the target while preserving aspect ratio and the 4K budget. For the
reported case it uses 640×360 → MetalFX 2560×1440 → final sampling at 1:1.
Cinema's texture now has a 2560×1440 minimum instead of dropping to 1280×720 with
the 360p profile. Larger targets beyond the allocation cap explicitly report the
remaining display scaling. Window/compositor sampling after this app-owned target
is still controlled by visionOS, so the target is not a measure of perceived
resolution at the eye.

The scaler is recreated only when the source or effective output changes;
aspect-ratio rounding reuses identical output configurations. GPU completion
retains retired scalers and buffers. Output is still private GPU storage, with
no CPU readback or new frame queue in playback. The larger output costs more GPU
work and memory; no latency improvement is inferred from this correction.

GPU regression passed in `/tmp/VisionRemotePS5-display-scale-gpu.log`: 16,745
sample locations of the final 1440p texture match an independent direct
`MTLFXSpatialScalerDescriptor` reference. Original is checked against independent
bilinear sampling; split and sRGB are checked against those references. The
fixture distinguishes the former 720p intermediate path, so checking only status
text cannot satisfy the test. Output growth/shrink, bounded allocation, failed
creation recovery and two in-flight generations also pass.

A separate synthetic edge experiment found a narrower 10–90% transition with
direct 4× scaling than with the old 2× + bilinear 2× path; see
`/tmp/VisionRemotePS5-direct-scaler-probe.log`. Both are Mac GPU results. Neither
proves recovered source detail or perceptible improvement in the PS5 stream.
Depth remains suspended; no waived/deferred measurement is reopened.

The corrected signed Debug and unsigned Release builds both passed without
compiler warnings/errors (`/tmp/VisionRemotePS5-display-scale-device-build.log`,
`/tmp/VisionRemotePS5-display-scale-release-build.log`). CoreDevice confirmed
installation in `/tmp/VisionRemotePS5-display-scale-install.log`. The corrected
version was launched normally with console capture at
`/tmp/VisionRemotePS5-display-scale-console.log`. Perceptual acceptance of this
new version is pending; the supplied screenshots belong to the previous version.

During the new device session, the console recorded successful GPU completion
for `MetalFX · Source 640×360 → Processing 2560×1440 · Display 2560×1440`,
switches back to Original, and the same-frame Original/MetalFX split. No GPU
command failure was logged at that check. This confirms execution of the new
configuration on the Vision Pro; it still does not establish perceived quality.

## Follow-up: preserve the 1080p upscaler's 4K output — 2026-09-10

The user also reports insufficient improvement in previous 1080p comparisons.
Inspection found a complementary defect: the window automatically sized its
drawable from window points and a fixed 2× density. A 2560×1440 drawable reduced
the 3840×2160 MetalFX result before submission to the system compositor.

`MetalTextureView` now chooses the drawable from the actual decoded source and
the native size recommendation: at least 2× source, a 1440p floor, bounded to
4K. Thus 1080p keeps a 4K app-owned presentation target; 720p keeps at least
1440p. Original uses the same target. Acquired drawables with stale sizes are
rejected without caching the frame as presented, allowing the next draw to retry.
Layer configuration stays on MainActor; a private drawable provider exposes only
`nextDrawable()` to the existing serial worker. The window's physical placement
and the visionOS compositor still affect the final perceived image.

This does not explain all feedback: cinema already used 4K for the requested
1080p profile. Isolated M3 Pro tests found mixed Spatial quality gains and no
color-format cancellation in the tested SDR path; see the
[updated diagnosis](analise_realista_metalfx_2026_09_10.md). The unshipped Detail
experiment was archived and removed from active sources.

Signed Debug passed without compiler warnings and the existing GPU regressions
passed. CoreDevice confirmed installation and normal launch. Evidence uses the
`/tmp/VisionRemotePS5-presentation-target-` build, GPU, install and console logs.
The new device console subsequently confirmed MetalFX Source1920×1080 →
Output texture3840×2160 → Display target3840×2160, plus Original mode switches
with the same 4K target. Perceived improvement remains pending. The increased
target also increases Original's final-pass pixel count; no latency reduction is
claimed. Source profiles are still selected before connection, not automatically
adapted to changing network conditions.
