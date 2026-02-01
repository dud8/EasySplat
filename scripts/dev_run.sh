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
VGGT_MPS_INSTALL="${VGGT_MPS_INSTALL:-$ROOT/Toolchains/build/vggt_mps/install}"
VGGT_MPS_BUNDLE="$VGGT_MPS_INSTALL/vggt_mps"
VGGT_MPS_BUILD="$ROOT/scripts/toolchain/build_vggt_mps.sh"

toolchain_inputs_newer() {
  # In dev, we want the locally-built toolchain zips to reflect the current workspace.
  test -f "$CORE_ZIP" || return 1
  find "$ROOT/Tools/VggtSfm" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/scripts/toolchain" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  return 1
}

core_zip_valid() {
  test -f "$CORE_ZIP" || return 1
  unzip -l "$CORE_ZIP" | grep -q "lib/libcrypto.3.dylib" || return 1
  unzip -l "$CORE_ZIP" | grep -q "vggt_mps/bin/easysplat_vggt_sfm" || return 1
  unzip -l "$CORE_ZIP" | grep -q "vggt_mps/python/bin/python3" || return 1
  unzip -l "$CORE_ZIP" | grep -q "vggt_mps/vendor/vggt/vggt/models/vggt.py" || return 1
  unzip -l "$CORE_ZIP" | grep -q "bin/brush.real" || return 1

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
  unzip -l "$MODELS_ZIP" | grep -q "vggt_mps/models/vggt_model\\.pt" || return 1
}

ensure_vggt_mps_bundle() {
  local build_log="$ROOT/Toolchains/build/vggt_mps/build.log"
  mkdir -p "$(dirname "$build_log")"
  local ok=0
  if [ -d "$VGGT_MPS_BUNDLE" ]; then
    if [ -x "$VGGT_MPS_BUNDLE/bin/easysplat_vggt_sfm" ] && \
       [ -x "$VGGT_MPS_BUNDLE/python/bin/python3" ] && \
       [ -f "$VGGT_MPS_BUNDLE/models/vggt_model.pt" ] && \
       [ -f "$VGGT_MPS_BUNDLE/vendor/vggt/vggt/models/vggt.py" ]; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    if [ -x "$VGGT_MPS_BUILD" ]; then
      set +e
      "$VGGT_MPS_BUILD" 2>&1 | tee "$build_log"
      local build_status=${PIPESTATUS[0]}
      set -e
      if [ "$build_status" -ne 0 ]; then
        echo "vggt_mps build failed. See log: $build_log" >&2
      fi
    fi
  fi
  if [ ! -x "$VGGT_MPS_BUNDLE/bin/easysplat_vggt_sfm" ] || \
     [ ! -x "$VGGT_MPS_BUNDLE/python/bin/python3" ] || \
     [ ! -f "$VGGT_MPS_BUNDLE/models/vggt_model.pt" ] || \
     [ ! -f "$VGGT_MPS_BUNDLE/vendor/vggt/vggt/models/vggt.py" ]; then
    echo "vggt_mps bundle incomplete at $VGGT_MPS_BUNDLE." >&2
    echo "Required: bin/easysplat_vggt_sfm, python/bin/python3, models/vggt_model.pt, vendor/vggt/." >&2
    if [ -x "$VGGT_MPS_BUILD" ]; then
      echo "Tried to run $VGGT_MPS_BUILD, but the bundle is still incomplete." >&2
      echo "See build log: $build_log" >&2
    else
      echo "Provide it via VGGT_MPS_INSTALL or add a build script at $VGGT_MPS_BUILD." >&2
    fi
    exit 1
  fi
}

refresh_vggt_mps_app() {
  # The vggt_mps bundle includes a copy of Tools/VggtSfm as its "app" python package root.
  # Keep it in sync with the workspace so dev builds pick up local fixes without a full rebuild.
  if [ -d "$VGGT_MPS_BUNDLE" ]; then
    rm -rf "$VGGT_MPS_BUNDLE/app"
    cp -R "$ROOT/Tools/VggtSfm" "$VGGT_MPS_BUNDLE/app"
  fi
}

REBUILT_TOOLCHAIN=0
if ! core_zip_valid || ! models_zip_valid || toolchain_inputs_newer; then
  "$ROOT/scripts/toolchain/build_openssl.sh"
  test -x "$ROOT/Toolchains/build/colmap/install/bin/colmap" || "$ROOT/scripts/toolchain/build_colmap.sh"
  test -x "$ROOT/Toolchains/build/glomap/install/bin/glomap" || "$ROOT/scripts/toolchain/build_glomap.sh"
  test -x "$ROOT/Toolchains/build/brush/install/bin/brush" || "$ROOT/scripts/toolchain/build_brush.sh"
  ensure_vggt_mps_bundle
  refresh_vggt_mps_app
  # Remove any previous zips that may have been created without vggt_mps binaries.
  rm -f "$CORE_ZIP" "$MODELS_ZIP"
  "$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"
  REBUILT_TOOLCHAIN=1
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
  test -x "$INSTALLED_TOOLCHAIN/vggt_mps/bin/easysplat_vggt_sfm" || return 1
  test -x "$INSTALLED_TOOLCHAIN/vggt_mps/python/bin/python3" || return 1
  test -f "$INSTALLED_TOOLCHAIN/vggt_mps/models/vggt_model.pt" || return 1
  test -f "$INSTALLED_TOOLCHAIN/vggt_mps/vendor/vggt/vggt/models/vggt.py" || return 1
  if head -c 2 "$INSTALLED_TOOLCHAIN/bin/brush" 2>/dev/null | grep -q "#!"; then
    test -x "$INSTALLED_TOOLCHAIN/bin/brush.real" || return 1
  fi

  otool -l "$INSTALLED_TOOLCHAIN/bin/colmap" | grep -q "@executable_path/../lib" || return 1
  otool -l "$INSTALLED_TOOLCHAIN/bin/glomap" | grep -q "@executable_path/../lib" || return 1
  otool -L "$INSTALLED_TOOLCHAIN/bin/colmap" | grep -q "@rpath/libcrypto.3.dylib" || return 1
  otool -L "$INSTALLED_TOOLCHAIN/bin/glomap" | grep -q "@rpath/libcrypto.3.dylib" || return 1
}

if [ -d "$INSTALLED_TOOLCHAIN" ]; then
  if [ "$REBUILT_TOOLCHAIN" -eq 1 ]; then
    echo "Toolchain zips were rebuilt; removing installed toolchain to force re-install: $INSTALLED_TOOLCHAIN" >&2
    rm -rf "$INSTALLED_TOOLCHAIN"
  elif [ -f "$INSTALLED_TOOLCHAIN/vggt_mps/app/easysplat_vggt_sfm/run.py" ] && [ "$CORE_ZIP" -nt "$INSTALLED_TOOLCHAIN/vggt_mps/app/easysplat_vggt_sfm/run.py" ]; then
    echo "Installed toolchain predates core zip; removing to force re-install: $INSTALLED_TOOLCHAIN" >&2
    rm -rf "$INSTALLED_TOOLCHAIN"
  elif ! validate_installed_toolchain; then
    echo "Installed toolchain looks invalid; removing: $INSTALLED_TOOLCHAIN" >&2
    rm -rf "$INSTALLED_TOOLCHAIN"
  fi
fi

swift run --package-path "$ROOT" EasySplatApp
