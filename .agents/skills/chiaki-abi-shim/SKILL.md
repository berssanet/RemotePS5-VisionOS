---
skill: chiaki-abi-shim
status: enforced
severity: critical
applies_to:
  - VisionRemotePS5/Chiaki/ChiakiCore.c
  - VisionRemotePS5/Chiaki/ChiakiBridge.swift
  - VisionRemotePS5/Services/ChiakiFullSession.swift
evidence:
  - VisionRemotePS5/Chiaki/ChiakiCore.c:577-651    # manual offset section
  - VisionRemotePS5/Chiaki/ChiakiCore.c:744-812    # _safe() wrappers + chiaki_get_struct_sizes
---

# Skill: Chiaki ABI Shim — Manual Struct Offsets

## Reality

The static library `libchiaki_full.a` (under `Frameworks/Chiaki.xcframework/xros-arm64/`) was compiled with `CHIAKI_LIB_ENABLE_OPUS=1`, producing a `ChiakiSession` struct of **4512 bytes**. The chiaki public headers vendored in the xcframework do NOT match this layout. As a result:

- The header-derived offset for `video_sample_cb` is `608` (`0x260`) — **WRONG** for this library.
- The library actually expects `video_sample_cb` at offset `1552` (`0x610`).
- Same skew for `video_sample_cb_user` (offset `1560`) and `audio_sink` (offset `1568`).

`ChiakiCore.c` works around this with a dual-path pattern:
1. Direct `memcpy()` at the library's expected offset (the path that actually works).
2. A fallback call to the chiaki public setter (`chiaki_session_set_video_sample_cb()`) which writes via the wrong header offset — kept as belt-and-suspenders in case a future library revision reverts to the header layout.

```c
// ChiakiCore.c:586-598 — DO NOT TOUCH
#define LIBRARY_VIDEO_SAMPLE_CB_OFFSET 1552
#define LIBRARY_VIDEO_SAMPLE_CB_USER_OFFSET 1560

uint8_t *session_bytes = (uint8_t *)g_active_session->session;
*((ChiakiVideoSampleCallback *)(session_bytes + LIBRARY_VIDEO_SAMPLE_CB_OFFSET)) = session_video_sample_cb;
// ... user pointer set at +1560 ...

// Fallback at the header's (wrong) offset
chiaki_session_set_video_sample_cb(g_active_session->session, session_video_sample_cb, g_active_session);
```

## Hallucination vector

The LLM's natural latent-space prior is to:
- Treat `1552`, `1560`, `1568` as "magic numbers" and replace them with `offsetof(ChiakiSession, video_sample_cb)`.
- "Deduplicate" the dual-path write into a single `chiaki_session_set_video_sample_cb()` call.
- Migrate Swift callers to the existing `_safe()` wrappers (which use header-derived offsets and would equally be wrong).
- Delete `fprintf(stderr, "[ChiakiCore] DEBUG ABI: ...")` lines as "leftover debug logging".

ANY of these changes corrupts session memory and breaks the video stream silently — the session may register, but no frames render.

## Hard rules

You MUST NEVER:

1. Modify, delete, or refactor the `LIBRARY_VIDEO_SAMPLE_CB_OFFSET 1552`, `LIBRARY_VIDEO_SAMPLE_CB_USER_OFFSET 1560`, `LIBRARY_AUDIO_SINK_OFFSET 1568`, `LIBRARY_EVENT_CB_OFFSET 1536`, or `LIBRARY_EVENT_CB_USER_OFFSET 1544` constants. (Event pair added 2026-07-04 after on-device debugging: the ABI skew is a uniform +944 across ALL callback fields — header event_cb 592/600 → library 1536/1544. Without the manual event write, the session streams video but Swift never receives `CHIAKI_EVENT_CONNECTED`, and every controller input is discarded. Verified working on hardware.)
2. Replace `*((Type *)(session_bytes + OFFSET)) = ...` writes with `session->field = ...` style.
3. Remove the dual-path "fallback" calls (e.g., the `chiaki_session_set_video_sample_cb(...)` after the manual write).
4. Migrate `ChiakiBridge.swift` or `ChiakiFullSession.swift` to call `chiaki_session_set_video_callback_safe()` / `chiaki_session_set_audio_sink_safe()` / `chiaki_session_set_event_callback_safe()`. These exist as a verification surface ONLY — the migration has NOT been authorized.
5. Delete the `chiaki_get_struct_sizes()` function or the `_safe()` wrapper functions, even if no Swift caller currently invokes them.
6. Delete the `fprintf(stderr, "[ChiakiCore] DEBUG ABI: offsetof(...)=%zu\n", ...)` lines — they are runtime ABI verification.

You MUST:

- When adding a new chiaki callback, use the dual-path pattern: manual `memcpy` at the library offset + fallback public setter call + `fprintf` ABI probe.
- When unsure of the correct library offset for a new field, run a debug build and read the `[ChiakiCore] DEBUG ABI:` lines from stderr against the library's actual struct (not the header's).

## How to know the migration is safe (NOT YOU — only the human user)

Migration to the `_safe()` wrappers becomes safe only when ALL of these hold:
1. `libchiaki_full.a` is rebuilt from source matching the vendored headers.
2. `chiaki_get_struct_sizes()` returns `out_video_cb_offset == 1552` AND header `offsetof(ChiakiSession, video_sample_cb) == 1552`.
3. The user explicitly authorizes the migration.

Until then, the manual offsets stay. Period.

## Before/After (for any future "cleanup" PR)

```c
// BEFORE (an LLM "cleanup" attempt — REJECT):
g_active_session->session->video_sample_cb = session_video_sample_cb;
g_active_session->session->video_sample_cb_user = g_active_session;

// AFTER (the only correct form):
#define LIBRARY_VIDEO_SAMPLE_CB_OFFSET 1552
#define LIBRARY_VIDEO_SAMPLE_CB_USER_OFFSET 1560
uint8_t *session_bytes = (uint8_t *)g_active_session->session;
*((ChiakiVideoSampleCallback *)(session_bytes + LIBRARY_VIDEO_SAMPLE_CB_OFFSET)) = session_video_sample_cb;
*((void **)(session_bytes + LIBRARY_VIDEO_SAMPLE_CB_USER_OFFSET)) = g_active_session;
chiaki_session_set_video_sample_cb(g_active_session->session, session_video_sample_cb, g_active_session); // header-side fallback
```
