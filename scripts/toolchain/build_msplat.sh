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
BACKUP_DIR="$INSTALL_PARENT/msplat.previous.$$"

OVERLAY="$ROOT/Tools/MsplatNative/msplat.cpp"
RASTER_TEST_SOURCE="$ROOT/Tools/MsplatNative/msplat_raster_tests.cpp"
FIXTURE_GENERATOR="$ROOT/scripts/ci/generate_msplat_sparse_fixtures.py"
UPSTREAM_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-easysplat.patch"
CHECKPOINT_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-checkpoint.patch"
NUMERIC_STABILITY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-numeric-stability.patch"
NUMERIC_STABILITY_PATCH_SHA256="231586b17e4f47c8c55432a631e08bf293b31a92f8d6ec49b367d11632350ec3"
METAL_SAFETY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-metal-safety.patch"
METAL_SAFETY_PATCH_SHA256="5d3dfff3edcbca940d37f6ee3145c76c678ebd36ebc03016cfd5dab78e1d45ac"
EXACT_RASTER_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-raster.patch"
EXACT_RASTER_PATCH_SHA256="dd1f1a802cabaaceeab8825535e374f21ad723c680d4e70bcfc7d3d4e865962d"
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

cleanup() {
  local status=$?
  rm -rf "$STAGE_DIR"
  if [ "$status" -ne 0 ] && [ -d "$BACKUP_DIR" ] && [ ! -e "$INSTALL_DIR" ]; then
    mv "$BACKUP_DIR" "$INSTALL_DIR"
  fi
  if [ "$status" -eq 0 ]; then
    rm -rf "$BACKUP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

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
    msplat_copy_last_raster_debug; do
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
  for command in cmake ninja git curl shasum xcrun ditto file python3; do
    require_command "$command"
  done
  if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
    echo "Xcode's optional Metal compiler is required." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  [ -f "$OVERLAY" ] || die "missing CLI overlay: $OVERLAY"
  [ -f "$RASTER_TEST_SOURCE" ] || die "missing raster parity test: $RASTER_TEST_SOURCE"
  [ -f "$FIXTURE_GENERATOR" ] || die "missing sparse fixture generator: $FIXTURE_GENERATOR"
  [ -f "$UPSTREAM_PATCH" ] || die "missing upstream patch: $UPSTREAM_PATCH"
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
  rm -rf "$RASTER_TEST_FIXTURES"
  python3 "$FIXTURE_GENERATOR" --output "$RASTER_TEST_FIXTURES"
  "$NATIVE_BUILD_DIR/msplat_raster_tests" \
    "$RASTER_TEST_FIXTURES/01-sphere-500" \
    "$RASTER_TEST_FIXTURES/14-mixed-resolution-500" \
    "$RASTER_TEST_FIXTURES/13-overflow-2304" \
    "$RASTER_TEST_FIXTURES/16-broad-overflow-2304" \
    "$RASTER_TEST_FIXTURES/15-increasing-overflow-10000" \
    "$RASTER_TEST_FIXTURES/17-exact-budget-1279"
}

write_build_info() {
  local executable_sha256="$1"
  local metallib_sha256="$2"
  local build_info compiler cmake_version ninja_version timestamp overlay_sha256 raster_test_sha256 patch_sha256 checkpoint_patch_sha256 numeric_stability_patch_sha256 metal_safety_patch_sha256 exact_raster_patch_sha256
  build_info="$STAGE_DIR/build_info.json"
  compiler="$(xcrun clang++ --version | head -n 1)"
  cmake_version="$(cmake --version | head -n 1)"
  ninja_version="$(ninja --version)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  overlay_sha256="$(sha256 "$OVERLAY")"
  raster_test_sha256="$(sha256 "$RASTER_TEST_SOURCE")"
  patch_sha256="$(sha256 "$UPSTREAM_PATCH")"
  checkpoint_patch_sha256="$(sha256 "$CHECKPOINT_PATCH")"
  numeric_stability_patch_sha256="$(sha256 "$NUMERIC_STABILITY_PATCH")"
  metal_safety_patch_sha256="$(sha256 "$METAL_SAFETY_PATCH")"
  exact_raster_patch_sha256="$(sha256 "$EXACT_RASTER_PATCH")"

  python3 - "$build_info" \
    "$MSPLAT_REPO" "$MSPLAT_COMMIT" "$MSPLAT_VERSION" "$SOURCE_TREE_SHA256" \
    "$overlay_sha256" "$raster_test_sha256" "$patch_sha256" "$checkpoint_patch_sha256" "$numeric_stability_patch_sha256" "$metal_safety_patch_sha256" "$exact_raster_patch_sha256" \
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
    checkpoint_patch_sha256,
    numeric_stability_patch_sha256,
    metal_safety_patch_sha256,
    exact_raster_patch_sha256,
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
    "checkpoint_patch_sha256": checkpoint_patch_sha256,
    "numeric_stability_patch_sha256": numeric_stability_patch_sha256,
    "metal_safety_patch_sha256": metal_safety_patch_sha256,
    "exact_raster_patch_sha256": exact_raster_patch_sha256,
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
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR/bin"
  install -m 0755 "$NATIVE_BUILD_DIR/msplat" "$STAGE_DIR/bin/easysplat-train"
  install -m 0644 "$NATIVE_BUILD_DIR/default.metallib" "$STAGE_DIR/bin/default.metallib"
  install -m 0644 "$SOURCE_DIR/LICENSE" "$STAGE_DIR/LICENSE"

  local executable_sha256 metallib_sha256
  executable_sha256="$(sha256 "$STAGE_DIR/bin/easysplat-train")"
  metallib_sha256="$(sha256 "$STAGE_DIR/bin/default.metallib")"
  write_build_info "$executable_sha256" "$metallib_sha256"
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

  if ! python3 - "$STAGE_DIR/build_info.json" "$(sha256 "$binary")" "$(sha256 "$metallib")" <<'PY'
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
  rm -rf "$BACKUP_DIR"
  if [ -e "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$BACKUP_DIR"
  fi
  if ! mv "$STAGE_DIR" "$INSTALL_DIR"; then
    [ ! -e "$INSTALL_DIR" ] || rm -rf "$INSTALL_DIR"
    [ ! -d "$BACKUP_DIR" ] || mv "$BACKUP_DIR" "$INSTALL_DIR"
    die "could not promote staged install"
  fi
  rm -rf "$BACKUP_DIR"
}

preflight
mkdir -p "$BUILD_DIR" "$INSTALL_PARENT"
prepare_dependencies
prepare_source
configure_and_build
stage_install
validate_stage
promote_install

echo "native msplat ready at $INSTALL_DIR"
