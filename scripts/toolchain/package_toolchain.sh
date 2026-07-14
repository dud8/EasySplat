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
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$VERSION" =~ $SEMVER_PATTERN ]]; then
  echo "Toolchain version is not valid semantic versioning: $VERSION" >&2
  exit 1
fi

MSPLAT_INSTALL="${MSPLAT_INSTALL:-$ROOT/Toolchains/build/msplat/install}"
DA3_MPS_INSTALL="${DA3_MPS_INSTALL:-$ROOT/Toolchains/build/da3_mps/install}"
MSPLAT_VALIDATOR="$ROOT/scripts/toolchain/validate_native_msplat.sh"
SUPPLY_CHAIN_GENERATOR="$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"

OUT="$ROOT/Toolchains/out"
BIN="$OUT/bin"
LICENSES="$OUT/licenses"
PROVENANCE="$OUT/provenance"
SUPPLY_CHAIN="$OUT/supply-chain"
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
DA3_BASE_ZIP="$OUT/toolchain-geometry-da3-base-$VERSION.zip"
DA3_SMALL_ZIP="$OUT/toolchain-geometry-da3-small-$VERSION.zip"
MAX_RELEASE_ASSET_BYTES=2147483648
MAX_NORMAL_PHOTO_INSTALL_BYTES=2500000000

require_committed_packaging_sources() {
  local status_output
  status_output="$(
    git -C "$ROOT" status --porcelain --untracked-files=all -- \
      LICENSE \
      Tools/Da3Sfm \
      Tools/MsplatNative \
      scripts/toolchain/build_da3_mps.sh \
      scripts/toolchain/build_msplat.sh \
      scripts/toolchain/generate_supply_chain_manifest.py \
      scripts/toolchain/package_toolchain.sh \
      scripts/toolchain/validate_native_msplat.sh
  )"
  if [ -n "$status_output" ]; then
    echo "Toolchain source inputs must be committed before release packaging." >&2
    echo "$status_output" >&2
    exit 1
  fi
}

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

require_committed_packaging_sources
rm -rf "$OUT"
mkdir -p "$BIN" "$LICENSES" "$PROVENANCE" "$SUPPLY_CHAIN"

validate_build_info() {
  local python_bin="$1"
  local build_info="$2"
  local tool_name="$3"
  local colmap_launcher="$4"
  PYTHONNOUSERSITE=1 "$python_bin" - "$build_info" "$tool_name" "$colmap_launcher" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

build_info = Path(sys.argv[1])
tool_name = sys.argv[2]
colmap_launcher = Path(sys.argv[3])
required_keys = {
    "colmap_bridge_source_sha256",
    "colmap_launcher_sha256",
    "supplemental_license_manifest_sha256",
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

launcher_sha256 = str(payload.get("colmap_launcher_sha256") or "")
if not re.fullmatch(r"[0-9a-f]{64}", launcher_sha256):
    raise SystemExit("da3_mps build_info.json has no valid colmap_launcher_sha256")
actual_launcher_sha256 = hashlib.sha256(colmap_launcher.read_bytes()).hexdigest()
if actual_launcher_sha256 != launcher_sha256:
    raise SystemExit("DA3 COLMAP launcher does not match build_info.json")

bridge_source = build_info.parent / "app/easysplat_da3_sfm/colmap_cli.py"
bridge_sha256 = hashlib.sha256(bridge_source.read_bytes()).hexdigest()
if bridge_sha256 != payload["colmap_bridge_source_sha256"]:
    raise SystemExit("DA3 COLMAP bridge source does not match build_info.json")

license_manifest = build_info.parent / "licenses/python-package-upstream-notices.json"
license_manifest_sha256 = hashlib.sha256(license_manifest.read_bytes()).hexdigest()
if license_manifest_sha256 != payload["supplemental_license_manifest_sha256"]:
    raise SystemExit("DA3 supplemental license manifest does not match build_info.json")
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

find_macho_files() {
  python3 - "$OUT" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
magics = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
}
for path in root.rglob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    try:
        with path.open("rb") as stream:
            is_macho = stream.read(4) in magics
    except OSError as exc:
        raise SystemExit(f"Could not inspect packaged file {path}: {exc}") from exc
    if is_macho:
        sys.stdout.buffer.write(os.fsencode(path) + b"\0")
PY
}

validate_packaged_architectures() {
  local file
  local relative
  while IFS= read -r -d '' file; do
    relative="${file#"$OUT"/}"
    require_arm64_only_macho "Packaged native file $relative" "$file"
  done < <(find_macho_files)
}

otool_dependency_names() {
  otool -L "$1" | awk 'NR > 1 { print $1 }'
}

validate_portable_dependencies() {
  local file
  local dependency
  local install_id
  while IFS= read -r -d '' file; do
    install_id="$(otool -D "$file" 2>/dev/null | awk 'NR == 2 { print; exit }' || true)"
    while IFS= read -r dependency; do
      [ -n "$dependency" ] || continue
      [ "$dependency" = "$install_id" ] && continue
      if is_system_dependency "$dependency"; then
        continue
      fi
      case "$dependency" in
        @loader_path/*|@executable_path/*|@rpath/*)
          ;;
        *)
          echo "Unportable dependency in ${file#"$OUT"/}: $dependency" >&2
          exit 1
          ;;
      esac
    done < <(otool_dependency_names "$file")
  done < <(find_macho_files)
}

verify_packaged_signatures() {
  local file
  while IFS= read -r -d '' file; do
    /usr/bin/codesign --verify --strict "$file" || {
      echo "Packaged Mach-O has no valid embedded signature: ${file#"$OUT"/}" >&2
      exit 1
    }
  done < <(find_macho_files)
}

write_colmap_provenance() {
  local repository_revision
  repository_revision="$(git -C "$ROOT" rev-parse HEAD)"
  python3 - \
    "$OUT/da3_mps/licenses/python-packages-install-report.json" \
    "$OUT/da3_mps/build_info.json" \
    "$BIN/colmap" \
    "$PROVENANCE/colmap.json" \
    "$repository_revision" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
build_info_path = Path(sys.argv[2])
executable_path = Path(sys.argv[3])
receipt_path = Path(sys.argv[4])
repository_revision = sys.argv[5]

report = json.loads(report_path.read_text(encoding="utf-8"))
matches = [
    entry
    for entry in report.get("install", [])
    if re.sub(r"[-_.]+", "-", str(entry.get("metadata", {}).get("name") or "")).lower()
    == "pycolmap"
]
if len(matches) != 1:
    raise SystemExit("pip install report must contain exactly one PyCOLMAP artifact")
entry = matches[0]
metadata = entry.get("metadata", {})
download = entry.get("download_info", {})
archive = download.get("archive_info", {})
artifact_sha256 = str(archive.get("hashes", {}).get("sha256") or "")
if not artifact_sha256:
    raw_hash = str(archive.get("hash") or "")
    if raw_hash.startswith("sha256="):
        artifact_sha256 = raw_hash.removeprefix("sha256=")

expected_sha256 = "46d2108eaa1191584796a63f17a5f0204d59e30ec5f2778489ce44e19fff6ac2"
artifact_url = str(download.get("url") or "")
if metadata.get("version") != "3.13.0" or artifact_sha256 != expected_sha256:
    raise SystemExit("packaged PyCOLMAP is not the reviewed 3.13.0 arm64 wheel")
if metadata.get("license") != "BSD-3-Clause" or not artifact_url.startswith("https://"):
    raise SystemExit("PyCOLMAP license or artifact provenance is incomplete")

build_info = json.loads(build_info_path.read_text(encoding="utf-8"))
python_version = str(build_info.get("python_version") or "")
if not python_version:
    raise SystemExit("DA3 build receipt does not identify the bundled Python runtime")

receipt = {
    "toolchain_name": "colmap",
    "source_url": "https://github.com/colmap/colmap",
    "source_repo": "https://github.com/colmap/colmap",
    "source_version": "3.13.0",
    "source_commit": f"sha256:{artifact_sha256}",
    "license": "BSD-3-Clause",
    "backend": "pycolmap",
    "runtime": "bundled-python",
    "runtime_version": python_version,
    "artifact_url": artifact_url,
    "artifact_sha256": artifact_sha256,
    "bridge_source_url": "https://github.com/dud8/EasySplat",
    "bridge_revision": repository_revision,
    "bridge_source": build_info.get("colmap_bridge_source"),
    "bridge_source_sha256": build_info.get("colmap_bridge_source_sha256"),
    "supplemental_license_manifest_sha256": build_info.get(
        "supplemental_license_manifest_sha256"
    ),
    "executable_sha256": hashlib.sha256(executable_path.read_bytes()).hexdigest(),
}
receipt_path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

mkdir -p "$LICENSES/EasySplat"
install -m 0644 "$ROOT/LICENSE" "$LICENSES/EasySplat/LICENSE"

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

chmod +x "$BIN/easysplat-train"

if [ ! -d "$DA3_MPS_INSTALL/da3_mps" ]; then
  echo "da3_mps bundle not found at $DA3_MPS_INSTALL/da3_mps. Build it before packaging." >&2
  exit 1
fi
if [ ! -x "$DA3_MPS_INSTALL/da3_mps/bin/easysplat_da3_sfm" ]; then
  echo "da3_mps bundle missing bin/easysplat_da3_sfm. Rebuild da3_mps." >&2
  exit 1
fi
if [ ! -x "$DA3_MPS_INSTALL/da3_mps/bin/easysplat_colmap" ]; then
  echo "da3_mps bundle missing bin/easysplat_colmap. Rebuild da3_mps." >&2
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
if [ ! -f "$DA3_MPS_INSTALL/da3_mps/app/easysplat_da3_sfm/colmap_cli.py" ]; then
  echo "da3_mps bundle missing app/easysplat_da3_sfm/colmap_cli.py. Rebuild da3_mps." >&2
  exit 1
fi
DA3_PY_BIN="$DA3_MPS_INSTALL/da3_mps/python/bin/python3"
require_bundled_arm64_python "da3_mps" "$DA3_PY_BIN"
validate_build_info \
  "$DA3_PY_BIN" \
  "$DA3_MPS_INSTALL/da3_mps/build_info.json" \
  "da3_mps" \
  "$DA3_MPS_INSTALL/da3_mps/bin/easysplat_colmap"
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
find "$OUT/da3_mps/python" -type f -name '*.pyc' -delete
find "$OUT/da3_mps/python" -type d -name '__pycache__' -empty -delete
install -m 0755 "$OUT/da3_mps/bin/easysplat_colmap" "$BIN/colmap"

if ! command -v otool >/dev/null 2>&1; then
  echo "otool not found; cannot validate toolchain binary dependencies." >&2
  exit 1
fi
if [ ! -x /usr/bin/codesign ]; then
  echo "codesign not found; cannot verify the packaged Mach-O closure." >&2
  exit 1
fi

validate_packaged_architectures
validate_portable_dependencies
verify_packaged_signatures
write_colmap_provenance

PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH="$OUT/da3_mps/app" \
  "$OUT/da3_mps/python/bin/python3" - <<'PY'
import pycolmap

if pycolmap.__version__ != "3.13.0":
    raise SystemExit(f"unexpected PyCOLMAP version: {pycolmap.__version__}")
PY

"$BIN/colmap" -h >/dev/null 2>&1 || { echo "colmap bridge failed to launch" >&2; exit 1; }
"$BIN/colmap" feature_extractor -h >/dev/null 2>&1 || { echo "colmap bridge missing feature_extractor" >&2; exit 1; }
"$BIN/colmap" mapper -h >/dev/null 2>&1 || { echo "colmap bridge missing mapper" >&2; exit 1; }
"$BIN/colmap" point_triangulator -h >/dev/null 2>&1 || { echo "colmap bridge missing point_triangulator" >&2; exit 1; }
"$BIN/colmap" image_undistorter -h >/dev/null 2>&1 || { echo "colmap missing working image_undistorter command" >&2; exit 1; }
"$MSPLAT_VALIDATOR" --packaged "$OUT"

if [ ! -x "$SUPPLY_CHAIN_GENERATOR" ]; then
  echo "Supply-chain manifest generator is missing or not executable: $SUPPLY_CHAIN_GENERATOR" >&2
  exit 1
fi
"$SUPPLY_CHAIN_GENERATOR" \
  --toolchain-root "$OUT" \
  --version "$VERSION"

for forbidden in AGPL CGAL LSD SPQR SiftGPU da3_streaming salad; do
  if find "$OUT" -mindepth 1 -print | \
    grep -Ei "(^|/)${forbidden}([^/]*)(/|$)" >/dev/null; then
    echo "Forbidden release payload entry matched ${forbidden}." >&2
    exit 1
  fi
done

pushd "$OUT" >/dev/null
zip -q -r -D "$CORE_ZIP" \
  bin \
  licenses provenance supply-chain/components.json \
  msplat/build_info.json msplat/LICENSE \
  da3_mps/bin da3_mps/python da3_mps/app da3_mps/vendor da3_mps/licenses da3_mps/build_info.json
zip -q -r -D "$DA3_BASE_ZIP" da3_mps/models/DA3-BASE
zip -q -r -D "$DA3_SMALL_ZIP" da3_mps/models/DA3-SMALL
popd >/dev/null

assert_release_asset_size "$CORE_ZIP"
assert_release_asset_size "$DA3_BASE_ZIP"
assert_release_asset_size "$DA3_SMALL_ZIP"
assert_normal_photo_install_size "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"

echo "Packaged toolchain (core): $CORE_ZIP"
echo "Packaged component (DA3-BASE): $DA3_BASE_ZIP"
echo "Packaged component (DA3-SMALL): $DA3_SMALL_ZIP"
