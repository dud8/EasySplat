#!/usr/bin/env python3
"""Create and verify a private mixed-input staging generation.

Verification proves the descriptor-bound generation observed during the call.
It does not make the published directory immutable after return. The output
parent is owner-private; concurrent namespace mutation by another process with
the same effective user ID is outside this local benchmark tool's trust model.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import resource
import secrets
import stat
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


SCHEMA_VERSION = 1
MANIFEST_NAME = "staging_manifest.json"
MANIFEST_KIND = "easysplat-private-mixed-input-staging"
TEMPORARY_PREFIX = ".easysplat-mixed-stage-"
MAXIMUM_DESCRIPTOR_BYTES = 4 * 1024 * 1024
MAXIMUM_SOURCE_FILE_BYTES = 32 * 1024 * 1024 * 1024
MAXIMUM_SOURCE_CLOSURE_BYTES = 64 * 1024 * 1024 * 1024
MAXIMUM_ENTRY_COUNT = 512
DESCRIPTOR_HEADROOM = 32
CANONICAL_TIMESTAMP_SECONDS = 978_307_200
CANONICAL_TIMESTAMP_NS = CANONICAL_TIMESTAMP_SECONDS * 1_000_000_000
# macOS regenerates this process-provenance marker after a successful removal.
# It is system-owned, not copied user metadata; every other xattr is forbidden.
SYSTEM_MANAGED_XATTRS = frozenset({b"com.apple.provenance"})
SUPPORTED_PHOTO_EXTENSIONS = frozenset(
    {
        ".arw",
        ".cr2",
        ".cr3",
        ".dng",
        ".heic",
        ".heif",
        ".jpg",
        ".jpeg",
        ".nef",
        ".orf",
        ".png",
        ".raf",
        ".rw2",
        ".tif",
        ".tiff",
    }
)
SUPPORTED_VIDEO_EXTENSIONS = frozenset({".m4v", ".mov", ".mp4"})


class StagingError(RuntimeError):
    pass


class _AttributeList(ctypes.Structure):
    _fields_ = [
        ("bitmap_count", ctypes.c_uint16),
        ("reserved", ctypes.c_uint16),
        ("common_attributes", ctypes.c_uint32),
        ("volume_attributes", ctypes.c_uint32),
        ("directory_attributes", ctypes.c_uint32),
        ("file_attributes", ctypes.c_uint32),
        ("fork_attributes", ctypes.c_uint32),
    ]


class _TimeSpec(ctypes.Structure):
    _fields_ = [("seconds", ctypes.c_long), ("nanoseconds", ctypes.c_long)]


@dataclass(frozen=True)
class _Metadata:
    device: int
    inode: int
    mode: int
    size: int
    mtime_ns: int
    ctime_ns: int
    link_count: int

    @classmethod
    def from_stat(cls, value: os.stat_result) -> _Metadata:
        return cls(
            device=value.st_dev,
            inode=value.st_ino,
            mode=value.st_mode,
            size=value.st_size,
            mtime_ns=value.st_mtime_ns,
            ctime_ns=value.st_ctime_ns,
            link_count=value.st_nlink,
        )


@dataclass(frozen=True)
class _FileSnapshot:
    metadata: _Metadata
    sha256: str


@dataclass(frozen=True)
class _SourceEntry:
    source_path: Path
    logical_relative_path: str
    media_type: str
    group_id: str


@dataclass(frozen=True)
class _StagedEntry:
    source: _SourceEntry
    source_snapshot: _FileSnapshot
    manifest_entry: dict[str, Any]


def _extended_attribute_names(descriptor: int) -> tuple[bytes, ...]:
    library = ctypes.CDLL(None, use_errno=True)
    lister = library.flistxattr
    lister.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    lister.restype = ctypes.c_ssize_t
    for _ in range(3):
        ctypes.set_errno(0)
        size = lister(descriptor, None, 0, 0x0020)
        if size < 0:
            error_number = ctypes.get_errno()
            raise StagingError(
                "extended attributes could not be inspected"
            ) from OSError(
                error_number,
                os.strerror(error_number),
            )
        if size == 0:
            return ()
        buffer = ctypes.create_string_buffer(size)
        ctypes.set_errno(0)
        result = lister(descriptor, buffer, size, 0x0020)
        if result == size:
            names = tuple(item for item in buffer.raw.split(b"\0") if item)
            if len(names) != len(set(names)):
                raise StagingError("extended attribute names are invalid")
            return names
        if result < 0 and ctypes.get_errno() == errno.ERANGE:
            continue
        error_number = ctypes.get_errno()
        raise StagingError(
            "extended attributes changed during inspection"
        ) from OSError(
            error_number,
            os.strerror(error_number),
        )
    raise StagingError("extended attributes changed during inspection")


def _strip_extended_attributes(descriptor: int) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    remover = library.fremovexattr
    remover.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    remover.restype = ctypes.c_int
    for name in _extended_attribute_names(descriptor):
        ctypes.set_errno(0)
        if remover(descriptor, name, 0) == 0:
            continue
        error_number = ctypes.get_errno()
        if name in SYSTEM_MANAGED_XATTRS and error_number in {
            errno.EPERM,
            errno.EACCES,
        }:
            continue
        raise StagingError(
            "staged extended attributes could not be removed"
        ) from OSError(
            error_number,
            os.strerror(error_number),
        )
    if set(_extended_attribute_names(descriptor)) - SYSTEM_MANAGED_XATTRS:
        raise StagingError("staged extended attributes remain")


def _has_extended_acl(descriptor: int) -> bool:
    library = ctypes.CDLL(None, use_errno=True)
    getter = library.acl_get_fd_np
    getter.argtypes = [ctypes.c_int, ctypes.c_int]
    getter.restype = ctypes.c_void_p
    ctypes.set_errno(0)
    acl = getter(descriptor, 0x00000100)
    if acl:
        freer = library.acl_free
        freer.argtypes = [ctypes.c_void_p]
        freer.restype = ctypes.c_int
        freer(ctypes.c_void_p(acl))
        return True
    error_number = ctypes.get_errno()
    if error_number in {0, errno.ENOENT}:
        return False
    raise StagingError("extended ACL could not be inspected") from OSError(
        error_number,
        os.strerror(error_number),
    )


def _strip_extended_acl(descriptor: int) -> None:
    if not _has_extended_acl(descriptor):
        return
    library = ctypes.CDLL(None, use_errno=True)
    initializer = library.acl_init
    initializer.argtypes = [ctypes.c_int]
    initializer.restype = ctypes.c_void_p
    ctypes.set_errno(0)
    empty_acl = initializer(0)
    if not empty_acl:
        error_number = ctypes.get_errno()
        raise StagingError("empty ACL could not be created") from OSError(
            error_number,
            os.strerror(error_number),
        )
    try:
        setter = library.acl_set_fd_np
        setter.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        setter.restype = ctypes.c_int
        ctypes.set_errno(0)
        if setter(descriptor, empty_acl, 0x00000100) != 0:
            error_number = ctypes.get_errno()
            raise StagingError("staged extended ACL could not be removed") from OSError(
                error_number,
                os.strerror(error_number),
            )
    finally:
        freer = library.acl_free
        freer.argtypes = [ctypes.c_void_p]
        freer.restype = ctypes.c_int
        freer(empty_acl)
    if _has_extended_acl(descriptor):
        raise StagingError("staged extended ACL remains")


def _clear_bsd_flags(descriptor: int) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    clear_flags = library.fchflags
    clear_flags.argtypes = [ctypes.c_int, ctypes.c_uint32]
    clear_flags.restype = ctypes.c_int
    ctypes.set_errno(0)
    if clear_flags(descriptor, 0) != 0:
        error_number = ctypes.get_errno()
        raise StagingError("staged BSD flags could not be removed") from OSError(
            error_number,
            os.strerror(error_number),
        )
    if os.fstat(descriptor).st_flags != 0:
        raise StagingError("staged BSD flags remain")


def _set_canonical_timestamps(descriptor: int) -> None:
    try:
        os.utime(
            descriptor,
            ns=(CANONICAL_TIMESTAMP_NS, CANONICAL_TIMESTAMP_NS),
        )
    except OSError as error:
        raise StagingError("staged timestamps could not be canonicalized") from error

    attributes = _AttributeList(5, 0, 0x00000200, 0, 0, 0, 0)
    timestamp = _TimeSpec(CANONICAL_TIMESTAMP_SECONDS, 0)
    library = ctypes.CDLL(None, use_errno=True)
    setter = library.fsetattrlist
    setter.argtypes = [
        ctypes.c_int,
        ctypes.POINTER(_AttributeList),
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint,
    ]
    setter.restype = ctypes.c_int
    ctypes.set_errno(0)
    if (
        setter(
            descriptor,
            ctypes.byref(attributes),
            ctypes.byref(timestamp),
            ctypes.sizeof(timestamp),
            0,
        )
        != 0
    ):
        error_number = ctypes.get_errno()
        raise StagingError("staged birthtime could not be canonicalized") from OSError(
            error_number,
            os.strerror(error_number),
        )


def _verify_canonical_metadata(
    descriptor: int,
    expected_mode: int,
    *,
    check_timestamps: bool = True,
) -> None:
    metadata = os.fstat(descriptor)
    if (
        metadata.st_uid != os.geteuid()
        or metadata.st_gid != os.getegid()
        or stat.S_IMODE(metadata.st_mode) != expected_mode
        or metadata.st_flags != 0
        or (
            check_timestamps
            and (
                metadata.st_mtime_ns != CANONICAL_TIMESTAMP_NS
                or metadata.st_birthtime != float(CANONICAL_TIMESTAMP_SECONDS)
            )
        )
    ):
        raise StagingError("staged metadata is not canonical")
    if _has_extended_acl(descriptor):
        raise StagingError("staged extended ACL remains")
    if set(_extended_attribute_names(descriptor)) - SYSTEM_MANAGED_XATTRS:
        raise StagingError("staged extended attributes remain")


def _canonicalize_staged_metadata(descriptor: int, expected_mode: int) -> None:
    metadata = os.fstat(descriptor)
    if metadata.st_uid != os.geteuid():
        raise StagingError("staged file ownership is unsafe")
    try:
        _clear_bsd_flags(descriptor)
        os.fchown(descriptor, os.geteuid(), os.getegid())
        _strip_extended_acl(descriptor)
        _strip_extended_attributes(descriptor)
        os.fchmod(descriptor, expected_mode)
        _set_canonical_timestamps(descriptor)
    except OSError as error:
        raise StagingError("staged metadata could not be canonicalized") from error
    _verify_canonical_metadata(descriptor, expected_mode)


def _ensure_descriptor_capacity(entry_count: int) -> None:
    try:
        open_descriptors = [
            int(name) for name in os.listdir("/dev/fd") if name.isdecimal()
        ]
    except OSError as error:
        raise StagingError("open descriptors could not be inspected") from error
    highest_open_descriptor = max(open_descriptors, default=2)
    required_limit = highest_open_descriptor + entry_count + 1 + DESCRIPTOR_HEADROOM
    soft_limit, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft_limit >= required_limit:
        return
    if hard_limit < required_limit:
        raise StagingError("process descriptor limit is below the staging contract")
    try:
        resource.setrlimit(
            resource.RLIMIT_NOFILE,
            (required_limit, hard_limit),
        )
    except (OSError, ValueError) as error:
        raise StagingError(
            "process descriptor limit could not be raised for verification"
        ) from error
    if resource.getrlimit(resource.RLIMIT_NOFILE)[0] < required_limit:
        raise StagingError(
            "process descriptor limit could not be raised for verification"
        )


def _canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def _sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise StagingError("descriptor contains a duplicate JSON key")
        result[key] = value
    return result


def _reject_nonfinite_json(value: str) -> None:
    raise StagingError(f"descriptor contains unsupported JSON value {value}")


def _decode_json(data: bytes) -> Any:
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
            parse_constant=_reject_nonfinite_json,
        )
    except StagingError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StagingError("descriptor is not valid UTF-8 JSON") from error


def _reject_symlink_ancestors(path: Path, label: str) -> None:
    absolute = Path(os.path.abspath(os.fspath(path)))
    ancestors = list(absolute.parents)
    for ancestor in reversed(ancestors[:-1]):
        try:
            metadata = os.lstat(ancestor)
        except OSError as error:
            raise StagingError(f"{label} is unavailable") from error
        if not stat.S_ISLNK(metadata.st_mode):
            continue
        try:
            parent_metadata = os.lstat(ancestor.parent)
        except OSError as error:
            raise StagingError(f"{label} is unavailable") from error
        immutable_system_alias = (
            metadata.st_uid == 0
            and parent_metadata.st_uid == 0
            and stat.S_IMODE(parent_metadata.st_mode) & 0o022 == 0
        )
        if not immutable_system_alias:
            raise StagingError(f"{label} contains a symlink component")


def _open_plain_directory(path: Path, label: str) -> int:
    _reject_symlink_ancestors(path, label)
    try:
        before = os.lstat(path)
    except OSError as error:
        raise StagingError(f"{label} must be a plain directory") from error
    if stat.S_ISLNK(before.st_mode):
        raise StagingError(f"{label} contains a symlink component")
    if not stat.S_ISDIR(before.st_mode):
        raise StagingError(f"{label} must be a plain directory")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise StagingError(f"{label} must be a plain directory") from error
    opened = os.fstat(descriptor)
    if not stat.S_ISDIR(opened.st_mode) or (before.st_dev, before.st_ino) != (
        opened.st_dev,
        opened.st_ino,
    ):
        os.close(descriptor)
        raise StagingError(f"{label} must be a plain directory")
    return descriptor


def _hash_descriptor(descriptor: int, *, maximum_bytes: int) -> _FileSnapshot:
    before = _Metadata.from_stat(os.fstat(descriptor))
    if not stat.S_ISREG(before.mode):
        raise StagingError("source is a special file")
    if before.link_count != 1:
        raise StagingError("source is a hardlink")
    if not 0 < before.size <= maximum_bytes:
        raise StagingError("source size is outside the supported boundary")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    byte_count = 0
    while True:
        chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - byte_count))
        if not chunk:
            break
        byte_count += len(chunk)
        if byte_count > maximum_bytes:
            raise StagingError("source size is outside the supported boundary")
        digest.update(chunk)
    after = _Metadata.from_stat(os.fstat(descriptor))
    if before != after or byte_count != before.size:
        raise StagingError("source changed during staging")
    return _FileSnapshot(after, "sha256:" + digest.hexdigest())


def _open_regular_source(path: Path) -> tuple[int, _Metadata]:
    _reject_symlink_ancestors(path, "source path")
    try:
        before_stat = os.lstat(path)
    except OSError as error:
        raise StagingError("source path is unavailable") from error
    before = _Metadata.from_stat(before_stat)
    if stat.S_ISLNK(before.mode):
        raise StagingError("source path is a symlink")
    if not stat.S_ISREG(before.mode):
        raise StagingError("source is a special file")
    if before.link_count != 1:
        raise StagingError("source is a hardlink")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise StagingError("source path is unavailable") from error
    opened = _Metadata.from_stat(os.fstat(descriptor))
    if opened != before:
        os.close(descriptor)
        raise StagingError("source changed before staging")
    return descriptor, opened


def _snapshot_plain_file(
    path: Path, *, maximum_bytes: int, label: str
) -> tuple[bytes, _FileSnapshot]:
    _reject_symlink_ancestors(path, label)
    try:
        before = _Metadata.from_stat(os.lstat(path))
    except OSError as error:
        raise StagingError(f"{label} is unavailable") from error
    if stat.S_ISLNK(before.mode):
        raise StagingError(f"{label} is a symlink")
    if not stat.S_ISREG(before.mode):
        raise StagingError(f"{label} must be a plain file")
    if before.link_count != 1:
        raise StagingError(f"{label} is a hardlink")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise StagingError(f"{label} is unavailable") from error
    try:
        opened = _Metadata.from_stat(os.fstat(descriptor))
        if opened != before:
            raise StagingError(f"{label} changed during read")
        snapshot = _hash_descriptor(descriptor, maximum_bytes=maximum_bytes)
        os.lseek(descriptor, 0, os.SEEK_SET)
        data = bytearray()
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > maximum_bytes:
                raise StagingError(f"{label} is too large")
        after = _Metadata.from_stat(os.fstat(descriptor))
        if after != snapshot.metadata or len(data) != snapshot.metadata.size:
            raise StagingError(f"{label} changed during read")
    finally:
        os.close(descriptor)
    try:
        path_after = _Metadata.from_stat(os.lstat(path))
    except OSError as error:
        raise StagingError(f"{label} changed during read") from error
    if path_after != snapshot.metadata:
        raise StagingError(f"{label} changed during read")
    return bytes(data), snapshot


def _validate_source_path(value: Any) -> Path:
    if not isinstance(value, str) or not value or "\0" in value:
        raise StagingError("entry source path is invalid")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise StagingError("entry source path is invalid") from error
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise StagingError("entry source path must be absolute and normalized")
    if any(part in {".", ".."} for part in Path(value).parts):
        raise StagingError("entry source path must not contain traversal")
    return Path(value)


def _validate_logical_name(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise StagingError("entry logical relative path is invalid")
    if (
        value in {".", "..", MANIFEST_NAME}
        or value.startswith(".")
        or "/" in value
        or "\\" in value
        or "\0" in value
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
    ):
        raise StagingError("entry logical relative path must be one safe filename")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise StagingError("entry logical relative path is invalid") from error
    if len(encoded) > 255:
        raise StagingError("entry logical relative path is too long")
    return value


def _validate_group_id(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= 64
        or not value[0].isalnum()
        or not value.isascii()
        or any(
            not (character.islower() or character.isdigit() or character in "_-")
            for character in value
        )
    ):
        raise StagingError("entry group ID is invalid")
    return value


def _validate_entry(value: Any) -> _SourceEntry:
    if not isinstance(value, dict) or set(value) != {
        "source_path",
        "logical_relative_path",
        "media_type",
        "group_id",
    }:
        raise StagingError("descriptor entry fields are invalid")
    source_path = _validate_source_path(value["source_path"])
    logical_name = _validate_logical_name(value["logical_relative_path"])
    media_type = value["media_type"]
    if media_type not in {"photo", "video"}:
        raise StagingError("entry media type is invalid")
    group_id = _validate_group_id(value["group_id"])
    allowed_extensions = (
        SUPPORTED_PHOTO_EXTENSIONS
        if media_type == "photo"
        else SUPPORTED_VIDEO_EXTENSIONS
    )
    if (
        source_path.suffix.lower() not in allowed_extensions
        or Path(logical_name).suffix.lower() not in allowed_extensions
    ):
        raise StagingError("entry media extension does not match its media type")
    if source_path.suffix.casefold() != Path(logical_name).suffix.casefold():
        raise StagingError("entry logical path must preserve its source suffix")
    return _SourceEntry(source_path, logical_name, media_type, group_id)


def _validated_descriptor(value: Any) -> list[_SourceEntry]:
    if not isinstance(value, dict) or set(value) != {"schema_version", "entries"}:
        raise StagingError("descriptor fields are invalid")
    if (
        type(value["schema_version"]) is not int
        or value["schema_version"] != SCHEMA_VERSION
    ):
        raise StagingError("descriptor schema version is invalid")
    raw_entries = value["entries"]
    if (
        not isinstance(raw_entries, list)
        or not 2 <= len(raw_entries) <= MAXIMUM_ENTRY_COUNT
    ):
        raise StagingError("descriptor must contain a bounded mixed input set")
    entries = [_validate_entry(item) for item in raw_entries]
    if {item.media_type for item in entries} != {"photo", "video"}:
        raise StagingError("descriptor must contain both photos and videos")
    logical_identities: set[str] = set()
    photo_groups: set[str] = set()
    video_groups: set[str] = set()
    for item in entries:
        logical_identity = unicodedata.normalize(
            "NFC", item.logical_relative_path
        ).casefold()
        if logical_identity in logical_identities:
            raise StagingError("descriptor contains an ambiguous logical basename")
        logical_identities.add(logical_identity)
        if item.media_type == "video":
            if item.group_id in video_groups:
                raise StagingError("descriptor contains a duplicate video group ID")
            video_groups.add(item.group_id)
        else:
            photo_groups.add(item.group_id)
    if len(photo_groups) != 1:
        raise StagingError("descriptor photos must share a single photo group")
    if not photo_groups.isdisjoint(video_groups):
        raise StagingError("descriptor photo group must be distinct from video groups")
    return sorted(entries, key=lambda item: item.logical_relative_path.encode("utf-8"))


def _descriptor_snapshot(path: Path) -> tuple[list[_SourceEntry], _FileSnapshot]:
    data, snapshot = _snapshot_plain_file(
        path,
        maximum_bytes=MAXIMUM_DESCRIPTOR_BYTES,
        label="source descriptor",
    )
    return _validated_descriptor(_decode_json(data)), snapshot


def _preflight_sources(
    entries: list[_SourceEntry],
) -> tuple[dict[str, _Metadata], int]:
    metadata_by_name: dict[str, _Metadata] = {}
    seen_identities: set[tuple[int, int]] = set()
    total_bytes = 0
    for item in entries:
        descriptor, metadata = _open_regular_source(item.source_path)
        os.close(descriptor)
        if not 0 < metadata.size <= MAXIMUM_SOURCE_FILE_BYTES:
            raise StagingError("source size is outside the supported boundary")
        identity = (metadata.device, metadata.inode)
        if identity in seen_identities:
            raise StagingError("descriptor contains a duplicate source identity")
        seen_identities.add(identity)
        total_bytes += metadata.size
        if total_bytes > MAXIMUM_SOURCE_CLOSURE_BYTES:
            raise StagingError("mixed input closure exceeds the supported size")
        metadata_by_name[item.logical_relative_path] = metadata
    return metadata_by_name, total_bytes


def _revalidate_preflight_sources(
    entries: list[_SourceEntry],
    metadata_by_name: dict[str, _Metadata],
) -> None:
    if set(metadata_by_name) != {item.logical_relative_path for item in entries}:
        raise StagingError("source preflight is incomplete")
    for item in entries:
        _revalidate_path(
            item.source_path,
            metadata_by_name[item.logical_relative_path],
            "source",
        )


def _revalidate_path(path: Path, expected: _Metadata, label: str) -> None:
    try:
        current = _Metadata.from_stat(os.lstat(path))
    except OSError as error:
        raise StagingError(f"{label} changed during staging") from error
    if current != expected:
        raise StagingError(f"{label} changed during staging")


def _rename_no_replace(
    source_directory_descriptor: int,
    source_name: str,
    destination_directory_descriptor: int,
    destination_name: str,
) -> None:
    for name in (source_name, destination_name):
        if (
            not name
            or name in {".", ".."}
            or "\0" in name
            or Path(name).name != name
        ):
            raise StagingError("exclusive rename requires a plain leaf name")
    try:
        renameatx_np = ctypes.CDLL(None, use_errno=True).renameatx_np
    except (AttributeError, OSError) as error:
        raise StagingError("exclusive rename is unavailable") from error
    renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx_np.restype = ctypes.c_int
    ctypes.set_errno(0)
    if (
        renameatx_np(
            source_directory_descriptor,
            os.fsencode(source_name),
            destination_directory_descriptor,
            os.fsencode(destination_name),
            0x00000004 | 0x00000010,
        )
        == 0
    ):
        return
    error_number = ctypes.get_errno()
    raise OSError(
        error_number,
        os.strerror(error_number),
        f"{source_name} -> {destination_name}",
    )


def _unlink_quarantined_name(
    directory_descriptor: int,
    name: str,
    *,
    directory: bool,
    expected_identity: tuple[int, int],
) -> None:
    # macOS has no compare-and-unlink operation. The unpredictable private
    # quarantine plus an immediate inode recheck is the ownership boundary;
    # these flags additionally reject symlinks and multiply linked files.
    try:
        current = os.stat(
            name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except OSError as error:
        raise StagingError("quarantine identity changed before removal") from error
    expected_type = (
        stat.S_ISDIR(current.st_mode) if directory else stat.S_ISREG(current.st_mode)
    )
    if (
        not expected_type
        or (current.st_dev, current.st_ino) != expected_identity
        or (not directory and current.st_nlink != 1)
    ):
        raise StagingError("quarantine identity changed before removal")
    flags = 0x00000800 | (0x00000080 if directory else 0x00008000)
    library = ctypes.CDLL(None, use_errno=True)
    unlinkat = library.unlinkat
    unlinkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    unlinkat.restype = ctypes.c_int
    ctypes.set_errno(0)
    if unlinkat(directory_descriptor, os.fsencode(name), flags) == 0:
        return
    error_number = ctypes.get_errno()
    raise OSError(error_number, os.strerror(error_number), name)


def _restore_quarantined_name(
    directory_descriptor: int,
    quarantine_name: str,
    original_name: str,
) -> None:
    try:
        _rename_no_replace(
            directory_descriptor,
            quarantine_name,
            directory_descriptor,
            original_name,
        )
    except (OSError, StagingError):
        pass


def _discard_owned_file(
    directory_descriptor: int,
    name: str,
    expected_identity: tuple[int, int],
) -> None:
    quarantine_name = TEMPORARY_PREFIX + "discard-" + secrets.token_hex(16)
    try:
        _rename_no_replace(
            directory_descriptor,
            name,
            directory_descriptor,
            quarantine_name,
        )
    except (OSError, StagingError):
        return
    should_restore = True
    descriptor: int | None = None
    try:
        moved = os.stat(
            quarantine_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(moved.st_mode)
            or (moved.st_dev, moved.st_ino) != expected_identity
        ):
            return
        descriptor = os.open(
            quarantine_name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_descriptor,
        )
        opened = os.fstat(descriptor)
        rebound = os.stat(
            quarantine_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != expected_identity
            or (rebound.st_dev, rebound.st_ino) != expected_identity
        ):
            return
        final = os.stat(
            quarantine_name,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
        if (final.st_dev, final.st_ino) != expected_identity:
            return
        _unlink_quarantined_name(
            directory_descriptor,
            quarantine_name,
            directory=False,
            expected_identity=expected_identity,
        )
        should_restore = False
    except (OSError, StagingError):
        pass
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if should_restore:
            _restore_quarantined_name(
                directory_descriptor,
                quarantine_name,
                name,
            )


def _copy_descriptor(
    source_descriptor: int,
    destination_directory_descriptor: int,
    destination_name: str,
) -> tuple[int, int]:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_CLOEXEC
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        destination = os.open(
            destination_name,
            flags,
            0o600,
            dir_fd=destination_directory_descriptor,
        )
    except OSError as error:
        raise StagingError("staging destination could not be created") from error
    created_metadata = os.fstat(destination)
    created_identity = (created_metadata.st_dev, created_metadata.st_ino)
    try:
        os.lseek(source_descriptor, 0, os.SEEK_SET)
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(destination, view)
                if written <= 0:
                    raise StagingError("staging copy made no progress")
                view = view[written:]
        _canonicalize_staged_metadata(destination, 0o600)
        os.fsync(destination)
        metadata = os.fstat(destination)
        return metadata.st_dev, metadata.st_ino
    except Exception:
        _discard_owned_file(
            destination_directory_descriptor,
            destination_name,
            created_identity,
        )
        raise
    finally:
        os.close(destination)


def _clone_or_copy(
    source_descriptor: int,
    destination_directory_descriptor: int,
    destination_name: str,
) -> tuple[int, int]:
    cloned = False
    try:
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        clonefile = library.fclonefileat
        clonefile.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
        ]
        clonefile.restype = ctypes.c_int
        ctypes.set_errno(0)
        if (
            clonefile(
                source_descriptor,
                destination_directory_descriptor,
                os.fsencode(destination_name),
                0,
            )
            == 0
        ):
            cloned = True
        else:
            error_number = ctypes.get_errno()
            if error_number not in {
                errno.ENOTSUP,
                errno.EOPNOTSUPP,
                errno.EXDEV,
                errno.EINVAL,
            }:
                raise OSError(error_number, os.strerror(error_number), destination_name)
    except (AttributeError, OSError) as error:
        if isinstance(error, OSError) and error.errno not in {
            None,
            errno.ENOTSUP,
            errno.EOPNOTSUPP,
            errno.EXDEV,
            errno.EINVAL,
        }:
            raise StagingError("staging clone failed") from error
    if not cloned:
        try:
            os.stat(
                destination_name,
                dir_fd=destination_directory_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return _copy_descriptor(
                source_descriptor,
                destination_directory_descriptor,
                destination_name,
            )
        except OSError as error:
            raise StagingError(
                "clone fallback destination could not be inspected"
            ) from error
        raise StagingError("clone fallback found an unowned destination")
    try:
        staged_descriptor = os.open(
            destination_name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=destination_directory_descriptor,
        )
    except OSError as error:
        raise StagingError("staged clone is unavailable") from error
    try:
        metadata = os.fstat(staged_descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            raise StagingError("staged clone is unsafe")
        staged_identity = (metadata.st_dev, metadata.st_ino)
        _canonicalize_staged_metadata(staged_descriptor, 0o600)
        os.fsync(staged_descriptor)
        rebound = os.stat(
            destination_name,
            dir_fd=destination_directory_descriptor,
            follow_symlinks=False,
        )
        if (rebound.st_dev, rebound.st_ino) != staged_identity:
            raise StagingError("staged clone identity changed")
        return staged_identity
    finally:
        os.close(staged_descriptor)


def _open_staged_file(
    directory_descriptor: int,
    name: str,
    expected_identity: tuple[int, int] | None = None,
) -> int:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise StagingError("staged file is unavailable") from error
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        os.close(descriptor)
        raise StagingError("staged file is unsafe")
    if (
        expected_identity is not None
        and (
            metadata.st_dev,
            metadata.st_ino,
        )
        != expected_identity
    ):
        os.close(descriptor)
        raise StagingError("staged file identity changed")
    try:
        _verify_canonical_metadata(descriptor, 0o600)
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def _stage_entry(
    item: _SourceEntry,
    expected_source_metadata: _Metadata,
    destination_directory_descriptor: int,
    owned_files: dict[str, tuple[int, int]],
) -> _StagedEntry:
    source_descriptor, opened = _open_regular_source(item.source_path)
    try:
        if opened != expected_source_metadata:
            raise StagingError("source changed after preflight")
        staged_identity = _clone_or_copy(
            source_descriptor,
            destination_directory_descriptor,
            item.logical_relative_path,
        )
        if (
            not isinstance(staged_identity, tuple)
            or len(staged_identity) != 2
            or any(type(value) is not int for value in staged_identity)
        ):
            raise StagingError("staged file identity is unavailable")
        owned_files[item.logical_relative_path] = staged_identity
        staged_descriptor = _open_staged_file(
            destination_directory_descriptor,
            item.logical_relative_path,
            staged_identity,
        )
        try:
            opened_staged = os.fstat(staged_descriptor)
            if (opened_staged.st_dev, opened_staged.st_ino) != staged_identity:
                raise StagingError("staged file identity changed")
            staged = _hash_descriptor(
                staged_descriptor,
                maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
            )
        finally:
            os.close(staged_descriptor)
        source_snapshot = _hash_descriptor(
            source_descriptor,
            maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
        )
        if source_snapshot.metadata != opened:
            raise StagingError("source changed during staging")
    finally:
        os.close(source_descriptor)
    _revalidate_path(item.source_path, source_snapshot.metadata, "source")
    if (
        staged.sha256 != source_snapshot.sha256
        or staged.metadata.size != source_snapshot.metadata.size
    ):
        raise StagingError("staged bytes differ from their source")
    return _StagedEntry(
        source=item,
        source_snapshot=source_snapshot,
        manifest_entry={
            "logical_relative_path": item.logical_relative_path,
            "media_type": item.media_type,
            "group_id": item.group_id,
            "bytes": source_snapshot.metadata.size,
            "sha256": source_snapshot.sha256,
        },
    )


def _write_new_file(
    directory_descriptor: int,
    name: str,
    data: bytes,
) -> tuple[int, int]:
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory_descriptor,
        )
    except OSError as error:
        raise StagingError("staging manifest could not be created") from error
    created = os.fstat(descriptor)
    created_identity = (created.st_dev, created.st_ino)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise StagingError("staging manifest write made no progress")
            view = view[written:]
        _canonicalize_staged_metadata(descriptor, 0o600)
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        return metadata.st_dev, metadata.st_ino
    except Exception:
        _discard_owned_file(
            directory_descriptor,
            name,
            created_identity,
        )
        raise
    finally:
        os.close(descriptor)


def _rename_exclusive(
    parent_descriptor: int,
    temporary_name: str,
    destination_name: str,
) -> None:
    try:
        _rename_no_replace(
            parent_descriptor,
            temporary_name,
            parent_descriptor,
            destination_name,
        )
    except OSError as error:
        if error.errno == errno.EEXIST:
            raise StagingError("output root already exists") from error
        raise StagingError("exclusive staging publication failed") from error
    except StagingError as error:
        raise StagingError("exclusive staging publication is unavailable") from error


def _safe_cleanup_flat_directory(
    parent_descriptor: int,
    name: str,
    expected_identity: tuple[int, int],
    expected_files: dict[str, tuple[int, int]],
) -> None:
    root_quarantine = TEMPORARY_PREFIX + "cleanup-" + secrets.token_hex(16)
    try:
        _rename_no_replace(
            parent_descriptor,
            name,
            parent_descriptor,
            root_quarantine,
        )
    except (OSError, StagingError):
        return
    restore_root = True
    descriptor: int | None = None
    try:
        moved_root = os.stat(
            root_quarantine,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(moved_root.st_mode)
            or (moved_root.st_dev, moved_root.st_ino) != expected_identity
        ):
            return
        descriptor = os.open(
            root_quarantine,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        opened_root = os.fstat(descriptor)
        rebound_root = os.stat(
            root_quarantine,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (opened_root.st_dev, opened_root.st_ino) != expected_identity or (
            rebound_root.st_dev,
            rebound_root.st_ino,
        ) != expected_identity:
            return
        children = list(os.scandir(descriptor))
        if {child.name for child in children} != set(expected_files):
            return
        for child in children:
            try:
                child_metadata = child.stat(follow_symlinks=False)
            except (OSError, StagingError):
                return
            if (
                not stat.S_ISREG(child_metadata.st_mode)
                or (child_metadata.st_dev, child_metadata.st_ino)
                != expected_files[child.name]
            ):
                return

        for child_name in sorted(
            expected_files, key=lambda value: value.encode("utf-8")
        ):
            child_quarantine = TEMPORARY_PREFIX + "child-" + secrets.token_hex(16)
            try:
                _rename_no_replace(
                    descriptor,
                    child_name,
                    descriptor,
                    child_quarantine,
                )
            except (OSError, StagingError):
                return
            restore_child = True
            child_descriptor: int | None = None
            try:
                moved_child = os.stat(
                    child_quarantine,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (
                    not stat.S_ISREG(moved_child.st_mode)
                    or (moved_child.st_dev, moved_child.st_ino)
                    != expected_files[child_name]
                ):
                    return
                child_descriptor = os.open(
                    child_quarantine,
                    os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=descriptor,
                )
                opened_child = os.fstat(child_descriptor)
                rebound_child = os.stat(
                    child_quarantine,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (
                    not stat.S_ISREG(opened_child.st_mode)
                    or (opened_child.st_dev, opened_child.st_ino)
                    != expected_files[child_name]
                    or (rebound_child.st_dev, rebound_child.st_ino)
                    != expected_files[child_name]
                ):
                    return
                final_child = os.stat(
                    child_quarantine,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (final_child.st_dev, final_child.st_ino) != expected_files[
                    child_name
                ]:
                    return
                _unlink_quarantined_name(
                    descriptor,
                    child_quarantine,
                    directory=False,
                    expected_identity=expected_files[child_name],
                )
                restore_child = False
            except (OSError, StagingError):
                return
            finally:
                if child_descriptor is not None:
                    os.close(child_descriptor)
                if restore_child:
                    _restore_quarantined_name(
                        descriptor,
                        child_quarantine,
                        child_name,
                    )

        if any(os.scandir(descriptor)):
            return
        os.fsync(descriptor)
        final_root = os.stat(
            root_quarantine,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (final_root.st_dev, final_root.st_ino) != expected_identity:
            return
        os.close(descriptor)
        descriptor = None
        _unlink_quarantined_name(
            parent_descriptor,
            root_quarantine,
            directory=True,
            expected_identity=expected_identity,
        )
        restore_root = False
        os.fsync(parent_descriptor)
    except (OSError, StagingError):
        pass
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if restore_root:
            _restore_quarantined_name(
                parent_descriptor,
                root_quarantine,
                name,
            )


def _verify_staging_directory(
    directory_descriptor: int,
    manifest: dict[str, Any],
    manifest_bytes: bytes,
    expected_identities: dict[str, tuple[int, int]] | None,
) -> None:
    root_before = _Metadata.from_stat(os.fstat(directory_descriptor))
    if not stat.S_ISDIR(root_before.mode):
        raise StagingError("published staging root is unsafe")
    expected_entries = manifest["entries"]
    expected_names = {MANIFEST_NAME} | {
        item["logical_relative_path"] for item in expected_entries
    }
    if expected_identities is not None and set(expected_identities) != expected_names:
        raise StagingError("published staging ownership differs from the manifest")
    try:
        names = {child.name for child in os.scandir(directory_descriptor)}
    except OSError as error:
        raise StagingError("published staging root is unreadable") from error
    if names != expected_names:
        raise StagingError("published staging contents differ from the manifest")
    _verify_canonical_metadata(directory_descriptor, 0o700)
    descriptors: dict[str, int] = {}
    snapshots: dict[str, _FileSnapshot] = {}
    try:
        for name in sorted(expected_names, key=lambda value: value.encode("utf-8")):
            descriptor = _open_staged_file(
                directory_descriptor,
                name,
                expected_identities[name] if expected_identities is not None else None,
            )
            descriptors[name] = descriptor
            opened = os.fstat(descriptor)
            if (
                expected_identities is not None
                and (
                    opened.st_dev,
                    opened.st_ino,
                )
                != expected_identities[name]
            ):
                raise StagingError("published staged file identity changed")

        for item in expected_entries:
            name = item["logical_relative_path"]
            snapshot = _hash_descriptor(
                descriptors[name],
                maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
            )
            snapshots[name] = snapshot
            if (
                snapshot.metadata.size != item["bytes"]
                or snapshot.sha256 != item["sha256"]
            ):
                raise StagingError("published staged bytes differ from the manifest")
        manifest_snapshot = _hash_descriptor(
            descriptors[MANIFEST_NAME],
            maximum_bytes=MAXIMUM_DESCRIPTOR_BYTES,
        )
        snapshots[MANIFEST_NAME] = manifest_snapshot
        if manifest_snapshot.metadata.size != len(
            manifest_bytes
        ) or manifest_snapshot.sha256 != _sha256(manifest_bytes):
            raise StagingError("published staging manifest changed")

        try:
            final_names = {child.name for child in os.scandir(directory_descriptor)}
        except OSError as error:
            raise StagingError("published staging root is unreadable") from error
        if final_names != expected_names:
            raise StagingError("published staging contents differ from the manifest")
        if _Metadata.from_stat(os.fstat(directory_descriptor)) != root_before:
            raise StagingError(
                "published staging generation changed during verification"
            )
        _verify_canonical_metadata(directory_descriptor, 0o700)
        for name in sorted(expected_names, key=lambda value: value.encode("utf-8")):
            descriptor_metadata = _Metadata.from_stat(os.fstat(descriptors[name]))
            try:
                path_metadata = _Metadata.from_stat(
                    os.stat(
                        name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                )
            except OSError as error:
                raise StagingError(
                    "published staging generation changed during verification"
                ) from error
            if (
                descriptor_metadata != snapshots[name].metadata
                or path_metadata != snapshots[name].metadata
            ):
                raise StagingError(
                    "published staging generation changed during verification"
                )
            _verify_canonical_metadata(descriptors[name], 0o600)
    finally:
        for descriptor in descriptors.values():
            os.close(descriptor)


def _assert_bound_directory_name(
    parent_descriptor: int,
    name: str,
    expected_identity: tuple[int, int],
) -> None:
    try:
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        raise StagingError("published staging root identity changed") from error
    if (
        not stat.S_ISDIR(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_gid != os.getegid()
        or stat.S_IMODE(current.st_mode) != 0o700
        or (current.st_dev, current.st_ino) != expected_identity
    ):
        raise StagingError("published staging root identity changed")


def _open_bound_directory(
    parent_descriptor: int,
    name: str,
    expected_identity: tuple[int, int],
) -> int:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
    except OSError as error:
        raise StagingError("published staging root identity changed") from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != expected_identity
        ):
            raise StagingError("published staging root identity changed")
        _verify_canonical_metadata(descriptor, 0o700)
        _assert_bound_directory_name(parent_descriptor, name, expected_identity)
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _read_descriptor_bytes(
    descriptor: int,
    *,
    maximum_bytes: int,
) -> tuple[bytes, _FileSnapshot]:
    snapshot = _hash_descriptor(descriptor, maximum_bytes=maximum_bytes)
    os.lseek(descriptor, 0, os.SEEK_SET)
    data = bytearray()
    while len(data) < snapshot.metadata.size:
        chunk = os.read(
            descriptor,
            min(1024 * 1024, snapshot.metadata.size - len(data)),
        )
        if not chunk:
            break
        data.extend(chunk)
    if (
        len(data) != snapshot.metadata.size
        or _Metadata.from_stat(os.fstat(descriptor)) != snapshot.metadata
        or _sha256(bytes(data)) != snapshot.sha256
    ):
        raise StagingError("staging manifest changed during read")
    return bytes(data), snapshot


def _valid_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 71
        and value.startswith("sha256:")
        and all(character in "0123456789abcdef" for character in value[7:])
    )


def _validated_staging_manifest(value: Any, manifest_bytes: bytes) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "kind",
        "entry_count",
        "total_bytes",
        "aggregate_sha256",
        "entries",
    }:
        raise StagingError("staging manifest fields are invalid")
    if (
        type(value["schema_version"]) is not int
        or value["schema_version"] != SCHEMA_VERSION
        or value["kind"] != MANIFEST_KIND
    ):
        raise StagingError("staging manifest schema is invalid")
    raw_entries = value["entries"]
    if (
        not isinstance(raw_entries, list)
        or not 2 <= len(raw_entries) <= MAXIMUM_ENTRY_COUNT
    ):
        raise StagingError("staging manifest entry count is invalid")
    logical_identities: set[str] = set()
    content_hashes: set[str] = set()
    photo_groups: set[str] = set()
    video_groups: set[str] = set()
    total_bytes = 0
    prior_name: bytes | None = None
    for item in raw_entries:
        if not isinstance(item, dict) or set(item) != {
            "logical_relative_path",
            "media_type",
            "group_id",
            "bytes",
            "sha256",
        }:
            raise StagingError("staging manifest entry fields are invalid")
        name = _validate_logical_name(item["logical_relative_path"])
        encoded_name = name.encode("utf-8")
        if prior_name is not None and encoded_name <= prior_name:
            raise StagingError("staging manifest entries are not canonically ordered")
        prior_name = encoded_name
        logical_identity = unicodedata.normalize("NFC", name).casefold()
        if logical_identity in logical_identities:
            raise StagingError(
                "staging manifest contains an ambiguous logical basename"
            )
        logical_identities.add(logical_identity)
        media_type = item["media_type"]
        if media_type not in {"photo", "video"}:
            raise StagingError("staging manifest media type is invalid")
        allowed_extensions = (
            SUPPORTED_PHOTO_EXTENSIONS
            if media_type == "photo"
            else SUPPORTED_VIDEO_EXTENSIONS
        )
        if Path(name).suffix.casefold() not in allowed_extensions:
            raise StagingError("staging manifest media extension is invalid")
        group_id = _validate_group_id(item["group_id"])
        if media_type == "photo":
            photo_groups.add(group_id)
        else:
            if group_id in video_groups:
                raise StagingError(
                    "staging manifest contains a duplicate video group ID"
                )
            video_groups.add(group_id)
        byte_count = item["bytes"]
        if (
            type(byte_count) is not int
            or not 0 < byte_count <= MAXIMUM_SOURCE_FILE_BYTES
            or not _valid_sha256(item["sha256"])
        ):
            raise StagingError("staging manifest file evidence is invalid")
        if item["sha256"] in content_hashes:
            raise StagingError("staging manifest contains duplicate content")
        content_hashes.add(item["sha256"])
        total_bytes += byte_count
        if total_bytes > MAXIMUM_SOURCE_CLOSURE_BYTES:
            raise StagingError("staging manifest closure exceeds the supported size")
    if {item["media_type"] for item in raw_entries} != {"photo", "video"}:
        raise StagingError("staging manifest must contain both photos and videos")
    if len(photo_groups) != 1:
        raise StagingError("staging manifest photos must share one group")
    if not photo_groups.isdisjoint(video_groups):
        raise StagingError("staging manifest media groups collide")
    if (
        type(value["entry_count"]) is not int
        or value["entry_count"] != len(raw_entries)
        or type(value["total_bytes"]) is not int
        or value["total_bytes"] != total_bytes
        or value["aggregate_sha256"] != _sha256(_canonical_json(raw_entries))
    ):
        raise StagingError("staging manifest aggregate evidence is invalid")
    if _canonical_json(value) != manifest_bytes:
        raise StagingError("staging manifest is not canonical JSON")
    return value


def verify(
    output_root: Path,
    *,
    _expected_root_identity: tuple[int, int] | None = None,
    _expected_identities: dict[str, tuple[int, int]] | None = None,
) -> dict[str, Any]:
    output_root = Path(output_root)
    value = os.fspath(output_root)
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise StagingError("output root must be an absolute normalized path")
    if output_root.name in {"", ".", ".."}:
        raise StagingError("output root name is invalid")
    output_parent = output_root.parent
    parent_descriptor = _open_plain_directory(output_parent, "output parent")
    root_descriptor: int | None = None
    try:
        _assert_output_parent_binding(output_parent, parent_descriptor)
        try:
            root_descriptor = os.open(
                output_root.name,
                os.O_RDONLY
                | os.O_CLOEXEC
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_descriptor,
            )
        except OSError as error:
            raise StagingError("published staging root is unavailable") from error
        root = os.fstat(root_descriptor)
        root_identity = (root.st_dev, root.st_ino)
        if (
            _expected_root_identity is not None
            and root_identity != _expected_root_identity
        ):
            raise StagingError("published staging root identity changed")
        _verify_canonical_metadata(
            root_descriptor,
            0o700,
            check_timestamps=False,
        )
        _assert_bound_directory_name(
            parent_descriptor,
            output_root.name,
            root_identity,
        )

        manifest_descriptor = _open_staged_file(root_descriptor, MANIFEST_NAME)
        try:
            manifest_bytes, _ = _read_descriptor_bytes(
                manifest_descriptor,
                maximum_bytes=MAXIMUM_DESCRIPTOR_BYTES,
            )
        finally:
            os.close(manifest_descriptor)
        manifest = _validated_staging_manifest(
            _decode_json(manifest_bytes),
            manifest_bytes,
        )
        _ensure_descriptor_capacity(manifest["entry_count"])
        _verify_staging_directory(
            root_descriptor,
            manifest,
            manifest_bytes,
            _expected_identities,
        )
        _assert_bound_directory_name(
            parent_descriptor,
            output_root.name,
            root_identity,
        )
        _assert_output_parent_binding(output_parent, parent_descriptor)
        return {
            "schema_version": SCHEMA_VERSION,
            "entry_count": manifest["entry_count"],
            "total_bytes": manifest["total_bytes"],
            "manifest_sha256": _sha256(manifest_bytes),
        }
    finally:
        if root_descriptor is not None:
            os.close(root_descriptor)
        os.close(parent_descriptor)


def _validate_output_path(
    output_root: Path, entries: list[_SourceEntry]
) -> tuple[Path, str]:
    value = os.fspath(output_root)
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise StagingError("output root must be an absolute normalized path")
    if output_root.name in {"", ".", ".."}:
        raise StagingError("output root name is invalid")
    parent = output_root.parent
    _reject_symlink_ancestors(parent, "output parent")
    for item in entries:
        source_parent = os.path.normpath(os.fspath(item.source_path.parent))
        output_parent = os.path.normpath(os.fspath(parent))
        try:
            common = os.path.commonpath((source_parent, output_parent))
        except ValueError:
            continue
        if common == source_parent:
            raise StagingError("output root must remain outside source directories")
    return parent, output_root.name


def _validate_output_parent_descriptor(descriptor: int) -> None:
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise StagingError("output parent permissions are unsafe")
    if _has_extended_acl(descriptor):
        raise StagingError("output parent has an extended ACL")


def _assert_output_parent_binding(path: Path, descriptor: int) -> None:
    _validate_output_parent_descriptor(descriptor)
    try:
        current = os.lstat(path)
        opened = os.fstat(descriptor)
    except OSError as error:
        raise StagingError("output parent identity changed") from error
    if (
        not stat.S_ISDIR(current.st_mode)
        or stat.S_ISLNK(current.st_mode)
        or current.st_uid != os.geteuid()
        or stat.S_IMODE(current.st_mode) != 0o700
        or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
    ):
        raise StagingError("output parent identity changed")


def _fsync_parent(descriptor: int) -> None:
    os.fsync(descriptor)


def _assert_destination_absent(parent_descriptor: int, destination_name: str) -> None:
    try:
        os.stat(destination_name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise StagingError("output root availability could not be verified") from error
    raise StagingError("output root already exists")


def _revalidate_sources(
    staged_entries: list[_StagedEntry],
    descriptor_path: Path,
    descriptor_snapshot: _FileSnapshot,
) -> None:
    for staged in staged_entries:
        _revalidate_path(
            staged.source.source_path,
            staged.source_snapshot.metadata,
            "source",
        )
    _revalidate_path(descriptor_path, descriptor_snapshot.metadata, "source descriptor")


def stage(descriptor_path: Path, output_root: Path) -> dict[str, Any]:
    descriptor_path = Path(descriptor_path)
    output_root = Path(output_root)
    entries, descriptor_snapshot = _descriptor_snapshot(descriptor_path)
    _ensure_descriptor_capacity(len(entries))
    preflight_metadata, preflight_total_bytes = _preflight_sources(entries)
    _revalidate_preflight_sources(entries, preflight_metadata)
    _revalidate_path(descriptor_path, descriptor_snapshot.metadata, "source descriptor")
    output_parent, destination_name = _validate_output_path(output_root, entries)
    parent_descriptor = _open_plain_directory(output_parent, "output parent")
    temporary_name = TEMPORARY_PREFIX + secrets.token_hex(16)
    temporary_descriptor: int | None = None
    published_descriptor: int | None = None
    owned_identity: tuple[int, int] | None = None
    owned_files: dict[str, tuple[int, int]] = {}
    published = False
    try:
        _validate_output_parent_descriptor(parent_descriptor)
        _assert_output_parent_binding(output_parent, parent_descriptor)
        _assert_destination_absent(parent_descriptor, destination_name)
        try:
            os.mkdir(temporary_name, 0o700, dir_fd=parent_descriptor)
        except OSError as error:
            raise StagingError("private staging root could not be created") from error
        temporary_descriptor = os.open(
            temporary_name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        _canonicalize_staged_metadata(temporary_descriptor, 0o700)
        temporary_metadata = os.fstat(temporary_descriptor)
        owned_identity = (temporary_metadata.st_dev, temporary_metadata.st_ino)
        if not stat.S_ISDIR(temporary_metadata.st_mode):
            raise StagingError("private staging root is unsafe")
        _assert_bound_directory_name(
            parent_descriptor,
            temporary_name,
            owned_identity,
        )

        staged_entries: list[_StagedEntry] = []
        seen_content: set[str] = set()
        for item in entries:
            staged = _stage_entry(
                item,
                preflight_metadata[item.logical_relative_path],
                temporary_descriptor,
                owned_files,
            )
            if staged.source_snapshot.sha256 in seen_content:
                raise StagingError("descriptor contains duplicate content")
            seen_content.add(staged.source_snapshot.sha256)
            staged_entries.append(staged)

        manifest_entries = [item.manifest_entry for item in staged_entries]
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "kind": MANIFEST_KIND,
            "entry_count": len(manifest_entries),
            "total_bytes": preflight_total_bytes,
            "aggregate_sha256": _sha256(_canonical_json(manifest_entries)),
            "entries": manifest_entries,
        }
        manifest_bytes = _canonical_json(manifest)
        if len(manifest_bytes) > MAXIMUM_DESCRIPTOR_BYTES:
            raise StagingError("staging manifest exceeds the supported size")
        owned_files[MANIFEST_NAME] = _write_new_file(
            temporary_descriptor,
            MANIFEST_NAME,
            manifest_bytes,
        )
        _canonicalize_staged_metadata(temporary_descriptor, 0o700)

        _revalidate_sources(staged_entries, descriptor_path, descriptor_snapshot)
        _verify_staging_directory(
            temporary_descriptor,
            manifest,
            manifest_bytes,
            owned_files,
        )
        _revalidate_sources(staged_entries, descriptor_path, descriptor_snapshot)
        os.fsync(temporary_descriptor)
        _assert_bound_directory_name(
            parent_descriptor,
            temporary_name,
            owned_identity,
        )
        _assert_output_parent_binding(output_parent, parent_descriptor)

        _rename_exclusive(parent_descriptor, temporary_name, destination_name)
        published = True
        published_descriptor = _open_bound_directory(
            parent_descriptor,
            destination_name,
            owned_identity,
        )
        _revalidate_sources(staged_entries, descriptor_path, descriptor_snapshot)
        os.fsync(published_descriptor)
        try:
            _fsync_parent(parent_descriptor)
        except OSError as error:
            raise StagingError("staging publication could not be committed") from error
        _assert_output_parent_binding(output_parent, parent_descriptor)
        _revalidate_sources(staged_entries, descriptor_path, descriptor_snapshot)
        _assert_bound_directory_name(
            parent_descriptor,
            destination_name,
            owned_identity,
        )
        _assert_output_parent_binding(output_parent, parent_descriptor)
        summary = {
            "schema_version": SCHEMA_VERSION,
            "entry_count": len(manifest_entries),
            "total_bytes": preflight_total_bytes,
            "manifest_sha256": _sha256(manifest_bytes),
        }
        verified_summary = verify(
            output_root,
            _expected_root_identity=owned_identity,
            _expected_identities=owned_files,
        )
        if verified_summary != summary:
            raise StagingError("published staging summary changed during verification")
        return summary
    except Exception:
        if owned_identity is not None:
            _safe_cleanup_flat_directory(
                parent_descriptor,
                destination_name if published else temporary_name,
                owned_identity,
                owned_files,
            )
        raise
    finally:
        if published_descriptor is not None:
            os.close(published_descriptor)
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        os.close(parent_descriptor)


def _arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create and verify a private mixed photo/video staging generation."
    )
    parser.add_argument("--descriptor", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    parsed = _arguments(arguments)
    try:
        summary = stage(parsed.descriptor, parsed.output_root)
    except (StagingError, OSError) as error:
        sys.stderr.write(f"mixed input staging: {error}\n")
        return 1
    sys.stdout.write(_canonical_json(summary).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
