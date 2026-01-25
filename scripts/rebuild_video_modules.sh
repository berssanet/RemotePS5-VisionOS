#!/bin/bash
# Script to rebuild videoreceiver.c and frameprocessor.c with diagnostic logging
# and update the libchiaki_full.a static library

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
CHIAKI_DIR="$PROJECT_DIR/chiaki-ng"
LIB_PATH="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64/libchiaki_full.a"
TEMP_DIR="$PROJECT_DIR/build-temp"

echo "=== Rebuilding Video Modules for visionOS ==="

# Get visionOS SDK and tools
SDK_PATH=$(xcrun --sdk xros --show-sdk-path)
CLANG=$(xcrun --sdk xros --find clang)
AR=$(xcrun --sdk xros --find ar)
LIBTOOL=$(xcrun --sdk xros --find libtool)

echo "SDK: $SDK_PATH"
echo "Clang: $CLANG"

# Create temp directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Compiler flags (matching the original build)
CFLAGS="-target arm64-apple-xros2.0 \
        -isysroot $SDK_PATH \
        -I$CHIAKI_DIR/lib/include \
        -I$CHIAKI_DIR/third-party/nanopb \
        -I$CHIAKI_DIR/third-party/jerasure/include \
        -I$CHIAKI_DIR/third-party/gf-complete/include \
        -I$CHIAKI_DIR/build-macos/lib/include \
        -I$PROJECT_DIR/mbedtls-src/include \
        -DCHIAKI_LIB_ENABLE_MBEDTLS=1 \
        -O2 \
        -fPIC \
        -Wall \
        -Wno-unused-function"

echo ""
echo "Compiling videoreceiver.c..."
"$CLANG" $CFLAGS -c "$CHIAKI_DIR/lib/src/videoreceiver.c" -o "$TEMP_DIR/videoreceiver.c.o"
echo "  ✅ videoreceiver.c compiled"

echo ""
echo "Compiling frameprocessor.c..."
"$CLANG" $CFLAGS -c "$CHIAKI_DIR/lib/src/frameprocessor.c" -o "$TEMP_DIR/frameprocessor.c.o"
echo "  ✅ frameprocessor.c compiled"

echo ""
echo "Updating static library..."

# Make backup
if [ ! -f "${LIB_PATH}.orig" ]; then
    cp "$LIB_PATH" "${LIB_PATH}.orig"
    echo "  📦 Created backup: libchiaki_full.a.orig"
fi

# Extract all object files
EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
cd "$EXTRACT_DIR"
"$AR" -x "$LIB_PATH"

# Replace the object files
cp "$TEMP_DIR/videoreceiver.c.o" "$EXTRACT_DIR/"
cp "$TEMP_DIR/frameprocessor.c.o" "$EXTRACT_DIR/"
echo "  ✅ Replaced object files"

# Recreate the static library
cd "$EXTRACT_DIR"
rm -f "__.SYMDEF SORTED" "__.SYMDEF" 2>/dev/null || true
"$LIBTOOL" -static -o "$LIB_PATH" *.o
echo "  ✅ Updated libchiaki_full.a"

# Cleanup
cd "$PROJECT_DIR"
rm -rf "$TEMP_DIR"

echo ""
echo "=== Build Complete ==="
echo "Updated: $LIB_PATH"
ls -la "$LIB_PATH"
echo ""
echo "Now rebuild the Xcode project to use the updated library."
