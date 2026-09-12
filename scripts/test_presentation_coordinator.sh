#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-presentation-coordinator.XXXXXX")
xcrun swiftc -O -parse-as-library -module-cache-path "$TEMP_DIR/cache" \
  "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
  "$PROJECT_DIR/VisionRemotePS5/Services/PresentationCoordinator.swift" \
  "$PROJECT_DIR/VisionRemotePS5Tests/PresentationCoordinatorHostTests.swift" \
  -o "$TEMP_DIR/presentation-coordinator-tests"
"$TEMP_DIR/presentation-coordinator-tests"
