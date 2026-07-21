#!/bin/bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_SOURCE" != /dev/fd/* ]]; then
  SCRIPT_DIRECTORY="$(builtin cd "$(/usr/bin/dirname "$SCRIPT_SOURCE")" && builtin pwd -P)"
  CONTROL_FREEZER="$SCRIPT_DIRECTORY/freeze_build_controls.py"
  WRAPPER="$SCRIPT_DIRECTORY/build_openimageio.sh"
  IMPLEMENTATION="$SCRIPT_DIRECTORY/build_openimageio_impl.sh"
  PROMOTER="$SCRIPT_DIRECTORY/atomic_swap_install.py"
  CALLER_PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
  builtin exec /usr/bin/env -i PATH="$CALLER_PATH" \
    /usr/bin/python3 -I -S - \
    "$CONTROL_FREEZER" "$WRAPPER" "$IMPLEMENTATION" "$PROMOTER" \
    "$SCRIPT_DIRECTORY" "OpenImageIO" "non-executable" 99 "$@" 99<&0 <<'PY'
# EASYSPLAT_FREEZER_BOOTSTRAP_BEGIN
from __future__ import annotations

import fcntl
import hashlib
import os
import stat
import tempfile
from pathlib import Path
from typing import Callable, Optional, Tuple


class FreezerBootstrapError(RuntimeError):
    pass


_STABLE_FIELDS = (
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


def _same_metadata(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in _STABLE_FIELDS)


def _read_all(descriptor: int, size: int) -> bytes:
    payload = bytearray()
    offset = 0
    while offset < size:
        block = os.pread(descriptor, min(1024 * 1024, size - offset), offset)
        if not block:
            raise FreezerBootstrapError("control freezer was truncated while read")
        payload.extend(block)
        offset += len(block)
    return bytes(payload)


def freeze_freezer_file(
    path: Path,
    *,
    after_open: Optional[Callable[[], None]] = None,
) -> Tuple[int, str]:
    path = Path(path)
    if not path.is_absolute() or not path.name or path.name in {".", ".."}:
        raise FreezerBootstrapError(f"unsafe control freezer path: {path}")
    parent = -1
    source = -1
    staged = -1
    frozen = -1
    staged_path = ""
    staged_identity: Optional[Tuple[int, int]] = None
    try:
        parent = os.open(
            path.parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        parent_before = os.fstat(parent)
        parent_named = os.stat(path.parent, follow_symlinks=False)
        source = os.open(
            path.name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=parent,
        )
        before = os.fstat(source)
        named_before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        source_mode = stat.S_IMODE(before.st_mode)
        if (
            not stat.S_ISDIR(parent_before.st_mode)
            or parent_before.st_uid != os.getuid()
            or parent_before.st_gid != os.getgid()
            or (parent_before.st_dev, parent_before.st_ino)
            != (parent_named.st_dev, parent_named.st_ino)
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_gid != os.getgid()
            or before.st_size <= 0
            or source_mode & 0o133
            or (before.st_dev, before.st_ino)
            != (named_before.st_dev, named_before.st_ino)
            or (fcntl.fcntl(source, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDONLY
        ):
            raise FreezerBootstrapError(f"unsafe control freezer: {path}")
        if after_open is not None:
            after_open()
        payload = _read_all(source, before.st_size)
        after = os.fstat(source)
        named_after = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        parent_after = os.fstat(parent)
        parent_named_after = os.stat(path.parent, follow_symlinks=False)
        if (
            not _same_metadata(before, after)
            or not _same_metadata(before, named_after)
            or not _same_metadata(parent_before, parent_after)
            or (parent_before.st_dev, parent_before.st_ino)
            != (parent_named_after.st_dev, parent_named_after.st_ino)
        ):
            raise FreezerBootstrapError(f"control freezer changed while read: {path}")

        staged, staged_path = tempfile.mkstemp(prefix=".easysplat-freezer-")
        os.fchown(staged, os.getuid(), os.getgid())
        staged_before = os.fstat(staged)
        staged_identity = (staged_before.st_dev, staged_before.st_ino)
        offset = 0
        while offset < len(payload):
            written = os.write(staged, payload[offset:])
            if written <= 0:
                raise FreezerBootstrapError("could not stage control freezer")
            offset += written
        os.fsync(staged)
        os.fchmod(staged, 0o400)
        os.close(staged)
        staged = -1
        frozen = os.open(staged_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        frozen_before = os.fstat(frozen)
        staged_named = os.lstat(staged_path)
        if (
            (frozen_before.st_dev, frozen_before.st_ino) != staged_identity
            or (staged_named.st_dev, staged_named.st_ino) != staged_identity
            or not stat.S_ISREG(frozen_before.st_mode)
            or frozen_before.st_nlink != 1
            or frozen_before.st_uid != os.getuid()
            or frozen_before.st_gid != os.getgid()
            or frozen_before.st_size != len(payload)
            or stat.S_IMODE(frozen_before.st_mode) != 0o400
            or (fcntl.fcntl(frozen, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDONLY
        ):
            raise FreezerBootstrapError("anonymous freezer stage changed before unlink")
        os.unlink(staged_path)
        staged_path = ""
        anonymous = os.fstat(frozen)
        if (
            (anonymous.st_dev, anonymous.st_ino) != staged_identity
            or anonymous.st_nlink != 0
            or stat.S_IMODE(anonymous.st_mode) != 0o400
            or _read_all(frozen, anonymous.st_size) != payload
        ):
            raise FreezerBootstrapError("anonymous freezer descriptor is not stable")
        relocated = fcntl.fcntl(frozen, fcntl.F_DUPFD_CLOEXEC, 100)
        os.close(frozen)
        frozen = relocated
        os.set_inheritable(frozen, True)
        result = frozen
        frozen = -1
        return result, hashlib.sha256(payload).hexdigest()
    except FreezerBootstrapError:
        raise
    except (OSError, ValueError) as error:
        raise FreezerBootstrapError(f"could not freeze control freezer {path}: {error}") from error
    finally:
        for descriptor in (source, parent, staged, frozen):
            if descriptor >= 0:
                os.close(descriptor)
        if staged_path and staged_identity is not None:
            try:
                current = os.lstat(staged_path)
            except FileNotFoundError:
                pass
            else:
                if (current.st_dev, current.st_ino) == staged_identity:
                    os.unlink(staged_path)
# EASYSPLAT_FREEZER_BOOTSTRAP_END

import sys

(
    freezer_raw,
    wrapper_raw,
    implementation_raw,
    promoter_raw,
    script_directory,
    build_label,
    implementation_mode,
    stdin_fd_raw,
    *arguments,
) = sys.argv[1:]
frozen = -1
try:
    frozen, freezer_sha256 = freeze_freezer_file(Path(freezer_raw))
    stdin_fd = int(stdin_fd_raw)
    os.dup2(stdin_fd, 0)
    os.close(stdin_fd)
    metadata = os.fstat(frozen)
    payload = _read_all(frozen, metadata.st_size)
    if hashlib.sha256(payload).hexdigest() != freezer_sha256:
        raise FreezerBootstrapError("frozen control freezer digest mismatch")
    script = f"/dev/fd/{frozen}"
    sys.argv = [
        script,
        str(frozen),
        freezer_sha256,
        wrapper_raw,
        implementation_raw,
        promoter_raw,
        script_directory,
        build_label,
        implementation_mode,
        *arguments,
    ]
    namespace = {
        "__name__": "__main__",
        "__file__": script,
        "__package__": None,
        "__cached__": None,
    }
    exec(compile(payload, script, "exec"), namespace)
except (FreezerBootstrapError, OSError, ValueError) as error:
    print(f"{build_label} build failed: {error}", file=sys.stderr)
    raise SystemExit(1) from error
finally:
    if frozen >= 0:
        os.close(frozen)
PY
fi

FROZEN_FREEZER_FD="${EASYSPLAT_FROZEN_FREEZER_FD:-}"
FROZEN_FREEZER_SHA256="${EASYSPLAT_FROZEN_FREEZER_SHA256:-}"
FROZEN_WRAPPER_FD="${EASYSPLAT_FROZEN_WRAPPER_FD:-}"
FROZEN_WRAPPER_SHA256="${EASYSPLAT_FROZEN_WRAPPER_SHA256:-}"
FROZEN_IMPLEMENTATION_FD="${EASYSPLAT_FROZEN_IMPLEMENTATION_FD:-}"
FROZEN_IMPLEMENTATION_SHA256="${EASYSPLAT_FROZEN_IMPLEMENTATION_SHA256:-}"
FROZEN_PROMOTER_FD="${EASYSPLAT_FROZEN_PROMOTER_FD:-}"
FROZEN_PROMOTER_SHA256="${EASYSPLAT_FROZEN_PROMOTER_SHA256:-}"
SCRIPT_DIRECTORY="${EASYSPLAT_FROZEN_SCRIPT_DIRECTORY:-}"
if [[ "$SCRIPT_SOURCE" != "/dev/fd/$FROZEN_WRAPPER_FD" || "$SCRIPT_DIRECTORY" != /* ]]; then
  builtin printf '%s\n' "OpenImageIO build failed: frozen wrapper identity is invalid" >&2
  exit 1
fi

BOOTSTRAP_CMAKE_BIN="$(builtin type -P cmake || true)"
BOOTSTRAP_NINJA_BIN="$(builtin type -P ninja || true)"
BOOTSTRAP_RG_BIN="$(builtin type -P rg || true)"
for tool in "$BOOTSTRAP_CMAKE_BIN" "$BOOTSTRAP_NINJA_BIN" "$BOOTSTRAP_RG_BIN"; do
  if [[ "$tool" != /* || ! -x "$tool" ]]; then
    builtin printf '%s\n' \
      "OpenImageIO build failed: cmake, ninja, and rg must resolve to external executables" >&2
    exit 1
  fi
done

ROOT="$(builtin cd "$SCRIPT_DIRECTORY/../.." && builtin pwd -P)"
builtin exec /usr/bin/env -i \
  EASYSPLAT_BOOTSTRAP_CMAKE="$BOOTSTRAP_CMAKE_BIN" \
  EASYSPLAT_BOOTSTRAP_NINJA="$BOOTSTRAP_NINJA_BIN" \
  EASYSPLAT_BOOTSTRAP_RG="$BOOTSTRAP_RG_BIN" \
  EASYSPLAT_FROZEN_ROOT="$ROOT" \
  EASYSPLAT_FROZEN_FREEZER_FD="$FROZEN_FREEZER_FD" \
  EASYSPLAT_FROZEN_FREEZER_SHA256="$FROZEN_FREEZER_SHA256" \
  EASYSPLAT_FROZEN_WRAPPER_FD="$FROZEN_WRAPPER_FD" \
  EASYSPLAT_FROZEN_WRAPPER_SHA256="$FROZEN_WRAPPER_SHA256" \
  EASYSPLAT_FROZEN_IMPLEMENTATION_FD="$FROZEN_IMPLEMENTATION_FD" \
  EASYSPLAT_FROZEN_IMPLEMENTATION_SHA256="$FROZEN_IMPLEMENTATION_SHA256" \
  EASYSPLAT_FROZEN_PROMOTER_FD="$FROZEN_PROMOTER_FD" \
  EASYSPLAT_FROZEN_PROMOTER_SHA256="$FROZEN_PROMOTER_SHA256" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /bin/bash --noprofile --norc "/dev/fd/$FROZEN_IMPLEMENTATION_FD" "$@"
