#!/usr/bin/env python3
"""Secure lock, input snapshot, and process supervision for COLMAP builds."""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import os
import secrets
import select
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path


class SecurityError(RuntimeError):
    """A filesystem identity or immutable-input contract was violated."""


class BuildLockedError(SecurityError):
    """Another supervised native COLMAP build owns the lock."""


@dataclass(frozen=True)
class FrozenInput:
    fd: int
    sha256: str
    size: int


@dataclass
class BoundBuildLock:
    file_fd: int
    directory_fd: int
    anchor_fd: int

    def close(self) -> None:
        for descriptor in (self.file_fd, self.directory_fd, self.anchor_fd):
            if descriptor >= 0:
                os.close(descriptor)
        self.file_fd = -1
        self.directory_fd = -1
        self.anchor_fd = -1


CONTROL_SOURCE_NAMES = (
    "build_colmap.sh",
    "build_colmap_impl.sh",
    "secure_colmap_build.py",
    "atomic_swap_install.py",
)


def _same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _secure_parent(path: Path) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SecurityError(f"unsafe parent directory: {path}: {error}") from error
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
    ):
        os.close(descriptor)
        raise SecurityError(f"unsafe parent directory: {path}")
    return descriptor


def acquire_bound_lock(
    path: Path,
    *,
    after_open: Callable[[], None] | None = None,
) -> BoundBuildLock:
    """Open and lock a reusable non-link file without truncating its contents."""

    path = Path(path)
    if not path.is_absolute() or path.parent == path.parent.parent:
        raise SecurityError(f"unsafe native COLMAP build lock path: {path}")
    anchor = _secure_parent(path.parent.parent)
    parent = -1
    descriptor = -1
    try:
        try:
            fcntl.flock(anchor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise BuildLockedError(
                    "another native COLMAP build is running"
                ) from error
            raise SecurityError(
                f"could not lock native COLMAP build anchor: {path.parent.parent}"
            ) from error
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
        try:
            try:
                parent = os.open(
                    path.parent.name,
                    directory_flags,
                    dir_fd=anchor,
                )
            except FileNotFoundError:
                os.mkdir(path.parent.name, 0o700, dir_fd=anchor)
                parent = os.open(
                    path.parent.name,
                    directory_flags,
                    dir_fd=anchor,
                )
            named_parent = os.stat(
                path.parent.name, dir_fd=anchor, follow_symlinks=False
            )
        except OSError as error:
            raise SecurityError(
                f"unsafe native COLMAP build directory: {path.parent}"
            ) from error
        parent_metadata = os.fstat(parent)
        if (
            not stat.S_ISDIR(parent_metadata.st_mode)
            or parent_metadata.st_uid != os.getuid()
            or parent_metadata.st_gid != os.getgid()
            or not _same_identity(parent_metadata, named_parent)
        ):
            raise SecurityError(f"unsafe native COLMAP build directory: {path.parent}")
        try:
            fcntl.flock(parent, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise BuildLockedError(
                    "another native COLMAP build is running"
                ) from error
            raise SecurityError(
                f"could not lock native COLMAP build directory: {path.parent}"
            ) from error
        flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW
        try:
            descriptor = os.open(path.name, flags, 0o600, dir_fd=parent)
        except OSError as error:
            raise SecurityError(f"unsafe native COLMAP build lock: {path}") from error
        if after_open is not None:
            after_open()
        opened = os.fstat(descriptor)
        try:
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise SecurityError(
                f"native COLMAP build lock name changed: {path}"
            ) from error
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_uid != os.getuid()
            or opened.st_gid != os.getgid()
            or not _same_identity(opened, named)
        ):
            raise SecurityError(f"unsafe native COLMAP build lock: {path}")
        os.fchmod(descriptor, 0o600)
        try:
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise BuildLockedError(
                    "another native COLMAP build is running"
                ) from error
            raise SecurityError(
                f"could not lock native COLMAP build: {path}"
            ) from error
        opened_after = os.fstat(descriptor)
        try:
            named_after = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise SecurityError(
                f"native COLMAP build lock name changed: {path}"
            ) from error
        if (
            not _same_identity(opened, opened_after)
            or not _same_identity(opened, named_after)
            or opened_after.st_nlink != 1
            or stat.S_IMODE(opened_after.st_mode) != 0o600
        ):
            raise SecurityError(f"native COLMAP build lock changed: {path}")
        lock = BoundBuildLock(
            file_fd=descriptor,
            directory_fd=parent,
            anchor_fd=anchor,
        )
        descriptor = -1
        parent = -1
        anchor = -1
        return lock
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        if parent >= 0:
            os.close(parent)
        if anchor >= 0:
            os.close(anchor)


def _read_bound_source(
    path: Path,
    index: int,
    after_source_open: Callable[[Path, int], None] | None,
) -> bytes:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as error:
        raise SecurityError(f"unsafe native build input: {path}") from error
    try:
        before = os.fstat(descriptor)
        if after_source_open is not None:
            after_source_open(path, index)
        try:
            named_before = os.lstat(path)
        except OSError as error:
            raise SecurityError(f"native build input name changed: {path}") from error
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_uid != os.getuid()
            or before.st_gid != os.getgid()
            or stat.S_IMODE(before.st_mode) & 0o022
            or not _same_identity(before, named_before)
        ):
            raise SecurityError(f"unsafe native build input: {path}")
        chunks: list[bytes] = []
        offset = 0
        while offset < before.st_size:
            block = os.pread(
                descriptor, min(1024 * 1024, before.st_size - offset), offset
            )
            if not block:
                raise SecurityError(f"short native build input read: {path}")
            chunks.append(block)
            offset += len(block)
        if os.pread(descriptor, 1, before.st_size):
            raise SecurityError(f"native build input grew while read: {path}")
        after = os.fstat(descriptor)
        try:
            named_after = os.lstat(path)
        except OSError as error:
            raise SecurityError(f"native build input name changed: {path}") from error
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
            raise SecurityError(f"native build input changed while read: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _anonymous_copy(payload: bytes, directory: int) -> int:
    name = f".frozen.{os.getpid()}.{secrets.token_hex(16)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
    writer = os.open(name, flags, 0o400, dir_fd=directory)
    reader = -1
    try:
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
        written = os.fstat(writer)
        opened = os.fstat(reader)
        if not _same_identity(written, opened):
            raise SecurityError("anonymous native build input name changed")
        os.unlink(name, dir_fd=directory)
        os.fsync(directory)
        os.close(writer)
        writer = -1
        metadata = os.fstat(reader)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 0
            or metadata.st_size != len(payload)
        ):
            raise SecurityError("anonymous native build input has unsafe metadata")
        return reader
    except Exception:
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass
        if writer >= 0:
            os.close(writer)
        if reader >= 0:
            os.close(reader)
        raise


def freeze_inputs(
    sources: Sequence[Path],
    stage: Path | int,
    *,
    after_source_open: Callable[[Path, int], None] | None = None,
) -> tuple[FrozenInput, ...]:
    """Copy exact, identity-bound source generations into anonymous files."""

    if isinstance(stage, int):
        directory = os.dup(stage)
        metadata = os.fstat(directory)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_gid != os.getgid()
        ):
            os.close(directory)
            raise SecurityError("unsafe native COLMAP run stage descriptor")
    else:
        directory = _secure_parent(Path(stage))
    frozen: list[FrozenInput] = []
    try:
        for index, source in enumerate(sources):
            payload = _read_bound_source(Path(source), index, after_source_open)
            descriptor = _anonymous_copy(payload, directory)
            frozen.append(
                FrozenInput(
                    fd=descriptor,
                    sha256=hashlib.sha256(payload).hexdigest(),
                    size=len(payload),
                )
            )
        return tuple(frozen)
    except Exception:
        close_frozen_inputs(frozen)
        raise
    finally:
        os.close(directory)


def read_frozen(item: FrozenInput) -> bytes:
    metadata = os.fstat(item.fd)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 0
        or metadata.st_size != item.size
    ):
        raise SecurityError("anonymous native build input changed")
    chunks: list[bytes] = []
    offset = 0
    while offset < item.size:
        block = os.pread(item.fd, min(1024 * 1024, item.size - offset), offset)
        if not block:
            raise SecurityError("anonymous native build input was truncated")
        chunks.append(block)
        offset += len(block)
    if os.pread(item.fd, 1, item.size):
        raise SecurityError("anonymous native build input grew")
    return b"".join(chunks)


def verify_frozen(item: FrozenInput, expected_sha256: str) -> None:
    if len(expected_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in expected_sha256
    ):
        raise SecurityError("invalid frozen native build input digest")
    actual = hashlib.sha256(read_frozen(item)).hexdigest()
    if actual != expected_sha256 or actual != item.sha256:
        raise SecurityError("frozen native build input digest mismatch")


def close_frozen_inputs(inputs: Sequence[FrozenInput]) -> None:
    for item in inputs:
        try:
            os.close(item.fd)
        except OSError:
            pass


def _create_run_stage(
    work: Path, directory: int
) -> tuple[Path, int, int, int, select.kqueue]:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    for _ in range(128):
        name = f"input.stage.{os.getpid()}.{secrets.token_hex(12)}"
        try:
            os.mkdir(name, 0o700, dir_fd=directory)
        except FileExistsError:
            continue
        descriptor = -1
        try:
            descriptor = os.open(name, flags, dir_fd=directory)
            metadata = os.fstat(descriptor)
            named = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_gid != os.getgid()
                or stat.S_IMODE(metadata.st_mode) != 0o700
                or not _same_identity(metadata, named)
            ):
                raise SecurityError("unsafe native COLMAP run stage")
            monitor = select.kqueue()
            monitor.control(
                [
                    select.kevent(
                        descriptor,
                        filter=select.KQ_FILTER_VNODE,
                        flags=(
                            select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR
                        ),
                        fflags=(
                            select.KQ_NOTE_DELETE
                            | select.KQ_NOTE_RENAME
                            | select.KQ_NOTE_REVOKE
                        ),
                    )
                ],
                0,
                0,
            )
            return (
                work / name,
                descriptor,
                metadata.st_dev,
                metadata.st_ino,
                monitor,
            )
        except Exception:
            if descriptor >= 0:
                os.close(descriptor)
            raise
    raise SecurityError("could not allocate a unique native COLMAP run stage")


def _assert_run_stage_stable(
    path: Path,
    descriptor: int,
    expected_device: int,
    expected_inode: int,
    monitor: select.kqueue,
) -> None:
    if monitor.control(None, 1, 0):
        raise SecurityError("native COLMAP run stage name changed")
    opened = os.fstat(descriptor)
    try:
        named = os.lstat(path)
    except OSError as error:
        raise SecurityError("native COLMAP run stage name changed") from error
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_uid != os.getuid()
        or opened.st_gid != os.getgid()
        or stat.S_IMODE(opened.st_mode) != 0o700
        or (opened.st_dev, opened.st_ino) != (expected_device, expected_inode)
        or not _same_identity(opened, named)
    ):
        raise SecurityError("native COLMAP run stage name changed")


def _remove_owned_run_stage(
    path: Path,
    descriptor: int,
    expected_device: int,
    expected_inode: int,
    remover: FrozenInput | None = None,
) -> None:
    """Remove the unchanged supervisor-owned stage with the hardened tree remover."""

    if remover is None:
        remover_source = Path(__file__).with_name("atomic_swap_install.py")
        remover_payload = _read_bound_source(remover_source, 3, None)
        remover_descriptor = _anonymous_copy(remover_payload, descriptor)
        remover_digest = hashlib.sha256(remover_payload).hexdigest()
    else:
        verify_frozen(remover, remover.sha256)
        remover_payload = read_frozen(remover)
        remover_descriptor = os.dup(remover.fd)
        remover_digest = remover.sha256
    frozen_script_runner = "\n".join(
        (
            "import hashlib, os, sys",
            "descriptor = int(sys.argv[1])",
            "size = int(sys.argv[2])",
            "expected_digest = sys.argv[3]",
            "payload = b''.join(",
            "    os.pread(descriptor, min(1024 * 1024, size - offset), offset)",
            "    for offset in range(0, size, 1024 * 1024)",
            ")",
            "if len(payload) != size or os.pread(descriptor, 1, size):",
            "    raise SystemExit('frozen owned-tree remover size changed')",
            "if hashlib.sha256(payload).hexdigest() != expected_digest:",
            "    raise SystemExit('frozen owned-tree remover digest changed')",
            "sys.argv = ['atomic_swap_install.py', *sys.argv[4:]]",
            "namespace = {",
            "    '__name__': '__main__',",
            "    '__file__': '<frozen atomic_swap_install.py>',",
            "}",
            "exec(compile(payload, namespace['__file__'], 'exec'), namespace, namespace)",
        )
    )
    try:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                frozen_script_runner,
                str(remover_descriptor),
                str(len(remover_payload)),
                remover_digest,
                "--remove-owned-tree",
                str(path),
                str(expected_device),
                str(expected_inode),
                "--allow-symlinks",
            ],
            check=False,
            close_fds=True,
            pass_fds=(remover_descriptor,),
            capture_output=True,
        )
    finally:
        os.close(remover_descriptor)
    if result.returncode != 0:
        raise SecurityError("could not remove the bound native COLMAP run stage")
    try:
        os.lstat(path)
    except FileNotFoundError:
        pass
    else:
        raise SecurityError("native COLMAP run stage survived owned cleanup")
    opened = os.fstat(descriptor)
    if not stat.S_ISDIR(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
        expected_device,
        expected_inode,
    ):
        raise SecurityError("native COLMAP run stage changed during owned cleanup")


def _overlay_digest(payloads: Sequence[bytes]) -> str:
    if len(payloads) != 3:
        raise SecurityError("native build input count differs")
    # The public receipt's historical order is header, source, patch.
    names_and_payloads = (
        ("local_vocab_retriever.h", payloads[1]),
        ("local_vocab_retriever.cc", payloads[2]),
        ("colmap-4.1.1-easysplat.patch", payloads[0]),
    )
    digest = hashlib.sha256()
    for name, payload in names_and_payloads:
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(payload)
        digest.update(b"\0")
    return digest.hexdigest()


def _validated_control_sources(sources: Sequence[Path]) -> tuple[Path, ...]:
    controls = tuple(Path(source) for source in sources)
    if not controls:
        return ()
    if len(controls) != len(CONTROL_SOURCE_NAMES):
        raise SecurityError("exactly four native build control inputs are required")
    if tuple(path.name for path in controls) != CONTROL_SOURCE_NAMES:
        raise SecurityError("native build control input order differs")
    if any(not path.is_absolute() for path in controls):
        raise SecurityError("native build control inputs must be absolute")
    if len({str(path) for path in controls}) != len(controls):
        raise SecurityError("native build control inputs must be unique")
    if len({path.parent for path in controls}) != 1:
        raise SecurityError("native build control inputs must share one directory")
    return controls


def _group_exists(group: int) -> bool:
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Every supervised descendant retains this user's credentials. On
        # macOS, a fully exited group can briefly report EPERM while its
        # numeric ID is being retired or reused; it is not ours to signal.
        return False
    return True


def _signal_group(group: int, signum: int) -> bool:
    try:
        os.killpg(group, signum)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def _quiesce_group(
    group: int,
    grace: float,
    first_signal: int = signal.SIGTERM,
    leader: subprocess.Popen[bytes] | None = None,
) -> None:
    if leader is None or leader.pid != group or leader.returncode is not None:
        raise SecurityError("native COLMAP process-group identity was lost")
    if not _group_exists(group):
        return
    if not _signal_group(group, first_signal):
        return
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if not _group_exists(group):
            return
        time.sleep(0.02)
    if not _group_exists(group):
        return
    if not _signal_group(group, signal.SIGKILL):
        return
    deadline = time.monotonic() + max(grace, 1.0)
    while time.monotonic() < deadline:
        if not _group_exists(group):
            return
        time.sleep(0.02)
    if _group_exists(group):
        raise SecurityError("native COLMAP descendant process group did not exit")


def supervise(
    *,
    work: Path,
    lock_path: Path,
    sources: Sequence[Path],
    control_sources: Sequence[Path] = (),
    expected_control_sha256: Sequence[str] = (),
    command: Sequence[str],
    termination_grace: float,
) -> int:
    if len(sources) != 3:
        raise SecurityError("exactly three native build inputs are required")
    controls = _validated_control_sources(control_sources)
    expected_controls = tuple(expected_control_sha256)
    if controls and len(expected_controls) != len(controls):
        raise SecurityError("native build control digest count differs")
    if controls and any(
        len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
        for digest in expected_controls
    ):
        raise SecurityError("native build control digest is invalid")
    if not command or not Path(command[0]).is_absolute():
        raise SecurityError("supervised native COLMAP command must be absolute")
    work.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = acquire_bound_lock(lock_path)
    frozen: tuple[FrozenInput, ...] = ()
    frozen_controls: tuple[FrozenInput, ...] = ()
    stage_descriptor = -1
    stage_monitor: select.kqueue | None = None
    ready_reader = -1
    ready_writer = -1
    approval_reader = -1
    approval_writer = -1
    child: subprocess.Popen[bytes] | None = None
    child_exit_monitor: select.kqueue | None = None
    child_reaped = False
    stage: Path | None = None
    stage_removed = False
    previous_handlers: dict[int, signal.Handlers] = {}
    received_signal: int | None = None
    managed_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def handle_signal(signum: int, _frame: object) -> None:
        nonlocal received_signal
        if received_signal is None:
            received_signal = signum

    for signum in managed_signals:
        previous_handlers[signum] = signal.signal(signum, handle_signal)
    try:
        (
            stage,
            stage_descriptor,
            stage_device,
            stage_inode,
            stage_monitor,
        ) = _create_run_stage(work, lock.directory_fd)
        _assert_run_stage_stable(
            stage,
            stage_descriptor,
            stage_device,
            stage_inode,
            stage_monitor,
        )
        if received_signal is not None:
            return 128 + received_signal
        frozen = freeze_inputs(sources, stage_descriptor)
        payloads = tuple(read_frozen(item) for item in frozen)
        for item in frozen:
            verify_frozen(item, item.sha256)
        if controls:
            frozen_controls = freeze_inputs(controls, stage_descriptor)
            for index, item in enumerate(frozen_controls):
                verify_frozen(item, item.sha256)
                expected = expected_controls[index]
                if item.sha256 != expected:
                    raise SecurityError(
                        f"executed native build control changed: {controls[index].name}"
                    )
        if received_signal is not None:
            return 128 + received_signal
        guarded_arguments = [
            "--guarded-run",
            str(stage),
            str(stage_descriptor),
            str(stage_device),
            str(stage_inode),
            str(os.getpid()),
        ]
        ready_reader, ready_writer = os.pipe()
        approval_reader, approval_writer = os.pipe()
        os.set_blocking(ready_reader, False)
        guarded_arguments.extend((str(ready_writer), str(approval_reader)))
        for item in frozen:
            guarded_arguments.extend((str(item.fd), item.sha256, str(item.size)))
        guarded_arguments.append(_overlay_digest(payloads))
        launch_command = list(command)
        if frozen_controls:
            implementation_path = str(controls[1])
            implementation_positions = [
                index
                for index, argument in enumerate(launch_command)
                if argument == implementation_path
            ]
            if len(implementation_positions) != 1:
                raise SecurityError(
                    "supervised command does not execute the reviewed implementation"
                )
            launch_command[implementation_positions[0]] = (
                f"/dev/fd/{frozen_controls[1].fd}"
            )
            for item in frozen_controls:
                guarded_arguments.extend((str(item.fd), item.sha256, str(item.size)))
            guarded_arguments.append(str(controls[1].parent.parent.parent))

        stage_exec = (
            "import os,sys; "
            "descriptor=int(sys.argv[1]); "
            "command=sys.argv[2:]; "
            "os.fchdir(descriptor); "
            "os.execv(command[0], command)"
        )
        child = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-c",
                stage_exec,
                str(stage_descriptor),
                *launch_command,
                *guarded_arguments,
            ],
            close_fds=True,
            pass_fds=(
                stage_descriptor,
                ready_writer,
                approval_reader,
                *(item.fd for item in frozen),
                *(item.fd for item in frozen_controls),
            ),
            start_new_session=True,
        )
        child_exit_monitor = select.kqueue()
        child_exit_monitor.control(
            [
                select.kevent(
                    child.pid,
                    filter=select.KQ_FILTER_PROC,
                    flags=(select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR),
                    fflags=select.KQ_NOTE_EXIT,
                )
            ],
            0,
            0,
        )
        os.close(ready_writer)
        ready_writer = -1
        os.close(approval_reader)
        approval_reader = -1
        promotion_approved = False
        return_code: int | None = None
        while True:
            _assert_run_stage_stable(
                stage,
                stage_descriptor,
                stage_device,
                stage_inode,
                stage_monitor,
            )
            if received_signal is not None:
                break
            try:
                request = os.read(ready_reader, 2)
            except BlockingIOError:
                request = b""
            if received_signal is not None:
                break
            if request:
                if request != b"R" or promotion_approved:
                    raise SecurityError("invalid native COLMAP promotion request")
                _assert_run_stage_stable(
                    stage,
                    stage_descriptor,
                    stage_device,
                    stage_inode,
                    stage_monitor,
                )
                previous_mask = signal.pthread_sigmask(
                    signal.SIG_BLOCK,
                    managed_signals,
                )
                try:
                    if received_signal is not None:
                        break
                    os.write(approval_writer, b"A")
                    os.close(approval_writer)
                    approval_writer = -1
                    promotion_approved = True
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            if received_signal is not None:
                _quiesce_group(
                    child.pid,
                    termination_grace,
                    received_signal,
                    child,
                )
                break
            if child_exit_monitor.control(None, 1, 0):
                break
            time.sleep(0.02)
        _assert_run_stage_stable(
            stage,
            stage_descriptor,
            stage_device,
            stage_inode,
            stage_monitor,
        )
        _quiesce_group(
            child.pid,
            termination_grace,
            received_signal or signal.SIGTERM,
            child,
        )
        return_code = child.wait(timeout=max(termination_grace, 1.0))
        child_reaped = True
        for item in frozen:
            verify_frozen(item, item.sha256)
        for item in frozen_controls:
            verify_frozen(item, item.sha256)
        stage_monitor.close()
        stage_monitor = None
        _remove_owned_run_stage(
            stage,
            stage_descriptor,
            stage_device,
            stage_inode,
            frozen_controls[3] if frozen_controls else None,
        )
        stage_removed = True
        if received_signal is not None:
            return 128 + received_signal
        if return_code is None:
            raise SecurityError("native COLMAP child status is unavailable")
        return return_code
    finally:
        active_exception = sys.exc_info()[1]
        try:
            if child is not None and not child_reaped:
                try:
                    _quiesce_group(child.pid, termination_grace, leader=child)
                finally:
                    child.wait(timeout=max(termination_grace, 1.0))
                    child_reaped = True
            close_frozen_inputs(frozen)
            for descriptor in (
                ready_reader,
                ready_writer,
                approval_reader,
                approval_writer,
            ):
                if descriptor >= 0:
                    os.close(descriptor)
            if stage_monitor is not None:
                stage_monitor.close()
                stage_monitor = None
            if stage is not None and stage_descriptor >= 0 and not stage_removed:
                try:
                    _remove_owned_run_stage(
                        stage,
                        stage_descriptor,
                        stage_device,
                        stage_inode,
                        frozen_controls[3] if frozen_controls else None,
                    )
                    stage_removed = True
                except SecurityError:
                    if active_exception is None:
                        raise
        finally:
            close_frozen_inputs(frozen_controls)
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
            if child_exit_monitor is not None:
                child_exit_monitor.close()
            if stage_descriptor >= 0:
                os.close(stage_descriptor)
            lock.close()


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--input", action="append", default=[], type=Path)
    parser.add_argument("--control-input", action="append", default=[], type=Path)
    parser.add_argument("--termination-grace", type=float, default=5.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    parsed = parser.parse_args(arguments)
    if parsed.command and parsed.command[0] == "--":
        parsed.command = parsed.command[1:]
    if parsed.termination_grace <= 0 or parsed.termination_grace > 30:
        parser.error("--termination-grace must be in (0, 30]")
    return parsed


def main(arguments: Sequence[str] | None = None) -> int:
    parsed = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    try:
        expected_controls: tuple[str, ...] = ()
        if parsed.control_input:
            wrapper_digest = os.environ.get(
                "EASYSPLAT_EXECUTED_WRAPPER_SHA256", ""
            )
            implementation_digest = os.environ.get(
                "EASYSPLAT_EXPECTED_IMPLEMENTATION_SHA256", ""
            )
            supervisor_digest = os.environ.get(
                "EASYSPLAT_EXECUTED_SUPERVISOR_SHA256", ""
            )
            promoter_digest = os.environ.get(
                "EASYSPLAT_EXPECTED_PROMOTER_SHA256", ""
            )
            for label, digest in (
                ("wrapper", wrapper_digest),
                ("implementation", implementation_digest),
                ("supervisor", supervisor_digest),
                ("promoter", promoter_digest),
            ):
                if len(digest) != 64 or any(
                    character not in "0123456789abcdef" for character in digest
                ):
                    raise SecurityError(
                        f"executed native build {label} digest is unavailable"
                    )
            expected_controls = (
                wrapper_digest,
                implementation_digest,
                supervisor_digest,
                promoter_digest,
            )
        return supervise(
            work=parsed.work,
            lock_path=parsed.lock,
            sources=parsed.input,
            control_sources=parsed.control_input,
            expected_control_sha256=expected_controls,
            command=parsed.command,
            termination_grace=parsed.termination_grace,
        )
    except BuildLockedError as error:
        print(f"COLMAP build failed: {error}", file=sys.stderr)
        return 75
    except (OSError, SecurityError, subprocess.SubprocessError) as error:
        print(f"COLMAP build failed: {error}", file=sys.stderr)
        return 74


if __name__ == "__main__":
    raise SystemExit(main())
