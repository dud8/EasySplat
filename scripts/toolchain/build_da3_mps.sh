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

DA3_SOURCE="${DA3_SOURCE:-$ROOT/ThirdParty/Depth-Anything-3}"
DA3_REPO="${DA3_REPO:-https://github.com/ByteDance-Seed/Depth-Anything-3.git}"
DA3_REF="${DA3_REF:-41736238f5bced4debf3f2a12375d2466874866d}"
DA3_BASE_REPO="${DA3_BASE_REPO:-depth-anything/DA3-BASE}"
DA3_SMALL_REPO="${DA3_SMALL_REPO:-depth-anything/DA3-SMALL}"
DA3_METRIC_LARGE_REPO="${DA3_METRIC_LARGE_REPO:-depth-anything/DA3METRIC-LARGE}"
DA3_BASE_REVISION="${DA3_BASE_REVISION:-f4a6c9b3c95e41c82048423d3493a81ec3fa810e}"
DA3_SMALL_REVISION="${DA3_SMALL_REVISION:-e08cab65ca0ec38e7826075418411ab90cab4da3}"
DA3_METRIC_LARGE_REVISION="${DA3_METRIC_LARGE_REVISION:-4010e39f3634a45bc60553321fb49fb760bd594e}"
DA3_INCLUDE_METRIC_LARGE="${EASYSPLAT_DA3_INCLUDE_METRIC_LARGE:-0}"
ALLOW_UNPINNED_DA3_SOURCE="${EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE:-0}"
DA3_SOURCE_COMMIT=""
DA3_SOURCE_DESCRIPTOR=""
DA3_SOURCE_PROVENANCE=""
DA3_SOURCE_REPO_FOR_BUILD_INFO="$DA3_REPO"
DA3_SOURCE_REF_FOR_BUILD_INFO="$DA3_REF"

PYTHON_STANDALONE_TAG="${EASYSPLAT_PYTHON_STANDALONE_TAG:-20260127}"
PYTHON_STANDALONE_VERSION="${EASYSPLAT_PYTHON_VERSION:-3.13.11}"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"

if [ "$(uname -m)" != "arm64" ]; then
  echo "da3_mps build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
  exit 1
fi

ensure_repo() {
  local repo="$1"
  local url="$2"
  local ref="$3"

  if ! is_git_checkout "$repo"; then
    git clone --recursive "$url" "$repo"
  fi
  pushd "$repo" >/dev/null
  require_clean_git_checkout "$repo"
  git fetch --tags origin "$ref"
  git checkout --detach "$ref"
  git submodule sync --recursive
  git submodule update --init --recursive
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

download_file() {
  local url="$1"
  local dest="$2"
  if [ -f "$dest" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.tmp.$$"
  rm -f "$tmp"
  curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"
  mv "$tmp" "$dest"
}

ensure_python() {
  if [ -f "$PYTHON_DIR/pyvenv.cfg" ]; then
    rm -rf "$PYTHON_DIR"
  elif [ -L "$PYTHON_DIR/bin/python3" ]; then
    local target
    target="$(readlink "$PYTHON_DIR/bin/python3" || true)"
    if [[ "$target" == /* ]]; then
      rm -rf "$PYTHON_DIR"
    fi
  fi

  if [ -x "$PYTHON_DIR/bin/python3" ]; then
    local current_python_version
    current_python_version="$("$PYTHON_DIR/bin/python3" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
PY
)"
    if [ "$current_python_version" != "$PYTHON_STANDALONE_VERSION" ]; then
      echo "da3_mps python version mismatch (found $current_python_version, expected $PYTHON_STANDALONE_VERSION); rebuilding runtime." >&2
      rm -rf "$PYTHON_DIR"
    fi
  fi

  if [ ! -x "$PYTHON_DIR/bin/python3" ]; then
    download_file "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL"
    mkdir -p "$INSTALL_DIR"
    /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"
  fi

  echo "da3_mps python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user --upgrade pip setuptools wheel
}

pip_install() {
  PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user "$@"
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
  test -f "$target/config.json"
  test -f "$target/model.safetensors"
  test -f "$target/easysplat_model_info.json"
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

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$MODELS_DIR" "$BIN_DIR"

resolve_da3_source
ensure_python
require_arm64_python

pip_install -r "$ROOT/Tools/Da3Sfm/requirements.txt"
verify_torch_mps

rm -rf "$DA3_VENDOR"
mkdir -p "$DA3_VENDOR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude ".git" \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$DA3_SOURCE/" "$DA3_VENDOR/"
else
  cp -R "$DA3_SOURCE/." "$DA3_VENDOR/"
  find "$DA3_VENDOR" -type d -name ".git" -prune -exec rm -rf {} +
fi

if [ ! -f "$DA3_VENDOR/src/depth_anything_3/api.py" ]; then
  echo "DA3 vendor tree missing expected module: src/depth_anything_3/api.py" >&2
  exit 1
fi

stage_da3_app
download_model "$DA3_BASE_REPO" "DA3-BASE" "$DA3_BASE_REVISION"
download_model "$DA3_SMALL_REPO" "DA3-SMALL" "$DA3_SMALL_REVISION"
if [ "$DA3_INCLUDE_METRIC_LARGE" = "1" ]; then
  download_model "$DA3_METRIC_LARGE_REPO" "DA3METRIC-LARGE" "$DA3_METRIC_LARGE_REVISION"
fi

PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
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
metric_info = packaged_model_info("DA3METRIC-LARGE") if "${DA3_INCLUDE_METRIC_LARGE}" == "1" else None

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
            "metric_large_checkpoint_repo": "${DA3_METRIC_LARGE_REPO}" if "${DA3_INCLUDE_METRIC_LARGE}" == "1" else None,
            "metric_large_checkpoint_revision": "${DA3_METRIC_LARGE_REVISION}" if "${DA3_INCLUDE_METRIC_LARGE}" == "1" else None,
            "metric_large_checkpoint_commit": metric_info["resolved_sha"] if metric_info is not None else None,
            "python_version": platform.python_version(),
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
export PYTHONNOUSERSITE=1
export PYTHONPATH="$APP:$VENDOR_DA3/src${PYTHONPATH:+:$PYTHONPATH}"
export EASYSPLAT_DA3_MODELS_DIR="$ROOT/models"
export TORCH_HOME="$ROOT/models"
export HF_HOME="$ROOT/models/huggingface"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export KMP_DUPLICATE_LIB_OK=TRUE
export TOKENIZERS_PARALLELISM=false
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
exec "$PY" -m easysplat_da3_sfm.run "$@"
SCRIPT
chmod +x "$BIN_DIR/easysplat_da3_sfm"

KMP_DUPLICATE_LIB_OK=TRUE PYTHONNOUSERSITE=1 PYTHONPATH="$APP_DIR:$DA3_VENDOR/src" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import pycolmap  # noqa: F401
    import depth_anything_3.api  # noqa: F401
    import easysplat_da3_sfm  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"da3_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

"$BIN_DIR/easysplat_da3_sfm" --help >/dev/null

echo "da3_mps ready at $INSTALL_DIR"
