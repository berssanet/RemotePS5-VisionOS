#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-sustained-baseline-test.XXXXXX")
xcrun swiftc -O -parse-as-library -module-cache-path "$TEMP_DIR/cache" \
  "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/InputMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/VideoQueueMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Streaming/AudioRingBuffer.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/AudioThermalMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Streaming/UpscalingPipeline.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/PerformanceReportSnapshot.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/PerformanceReportFormatter.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/SustainedBaselineCapture.swift" \
  "$PROJECT_DIR/VisionRemotePS5Tests/SustainedBaselineCaptureHostTests.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
