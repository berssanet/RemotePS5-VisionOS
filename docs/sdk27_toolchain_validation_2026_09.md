# SDK 27 toolchain validation — 2026-09-07

The existing app builds, signs, installs, and launches with Xcode 27 on the
physical Vision Pro. Developer disk image services report compatible and usable.
This is a toolchain check, not a playback or performance validation.

## Observed environment

| Component | Observed value |
|---|---|
| Starting app revision | `4f88fe36552446487dce16bd12a650fdd266292d` |
| Mac OS | macOS 26.6.2, build `25G83` |
| Xcode used | `/Applications/Xcode-beta.app`, 27.0, build `27A5252f` |
| Swift | Apple Swift 6.4, `swiftlang-6.4.0.33.1` |
| Device SDK | `xros27.0` |
| App deployment target | visionOS 2.0, unchanged |
| Headset | Physical Apple Vision Pro, `RealityDevice14,1` |
| Headset OS | visionOS 27.0, build `24M5361a` |
| Connection | Paired over local network; Developer Mode enabled |
| App artifact | Debug, version 1.0.0 (1), `com.visionremote.ps5` |

The global `xcode-select` path still points to Xcode 26.6 at
`/Applications/Xcode.app/Contents/Developer`. The commands below select the beta
for their own invocation using `DEVELOPER_DIR`.

## Build evidence

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project VisionRemotePS5.xcodeproj -scheme VisionRemotePS5 \
  -configuration Debug -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/VisionRemotePS5-sdk27-build build
```

Result: `BUILD SUCCEEDED`, exit 0, with no `warning:` diagnostics in the successful
build log. The initial sandboxed attempt could not find the signing profile;
the approved unsandboxed build signed successfully without changing project
settings or requesting provisioning updates. No app source changes were needed.

Local build log: `/tmp/VisionRemotePS5-sdk27-build.log`.
Artifact: `/tmp/VisionRemotePS5-sdk27-build/Build/Products/Debug-xros/VisionRemotePS5.app`.
The built Info.plist confirms `DTSDKName = xros27.0` and `MinimumOSVersion = 2.0`.
Executable SHA-256:
`8a4010ce81e22e26a027bb4d6a3ff073901e5556ea8d9021aab3eff127337e37`.
These temporary artifacts may be replaced by a subsequent build.

## SDK signatures checked

Inspected the installed SDK's
`RealityFoundation.framework/Modules/RealityFoundation.swiftmodule/arm64e-apple-xros.swiftinterface`.

- `LowLevelTexture` and its `replace(using: MTLCommandBuffer) -> MTLTexture`
  path are available from visionOS 2.0 and isolated to `MainActor`.
- `LowLevelDeviceResource` is available from visionOS 27.0.
  **Its `init(texture: MTLTexture)` is explicitly unavailable on visionOS.**
- visionOS exposes `init(sharedTextureHandle: MTLSharedTextureHandle) throws`
  and `init(textureDescriptor: MTLTextureDescriptor, iosurface: IOSurfaceRef,
  plane: Int) throws`.
- The visionOS 27 `LowLevelTexture.init(deviceResource:using:) throws` and
  `replace(deviceResource:using:)` accept an optional `MTLCommandBuffer` and are
  isolated to `MainActor`.

A temporary Swift probe importing RealityKit and Metal successfully typechecked
the shared-handle initializer, LowLevelTexture initializer, and both replacement
methods inside an `@MainActor @available(visionOS 27.0, *)` function, targeting
`arm64-apple-xros2.0`. Command:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun swiftc -typecheck -target arm64-apple-xros2.0 \
  -sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/XROS.platform/Developer/SDKs/XROS.sdk \
  -module-cache-path /tmp/VisionRemotePS5-sdk27-probe-cache \
  /tmp/VisionRemotePS5-sdk27-api-probe.swift
```

Result: exit 0, no diagnostics. This confirms compile-time availability only;
texture sharing, synchronization, lifetime, and display costs still require the
planned renderer experiments on the headset.

## Release notes

Apple's [Xcode 27 beta 6 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
were inspected on 2026-09-07. They specify macOS 26.4 or later and visionOS device
debugging support. The observed Mac meets that host requirement. The notes also
list possible delayed stdout/stderr delivery when streaming multiple processes;
do not infer runtime timing from console delivery alone. Apple's
[visionOS 27 release notes page](https://developer.apple.com/documentation/visionos-release-notes/visionos-27-release-notes)
was titled beta 8; the exact device build above remains the environment identifier.

## Device installation and launch

The signed app installation was attempted using Xcode 27's `devicectl device
install app` with a 60-second timeout. It exited 1. CoreDevice reported failure
to mount/unmount the developer disk image (12040/12016), with underlying
`10003`: the device is locked, and a recovery instruction to unlock it and retry.
The error chain also reported no existing Cryptex DDI (12053).

After the user unlocked the headset, the same installation command succeeded
(exit 0), reporting bundle ID `com.visionremote.ps5`. The following launch also
succeeded (exit 0), returning a process identifier for the newly installed app:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun devicectl device process launch --device '<paired-device-id>' \
  com.visionremote.ps5 --timeout 60
```

A fresh device details query succeeded without the previous DDI warning.
`devicectl device info ddiServices` then returned exit 0 with:

- `buildUpdate: 27A5252f`
- `platform: xrOS`
- `contentIsCompatible: true`
- `isUsable: true`
- `isCryptexDDI: true`

The build/install gate is complete for this observed combination. Installation,
launch, and usable debug services are verified; an LLDB attachment, visual UI
inspection, PS5 session, and device performance measurements were not performed.
Those results must not be inferred from this toolchain check.

Local evidence: `/tmp/VisionRemotePS5-sdk27-install.log`,
`/tmp/VisionRemotePS5-sdk27-launch.log`, `/tmp/VisionRemotePS5-sdk27-device.log`,
and `/tmp/VisionRemotePS5-sdk27-ddi.log`. The successful retries replaced the
initial installation/device logs; the earlier failure is summarized above.

Raw CoreDevice logs/JSON remain in `/tmp/VisionRemotePS5-sdk27-*`; they contain
device identifiers and must be reviewed/redacted before sharing.
