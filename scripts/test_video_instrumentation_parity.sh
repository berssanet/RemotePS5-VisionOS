#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-video-instrumentation-parity.XXXXXX")
python3 - "$PROJECT_DIR" "$TEMP_DIR/Decoder.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'VisionRemotePS5/Services/StreamingService.swift').read_text()
decoder = source[source.index('final class StreamVideoDecoder:'):source.index('// MARK: - Data Extension')]
imports = '''import Foundation
import os
import AVFoundation
import VideoToolbox
import QuartzCore
enum DebugLog {
    static func print(_ message: String) { Swift.print(message) }
    static func info(_ category: String, _ message: String) {}
}
'''
Path(sys.argv[2]).write_text(imports + decoder)
PY
cp "$PROJECT_DIR/VisionRemotePS5Tests/VideoInstrumentationParityHostTests.swift" "$TEMP_DIR/main.swift"
for MODE in on off; do
    FLAGS=()
    if [ "$MODE" = off ]; then FLAGS=(-D DISABLE_PERFORMANCE_COLLECTION); fi
    xcrun swiftc -O "${FLAGS[@]}" -module-cache-path "$TEMP_DIR/cache" \
        "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
        "$PROJECT_DIR/VisionRemotePS5/Services/ContinuationGate.swift" \
        "$PROJECT_DIR/VisionRemotePS5/Streaming/UpscalingPipeline.swift" \
        "$TEMP_DIR/Decoder.swift" "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test-$MODE"
    "$TEMP_DIR/test-$MODE" > "$TEMP_DIR/$MODE.log"
    cat "$TEMP_DIR/$MODE.log"
done
python3 - "$TEMP_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def results(mode):
    return [line for line in (root / f'{mode}.log').read_text().splitlines() if line.startswith('PARITY ')]
on, off = results('on'), results('off')
assert len(on) == 3 and on == off, f'Functional parity differs: {on!r} != {off!r}'
print('PASS: ON/OFF optimized builds have identical asserted mailbox/H.264/HEVC functional outcomes')
PY
