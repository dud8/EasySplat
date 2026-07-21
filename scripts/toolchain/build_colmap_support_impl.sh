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
  builtin printf '%s\n' \
    "COLMAP support build failed: implementation received inherited shell functions" >&2
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
WORK="$ROOT/Toolchains/build/colmap-support"
DOWNLOADS="$WORK/downloads"
SOURCES="$WORK/sources"
BUILDS="$WORK/builds"
LOGS="$WORK/logs"
INSTALL="$WORK/install"
STAGE="$WORK/install.stage.$$"
BUILD_LOCK="$WORK/.build.lock"
BUILD_HOME="$WORK/home"
BUILD_TMP="$WORK/tmp"
LOCK="$ROOT/scripts/toolchain/colmap-support-lock.json"
EXTRACTOR="$ROOT/scripts/toolchain/safe_extract_source.py"
TESTS="$ROOT/scripts/toolchain/tests/test_colmap_support_builder.py"
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
CODESIGN_BIN="/usr/bin/codesign"
CURL_BIN="/usr/bin/curl"
INSTALL_NAME_TOOL_BIN=""
LD_BIN=""
LIPO_BIN=""
LOCKF_BIN="/usr/bin/lockf"
NINJA_BIN=""
OTOOL_BIN=""
PYTHON_BIN=""
RANLIB_BIN=""
RG_BIN=""
SHASUM_BIN="/usr/bin/shasum"
VTOOL_BIN=""
XCODEBUILD_BIN=""
XCODE_DEVELOPER_DIR=""
XCODE_TOOLCHAIN_BIN=""
XCRUN_BIN="/usr/bin/xcrun"
XATTR_BIN="/usr/bin/xattr"
MACOS_SDK=""
MACOS_SDK_VERSION=""
COMMON_C_FLAGS=""
COMMON_CXX_FLAGS=""
COMMON_LINK_FLAGS=""

die() {
  echo "COLMAP support build failed: $*" >&2
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
        "COLMAP support build cleanup preserved an unverified staged install: $STAGE" >&2
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
  )" || die "could not create and bind COLMAP support install stage"
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
    die "COLMAP support install stage identity is malformed"
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
  validate_build_lock || die "COLMAP support build lock is unsafe"
  "$LOCKF_BIN" -s -t 0 9 || die "another COLMAP support build is running"
  LOCK_OWNED=1
  validate_build_lock || die "COLMAP support build lock changed during acquisition"
}

recover_stale_promotions() {
  local journal path
  for journal in "$WORK"/install.stage.*.promotion-state; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    run_promoter --recover "$journal" || \
      die "could not recover interrupted COLMAP support promotion: $journal"
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
  validate_frozen_control_inputs || die "frozen build controls are invalid"
  [ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64"
  [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || \
    die "Rosetta is unsupported"
  case "$ROOT" in
    *[[:space:]]*) die "checkout path contains whitespace; move the source checkout before building" ;;
  esac
  [ -s "$LOCK" ] || die "colmap-support-lock.json is missing"
  [ -x "$EXTRACTOR" ] || die "safe source extractor is missing or not executable"
  [ -f "$TESTS" ] || die "COLMAP support artifact tests are missing"
  for command in \
    /usr/bin/codesign \
    /usr/bin/curl \
    /usr/bin/lockf \
    /usr/bin/shasum \
    /usr/bin/xattr \
    /usr/bin/xcode-select \
    /usr/bin/xcrun; do
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
  INSTALL_NAME_TOOL_BIN="$(resolve_xcode_tool install_name_tool)"
  LD_BIN="$(resolve_xcode_tool ld)"
  LIPO_BIN="$(resolve_xcode_tool lipo)"
  OTOOL_BIN="$(resolve_xcode_tool otool)"
  PYTHON_BIN="$(resolve_xcode_tool python3)"
  RANLIB_BIN="$(resolve_xcode_tool ranlib)"
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
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$INSTALL_NAME_TOOL_BIN" "$LD_BIN" \
    "$LIPO_BIN" "$OTOOL_BIN" "$PYTHON_BIN" "$RANLIB_BIN" "$VTOOL_BIN" \
    "$XCODEBUILD_BIN"; do
    [ -x "$command" ] || die "selected Xcode tool is missing: $command"
  done
}

sanitize_environment() {
  unset \
    AR ARCHFLAGS ASFLAGS B2_BUILD_ID B2_TOOLSET B2_USER_CONFIG BASH_ENV CDPATH \
    BOOST_BUILD_PATH BOOST_BUILD_USER_CONFIG BOOST_INCLUDEDIR BOOST_LIBRARYDIR BOOST_ROOT \
    CCC_OVERRIDE_OPTIONS CC CFLAGS C_INCLUDE_PATH CPLUS_INCLUDE_PATH COMPILER_PATH \
    CMAKE_APPBUNDLE_PATH CMAKE_BUILD_PARALLEL_LEVEL CMAKE_BUILD_TYPE \
    CMAKE_C_COMPILER_LAUNCHER CMAKE_CROSSCOMPILING_EMULATOR CMAKE_FRAMEWORK_PATH \
    CMAKE_GENERATOR CMAKE_GENERATOR_INSTANCE CMAKE_GENERATOR_PLATFORM CMAKE_GENERATOR_TOOLSET \
    CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_OSX_SYSROOT CMAKE_PREFIX_PATH \
    CMAKE_PROJECT_INCLUDE CMAKE_PROJECT_INCLUDE_BEFORE CMAKE_PROJECT_TOP_LEVEL_INCLUDES \
    CMAKE_TOOLCHAIN_FILE CPATH CPPFLAGS CXX CXXFLAGS CMAKE_CXX_COMPILER_LAUNCHER \
    DESTDIR DEVELOPER_DIR ENV GCC_EXEC_PREFIX GLOBIGNORE \
    DYLD_FALLBACK_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
    DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH LD LD_LIBRARY_PATH LDFLAGS LIBRARY_PATH \
    LLVM_CONFIG MAKEFLAGS NM OBJCFLAGS OBJCXXFLAGS OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH \
    PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PYTHONHOME PYTHONINSPECT PYTHONPATH PYTHONSTARTUP \
    PYTHONWARNINGS Python3_ROOT_DIR Python_ROOT_DIR RANLIB RCFLAGS SDKROOT STRIP \
    VIRTUAL_ENV CONDA_PREFIX || true

  local path_value="$XCODE_TOOLCHAIN_BIN:$XCODE_DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  local tool directory variable
  for tool in "$CMAKE_BIN" "$NINJA_BIN" "$RG_BIN"; do
    directory="$(/usr/bin/dirname "$tool")"
    case ":$path_value:" in
      *":$directory:"*) ;;
      *) path_value="$path_value:$directory" ;;
    esac
  done

  # The build receives an allowlisted environment. This prevents undocumented
  # compiler, linker, Python, and dynamic-loader overrides from changing bytes.
  while IFS= read -r variable; do
    case "$variable" in
      DYLD_*) unset "$variable" 2>/dev/null || true ;;
      *) unset "$variable" 2>/dev/null || true ;;
    esac
  done < <(compgen -e)

  export PATH="$path_value"
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
  export HOME="$BUILD_HOME"
  export TMPDIR="$BUILD_TMP"
  export LC_ALL=C
  export LANG=C
  export TZ=UTC
  export MACOSX_DEPLOYMENT_TARGET=15.0
  export ZERO_AR_DATE=1
  export SOURCE_DATE_EPOCH=0
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_LIBDIR="/dev/null"

  COMMON_C_FLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $MACOS_SDK -ffile-prefix-map=$ROOT=/easysplat-source -fdebug-prefix-map=$ROOT=/easysplat-source"
  COMMON_CXX_FLAGS="$COMMON_C_FLAGS"
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

path = Path(sys.argv[1])
name = sys.argv[2]
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("unsupported colmap-support-lock.json schema")
try:
    entry = payload["dependencies"][name]
    source = entry["source"]
    values = (
        entry["version"],
        source["url"],
        source["sha256"],
        entry["license"],
    )
except (KeyError, TypeError) as error:
    raise SystemExit(f"incomplete source lock entry for {name}: {error}") from error
version, url, digest, license_name = values
if not all(isinstance(value, str) and value for value in values):
    raise SystemExit(f"invalid source lock value for {name}")
if not url.startswith("https://"):
    raise SystemExit(f"non-HTTPS source URL for {name}")
if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit(f"invalid source SHA-256 for {name}")
if "\t" in version + url + digest + license_name or "\n" in version + url + digest + license_name:
    raise SystemExit(f"unsafe source lock value for {name}")
print("\t".join(values))
PY
)" || die "could not load reviewed source pin: $name"
  IFS=$'\t' read -r PIN_VERSION PIN_URL PIN_SHA256 PIN_LICENSE <<<"$values"
  [ -n "$PIN_VERSION" ] && [ -n "$PIN_URL" ] && [ -n "$PIN_SHA256" ] && [ -n "$PIN_LICENSE" ] || \
    die "reviewed source pin is incomplete: $name"
}

download_verified() {
  local name="$1"
  local destination="$2"
  local temporary="$destination.tmp.$$"
  load_pin "$name"
  mkdir -p "$DOWNLOADS"
  if [ -f "$destination" ] && [ "$(sha256 "$destination")" = "$PIN_SHA256" ]; then
    return
  fi
  rm -f "$destination" "$temporary"
  /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location \
    --retry 3 --retry-delay 2 --output "$temporary" "$PIN_URL"
  if [ "$(sha256 "$temporary")" != "$PIN_SHA256" ]; then
    rm -f "$temporary"
    die "source archive SHA-256 mismatch: $name"
  fi
  mv "$temporary" "$destination"
}

extract_verified_archive() {
  local name="$1"
  local archive="$2"
  local destination="$3"
  local temporary="$destination.extract.$$"
  local extracted_root
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
}

prepare_source() {
  local name="$1"
  local archive="$DOWNLOADS/$name.archive"
  local destination="$SOURCES/$name"
  download_verified "$name" "$archive"
  extract_verified_archive "$name" "$archive" "$destination"
  PREPARED_SOURCE="$destination"
}

cmake_build_install() {
  local name="$1"
  local source="$2"
  shift 2
  local build="$BUILDS/$name"
  local log="$LOGS/$name.log"
  rm -rf "$build"
  "$CMAKE_BIN" -S "$source" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK" \
    -DCMAKE_C_COMPILER="$CLANG_BIN" \
    -DCMAKE_CXX_COMPILER="$CLANGXX_BIN" \
    -DCMAKE_AR="$AR_BIN" \
    -DCMAKE_RANLIB="$RANLIB_BIN" \
    -DCMAKE_LINKER="$LD_BIN" \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_C_FLAGS="$COMMON_C_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
    -DCMAKE_ASM_FLAGS="$COMMON_C_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_PREFIX_PATH="$STAGE" \
    '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF \
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    "$@" 2>&1 | /usr/bin/tee "$log"
  "$CMAKE_BIN" --build "$build" --target install \
    --parallel "$(sysctl -n hw.ncpu)" 2>&1 | /usr/bin/tee -a "$log"
}

build_boost() {
  prepare_source boost
  local source="$PREPARED_SOURCE"
  local log="$LOGS/boost.log"
  local build="$BUILDS/boost"
  local user_config="$build/user-config.jam"
  rm -rf "$build"
  mkdir -p "$build"
  "$PYTHON_BIN" - "$user_config" "$CLANGXX_BIN" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
compiler = sys.argv[2]
if any(character in compiler for character in {'"', '\n', '\r'}):
    raise SystemExit("unsafe compiler path for Boost.Build")
path.write_text(
    f'using clang : easysplat : "{compiler}" ;\n',
    encoding="utf-8",
)
PY
  if ! (
    cd "$source"
    CC="$CLANG_BIN" CXX="$CLANGXX_BIN" ./bootstrap.sh \
      --prefix="$STAGE" \
      --with-libraries=atomic,chrono,container,date_time,graph,program_options,thread
    ./b2 -q -d2 \
      --ignore-site-config \
      --user-config="$user_config" \
      --build-dir="$build" \
      --prefix="$STAGE" \
      toolset=clang-easysplat \
      cxxstd=17 \
      architecture=arm \
      address-model=64 \
      target-os=darwin \
      variant=release \
      threading=multi \
      link=static \
      runtime-link=shared \
      visibility=hidden \
      --layout=system \
      cflags="$COMMON_C_FLAGS" \
      cxxflags="$COMMON_CXX_FLAGS" \
      linkflags="$COMMON_LINK_FLAGS" \
      install
  ) >"$log" 2>&1; then
    /usr/bin/tail -n 200 "$log" >&2
    die "Boost build failed"
  fi
  /usr/bin/tail -n 20 "$log"
}

build_gflags() {
  prepare_source gflags
  cmake_build_install gflags "$PREPARED_SOURCE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGFLAGS_BUILD_SHARED_LIBS=OFF \
    -DGFLAGS_BUILD_STATIC_LIBS=ON \
    -DGFLAGS_BUILD_gflags_LIB=ON \
    -DGFLAGS_BUILD_gflags_nothreads_LIB=OFF \
    -DGFLAGS_BUILD_TESTING=OFF \
    -DGFLAGS_BUILD_PACKAGING=OFF \
    -DREGISTER_BUILD_DIR=OFF \
    -DREGISTER_INSTALL_PREFIX=OFF
}

build_glog() {
  prepare_source glog
  cmake_build_install glog "$PREPARED_SOURCE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_GFLAGS=ON \
    -DWITH_GTEST=OFF \
    -DWITH_UNWIND=none \
    -Dgflags_DIR="$STAGE/lib/cmake/gflags"
}

build_libomp() {
  prepare_source libomp
  [ -d "$PREPARED_SOURCE/openmp" ] || die "LLVM source archive does not contain openmp"
  cmake_build_install libomp "$PREPARED_SOURCE/openmp" \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBOMP_ENABLE_SHARED=ON \
    -DLIBOMP_USE_ITT_NOTIFY=OFF \
    -DLIBOMP_INSTALL_ALIASES=OFF \
    -DLIBOMP_OMPT_SUPPORT=OFF \
    -DLIBOMP_USE_HWLOC=OFF \
    -DLIBOMP_ENABLE_ASSERTIONS=OFF \
    -DOPENMP_ENABLE_LIBOMPTARGET=OFF \
    -DPython3_EXECUTABLE="$PYTHON_BIN" \
    -DCMAKE_INSTALL_NAME_DIR=@rpath
  if "$RG_BIN" -a -n -F 'ittnotify_static.cpp.o' "$BUILDS/libomp/build.ninja" >/dev/null; then
    die "ittnotify_static.cpp entered the OpenMP build"
  fi
}

audit_compile_commands() {
  local file
  while IFS= read -r file; do
    "$PYTHON_BIN" - \
      "$file" "$MACOS_SDK" "$ROOT" "$CLANG_BIN" "$CLANGXX_BIN" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
sdk = sys.argv[2]
root = sys.argv[3]
compilers = {Path(raw).resolve() for raw in sys.argv[4:]}
entries = json.loads(path.read_text(encoding="utf-8"))
if not entries:
    raise SystemExit(f"compile command database is empty: {path}")
for entry in entries:
    tokens = entry.get("arguments") or shlex.split(entry.get("command", ""))
    if not tokens or Path(tokens[0]).resolve() not in compilers:
        raise SystemExit(f"unpinned compiler entered the build: {tokens[:1]}")
    for index, token in enumerate(tokens):
        if token in {"-mcpu", "-march"} and index + 1 < len(tokens) and tokens[index + 1] == "native":
            raise SystemExit("host-specific compiler tuning entered the build")
        if re.fullmatch(r"-(?:mcpu|march)=native", token):
            raise SystemExit("host-specific compiler tuning entered the build")
        if "/opt/homebrew/" in token or "/usr/local/" in token:
            raise SystemExit("Homebrew dependency entered the build")
    try:
        sysroot_index = tokens.index("-isysroot")
    except ValueError as error:
        raise SystemExit(f"macOS sysroot is absent from compile command: {path}") from error
    if sysroot_index + 1 >= len(tokens) or tokens[sysroot_index + 1] != sdk:
        raise SystemExit(f"unexpected SDK entered the build: {path}")
    if f"-ffile-prefix-map={root}=/easysplat-source" not in tokens:
        raise SystemExit(f"source prefix map is absent from compile command: {path}")
    if f"-fdebug-prefix-map={root}=/easysplat-source" not in tokens:
        raise SystemExit(f"debug prefix map is absent from compile command: {path}")
PY
  done < <(find "$BUILDS" -type f -name compile_commands.json -print | LC_ALL=C sort)

  "$RG_BIN" -a -F -- "-isysroot $MACOS_SDK" "$LOGS/boost.log" >/dev/null || \
    die "Boost commands did not use the pinned macOS SDK"
  "$RG_BIN" -a -F -- "$CLANGXX_BIN" "$LOGS/boost.log" >/dev/null || \
    die "Boost commands did not use the pinned Xcode compiler"
  if "$RG_BIN" -a -n -- '(^|[[:space:]])-(mcpu|march)(=|[[:space:]]+)native([[:space:]]|$)' \
    "$BUILDS" "$LOGS" >/dev/null; then
    die "host-specific compiler tuning entered the build"
  fi
  if "$RG_BIN" -a -n -g build.ninja -g compile_commands.json -g CMakeCache.txt -g '*.log' \
    -- "/opt/homebrew/(opt|Cellar|Caskroom|include|lib)(/|[[:space:]\"'])|/usr/local/(opt|Cellar|Caskroom|include|lib)(/|[[:space:]\"'])|-[ILF][[:space:]]*(/opt/homebrew|/usr/local)/|(/opt/homebrew|/usr/local)/[^[:space:]\"']+\\.(a|dylib)" \
    "$BUILDS" "$LOGS" >/dev/null; then
    die "Homebrew dependency entered the build"
  fi
}

normalize_boost_configs() {
  "$PYTHON_BIN" - "$STAGE" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
marker = "# If the computed and the original directories are symlink-equivalent, use original"
pattern = re.compile(
    r"\n# If the computed and the original directories are symlink-equivalent, use original\n"
    r"if\(EXISTS \"(?P<directory>[^\"]+)\"\)\n"
    r"  get_filename_component\(_BOOST_CMAKEDIR_ORIGINAL \"(?P=directory)\" REALPATH\)\n"
    r"  if\(_BOOST_CMAKEDIR STREQUAL _BOOST_CMAKEDIR_ORIGINAL\)\n"
    r"    set\(_BOOST_CMAKEDIR \"(?P=directory)\"\)\n"
    r"  endif\(\)\n"
    r"  unset\(_BOOST_CMAKEDIR_ORIGINAL\)\n"
    r"endif\(\)\n"
)
rewritten = 0
for path in sorted((root / "lib/cmake").glob("boost_*-*/boost_*-config.cmake")):
    text = path.read_text(encoding="utf-8")
    if marker not in text:
        continue
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(f"unexpected Boost relocation block: {path}")
    directory = Path(matches[0].group("directory"))
    expected = root / "lib/cmake"
    if directory != expected:
        raise SystemExit(f"unexpected Boost install directory: {directory}")
    path.write_text(pattern.sub("\n", text), encoding="utf-8")
    rewritten += 1
if rewritten == 0:
    raise SystemExit("Boost component configurations had no relocation block")
PY
}

validate_static_archive() {
  local archive="$1"
  local metadata
  metadata="$LOGS/$(basename "$archive").otool"
  "$LIPO_BIN" -info "$archive" | /usr/bin/grep -Eq 'architecture: arm64$' || \
    die "static archive is not thin arm64: $archive"
  "$OTOOL_BIN" -l "$archive" >"$metadata"
  "$PYTHON_BIN" - "$archive" "$metadata" "$AR_BIN" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

archive = Path(sys.argv[1])
load_commands = Path(sys.argv[2]).read_text(encoding="utf-8")
ar = sys.argv[3]
versions = re.findall(r"^\s*minos\s+([0-9.]+)$", load_commands, re.MULTILINE)
platforms = re.findall(r"^\s*platform\s+([^\s]+)$", load_commands, re.MULTILINE)
members = subprocess.run(
    [ar, "-t", str(archive)],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
objects = [member for member in members if not member.startswith("__.SYMDEF")]
if not objects or len(versions) != len(objects) or len(platforms) != len(objects):
    raise SystemExit(f"incomplete Mach-O metadata in static archive: {archive}")
if set(platforms) != {"1"}:
    raise SystemExit(f"not a macOS object: {archive}")
for raw in versions:
    if tuple(int(part) for part in raw.split(".")) > (15, 0):
        raise SystemExit(
            f"archive member requires macOS {raw}, newer than macOS 15.0: {archive}"
        )

data = archive.read_bytes()
if not data.startswith(b"!<arch>\n"):
    raise SystemExit(f"invalid static archive header: {archive}")
offset = 8
while offset < len(data):
    header = data[offset : offset + 60]
    if len(header) != 60 or header[58:60] != b"`\n":
        raise SystemExit(f"invalid static archive member header: {archive}")
    timestamp = int(header[16:28].decode("ascii").strip() or "0")
    owner = int(header[28:34].decode("ascii").strip() or "0")
    group = int(header[34:40].decode("ascii").strip() or "0")
    mode = header[40:48].decode("ascii").strip()
    size = int(header[48:58].decode("ascii").strip())
    raw_name = header[:16].decode("ascii").strip()
    name = raw_name
    if raw_name.startswith("#1/"):
        name_size = int(raw_name[3:])
        name = data[offset + 60 : offset + 60 + name_size].rstrip(b"\0").decode(
            "utf-8", errors="replace"
        )
    expected_mode = "100644" if name.startswith("__.SYMDEF") else "644"
    if (timestamp, owner, group) != (0, 0, 0) or mode != expected_mode:
        raise SystemExit(f"archive member metadata is not deterministic: {archive}")
    offset += 60 + size + (size % 2)
if offset != len(data):
    raise SystemExit(f"invalid static archive size: {archive}")
PY
}

validate_macos_dylib() {
  local library="$1"
  local metadata minos
  metadata="$("$VTOOL_BIN" -show-build "$library" 2>/dev/null)"
  printf '%s\n' "$metadata" | /usr/bin/grep -Eq '^[[:space:]]*platform[[:space:]]+MACOS$' || \
    die "not a macOS object: $library"
  minos="$(printf '%s\n' "$metadata" | /usr/bin/awk '$1 == "minos" {print $2; exit}')"
  [ -n "$minos" ] || die "could not read the macOS deployment target: $library"
  "$PYTHON_BIN" - "$library" "$minos" <<'PY'
import sys

path, raw = sys.argv[1:]
if tuple(int(part) for part in raw.split(".")) > (15, 0):
    raise SystemExit(f"dependency requires macOS {raw}, newer than macOS 15.0: {path}")
PY
}

normalize_and_validate_outputs() {
  local library="$STAGE/lib/libomp.dylib"
  rm -rf \
    "${STAGE:?}/bin" \
    "$STAGE/share/doc" \
    "$STAGE/share/man" \
    "$STAGE/lib/pkgconfig"
  find "$STAGE" -type d -empty -delete
  normalize_boost_configs

  [ -f "$library" ] && [ ! -L "$library" ] || die "source-built libomp.dylib is missing"
  "$INSTALL_NAME_TOOL_BIN" -id @rpath/libomp.dylib "$library"
  "$CODESIGN_BIN" --force --sign - --timestamp=none "$library"

  local dylibs
  dylibs="$(find "$STAGE" -type f -name '*.dylib' -print | LC_ALL=C sort)"
  [ "$dylibs" = "$library" ] || die "unexpected shared library entered COLMAP support prefix"

  local required
  for required in \
    libboost_atomic.a \
    libboost_chrono.a \
    libboost_container.a \
    libboost_date_time.a \
    libboost_exception.a \
    libboost_graph.a \
    libboost_program_options.a \
    libboost_thread.a \
    libgflags.a \
    libglog.a; do
    [ -f "$STAGE/lib/$required" ] && [ ! -L "$STAGE/lib/$required" ] || \
      die "required static library is missing: $required"
  done
  local static_count
  static_count="$(find "$STAGE/lib" -maxdepth 1 -type f -name '*.a' -print | wc -l | tr -d ' ')"
  [ "$static_count" = "10" ] || die "unexpected static library entered COLMAP support prefix"

  if find "$STAGE" -type l -print | /usr/bin/grep -q .; then
    die "symlink survived COLMAP support installation"
  fi
  while IFS= read -r required; do
    validate_static_archive "$required"
  done < <(find "$STAGE/lib" -maxdepth 1 -type f -name '*.a' -print | LC_ALL=C sort)

  "$LIPO_BIN" -info "$library" | /usr/bin/grep -Eq 'architecture: arm64$' || \
    die "libomp is not thin arm64"
  validate_macos_dylib "$library"
  [ "$("$OTOOL_BIN" -D "$library" | tail -n 1)" = "@rpath/libomp.dylib" ] || \
    die "libomp install name is not portable"
  while IFS= read -r required; do
    case "$required" in
      @rpath/libomp.dylib|/usr/lib/*|/System/Library/*) ;;
      *) die "libomp has a non-system dependency: $required" ;;
    esac
  done < <("$OTOOL_BIN" -L "$library" | /usr/bin/awk 'NR > 1 {print $1}')
  "$CODESIGN_BIN" --verify --strict "$library" || die "libomp code signature is invalid"

  if "$RG_BIN" -a -n -F "$ROOT" "$STAGE" >/dev/null || \
    "$RG_BIN" -a -n -F "$WORK" "$STAGE" >/dev/null; then
    die "build path leaked into COLMAP support prefix"
  fi
  if "$RG_BIN" -a -n -- '/opt/homebrew/|/usr/local/' "$STAGE" >/dev/null; then
    die "Homebrew dependency entered the build"
  fi
}

stage_licenses() {
  local destination="$STAGE/licenses/COLMAPSupport"
  mkdir -p "$destination"
  install -m 0644 "$SOURCES/boost/LICENSE_1_0.txt" "$destination/Boost-LICENSE_1_0.txt"
  install -m 0644 "$SOURCES/gflags/COPYING.txt" "$destination/gflags-COPYING.txt"
  install -m 0644 "$SOURCES/glog/COPYING" "$destination/glog-COPYING"
  install -m 0644 "$SOURCES/libomp/openmp/LICENSE.TXT" "$destination/OpenMP-LICENSE.txt"
}

normalize_install_metadata() {
  "$PYTHON_BIN" - "$STAGE" "$NORMALIZED_MTIME_EPOCH" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
epoch_ns = int(sys.argv[2]) * 1_000_000_000
owner_uid = os.getuid()
owner_gid = os.getgid()
paths = sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())

for path in paths:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        if stat.S_ISDIR(metadata.st_mode):
            continue
        raise SystemExit(f"unsupported install entry: {path}")
    mode = 0o755 if path.suffix == ".dylib" else 0o644
    os.chown(path, owner_uid, owner_gid, follow_symlinks=False)
    os.chmod(path, mode, follow_symlinks=False)
    os.utime(path, ns=(epoch_ns, epoch_ns), follow_symlinks=False)

for path in sorted(
    (item for item in paths if item.is_dir() and not item.is_symlink()),
    key=lambda item: len(item.parts),
    reverse=True,
):
    os.chown(path, owner_uid, owner_gid, follow_symlinks=False)
    os.chmod(path, 0o755, follow_symlinks=False)
    os.utime(path, ns=(epoch_ns, epoch_ns), follow_symlinks=False)

os.chown(root, owner_uid, owner_gid, follow_symlinks=False)
os.chmod(root, 0o755, follow_symlinks=False)
os.utime(root, ns=(epoch_ns, epoch_ns), follow_symlinks=False)
PY
  "$XATTR_BIN" -c -r "$STAGE"
}

stage_receipt() {
  "$PYTHON_BIN" - \
    "$LOCK" "$STAGE" "$FROZEN_FREEZER_SHA256" "$FROZEN_WRAPPER_SHA256" \
    "$FROZEN_IMPLEMENTATION_SHA256" "$EXTRACTOR" "$FROZEN_PROMOTER_SHA256" \
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$CMAKE_BIN" "$CODESIGN_BIN" \
    "$CURL_BIN" "$INSTALL_NAME_TOOL_BIN" "$LD_BIN" "$LIPO_BIN" "$LOCKF_BIN" \
    "$NINJA_BIN" "$OTOOL_BIN" "$PYTHON_BIN" "$RANLIB_BIN" "$RG_BIN" \
    "$SHASUM_BIN" "$VTOOL_BIN" "$XATTR_BIN" "$XCODEBUILD_BIN" "$XCRUN_BIN" \
    "$MACOS_SDK_VERSION" "$MACOS_SDK/SDKSettings.json" \
    "$NORMALIZED_MTIME_EPOCH" <<'PY'
import hashlib
import json
import stat
import subprocess
import sys
from pathlib import Path

(
    lock_raw,
    root_raw,
    freezer_sha256,
    wrapper_sha256,
    implementation_sha256,
    extractor_raw,
    promoter_sha256,
    ar_raw,
    clang_raw,
    clangxx_raw,
    cmake_raw,
    codesign_raw,
    curl_raw,
    install_name_tool_raw,
    ld_raw,
    lipo_raw,
    lockf_raw,
    ninja_raw,
    otool_raw,
    python_raw,
    ranlib_raw,
    ripgrep_raw,
    shasum_raw,
    vtool_raw,
    xattr_raw,
    xcodebuild_raw,
    xcrun_raw,
    sdk_version,
    sdk_settings_raw,
    normalized_mtime_raw,
) = sys.argv[1:]
lock_path = Path(lock_raw)
root = Path(root_raw)
extractor = Path(extractor_raw)
cmake = Path(cmake_raw)
ninja = Path(ninja_raw)
ripgrep = Path(ripgrep_raw)
sdk_settings = Path(sdk_settings_raw)
normalized_mtime_epoch = int(normalized_mtime_raw)
lock = json.loads(lock_path.read_text(encoding="utf-8"))
names = ("boost", "gflags", "glog", "libomp")
linkage = {
    "boost": "static",
    "gflags": "static",
    "glog": "static",
    "libomp": "shared",
}
license_files = {
    "boost": ["licenses/COLMAPSupport/Boost-LICENSE_1_0.txt"],
    "gflags": ["licenses/COLMAPSupport/gflags-COPYING.txt"],
    "glog": ["licenses/COLMAPSupport/glog-COPYING"],
    "libomp": ["licenses/COLMAPSupport/OpenMP-LICENSE.txt"],
}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command_version(command: list[str]) -> str:
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return " | ".join(line.strip() for line in result.stdout.splitlines() if line.strip())


dependencies = {}
for name in names:
    entry = lock["dependencies"][name]
    dependencies[name] = {
        "source_url": entry["source"]["url"],
        "source_sha256": entry["source"]["sha256"],
        "source_version": entry["version"],
        "license": entry["license"],
        "license_files": license_files[name],
        "linkage": linkage[name],
    }

tool_paths = {
    "ar": Path(ar_raw),
    "clang": Path(clang_raw),
    "clangxx": Path(clangxx_raw),
    "cmake": cmake,
    "codesign": Path(codesign_raw),
    "curl": Path(curl_raw),
    "install_name_tool": Path(install_name_tool_raw),
    "ld": Path(ld_raw),
    "lipo": Path(lipo_raw),
    "lockf": Path(lockf_raw),
    "ninja": ninja,
    "otool": Path(otool_raw),
    "python": Path(python_raw),
    "ranlib": Path(ranlib_raw),
    "ripgrep": ripgrep,
    "shasum": Path(shasum_raw),
    "vtool": Path(vtool_raw),
    "xattr": Path(xattr_raw),
    "xcodebuild": Path(xcodebuild_raw),
    "xcrun": Path(xcrun_raw),
}

libraries = {}
for path in sorted((root / "lib").glob("*")):
    if path.is_file() and path.suffix in {".a", ".dylib"}:
        libraries[path.relative_to(root).as_posix()] = file_sha256(path)

tree = hashlib.sha256()
paths = [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())]
for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    if relative == "build_info.json":
        continue
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISDIR(metadata.st_mode):
        kind = "directory"
        content = ""
    elif stat.S_ISREG(metadata.st_mode):
        kind = "file"
        content = file_sha256(path)
    else:
        raise SystemExit(f"unsupported install entry: {path}")
    tree.update(relative.encode("utf-8"))
    tree.update(b"\0")
    tree.update(kind.encode("ascii"))
    tree.update(b"\0")
    tree.update(f"{mode:o}".encode("ascii"))
    tree.update(b"\0")
    tree.update(str(metadata.st_mtime_ns).encode("ascii"))
    tree.update(b"\0")
    tree.update(content.encode("ascii"))
    tree.update(b"\0")

payload = {
    "schema_version": 1,
    "toolchain_name": "colmap-support",
    "deployment_target": "macOS 15.0",
    "architecture": "arm64",
    "source_date_epoch": 0,
    "normalized_mtime_epoch": normalized_mtime_epoch,
    "ownership_policy": "invoking-build-user-and-primary-group",
    "control_freezer_sha256": freezer_sha256,
    "builder_sha256": wrapper_sha256,
    "builder_implementation_sha256": implementation_sha256,
    "source_lock_sha256": file_sha256(lock_path),
    "extractor_sha256": file_sha256(extractor),
    "promoter_sha256": promoter_sha256,
    "build_tools": {
        "clang": command_version([clang_raw, "--version"]).split(" | ", 1)[0],
        "cmake": command_version([str(cmake), "--version"]).split(" | ", 1)[0],
        "macos_sdk": sdk_version,
        "ninja": command_version([str(ninja), "--version"]),
        "python": command_version([python_raw, "--version"]),
        "ripgrep": command_version([str(ripgrep), "--version"]).split(" | ", 1)[0],
        "xcode": command_version([xcodebuild_raw, "-version"]),
    },
    "build_tool_sha256": {
        name: file_sha256(path) for name, path in sorted(tool_paths.items())
    },
    "macos_sdk_settings_sha256": file_sha256(sdk_settings),
    "dependencies": dependencies,
    "build_options": {
        "boost": [
            "link=static",
            "runtime-link=shared",
            "cxxstd=17",
            "ignore-site-config",
        ],
        "cmake": [
            "CMAKE_OSX_ARCHITECTURES=arm64",
            "CMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "CMAKE_OSX_SYSROOT=macosx",
            "CMAKE_FIND_USE_PACKAGE_REGISTRY=OFF",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
        ],
        "openmp": [
            "LIBOMP_ENABLE_SHARED=ON",
            "LIBOMP_USE_ITT_NOTIFY=OFF",
            "OPENMP_ENABLE_LIBOMPTARGET=OFF",
        ],
        "reproducibility": [
            "SOURCE_DATE_EPOCH=0",
            "ZERO_AR_DATE=1",
            "checkout-prefix=/easysplat-source",
            "install-mtime=2000-01-01T00:00:00Z",
            "regular-mode=0644",
            "dylib-and-directory-mode=0755",
            "ownership-policy=invoking-build-user-and-primary-group",
            "extended-attributes=none",
            "umask=022",
        ],
    },
    "library_sha256": dict(sorted(libraries.items())),
    "install_tree_sha256": tree.hexdigest(),
}
(root / "build_info.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

validate_receipt() {
  "$PYTHON_BIN" - \
    "$STAGE" "$FROZEN_FREEZER_SHA256" "$FROZEN_WRAPPER_SHA256" \
    "$FROZEN_IMPLEMENTATION_SHA256" \
    "$LOCK" "$EXTRACTOR" "$FROZEN_PROMOTER_SHA256" \
    "$NORMALIZED_MTIME_EPOCH" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
freezer_sha256 = sys.argv[2]
wrapper_sha256 = sys.argv[3]
implementation_sha256 = sys.argv[4]
source_lock = Path(sys.argv[5])
extractor = Path(sys.argv[6])
promoter_sha256 = sys.argv[7]
normalized_mtime_epoch = int(sys.argv[8])
receipt = json.loads((root / "build_info.json").read_text(encoding="utf-8"))


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


expected_digests = {
    "control_freezer_sha256": freezer_sha256,
    "builder_sha256": wrapper_sha256,
    "builder_implementation_sha256": implementation_sha256,
    "promoter_sha256": promoter_sha256,
}
for field, expected in expected_digests.items():
    if receipt.get(field) != expected:
        raise SystemExit(f"{field} does not match the executed build input")
expected_paths = {
    "source_lock_sha256": source_lock,
    "extractor_sha256": extractor,
}
for field, path in expected_paths.items():
    if receipt.get(field) != file_sha256(path):
        raise SystemExit(f"{field} does not match the current build input")
for relative, expected in receipt["library_sha256"].items():
    if file_sha256(root / relative) != expected:
        raise SystemExit(f"library hash mismatch in build_info.json: {relative}")
if receipt.get("normalized_mtime_epoch") != normalized_mtime_epoch:
    raise SystemExit("normalized_mtime_epoch does not match the build contract")
if receipt.get("ownership_policy") != "invoking-build-user-and-primary-group":
    raise SystemExit("ownership_policy does not match the build contract")
if "normalized_owner_uid" in receipt or "normalized_owner_gid" in receipt:
    raise SystemExit("build_info.json contains host-specific numeric ownership")

for path in [root, *sorted(root.rglob("*"))]:
    metadata = path.lstat()
    if stat.S_ISDIR(metadata.st_mode):
        expected_mode = 0o755
    elif stat.S_ISREG(metadata.st_mode):
        expected_mode = 0o755 if path.suffix == ".dylib" else 0o644
    else:
        raise SystemExit(f"unsupported install entry: {path}")
    if stat.S_IMODE(metadata.st_mode) != expected_mode:
        raise SystemExit(f"noncanonical install mode: {path}")
    if (metadata.st_uid, metadata.st_gid) != (os.getuid(), os.getgid()):
        raise SystemExit(f"noncanonical install ownership: {path}")
    if metadata.st_mtime_ns != normalized_mtime_epoch * 1_000_000_000:
        raise SystemExit(f"noncanonical install modification time: {path}")

tree = hashlib.sha256()
paths = [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())]
for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    if relative == "build_info.json":
        continue
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISDIR(metadata.st_mode):
        kind = "directory"
        content = ""
    elif stat.S_ISREG(metadata.st_mode):
        kind = "file"
        content = file_sha256(path)
    else:
        raise SystemExit(f"unsupported install entry: {path}")
    tree.update(relative.encode("utf-8"))
    tree.update(b"\0")
    tree.update(kind.encode("ascii"))
    tree.update(b"\0")
    tree.update(f"{mode:o}".encode("ascii"))
    tree.update(b"\0")
    tree.update(str(metadata.st_mtime_ns).encode("ascii"))
    tree.update(b"\0")
    tree.update(content.encode("ascii"))
    tree.update(b"\0")
if tree.hexdigest() != receipt["install_tree_sha256"]:
    raise SystemExit("install_tree_sha256 does not match final bytes")
PY
  if "$XATTR_BIN" -l -r "$STAGE" | /usr/bin/grep -q .; then
    die "extended attributes survived COLMAP support normalization"
  fi
}

verify_artifacts() {
  EASYSPLAT_COLMAP_SUPPORT_ROOT="$STAGE" \
    "$PYTHON_BIN" "$TESTS" ArtifactTests
}

promote_install() {
  local journal="$STAGE.promotion-state" tree_receipt
  tree_receipt="$(run_promoter --tree-receipt \
    "$STAGE" "$INSTALL_STAGE_DEVICE" "$INSTALL_STAGE_INODE")" || \
    die "could not bind the validated COLMAP support tree"
  STAGE_CLEANUP_ALLOWED=0
  run_promoter "$STAGE" "$INSTALL" "$tree_receipt" || \
    die "could not atomically promote COLMAP support prefix; recovery state preserved"
  run_promoter --commit "$journal" || \
    die "could not finalize COLMAP support promotion; recovery state preserved"
}

if [ "$#" -ne 0 ]; then
  die "usage: build_colmap_support.sh"
fi

preflight
acquire_build_lock
recover_stale_promotions
rm -rf "$BUILDS" "$LOGS" "$BUILD_HOME" "$BUILD_TMP"
mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILDS" "$LOGS" "$BUILD_HOME" "$BUILD_TMP"
create_owned_install_stage
sanitize_environment
build_boost
build_gflags
build_glog
build_libomp
audit_compile_commands
normalize_and_validate_outputs
stage_licenses
normalize_install_metadata
stage_receipt
normalize_install_metadata
validate_receipt
verify_artifacts
promote_install

echo "COLMAP support installed to: $INSTALL"
