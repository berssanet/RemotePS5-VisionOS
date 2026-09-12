#!/usr/bin/env python3
"""Analyze allowlisted Native baseline records; never echo raw log/report text.

Usage: python3 scripts/analyze_native_baseline.py console.log > summary.json
Completion validates a capture's structure, not baseline/performance acceptance.
Window percentiles remain window observations and are never pooled or averaged.
"""

import json
from pathlib import Path
import re
import sys

PREFIX = b"[NativeBaseline] "
MAX_LINE_BYTES = 65_536
MAX_REPORT_BYTES = 49_152
MAX_RECORDS = 361
MAX_RUNS = 32
MAX_INPUT_BYTES = 256 * 1024 * 1024
UINT64_MAX = 2**64 - 1
MAX_GAP_US = 15_000_000
MIN_DURATION_US = 1_200_000_000
MAX_DURATION_US = 1_800_000_000
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
DECIMAL_MS = re.compile(r"([0-9]{1,17})\.([0-9]{3})\Z")
DURATION_IDS = (
    "video.receiveToDecode", "video.receiveToGPUCompletion", "video.gpuExecution",
    "video.receiveToPresentation", "input.tickInterval", "input.tickWork", "input.localHandoff",
)
KINDS = {"checkpoint", "completed", "stopped", "failed"}
REASONS = {
    "sessionEnded", "modeChanged", "cancelled", "unavailableClock", "regressedClock",
    "inconsistentSession", "inactiveSession", "durationExceeded", "captureLimit",
    "captureFailed", "formattingFailed", "captureGapExceeded", "outputFailed",
}
ENVELOPE_KEYS = {
    "kind", "captureID", "session", "sequence", "startedHostUs", "capturedHostUs",
    "elapsedUs", "scope", "processingMode", "reportText", "reason",
}
COUNTER_FIELDS = {
    "video": ("overwrittenSamples",),
    "input": ("ticks", "localHandoffCalls", "slowCalls", "nativeErrors", "busyCalls", "inactiveCalls"),
    "input.retention": ("overwrittenSamples", "missedSamples", "invalidSamples"),
    "decoder.events": ("accepted", "outputs", "errors", "rejectedNew", "rejectedInvalid",
                       "rejectedStopped", "cancelledBeforeDecode"),
    "mailbox.events": ("published", "overwrittenBeforeAcquire", "acquiredFrames",
                       "clearedBeforeAcquire", "disabledSubmissions", "staleSubmissions"),
    "renderer": ("busyDraws", "idleDraws", "throttledDraws", "drawableUnavailable", "encodeFailures"),
    "renderer.gpu": ("submitted", "completed", "gpuFailures"),
    "thermal": ("changes", "notificationsReceived", "rejectedObservations", "eventCount", "overwrittenEvents"),
}
MEMORY_FIELDS = ("hostUs", "footprintBytes", "deviceAllocatedBytes", "ownedTextureCount",
                 "ownedTextureBytes", "decoderSubmissions", "decoderPayloadBytes", "mailboxPixelBytes")
AUDIO_COUNTERS = (
    "writtenSamples", "readSamples", "readCalls", "underflowReads", "missingSamples",
    "prePCMUnderflowReads", "prePCMMissingSamples", "underflowEpisodes", "recoveryEvents",
    "contentionReads", "contentionRequestedSamples", "overflowDiscardedSamples",
    "catchUpDiscardedSamples", "catchUpEvents", "oversizedRenderRequests",
)
AUDIO_FIELDS = ("sequence", "intervalStartUs", "hostUs", "sampleRate", "channels",
                "queuedSamples", "capacitySamples", "targetSamples", "rawThermalState") + AUDIO_COUNTERS


class InvalidRecord(ValueError):
    """Only fixed codes reach output; input values never become error messages."""


def integer(value, *, optional=False, positive=False):
    if optional and value in (None, "unavailable"):
        return None
    if isinstance(value, str):
        if not re.fullmatch(r"[0-9]{1,20}", value):
            raise InvalidRecord("invalid_number")
        value = int(value)
    if type(value) is not int or not (int(positive) <= value <= UINT64_MAX):
        raise InvalidRecord("invalid_number")
    return value


def signed_integer(value):
    if not isinstance(value, str) or not re.fullmatch(r"-?[0-9]{1,19}", value):
        raise InvalidRecord("invalid_number")
    result = int(value)
    if not -(2**63) <= result < 2**63:
        raise InvalidRecord("invalid_number")
    return result


def milliseconds_us(value):
    if value == "unavailable":
        return None
    match = DECIMAL_MS.fullmatch(value or "")
    if not match:
        raise InvalidRecord("invalid_percentile")
    result = int(match[1]) * 1000 + int(match[2])
    if result > UINT64_MAX:
        raise InvalidRecord("invalid_percentile")
    return result


def fields(line):
    result = {}
    for token in line.split()[1:]:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        if key in result:
            raise InvalidRecord("duplicate_report_field")
        result[key] = value
    return result


def unique_json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidRecord("duplicate_json_key")
        result[key] = value
    return result


def envelope(payload):
    try:
        value = json.loads(payload, object_pairs_hook=unique_json_pairs)
    except (ValueError, UnicodeError, RecursionError):
        raise InvalidRecord("invalid_json") from None
    if not isinstance(value, dict) or not set(value) <= ENVELOPE_KEYS:
        raise InvalidRecord("invalid_envelope")
    for key in ("captureID", "session"):
        if not isinstance(value.get(key), str) or not UUID.fullmatch(value[key]):
            raise InvalidRecord("invalid_identity")
        value[key] = value[key].upper()
    if not isinstance(value.get("kind"), str) or value["kind"] not in KINDS or value.get("scope") != "retainedWindow":
        raise InvalidRecord("invalid_envelope")
    if value.get("processingMode") != "native":
        raise InvalidRecord("non_native_record")
    value["sequence"] = integer(value.get("sequence"))
    if value["sequence"] > MAX_RECORDS:
        raise InvalidRecord("invalid_sequence")
    for key in ("startedHostUs", "capturedHostUs"):
        value[key] = integer(value.get(key), optional=True, positive=True)
    value["elapsedUs"] = integer(value.get("elapsedUs"), optional=True)
    reason = value.get("reason")
    if reason is not None and (not isinstance(reason, str) or reason not in REASONS):
        raise InvalidRecord("invalid_reason")
    value["reason"] = reason
    if value["kind"] == "checkpoint":
        if value["sequence"] == 0 or reason is not None:
            raise InvalidRecord("invalid_checkpoint")
        report = value.get("reportText")
        if not isinstance(report, str):
            raise InvalidRecord("invalid_report_size")
        try:
            report_bytes = len(report.encode("utf-8"))
        except UnicodeError:
            raise InvalidRecord("invalid_report_encoding") from None
        if report_bytes > MAX_REPORT_BYTES:
            raise InvalidRecord("invalid_report_size")
        if any(value[key] is None for key in ("startedHostUs", "capturedHostUs", "elapsedUs")):
            raise InvalidRecord("invalid_checkpoint")
    elif value.get("reportText") is not None:
        raise InvalidRecord("invalid_terminal")
    return value


def parse_report(text, record):
    lines = text.splitlines()
    if len(lines) > 512 or any(len(line) > 8192 for line in lines):
        raise InvalidRecord("invalid_report_size")
    result = {"durations": {}, "counters": {}, "memory": None, "audio": None, "thermalRaw": None}
    recognized = set(DURATION_IDS) | set(COUNTER_FIELDS) | {"memory.sample", "audio.sample"}
    rows = {}
    sessions = [line[8:] for line in lines if line.startswith("session=")]
    captures = [line for line in lines if line.startswith("capturedHostUs=")]
    if sessions != [record["session"]] or len(captures) != 1 or lines.count("formatVersion=1") != 1:
        raise InvalidRecord("report_identity_mismatch")
    header = fields("header " + captures[0])
    if integer(header.get("capturedHostUs")) != record["capturedHostUs"] or header.get("active") != "true":
        raise InvalidRecord("report_capture_mismatch")
    for line in lines:
        label = line.split(" ", 1)[0]
        if label not in recognized:
            continue  # Explanatory prose and all unknown fields never reach output.
        if label in rows:
            raise InvalidRecord("duplicate_report_row")
        rows[label] = fields(line)
    for label in DURATION_IDS:
        if label not in rows:
            raise InvalidRecord("missing_duration_row")
        row = rows[label]
        count = integer(row.get("count"))
        start = integer(row.get("startHostUs"), optional=True, positive=True)
        end = integer(row.get("endHostUs"), optional=True, positive=True)
        quantiles = [milliseconds_us(row.get(key)) for key in ("p50Ms", "p95Ms", "p99Ms")]
        if count == 0:
            if any(item is not None for item in [start, end] + quantiles):
                raise InvalidRecord("inconsistent_empty_duration")
        elif (start is None or end is None or end < start or any(q is None for q in quantiles)
              or quantiles != sorted(quantiles)):
            raise InvalidRecord("invalid_duration_window")
        result["durations"][label] = {"count": count, "startHostUs": start, "endHostUs": end,
                                      "p95Us": quantiles[1]}
    for label, names in COUNTER_FIELDS.items():
        row = rows.get(label, {})
        for name in names:
            if name in row:
                result["counters"][label + "." + name] = integer(row[name])
    if "memory.sample" in rows:
        row = rows["memory.sample"]
        result["memory"] = {name: integer(row.get(name), optional=name == "footprintBytes",
                                         positive=name == "hostUs") for name in MEMORY_FIELDS}
    if "audio.sample" in rows:
        row = rows["audio.sample"]
        result["audio"] = {
            name: (signed_integer(row.get(name)) if name == "rawThermalState" else
                   integer(row.get(name), optional=name == "intervalStartUs",
                           positive=name in ("sequence", "hostUs", "sampleRate", "channels")))
            for name in AUDIO_FIELDS
        }
    thermal = rows.get("thermal", {}).get("rawState")
    if thermal is not None and thermal != "unavailable":
        result["thermalRaw"] = signed_integer(thermal)
    return result


def summarize_numbers(values):
    valid = [value for value in values if value is not None]
    first = values[0] if values else None
    last = values[-1] if values else None
    return {"validSamples": len(valid), "first": first, "last": last,
            "minimum": min(valid) if valid else None, "maximum": max(valid) if valid else None,
            "firstToLastDelta": last - first if first is not None and last is not None else None}


def summarize_windows(checkpoints):
    output = {}
    for label in DURATION_IDS:
        windows = [r["parsed"]["durations"][label] for r in checkpoints]
        available = [row for row in windows if row["count"] > 0]
        p95 = [row["p95Us"] / 1000 for row in available]
        gaps = overlaps = repeated = 0
        max_gap = 0
        for previous, current in zip(available, available[1:]):
            difference = current["startHostUs"] - previous["endHostUs"]
            gaps += difference > 0
            overlaps += difference < 0
            max_gap = max(max_gap, difference)
            repeated += (current["startHostUs"], current["endHostUs"]) == (previous["startHostUs"], previous["endHostUs"])
        output[label] = {
            "windowCount": len(windows), "availableWindowCount": len(available),
            "retainedCountMinimum": min((w["count"] for w in windows), default=None),
            "retainedCountMaximum": max((w["count"] for w in windows), default=None),
            "p95WindowMinimumMs": min(p95) if p95 else None,
            "p95WindowMaximumMs": max(p95) if p95 else None,
            "firstWindowStartHostUs": available[0]["startHostUs"] if available else None,
            "lastWindowEndHostUs": available[-1]["endHostUs"] if available else None,
            "windowGaps": gaps, "maximumWindowGapUs": max_gap,
            "overlappingWindows": overlaps, "repeatedWindowBounds": repeated,
            "scope": "range_of_retained_window_p95_not_global_percentile",
        }
    return output


def summarize_source(checkpoints, domain):
    seen = {}
    sequence_times = {}
    repeated = conflicts = stale = future = out_of_order = sequence_conflicts = 0
    last_seen_time = None
    for checkpoint in checkpoints:
        row = checkpoint["parsed"][domain]
        if row is None:
            continue
        host = row["hostUs"]
        stale += checkpoint["capturedHostUs"] - host > MAX_GAP_US
        future += host > checkpoint["capturedHostUs"]
        if last_seen_time is not None and host < last_seen_time:
            out_of_order += 1
        last_seen_time = host
        key = (host, row["sequence"]) if domain == "audio" else host
        if key in seen:
            repeated += 1
            conflicts += seen[key] != row
        else:
            seen[key] = row
        if domain == "audio":
            sequence = row["sequence"]
            if sequence in sequence_times and sequence_times[sequence] != host:
                sequence_conflicts += 1
            sequence_times[sequence] = host
    samples = sorted(seen.values(), key=lambda row: row["hostUs"])
    gaps = [b["hostUs"] - a["hostUs"] for a, b in zip(samples, samples[1:])]
    result = {
        "uniqueSamples": len(samples), "repeatedRows": repeated, "conflictingDuplicateRows": conflicts,
        "staleRowsOver15Seconds": stale, "rowsAfterCaptureClock": future,
        "outOfOrderRows": out_of_order, "sequenceTimeConflicts": sequence_conflicts,
        "sampleGapsOver15Seconds": sum(gap > MAX_GAP_US for gap in gaps),
        "maximumSampleGapUs": max(gaps, default=None),
        "firstHostUs": samples[0]["hostUs"] if samples else None,
        "lastHostUs": samples[-1]["hostUs"] if samples else None,
    }
    if domain == "memory":
        result["byteScopes"] = {name: summarize_numbers([s[name] for s in samples])
                                for name in MEMORY_FIELDS if name.endswith("Bytes")}
        result["ownedTextureCount"] = summarize_numbers([s["ownedTextureCount"] for s in samples])
        result["scope"] = "independent_point_samples_overlapping_byte_scopes_not_a_leak_verdict"
    else:
        result["counters"] = summarize_counter_rows(samples, AUDIO_COUNTERS)
        result["rawThermalStates"] = sorted({s["rawThermalState"] for s in samples})
        result["queuedSamples"] = summarize_numbers([s["queuedSamples"] for s in samples])
    return result


def summarize_counter_rows(rows, names):
    result = {}
    for name in names:
        values = [row[name] for row in rows if name in row]
        regressions = sum(b < a for a, b in zip(values, values[1:]))
        result[name] = {"observations": len(values), "first": values[0] if values else None,
                        "last": values[-1] if values else None, "regressions": regressions,
                        "delta": values[-1] - values[0] if values and not regressions else None}
    return result


def summarize_run(run):
    issues = set(run["issues"])
    records = run["records"]
    checkpoints = [record for record in records if record["kind"] == "checkpoint"]
    terminals = [record for record in records if record["kind"] != "checkpoint"]
    sequences = [record["sequence"] for record in checkpoints]
    if len(set(sequences)) != len(sequences):
        issues.add("duplicate_checkpoint_sequence")
    if sequences != list(range(1, len(checkpoints) + 1)):
        issues.add("checkpoint_sequence_not_contiguous_in_arrival_order")
    if len(terminals) > 1:
        issues.add("multiple_terminals")
    if terminals and records[-1] is not terminals[-1]:
        issues.add("checkpoint_after_terminal")
    start = checkpoints[0]["startedHostUs"] if checkpoints else None
    last_host = None
    gaps = []
    for checkpoint in checkpoints:
        host = checkpoint["capturedHostUs"]
        if checkpoint["startedHostUs"] != start:
            issues.add("start_clock_changed")
        if host < checkpoint["startedHostUs"] or checkpoint["elapsedUs"] != host - checkpoint["startedHostUs"]:
            issues.add("elapsed_clock_mismatch")
        if last_host is not None:
            gap = host - last_host
            gaps.append(gap)
            if gap <= 0:
                issues.add("capture_clock_not_increasing")
            elif gap > MAX_GAP_US:
                issues.add("capture_gap_exceeded")
        last_host = host
    if checkpoints and (checkpoints[0]["elapsedUs"] != 0 or checkpoints[0]["capturedHostUs"] != start):
        issues.add("missing_initial_checkpoint")
    terminal = terminals[-1] if terminals else None
    if terminal and terminal["kind"] == "completed":
        if not checkpoints or any(terminal[key] != checkpoints[-1][key] for key in
                                  ("sequence", "startedHostUs", "capturedHostUs", "elapsedUs")):
            issues.add("completed_terminal_bounds_mismatch")
        if terminal["reason"] is not None:
            issues.add("completed_terminal_has_failure_reason")
        if terminal["elapsedUs"] is None or not MIN_DURATION_US <= terminal["elapsedUs"] <= MAX_DURATION_US:
            issues.add("completed_duration_out_of_range")
    complete = bool(terminal and terminal["kind"] == "completed" and not issues)
    status = "complete_capture_requires_review" if complete else "invalid_capture" if issues else "incomplete_capture"
    # Do not reorder malformed checkpoint streams into an apparently successful run.
    counter_rows = [r["parsed"]["counters"] for r in checkpoints]
    counter_names = sorted({name for row in counter_rows for name in row})
    counters = summarize_counter_rows(counter_rows, counter_names)
    thermal = [r["parsed"]["thermalRaw"] for r in checkpoints if r["parsed"]["thermalRaw"] is not None]
    memory = summarize_source(checkpoints, "memory")
    audio = summarize_source(checkpoints, "audio")
    data_issues = []
    if any(row["regressions"] for row in counters.values()) or any(row["regressions"] for row in audio["counters"].values()):
        data_issues.append("counter_regression")
    for domain, source in (("memory", memory), ("audio", audio)):
        for field in ("conflictingDuplicateRows", "staleRowsOver15Seconds", "outOfOrderRows",
                      "sequenceTimeConflicts", "sampleGapsOver15Seconds"):
            if source[field]:
                data_issues.append(domain + "." + field)
        if source["rowsAfterCaptureClock"]:
            # Independent domain copies can observe a newer sample than the
            # envelope clock. Surface for review without invalidating capture.
            data_issues.append(domain + ".rowsAfterCaptureClock_review_independent_observation")
    return {
        "captureID": run["captureID"], "session": run["session"], "status": status,
        "captureComplete": complete, "baselineAccepted": None,
        "measurementDataIssues": data_issues,
        "acceptance": "requires_network_screen_power_conditions_and_functional_review",
        "issues": sorted(issues), "records": len(records), "checkpointCount": len(checkpoints),
        "terminalKind": terminal["kind"] if terminal else None,
        "terminalReason": terminal["reason"] if terminal else None,
        "startedHostUs": start, "lastCapturedHostUs": last_host,
        "observedDurationUs": last_host - start if last_host is not None and start is not None else None,
        "maximumCaptureGapUs": max(gaps, default=None), "processingMode": "native",
        "durationWindows": summarize_windows(checkpoints), "counters": counters,
        "drops": {name: counters.get(name) for name in (
            "decoder.events.rejectedNew", "mailbox.events.overwrittenBeforeAcquire", "renderer.gpu.gpuFailures")},
        "memory": memory,
        "audio": audio,
        "thermal": {"rawCategories": sorted(set(thermal)),
                    "changesBetweenCheckpointObservations": sum(a != b for a, b in zip(thermal, thermal[1:])),
                    "recordedChangeCounter": counters.get("thermal.changes"),
                    "scope": "OS_pressure_categories_not_temperature"},
    }


def analyze_stream(stream):
    runs = {}
    errors = {}
    ignored = total_bytes = 0

    def error(code):
        errors[code] = errors.get(code, 0) + 1

    while True:
        line = stream.readline(MAX_LINE_BYTES + 1)
        if not line:
            break
        total_bytes += len(line)
        if total_bytes > MAX_INPUT_BYTES:
            error("input_size_limit")
            break
        if len(line) > MAX_LINE_BYTES:
            prefixed = line.startswith(b"[NativeBaseline]")
            while line and not line.endswith(b"\n"):
                line = stream.readline(MAX_LINE_BYTES + 1)
                total_bytes += len(line)
                if total_bytes > MAX_INPUT_BYTES:
                    break
            error("oversized_prefixed_line") if prefixed else None
            ignored += not prefixed
            continue
        if not line.startswith(PREFIX):
            if line.startswith(b"[NativeBaseline]"):
                error("malformed_prefix")
            else:
                ignored += 1
            continue
        try:
            record = envelope(line[len(PREFIX):])
        except InvalidRecord as failure:
            error(str(failure))
            continue
        key = (record["captureID"], record["session"])
        if key not in runs:
            if len(runs) >= MAX_RUNS:
                error("capture_group_limit")
                continue
            runs[key] = {"captureID": key[0], "session": key[1], "records": [], "issues": set(), "seen": 0}
        run = runs[key]
        run["seen"] += 1
        if run["seen"] > MAX_RECORDS:
            run["issues"].add("record_limit")
            continue
        if record["kind"] == "checkpoint":
            try:
                record["parsed"] = parse_report(record["reportText"], record)
            except (InvalidRecord, TypeError, KeyError):
                error("invalid_report")
                run["issues"].add("invalid_report")
                continue
        record.pop("reportText", None)
        run["records"].append(record)
    # A prefix/envelope truncation may have lost an otherwise valid checkpoint.
    # Preserve individual structural status while marking the input unverified.
    summaries = [summarize_run(run) for run in runs.values()]
    return {"analysisVersion": 1, "source": "allowlisted_NativeBaseline_records",
            "inputHasRejectedRecords": bool(errors), "rejectedRecordCounts": dict(sorted(errors.items())),
            "ignoredNonBaselineLines": ignored, "runs": summaries,
            "scope": "retained_window_percentile_ranges_and_independent_samples_no_automatic_baseline_acceptance"}


def analyze_path(path):
    with open(path, "rb") as source:
        result = analyze_stream(source)
    if Path(path).name.lower().endswith(".partial"):
        # A completed record can have been appended before synchronization,
        # close, or rename fails. Staging bytes are not a published artifact.
        result["sourcePublication"] = "unpublished_partial"
        result["publicationIssue"] = "source_is_unpublished_partial"
        for run in result["runs"]:
            run["issues"] = sorted(set(run["issues"]) | {"source_is_unpublished_partial"})
            run["captureComplete"] = False
            run["status"] = "incomplete_unpublished_capture"
    else:
        result["sourcePublication"] = "final_ndjson_name" if Path(path).suffix == ".ndjson" else "console_or_other_input"
    return result


def main(argv):
    if len(argv) != 2:
        print(json.dumps({"error": "usage_requires_one_input_log_path"}))
        return 2
    try:
        result = analyze_path(argv[1])
    except OSError:
        print(json.dumps({"error": "input_unavailable"}))
        return 2
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
