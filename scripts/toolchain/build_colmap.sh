#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/colmap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
OPENMP_ROOT=""
BOOST_ROOT=""
OPENIMAGEIO_DIR=""
OPENSSL_ROOT=""

mkdir -p "$WORK"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 https://github.com/colmap/colmap.git "$SRC"
fi

if command -v brew >/dev/null 2>&1; then
  OPENMP_ROOT="$(brew --prefix libomp 2>/dev/null || true)"
  BOOST_ROOT="$(brew --prefix boost 2>/dev/null || true)"
  if OPENIMAGEIO_PREFIX="$(brew --prefix openimageio 2>/dev/null)"; then
    OPENIMAGEIO_DIR="$OPENIMAGEIO_PREFIX/lib/cmake/OpenImageIO"
  fi
fi

OPENSSL_BUILD="$ROOT/Toolchains/build/openssl/install"
if [ -d "$OPENSSL_BUILD/lib" ]; then
  OPENSSL_ROOT="$OPENSSL_BUILD"
fi

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$INSTALL"
  -DGUI_ENABLED=OFF
  -DCUDA_ENABLED=OFF
  -DCMAKE_POLICY_DEFAULT_CMP0144=NEW
)

if [ -n "$OPENMP_ROOT" ]; then
  CMAKE_ARGS+=(-DOpenMP_ROOT="$OPENMP_ROOT")
fi
if [ -n "$BOOST_ROOT" ]; then
  CMAKE_ARGS+=(-DBoost_ROOT="$BOOST_ROOT")
fi
if [ -n "$OPENIMAGEIO_DIR" ] && [ -d "$OPENIMAGEIO_DIR" ]; then
  CMAKE_ARGS+=(-DOpenImageIO_DIR="$OPENIMAGEIO_DIR")
fi
if [ -n "$OPENSSL_ROOT" ]; then
  CMAKE_ARGS+=(-DOPENSSL_ROOT_DIR="$OPENSSL_ROOT")
  CMAKE_ARGS+=(-DOPENSSL_USE_STATIC_LIBS=OFF)
fi

cmake -S "$SRC" -B "$BUILD" -GNinja "${CMAKE_ARGS[@]}"

cmake --build "$BUILD" --target install

CONFIG_DIR=""
CONFIG_FILE=""
if [ -f "$INSTALL/share/colmap/colmap-config.cmake" ] || [ -f "$INSTALL/share/colmap/colmapConfig.cmake" ]; then
  CONFIG_DIR="$INSTALL/share/colmap"
elif [ -f "$INSTALL/lib/cmake/colmap/colmap-config.cmake" ] || [ -f "$INSTALL/lib/cmake/colmap/colmapConfig.cmake" ]; then
  CONFIG_DIR="$INSTALL/lib/cmake/colmap"
fi

if [ -z "$CONFIG_DIR" ]; then
  echo "COLMAP config not found under $INSTALL (expected share/colmap or lib/cmake/colmap)" >&2
  exit 1
fi

if [ -f "$CONFIG_DIR/colmap-config.cmake" ]; then
  CONFIG_FILE="$CONFIG_DIR/colmap-config.cmake"
elif [ -f "$CONFIG_DIR/colmapConfig.cmake" ]; then
  CONFIG_FILE="$CONFIG_DIR/colmapConfig.cmake"
else
  echo "COLMAP config file missing in $CONFIG_DIR" >&2
  exit 1
fi

SHIM_FILE="$CONFIG_DIR/colmap-targets-shim.cmake"
cat > "$SHIM_FILE" <<'EOF'
if(NOT TARGET colmap::colmap)
  if(TARGET COLMAP::colmap)
    add_library(colmap::colmap ALIAS COLMAP::colmap)
  elseif(TARGET colmap)
    add_library(colmap::colmap ALIAS colmap)
  endif()
endif()
if(TARGET colmap::colmap AND NOT TARGET COLMAP::colmap)
  add_library(COLMAP::colmap ALIAS colmap::colmap)
endif()
EOF

if ! grep -q "colmap-targets-shim.cmake" "$CONFIG_FILE"; then
  printf '\ninclude("${CMAKE_CURRENT_LIST_DIR}/colmap-targets-shim.cmake")\n' >> "$CONFIG_FILE"
fi

if [ ! -f "$CONFIG_DIR/COLMAPConfig.cmake" ]; then
  cp "$CONFIG_FILE" "$CONFIG_DIR/COLMAPConfig.cmake"
fi

VERSION_FILE=""
if [ -f "$CONFIG_DIR/colmap-config-version.cmake" ]; then
  VERSION_FILE="$CONFIG_DIR/colmap-config-version.cmake"
elif [ -f "$CONFIG_DIR/colmapConfigVersion.cmake" ]; then
  VERSION_FILE="$CONFIG_DIR/colmapConfigVersion.cmake"
fi
if [ -n "$VERSION_FILE" ] && [ ! -f "$CONFIG_DIR/COLMAPConfigVersion.cmake" ]; then
  cp "$VERSION_FILE" "$CONFIG_DIR/COLMAPConfigVersion.cmake"
fi

echo "COLMAP installed to: $INSTALL"
