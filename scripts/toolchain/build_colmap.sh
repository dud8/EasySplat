#!/bin/bash
set -euo pipefail

fail() {
  builtin printf '%s\n' "COLMAP build failed: $*" >&2
  exit 1
}

[ "$#" = "0" ] || fail "native COLMAP builder does not accept arguments"

if [ "${EASYSPLAT_FROZEN_WRAPPER:-}" != "1" ]; then
  source_directory="$(
    builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && builtin pwd -P
  )"
  wrapper="$source_directory/build_colmap.sh"
  implementation="$source_directory/build_colmap_impl.sh"
  supervisor="$source_directory/secure_colmap_build.py"
  promoter="$source_directory/atomic_swap_install.py"
  root="$(builtin cd "$source_directory/../.." && builtin pwd -P)"
  bootstrap_cmake="$(builtin type -P cmake || true)"
  bootstrap_git="$(builtin type -P git || true)"
  bootstrap_ninja="$(builtin type -P ninja || true)"
  bootstrap_rg="$(builtin type -P rg || true)"
  bootstrap_python="$(/usr/bin/xcrun --find python3 2>/dev/null || true)"
  for tool in \
    "$bootstrap_cmake" \
    "$bootstrap_git" \
    "$bootstrap_ninja" \
    "$bootstrap_rg" \
    "$bootstrap_python"; do
    [[ "$tool" = /* && -x "$tool" ]] || \
      fail "cmake, git, ninja, rg, and the selected Xcode Python must be available"
  done

  builtin exec /usr/bin/env -i \
    EASYSPLAT_BOOTSTRAP_CMAKE="$bootstrap_cmake" \
    EASYSPLAT_BOOTSTRAP_GIT="$bootstrap_git" \
    EASYSPLAT_BOOTSTRAP_NINJA="$bootstrap_ninja" \
    EASYSPLAT_BOOTSTRAP_PYTHON="$bootstrap_python" \
    EASYSPLAT_BOOTSTRAP_RG="$bootstrap_rg" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$bootstrap_python" -I - \
      "$wrapper" "$implementation" "$supervisor" "$promoter" "$root" <<'PY'
import fcntl
import hashlib
import os
import secrets
import stat
import sys
import tempfile
from pathlib import Path


def read_bound(path: Path, label: str) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        named_before = os.lstat(path)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_uid != os.getuid()
            or before.st_gid != os.getgid()
            or stat.S_IMODE(before.st_mode) & 0o022
            or (before.st_dev, before.st_ino)
            != (named_before.st_dev, named_before.st_ino)
        ):
            raise SystemExit(f"unsafe native COLMAP {label}")
        chunks = []
        offset = 0
        while offset < before.st_size:
            block = os.pread(
                descriptor,
                min(1024 * 1024, before.st_size - offset),
                offset,
            )
            if not block:
                raise SystemExit(f"native COLMAP {label} was truncated")
            chunks.append(block)
            offset += len(block)
        if os.pread(descriptor, 1, before.st_size):
            raise SystemExit(f"native COLMAP {label} grew while read")
        after = os.fstat(descriptor)
        named_after = os.lstat(path)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_nlink",
            "st_mode",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(
            getattr(before, field) != getattr(after, field)
            or getattr(before, field) != getattr(named_after, field)
            for field in stable_fields
        ):
            raise SystemExit(f"native COLMAP {label} changed while read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def anonymous_copy(payload: bytes, label: str):
    temporary_directory = Path(
        tempfile.mkdtemp(prefix=f".easysplat-colmap-{label}.")
    )
    directory = os.open(
        temporary_directory,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
    )
    directory_metadata = os.fstat(directory)
    named_directory_metadata = os.lstat(temporary_directory)
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or directory_metadata.st_uid != os.getuid()
        or stat.S_IMODE(directory_metadata.st_mode) != 0o700
        or (directory_metadata.st_dev, directory_metadata.st_ino)
        != (named_directory_metadata.st_dev, named_directory_metadata.st_ino)
    ):
        os.close(directory)
        os.rmdir(temporary_directory)
        raise SystemExit("unsafe native COLMAP bootstrap directory")
    name = f".easysplat-colmap-{label}.{os.getpid()}.{secrets.token_hex(16)}"
    writer = -1
    reader = -1
    try:
        writer = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o400,
            dir_fd=directory,
        )
        offset = 0
        while offset < len(payload):
            offset += os.write(writer, payload[offset:])
        os.fsync(writer)
        os.fchmod(writer, 0o400)
        reader = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=directory,
        )
        if (os.fstat(writer).st_dev, os.fstat(writer).st_ino) != (
            os.fstat(reader).st_dev,
            os.fstat(reader).st_ino,
        ):
            raise SystemExit(f"anonymous native COLMAP {label} name changed")
        os.unlink(name, dir_fd=directory)
        os.fsync(directory)
        os.close(writer)
        writer = -1
        metadata = os.fstat(reader)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 0
            or metadata.st_size != len(payload)
            or stat.S_IMODE(metadata.st_mode) != 0o400
            or (fcntl.fcntl(reader, fcntl.F_GETFL) & os.O_ACCMODE)
            != os.O_RDONLY
        ):
            raise SystemExit(
                f"anonymous native COLMAP {label} has unsafe metadata"
            )
        os.set_inheritable(reader, True)
        result = reader
        reader = -1
        return result
    finally:
        if writer >= 0:
            os.close(writer)
        if reader >= 0:
            os.close(reader)
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)
        os.rmdir(temporary_directory)


wrapper = Path(sys.argv[1])
implementation = Path(sys.argv[2])
supervisor = Path(sys.argv[3])
promoter = Path(sys.argv[4])
root = Path(sys.argv[5])
if any(
    not path.is_absolute()
    for path in (wrapper, implementation, supervisor, promoter, root)
):
    raise SystemExit("native COLMAP bootstrap paths must be absolute")
wrapper_payload = read_bound(wrapper, "wrapper")
implementation_payload = read_bound(implementation, "implementation")
supervisor_payload = read_bound(supervisor, "supervisor")
promoter_payload = read_bound(promoter, "promoter")
wrapper_descriptor = anonymous_copy(wrapper_payload, "wrapper")
supervisor_descriptor = anonymous_copy(supervisor_payload, "supervisor")
environment = {
    "EASYSPLAT_BUILD_ROOT": str(root),
    "EASYSPLAT_BOOTSTRAP_CMAKE": os.environ["EASYSPLAT_BOOTSTRAP_CMAKE"],
    "EASYSPLAT_BOOTSTRAP_GIT": os.environ["EASYSPLAT_BOOTSTRAP_GIT"],
    "EASYSPLAT_BOOTSTRAP_NINJA": os.environ["EASYSPLAT_BOOTSTRAP_NINJA"],
    "EASYSPLAT_BOOTSTRAP_PYTHON": os.environ["EASYSPLAT_BOOTSTRAP_PYTHON"],
    "EASYSPLAT_BOOTSTRAP_RG": os.environ["EASYSPLAT_BOOTSTRAP_RG"],
    "EASYSPLAT_EXECUTED_WRAPPER_SHA256": hashlib.sha256(
        wrapper_payload
    ).hexdigest(),
    "EASYSPLAT_EXPECTED_IMPLEMENTATION_SHA256": hashlib.sha256(
        implementation_payload
    ).hexdigest(),
    "EASYSPLAT_EXPECTED_PROMOTER_SHA256": hashlib.sha256(
        promoter_payload
    ).hexdigest(),
    "EASYSPLAT_FROZEN_WRAPPER": "1",
    "EASYSPLAT_FROZEN_WRAPPER_FD": str(wrapper_descriptor),
    "EASYSPLAT_FROZEN_WRAPPER_SIZE": str(len(wrapper_payload)),
    "EASYSPLAT_FROZEN_SUPERVISOR_FD": str(supervisor_descriptor),
    "EASYSPLAT_FROZEN_SUPERVISOR_SHA256": hashlib.sha256(
        supervisor_payload
    ).hexdigest(),
    "EASYSPLAT_FROZEN_SUPERVISOR_SIZE": str(len(supervisor_payload)),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
}
os.execve(
    "/bin/bash",
    (
        "/bin/bash",
        "--noprofile",
        "--norc",
        f"/dev/fd/{wrapper_descriptor}",
    ),
    environment,
)
PY
fi

ROOT="${EASYSPLAT_BUILD_ROOT:-}"
EXECUTED_WRAPPER_SHA256="${EASYSPLAT_EXECUTED_WRAPPER_SHA256:-}"
FROZEN_WRAPPER_FD="${EASYSPLAT_FROZEN_WRAPPER_FD:-}"
FROZEN_WRAPPER_SIZE="${EASYSPLAT_FROZEN_WRAPPER_SIZE:-}"
EXPECTED_IMPLEMENTATION_SHA256="${EASYSPLAT_EXPECTED_IMPLEMENTATION_SHA256:-}"
EXPECTED_PROMOTER_SHA256="${EASYSPLAT_EXPECTED_PROMOTER_SHA256:-}"
FROZEN_SUPERVISOR_FD="${EASYSPLAT_FROZEN_SUPERVISOR_FD:-}"
FROZEN_SUPERVISOR_SHA256="${EASYSPLAT_FROZEN_SUPERVISOR_SHA256:-}"
FROZEN_SUPERVISOR_SIZE="${EASYSPLAT_FROZEN_SUPERVISOR_SIZE:-}"
[[ "$ROOT" = /* && -d "$ROOT" ]] || fail "bound source root is unavailable"
[[ "$FROZEN_WRAPPER_FD" =~ ^[0-9]+$ ]] || \
  fail "bound wrapper descriptor is unavailable"
[[ "$FROZEN_WRAPPER_SIZE" =~ ^[1-9][0-9]*$ ]] || \
  fail "bound wrapper size is unavailable"
[ "${BASH_SOURCE[0]}" = "/dev/fd/$FROZEN_WRAPPER_FD" ] || \
  fail "native COLMAP wrapper is not executing from its bound copy"
[[ "$EXECUTED_WRAPPER_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
  fail "bound wrapper digest is unavailable"
[[ "$EXPECTED_IMPLEMENTATION_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
  fail "bound implementation digest is unavailable"
[[ "$EXPECTED_PROMOTER_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
  fail "bound promoter digest is unavailable"
[[ "$FROZEN_SUPERVISOR_FD" =~ ^[0-9]+$ ]] || \
  fail "bound supervisor descriptor is unavailable"
[[ "$FROZEN_SUPERVISOR_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
  fail "bound supervisor digest is unavailable"
[[ "$FROZEN_SUPERVISOR_SIZE" =~ ^[1-9][0-9]*$ ]] || \
  fail "bound supervisor size is unavailable"

BOOTSTRAP_PYTHON_BIN="${EASYSPLAT_BOOTSTRAP_PYTHON:-}"
[[ "$BOOTSTRAP_PYTHON_BIN" = /* && -x "$BOOTSTRAP_PYTHON_BIN" ]] || \
  fail "the selected Xcode Python runtime is unavailable"
"$BOOTSTRAP_PYTHON_BIN" -I - \
  "$FROZEN_WRAPPER_FD" \
  "$EXECUTED_WRAPPER_SHA256" \
  "$FROZEN_WRAPPER_SIZE" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected_digest = sys.argv[2]
expected_size = int(sys.argv[3])
metadata = os.fstat(descriptor)
payload = b"".join(
    os.pread(descriptor, min(1024 * 1024, expected_size - offset), offset)
    for offset in range(0, expected_size, 1024 * 1024)
)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 0
    or metadata.st_uid != os.getuid()
    or stat.S_IMODE(metadata.st_mode) != 0o400
    or metadata.st_size != expected_size
    or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
    != os.O_RDONLY
    or len(payload) != expected_size
    or os.pread(descriptor, 1, expected_size)
    or hashlib.sha256(payload).hexdigest() != expected_digest
):
    raise SystemExit("anonymous native COLMAP wrapper content changed")
PY

SCRIPT_DIRECTORY="$ROOT/scripts/toolchain"
WRAPPER="$SCRIPT_DIRECTORY/build_colmap.sh"
IMPLEMENTATION="$SCRIPT_DIRECTORY/build_colmap_impl.sh"
BUILD_SUPERVISOR="$SCRIPT_DIRECTORY/secure_colmap_build.py"
PROMOTER="$SCRIPT_DIRECTORY/atomic_swap_install.py"
WORK="$ROOT/Toolchains/build/colmap"
BUILD_LOCK="$WORK/.build.lock"
COLMAP_PATCH="$SCRIPT_DIRECTORY/patches/colmap-4.1.1-easysplat.patch"
NATIVE_OVERLAY="$ROOT/Tools/NativeColmap"

BOOTSTRAP_CMAKE_BIN="${EASYSPLAT_BOOTSTRAP_CMAKE:-}"
BOOTSTRAP_GIT_BIN="${EASYSPLAT_BOOTSTRAP_GIT:-}"
BOOTSTRAP_NINJA_BIN="${EASYSPLAT_BOOTSTRAP_NINJA:-}"
BOOTSTRAP_RG_BIN="${EASYSPLAT_BOOTSTRAP_RG:-}"

for tool in \
  "$BOOTSTRAP_CMAKE_BIN" \
  "$BOOTSTRAP_GIT_BIN" \
  "$BOOTSTRAP_NINJA_BIN" \
  "$BOOTSTRAP_RG_BIN" \
  "$BOOTSTRAP_PYTHON_BIN"; do
  [[ "$tool" = /* && -x "$tool" ]] || \
    fail "cmake, git, ninja, rg, and the selected Xcode Python must be available"
done
for source in \
  "$WRAPPER" \
  "$IMPLEMENTATION" \
  "$BUILD_SUPERVISOR" \
  "$PROMOTER" \
  "$COLMAP_PATCH" \
  "$NATIVE_OVERLAY/local_vocab_retriever.h" \
  "$NATIVE_OVERLAY/local_vocab_retriever.cc"; do
  [[ -f "$source" && ! -L "$source" ]] || \
    fail "required native COLMAP build input is missing or unsafe: $source"
done

builtin exec /usr/bin/env -i \
  EASYSPLAT_BOOTSTRAP_CMAKE="$BOOTSTRAP_CMAKE_BIN" \
  EASYSPLAT_BOOTSTRAP_GIT="$BOOTSTRAP_GIT_BIN" \
  EASYSPLAT_BOOTSTRAP_NINJA="$BOOTSTRAP_NINJA_BIN" \
  EASYSPLAT_BOOTSTRAP_RG="$BOOTSTRAP_RG_BIN" \
  EASYSPLAT_EXECUTED_WRAPPER_SHA256="$EXECUTED_WRAPPER_SHA256" \
  EASYSPLAT_EXPECTED_IMPLEMENTATION_SHA256="$EXPECTED_IMPLEMENTATION_SHA256" \
  EASYSPLAT_EXPECTED_PROMOTER_SHA256="$EXPECTED_PROMOTER_SHA256" \
  EASYSPLAT_FROZEN_SUPERVISOR_FD="$FROZEN_SUPERVISOR_FD" \
  EASYSPLAT_FROZEN_SUPERVISOR_SHA256="$FROZEN_SUPERVISOR_SHA256" \
  EASYSPLAT_FROZEN_SUPERVISOR_SIZE="$FROZEN_SUPERVISOR_SIZE" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$BOOTSTRAP_PYTHON_BIN" -I - \
    "$BUILD_SUPERVISOR" \
    --work "$WORK" \
    --lock "$BUILD_LOCK" \
    --input "$COLMAP_PATCH" \
    --input "$NATIVE_OVERLAY/local_vocab_retriever.h" \
    --input "$NATIVE_OVERLAY/local_vocab_retriever.cc" \
    --control-input "$WRAPPER" \
    --control-input "$IMPLEMENTATION" \
    --control-input "$BUILD_SUPERVISOR" \
    --control-input "$PROMOTER" \
    -- \
    /usr/bin/env -i \
      EASYSPLAT_BOOTSTRAP_CMAKE="$BOOTSTRAP_CMAKE_BIN" \
      EASYSPLAT_BOOTSTRAP_GIT="$BOOTSTRAP_GIT_BIN" \
      EASYSPLAT_BOOTSTRAP_NINJA="$BOOTSTRAP_NINJA_BIN" \
      EASYSPLAT_BOOTSTRAP_RG="$BOOTSTRAP_RG_BIN" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      /bin/bash --noprofile --norc "$IMPLEMENTATION" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys
from pathlib import Path

supervisor = Path(sys.argv[1])
descriptor = int(os.environ["EASYSPLAT_FROZEN_SUPERVISOR_FD"])
expected_digest = os.environ["EASYSPLAT_FROZEN_SUPERVISOR_SHA256"]
expected_size = int(os.environ["EASYSPLAT_FROZEN_SUPERVISOR_SIZE"])
metadata = os.fstat(descriptor)
if (
    not stat.S_ISREG(metadata.st_mode)
    or metadata.st_nlink != 0
    or metadata.st_uid != os.getuid()
    or metadata.st_size != expected_size
    or stat.S_IMODE(metadata.st_mode) != 0o400
    or (fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE)
    != os.O_RDONLY
):
    raise SystemExit("anonymous native COLMAP supervisor has unsafe metadata")
payload = b"".join(
    os.pread(descriptor, min(1024 * 1024, expected_size - offset), offset)
    for offset in range(0, expected_size, 1024 * 1024)
)
if (
    len(payload) != expected_size
    or os.pread(descriptor, 1, expected_size)
    or hashlib.sha256(payload).hexdigest() != expected_digest
):
    raise SystemExit("anonymous native COLMAP supervisor content changed")
os.environ["EASYSPLAT_EXECUTED_SUPERVISOR_SHA256"] = expected_digest
sys.argv = [str(supervisor), *sys.argv[2:]]
namespace = {
    "__name__": "__main__",
    "__file__": str(supervisor),
}
exec(compile(payload, str(supervisor), "exec"), namespace, namespace)
PY
