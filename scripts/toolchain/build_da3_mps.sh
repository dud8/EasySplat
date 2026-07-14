#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/da3_mps"
INSTALL_DIR="$BUILD_DIR/install/da3_mps"
PYTHON_DIR="$INSTALL_DIR/python"
MODELS_DIR="$INSTALL_DIR/models"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$INSTALL_DIR/bin"
VENDOR_DIR="$INSTALL_DIR/vendor"
DA3_VENDOR="$VENDOR_DIR/depth-anything-3"
REQUIREMENTS_LOCK="$ROOT/Tools/Da3Sfm/requirements.txt"
DA3_RUNTIME_PATCH="$ROOT/Tools/Da3Sfm/patches/da3-api-lazy-export.patch"
DA3_RUNTIME_PATCH_SHA256="885ade24b466ab3dff04169ff47dd3813d64c40ffd0bdb7dd9b779de97a370eb"
COLMAP_LAUNCHER_SOURCE="$ROOT/Tools/Da3Sfm/colmap_launcher.c"
COLMAP_LAUNCHER_SOURCE_SHA256="ab491ab2bf2aac71c7c0e65ae10241dd695aefd7158d967a2244d9ce692f8900"
PIP_INSTALL_REPORT="$INSTALL_DIR/licenses/python-packages-install-report.json"
SUPPLEMENTAL_LICENSE_MANIFEST="$INSTALL_DIR/licenses/python-package-upstream-notices.json"
ANTLR_LICENSE_COMMIT="e4c1a74c66bd5290364ea2b36c97cd724b247357"
ANTLR_LICENSE_URL="https://raw.githubusercontent.com/antlr/antlr4/${ANTLR_LICENSE_COMMIT}/LICENSE.txt"
ANTLR_LICENSE_SHA256="b1b379fcaf3219593a4c433feb1b35c780bed23fafaae440b1ae2771a9521e3a"
ANTLR_LICENSE_CACHE="$BUILD_DIR/licenses/antlr4-python3-runtime-4.9.3-LICENSE.txt"
FAISS_VERSION="1.14.1"
FAISS_SOURCE_COMMIT="5622e93733b64b2e033362dbdfda019b2ab33ef0"
FAISS_LICENSE_URL="https://raw.githubusercontent.com/facebookresearch/faiss/${FAISS_SOURCE_COMMIT}/LICENSE"
FAISS_LICENSE_SHA256="52412d7bc7ce4157ea628bbaacb8829e0a9cb3c58f57f99176126bc8cf2bfc85"
FAISS_LICENSE_CACHE="$BUILD_DIR/licenses/faiss-${FAISS_VERSION}-LICENSE.txt"

ALLOW_UNPINNED_DA3_SOURCE="${EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE:-0}"
if [ -n "${DA3_SOURCE:-}" ] && [ "$ALLOW_UNPINNED_DA3_SOURCE" != "1" ]; then
  echo "DA3_SOURCE requires EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1 and is forbidden in release builds." >&2
  exit 1
fi
for override in DA3_REPO DA3_REF DA3_BASE_REPO DA3_SMALL_REPO DA3_BASE_REVISION DA3_SMALL_REVISION; do
  if [ -n "${!override:-}" ]; then
    echo "$override is not configurable; update and review the pinned source in build_da3_mps.sh." >&2
    exit 1
  fi
done
DA3_SOURCE="${DA3_SOURCE:-$ROOT/ThirdParty/Depth-Anything-3}"
DA3_REPO="https://github.com/ByteDance-Seed/Depth-Anything-3.git"
DA3_REF="41736238f5bced4debf3f2a12375d2466874866d"
DA3_BASE_REPO="depth-anything/DA3-BASE"
DA3_SMALL_REPO="depth-anything/DA3-SMALL"
DA3_BASE_REVISION="f4a6c9b3c95e41c82048423d3493a81ec3fa810e"
DA3_SMALL_REVISION="e08cab65ca0ec38e7826075418411ab90cab4da3"
DA3_SOURCE_COMMIT=""
DA3_SOURCE_DESCRIPTOR=""
DA3_SOURCE_PROVENANCE=""
DA3_SOURCE_REPO_FOR_BUILD_INFO="$DA3_REPO"
DA3_SOURCE_REF_FOR_BUILD_INFO="$DA3_REF"

PYTHON_STANDALONE_TAG="20260127"
PYTHON_STANDALONE_VERSION="3.13.11"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"
PYTHON_STANDALONE_SHA256="718a87bf84d81cb81355488ca37be1f66c2252304be2090721016948de96e7ca"
PYTHON_STANDALONE_FULL_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-pgo+lto-full.tar.zst"
PYTHON_STANDALONE_FULL_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_FULL_ASSET}"
PYTHON_STANDALONE_FULL_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_FULL_ASSET"
PYTHON_STANDALONE_FULL_SHA256="ff7e2bb25f1f29067a0663af42b32980b0da295b948238d5e3fc09d2b27228a6"

if [ "$(uname -m)" != "arm64" ]; then
  echo "da3_mps build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
  exit 1
fi

ensure_repo() {
  local repo="$1"
  local url="$2"
  local ref="$3"

  if ! is_git_checkout "$repo"; then
    git clone "$url" "$repo"
  fi
  pushd "$repo" >/dev/null
  require_clean_git_checkout "$repo"
  git fetch --tags origin "$ref"
  git checkout --detach "$ref"
  require_clean_git_checkout "$repo"
  local current_head
  local expected_head
  current_head="$(git rev-parse HEAD)"
  expected_head="$(git rev-parse "$ref^{commit}")"
  if [ "$current_head" != "$expected_head" ]; then
    echo "DA3 source checkout mismatch in $repo: expected $expected_head, got $current_head" >&2
    exit 1
  fi
  echo "DA3 source pinned at $current_head ($repo)"
  popd >/dev/null
}

is_git_checkout() {
  local repo="$1"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1
}

require_clean_git_checkout() {
  local repo="$1"
  local status_output
  status_output="$(git -C "$repo" status --porcelain --untracked-files=all --ignored=matching --ignore-submodules=none)"
  if [ -n "$status_output" ]; then
    echo "DA3 source checkout is dirty at $repo. Refusing to package local edits or untracked files into the signed toolchain." >&2
    echo "$status_output" >&2
    exit 1
  fi
}

resolve_da3_source() {
  if is_git_checkout "$DA3_SOURCE"; then
    ensure_repo "$DA3_SOURCE" "$DA3_REPO" "$DA3_REF"
    DA3_SOURCE_COMMIT="$(git -C "$DA3_SOURCE" rev-parse HEAD)"
    DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"
    DA3_SOURCE_PROVENANCE="pinned-git"
    return 0
  fi

  if [ -d "$DA3_SOURCE/src/depth_anything_3" ]; then
    if [ "$ALLOW_UNPINNED_DA3_SOURCE" != "1" ]; then
      echo "DA3 source at $DA3_SOURCE has no git metadata." >&2
      echo "Release/toolchain builds require pinned DA3 git provenance. Set EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1 only for local development snapshots." >&2
      exit 1
    fi
    DA3_SOURCE_COMMIT="unverified-local-snapshot"
    DA3_SOURCE_DESCRIPTOR="unverified-local-snapshot"
    DA3_SOURCE_PROVENANCE="unverified-local-snapshot"
    DA3_SOURCE_REPO_FOR_BUILD_INFO="unverified-local-snapshot"
    DA3_SOURCE_REF_FOR_BUILD_INFO="unverified-local-snapshot"
    echo "Using unpinned local DA3 source because EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1." >&2
    echo "Build info will record unverified-local-snapshot and will not include the local source path." >&2
    return 0
  fi

  DA3_SOURCE="$BUILD_DIR/depth-anything-3-upstream"
  ensure_repo "$DA3_SOURCE" "$DA3_REPO" "$DA3_REF"
  DA3_SOURCE_COMMIT="$(git -C "$DA3_SOURCE" rev-parse HEAD)"
  DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"
  DA3_SOURCE_PROVENANCE="pinned-git"
}

download_verified() {
  local url="$1"
  local dest="$2"
  local expected_sha256="$3"
  if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | awk '{print $1}')" = "$expected_sha256" ]; then
    return
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.tmp.$$"
  rm -f "$dest" "$tmp"
  curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"
  if [ "$(shasum -a 256 "$tmp" | awk '{print $1}')" != "$expected_sha256" ]; then
    rm -f "$tmp"
    echo "Checksum mismatch for $url" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
}

install_supplemental_python_licenses() {
  local -a antlr_dist_info=(
    "$PYTHON_DIR"/lib/python*/site-packages/antlr4_python3_runtime-4.9.3.dist-info
  )
  if [ "${#antlr_dist_info[@]}" -ne 1 ] || [ ! -d "${antlr_dist_info[0]}" ]; then
    echo "Expected exactly one antlr4-python3-runtime 4.9.3 distribution." >&2
    exit 1
  fi
  local -a pycolmap_dist_info=(
    "$PYTHON_DIR"/lib/python*/site-packages/pycolmap-4.1.0.dist-info
  )
  if [ "${#pycolmap_dist_info[@]}" -ne 1 ] || [ ! -d "${pycolmap_dist_info[0]}" ]; then
    echo "Expected exactly one PyCOLMAP 4.1.0 distribution." >&2
    exit 1
  fi

  download_verified \
    "$ANTLR_LICENSE_URL" \
    "$ANTLR_LICENSE_CACHE" \
    "$ANTLR_LICENSE_SHA256"
  download_verified \
    "$FAISS_LICENSE_URL" \
    "$FAISS_LICENSE_CACHE" \
    "$FAISS_LICENSE_SHA256"

  local antlr_license="${antlr_dist_info[0]}/licenses/UPSTREAM_LICENSE.txt"
  mkdir -p "$(dirname "$antlr_license")"
  install -m 0644 "$ANTLR_LICENSE_CACHE" "$antlr_license"
  local faiss_license="${pycolmap_dist_info[0]}/licenses/FAISS-LICENSE"
  mkdir -p "$(dirname "$faiss_license")"
  install -m 0644 "$FAISS_LICENSE_CACHE" "$faiss_license"

  "$PYTHON_DIR/bin/python3" - \
    "$INSTALL_DIR" \
    "$SUPPLEMENTAL_LICENSE_MANIFEST" \
    "$antlr_license" \
    "$faiss_license" <<PY
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
manifest = Path(sys.argv[2])

def relative(path_text):
    path = Path(path_text).resolve(strict=True).relative_to(root).as_posix()
    return f"da3_mps/{path}"

payload = {
    "schemaVersion": 1,
    "notices": [
        {
            "package": "antlr4-python3-runtime",
            "version": "4.9.3",
            "license": "BSD-3-Clause",
            "source": "https://github.com/antlr/antlr4",
            "sourceCommit": "${ANTLR_LICENSE_COMMIT}",
            "artifact": "${ANTLR_LICENSE_URL}",
            "artifactSha256": "${ANTLR_LICENSE_SHA256}",
            "distInfo": "antlr4_python3_runtime-4.9.3.dist-info",
            "filename": "UPSTREAM_LICENSE.txt",
            "installedPath": relative(sys.argv[3]),
        },
        {
            "package": "faiss",
            "version": "${FAISS_VERSION}",
            "license": "MIT",
            "source": "https://github.com/facebookresearch/faiss",
            "sourceCommit": "${FAISS_SOURCE_COMMIT}",
            "artifact": "${FAISS_LICENSE_URL}",
            "artifactSha256": "${FAISS_LICENSE_SHA256}",
            "distInfo": "pycolmap-4.1.0.dist-info",
            "filename": "FAISS-LICENSE",
            "installedPath": relative(sys.argv[4]),
        },
    ],
}
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

ensure_python() {
  download_verified "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL" "$PYTHON_STANDALONE_SHA256"
  mkdir -p "$INSTALL_DIR"
  /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"

  echo "da3_mps python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
}

reset_install_dir() {
  case "$INSTALL_DIR" in
    "$BUILD_DIR/install/da3_mps") ;;
    *)
      echo "Refusing to clean unsafe DA3 install directory: $INSTALL_DIR" >&2
      exit 1
      ;;
  esac
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" "$MODELS_DIR" "$BIN_DIR"
}

pip_install() {
  PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user "$@"
}

remove_build_only_python_tools() {
  local site_packages="$PYTHON_DIR/lib/python3.13/site-packages"
  rm -f "$PYTHON_DIR/bin/pip" "$PYTHON_DIR/bin/pip3" "$PYTHON_DIR/bin/pip3.13"
  rm -rf \
    "$PYTHON_DIR/lib/python3.13/ensurepip" \
    "$site_packages/pip" \
    "$site_packages"/pip-*.dist-info

  if [ -e "$PYTHON_DIR/bin/pip" ] \
    || [ -e "$PYTHON_DIR/bin/pip3" ] \
    || [ -e "$PYTHON_DIR/bin/pip3.13" ] \
    || [ -e "$PYTHON_DIR/lib/python3.13/ensurepip" ] \
    || [ -e "$site_packages/pip" ] \
    || find "$site_packages" -maxdepth 1 -type d -name 'pip-*.dist-info' -print -quit | grep -F . >/dev/null; then
    echo "Build-only pip files survived runtime pruning." >&2
    exit 1
  fi
}

require_arm64_python() {
  local arch
  arch="$("$PYTHON_DIR/bin/python3" - <<'PY'
import platform
print(platform.machine())
PY
)"
  if [ "$arch" != "arm64" ]; then
    echo "da3_mps python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

verify_runtime_patch() {
  if [ ! -f "$DA3_RUNTIME_PATCH" ] || [ -L "$DA3_RUNTIME_PATCH" ]; then
    echo "DA3 runtime patch is missing or is not a regular file: $DA3_RUNTIME_PATCH" >&2
    exit 1
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$DA3_RUNTIME_PATCH" | awk '{print $1}')"
  if [ "$actual_sha256" != "$DA3_RUNTIME_PATCH_SHA256" ]; then
    echo "DA3 runtime patch checksum mismatch: expected $DA3_RUNTIME_PATCH_SHA256, got $actual_sha256" >&2
    exit 1
  fi
}

build_colmap_launcher() {
  if [ ! -f "$COLMAP_LAUNCHER_SOURCE" ] || [ -L "$COLMAP_LAUNCHER_SOURCE" ]; then
    echo "COLMAP launcher source is missing or is not a regular file: $COLMAP_LAUNCHER_SOURCE" >&2
    exit 1
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$COLMAP_LAUNCHER_SOURCE" | awk '{print $1}')"
  if [ "$actual_sha256" != "$COLMAP_LAUNCHER_SOURCE_SHA256" ]; then
    echo "COLMAP launcher source checksum mismatch: expected $COLMAP_LAUNCHER_SOURCE_SHA256, got $actual_sha256" >&2
    exit 1
  fi
  xcrun clang \
    -arch arm64 \
    -mmacosx-version-min=15.0 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    "$COLMAP_LAUNCHER_SOURCE" \
    -o "$BIN_DIR/easysplat_colmap"
  chmod +x "$BIN_DIR/easysplat_colmap"
  /usr/bin/file -b "$BIN_DIR/easysplat_colmap" | \
    grep -q 'Mach-O 64-bit executable arm64' || {
      echo "COLMAP launcher is not an arm64 Mach-O executable." >&2
      exit 1
    }
}

verify_torch_mps() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    sys.stderr.write(f"da3_mps: failed to import torch: {exc}\n")
    raise SystemExit(1)
print(f"torch={torch.__version__}")
print(f"mps.is_built={torch.backends.mps.is_built()}")
print(f"mps.is_available={torch.backends.mps.is_available()}")
if not torch.backends.mps.is_built():
    sys.stderr.write("da3_mps: torch was built without MPS support.\n")
    raise SystemExit(1)
PY
}

download_model() {
  local repo_id="$1"
  local local_name="$2"
  local revision="$3"
  local target="$MODELS_DIR/$local_name"
  rm -rf "$target"
  mkdir -p "$target"
  echo "Downloading ${repo_id}@${revision} into $target"
  HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
import json
from pathlib import Path

from huggingface_hub import model_info, snapshot_download

info = model_info(repo_id="${repo_id}", revision="${revision}")
license_value = ""
card_data = getattr(info, "cardData", None)
if isinstance(card_data, dict):
    license_value = str(card_data.get("license") or "").lower()
elif card_data is not None and getattr(card_data, "license", None):
    license_value = str(card_data.license).lower()
tags = {str(tag).lower() for tag in (getattr(info, "tags", None) or [])}
if license_value != "apache-2.0" and "license:apache-2.0" not in tags:
    raise SystemExit(f"${repo_id}@${revision} is not Apache-2.0 (license={license_value!r}, tags={sorted(tags)!r})")

snapshot_download(
    repo_id="${repo_id}",
    revision="${revision}",
    local_dir="${target}",
    allow_patterns=["config.json", "model.safetensors", "*.json", "*.safetensors"],
)
Path("${target}/easysplat_model_info.json").write_text(
    json.dumps(
        {
            "repo_id": "${repo_id}",
            "requested_revision": "${revision}",
            "resolved_sha": info.sha,
            "license": license_value or "apache-2.0",
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
  install -m 0644 "$DA3_SOURCE/LICENSE" "$target/LICENSE"
  test -f "$target/config.json"
  test -f "$target/model.safetensors"
  test -f "$target/easysplat_model_info.json"
  test -f "$target/LICENSE"
}

stage_da3_app() {
  local source_root="$ROOT/Tools/Da3Sfm/easysplat_da3_sfm"
  if [ ! -d "$source_root" ]; then
    echo "DA3 app source missing at $source_root" >&2
    exit 1
  fi
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  cp -R "$source_root" "$APP_DIR/"
  find "$APP_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +
  find "$APP_DIR" -type f -name "*.pyc" -delete
}

mkdir -p "$BUILD_DIR"

resolve_da3_source
verify_runtime_patch
reset_install_dir
ensure_python
require_arm64_python

# OmegaConf 2.3.0 requires antlr4-python3-runtime 4.9.x, which has no wheel.
# Every artifact is hash-locked; all other packages must come from wheels.
mkdir -p "$(dirname "$PIP_INSTALL_REPORT")"
install -m 0644 "$REQUIREMENTS_LOCK" "$INSTALL_DIR/licenses/python-packages-requirements.txt"
pip_install \
  --require-hashes \
  --only-binary=:all: \
  --no-binary=antlr4-python3-runtime \
  --force-reinstall \
  --no-cache-dir \
  --report "$PIP_INSTALL_REPORT" \
  -r "$REQUIREMENTS_LOCK"
if find "$PYTHON_DIR" -iname '*opencv*' -print -quit | grep -F . >/dev/null; then
  echo "opencv-python-headless survived the clean install; refusing the release runtime." >&2
  exit 1
fi
install_supplemental_python_licenses
remove_build_only_python_tools
verify_torch_mps

rm -rf "$DA3_VENDOR"
mkdir -p "$DA3_VENDOR/src/depth_anything_3"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$DA3_SOURCE/src/depth_anything_3/" "$DA3_VENDOR/src/depth_anything_3/"
else
  cp -R "$DA3_SOURCE/src/depth_anything_3/." "$DA3_VENDOR/src/depth_anything_3/"
fi
install -m 0644 "$DA3_SOURCE/LICENSE" "$DA3_VENDOR/LICENSE"
test ! -e "$DA3_VENDOR/da3_streaming"
/usr/bin/patch --dry-run -s -p1 -d "$DA3_VENDOR" < "$DA3_RUNTIME_PATCH"
/usr/bin/patch -s -p1 -d "$DA3_VENDOR" < "$DA3_RUNTIME_PATCH"

if ! command -v unzstd >/dev/null 2>&1; then
  echo "unzstd is required to extract python-build-standalone license metadata." >&2
  exit 1
fi
download_verified \
  "$PYTHON_STANDALONE_FULL_URL" \
  "$PYTHON_STANDALONE_FULL_TARBALL" \
  "$PYTHON_STANDALONE_FULL_SHA256"
rm -rf "$INSTALL_DIR/licenses/python-build-standalone"
mkdir -p "$INSTALL_DIR/licenses/python-build-standalone"
/usr/bin/tar --use-compress-program=unzstd \
  -xf "$PYTHON_STANDALONE_FULL_TARBALL" \
  -C "$INSTALL_DIR/licenses/python-build-standalone" \
  --strip-components=1 \
  python/PYTHON.json python/licenses
test -s "$INSTALL_DIR/licenses/python-build-standalone/PYTHON.json"
test -d "$INSTALL_DIR/licenses/python-build-standalone/licenses"

if [ ! -f "$DA3_VENDOR/src/depth_anything_3/api.py" ]; then
  echo "DA3 vendor tree missing expected module: src/depth_anything_3/api.py" >&2
  exit 1
fi

stage_da3_app
build_colmap_launcher
download_model "$DA3_BASE_REPO" "DA3-BASE" "$DA3_BASE_REVISION"
download_model "$DA3_SMALL_REPO" "DA3-SMALL" "$DA3_SMALL_REVISION"

PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
import hashlib
import json
import platform
from pathlib import Path
import torch
import torchvision
import huggingface_hub

def packaged_model_info(name):
    path = Path("${MODELS_DIR}") / name / "easysplat_model_info.json"
    return json.loads(path.read_text(encoding="utf-8"))

base_info = packaged_model_info("DA3-BASE")
small_info = packaged_model_info("DA3-SMALL")
requirements_lock = Path("${REQUIREMENTS_LOCK}")
requirements_lock_sha256 = hashlib.sha256(requirements_lock.read_bytes()).hexdigest()
runtime_patch = Path("${DA3_RUNTIME_PATCH}")
runtime_patch_sha256 = hashlib.sha256(runtime_patch.read_bytes()).hexdigest()
colmap_launcher_source = Path("${COLMAP_LAUNCHER_SOURCE}")
colmap_launcher_source_sha256 = hashlib.sha256(colmap_launcher_source.read_bytes()).hexdigest()
colmap_launcher = Path("${BIN_DIR}/easysplat_colmap")
colmap_launcher_sha256 = hashlib.sha256(colmap_launcher.read_bytes()).hexdigest()
colmap_bridge_source = Path("${APP_DIR}/easysplat_da3_sfm/colmap_cli.py")
colmap_bridge_source_sha256 = hashlib.sha256(colmap_bridge_source.read_bytes()).hexdigest()
supplemental_license_manifest = Path("${SUPPLEMENTAL_LICENSE_MANIFEST}")
supplemental_license_manifest_sha256 = hashlib.sha256(
    supplemental_license_manifest.read_bytes()
).hexdigest()

Path("${INSTALL_DIR}").mkdir(parents=True, exist_ok=True)
Path("${INSTALL_DIR}/build_info.json").write_text(
    json.dumps(
        {
            "toolchain_name": "da3_mps",
            "source_repo": "${DA3_SOURCE_REPO_FOR_BUILD_INFO}",
            "source_ref": "${DA3_SOURCE_REF_FOR_BUILD_INFO}",
            "source_commit": "${DA3_SOURCE_COMMIT}",
            "source_path": "${DA3_SOURCE_DESCRIPTOR}",
            "source_provenance": "${DA3_SOURCE_PROVENANCE}",
            "expected_upstream_repo": "${DA3_REPO}",
            "expected_upstream_ref": "${DA3_REF}",
            "base_checkpoint_repo": "${DA3_BASE_REPO}",
            "base_checkpoint_revision": "${DA3_BASE_REVISION}",
            "base_checkpoint_commit": base_info["resolved_sha"],
            "small_checkpoint_repo": "${DA3_SMALL_REPO}",
            "small_checkpoint_revision": "${DA3_SMALL_REVISION}",
            "small_checkpoint_commit": small_info["resolved_sha"],
            "python_version": platform.python_version(),
            "python_standalone_url": "${PYTHON_STANDALONE_URL}",
            "python_standalone_sha256": "${PYTHON_STANDALONE_SHA256}",
            "python_standalone_license_archive_url": "${PYTHON_STANDALONE_FULL_URL}",
            "python_standalone_license_archive_sha256": "${PYTHON_STANDALONE_FULL_SHA256}",
            "requirements_lock": "Tools/Da3Sfm/requirements.txt",
            "requirements_lock_sha256": requirements_lock_sha256,
            "runtime_patch": "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
            "runtime_patch_sha256": runtime_patch_sha256,
            "colmap_launcher_source": "Tools/Da3Sfm/colmap_launcher.c",
            "colmap_launcher_source_sha256": colmap_launcher_source_sha256,
            "colmap_launcher_sha256": colmap_launcher_sha256,
            "colmap_bridge_source": "Tools/Da3Sfm/easysplat_da3_sfm/colmap_cli.py",
            "colmap_bridge_source_sha256": colmap_bridge_source_sha256,
            "supplemental_license_manifest": "licenses/python-package-upstream-notices.json",
            "supplemental_license_manifest_sha256": supplemental_license_manifest_sha256,
            "pip_install_report": "licenses/python-packages-install-report.json",
            "torch_version": torch.__version__,
            "torchvision_version": torchvision.__version__,
            "huggingface_hub_version": huggingface_hub.__version__,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

cat >"$BIN_DIR/easysplat_da3_sfm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
APP="$ROOT/app"
VENDOR_DA3="$ROOT/vendor/depth-anything-3"
unset PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP PYTHONINSPECT
export PYTHONNOUSERSITE=1
export PYTHONSAFEPATH=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$APP:$VENDOR_DA3/src"
export EASYSPLAT_DA3_MODELS_DIR="$ROOT/models"
CACHE_ROOT="${EASYSPLAT_DA3_CACHE_DIR:-${TMPDIR:-/tmp}/EasySplat/DA3Cache}"
export TORCH_HOME="$CACHE_ROOT/torch"
export HF_HOME="$CACHE_ROOT/huggingface"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export KMP_DUPLICATE_LIB_OK=TRUE
export TOKENIZERS_PARALLELISM=false
export PYTORCH_ENABLE_MPS_FALLBACK=1
exec "$PY" -m easysplat_da3_sfm.run "$@"
SCRIPT
chmod +x "$BIN_DIR/easysplat_da3_sfm"

KMP_DUPLICATE_LIB_OK=TRUE PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
  PYTHONPATH="$APP_DIR:$DA3_VENDOR/src" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import pycolmap
    import depth_anything_3.api  # noqa: F401
    import easysplat_da3_sfm  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"da3_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
if pycolmap.__version__ != "4.1.0" or not callable(
    getattr(pycolmap, "match_image_pairs", None)
):
    raise SystemExit("da3_mps requires the reviewed PyCOLMAP 4.1.0 pair matcher")
PY

"$BIN_DIR/easysplat_da3_sfm" --help >/dev/null
"$BIN_DIR/easysplat_colmap" -h >/dev/null

echo "da3_mps ready at $INSTALL_DIR"
