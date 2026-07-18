#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/Toolchains/build/colmap"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
SUITESPARSE_INSTALL="$ROOT/Toolchains/build/suitesparse/install"
CERES_INSTALL="$ROOT/Toolchains/build/ceres/install"
EIGEN_INSTALL="$ROOT/Toolchains/build/ceres/eigen-install"
OPENIMAGEIO_INSTALL="$ROOT/Toolchains/build/openimageio/install"
NATIVE_OVERLAY="$ROOT/Tools/NativeColmap"
COLMAP_PATCH="$ROOT/scripts/toolchain/patches/colmap-4.1.0-easysplat.patch"

COLMAP_REPO="https://github.com/colmap/colmap.git"
COLMAP_COMMIT="fa8e3b3ff591552855f8ad2806723c80f963f69c"
COLMAP_VERSION="4.1.0"
SUITESPARSE_COMMIT="42151688813c45846a597edcb601435a0e38f3dd"
CERES_COMMIT="85331393dc0dff09f6fb9903ab0c4bfa3e134b01"
OPENIMAGEIO_COMMIT="f32bf6e6f8de38ab6d197a72fd72366b66fd30a3"
POSELIB_URL="https://github.com/PoseLib/PoseLib/archive/fa7280fee27f97aff31ae7f98bab7f583fac7d08.zip"
POSELIB_COMMIT="fa7280fee27f97aff31ae7f98bab7f583fac7d08"
POSELIB_SHA256="5408d4ae8ce367cb2f076bc6c5f0f6f78abd3573d2c015304b04e46f23455f5b"
UPSTREAM_FAISS_URL="https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.1.zip"
UPSTREAM_FAISS_SHA256="4b1ae7e7a0a46385b4084f0e3945623a15fcf99d793bf44d82aae8e24f11e5f5"
FAISS_URL="https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.3.zip"
FAISS_COMMIT="0ca9df4792b173d573044ee14ca0704780176e82"
FAISS_VERSION="1.14.3"
FAISS_SHA256="fdb01044e707caa7e16d009a8ed11816aebe17fefbccb428c495486e28e6046d"

die() {
  echo "COLMAP build failed: $*" >&2
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

verify_dependency_provenance() {
  local build_info="$1"
  local tool_name="$2"
  local expected_commit="$3"
  python3 - "$build_info" "$tool_name" "$expected_commit" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
tool_name = sys.argv[2]
expected_commit = sys.argv[3]
if not path.is_file():
    raise SystemExit(f"missing {tool_name} provenance: {path}")
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("toolchain_name") != tool_name:
    raise SystemExit(f"unexpected toolchain_name in {path}")
if payload.get("source_commit") != expected_commit:
    raise SystemExit(f"stale {tool_name} install at {path.parent}")
PY
}

prepare_source() {
  local modified_paths untracked_paths
  mkdir -p "$WORK"
  if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git clone --filter=blob:none --no-checkout "$COLMAP_REPO" "$SRC"
  fi
  [ "$(git -C "$SRC" remote get-url origin)" = "$COLMAP_REPO" ] || \
    die "unexpected source origin in $SRC"
  git -C "$SRC" fetch --depth 1 --force origin "$COLMAP_COMMIT"
  git -C "$SRC" checkout --detach --force "$COLMAP_COMMIT"
  git -C "$SRC" clean -ffdqx
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$COLMAP_COMMIT" ] || die "source commit mismatch"
  [ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ] || \
    die "source checkout is dirty"
  rg -F "URL $POSELIB_URL" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP PoseLib source URL no longer matches the reviewed pin"
  rg -F "URL_HASH SHA256=$POSELIB_SHA256" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP PoseLib source hash no longer matches the reviewed pin"
  rg -F "URL $UPSTREAM_FAISS_URL" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP FAISS source URL no longer matches the reviewed pin"
  rg -F "URL_HASH SHA256=$UPSTREAM_FAISS_SHA256" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP FAISS source hash no longer matches the reviewed pin"
  [ -s "$NATIVE_OVERLAY/local_vocab_retriever.h" ] || die "native COLMAP overlay header is missing"
  [ -s "$NATIVE_OVERLAY/local_vocab_retriever.cc" ] || die "native COLMAP overlay source is missing"
  [ -s "$COLMAP_PATCH" ] || die "reviewed COLMAP patch is missing"
  git -C "$SRC" apply --check "$COLMAP_PATCH"
  git -C "$SRC" apply "$COLMAP_PATCH"
  install -m 0644 \
    "$NATIVE_OVERLAY/local_vocab_retriever.h" \
    "$SRC/src/colmap/exe/local_vocab_retriever.h"
  install -m 0644 \
    "$NATIVE_OVERLAY/local_vocab_retriever.cc" \
    "$SRC/src/colmap/exe/local_vocab_retriever.cc"
  cmp -s \
    "$NATIVE_OVERLAY/local_vocab_retriever.h" \
    "$SRC/src/colmap/exe/local_vocab_retriever.h" || die "native overlay header copy changed"
  cmp -s \
    "$NATIVE_OVERLAY/local_vocab_retriever.cc" \
    "$SRC/src/colmap/exe/local_vocab_retriever.cc" || die "native overlay source copy changed"
  modified_paths="$(git -C "$SRC" diff --name-only | LC_ALL=C sort)"
  untracked_paths="$(git -C "$SRC" ls-files --others --exclude-standard | LC_ALL=C sort)"
  [ "$modified_paths" = $'src/colmap/exe/CMakeLists.txt\nsrc/colmap/exe/colmap.cc\nsrc/thirdparty/CMakeLists.txt' ] || \
    die "COLMAP patch modified an unexpected source path"
  [ "$untracked_paths" = $'src/colmap/exe/local_vocab_retriever.cc\nsrc/colmap/exe/local_vocab_retriever.h' ] || \
    die "native COLMAP overlay added an unexpected source path"
  git -C "$SRC" diff --check
  rg -F "URL $FAISS_URL" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "patched COLMAP FAISS source URL is incorrect"
  rg -F "URL_HASH SHA256=$FAISS_SHA256" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "patched COLMAP FAISS source hash is incorrect"
  rg -F "set(FAISS_ENABLE_METAL OFF)" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "patched COLMAP did not disable FAISS Metal"
}

configure() {
  local openmp_root boost_root gflags_prefix glog_prefix metis_prefix
  local brew_ceres brew_suitesparse brew_openimageio ignore_prefixes prefix_path
  openmp_root="$(brew --prefix libomp 2>/dev/null || true)"
  boost_root="$(brew --prefix boost 2>/dev/null || true)"
  gflags_prefix="$(brew --prefix gflags 2>/dev/null || true)"
  glog_prefix="$(brew --prefix glog 2>/dev/null || true)"
  metis_prefix="$(brew --prefix metis 2>/dev/null || true)"
  brew_ceres="$(brew --prefix ceres-solver 2>/dev/null || true)"
  brew_suitesparse="$(brew --prefix suitesparse 2>/dev/null || true)"
  brew_openimageio="$(brew --prefix openimageio 2>/dev/null || true)"

  for required in \
    "$openmp_root" \
    "$boost_root" \
    "$gflags_prefix" \
    "$glog_prefix" \
    "$metis_prefix"; do
    [ -d "$required" ] || die "required Homebrew dependency is missing"
  done

  [ -d "$EIGEN_INSTALL/share/eigen3/cmake" ] || die "pinned Eigen install is missing"
  [ -s "$OPENIMAGEIO_INSTALL/lib/cmake/OpenImageIO/OpenImageIOConfig.cmake" ] || \
    die "pinned OpenImageIO install is missing"
  prefix_path="$CERES_INSTALL;$SUITESPARSE_INSTALL;$EIGEN_INSTALL;$OPENIMAGEIO_INSTALL;$openmp_root;$boost_root;$gflags_prefix;$glog_prefix;$metis_prefix"
  ignore_prefixes="$brew_ceres;$brew_suitesparse;$brew_openimageio"

  rm -rf "$BUILD" "$INSTALL"
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_PREFIX_PATH="$prefix_path" \
    -DCMAKE_IGNORE_PREFIX_PATH="$ignore_prefixes" \
    -DOpenMP_ROOT="$openmp_root" \
    -DBoost_ROOT="$boost_root" \
    -DOpenImageIO_DIR="$OPENIMAGEIO_INSTALL/lib/cmake/OpenImageIO" \
    -DEigen3_DIR="$EIGEN_INSTALL/share/eigen3/cmake" \
    -Dgflags_DIR="$gflags_prefix/lib/cmake/gflags" \
    -Dglog_DIR="$glog_prefix/lib/cmake/glog" \
    -DMetis_ROOT="$metis_prefix" \
    -DCeres_DIR="$CERES_INSTALL/lib/cmake/Ceres" \
    -DCHOLMOD_DIR="$SUITESPARSE_INSTALL/lib/cmake/CHOLMOD" \
    -DCHOLMOD_INCLUDE_DIR_HINTS="$SUITESPARSE_INSTALL/include" \
    -DCHOLMOD_LIBRARY_DIR_HINTS="$SUITESPARSE_INSTALL/lib" \
    -DGUI_ENABLED=OFF \
    -DCUDA_ENABLED=OFF \
    -DOPENGL_ENABLED=OFF \
    -DMVS_ENABLED=OFF \
    -DCGAL_ENABLED=OFF \
    -DLSD_ENABLED=OFF \
    -DONNX_ENABLED=OFF \
    -DFETCH_ONNX=OFF \
    -DDOWNLOAD_ENABLED=OFF \
    -DCASPAR_ENABLED=OFF \
    -DTESTS_ENABLED=OFF \
    -DBENCHMARK_ENABLED=OFF \
    -DALL_SOURCE_TARGET=OFF \
    -DFETCH_POSELIB=ON \
    -DFETCH_FAISS=ON \
    -DFAISS_ENABLE_GPU=OFF \
    -DFAISS_ENABLE_METAL=OFF \
    -DFAISS_ENABLE_PYTHON=OFF \
    -DFAISS_ENABLE_MKL=OFF \
    -DFAISS_OPT_LEVEL=generic

  for option in \
    GUI_ENABLED \
    CUDA_ENABLED \
    OPENGL_ENABLED \
    MVS_ENABLED \
    CGAL_ENABLED \
    LSD_ENABLED \
    ONNX_ENABLED \
    FETCH_ONNX \
    DOWNLOAD_ENABLED \
    CASPAR_ENABLED \
    TESTS_ENABLED \
    FAISS_ENABLE_GPU \
    FAISS_ENABLE_METAL \
    FAISS_ENABLE_PYTHON \
    FAISS_ENABLE_MKL; do
    cache_is "$option" OFF
  done
  cache_is FAISS_OPT_LEVEL generic
  cache_is Ceres_DIR "$CERES_INSTALL/lib/cmake/Ceres"
  cache_is CHOLMOD_LIBRARY_DIR_HINTS "$SUITESPARSE_INSTALL/lib"
  cache_is OpenImageIO_DIR "$OPENIMAGEIO_INSTALL/lib/cmake/OpenImageIO"
  cache_is gflags_DIR "$gflags_prefix/lib/cmake/gflags"

  python3 - "$BUILD/compile_commands.json" <<'PY'
import json
import shlex
import sys
from pathlib import Path

for entry in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")):
    command = entry.get("command", "")
    tokens = entry.get("arguments") or shlex.split(command)
    source = entry.get("file", "").replace("\\", "/").lower()
    if any(part in source for part in (
        "/thirdparty/lsd/",
        "/thirdparty/siftgpu/",
        "/thirdparty/symforce-caspar/",
        "/onnxruntime/",
    )):
        raise SystemExit(f"forbidden COLMAP source entered the build: {source}")
    forbidden_pairs = (("-mcpu", "native"), ("-march", "native"))
    has_split_flag = any(
        (tokens[index], tokens[index + 1]) in forbidden_pairs
        for index in range(len(tokens) - 1)
    )
    has_joined_flag = any(
        token.partition("=")[1] and
        (token.partition("=")[0], token.partition("=")[2]) in forbidden_pairs
        for token in tokens
    )
    if has_split_flag or has_joined_flag:
        raise SystemExit(f"host-specific compiler tuning entered the build: {source}")
PY

  if rg -n '(^|[[:space:]])-isystem[[:space:]]+/opt/homebrew/include([[:space:]]|$)' \
    "$BUILD/compile_commands.json" >/dev/null; then
    die "generic Homebrew include path entered the configured build"
  fi

  if cmake --build "$BUILD" --target help | \
    grep -Eiq '(^|[^[:alnum:]_])(colmap_lsd|colmap_sift_gpu|caspar|onnxruntime)([^[:alnum:]_]|$)'; then
    die "forbidden COLMAP target was generated"
  fi
  if rg -n '/opt/homebrew/(opt|Cellar)/(ceres-solver|suite-sparse|openimageio)/' \
    "$BUILD/build.ninja" "$BUILD/compile_commands.json" >/dev/null; then
    die "Homebrew Ceres, SuiteSparse, or OpenImageIO leaked into the configured build"
  fi
  rg -F "$CERES_INSTALL/lib/libceres" "$BUILD/build.ninja" >/dev/null || \
    die "custom Ceres library is absent from the configured build"
  rg -F "$SUITESPARSE_INSTALL/lib/libcholmod" "$BUILD/build.ninja" >/dev/null || \
    die "custom CHOLMOD library is absent from the configured build"
  rg -F "$OPENIMAGEIO_INSTALL/lib/libOpenImageIO" "$BUILD/build.ninja" >/dev/null || \
    die "custom OpenImageIO library is absent from the configured build"
}

strip_install_to_runtime() {
  [ -x "$INSTALL/bin/colmap" ] || die "installed COLMAP executable is missing"
  rm -rf "${INSTALL:?}/include" "${INSTALL:?}/lib" "${INSTALL:?}/share"
  find "$INSTALL/bin" -mindepth 1 -maxdepth 1 -type f ! -name colmap -delete
}

stage_license() {
  local source_dir="$1"
  local destination="$2"
  local source
  source="$(find "$source_dir" -maxdepth 1 -type f -iname 'LICENSE*' -print | LC_ALL=C sort | head -n 1)"
  [ -n "$source" ] || die "license file is missing in $source_dir"
  install -m 0644 "$source" "$destination"
}

stage_metadata() {
  local licenses="$INSTALL/licenses/COLMAP"
  local source_tree_sha256 easysplat_overlay_sha256 binary_sha256
  local poissonrecon_tree_sha256 vlfeat_tree_sha256
  mkdir -p "$licenses"
  install -m 0644 "$SRC/COPYING.txt" "$INSTALL/licenses/COLMAP/COPYING.txt"
  install -m 0644 "$SRC/src/thirdparty/PoissonRecon/LICENSE" "$licenses/PoissonRecon-LICENSE"
  install -m 0644 "$SRC/src/thirdparty/VLFeat/LICENSE" "$licenses/VLFeat-LICENSE"
  stage_license "$BUILD/_deps/poselib-src" "$licenses/PoseLib-LICENSE"
  stage_license "$BUILD/_deps/faiss-src" "$licenses/FAISS-LICENSE"

  source_tree_sha256="$(git -C "$SRC" ls-tree -r --full-tree "$COLMAP_COMMIT" | shasum -a 256 | awk '{print $1}')"
  easysplat_overlay_sha256="$(python3 - \
    "$NATIVE_OVERLAY/local_vocab_retriever.h" \
    "$NATIVE_OVERLAY/local_vocab_retriever.cc" \
    "$COLMAP_PATCH" <<'PY'
import hashlib
import sys
from pathlib import Path

digest = hashlib.sha256()
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    digest.update(path.name.encode("utf-8"))
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest())
PY
)"
  poissonrecon_tree_sha256="$(git -C "$SRC" ls-tree -r --full-tree "$COLMAP_COMMIT" src/thirdparty/PoissonRecon | shasum -a 256 | awk '{print $1}')"
  vlfeat_tree_sha256="$(git -C "$SRC" ls-tree -r --full-tree "$COLMAP_COMMIT" src/thirdparty/VLFeat | shasum -a 256 | awk '{print $1}')"
  binary_sha256="$(shasum -a 256 "$INSTALL/bin/colmap" | awk '{print $1}')"
  python3 - \
    "$INSTALL/build_info.json" \
    "$COLMAP_REPO" \
    "$COLMAP_COMMIT" \
    "$COLMAP_VERSION" \
    "$source_tree_sha256" \
    "$easysplat_overlay_sha256" \
    "$binary_sha256" \
    "$SUITESPARSE_COMMIT" \
    "$CERES_COMMIT" \
    "$OPENIMAGEIO_COMMIT" \
    "$POSELIB_URL" \
    "$POSELIB_COMMIT" \
    "$POSELIB_SHA256" \
    "$poissonrecon_tree_sha256" \
    "$vlfeat_tree_sha256" \
    "$FAISS_URL" \
    "$FAISS_COMMIT" \
    "$FAISS_VERSION" \
    "$FAISS_SHA256" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    destination,
    source_url,
    source_commit,
    source_version,
    source_tree_sha256,
    easysplat_overlay_sha256,
    executable_sha256,
    suitesparse_commit,
    ceres_commit,
    openimageio_commit,
    poselib_url,
    poselib_commit,
    poselib_sha256,
    poissonrecon_tree_sha256,
    vlfeat_tree_sha256,
    faiss_url,
    faiss_commit,
    faiss_version,
    faiss_sha256,
) = sys.argv[1:]
payload = {
    "toolchain_name": "colmap",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "source_tree_sha256": source_tree_sha256,
    "easysplat_overlay_sha256": easysplat_overlay_sha256,
    "license": "BSD-3-Clause",
    "executable_sha256": executable_sha256,
    "dependency_pins": {
        "suitesparse": suitesparse_commit,
        "ceres": ceres_commit,
        "openimageio": openimageio_commit,
    },
    "dependencies": {
        "faiss": {
            "source_url": faiss_url,
            "source_commit": faiss_commit,
            "source_version": faiss_version,
            "source_archive_sha256": faiss_sha256,
            "license": "MIT",
            "license_files": ["licenses/COLMAP/FAISS-LICENSE"],
            "linkage": "compiled-in",
        },
        "poselib": {
            "source_url": poselib_url,
            "source_commit": poselib_commit,
            "source_version": poselib_commit,
            "source_archive_sha256": poselib_sha256,
            "license": "BSD-3-Clause",
            "license_files": ["licenses/COLMAP/PoseLib-LICENSE"],
            "linkage": "compiled-in",
        },
        "poissonrecon": {
            "source_url": f"{source_url.removesuffix('.git')}/tree/{source_commit}/src/thirdparty/PoissonRecon",
            "source_commit": source_commit,
            "source_version": f"vendored-at-colmap-{source_version}",
            "source_tree_sha256": poissonrecon_tree_sha256,
            "license": "MIT",
            "license_files": ["licenses/COLMAP/PoissonRecon-LICENSE"],
            "linkage": "compiled-in",
        },
        "vlfeat": {
            "source_url": f"{source_url.removesuffix('.git')}/tree/{source_commit}/src/thirdparty/VLFeat",
            "source_commit": source_commit,
            "source_version": f"vendored-at-colmap-{source_version}",
            "source_tree_sha256": vlfeat_tree_sha256,
            "license": "BSD-2-Clause",
            "license_files": ["licenses/COLMAP/VLFeat-LICENSE"],
            "linkage": "compiled-in",
        },
    },
    "enabled_capabilities": [
        "feature_extractor",
        "matches_importer",
        "sequential_matcher",
        "exhaustive_matcher",
        "local_vocab_retriever",
        "mapper",
        "point_triangulator",
        "bundle_adjuster",
        "model_converter",
        "model_analyzer",
        "image_undistorter",
    ],
    "disabled_capabilities": [
        "GUI",
        "CUDA",
        "OpenGL",
        "MVS",
        "CGAL",
        "LSD",
        "ONNX",
        "downloads",
        "CASPAR",
        "FAISS GPU",
        "FAISS Metal",
        "FAISS Python",
        "FAISS MKL",
    ],
    "deployment_target": "macOS 15.0",
    "build_timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
Path(destination).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

assert_permissive_closure() {
  local target
  local dependency
  local dependency_lower
  local forbidden='(spqr|cgal|lsd|siftgpu|onnx(runtime)?|caspar|cuda|avcodec|avformat|avutil|swscale|ffmpeg|heif|de265|x264|x265|aom|dav1d|vpx|svtav1|theora|vorbis|opencolorio|ocio|tbb|freetype|webp|libraw|dcmtk)'
  local targets=("$INSTALL/bin/colmap")

  while IFS= read -r target; do
    targets+=("$target")
  done < <(find "$CERES_INSTALL/lib" "$SUITESPARSE_INSTALL/lib" -type f -name '*.dylib' -print | sort)
  while IFS= read -r target; do
    targets+=("$target")
  done < <(find "$OPENIMAGEIO_INSTALL/lib" -maxdepth 1 -type f -name 'libOpenImageIO*.dylib' -print | sort)

  for target in "${targets[@]}"; do
    /usr/bin/file -b "$target" | grep -q 'Mach-O 64-bit' || die "closure contains a non-Mach-O file: $target"
    /usr/bin/file -b "$target" | grep -q 'arm64' || die "closure contains a non-arm64 binary: $target"
    while IFS= read -r dependency; do
      dependency_lower="$(printf '%s' "$dependency" | tr '[:upper:]' '[:lower:]')"
      if [[ "$dependency_lower" =~ $forbidden ]]; then
        die "forbidden dependency in $(basename "$target"): $dependency"
      fi
      if [[ "$dependency" =~ /opt/homebrew/(opt|Cellar)/(ceres-solver|suite-sparse|openimageio)/ ]]; then
        die "Homebrew Ceres, SuiteSparse, or OpenImageIO entered the closure: $dependency"
      fi
    done < <(/usr/bin/otool -L "$target" | awk 'NR > 1 {print $1}')
  done

  if find "$INSTALL" -type f -print | grep -Ei '/(lib)?(spqr|cgal|lsd|siftgpu|onnx|caspar|cuda)[^/]*$' >/dev/null; then
    die "forbidden artifact was installed with COLMAP"
  fi
  if rg -n '/opt/homebrew/(opt|Cellar)/(ceres-solver|suite-sparse|openimageio)/' \
    "$BUILD/build.ninja" "$BUILD/compile_commands.json" "$INSTALL" >/dev/null; then
    die "Homebrew Ceres, SuiteSparse, or OpenImageIO path remains in COLMAP outputs"
  fi
}

validate_commands() {
  local command
  local runtime_path="$CERES_INSTALL/lib:$SUITESPARSE_INSTALL/lib:$OPENIMAGEIO_INSTALL/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  for command in \
    feature_extractor \
    matches_importer \
    local_vocab_retriever \
    sequential_matcher \
    exhaustive_matcher \
    mapper \
    point_triangulator \
    bundle_adjuster \
    model_converter \
    model_analyzer \
    image_undistorter; do
    DYLD_LIBRARY_PATH="$runtime_path" "$INSTALL/bin/colmap" "$command" -h >/dev/null 2>&1 || \
      die "installed COLMAP command is unavailable: $command"
  done
}

validate_native_retriever() {
  local runtime_path="$CERES_INSTALL/lib:$SUITESPARSE_INSTALL/lib:$OPENIMAGEIO_INSTALL/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  EASYSPLAT_NATIVE_COLMAP_BIN="$INSTALL/bin/colmap" \
  EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH="$runtime_path" \
    python3 "$ROOT/scripts/toolchain/tests/test_native_colmap_retriever.py" NativeRetrieverTests
}

[ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64"
[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || die "Rosetta is unsupported"
for command in brew cmake ninja git python3 rg; do
  require_command "$command"
done

verify_dependency_provenance "$SUITESPARSE_INSTALL/build_info.json" suitesparse "$SUITESPARSE_COMMIT"
verify_dependency_provenance "$CERES_INSTALL/build_info.json" ceres "$CERES_COMMIT"
verify_dependency_provenance "$OPENIMAGEIO_INSTALL/build_info.json" openimageio "$OPENIMAGEIO_COMMIT"
prepare_source
configure
cmake --build "$BUILD" --target install --parallel "$(sysctl -n hw.ncpu)"
strip_install_to_runtime
stage_metadata
assert_permissive_closure
validate_commands
validate_native_retriever

echo "COLMAP installed to: $INSTALL"
