# Presentation coordinator — task 02.02

Implemented on 2026-09-09 on `docs/active-streaming-paths`, starting at `d9c044d`
with the existing uncommitted measurement work preserved. The user's request
to continue is applied to the coordinator core, host tests and app compilation.
01.08 remains open/inconclusive with current-study condition/function confirmation
pending. This sequencing extension does not change performance acceptance or
approve an immersive effect; 01.03 remains waived and 01.10 deferred.

This report records the state at completion of 02.02. The subsequent
[02.03 window lifetime integration](presentation_window_lifecycle_2026_09.md)
connects the core to the views and service; its host evidence and confirmed
physical close/reconnect result are recorded separately. References below to future/unwired adapters
describe the 02.02 boundary, not the current source.

## Implemented behavior

[PresentationCoordinator](../VisionRemotePS5/Services/PresentationCoordinator.swift)
implements the [state/ownership contract](presentation_state_contract_2026_09.md)
as a main-actor reducer: `send(Event)` updates state synchronously and returns
bounded effects plus an optional rejection. AppState retains one instance and
the project includes its source in the app target. No view, service, decoder,
mailbox or SwiftUI immersive action calls the coordinator yet. Its idle state
must not be read as the status of a session using the existing streaming path.

The core reserves a fresh lease before granting startup, binds the actual
`MetricSessionID` once, and permits one selected consumer. A preparing immersive
view cannot acquire permission until its readiness and open result both arrive.
Busy presentation requests are rejected; no request or callback history is
stored. There is at most one current window, one immersive registration, one
retiring-window permit, one operation slot and one readiness deadline.

Cancel/stop never frees an awaited open. A late opened or unknown result emits
one compensating dismissal under that operation's identity. Return uses a new
operation, waits for W1's retirement before requesting W2, selects the ready
window and then closes immersion. Consumer disappearance cannot certify that
the OS space is absent. Actual open/dismiss acknowledgements drive that state.

Termination immediately revokes startup/consumer permission and issues cleanup
once. If startup was issued, both startup settlement and actual transport
teardown must be acknowledged; their arrival order is irrelevant. The lease
also waits for pending OS actions and any compensating dismissal. A reservation
that never issued startup needs no fictitious transport acknowledgement. Old
lease, generation, operation, surface and deadline callbacks cannot affect the
next session.

Time is injected and monotonic. Readiness gets ten seconds, as proposed in the
contract; an unresolved OS open has no invented completion deadline. Early
timer delivery re-arms the same absolute deadline. Invalid/regressing time
terminates with a clock failure while retaining outstanding cleanup ownership.
Fallback recovery retains its failure even if readiness arrives after dismissal
(contract v1.1, T38), so callback order does not hide the error.

## Driver obligations for subsequent tasks

The effects are **instructions to the future adapters**, not evidence that
transport, focus, input neutralization or OS operations already happened.

- Execute or discard each issued effect according to its current lease, phase,
  surface, operation and retirement permit. A window/start command can become
  obsolete before a driver receives it. Do not blindly replay effect arrays.
- The startup task checks `mayStartTransport(S)` before authentication and again
  before entering the service after every await. An issued start is one attempt,
  not permission to retry. Cancellation must settle the entire attempt; the
  existing VM/service do not yet implement this adapter or its acknowledgements.
  Even a discarded startup command must acknowledge that it cannot start later;
  revoking permission does not replace `startupSettled` or teardown completion.
- A skipped open that was demonstrably never invoked can acknowledge cancellation.
  Once invoked, retain its owner until the actual result arrives, including after
  task cancellation. Never fabricate completion to free the operation slot.
- Apply consumer selection by revoking outgoing submissions/event targeting before
  enabling incoming work. Validate `mayConsume(surface, G)` when admitting new
  work; already-submitted GPU resources retain their independent lifetime. Real
  mailbox/renderer/input enforcement is not added in this task.
- Window registrations capture immutable surface identities. Complete old
  detach/close bookkeeping before reusing an underlying window instance, even
  across sessions. Session-ended effects retire remaining registrations; a new
  lease must not relabel their late callbacks. SwiftUI event classification is
  still 02.03 work.
- Replace one timer per deadline token, preserve its absolute due time and cancel
  it when instructed. The reducer owns no tasks or timers and performs no I/O.
  The app-phase events are a tested policy model; no real lifecycle hook exists.

The single coordinator is enforced by AppState ownership, not a global static
lock. Future drivers must use that instance exclusively and preserve the service
as the sole runtime owner. The plain coordinator is not an observable UI model;
its adapter must publish the resulting presentation state through the app's UI
state without making the video/input paths depend on SwiftUI updates.

## Validation and limits

Host procedure:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_presentation_coordinator.sh
python3 scripts/check_presentation_contract.py
```

The [host suite](../VisionRemotePS5Tests/PresentationCoordinatorHostTests.swift)
uses the production reducer and real metrics identity type with controlled
events, effects and a fake clock. It covers duplicate/invalid requests,
opened/readiness order, cancellation/error/unknown results, both teardown-barrier
orders, stop during startup/open/close, W1/W2 retirement, stale identities,
readiness/deadline failures, app versus scene phases and 64 repeated cycles.
Each cycle preserves one lease/generation/start and releases transient slots.
Final result on arm64 macOS 26.6.2 with command-scoped Xcode 27: 1,025 assertions
passed across ten groups, without compiler warnings/errors. The specification
checker also passed: ten states, 38 guarded rules and 102 expanded edges.
These are simulated event sequences, not 64 device transitions or a performance
measurement. No mocked result is attributed to the actual SwiftUI/Chiaki APIs.

Release validation uses Xcode 27 (`27A5252f`), SDK 27 and the unchanged visionOS
2.0 deployment target:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project VisionRemotePS5.xcodeproj -scheme VisionRemotePS5 \
  -configuration Release -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/VisionRemotePS5-0202-release CODE_SIGNING_ALLOWED=NO build
```

The initial sandboxed build was blocked by Xcode/SwiftUI macro sandbox access.
The same unsigned Release build passed outside that sandbox without compiler
warnings/errors. Local evidence is retained at
`/tmp/VisionRemotePS5-0202-release-build.log` (blocked attempt),
`/tmp/VisionRemotePS5-0202-release-build-unsandboxed.log` (successful build), and
`/tmp/VisionRemotePS5-0202-coordinator-host.log` (host suite). The final Release
build was repeated after the clock/recovery corrections and passed; its bundle
still declares `MinimumOSVersion = 2.0`. Project plist/diff checks and all local
documentation links also passed. Structural checker evidence is
`/tmp/VisionRemotePS5-0202-contract-check.log`.

02.02 acceptance concerns the tested coordinator model and rejection of
concurrent transitions without duplicate startup effects. Scene/service
integration, real idempotence, focus/neutralization, suspension and physical
cycle validation remain 02.03–02.10. No installation, app restart, physical
validation, commit or push was performed for this task.
