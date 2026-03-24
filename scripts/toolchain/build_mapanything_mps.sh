#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/mapanything_mps"
INSTALL_DIR="$BUILD_DIR/install/mapanything_mps"
PYTHON_DIR="$INSTALL_DIR/python"
MODELS_DIR="$INSTALL_DIR/models"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$INSTALL_DIR/bin"
VENDOR_DIR="$INSTALL_DIR/vendor"
MAPANYTHING_VENDOR="$VENDOR_DIR/mapanything"

MAPANYTHING_SOURCE="${MAPANYTHING_SOURCE:-$ROOT/ThirdParty/MapAnything}"
MAPANYTHING_REPO="${MAPANYTHING_REPO:-https://github.com/facebookresearch/map-anything.git}"
MAPANYTHING_REF="${MAPANYTHING_REF:-f065d13383ae84a7f80f0e0104a4d12afc7c7c82}"
MAPANYTHING_CHECKPOINT_REPO="${MAPANYTHING_CHECKPOINT_REPO:-facebook/map-anything-apache}"
MAPANYTHING_CHECKPOINT_REVISION="${MAPANYTHING_CHECKPOINT_REVISION:-00f9c245bbcb60522d1ed7f9e9d88462c6e3f38a}"
MAPANYTHING_CHECKPOINT_DIR="$MODELS_DIR/map-anything-apache"
DINOV2_WEIGHTS_URL="${DINOV2_WEIGHTS_URL:-https://dl.fbaipublicfiles.com/dinov2/dinov2_vitg14/dinov2_vitg14_pretrain.pth}"
DINOV2_WEIGHTS_FALLBACK_URL="${DINOV2_WEIGHTS_FALLBACK_URL:-https://dl.fbaipublicfiles.com/dinov2/dinov2_vitg14_pretrain.pth}"
DINOV2_WEIGHTS_FILE="$MODELS_DIR/dinov2/dinov2_vitg14_pretrain.pth"

PYTHON_STANDALONE_TAG="${EASYSPLAT_PYTHON_STANDALONE_TAG:-20260127}"
PYTHON_STANDALONE_VERSION="${EASYSPLAT_PYTHON_VERSION:-3.13.11}"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"

if [ "$(uname -m)" != "arm64" ]; then
  echo "mapanything_mps build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
  exit 1
fi

function ensure_repo() {
  local repo="$1"
  local url="$2"
  local ref="$3"

  if [ ! -d "$repo/.git" ]; then
    git clone --recursive "$url" "$repo"
  fi
  pushd "$repo" >/dev/null
  git fetch --tags origin "$ref"
  git checkout --detach "$ref"
  git submodule sync --recursive
  git submodule update --init --recursive
  local current_head
  local expected_head
  current_head="$(git rev-parse HEAD)"
  expected_head="$(git rev-parse "$ref^{commit}")"
  if [ "$current_head" != "$expected_head" ]; then
    echo "MapAnything source checkout mismatch in $repo: expected $expected_head, got $current_head" >&2
    exit 1
  fi
  echo "MapAnything source pinned at $current_head ($repo)"
  popd >/dev/null
}

function download_file() {
  local url="$1"
  local dest="$2"
  if [ -f "$dest" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp="$dest.tmp.$$"
  rm -f "$tmp"
  if curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"; then
    mv "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

function download_file_with_fallback() {
  local dest="$1"
  shift
  if [ -f "$dest" ]; then
    printf '%s\n' "$1"
    return 0
  fi

  local url
  for url in "$@"; do
    if [ -z "$url" ]; then
      continue
    fi
    echo "Downloading $(basename "$dest") from $url" >&2
    if download_file "$url" "$dest"; then
      printf '%s\n' "$url"
      return 0
    fi
    echo "Download failed from $url; trying next source if available." >&2
  done
  return 1
}

function ensure_python() {
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
      echo "mapanything_mps python version mismatch (found $current_python_version, expected $PYTHON_STANDALONE_VERSION); rebuilding runtime." >&2
      rm -rf "$PYTHON_DIR"
    fi
  fi

  if [ ! -x "$PYTHON_DIR/bin/python3" ]; then
    download_file "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL"
    mkdir -p "$INSTALL_DIR"
    /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"
  fi

  echo "mapanything_mps python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user --upgrade pip setuptools wheel
}

function pip_install() {
  PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user "$@"
}

function require_arm64_python() {
  local arch
  arch="$("$PYTHON_DIR/bin/python3" - <<'PY'
import platform
print(platform.machine())
PY
)"
  if [ "$arch" != "arm64" ]; then
    echo "mapanything_mps python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

function verify_torch_mps() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    sys.stderr.write(f"mapanything_mps: failed to import torch: {exc}\n")
    raise SystemExit(1)
print(f"torch={torch.__version__}")
print(f"mps.is_built={torch.backends.mps.is_built()}")
print(f"mps.is_available={torch.backends.mps.is_available()}")
if not torch.backends.mps.is_built():
    sys.stderr.write("mapanything_mps: torch was built without MPS support.\n")
    raise SystemExit(1)
PY
}

function download_checkpoint() {
  mkdir -p "$MAPANYTHING_CHECKPOINT_DIR"
  echo "Downloading ${MAPANYTHING_CHECKPOINT_REPO}@${MAPANYTHING_CHECKPOINT_REVISION} into $MAPANYTHING_CHECKPOINT_DIR"
  HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="${MAPANYTHING_CHECKPOINT_REPO}",
    revision="${MAPANYTHING_CHECKPOINT_REVISION}",
    local_dir="${MAPANYTHING_CHECKPOINT_DIR}",
    allow_patterns=["config.json", "model.safetensors"],
)
PY
  test -f "$MAPANYTHING_CHECKPOINT_DIR/config.json"
  test -f "$MAPANYTHING_CHECKPOINT_DIR/model.safetensors"
}

function stage_mapanything_app() {
  local source_root="$ROOT/Tools/MapAnythingSfm/easysplat_mapanything_sfm"
  if [ ! -d "$source_root" ]; then
    echo "MapAnything app source missing at $source_root" >&2
    exit 1
  fi

  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  cp -R "$source_root" "$APP_DIR/"
  find "$APP_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +
  find "$APP_DIR" -type f -name "*.pyc" -delete
}

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$MODELS_DIR" "$BIN_DIR"

ensure_python
require_arm64_python

MAPANYTHING_SOURCE_COMMIT="vendored-snapshot"
if [ -d "$MAPANYTHING_SOURCE/.git" ]; then
  ensure_repo "$MAPANYTHING_SOURCE" "$MAPANYTHING_REPO" "$MAPANYTHING_REF"
  MAPANYTHING_SOURCE_COMMIT="$(git -C "$MAPANYTHING_SOURCE" rev-parse HEAD)"
elif [ -d "$MAPANYTHING_SOURCE/mapanything" ]; then
  echo "Using pre-vendored MapAnything source from $MAPANYTHING_SOURCE (no git metadata to pin)." >&2
else
  MAPANYTHING_SOURCE="$BUILD_DIR/mapanything-upstream"
  ensure_repo "$MAPANYTHING_SOURCE" "$MAPANYTHING_REPO" "$MAPANYTHING_REF"
  MAPANYTHING_SOURCE_COMMIT="$(git -C "$MAPANYTHING_SOURCE" rev-parse HEAD)"
fi

pip_install -r "$ROOT/Tools/MapAnythingSfm/requirements.txt"
verify_torch_mps

if command -v rsync >/dev/null 2>&1; then
  rm -rf "$MAPANYTHING_VENDOR"
  mkdir -p "$MAPANYTHING_VENDOR"
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$MAPANYTHING_SOURCE/mapanything/" "$MAPANYTHING_VENDOR/mapanything/"
  if [ -f "$MAPANYTHING_SOURCE/LICENSE" ]; then
    cp -f "$MAPANYTHING_SOURCE/LICENSE" "$MAPANYTHING_VENDOR/LICENSE"
  elif [ -f "$MAPANYTHING_SOURCE/LICENSE.txt" ]; then
    cp -f "$MAPANYTHING_SOURCE/LICENSE.txt" "$MAPANYTHING_VENDOR/LICENSE.txt"
  fi
else
  rm -rf "$MAPANYTHING_VENDOR"
  mkdir -p "$MAPANYTHING_VENDOR"
  cp -R "$MAPANYTHING_SOURCE/mapanything" "$MAPANYTHING_VENDOR/"
fi

if [ ! -f "$MAPANYTHING_VENDOR/mapanything/models/mapanything/model.py" ]; then
  echo "MapAnything vendor tree missing expected module: mapanything/models/mapanything/model.py" >&2
  exit 1
fi

stage_mapanything_app
if [ ! -f "$APP_DIR/easysplat_mapanything_sfm/run.py" ]; then
  echo "MapAnything app bundle missing easysplat_mapanything_sfm/run.py" >&2
  exit 1
fi

download_checkpoint
DINOV2_WEIGHTS_URL_USED="$(
  download_file_with_fallback \
    "$DINOV2_WEIGHTS_FILE" \
    "$DINOV2_WEIGHTS_URL" \
    "$DINOV2_WEIGHTS_FALLBACK_URL"
)"
if [ ! -f "$DINOV2_WEIGHTS_FILE" ]; then
  echo "Failed to download DINOv2 weights to $DINOV2_WEIGHTS_FILE" >&2
  exit 1
fi

PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
import json
import platform
from pathlib import Path
import torch
import torchvision
import huggingface_hub

Path("${INSTALL_DIR}").mkdir(parents=True, exist_ok=True)
Path("${INSTALL_DIR}/build_info.json").write_text(
    json.dumps(
        {
            "toolchain_name": "mapanything_mps",
            "source_repo": "${MAPANYTHING_REPO}",
            "source_ref": "${MAPANYTHING_REF}",
            "source_commit": "${MAPANYTHING_SOURCE_COMMIT}",
            "source_path": "${MAPANYTHING_SOURCE}",
            "checkpoint_repo": "${MAPANYTHING_CHECKPOINT_REPO}",
            "checkpoint_revision": "${MAPANYTHING_CHECKPOINT_REVISION}",
            "dinov2_weights_url": "${DINOV2_WEIGHTS_URL_USED}",
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

cat >"$BIN_DIR/easysplat_mapanything_sfm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
APP="$ROOT/app"
VENDOR_MAPANYTHING="$ROOT/vendor/mapanything"
export PYTHONNOUSERSITE=1
export PYTHONPATH="$APP:$VENDOR_MAPANYTHING${PYTHONPATH:+:$PYTHONPATH}"
export EASYSPLAT_MAPANYTHING_MODELS_DIR="$ROOT/models"
export TORCH_HOME="$ROOT/models"
export HF_HOME="$ROOT/models/huggingface"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export KMP_DUPLICATE_LIB_OK=TRUE
export TOKENIZERS_PARALLELISM=false
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
exec "$PY" -m easysplat_mapanything_sfm.run "$@"
SCRIPT
chmod +x "$BIN_DIR/easysplat_mapanything_sfm"

KMP_DUPLICATE_LIB_OK=TRUE PYTHONNOUSERSITE=1 PYTHONPATH="$APP_DIR:$MAPANYTHING_VENDOR" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    from mapanything.models import MapAnything  # noqa: F401
    import easysplat_mapanything_sfm  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"mapanything_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

"$BIN_DIR/easysplat_mapanything_sfm" --help >/dev/null

echo "mapanything_mps ready at $INSTALL_DIR"
