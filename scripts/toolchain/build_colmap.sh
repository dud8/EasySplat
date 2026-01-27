#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/colmap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/colmap/colmap.git "$SRC"
fi

cmake -S "$SRC" -B "$BUILD" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DGUI_ENABLED=OFF \
  -DCUDA_ENABLED=OFF

cmake --build "$BUILD" --target install

echo "COLMAP installed to: $INSTALL"
