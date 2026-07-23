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
PROMOTER_SOURCE="$ROOT/scripts/toolchain/atomic_swap_install.py"
BUILD_LOCK_PATH="$ROOT/Toolchains/.msplat-build.lock"
BUILD_LOCK_PROMOTER_SOURCE="$ROOT/scripts/toolchain/atomic_swap_install.py"
BUILD_LOCK_PROMOTER_SHA256=""
BUILD_LOCK_DEVICE=""
BUILD_LOCK_INODE=""
BUILD_LOCK_OWNED=0
PROMOTER_RUNTIME_DIR=""
PROMOTER_RUNTIME=""
PROMOTER_RUNTIME_SOURCE_SHA256=""
PROMOTER_RUNTIME_DEVICE=""
PROMOTER_RUNTIME_INODE=""
PROMOTER_RUNTIME_OWNED=0
PROMOTER_RUNTIME_READY=0
BUILD_INPUT_SNAPSHOT_DIR=""
BUILD_INPUT_SNAPSHOT_DEVICE=""
BUILD_INPUT_SNAPSHOT_INODE=""
BUILD_INPUT_SNAPSHOT_OWNED=0
BUILD_INPUT_SNAPSHOT_READY=0
DEFERRED_BUILD_SIGNAL=0
CLEANUP_DEFERRED_SIGNAL=0
PYTHON_BIN="/usr/bin/python3"
INSTALL_STAGE_OWNED=0
INSTALL_STAGE_DEVICE=""
INSTALL_STAGE_INODE=""

OVERLAY="$ROOT/Tools/MsplatNative/msplat.cpp"
OVERLAY_SHA256="c4ebdfa026353eeb894ad7d4d8f0b7a68e67f61d99c4eaae929321e6e6bf1489"
RASTER_TEST_SOURCE="$ROOT/Tools/MsplatNative/msplat_raster_tests.cpp"
RASTER_TEST_SHA256="06eec969719a4b44102280eed79d817c8774dafbd3050b90324d9898bc57e43d"
ISOLATION_HEADER="$ROOT/Tools/MsplatNative/isolation.hpp"
ISOLATION_HEADER_SHA256="ecb457dc03d75aaa5a76b34c0d39a5d110629b0a3025b60976e1c1d3f7a9cbc8"
ISOLATION_SOURCE="$ROOT/Tools/MsplatNative/isolation.cpp"
ISOLATION_SOURCE_SHA256="40444aa0fc5a07f6919b28ef4dac1517a6627daa81331013b71ba49ff465c9fc"
ISOLATION_RUNTIME_HEADER="$ROOT/Tools/MsplatNative/isolation_runtime.hpp"
ISOLATION_RUNTIME_HEADER_SHA256="f3fae8409eeb24446bd9b5f4970b64522f01b1048c25827b712f4bef087b7d82"
ISOLATION_RUNTIME_SOURCE="$ROOT/Tools/MsplatNative/isolation_runtime.cpp"
ISOLATION_RUNTIME_SOURCE_SHA256="d1a1aa29a11e0f581b647554ace492710936c4e6ccc14c85c4fbc292625fbfc5"
ISOLATION_MASK_HEADER="$ROOT/Tools/MsplatNative/isolation_mask.hpp"
ISOLATION_MASK_HEADER_SHA256="51956923935621ef2e3681f33e11b1f63a6d1ed969234ee9e50edab927f712d7"
ISOLATION_MASK_SOURCE="$ROOT/Tools/MsplatNative/isolation_mask.mm"
ISOLATION_MASK_SOURCE_SHA256="ad9844c13dd427517311f0ad0725ffa348beb4c590d6febc6efe11c38d7240e8"
ISOLATION_METAL_SOURCE="$ROOT/Tools/MsplatNative/isolation_lift.metal"
ISOLATION_METAL_SOURCE_SHA256="c063a934eee67eb22e04483f32e798e6844ee722dde9daddeed79f5db56c13bc"
ISOLATION_TEST_SOURCE="$ROOT/Tools/MsplatNative/isolation_tests.cpp"
ISOLATION_TEST_SOURCE_SHA256="c2929e9ddf86b83527fb717277d6cc0d3da379f95ff4652a212daffb0aa94d71"
ISOLATION_MASK_TEST_SOURCE="$ROOT/Tools/MsplatNative/isolation_mask_tests.mm"
ISOLATION_MASK_TEST_SOURCE_SHA256="f4900f77878a22417c1bd397ee87d2730c21344d9ba9ab7e1579bfa083e7d2bc"
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
STAGE_TIMING_PATCH_SHA256="fcc00c8b9eb3c79ccc7be3f27b997421b28e2c0ea98477c4382d7acefd334435"
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
ALLOCATION_PRESSURE_PATCH_SHA256="34611e91e896f56c9ad81ae2c4bd55352b4172d5cbdb83da7658e9050382b4a8"
EXACT_PREFIX_HARDENING_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-exact-prefix-hardening.patch"
EXACT_PREFIX_HARDENING_PATCH_SHA256="510d70ac3413cbf1260881ed1399e5301cc1fce0d783a1e451381c9e3ec8c9fb"
QUATERNION_STABILITY_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-quaternion-stability.patch"
QUATERNION_STABILITY_PATCH_SHA256="d0aabc26d10b316a669c120ebdfdf573dd645c30c857e97b6ceeaa8c2c76b786"
ISOLATION_PATCH="$ROOT/Tools/MsplatNative/msplat-1.1.3-isolation.patch"
ISOLATION_PATCH_SHA256="a8a579d9d2a5ca23ce87ae0dd2a1f79de8da56bbfa62851244cfdda51bc37f59"
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

run_promoter() {
  [ "$PROMOTER_RUNTIME_READY" = "1" ] || \
    die "private atomic install promoter is unavailable"
  "$PYTHON_BIN" "$PROMOTER_RUNTIME" "$@"
}

run_promoter_source_from_stdin() {
  "$PYTHON_BIN" - "$@" < "$PROMOTER_SOURCE"
}

cleanup() {
  local status=$?
  local install_cleanup_status=0
  local promoter_cleanup_status=0
  local snapshot_cleanup_status=0
  local snapshot_cleanup_attempted=0
  local lock_cleanup_status=0
  trap - EXIT
  trap 'CLEANUP_DEFERRED_SIGNAL=2' INT
  trap 'CLEANUP_DEFERRED_SIGNAL=15' TERM
  trap 'CLEANUP_DEFERRED_SIGNAL=1' HUP
  if [ "$STAGE_CLEANUP_ALLOWED" = "1" ] && [ "$INSTALL_STAGE_OWNED" = "1" ]; then
    if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ] && \
      [ "$PROMOTER_RUNTIME_READY" = "1" ]; then
      run_promoter \
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
  if [ "$BUILD_INPUT_SNAPSHOT_OWNED" = "1" ] && \
    [ "$PROMOTER_RUNTIME_READY" = "1" ]; then
    snapshot_cleanup_attempted=1
    cleanup_build_input_snapshot || snapshot_cleanup_status=$?
  fi
  if [ "$PROMOTER_RUNTIME_OWNED" = "1" ]; then
    if [ "$PROMOTER_RUNTIME_READY" = "1" ]; then
      run_promoter \
        --remove-owned-tree \
        "$PROMOTER_RUNTIME_DIR" \
        "$PROMOTER_RUNTIME_DEVICE" \
        "$PROMOTER_RUNTIME_INODE" \
        --allow-symlinks || promoter_cleanup_status=$?
    elif [ -n "$PROMOTER_RUNTIME_SOURCE_SHA256" ] && \
      [ -f "$PROMOTER_SOURCE" ] && [ ! -L "$PROMOTER_SOURCE" ] && \
      [ "$(sha256 "$PROMOTER_SOURCE")" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ]; then
      run_promoter_source_from_stdin \
        --remove-owned-tree \
        "$PROMOTER_RUNTIME_DIR" \
        "$PROMOTER_RUNTIME_DEVICE" \
        "$PROMOTER_RUNTIME_INODE" \
        --allow-symlinks || promoter_cleanup_status=$?
    else
      promoter_cleanup_status=1
    fi
    if [ "$promoter_cleanup_status" -ne 0 ]; then
      printf '%s\n' \
        "native msplat cleanup preserved an unverified private promoter: $PROMOTER_RUNTIME_DIR" >&2
    fi
  fi
  if [ "$BUILD_INPUT_SNAPSHOT_OWNED" = "1" ] && \
    [ "$snapshot_cleanup_attempted" = "0" ]; then
    cleanup_build_input_snapshot || snapshot_cleanup_status=$?
  fi
  if [ "$snapshot_cleanup_status" -ne 0 ]; then
    printf '%s\n' \
      "native msplat cleanup preserved an unverified build-input snapshot: $BUILD_INPUT_SNAPSHOT_DIR" >&2
  fi
  if [ "$BUILD_LOCK_OWNED" = "1" ]; then
    release_build_lock || lock_cleanup_status=$?
    if [ "$lock_cleanup_status" -ne 0 ]; then
      printf '%s\n' \
        "native msplat cleanup preserved an unverified build lock: $BUILD_LOCK_PATH" >&2
    fi
  fi
  if [ "$status" -eq 0 ] && [ "$install_cleanup_status" -ne 0 ]; then
    status="$install_cleanup_status"
  fi
  if [ "$status" -eq 0 ] && [ "$promoter_cleanup_status" -ne 0 ]; then
    status="$promoter_cleanup_status"
  fi
  if [ "$status" -eq 0 ] && [ "$snapshot_cleanup_status" -ne 0 ]; then
    status="$snapshot_cleanup_status"
  fi
  if [ "$status" -eq 0 ] && [ "$lock_cleanup_status" -ne 0 ]; then
    status="$lock_cleanup_status"
  fi
  if [ "$CLEANUP_DEFERRED_SIGNAL" -ne 0 ]; then
    status=$((128 + CLEANUP_DEFERRED_SIGNAL))
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

normalize_private_promoter_metadata() {
  local entry="$1"
  local attribute
  while IFS= read -r attribute; do
    [ -n "$attribute" ] || continue
    [ "$attribute" = "com.apple.provenance" ] || \
      die "private atomic install promoter has unexpected metadata: $attribute"
  done < <(/usr/bin/xattr -s "$entry")
  if /usr/bin/xattr -s "$entry" | grep -Fxq 'com.apple.provenance'; then
    /usr/bin/xattr -s -d com.apple.provenance "$entry" || \
      die "could not remove system provenance from private atomic install promoter"
  fi
  [ -z "$(/usr/bin/xattr -s "$entry")" ] || \
    die "private atomic install promoter metadata normalization was incomplete"
}

restore_build_signal_traps() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

capture_deferred_build_signal() {
  local signal="$1"
  if [ "$DEFERRED_BUILD_SIGNAL" -eq 0 ]; then
    DEFERRED_BUILD_SIGNAL="$signal"
  fi
}

begin_deferred_build_signals() {
  DEFERRED_BUILD_SIGNAL=0
  trap 'capture_deferred_build_signal 2' INT
  trap 'capture_deferred_build_signal 15' TERM
  trap 'capture_deferred_build_signal 1' HUP
}

replay_deferred_build_signal() {
  local signal="$DEFERRED_BUILD_SIGNAL"
  restore_build_signal_traps
  DEFERRED_BUILD_SIGNAL=0
  if [ "$signal" -ne 0 ]; then
    exit $((128 + signal))
  fi
}

release_build_lock() {
  [ "$BUILD_LOCK_OWNED" = "1" ] || return 0
  [ -f "$BUILD_LOCK_PROMOTER_SOURCE" ] && \
    [ ! -L "$BUILD_LOCK_PROMOTER_SOURCE" ] && \
    [ "$(sha256 "$BUILD_LOCK_PROMOTER_SOURCE")" = "$BUILD_LOCK_PROMOTER_SHA256" ] \
    || return 1
  "$PYTHON_BIN" - \
    --remove-bound-build-lock \
    "$BUILD_LOCK_PATH" \
    "$BUILD_LOCK_DEVICE" \
    "$BUILD_LOCK_INODE" \
    "$$" < "$BUILD_LOCK_PROMOTER_SOURCE" || return $?
  BUILD_LOCK_OWNED=0
}

acquire_build_lock() {
  local identity
  BUILD_LOCK_PROMOTER_SHA256="$(sha256 "$BUILD_LOCK_PROMOTER_SOURCE")"
  begin_deferred_build_signals
  if ! /usr/bin/shlock -f "$BUILD_LOCK_PATH" -p "$$"; then
    replay_deferred_build_signal
    die "another native msplat build already holds $BUILD_LOCK_PATH"
  fi
  if ! identity="$(
    "$PYTHON_BIN" - "$BUILD_LOCK_PATH" "$$" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
owner_pid = int(sys.argv[2])
before = os.lstat(path)
descriptor = os.open(
    path,
    os.O_RDONLY
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0),
)
try:
    opened = os.fstat(descriptor)
    content = os.read(descriptor, 64)
    after = os.fstat(descriptor)
    named = os.lstat(path)
finally:
    os.close(descriptor)
fields = (
    "st_dev",
    "st_ino",
    "st_mode",
    "st_nlink",
    "st_uid",
    "st_gid",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
    "st_flags",
)
if (
    not stat.S_ISREG(opened.st_mode)
    or any(getattr(before, field) != getattr(item, field)
           for item in (opened, after, named)
           for field in fields)
    or opened.st_nlink != 1
    or opened.st_uid != os.getuid()
    or opened.st_gid != os.getgid()
    or stat.S_IMODE(opened.st_mode) != 0o644
    or opened.st_flags != 0
    or content != f"{owner_pid}\n".encode("ascii")
):
    raise SystemExit("native build lock identity is invalid")
print(f"{opened.st_dev}:{opened.st_ino}")
PY
  )"; then
    replay_deferred_build_signal
    die "could not bind the native msplat build lock"
  fi
  if [[ ! "$identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    replay_deferred_build_signal
    die "native msplat build lock identity is malformed"
  fi
  BUILD_LOCK_DEVICE="${identity%%:*}"
  BUILD_LOCK_INODE="${identity#*:}"
  BUILD_LOCK_OWNED=1
  replay_deferred_build_signal
}

run_build_lock_probe() {
  local probe_dir="${EASYSPLAT_MSPLAT_BUILD_LOCK_PROBE_DIR:-}"
  local iteration
  [ -n "$probe_dir" ] || return 1
  "$PYTHON_BIN" - "$probe_dir" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
entry = os.lstat(root)
if (
    not stat.S_ISDIR(entry.st_mode)
    or entry.st_uid != os.getuid()
    or entry.st_gid != os.getgid()
    or stat.S_IMODE(entry.st_mode) != 0o700
):
    raise SystemExit("build-lock probe directory is not private")
descriptor = os.open(
    root / "acquired",
    os.O_WRONLY
    | os.O_CREAT
    | os.O_EXCL
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0),
    0o600,
)
os.close(descriptor)
PY
  for iteration in {1..200}; do
    if [ -f "$probe_dir/release" ] && [ ! -L "$probe_dir/release" ]; then
      return 0
    fi
    /bin/sleep 0.05
  done
  die "timed out waiting for the native build-lock probe release"
}

abandon_unbound_private_promoter() {
  local reason="$1"
  local path="$PROMOTER_RUNTIME_DIR"
  if [ -n "$path" ] && [ -d "$path" ] && [ ! -L "$path" ]; then
    /bin/rmdir "$path" || {
      replay_deferred_build_signal
      die "$reason; preserved an unverified private promoter: $path"
    }
  fi
  PROMOTER_RUNTIME_DIR=""
  replay_deferred_build_signal
  die "$reason"
}

recover_stale_private_promoters() {
  local path identity
  for path in "$BUILD_DIR"/promoter.stage.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    if ! identity="$(
      "$PYTHON_BIN" - "$path" "$PROMOTER_RUNTIME_SOURCE_SHA256" <<'PY'
import os
import re
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
if not re.fullmatch(r"promoter[.]stage[.][A-Za-z0-9]{6}", root.name):
    raise SystemExit("stale private promoter name is ambiguous")
entry = os.lstat(root)
if (
    not stat.S_ISDIR(entry.st_mode)
    or entry.st_uid != os.getuid()
    or entry.st_gid != os.getgid()
    or stat.S_IMODE(entry.st_mode) != 0o700
):
    raise SystemExit("stale private promoter root is not strictly owned")
print(f"{entry.st_dev}:{entry.st_ino}")
PY
    )"; then
      die "ambiguous stale private promoter requires manual recovery: $path"
    fi
    [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
      die "stale private promoter identity is malformed: $path"
    run_promoter_source_from_stdin \
      --remove-private-promoter-tree \
      "$path" \
      "${identity%%:*}" \
      "${identity#*:}" \
      "$PROMOTER_RUNTIME_SOURCE_SHA256" || \
      die "could not recover stale private promoter: $path"
  done
}

prepare_private_promoter() {
  local identity runtime_hash
  PROMOTER_RUNTIME_SOURCE_SHA256="$(sha256 "$PROMOTER_SOURCE")"
  begin_deferred_build_signals
  if ! PROMOTER_RUNTIME_DIR="$(mktemp -d "$BUILD_DIR/promoter.stage.XXXXXX")"; then
    replay_deferred_build_signal
    die "could not create private atomic install promoter directory"
  fi
  if ! identity="$(
    "$PYTHON_BIN" - "$PROMOTER_RUNTIME_DIR" <<'PY'
import os
import stat
import sys

entry = os.lstat(sys.argv[1])
if not stat.S_ISDIR(entry.st_mode):
    raise SystemExit("private promoter root is not a directory")
if entry.st_uid != os.getuid() or entry.st_gid != os.getgid():
    raise SystemExit("private promoter root ownership is invalid")
if stat.S_IMODE(entry.st_mode) != 0o700:
    raise SystemExit("private promoter root permissions are invalid")
print(f"{entry.st_dev}:{entry.st_ino}")
PY
  )"; then
    abandon_unbound_private_promoter \
      "could not bind private atomic install promoter directory"
  fi
  if [[ ! "$identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    abandon_unbound_private_promoter \
      "private atomic install promoter identity is malformed"
  fi
  PROMOTER_RUNTIME_DEVICE="${identity%%:*}"
  PROMOTER_RUNTIME_INODE="${identity#*:}"
  PROMOTER_RUNTIME_OWNED=1
  replay_deferred_build_signal
  PROMOTER_RUNTIME="$PROMOTER_RUNTIME_DIR/atomic_swap_install.py"

  install -m 0700 "$PROMOTER_SOURCE" "$PROMOTER_RUNTIME"
  runtime_hash="$(sha256 "$PROMOTER_RUNTIME")"
  [ "$runtime_hash" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ] || \
    die "private atomic install promoter copy changed"
  normalize_private_promoter_metadata "$PROMOTER_RUNTIME"
  normalize_private_promoter_metadata "$PROMOTER_RUNTIME_DIR"
  [ "$(sha256 "$PROMOTER_SOURCE")" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ] || \
    die "atomic install promoter source changed during private copy"
  [ "$(sha256 "$PROMOTER_RUNTIME")" = "$PROMOTER_RUNTIME_SOURCE_SHA256" ] || \
    die "private atomic install promoter changed during metadata cleanup"
  "$PYTHON_BIN" - "$PROMOTER_RUNTIME" <<'PY'
import os
import stat
import sys

entry = os.lstat(sys.argv[1])
if not stat.S_ISREG(entry.st_mode):
    raise SystemExit("private promoter is not a regular file")
if entry.st_nlink != 1:
    raise SystemExit("private promoter must have exactly one link")
if entry.st_uid != os.getuid() or entry.st_gid != os.getgid():
    raise SystemExit("private promoter ownership is invalid")
if stat.S_IMODE(entry.st_mode) != 0o700:
    raise SystemExit("private promoter permissions are invalid")
PY
  PROMOTER_RUNTIME_READY=1
}

create_owned_install_stage() {
  local identity
  identity="$(
    run_promoter --create-owned-tree "$STAGE_DIR"
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
    run_promoter --recover "$journal" || \
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
    msplat_quaternion_vjp_for_testing \
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
  [ -x /usr/bin/shlock ] || die "required command is missing: /usr/bin/shlock"
  [ -d "$ROOT/Toolchains" ] && [ ! -L "$ROOT/Toolchains" ] \
    || die "Toolchains must be an ordinary directory"
  [ -x "$PYTHON_BIN" ] || die "selected Python executable is unavailable"
  [ -f "$PROMOTER_SOURCE" ] && [ ! -L "$PROMOTER_SOURCE" ] \
    || die "atomic install promoter must be a regular file"
  if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
    echo "Xcode's optional Metal compiler is required." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  [ -f "$OVERLAY" ] || die "missing CLI overlay: $OVERLAY"
  [ "$(sha256 "$OVERLAY")" = "$OVERLAY_SHA256" ] \
    || die "CLI overlay SHA-256 mismatch"
  [ -f "$RASTER_TEST_SOURCE" ] || die "missing raster parity test: $RASTER_TEST_SOURCE"
  [ -f "$ISOLATION_HEADER" ] || die "missing isolation header: $ISOLATION_HEADER"
  [ "$(sha256 "$ISOLATION_HEADER")" = "$ISOLATION_HEADER_SHA256" ] \
    || die "isolation header SHA-256 mismatch"
  [ -f "$ISOLATION_SOURCE" ] || die "missing isolation source: $ISOLATION_SOURCE"
  [ "$(sha256 "$ISOLATION_SOURCE")" = "$ISOLATION_SOURCE_SHA256" ] \
    || die "isolation source SHA-256 mismatch"
  [ -f "$ISOLATION_RUNTIME_HEADER" ] \
    || die "missing isolation runtime header: $ISOLATION_RUNTIME_HEADER"
  [ "$(sha256 "$ISOLATION_RUNTIME_HEADER")" = "$ISOLATION_RUNTIME_HEADER_SHA256" ] \
    || die "isolation runtime header SHA-256 mismatch"
  [ -f "$ISOLATION_RUNTIME_SOURCE" ] \
    || die "missing isolation runtime source: $ISOLATION_RUNTIME_SOURCE"
  [ "$(sha256 "$ISOLATION_RUNTIME_SOURCE")" = "$ISOLATION_RUNTIME_SOURCE_SHA256" ] \
    || die "isolation runtime source SHA-256 mismatch"
  [ -f "$ISOLATION_MASK_HEADER" ] \
    || die "missing isolation mask header: $ISOLATION_MASK_HEADER"
  [ "$(sha256 "$ISOLATION_MASK_HEADER")" = "$ISOLATION_MASK_HEADER_SHA256" ] \
    || die "isolation mask header SHA-256 mismatch"
  [ -f "$ISOLATION_MASK_SOURCE" ] \
    || die "missing isolation mask source: $ISOLATION_MASK_SOURCE"
  [ "$(sha256 "$ISOLATION_MASK_SOURCE")" = "$ISOLATION_MASK_SOURCE_SHA256" ] \
    || die "isolation mask source SHA-256 mismatch"
  [ -f "$ISOLATION_METAL_SOURCE" ] \
    || die "missing isolation Metal source: $ISOLATION_METAL_SOURCE"
  [ "$(sha256 "$ISOLATION_METAL_SOURCE")" = "$ISOLATION_METAL_SOURCE_SHA256" ] \
    || die "isolation Metal source SHA-256 mismatch"
  [ -f "$ISOLATION_TEST_SOURCE" ] \
    || die "missing isolation test source: $ISOLATION_TEST_SOURCE"
  [ "$(sha256 "$ISOLATION_TEST_SOURCE")" = "$ISOLATION_TEST_SOURCE_SHA256" ] \
    || die "isolation test source SHA-256 mismatch"
  [ -f "$ISOLATION_MASK_TEST_SOURCE" ] \
    || die "missing isolation mask test source: $ISOLATION_MASK_TEST_SOURCE"
  [ "$(sha256 "$ISOLATION_MASK_TEST_SOURCE")" = "$ISOLATION_MASK_TEST_SOURCE_SHA256" ] \
    || die "isolation mask test source SHA-256 mismatch"
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
  [ -f "$QUATERNION_STABILITY_PATCH" ] \
    || die "missing quaternion-stability patch: $QUATERNION_STABILITY_PATCH"
  [ "$(sha256 "$QUATERNION_STABILITY_PATCH")" = "$QUATERNION_STABILITY_PATCH_SHA256" ] \
    || die "quaternion-stability patch SHA-256 mismatch"
  [ -f "$ISOLATION_PATCH" ] || die "missing isolation patch: $ISOLATION_PATCH"
  [ "$(sha256 "$ISOLATION_PATCH")" = "$ISOLATION_PATCH_SHA256" ] \
    || die "isolation patch SHA-256 mismatch"
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

unlock_build_input_snapshot() {
  "$PYTHON_BIN" - \
    "$BUILD_INPUT_SNAPSHOT_DIR" \
    "$BUILD_INPUT_SNAPSHOT_DEVICE" \
    "$BUILD_INPUT_SNAPSHOT_INODE" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = (int(sys.argv[2]), int(sys.argv[3]))
root_status = os.lstat(root)
if (
    not stat.S_ISDIR(root_status.st_mode)
    or (root_status.st_dev, root_status.st_ino) != expected
    or root_status.st_uid != os.getuid()
    or root_status.st_gid != os.getgid()
    or stat.S_IMODE(root_status.st_mode) != 0o500
):
    raise SystemExit("build-input snapshot root identity is invalid")

directories = [root]
for current, directory_names, file_names in os.walk(root, followlinks=False):
    directory_names.sort()
    file_names.sort()
    current_path = Path(current)
    for name in directory_names:
        path = current_path / name
        entry = os.lstat(path)
        if (
            not stat.S_ISDIR(entry.st_mode)
            or entry.st_uid != os.getuid()
            or entry.st_gid != os.getgid()
            or stat.S_IMODE(entry.st_mode) != 0o500
        ):
            raise SystemExit(f"build-input snapshot directory is invalid: {path}")
        directories.append(path)
    for name in file_names:
        path = current_path / name
        entry = os.lstat(path)
        if (
            not stat.S_ISREG(entry.st_mode)
            or entry.st_nlink != 1
            or entry.st_uid != os.getuid()
            or entry.st_gid != os.getgid()
            or stat.S_IMODE(entry.st_mode) != 0o400
        ):
            raise SystemExit(f"build-input snapshot file is invalid: {path}")

for directory in directories:
    os.chmod(directory, 0o700, follow_symlinks=False)
PY
}

cleanup_build_input_snapshot() {
  unlock_build_input_snapshot || return $?
  if [ "$PROMOTER_RUNTIME_READY" = "1" ]; then
    run_promoter \
      --remove-owned-tree \
      "$BUILD_INPUT_SNAPSHOT_DIR" \
      "$BUILD_INPUT_SNAPSHOT_DEVICE" \
      "$BUILD_INPUT_SNAPSHOT_INODE" \
      --allow-symlinks || return $?
  elif [ -n "$PROMOTER_SOURCE" ] && [ -f "$PROMOTER_SOURCE" ] && \
    [ ! -L "$PROMOTER_SOURCE" ]; then
    run_promoter_source_from_stdin \
      --remove-owned-tree \
      "$BUILD_INPUT_SNAPSHOT_DIR" \
      "$BUILD_INPUT_SNAPSHOT_DEVICE" \
      "$BUILD_INPUT_SNAPSHOT_INODE" \
      --allow-symlinks || return $?
  else
    return 1
  fi
  BUILD_INPUT_SNAPSHOT_OWNED=0
}

snapshot_build_inputs() {
  local identity
  if ! BUILD_INPUT_SNAPSHOT_DIR="$(
    mktemp -d "$BUILD_DIR/build-inputs.stage.XXXXXX"
  )"; then
    die "could not create private native build-input snapshot"
  fi
  if ! identity="$(
    "$PYTHON_BIN" - "$BUILD_INPUT_SNAPSHOT_DIR" \
      "$PROMOTER_SOURCE" "toolchain/atomic_swap_install.py" "" \
      "$OVERLAY" "native/msplat.cpp" "$OVERLAY_SHA256" \
      "$RASTER_TEST_SOURCE" "native/msplat_raster_tests.cpp" "$RASTER_TEST_SHA256" \
      "$ISOLATION_HEADER" "native/isolation.hpp" "$ISOLATION_HEADER_SHA256" \
      "$ISOLATION_SOURCE" "native/isolation.cpp" "$ISOLATION_SOURCE_SHA256" \
      "$ISOLATION_RUNTIME_HEADER" "native/isolation_runtime.hpp" "$ISOLATION_RUNTIME_HEADER_SHA256" \
      "$ISOLATION_RUNTIME_SOURCE" "native/isolation_runtime.cpp" "$ISOLATION_RUNTIME_SOURCE_SHA256" \
      "$ISOLATION_MASK_HEADER" "native/isolation_mask.hpp" "$ISOLATION_MASK_HEADER_SHA256" \
      "$ISOLATION_MASK_SOURCE" "native/isolation_mask.mm" "$ISOLATION_MASK_SOURCE_SHA256" \
      "$ISOLATION_METAL_SOURCE" "native/isolation_lift.metal" "$ISOLATION_METAL_SOURCE_SHA256" \
      "$ISOLATION_TEST_SOURCE" "native/isolation_tests.cpp" "$ISOLATION_TEST_SOURCE_SHA256" \
      "$ISOLATION_MASK_TEST_SOURCE" "native/isolation_mask_tests.mm" "$ISOLATION_MASK_TEST_SOURCE_SHA256" \
      "$FIXTURE_GENERATOR" "ci/generate_msplat_sparse_fixtures.py" "" \
      "$UPSTREAM_PATCH" "patches/msplat-1.1.3-easysplat.patch" "$UPSTREAM_PATCH_SHA256" \
      "$SOURCE_NOTICE_PATCH" "patches/msplat-1.1.3-source-notices.patch" "$SOURCE_NOTICE_PATCH_SHA256" \
      "$CHECKPOINT_PATCH" "patches/msplat-1.1.3-checkpoint.patch" "" \
      "$NUMERIC_STABILITY_PATCH" "patches/msplat-1.1.3-numeric-stability.patch" "$NUMERIC_STABILITY_PATCH_SHA256" \
      "$METAL_SAFETY_PATCH" "patches/msplat-1.1.3-metal-safety.patch" "$METAL_SAFETY_PATCH_SHA256" \
      "$EXACT_RASTER_PATCH" "patches/msplat-1.1.3-exact-raster.patch" "$EXACT_RASTER_PATCH_SHA256" \
      "$STAGE_TIMING_PATCH" "patches/msplat-1.1.3-stage-timing.patch" "$STAGE_TIMING_PATCH_SHA256" \
      "$MEMORY_EFFICIENCY_PATCH" "patches/msplat-1.1.3-memory-efficiency.patch" "$MEMORY_EFFICIENCY_PATCH_SHA256" \
      "$DENSIFICATION_MEMORY_PATCH" "patches/msplat-1.1.3-densification-memory.patch" "$DENSIFICATION_MEMORY_PATCH_SHA256" \
      "$ROW_SPAN_CULLING_PATCH" "patches/msplat-1.1.3-row-span-culling.patch" "$ROW_SPAN_CULLING_PATCH_SHA256" \
      "$GEOMETRY_ADAM_FUSION_PATCH" "patches/msplat-1.1.3-geometry-adam-fusion.patch" "$GEOMETRY_ADAM_FUSION_PATCH_SHA256" \
      "$PARALLEL_RADIX_SCAN_PATCH" "patches/msplat-1.1.3-parallel-radix-scan.patch" "$PARALLEL_RADIX_SCAN_PATCH_SHA256" \
      "$ALLOCATION_PRESSURE_PATCH" "patches/msplat-1.1.3-allocation-pressure.patch" "$ALLOCATION_PRESSURE_PATCH_SHA256" \
      "$EXACT_PREFIX_HARDENING_PATCH" "patches/msplat-1.1.3-exact-prefix-hardening.patch" "$EXACT_PREFIX_HARDENING_PATCH_SHA256" \
      "$QUATERNION_STABILITY_PATCH" "patches/msplat-1.1.3-quaternion-stability.patch" "$QUATERNION_STABILITY_PATCH_SHA256" \
      "$ISOLATION_PATCH" "patches/msplat-1.1.3-isolation.patch" "$ISOLATION_PATCH_SHA256" \
      "$TILE_SPAN_TEST_ROOT/include/tile_culling.hpp" "tile/include/tile_culling.hpp" "" \
      "$TILE_SPAN_TEST_ROOT/include/gpu_tile_culling.hpp" "tile/include/gpu_tile_culling.hpp" "" \
      "$TILE_SPAN_TEST_ROOT/src/tile_culling.metal" "tile/src/tile_culling.metal" "" \
      "$TILE_SPAN_TEST_ROOT/src/gpu_tile_culling.mm" "tile/src/gpu_tile_culling.mm" "" \
      "$TILE_SPAN_TEST_ROOT/tests/tile_culling_tests.cpp" "tile/tests/tile_culling_tests.cpp" "" \
      "$TILE_SPAN_TEST_ROOT/tests/gpu_tile_culling_tests.mm" "tile/tests/gpu_tile_culling_tests.mm" "" <<'PY'
import hashlib
import os
import shutil
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
arguments = sys.argv[2:]
if len(arguments) % 3:
    raise SystemExit("build-input snapshot manifest is malformed")


def stable(entry, opened):
    return (
        stat.S_ISREG(entry.st_mode)
        and stat.S_ISREG(opened.st_mode)
        and entry.st_nlink == 1
        and opened.st_nlink == 1
        and (entry.st_dev, entry.st_ino) == (opened.st_dev, opened.st_ino)
        and entry.st_size == opened.st_size
        and entry.st_mtime_ns == opened.st_mtime_ns
        and entry.st_ctime_ns == opened.st_ctime_ns
    )


try:
    root_status = os.lstat(root)
    if (
        not stat.S_ISDIR(root_status.st_mode)
        or root_status.st_uid != os.getuid()
        or root_status.st_gid != os.getgid()
        or stat.S_IMODE(root_status.st_mode) != 0o700
    ):
        raise RuntimeError("build-input snapshot root is not private")
    seen = set()
    for offset in range(0, len(arguments), 3):
        source = Path(arguments[offset])
        relative = Path(arguments[offset + 1])
        expected = arguments[offset + 2]
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix() in seen
        ):
            raise RuntimeError("build-input snapshot destination is unsafe")
        seen.add(relative.as_posix())
        before = os.lstat(source)
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        source_descriptor = os.open(source, flags)
        try:
            opened = os.fstat(source_descriptor)
            if not stable(before, opened):
                raise RuntimeError(f"build input changed while opening: {source}")
            destination = root / relative
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            output_descriptor = os.open(
                destination,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            digest = hashlib.sha256()
            consumed = 0
            try:
                while True:
                    block = os.read(source_descriptor, 1024 * 1024)
                    if not block:
                        break
                    digest.update(block)
                    consumed += len(block)
                    cursor = 0
                    while cursor < len(block):
                        cursor += os.write(output_descriptor, block[cursor:])
                os.fsync(output_descriptor)
                os.fchmod(output_descriptor, 0o400)
            finally:
                os.close(output_descriptor)
            after_open = os.fstat(source_descriptor)
            after_named = os.lstat(source)
            if (
                consumed != opened.st_size
                or not stable(opened, after_open)
                or not stable(opened, after_named)
            ):
                raise RuntimeError(f"build input changed while copying: {source}")
            if expected and digest.hexdigest() != expected:
                raise RuntimeError(f"snapshotted build-input digest mismatch: {source}")
        finally:
            os.close(source_descriptor)

    for current, directory_names, _ in os.walk(root, topdown=False):
        directory_names.sort()
        for name in directory_names:
            os.chmod(Path(current) / name, 0o500, follow_symlinks=False)
        os.chmod(current, 0o500, follow_symlinks=False)
    final_root = os.lstat(root)
    if (final_root.st_dev, final_root.st_ino) != (
        root_status.st_dev,
        root_status.st_ino,
    ):
        raise RuntimeError("build-input snapshot root changed")
    print(f"{final_root.st_dev}:{final_root.st_ino}")
except Exception:
    for current, directory_names, _ in os.walk(root, topdown=False):
        for name in directory_names:
            try:
                os.chmod(Path(current) / name, 0o700, follow_symlinks=False)
            except OSError:
                pass
        try:
            os.chmod(current, 0o700, follow_symlinks=False)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
    raise
PY
  )"; then
    BUILD_INPUT_SNAPSHOT_DIR=""
    die "could not create authenticated native build-input snapshot"
  fi
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
    die "native build-input snapshot identity is malformed"
  BUILD_INPUT_SNAPSHOT_DEVICE="${identity%%:*}"
  BUILD_INPUT_SNAPSHOT_INODE="${identity#*:}"
  BUILD_INPUT_SNAPSHOT_OWNED=1

  PROMOTER_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/toolchain/atomic_swap_install.py"
  OVERLAY="$BUILD_INPUT_SNAPSHOT_DIR/native/msplat.cpp"
  RASTER_TEST_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/msplat_raster_tests.cpp"
  ISOLATION_HEADER="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation.hpp"
  ISOLATION_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation.cpp"
  ISOLATION_RUNTIME_HEADER="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_runtime.hpp"
  ISOLATION_RUNTIME_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_runtime.cpp"
  ISOLATION_MASK_HEADER="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_mask.hpp"
  ISOLATION_MASK_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_mask.mm"
  ISOLATION_METAL_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_lift.metal"
  ISOLATION_TEST_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_tests.cpp"
  ISOLATION_MASK_TEST_SOURCE="$BUILD_INPUT_SNAPSHOT_DIR/native/isolation_mask_tests.mm"
  FIXTURE_GENERATOR="$BUILD_INPUT_SNAPSHOT_DIR/ci/generate_msplat_sparse_fixtures.py"
  UPSTREAM_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-easysplat.patch"
  SOURCE_NOTICE_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-source-notices.patch"
  CHECKPOINT_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-checkpoint.patch"
  NUMERIC_STABILITY_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-numeric-stability.patch"
  METAL_SAFETY_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-metal-safety.patch"
  EXACT_RASTER_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-exact-raster.patch"
  STAGE_TIMING_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-stage-timing.patch"
  MEMORY_EFFICIENCY_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-memory-efficiency.patch"
  DENSIFICATION_MEMORY_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-densification-memory.patch"
  ROW_SPAN_CULLING_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-row-span-culling.patch"
  GEOMETRY_ADAM_FUSION_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-geometry-adam-fusion.patch"
  PARALLEL_RADIX_SCAN_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-parallel-radix-scan.patch"
  ALLOCATION_PRESSURE_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-allocation-pressure.patch"
  EXACT_PREFIX_HARDENING_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-exact-prefix-hardening.patch"
  QUATERNION_STABILITY_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-quaternion-stability.patch"
  ISOLATION_PATCH="$BUILD_INPUT_SNAPSHOT_DIR/patches/msplat-1.1.3-isolation.patch"
  TILE_SPAN_TEST_ROOT="$BUILD_INPUT_SNAPSHOT_DIR/tile"
  BUILD_INPUT_SNAPSHOT_READY=1
}

revalidate_snapshotted_pins() {
  local source expected description
  while IFS='|' read -r source expected description; do
    [ "$(sha256 "$source")" = "$expected" ] || \
      die "snapshotted $description SHA-256 mismatch"
  done <<EOF
$OVERLAY|$OVERLAY_SHA256|CLI overlay
$RASTER_TEST_SOURCE|$RASTER_TEST_SHA256|raster test
$ISOLATION_HEADER|$ISOLATION_HEADER_SHA256|isolation header
$ISOLATION_SOURCE|$ISOLATION_SOURCE_SHA256|isolation source
$ISOLATION_RUNTIME_HEADER|$ISOLATION_RUNTIME_HEADER_SHA256|isolation runtime header
$ISOLATION_RUNTIME_SOURCE|$ISOLATION_RUNTIME_SOURCE_SHA256|isolation runtime source
$ISOLATION_MASK_HEADER|$ISOLATION_MASK_HEADER_SHA256|isolation mask header
$ISOLATION_MASK_SOURCE|$ISOLATION_MASK_SOURCE_SHA256|isolation mask source
$ISOLATION_METAL_SOURCE|$ISOLATION_METAL_SOURCE_SHA256|isolation Metal source
$ISOLATION_TEST_SOURCE|$ISOLATION_TEST_SOURCE_SHA256|isolation test source
$ISOLATION_MASK_TEST_SOURCE|$ISOLATION_MASK_TEST_SOURCE_SHA256|isolation mask test source
$UPSTREAM_PATCH|$UPSTREAM_PATCH_SHA256|upstream patch
$SOURCE_NOTICE_PATCH|$SOURCE_NOTICE_PATCH_SHA256|source notice patch
$NUMERIC_STABILITY_PATCH|$NUMERIC_STABILITY_PATCH_SHA256|numeric-stability patch
$METAL_SAFETY_PATCH|$METAL_SAFETY_PATCH_SHA256|Metal-safety patch
$EXACT_RASTER_PATCH|$EXACT_RASTER_PATCH_SHA256|exact-raster patch
$STAGE_TIMING_PATCH|$STAGE_TIMING_PATCH_SHA256|stage-timing patch
$MEMORY_EFFICIENCY_PATCH|$MEMORY_EFFICIENCY_PATCH_SHA256|memory-efficiency patch
$DENSIFICATION_MEMORY_PATCH|$DENSIFICATION_MEMORY_PATCH_SHA256|densification-memory patch
$ROW_SPAN_CULLING_PATCH|$ROW_SPAN_CULLING_PATCH_SHA256|row-span culling patch
$GEOMETRY_ADAM_FUSION_PATCH|$GEOMETRY_ADAM_FUSION_PATCH_SHA256|geometry-Adam patch
$PARALLEL_RADIX_SCAN_PATCH|$PARALLEL_RADIX_SCAN_PATCH_SHA256|parallel radix-scan patch
$ALLOCATION_PRESSURE_PATCH|$ALLOCATION_PRESSURE_PATCH_SHA256|allocation-pressure patch
$EXACT_PREFIX_HARDENING_PATCH|$EXACT_PREFIX_HARDENING_PATCH_SHA256|exact-prefix patch
$QUATERNION_STABILITY_PATCH|$QUATERNION_STABILITY_PATCH_SHA256|quaternion patch
$ISOLATION_PATCH|$ISOLATION_PATCH_SHA256|isolation patch
EOF
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
  cp "$ISOLATION_HEADER" "$SOURCE_DIR/cli/isolation.hpp"
  cp "$ISOLATION_SOURCE" "$SOURCE_DIR/cli/isolation.cpp"
  cp "$ISOLATION_RUNTIME_HEADER" "$SOURCE_DIR/cli/isolation_runtime.hpp"
  cp "$ISOLATION_RUNTIME_SOURCE" "$SOURCE_DIR/cli/isolation_runtime.cpp"
  cp "$ISOLATION_MASK_HEADER" "$SOURCE_DIR/cli/isolation_mask.hpp"
  cp "$ISOLATION_MASK_SOURCE" "$SOURCE_DIR/cli/isolation_mask.mm"
  cp "$ISOLATION_METAL_SOURCE" "$SOURCE_DIR/core/metal/isolation_lift.metal"
  cp "$ISOLATION_TEST_SOURCE" "$SOURCE_DIR/tests/isolation_tests.cpp"
  cp "$ISOLATION_MASK_TEST_SOURCE" "$SOURCE_DIR/tests/isolation_mask_tests.mm"
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
  git -C "$SOURCE_DIR" apply --check "$QUATERNION_STABILITY_PATCH"
  git -C "$SOURCE_DIR" apply "$QUATERNION_STABILITY_PATCH"
  git -C "$SOURCE_DIR" apply --check "$ISOLATION_PATCH"
  git -C "$SOURCE_DIR" apply "$ISOLATION_PATCH"
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
  cmake --build "$NATIVE_BUILD_DIR" --target msplat metallib msplat_raster_tests msplat_isolation_tests msplat_isolation_mask_tests
  "$NATIVE_BUILD_DIR/msplat_isolation_tests"
  "$NATIVE_BUILD_DIR/msplat_isolation_mask_tests"
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
  "$NATIVE_BUILD_DIR/msplat_raster_tests" --quaternion-vjp
}

write_build_info() {
  local executable_sha256="$1"
  local metallib_sha256="$2"
  local build_info compiler cmake_version ninja_version timestamp
  local overlay_sha256 raster_test_sha256
  local isolation_header_sha256 isolation_source_sha256
  local isolation_runtime_header_sha256 isolation_runtime_source_sha256
  local isolation_mask_header_sha256 isolation_mask_source_sha256
  local isolation_lift_source_sha256 isolation_test_sha256
  local isolation_mask_test_sha256 isolation_patch_sha256
  local patch_sha256 source_notice_patch_sha256 checkpoint_patch_sha256
  local numeric_stability_patch_sha256 metal_safety_patch_sha256
  local exact_raster_patch_sha256 stage_timing_patch_sha256
  local memory_efficiency_patch_sha256 densification_memory_patch_sha256
  local row_span_culling_patch_sha256 geometry_adam_fusion_patch_sha256
  local parallel_radix_scan_patch_sha256 allocation_pressure_patch_sha256
  local exact_prefix_hardening_patch_sha256 quaternion_stability_patch_sha256
  build_info="$STAGE_DIR/build_info.json"
  compiler="$(xcrun clang++ --version | head -n 1)"
  cmake_version="$(cmake --version | head -n 1)"
  ninja_version="$(ninja --version)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  overlay_sha256="$(sha256 "$OVERLAY")"
  raster_test_sha256="$(sha256 "$RASTER_TEST_SOURCE")"
  isolation_header_sha256="$(sha256 "$ISOLATION_HEADER")"
  isolation_source_sha256="$(sha256 "$ISOLATION_SOURCE")"
  isolation_runtime_header_sha256="$(sha256 "$ISOLATION_RUNTIME_HEADER")"
  isolation_runtime_source_sha256="$(sha256 "$ISOLATION_RUNTIME_SOURCE")"
  isolation_mask_header_sha256="$(sha256 "$ISOLATION_MASK_HEADER")"
  isolation_mask_source_sha256="$(sha256 "$ISOLATION_MASK_SOURCE")"
  isolation_lift_source_sha256="$(sha256 "$ISOLATION_METAL_SOURCE")"
  isolation_test_sha256="$(sha256 "$ISOLATION_TEST_SOURCE")"
  isolation_mask_test_sha256="$(sha256 "$ISOLATION_MASK_TEST_SOURCE")"
  isolation_patch_sha256="$(sha256 "$ISOLATION_PATCH")"
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
  quaternion_stability_patch_sha256="$(sha256 "$QUATERNION_STABILITY_PATCH")"

  "$PYTHON_BIN" - "$build_info" \
    "$MSPLAT_REPO" "$MSPLAT_COMMIT" "$MSPLAT_VERSION" "$SOURCE_TREE_SHA256" \
    "$overlay_sha256" "$raster_test_sha256" \
    "$isolation_header_sha256" "$isolation_source_sha256" \
    "$isolation_runtime_header_sha256" "$isolation_runtime_source_sha256" \
    "$isolation_mask_header_sha256" "$isolation_mask_source_sha256" \
    "$isolation_lift_source_sha256" "$isolation_test_sha256" \
    "$isolation_mask_test_sha256" "$isolation_patch_sha256" \
    "$patch_sha256" "$source_notice_patch_sha256" "$checkpoint_patch_sha256" \
    "$numeric_stability_patch_sha256" "$metal_safety_patch_sha256" \
    "$exact_raster_patch_sha256" "$stage_timing_patch_sha256" \
    "$memory_efficiency_patch_sha256" "$densification_memory_patch_sha256" \
    "$row_span_culling_patch_sha256" "$geometry_adam_fusion_patch_sha256" \
    "$parallel_radix_scan_patch_sha256" "$allocation_pressure_patch_sha256" \
    "$exact_prefix_hardening_patch_sha256" "$quaternion_stability_patch_sha256" \
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
    isolation_header_sha256,
    isolation_source_sha256,
    isolation_runtime_header_sha256,
    isolation_runtime_source_sha256,
    isolation_mask_header_sha256,
    isolation_mask_source_sha256,
    isolation_lift_source_sha256,
    isolation_test_sha256,
    isolation_mask_test_sha256,
    isolation_patch_sha256,
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
    quaternion_stability_patch_sha256,
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
    "isolation_header_sha256": isolation_header_sha256,
    "isolation_source_sha256": isolation_source_sha256,
    "isolation_runtime_header_sha256": isolation_runtime_header_sha256,
    "isolation_runtime_source_sha256": isolation_runtime_source_sha256,
    "isolation_mask_header_sha256": isolation_mask_header_sha256,
    "isolation_mask_source_sha256": isolation_mask_source_sha256,
    "isolation_lift_source_sha256": isolation_lift_source_sha256,
    "isolation_test_sha256": isolation_test_sha256,
    "isolation_mask_test_sha256": isolation_mask_test_sha256,
    "isolation_patch_sha256": isolation_patch_sha256,
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
    "quaternion_stability_patch_sha256": quaternion_stability_patch_sha256,
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
  grep -Fq '"isolation_mode_version":1' <<<"$self_check" \
    || die "subject-isolation self-check version missing"
  if ! "$PYTHON_BIN" - "$self_check" "$MSPLAT_VERSION" "${MSPLAT_COMMIT:0:7}" <<'PY'
import json
import sys


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


event = json.loads(
    sys.argv[1],
    object_pairs_hook=reject_duplicate_keys,
    parse_constant=reject_constant,
)
expected_self_check_keys = {
    "event",
    "isolation_mode_version",
    "scene_bounds_status",
    "schema_version",
    "sequence",
    "status",
    "version",
}
if type(event) is not dict or set(event) != expected_self_check_keys:
    raise SystemExit("self-check event schema is not closed")
for key in ("isolation_mode_version", "schema_version", "sequence"):
    if type(event.get(key)) is not int:
        raise SystemExit(f"self-check {key} must be an exact JSON integer")
expected = {
    "event": "self_check",
    "isolation_mode_version": 1,
    "scene_bounds_status": "ok",
    "schema_version": 2,
    "sequence": 1,
    "status": "ok",
    "version": f"{sys.argv[2]} (git {sys.argv[3]})",
}
if event != expected:
    raise SystemExit("self-check event values mismatch")
PY
  then
    die "self-check event failed strict validation"
  fi
}

promote_install() {
  local journal="$STAGE_DIR.promotion-state" tree_receipt
  validate_stage_extended_metadata
  tree_receipt="$(run_promoter --tree-receipt \
    "$STAGE_DIR" "$INSTALL_STAGE_DEVICE" "$INSTALL_STAGE_INODE")" || \
    die "could not bind the validated native msplat tree"
  validate_stage_extended_metadata
  STAGE_CLEANUP_ALLOWED=0
  run_promoter "$STAGE_DIR" "$INSTALL_DIR" "$tree_receipt" || \
    die "could not promote staged install; recovery state preserved"
  run_promoter --commit "$journal" || \
    die "could not finalize staged install; recovery state preserved"
}

preflight
acquire_build_lock
if [ -n "${EASYSPLAT_MSPLAT_BUILD_LOCK_PROBE_DIR:-}" ]; then
  run_build_lock_probe
  exit 0
fi
mkdir -p "$BUILD_DIR" "$INSTALL_PARENT"
snapshot_build_inputs
revalidate_snapshotted_pins
PROMOTER_RUNTIME_SOURCE_SHA256="$(sha256 "$PROMOTER_SOURCE")"
recover_stale_private_promoters
prepare_private_promoter
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
