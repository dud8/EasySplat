#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-2.0.0}"
TOOLCHAIN_ROOT=""
FAST=0
REBUILD=0

log() {
  printf '[run] %s\n' "$*"
}

launch_app() {
  local launch_mode="$1"
  # `swift run` produces a bare executable rather than an app bundle, so the
  # override is the only way the app can find its tools here.
  export EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT"
  log "Launching EasySplatApp ($launch_mode)."
  log "If the window does not come to the front automatically, switch to EasySplatApp in the Dock."
  swift run --package-path "$ROOT" EasySplatApp
}

usage() {
  cat <<'EOF'
Usage: ./scripts/run.sh [options]

Options:
  --fast                 Run with the built toolchain as-is (no rebuild).
  --rebuild              Force a toolchain rebuild.
  --version <semver>     Toolchain version to package (default: 2.0.0).
  --toolchain-root <dir> Toolchain tree to run against (default: Toolchains/out).
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

TOOLCHAINS="$ROOT/Toolchains"
OUT="$TOOLCHAINS/out"

# The app resolves tools from this tree; packaging writes it in place.
if [ -z "$TOOLCHAIN_ROOT" ]; then
  TOOLCHAIN_ROOT="$OUT"
fi
# This script extracts archives into the toolchain root and replaces payload
# directories inside it, so the root is bounded to the staging tree and the
# per-version install locations. An arbitrary path would be destroyed.
TOOLCHAIN_ROOT="$(python3 - \
  "$TOOLCHAIN_ROOT" \
  "$VERSION" \
  "$OUT" \
  "$HOME/Library/Application Support/EasySplat/Toolchains" \
  "$ROOT/Toolchains/dev" \
  "${TMPDIR:-/tmp}/EasySplat/Toolchains" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).expanduser().resolve(strict=False)
version = sys.argv[2]
staging = Path(sys.argv[3]).expanduser().resolve(strict=False)
allowed_parents = {Path(value).expanduser().resolve(strict=False) for value in sys.argv[4:]}
semver = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
if not semver.fullmatch(version):
    raise SystemExit(f"Invalid toolchain version: {version}")
if root != staging and (root.name != version or root.parent not in allowed_parents):
    allowed = ", ".join([str(staging)] + [str(parent / version) for parent in sorted(allowed_parents)])
    raise SystemExit(
        f"Refusing unsafe toolchain root: {root}. Expected one of: {allowed}"
    )
print(root)
PY
)"

python3 - "$VERSION" <<'PY'
import re
import sys

semver = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
if not semver.fullmatch(sys.argv[1]):
    raise SystemExit(f"Invalid toolchain version: {sys.argv[1]}")
PY
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
DA3_BASE_ZIP="$OUT/toolchain-geometry-da3-base-$VERSION.zip"
DA3_SMALL_ZIP="$OUT/toolchain-geometry-da3-small-$VERSION.zip"
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

toolchain_inputs_newer() {
  test -f "$CORE_ZIP" || return 1
  find "$ROOT/Tools/Da3Sfm" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/Tools/MsplatNative" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  find "$ROOT/scripts/toolchain" -type f -newer "$CORE_ZIP" -print -quit | grep -q . && return 0
  return 1
}

archive_component_owned() {
  python3 - "$1" "$2" <<'PY' >/dev/null
import stat
import sys
import zipfile

archive_path, component = sys.argv[1:]
core_anchors = {
    "bin/colmap",
    "bin/easysplat-train",
    "bin/default.metallib",
    "lib/libomp.dylib",
    "provenance/colmap.json",
    "provenance/colmap-support.json",
    "provenance/ceres.json",
    "provenance/openimageio.json",
    "msplat/build_info.json",
    "msplat/LICENSE",
    "supply-chain/components.json",
}
base_anchors = {
    "da3_mps/bin/easysplat_da3_sfm",
    "da3_mps/python/bin/python3",
    "da3_mps/app/easysplat_da3_sfm/run.py",
    "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
    "da3_mps/build_info.json",
    "da3_mps/models/DA3-BASE/config.json",
    "da3_mps/models/DA3-BASE/model.safetensors",
    "da3_mps/models/DA3-BASE/easysplat_model_info.json",
    "da3_mps/models/DA3-BASE/LICENSE",
}
small_files = {
    "da3_mps/models/DA3-SMALL/config.json",
    "da3_mps/models/DA3-SMALL/model.safetensors",
    "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
    "da3_mps/models/DA3-SMALL/LICENSE",
}

try:
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
except (OSError, zipfile.BadZipFile):
    raise SystemExit(1)

paths = []
for info in infos:
    path = info.filename
    parts = path.split("/")
    file_type = stat.S_IFMT(info.external_attr >> 16)
    if (
        not path
        or info.is_dir()
        or path.startswith("/")
        or "\\" in path
        or not parts
        or any(part in {"", ".", ".."} for part in parts)
        or file_type not in {0, stat.S_IFREG}
    ):
        raise SystemExit(1)
    paths.append(path)

if not paths or len(paths) != len(set(paths)):
    raise SystemExit(1)

if component == "core":
    owned = core_anchors.issubset(paths) and all(
        path in core_anchors
        or path == "provenance/distribution-signing.json"
        or (path.startswith("licenses/") and len(path) > len("licenses/"))
        for path in paths
    )
elif component == "da3-base":
    prefixes = (
        "da3_mps/bin/",
        "da3_mps/python/",
        "da3_mps/app/",
        "da3_mps/vendor/",
        "da3_mps/licenses/",
        "da3_mps/models/DA3-BASE/",
    )
    owned = (
        base_anchors.issubset(paths)
        and any(path.startswith("da3_mps/licenses/") for path in paths)
        and all(
            path == "da3_mps/build_info.json"
            or path.startswith(prefixes)
            for path in paths
        )
    )
elif component == "da3-small":
    owned = set(paths) == small_files
else:
    owned = False

raise SystemExit(0 if owned else 1)
PY
}

core_zip_valid() {
  test -f "$CORE_ZIP" || return 1
  "$MSPLAT_VALIDATOR" --archive "$CORE_ZIP" >/dev/null 2>&1 || return 1
  archive_component_owned "$CORE_ZIP" "core" || return 1

  local tmp
  tmp="$(mktemp -d)"
  local rc=0
  {
    unzip -p "$CORE_ZIP" bin/colmap >"$tmp/colmap" 2>/dev/null \
      && chmod +x "$tmp/colmap" \
      && /usr/bin/codesign --verify --strict "$tmp/colmap"
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

da3_base_zip_valid() {
  local zip_path="$1"
  test -f "$zip_path" || return 1
  archive_component_owned "$zip_path" "da3-base" || return 1
}

da3_small_zip_valid() {
  local zip_path="$1"
  test -f "$zip_path" || return 1
  archive_component_owned "$zip_path" "da3-small" || return 1
}

da3_bundle_sources_newer() {
  local receipt="$DA3_MPS_BUNDLE/build_info.json"
  [ -f "$receipt" ] || return 0
  [ "$DA3_MPS_BUILD" -nt "$receipt" ] && return 0
  [ -n "$(find "$ROOT/Tools/Da3Sfm" -type f -newer "$receipt" -print -quit)" ]
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
       validate_bundle_build_info "$DA3_MPS_BUNDLE/python/bin/python3" "$DA3_MPS_BUNDLE/build_info.json" "da3_mps" && \
       ! da3_bundle_sources_newer; then
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

validate_installed_core() {
  local root="$1"
  test -x "$root/bin/colmap" || return 1
  "$MSPLAT_VALIDATOR" --packaged "$root" >/dev/null 2>&1 || return 1
  test -f "$root/lib/libomp.dylib" || return 1
  test -f "$root/provenance/colmap.json" || return 1
  test -f "$root/provenance/colmap-support.json" || return 1
  test -f "$root/provenance/ceres.json" || return 1
  test -f "$root/provenance/openimageio.json" || return 1
  test -f "$root/supply-chain/components.json" || return 1

  /usr/bin/codesign --verify --strict "$root/bin/colmap" || return 1
  "$root/bin/colmap" -h >/dev/null 2>&1 || return 1
}

validate_installed_da3_base() {
  local root="$1"
  test -x "$root/da3_mps/bin/easysplat_da3_sfm" || return 1
  test -x "$root/da3_mps/python/bin/python3" || return 1
  test -f "$root/da3_mps/build_info.json" || return 1
  validate_bundle_build_info "$root/da3_mps/python/bin/python3" "$root/da3_mps/build_info.json" "da3_mps" || return 1
  test -f "$root/da3_mps/app/easysplat_da3_sfm/run.py" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/model.safetensors" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/config.json" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/easysplat_model_info.json" || return 1
  test -f "$root/da3_mps/models/DA3-BASE/LICENSE" || return 1
  test -d "$root/da3_mps/licenses" || return 1
  test -f "$root/da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py" || return 1
}

validate_installed_da3_small() {
  local root="$1"
  test -f "$root/da3_mps/models/DA3-SMALL/model.safetensors" || return 1
  test -f "$root/da3_mps/models/DA3-SMALL/config.json" || return 1
  test -f "$root/da3_mps/models/DA3-SMALL/easysplat_model_info.json" || return 1
  test -f "$root/da3_mps/models/DA3-SMALL/LICENSE" || return 1
}

INSTALLED_CORE_OK=0
INSTALLED_FULL_OK=0
if [ -d "$TOOLCHAIN_ROOT" ] && validate_installed_core "$TOOLCHAIN_ROOT"; then
  INSTALLED_CORE_OK=1
  if validate_installed_da3_base "$TOOLCHAIN_ROOT" && \
     validate_installed_da3_small "$TOOLCHAIN_ROOT"; then
    INSTALLED_FULL_OK=1
  fi
fi

if [ "$FAST" -eq 1 ]; then
  if [ "$INSTALLED_CORE_OK" -ne 1 ]; then
    echo "Local toolchain not found or incomplete at: $TOOLCHAIN_ROOT" >&2
    echo "Run ./scripts/run.sh to auto-build/install it, or use --rebuild to force a fresh toolchain." >&2
    exit 1
  fi
  launch_app "installed toolchain at $TOOLCHAIN_ROOT"
  exit 0
fi

if [ "$REBUILD" -eq 0 ] && [ "$INSTALLED_FULL_OK" -eq 1 ]; then
  launch_app "installed toolchain at $TOOLCHAIN_ROOT"
  exit 0
fi

NEED_PACKAGE=0
if [ "$REBUILD" -eq 1 ] || ! core_zip_valid \
  || ! da3_base_zip_valid "$DA3_BASE_ZIP" \
  || ! da3_small_zip_valid "$DA3_SMALL_ZIP"; then
  NEED_PACKAGE=1
elif [ "$INSTALLED_FULL_OK" -eq 0 ] && toolchain_inputs_newer; then
  NEED_PACKAGE=1
fi

if [ "$NEED_PACKAGE" -eq 1 ]; then
  "$ROOT/scripts/toolchain/build_colmap_support.sh"
  "$ROOT/scripts/toolchain/build_ceres.sh"
  "$ROOT/scripts/toolchain/build_openimageio.sh"
  "$ROOT/scripts/toolchain/build_colmap.sh"
  ensure_msplat_bundle
  ensure_da3_mps_bundle
  rm -f "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"
  "$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"
fi

# The packaged archives are the durable artifact; the tree is derived from them.
# A root that has no tree yet gets one, whether packaging just ran or the cached
# archives were reused.
if ! validate_installed_core "$TOOLCHAIN_ROOT"; then
  mkdir -p "$TOOLCHAIN_ROOT"
  for archive in "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"; do
    if [ -f "$archive" ]; then
      /usr/bin/ditto -x -k "$archive" "$TOOLCHAIN_ROOT"
    fi
  done
  for executable in bin/colmap bin/easysplat-train; do
    if [ -f "$TOOLCHAIN_ROOT/$executable" ]; then
      chmod 755 "$TOOLCHAIN_ROOT/$executable"
    fi
  done
fi

if ! validate_installed_core "$TOOLCHAIN_ROOT"; then
  echo "Toolchain tree is incomplete after packaging: $TOOLCHAIN_ROOT" >&2
  echo "Expected bin/colmap, bin/easysplat-train, lib/libomp.dylib, provenance/, supply-chain/." >&2
  exit 1
fi

launch_app "toolchain at $TOOLCHAIN_ROOT"
