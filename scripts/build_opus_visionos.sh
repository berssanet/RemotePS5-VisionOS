#!/bin/bash
# Build libopus for visionOS arm64
# This creates a static library that can be linked with Chiaki

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPUS_SRC="$PROJECT_DIR/opus-build/opus-1.5.2"
BUILD_DIR="$PROJECT_DIR/opus-build/build-visionos"
OUTPUT_DIR="$PROJECT_DIR/opus-build/output"

# visionOS SDK settings
XROS_SDK=$(xcrun --sdk xros --show-sdk-path)
XROS_MIN_VERSION="2.0"

echo "🔨 Building libopus for visionOS arm64..."
echo "   SDK: $XROS_SDK"

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure for visionOS arm64
# Using CMake if available, otherwise autotools
if [ -f "$OPUS_SRC/CMakeLists.txt" ]; then
    echo "⚙️  Configuring with CMake..."
    cmake "$OPUS_SRC" \
        -DCMAKE_SYSTEM_NAME=visionOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT="$XROS_SDK" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$XROS_MIN_VERSION" \
        -DCMAKE_BUILD_TYPE=Release \
        -DOPUS_BUILD_PROGRAMS=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
        -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
    
    echo "🔧 Building..."
    cmake --build . --config Release
    
    # Find the library
    OPUS_LIB=$(find . -name "libopus.a" | head -1)
else
    echo "⚙️  Configuring with autotools..."
    cd "$OPUS_SRC"
    
    # Set cross-compile environment
    export CC="xcrun -sdk xros clang"
    export CXX="xcrun -sdk xros clang++"
    export CFLAGS="-arch arm64 -isysroot $XROS_SDK -mxros-version-min=$XROS_MIN_VERSION -fembed-bitcode"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-arch arm64 -isysroot $XROS_SDK"
    export HOST="arm64-apple-darwin"
    
    ./configure --host=$HOST --enable-static --disable-shared --disable-doc --disable-extra-programs
    make clean 2>/dev/null || true
    make -j$(sysctl -n hw.ncpu)
    
    OPUS_LIB=".libs/libopus.a"
fi

# Copy to output
mkdir -p "$OUTPUT_DIR"
if [ -f "$OPUS_LIB" ]; then
    cp "$OPUS_LIB" "$OUTPUT_DIR/libopus.a"
    echo "✅ Successfully built libopus for visionOS!"
    echo "📦 Output: $OUTPUT_DIR/libopus.a"
    
    # Verify architecture
    lipo -info "$OUTPUT_DIR/libopus.a"
else
    echo "❌ Build failed - libopus.a not found"
    exit 1
fi

echo "🎉 Done!"
