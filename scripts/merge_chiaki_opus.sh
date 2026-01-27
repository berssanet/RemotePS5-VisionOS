#!/bin/bash
# Merge libchiaki_full ORIGINAL (with OpenSSL) + libopus + opus decoder objects
# This creates the final libchiaki_full.a with OPUS support

set -e

PROJECT_DIR="/Users/berssanette/Desktop/Projetos/VisionRemotePS5"
CHIAKI_BUILD="$PROJECT_DIR/chiaki-ng/build-visionos-xcframework"
XCFRAMEWORK_DIR="$PROJECT_DIR/VisionRemotePS5/Frameworks/Chiaki.xcframework/xros-arm64"
OPUS_LIB="$PROJECT_DIR/opus-build/output/libopus.a"
OUTPUT_DIR="$PROJECT_DIR/chiaki-ng/opus-enabled-lib"

echo "🔧 Merging ORIGINAL libchiaki (with OpenSSL) + libopus + OPUS decoder..."

# CRITICAL: Use the ORIGINAL library from xcframework (3.4 MB with OpenSSL)
# NOT the minimal library from build dir (275 KB without OpenSSL)
ORIGINAL_CHIAKI="$XCFRAMEWORK_DIR/libchiaki_full.a.orig"

if [ ! -f "$ORIGINAL_CHIAKI" ]; then
    # Try backup
    ORIGINAL_CHIAKI="$XCFRAMEWORK_DIR/libchiaki_full.a.backup"
fi

if [ ! -f "$ORIGINAL_CHIAKI" ]; then
    echo "❌ Original libchiaki_full.a not found!"
    echo "   Looking for: $XCFRAMEWORK_DIR/libchiaki_full.a.orig"
    exit 1
fi

echo "📦 Using original library: $ORIGINAL_CHIAKI ($(ls -lh "$ORIGINAL_CHIAKI" | awk '{print $5}'))"

if [ ! -f "$OPUS_LIB" ]; then
    echo "❌ libopus.a not found at $OPUS_LIB"
    exit 1
fi

if [ ! -f "$CHIAKI_BUILD/opusdecoder.o" ]; then
    echo "❌ opusdecoder.o not found at $CHIAKI_BUILD"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# Extract object files from ORIGINAL chiaki library
echo "📦 Extracting object files from ORIGINAL libchiaki_full.a..."
rm -rf chiaki_objs opus_objs
mkdir chiaki_objs opus_objs

cd chiaki_objs
ar -x "$ORIGINAL_CHIAKI"
cd ..

# Extract object files from libopus
cd opus_objs
ar -x "$OPUS_LIB"
cd ..

# Add opus decoder/encoder objects (compiled for OPUS support)
echo "📦 Adding opus decoder/encoder objects..."
cp "$CHIAKI_BUILD/opusdecoder.o" chiaki_objs/
cp "$CHIAKI_BUILD/opusencoder.o" chiaki_objs/

# Create unified library
echo "🔗 Creating unified libchiaki_full.a..."
rm -f libchiaki_full.a
ar rcs libchiaki_full.a chiaki_objs/*.o opus_objs/*.o

# Verify the symbols exist
echo "🔍 Verifying OPUS symbols..."
nm libchiaki_full.a | grep -E "chiaki_opus_decoder_(init|fini|get_sink)" | head -5

echo "🔍 Verifying OpenSSL symbols still present..."
nm libchiaki_full.a | grep -E "BN_bin2bn|ECDH_compute_key" | head -3

# Check size
FINAL_SIZE=$(ls -lh libchiaki_full.a | awk '{print $5}')
echo "📊 Final library size: $FINAL_SIZE (should be ~3.5-4MB)"

# Install to xcframework
echo "💾 Installing to xcframework..."
cp libchiaki_full.a "$XCFRAMEWORK_DIR/libchiaki_full.a"

echo "✅ Successfully created libchiaki_full.a with OPUS support!"
echo "📦 Installed to: $XCFRAMEWORK_DIR/libchiaki_full.a"

# Cleanup
rm -rf chiaki_objs opus_objs

echo "🎉 Done!"
