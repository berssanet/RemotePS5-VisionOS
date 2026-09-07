#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-input-metrics-test.XXXXXX")
cp "$PROJECT_DIR/VisionRemotePS5Tests/InputMetricsHostTests.swift" "$TEMP_DIR/main.swift"
xcrun swiftc -D INPUT_METRICS_TESTING -module-cache-path "$TEMP_DIR/cache" \
  "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/InputMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Controllers/HighFrequencyInputController.swift" \
  "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
