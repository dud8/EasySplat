#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: package_toolchain.sh --version <semver>" >&2
  exit 1
fi

COLMAP_INSTALL="${COLMAP_INSTALL:-$ROOT/Toolchains/build/colmap/install}"
GLOMAP_INSTALL="${GLOMAP_INSTALL:-$ROOT/Toolchains/build/glomap/install}"
BRUSH_INSTALL="${BRUSH_INSTALL:-$ROOT/Toolchains/build/brush/install}"
LEARNED_SFM_INSTALL="${LEARNED_SFM_INSTALL:-$ROOT/Toolchains/build/learned_sfm/install}"

OUT="$ROOT/Toolchains/out"
BIN="$OUT/bin"
LIB="$OUT/lib"
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
MODELS_ZIP="$OUT/toolchain-macos-arm64-$VERSION-models.zip"

rm -rf "$OUT"
mkdir -p "$BIN" "$LIB"

cp "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"
cp "$GLOMAP_INSTALL/bin/glomap" "$BIN/glomap"
cp "$BRUSH_INSTALL/bin/brush" "$BIN/brush"

chmod +x "$BIN/colmap" "$BIN/glomap" "$BIN/brush"

if [ ! -d "$LEARNED_SFM_INSTALL/learned_sfm" ]; then
  echo "learned_sfm bundle not found at $LEARNED_SFM_INSTALL/learned_sfm. Build it before packaging." >&2
  exit 1
fi
if [ ! -x "$LEARNED_SFM_INSTALL/learned_sfm/bin/easysplat_match" ]; then
  echo "learned_sfm bundle missing bin/easysplat_match. Rebuild learned_sfm." >&2
  exit 1
fi
if [ ! -x "$LEARNED_SFM_INSTALL/learned_sfm/python/bin/python3" ]; then
  echo "learned_sfm bundle missing python/bin/python3. Rebuild learned_sfm." >&2
  exit 1
fi
PY_BIN="$LEARNED_SFM_INSTALL/learned_sfm/python/bin/python3"
if ! /usr/bin/file "$PY_BIN" | grep -q "arm64"; then
  echo "learned_sfm python is not arm64 (Rosetta build detected). Rebuild learned_sfm on Apple Silicon." >&2
  exit 1
fi
if [ ! -d "$LEARNED_SFM_INSTALL/learned_sfm/models" ]; then
  echo "learned_sfm bundle missing models/. Rebuild learned_sfm." >&2
  exit 1
fi
if [ ! -d "$LEARNED_SFM_INSTALL/learned_sfm/vendor/mast3r/mast3r" ]; then
  echo "learned_sfm bundle missing vendor/mast3r. Rebuild learned_sfm." >&2
  exit 1
fi
cp -R "$LEARNED_SFM_INSTALL/learned_sfm" "$OUT/learned_sfm"

if ! command -v install_name_tool >/dev/null 2>&1; then
  echo "install_name_tool not found; cannot package portable GLOMAP dependencies." >&2
  exit 1
fi
if ! command -v otool >/dev/null 2>&1; then
  echo "otool not found; cannot validate toolchain binary dependencies." >&2
  exit 1
fi

# Prefer a locally built OpenSSL (portable), then fall back to Homebrew.
OPENSSL_INSTALL="${OPENSSL_INSTALL:-$ROOT/Toolchains/build/openssl/install}"
OPENSSL_PREFIX=""
if [ -d "$OPENSSL_INSTALL/lib" ]; then
  OPENSSL_PREFIX="$OPENSSL_INSTALL"
elif command -v brew >/dev/null 2>&1; then
  OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
  if [ -z "$OPENSSL_PREFIX" ]; then
    OPENSSL_PREFIX="$(brew --prefix openssl 2>/dev/null || true)"
  fi
fi
if [ -z "$OPENSSL_PREFIX" ] && [ -d "/opt/homebrew/opt/openssl@3" ]; then
  OPENSSL_PREFIX="/opt/homebrew/opt/openssl@3"
fi
if [ -z "$OPENSSL_PREFIX" ] && [ -d "/usr/local/opt/openssl@3" ]; then
  OPENSSL_PREFIX="/usr/local/opt/openssl@3"
fi

if [ -z "$OPENSSL_PREFIX" ]; then
  echo "OpenSSL not found. Build it via scripts/toolchain/build_openssl.sh, or install openssl@3." >&2
  exit 1
fi

for lib in libcrypto.3.dylib libssl.3.dylib; do
  if [ ! -f "$OPENSSL_PREFIX/lib/$lib" ]; then
    echo "Missing $OPENSSL_PREFIX/lib/$lib (required by glomap)." >&2
    exit 1
  fi
  cp -L "$OPENSSL_PREFIX/lib/$lib" "$LIB/$lib"
done

# Make the dylib IDs rpath-relative so they work from our bundled lib/ directory.
install_name_tool -id "@rpath/libcrypto.3.dylib" "$LIB/libcrypto.3.dylib"
install_name_tool -id "@rpath/libssl.3.dylib" "$LIB/libssl.3.dylib"

add_rpath_if_missing() {
  local bin="$1"
  local rpath="$2"
  if ! otool -l "$bin" | grep -q "$rpath"; then
    install_name_tool -add_rpath "$rpath" "$bin"
  fi
}

# Ensure GLOMAP can find bundled OpenSSL without Homebrew.
add_rpath_if_missing "$BIN/glomap" "@executable_path/../lib"
add_rpath_if_missing "$BIN/colmap" "@executable_path/../lib"

# If GLOMAP was linked against a Homebrew/OpenSSL install name, rewrite to @rpath.
crypto_dep="$(otool -L "$BIN/glomap" | { grep -m1 'libcrypto\.3\.dylib' || true; } | awk '{print $1}')"
ssl_dep="$(otool -L "$BIN/glomap" | { grep -m1 'libssl\.3\.dylib' || true; } | awk '{print $1}')"
if [ -n "$crypto_dep" ] && [ "$crypto_dep" != "@rpath/libcrypto.3.dylib" ]; then
  install_name_tool -change "$crypto_dep" "@rpath/libcrypto.3.dylib" "$BIN/glomap"
fi
if [ -n "$ssl_dep" ] && [ "$ssl_dep" != "@rpath/libssl.3.dylib" ]; then
  install_name_tool -change "$ssl_dep" "@rpath/libssl.3.dylib" "$BIN/glomap"
fi

# COLMAP links against OpenSSL too; prefer the bundled dylibs.
colmap_crypto_dep="$(otool -L "$BIN/colmap" | { grep -m1 -E 'libcrypto\.3\.dylib|libcrypto\.1\.1\.dylib' || true; } | awk '{print $1}')"
if [ -z "$colmap_crypto_dep" ]; then
  echo "COLMAP does not link to libcrypto; unexpected build configuration." >&2
  exit 1
fi
if [[ "$colmap_crypto_dep" == *"libcrypto.1.1.dylib" ]]; then
  echo "COLMAP links against OpenSSL 1.1; rebuild COLMAP after running build_openssl.sh (OpenSSL 3)." >&2
  exit 1
fi
if [ "$colmap_crypto_dep" != "@rpath/libcrypto.3.dylib" ]; then
  install_name_tool -change "$colmap_crypto_dep" "@rpath/libcrypto.3.dylib" "$BIN/colmap"
fi

# Validate: glomap must have rpath + reference @rpath OpenSSL libs, and we must ship those libs.
otool -l "$BIN/glomap" | grep -q "@executable_path/../lib" || { echo "glomap missing rpath @executable_path/../lib" >&2; exit 1; }
otool -L "$BIN/glomap" | grep -q "@rpath/libcrypto.3.dylib" || { echo "glomap missing dependency @rpath/libcrypto.3.dylib" >&2; exit 1; }
if otool -L "$BIN/glomap" | grep -q "libssl.3.dylib"; then
  otool -L "$BIN/glomap" | grep -q "@rpath/libssl.3.dylib" || { echo "glomap missing dependency @rpath/libssl.3.dylib" >&2; exit 1; }
fi
otool -L "$BIN/colmap" | grep -q "@rpath/libcrypto.3.dylib" || { echo "colmap missing dependency @rpath/libcrypto.3.dylib" >&2; exit 1; }
test -f "$LIB/libcrypto.3.dylib" || { echo "missing bundled libcrypto.3.dylib" >&2; exit 1; }
test -f "$LIB/libssl.3.dylib" || { echo "missing bundled libssl.3.dylib" >&2; exit 1; }

pushd "$OUT" >/dev/null
zip -r "$CORE_ZIP" bin lib learned_sfm/bin learned_sfm/python learned_sfm/app learned_sfm/vendor
zip -r "$MODELS_ZIP" learned_sfm/models
popd >/dev/null

echo "Packaged toolchain (core): $CORE_ZIP"
echo "Packaged toolchain (models): $MODELS_ZIP"
