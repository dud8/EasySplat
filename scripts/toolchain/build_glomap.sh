#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/glomap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
COLMAP_INSTALL="${COLMAP_INSTALL:-$ROOT/Toolchains/build/colmap/install}"
GLOMAP_REF="${GLOMAP_REF:-bfa9af89be8d8d49a58deeed3ef28d7960a37d06}"
COLMAP_CONFIG_DIR=""
OPENMP_ROOT=""

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/colmap/glomap.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$GLOMAP_REF"
git -C "$SRC" checkout -q FETCH_HEAD

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
  -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON
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
