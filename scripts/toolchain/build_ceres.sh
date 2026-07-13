#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/ceres"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
EIGEN_SRC="$WORK/eigen-src"
EIGEN_BUILD="$WORK/eigen-build"
EIGEN_INSTALL="$WORK/eigen-install"

CERES_REPO="https://github.com/ceres-solver/ceres-solver.git"
CERES_COMMIT="85331393dc0dff09f6fb9903ab0c4bfa3e134b01"
CERES_VERSION="2.2.0"
EIGEN_REPO="https://gitlab.com/libeigen/eigen.git"
EIGEN_COMMIT="3147391d946bb4b6c68edd901f2add6ac1f31f8c"
EIGEN_VERSION="3.4.0"

die() {
  echo "Ceres build failed: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

cache_is() {
  local name="$1"
  local expected="$2"
  grep -Eq "^${name}:[^=]+=${expected}$" "$BUILD/CMakeCache.txt" || \
    die "CMake did not preserve ${name}=${expected}"
}

prepare_source() {
  mkdir -p "$WORK"
  if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git clone --filter=blob:none --no-checkout "$CERES_REPO" "$SRC"
  fi
  [ "$(git -C "$SRC" remote get-url origin)" = "$CERES_REPO" ] || \
    die "unexpected source origin in $SRC"
  git -C "$SRC" fetch --depth 1 --force origin "$CERES_COMMIT"
  git -C "$SRC" checkout --detach --force "$CERES_COMMIT"
  git -C "$SRC" clean -ffdqx
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$CERES_COMMIT" ] || die "source commit mismatch"
  [ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ] || \
    die "source checkout is dirty"
}

prepare_eigen() {
  if [ ! -d "$EIGEN_SRC/.git" ]; then
    rm -rf "$EIGEN_SRC"
    git clone --filter=blob:none --no-checkout "$EIGEN_REPO" "$EIGEN_SRC"
  fi
  [ "$(git -C "$EIGEN_SRC" remote get-url origin)" = "$EIGEN_REPO" ] || \
    die "unexpected Eigen source origin in $EIGEN_SRC"
  git -C "$EIGEN_SRC" fetch --depth 1 --force origin "$EIGEN_COMMIT"
  git -C "$EIGEN_SRC" checkout --detach --force "$EIGEN_COMMIT"
  git -C "$EIGEN_SRC" clean -ffdqx
  [ "$(git -C "$EIGEN_SRC" rev-parse HEAD)" = "$EIGEN_COMMIT" ] || \
    die "Eigen source commit mismatch"

  rm -rf "$EIGEN_BUILD" "$EIGEN_INSTALL"
  cmake -S "$EIGEN_SRC" -B "$EIGEN_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$EIGEN_INSTALL" \
    -DBUILD_TESTING=OFF \
    -DEIGEN_BUILD_DOC=OFF \
    -DEIGEN_BUILD_PKGCONFIG=OFF
  cmake --build "$EIGEN_BUILD" --target install
  [ -s "$EIGEN_INSTALL/share/eigen3/cmake/Eigen3Config.cmake" ] || \
    die "pinned Eigen CMake package is missing"
}

configure() {
  rm -rf "$BUILD" "$INSTALL"
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_INSTALL_RPATH=@loader_path \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
    -DEigen3_DIR="$EIGEN_INSTALL/share/eigen3/cmake" \
    -DSUITESPARSE=OFF \
    -DACCELERATESPARSE=ON \
    -DEIGENSPARSE=ON \
    -DEIGENMETIS=OFF \
    -DUSE_CUDA=OFF \
    -DMINIGLOG=ON \
    -DGFLAGS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DBUILD_SHARED_LIBS=ON

  cache_is SUITESPARSE OFF
  cache_is ACCELERATESPARSE ON
  cache_is EIGENSPARSE ON
  cache_is EIGENMETIS OFF
  cache_is USE_CUDA OFF
  cache_is MINIGLOG ON
  cache_is GFLAGS OFF
  cache_is BUILD_TESTING OFF
  cache_is BUILD_EXAMPLES OFF
  cache_is BUILD_BENCHMARKS OFF
  cache_is BUILD_SHARED_LIBS ON
}

stage_metadata() {
  mkdir -p "$INSTALL/licenses/Ceres"
  install -m 0644 "$SRC/LICENSE" "$INSTALL/licenses/Ceres/LICENSE"
  install -m 0644 "$EIGEN_SRC/COPYING.MPL2" "$INSTALL/licenses/Ceres/Eigen-MPL-2.0.txt"
  install -m 0644 "$EIGEN_SRC/COPYING.LGPL" "$INSTALL/licenses/Ceres/Eigen-LGPL-2.1.txt"
  python3 - \
    "$INSTALL/build_info.json" \
    "$INSTALL" \
    "$CERES_REPO" \
    "$CERES_COMMIT" \
    "$CERES_VERSION" \
    "$EIGEN_REPO" \
    "$EIGEN_COMMIT" \
    "$EIGEN_VERSION" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

destination = Path(sys.argv[1])
install = Path(sys.argv[2])
source_url, source_commit, source_version = sys.argv[3:6]
eigen_url, eigen_commit, eigen_version = sys.argv[6:]
libraries = []
for path in sorted((install / "lib").glob("*.dylib")):
    if path.is_symlink():
        continue
    libraries.append({
        "file": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    })
payload = {
    "toolchain_name": "ceres",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "license": "BSD-3-Clause",
    "dependencies": {
        "eigen": {
            "source_url": eigen_url,
            "source_commit": eigen_commit,
            "source_version": eigen_version,
            "license": "MPL-2.0 AND LGPL-2.1-or-later",
        },
    },
    "sparse_backends": ["AccelerateSparse", "EigenSparse"],
    "suitesparse": False,
    "cuda": False,
    "logging": "miniglog",
    "gflags": False,
    "shared_libraries": True,
    "deployment_target": "macOS 15.0",
    "libraries": libraries,
    "build_timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
destination.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

validate_install() {
  local config="$INSTALL/include/ceres/internal/config.h"
  local library
  local dependency

  [ -s "$config" ] || die "installed Ceres configuration header is missing"
  grep -Eq '^#define[[:space:]]+CERES_NO_SUITESPARSE([[:space:]]|$)' "$config" || \
    die "installed Ceres header does not disable SuiteSparse"
  grep -Eq '^#define[[:space:]]+CERES_USE_EIGEN_SPARSE([[:space:]]|$)' "$config" || \
    die "installed Ceres header does not enable EigenSparse"
  if grep -Eq '^#define[[:space:]]+CERES_NO_ACCELERATE_SPARSE([[:space:]]|$)' "$config"; then
    die "installed Ceres header disables AccelerateSparse"
  fi
  [ -s "$INSTALL/lib/cmake/Ceres/CeresConfig.cmake" ] || die "installed Ceres CMake package is missing"

  while IFS= read -r library; do
    /usr/bin/file -b "$library" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64' || \
      die "installed library is not an arm64 dylib: $library"
    while IFS= read -r dependency; do
      case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|"$INSTALL"/*) ;;
        *suitesparse*|*suite-sparse*|*cholmod*|*spqr*|*metis*|*cuda*) \
          die "forbidden sparse or CUDA dependency in $(basename "$library"): $dependency" ;;
        *) die "unexpected dependency in $(basename "$library"): $dependency" ;;
      esac
    done < <(/usr/bin/otool -L "$library" | awk 'NR > 1 {print $1}')
  done < <(find "$INSTALL/lib" -type f -name '*.dylib' -print | sort)

  [ -s "$INSTALL/build_info.json" ] || die "provenance is missing"
  python3 -m json.tool "$INSTALL/build_info.json" >/dev/null || die "provenance is invalid JSON"
}

[ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64"
[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || die "Rosetta is unsupported"
for command in cmake ninja git python3; do
  require_command "$command"
done

prepare_source
prepare_eigen
configure
cmake --build "$BUILD" --target install --parallel "$(sysctl -n hw.ncpu)"
stage_metadata
validate_install

echo "Ceres installed to: $INSTALL"
