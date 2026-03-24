#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/vggt_mps"
INSTALL_DIR="$BUILD_DIR/install/vggt_mps"
PYTHON_DIR="$INSTALL_DIR/python"
MODELS_DIR="$INSTALL_DIR/models"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$INSTALL_DIR/bin"
VENDOR_DIR="$INSTALL_DIR/vendor"
VGGT_VENDOR="$VENDOR_DIR/vggt"

VGGT_SOURCE="${VGGT_SOURCE:-$ROOT/ThirdParty/VGGT}"
VGGT_UPSTREAM_REPO="${VGGT_UPSTREAM_REPO:-}"
VGGT_UPSTREAM_URL="${VGGT_UPSTREAM_URL:-https://github.com/facebookresearch/vggt.git}"
VGGT_UPSTREAM_REF="${VGGT_UPSTREAM_REF:-main}"

VGGT_MODEL_URL="${VGGT_MODEL_URL:-https://huggingface.co/facebook/VGGT-1B/resolve/main/model.pt}"
VGGT_MODEL_FILE="$MODELS_DIR/vggt_model.pt"

# Use a self-contained CPython distribution so the packaged toolchain doesn't depend on the
# developer's local Python install (Homebrew/Conda/etc.). This makes the toolchain portable.
PYTHON_STANDALONE_TAG="${EASYSPLAT_PYTHON_STANDALONE_TAG:-20260127}"
# Use a pinned release artifact we can consistently fetch.
PYTHON_STANDALONE_VERSION="${EASYSPLAT_PYTHON_VERSION:-3.13.11}"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"

if [ "$(uname -m)" != "arm64" ]; then
  echo "vggt_mps build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
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
    echo "VGGT source checkout mismatch in $repo: expected $expected_head, got $current_head" >&2
    exit 1
  fi
  echo "VGGT source pinned at $current_head ($repo)"
  popd >/dev/null
}

function ensure_python() {
  # If this is a previously created venv (pyvenv.cfg) or an external absolute symlink (Conda),
  # blow it away and replace it with a standalone CPython distribution.
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
      echo "vggt_mps python version mismatch (found $current_python_version, expected $PYTHON_STANDALONE_VERSION); rebuilding runtime." >&2
      rm -rf "$PYTHON_DIR"
    fi
  fi

  if [ ! -x "$PYTHON_DIR/bin/python3" ]; then
    download_file "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL"
    mkdir -p "$INSTALL_DIR"
    /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"
  fi

  echo "vggt_mps python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user --upgrade pip setuptools wheel
}

function pip_install() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user "$@"
}

function require_arm64_python() {
  local arch
  arch="$("$PYTHON_DIR/bin/python3" - <<'PY'
import platform
print(platform.machine())
PY
)"
  if [ "$arch" != "arm64" ]; then
    echo "vggt_mps python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

function verify_torch_mps() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    sys.stderr.write(f"vggt_mps: failed to import torch: {exc}\n")
    raise SystemExit(1)
print(f"torch={torch.__version__}")
print(f"mps.is_built={torch.backends.mps.is_built()}")
print(f"mps.is_available={torch.backends.mps.is_available()}")
if not torch.backends.mps.is_built():
    sys.stderr.write("vggt_mps: torch was built without MPS support.\n")
    raise SystemExit(1)
PY
}

function download_file() {
  local url="$1"
  local dest="$2"
  if [ -f "$dest" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 3 --retry-delay 5 -o "$dest" "$url"
}

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$MODELS_DIR" "$BIN_DIR"

ensure_python
require_arm64_python

VGGT_SOURCE_REPO="${VGGT_UPSTREAM_REPO:-local-vendored}"
VGGT_SOURCE_REF="${VGGT_UPSTREAM_REF}"
VGGT_SOURCE_COMMIT="vendored-snapshot"

if [ -d "$VGGT_SOURCE/vggt" ]; then
  if [ -d "$VGGT_SOURCE/.git" ]; then
    VGGT_SOURCE_COMMIT="$(git -C "$VGGT_SOURCE" rev-parse HEAD)"
  fi
elif [ -n "$VGGT_UPSTREAM_REPO" ]; then
  if [ -d "$VGGT_UPSTREAM_REPO" ]; then
    VGGT_SOURCE="$VGGT_UPSTREAM_REPO"
    ensure_repo "$VGGT_SOURCE" "$VGGT_UPSTREAM_URL" "$VGGT_UPSTREAM_REF"
    VGGT_SOURCE_REPO="$VGGT_UPSTREAM_URL"
  else
    VGGT_SOURCE="$BUILD_DIR/vggt-upstream"
    ensure_repo "$VGGT_SOURCE" "$VGGT_UPSTREAM_REPO" "$VGGT_UPSTREAM_REF"
    VGGT_SOURCE_REPO="$VGGT_UPSTREAM_REPO"
  fi
  VGGT_SOURCE_COMMIT="$(git -C "$VGGT_SOURCE" rev-parse HEAD)"
else
  VGGT_SOURCE="$BUILD_DIR/vggt-upstream"
  ensure_repo "$VGGT_SOURCE" "$VGGT_UPSTREAM_URL" "$VGGT_UPSTREAM_REF"
  VGGT_SOURCE_REPO="$VGGT_UPSTREAM_URL"
  VGGT_SOURCE_COMMIT="$(git -C "$VGGT_SOURCE" rev-parse HEAD)"
fi

# Install the runtime deps for EasySplat's VGGT bridge.
# We pin the PyTorch pair in Tools/VggtSfm/requirements.txt to a matching PyPI release that
# publishes Apple Silicon wheels for the bundled CPython version.
pip_install -r "$ROOT/Tools/VggtSfm/requirements.txt"
verify_torch_mps

# Vendor the minimal VGGT sources so toolchain runs offline (no pip editable install needed).
if command -v rsync >/dev/null 2>&1; then
  rm -rf "$VGGT_VENDOR"
  mkdir -p "$VGGT_VENDOR"
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$VGGT_SOURCE/vggt/" "$VGGT_VENDOR/vggt/"
  if [ -f "$VGGT_SOURCE/LICENSE.txt" ]; then
    cp -f "$VGGT_SOURCE/LICENSE.txt" "$VGGT_VENDOR/LICENSE.txt"
  fi
else
  rm -rf "$VGGT_VENDOR"
  mkdir -p "$VGGT_VENDOR"
  cp -R "$VGGT_SOURCE/vggt" "$VGGT_VENDOR/"
  if [ -f "$VGGT_SOURCE/LICENSE.txt" ]; then
    cp -f "$VGGT_SOURCE/LICENSE.txt" "$VGGT_VENDOR/LICENSE.txt"
  fi
fi

if [ ! -f "$VGGT_VENDOR/vggt/models/vggt.py" ]; then
  echo "VGGT vendor tree missing expected module: vggt/models/vggt.py" >&2
  exit 1
fi

# Install EasySplat's VGGT -> COLMAP bridge app code.
rm -rf "$APP_DIR"
cp -R "$ROOT/Tools/VggtSfm" "$APP_DIR"
if [ ! -f "$APP_DIR/easysplat_vggt_sfm/run.py" ]; then
  echo "VGGT app bundle missing easysplat_vggt_sfm/run.py" >&2
  exit 1
fi

# Download model weights (large).
download_file "$VGGT_MODEL_URL" "$VGGT_MODEL_FILE"

PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
import json
import platform
from pathlib import Path
import torch
import torchvision

Path("${INSTALL_DIR}").mkdir(parents=True, exist_ok=True)
Path("${INSTALL_DIR}/build_info.json").write_text(
    json.dumps(
        {
            "toolchain_name": "vggt_mps",
            "source_repo": "${VGGT_SOURCE_REPO}",
            "source_ref": "${VGGT_SOURCE_REF}",
            "source_commit": "${VGGT_SOURCE_COMMIT}",
            "source_path": "${VGGT_SOURCE}",
            "model_source": "${VGGT_MODEL_URL}",
            "python_version": platform.python_version(),
            "torch_version": torch.__version__,
            "torchvision_version": torchvision.__version__,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

function write_wrapper() {
  cat > "$BIN_DIR/easysplat_vggt_sfm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
APP="$ROOT/app"
VENDOR_VGGT="$ROOT/vendor/vggt"
export PYTHONNOUSERSITE=1
export PYTHONPATH="$APP:$VENDOR_VGGT${PYTHONPATH:+:$PYTHONPATH}"
export TORCH_HOME="$ROOT/models"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export KMP_DUPLICATE_LIB_OK=TRUE
exec "$PY" -m easysplat_vggt_sfm.run "$@"
SCRIPT
  chmod +x "$BIN_DIR/easysplat_vggt_sfm"
}

write_wrapper

if [ ! -x "$BIN_DIR/easysplat_vggt_sfm" ]; then
  echo "Failed to create easysplat_vggt_sfm wrapper." >&2
  exit 1
fi

KMP_DUPLICATE_LIB_OK=TRUE PYTHONNOUSERSITE=1 PYTHONPATH="$APP_DIR:$VGGT_VENDOR" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    from vggt.models.vggt import VGGT  # noqa: F401
    import easysplat_vggt_sfm  # noqa: F401
    import pycolmap  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"vggt_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

"$BIN_DIR/easysplat_vggt_sfm" --help >/dev/null

echo "vggt_mps ready at $INSTALL_DIR"
