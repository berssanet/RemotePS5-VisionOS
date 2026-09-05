#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-decoder-test.XXXXXX")
python3 - "$PROJECT_DIR" "$TEMP_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
s=(root/'VisionRemotePS5/Services/StreamingService.swift').read_text()
decoder=s[s.index('final class StreamVideoDecoder:'):s.index('// MARK: - Data Extension')]
stub='''import Foundation
import os
import AVFoundation
import VideoToolbox
import QuartzCore
enum DebugLog {
 static func print(_ message: String) { Swift.print(message) }
 static func info(_ category: String, _ message: String) {}
}
'''
gate=(root/'VisionRemotePS5/Services/ContinuationGate.swift').read_text()
tests=(root/'VisionRemotePS5Tests/VideoDecoderHostTests.swift').read_text()
Path(sys.argv[2]).write_text(stub+gate+decoder+tests)
PY
xcrun swiftc -module-cache-path "$TEMP_DIR/cache" "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
