#!/usr/bin/env bash
set -euo pipefail

EXPECTED_VERSION="1.1.3 (git 106499b)"
EXPECTED_LICENSE_SHA256="c9fa07a171e978b59ad1558e29c15321cb6d803e6fb5020981a887bbd49f8d82"

fail() {
  echo "native msplat validation failed: $*" >&2
  exit 1
}

usage() {
  echo "Usage: validate_native_msplat.sh --source <msplat-root> | --packaged <toolchain-root> | --archive <core.zip>" >&2
  exit 2
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
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
    msplat_fail_next_sync_for_testing \
    msplat_pending_exact_raster_timing_handlers_for_testing \
    msplat_gpu_ticks_to_seconds_for_testing \
    msplat_gpu_frequency_from_timestamp_pairs_for_testing \
    msplat_stage_timing_sample_valid_for_testing \
    msplat_stage_timing_aggregate_coherent_for_testing \
    msplat_enable_stage_profiling_for_testing \
    msplat_gpu_timestamp_calibration_for_testing \
    msplat_copy_last_raster_debug; do
    if /usr/bin/nm -gU "$binary" | grep -Fq "$symbol"; then
      fail "native trainer exports raster test hook: $symbol"
    fi
  done
}

require_regular_file() {
  local path="$1"
  local description="$2"
  [ -f "$path" ] || fail "missing $description: $path"
  [ ! -L "$path" ] || fail "$description must not be a symlink: $path"
}

validate_build_info() {
  local build_info="$1"
  local executable="$2"
  local metallib="$3"
  local executable_sha256 metallib_sha256

  executable_sha256="$(sha256 "$executable")"
  metallib_sha256="$(sha256 "$metallib")"
  if ! python3 - "$build_info" "$executable_sha256" "$metallib_sha256" <<'PY'
import datetime
import json
import re
import sys
from pathlib import Path

build_info = Path(sys.argv[1])
actual_executable_sha256 = sys.argv[2]
actual_metallib_sha256 = sys.argv[3]


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value):
    raise ValueError(f"non-finite JSON value: {value}")


try:
    payload = json.loads(
        build_info.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicate_keys,
        parse_constant=reject_nonfinite,
    )
except Exception as exc:
    raise SystemExit(f"native msplat validation failed: invalid build_info.json: {exc}")

expected_keys = {
    "build_configuration",
    "build_timestamp",
    "cmake",
    "cmake_arguments",
    "checkpoint_patch_sha256",
    "compiler",
    "dependencies",
    "deployment_target",
    "densification_memory_patch_sha256",
    "exact_raster_patch_sha256",
    "executable_sha256",
    "metallib_sha256",
    "metal_safety_patch_sha256",
    "memory_efficiency_patch_sha256",
    "ninja",
    "numeric_stability_patch_sha256",
    "overlay_sha256",
    "patch_sha256",
    "raster_test_sha256",
    "row_span_culling_patch_sha256",
    "source_commit",
    "source_tree_sha256",
    "source_url",
    "source_version",
    "stage_timing_patch_sha256",
    "toolchain_name",
}
if not isinstance(payload, dict) or set(payload) != expected_keys:
    actual = set(payload) if isinstance(payload, dict) else set()
    missing = sorted(expected_keys - actual)
    unexpected = sorted(actual - expected_keys)
    raise SystemExit(
        "native msplat validation failed: build_info.json keys mismatch; "
        f"missing={missing}, unexpected={unexpected}"
    )

exact_values = {
    "toolchain_name": "msplat",
    "source_url": "https://github.com/rayanht/msplat.git",
    "source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
    "source_version": "1.1.3",
    "source_tree_sha256": "866fd6d051b5cf98ca08ae1552236473f504d8f13756cbda68201e48532c3e6a",
    "overlay_sha256": "cfefabcf9366571241e5a0923ae35fa3b8b263d6d024a87485bccc2e842ad29e",
    "raster_test_sha256": "8c3905839c31685cb836d75cc5bef1188c8e370bcab99dfe7a7696acd814ef46",
    "patch_sha256": "fafbf6f43a3be474a708607a903fc0dbb0029a4d4664c261a1ebaf301f3e9f3f",
    "checkpoint_patch_sha256": "c8b9a8dd03afb4bc50b8a12adf78dc46f5280d67bb62823c58aff2305a4870dc",
    "numeric_stability_patch_sha256": "231586b17e4f47c8c55432a631e08bf293b31a92f8d6ec49b367d11632350ec3",
    "metal_safety_patch_sha256": "5d3dfff3edcbca940d37f6ee3145c76c678ebd36ebc03016cfd5dab78e1d45ac",
    "exact_raster_patch_sha256": "278deba531d1503b8f6fe3428e0b6c5103129f388a6bc425c41780ff9e4c453b",
    "stage_timing_patch_sha256": "41e7146c2047a7a93b45927d1ee40d1e310db9898c25ab892a27c158acff75dd",
    "memory_efficiency_patch_sha256": "bfacc105454e80102139f120dd6375037360c6a9763f1e1f708aa2a7f22eca6c",
    "densification_memory_patch_sha256": "b429540372d807f280929ebba1670257990bd36b28dfee5b42bc377ccef60ac7",
    "row_span_culling_patch_sha256": "1147bb070a054f057fb8fa72b82263bfcf9398d31c9314ae51545f1b4e501050",
    "deployment_target": "macOS 15.0",
    "build_configuration": "Release",
}
for key, expected in exact_values.items():
    if payload.get(key) != expected:
        raise SystemExit(
            f"native msplat validation failed: build_info.json {key} mismatch; "
            f"expected {expected!r}, got {payload.get(key)!r}"
        )

expected_dependencies = {
    "nlohmann_json_v3.11.3_sha256": "04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069",
    "nanoflann_v1.5.5_sha256": "57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc",
    "cli11_v2.4.2_sha256": "43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0",
}
if payload.get("dependencies") != expected_dependencies:
    raise SystemExit("native msplat validation failed: build_info.json dependency pins mismatch")

expected_cmake_arguments = [
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
]
if payload.get("cmake_arguments") != expected_cmake_arguments:
    raise SystemExit("native msplat validation failed: build_info.json CMake arguments mismatch")

hash_pattern = re.compile(r"[0-9a-f]{64}\Z")
for key in (
    "source_tree_sha256",
    "overlay_sha256",
    "patch_sha256",
    "checkpoint_patch_sha256",
    "numeric_stability_patch_sha256",
    "metal_safety_patch_sha256",
    "exact_raster_patch_sha256",
    "stage_timing_patch_sha256",
    "memory_efficiency_patch_sha256",
    "densification_memory_patch_sha256",
    "row_span_culling_patch_sha256",
    "raster_test_sha256",
    "executable_sha256",
    "metallib_sha256",
):
    value = payload.get(key)
    if not isinstance(value, str) or not hash_pattern.fullmatch(value):
        raise SystemExit(f"native msplat validation failed: build_info.json {key} is not a lowercase SHA-256")

if payload["executable_sha256"] != actual_executable_sha256:
    raise SystemExit("native msplat validation failed: executable SHA-256 does not match build_info.json")
if payload["metallib_sha256"] != actual_metallib_sha256:
    raise SystemExit("native msplat validation failed: metallib SHA-256 does not match build_info.json")

for key in ("compiler", "cmake", "ninja"):
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip() or "\n" in value or "\r" in value:
        raise SystemExit(f"native msplat validation failed: build_info.json {key} is invalid")

timestamp = payload.get("build_timestamp")
if not isinstance(timestamp, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", timestamp):
    raise SystemExit("native msplat validation failed: build_info.json build_timestamp is not canonical UTC")
try:
    datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
except ValueError as exc:
    raise SystemExit(f"native msplat validation failed: invalid build_timestamp: {exc}")

serialized = json.dumps(payload, sort_keys=True)
if re.search(r"/Users/|/home/|file://|https?://[^/@\s]+:[^/@\s]+@", serialized, re.IGNORECASE):
    raise SystemExit("native msplat validation failed: build_info.json contains private or credentialed paths")
PY
  then
    return 1
  fi
}

validate_binary() {
  local executable="$1"
  local metallib="$2"
  local description dependency
  local stdout_file stderr_file

  [ -x "$executable" ] || fail "native trainer is not executable: $executable"
  [ -s "$metallib" ] || fail "default.metallib is empty: $metallib"

  description="$(/usr/bin/file -b "$executable")"
  [ "$description" = "Mach-O 64-bit executable arm64" ] \
    || fail "native trainer is not an arm64 Mach-O (file reported: $description)"
  reject_raster_test_symbols "$executable"

  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *) fail "native trainer has a non-system dynamic dependency: $dependency" ;;
    esac
  done < <(/usr/bin/otool -L "$executable" | tail -n +2 | awk '{print $1}')

  stdout_file="$(mktemp "${TMPDIR:-/tmp}/easysplat-msplat-self-check.XXXXXX")"
  stderr_file="$stdout_file.stderr"
  if ! "$executable" --self-check --events-fd 1 >"$stdout_file" 2>"$stderr_file"; then
    cat "$stderr_file" >&2 || true
    rm -f "$stdout_file" "$stderr_file"
    fail "native trainer self-check failed"
  fi
  if [ -s "$stderr_file" ]; then
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    fail "native trainer self-check wrote to stderr"
  fi
  if ! python3 - "$stdout_file" "$EXPECTED_VERSION" <<'PY'
import json
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
expected = {
    "event": "self_check",
    "scene_bounds_status": "ok",
    "schema_version": 2,
    "sequence": 1,
    "status": "ok",
    "version": sys.argv[2],
}
if len(lines) != 1:
    raise SystemExit("native msplat validation failed: self-check must emit exactly one JSONL event")
try:
    actual = json.loads(lines[0])
except Exception as exc:
    raise SystemExit(f"native msplat validation failed: self-check emitted invalid JSON: {exc}")
if actual != expected:
    raise SystemExit(
        "native msplat validation failed: self-check event mismatch; "
        f"expected {expected!r}, got {actual!r}"
    )
PY
  then
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  rm -f "$stdout_file" "$stderr_file"
}

validate_source() {
  local root="$1"
  local actual expected
  [ -d "$root" ] || fail "source install root is missing: $root"
  [ ! -L "$root" ] || fail "source install root must not be a symlink: $root"
  if find "$root" -type l -print -quit | grep -q .; then
    fail "source install contains a symlink"
  fi

  actual="$(cd "$root" && find . -mindepth 1 -print | LC_ALL=C sort)"
  expected=$'./LICENSE\n./bin\n./bin/default.metallib\n./bin/easysplat-train\n./build_info.json'
  [ "$actual" = "$expected" ] || fail "source install has missing or unexpected entries"

  require_regular_file "$root/bin/easysplat-train" "native trainer"
  require_regular_file "$root/bin/default.metallib" "Metal library"
  require_regular_file "$root/build_info.json" "build provenance"
  require_regular_file "$root/LICENSE" "license"
  [ -s "$root/LICENSE" ] || fail "license is empty"
  [ "$(sha256 "$root/LICENSE")" = "$EXPECTED_LICENSE_SHA256" ] || fail "upstream license SHA-256 mismatch"
  validate_build_info "$root/build_info.json" "$root/bin/easysplat-train" "$root/bin/default.metallib" || return 1
  validate_binary "$root/bin/easysplat-train" "$root/bin/default.metallib" || return 1
}

validate_packaged() {
  local root="$1"
  local actual expected
  [ -d "$root" ] || fail "packaged toolchain root is missing: $root"
  [ ! -L "$root" ] || fail "packaged toolchain root must not be a symlink: $root"

  for path in \
    "$root/bin/easysplat-train" \
    "$root/bin/default.metallib" \
    "$root/msplat/build_info.json" \
    "$root/msplat/LICENSE"; do
    require_regular_file "$path" "packaged native msplat file"
  done
  for path in "$root/bin" "$root/msplat"; do
    [ -d "$path" ] || fail "missing packaged directory: $path"
    [ ! -L "$path" ] || fail "packaged directory must not be a symlink: $path"
  done
  if find "$root/msplat" -type l -print -quit | grep -q .; then
    fail "packaged native msplat metadata contains a symlink"
  fi

  actual="$(cd "$root/msplat" && find . -mindepth 1 -print | LC_ALL=C sort)"
  expected=$'./LICENSE\n./build_info.json'
  [ "$actual" = "$expected" ] || fail "packaged native msplat metadata has missing or unexpected entries"

  while IFS= read -r path; do
    case "$(basename "$path")" in
      easysplat-train|default.metallib) ;;
      *msplat*|easysplat-train*|*.metallib)
        fail "unexpected native msplat file in packaged bin/: $path"
        ;;
    esac
  done < <(find "$root/bin" -mindepth 1 -maxdepth 1 -print)

  [ ! -e "$root/bin/msplat-train" ] || fail "legacy bin/msplat-train is forbidden"
  [ ! -e "$root/msplat/bin" ] || fail "legacy nested msplat/bin is forbidden"
  [ ! -e "$root/msplat/python" ] || fail "legacy packaged Python runtime is forbidden"
  [ -s "$root/msplat/LICENSE" ] || fail "packaged license is empty"
  [ "$(sha256 "$root/msplat/LICENSE")" = "$EXPECTED_LICENSE_SHA256" ] \
    || fail "packaged upstream license SHA-256 mismatch"
  validate_build_info \
    "$root/msplat/build_info.json" \
    "$root/bin/easysplat-train" \
    "$root/bin/default.metallib" || return 1
  validate_binary "$root/bin/easysplat-train" "$root/bin/default.metallib" || return 1
}

validate_archive() {
  local archive="$1"
  local temporary
  require_regular_file "$archive" "core archive"
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-msplat-archive.XXXXXX")"
  if ! python3 - "$archive" "$temporary" <<'PY'
import os
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

archive = Path(sys.argv[1])
destination = Path(sys.argv[2])
required = {
    "bin/easysplat-train",
    "bin/default.metallib",
    "msplat/build_info.json",
    "msplat/LICENSE",
}
entry_size_limits = {
    "bin/easysplat-train": 16 * 1024 * 1024,
    "bin/default.metallib": 16 * 1024 * 1024,
    "msplat/build_info.json": 64 * 1024,
    "msplat/LICENSE": 128 * 1024,
}
maximum_archive_bytes = 2 * 1024 * 1024 * 1024
maximum_entries = 100_000
maximum_name_bytes = 16 * 1024 * 1024
maximum_entry_bytes = 1024 * 1024 * 1024
maximum_uncompressed_bytes = 8 * 1024 * 1024 * 1024
maximum_compression_ratio = 100

try:
    archive_size = archive.stat().st_size
except OSError as exc:
    raise SystemExit(f"native msplat validation failed: core archive stat failed: {exc}")
if archive_size <= 0 or archive_size > maximum_archive_bytes:
    raise SystemExit("native msplat validation failed: core archive exceeds the size limit")

try:
    handle = zipfile.ZipFile(archive)
except Exception as exc:
    raise SystemExit(f"native msplat validation failed: core archive is unreadable: {exc}")

with handle:
    infos = handle.infolist()
    if len(infos) > maximum_entries:
        raise SystemExit("native msplat validation failed: core archive exceeds the entry-count limit")
    if sum(len(info.filename.encode("utf-8")) for info in infos) > maximum_name_bytes:
        raise SystemExit("native msplat validation failed: core archive filenames exceed the size limit")
    names = [info.filename for info in infos]
    if len(names) != len(set(names)):
        raise SystemExit("native msplat validation failed: core archive contains duplicate entries")
    total_uncompressed_bytes = 0
    for info in infos:
        name = info.filename
        path = PurePosixPath(name)
        normalized = path.as_posix() + ("/" if name.endswith("/") else "")
        if (
            not name
            or "\\" in name
            or path.is_absolute()
            or ".." in path.parts
            or any(part in ("", ".") for part in path.parts)
            or normalized != name
        ):
            raise SystemExit(f"native msplat validation failed: unsafe archive entry: {name!r}")
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise SystemExit(f"native msplat validation failed: archive symlink is forbidden: {name}")
        if info.flag_bits & 0x1:
            raise SystemExit(f"native msplat validation failed: encrypted archive entry is forbidden: {name}")
        if name.endswith("/"):
            if info.file_size != 0:
                raise SystemExit(
                    f"native msplat validation failed: archive directory has a payload: {name}"
                )
            continue
        if mode and not stat.S_ISREG(mode):
            raise SystemExit(
                f"native msplat validation failed: archive entry is not a regular file: {name}"
            )
        entry_limit = entry_size_limits.get(name, maximum_entry_bytes)
        if info.file_size > entry_limit:
            raise SystemExit(
                f"native msplat validation failed: archive entry exceeds the size limit: {name}"
            )
        if info.file_size > 0 and (
            info.compress_size <= 0
            or info.file_size > info.compress_size * maximum_compression_ratio
        ):
            raise SystemExit(
                f"native msplat validation failed: archive entry exceeds the compression ratio limit: {name}"
            )
        total_uncompressed_bytes += info.file_size
        if total_uncompressed_bytes > maximum_uncompressed_bytes:
            raise SystemExit(
                "native msplat validation failed: core archive exceeds the uncompressed size limit"
            )

    files = {name.rstrip("/") for name in names if not name.endswith("/")}
    missing = sorted(required - files)
    if missing:
        raise SystemExit(f"native msplat validation failed: core archive is missing: {missing}")
    unexpected_msplat = sorted(
        name for name in files if name.startswith("msplat/") and name not in required
    )
    if unexpected_msplat:
        raise SystemExit(
            "native msplat validation failed: core archive contains unexpected msplat entries: "
            f"{unexpected_msplat}"
        )
    if "bin/msplat-train" in files:
        raise SystemExit("native msplat validation failed: core archive contains legacy bin/msplat-train")
    unexpected_bin = sorted(
        name
        for name in files
        if name.startswith("bin/")
        and name not in required
        and (
            "msplat" in PurePosixPath(name).name
            or PurePosixPath(name).name.startswith("easysplat-train")
            or PurePosixPath(name).suffix == ".metallib"
        )
    )
    if unexpected_bin:
        raise SystemExit(
            "native msplat validation failed: core archive contains unexpected native trainer entries: "
            f"{unexpected_bin}"
        )

    info_by_name = {info.filename: info for info in infos}
    required_total = 0
    for name, limit in entry_size_limits.items():
        info = info_by_name[name]
        if info.file_size <= 0 or info.file_size > limit:
            raise SystemExit(
                f"native msplat validation failed: {name} exceeds its size limit"
            )
        if info.compress_size <= 0 or info.file_size > info.compress_size * maximum_compression_ratio:
            raise SystemExit(
                f"native msplat validation failed: {name} exceeds the compression ratio limit"
            )
        required_total += info.file_size
    if required_total > sum(entry_size_limits.values()):
        raise SystemExit("native msplat validation failed: required entries exceed the aggregate size limit")

    for name in sorted(required):
        info = info_by_name[name]
        limit = entry_size_limits[name]
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        copied = 0
        with handle.open(info) as source, target.open("xb") as output:
            while True:
                chunk = source.read(min(1024 * 1024, limit - copied + 1))
                if not chunk:
                    break
                copied += len(chunk)
                if copied > limit or copied > info.file_size:
                    raise SystemExit(
                        f"native msplat validation failed: {name} exceeded its declared size"
                    )
                output.write(chunk)
        if copied != info.file_size:
            raise SystemExit(
                f"native msplat validation failed: {name} did not match its declared size"
            )
    os.chmod(destination / "bin/easysplat-train", 0o755)
PY
  then
    rm -rf "$temporary"
    return 1
  fi
  if ! validate_packaged "$temporary"; then
    rm -rf "$temporary"
    return 1
  fi
  rm -rf "$temporary"
}

[ "$#" -eq 2 ] || usage
case "$1" in
  --source)
    validate_source "$2"
    ;;
  --packaged)
    validate_packaged "$2"
    ;;
  --archive)
    validate_archive "$2"
    ;;
  *)
    usage
    ;;
esac
