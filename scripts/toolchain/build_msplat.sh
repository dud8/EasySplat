#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/Toolchains/build/msplat"
SOURCE_DIR="$BUILD_DIR/src"
NATIVE_BUILD_DIR="$BUILD_DIR/native-build"
DOWNLOAD_DIR="$BUILD_DIR/downloads"
DEPS_DIR="$BUILD_DIR/dependencies"
INSTALL_PARENT="$BUILD_DIR/install"
INSTALL_DIR="$INSTALL_PARENT/msplat"
STAGE_DIR="$INSTALL_PARENT/msplat.stage.$$"
PROMOTER="$ROOT/scripts/toolchain/atomic_swap_install.py"
PYTHON_BIN="/usr/bin/python3"
INSTALL_STAGE_OWNED=0
INSTALL_STAGE_DEVICE=""
INSTALL_STAGE_INODE=""

OVERLAY="$ROOT/Tools/MsplatNative/msplat.cpp"
OVERLAY_SHA256="ff776be07eaf49219b23b3c460d5d1834d1227882b5f4e54aed627cad72f0e23"
RASTER_TEST_SOURCE="$ROOT/Tools/MsplatNative/msplat_raster_tests.cpp"
RASTER_TEST_SHA256="b2529dedfc7e2027b6f3e0f86db522cfc95be5fb90208a8d6b75a892584a52b7"
FIXTURE_GENERATOR="$ROOT/scripts/ci/generate_msplat_sparse_fixtures.py"
UPSTREAM_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-easysplat.patch"
UPSTREAM_PATCH_SHA256="047ef2547d4478bc77a7a1537284e58fdb20de4c52c5c37982674fa2af70927e"
SOURCE_NOTICE_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-source-notices.patch"
SOURCE_NOTICE_PATCH_SHA256="6deee598c9321c9b98d74b92fd5cce9808069a7a63effcd80615eb7d208d2ffb"
CHECKPOINT_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-checkpoint.patch"
NUMERIC_STABILITY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-numeric-stability.patch"
NUMERIC_STABILITY_PATCH_SHA256="231586b17e4f47c8c55432a631e08bf293b31a92f8d6ec49b367d11632350ec3"
METAL_SAFETY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-metal-safety.patch"
METAL_SAFETY_PATCH_SHA256="5d3dfff3edcbca940d37f6ee3145c76c678ebd36ebc03016cfd5dab78e1d45ac"
EXACT_RASTER_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-raster.patch"
EXACT_RASTER_PATCH_SHA256="c34a8860ed8ae9bc92c976aaa1c3f89eec8aa9be9cab4778f074491e98860855"
STAGE_TIMING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-stage-timing.patch"
STAGE_TIMING_PATCH_SHA256="e803a9e6027fb81835d3c30bccd6cec1fa7ad63315ffb6bbae0f135cc476941d"
MEMORY_EFFICIENCY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-memory-efficiency.patch"
MEMORY_EFFICIENCY_PATCH_SHA256="bfacc105454e80102139f120dd6375037360c6a9763f1e1f708aa2a7f22eca6c"
DENSIFICATION_MEMORY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-densification-memory.patch"
DENSIFICATION_MEMORY_PATCH_SHA256="b429540372d807f280929ebba1670257990bd36b28dfee5b42bc377ccef60ac7"
ROW_SPAN_CULLING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-row-span-culling.patch"
ROW_SPAN_CULLING_PATCH_SHA256="481c4c9a70f1da5eb1590b20a64e25a3c64bb3c19f14e27996ab9b25a119594d"
GEOMETRY_ADAM_FUSION_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-geometry-adam-fusion.patch"
GEOMETRY_ADAM_FUSION_PATCH_SHA256="927ad1fdbffee7ad762396c7acc965cd4a20da781f172240c62aa94f41e1cd2c"
PARALLEL_RADIX_SCAN_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-parallel-radix-scan.patch"
PARALLEL_RADIX_SCAN_PATCH_SHA256="1caedde675063dd0b119e91ec39a6945328ecf37134a83b079dce964a7a816c4"
ALLOCATION_PRESSURE_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-allocation-pressure.patch"
ALLOCATION_PRESSURE_PATCH_SHA256="d5235770565c75387ad42ec4b534895322275822ab5913d0bc05bcf3bba95083"
EXACT_PREFIX_HARDENING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-prefix-hardening.patch"
EXACT_PREFIX_HARDENING_PATCH_SHA256="e7437861085e86e8671898b8c5833568e0420bdf1c0559175ddcdb34ed159ace"
TILE_SPAN_TEST_ROOT="$ROOT/Tools/MsplatNative/TileSpanTests"
RASTER_TEST_FIXTURES="$BUILD_DIR/raster-test-fixtures"

MSPLAT_REPO="https://github.com/rayanht/msplat.git"
MSPLAT_COMMIT="106499b0a53f82b0c92d013b0861fbebd341b17e"
MSPLAT_VERSION="1.1.3"

NLOHMANN_JSON_URL="https://github.com/nlohmann/json/archive/refs/tags/v3.11.3.zip"
NLOHMANN_JSON_SHA256="04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069"
NANOFLANN_URL="https://github.com/jlblancoc/nanoflann/archive/refs/tags/v1.5.5.zip"
NANOFLANN_SHA256="57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc"
CLI11_URL="https://github.com/CLIUtils/CLI11/archive/refs/tags/v2.4.2.zip"
CLI11_SHA256="43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0"

STAGE_CLEANUP_ALLOWED=1

cleanup() {
  local status=$?
  local install_cleanup_status=0
  trap - EXIT
  trap '' INT TERM HUP
  if [ "$STAGE_CLEANUP_ALLOWED" = "1" ] && [ "$INSTALL_STAGE_OWNED" = "1" ]; then
    if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ] && \
      [ -f "$PROMOTER" ] && [ ! -L "$PROMOTER" ]; then
      "$PYTHON_BIN" "$PROMOTER" \
        --remove-owned-tree \
        "$STAGE_DIR" \
        "$INSTALL_STAGE_DEVICE" \
        "$INSTALL_STAGE_INODE" \
        --allow-symlinks || install_cleanup_status=$?
    else
      install_cleanup_status=1
    fi
    if [ "$install_cleanup_status" -ne 0 ]; then
      printf '%s\n' \
        "native msplat cleanup preserved an unverified staged install: $STAGE_DIR" >&2
    fi
  fi
  if [ "$status" -eq 0 ] && [ "$install_cleanup_status" -ne 0 ]; then
    status="$install_cleanup_status"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

die() {
  echo "native msplat build failed: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

create_owned_install_stage() {
  local identity
  identity="$(
    "$PYTHON_BIN" "$PROMOTER" --create-owned-tree "$STAGE_DIR"
  )" || die "could not create and bind native msplat install stage"
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
    die "native msplat install stage identity is malformed"
  INSTALL_STAGE_DEVICE="${identity%%:*}"
  INSTALL_STAGE_INODE="${identity#*:}"
  INSTALL_STAGE_OWNED=1
}

recover_stale_promotions() {
  local journal path
  for journal in "$INSTALL_PARENT"/msplat.stage.*.promotion-state; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    "$PYTHON_BIN" "$PROMOTER" --recover "$journal" || \
      die "could not recover interrupted msplat promotion: $journal"
  done
  for path in "$INSTALL_PARENT"/msplat.stage.* "$INSTALL_PARENT"/msplat.previous.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    case "$path" in
      *.promotion-state) continue ;;
    esac
    die "ambiguous staged install requires recovery: $path"
  done
}

reject_raster_test_symbols() {
  local binary="$1"
  local symbol
  for symbol in \
    msplat_set_force_exact_for_testing \
    msplat_set_exact_fallback_enabled_for_testing \
    msplat_set_exact_execution_capacity_for_testing \
    msplat_set_exact_capacity_limit_for_testing \
    msplat_set_raster_memory_budget_for_testing \
    msplat_simulate_gpu_allocation_failure_for_testing \
    msplat_set_raster_memory_budget_and_fail_for_testing \
    msplat_set_tile_culling_min_area_for_testing \
    msplat_set_geometry_adam_fusion_enabled_for_testing \
    msplat_fail_next_sync_for_testing \
    msplat_pending_exact_raster_timing_handlers_for_testing \
    msplat_exact_radix_pass_count_for_testing \
    msplat_exact_prefix_sum_for_testing \
    msplat_exact_radix_sort_for_testing \
    msplat_gpu_ticks_to_seconds_for_testing \
    msplat_gpu_frequency_from_timestamp_pairs_for_testing \
    msplat_stage_timing_sample_valid_for_testing \
    msplat_stage_timing_aggregate_coherent_for_testing \
    msplat_enable_stage_profiling_for_testing \
    msplat_gpu_timestamp_calibration_for_testing \
    msplat_copy_last_raster_debug \
    msplat_copy_last_raster_reference_debug; do
    if /usr/bin/nm -gU "$binary" | grep -Fq "$symbol"; then
      die "staged CLI exports raster test hook: $symbol"
    fi
  done
}

preflight() {
  [ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64; Rosetta is unsupported"
  if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    die "must run outside Rosetta"
  fi
  for command in cmake ninja git curl shasum xcrun ditto file; do
    require_command "$command"
  done
  [ -x "$PYTHON_BIN" ] || die "selected Python executable is unavailable"
  [ -x "$PROMOTER" ] || die "atomic install promoter is missing or not executable"
  if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
    echo "Xcode's optional Metal compiler is required." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  [ -f "$OVERLAY" ] || die "missing CLI overlay: $OVERLAY"
  [ "$(sha256 "$OVERLAY")" = "$OVERLAY_SHA256" ] \
    || die "CLI overlay SHA-256 mismatch"
  [ -f "$RASTER_TEST_SOURCE" ] || die "missing raster parity test: $RASTER_TEST_SOURCE"
  [ -f "$FIXTURE_GENERATOR" ] || die "missing sparse fixture generator: $FIXTURE_GENERATOR"
  [ -f "$UPSTREAM_PATCH" ] || die "missing upstream patch: $UPSTREAM_PATCH"
  [ "$(sha256 "$UPSTREAM_PATCH")" = "$UPSTREAM_PATCH_SHA256" ] \
    || die "upstream patch SHA-256 mismatch"
  [ -f "$SOURCE_NOTICE_PATCH" ] || die "missing source-notice patch: $SOURCE_NOTICE_PATCH"
  [ "$(sha256 "$SOURCE_NOTICE_PATCH")" = "$SOURCE_NOTICE_PATCH_SHA256" ] \
    || die "source-notice patch SHA-256 mismatch"
  [ "$(sha256 "$RASTER_TEST_SOURCE")" = "$RASTER_TEST_SHA256" ] \
    || die "raster parity test SHA-256 mismatch"
  [ -f "$CHECKPOINT_PATCH" ] || die "missing checkpoint patch: $CHECKPOINT_PATCH"
  [ -f "$NUMERIC_STABILITY_PATCH" ] || die "missing numeric-stability patch: $NUMERIC_STABILITY_PATCH"
  [ "$(sha256 "$NUMERIC_STABILITY_PATCH")" = "$NUMERIC_STABILITY_PATCH_SHA256" ] \
    || die "numeric-stability patch SHA-256 mismatch"
  [ -f "$METAL_SAFETY_PATCH" ] || die "missing Metal-safety patch: $METAL_SAFETY_PATCH"
  [ "$(sha256 "$METAL_SAFETY_PATCH")" = "$METAL_SAFETY_PATCH_SHA256" ] \
    || die "Metal-safety patch SHA-256 mismatch"
  [ -f "$EXACT_RASTER_PATCH" ] || die "missing exact-raster patch: $EXACT_RASTER_PATCH"
  [ "$(sha256 "$EXACT_RASTER_PATCH")" = "$EXACT_RASTER_PATCH_SHA256" ] \
    || die "exact-raster patch SHA-256 mismatch"
  [ -f "$STAGE_TIMING_PATCH" ] || die "missing stage-timing patch: $STAGE_TIMING_PATCH"
  [ "$(sha256 "$STAGE_TIMING_PATCH")" = "$STAGE_TIMING_PATCH_SHA256" ] \
    || die "stage-timing patch SHA-256 mismatch"
  [ -f "$MEMORY_EFFICIENCY_PATCH" ] || die "missing memory-efficiency patch: $MEMORY_EFFICIENCY_PATCH"
  [ "$(sha256 "$MEMORY_EFFICIENCY_PATCH")" = "$MEMORY_EFFICIENCY_PATCH_SHA256" ] \
    || die "memory-efficiency patch SHA-256 mismatch"
  [ -f "$DENSIFICATION_MEMORY_PATCH" ] || die "missing densification-memory patch: $DENSIFICATION_MEMORY_PATCH"
  [ "$(sha256 "$DENSIFICATION_MEMORY_PATCH")" = "$DENSIFICATION_MEMORY_PATCH_SHA256" ] \
    || die "densification-memory patch SHA-256 mismatch"
  [ -f "$ROW_SPAN_CULLING_PATCH" ] || die "missing row-span culling patch: $ROW_SPAN_CULLING_PATCH"
  [ "$(sha256 "$ROW_SPAN_CULLING_PATCH")" = "$ROW_SPAN_CULLING_PATCH_SHA256" ] \
    || die "row-span culling patch SHA-256 mismatch"
  [ -f "$GEOMETRY_ADAM_FUSION_PATCH" ] \
    || die "missing geometry-Adam fusion patch: $GEOMETRY_ADAM_FUSION_PATCH"
  [ "$(sha256 "$GEOMETRY_ADAM_FUSION_PATCH")" = "$GEOMETRY_ADAM_FUSION_PATCH_SHA256" ] \
    || die "geometry-Adam fusion patch SHA-256 mismatch"
  [ -f "$PARALLEL_RADIX_SCAN_PATCH" ] \
    || die "missing parallel radix-scan patch: $PARALLEL_RADIX_SCAN_PATCH"
  [ "$(sha256 "$PARALLEL_RADIX_SCAN_PATCH")" = "$PARALLEL_RADIX_SCAN_PATCH_SHA256" ] \
    || die "parallel radix-scan patch SHA-256 mismatch"
  [ -f "$ALLOCATION_PRESSURE_PATCH" ] \
    || die "missing allocation-pressure patch: $ALLOCATION_PRESSURE_PATCH"
  [ "$(sha256 "$ALLOCATION_PRESSURE_PATCH")" = "$ALLOCATION_PRESSURE_PATCH_SHA256" ] \
    || die "allocation-pressure patch SHA-256 mismatch"
  [ -f "$EXACT_PREFIX_HARDENING_PATCH" ] \
    || die "missing exact-prefix hardening patch: $EXACT_PREFIX_HARDENING_PATCH"
  [ "$(sha256 "$EXACT_PREFIX_HARDENING_PATCH")" = "$EXACT_PREFIX_HARDENING_PATCH_SHA256" ] \
    || die "exact-prefix hardening patch SHA-256 mismatch"
  for source in \
    "$TILE_SPAN_TEST_ROOT/include/tile_culling.hpp" \
    "$TILE_SPAN_TEST_ROOT/include/gpu_tile_culling.hpp" \
    "$TILE_SPAN_TEST_ROOT/src/tile_culling.metal" \
    "$TILE_SPAN_TEST_ROOT/src/gpu_tile_culling.mm" \
    "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp" \
    "$TILE_SPAN_TEST_ROOT/tests/gpu_tile_culling_tests.mm"; do
    [ -f "$source" ] || die "missing tile-span property source: $source"
  done
}

download_verified() {
  local url="$1"
  local expected="$2"
  local destination="$3"
  local temporary="$destination.tmp.$$"

  mkdir -p "$(dirname "$destination")"
  if [ ! -f "$destination" ] || [ "$(sha256 "$destination")" != "$expected" ]; then
    rm -f "$destination" "$temporary"
    curl -fL --retry 3 --retry-delay 2 -o "$temporary" "$url"
    [ "$(sha256 "$temporary")" = "$expected" ] || {
      rm -f "$temporary"
      die "SHA-256 mismatch for $url"
    }
    mv "$temporary" "$destination"
  fi
  [ "$(sha256 "$destination")" = "$expected" ] || die "cached archive failed verification: $destination"
}

extract_verified() {
  local archive="$1"
  local expected_root="$2"
  local destination="$3"
  local temporary="$destination.stage.$$"

  rm -rf "$temporary"
  mkdir -p "$temporary"
  ditto -x -k "$archive" "$temporary"
  [ -d "$temporary/$expected_root" ] || die "archive root mismatch for $archive"
  rm -rf "$destination"
  mv "$temporary/$expected_root" "$destination"
  rm -rf "$temporary"
}

prepare_dependencies() {
  local json_archive="$DOWNLOAD_DIR/nlohmann-json-v3.11.3.zip"
  local nanoflann_archive="$DOWNLOAD_DIR/nanoflann-v1.5.5.zip"
  local cli11_archive="$DOWNLOAD_DIR/cli11-v2.4.2.zip"

  download_verified "$NLOHMANN_JSON_URL" "$NLOHMANN_JSON_SHA256" "$json_archive"
  download_verified "$NANOFLANN_URL" "$NANOFLANN_SHA256" "$nanoflann_archive"
  download_verified "$CLI11_URL" "$CLI11_SHA256" "$cli11_archive"

  mkdir -p "$DEPS_DIR"
  extract_verified "$json_archive" "json-3.11.3" "$DEPS_DIR/nlohmann-json-3.11.3"
  extract_verified "$nanoflann_archive" "nanoflann-1.5.5" "$DEPS_DIR/nanoflann-1.5.5"
  extract_verified "$cli11_archive" "CLI11-2.4.2" "$DEPS_DIR/CLI11-2.4.2"
}

prepare_source() {
  mkdir -p "$BUILD_DIR"
  rm -rf "$SOURCE_DIR"
  GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none --no-checkout "$MSPLAT_REPO" "$SOURCE_DIR"

  [ "$(git -C "$SOURCE_DIR" remote get-url origin)" = "$MSPLAT_REPO" ] || die "unexpected msplat origin"
  GIT_LFS_SKIP_SMUDGE=1 git -C "$SOURCE_DIR" fetch --force origin "$MSPLAT_COMMIT"
  git -C "$SOURCE_DIR" config filter.lfs.process ""
  git -C "$SOURCE_DIR" config filter.lfs.smudge ""
  git -C "$SOURCE_DIR" config filter.lfs.required false
  GIT_LFS_SKIP_SMUDGE=1 git -C "$SOURCE_DIR" checkout --detach --force "$MSPLAT_COMMIT"
  git -C "$SOURCE_DIR" clean -ffdqx

  [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$MSPLAT_COMMIT" ] || die "msplat source commit mismatch"
  [ "$(cat "$SOURCE_DIR/VERSION")" = "$MSPLAT_VERSION" ] || die "msplat VERSION mismatch"
  [ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)" ] || die "msplat source checkout is dirty before overlay"

  SOURCE_TREE_SHA256="$(git -C "$SOURCE_DIR" ls-tree -r --full-tree "$MSPLAT_COMMIT" | shasum -a 256 | awk '{print $1}')"
  cp "$OVERLAY" "$SOURCE_DIR/cli/msplat.cpp"
  mkdir -p "$SOURCE_DIR/tests"
  cp "$RASTER_TEST_SOURCE" "$SOURCE_DIR/tests/msplat_raster_tests.cpp"
  git -C "$SOURCE_DIR" apply --unidiff-zero --check "$UPSTREAM_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero "$UPSTREAM_PATCH"
  git -C "$SOURCE_DIR" apply --check "$CHECKPOINT_PATCH"
  git -C "$SOURCE_DIR" apply "$CHECKPOINT_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero --check "$NUMERIC_STABILITY_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero "$NUMERIC_STABILITY_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero --check "$METAL_SAFETY_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero "$METAL_SAFETY_PATCH"
  git -C "$SOURCE_DIR" apply --check "$EXACT_RASTER_PATCH"
  git -C "$SOURCE_DIR" apply "$EXACT_RASTER_PATCH"
  git -C "$SOURCE_DIR" apply --check "$STAGE_TIMING_PATCH"
  git -C "$SOURCE_DIR" apply "$STAGE_TIMING_PATCH"
  git -C "$SOURCE_DIR" apply --check "$MEMORY_EFFICIENCY_PATCH"
  git -C "$SOURCE_DIR" apply "$MEMORY_EFFICIENCY_PATCH"
  git -C "$SOURCE_DIR" apply --check "$DENSIFICATION_MEMORY_PATCH"
  git -C "$SOURCE_DIR" apply "$DENSIFICATION_MEMORY_PATCH"
  git -C "$SOURCE_DIR" apply --check "$ROW_SPAN_CULLING_PATCH"
  git -C "$SOURCE_DIR" apply "$ROW_SPAN_CULLING_PATCH"
  git -C "$SOURCE_DIR" apply --check "$GEOMETRY_ADAM_FUSION_PATCH"
  git -C "$SOURCE_DIR" apply "$GEOMETRY_ADAM_FUSION_PATCH"
  git -C "$SOURCE_DIR" apply --check "$PARALLEL_RADIX_SCAN_PATCH"
  git -C "$SOURCE_DIR" apply "$PARALLEL_RADIX_SCAN_PATCH"
  git -C "$SOURCE_DIR" apply --check "$ALLOCATION_PRESSURE_PATCH"
  git -C "$SOURCE_DIR" apply "$ALLOCATION_PRESSURE_PATCH"
  git -C "$SOURCE_DIR" apply --check "$EXACT_PREFIX_HARDENING_PATCH"
  git -C "$SOURCE_DIR" apply "$EXACT_PREFIX_HARDENING_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero --check "$SOURCE_NOTICE_PATCH"
  git -C "$SOURCE_DIR" apply --unidiff-zero "$SOURCE_NOTICE_PATCH"
}

configure_and_build() {
  rm -rf "$NATIVE_BUILD_DIR"
  cmake -S "$SOURCE_DIR" -B "$NATIVE_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DMSPLAT_BUILD_PYTHON=OFF \
    -DMSPLAT_BUILD_RASTER_TESTS=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DFETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON="$DEPS_DIR/nlohmann-json-3.11.3" \
    -DFETCHCONTENT_SOURCE_DIR_NANOFLANN="$DEPS_DIR/nanoflann-1.5.5" \
    -DFETCHCONTENT_SOURCE_DIR_CLI11="$DEPS_DIR/CLI11-2.4.2"
  cmake --build "$NATIVE_BUILD_DIR" --target msplat metallib msplat_raster_tests
  xcrun clang++ -std=c++20 -O2 \
    -I"$TILE_SPAN_TEST_ROOT/include" \
    "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp" \
    -o "$NATIVE_BUILD_DIR/tile_span_cpu_tests"
  xcrun -sdk macosx metal -std=metal3.1 \
    -c "$TILE_SPAN_TEST_ROOT/src/tile_culling.metal" \
    -o "$NATIVE_BUILD_DIR/tile_span_property.air"
  xcrun -sdk macosx metallib \
    "$NATIVE_BUILD_DIR/tile_span_property.air" \
    -o "$NATIVE_BUILD_DIR/tile_span_property.metallib"
  xcrun clang++ -std=c++20 -O2 -fobjc-arc \
    -I"$TILE_SPAN_TEST_ROOT/include" \
    "$TILE_SPAN_TEST_ROOT/tests/gpu_tile_culling_tests.mm" \
    "$TILE_SPAN_TEST_ROOT/src/gpu_tile_culling.mm" \
    -framework Foundation -framework Metal \
    -o "$NATIVE_BUILD_DIR/tile_span_metal_tests"
  "$NATIVE_BUILD_DIR/tile_span_cpu_tests"
  "$NATIVE_BUILD_DIR/tile_span_metal_tests" \
    "$NATIVE_BUILD_DIR/tile_span_property.metallib"
  rm -rf "$RASTER_TEST_FIXTURES"
  "$PYTHON_BIN" "$FIXTURE_GENERATOR" --output "$RASTER_TEST_FIXTURES"
  "$NATIVE_BUILD_DIR/msplat_raster_tests" \
    "$RASTER_TEST_FIXTURES/01-sphere-500" \
    "$RASTER_TEST_FIXTURES/14-mixed-resolution-500" \
    "$RASTER_TEST_FIXTURES/13-overflow-2304" \
    "$RASTER_TEST_FIXTURES/16-broad-overflow-2304" \
    "$RASTER_TEST_FIXTURES/15-increasing-overflow-10000" \
    "$RASTER_TEST_FIXTURES/17-exact-budget-1279"
  "$NATIVE_BUILD_DIR/msplat_raster_tests" \
    --stage-timing "$RASTER_TEST_FIXTURES/01-sphere-500"
  "$NATIVE_BUILD_DIR/msplat_raster_tests" --prefix-oracle
  "$NATIVE_BUILD_DIR/msplat_raster_tests" --radix-oracle
}

write_build_info() {
  local executable_sha256="$1"
  local metallib_sha256="$2"
  local build_info compiler cmake_version ninja_version timestamp overlay_sha256 raster_test_sha256 patch_sha256 source_notice_patch_sha256 checkpoint_patch_sha256 numeric_stability_patch_sha256 metal_safety_patch_sha256 exact_raster_patch_sha256 stage_timing_patch_sha256 memory_efficiency_patch_sha256 densification_memory_patch_sha256 row_span_culling_patch_sha256 geometry_adam_fusion_patch_sha256 parallel_radix_scan_patch_sha256 allocation_pressure_patch_sha256 exact_prefix_hardening_patch_sha256
  build_info="$STAGE_DIR/build_info.json"
  compiler="$(xcrun clang++ --version | head -n 1)"
  cmake_version="$(cmake --version | head -n 1)"
  ninja_version="$(ninja --version)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  overlay_sha256="$(sha256 "$OVERLAY")"
  raster_test_sha256="$(sha256 "$RASTER_TEST_SOURCE")"
  patch_sha256="$(sha256 "$UPSTREAM_PATCH")"
  source_notice_patch_sha256="$(sha256 "$SOURCE_NOTICE_PATCH")"
  checkpoint_patch_sha256="$(sha256 "$CHECKPOINT_PATCH")"
  numeric_stability_patch_sha256="$(sha256 "$NUMERIC_STABILITY_PATCH")"
  metal_safety_patch_sha256="$(sha256 "$METAL_SAFETY_PATCH")"
  exact_raster_patch_sha256="$(sha256 "$EXACT_RASTER_PATCH")"
  stage_timing_patch_sha256="$(sha256 "$STAGE_TIMING_PATCH")"
  memory_efficiency_patch_sha256="$(sha256 "$MEMORY_EFFICIENCY_PATCH")"
  densification_memory_patch_sha256="$(sha256 "$DENSIFICATION_MEMORY_PATCH")"
  row_span_culling_patch_sha256="$(sha256 "$ROW_SPAN_CULLING_PATCH")"
  geometry_adam_fusion_patch_sha256="$(sha256 "$GEOMETRY_ADAM_FUSION_PATCH")"
  parallel_radix_scan_patch_sha256="$(sha256 "$PARALLEL_RADIX_SCAN_PATCH")"
  allocation_pressure_patch_sha256="$(sha256 "$ALLOCATION_PRESSURE_PATCH")"
  exact_prefix_hardening_patch_sha256="$(sha256 "$EXACT_PREFIX_HARDENING_PATCH")"

  "$PYTHON_BIN" - "$build_info" \
    "$MSPLAT_REPO" "$MSPLAT_COMMIT" "$MSPLAT_VERSION" "$SOURCE_TREE_SHA256" \
    "$overlay_sha256" "$raster_test_sha256" "$patch_sha256" "$source_notice_patch_sha256" "$checkpoint_patch_sha256" "$numeric_stability_patch_sha256" "$metal_safety_patch_sha256" "$exact_raster_patch_sha256" "$stage_timing_patch_sha256" "$memory_efficiency_patch_sha256" "$densification_memory_patch_sha256" "$row_span_culling_patch_sha256" "$geometry_adam_fusion_patch_sha256" "$parallel_radix_scan_patch_sha256" "$allocation_pressure_patch_sha256" "$exact_prefix_hardening_patch_sha256" \
    "$NLOHMANN_JSON_SHA256" "$NANOFLANN_SHA256" "$CLI11_SHA256" \
    "$executable_sha256" "$metallib_sha256" \
    "$compiler" "$cmake_version" "$ninja_version" "$timestamp" <<'PY'
import json
import sys

(
    output_path,
    source_url,
    source_commit,
    source_version,
    source_tree_sha256,
    overlay_sha256,
    raster_test_sha256,
    patch_sha256,
    source_notice_patch_sha256,
    checkpoint_patch_sha256,
    numeric_stability_patch_sha256,
    metal_safety_patch_sha256,
    exact_raster_patch_sha256,
    stage_timing_patch_sha256,
    memory_efficiency_patch_sha256,
    densification_memory_patch_sha256,
    row_span_culling_patch_sha256,
    geometry_adam_fusion_patch_sha256,
    parallel_radix_scan_patch_sha256,
    allocation_pressure_patch_sha256,
    exact_prefix_hardening_patch_sha256,
    nlohmann_json_sha256,
    nanoflann_sha256,
    cli11_sha256,
    executable_sha256,
    metallib_sha256,
    compiler,
    cmake_version,
    ninja_version,
    timestamp,
) = sys.argv[1:]

payload = {
    "toolchain_name": "msplat",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "source_tree_sha256": source_tree_sha256,
    "overlay_sha256": overlay_sha256,
    "raster_test_sha256": raster_test_sha256,
    "patch_sha256": patch_sha256,
    "source_notice_patch_sha256": source_notice_patch_sha256,
    "checkpoint_patch_sha256": checkpoint_patch_sha256,
    "numeric_stability_patch_sha256": numeric_stability_patch_sha256,
    "metal_safety_patch_sha256": metal_safety_patch_sha256,
    "exact_raster_patch_sha256": exact_raster_patch_sha256,
    "stage_timing_patch_sha256": stage_timing_patch_sha256,
    "memory_efficiency_patch_sha256": memory_efficiency_patch_sha256,
    "densification_memory_patch_sha256": densification_memory_patch_sha256,
    "row_span_culling_patch_sha256": row_span_culling_patch_sha256,
    "geometry_adam_fusion_patch_sha256": geometry_adam_fusion_patch_sha256,
    "parallel_radix_scan_patch_sha256": parallel_radix_scan_patch_sha256,
    "allocation_pressure_patch_sha256": allocation_pressure_patch_sha256,
    "exact_prefix_hardening_patch_sha256": exact_prefix_hardening_patch_sha256,
    "dependencies": {
        "nlohmann_json_v3.11.3_sha256": nlohmann_json_sha256,
        "nanoflann_v1.5.5_sha256": nanoflann_sha256,
        "cli11_v2.4.2_sha256": cli11_sha256,
    },
    "executable_sha256": executable_sha256,
    "metallib_sha256": metallib_sha256,
    "compiler": compiler,
    "cmake": cmake_version,
    "ninja": ninja_version,
    "deployment_target": "macOS 15.0",
    "build_configuration": "Release",
    "cmake_arguments": [
        "-G Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
        "-DMSPLAT_BUILD_PYTHON=OFF",
        "-DMSPLAT_BUILD_RASTER_TESTS=ON",
        "-DFETCHCONTENT_FULLY_DISCONNECTED=ON",
        "FETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON=verified-v3.11.3",
        "FETCHCONTENT_SOURCE_DIR_NANOFLANN=verified-v1.5.5",
        "FETCHCONTENT_SOURCE_DIR_CLI11=verified-v2.4.2",
    ],
    "build_timestamp": timestamp,
}

with open(output_path, "w", encoding="utf-8", newline="\n") as output:
    json.dump(payload, output, indent=2, sort_keys=True)
    output.write("\n")
PY
}

stage_install() {
  mkdir -p "$STAGE_DIR/bin"
  install -m 0755 "$NATIVE_BUILD_DIR/msplat" "$STAGE_DIR/bin/easysplat-train"
  install -m 0644 "$NATIVE_BUILD_DIR/default.metallib" "$STAGE_DIR/bin/default.metallib"
  install -m 0644 "$SOURCE_DIR/LICENSE" "$STAGE_DIR/LICENSE"

  local executable_sha256 metallib_sha256
  executable_sha256="$(sha256 "$STAGE_DIR/bin/easysplat-train")"
  metallib_sha256="$(sha256 "$STAGE_DIR/bin/default.metallib")"
  write_build_info "$executable_sha256" "$metallib_sha256"
}

audit_stage_extended_metadata() {
  local mode="$1"
  "$PYTHON_BIN" - \
    "$STAGE_DIR" \
    "$INSTALL_STAGE_DEVICE" \
    "$INSTALL_STAGE_INODE" \
    "$mode" <<'PY'
import ctypes
import errno
import os
import stat
import subprocess
import sys
from pathlib import Path

ACL_TYPE_EXTENDED = 0x00000100
SYSTEM_PROVENANCE = "com.apple.provenance"
XATTR_SHOWCOMPRESSION = 0x0020

root = Path(sys.argv[1])
expected_root = (int(sys.argv[2]), int(sys.argv[3]))
mode = sys.argv[4]
if mode not in {"normalize", "validate"}:
    raise SystemExit("native msplat metadata mode is invalid")

libc = ctypes.CDLL(None, use_errno=True)
flistxattr = libc.flistxattr
flistxattr.argtypes = (
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_int,
)
flistxattr.restype = ctypes.c_ssize_t
acl_get_fd = libc.acl_get_fd_np
acl_get_fd.argtypes = (ctypes.c_int, ctypes.c_int)
acl_get_fd.restype = ctypes.c_void_p
acl_free = libc.acl_free
acl_free.argtypes = (ctypes.c_void_p,)
acl_free.restype = ctypes.c_int


def attribute_names(descriptor: int) -> tuple[str, ...]:
    ctypes.set_errno(0)
    size = flistxattr(descriptor, None, 0, XATTR_SHOWCOMPRESSION)
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size == 0:
        return ()
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    actual = flistxattr(descriptor, buffer, size, XATTR_SHOWCOMPRESSION)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if actual != size:
        raise OSError("extended attribute list changed during audit")
    return tuple(
        sorted(
            os.fsdecode(name)
            for name in bytes(buffer.raw[:actual]).split(b"\0")
            if name
        )
    )


def has_extended_acl(descriptor: int) -> bool:
    ctypes.set_errno(0)
    acl = acl_get_fd(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return False
        raise OSError(error, os.strerror(error))
    if acl_free(acl) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return True


paths = [root]
for current, directory_names, file_names in os.walk(root, followlinks=False):
    directory_names.sort()
    file_names.sort()
    current_path = Path(current)
    paths.extend(current_path / name for name in directory_names)
    paths.extend(current_path / name for name in file_names)

records = []
try:
    for path in paths:
        before = os.lstat(path)
        if stat.S_ISDIR(before.st_mode):
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        elif stat.S_ISREG(before.st_mode):
            if before.st_nlink != 1:
                raise SystemExit(
                    "native msplat metadata audit rejects a multiply linked "
                    f"file: {path}"
                )
            flags = os.O_RDONLY
        else:
            raise SystemExit(
                "native msplat metadata audit rejects an unsupported entry: "
                f"{path}"
            )
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            os.close(descriptor)
            raise SystemExit(f"native msplat metadata entry changed: {path}")
        if path == root and (opened.st_dev, opened.st_ino) != expected_root:
            os.close(descriptor)
            raise SystemExit("native msplat install stage owned identity changed")
        records.append((path, descriptor, opened))

    bound_attributes = []
    for path, descriptor, _ in records:
        if has_extended_acl(descriptor):
            raise SystemExit(f"native msplat install has an extended ACL: {path}")
        names = attribute_names(descriptor)
        unexpected = tuple(name for name in names if name != SYSTEM_PROVENANCE)
        if unexpected:
            raise SystemExit(
                "native msplat install has an unexpected extended attribute: "
                f"{unexpected[0]} on {path}"
            )
        if mode == "validate" and names:
            raise SystemExit(f"native msplat install has extended attributes: {path}")
        bound_attributes.append((path, descriptor, names))

finally:
    for _, descriptor, _ in reversed(records):
        os.close(descriptor)

root_after = os.lstat(root)
if (root_after.st_dev, root_after.st_ino) != expected_root:
    raise SystemExit("native msplat install stage changed during metadata audit")
if mode == "normalize":
    for path, _, expected in reversed(records):
        named = os.lstat(path)
        if (named.st_dev, named.st_ino) != (expected.st_dev, expected.st_ino):
            raise SystemExit(f"native msplat metadata entry changed: {path}")
        if stat.S_ISDIR(expected.st_mode):
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        else:
            flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            names = attribute_names(descriptor)
        finally:
            os.close(descriptor)
        if names:
            removal = subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-s",
                    "-d",
                    SYSTEM_PROVENANCE,
                    os.fspath(path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if removal.returncode != 0:
                raise SystemExit(
                    "native msplat system provenance cleanup failed: "
                    f"{path}: {removal.stderr.strip()}"
                )
        named_after = os.lstat(path)
        if (named_after.st_dev, named_after.st_ino) != (
            expected.st_dev,
            expected.st_ino,
        ):
            raise SystemExit(
                f"native msplat metadata entry changed during cleanup: {path}"
            )

    for path, _, expected in records:
        if stat.S_ISDIR(expected.st_mode):
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        else:
            flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            reopened = os.fstat(descriptor)
            if (reopened.st_dev, reopened.st_ino) != (
                expected.st_dev,
                expected.st_ino,
            ):
                raise SystemExit(
                    f"native msplat metadata entry changed after cleanup: {path}"
                )
            remaining = attribute_names(descriptor)
            if remaining:
                raise SystemExit(
                    "native msplat metadata normalization was incomplete: "
                    f"{path} ({remaining})"
                )
        finally:
            os.close(descriptor)
PY
}

normalize_stage_system_metadata() {
  audit_stage_extended_metadata normalize
}

validate_stage_extended_metadata() {
  audit_stage_extended_metadata validate
}

validate_stage() {
  local binary="$STAGE_DIR/bin/easysplat-train"
  local metallib="$STAGE_DIR/bin/default.metallib"
  local actual_files expected_files self_check
  [ -x "$binary" ] || die "staged CLI is not executable"
  [ -s "$metallib" ] || die "staged metallib is empty"
  [ -s "$STAGE_DIR/LICENSE" ] || die "staged license is empty"
  [ -s "$STAGE_DIR/build_info.json" ] || die "staged provenance is empty"
  /usr/bin/file -b "$binary" | grep -q 'Mach-O 64-bit executable arm64' || die "staged CLI is not arm64 Mach-O"
  reject_raster_test_symbols "$binary"
  /usr/bin/otool -L "$binary" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *) die "staged CLI has a non-system dynamic dependency: $dependency" ;;
    esac
  done

  actual_files="$(cd "$STAGE_DIR" && find . -type f -print | LC_ALL=C sort)"
  expected_files=$'./LICENSE\n./bin/default.metallib\n./bin/easysplat-train\n./build_info.json'
  [ "$actual_files" = "$expected_files" ] || die "unexpected staged files"

  if ! "$PYTHON_BIN" - "$STAGE_DIR/build_info.json" "$(sha256 "$binary")" "$(sha256 "$metallib")" <<'PY'
import json
import sys


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


try:
    with open(sys.argv[1], encoding="utf-8") as source:
        payload = json.load(source, parse_constant=reject_constant)
except (OSError, UnicodeError, ValueError) as exc:
    raise SystemExit(f"invalid build provenance JSON: {exc}") from exc

if not isinstance(payload, dict):
    raise SystemExit("build provenance must be a JSON object")
if payload.get("executable_sha256") != sys.argv[2]:
    raise SystemExit("executable provenance hash mismatch")
if payload.get("metallib_sha256") != sys.argv[3]:
    raise SystemExit("metallib provenance hash mismatch")
PY
  then
    die "provenance validation failed"
  fi
  if grep -Eq '(/Users/|/home/|"hostname"|"username"|"source_path")' "$STAGE_DIR/build_info.json"; then
    die "provenance contains private or machine-local data"
  fi

  self_check="$("$binary" --self-check --events-fd 1)"
  [ "$(printf '%s\n' "$self_check" | wc -l | tr -d ' ')" = "1" ] || die "self-check did not emit exactly one JSON line"
  grep -Fq '"event":"self_check"' <<<"$self_check" || die "self-check event missing"
  grep -Fq '"status":"ok"' <<<"$self_check" || die "self-check status missing"
  grep -Fq '"scene_bounds_status":"ok"' <<<"$self_check" || die "scene-bounds self-check status missing"
}

promote_install() {
  local journal="$STAGE_DIR.promotion-state" tree_receipt
  validate_stage_extended_metadata
  tree_receipt="$("$PYTHON_BIN" "$PROMOTER" --tree-receipt \
    "$STAGE_DIR" "$INSTALL_STAGE_DEVICE" "$INSTALL_STAGE_INODE")" || \
    die "could not bind the validated native msplat tree"
  validate_stage_extended_metadata
  STAGE_CLEANUP_ALLOWED=0
  "$PYTHON_BIN" "$PROMOTER" "$STAGE_DIR" "$INSTALL_DIR" "$tree_receipt" || \
    die "could not promote staged install; recovery state preserved"
  "$PYTHON_BIN" "$PROMOTER" --commit "$journal" || \
    die "could not finalize staged install; recovery state preserved"
}

preflight
mkdir -p "$BUILD_DIR" "$INSTALL_PARENT"
recover_stale_promotions
create_owned_install_stage
prepare_dependencies
prepare_source
configure_and_build
stage_install
normalize_stage_system_metadata
validate_stage
validate_stage_extended_metadata
promote_install

echo "native msplat ready at $INSTALL_DIR"
