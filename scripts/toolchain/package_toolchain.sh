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
BRUSH_INSTALL="${BRUSH_INSTALL:-$ROOT/Toolchains/build/brush/install}"
VGGT_MPS_INSTALL="${VGGT_MPS_INSTALL:-$ROOT/Toolchains/build/vggt_mps/install}"
FASTVGGT_MPS_INSTALL="${FASTVGGT_MPS_INSTALL:-$ROOT/Toolchains/build/fastvggt_mps/install}"
MAPANYTHING_MPS_INSTALL="${MAPANYTHING_MPS_INSTALL:-$ROOT/Toolchains/build/mapanything_mps/install}"

OUT="$ROOT/Toolchains/out"
BIN="$OUT/bin"
LIB="$OUT/lib"
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
MODELS_ZIP="$OUT/toolchain-macos-arm64-$VERSION-models.zip"

rm -rf "$OUT"
mkdir -p "$BIN" "$LIB"

validate_build_info() {
  local python_bin="$1"
  local build_info="$2"
  local tool_name="$3"
  PYTHONNOUSERSITE=1 "$python_bin" - "$build_info" "$tool_name" <<'PY'
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

try:
    payload = json.loads(build_info.read_text(encoding="utf-8"))
except Exception as exc:  # noqa: BLE001
    raise SystemExit(f"{tool_name} build_info.json is invalid JSON: {exc}")

if not isinstance(payload, dict):
    raise SystemExit(f"{tool_name} build_info.json must contain a JSON object.")

missing = sorted(key for key in required_keys if not payload.get(key))
if missing:
    raise SystemExit(f"{tool_name} build_info.json is missing required keys: {', '.join(missing)}")

if payload.get("toolchain_name") != tool_name:
    raise SystemExit(
        f"{tool_name} build_info.json toolchain_name mismatch: expected {tool_name}, "
        f"got {payload.get('toolchain_name')!r}"
    )
PY
}

is_system_dependency() {
  case "$1" in
    /usr/lib/*|/System/Library/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_relative_dependency() {
  case "$1" in
    @rpath/*|@loader_path/*|@executable_path/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_macho_file() {
  local path="$1"
  [ -f "$path" ] && /usr/bin/file "$path" | grep -q "Mach-O"
}

otool_dependency_names() {
  otool -L "$1" | awk 'NR > 1 { print $1 }'
}

queued_macho_files=()
processed_macho_files=()
queued_macho_file_keys="|"
processed_macho_file_keys="|"

path_key_present() {
  local needle="|$1|"
  local keys="$2"
  case "$keys" in
    *"$needle"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

enqueue_macho_file() {
  local path="$1"
  if ! is_macho_file "$path"; then
    return
  fi
  if path_key_present "$path" "$queued_macho_file_keys" || path_key_present "$path" "$processed_macho_file_keys"; then
    return
  fi
  queued_macho_files+=("$path")
  queued_macho_file_keys="${queued_macho_file_keys}${path}|"
}

copy_dependency_to_lib() {
  local dependency="$1"
  local referer="$2"
  local dependency_name
  local destination

  if [ ! -f "$dependency" ]; then
    echo "Missing non-system dependency $dependency referenced by $referer." >&2
    exit 1
  fi

  dependency_name="$(basename "$dependency")"
  destination="$LIB/$dependency_name"
  if [ ! -f "$destination" ]; then
    cp -L "$dependency" "$destination"
    chmod u+w "$destination"
    if is_macho_file "$destination"; then
      install_name_tool -id "@rpath/$dependency_name" "$destination" 2>/dev/null || true
    fi
  fi
  enqueue_macho_file "$destination"
}

rewrite_dependency_reference() {
  local file="$1"
  local dependency="$2"
  local dependency_name
  local replacement

  dependency_name="$(basename "$dependency")"
  if [[ "$file" == "$LIB/"* ]]; then
    replacement="@loader_path/$dependency_name"
  else
    replacement="@rpath/$dependency_name"
  fi
  install_name_tool -change "$dependency" "$replacement" "$file"
}

bundle_non_system_dependencies_for() {
  local file="$1"
  local dependency

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    if is_system_dependency "$dependency" || is_relative_dependency "$dependency"; then
      continue
    fi
    if [[ "$dependency" != /* ]]; then
      echo "Unexpected dependency reference $dependency in $file." >&2
      exit 1
    fi
    copy_dependency_to_lib "$dependency" "$file"
    rewrite_dependency_reference "$file" "$dependency"
  done < <(otool_dependency_names "$file")
}

bundle_toolchain_dependency_closure() {
  local path
  local index
  local current

  for path in "$BIN"/* "$LIB"/*; do
    enqueue_macho_file "$path"
  done

  index=0
  while [ "$index" -lt "${#queued_macho_files[@]}" ]; do
    current="${queued_macho_files[$index]}"
    index=$((index + 1))
    if path_key_present "$current" "$processed_macho_file_keys"; then
      continue
    fi
    processed_macho_files+=("$current")
    processed_macho_file_keys="${processed_macho_file_keys}${current}|"
    bundle_non_system_dependencies_for "$current"
  done
}

validate_portable_dependency_references() {
  local file
  local dependency
  local target

  for file in "$BIN"/* "$LIB"/*; do
    if ! is_macho_file "$file"; then
      continue
    fi
    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      if is_system_dependency "$dependency"; then
        continue
      fi
      case "$dependency" in
        @rpath/*)
          target="$LIB/$(basename "$dependency")"
          if [ ! -f "$target" ]; then
            echo "$file references $dependency, but $target is not bundled." >&2
            exit 1
          fi
          ;;
        @loader_path/*)
          target="$(dirname "$file")/${dependency#@loader_path/}"
          if [ ! -f "$target" ]; then
            echo "$file references $dependency, but $target is not bundled." >&2
            exit 1
          fi
          ;;
        @executable_path/*)
          ;;
        /*)
          echo "$file has unportable absolute dependency: $dependency" >&2
          exit 1
          ;;
        *)
          echo "$file has unexpected dependency reference: $dependency" >&2
          exit 1
          ;;
      esac
    done < <(otool_dependency_names "$file")
  done
}

cp "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"

# Brush has changed CLI shapes over time (some versions used subcommands like `train`).
# Package a tiny wrapper so both `brush <dataset>` and `brush train <dataset>` work.
cp "$BRUSH_INSTALL/bin/brush" "$BIN/brush.real"
cat >"$BIN/brush" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$DIR/brush.real"
if [ "${1:-}" = "train" ]; then
  shift
fi
exec "$REAL" "$@"
SCRIPT

chmod +x "$BIN/colmap" "$BIN/brush" "$BIN/brush.real"

if [ ! -d "$MAPANYTHING_MPS_INSTALL/mapanything_mps" ]; then
  echo "mapanything_mps bundle not found at $MAPANYTHING_MPS_INSTALL/mapanything_mps. Build it before packaging." >&2
  exit 1
fi
if [ ! -x "$MAPANYTHING_MPS_INSTALL/mapanything_mps/bin/easysplat_mapanything_sfm" ]; then
  echo "mapanything_mps bundle missing bin/easysplat_mapanything_sfm. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -x "$MAPANYTHING_MPS_INSTALL/mapanything_mps/python/bin/python3" ]; then
  echo "mapanything_mps bundle missing python/bin/python3. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -f "$MAPANYTHING_MPS_INSTALL/mapanything_mps/build_info.json" ]; then
  echo "mapanything_mps bundle missing build_info.json. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -f "$MAPANYTHING_MPS_INSTALL/mapanything_mps/app/easysplat_mapanything_sfm/run.py" ]; then
  echo "mapanything_mps bundle missing app/easysplat_mapanything_sfm/run.py. Rebuild mapanything_mps." >&2
  exit 1
fi
MAP_PY_BIN="$MAPANYTHING_MPS_INSTALL/mapanything_mps/python/bin/python3"
if ! /usr/bin/file "$MAP_PY_BIN" | grep -q "arm64"; then
  echo "mapanything_mps python is not arm64 (Rosetta build detected). Rebuild mapanything_mps on Apple Silicon." >&2
  exit 1
fi
if [ -L "$MAP_PY_BIN" ]; then
  target="$(readlink "$MAP_PY_BIN" || true)"
  if [[ "$target" == /* ]]; then
    echo "mapanything_mps python3 is an absolute symlink ($target). Rebuild mapanything_mps with bundled CPython." >&2
    exit 1
  fi
fi
validate_build_info "$MAP_PY_BIN" "$MAPANYTHING_MPS_INSTALL/mapanything_mps/build_info.json" "mapanything_mps"
if [ ! -d "$MAPANYTHING_MPS_INSTALL/mapanything_mps/models" ]; then
  echo "mapanything_mps bundle missing models/. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -f "$MAPANYTHING_MPS_INSTALL/mapanything_mps/models/map-anything-apache/model.safetensors" ]; then
  echo "mapanything_mps bundle missing models/map-anything-apache/model.safetensors. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -f "$MAPANYTHING_MPS_INSTALL/mapanything_mps/models/map-anything-apache/config.json" ]; then
  echo "mapanything_mps bundle missing models/map-anything-apache/config.json. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -f "$MAPANYTHING_MPS_INSTALL/mapanything_mps/models/dinov2/dinov2_vitg14_pretrain.pth" ]; then
  echo "mapanything_mps bundle missing models/dinov2/dinov2_vitg14_pretrain.pth. Rebuild mapanything_mps." >&2
  exit 1
fi
if [ ! -f "$MAPANYTHING_MPS_INSTALL/mapanything_mps/vendor/mapanything/mapanything/models/mapanything/model.py" ]; then
  echo "mapanything_mps bundle missing vendor/mapanything. Rebuild mapanything_mps." >&2
  exit 1
fi
cp -R "$MAPANYTHING_MPS_INSTALL/mapanything_mps" "$OUT/mapanything_mps"

if [ ! -d "$VGGT_MPS_INSTALL/vggt_mps" ]; then
  echo "vggt_mps bundle not found at $VGGT_MPS_INSTALL/vggt_mps. Build it before packaging." >&2
  exit 1
fi
if [ ! -x "$VGGT_MPS_INSTALL/vggt_mps/bin/easysplat_vggt_sfm" ]; then
  echo "vggt_mps bundle missing bin/easysplat_vggt_sfm. Rebuild vggt_mps." >&2
  exit 1
fi
if [ ! -x "$VGGT_MPS_INSTALL/vggt_mps/python/bin/python3" ]; then
  echo "vggt_mps bundle missing python/bin/python3. Rebuild vggt_mps." >&2
  exit 1
fi
if [ ! -f "$VGGT_MPS_INSTALL/vggt_mps/build_info.json" ]; then
  echo "vggt_mps bundle missing build_info.json. Rebuild vggt_mps." >&2
  exit 1
fi
if [ ! -f "$VGGT_MPS_INSTALL/vggt_mps/app/easysplat_vggt_sfm/run.py" ]; then
  echo "vggt_mps bundle missing app/easysplat_vggt_sfm/run.py. Rebuild vggt_mps." >&2
  exit 1
fi
PY_BIN="$VGGT_MPS_INSTALL/vggt_mps/python/bin/python3"
if ! /usr/bin/file "$PY_BIN" | grep -q "arm64"; then
  echo "vggt_mps python is not arm64 (Rosetta build detected). Rebuild vggt_mps on Apple Silicon." >&2
  exit 1
fi
if [ -L "$PY_BIN" ]; then
  target="$(readlink "$PY_BIN" || true)"
  if [[ "$target" == /* ]]; then
    echo "vggt_mps python3 is an absolute symlink ($target). Rebuild vggt_mps with bundled CPython (no external Python dependency)." >&2
    exit 1
  fi
fi
validate_build_info "$PY_BIN" "$VGGT_MPS_INSTALL/vggt_mps/build_info.json" "vggt_mps"
if [ ! -d "$VGGT_MPS_INSTALL/vggt_mps/models" ]; then
  echo "vggt_mps bundle missing models/. Rebuild vggt_mps." >&2
  exit 1
fi
if [ ! -f "$VGGT_MPS_INSTALL/vggt_mps/models/vggt_model.pt" ]; then
  echo "vggt_mps bundle missing models/vggt_model.pt. Rebuild vggt_mps." >&2
  exit 1
fi
if [ ! -f "$VGGT_MPS_INSTALL/vggt_mps/vendor/vggt/vggt/models/vggt.py" ]; then
  echo "vggt_mps bundle missing vendor/vggt. Rebuild vggt_mps." >&2
  exit 1
fi
cp -R "$VGGT_MPS_INSTALL/vggt_mps" "$OUT/vggt_mps"

if [ ! -d "$FASTVGGT_MPS_INSTALL/fastvggt_mps" ]; then
  echo "fastvggt_mps bundle not found at $FASTVGGT_MPS_INSTALL/fastvggt_mps. Build it before packaging." >&2
  exit 1
fi
if [ ! -x "$FASTVGGT_MPS_INSTALL/fastvggt_mps/bin/easysplat_fastvggt_sfm" ]; then
  echo "fastvggt_mps bundle missing bin/easysplat_fastvggt_sfm. Rebuild fastvggt_mps." >&2
  exit 1
fi
if [ ! -x "$FASTVGGT_MPS_INSTALL/fastvggt_mps/python/bin/python3" ]; then
  echo "fastvggt_mps bundle missing python/bin/python3. Rebuild fastvggt_mps." >&2
  exit 1
fi
if [ ! -f "$FASTVGGT_MPS_INSTALL/fastvggt_mps/build_info.json" ]; then
  echo "fastvggt_mps bundle missing build_info.json. Rebuild fastvggt_mps." >&2
  exit 1
fi
if [ ! -f "$FASTVGGT_MPS_INSTALL/fastvggt_mps/app/easysplat_fastvggt_sfm/run.py" ]; then
  echo "fastvggt_mps bundle missing app/easysplat_fastvggt_sfm/run.py. Rebuild fastvggt_mps." >&2
  exit 1
fi
FAST_PY_BIN="$FASTVGGT_MPS_INSTALL/fastvggt_mps/python/bin/python3"
if ! /usr/bin/file "$FAST_PY_BIN" | grep -q "arm64"; then
  echo "fastvggt_mps python is not arm64 (Rosetta build detected). Rebuild fastvggt_mps on Apple Silicon." >&2
  exit 1
fi
if [ -L "$FAST_PY_BIN" ]; then
  target="$(readlink "$FAST_PY_BIN" || true)"
  if [[ "$target" == /* ]]; then
    echo "fastvggt_mps python3 is an absolute symlink ($target). Rebuild fastvggt_mps with bundled CPython." >&2
    exit 1
  fi
fi
validate_build_info "$FAST_PY_BIN" "$FASTVGGT_MPS_INSTALL/fastvggt_mps/build_info.json" "fastvggt_mps"
if [ ! -d "$FASTVGGT_MPS_INSTALL/fastvggt_mps/models" ]; then
  echo "fastvggt_mps bundle missing models/. Rebuild fastvggt_mps." >&2
  exit 1
fi
if [ ! -f "$FASTVGGT_MPS_INSTALL/fastvggt_mps/models/fastvggt_model.pt" ]; then
  echo "fastvggt_mps bundle missing models/fastvggt_model.pt. Rebuild fastvggt_mps." >&2
  exit 1
fi
if [ ! -f "$FASTVGGT_MPS_INSTALL/fastvggt_mps/vendor/fastvggt/vggt/models/vggt.py" ]; then
  echo "fastvggt_mps bundle missing vendor/fastvggt. Rebuild fastvggt_mps." >&2
  exit 1
fi
cp -R "$FASTVGGT_MPS_INSTALL/fastvggt_mps" "$OUT/fastvggt_mps"

if ! command -v install_name_tool >/dev/null 2>&1; then
  echo "install_name_tool not found; cannot package portable toolchain dependencies." >&2
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
    echo "Missing $OPENSSL_PREFIX/lib/$lib (required by colmap)." >&2
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

for executable in "$BIN"/*; do
  if is_macho_file "$executable"; then
    add_rpath_if_missing "$executable" "@executable_path/../lib"
  fi
done

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

# Validate: colmap must have rpath + reference @rpath OpenSSL libs, and we must ship those libs.
otool -l "$BIN/colmap" | grep -q "@executable_path/../lib" || { echo "colmap missing rpath @executable_path/../lib" >&2; exit 1; }
otool -L "$BIN/colmap" | grep -q "@rpath/libcrypto.3.dylib" || { echo "colmap missing dependency @rpath/libcrypto.3.dylib" >&2; exit 1; }
test -f "$LIB/libcrypto.3.dylib" || { echo "missing bundled libcrypto.3.dylib" >&2; exit 1; }
test -f "$LIB/libssl.3.dylib" || { echo "missing bundled libssl.3.dylib" >&2; exit 1; }

bundle_toolchain_dependency_closure
validate_portable_dependency_references

pushd "$OUT" >/dev/null
zip -r "$CORE_ZIP" \
  bin lib \
  mapanything_mps/bin mapanything_mps/python mapanything_mps/app mapanything_mps/vendor mapanything_mps/build_info.json \
  vggt_mps/bin vggt_mps/python vggt_mps/app vggt_mps/vendor vggt_mps/build_info.json \
  fastvggt_mps/bin fastvggt_mps/python fastvggt_mps/app fastvggt_mps/vendor fastvggt_mps/build_info.json
zip -r "$MODELS_ZIP" mapanything_mps/models vggt_mps/models fastvggt_mps/models
popd >/dev/null

echo "Packaged toolchain (core): $CORE_ZIP"
echo "Packaged toolchain (models): $MODELS_ZIP"
