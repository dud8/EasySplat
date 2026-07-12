#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
PORT="${EASYSPLAT_DEV_PORT:-8000}"
TOOLCHAIN_ROOT=""
FAST=0
REBUILD=0

log() {
  printf '[run] %s\n' "$*"
}

launch_app() {
  local launch_mode="$1"
  log "Launching EasySplatApp ($launch_mode)."
  log "If the window does not come to the front automatically, switch to EasySplatApp in the Dock."
  swift run --package-path "$ROOT" EasySplatApp
}

wait_for_local_manifest_server() {
  local port="$1"
  local manifest_path="$2"
  local server_pid="$3"
  local attempts=50

  while [ "$attempts" -gt 0 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      wait "$server_pid" 2>/dev/null || true
      echo "Local toolchain server exited before serving the staged manifest on port $port. Is that port already in use?" >&2
      return 1
    fi

    if python3 - "$port" "$manifest_path" <<'PY' >/dev/null 2>&1
import sys
import urllib.request
from pathlib import Path

port = int(sys.argv[1])
manifest_path = Path(sys.argv[2])
expected_manifest = manifest_path.read_bytes()
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/manifest.json", timeout=0.2) as response:
        actual_manifest = response.read()
except Exception:
    raise SystemExit(1)

if actual_manifest != expected_manifest:
    raise SystemExit(1)
PY
    then
      return 0
    fi

    attempts=$((attempts - 1))
    sleep 0.1
  done

  echo "Timed out waiting for the local toolchain server to serve the staged manifest on port $port." >&2
  return 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/run.sh [options]

Options:
  --fast                 Run with the installed toolchain (no rebuild/download).
  --rebuild              Force a toolchain rebuild (preserve models when possible).
  --version <semver>     Toolchain version (default: 0.1.0).
  --toolchain-root <dir> Override installed toolchain path.
  --port <port>          Local manifest server port on 127.0.0.1 (default: 8000).
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
DA3_BASE_ZIP="$OUT/toolchain-geometry-da3-base-$VERSION.zip"
DA3_SMALL_ZIP="$OUT/toolchain-geometry-da3-small-$VERSION.zip"
MANIFEST="$TOOLCHAINS/manifest.json"
PUBLIC_SERVE_ROOT=""
PUB="$TOOLCHAINS/public_key_ed25519.txt"
PRIV="$TOOLCHAINS/private_key_ed25519.txt"
MSPLAT_INSTALL="${MSPLAT_INSTALL:-$ROOT/Toolchains/build/msplat/install}"
MSPLAT_BUNDLE="$MSPLAT_INSTALL/msplat"
MSPLAT_BUILD="$ROOT/scripts/toolchain/build_msplat.sh"
MSPLAT_VALIDATOR="$ROOT/scripts/toolchain/validate_native_msplat.sh"
DA3_MPS_INSTALL="${DA3_MPS_INSTALL:-$ROOT/Toolchains/build/da3_mps/install}"
DA3_MPS_BUNDLE="$DA3_MPS_INSTALL/da3_mps"
DA3_MPS_BUILD="$ROOT/scripts/toolchain/build_da3_mps.sh"

validate_bundle_build_info() {
  local python_bin="$1"
  local build_info="$2"
  local tool_name="$3"
  PYTHONNOUSERSITE=1 "$python_bin" - "$build_info" "$tool_name" <<'PY' >/dev/null
import json
import sys
from pathlib import Path

build_info = Path(sys.argv[1])
tool_name = sys.argv[2]
required_keys = {
    "toolchain_name",
    "source_path",
    "python_version",
    "torch_version",
    "torchvision_version",
}

payload = json.loads(build_info.read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit(1)
missing = sorted(key for key in required_keys if not payload.get(key))
if missing:
    raise SystemExit(1)
if payload.get("toolchain_name") != tool_name:
    raise SystemExit(1)
PY
}

copy_da3_app_into() {
  local bundle_root="$1"
  local source_root="$ROOT/Tools/Da3Sfm/easysplat_da3_sfm"
  local app_root="$bundle_root/app"
  if [ ! -d "$source_root" ]; then
    echo "DA3 app source missing at $source_root" >&2
    exit 1
  fi

  rm -rf "$app_root"
  mkdir -p "$app_root"
  cp -R "$source_root" "$app_root/"
  find "$app_root" -type d -name "__pycache__" -prune -exec rm -rf {} +
  find "$app_root" -type f -name "*.pyc" -delete
}

toolchain_inputs_newer() {
  test -f "$CORE_ZIP" || return 1
  find "$ROOT/Tools/Da3Sfm" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/Tools/MsplatNative" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/scripts/toolchain" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  return 1
}

core_zip_valid() {
  test -f "$CORE_ZIP" || return 1
  "$MSPLAT_VALIDATOR" --archive "$CORE_ZIP" >/dev/null 2>&1 || return 1
  unzip -l "$CORE_ZIP" | grep -q "bin/colmap" || return 1
  unzip -l "$CORE_ZIP" | grep -q "bin/easysplat-train" || return 1
  unzip -l "$CORE_ZIP" | grep -q "bin/default.metallib" || return 1
  unzip -l "$CORE_ZIP" | grep -q "lib/libcrypto.3.dylib" || return 1
  unzip -l "$CORE_ZIP" | grep -q "lib/libssl.3.dylib" || return 1
  unzip -l "$CORE_ZIP" | grep -q "msplat/build_info.json" || return 1
  unzip -l "$CORE_ZIP" | grep -q "msplat/LICENSE" || return 1
  unzip -l "$CORE_ZIP" | grep -q "da3_mps/bin/easysplat_da3_sfm" || return 1
  unzip -l "$CORE_ZIP" | grep -q "da3_mps/python/bin/python3" || return 1
  unzip -l "$CORE_ZIP" | grep -q "da3_mps/build_info.json" || return 1
  unzip -l "$CORE_ZIP" | grep -q "da3_mps/app/easysplat_da3_sfm/run.py" || return 1
  unzip -l "$CORE_ZIP" | grep -q "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py" || return 1

  local tmp
  tmp="$(mktemp -d)"
  local rc=0
  {
    unzip -p "$CORE_ZIP" bin/colmap >"$tmp/colmap" 2>/dev/null \
      && chmod +x "$tmp/colmap" \
      && otool -l "$tmp/colmap" | grep -q "@executable_path/../lib" \
      && otool -L "$tmp/colmap" | grep -q "@rpath/libcrypto.3.dylib"
  } || rc=1
  rm -rf "$tmp"
  return "$rc"
}

ensure_msplat_bundle() {
  local build_log="$ROOT/Toolchains/build/msplat/build.log"
  mkdir -p "$(dirname "$build_log")"
  if "$MSPLAT_VALIDATOR" --source "$MSPLAT_BUNDLE" >/dev/null 2>&1; then
    local native_sources_newer=0
    if find "$ROOT/Tools/MsplatNative" -type f -newer "$MSPLAT_BUNDLE/build_info.json" -print -quit | grep -q .; then
      native_sources_newer=1
    fi
    if [ "$MSPLAT_BUILD" -nt "$MSPLAT_BUNDLE/build_info.json" ]; then
      native_sources_newer=1
    fi
    if [ "$native_sources_newer" -eq 0 ]; then
      return
    fi
  fi
  if [ -x "$MSPLAT_BUILD" ]; then
    set +e
    "$MSPLAT_BUILD" 2>&1 | tee "$build_log"
    local build_status=${PIPESTATUS[0]}
    set -e
    if [ "$build_status" -ne 0 ]; then
      echo "Native msplat build failed. See log: $build_log" >&2
    fi
  fi
  if ! "$MSPLAT_VALIDATOR" --source "$MSPLAT_BUNDLE"; then
    echo "Native msplat install is invalid at $MSPLAT_BUNDLE." >&2
    if [ -x "$MSPLAT_BUILD" ]; then
      echo "Tried to run $MSPLAT_BUILD, but validation still failed." >&2
      echo "See build log: $build_log" >&2
    else
      echo "Provide it via MSPLAT_INSTALL or add a build script at $MSPLAT_BUILD." >&2
    fi
    exit 1
  fi
}

da3_model_zip_valid() {
  local zip_path="$1"
  local model="$2"
  test -f "$zip_path" || return 1
  unzip -l "$zip_path" | grep -q "da3_mps/models/$model/config\\.json" || return 1
  unzip -l "$zip_path" | grep -q "da3_mps/models/$model/model\\.safetensors" || return 1
  unzip -l "$zip_path" | grep -q "da3_mps/models/$model/easysplat_model_info\\.json" || return 1
}

ensure_da3_mps_bundle() {
  local build_log="$ROOT/Toolchains/build/da3_mps/build.log"
  mkdir -p "$(dirname "$build_log")"
  local ok=0
  if [ -d "$DA3_MPS_BUNDLE" ]; then
    if [ -x "$DA3_MPS_BUNDLE/bin/easysplat_da3_sfm" ] && \
       [ -x "$DA3_MPS_BUNDLE/python/bin/python3" ] && \
       [ -f "$DA3_MPS_BUNDLE/build_info.json" ] && \
       [ -f "$DA3_MPS_BUNDLE/app/easysplat_da3_sfm/run.py" ] && \
       [ -f "$DA3_MPS_BUNDLE/models/DA3-BASE/model.safetensors" ] && \
       [ -f "$DA3_MPS_BUNDLE/models/DA3-BASE/config.json" ] && \
       [ -f "$DA3_MPS_BUNDLE/models/DA3-BASE/easysplat_model_info.json" ] && \
       [ -f "$DA3_MPS_BUNDLE/models/DA3-SMALL/model.safetensors" ] && \
       [ -f "$DA3_MPS_BUNDLE/models/DA3-SMALL/config.json" ] && \
       [ -f "$DA3_MPS_BUNDLE/models/DA3-SMALL/easysplat_model_info.json" ] && \
       [ -f "$DA3_MPS_BUNDLE/vendor/depth-anything-3/src/depth_anything_3/api.py" ] && \
       validate_bundle_build_info "$DA3_MPS_BUNDLE/python/bin/python3" "$DA3_MPS_BUNDLE/build_info.json" "da3_mps"; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    if [ -x "$DA3_MPS_BUILD" ]; then
      set +e
      "$DA3_MPS_BUILD" 2>&1 | tee "$build_log"
      local build_status=${PIPESTATUS[0]}
      set -e
      if [ "$build_status" -ne 0 ]; then
        echo "da3_mps build failed. See log: $build_log" >&2
      fi
    fi
  fi
  if [ ! -x "$DA3_MPS_BUNDLE/bin/easysplat_da3_sfm" ] || \
     [ ! -x "$DA3_MPS_BUNDLE/python/bin/python3" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/build_info.json" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/app/easysplat_da3_sfm/run.py" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/models/DA3-BASE/model.safetensors" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/models/DA3-BASE/config.json" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/models/DA3-BASE/easysplat_model_info.json" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/models/DA3-SMALL/model.safetensors" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/models/DA3-SMALL/config.json" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/models/DA3-SMALL/easysplat_model_info.json" ] || \
     [ ! -f "$DA3_MPS_BUNDLE/vendor/depth-anything-3/src/depth_anything_3/api.py" ]; then
    echo "da3_mps bundle incomplete at $DA3_MPS_BUNDLE." >&2
    echo "Required: bin/easysplat_da3_sfm, python/bin/python3, build_info.json, app/easysplat_da3_sfm/run.py, models/DA3-{BASE,SMALL}/{config.json,model.safetensors,easysplat_model_info.json}, vendor/depth-anything-3/src/." >&2
    if [ -x "$DA3_MPS_BUILD" ]; then
      echo "Tried to run $DA3_MPS_BUILD, but the bundle is still incomplete." >&2
      echo "See build log: $build_log" >&2
    else
      echo "Provide it via DA3_MPS_INSTALL or add a build script at $DA3_MPS_BUILD." >&2
    fi
    exit 1
  fi
}

refresh_da3_mps_app() {
  if [ -d "$DA3_MPS_BUNDLE" ]; then
    copy_da3_app_into "$DA3_MPS_BUNDLE"
  fi
}

da3_app_needs_refresh() {
  local root="$1"
  local app_root="$root/da3_mps/app"
  local sentinel="$app_root/easysplat_da3_sfm/run.py"
  if [ ! -d "$ROOT/Tools/Da3Sfm" ]; then
    return 1
  fi
  if [ ! -d "$root/da3_mps" ]; then
    return 1
  fi
  if [ ! -f "$sentinel" ]; then
    return 0
  fi
  find "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm" \
    -type f \
    ! -name "*.pyc" \
    ! -path "*/__pycache__/*" \
    -newer "$sentinel" \
    -print -quit | grep -q .
}

refresh_installed_da3_app() {
  local root="$1"
  if da3_app_needs_refresh "$root"; then
    copy_da3_app_into "$root/da3_mps"
  fi
}

validate_installed_toolchain() {
  local root="$1"
  test -x "$root/bin/colmap" || return 1
  test -f "$root/lib/libcrypto.3.dylib" || return 1
  test -f "$root/lib/libssl.3.dylib" || return 1
  "$MSPLAT_VALIDATOR" --packaged "$root" >/dev/null 2>&1 || return 1
  test -x "$root/da3_mps/bin/easysplat_da3_sfm" || return 1
  test -x "$root/da3_mps/python/bin/python3" || return 1
  test -f "$root/da3_mps/build_info.json" || return 1
  validate_bundle_build_info "$root/da3_mps/python/bin/python3" "$root/da3_mps/build_info.json" "da3_mps" || return 1
  test -f "$root/da3_mps/app/easysplat_da3_sfm/run.py" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/model.safetensors" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/config.json" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/easysplat_model_info.json" || return 1
  test -f "$root/da3_mps/models/DA3-SMALL/model.safetensors" || return 1
  test -f "$root/da3_mps/models/DA3-SMALL/config.json" || return 1
  test -f "$root/da3_mps/models/DA3-SMALL/easysplat_model_info.json" || return 1
  test -f "$root/da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py" || return 1

  otool -l "$root/bin/colmap" | grep -q "@executable_path/../lib" || return 1
  otool -L "$root/bin/colmap" | grep -q "@rpath/libcrypto.3.dylib" || return 1
}

models_present() {
  local root="$1"
  test -f "$root/da3_mps/models/DA3-BASE/model.safetensors" \
    && test -f "$root/da3_mps/models/DA3-BASE/config.json" \
    && test -f "$root/da3_mps/models/DA3-BASE/easysplat_model_info.json" \
    && test -f "$root/da3_mps/models/DA3-SMALL/model.safetensors" \
    && test -f "$root/da3_mps/models/DA3-SMALL/config.json" \
    && test -f "$root/da3_mps/models/DA3-SMALL/easysplat_model_info.json"
}

wipe_installed_core() {
  local root="$1"
  rm -rf \
    "$root/bin" \
    "$root/lib" \
    "$root/msplat" \
    "$root/da3_mps/bin" \
    "$root/da3_mps/python" \
    "$root/da3_mps/build_info.json" \
    "$root/da3_mps/vendor" \
    "$root/da3_mps/app"
}

INSTALLED_OK=0
if [ -d "$TOOLCHAIN_ROOT" ] && validate_installed_toolchain "$TOOLCHAIN_ROOT"; then
  INSTALLED_OK=1
fi

if [ "$FAST" -eq 1 ]; then
  if [ "$INSTALLED_OK" -ne 1 ]; then
    echo "Local toolchain not found or incomplete at: $TOOLCHAIN_ROOT" >&2
    echo "Run ./scripts/run.sh to auto-build/install it, or use --rebuild to force a fresh toolchain." >&2
    exit 1
  fi
  refresh_installed_da3_app "$TOOLCHAIN_ROOT"
  export EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT"
  launch_app "installed toolchain at $TOOLCHAIN_ROOT"
  exit 0
fi

if [ "$REBUILD" -eq 0 ] && [ "$INSTALLED_OK" -eq 1 ]; then
  refresh_installed_da3_app "$TOOLCHAIN_ROOT"
  export EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT"
  launch_app "installed toolchain at $TOOLCHAIN_ROOT"
  exit 0
fi

NEED_PACKAGE=0
if [ "$REBUILD" -eq 1 ] || ! core_zip_valid \
  || ! da3_model_zip_valid "$DA3_BASE_ZIP" "DA3-BASE" \
  || ! da3_model_zip_valid "$DA3_SMALL_ZIP" "DA3-SMALL"; then
  NEED_PACKAGE=1
elif [ "$INSTALLED_OK" -eq 0 ] && toolchain_inputs_newer; then
  NEED_PACKAGE=1
fi

if [ "$NEED_PACKAGE" -eq 1 ]; then
  "$ROOT/scripts/toolchain/build_openssl.sh"
  test -x "$ROOT/Toolchains/build/colmap/install/bin/colmap" || "$ROOT/scripts/toolchain/build_colmap.sh"
  ensure_msplat_bundle
  ensure_da3_mps_bundle
  refresh_da3_mps_app
  rm -f "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"
  "$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"
fi

if [ ! -f "$PUB" ] || [ ! -f "$PRIV" ]; then
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool generate-keypair \
    --public-key-out "$PUB" \
    --private-key-out "$PRIV"
fi
chmod 600 "$PRIV"

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool \
  --version "$VERSION" \
  --published-at "$PUBLISHED_AT" \
  --core-zip "$CORE_ZIP" \
  --core-url "http://localhost:$PORT/out/$(basename "$CORE_ZIP")" \
  --da3-base-zip "$DA3_BASE_ZIP" \
  --da3-base-url "http://localhost:$PORT/out/$(basename "$DA3_BASE_ZIP")" \
  --da3-small-zip "$DA3_SMALL_ZIP" \
  --da3-small-url "http://localhost:$PORT/out/$(basename "$DA3_SMALL_ZIP")" \
  --app-version-minimum "0.0.0" \
  --app-version-maximum-exclusive "9999.0.0" \
  --private-key-file "$PRIV" \
  --manifest-out "$MANIFEST"

SERVER_PID=""
cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "${PUBLIC_SERVE_ROOT:-}" ]; then
    rm -rf "$PUBLIC_SERVE_ROOT"
  fi
}
trap cleanup EXIT

PUBLIC_SERVE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-toolchain-public.XXXXXX")"
cp "$MANIFEST" "$PUBLIC_SERVE_ROOT/manifest.json"
mkdir -p "$PUBLIC_SERVE_ROOT/out"
ln -s "$CORE_ZIP" "$PUBLIC_SERVE_ROOT/out/$(basename "$CORE_ZIP")"
ln -s "$DA3_BASE_ZIP" "$PUBLIC_SERVE_ROOT/out/$(basename "$DA3_BASE_ZIP")"
ln -s "$DA3_SMALL_ZIP" "$PUBLIC_SERVE_ROOT/out/$(basename "$DA3_SMALL_ZIP")"

pushd "$PUBLIC_SERVE_ROOT" >/dev/null
python3 -m http.server --bind 127.0.0.1 "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null

wait_for_local_manifest_server "$PORT" "$PUBLIC_SERVE_ROOT/manifest.json" "$SERVER_PID"
log "Serving local toolchain manifest at http://localhost:$PORT/manifest.json."

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

launch_app "fresh local manifest at http://localhost:$PORT/manifest.json"
