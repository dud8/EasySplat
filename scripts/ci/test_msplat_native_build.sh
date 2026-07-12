#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/toolchain/build_msplat.sh"
OVERLAY="$ROOT/Tools/MsplatNative/msplat.cpp"
UPSTREAM_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-easysplat.patch"
FIXTURE_GENERATOR="$ROOT/scripts/ci/generate_msplat_sparse_fixtures.py"
INSTALL_DIR="${EASYSPLAT_MSPLAT_INSTALL_DIR:-$ROOT/Toolchains/build/msplat/install/msplat}"

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
require_file "$UPSTREAM_PATCH"
require_file "$FIXTURE_GENERATOR"

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
require_contains '/usr/bin/plutil -p' "$BUILD_SCRIPT"
require_contains '/usr/bin/otool -L' "$BUILD_SCRIPT"

for forbidden in 'pip install' 'python-build-standalone' 'site-packages' '_core.so' 'core_extension_path.txt' '/msplat-train'; do
  require_absent "$forbidden" "$BUILD_SCRIPT"
done

for flag in --dataset --output --profile --seed --events-fd --self-check --validate-ply --version --help; do
  require_contains "$flag" "$OVERLAY"
done
for flag in --input --num-iters --num-downscales --downscale-factor --eval --events-jsonl; do
  require_absent "$flag" "$OVERLAY"
done
for budget in 'fast", 3000, 400' 'balanced", 7000, 800' 'high-detail", 15000, 1500'; do
  require_contains "$budget" "$OVERLAY"
done
for event in started progress early_stop completed cancellation_requested cancelled self_check; do
  require_contains "\"$event\"" "$OVERLAY"
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
require_contains 'write(' "$OVERLAY"
require_contains 'msplat_gpu_sync()' "$OVERLAY"
require_contains 'SIGINT' "$OVERLAY"
require_contains 'SIGTERM' "$OVERLAY"
require_contains 'return 130' "$OVERLAY"
require_contains 'rename(' "$OVERLAY"
require_contains 'fsync(' "$OVERLAY"
if [ "$(grep -Fc 'cancelIfRequested(' "$OVERLAY")" -lt 3 ]; then
  fail "$OVERLAY must observe cancellation both before and after each iteration"
fi

require_contains 'get_global_context' "$UPSTREAM_PATCH"
require_contains 'runtime_error' "$UPSTREAM_PATCH"
require_contains 'pipelineLoadFailed' "$UPSTREAM_PATCH"
require_contains 'std::ios::failbit' "$UPSTREAM_PATCH"
require_contains 'float3 b_conic = float3(0.0f)' "$UPSTREAM_PATCH"
require_contains 'int32_t b_id = 0' "$UPSTREAM_PATCH"
require_contains 'void msplat_record_last_loss' "$UPSTREAM_PATCH"
require_contains 'void msplat_sync_loss_window' "$UPSTREAM_PATCH"
require_contains 'syncCB()' "$UPSTREAM_PATCH"
require_contains 'validateBinaryPly' "$OVERLAY"
require_contains 'cancelIfRequested(events, step)' "$OVERLAY"

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
/usr/bin/otool -L "$BIN" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *) fail "CLI has a non-system dynamic dependency: $dependency" ;;
  esac
done
"$BIN" --version | grep -Fq '1.1.3' || fail "CLI version does not report 1.1.3"
help="$($BIN --help)"
for flag in --dataset --output --profile --seed --events-fd --self-check --validate-ply --version --help; do
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
  --profile extravagant --seed 42 --events-fd 1 \
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

for key in source_commit source_version source_url source_tree_sha256 overlay_sha256 patch_sha256 executable_sha256 metallib_sha256 compiler deployment_target cmake_arguments build_timestamp; do
  require_contains "\"$key\"" "$BUILD_INFO"
done
/usr/bin/plutil -p "$BUILD_INFO" >/dev/null || fail "build provenance is not valid JSON"
[ "$(/usr/bin/plutil -extract source_commit raw "$BUILD_INFO")" = "106499b0a53f82b0c92d013b0861fbebd341b17e" ] || fail "parsed source commit is wrong"
require_contains '"source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e"' "$BUILD_INFO"
require_contains '"source_version": "1.1.3"' "$BUILD_INFO"

exe_hash="$(shasum -a 256 "$BIN" | awk '{print $1}')"
metallib_hash="$(shasum -a 256 "$METALLIB" | awk '{print $1}')"
require_contains "\"executable_sha256\": \"$exe_hash\"" "$BUILD_INFO"
require_contains "\"metallib_sha256\": \"$metallib_hash\"" "$BUILD_INFO"

if grep -Eq '(/Users/|/home/|"hostname"|"username"|"source_path")' "$BUILD_INFO"; then
  fail "build provenance contains a private or machine-local field"
fi

validate_jsonl() {
  local jsonl="$1"
  local line_file="$negative_dir/line.json"
  local expected_sequence=1
  while IFS= read -r line; do
    printf '%s\n' "$line" >"$line_file"
    /usr/bin/plutil -p "$line_file" >/dev/null || fail "stdout contains a non-JSONL line: $line"
    grep -Fq "\"sequence\":$expected_sequence" "$line_file" || fail "JSONL sequence is not monotonic at $expected_sequence"
    expected_sequence=$((expected_sequence + 1))
  done <"$jsonl"
}

validate_training_events() {
  local jsonl="$1"
  local expected_points="$2"
  python3 - "$jsonl" "$expected_points" <<'PY'
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
if started.get("event") != "started" or completed.get("event") != "completed":
    raise SystemExit("training event stream has invalid boundaries")
if started.get("initial_gaussian_count") != expected_points:
    raise SystemExit("started event has the wrong sparse-point count")
expected_contract = {
    "iteration_limit": 3000,
    "plateau_window": 400,
    "profile": "fast",
    "seed": 42,
}
for key, expected in expected_contract.items():
    if started.get(key) != expected or completed.get(key) != expected:
        raise SystemExit(f"training profile contract mismatch for {key}")
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
fixture_count=0
while IFS=$'\t' read -r fixture_name expected_points; do
  fixture_count=$((fixture_count + 1))
  training_fixture="$fixture_root/$fixture_name"
  training_dir="$negative_dir/training-$fixture_name"
  mkdir -p "$training_dir"
  "$BIN" \
    --dataset "$training_fixture" \
    --output "$training_dir/splat.ply" \
    --profile fast \
    --seed 42 \
    --events-fd 1 \
    >"$training_dir/events.jsonl" 2>"$training_dir/stderr.log"
  validate_jsonl "$training_dir/events.jsonl"
  validate_training_events "$training_dir/events.jsonl" "$expected_points"
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
    print(f'{fixture["dataset"]}\t{fixture["point_count"]}')
PY
)
[ "$fixture_count" = "12" ] || fail "sparse fixture generator did not produce twelve cases"

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
    --seed 42 \
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
}

run_cancelled_profile balanced 7000 800
run_cancelled_profile high-detail 15000 1500

echo "native msplat build and CLI contracts passed"
