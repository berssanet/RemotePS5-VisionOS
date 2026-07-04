# User Preferences

## Language
- Think internally in concise English. Respond to the user in English.
- Code, identifiers, comments, commits, log strings, and internal technical notes stay in English.
- User-facing UI text: English (visionOS international app).
- Do NOT switch to Portuguese unless the user explicitly issues `/lang pt-br` in the current message.
- Rationale: prior cross-LLM language drift between `CLAUDE.md` and `GEMINI.md` produced inconsistent commit messages and review confusion. Both files now enforce English.

## Workflow (what diverges from defaults)
- Target 200–300 line Swift files; justify going over 500.
- Target 4–20 logical-line functions.
- Avoid vague names: `data`, `manager`, `helper`, `util`, `process` — prefer grep-friendly specifics.
- Explicit types on every public API signature (`func`, `var`, initializers). Infer types for local `let`/`var` only when the RHS makes the type unambiguous.
- Warnings = failures. `xcodebuild` MUST produce zero warnings on every commit. Treat deprecation warnings as blocking.
- Indentation: 4 spaces in Swift, 2 spaces in C (`ChiakiCore.c`). Brace placement: same line.
- Match existing file style before applying defaults — read the file before editing.
- No new dependencies without explicit user approval. The project is intentionally minimalist.
- No emojis in code or commit messages unless the file already contains them (preserve existing, do not add new).
- Treat `TODO.md` as authoritative for project state. Phases marked ✅ are closed; phases marked ⏳ are pending.

## Default context
VisionRemotePS5 — native PS5 Remote Play streaming on Apple Vision Pro. The stack:

- **Languages:** Swift (UI, services, streaming pipeline), Objective-C/C (Chiaki bridge, mbedTLS), Metal Shaders (rendering, upscaling, tonemapping).
- **Platform:** visionOS 2.0+, Xcode, SwiftUI + RealityKit, 90Hz Vision Pro display, 120Hz input loop.
- **Core dependency:** `libchiaki_full.a` — hand-merged static library (OpenSSL + mbedTLS + opus + custom rebuilds) inside `Frameworks/Chiaki.xcframework`.
- **Architecture:** Multi-Agent System (`.agents/`) governs all autonomous work. See mandatory bootstrap below.

### Mandatory bootstrap (read before ANY work)
This repository has an `.agents/` MAS architecture. You MUST read, in order:
1. `.agents/INDEX.md` — cold-start map for all agents, skills, and teams.
2. `.agents/teams/streaming-core.md` — boundary map and anti-deadlock rules.
3. The single agent file under `.agents/agents/` that owns the file you are about to touch.
4. Every skill file listed in that agent's `required_skills:` frontmatter.

If the file you intend to modify is owned by a different agent than the one you would naturally adopt, STOP. Output `OUT_OF_SCOPE: <path> belongs to <agent-name>. Halting per .agents/INDEX.md loading protocol.` Do NOT proceed.

### Cardinal directives (unbreakable rules)

**1. File Integrity & Large Context:**
- When receiving a file, assume it may be truncated. State if incomplete and ask for the rest.
- NEVER remove, summarize, or replace parts of original code with comments (e.g., `// ... rest of your code here ...`), unless explicitly instructed.
- If a file is too large to process at once, propose a plan to work on specific sections, ensuring final cohesion.

**2. Stability & Non-Regression:**
- Primary goal: NEVER break existing functionality. All changes must preserve the project's stability.

**3. Untouchable Tech Debt — Chiaki C ABI Bridge:**
The file `VisionRemotePS5/Chiaki/ChiakiCore.c` uses MANUAL struct offsets (`1552`, `1560`, `1568`, contrasted with header-derived `608`) to set callbacks against the upstream `ChiakiSession`. The library was compiled with `CHIAKI_LIB_ENABLE_OPUS=1` (4512-byte struct), and public headers do NOT match this layout. You MUST NEVER:
- Replace offset arithmetic with struct field access (`session->video_sample_cb = ...`).
- Remove the runtime size-check via `chiaki_get_struct_sizes()`, the `_safe()` wrapper functions, or the `[ChiakiCore] DEBUG ABI:` `fprintf` lines.
- Migrate Swift callers to `chiaki_session_set_video_callback_safe()` / `..._audio_sink_safe()` / `..._event_callback_safe()` without explicit user authorization.
- Reorder `#define CHIAKI_LIB_ENABLE_OPUS 1` (`ChiakiCore.c:14`) — it MUST precede ALL chiaki header includes. Wrapping it in `#ifndef` is also forbidden.
- Full guardrails: `.agents/skills/chiaki-abi-shim/SKILL.md` and `.agents/skills/opus-define-ordering/SKILL.md`.

**4. Untouchable Tech Debt — Vendored Trees & Prebuilt Library:**
The directories `chiaki-ng/`, `mbedtls-src/`, and `opus-build/opus-1.5.2/` are gitignored read-only vendored upstream sources. The library `Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a` is hand-merged via `scripts/merge_chiaki_opus.sh`; adjacent `.orig` and `.backup` files are sacred. You MUST NEVER:
- Edit, delete, rename, or `sed -i` any file under those vendored directories.
- Modify `libchiaki_full.a`, `libchiaki_full.a.orig`, or `libchiaki_full.a.backup` directly.
- Hand-edit any `Info.plist` inside the xcframework.
- Run `xcodebuild -create-xcframework` against the build outputs — the merged library is reproducible only via `scripts/merge_chiaki_opus.sh`.
- Full guardrails: `.agents/skills/vendored-deps-readonly/SKILL.md` and `.agents/skills/prebuilt-xcframework-immutable/SKILL.md`.

**5. Scoped codebase access:**
- Deeply analyze ONLY first-party code under `VisionRemotePS5/`, `VisionRemotePS5Tests/`, and `scripts/`.
- The vendored directories are READ-ONLY — read for context, NEVER propose edits, reformatting, or refactors.
- If a fix appears to require an upstream change, stop and surface it as `UPSTREAM_BUG: <file>:<line> — <description>`.

## When uncertain
- Pick the simpler approach.
- Never invent APIs — read the code or docs first.
- Ask before acting when the blast radius is wide, the requirement is ambiguous, or multiple valid paths exist.
- When in doubt about file ownership, read `.agents/INDEX.md` and the relevant agent file BEFORE touching anything.

## Git / commits
- Never add `Co-Authored-By: Claude ...` (or any other AI-assistant attribution) to commit messages, PR descriptions, or tags. Author them as if written solely by the user.
- The same rule applies to `🤖 Generated with …` footers and equivalent markers — omit them.
- Commit messages: imperative mood, 50-char subject line, blank line, then body if needed.
- No force-pushes to `main`. Feature branches for non-trivial changes.

## Xcode / Swift quality gate (reusable across visionOS projects)

Every visionOS project should ship with a `scripts/quality-check.sh` that wraps the tools below. Modes: `--ci` (exact gate CI runs, blocking) / `--full` (adds slower informational checks) / `--fix` (autofix what's autofixable).

### Blocking gate (runs in `--ci`)

**Build correctness:**
- `xcodebuild build -scheme VisionRemotePS5 -destination 'generic/platform=xrOS' -quiet` — zero errors, zero warnings.
- Unit tests: `xcodebuild test -scheme VisionRemotePS5 -destination 'platform=xrOS Simulator,name=Apple Vision Pro'` — all tests pass.

**Static analysis:**
- SwiftLint (when adopted): `swiftlint lint --strict --config .swiftlint.yml` — zero violations. (Not currently present; recommended for future adoption.)
- Xcode Analyze: `xcodebuild analyze -scheme VisionRemotePS5 -destination 'generic/platform=xrOS' -quiet` — zero analyzer warnings.

**Complexity & duplication** (the two most-forgotten gates):
- `lizard VisionRemotePS5/ -l swift -C 25 -w` — per-function cyclomatic complexity. Exits non-zero if any function exceeds CCN 25. On legacy code start at the current max, tighten by 5 each refactor. Install: `pipx install lizard`.
- `jscpd --min-lines 50 --min-tokens 100 --threshold 5 --reporters console --silent VisionRemotePS5/` — duplicate-code detector. Fails if >5% of code is copy-paste in blocks ≥50 lines / ≥100 tokens. Install: `npm install -g jscpd`.

### Informational (`--full` only — slower, noisier)

- `typos VisionRemotePS5/` — spellcheck comments + strings. Install: `cargo install typos-cli`.
- `scc VisionRemotePS5/ --by-file --sort complexity` — LOC + CC summary per file (complements lizard's per-function view).
- `xcrun swift-demangle` on crash logs for symbolication verification.

### Project-specific lints

Add custom scripts for domain concerns that standard lints can't express — and register them in `quality-check.sh` alongside the generic gates. Examples relevant to this project:
- `lint-monotonic-clock.sh` — verifies no `CFAbsoluteTimeGetCurrent()` usage in the streaming pipeline. Only `CACurrentMediaTime()` is permitted.
- `lint-abi-shim.sh` — verifies `ChiakiCore.c` still uses offset-based callbacks, not struct field access.
- `lint-opus-define.sh` — verifies `#define CHIAKI_LIB_ENABLE_OPUS 1` precedes all chiaki header includes.

### One-liner install (fresh dev box)

```bash
pipx install lizard
npm install -g jscpd
cargo install typos-cli
# SwiftLint (when adopted): brew install swiftlint
```

## Security invariants

### Network input validation
- All data received from the PS5 stream (video samples, audio buffers, controller feedback) passes through the Chiaki C bridge. NEVER trust raw buffer sizes — validate against expected frame dimensions and sample rates before processing.
- Session tokens and PSN credentials: NEVER log, NEVER hardcode, NEVER commit to source. Use Keychain Services for credential storage.

### Vendored dependency integrity
- `libchiaki_full.a` is the ONLY trusted binary. Its provenance is `scripts/merge_chiaki_opus.sh` from `.orig` files.
- NEVER download or substitute pre-built binaries from external sources.
- If a CVE is found in a vendored dependency (OpenSSL, mbedTLS, opus), escalate — do NOT patch the vendored tree in-place. The rebuild must go through `build-script-maintainer`.

### Secrets management
- `.gitignore` MUST exclude any `*.pem`, `*.p12`, `*.key`, `*.mobileprovision` files.
- NEVER commit Xcode signing identities or provisioning profiles.
- API keys and PSN client IDs: environment variables or Xcode build settings, NEVER inline strings.

### Threat model summary
The primary untrusted input surfaces are:
1. **PS5 network stream** — video/audio/haptic data over encrypted Chiaki session. Gate: C bridge validates frame sizes; Swift decoders validate NAL unit boundaries.
2. **PSN OAuth flow** — network responses from Sony servers. Gate: HTTPS-only, certificate pinning via ATS defaults.
3. **mDNS discovery** — console announcements on local network. Gate: validate hostname length and character set before display.

## Pre-commit / CI integration

### Pre-commit hook (optional)

`.pre-commit-config.yaml` with:
- `xcodebuild build` (zero warnings)
- `typos VisionRemotePS5/` (spellcheck)
- Custom lint scripts (`lint-monotonic-clock.sh`, `lint-abi-shim.sh`, `lint-opus-define.sh`)

Installed via `pip install pre-commit && pre-commit install`. CI already catches everything this would; the hook is just faster feedback.

### CI workflow (GitHub Actions)

- **`ci.yml`** — quality gate: build, analyze, test, lizard, jscpd, custom lints.
- **`security.yml`** — `gitleaks/gitleaks-action@v2` with `fetch-depth: 0` for full-history secret scan.
- **`dependabot.yml`** — weekly github-actions updates (no package manager dependencies to track — vendored library).