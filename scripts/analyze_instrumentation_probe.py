#!/usr/bin/env python3
"""Validate v2 process-CPU probes and optionally describe eight ordered ABBA runs.

Only fixed labels, numbers and opaque session IDs reach output. Technical
validity does not establish matched physical conditions or causal overhead.
"""

import argparse
from collections import Counter
from fractions import Fraction
import json
import math
import re
import statistics
import sys

PREFIX = b"[InstrumentationProbe] "
MARKER = b"InstrumentationProbe"
MAX_LINE_BYTES = 8192
MAX_INPUT_BYTES = 256 * 1024 * 1024
MAX_RUNS = 32
MAX_RECORDS = 32
MAX_FILES = 32
UINT64_MAX = 2**64 - 1
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
PHASES = {"warmup", "measureStart", "sample", "complete", "failed", "stopped"}
TERMINALS = {"complete", "failed", "stopped"}
REASONS = {"none", "sessionEnded", "modeChanged", "videoUnavailable", "videoStalled",
           "incompatibleDiagnostics", "invalidClock", "invalidCPU", "sampleGap",
           "durationOutOfBounds", "invalidConfiguration", "interrupted"}
CONFIG_BOUNDS = {"requestedWidth": 16384, "requestedHeight": 16384,
                 "requestedFPS": 240, "requestedBitrateKbps": 1_000_000}
ENDPOINT_SUFFIXES = ("HostUs", "WallTicks", "UserTicks", "SystemTicks")
ENDPOINT_FIELDS = tuple(side + suffix for side in ("first", "last") for suffix in ENDPOINT_SUFFIXES)
INTEGER_FIELDS = tuple(CONFIG_BOUNDS) + ("startedHostUs", "hostUs") + ENDPOINT_FIELDS + ("footprintBytes",)
FIELDS = set(INTEGER_FIELDS) | {"schema", "session", "mode", "processingMode", "phase",
                               "reason", "index", "cpuProcessPercent", "thermalRaw"}


class InvalidRecord(ValueError):
    """Only fixed internal error codes, never input strings."""


def integer(value, optional=False):
    if optional and value == "unavailable":
        return None
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,20}", value):
        raise InvalidRecord("invalid_integer")
    number = int(value)
    if number > UINT64_MAX:
        raise InvalidRecord("invalid_integer")
    return number


def parse_record(line):
    if not line.startswith(PREFIX):
        raise InvalidRecord("malformed_prefix")
    if not line.endswith(b"\n"):
        raise InvalidRecord("unterminated_record")
    payload = line[len(PREFIX):-1]
    if payload.endswith(b"\r"):
        payload = payload[:-1]
    try:
        tokens = payload.decode("ascii").split(" ")
    except UnicodeError:
        raise InvalidRecord("invalid_encoding") from None
    values = {}
    for token in tokens:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*=[^\s=]+", token):
            raise InvalidRecord("invalid_field_syntax")
        name, value = token.split("=", 1)
        if name in values:
            raise InvalidRecord("duplicate_field")
        values[name] = value
    if set(values) != FIELDS:
        raise InvalidRecord("unexpected_field_set")
    if values["schema"] != "2":
        raise InvalidRecord("unsupported_schema")
    if not UUID.fullmatch(values["session"]):
        raise InvalidRecord("invalid_session")
    values["session"] = values["session"].upper()
    if values["mode"] not in ("enabled", "disabled") or values["processingMode"] != "native":
        raise InvalidRecord("invalid_mode")
    if values["phase"] not in PHASES or values["reason"] not in REASONS:
        raise InvalidRecord("invalid_phase_or_reason")
    values["index"] = integer(values["index"])
    if values["index"] > 12:
        raise InvalidRecord("invalid_index")
    for name in INTEGER_FIELDS:
        values[name] = integer(values[name], optional=True)
    thermal = values["thermalRaw"]
    if thermal == "unavailable":
        values["thermalRaw"] = None
    elif re.fullmatch(r"-?[0-9]{1,19}", thermal) and -(2**63) <= int(thermal) < 2**63:
        values["thermalRaw"] = int(thermal)
    else:
        raise InvalidRecord("invalid_thermal_category")
    percent = values["cpuProcessPercent"]
    if percent == "unavailable":
        values["cpuProcessPercent"] = None
    elif re.fullmatch(r"[0-9]{1,25}\.[0-9]{3}", percent):
        values["cpuProcessPercent"] = Fraction(percent)
    else:
        raise InvalidRecord("invalid_cpu_percent")
    return values


def endpoint(record, side):
    return tuple(record[side + suffix] for suffix in ENDPOINT_SUFFIXES)


def cpu_delta(record):
    first, last = endpoint(record, "first"), endpoint(record, "last")
    if any(value is None for value in first + last):
        raise InvalidRecord("unavailable_cpu_endpoint")
    if first[0] <= 0 or first[1] <= 0 or last[0] <= first[0] or last[1] <= first[1]:
        raise InvalidRecord("nonincreasing_clock")
    if last[2] < first[2] or last[3] < first[3]:
        raise InvalidRecord("regressing_cpu_counter")
    wall, user, system = last[1] - first[1], last[2] - first[2], last[3] - first[3]
    if user + system > UINT64_MAX:
        raise InvalidRecord("cpu_delta_overflow")
    percent = Fraction(100 * (user + system), wall)
    rendered = record["cpuProcessPercent"]
    # The producer formats a Double to three decimal places. Integer subtraction
    # and the ratio are exact here; the small ULP allowance covers that conversion.
    tolerance = Fraction(1, 2000) + Fraction.from_float(math.ulp(float(percent)) * 4)
    if rendered is None or abs(rendered - percent) > tolerance:
        raise InvalidRecord("inconsistent_cpu_percent")
    return {"wallTicks": wall, "userTicks": user, "systemTicks": system,
            "processPercent": float(percent)}


def summarize_run(records, source_rejected=False, extra_issues=()):
    issues = set(extra_issues)
    if source_rejected:
        issues.add("source_has_rejected_records")
    first = records[0]
    phases = [record["phase"] for record in records]
    warmups = [r for r in records if r["phase"] == "warmup"]
    starts = [r for r in records if r["phase"] == "measureStart"]
    samples = [r for r in records if r["phase"] == "sample"]
    terminals = [r for r in records if r["phase"] in TERMINALS]
    terminal = terminals[-1] if terminals else None
    if len(terminals) > 1:
        issues.add("multiple_terminals")
    if terminal is not None and records[-1] is not terminal:
        issues.add("record_after_terminal")
    if len(warmups) > 1 or len(starts) > 1:
        issues.add("duplicate_phase")
    expected = ["warmup", "measureStart"] + ["sample"] * len(samples)
    if terminal is not None:
        expected.append(terminal["phase"])
    # An early explicit failure/stop may precede a successful warmup or start.
    if terminal is not None and terminal["phase"] != "complete":
        expected = (["warmup"] if warmups else []) + (["measureStart"] if starts else []) + ["sample"] * len(samples) + [terminal["phase"]]
    if phases != expected:
        issues.add("phase_order_or_missing_phase")
    if [r["index"] for r in samples] != list(range(1, len(samples) + 1)):
        issues.add("sample_index_not_contiguous_in_arrival_order")
    if terminal is not None and terminal["index"] != len(samples):
        issues.add("terminal_index_mismatch")
    immutable = ("mode", "processingMode", "startedHostUs") + tuple(CONFIG_BOUNDS)
    if any(any(r[name] != first[name] for name in immutable) for r in records):
        issues.add("run_metadata_changed")
    for name, maximum in CONFIG_BOUNDS.items():
        if first[name] is None or not 1 <= first[name] <= maximum:
            issues.add("invalid_configuration")
    for record in records:
        failure_phase = record["phase"] in ("failed", "stopped")
        if (record["reason"] != "none") != failure_phase:
            issues.add("phase_reason_mismatch")
        if record["phase"] in ("warmup", "measureStart") and record["index"] != 0:
            issues.add("invalid_start_index")
        if record["phase"] in ("warmup", "measureStart", "failed", "stopped") and record["cpuProcessPercent"] is not None:
            issues.add("unexpected_cpu_percent")
    if warmups:
        warmup = warmups[0]
        if warmup["startedHostUs"] is None or warmup["startedHostUs"] <= 0 or warmup["hostUs"] != warmup["startedHostUs"]:
            issues.add("invalid_warmup_clock")
        if any(warmup[name] is not None for name in ENDPOINT_FIELDS + ("footprintBytes", "thermalRaw")):
            issues.add("unexpected_warmup_observation")
    start = starts[0] if starts else None
    if start is not None:
        point = endpoint(start, "first")
        if point != endpoint(start, "last") or any(value is None for value in point) or point[0] == 0 or point[1] == 0:
            issues.add("invalid_measure_start_endpoint")
        began, observed = start["startedHostUs"], start["firstHostUs"]
        if began is None or observed is None or not 30_000_000 <= observed - began <= 45_000_000:
            issues.add("warmup_duration_out_of_bounds")
    previous = start
    deltas, gaps = [], []
    for sample in samples:
        if previous is None or endpoint(sample, "first") != endpoint(previous, "last"):
            issues.add("sample_endpoint_chain_mismatch")
        try:
            deltas.append(cpu_delta(sample))
        except InvalidRecord as failure:
            issues.add(str(failure))
        if sample["firstHostUs"] is not None and sample["lastHostUs"] is not None:
            gap = sample["lastHostUs"] - sample["firstHostUs"]
            gaps.append(gap)
            if not 0 < gap <= 15_000_000:
                issues.add("sample_gap_out_of_bounds")
        previous = sample
    for record in ([start] if start is not None else []) + samples:
        if record["hostUs"] != record["lastHostUs"]:
            issues.add("observation_host_mismatch")
    duration = None
    total = None
    if terminal is not None:
        if start is not None and previous is not None:
            if endpoint(terminal, "first") != endpoint(start, "first") or endpoint(terminal, "last") != endpoint(previous, "last"):
                issues.add("terminal_endpoint_mismatch")
        elif any(terminal[name] is not None for name in ENDPOINT_FIELDS):
            issues.add("unexpected_terminal_endpoint")
        if terminal["phase"] == "complete":
            if len(samples) != 12:
                issues.add("incomplete_sample_count")
            if terminal["hostUs"] != terminal["lastHostUs"]:
                issues.add("observation_host_mismatch")
            if previous is not None and any(terminal[name] != previous[name] for name in ("footprintBytes", "thermalRaw")):
                issues.add("terminal_observation_mismatch")
            try:
                total = cpu_delta(terminal)
            except InvalidRecord as failure:
                issues.add(str(failure))
            if terminal["firstHostUs"] is not None and terminal["lastHostUs"] is not None:
                duration = terminal["lastHostUs"] - terminal["firstHostUs"]
            if duration is None or not 60_000_000 <= duration <= 90_000_000:
                issues.add("measured_duration_out_of_bounds")
    valid = terminal is not None and terminal["phase"] == "complete" and not issues
    status = "valid_complete_requires_review" if valid else "invalid_run" if issues else terminal["phase"] if terminal is not None else "incomplete_run"
    observations = ([start] if start is not None else []) + samples
    footprints = [r["footprintBytes"] for r in observations]
    available = [value for value in footprints if value is not None]
    first_foot = footprints[0] if footprints else None
    last_foot = footprints[-1] if footprints else None
    return {"session": first["session"], "mode": first["mode"], "processingMode": first["processingMode"],
            "configuration": {name: first[name] for name in CONFIG_BOUNDS},
            "status": status, "technicalValid": bool(valid), "performanceAccepted": None,
            "issues": sorted(issues), "recordCount": len(records), "sampleCount": len(samples),
            "terminalPhase": terminal["phase"] if terminal else None,
            "terminalReason": terminal["reason"] if terminal else None,
            "startedHostUs": first["startedHostUs"], "durationHostUs": duration,
            "measurementStartHostUs": start["firstHostUs"] if start is not None else None,
            "measurementEndHostUs": previous["lastHostUs"] if start is not None and previous is not None else None,
            "maximumSampleGapUs": max(gaps, default=None), "cpu": total if valid else None,
            "sampleCPUPercentRange": {"validIntervals": len(deltas),
                "minimum": min((d["processPercent"] for d in deltas), default=None),
                "maximum": max((d["processPercent"] for d in deltas), default=None)},
            "footprint": {"observations": len(footprints), "validObservations": len(available),
                "firstBytes": first_foot, "lastBytes": last_foot,
                "minimumBytes": min(available, default=None), "maximumBytes": max(available, default=None),
                "firstToLastDeltaBytes": last_foot - first_foot if first_foot is not None and last_foot is not None else None},
            "thermalRawCategories": sorted({r["thermalRaw"] for r in observations if r["thermalRaw"] is not None}),
            "scope": "process_cpu_one_core_is_100_percent_independent_snapshots_no_causal_or_acceptance_claim"}


def analyze_stream(stream):
    groups, group_issues = {}, {}
    errors = Counter()
    ignored = total_bytes = 0
    while True:
        line = stream.readline(MAX_LINE_BYTES + 1)
        if not line:
            break
        total_bytes += len(line)
        if total_bytes > MAX_INPUT_BYTES:
            errors["input_size_limit"] += 1
            break
        if len(line) > MAX_LINE_BYTES:
            marked = MARKER in line
            tail = line[-(len(MARKER) - 1):]
            while line and not line.endswith(b"\n") and total_bytes <= MAX_INPUT_BYTES:
                line = stream.readline(MAX_LINE_BYTES + 1)
                total_bytes += len(line)
                marked = marked or MARKER in tail + line
                tail = line[-(len(MARKER) - 1):]
            if marked:
                errors["oversized_probe_line"] += 1
            else:
                ignored += 1
            if total_bytes > MAX_INPUT_BYTES:
                errors["input_size_limit"] += 1
                break
            continue
        if MARKER not in line:
            ignored += 1
            continue
        try:
            record = parse_record(line)
        except InvalidRecord as failure:
            errors[str(failure)] += 1
            continue
        session = record["session"]
        if session not in groups:
            if len(groups) >= MAX_RUNS:
                errors["run_limit"] += 1
                continue
            groups[session], group_issues[session] = [], set()
        if len(groups[session]) >= MAX_RECORDS:
            group_issues[session].add("record_limit")
            continue
        groups[session].append(record)
    runs = [summarize_run(records, bool(errors), group_issues[session]) for session, records in groups.items()]
    return {"analysisVersion": 2, "rejectedRecordCounts": dict(sorted(errors.items())),
            "inputHasRejectedRecords": bool(errors), "ignoredNonProbeLines": ignored,
            "runs": runs, "eligibleSingleRun": len(runs) == 1 and runs[0]["technicalValid"] and not errors}


def analyze_path(path):
    try:
        with open(path, "rb") as source:
            return analyze_stream(source)
    except OSError:
        return {"analysisVersion": 2, "rejectedRecordCounts": {"input_unavailable": 1},
                "inputHasRejectedRecords": True, "ignoredNonProbeLines": 0,
                "runs": [], "eligibleSingleRun": False}


def aggregate_abba(files):
    issues = []
    if len(files) != 8:
        issues.append("abba_requires_eight_files")
    if any(not item["eligibleSingleRun"] for item in files):
        issues.append("abba_requires_one_valid_run_per_file_including_all_attempts")
    runs = [item["runs"][0] for item in files if item["eligibleSingleRun"]]
    if not issues:
        if [r["mode"] for r in runs] != ["enabled", "disabled", "disabled", "enabled"] * 2:
            issues.append("abba_mode_order_mismatch")
        if len({r["session"] for r in runs}) != 8:
            issues.append("abba_sessions_not_distinct")
        if any(r["configuration"] != runs[0]["configuration"] for r in runs):
            issues.append("abba_configuration_mismatch")
        if any(r["startedHostUs"] is None or r["measurementStartHostUs"] is None
               or r["measurementEndHostUs"] is None for r in runs):
            issues.append("abba_requires_available_host_bounds")
        elif any(later["startedHostUs"] <= earlier["measurementEndHostUs"]
                 for earlier, later in zip(runs, runs[1:])):
            issues.append("abba_host_order_or_overlap")
    output = {"requestedOrder": ["enabled", "disabled", "disabled", "enabled"] * 2,
              "technicalValid": not issues, "issues": issues, "performanceAccepted": None,
              "scope": "descriptive_signed_process_cpu_differences_not_confidence_intervals_or_causal_overhead"}
    if issues:
        return output
    values = [r["cpu"]["processPercent"] for r in runs]
    paired = []
    for index in range(0, 8, 2):
        on, off = (index, index + 1) if runs[index]["mode"] == "enabled" else (index + 1, index)
        paired.append({"enabledFileIndex": on + 1, "disabledFileIndex": off + 1,
                       "signedOnMinusOffPercentagePoints": values[on] - values[off]})
    blocks = [(values[start] + values[start + 3] - values[start + 1] - values[start + 2]) / 2 for start in (0, 4)]
    same = [{"fileIndices": [a + 1, a + 2], "mode": runs[a]["mode"],
             "signedLaterMinusEarlierPercentagePoints": values[a + 1] - values[a],
             "absoluteDifferencePercentagePoints": abs(values[a + 1] - values[a])} for a in (1, 3, 5)]
    differences = [r["signedOnMinusOffPercentagePoints"] for r in paired]
    variant_ranges = {}
    for mode in ("enabled", "disabled"):
        observations = [value for run, value in zip(runs, values) if run["mode"] == mode]
        minimum, maximum = min(observations), max(observations)
        variant_ranges[mode] = {"count": len(observations), "minimum": minimum,
                                "maximum": maximum, "range": maximum - minimum}
    output.update({"orderedCPUProcessPercent": values, "adjacentPairs": paired,
                   "pairedDifferenceMedianPercentagePoints": statistics.median(differences),
                   "pairedDifferenceRangePercentagePoints": [min(differences), max(differences)],
                   "blockContrastsOnMinusOffPercentagePoints": blocks,
                   "sameVariantAdjacentComparisons": same,
                   "sameVariantCPUPercentRange": variant_ranges,
                   "thermalCategoriesByFile": [r["thermalRawCategories"] for r in runs],
                   "physicalConditionsVerified": None,
                   "hostClockScope": "requires_same_device_boot_no_reboot_between_runs"})
    return output


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        raise InvalidRecord("invalid_arguments")


def main(argv):
    options = Arguments(description=__doc__)
    options.add_argument("--abba", action="store_true")
    options.add_argument("files", nargs="+")
    try:
        args = options.parse_args(argv[1:])
        if len(args.files) > MAX_FILES:
            raise InvalidRecord("too_many_input_files")
    except InvalidRecord as error:
        print(json.dumps({"error": str(error)}))
        return 2
    files = [dict(analyze_path(path), inputIndex=index + 1) for index, path in enumerate(args.files)]
    result = {"analysisVersion": 2, "files": files,
              "scope": "technical_probe_validation_no_automatic_performance_acceptance"}
    if args.abba:
        result["abba"] = aggregate_abba(files)
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
