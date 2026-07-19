#!/bin/bash

CMAKE_BIN="${EASYSPLAT_BOOTSTRAP_CMAKE:-}"
GIT_BIN="${EASYSPLAT_BOOTSTRAP_GIT:-}"
NINJA_BIN="${EASYSPLAT_BOOTSTRAP_NINJA:-}"
RG_BIN="${EASYSPLAT_BOOTSTRAP_RG:-}"
GUARDED_RUN=0
GUARDED_INPUT_SNAPSHOT=""
GUARDED_STAGE_FD=""
GUARDED_STAGE_DEVICE=""
GUARDED_STAGE_INODE=""
BUILD_SUPERVISOR_PID=""
PROMOTION_READY_FD=""
PROMOTION_APPROVAL_FD=""
FROZEN_COLMAP_PATCH_FD=""
FROZEN_COLMAP_PATCH_SHA256=""
FROZEN_COLMAP_PATCH_SIZE=""
FROZEN_RETRIEVER_HEADER_FD=""
FROZEN_RETRIEVER_HEADER_SHA256=""
FROZEN_RETRIEVER_HEADER_SIZE=""
FROZEN_RETRIEVER_SOURCE_FD=""
FROZEN_RETRIEVER_SOURCE_SHA256=""
FROZEN_RETRIEVER_SOURCE_SIZE=""
FROZEN_OVERLAY_SHA256=""
FROZEN_WRAPPER_FD=""
FROZEN_WRAPPER_SHA256=""
FROZEN_WRAPPER_SIZE=""
FROZEN_IMPLEMENTATION_FD=""
FROZEN_IMPLEMENTATION_SHA256=""
FROZEN_IMPLEMENTATION_SIZE=""
FROZEN_SUPERVISOR_FD=""
FROZEN_SUPERVISOR_SHA256=""
FROZEN_SUPERVISOR_SIZE=""
FROZEN_PROMOTER_FD=""
FROZEN_PROMOTER_SHA256=""
FROZEN_PROMOTER_SIZE=""
BOUND_ROOT=""

if [ "${1:-}" = "--guarded-run" ]; then
  [ "$#" = "31" ] || {
    builtin printf '%s\n' "COLMAP build failed: guarded run arguments differ" >&2
    exit 1
  }
  GUARDED_RUN=1
  GUARDED_INPUT_SNAPSHOT="$2"
  GUARDED_STAGE_FD="$3"
  GUARDED_STAGE_DEVICE="$4"
  GUARDED_STAGE_INODE="$5"
  BUILD_SUPERVISOR_PID="$6"
  PROMOTION_READY_FD="$7"
  PROMOTION_APPROVAL_FD="$8"
  FROZEN_COLMAP_PATCH_FD="$9"
  FROZEN_COLMAP_PATCH_SHA256="${10}"
  FROZEN_COLMAP_PATCH_SIZE="${11}"
  FROZEN_RETRIEVER_HEADER_FD="${12}"
  FROZEN_RETRIEVER_HEADER_SHA256="${13}"
  FROZEN_RETRIEVER_HEADER_SIZE="${14}"
  FROZEN_RETRIEVER_SOURCE_FD="${15}"
  FROZEN_RETRIEVER_SOURCE_SHA256="${16}"
  FROZEN_RETRIEVER_SOURCE_SIZE="${17}"
  FROZEN_OVERLAY_SHA256="${18}"
  FROZEN_WRAPPER_FD="${19}"
  FROZEN_WRAPPER_SHA256="${20}"
  FROZEN_WRAPPER_SIZE="${21}"
  FROZEN_IMPLEMENTATION_FD="${22}"
  FROZEN_IMPLEMENTATION_SHA256="${23}"
  FROZEN_IMPLEMENTATION_SIZE="${24}"
  FROZEN_SUPERVISOR_FD="${25}"
  FROZEN_SUPERVISOR_SHA256="${26}"
  FROZEN_SUPERVISOR_SIZE="${27}"
  FROZEN_PROMOTER_FD="${28}"
  FROZEN_PROMOTER_SHA256="${29}"
  FROZEN_PROMOTER_SIZE="${30}"
  BOUND_ROOT="${31}"
  shift 31
fi
[ "$GUARDED_RUN" = "1" ] || {
  builtin printf '%s\n' "COLMAP build failed: native build lacks its supervisor" >&2
  exit 1
}

INHERITED_FUNCTIONS="$(builtin declare -F)"
if [ -n "$INHERITED_FUNCTIONS" ]; then
  builtin printf '%s\n' \
    "COLMAP build failed: implementation received inherited shell functions" >&2
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

ROOT="$BOUND_ROOT"
WORK="$ROOT/Toolchains/build/colmap"
INPUT_SNAPSHOT="${GUARDED_INPUT_SNAPSHOT:-$WORK/input.stage.$$}"
SRC="./src"
BUILD="./build"
INSTALL="$WORK/install.stage.$$"
LIVE_INSTALL="$WORK/install"
BUILD_HOME="./home"
BUILD_TMP="./tmp"
CERES_INSTALL="$ROOT/Toolchains/build/ceres/install"
OPENIMAGEIO_INSTALL="$ROOT/Toolchains/build/openimageio/install"
COLMAP_SUPPORT_INSTALL="$ROOT/Toolchains/build/colmap-support/install"
COLMAP_PATCH="$ROOT/scripts/toolchain/patches/colmap-4.1.1-easysplat.patch"
COLMAP_SUPPORT_TESTS="$ROOT/scripts/toolchain/tests/test_colmap_support_builder.py"
CERES_BUILDER="$ROOT/scripts/toolchain/build_ceres.sh"
OPENIMAGEIO_BUILDER="$ROOT/scripts/toolchain/build_openimageio.sh"
PROMOTER="$ROOT/scripts/toolchain/atomic_swap_install.py"
WRAPPER="$ROOT/scripts/toolchain/build_colmap.sh"
IMPLEMENTATION="$ROOT/scripts/toolchain/build_colmap_impl.sh"
BUILD_SUPERVISOR="$ROOT/scripts/toolchain/secure_colmap_build.py"

COLMAP_REPO="https://github.com/colmap/colmap.git"
COLMAP_COMMIT="a0d785fba74b2664f31edc4a29026a8b27c00f67"
COLMAP_VERSION="4.1.1"
CERES_COMMIT="85331393dc0dff09f6fb9903ab0c4bfa3e134b01"
OPENIMAGEIO_COMMIT="f32bf6e6f8de38ab6d197a72fd72366b66fd30a3"
POSELIB_URL="https://github.com/PoseLib/PoseLib/archive/fa7280fee27f97aff31ae7f98bab7f583fac7d08.zip"
POSELIB_COMMIT="fa7280fee27f97aff31ae7f98bab7f583fac7d08"
POSELIB_SHA256="5408d4ae8ce367cb2f076bc6c5f0f6f78abd3573d2c015304b04e46f23455f5b"
UPSTREAM_FAISS_URL="https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.1.zip"
UPSTREAM_FAISS_SHA256="4b1ae7e7a0a46385b4084f0e3945623a15fcf99d793bf44d82aae8e24f11e5f5"
FAISS_URL="https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.3.zip"
FAISS_COMMIT="0ca9df4792b173d573044ee14ca0704780176e82"
FAISS_VERSION="1.14.3"
FAISS_SHA256="fdb01044e707caa7e16d009a8ed11816aebe17fefbccb428c495486e28e6046d"
SOURCE_DATE_EPOCH=""
DEVELOPER_DIR_PATH=""
MACOS_SDK_PATH=""
MACOS_SDK_VERSION=""
MACOS_SDK_BUILD_VERSION=""
SELECTED_C_COMPILER=""
SELECTED_CXX_COMPILER=""
SELECTED_LINKER=""
SELECTED_ARCHIVER=""
SELECTED_RANLIB=""
SELECTED_PYTHON=""
SELECTED_LIPO=""
SELECTED_VTOOL=""
XCODEBUILD_BIN=""
LOCK_OWNED=0
INSTALL_STAGE_OWNED=0
INSTALL_STAGE_DEVICE=""
INSTALL_STAGE_INODE=""

die() {
  echo "COLMAP build failed: $*" >&2
  exit 1
}

run_frozen_promoter() {
  "$SELECTED_PYTHON" -I - \
    "$FROZEN_PROMOTER_FD" \
    "$FROZEN_PROMOTER_SHA256" \
    "$FROZEN_PROMOTER_SIZE" \
    "$@" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected_digest = sys.argv[2]
expected_size = int(sys.argv[3])
metadata = os.fstat(descriptor)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 0
    or metadata.st_uid != os.getuid()
    or metadata.st_gid != os.getgid()
    or stat.S_IMODE(metadata.st_mode) != 0o400
    or metadata.st_size != expected_size
    or expected_size <= 0
    or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
    != os.O_RDONLY
):
    raise SystemExit("frozen native COLMAP promoter metadata differs")
payload = b"".join(
    os.pread(descriptor, min(1024 * 1024, expected_size - offset), offset)
    for offset in range(0, expected_size, 1024 * 1024)
)
if len(payload) != expected_size or os.pread(descriptor, 1, expected_size):
    raise SystemExit("frozen native COLMAP promoter size changed")
if hashlib.sha256(payload).hexdigest() != expected_digest:
    raise SystemExit("frozen native COLMAP promoter digest changed")
sys.argv = ["<frozen atomic_swap_install.py>", *sys.argv[4:]]
namespace = {
    "__name__": "__main__",
    "__file__": "<frozen atomic_swap_install.py>",
}
exec(compile(payload, namespace["__file__"], "exec"), namespace, namespace)
PY
}

STAGE_CLEANUP_ALLOWED=1

cleanup() {
  local status=$?
  local install_cleanup_status=0
  trap - EXIT
  trap '' INT TERM HUP
  if [ "$STAGE_CLEANUP_ALLOWED" = "1" ] && [ "$INSTALL_STAGE_OWNED" = "1" ]; then
    if [ -n "$SELECTED_PYTHON" ] && [ -x "$SELECTED_PYTHON" ] && \
      [ -f "$PROMOTER" ] && [ ! -L "$PROMOTER" ]; then
      run_frozen_promoter \
        --remove-owned-tree \
        "$INSTALL" \
        "$INSTALL_STAGE_DEVICE" \
        "$INSTALL_STAGE_INODE" \
        --allow-symlinks || install_cleanup_status=$?
    else
      install_cleanup_status=1
    fi
    if [ "$install_cleanup_status" -ne 0 ]; then
      printf '%s\n' \
        "COLMAP build cleanup preserved an unverified staged install: $INSTALL" >&2
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
    run_frozen_promoter --create-owned-tree "$INSTALL"
  )" || die "could not create and bind native COLMAP install stage"
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || \
    die "native COLMAP install stage identity is malformed"
  INSTALL_STAGE_DEVICE="${identity%%:*}"
  INSTALL_STAGE_INODE="${identity#*:}"
  INSTALL_STAGE_OWNED=1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

acquire_build_lock() {
  [ "$GUARDED_RUN" = "1" ] || die "native COLMAP build lacks its supervisor"
  [ "$PPID" = "$BUILD_SUPERVISOR_PID" ] || \
    die "native COLMAP build supervisor identity changed"
  "$SELECTED_PYTHON" - \
    "$INPUT_SNAPSHOT" \
    "$GUARDED_STAGE_FD" \
    "$GUARDED_STAGE_DEVICE" \
    "$GUARDED_STAGE_INODE" \
    "$$" <<'PY'
import fcntl
import os
import stat
import sys

path, stage_fd, expected_device, expected_inode, implementation_pid = sys.argv[1:]
implementation_pid = int(implementation_pid)
if (
    os.getppid() != implementation_pid
    or os.getpgrp() != implementation_pid
    or os.getsid(0) != implementation_pid
):
    raise SystemExit("native COLMAP build implementation process changed")
stage_descriptor = int(stage_fd)
metadata = os.fstat(stage_descriptor)
cwd_metadata = os.stat(".", follow_symlinks=False)
named_metadata = os.lstat(path)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.getuid()
    or metadata.st_gid != os.getgid()
    or stat.S_IMODE(metadata.st_mode) != 0o700
    or metadata.st_dev != int(expected_device)
    or metadata.st_ino != int(expected_inode)
    or (fcntl.fcntl(stage_descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
    != os.O_RDONLY
    or (cwd_metadata.st_dev, cwd_metadata.st_ino)
    != (metadata.st_dev, metadata.st_ino)
    or (named_metadata.st_dev, named_metadata.st_ino)
    != (metadata.st_dev, metadata.st_ino)
):
    raise SystemExit("native COLMAP run stage identity changed")
PY
}

await_promotion_approval() {
  [ "$PPID" = "$BUILD_SUPERVISOR_PID" ] || \
    die "native COLMAP build supervisor identity changed"
  "$SELECTED_PYTHON" - \
    "$PROMOTION_READY_FD" \
    "$PROMOTION_APPROVAL_FD" \
    "$$" <<'PY'
import fcntl
import os
import stat
import sys

ready_descriptor, approval_descriptor, implementation_pid = map(int, sys.argv[1:])
if (
    os.getppid() != implementation_pid
    or os.getpgrp() != implementation_pid
    or os.getsid(0) != implementation_pid
):
    raise SystemExit("native COLMAP build implementation process changed")
ready_metadata = os.fstat(ready_descriptor)
approval_metadata = os.fstat(approval_descriptor)
if (
    not stat.S_ISFIFO(ready_metadata.st_mode)
    or not stat.S_ISFIFO(approval_metadata.st_mode)
    or (fcntl.fcntl(ready_descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
    != os.O_WRONLY
    or (fcntl.fcntl(approval_descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
    != os.O_RDONLY
):
    raise SystemExit("native COLMAP promotion gate descriptors differ")
if os.write(ready_descriptor, b"R") != 1:
    raise SystemExit("native COLMAP promotion request was truncated")
if os.read(approval_descriptor, 2) != b"A":
    raise SystemExit("native COLMAP promotion was not approved")
PY
}

recover_stale_promotions() {
  local journal path
  for journal in "$WORK"/install.stage.*.promotion-state; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    run_frozen_promoter --recover "$journal" || \
      die "could not recover interrupted native COLMAP promotion: $journal"
  done
  for path in "$WORK"/install.stage.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    case "$path" in
      *.promotion-state) continue ;;
    esac
    die "ambiguous staged install requires recovery: $path"
  done
  for path in "$WORK"/input.stage.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ "$path" = "$INPUT_SNAPSHOT" ] && continue
    die "ambiguous native input stage requires recovery: $path"
  done
}

freeze_native_inputs() {
  "$SELECTED_PYTHON" - \
    "$FROZEN_COLMAP_PATCH_FD" \
    "$FROZEN_COLMAP_PATCH_SHA256" \
    "$FROZEN_COLMAP_PATCH_SIZE" \
    "$FROZEN_RETRIEVER_HEADER_FD" \
    "$FROZEN_RETRIEVER_HEADER_SHA256" \
    "$FROZEN_RETRIEVER_HEADER_SIZE" \
    "$FROZEN_RETRIEVER_SOURCE_FD" \
    "$FROZEN_RETRIEVER_SOURCE_SHA256" \
    "$FROZEN_RETRIEVER_SOURCE_SIZE" \
    "$FROZEN_OVERLAY_SHA256" <<'PY'
import hashlib
import os
import stat
import sys

arguments = sys.argv[1:]
if len(arguments) != 10:
    raise SystemExit("frozen native build input arguments differ")
items = []
for offset in range(0, 9, 3):
    descriptor = int(arguments[offset])
    expected_sha256 = arguments[offset + 1]
    expected_size = int(arguments[offset + 2])
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or stat.S_IMODE(metadata.st_mode) != 0o400
        or metadata.st_size != expected_size
        or expected_size <= 0
    ):
        raise SystemExit("frozen native build input metadata differs")
    payload = b"".join(
        os.pread(descriptor, min(1024 * 1024, expected_size - position), position)
        for position in range(0, expected_size, 1024 * 1024)
    )
    if len(payload) != expected_size:
        raise SystemExit("frozen native build input was truncated")
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise SystemExit("frozen native build input digest mismatch")
    items.append(payload)

combined = hashlib.sha256()
for name, payload in (
    ("local_vocab_retriever.h", items[1]),
    ("local_vocab_retriever.cc", items[2]),
    ("colmap-4.1.1-easysplat.patch", items[0]),
):
    combined.update(name.encode("utf-8"))
    combined.update(b"\0")
    combined.update(payload)
    combined.update(b"\0")
if combined.hexdigest() != arguments[9]:
    raise SystemExit("frozen native overlay digest mismatch")
PY
}

validate_frozen_controls() {
  "$SELECTED_PYTHON" - \
    "$FROZEN_WRAPPER_FD" \
    "$FROZEN_WRAPPER_SHA256" \
    "$FROZEN_WRAPPER_SIZE" \
    "$FROZEN_IMPLEMENTATION_FD" \
    "$FROZEN_IMPLEMENTATION_SHA256" \
    "$FROZEN_IMPLEMENTATION_SIZE" \
    "$FROZEN_SUPERVISOR_FD" \
    "$FROZEN_SUPERVISOR_SHA256" \
    "$FROZEN_SUPERVISOR_SIZE" \
    "$FROZEN_PROMOTER_FD" \
    "$FROZEN_PROMOTER_SHA256" \
    "$FROZEN_PROMOTER_SIZE" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

arguments = sys.argv[1:]
if len(arguments) != 12:
    raise SystemExit("frozen native build control arguments differ")
for offset in range(0, 12, 3):
    descriptor = int(arguments[offset])
    expected_digest = arguments[offset + 1]
    expected_size = int(arguments[offset + 2])
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
        or stat.S_IMODE(metadata.st_mode) != 0o400
        or metadata.st_size != expected_size
        or expected_size <= 0
        or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
        != os.O_RDONLY
    ):
        raise SystemExit("frozen native build control metadata differs")
    payload = b"".join(
        os.pread(descriptor, min(1024 * 1024, expected_size - position), position)
        for position in range(0, expected_size, 1024 * 1024)
    )
    if len(payload) != expected_size or os.pread(descriptor, 1, expected_size):
        raise SystemExit("frozen native build control size changed")
    if hashlib.sha256(payload).hexdigest() != expected_digest:
        raise SystemExit("frozen native build control digest changed")
PY
}

sanitize_environment() {
  local directory path_value tool
  path_value="$(/usr/bin/dirname "$SELECTED_C_COMPILER")"
  path_value+=":$DEVELOPER_DIR_PATH/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  for tool in "$CMAKE_BIN" "$GIT_BIN" "$NINJA_BIN" "$RG_BIN"; do
    directory="$(/usr/bin/dirname "$tool")"
    case ":$path_value:" in
      *":$directory:"*) ;;
      *) path_value+=":$directory" ;;
    esac
  done
  export PATH="$path_value"
  export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"
  export HOME="$BUILD_HOME"
  export TMPDIR="$BUILD_TMP"
  export LC_ALL=C
  export LANG=C
  export TZ=UTC
  export MACOSX_DEPLOYMENT_TARGET=15.0
}

cache_is() {
  local name="$1"
  local expected="$2"
  local line
  while IFS= read -r line; do
    if [[ "${line%%=*}" == "$name":* ]]; then
      [ "${line#*=}" = "$expected" ] || \
        die "CMake did not preserve ${name}=${expected}"
      return
    fi
  done < "$BUILD/CMakeCache.txt"
  die "CMake cache is missing ${name}"
}

verify_dependency_provenance() {
  local build_info="$1"
  local tool_name="$2"
  local expected_commit="$3"
  local source_dependency="${4:-}"
  "$SELECTED_PYTHON" - \
    "$build_info" "$tool_name" "$expected_commit" "$source_dependency" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
tool_name = sys.argv[2]
expected_commit = sys.argv[3]
source_dependency = sys.argv[4]
if not path.is_file():
    raise SystemExit(f"missing {tool_name} provenance: {path}")
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("toolchain_name") != tool_name:
    raise SystemExit(f"unexpected toolchain_name in {path}")
if expected_commit:
    if source_dependency:
        dependency = payload.get("dependencies", {}).get(source_dependency)
        if not isinstance(dependency, dict):
            raise SystemExit(f"missing {source_dependency} source provenance")
        source_url = dependency.get("source_url", "")
        source_version = dependency.get("source_version", "")
        if (
            not source_url.endswith(f"/{expected_commit}.tar.gz")
            or not source_version.endswith(expected_commit)
        ):
            raise SystemExit(f"stale {tool_name} install at {path.parent}")
    elif payload.get("source_commit") != expected_commit:
        raise SystemExit(f"stale {tool_name} install at {path.parent}")
if payload.get("deployment_target") != "macOS 15.0":
    raise SystemExit(f"unsupported {tool_name} deployment target")
if payload.get("architecture", "arm64") != "arm64":
    raise SystemExit(f"unsupported {tool_name} architecture")
if payload.get("ownership_policy") != "invoking-build-user-and-primary-group":
    raise SystemExit(f"dependency ownership policy mismatch: {tool_name}")
if "normalized_owner_uid" in payload or "normalized_owner_gid" in payload:
    raise SystemExit(f"dependency receipt contains host-specific numeric ownership: {tool_name}")

declared: dict[str, str] = {}
for entry in payload.get("libraries", []):
    declared[f"lib/{entry['file']}"] = entry["sha256"]
for relative_path, digest in payload.get("library_sha256", {}).items():
    relative = relative_path if "/" in relative_path else f"lib/{relative_path}"
    if relative in declared and declared[relative] != digest:
        raise SystemExit(f"conflicting dependency library hash: {relative}")
    declared[relative] = digest
if not declared:
    raise SystemExit(f"{tool_name} provenance declares no library hashes")
for relative_path, expected_digest in sorted(declared.items()):
    relative = Path(relative_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"unsafe dependency library path: {relative_path}")
    library_path = path.parent / relative
    if not library_path.is_file() or library_path.is_symlink():
        raise SystemExit(f"declared dependency library is missing: {library_path}")
    actual_digest = hashlib.sha256(library_path.read_bytes()).hexdigest()
    if actual_digest != expected_digest:
        raise SystemExit(f"dependency library hash mismatch: {library_path}")

tree = hashlib.sha256()
root = path.parent
paths = [
    root,
    *sorted(root.rglob("*"), key=lambda entry: entry.relative_to(root).as_posix()),
]
for entry in paths:
    relative = "." if entry == root else entry.relative_to(root).as_posix()
    metadata = entry.lstat()
    if (metadata.st_uid, metadata.st_gid) != (os.getuid(), os.getgid()):
        raise SystemExit(f"noncanonical dependency ownership: {entry}")
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISDIR(metadata.st_mode):
        kind, content = "directory", ""
    elif stat.S_ISREG(metadata.st_mode):
        kind = "file"
        content = hashlib.sha256(entry.read_bytes()).hexdigest()
    else:
        raise SystemExit(f"unsupported dependency tree entry: {entry}")
    if relative == "build_info.json":
        continue
    for field in (relative, kind, f"{mode:o}", str(metadata.st_mtime_ns), content):
        tree.update(field.encode("utf-8"))
        tree.update(b"\0")
if tree.hexdigest() != payload.get("install_tree_sha256"):
    raise SystemExit(f"dependency install tree hash mismatch: {tool_name}")
PY
}

prepare_source() {
  local modified_paths untracked_paths
  [ ! -e "$SRC" ] && [ ! -L "$SRC" ] || \
    die "source checkout path already exists in the unique run stage"
  "$GIT_BIN" clone --filter=blob:none --no-checkout "$COLMAP_REPO" "$SRC"
  [ "$("$GIT_BIN" -C "$SRC" remote get-url origin)" = "$COLMAP_REPO" ] || \
    die "unexpected source origin in $SRC"
  "$GIT_BIN" -C "$SRC" fetch --depth 1 --force origin "$COLMAP_COMMIT"
  "$GIT_BIN" -C "$SRC" checkout --detach --force "$COLMAP_COMMIT"
  "$GIT_BIN" -C "$SRC" clean -ffdqx
  [ "$("$GIT_BIN" -C "$SRC" rev-parse HEAD)" = "$COLMAP_COMMIT" ] || \
    die "source commit mismatch"
  SOURCE_DATE_EPOCH="$("$GIT_BIN" -C "$SRC" show -s --format=%ct "$COLMAP_COMMIT")"
  [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || die "source commit timestamp is invalid"
  export SOURCE_DATE_EPOCH
  [ -z "$("$GIT_BIN" -C "$SRC" status --porcelain --untracked-files=all)" ] || \
    die "source checkout is dirty"
  "$RG_BIN" -F "URL $POSELIB_URL" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP PoseLib source URL no longer matches the reviewed pin"
  "$RG_BIN" -F "URL_HASH SHA256=$POSELIB_SHA256" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP PoseLib source hash no longer matches the reviewed pin"
  "$RG_BIN" -F "URL $UPSTREAM_FAISS_URL" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP FAISS source URL no longer matches the reviewed pin"
  "$RG_BIN" -F "URL_HASH SHA256=$UPSTREAM_FAISS_SHA256" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "COLMAP FAISS source hash no longer matches the reviewed pin"
  "$SELECTED_PYTHON" - \
    "$GIT_BIN" \
    "$SRC" \
    "$FROZEN_COLMAP_PATCH_FD" \
    "$FROZEN_COLMAP_PATCH_SHA256" \
    "$FROZEN_COLMAP_PATCH_SIZE" \
    "$FROZEN_RETRIEVER_HEADER_FD" \
    "$FROZEN_RETRIEVER_HEADER_SHA256" \
    "$FROZEN_RETRIEVER_HEADER_SIZE" \
    "$FROZEN_RETRIEVER_SOURCE_FD" \
    "$FROZEN_RETRIEVER_SOURCE_SHA256" \
    "$FROZEN_RETRIEVER_SOURCE_SIZE" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path

git, source = sys.argv[1:3]
arguments = sys.argv[3:]


def read_frozen(offset: int) -> bytes:
    descriptor = int(arguments[offset])
    expected_sha256 = arguments[offset + 1]
    expected_size = int(arguments[offset + 2])
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or stat.S_IMODE(metadata.st_mode) != 0o400
        or metadata.st_size != expected_size
    ):
        raise SystemExit("frozen native build input metadata differs")
    payload = bytearray()
    position = 0
    while position < expected_size:
        block = os.pread(
            descriptor, min(1024 * 1024, expected_size - position), position
        )
        if not block:
            raise SystemExit("frozen native build input was truncated")
        payload.extend(block)
        position += len(block)
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise SystemExit("frozen native build input digest mismatch")
    return bytes(payload)


patch, header, implementation = (read_frozen(offset) for offset in (0, 3, 6))
for extra in (("--check",), ()):
    subprocess.run(
        [git, "-C", source, "apply", *extra, "-"],
        input=patch,
        check=True,
    )
for relative, payload, expected_sha256 in (
    ("src/colmap/exe/local_vocab_retriever.h", header, arguments[4]),
    ("src/colmap/exe/local_vocab_retriever.cc", implementation, arguments[7]),
):
    destination = Path(source) / relative
    descriptor = os.open(
        destination,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_CLOEXEC
        | os.O_NOFOLLOW,
        0o644,
    )
    try:
        position = 0
        while position < len(payload):
            position += os.write(descriptor, payload[position:])
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        named = os.lstat(destination)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or (metadata.st_dev, metadata.st_ino) != (named.st_dev, named.st_ino)
            or hashlib.sha256(payload).hexdigest() != expected_sha256
        ):
            raise SystemExit(f"native overlay publication changed: {relative}")
    finally:
        os.close(descriptor)
PY
  modified_paths="$("$GIT_BIN" -C "$SRC" diff --name-only | LC_ALL=C sort)"
  untracked_paths="$("$GIT_BIN" -C "$SRC" ls-files --others --exclude-standard | LC_ALL=C sort)"
  [ "$modified_paths" = $'CMakeLists.txt\ncmake/FindDependencies.cmake\nsrc/colmap/controllers/CMakeLists.txt\nsrc/colmap/controllers/feature_extraction.cc\nsrc/colmap/controllers/feature_matching.cc\nsrc/colmap/controllers/feature_matching.h\nsrc/colmap/controllers/option_manager.cc\nsrc/colmap/controllers/option_manager.h\nsrc/colmap/controllers/option_manager_test.cc\nsrc/colmap/controllers/pairing.cc\nsrc/colmap/controllers/pairing.h\nsrc/colmap/controllers/undistorters.cc\nsrc/colmap/controllers/undistorters.h\nsrc/colmap/estimators/CMakeLists.txt\nsrc/colmap/exe/CMakeLists.txt\nsrc/colmap/exe/colmap.cc\nsrc/colmap/exe/feature.cc\nsrc/colmap/exe/image.cc\nsrc/colmap/exe/sfm.cc\nsrc/colmap/exe/sfm.h\nsrc/colmap/feature/CMakeLists.txt\nsrc/colmap/feature/extractor.cc\nsrc/colmap/feature/extractor.h\nsrc/colmap/feature/matcher.cc\nsrc/colmap/feature/matcher.h\nsrc/colmap/feature/sift.cc\nsrc/colmap/feature/sift.h\nsrc/colmap/feature/types.cc\nsrc/colmap/feature/types.h\nsrc/colmap/math/CMakeLists.txt\nsrc/colmap/optim/CMakeLists.txt\nsrc/colmap/retrieval/resources.cc\nsrc/colmap/retrieval/resources.h\nsrc/colmap/retrieval/visual_index.cc\nsrc/colmap/retrieval/visual_index.h\nsrc/colmap/scene/CMakeLists.txt\nsrc/colmap/scene/database.cc\nsrc/colmap/scene/database.h\nsrc/colmap/scene/database_sqlite.cc\nsrc/colmap/scene/database_sqlite.h\nsrc/colmap/sfm/CMakeLists.txt\nsrc/colmap/sfm/incremental_mapper_impl.cc\nsrc/colmap/sfm/incremental_mapper_test.cc\nsrc/thirdparty/CMakeLists.txt' ] || \
    die "COLMAP patch modified an unexpected source path"
  [ "$untracked_paths" = $'src/colmap/exe/local_vocab_retriever.cc\nsrc/colmap/exe/local_vocab_retriever.h' ] || \
    die "native COLMAP overlay added an unexpected source path"
  "$GIT_BIN" -C "$SRC" diff --check
  "$RG_BIN" -F "URL $FAISS_URL" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "patched COLMAP FAISS source URL is incorrect"
  "$RG_BIN" -F "URL_HASH SHA256=$FAISS_SHA256" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "patched COLMAP FAISS source hash is incorrect"
  "$RG_BIN" -F "set(FAISS_ENABLE_METAL OFF)" "$SRC/src/thirdparty/CMakeLists.txt" >/dev/null || \
    die "patched COLMAP did not disable FAISS Metal"
}

validate_frozen_native_inputs() {
  "$SELECTED_PYTHON" - \
    "$GIT_BIN" \
    "$SRC" \
    "$FROZEN_COLMAP_PATCH_FD" \
    "$FROZEN_COLMAP_PATCH_SHA256" \
    "$FROZEN_COLMAP_PATCH_SIZE" \
    "$FROZEN_RETRIEVER_HEADER_SHA256" \
    "$FROZEN_RETRIEVER_SOURCE_SHA256" <<'PY'
import hashlib
import os
import subprocess
import sys
from pathlib import Path

git, source, patch_fd, patch_sha256, patch_size, header_sha256, source_sha256 = sys.argv[1:]
size = int(patch_size)
payload = bytearray()
position = 0
while position < size:
    block = os.pread(int(patch_fd), min(1024 * 1024, size - position), position)
    if not block:
        raise SystemExit("frozen native COLMAP patch was truncated")
    payload.extend(block)
    position += len(block)
if hashlib.sha256(payload).hexdigest() != patch_sha256:
    raise SystemExit("frozen native COLMAP patch digest mismatch")
diff = subprocess.run(
    [git, "-C", source, "diff", "--binary"],
    check=True,
    capture_output=True,
).stdout
if diff != payload:
    raise SystemExit("compiled native COLMAP source differs from the frozen patch")
for relative, expected in (
    ("src/colmap/exe/local_vocab_retriever.h", header_sha256),
    ("src/colmap/exe/local_vocab_retriever.cc", source_sha256),
):
    actual = hashlib.sha256((Path(source) / relative).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"compiled native overlay differs: {relative}")
PY
}

configure() {
  local openmp_root boost_root gflags_prefix glog_prefix
  local ignore_prefixes prefix_map_flags prefix_path
  openmp_root="$COLMAP_SUPPORT_INSTALL"
  boost_root="$COLMAP_SUPPORT_INSTALL"
  gflags_prefix="$COLMAP_SUPPORT_INSTALL"
  glog_prefix="$COLMAP_SUPPORT_INSTALL"

  for required in \
    "$openmp_root" \
    "$boost_root" \
    "$gflags_prefix" \
    "$glog_prefix"; do
    [ -d "$required" ] || die "required portable support dependency is missing"
  done

  [ -d "$CERES_INSTALL/share/eigen3/cmake" ] || die "pinned Eigen install is missing"
  [ -s "$OPENIMAGEIO_INSTALL/lib/cmake/OpenImageIO/OpenImageIOConfig.cmake" ] || \
    die "pinned OpenImageIO install is missing"
  prefix_path="$CERES_INSTALL;$OPENIMAGEIO_INSTALL;$COLMAP_SUPPORT_INSTALL"
  ignore_prefixes="/opt/homebrew/opt/ceres-solver"
  ignore_prefixes+=";/opt/homebrew/opt/suite-sparse"
  ignore_prefixes+=";/opt/homebrew/opt/openimageio"
  ignore_prefixes+=";/usr/local/opt/ceres-solver"
  ignore_prefixes+=";/usr/local/opt/suite-sparse"
  ignore_prefixes+=";/usr/local/opt/openimageio"
  prefix_map_flags="-ffile-prefix-map=${ROOT}=/easysplat -fdebug-prefix-map=${ROOT}=/easysplat"

  rm -rf "$BUILD"
  "$CMAKE_BIN" -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$SELECTED_C_COMPILER" \
    -DCMAKE_CXX_COMPILER="$SELECTED_CXX_COMPILER" \
    -DCMAKE_LINKER="$SELECTED_LINKER" \
    -DCMAKE_AR="$SELECTED_ARCHIVER" \
    -DCMAKE_RANLIB="$SELECTED_RANLIB" \
    -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_INSTALL_RPATH='@executable_path/../lib' \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
    -DCMAKE_C_FLAGS="$prefix_map_flags" \
    -DCMAKE_CXX_FLAGS="$prefix_map_flags" \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DGIT_EXECUTABLE="$GIT_BIN" \
    -DCMAKE_PREFIX_PATH="$prefix_path" \
    -DCMAKE_IGNORE_PREFIX_PATH="$ignore_prefixes" \
    -DOpenMP_ROOT="$openmp_root" \
    -DBoost_ROOT="$boost_root" \
    -DOpenImageIO_DIR="$OPENIMAGEIO_INSTALL/lib/cmake/OpenImageIO" \
    -DEigen3_DIR="$CERES_INSTALL/share/eigen3/cmake" \
    -Dgflags_DIR="$gflags_prefix/lib/cmake/gflags" \
    -Dglog_DIR="$glog_prefix/lib/cmake/glog" \
    -DCeres_DIR="$CERES_INSTALL/lib/cmake/Ceres" \
    -DGUI_ENABLED=OFF \
    -DCUDA_ENABLED=OFF \
    -DOPENGL_ENABLED=OFF \
    -DMVS_ENABLED=OFF \
    -DCGAL_ENABLED=OFF \
    -DLSD_ENABLED=OFF \
    -DONNX_ENABLED=OFF \
    -DFETCH_ONNX=OFF \
    -DDOWNLOAD_ENABLED=OFF \
    -DCASPAR_ENABLED=OFF \
    -DTESTS_ENABLED=OFF \
    -DBENCHMARK_ENABLED=OFF \
    -DALL_SOURCE_TARGET=OFF \
    -DFETCH_POSELIB=ON \
    -DFETCH_FAISS=ON \
    -DFAISS_ENABLE_GPU=OFF \
    -DFAISS_ENABLE_METAL=OFF \
    -DFAISS_ENABLE_PYTHON=OFF \
    -DFAISS_ENABLE_MKL=OFF \
    -DFAISS_OPT_LEVEL=generic

  for option in \
    GUI_ENABLED \
    CUDA_ENABLED \
    OPENGL_ENABLED \
    MVS_ENABLED \
    CGAL_ENABLED \
    LSD_ENABLED \
    ONNX_ENABLED \
    FETCH_ONNX \
    DOWNLOAD_ENABLED \
    CASPAR_ENABLED \
    TESTS_ENABLED \
    FAISS_ENABLE_GPU \
    FAISS_ENABLE_METAL \
    FAISS_ENABLE_PYTHON \
    FAISS_ENABLE_MKL; do
    cache_is "$option" OFF
  done
  cache_is FAISS_OPT_LEVEL generic
  cache_is CMAKE_C_COMPILER "$SELECTED_C_COMPILER"
  cache_is CMAKE_CXX_COMPILER "$SELECTED_CXX_COMPILER"
  cache_is CMAKE_LINKER "$SELECTED_LINKER"
  cache_is CMAKE_AR "$SELECTED_ARCHIVER"
  cache_is CMAKE_RANLIB "$SELECTED_RANLIB"
  cache_is CMAKE_MAKE_PROGRAM "$NINJA_BIN"
  cache_is CMAKE_BUILD_WITH_INSTALL_RPATH ON
  cache_is CMAKE_INSTALL_RPATH "@executable_path/../lib"
  cache_is CMAKE_INSTALL_RPATH_USE_LINK_PATH OFF
  cache_is CMAKE_OSX_SYSROOT "$MACOS_SDK_PATH"
  cache_is CMAKE_C_FLAGS "$prefix_map_flags"
  cache_is CMAKE_CXX_FLAGS "$prefix_map_flags"
  cache_is CMAKE_EXE_LINKER_FLAGS -Wl,-dead_strip
  cache_is Ceres_DIR "$CERES_INSTALL/lib/cmake/Ceres"
  cache_is OpenImageIO_DIR "$OPENIMAGEIO_INSTALL/lib/cmake/OpenImageIO"
  cache_is gflags_DIR "$gflags_prefix/lib/cmake/gflags"
  if "$RG_BIN" -n -i 'cholmod|SuiteSparse' \
    "$BUILD/CMakeCache.txt" "$BUILD/build.ninja" "$BUILD/compile_commands.json" >/dev/null; then
    die "native COLMAP build graph retains CHOLMOD or SuiteSparse"
  fi

  "$SELECTED_PYTHON" - \
    "$BUILD/compile_commands.json" \
    "$ROOT" \
    "$SELECTED_C_COMPILER" \
    "$SELECTED_CXX_COMPILER" <<'PY'
import json
import shlex
import sys
from pathlib import Path

root = sys.argv[2]
selected_c_compiler = sys.argv[3]
selected_cxx_compiler = sys.argv[4]
required_prefix_maps = {
    f"-ffile-prefix-map={root}=/easysplat",
    f"-fdebug-prefix-map={root}=/easysplat",
}
for entry in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")):
    command = entry.get("command", "")
    tokens = entry.get("arguments") or shlex.split(command)
    source = entry.get("file", "").replace("\\", "/").lower()
    selected_compiler = (
        selected_cxx_compiler
        if source.endswith((".cc", ".cpp", ".cxx", ".mm"))
        else selected_c_compiler
    )
    if not tokens or tokens[0] != selected_compiler:
        raise SystemExit(f"unselected compiler entered the build: {source}")
    if any(part in source for part in (
        "/thirdparty/lsd/",
        "/thirdparty/siftgpu/",
        "/thirdparty/symforce-caspar/",
        "/onnxruntime/",
    )):
        raise SystemExit(f"forbidden COLMAP source entered the build: {source}")
    forbidden_pairs = (("-mcpu", "native"), ("-march", "native"))
    has_split_flag = any(
        (tokens[index], tokens[index + 1]) in forbidden_pairs
        for index in range(len(tokens) - 1)
    )
    has_joined_flag = any(
        token.partition("=")[1] and
        (token.partition("=")[0], token.partition("=")[2]) in forbidden_pairs
        for token in tokens
    )
    if has_split_flag or has_joined_flag:
        raise SystemExit(f"host-specific compiler tuning entered the build: {source}")
    if not required_prefix_maps.issubset(tokens):
        raise SystemExit(f"compiler prefix maps are absent: {source}")
PY

  if "$RG_BIN" -n '(^|[[:space:]])-isystem[[:space:]]+/opt/homebrew/include([[:space:]]|$)' \
    "$BUILD/compile_commands.json" >/dev/null; then
    die "generic Homebrew include path entered the configured build"
  fi

  if "$CMAKE_BIN" --build "$BUILD" --target help | \
    grep -Eiq '(^|[^[:alnum:]_])(colmap_lsd|colmap_sift_gpu|caspar|onnxruntime)([^[:alnum:]_]|$)'; then
    die "forbidden COLMAP target was generated"
  fi
  if "$RG_BIN" -n '/opt/homebrew/(opt|Cellar)/(ceres-solver|suite-sparse|openimageio)/' \
    "$BUILD/build.ninja" "$BUILD/compile_commands.json" >/dev/null; then
    die "Homebrew Ceres, SuiteSparse, or OpenImageIO leaked into the configured build"
  fi
  "$RG_BIN" -F "$CERES_INSTALL/lib/libceres.a" "$BUILD/build.ninja" >/dev/null || \
    die "static Ceres library is absent from the configured build"
  "$RG_BIN" -F "$OPENIMAGEIO_INSTALL/lib/libOpenImageIO.a" "$BUILD/build.ninja" >/dev/null || \
    die "static OpenImageIO library is absent from the configured build"
}

stage_license() {
  local source_dir="$1"
  local destination="$2"
  local source
  source="$(find "$source_dir" -maxdepth 1 -type f -iname 'LICENSE*' -print | LC_ALL=C sort | head -n 1)"
  [ -n "$source" ] || die "license file is missing in $source_dir"
  install -m 0644 "$source" "$destination"
}

stage_metadata() {
  local licenses="$INSTALL/licenses/COLMAP"
  local binary_sha256 source_tree_sha256 vlfeat_tree_sha256
  local support_receipt="$COLMAP_SUPPORT_INSTALL/build_info.json"
  local ceres_receipt="$CERES_INSTALL/build_info.json"
  local openimageio_receipt="$OPENIMAGEIO_INSTALL/build_info.json"
  mkdir -p "$licenses"
  install -m 0644 "$SRC/COPYING.txt" "$INSTALL/licenses/COLMAP/COPYING.txt"
  install -m 0644 "$SRC/src/thirdparty/VLFeat/LICENSE" "$licenses/VLFeat-LICENSE"
  stage_license "$BUILD/_deps/poselib-src" "$licenses/PoseLib-LICENSE"
  stage_license "$BUILD/_deps/faiss-src" "$licenses/FAISS-LICENSE"

  source_tree_sha256="$("$GIT_BIN" -C "$SRC" ls-tree -r --full-tree "$COLMAP_COMMIT" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  vlfeat_tree_sha256="$("$GIT_BIN" -C "$SRC" ls-tree -r --full-tree "$COLMAP_COMMIT" src/thirdparty/VLFeat | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  binary_sha256="$(/usr/bin/shasum -a 256 "$INSTALL/bin/colmap" | /usr/bin/awk '{print $1}')"
  for receipt in \
    "$support_receipt" \
    "$ceres_receipt" \
    "$openimageio_receipt"; do
    [ -s "$receipt" ] || die "dependency receipt is missing: $receipt"
  done
  "$SELECTED_PYTHON" - \
    "$INSTALL/build_info.json" \
    "$COLMAP_REPO" \
    "$COLMAP_COMMIT" \
    "$COLMAP_VERSION" \
    "$source_tree_sha256" \
    "$binary_sha256" \
    "$CERES_COMMIT" \
    "$OPENIMAGEIO_COMMIT" \
    "$POSELIB_URL" \
    "$POSELIB_COMMIT" \
    "$POSELIB_SHA256" \
    "$vlfeat_tree_sha256" \
    "$FAISS_URL" \
    "$FAISS_COMMIT" \
    "$FAISS_VERSION" \
    "$FAISS_SHA256" \
    "$SOURCE_DATE_EPOCH" \
    "$FROZEN_WRAPPER_SHA256" \
    "$FROZEN_IMPLEMENTATION_SHA256" \
    "$FROZEN_SUPERVISOR_SHA256" \
    "$FROZEN_PROMOTER_SHA256" \
    "$FROZEN_COLMAP_PATCH_SHA256" \
    "$FROZEN_RETRIEVER_HEADER_SHA256" \
    "$FROZEN_RETRIEVER_SOURCE_SHA256" \
    "$FROZEN_OVERLAY_SHA256" \
    "$support_receipt" \
    "$ceres_receipt" \
    "$openimageio_receipt" \
    "$CMAKE_BIN" \
    "$NINJA_BIN" \
    "$GIT_BIN" \
    "$RG_BIN" \
    "$SELECTED_PYTHON" \
    "$SELECTED_C_COMPILER" \
    "$SELECTED_CXX_COMPILER" \
    "$SELECTED_LINKER" \
    "$SELECTED_ARCHIVER" \
    "$SELECTED_RANLIB" \
    "$SELECTED_LIPO" \
    "$SELECTED_VTOOL" \
    "$XCODEBUILD_BIN" \
    "$COLMAP_SUPPORT_INSTALL" \
    "$CERES_INSTALL" \
    "$OPENIMAGEIO_INSTALL" \
    "$MACOS_SDK_PATH/SDKSettings.json" \
    "$MACOS_SDK_VERSION" \
    "$MACOS_SDK_BUILD_VERSION" \
    "$("$XCODEBUILD_BIN" -version)" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    destination,
    source_url,
    source_commit,
    source_version,
    source_tree_sha256,
    executable_sha256,
    ceres_commit,
    openimageio_commit,
    poselib_url,
    poselib_commit,
    poselib_sha256,
    vlfeat_tree_sha256,
    faiss_url,
    faiss_commit,
    faiss_version,
    faiss_sha256,
    source_date_epoch_raw,
    builder_sha256,
    builder_implementation_sha256,
    build_supervisor_sha256,
    promoter_sha256,
    patch_sha256,
    overlay_header_sha256,
    overlay_source_sha256,
    overlay_combined_sha256,
    support_receipt_path,
    ceres_receipt_path,
    openimageio_receipt_path,
    cmake_path,
    ninja_path,
    git_path,
    rg_path,
    python_path,
    clang_path,
    clangxx_path,
    ld_path,
    ar_path,
    ranlib_path,
    lipo_path,
    vtool_path,
    xcodebuild_path,
    support_prefix,
    ceres_prefix,
    openimageio_prefix,
    sdk_settings_path,
    sdk_version,
    sdk_build_version,
    xcode_version,
) = sys.argv[1:]


def sha256(raw_path: str) -> str:
    digest = hashlib.sha256()
    with Path(raw_path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verified_library_hashes(
    receipt_path: str,
    prefix_path: str,
) -> dict[str, str]:
    receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
    declared: dict[str, str] = {}
    for entry in receipt.get("libraries", []):
        declared[f"lib/{entry['file']}"] = entry["sha256"]
    for relative_path, digest in receipt.get("library_sha256", {}).items():
        relative = (
            relative_path
            if "/" in relative_path
            else f"lib/{relative_path}"
        )
        declared[relative] = digest
    if not declared:
        raise SystemExit(f"dependency receipt has no library hashes: {receipt_path}")
    for relative_path, expected in declared.items():
        library_path = Path(prefix_path) / relative_path
        if not library_path.is_file() or library_path.is_symlink():
            raise SystemExit(f"declared dependency library is missing: {library_path}")
        if sha256(str(library_path)) != expected:
            raise SystemExit(f"dependency library hash mismatch: {library_path}")
    return dict(sorted(declared.items()))


source_date_epoch = int(source_date_epoch_raw)
for label, digest in (
    ("builder", builder_sha256),
    ("builder implementation", builder_implementation_sha256),
    ("build supervisor", build_supervisor_sha256),
    ("promoter", promoter_sha256),
    ("patch", patch_sha256),
    ("overlay header", overlay_header_sha256),
    ("overlay source", overlay_source_sha256),
    ("combined overlay", overlay_combined_sha256),
):
    if len(digest) != 64 or any(
        character not in "0123456789abcdef" for character in digest
    ):
        raise SystemExit(f"invalid frozen {label} digest")
dependency_receipts = {
    "colmap-support": support_receipt_path,
    "ceres": ceres_receipt_path,
    "openimageio": openimageio_receipt_path,
}
dependency_prefixes = {
    "colmap-support": support_prefix,
    "ceres": ceres_prefix,
    "openimageio": openimageio_prefix,
}
dependency_library_sha256 = {
    name: verified_library_hashes(path, dependency_prefixes[name])
    for name, path in sorted(dependency_receipts.items())
}
dependency_tree_sha256 = {
    name: json.loads(Path(path).read_text(encoding="utf-8")).get(
        "install_tree_sha256"
    )
    for name, path in sorted(dependency_receipts.items())
}
if any(
    not isinstance(digest, str) or len(digest) != 64
    for digest in dependency_tree_sha256.values()
):
    raise SystemExit("dependency receipt has no valid install tree hash")
build_tool_paths = {
    "cmake": cmake_path,
    "ninja": ninja_path,
    "git": git_path,
    "rg": rg_path,
    "python3": python_path,
    "clang": clang_path,
    "clang++": clangxx_path,
    "ld": ld_path,
    "ar": ar_path,
    "ranlib": ranlib_path,
    "lipo": lipo_path,
    "vtool": vtool_path,
    "xcodebuild": xcodebuild_path,
}
payload = {
    "schema_version": 2,
    "toolchain_name": "colmap",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "source_tree_sha256": source_tree_sha256,
    "easysplat_overlay_sha256": overlay_combined_sha256,
    "license": "BSD-3-Clause",
    "executable_sha256": executable_sha256,
    "dependency_pins": {
        "ceres": ceres_commit,
        "openimageio": openimageio_commit,
    },
    "build_inputs": {
        "builder_sha256": builder_sha256,
        "builder_implementation_sha256": builder_implementation_sha256,
        "build_supervisor_sha256": build_supervisor_sha256,
        "promoter_sha256": promoter_sha256,
        "patch_sha256": patch_sha256,
        "overlay_sha256": {
            "local_vocab_retriever.h": overlay_header_sha256,
            "local_vocab_retriever.cc": overlay_source_sha256,
        },
        "dependency_receipt_sha256": {
            name: sha256(path)
            for name, path in sorted(dependency_receipts.items())
        },
        "dependency_library_sha256": dependency_library_sha256,
        "dependency_tree_sha256": dependency_tree_sha256,
    },
    "build_options": {
        "architecture": "arm64",
        "build_type": "Release",
        "deployment_target": "15.0",
        "faiss_opt_level": "generic",
        "file_prefix_root": "/easysplat",
        "gpu": False,
        "mvs": False,
        "sdk_version": sdk_version,
        "tests": False,
    },
    "build_tools": {
        name: {
            "executable": Path(path).name,
            "sha256": sha256(path),
        }
        for name, path in sorted(build_tool_paths.items())
    },
    "sdk": {
        "build_version": sdk_build_version,
        "platform": "macosx",
        "settings_sha256": sha256(sdk_settings_path),
        "version": sdk_version,
        "xcode_version": xcode_version,
    },
    "dependencies": {
        "faiss": {
            "source_url": faiss_url,
            "source_commit": faiss_commit,
            "source_version": faiss_version,
            "source_archive_sha256": faiss_sha256,
            "license": "MIT",
            "license_files": ["licenses/COLMAP/FAISS-LICENSE"],
            "linkage": "compiled-in",
        },
        "poselib": {
            "source_url": poselib_url,
            "source_commit": poselib_commit,
            "source_version": poselib_commit,
            "source_archive_sha256": poselib_sha256,
            "license": "BSD-3-Clause",
            "license_files": ["licenses/COLMAP/PoseLib-LICENSE"],
            "linkage": "compiled-in",
        },
        "vlfeat": {
            "source_url": f"{source_url.removesuffix('.git')}/tree/{source_commit}/src/thirdparty/VLFeat",
            "source_commit": source_commit,
            "source_version": f"vendored-at-colmap-{source_version}",
            "source_tree_sha256": vlfeat_tree_sha256,
            "license": "BSD-2-Clause",
            "license_files": ["licenses/COLMAP/VLFeat-LICENSE"],
            "linkage": "compiled-in",
        },
    },
    "enabled_capabilities": [
        "feature_extractor",
        "matches_importer",
        "local_vocab_retriever",
        "mapper",
        "point_triangulator",
        "bundle_adjuster",
        "model_analyzer",
        "image_undistorter",
        "model_converter",
    ],
    "disabled_capabilities": [
        "GUI",
        "CUDA",
        "OpenGL",
        "MVS",
        "CGAL",
        "LSD",
        "ONNX",
        "downloads",
        "CASPAR",
        "FAISS GPU",
        "FAISS Metal",
        "FAISS Python",
        "FAISS MKL",
        "METIS",
        "hierarchical reconstruction",
        "automatic reconstruction",
        "PoissonRecon",
    ],
    "deployment_target": "macOS 15.0",
    "source_date_epoch": source_date_epoch,
    "build_timestamp": datetime.fromtimestamp(
        source_date_epoch, timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
Path(destination).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

validate_metadata() {
  "$SELECTED_PYTHON" - \
    "$INSTALL/build_info.json" \
    "$INSTALL/bin/colmap" \
    "$FROZEN_WRAPPER_SHA256" \
    "$FROZEN_IMPLEMENTATION_SHA256" \
    "$FROZEN_SUPERVISOR_SHA256" \
    "$FROZEN_PROMOTER_SHA256" \
    "$FROZEN_COLMAP_PATCH_SHA256" \
    "$FROZEN_RETRIEVER_HEADER_SHA256" \
    "$FROZEN_RETRIEVER_SOURCE_SHA256" \
    "$FROZEN_OVERLAY_SHA256" \
    "$COLMAP_SUPPORT_INSTALL/build_info.json" \
    "$COLMAP_SUPPORT_INSTALL" \
    "$CERES_INSTALL/build_info.json" \
    "$CERES_INSTALL" \
    "$OPENIMAGEIO_INSTALL/build_info.json" \
    "$OPENIMAGEIO_INSTALL" \
    "$SOURCE_DATE_EPOCH" \
    "$ROOT" \
    "$COLMAP_REPO" \
    "$COLMAP_COMMIT" \
    "$COLMAP_VERSION" \
    "$CERES_COMMIT" \
    "$OPENIMAGEIO_COMMIT" \
    "$SRC" \
    "$CMAKE_BIN" \
    "$NINJA_BIN" \
    "$GIT_BIN" \
    "$RG_BIN" \
    "$SELECTED_PYTHON" \
    "$SELECTED_C_COMPILER" \
    "$SELECTED_CXX_COMPILER" \
    "$SELECTED_LINKER" \
    "$SELECTED_ARCHIVER" \
    "$SELECTED_RANLIB" \
    "$SELECTED_LIPO" \
    "$SELECTED_VTOOL" \
    "$XCODEBUILD_BIN" \
    "$MACOS_SDK_PATH/SDKSettings.json" \
    "$MACOS_SDK_VERSION" \
    "$MACOS_SDK_BUILD_VERSION" \
    "$("$XCODEBUILD_BIN" -version)" \
    "$POSELIB_URL" \
    "$POSELIB_COMMIT" \
    "$POSELIB_SHA256" \
    "$FAISS_URL" \
    "$FAISS_COMMIT" \
    "$FAISS_VERSION" \
    "$FAISS_SHA256" <<'PY'
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    receipt_path,
    executable_path,
    builder_sha256,
    builder_implementation_sha256,
    build_supervisor_sha256,
    promoter_sha256,
    patch_sha256,
    overlay_header_sha256,
    overlay_source_sha256,
    overlay_combined_sha256,
    support_receipt_path,
    support_prefix,
    ceres_receipt_path,
    ceres_prefix,
    openimageio_receipt_path,
    openimageio_prefix,
    source_date_epoch_raw,
    root,
    source_url,
    source_commit,
    source_version,
    ceres_commit,
    openimageio_commit,
    source_checkout,
    cmake_path,
    ninja_path,
    git_path,
    rg_path,
    python_path,
    clang_path,
    clangxx_path,
    ld_path,
    ar_path,
    ranlib_path,
    lipo_path,
    vtool_path,
    xcodebuild_path,
    sdk_settings_path,
    sdk_version,
    sdk_build_version,
    xcode_version,
    poselib_url,
    poselib_commit,
    poselib_sha256,
    faiss_url,
    faiss_commit,
    faiss_version,
    faiss_sha256,
) = sys.argv[1:]


def sha256(raw_path: str) -> str:
    digest = hashlib.sha256()
    with Path(raw_path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verified_library_hashes(
    dependency_receipt_path: str,
    prefix_path: str,
) -> dict[str, str]:
    receipt = json.loads(
        Path(dependency_receipt_path).read_text(encoding="utf-8")
    )
    declared: dict[str, str] = {}
    for entry in receipt.get("libraries", []):
        declared[f"lib/{entry['file']}"] = entry["sha256"]
    for relative_path, digest in receipt.get("library_sha256", {}).items():
        relative = relative_path if "/" in relative_path else f"lib/{relative_path}"
        if relative in declared and declared[relative] != digest:
            raise SystemExit(f"conflicting dependency library hash: {relative}")
        declared[relative] = digest
    if not declared:
        raise SystemExit(
            f"dependency receipt has no library hashes: {dependency_receipt_path}"
        )
    for relative_path, expected_digest in sorted(declared.items()):
        relative = Path(relative_path)
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit(f"unsafe dependency library path: {relative_path}")
        library_path = Path(prefix_path) / relative
        if not library_path.is_file() or library_path.is_symlink():
            raise SystemExit(f"declared dependency library is missing: {library_path}")
        if sha256(str(library_path)) != expected_digest:
            raise SystemExit(f"dependency library hash mismatch: {library_path}")
    return dict(sorted(declared.items()))


def git_tree_sha256(pathspec=None) -> str:
    command = [
        git_path,
        "-C",
        source_checkout,
        "ls-tree",
        "-r",
        "--full-tree",
        source_commit,
    ]
    if pathspec is not None:
        command.extend(("--", pathspec))
    result = subprocess.run(command, check=True, capture_output=True)
    return hashlib.sha256(result.stdout).hexdigest()


dependency_receipts = {
    "colmap-support": support_receipt_path,
    "ceres": ceres_receipt_path,
    "openimageio": openimageio_receipt_path,
}
dependency_prefixes = {
    "colmap-support": support_prefix,
    "ceres": ceres_prefix,
    "openimageio": openimageio_prefix,
}
dependency_library_sha256 = {
    name: verified_library_hashes(path, dependency_prefixes[name])
    for name, path in sorted(dependency_receipts.items())
}
dependency_tree_sha256 = {
    name: json.loads(Path(path).read_text(encoding="utf-8")).get(
        "install_tree_sha256"
    )
    for name, path in sorted(dependency_receipts.items())
}
if any(
    not isinstance(digest, str) or len(digest) != 64
    for digest in dependency_tree_sha256.values()
):
    raise SystemExit("dependency receipt has no valid install tree hash")
build_tool_paths = {
    "cmake": cmake_path,
    "ninja": ninja_path,
    "git": git_path,
    "rg": rg_path,
    "python3": python_path,
    "clang": clang_path,
    "clang++": clangxx_path,
    "ld": ld_path,
    "ar": ar_path,
    "ranlib": ranlib_path,
    "lipo": lipo_path,
    "vtool": vtool_path,
    "xcodebuild": xcodebuild_path,
}
source_date_epoch = int(source_date_epoch_raw)
for label, digest in (
    ("builder", builder_sha256),
    ("builder implementation", builder_implementation_sha256),
    ("build supervisor", build_supervisor_sha256),
    ("promoter", promoter_sha256),
    ("patch", patch_sha256),
    ("overlay header", overlay_header_sha256),
    ("overlay source", overlay_source_sha256),
    ("combined overlay", overlay_combined_sha256),
):
    if len(digest) != 64 or any(
        character not in "0123456789abcdef" for character in digest
    ):
        raise SystemExit(f"invalid frozen {label} digest")
expected_timestamp = datetime.fromtimestamp(
    source_date_epoch, timezone.utc
).strftime("%Y-%m-%dT%H:%M:%SZ")
expected_payload = {
    "schema_version": 2,
    "toolchain_name": "colmap",
    "source_url": source_url,
    "source_commit": source_commit,
    "source_version": source_version,
    "source_tree_sha256": git_tree_sha256(),
    "easysplat_overlay_sha256": overlay_combined_sha256,
    "license": "BSD-3-Clause",
    "executable_sha256": sha256(executable_path),
    "dependency_pins": {
        "ceres": ceres_commit,
        "openimageio": openimageio_commit,
    },
    "build_inputs": {
        "builder_sha256": builder_sha256,
        "builder_implementation_sha256": builder_implementation_sha256,
        "build_supervisor_sha256": build_supervisor_sha256,
        "promoter_sha256": promoter_sha256,
        "patch_sha256": patch_sha256,
        "overlay_sha256": {
            "local_vocab_retriever.h": overlay_header_sha256,
            "local_vocab_retriever.cc": overlay_source_sha256,
        },
        "dependency_receipt_sha256": {
            name: sha256(path)
            for name, path in sorted(dependency_receipts.items())
        },
        "dependency_library_sha256": dependency_library_sha256,
        "dependency_tree_sha256": dependency_tree_sha256,
    },
    "build_options": {
        "architecture": "arm64",
        "build_type": "Release",
        "deployment_target": "15.0",
        "faiss_opt_level": "generic",
        "file_prefix_root": "/easysplat",
        "gpu": False,
        "mvs": False,
        "sdk_version": sdk_version,
        "tests": False,
    },
    "build_tools": {
        name: {
            "executable": Path(path).name,
            "sha256": sha256(path),
        }
        for name, path in sorted(build_tool_paths.items())
    },
    "sdk": {
        "build_version": sdk_build_version,
        "platform": "macosx",
        "settings_sha256": sha256(sdk_settings_path),
        "version": sdk_version,
        "xcode_version": xcode_version,
    },
    "dependencies": {
        "faiss": {
            "source_url": faiss_url,
            "source_commit": faiss_commit,
            "source_version": faiss_version,
            "source_archive_sha256": faiss_sha256,
            "license": "MIT",
            "license_files": ["licenses/COLMAP/FAISS-LICENSE"],
            "linkage": "compiled-in",
        },
        "poselib": {
            "source_url": poselib_url,
            "source_commit": poselib_commit,
            "source_version": poselib_commit,
            "source_archive_sha256": poselib_sha256,
            "license": "BSD-3-Clause",
            "license_files": ["licenses/COLMAP/PoseLib-LICENSE"],
            "linkage": "compiled-in",
        },
        "vlfeat": {
            "source_url": (
                f"{source_url.removesuffix('.git')}/tree/{source_commit}"
                "/src/thirdparty/VLFeat"
            ),
            "source_commit": source_commit,
            "source_version": f"vendored-at-colmap-{source_version}",
            "source_tree_sha256": git_tree_sha256("src/thirdparty/VLFeat"),
            "license": "BSD-2-Clause",
            "license_files": ["licenses/COLMAP/VLFeat-LICENSE"],
            "linkage": "compiled-in",
        },
    },
    "enabled_capabilities": [
        "feature_extractor",
        "matches_importer",
        "local_vocab_retriever",
        "mapper",
        "point_triangulator",
        "bundle_adjuster",
        "model_analyzer",
        "image_undistorter",
        "model_converter",
    ],
    "disabled_capabilities": [
        "GUI",
        "CUDA",
        "OpenGL",
        "MVS",
        "CGAL",
        "LSD",
        "ONNX",
        "downloads",
        "CASPAR",
        "FAISS GPU",
        "FAISS Metal",
        "FAISS Python",
        "FAISS MKL",
        "METIS",
        "hierarchical reconstruction",
        "automatic reconstruction",
        "PoissonRecon",
    ],
    "deployment_target": "macOS 15.0",
    "source_date_epoch": source_date_epoch,
    "build_timestamp": expected_timestamp,
}
payload = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
if payload != expected_payload:
    for key in sorted(set(payload) | set(expected_payload)):
        if payload.get(key) != expected_payload.get(key):
            raise SystemExit(f"native COLMAP receipt field differs: {key}")
    raise SystemExit("native COLMAP receipt differs from the expected payload")

install_root = Path(receipt_path).parent
license_paths = {
    "licenses/COLMAP/COPYING.txt",
    *(path for item in expected_payload["dependencies"].values()
      for path in item["license_files"]),
}
for relative_path in sorted(license_paths):
    if not (install_root / relative_path).is_file():
        raise SystemExit(f"native COLMAP license is missing: {relative_path}")

encoded = json.dumps(payload, sort_keys=True)
for forbidden in (root, "/Users/", "/private/tmp/", "/private/var/folders/"):
    if forbidden and forbidden in encoded:
        raise SystemExit(f"native COLMAP receipt leaks a private path: {forbidden}")
PY
}

normalize_stage_system_metadata() {
  "$SELECTED_PYTHON" - \
    "$INSTALL" \
    "$INSTALL_STAGE_DEVICE" \
    "$INSTALL_STAGE_INODE" <<'PY'
import ctypes
import os
import stat
import sys
from pathlib import Path

DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
FILE_OPEN_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
MAX_BOUND_ENTRIES = 128
SYSTEM_PROVENANCE = "com.apple.provenance"

root = Path(sys.argv[1])
expected_root_device = int(sys.argv[2])
expected_root_inode = int(sys.argv[3])

libc = ctypes.CDLL(None, use_errno=True)
flistxattr = libc.flistxattr
flistxattr.argtypes = (
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_int,
)
flistxattr.restype = ctypes.c_ssize_t
fremovexattr = libc.fremovexattr
fremovexattr.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
fremovexattr.restype = ctypes.c_int


def stable_metadata(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def require_same_node(label, *items):
    expected = stable_metadata(items[0])
    if any(stable_metadata(item) != expected for item in items[1:]):
        raise SystemExit(
            f"native COLMAP system metadata entry changed: {label}"
        )


def attributes(descriptor):
    ctypes.set_errno(0)
    size = flistxattr(descriptor, None, 0, 0)
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size == 0:
        return ()
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    actual = flistxattr(descriptor, buffer, size, 0)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if actual != size:
        raise OSError("extended attribute list changed during normalization")
    return tuple(
        sorted(
            os.fsdecode(name)
            for name in bytes(buffer.raw[:actual]).split(b"\0")
            if name
        )
    )


parent_descriptor = os.open(root.parent, DIRECTORY_OPEN_FLAGS)
records = []


def verify_record(record):
    label, descriptor, parent, name, initial = record
    opened = os.fstat(descriptor)
    named = os.stat(name, dir_fd=parent, follow_symlinks=False)
    require_same_node(label, initial, opened, named)
    if stat.S_ISREG(opened.st_mode) and opened.st_nlink != 1:
        raise SystemExit(
            "native COLMAP system metadata normalization rejects a "
            f"multiply linked file: {label}"
        )


def bind_directory(descriptor, label):
    for name in sorted(os.listdir(descriptor), key=os.fsencode):
        if len(records) >= MAX_BOUND_ENTRIES:
            raise SystemExit(
                "native COLMAP system metadata tree exceeds its bounded closure"
            )
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        child_label = f"{label}/{name}" if label != "." else name
        if stat.S_ISDIR(before.st_mode):
            child = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=descriptor)
            opened = os.fstat(child)
            named = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            require_same_node(child_label, before, opened, named)
            record = (child_label, child, descriptor, name, opened)
            records.append(record)
            bind_directory(child, child_label)
            verify_record(record)
        elif stat.S_ISREG(before.st_mode):
            if before.st_nlink != 1:
                raise SystemExit(
                    "native COLMAP system metadata normalization rejects a "
                    f"multiply linked file: {child_label}"
                )
            child = os.open(name, FILE_OPEN_FLAGS, dir_fd=descriptor)
            opened = os.fstat(child)
            named = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            require_same_node(child_label, before, opened, named)
            record = (child_label, child, descriptor, name, opened)
            records.append(record)
        else:
            raise SystemExit(
                "native COLMAP system metadata normalization rejects an "
                f"unsupported entry: {child_label}"
            )


try:
    root_before = os.stat(root.name, dir_fd=parent_descriptor, follow_symlinks=False)
    if not stat.S_ISDIR(root_before.st_mode):
        raise SystemExit("native COLMAP install stage is not a directory")
    root_descriptor = os.open(
        root.name,
        DIRECTORY_OPEN_FLAGS,
        dir_fd=parent_descriptor,
    )
    root_opened = os.fstat(root_descriptor)
    root_named = os.stat(
        root.name,
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    require_same_node(".", root_before, root_opened, root_named)
    if (
        root_opened.st_dev != expected_root_device
        or root_opened.st_ino != expected_root_inode
    ):
        raise SystemExit("native COLMAP install stage owned identity changed")
    records.append((".", root_descriptor, parent_descriptor, root.name, root_opened))
    bind_directory(root_descriptor, ".")
    for record in records:
        verify_record(record)

    bound_attributes = [
        (record, attributes(record[1]))
        for record in records
    ]
    for record, names in bound_attributes:
        label = record[0]
        unexpected = tuple(name for name in names if name != SYSTEM_PROVENANCE)
        if unexpected:
            raise SystemExit(
                "native COLMAP install has an unexpected extended attribute: "
                f"{unexpected[0]} on {label}"
            )
    provenance_records = [
        record
        for record, names in reversed(bound_attributes)
        if SYSTEM_PROVENANCE in names
    ]
    for record in provenance_records:
        label, descriptor, _, _, _ = record
        verify_record(record)
        if attributes(descriptor) != (SYSTEM_PROVENANCE,):
            raise SystemExit(
                "native COLMAP system metadata changed before normalization: "
                f"{label}"
            )
        ctypes.set_errno(0)
        if fremovexattr(
            descriptor,
            SYSTEM_PROVENANCE.encode("utf-8"),
            0,
        ) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), label)
    for record in records:
        verify_record(record)
        if attributes(record[1]):
            raise SystemExit(
                "native COLMAP system metadata normalization was incomplete: "
                f"{record[0]}"
            )
finally:
    for _, descriptor, _, _, _ in reversed(records):
        os.close(descriptor)
    os.close(parent_descriptor)
PY
}

validate_stage_extended_metadata() {
  "$SELECTED_PYTHON" - "$INSTALL" <<'PY'
import ctypes
import errno
import os
import sys
from pathlib import Path

ACL_TYPE_EXTENDED = 0x00000100
ACL_FIRST_ENTRY = 0
XATTR_NOFOLLOW = 0x0001

root = Path(sys.argv[1])
paths = [root]
for current, directory_names, file_names in os.walk(root, followlinks=False):
    directory_names.sort()
    file_names.sort()
    current_path = Path(current)
    paths.extend(current_path / name for name in directory_names)
    paths.extend(current_path / name for name in file_names)

libc = ctypes.CDLL(None, use_errno=True)
acl_get_link = libc.acl_get_link_np
acl_get_link.argtypes = (ctypes.c_char_p, ctypes.c_int)
acl_get_link.restype = ctypes.c_void_p
acl_get_entry = libc.acl_get_entry
acl_get_entry.argtypes = (
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_void_p),
)
acl_get_entry.restype = ctypes.c_int
acl_free = libc.acl_free
acl_free.argtypes = (ctypes.c_void_p,)
acl_free.restype = ctypes.c_int
listxattr = libc.listxattr
listxattr.argtypes = (
    ctypes.c_char_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_int,
)
listxattr.restype = ctypes.c_ssize_t


def has_extended_attributes(path: Path) -> bool:
    ctypes.set_errno(0)
    size = listxattr(os.fsencode(path), None, 0, XATTR_NOFOLLOW)
    if size >= 0:
        return size > 0
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), path)


def has_extended_acl(path: Path) -> bool:
    ctypes.set_errno(0)
    acl = acl_get_link(os.fsencode(path), ACL_TYPE_EXTENDED)
    if not acl:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return False
        raise OSError(error, os.strerror(error), path)
    try:
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = acl_get_entry(acl, ACL_FIRST_ENTRY, ctypes.byref(entry))
        if result == 0:
            return True
        if result == 1:
            return False
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), path)
    finally:
        if acl_free(acl) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), path)


for path in paths:
    if has_extended_acl(path):
        raise SystemExit(f"native COLMAP install has an extended ACL: {path}")
for path in paths:
    if has_extended_attributes(path):
        raise SystemExit(
            f"native COLMAP install has extended attributes: {path}"
        )
PY
}

assert_permissive_closure() {
  local target
  local dependency
  local dependency_lower
  local run_symbols
  local forbidden='(spqr|metis|cgal|lsd|siftgpu|onnx(runtime)?|caspar|cuda|avcodec|avformat|avutil|swscale|ffmpeg|heif|de265|x264|x265|aom|dav1d|vpx|svtav1|theora|vorbis|opencolorio|ocio|tbb|freetype|webp|libraw|dcmtk)'
  local targets=("$INSTALL/bin/colmap" "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib")

  for target in "${targets[@]}"; do
    /usr/bin/file -b "$target" | /usr/bin/grep -q 'Mach-O 64-bit' || \
      die "closure contains a non-Mach-O file: $target"
    [ "$("$SELECTED_LIPO" -archs "$target")" = "arm64" ] || \
      die "closure is not exact thin arm64: $target"
    "$SELECTED_PYTHON" - "$SELECTED_VTOOL" "$target" <<'PY'
import re
import subprocess
import sys

output = subprocess.run(
    [sys.argv[1], "-show-build", sys.argv[2]],
    check=True,
    capture_output=True,
    text=True,
).stdout
if not re.search(r"^\s*platform MACOS\s*$", output, re.MULTILINE):
    raise SystemExit(f"closure does not target macOS: {sys.argv[2]}")
matches = re.findall(r"^\s*minos ([0-9.]+)\s*$", output, re.MULTILINE)
if len(matches) != 1:
    raise SystemExit(f"closure has ambiguous minimum OS metadata: {sys.argv[2]}")
parts = [int(part) for part in matches[0].split(".")]
version = tuple((parts + [0, 0, 0])[:3])
if version > (15, 0, 0):
    raise SystemExit(f"closure requires a newer macOS than 15.0: {sys.argv[2]}")
PY
    while IFS= read -r dependency; do
      dependency_lower="$(printf '%s' "$dependency" | tr '[:upper:]' '[:lower:]')"
      if [[ "$dependency_lower" =~ $forbidden ]]; then
        die "forbidden dependency in $(basename "$target"): $dependency"
      fi
      if printf '%s\n' "$dependency" | "$RG_BIN" -i 'cholmod|SuiteSparse' >/dev/null; then
        die "native COLMAP Mach-O closure retains CHOLMOD or SuiteSparse: $dependency"
      fi
      if [[ "$dependency" =~ /opt/homebrew/(opt|Cellar)/(ceres-solver|suite-sparse|openimageio)/ ]]; then
        die "Homebrew Ceres, SuiteSparse, or OpenImageIO entered the closure: $dependency"
      fi
    done < <(/usr/bin/otool -L "$target" | awk 'NR > 1 {print $1}')
  done

  "$SELECTED_PYTHON" - "$INSTALL/bin/colmap" <<'PY'
import subprocess
import sys

binary = sys.argv[1]
load_commands = subprocess.run(
    ["/usr/bin/otool", "-l", binary],
    check=True,
    capture_output=True,
    text=True,
).stdout
rpaths = []
lines = load_commands.splitlines()
for index, line in enumerate(lines):
    if line.strip() != "cmd LC_RPATH":
        continue
    for candidate in lines[index + 1:index + 4]:
        candidate = candidate.strip()
        if candidate.startswith("path ") and " (offset " in candidate:
            rpaths.append(candidate[5:].split(" (offset ", 1)[0])
            break
if rpaths != ["@executable_path/../lib"]:
    raise SystemExit("native COLMAP rpaths differ: " + ", ".join(rpaths))
dependencies = [
    line.strip().split(" ", 1)[0]
    for line in subprocess.run(
        ["/usr/bin/otool", "-L", binary],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()[1:]
    if line.strip()
]
non_system = [
    dependency
    for dependency in dependencies
    if not dependency.startswith(("/usr/lib/", "/System/Library/"))
]
if non_system != ["@rpath/libomp.dylib"]:
    raise SystemExit(
        "native COLMAP non-system closure differs: " + ", ".join(non_system)
    )
PY

  if find "$INSTALL" -type f -print | /usr/bin/grep -Ei '/(lib)?(spqr|cgal|lsd|siftgpu|onnx|caspar|cuda)[^/]*$' >/dev/null; then
    die "forbidden artifact was installed with COLMAP"
  fi
  if "$RG_BIN" -n '/opt/homebrew/(opt|Cellar)/(ceres-solver|suite-sparse|openimageio)/' \
    "$BUILD/build.ninja" "$BUILD/compile_commands.json" "$INSTALL" >/dev/null; then
    die "Homebrew Ceres, SuiteSparse, or OpenImageIO path remains in COLMAP outputs"
  fi
  run_symbols="$(
    /usr/bin/nm -gU "$INSTALL/bin/colmap" |
      /usr/bin/c++filt |
      /usr/bin/sed -nE 's/^.*colmap::(Run[A-Za-z0-9_]+).*$/\1/p' |
      LC_ALL=C sort -u
  )"
  [ "$run_symbols" = $'RunBundleAdjuster\nRunFeatureExtractor\nRunImageUndistorter\nRunIncrementalMapperImpl\nRunLocalVocabularyRetriever\nRunMapper\nRunMatchesImporter\nRunModelAnalyzer\nRunModelConverter\nRunPointTriangulator\nRunPointTriangulatorImpl' ] || \
    die "unreviewed COLMAP command implementation survived native linking"
  if /usr/bin/strings "$INSTALL/bin/colmap" | \
    "$RG_BIN" "\$COLMAP_EXE_PATH/colmap (patch_match_stereo|stereo_fusion|poisson_mesher|delaunay_mesher)|PMVSUndistorter|CMPMVSUndistorter|PMVS_EXE_PATH" >/dev/null; then
    die "image undistorter retains an unsupported output workflow"
  fi
  "$SELECTED_PYTHON" - "$INSTALL/bin/colmap" "$ROOT" "${HOME:-}" <<'PY'
import sys
from pathlib import Path

payload = Path(sys.argv[1]).read_bytes()
for marker in (
    sys.argv[2].encode(),
    sys.argv[3].encode(),
    b"/Users/",
    b"/private/tmp/",
    b"/private/var/folders/",
):
    if marker and marker in payload:
        raise SystemExit(
            f"native COLMAP contains a private build path: {marker.decode(errors='replace')}"
        )
PY
}

validate_commands() {
  local command listed_commands matches_importer_help retriever_help undistorter_rejection
  local validation_image_path="$BUILD/undistorter-validation-images"
  local validation_output_path="$BUILD/undistorter-validation-output"
  local runtime_path="$COLMAP_SUPPORT_INSTALL/lib"
  for command in \
    feature_extractor \
    matches_importer \
    local_vocab_retriever \
    mapper \
    point_triangulator \
    bundle_adjuster \
    model_analyzer \
    image_undistorter \
    model_converter; do
    DYLD_LIBRARY_PATH="$runtime_path" "$INSTALL/bin/colmap" "$command" -h >/dev/null 2>&1 || \
      die "installed COLMAP command is unavailable: $command"
  done
  listed_commands="$(
    DYLD_LIBRARY_PATH="$runtime_path" "$INSTALL/bin/colmap" help |
      awk '/^Available commands:$/ { capture = 1; next } capture && /^  / { sub(/^  /, ""); print }'
  )"
  [ "$listed_commands" = $'help\nversion\nfeature_extractor\nmatches_importer\nlocal_vocab_retriever\nmapper\npoint_triangulator\nbundle_adjuster\nmodel_analyzer\nimage_undistorter\nmodel_converter' ] || \
    die "installed COLMAP command surface differs from the shipping contract"
  matches_importer_help="$(
    DYLD_LIBRARY_PATH="$runtime_path" "$INSTALL/bin/colmap" matches_importer -h 2>&1
  )"
  printf '%s\n' "$matches_importer_help" | \
    awk '$1 == "--TwoViewGeometry.random_seed" { found = 1 } END { exit found ? 0 : 1 }' || \
    die "installed COLMAP matches_importer lacks TwoViewGeometry.random_seed"
  printf '%s\n' "$matches_importer_help" | \
    awk '$1 == "--EasySplat.require_empty_matching_results" { found = 1 } END { exit found ? 0 : 1 }' || \
    die "installed COLMAP matches_importer lacks EasySplat empty-result authority"
  retriever_help="$(
    DYLD_LIBRARY_PATH="$runtime_path" "$INSTALL/bin/colmap" \
      local_vocab_retriever -h 2>&1
  )"
  for command in image_group_list_path image_group_list_digest; do
    printf '%s\n' "$retriever_help" | \
      awk -v option="--$command" '$1 == option { found = 1 } END { exit found ? 0 : 1 }' || \
      die "installed COLMAP local_vocab_retriever lacks $command"
  done
  rm -rf "$validation_image_path" "$validation_output_path"
  mkdir -p "$validation_image_path"
  if undistorter_rejection="$(
    DYLD_LIBRARY_PATH="$runtime_path" "$INSTALL/bin/colmap" image_undistorter \
      --image_path "$validation_image_path" \
      --input_path "$BUILD/nonexistent-undistorter-model" \
      --output_path "$validation_output_path" \
      --output_type PMVS 2>&1
  )"; then
    rm -rf "$validation_image_path" "$validation_output_path"
    die "image undistorter accepted the omitted PMVS workflow"
  fi
  printf '%s' "$undistorter_rejection" | \
    "$RG_BIN" -F "supported value is {'COLMAP'}" >/dev/null || \
    die "image undistorter did not reject PMVS at argument validation"
  [ ! -e "$validation_output_path" ] || \
    die "image undistorter mutated output before rejecting PMVS"
  rm -rf "$validation_image_path" "$validation_output_path"
}

validate_relocated_runtime() {
  local relocated="$BUILD/relocated-runtime"
  rm -rf "$relocated"
  mkdir -p "$relocated/bin" "$relocated/lib"
  install -m 0755 "$INSTALL/bin/colmap" "$relocated/bin/colmap"
  install -m 0755 "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib" \
    "$relocated/lib/libomp.dylib"
  /usr/bin/env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
    "$relocated/bin/colmap" help >/dev/null || \
    die "relocated native COLMAP could not load its packaged closure"
}

validate_native_retriever() {
  local runtime_path="$COLMAP_SUPPORT_INSTALL/lib"
  EASYSPLAT_TEST_CLANG="$SELECTED_C_COMPILER" \
  EASYSPLAT_TEST_SDK="$MACOS_SDK_PATH" \
  EASYSPLAT_NATIVE_COLMAP_BIN="$INSTALL/bin/colmap" \
  EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH="$runtime_path" \
    "$SELECTED_PYTHON" "$ROOT/scripts/toolchain/tests/test_native_colmap_retriever.py" \
      NativeRetrieverTests NativeMatchesImporterTests
}

preflight() {
  [[ "$ROOT" = /* && -d "$ROOT" && ! -L "$ROOT" ]] || \
    die "bound source root is missing or unsafe"
  [ "${BASH_SOURCE[0]}" = "/dev/fd/$FROZEN_IMPLEMENTATION_FD" ] || \
    die "native COLMAP implementation is not executing from its bound copy"
  [ "$(/usr/bin/uname -m)" = "arm64" ] || \
    die "must run natively on Apple Silicon arm64"
  [ "$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)" != "1" ] || \
    die "Rosetta is unsupported"
  case "$ROOT" in
    *[[:space:]]*) die "checkout path contains whitespace; move the source checkout before building" ;;
  esac
  for tool in "$CMAKE_BIN" "$GIT_BIN" "$NINJA_BIN" "$RG_BIN"; do
    [[ "$tool" = /* && -x "$tool" ]] || \
      die "bootstrap build tool is missing or unsafe: $tool"
  done
  [ -x "$WRAPPER" ] || die "hermetic COLMAP wrapper is missing"
  [ -f "$IMPLEMENTATION" ] && [ ! -L "$IMPLEMENTATION" ] || \
    die "hermetic COLMAP implementation is missing or unsafe"
  [ -f "$BUILD_SUPERVISOR" ] && [ ! -L "$BUILD_SUPERVISOR" ] || \
    die "native COLMAP build supervisor is missing or unsafe"
  [ -x "$CERES_BUILDER" ] || die "Ceres validator is missing"
  [ -x "$OPENIMAGEIO_BUILDER" ] || die "OpenImageIO validator is missing"
  [ -x "$PROMOTER" ] || die "atomic install promoter is missing"
  [ -f "$COLMAP_SUPPORT_TESTS" ] || die "COLMAP support tests are missing"
  [ -s "$COLMAP_PATCH" ] || die "reviewed COLMAP patch is missing"

  DEVELOPER_DIR_PATH="$(/usr/bin/xcode-select -p)"
  [ -d "$DEVELOPER_DIR_PATH" ] || die "selected Xcode developer directory is missing"
  MACOS_SDK_PATH="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
  MACOS_SDK_VERSION="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --sdk macosx --show-sdk-version)"
  MACOS_SDK_BUILD_VERSION="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --sdk macosx --show-sdk-build-version)"
  SELECTED_C_COMPILER="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find clang)"
  SELECTED_CXX_COMPILER="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find clang++)"
  SELECTED_LINKER="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find ld)"
  SELECTED_ARCHIVER="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find ar)"
  SELECTED_RANLIB="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find ranlib)"
  SELECTED_PYTHON="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find python3)"
  SELECTED_LIPO="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find lipo)"
  SELECTED_VTOOL="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" /usr/bin/xcrun --find vtool)"
  XCODEBUILD_BIN="$DEVELOPER_DIR_PATH/usr/bin/xcodebuild"
  for selected_tool in \
    "$SELECTED_C_COMPILER" \
    "$SELECTED_CXX_COMPILER" \
    "$SELECTED_LINKER" \
    "$SELECTED_ARCHIVER" \
    "$SELECTED_RANLIB" \
    "$SELECTED_PYTHON" \
    "$SELECTED_LIPO" \
    "$SELECTED_VTOOL" \
    "$XCODEBUILD_BIN"; do
    [ -x "$selected_tool" ] || \
      die "selected Xcode build tool is unavailable: $selected_tool"
  done
  [ -s "$MACOS_SDK_PATH/SDKSettings.json" ] || \
    die "selected macOS SDK settings are missing"
}

promote_install() {
  local journal="$INSTALL.promotion-state" tree_receipt
  validate_stage_extended_metadata
  tree_receipt="$(run_frozen_promoter --tree-receipt \
    "$INSTALL" "$INSTALL_STAGE_DEVICE" "$INSTALL_STAGE_INODE")" || \
    die "could not bind the validated native COLMAP tree"
  validate_stage_extended_metadata
  STAGE_CLEANUP_ALLOWED=0
  run_frozen_promoter "$INSTALL" "$LIVE_INSTALL" "$tree_receipt" || \
    die "could not atomically promote native COLMAP; recovery state preserved"
  run_frozen_promoter --commit "$journal" || \
    die "could not finalize native COLMAP promotion; recovery state preserved"
}

preflight
acquire_build_lock
recover_stale_promotions
freeze_native_inputs
validate_frozen_controls
rm -rf "$BUILD" "$BUILD_HOME" "$BUILD_TMP"
create_owned_install_stage
mkdir -p "$BUILD_HOME" "$BUILD_TMP"
sanitize_environment
verify_dependency_provenance "$COLMAP_SUPPORT_INSTALL/build_info.json" colmap-support ""
"${CERES_BUILDER}" --validate-only "${CERES_INSTALL}"
"${OPENIMAGEIO_BUILDER}" --validate-only "${OPENIMAGEIO_INSTALL}"
verify_dependency_provenance \
  "$CERES_INSTALL/build_info.json" ceres-static "$CERES_COMMIT"
verify_dependency_provenance \
  "$OPENIMAGEIO_INSTALL/build_info.json" \
  openimageio-static "$OPENIMAGEIO_COMMIT" openimageio
EASYSPLAT_COLMAP_SUPPORT_ROOT="$COLMAP_SUPPORT_INSTALL" \
  "$SELECTED_PYTHON" "$COLMAP_SUPPORT_TESTS" ArtifactTests
prepare_source
configure
"$CMAKE_BIN" --build "$BUILD" --target colmap_main --parallel "$(/usr/sbin/sysctl -n hw.ncpu)"
validate_frozen_native_inputs
mkdir -p "$INSTALL/bin"
install -m 0755 "$BUILD/src/colmap/exe/colmap" "$INSTALL/bin/colmap"
stage_metadata
normalize_stage_system_metadata
validate_metadata
assert_permissive_closure
validate_commands
validate_relocated_runtime
validate_native_retriever
validate_stage_extended_metadata
await_promotion_approval
promote_install

echo "COLMAP installed to: $LIVE_INSTALL"
