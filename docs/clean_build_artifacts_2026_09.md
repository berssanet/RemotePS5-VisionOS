# Isolated clean-build artifacts — 2026-09-07

Task 00.05 found and fixed a dependency on an ignored checkout: `ChiakiCore.c`
includes `curl/curl.h`, but both build configurations searched
`chiaki-ng/third-party/curl/include`. A clean checkout lacked that directory.
The fixed Release app builds successfully using only repository inputs, a copy
of the configuration template, and the installed Xcode SDK.

## Change and validation environment

- Base: `cc7e91164a37e6bc7319844148b13ce44e461490`, branch
  `docs/active-streaming-paths`. The prior path-map document was already untracked
  in the working tree and was not included in the isolated source.
- Mac: macOS 26.6.2 (`25G83`); Xcode 27.0 (`27A5252f`), SDK `xros27.0`.
- Added 12 public curl headers, unmodified, plus `COPYING`, from the local curl
  submodule's pinned revision `b1ef0e1a01c0bb6ee5367bd9c186a603bde3615a`.
  Exported committed Git content and verified equality with the previously used
  headers. [Provenance and verification](../VisionRemotePS5/ThirdParty/curl/README.md)
  records the exact version string and checksums.
- Changed only the curl header search path in Debug and Release to
  `$(SRCROOT)/VisionRemotePS5/ThirdParty/curl/include`.
- No native library, ABI declaration, C/Swift runtime code, or minimum OS change.

## Isolated build procedure and results

A local clone was created with `git clone --no-hardlinks --no-checkout`, then
checked out at the full base revision in detached HEAD. Confirmed the absence
of `Local.xcconfig`, `.env`, `chiaki-ng`, `mbedtls-src`, `opus-build`, `build`,
and `TODO.md`. Only `Local.xcconfig.example` was copied to `Local.xcconfig`;
no credentials were copied from the working project.

The first sandboxed build failed to run SwiftUI macros. An approved build outside
the sandbox then identified the actual missing dependency:
`ChiakiCore.c:30:10: error: 'curl/curl.h' file not found`.

Applied only the new curl directory and project-file change to that isolated
checkout, then built with a new DerivedData directory. From the isolated source:

```sh
cp -n Local.xcconfig.example Local.xcconfig
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project VisionRemotePS5.xcodeproj -scheme VisionRemotePS5 \
  -configuration Release -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/VisionRemotePS5-clean-release \
  CODE_SIGNING_ALLOWED=NO build
```

Result: exit 0, `BUILD SUCCEEDED`, no `warning:` or `error:` diagnostics in the
successful log. The generated `ChiakiCore.d` lists curl dependencies exclusively
inside the isolated `VisionRemotePS5/ThirdParty/curl` directory.
The built app reports `DTSDKName=xros27.0`, `MinimumOSVersion=2.0`, version 1.0.0
(1). Its bundled `cacert.pem` matches the repository copy byte-for-byte.

Actual evidence directory: `/tmp/VisionRemotePS5-clean-0005-85w7dri6/`:

- `source/`: detached base plus the reviewed header/project changes and template.
- `build.log`: initial sandbox failure.
- `build-unsandboxed.log`: missing curl header reproduction.
- `build-fixed.log`: successful build using fresh `DerivedData-fixed/`.
- `artifacts-before.json`: per-file SHA-256 manifest for all 149 original
  framework/header/certificate files, checked again after the build against both
  isolated and working trees; all unchanged.

## Artifact inventory

Paths below are relative to `VisionRemotePS5/`.

| Artifact | Role / platform |
|---|---|
| `Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a` | Linked native stack; arm64 archive |
| `Frameworks/json-c/libjson-c.a` | Linked JSON dependency; arm64 archive |
| `Frameworks/Chiaki.xcframework/Info.plist` | Declares a single xros arm64 device slice, no simulator slice |
| `Frameworks/Chiaki.xcframework/xros-arm64/Headers/` | 142 tracked Chiaki/mbedTLS/PSA headers |
| `ThirdParty/curl/include/curl/` | 12 public headers needed by the C bridge; checksums alongside COPYING |
| `Resources/cacert.pem` | Bundled trust certificates for native TLS |
| `libchiaki_full.a.orig`, `.backup`, `.backup_no_opus` beside the linked archive | Preserved maintenance inputs, not app link inputs |

Recorded SHA-256 values (full paths relative to the repository):

```text
998f13263907f63e83f124b440d7f9b21df78e7938185c15e1a9862d8fc753e5  VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a
164b68dd529a4997300f4bbec4c0c995ec2dc9c3fd2ee23a3f10f6d46b5545be  VisionRemotePS5/Frameworks/json-c/libjson-c.a
288e6f440e0cc7c2bc6544038ddf05500e7e0760bf3a3f33e83451ad350d7c8f  VisionRemotePS5/Frameworks/Chiaki.xcframework/Info.plist
7c4c97b090fed937cf68fa406ed87d87b75e9250888fb27373d759ac6beb1ffc  VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a.orig
7c4c97b090fed937cf68fa406ed87d87b75e9250888fb27373d759ac6beb1ffc  VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a.backup
003022196c654ab730847800ec52296654d8f562e3fdb6cf7ce340aa8df3dd83  VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a.backup_no_opus
89c5ceed25fc6dbb5c75aa66743b6f04e037fd70432b3a821c4229f568b704e7  VisionRemotePS5/Resources/cacert.pem
```

The 142 original headers' manifest digest is
`a08e092962df428a36b4589ca8df49b6fe0c19c2add0ebe17c5730364fa20554`:
SHA-256 of UTF-8 lines `FILE_SHA256` + two spaces + repository-relative path +
newline, sorted lexicographically by path. The new curl files have a separate
checked-in [SHA256SUMS](../VisionRemotePS5/ThirdParty/curl/SHA256SUMS).

## Remaining prerequisites and limits

`Local.xcconfig` remains an intentional setup step. Placeholders suffice for
compilation, but not PSN login. Device installation requires signing; this
unsigned Release build was not installed or run. The SDK 27 signed installation
record applies to the earlier task's artifact.

No model package or ignored native source checkout was needed by the app build.
Some maintenance/host-test scripts still require vendored source revisions;
their execution is covered by tasks 00.06/00.07, not this result. This is a clean
app compilation with shipped native binaries, not a reproducible source rebuild
of those binaries or proof of their complete provenance. The later dedicated
Release and device regression gates remain separate tasks.
