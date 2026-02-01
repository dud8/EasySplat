#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/learned_sfm"
INSTALL_DIR="$BUILD_DIR/install/learned_sfm"
VENV_DIR="$INSTALL_DIR/python"
MODELS_DIR="$INSTALL_DIR/models"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$INSTALL_DIR/bin"
VENDOR_DIR="$INSTALL_DIR/vendor"
MAST3R_VENDOR="$VENDOR_DIR/mast3r"

MAST3R_REF="${MAST3R_REF:-main}"
MAST3R_REPO="$BUILD_DIR/mast3r"
ASMK_REPO="$BUILD_DIR/asmk"
ENABLE_RETRIEVAL="${EASYSPLAT_LEARNED_RETRIEVAL:-0}"

MAST3R_CKPT_URL="https://download.europe.naverlabs.com/ComputerVision/MASt3R/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric.pth"
MAST3R_RETRIEVAL_URL="https://download.europe.naverlabs.com/ComputerVision/MASt3R/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric_retrieval_trainingfree.pth"
MAST3R_CODEBOOK_URL="https://download.europe.naverlabs.com/ComputerVision/MASt3R/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric_retrieval_codebook.pkl"

echo "WARNING: learned_sfm (MASt3R) is deprecated. Prefer VGGT via ./scripts/toolchain/build_vggt_mps.sh" >&2

if [ "$(uname -m)" != "arm64" ]; then
  echo "learned_sfm build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
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
  git submodule update --init --recursive
  popd >/dev/null
}

function ensure_venv() {
  if [ ! -x "$VENV_DIR/bin/python3" ]; then
    arch -arm64 python3 -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/pip" install --no-user --upgrade pip setuptools wheel
}

function pip_install() {
  "$VENV_DIR/bin/pip" install --no-user "$@"
}

function require_arm64_python() {
  local arch
  arch="$("$VENV_DIR/bin/python3" - <<'PY'
import platform
print(platform.machine())
PY
)"
  if [ "$arch" != "arm64" ]; then
    echo "learned_sfm python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

function verify_torch_mps() {
  "$VENV_DIR/bin/python3" - <<'PY'
import sys
try:
    import torch
except Exception as exc:
    sys.stderr.write(f"learned_sfm: failed to import torch: {exc}\n")
    raise SystemExit(1)
print(f"torch={torch.__version__}")
print(f"mps.is_built={torch.backends.mps.is_built()}")
print(f"mps.is_available={torch.backends.mps.is_available()}")
if not torch.backends.mps.is_built():
    sys.stderr.write("learned_sfm: torch was built without MPS support.\n")
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
  curl -L --retry 3 --retry-delay 5 -o "$dest" "$url"
}

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$MODELS_DIR" "$BIN_DIR"

ensure_venv
require_arm64_python

ensure_repo "$MAST3R_REPO" "https://github.com/naver/mast3r" "$MAST3R_REF"

pip_install -r "$MAST3R_REPO/requirements.txt"
if [ -f "$MAST3R_REPO/dust3r/requirements.txt" ]; then
  pip_install -r "$MAST3R_REPO/dust3r/requirements.txt"
fi
verify_torch_mps

if command -v rsync >/dev/null 2>&1; then
  mkdir -p "$VENDOR_DIR"
  rsync -a --delete \
    --exclude ".git" \
    --exclude "__pycache__" \
    --exclude ".pytest_cache" \
    --exclude "*.pyc" \
    "$MAST3R_REPO/" "$MAST3R_VENDOR/"
else
  rm -rf "$MAST3R_VENDOR"
  mkdir -p "$MAST3R_VENDOR"
  cp -R "$MAST3R_REPO/." "$MAST3R_VENDOR/"
fi

if [ ! -d "$MAST3R_VENDOR/mast3r" ] || \
   [ ! -d "$MAST3R_VENDOR/dust3r/dust3r" ] || \
   [ ! -d "$MAST3R_VENDOR/dust3r/croco/models" ]; then
  echo "MASt3R vendor tree missing required submodules. Ensure git submodules are initialized." >&2
  exit 1
fi

# Retrieval support (optional)
if [ "$ENABLE_RETRIEVAL" = "1" ]; then
  ensure_repo "$ASMK_REPO" "https://github.com/jenicek/asmk" "master"
  pip_install cython
  pushd "$ASMK_REPO" >/dev/null
  "$VENV_DIR/bin/python" setup.py build_ext --inplace
  popd >/dev/null
  pip_install -e "$ASMK_REPO"
fi

# Install EasySplat learned matcher app code
rm -rf "$APP_DIR"
cp -R "$ROOT/Tools/LearnedSfm" "$APP_DIR"

pip_install -r "$ROOT/Tools/LearnedSfm/requirements.txt"

# Download model weights
CHECKPOINT_DIR="$MODELS_DIR/checkpoints"
download_file "$MAST3R_CKPT_URL" "$CHECKPOINT_DIR/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric.pth"
if [ "$ENABLE_RETRIEVAL" = "1" ]; then
  download_file "$MAST3R_RETRIEVAL_URL" "$MODELS_DIR/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric_retrieval_trainingfree.pth"
  download_file "$MAST3R_CODEBOOK_URL" "$MODELS_DIR/MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric_retrieval_codebook.pkl"
fi

function write_wrapper() {
  cat > "$BIN_DIR/easysplat_match" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
APP="$ROOT/app"
VENDOR="$ROOT/vendor/mast3r"
export PYTHONPATH="$APP:$VENDOR:$VENDOR/dust3r${PYTHONPATH:+:$PYTHONPATH}"
export TORCH_HOME="$ROOT/models"
exec "$PY" -m easysplat_learned.match "$@"
SCRIPT
  chmod +x "$BIN_DIR/easysplat_match"
}

write_wrapper

if [ ! -x "$BIN_DIR/easysplat_match" ]; then
  echo "Failed to create learned matcher wrapper." >&2
  exit 1
fi

PYTHONPATH="$APP_DIR:$MAST3R_VENDOR:$MAST3R_VENDOR/dust3r" "$VENV_DIR/bin/python3" - <<'PY'
import sys
try:
    import mast3r  # noqa: F401
    import dust3r  # noqa: F401
    import easysplat_learned  # noqa: F401
except Exception as exc:  # noqa: BLE001
    sys.stderr.write(f"learned_sfm import sanity check failed: {exc}\n")
    raise SystemExit(1)
PY

echo "learned_sfm ready at $INSTALL_DIR"
