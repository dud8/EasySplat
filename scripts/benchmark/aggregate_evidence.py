#!/usr/bin/env python3
"""Validate and aggregate three compact benchmark lane shards."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, NoReturn

from jsonschema import Draft202012Validator, SchemaError, ValidationError

try:
    from scripts.benchmark import easysplat_benchmark as benchmark
    from scripts.benchmark import evidence_protocol as evidence
except ModuleNotFoundError:
    import easysplat_benchmark as benchmark
    import evidence_protocol as evidence


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RESULT_SCHEMA_PATH = REPOSITORY_ROOT / "scripts/benchmark/result.schema.json"
PREPARER_RELATIVE_PATH = "scripts/benchmark/prepare_evidence.py"
PREPARER_VERSION = "2.0.0"
COLLECTOR_RELATIVE_PATH = "scripts/benchmark/run_lane.py"
COLLECTOR_VERSION = "1.0.0"
PREPARED_INDEX_NAME = "prepared-index.json"
RELEASE_LANES = (
    evidence.LANE_REFERENCE,
    evidence.LANE_CONSTRAINED,
    evidence.LANE_EIGHT_GB,
)
MAX_INDEX_BYTES = 16 * 1024 * 1024
MAX_REQUEST_BYTES = 16 * 1024 * 1024
MAX_COMPACT_FILE_BYTES = 16 * 1024 * 1024
MAX_COMPACT_TREE_BYTES = 2 * 1024**3
EXPECTED_SCENE_COUNT = 26
EXPECTED_RECORD_COUNT = 65
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
GIT_REFERENCE_PATTERN = re.compile(r"^refs/[A-Za-z0-9._/-]+$")


class AggregationError(ValueError):
    """The prepared evidence closure is unsafe, incomplete, or inconsistent."""


def _reject_json_constant(value: str) -> NoReturn:
    raise AggregationError(f"JSON contains non-finite constant {value}")


def _reject_duplicate_keys(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AggregationError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _require_finite_numbers(value: Any) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise AggregationError("JSON contains a non-finite number")
    if isinstance(value, Mapping):
        for item in value.values():
            _require_finite_numbers(item)
    elif isinstance(value, list):
        for item in value:
            _require_finite_numbers(item)


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise AggregationError(f"{label} must be an object")
    return value


def _exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    if set(value) == expected_set:
        return
    missing = sorted(expected_set - set(value))
    extra = sorted(set(value) - expected_set)
    details = []
    if missing:
        details.append("missing " + ", ".join(missing))
    if extra:
        details.append("unknown " + ", ".join(extra))
    raise AggregationError(f"{label} has invalid fields: {'; '.join(details)}")


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
        raise AggregationError(f"{label} must be a SHA-256 digest")
    return value


def _safe_relative_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise AggregationError(f"{label} must be a canonical relative path")
    relative = PurePosixPath(value)
    if (
        relative.is_absolute()
        or value != relative.as_posix()
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise AggregationError(f"{label} must be a canonical relative path")
    return Path(*relative.parts)


def _canonical_real_directory(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    try:
        metadata = absolute.lstat()
        resolved = absolute.resolve(strict=True)
    except OSError as error:
        raise AggregationError(f"{label} is missing") from error
    if absolute.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        raise AggregationError(f"{label} must be a real directory")
    return resolved


def _stable_regular_bytes(path: Path, label: str, maximum_bytes: int) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise AggregationError(f"{label} is missing") from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > maximum_bytes
    ):
        raise AggregationError(f"{label} must be a bounded single-link regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            opened = os.fstat(handle.fileno())
            data = handle.read(maximum_bytes + 1)
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise AggregationError(f"{label} could not be read safely") from error
    if len(data) > maximum_bytes:
        raise AggregationError(f"{label} exceeds its size limit")
    stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_nlink")
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or any(getattr(opened, field) != getattr(before, field) for field in stable_fields)
        or any(getattr(after, field) != getattr(opened, field) for field in stable_fields)
    ):
        raise AggregationError(f"{label} changed while it was read")
    return data


def _load_canonical_json(path: Path, label: str, maximum_bytes: int) -> Any:
    data = _stable_regular_bytes(path, label, maximum_bytes)
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
        _require_finite_numbers(value)
    except AggregationError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise AggregationError(f"{label} is not strict JSON") from error
    if data != evidence.canonical_json_bytes(value) + b"\n":
        raise AggregationError(f"{label} is not canonical JSON")
    return value


def _load_tracked_json(path: Path, label: str, maximum_bytes: int) -> Any:
    data = _stable_regular_bytes(path, label, maximum_bytes)
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
        _require_finite_numbers(value)
        return value
    except AggregationError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise AggregationError(f"{label} is not strict JSON") from error


def _canonical_value_sha256(value: Any) -> str:
    return evidence.sha256_bytes(evidence.canonical_json_bytes(value) + b"\n")


def _read_small_text(path: Path, label: str, maximum_bytes: int = 4096) -> str:
    return _stable_regular_bytes(path, label, maximum_bytes).decode("utf-8").strip()


def _git_directories(repository_root: Path) -> tuple[Path, Path]:
    marker = repository_root / ".git"
    if marker.is_dir() and not marker.is_symlink():
        git_directory = marker.resolve(strict=True)
    else:
        marker_text = _read_small_text(marker, "Git worktree marker")
        if not marker_text.startswith("gitdir: "):
            raise AggregationError("Git worktree marker is invalid")
        raw = Path(marker_text.removeprefix("gitdir: "))
        git_directory = (raw if raw.is_absolute() else repository_root / raw).resolve(strict=True)
    common_marker = git_directory / "commondir"
    if common_marker.exists():
        raw_common = Path(_read_small_text(common_marker, "Git common directory marker"))
        common_directory = (
            raw_common if raw_common.is_absolute() else git_directory / raw_common
        ).resolve(strict=True)
    else:
        common_directory = git_directory
    return git_directory, common_directory


def _current_git_commit(repository_root: Path = REPOSITORY_ROOT) -> str:
    git_directory, common_directory = _git_directories(repository_root)
    head = _read_small_text(git_directory / "HEAD", "Git HEAD")
    if COMMIT_PATTERN.fullmatch(head):
        return head
    reference = head.removeprefix("ref: ") if head.startswith("ref: ") else ""
    if not GIT_REFERENCE_PATTERN.fullmatch(reference) or ".." in PurePosixPath(reference).parts:
        raise AggregationError("Git HEAD reference is invalid")
    relative = Path(*PurePosixPath(reference).parts)
    for base in (git_directory, common_directory):
        candidate = base / relative
        if candidate.exists():
            commit = _read_small_text(candidate, "Git HEAD reference")
            if COMMIT_PATTERN.fullmatch(commit):
                return commit
            raise AggregationError("Git HEAD reference does not contain a commit")
    packed = common_directory / "packed-refs"
    if packed.exists():
        for line in _read_small_text(packed, "Git packed references", 32 * 1024 * 1024).splitlines():
            if not line or line.startswith(("#", "^")):
                continue
            fields = line.split(" ", 1)
            if len(fields) == 2 and fields[1] == reference and COMMIT_PATTERN.fullmatch(fields[0]):
                return fields[0]
    raise AggregationError("Git HEAD reference is unresolved")


def _require_clean_worktree(repository_root: Path = REPOSITORY_ROOT) -> None:
    try:
        result = subprocess.run(
            [
                "/usr/bin/git",
                "--no-optional-locks",
                "-C",
                str(repository_root),
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise AggregationError(f"cannot inspect Git worktree state: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise AggregationError(
            "cannot inspect Git worktree state" + (f": {detail}" if detail else "")
        )
    if result.stdout:
        raise AggregationError("cannot aggregate release evidence from a dirty Git worktree")


def _validate_producer(value: Any, label: str) -> dict[str, Any]:
    producer = _mapping(value, label)
    _exact_keys(producer, {"protocol_version", "version", "executable", "sha256"}, label)
    expected = {
        "protocol_version": evidence.PROTOCOL_VERSION,
        "version": evidence.PRODUCER_VERSION,
        "executable": evidence.PRODUCER_RELATIVE_PATH,
        "sha256": evidence.sha256_file(REPOSITORY_ROOT / evidence.PRODUCER_RELATIVE_PATH),
    }
    if producer != expected:
        raise AggregationError(f"{label} does not match this checkout")
    return dict(producer)


def _validate_descriptor(value: Any, label: str, *, expected_path: str | None = None) -> dict[str, Any]:
    descriptor = _mapping(value, label)
    _exact_keys(descriptor, {"path", "sha256", "bytes"}, label)
    relative = _safe_relative_path(descriptor["path"], f"{label}.path")
    if expected_path is not None and relative.as_posix() != expected_path:
        raise AggregationError(f"{label}.path is invalid")
    _digest(descriptor["sha256"], f"{label}.sha256")
    if type(descriptor["bytes"]) is not int or descriptor["bytes"] < 0:
        raise AggregationError(f"{label}.bytes must be a nonnegative integer")
    return dict(descriptor)


def _verify_descriptor_file(
    root: Path,
    value: Any,
    label: str,
    *,
    expected_path: str | None = None,
) -> dict[str, Any]:
    descriptor = _validate_descriptor(value, label, expected_path=expected_path)
    path = root / _safe_relative_path(descriptor["path"], f"{label}.path")
    data = _stable_regular_bytes(path, label, MAX_COMPACT_FILE_BYTES)
    if len(data) != descriptor["bytes"] or evidence.sha256_bytes(data) != descriptor["sha256"]:
        raise AggregationError(f"{label} descriptor does not match its file")
    return descriptor


def _validate_prepared_attestation(
    value: Any,
    request: Mapping[str, Any],
    lane: str,
    runner: Mapping[str, Any],
) -> dict[str, Any]:
    attestation = _mapping(value, "prepared evidence")
    _exact_keys(
        attestation,
        {
            "schema_version", "binding", "baseline_run_configuration",
            "candidate_run_configuration", "category", "capture_traits",
            "holdout_indices", "reference_artifacts", "timing_basis",
            "expected_outcome", "input_kind", "gate_scopes",
            "rendering_driver_identity", "scoring_runtime", "lane", "machine",
            "producer", "measurement_runner", "commands", "resolved_compute",
            "actual", "metrics", "artifacts",
        },
        "prepared evidence",
    )
    if attestation["schema_version"] != 3 or attestation["lane"] != lane:
        raise AggregationError("prepared evidence schema or lane is invalid")
    validated_request = evidence.validate_request(request)
    for field in (
        "binding", "baseline_run_configuration", "candidate_run_configuration", "category",
        "capture_traits", "holdout_indices", "reference_artifacts", "timing_basis",
        "expected_outcome", "input_kind", "gate_scopes", "rendering_driver_identity",
    ):
        if attestation[field] != validated_request[field]:
            raise AggregationError(f"prepared evidence {field} does not match its request")
    expected_scoring = (
        evidence.render_scoring_runtime()
        if "scene_quality" in validated_request["gate_scopes"]
        else {"status": "not_used"}
    )
    if attestation["scoring_runtime"] != expected_scoring:
        raise AggregationError("prepared evidence render-scoring runtime is invalid")
    if validated_request["expected_outcome"]["kind"] == "valid":
        evidence._validate_resolved_compute(
            attestation["resolved_compute"], validated_request["candidate_run_configuration"]
        )
    elif attestation["resolved_compute"] != {"status": "not_applicable"}:
        raise AggregationError("invalid evidence must mark resolved compute not_applicable")
    _validate_producer(attestation["producer"], "prepared evidence producer")
    if evidence.validate_runner_identity(attestation["measurement_runner"], lane) != (
        evidence.validate_runner_identity(runner, lane)
    ):
        raise AggregationError("prepared evidence measurement runner is invalid")
    evidence.validate_machine_lane(_mapping(attestation["machine"], "prepared evidence machine"), lane)
    benchmark._validate_actual_evidence(attestation["actual"], "prepared actual evidence")
    metric_errors = benchmark.metric_validation_failures(attestation["metrics"])
    if metric_errors:
        raise AggregationError("prepared metrics are invalid: " + "; ".join(metric_errors))
    artifacts = _mapping(attestation["artifacts"], "prepared artifacts")
    for name, descriptor in artifacts.items():
        if not isinstance(name, str) or not evidence.SAFE_TOKEN_PATTERN.fullmatch(name):
            raise AggregationError("prepared artifact name is invalid")
        _validate_descriptor(descriptor, f"prepared artifact {name}")
    return dict(attestation)


def _validate_prepared_lane_outcome(
    value: Any,
    path: Path,
    request: Mapping[str, Any],
    lane: str,
    runner: Mapping[str, Any],
) -> dict[str, Any]:
    receipt = _mapping(value, "lane outcome")
    try:
        validated = evidence.validate_prepared_lane_outcome_file(
            path,
            request,
            lane,
            runner,
        )
    except evidence.EvidenceError as error:
        raise AggregationError(f"prepared lane outcome is invalid: {error}") from error
    if dict(validated) != dict(receipt):
        raise AggregationError("prepared lane outcome changed while it was validated")
    return dict(validated)


def _source_identity(path: str, version: str) -> dict[str, Any]:
    return {
        "version": version,
        "executable": path,
        "sha256": evidence.sha256_file(REPOSITORY_ROOT / path),
    }


def _canonical_utc_datetime(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise AggregationError(f"{label} must be canonical UTC")
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise AggregationError(f"{label} must be canonical UTC") from error
    if parsed.tzinfo != timezone.utc or parsed.isoformat().replace("+00:00", "Z") != value:
        raise AggregationError(f"{label} must be canonical UTC")
    return parsed


def _validate_prepared_index(root: Path, value: Any) -> dict[str, Any]:
    index = _mapping(value, "prepared index")
    _exact_keys(
        index,
        {
            "schema_version", "lane", "git_commit", "protocol_version", "app_version",
            "toolchain_identity", "benchmark_contract_sha256", "sources",
            "collection_started_at_utc", "collection_ended_at_utc",
            "request_index", "corpus_manifest", "reference_config", "lane_result", "records",
        },
        "prepared index",
    )
    if index["schema_version"] != 2 or index["protocol_version"] != evidence.PROTOCOL_VERSION:
        raise AggregationError("prepared index schema is invalid")
    if index["lane"] not in RELEASE_LANES:
        raise AggregationError("prepared index lane is invalid")
    for field in ("toolchain_identity", "benchmark_contract_sha256"):
        _digest(index[field], f"prepared index {field}")
    if not isinstance(index["git_commit"], str) or not COMMIT_PATTERN.fullmatch(index["git_commit"]):
        raise AggregationError("prepared index git commit is invalid")
    if index["app_version"] != benchmark.APP_VERSION:
        raise AggregationError("prepared index app version does not match this checkout")
    started = _canonical_utc_datetime(index["collection_started_at_utc"], "collection start")
    ended = _canonical_utc_datetime(index["collection_ended_at_utc"], "collection end")
    if started > ended:
        raise AggregationError("prepared index collection timestamps are reversed")
    sources = _mapping(index["sources"], "prepared index sources")
    _exact_keys(sources, {"evidence_protocol", "collector", "preparer"}, "prepared index sources")
    expected_sources = {
        "evidence_protocol": _source_identity(
            evidence.PRODUCER_RELATIVE_PATH,
            evidence.PRODUCER_VERSION,
        ),
        "collector": _source_identity(COLLECTOR_RELATIVE_PATH, COLLECTOR_VERSION),
        "preparer": _source_identity(PREPARER_RELATIVE_PATH, PREPARER_VERSION),
    }
    if dict(sources) != expected_sources:
        raise AggregationError("prepared index sources do not match this checkout")
    _verify_descriptor_file(root, index["request_index"], "request index", expected_path="requests/index.json")
    _verify_descriptor_file(root, index["corpus_manifest"], "corpus manifest", expected_path="requests/corpus.json")
    _verify_descriptor_file(root, index["reference_config"], "reference config", expected_path="requests/reference-config.json")
    _verify_descriptor_file(root, index["lane_result"], "lane result", expected_path="lane-result.json")
    if not isinstance(index["records"], list) or not index["records"]:
        raise AggregationError("prepared index records must be a nonempty array")
    lane_result = _mapping(
        _load_canonical_json(root / "lane-result.json", "lane result", MAX_INDEX_BYTES),
        "lane result",
    )
    _exact_keys(
        lane_result,
        {
            "schema_version", "lane", "machine", "git_commit", "corpus_digest",
            "thresholds_digest", "toolchain_identity", "producer_digest",
            "runner_identity", "rendering_driver_identity", "collections",
            "collection_started_at_utc", "collection_ended_at_utc",
        },
        "lane result",
    )
    for field in (
        "lane", "git_commit", "toolchain_identity",
        "collection_started_at_utc", "collection_ended_at_utc",
    ):
        if lane_result[field] != index[field]:
            raise AggregationError(f"lane result {field} does not match its prepared index")
    collections = lane_result["collections"]
    if not isinstance(collections, list) or len(collections) != len(index["records"]):
        raise AggregationError("lane result collection closure is incomplete")
    for number, (collection_value, record_value) in enumerate(
        zip(collections, index["records"], strict=True)
    ):
        collection = _mapping(collection_value, f"lane collection[{number}]")
        record = _mapping(record_value, f"prepared record[{number}]")
        _exact_keys(
            collection,
            {"scene_id", "scale", "lane", "collector_status", "sha256"},
            f"lane collection[{number}]",
        )
        expected_status = (
            _safe_relative_path(record.get("artifact_root"), "prepared artifact root")
            / "collector-status.json"
        ).as_posix()
        if (
            collection["scene_id"] != record.get("scene_id")
            or collection["scale"] != record.get("scale")
            or collection["lane"] != index["lane"]
            or collection["collector_status"] != expected_status
            or collection["sha256"] != record.get("collector_status_sha256")
        ):
            raise AggregationError("lane result collection does not match prepared evidence")
    return dict(index)


def _expected_tree_files(
    prepared_index: Mapping[str, Any],
) -> set[Path]:
    expected = {
        Path(PREPARED_INDEX_NAME),
        Path("requests/index.json"),
        Path("requests/corpus.json"),
        Path("requests/reference-config.json"),
        Path("lane-result.json"),
    }
    for record in prepared_index["records"]:
        item = _mapping(record, "prepared record")
        request = _validate_descriptor(item.get("request"), "prepared request descriptor")
        prepared = _validate_descriptor(item.get("prepared"), "prepared evidence descriptor")
        artifact_root = _safe_relative_path(item.get("artifact_root"), "prepared artifact root")
        expected.add(_safe_relative_path(request["path"], "prepared request path"))
        expected.add(artifact_root / _safe_relative_path(prepared["path"], "prepared evidence path"))
        if item.get("disposition") == "lane_outcome":
            try:
                outcome = evidence._validate_lane_outcome_payload(item.get("outcome"))
            except evidence.EvidenceError as error:
                raise AggregationError(f"prepared lane outcome is invalid: {error}") from error
            if outcome["kind"] == "environment_rejected":
                expected.add(artifact_root / "measurement-environment.json")
                expected.add(artifact_root / "host-monitor.json")
    return expected


def _scan_compact_tree(root: Path, expected_files: set[Path]) -> None:
    actual_files: set[Path] = set()
    actual_directories: set[Path] = set()
    total_bytes = 0

    def scan(directory: Path) -> None:
        nonlocal total_bytes
        try:
            entries = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            raise AggregationError("prepared evidence tree could not be inspected") from error
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root)
            try:
                metadata = path.lstat()
            except OSError as error:
                raise AggregationError("prepared evidence entry is unreadable") from error
            if stat.S_ISLNK(metadata.st_mode):
                raise AggregationError(f"prepared evidence contains a symbolic link: {relative.as_posix()}")
            if stat.S_ISDIR(metadata.st_mode):
                actual_directories.add(relative)
                scan(path)
                continue
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise AggregationError(f"prepared evidence contains an unsafe file: {relative.as_posix()}")
            if metadata.st_size <= 0 or metadata.st_size > MAX_COMPACT_FILE_BYTES:
                raise AggregationError(f"prepared evidence file is not compact: {relative.as_posix()}")
            total_bytes += metadata.st_size
            if total_bytes > MAX_COMPACT_TREE_BYTES:
                raise AggregationError("prepared evidence closure exceeds its compact size limit")
            actual_files.add(relative)

    scan(root)
    expected_directories = {
        parent
        for path in expected_files
        for parent in path.parents
        if parent != Path(".")
    }
    unexpected_directories = sorted(
        path.as_posix() for path in actual_directories - expected_directories
    )
    if actual_files != expected_files:
        missing = sorted(path.as_posix() for path in expected_files - actual_files)
        extra = sorted(path.as_posix() for path in actual_files - expected_files)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unexpected " + ", ".join(extra))
        raise AggregationError("prepared evidence closure is not exact: " + "; ".join(details))
    if unexpected_directories:
        raise AggregationError(
            "prepared evidence closure contains unexpected directories: "
            + ", ".join(unexpected_directories)
        )


def _prepare_output(path: Path, prepared_roots: Iterable[Path]) -> Path:
    roots = tuple(prepared_roots)
    absolute = Path(os.path.abspath(path))
    if absolute.exists() or absolute.is_symlink():
        root = _canonical_real_directory(absolute, "aggregate output")
        if any(root == prepared or root in prepared.parents or prepared in root.parents for prepared in roots):
            raise AggregationError("aggregate output and prepared evidence roots must not overlap")
        if any(root.iterdir()):
            raise AggregationError("aggregate output must be absent or empty")
        return root
    parent = _canonical_real_directory(absolute.parent, "aggregate output parent")
    output = parent / absolute.name
    if any(output == prepared or output in prepared.parents or prepared in output.parents for prepared in roots):
        raise AggregationError("aggregate output and prepared evidence roots must not overlap")
    output.mkdir(mode=0o700)
    return output


def _write_exclusive_json(path: Path, value: Any) -> None:
    data = evidence.canonical_json_bytes(value) + b"\n"
    temporary = path.parent / f".{path.name}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def _load_and_validate_requests(
    roots_by_lane: Mapping[str, Path],
    request_index: Mapping[str, Any],
    corpus: Mapping[str, Any],
    identity: benchmark.RunIdentity,
) -> tuple[dict[tuple[str, int, str], dict[str, Any]], dict[str, str]]:
    scenes = {scene["id"]: scene for scene in corpus["scenes"]}
    runners = request_index["runner_identities"]
    contract_digest = benchmark.benchmark_contract_sha256(corpus)
    requests: dict[tuple[str, int, str], dict[str, Any]] = {}
    scene_digests: dict[str, str] = {}
    digest_owners: dict[str, str] = {}
    for entry in request_index["requests"]:
        key = (entry["scene_id"], entry["scale"], entry["lane"])
        request_path = (
            roots_by_lane[entry["lane"]]
            / "requests"
            / _safe_relative_path(entry["request"], "request path")
        )
        raw = _load_canonical_json(request_path, "protected request", MAX_REQUEST_BYTES)
        try:
            request = dict(evidence.validate_request(raw))
        except evidence.EvidenceError as error:
            raise AggregationError(f"protected request is invalid: {error}") from error
        input_digest = request["binding"]["input_digest"]
        previous = scene_digests.setdefault(entry["scene_id"], input_digest)
        if previous != input_digest:
            raise AggregationError(f"{entry['scene_id']} has inconsistent input digests")
        owner = digest_owners.setdefault(input_digest, entry["scene_id"])
        if owner != entry["scene_id"]:
            raise AggregationError(f"{owner} and {entry['scene_id']} reuse one input digest")
        expected = benchmark._evidence_request(
            scenes[entry["scene_id"]],
            entry["scale"],
            entry["lane"],
            identity,
            input_digest,
            runners[evidence.RENDERING_DRIVER_IDENTITY],
            contract_digest,
        )
        if request != expected:
            raise AggregationError("protected request does not match the prepared benchmark contract")
        requests[key] = request
    if len(scene_digests) != EXPECTED_SCENE_COUNT or len(set(scene_digests.values())) != EXPECTED_SCENE_COUNT:
        raise AggregationError("prepared evidence must bind one unique input digest to every scene")
    return requests, scene_digests


def _record_lookup(
    prepared_indexes: Mapping[str, Mapping[str, Any]],
    request_index: Mapping[str, Any],
) -> dict[tuple[str, int, str], Mapping[str, Any]]:
    per_lane = {
        lane: list(_mapping(index, f"{lane} prepared index")["records"])
        for lane, index in prepared_indexes.items()
    }
    expected_counts = {
        lane: sum(1 for entry in request_index["requests"] if entry["lane"] == lane)
        for lane in RELEASE_LANES
    }
    for lane in RELEASE_LANES:
        if len(per_lane.get(lane, [])) != expected_counts[lane]:
            raise AggregationError(f"{lane} prepared records do not match the request closure")
    result: dict[tuple[str, int, str], Mapping[str, Any]] = {}
    positions = {lane: 0 for lane in RELEASE_LANES}
    for number, entry in enumerate(request_index["requests"]):
        lane = entry["lane"]
        position = positions[lane]
        raw_record = per_lane[lane][position]
        positions[lane] += 1
        record = _mapping(raw_record, f"prepared records[{number}]")
        _exact_keys(
            record,
            {
                "scene_id", "scale", "lane", "request", "request_sha256",
                "artifact_root", "collector_status_sha256", "machine",
                "measurement_runner", "disposition", "outcome", "prepared",
            },
            f"prepared records[{number}]",
        )
        key = (entry["scene_id"], entry["scale"], entry["lane"])
        if (record["scene_id"], record["scale"], record["lane"]) != key:
            raise AggregationError("prepared records are not in exact request-index order")
        if key in result:
            raise AggregationError("prepared indexes contain a duplicate record")
        request_descriptor = _validate_descriptor(
            record["request"],
            "prepared request descriptor",
            expected_path=(Path("requests") / entry["request"]).as_posix(),
        )
        _digest(record["request_sha256"], "prepared request digest")
        if request_descriptor["sha256"] != record["request_sha256"]:
            raise AggregationError("prepared request digests disagree")
        _digest(record["collector_status_sha256"], "collector status digest")
        try:
            evidence.validate_machine_lane(record["machine"], lane)
            runner = evidence.validate_runner_identity(record["measurement_runner"], lane)
        except evidence.EvidenceError as error:
            raise AggregationError(f"prepared record identity is invalid: {error}") from error
        if runner != request_index["runner_identities"][lane]:
            raise AggregationError("prepared record measurement runner is invalid")
        artifact_root = _safe_relative_path(record["artifact_root"], "prepared artifact root")
        expected_artifact_root = Path(entry["evidence_path"]) / str(entry["scale"]) / lane
        if artifact_root != expected_artifact_root:
            raise AggregationError("prepared artifact root is not canonical")
        prepared = _validate_descriptor(record["prepared"], "prepared evidence descriptor")
        if record["disposition"] == "attestation_candidate":
            if record["outcome"] is not None or prepared["path"] != "evidence.json":
                raise AggregationError("prepared attestation record is invalid")
            kind = "attestation"
        elif record["disposition"] == "lane_outcome":
            try:
                outcome = evidence._validate_lane_outcome_payload(record["outcome"])
            except evidence.EvidenceError as error:
                raise AggregationError(f"prepared lane outcome is invalid: {error}") from error
            if prepared["path"] != "lane-outcome.json":
                raise AggregationError("prepared lane outcome path is invalid")
            kind = outcome["kind"]
        else:
            raise AggregationError("prepared record disposition is invalid")
        result[key] = {
            "scene_id": entry["scene_id"],
            "scale": entry["scale"],
            "lane": lane,
            "kind": kind,
            "evidence": (artifact_root / prepared["path"]).as_posix(),
            "sha256": prepared["sha256"],
            "bytes": prepared["bytes"],
            "collector_status_sha256": record["collector_status_sha256"],
        }
    return result


def _scene_result(
    roots_by_lane: Mapping[str, Path],
    scene: Mapping[str, Any],
    scale: int,
    records: Mapping[tuple[str, int, str], Mapping[str, Any]],
    requests: Mapping[tuple[str, int, str], Mapping[str, Any]],
    runners: Mapping[str, Mapping[str, Any]],
) -> tuple[dict[str, Any], list[Mapping[str, Any]]]:
    attestations: dict[str, Mapping[str, Any]] = {}
    summaries: list[dict[str, Any]] = []
    artifacts: dict[str, str] = {}
    failures: list[str] = []
    blocking: list[str] = []
    receipts: list[Mapping[str, Any]] = []
    for lane in benchmark.required_evidence_lanes(scene, scale):
        key = (scene["id"], scale, lane)
        record = records[key]
        path = roots_by_lane[lane] / _safe_relative_path(
            record["evidence"], "prepared record evidence path"
        )
        value = _load_canonical_json(path, "prepared evidence receipt", MAX_COMPACT_FILE_BYTES)
        if _canonical_value_sha256(value) != record["sha256"]:
            raise AggregationError("prepared evidence receipt digest does not match its index")
        if record["kind"] == "attestation":
            attestation = _validate_prepared_attestation(
                value, requests[key], lane, runners[lane]
            )
            receipts.append(attestation)
            attestations[lane] = attestation
            summaries.append(
                {
                    "lane": lane,
                    "machine": dict(attestation["machine"]),
                    "producer": dict(attestation["producer"]),
                    "measurement_runner": dict(attestation["measurement_runner"]),
                    "evidence_digest": record["sha256"],
                    "collector_status_digest": record["collector_status_sha256"],
                }
            )
            for name, descriptor in attestation["artifacts"].items():
                output_name = f"{lane}_{name}".replace(".", "_").replace("-", "_")
                if benchmark.ARTIFACT_NAME_PATTERN.fullmatch(output_name):
                    artifacts[output_name] = descriptor["sha256"]
        else:
            outcome_receipt = _validate_prepared_lane_outcome(
                value, path, requests[key], lane, runners[lane]
            )
            receipts.append(outcome_receipt)
            outcome = outcome_receipt["outcome"]
            if outcome["kind"] != record["kind"]:
                raise AggregationError("prepared record kind does not match its lane outcome")
            artifacts[f"{lane}_lane_outcome"] = record["sha256"]
            if outcome["kind"] == "execution_failed":
                reason = outcome["reason"].replace("_", " ")
                suffix = f" (exit {outcome['exit_code']})" if outcome["exit_code"] not in {None, 0} else ""
                failures.append(f"{lane} measurement runner {reason}{suffix}")
            elif outcome["kind"] == "environment_rejected":
                blocking.append(f"{lane} timing evidence was rejected by measured host conditions")
            else:
                blocking.append(
                    f"{lane} protected evidence infrastructure {outcome['reason'].replace('_', ' ')}"
                )
    if failures:
        evaluation = {"status": "failed", "blocking_reasons": blocking, "failures": failures}
        metrics: dict[str, Any] = {}
    elif blocking:
        evaluation = {"status": "blocked", "blocking_reasons": blocking, "failures": []}
        metrics = {}
    else:
        evaluation, metrics = benchmark._evaluate_protected_attestations(scene, scale, attestations)
    reference = attestations.get(evidence.LANE_REFERENCE)
    actual = reference.get("actual", {}) if isinstance(reference, Mapping) else {}
    try:
        benchmark._validate_actual_evidence(actual, "reference evidence")
    except benchmark.ConfigError:
        actual = {}
    return (
        {
            "scene_id": scene["id"],
            "category": scene["category"],
            "capture_traits": scene["capture_traits"],
            "scale": scale,
            "aggregate_scale": scene["aggregate_scale"],
            "adapter": "protected-evidence",
            "status": evaluation["status"],
            "blocking_reasons": evaluation["blocking_reasons"],
            "failures": evaluation["failures"],
            "input_kind": scene["input"]["kind"],
            "expected_outcome": scene["expected_outcome"],
            "gate_scopes": scene["gate_scopes"],
            "route": "protected-evidence",
            "detail_profile": "release",
            "exit": {
                "code": actual.get("exit_code"),
                "reason": actual.get("termination_reason", "not_available"),
                "cancelled": actual.get("cancelled", False),
            },
            "command": benchmark._redacted_scene_command(scene, scale),
            "metrics": metrics,
            "artifacts": artifacts,
            "evidence": summaries,
        },
        receipts,
    )


def _load_prepared_roots(
    prepared_roots: Iterable[Path],
) -> tuple[dict[str, Path], dict[str, dict[str, Any]]]:
    supplied = tuple(prepared_roots)
    if len(supplied) != len(RELEASE_LANES):
        raise AggregationError("aggregation requires exactly one prepared root per release lane")
    roots_by_lane: dict[str, Path] = {}
    indexes_by_lane: dict[str, dict[str, Any]] = {}
    roots: list[Path] = []
    for supplied_root in supplied:
        root = _canonical_real_directory(supplied_root, "prepared evidence root")
        if any(root == other or root in other.parents or other in root.parents for other in roots):
            raise AggregationError("prepared evidence roots must be distinct and non-overlapping")
        roots.append(root)
        index = _validate_prepared_index(
            root,
            _load_canonical_json(
                root / PREPARED_INDEX_NAME,
                "prepared index",
                MAX_INDEX_BYTES,
            ),
        )
        lane = index["lane"]
        if lane in roots_by_lane:
            raise AggregationError(f"prepared evidence contains duplicate lane {lane}")
        _scan_compact_tree(root, _expected_tree_files(index))
        roots_by_lane[lane] = root
        indexes_by_lane[lane] = index
    missing = sorted(set(RELEASE_LANES) - set(roots_by_lane))
    extra = sorted(set(roots_by_lane) - set(RELEASE_LANES))
    if missing or extra:
        raise AggregationError(
            "prepared lane closure is incomplete"
            + (f": missing {', '.join(missing)}" if missing else "")
            + (f"; unexpected {', '.join(extra)}" if extra else "")
        )
    return roots_by_lane, indexes_by_lane


def aggregate_evidence(*, prepared_roots: Iterable[Path], output: Path) -> dict[str, Any]:
    _require_clean_worktree()
    roots_by_lane, indexes_by_lane = _load_prepared_roots(prepared_roots)
    destination = _prepare_output(output, roots_by_lane.values())
    root = roots_by_lane[evidence.LANE_REFERENCE]
    requests_root = root / "requests"
    if _canonical_real_directory(requests_root, "prepared requests root") != requests_root:
        raise AggregationError("prepared requests root is not canonical")
    request_index_path = requests_root / "index.json"
    corpus_path = requests_root / "corpus.json"
    config_path = requests_root / "reference-config.json"
    request_index_value = _load_canonical_json(request_index_path, "request index", MAX_INDEX_BYTES)
    corpus = _load_canonical_json(corpus_path, "corpus manifest", MAX_INDEX_BYTES)
    config = _load_canonical_json(config_path, "reference config", MAX_INDEX_BYTES)
    try:
        benchmark.validate_corpus(corpus, expected_profile="release")
        benchmark.validate_reference_config(config)
        contract_digest = benchmark.validate_tracked_benchmark_contract(corpus)
    except benchmark.ConfigError as error:
        raise AggregationError(str(error)) from error
    if len(corpus["scenes"]) != EXPECTED_SCENE_COUNT:
        raise AggregationError(f"release corpus must contain exactly {EXPECTED_SCENE_COUNT} scenes")
    current_commit = _current_git_commit()
    identity = benchmark.RunIdentity(
        profile="release",
        corpus_digest=benchmark.sha256_json(corpus),
        thresholds_digest=benchmark.sha256_json(config),
        git_commit=current_commit,
        app_version=benchmark.APP_VERSION,
        toolchain_identity=indexes_by_lane[evidence.LANE_REFERENCE]["toolchain_identity"],
    )
    try:
        request_index = benchmark.validate_request_index(
            request_index_value, identity, corpus, config
        )
    except benchmark.ConfigError as error:
        raise AggregationError(str(error)) from error
    bindings = {
        "request_index": _canonical_value_sha256(request_index_value),
        "git_commit": request_index["git_commit"],
        "app_version": request_index["app_version"],
        "toolchain_identity": request_index["toolchain_identity"],
        "benchmark_contract_sha256": contract_digest,
        "corpus_manifest": _canonical_value_sha256(corpus),
        "reference_config": _canonical_value_sha256(config),
    }
    for lane, index in indexes_by_lane.items():
        for field in ("git_commit", "app_version", "toolchain_identity", "benchmark_contract_sha256"):
            if index[field] != bindings[field]:
                raise AggregationError(
                    f"{lane} prepared index {field} does not match its protected input"
                )
        for field in ("request_index", "corpus_manifest", "reference_config"):
            descriptor = _validate_descriptor(index[field], f"{lane} {field} descriptor")
            if descriptor["sha256"] != bindings[field]:
                raise AggregationError(
                    f"{lane} prepared index {field} does not match its protected input"
                )
    if request_index["corpus_manifest_sha256"] != bindings["corpus_manifest"]:
        raise AggregationError("request index corpus manifest hash is invalid")
    if request_index["reference_config_sha256"] != bindings["reference_config"]:
        raise AggregationError("request index reference config hash is invalid")
    records = _record_lookup(indexes_by_lane, request_index)
    requests, _ = _load_and_validate_requests(roots_by_lane, request_index, corpus, identity)
    scene_results = []
    all_receipts: list[Mapping[str, Any]] = []
    for scene in corpus["scenes"]:
        for scale in scene["scale_lanes"]:
            scene_result, receipts = _scene_result(
                roots_by_lane, scene, scale, records, requests,
                request_index["runner_identities"],
            )
            scene_results.append(scene_result)
            all_receipts.extend(receipts)
    if len(all_receipts) != EXPECTED_RECORD_COUNT:
        raise AggregationError("prepared evidence receipt closure is incomplete")
    suite_performance = benchmark.evaluate_suite_performance(
        scene_results, benchmark.APPROVED_THRESHOLDS
    )
    suite_quality = benchmark.evaluate_suite_quality(scene_results, benchmark.APPROVED_THRESHOLDS)
    blocking_reasons = [
        f"{item['scene_id']}@{item['scale']}: {reason}"
        for item in scene_results for reason in item["blocking_reasons"]
    ]
    failures = [
        f"{item['scene_id']}@{item['scale']}: {failure}"
        for item in scene_results for failure in item["failures"]
    ]
    blocking_reasons.extend(
        f"suite performance: {reason}" for reason in suite_performance["blocking_reasons"]
    )
    failures.extend(
        f"suite performance: {failure}" for failure in suite_performance["failures"]
    )
    blocking_reasons.extend(
        f"suite quality: {reason}" for reason in suite_quality["blocking_reasons"]
    )
    failures.extend(f"suite quality: {failure}" for failure in suite_quality["failures"])
    status = "failed" if failures else "blocked" if blocking_reasons else "passed"
    first_machine = dict(all_receipts[0]["machine"])
    closure_index = [indexes_by_lane[lane] for lane in RELEASE_LANES]
    index_digest = hashlib.sha256(evidence.canonical_json_bytes(closure_index)).digest()
    started_at = min(
        _canonical_utc_datetime(
            indexes_by_lane[lane]["collection_started_at_utc"],
            f"{lane} collection start",
        )
        for lane in RELEASE_LANES
    ).isoformat().replace("+00:00", "Z")
    ended_at = max(
        _canonical_utc_datetime(
            indexes_by_lane[lane]["collection_ended_at_utc"],
            f"{lane} collection end",
        )
        for lane in RELEASE_LANES
    ).isoformat().replace("+00:00", "Z")
    result = {
        "schema_version": 2,
        "run_id": str(uuid.UUID(bytes=index_digest[:16], version=5)),
        "started_at_utc": started_at,
        "ended_at_utc": ended_at,
        "profile": "release",
        "status": status,
        "blocking_reasons": blocking_reasons,
        "failures": failures,
        "scene_results": scene_results,
        "aggregates": benchmark._aggregate_scene_results(scene_results),
        "machine": first_machine,
        "app_version": benchmark.APP_VERSION,
        "toolchain_identity": request_index["toolchain_identity"],
        "thresholds_digest": request_index["thresholds_digest"],
        "corpus_digest": request_index["corpus_digest"],
        "git": {"commit": current_commit, "dirty": False},
        "raw_evidence_retention": "excluded",
        "missing_requirements": {
            "media": [], "evidence": [], "toolchain": None,
            "request_index": None,
        },
    }
    try:
        benchmark.validate_suite_result(result)
    except benchmark.ConfigError as error:
        raise AggregationError(f"aggregate suite result is invalid: {error}") from error
    try:
        schema = _load_tracked_json(RESULT_SCHEMA_PATH, "benchmark result schema", MAX_INDEX_BYTES)
        validator = Draft202012Validator(schema)
        validator.validate(result)
    except (SchemaError, ValidationError) as error:
        raise AggregationError(f"aggregate suite result does not match its schema: {error.message}") from error
    _write_exclusive_json(destination / "suite.json", result)
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared-root", required=True, type=Path, action="append")
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = aggregate_evidence(prepared_roots=args.prepared_root, output=args.output)
    except (AggregationError, benchmark.ConfigError, evidence.EvidenceError) as error:
        print(f"benchmark aggregation error: {error}", file=sys.stderr)
        return 64
    print(evidence.canonical_json_bytes({"status": result["status"], "result": "suite.json"}).decode("utf-8"))
    return 0 if result["status"] == "passed" else 2 if result["status"] == "blocked" else 1


if __name__ == "__main__":
    raise SystemExit(main())
