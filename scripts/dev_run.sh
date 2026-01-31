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
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
MODELS_ZIP="$OUT/toolchain-macos-arm64-$VERSION-models.zip"
MANIFEST="$TOOLCHAINS/manifest.json"
PUB="$TOOLCHAINS/public_key_ed25519.txt"
PRIV="$TOOLCHAINS/private_key_ed25519.txt"
LEARNED_SFM_INSTALL="${LEARNED_SFM_INSTALL:-$ROOT/Toolchains/build/learned_sfm/install}"
LEARNED_SFM_BUNDLE="$LEARNED_SFM_INSTALL/learned_sfm"
LEARNED_SFM_BUILD="$ROOT/scripts/toolchain/build_learned_sfm.sh"

core_zip_valid() {
  test -f "$CORE_ZIP" || return 1
  unzip -l "$CORE_ZIP" | grep -q "lib/libcrypto.3.dylib" || return 1
  unzip -l "$CORE_ZIP" | grep -q "learned_sfm/bin/easysplat_match" || return 1
  unzip -l "$CORE_ZIP" | grep -q "learned_sfm/python/bin/python3" || return 1
  unzip -l "$CORE_ZIP" | grep -q "learned_sfm/vendor/mast3r/mast3r/__init__.py" || return 1

  local tmp
  tmp="$(mktemp -d)"
  unzip -p "$CORE_ZIP" bin/glomap >"$tmp/glomap" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/glomap"
  otool -l "$tmp/glomap" | grep -q "@executable_path/../lib" || { rm -rf "$tmp"; return 1; }
  otool -L "$tmp/glomap" | grep -q "@rpath/libcrypto.3.dylib" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

models_zip_valid() {
  test -f "$MODELS_ZIP" || return 1
  unzip -l "$MODELS_ZIP" | grep -q "learned_sfm/models/checkpoints/" || return 1
  unzip -l "$MODELS_ZIP" | grep -q "learned_sfm/models/checkpoints/.*\\.pth" || return 1
}

ensure_learned_sfm_bundle() {
  local build_log="$ROOT/Toolchains/build/learned_sfm/build.log"
  mkdir -p "$(dirname "$build_log")"
  local ok=0
  if [ -d "$LEARNED_SFM_BUNDLE" ]; then
    if [ -x "$LEARNED_SFM_BUNDLE/bin/easysplat_match" ] && \
       [ -x "$LEARNED_SFM_BUNDLE/python/bin/python3" ] && \
       [ -d "$LEARNED_SFM_BUNDLE/models" ] && \
       [ -d "$LEARNED_SFM_BUNDLE/vendor/mast3r/mast3r" ]; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    if [ -x "$LEARNED_SFM_BUILD" ]; then
      set +e
      "$LEARNED_SFM_BUILD" 2>&1 | tee "$build_log"
      local build_status=${PIPESTATUS[0]}
      set -e
      if [ "$build_status" -ne 0 ]; then
        echo "learned_sfm build failed. See log: $build_log" >&2
      fi
    fi
  fi
  if [ ! -x "$LEARNED_SFM_BUNDLE/bin/easysplat_match" ] || \
     [ ! -x "$LEARNED_SFM_BUNDLE/python/bin/python3" ] || \
     [ ! -d "$LEARNED_SFM_BUNDLE/models" ] || \
     [ ! -d "$LEARNED_SFM_BUNDLE/vendor/mast3r/mast3r" ]; then
    echo "learned_sfm bundle incomplete at $LEARNED_SFM_BUNDLE." >&2
    echo "Required: bin/easysplat_match, python/bin/python3, models/, vendor/mast3r/." >&2
    if [ -x "$LEARNED_SFM_BUILD" ]; then
      echo "Tried to run $LEARNED_SFM_BUILD, but the bundle is still incomplete." >&2
      echo "See build log: $build_log" >&2
    else
      echo "Provide it via LEARNED_SFM_INSTALL or add a build script at $LEARNED_SFM_BUILD." >&2
    fi
    exit 1
  fi
}

if ! core_zip_valid || ! models_zip_valid; then
  "$ROOT/scripts/toolchain/build_openssl.sh"
  test -x "$ROOT/Toolchains/build/colmap/install/bin/colmap" || "$ROOT/scripts/toolchain/build_colmap.sh"
  test -x "$ROOT/Toolchains/build/glomap/install/bin/glomap" || "$ROOT/scripts/toolchain/build_glomap.sh"
  test -x "$ROOT/Toolchains/build/brush/install/bin/brush" || "$ROOT/scripts/toolchain/build_brush.sh"
  ensure_learned_sfm_bundle
  # Remove any previous zips that may have been created without learned_sfm binaries.
  rm -f "$CORE_ZIP" "$MODELS_ZIP"
  "$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"
fi

if [ ! -f "$PUB" ] || [ ! -f "$PRIV" ]; then
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool generate-keypair \
    --public-key-out "$PUB" \
    --private-key-out "$PRIV"
fi

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool \
  --version "$VERSION" \
  --published-at "$PUBLISHED_AT" \
  --core-zip "$CORE_ZIP" \
  --core-url "http://localhost:$PORT/out/$(basename "$CORE_ZIP")" \
  --models-zip "$MODELS_ZIP" \
  --models-url "http://localhost:$PORT/out/$(basename "$MODELS_ZIP")" \
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
  test -d "$INSTALLED_TOOLCHAIN/learned_sfm/models/checkpoints" || return 1
  find "$INSTALLED_TOOLCHAIN/learned_sfm/models/checkpoints" -maxdepth 1 -type f -name "*.pth" | grep -q . || return 1
  test -d "$INSTALLED_TOOLCHAIN/learned_sfm/vendor/mast3r/mast3r" || return 1

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
