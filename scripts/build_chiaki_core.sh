#!/bin/bash
# Build script for chiaki-ng core library targeting visionOS
# This compiles only the core authentication/crypto modules needed for PS5 registration

set -e

echo "🔨 Building chiaki-ng core for visionOS..."

# Navigate to chiaki-ng directory
cd "$(dirname "$0")/../chiaki-ng"

# Create build directory
BUILD_DIR="build-visionos"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure CMake for visionOS
echo "⚙️  Configuring CMake..."
cmake .. \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCHIAKI_ENABLE_CLI=OFF \
  -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_TESTS=OFF \
  -DCHIAKI_ENABLE_ANDROID=OFF \
  -DCHIAKI_ENABLE_BOREALIS=OFF \
  -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
  -DCHIAKI_ENABLE_PI_DECODER=OFF \
  -DCHIAKI_LIB_ENABLE_OPUS=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF \
  -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DCHIAKI_ENABLE_SPEEX=OFF \
  -DCHIAKI_ENABLE_RUDP=OFF

# Build the library
echo "🔧 Building chiaki-lib..."
cmake --build . --target chiaki-lib --config Release

# Check if library was created
if [ -f "lib/libchiaki.a" ]; then
    echo "✅ Chiaki core library compiled successfully!"
    echo "📦 Library location: $(pwd)/lib/libchiaki.a"
    
    # Copy to a known location for Xcode
    FRAMEWORK_DIR="../build-output"
    mkdir -p "$FRAMEWORK_DIR"
    cp lib/libchiaki.a "$FRAMEWORK_DIR/"
    echo "📋 Copied to: $FRAMEWORK_DIR/libchiaki.a"
else
    echo "❌ Build failed - library not found"
    exit 1
fi

echo "🎉 Build complete!"
