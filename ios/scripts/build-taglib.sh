#!/usr/bin/env bash
# Builds TagLib 2.x (git submodule lyrico-audiotag/src/main/cpp/taglib, shared with Android) as a
# static library for iOS. Output: ios/build/taglib/<platform>/{include/taglib,lib/libtag.a}
# Usage: ios/scripts/build-taglib.sh [iphoneos|iphonesimulator ...]   (default: iphoneos)
set -euo pipefail
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$IOS_DIR/.." && pwd)"
SRC="$ROOT/lyrico-audiotag/src/main/cpp/taglib"
DEPLOY="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "TagLib sources missing; run: git submodule update --init --recursive lyrico-audiotag/src/main/cpp/taglib" >&2
  exit 1
fi
if [ ! -f "$SRC/3rdparty/utfcpp/source/utf8.h" ]; then
  git -C "$SRC" submodule update --init --recursive
fi

PLATFORMS=("$@")
[ ${#PLATFORMS[@]} -eq 0 ] && PLATFORMS=(iphoneos)

for PLATFORM in "${PLATFORMS[@]}"; do
  case "$PLATFORM" in
    iphoneos) ARCHS="arm64" ;;
    iphonesimulator) ARCHS="arm64;x86_64" ;;
    *) echo "unknown platform $PLATFORM" >&2; exit 1 ;;
  esac
  BUILD="$IOS_DIR/build/taglib-build/$PLATFORM"
  PREFIX="$IOS_DIR/build/taglib/$PLATFORM"
  rm -rf "$BUILD" "$PREFIX"
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$PLATFORM" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="-fvisibility=hidden -fvisibility-inlines-hidden" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BINDINGS=OFF \
    -DWITH_ZLIB=OFF
  cmake --build "$BUILD" --config Release -j "$JOBS"
  cmake --install "$BUILD" --config Release
  echo "TagLib for $PLATFORM -> $PREFIX"
done
