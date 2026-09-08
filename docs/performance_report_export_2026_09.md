# Explicit performance report export — 2026-09-07

Task01.07 adds an explicit UTF-8 text export of the current or most recent session.
Host tests, code review and Debug/Release builds passed. The signed build is
installed on the Vision Pro. The user confirmed the report was saved and normal
operation continued after returning to the game.

The preceding work through completed task01.06 was committed separately as
`1f8fa95` (`feat: instrument input, video queues, audio and thermal state`).
The user confirmed normal sound, image and controls after that build's reconnect.
Task01.03 remains waived, with no claim of validated presentation timing.

## Using the export

During playback, select **Export Report** in the streaming controls. After ending
a session, open Settings → Performance → **Export Performance Report**. The app
prepares an immutable report only on that action, then presents the system Files
exporter with `VisionRemotePS5-Performance.txt` as its suggested name. Choose the
destination and save; cancellation does not save a file. With no session yet,
the action explains that a streaming session is needed.

The app has no automatic report save, upload, share action or background transfer.
A destination offered by Files can be a cloud provider selected by the user;
this is not a promise that every possible destination stays physically on-device.
The export component restores streaming focus after saving, cancelling, or
acknowledging a generic error. It does not call stop/reconnect/disappear handlers.

## Data contract and privacy boundary

`PerformanceReportSnapshot` is a typed allowlist of numeric observations, fixed
enums and opaque session/renderer UUIDs. It contains no connection configuration
object, host/address, account/device identifier, token, pairing key, file path,
raw log, PCM/video payload or controller button values. Requested width, height,
frame rate and bitrate in **kbps** are copied individually into a separate type.
These requested values are not inferred measured network throughput or frame rate.

`StreamingService.makePerformanceReport()` copies the bounded sources on the
main actor before its first suspension. A detached utility task formats that
immutable capture. All supplied domains and every video sample/frame must have
the same captured session identity; otherwise export fails. Report generation
never reads settings, environment variables or logs and performs no file/network
I/O. Only the FileDocument/fileExporter boundary writes the prepared UTF-8 bytes
after the explicit user save. Error UI does not expose provider paths or raw
error descriptions.

Ending a session preserves the metrics until the next session replaces them.
The decoder's numeric observation is cached before releasing its instance; its
own capture time is exported. This observation can precede final queue draining.
Other sources are copied independently, so a shutdown can leave an unmatched
last audio/memory sample. The report neither invents missing pairs nor promises
an atomic whole-pipeline snapshot.

## Statistics and units

Each video and input duration distribution includes its own retained count,
start/end host microseconds and p50/p95/p99 in milliseconds. Percentiles use
nearest rank: sort integer microseconds, select `ceil(p*n)-1`, then convert to
milliseconds. For unsorted values1…100ms this yields50/95/99ms. A valid zero is
`0.000`; no values produce `unavailable`, not zero. Integer subtraction and
formatting preserve5µs as`0.005ms` even at very large host uptimes.

These percentiles describe the retained population, not the entire session or
button-to-image latency. Video metrics share their256-slot ring; input keeps
2,048 events separately, so the distributions can span different intervals.
Counts of overwritten, invalid or missed observations remain separate. GPU work
completion never substitutes for an unavailable presentation endpoint.

The report also includes:

- Decoder admission/payload gauges, capacity rejection and cancellation counters.
- Mailbox overwrite before acquisition, occupancy and retained logical bytes.
- Renderer draw attempts, GPU outcomes and persistent output texture reuse.
- Chronological memory rows with process/device/resource byte scopes that overlap.
- Audio queue duration, PCM counts, startup underflow subsets, later recovery,
  overflow/catch-up and contention, with their original reporting boundaries.
- Thermal state observations, source and timestamps; initial state is not a change.

Missing data is explicit. Memory scopes are not added together, and a rising
sample is not labelled a leak. The oldest retained audio sample need not be the
first sample of the session; paired audio/video rows are matched by host time.

To make these histories available to Release users, bounded five-second audio
and memory collection now runs in both builds. Each history retains at most64
samples, and thermal events retain at most64 entries. Console formatting/output
remains Debug only. This changes collection availability, not playback settings;
overhead comparison is the separate next task01.08.

## Validation

Xcode27.0 (`27A5252f`), host MacBook Pro M3 Pro:

- `scripts/test_performance_report.sh`: passed. Unsorted nearest ranks, zero,
  singleton and absent values, exact high-uptime microseconds, independent input
  windows, bounded retention, mixed sessions in every domain and video frame,
  ended/replaced immutable captures, configuration allowlist and absence of
  synthetic ambient secrets. Also covers decoder capture time, separate drop
  causes, unavailable memory endpoints, signed byte deltas, stereo PCM duration,
  thermal provenance and bounded complete histories.
- UI FileDocument/fileExporter typecheck against SDK27 targeting visionOS2.0:
  passed. Existing APIs preserve the minimum deployment target.
- Final signed Debug and unsigned Release visionOS builds: passed, no compiler
  warning/error diagnostics. Project plist and `git diff --check`: passed.
- Review: no network/raw-log/configuration access in capture/formatter; immutable
  data reaches the system exporter; session lifecycle and Release collection checked.
- Signed Debug installed/launched on the paired Vision Pro. The user confirmed
  successful report saving and normal operation afterward. This confirms the
  physical picker/save/focus flow; exact content and privacy were verified by
  host fixtures/code review, not by inspecting that user-selected file.

The H/R acceptance and additional physical picker/save/focus check for01.07
are complete. Local logs:
`/tmp/VisionRemotePS5-0107-report.log`, `/tmp/VisionRemotePS5-sdk27-build.log`,
`/tmp/VisionRemotePS5-0107-release.log`, `/tmp/VisionRemotePS5-0107-device-console.log`.
