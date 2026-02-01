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

VGGT_MPS_REF="${VGGT_MPS_REF:-v2.0.0}"
VGGT_MPS_REPO="$BUILD_DIR/vggt-mps"

VGGT_MODEL_URL="${VGGT_MODEL_URL:-https://huggingface.co/facebook/VGGT-1B/resolve/main/model.pt}"
VGGT_MODEL_FILE="$MODELS_DIR/vggt_model.pt"

# Use a self-contained CPython distribution so the packaged toolchain doesn't depend on the
# developer's local Python install (Homebrew/Conda/etc.). This makes the toolchain portable.
PYTHON_STANDALONE_TAG="${EASYSPLAT_PYTHON_STANDALONE_TAG:-20260127}"
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
  git fetch origin "$ref" || true
  git checkout "$ref" || true
  git submodule update --init --recursive || true
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

  if [ ! -x "$PYTHON_DIR/bin/python3" ]; then
    download_file "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL"
    mkdir -p "$INSTALL_DIR"
    /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"
  fi

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

ensure_repo "$VGGT_MPS_REPO" "https://github.com/jmanhype/vggt-mps.git" "$VGGT_MPS_REF"

# Install the runtime deps for EasySplat's VGGT bridge.
# Note: upstream vggt/requirements.txt pins torch==2.3.1 which doesn't have wheels for newer
# Python versions (e.g. 3.13). We intentionally avoid those pins and let pip choose compatible
# torch/torchvision builds for the current Python.
pip_install -r "$ROOT/Tools/VggtSfm/requirements.txt"
verify_torch_mps

# Vendor the upstream VGGT repo so toolchain runs offline (no pip editable install needed).
if command -v rsync >/dev/null 2>&1; then
  mkdir -p "$VENDOR_DIR"
  rsync -a --delete \
    --exclude ".git" \
    --exclude "__pycache__" \
    --exclude ".pytest_cache" \
    --exclude "*.pyc" \
    "$VGGT_MPS_REPO/repo/vggt/" "$VGGT_VENDOR/"
else
  rm -rf "$VGGT_VENDOR"
  mkdir -p "$VGGT_VENDOR"
  cp -R "$VGGT_MPS_REPO/repo/vggt/." "$VGGT_VENDOR/"
fi

if [ ! -f "$VGGT_VENDOR/vggt/models/vggt.py" ]; then
  echo "VGGT vendor tree missing expected module: vggt/models/vggt.py" >&2
  exit 1
fi

# Install EasySplat's VGGT -> COLMAP bridge app code.
rm -rf "$APP_DIR"
cp -R "$ROOT/Tools/VggtSfm" "$APP_DIR"

# Download model weights (large).
download_file "$VGGT_MODEL_URL" "$VGGT_MODEL_FILE"

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
exec "$PY" -m easysplat_vggt_sfm.run "$@"
SCRIPT
  chmod +x "$BIN_DIR/easysplat_vggt_sfm"
}

write_wrapper

if [ ! -x "$BIN_DIR/easysplat_vggt_sfm" ]; then
  echo "Failed to create easysplat_vggt_sfm wrapper." >&2
  exit 1
fi

PYTHONNOUSERSITE=1 PYTHONPATH="$APP_DIR:$VGGT_VENDOR" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    from vggt.models.vggt import VGGT  # noqa: F401
    import easysplat_vggt_sfm  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"vggt_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

echo "vggt_mps ready at $INSTALL_DIR"
