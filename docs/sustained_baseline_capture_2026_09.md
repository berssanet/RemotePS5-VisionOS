# Sustained Native baseline capture — preparation

Task 01.09 has an opt-in capture implementation. The physical 20–30 minute test
has not been performed; no sustained baseline or performance acceptance is
claimed. The user's confirmation for 01.08 covers normal image, audio and input
in both comparison variants, not this new capture.

Launch with `-NativeBaselineCapture` to collect during a Native PS5 session.
Normal launches do not start it. The service refuses to combine this capture
with the existing overhead, collector benchmark or synthetic-load arguments.
It observes the processing selection and cancels on any switch away from Native,
including changes between periodic samples; it never changes the user's mode.

Capture uses the existing bounded, typed performance snapshot and formatter.
After 30 seconds of host-clock warmup, checkpoints are emitted about every
5 seconds until at least 20 minutes of measured host time have elapsed. A run
beyond 30 minutes or a gap over 15 seconds is rejected; a resumed app must not
mistake a long suspension for continuous capture. Session changes, unavailable
or regressing clocks, explicit stop and formatting failures cannot report success.

Each `[NativeBaseline]` line contains one JSON record with an opaque capture ID,
session, sequence, host-time bounds and escaped report text. Formatting and console
output run off the main actor with one operation in flight. There is no growing
in-app archive, automatic file save or network transmission. Native raw console
logs can contain unrelated sensitive data; extract only valid records with this
prefix for analysis. A write already begun may finish after cancellation and
remains identified by its original capture/session.

Percentiles describe each retained window, with its own count and time bounds.
The 256 video entries cover only the newest portion of a checkpoint interval;
video gaps are expected and input windows can overlap. Never combine window
percentiles into a whole-session percentile. Compact history output emits only
the latest memory/audio/thermal row while keeping summaries over the actual
retained source history. Use independent row timestamps and cumulative counters
to reconstruct the sampled timeline; do not infer steady memory from one point.

The remaining physical procedure requires a recorded game, connection type,
power conditions and repeatable Native screen placement/size. Changing game
scenes is allowed and must be documented. OS thermal categories are not numerical
temperatures, and the waived presentation endpoint remains unavailable.

Host validation is provided by `scripts/test_sustained_baseline.sh` and the
existing `scripts/test_performance_report.sh`. The former simulates elapsed time;
passing it does not substitute for playing on the Vision Pro for 20–30 minutes.

Validation on 2026-09-08 with Xcode 27: both host scripts passed, including
session validation during warmup, cancellation during formatting, exact
15-second gap boundaries and a simulated continuous 20-minute run. Signed Release
builds with collection enabled and disabled passed without compiler warnings or
errors. No new device installation or physical baseline was performed in this
validation. Local evidence: `/tmp/VisionRemotePS5-commit-report.log`,
`/tmp/VisionRemotePS5-commit-baseline.log`,
`/tmp/VisionRemotePS5-commit-release.log` and
`/tmp/VisionRemotePS5-commit-disabled.log`.
