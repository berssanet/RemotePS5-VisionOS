#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-instrumentation-probe.XXXXXX")
cp "$PROJECT_DIR/VisionRemotePS5Tests/InstrumentationOverheadProbeHostTests.swift" "$TEMP_DIR/main.swift"
for variant in enabled disabled; do
  flags=()
  if [ "$variant" = disabled ]; then flags+=(-D DISABLE_PERFORMANCE_COLLECTION); fi
  xcrun swiftc -O "${flags[@]}" -module-cache-path "$TEMP_DIR/cache" \
    "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
    "$PROJECT_DIR/VisionRemotePS5/Services/InstrumentationOverheadProbe.swift" \
    "$TEMP_DIR/main.swift" -o "$TEMP_DIR/$variant"
  "$TEMP_DIR/$variant" "$TEMP_DIR/$variant.log"
done
python3 - "$SCRIPT_DIR" "$TEMP_DIR" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from analyze_instrumentation_probe import analyze_path

for variant in ("enabled", "disabled"):
    result = analyze_path(Path(sys.argv[2]) / (variant + ".log"))
    assert result["eligibleSingleRun"], "Production Swift output must validate as one complete run"
    run = result["runs"][0]
    assert run["mode"] == variant and run["processingMode"] == "native"
    assert run["sampleCount"] == 12 and run["durationHostUs"] == 60_000_000
    assert run["cpu"]["processPercent"] == 20.0
    assert run["configuration"] == {
        "requestedWidth": 1920, "requestedHeight": 1080,
        "requestedFPS": 60, "requestedBitrateKbps": 15000,
    }
    assert run["performanceAccepted"] is None
print("PASS: production Swift ON/OFF records validate in the independent Python analyzer")
PY
echo "PASS: common OS observer compiles and validates identically with performance collection enabled and disabled"
