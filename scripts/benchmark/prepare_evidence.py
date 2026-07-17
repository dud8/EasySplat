#!/usr/bin/env python3
"""Derive one compact benchmark lane shard from a bounded raw closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, NoReturn

try:
    from scripts.benchmark import easysplat_benchmark as benchmark
    from scripts.benchmark import evidence_protocol as evidence
except ModuleNotFoundError:
    import easysplat_benchmark as benchmark
    import evidence_protocol as evidence


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROTOCOL_VERSION = evidence.PROTOCOL_VERSION
EVIDENCE_PRODUCER_VERSION = evidence.PRODUCER_VERSION
EVIDENCE_PRODUCER_PATH = evidence.PRODUCER_RELATIVE_PATH
COLLECTOR_VERSION = "1.0.0"
COLLECTOR_PATH = "scripts/benchmark/run_lane.py"
PREPARER_VERSION = "2.0.0"
PREPARER_PATH = "scripts/benchmark/prepare_evidence.py"
PREPARED_INDEX_NAME = "prepared-index.json"
RELEASE_LANES = {
    evidence.LANE_REFERENCE,
    evidence.LANE_CONSTRAINED,
    evidence.LANE_EIGHT_GB,
}
MAX_CONTROL_JSON_BYTES = 16 * 1024 * 1024
MAX_OBSERVATIONS_BYTES = 256 * 1024 * 1024
MAX_COLLECTOR_STATUS_BYTES = 1024 * 1024
MAX_COPY_FILES = 200_000
MAX_COPY_BYTES = 64 * 1024**3
PREPARED_EVIDENCE_NAME = "evidence.json"
PREPARED_OUTCOME_NAME = "lane-outcome.json"
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")


class PreparationError(ValueError):
    """Raw evidence cannot produce a safe, internally consistent lane shard."""


def _reject_json_constant(value: str) -> NoReturn:
    raise PreparationError(f"JSON contains non-finite constant {value}")


def _reject_duplicate_keys(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise PreparationError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _require_finite_numbers(value: Any) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise PreparationError("JSON contains a non-finite number")
    if isinstance(value, Mapping):
        for item in value.values():
            _require_finite_numbers(item)
    elif isinstance(value, list):
        for item in value:
            _require_finite_numbers(item)


def _canonical_json_bytes(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as error:
        raise PreparationError("value cannot be encoded as canonical JSON") from error


def _sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _load_bounded_file(path: Path, label: str, maximum_bytes: int) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise PreparationError(f"{label} is missing") from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > maximum_bytes
    ):
        raise PreparationError(f"{label} must be a bounded single-link regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            opened = os.fstat(handle.fileno())
            data = handle.read(maximum_bytes + 1)
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise PreparationError(f"{label} could not be read safely") from error
    stable = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_nlink")
    if (
        len(data) > maximum_bytes
        or not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or any(getattr(opened, field) != getattr(before, field) for field in stable)
        or any(getattr(after, field) != getattr(opened, field) for field in stable)
    ):
        raise PreparationError(f"{label} changed while it was read")
    return data


def _load_json(path: Path, label: str, maximum_bytes: int = MAX_CONTROL_JSON_BYTES) -> Any:
    data = _load_bounded_file(path, label, maximum_bytes)
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
        _require_finite_numbers(value)
    except PreparationError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise PreparationError(f"{label} is not strict JSON") from error
    if data != _canonical_json_bytes(value) + b"\n":
        raise PreparationError(f"{label} is not canonical JSON")
    return value


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise PreparationError(f"could not hash {path.name} safely") from error
    return "sha256:" + digest.hexdigest()


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
    raise PreparationError(f"{label} has invalid fields: {'; '.join(details)}")


def _safe_relative_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise PreparationError(f"{label} must be a canonical relative path")
    relative = PurePosixPath(value)
    if (
        relative.is_absolute()
        or value != relative.as_posix()
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise PreparationError(f"{label} must be a canonical relative path")
    return Path(*relative.parts)


def _canonical_real_directory(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    try:
        metadata = absolute.lstat()
        resolved = absolute.resolve(strict=True)
    except OSError as error:
        raise PreparationError(f"{label} is missing") from error
    if absolute.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        raise PreparationError(f"{label} must be a real directory")
    return resolved


def _absent_output(path: Path) -> tuple[Path, Path]:
    absolute = Path(os.path.abspath(path))
    if absolute.exists() or absolute.is_symlink():
        raise PreparationError("prepared output root must not already exist")
    parent = _canonical_real_directory(absolute.parent, "prepared output parent")
    return parent / absolute.name, parent


def _copy_regular_file(source: Path, destination: Path) -> int:
    try:
        metadata = source.lstat()
    except OSError as error:
        raise PreparationError(f"source file is missing: {source.name}") from error
    if source.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise PreparationError(f"source file is unsafe: {source.name}")
    source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        source_fd = os.open(source, source_flags)
    except OSError as error:
        raise PreparationError(f"source file could not be copied safely: {source.name}") from error
    try:
        destination_fd = os.open(destination, destination_flags, 0o600)
    except OSError as error:
        os.close(source_fd)
        raise PreparationError(f"source file could not be copied safely: {source.name}") from error
    try:
        before = os.fstat(source_fd)
        if before.st_ino != metadata.st_ino or before.st_dev != metadata.st_dev or before.st_nlink != 1:
            raise PreparationError(f"source file changed before copy: {source.name}")
        copied = 0
        while chunk := os.read(source_fd, 1024 * 1024):
            copied += len(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    raise PreparationError(f"source file copy stalled: {source.name}")
                view = view[written:]
        os.fsync(destination_fd)
        after = os.fstat(source_fd)
        if (
            copied != before.st_size
            or after.st_ino != before.st_ino
            or after.st_dev != before.st_dev
            or after.st_size != before.st_size
            or after.st_mtime_ns != before.st_mtime_ns
            or after.st_nlink != 1
        ):
            raise PreparationError(f"source file changed during copy: {source.name}")
        return copied
    finally:
        os.close(source_fd)
        os.close(destination_fd)


def _copy_tree(source_root: Path, destination_root: Path) -> None:
    source_root = _canonical_real_directory(source_root, "raw evidence root")
    destination_root.mkdir(mode=0o700)
    file_count = 0
    byte_count = 0

    def visit(source: Path, destination: Path) -> None:
        nonlocal file_count, byte_count
        for entry in sorted(os.scandir(source), key=lambda item: item.name):
            file_count += 1
            if file_count > MAX_COPY_FILES:
                raise PreparationError("raw evidence contains too many entries")
            source_path = source / entry.name
            destination_path = destination / entry.name
            metadata = source_path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise PreparationError("raw evidence contains a symbolic link")
            if stat.S_ISDIR(metadata.st_mode):
                destination_path.mkdir(mode=0o700)
                visit(source_path, destination_path)
            elif stat.S_ISREG(metadata.st_mode):
                byte_count += _copy_regular_file(source_path, destination_path)
                if byte_count > MAX_COPY_BYTES:
                    raise PreparationError("raw evidence exceeds its size limit")
            else:
                raise PreparationError("raw evidence contains a special file")

    visit(source_root, destination_root)


def _write_exclusive_json(path: Path, value: Any, label: str) -> None:
    data = _canonical_json_bytes(value) + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as error:
        raise PreparationError(f"{label} could not be written exclusively") from error


def _current_git_commit() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise PreparationError("current Git commit could not be resolved") from error
    commit = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise PreparationError("current Git commit is invalid")
    return commit


def _source_identity(path: str, version: str) -> dict[str, Any]:
    return {"version": version, "executable": path, "sha256": _sha256_file(REPOSITORY_ROOT / path)}


def _canonical_utc(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise PreparationError(f"{label} must be canonical UTC")
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise PreparationError(f"{label} must be canonical UTC") from error
    if parsed.tzinfo != timezone.utc or parsed.isoformat().replace("+00:00", "Z") != value:
        raise PreparationError(f"{label} must be canonical UTC")
    return value


def _validate_lane_result(
    raw_root: Path,
    index: Mapping[str, Any],
    lane: str,
    selected: list[Mapping[str, Any]],
) -> tuple[dict[str, Any], dict[tuple[str, int, str], str], Path]:
    path = raw_root / f"lane-{lane}.json"
    result = _mapping(_load_json(path, "lane result"), "lane result")
    _exact_keys(
        result,
        {
            "schema_version", "lane", "machine", "git_commit", "corpus_digest",
            "thresholds_digest", "toolchain_identity", "producer_digest",
            "runner_identity", "rendering_driver_identity", "collections",
            "collection_started_at_utc", "collection_ended_at_utc",
        },
        "lane result",
    )
    try:
        evidence.validate_machine_lane(result["machine"], lane)
        runner = evidence.validate_runner_identity(result["runner_identity"], lane)
    except evidence.EvidenceError as error:
        raise PreparationError(f"lane result identity is invalid: {error}") from error
    expected_bindings = {
        "schema_version": 1,
        "lane": lane,
        "git_commit": index["git_commit"],
        "corpus_digest": index["corpus_digest"],
        "thresholds_digest": index["thresholds_digest"],
        "toolchain_identity": index["toolchain_identity"],
        "producer_digest": index["producer_digest"],
        "runner_identity": index["runner_identities"][lane],
        "rendering_driver_identity": index["runner_identities"][evidence.RENDERING_DRIVER_IDENTITY],
    }
    for field, expected in expected_bindings.items():
        if result[field] != expected:
            raise PreparationError(f"lane result {field} does not match its request index")
    if runner != index["runner_identities"][lane]:
        raise PreparationError("lane result runner identity does not match its request index")
    started = _canonical_utc(result["collection_started_at_utc"], "collection start")
    ended = _canonical_utc(result["collection_ended_at_utc"], "collection end")
    started_value = datetime.fromisoformat(started.removesuffix("Z") + "+00:00")
    ended_value = datetime.fromisoformat(ended.removesuffix("Z") + "+00:00")
    if started_value > ended_value:
        raise PreparationError("lane result collection timestamps are reversed")
    collections = result["collections"]
    if not isinstance(collections, list) or len(collections) != len(selected):
        raise PreparationError("lane result does not contain the exact request closure")
    digests: dict[tuple[str, int, str], str] = {}
    for number, (collection_value, entry) in enumerate(zip(collections, selected, strict=True)):
        collection = _mapping(collection_value, f"lane collection[{number}]")
        _exact_keys(
            collection,
            {"scene_id", "scale", "lane", "collector_status", "sha256"},
            f"lane collection[{number}]",
        )
        key = (entry["scene_id"], entry["scale"], lane)
        expected_path = (
            Path(entry["evidence_path"])
            / str(entry["scale"])
            / lane
            / "collector-status.json"
        ).as_posix()
        if (
            (collection["scene_id"], collection["scale"], collection["lane"]) != key
            or collection["collector_status"] != expected_path
            or not isinstance(collection["sha256"], str)
            or not SHA256_PATTERN.fullmatch(collection["sha256"])
            or key in digests
        ):
            raise PreparationError("lane result collections are malformed or out of order")
        digests[key] = collection["sha256"]
    return dict(result), digests, path


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise PreparationError(f"{label} must be an object")
    return value


def _validate_outcome(value: Any) -> dict[str, Any]:
    try:
        return evidence._validate_lane_outcome_payload(value)
    except evidence.EvidenceError as error:
        raise PreparationError(str(error)) from error


def _descriptor(path: Path, root: Path) -> dict[str, Any]:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise PreparationError("prepared file escapes its output root") from error
    metadata = path.lstat()
    if path.is_symlink() or not path.is_file() or metadata.st_nlink != 1 or metadata.st_size <= 0:
        raise PreparationError("prepared file is unsafe")
    return {
        "path": relative,
        "sha256": _sha256_file(path),
        "bytes": metadata.st_size,
    }


def _validate_collector_status(
    artifact_root: Path,
    request: Mapping[str, Any],
    lane: str,
    runner: Mapping[str, Any],
) -> dict[str, Any]:
    status_path = artifact_root / "collector-status.json"
    status = _mapping(
        _load_json(status_path, "collector status", MAX_COLLECTOR_STATUS_BYTES),
        "collector status",
    )
    _exact_keys(
        status,
        {
            "schema_version",
            "request_sha256",
            "lane",
            "machine",
            "measurement_runner",
            "collector",
            "disposition",
            "outcome",
        },
        "collector status",
    )
    request_sha256 = _sha256_bytes(_canonical_json_bytes(request))
    try:
        evidence.validate_machine_lane(status["machine"], lane)
        validated_runner = evidence.validate_runner_identity(status["measurement_runner"], lane)
    except evidence.EvidenceError as error:
        raise PreparationError(f"collector status identity is invalid: {error}") from error
    if (
        status["schema_version"] != 1
        or status["request_sha256"] != request_sha256
        or status["lane"] != lane
        or validated_runner != runner
    ):
        raise PreparationError("collector status request binding is invalid")
    collector = _mapping(status["collector"], "collector identity")
    _exact_keys(
        collector,
        {"protocol_version", "version", "executable", "sha256"},
        "collector identity",
    )
    if dict(collector) != {
        "protocol_version": PROTOCOL_VERSION,
        "version": COLLECTOR_VERSION,
        "executable": COLLECTOR_PATH,
        "sha256": _sha256_file(REPOSITORY_ROOT / COLLECTOR_PATH),
    }:
        raise PreparationError("collector status does not match this checkout")
    disposition = status["disposition"]
    if disposition == "attestation_candidate":
        if status["outcome"] is not None:
            raise PreparationError("attestation candidate cannot declare a lane outcome")
        outcome = None
    elif disposition == "lane_outcome":
        outcome = _validate_outcome(status["outcome"])
    else:
        raise PreparationError("collector status disposition is invalid")
    environment_path = artifact_root / "measurement-environment.json"
    requires_environment = outcome is not None and outcome["kind"] == "environment_rejected"
    if requires_environment != (environment_path.exists() or environment_path.is_symlink()):
        raise PreparationError("collector status environment receipt presence is invalid")
    return {
        "machine": dict(status["machine"]),
        "measurement_runner": validated_runner,
        "disposition": disposition,
        "outcome": outcome,
        "collector_status_sha256": _sha256_file(status_path),
        "request_sha256": request_sha256,
    }


def _validate_index(
    requests_root: Path,
    index_path: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    requests_root = _canonical_real_directory(requests_root, "requests root")
    expected_index = requests_root / "index.json"
    if index_path.resolve(strict=True) != expected_index:
        raise PreparationError("request index must be requests-root/index.json")
    index = _mapping(_load_json(expected_index, "request index"), "request index")
    corpus = _mapping(_load_json(requests_root / "corpus.json", "corpus manifest"), "corpus manifest")
    config = _mapping(
        _load_json(requests_root / "reference-config.json", "reference config"),
        "reference config",
    )
    try:
        benchmark.validate_corpus(corpus, expected_profile="release")
        benchmark.validate_reference_config(config)
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest=index["corpus_digest"],
            thresholds_digest=index["thresholds_digest"],
            git_commit=_current_git_commit(),
            app_version=benchmark.APP_VERSION,
            toolchain_identity=index["toolchain_identity"],
        )
        validated = benchmark.validate_request_index(index, identity, corpus, config)
    except (benchmark.ConfigError, KeyError, TypeError) as error:
        raise PreparationError(f"request index is invalid: {error}") from error
    if validated["benchmark_contract_sha256"] != benchmark.benchmark_contract_sha256(corpus):
        raise PreparationError("request index benchmark contract is invalid")
    return validated, dict(corpus), dict(config)


def _copy_control_file(source: Path, destination: Path, expected_sha256: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    _copy_regular_file(source, destination)
    if _sha256_file(destination) != expected_sha256:
        raise PreparationError(f"{source.name} changed while preparing evidence")


def _derive_one(
    *,
    request: Mapping[str, Any],
    artifact_root: Path,
    lane: str,
    runner: Mapping[str, Any],
    compact_root: Path,
    artifact_relative: Path,
) -> dict[str, Any]:
    status = _validate_collector_status(artifact_root, request, lane, runner)
    destination = compact_root / artifact_relative
    destination.mkdir(parents=True, mode=0o700)
    if status["disposition"] == "attestation_candidate":
        observations = _mapping(
            _load_json(artifact_root / "observations.json", "raw observations", MAX_OBSERVATIONS_BYTES),
            "raw observations",
        )
        prepared_path = destination / PREPARED_EVIDENCE_NAME
        try:
            prepared_value = evidence.derive_attestation(
                request,
                observations,
                artifact_root,
                prepared_path,
                lane,
                runner,
                machine=status["machine"],
                enforce_environment_policy=True,
            )
        except evidence.EvidenceError as error:
            raise PreparationError(f"raw attestation candidate is invalid: {error}") from error
    else:
        outcome = status["outcome"]
        assert isinstance(outcome, Mapping)
        environment_path = (
            artifact_root / "measurement-environment.json"
            if outcome["kind"] == "environment_rejected"
            else None
        )
        environment_receipt = (
            _mapping(
                _load_json(
                    environment_path,
                    "measurement environment receipt",
                    MAX_OBSERVATIONS_BYTES,
                ),
                "measurement environment receipt",
            )
            if environment_path is not None
            else None
        )
        prepared_path = destination / PREPARED_OUTCOME_NAME
        try:
            prepared_value = evidence.derive_lane_outcome(
                request,
                lane,
                runner,
                status["machine"],
                kind=outcome["kind"],
                reason=outcome["reason"],
                exit_code=outcome["exit_code"],
                environment_receipt_path=environment_path,
            )
        except evidence.EvidenceError as error:
            raise PreparationError(f"raw lane outcome is invalid: {error}") from error
        if environment_path is not None:
            assert environment_receipt is not None
            environment_descriptor = _mapping(
                prepared_value["environment_receipt"],
                "prepared environment receipt",
            )
            prepared_environment_path = destination / "measurement-environment.json"
            _copy_control_file(
                environment_path,
                prepared_environment_path,
                environment_descriptor["sha256"],
            )
            if _descriptor(prepared_environment_path, destination) != environment_descriptor:
                raise PreparationError(
                    "prepared environment receipt does not match its lane outcome"
                )
            measurement_environment = _mapping(
                environment_receipt.get("measurement_environment"),
                "measurement environment",
            )
            monitor_sha256 = measurement_environment.get("monitor_sha256")
            if (
                not isinstance(monitor_sha256, str)
                or not SHA256_PATTERN.fullmatch(monitor_sha256)
            ):
                raise PreparationError("measurement environment monitor digest is invalid")
            _copy_control_file(
                artifact_root / "host-monitor.json",
                destination / "host-monitor.json",
                monitor_sha256,
            )
    _write_exclusive_json(prepared_path, prepared_value, "prepared evidence")
    return {
        "status": status,
        "prepared": _descriptor(prepared_path, destination),
    }


def prepare_lane_evidence(
    *,
    index_path: Path,
    requests_root: Path,
    raw_evidence_root: Path,
    output_root: Path,
    lane: str,
) -> dict[str, Any]:
    if lane not in RELEASE_LANES:
        raise PreparationError("unsupported release lane")
    raw_root = _canonical_real_directory(raw_evidence_root, "raw evidence root")
    output, output_parent = _absent_output(output_root)
    if output == raw_root or output in raw_root.parents or raw_root in output.parents:
        raise PreparationError("raw and prepared roots must be distinct and non-overlapping")
    index, _, _ = _validate_index(requests_root, index_path)
    selected = [entry for entry in index["requests"] if entry["lane"] == lane]
    if not selected:
        raise PreparationError(f"request index contains no {lane} records")
    lane_result, lane_collection_digests, lane_result_path = _validate_lane_result(
        raw_root,
        index,
        lane,
        selected,
    )

    build_root = Path(tempfile.mkdtemp(prefix=f".{output.name}.prepare-", dir=output_parent))
    raw_workspace = Path(tempfile.mkdtemp(prefix=".raw-evidence-", dir=output_parent))
    try:
        requests_destination = build_root / "requests"
        requests_destination.mkdir(mode=0o700)
        request_index_sha = _sha256_file(index_path)
        _copy_control_file(index_path, requests_destination / "index.json", request_index_sha)
        _copy_control_file(
            Path(requests_root) / "corpus.json",
            requests_destination / "corpus.json",
            index["corpus_manifest_sha256"],
        )
        _copy_control_file(
            Path(requests_root) / "reference-config.json",
            requests_destination / "reference-config.json",
            index["reference_config_sha256"],
        )
        _copy_control_file(
            lane_result_path,
            build_root / "lane-result.json",
            _sha256_file(lane_result_path),
        )

        records = []
        runner = evidence.validate_runner_identity(index["runner_identities"][lane], lane)
        for entry in selected:
            request_relative = _safe_relative_path(entry["request"], "request path")
            request_source = Path(requests_root) / request_relative
            request_destination = requests_destination / request_relative
            request_sha = _sha256_file(request_source)
            _copy_control_file(request_source, request_destination, request_sha)
            request = _mapping(_load_json(request_destination, "evidence request"), "evidence request")
            try:
                request = dict(evidence.validate_request(request))
            except evidence.EvidenceError as error:
                raise PreparationError(f"evidence request is invalid: {error}") from error
            for field in (
                "corpus_digest",
                "thresholds_digest",
                "git_commit",
                "app_version",
                "toolchain_identity",
                "baseline_git_commit",
                "baseline_toolchain_identity",
                "baseline_configuration_digest",
                "benchmark_contract_sha256",
            ):
                if request["binding"][field] != index[field]:
                    raise PreparationError(f"request {field} does not match its index")
            artifact_relative = (
                _safe_relative_path(entry["evidence_path"], "evidence path")
                / str(entry["scale"])
                / lane
            )
            raw_source = raw_root / artifact_relative
            raw_artifact_root = raw_workspace / artifact_relative
            raw_artifact_root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            # The no-secret process snapshots only this lane's indexed closure.
            try:
                _copy_tree(raw_source, raw_artifact_root)
                derived = _derive_one(
                    request=request,
                    artifact_root=raw_artifact_root,
                    lane=lane,
                    runner=runner,
                    compact_root=build_root,
                    artifact_relative=artifact_relative,
                )
            finally:
                shutil.rmtree(raw_artifact_root, ignore_errors=True)
            status = derived["status"]
            key = (entry["scene_id"], entry["scale"], lane)
            if status["collector_status_sha256"] != lane_collection_digests[key]:
                raise PreparationError("collector status digest does not match its lane result")
            records.append(
                {
                    "scene_id": entry["scene_id"],
                    "scale": entry["scale"],
                    "lane": lane,
                    "request": _descriptor(request_destination, build_root),
                    "request_sha256": status["request_sha256"],
                    "artifact_root": artifact_relative.as_posix(),
                    "collector_status_sha256": status["collector_status_sha256"],
                    "machine": status["machine"],
                    "measurement_runner": status["measurement_runner"],
                    "disposition": status["disposition"],
                    "outcome": status["outcome"],
                    "prepared": derived["prepared"],
                }
            )

        prepared_index = {
            "schema_version": 2,
            "lane": lane,
            "git_commit": index["git_commit"],
            "protocol_version": PROTOCOL_VERSION,
            "app_version": index["app_version"],
            "toolchain_identity": index["toolchain_identity"],
            "benchmark_contract_sha256": index["benchmark_contract_sha256"],
            "collection_started_at_utc": lane_result["collection_started_at_utc"],
            "collection_ended_at_utc": lane_result["collection_ended_at_utc"],
            "sources": {
                "evidence_protocol": _source_identity(
                    EVIDENCE_PRODUCER_PATH,
                    EVIDENCE_PRODUCER_VERSION,
                ),
                "collector": _source_identity(
                    COLLECTOR_PATH,
                    COLLECTOR_VERSION,
                ),
                "preparer": _source_identity(
                    PREPARER_PATH,
                    PREPARER_VERSION,
                ),
            },
            "request_index": _descriptor(requests_destination / "index.json", build_root),
            "corpus_manifest": _descriptor(requests_destination / "corpus.json", build_root),
            "reference_config": _descriptor(
                requests_destination / "reference-config.json",
                build_root,
            ),
            "lane_result": _descriptor(build_root / "lane-result.json", build_root),
            "records": records,
        }
        _write_exclusive_json(
            build_root / PREPARED_INDEX_NAME,
            prepared_index,
            "prepared index",
        )
        if output.exists() or output.is_symlink():
            raise PreparationError("prepared output root appeared during derivation")
        os.rename(build_root, output)
        return prepared_index
    except evidence.EvidenceError as error:
        raise PreparationError(str(error)) from error
    finally:
        shutil.rmtree(build_root, ignore_errors=True)
        shutil.rmtree(raw_workspace, ignore_errors=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--requests-root", required=True, type=Path)
    parser.add_argument("--raw-evidence-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--lane", required=True, choices=sorted(RELEASE_LANES))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = prepare_lane_evidence(
            index_path=args.index,
            requests_root=args.requests_root,
            raw_evidence_root=args.raw_evidence_root,
            output_root=args.output_root,
            lane=args.lane,
        )
    except (PreparationError, OSError, UnicodeError, ValueError) as error:
        print(f"error: {error}", file=os.sys.stderr)
        return 2
    print(
        json.dumps(
            {"status": "prepared", "lane": result["lane"], "records": len(result["records"])},
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
