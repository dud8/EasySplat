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
    "OpenImageIO build failed: implementation received inherited shell functions" >&2
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
WORK="$ROOT/Toolchains/build/openimageio"
DOWNLOADS="$WORK/downloads"
SOURCES="$WORK/sources"
BUILDS="$WORK/builds"
LOGS="$WORK/logs"
INSTALL="$WORK/install"
STAGE="$WORK/install.stage.$$"
BUILD_LOCK="$WORK/.build.lock"
SCRATCH=""
BUILD_HOME=""
BUILD_TMP=""
LOCK="$ROOT/scripts/toolchain/openimageio-lock.json"
EXTRACTOR="$ROOT/scripts/toolchain/safe_extract_source.py"
TESTS="$ROOT/scripts/toolchain/tests/test_openimageio_builder.py"
SUPPORT="$ROOT/Toolchains/build/colmap-support/install"
DEPLOYMENT_TARGET="15.0"
NORMALIZED_MTIME_EPOCH="946684800"
LOCK_OWNED=0
INSTALL_STAGE_OWNED=0
INSTALL_STAGE_DEVICE=""
INSTALL_STAGE_INODE=""
MODE="build"
MODE_PREFIX=""

AR_BIN=""
CLANG_BIN=""
CLANGXX_BIN=""
CMAKE_BIN=""
CHOWN_BIN="/usr/sbin/chown"
CURL_BIN="/usr/bin/curl"
LD_BIN=""
LIPO_BIN=""
LOCKF_BIN="/usr/bin/lockf"
NM_BIN=""
NINJA_BIN=""
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
SUPPORT_RECEIPT_SHA256=""
SUPPORT_TREE_SHA256=""
PREPARED_SOURCE=""
OIIO_SOURCE=""
FMT_SOURCE=""
ROBIN_SOURCE=""
IMATH_SOURCE=""
JPEG_SOURCE=""
PNG_SOURCE=""

die() {
  echo "OpenImageIO build failed: $*" >&2
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
  if [ "$MODE" = "build" ] && [ "$STAGE_CLEANUP_ALLOWED" = "1" ] && \
    [ "$INSTALL_STAGE_OWNED" = "1" ]; then
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
        "OpenImageIO build cleanup preserved an unverified staged install: $STAGE" >&2
    fi
  fi
  if [ -n "$SCRATCH" ]; then
    rm -rf -- "$SCRATCH"
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
  )" || die "could not create and bind OpenImageIO install stage"
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
    die "OpenImageIO install stage identity is malformed"
  INSTALL_STAGE_DEVICE="${identity%%:*}"
  INSTALL_STAGE_INODE="${identity#*:}"
  INSTALL_STAGE_OWNED=1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

parse_arguments() {
  if [ "$#" = "0" ]; then
    MODE="build"
    return
  fi
  case "$#:$1" in
    2:--validate-only)
      MODE="validate"
      MODE_PREFIX="$2"
      ;;
    2:--compare-prefix)
      MODE="compare"
      MODE_PREFIX="$2"
      ;;
    *)
      die "usage: build_openimageio.sh [--validate-only <absolute-prefix> | --compare-prefix <absolute-prefix>]"
      ;;
  esac
  if [ -n "$MODE_PREFIX" ]; then
    case "$MODE_PREFIX" in
      /*) ;;
      *) die "validation prefix must be absolute" ;;
    esac
    [ -d "$MODE_PREFIX" ] && [ ! -L "$MODE_PREFIX" ] || \
      die "validation prefix is not a regular directory: $MODE_PREFIX"
    MODE_PREFIX="$(cd "$MODE_PREFIX" && pwd -P)"
  fi
}

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
  validate_build_lock || die "OpenImageIO build lock is unsafe"
  "$LOCKF_BIN" -s -t 0 9 || die "another OpenImageIO build is running"
  LOCK_OWNED=1
  validate_build_lock || die "OpenImageIO build lock changed during acquisition"
}

initialize_private_workdirs() {
  mkdir -p "$WORK"
  SCRATCH="$(/usr/bin/mktemp -d "$WORK/scratch.XXXXXXXX")" || \
    die "could not create private OpenImageIO scratch directory"
  BUILD_HOME="$SCRATCH/home"
  BUILD_TMP="$SCRATCH/tmp"
  mkdir -p "$BUILD_HOME" "$BUILD_TMP"
}

recover_stale_promotions() {
  local journal path
  for journal in "$WORK"/install.stage.*.promotion-state; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    run_promoter --recover "$journal" || \
      die "could not recover interrupted OpenImageIO promotion: $journal"
  done
  for path in "$WORK"/install.stage.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    case "$path" in
      *.promotion-state) continue ;;
    esac
    die "ambiguous staged install requires recovery: $path"
  done
}

remove_stale_workdirs() {
  local path
  recover_stale_promotions
  for path in "$WORK"/install.pruned.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    rm -rf "$path"
  done
}

preflight() {
  [ "$(uname -m)" = "arm64" ] || die "must run natively on Apple Silicon arm64"
  [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || \
    die "Rosetta is unsupported"
  case "$ROOT" in
    *[[:space:]]*) die "checkout path contains whitespace; move the source checkout before building" ;;
  esac
  [ -s "$LOCK" ] || die "openimageio-lock.json is missing"
  [ -x "$EXTRACTOR" ] || die "safe source extractor is missing or not executable"
  [ -f "$TESTS" ] || die "OpenImageIO builder tests are missing"
  [ -d "$SUPPORT" ] && [ ! -L "$SUPPORT" ] || \
    die "promoted COLMAP support prefix is missing"
  for command in \
    /usr/bin/curl \
    /usr/bin/lockf \
    /usr/bin/shasum \
    /usr/bin/xattr \
    /usr/bin/xcode-select \
    /usr/bin/xcrun \
    "$CHOWN_BIN"; do
    [ -x "$command" ] || die "required system tool is missing: $command"
  done

  CMAKE_BIN="$BOOTSTRAP_CMAKE_BIN"
  NINJA_BIN="$BOOTSTRAP_NINJA_BIN"
  RG_BIN="$BOOTSTRAP_RG_BIN"
  for command in "$CMAKE_BIN" "$NINJA_BIN" "$RG_BIN"; do
    [ -x "$command" ] || die "required build tool is missing: $command"
  done

  XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  [ -d "$XCODE_DEVELOPER_DIR" ] || die "selected Xcode Developer directory is missing"
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
  [ -d "$MACOS_SDK" ] || die "selected macOS SDK is missing: $MACOS_SDK"
  [ -f "$MACOS_SDK/SDKSettings.json" ] || die "selected macOS SDK has no SDKSettings.json"
  for command in \
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$LD_BIN" "$LIPO_BIN" "$NM_BIN" \
    "$OTOOL_BIN" "$PYTHON_BIN" "$RANLIB_BIN" "$STRINGS_BIN" "$VTOOL_BIN" \
    "$XCODEBUILD_BIN"; do
    [ -x "$command" ] || die "selected Xcode tool is missing: $command"
  done
}

sanitize_environment() {
  unset \
    AR ARCHFLAGS ASFLAGS BASH_ENV CDPATH CCC_OVERRIDE_OPTIONS CC CFLAGS \
    C_INCLUDE_PATH CPLUS_INCLUDE_PATH COMPILER_PATH CMAKE_APPBUNDLE_PATH \
    CMAKE_BUILD_PARALLEL_LEVEL CMAKE_BUILD_TYPE CMAKE_C_COMPILER_LAUNCHER \
    CMAKE_CROSSCOMPILING_EMULATOR CMAKE_FRAMEWORK_PATH CMAKE_GENERATOR \
    CMAKE_GENERATOR_INSTANCE CMAKE_GENERATOR_PLATFORM CMAKE_GENERATOR_TOOLSET \
    CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_OSX_SYSROOT \
    CMAKE_PREFIX_PATH CMAKE_PROJECT_INCLUDE CMAKE_PROJECT_INCLUDE_BEFORE \
    CMAKE_PROJECT_TOP_LEVEL_INCLUDES CMAKE_TOOLCHAIN_FILE CPATH CPPFLAGS CXX \
    CXXFLAGS CMAKE_CXX_COMPILER_LAUNCHER DESTDIR DEVELOPER_DIR ENV GCC_EXEC_PREFIX \
    GLOBIGNORE DYLD_FALLBACK_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH \
    DYLD_FRAMEWORK_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH LD LD_LIBRARY_PATH \
    LDFLAGS LIBRARY_PATH MAKEFLAGS NM OBJCFLAGS OBJCXXFLAGS OBJC_INCLUDE_PATH \
    OBJCPLUS_INCLUDE_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PYTHONHOME PYTHONINSPECT \
    PYTHONPATH PYTHONSTARTUP PYTHONWARNINGS Python3_ROOT_DIR Python_ROOT_DIR \
    RANLIB RCFLAGS SDKROOT STRIP VIRTUAL_ENV CONDA_PREFIX || true

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
  export MACOSX_DEPLOYMENT_TARGET=15.0
  export ZERO_AR_DATE=1
  export SOURCE_DATE_EPOCH=0
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_LIBDIR=/dev/null

  COMMON_C_FLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $MACOS_SDK -O3 -DNDEBUG -g0 -ffile-prefix-map=$ROOT=. -fdebug-prefix-map=$ROOT=. -fmacro-prefix-map=$ROOT=."
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
expected_names = {
    "openimageio", "fmt", "robin-map", "imath", "libjpeg-turbo", "libpng"
}
if payload.get("schemaVersion") != 1 or set(payload.get("dependencies", {})) != expected_names:
    raise SystemExit("unsupported or incomplete openimageio-lock.json schema")
try:
    entry = payload["dependencies"][name]
    values = (entry["version"], entry["source"]["url"], entry["source"]["sha256"], entry["license"])
except (KeyError, TypeError) as error:
    raise SystemExit(f"incomplete source lock entry for {name}: {error}") from error
if not all(isinstance(value, str) and value for value in values):
    raise SystemExit(f"invalid source lock value for {name}")
version, url, digest, license_name = values
if not url.startswith("https://"):
    raise SystemExit(f"non-HTTPS source URL for {name}")
if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit(f"invalid source SHA-256 for {name}")
if any(character in "".join(values) for character in "\t\r\n"):
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
  "$CURL_BIN" --proto '=https' --tlsv1.2 --fail --location \
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

install_tiff_free_exif_compatibility() {
  "$PYTHON_BIN" - "$OIIO_SOURCE" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
path = root / "src/include/OpenImageIO/tiffutils.h"
text = path.read_text(encoding="utf-8")
start_marker = '''extern "C" {
#include "tiff.h"
}

#include <OpenImageIO/imageio.h>


#ifdef TIFF_VERSION_BIG
// In old versions of TIFF, this was defined in tiff.h.  It's gone from
// "BIG TIFF" (libtiff 4.x), so we just define it here.

struct TIFFHeader {
    uint16_t tiff_magic;  /* magic number (defines byte order) */
    uint16_t tiff_version;/* TIFF version number */
    uint32_t tiff_diroff; /* byte offset to first directory */
};

struct TIFFDirEntry {
    uint16_t tdir_tag;    /* tag ID */
    uint16_t tdir_type;   /* data type -- see TIFFDataType enum */
    uint32_t tdir_count;  /* number of items; length in spec */
    uint32_t tdir_offset; /* byte offset to field data */
};
#endif
'''
replacement = '''#include <cstdint>

#include <OpenImageIO/imageio.h>


// TIFF-free EXIF compatibility types. These are the TIFF 6.0 scalar codes,
// classic directory layouts, and tag identifiers consumed by OIIO's EXIF
// parser. They do not provide TIFF image input or output support.
#define TIFF_VERSION_BIG 43

enum TIFFDataType {
    TIFF_NOTYPE = 0,
    TIFF_BYTE = 1,
    TIFF_ASCII = 2,
    TIFF_SHORT = 3,
    TIFF_LONG = 4,
    TIFF_RATIONAL = 5,
    TIFF_SBYTE = 6,
    TIFF_UNDEFINED = 7,
    TIFF_SSHORT = 8,
    TIFF_SLONG = 9,
    TIFF_SRATIONAL = 10,
    TIFF_FLOAT = 11,
    TIFF_DOUBLE = 12,
    TIFF_IFD = 13,
    TIFF_LONG8 = 16,
    TIFF_SLONG8 = 17,
    TIFF_IFD8 = 18,
};

struct TIFFHeader {
    std::uint16_t tiff_magic;
    std::uint16_t tiff_version;
    std::uint32_t tiff_diroff;
};

struct TIFFDirEntry {
    std::uint16_t tdir_tag;
    std::uint16_t tdir_type;
    std::uint32_t tdir_count;
    std::uint32_t tdir_offset;
};

static_assert(sizeof(TIFFHeader) == 8, "classic EXIF header layout changed");
static_assert(sizeof(TIFFDirEntry) == 12, "classic EXIF directory layout changed");

enum : int {
    TIFFTAG_IMAGEWIDTH = 256,
    TIFFTAG_IMAGELENGTH = 257,
    TIFFTAG_BITSPERSAMPLE = 258,
    TIFFTAG_COMPRESSION = 259,
    TIFFTAG_PHOTOMETRIC = 262,
    TIFFTAG_DOCUMENTNAME = 269,
    TIFFTAG_IMAGEDESCRIPTION = 270,
    TIFFTAG_MAKE = 271,
    TIFFTAG_MODEL = 272,
    TIFFTAG_ORIENTATION = 274,
    TIFFTAG_SAMPLESPERPIXEL = 277,
    TIFFTAG_XRESOLUTION = 282,
    TIFFTAG_YRESOLUTION = 283,
    TIFFTAG_PLANARCONFIG = 284,
    TIFFTAG_PAGENAME = 285,
    TIFFTAG_RESOLUTIONUNIT = 296,
    TIFFTAG_PAGENUMBER = 297,
    TIFFTAG_SOFTWARE = 305,
    TIFFTAG_DATETIME = 306,
    TIFFTAG_ARTIST = 315,
    TIFFTAG_HOSTCOMPUTER = 316,
    TIFFTAG_YCBCRSUBSAMPLING = 530,
    TIFFTAG_YCBCRPOSITIONING = 531,
    TIFFTAG_XMLPACKET = 700,
    TIFFTAG_PIXAR_TEXTUREFORMAT = 33302,
    TIFFTAG_PIXAR_WRAPMODES = 33303,
    TIFFTAG_PIXAR_FOVCOT = 33304,
    TIFFTAG_COPYRIGHT = 33432,
    TIFFTAG_EXIFIFD = 34665,
    TIFFTAG_GPSIFD = 34853,
    TIFFTAG_INTEROPERABILITYIFD = 40965,
    TIFFTAG_JPEGQUALITY = 65537,
    TIFFTAG_ZIPQUALITY = 65557,
};
'''
if text.count(start_marker) != 1:
    raise SystemExit("reviewed tiffutils.h libtiff dependency block changed upstream")
text = text.replace(start_marker, replacement, 1)
text = text.replace(
    "Given a TIFF data type code (defined in tiff.h)",
    "Given a TIFF data type code (defined above)",
    1,
)
path.write_text(text, encoding="utf-8")

xmp_path = root / "src/libOpenImageIO/xmp.cpp"
xmp_text = xmp_path.read_text(encoding="utf-8")
xmp_include = '''extern "C" {
#include "tiff.h"
}

'''
if xmp_text.count(xmp_include) != 1:
    raise SystemExit("reviewed xmp.cpp redundant libtiff include changed upstream")
xmp_path.write_text(xmp_text.replace(xmp_include, "", 1), encoding="utf-8")
PY
}

install_minimal_embedded_plugin_catalog() {
  "$PYTHON_BIN" - "$OIIO_SOURCE/src/libOpenImageIO/imageioplugin.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

declarations_start = text.index("PLUGENTRY(bmp);")
declarations_end = text.index("\n\n\n#endif  // defined(EMBED_PLUGINS)", declarations_start)
declarations = '''PLUGENTRY(jpeg);
PLUGENTRY(png);'''
text = text[:declarations_start] + declarations + text[declarations_end:]

catalog_start = text.index("// Declare the most commonly used formats we encounter first")
catalog_end_marker = '''#if !defined(DISABLE_ZFILE)
    DECLAREPLUG (zfile);
#endif
'''
catalog_end = text.index(catalog_end_marker, catalog_start) + len(catalog_end_marker)
catalog = '''// EasySplat embeds exactly the two supported image formats.
    DECLAREPLUG (jpeg);
    DECLAREPLUG (png);
'''
text = text[:catalog_start] + catalog + text[catalog_end:]

if text.count("PLUGENTRY(jpeg);") != 1 or text.count("PLUGENTRY(png);") != 1:
    raise SystemExit("minimal embedded plugin declarations are not unique")
if text.count("DECLAREPLUG (jpeg);") != 1 or text.count("DECLAREPLUG (png);") != 1:
    raise SystemExit("minimal embedded plugin catalog is not unique")
path.write_text(text, encoding="utf-8")
PY
}

prepare_sources() {
  prepare_source openimageio
  OIIO_SOURCE="$PREPARED_SOURCE"
  install_tiff_free_exif_compatibility
  install_minimal_embedded_plugin_catalog
  prepare_source fmt
  FMT_SOURCE="$PREPARED_SOURCE"
  prepare_source robin-map
  ROBIN_SOURCE="$PREPARED_SOURCE"
  prepare_source imath
  IMATH_SOURCE="$PREPARED_SOURCE"
  prepare_source libjpeg-turbo
  JPEG_SOURCE="$PREPARED_SOURCE"
  prepare_source libpng
  PNG_SOURCE="$PREPARED_SOURCE"

  "$PYTHON_BIN" - "$OIIO_SOURCE" "$FMT_SOURCE" "$ROBIN_SOURCE" <<'PY'
import shutil
import sys
from pathlib import Path

oiio, fmt, robin = map(Path, sys.argv[1:])
external = oiio / "ext"
for name, source in (("fmt", fmt), ("robin-map", robin)):
    destination = external / name
    if destination.exists() or destination.is_symlink():
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink()
    shutil.copytree(source, destination, symlinks=False)

required_plugins = {'jpeg.imageio', 'png.imageio'}
plugin_directories = {path.name for path in (oiio / "src").glob("*.imageio")}
if not required_plugins.issubset(plugin_directories):
    raise SystemExit("required JPEG/PNG plugin source is missing")
for path in (oiio / "src").glob("*.imageio"):
    if path.name not in required_plugins:
        shutil.rmtree(path)

external_packages = oiio / "src/cmake/externalpackages.cmake"
text = external_packages.read_text(encoding="utf-8")
start = text.index("checked_find_package (ZLIB REQUIRED)")
end = text.index("# JPEG -- prefer JPEG-Turbo", start)
replacement = r'''checked_find_package (ZLIB REQUIRED)
set (USE_TIFF OFF CACHE BOOL "EasySplat excludes TIFF" FORCE)
set (USE_OPENEXR OFF CACHE BOOL "EasySplat excludes OpenEXR" FORCE)
set (ENABLE_JPEG ON CACHE BOOL "EasySplat embeds JPEG" FORCE)
set (ENABLE_PNG ON CACHE BOOL "EasySplat embeds PNG" FORCE)
checked_find_package (Imath CONFIG REQUIRED
                      VERSION_MIN 3.1
                      PRINT Imath_VERSION Imath_INCLUDE_DIRS)
if (NOT TARGET Imath::Imath)
    message (FATAL_ERROR "Pinned Imath target is missing")
endif ()
get_target_property (IMATH_INCLUDES Imath::Imath INTERFACE_INCLUDE_DIRECTORIES)
include_directories (BEFORE ${IMATH_INCLUDES})
set (OIIO_USING_IMATH 3)
set (OPENIMAGEIO_IMATH_TARGETS Imath::Imath)
set (OPENIMAGEIO_OPENEXR_TARGETS "")
set (OPENIMAGEIO_IMATH_DEPENDENCY_VISIBILITY "PUBLIC" CACHE STRING
     "Should we expose Imath library dependency as PUBLIC or PRIVATE")
set (OPENIMAGEIO_CONFIG_DO_NOT_FIND_IMATH OFF CACHE BOOL
     "Exclude find_dependency(Imath) from the exported OpenImageIOConfig.cmake")
set (OpenEXR_VERSION 0)
set (OPENEXR_INCLUDES "")
set (FOUND_OPENEXR_WITH_CONFIG 0)

'''
if "checked_find_package (TIFF REQUIRED" not in text[start:end]:
    raise SystemExit("reviewed TIFF/OpenEXR dependency block changed upstream")
external_packages.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
PY
  FMT_SOURCE="$OIIO_SOURCE/ext/fmt"
  ROBIN_SOURCE="$OIIO_SOURCE/ext/robin-map"
}

cmake_configure() {
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
    -DCMAKE_PREFIX_PATH="$STAGE;$SUPPORT" \
    '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF \
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_Git=TRUE \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DPython3_EXECUTABLE="$PYTHON_BIN" \
    "$@" 2>&1 | /usr/bin/tee "$log"
}

cmake_build_install() {
  local name="$1"
  local build="$BUILDS/$name"
  local log="$LOGS/$name.log"
  "$CMAKE_BIN" --build "$build" --target install \
    --parallel "$(sysctl -n hw.ncpu)" 2>&1 | /usr/bin/tee -a "$log"
}

build_imath() {
  cmake_configure imath "$IMATH_SOURCE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DIMATH_INSTALL=ON \
    -DIMATH_INSTALL_PKG_CONFIG=OFF \
    -DIMATH_INSTALL_SYM_LINK=OFF \
    -DIMATH_USE_CLANG_TIDY=OFF \
    -DPYTHON=OFF \
    -DPYBIND11=OFF \
    -DBUILD_WEBSITE=OFF
  cmake_build_install imath
}

build_jpeg() {
  cmake_configure libjpeg-turbo "$JPEG_SOURCE" \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DREQUIRE_SIMD=ON \
    -DWITH_SIMD=ON \
    -DWITH_TURBOJPEG=OFF \
    -DWITH_TOOLS=OFF \
    -DWITH_TESTS=OFF \
    -DWITH_FUZZ=OFF \
    -DWITH_JAVA=OFF \
    -DWITH_JPEG7=OFF \
    -DWITH_JPEG8=OFF
  cmake_build_install libjpeg-turbo
}

build_png() {
  cmake_configure libpng "$PNG_SOURCE" \
    -DPNG_SHARED=OFF \
    -DPNG_STATIC=ON \
    -DPNG_FRAMEWORK=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF \
    -DPNG_EXECUTABLES=OFF \
    -DPNG_HARDWARE_OPTIMIZATIONS=ON \
    -DPNG_ARM_NEON=on \
    -DPNG_BUILD_ZLIB=OFF \
    -Dld-version-script=OFF
  cmake_build_install libpng
}

build_openimageio() {
  cmake_configure openimageio "$OIIO_SOURCE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLINKSTATIC=ON \
    -DEMBEDPLUGINS=ON \
    -DOIIO_BUILD_TOOLS=OFF \
    -DOIIO_BUILD_TESTS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOCS=OFF \
    -DINSTALL_DOCS=OFF \
    -DINSTALL_FONTS=OFF \
    -DUSE_PYTHON=OFF \
    -DBUILD_MISSING_DEPS=OFF \
    -DBUILD_MISSING_FMT=OFF \
    -DBUILD_FMT_FORCE=ON \
    -DBUILD_MISSING_ROBINMAP=OFF \
    -DBUILD_ROBINMAP_FORCE=ON \
    -DBUILD_FMT_VERSION=10.0.0 \
    -DBUILD_ROBINMAP_VERSION=0.6.2 \
    -DINTERNALIZE_FMT=ON \
    -DUSE_EXTERNAL_PUGIXML=OFF \
    -DUSE_STD_FILESYSTEM=ON \
    -DUSE_CCACHE=OFF \
    -DUSE_LIBJPEG-TURBO=ON \
    -DUSE_JPEG=ON \
    -DUSE_PNG=ON \
    -DUSE_TIFF=OFF \
    -DUSE_OPENEXR=OFF \
    -DENABLE_JPEG=ON \
    -DENABLE_PNG=ON \
    -DUSE_FREETYPE=OFF \
    -DUSE_OPENCOLORIO=OFF \
    -DUSE_OPENCV=OFF \
    -DUSE_TBB=OFF \
    -DUSE_DCMTK=OFF \
    -DUSE_FFMPEG=OFF \
    -DUSE_GIF=OFF \
    -DUSE_LIBHEIF=OFF \
    -DUSE_LIBRAW=OFF \
    -DUSE_OPENJPEG=OFF \
    -DUSE_OPENVDB=OFF \
    -DUSE_PTEX=OFF \
    -DUSE_WEBP=OFF \
    -DUSE_JXL=OFF \
    -DUSE_R3DSDK=OFF \
    -DUSE_NUKE=OFF \
    -DUSE_QT=OFF \
    -DOIIO_DISABLE_BOOST_STACKTRACE=ON \
    -DBoost_NO_BOOST_CMAKE=ON \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBOOST_ROOT="$SUPPORT" \
    -DBoost_ROOT="$SUPPORT" \
    -DBoost_INCLUDE_DIR="$SUPPORT/include" \
    -DImath_DIR="$STAGE/lib/cmake/Imath" \
    -Dlibjpeg-turbo_DIR="$STAGE/lib/cmake/libjpeg-turbo" \
    -DJPEG_ROOT="$STAGE" \
    -DPNG_ROOT="$STAGE" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_STANDARD_REQUIRED=ON
  cmake_build_install openimageio
}

cache_bool_is() {
  local cache="$1"
  local name="$2"
  local expected="$3"
  /usr/bin/grep -Eq "^${name}:BOOL=${expected}$" "$cache" || \
    die "CMake did not preserve ${name}=${expected} in $cache"
}

audit_configurations() {
  local imath_cache="$BUILDS/imath/CMakeCache.txt"
  local jpeg_cache="$BUILDS/libjpeg-turbo/CMakeCache.txt"
  local png_cache="$BUILDS/libpng/CMakeCache.txt"
  local oiio_cache="$BUILDS/openimageio/CMakeCache.txt"

  cache_bool_is "$imath_cache" BUILD_SHARED_LIBS OFF
  cache_bool_is "$imath_cache" BUILD_TESTING OFF
  cache_bool_is "$imath_cache" IMATH_INSTALL_PKG_CONFIG OFF
  cache_bool_is "$jpeg_cache" ENABLE_SHARED OFF
  cache_bool_is "$jpeg_cache" ENABLE_STATIC ON
  cache_bool_is "$jpeg_cache" WITH_TOOLS OFF
  cache_bool_is "$jpeg_cache" WITH_TESTS OFF
  cache_bool_is "$png_cache" PNG_SHARED OFF
  cache_bool_is "$png_cache" PNG_STATIC ON
  cache_bool_is "$png_cache" PNG_TESTS OFF
  cache_bool_is "$oiio_cache" BUILD_SHARED_LIBS OFF
  cache_bool_is "$oiio_cache" LINKSTATIC ON
  cache_bool_is "$oiio_cache" EMBEDPLUGINS ON
  cache_bool_is "$oiio_cache" OIIO_BUILD_TOOLS OFF
  cache_bool_is "$oiio_cache" OIIO_BUILD_TESTS OFF
  cache_bool_is "$oiio_cache" USE_PYTHON OFF
  cache_bool_is "$oiio_cache" USE_TIFF OFF
  cache_bool_is "$oiio_cache" USE_OPENEXR OFF
  cache_bool_is "$oiio_cache" ENABLE_JPEG ON
  cache_bool_is "$oiio_cache" ENABLE_PNG ON

  "$PYTHON_BIN" - \
    "$CLANG_BIN" "$MACOS_SDK" "$BUILDS" "$OIIO_SOURCE" <<'PY'
import json
import shlex
import sys
from pathlib import Path

compiler, sdk, builds_raw, oiio_raw = sys.argv[1:]
builds = Path(builds_raw)
oiio = Path(oiio_raw)
required_plugins = {"jpeg.imageio", "png.imageio"}
seen_plugins = set()
for database in sorted(builds.glob("*/compile_commands.json")):
    entries = json.loads(database.read_text(encoding="utf-8"))
    if not entries:
        raise SystemExit(f"empty compile database: {database}")
    for entry in entries:
        command = entry.get("command") or " ".join(entry.get("arguments", []))
        arguments = shlex.split(command)
        if not arguments or Path(arguments[0]).resolve() != Path(compiler).resolve():
            raise SystemExit(f"unselected compiler in {database}: {arguments[:1]}")
        for flag in ("-arch", "arm64", "-mmacosx-version-min=15.0", "-isysroot", sdk):
            if flag not in arguments:
                raise SystemExit(f"missing compile contract {flag!r}: {entry.get('file')}")
        if any(argument.startswith(("-march=native", "-mcpu=native")) for argument in arguments):
            raise SystemExit(f"host tuning leaked into compile command: {entry.get('file')}")
        if any(
            marker in argument
            for argument in arguments
            for marker in ("/opt/homebrew", "/usr/local", "Cellar", ".dylib")
        ):
            raise SystemExit(f"host dependency leaked into compile command: {entry.get('file')}")
        source = Path(entry.get("file", ""))
        try:
            relative = source.resolve().relative_to((oiio / "src").resolve())
        except (OSError, ValueError):
            continue
        if relative.parts and relative.parts[0].endswith(".imageio"):
            seen_plugins.add(relative.parts[0])
if seen_plugins != required_plugins:
    raise SystemExit(f"unexpected compiled image plugins: {sorted(seen_plugins)}")

link_dependency_fields = (
    "INCLUDES = ",
    "LINK_FLAGS = ",
    "LINK_LIBRARIES = ",
    "LINK_PATH = ",
)
for ninja in sorted(builds.glob("*/build.ninja")):
    for line_number, line in enumerate(ninja.read_text(encoding="utf-8").splitlines(), 1):
        value = line.lstrip()
        if not value.startswith(link_dependency_fields):
            continue
        if any(
            marker in value
            for marker in ("/opt/homebrew", "/usr/local", "Homebrew", "Cellar", "pkg-config", ".dylib")
        ):
            raise SystemExit(
                f"host or dynamic dependency leaked into {ninja}:{line_number}: {value}"
            )
PY
}

verify_support_prefix() {
  SUPPORT_RECEIPT_SHA256="$(sha256 "$SUPPORT/build_info.json")"
  SUPPORT_TREE_SHA256="$("$PYTHON_BIN" - "$SUPPORT" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
receipt_path = root / "build_info.json"
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
if receipt.get("schema_version") != 1 or receipt.get("toolchain_name") != "colmap-support":
    raise SystemExit("unsupported COLMAP support receipt")
if receipt.get("architecture") != "arm64" or receipt.get("deployment_target") != "macOS 15.0":
    raise SystemExit("COLMAP support architecture or deployment target mismatch")
boost = receipt.get("dependencies", {}).get("boost", {})
if boost.get("linkage") != "static" or boost.get("license") != "BSL-1.0":
    raise SystemExit("COLMAP support Boost provenance is incomplete")


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


for relative, expected in receipt.get("library_sha256", {}).items():
    path = root / relative
    if not path.is_file() or path.is_symlink() or file_sha256(path) != expected:
        raise SystemExit(f"COLMAP support library hash mismatch: {relative}")
for relative in (
    "include/boost/version.hpp",
    "lib/libboost_thread.a",
    "lib/libboost_atomic.a",
    "lib/libboost_chrono.a",
    "lib/libboost_date_time.a",
    "licenses/COLMAPSupport/Boost-LICENSE_1_0.txt",
):
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"required COLMAP support entry is missing: {relative}")

tree = hashlib.sha256()
paths = [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())]
for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    metadata = path.lstat()
    if (metadata.st_uid, metadata.st_gid) != (os.getuid(), os.getgid()):
        raise SystemExit(f"noncanonical COLMAP support ownership: {path}")
    if relative == "build_info.json":
        continue
    if stat.S_ISDIR(metadata.st_mode):
        kind, content = "directory", ""
    elif stat.S_ISREG(metadata.st_mode):
        kind, content = "file", file_sha256(path)
    else:
        raise SystemExit(f"unsafe COLMAP support entry: {path}")
    fields = (
        relative,
        kind,
        f"{stat.S_IMODE(metadata.st_mode):o}",
        str(metadata.st_mtime_ns),
        content,
    )
    for field in fields:
        tree.update(field.encode("utf-8"))
        tree.update(b"\0")
digest = tree.hexdigest()
if digest != receipt.get("install_tree_sha256"):
    raise SystemExit("COLMAP support tree digest mismatch")
if receipt.get("ownership_policy") != "invoking-build-user-and-primary-group":
    raise SystemExit("COLMAP support ownership policy is incompatible")
if "normalized_owner_uid" in receipt or "normalized_owner_gid" in receipt:
    raise SystemExit("COLMAP support receipt contains host-specific numeric ownership")
print(digest)
PY
)" || die "could not verify promoted COLMAP support prefix"
  [ -n "$SUPPORT_TREE_SHA256" ] || die "COLMAP support tree digest is empty"
  [ "$("$LIPO_BIN" -archs "$SUPPORT/lib/libboost_thread.a")" = "arm64" ] || \
    die "COLMAP support Boost thread archive is not thin arm64"
}

prune_install() {
  local pruned="$WORK/install.pruned.$$"
  rm -rf "$pruned"
  "$PYTHON_BIN" - \
    "$STAGE" \
    "$pruned" \
    "$INSTALL_STAGE_DEVICE" \
    "$INSTALL_STAGE_INODE" <<'PY'
import os
import shutil
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
expected_source_identity = (int(sys.argv[3]), int(sys.argv[4]))
destination.mkdir(parents=True)

include = source / "include"
if not (include / "OpenImageIO/imageio.h").is_file():
    raise SystemExit("OpenImageIO headers are missing")
shutil.copytree(include, destination / "include", symlinks=False)

libraries = {
    "libOpenImageIO.a": [source / "lib/libOpenImageIO.a"],
    "libOpenImageIO_Util.a": [source / "lib/libOpenImageIO_Util.a"],
    "libImath-3_2.a": [source / "lib/libImath-3_2.a"],
    "libjpeg.a": [source / "lib/libjpeg.a"],
    "libpng16.a": [
        source / "lib/libpng16.a",
        source / "lib/libpng16_static.a",
        source / "lib/libpng.a",
    ],
}
library_directory = destination / "lib"
library_directory.mkdir()
for output_name, candidates in libraries.items():
    existing = [candidate for candidate in candidates if candidate.is_file()]
    if not existing:
        raise SystemExit(f"required static library is missing: {output_name}")
    shutil.copyfile(existing[0], library_directory / output_name)

cmake_directory = library_directory / "cmake/OpenImageIO"
cmake_directory.mkdir(parents=True)
config = r'''include(CMakeFindDependencyMacro)
set(Boost_NO_BOOST_CMAKE ON)
set(Boost_USE_STATIC_LIBS ON)
find_dependency(Boost 1.53 REQUIRED COMPONENTS thread)
find_dependency(Threads REQUIRED)
find_dependency(ZLIB REQUIRED)

get_filename_component(_EASYSPLAT_OIIO_PREFIX
  "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

foreach(_library IN ITEMS
    libOpenImageIO.a
    libOpenImageIO_Util.a
    libImath-3_2.a
    libjpeg.a
    libpng16.a)
  if(NOT EXISTS "${_EASYSPLAT_OIIO_PREFIX}/lib/${_library}")
    message(FATAL_ERROR "Incomplete EasySplat OpenImageIO prefix: ${_library}")
  endif()
endforeach()

if(NOT TARGET OpenImageIO::OpenImageIO_Util)
  add_library(OpenImageIO::OpenImageIO_Util STATIC IMPORTED)
  set_target_properties(OpenImageIO::OpenImageIO_Util PROPERTIES
    IMPORTED_LOCATION "${_EASYSPLAT_OIIO_PREFIX}/lib/libOpenImageIO_Util.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_EASYSPLAT_OIIO_PREFIX}/include"
    INTERFACE_COMPILE_DEFINITIONS "OIIO_STATIC_DEFINE=1"
    INTERFACE_LINK_LIBRARIES
      "${_EASYSPLAT_OIIO_PREFIX}/lib/libImath-3_2.a;Boost::thread;Threads::Threads")
endif()

if(NOT TARGET OpenImageIO::OpenImageIO)
  add_library(OpenImageIO::OpenImageIO STATIC IMPORTED)
  set_target_properties(OpenImageIO::OpenImageIO PROPERTIES
    IMPORTED_LOCATION "${_EASYSPLAT_OIIO_PREFIX}/lib/libOpenImageIO.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_EASYSPLAT_OIIO_PREFIX}/include"
    INTERFACE_COMPILE_DEFINITIONS "OIIO_STATIC_DEFINE=1"
    INTERFACE_COMPILE_FEATURES "cxx_std_17"
    INTERFACE_LINK_LIBRARIES
      "OpenImageIO::OpenImageIO_Util;${_EASYSPLAT_OIIO_PREFIX}/lib/libImath-3_2.a;${_EASYSPLAT_OIIO_PREFIX}/lib/libjpeg.a;${_EASYSPLAT_OIIO_PREFIX}/lib/libpng16.a;ZLIB::ZLIB;Boost::thread;Threads::Threads")
endif()

set(OpenImageIO_FOUND TRUE)
set(OpenImageIO_VERSION "2.5.19.1")
set(OpenImageIO_INCLUDE_DIR "${_EASYSPLAT_OIIO_PREFIX}/include")
set(OpenImageIO_INCLUDES "${_EASYSPLAT_OIIO_PREFIX}/include")
unset(_library)
unset(_EASYSPLAT_OIIO_PREFIX)
'''
version = r'''set(PACKAGE_VERSION "2.5.19.1")
if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION VERSION_EQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
'''
(cmake_directory / "OpenImageIOConfig.cmake").write_text(config, encoding="utf-8")
(cmake_directory / "OpenImageIOConfigVersion.cmake").write_text(version, encoding="utf-8")

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def open_bound_directory(path, expected_identity=None):
    descriptor = os.open(path, directory_flags)
    metadata = os.fstat(descriptor)
    identity = (metadata.st_dev, metadata.st_ino)
    if expected_identity is not None and identity != expected_identity:
        os.close(descriptor)
        raise SystemExit(f"owned directory identity changed: {path}")
    return descriptor, identity


def remove_entry(parent_fd, name):
    metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    identity = (metadata.st_dev, metadata.st_ino)
    if stat.S_ISDIR(metadata.st_mode):
        child_fd = os.open(name, directory_flags, dir_fd=parent_fd)
        try:
            child_metadata = os.fstat(child_fd)
            if (child_metadata.st_dev, child_metadata.st_ino) != identity:
                raise SystemExit(f"directory changed while pruning: {name}")
            for child_name in os.listdir(child_fd):
                remove_entry(child_fd, child_name)
        finally:
            os.close(child_fd)
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != identity:
            raise SystemExit(f"directory changed before removal: {name}")
        os.rmdir(name, dir_fd=parent_fd)
    elif stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        os.unlink(name, dir_fd=parent_fd)
    else:
        raise SystemExit(f"unsupported staged install entry: {name}")


source_fd, _ = open_bound_directory(source, expected_source_identity)
destination_fd, destination_identity = open_bound_directory(destination)
try:
    for name in os.listdir(source_fd):
        remove_entry(source_fd, name)
    for name in sorted(os.listdir(destination_fd)):
        metadata = os.stat(name, dir_fd=destination_fd, follow_symlinks=False)
        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            raise SystemExit(f"unsafe pruned install entry: {name}")
        os.rename(name, name, src_dir_fd=destination_fd, dst_dir_fd=source_fd)
    os.fsync(source_fd)
    source_metadata = source.lstat()
    if (source_metadata.st_dev, source_metadata.st_ino) != expected_source_identity:
        raise SystemExit("owned install root changed while pruning")
finally:
    os.close(destination_fd)
    os.close(source_fd)

destination_parent_fd, _ = open_bound_directory(destination.parent)
try:
    destination_metadata = os.stat(
        destination.name,
        dir_fd=destination_parent_fd,
        follow_symlinks=False,
    )
    if (destination_metadata.st_dev, destination_metadata.st_ino) != destination_identity:
        raise SystemExit("pruned install root changed before cleanup")
    os.rmdir(destination.name, dir_fd=destination_parent_fd)
    os.fsync(destination_parent_fd)
finally:
    os.close(destination_parent_fd)
PY
}

stage_licenses() {
  local destination="$STAGE/licenses/OpenImageIO"
  mkdir -p "$destination"
  /usr/bin/install -m 0644 "$OIIO_SOURCE/LICENSE.md" "$destination/OpenImageIO-LICENSE.md"
  /usr/bin/install -m 0644 "$OIIO_SOURCE/THIRD-PARTY.md" "$destination/OpenImageIO-THIRD-PARTY.md"
  /usr/bin/install -m 0644 "$OIIO_SOURCE/RELICENSING.md" "$destination/OpenImageIO-RELICENSING.md"
  /usr/bin/install -m 0644 "$FMT_SOURCE/LICENSE.rst" "$destination/fmt-LICENSE.rst"
  /usr/bin/install -m 0644 "$ROBIN_SOURCE/LICENSE" "$destination/robin-map-LICENSE"
  /usr/bin/install -m 0644 "$IMATH_SOURCE/LICENSE.md" "$destination/Imath-LICENSE.md"
  /usr/bin/install -m 0644 "$JPEG_SOURCE/LICENSE.md" "$destination/libjpeg-turbo-LICENSE.md"
  /usr/bin/install -m 0644 "$JPEG_SOURCE/README.ijg" "$destination/libjpeg-turbo-README.ijg"
  /usr/bin/install -m 0644 "$PNG_SOURCE/LICENSE" "$destination/libpng-LICENSE"
  /usr/bin/install -m 0644 \
    "$SUPPORT/licenses/COLMAPSupport/Boost-LICENSE_1_0.txt" \
    "$destination/Boost-LICENSE_1_0.txt"
}

normalize_install_metadata() {
  local current_uid current_gid
  current_uid="$(/usr/bin/id -u)"
  current_gid="$(/usr/bin/id -g)"
  "$XATTR_BIN" -c -r "$STAGE" 2>/dev/null || true
  "$CHOWN_BIN" -R "$current_uid:$current_gid" "$STAGE"
  find "$STAGE" -type d -exec chmod 0755 {} +
  find "$STAGE" -type f -exec chmod 0644 {} +
  find "$STAGE" -type f -exec touch -h -t 200001010000 {} +
  find "$STAGE" -depth -type d -exec touch -h -t 200001010000 {} +
}

validate_static_archive() {
  local archive="$1"
  [ "$("$LIPO_BIN" -archs "$archive")" = "arm64" ] || \
    die "static archive is not thin arm64: $archive"
  "$PYTHON_BIN" - "$archive" <<'PY'
import struct
import sys
from pathlib import Path

LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1
MH_OBJECT = 1
EXPECTED_MINIMUM_OS = 15 << 16

path = Path(sys.argv[1])
data = path.read_bytes()
if not data.startswith(b"!<arch>\n"):
    raise SystemExit(f"not a regular static archive: {path}")
offset = 8
objects = 0
while offset < len(data):
    if offset + 60 > len(data):
        raise SystemExit(f"truncated archive header: {path}")
    header = data[offset:offset + 60]
    if header[58:60] != b"`\n":
        raise SystemExit(f"invalid archive member header: {path}")
    raw_name = header[:16].decode("ascii", "strict").strip()
    size = int(header[48:58].decode("ascii", "strict").strip())
    timestamp = header[16:28].decode("ascii", "strict").strip()
    uid = header[28:34].decode("ascii", "strict").strip()
    gid = header[34:40].decode("ascii", "strict").strip()
    for label, value in (("timestamp", timestamp), ("uid", uid), ("gid", gid)):
        if value and int(value) != 0:
            raise SystemExit(f"nondeterministic archive {label}: {path}: {value}")
    payload = data[offset + 60:offset + 60 + size]
    name = raw_name.rstrip("/")
    if raw_name.startswith("#1/"):
        name_length = int(raw_name[3:])
        name = payload[:name_length].rstrip(b"\0").decode("utf-8", "strict")
        payload = payload[name_length:]
    if not name.startswith("__.SYMDEF") and name not in {"", "/", "//"}:
        if b"/" in name.encode("utf-8") or b"\\" in name.encode("utf-8"):
            raise SystemExit(f"archive member contains a path: {path}: {name}")
        if len(payload) < 32 or payload[:4] != b"\xcf\xfa\xed\xfe":
            raise SystemExit(f"archive member is not a thin Mach-O object: {path}: {name}")
        (
            _,
            cpu_type,
            _,
            file_type,
            command_count,
            command_bytes,
            _,
            _,
        ) = struct.unpack_from("<IIIIIIII", payload, 0)
        if cpu_type != 0x0100000C:
            raise SystemExit(f"archive member is not arm64: {path}: {name}")
        if file_type != MH_OBJECT:
            raise SystemExit(f"archive member is not MH_OBJECT: {path}: {name}")

        command_offset = 32
        command_end = command_offset + command_bytes
        if command_end > len(payload):
            raise SystemExit(f"archive member load commands are truncated: {path}: {name}")
        deployments = []
        for _ in range(command_count):
            if command_offset + 8 > command_end:
                raise SystemExit(f"archive member load command is truncated: {path}: {name}")
            command, command_size = struct.unpack_from("<II", payload, command_offset)
            if command_size < 8 or command_offset + command_size > command_end:
                raise SystemExit(f"archive member load command is invalid: {path}: {name}")
            if command == LC_BUILD_VERSION:
                if command_size < 24:
                    raise SystemExit(f"archive member build-version command is invalid: {path}: {name}")
                platform, minimum_os, _, tool_count = struct.unpack_from(
                    "<IIII", payload, command_offset + 8
                )
                if 24 + tool_count * 8 > command_size:
                    raise SystemExit(f"archive member build tools are truncated: {path}: {name}")
                deployments.append((platform, minimum_os))
            elif command == LC_VERSION_MIN_MACOSX:
                if command_size < 16:
                    raise SystemExit(f"archive member minimum-version command is invalid: {path}: {name}")
                minimum_os = struct.unpack_from("<I", payload, command_offset + 8)[0]
                deployments.append((PLATFORM_MACOS, minimum_os))
            command_offset += command_size
        if command_offset != command_end:
            raise SystemExit(f"archive member load-command size mismatch: {path}: {name}")
        if not deployments:
            raise SystemExit(f"archive member has no deployment command: {path}: {name}")
        if deployments != [(PLATFORM_MACOS, EXPECTED_MINIMUM_OS)]:
            raise SystemExit(
                f"archive member does not target macOS 15.0: {path}: {name}: {deployments}"
            )
        objects += 1
    offset += 60 + size
    if offset % 2:
        offset += 1
if offset != len(data) or objects == 0:
    raise SystemExit(f"invalid or empty static archive: {path}")
PY
}

audit_static_outputs() {
  local root="${1:-$STAGE}"
  local archive
  for archive in "$root"/lib/*.a; do
    [ -f "$archive" ] || die "static library set is empty"
    validate_static_archive "$archive"
  done

  local nm_output="$SCRATCH/openimageio-nm.txt"
  local strings_output="$SCRATCH/openimageio-strings.txt"
  "$NM_BIN" -g -U -C "$root/lib/libOpenImageIO.a" >"$nm_output"
  "$STRINGS_BIN" "$root/lib/libOpenImageIO.a" >"$strings_output"
  "$PYTHON_BIN" - "$nm_output" "$strings_output" <<'PY'
import re
import sys
from pathlib import Path

expected = {
    "jpeg_input_imageio_create",
    "jpeg_output_imageio_create",
    "png_input_imageio_create",
    "png_output_imageio_create",
}
forbidden_factories = {
    "tiff_input_imageio_create",
    "tiff_output_imageio_create",
    "openexr_input_imageio_create",
    "openexr_output_imageio_create",
}
nm_pattern = re.compile(r"\b([a-z][a-z0-9]*_(?:input|output)_imageio_create)\(\)")
nm_found = set(nm_pattern.findall(Path(sys.argv[1]).read_text(encoding="utf-8")))
if nm_found != expected:
    raise SystemExit(f"unexpected defined plugin factories: {sorted(nm_found)}")

strings_text = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
strings_pattern = re.compile(r"([a-z][a-z0-9]*_(?:input|output)_imageio_create)")
strings_found = set(strings_pattern.findall(strings_text))
if not expected.issubset(strings_found):
    raise SystemExit(f"embedded plugin strings are incomplete: {sorted(strings_found)}")
if forbidden_factories & strings_found:
    raise SystemExit("TIFF/OpenEXR factory survived in the static archive")
PY
}

validate_install_surface() {
  local root="$1"
  local expected=(
    include/OpenImageIO/imageio.h
    lib/libOpenImageIO.a
    lib/libOpenImageIO_Util.a
    lib/libImath-3_2.a
    lib/libjpeg.a
    lib/libpng16.a
    lib/cmake/OpenImageIO/OpenImageIOConfig.cmake
    lib/cmake/OpenImageIO/OpenImageIOConfigVersion.cmake
    licenses/OpenImageIO/OpenImageIO-LICENSE.md
    licenses/OpenImageIO/OpenImageIO-THIRD-PARTY.md
    licenses/OpenImageIO/OpenImageIO-RELICENSING.md
    licenses/OpenImageIO/fmt-LICENSE.rst
    licenses/OpenImageIO/robin-map-LICENSE
    licenses/OpenImageIO/Imath-LICENSE.md
    licenses/OpenImageIO/libjpeg-turbo-LICENSE.md
    licenses/OpenImageIO/libjpeg-turbo-README.ijg
    licenses/OpenImageIO/libpng-LICENSE
    licenses/OpenImageIO/Boost-LICENSE_1_0.txt
    build_info.json
  )
  local relative
  for relative in "${expected[@]}"; do
    [ -f "$root/$relative" ] && [ ! -L "$root/$relative" ] || \
      die "required OpenImageIO install entry is missing: $relative"
  done
  if find "$root" -type l -o -type p -o -type s | /usr/bin/grep -q .; then
    die "OpenImageIO install contains a non-regular entry"
  fi
  if find "$root" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.pc' \) | /usr/bin/grep -q .; then
    die "dynamic library or pkg-config surface survived OpenImageIO pruning"
  fi
  if find "$root" -type d | /usr/bin/grep -Ei '/(bin|docs?|man|plugins?|pkgconfig|python|share)$' >/dev/null; then
    die "non-runtime directory survived OpenImageIO pruning"
  fi
}

scan_install_forbidden_paths() {
  local root="$1"
  "$PYTHON_BIN" - "$root" "$ROOT" "$WORK" "$SUPPORT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
specific = [value.encode("utf-8") for value in sys.argv[2:]]
generic = [b"/Users/", b"/private/tmp/", b"/opt/homebrew/", b"-mcpu=native", b"-march=native"]
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    data = path.read_bytes()
    for marker in specific + generic:
        if marker and marker in data:
            raise SystemExit(f"host/build path or tuning leaked into {path}: {marker!r}")
PY
}

receipt_contract() {
  local action="$1"
  local root="$2"
  "$PYTHON_BIN" - \
    "$action" "$root" "$LOCK" "$FROZEN_FREEZER_SHA256" \
    "$FROZEN_WRAPPER_SHA256" "$FROZEN_IMPLEMENTATION_SHA256" \
    "$EXTRACTOR" "$FROZEN_PROMOTER_SHA256" "$TESTS" \
    "$SUPPORT" "$SUPPORT_RECEIPT_SHA256" "$SUPPORT_TREE_SHA256" \
    "$AR_BIN" "$CLANG_BIN" "$CLANGXX_BIN" "$CMAKE_BIN" "$CHOWN_BIN" "$CURL_BIN" "$LD_BIN" \
    "$LIPO_BIN" "$LOCKF_BIN" "$NM_BIN" "$NINJA_BIN" "$OTOOL_BIN" "$PYTHON_BIN" \
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
    action,
    root_raw,
    lock_raw,
    freezer_sha256,
    wrapper_sha256,
    implementation_sha256,
    extractor_raw,
    promoter_sha256,
    tests_raw,
    support_raw,
    support_receipt_sha256,
    support_tree_sha256,
    ar_raw,
    clang_raw,
    clangxx_raw,
    cmake_raw,
    chown_raw,
    curl_raw,
    ld_raw,
    lipo_raw,
    lockf_raw,
    nm_raw,
    ninja_raw,
    otool_raw,
    python_raw,
    ranlib_raw,
    ripgrep_raw,
    shasum_raw,
    strings_raw,
    vtool_raw,
    xattr_raw,
    xcodebuild_raw,
    xcrun_raw,
    sdk_version,
    sdk_settings_raw,
    normalized_mtime_raw,
) = sys.argv[1:]

root = Path(root_raw)
lock_path = Path(lock_raw)
support = Path(support_raw)
normalized_mtime_epoch = int(normalized_mtime_raw)
lock = json.loads(lock_path.read_text(encoding="utf-8"))
support_receipt = json.loads((support / "build_info.json").read_text(encoding="utf-8"))


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command_version(command):
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    output = result.stdout or result.stderr
    return " | ".join(line.strip() for line in output.splitlines() if line.strip())


tree = hashlib.sha256()
paths = [root, *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())]
for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    if relative == "build_info.json":
        continue
    metadata = path.lstat()
    if stat.S_ISDIR(metadata.st_mode):
        kind, content = "directory", ""
    elif stat.S_ISREG(metadata.st_mode):
        kind, content = "file", file_sha256(path)
    else:
        raise SystemExit(f"unsupported install entry: {path}")
    for field in (
        relative,
        kind,
        f"{stat.S_IMODE(metadata.st_mode):o}",
        str(metadata.st_mtime_ns),
        content,
    ):
        tree.update(field.encode("utf-8"))
        tree.update(b"\0")

license_files = {
    "openimageio": [
        "licenses/OpenImageIO/OpenImageIO-LICENSE.md",
        "licenses/OpenImageIO/OpenImageIO-THIRD-PARTY.md",
        "licenses/OpenImageIO/OpenImageIO-RELICENSING.md",
    ],
    "fmt": ["licenses/OpenImageIO/fmt-LICENSE.rst"],
    "robin-map": ["licenses/OpenImageIO/robin-map-LICENSE"],
    "imath": ["licenses/OpenImageIO/Imath-LICENSE.md"],
    "libjpeg-turbo": [
        "licenses/OpenImageIO/libjpeg-turbo-LICENSE.md",
        "licenses/OpenImageIO/libjpeg-turbo-README.ijg",
    ],
    "libpng": ["licenses/OpenImageIO/libpng-LICENSE"],
}
linkage = {
    "openimageio": "static",
    "fmt": "internalized-header-only",
    "robin-map": "build-only-header-only",
    "imath": "static",
    "libjpeg-turbo": "static",
    "libpng": "static",
}
dependencies = {}
for name in ("openimageio", "fmt", "robin-map", "imath", "libjpeg-turbo", "libpng"):
    entry = lock["dependencies"][name]
    dependencies[name] = {
        "source_url": entry["source"]["url"],
        "source_sha256": entry["source"]["sha256"],
        "source_version": entry["version"],
        "license": entry["license"],
        "license_files": license_files[name],
        "linkage": linkage[name],
    }
dependencies["boost"] = {
    "source_url": support_receipt["dependencies"]["boost"]["source_url"],
    "source_sha256": support_receipt["dependencies"]["boost"]["source_sha256"],
    "source_version": support_receipt["dependencies"]["boost"]["source_version"],
    "license": "BSL-1.0",
    "license_files": ["licenses/OpenImageIO/Boost-LICENSE_1_0.txt"],
    "linkage": "static-external-prefix",
}

library_paths = (
    "lib/libOpenImageIO.a",
    "lib/libOpenImageIO_Util.a",
    "lib/libImath-3_2.a",
    "lib/libjpeg.a",
    "lib/libpng16.a",
)
libraries = {relative: file_sha256(root / relative) for relative in library_paths}
tool_paths = {
    "ar": Path(ar_raw),
    "clang": Path(clang_raw),
    "clangxx": Path(clangxx_raw),
    "cmake": Path(cmake_raw),
    "chown": Path(chown_raw),
    "curl": Path(curl_raw),
    "ld": Path(ld_raw),
    "lipo": Path(lipo_raw),
    "lockf": Path(lockf_raw),
    "nm": Path(nm_raw),
    "ninja": Path(ninja_raw),
    "otool": Path(otool_raw),
    "python": Path(python_raw),
    "ranlib": Path(ranlib_raw),
    "ripgrep": Path(ripgrep_raw),
    "shasum": Path(shasum_raw),
    "strings": Path(strings_raw),
    "vtool": Path(vtool_raw),
    "xattr": Path(xattr_raw),
    "xcodebuild": Path(xcodebuild_raw),
    "xcrun": Path(xcrun_raw),
}

expected = {
    "schema_version": 1,
    "toolchain_name": "openimageio-static",
    "architecture": "arm64",
    "deployment_target": "macOS 15.0",
    "linkage": "static",
    "enabled_formats": ["JPEG", "PNG"],
    "source_date_epoch": 0,
    "normalized_mtime_epoch": normalized_mtime_epoch,
    "ownership_policy": "invoking-build-user-and-primary-group",
    "control_freezer_sha256": freezer_sha256,
    "builder_sha256": wrapper_sha256,
    "builder_implementation_sha256": implementation_sha256,
    "source_lock_sha256": file_sha256(lock_path),
    "extractor_sha256": file_sha256(Path(extractor_raw)),
    "promoter_sha256": promoter_sha256,
    "tests_sha256": file_sha256(Path(tests_raw)),
    "support_receipt_sha256": support_receipt_sha256,
    "support_install_tree_sha256": support_tree_sha256,
    "dependencies": dependencies,
    "build_options": {
        "common": [
            "CMAKE_OSX_ARCHITECTURES=arm64",
            "CMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "CMAKE_FIND_USE_PACKAGE_REGISTRY=OFF",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
            "FETCHCONTENT_FULLY_DISCONNECTED=ON",
        ],
        "imath": ["BUILD_SHARED_LIBS=OFF", "BUILD_TESTING=OFF"],
        "libjpeg-turbo": [
            "ENABLE_SHARED=OFF",
            "ENABLE_STATIC=ON",
            "WITH_SIMD=ON",
            "WITH_TURBOJPEG=OFF",
            "WITH_TOOLS=OFF",
        ],
        "libpng": [
            "PNG_SHARED=OFF",
            "PNG_STATIC=ON",
            "PNG_ARM_NEON=on",
            "SDK-zlib",
        ],
        "openimageio": [
            "BUILD_SHARED_LIBS=OFF",
            "LINKSTATIC=ON",
            "EMBEDPLUGINS=ON",
            "formats=JPEG,PNG",
            "USE_OPENEXR=OFF",
            "USE_TIFF=OFF",
            "USE_PYTHON=OFF",
            "TIFF-free EXIF compatibility types",
        ],
        "reproducibility": [
            "SOURCE_DATE_EPOCH=0",
            "ZERO_AR_DATE=1",
            "prefix-map=.",
            "install-mtime=2000-01-01T00:00:00Z",
            "regular-mode=0644",
            "directory-mode=0755",
            "ownership-policy=invoking-build-user-and-primary-group",
            "extended-attributes=none",
            "umask=022",
        ],
    },
    "build_tools": {
        "clang": command_version([clang_raw, "--version"]).split(" | ", 1)[0],
        "cmake": command_version([cmake_raw, "--version"]).split(" | ", 1)[0],
        "macos_sdk": sdk_version,
        "ninja": command_version([ninja_raw, "--version"]),
        "python": command_version([python_raw, "--version"]),
        "ripgrep": command_version([ripgrep_raw, "--version"]).split(" | ", 1)[0],
        "xcode": command_version([xcodebuild_raw, "-version"]),
    },
    "build_tool_sha256": {
        name: file_sha256(path) for name, path in sorted(tool_paths.items())
    },
    "macos_sdk_settings_sha256": file_sha256(Path(sdk_settings_raw)),
    "library_sha256": libraries,
    "install_tree_sha256": tree.hexdigest(),
    "smoke_test": {
        "cmake_relocated_target": "OpenImageIO::OpenImageIO",
        "apple_imageio_metadata_interop": True,
        "jpeg_write_read": True,
        "jpeg_exif_orientation_roundtrip": True,
        "png_write_read": True,
        "tiff_create_unavailable": True,
        "tiff_read_unavailable": True,
        "consumer_architecture": "arm64",
        "consumer_deployment_target": "macOS 15.0",
    },
}

receipt_path = root / "build_info.json"
if action == "write":
    receipt_path.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8")
elif action == "validate":
    actual = json.loads(receipt_path.read_text(encoding="utf-8"))
    if actual != expected:
        mismatched = sorted(key for key in set(actual) | set(expected) if actual.get(key) != expected.get(key))
        raise SystemExit(f"build_info.json does not match reconstructed contract: {mismatched}")
else:
    raise SystemExit(f"unsupported receipt action: {action}")
PY
}

validate_metadata() {
  local root="$1"
  "$PYTHON_BIN" - "$root" "$NORMALIZED_MTIME_EPOCH" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
epoch = int(sys.argv[2])
for path in [root, *sorted(root.rglob("*"))]:
    metadata = path.lstat()
    if stat.S_ISDIR(metadata.st_mode):
        expected_mode = 0o755
    elif stat.S_ISREG(metadata.st_mode):
        expected_mode = 0o644
    else:
        raise SystemExit(f"unsupported install entry: {path}")
    if stat.S_IMODE(metadata.st_mode) != expected_mode:
        raise SystemExit(f"noncanonical install mode: {path}")
    if (metadata.st_uid, metadata.st_gid) != (os.getuid(), os.getgid()):
        raise SystemExit(f"noncanonical install ownership: {path}")
    if metadata.st_mtime_ns != epoch * 1_000_000_000:
        raise SystemExit(f"noncanonical install modification time: {path}")
PY
  if "$XATTR_BIN" -l -r "$root" 2>/dev/null | /usr/bin/grep -q .; then
    die "extended attributes survived OpenImageIO normalization"
  fi
}

write_receipt() {
  receipt_contract write "$STAGE"
  normalize_install_metadata
}

validate_receipt() {
  receipt_contract validate "$1"
}

run_relocated_consumer() {
  local root="$1"
  local smoke_root="$SCRATCH/smoke-consumer-relocated"
  local smoke_logs="$SCRATCH/smoke-logs"
  local source="$smoke_root/source"
  local build="$smoke_root/build"
  local relocated_oiio="$smoke_root/prefix/openimageio"
  local relocated_support="$smoke_root/prefix/support"
  if [ "$MODE" = "build" ]; then
    smoke_logs="$LOGS"
  fi
  rm -rf "$smoke_root"
  mkdir -p "$smoke_logs" "$source" "$smoke_root/output" "$(dirname "$relocated_oiio")"
  /bin/cp -R "$root" "$relocated_oiio"
  /bin/cp -R "$SUPPORT" "$relocated_support"

  "$PYTHON_BIN" - "$source" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
(root / "CMakeLists.txt").write_text(r'''cmake_minimum_required(VERSION 3.20)
project(EasySplatOpenImageIOSmoke LANGUAGES CXX)
find_package(OpenImageIO CONFIG REQUIRED)
find_library(COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(IMAGEIO_FRAMEWORK ImageIO REQUIRED)
add_executable(oiio_smoke main.cpp)
target_link_libraries(oiio_smoke PRIVATE
  OpenImageIO::OpenImageIO
  ${COREFOUNDATION_FRAMEWORK}
  ${COREGRAPHICS_FRAMEWORK}
  ${IMAGEIO_FRAMEWORK})
''', encoding="utf-8")
(root / "main.cpp").write_text(r'''#include <OpenImageIO/imageio.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace {

std::vector<std::uint8_t> pixels(int width, int height) {
    std::vector<std::uint8_t> result(static_cast<std::size_t>(width * height * 3));
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const auto offset = static_cast<std::size_t>((y * width + x) * 3);
            result[offset] = static_cast<std::uint8_t>(20 + x * 7);
            result[offset + 1] = static_cast<std::uint8_t>(30 + y * 9);
            result[offset + 2] = static_cast<std::uint8_t>(40 + (x + y) * 4);
        }
    }
    return result;
}

bool write_apple_imageio_fixture(const std::string& path, int width, int height,
                                 const std::vector<std::uint8_t>& source) {
    std::vector<CFTypeRef> owned;
    const auto own = [&owned](auto value) {
        if (value) owned.push_back(value);
        return value;
    };
    const auto release_owned = [&owned] {
        for (auto item = owned.rbegin(); item != owned.rend(); ++item) CFRelease(*item);
    };

    auto provider = own(CGDataProviderCreateWithData(
        nullptr, source.data(), source.size(), nullptr));
    auto color_space = own(CGColorSpaceCreateDeviceRGB());
    auto image = own(CGImageCreate(
        width, height, 8, 24, static_cast<std::size_t>(width * 3), color_space,
        static_cast<CGBitmapInfo>(kCGBitmapByteOrderDefault | kCGImageAlphaNone),
        provider, nullptr, false, kCGRenderingIntentDefault));
    auto url = own(CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(path.data()), path.size(), false));

    int orientation_value = 6;
    double focal_length_value = 24.0;
    auto orientation = own(CFNumberCreate(
        kCFAllocatorDefault, kCFNumberIntType, &orientation_value));
    auto focal_length = own(CFNumberCreate(
        kCFAllocatorDefault, kCFNumberDoubleType, &focal_length_value));
    const void* tiff_keys[] = {kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel};
    const void* tiff_values[] = {CFSTR("EasySplat Camera"), CFSTR("ES-15")};
    auto tiff = own(CFDictionaryCreate(
        kCFAllocatorDefault, tiff_keys, tiff_values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    const void* exif_keys[] = {kCGImagePropertyExifFocalLength};
    const void* exif_values[] = {focal_length};
    auto exif = own(CFDictionaryCreate(
        kCFAllocatorDefault, exif_keys, exif_values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    const void* metadata_keys[] = {
        kCGImagePropertyOrientation,
        kCGImagePropertyTIFFDictionary,
        kCGImagePropertyExifDictionary,
    };
    const void* metadata_values[] = {orientation, tiff, exif};
    auto metadata = own(CFDictionaryCreate(
        kCFAllocatorDefault, metadata_keys, metadata_values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    auto destination = own(CGImageDestinationCreateWithURL(
        url, CFSTR("public.jpeg"), 1, nullptr));

    bool succeeded = provider && color_space && image && url && orientation
        && focal_length && tiff && exif && metadata && destination;
    if (succeeded) {
        CGImageDestinationAddImage(destination, image, metadata);
        succeeded = CGImageDestinationFinalize(destination);
    }
    release_owned();
    return succeeded;
}

bool read_apple_imageio_metadata(const std::string& path) {
    auto input = OIIO::ImageInput::open(path);
    if (!input) return false;
    const auto& spec = input->spec();
    const bool metadata_matches = spec.get_int_attribute("Orientation", 0) == 6
        && spec.get_string_attribute("Make") == "EasySplat Camera"
        && spec.get_string_attribute("Model") == "ES-15"
        && std::abs(spec.get_float_attribute("Exif:FocalLength", 0.0f) - 24.0f) < 0.01f;
    return input->close() && metadata_matches;
}

bool write_image(const std::string& path, int width, int height,
                 const std::vector<std::uint8_t>& source, bool jpeg,
                 int orientation) {
    auto output = OIIO::ImageOutput::create(path);
    if (!output) return false;
    OIIO::ImageSpec spec(width, height, 3, OIIO::TypeDesc::UINT8);
    if (jpeg) spec.attribute("CompressionQuality", 100);
    if (orientation > 0) spec.attribute("Orientation", orientation);
    return output->open(path, spec)
        && output->write_image(OIIO::TypeDesc::UINT8, source.data())
        && output->close();
}

bool read_and_compare(const std::string& path, int width, int height,
                      const std::vector<std::uint8_t>& expected, bool exact,
                      int expected_orientation) {
    auto input = OIIO::ImageInput::open(path);
    if (!input) return false;
    const auto& spec = input->spec();
    if (spec.width != width || spec.height != height || spec.nchannels != 3) return false;
    if (expected_orientation > 0
        && spec.get_int_attribute("Orientation", 0) != expected_orientation) return false;
    std::vector<std::uint8_t> actual(expected.size());
    if (!input->read_image(OIIO::TypeDesc::UINT8, actual.data()) || !input->close()) return false;
    if (exact) return actual == expected;
    long long total = 0;
    int maximum = 0;
    for (std::size_t index = 0; index < actual.size(); ++index) {
        const int difference = std::abs(int(actual[index]) - int(expected[index]));
        total += difference;
        maximum = std::max(maximum, difference);
    }
    const double mean = double(total) / double(actual.size());
    return mean <= 5.0 && maximum <= 30;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    const std::string directory = argv[1];
    const std::string jpeg = directory + "/roundtrip.jpg";
    const std::string png = directory + "/roundtrip.png";
    const std::string apple_jpeg = directory + "/apple-imageio.jpg";
    const std::string tiff = directory + "/unsupported.tif";
    constexpr int width = 19;
    constexpr int height = 13;
    const auto source = pixels(width, height);
    if (!write_image(jpeg, width, height, source, true, 6)) return 3;
    if (!read_and_compare(jpeg, width, height, source, false, 6)) return 4;
    if (!write_image(png, width, height, source, false, 0)) return 5;
    if (!read_and_compare(png, width, height, source, true, 0)) return 6;
    if (!write_apple_imageio_fixture(apple_jpeg, width, height, source)) return 7;
    if (!read_apple_imageio_metadata(apple_jpeg)) return 8;
    if (OIIO::ImageOutput::create(tiff)) return 9;
    (void)OIIO::geterror();
    {
        std::ofstream stream(tiff, std::ios::binary);
        const char signature[] = {'I', 'I', '*', '\0', '\0', '\0', '\0', '\0'};
        stream.write(signature, sizeof(signature));
    }
    if (OIIO::ImageInput::open(tiff)) return 10;
    (void)OIIO::geterror();
    std::cout << "JPEG/PNG and Apple ImageIO metadata passed; TIFF unavailable\n";
    return 0;
}
''', encoding="utf-8")
PY

  "$CMAKE_BIN" -S "$source" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK" \
    -DCMAKE_CXX_COMPILER="$CLANGXX_BIN" \
    -DCMAKE_LINKER="$LD_BIN" \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_CXX_FLAGS="$COMMON_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LINK_FLAGS" \
    -DCMAKE_PREFIX_PATH="$relocated_oiio;$relocated_support" \
    '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF \
    -DBoost_NO_BOOST_CMAKE=ON \
    >"$smoke_logs/smoke-consumer-configure.log" 2>&1 || {
      /usr/bin/tail -n 200 "$smoke_logs/smoke-consumer-configure.log" >&2
      die "relocated CMake consumer configuration failed"
    }
  "$CMAKE_BIN" --build "$build" --parallel "$(sysctl -n hw.ncpu)" \
    >"$smoke_logs/smoke-consumer-build.log" 2>&1 || {
      /usr/bin/tail -n 200 "$smoke_logs/smoke-consumer-build.log" >&2
      die "relocated CMake consumer link failed"
    }
  "$build/oiio_smoke" "$smoke_root/output" >"$smoke_logs/smoke-consumer-run.log" 2>&1 || {
    /usr/bin/cat "$smoke_logs/smoke-consumer-run.log" >&2
    die "relocated JPEG/PNG/TIFF smoke consumer failed"
  }
  [ "$("$LIPO_BIN" -archs "$build/oiio_smoke")" = "arm64" ] || \
    die "smoke consumer is not thin arm64"
  local minos
  minos="$("$VTOOL_BIN" -show-build "$build/oiio_smoke" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
  [ "$minos" = "15.0" ] || die "smoke consumer deployment target is $minos, expected 15.0"
  if "$OTOOL_BIN" -L "$build/oiio_smoke" | /usr/bin/awk 'NR > 1 {print $1}' | \
    /usr/bin/grep -Ev '^(/System/Library/|/usr/lib/)' | /usr/bin/grep -q .; then
    die "smoke consumer retained a non-system dynamic dependency"
  fi
}

validate_install_prefix() {
  local root="$1"
  validate_install_surface "$root"
  validate_metadata "$root"
  validate_receipt "$root"
  audit_static_outputs "$root"
  scan_install_forbidden_paths "$root"
}

compare_reproducibility() {
  local left="$1"
  local right="$2"
  validate_install_prefix "$left"
  validate_install_prefix "$right"
  "$PYTHON_BIN" - "$left/build_info.json" "$right/build_info.json" <<'PY'
import json
import sys
from pathlib import Path

left = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
right = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if left != right:
    mismatched = sorted(key for key in set(left) | set(right) if left.get(key) != right.get(key))
    raise SystemExit(f"OpenImageIO builds are not reproducible: {mismatched}")
PY
}

promote_install() {
  local journal="$STAGE.promotion-state" tree_receipt
  tree_receipt="$(run_promoter --tree-receipt \
    "$STAGE" "$INSTALL_STAGE_DEVICE" "$INSTALL_STAGE_INODE")" || \
    die "could not bind the validated OpenImageIO tree"
  STAGE_CLEANUP_ALLOWED=0
  run_promoter "$STAGE" "$INSTALL" "$tree_receipt" || \
    die "could not atomically promote static OpenImageIO prefix; recovery state preserved"
  if ! validate_install_prefix "$INSTALL"; then
    if run_promoter --recover "$journal"; then
      die "promoted OpenImageIO prefix failed validation; previous state restored"
    fi
    die "post-promotion validation and rollback failed; recovery state preserved"
  fi
  run_promoter --commit "$journal" || \
    die "could not finalize OpenImageIO promotion; recovery state preserved"
}

validate_frozen_control_inputs || die "frozen build controls are invalid"
parse_arguments "$@"
preflight
initialize_private_workdirs
sanitize_environment
verify_support_prefix

case "$MODE" in
  validate)
    validate_install_prefix "$MODE_PREFIX"
    run_relocated_consumer "$MODE_PREFIX"
    echo "OpenImageIO prefix is valid: $MODE_PREFIX"
    ;;
  compare)
    [ -d "$INSTALL" ] && [ ! -L "$INSTALL" ] || die "default OpenImageIO install is missing"
    compare_reproducibility "$MODE_PREFIX" "$INSTALL"
    echo "OpenImageIO prefixes are byte-reproducible"
    ;;
  build)
    acquire_build_lock
    remove_stale_workdirs
    rm -rf "$BUILDS" "$LOGS"
    mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILDS" "$LOGS" "$BUILD_HOME" "$BUILD_TMP"
    create_owned_install_stage
    prepare_sources
    build_imath
    build_jpeg
    build_png
    build_openimageio
    audit_configurations
    prune_install
    stage_licenses
    normalize_install_metadata
    audit_static_outputs "$STAGE"
    scan_install_forbidden_paths "$STAGE"
    run_relocated_consumer "$STAGE"
    write_receipt
    validate_install_prefix "$STAGE"
    EASYSPLAT_OPENIMAGEIO_ROOT="$STAGE" \
      "$PYTHON_BIN" "$TESTS"
    promote_install
    echo "Static OpenImageIO installed to: $INSTALL"
    ;;
esac
