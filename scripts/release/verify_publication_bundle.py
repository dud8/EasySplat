#!/usr/bin/env python3
"""Build and verify the inert artifact closure used to publish EasySplat."""

from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Iterator, NamedTuple, NoReturn


BUILD_CLOSURE_NAME = "build-closure.json"
PUBLICATION_MANIFEST_NAME = "publication-manifest.json"
TOOLCHAIN_AUTHORITY_RECEIPT_NAME = "toolchain-authority-receipt.json"
TOOLCHAIN_AUTHORITY_ENVELOPE_NAME = "toolchain-authority-envelope.json"
TOOLCHAIN_RELEASE_REQUEST_NAME = "toolchain-release-request.json"
TOOLCHAIN_BENCHMARK_EVIDENCE_NAME = "toolchain-benchmark-evidence.json"
AUTHORITY_RECEIPT_SIGNATURE_DOMAIN = b"EasySplat Release Authority Receipt v1\n"
CANONICAL_SOURCE_REPOSITORY = "dud8/EasySplat"
CANONICAL_SOURCE_REPOSITORY_ID = 1_143_631_347
CANONICAL_SOURCE_WORKFLOW_ID = 227_648_955
CANONICAL_SOURCE_WORKFLOW_PATH = ".github/workflows/toolchain-build.yml"
CANONICAL_AUTHORITY_REPOSITORY = "dud8/easysplat-release-authority"
CANONICAL_AUTHORITY_REPOSITORY_ID = 1_301_851_745
METALSPLATTER_SOURCE = "https://github.com/scier/MetalSplatter"
METALSPLATTER_BASE_REVISION = "c0f066fb7146d46d9b68e5c76d7d0a6154facc5e"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAX_RELEASE_ASSET_BYTES = 2_147_483_648
MAX_HASH_BYTES = MAX_RELEASE_ASSET_BYTES
SHA256 = re.compile(r"[0-9a-f]{64}")
SHA256_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?"
)
UTC_RFC3339 = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
UUID_LINE = re.compile(
    r"UUID: ([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}) "
    r"\(arm64\) .+"
)
SYSTEM_TOOLS = {
    "hdiutil": "/usr/bin/hdiutil",
    "plutil": "/usr/bin/plutil",
    "lipo": "/usr/bin/lipo",
    "codesign": "/usr/bin/codesign",
    "dwarfdump": "/usr/bin/dwarfdump",
}
APP_BUNDLED_TOOLCHAIN_EXECUTABLES = (
    "Contents/Helpers/bin/colmap",
    "Contents/Helpers/bin/easysplat-train",
)
APP_BUNDLED_TOOLCHAIN_PAYLOAD = (
    "Contents/Helpers/lib/libomp.dylib",
    "Contents/Resources/Toolchain/default.metallib",
    "Contents/Resources/Toolchain/supply-chain/components.json",
)
APP_RETIRED_TOOLCHAIN_RESOURCE_NAMES = (
    "public_key_ed25519.txt",
    "toolchain_manifest_url.txt",
)


def load_release_helper(filename: str, module_name: str) -> Any:
    path = Path(__file__).resolve().with_name(filename)
    specification = importlib.util.spec_from_file_location(module_name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load release helper: {filename}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


SIGNING_HELPER = load_release_helper(
    "sign_macos_distribution.py", "easysplat_publication_signing_helper"
)
NOTARY_HELPER = load_release_helper(
    "verify_notarization_receipt.py", "easysplat_publication_notary_helper"
)


class PublicationError(ValueError):
    pass


def fail(message: str) -> NoReturn:
    raise PublicationError(message)


def validate_release_mode(release_mode: str) -> None:
    if release_mode not in {"development-unsigned", "production"}:
        fail(f"unsupported release mode: {release_mode}")


def build_file_limits(
    app_version: str, release_mode: str = "development-unsigned"
) -> dict[str, int]:
    validate_release_mode(release_mode)
    stem = f"EasySplat-{app_version}"
    suffix = "-unsigned" if release_mode == "development-unsigned" else ""
    limits = {
        f"{stem}{suffix}.dmg": MAX_RELEASE_ASSET_BYTES,
        f"{stem}{suffix}.dmg.sha256": 1_024,
        f"{stem}.provenance.json": 8 * 1_024 * 1_024,
        f"{stem}.spdx.json": 64 * 1_024 * 1_024,
        f"{stem}-licenses.zip": MAX_RELEASE_ASSET_BYTES,
        f"{stem}-dSYM.zip": MAX_RELEASE_ASSET_BYTES,
        f"{stem}-release-notes.txt": 64 * 1_024,
        "toolchain-manifest.json": 8 * 1_024 * 1_024,
        TOOLCHAIN_AUTHORITY_RECEIPT_NAME: 1 * 1_024 * 1_024,
        TOOLCHAIN_AUTHORITY_ENVELOPE_NAME: 64 * 1_024 * 1_024,
        TOOLCHAIN_RELEASE_REQUEST_NAME: 8 * 1_024 * 1_024,
        TOOLCHAIN_BENCHMARK_EVIDENCE_NAME: 8 * 1_024 * 1_024,
    }
    if release_mode == "production":
        limits.update(
            {
                f"{stem}.app-signing.json": 16 * 1_024 * 1_024,
                f"{stem}.app-notarization.json": 4 * 1_024 * 1_024,
                f"{stem}.dmg-signing.json": 4 * 1_024 * 1_024,
                f"{stem}.dmg-notarization.json": 4 * 1_024 * 1_024,
            }
        )
    return limits


def publication_payload_names(
    app_version: str,
    release_mode: str = "development-unsigned",
    *,
    include_benchmark: bool = True,
) -> tuple[str, ...]:
    validate_release_mode(release_mode)
    stem = f"EasySplat-{app_version}"
    suffix = "-unsigned" if release_mode == "development-unsigned" else ""
    names = [
        f"{stem}{suffix}.dmg",
        f"{stem}{suffix}.dmg.sha256",
        f"{stem}.provenance.json",
        f"{stem}.spdx.json",
        f"{stem}-licenses.zip",
        f"{stem}-dSYM.zip",
        f"{stem}-release-notes.txt",
    ]
    if include_benchmark:
        names.insert(-1, f"{stem}-benchmark.json")
    return tuple(names)


def publication_file_limits(
    app_version: str,
    release_mode: str = "development-unsigned",
    *,
    include_benchmark: bool = True,
) -> dict[str, int]:
    limits = build_file_limits(app_version, release_mode)
    limits.pop("toolchain-manifest.json")
    limits.pop(TOOLCHAIN_AUTHORITY_RECEIPT_NAME)
    limits.pop(TOOLCHAIN_AUTHORITY_ENVELOPE_NAME)
    limits.pop(TOOLCHAIN_RELEASE_REQUEST_NAME)
    limits.pop(TOOLCHAIN_BENCHMARK_EVIDENCE_NAME)
    for suffix in (
        ".app-signing.json",
        ".app-notarization.json",
        ".dmg-signing.json",
        ".dmg-notarization.json",
    ):
        limits.pop(f"EasySplat-{app_version}{suffix}", None)
    if include_benchmark:
        limits[f"EasySplat-{app_version}-benchmark.json"] = 128 * 1_024 * 1_024
    return limits


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")


def signature_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def sha256_stream(stream: BinaryIO, *, limit: int = MAX_HASH_BYTES) -> str:
    digest = hashlib.sha256()
    total = 0
    for chunk in iter(lambda: stream.read(1_024 * 1_024), b""):
        total += len(chunk)
        if total > limit:
            fail("file changed size or exceeded its hash limit while reading")
        digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: Path, *, limit: int = MAX_HASH_BYTES) -> str:
    return snapshot_bounded_regular_file(
        path,
        path.name or str(path),
        limit=limit,
        capture_bytes=False,
        allow_empty=True,
    ).sha256


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    payload: dict[str, Any] = {}
    for key, value in pairs:
        if key in payload:
            fail(f"JSON contains duplicate key {key!r}")
        payload[key] = value
    return payload


def reject_json_constant(value: str) -> NoReturn:
    fail(f"JSON contains non-finite value {value}")


def load_json(
    path: Path, label: str, *, limit: int = 64 * 1_024 * 1_024
) -> dict[str, Any]:
    raw = read_bounded_regular_file(path, label, limit=limit)
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    return payload


def load_compact_canonical_json(
    path: Path, label: str, *, limit: int = 1 * 1_024 * 1_024
) -> dict[str, Any]:
    payload, _digest = load_compact_canonical_json_with_sha256(
        path,
        label,
        limit=limit,
    )
    return payload


def load_compact_canonical_json_with_sha256(
    path: Path, label: str, *, limit: int = 1 * 1_024 * 1_024
) -> tuple[dict[str, Any], str]:
    snapshot = snapshot_bounded_regular_file(
        path,
        label,
        limit=limit,
        capture_bytes=True,
    )
    raw = snapshot.data
    if raw is None:
        fail(f"cannot safely retain {label}")
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    if raw != signature_json_bytes(payload):
        fail(f"{label} is not canonical compact JSON")
    return payload, snapshot.sha256


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        fail(f"{label} must contain exact keys {sorted(expected)}")


def validate_https_url(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a credential-free HTTPS URL")
    parsed = urllib.parse.urlparse(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        fail(f"{label} must be a credential-free HTTPS URL")
    return value


def validate_utc_timestamp(value: Any, label: str) -> str:
    if not isinstance(value, str) or not UTC_RFC3339.fullmatch(value):
        fail(f"{label} must be a UTC RFC 3339 timestamp")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        fail(f"{label} must be a UTC RFC 3339 timestamp")
    return value


def validate_release_timestamps(
    provenance: dict[str, Any], manifest: dict[str, Any]
) -> None:
    created_at = validate_utc_timestamp(
        provenance.get("createdAt"), "release provenance createdAt"
    )
    published_at = validate_utc_timestamp(
        manifest.get("publishedAt"), "toolchain manifest publishedAt"
    )
    created = datetime.fromisoformat(created_at[:-1] + "+00:00")
    published = datetime.fromisoformat(published_at[:-1] + "+00:00")
    if created < published:
        fail("release provenance creation time predates the signed manifest")


def require_regular_file(
    path: Path, label: str, *, maximum_size: int
) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail(f"{label} must be a regular file")
    if metadata.st_nlink != 1:
        fail(f"{label} must not be a hard link")
    if metadata.st_size <= 0 or metadata.st_size > maximum_size:
        fail(f"{label} exceeds its size limit or is empty")
    return metadata


class BoundedRegularFileSnapshot(NamedTuple):
    data: bytes | None
    sha256: str
    size_bytes: int


class BoundedRegularFileIdentity(NamedTuple):
    device: int
    inode: int
    mode: int
    link_count: int
    size_bytes: int
    modified_ns: int
    changed_ns: int


class BoundedRegularFileCopy(NamedTuple):
    snapshot: BoundedRegularFileSnapshot
    destination_identity: BoundedRegularFileIdentity


class StagedPublicationPayload(NamedTuple):
    records: list[dict[str, Any]]
    bindings: dict[str, BoundedRegularFileCopy]


def rename_entry_exclusive_raw(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> None:
    if (
        not source_name
        or Path(source_name).name != source_name
        or not destination_name
        or Path(destination_name).name != destination_name
    ):
        raise OSError(errno.EINVAL, "invalid directory entry name")
    try:
        function = ctypes.CDLL(None, use_errno=True).renameatx_np
    except (AttributeError, OSError) as error:
        raise OSError(
            errno.ENOSYS,
            f"exclusive rename is unavailable: {error}",
        ) from error
    function.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(
        parent_descriptor,
        os.fsencode(source_name),
        parent_descriptor,
        os.fsencode(destination_name),
        0x00000004,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    raise OSError(error_number, os.strerror(error_number))


def quarantine_owned_entry(
    parent_descriptor: int,
    name: str,
    owned_identity: BoundedRegularFileIdentity,
) -> bool:
    """Hide an owned entry without ever unlinking a raced replacement."""

    for _attempt in range(8):
        quarantine_name = f".{name}.abandoned-{uuid.uuid4().hex}"
        try:
            rename_entry_exclusive_raw(
                parent_descriptor,
                name,
                quarantine_name,
            )
        except OSError as error:
            if error.errno == errno.EEXIST:
                continue
            return False
        try:
            quarantined = bounded_regular_file_identity(
                os.stat(
                    quarantine_name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            )
        except OSError:
            return False
        if (quarantined.device, quarantined.inode) == (
            owned_identity.device,
            owned_identity.inode,
        ):
            return True

        # The name was replaced before the rename. Put that replacement back
        # when possible, and never delete it if another entry won the race.
        try:
            rename_entry_exclusive_raw(
                parent_descriptor,
                quarantine_name,
                name,
            )
        except OSError:
            pass
        return False
    return False


def remove_owned_regular_file(
    path: Path,
    owned_identity: BoundedRegularFileIdentity,
) -> None:
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory_flag = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory_flag is None:
        return
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path.parent,
            os.O_RDONLY
            | nofollow
            | directory_flag
            | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError:
        return
    try:
        quarantine_owned_entry(descriptor, path.name, owned_identity)
    finally:
        os.close(descriptor)


def bounded_regular_file_identity(
    metadata: os.stat_result,
) -> BoundedRegularFileIdentity:
    return BoundedRegularFileIdentity(
        device=metadata.st_dev,
        inode=metadata.st_ino,
        mode=metadata.st_mode,
        link_count=metadata.st_nlink,
        size_bytes=metadata.st_size,
        modified_ns=metadata.st_mtime_ns,
        changed_ns=metadata.st_ctime_ns,
    )


@contextlib.contextmanager
def open_bounded_regular_file(
    path: Path | str,
    label: str,
    *,
    limit: int,
    allow_empty: bool = False,
    directory_descriptor: int | None = None,
) -> Iterator[tuple[int, BoundedRegularFileIdentity]]:
    if limit <= 0:
        fail(f"{label} has an invalid size limit")
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        fail(f"cannot safely open {label}: O_NOFOLLOW is unavailable")
    flags = os.O_RDONLY | os.O_NONBLOCK
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= nofollow
    try:
        descriptor = os.open(path, flags, dir_fd=directory_descriptor)
    except OSError as error:
        fail(f"cannot safely open {label}: {error}")
    try:
        try:
            before_metadata = os.fstat(descriptor)
        except OSError as error:
            fail(f"cannot inspect opened {label}: {error}")
        before = bounded_regular_file_identity(before_metadata)
        if not stat.S_ISREG(before.mode) or before.link_count != 1:
            fail(f"{label} must be a bounded single-link regular file")
        if (
            before.size_bytes < 0
            or (before.size_bytes == 0 and not allow_empty)
            or before.size_bytes > limit
        ):
            fail(f"{label} exceeds its size limit or is empty")

        try:
            yield descriptor, before
        except BaseException:
            raise
        else:
            try:
                after = bounded_regular_file_identity(os.fstat(descriptor))
                path_after = bounded_regular_file_identity(
                    os.stat(
                        path,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                )
            except OSError as error:
                fail(f"cannot re-inspect opened {label}: {error}")
            if before != after or before != path_after:
                fail(f"{label} changed while it was read")
    finally:
        os.close(descriptor)


def snapshot_opened_regular_file(
    descriptor: int,
    identity: BoundedRegularFileIdentity,
    label: str,
    *,
    capture_bytes: bool,
    destination_descriptor: int | None = None,
) -> BoundedRegularFileSnapshot:
    digest = hashlib.sha256()
    chunks: list[bytes] | None = [] if capture_bytes else None
    remaining = identity.size_bytes
    while remaining:
        try:
            chunk = os.read(descriptor, min(remaining, 1_024 * 1_024))
        except InterruptedError:
            continue
        except OSError as error:
            fail(f"cannot safely read {label}: {error}")
        if not chunk:
            fail(f"{label} changed while it was read")
        digest.update(chunk)
        if chunks is not None:
            chunks.append(chunk)
        if destination_descriptor is not None:
            written = 0
            while written < len(chunk):
                try:
                    count = os.write(destination_descriptor, chunk[written:])
                except InterruptedError:
                    continue
                except OSError as error:
                    fail(f"cannot safely copy {label}: {error}")
                if count <= 0:
                    fail(f"cannot safely copy {label}: short write")
                written += count
        remaining -= len(chunk)
    while True:
        try:
            extra = os.read(descriptor, 1)
            break
        except InterruptedError:
            continue
        except OSError as error:
            fail(f"cannot safely finish reading {label}: {error}")
    if extra:
        fail(f"{label} changed while it was read")
    data = b"".join(chunks) if chunks is not None else None
    if data is not None and len(data) != identity.size_bytes:
        fail(f"{label} changed while it was read")
    return BoundedRegularFileSnapshot(
        data=data,
        sha256=digest.hexdigest(),
        size_bytes=identity.size_bytes,
    )


def snapshot_bounded_regular_file(
    path: Path,
    label: str,
    *,
    limit: int,
    capture_bytes: bool,
    allow_empty: bool = False,
) -> BoundedRegularFileSnapshot:
    with open_bounded_regular_file(
        path,
        label,
        limit=limit,
        allow_empty=allow_empty,
    ) as (descriptor, identity):
        return snapshot_opened_regular_file(
            descriptor,
            identity,
            label,
            capture_bytes=capture_bytes,
        )


def bind_bounded_regular_file(
    path: Path | str,
    label: str,
    *,
    limit: int,
    directory_descriptor: int | None = None,
) -> BoundedRegularFileCopy:
    with open_bounded_regular_file(
        path,
        label,
        limit=limit,
        directory_descriptor=directory_descriptor,
    ) as (descriptor, identity):
        snapshot = snapshot_opened_regular_file(
            descriptor,
            identity,
            label,
            capture_bytes=False,
        )
    return BoundedRegularFileCopy(
        snapshot=snapshot,
        destination_identity=identity,
    )


def copy_opened_bounded_regular_file(
    source_descriptor: int,
    source_identity: BoundedRegularFileIdentity,
    destination: Path,
    label: str,
) -> BoundedRegularFileCopy:
    destination_descriptor: int | None = None
    owned_destination: BoundedRegularFileIdentity | None = None
    try:
        flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            destination_descriptor = os.open(destination, flags, 0o600)
        except OSError as error:
            fail(f"cannot create bounded copy for {label}: {error}")
        try:
            owned_destination = bounded_regular_file_identity(
                os.fstat(destination_descriptor)
            )
        except OSError as error:
            fail(f"cannot inspect bounded copy for {label}: {error}")
        if (
            not stat.S_ISREG(owned_destination.mode)
            or owned_destination.link_count != 1
        ):
            fail(f"bounded copy destination is unsafe for {label}")
        snapshot = snapshot_opened_regular_file(
            source_descriptor,
            source_identity,
            label,
            capture_bytes=False,
            destination_descriptor=destination_descriptor,
        )
        try:
            os.fsync(destination_descriptor)
        except OSError as error:
            fail(f"cannot commit bounded copy for {label}: {error}")
        try:
            destination_before = bounded_regular_file_identity(
                os.fstat(destination_descriptor)
            )
            os.lseek(destination_descriptor, 0, os.SEEK_SET)
        except OSError as error:
            fail(f"cannot verify bounded copy for {label}: {error}")
        destination_snapshot = snapshot_opened_regular_file(
            destination_descriptor,
            destination_before,
            f"{label} destination",
            capture_bytes=False,
        )
        try:
            destination_after = bounded_regular_file_identity(
                os.fstat(destination_descriptor)
            )
            destination_path = bounded_regular_file_identity(
                os.stat(destination, follow_symlinks=False)
            )
        except OSError as error:
            fail(f"bounded copy destination changed for {label}: {error}")
        if (
            not stat.S_ISREG(destination_before.mode)
            or destination_before.link_count != 1
            or destination_before != destination_after
            or destination_before != destination_path
            or destination_snapshot != snapshot
        ):
            fail(f"bounded copy destination changed for {label}")
        return BoundedRegularFileCopy(
            snapshot=snapshot,
            destination_identity=destination_before,
        )
    except BaseException:
        if destination_descriptor is not None and owned_destination is not None:
            remove_owned_regular_file(destination, owned_destination)
        raise
    finally:
        if destination_descriptor is not None:
            os.close(destination_descriptor)


def copy_bounded_regular_file_with_identity(
    source: Path | str,
    destination: Path,
    label: str,
    *,
    limit: int,
    allow_empty: bool = False,
    source_directory_descriptor: int | None = None,
) -> BoundedRegularFileCopy:
    copied: BoundedRegularFileCopy | None = None
    try:
        with open_bounded_regular_file(
            source,
            label,
            limit=limit,
            allow_empty=allow_empty,
            directory_descriptor=source_directory_descriptor,
        ) as (source_descriptor, source_identity):
            copied = copy_opened_bounded_regular_file(
                source_descriptor,
                source_identity,
                destination,
                label,
            )
        return copied
    except BaseException:
        if copied is not None:
            remove_owned_regular_file(
                destination,
                copied.destination_identity,
            )
        raise


def copy_bounded_regular_file(
    source: Path | str,
    destination: Path,
    label: str,
    *,
    limit: int,
    allow_empty: bool = False,
    source_directory_descriptor: int | None = None,
) -> BoundedRegularFileSnapshot:
    return copy_bounded_regular_file_with_identity(
        source,
        destination,
        label,
        limit=limit,
        allow_empty=allow_empty,
        source_directory_descriptor=source_directory_descriptor,
    ).snapshot


def stage_exact_directory(
    source: Path,
    destination: Path,
    limits: dict[str, int],
    *,
    label: str,
) -> dict[str, BoundedRegularFileSnapshot]:
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory_flag = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory_flag is None:
        fail(f"cannot safely stage {label}: directory safety flags are unavailable")
    flags = os.O_RDONLY | nofollow | directory_flag
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(source, flags)
    except OSError as error:
        fail(f"cannot safely open {label}: {error}")
    try:
        try:
            before = bounded_regular_file_identity(os.fstat(descriptor))
        except OSError as error:
            fail(f"cannot inspect opened {label}: {error}")
        if not stat.S_ISDIR(before.mode):
            fail(f"{label} must be a real directory")
        try:
            names_before = set(os.listdir(descriptor))
        except OSError as error:
            fail(f"cannot enumerate opened {label}: {error}")
        if names_before != set(limits):
            fail(f"{label} must contain the exact file set {sorted(limits)}")
        try:
            destination.mkdir(mode=0o700)
        except OSError as error:
            fail(f"cannot create private stage for {label}: {error}")

        snapshots: dict[str, BoundedRegularFileSnapshot] = {}
        with contextlib.ExitStack() as opened_sources:
            opened: dict[
                str, tuple[int, BoundedRegularFileIdentity]
            ] = {}
            for name in sorted(limits):
                opened[name] = opened_sources.enter_context(
                    open_bounded_regular_file(
                        name,
                        f"{label} file {name}",
                        limit=limits[name],
                        directory_descriptor=descriptor,
                    )
                )
            for name in sorted(limits):
                source_descriptor, source_identity = opened[name]
                copied = copy_opened_bounded_regular_file(
                    source_descriptor,
                    source_identity,
                    destination / name,
                    f"{label} file {name}",
                )
                snapshots[name] = copied.snapshot
        try:
            names_after = set(os.listdir(descriptor))
            after = bounded_regular_file_identity(os.fstat(descriptor))
            path_after = bounded_regular_file_identity(
                os.stat(source, follow_symlinks=False)
            )
        except OSError as error:
            fail(f"cannot re-inspect opened {label}: {error}")
        if names_after != names_before or after != before or path_after != before:
            fail(f"{label} changed while it was staged")
        return snapshots
    finally:
        os.close(descriptor)


def read_bounded_regular_file(path: Path, label: str, *, limit: int) -> bytes:
    snapshot = snapshot_bounded_regular_file(
        path,
        label,
        limit=limit,
        capture_bytes=True,
    )
    if snapshot.data is None:
        fail(f"cannot safely retain {label}")
    return snapshot.data


def require_exact_directory(root: Path, limits: dict[str, int], *, label: str) -> None:
    try:
        metadata = root.lstat()
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or root.is_symlink():
        fail(f"{label} must be a real directory")
    try:
        names = {entry.name for entry in root.iterdir()}
    except OSError as error:
        fail(f"cannot enumerate {label}: {error}")
    if names != set(limits):
        fail(f"{label} must contain the exact file set {sorted(limits)}")
    for name, maximum_size in limits.items():
        require_regular_file(
            root / name, f"{label} file {name}", maximum_size=maximum_size
        )


def file_record(path: Path, *, maximum_size: int) -> dict[str, Any]:
    snapshot = snapshot_bounded_regular_file(
        path,
        path.name,
        limit=maximum_size,
        capture_bytes=False,
    )
    return {
        "name": path.name,
        "sha256": snapshot.sha256,
        "size_bytes": snapshot.size_bytes,
    }


def validate_identity(
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str | None,
    benchmark_artifact_id: str | None,
    benchmark_artifact_digest: str | None,
    release_mode: str,
) -> None:
    validate_release_mode(release_mode)
    try:
        _app_core, app_prerelease = parse_semver(app_version)
        _toolchain_core, toolchain_prerelease = parse_semver(toolchain_version)
    except PublicationError:
        fail("app and toolchain versions must use strict semantic versioning")
    if "+" in app_version or "+" in toolchain_version:
        fail(
            "public release versions must not contain semantic version build metadata"
        )
    if release_mode == "production" and (
        app_prerelease is not None or toolchain_prerelease is not None
    ):
        fail("production app and toolchain versions must be stable semantic versioning")
    if not REPOSITORY.fullmatch(source_repository):
        fail("source repository must be owner/name")
    if not COMMIT.fullmatch(source_commit):
        fail("source commit must be a lowercase full SHA")
    if tag != f"v{app_version}":
        fail("release tag does not match the app version")
    benchmark_values = (
        benchmark_run_id,
        benchmark_artifact_id,
        benchmark_artifact_digest,
    )
    if any(value is not None for value in benchmark_values):
        if any(value is None for value in benchmark_values):
            fail("benchmark identity must be supplied as one complete set")
        assert benchmark_run_id is not None
        assert benchmark_artifact_id is not None
        assert benchmark_artifact_digest is not None
        if not benchmark_run_id.isdecimal() or int(benchmark_run_id) <= 0:
            fail("benchmark run ID must be a positive integer")
        if not benchmark_artifact_id.isdecimal() or int(benchmark_artifact_id) <= 0:
            fail("benchmark artifact ID must be a positive integer")
        if not SHA256_DIGEST.fullmatch(benchmark_artifact_digest):
            fail("benchmark artifact digest must be sha256:<64 lowercase hex>")


def create_build_closure(
    bundle: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str | None = None,
    benchmark_artifact_id: str | None = None,
    benchmark_artifact_digest: str | None = None,
    release_mode: str = "development-unsigned",
) -> dict[str, Any]:
    validate_identity(
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
        release_mode=release_mode,
    )
    limits = build_file_limits(app_version, release_mode)
    require_exact_directory(bundle, limits, label="build bundle")
    payload = {
        "schema_version": 1,
        "app_version": app_version,
        "toolchain_version": toolchain_version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "tag": tag,
        "release_mode": release_mode,
        "benchmark": (
            {
                "run_id": benchmark_run_id,
                "artifact_id": benchmark_artifact_id,
                "artifact_digest": benchmark_artifact_digest,
            }
            if benchmark_run_id is not None
            else None
        ),
        "files": [
            file_record(bundle / name, maximum_size=limits[name])
            for name in sorted(limits)
        ],
    }
    target = bundle / BUILD_CLOSURE_NAME
    try:
        with target.open("xb") as stream:
            stream.write(canonical_json_bytes(payload))
    except FileExistsError:
        fail(f"{BUILD_CLOSURE_NAME} already exists")
    return payload


def validate_file_records(
    value: Any, root: Path, limits: dict[str, int], label: str
) -> None:
    if not isinstance(value, list) or len(value) != len(limits):
        fail(f"{label} file records are incomplete")
    expected_records = [
        file_record(root / name, maximum_size=limits[name]) for name in sorted(limits)
    ]
    if value != expected_records:
        fail(f"{label} closure mismatch")


def validate_build_bundle(
    bundle: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str | None = None,
    benchmark_artifact_id: str | None = None,
    benchmark_artifact_digest: str | None = None,
    release_mode: str = "development-unsigned",
) -> dict[str, Any]:
    validate_identity(
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
        release_mode=release_mode,
    )
    limits = build_file_limits(app_version, release_mode)
    closure_limits = dict(limits)
    closure_limits[BUILD_CLOSURE_NAME] = 4 * 1_024 * 1_024
    require_exact_directory(bundle, closure_limits, label="build bundle")
    closure = load_json(
        bundle / BUILD_CLOSURE_NAME, "build closure", limit=4 * 1_024 * 1_024
    )
    require_exact_keys(
        closure,
        {
            "schema_version",
            "app_version",
            "toolchain_version",
            "source_repository",
            "source_commit",
            "tag",
            "release_mode",
            "benchmark",
            "files",
        },
        "build closure",
    )
    expected_scalars = {
        "schema_version": 1,
        "app_version": app_version,
        "toolchain_version": toolchain_version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "tag": tag,
        "release_mode": release_mode,
    }
    for key, expected in expected_scalars.items():
        if closure[key] != expected:
            fail(f"build closure {key} does not match the release")
    benchmark = closure["benchmark"]
    expected_benchmark = (
        {
            "run_id": benchmark_run_id,
            "artifact_id": benchmark_artifact_id,
            "artifact_digest": benchmark_artifact_digest,
        }
        if benchmark_run_id is not None
        else None
    )
    if benchmark != expected_benchmark:
        fail("build closure benchmark identity does not match")
    validate_file_records(closure["files"], bundle, limits, "build")
    return closure


def validate_dmg_checksum(dmg: Path, checksum: Path) -> None:
    expected = f"{sha256_file(dmg)}  {dmg.name}\n"
    try:
        actual = read_bounded_regular_file(
            checksum,
            "DMG checksum",
            limit=1_024,
        ).decode("ascii")
    except UnicodeDecodeError as error:
        fail(f"cannot read DMG checksum: {error}")
    if actual != expected:
        fail("DMG checksum does not exactly name and hash the release image")


def vendored_viewer_source_identity() -> tuple[str, int]:
    root = REPOSITORY_ROOT / "ThirdParty/MetalSplatter"
    paths = [root / "Package.swift", root / "LICENSE"]
    for relative in ("MetalSplatter", "PLYIO/Sources", "SplatIO/Sources"):
        directory = root / relative
        if not directory.is_dir() or directory.is_symlink():
            fail(f"vendored MetalSplatter source directory is missing: {relative}")
        paths.extend(path for path in directory.rglob("*") if path.is_file())
    digest = hashlib.sha256()
    count = 0
    for path in sorted(set(paths), key=lambda value: value.relative_to(root).as_posix()):
        if path.is_symlink() or not path.is_file():
            fail("vendored MetalSplatter source closure contains an unsafe entry")
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(path)))
        count += 1
    if count < 4:
        fail("vendored MetalSplatter source closure is unexpectedly small")
    return digest.hexdigest(), count


def validate_provenance_shape(
    payload: dict[str, Any],
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    release_mode: str = "development-unsigned",
) -> None:
    require_exact_keys(
        payload,
        {
            "schemaVersion",
            "appVersion",
            "toolchainVersion",
            "releaseMode",
            "bundleIdentifier",
            "createdAt",
            "source",
            "sourceDependencies",
            "supplyChain",
            "artifacts",
        },
        "release provenance",
    )
    expected = {
        "schemaVersion": 2,
        "appVersion": app_version,
        "toolchainVersion": toolchain_version,
        "releaseMode": release_mode,
        "bundleIdentifier": "com.easysplat.app",
    }
    for key, value in expected.items():
        if payload[key] != value:
            fail(f"release provenance {key} is invalid")
    validate_utc_timestamp(payload["createdAt"], "release provenance createdAt")
    source = payload["source"]
    if not isinstance(source, dict):
        fail("release provenance source must be an object")
    require_exact_keys(
        source, {"buildCommand", "commit", "url"}, "release provenance source"
    )
    if source != {
        "buildCommand": "./scripts/release/build_app.sh",
        "commit": source_commit,
        "url": f"https://github.com/{source_repository}",
    }:
        fail("release provenance source identity is invalid")
    if (
        not isinstance(payload["sourceDependencies"], dict)
        or not isinstance(payload["supplyChain"], dict)
        or not isinstance(payload["artifacts"], dict)
    ):
        fail(
            "release provenance dependency, supply-chain, and artifact fields must be objects"
        )
    viewer_digest, viewer_file_count = vendored_viewer_source_identity()
    expected_source_dependencies = {
        "MetalSplatter": {
            "source": METALSPLATTER_SOURCE,
            "basedOnRevision": METALSPLATTER_BASE_REVISION,
            "vendoredTreeSHA256": viewer_digest,
            "sourceFileCount": viewer_file_count,
            "license": "MIT",
            "buildCommand": "./scripts/release/build_app.sh",
            "integration": "statically linked with EasySplat compatibility changes",
        }
    }
    if payload["sourceDependencies"] != expected_source_dependencies:
        fail("release provenance MetalSplatter identity is invalid")


def validate_provenance(
    path: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    dmg: Path,
    manifest: Path,
    release_mode: str = "development-unsigned",
) -> dict[str, Any]:
    payload = load_json(path, "release provenance", limit=8 * 1_024 * 1_024)
    validate_provenance_shape(
        payload,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        release_mode=release_mode,
    )
    artifacts = payload["artifacts"]
    # The toolchain ships inside the app, so the disk image is the only
    # published artifact; the closure sections still describe every embedded file.
    expected_keys = {"dmg"}
    if set(artifacts) != expected_keys:
        fail("release provenance artifact allowlist is invalid")
    for identifier, row in artifacts.items():
        if not isinstance(row, dict):
            fail(f"release provenance artifact {identifier} must be an object")
        require_exact_keys(
            row, {"downloadURL", "file", "sha256", "size"}, f"artifact {identifier}"
        )
        if not isinstance(row["file"], str) or Path(row["file"]).name != row["file"]:
            fail(f"artifact {identifier} filename is invalid")
        if not isinstance(row["sha256"], str) or not SHA256.fullmatch(row["sha256"]):
            fail(f"artifact {identifier} digest is invalid")
        if not isinstance(row["size"], int) or not (
            0 < row["size"] <= MAX_RELEASE_ASSET_BYTES
        ):
            fail(f"artifact {identifier} size is invalid")
        expected_prefix = f"https://github.com/{source_repository}/releases/download/"
        if not isinstance(row["downloadURL"], str) or not row["downloadURL"].startswith(
            expected_prefix
        ):
            fail(f"artifact {identifier} URL is invalid")
    local_artifacts = {
        "dmg": (dmg, dmg.name, MAX_RELEASE_ASSET_BYTES),
    }
    for identifier, (
        local_path,
        expected_filename,
        maximum_size,
    ) in local_artifacts.items():
        row = artifacts[identifier]
        snapshot = snapshot_bounded_regular_file(
            local_path,
            f"release provenance {identifier}",
            limit=maximum_size,
            capture_bytes=False,
        )
        if (
            row["file"] != expected_filename
            or row["size"] != snapshot.size_bytes
            or row["sha256"] != snapshot.sha256
        ):
            fail(f"release provenance {identifier} does not match the build bundle")
    expected_download_urls = {
        "dmg": (
            f"https://github.com/{source_repository}/releases/download/"
            f"v{urllib.parse.quote(app_version, safe='.-')}/{dmg.name}"
        ),
    }
    for identifier, expected_url in expected_download_urls.items():
        if artifacts[identifier]["downloadURL"] != expected_url:
            fail(f"release provenance {identifier} release URL is invalid")
    return payload


def spdx_component_id(component_id: str) -> str:
    label = re.sub(r"[^A-Za-z0-9.-]+", "-", component_id).strip("-") or "item"
    digest = hashlib.sha256(component_id.encode("utf-8")).hexdigest()[:8]
    return f"SPDXRef-Package-Component-{label}-{digest}"


def spdx_component_external_refs(component: dict[str, Any]) -> list[dict[str, str]]:
    source = component["source"]
    revision = component["revision"]
    references = [
        {
            "referenceCategory": "OTHER",
            "referenceType": "vcs",
            "referenceLocator": f"{source}#{revision}",
        }
    ]
    parsed = urllib.parse.urlparse(source)
    parts = [part for part in parsed.path.removesuffix(".git").split("/") if part]
    purl = ""
    if parsed.hostname == "github.com" and len(parts) == 2:
        purl = (
            f"pkg:github/{urllib.parse.quote(parts[0])}/{urllib.parse.quote(parts[1])}"
            f"@{urllib.parse.quote(revision, safe='.-:')}"
        )
    elif component["id"].startswith("python:"):
        purl = (
            f"pkg:pypi/{urllib.parse.quote(component['name'].lower())}"
            f"@{urllib.parse.quote(component['version'])}"
        )
    elif component["id"].startswith("homebrew:"):
        purl = (
            f"pkg:brew/{urllib.parse.quote(component['name'])}"
            f"@{urllib.parse.quote(component['version'])}"
        )
    if purl:
        references.insert(
            0,
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": purl,
            },
        )
    return references


def spdx_component_checksum(
    component: dict[str, Any], files: dict[str, dict[str, Any]]
) -> str:
    rows = [files[path] for path in component["files"]]
    material: Any = rows or {
        key: component[key]
        for key in ("id", "version", "revision", "source", "license", "licenseFiles")
    }
    return hashlib.sha256(canonical_json_bytes(material)).hexdigest()


def expected_spdx_document(
    *,
    provenance: dict[str, Any],
    license_closure: dict[str, Any],
    licenses_name: str,
) -> dict[str, Any]:
    source = provenance["source"]
    artifacts = provenance["artifacts"]
    viewer = provenance["sourceDependencies"]["MetalSplatter"]
    component_payload = license_closure["components"]
    components = {component["id"]: component for component in component_payload["components"]}
    files = {row["path"]: row for row in component_payload["files"]}
    archive_rows = {
        archive["id"]: archive["entries"]
        for archive in license_closure["archives"]["embedded"]
    }
    app_id = "SPDXRef-Package-EasySplat"
    viewer_id = "SPDXRef-Package-MetalSplatter"
    artifact_ids = {
        "dmg": "SPDXRef-Package-DiskImage",
        "core": "SPDXRef-Package-Toolchain-Core",
    }
    component_ids = {
        component_id: spdx_component_id(component_id) for component_id in components
    }

    app_purl = (
        f"pkg:github/dud8/EasySplat@{urllib.parse.quote(source['commit'])}"
        if source["url"].rstrip("/").removesuffix(".git")
        == "https://github.com/dud8/EasySplat"
        else f"pkg:generic/EasySplat@{urllib.parse.quote(provenance['appVersion'])}"
    )
    packages: list[dict[str, Any]] = [
        {
            "SPDXID": app_id,
            "name": "EasySplat",
            "versionInfo": provenance["appVersion"],
            "packageFileName": artifacts["dmg"]["file"],
            "downloadLocation": artifacts["dmg"]["downloadURL"],
            "homepage": source["url"],
            "sourceInfo": f"Build command: {source['buildCommand']}",
            "filesAnalyzed": False,
            "checksums": [
                {"algorithm": "SHA256", "checksumValue": artifacts["dmg"]["sha256"]}
            ],
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright (c) 2026 EasySplat contributors",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": app_purl,
                }
            ],
        },
        {
            "SPDXID": viewer_id,
            "name": "MetalSplatter",
            "versionInfo": viewer["basedOnRevision"],
            "downloadLocation": viewer["source"],
            "homepage": viewer["source"],
            "sourceInfo": (
                f"Based on upstream revision {viewer['basedOnRevision']} with reviewed EasySplat "
                f"compatibility changes; vendored source closure contains "
                f"{viewer['sourceFileCount']} files; build command: {viewer['buildCommand']}."
            ),
            "filesAnalyzed": False,
            "checksums": [
                {
                    "algorithm": "SHA256",
                    "checksumValue": viewer["vendoredTreeSHA256"],
                }
            ],
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright information is provided by MetalSplatter/LICENSE.",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": (
                        f"pkg:github/scier/MetalSplatter@{viewer['basedOnRevision']}"
                    ),
                },
                {
                    "referenceCategory": "OTHER",
                    "referenceType": "vcs",
                    "referenceLocator": f"{viewer['source']}#{viewer['basedOnRevision']}",
                },
            ],
        },
    ]
    artifact_licenses = {
        "dmg": "LicenseRef-EasySplat-Toolchain-Closure",
    }
    for identifier in ("dmg",):
        artifact = artifacts[identifier]
        license_id = artifact_licenses[identifier]
        packages.append(
            {
                "SPDXID": artifact_ids[identifier],
                "name": f"EasySplat-{identifier}",
                "versionInfo": provenance["toolchainVersion"],
                "packageFileName": artifact["file"],
                "downloadLocation": artifact["downloadURL"],
                "filesAnalyzed": False,
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": artifact["sha256"]}
                ],
                "licenseConcluded": license_id,
                "licenseDeclared": license_id,
                "copyrightText": (
                    "Copyright information is provided by the declared license files."
                ),
            }
        )
    # The embedded toolchain is a package in its own right: it has no file of its
    # own, so it is identified by the closure digest the app carries.
    packages.append(
        {
            "SPDXID": artifact_ids["core"],
            "name": "EasySplat-toolchain",
            "versionInfo": provenance["toolchainVersion"],
            "downloadLocation": "NONE",
            "sourceInfo": "Embedded in the application bundle.",
            "filesAnalyzed": False,
            "checksums": [
                {
                    "algorithm": "SHA256",
                    "checksumValue": provenance["supplyChain"]["componentsSHA256"],
                }
            ],
            "licenseConcluded": "LicenseRef-EasySplat-Toolchain-Closure",
            "licenseDeclared": "LicenseRef-EasySplat-Toolchain-Closure",
            "copyrightText": (
                "Copyright information is provided by the declared license files."
            ),
        }
    )
    for component_id in sorted(components):
        component = components[component_id]
        closure_checksum = spdx_component_checksum(component, files)
        packages.append(
            {
                "SPDXID": component_ids[component_id],
                "name": component["name"],
                "versionInfo": component["version"],
                "downloadLocation": component.get("artifact") or component["source"],
                "homepage": component["source"],
                "sourceInfo": (
                    f"Pinned revision: {component['revision']}; "
                    f"component closure SHA-256: {closure_checksum}; "
                    f"build command: {component['buildCommand']}"
                ),
                "filesAnalyzed": False,
                "checksums": [
                    {
                        "algorithm": "SHA256",
                        "checksumValue": component.get("artifactSha256")
                        or closure_checksum,
                    }
                ],
                "licenseConcluded": component["license"],
                "licenseDeclared": component["license"],
                "copyrightText": (
                    "Copyright information is provided by the declared license files."
                ),
                "externalRefs": spdx_component_external_refs(component),
            }
        )

    relationships: list[dict[str, str]] = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": app_id,
        },
        {
            "spdxElementId": app_id,
            "relationshipType": "STATIC_LINK",
            "relatedSpdxElement": viewer_id,
        },
    ]
    for identifier in ("dmg",):
        relationships.append(
            {
                "spdxElementId": app_id,
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": artifact_ids[identifier],
            }
        )
    for identifier in ("core",):
        # A shared licence can be attributed to a component the app does not
        # otherwise carry; the file ships, but there is no package to relate it to.
        owners = sorted({
            row["component"]
            for row in archive_rows[identifier]
            if row["component"] in component_ids
        })
        for owner in owners:
            relationships.append(
                {
                    "spdxElementId": artifact_ids[identifier],
                    "relationshipType": "CONTAINS",
                    "relatedSpdxElement": component_ids[owner],
                }
            )
    for component_id in sorted(components):
        component = components[component_id]
        for dependency in component["dependencies"]:
            relationships.append(
                {
                    "spdxElementId": component_ids[component_id],
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": component_ids[dependency],
                }
            )
        for target in component.get("incorporatedInto", []):
            relationships.append(
                {
                    "spdxElementId": component_ids[target],
                    "relationshipType": "STATIC_LINK",
                    "relatedSpdxElement": component_ids[component_id],
                }
            )
    relationships.sort(
        key=lambda row: (
            row["spdxElementId"],
            row["relationshipType"],
            row["relatedSpdxElement"],
        )
    )

    license_ids = {"LicenseRef-EasySplat-Toolchain-Closure"}
    for component in components.values():
        license_ids.update(re.findall(r"LicenseRef-[A-Za-z0-9.-]+", component["license"]))
    extracted = [
        {
            "licenseId": identifier,
            "name": identifier.removeprefix("LicenseRef-").replace("-", " "),
            "extractedText": (
                f"Exact license texts and mappings are distributed in {licenses_name}; "
                "see Toolchain/supply-chain/components.json."
            ),
        }
        for identifier in sorted(license_ids)
    ]
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"EasySplat-{provenance['appVersion']}",
        "documentNamespace": (
            f"{source['url'].removesuffix('.git').rstrip('/')}/spdx/"
            f"{source['commit']}/{urllib.parse.quote(provenance['appVersion'], safe='.-')}"
        ),
        "creationInfo": {
            "created": provenance["createdAt"],
            "creators": ["Tool: EasySplat generate_release_metadata.py"],
        },
        "packages": packages,
        "relationships": relationships,
        "hasExtractedLicensingInfos": extracted,
    }


def validate_spdx(
    path: Path,
    *,
    provenance: dict[str, Any],
    license_closure: dict[str, Any],
    licenses_name: str,
) -> None:
    payload = load_json(path, "SPDX document", limit=64 * 1_024 * 1_024)
    require_exact_keys(
        payload,
        {
            "SPDXID",
            "spdxVersion",
            "dataLicense",
            "name",
            "documentNamespace",
            "creationInfo",
            "packages",
            "relationships",
            "hasExtractedLicensingInfos",
        },
        "SPDX document",
    )
    expected_name = f"EasySplat-{provenance['appVersion']}-licenses.zip"
    if licenses_name != expected_name:
        fail("SPDX license archive identity is invalid")
    expected = expected_spdx_document(
        provenance=provenance,
        license_closure=license_closure,
        licenses_name=licenses_name,
    )
    for field, label in (
        ("creationInfo", "creation information"),
        ("packages", "package closure"),
        ("relationships", "relationship closure"),
        ("hasExtractedLicensingInfos", "extracted-license closure"),
    ):
        if canonical_json_bytes(payload[field]) != canonical_json_bytes(expected[field]):
            fail(f"SPDX {label} does not match the validated release closure")
    remaining = {
        key: value
        for key, value in payload.items()
        if key
        not in {
            "creationInfo",
            "packages",
            "relationships",
            "hasExtractedLicensingInfos",
        }
    }
    expected_remaining = {
        key: value
        for key, value in expected.items()
        if key
        not in {
            "creationInfo",
            "packages",
            "relationships",
            "hasExtractedLicensingInfos",
        }
    }
    if canonical_json_bytes(remaining) != canonical_json_bytes(expected_remaining):
        fail("SPDX document identity does not match the validated release closure")


def safe_zip_name(raw: str, label: str) -> str:
    if not raw or "\\" in raw or "\x00" in raw:
        fail(f"unsafe {label}: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"unsafe {label}: {raw!r}")
    return path.as_posix()


def zip_entry_type(info: zipfile.ZipInfo) -> int:
    return stat.S_IFMT(info.external_attr >> 16)


def validate_open_zip(
    archive: zipfile.ZipFile,
    *,
    label: str,
    allowed_prefixes: tuple[str, ...],
    required_files: set[str],
    maximum_expanded_size: int = 2 * 1_024 * 1_024 * 1_024,
    maximum_entry_size: int = 1_024 * 1_024 * 1_024,
    maximum_entries: int = 4_096,
) -> dict[str, zipfile.ZipInfo]:
    total = 0
    entries: dict[str, zipfile.ZipInfo] = {}
    infos = archive.infolist()
    if len(infos) > maximum_entries:
        fail(f"{label} exceeds its entry count limit")
    validate_zip_structure(archive, infos, label=label)
    for info in infos:
        name = safe_zip_name(info.filename.rstrip("/"), f"{label} entry")
        if name in entries:
            fail(f"{label} contains duplicate entry {name}")
        if not any(
            name == prefix.rstrip("/")
            or (prefix.endswith("/") and name.startswith(prefix))
            for prefix in allowed_prefixes
        ):
            fail(f"{label} contains unallowlisted entry {name}")
        kind = zip_entry_type(info)
        if info.is_dir():
            if kind not in {0, stat.S_IFDIR}:
                fail(f"{label} directory has an invalid type: {name}")
        elif kind not in {0, stat.S_IFREG}:
            fail(f"{label} contains a link or special file: {name}")
        if info.flag_bits & 0x1:
            fail(f"{label} contains an encrypted entry: {name}")
        if info.file_size < 0 or info.file_size > maximum_entry_size:
            fail(f"{label} entry exceeds its size limit: {name}")
        total += info.file_size
        if total > maximum_expanded_size:
            fail(f"{label} expands beyond its size limit")
        entries[name] = info
    missing = required_files - set(entries)
    if missing:
        fail(f"{label} is missing required files: {sorted(missing)}")
    for required in sorted(required_files):
        info = entries[required]
        if info.is_dir() or zip_entry_type(info) not in {0, stat.S_IFREG} or info.file_size == 0:
            fail(f"{label} required file must be a nonempty regular file: {required}")
    return entries


def read_zip_bytes(
    stream: BinaryIO,
    size: int,
    label: str,
) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        fail(f"{label} has a truncated ZIP structure")
    return data


def validate_zip_structure(
    archive: zipfile.ZipFile,
    infos: list[zipfile.ZipInfo],
    *,
    label: str,
) -> None:
    stream = archive.fp
    if stream is None:
        fail(f"{label} has no open ZIP descriptor")
    original_offset = 0
    try:
        original_offset = stream.tell()
        stream.seek(0, os.SEEK_END)
        archive_size = stream.tell()
        if archive_size < 22:
            fail(f"{label} has an invalid ZIP structure")
        stream.seek(archive_size - 22)
        end_record = read_zip_bytes(stream, 22, label)
        (
            signature,
            disk_number,
            central_disk,
            disk_entry_count,
            entry_count,
            central_size,
            central_offset,
            comment_size,
        ) = struct.unpack("<4s4H2LH", end_record)
        if (
            signature != b"PK\x05\x06"
            or disk_number != 0
            or central_disk != 0
            or disk_entry_count != entry_count
            or entry_count != len(infos)
            or entry_count == 0xFFFF
            or central_size == 0xFFFFFFFF
            or central_offset == 0xFFFFFFFF
            or comment_size != 0
            or archive.comment
            or archive.start_dir != central_offset
            or central_offset + central_size != archive_size - 22
        ):
            fail(f"{label} has an invalid ZIP structure")

        local_cursor = 0
        for info in sorted(infos, key=lambda candidate: candidate.header_offset):
            if (
                info.header_offset != local_cursor
                or info.flag_bits != 0
                or info.extra
                or info.comment
                or info.compress_type
                not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
            ):
                fail(f"{label} has unbound ZIP metadata")
            try:
                encoded_name = info.filename.encode("ascii")
            except UnicodeEncodeError:
                fail(f"{label} contains a non-ASCII ZIP entry")
            stream.seek(local_cursor)
            local_header = read_zip_bytes(stream, 30, label)
            (
                local_signature,
                _extract_version,
                local_flags,
                local_compression,
                _modified_time,
                _modified_date,
                local_crc,
                local_compressed_size,
                local_file_size,
                local_name_size,
                local_extra_size,
            ) = struct.unpack("<4s5H3L2H", local_header)
            local_name = read_zip_bytes(stream, local_name_size, label)
            local_extra = read_zip_bytes(stream, local_extra_size, label)
            if (
                local_signature != b"PK\x03\x04"
                or local_flags != info.flag_bits
                or local_compression != info.compress_type
                or local_crc != info.CRC
                or local_compressed_size != info.compress_size
                or local_file_size != info.file_size
                or local_name != encoded_name
                or local_extra
            ):
                fail(f"{label} has an invalid local ZIP record")
            local_cursor = (
                local_cursor
                + 30
                + local_name_size
                + local_extra_size
                + info.compress_size
            )
        if local_cursor != central_offset:
            fail(f"{label} has unbound bytes before its central directory")

        central_cursor = central_offset
        for info in infos:
            stream.seek(central_cursor)
            central_header = read_zip_bytes(stream, 46, label)
            (
                central_signature,
                created_version,
                extracted_version,
                central_flags,
                central_compression,
                _modified_time,
                _modified_date,
                central_crc,
                central_compressed_size,
                central_file_size,
                central_name_size,
                central_extra_size,
                central_comment_size,
                central_disk_number,
                central_internal_attr,
                central_external_attr,
                local_offset,
            ) = struct.unpack("<4s6H3L5H2L", central_header)
            central_name = read_zip_bytes(stream, central_name_size, label)
            central_extra = read_zip_bytes(stream, central_extra_size, label)
            central_comment = read_zip_bytes(stream, central_comment_size, label)
            try:
                encoded_name = info.filename.encode("ascii")
            except UnicodeEncodeError:
                fail(f"{label} contains a non-ASCII ZIP entry")
            if (
                central_signature != b"PK\x01\x02"
                or created_version & 0xFF != info.create_version
                or created_version >> 8 != info.create_system
                or extracted_version != info.extract_version
                or central_flags != info.flag_bits
                or central_compression != info.compress_type
                or central_crc != info.CRC
                or central_compressed_size != info.compress_size
                or central_file_size != info.file_size
                or central_name != encoded_name
                or central_extra
                or central_comment
                or central_disk_number != 0
                or central_internal_attr != info.internal_attr
                or central_external_attr != info.external_attr
                or local_offset != info.header_offset
            ):
                fail(f"{label} has an invalid central ZIP record")
            central_cursor += (
                46
                + central_name_size
                + central_extra_size
                + central_comment_size
            )
        if central_cursor != archive_size - 22:
            fail(f"{label} has unbound bytes in its central directory")
    except (OSError, struct.error) as error:
        fail(f"cannot inspect {label} ZIP structure: {error}")
    finally:
        try:
            stream.seek(original_offset)
        except OSError:
            pass


@contextlib.contextmanager
def open_zip_from_descriptor(
    descriptor: int,
    label: str,
    *,
    maximum_entries: int = 4_096,
) -> Iterator[zipfile.ZipFile]:
    try:
        archive_size = os.fstat(descriptor).st_size
        if archive_size < 22:
            fail(f"{label} has an invalid ZIP structure")
        end_record = os.pread(descriptor, 22, archive_size - 22)
    except OSError as error:
        fail(f"cannot preflight {label}: {error}")
    if len(end_record) != 22:
        fail(f"{label} has a truncated ZIP structure")
    try:
        (
            signature,
            disk_number,
            central_disk,
            disk_entry_count,
            entry_count,
            central_size,
            central_offset,
            comment_size,
        ) = struct.unpack("<4s4H2LH", end_record)
    except struct.error as error:
        fail(f"cannot preflight {label}: {error}")
    if (
        signature != b"PK\x05\x06"
        or disk_number != 0
        or central_disk != 0
        or disk_entry_count != entry_count
        or entry_count == 0xFFFF
        or central_size == 0xFFFFFFFF
        or central_offset == 0xFFFFFFFF
        or comment_size != 0
        or central_offset + central_size != archive_size - 22
    ):
        fail(f"{label} has an invalid ZIP structure")
    if entry_count > maximum_entries:
        fail(f"{label} exceeds its entry count limit")
    try:
        duplicate = os.dup(descriptor)
    except OSError as error:
        fail(f"cannot duplicate {label} descriptor: {error}")
    stream = os.fdopen(duplicate, "rb")
    try:
        try:
            archive = zipfile.ZipFile(stream)
        except (OSError, zipfile.BadZipFile, RuntimeError) as error:
            fail(f"cannot inspect {label}: {error}")
        try:
            yield archive
        finally:
            archive.close()
    finally:
        stream.close()


def validate_zip_descriptor(
    descriptor: int,
    *,
    label: str,
    allowed_prefixes: tuple[str, ...],
    required_files: set[str],
    maximum_expanded_size: int = 2 * 1_024 * 1_024 * 1_024,
    maximum_entry_size: int = 1_024 * 1_024 * 1_024,
    maximum_entries: int = 4_096,
) -> dict[str, zipfile.ZipInfo]:
    with open_zip_from_descriptor(
        descriptor,
        label,
        maximum_entries=maximum_entries,
    ) as archive:
        return validate_open_zip(
            archive,
            label=label,
            allowed_prefixes=allowed_prefixes,
            required_files=required_files,
            maximum_expanded_size=maximum_expanded_size,
            maximum_entry_size=maximum_entry_size,
            maximum_entries=maximum_entries,
        )


def validate_zip(
    path: Path,
    *,
    label: str,
    allowed_prefixes: tuple[str, ...],
    required_files: set[str],
    maximum_expanded_size: int = 2 * 1_024 * 1_024 * 1_024,
    maximum_entry_size: int = 1_024 * 1_024 * 1_024,
    maximum_archive_size: int = MAX_RELEASE_ASSET_BYTES,
    maximum_entries: int = 4_096,
) -> dict[str, zipfile.ZipInfo]:
    with open_bounded_regular_file(
        path,
        label,
        limit=maximum_archive_size,
    ) as (descriptor, _identity):
        return validate_zip_descriptor(
            descriptor,
            label=label,
            allowed_prefixes=allowed_prefixes,
            required_files=required_files,
            maximum_expanded_size=maximum_expanded_size,
            maximum_entry_size=maximum_entry_size,
            maximum_entries=maximum_entries,
        )


def read_canonical_archive_json(
    archive: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    label: str,
    *,
    maximum_size: int = 64 * 1_024 * 1_024,
) -> tuple[dict[str, Any], bytes]:
    if info.file_size <= 0 or info.file_size > maximum_size:
        fail(f"{label} exceeds its size limit or is empty")
    try:
        raw = archive.read(info)
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (RuntimeError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    if raw != canonical_json_bytes(payload):
        fail(f"{label} is not canonical JSON")
    return payload, raw


def supply_chain_archive_for_path(path: str) -> str:
    archive_matches: list[str] = []
    if (
        path.startswith(("bin/", "lib/", "licenses/", "provenance/"))
        or path == "supply-chain/components.json"
        or path in {"msplat/build_info.json", "msplat/LICENSE"}
    ):
        archive_matches.append("core")
    if (
        path.startswith(
            (
                "da3_mps/bin/",
                "da3_mps/python/",
                "da3_mps/app/",
                "da3_mps/vendor/",
                "da3_mps/licenses/",
                "da3_mps/models/DA3-BASE/",
            )
        )
        or path == "da3_mps/build_info.json"
    ):
        archive_matches.append("geometry-da3-base")
    if path.startswith("da3_mps/models/DA3-SMALL/"):
        archive_matches.append("geometry-da3-small")
    if len(archive_matches) != 1:
        fail(f"toolchain closure path has no unique production archive: {path}")
    return archive_matches[0]


def validate_open_license_archive(
    archive: zipfile.ZipFile,
    provenance: dict[str, Any],
    manifest: dict[str, Any],
    *,
    toolchain_version: str,
) -> dict[str, Any]:
    entries = validate_open_zip(
        archive,
        label="license archive",
        allowed_prefixes=(
            "EasySplat/",
            "MetalSplatter/",
            "Toolchain/",
            "toolchain-closure.json",
        ),
        required_files={
            "EasySplat/LICENSE",
            "EasySplat/NOTICE.md",
            "MetalSplatter/LICENSE",
            "Toolchain/supply-chain/components.json",
            "toolchain-closure.json",
        },
        maximum_expanded_size=1_024 * 1_024 * 1_024,
        maximum_entry_size=256 * 1_024 * 1_024,
    )
    try:
        components_payload, components_raw = read_canonical_archive_json(
            archive,
            entries["Toolchain/supply-chain/components.json"],
            "toolchain component closure",
            maximum_size=16 * 1_024 * 1_024,
        )
        archive_closure, _ = read_canonical_archive_json(
            archive,
            entries["toolchain-closure.json"],
            "toolchain archive closure",
            maximum_size=1 * 1_024 * 1_024,
        )
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        fail(f"cannot read license archive closure: {error}")

    require_exact_keys(
        components_payload,
        {"schemaVersion", "toolchainVersion", "components", "files"},
        "toolchain component closure",
    )
    component_rows = components_payload["components"]
    file_rows = components_payload["files"]
    if (
        components_payload["schemaVersion"] != 1
        or components_payload["toolchainVersion"] != toolchain_version
        or not isinstance(component_rows, list)
        or not component_rows
        or not isinstance(file_rows, list)
        or not file_rows
    ):
        fail("toolchain component closure schema or contents are invalid")

    components: dict[str, dict[str, Any]] = {}
    component_ids: list[str] = []
    component_required = {
        "id",
        "name",
        "type",
        "version",
        "revision",
        "source",
        "buildCommand",
        "license",
        "linkage",
        "licenseFiles",
        "dependencies",
        "files",
    }
    component_optional = {
        "artifact",
        "artifactSha256",
        "incorporatedInto",
        "sourceArtifacts",
    }
    for index, component in enumerate(component_rows):
        if not isinstance(component, dict):
            fail(f"toolchain component {index} must be an object")
        if not component_required.issubset(component) or not set(component).issubset(
            component_required | component_optional
        ):
            fail(f"toolchain component {index} has invalid fields")
        component_id = component["id"]
        if (
            not isinstance(component_id, str)
            or not component_id
            or component_id in components
        ):
            fail("toolchain component identity is invalid")
        for field in (
            "name",
            "type",
            "version",
            "revision",
            "source",
            "buildCommand",
            "license",
            "linkage",
        ):
            if not isinstance(component[field], str) or not component[field]:
                fail(f"toolchain component {component_id} {field} is invalid")
        validate_https_url(
            component["source"], f"toolchain component {component_id} source"
        )
        for field in ("licenseFiles", "dependencies", "files"):
            values = component[field]
            if (
                not isinstance(values, list)
                or any(not isinstance(value, str) or not value for value in values)
                or values != sorted(set(values))
            ):
                fail(f"toolchain component {component_id} {field} is invalid")
        if not component["licenseFiles"]:
            fail(f"toolchain component {component_id} has no license files")
        incorporated = component.get("incorporatedInto", [])
        if (
            not isinstance(incorporated, list)
            or any(not isinstance(value, str) or not value for value in incorporated)
            or incorporated != sorted(set(incorporated))
        ):
            fail(f"toolchain component {component_id} incorporatedInto is invalid")
        artifact = component.get("artifact")
        artifact_sha = component.get("artifactSha256")
        if (artifact is None) != (artifact_sha is None) or (
            artifact_sha is not None
            and (not isinstance(artifact_sha, str) or not SHA256.fullmatch(artifact_sha))
        ):
            fail(f"toolchain component {component_id} artifact identity is invalid")
        if artifact is not None:
            validate_https_url(
                artifact, f"toolchain component {component_id} artifact"
            )
        source_artifacts = component.get("sourceArtifacts")
        if component["type"] == "model" and source_artifacts is None:
            fail(f"toolchain component {component_id} sourceArtifacts are missing")
        if source_artifacts is not None:
            if component["type"] != "model" or not isinstance(source_artifacts, list) or not source_artifacts:
                fail(f"toolchain component {component_id} sourceArtifacts are invalid")
            artifact_names: list[str] = []
            artifact_urls: set[str] = set()
            for artifact_index, source_artifact in enumerate(source_artifacts):
                label = (
                    f"toolchain component {component_id} "
                    f"sourceArtifacts[{artifact_index}]"
                )
                if not isinstance(source_artifact, dict):
                    fail(f"{label} must be an object")
                require_exact_keys(
                    source_artifact,
                    {"name", "url", "sha256", "size"},
                    label,
                )
                artifact_name = source_artifact["name"]
                if (
                    not isinstance(artifact_name, str)
                    or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", artifact_name)
                    is None
                ):
                    fail(f"{label} name is invalid")
                artifact_url = validate_https_url(
                    source_artifact["url"], f"{label} url"
                )
                parsed_artifact_url = urllib.parse.urlparse(artifact_url)
                if (
                    parsed_artifact_url.query
                    or parsed_artifact_url.fragment
                    or any(ord(character) < 0x20 for character in artifact_url)
                ):
                    fail(f"{label} url must be a credential-free HTTPS URL")
                if (
                    not isinstance(source_artifact["sha256"], str)
                    or not SHA256.fullmatch(source_artifact["sha256"])
                    or type(source_artifact["size"]) is not int
                    or source_artifact["size"] <= 0
                ):
                    fail(f"{label} digest or size is invalid")
                artifact_names.append(artifact_name)
                if artifact_url in artifact_urls:
                    fail(f"toolchain component {component_id} sourceArtifacts are duplicated")
                artifact_urls.add(artifact_url)
            if artifact_names != sorted(set(artifact_names)):
                fail(
                    f"toolchain component {component_id} sourceArtifacts are "
                    "duplicated or unsorted"
                )
        components[component_id] = component
        component_ids.append(component_id)
    if component_ids != sorted(component_ids):
        fail("toolchain components must be sorted by id")

    files: dict[str, dict[str, Any]] = {}
    owned_files: dict[str, list[str]] = {component_id: [] for component_id in components}
    file_paths: list[str] = []
    for index, row in enumerate(file_rows):
        if not isinstance(row, dict):
            fail(f"toolchain closure file {index} must be an object")
        if not {"component", "kind", "path"}.issubset(row):
            fail(f"toolchain closure file {index} is incomplete")
        path_value = safe_zip_name(row["path"], "toolchain closure path")
        component_id = row["component"]
        kind = row["kind"]
        if path_value in files or component_id not in components:
            fail(f"toolchain closure file ownership is invalid: {path_value}")
        expected_keys = {"component", "kind", "path"}
        if kind in {"file", "mach-o"}:
            expected_keys |= {"sha256", "size"}
            if kind == "mach-o":
                expected_keys.add("dependencies")
            if (
                not isinstance(row.get("sha256"), str)
                or not SHA256.fullmatch(row["sha256"])
                or type(row.get("size")) is not int
                or row["size"] < 0
            ):
                fail(f"toolchain closure file digest or size is invalid: {path_value}")
        elif kind == "symlink":
            expected_keys.add("target")
            if not isinstance(row.get("target"), str) or not row["target"]:
                fail(f"toolchain closure symlink target is invalid: {path_value}")
        else:
            fail(f"toolchain closure file kind is invalid: {path_value}")
        if set(row) != expected_keys:
            fail(f"toolchain closure file fields are invalid: {path_value}")
        files[path_value] = row
        file_paths.append(path_value)
        owned_files[component_id].append(path_value)
    if file_paths != sorted(file_paths):
        fail("toolchain closure files must be sorted by path")

    mapped_license_paths: set[str] = set()
    for component_id, component in components.items():
        if component["files"] != sorted(owned_files[component_id]):
            fail(f"toolchain component {component_id} file ownership differs")
        if component["type"] == "model":
            source_artifacts = component["sourceArtifacts"]
            source_artifact_names = {
                source_artifact["name"] for source_artifact in source_artifacts
            }
            expected_source_artifact_names = {"config.json", "model.safetensors"}
            model_license_roots = {
                PurePosixPath(license_path).parent
                for license_path in component["licenseFiles"]
                if PurePosixPath(license_path).name == "LICENSE"
            }
            if (
                source_artifact_names != expected_source_artifact_names
                or len(model_license_roots) != 1
            ):
                fail(
                    f"toolchain component {component_id} model payload source "
                    "closure is invalid"
                )
            model_root = next(iter(model_license_roots))
            expected_payload_paths = {
                (model_root / artifact_name).as_posix()
                for artifact_name in expected_source_artifact_names
            }
            relevant_payload_paths = {
                owned_path
                for owned_path in owned_files[component_id]
                if PurePosixPath(owned_path).parent == model_root
                and PurePosixPath(owned_path).name
                not in {"LICENSE", "easysplat_model_info.json"}
            }
            if relevant_payload_paths != expected_payload_paths:
                fail(
                    f"toolchain component {component_id} model payload file "
                    "closure is invalid"
                )
            for source_artifact in source_artifacts:
                payload_path = (model_root / source_artifact["name"]).as_posix()
                payload_row = files.get(payload_path)
                if (
                    payload_row is None
                    or payload_row["component"] != component_id
                    or payload_row["kind"] != "file"
                    or payload_row["sha256"] != source_artifact["sha256"]
                    or payload_row["size"] != source_artifact["size"]
                ):
                    fail(
                        f"toolchain component {component_id} model payload "
                        f"does not match sourceArtifacts: {source_artifact['name']}"
                    )
        for relation in (*component["dependencies"], *component.get("incorporatedInto", [])):
            if relation not in components or relation == component_id:
                fail(f"toolchain component {component_id} has an invalid relationship")
        for license_path in component["licenseFiles"]:
            file_row = files.get(license_path)
            archived_license = entries.get(f"Toolchain/{license_path}")
            if (
                file_row is None
                or file_row["kind"] == "symlink"
                or archived_license is None
                or archived_license.is_dir()
                or archived_license.file_size == 0
            ):
                fail(f"toolchain component {component_id} license closure is incomplete")
            mapped_license_paths.add(license_path)
    fixed_legal_sources = {
        "EasySplat/LICENSE": REPOSITORY_ROOT / "LICENSE",
        "EasySplat/NOTICE.md": REPOSITORY_ROOT / "NOTICE.md",
        "MetalSplatter/LICENSE": (
            REPOSITORY_ROOT / "ThirdParty/MetalSplatter/LICENSE"
        ),
    }
    expected_archive_entries = {
        *fixed_legal_sources,
        "Toolchain/supply-chain/components.json",
        "toolchain-closure.json",
        *(f"Toolchain/{path}" for path in mapped_license_paths),
    }
    if set(entries) != expected_archive_entries:
        fail("license archive does not contain the exact legal-file closure")
    try:
        for archive_name, source_path in fixed_legal_sources.items():
            archived = archive.read(entries[archive_name])
            trusted = read_bounded_regular_file(
                source_path,
                f"trusted public legal file {archive_name}",
                limit=8 * 1_024 * 1_024,
            )
            if archived != trusted:
                fail(
                    "license archive public legal file differs from its "
                    f"trusted source: {archive_name}"
                )
        for license_path in sorted(mapped_license_paths):
            file_row = files[license_path]
            archived_license = entries[f"Toolchain/{license_path}"]
            with archive.open(archived_license) as stream:
                digest = sha256_stream(stream, limit=256 * 1_024 * 1_024)
            if (
                archived_license.file_size != file_row["size"]
                or digest != file_row["sha256"]
            ):
                fail(f"toolchain license bytes differ from the signed closure: {license_path}")
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        fail(f"cannot verify toolchain license bytes: {error}")

    components_sha = hashlib.sha256(components_raw).hexdigest()
    core_components = [
        component
        for component in manifest.get("components", [])
        if isinstance(component, dict) and component.get("name") == "macos-arm64-core"
    ]
    if len(core_components) != 1 or core_components[0].get("criticalFileHashes", {}).get(
        "supply-chain/components.json"
    ) != components_sha:
        fail("license archive does not match the signed component closure")
    supply_chain = provenance.get("supplyChain")
    if supply_chain != {
        "schemaVersion": 1,
        "componentsSHA256": components_sha,
        "componentCount": len(components),
        "fileCount": len(files),
    }:
        fail("release provenance supply-chain closure is invalid")

    require_exact_keys(
        archive_closure,
        {"schemaVersion", "toolchainVersion", "componentsSHA256", "embedded"},
        "toolchain archive closure",
    )
    archive_rows = archive_closure["embedded"]
    # The app carries one closure; nothing is published on its own any more, so
    # the rows describe embedded content rather than downloadable archives.
    expected_archive_ids = ("core",)
    if (
        archive_closure["schemaVersion"] != 2
        or archive_closure["toolchainVersion"] != toolchain_version
        or archive_closure["componentsSHA256"] != components_sha
        or not isinstance(archive_rows, list)
        or len(archive_rows) != len(expected_archive_ids)
    ):
        fail("toolchain archive closure identity is invalid")
    provenance_artifacts = provenance.get("artifacts")
    if not isinstance(provenance_artifacts, dict):
        fail("release provenance artifacts are invalid")
    for archive_row, archive_id in zip(archive_rows, expected_archive_ids):
        if not isinstance(archive_row, dict):
            fail("toolchain archive closure row must be an object")
        require_exact_keys(
            archive_row,
            {"id", "entries"},
            f"toolchain archive closure {archive_id}",
        )
        expected_entries = [
            row
            for row in file_rows
            if supply_chain_archive_for_path(row["path"]) == archive_id
        ]
        if archive_row["id"] != archive_id or archive_row["entries"] != expected_entries:
            fail(f"toolchain archive closure differs for {archive_id}")
    return {
        "components": components_payload,
        "archives": archive_closure,
        "component_ids": tuple(component_ids),
    }


def validate_license_archive(
    path: Path,
    provenance: dict[str, Any],
    manifest: dict[str, Any],
    *,
    toolchain_version: str,
) -> dict[str, Any]:
    with open_bounded_regular_file(
        path,
        "license archive",
        limit=MAX_RELEASE_ASSET_BYTES,
    ) as (descriptor, _identity):
        with open_zip_from_descriptor(
            descriptor,
            "license archive",
            maximum_entries=2_048,
        ) as archive:
            return validate_open_license_archive(
                archive,
                provenance,
                manifest,
                toolchain_version=toolchain_version,
            )


def run_static(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    if not arguments or arguments[0] not in SYSTEM_TOOLS.values():
        fail("publication verifier attempted a non-static subprocess")
    try:
        return subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except subprocess.CalledProcessError as error:
        output = "\n".join(
            value
            for value in (error.stdout, error.stderr)
            if isinstance(value, str) and value
        )
        suffix = f"\n{output[:64 * 1_024]}" if output else ""
        fail(
            f"static inspection command failed: {arguments[0]}: "
            f"exit {error.returncode}{suffix}"
        )
    except subprocess.TimeoutExpired as error:
        output = "\n".join(
            value.decode("utf-8", errors="replace")
            if isinstance(value, bytes)
            else value
            for value in (error.stdout, error.stderr)
            if isinstance(value, (bytes, str)) and value
        )
        suffix = f"\n{output[:64 * 1_024]}" if output else ""
        fail(
            f"static inspection command timed out: {arguments[0]}{suffix}"
        )
    except OSError as error:
        fail(f"static inspection command failed: {arguments[0]}: {error}")


def plist_value(path: Path, key: str) -> str | None:
    result = run_static(
        [SYSTEM_TOOLS["plutil"], "-extract", key, "raw", "-o", "-", str(path)]
    )
    value = result.stdout.strip()
    return value if value else None


def load_plist(path: Path, label: str) -> dict[str, Any]:
    result = run_static(
        [SYSTEM_TOOLS["plutil"], "-convert", "json", "-o", "-", str(path)]
    )
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, RecursionError) as error:
        fail(f"{label} is not a property-list object: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a property-list object")
    return payload


def expected_app_plist(
    app_version: str, release_mode: str = "development-unsigned"
) -> tuple[tuple[str, str], ...]:
    base_version = app_version.split("-", 1)[0]
    return (
        ("CFBundleExecutable", "EasySplatApp"),
        ("CFBundleIdentifier", "com.easysplat.app"),
        ("CFBundleName", "EasySplat"),
        ("CFBundlePackageType", "APPL"),
        ("CFBundleShortVersionString", base_version),
        ("CFBundleVersion", base_version),
        ("EasySplatReleaseChannel", release_mode),
        ("EasySplatReleaseVersion", app_version),
        ("LSMinimumSystemVersion", "15.0"),
    )


def validate_app_plist(
    path: Path, *, app_version: str, release_mode: str = "development-unsigned"
) -> None:
    payload = load_plist(path, "app Info.plist")
    for key, expected in expected_app_plist(app_version, release_mode):
        actual = payload.get(key)
        if actual != expected:
            fail(f"Info.plist {key} is {actual!r}, expected {expected!r}")
    for forbidden in ("LSUIElement", "LSBackgroundOnly"):
        if forbidden in payload:
            fail(f"Info.plist must not contain {forbidden}")


def validate_regular_tree(
    root: Path,
    *,
    maximum_bytes: int,
    maximum_entries: int = 100_000,
) -> None:
    total = 0
    entry_count = 0
    for path in root.rglob("*"):
        entry_count += 1
        if entry_count > maximum_entries:
            fail("app bundle exceeds its entry count limit")
        metadata = path.lstat()
        if path.is_symlink():
            fail(f"app bundle contains a symbolic link: {path.relative_to(root)}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"app bundle contains a special file: {path.relative_to(root)}")
        if metadata.st_nlink != 1:
            fail(f"app bundle contains a hard-linked file: {path.relative_to(root)}")
        total += metadata.st_size
        if total > maximum_bytes:
            fail("app bundle exceeds its static inspection size limit")


def parse_uuid(output: str, label: str) -> str:
    lines = [line for line in output.splitlines() if line]
    if len(lines) != 1:
        fail(f"{label} must contain exactly one Mach-O UUID")
    match = UUID_LINE.fullmatch(lines[0])
    if match is None:
        fail(f"{label} is not one arm64 Mach-O UUID")
    return match.group(1)


def validate_app_toolchain_resources(app: Path) -> None:
    """The app carries its tools; nothing in it may name a download."""
    stale = {
        path.relative_to(app).as_posix()
        for path in app.rglob("*")
        if path.name in APP_RETIRED_TOOLCHAIN_RESOURCE_NAMES
    }
    if stale:
        fail(f"app still carries a download-era toolchain resource: {sorted(stale)[0]}")
    if (app / "Contents/Resources/ToolchainBootstrap").exists():
        fail("app still carries a toolchain bootstrap directory")

    for relative in APP_BUNDLED_TOOLCHAIN_EXECUTABLES:
        helper = app / relative
        if helper.is_symlink() or not helper.is_file():
            fail(f"app is missing a bundled helper: {relative}")
        mode = helper.stat().st_mode
        if not mode & 0o111 or mode & 0o022:
            fail(f"bundled helper has an unsafe mode: {relative}")
    for relative in APP_BUNDLED_TOOLCHAIN_PAYLOAD:
        payload = app / relative
        if payload.is_symlink() or not payload.is_file() or payload.stat().st_size == 0:
            fail(f"app is missing bundled toolchain payload: {relative}")


def validate_app_bundle(
    app: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    toolchain_public_key: Path,
    release_mode: str = "development-unsigned",
) -> str:
    if app.is_symlink() or not app.is_dir():
        fail("DMG must contain a real EasySplat.app directory")
    contents = app / "Contents"
    expected = {"Helpers", "Info.plist", "MacOS", "Resources", "_CodeSignature"}
    if (
        not contents.is_dir()
        or {entry.name for entry in contents.iterdir()} != expected
    ):
        fail("app Contents allowlist is invalid")
    validate_regular_tree(app, maximum_bytes=4 * 1_024 * 1_024 * 1_024)
    validate_app_toolchain_resources(app)
    plist = contents / "Info.plist"
    executable = contents / "MacOS/EasySplatApp"
    if not executable.is_file() or executable.is_symlink():
        fail("app executable is missing")
    if {entry.name for entry in executable.parent.iterdir()} != {"EasySplatApp"}:
        fail("app MacOS directory contains an unexpected executable")
    validate_app_plist(plist, app_version=app_version, release_mode=release_mode)
    architectures = run_static(
        [SYSTEM_TOOLS["lipo"], "-archs", str(executable)]
    ).stdout.strip()
    if architectures != "arm64":
        fail("release app executable must be arm64-only")
    run_static([SYSTEM_TOOLS["codesign"], "--verify", "--deep", "--strict", str(app)])
    signing = run_static([SYSTEM_TOOLS["codesign"], "-dvvv", str(app)])
    details = signing.stdout + signing.stderr
    required_signing = ["Identifier=com.easysplat.app"]
    if release_mode == "development-unsigned":
        required_signing.extend(("Signature=adhoc", "TeamIdentifier=not set"))
    else:
        required_signing.extend(("flags=0x10000(runtime)", "TeamIdentifier="))
        if "Signature=adhoc" in details or "TeamIdentifier=not set" in details:
            fail("production app is not Developer ID signed")
    for required in required_signing:
        if required not in details:
            fail(f"{release_mode} signing state is missing {required}")
    return parse_uuid(
        run_static([SYSTEM_TOOLS["dwarfdump"], "--uuid", str(executable)]).stdout,
        "app executable",
    )


@contextlib.contextmanager
def mounted_dmg(path: Path) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(
        prefix="easysplat-publication-mount-"
    ) as temporary:
        mount = Path(temporary) / "volume"
        mount.mkdir()
        run_static([SYSTEM_TOOLS["hdiutil"], "verify", str(path)])
        attachment_devices: tuple[str, ...] = ()
        try:
            attachment = run_static(
                [
                    SYSTEM_TOOLS["hdiutil"],
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-noautoopen",
                    "-owners",
                    "off",
                    "-mountpoint",
                    str(mount),
                    str(path),
                ]
            )
            attachment_devices = hdiutil_device_nodes(
                attachment.stdout,
                attachment.stderr,
            )
        except BaseException as error:
            attachment_devices = hdiutil_device_nodes(str(error))
            detach_hdiutil_attachment(
                mount,
                attachment_devices,
                suppress_errors=True,
            )
            raise
        try:
            yield mount
        finally:
            detach_hdiutil_attachment(
                mount,
                attachment_devices,
                suppress_errors=False,
            )


def hdiutil_device_nodes(*outputs: str) -> tuple[str, ...]:
    nodes: list[str] = []
    seen: set[str] = set()
    pattern = re.compile(r"(?m)^(/dev/disk[0-9]+(?:s[0-9]+)*)[\t ]")
    for output in outputs:
        if not isinstance(output, str):
            continue
        for match in pattern.finditer(output):
            node = match.group(1)
            if node not in seen:
                seen.add(node)
                nodes.append(node)
    return tuple(nodes)


def detach_hdiutil_attachment(
    mount: Path,
    device_nodes: tuple[str, ...],
    *,
    suppress_errors: bool,
) -> None:
    failures: list[PublicationError] = []
    try:
        run_static([SYSTEM_TOOLS["hdiutil"], "detach", str(mount)])
        return
    except PublicationError as error:
        failures.append(error)
    ordered_nodes = sorted(
        device_nodes,
        key=lambda node: re.fullmatch(r"/dev/disk[0-9]+", node) is None,
    )
    for node in ordered_nodes:
        try:
            run_static([SYSTEM_TOOLS["hdiutil"], "detach", node])
            return
        except PublicationError as error:
            failures.append(error)
    if not suppress_errors and failures:
        raise failures[-1]


def validate_open_dsym_archive(
    archive: zipfile.ZipFile, app_binary: Path | str
) -> None:
    dwarf_name = "EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp"
    plist_name = "EasySplat.app.dSYM/Contents/Info.plist"
    relocation_name = (
        "EasySplat.app.dSYM/Contents/Resources/Relocations/"
        "aarch64/EasySplatApp.yml"
    )
    expected_directories = {
        "EasySplat.app.dSYM",
        "EasySplat.app.dSYM/Contents",
        "EasySplat.app.dSYM/Contents/Resources",
        "EasySplat.app.dSYM/Contents/Resources/DWARF",
        "EasySplat.app.dSYM/Contents/Resources/Relocations",
        "EasySplat.app.dSYM/Contents/Resources/Relocations/aarch64",
    }
    required_files = {dwarf_name, plist_name, relocation_name}
    entries = validate_open_zip(
        archive,
        label="dSYM archive",
        allowed_prefixes=("EasySplat.app.dSYM/",),
        required_files=required_files,
        maximum_expanded_size=2 * 1_024 * 1_024 * 1_024,
        maximum_entry_size=1_024 * 1_024 * 1_024,
        maximum_entries=16,
    )
    if set(entries) != required_files | expected_directories:
        fail("dSYM archive does not contain the exact debug-symbol closure")
    with tempfile.TemporaryDirectory(prefix="easysplat-publication-dsym-") as temporary:
        root = Path(temporary)
        extracted: dict[str, Path] = {}
        for name in sorted(required_files):
            info = entries[name]
            target = root / Path(name).name
            with archive.open(info) as source, target.open("xb") as destination:
                shutil.copyfileobj(source, destination, length=1_024 * 1_024)
            extracted[name] = target
        if plist_value(extracted[plist_name], "CFBundlePackageType") != "dSYM":
            fail("dSYM Info.plist package type is invalid")
        app_uuid = parse_uuid(
            run_static([SYSTEM_TOOLS["dwarfdump"], "--uuid", str(app_binary)]).stdout,
            "app executable",
        )
        dsym_uuid = parse_uuid(
            run_static(
                [SYSTEM_TOOLS["dwarfdump"], "--uuid", str(extracted[dwarf_name])]
            ).stdout,
            "dSYM",
        )
        if app_uuid != dsym_uuid:
            fail("dSYM UUID does not match the app executable")


def validate_dsym_archive(path: Path, app_binary: Path | str) -> None:
    with open_bounded_regular_file(
        path,
        "dSYM archive",
        limit=MAX_RELEASE_ASSET_BYTES,
    ) as (descriptor, _identity):
        with open_zip_from_descriptor(
            descriptor,
            "dSYM archive",
            maximum_entries=16,
        ) as archive:
            validate_open_dsym_archive(archive, app_binary)


# RFC 8032 verification. The release verifier intentionally carries no third-party runtime.
_Q = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _Q - 2, _Q)) % _Q
_I = pow(2, (_Q - 1) // 4, _Q)
_IDENTITY = (0, 1)


def _ed_xrecover(y: int, sign: int) -> int:
    xx = (y * y - 1) * pow(_D * y * y + 1, _Q - 2, _Q) % _Q
    x = pow(xx, (_Q + 3) // 8, _Q)
    if (x * x - xx) % _Q != 0:
        x = x * _I % _Q
    if (x * x - xx) % _Q != 0:
        fail("Ed25519 point is not on the curve")
    if x & 1 != sign:
        x = _Q - x
    return x


def _ed_decode(raw: bytes) -> tuple[int, int]:
    if len(raw) != 32:
        fail("Ed25519 point must be 32 bytes")
    encoded = int.from_bytes(raw, "little")
    sign = encoded >> 255
    y = encoded & ((1 << 255) - 1)
    if y >= _Q:
        fail("Ed25519 point encoding is not canonical")
    point = (_ed_xrecover(y, sign), y)
    if point[0] == 0 and sign:
        fail("Ed25519 point encoding is not canonical")
    return point


def _ed_add(left: tuple[int, int], right: tuple[int, int]) -> tuple[int, int]:
    x1, y1 = left
    x2, y2 = right
    product = _D * x1 * x2 * y1 * y2 % _Q
    x3 = (x1 * y2 + x2 * y1) * pow(1 + product, _Q - 2, _Q) % _Q
    y3 = (y1 * y2 + x1 * x2) * pow(1 - product, _Q - 2, _Q) % _Q
    return x3, y3


def _ed_scalar(point: tuple[int, int], scalar: int) -> tuple[int, int]:
    result = _IDENTITY
    addend = point
    while scalar:
        if scalar & 1:
            result = _ed_add(result, addend)
        addend = _ed_add(addend, addend)
        scalar >>= 1
    return result


_BASE = (_ed_xrecover(4 * pow(5, _Q - 2, _Q) % _Q, 0), 4 * pow(5, _Q - 2, _Q) % _Q)


def verify_ed25519(public_key: bytes, message: bytes, signature: bytes) -> bool:
    try:
        if len(public_key) != 32 or len(signature) != 64:
            return False
        encoded_r = signature[:32]
        scalar_s = int.from_bytes(signature[32:], "little")
        if scalar_s >= _L:
            return False
        public_point = _ed_decode(public_key)
        r_point = _ed_decode(encoded_r)
        if (
            _ed_scalar(public_point, 8) == _IDENTITY
            or _ed_scalar(r_point, 8) == _IDENTITY
        ):
            return False
        challenge = (
            int.from_bytes(
                hashlib.sha512(encoded_r + public_key + message).digest(), "little"
            )
            % _L
        )
        return _ed_scalar(_BASE, scalar_s) == _ed_add(
            r_point, _ed_scalar(public_point, challenge)
        )
    except PublicationError:
        return False


def decode_base64(value: str, label: str, expected_size: int) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        fail(f"{label} is not valid base64: {error}")
    if len(raw) != expected_size:
        fail(f"{label} must decode to {expected_size} bytes")
    return raw


def parse_semver(value: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None]:
    match = SEMVER.fullmatch(value)
    if match is None:
        fail(f"invalid semantic version: {value}")
    prerelease = match.group(4)
    build = match.group(5)
    for label, raw in (("prerelease", prerelease), ("build metadata", build)):
        if raw is not None and any(not identifier for identifier in raw.split(".")):
            fail(f"invalid semantic version {label}: {value}")
    identifiers = tuple(prerelease.split(".")) if prerelease is not None else None
    if identifiers is not None and any(
        identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0")
        for identifier in identifiers
    ):
        fail(f"invalid semantic version prerelease: {value}")
    return (
        (int(match.group(1)), int(match.group(2)), int(match.group(3))),
        identifiers,
    )


def compare_semver(left: str, right: str) -> int:
    left_core, left_prerelease = parse_semver(left)
    right_core, right_prerelease = parse_semver(right)
    if left_core != right_core:
        return -1 if left_core < right_core else 1
    if left_prerelease is None or right_prerelease is None:
        if left_prerelease is right_prerelease:
            return 0
        return 1 if left_prerelease is None else -1
    for left_identifier, right_identifier in zip(left_prerelease, right_prerelease):
        if left_identifier == right_identifier:
            continue
        left_numeric = left_identifier.isdigit()
        right_numeric = right_identifier.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_identifier) < int(right_identifier) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_identifier < right_identifier else 1
    if len(left_prerelease) == len(right_prerelease):
        return 0
    return -1 if len(left_prerelease) < len(right_prerelease) else 1


def validate_toolchain_manifest(
    path: Path,
    trust_root_path: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
) -> dict[str, Any]:
    manifest = load_json(path, "toolchain manifest", limit=8 * 1_024 * 1_024)
    require_exact_keys(
        manifest,
        {
            "schemaVersion",
            "toolchainAPI",
            "keyID",
            "version",
            "publishedAt",
            "appVersionRange",
            "components",
            "signatureEd25519",
        },
        "toolchain manifest",
    )
    if manifest["schemaVersion"] != 2 or manifest["toolchainAPI"] != 2:
        fail("toolchain manifest schema or API is invalid")
    if manifest["version"] != toolchain_version:
        fail("toolchain manifest version does not match the release")
    validate_utc_timestamp(manifest["publishedAt"], "toolchain manifest publishedAt")
    try:
        public_key_text = read_bounded_regular_file(
            trust_root_path,
            "tracked toolchain public key",
            limit=1_024,
        ).decode("ascii").strip()
    except UnicodeDecodeError as error:
        fail(f"toolchain public key is not ASCII: {error}")
    public_key = decode_base64(public_key_text, "toolchain public key", 32)
    if manifest["keyID"] != hashlib.sha256(public_key).hexdigest():
        fail("toolchain manifest key identifier is invalid")
    signature = decode_base64(manifest["signatureEd25519"], "toolchain signature", 64)
    unsigned = dict(manifest)
    unsigned["signatureEd25519"] = ""
    if not verify_ed25519(public_key, signature_json_bytes(unsigned), signature):
        fail("toolchain manifest signature is invalid")
    app_range = manifest["appVersionRange"]
    if not isinstance(app_range, dict):
        fail("toolchain app version range must be an object")
    require_exact_keys(
        app_range, {"minimum", "maximumExclusive"}, "toolchain app version range"
    )
    if compare_semver(app_version, app_range["minimum"]) < 0:
        fail("toolchain manifest does not support this app version")
    maximum = app_range["maximumExclusive"]
    if maximum is not None and compare_semver(app_version, maximum) >= 0:
        fail("toolchain manifest does not support this app version")
    components = manifest["components"]
    if not isinstance(components, list) or len(components) != 3:
        fail("toolchain manifest must contain the three release components")
    expected_names = {"macos-arm64-core", "geometry-da3-base", "geometry-da3-small"}
    seen: set[str] = set()
    for component in components:
        if not isinstance(component, dict):
            fail("toolchain component must be an object")
        require_exact_keys(
            component,
            {
                "name",
                "capabilities",
                "url",
                "sha256",
                "sizeBytes",
                "expandedSizeBytes",
                "expandedClosureSHA256",
                "contents",
                "criticalFileHashes",
                "dependencies",
                "requirement",
            },
            "toolchain component",
        )
        name = component["name"]
        if name not in expected_names or name in seen:
            fail("toolchain component set is invalid")
        seen.add(name)
        expected_file = {
            "macos-arm64-core": f"toolchain-macos-arm64-{toolchain_version}-core.zip",
            "geometry-da3-base": f"toolchain-geometry-da3-base-{toolchain_version}.zip",
            "geometry-da3-small": f"toolchain-geometry-da3-small-{toolchain_version}.zip",
        }[name]
        expected_url = (
            f"https://github.com/{source_repository}/releases/download/"
            f"toolchain-v{toolchain_version}/{expected_file}"
        )
        if component["url"] != expected_url:
            fail(f"toolchain component URL is invalid: {name}")
        if not isinstance(component["sha256"], str) or not SHA256.fullmatch(
            component["sha256"]
        ):
            fail(f"toolchain component digest is invalid: {name}")
        if not isinstance(component["expandedClosureSHA256"], str) or not SHA256.fullmatch(
            component["expandedClosureSHA256"]
        ):
            fail(f"toolchain expanded closure digest is invalid: {name}")
        if not isinstance(component["sizeBytes"], int) or not (
            0 < component["sizeBytes"] <= MAX_RELEASE_ASSET_BYTES
        ):
            fail(f"toolchain component size is invalid: {name}")
        if not isinstance(component["expandedSizeBytes"], int) or not (
            0 < component["expandedSizeBytes"] <= 16 * 1_024 * 1_024 * 1_024
        ):
            fail(f"toolchain expanded component size is invalid: {name}")
        contents = component["contents"]
        hashes = component["criticalFileHashes"]
        if (
            not isinstance(contents, list)
            or not contents
            or len(contents) != len(set(contents))
            or not isinstance(hashes, dict)
            or set(hashes) != set(contents)
            or any(not isinstance(value, str) or not SHA256.fullmatch(value) for value in hashes.values())
        ):
            fail(f"toolchain expanded file closure is invalid: {name}")
    if seen != expected_names:
        fail("toolchain component set is incomplete")
    return manifest


def positive_integer(value: Any, label: str) -> int:
    if type(value) is not int or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def validate_source_artifacts(
    value: Any, *, toolchain_version: str, label: str
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != 2:
        fail(f"{label} source artifact closure is invalid")
    expected_artifacts = (
        ("components", f"toolchain-components-{toolchain_version}"),
        ("signingRequest", f"toolchain-signing-request-{toolchain_version}"),
    )
    seen_artifact_ids: set[int] = set()
    validated: list[dict[str, Any]] = []
    for index, (artifact, (expected_kind, expected_name)) in enumerate(
        zip(value, expected_artifacts)
    ):
        if not isinstance(artifact, dict):
            fail(f"{label} source artifact must be an object")
        require_exact_keys(
            artifact,
            {
                "kind",
                "name",
                "artifactID",
                "artifactDigest",
                "payloadSHA256",
                "sizeBytes",
            },
            f"{label} sourceArtifacts[{index}]",
        )
        artifact_id = positive_integer(
            artifact["artifactID"], f"{label} sourceArtifacts[{index}].artifactID"
        )
        if artifact_id in seen_artifact_ids:
            fail(f"{label} reuses a source artifact")
        seen_artifact_ids.add(artifact_id)
        if (
            artifact["kind"] != expected_kind
            or artifact["name"] != expected_name
            or not isinstance(artifact["artifactDigest"], str)
            or not SHA256_DIGEST.fullmatch(artifact["artifactDigest"])
            or not isinstance(artifact["payloadSHA256"], str)
            or not SHA256.fullmatch(artifact["payloadSHA256"])
            or artifact["payloadSHA256"]
            != artifact["artifactDigest"].removeprefix("sha256:")
        ):
            fail(f"{label} source artifact identity is invalid")
        positive_integer(
            artifact["sizeBytes"], f"{label} sourceArtifacts[{index}].sizeBytes"
        )
        validated.append(dict(artifact))
    return validated


def validate_toolchain_release_request(
    path: Path,
    manifest: dict[str, Any],
    *,
    source_repository: str,
) -> tuple[dict[str, Any], str]:
    request, request_digest = load_compact_canonical_json_with_sha256(
        path, "toolchain release request", limit=8 * 1_024 * 1_024
    )
    require_exact_keys(
        request,
        {
            "schemaVersion",
            "sourceRepository",
            "sourceCommit",
            "manifestSHA256",
            "manifest",
        },
        "toolchain release request",
    )
    if (
        request["schemaVersion"] != 2
        or source_repository != CANONICAL_SOURCE_REPOSITORY
        or request["sourceRepository"] != source_repository
        or not isinstance(request["sourceCommit"], str)
        or not COMMIT.fullmatch(request["sourceCommit"])
    ):
        fail("toolchain release request source identity is invalid")
    unsigned_manifest = dict(manifest)
    unsigned_manifest["signatureEd25519"] = ""
    unsigned_digest = hashlib.sha256(
        signature_json_bytes(unsigned_manifest)
    ).hexdigest()
    if (
        request["manifest"] != unsigned_manifest
        or request["manifestSHA256"] != unsigned_digest
    ):
        fail("toolchain release request does not bind the unsigned manifest")
    return request, request_digest


def validate_toolchain_authority_envelope(
    path: Path,
    release_request_sha256: str,
    release_request: dict[str, Any],
    *,
    source_repository: str,
    toolchain_version: str,
) -> tuple[dict[str, Any], str]:
    envelope, envelope_digest = load_compact_canonical_json_with_sha256(
        path, "toolchain authority envelope", limit=64 * 1_024 * 1_024
    )
    require_exact_keys(
        envelope,
        {
            "schemaVersion",
            "sourceRepository",
            "sourceRepositoryID",
            "sourceCommit",
            "sourceWorkflowID",
            "sourceWorkflowPath",
            "sourceRunID",
            "sourceRunAttempt",
            "sourceArtifacts",
            "authorityRepository",
            "authorityRepositoryID",
            "authorityCommit",
            "authorityRunID",
            "authorityRunAttempt",
            "releaseTag",
            "sourceReleaseRequestSHA256",
            "unsignedManifestSHA256",
            "manifest",
        },
        "toolchain authority envelope",
    )
    if (
        envelope["schemaVersion"] != 1
        or envelope["sourceRepository"] != source_repository
        or envelope["sourceRepositoryID"] != CANONICAL_SOURCE_REPOSITORY_ID
        or envelope["sourceCommit"] != release_request["sourceCommit"]
        or envelope["sourceWorkflowID"] != CANONICAL_SOURCE_WORKFLOW_ID
        or envelope["sourceWorkflowPath"] != CANONICAL_SOURCE_WORKFLOW_PATH
        or envelope["authorityRepository"] != CANONICAL_AUTHORITY_REPOSITORY
        or envelope["authorityRepositoryID"] != CANONICAL_AUTHORITY_REPOSITORY_ID
        or envelope["releaseTag"] != f"toolchain-v{toolchain_version}"
    ):
        fail("toolchain authority envelope identity is invalid")
    if not isinstance(envelope["authorityCommit"], str) or not COMMIT.fullmatch(
        envelope["authorityCommit"]
    ):
        fail("toolchain authority envelope authorityCommit is invalid")
    for field in (
        "sourceRunID",
        "sourceRunAttempt",
        "authorityRunID",
        "authorityRunAttempt",
    ):
        positive_integer(envelope[field], f"toolchain authority envelope {field}")
    validate_source_artifacts(
        envelope["sourceArtifacts"],
        toolchain_version=toolchain_version,
        label="toolchain authority envelope",
    )
    if (
        envelope["sourceReleaseRequestSHA256"] != release_request_sha256
        or envelope["unsignedManifestSHA256"] != release_request["manifestSHA256"]
        or envelope["manifest"] != release_request["manifest"]
    ):
        fail("toolchain authority envelope does not bind the release request")
    return envelope, envelope_digest


def validate_toolchain_authority_receipt(
    path: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    trust_root_path: Path,
    *,
    source_repository: str,
    toolchain_version: str,
) -> dict[str, Any]:
    receipt = load_compact_canonical_json(path, "toolchain authority receipt")
    require_exact_keys(
        receipt,
        {
            "schemaVersion",
            "keyID",
            "sourceRepository",
            "sourceRepositoryID",
            "sourceCommit",
            "sourceWorkflowID",
            "sourceWorkflowPath",
            "sourceRunID",
            "sourceRunAttempt",
            "sourceArtifacts",
            "authorityRepository",
            "authorityRepositoryID",
            "authorityCommit",
            "authorityRunID",
            "authorityRunAttempt",
            "authorityEnvelopeSHA256",
            "sourceReleaseRequestSHA256",
            "unsignedManifestSHA256",
            "signedManifestFileSHA256",
            "releaseTag",
            "signedAt",
            "signatureEd25519",
        },
        "toolchain authority receipt",
    )
    if source_repository != CANONICAL_SOURCE_REPOSITORY:
        fail("toolchain authority is pinned to the canonical EasySplat repository")

    if (
        receipt["schemaVersion"] != 1
        or receipt["keyID"] != manifest["keyID"]
        or receipt["sourceRepository"] != source_repository
        or receipt["sourceRepositoryID"] != CANONICAL_SOURCE_REPOSITORY_ID
        or receipt["sourceWorkflowID"] != CANONICAL_SOURCE_WORKFLOW_ID
        or receipt["sourceWorkflowPath"] != CANONICAL_SOURCE_WORKFLOW_PATH
        or receipt["authorityRepository"] != CANONICAL_AUTHORITY_REPOSITORY
        or receipt["authorityRepositoryID"] != CANONICAL_AUTHORITY_REPOSITORY_ID
        or receipt["releaseTag"] != f"toolchain-v{toolchain_version}"
    ):
        fail("toolchain authority receipt identity is invalid")
    for field in ("sourceCommit", "authorityCommit"):
        if not isinstance(receipt[field], str) or not COMMIT.fullmatch(receipt[field]):
            fail(f"toolchain authority receipt {field} is invalid")
    for field in (
        "sourceRunID",
        "sourceRunAttempt",
        "authorityRunID",
        "authorityRunAttempt",
    ):
        positive_integer(receipt[field], f"toolchain authority receipt {field}")
    for field in (
        "authorityEnvelopeSHA256",
        "sourceReleaseRequestSHA256",
        "unsignedManifestSHA256",
        "signedManifestFileSHA256",
    ):
        if not isinstance(receipt[field], str) or not SHA256.fullmatch(receipt[field]):
            fail(f"toolchain authority receipt {field} is invalid")
    signed_at = receipt["signedAt"]
    if not isinstance(signed_at, str):
        fail("toolchain authority receipt signedAt is invalid")
    try:
        parsed_signed_at = datetime.strptime(signed_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        fail(f"toolchain authority receipt signedAt is invalid: {error}")
    if parsed_signed_at.strftime("%Y-%m-%dT%H:%M:%SZ") != signed_at:
        fail("toolchain authority receipt signedAt is not canonical UTC")

    validate_source_artifacts(
        receipt["sourceArtifacts"],
        toolchain_version=toolchain_version,
        label="toolchain authority receipt",
    )

    manifest_bytes = read_bounded_regular_file(
        manifest_path,
        "signed toolchain manifest",
        limit=8 * 1_024 * 1_024,
    )
    if manifest_bytes != signature_json_bytes(manifest):
        fail("signed toolchain manifest is not canonical compact JSON")
    unsigned_manifest = dict(manifest)
    unsigned_manifest["signatureEd25519"] = ""
    if (
        receipt["unsignedManifestSHA256"]
        != hashlib.sha256(signature_json_bytes(unsigned_manifest)).hexdigest()
        or receipt["signedManifestFileSHA256"]
        != hashlib.sha256(manifest_bytes).hexdigest()
    ):
        fail("toolchain authority receipt does not bind the signed manifest")

    try:
        public_key_text = read_bounded_regular_file(
            trust_root_path,
            "tracked toolchain public key",
            limit=1_024,
        ).decode("ascii").strip()
    except UnicodeDecodeError as error:
        fail(f"toolchain public key is not ASCII: {error}")
    public_key = decode_base64(public_key_text, "toolchain public key", 32)
    if receipt["keyID"] != hashlib.sha256(public_key).hexdigest():
        fail("toolchain authority receipt key identifier is invalid")
    signature = decode_base64(
        receipt["signatureEd25519"], "toolchain authority receipt signature", 64
    )
    unsigned_receipt = dict(receipt)
    unsigned_receipt["signatureEd25519"] = ""
    if not verify_ed25519(
        public_key,
        AUTHORITY_RECEIPT_SIGNATURE_DOMAIN + signature_json_bytes(unsigned_receipt),
        signature,
    ):
        fail("toolchain authority receipt signature is invalid")
    return receipt


def validate_toolchain_authority_closure(
    release_request_path: Path,
    envelope_path: Path,
    receipt_path: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    trust_root_path: Path,
    *,
    source_repository: str,
    toolchain_version: str,
) -> dict[str, dict[str, Any]]:
    request, request_digest = validate_toolchain_release_request(
        release_request_path,
        manifest,
        source_repository=source_repository,
    )
    envelope, envelope_digest = validate_toolchain_authority_envelope(
        envelope_path,
        request_digest,
        request,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
    )
    receipt = validate_toolchain_authority_receipt(
        receipt_path,
        manifest_path,
        manifest,
        trust_root_path,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
    )
    shared_fields = (
        "schemaVersion",
        "sourceRepository",
        "sourceRepositoryID",
        "sourceCommit",
        "sourceWorkflowID",
        "sourceWorkflowPath",
        "sourceRunID",
        "sourceRunAttempt",
        "sourceArtifacts",
        "authorityRepository",
        "authorityRepositoryID",
        "authorityCommit",
        "authorityRunID",
        "authorityRunAttempt",
        "releaseTag",
        "sourceReleaseRequestSHA256",
        "unsignedManifestSHA256",
    )
    if any(receipt[field] != envelope[field] for field in shared_fields):
        fail("toolchain authority receipt and envelope identity differ")
    if (
        receipt["sourceReleaseRequestSHA256"] != request_digest
        or receipt["authorityEnvelopeSHA256"] != envelope_digest
        or receipt["unsignedManifestSHA256"] != request["manifestSHA256"]
    ):
        fail("toolchain authority receipt does not bind its provenance closure")
    return {"request": request, "envelope": envelope, "receipt": receipt}


def api_json(url: str, token: str) -> dict[str, Any]:
    if not token:
        fail("a read-only GitHub token is required for publication verification")
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "EasySplat-publication-verifier",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) > 16 * 1_024 * 1_024:
                fail("GitHub API response is too large")
            raw = response.read(16 * 1_024 * 1_024 + 1)
    except (OSError, urllib.error.URLError, ValueError) as error:
        fail(f"GitHub API request failed: {error}")
    if len(raw) > 16 * 1_024 * 1_024:
        fail("GitHub API response is too large")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"GitHub API returned invalid JSON: {error}")
    if not isinstance(payload, dict):
        fail("GitHub API response must be an object")
    return payload


def validate_remote_toolchain_assets(
    manifest_path: Path,
    release_request_path: Path,
    authority_envelope_path: Path,
    authority_receipt_path: Path,
    benchmark_evidence_path: Path,
    manifest: dict[str, Any],
    *,
    source_repository: str,
    toolchain_version: str,
    authority_source_commit: str,
    github_token: str,
) -> None:
    quoted_repo = "/".join(
        urllib.parse.quote(part, safe="") for part in source_repository.split("/")
    )
    quoted_tag = urllib.parse.quote(f"toolchain-v{toolchain_version}", safe="")
    release = api_json(
        f"https://api.github.com/repos/{quoted_repo}/releases/tags/{quoted_tag}",
        github_token,
    )
    if (
        release.get("tag_name") != f"toolchain-v{toolchain_version}"
        or release.get("target_commitish") != authority_source_commit
        or release.get("draft") is not False
        or release.get("prerelease") is not False
        or release.get("immutable") is not True
    ):
        fail("published toolchain release identity is invalid")
    assets = release.get("assets")
    if not isinstance(assets, list):
        fail("published toolchain release assets are unavailable")
    by_name: dict[str, dict[str, Any]] = {}
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            fail("published toolchain asset record is invalid")
        name = asset["name"]
        if name in by_name:
            fail(f"published toolchain release has duplicate asset {name}")
        by_name[name] = asset
    local_assets = {
        "manifest.json": (manifest_path, 8 * 1_024 * 1_024),
        TOOLCHAIN_AUTHORITY_RECEIPT_NAME: (
            authority_receipt_path,
            1 * 1_024 * 1_024,
        ),
        TOOLCHAIN_AUTHORITY_ENVELOPE_NAME: (
            authority_envelope_path,
            64 * 1_024 * 1_024,
        ),
        TOOLCHAIN_BENCHMARK_EVIDENCE_NAME: (
            benchmark_evidence_path,
            8 * 1_024 * 1_024,
        ),
        "toolchain-release-request.json": (
            release_request_path,
            8 * 1_024 * 1_024,
        ),
    }
    expected: dict[str, tuple[int, str, str]] = {}
    for name, (path, limit) in local_assets.items():
        snapshot = snapshot_bounded_regular_file(
            path,
            f"local toolchain release asset {name}",
            limit=limit,
            capture_bytes=False,
        )
        expected[name] = (
            snapshot.size_bytes,
            snapshot.sha256,
            f"https://github.com/{source_repository}/releases/download/"
            f"toolchain-v{toolchain_version}/{name}",
        )
    for component in manifest["components"]:
        name = Path(component["url"]).name
        expected[name] = (component["sizeBytes"], component["sha256"], component["url"])
    for name, (size, digest, download_url) in expected.items():
        asset = by_name.get(name)
        if asset is None:
            fail(f"published toolchain asset is missing: {name}")
        if asset.get("size") != size or asset.get("digest") != f"sha256:{digest}":
            fail(f"published toolchain asset size or digest differs: {name}")
        if asset.get("browser_download_url") != download_url:
            fail(f"published toolchain asset URL differs: {name}")
    if set(by_name) != set(expected):
        fail("published toolchain release asset closure is not exact")


def full_toolchain_identity(manifest: dict[str, Any]) -> str:
    component_fields = (
        "name",
        "capabilities",
        "url",
        "sha256",
        "sizeBytes",
        "expandedSizeBytes",
        "expandedClosureSHA256",
        "contents",
        "criticalFileHashes",
        "dependencies",
        "requirement",
    )
    components = sorted(
        (
            {field: component[field] for field in component_fields}
            for component in manifest["components"]
        ),
        key=lambda component: component["name"],
    )
    closure = {
        "schema_version": 2,
        "toolchain_api": 2,
        "key_id": manifest["keyID"],
        "version": manifest["version"],
        "app_version_range": {
            "minimum": manifest["appVersionRange"]["minimum"],
            "maximum_exclusive": manifest["appVersionRange"]["maximumExclusive"],
        },
        "signature_ed25519": manifest["signatureEd25519"],
        "components": components,
        "installed_artifacts": {
            component["name"]: component["sha256"] for component in components
        },
        "installed_capabilities": sorted(
            {
                capability
                for component in components
                for capability in component["capabilities"]
            }
        ),
    }
    digest = hashlib.sha256()
    for value in (
        b"easysplat-benchmark-toolchain-v2",
        signature_json_bytes(closure),
    ):
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)
    return "sha256:" + digest.hexdigest()


def validate_release_notes(
    path: Path, *, app_version: str, release_mode: str = "development-unsigned"
) -> None:
    try:
        text = read_bounded_regular_file(
            path,
            "release notes",
            limit=64 * 1_024,
        ).decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"release notes are invalid: {error}")
    if release_mode == "production":
        expected = (
            f"EasySplat {app_version} is a Developer ID-signed and notarized release.\n"
            "Install the Developer ID-signed, notarized, and stapled DMG on an Apple "
            "Silicon Mac running macOS 15 or later.\n"
            "\n"
            "EasySplat turns video, photo folders, or mixed inputs into static 3D "
            "Gaussian splats locally. Input media stays on your Mac. Capture-aware "
            "native COLMAP reconstruction uses FAISS matching, and the native Metal "
            "trainer writes a validated PLY. When the geometry is conclusive, "
            "EasySplat aligns the scene upright. The viewer supports orbit, pan, zoom, "
            "fit, reset, export, and system Share. Work can stop and resume at durable "
            "stages. EasySplat has no cloud processing, telemetry, or analytics.\n"
            "\n"
            "One reconstruction runs at a time. PLY is the only export format. Moving "
            "subjects, reflections, water, foliage, and large lighting changes can "
            "leave artifacts.\n"
            "\n"
            "Release files include the DMG SHA-256 checksum, provenance record, SPDX "
            "SBOM, third-party license bundle, and dSYM archive.\n"
        )
    else:
        expected = (
            f"EasySplat {app_version} is an unsigned developer build, not a release artifact.\n"
            "macOS will require the user to confirm opening an app from an unidentified developer.\n"
        )
    if text != expected:
        fail(f"release notes do not exactly describe the {release_mode}")


def validate_signed_artifact_evidence(
    artifact: Path,
    *,
    artifact_type: str,
    signing_receipt: Path,
    notarization_receipt: Path,
) -> dict[str, str]:
    initial = load_json(
        signing_receipt,
        f"{artifact_type} signing receipt",
        limit=16 * 1_024 * 1_024,
    )
    fingerprint = initial.get("identityFingerprintSHA1")
    team_id = initial.get("teamID")
    if (
        not isinstance(fingerprint, str)
        or re.fullmatch(r"[0-9A-F]{40}", fingerprint) is None
        or not isinstance(team_id, str)
        or re.fullmatch(r"[A-Z0-9]{10}", team_id) is None
    ):
        fail(f"{artifact_type} signing receipt has an invalid Developer ID identity")
    try:
        signing = SIGNING_HELPER.validate_signing_receipt(
            signing_receipt.resolve(strict=True),
            kind=artifact_type,
            identity_fingerprint=fingerprint,
            team_id=team_id,
        )
        notarization = NOTARY_HELPER.validate_notarization_receipt(
            notarization_receipt.resolve(strict=True),
            artifact.resolve(strict=True),
            artifact_type,
            signing_receipt=signing_receipt.resolve(strict=True),
        )
    except (OSError, SIGNING_HELPER.SigningError, NOTARY_HELPER.ReceiptError) as error:
        fail(f"{artifact_type} signing/notarization evidence is invalid: {error}")
    if (
        signing.get("identityFingerprintSHA1") != fingerprint
        or signing.get("teamID") != team_id
    ):
        fail(f"{artifact_type} signing identity changed during verification")
    signing_payload, signing_sha256 = load_json_with_sha256(
        signing_receipt,
        f"{artifact_type} signing receipt",
        limit=16 * 1_024 * 1_024,
    )
    notarization_payload, notarization_sha256 = load_json_with_sha256(
        notarization_receipt,
        f"{artifact_type} notarization receipt",
        limit=4 * 1_024 * 1_024,
    )
    if signing_payload != signing or notarization_payload != notarization:
        fail(f"{artifact_type} signing/notarization evidence changed")
    post_staple_sha256 = notarization.get("postStapleSHA256")
    if not isinstance(post_staple_sha256, str) or not SHA256.fullmatch(
        post_staple_sha256
    ):
        fail(f"{artifact_type} notarization receipt has no final artifact digest")
    return {
        "identity_fingerprint_sha1": fingerprint,
        "team_id": team_id,
        "signing_receipt_sha256": signing_sha256,
        "notarization_receipt_sha256": notarization_sha256,
        "post_staple_sha256": post_staple_sha256,
    }


def validate_benchmark_suite(
    path: Path,
    *,
    app_version: str,
    source_commit: str,
    toolchain_identity: str,
) -> dict[str, Any]:
    payload = load_json(path, "verified benchmark suite", limit=128 * 1_024 * 1_024)
    expected_keys = {
        "schema_version",
        "run_id",
        "started_at_utc",
        "ended_at_utc",
        "profile",
        "status",
        "blocking_reasons",
        "failures",
        "scene_results",
        "aggregates",
        "machine",
        "app_version",
        "toolchain_identity",
        "thresholds_digest",
        "corpus_digest",
        "git",
        "raw_evidence_retention",
        "missing_requirements",
    }
    require_exact_keys(payload, expected_keys, "verified benchmark suite")
    if payload["schema_version"] != 2 or payload["profile"] != "release":
        fail("verified benchmark suite schema or profile is invalid")
    try:
        suite_run_id = uuid.UUID(payload["run_id"])
    except (AttributeError, TypeError, ValueError):
        fail("verified benchmark suite run ID is invalid")
    if (
        str(suite_run_id) != payload["run_id"]
        or suite_run_id.version != 5
        or suite_run_id.variant != uuid.RFC_4122
    ):
        fail("verified benchmark suite run ID is invalid")
    if (
        payload["status"] != "passed"
        or payload["blocking_reasons"] != []
        or payload["failures"] != []
    ):
        fail("verified benchmark suite did not pass")
    if payload["app_version"] != app_version:
        fail("verified benchmark suite app version differs")
    if payload["git"] != {"commit": source_commit, "dirty": False}:
        fail("verified benchmark suite source identity differs")
    if payload["raw_evidence_retention"] != "excluded":
        fail("verified benchmark suite must exclude raw evidence")
    missing = payload["missing_requirements"]
    if not isinstance(missing, dict) or any(
        value not in (None, []) for value in missing.values()
    ):
        fail("verified benchmark suite still has missing requirements")
    if payload["toolchain_identity"] != toolchain_identity:
        fail("verified benchmark suite used a different signed toolchain closure")
    return payload


def load_json_with_sha256(
    path: Path, label: str, *, limit: int
) -> tuple[dict[str, Any], str]:
    raw = read_bounded_regular_file(path, label, limit=limit)
    try:
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    if raw != canonical_json_bytes(payload):
        fail(f"{label} is not canonical JSON")
    return payload, hashlib.sha256(raw).hexdigest()


def require_positive_decimal_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.isdecimal() or int(value) <= 0:
        fail(f"{label} must be a positive decimal string")
    return value


def build_publication_manifest_payload(
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    release_mode: str,
    benchmark_run_id: str | None,
    benchmark_artifact_id: str | None,
    benchmark_artifact_digest: str | None,
    benchmark_suite_sha256: str | None,
    files: list[dict[str, Any]],
    signed_build: dict[str, str] | None,
) -> dict[str, Any]:
    validate_release_mode(release_mode)
    benchmark_values = (
        benchmark_run_id,
        benchmark_artifact_id,
        benchmark_artifact_digest,
        benchmark_suite_sha256,
    )
    if any(value is not None for value in benchmark_values):
        if any(value is None for value in benchmark_values):
            fail("benchmark publication identity must be supplied as one complete set")
        assert benchmark_suite_sha256 is not None
        if not SHA256.fullmatch(benchmark_suite_sha256):
            fail("benchmark suite digest must be 64 lowercase hex")
    payload: dict[str, Any] = {
        "schema_version": 1,
        "app_version": app_version,
        "toolchain_version": toolchain_version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "tag": tag,
        "release_mode": release_mode,
        "benchmark": (
            {
                "run_id": benchmark_run_id,
                "artifact_id": benchmark_artifact_id,
                "artifact_digest": benchmark_artifact_digest,
                "suite_sha256": benchmark_suite_sha256,
            }
            if benchmark_run_id is not None
            else None
        ),
        "files": files,
    }
    if release_mode == "production":
        if signed_build is None:
            fail("production publication requires signed build identity")
        require_exact_keys(
            signed_build,
            {
                "artifact_id",
                "artifact_digest",
                "workflow_run_id",
                "workflow_run_attempt",
                "source_commit",
            },
            "signed build record",
        )
        require_positive_decimal_string(
            signed_build["artifact_id"], "signed build artifact ID"
        )
        require_positive_decimal_string(
            signed_build["workflow_run_id"], "signed build workflow run ID"
        )
        require_positive_decimal_string(
            signed_build["workflow_run_attempt"],
            "signed build workflow run attempt",
        )
        if (
            signed_build["source_commit"] != source_commit
            or not isinstance(signed_build["artifact_digest"], str)
            or not SHA256_DIGEST.fullmatch(signed_build["artifact_digest"])
        ):
            fail("signed build record identity is invalid")
        payload["signed_build"] = signed_build
    elif signed_build is not None:
        fail("development-unsigned publication must not include signed build identity")
    return payload


def validate_publication_output_root(root: Path) -> None:
    if root.exists():
        if root.is_symlink() or not root.is_dir() or any(root.iterdir()):
            fail("publication output must be absent or an empty real directory")
    else:
        root.mkdir(parents=True)


def rename_directory_exclusive(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> None:
    try:
        rename_entry_exclusive_raw(
            parent_descriptor,
            source_name,
            destination_name,
        )
        return
    except OSError as error:
        if error.errno == errno.EEXIST:
            fail("publication output appeared during the transaction")
        if error.errno == errno.EINVAL:
            fail("publication transaction has an invalid directory name")
        fail(
            "cannot commit publication transaction exclusively: "
            f"{error}"
        )


@contextlib.contextmanager
def transactional_publication_output(
    output: Path,
    *,
    expected_names: set[str],
    commit_bindings: dict[str, BoundedRegularFileCopy],
) -> Iterator[Path]:
    if not expected_names or any(
        not name or Path(name).name != name for name in expected_names
    ):
        fail("publication transaction has invalid expected file names")
    if output.exists() or output.is_symlink():
        fail("publication output must not exist before the transaction")
    parent = output.parent
    try:
        parent_metadata = parent.lstat()
    except OSError as error:
        fail(f"cannot inspect publication output parent: {error}")
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent.is_symlink()
        or parent_metadata.st_uid != os.geteuid()
        or parent_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail(
            "publication output parent must be an owned, private real directory"
        )
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory_flag = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory_flag is None:
        fail("publication transaction directory safety flags are unavailable")
    try:
        parent_descriptor = os.open(
            parent,
            os.O_RDONLY
            | nofollow
            | directory_flag
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened_parent = bounded_regular_file_identity(
            os.fstat(parent_descriptor)
        )
    except OSError as error:
        fail(f"cannot pin publication output parent: {error}")
    if opened_parent != bounded_regular_file_identity(parent_metadata):
        os.close(parent_descriptor)
        fail("publication output parent changed while it was opened")
    staging_descriptor: int | None = None
    try:
        staging = Path(
            tempfile.mkdtemp(
                prefix=f".{output.name}.publication-",
                dir=parent,
            )
        )
        staging_descriptor = os.open(
            staging.name,
            os.O_RDONLY
            | nofollow
            | directory_flag
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        os.fchmod(staging_descriptor, 0o700)
        staging_metadata = os.fstat(staging_descriptor)
        staging_path_metadata = os.stat(
            staging.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        staging_identity = bounded_regular_file_identity(staging_metadata)
        if (
            staging_identity
            != bounded_regular_file_identity(staging_path_metadata)
            or not stat.S_ISDIR(staging_metadata.st_mode)
            or staging_metadata.st_uid != os.geteuid()
            or staging_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            fail("publication transaction staging directory is unsafe")
    except (OSError, PublicationError) as error:
        if staging_descriptor is not None:
            os.close(staging_descriptor)
        os.close(parent_descriptor)
        fail(f"cannot create private publication transaction: {error}")
    renamed = False
    try:
        yield staging
        frozen_bindings = dict(commit_bindings)
        if set(frozen_bindings) != expected_names or any(
            not isinstance(binding, BoundedRegularFileCopy)
            for binding in frozen_bindings.values()
        ):
            fail("publication transaction commit binding is incomplete")
        try:
            staged_names = set(os.listdir(staging_descriptor))
        except OSError as error:
            fail(f"cannot inspect completed publication transaction: {error}")
        if staged_names != expected_names:
            fail("publication transaction does not contain its exact file closure")

        with contextlib.ExitStack() as opened_files:
            for name in sorted(expected_names):
                expected = frozen_bindings[name]
                descriptor, identity = opened_files.enter_context(
                    open_bounded_regular_file(
                        name,
                        f"publication commit file {name}",
                        limit=max(expected.snapshot.size_bytes, 1),
                        directory_descriptor=staging_descriptor,
                    )
                )
                if identity != expected.destination_identity:
                    fail(f"publication commit file identity changed: {name}")
                snapshot = snapshot_opened_regular_file(
                    descriptor,
                    identity,
                    f"publication commit file {name}",
                    capture_bytes=False,
                )
                if snapshot != expected.snapshot:
                    fail(f"publication commit file digest changed: {name}")

            try:
                os.fsync(staging_descriptor)
                current_parent_metadata = os.stat(parent, follow_symlinks=False)
                current_staging = bounded_regular_file_identity(
                    os.stat(
                        staging.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                )
            except OSError as error:
                fail(f"cannot revalidate publication transaction: {error}")
            current_parent = bounded_regular_file_identity(
                current_parent_metadata
            )
            if (
                current_parent.device,
                current_parent.inode,
                current_parent.mode,
                current_parent_metadata.st_uid,
            ) != (
                opened_parent.device,
                opened_parent.inode,
                opened_parent.mode,
                parent_metadata.st_uid,
            ) or (
                current_staging.device,
                current_staging.inode,
            ) != (
                staging_identity.device,
                staging_identity.inode,
            ):
                fail("publication transaction identity changed before commit")
            rename_directory_exclusive(
                parent_descriptor,
                staging.name,
                output.name,
            )
            renamed = True
            try:
                output_identity = bounded_regular_file_identity(
                    os.stat(
                        output.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                )
                os.fsync(parent_descriptor)
                final_parent_metadata = os.stat(
                    parent,
                    follow_symlinks=False,
                )
            except OSError as error:
                fail(f"cannot commit publication transaction: {error}")
            if (staging_identity.device, staging_identity.inode) != (
                output_identity.device,
                output_identity.inode,
            ) or (
                final_parent_metadata.st_dev,
                final_parent_metadata.st_ino,
                final_parent_metadata.st_mode,
                final_parent_metadata.st_uid,
            ) != (
                opened_parent.device,
                opened_parent.inode,
                opened_parent.mode,
                parent_metadata.st_uid,
            ):
                fail("publication transaction identity changed during commit")
    except BaseException:
        if renamed:
            quarantine_owned_entry(
                parent_descriptor,
                output.name,
                staging_identity,
            )
        raise
    finally:
        if staging_descriptor is not None:
            os.close(staging_descriptor)
        os.close(parent_descriptor)


def copy_staged_publication_payload(
    *,
    sources: dict[str, Path],
    expected: dict[str, BoundedRegularFileSnapshot],
    output: Path,
    limits: dict[str, int],
) -> StagedPublicationPayload:
    names = set(limits)
    if set(sources) != names or set(expected) != names:
        fail("staged publication payload closure is not exact")
    validate_publication_output_root(output)
    created: list[tuple[Path, BoundedRegularFileIdentity]] = []
    records: list[dict[str, Any]] = []
    bindings: dict[str, BoundedRegularFileCopy] = {}
    try:
        for name in sorted(names):
            destination = output / name
            copied = copy_bounded_regular_file_with_identity(
                sources[name],
                destination,
                f"staged publication file {name}",
                limit=limits[name],
            )
            snapshot = copied.snapshot
            created.append((destination, copied.destination_identity))
            bindings[name] = copied
            if snapshot != expected[name]:
                fail(f"staged publication file {name} changed after acquisition")
            records.append(
                {
                    "name": name,
                    "sha256": snapshot.sha256,
                    "size_bytes": snapshot.size_bytes,
                }
            )
        require_exact_directory(output, limits, label="publication payload")
        rebound = [
            file_record(output / name, maximum_size=limits[name])
            for name in sorted(names)
        ]
        if rebound != records:
            fail("publication payload changed after its bounded copy")
        return StagedPublicationPayload(
            records=records,
            bindings=bindings,
        )
    except BaseException:
        for path, owned_identity in created:
            remove_owned_regular_file(path, owned_identity)
        raise


def verify_and_prepare_publication(
    *,
    bundle: Path,
    output: Path,
    benchmark_suite: Path | None,
    toolchain_public_key: Path,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str | None,
    benchmark_artifact_id: str | None,
    benchmark_artifact_digest: str | None,
    github_token: str,
    release_mode: str = "development-unsigned",
    signed_artifact_id: str | None = None,
    signed_artifact_digest: str | None = None,
    workflow_run_id: str | None = None,
    workflow_run_attempt: str | None = None,
) -> None:
    signed_values = {
        "signed artifact ID": signed_artifact_id,
        "signed artifact digest": signed_artifact_digest,
        "workflow run ID": workflow_run_id,
        "workflow run attempt": workflow_run_attempt,
    }
    signed_build: dict[str, str] | None = None
    if release_mode == "production":
        missing = sorted(
            label for label, value in signed_values.items() if value is None
        )
        if missing:
            fail(
                "production publication requires complete signed build "
                f"identity; missing {', '.join(missing)}"
            )
        assert signed_artifact_id is not None
        assert signed_artifact_digest is not None
        assert workflow_run_id is not None
        assert workflow_run_attempt is not None
        require_positive_decimal_string(
            signed_artifact_id, "signed build artifact ID"
        )
        require_positive_decimal_string(
            workflow_run_id, "signed build workflow run ID"
        )
        require_positive_decimal_string(
            workflow_run_attempt, "signed build workflow run attempt"
        )
        if not SHA256_DIGEST.fullmatch(signed_artifact_digest):
            fail("signed build artifact digest is invalid")
        signed_build = {
            "artifact_id": signed_artifact_id,
            "artifact_digest": signed_artifact_digest,
            "workflow_run_id": workflow_run_id,
            "workflow_run_attempt": workflow_run_attempt,
            "source_commit": source_commit,
        }
    elif any(value is not None for value in signed_values.values()):
        fail("development-unsigned publication must not receive signed build identity")

    benchmark_identity_present = benchmark_run_id is not None
    if benchmark_identity_present != (benchmark_suite is not None):
        fail("benchmark suite and authenticated benchmark identity must be supplied together")

    validate_identity(
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
        release_mode=release_mode,
    )

    with tempfile.TemporaryDirectory(
        prefix="easysplat-publication-inputs-"
    ) as temporary:
        stage = Path(temporary)
        bundle_limits = build_file_limits(app_version, release_mode)
        bundle_limits[BUILD_CLOSURE_NAME] = 4 * 1_024 * 1_024
        staged_bundle = stage / "bundle"
        bundle_snapshots = stage_exact_directory(
            bundle,
            staged_bundle,
            bundle_limits,
            label="build bundle",
        )
        staged_benchmark: Path | None = None
        benchmark_snapshot: BoundedRegularFileSnapshot | None = None
        if benchmark_suite is not None:
            staged_benchmark = stage / "benchmark-suite.json"
            benchmark_snapshot = copy_bounded_regular_file(
                benchmark_suite,
                staged_benchmark,
                "benchmark suite",
                limit=128 * 1_024 * 1_024,
            )
        staged_public_key = stage / "toolchain-public-key.txt"
        copy_bounded_regular_file(
            toolchain_public_key,
            staged_public_key,
            "tracked toolchain public key",
            limit=1_024,
        )

        benchmark_name = f"EasySplat-{app_version}-benchmark.json"
        expected_publication_snapshots = {
            name: bundle_snapshots[name]
            for name in publication_payload_names(
                app_version,
                release_mode,
                include_benchmark=benchmark_identity_present,
            )
            if name != benchmark_name
        }
        if benchmark_snapshot is not None:
            expected_publication_snapshots[benchmark_name] = benchmark_snapshot
        expected_output_names = {
            *publication_payload_names(
                app_version,
                release_mode,
                include_benchmark=benchmark_identity_present,
            ),
            PUBLICATION_MANIFEST_NAME,
        }
        commit_bindings: dict[str, BoundedRegularFileCopy] = {}
        with transactional_publication_output(
            output,
            expected_names=expected_output_names,
            commit_bindings=commit_bindings,
        ) as staged_output:
            commit_bindings.update(
                _verify_staged_publication(
                    bundle=staged_bundle,
                    output=staged_output,
                    benchmark_suite=staged_benchmark,
                    toolchain_public_key=staged_public_key,
                    app_version=app_version,
                    toolchain_version=toolchain_version,
                    source_repository=source_repository,
                    source_commit=source_commit,
                    tag=tag,
                    benchmark_run_id=benchmark_run_id,
                    benchmark_artifact_id=benchmark_artifact_id,
                    benchmark_artifact_digest=benchmark_artifact_digest,
                    github_token=github_token,
                    release_mode=release_mode,
                    signed_build=signed_build,
                    expected_publication_snapshots=(
                        expected_publication_snapshots
                    ),
                )
            )


def _verify_staged_publication(
    *,
    bundle: Path,
    output: Path,
    benchmark_suite: Path | None,
    toolchain_public_key: Path,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str | None,
    benchmark_artifact_id: str | None,
    benchmark_artifact_digest: str | None,
    github_token: str,
    release_mode: str,
    signed_build: dict[str, str] | None,
    expected_publication_snapshots: dict[
        str, BoundedRegularFileSnapshot
    ],
) -> dict[str, BoundedRegularFileCopy]:
    validate_build_bundle(
        bundle,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
        release_mode=release_mode,
    )
    stem = f"EasySplat-{app_version}"
    suffix = "-unsigned" if release_mode == "development-unsigned" else ""
    dmg = bundle / f"{stem}{suffix}.dmg"
    checksum = bundle / f"{stem}{suffix}.dmg.sha256"
    provenance_path = bundle / f"{stem}.provenance.json"
    spdx = bundle / f"{stem}.spdx.json"
    licenses = bundle / f"{stem}-licenses.zip"
    dsym = bundle / f"{stem}-dSYM.zip"
    notes = bundle / f"{stem}-release-notes.txt"
    manifest_path = bundle / "toolchain-manifest.json"
    release_request_path = bundle / TOOLCHAIN_RELEASE_REQUEST_NAME
    authority_envelope_path = bundle / TOOLCHAIN_AUTHORITY_ENVELOPE_NAME
    authority_receipt_path = bundle / TOOLCHAIN_AUTHORITY_RECEIPT_NAME
    benchmark_evidence_path = bundle / TOOLCHAIN_BENCHMARK_EVIDENCE_NAME
    app_signing_receipt = bundle / f"{stem}.app-signing.json"
    app_notary_receipt = bundle / f"{stem}.app-notarization.json"
    dmg_signing_receipt = bundle / f"{stem}.dmg-signing.json"
    dmg_notary_receipt = bundle / f"{stem}.dmg-notarization.json"

    validate_dmg_checksum(dmg, checksum)
    provenance = validate_provenance(
        provenance_path,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        dmg=dmg,
        manifest=manifest_path,
        release_mode=release_mode,
    )
    rebound_provenance, _ = load_json_with_sha256(
        provenance_path,
        "release provenance",
        limit=8 * 1_024 * 1_024,
    )
    if rebound_provenance != provenance:
        fail("release provenance changed during verification")
    validate_release_notes(
        notes, app_version=app_version, release_mode=release_mode
    )
    manifest = validate_toolchain_manifest(
        manifest_path,
        toolchain_public_key,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
    )
    validate_release_timestamps(provenance, manifest)
    license_closure = validate_license_archive(
        licenses,
        provenance,
        manifest,
        toolchain_version=toolchain_version,
    )
    validate_spdx(
        spdx,
        provenance=provenance,
        license_closure=license_closure,
        licenses_name=licenses.name,
    )
    authority_closure = validate_toolchain_authority_closure(
        release_request_path,
        authority_envelope_path,
        authority_receipt_path,
        manifest_path,
        manifest,
        toolchain_public_key,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
    )
    validate_remote_toolchain_assets(
        manifest_path,
        release_request_path,
        authority_envelope_path,
        authority_receipt_path,
        benchmark_evidence_path,
        manifest,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
        authority_source_commit=authority_closure["receipt"]["sourceCommit"],
        github_token=github_token,
    )
    if benchmark_suite is not None:
        validate_benchmark_suite(
            benchmark_suite,
            app_version=app_version,
            source_commit=source_commit,
            toolchain_identity=full_toolchain_identity(manifest),
        )

    dmg_signing_evidence: dict[str, str] | None = None
    if release_mode == "production":
        dmg_signing_evidence = validate_signed_artifact_evidence(
            dmg,
            artifact_type="dmg",
            signing_receipt=dmg_signing_receipt,
            notarization_receipt=dmg_notary_receipt,
        )

    # The DMG is mounted read-only. Its binary is only parsed by system inspection tools.
    with mounted_dmg(dmg) as mount:
        if {entry.name for entry in mount.iterdir()} != {
            "EasySplat.app",
            "Applications",
        }:
            fail("DMG root allowlist is invalid")
        applications = mount / "Applications"
        if (
            not applications.is_symlink()
            or os.readlink(applications) != "/Applications"
        ):
            fail("DMG Applications link is invalid")
        app = mount / "EasySplat.app"
        app_uuid = validate_app_bundle(
            app,
            app_version=app_version,
            toolchain_version=toolchain_version,
            source_repository=source_repository,
            toolchain_public_key=toolchain_public_key,
            release_mode=release_mode,
        )
        if release_mode == "production":
            app_signing_evidence = validate_signed_artifact_evidence(
                app,
                artifact_type="app",
                signing_receipt=app_signing_receipt,
                notarization_receipt=app_notary_receipt,
            )
            if (
                dmg_signing_evidence is None
                or app_signing_evidence["identity_fingerprint_sha1"]
                != dmg_signing_evidence["identity_fingerprint_sha1"]
                or app_signing_evidence["team_id"]
                != dmg_signing_evidence["team_id"]
            ):
                fail("app and disk image use different Developer ID identities")
        app_binary = app / "Contents/MacOS/EasySplatApp"
        validate_dsym_archive(dsym, app_binary)
        if app_uuid != parse_uuid(
            run_static([SYSTEM_TOOLS["dwarfdump"], "--uuid", str(app_binary)]).stdout,
            "app executable",
        ):
            fail("app UUID changed during static verification")

    # Provenance toolchain records must agree with the signed manifest.
    manifest_records = {
        component["name"]: component for component in manifest["components"]
    }
    provenance_map = {
        "core": "macos-arm64-core",
        "geometry-da3-base": "geometry-da3-base",
        "geometry-da3-small": "geometry-da3-small",
    }
    for provenance_name, component_name in provenance_map.items():
        row = provenance["artifacts"][provenance_name]
        component = manifest_records[component_name]
        if (
            row["downloadURL"] != component["url"]
            or row["sha256"] != component["sha256"]
            or row["size"] != component["sizeBytes"]
        ):
            fail(f"provenance and signed manifest differ for {provenance_name}")

    include_benchmark = benchmark_suite is not None
    public_names = publication_payload_names(
        app_version,
        release_mode,
        include_benchmark=include_benchmark,
    )
    benchmark_name = f"{stem}-benchmark.json"
    source_by_name = {
        name: bundle / name for name in public_names if name != benchmark_name
    }
    if benchmark_suite is not None:
        source_by_name[benchmark_name] = benchmark_suite
    limits = publication_file_limits(
        app_version,
        release_mode,
        include_benchmark=include_benchmark,
    )
    publication_payload = copy_staged_publication_payload(
        sources=source_by_name,
        expected=expected_publication_snapshots,
        output=output,
        limits=limits,
    )
    manifest_payload = build_publication_manifest_payload(
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        release_mode=release_mode,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
        benchmark_suite_sha256=(
            expected_publication_snapshots[benchmark_name].sha256
            if include_benchmark
            else None
        ),
        files=publication_payload.records,
        signed_build=signed_build,
    )
    manifest_bytes = canonical_json_bytes(manifest_payload)
    manifest_path = output / PUBLICATION_MANIFEST_NAME
    manifest_descriptor: int | None = None
    try:
        manifest_descriptor = os.open(
            manifest_path,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | os.O_NOFOLLOW,
            0o600,
        )
        written = 0
        while written < len(manifest_bytes):
            try:
                count = os.write(manifest_descriptor, manifest_bytes[written:])
            except InterruptedError:
                continue
            if count <= 0:
                fail("cannot write publication manifest: short write")
            written += count
        os.fsync(manifest_descriptor)
    except OSError as error:
        fail(f"cannot write publication manifest: {error}")
    finally:
        if manifest_descriptor is not None:
            os.close(manifest_descriptor)
    manifest_binding = bind_bounded_regular_file(
        manifest_path,
        "publication manifest",
        limit=16 * 1_024 * 1_024,
    )
    expected_manifest_snapshot = BoundedRegularFileSnapshot(
        data=None,
        sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        size_bytes=len(manifest_bytes),
    )
    if manifest_binding.snapshot != expected_manifest_snapshot:
        fail("publication manifest changed after creation")
    return {
        **publication_payload.bindings,
        PUBLICATION_MANIFEST_NAME: manifest_binding,
    }


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    def add_identity(command: argparse.ArgumentParser) -> None:
        command.add_argument(
            "--release-mode",
            choices=("development-unsigned", "production"),
            default="development-unsigned",
        )
        command.add_argument("--app-version", required=True)
        command.add_argument("--toolchain-version", required=True)
        command.add_argument("--source-repository", required=True)
        command.add_argument("--source-commit", required=True)
        command.add_argument("--tag", required=True)
        command.add_argument("--benchmark-run-id")
        command.add_argument("--benchmark-artifact-id")
        command.add_argument("--benchmark-artifact-digest")

    create = commands.add_parser("create-build-closure")
    create.add_argument("--bundle", type=Path, required=True)
    add_identity(create)

    verify = commands.add_parser("verify-build")
    verify.add_argument("--bundle", type=Path, required=True)
    verify.add_argument("--output", type=Path, required=True)
    verify.add_argument("--benchmark-suite", type=Path)
    verify.add_argument("--toolchain-public-key", type=Path, required=True)
    verify.add_argument("--signed-artifact-id")
    verify.add_argument("--signed-artifact-digest")
    verify.add_argument("--workflow-run-id")
    verify.add_argument("--workflow-run-attempt")
    verify.add_argument("--github-token-env", default="GITHUB_TOKEN")
    add_identity(verify)
    return root


def main(arguments: list[str] | None = None) -> int:
    args = parser().parse_args(arguments)
    try:
        identity = {
            "app_version": args.app_version,
            "toolchain_version": args.toolchain_version,
            "source_repository": args.source_repository,
            "source_commit": args.source_commit,
            "tag": args.tag,
            "benchmark_run_id": args.benchmark_run_id,
            "benchmark_artifact_id": args.benchmark_artifact_id,
            "benchmark_artifact_digest": args.benchmark_artifact_digest,
            "release_mode": args.release_mode,
        }
        if args.command == "create-build-closure":
            create_build_closure(args.bundle, **identity)
        else:
            verify_and_prepare_publication(
                bundle=args.bundle,
                output=args.output,
                benchmark_suite=args.benchmark_suite,
                toolchain_public_key=args.toolchain_public_key,
                github_token=os.environ.get(args.github_token_env, ""),
                signed_artifact_id=args.signed_artifact_id,
                signed_artifact_digest=args.signed_artifact_digest,
                workflow_run_id=args.workflow_run_id,
                workflow_run_attempt=args.workflow_run_attempt,
                **identity,
            )
    except PublicationError as error:
        print(f"Publication verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
