#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/fastvggt_mps"
INSTALL_DIR="$BUILD_DIR/install/fastvggt_mps"
PYTHON_DIR="$INSTALL_DIR/python"
MODELS_DIR="$INSTALL_DIR/models"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$INSTALL_DIR/bin"
VENDOR_DIR="$INSTALL_DIR/vendor"
FASTVGGT_VENDOR="$VENDOR_DIR/fastvggt"

FASTVGGT_LOCAL_REPO="${FASTVGGT_LOCAL_REPO:-}"
FASTVGGT_SOURCE="${FASTVGGT_SOURCE:-${FASTVGGT_LOCAL_REPO:-$ROOT/ThirdParty/FastVGGT}}"
FASTVGGT_REPO="${FASTVGGT_REPO:-}"
FASTVGGT_REF="${FASTVGGT_REF:-main}"

FASTVGGT_MODEL_PATH="${FASTVGGT_MODEL_PATH:-$FASTVGGT_SOURCE/ckpt/model_tracker_fixed_e20.pt}"
FASTVGGT_MODEL_URL="${FASTVGGT_MODEL_URL:-https://huggingface.co/facebook/VGGT_tracker_fixed/resolve/main/model_tracker_fixed_e20.pt}"
FASTVGGT_MODEL_FILE="$MODELS_DIR/fastvggt_model.pt"
FASTVGGT_ENABLE_PYCOLMAP="${FASTVGGT_ENABLE_PYCOLMAP:-0}"

# Use a self-contained CPython distribution so the packaged toolchain doesn't depend on the
# developer's local Python install (Homebrew/Conda/etc.). This makes the toolchain portable.
PYTHON_STANDALONE_TAG="${EASYSPLAT_PYTHON_STANDALONE_TAG:-20260127}"
# Use a pinned release artifact we can consistently fetch.
PYTHON_STANDALONE_VERSION="${EASYSPLAT_PYTHON_VERSION:-3.13.11}"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"

if [ "$(uname -m)" != "arm64" ]; then
  echo "fastvggt_mps build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
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
  # Clean first so checkout does not retain/print stale local modifications.
  git reset --hard
  git clean -fdx
  git fetch --tags origin "$ref"
  git checkout --detach "$ref"
  git submodule sync --recursive
  git submodule update --init --recursive
  local current_head
  local expected_head
  expected_head="$(git rev-parse "$ref^{commit}")"
  # Keep the managed upstream clone deterministic across reruns.
  git reset --hard "$expected_head"
  git clean -fdx
  current_head="$(git rev-parse HEAD)"
  if [ "$current_head" != "$expected_head" ]; then
    echo "FastVGGT source checkout mismatch in $repo: expected $expected_head, got $current_head" >&2
    exit 1
  fi
  echo "FastVGGT source pinned at $current_head ($repo)"
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
      echo "fastvggt_mps python version mismatch (found $current_python_version, expected $PYTHON_STANDALONE_VERSION); rebuilding runtime." >&2
      rm -rf "$PYTHON_DIR"
    fi
  fi

  if [ ! -x "$PYTHON_DIR/bin/python3" ]; then
    download_file "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL"
    mkdir -p "$INSTALL_DIR"
    /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"
  fi

  echo "fastvggt_mps python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
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
    echo "fastvggt_mps python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

function verify_torch_mps() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    sys.stderr.write(f"fastvggt_mps: failed to import torch: {exc}\n")
    raise SystemExit(1)
print(f"torch={torch.__version__}")
print(f"mps.is_built={torch.backends.mps.is_built()}")
print(f"mps.is_available={torch.backends.mps.is_available()}")
if not torch.backends.mps.is_built():
    sys.stderr.write("fastvggt_mps: torch was built without MPS support.\n")
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

FASTVGGT_SOURCE_REPO="${FASTVGGT_REPO:-local-vendored}"
FASTVGGT_SOURCE_REF="${FASTVGGT_REF}"
FASTVGGT_SOURCE_COMMIT="vendored-snapshot"

if [ -d "$FASTVGGT_SOURCE/vggt" ]; then
  if [ -d "$FASTVGGT_SOURCE/.git" ]; then
    FASTVGGT_SOURCE_COMMIT="$(git -C "$FASTVGGT_SOURCE" rev-parse HEAD)"
  fi
elif [ -n "$FASTVGGT_REPO" ]; then
  FASTVGGT_SOURCE="$BUILD_DIR/fastvggt-upstream"
  ensure_repo "$FASTVGGT_SOURCE" "$FASTVGGT_REPO" "$FASTVGGT_REF"
  FASTVGGT_SOURCE_COMMIT="$(git -C "$FASTVGGT_SOURCE" rev-parse HEAD)"
else
  echo "FastVGGT source not found at $FASTVGGT_SOURCE. Ensure ThirdParty/FastVGGT exists or set FASTVGGT_REPO." >&2
  exit 1
fi

# Install the runtime deps for EasySplat's FastVGGT bridge.
# We pin the PyTorch pair in Tools/FastVggtSfm/requirements.txt to a matching PyPI release that
# publishes Apple Silicon wheels for the bundled CPython version.
pip_install -r "$ROOT/Tools/FastVggtSfm/requirements.txt"
if [ "$FASTVGGT_ENABLE_PYCOLMAP" = "1" ]; then
  pip_install -r "$ROOT/Tools/FastVggtSfm/requirements-colmap.txt"
else
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" -m pip uninstall -y pycolmap >/dev/null 2>&1 || true
fi
verify_torch_mps

# Vendor the minimal FastVGGT sources so the toolchain runs offline.
if command -v rsync >/dev/null 2>&1; then
  rm -rf "$FASTVGGT_VENDOR"
  mkdir -p "$FASTVGGT_VENDOR"
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$FASTVGGT_SOURCE/vggt/" "$FASTVGGT_VENDOR/vggt/"
  rsync -a --delete \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "$FASTVGGT_SOURCE/merging/" "$FASTVGGT_VENDOR/merging/"
  if [ -f "$FASTVGGT_SOURCE/LICENSE.txt" ]; then
    cp -f "$FASTVGGT_SOURCE/LICENSE.txt" "$FASTVGGT_VENDOR/LICENSE.txt"
  fi
else
  rm -rf "$FASTVGGT_VENDOR"
  mkdir -p "$FASTVGGT_VENDOR"
  cp -R "$FASTVGGT_SOURCE/vggt" "$FASTVGGT_VENDOR/"
  cp -R "$FASTVGGT_SOURCE/merging" "$FASTVGGT_VENDOR/"
  if [ -f "$FASTVGGT_SOURCE/LICENSE.txt" ]; then
    cp -f "$FASTVGGT_SOURCE/LICENSE.txt" "$FASTVGGT_VENDOR/LICENSE.txt"
  fi
fi

if [ ! -f "$FASTVGGT_VENDOR/vggt/models/vggt.py" ]; then
  echo "FastVGGT vendor tree missing expected module: vggt/models/vggt.py" >&2
  exit 1
fi
if [ ! -f "$FASTVGGT_VENDOR/merging/merge.py" ]; then
  echo "FastVGGT vendor tree missing expected module: merging/merge.py" >&2
  exit 1
fi

# Install EasySplat's FastVGGT -> COLMAP bridge app code.
rm -rf "$APP_DIR"
cp -R "$ROOT/Tools/FastVggtSfm" "$APP_DIR"
if [ ! -f "$APP_DIR/easysplat_fastvggt_sfm/run.py" ]; then
  echo "FastVGGT app bundle missing easysplat_fastvggt_sfm/run.py" >&2
  exit 1
fi

# Copy model weights (large).
if [ -f "$FASTVGGT_MODEL_PATH" ]; then
  cp -f "$FASTVGGT_MODEL_PATH" "$FASTVGGT_MODEL_FILE"
elif [ -n "$FASTVGGT_MODEL_URL" ]; then
  download_file "$FASTVGGT_MODEL_URL" "$FASTVGGT_MODEL_FILE"
else
  echo "FastVGGT model weights not found. Set FASTVGGT_MODEL_PATH or FASTVGGT_MODEL_URL." >&2
  exit 1
fi

FASTVGGT_MODEL_SOURCE="$FASTVGGT_MODEL_URL"
if [ -f "$FASTVGGT_MODEL_PATH" ]; then
  FASTVGGT_MODEL_SOURCE="$FASTVGGT_MODEL_PATH"
fi

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
            "toolchain_name": "fastvggt_mps",
            "source_repo": "${FASTVGGT_SOURCE_REPO}",
            "source_ref": "${FASTVGGT_SOURCE_REF}",
            "source_commit": "${FASTVGGT_SOURCE_COMMIT}",
            "source_path": "${FASTVGGT_SOURCE}",
            "model_source": "${FASTVGGT_MODEL_SOURCE}",
            "pycolmap_enabled": "${FASTVGGT_ENABLE_PYCOLMAP}",
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
  cat > "$BIN_DIR/easysplat_fastvggt_sfm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
APP="$ROOT/app"
VENDOR_FASTVGGT="$ROOT/vendor/fastvggt"
export PYTHONNOUSERSITE=1
export PYTHONPATH="$APP:$VENDOR_FASTVGGT${PYTHONPATH:+:$PYTHONPATH}"
export TORCH_HOME="$ROOT/models"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export KMP_DUPLICATE_LIB_OK=TRUE
exec "$PY" -m easysplat_fastvggt_sfm.run "$@"
SCRIPT
  chmod +x "$BIN_DIR/easysplat_fastvggt_sfm"
}

write_wrapper

if [ ! -x "$BIN_DIR/easysplat_fastvggt_sfm" ]; then
  echo "Failed to create easysplat_fastvggt_sfm wrapper." >&2
  exit 1
fi

KMP_DUPLICATE_LIB_OK=TRUE PYTHONNOUSERSITE=1 PYTHONPATH="$APP_DIR:$FASTVGGT_VENDOR" "$PYTHON_DIR/bin/python3" - <<'PY'
import sys
try:
    from vggt.models.vggt import VGGT  # noqa: F401
    import easysplat_fastvggt_sfm  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"fastvggt_mps import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

"$BIN_DIR/easysplat_fastvggt_sfm" --help >/dev/null

echo "fastvggt_mps ready at $INSTALL_DIR"
