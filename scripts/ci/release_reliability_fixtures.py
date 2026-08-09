#!/usr/bin/env python3
"""Generate and gate large release-reliability fixtures without storing binaries."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import secrets
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Callable


DEFAULT_ENTRY_COUNT = 10_000
DEFAULT_PLY_MIB = 139.6
ZIP_PLY_PATH = "capture/reference-splat.ply"
SCHEMA_VERSION = 1
PLY_RECORD = struct.Struct("<62f")
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_BASELINE_BYTES = 1024 * 1024
TIME = "/usr/bin/time"
PYTHON = "/usr/bin/python3"
SYSCTL = "/usr/sbin/sysctl"
XCRUN = "/usr/bin/xcrun"
TEMPORARY_PREFIX = "easysplat-release-reliability-"
BASELINE_WALL_MULTIPLIER = 1.25
TERMINATE_GRACE_SECONDS = 1.0
KILL_GRACE_SECONDS = 1.0
MEASUREMENT_RUNNER_NAME = "EasySplatMeasurementRunner"
MEASUREMENT_RUNNER_OPTIONS = (
    "--request",
    "--input",
    "--toolchain-root",
    "--candidate-checkout-root",
    "--baseline-checkout-root",
    "--baseline-toolchain-root",
    "--reference-config",
    "--reference-artifact-root",
    "--artifact-root",
    "--lane",
)
MEASUREMENT_RUNNER_REQUIRED_OPTIONS = frozenset(MEASUREMENT_RUNNER_OPTIONS) - {
    "--reference-artifact-root"
}
PRODUCT_TEST_BINARY_NAME = "EasySplatPackageTests"
PRODUCT_FIXTURE_ROOT_KEY = "EASYSPLAT_RELEASE_RELIABILITY_FIXTURE_ROOT"
PRODUCT_OUTPUT_ROOT_KEY = "EASYSPLAT_RELEASE_RELIABILITY_OUTPUT_ROOT"
PRODUCT_RECEIPT_KEY = "EASYSPLAT_RELEASE_RELIABILITY_RECEIPT"
PRODUCT_WORKLOAD_KEY = "EASYSPLAT_RELEASE_RELIABILITY_WORKLOAD"
PRODUCT_TIMING_KEY = "EASYSPLAT_RELEASE_RELIABILITY_TIMING"
PRODUCT_PROCESS_DEADLINE_SECONDS = 30.0
PRODUCT_REQUIRED_CHECKS = (
    (
        "cooperative-cancellation-under-two-seconds",
        "EasySplatCoreTests.SubprocessRunnerAsyncTests/"
        "testRunAsyncReportsTerminationBeforeRethrowingCancellation",
        2.0,
    ),
    (
        "passive-share-cleanup-under-one-second",
        "EasySplatAppTests.ResultWorkspaceTests/"
        "testPickerCloseQueuesPassiveCancellationUntilTheNextMainActorTurn",
        1.0,
    ),
)
PRODUCT_WORKLOADS = (
    (
        "folder-admission-10000",
        "EasySplatAppTests.AppModelDatasetSelectionTests/"
        "testReleaseReliabilityFolderAdmissionTraversesTenThousandRealFiles",
    ),
    (
        "zip-extraction-10000",
        "EasySplatCoreTests.SafeArchiveExtractorTests/"
        "testReleaseReliabilityExtractsTenThousandEntryArchiveWithLargePayload",
    ),
    (
        "ply-validation-139.6mib",
        "EasySplatCoreTests.ProjectArtifactValidatorTests/"
        "testReleaseReliabilityValidatesReferenceSizePlyWithExactEvidence",
    ),
    (
        "ply-export-139.6mib",
        "EasySplatAppTests.UserSelectedExportPublicationTests/"
        "testReleaseReliabilityExportsReferenceSizePlyToAnAbsentDestination",
    ),
)
PRODUCT_ENVIRONMENT_KEYS = (
    "DEVELOPER_DIR",
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "SDKROOT",
    "TMPDIR",
    "USER",
)
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
IDENTITY_FIELDS = (
    "st_dev",
    "st_ino",
    "st_uid",
    "st_mode",
    "st_nlink",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
)
PHOTO_BYTES = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////"
    "////////////////////////////////////////////////////////2wBDAf//"
    "//////////////////////////////////////////////////////////////"
    "////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAA"
    "AAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAA"
    "AAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAA"
    "AAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAA"
    "AP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ/"
    "/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAA"
    "ABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EB//xAAUEQEAAAAAA"
    "AAAAAAAAAAAAAAA/9oACAECAQE/EB//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/"
    "9oACAEBAAE/EB//2Q=="
)


class FixtureError(RuntimeError):
    """A fixture or benchmark does not satisfy the reliability contract."""


def _fail(message: str) -> None:
    raise FixtureError(message)


def _canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def reference_host() -> dict[str, object]:
    """Return the exact hardware identity used to select a performance baseline."""

    values: dict[str, str] = {}
    for key in ("hw.model", "machdep.cpu.brand_string", "hw.memsize"):
        result = subprocess.run(
            [SYSCTL, "-n", key], capture_output=True, text=True, check=False
        )
        if result.returncode != 0 or not result.stdout.strip():
            _fail(f"Could not identify reference host field {key}.")
        values[key] = result.stdout.strip()
    try:
        memory_bytes = int(values["hw.memsize"])
    except ValueError:
        _fail("Reference host memory size is invalid.")
    if memory_bytes <= 0:
        _fail("Reference host memory size is invalid.")
    return {
        "architecture": os.uname().machine,
        "hardwareModel": values["hw.model"],
        "memoryBytes": memory_bytes,
        "processor": values["machdep.cpu.brand_string"],
    }


def _same_identity(first: os.stat_result, second: os.stat_result) -> bool:
    return all(getattr(first, key) == getattr(second, key) for key in IDENTITY_FIELDS)


def _same_directory_object(first: os.stat_result, second: os.stat_result) -> bool:
    return (
        first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_uid == second.st_uid
        and first.st_mode == second.st_mode
        and stat.S_ISDIR(second.st_mode)
    )


def _same_file_object(first: os.stat_result, second: os.stat_result) -> bool:
    return (
        first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_uid == second.st_uid
        and first.st_mode == second.st_mode
        and first.st_nlink == second.st_nlink
        and first.st_size == second.st_size
        and stat.S_ISREG(second.st_mode)
    )


def _identity_values(metadata: os.stat_result) -> tuple[int, ...]:
    return tuple(getattr(metadata, key) for key in IDENTITY_FIELDS)


def _require_canonical(path: Path, label: str, *, must_exist: bool = True) -> None:
    raw = os.fspath(path)
    if not os.path.isabs(raw) or os.path.normpath(raw) != raw:
        _fail(f"{label} must be absolute and normalized.")
    comparison = path if must_exist else path.parent
    if os.path.realpath(comparison) != os.fspath(comparison):
        _fail(f"{label} must contain no symlink ancestry.")


def _hash_regular(path: Path, label: str) -> tuple[str, int]:
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail(f"Could not open {label}: {error.strerror or error}.")
    digest = hashlib.sha256()
    size = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail(f"{label} must be an ordinary, non-hardlinked file.")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        visible = os.lstat(path)
    except OSError:
        _fail(f"{label} path changed while it was read.")
    if size != before.st_size or not _same_identity(before, after):
        _fail(f"{label} changed while it was read.")
    if not _same_identity(after, visible):
        _fail(f"{label} path changed while it was read.")
    return digest.hexdigest(), size


def _read_regular(path: Path, label: str, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail(f"Could not open {label}: {error.strerror or error}.")
    payload = bytearray()
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum_bytes
        ):
            _fail(f"{label} must be a bounded ordinary, non-hardlinked file.")
        while len(payload) < before.st_size:
            chunk = os.read(descriptor, min(64 * 1024, before.st_size - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        visible = os.lstat(path)
    except OSError:
        _fail(f"{label} path changed while it was read.")
    if len(payload) != before.st_size or not _same_identity(before, after):
        _fail(f"{label} changed while it was read.")
    if not _same_identity(after, visible):
        _fail(f"{label} path changed while it was read.")
    return bytes(payload)


def _write_regular(path: Path, chunks) -> tuple[str, int]:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    digest = hashlib.sha256()
    size = 0
    try:
        for chunk in chunks:
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    _fail(f"Could not completely write {path.name}.")
                digest.update(view[:written])
                size += written
                view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return digest.hexdigest(), size


def _photo_name(index: int) -> str:
    return f"frame-{index:05d}.jpg"


def _photo_bytes(index: int) -> bytes:
    if not 0 <= index < 2**64:
        _fail("Photo fixture index is out of range.")
    # A JPEG comment segment makes every frame byte-distinct without requiring
    # payload-sized image generation. The segment length includes its two-byte
    # length field, so the eight-byte index produces a length of ten.
    return (
        PHOTO_BYTES[:2]
        + b"\xff\xfe\x00\x0a"
        + index.to_bytes(8, "big")
        + PHOTO_BYTES[2:]
    )


def _generate_folder(root: Path, entry_count: int) -> dict[str, object]:
    folder = root / "folder"
    folder.mkdir(mode=0o700)
    rows = []
    total = 0
    for index in range(entry_count):
        name = _photo_name(index)
        payload = _photo_bytes(index)
        path = folder / name
        _write_regular(path, (payload,))
        rows.append([name, len(payload), hashlib.sha256(payload).hexdigest()])
        total += len(payload)
    closure = hashlib.sha256(
        json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {"byteCount": total, "closureSHA256": closure, "fileCount": entry_count}


def _stream_zip_entry(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo, source: Path
) -> tuple[str, int]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(source, flags)
    digest = hashlib.sha256()
    size = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail("ZIP large-entry source must be an ordinary, non-hardlinked file.")
        info.file_size = before.st_size
        with archive.open(info, "w", force_zip64=True) as destination:
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                destination.write(chunk)
                digest.update(chunk)
                size += len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(source)
    if size != before.st_size or not _same_identity(before, after):
        _fail("ZIP large-entry source changed while it was archived.")
    if not _same_identity(after, visible):
        _fail("ZIP large-entry source path changed while it was archived.")
    return digest.hexdigest(), size


def _generate_zip(
    root: Path, entry_count: int, ply_evidence: dict[str, object]
) -> dict[str, object]:
    path = root / "archive.zip"
    descriptor = os.open(
        path,
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(descriptor, "w+b", closefd=True) as output:
        with zipfile.ZipFile(
            output, "w", compression=zipfile.ZIP_STORED, allowZip64=True
        ) as archive:
            for index in range(entry_count - 1):
                info = zipfile.ZipInfo(
                    f"capture/{_photo_name(index)}", (1980, 1, 1, 0, 0, 0)
                )
                info.create_system = 3
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                archive.writestr(info, _photo_bytes(index))
            ply_info = zipfile.ZipInfo(ZIP_PLY_PATH, (1980, 1, 1, 0, 0, 0))
            ply_info.create_system = 3
            ply_info.compress_type = zipfile.ZIP_STORED
            ply_info.external_attr = (stat.S_IFREG | 0o600) << 16
            large_digest, large_size = _stream_zip_entry(
                archive, ply_info, root / "splat.ply"
            )
        output.flush()
        os.fsync(output.fileno())
    digest, size = _hash_regular(path, "ZIP fixture")
    if (
        large_digest != ply_evidence["sha256"]
        or large_size != ply_evidence["byteCount"]
    ):
        _fail("ZIP large entry does not match the generated PLY fixture.")
    payload_bytes = sum(
        len(_photo_bytes(index)) for index in range(entry_count - 1)
    ) + large_size
    return {
        "byteCount": size,
        "compressedByteCount": payload_bytes,
        "entryCount": entry_count,
        "largeEntryPath": ZIP_PLY_PATH,
        "largeEntrySHA256": large_digest,
        "sha256": digest,
        "uncompressedByteCount": payload_bytes,
    }


def _ply_properties() -> list[str]:
    return (
        ["x", "y", "z", "nx", "ny", "nz"]
        + [f"f_dc_{index}" for index in range(3)]
        + [f"f_rest_{index}" for index in range(45)]
        + ["opacity"]
        + [f"scale_{index}" for index in range(3)]
        + [f"rot_{index}" for index in range(4)]
    )


def _ply_header(gaussian_count: int) -> bytes:
    lines = [
        "ply",
        "format binary_little_endian 1.0",
        "comment EasySplat deterministic release reliability fixture",
        f"element vertex {gaussian_count}",
    ]
    lines.extend(f"property float {name}" for name in _ply_properties())
    lines.append("end_header")
    return ("\n".join(lines) + "\n").encode("ascii")


def _gaussian_record(index: int) -> bytes:
    values = [0.0] * 62
    values[0] = 1.0 if index & 1 else -1.0
    values[1] = 1.0 if index & 2 else -1.0
    values[2] = 1.0 if index & 4 else -1.0
    values[55:58] = [-2.0, -2.0, -2.0]
    values[58] = 1.0
    return PLY_RECORD.pack(*values)


def _ply_count_for_target(target_bytes: int) -> int:
    count = max(8, target_bytes // PLY_RECORD.size)
    for _ in range(8):
        adjusted = max(8, (target_bytes - len(_ply_header(count))) // PLY_RECORD.size)
        adjusted -= adjusted % 8
        if adjusted == count:
            return count
        count = adjusted
    return count


def _generate_ply(root: Path, target_ply_mib: float) -> dict[str, object]:
    target_bytes = round(target_ply_mib * 1024 * 1024)
    gaussian_count = _ply_count_for_target(target_bytes)
    header = _ply_header(gaussian_count)
    block_count = min(4096, gaussian_count)
    block = b"".join(_gaussian_record(index) for index in range(block_count))

    def chunks():
        yield header
        complete_blocks, remainder = divmod(gaussian_count, block_count)
        for _ in range(complete_blocks):
            yield block
        if remainder:
            yield block[: remainder * PLY_RECORD.size]

    digest, size = _write_regular(root / "splat.ply", chunks())
    return {
        "byteCount": size,
        "format": "binary_little_endian",
        "gaussianCount": gaussian_count,
        "recordBytes": PLY_RECORD.size,
        "sceneBounds": {
            "center": {"x": 0.0, "y": 0.0, "z": 0.0},
            "radius": math.sqrt(3.0) + 3.0 * math.exp(-2.0),
        },
        "sha256": digest,
        "targetMiB": target_ply_mib,
    }


def _write_manifest(path: Path, payload: dict[str, object]) -> None:
    _write_regular(path, (_canonical_json(payload),))


def generate_fixtures(
    root: Path,
    *,
    entry_count: int = DEFAULT_ENTRY_COUNT,
    target_ply_mib: float = DEFAULT_PLY_MIB,
) -> dict[str, object]:
    """Create a deterministic fixture tree at a new exact root."""

    _require_canonical(root, "Fixture root", must_exist=False)
    if os.path.lexists(root):
        _fail("Fixture root must not already exist.")
    if isinstance(entry_count, bool) or not isinstance(entry_count, int) or entry_count <= 0:
        _fail("Fixture entry count must be a positive integer.")
    if not math.isfinite(target_ply_mib) or target_ply_mib <= 0:
        _fail("PLY target size must be a positive finite MiB value.")
    root.mkdir(mode=0o700)
    ply = _generate_ply(root, target_ply_mib)
    payload: dict[str, object] = {
        "entryCount": entry_count,
        "folder": _generate_folder(root, entry_count),
        "ply": ply,
        "schemaVersion": SCHEMA_VERSION,
        "zip": _generate_zip(root, entry_count, ply),
    }
    _write_manifest(root / "fixture-manifest.json", payload)
    return payload


def _load_manifest(path: Path) -> dict[str, object]:
    data = _read_regular(path, "Fixture manifest", MAX_MANIFEST_BYTES)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"Fixture manifest is invalid JSON: {error}.")
    if not isinstance(value, dict) or data != _canonical_json(value):
        _fail("Fixture manifest is not canonical sorted JSON.")
    expected_keys = {"entryCount", "folder", "ply", "schemaVersion", "zip"}
    if set(value) != expected_keys or value.get("schemaVersion") != SCHEMA_VERSION:
        _fail("Fixture manifest has an unexpected schema.")
    return value


def _verify_folder(root: Path, entry_count: int) -> dict[str, object]:
    folder = root / "folder"
    metadata = os.lstat(folder)
    if not stat.S_ISDIR(metadata.st_mode):
        _fail("Folder fixture is not an ordinary directory.")
    names = sorted(os.listdir(folder), key=os.fsencode)
    expected_names = [_photo_name(index) for index in range(entry_count)]
    if names != expected_names:
        _fail("Folder fixture does not contain its exact entry set.")
    rows = []
    total = 0
    for index, name in enumerate(names):
        expected_payload = _photo_bytes(index)
        expected_digest = hashlib.sha256(expected_payload).hexdigest()
        digest, size = _hash_regular(folder / name, f"Folder fixture entry {name}")
        if digest != expected_digest or size != len(expected_payload):
            _fail(f"Folder fixture entry changed: {name}.")
        rows.append([name, size, digest])
        total += size
    closure = hashlib.sha256(
        json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {"byteCount": total, "closureSHA256": closure, "fileCount": entry_count}


def _verify_zip(
    root: Path,
    entry_count: int,
    ply_evidence: dict[str, object] | None = None,
    *,
    after_hash: Callable[[], None] | None = None,
) -> dict[str, object]:
    if ply_evidence is None:
        ply_digest, ply_size = _hash_regular(root / "splat.ply", "PLY fixture")
        ply_evidence = {"byteCount": ply_size, "sha256": ply_digest}
    path = root / "archive.zip"
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    size = 0
    compressed_bytes = 0
    uncompressed_bytes = 0
    try:
        with os.fdopen(descriptor, "rb", closefd=False) as source_file:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                _fail("ZIP fixture must be an ordinary, non-hardlinked file.")
            while True:
                chunk = source_file.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                size += len(chunk)
            if after_hash is not None:
                after_hash()
            source_file.seek(0)
            with zipfile.ZipFile(source_file, "r") as archive:
                infos = archive.infolist()
                expected_names = [
                    f"capture/{_photo_name(index)}" for index in range(entry_count - 1)
                ] + [ZIP_PLY_PATH]
                if len(infos) != entry_count or [
                    info.filename for info in infos
                ] != expected_names:
                    _fail("ZIP fixture does not contain its exact ordered entry set.")
                for index, info in enumerate(infos):
                    mode = info.external_attr >> 16
                    is_ply = info.filename == ZIP_PLY_PATH
                    expected_photo = None if is_ply else _photo_bytes(index)
                    expected_size = (
                        int(ply_evidence["byteCount"])
                        if is_ply
                        else len(expected_photo)
                    )
                    if (
                        info.date_time != (1980, 1, 1, 0, 0, 0)
                        or not stat.S_ISREG(mode)
                        or info.compress_type != zipfile.ZIP_STORED
                        or info.flag_bits & 0x1
                        or info.file_size != expected_size
                        or info.compress_size != expected_size
                    ):
                        _fail(f"ZIP fixture has invalid metadata for {info.filename}.")
                    compressed_bytes += info.compress_size
                    uncompressed_bytes += info.file_size
                    position = 0
                    entry_digest = hashlib.sha256()
                    with archive.open(info, "r") as entry:
                        while True:
                            chunk = entry.read(64 * 1024)
                            if not chunk:
                                break
                            if is_ply:
                                entry_digest.update(chunk)
                            else:
                                assert expected_photo is not None
                                expected = expected_photo[position : position + len(chunk)]
                                if chunk != expected:
                                    _fail(f"ZIP fixture entry changed: {info.filename}.")
                            position += len(chunk)
                    if position != expected_size:
                        _fail(f"ZIP fixture entry is incomplete: {info.filename}.")
                    if is_ply and entry_digest.hexdigest() != ply_evidence["sha256"]:
                        _fail("ZIP fixture large entry does not match the PLY fixture.")
            after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(path)
    if (
        size != before.st_size
        or not _same_identity(before, after)
        or not _same_identity(after, visible)
    ):
        _fail("ZIP fixture changed identity while it was verified.")
    return {
        "byteCount": size,
        "compressedByteCount": compressed_bytes,
        "entryCount": entry_count,
        "largeEntryPath": ZIP_PLY_PATH,
        "largeEntrySHA256": ply_evidence["sha256"],
        "sha256": digest.hexdigest(),
        "uncompressedByteCount": uncompressed_bytes,
    }


def _verify_ply(root: Path, target_ply_mib: float) -> dict[str, object]:
    path = root / "splat.ply"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    header = bytearray()
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail("PLY fixture must be an ordinary, non-hardlinked file.")
        while not header.endswith(b"end_header\n"):
            if len(header) >= 64 * 1024:
                _fail("PLY fixture header is too large.")
            byte = os.read(descriptor, 1)
            if not byte:
                _fail("PLY fixture header is incomplete.")
            header.extend(byte)
        digest.update(header)
        try:
            lines = header.decode("ascii").splitlines()
        except UnicodeDecodeError:
            _fail("PLY fixture header is not ASCII.")
        if lines[:2] != ["ply", "format binary_little_endian 1.0"]:
            _fail("PLY fixture has the wrong format.")
        vertex_rows = [line for line in lines if line.startswith("element vertex ")]
        properties = [
            line.removeprefix("property float ")
            for line in lines
            if line.startswith("property float ")
        ]
        if len(vertex_rows) != 1 or properties != _ply_properties():
            _fail("PLY fixture has the wrong Gaussian schema.")
        try:
            gaussian_count = int(vertex_rows[0].split()[2])
        except (ValueError, IndexError):
            _fail("PLY fixture has an invalid Gaussian count.")
        remaining_records = gaussian_count
        while remaining_records:
            records = min(1024, remaining_records)
            required = records * PLY_RECORD.size
            chunk = bytearray()
            while len(chunk) < required:
                part = os.read(descriptor, required - len(chunk))
                if not part:
                    _fail("PLY fixture ended before its declared Gaussian count.")
                chunk.extend(part)
            digest.update(chunk)
            for offset in range(0, len(chunk), PLY_RECORD.size):
                if not all(
                    math.isfinite(value)
                    for value in PLY_RECORD.unpack_from(chunk, offset)
                ):
                    _fail("PLY fixture contains a non-finite Gaussian value.")
            remaining_records -= records
        if os.read(descriptor, 1):
            _fail("PLY fixture contains bytes after its declared Gaussian records.")
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(path)
    if not _same_identity(before, after) or not _same_identity(after, visible):
        _fail("PLY fixture changed while it was verified.")
    expected_size = len(header) + gaussian_count * PLY_RECORD.size
    if before.st_size != expected_size:
        _fail("PLY fixture size does not match its header.")
    if gaussian_count % 8 != 0:
        _fail("PLY fixture Gaussian count does not preserve complete corner groups.")
    target_bytes = round(target_ply_mib * 1024 * 1024)
    if expected_size > target_bytes or target_bytes - expected_size > 8 * PLY_RECORD.size:
        _fail("PLY fixture size does not match its declared MiB target.")
    return {
        "byteCount": expected_size,
        "format": "binary_little_endian",
        "gaussianCount": gaussian_count,
        "recordBytes": PLY_RECORD.size,
        "sceneBounds": {
            "center": {"x": 0.0, "y": 0.0, "z": 0.0},
            "radius": math.sqrt(3.0) + 3.0 * math.exp(-2.0),
        },
        "sha256": digest.hexdigest(),
        "targetMiB": target_ply_mib,
    }


def verify_fixtures(root: Path) -> dict[str, object]:
    """Re-read every fixture and compare it with the strict manifest."""

    _require_canonical(root, "Fixture root")
    metadata = os.lstat(root)
    if not stat.S_ISDIR(metadata.st_mode):
        _fail("Fixture root must be an ordinary directory.")
    if set(os.listdir(root)) != {
        "archive.zip",
        "fixture-manifest.json",
        "folder",
        "splat.ply",
    }:
        _fail("Fixture root contains an unexpected entry.")
    manifest = _load_manifest(root / "fixture-manifest.json")
    entry_count = manifest["entryCount"]
    if isinstance(entry_count, bool) or not isinstance(entry_count, int) or entry_count <= 0:
        _fail("Fixture manifest has an invalid entry count.")
    manifest_ply = manifest.get("ply")
    if not isinstance(manifest_ply, dict):
        _fail("Fixture manifest has invalid PLY evidence.")
    target_ply_mib = manifest_ply.get("targetMiB")
    if (
        isinstance(target_ply_mib, bool)
        or not isinstance(target_ply_mib, (int, float))
        or not math.isfinite(target_ply_mib)
        or target_ply_mib <= 0
    ):
        _fail("Fixture manifest has an invalid PLY MiB target.")
    ply = _verify_ply(root, float(target_ply_mib))
    actual = {
        "entryCount": entry_count,
        "folder": _verify_folder(root, entry_count),
        "ply": ply,
        "schemaVersion": SCHEMA_VERSION,
        "zip": _verify_zip(root, entry_count, ply),
    }
    if actual != manifest:
        _fail("Fixture bytes do not match their manifest.")
    return manifest


def _capture_fixture_identities(
    root: Path, entry_count: int
) -> tuple[tuple[str, tuple[int, ...]], ...]:
    """Capture every measured fixture identity without following child links."""

    _require_canonical(root, "Fixture root")
    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    file_flags = (
        os.O_RDONLY
        | os.O_NONBLOCK
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    root_descriptor = -1
    folder_descriptor = -1
    identities: list[tuple[str, tuple[int, ...]]] = []

    def regular_identity(
        descriptor: int, name: str, label: str
    ) -> tuple[int, ...]:
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        file_descriptor = os.open(name, file_flags, dir_fd=descriptor)
        try:
            opened = os.fstat(file_descriptor)
        finally:
            os.close(file_descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or not _same_identity(before, opened)
        ):
            _fail(f"{label} identity is unsafe or changed while it was bound.")
        return _identity_values(opened)

    try:
        root_descriptor = os.open(root, directory_flags)
        opened_root = os.fstat(root_descriptor)
        visible_root = os.lstat(root)
        if (
            not stat.S_ISDIR(opened_root.st_mode)
            or not _same_identity(opened_root, visible_root)
        ):
            _fail("Fixture root identity changed while it was bound.")
        identities.append(("root", _identity_values(opened_root)))

        expected_root_names = {
            "archive.zip",
            "fixture-manifest.json",
            "folder",
            "splat.ply",
        }
        if set(os.listdir(root_descriptor)) != expected_root_names:
            _fail("Fixture root identity set contains an unexpected entry.")

        folder_before = os.stat(
            "folder", dir_fd=root_descriptor, follow_symlinks=False
        )
        folder_descriptor = os.open(
            "folder", directory_flags, dir_fd=root_descriptor
        )
        opened_folder = os.fstat(folder_descriptor)
        if (
            not stat.S_ISDIR(opened_folder.st_mode)
            or not _same_identity(folder_before, opened_folder)
        ):
            _fail("Folder fixture identity changed while it was bound.")
        identities.append(("folder", _identity_values(opened_folder)))

        for name, label in (
            ("fixture-manifest.json", "Fixture manifest"),
            ("archive.zip", "ZIP fixture"),
            ("splat.ply", "PLY fixture"),
        ):
            identities.append(
                (name, regular_identity(root_descriptor, name, label))
            )

        names = sorted(os.listdir(folder_descriptor), key=os.fsencode)
        if names != [_photo_name(index) for index in range(entry_count)]:
            _fail("Folder fixture identity set does not contain its exact entries.")
        for name in names:
            identities.append(
                (
                    f"folder/{name}",
                    regular_identity(
                        folder_descriptor, name, f"Folder fixture entry {name}"
                    ),
                )
            )
        return tuple(identities)
    except FixtureError:
        raise
    except OSError as error:
        _fail(f"Could not bind fixture identities: {error}.")
    finally:
        if folder_descriptor >= 0:
            os.close(folder_descriptor)
        if root_descriptor >= 0:
            os.close(root_descriptor)


def _load_baseline(path: Path, name: str) -> dict[str, float | int]:
    _require_canonical(path, "Performance baseline")
    data = _read_regular(path, "Performance baseline", MAX_BASELINE_BYTES)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"Performance baseline is invalid JSON: {error}.")
    if not isinstance(value, dict) or data != _canonical_json(value):
        _fail("Performance baseline is not canonical sorted JSON.")
    if (
        set(value) != {"measurements", "referenceHost", "schemaVersion"}
        or value.get("schemaVersion") != 1
    ):
        _fail("Performance baseline has an unexpected schema.")
    host = value.get("referenceHost")
    if (
        not isinstance(host, dict)
        or set(host)
        != {"architecture", "hardwareModel", "memoryBytes", "processor"}
        or host != reference_host()
    ):
        _fail("Performance baseline does not match this exact reference host.")
    measurements = value.get("measurements")
    if not isinstance(measurements, dict) or not measurements:
        _fail("Performance baseline has no measurements.")
    for measurement_name, measurement in measurements.items():
        if (
            not isinstance(measurement_name, str)
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", measurement_name) is None
            or not isinstance(measurement, dict)
            or set(measurement) != {"peakRSSBytes", "wallSeconds"}
        ):
            _fail("Performance baseline contains an invalid measurement.")
        peak_rss = measurement["peakRSSBytes"]
        wall = measurement["wallSeconds"]
        if (
            isinstance(peak_rss, bool)
            or not isinstance(peak_rss, int)
            or peak_rss <= 0
            or isinstance(wall, bool)
            or not isinstance(wall, (int, float))
            or not math.isfinite(float(wall))
            or float(wall) <= 0
        ):
            _fail("Performance baseline contains an invalid limit value.")
    if name not in measurements:
        _fail(f"Performance baseline has no measurement named {name!r}.")
    selected = measurements[name]
    return {
        "peakRSSBytes": int(selected["peakRSSBytes"]),
        "wallSeconds": float(selected["wallSeconds"]),
    }


def enforce_baseline(
    measured: dict[str, float | int], baseline: dict[str, float | int]
) -> dict[str, float | int]:
    """Apply the release gate's exact wall/RSS limits."""

    wall = float(measured["wallSeconds"])
    peak_rss = int(measured["peakRSSBytes"])
    baseline_wall = float(baseline["wallSeconds"])
    baseline_rss = int(baseline["peakRSSBytes"])
    wall_limit = baseline_wall * BASELINE_WALL_MULTIPLIER
    rss_limit = baseline_rss + 64 * 1024 * 1024
    if not math.isfinite(wall) or wall < 0 or wall > wall_limit:
        _fail(
            f"Measured wall time {wall:.6f}s exceeds the 1.25x baseline limit "
            f"of {wall_limit:.6f}s."
        )
    if peak_rss <= 0 or peak_rss > rss_limit:
        _fail(
            f"Measured peak RSS {peak_rss} exceeds the baseline-plus-64-MiB "
            f"limit of {rss_limit}."
        )
    return {"peakRSSBytes": rss_limit, "wallSeconds": wall_limit}


def _expand_command(root: Path, command: list[str]) -> list[str]:
    if not command or any(not isinstance(argument, str) or not argument for argument in command):
        _fail("Performance command must contain at least one nonempty argv item.")
    placeholders = ("{folder}", "{zip}", "{ply}")
    fixture_arguments = [
        (index, argument)
        for index, argument in enumerate(command)
        if any(placeholder in argument for placeholder in placeholders)
    ]
    if not fixture_arguments:
        _fail("Performance command must exercise a real EasySplat entrypoint with a fixture.")
    executable = Path(command[0])
    if executable.name != MEASUREMENT_RUNNER_NAME:
        _fail(
            "Performance command must exercise a real EasySplat entrypoint: "
            f"expected {MEASUREMENT_RUNNER_NAME}."
        )
    values = command[1:]
    if len(values) % 2 != 0:
        _fail(
            "Performance command must exercise a real EasySplat entrypoint with "
            "option/value pairs."
        )
    parsed: dict[str, str] = {}
    for index in range(0, len(values), 2):
        option = values[index]
        value = values[index + 1]
        if option not in MEASUREMENT_RUNNER_OPTIONS or option in parsed:
            _fail(
                "Performance command must exercise a real EasySplat entrypoint with "
                "the EasySplatMeasurementRunner option contract."
            )
        parsed[option] = value
    if not MEASUREMENT_RUNNER_REQUIRED_OPTIONS.issubset(parsed):
        _fail(
            "Performance command must exercise a real EasySplat entrypoint with "
            "the complete EasySplatMeasurementRunner option contract."
        )
    if parsed["--input"] not in placeholders or fixture_arguments != [
        (command.index("--input") + 1, parsed["--input"])
    ]:
        _fail(
            "Performance command must exercise a real EasySplat entrypoint with "
            "exactly one fixture placeholder as --input."
        )
    replacements = {
        "{folder}": os.fspath(root / "folder"),
        "{ply}": os.fspath(root / "splat.ply"),
        "{zip}": os.fspath(root / "archive.zip"),
    }
    expanded = []
    for argument in command:
        value = argument
        for placeholder, replacement in replacements.items():
            value = value.replace(placeholder, replacement)
        if "{" in value or "}" in value:
            _fail(f"Performance command contains an unknown placeholder: {argument!r}.")
        expanded.append(value)
    executable = Path(expanded[0])
    if not executable.is_absolute() or os.path.realpath(executable) != os.fspath(executable):
        _fail(
            "Performance command must exercise a real EasySplat entrypoint at an "
            "absolute path without symlinks."
        )
    metadata = os.lstat(executable)
    if not stat.S_ISREG(metadata.st_mode) or not os.access(executable, os.X_OK):
        _fail(
            "Performance command must exercise a real EasySplat entrypoint that is "
            "an executable regular file."
        )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(executable, flags)
    try:
        opened = os.fstat(descriptor)
        magic = os.read(descriptor, 4)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(executable)
    if (
        magic not in MACHO_MAGICS
        or not _same_identity(opened, after)
        or not _same_identity(after, visible)
    ):
        _fail(
            "Performance command must exercise a real EasySplat entrypoint built as "
            "a stable Mach-O executable."
        )
    return expanded


def _parse_time_output(data: bytes) -> dict[str, float | int]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        _fail("/usr/bin/time emitted non-UTF-8 metrics.")
    wall_match = re.search(r"(?m)^\s*([0-9]+(?:\.[0-9]+)?)\s+real(?:\s|$)", text)
    rss_match = re.search(r"(?m)^\s*([0-9]+)\s+maximum resident set size\s*$", text)
    if wall_match is None or rss_match is None:
        _fail("Could not parse /usr/bin/time -l metrics.")
    return {
        "peakRSSBytes": int(rss_match.group(1)),
        "wallSeconds": float(wall_match.group(1)),
    }


def _write_result(path: Path, payload: dict[str, object]) -> None:
    _require_canonical(path, "Measurement output", must_exist=False)
    if os.path.lexists(path):
        _fail("Measurement output must not already exist.")
    _write_regular(path, (_canonical_json(payload),))


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _signal_process_group(process_group: int, requested_signal: int) -> None:
    try:
        os.killpg(process_group, requested_signal)
    except ProcessLookupError:
        pass


def _wait_for_process_group_exit(
    process: subprocess.Popen, timeout_seconds: float
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while True:
        process.poll()
        if not _process_group_exists(process.pid):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.02, remaining))


def _terminate_owned_process_group(process: subprocess.Popen) -> bool:
    _signal_process_group(process.pid, signal.SIGTERM)
    if _wait_for_process_group_exit(process, TERMINATE_GRACE_SECONDS):
        return True
    _signal_process_group(process.pid, signal.SIGKILL)
    return _wait_for_process_group_exit(process, KILL_GRACE_SECONDS)


def _run_with_wall_deadline(
    arguments: list[str],
    *,
    deadline_seconds: float,
    label: str,
    stdout=None,
    stderr=None,
    environment: dict[str, str] | None = None,
    current_directory: Path | None = None,
) -> subprocess.CompletedProcess:
    if not math.isfinite(deadline_seconds) or deadline_seconds <= 0:
        _fail(f"{label} has an invalid wall deadline.")
    process = subprocess.Popen(
        arguments,
        stdout=stdout,
        stderr=stderr,
        start_new_session=True,
        env=environment,
        cwd=current_directory,
    )
    try:
        captured_stdout, captured_stderr = process.communicate(
            timeout=deadline_seconds
        )
    except subprocess.TimeoutExpired:
        terminated = _terminate_owned_process_group(process)
        try:
            captured_stdout, captured_stderr = process.communicate(
                timeout=KILL_GRACE_SECONDS
            )
        except subprocess.TimeoutExpired:
            terminated = False
            _signal_process_group(process.pid, signal.SIGKILL)
        if not terminated:
            _fail(
                f"{label} exceeded its wall deadline of {deadline_seconds:.6f}s, "
                "and its owned process group did not stop after bounded TERM/KILL "
                "escalation."
            )
        _fail(
            f"{label} exceeded its wall deadline of {deadline_seconds:.6f}s; "
            "terminated its owned process group."
        )
    if _process_group_exists(process.pid):
        terminated = _terminate_owned_process_group(process)
        if not terminated:
            _fail(
                f"{label} left an owned process group running after exit, and it "
                "did not stop after bounded TERM/KILL escalation."
            )
        _fail(f"{label} left descendant processes running after exit.")
    return subprocess.CompletedProcess(
        arguments,
        process.returncode,
        captured_stdout,
        captured_stderr,
    )


def _validate_product_test_binary(path: Path) -> os.stat_result:
    _require_canonical(path, "Product test binary")
    if (
        path.name != PRODUCT_TEST_BINARY_NAME
        or path.parent.name != "MacOS"
        or path.parent.parent.name != "Contents"
        or path.parent.parent.parent.name != f"{PRODUCT_TEST_BINARY_NAME}.xctest"
    ):
        _fail(
            "Product performance must use the exact EasySplat SwiftPM XCTest binary."
        )
    before = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.getuid()
        or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or not os.access(path, os.X_OK)
    ):
        _fail("Product test binary must be a protected executable regular file.")
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        magic = os.read(descriptor, 4)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(path)
    if (
        magic not in MACHO_MAGICS
        or not _same_identity(before, opened)
        or not _same_identity(opened, after)
        or not _same_identity(after, visible)
    ):
        _fail("Product test binary changed or is not a stable Mach-O executable.")
    return visible


def _consume_product_workload_receipt(path: Path, workload: str) -> float:
    try:
        before = os.lstat(path)
    except OSError as error:
        _fail(f"Product workload did not create its success receipt: {error}.")
    if before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600:
        _fail("Product workload receipt has unsafe ownership or permissions.")
    data = _read_regular(path, "Product workload receipt", 1024)
    try:
        payload = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"Product workload receipt is invalid JSON: {error}.")
    if (
        not isinstance(payload, dict)
        or set(payload) != {"schemaVersion", "status", "wallSeconds", "workload"}
        or payload.get("schemaVersion") != 1
        or payload.get("status") != "passed"
        or payload.get("workload") != workload
    ):
        _fail("Product workload receipt does not match the selected XCTest.")
    wall_seconds = payload.get("wallSeconds")
    if (
        isinstance(wall_seconds, bool)
        or not isinstance(wall_seconds, (int, float))
        or not math.isfinite(float(wall_seconds))
        or float(wall_seconds) <= 0
        or data != _canonical_json(payload)
    ):
        _fail("Product workload receipt has invalid operation timing.")
    after = os.lstat(path)
    if not _same_identity(before, after):
        _fail("Product workload receipt changed before it could be consumed.")
    os.unlink(path)
    if os.path.lexists(path):
        _fail("Product workload receipt could not be consumed exactly once.")
    return float(wall_seconds)


def _sanitized_product_environment() -> dict[str, str]:
    environment = {
        key: os.environ[key]
        for key in PRODUCT_ENVIRONMENT_KEYS
        if key in os.environ and os.environ[key]
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment.setdefault("TMPDIR", "/private/tmp")
    return environment


def _product_test_environment(
    *,
    fixture_root: Path,
    output_root: Path,
    receipt: Path,
    workload: str,
) -> dict[str, str]:
    environment = _sanitized_product_environment()
    environment.update(
        {
            PRODUCT_FIXTURE_ROOT_KEY: os.fspath(fixture_root),
            PRODUCT_OUTPUT_ROOT_KEY: os.fspath(output_root),
            PRODUCT_RECEIPT_KEY: os.fspath(receipt),
            PRODUCT_WORKLOAD_KEY: workload,
        }
    )
    return environment


def _xctest_case_name(test_specifier: str) -> str:
    suite, separator, method = test_specifier.partition("/")
    if (
        separator != "/"
        or not suite
        or not method
        or "/" in method
        or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", suite) is None
        or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", method) is None
    ):
        _fail("Product XCTest specifier is invalid.")
    return f"{suite} {method}"


def _run_product_required_check(
    *,
    name: str,
    test_specifier: str,
    test_binary: Path,
    output_root: Path,
    limit_seconds: float,
) -> dict[str, object]:
    if (name, test_specifier, limit_seconds) not in PRODUCT_REQUIRED_CHECKS:
        _fail("Required product check is not one of the reviewed XCTest cases.")
    binary_before = _validate_product_test_binary(test_binary)
    output_metadata = os.lstat(output_root)
    if (
        not stat.S_ISDIR(output_metadata.st_mode)
        or output_metadata.st_uid != os.getuid()
        or stat.S_IMODE(output_metadata.st_mode) != 0o700
        or os.listdir(output_root)
    ):
        _fail("Required product check output root must be a new private empty directory.")
    receipt = output_root / "receipt.json"
    test_bundle = test_binary.parent.parent.parent
    environment = _sanitized_product_environment()
    environment.update(
        {
            PRODUCT_RECEIPT_KEY: os.fspath(receipt),
            PRODUCT_TIMING_KEY: "1",
            PRODUCT_WORKLOAD_KEY: name,
        }
    )
    arguments = [
        XCRUN,
        "xctest",
        "-XCTest",
        test_specifier,
        os.fspath(test_bundle),
    ]
    result = _run_with_wall_deadline(
        arguments,
        deadline_seconds=PRODUCT_PROCESS_DEADLINE_SECONDS,
        label=f"Required product check {name}",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        environment=environment,
        current_directory=test_bundle.parent,
    )
    binary_after = _validate_product_test_binary(test_binary)
    if not _same_identity(binary_before, binary_after):
        _fail("Product test binary changed while a required check was running.")
    combined = (result.stdout or b"") + b"\n" + (result.stderr or b"")
    detail = combined[-8192:].decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        suffix = f": {detail}" if detail else ""
        _fail(f"Required product check {name} failed with status {result.returncode}{suffix}.")
    expected_case = f"Test Case '-[{_xctest_case_name(test_specifier)}]' passed".encode()
    if expected_case not in combined or b"Executed 1 test, with 0 failures" not in combined:
        _fail(f"Required product check {name} did not execute its exact XCTest case.")
    wall_seconds = _consume_product_workload_receipt(receipt, name)
    if os.listdir(output_root):
        _fail("Required product check left unexpected output after its receipt was consumed.")
    if wall_seconds > limit_seconds:
        _fail(
            f"Required product check {name} took {wall_seconds:.6f}s, exceeding "
            f"its {limit_seconds:.6f}s release budget."
        )
    return {
        "limitSeconds": limit_seconds,
        "status": "passed",
        "testSpecifier": test_specifier,
        "wallSeconds": wall_seconds,
    }


def _validated_product_measurement(
    *,
    operation_wall_seconds: float,
    process_measured: dict[str, float | int],
) -> dict[str, float | int]:
    process_wall_seconds = float(process_measured["wallSeconds"])
    if operation_wall_seconds > process_wall_seconds + 0.01:
        _fail("Product operation wall time exceeds independent process wall time.")
    return {
        "peakRSSBytes": int(process_measured["peakRSSBytes"]),
        "wallSeconds": operation_wall_seconds,
    }


def _measure_product_workload(
    *,
    fixture_root: Path,
    output_root: Path,
    baseline_path: Path,
    name: str,
    test_specifier: str,
    test_binary: Path,
) -> dict[str, object]:
    if (name, test_specifier) not in PRODUCT_WORKLOADS:
        _fail("Product workload is not one of the reviewed release XCTest cases.")
    manifest = verify_fixtures(fixture_root)
    fixture_identities = _capture_fixture_identities(
        fixture_root, int(manifest["entryCount"])
    )
    baseline = _load_baseline(baseline_path, name)
    binary_before = _validate_product_test_binary(test_binary)
    output_metadata = os.lstat(output_root)
    if (
        not stat.S_ISDIR(output_metadata.st_mode)
        or output_metadata.st_uid != os.getuid()
        or stat.S_IMODE(output_metadata.st_mode) != 0o700
        or os.listdir(output_root)
    ):
        _fail("Product workload output root must be a new private empty directory.")
    receipt = output_root / "receipt.json"
    descriptor, timing_name = tempfile.mkstemp(
        prefix=".easysplat-time-", dir=output_root
    )
    timing_path = Path(timing_name)
    os.close(descriptor)
    environment = _product_test_environment(
        fixture_root=fixture_root,
        output_root=output_root,
        receipt=receipt,
        workload=name,
    )
    test_bundle = test_binary.parent.parent.parent
    try:
        result = _run_with_wall_deadline(
            [
                TIME,
                "-l",
                "-o",
                os.fspath(timing_path),
                XCRUN,
                "xctest",
                "-XCTest",
                test_specifier,
                os.fspath(test_bundle),
            ],
            deadline_seconds=PRODUCT_PROCESS_DEADLINE_SECONDS,
            label=f"Product workload {name}",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            environment=environment,
            current_directory=fixture_root.parent,
        )
        binary_after = _validate_product_test_binary(test_binary)
        if not _same_identity(binary_before, binary_after):
            _fail("Product test binary changed while a workload was running.")
        if result.returncode != 0:
            combined = (result.stdout or b"") + b"\n" + (result.stderr or b"")
            detail = combined[-8192:].decode("utf-8", errors="replace").strip()
            suffix = f": {detail}" if detail else ""
            _fail(f"Product workload {name} failed with status {result.returncode}{suffix}.")
        operation_wall_seconds = _consume_product_workload_receipt(receipt, name)
        process_measured = _parse_time_output(
            _read_regular(timing_path, "/usr/bin/time output", MAX_MANIFEST_BYTES)
        )
    finally:
        try:
            os.unlink(timing_path)
        except FileNotFoundError:
            pass
    if os.listdir(output_root):
        _fail("Product workload left unexpected output after its assertions completed.")
    if (
        _capture_fixture_identities(fixture_root, int(manifest["entryCount"]))
        != fixture_identities
        or verify_fixtures(fixture_root) != manifest
        or _capture_fixture_identities(
            fixture_root, int(manifest["entryCount"])
        )
        != fixture_identities
    ):
        _fail("Product workload changed its authenticated fixture inputs.")
    measured = _validated_product_measurement(
        operation_wall_seconds=operation_wall_seconds,
        process_measured=process_measured,
    )
    limits = enforce_baseline(measured, baseline)
    return {
        "baseline": baseline,
        "limits": limits,
        "peakRSSBytes": measured["peakRSSBytes"],
        "processWallSeconds": process_measured["wallSeconds"],
        "testSpecifier": test_specifier,
        "wallSeconds": measured["wallSeconds"],
    }


def measure_command(
    *,
    root: Path,
    baseline_path: Path,
    name: str,
    command: list[str],
    output: Path | None = None,
) -> dict[str, object]:
    """Measure one caller-supplied entrypoint against an authenticated fixture."""

    manifest = verify_fixtures(root)
    fixture_identities = _capture_fixture_identities(
        root, int(manifest["entryCount"])
    )
    baseline = _load_baseline(baseline_path, name)
    expanded = _expand_command(root, command)
    descriptor, timing_name = tempfile.mkstemp(prefix=".easysplat-time-", dir=root.parent)
    timing_path = Path(timing_name)
    os.close(descriptor)
    try:
        result = _run_with_wall_deadline(
            [TIME, "-l", "-o", os.fspath(timing_path), *expanded],
            deadline_seconds=(
                float(baseline["wallSeconds"]) * BASELINE_WALL_MULTIPLIER
            ),
            label="Performance command",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            detail = (result.stderr or b"")[-4096:].decode(
                "utf-8", errors="replace"
            ).strip()
            suffix = f": {detail}" if detail else ""
            _fail(
                f"Performance command exited with status {result.returncode}{suffix}."
            )
        measured = _parse_time_output(
            _read_regular(timing_path, "/usr/bin/time output", MAX_MANIFEST_BYTES)
        )
    finally:
        try:
            os.unlink(timing_path)
        except FileNotFoundError:
            pass
    if _capture_fixture_identities(root, int(manifest["entryCount"])) != fixture_identities:
        _fail("Performance command changed at least one fixture identity.")
    limits = enforce_baseline(measured, baseline)
    if verify_fixtures(root) != manifest:
        _fail("Performance command changed its fixture inputs.")
    if _capture_fixture_identities(root, int(manifest["entryCount"])) != fixture_identities:
        _fail("Performance command changed at least one fixture identity.")
    manifest_digest = hashlib.sha256(_canonical_json(manifest)).hexdigest()
    payload: dict[str, object] = {
        "baseline": baseline,
        "fixtureManifestSHA256": manifest_digest,
        "limits": limits,
        "name": name,
        "peakRSSBytes": measured["peakRSSBytes"],
        "schemaVersion": 1,
        "status": "passed",
        "wallSeconds": measured["wallSeconds"],
    }
    if output is not None:
        _write_result(output, payload)
    return payload


def _measure_process(
    arguments: list[str],
    timing_directory: Path,
    *,
    deadline_seconds: float,
) -> dict[str, float | int]:
    descriptor, timing_name = tempfile.mkstemp(
        prefix=".easysplat-time-", dir=timing_directory
    )
    timing_path = Path(timing_name)
    os.close(descriptor)
    try:
        result = _run_with_wall_deadline(
            [TIME, "-l", "-o", os.fspath(timing_path), *arguments],
            deadline_seconds=deadline_seconds,
            label="Fixture workload",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            detail = result.stderr[-4096:].decode("utf-8", errors="replace").strip()
            suffix = f": {detail}" if detail else ""
            _fail(f"Fixture workload exited with status {result.returncode}{suffix}.")
        return _parse_time_output(
            _read_regular(timing_path, "/usr/bin/time output", MAX_MANIFEST_BYTES)
        )
    finally:
        try:
            os.unlink(timing_path)
        except FileNotFoundError:
            pass


def run_full_fixture_gate(
    *,
    workspace: Path,
    baseline_path: Path,
    entry_count: int = DEFAULT_ENTRY_COUNT,
    target_ply_mib: float = DEFAULT_PLY_MIB,
    output: Path | None = None,
) -> dict[str, object]:
    """Gate fixture-tool generation and verification, not product performance."""

    _require_canonical(workspace, "Fixture gate workspace")
    if not stat.S_ISDIR(os.lstat(workspace).st_mode):
        _fail("Fixture gate workspace must be an ordinary directory.")
    baselines = {
        name: _load_baseline(baseline_path, name)
        for name in ("fixture-generate", "fixture-verify")
    }
    root = Path(tempfile.mkdtemp(prefix=TEMPORARY_PREFIX, dir=workspace))
    original = os.lstat(root)
    fixture_root = root / "fixtures"
    helper = Path(__file__).resolve()
    measurements: dict[str, object] = {}
    try:
        generate_metrics = _measure_process(
            [
                PYTHON,
                "-I",
                os.fspath(helper),
                "generate",
                "--root",
                os.fspath(fixture_root),
                "--entry-count",
                str(entry_count),
                "--ply-mib",
                str(target_ply_mib),
            ],
            root,
            deadline_seconds=(
                float(baselines["fixture-generate"]["wallSeconds"])
                * BASELINE_WALL_MULTIPLIER
            ),
        )
        generate_limits = enforce_baseline(
            generate_metrics, baselines["fixture-generate"]
        )
        manifest = verify_fixtures(fixture_root)
        fixture_identities = _capture_fixture_identities(
            fixture_root, int(manifest["entryCount"])
        )
        measurements["fixture-generate"] = {
            "baseline": baselines["fixture-generate"],
            "limits": generate_limits,
            **generate_metrics,
        }

        verify_metrics = _measure_process(
            [
                PYTHON,
                "-I",
                os.fspath(helper),
                "verify",
                "--root",
                os.fspath(fixture_root),
            ],
            root,
            deadline_seconds=(
                float(baselines["fixture-verify"]["wallSeconds"])
                * BASELINE_WALL_MULTIPLIER
            ),
        )
        verify_limits = enforce_baseline(
            verify_metrics, baselines["fixture-verify"]
        )
        if (
            _capture_fixture_identities(
                fixture_root, int(manifest["entryCount"])
            )
            != fixture_identities
        ):
            _fail("Full fixture workload changed at least one fixture identity.")
        if verify_fixtures(fixture_root) != manifest:
            _fail("Full fixture workload changed its authenticated inputs.")
        if (
            _capture_fixture_identities(
                fixture_root, int(manifest["entryCount"])
            )
            != fixture_identities
        ):
            _fail("Full fixture workload changed at least one fixture identity.")
        measurements["fixture-verify"] = {
            "baseline": baselines["fixture-verify"],
            "limits": verify_limits,
            **verify_metrics,
        }
        payload: dict[str, object] = {
            "fixtureManifestSHA256": hashlib.sha256(
                _canonical_json(manifest)
            ).hexdigest(),
            "measurements": measurements,
            "referenceHost": reference_host(),
            "schemaVersion": 1,
            "status": "passed",
        }
        if output is not None:
            _write_result(output, payload)
        return payload
    finally:
        _remove_owned_temporary_root(root, workspace, original)


def _remove_owned_temporary_root(
    root: Path, workspace: Path, original: os.stat_result
) -> None:
    if root.parent != workspace or not root.name.startswith(TEMPORARY_PREFIX):
        _fail("Refusing to clean a fixture root outside the owned temporary boundary.")
    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )

    def retained_name() -> str:
        return f".easysplat-retained-{secrets.token_hex(12)}"

    def remove_contents(descriptor: int) -> None:
        names = sorted(os.listdir(descriptor), key=os.fsencode)
        for name in names:
            if name in {"", ".", ".."} or "/" in name:
                _fail("Owned temporary fixture root contains an unsafe entry name.")
            before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            quarantined_name = retained_name()
            if stat.S_ISDIR(before.st_mode):
                try:
                    child_descriptor = os.open(
                        name, directory_flags, dir_fd=descriptor
                    )
                except OSError:
                    _fail(
                        "Owned temporary fixture directory changed before cleanup."
                    )
                try:
                    opened = os.fstat(child_descriptor)
                    if not _same_directory_object(before, opened):
                        _fail(
                            "Owned temporary fixture directory changed before cleanup."
                        )
                    remove_contents(child_descriptor)
                    after = os.fstat(child_descriptor)
                    if not _same_directory_object(opened, after):
                        _fail(
                            "Owned temporary fixture directory changed during cleanup."
                        )
                    os.rename(
                        name,
                        quarantined_name,
                        src_dir_fd=descriptor,
                        dst_dir_fd=descriptor,
                    )
                    visible = os.stat(
                        quarantined_name,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    if not _same_directory_object(opened, visible):
                        _fail(
                            "Owned temporary fixture directory identity became "
                            f"uncertain; retained {quarantined_name}."
                        )
                finally:
                    os.close(child_descriptor)
                os.rmdir(quarantined_name, dir_fd=descriptor)
            elif stat.S_ISREG(before.st_mode) and before.st_nlink == 1:
                file_descriptor = os.open(
                    name,
                    os.O_RDONLY
                    | os.O_NONBLOCK
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=descriptor,
                )
                try:
                    opened = os.fstat(file_descriptor)
                    if not _same_identity(before, opened):
                        _fail("Owned temporary fixture entry changed before cleanup.")
                    os.rename(
                        name,
                        quarantined_name,
                        src_dir_fd=descriptor,
                        dst_dir_fd=descriptor,
                    )
                    visible = os.stat(
                        quarantined_name,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )
                    if not _same_file_object(opened, visible):
                        _fail(
                            "Owned temporary fixture entry identity became uncertain; "
                            f"retained {quarantined_name}."
                        )
                finally:
                    os.close(file_descriptor)
                os.unlink(quarantined_name, dir_fd=descriptor)
            else:
                _fail("Owned temporary fixture root contains an unsafe entry; retained it.")

    workspace_descriptor = -1
    root_descriptor = -1
    try:
        workspace_descriptor = os.open(workspace, directory_flags)
        current = os.stat(
            root.name, dir_fd=workspace_descriptor, follow_symlinks=False
        )
        if not _same_directory_object(original, current):
            _fail("Owned temporary fixture root changed identity before cleanup.")
        root_descriptor = os.open(
            root.name, directory_flags, dir_fd=workspace_descriptor
        )
        opened_root = os.fstat(root_descriptor)
        if not _same_directory_object(original, opened_root):
            _fail("Owned temporary fixture root changed identity before cleanup.")
        remove_contents(root_descriptor)
        after_root = os.fstat(root_descriptor)
        if not _same_directory_object(opened_root, after_root):
            _fail("Owned temporary fixture root changed identity during cleanup.")
        quarantined_root = retained_name()
        os.rename(
            root.name,
            quarantined_root,
            src_dir_fd=workspace_descriptor,
            dst_dir_fd=workspace_descriptor,
        )
        visible_root = os.stat(
            quarantined_root,
            dir_fd=workspace_descriptor,
            follow_symlinks=False,
        )
        if not _same_directory_object(after_root, visible_root):
            _fail(
                "Owned temporary fixture root identity became uncertain; "
                f"retained {quarantined_root}."
            )
        os.close(root_descriptor)
        root_descriptor = -1
        os.rmdir(quarantined_root, dir_fd=workspace_descriptor)
    except FixtureError:
        raise
    except OSError as error:
        _fail(f"Could not safely clean the owned temporary fixture root: {error}.")
    finally:
        if root_descriptor >= 0:
            os.close(root_descriptor)
        if workspace_descriptor >= 0:
            os.close(workspace_descriptor)


def run_temporary_benchmark(
    *,
    workspace: Path,
    baseline_path: Path,
    name: str,
    command: list[str],
    entry_count: int = DEFAULT_ENTRY_COUNT,
    target_ply_mib: float = DEFAULT_PLY_MIB,
) -> dict[str, object]:
    """Generate, verify, measure, and remove one exact temporary fixture root."""

    _require_canonical(workspace, "Benchmark workspace")
    metadata = os.lstat(workspace)
    if not stat.S_ISDIR(metadata.st_mode):
        _fail("Benchmark workspace must be an ordinary directory.")
    root = Path(tempfile.mkdtemp(prefix=TEMPORARY_PREFIX, dir=workspace))
    original = os.lstat(root)
    fixture_root = root / "fixtures"
    try:
        generate_fixtures(
            fixture_root,
            entry_count=entry_count,
            target_ply_mib=target_ply_mib,
        )
        return measure_command(
            root=fixture_root,
            baseline_path=baseline_path,
            name=name,
            command=command,
        )
    finally:
        _remove_owned_temporary_root(root, workspace, original)


def run_product_performance_gate(
    *,
    workspace: Path,
    baseline_path: Path,
    test_binary: Path,
    entry_count: int = DEFAULT_ENTRY_COUNT,
    target_ply_mib: float = DEFAULT_PLY_MIB,
    output: Path | None = None,
) -> dict[str, object]:
    """Run each large fixture through its exact app/core XCTest entrypoint."""

    _require_canonical(workspace, "Product gate workspace")
    workspace_metadata = os.lstat(workspace)
    if not stat.S_ISDIR(workspace_metadata.st_mode):
        _fail("Product gate workspace must be an ordinary directory.")
    expected_binary_identity = _validate_product_test_binary(test_binary)
    for name, _ in PRODUCT_WORKLOADS:
        _load_baseline(baseline_path, name)

    root = Path(tempfile.mkdtemp(prefix=TEMPORARY_PREFIX, dir=workspace))
    original = os.lstat(root)
    fixture_root = root / "fixtures"
    required_check_parent = root / "required-checks"
    workload_parent = root / "workloads"
    measurements: dict[str, object] = {}
    required_checks: dict[str, object] = {}
    try:
        required_check_parent.mkdir(mode=0o700)
        for name, test_specifier, limit_seconds in PRODUCT_REQUIRED_CHECKS:
            check_root = required_check_parent / name
            check_root.mkdir(mode=0o700)
            required_checks[name] = _run_product_required_check(
                name=name,
                test_specifier=test_specifier,
                test_binary=test_binary,
                output_root=check_root,
                limit_seconds=limit_seconds,
            )
            check_root.rmdir()
            if not _same_identity(
                expected_binary_identity,
                _validate_product_test_binary(test_binary),
            ):
                _fail("Product test binary changed between release-gate phases.")
        required_check_parent.rmdir()
        generate_fixtures(
            fixture_root,
            entry_count=entry_count,
            target_ply_mib=target_ply_mib,
        )
        manifest = verify_fixtures(fixture_root)
        if int(manifest["entryCount"]) != DEFAULT_ENTRY_COUNT:
            _fail("Product gate requires the exact 10,000-entry release fixture.")
        ply = manifest.get("ply")
        if not isinstance(ply, dict) or float(ply.get("targetMiB", 0)) != DEFAULT_PLY_MIB:
            _fail("Product gate requires the exact 139.6 MiB release PLY fixture.")
        workload_parent.mkdir(mode=0o700)
        for name, test_specifier in PRODUCT_WORKLOADS:
            workload_root = workload_parent / name
            workload_root.mkdir(mode=0o700)
            measurements[name] = _measure_product_workload(
                fixture_root=fixture_root,
                output_root=workload_root,
                baseline_path=baseline_path,
                name=name,
                test_specifier=test_specifier,
                test_binary=test_binary,
            )
            workload_root.rmdir()
            if not _same_identity(
                expected_binary_identity,
                _validate_product_test_binary(test_binary),
            ):
                _fail("Product test binary changed between release-gate phases.")

        payload: dict[str, object] = {
            "fixtureManifestSHA256": hashlib.sha256(
                _canonical_json(manifest)
            ).hexdigest(),
            "measurements": measurements,
            "referenceHost": reference_host(),
            "requiredChecks": required_checks,
            "schemaVersion": 1,
            "status": "passed",
        }
        if output is not None:
            _write_result(output, payload)
        return payload
    finally:
        _remove_owned_temporary_root(root, workspace, original)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate and gate deterministic EasySplat reliability fixtures.",
        epilog=(
            "For measure/run, pass an argv after --. The helper substitutes "
            "{folder}, {zip}, and {ply} with authenticated fixture paths. "
            "The command must be a built EasySplatMeasurementRunner invocation. "
            "Fixture generation and verification are fixture-tool workloads, not "
            "product benchmarks. Product-gate runs four exact EasySplat XCTest "
            "workloads in separate measured processes."
        ),
    )
    commands = parser.add_subparsers(dest="action", required=True)
    generate = commands.add_parser("generate")
    generate.add_argument("--root", required=True, type=Path)
    generate.add_argument("--entry-count", type=int, default=DEFAULT_ENTRY_COUNT)
    generate.add_argument("--ply-mib", type=float, default=DEFAULT_PLY_MIB)
    verify = commands.add_parser("verify")
    verify.add_argument("--root", required=True, type=Path)
    measure = commands.add_parser("measure")
    measure.add_argument("--root", required=True, type=Path)
    measure.add_argument("--baseline", required=True, type=Path)
    measure.add_argument("--name", required=True)
    measure.add_argument("--output", type=Path)
    measure.add_argument("command", nargs=argparse.REMAINDER)
    run = commands.add_parser("run")
    run.add_argument("--workspace", required=True, type=Path)
    run.add_argument("--baseline", required=True, type=Path)
    run.add_argument("--name", required=True)
    run.add_argument("--entry-count", type=int, default=DEFAULT_ENTRY_COUNT)
    run.add_argument("--ply-mib", type=float, default=DEFAULT_PLY_MIB)
    run.add_argument("--output", type=Path)
    run.add_argument("command", nargs=argparse.REMAINDER)
    full_gate = commands.add_parser("full-gate")
    full_gate.add_argument("--workspace", required=True, type=Path)
    full_gate.add_argument("--baseline", required=True, type=Path)
    full_gate.add_argument("--entry-count", type=int, default=DEFAULT_ENTRY_COUNT)
    full_gate.add_argument("--ply-mib", type=float, default=DEFAULT_PLY_MIB)
    full_gate.add_argument("--output", type=Path)
    product_gate = commands.add_parser("product-gate")
    product_gate.add_argument("--workspace", required=True, type=Path)
    product_gate.add_argument("--baseline", required=True, type=Path)
    product_gate.add_argument("--test-binary", required=True, type=Path)
    product_gate.add_argument("--entry-count", type=int, default=DEFAULT_ENTRY_COUNT)
    product_gate.add_argument("--ply-mib", type=float, default=DEFAULT_PLY_MIB)
    product_gate.add_argument("--output", type=Path)
    return parser


def _command_arguments(arguments: list[str]) -> list[str]:
    return arguments[1:] if arguments[:1] == ["--"] else arguments


def main(arguments: list[str] | None = None) -> int:
    options = _parser().parse_args(arguments)
    try:
        if options.action == "generate":
            payload = generate_fixtures(
                options.root,
                entry_count=options.entry_count,
                target_ply_mib=options.ply_mib,
            )
        elif options.action == "verify":
            payload = verify_fixtures(options.root)
        elif options.action == "measure":
            payload = measure_command(
                root=options.root,
                baseline_path=options.baseline,
                name=options.name,
                command=_command_arguments(options.command),
                output=options.output,
            )
        elif options.action == "run":
            payload = run_temporary_benchmark(
                workspace=options.workspace,
                baseline_path=options.baseline,
                name=options.name,
                command=_command_arguments(options.command),
                entry_count=options.entry_count,
                target_ply_mib=options.ply_mib,
            )
            if options.output is not None:
                _write_result(options.output, payload)
        elif options.action == "full-gate":
            payload = run_full_fixture_gate(
                workspace=options.workspace,
                baseline_path=options.baseline,
                entry_count=options.entry_count,
                target_ply_mib=options.ply_mib,
                output=options.output,
            )
        else:
            payload = run_product_performance_gate(
                workspace=options.workspace,
                baseline_path=options.baseline,
                test_binary=options.test_binary,
                entry_count=options.entry_count,
                target_ply_mib=options.ply_mib,
                output=options.output,
            )
        print(_canonical_json(payload).decode("utf-8"), end="")
    except (FixtureError, OSError, zipfile.BadZipFile) as error:
        print(f"Release reliability fixture gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
