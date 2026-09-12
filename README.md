# VisionRemotePS5

A native PlayStation Remote Play client for Apple Vision Pro, with a Metal video window and a spatial cinema presentation. A Bluetooth gamepad paired with the headset controls the PS5.

## Current behavior

- **Video:** selectable source profiles request 360p/2 Mbps, 540p/6 Mbps, 720p/10 Mbps or 1080p/15 Mbps, all at 60 fps. The new default is 360p/2 Mbps for the low-bandwidth upscaling test. Profiles are saved and apply on the next connection. VideoToolbox decodes HEVC/H.264 to BGRA; playback remains SDR.
- **Processing:** MetalFX is the initial filter, with the user's subsequent selection saved. Output preserves source aspect ratio, with a minimum 2× scale and a 4K allocation limit. The window now controls its final drawable independently of window points: 1080p keeps a 3840×2160 target instead of reducing the 4K processed texture to 1440p; 720p uses at least 2560×1440. Lower profiles retain the 1440p presentation floor and scale directly to it. Cinema also uses a 1440p minimum and a 4K texture for the requested 1080p profile. **Original** uses ordinary scaling into the same target for comparison. Enhanced remains a 1080p-source filter; unavailable processing reports a fallback. These are spatial image operations, not neural reconstruction.
- **Depth:** the 3D experiment is suspended at the user's request after limited perceived depth and shaking. Its sources and assets are retained for later work but excluded from the app target. The app does not load a depth model or allocate stereo resources.
- **Comparison:** window and cinema share the same GPU processing. **Compare with original** shows the received frame on the left and the selected filter on the right, using the same frame and coordinates. Move the divider without changing window size or source content.
- **Detail inspection:** **Inspect image detail** can freeze the displayed frame and enlarge the same region on both sides by 2× or 4×. Only the image pauses; the game, audio and controller input continue. **Live / 1×** resumes the latest frame and restores the full image.
- **Processing feedback:** reports the applied mode, source size, processed texture size and output target size. These dimensions describe GPU textures, not perceived resolution at the eye. Thermal pressure or unavailable processing can cause a reported fallback to native video.
- **Rendering:** a latest-frame mailbox feeds the selected consumer through a shared Metal queue. The window uses MTKView; cinema uses a RealityKit unlit screen backed by a GPU-updated LowLevelTexture. Each renderer bounds outstanding command buffers. Requesting a high display cadence does not turn the 60 fps source into 120 fps video.
- **Audio:** Chiaki decodes Opus; an AVAudioSourceNode plays direct stereo through a bounded ring buffer with backlog recovery.
- **Input:** GameController reads buttons, sticks, and analog triggers on an independent 120 Hz input thread. DualSense touchpad **button clicks** are mapped; full touch-surface gestures and adaptive-trigger resistance are not implemented by this path. Rumble uses the controller's haptic engine when supported/enabled.
- **Session UI:** connecting opens the streaming window. **Enter Cinema** opens a full immersive space with a screen curved horizontally and vertically around the player's initial head position. Default coverage is 180° horizontal × 101.25° vertical; **Screen coverage** adjusts it from 120° to 200° horizontally. The full video maps onto the curved surface, which stays fixed in space. **Recenter cinema** places the screen and controls around the current head position again. The panel can move inside the screen with a margin to prevent it from disappearing behind the picture; **Return to Window** restores the window. Both presentations use the same session, audio and input controller. Closing the required streaming window outside this handoff ends the session.
- **Launch UI:** opens at 840×660 points with a 760×580 minimum on the home screen, including after returning from streaming. A saved console and **Connect** are the main action; **Connection options** contains local network, PSN and PIN setup. Additional saved consoles are selected from a menu.
- **Connectivity:** local discovery, direct-IP connection, stored registration keys, PIN pairing, wake requests, PSN authentication, and a separate PSN remote connection/registration flow are present.

The active priority is image quality versus source bandwidth with MetalFX. The user reported only a subtle gain after the earlier low-resolution correction and insufficient improvement in previous 1080p tests. A further window presentation defect has been corrected; substantial perceived improvement and lower total latency remain unproven. Source profiles are selected before connection; automatic network adaptation is not implemented. See the [current diagnosis](docs/analise_realista_metalfx_2026_09_10.md). Neural restoration, spatialized audio, HDR/P010 playback and frame interpolation are not implemented.

## Requirements and build

- A Mac with Xcode and the visionOS SDK. The current toolchain is **Xcode 27 (`27A5252f`) with SDK 27**; the project deployment target remains **visionOS 2.0**.
- A physical Apple Vision Pro for playback and controller validation. The bundled Chiaki XCFramework contains an **xros arm64 device slice**, not a simulator slice.
- A PS5 with Remote Play enabled and a compatible Bluetooth gamepad paired with the Vision Pro.
- A signing team/provisioning configuration for installation on the headset.
- PSN OAuth client configuration if using browser authentication or PSN connection features.

The device validation target is visionOS 27.0 (`24M5361a`). Build, installation and windowed playback have been verified with this toolchain/device combination. New presentation behavior has its own physical acceptance.

1. Clone the repository and open `VisionRemotePS5.xcodeproj`.
2. Copy the configuration template if a local configuration does not already exist:

   ```sh
   cp -n Local.xcconfig.example Local.xcconfig
   ```

3. Fill in `PSN_CLIENT_ID` and `PSN_CLIENT_SECRET` in the ignored local file when PSN features are needed. Placeholder values allow configuration of the project but do not provide working authentication. The project already references `Local.xcconfig` for Debug and Release.
4. Set your development team and signing configuration in Xcode. Do not overwrite another developer's local credentials.
5. Select the `VisionRemotePS5` scheme and a physical Apple Vision Pro, then build and run.

For a device-targeted compilation check without signing:

```sh
xcodebuild -project VisionRemotePS5.xcodeproj \
  -scheme VisionRemotePS5 \
  -configuration Release \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/VisionRemotePS5-build \
  CODE_SIGNING_ALLOWED=NO build
```

The precompiled native libraries are tracked in this repository; a normal app build does not require cloning or recompiling Chiaki. Some maintenance scripts and host tests have additional source dependencies described below.

The isolated Release build was verified with Xcode 27 and SDK visionOS 27 after including the curl public headers used by the C bridge. See the [clean-build artifact record](docs/clean_build_artifacts_2026_09.md) for the tested configuration, dependency hashes, and reproduction steps.

## Connect over the local network

1. Enable Remote Play on the PS5. Keep the console reachable from the headset's network and allow Local Network access when the app requests it.
2. For a saved console, select a **Stream** profile and choose **Connect**. The same profile is available in **Settings → Streaming**. For setup or another address, open **Connection options → Local network**, enter the console IP, and choose **Connect locally**.
3. If this app has valid registration keys for the matching console/account, the app uses them for a direct LAN session. Console identity is checked using the discovery MAC, not just a name or IP.
4. Otherwise, complete PIN pairing. On the PS5, open **Settings > System > Remote Play > Link Device** and enter the displayed PIN in the app. Use PSN sign-in or the supported manual Account ID entry to supply the account information required by pairing.
5. Return to the local connection action after pairing. Registration information is retained for subsequent sessions.
6. Use the paired Bluetooth gamepad during playback. Select image processing in the ornament below the video; the Enhanced mode exposes sharpening strength.

Registration performed in Sony's official app is not shared with this client. PSN authentication alone does not provide local registration keys. Wake requests also depend on console standby settings and network reachability.

## Cinema and image comparison

1. Choose a source profile, connect to PS5, then choose **Enter Cinema**. The curved screen starts with broad coverage around you. Use **Screen coverage** to bring the edges closer into view and **Recenter cinema** after changing your position. Move or collapse the controls while playing. See [curved cinema](docs/curved_cinema_2026_09_11.md).
2. On visionOS 26+, pinch and hold **Move panel**, then move your hand horizontally, vertically or closer/farther. The panel stays where released. **Hide controls** collapses it; the scope button recenters it. On older systems, explicit distance/recenter controls remain available. Hold the Digital Crown to recenter the screen.
3. Select **MetalFX** and enable **Compare with original**. Left is the received image; right is MetalFX. Both sides use the same low-resolution frame. The status separately shows requested source settings and actual decoded/processed/display dimensions.
4. Inspect a fixed detail with **Inspect image detail → Pause image → 2×/4×**. Audio, game and controls continue; **Live / 1×** restores normal playback. Use live playback to judge motion and responsiveness.
5. End the session before changing source profile. Compare 540p, 720p or the previous 1080p/15 Mbps reference at the same screen size. Extremely degraded source can expose the filter's limits rather than improve the quality/latency tradeoff. Current evidence: [low-bandwidth MetalFX](docs/low_bandwidth_upscaling_2026_09.md).

## PSN connections

The home screen includes PSN console access, and the code contains session coordination, WebSocket signaling, registration, and native holepunch support. This path has different requirements and failure modes from direct LAN streaming.

Successful compilation or LAN playback does not establish reliable end-to-end internet streaming across arbitrary NATs. Validate the PSN path on the intended networks before relying on it. The app ships a certificate bundle used by the native TLS path; it is an active resource, not an unused download.

## Project layout

```text
VisionRemotePS5/
  VisionRemotePS5App.swift        App state, windows and immersive cinema scene
  Views/                         Console, pairing, settings, video and cinema UI
  Models/                        Console and controller data
  Controllers/                   Bluetooth gamepad, input thread, rumble
  Services/                      Connection/authentication and stream orchestration
    StreamingService.swift       Active StreamVideoDecoder implementation
  Streaming/                     Frame mailbox, shared GPU processing, cinema, stereo audio
  Chiaki/                        Project-owned C bridge and native helpers
  Frameworks/                    Tracked Chiaki XCFramework and json-c library
  Resources/                     App assets and native TLS certificate bundle
VisionRemotePS5Tests/             XCTest sources and host-test harnesses
scripts/                         Native maintenance and focused regression tests
docs/performance_fixes_2026_09.md Historical regression findings and test context
Local.xcconfig.example           Local credential/signing configuration template
```

The former quarantine directory, 3D reference assets, unreferenced video classes, disconnected localization catalog, old Android/VR architecture documents, and experimental model conversion scripts have been removed. Their earlier versions remain available in Git history. `TODO.md` is a local, ignored planning file and is not required to build or run the app.

## Native dependencies and maintenance

The app links:

- `VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a`
- `VisionRemotePS5/Frameworks/json-c/libjson-c.a`

`chiaki-ng/` is a separate, ignored checkout whose upstream is `streetpea/chiaki-ng`; it is not a submodule of this repository. Local upstream edits are not automatically included in app commits. The app uses the tracked static archive, not source files from that checkout.

`VisionRemotePS5/ThirdParty/curl/` contains the unmodified public curl headers and license needed to compile `ChiakiCore.c`. Debug and Release use this project-local include path. The [header provenance record](VisionRemotePS5/ThirdParty/curl/README.md) pins the revision and checksums; the curl implementation remains inside the existing Chiaki archive.

Preserve the adjacent `.orig` and `.backup` archives: `merge_chiaki_opus.sh` reads them as input when rebuilding the merged library. These are maintenance dependencies even though the app does not link them. Do not substitute a minimal crypto-only Chiaki archive for the merged library or infer native struct layouts from headers alone; the C bridge has compatibility safeguards for the shipped archive.

Maintenance scripts retained for the current native stack:

| Script | Purpose |
|---|---|
| `build_opus_visionos.sh` | Build the Opus dependency used by native audio maintenance |
| `merge_chiaki_opus.sh` | Merge existing Chiaki/Opus artifacts into the library |
| `build_jsonc_visionos.sh` | Build json-c for the holepunch path |
| `build_ca_bundle.sh` | Refresh the certificate resource used by native TLS |
| `rebuild_video_modules.sh` | Recompile video receiver/frame processor modules |
| `rebuild_feedback_module.sh` | Apply the pinned feedback-sender fix in a temporary source copy |
| `rebuild_takion_module.sh` | Rebuild Takion with the transport/reordering changes |
| `rebuild_holepunch_module.sh` | Rebuild native holepunch with its project-specific fixes |

These are maintenance tools, not an automatic clean-room rebuild of every native dependency. Inspect their prerequisites and source revisions before running them. Do not run them merely to build the Swift app; some replace native artifacts or access the network.

## Validation

Run these focused harnesses from the repository root:

```sh
bash scripts/test_video_decoder.sh
bash scripts/test_audio_buffer.sh
bash scripts/test_video_gpu.sh
bash scripts/test_feedback_sender.sh
bash scripts/test_socket_mode.sh
bash scripts/test_psn_customdata.sh
bash scripts/test_streaming_metrics.sh
```

- Decoder tests use real host VideoToolbox H.264/HEVC decoding, dependent frames, and recovery/backpressure cases.
- Audio tests check bounded buffering, channel alignment, recovery, and concurrent access.
- GPU tests run MetalFX and Enhanced on the **Mac GPU**, checking asynchronous texture reuse, same-frame split fidelity, sRGB parity and encoder-failure fallback. Pixel differences on the synthetic pattern are not quality scores.
- `test_stereo_video_gpu.sh` and `test_depth_estimation.sh` are retained for the suspended depth experiment; they are not checks of the active app target.
- Feedback tests simulate a blocked sender and verify input progress and button transitions. They require the local Chiaki checkout and pinned source commit referenced by the script.
- Socket tests check nonblocking flags and error handling. PSN custom-data tests require the Chiaki source files referenced by their script.
- Metrics tests check monotonic timestamps, units, invalid intervals, integer boundaries, and [session/frame isolation across late callbacks](docs/metrics_session_identity_2026_09.md). [Video instrumentation](docs/video_metrics_instrumentation_2026_09.md) records bounded, session-scoped decode/GPU/presentation intervals; physical timestamp validation remains pending.

The `*HostTests.swift` files are standalone harnesses invoked by scripts, not XCTest target members. XCTest source files also exist, but the shared scheme currently does not explicitly list a testable target; the shell harnesses above are the directly reproducible checks documented here.

A successful host test or Release build does not prove PS5/Vision Pro latency or visual quality. On the headset, test connection, sustained gameplay, processing switches, audio, rumble, controller reconnection, and closing/reopening the stream. The detailed regression record is in [performance fixes](docs/performance_fixes_2026_09.md).

The new presentation and comparison implementation, build/install evidence and
remaining physical checks are recorded in [cinema and image comparison](docs/cinema_and_image_comparison_2026_09.md).

Debug video logs measure reception-to-GPU and reception-to-presentation in the local pipeline. They exclude earlier PS5 capture/encoding, network transit before reception, and Bluetooth input latency. Most noncritical Swift logs are disabled in Release; native diagnostics and errors can still be emitted. Do not share credentials, pairing keys, or unreviewed raw logs.

## Development scope

This branch adds spatial cinema, direct filter comparison, a cleaner launch screen and selectable source quality. Depth work is suspended. It does not complete the local roadmap or claim measured image-quality/performance gains. Further rendering work must preserve the active decoder, direct-stereo audio and independent input path.
