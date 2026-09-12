#!/usr/bin/env python3
"""Synthetic v2 probe records only; never reads app/device console files."""

import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import analyze_instrumentation_probe as analyzer

SESSION = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
HOST = 10_000_000_000_000_000
TICKS = 10_000_000_000_000_000


def empty_record(session=SESSION, mode="enabled"):
    result = {name: "unavailable" for name in analyzer.FIELDS}
    result.update(schema="2", session=session, mode=mode, processingMode="native", phase="warmup",
                  reason="none", index=0, startedHostUs=HOST, hostUs=HOST,
                  requestedWidth=1920, requestedHeight=1080, requestedFPS=60,
                  requestedBitrateKbps=15000)
    return result


def observation(index, percent=20, gap_us=5_000_000, warmup_us=30_000_000):
    return {"HostUs": HOST + warmup_us + index * gap_us,
            "WallTicks": TICKS + index * gap_us * 24,
            "UserTicks": TICKS + index * gap_us * 24 * percent // 100,
            "SystemTicks": TICKS,
            "footprintBytes": 200_000_000 + index * 4096, "thermalRaw": 0}


def put_endpoints(record, first, last, with_cpu=False):
    for side, point in (("first", first), ("last", last)):
        for suffix in analyzer.ENDPOINT_SUFFIXES:
            record[side + suffix] = point[suffix]
    record.update(hostUs=last["HostUs"], footprintBytes=last["footprintBytes"], thermalRaw=last["thermalRaw"])
    if with_cpu:
        numerator = last["UserTicks"] - first["UserTicks"] + last["SystemTicks"] - first["SystemTicks"]
        denominator = last["WallTicks"] - first["WallTicks"]
        record["cpuProcessPercent"] = f"{100 * numerator / denominator:.3f}"


def valid_run(session=SESSION, mode="enabled", percent=20, gap_us=5_000_000, warmup_us=30_000_000,
              host_offset_us=0):
    records = [empty_record(session, mode)]
    points = [observation(index, percent, gap_us, warmup_us) for index in range(13)]
    start = dict(records[0], phase="measureStart")
    put_endpoints(start, points[0], points[0])
    records.append(start)
    for index in range(1, 13):
        sample = dict(records[0], phase="sample", index=index)
        put_endpoints(sample, points[index - 1], points[index], True)
        records.append(sample)
    terminal = dict(records[0], phase="complete", index=12)
    put_endpoints(terminal, points[0], points[-1], True)
    records.append(terminal)
    for record in records:
        for name in ("startedHostUs", "hostUs", "firstHostUs", "lastHostUs"):
            if isinstance(record[name], int):
                record[name] += host_offset_us
    return records


def encode(records):
    return b"".join(analyzer.PREFIX + " ".join(f"{key}={value}" for key, value in sorted(record.items())).encode() + b"\n" for record in records)


def analyze(records, noise=b""):
    return analyzer.analyze_stream(io.BytesIO(noise + encode(records)))


def issue(records, expected):
    result = analyze(records)
    assert not result["eligibleSingleRun"]
    assert expected in result["runs"][0]["issues"], result["runs"][0]["issues"]


class InstrumentationProbeAnalysisTests(unittest.TestCase):
    def test_complete_cpu_units_and_independent_optional_memory(self):
        for percent in (0, 20, 250):
            records = valid_run(percent=percent)
            result = analyze(records, b"unrelated console line\n")
            self.assertTrue(result["eligibleSingleRun"])
            run = result["runs"][0]
            self.assertEqual(run["durationHostUs"], 60_000_000)
            self.assertEqual(run["measurementStartHostUs"], HOST + 30_000_000)
            self.assertEqual(run["measurementEndHostUs"], HOST + 90_000_000)
            self.assertEqual(run["cpu"]["processPercent"], percent)
            self.assertEqual(run["cpu"]["wallTicks"], 60_000_000 * 24)
            self.assertEqual(run["sampleCount"], 12)
            self.assertIsNone(run["performanceAccepted"])
            self.assertEqual(run["status"], "valid_complete_requires_review")
        records = valid_run()
        records[1]["footprintBytes"] = "unavailable"
        records[-2]["footprintBytes"] = records[-1]["footprintBytes"] = "unavailable"
        run = analyze(records)["runs"][0]
        self.assertTrue(run["technicalValid"])
        self.assertIsNone(run["footprint"]["firstToLastDeltaBytes"])
        self.assertEqual(run["footprint"]["validObservations"], 11)

    def test_exact_cpu_subtraction_at_large_uptimes_and_rounding(self):
        record = valid_run()[2]
        record.update(firstHostUs=HOST, lastHostUs=HOST + 1, firstWallTicks=TICKS,
                      lastWallTicks=TICKS + 300_000, firstUserTicks=TICKS,
                      lastUserTicks=TICKS + 1, firstSystemTicks=TICKS,
                      lastSystemTicks=TICKS, cpuProcessPercent="0.000")
        parsed = analyzer.parse_record(encode([record]))
        delta = analyzer.cpu_delta(parsed)
        self.assertAlmostEqual(delta["processPercent"], 1 / 3000)
        self.assertEqual(delta["userTicks"], 1)
        record["cpuProcessPercent"] = "0.001"
        with self.assertRaisesRegex(analyzer.InvalidRecord, "inconsistent_cpu_percent"):
            analyzer.cpu_delta(analyzer.parse_record(encode([record])))
        record.update(lastWallTicks=TICKS + 200_000, cpuProcessPercent="0.001")
        analyzer.cpu_delta(analyzer.parse_record(encode([record])))

    def test_duration_and_warmup_boundaries(self):
        self.assertTrue(analyze(valid_run(gap_us=7_500_000, warmup_us=45_000_000))["eligibleSingleRun"])
        issue(valid_run(warmup_us=29_999_999), "warmup_duration_out_of_bounds")
        issue(valid_run(warmup_us=45_000_001), "warmup_duration_out_of_bounds")
        issue(valid_run(gap_us=4_999_999), "measured_duration_out_of_bounds")
        issue(valid_run(gap_us=7_500_001), "measured_duration_out_of_bounds")
        records = valid_run()
        records[2]["lastHostUs"] = records[2]["firstHostUs"] + 15_000_001
        records[2]["hostUs"] = records[2]["lastHostUs"]
        issue(records, "sample_gap_out_of_bounds")

        # One 15-second interval plus eleven 5-second intervals is valid. Host
        # and Mach ticks use different units; construct both continuous chains.
        records = valid_run()
        points = [observation(0)]
        for index in range(1, 13):
            elapsed = 15_000_000 + (index - 1) * 5_000_000
            point = observation(index)
            point.update(HostUs=HOST + 30_000_000 + elapsed,
                         WallTicks=TICKS + elapsed * 24,
                         UserTicks=TICKS + elapsed * 24 // 5)
            points.append(point)
            put_endpoints(records[index + 1], points[index - 1], point, True)
        put_endpoints(records[-1], points[0], points[-1], True)
        result = analyze(records)
        self.assertTrue(result["eligibleSingleRun"])
        self.assertEqual(result["runs"][0]["maximumSampleGapUs"], 15_000_000)
        self.assertEqual(result["runs"][0]["durationHostUs"], 70_000_000)

    def test_configuration_reason_and_platform_category_allowlists(self):
        for name, maximum in analyzer.CONFIG_BOUNDS.items():
            for value in (1, maximum):
                records = valid_run()
                for record in records:
                    record[name] = value
                self.assertTrue(analyze(records)["eligibleSingleRun"])
            for value in (0, maximum + 1, "unavailable"):
                records = valid_run()
                for record in records:
                    record[name] = value
                issue(records, "invalid_configuration")
        records = valid_run()
        records[-1]["reason"] = "sessionEnded"
        issue(records, "phase_reason_mismatch")
        for category in (-1, 37, 2**63 - 1, -(2**63)):
            records = valid_run()
            for record in records[1:]:
                record["thermalRaw"] = category
            result = analyze(records)
            self.assertTrue(result["eligibleSingleRun"])
            self.assertEqual(result["runs"][0]["thermalRawCategories"], [category])
        for field, value in (("processingMode", "enhanced"), ("reason", "SECRET_REASON"),
                             ("thermalRaw", 2**63), ("cpuProcessPercent", "20,000")):
            records = valid_run()
            records[2][field] = value
            result = analyze(records)
            self.assertFalse(result["eligibleSingleRun"])
            self.assertNotIn("SECRET_REASON", json.dumps(result))

    def test_missing_duplicate_reordered_and_post_terminal_records(self):
        records = valid_run()
        issue(records[:4] + records[5:], "sample_index_not_contiguous_in_arrival_order")
        issue(records[:3] + [records[2]] + records[3:], "sample_index_not_contiguous_in_arrival_order")
        records[2], records[3] = records[3], records[2]
        issue(records, "sample_index_not_contiguous_in_arrival_order")
        records = valid_run()
        issue(records + [records[-2]], "record_after_terminal")
        issue(records + [records[-1]], "multiple_terminals")
        issue(records[1:], "phase_order_or_missing_phase")
        issue(records[:1] + records[2:], "phase_order_or_missing_phase")

    def test_endpoint_chain_configuration_and_identity(self):
        for name, value, expected in (
            ("firstWallTicks", TICKS + 1, "sample_endpoint_chain_mismatch"),
            ("lastUserTicks", TICKS - 1, "regressing_cpu_counter"),
            ("lastHostUs", HOST, "nonincreasing_clock"),
            ("hostUs", HOST, "observation_host_mismatch"),
            ("cpuProcessPercent", "99.000", "inconsistent_cpu_percent"),
            ("mode", "disabled", "run_metadata_changed"),
            ("requestedWidth", 1280, "run_metadata_changed"),
            ("startedHostUs", HOST + 1, "run_metadata_changed"),
        ):
            records = valid_run()
            records[2][name] = value
            issue(records, expected)
        records = valid_run()
        records[4]["session"] = "11111111-2222-3333-4444-555555555555"
        result = analyze(records)
        self.assertFalse(result["eligibleSingleRun"])
        self.assertEqual(len(result["runs"]), 2)
        self.assertFalse(any(run["technicalValid"] for run in result["runs"]))
        records = valid_run()
        records[-1]["firstUserTicks"] += 1
        issue(records, "terminal_endpoint_mismatch")

    def test_overflow_invalid_numbers_and_optional_cpu_fail_closed(self):
        records = valid_run()
        records[2].update(firstUserTicks=0, firstSystemTicks=0,
                          lastUserTicks=analyzer.UINT64_MAX, lastSystemTicks=1)
        issue(records, "cpu_delta_overflow")
        for value in ("-1", str(analyzer.UINT64_MAX + 1), "NaN", "true", "1e4"):
            records = valid_run()
            records[2]["lastUserTicks"] = value
            self.assertFalse(analyze(records)["eligibleSingleRun"])
        records = valid_run()
        records[2]["lastUserTicks"] = "unavailable"
        issue(records, "unavailable_cpu_endpoint")

    def test_failed_stopped_and_missing_terminal_stay_visible(self):
        for phase, reason in (("failed", "videoStalled"), ("stopped", "sessionEnded"), ("failed", "interrupted")):
            records = valid_run()[:5]
            terminal = dict(records[-1], phase=phase, reason=reason, cpuProcessPercent="unavailable")
            for suffix in analyzer.ENDPOINT_SUFFIXES:
                terminal['first' + suffix] = records[1]['first' + suffix]
            records.append(terminal)
            run = analyze(records)["runs"][0]
            self.assertEqual(run["status"], phase)
            self.assertEqual(run["sampleCount"], 3)
            self.assertFalse(run["technicalValid"])
            self.assertIsNone(run["cpu"])
        result = analyze(valid_run()[:-1])
        self.assertEqual(result["runs"][0]["status"], "incomplete_run")
        early = empty_record()
        early.update(phase="stopped", reason="sessionEnded", startedHostUs="unavailable", hostUs="unavailable")
        self.assertEqual(analyze([early])["runs"][0]["status"], "stopped")

    def test_corruption_and_privacy_invalidate_otherwise_complete_file(self):
        secret = b"SECRET_ACCOUNT_TOKEN_PRIVATE_PAYLOAD"
        valid = encode(valid_run())
        bad_lines = [b"timestamp " + valid.splitlines(keepends=True)[0],
                     valid.splitlines(keepends=True)[0][:-1] + b" " + secret + b"\n",
                     analyzer.PREFIX + b"secret=" + secret + b"\n",
                     analyzer.PREFIX + b"\xff\xfe\n",
                     valid.splitlines(keepends=True)[0].replace(b"schema=2", b"schema=1"),
                     valid.splitlines(keepends=True)[0].replace(b"schema=2", b"schema=2 schema=2"),
                     valid.splitlines(keepends=True)[0][:-1]]
        for bad in bad_lines:
            result = analyzer.analyze_stream(io.BytesIO(valid + bad))
            self.assertTrue(result["inputHasRejectedRecords"])
            self.assertFalse(result["eligibleSingleRun"])
            self.assertFalse(result["runs"][0]["technicalValid"])
            self.assertNotIn(secret.decode(), json.dumps(result))
        result = analyzer.analyze_stream(io.BytesIO(secret + b"\n" + valid))
        self.assertTrue(result["eligibleSingleRun"])
        self.assertNotIn(secret.decode(), json.dumps(result))

    def test_limits_are_bounded_and_not_silently_accepted(self):
        huge = analyzer.PREFIX + b"x" * analyzer.MAX_LINE_BYTES + b"\n"
        result = analyzer.analyze_stream(io.BytesIO(huge + encode(valid_run())))
        self.assertFalse(result["eligibleSingleRun"])
        self.assertEqual(result["rejectedRecordCounts"], {"oversized_probe_line": 1})
        # A corrupted prefix can move the marker across bounded read chunks.
        split_marker = b"x" * (analyzer.MAX_LINE_BYTES - 5) + analyzer.MARKER + b"\n"
        result = analyzer.analyze_stream(io.BytesIO(split_marker + encode(valid_run())))
        self.assertFalse(result["eligibleSingleRun"])
        self.assertEqual(result["rejectedRecordCounts"], {"oversized_probe_line": 1})
        records = [valid_run()[0]] * (analyzer.MAX_RECORDS + 5)
        result = analyze(records)
        self.assertEqual(result["runs"][0]["recordCount"], analyzer.MAX_RECORDS)
        self.assertIn("record_limit", result["runs"][0]["issues"])
        records = [empty_record(session=f"{index:08x}-2222-3333-4444-555555555555")
                   for index in range(analyzer.MAX_RUNS + 1)]
        result = analyze(records)
        self.assertEqual(len(result["runs"]), analyzer.MAX_RUNS)
        self.assertEqual(result["rejectedRecordCounts"], {"run_limit": 1})
        previous_limit = analyzer.MAX_INPUT_BYTES
        try:
            analyzer.MAX_INPUT_BYTES = len(encode(valid_run()))
            result = analyzer.analyze_stream(io.BytesIO(encode(valid_run()) + b"extra\n"))
        finally:
            analyzer.MAX_INPUT_BYTES = previous_limit
        self.assertFalse(result["eligibleSingleRun"])
        self.assertEqual(result["rejectedRecordCounts"], {"input_size_limit": 1})

    def test_abba_signed_differences_and_independent_descriptive_variation(self):
        files = self.abba_files()
        result = analyzer.aggregate_abba(files)
        self.assertTrue(result["technicalValid"])
        self.assertEqual([p["signedOnMinusOffPercentagePoints"] for p in result["adjacentPairs"]], [2,-1,3,-2])
        self.assertEqual(result["blockContrastsOnMinusOffPercentagePoints"], [0.5,0.5])
        self.assertEqual(result["pairedDifferenceMedianPercentagePoints"], 0.5)
        self.assertEqual(result["pairedDifferenceRangePercentagePoints"], [-2,3])
        self.assertIsNone(result["performanceAccepted"])
        self.assertIsNone(result["physicalConditionsVerified"])
        self.assertEqual(len(result["sameVariantAdjacentComparisons"]), 3)
        self.assertEqual(result["sameVariantCPUPercentRange"], {
            "enabled": {"count": 4, "minimum": 20, "maximum": 25, "range": 5},
            "disabled": {"count": 4, "minimum": 20, "maximum": 24, "range": 4}})

    @staticmethod
    def abba_files():
        modes = ["enabled", "disabled", "disabled", "enabled"] * 2
        values = [22,20,21,20,25,22,24,22]
        return [analyze(valid_run(session=f"{index+1:08x}-2222-3333-4444-555555555555", mode=mode,
                                 percent=value, host_offset_us=index * 120_000_000))
                for index, (mode, value) in enumerate(zip(modes, values))]

    def test_abba_requires_chronological_nonoverlapping_same_boot_host_clocks(self):
        files = self.abba_files()
        # Permuting two OFF files leaves ABBA labels intact but reverses time.
        changed = copy.deepcopy(files)
        changed[1], changed[2] = changed[2], changed[1]
        self.assertIn("abba_host_order_or_overlap", analyzer.aggregate_abba(changed)["issues"])
        # A valid standalone run must still start after the preceding run ended.
        for offset in (89_999_999, 90_000_000):
            changed = copy.deepcopy(files)
            changed[1] = analyze(valid_run(session="22222222-2222-3333-4444-555555555555",
                                           mode="disabled", host_offset_us=offset))
            self.assertTrue(changed[1]["eligibleSingleRun"])
            self.assertIn("abba_host_order_or_overlap", analyzer.aggregate_abba(changed)["issues"])
        changed[1] = analyze(valid_run(session="22222222-2222-3333-4444-555555555555",
                                       mode="disabled", host_offset_us=90_000_001))
        self.assertTrue(analyzer.aggregate_abba(changed)["technicalValid"])
        for name in ("startedHostUs", "measurementStartHostUs", "measurementEndHostUs"):
            changed = copy.deepcopy(files)
            changed[1]["runs"][0][name] = None
            self.assertIn("abba_requires_available_host_bounds", analyzer.aggregate_abba(changed)["issues"])

    def test_abba_rejects_order_identity_configuration_and_all_failed_attempts(self):
        files = self.abba_files()
        self.assertFalse(analyzer.aggregate_abba(files[:-1])["technicalValid"])
        changed = copy.deepcopy(files)
        changed[0], changed[1] = changed[1], changed[0]
        self.assertIn("abba_mode_order_mismatch", analyzer.aggregate_abba(changed)["issues"])
        changed = copy.deepcopy(files)
        changed[-1]["runs"][0]["session"] = changed[0]["runs"][0]["session"]
        self.assertIn("abba_sessions_not_distinct", analyzer.aggregate_abba(changed)["issues"])
        changed = copy.deepcopy(files)
        changed[-1]["runs"][0]["configuration"]["requestedFPS"] = 30
        self.assertIn("abba_configuration_mismatch", analyzer.aggregate_abba(changed)["issues"])
        changed = copy.deepcopy(files)
        changed[1] = analyze(valid_run(mode="disabled")[:-1])
        self.assertFalse(analyzer.aggregate_abba(changed)["technicalValid"])
        # A good replacement in the same file does not hide its earlier attempt.
        changed[1] = analyze(valid_run(mode="disabled")[:-1] + valid_run(session="99999999-2222-3333-4444-555555555555", mode="disabled"))
        self.assertEqual(len(changed[1]["runs"]), 2)
        self.assertFalse(analyzer.aggregate_abba(changed)["technicalValid"])

    def test_cli_keeps_file_order_and_missing_file_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"input.txt"
            path.write_bytes(encode(valid_run()))
            missing = Path(directory)/"SECRET_PATH_TOKEN"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = analyzer.main(["analyzer", str(path), str(missing), "--abba"])
            result = json.loads(output.getvalue())
            self.assertEqual(status, 0)
            self.assertEqual([f["inputIndex"] for f in result["files"]], [1,2])
            self.assertEqual(result["files"][1]["rejectedRecordCounts"], {"input_unavailable":1})
            self.assertFalse(result["abba"]["technicalValid"])
            self.assertNotIn("SECRET_PATH_TOKEN", output.getvalue())
            self.assertNotIn(directory, output.getvalue())
        for argv in (["analyzer"], ["analyzer", "--SECRET_OPTION"],
                     ["analyzer"] + ["SECRET_PATH_TOKEN"] * (analyzer.MAX_FILES + 1)):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(analyzer.main(argv), 2)
            self.assertNotIn("SECRET", output.getvalue())


if __name__ == "__main__":
    unittest.main()
