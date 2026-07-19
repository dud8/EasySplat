#!/usr/bin/env python3
"""Verify and assemble the exact post-sign EasySplat toolchain release closure."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, NoReturn


MAX_ARCHIVE_BYTES = 2_147_483_647
MAX_JSON_BYTES = 8 * 1_024 * 1_024
MAX_AUTHORITY_ARTIFACT_BYTES = 16 * 1_024 * 1_024
SHA256 = re.compile(r"[0-9a-f]{64}")
ARTIFACT_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
AUTHORITY_RECEIPT_DOMAIN = b"EasySplat Toolchain Authority Receipt v2\n"


def _load_base() -> Any:
    path = Path(__file__).with_name("verify_publication_bundle.py")
    specification = importlib.util.spec_from_file_location(
        "easysplat_toolchain_publication_base", path
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load the publication verification library")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


BASE = _load_base()


class ToolchainPublicationError(ValueError):
    """The toolchain evidence does not form one authenticated byte closure."""


@dataclass(frozen=True)
class ExpectedIdentity:
    version: str
    app_version: str
    source_repository: str
    source_commit: str
    producer_run_id: int
    producer_run_attempt: int
    producer_artifact_id: int
    producer_artifact_name: str
    producer_artifact_digest: str
    request_artifact_id: int
    request_artifact_name: str
    request_artifact_digest: str
    request_sha256: str
    authority_repository: str
    authority_commit: str
    authority_run_id: int
    authority_run_attempt: int
    authority_payload_artifact_id: int
    authority_payload_artifact_name: str
    authority_payload_artifact_digest: str
    authority_receipt_artifact_id: int
    authority_receipt_artifact_name: str
    authority_receipt_artifact_digest: str
    handoff_run_id: int
    handoff_run_attempt: int


@dataclass(frozen=True)
class ValidatedAuthorityClosure:
    manifest: dict[str, Any]
    manifest_raw: bytes
    envelope_raw: bytes
    receipt_raw: bytes


def fail(message: str) -> NoReturn:
    raise ToolchainPublicationError(message)


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _validate_positive(value: Any, label: str) -> int:
    if type(value) is not int or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def _validate_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or ARTIFACT_DIGEST.fullmatch(value) is None:
        fail(f"{label} must be a sha256 artifact digest")
    return value


def _validate_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        fail(f"{label} must be a lowercase SHA-256 digest")
    return value


def _require_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        fail(f"{label} fields must be exactly {sorted(expected)}")
    return value


def _read_regular(path: Path, *, maximum: int, label: str) -> bytes:
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum
        ):
            fail(f"{label} is not a bounded single-link regular file")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(1_024 * 1_024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        named = path.lstat()
    except ToolchainPublicationError:
        raise
    except OSError as error:
        fail(f"cannot read {label}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    def identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
        return (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
    if (
        identity(before) != identity(after)
        or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)
        or len(data) != after.st_size
    ):
        fail(f"{label} changed while it was read")
    return data


def _stat_identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _stage_regular_snapshot(
    source: Path,
    destination: Path,
    *,
    maximum: int,
    label: str,
    expected_sha256: str,
    expected_size: int | None = None,
) -> tuple[int, int, int, int, int, int, int]:
    """Copy one verified pathname through a single source descriptor."""
    _validate_sha256(expected_sha256, f"{label} expected digest")
    source_descriptor = -1
    destination_descriptor = -1
    before: os.stat_result | None = None
    after: os.stat_result | None = None
    named: os.stat_result | None = None
    digest = hashlib.sha256()
    written = 0
    complete = False
    try:
        source_descriptor = os.open(
            source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        )
        before = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum
            or (expected_size is not None and before.st_size != expected_size)
        ):
            fail(f"{label} is not the expected bounded single-link regular file")
        destination_descriptor = os.open(
            destination,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        while True:
            block = os.read(source_descriptor, 1_024 * 1_024)
            if not block:
                break
            digest.update(block)
            offset = 0
            while offset < len(block):
                count = os.write(destination_descriptor, block[offset:])
                if count <= 0:
                    fail(f"cannot stage {label}: short write")
                offset += count
                written += count
        os.fsync(destination_descriptor)
        after = os.fstat(source_descriptor)
        named = source.lstat()
        staged = os.fstat(destination_descriptor)
        os.lseek(destination_descriptor, 0, os.SEEK_SET)
        staged_digest = hashlib.sha256()
        staged_size = 0
        while True:
            block = os.read(destination_descriptor, 1_024 * 1_024)
            if not block:
                break
            staged_digest.update(block)
            staged_size += len(block)
        if (
            _stat_identity(before) != _stat_identity(after)
            or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)
            or written != after.st_size
            or staged.st_size != written
            or staged_size != written
        ):
            fail(f"{label} changed while being staged")
        if (
            digest.hexdigest() != expected_sha256
            or staged_digest.hexdigest() != expected_sha256
        ):
            fail(f"{label} does not match its verified digest")
        os.fchmod(destination_descriptor, 0o644)
        os.fsync(destination_descriptor)
        complete = True
    except ToolchainPublicationError:
        raise
    except OSError as error:
        fail(f"cannot stage {label}: {error}")
    finally:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if not complete:
            try:
                destination.unlink(missing_ok=True)
            except OSError:
                pass
    if not destination.exists():
        fail(f"cannot stage {label}")
    assert after is not None
    return _stat_identity(after)


def _assert_staged_source_unchanged(
    source: Path,
    expected_identity: tuple[int, int, int, int, int, int, int],
    *,
    label: str,
) -> None:
    try:
        current = source.lstat()
    except OSError as error:
        fail(f"{label} changed after it was staged: {error}")
    if _stat_identity(current) != expected_identity:
        fail(f"{label} changed after it was staged")


def _write_staged_bytes(destination: Path, data: bytes, *, label: str) -> None:
    descriptor = -1
    try:
        descriptor = os.open(
            destination,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        offset = 0
        while offset < len(data):
            count = os.write(descriptor, data[offset:])
            if count <= 0:
                fail(f"cannot write {label}: short write")
            offset += count
        os.fsync(descriptor)
        if os.fstat(descriptor).st_size != len(data):
            fail(f"cannot write complete {label}")
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
    except ToolchainPublicationError:
        raise
    except OSError as error:
        fail(f"cannot write {label}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _fsync_directory(path: Path, label: str) -> None:
    descriptor = -1
    try:
        descriptor = os.open(
            path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        )
        os.fsync(descriptor)
    except OSError as error:
        fail(f"cannot sync {label}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _load_json_bytes(data: bytes, label: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                fail(f"{label} contains a duplicate key: {key}")
            value[key] = item
        return value

    try:
        payload = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: fail(
                f"{label} contains a non-finite value: {value}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    return payload


def _load_json(path: Path, label: str, *, maximum: int = MAX_JSON_BYTES) -> dict[str, Any]:
    return _load_json_bytes(_read_regular(path, maximum=maximum, label=label), label)


def _exact_regular_files(directory: Path, names: set[str], label: str) -> None:
    try:
        entries = list(directory.iterdir())
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if {entry.name for entry in entries} != names:
        fail(f"{label} must contain exactly {sorted(names)}")
    folded: set[str] = set()
    for entry in entries:
        key = entry.name.casefold()
        if key in folded:
            fail(f"{label} contains a case-insensitive name collision")
        folded.add(key)
        try:
            metadata = entry.lstat()
        except OSError as error:
            fail(f"cannot inspect {label} member: {error}")
        if not stat.S_ISREG(metadata.st_mode) or entry.is_symlink() or metadata.st_nlink != 1:
            fail(f"{label} contains a non-regular member: {entry.name}")


def _artifact_record(value: Any, label: str, *, include_request_sha: bool = False) -> dict[str, Any]:
    expected = {"id", "name", "digest"}
    if include_request_sha:
        expected.add("requestSHA256")
    record = _require_exact_keys(value, expected, label)
    _validate_positive(record["id"], f"{label} id")
    if not isinstance(record["name"], str) or not record["name"]:
        fail(f"{label} name is invalid")
    _validate_digest(record["digest"], f"{label} digest")
    if include_request_sha:
        _validate_sha256(record["requestSHA256"], f"{label} request hash")
    return record


def _archive_names(version: str) -> dict[str, str]:
    return {
        "macos-arm64-core": f"toolchain-macos-arm64-{version}-core.zip",
        "geometry-da3-base": f"toolchain-geometry-da3-base-{version}.zip",
        "geometry-da3-small": f"toolchain-geometry-da3-small-{version}.zip",
    }


def _validate_zip_notarization(receipt_path: Path, archive_path: Path, label: str) -> None:
    receipt = _load_json(receipt_path, f"{label} notarization receipt", maximum=1_024 * 1_024)
    _require_exact_keys(
        receipt,
        {
            "schemaVersion",
            "artifactType",
            "artifactDigestFormat",
            "submissionID",
            "status",
            "preStapleSHA256",
            "postStapleSHA256",
            "stapled",
            "verification",
            "downstreamChecksums",
        },
        f"{label} notarization receipt",
    )
    verification = _require_exact_keys(
        receipt["verification"],
        {"codesign", "systemPolicy", "stapler", "gatekeeper"},
        f"{label} notarization verification",
    )
    archive_hash = _sha256_bytes(
        _read_regular(archive_path, maximum=MAX_ARCHIVE_BYTES, label=f"{label} archive")
    )
    if (
        receipt["schemaVersion"] != 1
        or receipt["artifactType"] != "zip"
        or receipt["artifactDigestFormat"] != "sha256-file-v1"
        or not isinstance(receipt["submissionID"], str)
        or not receipt["submissionID"]
        or receipt["status"] != "Accepted"
        or receipt["preStapleSHA256"] != archive_hash
        or receipt["postStapleSHA256"] != archive_hash
        or receipt["stapled"] is not False
        or any(value != "notApplicable" for value in verification.values())
        or receipt["downstreamChecksums"] != "generate-after-notarization"
    ):
        fail(f"{label} ZIP notarization receipt does not bind the final archive")


def _validate_request(
    request_path: Path,
    *,
    version: str,
    source_repository: str,
    source_commit: str,
) -> tuple[dict[str, Any], dict[str, Any], bytes]:
    raw = _read_regular(
        request_path, maximum=MAX_JSON_BYTES, label="post-sign release request"
    )
    request = _load_json_bytes(raw, "post-sign release request")
    _require_exact_keys(
        request,
        {"schemaVersion", "sourceRepository", "sourceCommit", "manifestSHA256", "manifest"},
        "post-sign release request",
    )
    if raw != _canonical(request):
        fail("post-sign release request is not canonical compact JSON")
    if (
        request["schemaVersion"] != 2
        or request["sourceRepository"] != source_repository
        or request["sourceCommit"] != source_commit
    ):
        fail("post-sign release request source identity is invalid")
    manifest = _require_exact_keys(
        request["manifest"],
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
        "post-sign unsigned manifest",
    )
    if (
        manifest["schemaVersion"] != 2
        or manifest["toolchainAPI"] != 2
        or manifest["version"] != version
        or manifest["signatureEd25519"] != ""
    ):
        fail("post-sign unsigned manifest schema or version is invalid")
    if request["manifestSHA256"] != _sha256_bytes(_canonical(manifest)):
        fail("post-sign release request manifest hash is invalid")
    return request, manifest, raw


def _validate_finalization(
    path: Path,
    *,
    archives: dict[str, tuple[Path, bytes]],
    version: str,
    source_commit: str,
) -> None:
    receipt = _load_json(path, "distribution-signing finalization", maximum=1_024 * 1_024)
    _require_exact_keys(
        receipt,
        {
            "schemaVersion",
            "kind",
            "toolchainVersion",
            "identityFingerprintSHA1",
            "teamID",
            "signedAt",
            "sourceCommit",
            "sourceInputs",
            "unsignedComponentArchives",
            "builderAttestedUnsignedReleaseRequest",
            "builderArtifactAuthority",
            "distributionSigningReceipt",
            "supplyChain",
            "finalArchives",
        },
        "distribution-signing finalization",
    )
    if (
        receipt["schemaVersion"] != 1
        or receipt["kind"] != "easysplat-signed-toolchain-finalization"
        or receipt["toolchainVersion"] != version
        or receipt["sourceCommit"] != source_commit
        or not isinstance(receipt["identityFingerprintSHA1"], str)
        or re.fullmatch(r"[0-9A-F]{40}", receipt["identityFingerprintSHA1"]) is None
        or not isinstance(receipt["teamID"], str)
        or re.fullmatch(r"[A-Z0-9]{10}", receipt["teamID"]) is None
    ):
        fail("distribution-signing finalization identity is invalid")
    rows = receipt["finalArchives"]
    if not isinstance(rows, list) or len(rows) != 3:
        fail("distribution-signing finalization archive closure is invalid")
    by_component: dict[str, dict[str, Any]] = {}
    for row in rows:
        row = _require_exact_keys(row, {"component", "name", "sha256", "size"}, "final archive row")
        component = row["component"]
        if (
            not isinstance(component, str)
            or component not in {"core", "base", "small"}
            or component in by_component
        ):
            fail("distribution-signing finalization archive components are invalid")
        by_component[component] = row
    component_names = {"core": "macos-arm64-core", "base": "geometry-da3-base", "small": "geometry-da3-small"}
    for short, component in component_names.items():
        archive_path, data = archives[component]
        row = by_component.get(short)
        if row != {
            "component": short,
            "name": archive_path.name,
            "sha256": _sha256_bytes(data),
            "size": len(data),
        }:
            fail(f"distribution-signing finalization does not bind final {short} archive")


def validate_producer(
    producer: Path,
    request_path: Path,
    *,
    version: str,
    source_repository: str,
    source_commit: str,
    notary_validator: Callable[[Path, Path, str], None] = _validate_zip_notarization,
) -> dict[str, Any]:
    try:
        BASE.parse_semver(version)
    except BASE.PublicationError as error:
        fail(str(error))
    if REPOSITORY.fullmatch(source_repository) is None or COMMIT.fullmatch(source_commit) is None:
        fail("producer source identity is invalid")
    names = _archive_names(version)
    expected_files = {
        *names.values(),
        "distribution-signing-finalization.json",
        "core-notarization.json",
        "da3-base-notarization.json",
        "toolchain-build-host.json",
    }
    _exact_regular_files(producer, expected_files, "final producer artifact")
    request, manifest, _ = _validate_request(
        request_path,
        version=version,
        source_repository=source_repository,
        source_commit=source_commit,
    )
    components = manifest.get("components")
    if not isinstance(components, list) or len(components) != 3:
        fail("post-sign release request component closure is invalid")
    archives: dict[str, tuple[Path, bytes]] = {}
    seen: set[str] = set()
    for component in components:
        if not isinstance(component, dict):
            fail("post-sign release request component is invalid")
        name = component.get("name")
        if not isinstance(name, str) or name not in names or name in seen:
            fail("post-sign release request component set is invalid")
        seen.add(name)
        archive = producer / names[name]
        data = _read_regular(
            archive, maximum=MAX_ARCHIVE_BYTES, label=f"final signed archive {archive.name}"
        )
        expected_url = (
            f"https://github.com/{source_repository}/releases/download/"
            f"toolchain-v{version}/{archive.name}"
        )
        if (
            component.get("url") != expected_url
            or component.get("sha256") != _sha256_bytes(data)
            or component.get("sizeBytes") != len(data)
        ):
            fail(f"post-sign request does not hash final signed archive: {archive.name}")
        archives[name] = (archive, data)
    if seen != set(names):
        fail("post-sign release request component set is incomplete")
    _validate_finalization(
        producer / "distribution-signing-finalization.json",
        archives=archives,
        version=version,
        source_commit=source_commit,
    )
    host = _load_json(producer / "toolchain-build-host.json", "toolchain build host", maximum=1_024 * 1_024)
    if host.get("schemaVersion") != 1 or host.get("hostRole") != "identity-free-production-builder":
        fail("toolchain build host does not attest the identity-free builder")
    if not set(host).issubset(
        {
            "schemaVersion", "hostRole", "macOS", "macOSBuild", "developerDir",
            "xcode", "xcodeBuild", "sdk", "sdkBuild", "architecture", "swift",
            "clang", "metal",
        }
    ):
        fail("toolchain build host contains unsupported fields")
    notary_validator(
        producer / "core-notarization.json",
        producer / names["macos-arm64-core"],
        "core",
    )
    notary_validator(
        producer / "da3-base-notarization.json",
        producer / names["geometry-da3-base"],
        "DA3 Base",
    )
    return request


def _read_authority_zip_bytes(
    raw: bytes, expected_names: set[str], label: str
) -> dict[str, bytes]:
    try:
        # Parse the immutable byte snapshot checked above. Reopening the named path
        # here would create a time-of-check/time-of-use gap on shared runners.
        with zipfile.ZipFile(io.BytesIO(raw), "r") as archive:
            infos = archive.infolist()
            if {info.filename for info in infos} != expected_names or len(infos) != len(expected_names):
                fail(f"{label} has the wrong exact file set")
            result: dict[str, bytes] = {}
            for info in infos:
                mode = (info.external_attr >> 16) & 0o170000
                if (
                    info.is_dir()
                    or info.flag_bits & 0x1
                    or mode == stat.S_IFLNK
                    or info.file_size <= 0
                    or info.file_size > MAX_JSON_BYTES
                ):
                    fail(f"{label} contains an unsafe member")
                result[info.filename] = archive.read(info)
    except ToolchainPublicationError:
        raise
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        fail(f"{label} is not a valid artifact ZIP: {error}")
    return result


def _validate_expected_identity(expected: ExpectedIdentity) -> None:
    if (
        REPOSITORY.fullmatch(expected.source_repository) is None
        or COMMIT.fullmatch(expected.source_commit) is None
        or REPOSITORY.fullmatch(expected.authority_repository) is None
        or COMMIT.fullmatch(expected.authority_commit) is None
    ):
        fail("expected source or authority identity is malformed")
    for value, label in (
        (expected.producer_run_id, "producer run"),
        (expected.producer_run_attempt, "producer run attempt"),
        (expected.producer_artifact_id, "producer artifact"),
        (expected.request_artifact_id, "request artifact"),
        (expected.authority_run_id, "authority run"),
        (expected.authority_run_attempt, "authority run attempt"),
        (expected.authority_payload_artifact_id, "authority payload artifact"),
        (expected.authority_receipt_artifact_id, "authority receipt artifact"),
        (expected.handoff_run_id, "handoff run"),
        (expected.handoff_run_attempt, "handoff run attempt"),
    ):
        _validate_positive(value, label)
    for value, label in (
        (expected.producer_artifact_digest, "producer artifact digest"),
        (expected.request_artifact_digest, "request artifact digest"),
        (expected.authority_payload_artifact_digest, "authority payload artifact digest"),
        (expected.authority_receipt_artifact_digest, "authority receipt artifact digest"),
    ):
        _validate_digest(value, label)
    _validate_sha256(expected.request_sha256, "request SHA-256")


def _expected_record(identifier: int, name: str, digest: str) -> dict[str, Any]:
    return {"id": identifier, "name": name, "digest": digest}


def _load_public_key(path: Path) -> bytes:
    raw = _read_regular(path, maximum=1_024, label="tracked toolchain public key")
    try:
        key = base64.b64decode(raw.decode("ascii").strip(), validate=True)
    except (UnicodeDecodeError, binascii.Error, ValueError):
        fail("tracked toolchain public key is invalid base64")
    if len(key) != 32:
        fail("tracked toolchain public key must decode to 32 bytes")
    return key


def validate_authority_closure(
    *,
    producer: Path,
    request_path: Path,
    authority_handoff: Path,
    public_key_path: Path,
    expected: ExpectedIdentity,
    notary_validator: Callable[[Path, Path, str], None] = _validate_zip_notarization,
) -> ValidatedAuthorityClosure:
    _validate_expected_identity(expected)
    request = validate_producer(
        producer,
        request_path,
        version=expected.version,
        source_repository=expected.source_repository,
        source_commit=expected.source_commit,
        notary_validator=notary_validator,
    )
    request_raw = _read_regular(request_path, maximum=MAX_JSON_BYTES, label="post-sign release request")
    if _sha256_bytes(request_raw) != expected.request_sha256:
        fail("post-sign release request digest differs from the producer output")
    _exact_regular_files(
        authority_handoff,
        {
            "toolchain-authority-payload.zip",
            "toolchain-authority-receipt.zip",
            "authority-transport.json",
        },
        "authority handoff",
    )
    payload_zip = authority_handoff / "toolchain-authority-payload.zip"
    receipt_zip = authority_handoff / "toolchain-authority-receipt.zip"
    payload_raw = _read_regular(payload_zip, maximum=MAX_AUTHORITY_ARTIFACT_BYTES, label="authority payload artifact")
    receipt_raw = _read_regular(receipt_zip, maximum=MAX_AUTHORITY_ARTIFACT_BYTES, label="authority receipt artifact")
    transport = _load_json(authority_handoff / "authority-transport.json", "authority transport", maximum=1_024 * 1_024)
    _require_exact_keys(
        transport,
        {
            "schemaVersion", "sourceRepository", "sourceCommit", "handoffRunID",
            "handoffRunAttempt", "authorityRepository", "authorityCommit",
            "authorityRunID", "authorityRunAttempt", "payloadArtifact", "receiptArtifact",
        },
        "authority transport",
    )
    if (
        transport["schemaVersion"] != 1
        or transport["sourceRepository"] != expected.source_repository
        or transport["sourceCommit"] != expected.source_commit
        or transport["handoffRunID"] != expected.handoff_run_id
        or transport["handoffRunAttempt"] != expected.handoff_run_attempt
        or transport["authorityRepository"] != expected.authority_repository
        or transport["authorityCommit"] != expected.authority_commit
        or transport["authorityRunID"] != expected.authority_run_id
        or transport["authorityRunAttempt"] != expected.authority_run_attempt
    ):
        fail("authority transport identity is invalid")
    for key, identifier, name, digest, raw in (
        (
            "payloadArtifact", expected.authority_payload_artifact_id,
            expected.authority_payload_artifact_name,
            expected.authority_payload_artifact_digest, payload_raw,
        ),
        (
            "receiptArtifact", expected.authority_receipt_artifact_id,
            expected.authority_receipt_artifact_name,
            expected.authority_receipt_artifact_digest, receipt_raw,
        ),
    ):
        record = _require_exact_keys(
            transport[key], {"id", "name", "digest", "downloadSHA256"}, key
        )
        if record != {
            "id": identifier,
            "name": name,
            "digest": digest,
            "downloadSHA256": _sha256_bytes(raw),
        }:
            fail(f"authority transport {key} identity is invalid")

    payload_files = _read_authority_zip_bytes(
        payload_raw,
        {"manifest.json", "toolchain-authority-envelope.json"},
        "authority payload artifact",
    )
    receipt_files = _read_authority_zip_bytes(
        receipt_raw,
        {"toolchain-authority-receipt.json"},
        "authority receipt artifact",
    )
    manifest_raw = payload_files["manifest.json"]
    envelope_raw = payload_files["toolchain-authority-envelope.json"]
    authority_receipt_raw = receipt_files["toolchain-authority-receipt.json"]
    manifest = _load_json_bytes(manifest_raw, "signed toolchain manifest")
    envelope = _load_json_bytes(envelope_raw, "toolchain authority envelope")
    authority_receipt = _load_json_bytes(authority_receipt_raw, "toolchain authority receipt")
    for raw, value, label in (
        (manifest_raw, manifest, "signed toolchain manifest"),
        (envelope_raw, envelope, "toolchain authority envelope"),
        (authority_receipt_raw, authority_receipt, "toolchain authority receipt"),
    ):
        if raw != _canonical(value):
            fail(f"{label} is not canonical compact JSON")

    _require_exact_keys(
        envelope,
        {
            "schemaVersion", "kind", "sourceRepository", "sourceCommit",
            "sourceWorkflowPath", "sourceRunID", "sourceRunAttempt",
            "producerArtifact", "requestArtifact", "authorityRepository",
            "authorityCommit", "authorityRunID", "authorityRunAttempt",
            "releaseTag", "keyID", "signedManifestSHA256", "manifest",
        },
        "authority envelope",
    )
    producer_record = _artifact_record(envelope["producerArtifact"], "producer artifact")
    request_record = _artifact_record(
        envelope["requestArtifact"], "request artifact", include_request_sha=True
    )
    if producer_record != _expected_record(
        expected.producer_artifact_id,
        expected.producer_artifact_name,
        expected.producer_artifact_digest,
    ):
        fail("producer artifact identity does not match the authority envelope")
    expected_request_record = {
        **_expected_record(
            expected.request_artifact_id,
            expected.request_artifact_name,
            expected.request_artifact_digest,
        ),
        "requestSHA256": expected.request_sha256,
    }
    if request_record != expected_request_record:
        fail("request artifact identity does not match the authority envelope")
    public_key = _load_public_key(public_key_path)
    key_id = _sha256_bytes(public_key)
    if (
        envelope["schemaVersion"] != 2
        or envelope["kind"] != "easysplat-toolchain-authority-envelope"
        or envelope["sourceRepository"] != expected.source_repository
        or envelope["sourceCommit"] != expected.source_commit
        or envelope["sourceWorkflowPath"] != ".github/workflows/toolchain-build.yml"
        or envelope["sourceRunID"] != expected.producer_run_id
        or envelope["sourceRunAttempt"] != expected.producer_run_attempt
        or envelope["authorityRepository"] != expected.authority_repository
        or envelope["authorityCommit"] != expected.authority_commit
        or envelope["authorityRunID"] != expected.authority_run_id
        or envelope["authorityRunAttempt"] != expected.authority_run_attempt
        or envelope["releaseTag"] != f"toolchain-v{expected.version}"
        or envelope["keyID"] != key_id
        or envelope["signedManifestSHA256"] != _sha256_bytes(manifest_raw)
        or envelope["manifest"] != manifest
    ):
        fail("authority envelope identity or signed payload is invalid")
    unsigned_manifest = dict(manifest)
    unsigned_manifest["signatureEd25519"] = ""
    if unsigned_manifest != request["manifest"]:
        fail("signed manifest differs from the post-sign release request")
    with tempfile.TemporaryDirectory(prefix="easysplat-toolchain-manifest-") as temporary:
        manifest_path = Path(temporary) / "manifest.json"
        manifest_path.write_bytes(manifest_raw)
        try:
            BASE.validate_toolchain_manifest(
                manifest_path,
                public_key_path,
                app_version=expected.app_version,
                toolchain_version=expected.version,
                source_repository=expected.source_repository,
            )
        except BASE.PublicationError as error:
            fail(f"signed toolchain manifest is invalid: {error}")

    _require_exact_keys(
        authority_receipt,
        {
            "schemaVersion", "kind", "keyID", "sourceRepository", "sourceCommit",
            "sourceRunID", "sourceRunAttempt", "producerArtifact", "requestArtifact",
            "authorityRepository", "authorityCommit", "authorityRunID",
            "authorityRunAttempt", "authorityPayloadArtifact", "authorityEnvelopeSHA256",
            "signedManifestSHA256", "sourceReleaseRequestSHA256", "signedAt",
            "signatureEd25519",
        },
        "authority receipt",
    )
    payload_record = _artifact_record(
        authority_receipt["authorityPayloadArtifact"], "authority payload artifact"
    )
    expected_payload_record = _expected_record(
        expected.authority_payload_artifact_id,
        expected.authority_payload_artifact_name,
        expected.authority_payload_artifact_digest,
    )
    if payload_record != expected_payload_record:
        fail("authority receipt payload artifact identity is invalid")
    if (
        authority_receipt["schemaVersion"] != 2
        or authority_receipt["kind"] != "easysplat-toolchain-authority-receipt"
        or authority_receipt["keyID"] != key_id
        or authority_receipt["sourceRepository"] != expected.source_repository
        or authority_receipt["sourceCommit"] != expected.source_commit
        or authority_receipt["sourceRunID"] != expected.producer_run_id
        or authority_receipt["sourceRunAttempt"] != expected.producer_run_attempt
        or authority_receipt["producerArtifact"] != producer_record
        or authority_receipt["requestArtifact"] != request_record
        or authority_receipt["authorityRepository"] != expected.authority_repository
        or authority_receipt["authorityCommit"] != expected.authority_commit
        or authority_receipt["authorityRunID"] != expected.authority_run_id
        or authority_receipt["authorityRunAttempt"] != expected.authority_run_attempt
        or authority_receipt["authorityEnvelopeSHA256"] != _sha256_bytes(envelope_raw)
        or authority_receipt["signedManifestSHA256"] != _sha256_bytes(manifest_raw)
        or authority_receipt["sourceReleaseRequestSHA256"] != expected.request_sha256
        or not isinstance(authority_receipt["signedAt"], str)
        or not authority_receipt["signedAt"]
    ):
        fail("authority receipt does not bind the complete authority closure")
    try:
        signature = base64.b64decode(
            authority_receipt["signatureEd25519"], validate=True
        )
    except (TypeError, binascii.Error, ValueError):
        fail("authority receipt signature is invalid base64")
    unsigned_receipt = dict(authority_receipt)
    unsigned_receipt["signatureEd25519"] = ""
    if len(signature) != 64 or not BASE.verify_ed25519(
        public_key,
        AUTHORITY_RECEIPT_DOMAIN + _canonical(unsigned_receipt),
        signature,
    ):
        fail("authority receipt signature is invalid")
    return ValidatedAuthorityClosure(
        manifest=manifest,
        manifest_raw=manifest_raw,
        envelope_raw=envelope_raw,
        receipt_raw=authority_receipt_raw,
    )


def full_toolchain_identity(manifest: dict[str, Any]) -> str:
    try:
        return BASE.full_toolchain_identity(manifest)
    except (BASE.PublicationError, KeyError, TypeError) as error:
        fail(f"cannot derive full signed toolchain identity: {error}")


def validate_benchmark_binding(
    benchmark_suite: Path,
    *,
    evidence_path: Path,
    manifest: dict[str, Any],
    expected: ExpectedIdentity,
    benchmark_run_id: int,
    benchmark_run_attempt: int,
    benchmark_artifact_id: int,
    benchmark_artifact_name: str,
    benchmark_artifact_digest: str,
) -> dict[str, Any]:
    _validate_positive(benchmark_run_id, "benchmark run")
    _validate_positive(benchmark_run_attempt, "benchmark run attempt")
    _validate_positive(benchmark_artifact_id, "benchmark artifact")
    if not isinstance(benchmark_artifact_name, str) or not benchmark_artifact_name:
        fail("benchmark artifact name is invalid")
    _validate_digest(benchmark_artifact_digest, "benchmark artifact digest")
    evidence = _require_exact_keys(
        _load_json(evidence_path, "benchmark transport evidence"),
        {
            "schemaVersion",
            "sourceRepository",
            "sourceCommit",
            "benchmarkRunID",
            "benchmarkRunAttempt",
            "benchmarkArtifact",
        },
        "benchmark transport evidence",
    )
    artifact = _require_exact_keys(
        evidence["benchmarkArtifact"],
        {"id", "name", "digest", "verifiedSuiteSHA256"},
        "benchmark transport artifact",
    )
    _validate_sha256(
        artifact["verifiedSuiteSHA256"], "verified benchmark suite digest"
    )
    if (
        evidence["schemaVersion"] != 1
        or evidence["sourceRepository"] != expected.source_repository
        or evidence["sourceCommit"] != expected.source_commit
        or evidence["benchmarkRunID"] != benchmark_run_id
        or evidence["benchmarkRunAttempt"] != benchmark_run_attempt
        or artifact["id"] != benchmark_artifact_id
        or artifact["name"] != benchmark_artifact_name
        or artifact["digest"] != benchmark_artifact_digest
    ):
        fail("benchmark transport identity does not match the verified artifact")
    _validate_positive(evidence["benchmarkRunID"], "benchmark transport run")
    _validate_positive(
        evidence["benchmarkRunAttempt"], "benchmark transport run attempt"
    )
    _validate_positive(artifact["id"], "benchmark transport artifact")
    if not isinstance(artifact["name"], str) or not artifact["name"]:
        fail("benchmark transport artifact name is invalid")
    _validate_digest(artifact["digest"], "benchmark transport artifact digest")
    with tempfile.TemporaryDirectory(prefix="easysplat-benchmark-") as temporary:
        snapshot = Path(temporary) / "verified-suite.json"
        _stage_regular_snapshot(
            benchmark_suite,
            snapshot,
            maximum=MAX_JSON_BYTES,
            label="verified benchmark suite",
            expected_sha256=artifact["verifiedSuiteSHA256"],
        )
        try:
            suite_payload = BASE.validate_benchmark_suite(
                snapshot,
                app_version=expected.app_version,
                source_commit=expected.source_commit,
                toolchain_identity=full_toolchain_identity(manifest),
            )
        except BASE.PublicationError as error:
            if "different signed toolchain closure" in str(error):
                fail("benchmark used a different signed toolchain closure")
            fail(f"benchmark evidence is invalid: {error}")
    return {
        "schemaVersion": 1,
        "kind": "easysplat-toolchain-benchmark-evidence",
        "sourceRepository": expected.source_repository,
        "sourceCommit": expected.source_commit,
        "benchmarkRunID": benchmark_run_id,
        "benchmarkRunAttempt": benchmark_run_attempt,
        "benchmarkArtifact": dict(artifact),
        "benchmarkSuiteRunID": suite_payload["run_id"],
        "appVersion": suite_payload["app_version"],
        "fullToolchainIdentity": suite_payload["toolchain_identity"],
        "status": suite_payload["status"],
    }


def prepare_publication_output(
    output: Path,
    *,
    producer: Path,
    request_path: Path,
    authority: ValidatedAuthorityClosure,
    manifest: dict[str, Any],
    expected_request_sha256: str,
    benchmark_evidence: dict[str, Any],
) -> None:
    if output.exists():
        try:
            if any(output.iterdir()):
                fail("publication output directory must be absent or empty")
        except OSError as error:
            fail(f"cannot inspect publication output directory: {error}")
        output.rmdir()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent)
    )
    try:
        archive_paths = sorted(producer.glob("toolchain-*.zip"), key=lambda path: path.name)
        archive_names = _archive_names(str(manifest.get("version", "")))
        if {path.name for path in archive_paths} != set(archive_names.values()):
            fail("final producer does not contain exactly three public archives")
        components = manifest.get("components")
        if not isinstance(components, list):
            fail("signed manifest has no publication component closure")
        by_name = {
            component.get("name"): component
            for component in components
            if isinstance(component, dict)
        }
        if set(by_name) != set(archive_names):
            fail("signed manifest component set does not match public archives")
        component_by_filename = {
            filename: by_name[name] for name, filename in archive_names.items()
        }
        for path in archive_paths:
            component = component_by_filename[path.name]
            _stage_regular_snapshot(
                path,
                temporary / path.name,
                maximum=MAX_ARCHIVE_BYTES,
                label=f"publication archive {path.name}",
                expected_sha256=component.get("sha256"),
                expected_size=component.get("sizeBytes"),
            )
        _stage_regular_snapshot(
            request_path,
            temporary / "toolchain-release-request.json",
            maximum=MAX_JSON_BYTES,
            label="publication release request",
            expected_sha256=expected_request_sha256,
        )
        _write_staged_bytes(
            temporary / "manifest.json",
            authority.manifest_raw,
            label="signed manifest",
        )
        _write_staged_bytes(
            temporary / "toolchain-authority-envelope.json",
            authority.envelope_raw,
            label="authority envelope",
        )
        _write_staged_bytes(
            temporary / "toolchain-authority-receipt.json",
            authority.receipt_raw,
            label="authority receipt",
        )
        _write_staged_bytes(
            temporary / "toolchain-benchmark-evidence.json",
            _canonical(benchmark_evidence),
            label="benchmark publication evidence",
        )
        expected = {
            *(path.name for path in archive_paths),
            "manifest.json",
            "toolchain-release-request.json",
            "toolchain-authority-envelope.json",
            "toolchain-authority-receipt.json",
            "toolchain-benchmark-evidence.json",
        }
        _exact_regular_files(temporary, expected, "publication output")
        _fsync_directory(temporary, "publication staging directory")
        os.replace(temporary, output)
        _fsync_directory(output.parent, "publication output parent")
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def install_verified_toolchain(
    output: Path,
    *,
    producer: Path,
    manifest: dict[str, Any],
) -> None:
    """Materialize the already verified component archives as one atomic install."""
    if output.exists():
        fail("verified toolchain install destination must not already exist")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    archive_staging = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.archives.", dir=output.parent)
    )
    names = _archive_names(str(manifest["version"]))
    components = manifest.get("components")
    if not isinstance(components, list):
        fail("signed manifest has no installable component closure")
    by_name = {
        component.get("name"): component
        for component in components
        if isinstance(component, dict)
    }
    if set(by_name) != set(names):
        fail("signed manifest component set cannot be installed")
    installed_paths: set[str] = set()
    try:
        for component_name in (
            "macos-arm64-core",
            "geometry-da3-base",
            "geometry-da3-small",
        ):
            component = by_name[component_name]
            expected_contents = component.get("contents")
            critical_hashes = component.get("criticalFileHashes")
            if (
                not isinstance(expected_contents, list)
                or not isinstance(critical_hashes, dict)
                or set(expected_contents) != set(critical_hashes)
            ):
                fail(f"signed component file closure is invalid: {component_name}")
            archive_path = producer / names[component_name]
            staged_archive = archive_staging / archive_path.name
            source_identity = _stage_regular_snapshot(
                archive_path,
                staged_archive,
                maximum=MAX_ARCHIVE_BYTES,
                label=f"verified component archive {archive_path.name}",
                expected_sha256=component.get("sha256"),
                expected_size=component.get("sizeBytes"),
            )
            try:
                with zipfile.ZipFile(staged_archive, "r") as archive:
                    infos = archive.infolist()
                    if (
                        len(infos) != len(expected_contents)
                        or {info.filename for info in infos} != set(expected_contents)
                    ):
                        fail(f"component archive file set changed: {component_name}")
                    expanded = 0
                    for info in infos:
                        relative = Path(info.filename)
                        parts = relative.parts
                        mode = (info.external_attr >> 16) & 0o177777
                        if (
                            relative.is_absolute()
                            or not parts
                            or any(part in {"", ".", ".."} for part in parts)
                            or "\\" in info.filename
                            or info.is_dir()
                            or info.flag_bits & 0x1
                            or stat.S_IFMT(mode) not in {0, stat.S_IFREG}
                            or stat.S_IMODE(mode) not in {0o644, 0o755}
                            or info.filename in installed_paths
                        ):
                            fail(f"component archive contains an unsafe path: {info.filename}")
                        expanded += info.file_size
                        if expanded > component.get("expandedSizeBytes", -1):
                            fail(f"component archive exceeds its signed expanded size: {component_name}")
                        destination = temporary.joinpath(*parts)
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        digest = hashlib.sha256()
                        written = 0
                        with archive.open(info, "r") as source, destination.open("xb") as target:
                            for block in iter(lambda: source.read(1_024 * 1_024), b""):
                                target.write(block)
                                digest.update(block)
                                written += len(block)
                        if (
                            written != info.file_size
                            or digest.hexdigest() != critical_hashes.get(info.filename)
                        ):
                            fail(f"component file does not match its signed digest: {info.filename}")
                        destination.chmod(stat.S_IMODE(mode))
                        installed_paths.add(info.filename)
                    if expanded != component.get("expandedSizeBytes"):
                        fail(f"component archive expanded size is invalid: {component_name}")
                _assert_staged_source_unchanged(
                    archive_path,
                    source_identity,
                    label=f"verified component archive {archive_path.name}",
                )
            except ToolchainPublicationError:
                raise
            except (OSError, zipfile.BadZipFile, RuntimeError) as error:
                fail(f"cannot install verified component {component_name}: {error}")
        state = {
            "schemaVersion": 2,
            "installedArtifacts": {
                name: by_name[name]["sha256"] for name in sorted(by_name)
            },
            "installedCapabilities": sorted(
                {
                    capability
                    for component in components
                    for capability in component["capabilities"]
                }
            ),
            "signedManifest": manifest,
        }
        (temporary / ".easysplat_toolchain_state.json").write_bytes(_canonical(state))
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(archive_staging, ignore_errors=True)


def _identity_from_arguments(arguments: argparse.Namespace) -> ExpectedIdentity:
    return ExpectedIdentity(
        version=arguments.version,
        app_version=arguments.app_version,
        source_repository=arguments.source_repository,
        source_commit=arguments.source_commit,
        producer_run_id=arguments.producer_run_id,
        producer_run_attempt=arguments.producer_run_attempt,
        producer_artifact_id=arguments.producer_artifact_id,
        producer_artifact_name=arguments.producer_artifact_name,
        producer_artifact_digest=arguments.producer_artifact_digest,
        request_artifact_id=arguments.request_artifact_id,
        request_artifact_name=arguments.request_artifact_name,
        request_artifact_digest=arguments.request_artifact_digest,
        request_sha256=arguments.request_sha256,
        authority_repository=arguments.authority_repository,
        authority_commit=arguments.authority_commit,
        authority_run_id=arguments.authority_run_id,
        authority_run_attempt=arguments.authority_run_attempt,
        authority_payload_artifact_id=arguments.authority_payload_artifact_id,
        authority_payload_artifact_name=arguments.authority_payload_artifact_name,
        authority_payload_artifact_digest=arguments.authority_payload_artifact_digest,
        authority_receipt_artifact_id=arguments.authority_receipt_artifact_id,
        authority_receipt_artifact_name=arguments.authority_receipt_artifact_name,
        authority_receipt_artifact_digest=arguments.authority_receipt_artifact_digest,
        handoff_run_id=arguments.handoff_run_id,
        handoff_run_attempt=arguments.handoff_run_attempt,
    )


def _add_identity_arguments(parser: argparse.ArgumentParser) -> None:
    for name in (
        "version", "app-version", "source-repository", "source-commit",
        "producer-artifact-name", "producer-artifact-digest",
        "request-artifact-name", "request-artifact-digest", "request-sha256",
        "authority-repository", "authority-commit",
        "authority-payload-artifact-name", "authority-payload-artifact-digest",
        "authority-receipt-artifact-name", "authority-receipt-artifact-digest",
    ):
        parser.add_argument(f"--{name}", required=True)
    for name in (
        "producer-run-id", "producer-run-attempt", "producer-artifact-id",
        "request-artifact-id", "authority-run-id", "authority-run-attempt",
        "authority-payload-artifact-id", "authority-receipt-artifact-id",
        "handoff-run-id", "handoff-run-attempt",
    ):
        parser.add_argument(f"--{name}", type=int, required=True)


def _add_authority_paths(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--producer", type=Path, required=True)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--authority-handoff", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    producer = commands.add_parser("validate-producer")
    producer.add_argument("--producer", type=Path, required=True)
    producer.add_argument("--request", type=Path, required=True)
    producer.add_argument("--version", required=True)
    producer.add_argument("--source-repository", required=True)
    producer.add_argument("--source-commit", required=True)

    authority = commands.add_parser("verify-authority")
    _add_authority_paths(authority)
    _add_identity_arguments(authority)
    authority.add_argument("--manifest-out", type=Path, required=True)
    authority.add_argument("--install-root", type=Path, required=True)

    install = commands.add_parser("install")
    install.add_argument("--producer", type=Path, required=True)
    install.add_argument("--manifest", type=Path, required=True)
    install.add_argument("--public-key", type=Path, required=True)
    install.add_argument("--version", required=True)
    install.add_argument("--app-version", required=True)
    install.add_argument("--source-repository", required=True)
    install.add_argument("--install-root", type=Path, required=True)

    verify = commands.add_parser("verify")
    _add_authority_paths(verify)
    _add_identity_arguments(verify)
    verify.add_argument("--benchmark-suite", type=Path, required=True)
    verify.add_argument("--benchmark-evidence", type=Path, required=True)
    verify.add_argument("--output", type=Path, required=True)
    verify.add_argument("--benchmark-artifact-digest", required=True)
    verify.add_argument("--benchmark-artifact-name", required=True)
    verify.add_argument("--benchmark-run-id", type=int, required=True)
    verify.add_argument("--benchmark-run-attempt", type=int, required=True)
    verify.add_argument("--benchmark-artifact-id", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "validate-producer":
            request = validate_producer(
                arguments.producer,
                arguments.request,
                version=arguments.version,
                source_repository=arguments.source_repository,
                source_commit=arguments.source_commit,
            )
            print(json.dumps({"status": "valid", "requestSHA256": _sha256_bytes(_canonical(request))}, sort_keys=True))
            return 0
        if arguments.command == "install":
            try:
                manifest = BASE.validate_toolchain_manifest(
                    arguments.manifest,
                    arguments.public_key,
                    app_version=arguments.app_version,
                    toolchain_version=arguments.version,
                    source_repository=arguments.source_repository,
                )
            except BASE.PublicationError as error:
                fail(f"signed toolchain manifest is invalid: {error}")
            install_verified_toolchain(
                arguments.install_root,
                producer=arguments.producer,
                manifest=manifest,
            )
            print(json.dumps({"status": "installed", "full_toolchain_identity": full_toolchain_identity(manifest)}, sort_keys=True))
            return 0
        expected = _identity_from_arguments(arguments)
        authority = validate_authority_closure(
            producer=arguments.producer,
            request_path=arguments.request,
            authority_handoff=arguments.authority_handoff,
            public_key_path=arguments.public_key,
            expected=expected,
        )
        manifest = authority.manifest
        if arguments.command == "verify-authority":
            if arguments.manifest_out.exists():
                fail("signed manifest output must not already exist")
            arguments.manifest_out.parent.mkdir(parents=True, exist_ok=True)
            arguments.manifest_out.write_bytes(authority.manifest_raw)
            install_verified_toolchain(
                arguments.install_root,
                producer=arguments.producer,
                manifest=manifest,
            )
            print(json.dumps({"status": "valid", "full_toolchain_identity": full_toolchain_identity(manifest)}, sort_keys=True))
            return 0
        benchmark_evidence = validate_benchmark_binding(
            arguments.benchmark_suite,
            evidence_path=arguments.benchmark_evidence,
            manifest=manifest,
            expected=expected,
            benchmark_run_id=arguments.benchmark_run_id,
            benchmark_run_attempt=arguments.benchmark_run_attempt,
            benchmark_artifact_id=arguments.benchmark_artifact_id,
            benchmark_artifact_name=arguments.benchmark_artifact_name,
            benchmark_artifact_digest=arguments.benchmark_artifact_digest,
        )
        prepare_publication_output(
            arguments.output,
            producer=arguments.producer,
            request_path=arguments.request,
            authority=authority,
            manifest=manifest,
            expected_request_sha256=expected.request_sha256,
            benchmark_evidence=benchmark_evidence,
        )
        print(json.dumps({"status": "valid", "full_toolchain_identity": full_toolchain_identity(manifest)}, sort_keys=True))
        return 0
    except ToolchainPublicationError as error:
        print(f"Toolchain publication verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
