#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
PORT="${EASYSPLAT_DEV_PORT:-8000}"
TOOLCHAIN_ROOT=""
FAST=0
REBUILD=0

usage() {
  cat <<'EOF'
Usage: ./scripts/run.sh [options]

Options:
  --fast                 Run with the installed toolchain (no rebuild/download).
  --rebuild              Force a toolchain rebuild (preserve models when possible).
  --version <semver>     Toolchain version (default: 0.1.0).
  --toolchain-root <dir> Override installed toolchain path.
  --port <port>          Local manifest server port (default: 8000).
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --toolchain-root)
      TOOLCHAIN_ROOT="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --fast)
      FAST=1
      shift
      ;;
    --rebuild)
      REBUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$FAST" -eq 1 ] && [ "$REBUILD" -eq 1 ]; then
  echo "Cannot combine --fast and --rebuild." >&2
  exit 1
fi

if [ -z "$TOOLCHAIN_ROOT" ]; then
  TOOLCHAIN_ROOT="$HOME/Library/Application Support/EasySplat/Toolchains/$VERSION"
fi

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
FASTVGGT_MPS_INSTALL="${FASTVGGT_MPS_INSTALL:-$ROOT/Toolchains/build/fastvggt_mps/install}"
FASTVGGT_MPS_BUNDLE="$FASTVGGT_MPS_INSTALL/fastvggt_mps"
FASTVGGT_MPS_BUILD="$ROOT/scripts/toolchain/build_fastvggt_mps.sh"

toolchain_inputs_newer() {
  test -f "$CORE_ZIP" || return 1
  find "$ROOT/Tools/VggtSfm" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/Tools/FastVggtSfm" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/scripts/toolchain" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  return 1
}

core_zip_valid() {
  test -f "$CORE_ZIP" || return 1
  unzip -l "$CORE_ZIP" | grep -q "bin/colmap" || return 1
  unzip -l "$CORE_ZIP" | grep -q "lib/libcrypto.3.dylib" || return 1
  unzip -l "$CORE_ZIP" | grep -q "vggt_mps/bin/easysplat_vggt_sfm" || return 1
  unzip -l "$CORE_ZIP" | grep -q "vggt_mps/python/bin/python3" || return 1
  unzip -l "$CORE_ZIP" | grep -q "vggt_mps/vendor/vggt/vggt/models/vggt.py" || return 1
  unzip -l "$CORE_ZIP" | grep -q "fastvggt_mps/bin/easysplat_fastvggt_sfm" || return 1
  unzip -l "$CORE_ZIP" | grep -q "fastvggt_mps/python/bin/python3" || return 1
  unzip -l "$CORE_ZIP" | grep -q "fastvggt_mps/vendor/fastvggt/vggt/models/vggt.py" || return 1
  unzip -l "$CORE_ZIP" | grep -q "bin/brush.real" || return 1

  local tmp
  tmp="$(mktemp -d)"
  unzip -p "$CORE_ZIP" bin/colmap >"$tmp/colmap" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/colmap"
  otool -l "$tmp/colmap" | grep -q "@executable_path/../lib" || { rm -rf "$tmp"; return 1; }
  otool -L "$tmp/colmap" | grep -q "@rpath/libcrypto.3.dylib" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

models_zip_valid() {
  test -f "$MODELS_ZIP" || return 1
  unzip -l "$MODELS_ZIP" | grep -q "vggt_mps/models/vggt_model\\.pt" || return 1
  unzip -l "$MODELS_ZIP" | grep -q "fastvggt_mps/models/fastvggt_model\\.pt" || return 1
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

ensure_fastvggt_mps_bundle() {
  local build_log="$ROOT/Toolchains/build/fastvggt_mps/build.log"
  mkdir -p "$(dirname "$build_log")"
  local ok=0
  if [ -d "$FASTVGGT_MPS_BUNDLE" ]; then
    if [ -x "$FASTVGGT_MPS_BUNDLE/bin/easysplat_fastvggt_sfm" ] && \
       [ -x "$FASTVGGT_MPS_BUNDLE/python/bin/python3" ] && \
       [ -f "$FASTVGGT_MPS_BUNDLE/models/fastvggt_model.pt" ] && \
       [ -f "$FASTVGGT_MPS_BUNDLE/vendor/fastvggt/vggt/models/vggt.py" ]; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    if [ -x "$FASTVGGT_MPS_BUILD" ]; then
      set +e
      "$FASTVGGT_MPS_BUILD" 2>&1 | tee "$build_log"
      local build_status=${PIPESTATUS[0]}
      set -e
      if [ "$build_status" -ne 0 ]; then
        echo "fastvggt_mps build failed. See log: $build_log" >&2
      fi
    fi
  fi
  if [ ! -x "$FASTVGGT_MPS_BUNDLE/bin/easysplat_fastvggt_sfm" ] || \
     [ ! -x "$FASTVGGT_MPS_BUNDLE/python/bin/python3" ] || \
     [ ! -f "$FASTVGGT_MPS_BUNDLE/models/fastvggt_model.pt" ] || \
     [ ! -f "$FASTVGGT_MPS_BUNDLE/vendor/fastvggt/vggt/models/vggt.py" ]; then
    echo "fastvggt_mps bundle incomplete at $FASTVGGT_MPS_BUNDLE." >&2
    echo "Required: bin/easysplat_fastvggt_sfm, python/bin/python3, models/fastvggt_model.pt, vendor/fastvggt/." >&2
    if [ -x "$FASTVGGT_MPS_BUILD" ]; then
      echo "Tried to run $FASTVGGT_MPS_BUILD, but the bundle is still incomplete." >&2
      echo "See build log: $build_log" >&2
    else
      echo "Provide it via FASTVGGT_MPS_INSTALL or add a build script at $FASTVGGT_MPS_BUILD." >&2
    fi
    exit 1
  fi
}

refresh_vggt_mps_app() {
  if [ -d "$VGGT_MPS_BUNDLE" ]; then
    rm -rf "$VGGT_MPS_BUNDLE/app"
    cp -R "$ROOT/Tools/VggtSfm" "$VGGT_MPS_BUNDLE/app"
  fi
}

refresh_fastvggt_mps_app() {
  if [ -d "$FASTVGGT_MPS_BUNDLE" ]; then
    rm -rf "$FASTVGGT_MPS_BUNDLE/app"
    cp -R "$ROOT/Tools/FastVggtSfm" "$FASTVGGT_MPS_BUNDLE/app"
  fi
}

installed_app_needs_refresh() {
  local root="$1"
  local app_root="$root/vggt_mps/app"
  local sentinel="$app_root/easysplat_vggt_sfm/run.py"
  if [ ! -d "$ROOT/Tools/VggtSfm" ]; then
    return 1
  fi
  if [ ! -d "$root/vggt_mps" ]; then
    return 1
  fi
  if [ ! -f "$sentinel" ]; then
    return 0
  fi
  find "$ROOT/Tools/VggtSfm" -type f -newer "$sentinel" -print -quit | grep -q .
}

refresh_installed_vggt_app() {
  local root="$1"
  if installed_app_needs_refresh "$root"; then
    rm -rf "$root/vggt_mps/app"
    cp -R "$ROOT/Tools/VggtSfm" "$root/vggt_mps/app"
  fi
}

fastvggt_app_needs_refresh() {
  local root="$1"
  local app_root="$root/fastvggt_mps/app"
  local sentinel="$app_root/easysplat_fastvggt_sfm/run.py"
  if [ ! -d "$ROOT/Tools/FastVggtSfm" ]; then
    return 1
  fi
  if [ ! -d "$root/fastvggt_mps" ]; then
    return 1
  fi
  if [ ! -f "$sentinel" ]; then
    return 0
  fi
  find "$ROOT/Tools/FastVggtSfm" -type f -newer "$sentinel" -print -quit | grep -q .
}

refresh_installed_fastvggt_app() {
  local root="$1"
  if fastvggt_app_needs_refresh "$root"; then
    rm -rf "$root/fastvggt_mps/app"
    cp -R "$ROOT/Tools/FastVggtSfm" "$root/fastvggt_mps/app"
  fi
}

validate_installed_toolchain() {
  local root="$1"
  test -x "$root/bin/colmap" || return 1
  test -f "$root/lib/libcrypto.3.dylib" || return 1
  test -f "$root/lib/libssl.3.dylib" || return 1
  test -x "$root/vggt_mps/bin/easysplat_vggt_sfm" || return 1
  test -x "$root/vggt_mps/python/bin/python3" || return 1
  test -f "$root/vggt_mps/models/vggt_model.pt" || return 1
  test -f "$root/vggt_mps/vendor/vggt/vggt/models/vggt.py" || return 1
  test -x "$root/fastvggt_mps/bin/easysplat_fastvggt_sfm" || return 1
  test -x "$root/fastvggt_mps/python/bin/python3" || return 1
  test -f "$root/fastvggt_mps/models/fastvggt_model.pt" || return 1
  test -f "$root/fastvggt_mps/vendor/fastvggt/vggt/models/vggt.py" || return 1
  if head -c 2 "$root/bin/brush" 2>/dev/null | grep -q "#!"; then
    test -x "$root/bin/brush.real" || return 1
  fi

  otool -l "$root/bin/colmap" | grep -q "@executable_path/../lib" || return 1
  otool -L "$root/bin/colmap" | grep -q "@rpath/libcrypto.3.dylib" || return 1
}

models_present() {
  local root="$1"
  test -f "$root/vggt_mps/models/vggt_model.pt" && test -f "$root/fastvggt_mps/models/fastvggt_model.pt"
}

wipe_installed_core() {
  local root="$1"
  rm -rf \
    "$root/bin" \
    "$root/lib" \
    "$root/vggt_mps/bin" \
    "$root/vggt_mps/python" \
    "$root/vggt_mps/vendor" \
    "$root/vggt_mps/app" \
    "$root/fastvggt_mps/bin" \
    "$root/fastvggt_mps/python" \
    "$root/fastvggt_mps/vendor" \
    "$root/fastvggt_mps/app"
}

INSTALLED_OK=0
if [ -d "$TOOLCHAIN_ROOT" ] && validate_installed_toolchain "$TOOLCHAIN_ROOT"; then
  INSTALLED_OK=1
fi

if [ "$FAST" -eq 1 ]; then
  if [ "$INSTALLED_OK" -ne 1 ]; then
    echo "Local toolchain not found or incomplete at: $TOOLCHAIN_ROOT" >&2
    echo "Run ./scripts/run.sh --rebuild once to build/install the toolchain, then retry." >&2
    exit 1
  fi
  refresh_installed_vggt_app "$TOOLCHAIN_ROOT"
  refresh_installed_fastvggt_app "$TOOLCHAIN_ROOT"
  export EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT"
  swift run --package-path "$ROOT" EasySplatApp
  exit 0
fi

if [ "$REBUILD" -eq 0 ] && [ "$INSTALLED_OK" -eq 1 ]; then
  refresh_installed_vggt_app "$TOOLCHAIN_ROOT"
  refresh_installed_fastvggt_app "$TOOLCHAIN_ROOT"
  export EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT"
  swift run --package-path "$ROOT" EasySplatApp
  exit 0
fi

NEED_PACKAGE=0
if [ "$REBUILD" -eq 1 ] || ! core_zip_valid || ! models_zip_valid; then
  NEED_PACKAGE=1
elif [ "$INSTALLED_OK" -eq 0 ] && toolchain_inputs_newer; then
  NEED_PACKAGE=1
fi

if [ "$NEED_PACKAGE" -eq 1 ]; then
  "$ROOT/scripts/toolchain/build_openssl.sh"
  test -x "$ROOT/Toolchains/build/colmap/install/bin/colmap" || "$ROOT/scripts/toolchain/build_colmap.sh"
  test -x "$ROOT/Toolchains/build/brush/install/bin/brush" || "$ROOT/scripts/toolchain/build_brush.sh"
  ensure_vggt_mps_bundle
  refresh_vggt_mps_app
  ensure_fastvggt_mps_bundle
  refresh_fastvggt_mps_app
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

if [ -d "$TOOLCHAIN_ROOT" ]; then
  if models_present "$TOOLCHAIN_ROOT"; then
    echo "Preserving installed models; removing core to force reinstall: $TOOLCHAIN_ROOT" >&2
    wipe_installed_core "$TOOLCHAIN_ROOT"
  else
    echo "Removing installed toolchain to force reinstall: $TOOLCHAIN_ROOT" >&2
    rm -rf "$TOOLCHAIN_ROOT"
  fi
fi

swift run --package-path "$ROOT" EasySplatApp
