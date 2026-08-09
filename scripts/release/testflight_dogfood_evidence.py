#!/usr/bin/env python3
"""Validate exact-build TestFlight dogfood results and publish the release gate."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


MAX_JSON_BYTES = 64 * 1024
CHECKS = {
    "cancelModelConversion",
    "cancelPreparation",
    "cancelTraining",
    "childTerminationBounded",
    "colmapPolycamZip",
    "exportDownloadsAbsentExisting",
    "exportEvidenceMatchesSource",
    "exportTmpAbsentExisting",
    "failedRetrainPreviousResultRelaunch",
    "folderEmptyUnreadableDeepOversizedMixedWrapped",
    "importerAddFiles",
    "importerAddFolders",
    "importerCancellationAlternation",
    "importerReplaceFiles",
    "importerReplaceFolders",
    "nerfstudioCanonicalTrainOnly",
    "plyTamperRejected",
    "previousResultExportShare",
    "realPhotoViewer",
    "receiptTamperRejected",
    "relaunchClean",
    "replacementPreservation",
    "secondInstanceReadExport",
    "shareAppSwitch",
    "shareClickAway",
    "shareEscape",
    "shareSelectedService",
    "shareTenCycleDiskBaseline",
    "shareViewerNavigation",
    "subjectKeyboard",
    "subjectVoiceOver",
    "successfulReplacementRetrain",
    "traversalSymlinkZipReplacement",
}


class DogfoodEvidenceError(RuntimeError):
    pass


def _fail(message: str) -> None:
    raise DogfoodEvidenceError(message)


def _canonical(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _exact_dict(value: object, keys: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != keys:
        _fail(f"{label} has an unexpected schema")
    return value


def _digest(value: object, label: str, *, prefixed: bool = False) -> str:
    pattern = r"sha256:[0-9a-f]{64}" if prefixed else r"[0-9a-f]{64}"
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        _fail(f"{label} has an invalid SHA-256")
    return value


def _inspect_stable_file(
    path: Path,
    label: str,
    maximum: int | None = None,
    *,
    capture_bytes: bool = False,
) -> tuple[dict[str, object], bytes | None]:
    if not path.is_absolute() or os.path.normpath(os.fspath(path)) != os.fspath(path):
        _fail(f"{label} path must be absolute and normalized")
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
    )
    digest = hashlib.sha256()
    total = 0
    captured: list[bytes] | None = [] if capture_bytes else None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size <= 0:
            _fail(f"{label} must be a nonempty single-link regular file")
        if maximum is not None and before.st_size > maximum:
            _fail(f"{label} exceeds its size limit")
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            total += len(block)
            if captured is not None:
                captured.append(block)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(path)
    identity = lambda item: (
        item.st_dev,
        item.st_ino,
        item.st_mode,
        item.st_nlink,
        item.st_size,
        item.st_mtime_ns,
        item.st_ctime_ns,
    )
    if total != before.st_size or identity(before) != identity(after) or identity(after) != identity(visible):
        _fail(f"{label} changed while it was hashed")
    return (
        {"byteCount": total, "sha256": digest.hexdigest()},
        b"".join(captured) if captured is not None else None,
    )


def _stable_file(path: Path, label: str, maximum: int | None = None) -> dict[str, object]:
    evidence, _ = _inspect_stable_file(path, label, maximum)
    return evidence


def _load_result(path: Path, label: str) -> dict[str, object]:
    _, data = _inspect_stable_file(
        path,
        label,
        MAX_JSON_BYTES,
        capture_bytes=True,
    )
    assert data is not None

    def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                _fail(f"{label} repeats JSON key {key}")
            result[key] = value
        return result

    def finite(value: str) -> object:
        _fail(f"{label} contains non-finite JSON value {value}")

    try:
        payload = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=unique,
            parse_constant=finite,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"{label} is invalid JSON: {error}")
    if not isinstance(payload, dict) or data != _canonical(payload):
        _fail(f"{label} must be canonical sorted JSON")
    return payload


def validate_result(
    value: object,
    *,
    container: str,
    source_commit: str,
    apple_id: str,
    version: str,
    build: str,
    package_sha256: str,
    submission_artifact_id: str,
    submission_artifact_digest: str,
) -> dict[str, object]:
    result = _exact_dict(
        value,
        {
            "app",
            "artifacts",
            "checks",
            "completedAt",
            "container",
            "host",
            "metrics",
            "packageSHA256",
            "recordType",
            "schemaVersion",
            "sourceCommit",
            "submissionArtifact",
            "tester",
        },
        f"{container} dogfood result",
    )
    if result["recordType"] != "testflightDogfoodResult" or result["schemaVersion"] != 1:
        _fail(f"{container} dogfood result has an unsupported schema")
    if result["container"] != container:
        _fail(f"{container} dogfood result names a different container")
    if result["sourceCommit"] != source_commit or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
        _fail(f"{container} dogfood result names a different source")
    if result["packageSHA256"] != package_sha256:
        _fail(f"{container} dogfood result names a different package")
    _digest(result["packageSHA256"], f"{container} package")
    app = _exact_dict(result["app"], {"appleID", "build", "version"}, f"{container} app")
    if app != {"appleID": apple_id, "build": build, "version": version}:
        _fail(f"{container} dogfood result names a different app build")
    submission = _exact_dict(
        result["submissionArtifact"], {"digest", "id"}, f"{container} submission"
    )
    if submission != {"digest": submission_artifact_digest, "id": submission_artifact_id}:
        _fail(f"{container} dogfood result names a different submission artifact")
    _digest(submission["digest"], f"{container} submission", prefixed=True)
    if re.fullmatch(r"[1-9][0-9]*", str(submission["id"])) is None:
        _fail(f"{container} dogfood result has an invalid submission artifact ID")
    if not isinstance(result["tester"], str) or re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", result["tester"]) is None:
        _fail(f"{container} dogfood result has an invalid tester")
    if not isinstance(result["completedAt"], str) or re.fullmatch(
        r"20[0-9]{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z",
        result["completedAt"],
    ) is None:
        _fail(f"{container} dogfood result has an invalid completion time")
    host = _exact_dict(
        result["host"],
        {"containerFingerprintSHA256", "macOSBuild", "machineModel", "testFlightBuild"},
        f"{container} host",
    )
    _digest(host["containerFingerprintSHA256"], f"{container} container fingerprint")
    for key in ("macOSBuild", "machineModel", "testFlightBuild"):
        if not isinstance(host[key], str) or not host[key] or len(host[key]) > 128:
            _fail(f"{container} host has invalid {key}")
    checks = _exact_dict(result["checks"], CHECKS, f"{container} checks")
    if any(value is not True for value in checks.values()):
        _fail(f"{container} dogfood has a failed or unconfirmed check")
    metrics = _exact_dict(
        result["metrics"],
        {
            "activeShareSessionsAfter",
            "cancellationMaxSeconds",
            "shareCleanupMaxSeconds",
            "shareCycles",
            "shareTemporaryBytesAfter",
            "shareTemporaryBytesBefore",
        },
        f"{container} metrics",
    )
    for key, maximum in (("cancellationMaxSeconds", 2.0), ("shareCleanupMaxSeconds", 1.0)):
        value = metrics[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= float(value) <= maximum:
            _fail(f"{container} dogfood exceeds the {key} gate")
    for key in ("shareTemporaryBytesAfter", "shareTemporaryBytesBefore", "activeShareSessionsAfter", "shareCycles"):
        if isinstance(metrics[key], bool) or not isinstance(metrics[key], int) or int(metrics[key]) < 0:
            _fail(f"{container} dogfood has invalid {key}")
    if metrics["shareCycles"] != 10 or metrics["activeShareSessionsAfter"] != 0:
        _fail(f"{container} dogfood did not complete the ten-cycle share gate")
    if metrics["shareTemporaryBytesAfter"] != metrics["shareTemporaryBytesBefore"]:
        _fail(f"{container} dogfood leaked a temporary share snapshot")
    artifacts = result["artifacts"]
    if not isinstance(artifacts, list) or not 2 <= len(artifacts) <= 50:
        _fail(f"{container} dogfood must bind at least two evidence artifacts")
    names: set[str] = set()
    for index, raw in enumerate(artifacts):
        artifact = _exact_dict(raw, {"byteCount", "name", "sha256"}, f"{container} artifact {index}")
        if not isinstance(artifact["name"], str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", artifact["name"]) is None or artifact["name"] in names:
            _fail(f"{container} dogfood has an invalid or duplicate artifact name")
        names.add(artifact["name"])
        if isinstance(artifact["byteCount"], bool) or not isinstance(artifact["byteCount"], int) or artifact["byteCount"] <= 0:
            _fail(f"{container} dogfood artifact has an invalid byte count")
        _digest(artifact["sha256"], f"{container} artifact")
    return result


def _write_new(path: Path, data: bytes) -> None:
    parent = path.parent
    if not path.is_absolute() or os.path.normpath(os.fspath(path)) != os.fspath(path):
        _fail("output path must be absolute and normalized")
    parent_descriptor = os.open(parent, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = -1
    created = False
    try:
        descriptor = os.open(
            path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_descriptor,
        )
        created = True
        remaining = memoryview(data)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                _fail("output write was incomplete")
            remaining = remaining[written:]
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size != len(data):
            _fail("output failed descriptor validation")
        os.fsync(parent_descriptor)
    except BaseException:
        if created:
            try:
                named = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
                if descriptor >= 0 and named.st_dev == os.fstat(descriptor).st_dev and named.st_ino == os.fstat(descriptor).st_ino:
                    os.unlink(path.name, dir_fd=parent_descriptor)
                    os.fsync(parent_descriptor)
            except OSError:
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_descriptor)


def build_gate(options: argparse.Namespace) -> dict[str, object]:
    package = _stable_file(options.package, "TestFlight package")
    fresh = _load_result(options.fresh_result, "Fresh-container dogfood result")
    affected = _load_result(options.affected_result, "Affected-container dogfood result")
    common = {
        "source_commit": options.source_commit,
        "apple_id": options.apple_id,
        "version": options.version,
        "build": options.build,
        "package_sha256": package["sha256"],
        "submission_artifact_id": options.submission_artifact_id,
        "submission_artifact_digest": options.submission_artifact_digest,
    }
    fresh = validate_result(fresh, container="fresh", **common)
    affected = validate_result(affected, container="affectedInternal", **common)
    fresh_host = fresh["host"]
    affected_host = affected["host"]
    assert isinstance(fresh_host, dict) and isinstance(affected_host, dict)
    if fresh_host["containerFingerprintSHA256"] == affected_host["containerFingerprintSHA256"]:
        _fail("fresh and affected dogfood results name the same app container")
    sidecars = {
        "processingReceipt": _stable_file(options.processing_receipt, "processing receipt", MAX_JSON_BYTES),
        "releaseEvidence": _stable_file(options.evidence, "release evidence", 1024 * 1024),
        "uploadReceipt": _stable_file(options.upload_receipt, "upload receipt", MAX_JSON_BYTES),
    }
    if re.fullmatch(r"[1-9][0-9]*", options.workflow_run_id) is None or re.fullmatch(r"[1-9][0-9]*", options.workflow_run_attempt) is None:
        _fail("TestFlight workflow identity is invalid")
    payload: dict[str, object] = {
        "app": {"appleID": options.apple_id, "build": options.build, "version": options.version},
        "dogfood": {
            "affectedInternalContainer": affected,
            "approvalEnvironment": "testflight-dogfood",
            "freshContainer": fresh,
        },
        "package": package,
        "recordType": "testflightDogfoodGate",
        "schemaVersion": 1,
        "sidecars": sidecars,
        "sourceCommit": options.source_commit,
        "submissionArtifact": {"digest": options.submission_artifact_digest, "id": options.submission_artifact_id},
        "workflow": {"runAttempt": options.workflow_run_attempt, "runID": options.workflow_run_id},
    }
    encoded = _canonical(payload)
    if len(encoded) > MAX_JSON_BYTES:
        _fail("TestFlight dogfood gate exceeds its size limit")
    _write_new(options.output, encoded)
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    materialize = commands.add_parser("materialize")
    materialize.add_argument("--environment-variable", required=True)
    materialize.add_argument("--output", required=True, type=Path)
    gate = commands.add_parser("build-gate")
    for name in ("package", "evidence", "upload-receipt", "processing-receipt", "fresh-result", "affected-result", "output"):
        gate.add_argument(f"--{name}", required=True, type=Path)
    for name in ("source-commit", "apple-id", "version", "build", "submission-artifact-id", "submission-artifact-digest", "workflow-run-id", "workflow-run-attempt"):
        gate.add_argument(f"--{name}", required=True)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = _parser().parse_args(arguments)
    try:
        if options.command == "materialize":
            encoded = os.environ.get(options.environment_variable)
            if not encoded:
                _fail("dogfood result environment variable is empty")
            try:
                data = base64.b64decode(encoded, validate=True)
            except (binascii.Error, ValueError):
                _fail("dogfood result is not strict base64")
            if not data or len(data) > MAX_JSON_BYTES:
                _fail("dogfood result is empty or oversized")
            _write_new(options.output, data)
        else:
            build_gate(options)
    except (DogfoodEvidenceError, OSError) as error:
        print(f"TestFlight dogfood evidence rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
