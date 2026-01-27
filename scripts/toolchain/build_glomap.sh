#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/glomap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
COLMAP_INSTALL="${COLMAP_INSTALL:-$ROOT/Toolchains/build/colmap/install}"

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/colmap/glomap.git "$SRC"
fi

cmake -S "$SRC" -B "$BUILD" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DFETCH_COLMAP=OFF \
  -DCOLMAP_DIR="$COLMAP_INSTALL/share/colmap"

cmake --build "$BUILD" --target install

echo "GLOMAP installed to: $INSTALL"
