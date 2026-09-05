# `.agents/` — Cold-Start Map for LLM Agents

**Purpose:** This index is the FIRST file any LLM agent must read before touching this repository. It maps the Multi-Agent System (MAS) used to safely modify VisionRemotePS5.

**Repository reality this MAS protects:**
- Native PS5 Remote Play streaming on visionOS — real-time, 120Hz input, sub-frame A/V sync.
- Hand-merged static library `libchiaki_full.a` (OpenSSL + mbedTLS + opus + custom rebuilds).
- Manual C ABI offsets (`1552`/`1560`/`1568`) that cannot be derived from headers.
- Vendored upstream sources (`chiaki-ng/`, `mbedtls-src/`, `opus-build/`) — read-only.

---

## Agents (who has authority over what)

| File | Owns | NEVER touches |
|---|---|---|
| `agents/swift-visionos-engineer.md` | `VisionRemotePS5/Views/`, `Models/`, `Services/` (excluding Chiaki bridge), `VisionRemotePS5App.swift` | `Chiaki/`, `Streaming/`, `Frameworks/`, vendored dirs |
| `agents/streaming-pipeline-engineer.md` | `VisionRemotePS5/Streaming/`, `Shaders/`, `Controllers/HighFrequencyInputController.swift` | C bridge, build scripts, vendored dirs |
| `agents/c-bridge-guardian.md` | `VisionRemotePS5/Chiaki/*` (ChiakiCore.c, ChiakiBridge.swift, MbedtlsCore.c, headers) | Swift UI, vendored dirs |
| `agents/build-script-maintainer.md` | `scripts/*.sh`, `scripts/*.py` | Source code, agent files |

---

## Skills (codebase-specific guardrails — referenced by agents)

| File | Protects | Severity if violated |
|---|---|---|
| `skills/chiaki-abi-shim/SKILL.md` | Manual offsets 1552/1560/1568 in `ChiakiCore.c` | **Critical — stream corruption** |
| `skills/opus-define-ordering/SKILL.md` | `#define CHIAKI_LIB_ENABLE_OPUS 1` before header includes | **Critical — memory corruption** |
| `skills/vendored-deps-readonly/SKILL.md` | `chiaki-ng/`, `mbedtls-src/`, `opus-build/` are read-only mirrors | **Critical — supply chain break** |
| `skills/prebuilt-xcframework-immutable/SKILL.md` | `Frameworks/Chiaki.xcframework/**` and `.orig`/`.backup` files | **Critical — non-reproducible** |
| `skills/vision-pro-display-rate/SKILL.md` | 90Hz Vision Pro display gating (`#if os(visionOS)`) | **High — A/V desync** |
| `skills/monotonic-clock/SKILL.md` | `CACurrentMediaTime()` only, never `CFAbsoluteTimeGetCurrent()` | **High — NTP drift bug** |
| `skills/direct-stereo-audio/SKILL.md` | `spatialAudioEnabled = false` default, HRTF bypass | **High — audio regression** |
| `skills/aces-filmic-tonemap/SKILL.md` | ACES current, Reinhard preserved as legacy fallback | **Medium — color regression** |
| `skills/120hz-input-loop/SKILL.md` | `onInputReady` wiring, `weak self`, off-MainActor | **Medium — input lag regression** |
| `skills/buffer-pool-recovery/SKILL.md` | `markForRecovery()` + 1Hz debounce on buffer exhaustion | **Medium — visual smearing** |

---

## Teams (delegation rules)

| File | Purpose |
|---|---|
| `teams/streaming-core.md` | Cross-agent boundaries, escalation paths, anti-deadlock rules |

---

## Loading Protocol (mandatory for every new agent session)

1. Read this `INDEX.md` first.
2. Read `teams/streaming-core.md` to understand boundaries.
3. Identify which agent file applies to the task (only ONE agent owns any given file).
4. Read that agent's `.md` file in full.
5. Read every skill file the agent's frontmatter lists as `required_skills:`.
6. Only then begin work.

If a task crosses agent boundaries, STOP and read `teams/streaming-core.md` for the delegation rule. NEVER attempt cross-boundary work without consulting it — bystander effects and ping-pong delegation are the #1 failure mode of this MAS.

---

## Status Legend (used in agent/skill frontmatter)

- `status: enforced` — guardrail is active; violations are bugs.
- `status: advisory` — best-practice; document any deviation.
- `status: deprecated` — file kept for history; do not consult for active work.

---

## Note on Ownership Verification

Agent `owns:` frontmatter uses glob patterns (`**`, `Services/**`, etc.). When verifying that every file has an owner, you MUST expand globs — a basename-only `grep` against this directory will produce false-positive "unclaimed" hits for files that ARE covered by a parent glob (e.g., `Models/Console.swift` is owned via `VisionRemotePS5/Models/**`).

The genuinely unclaimed paths (those with NO agent owner, even after glob expansion) are listed exhaustively in `teams/streaming-core.md` under "Unclaimed Files". That list is the authoritative source.
