#!/usr/bin/env bash
# Source-contract assertions intentionally match literal shell expressions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/toolchain/build_msplat.sh"
OVERLAY="$ROOT/Tools/MsplatNative/msplat.cpp"
RASTER_TEST_SOURCE="$ROOT/Tools/MsplatNative/msplat_raster_tests.cpp"
UPSTREAM_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-easysplat.patch"
CHECKPOINT_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-checkpoint.patch"
NUMERIC_STABILITY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-numeric-stability.patch"
METAL_SAFETY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-metal-safety.patch"
EXACT_RASTER_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-raster.patch"
FIXTURE_GENERATOR="$ROOT/scripts/ci/generate_msplat_sparse_fixtures.py"
VALIDATOR="$ROOT/scripts/toolchain/validate_native_msplat.sh"
INSTALL_DIR="${EASYSPLAT_MSPLAT_INSTALL_DIR:-$ROOT/Toolchains/build/msplat/install/msplat}"
RASTER_TEST_BIN="${EASYSPLAT_MSPLAT_RASTER_TEST_BIN:-$ROOT/Toolchains/build/msplat/native-build/msplat_raster_tests}"

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

require_file "$BUILD_SCRIPT"
require_file "$OVERLAY"
require_file "$RASTER_TEST_SOURCE"
require_file "$UPSTREAM_PATCH"
require_file "$CHECKPOINT_PATCH"
require_file "$NUMERIC_STABILITY_PATCH"
require_file "$METAL_SAFETY_PATCH"
require_file "$EXACT_RASTER_PATCH"
require_file "$FIXTURE_GENERATOR"
require_file "$VALIDATOR"

require_contains 'MSPLAT_REPO="https://github.com/rayanht/msplat.git"' "$BUILD_SCRIPT"
require_contains 'MSPLAT_COMMIT="106499b0a53f82b0c92d013b0861fbebd341b17e"' "$BUILD_SCRIPT"
require_contains 'MSPLAT_VERSION="1.1.3"' "$BUILD_SCRIPT"
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
require_contains 'EXACT_RASTER_PATCH_SHA256="23c6a6a6c89dabe0827de9f13d2b026a0c416d912edc73468864b23bc376b27e"' "$BUILD_SCRIPT"
require_contains '[ "$(sha256 "$EXACT_RASTER_PATCH")" = "$EXACT_RASTER_PATCH_SHA256" ]' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply --check "$EXACT_RASTER_PATCH"' "$BUILD_SCRIPT"
require_contains 'git -C "$SOURCE_DIR" apply "$EXACT_RASTER_PATCH"' "$BUILD_SCRIPT"
require_contains 'exact_raster_patch_sha256' "$BUILD_SCRIPT"
require_contains 'exact_raster_patch_sha256' "$VALIDATOR"
require_contains 'MSPLAT_BUILD_RASTER_TESTS=ON' "$BUILD_SCRIPT"
require_contains 'msplat_raster_tests' "$BUILD_SCRIPT"
require_contains 'add_library(msplat_core_raster_tests STATIC' "$EXACT_RASTER_PATCH"
require_contains 'target_link_libraries(msplat_raster_tests PRIVATE msplat_core_raster_tests pthread)' "$EXACT_RASTER_PATCH"
require_contains 'reject_raster_test_symbols' "$BUILD_SCRIPT"
require_contains 'reject_raster_test_symbols' "$VALIDATOR"
require_contains 'raster_test_sha256' "$BUILD_SCRIPT"
require_contains 'raster_test_sha256' "$VALIDATOR"
require_contains 'python3 - "$build_info"' "$BUILD_SCRIPT"
require_contains 'json.dump(payload, output, indent=2, sort_keys=True)' "$BUILD_SCRIPT"
require_contains 'json.load(source, parse_constant=reject_constant)' "$BUILD_SCRIPT"
require_contains '/usr/bin/otool -L' "$BUILD_SCRIPT"
require_absent 'cat >"$STAGE_DIR/build_info.json" <<JSON' "$BUILD_SCRIPT"

for forbidden in 'pip install' 'python-build-standalone' 'site-packages' '_core.so' 'core_extension_path.txt' '/msplat-train'; do
  require_absent "$forbidden" "$BUILD_SCRIPT"
done

for flag in --dataset --output --profile --checkpoint --resume --seed --memory-budget-bytes --events-fd --self-check --validate-ply --version --help; do
  require_contains "$flag" "$OVERLAY"
done
for flag in --input --num-iters --num-downscales --downscale-factor --eval --events-jsonl; do
  require_absent "$flag" "$OVERLAY"
done
for budget in 'fast", 3000, 400' 'balanced", 7000, 800' 'high-detail", 15000, 1500'; do
  require_contains "$budget" "$OVERLAY"
done
for event in started checkpoint_completed checkpoint_loaded resume_rejected progress early_stop completed cancellation_requested cancelled self_check; do
  require_contains "\"$event\"" "$OVERLAY"
done
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
require_contains '"dropped_intersection_count"' "$OVERLAY"
require_contains 'msplat_preflight_raster_memory' "$OVERLAY"
require_contains 'msplat_raster_memory_budget_was_exceeded' "$OVERLAY"
require_contains 'msplat_raster_resource_limit_was_exceeded' "$OVERLAY"
require_contains 'msplat_gpu_sync_for_raster_replay' "$OVERLAY"
require_contains 'msplat_grow_exact_raster_capacity' "$OVERLAY"
require_contains '{"payload_schema", 2}' "$OVERLAY"
require_contains '{"schema_version", 2}' "$OVERLAY"

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
require_contains 'for (uint32_t pass = 0; pass < 8; ++pass)' "$EXACT_RASTER_PATCH"
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
require_contains 'deterministic_window_replay passed' "$RASTER_TEST_SOURCE"
require_contains 'increasing_window_replay passed' "$RASTER_TEST_SOURCE"
require_contains 'gpu_capacity_failure passed' "$RASTER_TEST_SOURCE"

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
  msplat_copy_last_raster_debug; do
  if nm -gU "$BIN" | grep -Fq "$symbol"; then
    fail "production CLI exports raster test hook: $symbol"
  fi
done
/usr/bin/otool -L "$BIN" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *) fail "CLI has a non-system dynamic dependency: $dependency" ;;
  esac
done
"$BIN" --version | grep -Fq '1.1.3' || fail "CLI version does not report 1.1.3"
help="$($BIN --help)"
for flag in --dataset --output --profile --checkpoint --resume --seed --memory-budget-bytes --events-fd --self-check --validate-ply --version --help; do
  grep -Fq -- "$flag" <<<"$help" || fail "CLI help is missing $flag"
done
for flag in --input --num-iters --num-downscales --downscale-factor --eval --events-jsonl; do
  if grep -Fq -- "$flag" <<<"$help"; then
    fail "CLI help still exposes obsolete control $flag"
  fi
done

self_check_stdout="$(mktemp "${TMPDIR:-/tmp}/easysplat-msplat-self-check.XXXXXX")"
self_check_stderr="$self_check_stdout.stderr"
trap 'rm -f "$self_check_stdout" "$self_check_stderr"; rm -rf "${negative_dir:-}"' EXIT
"$BIN" --self-check --events-fd 1 >"$self_check_stdout" 2>"$self_check_stderr"
[ "$(wc -l <"$self_check_stdout" | tr -d ' ')" = "1" ] || fail "self-check stdout is not exactly one JSONL record"
require_contains '"schema_version":1' "$self_check_stdout"
require_contains '"sequence":1' "$self_check_stdout"
require_contains '"event":"self_check"' "$self_check_stdout"
require_contains '"status":"ok"' "$self_check_stdout"

negative_dir="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-msplat-negative.XXXXXX")"
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
set -e
[ "$closed_fd_status" -ne 0 ] || fail "closed event file descriptor falsely succeeded"
grep -qi 'file descriptor' "$negative_dir/closed-fd.stderr" || fail "closed event-fd diagnostic is not useful"
[ "$invalid_profile_status" -ne 0 ] || fail "unknown training profile falsely succeeded"
grep -qi 'profile' "$negative_dir/invalid-profile.stderr" || fail "unknown profile diagnostic is not useful"

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

for key in source_commit source_version source_url source_tree_sha256 overlay_sha256 raster_test_sha256 patch_sha256 checkpoint_patch_sha256 numeric_stability_patch_sha256 metal_safety_patch_sha256 exact_raster_patch_sha256 executable_sha256 metallib_sha256 compiler deployment_target cmake_arguments build_timestamp; do
  require_contains "\"$key\"" "$BUILD_INFO"
done
overlay_hash="$(shasum -a 256 "$OVERLAY" | awk '{print $1}')"
numeric_stability_patch_hash="$(shasum -a 256 "$NUMERIC_STABILITY_PATCH" | awk '{print $1}')"
metal_safety_patch_hash="$(shasum -a 256 "$METAL_SAFETY_PATCH" | awk '{print $1}')"
exact_raster_patch_hash="$(shasum -a 256 "$EXACT_RASTER_PATCH" | awk '{print $1}')"
raster_test_hash="$(shasum -a 256 "$RASTER_TEST_SOURCE" | awk '{print $1}')"
exe_hash="$(shasum -a 256 "$BIN" | awk '{print $1}')"
metallib_hash="$(shasum -a 256 "$METALLIB" | awk '{print $1}')"
python3 - "$BUILD_INFO" "$overlay_hash" "$numeric_stability_patch_hash" "$metal_safety_patch_hash" "$exact_raster_patch_hash" "$raster_test_hash" "$exe_hash" "$metallib_hash" <<'PY'
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
    "numeric_stability_patch_sha256": sys.argv[3],
    "metal_safety_patch_sha256": sys.argv[4],
    "exact_raster_patch_sha256": sys.argv[5],
    "raster_test_sha256": sys.argv[6],
    "executable_sha256": sys.argv[7],
    "metallib_sha256": sys.argv[8],
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
    if record.get("schema_version") != 1 or record.get("sequence") != index:
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
    "checkpoint_schema": 2,
    "dropped_intersection_count": 0,
    "iteration_limit": 3000,
    "memory_budget_bytes": expected_memory_budget,
    "payload_schema": 2,
    "plateau_window": 400,
    "profile": "fast",
    "raster_fallback_count": 0,
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
for record in records:
    if record.get("event") != "checkpoint_completed":
        continue
    for key in ("memory_budget_bytes", "raster_fallback_count", "dropped_intersection_count"):
        if isinstance(record.get(key), bool) or not isinstance(record.get(key), int):
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
require_file "$RASTER_TEST_BIN"
[ -x "$RASTER_TEST_BIN" ] || fail "raster parity test is not executable: $RASTER_TEST_BIN"
"$RASTER_TEST_BIN" \
  "$fixture_root/01-sphere-500" \
  "$fixture_root/14-mixed-resolution-500" \
  "$fixture_root/13-overflow-2304" \
  "$fixture_root/16-broad-overflow-2304" \
  "$fixture_root/15-increasing-overflow-10000" \
  "$fixture_root/17-exact-budget-1279"
fixture_count=0
while IFS=$'\t' read -r fixture_name expected_points metal_pipeline_stress; do
  fixture_count=$((fixture_count + 1))
  training_fixture="$fixture_root/$fixture_name"
  training_dir="$negative_dir/training-$fixture_name"
  memory_budget_bytes=536870912
  validation_environment=(env)
  if [ "$metal_pipeline_stress" = "true" ]; then
    # Metal shader validation inflates device.currentAllocatedSize far beyond
    # the process RSS. Keep the real 512 MiB RSS gate below, but give the debug
    # layer enough room for its shadow allocations.
    memory_budget_bytes=8589934592
    validation_environment=(
      env
      MTL_DEBUG_LAYER=1
      MTL_SHADER_VALIDATION=1
      MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING=1
      MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1
      MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1
    )
  fi
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
import sys
from pathlib import Path

root = Path(sys.argv[1])
records = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
started = records[0]
completed = records[-1]
if started.get("event") != "started" or completed.get("event") != "completed":
    raise SystemExit("overflow run has invalid event boundaries")
if started.get("checkpoint_schema") != 2 or started.get("payload_schema") != 2:
    raise SystemExit("overflow run did not advertise checkpoint schema 2")
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
if completed.get("dropped_intersection_count") != 0:
    raise SystemExit("overflow run dropped raster intersections")
if completed.get("memory_budget_bytes") != 100663296:
    raise SystemExit("completion lost the explicit memory budget")
current = (root / "checkpoint" / "CURRENT").read_text().strip()
manifest = json.loads(
    (root / "checkpoint" / "generations" / current / "manifest.json").read_text()
)
expected_manifest = {
    "schema_version": 2,
    "payload_schema": 2,
    "memory_budget_bytes": 100663296,
    "dropped_intersection_count": 0,
}
for key, expected in expected_manifest.items():
    if manifest.get(key) != expected:
        raise SystemExit(f"overflow checkpoint mismatch for {key}")
if manifest.get("raster_fallback_count", 0) <= 0:
    raise SystemExit("overflow checkpoint lost fallback count")
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
if cancelled.get("raster_fallback_count") != manifest.get("raster_fallback_count"):
    raise SystemExit("cancelled event did not report its durable fallback count")
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

echo "native msplat build and CLI contracts passed"
