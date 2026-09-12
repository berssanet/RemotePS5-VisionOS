#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-depth-test.XXXXXX")
xcrun coremlcompiler compile "$PROJECT_DIR/VisionRemotePS5/Resources/DepthAnythingV2SmallF16.mlpackage" "$TEMP_DIR"
cp "$PROJECT_DIR/VisionRemotePS5Tests/DepthEstimationHostTests.swift" "$TEMP_DIR/main.swift"
xcrun swiftc -module-cache-path "$TEMP_DIR/cache" \
 "$PROJECT_DIR/VisionRemotePS5/Services/StreamingMetrics.swift" \
 "$PROJECT_DIR/VisionRemotePS5/Streaming/UpscalingPipeline.swift" \
 "$PROJECT_DIR/VisionRemotePS5/Streaming/DepthEstimationService.swift" \
 "$TEMP_DIR/main.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test" "$TEMP_DIR/DepthAnythingV2SmallF16.mlmodelc"
