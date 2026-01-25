#!/bin/bash
# Build minimal chiaki-ng core library for visionOS (arm64)
# Only includes essential crypto/registration functions, no network code

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIAKI_DIR="$SCRIPT_DIR/../chiaki-ng"
BUILD_DIR="$CHIAKI_DIR/build-visionos-minimal"
OUTPUT_LIB="$BUILD_DIR/libchiaki-core.a"

echo "=== Building Minimal Chiaki Core for visionOS ==="

# Get visionOS SDK
SDK_PATH=$(xcrun --sdk xros --show-sdk-path)
CLANG=$(xcrun --sdk xros --find clang)
AR=$(xcrun --sdk xros --find ar)
LIBTOOL=$(xcrun --sdk xros --find libtool)

echo "SDK: $SDK_PATH"
echo "Clang: $CLANG"

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/obj"

# Compiler flags for visionOS
CFLAGS="-target arm64-apple-xros1.0 \
        -isysroot $SDK_PATH \
        -I$CHIAKI_DIR/lib/include \
        -I$CHIAKI_DIR/third-party/mbedtls/include \
        -DCHIAKI_LIB_ENABLE_MBEDTLS=1 \
        -O2 \
        -fPIC \
        -Wall \
        -Wno-unused-function"

# Essential source files (crypto/registration only, no network)
SOURCES=(
    "$CHIAKI_DIR/lib/src/base64.c"
    "$CHIAKI_DIR/lib/src/rpcrypt.c"
    "$CHIAKI_DIR/lib/src/random.c"
    "$CHIAKI_DIR/lib/src/log.c"
    "$CHIAKI_DIR/lib/src/common.c"
    "$CHIAKI_DIR/lib/src/thread.c"
    "$CHIAKI_DIR/lib/src/stoppipe.c"
    "$CHIAKI_DIR/lib/src/time.c"
)

# MbedTLS source files (crypto primitives)
# We'll compile these as well for the crypto functions
MBEDTLS_SOURCES=(
    "$CHIAKI_DIR/third-party/mbedtls/library/aes.c"
    "$CHIAKI_DIR/third-party/mbedtls/library/platform_util.c"
    "$CHIAKI_DIR/third-party/mbedtls/library/constant_time.c"
    "$CHIAKI_DIR/third-party/mbedtls/library/cipher.c"
    "$CHIAKI_DIR/third-party/mbedtls/library/cipher_wrap.c"
    "$CHIAKI_DIR/third-party/mbedtls/library/md.c"
    "$CHIAKI_DIR/third-party/mbedtls/library/sha256.c"
)

echo "Compiling chiaki core sources..."
for src in "${SOURCES[@]}"; do
    if [ -f "$src" ]; then
        name=$(basename "$src" .c)
        echo "  $name.c"
        "$CLANG" $CFLAGS -c "$src" -o "$BUILD_DIR/obj/$name.o"
    else
        echo "  WARNING: $src not found, skipping"
    fi
done

echo "Compiling mbedtls sources..."
for src in "${MBEDTLS_SOURCES[@]}"; do
    if [ -f "$src" ]; then
        name=$(basename "$src" .c)
        echo "  $name.c"
        "$CLANG" $CFLAGS -I"$CHIAKI_DIR/third-party/mbedtls/library" \
            -c "$src" -o "$BUILD_DIR/obj/mbedtls_$name.o" 2>/dev/null || echo "    (skipped - missing deps)"
    fi
done

echo "Creating static library..."
cd "$BUILD_DIR/obj"
"$LIBTOOL" -static -o "$OUTPUT_LIB" *.o

echo ""
echo "=== Build Complete ==="
echo "Library: $OUTPUT_LIB"
file "$OUTPUT_LIB"
lipo -info "$OUTPUT_LIB"
echo "Size: $(du -h "$OUTPUT_LIB" | cut -f1)"
