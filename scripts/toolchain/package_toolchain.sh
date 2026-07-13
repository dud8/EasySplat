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
CERES_INSTALL="${CERES_INSTALL:-$ROOT/Toolchains/build/ceres/install}"
SUITESPARSE_INSTALL="${SUITESPARSE_INSTALL:-$ROOT/Toolchains/build/suitesparse/install}"
OPENIMAGEIO_INSTALL="${OPENIMAGEIO_INSTALL:-$ROOT/Toolchains/build/openimageio/install}"
MSPLAT_INSTALL="${MSPLAT_INSTALL:-$ROOT/Toolchains/build/msplat/install}"
DA3_MPS_INSTALL="${DA3_MPS_INSTALL:-$ROOT/Toolchains/build/da3_mps/install}"
MSPLAT_VALIDATOR="$ROOT/scripts/toolchain/validate_native_msplat.sh"
SUPPLY_CHAIN_GENERATOR="$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"

OUT="$ROOT/Toolchains/out"
BIN="$OUT/bin"
LIB="$OUT/lib"
LICENSES="$OUT/licenses"
PROVENANCE="$OUT/provenance"
SUPPLY_CHAIN="$OUT/supply-chain"
DEPENDENCY_ORIGINS="$SUPPLY_CHAIN/dependency-origins.tsv"
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
DA3_BASE_ZIP="$OUT/toolchain-geometry-da3-base-$VERSION.zip"
DA3_SMALL_ZIP="$OUT/toolchain-geometry-da3-small-$VERSION.zip"
MAX_RELEASE_ASSET_BYTES=2147483648
MAX_NORMAL_PHOTO_INSTALL_BYTES=2500000000

assert_release_asset_size() {
  local archive="$1"
  local size
  size="$(stat -f '%z' "$archive")"
  if (( size >= MAX_RELEASE_ASSET_BYTES )); then
    echo "Release component must be smaller than 2 GiB: $archive ($size bytes)" >&2
    exit 1
  fi
}

assert_normal_photo_install_size() {
  local total=0
  local archive
  local size
  for archive in "$@"; do
    size="$(stat -f '%z' "$archive")"
    total=$((total + size))
  done
  if (( total > MAX_NORMAL_PHOTO_INSTALL_BYTES )); then
    echo "Normal photo toolchain download exceeds 2.5 GB: $total bytes" >&2
    exit 1
  fi
}

rm -rf "$OUT"
mkdir -p "$BIN" "$LIB" "$LICENSES" "$PROVENANCE" "$SUPPLY_CHAIN"
: >"$DEPENDENCY_ORIGINS"

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

if tool_name == "da3_mps" and payload.get("source_provenance") != "pinned-git":
    raise SystemExit(
        "da3_mps build_info.json must record pinned-git source_provenance; "
        f"got {payload.get('source_provenance')!r}"
    )
PY
}

require_arm64_only_macho() {
  local label="$1"
  local binary="$2"
  local desc
  local architectures
  desc="$(/usr/bin/file -b "$binary")"
  if [[ "$desc" != *Mach-O* ]]; then
    echo "$label is not a Mach-O binary (file reported: $desc)." >&2
    exit 1
  fi
  if ! architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null)"; then
    echo "$label architecture could not be inspected with lipo." >&2
    exit 1
  fi
  if [[ "$architectures" != "arm64" || "$desc" == *"universal binary"* ]]; then
    echo "$label must be an arm64-only Mach-O binary (found: $architectures)." >&2
    exit 1
  fi
}

require_bundled_arm64_python() {
  local tool_name="$1"
  local python_bin="$2"
  local target
  require_arm64_only_macho "$tool_name python" "$python_bin"
  if [ -L "$python_bin" ]; then
    target="$(readlink "$python_bin" || true)"
    if [[ "$target" == /* ]]; then
      echo "$tool_name python3 is an absolute symlink ($target). Rebuild $tool_name with bundled CPython." >&2
      exit 1
    fi
  fi
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

is_macho_file() {
  local path="$1"
  [ -f "$path" ] && /usr/bin/file "$path" | grep -q "Mach-O"
}

validate_packaged_architectures() {
  local file
  local relative
  while IFS= read -r -d '' file; do
    is_macho_file "$file" || continue
    relative="${file#"$OUT"/}"
    require_arm64_only_macho "Packaged native file $relative" "$file"
  done < <(find "$OUT" -type f -print0)
}

otool_dependency_names() {
  otool -L "$1" | awk 'NR > 1 { print $1 }'
}

otool_rpath_entries() {
  otool -l "$1" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

resolve_macho_path_token() {
  local file="$1"
  local value="$2"
  case "$value" in
    @loader_path/*)
      printf '%s/%s\n' "$(dirname "$file")" "${value#@loader_path/}"
      ;;
    @executable_path/*)
      printf '%s/%s\n' "$(dirname "$file")" "${value#@executable_path/}"
      ;;
    /*)
      printf '%s\n' "$value"
      ;;
    *)
      printf '%s/%s\n' "$(dirname "$file")" "$value"
      ;;
  esac
}

resolve_rpath_dependency_for() {
  local file="$1"
  local dependency="$2"
  local name="${dependency#@rpath/}"
  local rpath
  local resolved

  if [ -f "$LIB/$name" ]; then
    return 0
  fi
  while IFS= read -r rpath; do
    [ -n "$rpath" ] || continue
    resolved="$(resolve_macho_path_token "$file" "$rpath")"
    if [ -f "$resolved/$name" ]; then
      return 0
    fi
  done < <(otool_rpath_entries "$file")
  return 1
}

resolve_rpath_dependency_path_for() {
  local file="$1"
  local dependency="$2"
  local name="${dependency#@rpath/}"
  local rpath
  local resolved

  if [ -f "$LIB/$name" ]; then
    printf '%s\n' "$LIB/$name"
    return 0
  fi
  while IFS= read -r rpath; do
    [ -n "$rpath" ] || continue
    resolved="$(resolve_macho_path_token "$file" "$rpath")"
    if [ -f "$resolved/$name" ]; then
      printf '%s\n' "$resolved/$name"
      return 0
    fi
  done < <(otool_rpath_entries "$file")
  return 1
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
  local existing_origin
  local real_dependency

  if [ ! -f "$dependency" ]; then
    echo "Missing non-system dependency $dependency referenced by $referer." >&2
    exit 1
  fi

  dependency_name="$(basename "$dependency")"
  destination="$LIB/$dependency_name"
  real_dependency="$(python3 - "$dependency" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  if [ ! -f "$destination" ]; then
    cp -L "$dependency" "$destination"
    chmod u+w "$destination"
    if is_macho_file "$destination"; then
      install_name_tool -id "@rpath/$dependency_name" "$destination" 2>/dev/null || true
    fi
    printf 'lib/%s\t%s\n' "$dependency_name" "$real_dependency" >>"$DEPENDENCY_ORIGINS"
  else
    existing_origin="$(awk -F '\t' -v path="lib/$dependency_name" '$1 == path { print $2; exit }' "$DEPENDENCY_ORIGINS")"
    if [ -n "$existing_origin" ] && [ "$existing_origin" != "$real_dependency" ]; then
      echo "Dependency basename collision for $dependency_name: $existing_origin and $real_dependency." >&2
      exit 1
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
  local resolved

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    if is_system_dependency "$dependency"; then
      continue
    fi
    case "$dependency" in
      @rpath/*)
        if ! resolved="$(resolve_rpath_dependency_path_for "$file" "$dependency")"; then
          echo "Unable to resolve $dependency referenced by $file." >&2
          exit 1
        fi
        if [[ "$resolved" != "$LIB/"* ]]; then
          copy_dependency_to_lib "$resolved" "$file"
          rewrite_dependency_reference "$file" "$dependency"
        fi
        ;;
      @loader_path/*|@executable_path/*)
        resolved="$(resolve_macho_path_token "$file" "$dependency")"
        if [ ! -f "$resolved" ]; then
          echo "Unable to resolve $dependency referenced by $file." >&2
          exit 1
        fi
        if [[ "$resolved" != "$OUT/"* ]]; then
          copy_dependency_to_lib "$resolved" "$file"
          rewrite_dependency_reference "$file" "$dependency"
        fi
        ;;
      /*)
        copy_dependency_to_lib "$dependency" "$file"
        rewrite_dependency_reference "$file" "$dependency"
        ;;
      *)
        echo "Unexpected dependency reference $dependency in $file." >&2
        exit 1
        ;;
    esac
  done < <(otool_dependency_names "$file")
}

bundle_toolchain_dependency_closure() {
  local path
  local index
  local current

  for path in "$BIN"/* "$LIB"/*; do
    [ "$path" = "$BIN/easysplat-train" ] && continue
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

validate_portable_dependency_references_for() {
  local file
  file="$1"
  if ! is_macho_file "$file"; then
    return
  fi
  local dependency
  local rpath
  local rpath_count=0
  local target

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    if is_system_dependency "$dependency"; then
      continue
    fi
    case "$dependency" in
      @rpath/*)
        if ! resolve_rpath_dependency_for "$file" "$dependency"; then
          target="$LIB/$(basename "$dependency")"
          echo "$file references $dependency, but it is not bundled in $target or reachable through that file's LC_RPATH entries." >&2
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

  while IFS= read -r rpath; do
    [ -n "$rpath" ] || continue
    rpath_count=$((rpath_count + 1))
    if [[ "$file" == "$LIB/"* ]]; then
      echo "$file retains an unnecessary LC_RPATH entry: $rpath" >&2
      exit 1
    fi
    if [[ "$file" == "$BIN/"* ]] && [ "$rpath" != "@executable_path/../lib" ]; then
      echo "$file has an unportable LC_RPATH entry: $rpath" >&2
      exit 1
    fi
  done < <(otool_rpath_entries "$file")
  if [[ "$file" == "$BIN/"* ]] && [ "$rpath_count" -ne 1 ]; then
    echo "$file must contain exactly one canonical LC_RPATH entry." >&2
    exit 1
  fi
}

validate_portable_dependency_references() {
  local file
  local dependency

  for file in "$BIN"/* "$LIB"/*; do
    validate_portable_dependency_references_for "$file"
  done
}

relative_lib_rpath_for() {
  python3 - "$1" "$LIB" <<'PY'
import os
import sys
from pathlib import Path

source_dir = Path(sys.argv[1]).parent
lib_dir = Path(sys.argv[2])
relative = os.path.relpath(lib_dir, source_dir)
print("@loader_path/" + relative)
PY
}

add_bundle_lib_rpath_if_needed() {
  local file="$1"
  local rpath
  if ! is_macho_file "$file" || [[ "$file" == "$LIB/"* ]]; then
    return
  fi
  if [[ "$file" == "$BIN/"* ]]; then
    rpath="@executable_path/../lib"
  else
    rpath="$(relative_lib_rpath_for "$file")"
  fi
  if ! otool -l "$file" | grep -q "$rpath"; then
    install_name_tool -add_rpath "$rpath" "$file"
  fi
}

add_bundle_lib_rpaths() {
  local file
  for file in "$BIN"/*; do
    add_bundle_lib_rpath_if_needed "$file"
  done
}

normalize_bundle_rpaths() {
  local file
  local rpath

  for file in "$BIN"/* "$LIB"/*; do
    is_macho_file "$file" || continue
    while IFS= read -r rpath; do
      [ -n "$rpath" ] || continue
      install_name_tool -delete_rpath "$rpath" "$file"
    done < <(otool_rpath_entries "$file")
    if [[ "$file" == "$BIN/"* ]]; then
      install_name_tool -add_rpath "@executable_path/../lib" "$file"
    fi
  done
}

ad_hoc_sign_packaged_machos() {
  local file
  local -a dylibs=()
  local -a other_machos=()

  while IFS= read -r -d '' file; do
    is_macho_file "$file" || continue
    chmod u+w "$file"
    if /usr/bin/file -b "$file" | grep -q 'dynamically linked shared library'; then
      dylibs+=("$file")
    else
      other_machos+=("$file")
    fi
  done < <(find "$OUT" -type f -print0)

  # install_name_tool invalidates existing arm64 signatures. Sign the completed
  # dylib graph first, then executables, bundles, and extension modules.
  for file in "${dylibs[@]}" "${other_machos[@]}"; do
    /usr/bin/codesign --force --sign - --timestamp=none "$file"
  done
  for file in "${dylibs[@]}" "${other_machos[@]}"; do
    /usr/bin/codesign --verify --strict "$file" || {
      echo "Ad-hoc signature verification failed: $file" >&2
      exit 1
    }
  done
}

refresh_packaged_msplat_hash() {
  python3 - "$OUT/msplat/build_info.json" "$BIN/easysplat-train" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

receipt = Path(sys.argv[1])
executable = Path(sys.argv[2])
payload = json.loads(receipt.read_text(encoding="utf-8"))
payload["executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

reject_forbidden_image_dependencies() {
  local file
  local dependency
  local dependency_lower
  local forbidden='(avcodec|avformat|avutil|swresample|swscale|ffmpeg|heif|de265|x264|x265|aom|dav1d|vpx|svtav1|theora|vorbis|webp|opencolorio|ocio|tbb|freetype|dcmtk|libraw|gif)'

  for file in "$BIN"/* "$LIB"/*; do
    is_macho_file "$file" || continue
    while IFS= read -r dependency; do
      dependency_lower="$(printf '%s' "$dependency" | tr '[:upper:]' '[:lower:]')"
      if [[ "$dependency_lower" =~ $forbidden ]]; then
        echo "Forbidden image dependency in $(basename "$file"): $dependency" >&2
        exit 1
      fi
    done < <(otool_dependency_names "$file")
  done
  if find "$LIB" -mindepth 1 -maxdepth 1 -print | \
    grep -Eqi "$forbidden"; then
    echo "Forbidden image dependency was copied into the runtime library closure." >&2
    exit 1
  fi
  if grep -Eq $'\t/opt/homebrew/(opt|Cellar)/openimageio([^/]*)/' "$DEPENDENCY_ORIGINS"; then
    echo "Homebrew OpenImageIO entered the runtime closure." >&2
    exit 1
  fi
}

cp "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"

for install_root in "$COLMAP_INSTALL" "$CERES_INSTALL" "$SUITESPARSE_INSTALL" "$OPENIMAGEIO_INSTALL"; do
  if [ ! -s "$install_root/build_info.json" ] || [ ! -d "$install_root/licenses" ]; then
    echo "Missing staged provenance or licenses under $install_root. Rebuild the pinned native dependency." >&2
    exit 1
  fi
done
cp "$COLMAP_INSTALL/build_info.json" "$PROVENANCE/colmap.json"
cp "$CERES_INSTALL/build_info.json" "$PROVENANCE/ceres.json"
cp "$SUITESPARSE_INSTALL/build_info.json" "$PROVENANCE/suitesparse.json"
cp "$OPENIMAGEIO_INSTALL/build_info.json" "$PROVENANCE/openimageio.json"
mkdir -p "$LICENSES/EasySplat"
install -m 0644 "$ROOT/LICENSE" "$LICENSES/EasySplat/LICENSE"
cp -R "$COLMAP_INSTALL/licenses/." "$LICENSES/"
cp -R "$CERES_INSTALL/licenses/." "$LICENSES/"
cp -R "$SUITESPARSE_INSTALL/licenses/." "$LICENSES/"
cp -R "$OPENIMAGEIO_INSTALL/licenses/." "$LICENSES/"

"$MSPLAT_VALIDATOR" --source "$MSPLAT_INSTALL/msplat"
mkdir -p "$OUT/msplat"
cp "$MSPLAT_INSTALL/msplat/bin/easysplat-train" "$BIN/easysplat-train"
cp "$MSPLAT_INSTALL/msplat/bin/default.metallib" "$BIN/default.metallib"
cp "$MSPLAT_INSTALL/msplat/build_info.json" "$OUT/msplat/build_info.json"
cp "$MSPLAT_INSTALL/msplat/LICENSE" "$OUT/msplat/LICENSE"

MSPLAT_DEPS="$ROOT/Toolchains/build/msplat/dependencies"
mkdir -p "$LICENSES/msplat/CLI11" "$LICENSES/msplat/nanoflann" "$LICENSES/msplat/nlohmann-json"
install -m 0644 "$MSPLAT_DEPS/CLI11-2.4.2/LICENSE" "$LICENSES/msplat/CLI11/LICENSE"
install -m 0644 "$MSPLAT_DEPS/nanoflann-1.5.5/COPYING" "$LICENSES/msplat/nanoflann/COPYING"
install -m 0644 "$MSPLAT_DEPS/nlohmann-json-3.11.3/LICENSE.MIT" "$LICENSES/msplat/nlohmann-json/LICENSE.MIT"

chmod +x "$BIN/colmap" "$BIN/easysplat-train"

if [ ! -d "$DA3_MPS_INSTALL/da3_mps" ]; then
  echo "da3_mps bundle not found at $DA3_MPS_INSTALL/da3_mps. Build it before packaging." >&2
  exit 1
fi
if [ ! -x "$DA3_MPS_INSTALL/da3_mps/bin/easysplat_da3_sfm" ]; then
  echo "da3_mps bundle missing bin/easysplat_da3_sfm. Rebuild da3_mps." >&2
  exit 1
fi
if [ ! -x "$DA3_MPS_INSTALL/da3_mps/python/bin/python3" ]; then
  echo "da3_mps bundle missing python/bin/python3. Rebuild da3_mps." >&2
  exit 1
fi
if [ ! -f "$DA3_MPS_INSTALL/da3_mps/build_info.json" ]; then
  echo "da3_mps bundle missing build_info.json. Rebuild da3_mps." >&2
  exit 1
fi
if [ ! -f "$DA3_MPS_INSTALL/da3_mps/app/easysplat_da3_sfm/run.py" ]; then
  echo "da3_mps bundle missing app/easysplat_da3_sfm/run.py. Rebuild da3_mps." >&2
  exit 1
fi
DA3_PY_BIN="$DA3_MPS_INSTALL/da3_mps/python/bin/python3"
require_bundled_arm64_python "da3_mps" "$DA3_PY_BIN"
validate_build_info "$DA3_PY_BIN" "$DA3_MPS_INSTALL/da3_mps/build_info.json" "da3_mps"
if [ ! -d "$DA3_MPS_INSTALL/da3_mps/models" ]; then
  echo "da3_mps bundle missing models/. Rebuild da3_mps." >&2
  exit 1
fi
for model in DA3-BASE DA3-SMALL; do
  if [ ! -f "$DA3_MPS_INSTALL/da3_mps/models/$model/model.safetensors" ]; then
    echo "da3_mps bundle missing models/$model/model.safetensors. Rebuild da3_mps." >&2
    exit 1
  fi
  if [ ! -f "$DA3_MPS_INSTALL/da3_mps/models/$model/config.json" ]; then
    echo "da3_mps bundle missing models/$model/config.json. Rebuild da3_mps." >&2
    exit 1
  fi
  if [ ! -f "$DA3_MPS_INSTALL/da3_mps/models/$model/easysplat_model_info.json" ]; then
    echo "da3_mps bundle missing models/$model/easysplat_model_info.json. Rebuild da3_mps." >&2
    exit 1
  fi
done
if [ ! -f "$DA3_MPS_INSTALL/da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py" ]; then
  echo "da3_mps bundle missing vendor/depth-anything-3. Rebuild da3_mps." >&2
  exit 1
fi
cp -R "$DA3_MPS_INSTALL/da3_mps" "$OUT/da3_mps"

if ! command -v install_name_tool >/dev/null 2>&1; then
  echo "install_name_tool not found; cannot package portable toolchain dependencies." >&2
  exit 1
fi
if ! command -v otool >/dev/null 2>&1; then
  echo "otool not found; cannot validate toolchain binary dependencies." >&2
  exit 1
fi
if [ ! -x /usr/bin/codesign ]; then
  echo "codesign not found; cannot restore integrity after Mach-O rewriting." >&2
  exit 1
fi

add_bundle_lib_rpaths

if otool -L "$BIN/colmap" | grep -Eq 'libcrypto|libssl'; then
  echo "COLMAP unexpectedly links OpenSSL even though download support is disabled." >&2
  exit 1
fi

# The stripped COLMAP install deliberately carries only its executable, receipts,
# and notices. Seed its pinned native roots before walking the Mach-O graph.
copy_dependency_to_lib "$CERES_INSTALL/lib/libceres.4.dylib" "$BIN/colmap"
copy_dependency_to_lib "$SUITESPARSE_INSTALL/lib/libcholmod.5.dylib" "$BIN/colmap"
copy_dependency_to_lib "$OPENIMAGEIO_INSTALL/lib/libOpenImageIO.2.5.dylib" "$BIN/colmap"
copy_dependency_to_lib "$OPENIMAGEIO_INSTALL/lib/libOpenImageIO_Util.2.5.dylib" "$BIN/colmap"

bundle_toolchain_dependency_closure
normalize_bundle_rpaths
validate_packaged_architectures
ad_hoc_sign_packaged_machos
refresh_packaged_msplat_hash
validate_portable_dependency_references
reject_forbidden_image_dependencies
"$BIN/colmap" global_mapper -h >/dev/null 2>&1 || { echo "colmap missing working global_mapper command" >&2; exit 1; }
"$BIN/colmap" image_undistorter -h >/dev/null 2>&1 || { echo "colmap missing working image_undistorter command" >&2; exit 1; }
"$MSPLAT_VALIDATOR" --packaged "$OUT"

if [ ! -x "$SUPPLY_CHAIN_GENERATOR" ]; then
  echo "Supply-chain manifest generator is missing or not executable: $SUPPLY_CHAIN_GENERATOR" >&2
  exit 1
fi
"$SUPPLY_CHAIN_GENERATOR" \
  --toolchain-root "$OUT" \
  --dependency-origins "$DEPENDENCY_ORIGINS" \
  --version "$VERSION"
rm -f "$DEPENDENCY_ORIGINS"

for forbidden in AGPL CGAL LSD SPQR SiftGPU da3_streaming salad; do
  if find "$OUT" -mindepth 1 -print | grep -Eqi "(^|/)${forbidden}([^/]*)(/|$)"; then
    echo "Forbidden release payload entry matched ${forbidden}." >&2
    exit 1
  fi
done

pushd "$OUT" >/dev/null
zip -r -D "$CORE_ZIP" \
  bin lib \
  licenses provenance supply-chain/components.json \
  msplat/build_info.json msplat/LICENSE \
  da3_mps/bin da3_mps/python da3_mps/app da3_mps/vendor da3_mps/licenses da3_mps/build_info.json
zip -r -D "$DA3_BASE_ZIP" da3_mps/models/DA3-BASE
zip -r -D "$DA3_SMALL_ZIP" da3_mps/models/DA3-SMALL
popd >/dev/null

assert_release_asset_size "$CORE_ZIP"
assert_release_asset_size "$DA3_BASE_ZIP"
assert_release_asset_size "$DA3_SMALL_ZIP"
assert_normal_photo_install_size "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"

echo "Packaged toolchain (core): $CORE_ZIP"
echo "Packaged component (DA3-BASE): $DA3_BASE_ZIP"
echo "Packaged component (DA3-SMALL): $DA3_SMALL_ZIP"
