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
BOOST_ROOT=""

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/colmap/glomap.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$GLOMAP_REF"
git -C "$SRC" checkout -q FETCH_HEAD

if command -v brew >/dev/null 2>&1; then
  OPENMP_ROOT="$(brew --prefix libomp 2>/dev/null || true)"
  BOOST_ROOT="$(brew --prefix boost 2>/dev/null || true)"
fi

if [ -f "$COLMAP_INSTALL/share/colmap/colmapConfig.cmake" ] || [ -f "$COLMAP_INSTALL/share/colmap/colmap-config.cmake" ]; then
  COLMAP_CONFIG_DIR="$COLMAP_INSTALL/share/colmap"
elif [ -f "$COLMAP_INSTALL/lib/cmake/colmap/colmapConfig.cmake" ] || [ -f "$COLMAP_INSTALL/lib/cmake/colmap/colmap-config.cmake" ]; then
  COLMAP_CONFIG_DIR="$COLMAP_INSTALL/lib/cmake/colmap"
fi

USE_EXTERNAL=1
if [ -z "$COLMAP_CONFIG_DIR" ]; then
  echo "COLMAP config not found under $COLMAP_INSTALL (expected share/colmap or lib/cmake/colmap); falling back to FETCH_COLMAP=ON" >&2
  USE_EXTERNAL=0
fi

if [ "$USE_EXTERNAL" -eq 1 ]; then
  TARGETS_FILE="$COLMAP_CONFIG_DIR/colmap-targets.cmake"
  if [ ! -f "$TARGETS_FILE" ] || ! grep -q "colmap::colmap" "$TARGETS_FILE"; then
    echo "COLMAP targets missing under $COLMAP_CONFIG_DIR; falling back to FETCH_COLMAP=ON" >&2
    USE_EXTERNAL=0
  fi
fi

COMMON_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$INSTALL"
  -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON
)

if [ -n "$OPENMP_ROOT" ]; then
  COMMON_ARGS+=(-DOpenMP_ROOT="$OPENMP_ROOT")
fi
if [ -n "$BOOST_ROOT" ]; then
  COMMON_ARGS+=(-DBoost_ROOT="$BOOST_ROOT")
fi

EXTERNAL_ARGS=()
if [ "$USE_EXTERNAL" -eq 1 ]; then
  EXTERNAL_ARGS=(
    -DFETCH_COLMAP=OFF
    -DCOLMAP_DIR="$COLMAP_CONFIG_DIR"
    -DCMAKE_PREFIX_PATH="$COLMAP_CONFIG_DIR;$COLMAP_INSTALL"
    -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON
    -DCMAKE_FIND_PACKAGE_NO_SYSTEM_PACKAGE_REGISTRY=ON
  )
fi

FALLBACK_ARGS=(
  -DFETCH_COLMAP=ON
)

configure_glomap() {
  cmake -S "$SRC" -B "$BUILD" -GNinja "${COMMON_ARGS[@]}" "$@"
}

if [ "$USE_EXTERNAL" -eq 1 ]; then
  set +e
  configure_glomap "${EXTERNAL_ARGS[@]}"
  CONFIG_STATUS=$?
  set -e
  if [ "$CONFIG_STATUS" -ne 0 ]; then
    echo "External COLMAP config failed; retrying with FETCH_COLMAP=ON" >&2
    rm -rf "$BUILD"
    configure_glomap "${FALLBACK_ARGS[@]}"
  fi
else
  configure_glomap "${FALLBACK_ARGS[@]}"
fi

cmake --build "$BUILD" --target install

echo "GLOMAP installed to: $INSTALL"
