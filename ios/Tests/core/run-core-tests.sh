#!/usr/bin/env bash
# Host (macOS/Linux) test of the C++ bridge core (LyricoTagCore) against TagLib's own sample files.
set -euo pipefail
IOS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$(cd "$IOS_DIR/.." && pwd)"
SRC="$ROOT/lyrico-audiotag/src/main/cpp/taglib"
B="$IOS_DIR/build/core-test"
rm -rf "$B" && mkdir -p "$B"
cmake -S "$SRC" -B "$B/taglib" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_BINDINGS=OFF -DWITH_ZLIB=OFF -DCMAKE_INSTALL_PREFIX="$B/prefix" >/dev/null
cmake --build "$B/taglib" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null
cmake --install "$B/taglib" >/dev/null
N="$IOS_DIR/LyricoMod/AudioTag/Native"
c++ -std=c++17 -O1 -I"$N" -I"$B/prefix/include/taglib" "$IOS_DIR/Tests/core/core_test.cpp" "$N/LyricoTagCore.cpp" "$B/prefix/lib/libtag.a" -o "$B/core_test"
"$B/core_test" "$SRC/tests/data"
