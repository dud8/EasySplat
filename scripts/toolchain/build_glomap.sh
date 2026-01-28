#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/glomap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
COLMAP_INSTALL="${COLMAP_INSTALL:-$ROOT/Toolchains/build/colmap/install}"
COLMAP_CONFIG_DIR=""
OPENMP_ROOT=""

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/colmap/glomap.git "$SRC"
fi

if command -v brew >/dev/null 2>&1; then
  OPENMP_ROOT="$(brew --prefix libomp 2>/dev/null || true)"
fi

if [ -f "$COLMAP_INSTALL/share/colmap/colmapConfig.cmake" ] || [ -f "$COLMAP_INSTALL/share/colmap/colmap-config.cmake" ]; then
  COLMAP_CONFIG_DIR="$COLMAP_INSTALL/share/colmap"
elif [ -f "$COLMAP_INSTALL/lib/cmake/colmap/colmapConfig.cmake" ] || [ -f "$COLMAP_INSTALL/lib/cmake/colmap/colmap-config.cmake" ]; then
  COLMAP_CONFIG_DIR="$COLMAP_INSTALL/lib/cmake/colmap"
fi

if [ -z "$COLMAP_CONFIG_DIR" ]; then
  echo "COLMAP config not found under $COLMAP_INSTALL (expected share/colmap or lib/cmake/colmap)" >&2
  exit 1
fi

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$INSTALL"
  -DFETCH_COLMAP=OFF
  -DCOLMAP_DIR="$COLMAP_CONFIG_DIR"
  -Dcolmap_DIR="$COLMAP_CONFIG_DIR"
  -DCMAKE_PREFIX_PATH="$COLMAP_INSTALL;$COLMAP_CONFIG_DIR"
)

if [ -n "$OPENMP_ROOT" ]; then
  CMAKE_ARGS+=(-DOpenMP_ROOT="$OPENMP_ROOT")
fi

cmake -S "$SRC" -B "$BUILD" -GNinja "${CMAKE_ARGS[@]}"

cmake --build "$BUILD" --target install

echo "GLOMAP installed to: $INSTALL"
