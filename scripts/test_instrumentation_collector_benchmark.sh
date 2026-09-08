#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-collector-benchmark-test.XXXXXX")
cp "$PROJECT_DIR/VisionRemotePS5Tests/InstrumentationCollectorBenchmarkHostTests.swift" "$TEMP_DIR/main.swift"
for mode in on off; do
  FLAGS=()
  if [[ "$mode" == off ]]; then FLAGS+=(-D DISABLE_PERFORMANCE_COLLECTION); fi
  xcrun swiftc -O "${FLAGS[@]}" -module-cache-path "$TEMP_DIR/cache" \
    "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
    "$PROJECT_DIR/VisionRemotePS5/Services/InputMetrics.swift" \
    "$PROJECT_DIR/VisionRemotePS5/Services/InstrumentationCollectorBenchmark.swift" \
    "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test-$mode"
  "$TEMP_DIR/test-$mode"
done
