#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
PORT="${EASYSPLAT_DEV_PORT:-8000}"

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

TOOLCHAINS="$ROOT/Toolchains"
OUT="$TOOLCHAINS/out"
ZIP="$OUT/toolchain-macos-arm64-$VERSION.zip"
MANIFEST="$TOOLCHAINS/manifest.json"
PUB="$TOOLCHAINS/public_key_ed25519.txt"
PRIV="$TOOLCHAINS/private_key_ed25519.txt"
LEARNED_SFM_INSTALL="${LEARNED_SFM_INSTALL:-$ROOT/Toolchains/build/learned_sfm/install}"
LEARNED_SFM_BUNDLE="$LEARNED_SFM_INSTALL/learned_sfm"
LEARNED_SFM_BUILD="$ROOT/scripts/toolchain/build_learned_sfm.sh"

toolchain_zip_valid() {
  test -f "$ZIP" || return 1
  unzip -l "$ZIP" | grep -q "lib/libcrypto.3.dylib" || return 1
  unzip -l "$ZIP" | grep -q "learned_sfm/bin/easysplat_match" || return 1
  unzip -l "$ZIP" | grep -q "learned_sfm/python/bin/python3" || return 1
  unzip -l "$ZIP" | grep -q "learned_sfm/models" || return 1

  local tmp
  tmp="$(mktemp -d)"
  unzip -p "$ZIP" bin/glomap >"$tmp/glomap" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/glomap"
  otool -l "$tmp/glomap" | grep -q "@executable_path/../lib" || { rm -rf "$tmp"; return 1; }
  otool -L "$tmp/glomap" | grep -q "@rpath/libcrypto.3.dylib" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

ensure_learned_sfm_bundle() {
  if [ -d "$LEARNED_SFM_BUNDLE" ]; then
    return 0
  fi
  if [ -x "$LEARNED_SFM_BUILD" ]; then
    "$LEARNED_SFM_BUILD"
  fi
  if [ ! -d "$LEARNED_SFM_BUNDLE" ]; then
    echo "learned_sfm bundle not found at $LEARNED_SFM_BUNDLE." >&2
    if [ -x "$LEARNED_SFM_BUILD" ]; then
      echo "Tried to run $LEARNED_SFM_BUILD, but the bundle is still missing." >&2
    else
      echo "Provide it via LEARNED_SFM_INSTALL or add a build script at $LEARNED_SFM_BUILD." >&2
    fi
    exit 1
  fi
}

if ! toolchain_zip_valid; then
  "$ROOT/scripts/toolchain/build_openssl.sh"
  test -x "$ROOT/Toolchains/build/colmap/install/bin/colmap" || "$ROOT/scripts/toolchain/build_colmap.sh"
  test -x "$ROOT/Toolchains/build/glomap/install/bin/glomap" || "$ROOT/scripts/toolchain/build_glomap.sh"
  test -x "$ROOT/Toolchains/build/brush/install/bin/brush" || "$ROOT/scripts/toolchain/build_brush.sh"
  ensure_learned_sfm_bundle
  "$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"
fi

if [ ! -f "$PUB" ] || [ ! -f "$PRIV" ]; then
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool generate-keypair \
    --public-key-out "$PUB" \
    --private-key-out "$PRIV"
fi

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool \
  --zip "$ZIP" \
  --version "$VERSION" \
  --published-at "$PUBLISHED_AT" \
  --artifact-url "http://localhost:$PORT/out/$(basename "$ZIP")" \
  --private-key "$(cat "$PRIV")" \
  --manifest-out "$MANIFEST"

pushd "$TOOLCHAINS" >/dev/null
python3 -m http.server "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

export EASYSPLAT_TOOLCHAIN_MANIFEST_URL="http://localhost:$PORT/manifest.json"
export EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64="$(cat "$PUB")"

# If a previous install left a broken toolchain around (e.g. missing rpaths / OpenSSL dylibs),
# ToolchainManager may reuse it and then COLMAP/GLOMAP will fail hours into a run. Validate and
# proactively wipe the installed toolchain so the app re-installs from our freshly-built zip.
INSTALLED_TOOLCHAIN="$HOME/Library/Application Support/EasySplat/Toolchains/$VERSION"
validate_installed_toolchain() {
  test -x "$INSTALLED_TOOLCHAIN/bin/colmap" || return 1
  test -x "$INSTALLED_TOOLCHAIN/bin/glomap" || return 1
  test -f "$INSTALLED_TOOLCHAIN/lib/libcrypto.3.dylib" || return 1
  test -f "$INSTALLED_TOOLCHAIN/lib/libssl.3.dylib" || return 1
  test -x "$INSTALLED_TOOLCHAIN/learned_sfm/bin/easysplat_match" || return 1
  test -x "$INSTALLED_TOOLCHAIN/learned_sfm/python/bin/python3" || return 1
  test -d "$INSTALLED_TOOLCHAIN/learned_sfm/models" || return 1

  otool -l "$INSTALLED_TOOLCHAIN/bin/colmap" | grep -q "@executable_path/../lib" || return 1
  otool -l "$INSTALLED_TOOLCHAIN/bin/glomap" | grep -q "@executable_path/../lib" || return 1
  otool -L "$INSTALLED_TOOLCHAIN/bin/colmap" | grep -q "@rpath/libcrypto.3.dylib" || return 1
  otool -L "$INSTALLED_TOOLCHAIN/bin/glomap" | grep -q "@rpath/libcrypto.3.dylib" || return 1
}

if [ -d "$INSTALLED_TOOLCHAIN" ]; then
  if ! validate_installed_toolchain; then
    echo "Installed toolchain looks invalid; removing: $INSTALLED_TOOLCHAIN" >&2
    rm -rf "$INSTALLED_TOOLCHAIN"
  fi
fi

swift run --package-path "$ROOT" EasySplatApp
