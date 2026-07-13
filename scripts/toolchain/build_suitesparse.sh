#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/suitesparse"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"

SUITESPARSE_REPO="https://github.com/DrTimothyAldenDavis/SuiteSparse.git"
SUITESPARSE_COMMIT="42151688813c45846a597edcb601435a0e38f3dd"
SUITESPARSE_VERSION="7.12.2"

die() {
  echo "SuiteSparse build failed: $*" >&2
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
    git clone --filter=blob:none --no-checkout "$SUITESPARSE_REPO" "$SRC"
  fi
  [ "$(git -C "$SRC" remote get-url origin)" = "$SUITESPARSE_REPO" ] || \
    die "unexpected source origin in $SRC"
  git -C "$SRC" fetch --depth 1 --force origin "$SUITESPARSE_COMMIT"
  git -C "$SRC" checkout --detach --force "$SUITESPARSE_COMMIT"
  git -C "$SRC" clean -ffdqx
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$SUITESPARSE_COMMIT" ] || \
    die "source commit mismatch"
  [ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ] || \
    die "source checkout is dirty"
}

prune_forbidden_sources() {
  rm -rf \
    "$SRC/CHOLMOD/GPU" \
    "$SRC/CHOLMOD/MatrixOps" \
    "$SRC/CHOLMOD/Modify" \
    "$SRC/CHOLMOD/Partition" \
    "$SRC/CHOLMOD/SuiteSparse_metis" \
    "$SRC/CHOLMOD/Supernodal" \
    "$SRC/SPQR"
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
    '-DSUITESPARSE_ENABLE_PROJECTS=suitesparse_config;amd;colamd;cholmod' \
    -DSUITESPARSE_USE_CUDA=OFF \
    -DSUITESPARSE_USE_FORTRAN=OFF \
    -DSUITESPARSE_USE_OPENMP=OFF \
    -DCHOLMOD_GPL=OFF \
    -DCHOLMOD_CAMD=OFF \
    -DCHOLMOD_PARTITION=OFF \
    -DCHOLMOD_MATRIXOPS=OFF \
    -DCHOLMOD_MODIFY=OFF \
    -DCHOLMOD_SUPERNODAL=OFF \
    -DCHOLMOD_USE_CUDA=OFF \
    -DCHOLMOD_USE_OPENMP=OFF \
    -DSUITESPARSE_DEMOS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_STATIC_LIBS=OFF

  cache_is SUITESPARSE_ENABLE_PROJECTS 'suitesparse_config;amd;colamd;cholmod'
  cache_is SUITESPARSE_USE_CUDA OFF
  cache_is CHOLMOD_GPL OFF
  cache_is CHOLMOD_CAMD OFF
  cache_is CHOLMOD_PARTITION OFF
  cache_is CHOLMOD_MATRIXOPS OFF
  cache_is CHOLMOD_MODIFY OFF
  cache_is CHOLMOD_SUPERNODAL OFF
  cache_is CHOLMOD_USE_CUDA OFF
  cache_is BUILD_SHARED_LIBS ON
  cache_is BUILD_STATIC_LIBS OFF

  python3 - "$BUILD/compile_commands.json" <<'PY'
import json
import sys
from pathlib import Path

for entry in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")):
    source = entry.get("file", "").replace("\\", "/").lower()
    if any(part in source for part in (
        "/cholmod/matrixops/",
        "/cholmod/modify/",
        "/cholmod/partition/",
        "/cholmod/supernodal/",
        "/cholmod/gpu/",
        "/cholmod/suitesparse_metis/",
        "/spqr/",
    )):
        raise SystemExit(f"forbidden SuiteSparse source entered the build: {source}")
PY
}

stage_metadata() {
  local licenses="$INSTALL/licenses/SuiteSparse"
  mkdir -p "$licenses/CHOLMOD"
  install -m 0644 "$SRC/SuiteSparse_config/README.txt" "$licenses/SuiteSparse_config-BSD-3-Clause.txt"
  install -m 0644 "$SRC/AMD/Doc/License.txt" "$licenses/AMD-BSD-3-Clause.txt"
  install -m 0644 "$SRC/COLAMD/Doc/License.txt" "$licenses/COLAMD-BSD-3-Clause.txt"
  install -m 0644 "$SRC/CHOLMOD/Doc/License.txt" "$licenses/CHOLMOD/module-licenses.txt"

  python3 - \
    "$INSTALL/build_info.json" \
    "$INSTALL" \
    "$SUITESPARSE_REPO" \
    "$SUITESPARSE_COMMIT" \
    "$SUITESPARSE_VERSION" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

destination = Path(sys.argv[1])
install = Path(sys.argv[2])
source_url, source_commit, source_version = sys.argv[3:]
libraries = []
for path in sorted((install / "lib").glob("*.dylib")):
    if path.is_symlink():
        continue
    libraries.append({
        "file": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    })
payload = {
    "toolchain_name": "suitesparse",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "license": "BSD-3-Clause AND LGPL-2.1-or-later AND Apache-2.0",
    "enabled_projects": ["SuiteSparse_config", "AMD", "COLAMD", "CHOLMOD"],
    "disabled_projects": ["CAMD", "CCOLAMD", "SPQR"],
    "cholmod_gpl": False,
    "cholmod_modules": ["Check", "Cholesky", "Utility"],
    "cuda": False,
    "shared_libraries": True,
    "deployment_target": "macOS 15.0",
    "libraries": libraries,
    "build_timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
destination.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

validate_install() {
  local header="$INSTALL/include/suitesparse/cholmod.h"
  local library
  local dependency

  [ -s "$header" ] || die "installed CHOLMOD header is missing"
  for feature in \
    CHOLMOD_HAS_GPL \
    CHOLMOD_HAS_PARTITION \
    CHOLMOD_HAS_MATRIXOPS \
    CHOLMOD_HAS_MODIFY \
    CHOLMOD_HAS_SUPERNODAL \
    CHOLMOD_HAS_CUDA; do
    if grep -Eq "^#define[[:space:]]+${feature}([[:space:]]|$)" "$header"; then
      die "$feature is unexpectedly enabled"
    fi
  done

  if find "$INSTALL" -mindepth 1 \( -type f -o -type l \) -print | \
    grep -Ei '/([^/]*(spqr|metis|camd|ccolamd|cuda)[^/]*)$' >/dev/null; then
    die "forbidden SuiteSparse library or package was installed"
  fi

  while IFS= read -r library; do
    /usr/bin/file -b "$library" | grep -q 'Mach-O 64-bit dynamically linked shared library arm64' || \
      die "installed library is not an arm64 dylib: $library"
    while IFS= read -r dependency; do
      case "$dependency" in
        /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|"$INSTALL"/*) ;;
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
prune_forbidden_sources
configure
cmake --build "$BUILD" --target install --parallel "$(sysctl -n hw.ncpu)"
stage_metadata
validate_install

echo "SuiteSparse installed to: $INSTALL"
