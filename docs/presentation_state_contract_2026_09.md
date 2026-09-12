# Presentation lifetime contract — version 1.1

Task 02.01, initially specified on 2026-09-09 against `d9c044d` and the existing
local measurement changes. Version 1.1 clarifies failure recovery during the
[02.02 coordinator implementation](presentation_coordinator_2026_09.md): T15/T38
retain a presentation error regardless of when the fallback becomes ready.
The app still uses window presentation. The subsequent
[02.03 integration](presentation_window_lifecycle_2026_09.md) connects the
coordinator to window/service adapters. Its physical close/reconnect check was
confirmed by the user on 2026-09-09. The subsequent
[cinema delivery](cinema_and_image_comparison_2026_09.md) implements the actual
immersive scene/renderer, surface admission and OS actions. Its physical
transition/quality checks await the user's new test; host results do not replace them.

The user's request to continue is applied to this bounded specification and
host consistency review while 01.08 remains open. Its eight-run CPU result is
inconclusive and its current-study condition/function confirmation is pending.
This sequencing exception does not change the
[performance acceptance policy](performance_acceptance_2026_09.md), waive
01.08, or approve a presentation effect. 01.03 remains waived and 01.10 deferred.

## Ownership at the 02.01 inspection

The following table records the starting path, before the 02.02/02.03 changes.
Current ownership and validation are detailed in the integration report above.

| Component | Responsibility at inspection | Consequence for implementation |
| --- | --- | --- |
| [AppState](../VisionRemotePS5/VisionRemotePS5App.swift) | The app's `StateObject` retains the shared `StreamingViewModel`; UI flags drive navigation. | Retain the future presentation coordinator here. Flags such as `isConnected` are asynchronous mirrors, not a session lock. |
| [HomeView.startSession](../VisionRemotePS5/Views/HomeView.swift) | Selects a console and opens `StreamingWindow`. | Reserve one connection attempt before opening a view or awaiting authentication. |
| [StreamingViewModel](../VisionRemotePS5/Views/StreamingView.swift) | Prepares credentials/configuration, awaits authentication, calls the service and mirrors delegate state. | A reserved attempt must guard both sides of every startup await, including authentication before the service has a metrics session ID. |
| [StreamingService](../VisionRemotePS5/Services/StreamingService.swift) | Owns the transport, decoder, audio, controller manager and input gate. Native video callbacks carry the metrics session into the mailbox. | Remain the sole runtime session owner. Its `stopStreaming()` returns before the native join and `.stopped`; `.error` also does not prove complete teardown. |
| [StreamingVideoWindow](../VisionRemotePS5/Views/StreamingVideoWindow.swift) | Its task enables delivery/starts the shared VM; `onDisappear` stops the service, disables delivery and clears AppState. | Retiring this consumer during a transfer must not perform that global termination. A duplicate view task must not start another connection. |
| [VideoDelivery / UpscalingPipeline](../VisionRemotePS5/Streaming/UpscalingPipeline.swift) | Global latest-frame mailbox with session identity, plus presentation processing settings. | Preserve the mailbox session across a presentation switch. Only actual termination/reconnection ends/replaces that session. |
| [MetalTextureView](../VisionRemotePS5/Views/MetalTextureView.swift) | Per-view renderer and GPU work; completion handlers retain submitted resources. | Consumer disappearance and service `.stopped` do not prove GPU completion or deallocation. |

At the 02.01 inspection there was no `ImmersiveSpace`, presentation coordinator
or `scenePhase` adapter. Task 02.02 added the AppState-owned coordinator core;
02.03 added its driver, window/service adapters and aggregate app-phase hook.
The subsequent cinema delivery adds the immersive scene/renderer using this
ownership contract. The historical path inventory predates those changes;
source and the cinema report are the references for current ownership.

## Platform facts and project decisions

The installed Xcode 27 (`27A5252f`) SDK declares `OpenImmersiveSpaceAction` and
`DismissImmersiveSpaceAction` as `@MainActor`, asynchronous, nonthrowing actions
available since visionOS 1.0. The app's minimum remains visionOS 2.0. Local
signature evidence is in
`/Applications/Xcode-beta.app/Contents/Developer/Platforms/XROS.platform/Developer/SDKs/XROS.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-xros.swiftinterface`
at lines 10895–10911 and 14990–14991 in this SDK.

Opening returns `.opened`, `.userCancelled` or `.error` after presenting the
space or failing. Another open while a space is already open fails. `.opened`
does not certify a PS5 frame, focus transfer or physical presentation.
[Apple: OpenImmersiveSpaceAction](https://developer.apple.com/documentation/swiftui/openimmersivespaceaction)

Dismissal has no target ID and returns after closing the currently open space,
if any. **A late dismissal must finish before any subsequent open is allowed.**
The serialization requirement is a project decision derived from that API.
[Apple: DismissImmersiveSpaceAction](https://developer.apple.com/documentation/swiftui/dismissimmersivespaceaction)

A view's `scenePhase` describes its scene; reading it at the app level aggregates
the scenes. `.inactive` can be temporary, including alerts. Closing the last
nonimmersive scene can produce `.background` without an immediate `onDisappear`.
These events are not interchangeable.
[Apple: ScenePhase](https://developer.apple.com/documentation/swiftui/scenephase),
[window life cycle](https://developer.apple.com/documentation/visionos/handling-the-window-life-cycle-with-multiple-scenes),
[Go beyond the window](https://developer.apple.com/videos/play/wwdc2023/10111/)

The following are project policies to implement and test, not promises from
SwiftUI:

- The app-owned coordinator survives view tasks and serializes presentation
  decisions on the main actor. It never waits in the input tick, decoder
  callback or while holding the mailbox lock.
- Busy open/return requests are rejected; there is no unbounded request queue.
  Cancellation of the current opening and explicit stop are the exceptions
  described below. A rejected request is not silently replayed later.
- `.inactive` and one scene entering background do not stop the transport.
  Aggregate app `.background` requests termination. Resuming does not reconnect
  automatically; explicit start is allowed after cleanup. The app-level adapter
  was wired in 02.03; headset behavior still requires 02.09 validation. Abrupt process termination
  cannot be assumed to run asynchronous cleanup.

## Identities, ownership and barriers

`S` is a **logical session lease**, reserved by the AppState-owned coordinator
before the first startup await. It grants exactly one VM startup and one
effective service stop. The service remains the sole owner of live streaming
resources; neither window nor immersion owns a separate connection. A lease
exists while startup is pending and throughout termination, even if no native
session was created.

Keep four identities distinct: the startup lease `S`, the existing mailbox /
metrics session generation `G` assigned by the service, each presentation
operation `O`, and each concrete surface registration `W` or `I`. Bind `G` to
`S` when available. Do not use the late-created `G`, console identity, a Boolean
or the view type as the only startup/operation identity. Capture immutable IDs
in callbacks; check them after every await and before mutating current state.

At most one registered surface has permission to acquire/submit new video work
and act as the selected gamepad event target. Preparing another surface does
not grant either permission. At handoff, revoke the outgoing surface's future
submissions before enabling the incoming one; already-submitted GPU work may
complete normally. The single service-owned input controller continues its
existing tick independently of these presentation permissions. Real event
delivery and neutralization still require 02.07/02.08 tests.

An app-wide operation slot admits at most one SwiftUI open or dismiss call.
It records the lease, operation ID, awaited action, known space presence and
abort reason. Never clear it just because its task was cancelled, a view went
away, the lease was invalidated, or a deadline expired. An outstanding open
must resolve; a late `.opened` after abort/stop requires compensating dismissal
under the same exclusive slot. Only after that dismissal resolves may another
operation open a space. The coordinator, not a disappearing view's `.task`,
retains this responsibility.

Termination joins two barriers before releasing `S`:

1. **Startup/transport:** invalidate startup permission, cancel and settle any
   authentication/start task, close the input gate, neutralize/tear down input
   once, end `G`, and await actual service teardown/native callback join. The
   service method returning, a VM Boolean or a metrics end event is insufficient.
   A start that never reached the service must also settle without later starting it.
2. **Presentation:** settle every outstanding open/dismiss action and dismiss
   any space it opened. No old operation may subsequently close a new space.

Already-submitted GPU work retains its own buffers/textures until completion.
Its callbacks must remain scoped to their old `S/G/surface`; teardown does not
rewrite them to a new generation. This resource lifetime is separate from the
two barriers and is not a claim that service stop drains the GPU.

## State and transition table

Transport phase is orthogonal: `reserved`, `starting`, `running`, `stopping`,
`ended`. For example, a connected-looking window is not evidence of `running`.
Only the service's current-lease connection acknowledgement enables input.
`error` below means a recoverable **presentation** error with the fallback
window ready; transport/authentication failure enters `terminating` with a
reason retained for display after termination.

<!-- presentation-states:start -->
| State | Lease | Meaning |
| --- | --- | --- |
| idle | none | No request, transport or presentation operation. |
| starting | S | Lease reserved; waiting for the initial window registration. |
| windowed | S | Window is the selected consumer; transport may still be starting. |
| opening | S | Window retained; opening or preparing immersion, possibly aborting. |
| immersive | S | Immersive consumer selected; outgoing window may be retired. |
| recoveringWindow | S | Window requested/recovered before completing return; space may still be open. |
| closing | S | Window ready and dismissal outstanding, or dismissal finishing after a surface loss. |
| error | S | Window fallback ready; recoverable presentation failure displayed. |
| terminating | S | Startup is invalidated and transport/presentation cleanup is still owned. |
| terminated | none | Both barriers complete; reason may be displayed; explicit start permitted. |
<!-- presentation-states:end -->

The rows form a guarded decision table. `same` preserves the exact source state
or lease, `new S` reserves a fresh lease, and `*` covers all states. First apply
identity validation and termination precedence, then the applicable row. A
callback for the outstanding cleanup slot is **not** discarded as stale merely
because startup was invalidated. Registered candidate/fallback surfaces and
unconsumed retirement permits also remain participants even when not selected.
The final row rejects any remaining event.
Guards partition outcomes; the checker validates references/ownership, not
their runtime implementation.

<!-- presentation-transitions:start -->
| ID | From | Event / guard | To | Lease after | Required action |
| --- | --- | --- | --- | --- | --- |
| T01 | idle,terminated | Explicit start; service quiescent and operation slot empty | starting | new S | Reserve before await; request one window registration; do not start via repeated view tasks. |
| T02 | starting | Current window mountReady, without requiring G | windowed | S | Grant one startup for S; authentication and service callbacks must revalidate S. |
| T03 | windowed,error | Enter immersion; transport running, window ready, slot empty | opening | S | Allocate O; keep W valid; issue one open; preserve G, input and audio. |
| T04 | windowed,error | Enter immersion; any T03 precondition missing | same | S | Reject with a recoverable status; do not enqueue or reconnect. |
| T05 | opening | Open result opened; no abort pending | opening | S | Record result; release the completed await, retain the transition; wait for T07 readiness. |
| T06 | opening | Current immersive consumer readiness arrives | opening | S | Record readiness even if open result is pending; do not select it yet. |
| T07 | opening | Opened AND consumer ready AND no abort AND current S/O | immersive | S | Transfer selection/focus to I once; retain its identity and W's retirement permit, finish O; never stop service or disable global mailbox. |
| T08 | opening | Cancel/return or readiness failure; open await still pending | opening | S | Latch abort and destination windowed or error; retain O until its result. |
| T09 | opening | Cancel/return or readiness failure; open already resolved opened | closing | S | Issue one compensating dismiss; fallback W is still retained. |
| T10 | opening | Open result opened with abort pending, or future unknown result | closing | S | Issue compensating dismiss under O; unknown result retains failure reason/unknown presence; never select I. |
| T11 | opening | Open result userCancelled; no readiness failure recorded | windowed | S | Restore W focus, clear O; no automatic retry. |
| T12 | opening | Open result error, or userCancelled after readiness failure | error | S | Restore W focus, clear settled O and show recoverable reason; do not restart transport. |
| T13 | immersive | Return to window | recoveringWindow | S | Allocate a return O and request/restore W; retain I and transport while waiting for W. |
| T14 | recoveringWindow | Current W ready; space open/unknown and no open/dismiss await | closing | S | Select W; issue one dismiss, preserving S/G/audio/input. |
| T15 | recoveringWindow | Current W ready; space absent, all OS awaits settled and no failure reason | windowed | S | Select W; clear settled transition and recover focus. |
| T38 | recoveringWindow | Current W ready; space absent, all OS awaits settled and failure reason retained | error | S | Select W; clear settled transition and display the retained failure, consistent with T17. |
| T16 | closing | Dismiss completes; W ready and no failure reason | windowed | S | Clear O; select W and recover focus; no transport start/stop. |
| T17 | closing | Dismiss completes; W ready and failure reason retained | error | S | Clear O; select W and display reason; no automatic retry. |
| T18 | closing | Dismiss completes; W unavailable without explicit termination | recoveringWindow | S | Clear settled O; request W; keep S until recovery or termination. |
| T19 | immersive | Current immersive surface dismissed/lost, or adapter reports failed handoff | recoveringWindow | S | Allocate recovery O, record consumer loss/failure and request W; OS space presence stays open/unknown until dismissal settles. |
| T20 | opening | Current immersive surface lost before handoff | opening | S | Latch readiness failure; reconcile through T08/T09, including any late opened result. |
| T21 | closing,recoveringWindow | Current immersive surface disappears | same | S | Record consumer loss, not OS absence; an outstanding dismiss still must resolve; reconcile window readiness. |
| T22 | opening,closing,recoveringWindow | Additional presentation request, excluding opening cancel/return | same | S | Reject busy; preserve the current operation and session. |
| T23 | immersive | Enter immersion again | immersive | S | Already selected; no new open or connection. |
| T24 | windowed,error | Return to window again | same | S | Already selected; do not reconnect. |
| T25 | starting,windowed,opening,immersive,recoveringWindow,closing,error,terminating | Additional start, same or different console | same | S | Reject while lease exists; reconnect requires explicit termination then a new start. |
| T26 | windowed,opening,immersive,recoveringWindow,closing,error | Outgoing window disappears with valid retirement permit | same | S | Consume permit for exact S/O/W; detach only that consumer, preserving G. |
| T27 | starting,windowed,opening,recoveringWindow,closing,error | Current required window lost/closed without a retirement permit | terminating | S | Treat loss as session-ending outside authorized handoff; begin both barriers. |
| T28 | starting,recoveringWindow | Window recovery/mount deadline expires | terminating | S | Report unavailable fallback and begin both barriers; do not leave an orphaned session. |
| T29 | starting,windowed,opening,immersive,recoveringWindow,closing,error | Explicit stop, startup/transport/clock failure or remote quit | terminating | S | Invalidate startup; stop service once and drain presentation even on error. |
| T30 | starting,windowed,opening,immersive,recoveringWindow,closing,error | Aggregate app background | terminating | S | Apply the defined suspension policy; resume requires explicit start after cleanup. |
| T31 | * | Inactive, active, individual scene background or focus change | same | same | Do not infer transport stop/start or space closure; reconcile focus separately. |
| T32 | terminating | Owned open resolves opened or a future unknown result | terminating | S | Dismiss under the retained slot, retaining any failure/unknown presence; prohibit any new open/start. |
| T33 | terminating | Owned open resolves cancelled/error, dismiss completes, or startup/service settles | terminating | S | Record the corresponding barrier progress; release nothing until both complete. |
| T34 | terminating | Both barriers complete | terminated | none | Release S and clear current UI selection once; retain only displayable outcome. |
| T35 | terminating | Repeated stop, failure, background, cancel or surface loss | terminating | S | Keep cleanup owned; do not issue duplicate stop/dismiss calls. |
| T36 | * | Duplicate/stale callback or nonparticipating surface, excluding owned transition/permit/cleanup | same | same | Ignore state mutation; release callback-owned resources safely, never touch new S/G. |
| T37 | * | Otherwise: unsupported request, unmet guard or unrecognized event | same | same | Reject/no-op with bounded diagnostic status; no implicit ownership change or queued retry. |
<!-- presentation-transitions:end -->

Initial `mountReady` means W has registered against the reserved S and can show
connection status. It requires neither G nor a decoded frame: G is created only
after T02 permits startup. The initial window task does not start transport a
second time when G later becomes available.

For an existing stream, `ready` means the current surface has registered its consumer and gamepad event
handling, has access to `G`, and can accept the adapter's focus handoff. Selection
and the focus request occur together at handoff, not when the incoming view
first appears. Failure before selection aborts opening; failure reported after
selection recovers W via T19. This does
not mean a first video frame or a physical focus/input test passed.
Video, decoder and input continue independently while these UI steps run. Do
not wait for a PS5 frame to allow returning to the window. The platform adapter
must produce T07 after either ordering of opened/readiness and only once.

Before handoff, keep W registered and recoverable. A retirement permit is issued
only for the outgoing W at successful T07, bound to `S/O/W` and consumed once.
It cannot authorize any new or unrelated window disappearance. SwiftUI's
`onDisappear` does not identify user intent; outside an exact permit, losing the
required streaming window requests termination. OS visibility changes that do
not unregister a consumer are not a close event. Event classification is wired
in 02.03; its ordinary window closure/reconnection check was confirmed on the
device. There is no assumed platform "user closed"
callback. A late disappearance of an already detached surface is T36.

A retiring W1 cannot become the required window again while its detach/close
is pending. Return waits for its detachment and requests a distinct W2
registration; a late W1 callback retains W1's identity and cannot consume W2's
permissions. If the platform reuses a window instance, its adapter must finish
the old registration before binding a fresh one. Do not invalidate a permit
and then relabel an old disappearance as a close of the new consumer. Failure
to obtain a safe registration follows the fallback deadline, not an implicit
reuse of W1.

Consumer loss is also distinct from OS space absence. An immersive
`onDisappear` cannot by itself satisfy T15 or the presentation termination
barrier. If the space is open or its presence is unknown after an open,
complete a serialized dismiss before declaring it absent or allowing another
open. A dismiss that finds the system has already closed the space is harmless;
the operation must still settle.

For the first implementation, use an injected monotonic 10-second deadline for
initial/fallback window readiness and for immersive consumer readiness after
`.opened`. These are proposed recovery timeouts, not measured latency budgets.
Initial/fallback timeout follows T28; immersive readiness timeout follows
T08/T09 and returns an error to the retained W. A timeout on a still-awaited OS
action may show a waiting/error status or request termination, but cannot
declare that action cancelled or free its slot. Numeric timeouts need physical
review in 02.06/02.09; no finite SwiftUI completion bound is claimed.

An early current timer callback re-arms the same absolute deadline without
extending the budget or adding another timer. A non-finite/regressing clock, or
one unable to represent the deadline, requests termination with
`clockUnavailable`; it never fabricates an expiry or silently consumes the
only timer callback. Outstanding OS work still drains through the two barriers.

## Verification and implementation handoff

Run `python3 scripts/check_presentation_contract.py`. It parses these tables,
checks all state/transition references and destination ownership, restricts
lease changes to startup and completed-termination edges, and checks graph
reachability to termination. Its scope is structural
consistency of this specification. It does not execute the SwiftUI guards,
async scheduling, transport, focus or GPU behavior.

Review scenarios for the 02.02 coordinator host suite (core validation status
and remaining adapter limits are recorded in its implementation report):

1. Duplicate start while waiting for W or authentication: exactly one lease and
   startup; stop during authentication prevents the resumed task starting transport.
2. Open result before/after consumer readiness: same final S/G, exactly one
   handoff, no global delivery disable, and no wait for a video frame.
3. Cancel/error/unknown opening result and readiness timeout: W/focus recover,
   no automatic retry; late opened after abort receives one compensating dismiss.
4. Stop A during opening, request B, then receive A's opened: B is rejected until
   A's dismissal and service/startup teardown finish. No A action can close B.
5. Out-of-order/duplicate dismiss, delegate, surface and GPU callbacks: only the
   matching S/G/O/surface changes current state; resources remain valid until
   their actual work completes.
6. Window retirement during handoff versus required-window loss outside it:
   preserve the former session and terminate the latter; never exempt all view
   disappearances with a single `isTransitioning` Boolean. Return before W1's
   retirement completes must use a safe W2 registration; late W1 events cannot
   hide loss of W2.
7. System immersive dismissal, failed fallback window, remote quit and stop
   during closing: every path retains an owner until both barriers finish.
   Losing I is not proof of OS space absence; unknown presence drains a dismiss.
8. Temporary inactive versus aggregate background; repeated stop and rapid
   reconnect: no duplicate transport, input controller or dismissal.

02.01 acceptance covers the documented destinations/owners and host structural
check. The coordinator/reducer is 02.02; service/scene adapters and idempotence
are 02.03–02.06; physical event capture, neutralization, suspension and 20-cycle
validation remain 02.07–02.10. No immersion, performance or physical transition
success is inferred from this document.
