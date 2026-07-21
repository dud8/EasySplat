#!/usr/bin/python3
"""Bind an accepted notarization receipt to the current app or DMG bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import struct
import sys
from pathlib import Path
from typing import NamedTuple, NoReturn


SHA256 = re.compile(r"[0-9a-f]{64}")
SUBMISSION_ID = re.compile(
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
)


class ReceiptError(RuntimeError):
    pass


class DirectoryBinding(NamedTuple):
    path: Path
    parent_descriptor: int
    descriptor: int
    parent_identity: tuple[int, int, int, int]
    identity: tuple[int, int, int, int]


class StableJSON(NamedTuple):
    payload: dict[str, object]
    identity: tuple[int, ...]
    sha256: str


def fail(message: str) -> NoReturn:
    raise ReceiptError(message)


def _safe_metadata(path: Path, *, directory: bool | None = None) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError:
        fail("artifact or receipt is missing")
    if stat.S_ISLNK(metadata.st_mode):
        fail("artifact or receipt must not be a symlink")
    if directory is True and not stat.S_ISDIR(metadata.st_mode):
        fail("artifact must be a directory")
    if directory is False and not stat.S_ISREG(metadata.st_mode):
        fail("artifact or receipt must be a regular file")
    if metadata.st_uid != os.geteuid():
        fail("artifact or receipt must be owned by the current user")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("artifact or receipt must not be group- or world-writable")
    if stat.S_ISREG(metadata.st_mode) and (
        metadata.st_nlink != 1 or metadata.st_size <= 0
    ):
        fail("artifact or receipt must be a nonempty, non-hardlinked file")
    return metadata


def _require_canonical(path: Path) -> None:
    if not path.is_absolute() or Path(os.path.normpath(str(path))) != path:
        fail("artifact or receipt path must be absolute and normalized")
    try:
        if path.resolve(strict=True) != path:
            fail("artifact or receipt path must be canonical")
    except OSError:
        fail("artifact or receipt is missing")


def _stable_file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _directory_identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
    )


def _open_bound_directory(root: Path) -> DirectoryBinding:
    _require_canonical(root)
    initial = _safe_metadata(root, directory=True)
    try:
        parent_initial = root.parent.lstat()
    except OSError:
        fail("artifact parent is missing")
    if not stat.S_ISDIR(parent_initial.st_mode) or stat.S_ISLNK(parent_initial.st_mode):
        fail("artifact parent must be a directory without symlinks")
    parent_identity = _directory_identity(parent_initial)
    root_identity = _directory_identity(initial)
    parent_descriptor = -1
    descriptor = -1
    completed = False
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        parent_descriptor = os.open(root.parent, flags)
        if _directory_identity(os.fstat(parent_descriptor)) != parent_identity:
            fail("artifact parent changed before binding")
        descriptor = os.open(root.name, flags, dir_fd=parent_descriptor)
        if _directory_identity(os.fstat(descriptor)) != root_identity:
            fail("artifact root changed before binding")
        named = os.stat(
            root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if _directory_identity(named) != root_identity:
            fail("artifact root pathname changed before binding")
        binding = DirectoryBinding(
            root,
            parent_descriptor,
            descriptor,
            parent_identity,
            root_identity,
        )
        completed = True
        return binding
    except OSError:
        fail("artifact root changed before binding")
    finally:
        if not completed:
            if descriptor >= 0:
                os.close(descriptor)
            if parent_descriptor >= 0:
                os.close(parent_descriptor)


def _close_bound_directory(binding: DirectoryBinding) -> None:
    os.close(binding.descriptor)
    os.close(binding.parent_descriptor)


def _require_bound_directory(binding: DirectoryBinding) -> None:
    try:
        if _directory_identity(os.fstat(binding.parent_descriptor)) != binding.parent_identity:
            fail("artifact parent binding changed")
        if _directory_identity(os.fstat(binding.descriptor)) != binding.identity:
            fail("artifact root binding changed")
        if _directory_identity(binding.path.parent.lstat()) != binding.parent_identity:
            fail("artifact parent pathname changed")
        named = os.stat(
            binding.path.name,
            dir_fd=binding.parent_descriptor,
            follow_symlinks=False,
        )
        if _directory_identity(named) != binding.identity:
            fail("artifact root pathname changed")
    except OSError:
        fail("artifact root pathname changed")


def _read_stable_json(path: Path, *, maximum_size: int, label: str) -> StableJSON:
    _require_canonical(path)
    initial = _safe_metadata(path, directory=False)
    if initial.st_size > maximum_size:
        fail(f"{label} is too large")
    initial_identity = _stable_file_identity(initial)
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        if _stable_file_identity(os.fstat(descriptor)) != initial_identity:
            fail(f"{label} identity changed before reading")
        chunks: list[bytes] = []
        total = 0
        while chunk := os.read(
            descriptor,
            min(1024 * 1024, maximum_size + 1 - total),
        ):
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum_size:
                fail(f"{label} is too large")
        if _stable_file_identity(os.fstat(descriptor)) != initial_identity:
            fail(f"{label} changed while reading")
        if _stable_file_identity(_safe_metadata(path, directory=False)) != initial_identity:
            fail(f"{label} pathname changed while reading")
        encoded = b"".join(chunks)
        payload = json.loads(encoded.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail(f"{label} is not valid UTF-8 JSON")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(payload, dict):
        fail(f"{label} must contain a JSON object")
    return StableJSON(
        payload=payload,
        identity=initial_identity,
        sha256=hashlib.sha256(encoded).hexdigest(),
    )


def _require_stable_json_evidence(
    path: Path,
    evidence: StableJSON,
    *,
    label: str,
) -> None:
    try:
        current = _safe_metadata(path, directory=False)
        if _stable_file_identity(current) != evidence.identity:
            fail(f"{label} identity changed after validation")
        if _stable_file_sha256(path, current) != evidence.sha256:
            fail(f"{label} digest changed after validation")
    except ReceiptError:
        fail(f"{label} changed after validation")


def _stable_file_sha256(path: Path, initial: os.stat_result | None = None) -> str:
    initial = initial or _safe_metadata(path, directory=False)
    binding = _stable_file_identity(initial)
    digest = hashlib.sha256()
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        if _stable_file_identity(os.fstat(descriptor)) != binding:
            fail("artifact file identity changed before hashing")
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        if _stable_file_identity(os.fstat(descriptor)) != binding:
            fail("artifact file changed while hashing")
        if _stable_file_identity(_safe_metadata(path, directory=False)) != binding:
            fail("artifact file pathname changed while hashing")
    except OSError:
        fail("artifact file changed while hashing")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def _tree_snapshot(root: Path) -> dict[str, tuple[object, ...]]:
    rows: dict[str, tuple[object, ...]] = {}
    pending = [root]
    while pending:
        path = pending.pop()
        metadata = _safe_metadata(path)
        relative = "." if path == root else path.relative_to(root).as_posix()
        identity = (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_uid,
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )
        if stat.S_ISDIR(metadata.st_mode):
            rows[relative] = ("directory", identity, None)
            try:
                children = sorted(
                    os.scandir(path),
                    key=lambda item: os.fsencode(item.name),
                    reverse=True,
                )
            except OSError:
                fail("artifact tree changed while enumerating")
            pending.extend(Path(child.path) for child in children)
        elif stat.S_ISREG(metadata.st_mode):
            rows[relative] = (
                "file",
                identity,
                _stable_file_sha256(path, metadata),
            )
        else:
            fail("artifact tree contains a special file")
    return rows


def _bound_tree_snapshot(root: DirectoryBinding) -> dict[str, tuple[object, ...]]:
    rows: dict[str, tuple[object, ...]] = {}
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY

    def scan(directory_descriptor: int, relative: str) -> None:
        initial_directory = os.fstat(directory_descriptor)
        _safe_directory_metadata(initial_directory)
        directory_identity = _stable_file_identity(initial_directory)
        rows[relative] = ("directory", directory_identity, None)
        scan_descriptor = -1
        iterator: object | None = None
        try:
            scan_descriptor = os.open(".", directory_flags, dir_fd=directory_descriptor)
            iterator = os.scandir(scan_descriptor)
            names = sorted(
                (entry.name for entry in iterator),
                key=os.fsencode,
            )
        except OSError:
            fail("artifact tree changed while enumerating")
        finally:
            close_iterator = getattr(iterator, "close", None)
            if close_iterator is not None:
                close_iterator()
            if scan_descriptor >= 0:
                os.close(scan_descriptor)

        for name in names:
            child_relative = name if relative == "." else f"{relative}/{name}"
            try:
                initial = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except OSError:
                fail("artifact tree changed while enumerating")
            if stat.S_ISLNK(initial.st_mode):
                fail("artifact tree contains a symlink")
            if initial.st_uid != os.geteuid():
                fail("artifact tree contains an entry owned by another user")
            if initial.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail("artifact tree contains a group- or world-writable entry")
            identity = _stable_file_identity(initial)
            if stat.S_ISDIR(initial.st_mode):
                child_descriptor = -1
                try:
                    child_descriptor = os.open(
                        name,
                        directory_flags,
                        dir_fd=directory_descriptor,
                    )
                    if _stable_file_identity(os.fstat(child_descriptor)) != identity:
                        fail("artifact tree directory changed before opening")
                    scan(child_descriptor, child_relative)
                    if _stable_file_identity(os.fstat(child_descriptor)) != identity:
                        fail("artifact tree directory changed while scanning")
                    if _stable_file_identity(
                        os.stat(
                            name,
                            dir_fd=directory_descriptor,
                            follow_symlinks=False,
                        )
                    ) != identity:
                        fail("artifact tree directory pathname changed while scanning")
                except OSError:
                    fail("artifact tree directory changed while scanning")
                finally:
                    if child_descriptor >= 0:
                        os.close(child_descriptor)
                continue
            if not stat.S_ISREG(initial.st_mode):
                fail("artifact tree contains a special file")
            if initial.st_nlink != 1:
                fail("artifact tree contains an unsafe regular file")
            descriptor = -1
            digest = hashlib.sha256()
            try:
                descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory_descriptor,
                )
                if _stable_file_identity(os.fstat(descriptor)) != identity:
                    fail("artifact tree file changed before opening")
                while chunk := os.read(descriptor, 1024 * 1024):
                    digest.update(chunk)
                if _stable_file_identity(os.fstat(descriptor)) != identity:
                    fail("artifact tree file changed while hashing")
                if _stable_file_identity(
                    os.stat(
                        name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                ) != identity:
                    fail("artifact tree file pathname changed while hashing")
            except OSError:
                fail("artifact tree file changed while hashing")
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
            rows[child_relative] = ("file", identity, digest.hexdigest())

        if _stable_file_identity(os.fstat(directory_descriptor)) != directory_identity:
            fail("artifact tree directory changed while scanning")

    _require_bound_directory(root)
    scan(root.descriptor, ".")
    _require_bound_directory(root)
    return rows


def _safe_directory_metadata(metadata: os.stat_result) -> None:
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail("artifact tree contains an unsafe directory")


def artifact_sha256(root: Path) -> str:
    _require_canonical(root)
    metadata = _safe_metadata(root)
    if stat.S_ISREG(metadata.st_mode):
        return _stable_file_sha256(root, metadata)
    if not stat.S_ISDIR(metadata.st_mode):
        fail("artifact must be a regular file or directory")

    binding = _open_bound_directory(root)
    try:
        before = _bound_tree_snapshot(binding)
        digest = hashlib.sha256()
        for relative in sorted(before, key=os.fsencode):
            kind, identity, file_digest = before[relative]
            relative_bytes = relative.encode("utf-8", errors="surrogateescape")
            digest.update(b"D" if kind == "directory" else b"F")
            digest.update(struct.pack(">Q", len(relative_bytes)))
            digest.update(relative_bytes)
            digest.update(struct.pack(">I", identity[2]))
            if kind == "file":
                digest.update(struct.pack(">Q", identity[5]))
                digest.update(bytes.fromhex(str(file_digest)))
        if _bound_tree_snapshot(binding) != before:
            fail("artifact tree changed while hashing")
        _require_bound_directory(binding)
        return digest.hexdigest()
    finally:
        _close_bound_directory(binding)


def validate_notarization_receipt(
    receipt: Path,
    artifact: Path,
    artifact_type: str,
    *,
    signing_receipt: Path | None = None,
) -> dict[str, object]:
    if artifact_type not in {"app", "dmg"}:
        fail("only app and DMG notarization receipts are publishable")
    _require_canonical(artifact)
    initial_artifact_metadata = _safe_metadata(
        artifact,
        directory=(artifact_type == "app"),
    )
    initial_artifact_identity = _stable_file_identity(initial_artifact_metadata)
    if artifact_type == "dmg" and artifact.suffix.lower() != ".dmg":
        fail("disk image artifact must have a .dmg suffix")
    receipt_evidence = _read_stable_json(
        receipt,
        maximum_size=1024 * 1024,
        label="notarization receipt",
    )
    payload = receipt_evidence.payload

    expected_verification = {
        "codesign": "passed",
        "systemPolicy": "passed" if artifact_type == "app" else "notApplicable",
        "stapler": "passed",
        "gatekeeper": "passed",
    }
    submission_id = payload.get("submissionID")
    pre_digest = payload.get("preStapleSHA256")
    post_digest = payload.get("postStapleSHA256")
    if (
        payload.get("schemaVersion") != 1
        or payload.get("artifactType") != artifact_type
        or payload.get("artifactDigestFormat")
        != ("sha256-tree-v1" if artifact_type == "app" else "sha256-file-v1")
        or payload.get("status") != "Accepted"
        or payload.get("stapled") is not True
        or payload.get("verification") != expected_verification
        or payload.get("downstreamChecksums")
        != "generate-after-notarization"
    ):
        fail("notarization receipt has invalid verification results")
    if (
        not isinstance(submission_id, str)
        or SUBMISSION_ID.fullmatch(submission_id) is None
        or submission_id == "00000000-0000-0000-0000-000000000000"
    ):
        fail("notarization receipt has an invalid submission identifier")
    if (
        not isinstance(pre_digest, str)
        or SHA256.fullmatch(pre_digest) is None
        or not isinstance(post_digest, str)
        or SHA256.fullmatch(post_digest) is None
        or pre_digest == post_digest
    ):
        fail("notarization receipt has invalid artifact digests")
    if artifact_sha256(artifact) != post_digest:
        fail("notarization receipt does not bind the current artifact bytes")
    signing_evidence: StableJSON | None = None
    if signing_receipt is not None:
        signing_evidence = _read_stable_json(
            signing_receipt,
            maximum_size=4 * 1024 * 1024,
            label="signing receipt",
        )
        signing = signing_evidence.payload
        artifact_digest = (
            signing.get("artifactDigest") if isinstance(signing, dict) else None
        )
        expected_format = (
            "sha256-tree-v1" if artifact_type == "app" else "sha256-file-v1"
        )
        if (
            not isinstance(signing, dict)
            or signing.get("schemaVersion") != 1
            or signing.get("rootKind") != artifact_type
            or not isinstance(artifact_digest, dict)
            or artifact_digest.get("format") != expected_format
            or artifact_digest.get("postSignSHA256") != pre_digest
        ):
            fail("signing post-sign digest does not match notarization pre-staple digest")
    final_artifact_metadata = _safe_metadata(
        artifact,
        directory=(artifact_type == "app"),
    )
    if _stable_file_identity(final_artifact_metadata) != initial_artifact_identity:
        fail("artifact identity changed while validating notarization receipts")
    if artifact_sha256(artifact) != post_digest:
        fail("notarization receipt does not bind the final current artifact bytes")
    _require_stable_json_evidence(
        receipt,
        receipt_evidence,
        label="notarization receipt",
    )
    if signing_receipt is not None and signing_evidence is not None:
        _require_stable_json_evidence(
            signing_receipt,
            signing_evidence,
            label="signing receipt",
        )
    final_artifact_metadata = _safe_metadata(
        artifact,
        directory=(artifact_type == "app"),
    )
    if _stable_file_identity(final_artifact_metadata) != initial_artifact_identity:
        fail("artifact identity changed while rebinding notarization receipts")
    if artifact_sha256(artifact) != post_digest:
        fail("notarization receipt does not bind the final current artifact bytes")
    return payload


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--type", required=True, choices=("app", "dmg"))
    parser.add_argument("--signing-receipt", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_args(argv)
    try:
        payload = validate_notarization_receipt(
            arguments.receipt,
            arguments.artifact,
            arguments.type,
            signing_receipt=arguments.signing_receipt,
        )
    except ReceiptError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(payload["postStapleSHA256"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
