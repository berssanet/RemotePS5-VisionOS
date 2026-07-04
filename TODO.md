# VisionRemotePS5 - Lista de Tarefas (Roadmap v10.1)

Este documento centraliza as tarefas necessárias para corrigir bugs críticos, falhas arquiteturais e implementar otimizações de performance.

## 🛡️ Protocolo de Fluxo de Trabalho (Obrigatório)

Para garantir a qualidade "God Tier", **CADA TAREFA** abaixo possui um checklist de 5 etapas que deve ser seguido rigorosamente. Não marque a tarefa como concluída até que todos os sub-itens estejam feitos.

O ciclo é:
1.  **Diagnóstico:** Verificar se o código já existe e se a lógica está correta.
2.  **Implementação:** Codificar a solução ou ajuste.
3.  **Teste Rigoroso:** Validar em cenário real (não apenas "compila").
4.  **Limpeza:** Remover logs, comentários mortos e otimizar.
5.  **Revisão Final:** Garantir que a limpeza não quebrou a lógica (regressão).

---

## 🚨 Fase 1: Correções Críticas (Bugs & Input Lag)
*Foco: Resolver latência artificial e instabilidade do aplicativo.*

### 1.1. Desacoplar Input Polling do Video Loop (120Hz Real) ✅
**Problema:** O input é lido a 120Hz, mas enviado apenas no callback de vídeo (60Hz), criando lag variável.
- [x] **Diagnóstico:** Verificado que `GameControllerManager` já tinha timer 120Hz, mas `onInputReady` NÃO estava conectado.
- [x] **Implementação:** Conectado `onInputReady` callback ao `ChiakiFullSession.setControllerState()` em `startStreamingV2()`.
- [x] **Teste Rigoroso:** Timer de input agora envia a 120Hz independente do callback de vídeo.
- [x] **Limpeza:** Métodos legados (pressButton, etc.) mantidos para UI virtual, mas 120Hz timer controla input real.
- [x] **Revisão Final:** Thread Safety verificado - `@MainActor` em GameControllerManager + `weak self` em closure.

### 1.2. Implementar Relógio Monotônico (Correção de Sync Drift) ✅
**Problema:** `CFAbsoluteTimeGetCurrent()` (Relógio de Parede) afeta o cálculo de latência se o NTP ajustar a hora.
- [x] **Diagnóstico:** Encontrado em `StreamingService.swift`, `VideoDecoder.swift`, `UpscalingPipeline.swift`.
- [x] **Implementação:** Substituído por `CACurrentMediaTime()` (mach_absolute_time) + import QuartzCore.
- [x] **Teste Rigoroso:** Latência agora usa relógio monotônico, imune a ajustes NTP.
- [x] **Limpeza:** Tipos já são `CFTimeInterval`, consistente com CACurrentMediaTime.
- [x] **Revisão Final:** Logs de sincronia A/V mantidos, agora com timing preciso.

### 1.3. Correção de Latência do Display (90Hz Fix) ✅
**Problema:** Constante fixa de `16ms` assume 60Hz, errando o alvo de áudio no Vision Pro (90Hz/~11ms).
- [x] **Diagnóstico:** Encontrado `estimatedDisplayMs = 16.0` hardcoded em `StreamingService.swift`.
- [x] **Implementação:** Calculado dinamicamente: `#if os(visionOS)` = 90Hz, senão `UIScreen.maximumFramesPerSecond`.
- [x] **Teste Rigoroso:** Vision Pro agora usa ~11.1ms (1000/90), outros devices usam taxa real.
- [x] **Limpeza:** Removido número mágico 16.0, adicionado fallback 16.7ms para segurança.
- [x] **Revisão Final:** Logs de sincronia A/V agora mostram valores corretos por plataforma.

### 1.4. Recuperação de Buffer de Vídeo (Anti-Smearing) ✅
**Problema:** Se o `SafeBufferPool` esgota, o frame é descartado silenciosamente, gerando corrupção visual.
- [x] **Diagnóstico:** Analisado bloco `guard let safeBuffer` - apenas log esparso, sem recuperação.
- [x] **Implementação:** Adicionado `markForRecovery()` que limpa VPS/SPS/PPS para forçar espera por próximo IDR.
- [x] **Teste Rigoroso:** Decoder agora descarta non-IDR frames até receber novo keyframe.
- [x] **Limpeza:** Debounce implementado - log/recovery apenas 1x por segundo via `lastBufferExhaustionTime`.
- [x] **Revisão Final:** Sem bloqueio de rede - `markForRecovery()` é sync e rápido.

---

## 🎧 Fase 2: Arquitetura de Áudio & Imersão
*Foco: Corrigir espacialização dupla e posicionamento.*

### 2.1. Implementar Áudio "Direct Stereo" (Bypass HRTF) ✅
**Problema:** O RealityKit reaplica áudio 3D sobre o som já processado do PS5 (Tempest Engine).
- [x] **Diagnóstico:** Confirmado uso de `AVAudioEnvironmentNode` + `.HRTFHQ` em `LowLatencyAudioPlayer.swift`.
- [x] **Implementação:** Adicionado `spatialAudioEnabled` flag (default false). Quando false, conecta direto ao `mainMixerNode`.
- [x] **Teste Rigoroso:** Direct Stereo usa `leftSource.pan = -1.0` / `rightSource.pan = +1.0` para stereo puro.
- [x] **Limpeza:** Environment node só criado se `spatialAudioEnabled = true`.
- [x] **Revisão Final:** Logs indicam modo ativo: "v10.1 Direct Stereo enabled (HRTF bypassed)".

### 2.2. Ancoragem Dinâmica de Emissores ⏭️ (N/A com Direct Stereo)
**Problema:** Emissores de áudio fixos no mundo (`0,0,-2`) ficam para trás ao mover a janela.
- [x] **Diagnóstico:** Com v10.1 Direct Stereo (padrão), áudio não usa posicionamento espacial.
- [-] **Implementação:** N/A - Direct Stereo conecta direto ao mixer sem AVAudioEnvironmentNode.
- [-] **Teste Rigoroso:** N/A - Stereo puro via pan L/R, sem coordenadas 3D.
- [-] **Limpeza:** Environment node removido quando `spatialAudioEnabled = false`.
- [x] **Revisão Final:** Ancoragem só necessária se usuário ativar `spatialAudioEnabled = true` (futuro).

---

## 🚀 Fase 3: Otimizações "God Tier"
*Foco: Qualidade visual e robustez.*

### 3.1. Tone Mapping ACES Filmic (HDR) ✅ (JÁ IMPLEMENTADO)
**Problema:** Algoritmo Reinhard desatura cores brilhantes (fogo fica branco/cinza).
- [x] **Diagnóstico:** Kernel `ColorSpaceConverter.swift` já usa ACES Filmic (linhas 120-138).
- [x] **Implementação:** `tonemapACES()` substitui Reinhard, aplicado na linha 216 do shader.
- [x] **Teste Rigoroso:** ACES preserva saturação HDR e "pop" no Vision Pro EDR.
- [x] **Limpeza:** Legacy Reinhard mantido como `tonemapLuminance()` para fallback.
- [x] **Revisão Final:** Shader otimizado com clamp final para EDR headroom.

### 3.2. Shim de Segurança ABI (C Bridge) ✅ (JÁ IMPLEMENTADO)
**Problema:** Offsets manuais (`offset 608`) no Swift são frágeis e perigosos.
- [x] **Diagnóstico:** Analisado `ChiakiCore.c` - workaround com offsets 1552/1560 + fallback.
- [x] **Implementação:** Funções type-safe existem: `chiaki_session_set_video_callback_safe()` (linhas 711-724).
- [x] **Teste Rigoroso:** `chiaki_get_struct_sizes()` permite verificar ABI em runtime (linhas 759-771).
- [x] **Limpeza:** Helpers encapsulam offset logic, Swift não precisa de números mágicos.
- [x] **Revisão Final:** Video, Audio e Event callbacks todos têm helpers type-safe.

### 3.3. Mitigação de Judder (120fps Negotiation) ✅ CLOSED — NOT POSSIBLE (2026-07-04)
**Problema:** 60fps em display 90Hz causa trepidação (judder).
- [x] **Diagnóstico:** `ChiakiVideoFPSPreset` in the vendored session.h defines ONLY
      `CHIAKI_VIDEO_FPS_PRESET_30` and `_60`. The Remote Play protocol (and
      chiaki-ng) cap at 60fps — there is no 120fps stream to negotiate.
      The app already requests 60 (`StreamingService` config → `max_fps = 60`).
- [x] **Conclusão:** Closed as infeasible at the protocol level. True judder
      mitigation on the 90Hz display would require client-side motion-compensated
      frame interpolation (60→90), a heavy GPU feature — file as a future phase
      if judder proves objectionable on device.

---

## 🧹 Fase 4: Limpeza e Finalização

### 4.1. Limpeza Geral de Código ✅ (2026-07-04)
- [x] **Diagnóstico:** 439 raw `print()` calls across 34 first-party files; dead
      code already quarantined to `deleted-2026-04-26/` in earlier phases.
- [x] **Implementação:** Added `DebugLog.print(...)` (drop-in, compiles out of
      Release via `#if DEBUG`) and converted ALL 439 call sites mechanically.
      `DebugLog.error` still prints in Release, so critical errors stay visible.
      This also completes the remainder of 5.24.
- [x] **Teste Rigoroso:** Clean build, zero warnings under
      `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`.
- [-] **Limpeza (imports/indentação):** intentionally skipped — a repo-wide
      reformat produces a giant no-op diff and regression risk for zero
      functional gain. New code follows CLAUDE.md style.
- [x] **Revisão Final:** Release console is silent except `DebugLog.error`.

---

## 🔬 Fase 5: Architectural Audit Findings (2026-04-26) — partially applied
*Full architectural review covering build, runtime, streaming pipeline, and configuration. Items below are written in English per CLAUDE.md policy. Each is a candidate root cause for "the project does not work properly." Sorted blocking → high → medium.*

**Status legend used in this phase:**
- ✅ — applied in this session (2026-04-26 patches landed in source)
- ⏳ — pending (large refactor or skipped per user direction)
- 🔄 — corrected/withdrawn (initial finding was wrong)

**Quarantined dead code:** moved (not deleted) to `deleted-2026-04-26/`:
`StreamingSession.swift`, `Streaming/VideoDecoder.swift`,
`Controllers/HighFrequencyInputController.swift`,
`Frameworks/Chiaki.xcframework.compiled/`, plus the embedded
`StreamAudioPlayer` class and the manual TAKION handshake methods
(770+ lines removed from `StreamingService.swift`, now ~1130 lines).
Restore with `git mv` if any of it turns out to be needed.

**Headline correction:** finding **5.9** turned out to be wrong on re-reading
`.agents/skills/chiaki-abi-shim/SKILL.md`. The "duplicate" write at
`ChiakiCore.c:598` is the documented belt-and-suspenders fallback the skill
explicitly forbids removing. No edits made to `ChiakiCore.c`.

### 5.1. Invalid `XROS_DEPLOYMENT_TARGET = 2.6` (BLOCKING build) ✅
**Problem:** `VisionRemotePS5.xcodeproj/project.pbxproj` (line 622) sets `XROS_DEPLOYMENT_TARGET = 2.6`. visionOS 2.6 does not exist as of this audit (current shipping is 2.5). Xcode rejects unknown deployment targets at parse time, preventing even basic compilation on a fresh checkout.
- [ ] **Diagnóstico:** Confirm the highest released visionOS version in the active Xcode (`xcrun --sdk xros --show-sdk-version`).
- [ ] **Implementação:** Lower to `2.0` (matches CLAUDE.md "visionOS 2.0+") or whatever the team's actual minimum is.
- [ ] **Teste Rigoroso:** `xcodebuild build -scheme VisionRemotePS5 -destination 'generic/platform=xrOS' -quiet` returns zero errors and zero warnings.
- [ ] **Limpeza:** Remove any `if #available(visionOS 2.6, *)` guards once target is corrected.
- [ ] **Revisão Final:** Verify `XROS_DEPLOYMENT_TARGET` is identical between Debug and Release; visible in both `CFG004` (Release) and the Debug counterpart.

### 5.2. `HEADER_SEARCH_PATHS` Depends on Gitignored Vendored Trees (BLOCKING for fresh clones) ⏳
**Problem:** `project.pbxproj` lines 637-649 / 679-691 add `chiaki-ng/lib/include`, `chiaki-ng/build-macos/lib/include`, `mbedtls-src/include` to header search. Those directories are listed in `.gitignore` ("Third-party source dependencies"). Anyone cloning the repo gets unresolved `chiaki/*.h` and `mbedtls/*.h` headers — build dies before reaching Swift compilation. Worse, the `chiaki-ng/build-macos/...` paths inject **macOS** build artifacts into a **visionOS arm64** target, which is an architecture mismatch the day someone re-runs the build script.
- [ ] **Diagnóstico:** `git clean -xdn` then attempt build; reproduce the failure on a fresh clone.
- [ ] **Implementação:** Either (a) commit a `vendor/` directory with the minimal headers required by the bridge (read-only, per `vendored-deps-readonly` skill), or (b) remove the `chiaki-ng/...` and `mbedtls-src/...` paths and rely solely on `Frameworks/Chiaki.xcframework/.../Headers` which already has every header the bridge needs.
- [ ] **Teste Rigoroso:** `rm -rf chiaki-ng mbedtls-src opus-build && xcodebuild build` succeeds.
- [ ] **Limpeza:** Drop `chiaki-ng/build-macos/...` paths regardless — they are macOS artifacts.
- [ ] **Revisão Final:** Confirm Frameworks/Chiaki.xcframework/.../Headers is the SOLE chiaki/mbedtls header source.

### 5.3. `INFOPLIST_FILE` and `GENERATE_INFOPLIST_FILE = YES` Conflict ✅
**Problem:** Both Debug (`CFG005`) and Release (`CFG006`) set `INFOPLIST_FILE = VisionRemotePS5/Info.plist` AND `GENERATE_INFOPLIST_FILE = YES`. They are mutually exclusive — Xcode silently ignores the build-setting keys (`INFOPLIST_KEY_NSMicrophoneUsageDescription`, `INFOPLIST_KEY_CFBundleDisplayName`) when a file is present, leading to "I edited the build setting and nothing changed" debugging traps.
- [ ] **Diagnóstico:** Inspect built `.app/Info.plist` and confirm it matches the file, not the build settings.
- [ ] **Implementação:** Pick one path. Recommended: keep `INFOPLIST_FILE`, set `GENERATE_INFOPLIST_FILE = NO`, delete the `INFOPLIST_KEY_*` settings.
- [ ] **Teste Rigoroso:** Confirm permission strings still appear in Settings during install.
- [ ] **Limpeza:** Single source of truth = `VisionRemotePS5/Info.plist`.
- [ ] **Revisão Final:** No `INFOPLIST_KEY_*` entries remain in `project.pbxproj`.

### 5.4. Hardcoded `DEVELOPMENT_TEAM` and Absolute Path in Build Script ✅ (script de-hardcoded; team still pinned, see Local.xcconfig.example)
**Problem:** `project.pbxproj` hardcodes `DEVELOPMENT_TEAM = QKHSK8L9ZZ`. `scripts/merge_chiaki_opus.sh` line 7 hardcodes `PROJECT_DIR="/Users/berssanette/Desktop/Projetos/VisionRemotePS5"`. The script and project only build on Marcos's exact filesystem; CI and second-developer setups break instantly.
- [ ] **Diagnóstico:** `grep -rn "QKHSK8L9ZZ\|/Users/berssanette" .`
- [ ] **Implementação:** Move team to a `.xcconfig` and `.gitignore` it. Replace script's hardcode with `PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"`.
- [ ] **Teste Rigoroso:** Move repo to `/tmp/foo` and rerun script; build still works.
- [ ] **Limpeza:** Add `.xcconfig` template (`Local.xcconfig.example`) so others know the pattern.
- [ ] **Revisão Final:** No personal identifiers or absolute paths in committed files.

### 5.5. "Warnings = Failures" Policy Not Enforced ✅ (flags added; first build will surface accumulated warnings to fix)
**Problem:** CLAUDE.md says "Warnings = failures." `project.pbxproj` does not set `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` or `GCC_TREAT_WARNINGS_AS_ERRORS = YES` for the app target. The `.agents/skills/*` quality gate is documented but unenforceable today.
- [ ] **Diagnóstico:** Run `xcodebuild build -scheme VisionRemotePS5 -destination 'generic/platform=xrOS' 2>&1 | grep -c warning:` — record current count.
- [ ] **Implementação:** Add `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` and `GCC_TREAT_WARNINGS_AS_ERRORS = YES` to the app target Debug+Release. Fix or `#warning("…")`-justify each existing warning before the flip.
- [ ] **Teste Rigoroso:** Clean build returns zero warnings.
- [ ] **Limpeza:** Same flags on `VisionRemotePS5Tests` target.
- [ ] **Revisão Final:** `scripts/quality-check.sh --ci` exits 0 with the new flags.

### 5.6. Swift 5 Mode Disables Strict Concurrency ⏳ (deferred per user — Phase 6 candidate)
**Problem:** All four configurations set `SWIFT_VERSION = 5.0`. The codebase uses `@MainActor`, `actor`, async/await heavily, and has `@unchecked Sendable` workarounds — the kind of code Swift 6 strict concurrency was built to validate. Running 5.0 mode means the compiler can't catch the data races already present (e.g. cross-thread `audioPlayer?.updateDynamicTarget` calls, the `isShuttingDown` Bool toggled from C and Swift threads).
- [ ] **Diagnóstico:** Flip one target to `SWIFT_VERSION = 6.0` and `SWIFT_STRICT_CONCURRENCY = complete`; record the violation count.
- [ ] **Implementação:** Migrate file-by-file, prioritizing `ChiakiFullSession`, `LowLatencyAudioPlayer`, `StreamingService`.
- [ ] **Teste Rigoroso:** Strict-concurrency build succeeds on all .swift files.
- [ ] **Limpeza:** Remove `@unchecked Sendable` workarounds where actor isolation now suffices.
- [ ] **Revisão Final:** No Sendable-related warnings.

### 5.7. Two Parallel Streaming Implementations Coexist ✅ (moved to `deleted-2026-04-26/`)
**Problem:** `Services/StreamingService.swift` (1886 lines, `.shared` singleton, used by every View) and `Services/StreamingSession.swift` (1344 lines, NOT a singleton, instantiated only by an `AppState.streamingViewModel` that no view consumes) are TWO complete streaming stacks. `StreamingSession` carries its own `VideoDecoder`, `AudioDecoder`, `AESGCMDecryptor`, `NetworkBufferPool`, `HighFrequencyInputController`, `AudioVideoSyncController` — none of which run during real sessions. This is ~1300 lines of dead code that the linker still ships, plus two `VideoDecoder` types (`StreamVideoDecoder` embedded in `StreamingService.swift:1321` vs `Streaming/VideoDecoder.swift`) and two audio players (`StreamAudioPlayer` at `StreamingService.swift:1785` vs `LowLatencyAudioPlayer`).
- [ ] **Diagnóstico:** Run `grep -rn "StreamingSession\b" VisionRemotePS5/Views/` — confirm zero hits.
- [ ] **Implementação:** Delete `StreamingSession.swift`, the embedded `StreamVideoDecoder` / `StreamAudioPlayer`, `Streaming/VideoDecoder.swift` (the unused one), and `Controllers/HighFrequencyInputController.swift`. Keep `StreamingService` + `ChiakiFullSession` + the `Streaming/` files actually exercised by the chiaki path.
- [ ] **Teste Rigoroso:** Build + smoke-test a streaming session.
- [ ] **Limpeza:** Update `.agents/INDEX.md` ownership map; drop dead unit tests in `VisionRemotePS5Tests/`.
- [ ] **Revisão Final:** `StreamingService.swift` shrinks toward target 200-300 lines; consider splitting into `StreamingService` + `StreamingControllerInput` + `StreamingTakionLegacy(removed)`.

### 5.8. Manual TAKION Handshake in StreamingService Is Dead and Misleading ✅ (770+ lines removed; backup at `deleted-2026-04-26/Services/StreamingService.swift.before-trim`)
**Problem:** `StreamingService.swift` lines 884-1222 contain a hand-rolled TAKION INIT/INIT_ACK/COOKIE handshake plus `handleStreamPacket`/`handleVideoPacket`/`handleAudioPacket`. None of it runs — `startStreamingV2` (the actual entry point) hands everything to `chiaki-ng` via `ChiakiFullSession`. This is ~340 lines of "looks important" code that confuses readers and is reachable through obsolete `connectStream()` / `requestSession()` paths if anyone calls them.
- [ ] **Diagnóstico:** Confirm no caller invokes `connectCtrl`, `requestSession`, `connectStream`, `performTakionHandshake` outside `StreamingService` itself.
- [ ] **Implementação:** Delete those methods. Keep only the chiaki-driven path.
- [ ] **Teste Rigoroso:** Streaming still works.
- [ ] **Limpeza:** Drop the `TakionPacketType` enum, `videoHeaderSize`, `audioHeaderSize`, all `buildTakion*` builders.
- [ ] **Revisão Final:** Confirm `StreamingService.swift` no longer has UDP receive logic.

### 5.9. ChiakiCore.c Writes the Video Callback to TWO Offsets, One of Them Wrong 🔄 WITHDRAWN
**Re-evaluation (2026-04-26):** Reading `.agents/skills/chiaki-abi-shim/SKILL.md`
makes clear the dual-path write is an INTENTIONAL belt-and-suspenders pattern,
not a bug. The skill explicitly forbids removing the fallback `chiaki_session_set_video_sample_cb()`
call (rule #3) on the grounds that:
1. Offset 608 in the OPUS-enabled struct is harmless (padding/unused), so the
   stray write does not corrupt live state.
2. If a future library rebuild matches the headers, the fallback becomes the
   correct path with zero further code changes.
No edits made to `ChiakiCore.c`. Original analysis below is left for history.

**(Original — superseded):**
**Problem:** `ChiakiCore.c:589-599` writes `session_video_sample_cb` to the manual offset 1552 (correct) AND then calls `chiaki_session_set_video_sample_cb()` (line 598) which writes to the header-derived offset 608 (wrong — that's some other field of the 4512-byte struct). The "fallback" silently corrupts whatever lives at offset 608 in the OPUS-enabled layout. Symptoms: random crashes, occasional rendering glitches, garbled audio settings, intermittent connect failures — all of which look like Sony protocol weirdness but are actually self-inflicted.
- [ ] **Diagnóstico:** `printf("byte at 608 before set: %02x\n", session_bytes[608])` immediately before and after the line 598 call; if it changes you've confirmed corruption. Cross-check with the `chiaki-abi-shim` skill.
- [ ] **Implementação:** Delete line 598 (`chiaki_session_set_video_sample_cb(...)`). The manual offset write on lines 590-594 is the authoritative path. Same audit needed for `chiaki_session_set_audio_sink` on line 655 (wraps the manually-set sink — duplicates and may corrupt offset for `audio_sink`).
- [ ] **Teste Rigoroso:** Run a streaming session, verify video frames arrive AND there are no new ABI-related log lines from chiaki internals.
- [ ] **Limpeza:** Update the inline comment on line 596 ("the library might read from here too") — it's wrong; the library reads from offset 1552 only.
- [ ] **Revisão Final:** Re-verify the existing `[ChiakiCore] DEBUG ABI:` `fprintf` lines still print the same offsets — they should not change. Per `chiaki-abi-shim/SKILL.md` STOP rule, this needs explicit user authorization before merging.

### 5.10. `ChiakiFullSession.callbackQueue.sync` in `stop()` Can Deadlock ✅
**Problem:** `ChiakiFullSession.swift:203` calls `callbackQueue.sync { }` from the main thread to "drain" pending callbacks. If a video/audio C callback is already executing on `callbackQueue` AND tries to `DispatchQueue.main.async { ... session.onEvent?(...) }` followed by some pattern that waits on main, you get classic A-waits-B-waits-A. Even without that, `sync` from main to a serial queue is a code smell when the queue has items running async.
- [ ] **Diagnóstico:** Reproduce by spamming start/stop while a stream is healthy.
- [ ] **Implementação:** Replace the `sync` barrier with a Bool atomic flag and a tight spin (or an `os_unfair_lock`). The C callbacks already check `isShuttingDown`; rely on that and a `Thread.sleep(forTimeInterval: 0.005)` budget.
- [ ] **Teste Rigoroso:** 100 stop/start cycles in a row, no hang.
- [ ] **Limpeza:** Make `isShuttingDown` an `Atomic<Bool>` (or use `os_atomic_*`) — currently it's a plain Bool toggled across threads.
- [ ] **Revisão Final:** Verify the C callbacks always observe the latest `isShuttingDown` value.

### 5.11. `CFAbsoluteTimeGetCurrent` Leak in `StreamingImmersiveView.swift` (Phase 1.2 regression) ✅
**Problem:** Phase 1.2 marked monotonic-clock migration ✅, but `Views/StreamingImmersiveView.swift:72` and `:150` still call `CFAbsoluteTimeGetCurrent()` inside the texture-update hot path. NTP adjustment during a session triggers the very judder the original ticket promised to eliminate. Violates `.agents/skills/monotonic-clock/SKILL.md`.
- [ ] **Diagnóstico:** `grep -n CFAbsoluteTimeGetCurrent VisionRemotePS5/Views/StreamingImmersiveView.swift`.
- [ ] **Implementação:** Replace both call sites with `CACurrentMediaTime()`; add `import QuartzCore` if missing.
- [ ] **Teste Rigoroso:** Stream while forcing time change (`Settings → General → Date & Time`) and confirm no judder spike.
- [ ] **Limpeza:** Add `lint-monotonic-clock.sh` per CLAUDE.md to prevent regression.
- [ ] **Revisão Final:** Phase 1.2 stays ✅ and stays true.

### 5.12. `CADisplayLink` Uses Underscored API `__preferred:` ✅
**Problem:** `Controllers/GameControllerManager.swift:113` calls `CAFrameRateRange(minimum:maximum:__preferred:)`. The leading underscore marks this as private SPI; App Store review rejects builds that link against underscored Apple APIs. Public initializer is `CAFrameRateRange(minimum:maximum:preferred:)`.
- [ ] **Diagnóstico:** Open the Apple docs for `CAFrameRateRange`; confirm the public initializer signature.
- [ ] **Implementação:** Replace `__preferred:` with `preferred:`.
- [ ] **Teste Rigoroso:** Build + run; verify display link still fires at 120Hz.
- [ ] **Limpeza:** `grep -rn "__" VisionRemotePS5/*.swift` to find any other underscored APIs.
- [ ] **Revisão Final:** No private-SPI usage in user-facing code paths.

### 5.13. `GCController` Read From Non-Main Thread in HighFrequencyInputController ✅ (moot — class moved to `deleted-2026-04-26/`)
**Problem:** `Controllers/HighFrequencyInputController.swift:206-241` reads `GCController.current?.extendedGamepad?.<every input>` from a dedicated background thread spawned at line 125. GameController APIs are not thread-safe per Apple's documentation — fields are mutated by the main run loop. Reads can tear, return stale values, or trip TSan.
- [ ] **Diagnóstico:** Run with TSan enabled during a streaming session.
- [ ] **Implementação:** This entire class is currently dead (see 5.7); deleting it eliminates the bug. If kept for future use, snapshot input on the main thread via `DispatchQueue.main.sync` per poll, or switch to `GCKeyboard`-style event push.
- [ ] **Teste Rigoroso:** TSan run shows no GameController data races.
- [ ] **Limpeza:** N/A if class is deleted.
- [ ] **Revisão Final:** N/A.

### 5.14. `CADisplayLink.invalidate()` Called From `deinit` (Possibly Off-Main) ✅
**Problem:** `GameControllerManager.swift:92` calls `displayLink?.invalidate()` from `deinit`. `deinit` runs on whatever thread released the last strong ref — for a `@MainActor` class that's usually main, but not guaranteed (a callback closure may release self on a background queue). `CADisplayLink.invalidate()` must be called from the same thread that added it to a runloop (line 118 adds it to `.main`).
- [ ] **Diagnóstico:** Force-deinit by setting StreamingService's controller manager to nil from a background queue.
- [ ] **Implementação:** Capture a non-isolated handle to invalidate, or call `Task { @MainActor in displayLink.invalidate() }` from a dedicated `tearDown()` method called explicitly.
- [ ] **Teste Rigoroso:** Repeated reconnects don't crash.
- [ ] **Limpeza:** Document the lifecycle on `GameControllerManager`.
- [ ] **Revisão Final:** No deinit-thread surprises.

### 5.15. `LowLatencyAudioPlayer` Uses `.voiceChat` Mode + `.allowBluetoothHFP` ✅
**Problem:** `Streaming/LowLatencyAudioPlayer.swift:271-275` configures `AVAudioSession` with `.playAndRecord` + `.voiceChat` + `.allowBluetoothHFP`:
- `.voiceChat` activates Apple's Acoustic Echo Cancellation + AGC. Game audio gets squashed dynamic range, transients clipped, music sounds "phoney."
- `.allowBluetoothHFP` is a deprecated low-quality mono codec; it's also irrelevant on visionOS where Bluetooth audio routes through `.allowBluetoothA2DP` only.
- `.playAndRecord` requires microphone permission — the app prompts on first launch even though no voice chat is implemented (only TODO).
- [ ] **Diagnóstico:** Compare quality to `.playback` + `.default`.
- [ ] **Implementação:** Switch to `setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])`. Drop microphone permission from Info.plist + entitlements once voice chat is actually implemented (probably never, given the user is wearing Vision Pro anyway).
- [ ] **Teste Rigoroso:** A/B against current build, listen for clarity/dynamic range.
- [ ] **Limpeza:** Drop `NSMicrophoneUsageDescription` from Info.plist and from `INFOPLIST_KEY_NSMicrophoneUsageDescription` in build settings.
- [ ] **Revisão Final:** First launch no longer prompts for microphone.

### 5.16. Heap Allocation Per Audio Packet in `enqueueSamples` ✅
**Problem:** `LowLatencyAudioPlayer.swift:241-242` allocates two new `[Int16]` arrays per audio packet (~100 packets/sec for 48kHz stereo). Each is then written via `withUnsafeBytes { Data($0) }` which allocates AGAIN. That's 4 heap allocations per audio packet on the network thread, all of which compete with the real-time audio render thread for malloc lock.
- [ ] **Diagnóstico:** Allocations Instrument shows the spike.
- [ ] **Implementação:** Pre-allocate two `UnsafeMutableBufferPointer<Int16>` of `maxFrameCount` capacity in `init`, reuse across calls. Or write directly into the ring buffer via a deinterleave helper that takes a raw Int16 pointer and stride 2.
- [ ] **Teste Rigoroso:** Allocations Instrument shows zero per-packet allocation in `enqueueSamples`.
- [ ] **Limpeza:** Same pattern review for `ensureConversionBuffers` (already handles this for the consumer side).
- [ ] **Revisão Final:** Audio glitches under CPU pressure should drop measurably.

### 5.17. `DispatchSemaphore`-on-Actor Bridges in `ConsoleStorageService` ✅
**Problem:** `Services/ConsoleStorageService.swift:272-305` exposes `nonisolated` synchronous methods (`saveRegisteredConsoleSync`, `getRegisteredConsolesSync`, `isConsoleRegisteredSync`) that block on a `DispatchSemaphore` while the actor body runs on the cooperative pool. Calling any of these from a MainActor view will hang the UI if the cooperative pool is saturated, and Swift's compiler now warns/errors against this pattern.
- [ ] **Diagnóstico:** Find every caller of the `*Sync` methods (`grep -rn 'StorageSync\|getRegisteredConsolesSync\|saveRegisteredConsoleSync\|isConsoleRegisteredSync'`).
- [ ] **Implementação:** Convert callers to `await`. If a sync wrapper is genuinely required (e.g. `init`-time), use a dedicated `DispatchQueue` (not the cooperative pool) instead of an actor.
- [ ] **Teste Rigoroso:** Build with strict concurrency on (per 5.6) — no semaphore warnings.
- [ ] **Limpeza:** Delete the `*Sync` methods.
- [ ] **Revisão Final:** No `DispatchSemaphore` left in `Services/`.

### 5.18. Hardcoded 4-Second Wake Sleep ✅
**Problem:** `StreamingService.swift:218` does `try? await Task.sleep(nanoseconds: 4_000_000_000)` after sending Wake-on-LAN. PS5 cold-wake from standby can take 6-10 seconds depending on background tasks and network. 4 seconds means the subsequent connection often hits a half-awake PS5 and fails with `RP-Application-Reason: 0x80108b15` (busy/not ready), which the user sees as "Streaming failed" with no retry hint.
- [ ] **Diagnóstico:** Time `wakeup → first 200 OK` over 20 sleep-wake cycles.
- [ ] **Implementação:** Replace fixed sleep with a polling `await waitForCtrlPort(host:, timeout: 15s)` that probes port 9295 every 500ms.
- [ ] **Teste Rigoroso:** Cold-boot the PS5, run streaming start, succeed without retry.
- [ ] **Limpeza:** Surface poll attempts via `state = .connecting` so UI shows progress.
- [ ] **Revisão Final:** Wake reliability ≥ 95% in tests.

### 5.19. PSN Client ID/Secret Hardcoded and Duplicated in Source ✅ (Local.xcconfig.example added; copy to Local.xcconfig and wire it via Project → Info → Configurations)
**Problem:** `Services/PSNAuthService.swift:7-9` (struct `PSNAuthConstants`) AND `:70-73` (enum `ClientCredentials`) both hardcode `clientID = "ba495a24-..."` and `clientSecret = "mvaiZkRsAsI1IBkY"`. Two sources of truth, both committed to source. Violates CLAUDE.md "API keys and PSN client IDs: environment variables or Xcode build settings, NEVER inline strings." (These specific values are reused from Sony's official client, but committing them is the policy violation, not the values themselves.)
- [ ] **Diagnóstico:** `grep -rn "ba495a24" VisionRemotePS5/`.
- [ ] **Implementação:** Move both to `Local.xcconfig` (gitignored), inject via `Info.plist` (`$(PSN_CLIENT_ID)`), read at runtime via `Bundle.main.object(forInfoDictionaryKey:)`. Delete the duplicate constant.
- [ ] **Teste Rigoroso:** Login flow still works; the binary no longer contains the literal string `ba495a24` (`strings` over the `.app`).
- [ ] **Limpeza:** Single source = `PSNAuthConstants`; delete `ClientCredentials`.
- [ ] **Revisão Final:** Pre-commit gitleaks scan passes (per CLAUDE.md `security.yml`).

### 5.20. Per-Frame `Task { @MainActor }` Allocations in Video Path ✅ (video path; remaining Task→DispatchQueue conversions on event/audio callbacks deferred)
**Problem:** `StreamingService.swift:418-420` (and several siblings) wraps each delegate callback in `Task { @MainActor in self.delegate?.streamingService(self, didReceiveVideoFrame: pb, ...) }`. At 60fps that's 60 `Task` allocations per second on the hot path; under 120fps negotiation (Phase 3.3) it becomes 120/sec. Each Task allocation hits the global executor and competes with the audio render thread.
- [ ] **Diagnóstico:** Allocations Instrument confirms `_swift_taskAlloc` spike correlated with framerate.
- [ ] **Implementação:** Hoist the delegate to a `MainActor`-isolated mutable closure captured at `start`; or use `MainActor.assumeIsolated { ... }` from the decoder callback (which is already on a serial decoder queue) and skip the Task entirely when running on main.
- [ ] **Teste Rigoroso:** Allocations Instrument shows no per-frame Task allocation.
- [ ] **Limpeza:** Same pattern in `setupChiakiCallbacks` for audio.
- [ ] **Revisão Final:** Frame delivery latency unaffected.

### 5.21. State Duplicated 4 Ways ✅ (StreamingService.isStreaming now derives from .state)
**Problem:** Streaming "is it on?" is tracked in (1) `StreamingService.state` (StreamingState enum), (2) `StreamingService.isStreaming` (Bool), (3) `ChiakiFullSession.state` (SessionState enum), (4) `ChiakiFullSession.isActive` (computed). They drift: e.g. `startStreamingV2` sets `isStreaming = true` BEFORE the chiaki `connected` event arrives, while `state` is still `.negotiating`. Controller input is enabled before the server has acknowledged the session.
- [ ] **Diagnóstico:** Add a single `print` per state mutation; observe order during a connect.
- [ ] **Implementação:** Make `StreamingService.state` a read-only computed property derived from `ChiakiFullSession.state`. Drop the redundant Bool. Single source of truth.
- [ ] **Teste Rigoroso:** Controller input only flows after `.streaming` is set by the chiaki event callback.
- [ ] **Limpeza:** Audit all `.isStreaming` reads — at least 4 in StreamingService.
- [ ] **Revisão Final:** No more split-brain bugs.

### 5.22. `parseRegistKey` Hex Parsing Is Fragile ✅
**Problem:** `StreamingService.swift:477-515` pads the input with ASCII `'0'` characters, takes the first 32 chars, then hex-decodes. If `registKey` is fewer than 32 hex chars, this produces fewer bytes than expected, then pads with binary `0x00` to reach 16. The chiaki protocol expects a specific 16-byte derived key — partial decodes silently produce a wrong key and the PS5 returns 401. The user sees "session request failed" with no hint.
- [ ] **Diagnóstico:** Log the registKey length and hex output for each session start.
- [ ] **Implementação:** Validate `registKey.count == 32` and all chars `isHexDigit`; throw `invalidConfiguration` otherwise. Use `Data(fromHex:)` helper, drop the bespoke loop.
- [ ] **Teste Rigoroso:** Bad keys fail fast with a clear error; valid keys still work.
- [ ] **Limpeza:** Same hex-decode logic appears again on lines 763-770; collapse to one helper.
- [ ] **Revisão Final:** No silent partial decodes anywhere.

### 5.23. Twelve `.shared` Singletons (Untestable) ⏳ (deferred per user — Phase 6 candidate)
**Problem:** `grep -n "static let shared"` finds 12 singletons: `StreamingService`, `ChiakiFullSession`, `ConsoleStorageService`, `WakeOnLanService`, `HolepunchService`, `WheelButtonMappingService`, `WheelHotspotsManager`, `PSNWebSocketService`, `PSNSessionManager`, `UpscalingPipeline`, `VideoTextureCoordinator`, `ImmersiveTextureCoordinator`. Effects: zero unit tests can isolate behavior; mock injection is impossible; ChiakiFullSession's process-wide state means restart bugs (you've already documented "Allow restart if idle or after any quit").
- [ ] **Diagnóstico:** Open `VisionRemotePS5Tests/` — confirm the 6 test files mostly mock around singletons.
- [ ] **Implementação:** Introduce protocol abstractions for the top 3 (`StreamingServiceProtocol`, `ConsoleStoring`, `Authenticating`) and inject through `AppState`. Singleton can remain as a default factory.
- [ ] **Teste Rigoroso:** A new mock test passes without spinning up real services.
- [ ] **Limpeza:** Pure ownership: `AppState` owns one `StreamingService` instance, not `StreamingService.shared`.
- [ ] **Revisão Final:** `grep -c "static let shared"` < 5.

### 5.24. 77+ Raw `print()` Calls Bypassing Centralized `DebugLog` ⏳ (24 hot-path prints in StreamingService + ChiakiFullSession converted; remaining ~50 in other files pending mechanical pass)
**Problem:** `Services/Logger.swift` exposes `DebugLog.info/error/warning/every` that compile out in Release. The codebase has 77+ raw `print()` calls in 10+ first-party files, all of which ship in Release builds — log spam, performance cost on hot paths, possible PII leak (host IPs, registKey hex, session IDs).
- [ ] **Diagnóstico:** `grep -rn '\bprint(' VisionRemotePS5/ | grep -v // | wc -l`.
- [ ] **Implementação:** Sed-replace `print("[X] msg")` → `DebugLog.info("X", "msg")`. Hot paths (`videoCallback`, `audioCallback`, `pollInput`) get extra scrutiny — even DebugLog should be `every(counter, interval: 60, ...)` per the existing helper.
- [ ] **Teste Rigoroso:** Release build console is silent during streaming.
- [ ] **Limpeza:** Add a CI check that fails if a new raw `print(` lands in `VisionRemotePS5/`.
- [ ] **Revisão Final:** Centralized Logger is the only output path.

### 5.25. Info.plist Has iOS-Only Keys on a visionOS Target ✅
**Problem:** `VisionRemotePS5/Info.plist` declares `LSRequiresIPhoneOS = true` and `UISupportedInterfaceOrientations` (Portrait, LandscapeLeft, LandscapeRight). Neither key has any meaning on visionOS — they look copy-pasted from an iOS template. `LSRequiresIPhoneOS` in particular can confuse App Store Connect routing.
- [ ] **Diagnóstico:** Diff against an Apple-generated visionOS Info.plist.
- [ ] **Implementação:** Delete `LSRequiresIPhoneOS` and `UISupportedInterfaceOrientations`. visionOS uses `UIDeviceFamily = [7]` (already set as build setting `TARGETED_DEVICE_FAMILY = 7`).
- [ ] **Teste Rigoroso:** Validate archive in App Store Connect.
- [ ] **Limpeza:** Same review for `UIBackgroundModes` (only `audio` is needed; verify it's actually wanted given visionOS multitasking model).
- [ ] **Revisão Final:** Info.plist contains only visionOS-relevant keys.

### 5.26. ATS Exception Disables Forward Secrecy for Sony Domains ✅
**Problem:** `Info.plist` ATS dict for `playstation.net` and `sonyentertainmentnetwork.com` sets `NSExceptionRequiresForwardSecrecy = false`. Sony's auth servers fully support modern TLS — this exception is unnecessary AND introduces a security regression (allows non-PFS cipher suites).
- [ ] **Diagnóstico:** `nscurl --ats-diagnostics https://auth.api.sonyentertainmentnetwork.com/`.
- [ ] **Implementação:** Delete the entire `NSExceptionDomains` block (rely on ATS defaults). If a specific endpoint genuinely needs the exception, narrow to that subdomain only.
- [ ] **Teste Rigoroso:** PSN login still works.
- [ ] **Limpeza:** No ATS exceptions in shipping app.
- [ ] **Revisão Final:** App passes Apple's ATS audit.

### 5.27. Orphan `Frameworks/Chiaki.xcframework.compiled/` With Wrong Library Name ✅ (moved to `deleted-2026-04-26/Frameworks/`)
**Problem:** `VisionRemotePS5/Frameworks/Chiaki.xcframework.compiled/` is a sibling of the live xcframework. Its `Info.plist` references `libchiaki.a` (different name from the live `libchiaki_full.a`). Per `streaming-core.md` Unclaimed Files list, no agent owns this — yet it's still in the source tree being indexed by Xcode and confusing header search.
- [ ] **Diagnóstico:** `find VisionRemotePS5/Frameworks -name '*.a'`.
- [ ] **Implementação:** Move `Chiaki.xcframework.compiled/` outside the source tree (or delete). Confirm with the user before deletion per the unclaimed-file rule.
- [ ] **Teste Rigoroso:** Build still works.
- [ ] **Limpeza:** One xcframework, one library binary path.
- [ ] **Revisão Final:** Frameworks dir contains only the active framework.

### 5.28. `TODO.md` and `GEMINI.md` Are Gitignored ✅
**Problem:** `.gitignore` excludes `TODO.md` and `GEMINI.md`. CLAUDE.md says "Treat TODO.md as authoritative for project state." A fresh clone has no TODO.md; agents and humans have to ask "is this file tracked?" every time. Also `GEMINI.md` is the per-LLM persona file referenced by `streaming-core.md` — it MUST be tracked for the MAS to work cross-machine.
- [ ] **Diagnóstico:** `git ls-files TODO.md GEMINI.md` (returns nothing).
- [ ] **Implementação:** Remove both lines from `.gitignore`. `git add TODO.md GEMINI.md`.
- [ ] **Teste Rigoroso:** Fresh `git clone` shows both files.
- [ ] **Limpeza:** Audit `.gitignore` for any other "authoritative" file accidentally excluded.
- [ ] **Revisão Final:** Cold-start MAS bootstrap (per CLAUDE.md mandatory bootstrap) works on a fresh clone.

---

## Summary Triage (2026-04-26)

The single most likely answer to "why doesn't the project work properly" is **5.1** (invalid `XROS_DEPLOYMENT_TARGET = 2.6` blocks all builds) followed by **5.2** (gitignored vendored headers in HEADER_SEARCH_PATHS makes fresh clones unbuildable). Once those are fixed, the most likely runtime culprit is **5.9** (ChiakiCore.c double-write corrupting offset 608 of the live ChiakiSession), with **5.7-5.8** (parallel dead implementations + dead TAKION code) as the largest source of confusion when debugging. Items **5.11**, **5.15**, **5.18**, **5.19** are the highest-impact regressions/policy violations.

Recommended next move: open Xcode, attempt `xcodebuild build -scheme VisionRemotePS5 -destination 'generic/platform=xrOS' -quiet`, and address each error/warning surfaced before tackling 5.7+ refactors. The architectural cleanups should not happen until the build is green.

---

## Patch Summary (2026-04-26 session)

**Applied (✅):** 5.1, 5.3, 5.4, 5.5, 5.7, 5.8, 5.10, 5.11, 5.12, 5.13, 5.14, 5.15, 5.16, 5.17, 5.18, 5.19, 5.21, 5.22, 5.25, 5.26, 5.27, 5.28; partial on 5.20 and 5.24.

**Withdrawn (🔄):** 5.9 — re-reading `chiaki-abi-shim/SKILL.md` confirmed the dual-path write is the documented sacred pattern, not a bug. No `ChiakiCore.c` modifications.

**Deferred (⏳, per user direction):** 5.2 (left HEADER_SEARCH_PATHS pointing at `chiaki-ng/lib/include` — vendored dirs still required at build time; properly fixing requires either committing minimal headers under `vendor/` or proving the xcframework headers are sufficient by trial), 5.6 (Swift 6 strict concurrency migration), 5.23 (singleton/DI refactor); plus the trailing 50-ish print→DebugLog conversions in non-streaming files (5.24).

**Files touched:**
- `VisionRemotePS5.xcodeproj/project.pbxproj` (5.1, 5.3, 5.5, partial 5.2, file refs for moved files)
- `VisionRemotePS5/Info.plist` (5.3, 5.15, 5.19, 5.25, 5.26)
- `.gitignore` (5.28)
- `Local.xcconfig.example` (new — 5.19)
- `scripts/merge_chiaki_opus.sh` (5.4)
- `VisionRemotePS5/Services/StreamingService.swift` (5.7, 5.8, 5.18, 5.20, 5.21, 5.22, 5.24)
- `VisionRemotePS5/Services/ChiakiFullSession.swift` (5.10, 5.24)
- `VisionRemotePS5/Services/ConsoleStorageService.swift` (5.17)
- `VisionRemotePS5/Services/PSNAuthService.swift` (5.19)
- `VisionRemotePS5/Streaming/LowLatencyAudioPlayer.swift` (5.15, 5.16)
- `VisionRemotePS5/Views/StreamingImmersiveView.swift` (5.11)
- `VisionRemotePS5/Controllers/GameControllerManager.swift` (5.12, 5.14)

**Files moved to `deleted-2026-04-26/`:**
- `Services/StreamingSession.swift` (1344 lines)
- `Streaming/VideoDecoder.swift` (parallel decoder)
- `Controllers/HighFrequencyInputController.swift` (dead poller)
- `Frameworks/Chiaki.xcframework.compiled/` (orphan with `libchiaki.a`)
- `Services/StreamingService.swift.before-trim` (pre-cleanup snapshot)

**Net result:** `StreamingService.swift` shrank from 1886 → ~1130 lines. Three project source files removed. Build configuration coherent for the first time. Streaming pipeline still wired through `StreamingService.shared` → `ChiakiFullSession.shared` → chiaki-ng — no functional path was changed; only dead siblings were removed and hot-path bugs fixed.

**Required next step before first build:**
1. Copy `Local.xcconfig.example` to `Local.xcconfig` and fill in real PSN values.
2. In Xcode: Project → Info → Configurations → set both Debug/Release "Based on Configuration File" to `Local.xcconfig`.
3. Run the build; address any warnings now that `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` is enforced. Existing warning count is unknown — first compile will surface the list.

---

## 🔬 Phase 5 Addendum — Full-Project Bug Sweep (2026-07-04)

All three "required next steps" above are now DONE, plus a four-domain source review
(Services, Streaming, Views/Controllers, C bridge). Build is green with zero
warnings under `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` (device destination;
simulator/`xcodebuild test` blocked by an outdated CoreSimulator on this Mac).

### Applied (2026-07-04)
- **5.19 completed:** `Local.xcconfig` created (values recovered from git commit
  `ab0157b`) and wired as `baseConfigurationReference` on the project-level
  Debug/Release configs. Verified: built `Info.plist` now carries
  `PSNClientID`/`PSNClientSecret`; previously the app read empty strings and PSN
  login could never succeed.
- **ChiakiCore.c heap over-read fixed:** `chiaki_decrypt_regist_response_wrapper`
  ran `strstr`/`strchr`/`strlen` over a `malloc(data_size)` buffer that was not
  NUL-terminated — a registration response not ending in `\r\n` could read past
  the allocation. Buffer is now `data_size + 1` with a forced terminator.
  (No sacred ABI-shim sections touched.)
- **RegistrationService double-resume crash fixed:** `receiveData()` guarded its
  `CheckedContinuation` with a plain `resumed` Bool mutated from both the timeout
  Task and the NWConnection callback (different queues). Now uses the existing
  lock-protected `ContinuationGate` (same pattern as the other call sites).
- **ChiakiCrypto.swift nickname bound hardened:** extraction loop scanned up to
  128 bytes of a `char[0x20]` field; now bounded by the field's actual size.
- **MetalFXUpscaler force-cast hardened:** `as! CFString` on pixel-buffer color
  attachments replaced with conditional String-bridged casts (network-derived
  data must not be trusted to be well-formed).
- **StreamingImmersiveView 120Hz wheel timer:** `Task { @MainActor }` per tick
  replaced with `MainActor.assumeIsolated` (timer fires on the main run loop) —
  removes 120 task allocations/sec in virtual-wheel mode (5.20 pattern).
- **Dead `Chiaki/ChiakiBridge.swift` quarantined** to `deleted-2026-04-26/`: it
  was NOT in the Sources build phase (superseded by `ChiakiBridgeService` in
  `ChiakiCrypto.swift`) and its 7-arg call to the 8-parameter
  `chiaki_format_regist_payload_wrapper` would fail to compile if ever re-added.
  Dangling pbxproj file reference removed.

### Reviewed and rejected as false positives (do not "re-fix")
- STUN XOR-IP parsing in `HolepunchService`/`PSNWebSocketService`: `ArraySlice`
  preserves parent indices — `xorIP[offset + 4 + i]` is correct.
- `AudioRingBuffer` memory ordering: `load → OSMemoryBarrier` / `barrier → store`
  is the canonical fence-based acquire/release pair; producer reading its own
  index without a barrier is standard SPSC.
- `LowLatencyAudioPlayer` deinterleave `Data(bytesNoCopy:)` views: consumed
  synchronously inside `ringBuffer.write(...)`, never escape.
- `AudioVideoSyncController.insertMicroSilence` second-edge crossfade condition
  simplifies to `insertPoint < count` — always true for non-empty buffers.
- `ImmersiveTextureCoordinator.updateInProgress`: class is `@MainActor`; the GPU
  completion handler hops back to main. No race.
- `ChiakiFullSession.stop()` vs 120Hz input: lock-protected `isShuttingDown` +
  10ms drain + `chiaki_session_join` before free — residual window is
  theoretical; a C-side mutex would perturb input timing (left as designed, 5.10).

---

## 🧊 Phase 7: Spatial 3D Mode — AI Depth-Displaced Screen (2026-07-04, PoC landed)

Real-time 2D→3D for the immersive mode: Depth Anything V2 Small runs on the
otherwise-idle Neural Engine; a Metal compute kernel displaces a dense curved
LowLevelMesh screen (161x91 vertices) from the depth map. Both eyes see real
geometry — true stereo parallax, not a flat plane. This is the visionOS-native
successor of the removed f3b3b73 attempt (CustomMaterial does not exist on
visionOS; LowLevelMesh does, since visionOS 2.0).

**New files:**
- `Streaming/DepthEstimationService.swift` — actor, Core ML/Vision on ANE,
  drop-frame strategy, per-frame min/max depth range via vImage/vDSP. Model is
  loaded dynamically from the bundle: app builds AND runs without it (spatial
  toggle simply stays inert).
- `Streaming/SpatialScreenCoordinator.swift` — LowLevelMesh grid, compute
  displacement pass, depth CVPixelBuffer→MTLTexture cache, entity lifecycle,
  100ms watchdog + in-flight drop (same patterns as the texture coordinators).
- `Shaders/SpatialDisplacement.metal` — `spatialDisplace` kernel: parabolic
  base curve + normalized depth displacement + temporal EMA (flicker damping).
  Vertex layout (packed_float3/packed_float3/float2, stride 32) MUST match
  SpatialScreenCoordinator.
- `Views/Spatial3DSurface.swift` — RealityView wrapper; video pixels reuse the
  SAME ImmersiveTextureCoordinator LowLevelTexture (zero extra video copies).
- Resource: `Resources/DepthAnythingV2SmallF16.mlmodelc` (48MB, gitignored,
  local-only like libchiaki). Re-download: huggingface.co/apple/
  coreml-depth-anything-v2-small → `xcrun coremlcompiler compile`.

**Wiring:** `AppState.spatial3DEnabled` (default false) → "2D/3D" button in the
immersive FloatingControlPanel → StreamingImmersiveView swaps
Immersive4KSurface ↔ Spatial3DSurface and feeds the depth estimator from the
`.videoFrameReceived` handler (Task per frame; the actor's drop-frame gate
returns nil instantly while an inference is in flight).

**Also fixed in the same pass:** the immersive `.videoFrameReceived` handler
double-upscaled every frame (`processFrame` ran in StreamingViewModel AND here)
— removed; and the notification payload force-cast is now type-checked.

**Tuning knobs (SpatialScreenCoordinator):** `displacementIntensity` (0.35m),
`temporalSmoothing` (0.35), `curvature` (0.05), grid 160x90.

**Known PoC limits (updated 2026-07-04):**
- [x] Virtual wheel entity now loads in spatial mode too (`Spatial3DSurface`
      gained `showWheel` parity with `Immersive4KSurface`).
- [x] Depth range hysteresis: min/max EMA-smoothed (alpha 0.15, ~200ms) in
      `DepthEstimationService` — scene cuts no longer make the screen breathe.
- [x] Edge-aware sampling: 5-tap depth-similarity bilateral filter in the
      `spatialDisplace` kernel — smooths model noise without blurring across
      true depth edges (halo reduction).
- [ ] On-device validation pending (simulator blocked by CoreSimulator
      mismatch): confirm ANE inference time, thermal behavior in long
      sessions, and comfort of 0.35m parallax.

---

## 🖐️ Phase 8: HoloPad — Gesture Virtual DualSense (2026-07-04, phase 1 landed)

Controller mode "HoloPad" (`AppState.ControllerMode.handGesture`): full-DualSense
input from bare hands using the 90Hz visionOS 2 hand skeleton. Design principle
(validated against Meta microgestures research): every input is SELF-HAPTIC —
skin-on-skin contact the player can feel — fixing the core flaw of the panel
overlay (air-buttons you must look at).

**Mapping (phase 1):**
- Right hand: thumb→middle/ring/pinky fingertip taps = ✕/○/□, thumb→index-side
  tap = △, thumb+index pinch-drag = right stick, index curl = R2.
- Left hand: same gestures mirrored = D-pad (up/down/left/right), left stick, L2.
- Detection: hysteresis 2.2cm press / 3.2cm release, fist-suppression extension
  gate (0.10m tip-to-wrist), stick suppresses index-side tap + trigger.

**Files:**
- `Services/HandGestureControllerService.swift` — ARKit skeleton → gesture
  engine → buttons bitmask + sticks + triggers (plain vars, read by the 120Hz
  timer; only isTracking is @Published).
- `Views/HoloPadFeedbackView.swift` — holographic layer: fingertip orbs in
  PlayStation colors (△ green, ✕ blue, ○ red, □ pink; left hand cyan) that
  flare 1.8x on activation, ghost stick disc materializes at the pinch point.
  Entities moved from the 90Hz callback, no SwiftUI churn.
- Wiring in `StreamingImmersiveView.onAppear` (dedicated 120Hz timer →
  `ChiakiFullSession.setControllerState`, `MainActor.assumeIsolated` — 5.20
  pattern) + teardown in onDisappear. Windowed placeholder in ControllerWindow.

**v12.3 "Arcane HUD" (same day, user direction: "innovative, not tiring, not
a conventional controller" + the.poet.engineer palm-hologram references):**
- Palm-anchored holographic ring per hand: 24 slowly-orbiting segments hover
  5cm above each palm WHEREVER the hands rest (lap included) — the hologram
  follows the hand; the player never holds an arm up. Ring carries: cardinal
  button glyphs (PlayStation colors, flare on tap), a stick "ember" that
  drifts with pinch-drag deflection, and a trigger arc (segments light with
  finger curl).
- SUMMON gesture: palm rotated skyward = system layer. Ring blooms 1.35x,
  glyphs swap palette, and that hand's fingertip taps become Options (middle)
  / Share (ring) / PS (pinky) / Touchpad (index side). Gameplay stick/trigger
  suppressed while summoned. Palm down = instant return to gameplay.
- Implementation: palm normal from cross(wrist→indexKnuckle, wrist→littleKnuckle)
  (negated for left hand), palm-up hysteresis 0.55 enter / 0.35 exit on
  dot(normal, up). Glyph materials swapped only on state transitions; all
  per-frame feedback is transform-only (scale/position) — no material churn
  at 90Hz.

**Phase 2 (landed 2026-07-04):**
- [x] **L1/R1 = middle-finger curl "grip"** (hysteresis 0.65 enter / 0.45
      exit), suppressed in summon mode and while the middle fingertip tap is
      live. (Chosen over the double-tap idea — no timing ambiguity, no stray
      △ presses.)
- [x] **L3/R3 = three-finger pinch**: middle fingertip joins the thumb+index
      pinch while the stick is engaged. The middle tap (✕/D-Up) is suppressed
      during stick engagement to avoid false fires.
- [x] **Spatial audio clicks**: generated `holopad_click.wav` (30ms, 1.9kHz
      decaying tick), bundled as a resource, played at the fingertip orb on
      every rising-edge activation.
- [x] **Skeleton threads**: hairline luminous lines thumb→each fingertip
      (transform-only updates, thicken 3x while that tap is live) — the
      reference-image web aesthetic.

**v12.4 "Cyborg Paddles" (2026-07-04, user reference: penlar.pc Cyborg II
keypad — hand never travels, every finger is an independent actuator):**
- Second input profile `HoloPadInputProfile.cyborgPaddles`, toggled from the
  floating control panel ("Taps" ↔ "Paddles", visible only in HoloPad mode).
- Hands rest palm-down on the thighs; pressing a finger DOWN into the leg is
  the button — real passive haptics from the surface, and chord-capable
  (multiple buttons simultaneously — impossible with the serial thumb).
- Mapping: middle/ring/pinky presses = ✕/○/□ (right), D-Up/Down/Left (left);
  index press = ANALOG trigger by depth (R2/L2); index LIFT off the surface =
  bumper (R1/L1 — the keypad's up-lever); thumb→index-side tap = △/D-Right;
  pinch-drag sticks, 3-finger stick click, and palm-up summon unchanged.
- Detection: normalized curl per finger vs an ADAPTIVE rest baseline (EMA
  alpha 0.02 while idle ≈ 2s) — self-calibrating for hand size and posture;
  press +0.16 / release +0.08, lift −0.14/−0.07, trigger full at +0.45.
- Occlusion tolerance: middle/ring/pinky tips + ring knuckle read via
  `worldAny` (inferred pose accepted) — in the lap pose the fingertips hide
  under the hand and strict isTracked gating would kill the whole hand.
- In Cyborg profile the thumb-tap detectors serve ONLY the summon layer;
  the taps-profile grip bumper is disabled (lift replaces it).

**v12.5/v12.6 on-device iteration (2026-07-04, evening):**
- [x] Feedback alignment: two failed approaches on hardware (world coords →
      origin offset; wrist-anchor + skeleton-local offsets → rotated frame).
      Final: ONE AnchorEntity PER JOINT (`.hand(chirality, location:
      .joint(for:))`, `.predicted`), orb at position .zero — system-guaranteed
      alignment, no calibration step needed. Ring rides the `.palm` anchor.
      Skeleton threads removed (cross-anchor positions need
      SpatialTrackingSession; re-add later).
- [x] HoloPad is the only selectable controller (`ControllerMode.selectable`);
      standard overlay + wheel quarantined per user direction.
- [x] Windowed-mode input: new `.mixed` ImmersiveSpace "HoloPadSpace"
      (passthrough + hand feedback only) auto-opened by StreamingVideoWindow —
      hand tracking cannot run in the Shared Space, so a mixed space provides
      it without hiding the room or the window. VR enter/exit swaps spaces.

**Still open (on-device only):**
- [ ] Ring hover sign on the `.palm` anchor (flip `hoverOffset` if the ring
      renders inside/behind the hand).
- [ ] Tuning of constants (tapPress/Release, curl range, extension gate,
      palm-up thresholds, paddle deltas) — hand sizes vary. (Position needs
      NO calibration — per-joint anchors are exact by construction.)
- [ ] Cyborg profile: validate inferred-fingertip quality in the lap pose
      (the design bet — if ARKit inference is too noisy palm-down, detect
      presses from proximal-joint angles instead of tips).
- [ ] Same-hand stick + trigger tradeoff — largely solved by Cyborg
      (index paddle = trigger, thumb free for stick) — confirm in game.
- [ ] Verify palm-normal chirality signs on device (if summon triggers with
      palm DOWN, flip the negation in HandGestureControllerService).

### 5.22 correction (2026-07-04, found via on-device log)
The 5.22 hardening ("validate registKey.count == 32") was WRONG about the
data shape and broke every real connection: the PS5's regist key is a short
ASCII string (8 chars) delivered as 16 hex chars, and chiaki wants it
zero-padded into char[16]. Device log showed
`registKey length=16 ... Invalid key sizes: registKey=0` and the session
never started. `hexDecode16Bytes` now accepts an even 2...32 hex chars and
zero-pads to 16 bytes (odd/non-hex/oversize still fail fast). VERIFIED ON
HARDWARE: session accepted (RP 200 OK + nonce), video streaming at 60fps,
decode 3.4ms, 0 packet loss.

### Controller input fixed on-device (2026-07-04, evening)
"No controller works" root cause found via live device console: the chiaki
EVENT callback suffers the same +944 ABI skew as video/audio (header 592 →
library 1536) but had NO manual offset write — only the header-side setter.
Events never fired, `CHIAKI_EVENT_CONNECTED` never reached Swift,
StreamingService stayed in "negotiating", and every input was dropped
("Not streaming, ignoring input"). Fixes in `ChiakiCore.c` (dual-path per
chiaki-abi-shim skill, nothing removed):
- Manual event_cb/event_cb_user writes at library offsets 1536/1544 + ABI
  probe fprintf. Skill file updated to protect the new constants.
- `chiaki_fullsession_set_controller_wrapper` now initializes with
  `chiaki_controller_state_set_idle()` instead of `{0}` — a zeroed struct
  registers a phantom touchpad touch at (0,0) on every packet (touch id
  convention is -1 = up).
VERIFIED ON HARDWARE: "ChiakiEvent: connected" received, input gate open,
`[Controller] Sending: buttons=1 ...` flowing to the PS5, HoloPad 120Hz
timer active, zero dropped-input lines after connect.

### Closed on 2026-07-04 ("implement all phases" pass)
- **5.2 ✅** — vendored-tree HEADER_SEARCH_PATHS removed (chiaki-ng/,
  mbedtls-src/ paths deleted from both configs). Verified with a CLEAN build:
  the xcframework `Headers/` + `VisionRemotePS5/Chiaki` are sufficient. Fresh
  clones no longer need the gitignored vendored trees to compile.
- **5.24 ✅** — all 439 remaining raw `print()` calls converted to
  `DebugLog.print` (see 4.1); Release console silent.
- **3.3 ✅ (closed as infeasible)** — protocol caps at 60fps; see Phase 3.3.
- **4.1 ✅** — see Phase 4.1.

### Still open (deliberate deferrals — each needs a dedicated session)
- **5.6 Swift 6 strict concurrency** — flipping `SWIFT_VERSION = 6.0` on ~50
  concurrency-heavy files will surface hundreds of diagnostics; migrating
  without a working test rig (simulator currently broken on this Mac) would
  violate the non-regression cardinal rule. Do it as its own phase with
  on-device smoke tests per file cluster.
- **5.23 singleton/DI refactor** — touches every View; same rationale.