# Monotonic metrics schema — 2026-09-07

Task 01.01 adds a validated timing schema in
[StreamingMetrics.swift](../VisionRemotePS5/Services/StreamingMetrics.swift).
Task 01.02 subsequently added [session/frame isolation](metrics_session_identity_2026_09.md).
Task 01.03 integrates [video collection](video_metrics_instrumentation_2026_09.md);
the user waived its unavailable physical presentation endpoint validation.
Completed task 01.04 uses a [dedicated bounded input recorder](input_metrics_2026_09.md).
Task 01.05 adds [queue, reuse and memory observations](video_queue_metrics_2026_09.md)
with the same captured session identity. Task01.06 adds [audio and thermal observations](audio_thermal_metrics_2026_09.md)
with matching video reporting timestamps and intervals.

## Contract

| Type | Contract |
|---|---|
| `MetricTimestamp` | Positive UInt64 microseconds in the local host monotonic time domain. Zero is reserved for unavailable timing. Never accepts wall-clock, remote-console, or cross-boot timestamps. |
| `MetricDuration` | Nonnegative UInt64 microseconds; zero is valid. Exposes milliseconds and seconds as Double for reporting. |
| `StreamingMetric` | Distinguishes receive-to-decode, receive-to-GPU-completion, receive-to-presentation, GPU execution, input tick interval, and input send duration. |
| `MetricInterval` | Stores metric and endpoints; rejects missing start/end and reversed endpoints before subtracting integer timestamps. |
| `StreamingMetricsClock` | Reads `CACurrentMediaTime`, matching the existing decoder's host time basis. No Date or wall-clock dependency. |

`MetricTimestamp(hostSeconds:)` converts seconds to microseconds, truncating
sub-microsecond fractions. Invalid/nonfinite/negative values, zero, positive
times smaller than one microsecond, and values outside the UInt64 conversion
range return nil instead of trapping. `MetricTimestamp(microseconds:)` imports
an already validated-domain integer timestamp without a floating-point roundtrip.
The caller is responsible for choosing the correct clock domain.

Subtraction happens before converting a duration to Double, preserving a 1 µs
delta even near UInt64.max. Converting each floating-point endpoint truncates
its fractional microsecond; equal converted endpoints produce a valid zero
duration. Floating-point inputs already have their own precision limits.
The schema does not claim nanosecond precision or device timing accuracy.

Example: endpoints 1,000,000 µs and 1,016,667 µs yield 16,667 µs, 16.667 ms,
and 0.016667 s. An unavailable drawable presentation time (zero) becomes nil
and causes `missingEnd`; it must not be treated as a zero-latency frame.

`MetricIntervalError` distinguishes `missingStart`, `missingEnd`, and
`reversedTimestamps`; when both endpoints are missing, start is checked first.
Invalid intervals are not clamped, wrapped, or replaced by zero samples.
GPU completion and presentation are separate metric names; no inference that
one implies the other is built into this schema.

## Validation

Base revision `059a71c`, branch `docs/active-streaming-paths`, plus this task's
schema/project/test changes. Existing untracked stage 00 reports were preserved.
MacBook Pro M3 Pro, macOS 26.6.2 (`25G83`), Xcode 27.0 (`27A5252f`).

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
bash scripts/test_streaming_metrics.sh
```

Result: exit 0. Synthetic tests cover units, fractional truncation, NaN/infinity,
negative/zero/overflow inputs, missing/reversed intervals, valid zero duration,
UInt64 boundaries, and distinct metric identity. A live host-clock smoke test
checks 1,000 consecutive samples for nondecreasing timestamps, without sleeps
or timing thresholds. It is not a jitter or performance benchmark.

The host script compiles the actual schema together with
[StreamingMetricsHostTests.swift](../VisionRemotePS5Tests/StreamingMetricsHostTests.swift),
following the existing standalone harness pattern. It requires no model,
vendored checkout, headset, or console.

The affected Release app build also passed with SDK `xros27.0`, exit 0,
`BUILD SUCCEEDED`, no compiler warning/error diagnostics. Log:
`/tmp/VisionRemotePS5-0101-release.log`. Command uses the existing project/scheme,
generic visionOS destination, `/tmp/VisionRemotePS5-immersive-build`, and
`CODE_SIGNING_ALLOWED=NO`. That temporary build location now holds this task's
artifact, replacing the previous 00.08 artifact; its historical log remains.
Project plist validation and `git diff --check` passed.

This 01.01 record claims no live metrics, reporting UI, export, or performance
result. Existing video/audio/controller callbacks are unchanged. Session identity
and bounded storage are subsequently tested in the linked 01.02 record.
