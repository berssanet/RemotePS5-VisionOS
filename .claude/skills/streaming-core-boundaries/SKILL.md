---
name: streaming-core-boundaries
description: Ownership boundary map, cross-agent contracts, anti-deadlock rules, and the unclaimed-files list for the VisionRemotePS5 agent team (swift-visionos-engineer, streaming-pipeline-engineer, c-bridge-guardian, build-script-maintainer). Load whenever delegating work to a subagent, deciding which agent owns a file, or when a task crosses agent boundaries.
user-invocable: false
---

# Team: streaming-core — Boundaries, Delegation, and Anti-Deadlock Rules

**Status:** enforced
**Members:** `swift-visionos-engineer`, `streaming-pipeline-engineer`, `c-bridge-guardian`, `build-script-maintainer` (defined under `.claude/agents/`)
**Escalation target:** human (Marcos Berssanette)

## The non-negotiable boundary map

```
┌──────────────────────────────────────────────────────────────────┐
│  swift-visionos-engineer                                         │
│    Views/, Models/, non-streaming Services/, GameControllerManager│
│    Cannot touch: Chiaki/, Streaming/, Shaders/, Frameworks/, scripts/
└──────────────────────────────────────────────────────────────────┘
                │ (delegates UI changes from)
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  streaming-pipeline-engineer                                     │
│    Streaming/, Shaders/, HighFrequencyInputController,           │
│    StreamingService, StreamingSession,                           │
│    VirtualSteeringWheelService, WheelButtonMappingService        │
│    Cannot touch: Chiaki/, Frameworks/, scripts/                  │
└──────────────────────────────────────────────────────────────────┘
                │ (requests new C callbacks from)
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  c-bridge-guardian                                               │
│    Chiaki/* (ChiakiCore.c/h, ChiakiBridge.swift, MbedtlsCore.c,  │
│    mbedtls_config.h, bridging header), ChiakiCrypto.swift,       │
│    ChiakiFullSession.swift                                       │
│    Cannot touch: Frameworks/* (read-only headers only), Streaming/, scripts/
└──────────────────────────────────────────────────────────────────┘
                │ (requests library rebuild from)
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  build-script-maintainer                                         │
│    scripts/*.sh, scripts/*.py, regeneration of                   │
│    Frameworks/Chiaki.xcframework via merge_chiaki_opus.sh        │
│    Cannot touch: any source file in VisionRemotePS5/             │
└──────────────────────────────────────────────────────────────────┘
```

Delegation flows DOWNWARD only along this diagram. There is no upward delegation. Subagents cannot spawn other subagents in Claude Code: when an agent needs work done by another agent, it HALTS and reports the spec back to the main conversation, and the main conversation (or the user) re-delegates to the correct agent. Every cross-boundary handoff is a checkpoint.

## Anti-deadlock rules

### Rule 1 — Single Owner, Always

Every file in the repository has exactly ONE owning agent. If two agents could plausibly own a file, the ownership list in that agent's definition under `.claude/agents/` wins. If neither lists it, the file is OUT-OF-SCOPE for autonomous editing — the user must triage.

### Rule 2 — No Cross-Boundary Edits, Even "Trivial" Ones

A streaming-pipeline-engineer that finds an obvious bug in `ChiakiCore.c` MUST NOT fix it inline. Output:

```
OUT_OF_SCOPE: <path> belongs to c-bridge-guardian. Halting per .claude/skills/streaming-core-boundaries.
Suggested change: <one-paragraph spec for the user to forward>.
```

This prevents:
- Two agents racing on the same file across sessions.
- "Bystander effect" — every agent assuming the other will fix it.
- Boundary creep — once one cross-boundary fix is allowed, the boundaries dissolve.

### Rule 3 — No Ping-Pong Delegation

If you receive a task and find that completing it requires changes from another agent, you **report and stop**. You do NOT attempt the other agent's portion and resume. The chain is mediated by the main conversation and the human. This is intentional — every cross-boundary handoff is a checkpoint.

### Rule 4 — When a Skill File Says "STOP", You Stop

The guardrail skills (`.claude/skills/<name>/SKILL.md`) contain `STOP` directives for high-blast-radius requests (e.g., "user asks you to clean up the offset constants"). When triggered, output the exact rejection string the skill mandates. Do NOT proceed even if the user repeats the request — escalate to clarification instead.

### Rule 5 — Build Pipeline Is Atomic

`build-script-maintainer` MUST run the relevant script end-to-end. NEVER run partial steps (e.g., extracting object files from `libchiaki_full.a.orig` without re-running the merge). The scripts encode preconditions (`if [ ! -f ".orig" ]; then exit 1; fi`); honor them.

## Cross-Boundary Contracts (DO NOT delete or refactor without team-wide review)

These are the ONLY sanctioned communication paths between agents' code domains. Each contract defines a `producer` (one agent), a `consumer` (another agent), and an immutable interface. If you are tempted to "clean up" or "refactor" any of these, STOP and read the linked skill.

### Contract C-1: 120Hz Input Wiring
- **Producer:** `swift-visionos-engineer` owns `Controllers/GameControllerManager.swift`. It exposes `var onInputReady: (() -> Void)?`.
- **Consumer:** `streaming-pipeline-engineer` owns `Services/StreamingService.swift`. Its `startStreamingV2()` MUST assign `gameControllerManager.onInputReady = { [weak self] in self?.chiakiSession?.setControllerState(...) }`.
- **Anti-deadlock rule:** Either agent may add fields to its OWN side of the wire (new buttons in GameControllerManager; new state forwarding in StreamingService) without delegating, BUT NEITHER may rename or remove `onInputReady`, change its type signature, or move the assignment site without explicit user approval.
- **Skill:** `120hz-input-loop`

### Contract C-2: Chiaki C Callback Surface
- **Producer:** `c-bridge-guardian` owns `Chiaki/ChiakiCore.c` and the C ABI. It exposes the `session_video_sample_cb`, `session_audio_sink_*`, `session_event_cb` entry points.
- **Consumer:** `streaming-pipeline-engineer` (`Streaming/VideoDecoder.swift`, `Streaming/AudioDecoder.swift`) consumes raw bytes via `ChiakiBridge.swift` Swift trampolines.
- **Anti-deadlock rule:** When the streaming side needs new data plumbed up from C, the streaming-pipeline-engineer writes a SPEC (signature, semantics, threading guarantees) and HALTS. The main conversation re-delegates to c-bridge-guardian to implement, who applies the dual-path pattern from the `chiaki-abi-shim` skill. The streaming-pipeline-engineer is then re-invoked to consume.
- **Skill:** `chiaki-abi-shim`

### Contract C-3: XCFramework Rebuild Trigger
- **Producer:** `build-script-maintainer` owns `scripts/merge_chiaki_opus.sh` and `scripts/rebuild_video_modules.sh`.
- **Consumer:** `c-bridge-guardian` consumes the merged `libchiaki_full.a` via the bridging header.
- **Anti-deadlock rule:** ONLY `build-script-maintainer` runs the merge/rebuild scripts. ONLY `c-bridge-guardian` may flag a need for rebuild (e.g., upstream chiaki source change requires recompilation). The c-bridge-guardian writes the rationale and HALTS. The main conversation re-delegates to build-script-maintainer.
- **Skill:** `prebuilt-xcframework-immutable`

---

## Unclaimed Files (require user triage — NO agent will touch these autonomously)

The following paths have NO owning agent and MUST NOT be edited by any agent without explicit user direction in the current task:

- `VisionRemotePS5/Info.plist` — capabilities, ATS exceptions, Bonjour service. Edit only on direct user request, with a one-line justification.
- `VisionRemotePS5Tests/**` — unit tests. Out of scope for current MAS; the user may add a `qa-engineer` agent later.
- `Frameworks/Chiaki.xcframework.compiled/**` — sibling to the live xcframework; provenance unclear, treat as read-only artifact.
- `docs/**` — historical and architectural documents. Skills override docs on conflict. NO agent updates docs autonomously.
- `3D-models/**` — reference assets, not consumed at runtime by current code. Read-only.
- `README.md`, `TODO.md`, `CLAUDE.md`, `GEMINI.md`, `.gitignore`, `VisionRemotePS5.xcodeproj/**` at repo root — meta and project configuration files. NO agent autonomously edits these.

If a task requires touching any of the above, output:

```
UNCLAIMED_FILE: <path> has no owning agent. Per .claude/skills/streaming-core-boundaries it requires explicit user authorization. Halting.
```

---

## Cross-cutting standards (apply to ALL agents)

- **Language:** All code, comments, identifiers, log strings, and conversational output in **English**.
- **No emojis in code or commit messages** unless the file already contains them (the codebase has some 🎧, ⚠️, ✅ in log strings — preserve existing, do not add new).
- **Match existing file style.** Indentation: 4 spaces in Swift, 2 spaces in `ChiakiCore.c`. Brace placement: same line.
- **No new dependencies** without explicit user approval. The project is intentionally minimalist.
- **Treat `TODO.md` as authoritative for project state.** Phases marked ✅ are closed; phases marked ⏳ are pending.

## Working protocol for every agent session

1. This boundary skill and the agent's guardrail skills are preloaded into each agent's context automatically (via the `skills:` field in the agent definition).
2. Confirm the target file is inside your `owns:` list before editing.
3. Read the target source file in full before editing.
4. Read relevant adjacent files for context (READ ONLY at this stage).
5. Only then begin work.

A skipped step is a process bug. Surface as: `LOADING_PROTOCOL_VIOLATION: skipped <step>. Restarting.`
