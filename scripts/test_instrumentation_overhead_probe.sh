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
  "$TEMP_DIR/$variant"
done
echo "PASS: common OS observer compiles and validates identically with performance collection enabled and disabled"
