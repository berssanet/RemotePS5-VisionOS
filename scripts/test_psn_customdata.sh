#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/psn-customdata-tests"
mkdir -p "$BUILD_DIR"
export TMPDIR="$BUILD_DIR"
CC="${CC:-$(xcrun --find clang)}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

"$CC" -std=c11 -Wall -Wextra -Werror -Wno-error=sign-compare -g -O1 \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -isysroot "$SDK" \
  -I"$PROJECT_DIR/chiaki-ng/lib/include" \
  "$PROJECT_DIR/VisionRemotePS5Tests/PSNCustomDataTests.c" \
  "$PROJECT_DIR/chiaki-ng/lib/src/base64.c" \
  "$PROJECT_DIR/chiaki-ng/lib/src/log.c" \
  -o "$BUILD_DIR/psn-customdata-tests"
"$BUILD_DIR/psn-customdata-tests"
