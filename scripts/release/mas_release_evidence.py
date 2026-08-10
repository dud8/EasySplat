#!/usr/bin/env python3
"""Create and verify a credential-free MAS/TestFlight provenance record."""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import secrets
import select
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Callable


GIT = "/usr/bin/git"
CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"
PKGUTIL = "/usr/sbin/pkgutil"
SCHEMA_VERSION = 1
MAX_PLIST_BYTES = 1024 * 1024
MAX_EVIDENCE_BYTES = 1024 * 1024
MAX_SIGNING_RECEIPT_BYTES = 4 * 1024 * 1024
SOURCE_SEAL_RELATIVE = "Contents/Resources/release_source.json"
DELIVERY_ID_PATTERN = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
SIGNING_HELPER = Path(__file__).with_name("sign_macos_distribution.py")
MAS_APP_REQUIREMENT_TEMPLATE = (
    "=anchor apple generic and "
    "certificate 1[field.1.2.840.113635.100.6.2.1] and "
    "certificate leaf[field.1.2.840.113635.100.6.1.7] and "
    'certificate leaf[subject.OU] = "{team_id}"'
)
MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
MH_EXECUTE = 0x2
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
CommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]
SigningReceiptValidator = Callable[..., dict[str, object]]


class ReleaseEvidenceError(RuntimeError):
    """The proposed release evidence is not authoritative."""


def _fail(message: str) -> None:
    raise ReleaseEvidenceError(message)


def _canonical_json(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _run_system(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(arguments, capture_output=True, text=True, check=False)


def _run(
    arguments: list[str],
    command_runner: CommandRunner,
    purpose: str,
) -> subprocess.CompletedProcess[str]:
    result = command_runner(arguments)
    if result.returncode != 0:
        _fail(f"{purpose} failed.")
    return result


def _require_canonical_path(path: Path, label: str) -> Path:
    raw = os.fspath(path)
    if not os.path.isabs(raw) or os.path.normpath(raw) != raw:
        _fail(f"{label} path must be absolute and normalized.")
    if os.path.realpath(raw) != raw:
        _fail(f"{label} path must contain no symlink ancestry.")
    return path


def _same_identity(first: os.stat_result, second: os.stat_result) -> bool:
    return all(getattr(first, field) == getattr(second, field) for field in IDENTITY_FIELDS)


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


def _identity_payload(metadata: os.stat_result) -> dict[str, int]:
    return {field: int(getattr(metadata, field)) for field in IDENTITY_FIELDS}


def _identity_from_payload(value: object, label: str) -> dict[str, int]:
    row = _require_exact_keys(value, set(IDENTITY_FIELDS), label)
    for field in IDENTITY_FIELDS:
        if isinstance(row[field], bool) or not isinstance(row[field], int):
            _fail(f"{label} has an invalid {field} value.")
    return {field: int(row[field]) for field in IDENTITY_FIELDS}


def _identity_matches_payload(metadata: os.stat_result, payload: dict[str, int]) -> bool:
    return all(int(getattr(metadata, field)) == payload[field] for field in IDENTITY_FIELDS)


def _stable_file_digest(
    path: Path,
    *,
    label: str,
    maximum_bytes: int | None = None,
) -> tuple[str, int, bytes | None]:
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail(f"Could not open {label}: {error.strerror or error}.")
    payload = bytearray() if maximum_bytes is not None else None
    digest = hashlib.sha256()
    byte_count = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail(f"{label} must be an ordinary, non-hardlinked regular file.")
        if maximum_bytes is not None and before.st_size > maximum_bytes:
            _fail(f"{label} exceeds its size limit.")
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            byte_count += len(chunk)
            digest.update(chunk)
            if payload is not None:
                payload.extend(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        visible = os.lstat(path)
    except OSError:
        _fail(f"{label} path changed while it was inspected.")
    if byte_count != before.st_size or not _same_identity(before, after):
        _fail(f"{label} changed while it was read.")
    if not _same_identity(after, visible):
        _fail(f"{label} path changed while it was read.")
    return digest.hexdigest(), byte_count, bytes(payload) if payload is not None else None


def _validate_with_distribution_signer(
    receipt_path: Path,
    *,
    kind: str,
    identity_fingerprint: str,
    team_id: str,
    current_artifact: Path,
) -> dict[str, object]:
    """Use the release signer's receipt contract without relying on sys.path."""

    spec = importlib.util.spec_from_file_location(
        "easysplat_distribution_signing_receipt", SIGNING_HELPER
    )
    if spec is None or spec.loader is None:
        _fail("Could not load the distribution signing receipt validator.")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
        validator = module.validate_signing_receipt
        signing_error = module.SigningError
    except (AttributeError, OSError):
        _fail("Could not load the distribution signing receipt validator.")
    try:
        return validator(
            receipt_path,
            kind=kind,
            identity_fingerprint=identity_fingerprint,
            team_id=team_id,
            current_artifact=current_artifact,
        )
    except signing_error as error:
        _fail(f"App signing receipt validation failed: {error}.")


def _resolve_app_signing_receipt(app: Path, receipt: Path | None) -> Path:
    selected = (
        receipt
        if receipt is not None
        else app.with_name(f"{app.name}-signing.json")
    )
    return _require_canonical_path(selected, "App signing receipt")


def _validated_app_signing_receipt_digest(
    app: Path,
    receipt: Path | None,
    *,
    expected_team_id: str,
    validator: SigningReceiptValidator,
) -> str:
    selected = _resolve_app_signing_receipt(app, receipt)
    digest_before, _, data_before = _stable_file_digest(
        selected,
        label="App signing receipt",
        maximum_bytes=MAX_SIGNING_RECEIPT_BYTES,
    )
    assert data_before is not None
    try:
        untrusted = json.loads(data_before)
    except (UnicodeDecodeError, json.JSONDecodeError):
        _fail("App signing receipt is not valid UTF-8 JSON.")
    if not isinstance(untrusted, dict):
        _fail("App signing receipt must contain a JSON object.")
    if untrusted.get("channel") != "mas":
        _fail("App signing receipt must prove the MAS signing channel.")
    if untrusted.get("teamID") != expected_team_id:
        _fail("App signing receipt names the wrong team.")
    fingerprint = untrusted.get("identityFingerprintSHA1")
    if (
        not isinstance(fingerprint, str)
        or re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint) is None
    ):
        _fail("App signing receipt has an invalid identity fingerprint.")
    validated = validator(
        selected,
        kind="app",
        identity_fingerprint=fingerprint,
        team_id=expected_team_id,
        current_artifact=app,
    )
    if validated != untrusted:
        _fail("App signing receipt changed while it was validated.")
    expected_bytes = (
        json.dumps(validated, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    if data_before != expected_bytes:
        _fail("App signing receipt is not canonical signer JSON.")
    digest_after, _, data_after = _stable_file_digest(
        selected,
        label="App signing receipt",
        maximum_bytes=MAX_SIGNING_RECEIPT_BYTES,
    )
    if digest_after != digest_before or data_after != data_before:
        _fail("App signing receipt changed while it was validated.")
    return digest_before


def _snapshot_tree(root: Path, label: str) -> dict[str, object]:
    _require_canonical_path(root, label)
    try:
        root_before = os.lstat(root)
    except OSError as error:
        _fail(f"{label} does not exist: {error.strerror or error}.")
    if not stat.S_ISDIR(root_before.st_mode):
        _fail(f"{label} must be an ordinary directory.")

    rows: list[list[object]] = []
    file_count = 0
    byte_count = 0
    for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        directory_names.sort(key=os.fsencode)
        file_names.sort(key=os.fsencode)
        current_path = Path(current)
        for name in directory_names:
            child = current_path / name
            metadata = os.lstat(child)
            relative = child.relative_to(root).as_posix()
            if not stat.S_ISDIR(metadata.st_mode):
                _fail(f"{label} contains an unsafe directory entry: {relative}.")
            if stat.S_IMODE(metadata.st_mode) & 0o022:
                _fail(f"{label} contains a writable directory: {relative}.")
            rows.append(["directory", relative, f"{stat.S_IMODE(metadata.st_mode):04o}"])
        for name in file_names:
            child = current_path / name
            relative = child.relative_to(root).as_posix()
            file_digest, size, _ = _stable_file_digest(
                child, label=f"{label} file {relative}"
            )
            metadata = os.lstat(child)
            if stat.S_IMODE(metadata.st_mode) & 0o022:
                _fail(f"{label} contains a writable file: {relative}.")
            rows.append(
                ["file", relative, f"{stat.S_IMODE(metadata.st_mode):04o}", size, file_digest]
            )
            file_count += 1
            byte_count += size

    root_after = os.lstat(root)
    if not _same_identity(root_before, root_after):
        _fail(f"{label} changed while it was inspected.")
    digest = hashlib.sha256(
        json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
    ).hexdigest()
    return {
        "byteCount": byte_count,
        "closureSHA256": digest,
        "fileCount": file_count,
    }


def _snapshot_combined_trees(roots: list[tuple[str, Path]], label: str) -> dict[str, object]:
    snapshots = []
    for relative, root in roots:
        snapshots.append([relative, _snapshot_tree(root, f"{label} {relative}")])
    payload = json.dumps(
        snapshots, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "byteCount": sum(int(row[1]["byteCount"]) for row in snapshots),
        "closureSHA256": hashlib.sha256(payload).hexdigest(),
        "fileCount": sum(int(row[1]["fileCount"]) for row in snapshots),
    }


def _remove_owned_tree(path: Path, original: os.stat_result, *, label: str) -> None:
    """Delete only a descriptor-bound tree; retain quarantined races for inspection."""

    _require_canonical_path(path.parent, f"{label} parent")
    if path.name in {"", ".", ".."} or "/" in path.name:
        _fail(f"{label} has an unsafe temporary name.")
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

    def quarantine_name() -> str:
        return f".easysplat-retained-{secrets.token_hex(12)}"

    def remove_contents(directory_descriptor: int) -> None:
        for name in sorted(os.listdir(directory_descriptor), key=os.fsencode):
            if name in {"", ".", ".."} or "/" in name:
                _fail(f"{label} contains an unsafe cleanup entry.")
            before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            retained = quarantine_name()
            if stat.S_ISDIR(before.st_mode):
                child_descriptor = os.open(
                    name, directory_flags, dir_fd=directory_descriptor
                )
                try:
                    opened = os.fstat(child_descriptor)
                    if not _same_directory_object(before, opened):
                        _fail(f"{label} directory changed before cleanup.")
                    remove_contents(child_descriptor)
                    if not _same_directory_object(opened, os.fstat(child_descriptor)):
                        _fail(f"{label} directory changed during cleanup.")
                    os.rename(
                        name,
                        retained,
                        src_dir_fd=directory_descriptor,
                        dst_dir_fd=directory_descriptor,
                    )
                    quarantined = os.stat(
                        retained, dir_fd=directory_descriptor, follow_symlinks=False
                    )
                    if not _same_directory_object(opened, quarantined):
                        _fail(
                            f"{label} cleanup identity became uncertain; retained {retained}."
                        )
                finally:
                    os.close(child_descriptor)
                os.rmdir(retained, dir_fd=directory_descriptor)
            elif stat.S_ISREG(before.st_mode) and before.st_nlink == 1:
                child_descriptor = os.open(name, file_flags, dir_fd=directory_descriptor)
                try:
                    opened = os.fstat(child_descriptor)
                    if not _same_identity(before, opened):
                        _fail(f"{label} file changed before cleanup.")
                    os.rename(
                        name,
                        retained,
                        src_dir_fd=directory_descriptor,
                        dst_dir_fd=directory_descriptor,
                    )
                    quarantined = os.stat(
                        retained, dir_fd=directory_descriptor, follow_symlinks=False
                    )
                    if not _same_file_object(opened, quarantined):
                        _fail(
                            f"{label} cleanup identity became uncertain; retained {retained}."
                        )
                finally:
                    os.close(child_descriptor)
                os.unlink(retained, dir_fd=directory_descriptor)
            else:
                _fail(f"{label} contains an unsafe cleanup entry; it was retained.")

    parent_descriptor = -1
    root_descriptor = -1
    retained_root = quarantine_name()
    try:
        parent_descriptor = os.open(path.parent, directory_flags)
        visible = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if not _same_directory_object(original, visible):
            _fail(f"{label} changed identity before cleanup and was retained.")
        root_descriptor = os.open(path.name, directory_flags, dir_fd=parent_descriptor)
        opened = os.fstat(root_descriptor)
        if not _same_directory_object(original, opened):
            _fail(f"{label} changed identity before cleanup and was retained.")
        remove_contents(root_descriptor)
        if not _same_directory_object(opened, os.fstat(root_descriptor)):
            _fail(f"{label} changed during cleanup and was retained.")
        os.rename(
            path.name,
            retained_root,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        quarantined = os.stat(
            retained_root, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if not _same_directory_object(opened, quarantined):
            _fail(
                f"{label} cleanup identity became uncertain; retained {retained_root}."
            )
        os.close(root_descriptor)
        root_descriptor = -1
        os.rmdir(retained_root, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except ReleaseEvidenceError:
        raise
    except OSError as error:
        _fail(f"Could not safely clean {label}; temporary files were retained: {error}.")
    finally:
        if root_descriptor >= 0:
            os.close(root_descriptor)
        if parent_descriptor >= 0:
            os.close(parent_descriptor)


def _secure_publish_bytes(path: Path, data: bytes, *, label: str) -> None:
    """Publish new bytes without ever opening or truncating the destination."""

    _require_canonical_path(path.parent, f"{label} output directory")
    if path.name in {"", ".", ".."} or "/" in path.name:
        _fail(f"{label} output has an unsafe name.")
    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_descriptor = os.open(path.parent, directory_flags)
    temporary = f".{path.name}.{secrets.token_hex(12)}"
    descriptor = -1
    temporary_exists = False
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        temporary_exists = True
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                _fail(f"Could not completely write {label}.")
            view = view[written:]
        os.fsync(descriptor)
        staged = os.fstat(descriptor)
        if (
            not stat.S_ISREG(staged.st_mode)
            or staged.st_nlink != 1
            or staged.st_size != len(data)
            or stat.S_IMODE(staged.st_mode) != 0o600
        ):
            _fail(f"Staged {label} failed descriptor validation.")
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(
                temporary,
                path.name,
                src_dir_fd=parent_descriptor,
                dst_dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError:
            _fail(f"{label} output already exists or appeared during publication.")
        os.unlink(temporary, dir_fd=parent_descriptor)
        temporary_exists = False
        os.fsync(parent_descriptor)
        digest, size, _ = _stable_file_digest(path, label=f"Published {label}")
        if size != len(data) or digest != hashlib.sha256(data).hexdigest():
            _fail(f"Published {label} does not match its staged bytes.")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_exists:
            try:
                os.unlink(temporary, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        os.close(parent_descriptor)


def _snapshot_token(
    *, snapshot: os.stat_result, parent: os.stat_result, sha256: str
) -> str:
    payload = {
        "parent": _identity_payload(parent),
        "sha256": sha256,
        "snapshot": _identity_payload(snapshot),
    }
    encoded = base64.urlsafe_b64encode(_canonical_json(payload)).decode("ascii")
    return encoded.rstrip("=")


def _parse_snapshot_token(token: str) -> dict[str, object]:
    if not isinstance(token, str) or re.fullmatch(r"[A-Za-z0-9_-]{32,4096}", token) is None:
        _fail("Package snapshot identity token is malformed.")
    padded = token + "=" * (-len(token) % 4)
    try:
        data = base64.b64decode(padded, altchars=b"-_", validate=True)
        value = json.loads(data)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        _fail("Package snapshot identity token is malformed.")
    row = _require_exact_keys(
        value, {"parent", "sha256", "snapshot"}, "Package snapshot identity token"
    )
    _require_digest(row["sha256"], "Package snapshot SHA-256")
    _identity_from_payload(row["parent"], "Package snapshot parent identity")
    _identity_from_payload(row["snapshot"], "Package snapshot file identity")
    if data != _canonical_json(value):
        _fail("Package snapshot identity token is not canonical.")
    return row


def snapshot_package(package: Path, output: Path) -> str:
    """Stream an authenticated package into a new private upload snapshot."""

    _require_canonical_path(package, "Installer package")
    _require_canonical_path(output.parent, "Package snapshot directory")
    if output.name in {"", ".", ".."} or "/" in output.name:
        _fail("Package snapshot has an unsafe name.")
    parent_metadata = os.lstat(output.parent)
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
    ):
        _fail("Package snapshot directory must be private, user-owned mode 0700.")
    source_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    source_descriptor = os.open(package, source_flags)
    parent_descriptor = os.open(output.parent, directory_flags)
    output_descriptor = -1
    output_created = False
    digest = hashlib.sha256()
    copied = 0
    try:
        source_before = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(source_before.st_mode)
            or source_before.st_nlink != 1
            or source_before.st_size <= 0
        ):
            _fail("Installer package must be an ordinary, non-hardlinked file.")
        if not _same_directory_object(parent_metadata, os.fstat(parent_descriptor)):
            _fail("Package snapshot directory changed before creation.")
        output_descriptor = os.open(
            output.name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        output_created = True
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            copied += len(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(output_descriptor, view)
                if written <= 0:
                    _fail("Could not completely write the private package snapshot.")
                view = view[written:]
        os.fsync(output_descriptor)
        source_after = os.fstat(source_descriptor)
        snapshot_metadata = os.fstat(output_descriptor)
        visible_source = os.lstat(package)
        visible_snapshot = os.stat(
            output.name, dir_fd=parent_descriptor, follow_symlinks=False
        )
        if (
            copied != source_before.st_size
            or not _same_identity(source_before, source_after)
            or not _same_identity(source_after, visible_source)
        ):
            _fail("Installer package changed while its upload snapshot was created.")
        if (
            not stat.S_ISREG(snapshot_metadata.st_mode)
            or snapshot_metadata.st_nlink != 1
            or snapshot_metadata.st_size != copied
            or stat.S_IMODE(snapshot_metadata.st_mode) != 0o600
            or not _same_identity(snapshot_metadata, visible_snapshot)
        ):
            _fail("Private package snapshot failed descriptor validation.")
        os.fsync(parent_descriptor)
        return _snapshot_token(
            snapshot=snapshot_metadata,
            parent=os.fstat(parent_descriptor),
            sha256=digest.hexdigest(),
        )
    except BaseException:
        if output_created:
            try:
                current = os.stat(
                    output.name, dir_fd=parent_descriptor, follow_symlinks=False
                )
                if output_descriptor >= 0 and _same_identity(
                    os.fstat(output_descriptor), current
                ):
                    os.unlink(output.name, dir_fd=parent_descriptor)
            except OSError:
                pass
        raise
    finally:
        if output_descriptor >= 0:
            os.close(output_descriptor)
        os.close(parent_descriptor)
        os.close(source_descriptor)


def verify_package_snapshot(path: Path, descriptor: int, token: str) -> None:
    """Prove a held descriptor and visible path still name the exact snapshot."""

    _require_canonical_path(path.parent, "Package snapshot directory")
    if not path.is_absolute() or path.name in {"", ".", ".."}:
        _fail("Package snapshot path must be absolute and normalized.")
    payload = _parse_snapshot_token(token)
    snapshot_identity = _identity_from_payload(
        payload["snapshot"], "Package snapshot file identity"
    )
    parent_identity = _identity_from_payload(
        payload["parent"], "Package snapshot parent identity"
    )
    before = os.fstat(descriptor)
    if not _identity_matches_payload(before, snapshot_identity):
        _fail("Held package snapshot descriptor has the wrong identity.")
    digest = hashlib.sha256()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
        if not chunk:
            _fail("Held package snapshot ended before its recorded size.")
        digest.update(chunk)
        offset += len(chunk)
    after = os.fstat(descriptor)
    try:
        visible = os.lstat(path)
        parent = os.lstat(path.parent)
    except OSError:
        _fail("Package snapshot path changed around App Store invocation.")
    if (
        not _same_identity(before, after)
        or not _same_identity(after, visible)
        or not _identity_matches_payload(parent, parent_identity)
        or digest.hexdigest() != payload["sha256"]
    ):
        _fail("Package snapshot identity changed around App Store invocation.")


def run_bound_package_command(
    *,
    snapshot: Path,
    descriptor: int,
    token: str,
    arguments: list[str],
) -> int:
    """Run a pathname-only tool while kqueue detects transient vnode swaps."""

    if not arguments or not os.path.isabs(arguments[0]):
        _fail("Bound package command must name one absolute executable.")
    verify_package_snapshot(snapshot, descriptor, token)
    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_descriptor = os.open(snapshot.parent, directory_flags)
    queue = select.kqueue()
    vnode_events = (
        select.KQ_NOTE_WRITE
        | select.KQ_NOTE_EXTEND
        | select.KQ_NOTE_ATTRIB
        | select.KQ_NOTE_LINK
        | select.KQ_NOTE_RENAME
        | select.KQ_NOTE_DELETE
        | select.KQ_NOTE_REVOKE
    )
    registrations = [
        select.kevent(
            watched,
            filter=select.KQ_FILTER_VNODE,
            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
            fflags=vnode_events,
        )
        for watched in (descriptor, parent_descriptor)
    ]
    try:
        queue.control(registrations, 0, 0)
        try:
            result = subprocess.run(arguments, check=False)
        except OSError:
            _fail("Bound App Store command could not be launched.")
        events = queue.control(None, 16, 0)
        verify_package_snapshot(snapshot, descriptor, token)
        if events:
            _fail("Private package snapshot changed while App Store Connect opened it.")
        if result.returncode < 0:
            return 128 + min(-result.returncode, 127)
        return result.returncode
    finally:
        queue.close()
        os.close(parent_descriptor)


def cleanup_package_snapshot(
    root: Path, path: Path, descriptor: int, token: str
) -> None:
    """Remove only the exact private snapshot tree, retaining any uncertainty."""

    if path.parent != root:
        _fail("Package snapshot is outside its owned cleanup root.")
    verify_package_snapshot(path, descriptor, token)
    payload = _parse_snapshot_token(token)
    parent_identity = _identity_from_payload(
        payload["parent"], "Package snapshot parent identity"
    )
    root_metadata = os.lstat(root)
    if not _identity_matches_payload(root_metadata, parent_identity):
        _fail("Package snapshot cleanup root changed identity and was retained.")
    if sorted(os.listdir(root), key=os.fsencode) != [path.name]:
        _fail("Package snapshot cleanup root contains unknown files and was retained.")
    _remove_owned_tree(root, root_metadata, label="Package snapshot cleanup root")


def cleanup_submission_responses(root: Path, response_paths: list[Path]) -> None:
    """Remove only the bounded response files created in a private owned root."""

    _require_canonical_path(root, "Submission response cleanup root")
    root_metadata = os.lstat(root)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        _fail("Submission response cleanup root is not a private owned directory.")
    if not response_paths:
        _fail("Submission response cleanup has no owned files.")
    allowed_response_names = {"processing-response.json", "upload-response.json"}
    response_names: list[str] = []
    for response in response_paths:
        if response.parent != root or response.name not in allowed_response_names:
            _fail("Submission response path is outside its owned cleanup root.")
        if response.name in response_names:
            _fail("Submission response cleanup repeats a response file.")
        metadata = os.lstat(response)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_size > MAX_EVIDENCE_BYTES
            or stat.S_IMODE(metadata.st_mode) & 0o077
        ):
            _fail("Submission response is not a bounded private file.")
        response_names.append(response.name)
    expected_names = sorted(response_names, key=os.fsencode)
    if sorted(os.listdir(root), key=os.fsencode) != expected_names:
        _fail("Submission response cleanup root contains unknown files and was retained.")
    _remove_owned_tree(root, root_metadata, label="Submission response cleanup root")


def _git_output(repository: Path, *arguments: str) -> str:
    environment = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "HOME": "/var/empty",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "XDG_CONFIG_HOME": "/var/empty",
    }
    result = subprocess.run(
        [
            GIT,
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.preloadindex=false",
            "-c",
            "core.untrackedCache=false",
            "-C",
            os.fspath(repository),
            *arguments,
        ],
        capture_output=True,
        text=True,
        check=False,
        env=environment,
    )
    if result.returncode != 0:
        _fail("Could not verify the release source checkout.")
    return result.stdout.strip()


def _source_snapshot(repository: Path, expected_source_commit: str | None) -> dict[str, str]:
    _require_canonical_path(repository, "Repository")
    if _git_output(repository, "rev-parse", "--show-toplevel") != os.fspath(repository):
        _fail("Release source must be the repository root.")
    status = _git_output(repository, "status", "--porcelain=v1", "--untracked-files=all")
    if status:
        _fail("Release source checkout must be clean.")
    head = _git_output(repository, "rev-parse", "HEAD").lower()
    if re.fullmatch(r"[0-9a-f]{40}", head) is None:
        _fail("Release source HEAD is not an exact 40-hex commit.")
    source_commit = head if expected_source_commit is None else expected_source_commit.lower()
    if re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
        _fail("Reviewed source commit must be exactly 40 hexadecimal characters.")
    resolved = _git_output(repository, "rev-parse", "--verify", f"{source_commit}^{{commit}}")
    if resolved.lower() != source_commit:
        _fail("Reviewed source commit does not resolve exactly.")
    head_tree = _git_output(repository, "rev-parse", f"{head}^{{tree}}")
    reviewed_tree = _git_output(repository, "rev-parse", f"{source_commit}^{{tree}}")
    if head != source_commit and head_tree != reviewed_tree:
        _fail("Reviewed source commit does not match the clean checkout tree.")
    return {"commit": source_commit, "head": head, "treeObjectID": reviewed_tree}


def _read_info_plist(app: Path) -> dict[str, object]:
    _, _, data = _stable_file_digest(
        app / "Contents/Info.plist",
        label="App Info.plist",
        maximum_bytes=MAX_PLIST_BYTES,
    )
    assert data is not None
    try:
        value = plistlib.loads(data)
    except (plistlib.InvalidFileException, ValueError) as error:
        _fail(f"App Info.plist is invalid: {error}.")
    if not isinstance(value, dict):
        _fail("App Info.plist must contain a dictionary.")
    return value


def _codesign_metadata(
    target: Path,
    expected_team_id: str,
    command_runner: CommandRunner,
    *,
    label: str,
) -> dict[str, object]:
    store_requirement = MAS_APP_REQUIREMENT_TEMPLATE.format(team_id=expected_team_id)
    _run(
        [
            CODESIGN,
            "--verify",
            "--strict",
            "--verbose=4",
            "--test-requirement",
            store_requirement,
            os.fspath(target),
        ],
        command_runner,
        f"{label} Apple Distribution signature verification",
    )
    result = _run(
        [CODESIGN, "--display", "--verbose=4", os.fspath(target)],
        command_runner,
        f"{label} signature inspection",
    )
    text = f"{result.stdout}\n{result.stderr}"
    cdhashes = re.findall(r"(?m)^CDHash=([0-9A-Fa-f]{40})$", text)
    teams = re.findall(r"(?m)^TeamIdentifier=([A-Z0-9]{10})$", text)
    authorities = re.findall(r"(?m)^Authority=(.+)$", text)
    if len(cdhashes) != 1 or len(teams) != 1 or not authorities:
        _fail("App signature metadata is incomplete.")
    if teams[0] != expected_team_id:
        _fail("App signature has the wrong TeamIdentifier.")
    return {
        "authorities": authorities,
        "cdhash": cdhashes[0].lower(),
        "signatureTeamID": teams[0],
    }


def _sealed_entitlements(
    target: Path,
    *,
    label: str,
    command_runner: CommandRunner,
) -> dict[str, object] | None:
    result = _run(
        [CODESIGN, "--display", "--entitlements", "-", "--xml", os.fspath(target)],
        command_runner,
        f"{label} entitlement inspection",
    )
    combined = f"{result.stdout}\n{result.stderr}".encode("utf-8")
    match = re.search(rb"<\?xml.*?</plist>", combined, re.DOTALL)
    if match is None:
        return None
    try:
        value = plistlib.loads(match.group(0))
    except plistlib.InvalidFileException:
        _fail(f"{label} has invalid sealed entitlements.")
    if not isinstance(value, dict):
        _fail(f"{label} sealed entitlements must be a dictionary.")
    return value


def _entitlement_digest(value: dict[str, object]) -> str:
    canonical = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _expected_app_entitlements(bundle_id: str, team_id: str) -> dict[str, object]:
    return {
        "com.apple.application-identifier": f"{team_id}.{bundle_id}",
        "com.apple.developer.team-identifier": team_id,
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-write": True,
    }


def _expected_helper_entitlements() -> dict[str, object]:
    return {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.inherit": True,
    }


def _macho_file_type(path: Path, *, label: str) -> int | None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail(f"{label} must be an ordinary, non-hardlinked file.")
        header = os.pread(descriptor, 16, 0)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(path)
    if not _same_identity(before, after) or not _same_identity(after, visible):
        _fail(f"{label} changed while its Mach-O header was inspected.")
    if len(header) < 4 or header[:4] not in MACHO_MAGICS:
        return None
    if len(header) < 16 or header[:4] in {
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf",
        b"\xbf\xba\xfe\xca",
    }:
        _fail(f"{label} must be a thin arm64 Mach-O.")
    byte_order = "little" if header[:4] in {b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"} else "big"
    return int.from_bytes(header[12:16], byte_order)


def _discover_app_code(app: Path) -> list[tuple[str, Path, int]]:
    discovered: list[tuple[str, Path, int]] = []
    for current, directory_names, file_names in os.walk(
        app, topdown=True, followlinks=False
    ):
        directory_names.sort(key=os.fsencode)
        file_names.sort(key=os.fsencode)
        for name in file_names:
            path = Path(current) / name
            relative = path.relative_to(app).as_posix()
            metadata = os.lstat(path)
            file_type = _macho_file_type(path, label=f"App code candidate {relative}")
            code_shaped = (
                bool(stat.S_IMODE(metadata.st_mode) & 0o111)
                or path.suffix == ".dylib"
                or relative.startswith("Contents/Helpers/")
            )
            if code_shaped and file_type is None:
                _fail(f"Bundled executable or helper is not Mach-O code: {relative}.")
            if file_type is not None:
                discovered.append((relative, path, file_type))
    discovered.sort(key=lambda row: os.fsencode(row[0]))
    return discovered


def _inspect_app_code(
    app: Path,
    *,
    main_relative: str,
    bundle_id: str,
    team_id: str,
    command_runner: CommandRunner,
) -> tuple[list[dict[str, object]], dict[str, str]]:
    expected_app = {
        **_expected_app_entitlements(bundle_id, team_id),
    }
    expected_helper = _expected_helper_entitlements()
    rows: list[dict[str, object]] = []
    digests: dict[str, str] = {}
    for relative, target, file_type in _discover_app_code(app):
        architectures = _run(
            [LIPO, "-archs", os.fspath(target)],
            command_runner,
            f"Architecture inspection for {relative}",
        ).stdout.split()
        if architectures != ["arm64"]:
            _fail(f"Bundled code is not exactly arm64: {relative}.")
        signature = _codesign_metadata(
            target,
            team_id,
            command_runner,
            label=f"Bundled code {relative}",
        )
        entitlements = _sealed_entitlements(
            target,
            label=f"Bundled code {relative}",
            command_runner=command_runner,
        )
        if relative == main_relative:
            kind = "mainExecutable"
            expected_entitlements = expected_app
        elif file_type == MH_EXECUTE:
            if not relative.startswith("Contents/Helpers/"):
                _fail(f"Unexpected executable outside the helper directory: {relative}.")
            kind = "helperExecutable"
            expected_entitlements = expected_helper
        else:
            kind = "library"
            expected_entitlements = None
        if entitlements != expected_entitlements:
            _fail(f"Bundled code has unexpected sealed entitlements: {relative}.")
        entitlement_digest = (
            _entitlement_digest(entitlements) if entitlements is not None else None
        )
        if entitlement_digest is not None:
            digests[relative] = entitlement_digest
        rows.append(
            {
                "architectures": architectures,
                "entitlementsSHA256": entitlement_digest,
                "kind": kind,
                "relativePath": relative,
                **signature,
            }
        )
    if [row["relativePath"] for row in rows if row["kind"] == "mainExecutable"] != [
        main_relative
    ]:
        _fail("App code inventory does not contain its one declared main executable.")
    return rows, digests


def _inspect_app(
    app: Path,
    *,
    expected_version: str,
    expected_build: str | None,
    expected_bundle_id: str,
    expected_team_id: str,
    command_runner: CommandRunner,
) -> tuple[dict[str, object], dict[str, object]]:
    _require_canonical_path(app, "App")
    closure_before = _snapshot_tree(app, "App bundle")
    info = _read_info_plist(app)
    authenticated_build = info.get("CFBundleVersion")
    if (
        not isinstance(authenticated_build, str)
        or re.fullmatch(r"(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}", authenticated_build)
        is None
    ):
        _fail("App CFBundleVersion is not a valid release build number.")
    if expected_build is None:
        expected_build = authenticated_build
    expected_values = {
        "CFBundleIdentifier": expected_bundle_id,
        "CFBundleShortVersionString": expected_version,
        "CFBundleVersion": expected_build,
    }
    for key, expected in expected_values.items():
        if info.get(key) != expected:
            _fail(f"App {key} does not match the reviewed release value.")
    executable_name = info.get("CFBundleExecutable")
    if (
        not isinstance(executable_name, str)
        or executable_name in {"", ".", ".."}
        or Path(executable_name).name != executable_name
    ):
        _fail("App has an invalid CFBundleExecutable.")
    executable = app / "Contents/MacOS" / executable_name
    _stable_file_digest(executable, label="App executable")
    main_relative = f"Contents/MacOS/{executable_name}"
    signature = _codesign_metadata(
        app, expected_team_id, command_runner, label="App bundle"
    )
    app_entitlements = _sealed_entitlements(
        app,
        label="App bundle",
        command_runner=command_runner,
    )
    expected_app_entitlements = _expected_app_entitlements(
        expected_bundle_id, expected_team_id
    )
    if app_entitlements != expected_app_entitlements:
        _fail("App bundle has broader or unexpected sealed entitlements.")
    code, entitlement_digests = _inspect_app_code(
        app,
        main_relative=main_relative,
        bundle_id=expected_bundle_id,
        team_id=expected_team_id,
        command_runner=command_runner,
    )
    entitlement_digests["."] = _entitlement_digest(expected_app_entitlements)
    sealed_source = _validate_sealed_source(
        _load_canonical_json(app / SOURCE_SEAL_RELATIVE, "Sealed app source")
    )
    closure_after = _snapshot_tree(app, "App bundle")
    if closure_before != closure_after:
        _fail("App bundle changed while release evidence was prepared.")

    helpers = app / "Contents/Helpers"
    resources = app / "Contents/Resources/Toolchain"
    toolchain = _snapshot_combined_trees(
        [("Contents/Helpers", helpers), ("Contents/Resources/Toolchain", resources)],
        "Bundled toolchain",
    )
    provenance = _snapshot_tree(
        resources / "supply-chain", "Bundled toolchain provenance"
    )
    toolchain["provenanceSHA256"] = provenance["closureSHA256"]
    return (
        {
            "architectures": ["arm64"],
            "build": expected_build,
            "bundleID": expected_bundle_id,
            "code": code,
            "closureSHA256": closure_after["closureSHA256"],
            "entitlementsSHA256": entitlement_digests,
            "sealedSource": sealed_source,
            "version": expected_version,
            **signature,
        },
        toolchain,
    )


def _inspect_packaged_app(
    package: Path,
    *,
    expected_version: str,
    expected_build: str,
    expected_bundle_id: str,
    expected_team_id: str,
    command_runner: CommandRunner,
) -> tuple[dict[str, object], dict[str, object]]:
    temporary_root = Path(tempfile.mkdtemp(prefix="easysplat-mas-package-")).resolve()
    temporary_identity = os.lstat(temporary_root)
    expanded = temporary_root / "expanded"
    try:
        _run(
            [PKGUTIL, "--expand-full", os.fspath(package), os.fspath(expanded)],
            command_runner,
            "Installer payload expansion",
        )
        _snapshot_tree(expanded, "Expanded installer package")
        component_name = f"{expected_bundle_id}.pkg"
        if set(os.listdir(expanded)) != {"Distribution", component_name}:
            _fail("Expanded installer package has unexpected top-level structure.")
        distribution = os.lstat(expanded / "Distribution")
        component = expanded / component_name
        if not stat.S_ISREG(distribution.st_mode) or not stat.S_ISDIR(
            os.lstat(component).st_mode
        ):
            _fail("Expanded installer package has invalid product structure.")
        if set(os.listdir(component)) != {"Bom", "PackageInfo", "Payload"}:
            _fail("Installer component contains scripts or unexpected files.")
        payload = component / "Payload"
        app = payload / "EasySplat.app"
        if set(os.listdir(payload)) != {app.name} or not stat.S_ISDIR(
            os.lstat(app).st_mode
        ):
            _fail("Installer payload must contain only EasySplat.app.")
        _, _, package_info_bytes = _stable_file_digest(
            component / "PackageInfo",
            label="Installer PackageInfo",
            maximum_bytes=MAX_PLIST_BYTES,
        )
        assert package_info_bytes is not None
        try:
            package_info = ET.fromstring(package_info_bytes)
        except ET.ParseError as error:
            _fail(f"Installer PackageInfo is invalid XML: {error}.")
        if (
            package_info.tag != "pkg-info"
            or package_info.attrib.get("identifier") != expected_bundle_id
            or package_info.attrib.get("install-location") != "/Applications"
            or any(element.tag.lower().endswith("script") for element in package_info.iter())
        ):
            _fail("Installer PackageInfo has an unsafe identifier, script, or install location.")
        return _inspect_app(
            app,
            expected_version=expected_version,
            expected_build=expected_build,
            expected_bundle_id=expected_bundle_id,
            expected_team_id=expected_team_id,
            command_runner=command_runner,
        )
    finally:
        _remove_owned_tree(
            temporary_root,
            temporary_identity,
            label="Expanded package temporary root",
        )


def _write_new_json(path: Path, payload: dict[str, object]) -> None:
    _secure_publish_bytes(path, _canonical_json(payload), label="release evidence")


def publish_checksum(package: Path, output: Path) -> str:
    """Publish a new checksum sidecar without opening the selected output path."""

    digest, byte_count, _ = _stable_file_digest(package, label="Installer package")
    if byte_count <= 0:
        _fail("Installer package must not be empty.")
    _secure_publish_bytes(
        output, f"{digest}\n".encode("ascii"), label="installer checksum"
    )
    digest_after, byte_count_after, _ = _stable_file_digest(
        package, label="Installer package"
    )
    if digest_after != digest or byte_count_after != byte_count:
        _fail("Installer package changed while its checksum was published.")
    return digest


def publish_release_set(
    *,
    staging_directory: Path,
    package_output: Path,
    evidence_output: Path,
    checksum_output: Path,
) -> bool:
    """Publish one validated MAS release set, with the package as its commit."""

    outputs = (
        ("EasySplat.pkg.provenance.json", evidence_output, "release evidence"),
        ("EasySplat.pkg.sha256", checksum_output, "installer checksum"),
        ("EasySplat.pkg", package_output, "installer package"),
    )
    parent = _require_canonical_path(package_output.parent, "MAS release output directory")
    if any(output.parent != parent for _, output, _ in outputs):
        _fail("MAS release outputs must share one directory.")
    for _, output, label in outputs:
        _require_canonical_path(output, label)
        if output.name in {"", ".", ".."} or "/" in output.name:
            _fail(f"{label} output has an unsafe name.")
    _require_canonical_path(staging_directory, "MAS release staging directory")
    if (
        staging_directory.parent != parent
        or not staging_directory.name.startswith(".easysplat-mas-package.")
    ):
        _fail("MAS release staging must be a private child of the output directory.")

    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    file_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_descriptor = -1
    staging_descriptor = -1
    opened_files: dict[str, int] = {}
    staged_digests: dict[str, tuple[str, int]] = {}
    created: list[tuple[str, str]] = []
    committed = False

    def descriptor_digest(descriptor: int, label: str) -> tuple[str, int]:
        before = os.fstat(descriptor)
        digest = hashlib.sha256()
        offset = 0
        while True:
            chunk = os.pread(descriptor, 1024 * 1024, offset)
            if not chunk:
                break
            digest.update(chunk)
            offset += len(chunk)
        after = os.fstat(descriptor)
        if not _same_identity(before, after) or offset != after.st_size:
            _fail(f"Staged {label} changed while it was hashed.")
        return digest.hexdigest(), offset

    def descriptor_bytes(
        descriptor: int, label: str, maximum_bytes: int
    ) -> bytes:
        before = os.fstat(descriptor)
        if before.st_size > maximum_bytes:
            _fail(f"Staged {label} exceeds its size limit.")
        blocks: list[bytes] = []
        offset = 0
        while offset < before.st_size:
            block = os.pread(
                descriptor,
                min(64 * 1024, before.st_size - offset),
                offset,
            )
            if not block:
                _fail(f"Staged {label} ended before its declared size.")
            blocks.append(block)
            offset += len(block)
        after = os.fstat(descriptor)
        if not _same_identity(before, after) or offset != after.st_size:
            _fail(f"Staged {label} changed while it was read.")
        return b"".join(blocks)

    def rollback_created() -> bool:
        conflict = False
        for staged_name, output_name in reversed(created):
            descriptor = opened_files[staged_name]
            try:
                current = os.stat(
                    output_name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            held = os.fstat(descriptor)
            if current.st_dev == held.st_dev and current.st_ino == held.st_ino:
                os.unlink(output_name, dir_fd=parent_descriptor)
            else:
                conflict = True
        try:
            os.fsync(parent_descriptor)
        except OSError:
            conflict = True
        return conflict

    def sync_parent() -> None:
        try:
            os.fsync(parent_descriptor)
        except OSError as error:
            _fail(f"MAS release output directory sync failed: {error}.")

    try:
        parent_before = os.lstat(parent)
        parent_descriptor = os.open(parent, directory_flags)
        parent_opened = os.fstat(parent_descriptor)
        if not _same_directory_object(parent_before, parent_opened):
            _fail("MAS release output directory changed before publication.")

        staging_visible = os.stat(
            staging_directory.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        staging_descriptor = os.open(
            staging_directory.name,
            directory_flags,
            dir_fd=parent_descriptor,
        )
        staging_opened = os.fstat(staging_descriptor)
        if (
            not _same_directory_object(staging_visible, staging_opened)
            or staging_opened.st_uid != os.getuid()
            or stat.S_IMODE(staging_opened.st_mode) != 0o700
        ):
            _fail("MAS release staging directory is not private and stable.")

        for staged_name, output, label in outputs:
            descriptor = os.open(staged_name, file_flags, dir_fd=staging_descriptor)
            opened_files[staged_name] = descriptor
            opened = os.fstat(descriptor)
            visible = os.stat(
                staged_name,
                dir_fd=staging_descriptor,
                follow_symlinks=False,
            )
            if (
                not _same_identity(opened, visible)
                or not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink != 1
                or opened.st_size <= 0
                or stat.S_IMODE(opened.st_mode) & 0o022
            ):
                _fail(f"Staged {label} is not a stable private regular file.")
            staged_digests[staged_name] = descriptor_digest(descriptor, label)
            try:
                os.stat(output.name, dir_fd=parent_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _fail(f"{label} output already exists before publication.")

        package_digest, package_size = staged_digests["EasySplat.pkg"]
        expected_checksum = f"{package_digest}\n".encode("ascii")
        checksum_bytes = descriptor_bytes(
            opened_files["EasySplat.pkg.sha256"],
            "installer checksum",
            65,
        )
        if checksum_bytes != expected_checksum:
            _fail("Staged installer checksum does not match the staged package.")
        evidence_bytes = descriptor_bytes(
            opened_files["EasySplat.pkg.provenance.json"],
            "release evidence",
            MAX_EVIDENCE_BYTES,
        )
        try:
            evidence_payload = json.loads(evidence_bytes)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            _fail(f"Staged release evidence is invalid JSON: {error}.")
        if (
            not isinstance(evidence_payload, dict)
            or evidence_bytes != _canonical_json(evidence_payload)
        ):
            _fail("Staged release evidence is not canonical sorted JSON.")
        evidence_package = _validate_final(evidence_payload)["package"]
        assert isinstance(evidence_package, dict)
        if (
            evidence_package["sha256"] != package_digest
            or evidence_package["byteCount"] != package_size
        ):
            _fail("Staged release evidence does not match the staged package.")

        for staged_name, _, label in outputs:
            descriptor = opened_files[staged_name]
            try:
                os.fsync(descriptor)
            except OSError as error:
                _fail(f"Staged {label} sync failed: {error}.")
            if not _same_identity(
                os.fstat(descriptor),
                os.stat(
                    staged_name,
                    dir_fd=staging_descriptor,
                    follow_symlinks=False,
                ),
            ):
                _fail(f"Staged {label} changed while it was synchronized.")

        for staged_name, output, label in outputs[:-1]:
            if not _same_identity(
                os.fstat(opened_files[staged_name]),
                os.stat(
                    staged_name,
                    dir_fd=staging_descriptor,
                    follow_symlinks=False,
                ),
            ):
                _fail(f"Staged {label} changed before publication.")
            try:
                os.link(
                    staged_name,
                    output.name,
                    src_dir_fd=staging_descriptor,
                    dst_dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError:
                _fail(f"{label} output appeared during publication.")
            except OSError as error:
                _fail(f"Could not publish {label}: {error}.")
            created.append((staged_name, output.name))

        # Make both sidecar names and all three staged file contents durable
        # before the package name can become the authority-conferring commit.
        sync_parent()
        staged_name, output, label = outputs[-1]
        if not _same_identity(
            os.fstat(opened_files[staged_name]),
            os.stat(
                staged_name,
                dir_fd=staging_descriptor,
                follow_symlinks=False,
            ),
        ):
            _fail(f"Staged {label} changed before publication.")
        try:
            os.link(
                staged_name,
                output.name,
                src_dir_fd=staging_descriptor,
                dst_dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError:
            _fail(f"{label} output appeared during publication.")
        except OSError as error:
            _fail(f"Could not publish {label}: {error}.")
        created.append((staged_name, output.name))
        sync_parent()
        for staged_name, output, label in outputs:
            held = os.fstat(opened_files[staged_name])
            published = os.stat(
                output.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            visible = os.stat(
                staged_name,
                dir_fd=staging_descriptor,
                follow_symlinks=False,
            )
            if (
                not _same_identity(held, published)
                or not _same_identity(held, visible)
                or held.st_nlink != 2
            ):
                _fail(f"Published {label} does not match its staged file.")

        # Sidecars become visible first. The package name is linked last above,
        # so its presence is the authority-conferring commit for the set.
        for staged_name, _, _ in outputs:
            os.unlink(staged_name, dir_fd=staging_descriptor)
        sync_parent()

        for staged_name, output, label in outputs:
            held = os.fstat(opened_files[staged_name])
            published = os.stat(
                output.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            digest, byte_count = descriptor_digest(opened_files[staged_name], label)
            if (
                not _same_identity(held, published)
                or held.st_nlink != 1
                or (digest, byte_count) != staged_digests[staged_name]
            ):
                _fail(f"Published {label} changed during commit.")
        if not _same_directory_object(parent_opened, os.lstat(parent)):
            _fail("MAS release output directory changed during publication.")
        committed = True
    except (ReleaseEvidenceError, OSError) as error:
        if created and rollback_created():
            raise ReleaseEvidenceError(
                "MAS release publication conflicted during rollback; foreign files were preserved."
            ) from None
        if isinstance(error, ReleaseEvidenceError):
            raise
        raise ReleaseEvidenceError(f"MAS release publication failed: {error}.") from None
    finally:
        for descriptor in opened_files.values():
            os.close(descriptor)
        if staging_descriptor >= 0:
            os.close(staging_descriptor)
        if parent_descriptor >= 0:
            os.close(parent_descriptor)

    if not committed:
        return False
    try:
        current_staging = os.lstat(staging_directory)
        if not _same_directory_object(staging_opened, current_staging):
            return False
        os.rmdir(staging_directory)
        return True
    except OSError:
        # Unknown or conflicting entries are deliberately retained. The release
        # is already committed and cleanup must not turn that success into a
        # false package failure.
        return False


def prepare_evidence(
    *,
    repository: Path,
    app: Path,
    expected_version: str,
    expected_build: str | None,
    expected_bundle_id: str,
    expected_team_id: str,
    expected_source_commit: str | None,
    output: Path,
    app_signing_receipt: Path | None = None,
    command_runner: CommandRunner = _run_system,
    signing_receipt_validator: SigningReceiptValidator = _validate_with_distribution_signer,
) -> dict[str, object]:
    """Snapshot the reviewed source and exact app before productbuild reads it."""

    if re.fullmatch(r"[A-Z0-9]{10}", expected_team_id) is None:
        _fail("Expected Team ID must be exactly 10 uppercase letters or digits.")
    signing_receipt_digest = _validated_app_signing_receipt_digest(
        app,
        app_signing_receipt,
        expected_team_id=expected_team_id,
        validator=signing_receipt_validator,
    )
    app_evidence, toolchain_evidence = _inspect_app(
        app,
        expected_version=expected_version,
        expected_build=expected_build,
        expected_bundle_id=expected_bundle_id,
        expected_team_id=expected_team_id,
        command_runner=command_runner,
    )
    sealed_source = app_evidence["sealedSource"]
    assert isinstance(sealed_source, dict)
    sealed_commit = str(sealed_source["sourceCommit"])
    if expected_source_commit is not None and expected_source_commit.lower() != sealed_commit:
        _fail("Explicit reviewed source does not match the sealed app source.")
    source = _source_snapshot(repository, sealed_commit)
    if (
        source["commit"] != sealed_commit
        or source["treeObjectID"] != sealed_source["sourceTreeObjectID"]
    ):
        _fail("Reviewed source does not match the sealed app source.")
    payload: dict[str, object] = {
        "app": app_evidence,
        "appSigningReceiptSHA256": signing_receipt_digest,
        "recordType": "masAppPreparation",
        "schemaVersion": SCHEMA_VERSION,
        "source": source,
        "toolchain": toolchain_evidence,
    }
    _write_new_json(output, payload)
    return payload


def seal_source(
    *, repository: Path, source_commit: str, output: Path
) -> dict[str, object]:
    """Write the reviewed source record before any app signature is created."""

    if re.fullmatch(r"[0-9a-fA-F]{40}", source_commit) is None:
        _fail("Reviewed source commit must be supplied as an exact 40-hex value.")
    source = _source_snapshot(repository, source_commit)
    payload: dict[str, object] = {
        "recordType": "easysplatSignedAppSource",
        "schemaVersion": 1,
        "sourceCommit": source["commit"],
        "sourceTreeObjectID": source["treeObjectID"],
    }
    _validate_sealed_source(payload)
    _write_new_json(output, payload)
    return payload


def _require_exact_keys(value: object, expected: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        _fail(f"{label} must be a JSON object.")
    actual = set(value)
    if actual != expected:
        _fail(
            f"{label} has an unexpected schema "
            f"(missing={sorted(expected - actual)}, extra={sorted(actual - expected)})."
        )
    return value


def _require_digest(value: object, label: str, *, length: int = 64) -> str:
    if not isinstance(value, str) or re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is None:
        _fail(f"{label} must be a lowercase {length}-hex digest.")
    return value


def _validate_source(value: object) -> dict[str, object]:
    source = _require_exact_keys(
        value, {"commit", "head", "treeObjectID"}, "Release source evidence"
    )
    for key in ("commit", "head", "treeObjectID"):
        _require_digest(source[key], f"Release source {key}", length=40)
    return source


def _validate_sealed_source(value: object) -> dict[str, object]:
    sealed = _require_exact_keys(
        value,
        {"recordType", "schemaVersion", "sourceCommit", "sourceTreeObjectID"},
        "Sealed app source",
    )
    if sealed["recordType"] != "easysplatSignedAppSource":
        _fail("Sealed app source has the wrong record type.")
    if sealed["schemaVersion"] != 1:
        _fail("Sealed app source has an unsupported schema version.")
    _require_digest(sealed["sourceCommit"], "Sealed app source commit", length=40)
    _require_digest(
        sealed["sourceTreeObjectID"], "Sealed app source tree", length=40
    )
    return sealed


def _validate_source_binding(source: object, app: object) -> None:
    source_row = _validate_source(source)
    app_row = _validate_app(app)
    sealed = app_row["sealedSource"]
    assert isinstance(sealed, dict)
    if (
        source_row["commit"] != sealed["sourceCommit"]
        or source_row["treeObjectID"] != sealed["sourceTreeObjectID"]
    ):
        _fail("Release source evidence does not match the sealed app source.")


def _validate_app(value: object) -> dict[str, object]:
    app = _require_exact_keys(
        value,
        {
            "architectures",
            "authorities",
            "build",
            "bundleID",
            "cdhash",
            "code",
            "closureSHA256",
            "entitlementsSHA256",
            "sealedSource",
            "signatureTeamID",
            "version",
        },
        "App evidence",
    )
    if app["architectures"] != ["arm64"]:
        _fail("App evidence must name exactly the arm64 architecture.")
    if (
        not isinstance(app["authorities"], list)
        or not app["authorities"]
        or any(not isinstance(item, str) or not item for item in app["authorities"])
    ):
        _fail("App evidence has an invalid authority summary.")
    for key in ("build", "bundleID", "signatureTeamID", "version"):
        if not isinstance(app[key], str) or not app[key]:
            _fail(f"App evidence has an invalid {key}.")
    if re.fullmatch(r"[A-Z0-9]{10}", str(app["signatureTeamID"])) is None:
        _fail("App evidence has an invalid TeamIdentifier.")
    _require_digest(app["cdhash"], "App CDHash", length=40)
    _require_digest(app["closureSHA256"], "App closure SHA-256")
    _validate_sealed_source(app["sealedSource"])
    code = app["code"]
    if not isinstance(code, list) or not code:
        _fail("App evidence has no complete signed-code inventory.")
    code_paths: list[str] = []
    entitlement_paths = {"."}
    main_count = 0
    for index, raw_row in enumerate(code):
        row = _require_exact_keys(
            raw_row,
            {
                "architectures",
                "authorities",
                "cdhash",
                "entitlementsSHA256",
                "kind",
                "relativePath",
                "signatureTeamID",
            },
            f"App code evidence row {index}",
        )
        relative = row["relativePath"]
        if (
            not isinstance(relative, str)
            or not relative
            or relative.startswith("/")
            or Path(relative).as_posix() != relative
            or any(part in {"", ".", ".."} for part in Path(relative).parts)
        ):
            _fail("App code evidence contains an unsafe relative path.")
        if row["architectures"] != ["arm64"]:
            _fail("App code evidence must name exactly arm64.")
        if row["signatureTeamID"] != app["signatureTeamID"]:
            _fail("App code evidence names a different signing team.")
        if not isinstance(row["authorities"], list) or not row["authorities"]:
            _fail("App code evidence has no signer authority.")
        _require_digest(row["cdhash"], "App code CDHash", length=40)
        kind = row["kind"]
        if kind not in {"mainExecutable", "helperExecutable", "library"}:
            _fail("App code evidence has an invalid code kind.")
        entitlement_digest = row["entitlementsSHA256"]
        if kind == "library":
            if entitlement_digest is not None:
                _fail("App library evidence must prove an empty entitlement policy.")
        else:
            _require_digest(entitlement_digest, "App code entitlement SHA-256")
            entitlement_paths.add(relative)
        if kind == "mainExecutable":
            main_count += 1
        code_paths.append(relative)
    if main_count != 1 or code_paths != sorted(code_paths, key=os.fsencode):
        _fail("App code evidence must contain one sorted main executable inventory.")
    if len(code_paths) != len(set(code_paths)):
        _fail("App code evidence contains duplicate paths.")
    entitlements = _require_exact_keys(
        app["entitlementsSHA256"], entitlement_paths, "App entitlement evidence"
    )
    for relative, digest in entitlements.items():
        _require_digest(digest, f"Entitlement SHA-256 for {relative}")
    return app


def _validate_toolchain(value: object) -> dict[str, object]:
    toolchain = _require_exact_keys(
        value,
        {"byteCount", "closureSHA256", "fileCount", "provenanceSHA256"},
        "Bundled toolchain evidence",
    )
    for key in ("byteCount", "fileCount"):
        if isinstance(toolchain[key], bool) or not isinstance(toolchain[key], int):
            _fail(f"Bundled toolchain {key} must be a positive integer.")
        if int(toolchain[key]) <= 0:
            _fail(f"Bundled toolchain {key} must be a positive integer.")
    _require_digest(toolchain["closureSHA256"], "Bundled toolchain closure SHA-256")
    _require_digest(toolchain["provenanceSHA256"], "Toolchain provenance SHA-256")
    return toolchain


def _load_canonical_json(path: Path, label: str) -> dict[str, object]:
    _require_canonical_path(path, label)
    _, _, data = _stable_file_digest(
        path, label=label, maximum_bytes=MAX_EVIDENCE_BYTES
    )
    assert data is not None
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"{label} is not valid UTF-8 JSON: {error}.")
    if not isinstance(value, dict):
        _fail(f"{label} must contain a JSON object.")
    if data != _canonical_json(value):
        _fail(f"{label} is not canonical sorted JSON.")
    return value


def _validate_prepared(value: object) -> dict[str, object]:
    prepared = _require_exact_keys(
        value,
        {
            "app",
            "appSigningReceiptSHA256",
            "recordType",
            "schemaVersion",
            "source",
            "toolchain",
        },
        "Prepared app evidence",
    )
    if prepared["schemaVersion"] != SCHEMA_VERSION:
        _fail("Prepared app evidence has an unsupported schema version.")
    if prepared["recordType"] != "masAppPreparation":
        _fail("Prepared app evidence has the wrong record type.")
    _require_digest(
        prepared["appSigningReceiptSHA256"], "Prepared app signing receipt SHA-256"
    )
    _validate_source_binding(prepared["source"], prepared["app"])
    _validate_toolchain(prepared["toolchain"])
    return prepared


def _inspect_package(
    package: Path,
    *,
    expected_team_id: str,
    command_runner: CommandRunner,
) -> dict[str, object]:
    _require_canonical_path(package, "Installer package")
    if package.suffix != ".pkg":
        _fail("Installer package must use the .pkg suffix.")
    digest_before, byte_count, _ = _stable_file_digest(
        package, label="Installer package"
    )
    if byte_count <= 0:
        _fail("Installer package must not be empty.")
    result = _run(
        [PKGUTIL, "--check-signature", os.fspath(package)],
        command_runner,
        "Installer signature inspection",
    )
    text = f"{result.stdout}\n{result.stderr}"
    authorities = [
        match.strip()
        for match in re.findall(r"(?m)^\s*\d+\.\s+(.+?)\s*$", text)
        if match.strip().startswith(
            ("3rd Party Mac Developer Installer:", "Mac Installer Distribution:")
        )
    ]
    authority_team = (
        re.search(r"\(([A-Z0-9]{10})\)$", authorities[0])
        if len(authorities) == 1
        else None
    )
    if authority_team is None or authority_team.group(1) != expected_team_id:
        _fail("Installer package has the wrong distribution signature.")
    digest_after, after_byte_count, _ = _stable_file_digest(
        package, label="Installer package"
    )
    if digest_before != digest_after or byte_count != after_byte_count:
        _fail("Installer package changed while its signature was inspected.")
    return {
        "authority": authorities[0],
        "byteCount": byte_count,
        "sha256": digest_before,
        "signatureTeamID": authority_team.group(1),
    }


def _validate_package(value: object) -> dict[str, object]:
    package = _require_exact_keys(
        value,
        {"authority", "byteCount", "sha256", "signatureTeamID"},
        "Installer package evidence",
    )
    if not isinstance(package["authority"], str) or not package["authority"]:
        _fail("Installer package evidence has no authority summary.")
    if (
        isinstance(package["byteCount"], bool)
        or not isinstance(package["byteCount"], int)
        or int(package["byteCount"]) <= 0
    ):
        _fail("Installer package evidence has an invalid byte count.")
    _require_digest(package["sha256"], "Installer package SHA-256")
    if re.fullmatch(r"[A-Z0-9]{10}", str(package["signatureTeamID"])) is None:
        _fail("Installer package evidence has an invalid TeamIdentifier.")
    return package


def _validate_final(value: object) -> dict[str, object]:
    evidence = _require_exact_keys(
        value,
        {
            "app",
            "appSigningReceiptSHA256",
            "appStoreConnect",
            "package",
            "recordType",
            "schemaVersion",
            "source",
            "toolchain",
        },
        "MAS release evidence",
    )
    if evidence["schemaVersion"] != SCHEMA_VERSION:
        _fail("MAS release evidence has an unsupported schema version.")
    if evidence["recordType"] != "masReleaseEvidence":
        _fail("MAS release evidence has the wrong record type.")
    _require_digest(
        evidence["appSigningReceiptSHA256"], "App signing receipt SHA-256"
    )
    _validate_source_binding(evidence["source"], evidence["app"])
    app = _validate_app(evidence["app"])
    _validate_toolchain(evidence["toolchain"])
    package = _validate_package(evidence["package"])
    if app["signatureTeamID"] != package["signatureTeamID"]:
        _fail("App and installer package evidence name different teams.")
    asc = _require_exact_keys(
        evidence["appStoreConnect"], {"buildID", "status"}, "ASC evidence"
    )
    if asc != {"buildID": None, "status": "pending"}:
        _fail("Pre-upload ASC evidence must have pending status and no build ID.")
    return evidence


def finalize_evidence(
    *,
    repository: Path,
    app: Path,
    package: Path,
    prepared: Path,
    expected_team_id: str,
    output: Path,
    app_signing_receipt: Path | None = None,
    command_runner: CommandRunner = _run_system,
    signing_receipt_validator: SigningReceiptValidator = _validate_with_distribution_signer,
) -> dict[str, object]:
    """Bind productbuild output to the unchanged reviewed app snapshot."""

    prepared_payload = _validate_prepared(_load_canonical_json(prepared, "Prepared app evidence"))
    current_receipt_digest = _validated_app_signing_receipt_digest(
        app,
        app_signing_receipt,
        expected_team_id=expected_team_id,
        validator=signing_receipt_validator,
    )
    if current_receipt_digest != prepared_payload["appSigningReceiptSHA256"]:
        _fail("App signing receipt changed after package preparation.")
    source = _source_snapshot(repository, str(prepared_payload["source"]["commit"]))
    if source != prepared_payload["source"]:
        _fail("Release source changed after the app was prepared.")
    prepared_app = prepared_payload["app"]
    current_app, current_toolchain = _inspect_app(
        app,
        expected_version=str(prepared_app["version"]),
        expected_build=str(prepared_app["build"]),
        expected_bundle_id=str(prepared_app["bundleID"]),
        expected_team_id=expected_team_id,
        command_runner=command_runner,
    )
    if current_app != prepared_app or current_toolchain != prepared_payload["toolchain"]:
        _fail("App or bundled toolchain changed after package preparation.")
    package_evidence = _inspect_package(
        package, expected_team_id=expected_team_id, command_runner=command_runner
    )
    packaged_app, packaged_toolchain = _inspect_packaged_app(
        package,
        expected_version=str(prepared_app["version"]),
        expected_build=str(prepared_app["build"]),
        expected_bundle_id=str(prepared_app["bundleID"]),
        expected_team_id=expected_team_id,
        command_runner=command_runner,
    )
    if packaged_app != current_app or packaged_toolchain != current_toolchain:
        _fail("Installer payload does not match the prepared app and toolchain.")
    if (
        _inspect_package(
            package,
            expected_team_id=expected_team_id,
            command_runner=command_runner,
        )
        != package_evidence
    ):
        _fail("Installer package changed while its payload was inspected.")
    payload: dict[str, object] = {
        "app": packaged_app,
        "appSigningReceiptSHA256": current_receipt_digest,
        "appStoreConnect": {"buildID": None, "status": "pending"},
        "package": package_evidence,
        "recordType": "masReleaseEvidence",
        "schemaVersion": SCHEMA_VERSION,
        "source": source,
        "toolchain": packaged_toolchain,
    }
    _validate_final(payload)
    _write_new_json(output, payload)
    return payload


def verify_evidence(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    command_runner: CommandRunner = _run_system,
) -> dict[str, object]:
    """Revalidate package/source binding immediately before ASC invocation."""

    payload = _validate_final(_load_canonical_json(evidence, "MAS release evidence"))
    current_source = _source_snapshot(repository, str(payload["source"]["commit"]))
    if current_source != payload["source"]:
        _fail("MAS release evidence does not match the current source checkout.")
    current_package = _inspect_package(
        package,
        expected_team_id=str(payload["package"]["signatureTeamID"]),
        command_runner=command_runner,
    )
    if current_package != payload["package"]:
        _fail("MAS release evidence does not match the exact installer package.")
    packaged_app, packaged_toolchain = _inspect_packaged_app(
        package,
        expected_version=str(payload["app"]["version"]),
        expected_build=str(payload["app"]["build"]),
        expected_bundle_id=str(payload["app"]["bundleID"]),
        expected_team_id=str(payload["app"]["signatureTeamID"]),
        command_runner=command_runner,
    )
    if packaged_app != payload["app"] or packaged_toolchain != payload["toolchain"]:
        _fail("MAS release evidence does not match the packaged app and toolchain.")
    if (
        _inspect_package(
            package,
            expected_team_id=str(payload["package"]["signatureTeamID"]),
            command_runner=command_runner,
        )
        != current_package
    ):
        _fail("Installer package changed while its payload was revalidated.")
    return payload


def load_altool_response(path: Path) -> dict[str, object]:
    """Read one bounded App Store Connect response without trusting its schema."""

    _require_canonical_path(path, "altool response")
    _, _, data = _stable_file_digest(
        path, label="altool response", maximum_bytes=MAX_EVIDENCE_BYTES
    )
    assert data is not None

    def object_from_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
        value: dict[str, object] = {}
        for key, item in pairs:
            if key in value:
                _fail(f"altool response contains a duplicate JSON key: {key}.")
            value[key] = item
        return value

    def reject_constant(value: str) -> object:
        _fail(f"altool response contains a non-finite JSON value: {value}.")

    try:
        value = json.loads(
            data,
            object_pairs_hook=object_from_pairs,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"altool response is not valid UTF-8 JSON: {error}.")
    if not isinstance(value, dict) or not value:
        _fail("altool response must contain a non-empty JSON object.")
    if len(_canonical_json(value)) > MAX_EVIDENCE_BYTES:
        _fail("Canonical altool response exceeds its size limit.")
    return value


def _submission_app(
    release: dict[str, object],
    *,
    apple_id: str,
    expected_version: str,
    expected_build: str,
) -> dict[str, object]:
    if re.fullmatch(r"[1-9][0-9]{5,19}", apple_id) is None:
        _fail("App Store Connect Apple ID must be a positive decimal identifier.")
    app = _validate_app(release["app"])
    if app["version"] != expected_version or app["build"] != expected_build:
        _fail("Submission version or build does not match the signed package evidence.")
    return {
        "appleID": apple_id,
        "build": expected_build,
        "bundleID": app["bundleID"],
        "platform": "macos",
        "version": expected_version,
    }


def _validate_submission_app(value: object, label: str) -> dict[str, object]:
    app = _require_exact_keys(
        value,
        {"appleID", "build", "bundleID", "platform", "version"},
        label,
    )
    if re.fullmatch(r"[1-9][0-9]{5,19}", str(app["appleID"])) is None:
        _fail(f"{label} has an invalid Apple ID.")
    if app["platform"] != "macos":
        _fail(f"{label} has the wrong platform.")
    for key in ("build", "bundleID", "version"):
        if not isinstance(app[key], str) or not app[key]:
            _fail(f"{label} has an invalid {key}.")
    return app


def _submission_altool(response: dict[str, object], version: str) -> dict[str, object]:
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+){2} \([0-9]+\)", version) is None:
        _fail("altool version must include its semantic and build versions.")
    response_bytes = _canonical_json(response)
    return {
        "response": response,
        "responseCanonicalSHA256": hashlib.sha256(response_bytes).hexdigest(),
        "version": version,
    }


def _validate_submission_altool(value: object, label: str) -> dict[str, object]:
    altool = _require_exact_keys(
        value,
        {"response", "responseCanonicalSHA256", "version"},
        label,
    )
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+){2} \([0-9]+\)", str(altool["version"])) is None:
        _fail(f"{label} has an invalid tool version.")
    response = altool["response"]
    if not isinstance(response, dict) or not response:
        _fail(f"{label} has an invalid response object.")
    digest = _require_digest(
        altool["responseCanonicalSHA256"], f"{label} response SHA-256"
    )
    if hashlib.sha256(_canonical_json(response)).hexdigest() != digest:
        _fail(f"{label} response digest does not match its response.")
    return altool


def _upload_delivery_id(response: object) -> str:
    if not isinstance(response, dict):
        _fail("MAS upload response must be a JSON object.")
    delivery_ids: list[object] = []
    legacy_delivery_id = response.get("delivery-id")
    if legacy_delivery_id is not None:
        delivery_ids.append(legacy_delivery_id)
    details = response.get("details")
    if details is not None:
        if not isinstance(details, dict):
            _fail("MAS upload response has invalid delivery details.")
        current_delivery_id = details.get("delivery-uuid")
        if current_delivery_id is not None:
            delivery_ids.append(current_delivery_id)
    if not delivery_ids or any(
        not isinstance(value, str)
        or DELIVERY_ID_PATTERN.fullmatch(value.lower()) is None
        for value in delivery_ids
    ):
        _fail("MAS upload response has no valid delivery ID.")
    normalized_delivery_ids = {str(value).lower() for value in delivery_ids}
    if len(normalized_delivery_ids) != 1:
        _fail("MAS upload response contains conflicting delivery IDs.")
    success = response.get("success-message")
    if not isinstance(success, str) or not success.strip():
        _fail("MAS upload response does not confirm acceptance.")
    return normalized_delivery_ids.pop()


def _require_successful_processing_response(
    response: object, expected_delivery_id: str
) -> None:
    if not isinstance(response, dict):
        _fail("MAS processing response must be a JSON object.")
    if response.get("internal-build-state") != "READY_TO_TEST":
        _fail("MAS processing response is not in the ready-to-test terminal state.")
    if response.get("is-on-app-store-connect") is not True:
        _fail("MAS processing response does not confirm App Store Connect visibility.")
    processing_errors = response.get("processing-errors")
    if not isinstance(processing_errors, list) or processing_errors:
        _fail("MAS processing response contains errors or an unknown error schema.")
    response_delivery_id = response.get("delivery-id")
    if response_delivery_id is not None and (
        not isinstance(response_delivery_id, str)
        or response_delivery_id.lower() != expected_delivery_id
    ):
        _fail("MAS processing response names a different delivery ID.")


def _bound_release_evidence(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    command_runner: CommandRunner,
) -> tuple[dict[str, object], str]:
    release = verify_evidence(
        repository=repository,
        package=package,
        evidence=evidence,
        command_runner=command_runner,
    )
    evidence_digest, _, _ = _stable_file_digest(
        evidence, label="MAS release evidence", maximum_bytes=MAX_EVIDENCE_BYTES
    )
    if _validate_final(_load_canonical_json(evidence, "MAS release evidence")) != release:
        _fail("MAS release evidence changed while submission evidence was prepared.")
    return release, evidence_digest


def _submission_common(
    release: dict[str, object],
    release_digest: str,
    *,
    apple_id: str,
    expected_version: str,
    expected_build: str,
) -> dict[str, object]:
    return {
        "app": _submission_app(
            release,
            apple_id=apple_id,
            expected_version=expected_version,
            expected_build=expected_build,
        ),
        "package": release["package"],
        "releaseEvidenceSHA256": release_digest,
        "source": release["source"],
    }


def _validate_submission_common(
    receipt: dict[str, object],
    release: dict[str, object],
    release_digest: str,
    *,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
) -> None:
    expected_app = _submission_app(
        release,
        apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    if _validate_submission_app(receipt["app"], "Submission app evidence") != expected_app:
        _fail("Submission receipt names a different app or build.")
    if _validate_package(receipt["package"]) != release["package"]:
        _fail("Submission receipt names a different installer package.")
    if _validate_source(receipt["source"]) != release["source"]:
        _fail("Submission receipt names a different reviewed source.")
    if _require_digest(
        receipt["releaseEvidenceSHA256"], "Submission release-evidence SHA-256"
    ) != release_digest:
        _fail("Submission receipt does not bind the current release evidence.")


def _validate_upload_attempt(
    value: object,
    release: dict[str, object],
    release_digest: str,
    *,
    package_name: str,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
) -> dict[str, object]:
    attempt = _require_exact_keys(
        value,
        {
            "app",
            "altoolVersion",
            "attemptID",
            "package",
            "recordType",
            "releaseEvidenceSHA256",
            "responseFile",
            "schemaVersion",
            "source",
            "state",
        },
        "MAS upload-attempt receipt",
    )
    if attempt["schemaVersion"] != SCHEMA_VERSION:
        _fail("MAS upload-attempt receipt has an unsupported schema version.")
    if attempt["recordType"] != "masUploadAttempt":
        _fail("MAS upload-attempt receipt has the wrong record type.")
    if attempt["state"] != "uploadInvokedReceiptPending":
        _fail("MAS upload-attempt receipt has the wrong state.")
    if re.fullmatch(
        r"[0-9]+(?:\.[0-9]+){2} \([0-9]+\)", str(attempt["altoolVersion"])
    ) is None:
        _fail("MAS upload-attempt receipt has an invalid altool version.")
    attempt_id = attempt["attemptID"]
    if not isinstance(attempt_id, str) or re.fullmatch(r"[0-9a-f]{32}", attempt_id) is None:
        _fail("MAS upload-attempt receipt has an invalid attempt ID.")
    expected_response = f".{package_name}.upload-response.{attempt_id}.json"
    if attempt["responseFile"] != expected_response:
        _fail("MAS upload-attempt receipt has an unsafe response filename.")
    _validate_submission_common(
        attempt,
        release,
        release_digest,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    return attempt


def start_upload_attempt(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    apple_id: str,
    expected_version: str,
    expected_build: str,
    altool_version: str,
    output: Path,
    command_runner: CommandRunner = _run_system,
) -> Path:
    """Durably mark an irreversible upload attempt before altool is launched."""

    _require_canonical_path(package, "Installer package")
    _require_canonical_path(output, "MAS upload-attempt receipt")
    if output != package.with_name(f"{package.name}.upload-attempt.json"):
        _fail("MAS upload-attempt receipt must use the canonical package sibling.")
    release, release_digest = _bound_release_evidence(
        repository=repository,
        package=package,
        evidence=evidence,
        command_runner=command_runner,
    )
    attempt_id = secrets.token_hex(16)
    response_name = f".{package.name}.upload-response.{attempt_id}.json"
    response = package.with_name(response_name)
    if os.path.lexists(response):
        _fail("MAS upload-attempt response path already exists.")
    payload: dict[str, object] = {
        **_submission_common(
            release,
            release_digest,
            apple_id=apple_id,
            expected_version=expected_version,
            expected_build=expected_build,
        ),
        "attemptID": attempt_id,
        "altoolVersion": altool_version,
        "recordType": "masUploadAttempt",
        "responseFile": response_name,
        "schemaVersion": SCHEMA_VERSION,
        "state": "uploadInvokedReceiptPending",
    }
    _validate_upload_attempt(
        payload,
        release,
        release_digest,
        package_name=package.name,
        expected_apple_id=apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    _write_new_json(output, payload)
    if _load_canonical_json(output, "MAS upload-attempt receipt") != payload:
        _fail("MAS upload-attempt receipt changed during publication.")
    return response


def verify_upload_attempt(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    attempt: Path,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
    command_runner: CommandRunner = _run_system,
) -> tuple[dict[str, object], Path]:
    release, release_digest = _bound_release_evidence(
        repository=repository,
        package=package,
        evidence=evidence,
        command_runner=command_runner,
    )
    payload = _validate_upload_attempt(
        _load_canonical_json(attempt, "MAS upload-attempt receipt"),
        release,
        release_digest,
        package_name=package.name,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    if attempt != package.with_name(f"{package.name}.upload-attempt.json"):
        _fail("MAS upload-attempt receipt is not the canonical package sibling.")
    response_name = payload["responseFile"]
    assert isinstance(response_name, str)
    return payload, package.with_name(response_name)


def capture_submission_response(output: Path, data: bytes) -> None:
    if not data or len(data) > MAX_EVIDENCE_BYTES:
        _fail("App Store response is empty or exceeds its size limit.")
    _secure_publish_bytes(output, data, label="App Store response")


def cleanup_upload_attempt(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    attempt: Path,
    response: Path,
    upload_receipt: Path,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
    command_runner: CommandRunner = _run_system,
) -> None:
    """Remove only the exact attempt files superseded by a valid upload receipt."""

    _, expected_response = verify_upload_attempt(
        repository=repository,
        package=package,
        evidence=evidence,
        attempt=attempt,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
        command_runner=command_runner,
    )
    if response != expected_response:
        _fail("MAS upload-attempt cleanup names a different response file.")
    upload = verify_upload_submission(
        repository=repository,
        package=package,
        evidence=evidence,
        receipt=upload_receipt,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
        command_runner=command_runner,
    )
    response_payload = load_altool_response(response)
    altool = upload["altool"]
    assert isinstance(altool, dict)
    if response_payload != altool["response"]:
        _fail("MAS upload-attempt response does not match the committed receipt.")

    parent = _require_canonical_path(package.parent, "MAS upload output directory")
    directory_flags = (
        os.O_RDONLY
        | os.O_DIRECTORY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    file_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_descriptor = os.open(parent, directory_flags)
    opened: list[tuple[str, int, os.stat_result]] = []
    try:
        for path, label in (
            (response, "upload-attempt response"),
            (attempt, "upload-attempt receipt"),
        ):
            if path.parent != parent:
                _fail(f"MAS {label} is outside the package directory.")
            named = os.stat(
                path.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            descriptor = os.open(path.name, file_flags, dir_fd=parent_descriptor)
            held = os.fstat(descriptor)
            if (
                not _same_identity(named, held)
                or not stat.S_ISREG(held.st_mode)
                or held.st_nlink != 1
            ):
                os.close(descriptor)
                _fail(f"MAS {label} changed before cleanup.")
            opened.append((path.name, descriptor, held))
        for name, descriptor, held in opened:
            current = os.stat(
                name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if not _same_identity(held, current) or not _same_identity(
                held, os.fstat(descriptor)
            ):
                _fail("MAS upload-attempt files changed during cleanup.")
        for name, _, _ in opened:
            os.unlink(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except FileNotFoundError:
        _fail("MAS upload-attempt cleanup file is missing; unknown files were preserved.")
    finally:
        for _, descriptor, _ in opened:
            os.close(descriptor)
        os.close(parent_descriptor)


def _validate_upload_submission(
    value: object,
    release: dict[str, object],
    release_digest: str,
    *,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
) -> dict[str, object]:
    receipt = _require_exact_keys(
        value,
        {
            "altool",
            "app",
            "deliveryID",
            "package",
            "recordType",
            "releaseEvidenceSHA256",
            "schemaVersion",
            "source",
            "state",
        },
        "MAS upload submission receipt",
    )
    if receipt["schemaVersion"] != SCHEMA_VERSION:
        _fail("MAS upload submission receipt has an unsupported schema version.")
    if receipt["recordType"] != "masUploadSubmission":
        _fail("MAS upload submission receipt has the wrong record type.")
    if receipt["state"] != "uploadedAwaitingProcessing":
        _fail("MAS upload submission receipt has the wrong state.")
    altool = _validate_submission_altool(
        receipt["altool"], "MAS upload altool evidence"
    )
    delivery_id = _upload_delivery_id(altool["response"])
    if receipt["deliveryID"] != delivery_id:
        _fail("MAS upload submission receipt has the wrong delivery ID.")
    _validate_submission_common(
        receipt,
        release,
        release_digest,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    return receipt


def record_upload_submission(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    apple_id: str,
    expected_version: str,
    expected_build: str,
    altool_version: str,
    response: Path,
    output: Path,
    command_runner: CommandRunner = _run_system,
) -> dict[str, object]:
    """Commit the irreversible upload result before polling processing status."""

    release, release_digest = _bound_release_evidence(
        repository=repository,
        package=package,
        evidence=evidence,
        command_runner=command_runner,
    )
    response_payload = load_altool_response(response)
    delivery_id = _upload_delivery_id(response_payload)
    payload: dict[str, object] = {
        **_submission_common(
            release,
            release_digest,
            apple_id=apple_id,
            expected_version=expected_version,
            expected_build=expected_build,
        ),
        "altool": _submission_altool(response_payload, altool_version),
        "deliveryID": delivery_id,
        "recordType": "masUploadSubmission",
        "schemaVersion": SCHEMA_VERSION,
        "state": "uploadedAwaitingProcessing",
    }
    _validate_upload_submission(
        payload,
        release,
        release_digest,
        expected_apple_id=apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )
    if len(_canonical_json(payload)) > MAX_EVIDENCE_BYTES:
        _fail("MAS upload submission receipt exceeds its size limit.")
    _write_new_json(output, payload)
    reread = _load_canonical_json(output, "MAS upload submission receipt")
    if reread != payload:
        _fail("MAS upload submission receipt changed during publication.")
    return payload


def verify_upload_submission(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    receipt: Path,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
    command_runner: CommandRunner = _run_system,
) -> dict[str, object]:
    release, release_digest = _bound_release_evidence(
        repository=repository,
        package=package,
        evidence=evidence,
        command_runner=command_runner,
    )
    return _validate_upload_submission(
        _load_canonical_json(receipt, "MAS upload submission receipt"),
        release,
        release_digest,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
    )


def _validate_processing_submission(
    value: object,
    upload: dict[str, object],
    upload_digest: str,
) -> dict[str, object]:
    receipt = _require_exact_keys(
        value,
        {
            "altool",
            "app",
            "deliveryID",
            "package",
            "recordType",
            "releaseEvidenceSHA256",
            "schemaVersion",
            "source",
            "state",
            "uploadReceiptSHA256",
        },
        "MAS processing submission receipt",
    )
    if receipt["schemaVersion"] != SCHEMA_VERSION:
        _fail("MAS processing submission receipt has an unsupported schema version.")
    if receipt["recordType"] != "masProcessingSubmission":
        _fail("MAS processing submission receipt has the wrong record type.")
    if receipt["state"] != "processed":
        _fail("MAS processing submission receipt has the wrong state.")
    altool = _validate_submission_altool(
        receipt["altool"], "MAS processing altool evidence"
    )
    if receipt["deliveryID"] != upload["deliveryID"]:
        _fail("MAS processing receipt names a different delivery ID.")
    assert isinstance(upload["deliveryID"], str)
    _require_successful_processing_response(
        altool["response"], upload["deliveryID"]
    )
    for key in ("app", "package", "releaseEvidenceSHA256", "source"):
        if receipt[key] != upload[key]:
            _fail("MAS processing receipt does not match its upload receipt.")
    if _require_digest(
        receipt["uploadReceiptSHA256"], "MAS upload-receipt SHA-256"
    ) != upload_digest:
        _fail("MAS processing receipt does not bind its upload receipt.")
    return receipt


def record_processing_submission(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    upload_receipt: Path,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
    altool_version: str,
    response: Path,
    output: Path,
    command_runner: CommandRunner = _run_system,
) -> dict[str, object]:
    """Commit a successful terminal processing query without replacing upload proof."""

    upload = verify_upload_submission(
        repository=repository,
        package=package,
        evidence=evidence,
        receipt=upload_receipt,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
        command_runner=command_runner,
    )
    upload_digest, _, _ = _stable_file_digest(
        upload_receipt,
        label="MAS upload submission receipt",
        maximum_bytes=MAX_EVIDENCE_BYTES,
    )
    response_payload = load_altool_response(response)
    assert isinstance(upload["deliveryID"], str)
    _require_successful_processing_response(
        response_payload, upload["deliveryID"]
    )
    payload: dict[str, object] = {
        "altool": _submission_altool(response_payload, altool_version),
        "app": upload["app"],
        "deliveryID": upload["deliveryID"],
        "package": upload["package"],
        "recordType": "masProcessingSubmission",
        "releaseEvidenceSHA256": upload["releaseEvidenceSHA256"],
        "schemaVersion": SCHEMA_VERSION,
        "source": upload["source"],
        "state": "processed",
        "uploadReceiptSHA256": upload_digest,
    }
    _validate_processing_submission(payload, upload, upload_digest)
    if len(_canonical_json(payload)) > MAX_EVIDENCE_BYTES:
        _fail("MAS processing submission receipt exceeds its size limit.")
    _write_new_json(output, payload)
    reread = _load_canonical_json(output, "MAS processing submission receipt")
    if reread != payload:
        _fail("MAS processing submission receipt changed during publication.")
    return payload


def verify_processing_submission(
    *,
    repository: Path,
    package: Path,
    evidence: Path,
    upload_receipt: Path,
    processing_receipt: Path,
    expected_apple_id: str,
    expected_version: str,
    expected_build: str,
    command_runner: CommandRunner = _run_system,
) -> dict[str, object]:
    upload = verify_upload_submission(
        repository=repository,
        package=package,
        evidence=evidence,
        receipt=upload_receipt,
        expected_apple_id=expected_apple_id,
        expected_version=expected_version,
        expected_build=expected_build,
        command_runner=command_runner,
    )
    upload_digest, _, _ = _stable_file_digest(
        upload_receipt,
        label="MAS upload submission receipt",
        maximum_bytes=MAX_EVIDENCE_BYTES,
    )
    return _validate_processing_submission(
        _load_canonical_json(
            processing_receipt, "MAS processing submission receipt"
        ),
        upload,
        upload_digest,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Bind a reviewed source commit, MAS app, and installer package."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    seal = commands.add_parser(
        "seal-source", help="write the reviewed source record before app signing"
    )
    seal.add_argument("--repository", required=True, type=Path)
    seal.add_argument("--source-commit", required=True)
    seal.add_argument("--output", required=True, type=Path)

    prepare = commands.add_parser("prepare", help="snapshot the app before productbuild")
    prepare.add_argument("--repository", required=True, type=Path)
    prepare.add_argument("--app", required=True, type=Path)
    prepare.add_argument("--app-signing-receipt", type=Path)
    prepare.add_argument("--expected-version", required=True)
    prepare.add_argument("--expected-build")
    prepare.add_argument("--expected-bundle-id", required=True)
    prepare.add_argument("--expected-team-id", required=True)
    prepare.add_argument("--source-commit")
    prepare.add_argument("--output", required=True, type=Path)

    finalize = commands.add_parser(
        "finalize", help="bind the unchanged app snapshot to the package"
    )
    finalize.add_argument("--repository", required=True, type=Path)
    finalize.add_argument("--app", required=True, type=Path)
    finalize.add_argument("--app-signing-receipt", type=Path)
    finalize.add_argument("--package", required=True, type=Path)
    finalize.add_argument("--prepared", required=True, type=Path)
    finalize.add_argument("--expected-team-id", required=True)
    finalize.add_argument("--output", required=True, type=Path)

    verify = commands.add_parser(
        "verify", help="revalidate source and package immediately before ASC"
    )
    verify.add_argument("--repository", required=True, type=Path)
    verify.add_argument("--package", required=True, type=Path)
    verify.add_argument("--evidence", required=True, type=Path)

    def add_submission_identity(command: argparse.ArgumentParser) -> None:
        command.add_argument("--repository", required=True, type=Path)
        command.add_argument("--package", required=True, type=Path)
        command.add_argument("--evidence", required=True, type=Path)
        command.add_argument("--apple-id", required=True)
        command.add_argument("--expected-version", required=True)
        command.add_argument("--expected-build", required=True)

    record_upload = commands.add_parser(
        "record-upload", help="commit an accepted App Store Connect upload"
    )
    add_submission_identity(record_upload)
    record_upload.add_argument("--altool-version", required=True)
    record_upload.add_argument("--response", required=True, type=Path)
    record_upload.add_argument("--output", required=True, type=Path)

    verify_upload = commands.add_parser(
        "verify-upload", help="verify an accepted upload before resuming status"
    )
    add_submission_identity(verify_upload)
    verify_upload.add_argument("--receipt", required=True, type=Path)
    verify_upload.add_argument("--print-delivery-id", action="store_true")

    start_upload = commands.add_parser(
        "start-upload-attempt",
        help="durably mark an upload attempt before invoking App Store Connect",
    )
    add_submission_identity(start_upload)
    start_upload.add_argument("--output", required=True, type=Path)
    start_upload.add_argument("--altool-version", required=True)

    verify_attempt = commands.add_parser(
        "verify-upload-attempt",
        help="verify and resume an upload whose receipt was interrupted",
    )
    add_submission_identity(verify_attempt)
    verify_attempt.add_argument("--attempt", required=True, type=Path)
    verify_attempt.add_argument("--print-response-path", action="store_true")
    verify_attempt.add_argument("--print-altool-version", action="store_true")

    capture_response = commands.add_parser(
        "capture-response", help="durably capture one bounded App Store response"
    )
    capture_response.add_argument("--output", required=True, type=Path)

    cleanup_attempt = commands.add_parser(
        "cleanup-upload-attempt",
        help="remove an upload attempt superseded by its committed receipt",
    )
    add_submission_identity(cleanup_attempt)
    cleanup_attempt.add_argument("--attempt", required=True, type=Path)
    cleanup_attempt.add_argument("--response", required=True, type=Path)
    cleanup_attempt.add_argument("--upload-receipt", required=True, type=Path)

    record_processing = commands.add_parser(
        "record-processing", help="commit terminal App Store processing evidence"
    )
    add_submission_identity(record_processing)
    record_processing.add_argument("--upload-receipt", required=True, type=Path)
    record_processing.add_argument("--altool-version", required=True)
    record_processing.add_argument("--response", required=True, type=Path)
    record_processing.add_argument("--output", required=True, type=Path)

    verify_processing = commands.add_parser(
        "verify-processing", help="verify terminal App Store processing evidence"
    )
    add_submission_identity(verify_processing)
    verify_processing.add_argument("--upload-receipt", required=True, type=Path)
    verify_processing.add_argument("--processing-receipt", required=True, type=Path)

    checksum = commands.add_parser(
        "publish-checksum", help="publish a new no-follow package checksum"
    )
    checksum.add_argument("--package", required=True, type=Path)
    checksum.add_argument("--output", required=True, type=Path)

    publish_set = commands.add_parser(
        "publish-release-set",
        help="commit validated package sidecars and then the installer package",
    )
    publish_set.add_argument("--staging-directory", required=True, type=Path)
    publish_set.add_argument("--package-output", required=True, type=Path)
    publish_set.add_argument("--evidence-output", required=True, type=Path)
    publish_set.add_argument("--checksum-output", required=True, type=Path)

    snapshot = commands.add_parser(
        "snapshot-package", help="create a private immutable upload snapshot"
    )
    snapshot.add_argument("--package", required=True, type=Path)
    snapshot.add_argument("--output", required=True, type=Path)

    verify_snapshot = commands.add_parser(
        "verify-snapshot", help="verify a held upload snapshot descriptor"
    )
    verify_snapshot.add_argument("--snapshot", required=True, type=Path)
    verify_snapshot.add_argument("--descriptor", required=True, type=int)
    verify_snapshot.add_argument("--token", required=True)

    cleanup_snapshot = commands.add_parser(
        "cleanup-snapshot", help="remove only an exact owned upload snapshot"
    )
    cleanup_snapshot.add_argument("--root", required=True, type=Path)
    cleanup_snapshot.add_argument("--snapshot", required=True, type=Path)
    cleanup_snapshot.add_argument("--descriptor", required=True, type=int)
    cleanup_snapshot.add_argument("--token", required=True)

    cleanup_responses = commands.add_parser(
        "cleanup-responses", help="remove exact private App Store response files"
    )
    cleanup_responses.add_argument("--root", required=True, type=Path)
    cleanup_responses.add_argument(
        "--response", action="append", required=True, type=Path
    )
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = _parser().parse_args(arguments)
    try:
        if options.command == "seal-source":
            seal_source(
                repository=options.repository,
                source_commit=options.source_commit,
                output=options.output,
            )
            print(f"Sealed reviewed app source: {options.output}")
        elif options.command == "prepare":
            prepare_evidence(
                repository=options.repository,
                app=options.app,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
                expected_bundle_id=options.expected_bundle_id,
                expected_team_id=options.expected_team_id,
                expected_source_commit=options.source_commit,
                output=options.output,
                app_signing_receipt=options.app_signing_receipt,
            )
            print(f"Prepared MAS app evidence: {options.output}")
        elif options.command == "finalize":
            finalize_evidence(
                repository=options.repository,
                app=options.app,
                package=options.package,
                prepared=options.prepared,
                expected_team_id=options.expected_team_id,
                output=options.output,
                app_signing_receipt=options.app_signing_receipt,
            )
            print(f"MAS package evidence ready: {options.output}")
        elif options.command == "verify":
            verify_evidence(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
            )
            print("MAS release evidence verified.")
        elif options.command == "record-upload":
            record_upload_submission(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
                altool_version=options.altool_version,
                response=options.response,
                output=options.output,
            )
            print(f"MAS upload submission recorded: {options.output}")
        elif options.command == "verify-upload":
            upload = verify_upload_submission(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                receipt=options.receipt,
                expected_apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
            )
            if options.print_delivery_id:
                print(upload["deliveryID"])
            else:
                print("MAS upload submission verified.")
        elif options.command == "start-upload-attempt":
            response = start_upload_attempt(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
                altool_version=options.altool_version,
                output=options.output,
            )
            print(response)
        elif options.command == "verify-upload-attempt":
            attempt, response = verify_upload_attempt(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                attempt=options.attempt,
                expected_apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
            )
            if options.print_response_path:
                print(response)
            elif options.print_altool_version:
                print(attempt["altoolVersion"])
            else:
                print("MAS upload attempt verified.")
        elif options.command == "capture-response":
            data = sys.stdin.buffer.read(MAX_EVIDENCE_BYTES + 1)
            capture_submission_response(options.output, data)
            print(f"App Store response captured: {options.output}", file=sys.stderr)
        elif options.command == "cleanup-upload-attempt":
            cleanup_upload_attempt(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                attempt=options.attempt,
                response=options.response,
                upload_receipt=options.upload_receipt,
                expected_apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
            )
            print("MAS upload attempt cleaned.")
        elif options.command == "record-processing":
            record_processing_submission(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                upload_receipt=options.upload_receipt,
                expected_apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
                altool_version=options.altool_version,
                response=options.response,
                output=options.output,
            )
            print(f"MAS processing submission recorded: {options.output}")
        elif options.command == "verify-processing":
            verify_processing_submission(
                repository=options.repository,
                package=options.package,
                evidence=options.evidence,
                upload_receipt=options.upload_receipt,
                processing_receipt=options.processing_receipt,
                expected_apple_id=options.apple_id,
                expected_version=options.expected_version,
                expected_build=options.expected_build,
            )
            print("MAS processing submission verified.")
        elif options.command == "publish-checksum":
            digest = publish_checksum(options.package, options.output)
            print(digest)
        elif options.command == "publish-release-set":
            cleaned = publish_release_set(
                staging_directory=options.staging_directory,
                package_output=options.package_output,
                evidence_output=options.evidence_output,
                checksum_output=options.checksum_output,
            )
            if cleaned:
                print("MAS release set published and staging cleaned.")
            else:
                print(
                    "MAS release set published; unknown staging entries were retained.",
                    file=sys.stderr,
                )
        elif options.command == "snapshot-package":
            print(snapshot_package(options.package, options.output))
        elif options.command == "verify-snapshot":
            verify_package_snapshot(
                options.snapshot, options.descriptor, options.token
            )
            print("Package snapshot verified.")
        elif options.command == "cleanup-snapshot":
            cleanup_package_snapshot(
                options.root,
                options.snapshot,
                options.descriptor,
                options.token,
            )
            print("Package snapshot cleaned.")
        else:
            cleanup_submission_responses(options.root, options.response)
            print("Submission responses cleaned.")
    except ReleaseEvidenceError as error:
        print(f"MAS release evidence rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
