#!/usr/bin/env python3
"""Run a paired mapper-cadence experiment from a reproduced matching checkpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, NoReturn

try:
    from scripts.benchmark import colmap_mapping_profile
    from scripts.benchmark import evidence_protocol as evidence
    from scripts.benchmark import mapper_cadence_request as request_contract
except ModuleNotFoundError:
    import colmap_mapping_profile  # type: ignore[no-redef]
    import evidence_protocol as evidence  # type: ignore[no-redef]
    import mapper_cadence_request as request_contract  # type: ignore[no-redef]


MAXIMUM_ENVELOPE_BYTES = 16 * 1024 * 1024
MAXIMUM_LOG_BYTES = 64 * 1024 * 1024
MAXIMUM_ADAPTER_STDERR_TAIL_BYTES = 16 * 1024
SHA256_FIELDS = (
    "request_sha256",
    "resolved_plan_binding_sha256",
    "colmap_runtime_closure_sha256",
    "selection_manifest_sha256",
    "selected_frames_digest",
    "pair_graph_evidence_sha256",
    "worker_execution_sha256",
    "pair_list_digest",
    "feature_database_digest",
    "matching_database_digest",
    "database_file_sha256",
)
MATCHING_CLOSURE_FIELDS = (
    "request_sha256",
    "execution_assurance",
    "evidence_class",
    "request_kind",
    "source_provenance_scope",
    "source_tree_state",
    "toolchain_provenance_status",
    "adapter_executable_bytes",
    "adapter_executable_sha256",
    "fixed_mapper_options",
    "fixed_mapper_options_sha256",
    "cadence_schedule_sha256",
    "quality_thresholds_sha256",
    "experiment_contract_sha256",
    "resolved_plan_binding_sha256",
    "colmap_runtime_closure_sha256",
    "selection_manifest_sha256",
    "selected_frames_digest",
    "pair_list_digest",
    "feature_database_digest",
    "matching_database_digest",
    "deterministic_seed",
    "database_project_relative_path",
    "selection_manifest",
    "pair_graph_evidence",
    "worker_execution",
    "pipeline_log",
    "selected_image_count",
    "selected_image_names",
    "pair_graph_schema_version",
    "worker_execution_schema_version",
    "pairing_policy",
    "pair_attempt_ordinal",
    "descriptor_matcher",
    "colmap_compute_mode",
    "fallback_reasons",
    "recovery_level",
    "exact_recovery_reason",
    "rejected_vocabulary_retrieval_count",
    "rejected_vocabulary_retrieval_history",
    "scheduled_pair_count",
    "attempted_pair_count",
    "raw_matched_pair_count",
    "spatially_verified_pair_count",
    "local_pair_count",
    "retrieval_pair_count",
    "loop_revisit_pair_count",
    "connected_component_count",
    "component_view_counts",
    "isolated_view_count",
    "descriptorless_view_count",
    "articulation_view_count",
    "biconnected_block_count",
    "largest_biconnected_block_view_count",
    "second_largest_biconnected_block_view_count",
    "degree_p10",
    "degree_median",
    "degree_p90",
    "feature_invocation_count",
    "matching_invocation_count",
    "retrieval_invocation_count",
)
TRIAL_BINDING_FIELDS = (
    "request_sha256",
    "resolved_plan_binding_sha256",
    "deterministic_seed",
    "colmap_runtime_closure_sha256",
    "selection_manifest_sha256",
    "selected_frames_digest",
    "selected_image_names",
    "pair_graph_evidence_sha256",
    "pair_list_digest",
    "feature_database_digest",
    "matching_database_digest",
)
AGGREGATE_FIELDS = (
    "mapping_elapsed_seconds",
    "peak_memory_bytes",
    "registered_views",
    "point_count",
    "observation_count",
    "median_residual_pixels",
    "p90_residual_pixels",
)
CONDITIONING_PROVENANCE = "colmap-text-conditioning-v2"
CONDITIONING_INTEGER_FIELDS = (
    "pointCount",
    "observationCount",
    "positiveDepthObservationCount",
    "stronglyMeasuredViewCount",
    "registeredViewCount",
    "perViewObservationMinimum",
    "perViewObservationP10",
    "perViewObservationP90",
    "distinctTrackLengthMinimum",
    "distinctTrackLengthP10",
    "distinctTrackLengthP90",
    "pointsAtLeast1Point5Degrees",
    "pointsAtLeast2Degrees",
    "pointsAtLeast3Degrees",
    "observationsAtLeast1Point5Degrees",
    "observationsAtLeast2Degrees",
    "observationsAtLeast3Degrees",
    "effectiveCameraCenterCount",
    "largestCameraCenterClusterSize",
    "numericallyConditionedPointCount",
    "numericallyConditionedObservationCount",
    "cameraPairEvaluationCount",
    "rayPairEvaluationCount",
)
CONDITIONING_NUMBER_FIELDS = (
    "perViewObservationMedian",
    "distinctTrackLengthMedian",
    "medianObservedDepth",
    "cameraBaselineToMedianDepthRatio",
    "cameraCenterMergeToleranceToMedianDepthRatio",
    "adaptiveParallaxThresholdMedianDegrees",
    "adaptiveParallaxThresholdP90Degrees",
)
CONDITIONING_EIGENVALUE_FIELDS = (
    "cameraCenterEigenvalues",
    "pointEigenvalues",
)
CONDITIONING_FIELDS = frozenset(
    (*CONDITIONING_INTEGER_FIELDS, *CONDITIONING_NUMBER_FIELDS, *CONDITIONING_EIGENVALUE_FIELDS)
)
SOURCE_DATABASE_EVIDENCE_FIELDS = frozenset(
    {
        "source_name",
        "parent_device_id",
        "parent_inode",
        "device_id",
        "inode",
        "link_count",
        "byte_count",
        "mode",
        "owner_uid",
        "owner_gid",
        "modified_seconds",
        "modified_nanoseconds",
        "changed_seconds",
        "changed_nanoseconds",
        "companion_names",
        "sha256",
    }
)
CLONE_DATABASE_PRE_RUN_EVIDENCE_FIELDS = frozenset(
    {
        "trial_ordinal",
        "trial_name",
        "destination_name",
        "destination_parent_device_id",
        "destination_parent_inode",
        "clone_strategy",
        "destination_device_id",
        "destination_inode",
        "destination_link_count",
        "destination_byte_count",
        "destination_mode",
        "destination_owner_uid",
        "destination_owner_gid",
        "destination_modified_seconds",
        "destination_modified_nanoseconds",
        "destination_changed_seconds",
        "destination_changed_nanoseconds",
        "destination_sha256",
    }
)
CLONE_DATABASE_POST_RUN_EVIDENCE_FIELDS = frozenset(
    CLONE_DATABASE_PRE_RUN_EVIDENCE_FIELDS
    - {"trial_ordinal", "trial_name", "clone_strategy"}
)
RECOVERY_LEVELS = frozenset({"normal", "expanded", "maximum"})
EXACT_RECOVERY_REASONS = frozenset(
    {
        "faissCrash",
        "faissUnsupportedOperation",
        "faissGeometryRejectedAfterRetries",
    }
)
REJECTED_RETRIEVAL_FIELDS = frozenset(
    {
        "retrieval_attempt_ordinal",
        "pair_attempt_ordinal",
        "pairing_policy",
        "recovery_level",
        "selected_view_count",
        "query_count",
        "no_ranked_neighbor_query_count",
        "candidate_count",
        "returned_neighbor_count",
        "retrieval_request_digest",
        "retrieval_output_digest",
    }
)
MATCHING_ENVELOPE_FIELDS = frozenset(
    {
        "schema_version",
        "measurement_scope",
        "variant",
        "started_monotonic_seconds",
        "ended_monotonic_seconds",
        "project_root",
        "database_path",
        "database_project_relative_path",
        "selection_manifest",
        "pair_graph_evidence",
        "worker_execution",
        "pipeline_log",
        *MATCHING_CLOSURE_FIELDS,
        "pair_graph_evidence_sha256",
        "worker_execution_sha256",
        "database_file_sha256",
        "database_file_bytes",
        "database_source_device_id",
        "database_source_inode",
        "database_source_mode",
        "matching_duration_seconds",
        "pipeline_stage_seconds",
        "stage_seconds",
        "peak_memory_bytes",
    }
)
TRIAL_ENVELOPE_FIELDS = frozenset(
    {
        "schema_version",
        "measurement_scope",
        "trial_name",
        "trial_ordinal",
        "discarded",
        "mapper_cadence",
        "ba_global_frames_ratio",
        "ba_global_points_ratio",
        "ba_global_max_refinements",
        "request_sha256",
        "execution_assurance",
        "evidence_class",
        "request_kind",
        "source_provenance_scope",
        "source_tree_state",
        "toolchain_provenance_status",
        "adapter_executable_bytes",
        "adapter_executable_sha256",
        "resolved_plan_binding_sha256",
        "deterministic_seed",
        "colmap_runtime_closure_sha256",
        "selection_manifest_sha256",
        "selected_frames_digest",
        "selected_image_names",
        "pair_graph_evidence_sha256",
        "pair_list_digest",
        "feature_database_digest",
        "matching_database_digest",
        "source_database_initial_evidence",
        "source_database_final_evidence",
        "clone_database_pre_run_evidence",
        "clone_database_post_run_evidence",
        "clone_feature_database_digest_after",
        "clone_matching_database_digest_after",
        "clone_database_companion_names",
        "output_root",
        "fixed_mapper_options",
        "fixed_mapper_options_sha256",
        "cadence_schedule_sha256",
        "quality_thresholds_sha256",
        "experiment_contract_sha256",
        "point_track_topology_digest",
        "mapping_elapsed_seconds",
        "peak_memory_bytes",
        "registered_views",
        "registered_image_names",
        "point_count",
        "observation_count",
        "median_residual_pixels",
        "p90_residual_pixels",
        "conditioning_status",
        "conditioning_provenance",
        "conditioning_measurement",
        "camera_poses_wxyz_xyz",
        "model_sha256",
        "model_hashes",
        "mapped_model_order",
        "mapper_log",
        "mapper_log_sha256",
        "mapper_log_bytes",
    }
)
MODEL_HASH_FIELDS = frozenset({"cameras.txt", "images.txt", "points3D.txt"})
EXECUTION_ASSURANCE = {
    "level": "observational",
    "mutation_threat_model": "no_concurrent_same_uid_mutation",
    "runner_isolation_mode": "owner_private_local_process",
    "child_database_binding": "pre_post_descriptor_path",
    "child_database_open_inode_verified": False,
    "child_runtime_binding": "pre_post_closure_path",
    "child_runtime_exec_inode_verified": False,
    "release_gate_eligible": False,
}


class CadenceExperimentError(RuntimeError):
    """The experiment could not produce internally consistent paired measurements."""


def _reject_constant(value: str) -> NoReturn:
    raise CadenceExperimentError(f"JSON contains non-finite constant {value}")


def _reject_duplicate_keys(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CadenceExperimentError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _integer(value: Any, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise CadenceExperimentError(f"{label} must be an integer at least {minimum}")
    return value


def _number(value: Any, label: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CadenceExperimentError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or (result <= 0 if positive else result < 0):
        qualifier = "finite and positive" if positive else "finite and nonnegative"
        raise CadenceExperimentError(f"{label} must be {qualifier}")
    return result


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise CadenceExperimentError(f"{label} must be a nonempty string")
    return value


def _sha256(value: Any, label: str) -> str:
    result = _string(value, label)
    if len(result) != 64 or any(character not in "0123456789abcdef" for character in result):
        raise CadenceExperimentError(f"{label} must be a lowercase SHA-256 digest")
    return result


def _absolute_path(value: Any, label: str) -> Path:
    result = Path(_string(value, label))
    if not result.is_absolute() or ".." in result.parts:
        raise CadenceExperimentError(f"{label} must be a normalized absolute path")
    return result


def _relative_path(value: Any, label: str) -> PurePosixPath:
    result = PurePosixPath(_string(value, label))
    if result.is_absolute() or not result.parts or any(part in {"", ".", ".."} for part in result.parts):
        raise CadenceExperimentError(f"{label} must be a safe relative path")
    return result


def _require_owned_path(
    path: Path,
    label: str,
    *,
    regular: bool = False,
    directory: bool = False,
    executable: bool = False,
) -> os.stat_result:
    if not path.is_absolute():
        raise CadenceExperimentError(f"{label} must be absolute")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CadenceExperimentError(f"{label} is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise CadenceExperimentError(f"{label} must be owned by the current user and not be a symlink")
    if regular and (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1):
        raise CadenceExperimentError(f"{label} must be a single-link regular file")
    if directory and not stat.S_ISDIR(metadata.st_mode):
        raise CadenceExperimentError(f"{label} must be a directory")
    if executable and not os.access(path, os.X_OK):
        raise CadenceExperimentError(f"{label} must be executable")
    return metadata


def _read_regular_bytes(path: Path, label: str, maximum: int) -> bytes:
    before = _require_owned_path(path, label, regular=True)
    if not 0 < before.st_size <= maximum:
        raise CadenceExperimentError(f"{label} has an invalid size")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise CadenceExperimentError(f"{label} changed while opening")
            chunks: list[bytes] = []
            remaining = maximum + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
        finally:
            os.close(descriptor)
    except OSError as error:
        raise CadenceExperimentError(f"unable to read {label}") from error
    data = b"".join(chunks)
    after = _require_owned_path(path, label, regular=True)
    if (after.st_dev, after.st_ino, after.st_size) != (
        before.st_dev,
        before.st_ino,
        before.st_size,
    ):
        raise CadenceExperimentError(f"{label} changed while reading")
    if len(data) != before.st_size:
        raise CadenceExperimentError(f"{label} was not read completely")
    return data


def _load_json(path: Path, label: str) -> dict[str, Any]:
    data = _read_regular_bytes(path, label, MAXIMUM_ENVELOPE_BYTES)
    try:
        value = json.loads(
            data,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CadenceExperimentError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise CadenceExperimentError(f"{label} must contain a JSON object")
    return value


def _create_private_directory(parent: Path, name: str) -> Path:
    if not name or "/" in name or name in {".", ".."}:
        raise CadenceExperimentError("internal run directory name is invalid")
    path = parent / name
    try:
        path.mkdir(mode=0o700)
    except OSError as error:
        raise CadenceExperimentError(f"unable to create run directory {name}") from error
    metadata = _require_owned_path(path, f"run directory {name}", directory=True)
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise CadenceExperimentError(f"run directory {name} is not owner-private")
    return path


def _invoke_adapter(adapter: Path, arguments: list[str], output: Path) -> dict[str, Any]:
    if output.exists() or output.is_symlink():
        raise CadenceExperimentError("adapter output already exists")
    read_descriptor, write_descriptor = os.pipe()
    try:
        process = subprocess.Popen(
            [str(adapter), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=write_descriptor,
        )
    except OSError as error:
        os.close(read_descriptor)
        os.close(write_descriptor)
        raise CadenceExperimentError("unable to execute the current adapter") from error
    os.close(write_descriptor)
    stderr_tail = bytearray()
    try:
        while True:
            chunk = os.read(read_descriptor, 64 * 1024)
            if not chunk:
                break
            if len(chunk) >= MAXIMUM_ADAPTER_STDERR_TAIL_BYTES:
                stderr_tail = bytearray(chunk[-MAXIMUM_ADAPTER_STDERR_TAIL_BYTES :])
            else:
                stderr_tail.extend(chunk)
                overflow = len(stderr_tail) - MAXIMUM_ADAPTER_STDERR_TAIL_BYTES
                if overflow > 0:
                    del stderr_tail[:overflow]
        return_code = process.wait()
    except BaseException:
        process.terminate()
        process.wait()
        raise
    finally:
        os.close(read_descriptor)
    if return_code != 0:
        message = f"adapter exited with status {return_code}"
        detail = _display_adapter_stderr_tail(bytes(stderr_tail))
        if detail:
            message += f"\nadapter stderr tail:\n{detail}"
        raise CadenceExperimentError(message)
    if not output.exists():
        raise CadenceExperimentError("adapter did not publish its evidence envelope")
    return _load_json(output, "adapter evidence envelope")


def _display_adapter_stderr_tail(data: bytes) -> str:
    text = data.decode("utf-8", errors="replace")
    cleaned: list[str] = []
    for character in text:
        codepoint = ord(character)
        if character == "\r":
            cleaned.append("\n")
        elif character in {"\n", "\t"} or (codepoint >= 32 and codepoint != 127):
            cleaned.append(character)
        else:
            cleaned.append("�")
    return "".join(cleaned).strip()


def _base_adapter_arguments(
    request: Path,
    input_path: Path,
    toolchain_root: Path,
    project_root: Path,
    output: Path,
) -> list[str]:
    return [
        "--request",
        str(request),
        "--input",
        str(input_path),
        "--toolchain-root",
        str(toolchain_root),
        "--project-root",
        str(project_root),
        "--variant",
        "candidate",
        "--output",
        str(output),
    ]


def _load_bound_request(
    request: Path,
    *,
    input_path: Path,
    adapter: Path,
    toolchain_root: Path,
    runtime_closure_sha256: str,
    runner_closure_identity: Path | None,
    runner_closure_root: Path | None,
) -> dict[str, Any]:
    try:
        return request_contract.load_and_validate_request(
            request,
            input_path=input_path,
            adapter_executable=adapter,
            colmap_runtime_root=toolchain_root,
            colmap_runtime_closure_sha256=runtime_closure_sha256,
            measurement_runner_closure_identity=runner_closure_identity,
            measurement_runner_closure_root=runner_closure_root,
        )
    except request_contract.MapperCadenceRequestError as error:
        raise CadenceExperimentError(f"request validation failed: {error}") from error


def _validate_execution_assurance(value: Any, label: str) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != set(EXECUTION_ASSURANCE)
        or any(
            type(value[field]) is not type(expected) or value[field] != expected
            for field, expected in EXECUTION_ASSURANCE.items()
        )
    ):
        raise CadenceExperimentError(
            f"{label} execution_assurance differs from the observational contract"
        )


def _validate_request_envelope_binding(
    envelope: Mapping[str, Any],
    validated_request: Mapping[str, Any],
    label: str,
) -> None:
    runtime = validated_request["runtime_closure"]
    build = validated_request["build_identity"]
    experiment = validated_request["experiment"]
    _validate_execution_assurance(envelope.get("execution_assurance"), label)
    expected = {
        "evidence_class": validated_request["evidence_class"],
        "request_kind": validated_request["request_kind"],
        "source_provenance_scope": build["source_provenance_scope"],
        "source_tree_state": build["source_tree_state"],
        "toolchain_provenance_status": runtime["toolchain_provenance_status"],
        "adapter_executable_bytes": runtime["adapter_executable_bytes"],
        "adapter_executable_sha256": runtime["adapter_executable_sha256"],
        "cadence_schedule_sha256": experiment["cadence_schedule_sha256"],
        "quality_thresholds_sha256": experiment["quality_thresholds_sha256"],
        "experiment_contract_sha256": experiment["experiment_contract_sha256"],
    }
    _integer(
        envelope.get("adapter_executable_bytes"),
        f"{label} adapter_executable_bytes",
        minimum=1,
    )
    for field in (
        "adapter_executable_sha256",
        "cadence_schedule_sha256",
        "quality_thresholds_sha256",
        "experiment_contract_sha256",
    ):
        _sha256(envelope.get(field), f"{label} {field}")
    if any(envelope.get(field) != value for field, value in expected.items()):
        raise CadenceExperimentError(
            f"{label} request-bound provenance or experiment contract differs"
        )


def _validate_fixed_mapper_options_binding(
    envelope: Mapping[str, Any],
    *,
    expected_options: Mapping[str, Any],
    expected_sha256: str,
    label: str,
) -> None:
    measured_options = envelope.get("fixed_mapper_options")
    if not isinstance(measured_options, dict):
        raise CadenceExperimentError(f"{label} fixed mapper options must be an object")
    try:
        measured_sha256 = request_contract.fixed_mapper_options_sha256(
            measured_options
        )
    except request_contract.MapperCadenceRequestError as error:
        raise CadenceExperimentError(
            f"{label} fixed mapper options are invalid: {error}"
        ) from error
    declared_sha256 = _sha256(
        envelope.get("fixed_mapper_options_sha256"),
        f"{label} fixed_mapper_options_sha256",
    )
    if (
        measured_options != expected_options
        or measured_sha256 != expected_sha256
        or declared_sha256 != expected_sha256
    ):
        raise CadenceExperimentError(
            f"{label} fixed mapper options differ from the validated request"
        )


def _validate_name_array(value: Any, label: str, expected_count: int | None = None) -> list[str]:
    if not isinstance(value, list) or not value:
        raise CadenceExperimentError(f"{label} must be a nonempty array")
    names = [_string(item, f"{label} item") for item in value]
    if len(set(names)) != len(names):
        raise CadenceExperimentError(f"{label} contains duplicates")
    if expected_count is not None and len(names) != expected_count:
        raise CadenceExperimentError(f"{label} count is inconsistent")
    return names


def _validate_rejected_retrieval_history(
    envelope: Mapping[str, Any],
    *,
    selected_image_count: int,
) -> None:
    count = _integer(
        envelope.get("rejected_vocabulary_retrieval_count"),
        "rejected_vocabulary_retrieval_count",
    )
    history = envelope.get("rejected_vocabulary_retrieval_history")
    if not isinstance(history, list) or len(history) != count:
        raise CadenceExperimentError(
            "rejected_vocabulary_retrieval_history count is inconsistent"
        )
    ordinals: list[int] = []
    for index, raw_entry in enumerate(history):
        label = f"rejected_vocabulary_retrieval_history[{index}]"
        entry = _exact_object(raw_entry, REJECTED_RETRIEVAL_FIELDS, label)
        retrieval_ordinal = _integer(
            entry["retrieval_attempt_ordinal"],
            f"{label}.retrieval_attempt_ordinal",
            minimum=1,
        )
        ordinals.append(retrieval_ordinal)
        _integer(
            entry["pair_attempt_ordinal"],
            f"{label}.pair_attempt_ordinal",
            minimum=1,
        )
        if entry["pairing_policy"] != envelope["pairing_policy"]:
            raise CadenceExperimentError(f"{label}.pairing_policy is inconsistent")
        if entry["recovery_level"] not in RECOVERY_LEVELS:
            raise CadenceExperimentError(f"{label}.recovery_level is invalid")
        if _integer(
            entry["selected_view_count"],
            f"{label}.selected_view_count",
            minimum=1,
        ) != selected_image_count:
            raise CadenceExperimentError(f"{label}.selected_view_count is inconsistent")
        query_count = _integer(
            entry["query_count"],
            f"{label}.query_count",
            minimum=1,
        )
        no_neighbor_count = _integer(
            entry["no_ranked_neighbor_query_count"],
            f"{label}.no_ranked_neighbor_query_count",
        )
        if no_neighbor_count > query_count:
            raise CadenceExperimentError(f"{label} query counts are inconsistent")
        candidate_count = _integer(
            entry["candidate_count"],
            f"{label}.candidate_count",
            minimum=1,
        )
        returned_count = _integer(
            entry["returned_neighbor_count"],
            f"{label}.returned_neighbor_count",
        )
        if returned_count > candidate_count:
            raise CadenceExperimentError(f"{label} candidate counts are inconsistent")
        _sha256(entry["retrieval_request_digest"], f"{label}.retrieval_request_digest")
        _sha256(entry["retrieval_output_digest"], f"{label}.retrieval_output_digest")
    if ordinals != sorted(ordinals) or len(set(ordinals)) != len(ordinals):
        raise CadenceExperimentError(
            "rejected_vocabulary_retrieval_history ordinals are not deterministic"
        )


def _validate_matching_envelope(
    envelope: Mapping[str, Any],
    *,
    expected_project_root: Path,
    request_sha256: str,
    validated_request: Mapping[str, Any],
    expected_seed: int,
    expected_runtime_closure_sha256: str,
    expected_selected_image_count: int,
) -> dict[str, Any]:
    if set(envelope) != MATCHING_ENVELOPE_FIELDS:
        raise CadenceExperimentError(
            "matching checkpoint fields do not match the schema"
        )
    schema_version = _integer(envelope.get("schema_version"), "schema_version")
    if schema_version != 3 or envelope.get("measurement_scope") != "matching_only":
        raise CadenceExperimentError("adapter did not publish a schema-3 matching checkpoint")
    if envelope.get("variant") != "candidate":
        raise CadenceExperimentError("matching checkpoint has the wrong adapter variant")
    if _absolute_path(envelope.get("project_root"), "project_root") != expected_project_root:
        raise CadenceExperimentError("matching checkpoint has the wrong project root")
    database_path = _absolute_path(envelope.get("database_path"), "database_path")
    database_relative_path = _relative_path(
        envelope.get("database_project_relative_path"),
        "database_project_relative_path",
    )
    if database_path != expected_project_root.joinpath(*database_relative_path.parts):
        raise CadenceExperimentError(
            "matching database path does not match its project-relative artifact"
        )
    for field in (
        "selection_manifest",
        "pair_graph_evidence",
        "worker_execution",
        "pipeline_log",
    ):
        _relative_path(envelope.get(field), field)
    for field in SHA256_FIELDS:
        _sha256(envelope.get(field), field)
    if envelope["request_sha256"] != request_sha256:
        raise CadenceExperimentError("matching checkpoint is not bound to the request file")
    _validate_request_envelope_binding(
        envelope,
        validated_request,
        "matching checkpoint",
    )
    request_experiment = validated_request["experiment"]
    _validate_fixed_mapper_options_binding(
        envelope,
        expected_options=request_experiment["fixed_mapper_options"],
        expected_sha256=request_experiment["fixed_mapper_options_sha256"],
        label="matching checkpoint",
    )
    seed = _integer(envelope.get("deterministic_seed"), "deterministic_seed")
    if seed != expected_seed:
        raise CadenceExperimentError(
            "matching checkpoint seed differs from the validated request"
        )
    if (
        envelope["colmap_runtime_closure_sha256"]
        != expected_runtime_closure_sha256
    ):
        raise CadenceExperimentError(
            "matching checkpoint runtime differs from the external COLMAP closure"
        )
    _integer(envelope.get("database_file_bytes"), "database_file_bytes", minimum=1)
    _integer(
        envelope.get("database_source_device_id"),
        "database_source_device_id",
        minimum=1,
    )
    _integer(
        envelope.get("database_source_inode"),
        "database_source_inode",
        minimum=1,
    )
    if _integer(envelope.get("database_source_mode"), "database_source_mode") != (
        stat.S_IFREG | stat.S_IRUSR
    ):
        raise CadenceExperimentError("database_source_mode is not a read-only regular file")
    selected_count = _integer(envelope.get("selected_image_count"), "selected_image_count", minimum=1)
    if selected_count != expected_selected_image_count:
        raise CadenceExperimentError(
            "matching checkpoint selected-image count differs from the validated request"
        )
    _validate_name_array(envelope.get("selected_image_names"), "selected_image_names", selected_count)
    _integer(envelope.get("pair_graph_schema_version"), "pair_graph_schema_version", minimum=1)
    _integer(envelope.get("worker_execution_schema_version"), "worker_execution_schema_version", minimum=1)
    _string(envelope.get("pairing_policy"), "pairing_policy")
    descriptor_matcher = _string(
        envelope.get("descriptor_matcher"),
        "descriptor_matcher",
    )
    if descriptor_matcher not in {"faiss", "exact"}:
        raise CadenceExperimentError("descriptor_matcher is invalid")
    if envelope.get("colmap_compute_mode") not in {"gpu", "cpu"}:
        raise CadenceExperimentError("colmap_compute_mode is invalid")
    fallback_reasons = envelope.get("fallback_reasons")
    if not isinstance(fallback_reasons, list):
        raise CadenceExperimentError("fallback_reasons must be an array")
    validated_reasons = [
        _string(reason, "fallback_reasons item") for reason in fallback_reasons
    ]
    if len(set(validated_reasons)) != len(validated_reasons):
        raise CadenceExperimentError("fallback_reasons contains duplicates")
    if envelope.get("recovery_level") not in RECOVERY_LEVELS:
        raise CadenceExperimentError("recovery_level is invalid")
    exact_recovery_reason = envelope.get("exact_recovery_reason")
    if exact_recovery_reason is not None and exact_recovery_reason not in EXACT_RECOVERY_REASONS:
        raise CadenceExperimentError("exact_recovery_reason is invalid")
    if (descriptor_matcher == "exact") != (exact_recovery_reason is not None):
        raise CadenceExperimentError(
            "descriptor_matcher and exact_recovery_reason are inconsistent"
        )
    _integer(envelope.get("pair_attempt_ordinal"), "pair_attempt_ordinal", minimum=1)
    _validate_rejected_retrieval_history(
        envelope,
        selected_image_count=selected_count,
    )
    count_fields = (
        "scheduled_pair_count",
        "attempted_pair_count",
        "raw_matched_pair_count",
        "spatially_verified_pair_count",
        "local_pair_count",
        "retrieval_pair_count",
        "loop_revisit_pair_count",
        "connected_component_count",
        "isolated_view_count",
        "descriptorless_view_count",
        "articulation_view_count",
        "biconnected_block_count",
        "largest_biconnected_block_view_count",
        "second_largest_biconnected_block_view_count",
        "feature_invocation_count",
        "matching_invocation_count",
        "retrieval_invocation_count",
    )
    counts = {field: _integer(envelope.get(field), field) for field in count_fields}
    if not (
        counts["spatially_verified_pair_count"]
        <= counts["raw_matched_pair_count"]
        <= counts["attempted_pair_count"]
        <= counts["scheduled_pair_count"]
    ):
        raise CadenceExperimentError("matching pair counts are inconsistent")
    if counts["feature_invocation_count"] < 1 or counts["matching_invocation_count"] < 1:
        raise CadenceExperimentError("matching checkpoint has no feature or matching invocation")
    component_counts = envelope.get("component_view_counts")
    if not isinstance(component_counts, list) or not component_counts:
        raise CadenceExperimentError("component_view_counts must be a nonempty array")
    validated_components = [
        _integer(item, "component_view_counts item", minimum=1) for item in component_counts
    ]
    if len(validated_components) != counts["connected_component_count"] or sum(validated_components) != selected_count:
        raise CadenceExperimentError("component_view_counts are inconsistent")
    if counts["largest_biconnected_block_view_count"] > selected_count or counts[
        "second_largest_biconnected_block_view_count"
    ] > counts["largest_biconnected_block_view_count"]:
        raise CadenceExperimentError("biconnected block counts are inconsistent")
    degrees = [
        _number(envelope.get(field), field)
        for field in ("degree_p10", "degree_median", "degree_p90")
    ]
    if degrees != sorted(degrees):
        raise CadenceExperimentError("degree percentiles are inconsistent")
    _number(envelope.get("matching_duration_seconds"), "matching_duration_seconds", positive=True)
    _integer(envelope.get("peak_memory_bytes"), "peak_memory_bytes", minimum=1)
    for field in ("started_monotonic_seconds", "ended_monotonic_seconds"):
        _number(envelope.get(field), field)
    if float(envelope["ended_monotonic_seconds"]) <= float(envelope["started_monotonic_seconds"]):
        raise CadenceExperimentError("matching monotonic interval is invalid")
    for field in ("pipeline_stage_seconds", "stage_seconds"):
        values = envelope.get(field)
        if not isinstance(values, dict) or not values:
            raise CadenceExperimentError(f"{field} must be a nonempty object")
        for key, value in values.items():
            _string(key, f"{field} key")
            _number(value, f"{field}.{key}")
    return dict(envelope)


def _matching_closure(envelope: Mapping[str, Any]) -> dict[str, Any]:
    return {field: envelope[field] for field in MATCHING_CLOSURE_FIELDS}


def _resolve_trial_log(value: Any, output_root: Path) -> Path:
    raw = _string(value, "mapper_log")
    candidate = Path(raw)
    if (
        candidate.is_absolute()
        or len(candidate.parts) != 1
        or candidate.name != raw
        or raw in {".", ".."}
    ):
        raise CadenceExperimentError("mapper_log must be a direct child of the trial root")
    return output_root / candidate


def _validate_conditioning_measurement(
    value: Any,
    *,
    registered_views: int,
    point_count: int,
    observation_count: int,
) -> None:
    if not isinstance(value, dict) or set(value) != CONDITIONING_FIELDS:
        raise CadenceExperimentError("conditioning_measurement keys do not match the schema")
    for field in CONDITIONING_INTEGER_FIELDS:
        _integer(value[field], f"conditioning_measurement.{field}")
    for field in CONDITIONING_NUMBER_FIELDS:
        _number(value[field], f"conditioning_measurement.{field}")
    for field in CONDITIONING_EIGENVALUE_FIELDS:
        eigenvalues = value[field]
        label = f"conditioning_measurement.{field}"
        if not isinstance(eigenvalues, list) or len(eigenvalues) != 3:
            raise CadenceExperimentError(f"{label} must contain exactly three values")
        validated = [
            _number(component, f"{label}[{index}]")
            for index, component in enumerate(eigenvalues)
        ]
        if validated != sorted(validated):
            raise CadenceExperimentError(f"{label} must be sorted ascending")
    if (
        value["registeredViewCount"] != registered_views
        or value["pointCount"] != point_count
        or value["observationCount"] != observation_count
    ):
        raise CadenceExperimentError(
            "conditioning_measurement counts differ from the trial quality evidence"
        )


def _exact_object(value: Any, fields: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise CadenceExperimentError(f"{label} keys do not match the schema")
    return value


def _validate_timestamp_fields(value: Mapping[str, Any], prefix: str) -> None:
    for stem in ("modified", "changed"):
        _integer(value[f"{prefix}{stem}_seconds"], f"{prefix}{stem}_seconds")
        nanoseconds = _integer(
            value[f"{prefix}{stem}_nanoseconds"],
            f"{prefix}{stem}_nanoseconds",
        )
        if nanoseconds >= 1_000_000_000:
            raise CadenceExperimentError(
                f"{prefix}{stem}_nanoseconds must be below one billion"
            )


def _validate_source_database_evidence(
    value: Any,
    *,
    decision: Mapping[str, Any],
    label: str,
) -> dict[str, Any]:
    source = _exact_object(value, SOURCE_DATABASE_EVIDENCE_FIELDS, label)
    source_name = _string(source["source_name"], f"{label}.source_name")
    if source_name != Path(decision["database_path"]).name or "/" in source_name:
        raise CadenceExperimentError(f"{label}.source_name is not the decision database")
    for field in ("parent_device_id", "parent_inode", "device_id", "inode"):
        _integer(source[field], f"{label}.{field}", minimum=1)
    if (
        source["device_id"] != decision["database_source_device_id"]
        or source["inode"] != decision["database_source_inode"]
    ):
        raise CadenceExperimentError(f"{label} identity differs from the decision database")
    if _integer(source["link_count"], f"{label}.link_count") != 1:
        raise CadenceExperimentError(f"{label}.link_count must equal 1")
    if _integer(source["byte_count"], f"{label}.byte_count", minimum=1) != decision[
        "database_file_bytes"
    ]:
        raise CadenceExperimentError(f"{label}.byte_count differs from the decision database")
    if _integer(source["mode"], f"{label}.mode") != decision["database_source_mode"]:
        raise CadenceExperimentError(f"{label}.mode must be a read-only regular file")
    if _integer(source["owner_uid"], f"{label}.owner_uid") != os.getuid():
        raise CadenceExperimentError(f"{label}.owner_uid differs from the current user")
    _integer(source["owner_gid"], f"{label}.owner_gid")
    _validate_timestamp_fields(source, "")
    if source["companion_names"] != []:
        raise CadenceExperimentError(f"{label} contains a SQLite companion")
    if _sha256(source["sha256"], f"{label}.sha256") != decision[
        "database_file_sha256"
    ]:
        raise CadenceExperimentError(f"{label}.sha256 differs from the decision database")
    return source


def _validate_clone_database_evidence(
    pre_value: Any,
    post_value: Any,
    *,
    source: Mapping[str, Any],
    expected_ordinal: int,
    expected_name: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    pre = _exact_object(
        pre_value,
        CLONE_DATABASE_PRE_RUN_EVIDENCE_FIELDS,
        "clone_database_pre_run_evidence",
    )
    post = _exact_object(
        post_value,
        CLONE_DATABASE_POST_RUN_EVIDENCE_FIELDS,
        "clone_database_post_run_evidence",
    )
    if _integer(pre["trial_ordinal"], "clone pre-run trial_ordinal") != expected_ordinal:
        raise CadenceExperimentError("clone pre-run trial identity differs from the schedule")
    if pre["trial_name"] != expected_name:
        raise CadenceExperimentError("clone pre-run trial identity differs from the schedule")
    destination_name = _string(
        pre["destination_name"],
        "clone_database_pre_run_evidence.destination_name",
    )
    if destination_name != source["source_name"] or "/" in destination_name or destination_name in {".", ".."}:
        raise CadenceExperimentError("trial database destination is not a safe direct child")
    if pre["clone_strategy"] != "apfs_clone":
        raise CadenceExperimentError("clone pre-run strategy must equal apfs_clone")
    for field in (
        "destination_parent_device_id",
        "destination_parent_inode",
        "destination_device_id",
        "destination_inode",
    ):
        _integer(pre[field], f"clone_database_pre_run_evidence.{field}", minimum=1)
    if pre["destination_device_id"] != source["device_id"]:
        raise CadenceExperimentError("clone pre-run device differs from the source database")
    if (
        pre["destination_parent_device_id"] != source["parent_device_id"]
        or pre["destination_device_id"] != pre["destination_parent_device_id"]
    ):
        raise CadenceExperimentError(
            "clone pre-run source, destination, and parent devices differ"
        )
    if pre["destination_inode"] == source["inode"]:
        raise CadenceExperimentError("clone pre-run inode aliases the source database")
    if _integer(pre["destination_link_count"], "clone pre-run link count") != 1:
        raise CadenceExperimentError("clone pre-run link count must equal 1")
    if _integer(
        pre["destination_byte_count"],
        "clone pre-run byte count",
        minimum=1,
    ) != source["byte_count"]:
        raise CadenceExperimentError("clone pre-run byte count differs from the source database")
    if _integer(pre["destination_mode"], "clone pre-run mode") != (
        stat.S_IFREG | stat.S_IRUSR | stat.S_IWUSR
    ):
        raise CadenceExperimentError("clone pre-run mode is not owner-private read-write")
    destination_owner_uid = _integer(
        pre["destination_owner_uid"],
        "clone pre-run owner uid",
    )
    destination_owner_gid = _integer(
        pre["destination_owner_gid"],
        "clone pre-run owner gid",
    )
    if destination_owner_uid != source["owner_uid"] or destination_owner_gid != source[
        "owner_gid"
    ]:
        raise CadenceExperimentError("clone pre-run owner differs from the source database")
    _validate_timestamp_fields(pre, "destination_")
    if _sha256(pre["destination_sha256"], "clone pre-run sha256") != source["sha256"]:
        raise CadenceExperimentError("clone pre-run digest differs from the source database")

    shared_fields = (
        "destination_name",
        "destination_parent_device_id",
        "destination_parent_inode",
        "destination_device_id",
        "destination_inode",
        "destination_link_count",
        "destination_mode",
        "destination_owner_uid",
        "destination_owner_gid",
    )
    _string(post["destination_name"], "clone post-run destination name")
    for field in shared_fields[1:]:
        _integer(post[field], f"clone post-run {field}", minimum=1 if field in {
            "destination_parent_device_id",
            "destination_parent_inode",
            "destination_device_id",
            "destination_inode",
            "destination_link_count",
        } else 0)
    for field in shared_fields:
        if post[field] != pre[field]:
            raise CadenceExperimentError(
                f"clone post-run {field} differs from the pre-run identity"
            )
    _integer(post["destination_byte_count"], "clone post-run byte count", minimum=1)
    _validate_timestamp_fields(post, "destination_")
    _sha256(post["destination_sha256"], "clone post-run sha256")
    return pre, post


def _validate_trial(
    envelope: Mapping[str, Any],
    *,
    decision: Mapping[str, Any],
    validated_request: Mapping[str, Any],
    expected: Mapping[str, Any],
    expected_fixed_mapper_options: Mapping[str, Any],
    expected_fixed_mapper_options_sha256: str,
    trial_root: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if set(envelope) != TRIAL_ENVELOPE_FIELDS:
        raise CadenceExperimentError("mapping trial fields do not match the schema")
    ordinal = _integer(expected.get("ordinal"), "requested trial ordinal")
    name = _string(expected.get("name"), "requested trial name")
    cadence = _string(expected.get("mapper_cadence"), "requested mapper cadence")
    ratio = _number(expected.get("ratio"), "requested cadence ratio", positive=True)
    discarded = expected.get("discarded")
    if type(discarded) is not bool:
        raise CadenceExperimentError("requested trial discarded must be a boolean")
    schema_version = _integer(envelope.get("schema_version"), "schema_version")
    if (
        schema_version != 3
        or envelope.get("measurement_scope") != "mapping_cadence_trial"
    ):
        raise CadenceExperimentError("adapter did not publish a mapping cadence trial")
    trial_ordinal = _integer(envelope.get("trial_ordinal"), "trial_ordinal")
    if trial_ordinal != ordinal:
        raise CadenceExperimentError("unexpected trial ordinal")
    if envelope.get("trial_name") != name or envelope.get("mapper_cadence") != cadence:
        raise CadenceExperimentError("trial identity does not match the requested schedule")
    if envelope.get("discarded") is not discarded:
        raise CadenceExperimentError(
            "trial discard status does not match the requested schedule"
        )
    for field in ("ba_global_frames_ratio", "ba_global_points_ratio"):
        value = _number(envelope.get(field), field, positive=True)
        if not math.isclose(value, ratio, rel_tol=0.0, abs_tol=1e-12):
            raise CadenceExperimentError(f"{field} does not match the requested cadence")
    maximum_refinements = _integer(
        envelope.get("ba_global_max_refinements"),
        "ba_global_max_refinements",
    )
    if maximum_refinements != 5:
        raise CadenceExperimentError("ba_global_max_refinements must equal 5")
    for field in TRIAL_BINDING_FIELDS:
        if envelope.get(field) != decision.get(field):
            raise CadenceExperimentError("trial binding differs from the matching checkpoint")
    _validate_request_envelope_binding(
        envelope,
        validated_request,
        "mapping trial",
    )
    _validate_fixed_mapper_options_binding(
        envelope,
        expected_options=expected_fixed_mapper_options,
        expected_sha256=expected_fixed_mapper_options_sha256,
        label="mapping trial",
    )
    for field in ("point_track_topology_digest", "model_sha256"):
        _sha256(envelope.get(field), field)
    source_initial = _validate_source_database_evidence(
        envelope.get("source_database_initial_evidence"),
        decision=decision,
        label="source database initial evidence",
    )
    source_final = _validate_source_database_evidence(
        envelope.get("source_database_final_evidence"),
        decision=decision,
        label="source database final evidence",
    )
    if source_final != source_initial:
        raise CadenceExperimentError("source database final evidence differs from initial")
    clone_pre, _ = _validate_clone_database_evidence(
        envelope.get("clone_database_pre_run_evidence"),
        envelope.get("clone_database_post_run_evidence"),
        source=source_initial,
        expected_ordinal=ordinal,
        expected_name=name,
    )
    if envelope.get("clone_database_companion_names") != []:
        raise CadenceExperimentError("trial clone contains a SQLite companion")
    if (
        _sha256(
            envelope.get("clone_feature_database_digest_after"),
            "clone_feature_database_digest_after",
        )
        != decision["feature_database_digest"]
        or _sha256(
            envelope.get("clone_matching_database_digest_after"),
            "clone_matching_database_digest_after",
        )
        != decision["matching_database_digest"]
    ):
        raise CadenceExperimentError(
            "clone logical database contents differ after mapping"
        )
    output_root = _absolute_path(envelope.get("output_root"), "output_root")
    if output_root != trial_root:
        raise CadenceExperimentError("trial output root differs from the requested root")
    trial_root_status = _require_owned_path(
        trial_root,
        "trial root",
        directory=True,
    )
    if stat.S_IMODE(trial_root_status.st_mode) != 0o700:
        raise CadenceExperimentError("trial root is not owner-private")
    if (
        clone_pre["destination_parent_device_id"],
        clone_pre["destination_parent_inode"],
    ) != (trial_root_status.st_dev, trial_root_status.st_ino):
        raise CadenceExperimentError("clone pre-run trial root identity is incorrect")
    clone_path = trial_root / clone_pre["destination_name"]
    if clone_path.parent != trial_root:
        raise CadenceExperimentError("trial database destination must be a direct child")
    mapping_elapsed = _number(
        envelope.get("mapping_elapsed_seconds"),
        "mapping_elapsed_seconds",
        positive=True,
    )
    _integer(envelope.get("peak_memory_bytes"), "peak_memory_bytes", minimum=1)
    registered = _integer(envelope.get("registered_views"), "registered_views", minimum=1)
    if registered > len(decision["selected_image_names"]):
        raise CadenceExperimentError("registered_views exceeds the selected frame count")
    registered_names = _validate_name_array(
        envelope.get("registered_image_names"),
        "registered_image_names",
        registered,
    )
    if registered_names != sorted(registered_names) or not set(registered_names).issubset(
        decision["selected_image_names"]
    ):
        raise CadenceExperimentError(
            "registered_image_names must be a sorted selected-image subset"
        )
    points = _integer(envelope.get("point_count"), "point_count", minimum=1)
    observations = _integer(envelope.get("observation_count"), "observation_count", minimum=1)
    if observations < points:
        raise CadenceExperimentError("observation_count is smaller than point_count")
    median_residual = _number(envelope.get("median_residual_pixels"), "median_residual_pixels")
    p90_residual = _number(envelope.get("p90_residual_pixels"), "p90_residual_pixels")
    if p90_residual < median_residual:
        raise CadenceExperimentError("residual percentiles are inconsistent")
    quality_thresholds = validated_request["experiment"]["quality_thresholds"]
    if median_residual > float(
        quality_thresholds["maximum_median_residual_pixels"]
    ) or p90_residual > float(quality_thresholds["maximum_p90_residual_pixels"]):
        raise CadenceExperimentError(
            "trial residuals exceed the validated absolute quality thresholds"
        )
    if envelope.get("conditioning_status") != "accepted":
        raise CadenceExperimentError("conditioning_status must equal accepted")
    if envelope.get("conditioning_provenance") != CONDITIONING_PROVENANCE:
        raise CadenceExperimentError(
            f"conditioning_provenance must equal {CONDITIONING_PROVENANCE}"
        )
    _validate_conditioning_measurement(
        envelope.get("conditioning_measurement"),
        registered_views=registered,
        point_count=points,
        observation_count=observations,
    )
    try:
        evidence.mapper_cadence_name_bound_poses(envelope)
    except evidence.PoseAlignmentError as error:
        raise CadenceExperimentError(
            f"camera_poses_wxyz_xyz is invalid: {error.reason}"
        ) from error
    model_hashes = _exact_object(
        envelope.get("model_hashes"),
        MODEL_HASH_FIELDS,
        "model_hashes",
    )
    for name, digest in model_hashes.items():
        _sha256(digest, f"model_hashes.{name}")
    if request_contract.sha256_canonical(model_hashes) != envelope["model_sha256"]:
        raise CadenceExperimentError("model_sha256 does not bind model_hashes")
    _integer(envelope.get("mapped_model_order"), "mapped_model_order")
    log_path = _resolve_trial_log(envelope.get("mapper_log"), output_root)
    mapper_log_bytes = _integer(
        envelope.get("mapper_log_bytes"),
        "mapper_log_bytes",
        minimum=1,
    )
    mapper_log_sha256 = _sha256(
        envelope.get("mapper_log_sha256"),
        "mapper_log_sha256",
    )
    try:
        log_data = _read_regular_bytes(log_path, "mapper log", MAXIMUM_LOG_BYTES)
        if len(log_data) != mapper_log_bytes:
            raise CadenceExperimentError("mapper_log_bytes differs from the mapper log")
        if hashlib.sha256(log_data).hexdigest() != mapper_log_sha256:
            raise CadenceExperimentError("mapper_log_sha256 differs from the mapper log")
        profile = colmap_mapping_profile.parse_mapping_profile(
            log_data.decode("utf-8"),
            wall_seconds=mapping_elapsed,
        )
    except (UnicodeError, colmap_mapping_profile.ProfileError) as error:
        raise CadenceExperimentError(
            "mapper log did not produce a valid mapping profile"
        ) from error
    return dict(envelope), profile


def _median(values: list[int | float]) -> int | float:
    return statistics.median(values)


def _compare_trial_quality(
    reference: Mapping[str, Any],
    candidate: Mapping[str, Any],
    quality_thresholds: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    thresholds = (
        request_contract.QUALITY_THRESHOLDS
        if quality_thresholds is None
        else quality_thresholds
    )
    registered_loss = max(
        0,
        int(reference["registered_views"]) - int(candidate["registered_views"]),
    )
    registered_loss_limit = min(
        float(thresholds["maximum_registered_view_loss"]),
        float(reference["registered_views"])
        * float(thresholds["maximum_registered_view_loss_fraction"]),
    )
    point_loss_fraction = max(
        0.0,
        (float(reference["point_count"]) - float(candidate["point_count"]))
        / float(reference["point_count"]),
    )
    observation_loss_fraction = max(
        0.0,
        (
            float(reference["observation_count"])
            - float(candidate["observation_count"])
        )
        / float(reference["observation_count"]),
    )
    median_delta = max(
        0.0,
        float(candidate["median_residual_pixels"])
        - float(reference["median_residual_pixels"]),
    )
    p90_delta = max(
        0.0,
        float(candidate["p90_residual_pixels"])
        - float(reference["p90_residual_pixels"]),
    )
    reasons: list[str] = []
    if (
        reference.get("conditioning_status") != "accepted"
        or candidate.get("conditioning_status") != "accepted"
    ):
        reasons.append("conditioning_not_accepted")
    if registered_loss > registered_loss_limit + 1e-12:
        reasons.append("registered_view_loss")
    if point_loss_fraction > float(
        thresholds["maximum_point_count_loss_fraction"]
    ) + 1e-12:
        reasons.append("point_count_loss")
    if observation_loss_fraction > float(
        thresholds["maximum_observation_count_loss_fraction"]
    ) + 1e-12:
        reasons.append("observation_count_loss")
    if median_delta > float(
        thresholds["maximum_median_residual_regression_pixels"]
    ) + 1e-12:
        reasons.append("median_residual_delta")
    if p90_delta > float(
        thresholds["maximum_p90_residual_regression_pixels"]
    ) + 1e-12:
        reasons.append("p90_residual_delta")
    if float(candidate["median_residual_pixels"]) > float(
        thresholds["maximum_median_residual_pixels"]
    ):
        reasons.append("median_residual_absolute")
    if float(candidate["p90_residual_pixels"]) > float(
        thresholds["maximum_p90_residual_pixels"]
    ):
        reasons.append("p90_residual_absolute")

    center_p95: float | None = None
    rotation_p95: float | None = None
    try:
        reference_poses = evidence.mapper_cadence_name_bound_poses(reference)
        candidate_poses = evidence.mapper_cadence_name_bound_poses(candidate)
        deviation = evidence.sim3_pose_deviation(reference_poses, candidate_poses)
        center_p95 = deviation.camera_center_p95_scene_radius_fraction
        rotation_p95 = deviation.rotation_p95_degrees
        if center_p95 > float(
            thresholds["maximum_camera_center_p95_scene_radius_fraction"]
        ) + 1e-12:
            reasons.append("camera_center_deviation")
        if rotation_p95 > float(
            thresholds["maximum_rotation_p95_degrees"]
        ) + 1e-12:
            reasons.append("camera_rotation_deviation")
    except evidence.PoseAlignmentError as error:
        reasons.append(error.reason)
    return {
        "accepted": not reasons,
        "reasons": reasons,
        "registered_view_loss": registered_loss,
        "registered_view_loss_limit": registered_loss_limit,
        "point_count_loss_fraction": point_loss_fraction,
        "observation_count_loss_fraction": observation_loss_fraction,
        "median_residual_delta_pixels": median_delta,
        "p90_residual_delta_pixels": p90_delta,
        "camera_center_p95_scene_radius_fraction": center_p95,
        "rotation_p95_degrees": rotation_p95,
    }


def _quality_comparisons(
    candidate_trials: list[Mapping[str, Any]],
    reference_trials: list[Mapping[str, Any]],
    quality_thresholds: Mapping[str, Any],
) -> list[dict[str, Any]]:
    comparisons: list[dict[str, Any]] = []
    for candidate in candidate_trials:
        for reference in reference_trials:
            comparison = _compare_trial_quality(
                reference,
                candidate,
                quality_thresholds,
            )
            comparison["candidate_trial"] = candidate["trial_name"]
            comparison["reference_trial"] = reference["trial_name"]
            comparisons.append(comparison)
    return comparisons


def _within_arm_repeatability(
    trials: list[Mapping[str, Any]],
    cadence: str,
    quality_thresholds: Mapping[str, Any],
) -> dict[str, Any]:
    selected = [trial for trial in trials if trial["mapper_cadence"] == cadence]
    if len(selected) != 4:
        raise CadenceExperimentError(
            f"{cadence} does not have exactly four measured trials"
        )
    elapsed = [float(trial["mapping_elapsed_seconds"]) for trial in selected]
    minimum_elapsed = min(elapsed)
    maximum_elapsed = max(elapsed)
    elapsed_range = maximum_elapsed - minimum_elapsed
    maximum_range = _number(
        quality_thresholds.get("maximum_within_arm_mapping_elapsed_range_seconds"),
        "maximum_within_arm_mapping_elapsed_range_seconds",
    )
    pairwise_comparisons: list[dict[str, Any]] = []
    for left_index, left in enumerate(selected):
        for right in selected[left_index + 1 :]:
            left_names = left["registered_image_names"]
            right_names = right["registered_image_names"]
            same_name_sequence = left_names == right_names
            same_name_set = set(left_names) == set(right_names)
            same_topology = (
                left["point_track_topology_digest"]
                == right["point_track_topology_digest"]
            )
            left_reference_quality = _compare_trial_quality(
                left,
                right,
                quality_thresholds,
            )
            right_reference_quality = _compare_trial_quality(
                right,
                left,
                quality_thresholds,
            )
            reasons: list[str] = []
            if not same_name_sequence:
                reasons.append("registered_image_name_sequence_mismatch")
            if not same_name_set:
                reasons.append("registered_image_name_set_mismatch")
            if not same_topology:
                reasons.append("point_track_topology_digest_mismatch")
            if not left_reference_quality["accepted"]:
                reasons.append("left_reference_quality_failed")
            if not right_reference_quality["accepted"]:
                reasons.append("right_reference_quality_failed")
            pairwise_comparisons.append(
                {
                    "left_trial": left["trial_name"],
                    "right_trial": right["trial_name"],
                    "registered_image_name_sequence_equal": same_name_sequence,
                    "registered_image_name_sets_equal": same_name_set,
                    "point_track_topology_digest_equal": same_topology,
                    "left_reference_right_candidate_quality": left_reference_quality,
                    "right_reference_left_candidate_quality": right_reference_quality,
                    "accepted": not reasons,
                    "reasons": reasons,
                }
            )
    timing_accepted = elapsed_range <= maximum_range
    semantic_accepted = all(
        comparison["accepted"] for comparison in pairwise_comparisons
    )
    return {
        "trial_count": len(selected),
        "minimum_mapping_elapsed_seconds": minimum_elapsed,
        "maximum_mapping_elapsed_seconds": maximum_elapsed,
        "mapping_elapsed_range_seconds": elapsed_range,
        "maximum_allowed_mapping_elapsed_range_seconds": maximum_range,
        "timing_accepted": timing_accepted,
        "semantic_repeatability_accepted": semantic_accepted,
        "pairwise_comparisons": pairwise_comparisons,
        "accepted": timing_accepted and semantic_accepted,
    }


def _aggregate(trials: list[Mapping[str, Any]], cadence: str) -> dict[str, Any]:
    selected = [trial for trial in trials if trial["mapper_cadence"] == cadence]
    if len(selected) != 4:
        raise CadenceExperimentError(
            f"{cadence} does not have exactly four measured trials"
        )
    result: dict[str, Any] = {"trial_count": len(selected)}
    for field in AGGREGATE_FIELDS:
        result[f"median_{field}"] = _median([trial[field] for trial in selected])
    return result


def _write_atomic_json(value: Mapping[str, Any], output: Path) -> None:
    payload = (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
        + "\n"
    ).encode("utf-8")
    temporary_path: Path | None = None
    descriptor: int | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".mapper-cadence-ab-",
            suffix=".tmp",
            dir=output.parent,
        )
        temporary_path = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        try:
            os.link(temporary_path, output, follow_symlinks=False)
        except FileExistsError as error:
            raise CadenceExperimentError("output appeared before publication") from error
        temporary_path.unlink()
        temporary_path = None
        directory_descriptor = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def run_experiment(args: argparse.Namespace) -> dict[str, Any]:
    adapter = Path(args.adapter)
    request = Path(args.request)
    input_path = Path(args.input)
    toolchain_root = Path(args.toolchain_root)
    runtime_closure_sha256 = _sha256(
        args.colmap_runtime_closure_sha256,
        "external COLMAP runtime closure SHA-256",
    )
    runner_closure_identity = (
        Path(args.measurement_runner_closure_identity)
        if args.measurement_runner_closure_identity is not None
        else None
    )
    runner_closure_root = (
        Path(args.measurement_runner_closure_root)
        if args.measurement_runner_closure_root is not None
        else None
    )
    if (runner_closure_identity is None) != (runner_closure_root is None):
        raise CadenceExperimentError(
            "measurement runner closure identity and root must be supplied together"
        )
    work_root = Path(args.work_root)
    output = Path(args.output)
    _require_owned_path(adapter, "adapter", regular=True, executable=True)
    _require_owned_path(request, "request", regular=True)
    input_metadata = _require_owned_path(input_path, "input")
    if not (stat.S_ISREG(input_metadata.st_mode) or stat.S_ISDIR(input_metadata.st_mode)):
        raise CadenceExperimentError("input must be a regular file or directory")
    _require_owned_path(toolchain_root, "toolchain root", directory=True)
    work_metadata = _require_owned_path(work_root, "work root", directory=True)
    if stat.S_IMODE(work_metadata.st_mode) != 0o700:
        raise CadenceExperimentError("work root must have mode 0700")
    if any(work_root.iterdir()):
        raise CadenceExperimentError("work root must be empty")
    if not output.is_absolute() or output.parent != work_root or output.exists() or output.is_symlink():
        raise CadenceExperimentError("output must be a new direct child of the work root")
    request_bytes = _read_regular_bytes(request, "request", MAXIMUM_ENVELOPE_BYTES)
    request_sha256 = hashlib.sha256(request_bytes).hexdigest()
    validated_request = _load_bound_request(
        request,
        input_path=input_path,
        adapter=adapter,
        toolchain_root=toolchain_root,
        runtime_closure_sha256=runtime_closure_sha256,
        runner_closure_identity=runner_closure_identity,
        runner_closure_root=runner_closure_root,
    )
    if request_bytes != request_contract.canonical_json_bytes(validated_request) + b"\n":
        raise CadenceExperimentError(
            "validated request bytes differ from the exact admitted request"
        )
    experiment = validated_request["experiment"]
    expected_seed = _integer(
        experiment["deterministic_seed"],
        "request deterministic_seed",
    )
    if args.profile_seed is not None and args.profile_seed != expected_seed:
        raise CadenceExperimentError(
            "profile seed differs from the validated request"
        )
    expected_selected_image_count = _integer(
        validated_request["binding"]["scale"],
        "request binding scale",
        minimum=1,
    )
    fixed_mapper_options = experiment["fixed_mapper_options"]
    fixed_mapper_options_sha256 = _sha256(
        experiment["fixed_mapper_options_sha256"],
        "request fixed_mapper_options_sha256",
    )
    try:
        measured_fixed_options_sha256 = (
            request_contract.fixed_mapper_options_sha256(fixed_mapper_options)
        )
    except request_contract.MapperCadenceRequestError as error:
        raise CadenceExperimentError(
            f"request fixed mapper options are invalid: {error}"
        ) from error
    if measured_fixed_options_sha256 != fixed_mapper_options_sha256:
        raise CadenceExperimentError(
            "request fixed mapper options digest does not match its values"
        )
    warmup = dict(experiment["warmup"])
    measured_schedule = [dict(item) for item in experiment["measured_trials"]]
    cadence_schedule = {
        "warmup": warmup,
        "measured_trials": measured_schedule,
    }
    cadence_schedule_sha256 = _sha256(
        experiment["cadence_schedule_sha256"],
        "request cadence_schedule_sha256",
    )
    if request_contract.sha256_canonical(cadence_schedule) != cadence_schedule_sha256:
        raise CadenceExperimentError(
            "request cadence schedule digest does not match its values"
        )
    quality_thresholds = dict(experiment["quality_thresholds"])
    quality_thresholds_sha256 = _sha256(
        experiment["quality_thresholds_sha256"],
        "request quality_thresholds_sha256",
    )
    if (
        request_contract.sha256_canonical(quality_thresholds)
        != quality_thresholds_sha256
    ):
        raise CadenceExperimentError(
            "request quality thresholds digest does not match its values"
        )

    matching: list[tuple[dict[str, Any], Path]] = []
    for label in ("matching-bootstrap", "matching-decision"):
        run_root = _create_private_directory(work_root, label)
        project_root = run_root / "project.easysplatproj"
        envelope_path = run_root / "matching-envelope.json"
        raw = _invoke_adapter(
            adapter,
            [
                *_base_adapter_arguments(
                    request,
                    input_path,
                    toolchain_root,
                    project_root,
                    envelope_path,
                ),
                "--matching-only",
                "true",
            ],
            envelope_path,
        )
        matching.append(
            (
                _validate_matching_envelope(
                    raw,
                    expected_project_root=project_root,
                    request_sha256=request_sha256,
                    validated_request=validated_request,
                    expected_seed=expected_seed,
                    expected_runtime_closure_sha256=runtime_closure_sha256,
                    expected_selected_image_count=expected_selected_image_count,
                ),
                envelope_path,
            )
        )
    bootstrap, _ = matching[0]
    decision, decision_path = matching[1]
    if _matching_closure(bootstrap) != _matching_closure(decision):
        raise CadenceExperimentError("matching checkpoints do not reproduce an identical closure")

    seen_database_inodes: set[int] = set()
    seen_database_paths: set[Path] = set()
    seen_output_roots: set[Path] = set()
    frozen_source_database: dict[str, Any] | None = None
    warmup_raw: dict[str, Any] | None = None
    measured_trials: list[dict[str, Any]] = []
    mapping_profiles: dict[str, dict[str, Any]] = {}
    for expected in (warmup, *measured_schedule):
        ordinal = expected["ordinal"]
        name = expected["name"]
        cadence = expected["mapper_cadence"]
        trial_root = _create_private_directory(work_root, name)
        project_root = trial_root / "project.easysplatproj"
        envelope_path = trial_root / "trial-envelope.json"
        raw = _invoke_adapter(
            adapter,
            [
                *_base_adapter_arguments(
                    request,
                    input_path,
                    toolchain_root,
                    project_root,
                    envelope_path,
                ),
                "--mapping-from-checkpoint",
                str(decision_path),
                "--mapper-cadence",
                cadence,
                "--trial-root",
                str(trial_root),
            ],
            envelope_path,
        )
        trial, profile = _validate_trial(
            raw,
            decision=decision,
            validated_request=validated_request,
            expected=expected,
            expected_fixed_mapper_options=fixed_mapper_options,
            expected_fixed_mapper_options_sha256=fixed_mapper_options_sha256,
            trial_root=trial_root,
        )
        clone_pre_run = trial["clone_database_pre_run_evidence"]
        database_inode = clone_pre_run["destination_inode"]
        database_path = Path(trial["output_root"]) / clone_pre_run["destination_name"]
        output_root = Path(trial["output_root"])
        if database_inode in seen_database_inodes or database_path in seen_database_paths:
            raise CadenceExperimentError("duplicate trial database identity or destination")
        if output_root in seen_output_roots:
            raise CadenceExperimentError("duplicate trial output root")
        seen_database_inodes.add(database_inode)
        seen_database_paths.add(database_path)
        seen_output_roots.add(output_root)
        source_database = trial["source_database_initial_evidence"]
        if frozen_source_database is None:
            frozen_source_database = source_database
        elif source_database != frozen_source_database:
            raise CadenceExperimentError(
                "mapper trials did not use one physical frozen source database"
            )
        mapping_profiles[name] = profile
        if ordinal == warmup["ordinal"]:
            warmup_raw = trial
        else:
            measured_trials.append(trial)
    if warmup_raw is None or len(measured_trials) != len(measured_schedule):
        raise CadenceExperimentError("the mapper trial schedule is incomplete")
    if [trial["trial_ordinal"] for trial in measured_trials] != [
        item["ordinal"] for item in measured_schedule
    ]:
        raise CadenceExperimentError("the mapper trial schedule is incomplete or contains extras")
    expected_work_entries = {
        "matching-bootstrap",
        "matching-decision",
        warmup["name"],
        *(item["name"] for item in measured_schedule),
    }
    actual_work_entries = {entry.name for entry in work_root.iterdir()}
    if actual_work_entries != expected_work_entries:
        raise CadenceExperimentError("unexpected work-root entry or missing trial root")

    aggregates = {
        cadence: _aggregate(measured_trials, cadence)
        for cadence in ("frequent-global", "balanced-global")
    }
    differences = {
        "balanced_minus_frequent": {
            field: aggregates["balanced-global"][field]
            - aggregates["frequent-global"][field]
            for field in aggregates["frequent-global"]
            if field != "trial_count"
        }
    }
    within_arm_repeatability = {
        cadence: _within_arm_repeatability(
            measured_trials,
            cadence,
            quality_thresholds,
        )
        for cadence in ("frequent-global", "balanced-global")
    }
    repeatability_accepted = all(
        result["accepted"] for result in within_arm_repeatability.values()
    )
    winner: str | None = None
    winner_status = (
        "timing_tie"
        if repeatability_accepted
        else "within_arm_repeatability_gate_failed"
    )
    quality_comparisons: list[dict[str, Any]] = []
    frequent_wall = aggregates["frequent-global"]["median_mapping_elapsed_seconds"]
    balanced_wall = aggregates["balanced-global"]["median_mapping_elapsed_seconds"]
    proposed_winner: str | None = None
    if repeatability_accepted:
        if frequent_wall < balanced_wall:
            proposed_winner = "frequent-global"
        elif balanced_wall < frequent_wall:
            proposed_winner = "balanced-global"
    if proposed_winner is not None:
        reference_cadence = (
            "balanced-global"
            if proposed_winner == "frequent-global"
            else "frequent-global"
        )
        quality_comparisons = _quality_comparisons(
            [
                trial
                for trial in measured_trials
                if trial["mapper_cadence"] == proposed_winner
            ],
            [
                trial
                for trial in measured_trials
                if trial["mapper_cadence"] == reference_cadence
            ],
            quality_thresholds,
        )
        if len(quality_comparisons) == 16 and all(
            comparison["accepted"] for comparison in quality_comparisons
        ):
            winner = proposed_winner
            winner_status = (
                "lower_median_mapping_elapsed_seconds_with_quality_parity"
            )
        else:
            winner_status = "quality_gate_failed"
    result: dict[str, Any] = {
        "schema_version": 3,
        "measurement_scope": "mapper_cadence_ab",
        "evidence_class": validated_request["evidence_class"],
        "source_provenance_scope": validated_request["build_identity"][
            "source_provenance_scope"
        ],
        "toolchain_provenance_status": validated_request["runtime_closure"][
            "toolchain_provenance_status"
        ],
        "execution_assurance": dict(EXECUTION_ASSURANCE),
        "profile_seed": expected_seed,
        "request_bytes": len(request_bytes),
        "request_sha256": decision["request_sha256"],
        "resolved_plan_binding_sha256": decision["resolved_plan_binding_sha256"],
        "colmap_runtime_closure_sha256": decision["colmap_runtime_closure_sha256"],
        "expected_colmap_runtime_closure_sha256": runtime_closure_sha256,
        "fixed_mapper_options_sha256": fixed_mapper_options_sha256,
        "cadence_schedule_sha256": cadence_schedule_sha256,
        "quality_thresholds_sha256": quality_thresholds_sha256,
        "cadence_schedule": cadence_schedule,
        "decision_matching_checkpoint": decision,
        "discarded_warmup": warmup_raw,
        "measured_schedule": [
            item["mapper_cadence"] for item in measured_schedule
        ],
        "raw_trials": measured_trials,
        "mapping_profiles": mapping_profiles,
        "aggregates": aggregates,
        "differences": differences,
        "within_arm_repeatability": within_arm_repeatability,
        "quality_comparisons": quality_comparisons,
        "winner": winner,
        "winner_status": winner_status,
    }
    final_request = _load_bound_request(
        request,
        input_path=input_path,
        adapter=adapter,
        toolchain_root=toolchain_root,
        runtime_closure_sha256=runtime_closure_sha256,
        runner_closure_identity=runner_closure_identity,
        runner_closure_root=runner_closure_root,
    )
    final_request_bytes = _read_regular_bytes(
        request,
        "request after trials",
        MAXIMUM_ENVELOPE_BYTES,
    )
    if final_request != validated_request or final_request_bytes != request_bytes:
        raise CadenceExperimentError(
            "validated request or its exact canonical bytes changed during the experiment"
        )
    _write_atomic_json(result, output)
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compare the fixed EasySplat mapper BA cadences from one frozen checkpoint."
    )
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--request", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--toolchain-root", required=True)
    parser.add_argument("--colmap-runtime-closure-sha256", required=True)
    parser.add_argument("--measurement-runner-closure-identity")
    parser.add_argument("--measurement-runner-closure-root")
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--profile-seed", type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.profile_seed is not None and args.profile_seed < 0:
        print("error: profile seed must be nonnegative", file=sys.stderr)
        return 2
    try:
        run_experiment(args)
    except (CadenceExperimentError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
