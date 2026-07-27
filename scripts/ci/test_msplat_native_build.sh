#!/usr/bin/env bash
# Source-contract assertions intentionally match literal shell expressions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/toolchain/build_msplat.sh"
ATOMIC_PROMOTER="$ROOT/scripts/toolchain/atomic_swap_install.py"
OVERLAY="$ROOT/Tools/MsplatNative/msplat.cpp"
RASTER_TEST_SOURCE="$ROOT/Tools/MsplatNative/msplat_raster_tests.cpp"
ISOLATION_HEADER="$ROOT/Tools/MsplatNative/isolation.hpp"
ISOLATION_SOURCE="$ROOT/Tools/MsplatNative/isolation.cpp"
ISOLATION_RUNTIME_HEADER="$ROOT/Tools/MsplatNative/isolation_runtime.hpp"
ISOLATION_RUNTIME_SOURCE="$ROOT/Tools/MsplatNative/isolation_runtime.cpp"
ISOLATION_MASK_HEADER="$ROOT/Tools/MsplatNative/isolation_mask.hpp"
ISOLATION_MASK_SOURCE="$ROOT/Tools/MsplatNative/isolation_mask.mm"
ISOLATION_METAL_SOURCE="$ROOT/Tools/MsplatNative/isolation_lift.metal"
ISOLATION_TEST_SOURCE="$ROOT/Tools/MsplatNative/isolation_tests.cpp"
ISOLATION_MASK_TEST_SOURCE="$ROOT/Tools/MsplatNative/isolation_mask_tests.mm"
APACHE_LICENSE="$ROOT/ThirdParty/LICENSES/Apache-2.0.txt"
MSPLAT_NOTICE="$ROOT/Tools/MsplatNative/NOTICE.md"
UPSTREAM_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-easysplat.patch"
SOURCE_NOTICE_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-source-notices.patch"
CHECKPOINT_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-checkpoint.patch"
NUMERIC_STABILITY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-numeric-stability.patch"
METAL_SAFETY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-metal-safety.patch"
EXACT_RASTER_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-raster.patch"
STAGE_TIMING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-stage-timing.patch"
MEMORY_EFFICIENCY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-memory-efficiency.patch"
DENSIFICATION_MEMORY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-densification-memory.patch"
ROW_SPAN_CULLING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-row-span-culling.patch"
GEOMETRY_ADAM_FUSION_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-geometry-adam-fusion.patch"
PARALLEL_RADIX_SCAN_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-parallel-radix-scan.patch"
ALLOCATION_PRESSURE_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-allocation-pressure.patch"
EXACT_PREFIX_HARDENING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-prefix-hardening.patch"
QUATERNION_STABILITY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-quaternion-stability.patch"
ISOLATION_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-isolation.patch"
DENSITY_CONTROL_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-density-control.patch"
TILE_SPAN_TEST_ROOT="$ROOT/Tools/MsplatNative/TileSpanTests"
FIXTURE_GENERATOR="$ROOT/scripts/ci/generate_msplat_sparse_fixtures.py"
VALIDATOR="$ROOT/scripts/toolchain/validate_native_msplat.sh"
SWIFT_VALIDATOR="$ROOT/EasySplatCore/Sources/EasySplatCore/Tools/ToolchainManager+Validation.swift"
SWIFT_FIXTURE="$ROOT/EasySplatCore/Tests/EasySplatCoreTests/ToolchainFixtureBuilder.swift"
INSTALL_DIR="${EASYSPLAT_MSPLAT_INSTALL_DIR:-$ROOT/Toolchains/build/msplat/install/msplat}"
RASTER_TEST_BIN="${EASYSPLAT_MSPLAT_RASTER_TEST_BIN:-$ROOT/Toolchains/build/msplat/native-build/msplat_raster_tests}"
NATIVE_BUILD_DIR="${EASYSPLAT_MSPLAT_NATIVE_BUILD_DIR:-$ROOT/Toolchains/build/msplat/native-build}"
ALLOCATION_PRESSURE_TEST_BIN="$NATIVE_BUILD_DIR/msplat_allocation_pressure_cli"
ISOLATION_TEST_BIN="$NATIVE_BUILD_DIR/msplat_isolation_tests"
ISOLATION_MASK_TEST_BIN="$NATIVE_BUILD_DIR/msplat_isolation_mask_tests"

fail() {
  echo "native msplat build contract failed: $*" >&2
  exit 1
}

require_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "$file is missing: $needle"
}

require_absent() {
  local needle="$1"
  local file="$2"
  if grep -Fiq -- "$needle" "$file"; then
    fail "$file still contains forbidden text: $needle"
  fi
}

require_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

require_order() {
  local first="$1"
  local second="$2"
  local file="$3"
  local first_line second_line
  first_line="$(grep -Fn -- "$first" "$file" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -Fn -- "$second" "$file" | head -n 1 | cut -d: -f1)"
  [ -n "$first_line" ] || fail "$file is missing ordered contract: $first"
  [ -n "$second_line" ] || fail "$file is missing ordered contract: $second"
  [ "$first_line" -lt "$second_line" ] \
    || fail "$file applies contracts out of order: $first must precede $second"
}

require_sha256_pin() {
  local variable="$1"
  local source="$2"
  local expected
  expected="$(shasum -a 256 "$source" | awk '{print $1}')"
  require_contains "${variable}_SHA256=\"$expected\"" "$BUILD_SCRIPT"
  require_contains \
    '[ "$(sha256 "$'"$variable"'")" = "$'"${variable}"'_SHA256" ]' \
    "$BUILD_SCRIPT"
}

require_json_hash() {
  local key="$1"
  local source="$2"
  local file="$3"
  local expected
  expected="$(shasum -a 256 "$source" | awk '{print $1}')"
  require_contains "\"$key\": \"$expected\"" "$file"
}

require_file "$BUILD_SCRIPT"
require_file "$ATOMIC_PROMOTER"
require_file "$OVERLAY"
require_file "$RASTER_TEST_SOURCE"
for source in \
  "$ISOLATION_HEADER" \
  "$ISOLATION_SOURCE" \
  "$ISOLATION_RUNTIME_HEADER" \
  "$ISOLATION_RUNTIME_SOURCE" \
  "$ISOLATION_MASK_HEADER" \
  "$ISOLATION_MASK_SOURCE" \
  "$ISOLATION_METAL_SOURCE" \
  "$ISOLATION_TEST_SOURCE" \
  "$ISOLATION_MASK_TEST_SOURCE"; do
  require_file "$source"
done
require_file "$APACHE_LICENSE"
require_file "$MSPLAT_NOTICE"
require_file "$UPSTREAM_PATCH"
require_file "$SOURCE_NOTICE_PATCH"
require_file "$CHECKPOINT_PATCH"
require_file "$NUMERIC_STABILITY_PATCH"
require_file "$METAL_SAFETY_PATCH"
require_file "$EXACT_RASTER_PATCH"
require_file "$STAGE_TIMING_PATCH"
require_file "$MEMORY_EFFICIENCY_PATCH"
require_file "$DENSIFICATION_MEMORY_PATCH"
require_file "$ROW_SPAN_CULLING_PATCH"
require_file "$GEOMETRY_ADAM_FUSION_PATCH"
require_file "$PARALLEL_RADIX_SCAN_PATCH"
require_file "$ALLOCATION_PRESSURE_PATCH"
require_file "$EXACT_PREFIX_HARDENING_PATCH"
require_file "$QUATERNION_STABILITY_PATCH"
require_file "$ISOLATION_PATCH"
require_file "$DENSITY_CONTROL_PATCH"
for source in \
  "$TILE_SPAN_TEST_ROOT/include/tile_culling.hpp" \
  "$TILE_SPAN_TEST_ROOT/include/gpu_tile_culling.hpp" \
  "$TILE_SPAN_TEST_ROOT/src/tile_culling.metal" \
  "$TILE_SPAN_TEST_ROOT/src/gpu_tile_culling.mm" \
  "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp" \
  "$TILE_SPAN_TEST_ROOT/tests/gpu_tile_culling_tests.mm"; do
  require_file "$source"
done
require_file "$FIXTURE_GENERATOR"
require_file "$VALIDATOR"
require_file "$SWIFT_VALIDATOR"
require_file "$SWIFT_FIXTURE"

require_contains 'MSPLAT_REPO="https://github.com/rayanht/msplat.git"' "$BUILD_SCRIPT"
require_contains 'MSPLAT_COMMIT="106499b0a53f82b0c92d013b0861fbebd341b17e"' "$BUILD_SCRIPT"
require_contains 'MSPLAT_VERSION="1.1.3"' "$BUILD_SCRIPT"
require_contains 'Apache License' "$APACHE_LICENSE"
require_contains 'Version 2.0, January 2004' "$APACHE_LICENSE"
[ "$(shasum -a 256 "$APACHE_LICENSE" | awk '{print $1}')" = \
  "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30" ] \
  || fail "Apache-2.0 license text is not the canonical upstream text"
require_contains 'Copyright 2025 Rayan Hatout' "$MSPLAT_NOTICE"
require_contains '106499b0a53f82b0c92d013b0861fbebd341b17e' "$MSPLAT_NOTICE"
require_contains 'Modified by the EasySplat project in 2026 from msplat 1.1.3.' "$OVERLAY"
require_contains 'Modified by the EasySplat project in 2026 from msplat 1.1.3.' "$RASTER_TEST_SOURCE"
for source in \
  "$ISOLATION_HEADER" \
  "$ISOLATION_SOURCE" \
  "$ISOLATION_RUNTIME_HEADER" \
  "$ISOLATION_RUNTIME_SOURCE" \
  "$ISOLATION_MASK_HEADER" \
  "$ISOLATION_MASK_SOURCE" \
  "$ISOLATION_METAL_SOURCE" \
  "$ISOLATION_TEST_SOURCE" \
  "$ISOLATION_MASK_TEST_SOURCE"; do
  require_contains \
    'Modified by the EasySplat project in 2026 from msplat 1.1.3.' \
    "$source"
done
[ "$(grep -Fc 'Modified by the EasySplat project in 2026 from msplat 1.1.3.' "$SOURCE_NOTICE_PATCH")" -eq 10 ] \
  || fail "msplat patch does not mark every modified upstream source"
require_contains 'UPSTREAM_PATCH_SHA256="047ef2547d4478bc77a7a1537284e58fdb20de4c52c5c37982674fa2af70927e"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$UPSTREAM_PATCH")" = "$UPSTREAM_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'SOURCE_NOTICE_PATCH_SHA256="6deee598c9321c9b98d74b92fd5cce9808069a7a63effcd80615eb7d208d2ffb"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$SOURCE_NOTICE_PATCH")" = "$SOURCE_NOTICE_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --unidiff-zero --check "$SOURCE_NOTICE_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --unidiff-zero "$SOURCE_NOTICE_PATCH"' "$BUILD_SCRIPT"
require_sha256_pin "OVERLAY" "$OVERLAY"
require_contains '[ "$(sha256 "$OVERLAY")" = "$OVERLAY_SHA256" ]' "$BUILD_SCRIPT"
require_json_hash "overlay_sha256" "$OVERLAY" "$VALIDATOR"
require_contains '"patch_sha256": "047ef2547d4478bc77a7a1537284e58fdb20de4c52c5c37982674fa2af70927e"' "$VALIDATOR"
require_contains '"source_notice_patch_sha256": "6deee598c9321c9b98d74b92fd5cce9808069a7a63effcd80615eb7d208d2ffb"' "$VALIDATOR"
require_contains 'RASTER_TEST_SHA256="60f4eea65d5be2ad8684292e8234fbce97ab330d5c1e0946d6b2e00a91957dcf"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$RASTER_TEST_SOURCE")" = "$RASTER_TEST_SHA256" ]' "$BUILD_SCRIPT"
for source_contract in \
  "ISOLATION_HEADER:$ISOLATION_HEADER" \
  "ISOLATION_SOURCE:$ISOLATION_SOURCE" \
  "ISOLATION_RUNTIME_HEADER:$ISOLATION_RUNTIME_HEADER" \
  "ISOLATION_RUNTIME_SOURCE:$ISOLATION_RUNTIME_SOURCE" \
  "ISOLATION_MASK_HEADER:$ISOLATION_MASK_HEADER" \
  "ISOLATION_MASK_SOURCE:$ISOLATION_MASK_SOURCE" \
  "ISOLATION_METAL_SOURCE:$ISOLATION_METAL_SOURCE" \
  "ISOLATION_TEST_SOURCE:$ISOLATION_TEST_SOURCE" \
  "ISOLATION_MASK_TEST_SOURCE:$ISOLATION_MASK_TEST_SOURCE" \
  "ISOLATION_PATCH:$ISOLATION_PATCH" \
  "DENSITY_CONTROL_PATCH:$DENSITY_CONTROL_PATCH"; do
  require_sha256_pin \
    "${source_contract%%:*}" \
    "${source_contract#*:}"
done
require_json_hash "isolation_header_sha256" "$ISOLATION_HEADER" "$VALIDATOR"
require_json_hash "isolation_source_sha256" "$ISOLATION_SOURCE" "$VALIDATOR"
require_json_hash "isolation_runtime_header_sha256" "$ISOLATION_RUNTIME_HEADER" "$VALIDATOR"
require_json_hash "isolation_runtime_source_sha256" "$ISOLATION_RUNTIME_SOURCE" "$VALIDATOR"
require_json_hash "isolation_mask_header_sha256" "$ISOLATION_MASK_HEADER" "$VALIDATOR"
require_json_hash "isolation_mask_source_sha256" "$ISOLATION_MASK_SOURCE" "$VALIDATOR"
require_json_hash "isolation_lift_source_sha256" "$ISOLATION_METAL_SOURCE" "$VALIDATOR"
require_json_hash "isolation_test_sha256" "$ISOLATION_TEST_SOURCE" "$VALIDATOR"
require_json_hash "isolation_mask_test_sha256" "$ISOLATION_MASK_TEST_SOURCE" "$VALIDATOR"
require_json_hash "isolation_patch_sha256" "$ISOLATION_PATCH" "$VALIDATOR"
require_json_hash "density_control_patch_sha256" "$DENSITY_CONTROL_PATCH" "$VALIDATOR"
for key in \
  isolation_header_sha256 \
  isolation_source_sha256 \
  isolation_runtime_header_sha256 \
  isolation_runtime_source_sha256 \
  isolation_mask_header_sha256 \
  isolation_mask_source_sha256 \
  isolation_lift_source_sha256 \
  isolation_test_sha256 \
  isolation_mask_test_sha256 \
  isolation_patch_sha256 \
  density_control_patch_sha256; do
  require_contains "$key" "$BUILD_SCRIPT"
  require_contains "$key" "$VALIDATOR"
done
require_contains 'cp "$ISOLATION_HEADER" "$SOURCE_DIR/cli/isolation.hpp"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_SOURCE" "$SOURCE_DIR/cli/isolation.cpp"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_RUNTIME_HEADER" "$SOURCE_DIR/cli/isolation_runtime.hpp"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_RUNTIME_SOURCE" "$SOURCE_DIR/cli/isolation_runtime.cpp"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_MASK_HEADER" "$SOURCE_DIR/cli/isolation_mask.hpp"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_MASK_SOURCE" "$SOURCE_DIR/cli/isolation_mask.mm"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_METAL_SOURCE" "$SOURCE_DIR/core/metal/isolation_lift.metal"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_TEST_SOURCE" "$SOURCE_DIR/tests/isolation_tests.cpp"' "$BUILD_SCRIPT"
require_contains 'cp "$ISOLATION_MASK_TEST_SOURCE" "$SOURCE_DIR/tests/isolation_mask_tests.mm"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$ISOLATION_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$ISOLATION_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$DENSITY_CONTROL_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$DENSITY_CONTROL_PATCH"' "$BUILD_SCRIPT"
require_order \
  'git -C "$SOURCE_DIR" apply "$QUATERNION_STABILITY_PATCH"' \
  'git -C "$SOURCE_DIR" apply --check "$ISOLATION_PATCH"' \
  "$BUILD_SCRIPT"
require_contains 'set(ISOLATION_METAL_SOURCE ${CMAKE_SOURCE_DIR}/core/metal/isolation_lift.metal)' "$ISOLATION_PATCH"
require_contains 'add_executable(msplat ${EASYSPLAT_CLI_SOURCES})' "$ISOLATION_PATCH"
require_contains \
  'add_executable(msplat_allocation_pressure_cli ${EASYSPLAT_CLI_SOURCES})' \
  "$ISOLATION_PATCH"
require_contains 'cli/isolation_runtime.cpp' "$ISOLATION_PATCH"
require_contains 'cli/isolation_mask.mm' "$ISOLATION_PATCH"
require_contains 'add_executable(' "$ISOLATION_PATCH"
require_contains 'msplat_isolation_tests' "$ISOLATION_PATCH"
require_contains 'msplat_isolation_mask_tests' "$ISOLATION_PATCH"
require_contains 'msplat_prepare_isolation_view' "$ISOLATION_PATCH"
require_contains 'msplat_lift_isolation_stripe' "$ISOLATION_PATCH"
require_contains 'isolation_lift_stripe_kernel' "$ISOLATION_PATCH"
require_absent '#include "model.hpp"' "$ISOLATION_RUNTIME_SOURCE"
require_absent 'Model model(' "$ISOLATION_RUNTIME_SOURCE"
require_contains \
  'isolationDataset / "sparse" / "0"' \
  "$OVERLAY"
require_contains \
  'isolationDataset / "images"' \
  "$OVERLAY"
require_contains 'requirePlainDirectory(isolationDataset);' "$OVERLAY"
require_contains 'requirePlainDirectory(isolationDataset / "sparse");' "$OVERLAY"
require_contains 'requirePlainDirectory(canonicalSparse);' "$OVERLAY"
require_contains 'requirePlainDirectory(canonicalImages);' "$OVERLAY"
require_contains \
  'snapshot.sparsePath().string(),' \
  "$OVERLAY"
require_contains \
  'snapshot.imagesPath().string()' \
  "$OVERLAY"
require_contains \
  'InputData inputData = loaders::loadColmap(' \
  "$OVERLAY"
require_contains 'class IsolationDatasetSnapshot' "$OVERLAY"
require_contains 'copyAuthenticatedFile(' "$OVERLAY"
require_contains 'verifySnapshotIdentity(' "$OVERLAY"
require_contains 'IsolationDatasetSnapshot snapshot(' "$OVERLAY"
require_contains 'claimIsolationSnapshotRoot(' "$OVERLAY"
require_contains 'removeIsolationSnapshotContentsAt(' "$OVERLAY"
require_contains '::renameatx_np(' "$OVERLAY"
require_contains '::fstatat(' "$OVERLAY"
require_contains '::openat(' "$OVERLAY"
require_contains '::unlinkat(' "$OVERLAY"
require_absent 'fs::remove_all(root_' "$OVERLAY"
require_absent \
  'loaders::loadColmap(\n                canonicalSparse.string()' \
  "$OVERLAY"
require_contains \
  'const TrainingIdentity loadedIdentity = computeTrainingIdentity(' \
  "$OVERLAY"
require_contains 'snapshot.rootPath(),' "$OVERLAY"
require_contains 'stableColmapRecordCount(' "$OVERLAY"
require_contains 'enforceIsolationColmapLoadBudget(' "$OVERLAY"
require_contains 'imageParserBytesPerInputByte = 2;' "$OVERLAY"
require_contains \
  'requiredBytes += imageBytes * imageParserBytesPerInputByte;' \
  "$OVERLAY"
require_contains \
  '"COLMAP loader allocation exceeds the isolation memory budget"' \
  "$OVERLAY"
require_contains 'app.parse(argc, argv);' "$OVERLAY"
require_contains 'scanPreparseIntent(argc, argv)' "$OVERLAY"
require_contains 'maximumPreparseArgumentCount = 4096' "$OVERLAY"
require_contains 'maximumPreparseTokenBytes = 128' "$OVERLAY"
require_contains 'if (*token == "--") break;' "$OVERLAY"
require_contains 'suppressParseDiagnostics' "$OVERLAY"
require_contains 'CLI::detail::lexical_cast(' "$OVERLAY"
require_absent '*token == "--events-fd=1"' "$OVERLAY"
require_contains 'const int parserExit = app.exit(' "$OVERLAY"
require_contains 'capturedStandardOutput,' "$OVERLAY"
require_contains 'capturedStandardError' "$OVERLAY"
require_contains 'emitCapturedParseDiagnostics(' "$OVERLAY"
require_absent 'EventsDescriptorIntent' "$OVERLAY"
require_absent 'app.exit(error);' "$OVERLAY"
require_contains 'return parserExit == 0 ? 0 : 1;' "$OVERLAY"
require_absent 'CLI11_PARSE(app, argc, argv);' "$OVERLAY"
require_contains 'inspectBinaryPlyHeader(' "$ISOLATION_RUNTIME_SOURCE"
require_contains 'validateBinaryPlyRows(' "$ISOLATION_RUNTIME_SOURCE"
require_order \
  'enforceMemoryBudget(requiredBytes, request.memoryBudgetBytes);' \
  'validateBinaryPlyRows(source, isCancelled);' \
  "$ISOLATION_RUNTIME_SOURCE"
require_contains 'eventFileIdentity' "$ISOLATION_RUNTIME_HEADER"
require_contains 'boundEventFileIdentity' "$OVERLAY"
require_contains 'rejectEventDescriptorAliases(' "$OVERLAY"
require_contains 'request.eventFileIdentity' "$ISOLATION_RUNTIME_SOURCE"
require_contains 'eventsFileDescriptor == STDERR_FILENO' "$OVERLAY"
require_contains 'filteringUnitTotal' "$ISOLATION_RUNTIME_SOURCE"
require_absent '{"completed_unit_count", 0}' "$ISOLATION_RUNTIME_SOURCE"
require_absent '{"total_unit_count", 1}' "$ISOLATION_RUNTIME_SOURCE"
require_contains \
  'cmake --build "$NATIVE_BUILD_DIR" --target msplat metallib msplat_raster_tests msplat_isolation_tests msplat_isolation_mask_tests' \
  "$BUILD_SCRIPT"
require_contains '"$NATIVE_BUILD_DIR/msplat_isolation_tests"' "$BUILD_SCRIPT"
require_contains '"$NATIVE_BUILD_DIR/msplat_isolation_mask_tests"' "$BUILD_SCRIPT"
require_contains 'NLOHMANN_JSON_SHA256="04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069"' "$BUILD_SCRIPT"
require_contains 'NANOFLANN_SHA256="57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc"' "$BUILD_SCRIPT"
require_contains 'CLI11_SHA256="43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0"' "$BUILD_SCRIPT"
require_contains 'FETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON' "$BUILD_SCRIPT"
require_contains 'FETCHCONTENT_SOURCE_DIR_NANOFLANN' "$BUILD_SCRIPT"
require_contains 'FETCHCONTENT_SOURCE_DIR_CLI11' "$BUILD_SCRIPT"
require_contains 'GIT_LFS_SKIP_SMUDGE=1' "$BUILD_SCRIPT"
require_contains 'GIT_LFS_SKIP_SMUDGE=1 git -C "$SOURCE_DIR" checkout' "$BUILD_SCRIPT"
require_contains 'config filter.lfs.process ""' "$BUILD_SCRIPT"
require_contains 'ls-tree -r --full-tree' "$BUILD_SCRIPT"
require_contains 'xcodebuild -downloadComponent MetalToolchain' "$BUILD_SCRIPT"
require_contains 'CMAKE_OSX_ARCHITECTURES=arm64' "$BUILD_SCRIPT"
require_contains 'CMAKE_OSX_DEPLOYMENT_TARGET=15.0' "$BUILD_SCRIPT"
require_contains 'promote_install' "$BUILD_SCRIPT"
require_contains 'build_info.json' "$BUILD_SCRIPT"
require_contains 'default.metallib' "$BUILD_SCRIPT"
require_contains 'easysplat-train' "$BUILD_SCRIPT"
require_contains 'msplat-1.1.3-easysplat.patch' "$BUILD_SCRIPT"
require_contains 'msplat-1.1.3-checkpoint.patch' "$BUILD_SCRIPT"
require_contains 'msplat-1.1.3-numeric-stability.patch' "$BUILD_SCRIPT"
require_contains 'NUMERIC_STABILITY_PATCH_SHA256="231586b17e4f47c8c55432a631e08bf293b31a92f8d6ec49b367d11632350ec3"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$NUMERIC_STABILITY_PATCH")" = "$NUMERIC_STABILITY_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --unidiff-zero --check "$NUMERIC_STABILITY_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --unidiff-zero "$NUMERIC_STABILITY_PATCH"' "$BUILD_SCRIPT"
require_contains 'numeric_stability_patch_sha256' "$BUILD_SCRIPT"
require_contains '"numeric_stability_patch_sha256": "231586b17e4f47c8c55432a631e08bf293b31a92f8d6ec49b367d11632350ec3"' "$VALIDATOR"
require_contains 'msplat-1.1.3-metal-safety.patch' "$BUILD_SCRIPT"
require_contains 'METAL_SAFETY_PATCH_SHA256="5d3dfff3edcbca940d37f6ee3145c76c678ebd36ebc03016cfd5dab78e1d45ac"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$METAL_SAFETY_PATCH")" = "$METAL_SAFETY_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --unidiff-zero --check "$METAL_SAFETY_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --unidiff-zero "$METAL_SAFETY_PATCH"' "$BUILD_SCRIPT"
require_contains 'metal_safety_patch_sha256' "$BUILD_SCRIPT"
require_contains '"metal_safety_patch_sha256": "5d3dfff3edcbca940d37f6ee3145c76c678ebd36ebc03016cfd5dab78e1d45ac"' "$VALIDATOR"
require_contains 'msplat-1.1.3-exact-raster.patch' "$BUILD_SCRIPT"
require_contains 'EXACT_RASTER_PATCH_SHA256="c34a8860ed8ae9bc92c976aaa1c3f89eec8aa9be9cab4778f074491e98860855"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$EXACT_RASTER_PATCH")" = "$EXACT_RASTER_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$EXACT_RASTER_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$EXACT_RASTER_PATCH"' "$BUILD_SCRIPT"
require_contains 'exact_raster_patch_sha256' "$BUILD_SCRIPT"
require_contains 'exact_raster_patch_sha256' "$VALIDATOR"
require_contains 'msplat-1.1.3-stage-timing.patch' "$BUILD_SCRIPT"
require_contains 'STAGE_TIMING_PATCH_SHA256="fcc00c8b9eb3c79ccc7be3f27b997421b28e2c0ea98477c4382d7acefd334435"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$STAGE_TIMING_PATCH")" = "$STAGE_TIMING_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$STAGE_TIMING_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$STAGE_TIMING_PATCH"' "$BUILD_SCRIPT"
require_contains 'stage_timing_patch_sha256' "$BUILD_SCRIPT"
require_contains '"stage_timing_patch_sha256": "fcc00c8b9eb3c79ccc7be3f27b997421b28e2c0ea98477c4382d7acefd334435"' "$VALIDATOR"
require_contains 'msplat-1.1.3-memory-efficiency.patch' "$BUILD_SCRIPT"
require_contains 'MEMORY_EFFICIENCY_PATCH_SHA256="bfacc105454e80102139f120dd6375037360c6a9763f1e1f708aa2a7f22eca6c"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$MEMORY_EFFICIENCY_PATCH")" = "$MEMORY_EFFICIENCY_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$MEMORY_EFFICIENCY_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$MEMORY_EFFICIENCY_PATCH"' "$BUILD_SCRIPT"
require_contains 'memory_efficiency_patch_sha256' "$BUILD_SCRIPT"
require_contains '"memory_efficiency_patch_sha256": "bfacc105454e80102139f120dd6375037360c6a9763f1e1f708aa2a7f22eca6c"' "$VALIDATOR"
require_contains 'MTensor {}, MTensor {}, v_opacity' "$MEMORY_EFFICIENCY_PATCH"
require_contains 'constexpr float kSphericalHarmonicDc' "$MEMORY_EFFICIENCY_PATCH"
require_contains 'iw, 9}, DType::Float32' "$MEMORY_EFFICIENCY_PATCH"
require_contains 'DENSIFICATION_MEMORY_PATCH_SHA256="b429540372d807f280929ebba1670257990bd36b28dfee5b42bc377ccef60ac7"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$DENSIFICATION_MEMORY_PATCH")" = "$DENSIFICATION_MEMORY_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$DENSIFICATION_MEMORY_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$DENSIFICATION_MEMORY_PATCH"' "$BUILD_SCRIPT"
require_contains 'densification_memory_patch_sha256' "$BUILD_SCRIPT"
require_contains '"densification_memory_patch_sha256": "b429540372d807f280929ebba1670257990bd36b28dfee5b42bc377ccef60ac7"' "$VALIDATOR"
require_contains 'ensureDensificationCompactScratch' "$DENSIFICATION_MEMORY_PATCH"
require_contains 'densify_compact_scratch.reset()' "$DENSIFICATION_MEMORY_PATCH"
require_contains 'densification scratch lifecycle passed' "$RASTER_TEST_SOURCE"
require_contains 'ROW_SPAN_CULLING_PATCH_SHA256="481c4c9a70f1da5eb1590b20a64e25a3c64bb3c19f14e27996ab9b25a119594d"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$ROW_SPAN_CULLING_PATCH")" = "$ROW_SPAN_CULLING_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$ROW_SPAN_CULLING_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$ROW_SPAN_CULLING_PATCH"' "$BUILD_SCRIPT"
require_contains 'row_span_culling_patch_sha256' "$BUILD_SCRIPT"
require_contains '"row_span_culling_patch_sha256": "481c4c9a70f1da5eb1590b20a64e25a3c64bb3c19f14e27996ab9b25a119594d"' "$VALIDATOR"
require_contains 'static constexpr uint32_t g_tile_culling_min_area_for_testing = 4' "$ROW_SPAN_CULLING_PATCH"
require_contains 'power_limit = log(scaled_opacity)' "$ROW_SPAN_CULLING_PATCH"
require_contains 'count_exact_tile_intersections_kernel' "$ROW_SPAN_CULLING_PATCH"
require_contains 'ellipse_tile_row_span' "$ROW_SPAN_CULLING_PATCH"
require_contains 'determinant_lower = nextafter' "$ROW_SPAN_CULLING_PATCH"
require_contains '8.0f * FLT_EPSILON * determinant_scale' "$ROW_SPAN_CULLING_PATCH"
require_absent 'ellipse_intersects_pixel_tile' "$ROW_SPAN_CULLING_PATCH"
require_absent 'min(4.5' "$ROW_SPAN_CULLING_PATCH"
require_contains 'msplat-1.1.3-geometry-adam-fusion.patch' "$BUILD_SCRIPT"
require_contains 'GEOMETRY_ADAM_FUSION_PATCH_SHA256="927ad1fdbffee7ad762396c7acc965cd4a20da781f172240c62aa94f41e1cd2c"' "$BUILD_SCRIPT"
actual_geometry_adam_fusion_patch_sha256="$(shasum -a 256 "$GEOMETRY_ADAM_FUSION_PATCH" | awk '{print $1}')"
[ "$actual_geometry_adam_fusion_patch_sha256" = "927ad1fdbffee7ad762396c7acc965cd4a20da781f172240c62aa94f41e1cd2c" ] \
  || fail "geometry-Adam fusion patch SHA-256 mismatch"
require_contains '[ "$(sha256 "$GEOMETRY_ADAM_FUSION_PATCH")" = "$GEOMETRY_ADAM_FUSION_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$GEOMETRY_ADAM_FUSION_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$GEOMETRY_ADAM_FUSION_PATCH"' "$BUILD_SCRIPT"
require_contains 'geometry_adam_fusion_patch_sha256' "$BUILD_SCRIPT"
require_contains '"geometry_adam_fusion_patch_sha256": "927ad1fdbffee7ad762396c7acc965cd4a20da781f172240c62aa94f41e1cd2c"' "$VALIDATOR"
require_contains 'msplat-1.1.3-parallel-radix-scan.patch' "$BUILD_SCRIPT"
require_contains 'PARALLEL_RADIX_SCAN_PATCH_SHA256="1caedde675063dd0b119e91ec39a6945328ecf37134a83b079dce964a7a816c4"' "$BUILD_SCRIPT"
actual_parallel_radix_scan_patch_sha256="$(shasum -a 256 "$PARALLEL_RADIX_SCAN_PATCH" | awk '{print $1}')"
[ "$actual_parallel_radix_scan_patch_sha256" = "1caedde675063dd0b119e91ec39a6945328ecf37134a83b079dce964a7a816c4" ] \
  || fail "parallel radix-scan patch SHA-256 mismatch"
require_contains '[ "$(sha256 "$PARALLEL_RADIX_SCAN_PATCH")" = "$PARALLEL_RADIX_SCAN_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$PARALLEL_RADIX_SCAN_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$PARALLEL_RADIX_SCAN_PATCH"' "$BUILD_SCRIPT"
require_contains 'parallel_radix_scan_patch_sha256' "$BUILD_SCRIPT"
require_contains '"parallel_radix_scan_patch_sha256": "1caedde675063dd0b119e91ec39a6945328ecf37134a83b079dce964a7a816c4"' "$VALIDATOR"
require_contains 'radix_sort_scan_blocks_kernel' "$PARALLEL_RADIX_SCAN_PATCH"
require_contains 'radix_sort_scan_digit_offsets_kernel' "$PARALLEL_RADIX_SCAN_PATCH"
require_contains 'msplat_exact_radix_sort_for_testing' "$PARALLEL_RADIX_SCAN_PATCH"
require_contains 'msplat_exact_radix_sort_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'verifyExactRadixOracle' "$RASTER_TEST_SOURCE"
require_contains '--radix-oracle' "$RASTER_TEST_SOURCE"
require_contains '"$NATIVE_BUILD_DIR/msplat_raster_tests" --radix-oracle' "$BUILD_SCRIPT"
require_contains 'msplat-1.1.3-allocation-pressure.patch' "$BUILD_SCRIPT"
require_contains 'ALLOCATION_PRESSURE_PATCH_SHA256="34611e91e896f56c9ad81ae2c4bd55352b4172d5cbdb83da7658e9050382b4a8"' "$BUILD_SCRIPT"
actual_allocation_pressure_patch_sha256="$(shasum -a 256 "$ALLOCATION_PRESSURE_PATCH" | awk '{print $1}')"
[ "$actual_allocation_pressure_patch_sha256" = "34611e91e896f56c9ad81ae2c4bd55352b4172d5cbdb83da7658e9050382b4a8" ] \
  || fail "allocation-pressure patch SHA-256 mismatch"
require_contains '[ "$(sha256 "$ALLOCATION_PRESSURE_PATCH")" = "$ALLOCATION_PRESSURE_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$ALLOCATION_PRESSURE_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$ALLOCATION_PRESSURE_PATCH"' "$BUILD_SCRIPT"
require_contains 'allocation_pressure_patch_sha256' "$BUILD_SCRIPT"
require_contains '"allocation_pressure_patch_sha256": "34611e91e896f56c9ad81ae2c4bd55352b4172d5cbdb83da7658e9050382b4a8"' "$VALIDATOR"
require_contains 'metal_allocation_unavailable' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'msplat_metal_allocation_was_unavailable' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'msplat_simulate_gpu_allocation_failure_for_testing' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'msplat_set_raster_memory_budget_and_fail_for_testing' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'add_executable(msplat_allocation_pressure_cli cli/msplat.cpp)' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'msplat_core_raster_tests CLI11::CLI11 pthread' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'msplat_set_raster_memory_budget_bytes=msplat_set_raster_memory_budget_and_fail_for_testing' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'MSPLAT_ENABLE_RASTER_TEST_HOOKS' "$ALLOCATION_PRESSURE_PATCH"
require_absent 'add_option("--simulate' "$ALLOCATION_PRESSURE_PATCH"
require_absent 'add_flag("--simulate' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'events->emit("isolation_memory_refused"' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'return isolate ? 75 : 71;' "$ALLOCATION_PRESSURE_PATCH"
require_contains 'EXACT_PREFIX_HARDENING_PATCH_SHA256="510d70ac3413cbf1260881ed1399e5301cc1fce0d783a1e451381c9e3ec8c9fb"' "$BUILD_SCRIPT"
actual_exact_prefix_hardening_patch_sha256="$(shasum -a 256 "$EXACT_PREFIX_HARDENING_PATCH" | awk '{print $1}')"
[ "$actual_exact_prefix_hardening_patch_sha256" = "510d70ac3413cbf1260881ed1399e5301cc1fce0d783a1e451381c9e3ec8c9fb" ] \
  || fail "exact-prefix hardening patch SHA-256 mismatch"
require_contains 'std::max(0.0, value)' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'MTLSize loss_threadgroups = MTLSizeMake(' "$EXACT_PREFIX_HARDENING_PATCH"
if [ "$(grep -Fc '[enc dispatchThreadgroups:loss_threadgroups threadsPerThreadgroup:tg];' \
       "$EXACT_PREFIX_HARDENING_PATCH")" -ne 3 ]; then
  fail "$EXACT_PREFIX_HARDENING_PATCH must dispatch all three SSIM stages as full threadgroups"
fi
require_contains 'uint valid_pixel_count = 0;' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'if (c == 0) ++valid_pixel_count;' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'ssim_weight * (float(valid_pixel_count) - ssim_sum / 3.0f)' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'const bool valid_center =' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'tg_f1[dy][dx] = 0.0f;' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'tg_f2[dy][dx] = 0.0f;' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'tg_f3[dy][dx] = 0.0f;' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains '[ "$(sha256 "$EXACT_PREFIX_HARDENING_PATCH")" = "$EXACT_PREFIX_HARDENING_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$EXACT_PREFIX_HARDENING_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$EXACT_PREFIX_HARDENING_PATCH"' "$BUILD_SCRIPT"
require_contains 'exact_prefix_hardening_patch_sha256' "$BUILD_SCRIPT"
require_contains 'exact_block_offsets_u64_kernel' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'block_totals[group] + inclusive[lane]' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains '-        for (uint prior = 0; prior < group; ++prior)' "$EXACT_PREFIX_HARDENING_PATCH"
require_absent '+        for (uint prior = 0; prior < group; ++prior)' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'msplat_copy_last_raster_reference_debug' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'msplat_copy_isolation_projection_for_testing' "$ISOLATION_PATCH"
require_contains 'msplat_copy_isolation_projection_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'verifyIsolationLiftOracle' "$RASTER_TEST_SOURCE"
require_contains 'isolation_lift_oracle passed' "$RASTER_TEST_SOURCE"
require_contains 'msplat_exact_prefix_sum_for_testing' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'getRootCommandBuffer' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'return _currentCB.rootCommandBuffer' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'completedCommandBuffer.status' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'Metal command buffer failed while exact-raster tracking was active' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'event=exact_raster_gpu_timing_unavailable' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'g_exact_raster_timing_warning_emitted = false' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'g_exact_raster_timing_failure.clear()' "$EXACT_PREFIX_HARDENING_PATCH"
require_contains 'QUATERNION_STABILITY_PATCH_SHA256="d0aabc26d10b316a669c120ebdfdf573dd645c30c857e97b6ceeaa8c2c76b786"' "$BUILD_SCRIPT"
actual_quaternion_stability_patch_sha256="$(shasum -a 256 "$QUATERNION_STABILITY_PATCH" | awk '{print $1}')"
[ "$actual_quaternion_stability_patch_sha256" = "d0aabc26d10b316a669c120ebdfdf573dd645c30c857e97b6ceeaa8c2c76b786" ] \
  || fail "quaternion-stability patch SHA-256 mismatch"
require_contains '[ "$(sha256 "$QUATERNION_STABILITY_PATCH")" = "$QUATERNION_STABILITY_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$QUATERNION_STABILITY_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$QUATERNION_STABILITY_PATCH"' "$BUILD_SCRIPT"
require_contains 'quaternion_stability_patch_sha256' "$BUILD_SCRIPT"
require_contains 'normalize_quaternion' "$QUATERNION_STABILITY_PATCH"
require_contains 'v_quat - normalized * dot(normalized, v_quat)' "$QUATERNION_STABILITY_PATCH"
require_contains 'quaternion_vjp_for_testing_kernel' "$QUATERNION_STABILITY_PATCH"
require_contains 'msplat_quaternion_vjp_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'verifyQuaternionVJP' "$RASTER_TEST_SOURCE"
require_contains '--quaternion-vjp' "$RASTER_TEST_SOURCE"
require_contains '"$NATIVE_BUILD_DIR/msplat_raster_tests" --quaternion-vjp' "$BUILD_SCRIPT"
require_contains 'msplat_exact_prefix_sum_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'verifyExactPrefixOracle' "$RASTER_TEST_SOURCE"
require_contains '{1023u, 1024u, 1025u, 2048u, 2049u}' "$RASTER_TEST_SOURCE"
require_contains '"$NATIVE_BUILD_DIR/msplat_raster_tests" --prefix-oracle' "$BUILD_SCRIPT"
require_contains 'cpuRasterReference' "$RASTER_TEST_SOURCE"
require_contains 'verifyOverflowCPUReference(argv[3]);' "$RASTER_TEST_SOURCE"
require_contains 'overflowReferenceOpacity = 1.0f / 240.0f' "$RASTER_TEST_SOURCE"
require_contains 'std::pow(1.0f - overflowReferenceOpacity, 2050.0f)' "$RASTER_TEST_SOURCE"
require_contains 'requireOverflowTailEvidence(reference, actual, 1024);' "$RASTER_TEST_SOURCE"
require_contains 'requireOverflowTailEvidence(reference, actual, 2048);' "$RASTER_TEST_SOURCE"
require_contains 'overflow_cpu_position_gradients' "$RASTER_TEST_SOURCE"
require_contains 'overflow_cpu_color_gradients' "$RASTER_TEST_SOURCE"
require_contains 'overflow_cpu_opacity_gradients' "$RASTER_TEST_SOURCE"
require_contains 'project_geometry_adam_backward_kernel' "$GEOMETRY_ADAM_FUSION_PATCH"
require_contains 'sh_adam_backward_kernel' "$GEOMETRY_ADAM_FUSION_PATCH"
require_contains 'msplat_set_geometry_adam_fusion_enabled_for_testing' "$RASTER_TEST_SOURCE"
for symbol_contract in "$BUILD_SCRIPT" "$VALIDATOR"; do
  require_contains 'msplat_set_geometry_adam_fusion_enabled_for_testing' "$symbol_contract"
  require_contains 'msplat_exact_prefix_sum_for_testing' "$symbol_contract"
  require_contains 'msplat_quaternion_vjp_for_testing' "$symbol_contract"
  require_contains 'msplat_exact_radix_sort_for_testing' "$symbol_contract"
  require_contains 'msplat_set_raster_memory_budget_and_fail_for_testing' "$symbol_contract"
  require_contains 'msplat_copy_last_raster_reference_debug' "$symbol_contract"
  require_contains 'msplat_copy_isolation_projection_for_testing' "$symbol_contract"
done
require_contains 'geometryAdamShDegreeInterval = 4' "$RASTER_TEST_SOURCE"
require_contains 'makeModel(inputData, geometryAdamShDegreeInterval)' "$RASTER_TEST_SOURCE"
require_contains 'requireNonzeroDegree("coefficients", snapshot.colorsRest, degree)' "$RASTER_TEST_SOURCE"
require_contains 'requireNonzeroDegree("first_moment", snapshot.colorRestFirstMoment, degree)' "$RASTER_TEST_SOURCE"
require_contains 'requireNonzeroDegree("second_moment", snapshot.colorRestSecondMoment, degree)' "$RASTER_TEST_SOURCE"
require_contains 'requireSphericalHarmonicStateExercised("geometry_adam_common", fused)' "$RASTER_TEST_SOURCE"
require_contains 'requireSphericalHarmonicStateExercised("geometry_adam_exact", exactFused)' "$RASTER_TEST_SOURCE"
require_contains '"geometry_adam_checkpoint_prefix", checkpointPrefix' "$RASTER_TEST_SOURCE"
require_contains 'requireSphericalHarmonicStateExercised("geometry_adam_checkpoint_resume", resumed)' "$RASTER_TEST_SOURCE"
require_contains 'requireModelNear("geometry_adam_checkpoint_resume", fused, resumed)' "$RASTER_TEST_SOURCE"
require_contains 'TemporaryCheckpoint' "$RASTER_TEST_SOURCE"
require_contains '::mkstemp' "$RASTER_TEST_SOURCE"
require_contains 'geometry_adam_checkpoint_resume' "$RASTER_TEST_SOURCE"
require_contains 'geometry_adam_fusion_parity' "$RASTER_TEST_SOURCE"
require_contains 'verifyGeometryAdamFusionParity(argv[2]);' "$RASTER_TEST_SOURCE"
require_contains '--geometry-adam-benchmark' "$RASTER_TEST_SOURCE"
# Performance sampling is an opt-in diagnostic. CI gates numerical parity and dispatch contracts.
require_absent '--geometry-adam-benchmark' "$BUILD_SCRIPT"
require_contains 'testThreeSigmaCapIsNotRasterExact' "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp"
require_contains 'for (int sample = 0; sample < 200000; ++sample)' "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp"
require_contains 'cases.reserve(200003)' "$TILE_SPAN_TEST_ROOT/tests/gpu_tile_culling_tests.mm"
require_contains 'testIllConditionedConicKeepsBroadBounds' "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp"
require_contains 'tile_span_cpu_tests' "$BUILD_SCRIPT"
require_contains 'tile_span_metal_tests' "$BUILD_SCRIPT"
require_contains 'tile_span_intersections baseline=' "$RASTER_TEST_SOURCE"
require_contains 'msplat_set_tile_culling_min_area_for_testing' "$BUILD_SCRIPT"
require_absent 'queryTimestampFrequency' "$STAGE_TIMING_PATCH"
require_contains 'sampleTimestamps:&cpuTimestamp gpuTimestamp:&gpuTimestamp' "$STAGE_TIMING_PATCH"
require_contains 'mach_timebase_info(&timebase)' "$STAGE_TIMING_PATCH"
require_contains 'frequencyFromTimestampPairs' "$STAGE_TIMING_PATCH"
require_contains 'kResolvedCounterTimestampFrequencyHz = 1.0e9' "$STAGE_TIMING_PATCH"
require_contains 'dispatch_semaphore_wait' "$STAGE_TIMING_PATCH"
require_contains 'end <= start' "$STAGE_TIMING_PATCH"
require_contains 'stageTimingValid' "$STAGE_TIMING_PATCH"
require_contains 'MSPLAT_STAGE_PROFILING_UNAVAILABLE = 0' "$STAGE_TIMING_PATCH"
require_contains 'MSPLAT_STAGE_PROFILING_INITIALIZATION_FAILED = 2' "$STAGE_TIMING_PATCH"
require_contains 'msplat_stage_profiling_status_for_testing' "$STAGE_TIMING_PATCH"
require_contains 'return ratio <= 1.05' "$STAGE_TIMING_PATCH"
require_contains 'stageSeconds / commandBufferSeconds >= 0.25' "$STAGE_TIMING_PATCH"
require_contains 'stageTimingIterations = 512' "$RASTER_TEST_SOURCE"
require_contains '--stage-timing' "$RASTER_TEST_SOURCE"
require_contains 'profilingStatus == MSPLAT_STAGE_PROFILING_UNAVAILABLE' "$RASTER_TEST_SOURCE"
require_contains 'profilingStatus != MSPLAT_STAGE_PROFILING_AVAILABLE' "$RASTER_TEST_SOURCE"
require_contains 'msplat stage timing skipped: Metal timestamp counters unavailable' "$RASTER_TEST_SOURCE"
require_contains '--stage-timing "$RASTER_TEST_FIXTURES/01-sphere-500"' "$BUILD_SCRIPT"
require_contains 'MSPLAT_BUILD_RASTER_TESTS=ON' "$BUILD_SCRIPT"
require_contains 'msplat_raster_tests' "$BUILD_SCRIPT"
require_contains 'add_library(msplat_core_raster_tests STATIC' "$EXACT_RASTER_PATCH"
require_contains 'target_link_libraries(msplat_raster_tests PRIVATE msplat_core_raster_tests pthread)' "$EXACT_RASTER_PATCH"
require_contains 'reject_raster_test_symbols' "$BUILD_SCRIPT"
require_contains 'reject_raster_test_symbols' "$VALIDATOR"
require_contains 'raster_test_sha256' "$BUILD_SCRIPT"
require_contains 'raster_test_sha256' "$VALIDATOR"
for contract_file in "$SWIFT_VALIDATOR" "$SWIFT_FIXTURE"; do
  require_contains 'source_notice_patch_sha256' "$contract_file"
  require_contains 'exact_raster_patch_sha256' "$contract_file"
  require_contains 'stage_timing_patch_sha256' "$contract_file"
  require_contains 'memory_efficiency_patch_sha256' "$contract_file"
  require_contains 'densification_memory_patch_sha256' "$contract_file"
  require_contains 'row_span_culling_patch_sha256' "$contract_file"
  require_contains 'geometry_adam_fusion_patch_sha256' "$contract_file"
  require_contains 'parallel_radix_scan_patch_sha256' "$contract_file"
  require_contains 'allocation_pressure_patch_sha256' "$contract_file"
  require_contains 'exact_prefix_hardening_patch_sha256' "$contract_file"
  require_contains 'quaternion_stability_patch_sha256' "$contract_file"
  require_contains 'raster_test_sha256' "$contract_file"
  for key in \
    isolation_header_sha256 \
    isolation_source_sha256 \
    isolation_runtime_header_sha256 \
    isolation_runtime_source_sha256 \
    isolation_mask_header_sha256 \
    isolation_mask_source_sha256 \
    isolation_lift_source_sha256 \
    isolation_test_sha256 \
    isolation_mask_test_sha256 \
    isolation_patch_sha256; do
    require_contains "$key" "$contract_file"
  done
  require_contains 'MSPLAT_BUILD_RASTER_TESTS=ON' "$contract_file"
  require_json_hash "overlay_sha256" "$OVERLAY" "$contract_file"
  require_json_hash "isolation_header_sha256" "$ISOLATION_HEADER" "$contract_file"
  require_json_hash "isolation_source_sha256" "$ISOLATION_SOURCE" "$contract_file"
  require_json_hash "isolation_runtime_header_sha256" "$ISOLATION_RUNTIME_HEADER" "$contract_file"
  require_json_hash "isolation_runtime_source_sha256" "$ISOLATION_RUNTIME_SOURCE" "$contract_file"
  require_json_hash "isolation_mask_header_sha256" "$ISOLATION_MASK_HEADER" "$contract_file"
  require_json_hash "isolation_mask_source_sha256" "$ISOLATION_MASK_SOURCE" "$contract_file"
  require_json_hash "isolation_lift_source_sha256" "$ISOLATION_METAL_SOURCE" "$contract_file"
  require_json_hash "isolation_test_sha256" "$ISOLATION_TEST_SOURCE" "$contract_file"
  require_json_hash "isolation_mask_test_sha256" "$ISOLATION_MASK_TEST_SOURCE" "$contract_file"
  require_json_hash "isolation_patch_sha256" "$ISOLATION_PATCH" "$contract_file"
  require_contains '"source_notice_patch_sha256": "6deee598c9321c9b98d74b92fd5cce9808069a7a63effcd80615eb7d208d2ffb"' "$contract_file"
  require_contains '"raster_test_sha256": "60f4eea65d5be2ad8684292e8234fbce97ab330d5c1e0946d6b2e00a91957dcf"' "$contract_file"
  require_contains '"parallel_radix_scan_patch_sha256": "1caedde675063dd0b119e91ec39a6945328ecf37134a83b079dce964a7a816c4"' "$contract_file"
  require_contains '"allocation_pressure_patch_sha256": "34611e91e896f56c9ad81ae2c4bd55352b4172d5cbdb83da7658e9050382b4a8"' "$contract_file"
  require_contains '"exact_prefix_hardening_patch_sha256": "510d70ac3413cbf1260881ed1399e5301cc1fce0d783a1e451381c9e3ec8c9fb"' "$contract_file"
  require_contains '"quaternion_stability_patch_sha256": "d0aabc26d10b316a669c120ebdfdf573dd645c30c857e97b6ceeaa8c2c76b786"' "$contract_file"
done
require_contains 'scene_bounds_status' "$SWIFT_VALIDATOR"
require_contains '"$PYTHON_BIN" - "$build_info"' "$BUILD_SCRIPT"
require_contains 'json.dump(payload, output, indent=2, sort_keys=True)' "$BUILD_SCRIPT"
require_contains 'json.load(source, parse_constant=reject_constant)' "$BUILD_SCRIPT"
require_contains '/usr/bin/otool -L' "$BUILD_SCRIPT"
require_absent 'cat >"$STAGE_DIR/build_info.json" <<JSON' "$BUILD_SCRIPT"
require_contains 'PROMOTER_SOURCE="$ROOT/scripts/toolchain/atomic_swap_install.py"' "$BUILD_SCRIPT"
require_contains '"$PYTHON_BIN" "$PROMOTER_RUNTIME" "$@"' "$BUILD_SCRIPT"
require_contains 'PROMOTER_RUNTIME_SOURCE_SHA256="$(sha256 "$PROMOTER_SOURCE")"' "$BUILD_SCRIPT"
require_contains '[ "$runtime_hash" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ]' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$PROMOTER_SOURCE")" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ]' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$PROMOTER_RUNTIME")" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'entry.st_nlink != 1' "$BUILD_SCRIPT"
require_contains 'PROMOTER_RUNTIME_DEVICE="${identity%%:*}"' "$BUILD_SCRIPT"
require_contains 'PROMOTER_RUNTIME_INODE="${identity#*:}"' "$BUILD_SCRIPT"
require_absent "trap '' INT TERM HUP" "$BUILD_SCRIPT"
require_contains 'capture_deferred_build_signal' "$BUILD_SCRIPT"
require_contains 'replay_deferred_build_signal' "$BUILD_SCRIPT"
require_contains 'recover_stale_private_promoters' "$BUILD_SCRIPT"
require_contains 'BUILD_LOCK_PATH="$ROOT/Toolchains/.msplat-build.lock"' "$BUILD_SCRIPT"
require_contains 'acquire_build_lock' "$BUILD_SCRIPT"
require_contains 'release_build_lock' "$BUILD_SCRIPT"
require_contains '/usr/bin/shlock -f "$BUILD_LOCK_PATH" -p "$$"' "$BUILD_SCRIPT"
require_contains 'EASYSPLAT_MSPLAT_BUILD_LOCK_PROBE_DIR' "$BUILD_SCRIPT"
require_contains 'acquisition_timeout_seconds = 60' "$0"
require_contains '--remove-private-promoter-tree' "$BUILD_SCRIPT"
require_contains 'def remove_private_promoter_tree(' "$ATOMIC_PROMOTER"
require_contains 'def remove_bound_build_lock(' "$ATOMIC_PROMOTER"
require_contains 'def _after_private_promoter_validation(' "$ATOMIC_PROMOTER"
require_contains '--remove-private-promoter-tree' "$ATOMIC_PROMOTER"
require_contains '--remove-bound-build-lock' "$ATOMIC_PROMOTER"
require_contains 'abandon_unbound_private_promoter' "$BUILD_SCRIPT"
require_contains '/bin/rmdir "$path"' "$BUILD_SCRIPT"
require_contains 'restore_build_signal_traps' "$BUILD_SCRIPT"
require_contains 'normalize_private_promoter_metadata "$PROMOTER_RUNTIME"' "$BUILD_SCRIPT"
require_contains 'normalize_private_promoter_metadata "$PROMOTER_RUNTIME_DIR"' "$BUILD_SCRIPT"
require_contains '[ "$attribute" = "com.apple.provenance" ]' "$BUILD_SCRIPT"
require_contains '/usr/bin/xattr -s -d com.apple.provenance "$entry"' "$BUILD_SCRIPT"
require_contains '"$PROMOTER_RUNTIME_DEVICE"' "$BUILD_SCRIPT"
require_contains '"$PROMOTER_RUNTIME_INODE"' "$BUILD_SCRIPT"
require_contains 'PROMOTER_RUNTIME_READY=1' "$BUILD_SCRIPT"
require_contains 'prepare_private_promoter' "$BUILD_SCRIPT"
require_contains 'snapshot_build_inputs' "$BUILD_SCRIPT"
require_contains 'BUILD_INPUT_SNAPSHOT_READY=1' "$BUILD_SCRIPT"
require_absent '"$PYTHON_BIN" "$PROMOTER_SOURCE"' "$BUILD_SCRIPT"
require_absent '/usr/bin/xattr -c' "$BUILD_SCRIPT"

python3 - "$BUILD_SCRIPT" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
boundary = source.rfind("\nsnapshot_build_inputs\n")
if boundary < 0:
    raise SystemExit("native build never crosses the immutable input snapshot boundary")
calls = [
    source.rfind("\npreflight\n"),
    source.rfind("\nacquire_build_lock\n"),
    boundary,
    source.rfind("\nrevalidate_snapshotted_pins\n"),
    source.rfind("\nrecover_stale_private_promoters\n"),
    source.rfind("\nprepare_private_promoter\n"),
]
if any(call < 0 for call in calls) or calls != sorted(calls):
    raise SystemExit("native build snapshots and revalidates inputs out of order")
downstream = source[boundary:]
for live_root in ('"$ROOT/Tools/', '"$ROOT/scripts/ci/'):
    if live_root in downstream:
        raise SystemExit(
            f"native build reads a live checkout input after snapshot: {live_root}"
        )
PY

for forbidden in 'pip install' 'python-build-standalone' 'site-packages' '_core.so' 'core_extension_path.txt' '/msplat-train'; do
  require_absent "$forbidden" "$BUILD_SCRIPT"
done

for flag in --dataset --output --profile --iteration-limit --plateau-window --checkpoint --resume --seed --expected-input-digest --expected-geometry-digest --memory-budget-bytes --events-fd --self-check --validate-ply --benchmark-decode --benchmark-decode-output --version --help; do
  require_contains "$flag" "$OVERLAY"
done
for flag in --isolate --source-ply --mask-manifest --analysis-cache --expected-source-ply-digest --expected-selected-frames-digest --expected-training-manifest-digest --anchor-image --anchor-instance; do
  require_contains "$flag" "$OVERLAY"
done
for flag in --preview-output --preview-interval-seconds; do
  require_contains "$flag" "$OVERLAY"
done
# The preview must stay degree 0 and capped: MetalSplatter rejects a partial
# higher-order set, and an uncapped preview would bid against training for memory.
require_contains 'previewGaussianCap = 400000' "$OVERLAY"
require_contains 'previewPropertyCount = 17' "$OVERLAY"
require_contains 'preview PLY does not use the degree 0 layout' "$OVERLAY"
require_contains 'preview PLY properties are out of contract order' "$OVERLAY"
# Bounds travel with the publication: the viewer refuses a scene it cannot bound,
# so a preview that omits them renders blank.
require_contains '"scene_center", publication.bounds.center' "$OVERLAY"
for flag in --input --num-iters --num-downscales --downscale-factor --eval --events-jsonl; do
  require_absent "$flag" "$OVERLAY"
done
for budget in 'fast", 3000, 400' 'balanced", 7000, 800' 'high-detail", 15000, 1500'; do
  require_contains "$budget" "$OVERLAY"
done
for event in started checkpoint_completed checkpoint_loaded resume_rejected progress early_stop completed cancellation_requested cancelled self_check preview_published preview_disabled; do
  require_contains "\"$event\"" "$OVERLAY"
done
for event in isolation_started isolation_progress isolation_ambiguity isolation_no_subject isolation_held_out_rejected isolation_completed; do
  require_contains "\"$event\"" "$ISOLATION_RUNTIME_SOURCE"
done
for event in isolation_cancelled isolation_memory_refused isolation_failed; do
  require_contains "\"$event\"" "$OVERLAY"
done
require_contains '{"isolation_mode_version", 1}' "$OVERLAY"
require_contains 'subject-isolation self-check version missing' "$BUILD_SCRIPT"
require_contains 'expected_self_check_keys = {' "$BUILD_SCRIPT"
require_contains 'type(event.get(key)) is not int' "$BUILD_SCRIPT"
require_contains 'IsolationRunOutcome::ambiguous' "$OVERLAY"
require_contains 'IsolationRunOutcome::noSubject' "$OVERLAY"
require_contains 'IsolationRunOutcome::heldOutRejected' "$OVERLAY"
require_contains 'return isolate ? 75 : 1' "$OVERLAY"
for reason in trainer_changed input_changed geometry_changed run_contract_changed; do
  require_contains "\"$reason\"" "$OVERLAY"
done
require_contains 'InfiniteRandomIterator<size_t> camsIter(camIndices, seed)' "$OVERLAY"
require_contains 'msplat_record_last_loss' "$OVERLAY"
require_contains 'msplat_sync_loss_window' "$OVERLAY"
require_contains 'step < profile.iterationLimit' "$OVERLAY"
require_contains '"loss_iteration"' "$OVERLAY"
require_contains 'lossSyncBatch = refineEvery' "$OVERLAY"
require_contains 'plateauSampleCount == lossSyncBatch' "$OVERLAY"
require_contains 'bestCameraLosses' "$OVERLAY"
require_contains 'lastImprovementIteration' "$OVERLAY"
require_contains 'checkpoint CURRENT' "$OVERLAY"
require_contains 'RENAME_NOFOLLOW_ANY' "$OVERLAY"
require_contains 'computeTrainingIdentity' "$OVERLAY"
require_contains 'write(' "$OVERLAY"
require_contains 'msplat_gpu_sync()' "$OVERLAY"
require_contains '#include <sys/resource.h>' "$OVERLAY"
require_contains 'getrusage(RUSAGE_SELF' "$OVERLAY"
require_contains '"peak_memory_bytes"' "$OVERLAY"
require_contains 'std::vector<Camera> &cameras = inputData.cameras;' "$OVERLAY"
require_contains 'constexpr float background[3] = {0.0f, 0.0f, 0.0f};' "$OVERLAY"
require_contains 'profile.iterationLimit, true, background);' "$OVERLAY"
require_contains 'constexpr int cameraReuseCount = 2;' "$OVERLAY"
require_contains 'releaseCameraResources' "$OVERLAY"
require_absent 'for (Camera &camera : inputData.cameras) camera.loadImage' "$OVERLAY"
require_absent 'getCameras(false)' "$OVERLAY"
require_absent '0.6130f, 0.0101f, 0.3984f' "$OVERLAY"
if [ "$(grep -Fc '"peak_memory_bytes"' "$OVERLAY")" -lt 2 ]; then
  fail "$OVERLAY must report peak memory for checkpoints and completion"
fi
require_contains 'SIGINT' "$OVERLAY"
require_contains 'SIGTERM' "$OVERLAY"
require_contains 'return 130' "$OVERLAY"
require_contains 'rename(' "$OVERLAY"
require_contains 'fsync(' "$OVERLAY"
if [ "$(grep -Fc 'handleCancellation()' "$OVERLAY")" -lt 4 ]; then
  fail "$OVERLAY must observe cancellation both before and after each iteration"
fi

require_contains 'get_global_context' "$UPSTREAM_PATCH"
require_contains 'runtime_error' "$UPSTREAM_PATCH"
require_contains 'pipelineLoadFailed' "$UPSTREAM_PATCH"
require_contains 'std::ios::failbit' "$UPSTREAM_PATCH"
require_contains 'float3 b_conic = float3(0.0f)' "$UPSTREAM_PATCH"
require_contains 'int32_t b_id = 0' "$UPSTREAM_PATCH"
if [ "$(grep -Fc 'CGColorSpaceCreateWithName(kCGColorSpaceSRGB)' "$UPSTREAM_PATCH")" -lt 2 ]; then
  fail "$UPSTREAM_PATCH must make production image reads and writes explicitly sRGB"
fi
if grep -Eq '^\+.*CGColorSpaceCreateDeviceRGB' "$UPSTREAM_PATCH"; then
  fail "$UPSTREAM_PATCH must not add device-dependent RGB color spaces"
fi
if [ "$(grep -Fc 'std::array<float, 4>' "$UPSTREAM_PATCH")" -lt 2 ] ||
   [ "$(grep -Fc 'cam_pos[0], cam_pos[1], cam_pos[2], 0.0f' "$UPSTREAM_PATCH")" -lt 2 ]; then
  fail "$UPSTREAM_PATCH must pad every inline Metal float3 argument to sixteen bytes"
fi
require_contains 'staticThreadgroupMemoryLength' "$UPSTREAM_PATCH"
require_contains 'maxThreadgroupMemoryLength' "$UPSTREAM_PATCH"
require_contains '#define SSIM_TG 8' "$UPSTREAM_PATCH"
if [ "$(grep -Fc 'MTLSizeMake(8, 8, 1)' "$UPSTREAM_PATCH")" -lt 2 ]; then
  fail "$UPSTREAM_PATCH must dispatch every SSIM path with its eight-by-eight kernel shape"
fi
require_contains 'pixel_has_contributors' "$UPSTREAM_PATCH"
require_contains 'pixel_has_contributors ? bin_final : -1' "$UPSTREAM_PATCH"
require_contains 'void msplat_record_last_loss' "$UPSTREAM_PATCH"
require_contains 'void msplat_sync_loss_window' "$UPSTREAM_PATCH"
require_contains 'syncCB()' "$UPSTREAM_PATCH"
require_contains 'CKPT_VERSION = 2' "$CHECKPOINT_PATCH"
require_contains 'Checkpoint tensor shape mismatch' "$CHECKPOINT_PATCH"
require_contains 'Metal command buffer failed' "$CHECKPOINT_PATCH"
require_contains 'float g = isfinite(grads[tid]) ? clamp(grads[tid], -1.0e10f, 1.0e10f) : 0.0f;' "$NUMERIC_STABILITY_PATCH"
require_contains 'isfinite(exp_avg_sq[tid]) && exp_avg_sq[tid] >= 0.0f' "$NUMERIC_STABILITY_PATCH"
require_contains 'if (isfinite(candidate)) params[tid] = candidate;' "$NUMERIC_STABILITY_PATCH"
require_contains 'float g = isfinite(grad) ? clamp(grad, -1.0e10f, 1.0e10f) : 0.0f;' "$NUMERIC_STABILITY_PATCH"
require_contains 'if (isfinite(candidate)) param = candidate;' "$NUMERIC_STABILITY_PATCH"
require_contains 'float gradient_norm = sqrt(gx * gx + gy * gy);' "$NUMERIC_STABILITY_PATCH"
require_contains 'if (isfinite(gradient_norm)) xys_grad_norm[idx] += gradient_norm;' "$NUMERIC_STABILITY_PATCH"
require_contains 'std::shared_ptr<GPUStorage> _gpu_storage;' "$METAL_SAFETY_PATCH"
require_contains 'throw std::out_of_range("MTensor::view exceeds dimension zero")' "$METAL_SAFETY_PATCH"
require_contains 'packed_intersection_capacity' "$METAL_SAFETY_PATCH"
require_contains 'num_tiles) * static_cast<uint64_t>(kMaxTileElements)' "$METAL_SAFETY_PATCH"
require_contains 'std::numeric_limits<int32_t>::max()' "$METAL_SAFETY_PATCH"
require_contains 'clamp(input[i], 0, MAX_TILE_ELEMS)' "$METAL_SAFETY_PATCH"
require_contains 'ENC_SCALAR(enc, capacity_u32, 13)' "$METAL_SAFETY_PATCH"
require_contains 'validateBinaryPly' "$OVERLAY"
require_contains 'if (handleCancellation()) return 130' "$OVERLAY"
require_contains '--memory-budget-bytes' "$OVERLAY"
require_contains 'msplat_set_raster_memory_budget_bytes' "$OVERLAY"
require_contains 'msplat_get_raster_stats' "$OVERLAY"
require_contains '"raster_fallback"' "$OVERLAY"
require_contains '"raster_memory_budget_exceeded"' "$OVERLAY"
require_contains '"raster_resource_limit_exceeded"' "$OVERLAY"
require_contains '"raster_fallback_count"' "$OVERLAY"
require_contains '"raster_exact_fallback_elapsed_seconds"' "$OVERLAY"
require_contains '"raster_exact_buffer_growth_count"' "$OVERLAY"
require_contains '"raster_exact_buffer_bytes_added"' "$OVERLAY"
require_contains '"raster_replay_elapsed_seconds"' "$OVERLAY"
require_contains '"raster_peak_exact_intersection_capacity"' "$OVERLAY"
require_contains '"dropped_intersection_count"' "$OVERLAY"
require_contains 'msplat_preflight_raster_memory' "$OVERLAY"
require_contains 'msplat_raster_memory_budget_was_exceeded' "$OVERLAY"
require_contains 'msplat_raster_resource_limit_was_exceeded' "$OVERLAY"
require_contains 'msplat_gpu_sync_for_raster_replay' "$OVERLAY"
require_contains 'msplat_grow_exact_raster_capacity' "$OVERLAY"
require_contains 'msplat_restore_exact_raster_capacity' "$OVERLAY"
require_contains '{"payload_schema", 2}' "$OVERLAY"
require_contains 'fields["schema_version"] = 2' "$OVERLAY"
require_contains 'Descriptor for schema-v2 JSONL events' "$OVERLAY"
require_contains 'checkpoint manifest keys do not match schema 3' "$OVERLAY"
require_contains 'native_coregraphics_imageio_srgb8_v2' "$OVERLAY"
require_absent 'native_coregraphics_imageio_rgb8_v1' "$OVERLAY"

require_contains 'radix_sort_histogram_kernel_cpso' "$EXACT_RASTER_PATCH"
require_contains 'radix_sort_scan_kernel_cpso' "$EXACT_RASTER_PATCH"
require_contains 'radix_sort_scatter_kernel_cpso' "$EXACT_RASTER_PATCH"
require_contains 'map_gaussian_to_intersects_kernel_cpso' "$EXACT_RASTER_PATCH"
require_contains 'get_tile_bin_edges_kernel_cpso' "$EXACT_RASTER_PATCH"
require_contains 'pack_sorted_gaussians_kernel_cpso' "$EXACT_RASTER_PATCH"
require_contains 'dispatchThreadgroupsWithIndirectBuffer' "$EXACT_RASTER_PATCH"
require_contains 'prepare_exact_dispatch_kernel' "$EXACT_RASTER_PATCH"
require_contains 'exact_block_reduce_u64_kernel' "$EXACT_RASTER_PATCH"
require_contains 'device const uint64_t* cum_tiles_hit' "$EXACT_RASTER_PATCH"
require_absent 'kExactBytesPerIntersection = 64' "$EXACT_RASTER_PATCH"
require_contains 'raster_allocation_bytes' "$EXACT_RASTER_PATCH"
require_contains 'release_exact_buffers' "$EXACT_RASTER_PATCH"
require_absent 'dispatchThreads:MTLSizeMake(capacity, 1, 1)' "$EXACT_RASTER_PATCH"
require_contains 'exact_radix_pass_count(num_tiles)' "$EXACT_RASTER_PATCH"
require_contains 'for (uint32_t pass = 0; pass < radix_pass_count; ++pass)' "$EXACT_RASTER_PATCH"
require_contains 'passes + (passes & 1u)' "$EXACT_RASTER_PATCH"
require_contains 'verifyExactRadixPassPlanning' "$RASTER_TEST_SOURCE"
require_contains "{65'536, 6}" "$RASTER_TEST_SOURCE"
require_contains "{65'537, 8}" "$RASTER_TEST_SOURCE"
require_contains '((uint64_t)tile_id << 32) | (uint64_t)as_type<uint>(depths[idx])' "$EXACT_RASTER_PATCH"
require_contains 'isect_ids_sorted[idx] >> 32' "$EXACT_RASTER_PATCH"
require_contains 'raster_memory_budget_exceeded' "$EXACT_RASTER_PATCH"
require_contains 'msplat_set_raster_memory_budget_bytes' "$EXACT_RASTER_PATCH"
require_contains 'if (raster_execution_blocked(fatal_flag)) return;' "$EXACT_RASTER_PATCH"
require_contains 'const int next_adam_step_count = adam_step_count + 1;' "$EXACT_RASTER_PATCH"
require_contains 'adam_step_count = next_adam_step_count;' "$EXACT_RASTER_PATCH"
require_contains 'void msplat_preflight_raster_memory(' "$EXACT_RASTER_PATCH"
require_contains 'bool msplat_raster_memory_budget_was_exceeded()' "$EXACT_RASTER_PATCH"
require_contains 'bool msplat_raster_resource_limit_was_exceeded()' "$EXACT_RASTER_PATCH"
require_contains 'void msplat_gpu_sync_for_raster_replay()' "$EXACT_RASTER_PATCH"
require_contains 'void msplat_grow_exact_raster_capacity(uint64_t intersection_count)' "$EXACT_RASTER_PATCH"
require_contains 'void msplat_restore_exact_raster_capacity(uint64_t intersection_count)' "$EXACT_RASTER_PATCH"
require_contains 'geometric_raster_capacity' "$EXACT_RASTER_PATCH"
require_contains 'raster_allocation_fits' "$EXACT_RASTER_PATCH"
require_contains 'targetCapacity = intersection_count' "$EXACT_RASTER_PATCH"
require_contains 'void msplat_restore_raster_metrics(' "$EXACT_RASTER_PATCH"
require_contains 'exact_fallback_elapsed_seconds' "$EXACT_RASTER_PATCH"
require_contains 'sync_and_drain_exact_raster_timing' "$EXACT_RASTER_PATCH"
require_contains 'std::exception_ptr syncFailure' "$EXACT_RASTER_PATCH"
require_contains 'completedCommandBuffer.GPUStartTime' "$EXACT_RASTER_PATCH"
require_contains 'completedCommandBuffer.GPUEndTime' "$EXACT_RASTER_PATCH"
require_absent 'addScheduledHandler' "$EXACT_RASTER_PATCH"
require_contains 'msplat_pending_exact_raster_timing_handlers_for_testing() == 0' "$EXACT_RASTER_PATCH"
require_contains '(fallback_count != 0 &&' "$EXACT_RASTER_PATCH"
require_contains 'exact_fallback_elapsed_seconds <= 0' "$EXACT_RASTER_PATCH"
require_contains 'exact_buffer_growth_count' "$EXACT_RASTER_PATCH"
require_contains 'exact_buffer_bytes_added' "$EXACT_RASTER_PATCH"
require_contains 'peak_exact_intersection_capacity' "$EXACT_RASTER_PATCH"
require_contains 'void msplat_clear_raster_capacity_failure()' "$EXACT_RASTER_PATCH"
require_contains 'kRasterStatFirstOverflowIteration' "$EXACT_RASTER_PATCH"
require_contains 'MSPLAT_ENABLE_RASTER_TEST_HOOKS' "$EXACT_RASTER_PATCH"

for evidence in forward_rgb forward_alpha position_gradients color_gradients opacity_gradients position_first_moment color_first_moment opacity_first_moment common_path_disabled_seconds mixed_resolution_growth; do
  require_contains "$evidence" "$RASTER_TEST_SOURCE"
done
require_contains 'exact_only_budget_evidence passed' "$RASTER_TEST_SOURCE"
require_contains 'shared_allocation_budget passed' "$RASTER_TEST_SOURCE"
require_contains 'msplat_validate_gpu_allocation' "$EXACT_RASTER_PATCH"
require_contains 'msplat_report_gpu_allocation_failure' "$EXACT_RASTER_PATCH"
require_contains 'Metal buffer allocation failed after capacity validation' "$EXACT_RASTER_PATCH"
require_contains 'const MsplatRasterStats replayStats = msplat_get_raster_stats();' "$OVERLAY"
require_contains '{"required_bytes", replayStats.required_bytes}' "$OVERLAY"
require_contains 'relativeTolerance = 2.0e-3f' "$RASTER_TEST_SOURCE"
require_contains 'absoluteTolerance = 2.0e-4f' "$RASTER_TEST_SOURCE"
require_contains 'msplat_set_force_exact_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'msplat_set_exact_fallback_enabled_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'window_replay_numerical_parity passed' "$RASTER_TEST_SOURCE"
require_absent 'verifyDeterministicWindowReplay' "$RASTER_TEST_SOURCE"
require_absent 'deterministic_window_replay passed' "$RASTER_TEST_SOURCE"
require_contains 'increasing_window_replay passed' "$RASTER_TEST_SOURCE"
require_contains 'gpu_capacity_failure passed' "$RASTER_TEST_SOURCE"
require_contains 'verifyRepeatedExactFallbackMetrics' "$RASTER_TEST_SOURCE"
require_contains 'repeated_exact_fallback_metrics passed' "$RASTER_TEST_SOURCE"
require_contains 'restored_exact_capacity passed' "$RASTER_TEST_SOURCE"
require_contains 'geometric headroom did not fall back to the minimum fitting capacity' "$RASTER_TEST_SOURCE"
require_contains 'queued_exact_timing passed' "$RASTER_TEST_SOURCE"
require_contains 'sync_failure_timing_lifecycle passed' "$RASTER_TEST_SOURCE"
require_contains 'msplat_fail_next_sync_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'msplat_pending_exact_raster_timing_handlers_for_testing' "$RASTER_TEST_SOURCE"
require_contains 'invalidHistory' "$RASTER_TEST_SOURCE"

python3 - "$ATOMIC_PROMOTER" <<'PY'
import hashlib
import importlib.util
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("atomic_swap_install", source)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
expected_digest = hashlib.sha256(source.read_bytes()).hexdigest()


def create_promoter(parent, suffix):
    root = parent / f"promoter.stage.{suffix}"
    root.mkdir(mode=0o700)
    executable = root / "atomic_swap_install.py"
    shutil.copyfile(source, executable)
    executable.chmod(0o700)
    metadata = root.lstat()
    return root, metadata


with tempfile.TemporaryDirectory(prefix="easysplat-promoter-recovery.") as temporary:
    parent = Path(temporary)
    valid, valid_metadata = create_promoter(parent, "ABC123")
    module.remove_private_promoter_tree(
        valid,
        valid_metadata.st_dev,
        valid_metadata.st_ino,
        expected_digest,
    )
    if valid.exists():
        raise SystemExit("strict private-promoter recovery left a valid root")

    injected, injected_metadata = create_promoter(parent, "DEF456")

    def inject_unverified_entry(_parent, _original, directory):
        descriptor = os.open(
            "injected",
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory,
        )
        os.write(descriptor, b"preserve me\n")
        os.close(descriptor)

    module._after_private_promoter_validation = inject_unverified_entry
    try:
        module.remove_private_promoter_tree(
            injected,
            injected_metadata.st_dev,
            injected_metadata.st_ino,
            expected_digest,
        )
    except module.PromotionRecoveryError:
        pass
    else:
        raise SystemExit("injected private-promoter content was accepted")
    if (
        not (injected / "injected").is_file()
        or (injected / "injected").read_bytes() != b"preserve me\n"
        or hashlib.sha256(
            (injected / "atomic_swap_install.py").read_bytes()
        ).hexdigest()
        != expected_digest
    ):
        raise SystemExit("private-promoter recovery deleted injected state")

    swapped, swapped_metadata = create_promoter(parent, "GHI789")

    def install_root_replacement(parent_descriptor, original_name, _directory):
        os.mkdir(original_name, mode=0o700, dir_fd=parent_descriptor)
        replacement = os.open(
            original_name,
            module.DIRECTORY_OPEN_FLAGS,
            dir_fd=parent_descriptor,
        )
        try:
            sentinel = os.open(
                "replacement",
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=replacement,
            )
            os.write(sentinel, b"replacement\n")
            os.close(sentinel)
        finally:
            os.close(replacement)

    module._after_private_promoter_validation = install_root_replacement
    module.remove_private_promoter_tree(
        swapped,
        swapped_metadata.st_dev,
        swapped_metadata.st_ino,
        expected_digest,
    )
    replacement = swapped / "replacement"
    if replacement.read_bytes() != b"replacement\n":
        raise SystemExit("private-promoter recovery removed a root replacement")
PY

python3 - "$BUILD_SCRIPT" "$ATOMIC_PROMOTER" "$ROOT" <<'PY'
import hashlib
import os
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

build_script = Path(sys.argv[1])
promoter_source = Path(sys.argv[2])
root = Path(sys.argv[3])
build_root = root / "Toolchains" / "build" / "msplat"
build_root.mkdir(parents=True, exist_ok=True)
lock_path = root / "Toolchains" / ".msplat-build.lock"

with tempfile.TemporaryDirectory(prefix="easysplat-build-lock.") as temporary:
    probe_root = Path(temporary)
    probe_a = probe_root / "a"
    probe_b = probe_root / "b"
    probe_a.mkdir(mode=0o700)
    probe_b.mkdir(mode=0o700)
    log_a = (probe_root / "a.log").open("wb")
    env_a = os.environ.copy()
    env_a["EASYSPLAT_MSPLAT_BUILD_LOCK_PROBE_DIR"] = str(probe_a)
    first = subprocess.Popen(
        ["/bin/bash", str(build_script)],
        cwd=root,
        env=env_a,
        stdout=log_a,
        stderr=subprocess.STDOUT,
    )
    live_promoter = None
    live_identity = None
    try:
        acquisition_timeout_seconds = 60
        deadline = time.monotonic() + acquisition_timeout_seconds
        while not (probe_a / "acquired").is_file():
            if first.poll() is not None:
                log_a.close()
                raise SystemExit(
                    "first build-lock probe exited before acquiring the lock: "
                    + (probe_root / "a.log").read_text(errors="replace")
                )
            if time.monotonic() >= deadline:
                process_status = first.poll()
                log_a.flush()
                raise SystemExit(
                    "first build-lock probe did not acquire the lock within "
                    f"{acquisition_timeout_seconds} seconds "
                    f"(alive={process_status is None}, poll={process_status!r}): "
                    + (probe_root / "a.log").read_text(errors="replace")
                )
            time.sleep(0.05)

        for _ in range(128):
            candidate = build_root / (
                "promoter.stage."
                + "".join(
                    secrets.choice(
                        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
                    )
                    for _ in range(6)
                )
            )
            try:
                candidate.mkdir(mode=0o700)
            except FileExistsError:
                continue
            live_promoter = candidate
            break
        if live_promoter is None:
            raise SystemExit("could not create a live private-promoter fixture")
        live_executable = live_promoter / "atomic_swap_install.py"
        shutil.copyfile(promoter_source, live_executable)
        live_executable.chmod(0o700)
        live_identity = live_promoter.lstat()
        live_digest = hashlib.sha256(live_executable.read_bytes()).hexdigest()

        env_b = os.environ.copy()
        env_b["EASYSPLAT_MSPLAT_BUILD_LOCK_PROBE_DIR"] = str(probe_b)
        second = subprocess.run(
            ["/bin/bash", str(build_script)],
            cwd=root,
            env=env_b,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if (
            second.returncode != 1
            or "another native msplat build already holds" not in second.stderr
        ):
            raise SystemExit(
                "parallel native builder did not fail on the live build lock"
            )
        after = live_promoter.lstat()
        if (
            not stat.S_ISDIR(after.st_mode)
            or (after.st_dev, after.st_ino)
            != (live_identity.st_dev, live_identity.st_ino)
            or hashlib.sha256(live_executable.read_bytes()).hexdigest()
            != live_digest
        ):
            raise SystemExit("parallel native builder changed the live promoter")

        (probe_a / "release").write_bytes(b"release\n")
        if first.wait(timeout=30) != 0:
            log_a.close()
            raise SystemExit(
                "first build-lock probe failed during release: "
                + (probe_root / "a.log").read_text(errors="replace")
            )
        if lock_path.exists() or lock_path.is_symlink():
            raise SystemExit("native build-lock probe left its owned lock behind")
    finally:
        if first.poll() is None:
            (probe_a / "release").write_bytes(b"release\n")
            try:
                first.wait(timeout=10)
            except subprocess.TimeoutExpired:
                first.terminate()
                first.wait(timeout=10)
        log_a.close()
        if live_promoter is not None and live_identity is not None:
            current = live_promoter.lstat()
            if (current.st_dev, current.st_ino) != (
                live_identity.st_dev,
                live_identity.st_ino,
            ):
                raise SystemExit(
                    "refusing to clean a replaced live-promoter fixture"
                )
            executable = live_promoter / "atomic_swap_install.py"
            executable.unlink()
            live_promoter.rmdir()
PY

if [ "${1:-}" = "--source-only" ]; then
  echo "native msplat source contracts passed"
  exit 0
fi

BIN="$INSTALL_DIR/bin/easysplat-train"
METALLIB="$INSTALL_DIR/bin/default.metallib"
BUILD_INFO="$INSTALL_DIR/build_info.json"
LICENSE="$INSTALL_DIR/LICENSE"

for path in "$BIN" "$METALLIB" "$BUILD_INFO" "$LICENSE"; do
  require_file "$path"
done
[ -x "$BIN" ] || fail "native CLI is not executable: $BIN"
[ -s "$METALLIB" ] || fail "metallib is empty: $METALLIB"

[ -f "$NATIVE_BUILD_DIR/CMakeCache.txt" ] \
  || fail "native build directory is not configured: $NATIVE_BUILD_DIR"
production_binary_hash_before="$(shasum -a 256 "$BIN" | awk '{print $1}')"
production_provenance_hash_before="$(shasum -a 256 "$BUILD_INFO" | awk '{print $1}')"
cmake --build "$NATIVE_BUILD_DIR" --target \
  msplat_allocation_pressure_cli \
  msplat_isolation_tests \
  msplat_isolation_mask_tests
require_file "$ALLOCATION_PRESSURE_TEST_BIN"
[ -x "$ALLOCATION_PRESSURE_TEST_BIN" ] \
  || fail "allocation-pressure test CLI is not executable"
/usr/bin/file -b "$ALLOCATION_PRESSURE_TEST_BIN" | grep -q 'Mach-O 64-bit executable arm64' \
  || fail "allocation-pressure test CLI is not an arm64 Mach-O"
for symbol in \
  msplat_simulate_gpu_allocation_failure_for_testing \
  msplat_set_raster_memory_budget_and_fail_for_testing; do
  /usr/bin/nm -gU "$ALLOCATION_PRESSURE_TEST_BIN" | grep -Fq "$symbol" \
    || fail "allocation-pressure test CLI is missing test hook: $symbol"
done
[ "$(shasum -a 256 "$BIN" | awk '{print $1}')" = "$production_binary_hash_before" ] \
  || fail "building the allocation-pressure test CLI changed the production binary"
[ "$(shasum -a 256 "$BUILD_INFO" | awk '{print $1}')" = "$production_provenance_hash_before" ] \
  || fail "building the allocation-pressure test CLI changed production provenance"
for test_binary in "$ISOLATION_TEST_BIN" "$ISOLATION_MASK_TEST_BIN"; do
  require_file "$test_binary"
  [ -x "$test_binary" ] || fail "isolation test is not executable: $test_binary"
  "$test_binary"
done

actual_files="$(cd "$INSTALL_DIR" && find . -type f -print | LC_ALL=C sort)"
expected_files=$'./LICENSE\n./bin/default.metallib\n./bin/easysplat-train\n./build_info.json'
[ "$actual_files" = "$expected_files" ] || fail "unexpected staged install contents:\n$actual_files"

/usr/bin/file -b "$BIN" | grep -q 'Mach-O 64-bit executable arm64' || fail "CLI is not an arm64 Mach-O"
for symbol in \
  msplat_set_force_exact_for_testing \
  msplat_set_exact_fallback_enabled_for_testing \
  msplat_set_exact_execution_capacity_for_testing \
  msplat_set_exact_capacity_limit_for_testing \
  msplat_set_raster_memory_budget_for_testing \
  msplat_simulate_gpu_allocation_failure_for_testing \
  msplat_set_raster_memory_budget_and_fail_for_testing \
  msplat_set_geometry_adam_fusion_enabled_for_testing \
  msplat_fail_next_sync_for_testing \
  msplat_pending_exact_raster_timing_handlers_for_testing \
  msplat_exact_prefix_sum_for_testing \
  msplat_exact_radix_sort_for_testing \
  msplat_gpu_ticks_to_seconds_for_testing \
  msplat_gpu_frequency_from_timestamp_pairs_for_testing \
  msplat_stage_timing_sample_valid_for_testing \
  msplat_stage_timing_aggregate_coherent_for_testing \
  msplat_enable_stage_profiling_for_testing \
  msplat_stage_profiling_status_for_testing \
  msplat_gpu_timestamp_calibration_for_testing \
  msplat_copy_last_raster_debug \
  msplat_copy_last_raster_reference_debug \
  msplat_copy_isolation_projection_for_testing; do
  if nm -gU "$BIN" | grep -Fq "$symbol"; then
    fail "production CLI exports raster test hook: $symbol"
  fi
done
for symbol in msplat_prepare_isolation_view msplat_lift_isolation_stripe; do
  /usr/bin/nm -gU "$BIN" | grep -Fq "$symbol" \
    || fail "production CLI is missing isolation binding: $symbol"
done
/usr/bin/otool -L "$BIN" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *) fail "CLI has a non-system dynamic dependency: $dependency" ;;
  esac
done
"$BIN" --version | grep -Fq '1.1.3' || fail "CLI version does not report 1.1.3"
help="$($BIN --help)"
test_help="$($ALLOCATION_PRESSURE_TEST_BIN --help)"
production_help_options="$(grep -Eo -- '--[a-z][a-z0-9-]*' <<<"$help" | LC_ALL=C sort -u)"
test_help_options="$(grep -Eo -- '--[a-z][a-z0-9-]*' <<<"$test_help" | LC_ALL=C sort -u)"
[ "$test_help_options" = "$production_help_options" ] \
  || fail "allocation-pressure test CLI changed the production option surface"
for flag in --dataset --output --profile --iteration-limit --plateau-window --checkpoint --resume --seed --expected-input-digest --expected-geometry-digest --memory-budget-bytes --events-fd --self-check --validate-ply --benchmark-decode --benchmark-decode-output --version --help; do
  grep -Fq -- "$flag" <<<"$help" || fail "CLI help is missing $flag"
done
for flag in --isolate --source-ply --mask-manifest --analysis-cache --expected-source-ply-digest --expected-selected-frames-digest --expected-training-manifest-digest --anchor-image --anchor-instance; do
  grep -Fq -- "$flag" <<<"$help" || fail "CLI help is missing $flag"
done
for flag in --preview-output --preview-interval-seconds; do
  grep -Fq -- "$flag" <<<"$help" || fail "CLI help is missing $flag"
done
for flag in --input --num-iters --num-downscales --downscale-factor --eval --events-jsonl; do
  if grep -Fq -- "$flag" <<<"$help"; then
    fail "CLI help still exposes obsolete control $flag"
  fi
done

self_check_stdout="$(mktemp "${TMPDIR:-/tmp}/easysplat-msplat-self-check.XXXXXX")"
self_check_stderr="$self_check_stdout.stderr"
trap 'rm -f "$self_check_stdout" "$self_check_stderr"; rm -rf "${decode_dir:-}" "${negative_dir:-}"' EXIT
"$BIN" --self-check --events-fd 1 >"$self_check_stdout" 2>"$self_check_stderr"
[ "$(wc -l <"$self_check_stdout" | tr -d ' ')" = "1" ] || fail "self-check stdout is not exactly one JSONL record"
require_contains '"schema_version":2' "$self_check_stdout"
require_contains '"sequence":1' "$self_check_stdout"
require_contains '"event":"self_check"' "$self_check_stdout"
require_contains '"status":"ok"' "$self_check_stdout"
require_contains '"scene_bounds_status":"ok"' "$self_check_stdout"
python3 - "$self_check_stdout" <<'PY'
import json
import sys
from pathlib import Path


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit("self-check must emit exactly one JSONL record")
event = json.loads(lines[0], parse_constant=reject_constant)
expected_keys = {
    "event",
    "isolation_mode_version",
    "scene_bounds_status",
    "schema_version",
    "sequence",
    "status",
    "version",
}
if type(event) is not dict or set(event) != expected_keys:
    raise SystemExit(f"self-check event schema is not closed: {sorted(event)}")
for key in ("isolation_mode_version", "schema_version", "sequence"):
    if type(event[key]) is not int:
        raise SystemExit(f"self-check {key} must be an exact JSON integer")
if event["isolation_mode_version"] != 1:
    raise SystemExit("self-check isolation mode version mismatch")
if (
    event["event"] != "self_check"
    or event["scene_bounds_status"] != "ok"
    or event["schema_version"] != 2
    or event["sequence"] != 1
    or event["status"] != "ok"
):
    raise SystemExit("self-check event values mismatch")
PY

decode_dir="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-msplat-decode.XXXXXX")"
python3 - "$decode_dir/source.png" <<'PY'
from PIL import Image, ImageCms
import sys

profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))
Image.new("RGB", (64, 64), (12, 34, 56)).save(
    sys.argv[1],
    format="PNG",
    icc_profile=profile.tobytes(),
)
PY
decode_receipt="$decode_dir/receipt.json"
"$BIN" \
  --benchmark-decode "$decode_dir/source.png" \
  --benchmark-decode-output "$decode_dir/output.rgb8" \
  >"$decode_receipt" \
  2>"$decode_dir/stderr.log"
[ ! -s "$decode_dir/stderr.log" ] || fail "benchmark decode polluted stderr"
[ "$(wc -c <"$decode_dir/output.rgb8" | tr -d ' ')" = 12288 ] \
  || fail "benchmark decode output has the wrong byte count"
python3 - "$decode_receipt" "$decode_dir/output.rgb8" "$BIN" "$METALLIB" <<'PY'
import hashlib
import json
import pathlib
import sys

receipt_path, output_path, executable_path, metallib_path = map(pathlib.Path, sys.argv[1:])
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
expected_fields = {
    "contract", "executable_bytes", "executable_sha256", "height",
    "metallib_bytes", "metallib_sha256", "mode", "mode_version",
    "msplat_source_commit", "output_bytes", "output_sha256", "pixel_sha256",
    "schema_version", "source_bytes", "source_sha256", "status",
    "trainer_build_digest", "width",
}
if set(receipt) != expected_fields:
    raise SystemExit("benchmark decode receipt schema is not closed")
sha = lambda path: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
if receipt["output_sha256"] != sha(output_path) or receipt["pixel_sha256"] != sha(output_path):
    raise SystemExit("benchmark decode output digest mismatch")
if receipt["executable_sha256"] != sha(executable_path):
    raise SystemExit("benchmark decode executable digest mismatch")
if receipt["metallib_sha256"] != sha(metallib_path):
    raise SystemExit("benchmark decode metallib digest mismatch")
if receipt["width"] != 64 or receipt["height"] != 64 or receipt["output_bytes"] != 12288:
    raise SystemExit("benchmark decode dimensions mismatch")
if receipt["contract"] != "native_coregraphics_imageio_srgb8_v2":
    raise SystemExit("benchmark decode color contract mismatch")
if receipt["mode_version"] != 2:
    raise SystemExit("benchmark decode mode version mismatch")
if output_path.read_bytes() != bytes((12, 34, 56)) * (64 * 64):
    raise SystemExit("production decoder changed tagged sRGB pixel values")
if receipt["msplat_source_commit"] != "106499b0a53f82b0c92d013b0861fbebd341b17e":
    raise SystemExit("benchmark decode source commit mismatch")
PY

display_p3_profile="/System/Library/ColorSync/Profiles/Display P3.icc"
[ -f "$display_p3_profile" ] || fail "macOS Display P3 profile is unavailable"
python3 - "$decode_dir/display-p3.png" "$display_p3_profile" <<'PY'
from pathlib import Path
from PIL import Image
import sys

image = Image.new("RGB", (4, 1))
image.putdata(((180, 60, 80), (60, 180, 80), (80, 60, 180), (140, 120, 40)))
image.save(sys.argv[1], format="PNG", icc_profile=Path(sys.argv[2]).read_bytes())
PY
"$BIN" \
  --benchmark-decode "$decode_dir/display-p3.png" \
  --benchmark-decode-output "$decode_dir/display-p3.rgb8" \
  >"$decode_dir/display-p3.json" \
  2>"$decode_dir/display-p3.stderr"
[ ! -s "$decode_dir/display-p3.stderr" ] || fail "Display P3 decode polluted stderr"
python3 - \
  "$decode_dir/display-p3.json" \
  "$decode_dir/display-p3.rgb8" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

receipt_path, output_path = map(Path, sys.argv[1:])
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
pixels = output_path.read_bytes()
expected = bytes((196, 47, 78, 0, 183, 64, 84, 59, 187, 144, 119, 11))
if len(pixels) != len(expected) or max(abs(a - b) for a, b in zip(pixels, expected)) > 1:
    raise SystemExit("Display P3 source was not converted to the fixed sRGB oracle")
if pixels == bytes((180, 60, 80, 60, 180, 80, 80, 60, 180, 140, 120, 40)):
    raise SystemExit("Display P3 source passed through without color conversion")
digest = "sha256:" + hashlib.sha256(pixels).hexdigest()
if (
    receipt["contract"] != "native_coregraphics_imageio_srgb8_v2"
    or receipt["mode_version"] != 2
    or receipt["width"] != 4
    or receipt["height"] != 1
    or receipt["output_bytes"] != len(expected)
    or receipt["pixel_sha256"] != digest
    or receipt["output_sha256"] != digest
):
    raise SystemExit("Display P3 decoder receipt does not bind the converted pixels")
PY

printf 'preserve me\n' >"$decode_dir/collision.rgb8"
set +e
"$BIN" \
  --benchmark-decode "$decode_dir/source.png" \
  --benchmark-decode-output "$decode_dir/collision.rgb8" \
  >"$decode_dir/collision.stdout" \
  2>"$decode_dir/collision.stderr"
collision_status=$?
set -e
[ "$collision_status" -ne 0 ] || fail "benchmark decode overwrote an existing output"
[ "$(cat "$decode_dir/collision.rgb8")" = "preserve me" ] \
  || fail "benchmark decode changed an existing output"
if find "$decode_dir" -maxdepth 1 -name '.benchmark-decode.*' -print -quit | grep -q .; then
  fail "benchmark decode left a partial temporary output"
fi

mkdir "$decode_dir/missing-closure"
cp "$BIN" "$decode_dir/missing-closure/easysplat-train"
chmod +x "$decode_dir/missing-closure/easysplat-train"
set +e
"$decode_dir/missing-closure/easysplat-train" \
  --benchmark-decode "$decode_dir/source.png" \
  --benchmark-decode-output "$decode_dir/missing-closure/output.rgb8" \
  >"$decode_dir/missing-closure/stdout" \
  2>"$decode_dir/missing-closure/stderr"
missing_closure_status=$?
set -e
[ "$missing_closure_status" -ne 0 ] || fail "benchmark decode accepted a missing closure"
[ ! -e "$decode_dir/missing-closure/output.rgb8" ] \
  || fail "benchmark decode published output before validating its closure"

negative_dir="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-msplat-negative.XXXXXX")"
isolation_source="$negative_dir/isolation-source.ply"
isolation_cache="$negative_dir/isolation-analysis.cache"
isolation_output="$negative_dir/isolation-output.ply"
isolation_dataset="$negative_dir/isolation-dataset"
isolation_manifest="$negative_dir/isolation-mask-manifest.json"
valid_isolation_digest="$(printf '0%.0s' {1..64})"
uppercase_isolation_digest="$(printf 'A%.0s' {1..64})"
short_isolation_digest="$(printf '0%.0s' {1..63})"
printf 'source PLY sentinel\n' >"$isolation_source"
isolation_source_hash_before="$(shasum -a 256 "$isolation_source" | awk '{print $1}')"

expect_isolation_rejection() {
  local label="$1"
  local diagnostic="$2"
  shift 2
  set +e
  "$@" \
    >"$negative_dir/$label.stdout" \
    2>"$negative_dir/$label.stderr"
  local status=$?
  set -e
  [ "$status" = 1 ] \
    || fail "$label isolation rejection exited with $status instead of 1"
  grep -Eqi -- "$diagnostic" "$negative_dir/$label.stderr" \
    || fail "$label isolation diagnostic is not useful"
}

expect_parse_suppression() {
  local label="$1"
  local expected_status="$2"
  shift 2
  set +e
  "$@" \
    >"$negative_dir/$label.stdout" \
    2>"$negative_dir/$label.stderr"
  local status=$?
  set -e
  [ "$status" = "$expected_status" ] \
    || fail "$label suppressed parse exited with $status instead of $expected_status"
  [ ! -s "$negative_dir/$label.stdout" ] \
    && [ ! -s "$negative_dir/$label.stderr" ] \
    || fail "$label parser emitted suppressed diagnostics"
}

case_source_digest="$valid_isolation_digest"
case_memory_budget=1
case_output="$isolation_output"
case_dataset="$isolation_dataset"
case_include_events=1
case_events_fd=1
case_anchor_args=()
case_extra_args=()
run_complete_isolation_case() {
  local arguments=(
    --isolate
    --dataset "$case_dataset"
    --source-ply "$isolation_source"
    --mask-manifest "$isolation_manifest"
    --analysis-cache "$isolation_cache"
    --output "$case_output"
    --expected-source-ply-digest "$case_source_digest"
    --expected-input-digest "$valid_isolation_digest"
    --expected-geometry-digest "$valid_isolation_digest"
    --expected-selected-frames-digest "$valid_isolation_digest"
    --expected-training-manifest-digest "$valid_isolation_digest"
    --memory-budget-bytes "$case_memory_budget"
  )
  if [ "$case_include_events" = 1 ]; then
    arguments+=(--events-fd "$case_events_fd")
  fi
  if [ "${#case_anchor_args[@]}" -gt 0 ]; then
    arguments+=("${case_anchor_args[@]}")
  fi
  if [ "${#case_extra_args[@]}" -gt 0 ]; then
    arguments+=("${case_extra_args[@]}")
  fi
  "$BIN" "${arguments[@]}"
}

expect_isolation_rejection \
  isolation-option-without-mode \
  'subject-isolation options require --isolate' \
  "$BIN" --source-ply "$isolation_source"
expect_isolation_rejection \
  isolation-training-conflict \
  'training-only options' \
  "$BIN" --isolate --profile fast
expect_isolation_rejection \
  isolation-mode-conflict \
  'cannot be combined' \
  "$BIN" --isolate --self-check
expect_isolation_rejection \
  isolation-missing-required \
  '--dataset is required exactly once' \
  "$BIN" --isolate

case_include_events=0
expect_isolation_rejection \
  isolation-missing-events \
  '--events-fd is required exactly once' \
  run_complete_isolation_case
case_include_events=1

case_source_digest="$uppercase_isolation_digest"
expect_isolation_rejection \
  isolation-invalid-digest \
  'lowercase 64-character' \
  run_complete_isolation_case
case_source_digest="$short_isolation_digest"
expect_isolation_rejection \
  isolation-short-digest \
  'lowercase 64-character' \
  run_complete_isolation_case
case_source_digest="$valid_isolation_digest"

case_memory_budget=0
expect_isolation_rejection \
  isolation-zero-memory \
  'must be positive' \
  run_complete_isolation_case
case_memory_budget=1

case_output="$negative_dir/isolation-output.obj"
expect_isolation_rejection \
  isolation-invalid-output-extension \
  '--output must end in .ply' \
  run_complete_isolation_case
case_output="$isolation_output"

case_anchor_args=(--anchor-image frame-0001)
expect_isolation_rejection \
  isolation-unpaired-anchor \
  'must be provided together' \
  run_complete_isolation_case
case_anchor_args=(--anchor-image frame-0001 --anchor-instance 0)
expect_isolation_rejection \
  isolation-zero-anchor \
  'nonzero 8-bit label' \
  run_complete_isolation_case
case_anchor_args=(--anchor-image frame-0001 --anchor-instance 256)
expect_isolation_rejection \
  isolation-large-anchor \
  'nonzero 8-bit label' \
  run_complete_isolation_case
case_anchor_args=()

case_extra_args=(--isolate)
expect_isolation_rejection \
  isolation-duplicate-mode \
  'exactly once' \
  run_complete_isolation_case
case_extra_args=(--dataset "$isolation_dataset")
expect_parse_suppression \
  isolation-duplicate-dataset \
  1 \
  run_complete_isolation_case
case_extra_args=()
expect_parse_suppression \
  isolation-help-before-validation \
  0 \
  "$BIN" --isolate --help
expect_parse_suppression \
  isolation-version-before-validation \
  0 \
  "$BIN" --isolate --version
expect_parse_suppression \
  alternate-event-fd-help-before-validation \
  0 \
  "$BIN" --events-fd=02 --help

printf 'mask manifest sentinel\n' >"$isolation_manifest"
for alias_case in source mask; do
  if [ "$alias_case" = source ]; then
    alias_path="$isolation_source"
  else
    alias_path="$isolation_manifest"
  fi
  for argument_order in before after equals; do
    alias_hash_before="$(shasum -a 256 "$alias_path" | awk '{print $1}')"
    alias_identity_before="$(stat -f '%d:%i:%l' "$alias_path")"
    if [ "$argument_order" = before ]; then
      parser_arguments=(
        --isolate
        --unknown-isolation-option
        --events-fd 2
        --source-ply "$isolation_source"
        --mask-manifest "$isolation_manifest"
      )
    elif [ "$argument_order" = after ]; then
      parser_arguments=(
        --isolate
        --events-fd 2
        --source-ply "$isolation_source"
        --mask-manifest "$isolation_manifest"
        --unknown-isolation-option
      )
    else
      parser_arguments=(
        --isolate
        --events-fd=2
        --source-ply "$isolation_source"
        --mask-manifest "$isolation_manifest"
        --unknown-isolation-option
      )
    fi
    set +e
    "$BIN" "${parser_arguments[@]}" \
      >"$negative_dir/isolation-parser-fd2-$alias_case-$argument_order.stdout" \
      2<>"$alias_path"
    alias_status=$?
    set -e
    [ "$alias_status" = 1 ] \
      || fail "fd2 parser $alias_case alias exited with $alias_status instead of 1"
    [ "$(shasum -a 256 "$alias_path" | awk '{print $1}')" = "$alias_hash_before" ] \
      || fail "fd2 parser diagnostics changed the isolation $alias_case input"
    [ "$(stat -f '%d:%i:%l' "$alias_path")" = "$alias_identity_before" ] \
      || fail "fd2 parser diagnostics replaced the isolation $alias_case input"
    [ ! -s "$negative_dir/isolation-parser-fd2-$alias_case-$argument_order.stdout" ] \
      || fail "fd2 parser $alias_case diagnostic escaped isolation suppression"
  done
done

for alias_case in source mask; do
  if [ "$alias_case" = source ]; then
    alias_path="$isolation_source"
  else
    alias_path="$isolation_manifest"
  fi
  for argument_order in before after; do
    alias_hash_before="$(shasum -a 256 "$alias_path" | awk '{print $1}')"
    alias_identity_before="$(stat -f '%d:%i:%l' "$alias_path")"
    if [ "$argument_order" = before ]; then
      parser_arguments=(
        --unknown-isolation-option
        --isolate
        --events-fd 2
        --source-ply "$isolation_source"
        --mask-manifest "$isolation_manifest"
      )
    else
      parser_arguments=(
        --isolate
        --events-fd 1
        --source-ply "$isolation_source"
        --mask-manifest "$isolation_manifest"
        --unknown-isolation-option
      )
    fi
    set +e
    if [ "$alias_case" = source ]; then
      "$BIN" "${parser_arguments[@]}" 1<>"$alias_path" 2>&1
    else
      "$BIN" "${parser_arguments[@]}" 2<>"$alias_path" 1>&2
    fi
    alias_status=$?
    set -e
    [ "$alias_status" = 1 ] \
      || fail "dual-stdio parser $alias_case alias exited with $alias_status instead of 1"
    [ "$(shasum -a 256 "$alias_path" | awk '{print $1}')" = "$alias_hash_before" ] \
      || fail "dual-stdio parser diagnostics changed the isolation $alias_case input"
    [ "$(stat -f '%d:%i:%l' "$alias_path")" = "$alias_identity_before" ] \
      || fail "dual-stdio parser diagnostics replaced the isolation $alias_case input"
  done
done

alternate_fd1_spellings=(
  01 +1 0x1 0X1 0b1 0o1 1_ 0b0_1 "0x'1" true " 1"
)
alternate_fd2_spellings=(
  02 +2 0x2 0X2 0b10 0o2 2_ 0b1_0 "0x'2" " 2"
)
for descriptor in 1 2; do
  if [ "$descriptor" = 1 ]; then
    alias_path="$isolation_manifest"
    spellings=("${alternate_fd1_spellings[@]}")
  else
    alias_path="$isolation_source"
    spellings=("${alternate_fd2_spellings[@]}")
  fi
  for spelling_index in "${!spellings[@]}"; do
    spelling="${spellings[$spelling_index]}"
    alias_hash_before="$(shasum -a 256 "$alias_path" | awk '{print $1}')"
    alias_identity_before="$(stat -f '%d:%i:%l' "$alias_path")"
    if [ $((spelling_index % 2)) = 0 ]; then
      parser_arguments=(
        "--events-fd=$spelling"
        --unknown-integral-spelling
      )
    else
      parser_arguments=(
        --events-fd "$spelling"
        --unknown-integral-spelling
      )
    fi
    set +e
    if [ "$descriptor" = 1 ]; then
      "$BIN" "${parser_arguments[@]}" 2<>"$alias_path" 1>&2
    else
      "$BIN" "${parser_arguments[@]}" 1<>"$alias_path" 2>&1
    fi
    alias_status=$?
    set -e
    [ "$alias_status" = 1 ] \
      || fail "alternate fd$descriptor spelling exited with $alias_status instead of 1"
    [ "$(shasum -a 256 "$alias_path" | awk '{print $1}')" = "$alias_hash_before" ] \
      || fail "alternate fd$descriptor spelling $spelling changed its aliased artifact"
    [ "$(stat -f '%d:%i:%l' "$alias_path")" = "$alias_identity_before" ] \
      || fail "alternate fd$descriptor spelling $spelling replaced its aliased artifact"
  done
done

parser_source_hash_before="$(shasum -a 256 "$isolation_source" | awk '{print $1}')"
parser_mask_hash_before="$(shasum -a 256 "$isolation_manifest" | awk '{print $1}')"
parser_source_identity_before="$(stat -f '%d:%i:%l' "$isolation_source")"
parser_mask_identity_before="$(stat -f '%d:%i:%l' "$isolation_manifest")"
set +e
"$BIN" --isolate --events-fd 1 --events-fd 2 --unknown-isolation-option \
  1<>"$isolation_source" 2<>"$isolation_manifest"
parser_ambiguous_status=$?
set -e
[ "$parser_ambiguous_status" = 1 ] \
  || fail "ambiguous parser event descriptors exited with $parser_ambiguous_status"
[ "$(shasum -a 256 "$isolation_source" | awk '{print $1}')" = "$parser_source_hash_before" ] \
  && [ "$(stat -f '%d:%i:%l' "$isolation_source")" = "$parser_source_identity_before" ] \
  || fail "ambiguous parser diagnostics changed the fd1 isolation artifact"
[ "$(shasum -a 256 "$isolation_manifest" | awk '{print $1}')" = "$parser_mask_hash_before" ] \
  && [ "$(stat -f '%d:%i:%l' "$isolation_manifest")" = "$parser_mask_identity_before" ] \
  || fail "ambiguous parser diagnostics changed the fd2 isolation artifact"

set +e
"$BIN" --isolate --events-fd 1 --unknown-isolation-option \
  >"$negative_dir/isolation-parser-fd1.stdout" \
  2>"$negative_dir/isolation-parser-fd1.stderr"
parser_fd1_status=$?
"$BIN" --unknown-isolation-option \
  >"$negative_dir/parser-ordinary.stdout" \
  2>"$negative_dir/parser-ordinary.stderr"
parser_ordinary_status=$?
set -e
[ "$parser_fd1_status" = 1 ] && [ ! -s "$negative_dir/isolation-parser-fd1.stdout" ] \
  && [ ! -s "$negative_dir/isolation-parser-fd1.stderr" ] \
  || fail "fd1 parser diagnostics escaped isolation suppression"
[ "$parser_ordinary_status" = 1 ] && [ ! -s "$negative_dir/parser-ordinary.stdout" ] \
  && grep -Fq -- '--unknown-isolation-option' "$negative_dir/parser-ordinary.stderr" \
  || fail "ordinary parser diagnostics did not preserve stderr behavior"

set +e
"$BIN" -- --isolate \
  >"$negative_dir/parser-terminator.stdout" \
  2>"$negative_dir/parser-terminator.stderr"
parser_terminator_status=$?
"$BIN" --events-fd 3 --unknown-isolation-option \
  >"$negative_dir/parser-fd3.stdout" \
  2>"$negative_dir/parser-fd3.stderr"
parser_fd3_status=$?
"$BIN" --events-fd -1 --unknown-isolation-option \
  >"$negative_dir/parser-invalid-fd.stdout" \
  2>"$negative_dir/parser-invalid-fd.stderr"
parser_invalid_fd_status=$?
"$BIN" --events-fd 999999999999999999999 \
  >"$negative_dir/parser-overflow-fd.stdout" \
  2>"$negative_dir/parser-overflow-fd.stderr"
parser_overflow_fd_status=$?
"$BIN" --events-fd=03 --unknown-isolation-option \
  >"$negative_dir/parser-nonstandard-fd3.stdout" \
  2>"$negative_dir/parser-nonstandard-fd3.stderr"
parser_nonstandard_fd3_status=$?
"$BIN" --events-fd 3 --events-fd 4 \
  >"$negative_dir/parser-duplicate-fd3.stdout" \
  2>"$negative_dir/parser-duplicate-fd3.stderr"
parser_duplicate_fd3_status=$?
set -e
[ "$parser_terminator_status" = 1 ] && [ ! -s "$negative_dir/parser-terminator.stdout" ] \
  && grep -Fq -- '--isolate' "$negative_dir/parser-terminator.stderr" \
  || fail "argument terminator did not preserve ordinary parser diagnostics"
[ "$parser_fd3_status" = 1 ] && [ ! -s "$negative_dir/parser-fd3.stdout" ] \
  && grep -Fq -- '--unknown-isolation-option' "$negative_dir/parser-fd3.stderr" \
  || fail "fd3 parser diagnostics were unnecessarily suppressed"
[ "$parser_invalid_fd_status" = 1 ] && [ ! -s "$negative_dir/parser-invalid-fd.stdout" ] \
  && [ -s "$negative_dir/parser-invalid-fd.stderr" ] \
  || fail "invalid non-stdio descriptor diagnostics were unnecessarily suppressed"
[ "$parser_overflow_fd_status" = 1 ] && [ ! -s "$negative_dir/parser-overflow-fd.stdout" ] \
  && [ -s "$negative_dir/parser-overflow-fd.stderr" ] \
  || fail "overflow descriptor diagnostics were unnecessarily suppressed"
[ "$parser_nonstandard_fd3_status" = 1 ] && [ ! -s "$negative_dir/parser-nonstandard-fd3.stdout" ] \
  && grep -Fq -- '--unknown-isolation-option' "$negative_dir/parser-nonstandard-fd3.stderr" \
  || fail "nonstandard fd3 diagnostics were unnecessarily suppressed"
[ "$parser_duplicate_fd3_status" = 1 ] && [ ! -s "$negative_dir/parser-duplicate-fd3.stdout" ] \
  && [ -s "$negative_dir/parser-duplicate-fd3.stderr" ] \
  || fail "duplicate fd3+ diagnostics were unnecessarily suppressed"

for alias_case in source mask; do
  if [ "$alias_case" = source ]; then
    alias_path="$isolation_source"
  else
    alias_path="$isolation_manifest"
  fi
  alias_hash_before="$(shasum -a 256 "$alias_path" | awk '{print $1}')"
  case_events_fd=3
  set +e
  run_complete_isolation_case \
    3<>"$alias_path" \
    >"$negative_dir/isolation-events-alias-$alias_case.stdout" \
    2>"$negative_dir/isolation-events-alias-$alias_case.stderr"
  alias_status=$?
  set -e
  [ "$alias_status" = 1 ] \
    || fail "event descriptor $alias_case alias exited with $alias_status instead of 1"
  [ "$(shasum -a 256 "$alias_path" | awk '{print $1}')" = "$alias_hash_before" ] \
    || fail "event descriptor alias changed the isolation $alias_case input"
  grep -Eqi 'event.*descriptor|alias|distinct' \
    "$negative_dir/isolation-events-alias-$alias_case.stderr" \
    || fail "event descriptor $alias_case alias diagnostic is not useful"
done

for alias_case in source mask; do
  if [ "$alias_case" = source ]; then
    alias_path="$isolation_source"
  else
    alias_path="$isolation_manifest"
  fi
  alias_hash_before="$(shasum -a 256 "$alias_path" | awk '{print $1}')"
  case_events_fd=2
  set +e
  run_complete_isolation_case \
    >"$negative_dir/isolation-events-fd2-alias-$alias_case.stdout" \
    2<>"$alias_path"
  alias_status=$?
  set -e
  [ "$alias_status" = 1 ] \
    || fail "fd2 event descriptor $alias_case alias exited with $alias_status instead of 1"
  [ "$(shasum -a 256 "$alias_path" | awk '{print $1}')" = "$alias_hash_before" ] \
    || fail "fd2 event descriptor alias changed the isolation $alias_case input"
  grep -Eqi 'event.*descriptor|alias|distinct' \
    "$negative_dir/isolation-events-fd2-alias-$alias_case.stdout" \
    || fail "fd2 event descriptor $alias_case alias diagnostic is not useful"
done
case_events_fd=1

set +e
"$BIN" --isolate --profile fast --events-fd 2 \
  >"$negative_dir/events-fd2.stdout" \
  2>"$negative_dir/events-fd2.jsonl"
events_fd2_status=$?
set -e
[ "$events_fd2_status" = 1 ] \
  || fail "fd2 JSONL purity probe exited with $events_fd2_status instead of 1"
python3 - "$negative_dir/events-fd2.jsonl" <<'PY'
import json
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit(f"fd2 event stream contains {len(lines)} lines instead of one")
event = json.loads(lines[0])
if event.get("event") != "isolation_failed":
    raise SystemExit("fd2 event stream did not contain the typed isolation failure")
PY
[ -s "$negative_dir/events-fd2.stdout" ] \
  || fail "fd2 event stream did not redirect human diagnostics to stdout"

isolation_dataset_target="$negative_dir/isolation-dataset-target"
mkdir "$isolation_dataset_target"
ln -s "$isolation_dataset_target" "$isolation_dataset"
expect_isolation_rejection \
  isolation-symlinked-dataset \
  'expected an ordinary directory' \
  run_complete_isolation_case

python3 - "$negative_dir/isolation-invalid-digest.stdout" <<'PY'
import json
import sys
from pathlib import Path


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit(
        f"invalid isolation request emitted {len(lines)} events instead of one"
    )
event = json.loads(lines[0], parse_constant=reject_constant)
expected_keys = {"event", "message", "schema_version", "sequence", "status"}
if type(event) is not dict or set(event) != expected_keys:
    raise SystemExit(f"isolation failure event schema is not closed: {sorted(event)}")
if type(event["schema_version"]) is not int or type(event["sequence"]) is not int:
    raise SystemExit("isolation failure event envelope requires exact JSON integers")
if (
    event["event"] != "isolation_failed"
    or event["schema_version"] != 2
    or event["sequence"] != 1
    or event["status"] != "failed"
    or "lowercase 64-character" not in event["message"]
):
    raise SystemExit("isolation failure event values mismatch")
PY

[ "$(shasum -a 256 "$isolation_source" | awk '{print $1}')" = "$isolation_source_hash_before" ] \
  || fail "invalid isolation CLI probes changed the source PLY"
[ ! -e "$isolation_cache" ] || fail "invalid isolation CLI probes published an analysis cache"
[ ! -e "$isolation_output" ] || fail "invalid isolation CLI probes published an output PLY"
[ ! -e "$negative_dir/isolation-output.obj" ] \
  || fail "invalid isolation CLI probes published a non-PLY output"

"$BIN" --self-check --events-fd 3 \
  3>"$negative_dir/fd3.events" \
  >"$negative_dir/fd3.stdout" \
  2>"$negative_dir/fd3.stderr"
[ ! -s "$negative_dir/fd3.stdout" ] || fail "event-fd self-check polluted stdout"
[ ! -s "$negative_dir/fd3.stderr" ] || fail "event-fd self-check polluted stderr"
require_contains '"event":"self_check"' "$negative_dir/fd3.events"

set +e
"$BIN" --self-check --events-fd 9 \
  >"$negative_dir/closed-fd.stdout" \
  2>"$negative_dir/closed-fd.stderr"
closed_fd_status=$?
"$BIN" --dataset "$negative_dir" --output "$negative_dir/invalid.ply" \
  --profile extravagant --checkpoint "$negative_dir/invalid-checkpoint" --seed 42 \
  --memory-budget-bytes 536870912 --events-fd 1 \
  >"$negative_dir/invalid-profile.stdout" \
  2>"$negative_dir/invalid-profile.stderr"
invalid_profile_status=$?
"$BIN" --self-check --iteration-limit 10 --iteration-limit 11 \
  >"$negative_dir/duplicate-iteration.stdout" \
  2>"$negative_dir/duplicate-iteration.stderr"
duplicate_iteration_status=$?
"$BIN" --self-check --iteration-limit 0 \
  >"$negative_dir/zero-iteration.stdout" \
  2>"$negative_dir/zero-iteration.stderr"
zero_iteration_status=$?
"$BIN" --self-check --iteration-limit=-1 \
  >"$negative_dir/negative-iteration.stdout" \
  2>"$negative_dir/negative-iteration.stderr"
negative_iteration_status=$?
"$BIN" --self-check --iteration-limit 1000001 \
  >"$negative_dir/overflow-iteration.stdout" \
  2>"$negative_dir/overflow-iteration.stderr"
overflow_iteration_status=$?
"$BIN" --dataset "$negative_dir" --output "$negative_dir/invalid-budget.ply" \
  --profile balanced --iteration-limit 10 --plateau-window 11 \
  --checkpoint "$negative_dir/invalid-budget-checkpoint" --seed 42 \
  --memory-budget-bytes 536870912 --events-fd 1 \
  >"$negative_dir/plateau-exceeds-iteration.stdout" \
  2>"$negative_dir/plateau-exceeds-iteration.stderr"
plateau_exceeds_iteration_status=$?
"$BIN" --self-check --not-a-real-option \
  >"$negative_dir/unknown-option.stdout" \
  2>"$negative_dir/unknown-option.stderr"
unknown_option_status=$?
set -e
[ "$closed_fd_status" -ne 0 ] || fail "closed event file descriptor falsely succeeded"
grep -qi 'file descriptor' "$negative_dir/closed-fd.stderr" || fail "closed event-fd diagnostic is not useful"
[ "$invalid_profile_status" -ne 0 ] || fail "unknown training profile falsely succeeded"
grep -qi 'profile' "$negative_dir/invalid-profile.stderr" || fail "unknown profile diagnostic is not useful"
[ "$duplicate_iteration_status" -ne 0 ] || fail "duplicate iteration limit falsely succeeded"
grep -Eqi 'iteration-limit|specified more than once' "$negative_dir/duplicate-iteration.stderr" \
  || fail "duplicate iteration-limit diagnostic is not useful"
[ "$zero_iteration_status" -ne 0 ] || fail "zero iteration limit falsely succeeded"
grep -qi 'iteration-limit' "$negative_dir/zero-iteration.stderr" \
  || fail "zero iteration-limit diagnostic is not useful"
[ "$negative_iteration_status" -ne 0 ] || fail "negative iteration limit falsely succeeded"
grep -qi 'iteration-limit' "$negative_dir/negative-iteration.stderr" \
  || fail "negative iteration-limit diagnostic is not useful"
[ "$overflow_iteration_status" -ne 0 ] || fail "overflow iteration limit falsely succeeded"
grep -qi 'iteration-limit' "$negative_dir/overflow-iteration.stderr" \
  || fail "overflow iteration-limit diagnostic is not useful"
[ "$plateau_exceeds_iteration_status" -ne 0 ] \
  || fail "plateau window above iteration limit falsely succeeded"
grep -Eqi 'plateau-window.*iteration-limit' "$negative_dir/plateau-exceeds-iteration.stderr" \
  || fail "plateau-window relationship diagnostic is not useful"
[ "$unknown_option_status" -ne 0 ] || fail "unknown native trainer option falsely succeeded"
grep -Eqi 'not-a-real-option|not expected|unrecognized' "$negative_dir/unknown-option.stderr" \
  || fail "unknown-option diagnostic is not useful"

python3 - "$BIN" "$negative_dir/broken-pipe.stdout" "$negative_dir/broken-pipe.stderr" <<'PY'
import os
import subprocess
import sys

read_fd, write_fd = os.pipe()
os.close(read_fd)
with open(sys.argv[2], "wb") as stdout, open(sys.argv[3], "wb") as stderr:
    result = subprocess.run(
        [sys.argv[1], "--self-check", "--events-fd", str(write_fd)],
        stdout=stdout,
        stderr=stderr,
        pass_fds=(write_fd,),
        check=False,
    )
os.close(write_fd)
if result.returncode == 0 or result.returncode < 0:
    raise SystemExit(f"broken event pipe exited with unsafe status {result.returncode}")
PY
grep -Eqi 'event file descriptor|broken pipe' "$negative_dir/broken-pipe.stderr" \
  || fail "broken event-pipe diagnostic is not useful"

cp "$BIN" "$negative_dir/easysplat-train"
set +e
"$negative_dir/easysplat-train" --self-check --events-fd 1 >"$negative_dir/missing.stdout" 2>"$negative_dir/missing.stderr"
missing_status=$?
set -e
[ "$missing_status" -ne 0 ] || fail "missing metallib self-check falsely succeeded"
[ "$missing_status" -lt 128 ] || fail "missing metallib self-check crashed with status $missing_status"
[ ! -s "$negative_dir/missing.stdout" ] || fail "missing metallib emitted a false success event"
grep -qi 'metallib' "$negative_dir/missing.stderr" || fail "missing metallib diagnostic is not useful"

printf 'not a metallib\n' >"$negative_dir/default.metallib"
set +e
"$negative_dir/easysplat-train" --self-check --events-fd 1 >"$negative_dir/corrupt.stdout" 2>"$negative_dir/corrupt.stderr"
corrupt_status=$?
set -e
[ "$corrupt_status" -ne 0 ] || fail "corrupt metallib self-check falsely succeeded"
[ "$corrupt_status" -lt 128 ] || fail "corrupt metallib self-check crashed with status $corrupt_status"
[ ! -s "$negative_dir/corrupt.stdout" ] || fail "corrupt metallib emitted a false success event"
grep -qi 'metallib' "$negative_dir/corrupt.stderr" || fail "corrupt metallib diagnostic is not useful"

cat >"$negative_dir/incomplete.metal" <<'METAL'
#include <metal_stdlib>
using namespace metal;
kernel void unrelated_kernel(device uint *output [[buffer(0)]], uint index [[thread_position_in_grid]]) {
  output[index] = index;
}
METAL
xcrun -sdk macosx metal -c "$negative_dir/incomplete.metal" -o "$negative_dir/incomplete.air"
xcrun -sdk macosx metallib "$negative_dir/incomplete.air" -o "$negative_dir/default.metallib"
set +e
"$negative_dir/easysplat-train" --self-check --events-fd 1 >"$negative_dir/incomplete.stdout" 2>"$negative_dir/incomplete.stderr"
incomplete_status=$?
set -e
[ "$incomplete_status" -ne 0 ] || fail "incomplete metallib self-check falsely succeeded"
[ "$incomplete_status" -lt 128 ] || fail "incomplete metallib self-check crashed with status $incomplete_status"
[ ! -s "$negative_dir/incomplete.stdout" ] || fail "incomplete metallib emitted a false success event"
grep -Eqi 'kernel|pipeline' "$negative_dir/incomplete.stderr" || fail "incomplete metallib diagnostic is not useful"

valid_ply="$negative_dir/valid.ply"
{
  printf '%s\n' \
    'ply' \
    'format binary_little_endian 1.0' \
    'element vertex 1' \
    'property float x' \
    'property float y' \
    'property float z' \
    'property float nx' \
    'property float ny' \
    'property float nz' \
    'property float f_dc_0' \
    'property float f_dc_1' \
    'property float f_dc_2' \
    'property float opacity' \
    'property float scale_0' \
    'property float scale_1' \
    'property float scale_2' \
    'property float rot_0' \
    'property float rot_1' \
    'property float rot_2' \
    'property float rot_3' \
    'end_header'
  dd if=/dev/zero bs=68 count=1 2>/dev/null
} >"$valid_ply"
"$BIN" --validate-ply "$valid_ply" --events-fd 1 >"$negative_dir/valid-ply.stdout" 2>"$negative_dir/valid-ply.stderr"
require_contains '"event":"output_validation"' "$negative_dir/valid-ply.stdout"
require_contains '"status":"ok"' "$negative_dir/valid-ply.stdout"

allocation_pressure_dir="$negative_dir/allocation-pressure"
allocation_output="$allocation_pressure_dir/existing-valid.ply"
allocation_checkpoint="$allocation_pressure_dir/checkpoint"
mkdir -p "$allocation_pressure_dir/dataset" "$allocation_checkpoint/optimizer"
cp "$valid_ply" "$allocation_output"
printf 'checkpoint receipt sentinel\n' >"$allocation_checkpoint/receipt.json"
printf '\001\003\003\007checkpoint-state\000' >"$allocation_checkpoint/optimizer/state.bin"
allocation_output_hash_before="$(shasum -a 256 "$allocation_output" | awk '{print $1}')"

snapshot_checkpoint_tree() {
  python3 - "$1" <<'PY'
import hashlib
import json
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
entries = []
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix().encode()):
    relative = path.relative_to(root).as_posix()
    status = path.lstat()
    if stat.S_ISDIR(status.st_mode):
        entries.append({
            "mode": stat.S_IMODE(status.st_mode),
            "path": relative,
            "type": "directory",
        })
    elif stat.S_ISREG(status.st_mode):
        entries.append({
            "bytes": status.st_size,
            "mode": stat.S_IMODE(status.st_mode),
            "path": relative,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "type": "file",
        })
    else:
        raise SystemExit(f"unexpected checkpoint entry type: {relative}")
json.dump(entries, sys.stdout, separators=(",", ":"), sort_keys=True)
PY
}

snapshot_checkpoint_tree "$allocation_checkpoint" \
  >"$allocation_pressure_dir/checkpoint-before.json"

set +e
"$ALLOCATION_PRESSURE_TEST_BIN" \
  --dataset "$allocation_pressure_dir/dataset" \
  --output "$allocation_output" \
  --profile fast \
  --iteration-limit 1 \
  --plateau-window 1 \
  --checkpoint "$allocation_checkpoint" \
  --seed 42 \
  --memory-budget-bytes 536870912 \
  --events-fd 1 \
  >"$allocation_pressure_dir/events.jsonl" \
  2>"$allocation_pressure_dir/stderr.log"
allocation_pressure_status=$?
set -e
[ "$allocation_pressure_status" = 71 ] \
  || fail "allocation-pressure test CLI exited with $allocation_pressure_status instead of 71"
python3 - "$allocation_pressure_dir/events.jsonl" <<'PY'
import json
from pathlib import Path
import sys


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit(f"allocation pressure emitted {len(lines)} records instead of one")
event = json.loads(lines[0], parse_constant=reject_constant)
expected_keys = {
    "budget_bytes",
    "current_allocated_bytes",
    "event",
    "iteration",
    "max_buffer_bytes",
    "recommended_working_set_bytes",
    "requested_bytes",
    "required_bytes",
    "schema_version",
    "sequence",
}
if set(event) != expected_keys:
    raise SystemExit(f"allocation event schema is not closed: {sorted(event)}")
if event["event"] != "metal_allocation_unavailable":
    raise SystemExit(f"unexpected allocation event: {event['event']!r}")
if event["schema_version"] != 2 or event["sequence"] != 1 or event["iteration"] != 0:
    raise SystemExit("allocation event sequencing or terminal iteration is wrong")
integer_fields = expected_keys - {"event"}
if any(type(event[field]) is not int for field in integer_fields):
    raise SystemExit("allocation event contains a non-integer numeric field")
if event["budget_bytes"] != 536_870_912 or event["requested_bytes"] != 67_108_864:
    raise SystemExit("allocation event lost the configured budget or deterministic request")
if event["current_allocated_bytes"] < 0:
    raise SystemExit("allocation event reported a negative current allocation")
if event["required_bytes"] != event["current_allocated_bytes"] + event["requested_bytes"]:
    raise SystemExit("allocation event required-byte arithmetic is inconsistent")
if event["max_buffer_bytes"] <= 0 or event["recommended_working_set_bytes"] <= 0:
    raise SystemExit("allocation event omitted live Metal device limits")
PY
grep -Fq 'metal_allocation_unavailable requested_bytes=67108864' \
  "$allocation_pressure_dir/stderr.log" \
  || fail "allocation-pressure stderr omitted the native Metal allocation diagnostic"
[ "$(shasum -a 256 "$allocation_output" | awk '{print $1}')" = "$allocation_output_hash_before" ] \
  || fail "allocation pressure changed the preexisting valid PLY"
"$BIN" --validate-ply "$allocation_output" --events-fd 1 \
  >"$allocation_pressure_dir/valid-ply-after.stdout" \
  2>"$allocation_pressure_dir/valid-ply-after.stderr"
snapshot_checkpoint_tree "$allocation_checkpoint" \
  >"$allocation_pressure_dir/checkpoint-after.json"
cmp -s \
  "$allocation_pressure_dir/checkpoint-before.json" \
  "$allocation_pressure_dir/checkpoint-after.json" \
  || fail "allocation pressure changed preexisting checkpoint bytes or entries"

truncated_ply="$negative_dir/truncated.ply"
cp "$valid_ply" "$truncated_ply"
truncate -s -4 "$truncated_ply"
set +e
"$BIN" --validate-ply "$truncated_ply" --events-fd 1 >"$negative_dir/truncated-ply.stdout" 2>"$negative_dir/truncated-ply.stderr"
truncated_status=$?
set -e
[ "$truncated_status" -ne 0 ] || fail "truncated PLY validation falsely succeeded"
[ ! -s "$negative_dir/truncated-ply.stdout" ] || fail "truncated PLY emitted a false success event"
grep -qi 'payload' "$negative_dir/truncated-ply.stderr" || fail "truncated PLY diagnostic is not useful"

for key in \
  source_commit source_version source_url source_tree_sha256 \
  overlay_sha256 raster_test_sha256 \
  isolation_header_sha256 isolation_source_sha256 \
  isolation_runtime_header_sha256 isolation_runtime_source_sha256 \
  isolation_mask_header_sha256 isolation_mask_source_sha256 \
  isolation_lift_source_sha256 isolation_test_sha256 \
  isolation_mask_test_sha256 isolation_patch_sha256 \
  patch_sha256 source_notice_patch_sha256 checkpoint_patch_sha256 \
  numeric_stability_patch_sha256 metal_safety_patch_sha256 \
  exact_raster_patch_sha256 stage_timing_patch_sha256 \
  memory_efficiency_patch_sha256 densification_memory_patch_sha256 \
  row_span_culling_patch_sha256 geometry_adam_fusion_patch_sha256 \
  parallel_radix_scan_patch_sha256 allocation_pressure_patch_sha256 \
  exact_prefix_hardening_patch_sha256 quaternion_stability_patch_sha256 \
  executable_sha256 metallib_sha256 compiler deployment_target \
  cmake_arguments build_timestamp; do
  require_contains "\"$key\"" "$BUILD_INFO"
done
overlay_hash="$(shasum -a 256 "$OVERLAY" | awk '{print $1}')"
isolation_header_hash="$(shasum -a 256 "$ISOLATION_HEADER" | awk '{print $1}')"
isolation_source_hash="$(shasum -a 256 "$ISOLATION_SOURCE" | awk '{print $1}')"
isolation_runtime_header_hash="$(shasum -a 256 "$ISOLATION_RUNTIME_HEADER" | awk '{print $1}')"
isolation_runtime_source_hash="$(shasum -a 256 "$ISOLATION_RUNTIME_SOURCE" | awk '{print $1}')"
isolation_mask_header_hash="$(shasum -a 256 "$ISOLATION_MASK_HEADER" | awk '{print $1}')"
isolation_mask_source_hash="$(shasum -a 256 "$ISOLATION_MASK_SOURCE" | awk '{print $1}')"
isolation_lift_source_hash="$(shasum -a 256 "$ISOLATION_METAL_SOURCE" | awk '{print $1}')"
isolation_test_hash="$(shasum -a 256 "$ISOLATION_TEST_SOURCE" | awk '{print $1}')"
isolation_mask_test_hash="$(shasum -a 256 "$ISOLATION_MASK_TEST_SOURCE" | awk '{print $1}')"
isolation_patch_hash="$(shasum -a 256 "$ISOLATION_PATCH" | awk '{print $1}')"
source_notice_patch_hash="$(shasum -a 256 "$SOURCE_NOTICE_PATCH" | awk '{print $1}')"
numeric_stability_patch_hash="$(shasum -a 256 "$NUMERIC_STABILITY_PATCH" | awk '{print $1}')"
metal_safety_patch_hash="$(shasum -a 256 "$METAL_SAFETY_PATCH" | awk '{print $1}')"
exact_raster_patch_hash="$(shasum -a 256 "$EXACT_RASTER_PATCH" | awk '{print $1}')"
stage_timing_patch_hash="$(shasum -a 256 "$STAGE_TIMING_PATCH" | awk '{print $1}')"
memory_efficiency_patch_hash="$(shasum -a 256 "$MEMORY_EFFICIENCY_PATCH" | awk '{print $1}')"
densification_memory_patch_hash="$(shasum -a 256 "$DENSIFICATION_MEMORY_PATCH" | awk '{print $1}')"
row_span_culling_patch_hash="$(shasum -a 256 "$ROW_SPAN_CULLING_PATCH" | awk '{print $1}')"
geometry_adam_fusion_patch_hash="$(shasum -a 256 "$GEOMETRY_ADAM_FUSION_PATCH" | awk '{print $1}')"
parallel_radix_scan_patch_hash="$(shasum -a 256 "$PARALLEL_RADIX_SCAN_PATCH" | awk '{print $1}')"
allocation_pressure_patch_hash="$(shasum -a 256 "$ALLOCATION_PRESSURE_PATCH" | awk '{print $1}')"
exact_prefix_hardening_patch_hash="$(shasum -a 256 "$EXACT_PREFIX_HARDENING_PATCH" | awk '{print $1}')"
quaternion_stability_patch_hash="$(shasum -a 256 "$QUATERNION_STABILITY_PATCH" | awk '{print $1}')"
raster_test_hash="$(shasum -a 256 "$RASTER_TEST_SOURCE" | awk '{print $1}')"
exe_hash="$(shasum -a 256 "$BIN" | awk '{print $1}')"
metallib_hash="$(shasum -a 256 "$METALLIB" | awk '{print $1}')"
python3 - "$BUILD_INFO" \
  "$overlay_hash" \
  "$isolation_header_hash" "$isolation_source_hash" \
  "$isolation_runtime_header_hash" "$isolation_runtime_source_hash" \
  "$isolation_mask_header_hash" "$isolation_mask_source_hash" \
  "$isolation_lift_source_hash" "$isolation_test_hash" \
  "$isolation_mask_test_hash" "$isolation_patch_hash" \
  "$source_notice_patch_hash" "$numeric_stability_patch_hash" \
  "$metal_safety_patch_hash" "$exact_raster_patch_hash" \
  "$stage_timing_patch_hash" "$memory_efficiency_patch_hash" \
  "$densification_memory_patch_hash" "$row_span_culling_patch_hash" \
  "$geometry_adam_fusion_patch_hash" "$parallel_radix_scan_patch_hash" \
  "$allocation_pressure_patch_hash" "$exact_prefix_hardening_patch_hash" \
  "$quaternion_stability_patch_hash" "$raster_test_hash" \
  "$exe_hash" "$metallib_hash" <<'PY'
import json
import sys


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source, parse_constant=reject_constant)
expected = {
    "source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
    "source_version": "1.1.3",
    "overlay_sha256": sys.argv[2],
    "isolation_header_sha256": sys.argv[3],
    "isolation_source_sha256": sys.argv[4],
    "isolation_runtime_header_sha256": sys.argv[5],
    "isolation_runtime_source_sha256": sys.argv[6],
    "isolation_mask_header_sha256": sys.argv[7],
    "isolation_mask_source_sha256": sys.argv[8],
    "isolation_lift_source_sha256": sys.argv[9],
    "isolation_test_sha256": sys.argv[10],
    "isolation_mask_test_sha256": sys.argv[11],
    "isolation_patch_sha256": sys.argv[12],
    "source_notice_patch_sha256": sys.argv[13],
    "numeric_stability_patch_sha256": sys.argv[14],
    "metal_safety_patch_sha256": sys.argv[15],
    "exact_raster_patch_sha256": sys.argv[16],
    "stage_timing_patch_sha256": sys.argv[17],
    "memory_efficiency_patch_sha256": sys.argv[18],
    "densification_memory_patch_sha256": sys.argv[19],
    "row_span_culling_patch_sha256": sys.argv[20],
    "geometry_adam_fusion_patch_sha256": sys.argv[21],
    "parallel_radix_scan_patch_sha256": sys.argv[22],
    "allocation_pressure_patch_sha256": sys.argv[23],
    "exact_prefix_hardening_patch_sha256": sys.argv[24],
    "quaternion_stability_patch_sha256": sys.argv[25],
    "raster_test_sha256": sys.argv[26],
    "executable_sha256": sys.argv[27],
    "metallib_sha256": sys.argv[28],
}
for key, value in expected.items():
    if payload.get(key) != value:
        raise SystemExit(f"build provenance {key} mismatch")
PY

if grep -Eq '(/Users/|/home/|"hostname"|"username"|"source_path")' "$BUILD_INFO"; then
  fail "build provenance contains a private or machine-local field"
fi

"$VALIDATOR" --source "$INSTALL_DIR"

validate_jsonl() {
  local jsonl="$1"
  python3 - "$jsonl" <<'PY'
import json
import sys
from pathlib import Path


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
for expected_sequence, line in enumerate(lines, start=1):
    try:
        record = json.loads(line, parse_constant=reject_constant)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"stdout contains a non-JSONL line: {exc}") from exc
    if not isinstance(record, dict):
        raise SystemExit(f"JSONL record {expected_sequence} is not an object")
    if record.get("sequence") != expected_sequence:
        raise SystemExit(f"JSONL sequence is not monotonic at {expected_sequence}")
PY
}

validate_training_events() {
  local jsonl="$1"
  local expected_points="$2"
  local metal_pipeline_stress="$3"
  local expected_memory_budget="$4"
  python3 - "$jsonl" "$expected_points" "$metal_pipeline_stress" "$expected_memory_budget" <<'PY'
import json
import math
import sys
from pathlib import Path


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


records = [
    json.loads(line, parse_constant=reject_constant)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
]
if len(records) < 3:
    raise SystemExit("training emitted fewer than three events")
for index, record in enumerate(records, start=1):
    if record.get("schema_version") != 2 or record.get("sequence") != index:
        raise SystemExit(f"invalid event envelope at sequence {index}")
    for value in record.values():
        if isinstance(value, float) and not math.isfinite(value):
            raise SystemExit(f"non-finite event value at sequence {index}")
started = records[0]
completed = records[-1]
expected_points = int(sys.argv[2])
metal_pipeline_stress = sys.argv[3] == "true"
expected_memory_budget = int(sys.argv[4])
if started.get("event") != "started" or completed.get("event") != "completed":
    raise SystemExit("training event stream has invalid boundaries")
if started.get("initial_gaussian_count") != expected_points:
    raise SystemExit("started event has the wrong sparse-point count")
expected_contract = {
    "checkpoint_schema": 3,
    "dropped_intersection_count": 0,
    "iteration_limit": 3000,
    "memory_budget_bytes": expected_memory_budget,
    "payload_schema": 2,
    "plateau_window": 400,
    "profile": "fast",
    "raster_exact_buffer_bytes_added": 0,
    "raster_exact_buffer_growth_count": 0,
    "raster_exact_fallback_elapsed_seconds": 0,
    "raster_fallback_count": 0,
    "raster_peak_exact_intersection_capacity": 0,
    "raster_replay_elapsed_seconds": 0,
    "seed": 42,
}
for key, expected in expected_contract.items():
    if started.get(key) != expected:
        raise SystemExit(f"training profile contract mismatch for {key}")
completed_contract = {
    "dropped_intersection_count": 0,
    "iteration_limit": 3000,
    "memory_budget_bytes": expected_memory_budget,
    "plateau_window": 400,
    "profile": "fast",
    "seed": 42,
}
for key, expected in completed_contract.items():
    if completed.get(key) != expected:
        raise SystemExit(f"completed contract mismatch for {key}")
fallback_count = completed.get("raster_fallback_count")
if isinstance(fallback_count, bool) or not isinstance(fallback_count, int) or fallback_count < 0:
    raise SystemExit("completed event has invalid raster fallback evidence")
recovery_integer_fields = (
    "raster_exact_buffer_bytes_added",
    "raster_exact_buffer_growth_count",
    "raster_peak_exact_intersection_capacity",
)
recovery_elapsed_fields = (
    "raster_exact_fallback_elapsed_seconds",
    "raster_replay_elapsed_seconds",
)
for key in recovery_integer_fields:
    value = completed.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SystemExit(f"completed event has invalid {key}")
for key in recovery_elapsed_fields:
    value = completed.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise SystemExit(f"completed event has invalid {key}")
if completed["raster_exact_buffer_growth_count"] > fallback_count:
    raise SystemExit("completed event reports more exact allocations than dispatches")
if fallback_count == 0 and any(completed[key] != 0 for key in recovery_integer_fields + recovery_elapsed_fields):
    raise SystemExit("completed event reports raster recovery work without a fallback")
for record in records:
    if record.get("event") != "checkpoint_completed":
        continue
    for key in (
        "memory_budget_bytes",
        "raster_exact_buffer_bytes_added",
        "raster_exact_buffer_growth_count",
        "raster_fallback_count",
        "raster_peak_exact_intersection_capacity",
        "dropped_intersection_count",
    ):
        if isinstance(record.get(key), bool) or not isinstance(record.get(key), int):
            raise SystemExit(f"checkpoint event has invalid {key}")
    for key in recovery_elapsed_fields:
        value = record.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise SystemExit(f"checkpoint event has invalid {key}")
    if record["memory_budget_bytes"] != expected_memory_budget or record["dropped_intersection_count"] != 0:
        raise SystemExit("checkpoint event lost the raster run contract")
iterations = [
    record["iteration"]
    for record in records
    if record.get("event") in {"progress", "early_stop", "completed"}
]
if not iterations or iterations != sorted(iterations) or iterations[-1] > 3000:
    raise SystemExit("training iterations are not monotonic and bounded")
if completed.get("stop_reason") not in {"iteration_limit", "plateau"}:
    raise SystemExit("completed event has an invalid stop reason")
if completed.get("gaussian_count", 0) <= 0 or completed.get("output_bytes", 0) <= 0:
    raise SystemExit("completed event is missing output evidence")
scene_center = completed.get("scene_center")
scene_radius = completed.get("scene_radius")
if (
    not isinstance(scene_center, list)
    or len(scene_center) != 3
    or any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
           for value in scene_center)
    or isinstance(scene_radius, bool)
    or not isinstance(scene_radius, (int, float))
    or not math.isfinite(scene_radius)
    or scene_radius <= 0
):
    raise SystemExit("completed event has invalid robust scene bounds")
memory_records = [
    record
    for record in records
    if record.get("event") in {"checkpoint_completed", "checkpoint_loaded", "completed"}
]
if not memory_records:
    raise SystemExit("training emitted no peak-memory evidence")
peak_memory_values = []
for record in memory_records:
    peak_memory_bytes = record.get("peak_memory_bytes")
    if (
        isinstance(peak_memory_bytes, bool)
        or not isinstance(peak_memory_bytes, int)
        or peak_memory_bytes <= 0
    ):
        raise SystemExit(
            f"{record.get('event')} is missing positive peak-memory evidence"
        )
    peak_memory_values.append(peak_memory_bytes)
if peak_memory_values != sorted(peak_memory_values):
    raise SystemExit("peak resident memory decreased within one process")
if metal_pipeline_stress and peak_memory_values[-1] > 512 * 1024 * 1024:
    raise SystemExit(
        "Metal pipeline stress exceeded the 512 MiB resident-memory ceiling: "
        f"{peak_memory_values[-1]} bytes"
    )
if sum(record.get("event") == "completed" for record in records) != 1:
    raise SystemExit("training emitted multiple completion records")
PY
}

validate_ply_scene_bounds() {
  local jsonl="$1"
  local ply="$2"
  python3 - "$jsonl" "$ply" <<'PY'
import json
import math
import statistics
import struct
import sys
from pathlib import Path


records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
completed = [record for record in records if record.get("event") == "completed"]
if len(completed) != 1:
    raise SystemExit("scene-bounds parity requires one completed event")
completed = completed[0]

with Path(sys.argv[2]).open("rb") as source:
    if source.readline() != b"ply\n":
        raise SystemExit("scene-bounds parity expected a PLY output")
    properties = []
    vertex_count = None
    in_vertices = False
    while True:
        line = source.readline()
        if not line:
            raise SystemExit("scene-bounds parity found a truncated PLY header")
        fields = line.decode("ascii").strip().split()
        if fields[:2] == ["format", "binary_little_endian"]:
            continue
        if fields[:2] == ["element", "vertex"]:
            vertex_count = int(fields[2])
            in_vertices = True
        elif fields[:1] == ["element"]:
            in_vertices = False
        elif in_vertices and fields[:2] == ["property", "float"]:
            properties.append(fields[2])
        elif fields == ["end_header"]:
            break
    if vertex_count is None or not properties:
        raise SystemExit("scene-bounds parity found no PLY vertices")
    required = {"x", "y", "z", "opacity", "scale_0", "scale_1", "scale_2"}
    if not required.issubset(properties):
        raise SystemExit("scene-bounds parity is missing required PLY properties")
    row = struct.Struct("<" + "f" * len(properties))
    samples = []
    for _ in range(vertex_count):
        payload = source.read(row.size)
        if len(payload) != row.size:
            raise SystemExit("scene-bounds parity found a truncated PLY payload")
        values = dict(zip(properties, row.unpack(payload), strict=True))
        raw = [
            values["x"], values["y"], values["z"], values["opacity"],
            values["scale_0"], values["scale_1"], values["scale_2"],
        ]
        if not all(math.isfinite(value) for value in raw):
            continue
        physical_scales = [math.exp(value) for value in raw[4:]]
        if not all(math.isfinite(value) and value > 0 for value in physical_scales):
            continue
        opacity = raw[3]
        alpha = (
            1 / (1 + math.exp(-opacity))
            if opacity >= 0
            else math.exp(opacity) / (1 + math.exp(opacity))
        )
        samples.append((raw[:3], max(physical_scales), alpha))
    if source.read(1):
        raise SystemExit("scene-bounds parity found trailing PLY payload")

if completed.get("gaussian_count") != vertex_count or not samples:
    raise SystemExit("scene-bounds parity has inconsistent Gaussian counts")
opaque = [sample for sample in samples if sample[2] >= 0.01]
minimum_opaque = min(len(samples), max(8, (len(samples) + 999) // 1000))
selected = opaque if len(opaque) >= minimum_opaque else samples
center = [statistics.median(sample[0][axis] for sample in selected) for axis in range(3)]
extents = sorted(
    math.dist(sample[0], center) + 3 * sample[1]
    for sample in selected
)
radius = extents[max(1, (995 * len(extents) + 999) // 1000) - 1]
reported_center = completed.get("scene_center")
reported_radius = completed.get("scene_radius")
if not isinstance(reported_center, list) or len(reported_center) != 3:
    raise SystemExit("completed event has no scene center for PLY parity")
for axis, (reported, actual) in enumerate(zip(reported_center, center, strict=True)):
    if not math.isclose(reported, actual, rel_tol=1e-6, abs_tol=1e-6):
        raise SystemExit(f"completed scene center axis {axis} disagrees with emitted PLY")
if not math.isclose(reported_radius, radius, rel_tol=1e-6, abs_tol=1e-6):
    raise SystemExit("completed scene radius disagrees with emitted PLY")
PY
}

assert_identity_input_rejected() {
  local label="$1"
  local dataset="$2"
  local diagnostic_pattern="$3"
  local result_dir="$negative_dir/identity-rejection-$label"
  mkdir -p "$result_dir"

  set +e
  "$BIN" \
    --dataset "$dataset" \
    --output "$result_dir/splat.ply" \
    --profile fast \
    --checkpoint "$result_dir/checkpoint" \
    --seed 42 \
    --memory-budget-bytes 536870912 \
    --events-fd 1 \
    >"$result_dir/events.jsonl" 2>"$result_dir/stderr.log"
  local status=$?
  set -e

  [ "$status" -eq 1 ] || fail "$label identity input exited with unexpected status $status"
  [ ! -s "$result_dir/events.jsonl" ] || fail "$label identity input emitted a training event"
  [ ! -e "$result_dir/checkpoint" ] || fail "$label identity input created a checkpoint"
  [ ! -e "$result_dir/splat.ply" ] || fail "$label identity input published an output"
  grep -Eqi "$diagnostic_pattern" "$result_dir/stderr.log" \
    || fail "$label identity input diagnostic is not useful"
}

fixture_root="$negative_dir/sparse-fixtures"
existing_fixture_root="$negative_dir/existing-fixture-output"
mkdir -p "$existing_fixture_root"
printf 'preserve\n' >"$existing_fixture_root/sentinel"
if python3 "$FIXTURE_GENERATOR" --output "$existing_fixture_root" >/dev/null 2>&1; then
  fail "sparse fixture generator replaced an existing directory"
fi
require_contains 'preserve' "$existing_fixture_root/sentinel"
python3 "$FIXTURE_GENERATOR" --output "$fixture_root"
python3 - "$fixture_root/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
stress = [fixture for fixture in manifest["fixtures"] if fixture.get("numeric_stability_stress")]
if len(stress) != 1:
    raise SystemExit("sparse fixtures must contain exactly one numeric-stability stress case")
fixture = stress[0]
if fixture.get("resolution") != [320, 180] or fixture.get("point_count") != 1279:
    raise SystemExit("numeric-stability stress fixture contract changed")
metal_stress = [
    fixture for fixture in manifest["fixtures"] if fixture.get("metal_pipeline_stress")
]
if metal_stress != stress:
    raise SystemExit("Metal pipeline stress must use the numeric-stability fixture")
overflow = [
    fixture for fixture in manifest["fixtures"] if fixture.get("raster_overflow_stress")
]
if len(overflow) != 1 or overflow[0].get("dataset") != "13-overflow-2304":
    raise SystemExit("sparse fixtures must contain the exact-raster overflow case")
if overflow[0].get("point_count") != 2304 or overflow[0].get("resolution") != [32, 32]:
    raise SystemExit("exact-raster overflow fixture contract changed")
broad = [fixture for fixture in manifest["fixtures"] if fixture.get("broad_raster_stress")]
if len(broad) != 1 or broad[0].get("dataset") != "16-broad-overflow-2304":
    raise SystemExit("sparse fixtures must contain the broad-splat growth case")
replay = [fixture for fixture in manifest["fixtures"] if fixture.get("raster_replay_stress")]
if len(replay) != 1 or replay[0].get("dataset") != "15-increasing-overflow-10000":
    raise SystemExit("sparse fixtures must contain the increasing replay case")
exact_budget = [fixture for fixture in manifest["fixtures"] if fixture.get("exact_budget_stress")]
if len(exact_budget) != 1 or exact_budget[0].get("dataset") != "17-exact-budget-1279":
    raise SystemExit("sparse fixtures must contain the exact-only budget case")
if exact_budget[0].get("point_count") != 1279 or exact_budget[0].get("resolution") != [640, 360]:
    raise SystemExit("exact-only budget fixture contract changed")
mixed = [
    fixture for fixture in manifest["fixtures"] if fixture.get("mixed_resolution_stress")
]
if len(mixed) != 1 or mixed[0].get("dataset") != "14-mixed-resolution-500":
    raise SystemExit("sparse fixtures must contain the mixed-resolution growth case")
if mixed[0].get("resolution") != [[32, 32], [320, 180]]:
    raise SystemExit("mixed-resolution fixture contract changed")
PY

hardlinked_image_dataset="$negative_dir/hardlinked-image-dataset"
cp -R "$fixture_root/01-sphere-500" "$hardlinked_image_dataset"
cp "$hardlinked_image_dataset/images/0000.png" "$negative_dir/hardlinked-image-source.png"
rm "$hardlinked_image_dataset/images/0000.png"
ln "$negative_dir/hardlinked-image-source.png" "$hardlinked_image_dataset/images/0000.png"
assert_identity_input_rejected \
  "hardlinked-image" "$hardlinked_image_dataset" 'single-link|hard.?link'

hardlinked_bin_dataset="$negative_dir/hardlinked-bin-dataset"
cp -R "$fixture_root/01-sphere-500" "$hardlinked_bin_dataset"
cp "$hardlinked_bin_dataset/sparse/0/cameras.bin" "$negative_dir/hardlinked-cameras-source.bin"
rm "$hardlinked_bin_dataset/sparse/0/cameras.bin"
ln "$negative_dir/hardlinked-cameras-source.bin" "$hardlinked_bin_dataset/sparse/0/cameras.bin"
assert_identity_input_rejected \
  "hardlinked-bin" "$hardlinked_bin_dataset" 'single-link|hard.?link'

extra_directory_dataset="$negative_dir/extra-directory-dataset"
cp -R "$fixture_root/01-sphere-500" "$extra_directory_dataset"
mkdir "$extra_directory_dataset/images/unexpected"
assert_identity_input_rejected \
  "extra-directory" "$extra_directory_dataset" 'supported|ordinary|image'

extra_file_dataset="$negative_dir/extra-file-dataset"
cp -R "$fixture_root/01-sphere-500" "$extra_file_dataset"
printf 'not an image\n' >"$extra_file_dataset/images/notes.txt"
assert_identity_input_rejected \
  "extra-file" "$extra_file_dataset" 'supported|ordinary|image'

identity_mismatch_dir="$negative_dir/expected-identity-mismatch"
identity_mismatch_checkpoint="$identity_mismatch_dir/checkpoint"
mkdir -p "$identity_mismatch_checkpoint/generations"
printf 'preserve-current\n' >"$identity_mismatch_checkpoint/CURRENT"
printf 'preserve-generation\n' >"$identity_mismatch_checkpoint/generations/sentinel"
set +e
"$BIN" \
  --dataset "$fixture_root/01-sphere-500" \
  --output "$identity_mismatch_dir/splat.ply" \
  --profile fast \
  --checkpoint "$identity_mismatch_checkpoint" \
  --seed 42 \
  --expected-input-digest "$(printf '0%.0s' {1..64})" \
  --expected-geometry-digest "$(printf '1%.0s' {1..64})" \
  --memory-budget-bytes 536870912 \
  --events-fd 1 \
  >"$identity_mismatch_dir/events.jsonl" 2>"$identity_mismatch_dir/stderr.log"
identity_mismatch_status=$?
set -e
[ "$identity_mismatch_status" -eq 1 ] \
  || fail "expected dataset identity mismatch exited with status $identity_mismatch_status"
[ ! -s "$identity_mismatch_dir/events.jsonl" ] \
  || fail "expected dataset identity mismatch emitted a training event"
[ ! -e "$identity_mismatch_dir/splat.ply" ] \
  || fail "expected dataset identity mismatch published an output"
require_contains 'preserve-current' "$identity_mismatch_checkpoint/CURRENT"
require_contains 'preserve-generation' "$identity_mismatch_checkpoint/generations/sentinel"
[ "$(find "$identity_mismatch_checkpoint" -type f | wc -l | tr -d ' ')" = "2" ] \
  || fail "expected dataset identity mismatch changed durable checkpoint contents"
grep -qi 'expected digests' "$identity_mismatch_dir/stderr.log" \
  || fail "expected dataset identity mismatch diagnostic is not useful"

require_file "$RASTER_TEST_BIN"
[ -x "$RASTER_TEST_BIN" ] || fail "raster parity test is not executable: $RASTER_TEST_BIN"
"$RASTER_TEST_BIN" \
  "$fixture_root/01-sphere-500" \
  "$fixture_root/14-mixed-resolution-500" \
  "$fixture_root/13-overflow-2304" \
  "$fixture_root/16-broad-overflow-2304" \
  "$fixture_root/15-increasing-overflow-10000" \
  "$fixture_root/17-exact-budget-1279"
"$RASTER_TEST_BIN" --prefix-oracle
"$RASTER_TEST_BIN" --radix-oracle
"$RASTER_TEST_BIN" --quaternion-vjp
fixture_count=0
while IFS=$'\t' read -r fixture_name expected_points metal_pipeline_stress; do
  fixture_count=$((fixture_count + 1))
  training_fixture="$fixture_root/$fixture_name"
  training_dir="$negative_dir/training-$fixture_name"
  memory_budget_bytes=536870912
  validation_environment=(env)
  mkdir -p "$training_dir"
  if ! "${validation_environment[@]}" "$BIN" \
    --dataset "$training_fixture" \
    --output "$training_dir/splat.ply" \
    --profile fast \
    --checkpoint "$training_dir/checkpoint" \
    --seed 42 \
    --memory-budget-bytes "$memory_budget_bytes" \
    --events-fd 1 \
    >"$training_dir/events.jsonl" 2>"$training_dir/stderr.log"; then
    sed -n '1,200p' "$training_dir/stderr.log" >&2
    fail "$fixture_name training failed"
  fi
  if [ "$metal_pipeline_stress" = "true" ] &&
     grep -Eqi 'shader validation|invalid (device|threadgroup|texture)|validation (error|fault)|gpu fault' \
       "$training_dir/stderr.log"; then
    sed -n '1,200p' "$training_dir/stderr.log" >&2
    fail "$fixture_name emitted Metal validation diagnostics"
  fi
  validate_jsonl "$training_dir/events.jsonl"
  validate_training_events \
    "$training_dir/events.jsonl" "$expected_points" "$metal_pipeline_stress" \
    "$memory_budget_bytes"
  [ -s "$training_dir/splat.ply" ] || fail "Fast-profile training did not atomically publish a nonempty PLY"
  "$BIN" --validate-ply "$training_dir/splat.ply" --events-fd 1 \
    >"$training_dir/validation.jsonl" 2>"$training_dir/validation.stderr"
  require_contains '"status":"ok"' "$training_dir/validation.jsonl"
  if [ "$fixture_name" = "01-sphere-500" ]; then
    validate_ply_scene_bounds "$training_dir/events.jsonl" "$training_dir/splat.ply"
  fi
  if find "$training_dir" -maxdepth 1 -name '*.tmp.*' -print -quit | grep -q .; then
    fail "Fast-profile training left a temporary output behind"
  fi
done < <(python3 - "$fixture_root/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for fixture in manifest["fixtures"]:
    if (
        fixture.get("raster_overflow_stress")
        or fixture.get("mixed_resolution_stress")
        or fixture.get("broad_raster_stress")
        or fixture.get("raster_replay_stress")
        or fixture.get("exact_budget_stress")
    ):
        continue
    metal_stress = "true" if fixture.get("metal_pipeline_stress") else "false"
    print(f'{fixture["dataset"]}\t{fixture["point_count"]}\t{metal_stress}')
PY
)
[ "$fixture_count" = "12" ] || fail "sparse fixture generator did not produce twelve cases"

isolation_runtime_dir="$negative_dir/background-mask-runtime"
mkdir "$isolation_runtime_dir"
isolation_runtime_source="$negative_dir/training-01-sphere-500/splat.ply"
[ -s "$isolation_runtime_source" ] \
  || fail "isolation runtime fixture has no trained source PLY"
python3 - "$isolation_runtime_dir" \
  "$negative_dir/training-01-sphere-500/checkpoint" \
  "$isolation_runtime_source" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

from PIL import Image

root, checkpoint, source = map(Path, sys.argv[1:])
current = checkpoint / "CURRENT"
generation = current.read_text(encoding="utf-8").strip()
if (
    not generation
    or "/" in generation
    or "\\" in generation
    or generation in {".", ".."}
):
    raise SystemExit("isolation runtime fixture has no valid current checkpoint")
manifest = checkpoint / "generations" / generation / "manifest.json"
if not manifest.is_file():
    raise SystemExit("isolation runtime fixture has no current checkpoint manifest")
training = json.loads(manifest.read_text(encoding="utf-8"))
input_digest = training["input_digest"]
geometry_digest = training["geometry_digest"]
source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
selected_frames_digest = "2" * 64
training_manifest_digest = "3" * 64


def write_mask(name: str, label: int) -> tuple[str, str]:
    path = root / name
    Image.new("L", (32, 32), label).save(path, format="PNG")
    return name, hashlib.sha256(path.read_bytes()).hexdigest()


blank_work = write_mask("blank-work.png", 0)
blank_held_out = write_mask("blank-held-out.png", 0)
foreground_work = [
    write_mask(f"foreground-work-{index}.png", 1)
    for index in range(3)
]


def write_manifest(name: str, views: list[tuple[int, str, tuple[str, str]]]) -> None:
    payload = {
        "schema_version": 1,
        "isolation_mode_version": 1,
        "source_ply_digest": source_digest,
        "input_digest": input_digest,
        "geometry_digest": geometry_digest,
        "selected_frames_digest": selected_frames_digest,
        "training_manifest_digest": training_manifest_digest,
        "selected_image_order": [f"{index:04d}.png" for index, _, _ in views],
        "views": [
            {
                "image_identity": f"{index:04d}.png",
                "camera_index": index,
                "role": role,
                "relative_mask_path": mask[0],
                "mask_sha256": mask[1],
                "width": 32,
                "height": 32,
            }
            for index, role, mask in views
        ],
    }
    (root / name).write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")


write_manifest(
    "all-background.json",
    [(0, "work", blank_work), (1, "held_out", blank_held_out)],
)
write_manifest(
    "blank-held-out.json",
    [(0, "work", foreground_work[0]), (1, "work", foreground_work[1]),
     (2, "work", foreground_work[2]), (3, "held_out", blank_held_out)],
)
(root / "digests.json").write_text(
    json.dumps(
        {
            "source": source_digest,
            "input": input_digest,
            "geometry": geometry_digest,
            "selected_frames": selected_frames_digest,
            "training_manifest": training_manifest_digest,
        },
        separators=(",", ":"),
    ),
    encoding="utf-8",
)
PY
read -r isolation_source_digest isolation_input_digest isolation_geometry_digest \
  isolation_selected_frames_digest isolation_training_manifest_digest <<EOF
$(python3 - "$isolation_runtime_dir/digests.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(
    payload["source"], payload["input"], payload["geometry"],
    payload["selected_frames"], payload["training_manifest"]
)
PY
)
EOF

run_background_mask_runtime_case() {
  local manifest="$1"
  local cache="$2"
  local output="$3"
  local events="$4"
  "$BIN" --isolate \
    --dataset "$fixture_root/01-sphere-500" \
    --source-ply "$isolation_runtime_source" \
    --mask-manifest "$manifest" \
    --analysis-cache "$cache" \
    --output "$output" \
    --expected-source-ply-digest "$isolation_source_digest" \
    --expected-input-digest "$isolation_input_digest" \
    --expected-geometry-digest "$isolation_geometry_digest" \
    --expected-selected-frames-digest "$isolation_selected_frames_digest" \
    --expected-training-manifest-digest "$isolation_training_manifest_digest" \
    --memory-budget-bytes 536870912 \
    --events-fd 1 >"$events"
}

all_background_output="$isolation_runtime_dir/all-background-output.ply"
run_background_mask_runtime_case \
  "$isolation_runtime_dir/all-background.json" \
  "$isolation_runtime_dir/all-background.cache" \
  "$all_background_output" \
  "$isolation_runtime_dir/all-background.events.jsonl"
[ ! -e "$all_background_output" ] \
  || fail "all-background work masks published a PLY"

blank_held_out_output="$isolation_runtime_dir/blank-held-out-output.ply"
run_background_mask_runtime_case \
  "$isolation_runtime_dir/blank-held-out.json" \
  "$isolation_runtime_dir/blank-held-out.cache" \
  "$blank_held_out_output" \
  "$isolation_runtime_dir/blank-held-out.events.jsonl"
[ ! -e "$blank_held_out_output" ] \
  || fail "background-only held-out mask published a PLY"
python3 - "$isolation_runtime_dir/all-background.events.jsonl" \
  "$isolation_runtime_dir/blank-held-out.events.jsonl" <<'PY'
import json
import sys
from pathlib import Path


def events(path: str) -> list[dict]:
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines()]


all_background, blank_held_out = map(events, sys.argv[1:])
if not any(event.get("event") == "isolation_no_subject" for event in all_background):
    raise SystemExit("all-background work masks did not reach isolation_no_subject")
if any(event.get("event") == "isolation_completed" for event in all_background):
    raise SystemExit("all-background work masks emitted isolation_completed")
rejections = [
    event for event in blank_held_out
    if event.get("event") == "isolation_held_out_rejected"
]
if len(rejections) != 1:
    raise SystemExit("background-only held-out mask did not reach held-out rejection")
if any(event.get("event") == "isolation_completed" for event in blank_held_out):
    raise SystemExit("background-only held-out mask emitted isolation_completed")
evidence = rejections[0].get("held_out_evidence")
if evidence != [{"best_instance": 0, "image_identity": "0003.png", "soft_iou": 0.0}]:
    raise SystemExit(f"background-only held-out evidence changed: {evidence!r}")
PY

# Shader validation changes floating-point scheduling enough to make a long,
# adversarial convergence run nondeterministic on some hosted GPUs. Keep the
# full 3,000-iteration production runs above, then exercise the instrumented
# Metal pipeline on a stable fixture through warmup, densification, and
# publication.
metal_validation_dir="$negative_dir/metal-validation-01-sphere-500"
mkdir -p "$metal_validation_dir"
if ! env \
    MTL_DEBUG_LAYER=1 \
    MTL_SHADER_VALIDATION=1 \
    MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING=1 \
    MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 \
    MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1 \
    "$BIN" \
      --dataset "$fixture_root/01-sphere-500" \
      --output "$metal_validation_dir/splat.ply" \
      --profile fast \
      --iteration-limit 600 \
      --checkpoint "$metal_validation_dir/checkpoint" \
      --seed 42 \
      --memory-budget-bytes 8589934592 \
      --events-fd 1 \
      >"$metal_validation_dir/events.jsonl" \
      2>"$metal_validation_dir/stderr.log"; then
  sed -n '1,200p' "$metal_validation_dir/stderr.log" >&2
  fail "instrumented Metal training failed"
fi
if grep -Eqi 'shader validation|invalid (device|threadgroup|texture)|validation (error|fault)|gpu fault' \
  "$metal_validation_dir/stderr.log"; then
  sed -n '1,200p' "$metal_validation_dir/stderr.log" >&2
  fail "instrumented Metal training emitted validation diagnostics"
fi
validate_jsonl "$metal_validation_dir/events.jsonl"
python3 - "$metal_validation_dir/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
started, completed = records[0], records[-1]
if started.get("event") != "started" or completed.get("event") != "completed":
    raise SystemExit("instrumented Metal run has invalid event boundaries")
if started.get("iteration_limit") != 600 or completed.get("iteration_limit") != 600:
    raise SystemExit("instrumented Metal run lost its bounded iteration limit")
if started.get("initial_gaussian_count") != 500:
    raise SystemExit("instrumented Metal run used the wrong stress fixture")
if completed.get("dropped_intersection_count") != 0:
    raise SystemExit("instrumented Metal run dropped raster intersections")
PY
[ -s "$metal_validation_dir/splat.ply" ] \
  || fail "instrumented Metal training did not publish a PLY"
"$BIN" --validate-ply "$metal_validation_dir/splat.ply" --events-fd 1 \
  >"$metal_validation_dir/validation.jsonl" \
  2>"$metal_validation_dir/validation.stderr"
require_contains '"status":"ok"' "$metal_validation_dir/validation.jsonl"

overflow_dir="$negative_dir/raster-overflow"
mkdir -p "$overflow_dir"
"$BIN" \
  --dataset "$fixture_root/13-overflow-2304" \
  --output "$overflow_dir/splat.ply" \
  --profile fast \
  --checkpoint "$overflow_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes 100663296 \
  --events-fd 1 \
  >"$overflow_dir/events.jsonl" 2>"$overflow_dir/stderr.log"
validate_jsonl "$overflow_dir/events.jsonl"
python3 - "$overflow_dir" <<'PY'
import json
import math
import sys
from pathlib import Path

root = Path(sys.argv[1])
records = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
started = records[0]
completed = records[-1]
if started.get("event") != "started" or completed.get("event") != "completed":
    raise SystemExit("overflow run has invalid event boundaries")
if started.get("checkpoint_schema") != 3 or started.get("payload_schema") != 2:
    raise SystemExit("overflow run did not advertise checkpoint schema 3")
if started.get("memory_budget_bytes") != 100663296:
    raise SystemExit("overflow run lost its explicit memory budget")
fallbacks = [record for record in records if record.get("event") == "raster_fallback"]
if not fallbacks:
    raise SystemExit("overflow fixture did not exercise exact raster fallback")
counts = [record.get("fallback_count") for record in fallbacks]
if any(isinstance(value, bool) or not isinstance(value, int) for value in counts):
    raise SystemExit("overflow fallback count is not integral")
if counts != sorted(counts) or counts[-1] <= 0:
    raise SystemExit("overflow fallback count is not positive and monotonic")
if any(record.get("intersection_count", 0) <= 2048 for record in fallbacks):
    raise SystemExit("overflow evidence did not exceed the tile-local limit")
if completed.get("raster_fallback_count", 0) < counts[-1]:
    raise SystemExit("completion lost raster fallback evidence")
recovery_integer_fields = (
    "raster_exact_buffer_bytes_added",
    "raster_exact_buffer_growth_count",
    "raster_peak_exact_intersection_capacity",
)
recovery_elapsed_fields = (
    "raster_exact_fallback_elapsed_seconds",
    "raster_replay_elapsed_seconds",
)
for record in fallbacks + [completed]:
    for key in recovery_integer_fields:
        value = record.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise SystemExit(f"overflow evidence has invalid {key}")
    for key in recovery_elapsed_fields:
        value = record.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise SystemExit(f"overflow evidence has invalid {key}")
if completed["raster_exact_buffer_growth_count"] <= 0:
    raise SystemExit("overflow completion lost exact buffer growth evidence")
if completed["raster_exact_buffer_growth_count"] > completed["raster_fallback_count"]:
    raise SystemExit("overflow completion reports more allocations than exact dispatches")
if completed["raster_exact_buffer_bytes_added"] <= 0:
    raise SystemExit("overflow completion lost exact allocation byte evidence")
if completed["raster_peak_exact_intersection_capacity"] <= 2048:
    raise SystemExit("overflow completion lost peak exact capacity evidence")
if completed["raster_exact_fallback_elapsed_seconds"] <= 0:
    raise SystemExit("overflow completion lost exact fallback timing evidence")
if completed["raster_replay_elapsed_seconds"] <= 0:
    raise SystemExit("overflow completion lost raster replay timing evidence")
for key in recovery_elapsed_fields:
    if completed[key] > completed.get("elapsed_seconds", -1):
        raise SystemExit(f"overflow completion {key} exceeds cumulative elapsed time")
if completed.get("dropped_intersection_count") != 0:
    raise SystemExit("overflow run dropped raster intersections")
if completed.get("memory_budget_bytes") != 100663296:
    raise SystemExit("completion lost the explicit memory budget")
scene_center = completed.get("scene_center")
scene_radius = completed.get("scene_radius")
if (
    not isinstance(scene_center, list)
    or len(scene_center) != 3
    or any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
           for value in scene_center)
    or isinstance(scene_radius, bool)
    or not isinstance(scene_radius, (int, float))
    or not math.isfinite(scene_radius)
    or scene_radius <= 0
):
    raise SystemExit("overflow completion lost robust scene bounds")
current = (root / "checkpoint" / "CURRENT").read_text().strip()
manifest = json.loads(
    (root / "checkpoint" / "generations" / current / "manifest.json").read_text()
)
expected_manifest = {
    "schema_version": 3,
    "payload_schema": 2,
    "memory_budget_bytes": 100663296,
    "dropped_intersection_count": 0,
}
for key, expected in expected_manifest.items():
    if manifest.get(key) != expected:
        raise SystemExit(f"overflow checkpoint mismatch for {key}")
if manifest.get("raster_fallback_count", 0) <= 0:
    raise SystemExit("overflow checkpoint lost fallback count")
# Durable recovery evidence must survive from the last checkpoint through completion.
# Equality holds only when no further exact-raster work happens after that checkpoint,
# which is incidental to where training stops, so assert the actual contract: these
# fields are monotonic and never regress. Capacity and byte totals are high-water marks
# and must not shrink; elapsed timers only accumulate.
for key in recovery_integer_fields + recovery_elapsed_fields:
    checkpointed = manifest.get(key)
    final = completed.get(key)
    if checkpointed is None or final is None:
        raise SystemExit(f"overflow checkpoint lost durable {key}")
    if final < checkpointed:
        raise SystemExit(
            f"overflow completion regressed durable {key}: "
            f"checkpoint={checkpointed} completed={final}"
        )
PY
[ -s "$overflow_dir/splat.ply" ] || fail "exact fallback did not publish a PLY"
"$BIN" --validate-ply "$overflow_dir/splat.ply" --events-fd 1 \
  >"$overflow_dir/validation.jsonl" 2>"$overflow_dir/validation.stderr"
require_contains '"status":"ok"' "$overflow_dir/validation.jsonl"

low_budget_dir="$negative_dir/raster-low-budget"
mkdir -p "$low_budget_dir"
printf 'SENTINEL' >"$low_budget_dir/existing.ply"
printf 'SENTINEL' >"$low_budget_dir/expected.ply"
set +e
"$BIN" \
  --dataset "$fixture_root/13-overflow-2304" \
  --output "$low_budget_dir/existing.ply" \
  --profile fast \
  --checkpoint "$low_budget_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes 1048576 \
  --events-fd 1 \
  >"$low_budget_dir/events.jsonl" 2>"$low_budget_dir/stderr.log"
low_budget_status=$?
set -e
[ "$low_budget_status" = "75" ] || fail "raster budget failure exited $low_budget_status instead of 75"
cmp -s "$low_budget_dir/existing.ply" "$low_budget_dir/expected.ply" \
  || fail "raster budget failure replaced an existing PLY"
[ ! -e "$low_budget_dir/checkpoint" ] || fail "raster preflight failure wrote a checkpoint"
if find "$low_budget_dir" -name '*.tmp.*' -print -quit | grep -q .; then
  fail "raster preflight failure left a temporary artifact"
fi
validate_jsonl "$low_budget_dir/events.jsonl"
python3 - "$low_budget_dir/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
if len(records) != 1 or records[0].get("event") != "raster_memory_budget_exceeded":
    raise SystemExit("setup-time budget failure did not emit one terminal event")
record = records[0]
if record.get("iteration") != 0 or record.get("budget_bytes") != 1048576:
    raise SystemExit("raster preflight failure has the wrong iteration or budget")
required = record.get("required_bytes")
if isinstance(required, bool) or not isinstance(required, int) or required <= 1048576:
    raise SystemExit("raster preflight failure lacks authoritative required bytes")
PY
require_contains 'raster_memory_budget_exceeded' "$low_budget_dir/stderr.log"
require_contains 'required_bytes=' "$low_budget_dir/stderr.log"
require_contains 'budget_bytes=1048576' "$low_budget_dir/stderr.log"

marginal_budget_dir="$negative_dir/raster-marginal-budget"
mkdir -p "$marginal_budget_dir"
printf 'SENTINEL' >"$marginal_budget_dir/existing.ply"
marginal_budget_bytes="$(python3 - "$low_budget_dir/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

record = json.loads(Path(sys.argv[1]).read_text().splitlines()[-1])
print(record["required_bytes"] - 1)
PY
)"
set +e
"$BIN" \
  --dataset "$fixture_root/13-overflow-2304" \
  --output "$marginal_budget_dir/existing.ply" \
  --profile fast \
  --checkpoint "$marginal_budget_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes "$marginal_budget_bytes" \
  --events-fd 1 \
  >"$marginal_budget_dir/events.jsonl" 2>"$marginal_budget_dir/stderr.log"
marginal_budget_status=$?
set -e
[ "$marginal_budget_status" = "75" ] \
  || fail "marginal raster budget exited $marginal_budget_status instead of 75"
[ ! -e "$marginal_budget_dir/checkpoint" ] \
  || fail "marginal raster preflight wrote a checkpoint"
require_contains 'SENTINEL' "$marginal_budget_dir/existing.ply"
python3 - "$marginal_budget_dir/events.jsonl" "$marginal_budget_bytes" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
budget = int(sys.argv[2])
if len(records) != 1 or records[0].get("event") != "raster_memory_budget_exceeded":
    raise SystemExit("marginal setup budget did not emit one terminal event")
record = records[0]
if record.get("iteration") != 0 or record.get("budget_bytes") != budget:
    raise SystemExit("marginal raster budget event lost its run contract")
if record.get("required_bytes") != budget + 1:
    raise SystemExit("marginal raster budget did not report its exact shortfall")
PY

misleading_error_dir="$negative_dir/raster_memory_budget_exceeded-unrelated"
cp -R "$fixture_root/01-sphere-500" "$misleading_error_dir"
find "$misleading_error_dir/images" -type f -exec sh -c 'printf invalid > "$1"' _ {} \;
set +e
"$BIN" \
  --dataset "$misleading_error_dir" \
  --output "$negative_dir/misleading-error.ply" \
  --profile fast \
  --checkpoint "$negative_dir/misleading-error-checkpoint" \
  --seed 42 \
  --memory-budget-bytes 536870912 \
  --events-fd 1 \
  >"$negative_dir/misleading-error.jsonl" 2>"$negative_dir/misleading-error.stderr"
misleading_error_status=$?
set -e
[ "$misleading_error_status" = "1" ] \
  || fail "unrelated raster-named error exited $misleading_error_status instead of 1"
require_contains 'raster_memory_budget_exceeded-unrelated' "$negative_dir/misleading-error.stderr"
if grep -Fq '"event":"raster_memory_budget_exceeded"' "$negative_dir/misleading-error.jsonl"; then
  fail "unrelated exception text was mislabeled as a raster budget failure"
fi
[ ! -e "$negative_dir/misleading-error.ply" ] \
  || fail "unrelated raster-named failure published output"

run_cancelled_profile() {
  local profile="$1"
  local expected_limit="$2"
  local expected_plateau="$3"
  local cancellation_dir="$negative_dir/cancellation-$profile"
  local cancellation_pid started cancellation_status
  mkdir -p "$cancellation_dir"
  "$BIN" \
    --dataset "$fixture_root/12-clusters-1500" \
    --output "$cancellation_dir/splat.ply" \
    --profile "$profile" \
    --checkpoint "$cancellation_dir/checkpoint" \
    --seed 42 \
    --memory-budget-bytes 536870912 \
    --events-fd 1 \
    >"$cancellation_dir/events.jsonl" 2>"$cancellation_dir/stderr.log" &
  cancellation_pid=$!
  started=0
  for _ in $(seq 1 600); do
    if grep -Fq '"event":"started"' "$cancellation_dir/events.jsonl" 2>/dev/null; then
      started=1
      break
    fi
    sleep 0.05
  done
  [ "$started" = "1" ] || {
    kill -KILL "$cancellation_pid" 2>/dev/null || true
    wait "$cancellation_pid" 2>/dev/null || true
    fail "$profile training did not emit started before the cancellation timeout"
  }
  python3 - "$cancellation_dir/events.jsonl" "$profile" "$expected_limit" "$expected_plateau" <<'PY'
import json
import sys
from pathlib import Path

started = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[0])
expected = {
    "event": "started",
    "iteration_limit": int(sys.argv[3]),
    "plateau_window": int(sys.argv[4]),
    "profile": sys.argv[2],
    "seed": 42,
}
for key, value in expected.items():
    if started.get(key) != value:
        raise SystemExit(f"{sys.argv[2]} started-event mismatch for {key}")
PY
  kill -TERM "$cancellation_pid"
  set +e
  wait "$cancellation_pid"
  cancellation_status=$?
  set -e
  [ "$cancellation_status" = "130" ] || fail "signaled $profile training exited $cancellation_status instead of 130"
  validate_jsonl "$cancellation_dir/events.jsonl"
  require_contains '"event":"cancellation_requested"' "$cancellation_dir/events.jsonl"
  require_contains '"event":"cancelled"' "$cancellation_dir/events.jsonl"
  if grep -Fq '"event":"completed"' "$cancellation_dir/events.jsonl"; then
    fail "cancelled $profile training emitted completed"
  fi
  [ ! -e "$cancellation_dir/splat.ply" ] || fail "cancelled $profile training published a final PLY"
  python3 - "$cancellation_dir" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
records = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
checkpoints = [record for record in records if record.get("event") == "checkpoint_completed"]
cancelled = records[-1]
if not checkpoints or cancelled.get("event") != "cancelled":
    raise SystemExit("cancellation stream is missing durable checkpoint evidence")
current = (root / "checkpoint" / "CURRENT").read_text().strip()
latest = checkpoints[-1]
if current != cancelled.get("checkpoint_generation") or current != latest.get("checkpoint_generation"):
    raise SystemExit("cancelled event does not reference CURRENT")
generation = root / "checkpoint" / "generations" / current
manifest = json.loads((generation / "manifest.json").read_text())
payload = generation / "state.msplat"
digest = hashlib.sha256(payload.read_bytes()).hexdigest()
if digest != manifest.get("payload_sha256") or digest != latest.get("checkpoint_payload_sha256"):
    raise SystemExit("cancelled checkpoint payload digest mismatch")
if manifest.get("iteration") != cancelled.get("checkpoint_iteration"):
    raise SystemExit("cancelled checkpoint iteration mismatch")
for key in (
    "raster_fallback_count",
    "raster_exact_fallback_elapsed_seconds",
    "raster_exact_buffer_growth_count",
    "raster_exact_buffer_bytes_added",
    "raster_replay_elapsed_seconds",
    "raster_peak_exact_intersection_capacity",
):
    if cancelled.get(key) != manifest.get(key) or cancelled.get(key) != latest.get(key):
        raise SystemExit(f"cancelled event did not report its durable {key}")
if cancelled.get("dropped_intersection_count") != 0:
    raise SystemExit("cancelled event reported dropped intersections")
PY
}

run_cancelled_profile balanced 7000 800
run_cancelled_profile high-detail 15000 1500

resume_dir="$negative_dir/resume-fast"
mkdir -p "$resume_dir"
"$BIN" \
  --dataset "$fixture_root/12-clusters-1500" \
  --output "$resume_dir/splat.ply" \
  --profile fast \
  --checkpoint "$resume_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes 536870912 \
  --events-fd 1 \
  >"$resume_dir/first.jsonl" 2>"$resume_dir/first.stderr" &
resume_pid=$!
checkpoint_ready=0
for _ in $(seq 1 2000); do
  if grep -Eq '"event":"checkpoint_completed".*"iteration":500' "$resume_dir/first.jsonl" 2>/dev/null; then
    checkpoint_ready=1
    break
  fi
  sleep 0.01
done
[ "$checkpoint_ready" = "1" ] || {
  kill -KILL "$resume_pid" 2>/dev/null || true
  wait "$resume_pid" 2>/dev/null || true
  fail "Fast training did not publish iteration-500 checkpoint"
}
kill -TERM "$resume_pid"
set +e
wait "$resume_pid"
resume_cancel_status=$?
set -e
[ "$resume_cancel_status" = "130" ] || fail "Fast checkpoint cancellation exited $resume_cancel_status"
cp -R "$resume_dir/checkpoint" "$resume_dir/tampered-checkpoint"

make_incompatible_checkpoint() {
  local destination="$1"
  local field="$2"
  local value="$3"
  cp -R "$resume_dir/checkpoint" "$destination"
  python3 - "$destination" "$field" "$value" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
field = sys.argv[2]
value = sys.argv[3]
current = (root / "CURRENT").read_text(encoding="utf-8").strip()
generation = root / "generations" / current
manifest_path = generation / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if field in {"camera_count", "memory_budget_bytes", "raster_fallback_count"}:
    manifest[field] = int(value)
    if field == "camera_count":
        manifest["best_camera_losses"] = [None] * int(value)
else:
    manifest[field] = value
encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
new_name = f"{manifest['iteration']:08d}-{hashlib.sha256(encoded).hexdigest()}"
new_generation = generation.with_name(new_name)
generation.rename(new_generation)
(new_generation / "manifest.json").write_bytes(encoded)
(root / "CURRENT").write_text(new_name + "\n", encoding="utf-8")
PY
}

make_raster_resume_checkpoint() {
  local destination="$1"
  local peak_capacity="$2"
  local memory_budget="$3"
  cp -R "$resume_dir/checkpoint" "$destination"
  python3 - "$destination" "$peak_capacity" "$memory_budget" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
peak_capacity = int(sys.argv[2])
memory_budget = int(sys.argv[3])
current = (root / "CURRENT").read_text(encoding="utf-8").strip()
generation = root / "generations" / current
manifest_path = generation / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest.update({
    "memory_budget_bytes": memory_budget,
    "raster_exact_buffer_bytes_added": 65536,
    "raster_exact_buffer_growth_count": 1,
    "raster_exact_fallback_elapsed_seconds": 0.001,
    "raster_fallback_count": 1,
    "raster_peak_exact_intersection_capacity": peak_capacity,
    "raster_replay_elapsed_seconds": 0.001,
})
encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
new_name = f"{manifest['iteration']:08d}-{hashlib.sha256(encoded).hexdigest()}"
new_generation = generation.with_name(new_name)
generation.rename(new_generation)
(new_generation / "manifest.json").write_bytes(encoded)
(root / "CURRENT").write_text(new_name + "\n", encoding="utf-8")
PY
}

assert_resume_rejected() {
  local checkpoint="$1"
  local reason="$2"
  local output="$resume_dir/rejected-$reason.ply"
  local events="$resume_dir/rejected-$reason.jsonl"
  local stderr="$resume_dir/rejected-$reason.stderr"
  set +e
  "$BIN" \
    --dataset "$fixture_root/12-clusters-1500" \
    --output "$output" \
    --profile fast \
    --checkpoint "$checkpoint" \
    --resume "$checkpoint" \
    --seed 42 \
    --memory-budget-bytes 536870912 \
    --events-fd 1 \
    >"$events" 2>"$stderr"
  local status=$?
  set -e
  [ "$status" = "78" ] || fail "$reason resume rejection exited $status instead of 78"
  [ "$(wc -l <"$events" | tr -d ' ')" = "1" ] || fail "$reason rejection emitted extra events"
  validate_jsonl "$events"
  require_contains '"event":"resume_rejected"' "$events"
  require_contains "\"reason\":\"$reason\"" "$events"
  [ ! -e "$output" ] || fail "$reason resume rejection published output"
  grep -qi 'checkpoint' "$stderr" || fail "$reason rejection diagnostic is not useful"
}

make_incompatible_checkpoint \
  "$resume_dir/geometry-mismatch-checkpoint" \
  geometry_digest \
  "$(printf 'a%.0s' {1..64})"
assert_resume_rejected "$resume_dir/geometry-mismatch-checkpoint" geometry_changed

make_incompatible_checkpoint \
  "$resume_dir/input-mismatch-checkpoint" \
  camera_count \
  13
assert_resume_rejected "$resume_dir/input-mismatch-checkpoint" input_changed

make_incompatible_checkpoint \
  "$resume_dir/trainer-mismatch-checkpoint" \
  trainer_build_digest \
  "$(printf 'b%.0s' {1..64})"
assert_resume_rejected "$resume_dir/trainer-mismatch-checkpoint" trainer_changed

make_incompatible_checkpoint \
  "$resume_dir/budget-mismatch-checkpoint" \
  memory_budget_bytes \
  100663296
assert_resume_rejected "$resume_dir/budget-mismatch-checkpoint" run_contract_changed

assert_malformed_checkpoint() {
  local checkpoint="$1"
  local label="$2"
  local events="$resume_dir/malformed-$label.jsonl"
  local stderr="$resume_dir/malformed-$label.stderr"
  set +e
  "$BIN" \
    --dataset "$fixture_root/12-clusters-1500" \
    --output "$resume_dir/malformed-$label.ply" \
    --profile fast \
    --checkpoint "$checkpoint" \
    --resume "$checkpoint" \
    --seed 42 \
    --memory-budget-bytes 536870912 \
    --events-fd 1 \
    >"$events" 2>"$stderr"
  local command_status=$?
  set -e
  [ "$command_status" = "1" ] || fail "$label malformed checkpoint exited $command_status"
  [ ! -s "$events" ] || fail "$label malformed checkpoint emitted events"
  [ ! -e "$resume_dir/malformed-$label.ply" ] || fail "$label malformed checkpoint published output"
  grep -qi 'checkpoint manifest' "$stderr" \
    || fail "$label malformed checkpoint diagnostic is not useful"
}

make_incompatible_checkpoint \
  "$resume_dir/fallback-after-iteration-checkpoint" \
  raster_fallback_count \
  501
assert_malformed_checkpoint \
  "$resume_dir/fallback-after-iteration-checkpoint" fallback-after-iteration

make_incompatible_checkpoint \
  "$resume_dir/fallback-uint32-overflow-checkpoint" \
  raster_fallback_count \
  4294967296
assert_malformed_checkpoint \
  "$resume_dir/fallback-uint32-overflow-checkpoint" fallback-uint32-overflow

restore_budget=100663296
restore_capacity=2305
restore_checkpoint="$resume_dir/non-geometric-restore-checkpoint"
restore_events="$resume_dir/non-geometric-restore.jsonl"
make_raster_resume_checkpoint "$restore_checkpoint" "$restore_capacity" "$restore_budget"
"$BIN" \
  --dataset "$fixture_root/12-clusters-1500" \
  --output "$resume_dir/non-geometric-restore.ply" \
  --profile fast \
  --checkpoint "$restore_checkpoint" \
  --resume "$restore_checkpoint" \
  --seed 42 \
  --memory-budget-bytes "$restore_budget" \
  --events-fd 1 \
  >"$restore_events" 2>"$resume_dir/non-geometric-restore.stderr" &
restore_pid=$!
restore_loaded=0
for _ in $(seq 1 2000); do
  if grep -Fq '"event":"checkpoint_loaded"' "$restore_events" 2>/dev/null; then
    restore_loaded=1
    break
  fi
  sleep 0.01
done
[ "$restore_loaded" = "1" ] || {
  kill -KILL "$restore_pid" 2>/dev/null || true
  wait "$restore_pid" 2>/dev/null || true
  fail "non-geometric resume did not load its checkpoint"
}
kill -TERM "$restore_pid"
set +e
wait "$restore_pid"
restore_status=$?
set -e
[ "$restore_status" = "130" ] \
  || fail "non-geometric resume cancellation exited $restore_status instead of 130"
validate_jsonl "$restore_events"
[ ! -e "$resume_dir/non-geometric-restore.ply" ] \
  || fail "non-geometric resume cancellation published output"
python3 - "$restore_checkpoint" "$restore_events" "$restore_capacity" <<'PY'
import json
import sys
from pathlib import Path

checkpoint = Path(sys.argv[1])
records = [json.loads(line) for line in Path(sys.argv[2]).read_text().splitlines()]
expected_capacity = int(sys.argv[3])
current = (checkpoint / "CURRENT").read_text().strip()
manifest = json.loads(
    (checkpoint / "generations" / current / "manifest.json").read_text()
)
expected_events = [
    "started",
    "checkpoint_loaded",
    "cancellation_requested",
    "cancelled",
]
event_names = [record.get("event") for record in records]
event_positions = []
for event in expected_events:
    matches = [index for index, name in enumerate(event_names) if name == event]
    if len(matches) != 1:
        raise SystemExit(f"non-geometric resume emitted {event!r} {len(matches)} times")
    event_positions.append(matches[0])
if event_positions != sorted(event_positions):
    raise SystemExit("non-geometric resume emitted required events out of order")
if event_names[0] != "started" or event_names[-1] != "cancelled":
    raise SystemExit("non-geometric resume did not start and cancel cleanly")
if "completed" in event_names:
    raise SystemExit("non-geometric resume completed after cancellation was requested")
started, loaded, _, cancelled = (records[index] for index in event_positions)
if manifest.get("raster_peak_exact_intersection_capacity") != expected_capacity:
    raise SystemExit("non-geometric checkpoint fixture lost its persisted capacity")
metric_keys = (
    "raster_fallback_count",
    "raster_exact_fallback_elapsed_seconds",
    "raster_exact_buffer_growth_count",
    "raster_exact_buffer_bytes_added",
    "raster_replay_elapsed_seconds",
    "raster_peak_exact_intersection_capacity",
)
for record in (started, loaded, cancelled):
    for key in metric_keys:
        if record.get(key) != manifest.get(key):
            raise SystemExit(f"non-geometric resume changed durable {key}")
if loaded.get("iteration") != manifest.get("iteration"):
    raise SystemExit("checkpoint_loaded changed the persisted iteration")
if cancelled.get("checkpoint_iteration") != manifest.get("iteration"):
    raise SystemExit("cancelled event did not retain the durable iteration")
PY

failure_capacity=30000001
failure_budget=1073741824
failure_checkpoint="$resume_dir/restore-budget-failure-checkpoint"
failure_events="$resume_dir/restore-budget-failure.jsonl"
make_raster_resume_checkpoint "$failure_checkpoint" "$failure_capacity" "$failure_budget"
failure_generation="$(tr -d '\n' <"$failure_checkpoint/CURRENT")"
set +e
"$BIN" \
  --dataset "$fixture_root/12-clusters-1500" \
  --output "$resume_dir/restore-budget-failure.ply" \
  --profile fast \
  --checkpoint "$failure_checkpoint" \
  --resume "$failure_checkpoint" \
  --seed 42 \
  --memory-budget-bytes "$failure_budget" \
  --events-fd 1 \
  >"$failure_events" 2>"$resume_dir/restore-budget-failure.stderr"
failure_status=$?
set -e
[ "$failure_status" = "75" ] \
  || fail "resume restore budget failure exited $failure_status instead of 75"
validate_jsonl "$failure_events"
[ ! -e "$resume_dir/restore-budget-failure.ply" ] \
  || fail "resume restore budget failure published output"
[ "$(tr -d '\n' <"$failure_checkpoint/CURRENT")" = "$failure_generation" ] \
  || fail "resume restore budget failure changed the durable checkpoint"
if find "$failure_checkpoint" -name '*.tmp.*' -print -quit | grep -q .; then
  fail "resume restore budget failure left a temporary checkpoint artifact"
fi
python3 - "$failure_events" "$failure_budget" "$failure_capacity" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
expected_budget = int(sys.argv[2])
expected_capacity = int(sys.argv[3])
if len(records) != 1 or records[0].get("event") != "raster_memory_budget_exceeded":
    raise SystemExit("resume restore failure did not emit one typed setup event")
record = records[0]
if record.get("iteration") != 0:
    raise SystemExit("resume restore failure exposed its checkpoint iteration before started")
if record.get("budget_bytes") != expected_budget:
    raise SystemExit("resume restore failure lost the checkpoint budget")
if record.get("required_bytes", 0) <= expected_budget:
    raise SystemExit("resume restore failure lacks authoritative allocation evidence")
if record.get("intersection_count") != expected_capacity:
    raise SystemExit(
        "resume restore failure did not come from the persisted capacity: "
        f"expected {expected_capacity}, got {record.get('intersection_count')!r}"
    )
PY

"$BIN" \
  --dataset "$fixture_root/12-clusters-1500" \
  --output "$resume_dir/splat.ply" \
  --profile fast \
  --checkpoint "$resume_dir/checkpoint" \
  --resume "$resume_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes 536870912 \
  --events-fd 1 \
  >"$resume_dir/resumed.jsonl" 2>"$resume_dir/resumed.stderr"
validate_jsonl "$resume_dir/resumed.jsonl"
require_contains '"event":"checkpoint_loaded"' "$resume_dir/resumed.jsonl"
require_contains '"resumed":true' "$resume_dir/resumed.jsonl"
require_contains '"event":"completed"' "$resume_dir/resumed.jsonl"
[ -s "$resume_dir/splat.ply" ] || fail "resumed Fast training did not publish PLY"
"$BIN" --validate-ply "$resume_dir/splat.ply" --events-fd 1 \
  >"$resume_dir/validation.jsonl" 2>"$resume_dir/validation.stderr"

python3 - "$resume_dir/tampered-checkpoint" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
generation = (root / "CURRENT").read_text().strip()
payload = root / "generations" / generation / "state.msplat"
with payload.open("ab") as stream:
    stream.write(b"tamper")
PY
set +e
"$BIN" \
  --dataset "$fixture_root/12-clusters-1500" \
  --output "$resume_dir/tampered.ply" \
  --profile fast \
  --checkpoint "$resume_dir/tampered-checkpoint" \
  --resume "$resume_dir/tampered-checkpoint" \
  --seed 42 \
  --memory-budget-bytes 536870912 \
  --events-fd 1 \
  >"$resume_dir/tampered.jsonl" 2>"$resume_dir/tampered.stderr"
tampered_status=$?
set -e
[ "$tampered_status" -ne 0 ] || fail "tampered optimizer checkpoint was accepted"
[ ! -e "$resume_dir/tampered.ply" ] || fail "tampered resume published output"
grep -Eqi 'hash|size|payload' "$resume_dir/tampered.stderr" \
  || fail "tampered checkpoint diagnostic is not useful"

# Real preview-enabled training. Source-level greps prove the code is present;
# only running it proves the publisher accepts its CLI, emits loadable degree 0
# PLYs, and reports evidence that matches the bytes on disk.
preview_dir="$negative_dir/preview"
mkdir -p "$preview_dir"
"$BIN" \
  --dataset "$fixture_root/12-clusters-1500" \
  --output "$preview_dir/splat.ply" \
  --preview-output "$preview_dir/preview.ply" \
  --preview-interval-seconds 1 \
  --profile fast \
  --iteration-limit 20000 \
  --plateau-window 20000 \
  --checkpoint "$preview_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes 4000000000 \
  --events-fd 1 \
  >"$preview_dir/events.jsonl" 2>"$preview_dir/stderr.txt" \
  || fail "preview-enabled training run failed"

[ -f "$preview_dir/preview.ply" ] || fail "preview-enabled training published no preview"
grep -q '"event":"preview_published"' "$preview_dir/events.jsonl" \
  || fail "preview-enabled training emitted no preview_published event"
# No temporary may survive a clean run.
if find "$preview_dir" -maxdepth 1 -name '.preview.ply.preview.tmp.*' -print -quit | grep -q .; then
  fail "preview publication left a temporary behind"
fi

python3 - "$preview_dir" <<'PY'
import hashlib, json, pathlib, struct, sys

root = pathlib.Path(sys.argv[1])
events = [
    json.loads(line)
    for line in (root / "events.jsonl").read_text().splitlines()
    if line.strip()
]
published = [event for event in events if event.get("event") == "preview_published"]
if not published:
    raise SystemExit("no preview_published events")

expected_properties = [
    "x", "y", "z",
    "nx", "ny", "nz",
    "f_dc_0", "f_dc_1", "f_dc_2",
    "opacity",
    "scale_0", "scale_1", "scale_2",
    "rot_0", "rot_1", "rot_2", "rot_3",
]

publications = [event["preview_publication"] for event in published]
if publications != sorted(set(publications)):
    raise SystemExit("preview publications are not strictly increasing")

for event in published:
    if event.get("preview_schema") != 1:
        raise SystemExit("unexpected preview schema")
    count = event["preview_gaussian_count"]
    source = event["source_gaussian_count"]
    if not 0 < count <= source:
        raise SystemExit("preview count is not a subset of the model")
    if count > 400000:
        raise SystemExit("preview exceeded its 400k cap")
    radius = event["scene_radius"]
    center = event["scene_center"]
    if not (radius > 0) or len(center) != 3:
        raise SystemExit("preview carries unusable scene bounds")

# The final publication must still describe the file left on disk.
final = published[-1]
payload = (root / "preview.ply").read_bytes()
if len(payload) != final["preview_bytes"]:
    raise SystemExit("preview byte count does not match its receipt")
if hashlib.sha256(payload).hexdigest() != final["preview_sha256"]:
    raise SystemExit("preview digest does not match its receipt")

header, _, body = payload.partition(b"end_header\n")
lines = header.decode("ascii").splitlines()
properties = [
    line.split(" ", 2)[2] for line in lines if line.startswith("property float ")
]
if properties != expected_properties:
    raise SystemExit(f"preview layout is not degree 0 in contract order: {properties}")
if any(line.startswith("property float f_rest_") for line in lines):
    raise SystemExit("preview emitted higher-order coefficients")

vertex_lines = [line for line in lines if line.startswith("element vertex ")]
vertices = int(vertex_lines[0].split()[-1])
if vertices != final["preview_gaussian_count"]:
    raise SystemExit("preview header count disagrees with its receipt")
if len(body) != vertices * len(expected_properties) * 4:
    raise SystemExit("preview payload length does not match its header")

# Every value must be finite; the publisher rejects non-finite rows on write.
for value in struct.iter_unpack("<f", body):
    if value[0] != value[0] or value[0] in (float("inf"), float("-inf")):
        raise SystemExit("preview contains a non-finite value")

print(f"preview contract verified across {len(published)} publications")
PY

# A preview that cannot be written must not take training down with it: point the
# publication at an unwritable directory and require the run to finish anyway.
readonly_dir="$negative_dir/preview-readonly"
mkdir -p "$readonly_dir/locked"
chmod 500 "$readonly_dir/locked"
"$BIN" \
  --dataset "$fixture_root/01-sphere-500" \
  --output "$readonly_dir/splat.ply" \
  --preview-output "$readonly_dir/locked/preview.ply" \
  --preview-interval-seconds 1 \
  --profile fast \
  --iteration-limit 6000 \
  --plateau-window 6000 \
  --checkpoint "$readonly_dir/checkpoint" \
  --seed 42 \
  --memory-budget-bytes 2000000000 \
  --events-fd 1 \
  >"$readonly_dir/events.jsonl" 2>"$readonly_dir/stderr.txt" \
  || fail "an unwritable preview destination took the training run down"
chmod 700 "$readonly_dir/locked"
[ -f "$readonly_dir/splat.ply" ] || fail "training did not publish its output despite a preview failure"
grep -q '"event":"preview_disabled"' "$readonly_dir/events.jsonl" \
  || fail "a failed preview publication did not report preview_disabled"

expect_preview_rejection() {
  local label="$1" expected="$2"
  shift 2
  set +e
  "$@" >"$negative_dir/$label.stdout" 2>"$negative_dir/$label.stderr"
  local status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$label was accepted"
  grep -Fq "$expected" "$negative_dir/$label.stderr" \
    || fail "$label did not explain itself: $(cat "$negative_dir/$label.stderr")"
}

expect_preview_rejection \
  preview-aliases-output \
  'cannot collide with --output' \
  "$BIN" --dataset "$fixture_root/01-sphere-500" \
  --output "$negative_dir/alias.ply" --preview-output "$negative_dir/alias.ply" \
  --profile fast --checkpoint "$negative_dir/alias-ckpt" --seed 42 \
  --memory-budget-bytes 536870912 --events-fd 1

expect_preview_rejection \
  preview-interval-without-path \
  'requires --preview-output' \
  "$BIN" --dataset "$fixture_root/01-sphere-500" \
  --output "$negative_dir/interval.ply" --preview-interval-seconds 5 \
  --profile fast --checkpoint "$negative_dir/interval-ckpt" --seed 42 \
  --memory-budget-bytes 536870912 --events-fd 1

echo "native msplat build and CLI contracts passed"
