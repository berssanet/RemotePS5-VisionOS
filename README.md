# VisionRemotePS5

A native PlayStation Remote Play client for Apple Vision Pro. The current app displays a PS5 stream in a SwiftUI window backed by Metal and uses a Bluetooth gamepad paired with the headset.

## Current behavior

- **Video:** requests 1920×1080 at 60 fps with a configured bitrate of 15,000 kbps. VideoToolbox decodes HEVC/H.264 to BGRA; the active presentation path is SDR.
- **Processing:** native 1080p is the default. The streaming window also offers MetalFX spatial upscaling and Enhanced Lanczos upscaling with adjustable sharpening. Both upscalers produce a 3840×2160 texture from a 1080p source; this is not a native 4K stream.
- **Processing feedback:** the window reports the applied processing mode and input/output texture sizes. Thermal pressure or unavailable processing can cause a reported fallback to native video.
- **Rendering:** a latest-frame mailbox feeds an MTKView renderer on a dedicated serial queue, with at most two GPU command buffers in flight. Requesting a high display cadence does not turn the 60 fps source into 120 fps video.
- **Audio:** Chiaki decodes Opus; an AVAudioSourceNode plays direct stereo through a bounded ring buffer with backlog recovery.
- **Input:** GameController reads buttons, sticks, and analog triggers on an independent 120 Hz input thread. DualSense touchpad **button clicks** are mapped; full touch-surface gestures and adaptive-trigger resistance are not implemented by this path. Rumble uses the controller's haptic engine when supported/enabled.
- **Session UI:** connecting opens the streaming window and minimizes the home content. Closing the streaming window ends the session.
- **Connectivity:** local discovery, direct-IP connection, stored registration keys, PIN pairing, wake requests, PSN authentication, and a separate PSN remote connection/registration flow are present.

Immersive spaces, hand controls, a virtual steering wheel, stereo depth conversion, neural restoration, spatialized audio, HDR/P010 playback, and frame interpolation are not current app features. The UI no longer exposes placeholder resolution, spatial-audio, auto-connect, controller-mapping, or simulated network-diagnostic controls.

## Requirements and build

- A Mac with Xcode and the visionOS SDK. The locally verified toolchain for this cleanup is **Xcode 26.6**; the project deployment target remains **visionOS 2.0**.
- A physical Apple Vision Pro for playback and controller validation. The bundled Chiaki XCFramework contains an **xros arm64 device slice**, not a simulator slice.
- A PS5 with Remote Play enabled and a compatible Bluetooth gamepad paired with the Vision Pro.
- A signing team/provisioning configuration for installation on the headset.
- PSN OAuth client configuration if using browser authentication or PSN connection features.

The planned device validation target is visionOS 27 beta 8. This does not mean the app uses SDK 27 APIs or has been validated on that beta. Confirm a compatible Xcode/device-debugging combination before installation.

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

## Connect over the local network

1. Enable Remote Play on the PS5. Keep the console reachable from the headset's network and allow Local Network access when the app requests it.
2. On the home screen, use **Local Network**, enter the console IP, and choose **Connect locally**.
3. If this app has valid registration keys for the matching console/account, the app uses them for a direct LAN session. Console identity is checked using the discovery MAC, not just a name or IP.
4. Otherwise, complete PIN pairing. On the PS5, open **Settings > System > Remote Play > Link Device** and enter the displayed PIN in the app. Use PSN sign-in or the supported manual Account ID entry to supply the account information required by pairing.
5. Return to the local connection action after pairing. Registration information is retained for subsequent sessions.
6. Use the paired Bluetooth gamepad during playback. Select image processing in the ornament below the video; the Enhanced mode exposes sharpening strength.

Registration performed in Sony's official app is not shared with this client. PSN authentication alone does not provide local registration keys. Wake requests also depend on console standby settings and network reachability.

## PSN connections

The home screen includes PSN console access, and the code contains session coordination, WebSocket signaling, registration, and native holepunch support. This path has different requirements and failure modes from direct LAN streaming.

Successful compilation or LAN playback does not establish reliable end-to-end internet streaming across arbitrary NATs. Validate the PSN path on the intended networks before relying on it. The app ships a certificate bundle used by the native TLS path; it is an active resource, not an unused download.

## Project layout

```text
VisionRemotePS5/
  VisionRemotePS5App.swift        App state and home/streaming windows
  Views/                         Console, pairing, settings, and Metal video UI
  Models/                        Console and controller data
  Controllers/                   Bluetooth gamepad, input thread, rumble
  Services/                      Connection/authentication and stream orchestration
    StreamingService.swift       Active StreamVideoDecoder implementation
  Streaming/                     Frame mailbox, upscalers, stereo audio, ring buffer
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
```

- Decoder tests use real host VideoToolbox H.264/HEVC decoding, dependent frames, and recovery/backpressure cases.
- Audio tests check bounded buffering, channel alignment, recovery, and concurrent access.
- GPU tests run MetalFX and Enhanced on the **Mac GPU**, checking asynchronous texture reuse and border/center pixels.
- Feedback tests simulate a blocked sender and verify input progress and button transitions. They require the local Chiaki checkout and pinned source commit referenced by the script.
- Socket tests check nonblocking flags and error handling. PSN custom-data tests require the Chiaki source files referenced by their script.

The `*HostTests.swift` files are standalone harnesses invoked by scripts, not XCTest target members. XCTest source files also exist, but the shared scheme currently does not explicitly list a testable target; the shell harnesses above are the directly reproducible checks documented here.

A successful host test or Release build does not prove PS5/Vision Pro latency or visual quality. On the headset, test connection, sustained gameplay, processing switches, audio, rumble, controller reconnection, and closing/reopening the stream. The detailed regression record is in [performance fixes](docs/performance_fixes_2026_09.md).

Debug video logs measure reception-to-GPU and reception-to-presentation in the local pipeline. They exclude earlier PS5 capture/encoding, network transit before reception, and Bluetooth input latency. Most noncritical Swift logs are disabled in Release; native diagnostics and errors can still be emitted. Do not share credentials, pairing keys, or unreviewed raw logs.

## Development scope

This branch prepares the existing windowed client for future work. It does not implement the local immersion roadmap or claim benchmark results on visionOS 27 beta 8. Keep future rendering/ML experiments isolated from the active decoder, direct-stereo audio, and independent input path.
