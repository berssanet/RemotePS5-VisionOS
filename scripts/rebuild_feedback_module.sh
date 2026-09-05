#!/bin/bash
# Reproducible, ABI-preserving update of only the feedback sender archive member.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
CHIAKI_DIR="$PROJECT_DIR/chiaki-ng"
HEADERS="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/Headers"
LIBRARY="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-feedback.XXXXXX")
SOURCE_COMMIT=25f89d386caf20de099040344ecf6b84342acb3e
git -C "$CHIAKI_DIR" show "$SOURCE_COMMIT:lib/src/feedbacksender.c" > "$TEMP_DIR/feedbacksender.c"
python3 "$SCRIPT_DIR/patches/feedback_sender.py" "$TEMP_DIR/feedbacksender.c"
SDK_PATH=$(xcrun --sdk xros --show-sdk-path)
xcrun --sdk xros clang -target arm64-apple-xros2.0 -isysroot "$SDK_PATH" \
  -I"$HEADERS" -DCHIAKI_LIB_ENABLE_MBEDTLS=1 -DCHIAKI_LIB_ENABLE_OPUS=1 \
  -O2 -fPIC -Wall -Werror -c "$TEMP_DIR/feedbacksender.c" -o "$TEMP_DIR/feedbacksender.c.o"
# Keep other same-basename members intact: never extract/repack the whole archive.
xcrun ar r "$LIBRARY" "$TEMP_DIR/feedbacksender.c.o"
xcrun ranlib "$LIBRARY"
printf 'Rebuilt feedbacksender.c.o from %s; sources: %s\n' "$SOURCE_COMMIT" "$TEMP_DIR"
