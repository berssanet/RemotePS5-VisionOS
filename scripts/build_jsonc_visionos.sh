#!/bin/bash
# Build json-c 0.18 as a static library for visionOS arm64.
# libchiaki_full.a (holepunch.c) references json-c symbols that are not part of the
# merged archive; the app links this library alongside it (see LIBRARY_SEARCH_PATHS /
# OTHER_LDFLAGS in project.pbxproj). Output: VisionRemotePS5/Frameworks/json-c/libjson-c.a
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${JSONC_WORK_DIR:-/tmp/jsonc-visionos}"
VERSION="json-c-0.18-20240915"
SDK="$(xcrun --sdk xros --show-sdk-path)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [ ! -d "json-c-$VERSION" ]; then
  curl -sL -o json-c.tar.gz "https://github.com/json-c/json-c/archive/refs/tags/$VERSION.tar.gz"
  tar xzf json-c.tar.gz
fi
cmake -S "json-c-$VERSION" -B build-xros -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_APPS=OFF \
  -DDISABLE_WERROR=ON -DDISABLE_EXTRA_LIBS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-xros -j8
mkdir -p "$PROJECT_DIR/VisionRemotePS5/Frameworks/json-c"
cp build-xros/libjson-c.a "$PROJECT_DIR/VisionRemotePS5/Frameworks/json-c/libjson-c.a"
echo "Installed $PROJECT_DIR/VisionRemotePS5/Frameworks/json-c/libjson-c.a"
