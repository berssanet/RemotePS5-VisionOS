#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-stereo-gpu-test.XXXXXX")
cat > "$TEMP_DIR/DebugLog.swift" <<'SWIFT'
enum DebugLog {
 static func print(_ message: String) { Swift.print(message) }
 static func info(_ category: String, _ message: String) {}
 static func warning(_ category: String, _ message: String) { Swift.print(message) }
 static func error(_ category: String, _ message: String) { Swift.print(message) }
 static func every(_ count: UInt64, interval: UInt64, _ category: String, _ message: String) {}
}
SWIFT
cp "$PROJECT_DIR/VisionRemotePS5Tests/StereoVideoGPUHostTests.swift" "$TEMP_DIR/main.swift"
xcrun swiftc -module-cache-path "$TEMP_DIR/cache" \
 "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
 "$PROJECT_DIR/VisionRemotePS5/Streaming/UpscalingPipeline.swift" \
 "$PROJECT_DIR/VisionRemotePS5/Streaming/StereoVideoProcessor.swift" \
 "$TEMP_DIR/DebugLog.swift" "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
