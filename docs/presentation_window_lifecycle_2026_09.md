# Window lifetime integration — task 02.03

This is the historical window-only integration report. The subsequent
[cinema and image-comparison delivery](cinema_and_image_comparison_2026_09.md)
adds the actual immersive scene, renderer and GPU comparison; its new physical
acceptance is recorded separately.

Implemented on 2026-09-09 on `docs/active-streaming-paths`, based on `d9c044d`
and the existing local measurement/coordinator changes. The user's request to
continue extends the sequencing scope to window/service integration and its
host, build and physical close/reconnect checks. 01.08 remains open/inconclusive;
01.03 remains waived and 01.10 deferred. No performance criterion changed.

The app now routes window lifetime through the app-owned coordinator and driver.
Host and build checks pass, and the signed Debug app was installed, launched and
connected to PS5. The live console subsequently recorded completed teardown
followed by a second successful connection. **On 2026-09-09 the user confirmed
that the console list returned and image, audio and controls worked normally
after reconnecting.** This completes 02.03 with host evidence for permitted
retirement and physical evidence for ordinary window closure/reconnection.
No real immersive renderer or presentation switch is part of this integration.

The user's subsequent observation was that the app remained a normal window and
1080p, MetalFX and Enhanced showed no perceptible quality improvement. The
functional confirmation above concerns closure/reconnection and playback/input;
it does not validate filter quality or an immersive experience.

## Session and window ownership

[AppState](../VisionRemotePS5/VisionRemotePS5App.swift) retains one
[PresentationSessionDriver](../VisionRemotePS5/Services/PresentationSessionDriver.swift)
and the [coordinator](../VisionRemotePS5/Services/PresentationCoordinator.swift).
Home reserves a logical session before opening a window or authenticating. It
refuses another start while the driver is busy or the service still owns work.
The driver executes control actions; frames, decoding, audio and the input tick
do not pass through it.

Each streaming window carries an immutable Codable surface token containing
only lease, surface kind and registration UUIDs. It does not serialize a console
or credentials into scene restoration. A restored/unowned token displays an
expired-session view and cannot start or stop another session. Open and close
actions target the exact token, including cleanup after termination.

[StreamingVideoWindow](../VisionRemotePS5/Views/StreamingVideoWindow.swift) reports
mount/preparation and detachment. Its disappearance no longer directly stops
the service, disables delivery or clears AppState. The coordinator classifies
that event: an exact outgoing-window retirement permit preserves the session;
loss of the required window outside that permit requests termination. Merely
being in a transition does not exempt every window disappearance.

Preparation is registration/readiness for the adapter, not evidence of a frame
being presented or a controller event reaching the console. Actual immersive
actions are absent from the production environment. The driver supports injected
open/dismiss hooks for host validation and refuses opening when they are absent.
Consumer selection publishes state; renderer admission and physical gamepad
handoff remain subsequent tasks.

## Startup and cleanup barriers

The driver checks the lease before task entry and delivery preparation.
[StreamingViewModel](../VisionRemotePS5/Views/StreamingView.swift) rechecks
cancellation and startup permission around authentication and before service
entry. State callbacks retain their original lease and service generation;
stale callbacks cannot publish into a replacement session.

[StreamingService](../VisionRemotePS5/Services/StreamingService.swift) exposes
quiescence and an awaitable teardown. Startup/wakeup/PSN continuations validate
their service generation, including after awaits. A superseded attempt cannot
cancel or clear a newer attempt. Termination closes admission immediately, then
the driver awaits the whole startup task and the service's actual teardown.
The lease remains busy until both are settled and any pending OS operation is
resolved. Delivery is disabled only at session end; synchronous terminal
cleanup finishes before a replacement lease is admitted. The native transport,
decoder, audio and controller remain owned by the service.

The app shows an ending-session status while cleanup is pending. The console
list returns after termination, and connection failures remain visible when
Home remounts. Aggregate app background requests termination; temporary
inactivity does not. Headset suspension/resumption still requires 02.09's
physical checks, and abrupt process termination cannot prove cleanup ran.

The driver retains pending OS results during cancellation, uses one readiness
timer, rejects stale timer delivery and bounds prepared-surface metadata even
when an immersive detach callback is omitted. These cases are exercised with
fake adapters; they do not demonstrate platform timing or physical immersion.

## Validation and evidence

Host: arm64 Mac, macOS 26.6.2. Builds: command-scoped Xcode 27 (`27A5252f`),
visionOS SDK 27, unchanged minimum visionOS 2.0. Device: Apple Vision Pro,
visionOS 27.0 (`24M5361a`). This is a functional test; no network, power, thermal
or window-size controls are asserted as a performance comparison.

| Check | Observed result | Local evidence under `/tmp/` |
| --- | --- | --- |
| Coordinator H | 1,025 assertions, ten groups, 64 simulated cycles pass | `VisionRemotePS5-0203-coordinator-host.log` |
| Driver H | 281 assertions, eleven groups pass | `VisionRemotePS5-0203-driver-host.log` |
| Mailbox H | Bounded storage, session guards and concurrent producer/consumer regression pass | `VisionRemotePS5-0203-mailbox-host.log` |
| Instrumentation parity H/G on Mac | Optimized ON/OFF mailbox and H.264/HEVC VideoToolbox checks pass | `VisionRemotePS5-0203-video-parity-authorized.log` |
| Unsigned visionOS Release B | Build succeeds without compiler warnings/errors | `VisionRemotePS5-0203-release-build.log` |
| Signed visionOS Debug B | Build succeeds without compiler warnings/errors | `VisionRemotePS5-0203-device-build.log` |
| Installation/launch | New Debug installed and launched without diagnostic arguments | `VisionRemotePS5-0203-install.log`, `VisionRemotePS5-0203-device-console.log` |
| Device connection/reconnection | Two startups, two Chiaki connected events and one completed stop; teardown precedes the second startup | `VisionRemotePS5-0203-device-console.log` |
| Window behavior and playback/controls V | User confirmed the console list returned and image, audio and controls worked normally after reconnecting | Live console plus explicit user confirmation on 2026-09-09 |

The [driver suite](../VisionRemotePS5Tests/PresentationSessionDriverHostTests.swift)
uses the production driver with suspended fake service/OS adapters. It verifies
closure during cancellation-resistant authentication, immediate stop admission,
delayed startup and teardown acknowledgements, obsolete callbacks after
reconnection, exact W1 retirement with fresh W2, and preserved delivery/generation
through simulated retirement. It also covers late-open compensation, timer
failure/rearming, reentrant cleanup, opaque Codable tokens and 32 cycles without
immersive detachment while metadata stays bounded.

Commands for these host suites:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_presentation_coordinator.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_presentation_session_driver.sh
```

Builds use `VisionRemotePS5.xcodeproj`, scheme `VisionRemotePS5`, destination
`generic/platform=visionOS`, and derived data under
`/tmp/VisionRemotePS5-0203-release` (Release, `CODE_SIGNING_ALLOWED=NO`) and
`/tmp/VisionRemotePS5-0203-device` (signed Debug). Initial sandbox failures of
CoreDevice initialization and the VideoToolbox parity harness are retained in
`VisionRemotePS5-0203-devices.log` and `VisionRemotePS5-0203-video-parity.log`.
Authorized reruns succeeded; neither blocked attempt is an app failure.

The physical procedure was to close only the streaming window using its X,
observe the console list returning, reconnect and confirm normal image, audio
and controls. The user answered yes to the specific question covering those
observations. The console corroborates startup, connection and completed service
teardown; the visual, audio and controller result comes from that user report.
Raw console logs remain local; documentation records only allowlisted outcomes.

02.03 is complete within this H/V scope. Its permitted-retirement behavior has
H evidence only; the V result covers closure outside a transition and subsequent
reconnection. Real immersive continuity, full runtime
start/stop idempotence, mailbox/renderer handoff, controller capture,
neutralization, suspension and repeated device cycles remain 02.04–02.10. No
commit or push was performed for this task.
