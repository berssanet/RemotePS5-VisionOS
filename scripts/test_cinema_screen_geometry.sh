#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-cinema-screen-geometry.XXXXXX")
xcrun swiftc -O -parse-as-library -module-cache-path "$TEMP_DIR/cache" \
  "$PROJECT_DIR/VisionRemotePS5/Streaming/CinemaScreenGeometry.swift" \
  "$PROJECT_DIR/VisionRemotePS5Tests/CinemaScreenGeometryHostTests.swift" \
  -o "$TEMP_DIR/cinema-screen-geometry-tests"
"$TEMP_DIR/cinema-screen-geometry-tests"
