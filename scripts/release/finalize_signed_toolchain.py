#!/usr/bin/env python3
"""Developer ID-sign a builder-attested EasySplat toolchain byte closure.

This preserves authenticated bytes through signing; it does not claim reproducible
source-to-binary derivation.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import json
import os
import re
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Callable, Dict, List, NamedTuple, NoReturn, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[2]
SIGNER = ROOT / "scripts/release/sign_macos_distribution.py"
SUPPLY_CHAIN_GENERATOR = ROOT / "scripts/toolchain/generate_supply_chain_manifest.py"
REPRODUCIBLE_ZIP = ROOT / "scripts/toolchain/create_reproducible_zip.py"
PACKAGE_TOOLCHAIN = ROOT / "scripts/toolchain/package_toolchain.sh"
INTERNAL_RECEIPT_PATH = "provenance/distribution-signing.json"
SUPPLY_CHAIN_PATH = "supply-chain/components.json"
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024 - 1
MAX_ARCHIVE_ENTRIES = 250_000
MAX_ARCHIVE_EXPANDED_BYTES = 12 * 1024 * 1024 * 1024
MAX_ALL_EXPANDED_BYTES = 24 * 1024 * 1024 * 1024
MAX_MEMBER_BYTES = 8 * 1024 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
COMPRESSION_RATIO_MIN_BYTES = 8 * 1024 * 1024
MAX_SUPPLY_CHAIN_BYTES = 16 * 1024 * 1024
MAX_RECEIPT_BYTES = 1 * 1024 * 1024
MAX_RELEASE_REQUEST_BYTES = 8 * 1024 * 1024
MAX_SOURCE_INPUT_BYTES = 64 * 1024 * 1024
MAX_GITHUB_AUTHORITY_RECEIPT_BYTES = 4 * 1024 * 1024
COPY_BUFFER_BYTES = 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
FINGERPRINT_PATTERN = re.compile(r"[0-9A-Fa-f]{40}")
TEAM_ID_PATTERN = re.compile(r"[A-Z0-9]{10}")
SEMVER_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
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
SOURCE_BINDING_PATHS = (
    "Tools/NativeColmap/local_vocab_retriever.cc",
    "Tools/NativeColmap/local_vocab_retriever.h",
    "scripts/release/finalize_signed_toolchain.py",
    "scripts/release/notarize_artifact.sh",
    "scripts/release/sign_macos_distribution.py",
    "scripts/toolchain/atomic_swap_install.py",
    "scripts/toolchain/build_colmap.sh",
    "scripts/toolchain/build_colmap_impl.sh",
    "scripts/toolchain/secure_colmap_build.py",
    "scripts/toolchain/create_reproducible_zip.py",
    "scripts/toolchain/generate_supply_chain_manifest.py",
    "scripts/toolchain/package_toolchain.sh",
    "scripts/toolchain/patches/colmap-4.1.1-easysplat.patch",
    "scripts/toolchain/validate_da3_payload.py",
    "scripts/toolchain/validate_native_msplat.sh",
    "scripts/toolchain/colmap-support-lock.json",
    "scripts/toolchain/ceres-lock.json",
    "scripts/toolchain/openimageio-lock.json",
    "scripts/toolchain/da3-model-lock.json",
)
ARCHIVE_SELECTIONS = {
    "core": (
        "bin",
        "lib",
        "licenses",
        "provenance",
        "supply-chain/components.json",
        "msplat",
    ),
    "base": (
        "da3_mps/bin",
        "da3_mps/python",
        "da3_mps/app",
        "da3_mps/vendor",
        "da3_mps/licenses",
        "da3_mps/build_info.json",
        "da3_mps/models/DA3-BASE",
    ),
    "small": ("da3_mps/models/DA3-SMALL",),
}


class FinalizationError(ValueError):
    pass


class FileState(NamedTuple):
    mode: int
    size: int
    sha256: str
    is_macho: bool


class TreeState(NamedTuple):
    files: Dict[str, FileState]
    directories: Dict[str, int]


class InputBinding(NamedTuple):
    device: int
    inode: int
    mode: int
    size: int
    mtime_ns: int
    ctime_ns: int
    sha256: str


class PathIdentity(NamedTuple):
    device: int
    inode: int
    mode: int


class BuilderArtifactEvidence(NamedTuple):
    repository: str
    workflow_run_id: int
    source_commit: str
    unsigned_artifact_id: int
    unsigned_artifact_digest: str
    request_artifact_id: int
    request_artifact_digest: str
    request_sha256: str


class GitHubArtifactEvidence(NamedTuple):
    repository: str
    workflow_run_id: int
    source_commit: str
    artifact_id: int
    artifact_digest: str
    artifact_name: str


SignerRunner = Callable[[Path, str, str, Path], None]
SupplyChainRunner = Callable[[Path, str, Path], None]
ArchiveRunner = Callable[[Path, Path, Sequence[str]], None]
UnsignedValidator = Callable[[Path], None]
ArtifactAuthorityVerifier = Callable[[BuilderArtifactEvidence, str], None]


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: BinaryIO,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        del request, file_pointer, code, message, headers, new_url
        return None


def fail(message: str) -> NoReturn:
    raise FinalizationError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stat_binding_identity(status: os.stat_result) -> Tuple[int, int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        stat.S_IMODE(status.st_mode),
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(COPY_BUFFER_BYTES), b""):
                digest.update(block)
    except OSError:
        fail(f"unable to hash release input: {path.name}")
    return digest.hexdigest()


def canonical_json(payload: object) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def compact_canonical_json(payload: object) -> bytes:
    return json.dumps(
        payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def atomic_write(path: Path, data: bytes, *, maximum: int) -> None:
    if len(data) > maximum:
        fail(f"receipt exceeds its {maximum}-byte safety limit")
    descriptor = -1
    temporary = ""
    try:
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{path.name}.", dir=path.parent
        )
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = ""
    except OSError:
        fail(f"unable to write release receipt atomically: {path.name}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def read_bounded_regular_file(
    path: Path, *, maximum: int, label: str, require_nonempty: bool = False
) -> bytes:
    descriptor = -1
    try:
        descriptor = os.open(
            path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or (require_nonempty and before.st_size <= 0)
            or before.st_size > maximum
        ):
            fail(f"{label} is unsafe or exceeds its {maximum}-byte limit")
        chunks: List[bytes] = []
        remaining = maximum + 1
        while remaining:
            block = os.read(descriptor, min(COPY_BUFFER_BYTES, remaining))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        named = path.lstat()
    except OSError:
        fail(f"{label} is missing or changed while it was read")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    before_identity = (
        before.st_dev,
        before.st_ino,
        stat.S_IMODE(before.st_mode),
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    if (
        before_identity != after_identity
        or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)
        or len(data) != after.st_size
        or len(data) > maximum
    ):
        fail(f"{label} changed while it was read")
    return data


def parse_json_object(data: bytes, *, label: str) -> Dict[str, Any]:
    def reject_duplicates(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key: {key}")
            result[key] = value
        return result

    try:
        payload = json.loads(
            data,
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON value: {value}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        fail(f"{label} is not valid JSON")
    if not isinstance(payload, dict):
        fail(f"{label} must contain a JSON object")
    return payload


def validate_github_artifact_authority(
    evidence: BuilderArtifactEvidence,
    version: str,
    *,
    fetch_json: Callable[[str], Dict[str, Any]],
) -> None:
    if (
        evidence.repository != "dud8/EasySplat"
        or not SEMVER_PATTERN.fullmatch(version)
        or evidence.workflow_run_id <= 0
        or evidence.unsigned_artifact_id <= 0
        or evidence.request_artifact_id <= 0
        or evidence.unsigned_artifact_id == evidence.request_artifact_id
        or not re.fullmatch(r"[0-9a-f]{40}", evidence.source_commit)
        or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", evidence.unsigned_artifact_digest
        )
        or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", evidence.request_artifact_digest
        )
        or not SHA256_PATTERN.fullmatch(evidence.request_sha256)
    ):
        fail("builder artifact authority evidence is malformed")
    expected = (
        (
            evidence.unsigned_artifact_id,
            evidence.unsigned_artifact_digest,
            f"toolchain-unsigned-components-{version}",
        ),
        (
            evidence.request_artifact_id,
            evidence.request_artifact_digest,
            f"toolchain-unsigned-request-{version}",
        ),
    )
    for artifact_id, artifact_digest, artifact_name in expected:
        validate_github_artifact_payload(
            GitHubArtifactEvidence(
                repository=evidence.repository,
                workflow_run_id=evidence.workflow_run_id,
                source_commit=evidence.source_commit,
                artifact_id=artifact_id,
                artifact_digest=artifact_digest,
                artifact_name=artifact_name,
            ),
            fetch_json=fetch_json,
        )
    validate_github_workflow_run_and_main(
        repository=evidence.repository,
        workflow_run_id=evidence.workflow_run_id,
        source_commit=evidence.source_commit,
        fetch_json=fetch_json,
    )


def github_authority_paths(evidence: BuilderArtifactEvidence) -> Tuple[str, ...]:
    return (
        f"repos/{evidence.repository}/actions/artifacts/{evidence.unsigned_artifact_id}",
        f"repos/{evidence.repository}/actions/artifacts/{evidence.request_artifact_id}",
        f"repos/{evidence.repository}/actions/runs/{evidence.workflow_run_id}",
        f"repos/{evidence.repository}/branches/main",
    )


def validate_github_artifact_authority_receipt(
    path: Path,
    evidence: BuilderArtifactEvidence,
    version: str,
) -> None:
    payload = load_canonical_json(
        path,
        maximum=MAX_GITHUB_AUTHORITY_RECEIPT_BYTES,
        label="GitHub artifact authority receipt",
    )
    if set(payload) != {"schemaVersion", "responses"} or payload["schemaVersion"] != 1:
        fail("GitHub artifact authority receipt schema is invalid")
    responses = payload["responses"]
    expected_paths = set(github_authority_paths(evidence))
    if (
        not isinstance(responses, dict)
        or set(responses) != expected_paths
        or any(not isinstance(response, dict) for response in responses.values())
    ):
        fail("GitHub artifact authority receipt response set is invalid")

    def fetch_json(request_path: str) -> Dict[str, Any]:
        response = responses.get(request_path)
        if not isinstance(response, dict):
            fail("GitHub artifact authority receipt response set is invalid")
        return response

    validate_github_artifact_authority(
        evidence,
        version,
        fetch_json=fetch_json,
    )


def validate_github_artifact_payload(
    evidence: GitHubArtifactEvidence,
    *,
    fetch_json: Callable[[str], Dict[str, Any]],
) -> None:
    payload = fetch_json(
        f"repos/{evidence.repository}/actions/artifacts/{evidence.artifact_id}"
    )
    workflow_run = payload.get("workflow_run")
    if (
        payload.get("id") != evidence.artifact_id
        or payload.get("name") != evidence.artifact_name
        or payload.get("digest") != evidence.artifact_digest
        or payload.get("expired") is not False
        or not isinstance(workflow_run, dict)
        or workflow_run.get("id") != evidence.workflow_run_id
        or workflow_run.get("head_branch") != "main"
        or workflow_run.get("head_sha") != evidence.source_commit
    ):
        fail(f"GitHub artifact authority rejected {evidence.artifact_name}")


def validate_github_workflow_run_and_main(
    *,
    repository: str,
    workflow_run_id: int,
    source_commit: str,
    fetch_json: Callable[[str], Dict[str, Any]],
) -> None:
    run = fetch_json(
        f"repos/{repository}/actions/runs/{workflow_run_id}"
    )
    run_repository = run.get("repository")
    if (
        run.get("id") != workflow_run_id
        or run.get("event") != "workflow_dispatch"
        or run.get("path")
        not in {
            ".github/workflows/toolchain-build.yml",
            ".github/workflows/toolchain-build.yml@main",
        }
        or run.get("head_branch") != "main"
        or run.get("head_sha") != source_commit
        or not isinstance(run_repository, dict)
        or run_repository.get("full_name") != repository
    ):
        fail("builder artifact authority rejected the workflow run identity")
    main = fetch_json(f"repos/{repository}/branches/main")
    commit = main.get("commit")
    if (
        main.get("name") != "main"
        or main.get("protected") is not True
        or not isinstance(commit, dict)
        or commit.get("sha") != source_commit
    ):
        fail("builder artifact authority is not current protected main")


def validate_single_github_artifact_authority(
    evidence: GitHubArtifactEvidence,
    *,
    fetch_json: Callable[[str], Dict[str, Any]],
) -> None:
    if (
        evidence.repository != "dud8/EasySplat"
        or evidence.workflow_run_id <= 0
        or not re.fullmatch(r"[0-9a-f]{40}", evidence.source_commit)
        or evidence.artifact_id <= 0
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", evidence.artifact_digest)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", evidence.artifact_name)
    ):
        fail("GitHub artifact authority evidence is malformed")
    validate_github_artifact_payload(evidence, fetch_json=fetch_json)
    validate_github_workflow_run_and_main(
        repository=evidence.repository,
        workflow_run_id=evidence.workflow_run_id,
        source_commit=evidence.source_commit,
        fetch_json=fetch_json,
    )


def build_github_api_opener() -> urllib.request.OpenerDirector:
    ca_file = Path("/private/etc/ssl/cert.pem")
    try:
        metadata = ca_file.lstat()
    except OSError:
        fail("system TLS trust roots are unavailable")
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or metadata.st_size <= 0
    ):
        fail("system TLS trust roots are unsafe")
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = True
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_verify_locations(cafile=str(ca_file))
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=context),
            NoRedirectHandler(),
        )
    except (OSError, ssl.SSLError):
        fail("system TLS trust roots could not be loaded")


def production_github_fetch_json() -> Callable[[str], Dict[str, Any]]:
    token = os.environ.get("GITHUB_TOKEN", "")
    if (
        not token
        or len(token) > 512
        or any(ord(character) < 0x20 for character in token)
    ):
        fail("GITHUB_TOKEN is required to authenticate builder artifact authority")
    opener = build_github_api_opener()

    def fetch_json(path: str) -> Dict[str, Any]:
        request = urllib.request.Request(
            f"https://api.github.com/{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2026-03-10",
                "User-Agent": "EasySplat-toolchain-finalizer/1",
            },
            method="GET",
        )
        try:
            with opener.open(request, timeout=30) as response:
                if response.status != 200:
                    fail("GitHub artifact authority returned a non-success response")
                data = response.read(MAX_RECEIPT_BYTES + 1)
        except (OSError, urllib.error.URLError):
            fail("GitHub artifact authority could not be reached")
        if not data or len(data) > MAX_RECEIPT_BYTES:
            fail("GitHub artifact authority response is empty or oversized")
        return parse_json_object(data, label="GitHub artifact authority response")

    return fetch_json


def production_github_artifact_authority(
    evidence: BuilderArtifactEvidence, version: str
) -> None:
    validate_github_artifact_authority(
        evidence,
        version,
        fetch_json=production_github_fetch_json(),
    )


def production_single_github_artifact_authority(
    evidence: GitHubArtifactEvidence,
) -> None:
    validate_single_github_artifact_authority(
        evidence,
        fetch_json=production_github_fetch_json(),
    )


def load_json(path: Path, *, maximum: int, label: str) -> Dict[str, Any]:
    data = read_bounded_regular_file(path, maximum=maximum, label=label)
    return parse_json_object(data, label=label)


def load_canonical_json(path: Path, *, maximum: int, label: str) -> Dict[str, Any]:
    data = read_bounded_regular_file(
        path, maximum=maximum, label=label, require_nonempty=True
    )
    try:
        payload = parse_json_object(data, label=label)
    except FinalizationError:
        fail(f"{label} is not valid canonical JSON")
    if compact_canonical_json(payload) != data:
        fail(f"{label} is not valid canonical JSON")
    return payload


def normalized_absolute(path: Path, *, must_exist: bool, label: str) -> Path:
    if (
        not path.is_absolute()
        or ".." in path.parts
        or Path(os.path.normpath(str(path))) != path
    ):
        fail(f"{label} must be an absolute normalized path")
    try:
        resolved = path.resolve(strict=must_exist)
    except OSError:
        fail(f"{label} does not exist")
    if resolved != path:
        fail(f"{label} ancestry contains a symlink or is not canonical")
    return path


def input_binding(path: Path) -> InputBinding:
    normalized_absolute(path, must_exist=True, label="source archive")
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(descriptor)
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, COPY_BUFFER_BYTES)
            if not block:
                break
            digest.update(block)
        after = os.fstat(descriptor)
        named = path.lstat()
    except OSError:
        fail("source archive is missing")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        stat_binding_identity(before) != stat_binding_identity(after)
        or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)
        or not stat.S_ISREG(after.st_mode)
        or stat.S_ISLNK(after.st_mode)
        or after.st_nlink != 1
        or after.st_uid != os.geteuid()
        or after.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or after.st_size <= 0
        or after.st_size > MAX_ARCHIVE_BYTES
    ):
        fail("source archive is unsafe, empty, hard linked, or exceeds the 2 GiB limit")
    return InputBinding(
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        digest.hexdigest(),
    )


def snapshot_authenticated_input(
    path: Path, expected: InputBinding, *, label: str
) -> BinaryIO:
    """Copy one previously bound input from a single descriptor to an anonymous file."""
    source = -1
    snapshot: BinaryIO | None = None
    try:
        source = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(source)
        current = (
            before.st_dev,
            before.st_ino,
            stat.S_IMODE(before.st_mode),
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        if current != expected[:6] or not stat.S_ISREG(before.st_mode):
            fail(f"{label} changed before its authenticated snapshot")
        snapshot = tempfile.TemporaryFile(mode="w+b")
        digest = hashlib.sha256()
        copied = 0
        while True:
            block = os.read(source, COPY_BUFFER_BYTES)
            if not block:
                break
            snapshot.write(block)
            digest.update(block)
            copied += len(block)
        after = os.fstat(source)
        if (
            current
            != (
                after.st_dev,
                after.st_ino,
                stat.S_IMODE(after.st_mode),
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            or copied != expected.size
            or digest.hexdigest() != expected.sha256
        ):
            fail(f"{label} changed while its authenticated snapshot was copied")
        snapshot.flush()
        os.fsync(snapshot.fileno())
        snapshot.seek(0)
        return snapshot
    except OSError:
        if snapshot is not None:
            snapshot.close()
        fail(f"{label} could not be snapshotted")
    finally:
        if source >= 0:
            os.close(source)


def snapshot_directory_ancestry(path: Path) -> Dict[Path, PathIdentity]:
    identities: Dict[Path, PathIdentity] = {}
    current = Path(path.anchor)
    for component in (None, *path.parts[1:]):
        if component is not None:
            current /= component
        try:
            status = current.lstat()
        except OSError:
            fail("output directory ancestry changed during finalization")
        if stat.S_ISLNK(status.st_mode) or not stat.S_ISDIR(status.st_mode):
            fail("output directory ancestry contains a symlink or non-directory")
        identities[current] = PathIdentity(
            status.st_dev,
            status.st_ino,
            stat.S_IMODE(status.st_mode),
        )
    immediate = path.lstat()
    if immediate.st_uid != os.geteuid() or immediate.st_mode & (
        stat.S_IWGRP | stat.S_IWOTH
    ):
        fail("output parent must be owned by the current user and privately writable")
    return identities


def require_unchanged_directory_ancestry(
    expected: Dict[Path, PathIdentity],
) -> None:
    for path, identity in expected.items():
        try:
            status = path.lstat()
        except OSError:
            fail("output directory ancestry changed during finalization")
        current = PathIdentity(
            status.st_dev,
            status.st_ino,
            stat.S_IMODE(status.st_mode),
        )
        if (
            stat.S_ISLNK(status.st_mode)
            or not stat.S_ISDIR(status.st_mode)
            or current != identity
        ):
            fail("output directory ancestry changed during finalization")


def require_input_unchanged(
    path: Path, expected: InputBinding, *, label: str = "source archive"
) -> None:
    if input_binding(path) != expected:
        fail(f"{label} changed during finalization: {path.name}")


def require_bound_file_at(
    directory_descriptor: int,
    name: str,
    expected: InputBinding,
    *,
    label: str,
) -> None:
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_descriptor,
        )
        before = os.fstat(descriptor)
        digest = hashlib.sha256()
        size = 0
        while True:
            block = os.read(descriptor, COPY_BUFFER_BYTES)
            if not block:
                break
            digest.update(block)
            size += len(block)
        after = os.fstat(descriptor)
    except OSError:
        fail(f"{label} is missing or unsafe after publication")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    current = InputBinding(
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        digest.hexdigest(),
    )
    if (
        stat_binding_identity(before) != stat_binding_identity(after)
        or not stat.S_ISREG(after.st_mode)
        or after.st_nlink != 1
        or after.st_uid != os.geteuid()
        or size != after.st_size
        or current != expected
    ):
        fail(f"{label} changed across atomic publication")


def require_exact_directory_entries(
    directory_descriptor: int,
    expected: Sequence[str],
    *,
    label: str,
) -> None:
    try:
        names = os.listdir(directory_descriptor)
    except OSError:
        fail(f"{label} could not be enumerated")
    expected_names = sorted(expected, key=os.fsencode)
    normalized = [unicodedata.normalize("NFC", name).casefold() for name in names]
    if (
        sorted(names, key=os.fsencode) != expected_names
        or len(normalized) != len(set(normalized))
    ):
        fail(f"{label} contains unexpected directory entries")


def validate_unsigned_release_request(
    data: bytes,
    *,
    binding: InputBinding,
    expected_sha256: str,
    version: str,
    source_commit: str,
    archives: Dict[str, Path],
    bindings: Dict[str, InputBinding],
) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, Any]]:
    if binding.size > MAX_RELEASE_REQUEST_BYTES:
        fail("authenticated release request exceeds the 8 MiB limit")
    if (
        not SHA256_PATTERN.fullmatch(expected_sha256)
        or binding.sha256 != expected_sha256
    ):
        fail("release request SHA-256 does not match independent authority evidence")
    request = parse_json_object(data, label="authenticated release request")
    if compact_canonical_json(request) != data:
        fail("authenticated release request is not valid canonical JSON")
    if set(request) != {
        "schemaVersion",
        "sourceRepository",
        "sourceCommit",
        "manifestSHA256",
        "manifest",
    }:
        fail("authenticated release request fields do not match schema 2")
    manifest = request.get("manifest")
    if (
        request.get("schemaVersion") != 2
        or request.get("sourceRepository") != "dud8/EasySplat"
        or request.get("sourceCommit") != source_commit
        or not isinstance(manifest, dict)
        or request.get("manifestSHA256")
        != sha256_bytes(compact_canonical_json(manifest))
    ):
        fail("authenticated release request identity or manifest digest is invalid")
    if set(manifest) != {
        "schemaVersion",
        "toolchainAPI",
        "keyID",
        "version",
        "publishedAt",
        "appVersionRange",
        "components",
        "signatureEd25519",
    }:
        fail("authenticated release manifest fields do not match schema 2")
    raw_components = manifest.get("components")
    app_version_range = manifest.get("appVersionRange")
    if (
        manifest.get("schemaVersion") != 2
        or manifest.get("toolchainAPI") != 2
        or manifest.get("version") != version
        or manifest.get("signatureEd25519") != ""
        or not SHA256_PATTERN.fullmatch(str(manifest.get("keyID") or ""))
        or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",
            str(manifest.get("publishedAt") or ""),
        )
        or not isinstance(app_version_range, dict)
        or set(app_version_range) != {"minimum", "maximumExclusive"}
        or not isinstance(app_version_range.get("minimum"), str)
        or not isinstance(app_version_range.get("maximumExclusive"), str)
        or not isinstance(raw_components, list)
    ):
        fail("authenticated release manifest identity is invalid")
    expected_names = {
        "core": "macos-arm64-core",
        "base": "geometry-da3-base",
        "small": "geometry-da3-small",
    }
    if [
        row.get("name") if isinstance(row, dict) else None for row in raw_components
    ] != [expected_names[component] for component in ("core", "base", "small")]:
        fail("authenticated release request has the wrong component set or order")
    components: Dict[str, Dict[str, Any]] = {}
    component_fields = {
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
    }
    expected_dependencies = {
        "core": [],
        "base": ["macos-arm64-core"],
        "small": ["geometry-da3-base"],
    }
    expected_requirements = {
        "core": "required",
        "base": "optional",
        "small": "optional",
    }
    expected_capabilities = {
        "core": ["runtime.core", "geometry.colmap", "training.msplat"],
        "base": ["geometry.da3.runtime", "geometry.da3.base"],
        "small": ["geometry.da3.small"],
    }
    for component, row in zip(("core", "base", "small"), raw_components):
        if not isinstance(row, dict):
            fail("authenticated release request contains a non-object component")
        contents = row.get("contents")
        critical = row.get("criticalFileHashes")
        size = row.get("sizeBytes")
        expanded_size = row.get("expandedSizeBytes")
        expected_url = (
            "https://github.com/dud8/EasySplat/releases/download/"
            f"toolchain-v{version}/{archives[component].name}"
        )
        if (
            set(row) != component_fields
            or row.get("name") != expected_names[component]
            or row.get("capabilities") != expected_capabilities[component]
            or row.get("url") != expected_url
            or row.get("sha256") != bindings[component].sha256
            or size != bindings[component].size
            or isinstance(size, bool)
            or not isinstance(size, int)
            or isinstance(expanded_size, bool)
            or not isinstance(expanded_size, int)
            or expanded_size <= 0
            or not SHA256_PATTERN.fullmatch(str(row.get("expandedClosureSHA256") or ""))
            or not isinstance(contents, list)
            or not contents
            or contents != sorted(contents)
            or len(contents) != len(set(contents))
            or not all(isinstance(item, str) for item in contents)
            or not isinstance(critical, dict)
            or set(critical) != set(contents)
            or not all(
                isinstance(value, str) and SHA256_PATTERN.fullmatch(value)
                for value in critical.values()
            )
            or row.get("dependencies") != expected_dependencies[component]
            or row.get("requirement") != expected_requirements[component]
        ):
            fail(
                f"authenticated release request component is invalid: {expected_names[component]}"
            )
        components[component] = row
    return components, request


def validate_requested_expanded_closure(
    components: Dict[str, Dict[str, Any]],
    component_paths: Dict[str, List[str]],
    state: TreeState,
) -> None:
    for component in ("core", "base", "small"):
        requested = components[component]
        paths = sorted(component_paths[component])
        digest = hashlib.sha256()
        digest.update(b"EasySplat expanded component closure v1\n")
        total = 0
        hashes: Dict[str, str] = {}
        for relative in paths:
            file_state = state.files[relative]
            total += file_state.size
            hashes[relative] = file_state.sha256
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(str(file_state.mode).encode("ascii"))
            digest.update(b"\0")
            digest.update(str(file_state.size).encode("ascii"))
            digest.update(b"\0")
            digest.update(file_state.sha256.encode("ascii"))
            digest.update(b"\n")
        if (
            requested["contents"] != paths
            or requested["expandedSizeBytes"] != total
            or requested["criticalFileHashes"] != hashes
            or requested["expandedClosureSHA256"] != digest.hexdigest()
        ):
            fail(
                f"authenticated release request expanded closure is stale: {component}"
            )


def validate_archive_name(raw: str) -> str:
    if (
        not raw
        or raw.startswith("/")
        or "\\" in raw
        or "\x00" in raw
        or unicodedata.normalize("NFC", raw) != raw
    ):
        fail(f"archive contains an unsafe or non-normalized path: {raw!r}")
    pure = PurePosixPath(raw)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        fail(f"archive contains path traversal: {raw!r}")
    if any(unicodedata.category(character) in {"Cc", "Cs"} for character in raw):
        fail(f"archive contains a control or surrogate character: {raw!r}")
    return pure.as_posix()


def validate_component_path(component: str, relative: str) -> None:
    if component == "core":
        if relative.startswith("da3_mps/"):
            fail(f"core archive contains a DA3 component path: {relative}")
    elif component == "base":
        if not relative.startswith("da3_mps/") or relative.startswith(
            "da3_mps/models/DA3-SMALL/"
        ):
            fail(f"DA3 BASE archive contains an out-of-component path: {relative}")
    elif component == "small":
        if not relative.startswith("da3_mps/models/DA3-SMALL/"):
            fail(f"DA3 SMALL archive contains an out-of-component path: {relative}")
    else:
        fail(f"unknown release component: {component}")


def archive_member_mode(info: zipfile.ZipInfo) -> int:
    unix_mode = info.external_attr >> 16
    file_type = stat.S_IFMT(unix_mode)
    if file_type not in {0, stat.S_IFREG}:
        fail(f"archive contains a symlink, hardlink, or special entry: {info.filename}")
    permissions = stat.S_IMODE(unix_mode)
    if permissions not in {0o644, 0o755}:
        fail(f"archive entry has unsafe or non-canonical permissions: {info.filename}")
    return permissions


def safe_extract_archive(
    archive_stream: BinaryIO,
    destination: Path,
    *,
    component: str,
    global_keys: Dict[str, str],
) -> Tuple[List[str], int]:
    paths: List[str] = []
    expanded = 0
    try:
        archive_stream.seek(0)
        with zipfile.ZipFile(archive_stream, "r") as archive:
            infos = archive.infolist()
            if not infos or len(infos) > MAX_ARCHIVE_ENTRIES:
                fail(f"{component} ZIP has an invalid entry count")
            for info in infos:
                if info.is_dir():
                    fail(
                        f"release ZIP contains an explicit directory entry: {info.filename}"
                    )
                relative = validate_archive_name(info.filename)
                validate_component_path(component, relative)
                key = unicodedata.normalize("NFC", relative).casefold()
                if key in global_keys:
                    fail(
                        f"release component archives overlap or contain a normalized duplicate: "
                        f"{relative} conflicts with {global_keys[key]}"
                    )
                global_keys[key] = relative
                if info.flag_bits & 0x1:
                    fail(f"archive contains an encrypted entry: {relative}")
                if info.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
                    fail(f"archive uses an unsupported compression method: {relative}")
                if info.extra or info.comment:
                    fail(
                        f"archive contains unsupported link or metadata fields: {relative}"
                    )
                mode = archive_member_mode(info)
                if info.file_size < 0 or info.file_size > MAX_MEMBER_BYTES:
                    fail(f"archive member exceeds its expanded size limit: {relative}")
                expanded += info.file_size
                if expanded > MAX_ARCHIVE_EXPANDED_BYTES:
                    fail(f"{component} ZIP exceeds its expanded size limit")
                if (
                    info.file_size >= COMPRESSION_RATIO_MIN_BYTES
                    and info.file_size / max(info.compress_size, 1)
                    > MAX_COMPRESSION_RATIO
                ):
                    fail(
                        f"archive member exceeds the compression-ratio limit: {relative}"
                    )

                output = destination.joinpath(*PurePosixPath(relative).parts)
                output.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                flags = (
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                )
                descriptor = os.open(output, flags, mode)
                try:
                    with os.fdopen(descriptor, "wb", closefd=True) as target:
                        remaining = info.file_size
                        with archive.open(info, "r") as source:
                            while remaining:
                                block = source.read(min(COPY_BUFFER_BYTES, remaining))
                                if not block:
                                    fail(f"archive member ended early: {relative}")
                                target.write(block)
                                remaining -= len(block)
                            if source.read(1):
                                fail(
                                    f"archive member exceeded its declared size: {relative}"
                                )
                        target.flush()
                        os.fchmod(target.fileno(), mode)
                        os.fsync(target.fileno())
                except Exception:
                    try:
                        output.unlink()
                    except FileNotFoundError:
                        pass
                    raise
                paths.append(relative)
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError) as error:
        fail(
            f"unable to safely extract {component} release ZIP: {type(error).__name__}"
        )
    return paths, expanded


def scan_tree(root: Path) -> TreeState:
    files: Dict[str, FileState] = {}
    directories: Dict[str, int] = {}
    for path in [
        root,
        *sorted(root.rglob("*"), key=lambda item: os.fsencode(item.as_posix())),
    ]:
        relative = "." if path == root else path.relative_to(root).as_posix()
        try:
            status = path.lstat()
        except OSError:
            fail(f"toolchain tree changed while being inspected: {relative}")
        if stat.S_ISLNK(status.st_mode):
            fail(f"toolchain tree contains a symlink: {relative}")
        if stat.S_ISDIR(status.st_mode):
            if status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"toolchain tree contains a writable directory: {relative}")
            directories[relative] = stat.S_IMODE(status.st_mode)
        elif stat.S_ISREG(status.st_mode):
            if status.st_nlink != 1:
                fail(f"toolchain tree contains a hard linked file: {relative}")
            if status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"toolchain tree contains a writable file: {relative}")
            try:
                with path.open("rb") as stream:
                    data_prefix = stream.read(4)
            except OSError:
                fail(f"unable to inspect toolchain file magic: {relative}")
            files[relative] = FileState(
                stat.S_IMODE(status.st_mode),
                status.st_size,
                sha256_file(path),
                data_prefix in MACHO_MAGICS,
            )
        else:
            fail(f"toolchain tree contains a special file: {relative}")
    return TreeState(files, directories)


def signer_tree_manifest_digest(root: Path) -> str:
    """Reproduce the signer's complete-tree receipt digest exactly."""
    entries: List[Dict[str, Any]] = []
    paths = [
        root,
        *sorted(root.rglob("*"), key=lambda item: os.fsencode(item.as_posix())),
    ]
    for path in paths:
        relative = "." if path == root else path.relative_to(root).as_posix()
        try:
            status = path.lstat()
        except OSError:
            fail(f"signing tree changed while its receipt digest was computed: {relative}")
        if stat.S_ISLNK(status.st_mode):
            fail(f"signing tree contains a symlink: {relative}")
        if stat.S_ISDIR(status.st_mode):
            kind = "directory"
            digest = None
        elif stat.S_ISREG(status.st_mode):
            kind = "file"
            digest = sha256_file(path)
        else:
            fail(f"signing tree contains a special file: {relative}")
        entries.append(
            {
                "device": status.st_dev,
                "inode": status.st_ino,
                "kind": kind,
                "mode": f"{stat.S_IMODE(status.st_mode):04o}",
                "relativePath": relative,
                "sha256": digest,
                "size": status.st_size,
            }
        )
    manifest = hashlib.sha256()
    manifest.update(b"EasySplat macOS signing tree manifest v1\0")
    for entry in sorted(entries, key=lambda row: os.fsencode(row["relativePath"])):
        payload = json.dumps(
            entry,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        manifest.update(len(payload).to_bytes(8, "big"))
        manifest.update(payload)
    return manifest.hexdigest()


def validate_unsigned_supply_chain(
    root: Path, version: str, state: TreeState, *, source_commit: str
) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, Dict[str, Any]], str]:
    path = root / SUPPLY_CHAIN_PATH
    payload = load_json(
        path, maximum=MAX_SUPPLY_CHAIN_BYTES, label="unsigned supply-chain manifest"
    )
    if payload.get("schemaVersion") != 1 or payload.get("toolchainVersion") != version:
        fail("unsigned supply-chain manifest has the wrong schema or toolchain version")
    raw_files = payload.get("files")
    raw_components = payload.get("components")
    if not isinstance(raw_files, list) or not isinstance(raw_components, list):
        fail("unsigned supply-chain manifest has invalid component or file rows")
    files: Dict[str, Dict[str, Any]] = {}
    for row in raw_files:
        if not isinstance(row, dict):
            fail("unsigned supply-chain manifest contains a non-object file row")
        relative = str(row.get("path") or "")
        validate_archive_name(relative)
        if relative in files:
            fail(f"unsigned supply-chain manifest contains a duplicate file: {relative}")
        state_row = state.files.get(relative)
        expected_kind = "mach-o" if state_row and state_row.is_macho else "file"
        if (
            state_row is None
            or row.get("sha256") != state_row.sha256
            or row.get("size") != state_row.size
            or row.get("kind") != expected_kind
            or not isinstance(row.get("component"), str)
        ):
            fail(
                f"unsigned supply-chain file row does not match archive bytes: {relative}"
            )
        files[relative] = row
    expected = set(state.files) - {SUPPLY_CHAIN_PATH}
    if set(files) != expected:
        fail(
            "unsigned supply-chain manifest does not exactly inventory merged archive files"
        )

    components: Dict[str, Dict[str, Any]] = {}
    grouped: Dict[str, List[str]] = {}
    for relative, row in files.items():
        grouped.setdefault(str(row["component"]), []).append(relative)
    for row in raw_components:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            fail("unsigned supply-chain manifest contains an invalid component row")
        component_id = row["id"]
        if component_id in components:
            fail(
                f"unsigned supply-chain manifest contains duplicate component: {component_id}"
            )
        listed = row.get("files")
        if not isinstance(listed, list) or sorted(listed) != sorted(
            grouped.get(component_id, [])
        ):
            fail(f"source component file ownership is incomplete: {component_id}")
        components[component_id] = row
    if set(components) != set(grouped):
        fail("unsigned supply-chain manifest has missing or extra component owners")
    runner = components.get("easysplat-da3-runner")
    if (
        not isinstance(runner, dict)
        or runner.get("type") != "script"
        or runner.get("version") != version
        or runner.get("revision") != source_commit
        or runner.get("source") != "https://github.com/dud8/EasySplat"
    ):
        fail("unsigned EasySplat runner is not bound to the authenticated source commit")
    return files, components, sha256_file(path)


def pointer_digest(receipt: Dict[str, Any], pointer: Sequence[str], label: str) -> str:
    current: Any = receipt
    for key in pointer:
        if not isinstance(current, dict) or key not in current:
            fail(f"{label} is missing build-receipt hash {'/'.join(pointer)}")
        current = current[key]
    if not isinstance(current, str) or not SHA256_PATTERN.fullmatch(current):
        fail(f"{label} contains an invalid build-receipt hash")
    return current


def native_build_provenance(
    root: Path, pre_state: TreeState
) -> Dict[str, Dict[str, str]]:
    definitions = {
        "bin/colmap": ("provenance/colmap.json", ("executable_sha256",)),
        "bin/easysplat-train": ("msplat/build_info.json", ("executable_sha256",)),
        "lib/libomp.dylib": (
            "provenance/colmap-support.json",
            ("library_sha256", "lib/libomp.dylib"),
        ),
    }
    result: Dict[str, Dict[str, str]] = {}
    for relative, (receipt_relative, pointer) in definitions.items():
        state = pre_state.files.get(relative)
        if state is None or not state.is_macho:
            fail(f"required native Mach-O is missing: {relative}")
        receipt_path = root / receipt_relative
        receipt = load_json(
            receipt_path, maximum=MAX_RECEIPT_BYTES, label=receipt_relative
        )
        expected = pointer_digest(receipt, pointer, receipt_relative)
        if expected != state.sha256:
            fail(f"stale build receipt does not bridge unsigned bytes: {relative}")
        result[relative] = {
            "kind": "build-receipt",
            "path": receipt_relative,
            "jsonPointer": "/" + "/".join(pointer),
            "sha256": expected,
        }
    return result


def decode_record_hash(value: str, *, label: str) -> str:
    algorithm, separator, encoded = value.partition("=")
    if separator != "=" or algorithm != "sha256" or not encoded:
        fail(f"Python RECORD uses an unsupported hash: {label}")
    try:
        raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    except (ValueError, TypeError):
        fail(f"Python RECORD contains an invalid hash: {label}")
    if len(raw) != 32:
        fail(f"Python RECORD contains an invalid SHA-256: {label}")
    return raw.hex()


def encoded_record_hash(digest_hex: str) -> str:
    encoded = base64.urlsafe_b64encode(bytes.fromhex(digest_hex)).decode("ascii")
    return f"sha256={encoded.rstrip('=')}"


def inspect_python_records(
    root: Path,
    pre_state: TreeState,
    *,
    source_files: Dict[str, Dict[str, Any]],
) -> Tuple[Dict[str, Dict[str, str]], Dict[str, List[List[str]]]]:
    python_root = root / "da3_mps/python"
    site_roots = sorted(python_root.glob("lib/python*/site-packages"))
    ownership: Dict[str, Dict[str, str]] = {}
    record_rows: Dict[str, List[List[str]]] = {}
    inventoried: Dict[str, str] = {}
    reviewed_non_record_files: Dict[str, str] = {}
    for site_root in site_roots:
        site_relative = site_root.relative_to(root).as_posix()
        reviewed_non_record_files[f"{site_relative}/README.txt"] = (
            "python-build-standalone"
        )
        reviewed_non_record_files[
            f"{site_relative}/antlr4_python3_runtime-4.9.3.dist-info/"
            "licenses/UPSTREAM_LICENSE.txt"
        ] = "python:antlr4-python3-runtime"
        for record in sorted(site_root.glob("*.dist-info/RECORD")):
            record_relative = record.relative_to(root).as_posix()
            if record.stat().st_size > MAX_RECEIPT_BYTES:
                fail(f"Python RECORD exceeds the 1 MiB limit: {record_relative}")
            try:
                rows = list(csv.reader(io.StringIO(record.read_text(encoding="utf-8"))))
            except (OSError, UnicodeDecodeError, csv.Error):
                fail(f"Python RECORD is invalid: {record_relative}")
            if not rows:
                fail(f"Python RECORD is empty: {record_relative}")
            seen: set[str] = set()
            normalized_rows: List[List[str]] = []
            for row in rows:
                if len(row) != 3:
                    fail(
                        f"Python RECORD row does not have exactly three columns: {record_relative}"
                    )
                raw_path, encoded_hash, encoded_size = row
                if (
                    not raw_path
                    or raw_path.startswith("/")
                    or "\\" in raw_path
                    or "\x00" in raw_path
                    or unicodedata.normalize("NFC", raw_path) != raw_path
                    or any(
                        unicodedata.category(character) in {"Cc", "Cs"}
                        for character in raw_path
                    )
                ):
                    fail(
                        f"Python RECORD contains an unsafe member path: {record_relative}"
                    )
                pure_member = PurePosixPath(raw_path)
                if (
                    pure_member.is_absolute()
                    or any(part in {"", "."} for part in pure_member.parts)
                    or pure_member.as_posix() != raw_path
                ):
                    fail(
                        f"Python RECORD contains a non-normalized member: {record_relative}"
                    )
                relative_member = pure_member.as_posix()
                if relative_member in seen:
                    fail(
                        f"Python RECORD contains a duplicate member: {record_relative}"
                    )
                seen.add(relative_member)
                try:
                    target = site_root.joinpath(*pure_member.parts).resolve(
                        strict=False
                    )
                    target.relative_to(python_root.resolve(strict=True))
                except (OSError, ValueError):
                    fail(
                        f"Python RECORD member escapes the Python runtime: {record_relative}"
                    )
                try:
                    target_relative = target.relative_to(root).as_posix()
                except ValueError:
                    fail(
                        f"Python RECORD member escapes site-packages: {record_relative}"
                    )
                target_state = pre_state.files.get(target_relative)
                if target_state is None:
                    if (
                        pure_member.suffix == ".pyc"
                        and not encoded_hash
                        and not encoded_size
                    ):
                        normalized_rows.append(
                            [relative_member, encoded_hash, encoded_size]
                        )
                        continue
                    fail(f"Python RECORD refers to a missing member: {target_relative}")
                if target_relative in inventoried:
                    fail(
                        f"Python RECORD ownership is ambiguous: {target_relative} appears in "
                        f"{inventoried[target_relative]} and {record_relative}"
                    )
                inventoried[target_relative] = record_relative
                is_self = target_relative == record_relative
                if is_self:
                    if encoded_hash or encoded_size:
                        fail(
                            f"Python RECORD self row must have empty hash and size: {record_relative}"
                        )
                else:
                    if not encoded_hash or not encoded_size:
                        fail(
                            f"Python RECORD member lacks hash or size: {target_relative}"
                        )
                    if (
                        decode_record_hash(encoded_hash, label=target_relative)
                        != target_state.sha256
                    ):
                        fail(f"Python RECORD hash mismatch: {target_relative}")
                    try:
                        size = int(encoded_size)
                    except ValueError:
                        fail(f"Python RECORD size is invalid: {target_relative}")
                    if size != target_state.size:
                        fail(f"Python RECORD size mismatch: {target_relative}")
                if target_state.is_macho:
                    ownership[target_relative] = {
                        "kind": "python-record",
                        "path": record_relative,
                        "member": relative_member,
                        "sha256": target_state.sha256,
                    }
                normalized_rows.append([relative_member, encoded_hash, encoded_size])
            record_rows[record_relative] = normalized_rows

    for relative, state in pre_state.files.items():
        if "/site-packages/" not in f"/{relative}":
            continue
        if relative not in inventoried:
            expected_component = reviewed_non_record_files.get(relative)
            source_row = source_files.get(relative)
            if (
                expected_component is not None
                and not state.is_macho
                and source_row is not None
                and source_row.get("component") == expected_component
            ):
                continue
            fail(f"site-packages file has no exact Python RECORD owner: {relative}")
        if state.is_macho and relative not in ownership:
            fail(f"site-packages Mach-O has no Python RECORD provenance: {relative}")
    return ownership, record_rows


def validate_signer_transition(before: TreeState, after: TreeState) -> None:
    if before.directories != after.directories or set(before.files) != set(after.files):
        fail("signer changed the toolchain tree shape")
    before_machos = {path for path, row in before.files.items() if row.is_macho}
    after_machos = {path for path, row in after.files.items() if row.is_macho}
    if before_machos != after_machos:
        fail("signer added, removed, or changed the Mach-O file set")
    for relative, original in before.files.items():
        current = after.files[relative]
        if original.is_macho:
            if original.mode != current.mode:
                fail(f"signer changed Mach-O mode: {relative}")
        elif original != current:
            fail(f"signer changed a non-Mach-O file: {relative}")


def validate_signer_receipt(
    path: Path,
    *,
    before: TreeState,
    after: TreeState,
    expected_pre_tree_digest: str,
    expected_post_tree_digest: str,
    fingerprint: str,
    team_id: str,
) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]], str]:
    receipt_data = read_bounded_regular_file(
        path,
        maximum=MAX_RECEIPT_BYTES,
        label="Developer ID signer receipt",
        require_nonempty=True,
    )
    payload = parse_json_object(receipt_data, label="Developer ID signer receipt")
    if (
        set(payload)
        != {
            "schemaVersion",
            "rootKind",
            "identityFingerprintSHA1",
            "teamID",
            "signedAt",
            "tree",
            "entries",
        }
        or
        payload.get("schemaVersion") != 1
        or payload.get("rootKind") != "tree"
        or payload.get("identityFingerprintSHA1") != fingerprint
        or payload.get("teamID") != team_id
    ):
        fail("Developer ID signer receipt has the wrong schema, identity, or Team ID")
    signed_at = payload.get("signedAt")
    entries = payload.get("entries")
    tree = payload.get("tree")
    if (
        not isinstance(signed_at, str)
        or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", signed_at)
        is None
        or not isinstance(entries, list)
        or not isinstance(tree, dict)
    ):
        fail("Developer ID signer receipt is incomplete")
    if set(tree) != {
        "preSignManifestSHA256",
        "postSignManifestSHA256",
        "preSignFileCount",
        "postSignFileCount",
    }:
        fail("Developer ID signer receipt has an invalid local tree closure")
    for key in ("preSignManifestSHA256", "postSignManifestSHA256"):
        if not isinstance(tree.get(key), str) or not SHA256_PATTERN.fullmatch(
            tree[key]
        ):
            fail("Developer ID signer receipt has an invalid local tree digest")
    if (
        tree["preSignManifestSHA256"] != expected_pre_tree_digest
        or tree["postSignManifestSHA256"] != expected_post_tree_digest
    ):
        fail("Developer ID signer receipt tree digest does not match verified bytes")
    expected_file_count = len(before.files)
    if (
        isinstance(tree.get("preSignFileCount"), bool)
        or not isinstance(tree.get("preSignFileCount"), int)
        or tree.get("preSignFileCount") != expected_file_count
        or tree.get("postSignFileCount") != expected_file_count
    ):
        fail("Developer ID signer receipt has the wrong local tree file count")
    by_path: Dict[str, Dict[str, Any]] = {}
    entry_fields = {
        "kind",
        "relativePath",
        "mode",
        "preSignSHA256",
        "postSignSHA256",
        "identityFingerprintSHA1",
        "teamID",
        "entitlementsSHA256",
        "entitlementsSourceSHA256",
        "embeddedEntitlementsSHA256",
        "signedAt",
        "codesign",
    }
    codesign_fields = {
        "identifier",
        "format",
        "codeDirectory",
        "teamIdentifier",
        "hardenedRuntime",
        "runtimeVersion",
        "timestamp",
        "leafCertificateSHA1",
        "authorities",
    }
    for row in entries:
        if (
            not isinstance(row, dict)
            or set(row) != entry_fields
            or row.get("kind") != "machO"
        ):
            fail("Developer ID signer receipt contains a non-Mach-O entry")
        relative = str(row.get("relativePath") or "")
        if relative in by_path:
            fail(f"Developer ID signer receipt has duplicate Mach-O: {relative}")
        pre = before.files.get(relative)
        post = after.files.get(relative)
        codesign = row.get("codesign")
        authorities = (
            codesign.get("authorities") if isinstance(codesign, dict) else None
        )
        if (
            pre is None
            or post is None
            or not pre.is_macho
            or row.get("preSignSHA256") != pre.sha256
            or row.get("postSignSHA256") != post.sha256
            or row.get("mode") != f"{pre.mode:04o}"
            or row.get("identityFingerprintSHA1") != fingerprint
            or row.get("teamID") != team_id
            or row.get("entitlementsSHA256") is not None
            or row.get("entitlementsSourceSHA256") is not None
            or row.get("embeddedEntitlementsSHA256") is not None
            or row.get("signedAt") != signed_at
            or not isinstance(codesign, dict)
            or set(codesign) != codesign_fields
            or codesign.get("teamIdentifier") != team_id
            or codesign.get("hardenedRuntime") is not True
            or codesign.get("leafCertificateSHA1") != fingerprint
            or not all(
                isinstance(codesign.get(field), str) and codesign[field]
                for field in (
                    "identifier",
                    "format",
                    "codeDirectory",
                    "runtimeVersion",
                    "timestamp",
                )
            )
            or not isinstance(authorities, list)
            or not all(isinstance(authority, str) for authority in authorities)
        ):
            fail(
                f"Developer ID signer receipt does not bridge Mach-O bytes: {relative}"
            )
        by_path[relative] = row
    expected = {relative for relative, row in before.files.items() if row.is_macho}
    if set(by_path) != expected:
        fail("Developer ID signer receipt has a missing or extra Mach-O entry")
    return payload, by_path, sha256_bytes(receipt_data)


def repair_python_records(
    root: Path,
    *,
    before: TreeState,
    signed: TreeState,
    record_rows: Dict[str, List[List[str]]],
) -> List[Dict[str, Any]]:
    repairs: List[Dict[str, Any]] = []
    for record_relative in sorted(record_rows, key=os.fsencode):
        path = root / record_relative
        site_root = path.parent.parent
        changed_members: List[Dict[str, str]] = []
        rows = record_rows[record_relative]
        for row in rows:
            try:
                target = site_root.joinpath(*PurePosixPath(row[0]).parts).resolve(
                    strict=False
                )
                relative = target.relative_to(root.resolve(strict=True)).as_posix()
            except (OSError, ValueError):
                fail(f"Python RECORD member changed during repair: {row[0]}")
            pre = before.files.get(relative)
            post = signed.files.get(relative)
            if pre is None and post is None:
                continue
            if pre is None or post is None:
                fail(f"Python RECORD member changed during repair: {row[0]}")
            if pre.is_macho:
                row[1] = encoded_record_hash(post.sha256)
                row[2] = str(post.size)
                changed_members.append(
                    {
                        "path": relative,
                        "preSignSHA256": pre.sha256,
                        "postSignSHA256": post.sha256,
                    }
                )
        if not changed_members:
            continue
        pre_hash = sha256_file(path)
        stream = io.StringIO(newline="")
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerows(rows)
        data = stream.getvalue().encode("utf-8")
        atomic_write(path, data, maximum=MAX_RECEIPT_BYTES)
        repairs.append(
            {
                "path": record_relative,
                "preRepairSHA256": pre_hash,
                "postRepairSHA256": sha256_file(path),
                "signedMembers": sorted(changed_members, key=lambda row: row["path"]),
            }
        )
    return repairs


def tracked_source_input_bindings(
    root: Path = ROOT, paths: Sequence[str] = SOURCE_BINDING_PATHS
) -> Dict[str, InputBinding]:
    bindings: Dict[str, InputBinding] = {}
    for relative in paths:
        path = root / relative
        descriptor = -1
        try:
            descriptor = os.open(
                path,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            before = os.fstat(descriptor)
            digest = hashlib.sha256()
            while True:
                block = os.read(descriptor, COPY_BUFFER_BYTES)
                if not block:
                    break
                digest.update(block)
            after = os.fstat(descriptor)
            named = path.lstat()
        except OSError:
            fail(f"tracked distribution-signing input is missing: {relative}")
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        if (
            stat_binding_identity(before) != stat_binding_identity(after)
            or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)
            or not stat.S_ISREG(after.st_mode)
            or stat.S_ISLNK(after.st_mode)
            or after.st_nlink != 1
            or after.st_uid != os.geteuid()
            or after.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or after.st_size <= 0
            or after.st_size > MAX_SOURCE_INPUT_BYTES
        ):
            fail(f"tracked distribution-signing input is unsafe: {relative}")
        bindings[relative] = InputBinding(
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            digest.hexdigest(),
        )
    return bindings


def readonly_git_environment() -> Dict[str, str]:
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/var/empty",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }


def require_tracked_sources_match_commit(
    expected: Dict[str, InputBinding],
    source_commit: str,
    *,
    root: Path = ROOT,
) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        fail("authenticated source commit is not a full Git commit")
    environment = readonly_git_environment()
    for relative in sorted(expected, key=os.fsencode):
        if (
            PurePosixPath(relative).is_absolute()
            or ".." in PurePosixPath(relative).parts
        ):
            fail("tracked source path is not canonical")
        try:
            blob = subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(root),
                    "cat-file",
                    "blob",
                    f"{source_commit}:{relative}",
                ],
                check=False,
                capture_output=True,
                timeout=30,
                env=environment,
            )
            tree = subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(root),
                    "ls-tree",
                    "-z",
                    source_commit,
                    "--",
                    relative,
                ],
                check=False,
                capture_output=True,
                timeout=30,
                env=environment,
            )
        except (OSError, subprocess.TimeoutExpired):
            fail("unable to authenticate tracked sources against the Git commit")
        binding = expected[relative]
        if (
            blob.returncode != 0
            or tree.returncode != 0
            or len(blob.stdout) != binding.size
            or hashlib.sha256(blob.stdout).hexdigest() != binding.sha256
        ):
            fail(f"tracked source differs from authenticated Git commit: {relative}")
        tree_rows = tree.stdout.split(b"\0")
        if len(tree_rows) != 2 or tree_rows[1] != b"" or b"\t" not in tree_rows[0]:
            fail(f"tracked source is absent from authenticated Git commit: {relative}")
        metadata, path_bytes = tree_rows[0].split(b"\t", 1)
        fields = metadata.split(b" ")
        expected_path = relative.encode("utf-8")
        if (
            len(fields) != 3
            or fields[1] != b"blob"
            or fields[0] not in {b"100644", b"100755"}
            or path_bytes != expected_path
            or bool(binding.mode & 0o111) != (fields[0] == b"100755")
        ):
            fail(f"tracked source mode differs from authenticated Git commit: {relative}")


def require_tracked_source_inputs_unchanged(
    expected: Dict[str, InputBinding], *, root: Path = ROOT
) -> None:
    current = tracked_source_input_bindings(root, tuple(expected))
    if current != expected:
        fail("tracked distribution-signing inputs changed during finalization")


def snapshot_tracked_source_tree(
    destination: Path,
    *,
    source_root: Path,
    expected: Dict[str, InputBinding],
) -> Dict[str, InputBinding]:
    destination.mkdir(mode=0o700)
    for relative in sorted(expected, key=os.fsencode):
        source = source_root / relative
        target = destination.joinpath(*PurePosixPath(relative).parts)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        snapshot = snapshot_authenticated_input(
            source,
            expected[relative],
            label=f"tracked source input {relative}",
        )
        descriptor = -1
        try:
            descriptor = os.open(
                target,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                expected[relative].mode,
            )
            with os.fdopen(descriptor, "wb", closefd=True) as output:
                descriptor = -1
                while True:
                    block = snapshot.read(COPY_BUFFER_BYTES)
                    if not block:
                        break
                    output.write(block)
                output.flush()
                os.fchmod(output.fileno(), expected[relative].mode)
                os.fsync(output.fileno())
        except OSError:
            fail(f"tracked source input could not be snapshotted: {relative}")
        finally:
            snapshot.close()
            if descriptor >= 0:
                os.close(descriptor)
    snapshotted = tracked_source_input_bindings(destination, tuple(expected))
    for relative, binding in snapshotted.items():
        original = expected[relative]
        if (
            binding.mode != original.mode
            or binding.size != original.size
            or binding.sha256 != original.sha256
        ):
            fail(f"tracked source snapshot differs from reviewed bytes: {relative}")
    return snapshotted


def source_bindings(
    tracked_inputs: Dict[str, InputBinding] | None = None,
    *,
    expected_commit: str | None = None,
) -> Dict[str, Any]:
    tracked = tracked_inputs or tracked_source_input_bindings()
    hashes = [
        {"path": relative, "sha256": tracked[relative].sha256}
        for relative in SOURCE_BINDING_PATHS
    ]
    try:
        revision = subprocess.run(
            ["/usr/bin/git", "-C", str(ROOT), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
            env=readonly_git_environment(),
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail("unable to bind distribution signing to the repository revision")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        fail("repository revision is not a full Git commit")
    if expected_commit is not None and revision != expected_commit:
        fail("repository revision differs from authenticated source commit")
    if expected_commit is not None:
        require_tracked_sources_match_commit(
            tracked,
            expected_commit,
            root=ROOT,
        )
    return {"sourceCommit": revision, "sourceInputs": hashes}


def run_checked(
    command: List[str],
    label: str,
    *,
    timeout: int = 3600,
    pass_fds: Sequence[int] = (),
) -> None:
    inherited = os.environ
    environment = {
        name: inherited[name]
        for name in (
            "HOME",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
        )
        if name in inherited
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=environment,
            pass_fds=tuple(pass_fds),
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        fail(f"{label} could not run")
    if result.returncode != 0:
        detail = (
            result.stderr.strip().splitlines()[-1]
            if result.stderr.strip()
            else "no diagnostic"
        )
        fail(f"{label} failed: {detail[:500]}")


def run_checked_with_source_guard(
    command: List[str],
    label: str,
    *,
    tracked_inputs: Dict[str, InputBinding] | None,
    source_root: Path,
    reviewed_script: Path,
    timeout: int = 3600,
) -> None:
    try:
        relative = reviewed_script.relative_to(source_root).as_posix()
    except ValueError:
        fail(f"{label} script is outside the reviewed source snapshot")
    if tracked_inputs is None:
        tracked_inputs = tracked_source_input_bindings(source_root, (relative,))
    require_tracked_source_inputs_unchanged(tracked_inputs, root=source_root)
    expected = tracked_inputs.get(relative) if tracked_inputs is not None else None
    if expected is None:
        fail(f"{label} script is not in the reviewed source closure")
    snapshot: BinaryIO | None = None
    try:
        snapshot = snapshot_authenticated_input(
            reviewed_script,
            expected,
            label=f"{label} reviewed script",
        )
        descriptor = snapshot.fileno()
        if command[:2] == ["/usr/bin/python3", "-I"] and command[2] == str(
            reviewed_script
        ):
            bootstrap = (
                "import os,sys\n"
                "fd=int(sys.argv[1]); filename=sys.argv[2]; argv=sys.argv[3:]\n"
                "chunks=[]\n"
                "while True:\n"
                " block=os.read(fd,1048576)\n"
                " if not block: break\n"
                " chunks.append(block)\n"
                "sys.argv=[filename,*argv]\n"
                "scope={'__name__':'__main__','__file__':filename,'__package__':None}\n"
                "exec(compile(b''.join(chunks),filename,'exec'),scope)\n"
            )
            reviewed_command = [
                "/usr/bin/python3",
                "-I",
                "-c",
                bootstrap,
                str(descriptor),
                str(reviewed_script),
                *command[3:],
            ]
        elif command[:1] == ["/bin/bash"] and command[1] == str(reviewed_script):
            reviewed_command = [
                "/bin/bash",
                f"/dev/fd/{descriptor}",
                *command[2:],
            ]
        else:
            fail(f"{label} command does not execute its reviewed script directly")
        run_checked(
            reviewed_command,
            label,
            timeout=timeout,
            pass_fds=(descriptor,),
        )
    finally:
        if snapshot is not None:
            snapshot.close()
        require_tracked_source_inputs_unchanged(tracked_inputs, root=source_root)


def production_signer(
    root: Path,
    fingerprint: str,
    team_id: str,
    receipt: Path,
    *,
    tracked_inputs: Dict[str, InputBinding] | None = None,
    source_root: Path = ROOT,
) -> None:
    run_checked_with_source_guard(
        [
            "/usr/bin/python3",
            "-I",
            str(source_root / "scripts/release/sign_macos_distribution.py"),
            "--root",
            str(root),
            "--kind",
            "tree",
            "--identity-fingerprint",
            fingerprint,
            "--team-id",
            team_id,
            "--receipt",
            str(receipt),
        ],
        "Developer ID toolchain signer",
        tracked_inputs=tracked_inputs,
        source_root=source_root,
        reviewed_script=source_root / "scripts/release/sign_macos_distribution.py",
    )


def production_supply_chain(
    root: Path,
    version: str,
    receipt: Path,
    *,
    tracked_inputs: Dict[str, InputBinding] | None = None,
    source_root: Path = ROOT,
    source_commit: str | None = None,
) -> None:
    command = [
        "/usr/bin/python3",
        "-I",
        str(source_root / "scripts/toolchain/generate_supply_chain_manifest.py"),
        "--toolchain-root",
        str(root),
        "--version",
        version,
        "--distribution-signing-receipt",
        str(receipt),
    ]
    if source_commit is not None:
        command.extend(
            [
                "--reviewed-source-root",
                str(source_root),
                "--reviewed-source-commit",
                source_commit,
            ]
        )
    run_checked_with_source_guard(
        command,
        "signed supply-chain generator",
        tracked_inputs=tracked_inputs,
        source_root=source_root,
        reviewed_script=(
            source_root / "scripts/toolchain/generate_supply_chain_manifest.py"
        ),
    )


def production_archive(
    root: Path,
    output: Path,
    paths: Sequence[str],
    *,
    tracked_inputs: Dict[str, InputBinding] | None = None,
    source_root: Path = ROOT,
) -> None:
    command = [
        "/usr/bin/python3",
        "-I",
        str(source_root / "scripts/toolchain/create_reproducible_zip.py"),
        "--root",
        str(root),
        "--output",
        str(output),
    ]
    for relative in paths:
        command.extend(["--path", relative])
    run_checked_with_source_guard(
        command,
        "reproducible signed toolchain archiver",
        tracked_inputs=tracked_inputs,
        source_root=source_root,
        reviewed_script=source_root / "scripts/toolchain/create_reproducible_zip.py",
    )


def validate_colmap_tracked_inputs(root: Path, *, source_root: Path = ROOT) -> None:
    receipt = load_json(
        root / "provenance/colmap.json",
        maximum=MAX_RECEIPT_BYTES,
        label="COLMAP build receipt",
    )
    build_inputs = receipt.get("build_inputs")
    if not isinstance(build_inputs, dict):
        fail("COLMAP build receipt has no source-bound build inputs")
    direct = {
        "builder_sha256": "scripts/toolchain/build_colmap.sh",
        "builder_implementation_sha256": "scripts/toolchain/build_colmap_impl.sh",
        "build_supervisor_sha256": "scripts/toolchain/secure_colmap_build.py",
        "promoter_sha256": "scripts/toolchain/atomic_swap_install.py",
        "patch_sha256": "scripts/toolchain/patches/colmap-4.1.1-easysplat.patch",
    }
    for field, relative in direct.items():
        if build_inputs.get(field) != sha256_file(source_root / relative):
            fail(f"COLMAP build receipt is not bound to tracked source input: {field}")
    overlays = build_inputs.get("overlay_sha256")
    expected_overlays = {
        "local_vocab_retriever.cc": sha256_file(
            source_root / "Tools/NativeColmap/local_vocab_retriever.cc"
        ),
        "local_vocab_retriever.h": sha256_file(
            source_root / "Tools/NativeColmap/local_vocab_retriever.h"
        ),
    }
    if overlays != expected_overlays:
        fail("COLMAP build receipt is not bound to the tracked overlay sources")


def production_unsigned_validator(
    root: Path,
    *,
    tracked_inputs: Dict[str, InputBinding] | None = None,
    source_root: Path = ROOT,
) -> None:
    if tracked_inputs is not None:
        require_tracked_source_inputs_unchanged(tracked_inputs, root=source_root)
    validate_colmap_tracked_inputs(root, source_root=source_root)
    if tracked_inputs is not None:
        require_tracked_source_inputs_unchanged(tracked_inputs, root=source_root)
    run_checked_with_source_guard(
        [
            "/bin/bash",
            str(source_root / "scripts/toolchain/validate_native_msplat.sh"),
            "--packaged-static",
            str(root),
        ],
        "unsigned native msplat validation",
        tracked_inputs=tracked_inputs,
        source_root=source_root,
        reviewed_script=source_root / "scripts/toolchain/validate_native_msplat.sh",
    )
    run_checked_with_source_guard(
        [
            "/usr/bin/python3",
            "-I",
            str(source_root / "scripts/toolchain/validate_da3_payload.py"),
            "--root",
            str(root / "da3_mps"),
        ],
        "unsigned DA3 payload validation",
        tracked_inputs=tracked_inputs,
        source_root=source_root,
        reviewed_script=source_root / "scripts/toolchain/validate_da3_payload.py",
    )


def run_unsigned_validator(
    runner: UnsignedValidator,
    root: Path,
    *,
    tracked_inputs: Dict[str, InputBinding] | None,
    source_root: Path,
) -> None:
    if runner is production_unsigned_validator:
        production_unsigned_validator(
            root,
            tracked_inputs=tracked_inputs,
            source_root=source_root,
        )
    else:
        runner(root)


def run_supply_chain_generator(
    runner: SupplyChainRunner,
    root: Path,
    version: str,
    receipt: Path,
    *,
    tracked_inputs: Dict[str, InputBinding] | None,
    source_root: Path,
    source_commit: str,
) -> None:
    if runner is production_supply_chain:
        production_supply_chain(
            root,
            version,
            receipt,
            tracked_inputs=tracked_inputs,
            source_root=source_root,
            source_commit=source_commit,
        )
    else:
        runner(root, version, receipt)


def validate_final_supply_chain(root: Path, version: str) -> str:
    path = root / SUPPLY_CHAIN_PATH
    payload = load_json(
        path, maximum=MAX_SUPPLY_CHAIN_BYTES, label="signed supply-chain manifest"
    )
    if payload.get("schemaVersion") != 1 or payload.get("toolchainVersion") != version:
        fail("signed supply-chain manifest has the wrong schema or version")
    state = scan_tree(root)
    rows = payload.get("files")
    components = payload.get("components")
    if not isinstance(rows, list) or not isinstance(components, list):
        fail("signed supply-chain manifest has invalid rows")
    by_path: Dict[str, Dict[str, Any]] = {}
    grouped: Dict[str, List[str]] = {}
    for row in rows:
        if not isinstance(row, dict):
            fail("signed supply-chain manifest contains a non-object file row")
        relative = str(row.get("path") or "")
        file_state = state.files.get(relative)
        if (
            relative in by_path
            or file_state is None
            or row.get("sha256") != file_state.sha256
            or row.get("size") != file_state.size
            or row.get("kind") != ("mach-o" if file_state.is_macho else "file")
            or not isinstance(row.get("component"), str)
        ):
            fail(
                f"signed supply-chain manifest contains a stale or duplicate row: {relative}"
            )
        by_path[relative] = row
        grouped.setdefault(str(row["component"]), []).append(relative)
    if set(by_path) != set(state.files) - {SUPPLY_CHAIN_PATH}:
        fail("signed supply-chain manifest does not exactly inventory final files")
    by_component: Dict[str, Dict[str, Any]] = {}
    for component in components:
        if not isinstance(component, dict) or not isinstance(component.get("id"), str):
            fail("signed supply-chain manifest contains an invalid component")
        component_id = component["id"]
        if component_id in by_component or sorted(component.get("files", [])) != sorted(
            grouped.get(component_id, [])
        ):
            fail(f"signed supply-chain component ownership is stale: {component_id}")
        by_component[component_id] = component
    if set(by_component) != set(grouped):
        fail("signed supply-chain manifest has missing or extra component owners")
    signing = by_component.get("easysplat-distribution-signing")
    if signing is None or signing.get("files") != [INTERNAL_RECEIPT_PATH]:
        fail("signed supply-chain manifest lacks the distribution-signing component")
    return sha256_file(path)


def archive_partitions(paths: Sequence[str]) -> Dict[str, List[str]]:
    small = sorted(
        path for path in paths if path.startswith("da3_mps/models/DA3-SMALL/")
    )
    base = sorted(
        path
        for path in paths
        if path.startswith("da3_mps/")
        and not path.startswith("da3_mps/models/DA3-SMALL/")
    )
    core = sorted(path for path in paths if not path.startswith("da3_mps/"))
    if not core or not base or not small:
        fail("final signed toolchain does not have all three component partitions")
    return {"core": core, "base": base, "small": small}


def verify_output_archive(
    path: Path, expected: Sequence[str], *, signed_tree: TreeState
) -> Tuple[Dict[str, Any], InputBinding]:
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or before.st_size <= 0
            or before.st_size >= 2 * 1024 * 1024 * 1024
        ):
            fail(f"final release archive is unsafe or exceeds 2 GiB: {path.name}")
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            with zipfile.ZipFile(stream, "r") as archive:
                infos = archive.infolist()
                names = [info.filename for info in infos]
                if names != sorted(
                    expected, key=lambda value: value.encode("utf-8")
                ):
                    fail(
                        f"final archive has the wrong deterministic file set: {path.name}"
                    )
                for info in infos:
                    relative = validate_archive_name(info.filename)
                    expected_state = signed_tree.files.get(relative)
                    if (
                        expected_state is None
                        or info.is_dir()
                        or info.flag_bits & 0x1
                        or info.compress_type
                        not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
                        or info.extra
                        or info.comment
                        or archive_member_mode(info) != expected_state.mode
                        or info.file_size != expected_state.size
                    ):
                        fail(
                            "final archive payload does not match the signed tree: "
                            f"{relative}"
                        )
                    member_digest = hashlib.sha256()
                    size = 0
                    with archive.open(info, "r") as source:
                        for block in iter(
                            lambda: source.read(COPY_BUFFER_BYTES), b""
                        ):
                            member_digest.update(block)
                            size += len(block)
                    if (
                        size != expected_state.size
                        or member_digest.hexdigest() != expected_state.sha256
                    ):
                        fail(
                            "final archive payload does not match the signed tree: "
                            f"{relative}"
                        )
        os.lseek(descriptor, 0, os.SEEK_SET)
        archive_digest = hashlib.sha256()
        size = 0
        while True:
            block = os.read(descriptor, COPY_BUFFER_BYTES)
            if not block:
                break
            archive_digest.update(block)
            size += len(block)
        after = os.fstat(descriptor)
        named = path.lstat()
    except (OSError, zipfile.BadZipFile, RuntimeError):
        fail(f"final archive cannot be verified: {path.name}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        stat_binding_identity(before) != stat_binding_identity(after)
        or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino)
        or size != after.st_size
    ):
        fail(f"final archive changed during verification: {path.name}")
    binding = InputBinding(
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        archive_digest.hexdigest(),
    )
    return (
        {"name": path.name, "sha256": binding.sha256, "size": binding.size},
        binding,
    )


def finalize_signed_toolchain(
    *,
    version: str,
    core_zip: Path,
    base_zip: Path,
    small_zip: Path,
    unsigned_release_request: Path,
    builder_attested_unsigned_request_sha256: str,
    builder_artifact_evidence: BuilderArtifactEvidence | None = None,
    output_directory: Path,
    identity_fingerprint: str,
    team_id: str,
    receipt_path: Path,
    signer_runner: SignerRunner = production_signer,
    supply_chain_runner: SupplyChainRunner = production_supply_chain,
    archive_runner: ArchiveRunner = production_archive,
    unsigned_validator: UnsignedValidator = production_unsigned_validator,
    artifact_authority_verifier: ArtifactAuthorityVerifier = (
        production_github_artifact_authority
    ),
) -> Dict[str, Any]:
    if not SEMVER_PATTERN.fullmatch(version):
        fail("toolchain version must be valid semantic versioning")
    if not FINGERPRINT_PATTERN.fullmatch(identity_fingerprint):
        fail("Developer ID fingerprint must be exactly 40 hexadecimal characters")
    fingerprint = identity_fingerprint.upper()
    if not TEAM_ID_PATTERN.fullmatch(team_id):
        fail("Team ID must be exactly 10 uppercase letters or digits")

    archives = {"core": core_zip, "base": base_zip, "small": small_zip}
    for archive in archives.values():
        if (
            validate_archive_name(archive.name) != archive.name
            or archive.suffix != ".zip"
        ):
            fail("source component archive must have a safe .zip filename")
    bindings = {component: input_binding(path) for component, path in archives.items()}
    identities = {(row.device, row.inode) for row in bindings.values()}
    if len(identities) != 3:
        fail("source component archives must be three distinct non-hardlinked files")

    uses_production_sources = any(
        runner is production
        for runner, production in (
            (signer_runner, production_signer),
            (supply_chain_runner, production_supply_chain),
            (archive_runner, production_archive),
            (unsigned_validator, production_unsigned_validator),
        )
    )
    tracked_inputs: Dict[str, InputBinding] | None = None
    if uses_production_sources:
        if (
            builder_artifact_evidence is None
            or not re.fullmatch(
                r"[0-9a-f]{40}", builder_artifact_evidence.source_commit
            )
        ):
            fail("authenticated source commit is required by production finalization")
        tracked_inputs = tracked_source_input_bindings()
    source_binding = source_bindings(
        tracked_inputs,
        expected_commit=(
            builder_artifact_evidence.source_commit
            if uses_production_sources and builder_artifact_evidence is not None
            else None
        ),
    )
    request_binding = input_binding(unsigned_release_request)
    if request_binding.size > MAX_RELEASE_REQUEST_BYTES:
        fail("authenticated release request exceeds the 8 MiB limit")
    if not SHA256_PATTERN.fullmatch(
        builder_attested_unsigned_request_sha256
    ):
        fail("release request SHA-256 authority evidence is malformed")
    if (request_binding.device, request_binding.inode) in identities:
        fail("release request and component archives must be distinct files")

    normalized_absolute(output_directory.parent, must_exist=True, label="output parent")
    output_ancestry = snapshot_directory_ancestry(output_directory.parent)
    if output_directory.exists() or output_directory.is_symlink():
        fail("output directory must not already exist")
    if not receipt_path.is_absolute() or receipt_path.parent != output_directory:
        fail(
            "external receipt path must be a direct child of the atomic output directory"
        )
    validate_archive_name(receipt_path.name)
    reserved_output_names = {
        f"toolchain-macos-arm64-{version}-core.zip",
        f"toolchain-geometry-da3-base-{version}.zip",
        f"toolchain-geometry-da3-small-{version}.zip",
    }
    receipt_key = unicodedata.normalize("NFC", receipt_path.name).casefold()
    reserved_output_keys = {
        unicodedata.normalize("NFC", name).casefold() for name in reserved_output_names
    }
    if receipt_key in reserved_output_keys:
        fail("external receipt filename collides with a finalized component archive")
    for archive in archives.values():
        if (
            output_directory == archive.parent
            or archive.parent in output_directory.parents
        ):
            fail("output directory must not be inside a source archive directory")
    if (
        output_directory == unsigned_release_request.parent
        or unsigned_release_request.parent in output_directory.parents
    ):
        fail("output directory must not be inside the release-request directory")
    temporary_root = Path(
        tempfile.mkdtemp(
            prefix=".easysplat-signed-toolchain-", dir=output_directory.parent
        )
    )
    temporary_root_status = temporary_root.lstat()
    temporary_root_identity = PathIdentity(
        temporary_root_status.st_dev,
        temporary_root_status.st_ino,
        stat.S_IMODE(temporary_root_status.st_mode),
    )
    if (
        not stat.S_ISDIR(temporary_root_status.st_mode)
        or temporary_root_status.st_uid != os.geteuid()
        or temporary_root_identity.mode != 0o700
    ):
        fail("private finalization directory is unsafe")
    input_snapshots: List[BinaryIO] = []
    try:
        archive_snapshots: Dict[str, BinaryIO] = {}
        for component in ("core", "base", "small"):
            snapshot = snapshot_authenticated_input(
                archives[component],
                bindings[component],
                label=f"{component} source archive",
            )
            input_snapshots.append(snapshot)
            archive_snapshots[component] = snapshot
        request_snapshot = snapshot_authenticated_input(
            unsigned_release_request,
            request_binding,
            label="authenticated release request",
        )
        input_snapshots.append(request_snapshot)
        runtime_source_root = ROOT
        runtime_tracked_inputs = tracked_inputs
        if tracked_inputs is not None:
            runtime_source_root = temporary_root / "reviewed-source"
            runtime_tracked_inputs = snapshot_tracked_source_tree(
                runtime_source_root,
                source_root=ROOT,
                expected=tracked_inputs,
            )
        request_data = request_snapshot.read(MAX_RELEASE_REQUEST_BYTES + 1)
        if len(request_data) != request_binding.size:
            fail("authenticated release request snapshot is incomplete")
        requested_components, release_request = validate_unsigned_release_request(
            request_data,
            binding=request_binding,
            expected_sha256=builder_attested_unsigned_request_sha256,
            version=version,
            source_commit=source_binding["sourceCommit"],
            archives=archives,
            bindings=bindings,
        )
        if (
            builder_artifact_evidence is None
            or builder_artifact_evidence.source_commit
            != source_binding["sourceCommit"]
            or builder_artifact_evidence.request_sha256
            != builder_attested_unsigned_request_sha256
        ):
            fail("builder artifact authority evidence is missing or inconsistent")
        artifact_authority_verifier(builder_artifact_evidence, version)
        unsigned_component_archives = [
            {
                "component": component,
                "name": PurePosixPath(requested_components[component]["url"]).name,
                "sha256": requested_components[component]["sha256"],
                "size": requested_components[component]["sizeBytes"],
            }
            for component in ("core", "base", "small")
        ]
        tree = temporary_root / "tree"
        artifacts = temporary_root / "artifacts"
        tree.mkdir(mode=0o755)
        artifacts.mkdir(mode=0o700)
        global_keys: Dict[str, str] = {}
        component_paths: Dict[str, List[str]] = {}
        expanded_total = 0
        for component in ("core", "base", "small"):
            paths, expanded = safe_extract_archive(
                archive_snapshots[component],
                tree,
                component=component,
                global_keys=global_keys,
            )
            component_paths[component] = paths
            expanded_total += expanded
            if expanded_total > MAX_ALL_EXPANDED_BYTES:
                fail("merged release ZIPs exceed the expanded size limit")
        for required in (
            SUPPLY_CHAIN_PATH,
            "bin/colmap",
            "bin/easysplat-train",
            "lib/libomp.dylib",
            "da3_mps/models/DA3-BASE/model.safetensors",
            "da3_mps/models/DA3-SMALL/model.safetensors",
        ):
            if required not in global_keys.values():
                fail(f"release component closure is missing: {required}")

        unsigned_state = scan_tree(tree)
        validate_requested_expanded_closure(
            requested_components, component_paths, unsigned_state
        )
        unsigned_files, _unsigned_components, unsigned_supply_hash = (
            validate_unsigned_supply_chain(
                tree,
                version,
                unsigned_state,
                source_commit=source_binding["sourceCommit"],
            )
        )
        build_provenance = native_build_provenance(tree, unsigned_state)
        record_provenance, record_rows = inspect_python_records(
            tree, unsigned_state, source_files=unsigned_files
        )
        for relative, state in unsigned_state.files.items():
            if state.is_macho and unsigned_files[relative].get("kind") != "mach-o":
                fail(
                    f"unsigned Mach-O lacks unsigned supply-chain byte provenance: {relative}"
                )
        run_unsigned_validator(
            unsigned_validator,
            tree,
            tracked_inputs=runtime_tracked_inputs,
            source_root=runtime_source_root,
        )

        raw_signer_receipt = temporary_root / "developer-id-signer.json"
        pre_sign_tree_digest = signer_tree_manifest_digest(tree)
        if signer_runner is production_signer:
            production_signer(
                tree,
                fingerprint,
                team_id,
                raw_signer_receipt,
                tracked_inputs=runtime_tracked_inputs,
                source_root=runtime_source_root,
            )
        else:
            signer_runner(tree, fingerprint, team_id, raw_signer_receipt)
        signed_state = scan_tree(tree)
        post_sign_tree_digest = signer_tree_manifest_digest(tree)
        validate_signer_transition(unsigned_state, signed_state)
        signer_payload, signer_entries, _signer_receipt_hash = validate_signer_receipt(
            raw_signer_receipt,
            before=unsigned_state,
            after=signed_state,
            expected_pre_tree_digest=pre_sign_tree_digest,
            expected_post_tree_digest=post_sign_tree_digest,
            fingerprint=fingerprint,
            team_id=team_id,
        )
        repairs = repair_python_records(
            tree,
            before=unsigned_state,
            signed=signed_state,
            record_rows=record_rows,
        )

        macho_rows: List[Dict[str, Any]] = []
        for relative in sorted(signer_entries, key=os.fsencode):
            pre = unsigned_state.files[relative]
            post = signed_state.files[relative]
            provenance: List[Dict[str, str]] = [
                {
                    "kind": "supply-chain",
                    "path": SUPPLY_CHAIN_PATH,
                    "component": str(unsigned_files[relative]["component"]),
                    "sha256": pre.sha256,
                }
            ]
            if relative in build_provenance:
                provenance.append(build_provenance[relative])
            if relative in record_provenance:
                provenance.append(record_provenance[relative])
            macho_rows.append(
                {
                    "path": relative,
                    "component": unsigned_files[relative]["component"],
                    "preSignSHA256": pre.sha256,
                    "postSignSHA256": post.sha256,
                    "preSignProvenance": provenance,
                    "codesign": signer_entries[relative]["codesign"],
                }
            )

        internal_payload: Dict[str, Any] = {
            "schemaVersion": 1,
            "kind": "easysplat-distribution-signing",
            "toolchainVersion": version,
            "identityFingerprintSHA1": fingerprint,
            "teamID": team_id,
            "signedAt": signer_payload["signedAt"],
            "sourceCommit": source_binding["sourceCommit"],
            "sourceInputs": source_binding["sourceInputs"],
            "unsignedComponentArchives": unsigned_component_archives,
            "builderAttestedUnsignedRequestSHA256": request_binding.sha256,
            "builderAttestedUnsignedManifestSHA256": release_request["manifestSHA256"],
            "unsignedSupplyChainSHA256": unsigned_supply_hash,
            "machOFiles": macho_rows,
            "recordRepairs": repairs,
        }
        internal_path = tree / INTERNAL_RECEIPT_PATH
        internal_path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(
            internal_path, canonical_json(internal_payload), maximum=MAX_RECEIPT_BYTES
        )

        before_generator = scan_tree(tree)
        run_supply_chain_generator(
            supply_chain_runner,
            tree,
            version,
            internal_path,
            tracked_inputs=runtime_tracked_inputs,
            source_root=runtime_source_root,
            source_commit=source_binding["sourceCommit"],
        )
        after_generator = scan_tree(tree)
        allowed_changes = {SUPPLY_CHAIN_PATH}
        for relative, original in before_generator.files.items():
            if (
                relative not in allowed_changes
                and after_generator.files.get(relative) != original
            ):
                fail(f"supply-chain regeneration changed unrelated bytes: {relative}")
        if set(before_generator.files) != set(after_generator.files):
            fail("supply-chain regeneration added or removed unexpected files")
        supply_chain_hash = validate_final_supply_chain(tree, version)

        final_tree = scan_tree(tree)
        final_paths = sorted(final_tree.files, key=os.fsencode)
        partitions = archive_partitions(final_paths)
        archive_names = {
            "core": f"toolchain-macos-arm64-{version}-core.zip",
            "base": f"toolchain-geometry-da3-base-{version}.zip",
            "small": f"toolchain-geometry-da3-small-{version}.zip",
        }
        final_archives: List[Dict[str, Any]] = []
        final_archive_bindings: Dict[str, InputBinding] = {}
        for component in ("core", "base", "small"):
            output = artifacts / archive_names[component]
            if archive_runner is production_archive:
                production_archive(
                    tree,
                    output,
                    ARCHIVE_SELECTIONS[component],
                    tracked_inputs=runtime_tracked_inputs,
                    source_root=runtime_source_root,
                )
            else:
                archive_runner(tree, output, ARCHIVE_SELECTIONS[component])
            if scan_tree(tree) != final_tree:
                fail("signed tree changed during final archive creation")
            row, archive_binding = verify_output_archive(
                output, partitions[component], signed_tree=final_tree
            )
            row["component"] = component
            final_archives.append(row)
            final_archive_bindings[component] = archive_binding

        for component, path in archives.items():
            require_input_unchanged(path, bindings[component])
        require_input_unchanged(
            unsigned_release_request,
            request_binding,
            label="authenticated release request",
        )

        external_payload: Dict[str, Any] = {
            "schemaVersion": 1,
            "kind": "easysplat-signed-toolchain-finalization",
            "toolchainVersion": version,
            "identityFingerprintSHA1": fingerprint,
            "teamID": team_id,
            "signedAt": signer_payload["signedAt"],
            "sourceCommit": source_binding["sourceCommit"],
            "sourceInputs": source_binding["sourceInputs"],
            "unsignedComponentArchives": unsigned_component_archives,
            "builderAttestedUnsignedReleaseRequest": {
                "name": unsigned_release_request.name,
                "sha256": request_binding.sha256,
                "manifestSHA256": release_request["manifestSHA256"],
            },
            "builderArtifactAuthority": {
                "repository": builder_artifact_evidence.repository,
                "workflowRunID": builder_artifact_evidence.workflow_run_id,
                "sourceCommit": builder_artifact_evidence.source_commit,
                "unsignedArtifactID": (
                    builder_artifact_evidence.unsigned_artifact_id
                ),
                "unsignedArtifactDigest": (
                    builder_artifact_evidence.unsigned_artifact_digest
                ),
                "requestArtifactID": builder_artifact_evidence.request_artifact_id,
                "requestArtifactDigest": (
                    builder_artifact_evidence.request_artifact_digest
                ),
            },
            "distributionSigningReceipt": {
                "path": INTERNAL_RECEIPT_PATH,
                "sha256": sha256_file(internal_path),
            },
            "supplyChain": {"path": SUPPLY_CHAIN_PATH, "sha256": supply_chain_hash},
            "finalArchives": final_archives,
        }
        staged_receipt = artifacts / receipt_path.name
        atomic_write(
            staged_receipt, canonical_json(external_payload), maximum=MAX_RECEIPT_BYTES
        )
        receipt_binding = input_binding(staged_receipt)
        by_component = {row["component"]: row for row in final_archives}
        for component in ("core", "base", "small"):
            verified, verified_binding = verify_output_archive(
                artifacts / archive_names[component],
                partitions[component],
                signed_tree=final_tree,
            )
            expected = by_component[component]
            if any(
                verified[field] != expected[field]
                for field in ("name", "sha256", "size")
            ):
                fail(f"final {component} archive changed after receipt generation")
            if verified_binding != final_archive_bindings[component]:
                fail(f"final {component} archive identity changed after verification")
        for component, path in archives.items():
            require_input_unchanged(path, bindings[component])
        require_input_unchanged(
            unsigned_release_request,
            request_binding,
            label="authenticated release request",
        )
        if tracked_inputs is not None:
            require_tracked_source_inputs_unchanged(tracked_inputs)
        artifacts_descriptor = -1
        temporary_descriptor = -1
        parent_descriptor = -1
        published_descriptor = -1
        promoted = False
        expected_output_names = [
            archive_names[component] for component in ("core", "base", "small")
        ] + [staged_receipt.name]
        try:
            directory_flags = (
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            artifacts_descriptor = os.open(artifacts, directory_flags)
            artifacts_status = os.fstat(artifacts_descriptor)
            if (
                not stat.S_ISDIR(artifacts_status.st_mode)
                or artifacts_status.st_uid != os.geteuid()
                or stat.S_IMODE(artifacts_status.st_mode) != 0o700
            ):
                fail("verified artifact directory is unsafe")
            for component in ("core", "base", "small"):
                require_bound_file_at(
                    artifacts_descriptor,
                    archive_names[component],
                    final_archive_bindings[component],
                    label=f"final {component} archive",
                )
            require_bound_file_at(
                artifacts_descriptor,
                staged_receipt.name,
                receipt_binding,
                label="external finalization receipt",
            )
            require_exact_directory_entries(
                artifacts_descriptor,
                expected_output_names,
                label="verified artifact directory",
            )
            os.fsync(artifacts_descriptor)
            temporary_descriptor = os.open(temporary_root, directory_flags)
            parent_descriptor = os.open(output_directory.parent, directory_flags)
            opened_temporary = os.fstat(temporary_descriptor)
            opened_parent = os.fstat(parent_descriptor)
            expected_parent = output_ancestry[output_directory.parent]
            if (
                opened_temporary.st_dev != temporary_root_identity.device
                or opened_temporary.st_ino != temporary_root_identity.inode
                or stat.S_IMODE(opened_temporary.st_mode)
                != temporary_root_identity.mode
                or opened_temporary.st_uid != os.geteuid()
            ):
                fail("private finalization directory identity changed")
            if (
                opened_parent.st_dev != expected_parent.device
                or opened_parent.st_ino != expected_parent.inode
                or stat.S_IMODE(opened_parent.st_mode) != expected_parent.mode
                or opened_parent.st_uid != os.geteuid()
            ):
                fail("output parent descriptor differs from validated ancestry")
            named_artifacts = os.stat(
                "artifacts", dir_fd=temporary_descriptor, follow_symlinks=False
            )
            if (
                named_artifacts.st_dev != artifacts_status.st_dev
                or named_artifacts.st_ino != artifacts_status.st_ino
                or stat.S_IMODE(named_artifacts.st_mode)
                != stat.S_IMODE(artifacts_status.st_mode)
            ):
                fail("verified artifact directory changed before publication")
            require_unchanged_directory_ancestry(output_ancestry)
            if tracked_inputs is not None:
                require_tracked_source_inputs_unchanged(tracked_inputs)
            os.replace(
                "artifacts",
                output_directory.name,
                src_dir_fd=temporary_descriptor,
                dst_dir_fd=parent_descriptor,
            )
            promoted = True
            published_descriptor = os.open(
                output_directory.name,
                directory_flags,
                dir_fd=parent_descriptor,
            )
            published_status = os.fstat(published_descriptor)
            if (
                published_status.st_dev != artifacts_status.st_dev
                or published_status.st_ino != artifacts_status.st_ino
                or stat.S_IMODE(published_status.st_mode)
                != stat.S_IMODE(artifacts_status.st_mode)
            ):
                fail("published output directory differs from verified artifacts")
            for component in ("core", "base", "small"):
                require_bound_file_at(
                    published_descriptor,
                    archive_names[component],
                    final_archive_bindings[component],
                    label=f"published {component} archive",
                )
            require_bound_file_at(
                published_descriptor,
                staged_receipt.name,
                receipt_binding,
                label="published finalization receipt",
            )
            require_exact_directory_entries(
                published_descriptor,
                expected_output_names,
                label="published output directory",
            )
            named_published = os.stat(
                output_directory.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (
                named_published.st_dev != published_status.st_dev
                or named_published.st_ino != published_status.st_ino
                or stat.S_IMODE(named_published.st_mode)
                != stat.S_IMODE(published_status.st_mode)
            ):
                fail("published output name differs from verified directory")
            require_unchanged_directory_ancestry(output_ancestry)
            os.fsync(published_descriptor)
            require_exact_directory_entries(
                published_descriptor,
                expected_output_names,
                label="published output directory",
            )
            os.fsync(parent_descriptor)
            promoted = False
        except BaseException:
            if promoted and parent_descriptor >= 0 and temporary_descriptor >= 0:
                try:
                    os.replace(
                        output_directory.name,
                        ".rejected-output",
                        src_dir_fd=parent_descriptor,
                        dst_dir_fd=temporary_descriptor,
                    )
                    os.fsync(temporary_descriptor)
                    os.fsync(parent_descriptor)
                except OSError:
                    fail("failed publication could not be rolled back safely")
            raise
        finally:
            for descriptor in (
                published_descriptor,
                parent_descriptor,
                temporary_descriptor,
                artifacts_descriptor,
            ):
                if descriptor >= 0:
                    os.close(descriptor)
        return external_payload
    except FinalizationError:
        raise
    except OSError as error:
        fail(f"signed toolchain finalization failed safely: {type(error).__name__}")
    finally:
        for snapshot in input_snapshots:
            snapshot.close()
        shutil.rmtree(temporary_root, ignore_errors=True)


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--core-zip", required=True, type=Path)
    parser.add_argument("--base-zip", required=True, type=Path)
    parser.add_argument("--small-zip", required=True, type=Path)
    parser.add_argument("--unsigned-release-request", required=True, type=Path)
    parser.add_argument(
        "--builder-attested-unsigned-request-sha256", required=True
    )
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow-run-id", required=True, type=int)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--unsigned-artifact-id", required=True, type=int)
    parser.add_argument("--unsigned-artifact-digest", required=True)
    parser.add_argument("--request-artifact-id", required=True, type=int)
    parser.add_argument("--request-artifact-digest", required=True)
    parser.add_argument(
        "--github-authority-receipt",
        required=True,
        type=Path,
    )
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--identity-fingerprint", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--receipt", required=True, type=Path)
    return parser.parse_args(arguments)


def parse_github_artifact_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Authenticate one exact toolchain workflow artifact."
    )
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow-run-id", required=True, type=int)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--artifact-id", required=True, type=int)
    parser.add_argument("--artifact-digest", required=True)
    parser.add_argument("--artifact-name", required=True)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    if arguments and arguments[0] == "verify-github-artifact":
        options = parse_github_artifact_args(arguments[1:])
        try:
            production_single_github_artifact_authority(
                GitHubArtifactEvidence(
                    repository=options.repository,
                    workflow_run_id=options.workflow_run_id,
                    source_commit=options.source_commit,
                    artifact_id=options.artifact_id,
                    artifact_digest=options.artifact_digest,
                    artifact_name=options.artifact_name,
                )
            )
        except FinalizationError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        print("GitHub toolchain artifact authority verified.")
        return 0
    options = parse_args(arguments)
    try:
        finalize_signed_toolchain(
            version=options.version,
            core_zip=options.core_zip,
            base_zip=options.base_zip,
            small_zip=options.small_zip,
            unsigned_release_request=options.unsigned_release_request,
            builder_attested_unsigned_request_sha256=(
                options.builder_attested_unsigned_request_sha256
            ),
            builder_artifact_evidence=BuilderArtifactEvidence(
                repository=options.repository,
                workflow_run_id=options.workflow_run_id,
                source_commit=options.source_commit,
                unsigned_artifact_id=options.unsigned_artifact_id,
                unsigned_artifact_digest=options.unsigned_artifact_digest,
                request_artifact_id=options.request_artifact_id,
                request_artifact_digest=options.request_artifact_digest,
                request_sha256=(
                    options.builder_attested_unsigned_request_sha256
                ),
            ),
            output_directory=options.output_directory,
            identity_fingerprint=options.identity_fingerprint,
            team_id=options.team_id,
            receipt_path=options.receipt,
            artifact_authority_verifier=(
                lambda evidence, version: validate_github_artifact_authority_receipt(
                    options.github_authority_receipt,
                    evidence,
                    version,
                )
            ),
        )
    except FinalizationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Developer ID toolchain archives finalized.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
