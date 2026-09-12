#!/usr/bin/env python3
"""Deterministic analyzer fixtures; no device, app state or private logs needed."""

import copy
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import analyze_native_baseline as analyzer

CAPTURE = "11111111-2222-3333-4444-555555555555"
SESSION = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
START = 100_000_000


def line(label, **values):
    return label + " " + " ".join(f"{key}={value}" for key, value in values.items())


def report(sequence, captured):
    rows = ["VisionRemotePS5 performance report", "formatVersion=1", f"session={SESSION}",
            f"capturedHostUs={captured} active=true"]
    for label in analyzer.DURATION_IDS:
        if label == "video.receiveToPresentation":
            rows.append(line(label, count=0, startHostUs="unavailable", endHostUs="unavailable",
                             p50Ms="unavailable", p95Ms="unavailable", p99Ms="unavailable"))
        else:
            duration = 7_000_000 if label.startswith("input.") else 1_000_000
            rows.append(line(label, count=120, startHostUs=captured - duration, endHostUs=captured - 1000,
                             p50Ms="1.000", p95Ms=f"{sequence % 3 + 2}.000", p99Ms="5.000"))
    rows += [
        line("decoder.events", rejectedNew=sequence, accepted=sequence * 300, outputs=sequence * 300,
             errors=0, rejectedInvalid=0, rejectedStopped=0, cancelledBeforeDecode=0),
        line("mailbox.events", overwrittenBeforeAcquire=sequence * 2, published=sequence * 300,
             acquiredFrames=sequence * 298, clearedBeforeAcquire=0, disabledSubmissions=0, staleSubmissions=0),
        line("renderer.gpu", gpuFailures=0, submitted=sequence * 298, completed=sequence * 298),
        line("thermal", rawState=0, changes=0, notificationsReceived=1, rejectedObservations=0,
             eventCount=1, overwrittenEvents=0),
        line("memory.sample", hostUs=captured - 1_000_000, footprintBytes=1_000_000 + sequence * 1000,
             deviceAllocatedBytes=6000, ownedTextureCount=0, ownedTextureBytes=0,
             decoderSubmissions=0, decoderPayloadBytes=0, mailboxPixelBytes=4096),
    ]
    audio = dict(sequence=sequence + 6, intervalStartUs=captured - 6_000_000, hostUs=captured - 1_000_000,
                 sampleRate=48000, channels=2, queuedSamples=3840, capacitySamples=19200,
                 targetSamples=3840, rawThermalState=0)
    audio.update({name: sequence * 10 for name in analyzer.AUDIO_COUNTERS})
    rows.append(line("audio.sample", **audio))
    return "\n".join(rows)


def checkpoint(sequence, *, captured=None):
    captured = START + (sequence - 1) * 5_000_000 if captured is None else captured
    return dict(kind="checkpoint", captureID=CAPTURE, session=SESSION, sequence=sequence,
                startedHostUs=START, capturedHostUs=captured, elapsedUs=captured - START,
                scope="retainedWindow", processingMode="native", reportText=report(sequence, captured))


def terminal(last, kind="completed", reason=None):
    result = {key: value for key, value in last.items() if key != "reportText"}
    result["kind"] = kind
    if reason is not None:
        result["reason"] = reason
    return result


def valid_run():
    records = [checkpoint(sequence) for sequence in range(1, 242)]
    return records + [terminal(records[-1])]


def encoded(records):
    return b"".join(analyzer.PREFIX + json.dumps(record).encode() + b"\n" for record in records)


def analyze(records, noise=b""):
    return analyzer.analyze_stream(io.BytesIO(noise + encoded(records)))


class NativeBaselineAnalysisTests(unittest.TestCase):
    def test_valid_capture_is_complete_but_never_accepted(self):
        result = analyze(valid_run())
        self.assertFalse(result["inputHasRejectedRecords"])
        run = result["runs"][0]
        self.assertTrue(run["captureComplete"])
        self.assertIsNone(run["baselineAccepted"])
        self.assertEqual(run["status"], "complete_capture_requires_review")
        self.assertEqual(run["checkpointCount"], 241)
        self.assertEqual(run["observedDurationUs"], 1_200_000_000)
        self.assertEqual(run["maximumCaptureGapUs"], 5_000_000)
        self.assertEqual(run["drops"]["decoder.events.rejectedNew"]["delta"], 240)
        self.assertEqual(run["drops"]["mailbox.events.overwrittenBeforeAcquire"]["delta"], 480)
        self.assertEqual(run["drops"]["renderer.gpu.gpuFailures"]["delta"], 0)
        self.assertEqual(run["memory"]["uniqueSamples"], 241)
        self.assertEqual(run["memory"]["byteScopes"]["footprintBytes"]["firstToLastDelta"], 240_000)
        self.assertEqual(run["thermal"]["rawCategories"], [0])
        self.assertEqual(run["measurementDataIssues"], [])

    def test_percentiles_are_window_ranges_not_global_or_averaged(self):
        run = analyze(valid_run())["runs"][0]
        video = run["durationWindows"]["video.receiveToDecode"]
        self.assertEqual((video["p95WindowMinimumMs"], video["p95WindowMaximumMs"]), (2, 4))
        self.assertEqual(video["retainedCountMinimum"], 120)
        self.assertEqual(video["windowGaps"], 240)
        self.assertEqual(video["maximumWindowGapUs"], 4_001_000)
        self.assertNotIn("p95Ms", video)
        self.assertNotIn("average", video)
        self.assertEqual(run["durationWindows"]["input.tickInterval"]["overlappingWindows"], 240)
        self.assertIsNone(run["durationWindows"]["video.receiveToPresentation"]["p95WindowMinimumMs"])

    def test_gap_and_exact_boundary(self):
        rows = [checkpoint(1), checkpoint(2, captured=START + 15_000_000)]
        run = analyze(rows)["runs"][0]
        self.assertNotIn("capture_gap_exceeded", run["issues"])
        rows[1] = checkpoint(2, captured=START + 15_000_001)
        run = analyze(rows)["runs"][0]
        self.assertIn("capture_gap_exceeded", run["issues"])
        self.assertFalse(run["captureComplete"])

    def test_duplicate_and_reordering_are_not_silently_fixed(self):
        duplicate = valid_run()
        duplicate.insert(1, copy.deepcopy(duplicate[0]))
        run = analyze(duplicate)["runs"][0]
        self.assertIn("duplicate_checkpoint_sequence", run["issues"])
        self.assertFalse(run["captureComplete"])
        reordered = valid_run()
        reordered[2], reordered[3] = reordered[3], reordered[2]
        run = analyze(reordered)["runs"][0]
        self.assertIn("checkpoint_sequence_not_contiguous_in_arrival_order", run["issues"])
        self.assertIn("capture_clock_not_increasing", run["issues"])

    def test_terminal_bounds_duration_and_clock_consistency(self):
        for key in ("sequence", "startedHostUs", "capturedHostUs", "elapsedUs"):
            records = valid_run()
            records[-1][key] -= 1
            run = analyze(records)["runs"][0]
            self.assertFalse(run["captureComplete"])
            self.assertIn("completed_terminal_bounds_mismatch", run["issues"])
        short = [checkpoint(1), checkpoint(2)]
        short.append(terminal(short[-1]))
        self.assertIn("completed_duration_out_of_range", analyze(short)["runs"][0]["issues"])
        bad_elapsed = [checkpoint(1), checkpoint(2)]
        bad_elapsed[1]["elapsedUs"] += 1
        self.assertIn("elapsed_clock_mismatch", analyze(bad_elapsed)["runs"][0]["issues"])
        bad_start = [checkpoint(1), checkpoint(2)]
        bad_start[1]["startedHostUs"] += 1
        self.assertIn("start_clock_changed", analyze(bad_start)["runs"][0]["issues"])

    def test_stopped_failed_and_missing_terminal_are_incomplete(self):
        for kind, reason in (("stopped", "sessionEnded"), ("failed", "captureFailed")):
            records = [checkpoint(1), checkpoint(2)]
            records.append(terminal(records[-1], kind, reason))
            run = analyze(records)["runs"][0]
            self.assertFalse(run["captureComplete"])
            self.assertEqual(run["status"], "incomplete_capture")
            self.assertEqual(run["terminalKind"], kind)
            self.assertEqual(run["terminalReason"], reason)
        self.assertEqual(analyze([checkpoint(1)])["runs"][0]["status"], "incomplete_capture")
        warmup = dict(kind="stopped", captureID=CAPTURE, session=SESSION, sequence=0,
                      scope="retainedWindow", processingMode="native", reason="cancelled")
        run = analyze([warmup])["runs"][0]
        self.assertIsNone(run["observedDurationUs"])
        self.assertEqual(run["checkpointCount"], 0)

    def test_output_failure_reason_keeps_unwritten_attempt_incomplete(self):
        records = [checkpoint(1), checkpoint(2)]
        # A writer can fail after observing checkpoint 3 but before persisting
        # that checkpoint. Its failure terminal must not invent the missing row.
        records.append(terminal(checkpoint(3), "failed", "outputFailed"))
        result = analyze(records)
        self.assertFalse(result["inputHasRejectedRecords"])
        run = result["runs"][0]
        self.assertEqual(run["status"], "incomplete_capture")
        self.assertEqual(run["terminalKind"], "failed")
        self.assertEqual(run["terminalReason"], "outputFailed")
        self.assertEqual(run["checkpointCount"], 2)
        self.assertEqual(run["observedDurationUs"], 5_000_000)
        self.assertFalse(run["captureComplete"])
        self.assertIsNone(run["baselineAccepted"])
        contradictory = valid_run()
        contradictory[-1]["reason"] = "outputFailed"
        invalid = analyze(contradictory)["runs"][0]
        self.assertIn("completed_terminal_has_failure_reason", invalid["issues"])
        self.assertFalse(invalid["captureComplete"])

    def test_cli_partial_source_never_counts_as_published_completion(self):
        with tempfile.TemporaryDirectory(prefix="native-baseline-analysis-") as folder:
            partial = Path(folder) / "capture.ndjson.partial"
            partial.write_bytes(encoded(valid_run()))
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(analyzer.main(["analyze_native_baseline.py", str(partial)]), 0)
            result = json.loads(stdout.getvalue())
            self.assertEqual(result["sourcePublication"], "unpublished_partial")
            self.assertEqual(result["publicationIssue"], "source_is_unpublished_partial")
            run = result["runs"][0]
            self.assertEqual(run["terminalKind"], "completed")
            self.assertFalse(run["captureComplete"])
            self.assertEqual(run["status"], "incomplete_unpublished_capture")
            self.assertIn("source_is_unpublished_partial", run["issues"])
            self.assertIsNone(run["baselineAccepted"])
            self.assertNotIn(str(folder), stdout.getvalue())
            final = partial.with_suffix("")
            partial.rename(final)
            published = analyzer.analyze_path(final)
            self.assertEqual(published["sourcePublication"], "final_ndjson_name")
            self.assertTrue(published["runs"][0]["captureComplete"])
            self.assertIsNone(published["runs"][0]["baselineAccepted"])

    def test_dedup_stale_memory_and_counter_regression(self):
        records = [checkpoint(1), checkpoint(2), checkpoint(3, captured=START + 20_000_000)]
        original_memory = next(row for row in records[0]["reportText"].splitlines() if row.startswith("memory.sample "))
        original_audio = next(row for row in records[0]["reportText"].splitlines() if row.startswith("audio.sample "))
        for record in records[1:]:
            record["reportText"] = "\n".join(
                original_memory if row.startswith("memory.sample ") else
                original_audio if row.startswith("audio.sample ") else row
                for row in record["reportText"].splitlines())
        records[2]["reportText"] = records[2]["reportText"].replace("rejectedNew=3", "rejectedNew=0")
        run = analyze(records)["runs"][0]
        self.assertEqual(run["memory"]["uniqueSamples"], 1)
        self.assertEqual(run["memory"]["repeatedRows"], 2)
        self.assertEqual(run["audio"]["uniqueSamples"], 1)
        self.assertEqual(run["memory"]["staleRowsOver15Seconds"], 1)
        self.assertIn("counter_regression", run["measurementDataIssues"])
        self.assertEqual(run["drops"]["decoder.events.rejectedNew"]["regressions"], 1)
        self.assertIsNone(run["drops"]["decoder.events.rejectedNew"]["delta"])

    def test_missing_footprint_endpoint_never_becomes_zero_delta(self):
        records = [checkpoint(1), checkpoint(2)]
        records[1]["reportText"] = records[1]["reportText"].replace("footprintBytes=1002000", "footprintBytes=unavailable")
        memory = analyze(records)["runs"][0]["memory"]["byteScopes"]["footprintBytes"]
        self.assertEqual(memory["validSamples"], 1)
        self.assertIsNone(memory["last"])
        self.assertIsNone(memory["firstToLastDelta"])

    def test_newer_independent_sample_is_visible_for_review_not_structural_failure(self):
        records = valid_run()
        last_checkpoint = records[-2]
        old_host = last_checkpoint["capturedHostUs"] - 1_000_000
        newer_host = last_checkpoint["capturedHostUs"] + 1
        last_checkpoint["reportText"] = last_checkpoint["reportText"].replace(
            f"hostUs={old_host}", f"hostUs={newer_host}")
        run = analyze(records)["runs"][0]
        self.assertTrue(run["captureComplete"])
        self.assertEqual(run["issues"], [])
        for domain in ("memory", "audio"):
            self.assertEqual(run[domain]["rowsAfterCaptureClock"], 1)
            self.assertIn(domain + ".rowsAfterCaptureClock_review_independent_observation",
                          run["measurementDataIssues"])
        self.assertIsNone(run["baselineAccepted"])

    def test_malformed_and_unknown_text_cannot_leak_secrets(self):
        secret = "RAW_SECRET_ACCOUNT_TOKEN_192.0.2.17_PRIVATE_PAYLOAD"
        record = checkpoint(1)
        record["reportText"] += "\n" + secret
        bad = dict(record, kind=[])
        bad["reportText"] = secret
        noise = (secret.encode() + b"\n[NativeBaseline]{" + secret.encode() + b"}\n"
                 + analyzer.PREFIX + b'{"kind":"' + secret.encode() + b'"}\n')
        result = analyze([record, bad], noise)
        text = json.dumps(result)
        self.assertNotIn(secret, text)
        self.assertNotIn("192.0.2.17", text)
        self.assertTrue(result["inputHasRejectedRecords"])
        self.assertEqual(result["rejectedRecordCounts"]["malformed_prefix"], 1)
        self.assertEqual(result["runs"][0]["checkpointCount"], 1)
        wrong_report_session = checkpoint(1)
        wrong_report_session["reportText"] = wrong_report_session["reportText"].replace(SESSION, CAPTURE)
        self.assertEqual(analyze([wrong_report_session])["runs"][0]["issues"], ["invalid_report"])
        non_native = dict(checkpoint(1), processingMode="enhanced")
        self.assertEqual(analyze([non_native])["rejectedRecordCounts"], {"non_native_record": 1})
        malformed_unicode = dict(checkpoint(1), reportText="\ud800")
        self.assertEqual(analyze([malformed_unicode])["rejectedRecordCounts"], {"invalid_report_encoding": 1})

    def test_native_log_interleaving_at_1024_bytes_is_never_repaired(self):
        records = valid_run()
        target = 159  # Sequence 160, between valid 159 and 161.
        original = encoded([records[target]])
        self.assertGreater(len(original), 1024)
        unrelated = b"[ChiakiOpus] SYNTHETIC_PRIVATE_LOG_SENTINEL\r\n"
        interleaved = original[:1024] + unrelated + original[1024:]
        source = encoded(records[:target]) + interleaved + encoded(records[target + 1:])
        result = analyzer.analyze_stream(io.BytesIO(source))
        self.assertEqual(result["rejectedRecordCounts"], {"invalid_json": 1})
        self.assertEqual(result["ignoredNonBaselineLines"], 1)
        run = result["runs"][0]
        self.assertEqual(run["checkpointCount"], 240)
        self.assertEqual(run["terminalKind"], "completed")
        self.assertFalse(run["captureComplete"])
        self.assertEqual(run["status"], "invalid_capture")
        self.assertIn("checkpoint_sequence_not_contiguous_in_arrival_order", run["issues"])
        self.assertNotIn("SYNTHETIC_PRIVATE_LOG_SENTINEL", json.dumps(result))
        self.assertIsNone(run["baselineAccepted"])

    def test_limits_and_separate_capture_identity(self):
        huge_line = analyzer.PREFIX + b"x" * analyzer.MAX_LINE_BYTES + b"\n"
        result = analyzer.analyze_stream(io.BytesIO(huge_line + encoded([checkpoint(1)])))
        self.assertEqual(result["rejectedRecordCounts"], {"oversized_prefixed_line": 1})
        oversized = dict(checkpoint(1), reportText="x" * (analyzer.MAX_REPORT_BYTES + 1))
        self.assertEqual(analyze([oversized])["rejectedRecordCounts"], {"invalid_report_size": 1})
        warmup = dict(kind="stopped", captureID=CAPTURE, session=SESSION, sequence=0,
                      scope="retainedWindow", processingMode="native", reason="cancelled")
        run = analyze([warmup] * (analyzer.MAX_RECORDS + 1))["runs"][0]
        self.assertIn("record_limit", run["issues"])
        self.assertEqual(run["records"], analyzer.MAX_RECORDS)
        second = checkpoint(1)
        second["captureID"] = "99999999-2222-3333-4444-555555555555"
        self.assertEqual(len(analyze([checkpoint(1), second])["runs"]), 2)


if __name__ == "__main__":
    unittest.main()
