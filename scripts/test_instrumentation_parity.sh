#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-instrumentation-parity.XXXXXX")
cp "$PROJECT_DIR/VisionRemotePS5Tests/InstrumentationParityHostTests.swift" "$TEMP_DIR/main.swift"
for variant in enabled disabled; do
  flags=()
  if [ "$variant" = disabled ]; then flags+=(-D DISABLE_PERFORMANCE_COLLECTION); fi
  xcrun swiftc -O -D AUDIO_RING_BUFFER_TESTING "${flags[@]}" -module-cache-path "$TEMP_DIR/cache" \
    "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
    "$PROJECT_DIR/VisionRemotePS5/Services/InputMetrics.swift" \
    "$PROJECT_DIR/VisionRemotePS5/Controllers/HighFrequencyInputController.swift" \
    "$PROJECT_DIR/VisionRemotePS5/Streaming/AudioRingBuffer.swift" \
    "$TEMP_DIR/main.swift" -o "$TEMP_DIR/$variant"
  "$TEMP_DIR/$variant" | tee "$TEMP_DIR/$variant.log"
  rg '^(PCM_PARITY|INPUT_PARITY) ' "$TEMP_DIR/$variant.log" > "$TEMP_DIR/$variant.signature"
done
cmp "$TEMP_DIR/enabled.signature" "$TEMP_DIR/disabled.signature"
echo "PASS: enabled/disabled synthetic PCM output and input lifecycle signatures are identical (not a timing benchmark)"
