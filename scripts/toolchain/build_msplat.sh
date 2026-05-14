#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/msplat"
INSTALL_DIR="$BUILD_DIR/install/msplat"
PYTHON_DIR="$INSTALL_DIR/python"
BIN_DIR="$INSTALL_DIR/bin"

MSPLAT_VERSION="${MSPLAT_VERSION:-1.1.3}"
MSPLAT_PIP_SPEC="msplat[cli]==$MSPLAT_VERSION"

# Keep msplat on Python 3.12 by default because the fast path has been validated
# against the current cp312 wheel and the package only supports Python 3.12+.
PYTHON_STANDALONE_TAG="${EASYSPLAT_PYTHON_STANDALONE_TAG:-20260127}"
PYTHON_STANDALONE_VERSION="${EASYSPLAT_MSPLAT_PYTHON_VERSION:-3.12.12}"
PYTHON_STANDALONE_ASSET="cpython-${PYTHON_STANDALONE_VERSION}+${PYTHON_STANDALONE_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_STANDALONE_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${PYTHON_STANDALONE_ASSET}"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/$PYTHON_STANDALONE_ASSET"

if [ "$(uname -m)" != "arm64" ]; then
  echo "msplat build must run on Apple Silicon (arm64). Refusing to build under Rosetta." >&2
  exit 1
fi

download_file() {
  local url="$1"
  local dest="$2"
  local tmp
  if [ -f "$dest" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.tmp.$$"
  rm -f "$tmp"
  if ! curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
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
      echo "msplat python version mismatch (found $current_python_version, expected $PYTHON_STANDALONE_VERSION); rebuilding runtime." >&2
      rm -rf "$PYTHON_DIR"
    fi
  fi

  if [ ! -x "$PYTHON_DIR/bin/python3" ]; then
    download_file "$PYTHON_STANDALONE_URL" "$PYTHON_STANDALONE_TARBALL"
    mkdir -p "$INSTALL_DIR"
    /usr/bin/tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$INSTALL_DIR"
  fi

  echo "msplat python version: $("$PYTHON_DIR/bin/python3" -V 2>&1)"
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" -m pip install --no-user --upgrade pip setuptools wheel
}

require_arm64_python() {
  local arch
  arch="$("$PYTHON_DIR/bin/python3" - <<'PY'
import platform
print(platform.machine())
PY
)"
  if [ "$arch" != "arm64" ]; then
    echo "msplat python is not arm64 (got: $arch). Rebuild toolchain on Apple Silicon without Rosetta." >&2
    exit 1
  fi
}

install_msplat() {
  PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$PYTHON_DIR/bin/python3" -m pip install \
    --no-user \
    --no-cache-dir \
    --force-reinstall \
    "$MSPLAT_PIP_SPEC"
}

write_wrapper() {
  mkdir -p "$BIN_DIR"
  cat >"$BIN_DIR/msplat-train" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/python/bin/python3"
export PYTHONNOUSERSITE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
exec "$PY" -m msplat.cli "$@"
SCRIPT
  chmod +x "$BIN_DIR/msplat-train"
}

write_build_info() {
  PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<PY
import importlib.metadata as metadata
import json
import platform
from pathlib import Path

Path("${INSTALL_DIR}").mkdir(parents=True, exist_ok=True)
Path("${INSTALL_DIR}/build_info.json").write_text(
    json.dumps(
        {
            "toolchain_name": "msplat",
            "source_path": "pypi:${MSPLAT_PIP_SPEC}",
            "package_name": "msplat",
            "package_version": metadata.version("msplat"),
            "numpy_version": metadata.version("numpy"),
            "tyro_version": metadata.version("tyro"),
            "python_version": platform.python_version(),
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
}

validate_install() {
  local core_extension
  core_extension="$(PYTHONNOUSERSITE=1 "$PYTHON_DIR/bin/python3" - <<'PY'
from pathlib import Path
import msplat

package_dir = Path(msplat.__file__).parent
matches = sorted(package_dir.glob("_core*.so"))
if not matches:
    raise SystemExit(1)
print(matches[0])
PY
)"
  if ! /usr/bin/file -b "$core_extension" | grep -q "arm64"; then
    echo "msplat core extension is not arm64: $core_extension" >&2
    exit 1
  fi
  "$BIN_DIR/msplat-train" --help >/dev/null
}

mkdir -p "$BUILD_DIR" "$INSTALL_DIR"
ensure_python
require_arm64_python
install_msplat
write_wrapper
write_build_info
find "$INSTALL_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +
find "$INSTALL_DIR" -type f -name "*.pyc" -delete
validate_install

echo "msplat ready at $INSTALL_DIR"
