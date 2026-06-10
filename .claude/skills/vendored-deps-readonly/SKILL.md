---
name: vendored-deps-readonly
description: Guardrail marking chiaki-ng/, mbedtls-src/, and opus-build/opus-1.5.2/ as read-only vendored upstream sources. Load before any edit, grep-driven fix, or refactor that touches C sources — if a search hit lands inside those trees, this skill explains why you must not edit it. Severity critical — editing vendored trees breaks the supply chain.
user-invocable: false
---

# Vendored Dependencies Are Read-Only

**Status:** enforced | **Severity:** critical — supply chain break
**Applies to:** `chiaki-ng/**`, `mbedtls-src/**`, `opus-build/opus-1.5.2/**`
**Evidence:** `.gitignore:34-37` (vendored dirs explicitly gitignored), `scripts/build_chiaki_visionos.sh:21-25` (paths reading from vendored trees), `scripts/rebuild_video_modules.sh:41-45` (cross-references mbedtls-src AND chiaki-ng/third-party/mbedtls)

## Reality

The directories `chiaki-ng/`, `mbedtls-src/`, and `opus-build/opus-1.5.2/` are **vendored upstream sources**. They are:
- Listed in `.gitignore` (`.gitignore:34-37`) — they are NOT tracked in git.
- Read by build scripts, never written.
- Expected to mirror upstream releases verbatim.

The build pipeline (`scripts/build_chiaki_visionos.sh`, `scripts/rebuild_video_modules.sh`, `scripts/build_opus_visionos.sh`) compiles selected sources from these trees and emits artifacts into separate build directories (e.g., `chiaki-ng/build-visionos-minimal/`, `opus-build/build-visionos/`).

## Why an LLM will break this

When an LLM is asked to "fix a bug in the C code" or "add logging to the network layer", and grep returns a hit inside `chiaki-ng/lib/src/...` or `mbedtls-src/library/...`, the LLM will reflexively edit those files. It will treat the vendored tree as project source. This:

1. Diverges the local copy from upstream — future `git pull` of upstream (or re-vendoring) overwrites the change silently.
2. Bypasses the `Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a` static archive (which the Xcode project actually links). Edits to vendored sources only matter if `scripts/rebuild_video_modules.sh` or `scripts/merge_chiaki_opus.sh` is then re-run.
3. Confuses code review: nothing in git diff shows the change.

## Hard rules

You MUST NEVER:

1. Write, edit, delete, or rename any file under `chiaki-ng/`, `mbedtls-src/`, or `opus-build/opus-1.5.2/`. This includes:
   - Source files (`.c`, `.h`, `.cpp`).
   - Build files (`CMakeLists.txt`, `Makefile`, `meson.build`).
   - Documentation, even READMEs.
   - `.git`, `.github`, `.gitmodules` inside those trees.
2. Run `git apply`, `patch`, `sed -i`, `awk -i inplace`, or any in-place mutation against files in those directories.
3. Suggest "vendoring a fix" by editing locally — if upstream is broken, the user must vendor a pre-patched mirror separately and re-vendor.
4. Add files under those paths (e.g., a new `chiaki-ng/build-experimental/`).
5. Move files from a vendored tree into `VisionRemotePS5/`. If a source file is needed in-tree, copy it AND rename it to make the local provenance explicit (e.g., `VisionRemotePS5/Chiaki/MbedtlsCore.c` is a project-local file, not the upstream one).

You MAY:

- Read files in those trees for context (`Read` tool, `grep`).
- Reference paths in build script flags (e.g., `-I$CHIAKI_DIR/lib/include`).
- Compile sources from those trees by running existing build scripts.

## Source vs. Build-Output Distinction (clarification of rule 4)

Rule 4 above forbids ADDING files to vendored trees. The **existing** build subdirectories — listed below — are write-allowed TARGETS for the existing build scripts (not source paths). They get auto-created and overwritten by the scripts; do not hand-edit their contents.

Write-allowed build outputs (existing scripts already populate these):

- `chiaki-ng/build-visionos/`         — created by `scripts/build_chiaki_core.sh`.
- `chiaki-ng/build-visionos-minimal/` — created by `scripts/build_chiaki_visionos.sh`.
- `chiaki-ng/build-visionos-xcframework/` — referenced by `scripts/merge_chiaki_opus.sh`.
- `chiaki-ng/build-output/`           — copy target in `build_chiaki_core.sh`.
- `chiaki-ng/opus-enabled-lib/`       — created by `scripts/merge_chiaki_opus.sh`.
- `opus-build/build-visionos/`        — created by `scripts/build_opus_visionos.sh`.
- `opus-build/output/`                — copy target in `build_opus_visionos.sh`.

**NEW build directories** under those vendored trees (e.g., `chiaki-ng/build-experimental/`) STILL require explicit user authorization — do not invent new build-output paths. The above list is exhaustive; if a script change would add another, it must be coordinated with the user via the `build-script-maintainer` agent.

The SOURCE subtrees (`chiaki-ng/lib/`, `chiaki-ng/third-party/`, `mbedtls-src/library/`, `mbedtls-src/include/`, `opus-build/opus-1.5.2/`, etc.) remain strictly read-only per all rules above.

## How to handle an "upstream bug"

If during work you find a bug in vendored code:

```
STOP. Output:
  UPSTREAM_BUG: <file>:<line> — <one-line description>.
  This file is in a read-only vendored tree (.claude/skills/vendored-deps-readonly).
  The fix must be applied upstream and re-vendored. Not editing in place.
```

Then suggest, but do not perform, a workaround in PROJECT-OWNED code (e.g., a wrapper in `VisionRemotePS5/Chiaki/`).

## Distinction: project-local Chiaki/mbedTLS files

The following files are PROJECT-LOCAL and ARE editable (subject to other skills):

- `VisionRemotePS5/Chiaki/ChiakiCore.c` — project wrapper around chiaki C ABI.
- `VisionRemotePS5/Chiaki/ChiakiCore.h` — project header.
- `VisionRemotePS5/Chiaki/MbedtlsCore.c` — project mbedTLS shim.
- `VisionRemotePS5/Chiaki/mbedtls_config.h` — project mbedTLS config.
- `VisionRemotePS5/Chiaki/VisionRemotePS5-Bridging-Header.h` — Swift bridging header.

These belong to the `c-bridge-guardian` agent. They are not vendored.
