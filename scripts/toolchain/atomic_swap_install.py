#!/usr/bin/env python3
"""Promote a staged directory without making an existing install disappear."""

from __future__ import annotations

import ctypes
import errno
import hashlib
import json
import os
import re
import secrets
import signal
import stat
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
TRANSACTION_SCHEMA = 2
TRANSACTION_SUFFIX = ".promotion-state"
FINALIZATION_MARKER = ".finalizing"
RETIREMENT_SUFFIX = ".retiring"
MAX_TRANSACTION_BYTES = 16 * 1024
TREE_RECEIPT_PREFIX = "tree-v2-clean:"
BOUND_TREE_RECEIPT_PREFIX = "tree-v2:"
LEGACY_TREE_RECEIPT_PREFIX = "tree-v1:"
TREE_READ_BLOCK_SIZE = 1024 * 1024
ACL_TYPE_EXTENDED = 0x00000100
EMPTY_EXTENDED_METADATA = (0).to_bytes(8, "big") + b"\0"
XATTR_SHOWCOMPRESSION = 0x0020
SYSTEM_PROVENANCE_ATTRIBUTE = b"com.apple.provenance"


def _is_permitted_clean_metadata(blob: bytes) -> bool:
    """True for empty extended metadata, or exactly one unremovable
    com.apple.provenance attribute and no extended ACL."""

    if blob == EMPTY_EXTENDED_METADATA:
        return True
    if len(blob) < 8:
        return False
    count = int.from_bytes(blob[:8], "big")
    if count != 1:
        return False
    offset = 8
    if len(blob) < offset + 8:
        return False
    name_length = int.from_bytes(blob[offset : offset + 8], "big")
    offset += 8
    if len(blob) < offset + name_length:
        return False
    name = blob[offset : offset + name_length]
    offset += name_length
    if name != SYSTEM_PROVENANCE_ATTRIBUTE:
        return False
    if len(blob) < offset + 8:
        return False
    value_length = int.from_bytes(blob[offset : offset + 8], "big")
    offset += 8
    if len(blob) < offset + value_length:
        return False
    offset += value_length
    return blob[offset:] == b"\0"

DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
FILE_OPEN_FLAGS = (
    os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
)
STABLE_METADATA_FIELDS = (
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


class PromotionRecoveryError(OSError):
    """Promotion state is durable but requires recovery before reuse."""


def require_directory(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"{label} is not a regular directory: {path}")


def _same_metadata(*items: os.stat_result) -> bool:
    if len(items) < 2:
        return True
    first = items[0]
    return all(
        all(
            getattr(first, field) == getattr(item, field)
            for field in STABLE_METADATA_FIELDS
        )
        for item in items[1:]
    )


def _same_stat_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _same_directory_binding(*items: os.stat_result) -> bool:
    if len(items) < 2:
        return True
    first = items[0]
    fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid")
    return all(
        all(getattr(first, field) == getattr(item, field) for field in fields)
        for item in items[1:]
    )


def _update_record(digest: "hashlib._Hash", *parts: bytes) -> None:
    for part in parts:
        digest.update(len(part).to_bytes(8, "big"))
        digest.update(part)


def _metadata_record(metadata: os.stat_result) -> bytes:
    values = (
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_nlink,
        metadata.st_flags,
    )
    return ":".join(str(value) for value in values).encode("ascii")


def _descriptor_extended_metadata(descriptor: int) -> bytes:
    """Serialize one stable descriptor's xattrs and extended ACL."""

    libc = ctypes.CDLL(None, use_errno=True)
    flistxattr = libc.flistxattr
    flistxattr.argtypes = (
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
    )
    flistxattr.restype = ctypes.c_ssize_t
    fgetxattr = libc.fgetxattr
    fgetxattr.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    )
    fgetxattr.restype = ctypes.c_ssize_t
    acl_get_fd = libc.acl_get_fd_np
    acl_get_fd.argtypes = (ctypes.c_int, ctypes.c_int)
    acl_get_fd.restype = ctypes.c_void_p
    acl_to_text = libc.acl_to_text
    acl_to_text.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t))
    acl_to_text.restype = ctypes.c_void_p
    acl_free = libc.acl_free
    acl_free.argtypes = (ctypes.c_void_p,)
    acl_free.restype = ctypes.c_int

    before = os.fstat(descriptor)
    ctypes.set_errno(0)
    names_size = flistxattr(descriptor, None, 0, XATTR_SHOWCOMPRESSION)
    if names_size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if names_size:
        names_buffer = ctypes.create_string_buffer(names_size)
        ctypes.set_errno(0)
        actual_names_size = flistxattr(
            descriptor,
            names_buffer,
            names_size,
            XATTR_SHOWCOMPRESSION,
        )
        if actual_names_size < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        if actual_names_size != names_size:
            raise ValueError("extended attribute names changed while read")
        names = sorted(
            name
            for name in bytes(names_buffer.raw[:actual_names_size]).split(b"\0")
            if name
        )
    else:
        names = []

    encoded = bytearray()
    encoded.extend(len(names).to_bytes(8, "big"))
    for name in names:
        ctypes.set_errno(0)
        value_size = fgetxattr(
            descriptor,
            name,
            None,
            0,
            0,
            XATTR_SHOWCOMPRESSION,
        )
        if value_size < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), os.fsdecode(name))
        value_buffer = ctypes.create_string_buffer(value_size or 1)
        ctypes.set_errno(0)
        actual_value_size = fgetxattr(
            descriptor,
            name,
            value_buffer,
            value_size,
            0,
            XATTR_SHOWCOMPRESSION,
        )
        if actual_value_size < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), os.fsdecode(name))
        if actual_value_size != value_size:
            raise ValueError(
                f"extended attribute changed while read: {os.fsdecode(name)}"
            )
        value = bytes(value_buffer.raw[:actual_value_size])
        encoded.extend(len(name).to_bytes(8, "big"))
        encoded.extend(name)
        encoded.extend(len(value).to_bytes(8, "big"))
        encoded.extend(value)

    ctypes.set_errno(0)
    acl = acl_get_fd(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error = ctypes.get_errno()
        if error != errno.ENOENT:
            raise OSError(error, os.strerror(error))
        acl_text = None
    else:
        text_pointer = None
        try:
            text_length = ctypes.c_ssize_t()
            ctypes.set_errno(0)
            text_pointer = acl_to_text(acl, ctypes.byref(text_length))
            if not text_pointer:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
            acl_text = ctypes.string_at(text_pointer, text_length.value)
        finally:
            if text_pointer and acl_free(text_pointer) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
            if acl_free(acl) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
    if acl_text is None:
        encoded.extend(b"\0")
    else:
        encoded.extend(b"\1")
        encoded.extend(len(acl_text).to_bytes(8, "big"))
        encoded.extend(acl_text)

    ctypes.set_errno(0)
    final_names_size = flistxattr(
        descriptor,
        None,
        0,
        XATTR_SHOWCOMPRESSION,
    )
    if final_names_size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    after = os.fstat(descriptor)
    if final_names_size != names_size or not _same_metadata(before, after):
        raise ValueError("extended metadata changed while read")
    return bytes(encoded)


def _read_stable_file(
    parent: int,
    name: str,
    relative: bytes,
    before: os.stat_result,
    bind_extended_metadata: bool,
    require_clean_metadata: bool,
) -> tuple[os.stat_result, bytes, bytes]:
    if before.st_nlink != 1:
        raise ValueError(
            f"tree receipt rejects multiply linked file: {os.fsdecode(relative)}"
        )
    try:
        descriptor = os.open(name, FILE_OPEN_FLAGS, dir_fd=parent)
    except OSError as error:
        raise ValueError(
            f"tree receipt could not bind file: {os.fsdecode(relative)}"
        ) from error
    try:
        opened = os.fstat(descriptor)
        named = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(opened.st_mode) or not _same_metadata(
            before, opened, named
        ):
            raise ValueError(
                f"tree receipt file identity changed: {os.fsdecode(relative)}"
            )
        if require_clean_metadata and opened.st_flags != 0:
            raise ValueError(
                f"tree receipt rejects file flags: {os.fsdecode(relative)}"
            )
        extended_metadata = (
            _descriptor_extended_metadata(descriptor) if bind_extended_metadata else b""
        )
        if require_clean_metadata and not _is_permitted_clean_metadata(
            extended_metadata
        ):
            raise ValueError(
                f"tree receipt rejects extended metadata: {os.fsdecode(relative)}"
            )
        content = hashlib.sha256()
        offset = 0
        while offset < opened.st_size:
            block = os.pread(
                descriptor,
                min(TREE_READ_BLOCK_SIZE, opened.st_size - offset),
                offset,
            )
            if not block:
                raise ValueError(
                    f"tree receipt encountered a short file: {os.fsdecode(relative)}"
                )
            content.update(block)
            offset += len(block)
        if os.pread(descriptor, 1, opened.st_size):
            raise ValueError(
                f"tree receipt file grew while read: {os.fsdecode(relative)}"
            )
        after = os.fstat(descriptor)
        named_after = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not _same_metadata(before, opened, after, named_after):
            raise ValueError(
                f"tree receipt file changed while read: {os.fsdecode(relative)}"
            )
        if bind_extended_metadata and (
            _descriptor_extended_metadata(descriptor) != extended_metadata
        ):
            raise ValueError(
                "tree receipt file extended metadata changed while read: "
                f"{os.fsdecode(relative)}"
            )
        return opened, content.digest(), extended_metadata
    finally:
        os.close(descriptor)


def _hash_directory_tree(
    digest: "hashlib._Hash",
    descriptor: int,
    relative_prefix: bytes,
    opened: os.stat_result,
    bind_extended_metadata: bool,
    require_clean_metadata: bool,
) -> None:
    names = sorted(os.listdir(descriptor), key=os.fsencode)
    for name in names:
        encoded_name = os.fsencode(name)
        relative = (
            encoded_name
            if not relative_prefix
            else relative_prefix + b"/" + encoded_name
        )
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(before.st_mode):
            try:
                child = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=descriptor)
            except OSError as error:
                raise ValueError(
                    f"tree receipt could not bind directory: {os.fsdecode(relative)}"
                ) from error
            try:
                child_opened = os.fstat(child)
                named = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if not stat.S_ISDIR(child_opened.st_mode) or not _same_metadata(
                    before, child_opened, named
                ):
                    raise ValueError(
                        "tree receipt directory identity changed: "
                        f"{os.fsdecode(relative)}"
                    )
                if require_clean_metadata and child_opened.st_flags != 0:
                    raise ValueError(
                        f"tree receipt rejects directory flags: {os.fsdecode(relative)}"
                    )
                extended_metadata = (
                    _descriptor_extended_metadata(child)
                    if bind_extended_metadata
                    else b""
                )
                if require_clean_metadata and not _is_permitted_clean_metadata(
                    extended_metadata
                ):
                    raise ValueError(
                        "tree receipt rejects extended metadata: "
                        f"{os.fsdecode(relative)}"
                    )
                _update_record(
                    digest,
                    b"directory",
                    relative,
                    _metadata_record(child_opened),
                )
                if bind_extended_metadata:
                    _update_record(
                        digest,
                        b"extended-metadata",
                        relative,
                        extended_metadata,
                    )
                _hash_directory_tree(
                    digest,
                    child,
                    relative,
                    child_opened,
                    bind_extended_metadata,
                    require_clean_metadata,
                )
                child_after = os.fstat(child)
                named_after = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if not _same_metadata(before, child_opened, child_after, named_after):
                    raise ValueError(
                        f"tree receipt directory changed: {os.fsdecode(relative)}"
                    )
                if bind_extended_metadata and (
                    _descriptor_extended_metadata(child) != extended_metadata
                ):
                    raise ValueError(
                        "tree receipt directory extended metadata changed: "
                        f"{os.fsdecode(relative)}"
                    )
            finally:
                os.close(child)
        elif stat.S_ISREG(before.st_mode):
            file_metadata, content_digest, extended_metadata = _read_stable_file(
                descriptor,
                name,
                relative,
                before,
                bind_extended_metadata,
                require_clean_metadata,
            )
            _update_record(
                digest,
                b"file",
                relative,
                _metadata_record(file_metadata),
                str(file_metadata.st_size).encode("ascii"),
                content_digest,
            )
            if bind_extended_metadata:
                _update_record(
                    digest,
                    b"extended-metadata",
                    relative,
                    extended_metadata,
                )
        else:
            raise ValueError(
                f"tree receipt rejects unsupported entry: {os.fsdecode(relative)}"
            )
    after = os.fstat(descriptor)
    if not _same_metadata(opened, after):
        location = os.fsdecode(relative_prefix) if relative_prefix else "."
        raise ValueError(f"tree receipt directory changed while read: {location}")


def tree_receipt(
    root: Path,
    expected_root_identity: dict[str, int] | None = None,
    receipt_prefix: str = TREE_RECEIPT_PREFIX,
) -> str:
    """Hash one exact, no-follow directory generation and every file byte."""

    root = Path(root)
    expected = (
        None
        if expected_root_identity is None
        else _parse_identity(expected_root_identity, "owned root")
    )
    if receipt_prefix not in {
        TREE_RECEIPT_PREFIX,
        BOUND_TREE_RECEIPT_PREFIX,
        LEGACY_TREE_RECEIPT_PREFIX,
    }:
        raise ValueError("unsupported tree receipt format")
    bind_extended_metadata = receipt_prefix != LEGACY_TREE_RECEIPT_PREFIX
    require_clean_metadata = receipt_prefix == TREE_RECEIPT_PREFIX
    parent = os.open(root.parent, DIRECTORY_OPEN_FLAGS)
    try:
        before = os.stat(root.name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode):
            raise ValueError(f"tree receipt root is not a directory: {root}")
        try:
            descriptor = os.open(root.name, DIRECTORY_OPEN_FLAGS, dir_fd=parent)
        except OSError as error:
            raise ValueError(f"tree receipt could not bind root: {root}") from error
        try:
            opened = os.fstat(descriptor)
            named = os.stat(root.name, dir_fd=parent, follow_symlinks=False)
            if not _same_metadata(before, opened, named):
                raise ValueError(f"tree receipt root identity changed: {root}")
            if expected is not None and (
                opened.st_dev != expected["device"]
                or opened.st_ino != expected["inode"]
            ):
                raise ValueError(f"tree receipt owned root identity changed: {root}")
            if require_clean_metadata and opened.st_flags != 0:
                raise ValueError(f"tree receipt rejects directory flags: {root}")
            extended_metadata = (
                _descriptor_extended_metadata(descriptor)
                if bind_extended_metadata
                else b""
            )
            if require_clean_metadata and not _is_permitted_clean_metadata(
                extended_metadata
            ):
                raise ValueError(f"tree receipt rejects extended metadata: {root}")
            digest = hashlib.sha256()
            digest.update(
                b"EASYSPLAT_ATOMIC_TREE_RECEIPT_V2_CLEAN\0"
                if require_clean_metadata
                else (
                    b"EASYSPLAT_ATOMIC_TREE_RECEIPT_V2\0"
                    if bind_extended_metadata
                    else b"EASYSPLAT_ATOMIC_TREE_RECEIPT_V1\0"
                )
            )
            _update_record(digest, b"directory", b".", _metadata_record(opened))
            if bind_extended_metadata:
                _update_record(
                    digest,
                    b"extended-metadata",
                    b".",
                    extended_metadata,
                )
            _hash_directory_tree(
                digest,
                descriptor,
                b"",
                opened,
                bind_extended_metadata,
                require_clean_metadata,
            )
            after = os.fstat(descriptor)
            named_after = os.stat(root.name, dir_fd=parent, follow_symlinks=False)
            if not _same_metadata(before, opened, after, named_after):
                raise ValueError(f"tree receipt root changed while read: {root}")
            if bind_extended_metadata and (
                _descriptor_extended_metadata(descriptor) != extended_metadata
            ):
                raise ValueError(f"tree receipt root extended metadata changed: {root}")
            return f"{receipt_prefix}{digest.hexdigest()}"
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def _parse_tree_receipt(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"invalid {label} tree receipt")
    prefix = next(
        (
            candidate
            for candidate in (
                TREE_RECEIPT_PREFIX,
                BOUND_TREE_RECEIPT_PREFIX,
                LEGACY_TREE_RECEIPT_PREFIX,
            )
            if value.startswith(candidate)
        ),
        None,
    )
    if prefix is None:
        raise ValueError(f"invalid {label} tree receipt")
    hexadecimal = value[len(prefix) :]
    if len(hexadecimal) != 64 or any(
        character not in "0123456789abcdef" for character in hexadecimal
    ):
        raise ValueError(f"invalid {label} tree receipt")
    return value


def _verify_tree_receipt(path: Path, expected: object, label: str) -> None:
    parsed = _parse_tree_receipt(expected, label)
    prefix = (
        TREE_RECEIPT_PREFIX
        if parsed.startswith(TREE_RECEIPT_PREFIX)
        else (
            BOUND_TREE_RECEIPT_PREFIX
            if parsed.startswith(BOUND_TREE_RECEIPT_PREFIX)
            else LEGACY_TREE_RECEIPT_PREFIX
        )
    )
    actual = tree_receipt(path, receipt_prefix=prefix)
    if actual != parsed:
        raise PromotionRecoveryError(
            f"{label} tree receipt differs at {path}; recovery state preserved"
        )


def sync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise ValueError(f"path is not a directory: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _sync_bound_parent(descriptor: int) -> None:
    os.fsync(descriptor)


def sync_regular_file(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"path is not a regular file: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_tree(root: Path) -> None:
    require_directory(root, "staged install")
    files = []
    directories = [root]
    for current_raw, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_raw)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            if path.is_symlink() or not stat.S_ISDIR(path.lstat().st_mode):
                raise ValueError(
                    f"staged install contains a non-directory entry: {path}"
                )
            directories.append(path)
        for name in file_names:
            path = current / name
            if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
                raise ValueError(f"staged install contains a non-regular file: {path}")
            files.append(path)

    for path in files:
        sync_regular_file(path)
    for path in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        sync_directory(path)


@contextmanager
def blocked_termination_signals() -> Iterator[None]:
    """Defer catchable termination while directory names are in transition."""

    if not hasattr(signal, "pthread_sigmask"):
        yield
        return
    blocked = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def directory_identity(path: Path, label: str) -> dict[str, int]:
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"{label} is not a regular directory: {path}")
    return {"device": metadata.st_dev, "inode": metadata.st_ino}


def _after_owned_tree_publish(parent: int, name: str) -> None:
    """Test seam after a newly created tree receives its public name."""


def _remove_created_tree_at(
    parent: int,
    name: str,
    created: os.stat_result,
    path: Path,
) -> None:
    try:
        named = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except OSError as error:
        raise PromotionRecoveryError(
            f"created owned tree disappeared during rollback: {path}"
        ) from error
    if not stat.S_ISDIR(named.st_mode) or not _same_stat_identity(created, named):
        raise PromotionRecoveryError(
            f"created owned-tree replacement was preserved: {path}"
        )

    claimed, claimed_metadata = _claim_entry(parent, name, named)
    remove_succeeded = False
    try:
        directory = os.open(claimed, DIRECTORY_OPEN_FLAGS, dir_fd=parent)
        try:
            opened = os.fstat(directory)
            claimed_named = os.stat(
                claimed,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISDIR(opened.st_mode)
                or not _same_stat_identity(created, opened)
                or not _same_stat_identity(created, claimed_named)
                or not _same_stat_identity(claimed_metadata, opened)
            ):
                raise PromotionRecoveryError(
                    f"created owned tree changed during rollback: {path}"
                )
            _remove_directory_contents(directory, allow_symlinks=True)
            after = os.fstat(directory)
            claimed_after = os.stat(
                claimed,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISDIR(after.st_mode)
                or not _same_stat_identity(created, after)
                or not _same_stat_identity(created, claimed_after)
            ):
                raise PromotionRecoveryError(
                    f"created owned tree changed after rollback cleanup: {path}"
                )
        finally:
            os.close(directory)
        os.rmdir(claimed, dir_fd=parent)
        remove_succeeded = True
        _sync_bound_parent(parent)
    finally:
        if not remove_succeeded:
            try:
                os.stat(claimed, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _restore_claimed_entry(parent, claimed, name)
                os.fsync(parent)


def create_owned_tree(path: Path) -> dict[str, int]:
    if not path.name or path.name in {".", ".."} or Path(path.name).name != path.name:
        raise ValueError(f"invalid owned-tree name: {path}")
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    private_name = ""
    directory = -1
    created: os.stat_result | None = None
    published = False
    try:
        for _ in range(128):
            candidate = f".easysplat-create.{os.getpid()}.{secrets.token_hex(12)}"
            try:
                os.mkdir(candidate, mode=0o700, dir_fd=parent)
            except FileExistsError:
                continue
            private_name = candidate
            break
        if not private_name:
            raise PromotionRecoveryError(
                "could not reserve a private owned-tree creation name"
            )

        directory = os.open(private_name, DIRECTORY_OPEN_FLAGS, dir_fd=parent)
        created = os.fstat(directory)
        private_named = os.stat(
            private_name,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(created.st_mode)
            or not _same_stat_identity(created, private_named)
            or stat.S_IMODE(created.st_mode) != 0o700
            or created.st_uid != os.getuid()
            or created.st_gid != os.getgid()
        ):
            raise PromotionRecoveryError(
                f"private owned tree changed during creation: {path}"
            )
        os.fsync(directory)
        _rename_exclusive_at(parent, private_name, path.name)
        private_name = ""
        published = True
        _after_owned_tree_publish(parent, path.name)

        named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        opened = os.fstat(directory)
        if (
            not stat.S_ISDIR(named.st_mode)
            or not _same_stat_identity(created, opened)
            or not _same_stat_identity(created, named)
            or stat.S_IMODE(named.st_mode) != 0o700
            or named.st_uid != os.getuid()
            or named.st_gid != os.getgid()
        ):
            raise PromotionRecoveryError(f"owned tree changed after creation: {path}")
        _sync_bound_parent(parent)
        return {"device": created.st_dev, "inode": created.st_ino}
    except BaseException as creation_error:
        if published and created is not None:
            try:
                _remove_created_tree_at(parent, path.name, created, path)
            except BaseException as rollback_error:
                raise PromotionRecoveryError(
                    "owned tree creation failed and identity-bound rollback "
                    f"could not complete ({creation_error}): {rollback_error}"
                ) from rollback_error
        raise
    finally:
        if directory >= 0:
            os.close(directory)
        try:
            if private_name and created is not None and not published:
                private_named = os.stat(
                    private_name,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
                if not stat.S_ISDIR(private_named.st_mode) or not _same_stat_identity(
                    created, private_named
                ):
                    raise PromotionRecoveryError(
                        "private owned-tree cleanup name was replaced; "
                        f"preserved as {private_name}"
                    )
                os.rmdir(private_name, dir_fd=parent)
                os.fsync(parent)
        finally:
            os.close(parent)


def transaction_state_path(stage: Path) -> Path:
    return stage.with_name(f"{stage.name}{TRANSACTION_SUFFIX}")


def transaction_finalization_path(stage: Path) -> Path:
    return stage.with_name(f"{stage.name}{FINALIZATION_MARKER}{TRANSACTION_SUFFIX}")


def retirement_state_path(stage: Path) -> Path:
    return stage.with_name(f"{stage.name}{RETIREMENT_SUFFIX}")


def _same_identity(left: dict[str, int], right: dict[str, int]) -> bool:
    return left["device"] == right["device"] and left["inode"] == right["inode"]


def _optional_directory_identity(path: Path, label: str) -> dict[str, int] | None:
    try:
        return directory_identity(path, label)
    except FileNotFoundError:
        return None


def _require_simple_name(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or Path(value).name != value
    ):
        raise ValueError(f"invalid {label} in promotion transaction")
    return value


def _parse_identity(value: object, label: str) -> dict[str, int]:
    if not isinstance(value, dict) or set(value) != {"device", "inode"}:
        raise ValueError(f"invalid {label} identity in promotion transaction")
    result: dict[str, int] = {}
    for key in ("device", "inode"):
        component = value[key]
        if (
            isinstance(component, bool)
            or not isinstance(component, int)
            or component < 0
        ):
            raise ValueError(f"invalid {label} identity in promotion transaction")
        result[key] = component
    return result


def _transaction_payload(
    stage: Path,
    install: Path,
    expected_stage_receipt: str,
) -> dict[str, object]:
    require_directory(stage, "staged install")
    parent = stage.parent.resolve(strict=True)
    if install.parent.resolve(strict=True) != parent:
        raise ValueError("stage and install must have the same parent directory")
    canonical = transaction_state_path(stage)
    retirement = retirement_state_path(stage)
    finalization = transaction_finalization_path(stage)
    reserved_names = {
        stage.name,
        install.name,
        canonical.name,
        finalization.name,
        retirement.name,
    }
    if len(reserved_names) != 5:
        raise ValueError(
            "promotion paths and reserved transaction names must be pairwise distinct"
        )
    if install.is_symlink():
        raise ValueError(f"install path is a symlink: {install}")
    for state_path, label in (
        (canonical, "transaction"),
        (retirement, "retirement"),
        (finalization, "finalization"),
    ):
        try:
            state_path.lstat()
        except FileNotFoundError:
            pass
        else:
            raise ValueError(f"staged {label} path already exists: {state_path}")
    expected_stage_receipt = _parse_tree_receipt(
        expected_stage_receipt, "staged install"
    )
    if not expected_stage_receipt.startswith(TREE_RECEIPT_PREFIX):
        raise ValueError("new promotion requires a current staged tree receipt")
    _verify_tree_receipt(stage, expected_stage_receipt, "staged install")
    installed = _optional_directory_identity(install, "current install")
    installed_tree_receipt = (
        tree_receipt(install, receipt_prefix=BOUND_TREE_RECEIPT_PREFIX)
        if installed is not None
        else None
    )
    return {
        "schema": TRANSACTION_SCHEMA,
        "parent": directory_identity(parent, "promotion parent"),
        "stage_name": stage.name,
        "install_name": install.name,
        "staged": directory_identity(stage, "staged install"),
        "installed": installed,
        "staged_tree_receipt": expected_stage_receipt,
        "installed_tree_receipt": installed_tree_receipt,
    }


def _write_transaction(path: Path, payload: dict[str, object]) -> None:
    encoded = (
        json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")
    if len(encoded) > MAX_TRANSACTION_BYTES:
        raise ValueError("promotion transaction is unexpectedly large")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    expected_parent = _parse_identity(payload.get("parent"), "parent")
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    descriptor = -1
    try:
        parent_opened = os.fstat(parent)
        parent_named = path.parent.lstat()
        if (
            not stat.S_ISDIR(parent_opened.st_mode)
            or not _same_metadata(parent_opened, parent_named)
            or parent_opened.st_dev != expected_parent["device"]
            or parent_opened.st_ino != expected_parent["inode"]
        ):
            raise PromotionRecoveryError(
                f"promotion transaction parent changed before write: {path.parent}"
            )
        descriptor = os.open(path.name, flags, 0o600, dir_fd=parent)
        offset = 0
        while offset < len(encoded):
            written = os.write(descriptor, encoded[offset:])
            if written <= 0:
                raise OSError("short promotion transaction write")
            offset += written
        os.fsync(descriptor)
        _sync_bound_parent(parent)
        parent_after = os.fstat(parent)
        parent_named_after = path.parent.lstat()
        if not _same_directory_binding(
            parent_opened,
            parent_after,
            parent_named_after,
        ):
            os.unlink(path.name, dir_fd=parent)
            _sync_bound_parent(parent)
            raise PromotionRecoveryError(
                f"promotion transaction parent changed during write: {path.parent}"
            )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent)


def _read_transaction(path: Path) -> tuple[dict[str, object], dict[str, int]]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > MAX_TRANSACTION_BYTES
        ):
            raise ValueError(f"unsafe promotion transaction: {path}")
        chunks = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                raise OSError(f"short promotion transaction read: {path}")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ValueError(f"promotion transaction grew while read: {path}")
        after = os.fstat(descriptor)
        named = path.lstat()
        stable = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_nlink",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(
            getattr(before, field) != getattr(after, field)
            or getattr(before, field) != getattr(named, field)
            for field in stable
        ):
            raise ValueError(f"promotion transaction changed while read: {path}")
    finally:
        os.close(descriptor)

    def reject_constant(value: str) -> object:
        raise ValueError(f"non-finite transaction constant: {value}")

    try:
        payload = json.loads(
            b"".join(chunks).decode("utf-8"), parse_constant=reject_constant
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid promotion transaction: {path}") from error
    expected_keys = {
        "schema",
        "parent",
        "stage_name",
        "install_name",
        "staged",
        "installed",
        "staged_tree_receipt",
        "installed_tree_receipt",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys:
        raise ValueError(f"invalid promotion transaction fields: {path}")
    if payload["schema"] != TRANSACTION_SCHEMA:
        raise ValueError(f"unsupported promotion transaction schema: {path}")
    payload["parent"] = _parse_identity(payload["parent"], "parent")
    payload["staged"] = _parse_identity(payload["staged"], "staged")
    payload["staged_tree_receipt"] = _parse_tree_receipt(
        payload["staged_tree_receipt"], "staged"
    )
    if payload["installed"] is not None:
        payload["installed"] = _parse_identity(payload["installed"], "installed")
        payload["installed_tree_receipt"] = _parse_tree_receipt(
            payload["installed_tree_receipt"], "installed"
        )
    elif payload["installed_tree_receipt"] is not None:
        raise ValueError(
            f"unexpected installed tree receipt in promotion transaction: {path}"
        )
    stage_name = _require_simple_name(payload["stage_name"], "stage name")
    _require_simple_name(payload["install_name"], "install name")
    allowed_names = {
        f"{stage_name}{TRANSACTION_SUFFIX}",
        f"{stage_name}{FINALIZATION_MARKER}{TRANSACTION_SUFFIX}",
    }
    if path.name not in allowed_names:
        raise ValueError(
            f"promotion transaction filename does not match payload: {path}"
        )
    actual_parent = directory_identity(
        path.parent.resolve(strict=True), "promotion parent"
    )
    if not _same_identity(actual_parent, payload["parent"]):
        raise ValueError(f"promotion transaction parent changed: {path}")
    return payload, {"device": before.st_dev, "inode": before.st_ino}


def _transaction_paths(journal: Path, payload: dict[str, object]) -> tuple[Path, Path]:
    parent = journal.parent
    return parent / str(payload["stage_name"]), parent / str(payload["install_name"])


def _transaction_receipt_generation(payload: dict[str, object]) -> str:
    staged_receipt = payload["staged_tree_receipt"]
    installed_receipt = payload["installed_tree_receipt"]
    installed = payload["installed"]
    assert isinstance(staged_receipt, str)
    if installed is None:
        if installed_receipt is not None:
            raise ValueError("first-install transaction has an installed receipt")
    elif not isinstance(installed_receipt, str):
        raise ValueError("existing-install transaction is missing its receipt")

    if staged_receipt.startswith(TREE_RECEIPT_PREFIX):
        if installed_receipt is not None and not installed_receipt.startswith(
            BOUND_TREE_RECEIPT_PREFIX
        ):
            raise ValueError("current promotion transaction mixes receipt generations")
        return "current"
    if staged_receipt.startswith(LEGACY_TREE_RECEIPT_PREFIX):
        if installed_receipt is not None and not installed_receipt.startswith(
            LEGACY_TREE_RECEIPT_PREFIX
        ):
            raise ValueError("legacy promotion transaction mixes receipt generations")
        return "legacy"
    raise ValueError("promotion transaction has an unsupported staged receipt")


def _layout(payload: dict[str, object], stage: Path, install: Path) -> str:
    staged = payload["staged"]
    installed = payload["installed"]
    assert isinstance(staged, dict)
    assert installed is None or isinstance(installed, dict)
    stage_now = _optional_directory_identity(stage, "staged install name")
    install_now = _optional_directory_identity(install, "install name")
    pre_promotion = stage_now is not None and _same_identity(stage_now, staged)
    if installed is None:
        pre_promotion = pre_promotion and install_now is None
        promoted = (
            stage_now is None
            and install_now is not None
            and _same_identity(install_now, staged)
        )
    else:
        pre_promotion = (
            pre_promotion
            and install_now is not None
            and _same_identity(install_now, installed)
        )
        promoted = (
            stage_now is not None
            and _same_identity(stage_now, installed)
            and install_now is not None
            and _same_identity(install_now, staged)
        )
    if pre_promotion:
        return "prepared"
    if promoted:
        return "promoted"
    return "ambiguous"


def _verify_layout_receipts(
    payload: dict[str, object],
    stage: Path,
    install: Path,
    layout: str,
) -> None:
    staged_receipt = payload["staged_tree_receipt"]
    installed_receipt = payload["installed_tree_receipt"]
    if layout == "prepared":
        _verify_tree_receipt(stage, staged_receipt, "staged install")
        if installed_receipt is not None:
            _verify_tree_receipt(install, installed_receipt, "current install")
        return
    if layout == "promoted":
        _verify_tree_receipt(install, staged_receipt, "promoted install")
        if installed_receipt is not None:
            _verify_tree_receipt(stage, installed_receipt, "prior install")
        return
    raise PromotionRecoveryError("cannot verify an ambiguous promotion layout")


def _is_commit_retirement_layout(
    payload: dict[str, object],
    stage: Path,
    install: Path,
) -> bool:
    staged = payload["staged"]
    installed = payload["installed"]
    if not isinstance(staged, dict) or not isinstance(installed, dict):
        return False
    retirement = retirement_state_path(stage)
    stage_now = _optional_directory_identity(stage, "prior install stage")
    retirement_now = _optional_directory_identity(
        retirement,
        "prior install retirement stage",
    )
    install_now = _optional_directory_identity(install, "committed install")
    return (
        stage_now is None
        and (retirement_now is None or _same_identity(retirement_now, installed))
        and install_now is not None
        and _same_identity(install_now, staged)
    )


def _is_recovery_retirement_layout(
    payload: dict[str, object],
    stage: Path,
    install: Path,
) -> bool:
    staged = payload["staged"]
    installed = payload["installed"]
    assert isinstance(staged, dict)
    assert installed is None or isinstance(installed, dict)
    retirement = retirement_state_path(stage)
    stage_now = _optional_directory_identity(stage, "rejected install stage")
    retirement_now = _optional_directory_identity(
        retirement,
        "rejected install retirement stage",
    )
    install_now = _optional_directory_identity(install, "recovered install")
    if stage_now is not None or (
        retirement_now is not None and not _same_identity(retirement_now, staged)
    ):
        return False
    if installed is None:
        return install_now is None
    return install_now is not None and _same_identity(install_now, installed)


def _reverse_existing_promotion(
    payload: dict[str, object],
    stage: Path,
    install: Path,
) -> None:
    parent = payload["parent"]
    staged = payload["staged"]
    installed = payload["installed"]
    assert isinstance(parent, dict)
    assert isinstance(staged, dict)
    assert isinstance(installed, dict)

    promote(
        stage,
        install,
        expected_parent_identity=parent,
        expected_stage_identity=installed,
        expected_install_identity=staged,
    )
    try:
        if _layout(payload, stage, install) != "prepared":
            raise PromotionRecoveryError(
                "reverse promotion returned with an ambiguous install state"
            )
        _verify_layout_receipts(payload, stage, install, "prepared")
    except BaseException as verification_error:
        try:
            if _layout(payload, stage, install) != "prepared":
                raise PromotionRecoveryError(
                    "cannot restore the promoted layout after failed verification"
                )
            promote(
                stage,
                install,
                expected_parent_identity=parent,
                expected_stage_identity=staged,
                expected_install_identity=installed,
            )
            if _layout(payload, stage, install) != "promoted":
                raise PromotionRecoveryError(
                    "restoring the promoted layout returned an ambiguous state"
                )
            _verify_tree_receipt(
                install,
                payload["staged_tree_receipt"],
                "restored promoted install",
            )
        except BaseException as rollback_error:
            raise PromotionRecoveryError(
                "reverse promotion verification failed and the prior promoted "
                f"layout could not be restored: {rollback_error}"
            ) from rollback_error
        raise verification_error


def _rename_exclusive_at(parent: int, source: str, destination: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameatx = libc.renameatx_np
    except AttributeError as error:
        raise PromotionRecoveryError(
            "exclusive no-replace rename is unavailable on this platform"
        ) from error
    renameatx.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameatx.restype = ctypes.c_int
    result = renameatx(
        parent,
        os.fsencode(source),
        parent,
        os.fsencode(destination),
        RENAME_EXCL,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), f"{source} -> {destination}")


def _swap_entries_at(parent: int, left: str, right: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameatx = libc.renameatx_np
    except AttributeError as error:
        raise PromotionRecoveryError(
            "atomic directory swap is unavailable on this platform"
        ) from error
    renameatx.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameatx.restype = ctypes.c_int
    result = renameatx(
        parent,
        os.fsencode(left),
        parent,
        os.fsencode(right),
        RENAME_SWAP,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), f"{left} <-> {right}")


def _restore_claimed_entry(parent: int, claimed: str, original: str) -> None:
    try:
        _rename_exclusive_at(parent, claimed, original)
    except OSError as error:
        raise PromotionRecoveryError(
            "could not restore an identity-bound cleanup entry; preserved as "
            f"{claimed}: {error}"
        ) from error


def _claim_entry(
    parent: int,
    name: str,
    expected: os.stat_result,
) -> tuple[str, os.stat_result]:
    for _ in range(128):
        claimed = f".easysplat-remove.{os.getpid()}.{secrets.token_hex(12)}"
        try:
            _rename_exclusive_at(parent, name, claimed)
        except OSError as error:
            if error.errno == errno.EEXIST:
                continue
            raise PromotionRecoveryError(
                f"could not claim cleanup entry without following it: {name}"
            ) from error
        try:
            actual = os.stat(claimed, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise PromotionRecoveryError(
                f"claimed cleanup entry disappeared: {claimed}"
            ) from error
        if not _same_stat_identity(expected, actual):
            _restore_claimed_entry(parent, claimed, name)
            raise PromotionRecoveryError(
                f"refusing to remove replacement cleanup entry: {name}"
            )
        return claimed, actual
    raise PromotionRecoveryError("could not reserve an identity-bound cleanup name")


def _remove_directory_contents(
    descriptor: int,
    *,
    allow_symlinks: bool,
) -> None:
    for name in sorted(os.listdir(descriptor), key=os.fsencode):
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        claimed, claimed_metadata = _claim_entry(descriptor, name, before)
        remove_succeeded = False
        try:
            if stat.S_ISDIR(claimed_metadata.st_mode):
                child = os.open(claimed, DIRECTORY_OPEN_FLAGS, dir_fd=descriptor)
                try:
                    opened = os.fstat(child)
                    named = os.stat(
                        claimed,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    if not stat.S_ISDIR(opened.st_mode) or not _same_metadata(
                        claimed_metadata, opened, named
                    ):
                        raise PromotionRecoveryError(
                            f"claimed cleanup directory changed: {name}"
                        )
                    _remove_directory_contents(
                        child,
                        allow_symlinks=allow_symlinks,
                    )
                    after = os.fstat(child)
                    named_after = os.stat(
                        claimed,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    if (
                        not stat.S_ISDIR(after.st_mode)
                        or not _same_stat_identity(opened, after)
                        or not _same_stat_identity(opened, named_after)
                    ):
                        raise PromotionRecoveryError(
                            f"claimed cleanup directory was replaced: {name}"
                        )
                finally:
                    os.close(child)
                os.rmdir(claimed, dir_fd=descriptor)
            elif stat.S_ISREG(claimed_metadata.st_mode):
                opened_file = os.open(
                    claimed,
                    FILE_OPEN_FLAGS,
                    dir_fd=descriptor,
                )
                try:
                    opened = os.fstat(opened_file)
                    named = os.stat(
                        claimed,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    if not stat.S_ISREG(opened.st_mode) or not _same_metadata(
                        claimed_metadata, opened, named
                    ):
                        raise PromotionRecoveryError(
                            f"claimed cleanup file was replaced: {name}"
                        )
                finally:
                    os.close(opened_file)
                os.unlink(claimed, dir_fd=descriptor)
            elif stat.S_ISLNK(claimed_metadata.st_mode) and allow_symlinks:
                named = os.stat(
                    claimed,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if not _same_metadata(claimed_metadata, named):
                    raise PromotionRecoveryError(
                        f"claimed cleanup link was replaced: {name}"
                    )
                os.unlink(claimed, dir_fd=descriptor)
            else:
                raise PromotionRecoveryError(
                    f"refusing to remove unsupported cleanup entry: {name}"
                )
            remove_succeeded = True
        finally:
            if not remove_succeeded:
                try:
                    os.stat(claimed, dir_fd=descriptor, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    _restore_claimed_entry(descriptor, claimed, name)
    os.fsync(descriptor)


def _remove_expected_tree(
    path: Path,
    expected: dict[str, int],
    *,
    allow_symlinks: bool = False,
) -> None:
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    claimed = ""
    remove_succeeded = False
    try:
        try:
            before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise PromotionRecoveryError(
                f"refusing to remove missing or replaced cleanup path: {path}"
            ) from error
        if (
            not stat.S_ISDIR(before.st_mode)
            or before.st_dev != expected["device"]
            or before.st_ino != expected["inode"]
        ):
            raise PromotionRecoveryError(
                f"refusing to remove replacement at cleanup path: {path}"
            )
        claimed, claimed_metadata = _claim_entry(parent, path.name, before)
        directory = os.open(claimed, DIRECTORY_OPEN_FLAGS, dir_fd=parent)
        try:
            opened = os.fstat(directory)
            named = os.stat(claimed, dir_fd=parent, follow_symlinks=False)
            if not _same_metadata(claimed_metadata, opened, named):
                raise PromotionRecoveryError(
                    f"claimed cleanup root changed before removal: {path}"
                )
            _remove_directory_contents(
                directory,
                allow_symlinks=allow_symlinks,
            )
            after = os.fstat(directory)
            named_after = os.stat(
                claimed,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISDIR(after.st_mode)
                or not _same_stat_identity(opened, after)
                or not _same_stat_identity(opened, named_after)
            ):
                raise PromotionRecoveryError(
                    f"claimed cleanup root was replaced during removal: {path}"
                )
        finally:
            os.close(directory)
        os.rmdir(claimed, dir_fd=parent)
        remove_succeeded = True
        os.fsync(parent)
    finally:
        if claimed and not remove_succeeded:
            try:
                os.stat(claimed, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _restore_claimed_entry(parent, claimed, path.name)
                os.fsync(parent)
        os.close(parent)


def _descriptor_xattr_names(descriptor: int) -> set[bytes]:
    libc = ctypes.CDLL(None, use_errno=True)
    flistxattr = libc.flistxattr
    flistxattr.argtypes = (
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
    )
    flistxattr.restype = ctypes.c_ssize_t
    ctypes.set_errno(0)
    size = flistxattr(descriptor, None, 0, XATTR_SHOWCOMPRESSION)
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size == 0:
        return set()
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    actual = flistxattr(
        descriptor,
        buffer,
        size,
        XATTR_SHOWCOMPRESSION,
    )
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if actual != size:
        raise PromotionRecoveryError(
            "extended attribute names changed while binding private state"
        )
    return {
        name
        for name in bytes(buffer.raw[:actual]).split(b"\0")
        if name
    }


def _private_metadata_is_allowed(descriptor: int) -> bool:
    return _descriptor_xattr_names(descriptor).issubset(
        {b"com.apple.provenance"}
    )


def _after_private_promoter_validation(
    parent: int,
    original_name: str,
    directory: int,
) -> None:
    """Test seam after a claimed private promoter has been fully validated."""


def remove_private_promoter_tree(
    path: Path,
    device: int,
    inode: int,
    expected_digest: str,
) -> None:
    """Claim and remove only one exact, strictly validated private promoter."""

    if not re.fullmatch(r"promoter[.]stage[.][A-Za-z0-9]{6}", path.name):
        raise PromotionRecoveryError(
            f"private promoter cleanup name is ambiguous: {path}"
        )
    if not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
        raise ValueError("private promoter digest is malformed")

    expected = {"device": device, "inode": inode}
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    claimed_root = ""
    root_removed = False
    try:
        before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISDIR(before.st_mode)
            or before.st_dev != expected["device"]
            or before.st_ino != expected["inode"]
            or before.st_uid != os.getuid()
            or before.st_gid != os.getgid()
            or stat.S_IMODE(before.st_mode) != 0o700
            or before.st_flags != 0
        ):
            raise PromotionRecoveryError(
                f"private promoter root identity is invalid: {path}"
            )
        claimed_root, claimed_metadata = _claim_entry(
            parent,
            path.name,
            before,
        )
        directory = os.open(
            claimed_root,
            DIRECTORY_OPEN_FLAGS,
            dir_fd=parent,
        )
        try:
            opened = os.fstat(directory)
            named = os.stat(
                claimed_root,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISDIR(opened.st_mode)
                or not _same_metadata(claimed_metadata, opened, named)
                or not _private_metadata_is_allowed(directory)
            ):
                raise PromotionRecoveryError(
                    f"claimed private promoter root is invalid: {path}"
                )

            names = sorted(os.listdir(directory), key=os.fsencode)
            if names not in ([], ["atomic_swap_install.py"]):
                raise PromotionRecoveryError(
                    f"private promoter tree has unexpected entries: {path}"
                )

            if names:
                child_before = os.stat(
                    names[0],
                    dir_fd=directory,
                    follow_symlinks=False,
                )
                if (
                    not stat.S_ISREG(child_before.st_mode)
                    or child_before.st_nlink != 1
                    or child_before.st_uid != os.getuid()
                    or child_before.st_gid != os.getgid()
                    or stat.S_IMODE(child_before.st_mode) != 0o700
                    or child_before.st_flags != 0
                ):
                    raise PromotionRecoveryError(
                        f"private promoter executable is invalid: {path}"
                    )
                claimed_child, child_metadata = _claim_entry(
                    directory,
                    names[0],
                    child_before,
                )
                child_removed = False
                try:
                    child = os.open(
                        claimed_child,
                        FILE_OPEN_FLAGS,
                        dir_fd=directory,
                    )
                    try:
                        child_opened = os.fstat(child)
                        child_named = os.stat(
                            claimed_child,
                            dir_fd=directory,
                            follow_symlinks=False,
                        )
                        if (
                            not stat.S_ISREG(child_opened.st_mode)
                            or not _same_metadata(
                                child_metadata,
                                child_opened,
                                child_named,
                            )
                            or not _private_metadata_is_allowed(child)
                        ):
                            raise PromotionRecoveryError(
                                f"claimed private promoter executable is invalid: {path}"
                            )
                        digest = hashlib.sha256()
                        offset = 0
                        while offset < child_opened.st_size:
                            block = os.pread(
                                child,
                                min(
                                    TREE_READ_BLOCK_SIZE,
                                    child_opened.st_size - offset,
                                ),
                                offset,
                            )
                            if not block:
                                raise PromotionRecoveryError(
                                    "private promoter executable was truncated"
                                )
                            digest.update(block)
                            offset += len(block)
                        if (
                            os.pread(child, 1, child_opened.st_size)
                            or digest.hexdigest() != expected_digest
                        ):
                            raise PromotionRecoveryError(
                                f"private promoter executable digest changed: {path}"
                            )
                        _after_private_promoter_validation(
                            parent,
                            path.name,
                            directory,
                        )
                        child_after = os.fstat(child)
                        child_named_after = os.stat(
                            claimed_child,
                            dir_fd=directory,
                            follow_symlinks=False,
                        )
                        if (
                            not _same_metadata(
                                child_metadata,
                                child_opened,
                                child_after,
                                child_named_after,
                            )
                            or sorted(
                                os.listdir(directory),
                                key=os.fsencode,
                            )
                            != [claimed_child]
                        ):
                            raise PromotionRecoveryError(
                                f"private promoter changed after validation: {path}"
                            )
                    finally:
                        os.close(child)
                    os.unlink(claimed_child, dir_fd=directory)
                    child_removed = True
                    os.fsync(directory)
                finally:
                    if not child_removed:
                        try:
                            os.stat(
                                claimed_child,
                                dir_fd=directory,
                                follow_symlinks=False,
                            )
                        except FileNotFoundError:
                            pass
                        else:
                            _restore_claimed_entry(
                                directory,
                                claimed_child,
                                names[0],
                            )
            else:
                _after_private_promoter_validation(
                    parent,
                    path.name,
                    directory,
                )

            opened_after = os.fstat(directory)
            named_after = os.stat(
                claimed_root,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                os.listdir(directory)
                or not _same_stat_identity(opened, opened_after)
                or not _same_stat_identity(opened, named_after)
            ):
                raise PromotionRecoveryError(
                    f"private promoter changed during cleanup: {path}"
                )
        finally:
            os.close(directory)
        os.rmdir(claimed_root, dir_fd=parent)
        root_removed = True
        os.fsync(parent)
    finally:
        if claimed_root and not root_removed:
            try:
                os.stat(
                    claimed_root,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            else:
                _restore_claimed_entry(parent, claimed_root, path.name)
                os.fsync(parent)
        os.close(parent)


def remove_bound_build_lock(
    path: Path,
    device: int,
    inode: int,
    owner_pid: int,
) -> None:
    """Remove only the exact shlock file owned by this live builder."""

    if path.name != ".msplat-build.lock" or owner_pid <= 0:
        raise ValueError("native build lock cleanup request is invalid")
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    claimed = ""
    removed = False
    try:
        before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_dev != device
            or before.st_ino != inode
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_gid != os.getgid()
            or stat.S_IMODE(before.st_mode) != 0o644
            or before.st_flags != 0
        ):
            raise PromotionRecoveryError(
                f"native build lock identity is invalid: {path}"
            )
        claimed, claimed_metadata = _claim_entry(parent, path.name, before)
        descriptor = os.open(claimed, FILE_OPEN_FLAGS, dir_fd=parent)
        try:
            opened = os.fstat(descriptor)
            named = os.stat(claimed, dir_fd=parent, follow_symlinks=False)
            content = os.pread(descriptor, 64, 0)
            after = os.fstat(descriptor)
            named_after = os.stat(
                claimed,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if (
                not _same_metadata(
                    claimed_metadata,
                    opened,
                    named,
                    after,
                    named_after,
                )
                or content != f"{owner_pid}\n".encode("ascii")
                or not _private_metadata_is_allowed(descriptor)
            ):
                raise PromotionRecoveryError(
                    f"native build lock changed before release: {path}"
                )
        finally:
            os.close(descriptor)
        os.unlink(claimed, dir_fd=parent)
        removed = True
        os.fsync(parent)
    finally:
        if claimed and not removed:
            try:
                os.stat(claimed, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _restore_claimed_entry(parent, claimed, path.name)
                os.fsync(parent)
        os.close(parent)


def _remove_retirement_tree(
    path: Path,
    expected: dict[str, int],
    expected_parent: dict[str, int],
) -> None:
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    directory = -1
    try:
        parent_opened = os.fstat(parent)
        parent_named = path.parent.lstat()
        if (
            not _same_directory_binding(parent_opened, parent_named)
            or parent_opened.st_dev != expected_parent["device"]
            or parent_opened.st_ino != expected_parent["inode"]
        ):
            raise PromotionRecoveryError(
                f"promotion parent changed before retirement cleanup: {path.parent}"
            )
        before = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISDIR(before.st_mode)
            or before.st_dev != expected["device"]
            or before.st_ino != expected["inode"]
        ):
            raise PromotionRecoveryError(
                f"retirement tree identity changed before cleanup: {path}"
            )
        directory = os.open(path.name, DIRECTORY_OPEN_FLAGS, dir_fd=parent)
        opened = os.fstat(directory)
        named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(opened.st_mode) or not _same_metadata(
            before,
            opened,
            named,
        ):
            raise PromotionRecoveryError(
                f"retirement tree changed before cleanup: {path}"
            )
        _remove_directory_contents(directory, allow_symlinks=False)
        after = os.fstat(directory)
        named_after = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (
            not _same_stat_identity(opened, after)
            or not _same_stat_identity(opened, named_after)
            or list(os.listdir(directory))
        ):
            raise PromotionRecoveryError(
                f"retirement tree changed during cleanup: {path}"
            )
        os.rmdir(path.name, dir_fd=parent)
        _sync_bound_parent(parent)
    finally:
        if directory >= 0:
            os.close(directory)
        os.close(parent)


def _retire_expected_tree(
    stage: Path,
    expected: dict[str, int],
    expected_parent: dict[str, int],
) -> None:
    retirement = retirement_state_path(stage)
    parent = os.open(stage.parent, DIRECTORY_OPEN_FLAGS)
    try:
        parent_opened = os.fstat(parent)
        parent_named = stage.parent.lstat()
        if (
            not _same_directory_binding(parent_opened, parent_named)
            or parent_opened.st_dev != expected_parent["device"]
            or parent_opened.st_ino != expected_parent["inode"]
        ):
            raise PromotionRecoveryError(
                f"promotion parent changed before tree retirement: {stage.parent}"
            )
        try:
            stage_now = os.stat(stage.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            stage_now = None
        try:
            retirement_now = os.stat(
                retirement.name,
                dir_fd=parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            retirement_now = None

        if stage_now is not None:
            if (
                not stat.S_ISDIR(stage_now.st_mode)
                or stage_now.st_dev != expected["device"]
                or stage_now.st_ino != expected["inode"]
                or retirement_now is not None
            ):
                raise PromotionRecoveryError(
                    f"tree retirement names changed before claim: {stage}"
                )
            with blocked_termination_signals():
                _rename_exclusive_at(parent, stage.name, retirement.name)
                _sync_bound_parent(parent)
            stage_now = None
            retirement_now = os.stat(
                retirement.name,
                dir_fd=parent,
                follow_symlinks=False,
            )

        if stage_now is not None:
            raise PromotionRecoveryError(
                f"staged tree remained after retirement claim: {stage}"
            )
        if retirement_now is None:
            return
        if (
            not stat.S_ISDIR(retirement_now.st_mode)
            or retirement_now.st_dev != expected["device"]
            or retirement_now.st_ino != expected["inode"]
        ):
            raise PromotionRecoveryError(
                f"retirement tree identity changed after claim: {retirement}"
            )
    finally:
        os.close(parent)

    _remove_retirement_tree(retirement, expected, expected_parent)


def remove_owned_tree(
    path: Path,
    expected_device: int,
    expected_inode: int,
    *,
    allow_symlinks: bool,
) -> None:
    if (
        isinstance(expected_device, bool)
        or isinstance(expected_inode, bool)
        or expected_device < 0
        or expected_inode < 0
    ):
        raise ValueError("invalid cleanup tree identity")
    _remove_expected_tree(
        Path(path),
        {"device": expected_device, "inode": expected_inode},
        allow_symlinks=allow_symlinks,
    )


def _verify_terminal_namespace(
    parent: int,
    parent_path: Path,
    payload: dict[str, object],
    outcome: str,
) -> None:
    stage_name = str(payload["stage_name"])
    install_name = str(payload["install_name"])
    retirement_name = f"{stage_name}{RETIREMENT_SUFFIX}"
    staged = payload["staged"]
    installed = payload["installed"]
    assert isinstance(staged, dict)
    assert installed is None or isinstance(installed, dict)

    def verify_identities() -> None:
        for name, label in (
            (stage_name, "staged install"),
            (retirement_name, "retirement tree"),
        ):
            try:
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise PromotionRecoveryError(
                    f"{label} reappeared before transaction finalization"
                )

        try:
            install_now = os.stat(
                install_name,
                dir_fd=parent,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            install_now = None

        if outcome == "commit":
            if (
                install_now is None
                or not stat.S_ISDIR(install_now.st_mode)
                or install_now.st_dev != staged["device"]
                or install_now.st_ino != staged["inode"]
            ):
                raise PromotionRecoveryError(
                    "committed install changed before transaction finalization"
                )
            return

        if outcome != "recovery":
            raise ValueError("invalid transaction terminal outcome")
        if installed is None:
            if install_now is not None:
                raise PromotionRecoveryError(
                    "first install reappeared before recovery finalization"
                )
            return
        if (
            install_now is None
            or not stat.S_ISDIR(install_now.st_mode)
            or install_now.st_dev != installed["device"]
            or install_now.st_ino != installed["inode"]
        ):
            raise PromotionRecoveryError(
                "recovered install changed before transaction finalization"
            )

    verify_identities()
    if outcome == "commit":
        _verify_tree_receipt(
            parent_path / install_name,
            payload["staged_tree_receipt"],
            "committed install",
        )
    elif installed is not None:
        _verify_tree_receipt(
            parent_path / install_name,
            payload["installed_tree_receipt"],
            "recovered install",
        )
    verify_identities()


def _unlink_transaction(
    path: Path,
    expected: dict[str, int],
    expected_parent: dict[str, int],
    terminal_payload: dict[str, object],
    terminal_outcome: str,
) -> None:
    parent = os.open(path.parent, DIRECTORY_OPEN_FLAGS)
    claimed = ""
    canonical_name = ""
    finalization_name = ""
    moved_from_canonical = False
    remove_succeeded = False
    descriptor = -1
    try:
        parent_opened = os.fstat(parent)
        parent_named = path.parent.lstat()
        if (
            not _same_directory_binding(parent_opened, parent_named)
            or parent_opened.st_dev != expected_parent["device"]
            or parent_opened.st_ino != expected_parent["inode"]
        ):
            raise PromotionRecoveryError(
                f"promotion transaction parent changed before removal: {path.parent}"
            )
        named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(named.st_mode)
            or named.st_nlink != 1
            or (named.st_dev, named.st_ino) != (expected["device"], expected["inode"])
        ):
            raise PromotionRecoveryError(
                f"promotion transaction was replaced before removal: {path}"
            )
        stage_name = _require_simple_name(
            terminal_payload["stage_name"],
            "stage name",
        )
        canonical_name = f"{stage_name}{TRANSACTION_SUFFIX}"
        finalization_name = f"{stage_name}{FINALIZATION_MARKER}{TRANSACTION_SUFFIX}"
        if path.name == finalization_name:
            claimed = path.name
            claimed_metadata = named
        elif path.name == canonical_name:
            _rename_exclusive_at(
                parent,
                canonical_name,
                finalization_name,
            )
            _sync_bound_parent(parent)
            moved_from_canonical = True
            claimed = finalization_name
            claimed_metadata = os.stat(
                claimed,
                dir_fd=parent,
                follow_symlinks=False,
            )
            if not _same_stat_identity(named, claimed_metadata):
                raise PromotionRecoveryError(
                    f"promotion transaction changed during finalization claim: {path}"
                )
        else:
            raise ValueError(f"invalid promotion transaction filename: {path}")

        def require_canonical_absent() -> None:
            try:
                os.stat(
                    canonical_name,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                return
            raise PromotionRecoveryError(
                "canonical promotion journal reappeared before finalization"
            )

        require_canonical_absent()
        descriptor = os.open(claimed, FILE_OPEN_FLAGS, dir_fd=parent)
        opened = os.fstat(descriptor)
        claimed_named = os.stat(
            claimed,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if not stat.S_ISREG(opened.st_mode) or not _same_metadata(
            claimed_metadata,
            opened,
            claimed_named,
        ):
            raise PromotionRecoveryError(
                f"promotion transaction changed before removal: {path}"
            )
        _verify_terminal_namespace(
            parent,
            path.parent,
            terminal_payload,
            terminal_outcome,
        )
        require_canonical_absent()
        parent_before_unlink = os.fstat(parent)
        parent_named_before_unlink = path.parent.lstat()
        if not _same_directory_binding(
            parent_opened,
            parent_before_unlink,
            parent_named_before_unlink,
        ):
            raise PromotionRecoveryError(
                "promotion transaction parent changed before final unlink"
            )
        opened_before_unlink = os.fstat(descriptor)
        claimed_before_unlink = os.stat(
            claimed,
            dir_fd=parent,
            follow_symlinks=False,
        )
        if not _same_metadata(
            claimed_metadata,
            opened,
            opened_before_unlink,
            claimed_before_unlink,
        ):
            raise PromotionRecoveryError(
                f"promotion transaction changed during final validation: {path}"
            )
        os.unlink(claimed, dir_fd=parent)
        remove_succeeded = True
        for name in (canonical_name, finalization_name):
            try:
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise PromotionRecoveryError(
                    f"promotion transaction replacement was preserved: {name}"
                )
        os.fsync(parent)
        parent_after = os.fstat(parent)
        parent_named_after = path.parent.lstat()
        if not _same_directory_binding(
            parent_opened,
            parent_after,
            parent_named_after,
        ):
            raise PromotionRecoveryError(
                f"promotion transaction parent changed during removal: {path.parent}"
            )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if claimed and not remove_succeeded:
            try:
                claimed_now = os.stat(
                    claimed,
                    dir_fd=parent,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            else:
                if moved_from_canonical and _same_stat_identity(
                    claimed_metadata,
                    claimed_now,
                ):
                    try:
                        os.stat(
                            canonical_name,
                            dir_fd=parent,
                            follow_symlinks=False,
                        )
                    except FileNotFoundError:
                        _rename_exclusive_at(
                            parent,
                            claimed,
                            canonical_name,
                        )
                        os.fsync(parent)
        os.close(parent)


_UNSET_IDENTITY = object()


def promote(
    stage: Path,
    install: Path,
    *,
    expected_parent_identity: dict[str, int] | None = None,
    expected_stage_identity: dict[str, int] | None = None,
    expected_install_identity: dict[str, int] | None | object = _UNSET_IDENTITY,
) -> None:
    require_directory(stage, "staged install")
    parent = stage.parent.resolve(strict=True)
    if install.parent.resolve(strict=True) != parent:
        raise ValueError("stage and install must have the same parent directory")
    if install.is_symlink():
        raise ValueError(f"install path is a symlink: {install}")

    sync_tree(stage)
    parent_descriptor = os.open(parent, DIRECTORY_OPEN_FLAGS)
    try:
        parent_opened = os.fstat(parent_descriptor)
        parent_named = parent.lstat()
        if not _same_directory_binding(parent_opened, parent_named):
            raise PromotionRecoveryError("promotion parent changed before swap")
        if expected_parent_identity is not None:
            expected_parent = _parse_identity(
                expected_parent_identity,
                "parent",
            )
            if (
                parent_opened.st_dev != expected_parent["device"]
                or parent_opened.st_ino != expected_parent["inode"]
            ):
                raise PromotionRecoveryError("promotion parent identity changed")

        staged_named = os.stat(
            stage.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if not stat.S_ISDIR(staged_named.st_mode):
            raise PromotionRecoveryError("staged install changed before swap")
        staged_identity = (
            directory_identity(stage, "staged install")
            if expected_stage_identity is None
            else _parse_identity(expected_stage_identity, "staged")
        )
        if (
            staged_named.st_dev != staged_identity["device"]
            or staged_named.st_ino != staged_identity["inode"]
        ):
            raise PromotionRecoveryError("staged install identity changed before swap")

        try:
            installed_named = os.stat(
                install.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            installed_named = None
        if expected_install_identity is _UNSET_IDENTITY:
            installed_identity = (
                None
                if installed_named is None
                else {
                    "device": installed_named.st_dev,
                    "inode": installed_named.st_ino,
                }
            )
        else:
            installed_identity = (
                None
                if expected_install_identity is None
                else _parse_identity(expected_install_identity, "installed")
            )
        if installed_identity is None:
            if installed_named is not None:
                raise PromotionRecoveryError("install appeared before promotion")
        elif (
            installed_named is None
            or not stat.S_ISDIR(installed_named.st_mode)
            or installed_named.st_dev != installed_identity["device"]
            or installed_named.st_ino != installed_identity["inode"]
        ):
            raise PromotionRecoveryError("current install changed before swap")

        with blocked_termination_signals():
            if installed_identity is None:
                try:
                    _rename_exclusive_at(
                        parent_descriptor,
                        stage.name,
                        install.name,
                    )
                    _sync_bound_parent(parent_descriptor)
                    installed_now = os.stat(
                        install.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    parent_after = os.fstat(parent_descriptor)
                    parent_named_after = parent.lstat()
                    if (
                        installed_now.st_dev != staged_identity["device"]
                        or installed_now.st_ino != staged_identity["inode"]
                        or not _same_directory_binding(
                            parent_opened,
                            parent_after,
                            parent_named_after,
                        )
                    ):
                        raise PromotionRecoveryError(
                            "promotion identity changed after rename"
                        )
                except BaseException as promotion_error:
                    try:
                        installed_now = os.stat(
                            install.name,
                            dir_fd=parent_descriptor,
                            follow_symlinks=False,
                        )
                    except FileNotFoundError as rollback_error:
                        raise PromotionRecoveryError(
                            "promotion failed and the promoted tree disappeared "
                            "before rollback"
                        ) from rollback_error
                    if (
                        installed_now.st_dev != staged_identity["device"]
                        or installed_now.st_ino != staged_identity["inode"]
                    ):
                        raise PromotionRecoveryError(
                            "promotion failed and the promoted tree was replaced "
                            "before rollback"
                        ) from promotion_error
                    try:
                        try:
                            os.stat(
                                stage.name,
                                dir_fd=parent_descriptor,
                                follow_symlinks=False,
                            )
                        except FileNotFoundError:
                            pass
                        else:
                            raise PromotionRecoveryError(
                                "promotion rollback destination appeared"
                            )
                        parent_before_rollback = os.fstat(parent_descriptor)
                        parent_named_before_rollback = parent.lstat()
                        if not _same_directory_binding(
                            parent_opened,
                            parent_before_rollback,
                            parent_named_before_rollback,
                        ):
                            raise PromotionRecoveryError(
                                "promotion parent changed before rollback"
                            )
                        _rename_exclusive_at(
                            parent_descriptor,
                            install.name,
                            stage.name,
                        )
                        _sync_bound_parent(parent_descriptor)
                        staged_after_rollback = os.stat(
                            stage.name,
                            dir_fd=parent_descriptor,
                            follow_symlinks=False,
                        )
                        try:
                            os.stat(
                                install.name,
                                dir_fd=parent_descriptor,
                                follow_symlinks=False,
                            )
                        except FileNotFoundError:
                            pass
                        else:
                            raise PromotionRecoveryError(
                                "promotion rollback source remained present"
                            )
                        parent_after_rollback = os.fstat(parent_descriptor)
                        parent_named_after_rollback = parent.lstat()
                        if (
                            staged_after_rollback.st_dev != staged_identity["device"]
                            or staged_after_rollback.st_ino != staged_identity["inode"]
                            or not _same_directory_binding(
                                parent_opened,
                                parent_after_rollback,
                                parent_named_after_rollback,
                            )
                        ):
                            raise PromotionRecoveryError(
                                "promotion rollback identity verification failed"
                            )
                    except BaseException as rollback_error:
                        raise PromotionRecoveryError(
                            "promotion failed; rollback or rollback durability failed: "
                            f"{rollback_error}"
                        ) from rollback_error
                    raise promotion_error
                return

            _swap_entries_at(parent_descriptor, stage.name, install.name)
            try:
                _sync_bound_parent(parent_descriptor)
                installed_now = os.stat(
                    install.name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                staged_now = os.stat(
                    stage.name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                parent_after = os.fstat(parent_descriptor)
                parent_named_after = parent.lstat()
                if (
                    installed_now.st_dev != staged_identity["device"]
                    or installed_now.st_ino != staged_identity["inode"]
                    or staged_now.st_dev != installed_identity["device"]
                    or staged_now.st_ino != installed_identity["inode"]
                    or not _same_directory_binding(
                        parent_opened,
                        parent_after,
                        parent_named_after,
                    )
                ):
                    raise PromotionRecoveryError(
                        "promotion identity changed after swap"
                    )
            except BaseException as promotion_error:
                try:
                    installed_before_rollback = os.stat(
                        install.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    staged_before_rollback = os.stat(
                        stage.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    parent_before_rollback = os.fstat(parent_descriptor)
                    parent_named_before_rollback = parent.lstat()
                    if (
                        installed_before_rollback.st_dev != staged_identity["device"]
                        or installed_before_rollback.st_ino != staged_identity["inode"]
                        or staged_before_rollback.st_dev != installed_identity["device"]
                        or staged_before_rollback.st_ino != installed_identity["inode"]
                        or not _same_directory_binding(
                            parent_opened,
                            parent_before_rollback,
                            parent_named_before_rollback,
                        )
                    ):
                        raise PromotionRecoveryError(
                            "promotion paths changed before rollback"
                        )
                    _swap_entries_at(parent_descriptor, stage.name, install.name)
                    _sync_bound_parent(parent_descriptor)
                    installed_after_rollback = os.stat(
                        install.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    staged_after_rollback = os.stat(
                        stage.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    parent_after_rollback = os.fstat(parent_descriptor)
                    parent_named_after_rollback = parent.lstat()
                    if (
                        installed_after_rollback.st_dev != installed_identity["device"]
                        or installed_after_rollback.st_ino
                        != installed_identity["inode"]
                        or staged_after_rollback.st_dev != staged_identity["device"]
                        or staged_after_rollback.st_ino != staged_identity["inode"]
                        or not _same_directory_binding(
                            parent_opened,
                            parent_after_rollback,
                            parent_named_after_rollback,
                        )
                    ):
                        raise PromotionRecoveryError(
                            "promotion rollback identity verification failed"
                        )
                except BaseException as rollback_error:
                    raise PromotionRecoveryError(
                        "promotion failed; rollback or rollback durability failed: "
                        f"{rollback_error}"
                    ) from rollback_error
                raise promotion_error
    finally:
        os.close(parent_descriptor)


def begin_transaction(
    stage: Path,
    install: Path,
    expected_stage_receipt: str,
) -> Path:
    journal = transaction_state_path(stage)
    payload = _transaction_payload(stage, install, expected_stage_receipt)
    _write_transaction(journal, payload)
    layout = _layout(payload, stage, install)
    if layout != "prepared":
        raise PromotionRecoveryError("promotion paths changed before the swap")
    _verify_layout_receipts(payload, stage, install, layout)
    staged_identity = payload["staged"]
    parent_identity = payload["parent"]
    installed_identity = payload["installed"]
    assert isinstance(staged_identity, dict)
    assert isinstance(parent_identity, dict)
    assert installed_identity is None or isinstance(installed_identity, dict)
    promote(
        stage,
        install,
        expected_parent_identity=parent_identity,
        expected_stage_identity=staged_identity,
        expected_install_identity=installed_identity,
    )
    layout = _layout(payload, stage, install)
    if layout != "promoted":
        raise PromotionRecoveryError(
            f"promotion returned with an ambiguous install state: {journal}"
        )
    _verify_layout_receipts(payload, stage, install, layout)
    return journal


def commit_transaction(journal: Path) -> None:
    payload, journal_identity = _read_transaction(journal)
    if _transaction_receipt_generation(payload) != "current":
        raise PromotionRecoveryError(
            "legacy promotion journals may only be rolled back"
        )
    stage, install = _transaction_paths(journal, payload)
    parent = payload["parent"]
    staged = payload["staged"]
    installed = payload["installed"]
    assert isinstance(parent, dict)
    assert isinstance(staged, dict)
    assert installed is None or isinstance(installed, dict)

    layout = _layout(payload, stage, install)
    if installed is None:
        if layout != "promoted":
            raise PromotionRecoveryError(
                f"cannot commit an ambiguous promotion transaction: {journal}"
            )
        _verify_layout_receipts(payload, stage, install, layout)
        if _layout(payload, stage, install) != "promoted":
            raise PromotionRecoveryError(
                f"first install changed before transaction finalization: {journal}"
            )
        _unlink_transaction(
            journal,
            journal_identity,
            parent,
            payload,
            "commit",
        )
        return

    if layout == "promoted":
        _verify_layout_receipts(payload, stage, install, layout)
    elif not _is_commit_retirement_layout(payload, stage, install):
        raise PromotionRecoveryError(
            f"cannot commit an ambiguous promotion transaction: {journal}"
        )
    _verify_tree_receipt(
        install,
        payload["staged_tree_receipt"],
        "committed install",
    )
    _retire_expected_tree(stage, installed, parent)
    if not _is_commit_retirement_layout(payload, stage, install):
        raise PromotionRecoveryError(
            f"committed install changed while retiring prior tree: {journal}"
        )
    _verify_tree_receipt(
        install,
        payload["staged_tree_receipt"],
        "committed install",
    )
    if not _is_commit_retirement_layout(payload, stage, install):
        raise PromotionRecoveryError(
            f"committed install changed before transaction finalization: {journal}"
        )
    _unlink_transaction(
        journal,
        journal_identity,
        parent,
        payload,
        "commit",
    )


def recover_transaction(journal: Path) -> None:
    payload, journal_identity = _read_transaction(journal)
    generation = _transaction_receipt_generation(payload)
    stage, install = _transaction_paths(journal, payload)
    parent = payload["parent"]
    staged = payload["staged"]
    installed = payload["installed"]
    assert isinstance(parent, dict)
    assert isinstance(staged, dict)
    assert installed is None or isinstance(installed, dict)

    is_finalization_journal = journal.name == transaction_finalization_path(stage).name
    if (
        is_finalization_journal
        and generation == "current"
        and installed is None
        and _layout(payload, stage, install) == "promoted"
    ):
        _verify_layout_receipts(payload, stage, install, "promoted")
        if _layout(payload, stage, install) != "promoted":
            raise PromotionRecoveryError(
                f"first install changed during finalization recovery: {journal}"
            )
        _unlink_transaction(
            journal,
            journal_identity,
            parent,
            payload,
            "commit",
        )
        return

    if generation == "current" and _is_commit_retirement_layout(
        payload,
        stage,
        install,
    ):
        assert isinstance(installed, dict)
        _verify_tree_receipt(
            install,
            payload["staged_tree_receipt"],
            "committed install",
        )
        _retire_expected_tree(stage, installed, parent)
        if not _is_commit_retirement_layout(payload, stage, install):
            raise PromotionRecoveryError(
                f"committed install changed during recovery: {journal}"
            )
        _verify_tree_receipt(
            install,
            payload["staged_tree_receipt"],
            "committed install",
        )
        if not _is_commit_retirement_layout(payload, stage, install):
            raise PromotionRecoveryError(
                f"committed install changed before recovery finalization: {journal}"
            )
        _unlink_transaction(
            journal,
            journal_identity,
            parent,
            payload,
            "commit",
        )
        return

    if _is_recovery_retirement_layout(payload, stage, install):
        if installed is not None:
            _verify_tree_receipt(
                install,
                payload["installed_tree_receipt"],
                "recovered install",
            )
        _retire_expected_tree(stage, staged, parent)
        if not _is_recovery_retirement_layout(payload, stage, install):
            raise PromotionRecoveryError(
                f"recovered install changed during staged cleanup: {journal}"
            )
        if installed is not None:
            _verify_tree_receipt(
                install,
                payload["installed_tree_receipt"],
                "recovered install",
            )
        if not _is_recovery_retirement_layout(payload, stage, install):
            raise PromotionRecoveryError(
                f"recovered install changed before transaction finalization: {journal}"
            )
        _unlink_transaction(
            journal,
            journal_identity,
            parent,
            payload,
            "recovery",
        )
        return

    layout = _layout(payload, stage, install)
    if layout == "promoted":
        _verify_layout_receipts(payload, stage, install, layout)
        with blocked_termination_signals():
            if installed is None:
                promote(
                    install,
                    stage,
                    expected_parent_identity=parent,
                    expected_stage_identity=staged,
                    expected_install_identity=None,
                )
            else:
                _reverse_existing_promotion(payload, stage, install)
        layout = _layout(payload, stage, install)
    if layout != "prepared":
        raise PromotionRecoveryError(
            f"ambiguous promotion state requires manual recovery: {journal}"
        )
    _verify_layout_receipts(payload, stage, install, layout)
    _retire_expected_tree(stage, staged, parent)
    if not _is_recovery_retirement_layout(payload, stage, install):
        raise PromotionRecoveryError(
            f"recovered install changed while retiring staged tree: {journal}"
        )
    if installed is not None:
        _verify_tree_receipt(
            install,
            payload["installed_tree_receipt"],
            "recovered install",
        )
    if not _is_recovery_retirement_layout(payload, stage, install):
        raise PromotionRecoveryError(
            f"recovered install changed before transaction finalization: {journal}"
        )
    _unlink_transaction(
        journal,
        journal_identity,
        parent,
        payload,
        "recovery",
    )


def main() -> int:
    try:
        if len(sys.argv) in {3, 5} and sys.argv[1] == "--tree-receipt":
            expected = None
            if len(sys.argv) == 5:
                expected = {
                    "device": int(sys.argv[3]),
                    "inode": int(sys.argv[4]),
                }
            print(tree_receipt(Path(sys.argv[2]), expected))
        elif len(sys.argv) == 3 and sys.argv[1] == "--create-owned-tree":
            identity = create_owned_tree(Path(sys.argv[2]))
            print(f"{identity['device']}:{identity['inode']}")
        elif (
            len(sys.argv) == 6
            and sys.argv[1] == "--remove-private-promoter-tree"
        ):
            remove_private_promoter_tree(
                Path(sys.argv[2]),
                int(sys.argv[3]),
                int(sys.argv[4]),
                sys.argv[5],
            )
        elif (
            len(sys.argv) == 6
            and sys.argv[1] == "--remove-bound-build-lock"
        ):
            remove_bound_build_lock(
                Path(sys.argv[2]),
                int(sys.argv[3]),
                int(sys.argv[4]),
                int(sys.argv[5]),
            )
        elif len(sys.argv) == 6 and sys.argv[1] == "--remove-owned-tree":
            if sys.argv[5] != "--allow-symlinks":
                raise ValueError("owned-tree cleanup mode is invalid")
            remove_owned_tree(
                Path(sys.argv[2]),
                int(sys.argv[3]),
                int(sys.argv[4]),
                allow_symlinks=True,
            )
        elif len(sys.argv) == 3 and sys.argv[1] == "--commit":
            commit_transaction(Path(sys.argv[2]))
        elif len(sys.argv) == 3 and sys.argv[1] == "--recover":
            recover_transaction(Path(sys.argv[2]))
        elif len(sys.argv) == 4 and not sys.argv[1].startswith("--"):
            begin_transaction(
                Path(sys.argv[1]),
                Path(sys.argv[2]),
                sys.argv[3],
            )
        else:
            print(
                "usage: atomic_swap_install.py --tree-receipt <stage> "
                "[<device> <inode>] | "
                "--create-owned-tree <path> | "
                "<stage> <install> <tree-receipt> | --commit <transaction> | "
                "--recover <transaction> | --remove-owned-tree <path> "
                "<device> <inode> --allow-symlinks | "
                "--remove-private-promoter-tree <path> <device> <inode> "
                "<sha256> | --remove-bound-build-lock <path> <device> "
                "<inode> <pid>",
                file=sys.stderr,
            )
            return 2
    except (OSError, ValueError) as error:
        print(f"atomic promotion failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
