#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/colmap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
OPENMP_ROOT=""

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/colmap/colmap.git "$SRC"
fi

if command -v brew >/dev/null 2>&1; then
  OPENMP_ROOT="$(brew --prefix libomp 2>/dev/null || true)"
fi

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$INSTALL"
  -DGUI_ENABLED=OFF
  -DCUDA_ENABLED=OFF
)

if [ -n "$OPENMP_ROOT" ]; then
  CMAKE_ARGS+=(-DOpenMP_ROOT="$OPENMP_ROOT")
fi

cmake -S "$SRC" -B "$BUILD" -GNinja "${CMAKE_ARGS[@]}"

cmake --build "$BUILD" --target install

echo "COLMAP installed to: $INSTALL"
