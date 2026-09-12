# Release build — 2026-09-07

Task 00.08 passed: the current project built Release for a physical visionOS
target with Xcode 27. No code, build-setting, or native-library changes were
needed in this task.

## Environment and command

- Revision: `059a71c`, branch `docs/active-streaming-paths`.
- Preexisting untracked file: `docs/input_transport_regressions_2026_09.md`;
  preserved. The local ignored TODO is not a build input.
- Host: macOS 26.6.2 (`25G83`), Apple M3 Pro MacBook Pro.
- Xcode 27.0 (`27A5252f`), SDK `xros27.0`.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project VisionRemotePS5.xcodeproj -scheme VisionRemotePS5 \
  -configuration Release -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/VisionRemotePS5-immersive-build \
  CODE_SIGNING_ALLOWED=NO build
```

Executed outside the sandbox with approval because the earlier clean-build
verification established that SwiftUI macro execution is blocked inside it.
This run used the working project's existing local configuration; the separate
[isolated build](clean_build_artifacts_2026_09.md) tested template-only setup.

## Results and evidence

- Exit 0, `BUILD SUCCEEDED`.
- No compiler/linker `warning:` or `error:` diagnostics in the build log, matching
  the successful task 00.05 build. The task 00.07 host-test warning from Chiaki
  `log.c` is not emitted by this app build, which links the precompiled archive.
- Log: `/tmp/VisionRemotePS5-0008-release.log`.
- Artifact: `/tmp/VisionRemotePS5-immersive-build/Build/Products/Release-xros/VisionRemotePS5.app`.
- Executable: Mach-O arm64; version 1.0.0 (1).
- Built Info.plist: `DTSDKName=xros27.0`, `DTXcodeBuild=27A5252f`,
  `MinimumOSVersion=2.0`.
- Executable SHA-256:
  `1492d60712b2f7d0d636b04a50a99665c90b0cc90fd8baf29bed7914edeee62f`.
- Bundled TLS certificate matches the repository copy byte-for-byte. The linked
  Chiaki and json-c archives retain the task 00.05 SHA-256 values.
- `git diff --check` passed after recording the result.

The artifact is unsigned and was not installed or run. Temporary build outputs
and logs can be replaced by future runs and are not committed. No credentials
or local configuration values are reproduced in this record. Physical video,
audio, rumble, controller reconnection, and session reconnection validation
remain task 00.09; compilation does not satisfy those checks.
