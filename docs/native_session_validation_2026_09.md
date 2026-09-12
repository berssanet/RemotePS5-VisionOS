# Native session validation — 2026-09-07

Task 00.09 is **complete based on user-reported physical validation**. After
receiving the full procedure, the user confirmed: “ok funcionou corretamente”.
This is a functional report, not an instrumented performance measurement.

## Preparation

- App source: `059a71c`, branch `docs/active-streaming-paths`.
- Preexisting untracked reports for 00.07 and 00.08 are preserved.
- CoreDevice reconfirmed a connected, paired physical Vision Pro
  `RealityDevice14,1`, visionOS 27.0 (`24M5361a`), Developer Mode enabled.
- Installed test build: signed Debug 1.0.0 (1), built with Xcode 27.0
  (`27A5252f`). Debug is used for functional diagnosis; no Release performance
  conclusion may be drawn from this session.
- Before starting, confirm that the headset is unlocked, the PS5 is available,
  and a Bluetooth DualSense is connected. Reconfirm external power, game, LAN/PSN
  connection type, and network setup without recording addresses or credentials.

## Build, installation, and launch evidence

The current source built successfully (`BUILD SUCCEEDED`, exit 0) with the same
signed Debug command and `/tmp/VisionRemotePS5-sdk27-build` location used by
00.03. No compiler warning/error diagnostics were reported. Installation and
`devicectl device process launch` for `com.visionremote.ps5` each exited 0.
This verifies deployment and process launch, not visible UI or gameplay.

Executable SHA-256:
`f2444c68af5bc0976e364b2c8fd6989ef71a503a20eaf16fc85b7e76801d61e0`.
Current local logs: `/tmp/VisionRemotePS5-sdk27-build.log`,
`/tmp/VisionRemotePS5-sdk27-install.log`, and
`/tmp/VisionRemotePS5-sdk27-launch.log`. These paths now describe this current
build/run and replace the earlier 00.03 raw logs; its tracked historical summary
remains unchanged. Do not share raw logs before reviewing/redacting identifiers
and credentials.

## Physical test procedure

Keep processing set to **1080p / Native** throughout. The source configuration
remains 1920×1080 at 60 fps and 15,000 kbps. Enable controller haptics in the app.
Use a safe in-game scene where button presses and rumble can be observed without
unwanted changes to saved progress.

| Step | Action | Expected result | Observed result |
|---|---|---|---|
| 1 | Connect to the intended PS5 and play briefly in Native mode. | Visible moving video, audible stereo, responsive buttons/sticks/triggers. | Passed — user confirmation |
| 2 | Trigger a known in-game rumble event. | DualSense vibrates and subsequently stops as expected. | Passed — user confirmation |
| 3 | Hold a movement control in a safe scene, disconnect the gamepad, then reconnect it. | No input remains stuck; the reconnected pad controls the game; video/audio remain functional. | Passed — user confirmation |
| 4 | Close the streaming window to end the session. | Streaming ends, rumble stops, console selection becomes available. | Passed — user confirmation |
| 5 | Reconnect to the same PS5 and play again. | Video/audio/input recover; rumble works again; no stale held input. | Passed — user confirmation |

For each step, record pass/fail and any symptom. Do not infer success from an
absence of error logs. If a step fails, record the trigger and stop dependent
roadmap work until the failure is understood. If available, correlate reviewed
Debug logs with observations, omitting tokens, registration keys, and addresses.

## Acceptance boundary

The user confirmed correct operation after being asked to check Native gameplay,
audio/input, rumble, gamepad disconnection/reconnection, and PS5 session restart.
All steps are recorded as passed by that consolidated report; the assistant did
not visually or audibly observe the headset. No stuck-input problem was reported.
Game title, current LAN/PSN mode, and current external-power conditions were not
provided for this run. The earlier controller inventory identifies DualSense; no
new model was reported. These omissions prevent using this run as a repeatable
performance baseline, but do not replace or negate the reported functional check.
The sustained baseline and latency measurements remain separate stage 01 tasks.
