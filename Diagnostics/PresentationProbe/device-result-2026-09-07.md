# Physical presentation probe — 2026-09-07

Task 01.03 was waived by the user on 2026-09-07. No valid physical presentation
endpoint was obtained; retain this result as a limitation, not a passed test.

## Environment and procedure

Apple Vision Pro `RealityDevice14,1`, visionOS 27.0 (`24M5361a`), Xcode 27.0
(`27A5252f`). Standalone Debug app built from this directory, signed and installed
under `com.visionremote.ps5.presentationprobe`. The streaming app's Xcode session
had ended before the probe was launched. No streaming sources or native libraries
are linked into the probe.

The probe starts with the standard MTKView delegate path and switches to queued
layer acquisition 20 seconds after view startup. Window creation affects the
available rendering interval; callback counts are not a measured frame rate.
See [README](README.md) for the exact paths, settings and bounded late-read check.

## Observed checkpoints

| Mode | Callbacks | Zero | Positive finite | Invalid | GPU completed | GPU failed |
|---|---:|---:|---:|---:|---:|---:|
| MTKView currentDrawable | 900 | 900 | 0 | 0 | 899 | 0 |
| CAMetalLayer queued nextDrawable | 1440 | 1440 | 0 | 0 | 1439 | 0 |

These are logged checkpoints, not final totals. GPU and presented handlers are
asynchronous; their arrival order is not used as a presentation timestamp. In
both modes the default and effective `presentsWithTransaction` values were false.
Frame 3's `presentedTime` remained 0.0 on the one-off reread 100 ms later in each
mode. Actual GPU start/end timestamps were nonzero and GPU commands completed.

The user confirmed that the color changes in both probe modes. This supplements
the earlier confirmation of visible moving gameplay in the separate streaming
app. Together with the callback counters, it establishes a visible standalone
reproduction with unavailable reported presentation endpoints on this device.

## Interpretation

The unavailable endpoint reproduces without the application's decoder, mailbox,
metrics recorder or background acquisition pattern. Changing production to the
standard MTKView acquisition pattern is therefore not supported as a remedy by
this test. The zero value cannot establish that every sampled drawable was
displayed, nor prove a general API limitation in all visionOS versions. No
synthetic endpoint, fallback latency, percentile, or overhead claim is added.

This standalone project and the confirmed visual conditions can be used for a
platform bug report. No report has been submitted externally.

## Build and local evidence

Signed Debug build: exit 0, `BUILD SUCCEEDED`. Swift compilation has no warnings
or errors. The build emits the informational App Intents metadata-extraction
warning because this app has no AppIntents dependency. Project `plutil -lint`
and repository `git diff --check` pass. No simulated/GPU-host result is used as
physical validation.

- `/tmp/VisionRemotePS5-presentation-probe-signed.log`
- `/tmp/VisionRemotePS5-presentation-probe-install.log`: installation exit 0.
- `/tmp/VisionRemotePS5-presentation-probe-console.log`: actual device callbacks.

The initial sandboxed build could not launch SwiftUI macro plugins; the signed
build above was rerun outside the sandbox. Earlier source warnings were corrected
before this device run. The production app was not changed for this reproduction.
