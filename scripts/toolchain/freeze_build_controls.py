#!/usr/bin/python3
"""Freeze dependency-builder control files before any build work begins."""

# EASYSPLAT_CONTROL_FREEZER_BEGIN
from __future__ import annotations

import fcntl
import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Callable, Optional, Tuple


class ControlFreezeError(RuntimeError):
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
_MINIMUM_CONTROL_FD = 100


def _same_metadata(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in _STABLE_FIELDS)


def _read_all(descriptor: int, size: int) -> bytes:
    payload = bytearray()
    offset = 0
    while offset < size:
        block = os.pread(descriptor, min(1024 * 1024, size - offset), offset)
        if not block:
            raise ControlFreezeError("control input was truncated while read")
        payload.extend(block)
        offset += len(block)
    return bytes(payload)


def freeze_control_file(
    path: Path,
    executable: Optional[bool] = None,
    *,
    after_open: Optional[Callable[[], None]] = None,
) -> Tuple[int, str]:
    path = Path(path)
    if not path.is_absolute() or not path.name or path.name in {".", ".."}:
        raise ControlFreezeError(f"unsafe control input path: {path}")
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
        executable_bits = stat.S_IMODE(before.st_mode) & 0o111
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
            or source_mode & 0o022
            or (before.st_dev, before.st_ino)
            != (named_before.st_dev, named_before.st_ino)
            or (fcntl.fcntl(source, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDONLY
            or (executable is True and not executable_bits)
            or (executable is False and executable_bits)
        ):
            raise ControlFreezeError(f"unsafe control input: {path}")
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
            raise ControlFreezeError(f"control input changed while read: {path}")

        staged, staged_path = tempfile.mkstemp(prefix=".easysplat-control-")
        os.fchown(staged, os.getuid(), os.getgid())
        staged_before = os.fstat(staged)
        staged_identity = (staged_before.st_dev, staged_before.st_ino)
        offset = 0
        while offset < len(payload):
            offset += os.write(staged, payload[offset:])
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
            raise ControlFreezeError("anonymous control stage changed before unlink")
        os.unlink(staged_path)
        staged_path = ""
        anonymous = os.fstat(frozen)
        if (
            (anonymous.st_dev, anonymous.st_ino) != staged_identity
            or anonymous.st_nlink != 0
            or stat.S_IMODE(anonymous.st_mode) != 0o400
            or _read_all(frozen, anonymous.st_size) != payload
        ):
            raise ControlFreezeError("anonymous control descriptor is not stable")
        relocated = fcntl.fcntl(frozen, fcntl.F_DUPFD_CLOEXEC, _MINIMUM_CONTROL_FD)
        os.close(frozen)
        frozen = relocated
        relocated_metadata = os.fstat(frozen)
        if (
            relocated_metadata.st_nlink != 0
            or stat.S_IMODE(relocated_metadata.st_mode) != 0o400
            or (fcntl.fcntl(frozen, fcntl.F_GETFL) & os.O_ACCMODE) != os.O_RDONLY
        ):
            raise ControlFreezeError("relocated control descriptor is not stable")
        os.set_inheritable(frozen, True)
        result = frozen
        frozen = -1
        return result, hashlib.sha256(payload).hexdigest()
    except ControlFreezeError:
        raise
    except (OSError, ValueError) as error:
        raise ControlFreezeError(f"could not freeze control input {path}: {error}") from error
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
# EASYSPLAT_CONTROL_FREEZER_END


def validate_frozen_descriptor(descriptor: int, expected_sha256: str, label: str) -> None:
    if descriptor < _MINIMUM_CONTROL_FD:
        raise ControlFreezeError(f"unsafe frozen {label} descriptor number")
    if len(expected_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in expected_sha256
    ):
        raise ControlFreezeError(f"invalid frozen {label} digest")
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
        raise ControlFreezeError(f"unsafe frozen {label} descriptor")
    payload = _read_all(descriptor, metadata.st_size)
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise ControlFreezeError(f"frozen {label} payload digest mismatch")


def main() -> None:
    if len(sys.argv) < 9:
        raise ControlFreezeError("incomplete dependency-builder bootstrap arguments")
    (
        freezer_fd_raw,
        freezer_sha256,
        wrapper_raw,
        implementation_raw,
        promoter_raw,
        script_directory_raw,
        build_label,
        implementation_mode,
        *arguments,
    ) = sys.argv[1:]
    freezer_fd = int(freezer_fd_raw)
    script_directory = Path(script_directory_raw)
    wrapper_path = Path(wrapper_raw)
    implementation_path = Path(implementation_raw)
    promoter_path = Path(promoter_raw)
    if (
        build_label not in {"COLMAP support", "Ceres", "OpenImageIO"}
        or implementation_mode not in {"regular", "non-executable"}
        or not script_directory.is_absolute()
        or wrapper_path.parent != script_directory
        or implementation_path.parent != script_directory
        or promoter_path.parent != script_directory
    ):
        raise ControlFreezeError("unsafe dependency-builder bootstrap arguments")

    descriptors = [freezer_fd]
    try:
        validate_frozen_descriptor(freezer_fd, freezer_sha256, "control freezer")
        os.set_inheritable(freezer_fd, True)
        wrapper_fd, wrapper_sha256 = freeze_control_file(wrapper_path, True)
        descriptors.append(wrapper_fd)
        implementation_fd, implementation_sha256 = freeze_control_file(
            implementation_path,
            False if implementation_mode == "non-executable" else None,
        )
        descriptors.append(implementation_fd)
        promoter_fd, promoter_sha256 = freeze_control_file(promoter_path, True)
        descriptors.append(promoter_fd)
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
            "EASYSPLAT_FROZEN_SCRIPT_DIRECTORY": str(script_directory),
            "EASYSPLAT_FROZEN_FREEZER_FD": str(freezer_fd),
            "EASYSPLAT_FROZEN_FREEZER_SHA256": freezer_sha256,
            "EASYSPLAT_FROZEN_WRAPPER_FD": str(wrapper_fd),
            "EASYSPLAT_FROZEN_WRAPPER_SHA256": wrapper_sha256,
            "EASYSPLAT_FROZEN_IMPLEMENTATION_FD": str(implementation_fd),
            "EASYSPLAT_FROZEN_IMPLEMENTATION_SHA256": implementation_sha256,
            "EASYSPLAT_FROZEN_PROMOTER_FD": str(promoter_fd),
            "EASYSPLAT_FROZEN_PROMOTER_SHA256": promoter_sha256,
        }
        os.execve(
            "/bin/bash",
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                f"/dev/fd/{wrapper_fd}",
                *arguments,
            ],
            environment,
        )
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


if __name__ == "__main__":
    try:
        main()
    except (ControlFreezeError, OSError, ValueError) as error:
        label = sys.argv[7] if len(sys.argv) > 7 else "Dependency"
        print(f"{label} build failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
