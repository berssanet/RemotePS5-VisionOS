# Performance acceptance policy — version 1

Task 01.11 defines review criteria before evaluating presentation changes or
effects. This version establishes proposed engineering limits; it does not report
a candidate passing them. No app behavior, capture setting or input path changes
as part of this documentation task.

## Measurement status

| Evidence | Status and permitted claim |
| --- | --- |
| Native baseline, 01.09 | Completed observational reference: 20min03s, 236 intact checkpoints, local connection, external power and normal image/audio/controls confirmed. Window size is qualitative. |
| Physical presentation endpoint, 01.03 | Waived by the user; unavailable on the tested path. The original proposed reception-to-presentation p95 increase of at most 2 ms cannot currently be evaluated. |
| Button-to-image procedure, 01.10 | Deferred by the user; no external setup, physical latency measurement or error margin is claimed. It is not required for the present definition task. |
| Total instrumentation cost, 01.08 | Original functional ON/OFF comparison passed. The revised eight-run CPU study on 2026-09-09 completed with an inconclusive attribution result; current-study condition/function confirmation is pending. Total cost remains unisolated. See [study and limits](instrumentation_overhead_2026_09.md); no acceptance threshold was changed after observing the results. |
| Policy definition, 01.11 | Defined here; candidate measurements and their acceptance are separate work. |

GPU completion, local input handoff and actual display response remain separate
endpoints. The app formatter already labels these scopes. Apple's
[visionOS render pipeline](https://developer.apple.com/documentation/visionos/understanding-the-visionos-render-pipeline)
describes compositor and display updates after app rendering; a local GPU event
does not establish the button-to-image result.

## Preconditions for a comparison

Record the source revision, artifact identity, device/OS/SDK, controller and
connection type, requested stream settings, processing mode, power, thermal
category, collector configuration and screen placement/size. A game title is
not required. Changing scenes is permitted; describe the interaction pattern
without identifying the title. Uncontrolled changes limit causal conclusions.
Keep requested 1920×1080/60 fps/15,000 kbps for this reference; a lower requested
resolution, cadence or bitrate is not a performance improvement.

Use contemporaneous Native controls on the same installation and conditions.
The historical [01.09 report](sustained_baseline_capture_2026_09.md) records ranges
of window p95 values, not a global percentile or a between-run noise estimate.
In particular, its 14.432–17.738 ms receive-to-GPU range does not establish a
19.738 ms candidate ceiling. Do not transfer its user confirmation to a new mode.

Preserve capture/session identity, monotonic time, complete record sequences,
source timestamps, retained counts and individual window bounds. Reject mixed
sessions and regressing counters. Zero denominators and unavailable values are
unavailable, never zero performance cost. A missing or unpublished terminal
cannot establish a completed sustained run.

The current `-NativeBaselineCapture` and `analyze_native_baseline.py` deliberately
accept Native captures only. A future candidate needs a separately identified,
bounded capture of its actual mode with equivalent metric definitions and
coverage. Do not remove the Native guard, relabel candidate data as Native or
claim the current analyzer already implements this policy. No automatic
acceptance evaluator is introduced here.

## Repetitions, windows and noise

1. Before testing a candidate, plan three Native/Native control pairs and three
   Native/candidate pairs per comparison round, and use all six planned pairs.
   An inconclusive result can require a new round; do not select the best three
   pairs from a larger set. Alternate order across candidate pairs and
   record the actual order. Start comparable blocks after at least 30 seconds of
   warmup and use at least 60 seconds of measured host time per block.
2. Keep sampling cadence and the planned number of checkpoints consistent.
   Require at least ten valid checkpoints for each timing domain in a block.
   Record every attempt and every missing window. Different counts, populations
   or coverage require review; do not trim a slow candidate to its best windows.
3. For each metric, calculate `windowP95MedianMs` and `windowP95MaximumMs` over
   the block's retained-window p95 values. These are explicitly summaries of
   windows, not a whole-block or whole-session p95. Never pool overlapping input
   samples, average percentiles and call the result a percentile, or add the
   decode/GPU/input percentiles together. For input, also calculate
   `windowP99MedianMs` and `windowP99MaximumMs` and evaluate each with its own
   control margin and the same input resolution caps. Video p99 remains a
   required diagnostic with its count/bounds; version 1 assigns it no separate
   numeric acceptance budget.
4. For each statistic independently, let `E` be the largest absolute difference
   in the three Native/Native pairs. Controls and candidates must use comparable
   planned durations for that statistic; a short-block margin does not calibrate
   a sustained-run statistic. For timings, use a minimum margin of 0.002 ms,
   a policy floor associated with the reported 0.001 ms resolution. This is not
   an estimate of clock accuracy or instrumentation cost. `E` is an observed
   repeatability margin, not a confidence interval or a guaranteed error bound.
   The maximum needs its own `E`; the median's margin cannot calibrate it.
5. For each Native/candidate pair, calculate the signed difference
   `d = candidate statistic - Native statistic`. Preserve negative differences.
   Evaluate all three pairs and each applicable timing summary; no favorable
   pair alone establishes acceptance. At least one of the three candidate pairs
   must be collected in a later restarted session; record whether it agrees.
6. For memory and sustained audio behavior, also compare complete 20–30 minute
   runs after equivalent warmup, using the domains' own time bounds. Short timing
   blocks do not validate sustained memory or thermal behavior.

The present receive-to-GPU-completion windows contain roughly 77–86 samples
spanning 1.405–1.712 s; input windows span roughly 6.53–8.53 s and overlap.
Ten checkpoints are not ten
independent observations or complete coverage of a 60-second interval. Report
gaps, bounds and counts alongside the result. Lower coverage, slower delivered
cadence or thermal deterioration caused by a candidate remains evidence about
that candidate; it must not be excluded to obtain a favorable comparison.

## Proposed limits

All numeric limits below are initial policy choices, not values inferred to be
safe from one baseline. `pp` means percentage points; 1 pp means a change from
5% to 6%, not a 1% relative change. Native/candidate differences use matched
domains and independent control margins in the same units.

| Domain | Initial rule | Scope |
| --- | --- | --- |
| Receive to GPU completion | Increase at most 2.000 ms in each window-p95 summary, with the margin rule below. | New local diagnostic budget; does not replace the unavailable presentation limit. |
| Receive to decode; GPU execution | Increase at most 2.000 ms for each metric and each window-p95 summary separately. | Additional local diagnostic budgets; quantiles are not additive. |
| Input tick interval | No repeatable increase above the control margin; `E` must be at most 0.250 ms. | Maximum acceptable comparison resolution, not an allowed regression or an 8.33 ms end-to-end promise. |
| Input tick work | Same rule, with `E` at most 0.100 ms. | Work performed by the local callback. |
| Local input handoff | Same rule, with `E` at most 0.020 ms. | Native setter duration, not network delivery or console receipt. |
| GPU/decoder correctness | No unresolved new GPU failure, decoder error, invalid submission or new-frame capacity rejection during steady streaming. | Stop/reconnect cancellation events are classified separately. |
| Queue bounds | Decoder admission 0–12, mailbox occupancy 0–1, GPU in-flight 0–2; source-domain accounting must remain consistent. | Existing admission capacities, not all internal VideoToolbox/OS allocations. |
| Mailbox replacement share | Increase at most 1.000 pp in `100 × ΔoverwrittenBeforeAcquire / Δpublished`. | Replaced before acquisition; not a count of missed physical presentations. |
| Audio underflow and contention | Each share increases at most 0.100 pp: `100 × ΔunderflowReads / ΔreadCalls` and `100 × ΔcontentionReads / ΔreadCalls`. | Separate PCM read diagnostics; not audible-glitch percentages. |
| Audio catch-up and overflow | Each share increases at most 0.100 pp: discarded samples divided by `ΔwrittenSamples`, multiplied by 100. | Keep catch-up and overflow separate. |
| Audio episode rate | Increase at most 1.000 episode/minute in `ΔunderflowEpisodes / elapsedMinutes`. | Use independent audio observation times; recovery and missing-sample counters remain visible. |
| Sustained memory | In the final five minutes, the last-minute median footprint must be no more than 1 MiB above the first-minute median. Require at least eight distinct observations with valid footprint values in each minute; otherwise inconclusive. | Sampled plateau check, not proof of no leak or a true instantaneous peak. |
| Memory budget | Declare the allowed additional process footprint and owned resource bytes before the candidate test; an absent budget cannot pass. | Resource scopes overlap and must not be summed. Persistent allocations require a documented lifetime and budget. |
| Functional behavior | Normal image, audio, controls, focus and recovery; no unresolved freezes, recurring audible disruption, lost/stuck inputs or persistent queue growth. | User-visible regressions override favorable timing summaries. |

Native audio already has underflow, catch-up, overflow and contention events
while the user reports normal sound. Do not require every audio counter to be
zero or infer an audible glitch from one event. Preserve pre-PCM subsets without
adding them again to inclusive totals. Normalize cumulative deltas over the
matching source interval; sample counts are interleaved samples, not frames.
The catch-up-to-written ratio can exceed 100% when a block discards samples
already buffered before its first observation. Do not clamp it or call the value
corruption solely for exceeding 100%; inspect that domain's buffer accounting.
Overflow has its own meaning and is not interchangeable with catch-up.

Input native errors and new slow/busy/inactive calls during otherwise steady
streaming require investigation. Lost instrumentation observations do not prove
lost commands. Report missed/invalid/overwritten observations separately; a
candidate's higher observation loss can make a timing comparison inconclusive
even when its retained percentiles look better.

## Decision rules

For a positive increase budget `T` (local video timing and the defined shares or
rates), apply these rules in order to each statistic with its own `E`:

- **Regression detected:** at least two of three paired values satisfy
  `d - E > T`. Any unresolved correctness or functional failure blocks acceptance
  regardless of this timing/rate rule; reproduction informs its diagnosis.
- **Insufficient resolution:** otherwise, `E >= T` is inconclusive.
- **Available check passed:** `E < T` and all three paired values satisfy
  `d + E <= T`, with valid coverage and all correctness/functional gates passed.
- **Inconclusive:** the other cases, including incompatible conditions
  or insufficient coverage. Extend or repeat the comparison; do not raise the
  budget after seeing a failure simply to label that same result successful.

For input, the table's caps limit the allowed resolution. If `E` exceeds the cap,
the result is inconclusive. With adequate resolution, an increase above `E` in
at least two pairs is a detected local regression; all three increases at or
below `E` mean **no local regression detected at the stated resolution**. A
mixed result is inconclusive. Neither outcome establishes zero physical input
latency or a button-to-image measurement.

A newly serious/critical thermal state or sustained worsening relative to Native
requires review of the candidate and its fallback. Do not filter away its hot
intervals. Thermal categories are pressure indicators, not numerical temperature.
Explicit disconnect/stop events remain classified rather than silently dropped.

Report results per domain. An unavailable, deferred or inconclusive measurement
must not turn into a passed check. Passing available local checks is not global
latency acceptance; 01.08's total instrumentation cost remains open. Defining
this policy does not complete outstanding dependencies for stage 02 or validate
effects.

## Policy changes and review record

Version 1 records the following decisions before any candidate is evaluated:
the original presentation target remains unavailable; the local GPU/decode
budgets are new diagnostics; input uses explicit comparison-resolution caps;
drops/audio use separate normalized budgets; memory requires a sampled plateau
and a declared allocation budget. The user deferred 01.10 on 2026-09-08; no
camera setup or external measurement is requested for the current work.

Future changes must record the prior/new limit, affected metric and units,
technical reason, applicable source revision and new validation plan before
evaluating the changed policy. Preserve prior failed or inconclusive results.

Each review records: candidate/control revisions and conditions, control order,
capture identities, source coverage, per-block summaries, all paired differences,
`E`, the policy version, per-domain decision, functional report and limitations.
No game title is requested or required in this record.

Validation for 01.11 is document/source review of the existing formatter,
collectors, analyzer and 01.09 evidence. No new device test, effect comparison,
build or physical-latency result was performed for this definition.
