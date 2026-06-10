---
name: opus-define-ordering
description: Guardrail for "#define CHIAKI_LIB_ENABLE_OPUS 1" ordering — it MUST precede every chiaki header include. Load before editing ChiakiCore.c, ChiakiCore.h, the bridging header, or creating any C file that includes <chiaki/...> headers. Severity critical — violating it causes silent memory corruption (944-byte struct skew).
user-invocable: false
---

# OPUS Define Ordering

**Status:** enforced | **Severity:** critical — memory corruption
**Applies to:** `VisionRemotePS5/Chiaki/ChiakiCore.c`, `VisionRemotePS5/Chiaki/ChiakiCore.h`, `VisionRemotePS5/Chiaki/VisionRemotePS5-Bridging-Header.h`, any new C file that includes `<chiaki/...>` headers
**Evidence:** `ChiakiCore.c:8-22` (the define + comment + includes)

## Reality

The chiaki public headers conditionally compile fields into structs based on `CHIAKI_LIB_ENABLE_OPUS`. With OPUS disabled, `ChiakiSession` is **3568 bytes**. With OPUS enabled, it grows to **4512 bytes** (944-byte difference).

The library `libchiaki_full.a` was compiled with OPUS enabled. Therefore every `.c` file in this project that includes a chiaki header MUST define `CHIAKI_LIB_ENABLE_OPUS=1` BEFORE the include — otherwise the compiler generates code accessing the smaller (3568-byte) struct layout, while the linker resolves to the larger (4512-byte) library symbols. Result: silent memory corruption.

The current ordering in `ChiakiCore.c`:

```c
// ChiakiCore.c:14-26 — DO NOT REORDER
#define CHIAKI_LIB_ENABLE_OPUS 1

#include "ChiakiCore.h"
#include <stddef.h>

#include <chiaki/base64.h>
#include <chiaki/common.h>
#include <chiaki/random.h>
// ... etc
```

## Hallucination vector

LLMs reflexively:
- Move all `#define` directives to the top of the file or to a config header.
- Group `#include` directives together "for cleanliness", inadvertently moving a chiaki include above the OPUS define.
- Wrap the define in `#ifndef CHIAKI_LIB_ENABLE_OPUS / #endif` to make it "safer", which lets a `-DCHIAKI_LIB_ENABLE_OPUS=0` compile flag silently disable it.
- Add new helper headers that include `<chiaki/session.h>` without the define.

ANY of these reintroduce the 944-byte struct skew.

## Hard rules

You MUST NEVER:

1. Move `#define CHIAKI_LIB_ENABLE_OPUS 1` away from its current position (must precede ALL chiaki header includes in the file).
2. Wrap the define in `#ifndef ... #endif`, `#if !defined(...) ... #endif`, or any conditional.
3. Remove or comment out the explanatory comment block at `ChiakiCore.c:8-13` ("CRITICAL: Define CHIAKI_LIB_ENABLE_OPUS=1 BEFORE including any chiaki headers!"). The comment is the future-self warning that prevents regression.
4. Add a chiaki include to any new `.c` file in `VisionRemotePS5/Chiaki/` without first defining `CHIAKI_LIB_ENABLE_OPUS=1` at the very top of the file.
5. Define `CHIAKI_LIB_ENABLE_OPUS` to `0` anywhere in the project (not in a header, not in a build setting, not in a `.xcconfig`).

You MUST:

- For any new `.c` file that includes a chiaki header, mirror the ordering in `ChiakiCore.c:14-22` exactly: define first, then chiaki includes.
- For any new `.h` file that includes a chiaki header, prefix it with the same define.
- If you discover a chiaki include missing the prior define, surface it as a CRITICAL bug to the user — do NOT silently add the define and move on, because someone may have built around the wrong struct layout.

## Before/After

```c
// BEFORE (an LLM "include cleanup" attempt — REJECT):
#include "ChiakiCore.h"
#include <chiaki/base64.h>
#include <chiaki/common.h>
#include <stddef.h>

#define CHIAKI_LIB_ENABLE_OPUS 1   // moved here for "clarity" — BREAKS THE BUILD

// AFTER (the only correct form):
#define CHIAKI_LIB_ENABLE_OPUS 1   // MUST be first

#include "ChiakiCore.h"
#include <stddef.h>

#include <chiaki/base64.h>
#include <chiaki/common.h>
```
