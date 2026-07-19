#!/bin/bash

BOOTSTRAP_CMAKE_BIN="${EASYSPLAT_BOOTSTRAP_CMAKE:-}"
BOOTSTRAP_NINJA_BIN="${EASYSPLAT_BOOTSTRAP_NINJA:-}"
BOOTSTRAP_RG_BIN="${EASYSPLAT_BOOTSTRAP_RG:-}"
FROZEN_ROOT="${EASYSPLAT_FROZEN_ROOT:-}"
FROZEN_FREEZER_FD="${EASYSPLAT_FROZEN_FREEZER_FD:-}"
FROZEN_FREEZER_SHA256="${EASYSPLAT_FROZEN_FREEZER_SHA256:-}"
FROZEN_WRAPPER_FD="${EASYSPLAT_FROZEN_WRAPPER_FD:-}"
FROZEN_WRAPPER_SHA256="${EASYSPLAT_FROZEN_WRAPPER_SHA256:-}"
FROZEN_IMPLEMENTATION_FD="${EASYSPLAT_FROZEN_IMPLEMENTATION_FD:-}"
FROZEN_IMPLEMENTATION_SHA256="${EASYSPLAT_FROZEN_IMPLEMENTATION_SHA256:-}"
FROZEN_PROMOTER_FD="${EASYSPLAT_FROZEN_PROMOTER_FD:-}"
FROZEN_PROMOTER_SHA256="${EASYSPLAT_FROZEN_PROMOTER_SHA256:-}"

INHERITED_FUNCTIONS="$(builtin declare -F)"
if [ -n "$INHERITED_FUNCTIONS" ]; then
  builtin printf '%s\n' "Ceres build failed: implementation received inherited shell functions" >&2
  exit 1
fi
while IFS= read -r variable; do
  unset "$variable" 2>/dev/null || true
done < <(builtin compgen -e)
builtin unalias -a 2>/dev/null || true
builtin shopt -u expand_aliases
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

set -euo pipefail
umask 022

ROOT="$FROZEN_ROOT"
WORK="$ROOT/Toolchains/build/ceres"
DOWNLOADS="$WORK/downloads"
SOURCES="$WORK/sources"
BUILDS="$WORK/builds"
LOGS="$WORK/logs"
INSTALL="$WORK/install"
STAGE="$WORK/install.stage.$$"
SUPPORT="$ROOT/Toolchains/build/colmap-support/install"
LOCK="$ROOT/scripts/toolchain/ceres-lock.json"
EXTRACTOR="$ROOT/scripts/toolchain/safe_extract_source.py"
TESTS="$ROOT/scripts/toolchain/tests/test_ceres_builder.py"
BUILD_LOCK="$WORK/.build.lock"
BUILD_HOME="$WORK/home"
BUILD_TMP="$WORK/tmp"
DEPLOYMENT_TARGET="15.0"
NORMALIZED_MTIME_EPOCH="946684800"
LOCK_OWNED=0
INSTALL_STAGE_OWNED=0
INSTALL_STAGE_DEVICE=""
INSTALL_STAGE_INODE=""

AR_BIN=""
CLANG_BIN=""
CLANGXX_BIN=""
CMAKE_BIN=""
CURL_BIN="/usr/bin/curl"
LD_BIN=""
LIPO_BIN=""
LOCKF_BIN="/usr/bin/lockf"
NINJA_BIN=""
NM_BIN=""
OTOOL_BIN=""
PYTHON_BIN=""
RANLIB_BIN=""
RG_BIN=""
SHASUM_BIN="/usr/bin/shasum"
STRINGS_BIN=""
VTOOL_BIN=""
XATTR_BIN="/usr/bin/xattr"
XCODEBUILD_BIN=""
XCODE_DEVELOPER_DIR=""
XCODE_TOOLCHAIN_BIN=""
XCRUN_BIN="/usr/bin/xcrun"
MACOS_SDK=""
MACOS_SDK_VERSION=""
COMMON_C_FLAGS=""
COMMON_CXX_FLAGS=""
COMMON_LINK_FLAGS=""
PREPARED_SOURCE=""
PIN_URL=""
PIN_SHA256=""

die() {
  echo "Ceres build failed: $*" >&2
  exit 1
}

sha256() {
  "$SHASUM_BIN" -a 256 "$1" | /usr/bin/awk '{print $1}'
}

validate_frozen_control_inputs() {
  /usr/bin/python3 - \
    "$FROZEN_FREEZER_FD" "$FROZEN_FREEZER_SHA256" \
    "$FROZEN_WRAPPER_FD" "$FROZEN_WRAPPER_SHA256" \
    "$FROZEN_IMPLEMENTATION_FD" "$FROZEN_IMPLEMENTATION_SHA256" \
    "$FROZEN_PROMOTER_FD" "$FROZEN_PROMOTER_SHA256" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

arguments = sys.argv[1:]
if len(arguments) != 8:
    raise SystemExit("frozen control descriptor arguments are incomplete")
for label, offset in (
    ("control freezer", 0),
    ("wrapper", 2),
    ("implementation", 4),
    ("promoter", 6),
):
    try:
        descriptor = int(arguments[offset])
    except ValueError as error:
        raise SystemExit(f"invalid frozen {label} descriptor") from error
    expected = arguments[offset + 1]
    if descriptor < 100:
        raise SystemExit(f"unsafe frozen {label} descriptor number")
    if len(expected) != 64 or any(character not in "0123456789abcdef" for character in expected):
        raise SystemExit(f"invalid frozen {label} digest")
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
        or metadata.st_size <= 0
        or stat.S_IMODE(metadata.st_mode) != 0o400
        or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDONLY
    ):
        raise SystemExit(f"unsafe frozen {label} descriptor")
    payload = b"".join(
        os.pread(descriptor, min(1024 * 1024, metadata.st_size - offset), offset)
        for offset in range(0, metadata.st_size, 1024 * 1024)
    )
    if len(payload) != metadata.st_size or hashlib.sha256(payload).hexdigest() != expected:
        raise SystemExit(f"frozen {label} payload digest mismatch")
PY
}

run_promoter() {
  /usr/bin/python3 -I -S - "$FROZEN_PROMOTER_FD" "$FROZEN_PROMOTER_SHA256" "$@" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected = sys.argv[2]
arguments = sys.argv[3:]
metadata = os.fstat(descriptor)
if (
    descriptor < 100
    or not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 0
    or metadata.st_uid != os.getuid()
    or metadata.st_gid != os.getgid()
    or metadata.st_size <= 0
    or stat.S_IMODE(metadata.st_mode) != 0o400
    or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDONLY
):
    raise SystemExit("unsafe frozen promoter descriptor")
payload = b"".join(
    os.pread(descriptor, min(1024 * 1024, metadata.st_size - offset), offset)
    for offset in range(0, metadata.st_size, 1024 * 1024)
)
if len(payload) != metadata.st_size or hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit("frozen promoter payload digest mismatch")
script = f"/dev/fd/{descriptor}"
sys.argv = [script, *arguments]
namespace = {
    "__name__": "__main__",
    "__file__": script,
    "__package__": None,
    "__cached__": None,
}
exec(compile(payload, script, "exec"), namespace)
PY
}

resolve_xcode_tool() {
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCRUN_BIN" --find "$1"
}

STAGE_CLEANUP_ALLOWED=1

cleanup() {
  local status=$?
  local install_cleanup_status=0
  trap - EXIT
  if [ "$STAGE_CLEANUP_ALLOWED" = "1" ] && [ "$INSTALL_STAGE_OWNED" = "1" ]; then
    if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
      run_promoter \
        --remove-owned-tree \
        "$STAGE" \
        "$INSTALL_STAGE_DEVICE" \
        "$INSTALL_STAGE_INODE" \
        --allow-symlinks || install_cleanup_status=$?
    else
      install_cleanup_status=1
    fi
    if [ "$install_cleanup_status" -ne 0 ]; then
      printf '%s\n' \
        "Ceres build cleanup preserved an unverified staged install: $STAGE" >&2
    fi
  fi
  if [ "$LOCK_OWNED" = "1" ]; then
    exec 9>&-
  fi
  if [ "$status" -eq 0 ] && [ "$install_cleanup_status" -ne 0 ]; then
    status="$install_cleanup_status"
  fi
  exit "$status"
}

create_owned_install_stage() {
  local identity
  identity="$(
    run_promoter --create-owned-tree "$STAGE"
  )" || die "could not create and bind Ceres install stage"
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
    die "Ceres install stage identity is malformed"
  INSTALL_STAGE_DEVICE="${identity%%:*}"
  INSTALL_STAGE_INODE="${identity#*:}"
  INSTALL_STAGE_OWNED=1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_build_lock() {
  /usr/bin/python3 - "$WORK" "$BUILD_LOCK" 9 <<'PY'
import fcntl
import os
import stat
import sys

work, path, descriptor_raw = sys.argv[1:]
descriptor = int(descriptor_raw)
name = os.path.basename(path)


def reject() -> None:
    raise SystemExit("unsafe build lock")


if not name or name in {".", ".."} or os.path.dirname(path) != work:
    reject()
directory = -1
named_descriptor = -1
try:
    directory = os.open(
        work,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
    )
    directory_status = os.fstat(directory)
    work_status = os.stat(work, follow_symlinks=False)
    if (
        not stat.S_ISDIR(directory_status.st_mode)
        or directory_status.st_uid != os.getuid()
        or directory_status.st_gid != os.getgid()
        or (directory_status.st_dev, directory_status.st_ino)
        != (work_status.st_dev, work_status.st_ino)
    ):
        reject()
    named_descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=directory,
    )
    opened = os.fstat(descriptor)
    named_opened = os.fstat(named_descriptor)
    named = os.stat(name, dir_fd=directory, follow_symlinks=False)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or opened.st_uid != os.getuid()
        or opened.st_gid != os.getgid()
        or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDWR
        or (opened.st_dev, opened.st_ino)
        != (named_opened.st_dev, named_opened.st_ino)
        or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
    ):
        reject()
    os.fchmod(descriptor, 0o600)
    opened_after = os.fstat(descriptor)
    named_after = os.stat(name, dir_fd=directory, follow_symlinks=False)
    directory_after = os.fstat(directory)
    work_after = os.stat(work, follow_symlinks=False)
    if (
        (opened.st_dev, opened.st_ino)
        != (opened_after.st_dev, opened_after.st_ino)
        or (opened.st_dev, opened.st_ino)
        != (named_after.st_dev, named_after.st_ino)
        or opened_after.st_nlink != 1
        or stat.S_IMODE(opened_after.st_mode) != 0o600
        or (directory_status.st_dev, directory_status.st_ino)
        != (directory_after.st_dev, directory_after.st_ino)
        or (directory_status.st_dev, directory_status.st_ino)
        != (work_after.st_dev, work_after.st_ino)
    ):
        reject()
except OSError:
    reject()
finally:
    if named_descriptor >= 0:
        os.close(named_descriptor)
    if directory >= 0:
        os.close(directory)
PY
}

acquire_build_lock() {
  mkdir -p "$WORK"
  exec 9<>"$BUILD_LOCK"
  validate_build_lock || die "Ceres build lock is unsafe"
  "$LOCKF_BIN" -s -t 0 9 || die "another Ceres build is running"
  LOCK_OWNED=1
  validate_build_lock || die "Ceres build lock changed during acquisition"
}

recover_stale_promotions() {
  local journal path
  for journal in "$WORK"/install.stage.*.promotion-state; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    run_promoter --recover "$journal" || \
      die "could not recover interrupted Ceres promotion: $journal"
  done
  for path in "$WORK"/install.stage.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    case "$path" in
      *.promotion-state) continue ;;
    esac
    die "ambiguous staged install requires recovery: $path"
  done
}

preflight() {
  [ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64"
  [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || \
    die "Rosetta is unsupported"
  case "$ROOT" in
    *[[:space:]]*) die "checkout path contains whitespace; move the source checkout before building" ;;
  esac
  [ -s "$LOCK" ] || die "ceres-lock.json is missing"
  [ -x "$EXTRACTOR" ] || die "safe source extractor is missing or not executable"
  [ -f "$TESTS" ] || die "Ceres artifact tests are missing"
  [ -d "$SUPPORT" ] && [ ! -L "$SUPPORT" ] || die "promoted COLMAP support prefix is missing"
  [ -s "$SUPPORT/build_info.json" ] || die "COLMAP support receipt is missing"
  for command in \
    /usr/bin/curl /usr/bin/lockf /usr/bin/shasum /usr/bin/xattr \
    /usr/bin/xcode-select /usr/bin/xcrun; do
    [ -x "$command" ] || die "required system tool is missing: $command"
  done

  CMAKE_BIN="$BOOTSTRAP_CMAKE_BIN"
  NINJA_BIN="$BOOTSTRAP_NINJA_BIN"
  RG_BIN="$BOOTSTRAP_RG_BIN"
  for command in "$CMAKE_BIN" "$NINJA_BIN" "$RG_BIN"; do
    [ -x "$command" ] || die "required build tool is missing: $command"
  done
  XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  [ -d "$XCODE_DEVELOPER_DIR" ] || die "the selected Xcode Developer directory is missing"
  AR_BIN="$(resolve_xcode_tool ar)"
  CLANG_BIN="$(resolve_xcode_tool clang)"
  CLANGXX_BIN="$(resolve_xcode_tool clang++)"
  LD_BIN="$(resolve_xcode_tool ld)"
  LIPO_BIN="$(resolve_xcode_tool lipo)"
  NM_BIN="$(resolve_xcode_tool nm)"
  OTOOL_BIN="$(resolve_xcode_tool otool)"
  PYTHON_BIN="$(resolve_xcode_tool python3)"
  RANLIB_BIN="$(resolve_xcode_tool ranlib)"
  STRINGS_BIN="$(resolve_xcode_tool strings)"
  VTOOL_BIN="$(resolve_xcode_tool vtool)"
  XCODEBUILD_BIN="$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild"
  XCODE_TOOLCHAIN_BIN="$(dirname "$CLANG_BIN")"
  MACOS_SDK="$(DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCRUN_BIN" --sdk macosx --show-sdk-path)"
  MACOS_SDK_VERSION="$(DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCRUN_BIN" --sdk macosx --show-sdk-version)"
  case "$XCODE_DEVELOPER_DIR:$MACOS_SDK" in
    *[[:space:]]*) die "selected Xcode paths contain whitespace and are unsupported" ;;
  esac
  [ -d "$MACOS_SDK" ] || die "the selected macOS SDK is missing: $MACOS_SDK"
  [ -f "$MACOS_SDK/SDKSettings.json" ] || die "the selected macOS SDK has no SDKSettings.json"
  for command in \
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$LD_BIN" "$LIPO_BIN" "$NM_BIN" \
    "$OTOOL_BIN" "$PYTHON_BIN" "$RANLIB_BIN" "$STRINGS_BIN" "$VTOOL_BIN" \
    "$XCODEBUILD_BIN"; do
    [ -x "$command" ] || die "selected Xcode tool is missing: $command"
  done
}

sanitize_environment() {
  local path_value="$XCODE_TOOLCHAIN_BIN:$XCODE_DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local tool directory variable
  for tool in "$CMAKE_BIN" "$NINJA_BIN" "$RG_BIN"; do
    directory="$(/usr/bin/dirname "$tool")"
    case ":$path_value:" in
      *":$directory:"*) ;;
      *) path_value="$path_value:$directory" ;;
    esac
  done
  while IFS= read -r variable; do
    unset "$variable" 2>/dev/null || true
  done < <(compgen -e)
  export PATH="$path_value"
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
  export HOME="$BUILD_HOME"
  export TMPDIR="$BUILD_TMP"
  export LC_ALL=C
  export LANG=C
  export TZ=UTC
  export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  export ZERO_AR_DATE=1
  export SOURCE_DATE_EPOCH=0
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_LIBDIR="/dev/null"

  COMMON_C_FLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $MACOS_SDK -ffile-prefix-map=$ROOT=/easysplat-source -fdebug-prefix-map=$ROOT=/easysplat-source -ffile-prefix-map=$SUPPORT=/easysplat-support -fdebug-prefix-map=$SUPPORT=/easysplat-support"
  COMMON_CXX_FLAGS="$COMMON_C_FLAGS -DEIGEN_MPL2_ONLY"
  COMMON_LINK_FLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $MACOS_SDK"
}

load_pin() {
  local name="$1"
  local values
  values="$("$PYTHON_BIN" - "$LOCK" "$name" <<'PY'
import json
import re
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if lock.get("schemaVersion") != 1:
    raise SystemExit("unsupported ceres-lock.json schema")
try:
    entry = lock["dependencies"][sys.argv[2]]
    values = (entry["version"], entry["commit"], entry["source"]["url"], entry["source"]["sha256"], entry["license"])
except (KeyError, TypeError) as error:
    raise SystemExit(f"incomplete source lock entry: {error}") from error
if not all(isinstance(value, str) and value for value in values):
    raise SystemExit("invalid source lock value")
version, commit, url, digest, license_name = values
if not url.startswith("https://"):
    raise SystemExit("source URL must use HTTPS")
if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit("invalid source commit")
if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("invalid source SHA-256")
if any("\t" in value or "\n" in value for value in values):
    raise SystemExit("unsafe source lock value")
print("\t".join(values))
PY
)" || die "could not load reviewed source pin: $name"
  IFS=$'\t' read -r _ _ PIN_URL PIN_SHA256 _ <<<"$values"
}

download_verified() {
  local name="$1"
  local destination="$DOWNLOADS/$name.archive"
  local temporary="$destination.tmp.$$"
  load_pin "$name"
  if [ -f "$destination" ] && [ "$(sha256 "$destination")" = "$PIN_SHA256" ]; then
    return
  fi
  rm -f "$destination" "$temporary"
  "$CURL_BIN" --proto '=https' --tlsv1.2 --fail --location \
    --retry 3 --retry-delay 2 --output "$temporary" "$PIN_URL"
  if [ "$(sha256 "$temporary")" != "$PIN_SHA256" ]; then
    rm -f "$temporary"
    die "source archive SHA-256 mismatch: $name"
  fi
  mv "$temporary" "$destination"
}

prepare_source() {
  local name="$1"
  local archive="$DOWNLOADS/$name.archive"
  local destination="$SOURCES/$name"
  local temporary="$destination.extract.$$"
  local extracted_root
  download_verified "$name"
  rm -rf "$temporary"
  mkdir -p "$temporary"
  if ! extracted_root="$("$PYTHON_BIN" "$EXTRACTOR" "$archive" "$temporary")"; then
    rm -rf "$temporary"
    die "safe source extraction failed: $name"
  fi
  [ -d "$extracted_root" ] && [ ! -L "$extracted_root" ] || \
    die "source archive root is invalid: $name"
  rm -rf "$destination"
  mv "$extracted_root" "$destination"
  rm -rf "$temporary"
  if find "$destination" -type l -exec test ! -e {} \; -print | /usr/bin/grep -q .; then
    die "source archive contains a dangling symlink: $name"
  fi
  PREPARED_SOURCE="$destination"
}

verify_support_prefix() {
  "$PYTHON_BIN" - "$SUPPORT" <<'PY'
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
receipt_path = root / "build_info.json"
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
if receipt.get("toolchain_name") != "colmap-support":
    raise SystemExit("unexpected COLMAP support receipt")
if receipt.get("architecture") != "arm64" or receipt.get("deployment_target") != "macOS 15.0":
    raise SystemExit("COLMAP support platform is incompatible")
digest = hashlib.sha256()
paths = [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())]
for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    metadata = path.lstat()
    if (metadata.st_uid, metadata.st_gid) != (os.getuid(), os.getgid()):
        raise SystemExit(f"noncanonical COLMAP support ownership: {path}")
    if relative == "build_info.json":
        continue
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISDIR(metadata.st_mode):
        kind, content = "directory", ""
    elif stat.S_ISREG(metadata.st_mode):
        kind, content = "file", hashlib.sha256(path.read_bytes()).hexdigest()
    else:
        raise SystemExit(f"unsupported COLMAP support entry: {relative}")
    for value in (relative, kind, f"{mode:o}", str(metadata.st_mtime_ns), content):
        digest.update(value.encode())
        digest.update(b"\0")
if digest.hexdigest() != receipt.get("install_tree_sha256"):
    raise SystemExit("COLMAP support tree does not match its receipt")
if receipt.get("ownership_policy") != "invoking-build-user-and-primary-group":
    raise SystemExit("COLMAP support ownership policy is incompatible")
if "normalized_owner_uid" in receipt or "normalized_owner_gid" in receipt:
    raise SystemExit("COLMAP support receipt contains host-specific numeric ownership")
for name in ("lib/libgflags.a", "lib/libglog.a"):
    path = root / name
    expected = receipt.get("library_sha256", {}).get(name)
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"COLMAP support library does not match receipt: {name}")
PY
}

cmake_common() {
  local source="$1"
  local build="$2"
  shift 2
  "$CMAKE_BIN" -S "$source" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK" \
    -DCMAKE_C_COMPILER="$CLANG_BIN" \
    -DCMAKE_CXX_COMPILER="$CLANGXX_BIN" \
    -DCMAKE_AR="$AR_BIN" \
    -DCMAKE_RANLIB="$RANLIB_BIN" \
    -DCMAKE_LINKER="$LD_BIN" \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_C_FLAGS="$COMMON_C_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_PREFIX_PATH="$STAGE;$SUPPORT" \
    '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF \
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DPython3_EXECUTABLE="$PYTHON_BIN" \
    "$@"
}

build_eigen() {
  prepare_source eigen
  local source="$PREPARED_SOURCE"
  local build="$BUILDS/eigen"
  local log="$LOGS/eigen.log"
  rm -rf "$build"
  cmake_common "$source" "$build" \
    -DBUILD_TESTING=OFF \
    -DEIGEN_BUILD_DOC=OFF \
    -DEIGEN_BUILD_PKGCONFIG=OFF \
    -DCMAKE_Fortran_COMPILER=NOTFOUND 2>&1 | /usr/bin/tee "$log"
  "$RG_BIN" -n '^CMAKE_Fortran_COMPILER:[^=]+=NOTFOUND$' "$build/CMakeCache.txt" >/dev/null || \
    die "unpinned Fortran compiler entered the Eigen configure"
  "$CMAKE_BIN" --build "$build" --target install \
    --parallel "$(sysctl -n hw.ncpu)" 2>&1 | /usr/bin/tee -a "$log"
}

cache_is() {
  local cache="$1"
  local name="$2"
  local expected="$3"
  "$RG_BIN" -n "^${name}:[^=]+=${expected}$" "$cache" >/dev/null || \
    die "CMake did not preserve ${name}=${expected}"
}

build_ceres() {
  prepare_source ceres
  local source="$PREPARED_SOURCE"
  local build="$BUILDS/ceres"
  local log="$LOGS/ceres.log"
  rm -rf "$build"
  cmake_common "$source" "$build" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DSUITESPARSE=OFF \
    -DACCELERATESPARSE=ON \
    -DEIGENSPARSE=ON \
    -DEIGENMETIS=OFF \
    -DUSE_CUDA=OFF \
    -DMINIGLOG=OFF \
    -DGFLAGS=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DEigen3_DIR="$STAGE/share/eigen3/cmake" \
    -Dgflags_DIR="$SUPPORT/lib/cmake/gflags" \
    -Dglog_DIR="$SUPPORT/lib/cmake/glog" 2>&1 | /usr/bin/tee "$log"
  local cache="$build/CMakeCache.txt"
  cache_is "$cache" BUILD_SHARED_LIBS OFF
  cache_is "$cache" BUILD_TESTING OFF
  cache_is "$cache" BUILD_EXAMPLES OFF
  cache_is "$cache" BUILD_BENCHMARKS OFF
  cache_is "$cache" BUILD_DOCUMENTATION OFF
  cache_is "$cache" SUITESPARSE OFF
  cache_is "$cache" ACCELERATESPARSE ON
  cache_is "$cache" EIGENSPARSE ON
  cache_is "$cache" EIGENMETIS OFF
  cache_is "$cache" USE_CUDA OFF
  cache_is "$cache" MINIGLOG OFF
  cache_is "$cache" GFLAGS ON
  "$CMAKE_BIN" --build "$build" --target install \
    --parallel "$(sysctl -n hw.ncpu)" 2>&1 | /usr/bin/tee -a "$log"
}

audit_compile_commands() {
  local file
  while IFS= read -r file; do
    "$PYTHON_BIN" - "$file" "$MACOS_SDK" "$ROOT" "$SUPPORT" "$CLANG_BIN" "$CLANGXX_BIN" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
sdk, root, support = sys.argv[2:5]
compilers = {Path(raw).resolve() for raw in sys.argv[5:]}
entries = json.loads(path.read_text(encoding="utf-8"))
for entry in entries:
    tokens = entry.get("arguments") or shlex.split(entry.get("command", ""))
    if not tokens:
        raise SystemExit("empty compile command entered the build")
    compiler = Path(tokens[0]).resolve()
    if compiler not in compilers:
        raise SystemExit(f"unpinned Fortran compiler entered the Eigen configure: {tokens[:1]}")
    joined = "\0".join(tokens)
    if "/opt/homebrew/" in joined or "/usr/local/" in joined:
        raise SystemExit("Homebrew dependency entered the build")
    if any(re.fullmatch(r"-(?:mcpu|march)=native", token) for token in tokens):
        raise SystemExit("host-specific compiler tuning entered the build")
    if "-isysroot" not in tokens or tokens[tokens.index("-isysroot") + 1] != sdk:
        raise SystemExit("pinned macOS SDK is absent from compile command")
    for mapping in (f"-ffile-prefix-map={root}=/easysplat-source", f"-fdebug-prefix-map={root}=/easysplat-source", f"-ffile-prefix-map={support}=/easysplat-support", f"-fdebug-prefix-map={support}=/easysplat-support"):
        if mapping not in tokens:
            raise SystemExit(f"prefix map is absent from compile command: {mapping}")
    if compiler.name in {"clang++", "clang++-17"} and "-DEIGEN_MPL2_ONLY" not in tokens:
        raise SystemExit("Eigen MPL2-only compile guard is absent")
PY
  done < <(find "$BUILDS" -type f -name compile_commands.json -print | LC_ALL=C sort)
  if "$RG_BIN" -a -n -g build.ninja -g compile_commands.json -g CMakeCache.txt -g '*.log' \
    -- '/opt/homebrew/(opt|Cellar|include|lib)/|/usr/local/(opt|Cellar|include|lib)/|-(mcpu|march)(=|[[:space:]]+)native' \
    "$BUILDS" "$LOGS" >/dev/null; then
    die "Homebrew dependency or host-native tuning entered the build"
  fi
  local ceres_commands="$BUILDS/ceres/compile_commands.json"
  if "$RG_BIN" -a -n '/miniglog/' "$ceres_commands" >/dev/null; then
    die "miniglog source entered the Ceres build"
  fi
  if ! "$RG_BIN" -a -F "$SUPPORT/include" "$ceres_commands" >/dev/null || \
    ! "$RG_BIN" -a -F -- '-DGLOG_USE_GFLAGS' "$ceres_commands" >/dev/null; then
    die "static glog/gflags support did not enter the Ceres build"
  fi
}

trim_install() {
  rm -rf \
    "${STAGE:?}/bin" "$STAGE/share/doc" "$STAGE/share/man" "$STAGE/lib/pkgconfig" \
    "$STAGE/include/eigen3/unsupported" \
    "$STAGE/include/eigen3/Eigen/CholmodSupport" \
    "$STAGE/include/eigen3/Eigen/MetisSupport" \
    "$STAGE/include/eigen3/Eigen/PardisoSupport" \
    "$STAGE/include/eigen3/Eigen/PaStiXSupport" \
    "$STAGE/include/eigen3/Eigen/SPQRSupport" \
    "$STAGE/include/eigen3/Eigen/SuperLUSupport" \
    "$STAGE/include/eigen3/Eigen/UmfPackSupport" \
    "$STAGE/include/eigen3/Eigen/src/CholmodSupport" \
    "$STAGE/include/eigen3/Eigen/src/MetisSupport" \
    "$STAGE/include/eigen3/Eigen/src/PardisoSupport" \
    "$STAGE/include/eigen3/Eigen/src/PaStiXSupport" \
    "$STAGE/include/eigen3/Eigen/src/SPQRSupport" \
    "$STAGE/include/eigen3/Eigen/src/SuperLUSupport" \
    "$STAGE/include/eigen3/Eigen/src/UmfPackSupport"
  find "$STAGE" -type d -empty -delete
}

prune_disabled_backend_objects() {
  local archive="$STAGE/lib/libceres.a"
  local members=(
    cuda_block_sparse_crs_view.cc.o
    cuda_partitioned_block_sparse_crs_view.cc.o
    cuda_block_structure.cc.o
    cuda_sparse_matrix.cc.o
    cuda_vector.cc.o
    float_suitesparse.cc.o
    suitesparse.cc.o
  )
  local member
  for member in "${members[@]}"; do
    "$AR_BIN" -t "$archive" | /usr/bin/grep -Fx "$member" >/dev/null || \
      die "expected disabled-backend stub object is missing: $member"
  done
  "$AR_BIN" -d "$archive" "${members[@]}"
  "$RANLIB_BIN" "$archive"
  if "$AR_BIN" -t "$archive" | "$RG_BIN" -i 'cuda|suitesparse|suite_sparse|cholmod|metis' >/dev/null; then
    die "optional CUDA or SuiteSparse archive member survived"
  fi
}

stage_licenses() {
  mkdir -p "$STAGE/licenses/Ceres" "$STAGE/licenses/Eigen"
  install -m 0644 "$SOURCES/ceres/LICENSE" "$STAGE/licenses/Ceres/LICENSE"
  local name
  for name in COPYING.APACHE COPYING.BSD COPYING.GPL COPYING.LGPL COPYING.MINPACK COPYING.MPL2 COPYING.README; do
    install -m 0644 "$SOURCES/eigen/$name" "$STAGE/licenses/Eigen/$name"
  done
}

normalize_metadata() {
  local root="$1"
  "$PYTHON_BIN" - "$root" "$NORMALIZED_MTIME_EPOCH" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
epoch_ns = int(sys.argv[2]) * 1_000_000_000
uid, gid = os.getuid(), os.getgid()
paths = sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
for path in paths:
    metadata = path.lstat()
    if stat.S_ISREG(metadata.st_mode):
        os.chown(path, uid, gid, follow_symlinks=False)
        os.chmod(path, 0o644, follow_symlinks=False)
        os.utime(path, ns=(epoch_ns, epoch_ns), follow_symlinks=False)
    elif not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(f"unsupported install entry: {path}")
for path in sorted((item for item in paths if item.is_dir()), key=lambda item: len(item.parts), reverse=True):
    os.chown(path, uid, gid, follow_symlinks=False)
    os.chmod(path, 0o755, follow_symlinks=False)
    os.utime(path, ns=(epoch_ns, epoch_ns), follow_symlinks=False)
os.chown(root, uid, gid, follow_symlinks=False)
os.chmod(root, 0o755, follow_symlinks=False)
os.utime(root, ns=(epoch_ns, epoch_ns), follow_symlinks=False)
PY
  "$XATTR_BIN" -c -r "$root"
}

validate_static_archive() {
  local archive="$1"
  [ "$("$LIPO_BIN" -archs "$archive")" = "arm64" ] || \
    die "static archive is not thin arm64: $archive"
  "$PYTHON_BIN" - "$archive" "$AR_BIN" "$LIPO_BIN" "$VTOOL_BIN" "$DEPLOYMENT_TARGET" "$WORK" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

archive = Path(sys.argv[1])
ar, lipo, vtool, target, work = sys.argv[2:]
members = subprocess.run([ar, "-t", str(archive)], check=True, capture_output=True, text=True).stdout.splitlines()
objects = [member for member in members if not member.startswith("__.SYMDEF")]
if not objects:
    raise SystemExit("Ceres archive has no objects")
if len(objects) != len(set(objects)):
    raise SystemExit("duplicate archive member in libceres.a")

data = archive.read_bytes()
if not data.startswith(b"!<arch>\n"):
    raise SystemExit("invalid static archive header")
offset = 8
while offset < len(data):
    header = data[offset : offset + 60]
    if len(header) != 60 or header[58:60] != b"`\n":
        raise SystemExit("invalid static archive member header")
    timestamp = int(header[16:28].decode().strip() or "0")
    owner = int(header[28:34].decode().strip() or "0")
    group = int(header[34:40].decode().strip() or "0")
    mode = header[40:48].decode().strip()
    size = int(header[48:58].decode().strip())
    raw_name = header[:16].decode().strip()
    name = raw_name
    if raw_name.startswith("#1/"):
        name_size = int(raw_name[3:])
        name = data[offset + 60 : offset + 60 + name_size].rstrip(b"\0").decode("utf-8", errors="replace")
    expected_mode = "100644" if name.startswith("__.SYMDEF") else "644"
    if (timestamp, owner, group) != (0, 0, 0) or mode != expected_mode:
        raise SystemExit("archive member metadata is not deterministic")
    offset += 60 + size + (size % 2)
if offset != len(data):
    raise SystemExit("invalid static archive size")

PY
  # otool reports every object in a static archive, so the object and load-command
  # counts must agree. This avoids extracting untrusted member names to disk.
  local metadata="$LOGS/libceres.otool"
  "$OTOOL_BIN" -l "$archive" >"$metadata"
  "$PYTHON_BIN" - "$archive" "$metadata" "$AR_BIN" "$DEPLOYMENT_TARGET" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

archive, metadata, ar, target = sys.argv[1:]
objects = [name for name in subprocess.run([ar, "-t", archive], check=True, capture_output=True, text=True).stdout.splitlines() if not name.startswith("__.SYMDEF")]
text = Path(metadata).read_text(encoding="utf-8")
platforms = re.findall(r"^\s*platform\s+([^\s]+)$", text, re.MULTILINE)
versions = re.findall(r"^\s*minos\s+([0-9.]+)$", text, re.MULTILINE)
if len(platforms) != len(objects) or len(versions) != len(objects):
    raise SystemExit("incomplete Mach-O metadata in libceres.a")
if set(platforms) not in ({"1"}, {"MACOS"}):
    raise SystemExit("libceres contains a non-macOS object")
limit = tuple(int(part) for part in target.split("."))
if any(tuple(int(part) for part in version.split(".")) > limit for version in versions):
    raise SystemExit("libceres object requires macOS newer than macOS 15.0")
PY
  local symbols="$LOGS/libceres.symbols"
  "$NM_BIN" -gU "$archive" >"$symbols"
  "$RG_BIN" -i 'ceres.*solve|solve.*ceres' "$symbols" >/dev/null || \
    die "expected Ceres symbols are missing"
  "$NM_BIN" -u "$archive" >"$LOGS/libceres.undefined-symbols"
  if "$RG_BIN" -i ' U .*cholmod| U .*suitesparse| U .*suite_sparse| U .*cuda| U .*cusolver| U .*metis' \
    "$LOGS/libceres.undefined-symbols" >/dev/null; then
    die "forbidden Ceres symbol entered libceres.a"
  fi
}

validate_install_tree() {
  local root="$1"
  [ -d "$root" ] && [ ! -L "$root" ] || die "Ceres install is not a regular directory"
  [ -s "$root/lib/libceres.a" ] || die "lib/libceres.a is missing"
  [ -s "$root/include/ceres/ceres.h" ] || die "Ceres headers are missing"
  [ -s "$root/include/ceres/internal/config.h" ] || die "Ceres configuration header is missing"
  [ -s "$root/lib/cmake/Ceres/CeresConfig.cmake" ] || die "CeresConfig.cmake is missing"
  [ -s "$root/share/eigen3/cmake/Eigen3Config.cmake" ] || die "Eigen3Config.cmake is missing"
  [ -s "$root/licenses/Ceres/LICENSE" ] || die "licenses/Ceres/LICENSE is missing"
  [ -s "$root/licenses/Eigen/COPYING.MPL2" ] || die "licenses/Eigen/COPYING.MPL2 is missing"
  if find "$root" -type l -print | /usr/bin/grep -q .; then
    die "symlink survived Ceres installation"
  fi
  if find "$root" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.pc' \) -print | /usr/bin/grep -q .; then
    die "dynamic library or pkg-config file entered Ceres installation"
  fi
  [ ! -e "$root/bin" ] && [ ! -e "$root/share/doc" ] && [ ! -e "$root/share/man" ] || \
    die "binary or documentation entered Ceres installation"
  [ "$(find "$root/lib" -maxdepth 1 -type f -name '*.a' -print | wc -l | tr -d ' ')" = "1" ] || \
    die "unexpected static library entered Ceres installation"
  validate_static_archive "$root/lib/libceres.a"
  local config="$root/include/ceres/internal/config.h"
  "$RG_BIN" '^#define[[:space:]]+CERES_NO_SUITESPARSE([[:space:]]|$)' "$config" >/dev/null || \
    die "installed Ceres header does not disable SuiteSparse"
  "$RG_BIN" '^#define[[:space:]]+CERES_USE_EIGEN_SPARSE([[:space:]]|$)' "$config" >/dev/null || \
    die "installed Ceres header does not enable EigenSparse"
  if "$RG_BIN" '^#define[[:space:]]+CERES_NO_ACCELERATE_SPARSE([[:space:]]|$)' "$config" >/dev/null; then
    die "installed Ceres header disables AccelerateSparse"
  fi
  if "$RG_BIN" -a -n -F "$ROOT" "$root" >/dev/null || \
    "$RG_BIN" -a -n -F "$WORK" "$root" >/dev/null || \
    "$RG_BIN" -a -n -- '/Users/|/private/tmp/|/opt/homebrew/|/usr/local/|-(mcpu|march)=native' "$root" >/dev/null; then
    die "checkout path leaked into Ceres prefix"
  fi
  for forbidden in CholmodSupport MetisSupport SPQRSupport UmfPackSupport PaStiXSupport PardisoSupport SuperLUSupport; do
    [ ! -e "$root/include/eigen3/Eigen/$forbidden" ] || die "forbidden Eigen integration header survived: $forbidden"
  done
}

stage_receipt() {
  "$PYTHON_BIN" - \
    "$LOCK" "$STAGE" "$SUPPORT" "$FROZEN_FREEZER_SHA256" \
    "$FROZEN_WRAPPER_SHA256" "$FROZEN_IMPLEMENTATION_SHA256" \
    "$EXTRACTOR" "$FROZEN_PROMOTER_SHA256" \
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$CMAKE_BIN" "$CURL_BIN" "$LD_BIN" \
    "$LIPO_BIN" "$LOCKF_BIN" "$NINJA_BIN" "$NM_BIN" "$OTOOL_BIN" "$PYTHON_BIN" \
    "$RANLIB_BIN" "$RG_BIN" "$SHASUM_BIN" "$STRINGS_BIN" "$VTOOL_BIN" "$XATTR_BIN" \
    "$XCODEBUILD_BIN" "$XCRUN_BIN" "$MACOS_SDK_VERSION" "$MACOS_SDK/SDKSettings.json" \
    "$NORMALIZED_MTIME_EPOCH" <<'PY'
import hashlib
import json
import stat
import subprocess
import sys
from pathlib import Path

(
    lock_raw, root_raw, support_raw, freezer_sha256, wrapper_sha256,
    implementation_sha256, extractor_raw, promoter_sha256,
    ar_raw, clang_raw, clangxx_raw, cmake_raw, curl_raw, ld_raw, lipo_raw, lockf_raw,
    ninja_raw, nm_raw, otool_raw, python_raw, ranlib_raw, rg_raw, shasum_raw, strings_raw,
    vtool_raw, xattr_raw, xcodebuild_raw, xcrun_raw, sdk_version, sdk_settings_raw, epoch_raw,
) = sys.argv[1:]
lock_path, root, support = Path(lock_raw), Path(root_raw), Path(support_raw)
extractor = Path(extractor_raw)
sdk_settings = Path(sdk_settings_raw)
lock = json.loads(lock_path.read_text(encoding="utf-8"))

def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def version(command):
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return " | ".join(line.strip() for line in result.stdout.splitlines() if line.strip())

def tree_sha256(path):
    digest = hashlib.sha256()
    paths = [path, *sorted(path.rglob("*"), key=lambda item: item.relative_to(path).as_posix())]
    for entry in paths:
        relative = "." if entry == path else entry.relative_to(path).as_posix()
        if relative == "build_info.json":
            continue
        metadata = entry.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            kind, content = "directory", ""
        elif stat.S_ISREG(metadata.st_mode):
            kind, content = "file", file_sha256(entry)
        else:
            raise SystemExit(f"unsupported install entry: {relative}")
        for value in (relative, kind, f"{mode:o}", str(metadata.st_mtime_ns), content):
            digest.update(value.encode())
            digest.update(b"\0")
    return digest.hexdigest()

support_receipt_path = support / "build_info.json"
support_receipt = json.loads(support_receipt_path.read_text(encoding="utf-8"))
tools = {
    "ar": Path(ar_raw), "clang": Path(clang_raw), "clangxx": Path(clangxx_raw),
    "cmake": Path(cmake_raw), "curl": Path(curl_raw), "ld": Path(ld_raw),
    "lipo": Path(lipo_raw), "lockf": Path(lockf_raw), "ninja": Path(ninja_raw),
    "nm": Path(nm_raw), "otool": Path(otool_raw), "python": Path(python_raw),
    "ranlib": Path(ranlib_raw), "ripgrep": Path(rg_raw), "shasum": Path(shasum_raw),
    "strings": Path(strings_raw), "vtool": Path(vtool_raw), "xattr": Path(xattr_raw),
    "xcodebuild": Path(xcodebuild_raw), "xcrun": Path(xcrun_raw),
}
dependencies = {}
license_files = {
    "ceres": ["licenses/Ceres/LICENSE"],
    "eigen": [f"licenses/Eigen/{name}" for name in ("COPYING.APACHE", "COPYING.BSD", "COPYING.GPL", "COPYING.LGPL", "COPYING.MINPACK", "COPYING.MPL2", "COPYING.README")],
}
for name in ("ceres", "eigen"):
    entry = lock["dependencies"][name]
    dependencies[name] = {
        "source_url": entry["source"]["url"],
        "source_sha256": entry["source"]["sha256"],
        "source_commit": entry["commit"],
        "source_version": entry["version"],
        "license": entry["license"],
        "license_files": license_files[name],
    }
payload = {
    "schema_version": 1,
    "toolchain_name": "ceres-static",
    "source_url": dependencies["ceres"]["source_url"],
    "source_sha256": dependencies["ceres"]["source_sha256"],
    "source_commit": dependencies["ceres"]["source_commit"],
    "source_version": dependencies["ceres"]["source_version"],
    "license": dependencies["ceres"]["license"],
    "architecture": "arm64",
    "deployment_target": "macOS 15.0",
    "shared_libraries": False,
    "suitesparse": False,
    "cuda": False,
    "logging": "glog",
    "gflags": True,
    "sparse_backends": ["AccelerateSparse", "EigenSparse"],
    "dependencies": dependencies,
    "build_options": {
        "ceres": ["BUILD_SHARED_LIBS=OFF", "SUITESPARSE=OFF", "ACCELERATESPARSE=ON", "EIGENSPARSE=ON", "EIGENMETIS=OFF", "USE_CUDA=OFF", "MINIGLOG=OFF", "GFLAGS=ON"],
        "reproducibility": ["SOURCE_DATE_EPOCH=0", "ZERO_AR_DATE=1", "EIGEN_MPL2_ONLY=ON", "checkout-prefix=/easysplat-source", "support-prefix=/easysplat-support", "install-mtime=2000-01-01T00:00:00Z", "regular-mode=0644", "directory-mode=0755", "ownership-policy=invoking-build-user-and-primary-group", "extended-attributes=none", "umask=022"],
    },
    "source_date_epoch": 0,
    "normalized_mtime_epoch": int(epoch_raw),
    "ownership_policy": "invoking-build-user-and-primary-group",
    "control_freezer_sha256": freezer_sha256,
    "builder_sha256": wrapper_sha256,
    "builder_implementation_sha256": implementation_sha256,
    "source_lock_sha256": file_sha256(lock_path),
    "extractor_sha256": file_sha256(extractor),
    "promoter_sha256": promoter_sha256,
    "support_receipt_sha256": file_sha256(support_receipt_path),
    "support_install_tree_sha256": support_receipt["install_tree_sha256"],
    "macos_sdk_settings_sha256": file_sha256(sdk_settings),
    "build_tool_sha256": {name: file_sha256(path) for name, path in tools.items()},
    "build_tools": {
        "clang": version([clang_raw, "--version"]).split(" | ")[0],
        "cmake": version([cmake_raw, "--version"]).split(" | ")[0],
        "ninja": version([ninja_raw, "--version"]),
        "python": version([python_raw, "--version"]),
        "ripgrep": version([rg_raw, "--version"]).split(" | ")[0],
        "xcode": version([xcodebuild_raw, "-version"]),
        "macos_sdk": sdk_version,
    },
    "library_sha256": {"lib/libceres.a": file_sha256(root / "lib/libceres.a")},
    "install_tree_sha256": tree_sha256(root),
}
(root / "build_info.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

validate_receipt() {
  local root="$1"
  "$PYTHON_BIN" - \
    "$root" "$SUPPORT" "$LOCK" "$FROZEN_FREEZER_SHA256" \
    "$FROZEN_WRAPPER_SHA256" "$FROZEN_IMPLEMENTATION_SHA256" \
    "$EXTRACTOR" "$FROZEN_PROMOTER_SHA256" \
    "$MACOS_SDK/SDKSettings.json" "$NORMALIZED_MTIME_EPOCH" \
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$CMAKE_BIN" "$CURL_BIN" "$LD_BIN" \
    "$LIPO_BIN" "$LOCKF_BIN" "$NINJA_BIN" "$NM_BIN" "$OTOOL_BIN" "$PYTHON_BIN" \
    "$RANLIB_BIN" "$RG_BIN" "$SHASUM_BIN" "$STRINGS_BIN" "$VTOOL_BIN" "$XATTR_BIN" \
    "$XCODEBUILD_BIN" "$XCRUN_BIN" <<'PY'
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

root, support, lock = map(Path, sys.argv[1:4])
freezer_sha256, wrapper_sha256, implementation_sha256 = sys.argv[4:7]
extractor = Path(sys.argv[7])
promoter_sha256 = sys.argv[8]
sdk_settings = Path(sys.argv[9])
epoch = int(sys.argv[10])
tool_names = ("ar", "clang", "clangxx", "cmake", "curl", "ld", "lipo", "lockf", "ninja", "nm", "otool", "python", "ranlib", "ripgrep", "shasum", "strings", "vtool", "xattr", "xcodebuild", "xcrun")
if len(sys.argv[11:]) != len(tool_names):
    raise SystemExit("internal validator tool argument mismatch")
tool_paths = dict(zip(tool_names, map(Path, sys.argv[11:])))
receipt = json.loads((root / "build_info.json").read_text(encoding="utf-8"))

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def tree_sha256(path):
    digest = hashlib.sha256()
    paths = [path, *sorted(path.rglob("*"), key=lambda item: item.relative_to(path).as_posix())]
    for entry in paths:
        relative = "." if entry == path else entry.relative_to(path).as_posix()
        if relative == "build_info.json": continue
        metadata = entry.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode): kind, content = "directory", ""
        elif stat.S_ISREG(metadata.st_mode): kind, content = "file", sha(entry)
        else: raise SystemExit(f"unsupported install entry: {relative}")
        for value in (relative, kind, f"{mode:o}", str(metadata.st_mtime_ns), content):
            digest.update(value.encode()); digest.update(b"\0")
    return digest.hexdigest()

expected = {
    "control_freezer_sha256": freezer_sha256,
    "builder_sha256": wrapper_sha256,
    "builder_implementation_sha256": implementation_sha256,
    "source_lock_sha256": sha(lock),
    "extractor_sha256": sha(extractor),
    "promoter_sha256": promoter_sha256,
    "support_receipt_sha256": sha(support / "build_info.json"),
    "support_install_tree_sha256": json.loads((support / "build_info.json").read_text())["install_tree_sha256"],
    "macos_sdk_settings_sha256": sha(sdk_settings),
    "build_tool_sha256": {name: sha(path) for name, path in tool_paths.items()},
    "install_tree_sha256": tree_sha256(root),
}
for key, value in expected.items():
    if receipt.get(key) != value:
        raise SystemExit(f"Ceres receipt mismatch: {key}")
if receipt.get("library_sha256", {}).get("lib/libceres.a") != sha(root / "lib/libceres.a"):
    raise SystemExit("Ceres library hash does not match receipt")
if receipt.get("architecture") != "arm64" or receipt.get("deployment_target") != "macOS 15.0":
    raise SystemExit("Ceres receipt platform mismatch")
lock_payload = json.loads(lock.read_text(encoding="utf-8"))
ceres = lock_payload["dependencies"]["ceres"]
eigen = lock_payload["dependencies"]["eigen"]
primary_source = {
    "source_url": ceres["source"]["url"],
    "source_sha256": ceres["source"]["sha256"],
    "source_commit": ceres["commit"],
    "source_version": ceres["version"],
    "license": ceres["license"],
}
for key, value in primary_source.items():
    if receipt.get(key) != value:
        raise SystemExit(f"Ceres source receipt mismatch: {key}")
license_files = {
    "ceres": ["licenses/Ceres/LICENSE"],
    "eigen": [f"licenses/Eigen/{name}" for name in ("COPYING.APACHE", "COPYING.BSD", "COPYING.GPL", "COPYING.LGPL", "COPYING.MINPACK", "COPYING.MPL2", "COPYING.README")],
}
expected_dependencies = {}
for name, entry in (("ceres", ceres), ("eigen", eigen)):
    expected_dependencies[name] = {
        "source_url": entry["source"]["url"],
        "source_sha256": entry["source"]["sha256"],
        "source_commit": entry["commit"],
        "source_version": entry["version"],
        "license": entry["license"],
        "license_files": license_files[name],
    }
if receipt.get("dependencies") != expected_dependencies:
    raise SystemExit("Ceres dependency receipt mismatch")
expected_build_options = {
    "ceres": ["BUILD_SHARED_LIBS=OFF", "SUITESPARSE=OFF", "ACCELERATESPARSE=ON", "EIGENSPARSE=ON", "EIGENMETIS=OFF", "USE_CUDA=OFF", "MINIGLOG=OFF", "GFLAGS=ON"],
    "reproducibility": ["SOURCE_DATE_EPOCH=0", "ZERO_AR_DATE=1", "EIGEN_MPL2_ONLY=ON", "checkout-prefix=/easysplat-source", "support-prefix=/easysplat-support", "install-mtime=2000-01-01T00:00:00Z", "regular-mode=0644", "directory-mode=0755", "ownership-policy=invoking-build-user-and-primary-group", "extended-attributes=none", "umask=022"],
}
if receipt.get("build_options") != expected_build_options:
    raise SystemExit("Ceres build-options receipt mismatch")
expected_scalars = {
    "schema_version": 1,
    "toolchain_name": "ceres-static",
    "source_date_epoch": 0,
    "normalized_mtime_epoch": epoch,
    "ownership_policy": "invoking-build-user-and-primary-group",
    "shared_libraries": False,
    "suitesparse": False,
    "cuda": False,
    "logging": "glog",
    "gflags": True,
    "sparse_backends": ["AccelerateSparse", "EigenSparse"],
}
for key, value in expected_scalars.items():
    if receipt.get(key) != value:
        raise SystemExit(f"Ceres build receipt mismatch: {key}")
if "normalized_owner_uid" in receipt or "normalized_owner_gid" in receipt:
    raise SystemExit("Ceres build receipt contains host-specific numeric ownership")

def version(command):
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return " | ".join(line.strip() for line in result.stdout.splitlines() if line.strip())

expected_build_tools = {
    "clang": version([str(tool_paths["clang"]), "--version"]).split(" | ")[0],
    "cmake": version([str(tool_paths["cmake"]), "--version"]).split(" | ")[0],
    "ninja": version([str(tool_paths["ninja"]), "--version"]),
    "python": version([str(tool_paths["python"]), "--version"]),
    "ripgrep": version([str(tool_paths["ripgrep"]), "--version"]).split(" | ")[0],
    "xcode": version([str(tool_paths["xcodebuild"]), "-version"]),
    "macos_sdk": version([str(tool_paths["xcrun"]), "--sdk", "macosx", "--show-sdk-version"]),
}
if receipt.get("build_tools") != expected_build_tools:
    raise SystemExit("Ceres build-tool version receipt mismatch")
for path in [root, *root.rglob("*")]:
    metadata = path.lstat()
    expected_mode = 0o755 if stat.S_ISDIR(metadata.st_mode) else 0o644
    if stat.S_IMODE(metadata.st_mode) != expected_mode or metadata.st_uid != os.getuid() or metadata.st_gid != os.getgid() or metadata.st_mtime_ns != epoch * 1_000_000_000:
        raise SystemExit(f"Ceres install metadata is not canonical: {path}")
    if hasattr(os, "listxattr") and os.listxattr(path, follow_symlinks=False):
        raise SystemExit(f"Ceres install has extended attributes: {path}")
PY
}

validate_relocated_consumer() {
  local root="$1"
  local check="$WORK/relocated-consumer.$$"
  local prefix="$check/prefix"
  local source="$check/source"
  local build="$check/build"
  rm -rf "$check"
  mkdir -p "$check" "$source"
  "$PYTHON_BIN" - "$root" "$prefix" <<'PY'
import shutil
import sys
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=False)
PY
  /bin/cat >"$source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.24)
project(RelocatedCeresConsumer LANGUAGES CXX)
find_package(Ceres CONFIG REQUIRED)
add_executable(ceres_consumer main.cpp)
target_link_libraries(ceres_consumer PRIVATE Ceres::ceres)
CMAKE
  /bin/cat >"$source/main.cpp" <<'CPP'
#include <ceres/ceres.h>
#include <cmath>
#include <iostream>

struct Residual {
  template <typename T> bool operator()(const T* const x, T* residual) const {
    residual[0] = T(10.0) - x[0];
    return true;
  }
};

int main() {
  double x = 0.0;
  ceres::Problem problem;
  problem.AddResidualBlock(new ceres::AutoDiffCostFunction<Residual, 1, 1>(new Residual), nullptr, &x);
  ceres::Solver::Options options;
  options.max_num_iterations = 25;
  options.linear_solver_type = ceres::DENSE_QR;
  options.logging_type = ceres::SILENT;
  options.num_threads = 1;
  ceres::Solver::Summary summary;
  ceres::Solve(options, &problem, &summary);
  std::cout << "x=" << x << " final_cost=" << summary.final_cost << "\n";
  return summary.IsSolutionUsable() && std::abs(x - 10.0) < 1e-7 && summary.final_cost < 1e-12 ? 0 : 1;
}
CPP
  "$CMAKE_BIN" -S "$source" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$prefix;$SUPPORT" \
    '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF \
    -DCMAKE_C_COMPILER="$CLANG_BIN" \
    -DCMAKE_CXX_COMPILER="$CLANGXX_BIN" \
    -DCMAKE_AR="$AR_BIN" \
    -DCMAKE_RANLIB="$RANLIB_BIN" \
    -DCMAKE_LINKER="$LD_BIN" \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LINK_FLAGS" >"$LOGS/consumer-configure.log" 2>&1 || {
      /bin/cat "$LOGS/consumer-configure.log" >&2
      die "relocated Ceres consumer configuration failed"
    }
  "$CMAKE_BIN" --build "$build" --parallel "$(sysctl -n hw.ncpu)" >"$LOGS/consumer-build.log" 2>&1 || {
    /bin/cat "$LOGS/consumer-build.log" >&2
    die "relocated Ceres consumer build failed"
  }
  local executable="$build/ceres_consumer"
  local output
  output="$("$executable")" || die "relocated Ceres consumer solve failed"
  printf '%s\n' "$output" | "$RG_BIN" '^x=10(\.0+)? final_cost=' >/dev/null || \
    die "relocated Ceres consumer returned an unexpected solution"
  [ "$("$LIPO_BIN" -archs "$executable")" = "arm64" ] || \
    die "relocated Ceres consumer is not thin arm64"
  local build_metadata minos
  build_metadata="$("$VTOOL_BIN" -show-build "$executable")"
  printf '%s\n' "$build_metadata" | "$RG_BIN" '^[[:space:]]*platform[[:space:]]+MACOS$' >/dev/null || \
    die "relocated Ceres consumer is not a macOS executable"
  minos="$(printf '%s\n' "$build_metadata" | /usr/bin/awk '$1 == "minos" {print $2; exit}')"
  "$PYTHON_BIN" - "$minos" <<'PY'
import sys
if tuple(int(part) for part in sys.argv[1].split(".")) > (15, 0):
    raise SystemExit("relocated Ceres consumer requires macOS newer than macOS 15.0")
PY
  local dependency
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      *libceres*|*cholmod*|*suitesparse*|*metis*|*cuda*) \
        die "relocated Ceres consumer has a forbidden dependency: $dependency" ;;
      *) die "relocated Ceres consumer has a non-system dependency: $dependency" ;;
    esac
  done < <("$OTOOL_BIN" -L "$executable" | /usr/bin/awk 'NR > 1 {print $1}')
  rm -rf "$check"
}

promote_install() {
  local journal="$STAGE.promotion-state" tree_receipt
  tree_receipt="$(run_promoter --tree-receipt \
    "$STAGE" "$INSTALL_STAGE_DEVICE" "$INSTALL_STAGE_INODE")" || \
    die "could not bind the validated Ceres tree"
  STAGE_CLEANUP_ALLOWED=0
  run_promoter "$STAGE" "$INSTALL" "$tree_receipt" || \
    die "atomic Ceres promotion failed; recovery state preserved"
  if ! (
    validate_install_tree "$INSTALL" &&
    validate_receipt "$INSTALL" &&
    validate_relocated_consumer "$INSTALL"
  ); then
    if run_promoter --recover "$journal"; then
      die "post-promotion validation failed; previous Ceres state restored"
    fi
    die "post-promotion validation and rollback failed; recovery state preserved"
  fi
  run_promoter --commit "$journal" || \
    die "could not finalize Ceres promotion; recovery state preserved"
}

main() {
  validate_frozen_control_inputs || die "frozen build controls are invalid"
  acquire_build_lock
  recover_stale_promotions
  preflight
  sanitize_environment
  mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILDS" "$LOGS" "$BUILD_HOME" "$BUILD_TMP"
  if [ "$#" -gt 0 ]; then
    [ "$#" = "2" ] && [ "$1" = "--validate-only" ] || \
      die "usage: build_ceres.sh [--validate-only <install>]"
    local candidate
    candidate="$(cd "$2" 2>/dev/null && pwd -P)" || die "validation target is not a directory: $2"
    verify_support_prefix
    validate_install_tree "$candidate"
    validate_receipt "$candidate"
    validate_relocated_consumer "$candidate"
    echo "Validated Ceres install: $candidate"
    return
  fi
  create_owned_install_stage
  verify_support_prefix
  build_eigen
  build_ceres
  audit_compile_commands
  trim_install
  prune_disabled_backend_objects
  stage_licenses
  normalize_metadata "$STAGE"
  validate_install_tree "$STAGE"
  validate_relocated_consumer "$STAGE"
  stage_receipt
  normalize_metadata "$STAGE"
  validate_install_tree "$STAGE"
  validate_receipt "$STAGE"
  promote_install
  echo "Ceres installed to: $INSTALL"
}

main "$@"
