#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-video-queue-metrics-test.XXXXXX")
cp "$PROJECT_DIR/VisionRemotePS5Tests/VideoQueueMetricsHostTests.swift" "$TEMP_DIR/main.swift"
xcrun swiftc -D DEBUG -module-cache-path "$TEMP_DIR/cache" \
  "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/VideoQueueMetrics.swift" \
  "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
