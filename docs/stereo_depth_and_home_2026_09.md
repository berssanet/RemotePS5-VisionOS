# Home redesign and estimated stereoscopic depth

**Suspended after user feedback:** a small depth sensation was reported, but
mostly image shaking and no convincing immersion. The user requested that depth
wait until upscaling is adjusted. All depth sources/assets are excluded from the
active app target. This document preserves the earlier experiment's evidence;
current work is [low-bandwidth MetalFX](low_bandwidth_upscaling_2026_09.md).

## Request and observed problem

On 2026-09-09 the user supplied seven local test captures, removed at their request on 2026-09-12. The first
shows a small home window with a truncated title and clipped content. The others
show the existing cinema/filter comparison without an evident image benefit.
The requested effect is binocular depth like a 3D film, rather than more spatial
upscaling. No game identity from the captures is recorded here.

The home content had no useful minimum size while the same window shrank to a
hidden 1×1 view during streaming. The revised scene opens at 840×660 points and
the home content requires at least 760×580, restoring useful bounds on return.
A saved console and Connect are prominent; additional consoles use a menu.
Local network, PSN, PIN registration and refresh remain in Connection options.
The disconnected ornament is removed. Storage, credentials and connection
implementations are preserved.

## Visible 3D behavior

Cinema now exposes **2D / 3D depth**, independently of the old 2D filters. 3D uses
the live original 1080p frame, with a depth intensity control. The previous 2D
filter selection is retained. Enabling 3D exits frozen/zoomed inspection.
The panel starts at the current viewing direction; image filters are collapsed
under a disclosure to keep the primary controls short.

The bundled model estimates relative inverse depth. Metal generates a matched
left/right pair from one color frame; a RealityKit ShaderGraphMaterial routes
each half to its eye. Near features converge at the screen plane and farther
features appear behind it. Total horizontal disparity is capped at 1.2% of the
screen width, with a default strength of 65%. There is no vertical disparity.
**Keep center and edges flat** masks fixed regions commonly occupied by text or
reticles; it is not semantic HUD detection and can flatten other content there.

Return to 2D is immediate as an action; the renderer initializes the current
2D texture before presenting it. Unusable depth maps produce matching flat
views while color delivery continues. Source resolution, rate, bitrate, audio,
controller loop and native Chiaki ABI are unchanged.

This is synthesized stereo from a monocular stream. The model does not receive
the game's depth buffer, cannot recover hidden geometry, and may misplace HUD,
transparent objects or thin edges. Inverse warping clamps uncovered borders;
there is no generative filling or neural image restoration. Perceived quality,
comfort and sustained performance require a separate headset observation.

## Model and scheduling

- Apple-published DepthAnythingV2SmallF16 Core ML package, about 49.8 MB, bundled
  unmodified with its Apache-2.0 license and checksums. See the
  [model provenance](../VisionRemotePS5/Resources/DepthAnythingV2-PROVENANCE.md).
- Actual fixed schema: BGRA `image` 518×392 → Float16 image `depth` 518×392.
  The entire source is resized to the input. Relative inverse depth is sampled
  into a 259×196 immutable r32Float texture in normalized source coordinates.
- Core ML allows CPU and GPU; no Neural Engine or enterprise entitlement is
  assumed. A separate serial lane admits at most eight predictions per second,
  with one job in flight and no pending frame queue. No per-frame model download,
  compilation or main-actor image publication occurs.
- Each map carries generation, source frame, admission time and inference time.
  Live maps expire at 250 ms with an age fade; a small luma signature attenuates
  or rejects incompatible motion/cuts. Range normalization uses robust percentiles
  with temporal smoothing and reset at cuts. These are heuristics, not model
  confidence or optical-flow tracking.
- Disable, session changes and retirement revoke pending results. Serious or
  critical thermal state returns to 2D. Cold model loading can take seconds and
  its first stale result is discarded. Rendering never waits for prediction.
- GPU resources remain alive until their command buffer completes. Both eyes
  always derive from the same color frame. LowLevelTexture replacement is still
  initialized/committed on revoked or failed work; completion is not a physical
  presentation timestamp.

## Documentation and validation

After the user's correction, framework documentation was checked through the
installed Helpike packs `apple/swiftui`, `apple/realitykit`, `apple/coreml` and
the local Xcode 27 SDK. All packs required by this stack are already installed.
Relevant Helpike pages include
[WindowResizability](https://developer.apple.com/documentation/swiftui/windowresizability),
[ShaderGraphMaterial](https://developer.apple.com/documentation/realitykit/shadergraphmaterial),
[connected stereo video](https://developer.apple.com/documentation/realitykit/displaying-low-latency-connected-video)
and [MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits).
Model artifacts came from Apple's model distribution URL, with provenance above.

| Check | Evidence |
| --- | --- |
| GPU pair fidelity, SDR/orientation, fallback, disparity sign, HUD regions and lifetime | `scripts/test_stereo_video_gpu.sh`: 1,815,843 assertions; `/tmp/VisionRemotePS5-stereo-gpu-tests.log` |
| Depth scheduling, finite maps, generation/disable/stop, age and motion rejection | `scripts/test_depth_estimation.sh`; `/tmp/VisionRemotePS5-depth-estimation-tests.log` |
| Actual bundled model on Mac CPU/GPU | Valid schema and maps; warm predictions 28/29/30 ms in the recorded run. A prior cold invocation took about 3 seconds. These are not Vision Pro measurements. |
| Material load and dynamic texture binding | Real RealityKit host loading, parameters and invalid layout/mipmap rejection pass; `/tmp/VisionRemotePS5-stereo-material-host.log` |
| Full signed Debug and unsigned Release | Both pass without Swift compiler warnings/errors; `/tmp/VisionRemotePS5-stereo-home-device-build.log` and `/tmp/VisionRemotePS5-stereo-home-release-build.log` |
| Bundled artifacts | Signed app includes compiled model, StereoVideo.usda and model license; minimum OS remains visionOS2.0, compiled with SDK27 |
| Model on the actual Vision Pro | Synthetic input only: first prediction3045ms, warm predictions97/76/77ms; valid259×196 maps, warm maps accepted by the live age gate. `/tmp/VisionRemotePS5-stereo-depth-device-smoke.log` |

CoreDevice confirmed installation of the signed Debug build and its launch
without diagnostic arguments after the opt-in model check. Evidence is
`/tmp/VisionRemotePS5-stereo-home-install.log` and
`/tmp/VisionRemotePS5-stereo-home-console.log`. The model check is explicitly
DEBUG-only (`--depth-model-smoke-test`), uses generated pixels and never reads
game frames, screenshots or account data. Its successful result establishes
model execution on the device, not inference timing under streaming load.

Final integration review corrected a queued inference race when disabling3D,
added mode revisions against3D→2D→3D stale callbacks, and delayed material changes
until current textures are initialized. Processor/map resource counters use
allocated bytes and include retained, inactive2Dupscaler allocations; they do
not cover CoreML/RealityKit internals or every transient allocation.

Next physical check: home window usability, Connect→Enter Cinema→3Ddepth,
intensity/region controls,2DandReturn to Window, with normal audio/controller
behavior. Binocular perception and comfort require observing through the headset;
an ordinary screenshot and the synthetic model check do not establish them.

The previous no-perceived-gain report for MetalFX/Enhanced remains valid; no new
2D filter improvement is claimed. Wider roadmap matrices remain open. 01.03 stays
waived, 01.10 deferred, and 01.08 open/inconclusive. No commit or push is implied.
