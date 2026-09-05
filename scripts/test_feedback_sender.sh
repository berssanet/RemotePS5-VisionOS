#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
CHIAKI_DIR="$PROJECT_DIR/chiaki-ng"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vision-feedback-test.XXXXXX")
HEADERS="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/Headers"
git -C "$CHIAKI_DIR" show 25f89d386caf20de099040344ecf6b84342acb3e:lib/src/feedbacksender.c > "$TEMP_DIR/feedbacksender.c"
python3 "$SCRIPT_DIR/patches/feedback_sender.py" "$TEMP_DIR/feedbacksender.c"
xcrun --sdk macosx clang -I"$HEADERS" -I"$TEMP_DIR" -Wall -Wextra -Wno-unused-parameter \
 -DCHIAKI_LIB_ENABLE_MBEDTLS=1 -DCHIAKI_LIB_ENABLE_OPUS=1 \
 "$PROJECT_DIR/VisionRemotePS5Tests/FeedbackSenderTests.c" \
 "$CHIAKI_DIR/lib/src/controller.c" "$CHIAKI_DIR/lib/src/feedback.c" \
 "$CHIAKI_DIR/lib/src/thread.c" "$CHIAKI_DIR/lib/src/time.c" \
 -o "$TEMP_DIR/test"
"$TEMP_DIR/test"
