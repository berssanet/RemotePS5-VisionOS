---
name: prebuilt-xcframework-immutable
description: Guardrail for Frameworks/Chiaki.xcframework — the hand-merged libchiaki_full.a and its .orig/.backup siblings are immutable except via scripts/merge_chiaki_opus.sh. Load before touching anything under VisionRemotePS5/Frameworks/ or proposing library regeneration/cleanup. Severity critical — violating it produces a non-reproducible or non-linking build.
user-invocable: false
---

# Prebuilt XCFramework Is Immutable Except via Build Scripts

**Status:** enforced | **Severity:** critical — non-reproducible build
**Applies to:** `VisionRemotePS5/Frameworks/Chiaki.xcframework/**`, `VisionRemotePS5/Frameworks/Chiaki.xcframework.compiled/**`
**Evidence:** `scripts/merge_chiaki_opus.sh:7-29` (path resolution + .orig restoration logic), `scripts/rebuild_video_modules.sh:54-58` (backup creation pattern)

## Reality

`VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a` is a **hand-merged** static archive containing:

- Original chiaki object files (compiled with OpenSSL, ~3.4 MB).
- `libopus.a` object files.
- Custom-rebuilt `videoreceiver.o` and `frameprocessor.o` (re-targeted to `xros2.0`).
- `opusdecoder.o` and `opusencoder.o` from chiaki's OPUS-enabled build.

Adjacent files that MUST exist for the build pipeline to work:

- `libchiaki_full.a.orig` — the OpenSSL-bearing original library, source of truth for `merge_chiaki_opus.sh`.
- `libchiaki_full.a.backup` — secondary fallback used by `merge_chiaki_opus.sh:23-24` if `.orig` is missing.

The Xcode project links against `libchiaki_full.a`. The two adjacent files are not linked but are READ at build time.

## Hallucination vector

An LLM seeing a `Frameworks/` directory with `.a`, `.a.orig`, and `.a.backup` files will:
1. "Clean up" the `.orig` and `.backup` files as "duplicates".
2. Run `xcodebuild -create-xcframework` to "regenerate properly" — but the source bundles to recreate it are not in-repo.
3. Replace `libchiaki_full.a` with the smaller `libchiaki.a` produced by `build_chiaki_core.sh` (275 KB minimal, no OpenSSL, no OPUS).
4. Hand-edit `Info.plist` inside the xcframework to "fix" the architecture identifiers.

ANY of these breaks the link step or silently produces a build that fails to register a session.

## Hard rules

You MUST NEVER:

1. Delete or rename `libchiaki_full.a.orig` or `libchiaki_full.a.backup`.
2. Hand-edit `libchiaki_full.a` (it is binary; no edit tool should ever touch it).
3. Hand-edit `Frameworks/Chiaki.xcframework/Info.plist` or `Frameworks/Chiaki.xcframework.compiled/Info.plist`.
4. Replace `libchiaki_full.a` with the output of `build_chiaki_core.sh` (`chiaki-ng/build-output/libchiaki.a`) or `build_chiaki_visionos.sh` (`chiaki-ng/build-visionos-minimal/libchiaki-core.a`). They are different libraries and the Xcode project depends on the merged one.
5. Delete `Frameworks/Chiaki.xcframework.compiled/` without confirming the Xcode project's framework search paths first.
6. `git add -f Frameworks/**/*.a*` to force-track the binaries unless explicitly authorized — they are intentionally local.
7. Run `xcodebuild -create-xcframework` against `chiaki-ng/build-*/` outputs. The merged library cannot be reproduced this way; only `scripts/merge_chiaki_opus.sh` produces it.

You MUST:

- To regenerate `libchiaki_full.a`, hand off to the `build-script-maintainer` agent and run `scripts/merge_chiaki_opus.sh`.
- To regenerate just `videoreceiver.o` / `frameprocessor.o` inside the existing library, hand off to the `build-script-maintainer` agent and run `scripts/rebuild_video_modules.sh` (which backs up to `.orig` first if not already present).
- If `.orig` is somehow lost, STOP. Do not attempt to recreate it. Surface as: `BUILD_PIPELINE_BREAK: libchiaki_full.a.orig is missing — required as OpenSSL-bearing source for merge_chiaki_opus.sh. Cannot proceed.`

## Recovery

If `libchiaki_full.a` is corrupted but `.orig` exists:
- `cp libchiaki_full.a.orig libchiaki_full.a` then re-run `scripts/merge_chiaki_opus.sh`.

If both are gone:
- The library is unrecoverable from this repo. The user must restore from a backup or rebuild from a clean `chiaki-ng` clone with OpenSSL toolchain.
