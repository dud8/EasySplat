#!/usr/bin/env python3
"""Derive and validate benchmark evidence from raw measurements.

Release metrics are never accepted directly from a corpus manifest. A protected
runner records raw observations and command logs. A separate hosted job derives
compact evidence from those observations without retaining the raw artifacts.
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import mmap
import os
import platform
import re
import shutil
import stat
import statistics
import struct
import subprocess
import tempfile
import warnings
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping


PROTOCOL_VERSION = 4
PRODUCER_VERSION = "4.0.0"
PRODUCER_RELATIVE_PATH = "scripts/benchmark/evidence_protocol.py"
LANE_REFERENCE = "reference_m4_max"
LANE_CONSTRAINED = "constrained_14_16gb"
LANE_EIGHT_GB = "eight_gb_fast"
RENDERING_DRIVER_IDENTITY = "rendering_driver"
RELEASE_LANES = {LANE_REFERENCE, LANE_CONSTRAINED, LANE_EIGHT_GB}
RUNNER_LABELS = {
    LANE_REFERENCE: "reference-measurement-runner",
    LANE_CONSTRAINED: "constrained-measurement-runner",
    LANE_EIGHT_GB: "eight-gb-measurement-runner",
    RENDERING_DRIVER_IDENTITY: "metal-splatter-benchmark-driver",
}
ACCURATE_REFERENCE_CONFIGURATION = {
    "mapper": "mapper",
    "bundle_adjustment": "full",
    "render_iterations": 30_000,
    "pose_source": "accurate_colmap",
}
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
MONOTONIC_TIMESTAMP_TOLERANCE_SECONDS = 1e-6
PINNED_TOOLCHAIN_PUBLIC_KEY_PATH = (
    Path(__file__).resolve().parents[2]
    / "EasySplatApp/Resources/public_key_ed25519.txt"
)
PINNED_TOOLCHAIN_PUBLIC_KEY_BASE64_OVERRIDE: str | None = None
MAX_TOOLCHAIN_INSTALL_STATE_BYTES = 16 * 1024 * 1024
MAX_HOST_MONITOR_BYTES = 64 * 1024 * 1024
MAX_LANE_OUTCOME_BYTES = 1024 * 1024
MAX_ATTESTATION_BYTES = 16 * 1024 * 1024
MAX_OBSERVATIONS_BYTES = 256 * 1024 * 1024
MAX_EXTERNAL_CPU_FRACTION = 0.10
MAX_UNATTRIBUTED_CHILD_CPU_FRACTION = 0.02
ALLOWED_GATE_SCOPES = {
    "scene_quality",
    "scene_performance",
    "suite_performance",
    "long_sequence",
    "stability",
    "invalid_input",
    "toolchain",
}
PIPELINE_INTEGER_METRICS = {
    "scheduled_pairs",
    "attempted_pairs",
    "raw_matched_pairs",
    "spatially_verified_pairs",
    "connected_components",
    "isolated_views",
    "articulation_views",
    "biconnected_blocks",
    "largest_biconnected_block_views",
    "second_largest_biconnected_block_views",
    "local_pairs",
    "retrieval_pairs",
    "loop_pairs",
    "bundle_adjustment_cycles",
    "raster_fallback_count",
    "raster_exact_buffer_growth_count",
    "raster_exact_buffer_bytes_added",
    "raster_peak_exact_intersection_capacity",
    "maximum_tile_intersections",
    "dropped_intersection_count",
}
PIPELINE_NUMBER_METRICS = {
    "matcher_seconds",
    "mapping_seconds",
    "orientation_physical_up_error_degrees",
    "raster_exact_fallback_elapsed_seconds",
    "raster_replay_elapsed_seconds",
}
PIPELINE_BOOLEAN_METRICS = {"orientation_sign_correct"}
PIPELINE_ENUM_METRICS = {
    "orientation_status": {"verified", "axis_aligned_sign_unverified", "unresolved"},
}
PIPELINE_METRICS = (
    PIPELINE_INTEGER_METRICS
    | PIPELINE_NUMBER_METRICS
    | PIPELINE_BOOLEAN_METRICS
    | set(PIPELINE_ENUM_METRICS)
)
ORIENTATION_EVIDENCE_FIELDS = {
    "alignment_median_residual_degrees",
    "alignment_p90_residual_degrees",
    "alignment_support_count",
    "candidate_source_to_ground_truth_wxyz",
    "orientation_physical_up_error_degrees",
    "orientation_sign_correct",
    "orientation_status",
}
ORIENTATION_PIPELINE_FIELDS = {
    "orientation_physical_up_error_degrees",
    "orientation_sign_correct",
    "orientation_status",
}
QUALITY_METRICS = {
    "registered_views",
    "total_views",
    "colmap_registered_views",
    "baseline_registered_views",
    "points",
    "observations",
    "output_splat_count",
    "residual_provenance",
    "residual_median_pixels",
    "residual_p90_pixels",
    "ate_colmap_ratio",
    "rotation_rpe_delta_degrees",
    "translation_rpe_delta_percentage_points",
    "balanced_median_psnr_loss_db",
    "balanced_median_ssim_loss",
    "balanced_median_lpips_increase",
    "balanced_scene_psnr_loss_db",
    "balanced_scene_ssim_loss",
    "balanced_scene_lpips_increase",
    "fast_scene_psnr_loss_db",
    "fast_scene_ssim_loss",
    "fast_scene_lpips_increase",
    "paired_balanced_scene_psnr_loss_db",
    "paired_balanced_scene_ssim_loss",
    "paired_balanced_scene_lpips_increase",
    "orientation_physical_up_error_degrees",
    "orientation_sign_correct",
}
SUITE_PERFORMANCE_METRICS = {
    "m4_max_p50_seconds",
    "fast_end_to_end_speedup",
    "balanced_geometry_speedup",
    "constrained_fast_p50_seconds",
    "eight_gb_fast_p50_seconds",
    "matching_speedup",
    "mapping_speedup",
    "peak_metal_allocated_bytes",
}
LONG_SEQUENCE_METRICS = {
    "long_sequence_analysis_fps",
    "long_sequence_frames",
    "long_sequence_rss_growth_fraction",
}
STABILITY_METRICS = {
    "repeat_runs",
    "crashes",
    "corrupt_outputs",
    "durable_state_recovery_succeeded",
}
TOOLCHAIN_CHECK_METRICS = {
    "toolchain_fresh_install",
    "toolchain_cached_offline_run",
    "toolchain_interrupted_download_recovered",
    "toolchain_low_disk_rejected",
    "toolchain_wrong_key_rejected",
    "toolchain_corrupt_archive_rejected",
    "toolchain_rollback_succeeded",
    "toolchain_traversal_rejected",
}
TOOLCHAIN_METRICS = {
    "normal_photo_toolchain_bytes",
    "large_area_toolchain_bytes",
} | TOOLCHAIN_CHECK_METRICS
TOOLCHAIN_SCENARIO_SPECS = {
    "fresh_install": {
        "metric": "toolchain_fresh_install",
        "fault": "none",
        "network_mode": "online",
        "initial_exit_code": 0,
        "retry_exit_code": None,
        "result": "installed",
    },
    "cached_offline_run": {
        "metric": "toolchain_cached_offline_run",
        "fault": "offline",
        "network_mode": "offline",
        "initial_exit_code": 0,
        "retry_exit_code": None,
        "result": "cached_run",
    },
    "interrupted_download": {
        "metric": "toolchain_interrupted_download_recovered",
        "fault": "interrupted_download",
        "network_mode": "online",
        "initial_exit_code": 75,
        "retry_exit_code": 0,
        "result": "recovered",
    },
    "low_disk": {
        "metric": "toolchain_low_disk_rejected",
        "fault": "low_disk",
        "network_mode": "online",
        "initial_exit_code": 70,
        "retry_exit_code": None,
        "result": "rejected",
    },
    "wrong_key": {
        "metric": "toolchain_wrong_key_rejected",
        "fault": "wrong_key",
        "network_mode": "online",
        "initial_exit_code": 65,
        "retry_exit_code": None,
        "result": "rejected",
    },
    "corrupt_archive": {
        "metric": "toolchain_corrupt_archive_rejected",
        "fault": "corrupt_archive",
        "network_mode": "online",
        "initial_exit_code": 66,
        "retry_exit_code": None,
        "result": "rejected",
    },
    "rollback": {
        "metric": "toolchain_rollback_succeeded",
        "fault": "corrupt_upgrade",
        "network_mode": "online",
        "initial_exit_code": 67,
        "retry_exit_code": 0,
        "result": "rolled_back",
    },
    "traversal": {
        "metric": "toolchain_traversal_rejected",
        "fault": "traversal_archive",
        "network_mode": "online",
        "initial_exit_code": 68,
        "retry_exit_code": None,
        "result": "rejected",
    },
}

RENDER_VARIANTS = (
    "accurate_reference",
    "paired_baseline",
    "candidate_balanced",
    "candidate_fast",
)
LPIPS_SQUEEZENET_BACKBONE_SHA256 = (
    "sha256:b8a52dc049b60e4b6ab68ad0df457362afab8b6304b2febdc1650a5dab4d7e7b"
)
LPIPS_SQUEEZENET_CALIBRATION_SHA256 = (
    "sha256:4a5350f23600cb79923ce65bb07cbf57dca461329894153e05a1346bd531cf76"
)
LPIPS_CALIBRATION_HEAD_KEYS = frozenset(
    f"lin{index}.model.1.weight"
    for index in range(7)
)
RENDER_SCORING_PACKAGE_VERSIONS = {
    "lpips": "0.1.4",
    "numpy": "2.5.1",
    "pillow": "12.3.0",
    "torch": "2.13.0",
    "torchvision": "0.28.0",
}


def render_scoring_runtime() -> dict[str, Any]:
    lock = Path(__file__).resolve().with_name("render-requirements.txt")
    return {
        "status": "required",
        "requirements_lock_sha256": sha256_file(lock),
        "packages": dict(RENDER_SCORING_PACKAGE_VERSIONS),
        "lpips": {
            "network_access": "disabled",
            "backbone": {
                "name": "torchvision_squeezenet1_1_imagenet1k_v1",
                "sha256": LPIPS_SQUEEZENET_BACKBONE_SHA256,
            },
            "calibration": {
                "name": "lpips_v0.1_squeeze",
                "sha256": LPIPS_SQUEEZENET_CALIBRATION_SHA256,
            },
        },
    }


@dataclass(frozen=True)
class RenderingEvidence:
    balanced: list[dict[str, float | int]]
    fast: list[dict[str, float | int]]
    artifacts: dict[str, dict[str, Any]]

    @property
    def samples(self) -> list[dict[str, float | int]]:
        return self.balanced


class EvidenceError(ValueError):
    """Raw evidence is incomplete, inconsistent, or unsafe."""


def _decode_json_text(value: str, label: str) -> Any:
    def reject_constant(constant: str) -> None:
        raise EvidenceError(f"{label} contains {constant}")

    def finite_float(raw: str) -> float:
        parsed = float(raw)
        if not math.isfinite(parsed):
            raise EvidenceError(f"{label} contains a non-finite number")
        return parsed

    try:
        return json.loads(
            value,
            parse_constant=reject_constant,
            parse_float=finite_float,
        )
    except EvidenceError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise EvidenceError(f"{label} is not valid JSON") from error


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def render_camera_digest(value: Any) -> str:
    camera = _render_camera(value, "render camera digest")
    payload = bytearray(b"EasySplat render camera digest v1\0")
    payload.extend(struct.pack(">II", camera["width"], camera["height"]))
    values = (
        camera["projection_matrix_column_major"]
        + camera["world_to_camera_matrix_column_major"]
    )
    for position, value in enumerate(values):
        try:
            encoded = struct.pack(">f", value)
        except (OverflowError, struct.error) as error:
            raise EvidenceError(
                f"render camera digest value {position} is outside Float32"
            ) from error
        bits = struct.unpack(">I", encoded)[0]
        if bits & 0x7FFF_FFFF == 0:
            bits = 0
        payload.extend(struct.pack(">I", bits))
    return sha256_bytes(bytes(payload))


def sha256_file(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise EvidenceError(f"evidence artifact must be a regular file: {path.name}")
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        before = os.fstat(handle.fileno())
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
        after = os.fstat(handle.fileno())
    if (
        before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ino != after.st_ino
    ):
        raise EvidenceError(f"evidence artifact changed while hashing: {path.name}")
    return "sha256:" + hasher.hexdigest()


def toolchain_identity_from_closure(closure: Mapping[str, Any]) -> str:
    hasher = hashlib.sha256()
    for value in (
        b"easysplat-benchmark-toolchain-v2",
        canonical_json_bytes(closure),
    ):
        hasher.update(len(value).to_bytes(8, "big"))
        hasher.update(value)
    return "sha256:" + hasher.hexdigest()


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise EvidenceError(f"{label} must be an object")
    return value


def _exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    if set(value) != expected_set:
        missing = sorted(expected_set - set(value))
        extra = sorted(set(value) - expected_set)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unknown " + ", ".join(extra))
        raise EvidenceError(f"{label} has invalid fields: {'; '.join(details)}")


def _token(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SAFE_TOKEN_PATTERN.fullmatch(value):
        raise EvidenceError(f"{label} must be a lowercase token")
    return value


def _digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
        raise EvidenceError(f"{label} must be a SHA-256 digest")
    return value


def validate_runner_identity(value: Any, lane: str) -> dict[str, Any]:
    if lane == RENDERING_DRIVER_IDENTITY:
        return validate_rendering_driver_identity(value)
    identity = _mapping(value, f"{lane} measurement runner")
    _exact_keys(identity, {"label", "sha256"}, f"{lane} measurement runner")
    expected_label = RUNNER_LABELS.get(lane)
    if expected_label is None or identity["label"] != expected_label:
        raise EvidenceError(f"{lane} measurement runner label is invalid")
    return {
        "label": expected_label,
        "sha256": _digest(identity["sha256"], f"{lane} measurement runner sha256"),
    }


def validate_rendering_driver_identity(value: Any) -> dict[str, Any]:
    identity = _mapping(value, "rendering driver identity")
    _exact_keys(
        identity,
        {
            "label",
            "sha256",
            "executable_path",
            "executable_sha256",
            "resource_bundle_path",
            "manifest_path",
            "manifest_bytes",
            "manifest_sha256",
        },
        "rendering driver identity",
    )
    if identity["label"] != RUNNER_LABELS[RENDERING_DRIVER_IDENTITY]:
        raise EvidenceError("rendering driver identity label is invalid")
    expected_paths = {
        "executable_path": "EasySplatBenchmarkDriver",
        "resource_bundle_path": "MetalSplatter_MetalSplatter.bundle",
        "manifest_path": "closure-manifest.json",
    }
    for field, expected in expected_paths.items():
        if identity[field] != expected:
            raise EvidenceError(f"rendering driver identity {field} is invalid")
    manifest_bytes = identity["manifest_bytes"]
    if type(manifest_bytes) is not int or manifest_bytes <= 0:
        raise EvidenceError("rendering driver identity manifest_bytes is invalid")
    return {
        "label": RUNNER_LABELS[RENDERING_DRIVER_IDENTITY],
        "sha256": _digest(identity["sha256"], "rendering driver closure sha256"),
        "executable_path": expected_paths["executable_path"],
        "executable_sha256": _digest(
            identity["executable_sha256"], "rendering driver executable sha256"
        ),
        "resource_bundle_path": expected_paths["resource_bundle_path"],
        "manifest_path": expected_paths["manifest_path"],
        "manifest_bytes": manifest_bytes,
        "manifest_sha256": _digest(
            identity["manifest_sha256"], "rendering driver manifest sha256"
        ),
    }


def validate_runner_identities(value: Any) -> dict[str, dict[str, Any]]:
    identities = _mapping(value, "measurement runner identities")
    required = RELEASE_LANES | {RENDERING_DRIVER_IDENTITY}
    _exact_keys(identities, required, "measurement runner identities")
    return {name: validate_runner_identity(identities[name], name) for name in sorted(required)}


def _finite_numbers(
    value: Any,
    label: str,
    *,
    nonempty: bool = True,
    positive: bool = False,
) -> list[float]:
    if not isinstance(value, list) or (nonempty and not value):
        raise EvidenceError(f"{label} must be a nonempty array")
    result: list[float] = []
    for item in value:
        if (
            isinstance(item, bool)
            or not isinstance(item, (int, float))
            or not math.isfinite(item)
            or item < 0
            or (positive and item <= 0)
        ):
            qualifier = "positive" if positive else "nonnegative"
            raise EvidenceError(f"{label} must contain finite {qualifier} numbers")
        result.append(float(item))
    return result


def _booleans(value: Any, label: str) -> list[bool]:
    if not isinstance(value, list) or not value or any(not isinstance(item, bool) for item in value):
        raise EvidenceError(f"{label} must be a nonempty boolean array")
    return list(value)


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def _residual_samples(
    value: Any,
    registered_views: list[bool],
) -> tuple[list[float], int]:
    if not isinstance(value, list) or not value:
        raise EvidenceError("observations.residual_pixels must be a nonempty array")
    residuals: list[float] = []
    seen_observations: set[tuple[int, int]] = set()
    covered_views: set[int] = set()
    point_ids: set[int] = set()
    for index, raw in enumerate(value):
        record = _mapping(raw, f"observations.residual_pixels[{index}]")
        _exact_keys(
            record,
            {"view_index", "point_id", "residual_pixels"},
            f"observations.residual_pixels[{index}]",
        )
        view_index = record["view_index"]
        point_id = record["point_id"]
        residual = record["residual_pixels"]
        if (
            type(view_index) is not int
            or not 0 <= view_index < len(registered_views)
            or not registered_views[view_index]
        ):
            raise EvidenceError("residual view_index must identify a candidate-registered view")
        if type(point_id) is not int or point_id < 0:
            raise EvidenceError("residual point_id must be a nonnegative integer")
        if (
            isinstance(residual, bool)
            or not isinstance(residual, (int, float))
            or not math.isfinite(residual)
            or residual < 0
        ):
            raise EvidenceError("residual_pixels values must be finite and nonnegative")
        observation = (view_index, point_id)
        if observation in seen_observations:
            raise EvidenceError("residual observations must be unique view and point pairs")
        seen_observations.add(observation)
        covered_views.add(view_index)
        point_ids.add(point_id)
        residuals.append(float(residual))
    expected_views = {index for index, registered in enumerate(registered_views) if registered}
    if covered_views != expected_views:
        raise EvidenceError("residual observations must cover every candidate-registered view")
    return residuals, len(point_ids)


def _pose_samples(
    value: Any,
    candidate_registered: list[bool],
    colmap_registered: list[bool],
) -> tuple[list[float], list[float], list[float], list[float], list[float], list[float]]:
    pose = _mapping(value, "observations.pose")
    _exact_keys(pose, {"absolute", "relative"}, "observations.pose")
    common_views = [
        index
        for index, (candidate, colmap) in enumerate(
            zip(candidate_registered, colmap_registered, strict=True)
        )
        if candidate and colmap
    ]
    if len(common_views) < 2:
        raise EvidenceError("pose evidence requires at least two commonly registered views")
    absolute = pose["absolute"]
    if not isinstance(absolute, list) or len(absolute) != len(common_views):
        raise EvidenceError("pose.absolute must cover every commonly registered view")
    candidate_ate: list[float] = []
    colmap_ate: list[float] = []
    for index, raw in enumerate(absolute):
        record = _mapping(raw, f"pose.absolute[{index}]")
        _exact_keys(record, {"view_index", "candidate_ate", "colmap_ate"}, f"pose.absolute[{index}]")
        if record["view_index"] != common_views[index]:
            raise EvidenceError("pose.absolute view indices must match the common registration set")
        for field, destination in (
            ("candidate_ate", candidate_ate),
            ("colmap_ate", colmap_ate),
        ):
            number = record[field]
            if (
                isinstance(number, bool)
                or not isinstance(number, (int, float))
                or not math.isfinite(number)
                or number < 0
            ):
                raise EvidenceError(f"pose.absolute[{index}].{field} must be finite and nonnegative")
            destination.append(float(number))

    expected_pairs = list(zip(common_views, common_views[1:]))
    relative = pose["relative"]
    if not isinstance(relative, list) or len(relative) != len(expected_pairs):
        raise EvidenceError("pose.relative must cover every adjacent common-view pair")
    candidate_rotation: list[float] = []
    colmap_rotation: list[float] = []
    candidate_translation: list[float] = []
    colmap_translation: list[float] = []
    fields = {
        "from_view_index",
        "to_view_index",
        "candidate_rotation_rpe_degrees",
        "colmap_rotation_rpe_degrees",
        "candidate_translation_rpe_percentage_points",
        "colmap_translation_rpe_percentage_points",
    }
    destinations = (
        ("candidate_rotation_rpe_degrees", candidate_rotation),
        ("colmap_rotation_rpe_degrees", colmap_rotation),
        ("candidate_translation_rpe_percentage_points", candidate_translation),
        ("colmap_translation_rpe_percentage_points", colmap_translation),
    )
    for index, raw in enumerate(relative):
        record = _mapping(raw, f"pose.relative[{index}]")
        _exact_keys(record, fields, f"pose.relative[{index}]")
        if (record["from_view_index"], record["to_view_index"]) != expected_pairs[index]:
            raise EvidenceError("pose.relative pairs must match adjacent common registered views")
        for field, destination in destinations:
            number = record[field]
            if (
                isinstance(number, bool)
                or not isinstance(number, (int, float))
                or not math.isfinite(number)
                or number < 0
            ):
                raise EvidenceError(f"pose.relative[{index}].{field} must be finite and nonnegative")
            destination.append(float(number))
    return (
        candidate_ate,
        colmap_ate,
        candidate_rotation,
        colmap_rotation,
        candidate_translation,
        colmap_translation,
    )


def measured(value: Any) -> dict[str, Any]:
    return {"availability": "measured", "value": value}


def unavailable(reason: str = "not_measured") -> dict[str, Any]:
    return {"availability": "not_available", "reason": reason}


def _pipeline_metrics(value: Any) -> dict[str, Any]:
    raw = _mapping(value, "observations.pipeline_metrics")
    _exact_keys(raw, PIPELINE_METRICS, "observations.pipeline_metrics")
    result: dict[str, Any] = {}
    for name in sorted(PIPELINE_METRICS):
        item = raw[name]
        if item is None:
            result[name] = unavailable()
        elif name in PIPELINE_INTEGER_METRICS:
            if type(item) is not int or item < 0:
                raise EvidenceError(f"observations.pipeline_metrics.{name} must be null or a nonnegative integer")
            result[name] = measured(item)
        elif name in PIPELINE_NUMBER_METRICS:
            if (
                isinstance(item, bool)
                or not isinstance(item, (int, float))
                or not math.isfinite(item)
                or item < 0
            ):
                raise EvidenceError(f"observations.pipeline_metrics.{name} must be null or finite and nonnegative")
            result[name] = measured(float(item))
        elif name in PIPELINE_BOOLEAN_METRICS:
            if type(item) is not bool:
                raise EvidenceError(
                    f"observations.pipeline_metrics.{name} must be null or boolean"
                )
            result[name] = measured(item)
        elif item not in PIPELINE_ENUM_METRICS[name]:
            raise EvidenceError(f"observations.pipeline_metrics.{name} has an unsupported value")
        else:
            result[name] = measured(item)
    raster_values = {
        name: raw[name]
        for name in (
            "raster_fallback_count",
            "raster_exact_fallback_elapsed_seconds",
            "raster_exact_buffer_growth_count",
            "raster_exact_buffer_bytes_added",
            "raster_replay_elapsed_seconds",
            "raster_peak_exact_intersection_capacity",
        )
    }
    measured_raster = {name for name, item in raster_values.items() if item is not None}
    if measured_raster and len(measured_raster) != len(raster_values):
        raise EvidenceError("raster recovery pipeline metrics must be measured together")
    if measured_raster:
        fallback_count = raster_values["raster_fallback_count"]
        exact_elapsed = raster_values["raster_exact_fallback_elapsed_seconds"]
        growth_count = raster_values["raster_exact_buffer_growth_count"]
        bytes_added = raster_values["raster_exact_buffer_bytes_added"]
        replay_elapsed = raster_values["raster_replay_elapsed_seconds"]
        peak_capacity = raster_values["raster_peak_exact_intersection_capacity"]
        if peak_capacity > (1 << 32) - 1:
            raise EvidenceError("raster peak exact capacity exceeds the native counter range")
        if growth_count > fallback_count:
            raise EvidenceError("raster buffer growth count exceeds fallback count")
        if fallback_count == 0 and any(
            value != 0
            for value in (exact_elapsed, growth_count, bytes_added, replay_elapsed, peak_capacity)
        ):
            raise EvidenceError("zero raster fallbacks require zero recovery metrics")
        if fallback_count > 0 and (
            exact_elapsed <= 0
            or growth_count <= 0
            or bytes_added <= 0
            or replay_elapsed <= 0
            or peak_capacity <= 2_048
        ):
            raise EvidenceError("raster fallback recovery evidence is incomplete")
        if growth_count == 0 and (bytes_added != 0 or peak_capacity != 0):
            raise EvidenceError("zero raster buffer growth requires zero allocation evidence")
        if growth_count > 0 and (bytes_added == 0 or peak_capacity <= 2_048):
            raise EvidenceError("raster buffer growth evidence is incomplete")
        maximum_tile_intersections = raw["maximum_tile_intersections"]
        if maximum_tile_intersections is not None:
            crossed_overflow_threshold = maximum_tile_intersections > 2_048
            if (fallback_count > 0) != crossed_overflow_threshold:
                raise EvidenceError(
                    "raster fallback evidence contradicts the measured overflow threshold"
                )
            if crossed_overflow_threshold and peak_capacity < maximum_tile_intersections:
                raise EvidenceError(
                    "raster peak exact capacity is below the measured tile intersections"
                )
    orientation_status = raw["orientation_status"]
    physical_error = raw["orientation_physical_up_error_degrees"]
    sign_correct = raw["orientation_sign_correct"]
    if orientation_status == "verified":
        if physical_error is None or sign_correct is None:
            raise EvidenceError(
                "verified orientation requires labeled physical-up error and sign evidence"
            )
    elif orientation_status == "axis_aligned_sign_unverified":
        if physical_error is None or sign_correct is not None:
            raise EvidenceError(
                "axis_aligned_sign_unverified orientation requires physical-up error without a sign claim"
            )
    elif physical_error is not None or sign_correct is not None:
        raise EvidenceError(
            "unresolved or unavailable orientation cannot claim labeled physical-up or sign evidence"
        )
    return result


def _validate_orientation_label(path: Path) -> None:
    raw = _mapping(
        _load_bounded_json(path, "orientation-label.json"),
        "orientation label",
    )
    _exact_keys(
        raw,
        {"schema_version", "coordinate_space", "physical_up"},
        "orientation label",
    )
    if raw["schema_version"] != 1 or raw["coordinate_space"] != "ground_truth_world":
        raise EvidenceError(
            "orientation label must use schema 1 ground-truth-world coordinates"
        )
    physical_up = _mapping(raw["physical_up"], "orientation label physical_up")
    _exact_keys(physical_up, {"x", "y", "z"}, "orientation label physical_up")
    components: list[float] = []
    for name in ("x", "y", "z"):
        value = physical_up[name]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
        ):
            raise EvidenceError(
                f"orientation label physical_up.{name} must be finite"
            )
        components.append(float(value))
    if math.sqrt(sum(value * value for value in components)) <= 1e-12:
        raise EvidenceError("orientation label physical_up must be nonzero")


def validate_orientation_metrics(value: Any, label: str = "orientation metrics") -> dict[str, Any]:
    raw = _mapping(value, label)
    _exact_keys(raw, ORIENTATION_EVIDENCE_FIELDS, label)
    status = raw["orientation_status"]
    if status not in PIPELINE_ENUM_METRICS["orientation_status"]:
        raise EvidenceError(f"{label}.orientation_status is invalid")

    result = dict(raw)
    support = raw["alignment_support_count"]
    if type(support) is not int or support < 8:
        raise EvidenceError(f"{label}.alignment_support_count must be at least 8")
    for name in (
        "alignment_median_residual_degrees",
        "alignment_p90_residual_degrees",
    ):
        result[name] = _nonnegative_number(raw[name], f"{label}.{name}")
    if result["alignment_p90_residual_degrees"] < result[
        "alignment_median_residual_degrees"
    ]:
        raise EvidenceError(f"{label} alignment p90 residual cannot be below its median")

    quaternion = raw["candidate_source_to_ground_truth_wxyz"]
    if (
        not isinstance(quaternion, list)
        or len(quaternion) != 4
        or any(
            isinstance(component, bool)
            or not isinstance(component, (int, float))
            or not math.isfinite(component)
            for component in quaternion
        )
    ):
        raise EvidenceError(f"{label}.candidate_source_to_ground_truth_wxyz is invalid")
    normalized_quaternion = [float(component) for component in quaternion]
    if abs(math.sqrt(sum(component * component for component in normalized_quaternion)) - 1) > 1e-6:
        raise EvidenceError(f"{label} source-to-ground-truth quaternion must be normalized")
    first_nonzero = next(
        (component for component in normalized_quaternion if component != 0),
        0.0,
    )
    if first_nonzero < 0:
        raise EvidenceError(f"{label} source-to-ground-truth quaternion must be sign-canonical")
    result["candidate_source_to_ground_truth_wxyz"] = normalized_quaternion

    physical_error = raw["orientation_physical_up_error_degrees"]
    result["orientation_physical_up_error_degrees"] = (
        None
        if physical_error is None
        else _nonnegative_number(
            physical_error,
            f"{label}.orientation_physical_up_error_degrees",
        )
    )
    sign_correct = raw["orientation_sign_correct"]
    if sign_correct is not None and type(sign_correct) is not bool:
        raise EvidenceError(f"{label}.orientation_sign_correct must be null or boolean")
    if status == "verified":
        if result["orientation_physical_up_error_degrees"] is None or sign_correct is None:
            raise EvidenceError(f"{label} verified orientation lacks directed up evidence")
    elif status == "axis_aligned_sign_unverified":
        if result["orientation_physical_up_error_degrees"] is None or sign_correct is not None:
            raise EvidenceError(
                f"{label} axis_aligned_sign_unverified orientation requires physical-up "
                "error without a sign claim"
            )
    elif result["orientation_physical_up_error_degrees"] is not None or sign_correct is not None:
        raise EvidenceError(f"{label} unresolved orientation cannot claim physical up")
    angle_fields = (
        "alignment_median_residual_degrees",
        "alignment_p90_residual_degrees",
        "orientation_physical_up_error_degrees",
    )
    if any(result[name] is not None and result[name] > 180 for name in angle_fields):
        raise EvidenceError(f"{label} angular evidence cannot exceed 180 degrees")
    return result


def _paired_losses(
    records: Any,
    label: str,
    expected_holdout_indices: list[int],
    *,
    include_paired_baseline: bool,
) -> tuple[list[float], list[float], list[float], list[float], list[float], list[float]]:
    if not isinstance(records, list) or not records:
        raise EvidenceError(f"{label} must be a nonempty array")
    psnr: list[float] = []
    ssim: list[float] = []
    lpips: list[float] = []
    paired_psnr: list[float] = []
    paired_ssim: list[float] = []
    paired_lpips: list[float] = []
    fields = {
        "holdout_index",
        "candidate_psnr",
        "reference_psnr",
        "candidate_ssim",
        "reference_ssim",
        "candidate_lpips",
        "reference_lpips",
    }
    if include_paired_baseline:
        fields.update({"baseline_psnr", "baseline_ssim", "baseline_lpips"})
    for index, raw in enumerate(records):
        record = _mapping(raw, f"{label}[{index}]")
        _exact_keys(record, fields, f"{label}[{index}]")
        if record["holdout_index"] != expected_holdout_indices[index]:
            raise EvidenceError(
                f"{label} must cover each bound holdout index exactly once and in order"
            )
        values = {}
        for field in fields - {"holdout_index"}:
            number = record[field]
            if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number):
                raise EvidenceError(f"{label}[{index}].{field} must be finite")
            values[field] = float(number)
        for field, number in values.items():
            if field.endswith("_psnr") and number < 0:
                raise EvidenceError(f"{label}[{index}].{field} is outside the rendering domain")
            if field.endswith("_ssim") and not 0 <= number <= 1:
                raise EvidenceError(f"{label}[{index}].{field} is outside the rendering domain")
            if field.endswith("_lpips") and number < 0:
                raise EvidenceError(f"{label}[{index}].{field} is outside the rendering domain")
        psnr.append(max(0.0, values["reference_psnr"] - values["candidate_psnr"]))
        ssim.append(max(0.0, values["reference_ssim"] - values["candidate_ssim"]))
        lpips.append(max(0.0, values["candidate_lpips"] - values["reference_lpips"]))
        if include_paired_baseline:
            paired_psnr.append(max(0.0, values["baseline_psnr"] - values["candidate_psnr"]))
            paired_ssim.append(max(0.0, values["baseline_ssim"] - values["candidate_ssim"]))
            paired_lpips.append(max(0.0, values["candidate_lpips"] - values["baseline_lpips"]))
    return psnr, ssim, lpips, paired_psnr, paired_ssim, paired_lpips


def _positive_number(value: Any, label: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value <= 0
    ):
        raise EvidenceError(f"{label} must be positive and finite")
    return float(value)


def _nonnegative_number(value: Any, label: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < 0
    ):
        raise EvidenceError(f"{label} must be nonnegative and finite")
    return float(value)


def _validate_timing_repeatability(
    grouped: Mapping[str, list[dict[str, float]]],
    label: str,
    measurement_fields: tuple[str, ...],
) -> None:
    for variant, records in grouped.items():
        for field in measurement_fields:
            values = [record[field] for record in records]
            median = statistics.median(values)
            spread = max(values) - min(values)
            maximum_spread = max(0.05, 0.25 * median)
            maximum_ratio = max(values) / min(values)
            if spread > maximum_spread + 1e-9 or maximum_ratio > 1.5 + 1e-9:
                raise EvidenceError(
                    f"{label} {variant} {field} failed the timing repeatability gate"
                )


def _validate_timing_sequence(
    value: Any,
    label: str,
    *,
    repetitions: int,
    measurement_fields: tuple[str, ...],
    baseline_variant: str = "baseline",
    candidate_variant: str = "candidate",
) -> dict[str, list[dict[str, float]]]:
    expected_count = 2 + repetitions * 2
    if not isinstance(value, list) or len(value) != expected_count:
        raise EvidenceError(
            f"{label} must contain one discarded warm-up per variant and "
            f"{repetitions} counterbalanced paired repetitions"
        )
    expected_variants = [baseline_variant, candidate_variant]
    for pair_index in range(repetitions):
        pair = (baseline_variant, candidate_variant)
        expected_variants.extend(pair if pair_index % 2 == 0 else reversed(pair))
    grouped: dict[str, list[dict[str, float]]] = {
        baseline_variant: [],
        candidate_variant: [],
    }
    for index, (raw, expected_variant) in enumerate(zip(value, expected_variants)):
        record = _mapping(raw, f"{label}[{index}]")
        expected_fields = {"run_id", "variant", "discarded", *measurement_fields}
        _exact_keys(record, expected_fields, f"{label}[{index}]")
        if record["variant"] != expected_variant:
            raise EvidenceError(
                f"{label} must follow the counterbalanced baseline/candidate order"
            )
        run_id = _token(record["run_id"], f"{label}[{index}].run_id")
        expected_discarded = index < 2
        if type(record["discarded"]) is not bool or record["discarded"] != expected_discarded:
            raise EvidenceError(f"{label} must discard exactly one warm-up per variant")
        measurements = {
            field: _positive_number(record[field], f"{label}[{index}].{field}")
            for field in measurement_fields
        }
        component_fields = set(measurement_fields) - {"end_to_end_seconds"}
        if "end_to_end_seconds" in measurements and component_fields and measurements[
            "end_to_end_seconds"
        ] + 1e-9 < sum(measurements[field] for field in component_fields):
            raise EvidenceError(f"{label}[{index}] end-to-end time is below its phase sum")
        measurements["run_id"] = run_id
        if not expected_discarded:
            grouped[expected_variant].append(measurements)
    _validate_timing_repeatability(grouped, label, measurement_fields)
    return grouped


def _validate_candidate_timing(value: Any) -> list[float]:
    if not isinstance(value, list) or len(value) != 4:
        raise EvidenceError(
            "timing.candidate_runs must contain one discarded warm-up and three measured repetitions"
        )
    result: list[float] = []
    fields = {"run_id", "variant", "discarded", "end_to_end_seconds"}
    for index, raw in enumerate(value):
        record = _mapping(raw, f"timing.candidate_runs[{index}]")
        _exact_keys(record, fields, f"timing.candidate_runs[{index}]")
        if record["variant"] != "candidate":
            raise EvidenceError("timing.candidate_runs may contain candidate runs only")
        _token(record["run_id"], f"timing.candidate_runs[{index}].run_id")
        expected_discarded = index == 0
        if type(record["discarded"]) is not bool or record["discarded"] != expected_discarded:
            raise EvidenceError("timing.candidate_runs must mark only its first warm-up as discarded")
        seconds = _positive_number(
            record["end_to_end_seconds"],
            f"timing.candidate_runs[{index}].end_to_end_seconds",
        )
        if not expected_discarded:
            result.append(seconds)
    _validate_timing_repeatability(
        {"candidate": [{"end_to_end_seconds": seconds} for seconds in result]},
        "timing.candidate_runs",
        ("end_to_end_seconds",),
    )
    return result


def _timing_metrics(
    timing: Mapping[str, Any],
    lane: str,
    gate_scopes: set[str],
) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    if lane == LANE_REFERENCE and "suite_performance" in gate_scopes:
        _exact_keys(
            timing,
            {"ordinary_runs", "phase_runs", "fast_profile_runs"},
            "observations.timing",
        )
        ordinary = _validate_timing_sequence(
            timing["ordinary_runs"],
            "timing.ordinary_runs",
            repetitions=3,
            measurement_fields=("end_to_end_seconds", "geometry_seconds", "training_seconds"),
        )
        phases = _validate_timing_sequence(
            timing["phase_runs"],
            "timing.phase_runs",
            repetitions=5,
            measurement_fields=("end_to_end_seconds", "matcher_seconds", "mapping_seconds"),
        )
        fast_profile = _validate_timing_sequence(
            timing["fast_profile_runs"],
            "timing.fast_profile_runs",
            repetitions=3,
            measurement_fields=("end_to_end_seconds",),
            baseline_variant="accurate_reference",
            candidate_variant="fast_candidate",
        )
        candidate_end = [record["end_to_end_seconds"] for record in ordinary["candidate"]]
        candidate_geometry = [record["geometry_seconds"] for record in ordinary["candidate"]]
        baseline_geometry = [record["geometry_seconds"] for record in ordinary["baseline"]]
        candidate_training = [record["training_seconds"] for record in ordinary["candidate"]]
        candidate_matcher = [record["matcher_seconds"] for record in phases["candidate"]]
        baseline_matcher = [record["matcher_seconds"] for record in phases["baseline"]]
        candidate_mapping = [record["mapping_seconds"] for record in phases["candidate"]]
        baseline_mapping = [record["mapping_seconds"] for record in phases["baseline"]]
        fast_candidate_end = [
            record["end_to_end_seconds"] for record in fast_profile["fast_candidate"]
        ]
        accurate_reference_end = [
            record["end_to_end_seconds"] for record in fast_profile["accurate_reference"]
        ]
        candidate_median = statistics.median(candidate_end)
        metrics.update(
            {
                "wall_time_seconds": measured(candidate_median),
                "m4_max_p50_seconds": measured(candidate_median),
                "fast_end_to_end_speedup": measured(
                    statistics.median(accurate_reference_end)
                    / statistics.median(fast_candidate_end)
                ),
                "balanced_geometry_speedup": measured(
                    statistics.median(baseline_geometry) / statistics.median(candidate_geometry)
                ),
                "geometry_seconds": measured(statistics.median(candidate_geometry)),
                "training_seconds": measured(statistics.median(candidate_training)),
                "matcher_seconds": measured(statistics.median(candidate_matcher)),
                "mapping_seconds": measured(statistics.median(candidate_mapping)),
                "matching_speedup": measured(
                    statistics.median(baseline_matcher) / statistics.median(candidate_matcher)
                ),
                "mapping_speedup": measured(
                    statistics.median(baseline_mapping) / statistics.median(candidate_mapping)
                ),
            }
        )
        return metrics

    if lane == LANE_REFERENCE and "scene_quality" in gate_scopes:
        _exact_keys(
            timing,
            {"ordinary_runs", "fast_profile_runs"},
            "observations.timing",
        )
        ordinary = _validate_timing_sequence(
            timing["ordinary_runs"],
            "timing.ordinary_runs",
            repetitions=3,
            measurement_fields=("end_to_end_seconds", "geometry_seconds", "training_seconds"),
        )
        _validate_timing_sequence(
            timing["fast_profile_runs"],
            "timing.fast_profile_runs",
            repetitions=3,
            measurement_fields=("end_to_end_seconds",),
            baseline_variant="accurate_reference",
            candidate_variant="fast_candidate",
        )
        metrics["wall_time_seconds"] = measured(
            statistics.median(record["end_to_end_seconds"] for record in ordinary["candidate"])
        )
        return metrics

    _exact_keys(timing, {"candidate_runs"}, "observations.timing")
    candidate_median = statistics.median(_validate_candidate_timing(timing["candidate_runs"]))
    metrics["wall_time_seconds"] = measured(candidate_median)
    if lane == LANE_CONSTRAINED and "suite_performance" in gate_scopes:
        metrics["constrained_fast_p50_seconds"] = measured(candidate_median)
    elif lane == LANE_EIGHT_GB and "suite_performance" in gate_scopes:
        metrics["eight_gb_fast_p50_seconds"] = measured(candidate_median)
    return metrics


def _execution_runs(
    timing: Mapping[str, Any],
    lane: str,
    gate_scopes: set[str],
) -> list[dict[str, Any]]:
    if lane == LANE_REFERENCE and "suite_performance" in gate_scopes:
        group_names = ("ordinary_runs", "phase_runs", "fast_profile_runs")
    elif lane == LANE_REFERENCE and "scene_quality" in gate_scopes:
        group_names = ("ordinary_runs", "fast_profile_runs")
    else:
        group_names = ("candidate_runs",)
    runs: list[dict[str, Any]] = []
    seen: set[str] = set()
    for group_name in group_names:
        records = timing.get(group_name)
        if not isinstance(records, list):
            raise EvidenceError(f"timing.{group_name} must be an array")
        for index, raw in enumerate(records):
            record = _mapping(raw, f"timing.{group_name}[{index}]")
            run_id = _token(record.get("run_id"), f"timing.{group_name}[{index}].run_id")
            if run_id in seen:
                raise EvidenceError("timing run IDs must be unique")
            seen.add(run_id)
            runs.append(
                {
                    "run_id": run_id,
                    "phase": group_name.removesuffix("_runs"),
                    "variant": record.get("variant"),
                    "duration": _positive_number(
                        record.get("end_to_end_seconds"),
                        f"timing.{group_name}[{index}].end_to_end_seconds",
                    ),
                }
            )
    return runs


def _published_training_duration(
    commands: Any,
    timing: Mapping[str, Any],
) -> float:
    if not isinstance(commands, list):
        raise EvidenceError("published training receipt is unavailable")
    published = [
        _mapping(command, f"commands[{index}]")
        for index, command in enumerate(commands)
        if isinstance(command, Mapping) and command.get("published_output") is True
    ]
    if len(published) != 1:
        raise EvidenceError("valid evidence requires exactly one published training receipt")
    receipt = published[0]
    run_id = _token(receipt.get("run_id"), "published training receipt run_id")
    phase = _token(receipt.get("phase"), "published training receipt phase")
    variant = _token(receipt.get("variant"), "published training receipt variant")
    expected_phase = "ordinary" if "ordinary_runs" in timing else "candidate"
    if variant != "candidate" or phase != expected_phase:
        raise EvidenceError("published output must come from the candidate end-to-end run")
    group_name = f"{phase}_runs"
    records = timing.get(group_name)
    if not isinstance(records, list):
        raise EvidenceError("published training receipt has no timing group")
    matching = [
        _mapping(record, f"timing.{group_name}[{index}]")
        for index, record in enumerate(records)
        if isinstance(record, Mapping)
        and record.get("run_id") == run_id
        and record.get("variant") == variant
    ]
    if len(matching) != 1:
        raise EvidenceError("published training receipt does not resolve to one timing run")
    record = matching[0]
    if record.get("discarded") is not False:
        raise EvidenceError("published output must come from a measured candidate end-to-end run")
    field = "training_seconds" if "training_seconds" in record else "end_to_end_seconds"
    return _positive_number(
        record.get(field),
        f"published timing run {group_name}.{run_id}.{field}",
    )


def _configuration_digest(value: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json_bytes(value))


def _baseline_mapper_cadence(
    configuration: Mapping[str, Any],
) -> tuple[float, float, int, int]:
    frames = configuration.get("ba_global_frames_ratio")
    points = configuration.get("ba_global_points_ratio")
    global_refinements = configuration.get("ba_global_max_refinements")
    local_refinements = configuration.get("ba_local_max_refinements")
    if (
        frames != 1.1
        or points != 1.1
        or global_refinements != 5
        or local_refinements != 2
    ):
        raise EvidenceError(
            "request baseline mapper effective defaults must remain 1.1/1.1/global5/local2"
        )
    return 1.1, 1.1, 5, 2


def _candidate_mapper_cadence(
    configuration: Mapping[str, Any],
) -> tuple[float, float, int, int]:
    topology = configuration["input_topology"]
    if not isinstance(topology, str) or topology not in {
        "continuous",
        "segmented_mixed",
        "unordered",
    }:
        raise EvidenceError("request input topology is invalid for mapper cadence")
    expected_ratio = 4.0 if topology == "continuous" else 1.1
    expected_local = 1 if topology == "continuous" else 2
    frames = configuration["ba_global_frames_ratio"]
    points = configuration["ba_global_points_ratio"]
    global_refinements = configuration["ba_global_max_refinements"]
    local_refinements = configuration["ba_local_max_refinements"]
    if (
        isinstance(frames, bool)
        or isinstance(points, bool)
        or not isinstance(frames, (int, float))
        or not isinstance(points, (int, float))
        or not math.isfinite(frames)
        or not math.isfinite(points)
    ):
        raise EvidenceError("candidate mapper global ratios must be finite numbers")
    if type(local_refinements) is not int or local_refinements <= 0:
        raise EvidenceError("ba_local_max_refinements must be a positive integer")
    if global_refinements != 5:
        raise EvidenceError("ba_global_max_refinements must remain 5")
    promoted_convergence = {
        "ba_local_max_num_iterations": 10,
        "ba_local_function_tolerance": 0.001,
        "ba_global_function_tolerance": 0.000_001,
        "ba_local_num_images": 6,
    }
    for field, expected in promoted_convergence.items():
        if configuration[field] != expected:
            raise EvidenceError(f"{field} must remain {expected!r}")
    if frames != expected_ratio or points != expected_ratio or local_refinements != expected_local:
        raise EvidenceError(
            f"{topology} mapper cadence requires global ratios {expected_ratio} "
            f"and local refinements {expected_local}"
        )
    return float(frames), float(points), global_refinements, local_refinements


MAPPER_CADENCE_OPTIONS = (
    "--Mapper.ba_global_frames_ratio",
    "--Mapper.ba_global_points_ratio",
    "--Mapper.ba_global_max_refinements",
    "--Mapper.ba_local_max_refinements",
    "--Mapper.ba_local_max_num_iterations",
    "--Mapper.ba_local_function_tolerance",
    "--Mapper.ba_global_function_tolerance",
    "--Mapper.ba_local_num_images",
)


def _validate_mapper_invocation_argv(
    raw: Any,
    variant: str,
    *,
    expected_cadence: tuple[float, float, int, int] | None,
    label: str,
) -> None:
    if not isinstance(raw, list) or len(raw) < 2 or any(
        not isinstance(argument, str) or not argument for argument in raw
    ):
        raise EvidenceError(f"{label} argv must be a nonempty redacted argument array")
    if any("/Users/" in argument or "/home/" in argument for argument in raw):
        raise EvidenceError(f"{label} argv must use redacted paths")
    expected_executable = (
        "baseline-toolchain://resolved/bin/colmap"
        if variant == "baseline"
        else "toolchain://resolved/bin/colmap"
    )
    if raw[0] != expected_executable or raw[1] != "mapper":
        raise EvidenceError(f"{label} argv does not identify the canonical COLMAP mapper executable")
    if expected_cadence is None:
        if any(
            argument == option or argument.startswith(option + "=")
            for argument in raw
            for option in MAPPER_CADENCE_OPTIONS
        ):
            raise EvidenceError(
                f"{label} cannot contain production cadence options"
            )
        return
    expected = {
        "--Mapper.ba_global_frames_ratio": str(expected_cadence[0]),
        "--Mapper.ba_global_points_ratio": str(expected_cadence[1]),
        "--Mapper.ba_global_max_refinements": str(expected_cadence[2]),
        "--Mapper.ba_local_max_refinements": str(expected_cadence[3]),
        "--Mapper.ba_local_max_num_iterations": "10",
        "--Mapper.ba_local_function_tolerance": "0.001",
        "--Mapper.ba_global_function_tolerance": "1e-06",
        "--Mapper.ba_local_num_images": "6",
    }
    for option, expected_value in expected.items():
        indices = [index for index, argument in enumerate(raw) if argument == option]
        ambiguous = any(argument.startswith(option + "=") for argument in raw)
        if len(indices) != 1 or ambiguous or indices[0] + 1 >= len(raw):
            raise EvidenceError(f"{label} cadence must contain one split {option} value")
        if raw[indices[0] + 1] != expected_value:
            raise EvidenceError(f"{label} cadence {option} does not match the bound value")


def _validate_mapper_invocations(
    raw: Any,
    variant: str,
    request: Mapping[str, Any],
    *,
    valid_outcome: bool,
) -> None:
    if not isinstance(raw, list):
        raise EvidenceError("mapper_invocations must be an ordered array")
    if not valid_outcome:
        if raw:
            raise EvidenceError("invalid-input execution receipts require empty mapper_invocations")
        return
    invocations: list[Mapping[str, Any]] = []
    for index, item in enumerate(raw):
        invocation = _mapping(item, f"mapper_invocations[{index}]")
        _exact_keys(
            invocation,
            {
                "argv",
                "outcome",
                "matching_attempt",
                "pair_list_digest",
                "descriptor_matcher",
            },
            f"mapper_invocations[{index}]",
        )
        if invocation["outcome"] not in {"accepted", "rejected_geometry_gate"}:
            raise EvidenceError(f"mapper_invocations[{index}].outcome is invalid")
        matching_attempt = invocation["matching_attempt"]
        if type(matching_attempt) is not int or matching_attempt <= 0:
            raise EvidenceError(
                f"mapper_invocations[{index}].matching_attempt must be a positive integer"
            )
        _digest(
            invocation["pair_list_digest"],
            f"mapper_invocations[{index}].pair_list_digest",
        )
        if invocation["descriptor_matcher"] not in {"faiss", "exact"}:
            raise EvidenceError(
                f"mapper_invocations[{index}].descriptor_matcher is invalid"
            )
        invocations.append(invocation)
    accepted = [
        index for index, invocation in enumerate(invocations)
        if invocation["outcome"] == "accepted"
    ]
    if len(accepted) != 1:
        raise EvidenceError("mapper_invocations require exactly one accepted invocation")
    if accepted[0] != len(invocations) - 1:
        raise EvidenceError("the accepted mapper invocation must be last")
    if any(
        invocation["outcome"] != "rejected_geometry_gate"
        for invocation in invocations[:-1]
    ):
        raise EvidenceError(
            "every mapper invocation before the accepted final invocation must fail its geometry gate"
        )

    if variant in {"baseline", "accurate_reference"}:
        if len(invocations) != 1:
            raise EvidenceError(f"{variant} requires exactly one mapper invocation")
        if invocations[0]["descriptor_matcher"] != "exact":
            raise EvidenceError(f"{variant} mapper invocation must record exact matching")
        _validate_mapper_invocation_argv(
            invocations[0]["argv"],
            variant,
            expected_cadence=None,
            label=f"{variant} mapper invocation",
        )
        return

    initial_cadence = _candidate_mapper_cadence(request["candidate_run_configuration"])
    topology = request["candidate_run_configuration"]["input_topology"]
    planned_matcher = request["candidate_run_configuration"]["descriptor_matcher"]
    first_invocation = invocations[0]
    if first_invocation["descriptor_matcher"] != planned_matcher:
        if (
            first_invocation["descriptor_matcher"] != "exact"
            or first_invocation["matching_attempt"] <= 1
        ):
            raise EvidenceError(
                "candidate first exact mapper invocation requires a prior FAISS matching attempt"
            )
    if topology != "continuous":
        for index, invocation in enumerate(invocations):
            _validate_mapper_invocation_argv(
                invocation["argv"],
                variant,
                expected_cadence=initial_cadence,
                label=f"{topology} candidate mapper invocation {index}",
            )
            if index == 0:
                continue
            previous = invocations[index - 1]
            if invocation["matching_attempt"] <= previous["matching_attempt"]:
                raise EvidenceError(
                    f"{topology} mapper matching attempts must strictly increase after a retry"
                )
            if (
                invocation["pair_list_digest"] == previous["pair_list_digest"]
                and invocation["descriptor_matcher"] == previous["descriptor_matcher"]
            ):
                raise EvidenceError(
                    f"{topology} mapper retries must change the pair list or matcher"
                )
            if (
                previous["descriptor_matcher"] == "exact"
                and invocation["descriptor_matcher"] == "faiss"
            ):
                raise EvidenceError("mapper recovery cannot return from exact to faiss matching")
        return

    _validate_mapper_invocation_argv(
        invocations[0]["argv"],
        variant,
        expected_cadence=initial_cadence,
        label="continuous candidate fast 4.0/1 invocation",
    )
    if len(invocations) == 1:
        return
    for index, invocation in enumerate(invocations[1:], start=1):
        _validate_mapper_invocation_argv(
            invocation["argv"],
            variant,
            expected_cadence=(1.4, 1.4, 5, 2),
            label=f"continuous candidate conservative 1.4/2 recovery invocation {index}",
        )
    if any(
        invocations[1][field] != invocations[0][field]
        for field in ("matching_attempt", "pair_list_digest", "descriptor_matcher")
    ):
        raise EvidenceError(
            "the first continuous conservative retry must reuse the fast mapper pair graph"
        )
    for index in range(2, len(invocations)):
        previous = invocations[index - 1]
        invocation = invocations[index]
        if invocation["matching_attempt"] <= previous["matching_attempt"]:
            raise EvidenceError(
                "continuous mapper matching attempts must strictly increase after rematching"
            )
        if (
            invocation["pair_list_digest"] == previous["pair_list_digest"]
            and invocation["descriptor_matcher"] == previous["descriptor_matcher"]
        ):
            raise EvidenceError(
                "continuous mapper rematches must change the pair list or matcher"
            )
        if (
            previous["descriptor_matcher"] == "exact"
            and invocation["descriptor_matcher"] == "faiss"
        ):
            raise EvidenceError("mapper recovery cannot return from exact to faiss matching")


def _expected_variant_identity(
    variant: str,
    request: Mapping[str, Any],
) -> tuple[str, str, str, tuple[str, ...]]:
    binding = request["binding"]
    if variant == "baseline":
        configuration = request["baseline_run_configuration"]
        return (
            binding["baseline_git_commit"],
            binding["baseline_toolchain_identity"],
            _configuration_digest(configuration),
            ("baseline://", "baseline-toolchain://"),
        )
    if variant == "candidate":
        configuration = request["candidate_run_configuration"]
        prefixes = ("candidate://", "toolchain://")
    elif variant == "fast_candidate":
        configuration = {
            **request["candidate_run_configuration"],
            "detail_profile": "fast",
            "trainer_iterations": 3000,
            "trainer_plateau_window": 400,
        }
        prefixes = ("fast-candidate://", "toolchain://")
    elif variant == "accurate_reference":
        configuration = ACCURATE_REFERENCE_CONFIGURATION
        prefixes = ("accurate-reference://", "toolchain://")
    else:
        raise EvidenceError(f"unsupported execution variant: {variant}")
    return (
        binding["git_commit"],
        binding["toolchain_identity"],
        _configuration_digest(configuration),
        prefixes,
    )


def _read_command_log(path: Path) -> list[Any]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        return [
            _decode_json_text(line, "command_log")
            for line in lines
            if line.strip()
        ]
    except EvidenceError:
        raise
    except (OSError, UnicodeError, ValueError) as error:
        raise EvidenceError("command_log is not valid JSONL") from error


def _validate_execution_receipts(
    commands: Any,
    command_log_path: Path,
    request: Mapping[str, Any],
    runner_identity: Mapping[str, Any],
    timing: Mapping[str, Any] | None,
    actual: Mapping[str, Any],
    published_output_sha256: str | None,
) -> list[dict[str, Any]]:
    if not isinstance(commands, list) or not commands:
        raise EvidenceError("observations.commands must be a nonempty receipt array")
    if _read_command_log(command_log_path) != commands:
        raise EvidenceError("command_log does not match the bound execution receipts")
    scopes = set(request["gate_scopes"])
    valid_outcome = request["expected_outcome"]["kind"] == "valid"
    if valid_outcome:
        if timing is None:
            raise EvidenceError("valid execution receipts require timing records")
        expected_runs = _execution_runs(timing, request["binding"]["lane"], scopes)
    else:
        expected_runs = [
            {
                "run_id": "invalid-input-0",
                "phase": "invalid_input",
                "variant": "candidate",
                "duration": None,
            }
        ]
    if len(commands) != len(expected_runs):
        raise EvidenceError("execution receipts do not match the timing run closure")

    receipt_fields = {
        "run_id",
        "phase",
        "variant",
        "argv",
        "mapper_invocations",
        "started_monotonic_seconds",
        "ended_monotonic_seconds",
        "process_cpu_microseconds",
        "exit_code",
        "checkout_commit",
        "toolchain_identity",
        "run_configuration_digest",
        "executable_sha256",
        "output_sha256",
        "scene_id",
        "input_digest",
        "scale",
        "lane",
        "published_output",
    }
    previous_end = -math.inf
    published_receipts = 0
    for index, (raw, expected) in enumerate(zip(commands, expected_runs, strict=True)):
        receipt = _mapping(raw, f"commands[{index}]")
        _exact_keys(receipt, receipt_fields, f"commands[{index}]")
        for field in ("run_id", "phase", "variant"):
            if receipt[field] != expected[field]:
                raise EvidenceError(f"commands[{index}].{field} does not match its timing record")
        started = receipt["started_monotonic_seconds"]
        ended = receipt["ended_monotonic_seconds"]
        if (
            isinstance(started, bool)
            or isinstance(ended, bool)
            or not isinstance(started, (int, float))
            or not isinstance(ended, (int, float))
            or not math.isfinite(started)
            or not math.isfinite(ended)
            or started < 0
            or ended <= started
            or started < previous_end
        ):
            raise EvidenceError("execution receipt timestamps are invalid or overlap")
        previous_end = float(ended)
        process_cpu = _mapping(
            receipt["process_cpu_microseconds"],
            f"commands[{index}].process_cpu_microseconds",
        )
        try:
            _exact_keys(
                process_cpu,
                {"user", "system"},
                f"commands[{index}].process_cpu_microseconds",
            )
        except EvidenceError as error:
            raise EvidenceError("execution receipt process CPU fields are invalid") from error
        if any(
            type(process_cpu[field]) is not int
            or not 0 <= process_cpu[field] < 1 << 64
            for field in ("user", "system")
        ):
            raise EvidenceError("execution receipt process CPU time is outside UInt64")
        if expected["duration"] is not None and not math.isclose(
            float(ended) - float(started),
            expected["duration"],
            rel_tol=0,
            abs_tol=1e-6,
        ):
            raise EvidenceError("execution receipt duration does not match its timing record")
        expected_exit = 0 if valid_outcome else actual["exit_code"]
        if type(receipt["exit_code"]) is not int or receipt["exit_code"] != expected_exit:
            raise EvidenceError("execution receipt exit code does not match the run outcome")
        checkout, toolchain, configuration_digest, prefixes = _expected_variant_identity(
            receipt["variant"],
            request,
        )
        if receipt["checkout_commit"] != checkout:
            raise EvidenceError("execution receipt checkout commit is invalid")
        if receipt["toolchain_identity"] != toolchain:
            raise EvidenceError("execution receipt toolchain identity is invalid")
        if receipt["run_configuration_digest"] != configuration_digest:
            raise EvidenceError("execution receipt configuration digest is invalid")
        if receipt["executable_sha256"] != runner_identity["sha256"]:
            raise EvidenceError("execution receipt executable digest is invalid")
        for field, expected_value in (
            ("scene_id", request["binding"]["scene_id"]),
            ("input_digest", request["binding"]["input_digest"]),
            ("scale", request["binding"]["scale"]),
            ("lane", request["binding"]["lane"]),
        ):
            if receipt[field] != expected_value:
                raise EvidenceError(f"execution receipt {field} is invalid")
        _digest(receipt["output_sha256"], f"commands[{index}].output_sha256")
        if type(receipt["published_output"]) is not bool:
            raise EvidenceError("execution receipt published_output must be boolean")
        if receipt["published_output"]:
            published_receipts += 1
            if published_output_sha256 is None or receipt["output_sha256"] != published_output_sha256:
                raise EvidenceError("published execution receipt does not match output_ply")
        argv = receipt["argv"]
        if not isinstance(argv, list) or not argv:
            raise EvidenceError("execution receipt argv must be a nonempty argument array")
        for argument in argv:
            if (
                not isinstance(argument, str)
                or not argument
                or "/Users/" in argument
                or "/home/" in argument
            ):
                raise EvidenceError("execution receipt argv must use redacted paths")
        if any(not any(argument.startswith(prefix) for argument in argv) for prefix in prefixes):
            raise EvidenceError("execution receipt argv does not identify its variant closure")
        _validate_mapper_invocations(
            receipt["mapper_invocations"],
            receipt["variant"],
            request,
            valid_outcome=valid_outcome,
        )
    if valid_outcome and published_receipts != 1:
        raise EvidenceError("valid evidence requires exactly one receipt for the published output")
    if not valid_outcome and published_receipts:
        raise EvidenceError("invalid evidence cannot claim a published output receipt")
    return expected_runs


def _host_state_snapshot(value: Any, label: str) -> dict[str, Any]:
    snapshot = _mapping(value, label)
    _exact_keys(
        snapshot,
        {
            "cpu_ticks",
            "vm_pageouts",
            "vm_swapouts",
            "thermal_state",
            "low_power_mode",
            "power_source",
        },
        label,
    )
    ticks = _mapping(snapshot["cpu_ticks"], f"{label}.cpu_ticks")
    _exact_keys(ticks, {"user", "system", "idle", "nice"}, f"{label}.cpu_ticks")
    for field, value in ticks.items():
        if type(value) is not int or not 0 <= value <= 0xFFFFFFFF:
            raise EvidenceError(f"{label}.cpu_ticks.{field} is outside UInt32")
    for field in ("vm_pageouts", "vm_swapouts"):
        value = snapshot[field]
        if type(value) is not int or not 0 <= value < 1 << 64:
            raise EvidenceError(f"{label}.{field} is outside UInt64")
    if snapshot["thermal_state"] not in {"nominal", "fair", "serious", "critical"}:
        raise EvidenceError(f"{label}.thermal_state is invalid")
    if type(snapshot["low_power_mode"]) is not bool:
        raise EvidenceError(f"{label}.low_power_mode must be boolean")
    if snapshot["power_source"] not in {"ac_power", "battery_power", "ups_power"}:
        raise EvidenceError(f"{label}.power_source is invalid")
    return dict(snapshot)


def _wrapped_cpu_tick_delta(start: int, end: int) -> int:
    return end - start if end >= start else (1 << 32) - start + end


def measurement_environment_rejections(
    value: Any,
    machine: Mapping[str, Any],
    commands: list[dict[str, Any]],
    supervisor_started: float,
    supervisor_ended: float,
    supervisor_path: Path,
    expected_monitor_executable_sha256: str,
) -> tuple[str, ...]:
    environment = _mapping(value, "supervisor_run.measurement_environment")
    _exact_keys(
        environment,
        {
            "schema_version",
            "monotonic_clock",
            "monitor_sha256",
            "monitor_executable_sha256",
            "sample_interval_seconds",
            "sample_count",
            "maximum_sample_gap_seconds",
            "first_monotonic_seconds",
            "last_monotonic_seconds",
            "state_change_events",
            "power_sources",
            "thermal_states",
            "low_power_mode_observed",
            "vm_pageouts_delta",
            "vm_swapouts_delta",
            "outer_child_cpu_microseconds",
            "supervisor_host_busy_fraction",
            "supervisor_process_cpu_fraction",
            "supervisor_external_cpu_fraction",
            "unattributed_child_cpu_fraction",
            "commands",
        },
        "supervisor_run.measurement_environment",
    )
    if environment["schema_version"] != 1:
        raise EvidenceError("measurement environment schema is invalid")
    if environment["monotonic_clock"] != "mach_absolute_time":
        raise EvidenceError("measurement environment monotonic clock is invalid")
    _digest(environment["monitor_sha256"], "measurement environment monitor sha256")
    _digest(
        environment["monitor_executable_sha256"],
        "measurement environment monitor executable sha256",
    )
    if environment["monitor_executable_sha256"] != expected_monitor_executable_sha256:
        raise EvidenceError("measurement environment monitor executable is not approved")
    monitor_path = supervisor_path.parent / "host-monitor.json"
    try:
        metadata = monitor_path.lstat()
    except OSError as error:
        raise EvidenceError("host monitor artifact is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or monitor_path.is_symlink()
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > MAX_HOST_MONITOR_BYTES
    ):
        raise EvidenceError("host monitor artifact is unsafe or too large")
    if sha256_file(monitor_path) != environment["monitor_sha256"]:
        raise EvidenceError("host monitor artifact digest is invalid")

    interval = _positive_number(
        environment["sample_interval_seconds"],
        "measurement environment sample interval",
    )
    if interval > 1.0:
        raise EvidenceError("measurement environment sample interval exceeds one second")
    sample_count = environment["sample_count"]
    if type(sample_count) is not int or not 2 <= sample_count <= 100_000:
        raise EvidenceError("measurement environment sample count is invalid")
    maximum_gap = _positive_number(
        environment["maximum_sample_gap_seconds"],
        "measurement environment maximum sample gap",
    )
    if maximum_gap > max(2.5 * interval, 0.125) + 1e-9:
        raise EvidenceError("measurement environment sample gap is too large")
    first = _nonnegative_number(
        environment["first_monotonic_seconds"],
        "measurement environment first timestamp",
    )
    last = _positive_number(
        environment["last_monotonic_seconds"],
        "measurement environment last timestamp",
    )
    if (
        last <= first
        or first > supervisor_started + 0.05
        or last < supervisor_ended - 0.05
        or supervisor_started - first > maximum_gap + 0.05
        or last - supervisor_ended > maximum_gap + 0.05
    ):
        raise EvidenceError("measurement environment does not bracket the supervisor window")

    state_change_events = environment["state_change_events"]
    if not isinstance(state_change_events, list) or len(state_change_events) > sample_count:
        raise EvidenceError("measurement environment state-change events are invalid")
    previous_event_key: tuple[float, str] | None = None
    for index, raw_event in enumerate(state_change_events):
        event = _mapping(
            raw_event,
            f"measurement environment state_change_events[{index}]",
        )
        _exact_keys(
            event,
            {"monotonic_seconds", "kind"},
            f"measurement environment state_change_events[{index}]",
        )
        timestamp = _nonnegative_number(
            event["monotonic_seconds"],
            f"measurement environment state_change_events[{index}].monotonic_seconds",
        )
        kind = event["kind"]
        if (
            not isinstance(kind, str)
            or kind not in {"thermal_state", "low_power_mode", "power_source"}
            or timestamp < supervisor_started
            or timestamp > supervisor_ended
        ):
            raise EvidenceError("measurement environment state-change event is invalid")
        event_key = (timestamp, kind)
        if previous_event_key is not None and event_key < previous_event_key:
            raise EvidenceError("measurement environment state-change events are not canonical")
        previous_event_key = event_key
    if state_change_events:
        rejections = ["host_state_change"]
    else:
        rejections = []

    def string_set(field: str, allowed: set[str]) -> list[str]:
        raw = environment[field]
        if (
            not isinstance(raw, list)
            or not raw
            or raw != sorted(set(raw))
            or any(not isinstance(item, str) or item not in allowed for item in raw)
        ):
            raise EvidenceError(f"measurement environment {field} is invalid")
        return raw

    power_sources = string_set(
        "power_sources",
        {"ac_power", "battery_power", "ups_power"},
    )
    thermal_states = string_set(
        "thermal_states",
        {"nominal", "fair", "serious", "critical"},
    )
    if power_sources != ["ac_power"]:
        rejections.append("ac_power")
    if any(state in {"serious", "critical"} for state in thermal_states):
        rejections.append("thermal_state")
    if type(environment["low_power_mode_observed"]) is not bool:
        raise EvidenceError("measurement environment Low Power Mode state is invalid")
    if environment["low_power_mode_observed"]:
        rejections.append("low_power_mode")
    for field in ("vm_pageouts_delta", "vm_swapouts_delta"):
        if type(environment[field]) is not int or not 0 <= environment[field] < 1 << 64:
            raise EvidenceError(f"measurement environment {field} is outside UInt64")
        if environment[field] != 0:
            rejections.append(field.removesuffix("_delta"))

    child_cpu = _mapping(
        environment["outer_child_cpu_microseconds"],
        "supervisor_run.measurement_environment.outer_child_cpu_microseconds",
    )
    _exact_keys(
        child_cpu,
        {"user", "system"},
        "supervisor_run.measurement_environment.outer_child_cpu_microseconds",
    )
    if any(
        type(child_cpu[field]) is not int or not 0 <= child_cpu[field] < 1 << 64
        for field in ("user", "system")
    ):
        raise EvidenceError("measurement outer child CPU is outside UInt64")
    logical_cpus = machine.get("logical_cpus")
    if type(logical_cpus) is not int or logical_cpus <= 0:
        raise EvidenceError("measurement logical CPU count is unavailable")
    command_environment = environment["commands"]
    if not isinstance(command_environment, list) or len(command_environment) != len(commands):
        raise EvidenceError("measurement environment command closure is incomplete")
    process_cpu_total = 0
    for index, (raw, command) in enumerate(zip(command_environment, commands, strict=True)):
        item = _mapping(raw, f"measurement environment commands[{index}]")
        _exact_keys(
            item,
            {"run_id", "host_busy_fraction", "process_cpu_fraction", "external_cpu_fraction"},
            f"measurement environment commands[{index}]",
        )
        if item["run_id"] != command["run_id"]:
            raise EvidenceError("measurement environment command order is invalid")
        duration = float(command["ended_monotonic_seconds"]) - float(
            command["started_monotonic_seconds"]
        )
        process_cpu = command["process_cpu_microseconds"]
        process_microseconds = process_cpu["user"] + process_cpu["system"]
        process_cpu_total += process_microseconds
        expected_process_fraction = process_microseconds / (
            duration * logical_cpus * 1_000_000
        )
        host_busy = _nonnegative_number(
            item["host_busy_fraction"],
            f"measurement environment commands[{index}].host_busy_fraction",
        )
        process_fraction = _nonnegative_number(
            item["process_cpu_fraction"],
            f"measurement environment commands[{index}].process_cpu_fraction",
        )
        external_fraction = _nonnegative_number(
            item["external_cpu_fraction"],
            f"measurement environment commands[{index}].external_cpu_fraction",
        )
        if host_busy > 1 + 1e-12 or process_fraction > 1.05 + 1e-12:
            raise EvidenceError("measurement environment CPU fraction is outside its domain")
        if not math.isclose(process_fraction, expected_process_fraction, rel_tol=0, abs_tol=1e-9):
            raise EvidenceError("measurement environment process CPU fraction is inconsistent")
        if not math.isclose(
            external_fraction,
            max(0.0, host_busy - process_fraction),
            rel_tol=0,
            abs_tol=1e-9,
        ):
            raise EvidenceError("measurement environment external CPU fraction is inconsistent")
        if external_fraction > MAX_EXTERNAL_CPU_FRACTION + 1e-12:
            rejections.append("external_cpu")
    outer_cpu_total = child_cpu["user"] + child_cpu["system"]
    if process_cpu_total > outer_cpu_total + max(100_000, math.ceil(outer_cpu_total * 0.01)):
        raise EvidenceError("measurement command CPU exceeds outer child CPU")
    supervisor_duration = supervisor_ended - supervisor_started
    supervisor_host_busy = _nonnegative_number(
        environment["supervisor_host_busy_fraction"],
        "measurement environment supervisor host busy fraction",
    )
    supervisor_process_fraction = _nonnegative_number(
        environment["supervisor_process_cpu_fraction"],
        "measurement environment supervisor process CPU fraction",
    )
    supervisor_external_fraction = _nonnegative_number(
        environment["supervisor_external_cpu_fraction"],
        "measurement environment supervisor external CPU fraction",
    )
    unattributed_child_fraction = _nonnegative_number(
        environment["unattributed_child_cpu_fraction"],
        "measurement environment unattributed child CPU fraction",
    )
    expected_process_fraction = outer_cpu_total / (
        supervisor_duration * logical_cpus * 1_000_000
    )
    expected_unattributed_fraction = max(0, outer_cpu_total - process_cpu_total) / (
        supervisor_duration * logical_cpus * 1_000_000
    )
    if (
        supervisor_host_busy > 1 + 1e-12
        or supervisor_process_fraction > 1.05 + 1e-12
        or not math.isclose(
            supervisor_process_fraction,
            expected_process_fraction,
            rel_tol=0,
            abs_tol=1e-9,
        )
        or not math.isclose(
            supervisor_external_fraction,
            max(0.0, supervisor_host_busy - supervisor_process_fraction),
            rel_tol=0,
            abs_tol=1e-9,
        )
        or not math.isclose(
            unattributed_child_fraction,
            expected_unattributed_fraction,
            rel_tol=0,
            abs_tol=1e-9,
        )
    ):
        raise EvidenceError("measurement environment supervisor CPU accounting is inconsistent")
    if supervisor_external_fraction > MAX_EXTERNAL_CPU_FRACTION + 1e-12:
        rejections.append("supervisor_external_cpu")
    if unattributed_child_fraction > MAX_UNATTRIBUTED_CHILD_CPU_FRACTION + 1e-12:
        rejections.append("unattributed_child_cpu")
    return tuple(dict.fromkeys(rejections))


def _validate_measurement_environment(
    value: Any,
    machine: Mapping[str, Any],
    commands: list[dict[str, Any]],
    supervisor_started: float,
    supervisor_ended: float,
    supervisor_path: Path,
    expected_monitor_executable_sha256: str,
) -> None:
    rejections = measurement_environment_rejections(
        value,
        machine,
        commands,
        supervisor_started,
        supervisor_ended,
        supervisor_path,
        expected_monitor_executable_sha256,
    )
    if not rejections:
        return
    messages = {
        "ac_power": "release timing evidence requires uninterrupted AC power",
        "thermal_state": "release timing evidence has a serious thermal state",
        "low_power_mode": "release timing evidence cannot use Low Power Mode",
        "vm_pageouts": "measurement environment recorded vm_pageouts",
        "vm_swapouts": "measurement environment recorded vm_swapouts",
        "external_cpu": "measurement external CPU utilization exceeds 0.10",
        "supervisor_external_cpu": "measurement-wide external CPU utilization exceeds 0.10",
        "unattributed_child_cpu": "measurement runner CPU is not covered by execution receipts",
        "host_state_change": "measurement host state changed during the protected run",
    }
    raise EvidenceError(messages[rejections[0]])


def _validate_supervisor_run(
    path: Path,
    request: Mapping[str, Any],
    runner_identity: Mapping[str, Any],
    commands: list[dict[str, Any]],
    machine: Mapping[str, Any],
    *,
    enforce_environment_policy: bool = True,
) -> None:
    receipt = _mapping(_load_bounded_json(path, "supervisor_run"), "supervisor_run")
    fields = {
        "schema_version",
        "scene_id",
        "scale",
        "lane",
        "input_digest",
        "candidate_git_commit",
        "baseline_git_commit",
        "toolchain_identity",
        "baseline_toolchain_identity",
        "runner_sha256",
        "argv",
        "started_monotonic_seconds",
        "ended_monotonic_seconds",
        "exit_code",
        "measurement_environment",
    }
    _exact_keys(receipt, fields, "supervisor_run")
    binding = request["binding"]
    expected_bindings = {
        "schema_version": 3,
        "scene_id": binding["scene_id"],
        "scale": binding["scale"],
        "lane": binding["lane"],
        "input_digest": binding["input_digest"],
        "candidate_git_commit": binding["git_commit"],
        "baseline_git_commit": binding["baseline_git_commit"],
        "toolchain_identity": binding["toolchain_identity"],
        "baseline_toolchain_identity": binding["baseline_toolchain_identity"],
        "runner_sha256": runner_identity["sha256"],
        "exit_code": 0,
    }
    for field, expected in expected_bindings.items():
        if receipt[field] != expected:
            raise EvidenceError(f"supervisor_run {field} does not match the protected request")
    started = receipt["started_monotonic_seconds"]
    ended = receipt["ended_monotonic_seconds"]
    if (
        isinstance(started, bool)
        or isinstance(ended, bool)
        or not isinstance(started, (int, float))
        or not isinstance(ended, (int, float))
        or not math.isfinite(started)
        or not math.isfinite(ended)
        or started < 0
        or ended <= started
    ):
        raise EvidenceError("supervisor_run monotonic timestamps are invalid")
    argv = receipt["argv"]
    if not isinstance(argv, list) or any(not isinstance(item, str) or not item for item in argv):
        raise EvidenceError("supervisor_run argv must be a nonempty redacted argument array")
    expected_tokens = {
        f"scene://{binding['scene_id']}",
        f"scale://{binding['scale']}",
        f"lane://{binding['lane']}",
        f"input://{binding['input_digest']}",
        f"candidate://{binding['git_commit']}",
        f"baseline://{binding['baseline_git_commit']}",
        f"toolchain://{binding['toolchain_identity']}",
        f"runner://{runner_identity['sha256']}",
    }
    if not expected_tokens.issubset(set(argv)):
        raise EvidenceError("supervisor_run argv is not bound to the protected execution")
    supervisor_start = float(started)
    supervisor_end = float(ended)
    intervals = sorted(
        (
            float(command["started_monotonic_seconds"]),
            float(command["ended_monotonic_seconds"]),
        )
        for command in commands
    )
    for internal_start, internal_end in intervals:
        if (
            internal_start < supervisor_start - MONOTONIC_TIMESTAMP_TOLERANCE_SECONDS
            or internal_end > supervisor_end + MONOTONIC_TIMESTAMP_TOLERANCE_SECONDS
        ):
            raise EvidenceError("execution receipt falls outside the supervisor monotonic window")

    covered_seconds = 0.0
    merged_start, merged_end = intervals[0]
    for interval_start, interval_end in intervals[1:]:
        if interval_start <= merged_end + MONOTONIC_TIMESTAMP_TOLERANCE_SECONDS:
            merged_end = max(merged_end, interval_end)
        else:
            covered_seconds += merged_end - merged_start
            merged_start, merged_end = interval_start, interval_end
    covered_seconds += merged_end - merged_start
    supervisor_span = supervisor_end - supervisor_start
    if enforce_environment_policy:
        _validate_measurement_environment(
            receipt["measurement_environment"],
            machine,
            commands,
            supervisor_start,
            supervisor_end,
            path,
            request["rendering_driver_identity"]["executable_sha256"],
        )
    else:
        measurement_environment_rejections(
            receipt["measurement_environment"],
            machine,
            commands,
            supervisor_start,
            supervisor_end,
            path,
            request["rendering_driver_identity"]["executable_sha256"],
        )
    unattributed_seconds = supervisor_span - covered_seconds
    if unattributed_seconds > max(2.0, supervisor_span * 0.1):
        raise EvidenceError("execution receipts leave too much supervisor time unattributed")


def _validate_render_supervisor(
    path: Path,
    job_path: Path,
    manifest_path: Path,
    request: Mapping[str, Any],
    renderer_identity: Mapping[str, Any],
) -> None:
    receipt = _mapping(
        _load_bounded_json(path, "render_supervisor"),
        "render_supervisor",
    )
    _exact_keys(
        receipt,
        {
            "schema_version",
            "scene_id",
            "scale",
            "lane",
            "request_sha256",
            "candidate_checkout_commit",
            "baseline_checkout_commit",
            "renderer_closure_sha256",
            "renderer_executable_sha256",
            "ground_truth_preparation_sha256",
            "job_sha256",
            "manifest_sha256",
            "stdout_sha256",
            "stderr_sha256",
            "argv",
            "actual_argv_sha256",
            "started_monotonic_seconds",
            "ended_monotonic_seconds",
            "exit_code",
            "timed_out",
        },
        "render_supervisor",
    )
    binding = request["binding"]
    expected = {
        "schema_version": 1,
        "scene_id": binding["scene_id"],
        "scale": binding["scale"],
        "lane": binding["lane"],
        "request_sha256": sha256_bytes(canonical_json_bytes(request) + b"\n"),
        "candidate_checkout_commit": binding["git_commit"],
        "baseline_checkout_commit": binding["baseline_git_commit"],
        "renderer_closure_sha256": renderer_identity["sha256"],
        "renderer_executable_sha256": renderer_identity["executable_sha256"],
        "ground_truth_preparation_sha256": request["reference_artifacts"][
            "ground_truth_preparation_sha256"
        ],
        "job_sha256": sha256_file(job_path),
        "manifest_sha256": sha256_file(manifest_path),
        "stdout_sha256": sha256_file(path.parent / "renderer-stdout.log"),
        "stderr_sha256": sha256_file(path.parent / "renderer-stderr.log"),
        "exit_code": 0,
        "timed_out": False,
    }
    for field, expected_value in expected.items():
        if receipt.get(field) != expected_value:
            raise EvidenceError(f"render_supervisor {field} is invalid")
    _digest(receipt["actual_argv_sha256"], "render_supervisor actual_argv_sha256")
    started = receipt["started_monotonic_seconds"]
    ended = receipt["ended_monotonic_seconds"]
    if (
        isinstance(started, bool)
        or isinstance(ended, bool)
        or not isinstance(started, (int, float))
        or not isinstance(ended, (int, float))
        or not math.isfinite(started)
        or not math.isfinite(ended)
        or started < 0
        or ended <= started
    ):
        raise EvidenceError("render_supervisor monotonic timestamps are invalid")
    argv = receipt["argv"]
    if not isinstance(argv, list) or any(not isinstance(item, str) or not item for item in argv):
        raise EvidenceError("render_supervisor argv must be a nonempty redacted argument array")
    expected_tokens = {
        "approved-rendering-driver",
        f"renderer-closure://{renderer_identity['sha256']}",
        f"renderer-executable://{renderer_identity['executable_sha256']}",
        "evidence://render-job.json",
        "evidence://rendering-manifest.json",
    }
    if not expected_tokens.issubset(set(argv)) or any(
        "/Users/" in argument or "/home/" in argument for argument in argv
    ):
        raise EvidenceError("render_supervisor argv is not bound to the protected rendering process")


def _single_link_artifact_descriptor(
    path: Path,
    root: Path,
    label: str,
) -> dict[str, Any]:
    descriptor = _artifact_descriptor(path, root)
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EvidenceError(f"{label} is missing") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise EvidenceError(f"{label} must be a single-link regular file")
    return descriptor


def _orientation_candidate_records(
    observations: Mapping[str, Any],
) -> tuple[list[Mapping[str, Any]], list[str]]:
    timing = _mapping(observations.get("timing"), "observations.timing")
    ordinary_runs = timing.get("ordinary_runs")
    if not isinstance(ordinary_runs, list):
        raise EvidenceError("orientation evidence requires ordinary timing runs")
    records: list[Mapping[str, Any]] = []
    run_ids: list[str] = []
    for index, raw_record in enumerate(ordinary_runs):
        record = _mapping(raw_record, f"observations.timing.ordinary_runs[{index}]")
        if record.get("variant") != "candidate":
            continue
        run_id = _token(record.get("run_id"), f"ordinary candidate run {index} id")
        if run_id in run_ids:
            raise EvidenceError("orientation candidate timing run ids must be unique")
        run_ids.append(run_id)
        records.append(record)
    if not records:
        raise EvidenceError("orientation evidence requires candidate ordinary runs")
    return records, run_ids


def _orientation_scoring_run_id(
    observations: Mapping[str, Any],
    candidate_run_ids: list[str],
) -> str:
    commands = observations.get("commands")
    if not isinstance(commands, list):
        raise EvidenceError("orientation evidence requires execution receipts")
    published = [
        command
        for command in commands
        if isinstance(command, Mapping)
        and command.get("variant") == "candidate"
        and command.get("published_output") is True
    ]
    if len(published) != 1 or published[0].get("run_id") not in candidate_run_ids:
        raise EvidenceError(
            "orientation evidence requires one published candidate ordinary run"
        )
    return str(published[0]["run_id"])


def _validate_orientation_supervisor(
    supervisor_path: Path,
    metrics_index_path: Path,
    artifact_root: Path,
    request: Mapping[str, Any],
    observations: Mapping[str, Any],
    renderer_identity: Mapping[str, Any],
) -> dict[str, dict[str, Any]]:
    _single_link_artifact_descriptor(
        supervisor_path,
        artifact_root,
        "orientation supervisor receipt",
    )
    supervisor = _mapping(
        _load_bounded_json(supervisor_path, "orientation-supervisor.json"),
        "orientation supervisor",
    )
    _exact_keys(
        supervisor,
        {
            "candidate_git_commit",
            "ground_truth_poses_sha256",
            "lane",
            "metrics_index_sha256",
            "orientation_label_sha256",
            "renderer_closure_sha256",
            "renderer_executable_sha256",
            "request_sha256",
            "runs",
            "scale",
            "scene_id",
            "schema_version",
            "scoring_run_id",
        },
        "orientation supervisor",
    )
    binding = request["binding"]
    expected = {
        "candidate_git_commit": binding["git_commit"],
        "ground_truth_poses_sha256": request["reference_artifacts"][
            "ground_truth_poses_sha256"
        ],
        "lane": binding["lane"],
        "orientation_label_sha256": request["reference_artifacts"][
            "orientation_label_sha256"
        ],
        "renderer_closure_sha256": renderer_identity["sha256"],
        "renderer_executable_sha256": renderer_identity["executable_sha256"],
        "request_sha256": sha256_bytes(canonical_json_bytes(request) + b"\n"),
        "scale": binding["scale"],
        "scene_id": binding["scene_id"],
        "schema_version": 1,
    }
    for field, expected_value in expected.items():
        if supervisor[field] != expected_value:
            raise EvidenceError(
                f"orientation supervisor {field} does not match the protected request"
            )
    for filename, digest_field, label in (
        (
            "ground-truth-poses.json",
            "ground_truth_poses_sha256",
            "orientation ground-truth poses",
        ),
        (
            "orientation-label.json",
            "orientation_label_sha256",
            "orientation physical-up label",
        ),
    ):
        descriptor = _single_link_artifact_descriptor(
            artifact_root / filename,
            artifact_root,
            label,
        )
        if descriptor["sha256"] != supervisor[digest_field]:
            raise EvidenceError(f"{label} digest does not match")

    metrics_index_descriptor = _single_link_artifact_descriptor(
        metrics_index_path,
        artifact_root,
        "orientation metrics index",
    )
    if supervisor["metrics_index_sha256"] != metrics_index_descriptor["sha256"]:
        raise EvidenceError("orientation supervisor metrics index digest does not match")
    aggregate = _mapping(
        _load_bounded_json(metrics_index_path, "orientation-metrics.json"),
        "orientation metrics index",
    )
    _exact_keys(
        aggregate,
        {"runs", "schema_version", "scoring_run_id"},
        "orientation metrics index",
    )
    if aggregate["schema_version"] != 1:
        raise EvidenceError("orientation metrics index schema is invalid")

    candidate_records, candidate_run_ids = _orientation_candidate_records(observations)
    scoring_run_id = _orientation_scoring_run_id(observations, candidate_run_ids)
    if (
        supervisor["scoring_run_id"] != scoring_run_id
        or aggregate["scoring_run_id"] != scoring_run_id
    ):
        raise EvidenceError("orientation scoring run does not match the published output")
    raw_receipts = supervisor["runs"]
    aggregate_runs = aggregate["runs"]
    if (
        not isinstance(raw_receipts, list)
        or not isinstance(aggregate_runs, list)
        or len(raw_receipts) != len(candidate_records)
        or len(aggregate_runs) != len(candidate_records)
    ):
        raise EvidenceError("orientation supervisor does not cover every candidate run")

    receipt_fields = {
        "actual_argv_sha256",
        "argv",
        "candidate_images_path",
        "candidate_images_sha256",
        "ended_monotonic_seconds",
        "exit_code",
        "geometry_manifest_path",
        "geometry_manifest_sha256",
        "metrics_path",
        "metrics_sha256",
        "run_id",
        "started_monotonic_seconds",
        "stderr_path",
        "stderr_sha256",
        "stdout_path",
        "stdout_sha256",
        "timed_out",
    }
    dynamic_descriptors: dict[str, dict[str, Any]] = {}
    scoring_metrics: dict[str, Any] | None = None
    for index, (raw_receipt, raw_aggregate) in enumerate(
        zip(raw_receipts, aggregate_runs, strict=True)
    ):
        run_id = candidate_run_ids[index]
        receipt = _mapping(raw_receipt, f"orientation supervisor runs[{index}]")
        _exact_keys(receipt, receipt_fields, f"orientation supervisor runs[{index}]")
        if receipt["run_id"] != run_id:
            raise EvidenceError("orientation supervisor runs are not in candidate timing order")
        aggregate_run = _mapping(
            raw_aggregate,
            f"orientation metrics index runs[{index}]",
        )
        _exact_keys(
            aggregate_run,
            {"metrics", "metrics_path", "run_id"},
            f"orientation metrics index runs[{index}]",
        )
        if aggregate_run["run_id"] != run_id:
            raise EvidenceError("orientation metrics runs are not in candidate timing order")

        relative_root = PurePosixPath("orientation-runs") / run_id
        expected_paths = {
            "geometry_manifest_path": relative_root / "geometry-manifest.json",
            "candidate_images_path": relative_root / "candidate-images.txt",
            "metrics_path": relative_root / "orientation-metrics.json",
            "stdout_path": relative_root / "orientation-stdout.log",
            "stderr_path": relative_root / "orientation-stderr.log",
        }
        descriptor_names = {
            "geometry_manifest_path": "geometry_manifest",
            "candidate_images_path": "candidate_images",
            "metrics_path": "metrics",
            "stdout_path": "stdout",
            "stderr_path": "stderr",
        }
        for path_field, expected_relative in expected_paths.items():
            if receipt[path_field] != expected_relative.as_posix():
                raise EvidenceError(
                    f"orientation supervisor {path_field} is not canonical for {run_id}"
                )
            descriptor_name = descriptor_names[path_field]
            descriptor = _single_link_artifact_descriptor(
                artifact_root / Path(*expected_relative.parts),
                artifact_root,
                f"orientation {descriptor_name} for {run_id}",
            )
            digest_field = path_field.removesuffix("_path") + "_sha256"
            if descriptor["sha256"] != receipt[digest_field]:
                raise EvidenceError(
                    f"orientation {descriptor_name} digest does not match for {run_id}"
                )
            dynamic_descriptors[f"orientation_{descriptor_name}_{index:02d}"] = descriptor

        if aggregate_run["metrics_path"] != receipt["metrics_path"]:
            raise EvidenceError("orientation metrics index path does not match its receipt")
        metrics_path = artifact_root / Path(*expected_paths["metrics_path"].parts)
        metrics = validate_orientation_metrics(
            _load_bounded_json(metrics_path, f"orientation metrics for {run_id}"),
            f"orientation metrics for {run_id}",
        )
        if metrics["alignment_support_count"] > binding["scale"]:
            raise EvidenceError(
                f"orientation alignment support for {run_id} exceeds the selected scale"
            )
        if aggregate_run["metrics"] != metrics:
            raise EvidenceError("orientation metrics index does not match the driver output")
        started = receipt["started_monotonic_seconds"]
        ended = receipt["ended_monotonic_seconds"]
        if (
            isinstance(started, bool)
            or isinstance(ended, bool)
            or not isinstance(started, (int, float))
            or not isinstance(ended, (int, float))
            or not math.isfinite(started)
            or not math.isfinite(ended)
            or started < 0
            or ended <= started
            or receipt["exit_code"] != 0
            or receipt["timed_out"] is not False
        ):
            raise EvidenceError(f"orientation supervisor execution for {run_id} is invalid")
        _digest(
            receipt["actual_argv_sha256"],
            f"orientation supervisor actual argv digest for {run_id}",
        )
        expected_argv = [
            "approved-orientation-driver",
            f"renderer-closure://{renderer_identity['sha256']}",
            f"renderer-executable://{renderer_identity['executable_sha256']}",
            "extract-orientation",
            "--geometry-manifest",
            f"evidence://{expected_paths['geometry_manifest_path'].as_posix()}",
            "--candidate-images",
            f"evidence://{expected_paths['candidate_images_path'].as_posix()}",
            "--ground-truth-poses",
            "evidence://ground-truth-poses.json",
            "--ground-truth-poses-sha256",
            request["reference_artifacts"]["ground_truth_poses_sha256"],
            "--orientation-label",
            "evidence://orientation-label.json",
            "--orientation-label-sha256",
            request["reference_artifacts"]["orientation_label_sha256"],
            "--output",
            f"evidence://{expected_paths['metrics_path'].as_posix()}",
        ]
        if receipt["argv"] != expected_argv:
            raise EvidenceError(f"orientation supervisor argv for {run_id} is invalid")
        if run_id == scoring_run_id:
            scoring_metrics = metrics

    if scoring_metrics is None:
        raise EvidenceError("orientation scoring metrics are missing")
    raw_pipeline = _mapping(
        observations.get("pipeline_metrics"),
        "observations.pipeline_metrics",
    )
    for name in ORIENTATION_PIPELINE_FIELDS:
        if raw_pipeline.get(name) != scoring_metrics[name]:
            raise EvidenceError(
                f"supervisor orientation {name} does not match pipeline metrics"
            )
    return dynamic_descriptors


def _memory_metrics(
    value: Any,
    expected_runs: list[dict[str, Any]],
    machine: Mapping[str, Any],
    lane: str,
) -> dict[str, Any]:
    memory = _mapping(value, "observations.memory")
    _exact_keys(memory, {"sample_interval_seconds", "samples"}, "observations.memory")
    interval = _positive_number(
        memory["sample_interval_seconds"],
        "observations.memory.sample_interval_seconds",
    )
    if interval > 5:
        raise EvidenceError("memory sampling interval must be at most five seconds")
    candidate_runs = {
        run["run_id"]: run
        for run in expected_runs
        if run["variant"] in {"candidate", "fast_candidate"} and run["duration"] is not None
    }
    samples = memory["samples"]
    if not isinstance(samples, list) or not samples:
        raise EvidenceError("observations.memory.samples must be nonempty")
    by_run: dict[str, list[tuple[float, int, int]]] = {}
    for index, raw in enumerate(samples):
        sample = _mapping(raw, f"observations.memory.samples[{index}]")
        _exact_keys(
            sample,
            {
                "run_id",
                "elapsed_seconds",
                "process_tree_resident_bytes",
                "metal_allocated_bytes",
            },
            f"observations.memory.samples[{index}]",
        )
        run_id = sample["run_id"]
        elapsed = sample["elapsed_seconds"]
        rss = sample["process_tree_resident_bytes"]
        metal = sample["metal_allocated_bytes"]
        if run_id not in candidate_runs:
            raise EvidenceError("memory sample is not bound to a candidate execution receipt")
        if (
            isinstance(elapsed, bool)
            or not isinstance(elapsed, (int, float))
            or not math.isfinite(elapsed)
            or elapsed < 0
            or type(rss) is not int
            or rss <= 0
            or type(metal) is not int
            or metal < 0
        ):
            raise EvidenceError("memory sample values are invalid")
        by_run.setdefault(run_id, []).append((float(elapsed), rss, metal))
    if set(by_run) != set(candidate_runs):
        raise EvidenceError("memory samples do not cover every candidate execution receipt")
    for run_id, run in candidate_runs.items():
        duration = float(run["duration"])
        run_samples = by_run[run_id]
        elapsed_values = [sample[0] for sample in run_samples]
        if elapsed_values != sorted(elapsed_values) or len(elapsed_values) != len(set(elapsed_values)):
            raise EvidenceError("memory sample timestamps must be strictly increasing per run")
        if not math.isclose(elapsed_values[0], 0, abs_tol=1e-6) or not math.isclose(
            elapsed_values[-1], duration, rel_tol=0, abs_tol=1e-6
        ):
            raise EvidenceError("memory samples must span each candidate run from launch to exit")
        if any(
            later - earlier > interval * 1.25 + 1e-6
            for earlier, later in zip(elapsed_values, elapsed_values[1:], strict=False)
        ):
            raise EvidenceError("memory sampling cadence has an uncovered gap")
        if run["phase"] != "phase" and max(sample[2] for sample in run_samples) <= 0:
            raise EvidenceError("end-to-end candidate runs must report positive Metal allocation")
    physical_memory = machine.get("physical_memory_bytes")
    if type(physical_memory) is not int or physical_memory <= 0:
        raise EvidenceError("machine physical memory is unavailable")
    return {
        "peak_memory_bytes": measured(max(sample[1] for samples in by_run.values() for sample in samples)),
        "peak_metal_allocated_bytes": measured(
            max(sample[2] for samples in by_run.values() for sample in samples)
        ),
        "machine_memory_bytes": measured(physical_memory),
        "memory_lane": measured(
            "larger"
            if lane == LANE_REFERENCE
            else "constrained"
            if lane == LANE_CONSTRAINED
            else "eight_gb_fast"
        ),
    }


def _validate_resolved_compute(
    value: Any,
    candidate_configuration: Mapping[str, Any],
) -> dict[str, Any]:
    compute = _mapping(value, "observations.resolved_compute")
    _exact_keys(compute, {"stages", "cpu_only_reasons"}, "observations.resolved_compute")
    stages = _mapping(compute["stages"], "observations.resolved_compute.stages")
    stage_names = {"feature_extraction", "matching", "mapping", "training", "rendering"}
    _exact_keys(stages, stage_names, "observations.resolved_compute.stages")
    if any(value not in {"cpu", "metal"} for value in stages.values()):
        raise EvidenceError("resolved compute stages must use cpu or metal")
    if stages["training"] != "metal" or stages["rendering"] != "metal":
        raise EvidenceError("training and rendering must use Metal")
    reasons = _mapping(
        compute["cpu_only_reasons"],
        "observations.resolved_compute.cpu_only_reasons",
    )
    reason_tokens = {
        "feature_extraction": "colmap_sift_has_no_supported_metal_backend",
        "matching": "faiss_has_no_supported_metal_backend",
        "mapping": "ceres_has_no_supported_metal_backend",
    }
    expected_reasons = {
        stage: reason
        for stage, reason in reason_tokens.items()
        if stages[stage] == "cpu"
    }
    _exact_keys(
        reasons,
        expected_reasons,
        "observations.resolved_compute.cpu_only_reasons",
    )
    if dict(reasons) != expected_reasons:
        raise EvidenceError("CPU-only stage reasons do not match the supported backend closure")
    if candidate_configuration.get("compute_policy") != "metal_for_supported_stages":
        raise EvidenceError("resolved compute does not match the bound compute policy")
    return {"stages": dict(stages), "cpu_only_reasons": dict(reasons)}


def _validate_actual(
    value: Any,
    expected_outcome: Mapping[str, Any],
) -> dict[str, Any]:
    actual = _mapping(value, "observations.actual")
    _exact_keys(
        actual,
        {"exit_code", "termination_reason", "cancelled", "failure_type", "corrupt_ply"},
        "observations.actual",
    )
    if expected_outcome["kind"] == "valid":
        expected = {
            "exit_code": 0,
            "termination_reason": "exit",
            "cancelled": False,
            "failure_type": None,
            "corrupt_ply": False,
        }
        if dict(actual) != expected:
            raise EvidenceError("valid evidence must report one clean successful process outcome")
    else:
        if (
            type(actual["exit_code"]) is not int
            or actual["exit_code"] == 0
            or actual["termination_reason"] != "exit"
            or actual["cancelled"] is not False
            or actual["failure_type"] != expected_outcome["failure_type"]
            or actual["corrupt_ply"] is not False
        ):
            raise EvidenceError("invalid-input evidence must report the expected clean rejection")
    return dict(actual)


def _toolchain_scenario_metrics(
    value: Any,
    binding: Mapping[str, Any],
) -> dict[str, dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(TOOLCHAIN_SCENARIO_SPECS):
        raise EvidenceError("toolchain_scenarios must contain the complete scenario closure")
    expected_names = list(TOOLCHAIN_SCENARIO_SPECS)
    actual_names: list[str] = []
    metrics: dict[str, dict[str, Any]] = {}
    fields = {
        "schema_version",
        "name",
        "fault",
        "network_mode",
        "toolchain_identity",
        "input_digest",
        "argv",
        "initial_exit_code",
        "retry_exit_code",
        "result",
        "post_state_verified",
    }
    for index, raw in enumerate(value):
        record = _mapping(raw, f"toolchain_scenarios[{index}]")
        _exact_keys(record, fields, f"toolchain_scenarios[{index}]")
        name = _token(record["name"], f"toolchain_scenarios[{index}].name")
        actual_names.append(name)
        if name not in TOOLCHAIN_SCENARIO_SPECS:
            raise EvidenceError("toolchain_scenarios contains an unsupported scenario")
        spec = TOOLCHAIN_SCENARIO_SPECS[name]
        if record["schema_version"] != 1:
            raise EvidenceError("toolchain scenario schema_version must be 1")
        if record["fault"] != spec["fault"] or record["network_mode"] != spec["network_mode"]:
            raise EvidenceError("toolchain scenario fault injection does not match its name")
        if record["toolchain_identity"] != binding["toolchain_identity"]:
            raise EvidenceError("toolchain scenario is not bound to the requested toolchain")
        if record["input_digest"] != binding["input_digest"]:
            raise EvidenceError("toolchain scenario is not bound to the requested input")
        argv = record["argv"]
        required_arguments = {
            f"toolchain-scenario://{name}",
            f"toolchain://{binding['toolchain_identity']}",
        }
        if (
            not isinstance(argv, list)
            or not required_arguments.issubset(set(argv))
            or any(
                not isinstance(argument, str)
                or not argument
                or "/Users/" in argument
                or "/home/" in argument
                for argument in argv
            )
        ):
            raise EvidenceError("toolchain scenario argv is not safely bound")
        if type(record["initial_exit_code"]) is not int or (
            record["retry_exit_code"] is not None
            and type(record["retry_exit_code"]) is not int
        ):
            raise EvidenceError("toolchain scenario exit codes must be integers")
        if not isinstance(record["result"], str) or type(record["post_state_verified"]) is not bool:
            raise EvidenceError("toolchain scenario outcome is invalid")
        passed = (
            record["initial_exit_code"] == spec["initial_exit_code"]
            and record["retry_exit_code"] == spec["retry_exit_code"]
            and record["result"] == spec["result"]
            and record["post_state_verified"]
        )
        metrics[spec["metric"]] = measured(passed)
    if actual_names != expected_names:
        raise EvidenceError("toolchain_scenarios must use the canonical scenario order")
    return metrics


def _verify_toolchain_manifest_signature(manifest: Mapping[str, Any]) -> None:
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError as error:
        raise EvidenceError(
            "toolchain manifest verification requires the pinned benchmark environment"
        ) from error
    public_key_base64 = PINNED_TOOLCHAIN_PUBLIC_KEY_BASE64_OVERRIDE
    if public_key_base64 is None:
        try:
            public_key_base64 = PINNED_TOOLCHAIN_PUBLIC_KEY_PATH.read_text(
                encoding="utf-8"
            ).strip()
        except OSError as error:
            raise EvidenceError("pinned toolchain public key is unavailable") from error
    try:
        public_key = base64.b64decode(public_key_base64, validate=True)
        signature = base64.b64decode(manifest["signatureEd25519"], validate=True)
    except (KeyError, TypeError, ValueError) as error:
        raise EvidenceError("toolchain manifest signature is invalid") from error
    if len(public_key) != 32 or len(signature) != 64:
        raise EvidenceError("toolchain manifest signature is invalid")
    if manifest.get("keyID") != hashlib.sha256(public_key).hexdigest():
        raise EvidenceError("toolchain manifest key identifier is invalid")
    unsigned = dict(manifest)
    unsigned["signatureEd25519"] = ""
    published_at = unsigned.get("publishedAt")
    if isinstance(published_at, bool) or not isinstance(published_at, (int, float, str)):
        raise EvidenceError("toolchain manifest publication date is invalid")
    if isinstance(published_at, (int, float)):
        if not math.isfinite(float(published_at)):
            raise EvidenceError("toolchain manifest publication date is invalid")
        published_date = datetime.fromtimestamp(
            978_307_200 + float(published_at),
            tz=timezone.utc,
        )
    else:
        try:
            published_date = datetime.fromisoformat(published_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise EvidenceError("toolchain manifest publication date is invalid") from error
        if published_date.tzinfo is None:
            raise EvidenceError("toolchain manifest publication date is invalid")
        published_date = published_date.astimezone(timezone.utc)
    unsigned["publishedAt"] = published_date.strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            signature,
            canonical_json_bytes(unsigned),
        )
    except (InvalidSignature, ValueError) as error:
        raise EvidenceError("toolchain manifest signature is invalid") from error


def _validated_toolchain_install_state(
    path: Path,
    label: str,
) -> tuple[dict[str, Any], dict[str, Mapping[str, Any]], set[str], str]:
    if path.stat().st_size > MAX_TOOLCHAIN_INSTALL_STATE_BYTES:
        raise EvidenceError(f"{label} exceeds its size limit")
    state = _mapping(_load_bounded_json(path, label), label)
    _exact_keys(
        state,
        {"schemaVersion", "installedArtifacts", "installedCapabilities", "signedManifest"},
        label,
    )
    if state["schemaVersion"] != 2:
        raise EvidenceError(f"{label} schema is unsupported")
    manifest = _mapping(state["signedManifest"], f"{label}.signedManifest")
    manifest_fields = {
        "schemaVersion",
        "toolchainAPI",
        "keyID",
        "version",
        "publishedAt",
        "appVersionRange",
        "components",
        "signatureEd25519",
    }
    _exact_keys(manifest, manifest_fields, f"{label}.signedManifest")
    if (
        manifest["schemaVersion"] != 2
        or manifest["toolchainAPI"] != 2
        or not isinstance(manifest["version"], str)
        or not manifest["version"]
        or not isinstance(manifest["keyID"], str)
        or re.fullmatch(r"[0-9a-f]{64}", manifest["keyID"]) is None
        or not isinstance(manifest["signatureEd25519"], str)
        or not manifest["signatureEd25519"]
    ):
        raise EvidenceError(f"{label} signed manifest identity is invalid")
    _verify_toolchain_manifest_signature(manifest)
    app_range = _mapping(manifest["appVersionRange"], f"{label}.appVersionRange")
    if (
        set(app_range) - {"minimum", "maximumExclusive"}
        or "minimum" not in app_range
        or not isinstance(app_range["minimum"], str)
        or (
            app_range.get("maximumExclusive") is not None
            and not isinstance(app_range.get("maximumExclusive"), str)
        )
    ):
        raise EvidenceError(f"{label} app version range is invalid")

    raw_components = manifest["components"]
    if not isinstance(raw_components, list) or not raw_components:
        raise EvidenceError(f"{label} signed manifest has no components")
    components_by_name: dict[str, Mapping[str, Any]] = {}
    component_fields = {
        "name",
        "capabilities",
        "url",
        "sha256",
        "sizeBytes",
        "expandedSizeBytes",
        "contents",
        "criticalFileHashes",
        "dependencies",
        "requirement",
    }
    for index, raw_component in enumerate(raw_components):
        component = _mapping(raw_component, f"{label}.components[{index}]")
        _exact_keys(component, component_fields, f"{label}.components[{index}]")
        name = component["name"]
        capabilities = component["capabilities"]
        dependencies = component["dependencies"]
        contents = component["contents"]
        critical_hashes = component["criticalFileHashes"]
        if (
            not isinstance(name, str)
            or SAFE_TOKEN_PATTERN.fullmatch(name) is None
            or name in components_by_name
            or not isinstance(capabilities, list)
            or not capabilities
            or len(capabilities) != len(set(capabilities))
            or any(
                not isinstance(capability, str)
                or SAFE_TOKEN_PATTERN.fullmatch(capability) is None
                for capability in capabilities
            )
            or not isinstance(dependencies, list)
            or len(dependencies) != len(set(dependencies))
            or any(
                not isinstance(dependency, str)
                or SAFE_TOKEN_PATTERN.fullmatch(dependency) is None
                for dependency in dependencies
            )
            or not isinstance(contents, list)
            or not contents
            or len(contents) != len(set(contents))
            or not isinstance(critical_hashes, dict)
            or not critical_hashes
            or not isinstance(component["url"], str)
            or not component["url"].startswith("https://")
            or not isinstance(component["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", component["sha256"]) is None
            or type(component["sizeBytes"]) is not int
            or component["sizeBytes"] <= 0
            or type(component["expandedSizeBytes"]) is not int
            or component["expandedSizeBytes"] < component["sizeBytes"]
            or component["requirement"] not in {"required", "optional"}
        ):
            raise EvidenceError(f"{label} manifest component is invalid")
        for relative in contents:
            if not isinstance(relative, str):
                raise EvidenceError(f"{label} manifest content path is invalid")
            path_value = PurePosixPath(relative)
            if (
                path_value.is_absolute()
                or "\\" in relative
                or any(part in {"", ".", ".."} for part in path_value.parts)
            ):
                raise EvidenceError(f"{label} manifest content path is unsafe")
        for relative, digest in critical_hashes.items():
            if relative not in contents or not isinstance(digest, str) or re.fullmatch(
                r"[0-9a-f]{64}", digest
            ) is None:
                raise EvidenceError(f"{label} manifest critical file is invalid")
        components_by_name[name] = component
    for name, component in components_by_name.items():
        if any(dependency not in components_by_name for dependency in component["dependencies"]):
            raise EvidenceError(f"{label} component dependency is unknown: {name}")

    installed_artifacts = _mapping(state["installedArtifacts"], f"{label}.installedArtifacts")
    installed_names = set(installed_artifacts)
    if "macos-arm64-core" not in installed_names or not installed_names.issubset(components_by_name):
        raise EvidenceError(f"{label} installed component closure is invalid")
    for name, digest in installed_artifacts.items():
        if digest != components_by_name[name]["sha256"]:
            raise EvidenceError(f"{label} installed component digest is invalid: {name}")
        missing = set(components_by_name[name]["dependencies"]) - installed_names
        if missing:
            raise EvidenceError(f"{label} installed component is missing dependencies: {name}")
    installed_capabilities = state["installedCapabilities"]
    expected_capabilities = sorted(
        capability
        for name in installed_names
        for capability in components_by_name[name]["capabilities"]
    )
    if installed_capabilities != expected_capabilities:
        raise EvidenceError(f"{label} installed capabilities do not match components")

    normalized_components = [
        {field: component[field] for field in component_fields}
        for component in sorted(components_by_name.values(), key=lambda value: value["name"])
    ]
    closure = {
        "schema_version": 2,
        "toolchain_api": 2,
        "key_id": manifest["keyID"],
        "version": manifest["version"],
        "app_version_range": {
            "minimum": app_range["minimum"],
            "maximum_exclusive": app_range.get("maximumExclusive"),
        },
        "signature_ed25519": manifest["signatureEd25519"],
        "components": normalized_components,
        "installed_artifacts": dict(sorted(installed_artifacts.items())),
        "installed_capabilities": expected_capabilities,
    }
    return (
        dict(manifest),
        components_by_name,
        installed_names,
        toolchain_identity_from_closure(closure),
    )


def _safe_zip_files(
    archive: zipfile.ZipFile,
    label: str,
) -> dict[str, zipfile.ZipInfo]:
    files: dict[str, zipfile.ZipInfo] = {}
    for member in archive.infolist():
        relative = PurePosixPath(member.filename)
        mode = member.external_attr >> 16
        if (
            relative.is_absolute()
            or any(part in {"", ".", ".."} for part in relative.parts)
            or "\\" in member.filename
            or stat.S_ISLNK(mode)
            or member.flag_bits & 0x1
            or member.filename in files
        ):
            raise EvidenceError(f"{label} contains an unsafe archive entry")
        if not member.is_dir():
            files[member.filename] = member
    if not files:
        raise EvidenceError(f"{label} must contain at least one file")
    return files


def _validate_component_archive(
    handle: Any,
    component: Mapping[str, Any],
    label: str,
) -> None:
    try:
        with zipfile.ZipFile(handle) as component_archive:
            files = _safe_zip_files(component_archive, label)
            if set(files) != set(component["contents"]):
                raise EvidenceError(f"{label} contents do not match the signed manifest")
            if sum(member.file_size for member in files.values()) > component["expandedSizeBytes"]:
                raise EvidenceError(f"{label} expanded size exceeds the signed manifest")
            for relative, expected_digest in component["criticalFileHashes"].items():
                hasher = hashlib.sha256()
                with component_archive.open(files[relative]) as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        hasher.update(chunk)
                if hasher.hexdigest() != expected_digest:
                    raise EvidenceError(f"{label} critical file digest is invalid")
    except zipfile.BadZipFile as error:
        raise EvidenceError(f"{label} must be a valid ZIP archive") from error


def _validate_toolchain_closure_archive(
    path: Path,
    label: str,
    components_by_name: Mapping[str, Mapping[str, Any]],
    installed_names: set[str],
) -> int:
    try:
        if not zipfile.is_zipfile(path):
            raise EvidenceError(f"{label} must be a valid ZIP archive")
        with zipfile.ZipFile(path) as closure_archive:
            files = _safe_zip_files(closure_archive, label)
            expected_members = {f"{name}.zip" for name in installed_names}
            if set(files) != expected_members:
                raise EvidenceError(f"{label} component closure does not match its install receipt")
            total_bytes = 0
            for name in sorted(installed_names):
                component = components_by_name[name]
                member = files[f"{name}.zip"]
                if member.file_size != component["sizeBytes"]:
                    raise EvidenceError(f"{label} component size is invalid: {name}")
                hasher = hashlib.sha256()
                with tempfile.TemporaryFile() as component_file:
                    with closure_archive.open(member) as source:
                        copied = 0
                        for chunk in iter(lambda: source.read(1024 * 1024), b""):
                            copied += len(chunk)
                            hasher.update(chunk)
                            component_file.write(chunk)
                    if copied != component["sizeBytes"] or hasher.hexdigest() != component["sha256"]:
                        raise EvidenceError(f"{label} component archive digest is invalid: {name}")
                    component_file.seek(0)
                    _validate_component_archive(
                        component_file,
                        component,
                        f"{label}.{name}",
                    )
                total_bytes += component["sizeBytes"]
            return total_bytes
    except (OSError, zipfile.BadZipFile) as error:
        raise EvidenceError(f"{label} could not be validated") from error


def _validate_toolchain_package_evidence(
    artifact_root: Path,
    descriptors: Mapping[str, Mapping[str, Any]],
    bound_toolchain_identity: str,
) -> dict[str, int]:
    normal_manifest, normal_components, normal_names, _ = _validated_toolchain_install_state(
        artifact_root / descriptors["normal_photo_toolchain_state"]["path"],
        "normal photo toolchain install state",
    )
    large_manifest, large_components, large_names, large_identity = _validated_toolchain_install_state(
        artifact_root / descriptors["large_area_toolchain_state"]["path"],
        "large area toolchain install state",
    )
    if canonical_json_bytes(normal_manifest) != canonical_json_bytes(large_manifest):
        raise EvidenceError("toolchain package closures do not use the same signed manifest")
    if large_identity != bound_toolchain_identity:
        raise EvidenceError("large area toolchain closure does not match the bound toolchain identity")
    if not normal_names.issubset(large_names):
        raise EvidenceError("normal photo toolchain closure is not contained in large area closure")
    normal_capabilities = {
        capability
        for name in normal_names
        for capability in normal_components[name]["capabilities"]
    }
    large_capabilities = {
        capability
        for name in large_names
        for capability in large_components[name]["capabilities"]
    }
    required_normal_capabilities = {
        "runtime.core",
        "geometry.colmap",
        "training.msplat",
    }
    if not required_normal_capabilities.issubset(normal_capabilities):
        raise EvidenceError(
            "normal photo toolchain capabilities do not provide the runnable COLMAP route"
        )
    normal_has_streaming = any(
        "streaming" in capability.split(".") for capability in normal_capabilities
    )
    large_has_streaming = any(
        "streaming" in capability.split(".") for capability in large_capabilities
    )
    same_archive = (
        descriptors["normal_photo_toolchain"]["sha256"]
        == descriptors["large_area_toolchain"]["sha256"]
    )
    if normal_has_streaming:
        raise EvidenceError("normal photo toolchain closure unexpectedly selects streaming")
    if large_has_streaming and normal_names == large_names:
        raise EvidenceError("streaming toolchain closure must add its signed components")
    if normal_names == large_names:
        if not same_archive:
            raise EvidenceError("identical toolchain component closures must use the same archive")
    elif same_archive:
        raise EvidenceError("distinct toolchain component closures cannot share one archive")
    normal_bytes = _validate_toolchain_closure_archive(
        artifact_root / descriptors["normal_photo_toolchain"]["path"],
        "normal_photo_toolchain",
        normal_components,
        normal_names,
    )
    large_bytes = _validate_toolchain_closure_archive(
        artifact_root / descriptors["large_area_toolchain"]["path"],
        "large_area_toolchain",
        large_components,
        large_names,
    )
    return {
        "normal_photo_toolchain": normal_bytes,
        "large_area_toolchain": large_bytes,
    }


def derive_metrics(
    observations: Mapping[str, Any],
    lane: str,
    machine: Mapping[str, Any],
    artifact_sizes: Mapping[str, int],
    *,
    gate_scopes: Iterable[str],
    valid_outcome: bool,
    requested_scale: int,
    holdout_count: int,
    candidate_run_configuration: Mapping[str, Any],
    holdout_indices: list[int],
    expected_orientation_status: str | None,
    request_binding: Mapping[str, Any],
    rendering_evidence: RenderingEvidence | None = None,
) -> dict[str, Any]:
    """Derive gate metrics from raw samples; aggregate metrics are not accepted."""
    if lane not in RELEASE_LANES:
        raise EvidenceError("unsupported benchmark lane")
    scopes = set(gate_scopes)
    metrics = {
        name: unavailable()
        for name in (
            QUALITY_METRICS
            | SUITE_PERFORMANCE_METRICS
            | LONG_SEQUENCE_METRICS
            | STABILITY_METRICS
            | TOOLCHAIN_METRICS
        )
    }
    if not valid_outcome:
        return metrics
    raw_pipeline = _mapping(observations.get("pipeline_metrics"), "observations.pipeline_metrics")
    orientation_required = lane == LANE_REFERENCE and "scene_quality" in scopes
    if not orientation_required:
        unexpected_orientation = sorted(
            name
            for name in ORIENTATION_PIPELINE_FIELDS
            if raw_pipeline.get(name) is not None
        )
        if unexpected_orientation:
            raise EvidenceError(
                "orientation pipeline metrics require reference scene_quality evidence: "
                + ", ".join(unexpected_orientation)
            )
    metrics.update(_pipeline_metrics(raw_pipeline))
    if (
        orientation_required
        and raw_pipeline.get("orientation_status") != expected_orientation_status
    ):
        raise EvidenceError(
            "measured orientation status does not match the pinned scene expectation"
        )
    if raw_pipeline.get("dropped_intersection_count") is None:
        raise EvidenceError("every valid run must report dropped_intersection_count")
    if raw_pipeline["dropped_intersection_count"] != 0:
        raise EvidenceError("a valid PLY cannot contain dropped raster intersections")
    timing = _mapping(observations.get("timing"), "observations.timing")
    metrics.update(_timing_metrics(timing, lane, scopes))
    expected_runs = _execution_runs(timing, lane, scopes)
    metrics.update(
        _memory_metrics(
            observations.get("memory"),
            expected_runs,
            machine,
            lane,
        )
    )
    if lane == LANE_REFERENCE:
        required_pipeline: set[str] = set()
        if "scene_quality" in scopes:
            required_pipeline.update(
                {
                    "scheduled_pairs",
                    "attempted_pairs",
                    "raw_matched_pairs",
                    "spatially_verified_pairs",
                    "connected_components",
                    "isolated_views",
                    "articulation_views",
                    "biconnected_blocks",
                    "largest_biconnected_block_views",
                    "second_largest_biconnected_block_views",
                    "local_pairs",
                    "retrieval_pairs",
                    "loop_pairs",
                    "orientation_status",
                    "dropped_intersection_count",
                }
            )
        if "scene_performance" in scopes:
            required_pipeline.update(
                {
                    "matcher_seconds",
                    "mapping_seconds",
                    "bundle_adjustment_cycles",
                    "raster_fallback_count",
                    "raster_exact_fallback_elapsed_seconds",
                    "raster_exact_buffer_growth_count",
                    "raster_exact_buffer_bytes_added",
                    "raster_replay_elapsed_seconds",
                    "raster_peak_exact_intersection_capacity",
                    "maximum_tile_intersections",
                }
            )
        if "suite_performance" in scopes:
            required_pipeline.update({"bundle_adjustment_cycles"})
        missing_pipeline = sorted(name for name in required_pipeline if raw_pipeline.get(name) is None)
        if missing_pipeline:
            raise EvidenceError(
                "required pipeline metrics are not measured: " + ", ".join(missing_pipeline)
            )
        if "scene_quality" in scopes:
            scheduled = raw_pipeline["scheduled_pairs"]
            local = raw_pipeline["local_pairs"]
            retrieval = raw_pipeline["retrieval_pairs"]
            loop = raw_pipeline["loop_pairs"]
            verified = raw_pipeline["spatially_verified_pairs"]
            if candidate_run_configuration["pairing_policy"] == "unordered_exhaustive":
                expected_exhaustive = requested_scale * (requested_scale - 1) // 2
                if scheduled != expected_exhaustive or any((local, retrieval, loop)):
                    raise EvidenceError(
                        "unordered exhaustive scheduled pair count is incomplete"
                    )
            elif scheduled != local + retrieval + loop:
                raise EvidenceError(
                    "scheduled pair count must equal local, retrieval, and loop pair counts"
                )
            if verified < requested_scale - 1:
                raise EvidenceError(
                    "a connected verified graph requires at least selected_view_count - 1 pairs"
                )
            if candidate_run_configuration["input_topology"] == "continuous":
                expected_local = sum(
                    requested_scale - offset
                    for offset in candidate_run_configuration["temporal_offsets"]
                )
                if local != expected_local:
                    raise EvidenceError(
                        f"local pair count must match the resolved temporal schedule ({expected_local})"
                    )
    if lane != LANE_REFERENCE:
        return metrics

    if "scene_quality" in scopes:
        registration = _mapping(observations.get("registration"), "observations.registration")
        _exact_keys(registration, {"candidate", "colmap", "baseline"}, "observations.registration")
        candidate_registered = _booleans(registration.get("candidate"), "registration.candidate")
        colmap_registered = _booleans(registration.get("colmap"), "registration.colmap")
        baseline_registered = _booleans(registration.get("baseline"), "registration.baseline")
        if len(candidate_registered) != len(colmap_registered):
            raise EvidenceError("registration sample counts must match")
        if len(candidate_registered) != len(baseline_registered):
            raise EvidenceError("baseline registration sample count must match the candidate")
        if len(candidate_registered) != requested_scale:
            raise EvidenceError(
                f"registration sample count must equal requested scale {requested_scale}"
            )
        residuals, sparse_point_count = _residual_samples(
            observations.get("residual_pixels"),
            candidate_registered,
        )

        (
            candidate_ate,
            colmap_ate,
            candidate_rotation,
            colmap_rotation,
            candidate_translation,
            colmap_translation,
        ) = _pose_samples(
            observations.get("pose"),
            candidate_registered,
            colmap_registered,
        )
        colmap_rms = math.sqrt(sum(value * value for value in colmap_ate) / len(colmap_ate))
        if colmap_rms == 0:
            raise EvidenceError("COLMAP ATE reference must be nonzero")
        candidate_rms = math.sqrt(sum(value * value for value in candidate_ate) / len(candidate_ate))
        if rendering_evidence is None:
            raise EvidenceError("scene quality requires rendered pixel evidence")
        balanced_records = rendering_evidence.balanced
        fast_records = rendering_evidence.fast
        if not isinstance(balanced_records, list) or len(balanced_records) != holdout_count:
            raise EvidenceError(
                f"rendering.balanced must contain exactly {holdout_count} held-out views"
            )
        if not isinstance(fast_records, list) or len(fast_records) != holdout_count:
            raise EvidenceError(
                f"rendering.fast must contain exactly {holdout_count} held-out views"
            )
        (
            balanced_psnr,
            balanced_ssim,
            balanced_lpips,
            paired_psnr,
            paired_ssim,
            paired_lpips,
        ) = _paired_losses(
            balanced_records,
            "rendering.balanced",
            holdout_indices,
            include_paired_baseline=True,
        )
        fast_psnr, fast_ssim, fast_lpips, _, _, _ = _paired_losses(
            fast_records,
            "rendering.fast",
            holdout_indices,
            include_paired_baseline=False,
        )
        metrics.update(
            {
                "registered_views": measured(sum(candidate_registered)),
                "total_views": measured(len(candidate_registered)),
                "colmap_registered_views": measured(sum(colmap_registered)),
                "baseline_registered_views": measured(sum(baseline_registered)),
                "residual_provenance": measured("track_reprojection"),
                "points": measured(sparse_point_count),
                "observations": measured(len(residuals)),
                "residual_median_pixels": measured(statistics.median(residuals)),
                "residual_p90_pixels": measured(_percentile(residuals, 0.90)),
                "ate_colmap_ratio": measured(candidate_rms / colmap_rms),
                "rotation_rpe_delta_degrees": measured(
                    max(0.0, statistics.median(candidate_rotation) - statistics.median(colmap_rotation))
                ),
                "translation_rpe_delta_percentage_points": measured(
                    max(
                        0.0,
                        statistics.median(candidate_translation) - statistics.median(colmap_translation),
                    )
                ),
                "balanced_median_psnr_loss_db": measured(statistics.median(balanced_psnr)),
                "balanced_median_ssim_loss": measured(statistics.median(balanced_ssim)),
                "balanced_median_lpips_increase": measured(statistics.median(balanced_lpips)),
                "balanced_scene_psnr_loss_db": measured(statistics.median(balanced_psnr)),
                "balanced_scene_ssim_loss": measured(statistics.median(balanced_ssim)),
                "balanced_scene_lpips_increase": measured(statistics.median(balanced_lpips)),
                "fast_scene_psnr_loss_db": measured(statistics.median(fast_psnr)),
                "fast_scene_ssim_loss": measured(statistics.median(fast_ssim)),
                "fast_scene_lpips_increase": measured(statistics.median(fast_lpips)),
                "paired_balanced_scene_psnr_loss_db": measured(statistics.median(paired_psnr)),
                "paired_balanced_scene_ssim_loss": measured(statistics.median(paired_ssim)),
                "paired_balanced_scene_lpips_increase": measured(statistics.median(paired_lpips)),
            }
        )

    if "long_sequence" in scopes:
        long_sequence = _mapping(observations.get("long_sequence"), "observations.long_sequence")
        _exact_keys(
            long_sequence,
            {"processed_frames", "analysis_seconds", "rss_windows"},
            "observations.long_sequence",
        )
        frames = long_sequence.get("processed_frames")
        seconds = long_sequence.get("analysis_seconds")
        if type(frames) is not int or frames <= 0:
            raise EvidenceError("long_sequence.processed_frames must be a positive integer")
        if (
            isinstance(seconds, bool)
            or not isinstance(seconds, (int, float))
            or not math.isfinite(seconds)
            or seconds <= 0
        ):
            raise EvidenceError("long_sequence.analysis_seconds must be positive and finite")
        if frames != requested_scale:
            raise EvidenceError("long_sequence.processed_frames must equal the requested scale")
        raw_windows = long_sequence.get("rss_windows")
        expected_window_count = math.ceil(frames / 500)
        if not isinstance(raw_windows, list) or len(raw_windows) != expected_window_count:
            raise EvidenceError("long_sequence.rss_windows must cover every 500-frame window")
        windows: list[float] = []
        for index, raw_window in enumerate(raw_windows):
            window = _mapping(raw_window, f"long_sequence.rss_windows[{index}]")
            _exact_keys(
                window,
                {"start_frame", "end_frame", "rss_bytes"},
                f"long_sequence.rss_windows[{index}]",
            )
            expected_start = index * 500
            expected_end = min(frames - 1, expected_start + 499)
            if window["start_frame"] != expected_start or window["end_frame"] != expected_end:
                raise EvidenceError("long_sequence.rss_windows frame coverage is not contiguous")
            rss = window["rss_bytes"]
            if type(rss) is not int or rss <= 0:
                raise EvidenceError("long_sequence.rss_windows rss_bytes must be positive")
            windows.append(float(rss))
        if len(windows) < 2:
            raise EvidenceError("long_sequence.rss_windows must include a second window")
        growth = max(0.0, (windows[-1] - windows[1]) / windows[1])
        metrics["long_sequence_analysis_fps"] = measured(frames / float(seconds))
        metrics["long_sequence_frames"] = measured(frames)
        metrics["long_sequence_rss_growth_fraction"] = measured(growth)

    if "stability" in scopes:
        stability = _mapping(observations.get("stability"), "observations.stability")
        _exact_keys(stability, {"runs"}, "observations.stability")
        stability_runs = stability.get("runs")
        if not isinstance(stability_runs, list) or len(stability_runs) != 50:
            raise EvidenceError("observations.stability.runs must contain exactly 50 runs")
        crashes = 0
        corrupt_outputs = 0
        categories: set[str] = set()
        profiles: set[str] = set()
        interruption_stages: set[str] = set()
        recovery_actions: set[str] = set()
        stage_recovery_pairs: set[tuple[str, str]] = set()
        recovery_results: list[bool] = []
        for index, raw in enumerate(stability_runs):
            sample = _mapping(raw, f"stability.runs[{index}]")
            _exact_keys(
                sample,
                {
                    "category",
                    "detail_profile",
                    "interruption_stage",
                    "recovery_action",
                    "crashed",
                    "corrupt_output",
                    "recovery_succeeded",
                },
                f"stability.runs[{index}]",
            )
            if (
                not isinstance(sample["crashed"], bool)
                or not isinstance(sample["corrupt_output"], bool)
            ):
                raise EvidenceError("stability flags must be boolean")
            if sample["category"] not in {
                "object_orbit",
                "interior_walkthrough",
                "professional_photos",
                "large_area_exterior",
                "low_light",
            }:
                raise EvidenceError("stability category is invalid")
            if sample["detail_profile"] not in {"fast", "balanced", "high_detail"}:
                raise EvidenceError("stability detail profile is invalid")
            if sample["interruption_stage"] not in {
                "none",
                "prepare",
                "reconstruct",
                "train",
                "finish",
            }:
                raise EvidenceError("stability interruption stage is invalid")
            if sample["recovery_action"] not in {"none", "cancel_resume", "relaunch_resume"}:
                raise EvidenceError("stability recovery action is invalid")
            is_uninterrupted = sample["interruption_stage"] == "none"
            if is_uninterrupted != (sample["recovery_action"] == "none"):
                raise EvidenceError("stability interruption none must pair only with recovery none")
            if is_uninterrupted:
                if sample["recovery_succeeded"] is not None:
                    raise EvidenceError("uninterrupted stability runs must not report recovery")
            elif type(sample["recovery_succeeded"]) is not bool:
                raise EvidenceError("interrupted stability runs must report recovery success")
            crashes += sample["crashed"]
            corrupt_outputs += sample["corrupt_output"]
            categories.add(sample["category"])
            profiles.add(sample["detail_profile"])
            interruption_stages.add(sample["interruption_stage"])
            recovery_actions.add(sample["recovery_action"])
            stage_recovery_pairs.add(
                (sample["interruption_stage"], sample["recovery_action"])
            )
            if not is_uninterrupted:
                recovery_results.append(sample["recovery_succeeded"])
        if categories != {
            "object_orbit",
            "interior_walkthrough",
            "professional_photos",
            "large_area_exterior",
            "low_light",
        }:
            raise EvidenceError("stability runs must cover every valid capture category")
        if profiles != {"fast", "balanced", "high_detail"}:
            raise EvidenceError("stability runs must cover every detail profile")
        if not {"prepare", "reconstruct", "train", "finish"}.issubset(interruption_stages):
            raise EvidenceError("stability runs must cover every durable interruption stage")
        if not {"cancel_resume", "relaunch_resume"}.issubset(recovery_actions):
            raise EvidenceError("stability runs must cover cancel and relaunch recovery")
        required_pairs = {
            (stage, action)
            for stage in ("prepare", "reconstruct", "train", "finish")
            for action in ("cancel_resume", "relaunch_resume")
        }
        if not required_pairs.issubset(stage_recovery_pairs):
            raise EvidenceError("stability runs must cover every durable stage and recovery pair")
        metrics.update(
            {
                "repeat_runs": measured(len(stability_runs)),
                "crashes": measured(crashes),
                "corrupt_outputs": measured(corrupt_outputs),
                "durable_state_recovery_succeeded": measured(all(recovery_results)),
            }
        )

    if "toolchain" in scopes:
        required_size_artifacts = {"normal_photo_toolchain", "large_area_toolchain"}
        missing_sizes = required_size_artifacts - set(artifact_sizes)
        if missing_sizes:
            raise EvidenceError("missing toolchain size artifacts: " + ", ".join(sorted(missing_sizes)))
        metrics["normal_photo_toolchain_bytes"] = measured(artifact_sizes["normal_photo_toolchain"])
        metrics["large_area_toolchain_bytes"] = measured(artifact_sizes["large_area_toolchain"])
        metrics.update(
            _toolchain_scenario_metrics(
                observations.get("toolchain_scenarios"),
                request_binding,
            )
        )
    return metrics


def collect_machine_metadata() -> dict[str, Any]:
    def command(argv: list[str]) -> str:
        try:
            return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=20).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return "not_available"

    def sysctl(name: str) -> str:
        return command(["/usr/sbin/sysctl", "-n", name])

    def integer_sysctl(name: str) -> int | None:
        try:
            return int(sysctl(name))
        except ValueError:
            return None

    return {
        "architecture": platform.machine(),
        "chip": sysctl("machdep.cpu.brand_string"),
        "hardware_model": sysctl("hw.model"),
        "logical_cpus": integer_sysctl("hw.logicalcpu"),
        "macos_build": command(["/usr/bin/sw_vers", "-buildVersion"]),
        "macos_version": command(["/usr/bin/sw_vers", "-productVersion"]),
        "physical_cpus": integer_sysctl("hw.physicalcpu"),
        "physical_memory_bytes": integer_sysctl("hw.memsize"),
        "swift_version": command(["/usr/bin/xcrun", "swift", "--version"]),
        "xcode_version": command(["/usr/bin/xcodebuild", "-version"]),
    }


def validate_machine_lane(machine: Mapping[str, Any], lane: str) -> None:
    required = {
        "architecture",
        "chip",
        "hardware_model",
        "logical_cpus",
        "macos_build",
        "macos_version",
        "physical_cpus",
        "physical_memory_bytes",
        "swift_version",
        "xcode_version",
    }
    _exact_keys(machine, required, "machine")
    if machine["architecture"] != "arm64":
        raise EvidenceError("release evidence must be measured on Apple Silicon")
    version = machine["macos_version"]
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){1,2}", version):
        raise EvidenceError("machine macOS version is unavailable")
    if int(version.split(".", 1)[0]) < 15:
        raise EvidenceError("release evidence requires macOS 15 or newer")
    xcode_version = machine["xcode_version"]
    if not isinstance(xcode_version, str) or xcode_version.splitlines()[:1] != ["Xcode 16.4"]:
        raise EvidenceError("release evidence requires Xcode 16.4")
    memory = machine["physical_memory_bytes"]
    if type(memory) is not int:
        raise EvidenceError("machine physical memory is unavailable")
    gib = 1024**3
    if lane == LANE_REFERENCE:
        if "M4 Max" not in str(machine["chip"]) or memory != 48 * gib:
            raise EvidenceError("reference lane requires an M4 Max with exactly 48 GiB memory")
    elif lane == LANE_CONSTRAINED:
        if not 14 * gib <= memory <= 17 * gib:
            raise EvidenceError("constrained lane requires a 14-16 GiB Mac")
    elif lane == LANE_EIGHT_GB:
        if not 7 * gib <= memory <= 9 * gib:
            raise EvidenceError("8 GB lane requires a 7-9 GiB Mac")
    else:
        raise EvidenceError("unsupported benchmark lane")


def validate_request(request: Any) -> Mapping[str, Any]:
    value = _mapping(request, "request")
    _exact_keys(
        value,
        {
            "schema_version",
            "binding",
            "baseline_run_configuration",
            "candidate_run_configuration",
            "category",
            "capture_traits",
            "holdout_indices",
            "reference_artifacts",
            "timing_basis",
            "expected_outcome",
            "input_kind",
            "gate_scopes",
            "rendering_driver_identity",
        },
        "request",
    )
    if value["schema_version"] != 4:
        raise EvidenceError("request schema_version must be 4")
    binding = _mapping(value["binding"], "request.binding")
    validate_runner_identity(
        value["rendering_driver_identity"],
        RENDERING_DRIVER_IDENTITY,
    )
    _exact_keys(
        binding,
        {
            "profile",
            "scene_id",
            "scale",
            "lane",
            "input_digest",
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "baseline_git_commit",
            "baseline_toolchain_identity",
            "baseline_configuration_digest",
            "benchmark_contract_sha256",
        },
        "request.binding",
    )
    if binding["profile"] != "release":
        raise EvidenceError("protected evidence requests are release-only")
    _token(binding["scene_id"], "request.binding.scene_id")
    for field in (
        "input_digest",
        "corpus_digest",
        "thresholds_digest",
        "toolchain_identity",
        "baseline_toolchain_identity",
        "baseline_configuration_digest",
        "benchmark_contract_sha256",
    ):
        _digest(binding[field], f"request.binding.{field}")
    baseline_configuration = _mapping(
        value["baseline_run_configuration"],
        "request.baseline_run_configuration",
    )
    if sha256_bytes(canonical_json_bytes(baseline_configuration)) != binding["baseline_configuration_digest"]:
        raise EvidenceError("request baseline_run_configuration does not match its digest")
    if not isinstance(binding["git_commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", binding["git_commit"]):
        raise EvidenceError("request.binding.git_commit is invalid")
    if not isinstance(binding["baseline_git_commit"], str) or not re.fullmatch(
        r"[0-9a-f]{40}", binding["baseline_git_commit"]
    ):
        raise EvidenceError("request.binding.baseline_git_commit is invalid")
    if type(binding["scale"]) is not int or binding["scale"] <= 0:
        raise EvidenceError("request.binding.scale is invalid")
    if binding["lane"] not in RELEASE_LANES:
        raise EvidenceError("request.binding.lane is invalid")
    if value["category"] not in {
        "object_orbit",
        "interior_walkthrough",
        "professional_photos",
        "large_area_exterior",
        "low_light",
        "invalid",
    }:
        raise EvidenceError("request.category is invalid")
    capture_traits = value["capture_traits"]
    if (
        not isinstance(capture_traits, list)
        or not capture_traits
        or capture_traits != sorted(capture_traits)
        or len(capture_traits) != len(set(capture_traits))
        or any(not isinstance(trait, str) or not SAFE_TOKEN_PATTERN.fullmatch(trait) for trait in capture_traits)
    ):
        raise EvidenceError("request.capture_traits must be a sorted unique token array")
    if value["input_kind"] not in {"video", "photos", "mixed"}:
        raise EvidenceError("request.input_kind is invalid")
    expected = _mapping(value["expected_outcome"], "request.expected_outcome")
    if expected.get("kind") == "valid":
        _exact_keys(expected, {"kind"}, "request.expected_outcome")
        if value["category"] == "invalid":
            raise EvidenceError("a valid request cannot use the invalid category")
    elif expected.get("kind") == "invalid":
        _exact_keys(expected, {"kind", "failure_type"}, "request.expected_outcome")
        _token(expected["failure_type"], "request.expected_outcome.failure_type")
        if value["category"] != "invalid":
            raise EvidenceError("an invalid request must use the invalid category")
    else:
        raise EvidenceError("request.expected_outcome is invalid")
    holdout_indices = value["holdout_indices"]
    if expected["kind"] == "valid":
        if (
            not isinstance(holdout_indices, list)
            or not holdout_indices
            or holdout_indices != sorted(holdout_indices)
            or len(holdout_indices) != len(set(holdout_indices))
            or any(
                type(index) is not int or index < 0 or index >= binding["scale"]
                for index in holdout_indices
            )
        ):
            raise EvidenceError(
                "request.holdout_indices must be sorted, unique, and within the selected scale"
            )
        if value["input_kind"] == "video" and holdout_indices != list(
            range(4, binding["scale"], 5)
        ):
            raise EvidenceError("video holdout indices must contain every fifth selected frame")
    elif holdout_indices != []:
        raise EvidenceError("invalid requests must not declare rendering holdouts")
    if value["timing_basis"] != "selected_view_count":
        raise EvidenceError("request timing_basis must be selected_view_count")
    reference_artifacts = _mapping(value["reference_artifacts"], "request.reference_artifacts")
    reference_digest_fields = {
        "selection_manifest_sha256",
        "ground_truth_poses_sha256",
        "accurate_colmap_model_sha256",
        "accurate_rendering_reference_sha256",
        "ground_truth_preparation_sha256",
        "paired_baseline_rendering_reference_sha256",
        "orientation_label_sha256",
    }
    if expected["kind"] == "valid":
        _exact_keys(
            reference_artifacts,
            reference_digest_fields | {"orientation_expected_status"},
            "request.reference_artifacts",
        )
        for field in reference_digest_fields:
            _digest(reference_artifacts[field], f"request.reference_artifacts.{field}")
        if reference_artifacts["orientation_expected_status"] not in PIPELINE_ENUM_METRICS[
            "orientation_status"
        ]:
            raise EvidenceError("request orientation_expected_status is invalid")
    else:
        _exact_keys(reference_artifacts, {"status"}, "request.reference_artifacts")
        if reference_artifacts["status"] != "not_applicable":
            raise EvidenceError("invalid requests must mark reference artifacts not_applicable")
    candidate_configuration = _mapping(
        value["candidate_run_configuration"],
        "request.candidate_run_configuration",
    )
    _exact_keys(
        candidate_configuration,
        {
            "detail_profile",
            "selected_frame_count",
            "capture_path",
            "input_topology",
            "camera_grouping",
            "lens_projection",
            "resource_policy",
            "compute_policy",
            "pairing_policy",
            "temporal_pairing",
            "temporal_offsets",
            "vocabulary_candidate_count",
            "vocabulary_verified_neighbor_count",
            "vocabulary_query_stride",
            "descriptor_matcher",
            "ba_global_frames_ratio",
            "ba_global_points_ratio",
            "ba_global_max_refinements",
            "ba_local_max_refinements",
            "ba_local_max_num_iterations",
            "ba_local_function_tolerance",
            "ba_global_function_tolerance",
            "ba_local_num_images",
            "trainer_iterations",
            "trainer_plateau_window",
            "run_seed",
        },
        "request.candidate_run_configuration",
    )
    expected_detail = "balanced" if binding["lane"] == LANE_REFERENCE else "fast"
    expected_resource = "automatic" if binding["lane"] == LANE_REFERENCE else "conserve_memory"
    if candidate_configuration["detail_profile"] != expected_detail:
        raise EvidenceError("candidate detail profile does not match its hardware lane")
    if candidate_configuration["resource_policy"] != expected_resource:
        raise EvidenceError("candidate resource policy does not match its hardware lane")
    if candidate_configuration["compute_policy"] != "metal_for_supported_stages":
        raise EvidenceError("candidate compute policy must prefer Metal where supported")
    if candidate_configuration["selected_frame_count"] != binding["scale"]:
        raise EvidenceError("candidate selected frame count does not match request scale")
    if candidate_configuration["descriptor_matcher"] != "faiss":
        raise EvidenceError("candidate descriptor matcher must be faiss")
    _baseline_mapper_cadence(baseline_configuration)
    _candidate_mapper_cadence(candidate_configuration)
    if candidate_configuration["run_seed"] != 42:
        raise EvidenceError("candidate run seed must be 42")
    gate_scopes = value["gate_scopes"]
    if (
        not isinstance(gate_scopes, list)
        or not gate_scopes
        or any(scope not in ALLOWED_GATE_SCOPES for scope in gate_scopes)
        or len(gate_scopes) != len(set(gate_scopes))
        or gate_scopes != sorted(gate_scopes)
    ):
        raise EvidenceError("request.gate_scopes must be a nonempty sorted list of supported scopes")
    if expected["kind"] == "invalid" and gate_scopes != ["invalid_input"]:
        raise EvidenceError("invalid requests must use only the invalid_input gate scope")
    if expected["kind"] == "valid" and "invalid_input" in gate_scopes:
        raise EvidenceError("valid requests cannot use the invalid_input gate scope")
    if "long_sequence" in gate_scopes and binding["scale"] != 3000:
        raise EvidenceError("long_sequence evidence must be bound to the 3000-frame scale")
    return value


def _validate_lane_outcome_payload(value: Any) -> dict[str, Any]:
    outcome = _mapping(value, "lane outcome")
    _exact_keys(outcome, {"kind", "stage", "reason", "exit_code"}, "lane outcome")
    kind = outcome["kind"]
    stage = outcome["stage"]
    reason = outcome["reason"]
    exit_code = outcome["exit_code"]
    if kind == "execution_failed":
        if stage != "measurement_runner":
            raise EvidenceError("execution lane outcome stage is invalid")
        if reason == "launch_failed":
            if exit_code is not None:
                raise EvidenceError("launch failure cannot report an exit code")
        elif reason == "timed_out":
            if type(exit_code) is not int or not -255 <= exit_code <= 255:
                raise EvidenceError("timeout outcome requires a bounded exit code")
        elif reason == "nonzero_exit":
            if type(exit_code) is not int or exit_code == 0 or not -255 <= exit_code <= 255:
                raise EvidenceError("nonzero outcome requires a bounded nonzero exit code")
        elif reason == "invalid_output":
            if exit_code != 0:
                raise EvidenceError("invalid output outcome requires exit code zero")
        elif reason in {"process_isolation_failed", "integrity_failed"}:
            if exit_code is not None:
                raise EvidenceError(f"{reason} cannot report an exit code")
        else:
            raise EvidenceError("execution lane outcome reason is invalid")
    elif kind == "environment_rejected":
        if (
            stage != "measurement_environment"
            or reason != "policy_violation"
            or exit_code != 0
        ):
            raise EvidenceError("environment lane outcome is invalid")
    elif kind == "infrastructure_blocked":
        if (
            reason not in {"host_monitor_failed", "postprocessing_failed"}
            or stage
            != {
                "host_monitor_failed": "host_monitor",
                "postprocessing_failed": "postprocessing",
            }.get(reason)
            or (
                reason == "host_monitor_failed"
                and exit_code not in {None, 0}
            )
            or (
                reason == "postprocessing_failed"
                and exit_code != 0
            )
        ):
            raise EvidenceError("infrastructure lane outcome is invalid")
    else:
        raise EvidenceError("lane outcome kind is invalid")
    return dict(outcome)


def _validate_environment_rejection_receipt(
    environment_path: Path,
    descriptor: Mapping[str, Any],
    request: Mapping[str, Any],
    machine: Mapping[str, Any],
) -> None:
    _exact_keys(
        descriptor,
        {"path", "sha256", "bytes"},
        "lane outcome environment receipt",
    )
    if descriptor["path"] != "measurement-environment.json":
        raise EvidenceError("lane outcome environment receipt path is invalid")
    artifact = _artifact_descriptor(environment_path, environment_path.parent)
    if artifact != descriptor:
        raise EvidenceError("lane outcome environment receipt descriptor is invalid")
    environment = _mapping(
        _load_bounded_json(environment_path, "measurement environment receipt"),
        "measurement environment receipt",
    )
    _exact_keys(
        environment,
        {
            "schema_version",
            "started_monotonic_seconds",
            "ended_monotonic_seconds",
            "commands",
            "measurement_environment",
        },
        "measurement environment receipt",
    )
    if environment["schema_version"] != 1:
        raise EvidenceError("measurement environment receipt schema is invalid")
    commands = environment["commands"]
    if not isinstance(commands, list) or any(
        not isinstance(item, Mapping) for item in commands
    ):
        raise EvidenceError("measurement environment receipt commands are invalid")
    rejections = measurement_environment_rejections(
        environment["measurement_environment"],
        machine,
        commands,
        environment["started_monotonic_seconds"],
        environment["ended_monotonic_seconds"],
        environment_path,
        request["rendering_driver_identity"]["executable_sha256"],
    )
    if not rejections:
        raise EvidenceError("environment lane outcome does not prove a policy rejection")


def derive_lane_outcome(
    request: Mapping[str, Any],
    lane: str,
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
    *,
    kind: str,
    reason: str,
    exit_code: int | None,
    environment_receipt_path: Path | None = None,
) -> dict[str, Any]:
    """Validate raw lane status evidence and return an unsigned receipt payload."""
    validated_request = validate_request(request)
    if lane not in RELEASE_LANES or lane != validated_request["binding"]["lane"]:
        raise EvidenceError("lane outcome does not match its request")
    runner = validate_runner_identity(runner_identity, lane)
    validate_machine_lane(machine, lane)
    stage = {
        "environment_rejected": "measurement_environment",
        "infrastructure_blocked": {
            "host_monitor_failed": "host_monitor",
            "postprocessing_failed": "postprocessing",
        }.get(reason),
    }.get(kind, "measurement_runner")
    outcome = _validate_lane_outcome_payload(
        {
            "kind": kind,
            "stage": stage,
            "reason": reason,
            "exit_code": exit_code,
        }
    )
    if kind == "environment_rejected":
        if environment_receipt_path is None:
            raise EvidenceError("environment rejection requires an environment receipt")
        descriptor = _artifact_descriptor(
            environment_receipt_path,
            environment_receipt_path.parent,
        )
        if descriptor["path"] != "measurement-environment.json":
            raise EvidenceError("environment receipt path is not canonical")
        environment_receipt: dict[str, Any] | None = descriptor
        _validate_environment_rejection_receipt(
            environment_receipt_path,
            environment_receipt,
            validated_request,
            machine,
        )
    else:
        if environment_receipt_path is not None:
            raise EvidenceError("lane outcome cannot carry an environment receipt")
        environment_receipt = None
    producer_path = Path(__file__).resolve()
    unsigned = {
        "schema_version": 1,
        "request_sha256": sha256_bytes(canonical_json_bytes(validated_request)),
        "lane": lane,
        "machine": dict(machine),
        "producer": {
            "protocol_version": PROTOCOL_VERSION,
            "version": PRODUCER_VERSION,
            "executable": PRODUCER_RELATIVE_PATH,
            "sha256": sha256_file(producer_path),
        },
        "measurement_runner": runner,
        "outcome": outcome,
        "environment_receipt": environment_receipt,
    }
    return unsigned


def validate_prepared_lane_outcome_file(
    path: Path,
    expected_request: Mapping[str, Any],
    expected_lane: str,
    expected_measurement_runner: Mapping[str, Any],
) -> Mapping[str, Any]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EvidenceError("lane outcome is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or path.is_symlink()
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > MAX_LANE_OUTCOME_BYTES
    ):
        raise EvidenceError("lane outcome must be a bounded single-link regular file")
    receipt = _mapping(_load_bounded_json(path, "lane outcome"), "lane outcome")
    _exact_keys(
        receipt,
        {
            "schema_version",
            "request_sha256",
            "lane",
            "machine",
            "producer",
            "measurement_runner",
            "outcome",
            "environment_receipt",
        },
        "lane outcome",
    )
    request = validate_request(expected_request)
    if (
        receipt["schema_version"] != 1
        or receipt["lane"] != expected_lane
        or expected_lane != request["binding"]["lane"]
        or receipt["request_sha256"] != sha256_bytes(canonical_json_bytes(request))
    ):
        raise EvidenceError("lane outcome request binding is invalid")
    producer = _mapping(receipt["producer"], "lane outcome producer")
    _exact_keys(
        producer,
        {"protocol_version", "version", "executable", "sha256"},
        "lane outcome producer",
    )
    if producer != {
        "protocol_version": PROTOCOL_VERSION,
        "version": PRODUCER_VERSION,
        "executable": PRODUCER_RELATIVE_PATH,
        "sha256": sha256_file(Path(__file__).resolve()),
    }:
        raise EvidenceError("lane outcome producer is invalid")
    if validate_runner_identity(receipt["measurement_runner"], expected_lane) != (
        validate_runner_identity(expected_measurement_runner, expected_lane)
    ):
        raise EvidenceError("lane outcome measurement runner is invalid")
    machine = _mapping(receipt["machine"], "lane outcome machine")
    validate_machine_lane(machine, expected_lane)
    outcome = _validate_lane_outcome_payload(receipt["outcome"])
    environment_descriptor = receipt["environment_receipt"]
    if outcome["kind"] in {"execution_failed", "infrastructure_blocked"}:
        if environment_descriptor is not None:
            raise EvidenceError(
                f"{outcome['kind']} lane outcome cannot carry environment evidence"
            )
        return receipt

    descriptor = _mapping(environment_descriptor, "lane outcome environment receipt")
    _validate_environment_rejection_receipt(
        path.parent / "measurement-environment.json",
        descriptor,
        request,
        machine,
    )
    return receipt


def _artifact_descriptor(path: Path, root: Path) -> dict[str, Any]:
    if root.is_symlink() or not root.is_dir():
        raise EvidenceError("artifact root must be a real directory")
    canonical_root = root.resolve(strict=True)
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise EvidenceError(f"artifact escapes evidence root: {path.name}") from error
    cursor = root
    for part in PurePosixPath(relative).parts:
        cursor /= part
        if cursor.is_symlink():
            raise EvidenceError(f"artifact path contains a symlink: {relative}")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise EvidenceError(f"artifact must be a regular file: {relative}") from error
    if resolved != canonical_root and canonical_root not in resolved.parents:
        raise EvidenceError(f"artifact escapes evidence root: {relative}")
    if not path.is_file():
        raise EvidenceError(f"artifact must be a regular file: {relative}")
    return {"path": relative, "sha256": sha256_file(path), "bytes": path.stat().st_size}


def _render_relative_path(value: Any, label: str) -> PurePosixPath:
    if not isinstance(value, str):
        raise EvidenceError(f"{label} must be a relative path")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or any(part in {"", ".", ".."} for part in path.parts)
        or "\\" in value
    ):
        raise EvidenceError(f"{label} is unsafe")
    return path


def _render_camera(value: Any, label: str) -> dict[str, Any]:
    camera = _mapping(value, label)
    _exact_keys(
        camera,
        {
            "width",
            "height",
            "projection_matrix_column_major",
            "world_to_camera_matrix_column_major",
        },
        label,
    )
    width = camera["width"]
    height = camera["height"]
    if (
        type(width) is not int
        or type(height) is not int
        or not 64 <= width <= 16_384
        or not 64 <= height <= 16_384
        or width * height > 4_194_304
    ):
        raise EvidenceError(f"{label} dimensions exceed the 4,194,304-pixel render limit")
    for field in (
        "projection_matrix_column_major",
        "world_to_camera_matrix_column_major",
    ):
        matrix = camera[field]
        if (
            not isinstance(matrix, list)
            or len(matrix) != 16
            or any(
                isinstance(number, bool)
                or not isinstance(number, (int, float))
                or not math.isfinite(number)
                for number in matrix
            )
        ):
            raise EvidenceError(f"{label}.{field} must contain 16 finite numbers")
    return dict(camera)


def _open_render_artifact(root: Path, relative: PurePosixPath, label: str) -> int:
    if not relative.parts:
        raise EvidenceError(f"{label} path is empty")
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    file_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        directory = os.open(root, directory_flags)
    except OSError as error:
        raise EvidenceError("render artifact root is missing or unsafe") from error
    try:
        for component in relative.parts[:-1]:
            try:
                child = os.open(component, directory_flags, dir_fd=directory)
            except OSError as error:
                raise EvidenceError(f"{label} path is missing or unsafe") from error
            os.close(directory)
            directory = child
        try:
            return os.open(relative.parts[-1], file_flags, dir_fd=directory)
        except OSError as error:
            raise EvidenceError(f"{label} is missing or unsafe") from error
    finally:
        os.close(directory)


def _load_render_image(
    *,
    artifact_root: Path,
    relative_path: PurePosixPath,
    expected_sha256: str,
    expected_width: int,
    expected_height: int,
    label: str,
) -> tuple[Any, dict[str, Any]]:
    try:
        import numpy
        from PIL import Image
    except ImportError as error:
        raise EvidenceError(
            "render scoring requires the hash-locked numpy and Pillow packages"
        ) from error
    descriptor = _open_render_artifact(artifact_root, relative_path, label)
    try:
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode):
                raise EvidenceError(f"{label} must be a regular file")
            maximum_bytes = max(16 * 1024 * 1024, expected_width * expected_height * 4)
            chunks = []
            total = 0
            while True:
                try:
                    chunk = os.read(descriptor, 1024 * 1024)
                except InterruptedError:
                    continue
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum_bytes:
                    raise EvidenceError(f"{label} is larger than its bound dimensions allow")
                chunks.append(chunk)
            after = os.fstat(descriptor)
        except EvidenceError:
            raise
        except OSError as error:
            raise EvidenceError(f"{label} could not be read safely") from error
    finally:
        os.close(descriptor)
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise EvidenceError(f"{label} changed while it was read")
    encoded = b"".join(chunks)
    digest = sha256_bytes(encoded)
    if digest != expected_sha256:
        raise EvidenceError(f"{label} digest does not match its pinned reference")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(encoded)) as image:
                if image.format != "PNG" or image.mode != "RGB":
                    raise EvidenceError(f"{label} must be an 8-bit RGB PNG")
                if image.size != (expected_width, expected_height):
                    raise EvidenceError(f"{label} dimensions do not match its bound camera")
                image.load()
                pixels = numpy.asarray(image, dtype=numpy.float32) / 255.0
    except EvidenceError:
        raise
    except (
        OSError,
        ValueError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ) as error:
        raise EvidenceError(f"{label} is not a readable PNG") from error
    if pixels.shape != (expected_height, expected_width, 3) or not numpy.isfinite(pixels).all():
        raise EvidenceError(f"{label} pixel data is invalid")
    return pixels, {
        "path": relative_path.as_posix(),
        "sha256": digest,
        "bytes": len(encoded),
    }


def _separable_gaussian_blur(image: Any) -> Any:
    import numpy

    kernel = numpy.asarray(
        [
            0.00102838008447911,
            0.007598758135239185,
            0.03600077212843082,
            0.10936068950970002,
            0.21300552785396576,
            0.26601171493530273,
            0.21300552785396576,
            0.10936068950970002,
            0.03600077212843082,
            0.007598758135239185,
            0.00102838008447911,
        ],
        dtype=numpy.float32,
    )
    radius = len(kernel) // 2
    horizontal_source = numpy.pad(image, ((0, 0), (radius, radius), (0, 0)), mode="reflect")
    horizontal = numpy.zeros_like(image)
    for offset, weight in enumerate(kernel):
        horizontal += horizontal_source[:, offset : offset + image.shape[1], :] * weight
    vertical_source = numpy.pad(horizontal, ((radius, radius), (0, 0), (0, 0)), mode="reflect")
    result = numpy.zeros_like(image)
    for offset, weight in enumerate(kernel):
        result += vertical_source[offset : offset + image.shape[0], :, :] * weight
    return result


def _pixel_metrics(candidate: Any, target: Any, lpips_distance: Any) -> tuple[float, float, float]:
    import numpy

    if candidate.shape != target.shape:
        raise EvidenceError("rendered and ground-truth image dimensions do not match")
    difference = candidate - target
    mean_squared_error = float(numpy.mean(difference * difference, dtype=numpy.float64))
    psnr = 100.0 if mean_squared_error == 0 else -10.0 * math.log10(mean_squared_error)

    mu_candidate = _separable_gaussian_blur(candidate)
    mu_target = _separable_gaussian_blur(target)
    variance_candidate = numpy.maximum(
        0,
        _separable_gaussian_blur(candidate * candidate) - mu_candidate * mu_candidate,
    )
    variance_target = numpy.maximum(
        0,
        _separable_gaussian_blur(target * target) - mu_target * mu_target,
    )
    covariance = (
        _separable_gaussian_blur(candidate * target) - mu_candidate * mu_target
    )
    c1 = 0.01**2
    c2 = 0.03**2
    numerator = (2 * mu_candidate * mu_target + c1) * (2 * covariance + c2)
    denominator = (
        (mu_candidate * mu_candidate + mu_target * mu_target + c1)
        * (variance_candidate + variance_target + c2)
    )
    ssim = float(numpy.mean(numerator / denominator, dtype=numpy.float64))
    lpips_value = lpips_distance(candidate, target)
    if (
        isinstance(lpips_value, bool)
        or not isinstance(lpips_value, (int, float))
        or not math.isfinite(lpips_value)
        or lpips_value < 0
    ):
        raise EvidenceError("LPIPS scorer returned an invalid value")
    return float(psnr), min(1.0, max(0.0, ssim)), float(lpips_value)


_LPIPS_MODEL: tuple[Any, Any] | None = None
LPIPS_DISTANCE_OVERRIDE: Any | None = None
LPIPS_DEVICE_OVERRIDE: str | None = None


def _verify_lpips_calibration(
    model_state: Mapping[str, Any],
    calibration_state: Mapping[str, Any],
    *,
    tensors_equal: Any,
) -> None:
    if set(calibration_state) != LPIPS_CALIBRATION_HEAD_KEYS:
        raise EvidenceError("the LPIPS calibration linear heads are invalid")
    model_head_keys = {
        key
        for key in model_state
        if re.fullmatch(r"lin\d+\.model\.\d+\.weight", key)
    }
    if model_head_keys != LPIPS_CALIBRATION_HEAD_KEYS:
        raise EvidenceError("the constructed LPIPS linear heads do not match the calibration")
    if any(
        not tensors_equal(model_state[key], calibration_state[key])
        for key in LPIPS_CALIBRATION_HEAD_KEYS
    ):
        raise EvidenceError("the LPIPS calibration weights were not loaded")


def _lpips_distance(candidate: Any, target: Any) -> float:
    global _LPIPS_MODEL
    raw_backbone = os.environ.get("EASYSPLAT_BENCHMARK_LPIPS_BACKBONE")
    if not raw_backbone:
        raise EvidenceError("the pinned LPIPS SqueezeNet backbone is unavailable")
    backbone = Path(raw_backbone)
    try:
        backbone_sha256 = sha256_file(backbone)
    except OSError as error:
        raise EvidenceError("the pinned LPIPS SqueezeNet backbone is unavailable") from error
    if backbone_sha256 != LPIPS_SQUEEZENET_BACKBONE_SHA256:
        raise EvidenceError("the LPIPS SqueezeNet backbone digest is invalid")
    try:
        import importlib.metadata
        import inspect
        import lpips
        import numpy
        import torch
    except ImportError as error:
        raise EvidenceError(
            "render scoring requires the hash-locked torch, torchvision, and lpips packages"
        ) from error
    for package, expected_version in RENDER_SCORING_PACKAGE_VERSIONS.items():
        if importlib.metadata.version(package) != expected_version:
            raise EvidenceError(f"render scoring package {package} is not the pinned version")
    if _LPIPS_MODEL is None:
        calibration = (
            Path(inspect.getfile(lpips.LPIPS)).resolve().parent
            / "weights"
            / "v0.1"
            / "squeeze.pth"
        )
        if sha256_file(calibration) != LPIPS_SQUEEZENET_CALIBRATION_SHA256:
            raise EvidenceError("the LPIPS calibration digest is invalid")
        try:
            calibration_state = torch.load(
                calibration,
                map_location="cpu",
                weights_only=True,
            )
        except (OSError, RuntimeError, TypeError, ValueError) as error:
            raise EvidenceError("the LPIPS calibration could not be loaded safely") from error
        if not isinstance(calibration_state, Mapping):
            raise EvidenceError("the LPIPS calibration is invalid")
        with tempfile.TemporaryDirectory() as directory:
            checkpoint_root = Path(directory) / "hub" / "checkpoints"
            checkpoint_root.mkdir(parents=True)
            shutil.copy2(backbone, checkpoint_root / "squeezenet1_1-b8a52dc0.pth")
            previous_torch_home = os.environ.get("TORCH_HOME")
            original_download = torch.hub.download_url_to_file

            def reject_download(*_args: Any, **_kwargs: Any) -> None:
                raise EvidenceError("LPIPS attempted an unapproved weight download")

            os.environ["TORCH_HOME"] = directory
            torch.hub.download_url_to_file = reject_download
            try:
                model = lpips.LPIPS(
                    net="squeeze",
                    version="0.1",
                    lpips=True,
                    spatial=False,
                    use_dropout=True,
                    eval_mode=True,
                    verbose=False,
                )
            finally:
                torch.hub.download_url_to_file = original_download
                if previous_torch_home is None:
                    os.environ.pop("TORCH_HOME", None)
                else:
                    os.environ["TORCH_HOME"] = previous_torch_home
        _verify_lpips_calibration(
            model.state_dict(),
            calibration_state,
            tensors_equal=torch.equal,
        )
        device_name = LPIPS_DEVICE_OVERRIDE or (
            "mps" if torch.backends.mps.is_available() else "cpu"
        )
        if device_name not in {"cpu", "mps"}:
            raise EvidenceError("the LPIPS scoring device is invalid")
        if device_name == "mps" and not torch.backends.mps.is_available():
            raise EvidenceError("the requested LPIPS MPS device is unavailable")
        device = torch.device(device_name)
        model = model.to(device).eval()
        _LPIPS_MODEL = (model, device)
    model, device = _LPIPS_MODEL
    candidate_tensor = torch.from_numpy(
        numpy.ascontiguousarray(candidate.transpose(2, 0, 1))
    ).unsqueeze(0).to(device)
    target_tensor = torch.from_numpy(
        numpy.ascontiguousarray(target.transpose(2, 0, 1))
    ).unsqueeze(0).to(device)
    with torch.inference_mode():
        value = model(candidate_tensor, target_tensor, normalize=True)
    return float(value.detach().to("cpu").item())


def _validate_ground_truth_preparation(
    *,
    artifact_root: Path,
    preparation_path: Path,
    expected_sha256: str,
    expected_input_digest: str,
    expected_selection_sha256: str,
    holdout_indices: list[int],
) -> tuple[dict[int, Mapping[str, Any]], dict[str, dict[str, Any]]]:
    descriptor = _artifact_descriptor(preparation_path, artifact_root)
    _digest(expected_sha256, "ground-truth preparation digest")
    if descriptor["sha256"] != expected_sha256:
        raise EvidenceError("ground-truth preparation does not match its pinned digest")
    preparation = _mapping(
        _load_bounded_json(preparation_path, "ground-truth preparation"),
        "ground-truth preparation",
    )
    _exact_keys(
        preparation,
        {
            "schema_version",
            "input_digest",
            "selection_manifest",
            "source_spec",
            "algorithm",
            "producer",
            "native_decoder",
            "views",
        },
        "ground-truth preparation",
    )
    if preparation["schema_version"] != 2:
        raise EvidenceError("ground-truth preparation schema is unsupported")
    _digest(expected_input_digest, "expected ground-truth input digest")
    if preparation["input_digest"] != expected_input_digest:
        raise EvidenceError("ground-truth preparation input digest is invalid")

    selection = _mapping(
        preparation["selection_manifest"],
        "ground-truth preparation.selection_manifest",
    )
    _exact_keys(
        selection,
        {"path", "sha256"},
        "ground-truth preparation.selection_manifest",
    )
    if selection["path"] != "selection-manifest.json":
        raise EvidenceError("ground-truth preparation selection path is invalid")
    _digest(expected_selection_sha256, "expected selection manifest digest")
    if selection["sha256"] != expected_selection_sha256:
        raise EvidenceError("ground-truth preparation selection digest is invalid")
    selection_descriptor = _artifact_descriptor(
        artifact_root / selection["path"], artifact_root
    )
    if selection_descriptor["sha256"] != expected_selection_sha256:
        raise EvidenceError("ground-truth preparation selection file is invalid")

    source_spec = _mapping(
        preparation["source_spec"],
        "ground-truth preparation.source_spec",
    )
    _exact_keys(source_spec, {"path", "sha256"}, "ground-truth preparation.source_spec")
    if source_spec["path"] != "render-target-spec.json":
        raise EvidenceError("ground-truth preparation source spec path is invalid")
    _digest(source_spec["sha256"], "ground-truth preparation source spec digest")
    algorithm = _mapping(preparation["algorithm"], "ground-truth preparation.algorithm")
    expected_algorithm = {
        "id": "native_msplat_decode_brown_conrady_alpha0",
        "version": 2,
        "float_precision": "float32",
        "inverse_iterations": 20,
        "boundary_samples": 200,
        "interpolation": "bilinear",
        "boundary_mode": "clamp",
    }
    if algorithm != expected_algorithm:
        raise EvidenceError("ground-truth preparation algorithm is unsupported")
    producer = _mapping(preparation["producer"], "ground-truth preparation.producer")
    _exact_keys(
        producer,
        {"path", "sha256", "runtime"},
        "ground-truth preparation.producer",
    )
    if producer["path"] != "scripts/benchmark/prepare_render_targets.py":
        raise EvidenceError("ground-truth preparation producer is invalid")
    _digest(producer["sha256"], "ground-truth preparation producer digest")
    producer_runtime = _mapping(
        producer["runtime"],
        "ground-truth preparation.producer.runtime",
    )
    _exact_keys(
        producer_runtime,
        {"implementation", "python_version", "numpy_version", "pillow_version"},
        "ground-truth preparation.producer.runtime",
    )
    if any(
        not isinstance(producer_runtime[field], str) or not producer_runtime[field]
        for field in producer_runtime
    ):
        raise EvidenceError("ground-truth preparation producer runtime is invalid")
    producer_path = Path(__file__).resolve().parents[2] / producer["path"]
    if sha256_file(producer_path) != producer["sha256"]:
        raise EvidenceError("ground-truth preparation producer digest is not current")

    native_decoder = _mapping(
        preparation["native_decoder"],
        "ground-truth preparation.native_decoder",
    )
    _exact_keys(
        native_decoder,
        {
            "contract",
            "mode_version",
            "executable_bytes",
            "executable_sha256",
            "metallib_bytes",
            "metallib_sha256",
            "trainer_build_digest",
            "msplat_source_commit",
        },
        "ground-truth preparation.native_decoder",
    )
    if (
        native_decoder["contract"] != "native_coregraphics_imageio_rgb8_v1"
        or native_decoder["mode_version"] != 1
        or native_decoder["msplat_source_commit"]
        != "106499b0a53f82b0c92d013b0861fbebd341b17e"
    ):
        raise EvidenceError("ground-truth preparation native decoder is unsupported")
    for field in ("executable_sha256", "metallib_sha256", "trainer_build_digest"):
        _digest(native_decoder[field], f"ground-truth preparation.native_decoder.{field}")
    for field in ("executable_bytes", "metallib_bytes"):
        if type(native_decoder[field]) is not int or native_decoder[field] <= 0:
            raise EvidenceError(
                f"ground-truth preparation.native_decoder.{field} is invalid"
            )

    raw_views = preparation["views"]
    if not isinstance(raw_views, list) or len(raw_views) != len(holdout_indices):
        raise EvidenceError("ground-truth preparation must cover every bound holdout")

    artifacts = {
        "ground_truth_preparation": descriptor,
        "selection_manifest": selection_descriptor,
    }
    records: dict[int, Mapping[str, Any]] = {}
    paths: set[PurePosixPath] = set()
    for position, (raw_view, holdout_index) in enumerate(
        zip(raw_views, holdout_indices, strict=True)
    ):
        label = f"ground-truth preparation.views[{position}]"
        view = _mapping(raw_view, label)
        _exact_keys(
            view,
            {
                "holdout_index",
                "source",
                "source_camera",
                "transform",
                "target",
                "target_camera",
                "render_camera_digest",
                "preparation_view_sha256",
            },
            label,
        )
        if view["holdout_index"] != holdout_index:
            raise EvidenceError("ground-truth preparation views are not in holdout order")
        unsigned_view = dict(view)
        supplied_view_digest = unsigned_view.pop("preparation_view_sha256")
        _digest(supplied_view_digest, f"{label}.preparation_view_sha256")
        if sha256_bytes(canonical_json_bytes(unsigned_view)) != supplied_view_digest:
            raise EvidenceError("ground-truth preparation view digest is invalid")
        _digest(view["render_camera_digest"], f"{label}.render_camera_digest")
        image_records: dict[str, Mapping[str, Any]] = {}
        for kind in ("source", "target"):
            image = _mapping(view[kind], f"{label}.{kind}")
            image_fields = {
                "path",
                "sha256",
                "pixel_sha256",
                "format",
                "width",
                "height",
            }
            if kind == "source":
                image_fields.update(
                    {
                        "native_decode_receipt_sha256",
                        "native_decoded_rgb8_sha256",
                    }
                )
            _exact_keys(
                image,
                image_fields,
                f"{label}.{kind}",
            )
            path = _render_relative_path(image["path"], f"{label}.{kind}.path")
            if path in paths:
                raise EvidenceError("ground-truth preparation image paths must be unique")
            paths.add(path)
            _digest(image["sha256"], f"{label}.{kind}.sha256")
            _digest(image["pixel_sha256"], f"{label}.{kind}.pixel_sha256")
            if kind == "source":
                _digest(
                    image["native_decode_receipt_sha256"],
                    f"{label}.source.native_decode_receipt_sha256",
                )
                _digest(
                    image["native_decoded_rgb8_sha256"],
                    f"{label}.source.native_decoded_rgb8_sha256",
                )
                if image["native_decoded_rgb8_sha256"] != image["pixel_sha256"]:
                    raise EvidenceError(
                        f"{label}.source native decoded pixels are inconsistent"
                    )
            if image["format"] not in {"png_rgb8", "jpeg_rgb8"}:
                raise EvidenceError(f"{label}.{kind}.format is unsupported")
            if kind == "target" and image["format"] != "png_rgb8":
                raise EvidenceError(f"{label}.target must be png_rgb8")
            if (
                type(image["width"]) is not int
                or type(image["height"]) is not int
                or not 1 <= image["width"] <= 16_384
                or not 1 <= image["height"] <= 16_384
                or image["width"] * image["height"] > 4_194_304
            ):
                raise EvidenceError(f"{label}.{kind} dimensions are invalid")
            file_descriptor = _artifact_descriptor(
                artifact_root / Path(*path.parts), artifact_root
            )
            if file_descriptor["sha256"] != image["sha256"]:
                raise EvidenceError(f"{label}.{kind} digest does not match its file")
            if kind == "source":
                artifacts[f"render_source_{holdout_index:06d}"] = file_descriptor
            image_records[kind] = image

        def camera_record(kind: str) -> Mapping[str, Any]:
            camera = _mapping(view[kind], f"{label}.{kind}")
            _exact_keys(camera, {"model", "width", "height", "parameters"}, f"{label}.{kind}")
            model = camera["model"]
            expected_parameter_count = {
                "PINHOLE": 4,
                "SIMPLE_PINHOLE": 3,
                "SIMPLE_RADIAL": 4,
            }.get(model)
            parameters = camera["parameters"]
            if (
                expected_parameter_count is None
                or not isinstance(parameters, list)
                or len(parameters) != expected_parameter_count
                or any(
                    isinstance(value, bool)
                    or not isinstance(value, (int, float))
                    or not math.isfinite(value)
                    for value in parameters
                )
                or camera["width"] != image_records["source" if kind == "source_camera" else "target"]["width"]
                or camera["height"] != image_records["source" if kind == "source_camera" else "target"]["height"]
            ):
                raise EvidenceError(f"{label}.{kind} is invalid")
            return camera

        source_camera = camera_record("source_camera")
        target_camera = camera_record("target_camera")
        if target_camera["model"] != "PINHOLE":
            raise EvidenceError("ground-truth preparation target camera must be PINHOLE")
        transform = _mapping(view["transform"], f"{label}.transform")
        _exact_keys(transform, {"kind", "roi"}, f"{label}.transform")
        roi = transform["roi"]
        if (
            transform["kind"] not in {"identity", "brown_conrady_alpha0"}
            or not isinstance(roi, list)
            or len(roi) != 4
            or any(type(value) is not int for value in roi)
        ):
            raise EvidenceError(f"{label}.transform is invalid")
        roi_x, roi_y, roi_width, roi_height = roi
        if (
            roi_x < 0
            or roi_y < 0
            or roi_width <= 0
            or roi_height <= 0
            or roi_x + roi_width > source_camera["width"]
            or roi_y + roi_height > source_camera["height"]
            or target_camera["width"] != roi_width
            or target_camera["height"] != roi_height
        ):
            raise EvidenceError(f"{label}.transform ROI is invalid")
        radial_is_nonzero_float32 = False
        if source_camera["model"] == "SIMPLE_RADIAL":
            try:
                radial_bits = struct.unpack(
                    ">I", struct.pack(">f", source_camera["parameters"][3])
                )[0]
            except (OverflowError, struct.error) as error:
                raise EvidenceError(f"{label}.source radial coefficient is outside Float32") from error
            radial_is_nonzero_float32 = radial_bits & 0x7FFF_FFFF != 0
        if transform["kind"] == "identity" and (
            radial_is_nonzero_float32
            or roi != [0, 0, source_camera["width"], source_camera["height"]]
        ):
            raise EvidenceError(f"{label}.identity transform is invalid")
        if transform["kind"] == "brown_conrady_alpha0" and (
            source_camera["model"] != "SIMPLE_RADIAL" or not radial_is_nonzero_float32
        ):
            raise EvidenceError(f"{label}.distortion transform is invalid")
        source_parameters = source_camera["parameters"]
        if source_camera["model"] == "PINHOLE":
            fx, fy, cx, cy = source_parameters
        else:
            fx = fy = source_parameters[0]
            cx, cy = source_parameters[1:3]
        expected_target_parameters = [fx, fy, cx - roi_x, cy - roi_y]
        if any(
            not math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-12)
            for actual, expected in zip(
                target_camera["parameters"],
                expected_target_parameters,
                strict=True,
            )
        ):
            raise EvidenceError(
                f"{label}.target camera intrinsics do not match the transform"
            )
        records[holdout_index] = view
    return records, artifacts


def validate_and_score_rendering(
    *,
    artifact_root: Path,
    manifest_path: Path,
    reference_path: Path,
    preparation_path: Path,
    request: Mapping[str, Any],
    commands: Any,
    renderer_executable_sha256: str,
    lpips_distance: Any = None,
) -> RenderingEvidence:
    if lpips_distance is None:
        lpips_distance = LPIPS_DISTANCE_OVERRIDE or _lpips_distance
    manifest = _mapping(_load_bounded_json(manifest_path, "rendering manifest"), "rendering manifest")
    _exact_keys(
        manifest,
        {
            "schema_version",
            "scene_id",
            "scale",
            "request_digest",
            "input_digest",
            "holdout_indices",
            "training_view_indices",
            "color_space",
            "pixel_format",
            "renderer_closure_sha256",
            "renderer_executable_sha256",
            "ground_truth_preparation_sha256",
            "render_operations",
            "views",
        },
        "rendering manifest",
    )
    binding = _mapping(request.get("binding"), "request.binding")
    holdouts = request.get("holdout_indices")
    request_preparation_sha256 = request["reference_artifacts"][
        "ground_truth_preparation_sha256"
    ]
    _digest(request_preparation_sha256, "request ground-truth preparation digest")
    if manifest["ground_truth_preparation_sha256"] != request_preparation_sha256:
        raise EvidenceError(
            "rendering manifest ground-truth preparation does not match the request"
        )
    if (
        manifest["schema_version"] != 2
        or manifest["scene_id"] != binding.get("scene_id")
        or manifest["scale"] != binding.get("scale")
        or manifest["input_digest"] != binding.get("input_digest")
        or manifest["request_digest"]
        != sha256_bytes(canonical_json_bytes(request) + b"\n")
        or manifest["holdout_indices"] != holdouts
        or manifest["color_space"] != "srgb"
        or manifest["pixel_format"] != "png_rgb8"
        or manifest["renderer_closure_sha256"]
        != request["rendering_driver_identity"]["sha256"]
        or manifest["renderer_executable_sha256"] != renderer_executable_sha256
    ):
        raise EvidenceError("rendering manifest does not match its bound request")
    _digest(renderer_executable_sha256, "approved renderer executable digest")
    scale = binding.get("scale")
    if type(scale) is not int or not isinstance(holdouts, list):
        raise EvidenceError("rendering request scale or holdouts are invalid")
    expected_training = [index for index in range(scale) if index not in set(holdouts)]
    if manifest["training_view_indices"] != expected_training:
        raise EvidenceError("held-out views must be excluded from the training selection")

    preparation_records, preparation_artifacts = _validate_ground_truth_preparation(
        artifact_root=artifact_root,
        preparation_path=preparation_path,
        expected_sha256=request_preparation_sha256,
        expected_input_digest=binding["input_digest"],
        expected_selection_sha256=request["reference_artifacts"][
            "selection_manifest_sha256"
        ],
        holdout_indices=holdouts,
    )
    reference = _mapping(
        _load_bounded_json(reference_path, "accurate rendering reference"),
        "accurate rendering reference",
    )
    _exact_keys(
        reference,
        {"schema_version", "ground_truth_preparation_sha256", "views"},
        "accurate rendering reference",
    )
    if reference["schema_version"] != 2:
        raise EvidenceError("accurate rendering reference schema is unsupported")
    if reference["ground_truth_preparation_sha256"] != request_preparation_sha256:
        raise EvidenceError(
            "accurate rendering reference ground-truth preparation does not match the request"
        )
    reference_views = reference["views"]
    views = manifest["views"]
    if (
        not isinstance(views, list)
        or not isinstance(reference_views, list)
        or len(views) != len(holdouts)
        or len(reference_views) != len(holdouts)
    ):
        raise EvidenceError("rendering views must cover every bound holdout")

    source_specs = {
        "accurate_reference": ("fast_profile", "accurate_reference"),
        "paired_baseline": ("ordinary", "baseline"),
        "candidate_balanced": ("ordinary", "candidate"),
        "candidate_fast": ("fast_profile", "fast_candidate"),
    }
    selected_sources = select_render_source_receipts(commands, source_specs)
    render_operations = manifest["render_operations"]
    expected_render_operation_count = len(holdouts) * len(RENDER_VARIANTS)
    if not isinstance(render_operations, list) or len(render_operations) != expected_render_operation_count:
        raise EvidenceError("render operations must cover every holdout and variant")
    render_operation_fields = {
        "operation_id",
        "holdout_index",
        "variant",
        "renderer_executable_sha256",
        "source_run_id",
        "source_checkout_commit",
        "source_toolchain_identity",
        "source_executable_sha256",
        "input_ply_sha256",
        "camera_digest",
        "output_sha256",
        "started_monotonic_seconds",
        "ended_monotonic_seconds",
        "status",
    }
    render_operations_by_key: dict[tuple[int, str], Mapping[str, Any]] = {}
    previous_render_end = -math.inf
    expected_operation_order = [
        (holdout_index, variant)
        for variant in RENDER_VARIANTS
        for holdout_index in holdouts
    ]
    for operation_position, ((holdout_index, variant), raw_operation) in enumerate(
        zip(expected_operation_order, render_operations, strict=True)
    ):
        operation = _mapping(
            raw_operation,
            f"rendering manifest.render_operations[{operation_position}]",
        )
        _exact_keys(
            operation,
            render_operation_fields,
            f"rendering manifest.render_operations[{operation_position}]",
        )
        started = operation["started_monotonic_seconds"]
        ended = operation["ended_monotonic_seconds"]
        if (
            operation["holdout_index"] != holdout_index
            or operation["variant"] != variant
            or operation["renderer_executable_sha256"] != renderer_executable_sha256
            or operation["status"] != "completed"
            or isinstance(started, bool)
            or isinstance(ended, bool)
            or not isinstance(started, (int, float))
            or not isinstance(ended, (int, float))
            or not math.isfinite(started)
            or not math.isfinite(ended)
            or started < previous_render_end
            or ended <= started
        ):
            raise EvidenceError("render operations are not in canonical source-major order")
        previous_render_end = float(ended)
        render_operations_by_key[(holdout_index, variant)] = operation

    artifacts = {
        "rendering_manifest": _artifact_descriptor(manifest_path, artifact_root),
        **preparation_artifacts,
    }
    image_paths: set[PurePosixPath] = set()
    balanced: list[dict[str, float | int]] = []
    fast: list[dict[str, float | int]] = []
    for position, holdout_index in enumerate(holdouts):
        view = _mapping(views[position], f"rendering manifest.views[{position}]")
        reference_view = _mapping(
            reference_views[position],
            f"accurate rendering reference.views[{position}]",
        )
        view_fields = {"holdout_index", "camera", "camera_digest", "ground_truth", "renders"}
        reference_fields = {
            "holdout_index",
            "camera",
            "camera_digest",
            "ground_truth_sha256",
            "preparation_view_sha256",
        }
        _exact_keys(view, view_fields, f"rendering manifest.views[{position}]")
        _exact_keys(
            reference_view,
            reference_fields,
            f"accurate rendering reference.views[{position}]",
        )
        if view["holdout_index"] != holdout_index or reference_view["holdout_index"] != holdout_index:
            raise EvidenceError("rendering views must be ordered by bound holdout index")
        camera = _render_camera(view["camera"], f"rendering manifest.views[{position}].camera")
        reference_camera = _render_camera(
            reference_view["camera"],
            f"accurate rendering reference.views[{position}].camera",
        )
        camera_digest = render_camera_digest(camera)
        preparation_view = preparation_records[holdout_index]
        target_camera = preparation_view["target_camera"]
        fx, fy, cx, cy = target_camera["parameters"]
        expected_projection = {
            0: 2.0 * fx / camera["width"],
            5: 2.0 * fy / camera["height"],
            8: 1.0 - 2.0 * cx / camera["width"],
            9: 2.0 * cy / camera["height"] - 1.0,
        }
        projection = camera["projection_matrix_column_major"]
        if (
            camera != reference_camera
            or view["camera_digest"] != camera_digest
            or reference_view["camera_digest"] != camera_digest
            or preparation_view["render_camera_digest"] != camera_digest
            or reference_view["preparation_view_sha256"]
            != preparation_view["preparation_view_sha256"]
        ):
            raise EvidenceError("render camera does not match the pinned holdout camera")
        if any(
            not math.isclose(projection[index], expected, rel_tol=1e-6, abs_tol=1e-6)
            for index, expected in expected_projection.items()
        ):
            raise EvidenceError(
                "render camera intrinsics do not match the prepared ground truth"
            )

        ground_truth = _mapping(
            view["ground_truth"],
            f"rendering manifest.views[{position}].ground_truth",
        )
        _exact_keys(
            ground_truth,
            {
                "path",
                "sha256",
                "source_path",
                "source_sha256",
                "preparation_view_sha256",
                "input_digest",
            },
            f"rendering manifest.views[{position}].ground_truth",
        )
        if ground_truth["input_digest"] != binding["input_digest"]:
            raise EvidenceError("ground-truth image is not bound to the requested input")
        if (
            ground_truth["path"] != preparation_view["target"]["path"]
            or ground_truth["sha256"] != preparation_view["target"]["sha256"]
            or ground_truth["source_path"] != preparation_view["source"]["path"]
            or ground_truth["source_sha256"] != preparation_view["source"]["sha256"]
            or ground_truth["preparation_view_sha256"]
            != preparation_view["preparation_view_sha256"]
        ):
            raise EvidenceError("ground-truth image does not match its preparation receipt")
        ground_truth_relative = _render_relative_path(
            ground_truth["path"],
            f"rendering manifest.views[{position}].ground_truth.path",
        )
        if ground_truth_relative in image_paths:
            raise EvidenceError("rendering image paths must be unique")
        image_paths.add(ground_truth_relative)
        _digest(ground_truth["sha256"], "ground-truth image digest")
        if ground_truth["sha256"] != reference_view["ground_truth_sha256"]:
            raise EvidenceError("ground-truth image digest does not match its pinned reference")
        ground_truth_pixels, ground_truth_descriptor = _load_render_image(
            artifact_root=artifact_root,
            relative_path=ground_truth_relative,
            expected_sha256=ground_truth["sha256"],
            expected_width=camera["width"],
            expected_height=camera["height"],
            label=f"ground-truth image {holdout_index}",
        )
        artifacts[f"render_ground_truth_{holdout_index:06d}"] = ground_truth_descriptor

        render_records = view["renders"]
        if not isinstance(render_records, list) or len(render_records) != len(RENDER_VARIANTS):
            raise EvidenceError("rendering variants are incomplete")
        measured: dict[str, tuple[float, float, float]] = {}
        for variant_position, variant in enumerate(RENDER_VARIANTS):
            render = _mapping(
                render_records[variant_position],
                f"rendering manifest.views[{position}].renders[{variant_position}]",
            )
            _exact_keys(
                render,
                {
                    "variant",
                    "path",
                    "sha256",
                    "camera_digest",
                    "source_run_id",
                    "ply_sha256",
                    "renderer",
                    "renderer_executable_sha256",
                    "render_operation_id",
                },
                f"rendering manifest.views[{position}].renders[{variant_position}]",
            )
            render_operation = render_operations_by_key[(holdout_index, variant)]
            source = selected_sources[variant]
            if (
                render["source_run_id"] != source.get("run_id")
                or render_operation["source_run_id"] != source.get("run_id")
            ):
                if variant == "candidate_balanced":
                    raise EvidenceError(
                        "candidate_balanced must bind the sole published output receipt"
                    )
                raise EvidenceError(
                    f"{variant} must bind one source execution receipt across all holdouts"
                )
            if (
                render["variant"] != variant
                or render["camera_digest"] != camera_digest
                or render["source_run_id"] != source.get("run_id")
                or render["ply_sha256"] != source.get("output_sha256")
                or render["renderer"] != "MetalSplatter"
                or render["renderer_executable_sha256"] != renderer_executable_sha256
            ):
                raise EvidenceError(f"{variant} render is not bound to its camera and source PLY")
            render_relative = _render_relative_path(
                render["path"],
                f"rendering manifest.views[{position}].renders[{variant_position}].path",
            )
            if render_relative in image_paths:
                raise EvidenceError("rendering image paths must be unique")
            image_paths.add(render_relative)
            _digest(render["sha256"], f"{variant} render digest")
            pixels, descriptor = _load_render_image(
                artifact_root=artifact_root,
                relative_path=render_relative,
                expected_sha256=render["sha256"],
                expected_width=camera["width"],
                expected_height=camera["height"],
                label=f"{variant} render {holdout_index}",
            )
            if (
                render_operation["operation_id"] != render["render_operation_id"]
                or render_operation["holdout_index"] != holdout_index
                or render_operation["variant"] != variant
                or render_operation["renderer_executable_sha256"] != renderer_executable_sha256
                or render_operation["source_run_id"] != source.get("run_id")
                or render_operation["source_checkout_commit"] != source.get("checkout_commit")
                or render_operation["source_toolchain_identity"] != source.get("toolchain_identity")
                or render_operation["source_executable_sha256"] != source.get("executable_sha256")
                or render_operation["input_ply_sha256"] != source.get("output_sha256")
                or render_operation["camera_digest"] != camera_digest
                or render_operation["output_sha256"] != descriptor["sha256"]
            ):
                raise EvidenceError(f"{variant} render operation receipt is invalid")
            artifacts[f"render_{variant}_{holdout_index:06d}"] = descriptor
            measured[variant] = _pixel_metrics(pixels, ground_truth_pixels, lpips_distance)

        reference_metrics = measured["accurate_reference"]
        baseline_metrics = measured["paired_baseline"]
        candidate_metrics = measured["candidate_balanced"]
        fast_metrics = measured["candidate_fast"]
        balanced.append(
            {
                "holdout_index": holdout_index,
                "candidate_psnr": candidate_metrics[0],
                "reference_psnr": reference_metrics[0],
                "candidate_ssim": candidate_metrics[1],
                "reference_ssim": reference_metrics[1],
                "candidate_lpips": candidate_metrics[2],
                "reference_lpips": reference_metrics[2],
                "baseline_psnr": baseline_metrics[0],
                "baseline_ssim": baseline_metrics[1],
                "baseline_lpips": baseline_metrics[2],
            }
        )
        fast.append(
            {
                "holdout_index": holdout_index,
                "candidate_psnr": fast_metrics[0],
                "reference_psnr": reference_metrics[0],
                "candidate_ssim": fast_metrics[1],
                "reference_ssim": reference_metrics[1],
                "candidate_lpips": fast_metrics[2],
                "reference_lpips": reference_metrics[2],
            }
        )
    return RenderingEvidence(balanced=balanced, fast=fast, artifacts=artifacts)


def select_render_source_receipts(
    commands: Any,
    source_specs: Mapping[str, tuple[str, str]] | None = None,
) -> dict[str, Mapping[str, Any]]:
    """Choose one image-independent execution receipt for every rendered variant."""
    if not isinstance(commands, list):
        raise EvidenceError("rendering source receipts are unavailable")
    if source_specs is None:
        source_specs = {
            "accurate_reference": ("fast_profile", "accurate_reference"),
            "paired_baseline": ("ordinary", "baseline"),
            "candidate_balanced": ("ordinary", "candidate"),
            "candidate_fast": ("fast_profile", "fast_candidate"),
        }
    receipts = [
        _mapping(command, f"rendering source receipt[{index}]")
        for index, command in enumerate(commands)
    ]
    published = [receipt for receipt in receipts if receipt.get("published_output") is True]
    if len(published) != 1:
        raise EvidenceError("candidate_balanced must bind the sole published output receipt")

    selected: dict[str, Mapping[str, Any]] = {}
    for render_variant, (phase, execution_variant) in source_specs.items():
        matching = [
            receipt
            for receipt in receipts
            if receipt.get("phase") == phase and receipt.get("variant") == execution_variant
        ]
        if not matching:
            raise EvidenceError(f"{render_variant} source execution receipt is unavailable")
        if render_variant == "candidate_balanced":
            source = published[0]
            if source not in matching:
                raise EvidenceError("candidate_balanced must bind the sole published output receipt")
        else:
            # Execution receipts are already validated against their bound timing
            # order. The final receipt is therefore deterministic and independent
            # of any rendered image or quality score.
            source = matching[-1]
        selected[render_variant] = source
    return selected


def _validate_splat_ply(path: Path) -> int:
    scalar_types = {
        "char": ("b", False),
        "int8": ("b", False),
        "uchar": ("B", False),
        "uint8": ("B", False),
        "short": ("h", False),
        "int16": ("h", False),
        "ushort": ("H", False),
        "uint16": ("H", False),
        "int": ("i", False),
        "int32": ("i", False),
        "uint": ("I", False),
        "uint32": ("I", False),
        "float": ("f", True),
        "float32": ("f", True),
        "double": ("d", True),
        "float64": ("d", True),
    }
    required_properties = {
        "x",
        "y",
        "z",
        "f_dc_0",
        "f_dc_1",
        "f_dc_2",
        "opacity",
        "scale_0",
        "scale_1",
        "scale_2",
        "rot_0",
        "rot_1",
        "rot_2",
        "rot_3",
    }
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if handle.readline() not in {b"ply\n", b"ply\r\n"}:
                raise EvidenceError("output_ply is not a PLY file")
            header_bytes = handle.tell()
            format_name: str | None = None
            vertex_count: int | None = None
            vertex_properties: list[tuple[str, str]] = []
            active_element: str | None = None
            other_element_count = 0
            while True:
                raw_line = handle.readline()
                if not raw_line:
                    raise EvidenceError("output_ply is missing end_header")
                header_bytes += len(raw_line)
                if header_bytes > 64 * 1024:
                    raise EvidenceError("output_ply header exceeds 64 KiB")
                try:
                    line = raw_line.decode("ascii").strip()
                except UnicodeDecodeError as error:
                    raise EvidenceError("output_ply header is not ASCII") from error
                if line == "end_header":
                    break
                if not line or line.startswith(("comment ", "obj_info ")):
                    continue
                fields = line.split()
                if fields[0] == "format":
                    if len(fields) != 3 or fields[2] != "1.0" or format_name is not None:
                        raise EvidenceError("output_ply format declaration is invalid")
                    format_name = fields[1]
                elif fields[0] == "element":
                    if len(fields) != 3:
                        raise EvidenceError("output_ply element declaration is invalid")
                    try:
                        count = int(fields[2])
                    except ValueError as error:
                        raise EvidenceError("output_ply element count is invalid") from error
                    if count < 0:
                        raise EvidenceError("output_ply element count is invalid")
                    active_element = fields[1]
                    if active_element == "vertex":
                        if vertex_count is not None:
                            raise EvidenceError("output_ply declares vertex more than once")
                        vertex_count = count
                    else:
                        other_element_count += count
                elif fields[0] == "property":
                    if active_element != "vertex":
                        continue
                    if len(fields) != 3 or fields[1] == "list":
                        raise EvidenceError("output_ply has an unsupported vertex property")
                    property_type = fields[1].lower()
                    property_name = fields[2].lower()
                    if property_type not in scalar_types or any(
                        name == property_name for name, _ in vertex_properties
                    ):
                        raise EvidenceError("output_ply has an invalid vertex property")
                    vertex_properties.append((property_name, property_type))
                else:
                    raise EvidenceError("output_ply header contains an unsupported declaration")

            body_offset = handle.tell()
            if format_name not in {"ascii", "binary_little_endian"}:
                raise EvidenceError("output_ply format is unsupported")
            if vertex_count is None or vertex_count <= 0:
                raise EvidenceError("output_ply must contain at least one splat")
            if other_element_count != 0:
                raise EvidenceError("output_ply must contain only Gaussian vertices")
            property_names = {name for name, _ in vertex_properties}
            missing = sorted(required_properties - property_names)
            if missing:
                raise EvidenceError("output_ply is missing Gaussian properties: " + ", ".join(missing))

            if format_name == "ascii":
                try:
                    body = handle.read().decode("ascii")
                except UnicodeDecodeError as error:
                    raise EvidenceError("output_ply ASCII body is invalid") from error
                rows = [line for line in body.splitlines() if line.strip()]
                if len(rows) != vertex_count:
                    raise EvidenceError("output_ply ASCII vertex count does not match its body")
                for row in rows:
                    values = row.split()
                    if len(values) != len(vertex_properties):
                        raise EvidenceError("output_ply ASCII vertex stride is invalid")
                    for value, (_, property_type) in zip(values, vertex_properties, strict=True):
                        code, is_float = scalar_types[property_type]
                        try:
                            number = float(value) if is_float else int(value, 10)
                        except ValueError as error:
                            raise EvidenceError("output_ply contains an invalid numeric value") from error
                        if is_float and not math.isfinite(number):
                            raise EvidenceError("output_ply contains a nonfinite value")
                        if not is_float:
                            try:
                                struct.pack("<" + code, number)
                            except struct.error as error:
                                raise EvidenceError("output_ply integer value is out of range") from error
            else:
                record = struct.Struct("<" + "".join(scalar_types[kind][0] for _, kind in vertex_properties))
                expected_size = body_offset + record.size * vertex_count
                if size != expected_size:
                    raise EvidenceError("output_ply binary payload size does not match its header")
                floating_indices = [
                    index
                    for index, (_, kind) in enumerate(vertex_properties)
                    if scalar_types[kind][1]
                ]
                with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                    body = memoryview(mapped)[body_offset:]
                    try:
                        for values in record.iter_unpack(body):
                            if any(not math.isfinite(values[index]) for index in floating_indices):
                                raise EvidenceError("output_ply contains a nonfinite value")
                    finally:
                        body.release()
    except OSError as error:
        raise EvidenceError("output_ply could not be read") from error
    return vertex_count


def _validate_training_manifest(
    path: Path,
    output_descriptor: Mapping[str, Any],
    output_splat_count: int,
    pipeline_metrics: Mapping[str, Any],
    candidate_configuration: Mapping[str, Any],
    maximum_training_seconds: float,
) -> None:
    manifest = _mapping(
        _load_bounded_json(path, "training manifest", maximum_bytes=1024 * 1024),
        "training manifest",
    )
    _exact_keys(
        manifest,
        {
            "schemaVersion",
            "trainerVersion",
            "runtimeVersion",
            "trainerBuildDigest",
            "inputDigest",
            "geometryDigest",
            "detailProfile",
            "iterationLimit",
            "plateauWindow",
            "cameraOrderSeed",
            "completedIteration",
            "outputPath",
            "outputSHA256",
            "outputBytes",
            "gaussianCount",
            "elapsedSeconds",
            "peakMemoryBytes",
            "memoryBudgetBytes",
            "rasterFallbackCount",
            "rasterExactFallbackElapsedSeconds",
            "rasterExactBufferGrowthCount",
            "rasterExactBufferBytesAdded",
            "rasterReplayElapsedSeconds",
            "rasterPeakExactIntersectionCapacity",
            "droppedIntersectionCount",
            "sceneBounds",
            "completionStatus",
        },
        "training manifest",
    )
    if manifest["schemaVersion"] != 5 or manifest["completionStatus"] != "completed":
        raise EvidenceError("training manifest is not a completed schema-5 artifact")
    if manifest["runtimeVersion"] != "native-metal-cli-v2":
        raise EvidenceError("training manifest runtime contract is unsupported")
    if (
        not isinstance(manifest["detailProfile"], str)
        or manifest["detailProfile"] not in {"fast", "balanced", "highDetail"}
    ):
        raise EvidenceError("training manifest detail profile is invalid")
    expected_profile = candidate_configuration["detail_profile"]
    if manifest["detailProfile"] != expected_profile:
        raise EvidenceError("training manifest detail profile does not match request")
    requested_contract = {
        "iterationLimit": candidate_configuration["trainer_iterations"],
        "plateauWindow": candidate_configuration["trainer_plateau_window"],
    }
    for name, expected in requested_contract.items():
        if manifest[name] != expected:
            raise EvidenceError(f"training manifest {name} does not match request")
    if manifest["outputPath"] != "Output/splat.ply":
        raise EvidenceError("training manifest output path is not canonical")
    digest = manifest["outputSHA256"]
    if (
        not isinstance(digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", digest)
        or "sha256:" + digest != output_descriptor["sha256"]
    ):
        raise EvidenceError("training manifest output digest does not match output_ply")
    bound_integer_fields = (
        "iterationLimit",
        "plateauWindow",
        "completedIteration",
        "outputBytes",
        "gaussianCount",
        "peakMemoryBytes",
        "memoryBudgetBytes",
        "rasterFallbackCount",
        "rasterExactBufferGrowthCount",
        "rasterExactBufferBytesAdded",
        "rasterPeakExactIntersectionCapacity",
        "droppedIntersectionCount",
    )
    for name in bound_integer_fields:
        if (
            type(manifest[name]) is not int
            or manifest[name] < 0
            or manifest[name] > (1 << 63) - 1
        ):
            raise EvidenceError(f"training manifest {name} must be a nonnegative integer")
    if (
        type(manifest["cameraOrderSeed"]) is not int
        or not 0 <= manifest["cameraOrderSeed"] <= (1 << 64) - 1
    ):
        raise EvidenceError("training manifest cameraOrderSeed is outside UInt64")
    if manifest["cameraOrderSeed"] != candidate_configuration["run_seed"]:
        raise EvidenceError("training manifest cameraOrderSeed does not match request")
    if manifest["iterationLimit"] == 0 or manifest["plateauWindow"] == 0:
        raise EvidenceError("training manifest iteration contract is invalid")
    if not 0 < manifest["completedIteration"] <= manifest["iterationLimit"]:
        raise EvidenceError("training manifest completion iteration is invalid")
    if manifest["outputBytes"] == 0 or manifest["gaussianCount"] == 0:
        raise EvidenceError("training manifest output contract is invalid")
    if manifest["peakMemoryBytes"] == 0 or manifest["memoryBudgetBytes"] == 0:
        raise EvidenceError("training manifest memory contract is invalid")
    if manifest["rasterFallbackCount"] > min(
        manifest["completedIteration"],
        (1 << 32) - 1,
    ):
        raise EvidenceError("training manifest raster fallback count is invalid")
    if manifest["rasterExactBufferGrowthCount"] > manifest["rasterFallbackCount"]:
        raise EvidenceError("training manifest raster growth count is invalid")
    for name in (
        "elapsedSeconds",
        "rasterExactFallbackElapsedSeconds",
        "rasterReplayElapsedSeconds",
    ):
        value = manifest[name]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value < 0
        ):
            raise EvidenceError(f"training manifest {name} must be finite and nonnegative")
    if manifest["rasterPeakExactIntersectionCapacity"] > (1 << 32) - 1:
        raise EvidenceError("training manifest raster peak capacity exceeds UInt32")
    if (
        manifest["rasterExactBufferBytesAdded"]
        > manifest["rasterExactBufferGrowthCount"] * manifest["memoryBudgetBytes"]
    ):
        raise EvidenceError("training manifest raster allocation evidence exceeds its budget")
    if manifest["rasterFallbackCount"] == 0 and any(
        manifest[name] != 0
        for name in (
            "rasterExactFallbackElapsedSeconds",
            "rasterExactBufferGrowthCount",
            "rasterExactBufferBytesAdded",
            "rasterReplayElapsedSeconds",
            "rasterPeakExactIntersectionCapacity",
        )
    ):
        raise EvidenceError("training manifest zero raster fallbacks have recovery evidence")
    if manifest["rasterFallbackCount"] > 0 and (
        manifest["rasterExactFallbackElapsedSeconds"] <= 0
        or manifest["rasterExactBufferGrowthCount"] <= 0
        or manifest["rasterExactBufferBytesAdded"] <= 0
        or manifest["rasterReplayElapsedSeconds"] <= 0
        or manifest["rasterPeakExactIntersectionCapacity"] <= 2_048
    ):
        raise EvidenceError("training manifest raster fallback evidence is incomplete")
    if manifest["rasterExactBufferGrowthCount"] == 0 and (
        manifest["rasterExactBufferBytesAdded"] != 0
        or manifest["rasterPeakExactIntersectionCapacity"] != 0
    ):
        raise EvidenceError("training manifest zero raster growth has allocation evidence")
    if manifest["rasterExactBufferGrowthCount"] > 0 and (
        manifest["rasterExactBufferBytesAdded"] == 0
        or manifest["rasterPeakExactIntersectionCapacity"] <= 2_048
    ):
        raise EvidenceError("training manifest raster growth evidence is invalid")
    if manifest["outputBytes"] != output_descriptor["bytes"]:
        raise EvidenceError("training manifest output size does not match output_ply")
    if manifest["gaussianCount"] != output_splat_count:
        raise EvidenceError("training manifest Gaussian count does not match output_ply")
    if manifest["droppedIntersectionCount"] != 0:
        raise EvidenceError("training manifest reports dropped raster intersections")
    if (
        manifest["rasterExactFallbackElapsedSeconds"] > manifest["elapsedSeconds"]
        or manifest["rasterReplayElapsedSeconds"] > manifest["elapsedSeconds"]
    ):
        raise EvidenceError("training manifest raster elapsed time exceeds training time")
    if manifest["elapsedSeconds"] > maximum_training_seconds + 1e-6:
        raise EvidenceError("training manifest elapsed time exceeds its published timing run")
    for name in ("trainerBuildDigest", "inputDigest", "geometryDigest"):
        digest = manifest[name]
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise EvidenceError(f"training manifest {name} is not a SHA-256 digest")
    for name in ("trainerVersion", "runtimeVersion"):
        if not isinstance(manifest[name], str) or not manifest[name]:
            raise EvidenceError(f"training manifest {name} is invalid")
    bounds = _mapping(manifest["sceneBounds"], "training manifest sceneBounds")
    _exact_keys(bounds, {"center", "radius"}, "training manifest sceneBounds")
    center = _mapping(bounds["center"], "training manifest scene center")
    _exact_keys(center, {"x", "y", "z"}, "training manifest scene center")
    coordinates = [center[axis] for axis in ("x", "y", "z")]
    if any(
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        for value in coordinates
    ):
        raise EvidenceError("training manifest scene center is invalid")
    radius = bounds["radius"]
    if (
        isinstance(radius, bool)
        or not isinstance(radius, (int, float))
        or not math.isfinite(radius)
        or radius <= 0
    ):
        raise EvidenceError("training manifest scene radius is invalid")
    manifest_to_pipeline = {
        "rasterFallbackCount": "raster_fallback_count",
        "rasterExactFallbackElapsedSeconds": "raster_exact_fallback_elapsed_seconds",
        "rasterExactBufferGrowthCount": "raster_exact_buffer_growth_count",
        "rasterExactBufferBytesAdded": "raster_exact_buffer_bytes_added",
        "rasterReplayElapsedSeconds": "raster_replay_elapsed_seconds",
        "rasterPeakExactIntersectionCapacity": "raster_peak_exact_intersection_capacity",
        "droppedIntersectionCount": "dropped_intersection_count",
    }
    for manifest_name, pipeline_name in manifest_to_pipeline.items():
        if manifest[manifest_name] != pipeline_metrics.get(pipeline_name):
            raise EvidenceError(
                f"training manifest {manifest_name} does not match pipeline metrics"
            )


def _load_bounded_json(
    path: Path,
    label: str,
    maximum_bytes: int = MAX_OBSERVATIONS_BYTES,
) -> Any:
    try:
        if path.stat().st_size > maximum_bytes:
            raise EvidenceError(f"{label} exceeds its size limit")
        return _decode_json_text(path.read_text(encoding="utf-8"), label)
    except EvidenceError:
        raise
    except (OSError, UnicodeError, ValueError) as error:
        raise EvidenceError(f"{label} is not valid JSON") from error


def _biconnected_robustness(adjacency: list[set[int]]) -> dict[str, int]:
    """Measure vertex-biconnected edge blocks without recursive DFS."""
    edges: list[tuple[int, int]] = []
    incident_edges: list[list[tuple[int, int]]] = [[] for _ in adjacency]
    for left, neighbors in enumerate(adjacency):
        for right in sorted(neighbors):
            if left >= right:
                continue
            edge_id = len(edges)
            edges.append((left, right))
            incident_edges[left].append((right, edge_id))
            incident_edges[right].append((left, edge_id))
    for incident in incident_edges:
        incident.sort()

    discovery = [-1] * len(adjacency)
    low = [-1] * len(adjacency)
    next_discovery = 0
    articulation_views: set[int] = set()
    edge_stack: list[int] = []
    block_sizes: list[int] = []

    def pop_block(boundary_edge: int | None) -> None:
        vertices: set[int] = set()
        while edge_stack:
            edge_id = edge_stack.pop()
            vertices.update(edges[edge_id])
            if edge_id == boundary_edge:
                block_sizes.append(len(vertices))
                return
        if boundary_edge is not None:
            raise EvidenceError("pair_list verified graph block boundary is corrupt")
        if vertices:
            block_sizes.append(len(vertices))

    # Each frame is [vertex, parent edge, next incident index, DFS child count].
    for root in range(len(adjacency)):
        if discovery[root] >= 0 or not incident_edges[root]:
            continue
        discovery[root] = next_discovery
        low[root] = next_discovery
        next_discovery += 1
        frames = [[root, -1, 0, 0]]
        while frames:
            vertex, parent_edge, next_index, child_count = frames[-1]
            if next_index < len(incident_edges[vertex]):
                neighbor, edge_id = incident_edges[vertex][next_index]
                frames[-1][2] += 1
                if edge_id == parent_edge:
                    continue
                if discovery[neighbor] < 0:
                    frames[-1][3] += 1
                    edge_stack.append(edge_id)
                    discovery[neighbor] = next_discovery
                    low[neighbor] = next_discovery
                    next_discovery += 1
                    frames.append([neighbor, edge_id, 0, 0])
                elif discovery[neighbor] < discovery[vertex]:
                    edge_stack.append(edge_id)
                    low[vertex] = min(low[vertex], discovery[neighbor])
                continue

            frames.pop()
            if parent_edge < 0:
                if child_count > 1:
                    articulation_views.add(vertex)
                pop_block(None)
                continue

            parent = frames[-1][0]
            low[parent] = min(low[parent], low[vertex])
            if low[vertex] >= discovery[parent]:
                if frames[-1][1] >= 0:
                    articulation_views.add(parent)
                pop_block(parent_edge)

    block_sizes.sort(reverse=True)
    return {
        "articulation_views": len(articulation_views),
        "biconnected_blocks": len(block_sizes),
        "largest_biconnected_block_views": block_sizes[0] if block_sizes else 0,
        "second_largest_biconnected_block_views": (
            block_sizes[1] if len(block_sizes) > 1 else 0
        ),
    }


def _validate_pair_list(
    pair_list_path: Path,
    selection_manifest_path: Path,
    requested_scale: int,
    candidate_configuration: Mapping[str, Any],
    pipeline_metrics: Mapping[str, Any],
) -> None:
    selection = _mapping(
        _load_bounded_json(selection_manifest_path, "selection_manifest"),
        "selection_manifest",
    )
    _exact_keys(selection, {"schema_version", "views"}, "selection_manifest")
    if selection["schema_version"] != 1:
        raise EvidenceError("selection_manifest schema is unsupported")
    raw_views = selection["views"]
    if not isinstance(raw_views, list) or len(raw_views) != requested_scale:
        raise EvidenceError(
            f"selection_manifest must cover the requested scale {requested_scale}"
        )
    clip_ids: list[str] = []
    source_kinds: list[str] = []
    for index, raw_view in enumerate(raw_views):
        view = _mapping(raw_view, f"selection_manifest.views[{index}]")
        _exact_keys(
            view,
            {"view_index", "clip_id", "source_kind"},
            f"selection_manifest.views[{index}]",
        )
        if view["view_index"] != index:
            raise EvidenceError("selection_manifest view indices must be contiguous")
        clip_ids.append(_token(view["clip_id"], f"selection_manifest.views[{index}].clip_id"))
        if view["source_kind"] not in {"video", "photo"}:
            raise EvidenceError("selection_manifest source kind is invalid")
        source_kinds.append(view["source_kind"])

    pair_list = _mapping(_load_bounded_json(pair_list_path, "pair_list"), "pair_list")
    _exact_keys(
        pair_list,
        {"schema_version", "selected_frame_count", "pairs", "retrieval"},
        "pair_list",
    )
    if pair_list["schema_version"] != 2 or pair_list["selected_frame_count"] != requested_scale:
        raise EvidenceError("pair_list does not match the bound selected frame count")
    raw_pairs = pair_list["pairs"]
    if not isinstance(raw_pairs, list) or not raw_pairs:
        raise EvidenceError("pair_list must contain scheduled pairs")

    pairs: set[tuple[int, int]] = set()
    local_pairs: set[tuple[int, int]] = set()
    type_counts = {"local": 0, "retrieval": 0, "loop": 0, "exhaustive": 0}
    exhaustive_pairs: set[tuple[int, int]] = set()
    attempted_count = 0
    raw_matched_count = 0
    verified_count = 0
    adjacency = [set() for _ in range(requested_scale)]
    retrieval_targets_by_query: dict[int, set[int]] = {}
    verified_retrieval_by_query: dict[int, set[int]] = {}
    topology = candidate_configuration["input_topology"]
    distance_minimum = max(12, requested_scale // 10)
    for index, raw_pair in enumerate(raw_pairs):
        pair = _mapping(raw_pair, f"pair_list.pairs[{index}]")
        pair_type = pair.get("pair_type")
        pair_fields = {
            "view_a",
            "view_b",
            "pair_type",
            "query_view",
            "attempted",
            "raw_matched",
            "spatially_verified",
        }
        if pair_type == "exhaustive":
            pair_fields.add("matcher_used")
        _exact_keys(
            pair,
            pair_fields,
            f"pair_list.pairs[{index}]",
        )
        view_a = pair["view_a"]
        view_b = pair["view_b"]
        if (
            type(view_a) is not int
            or type(view_b) is not int
            or not 0 <= view_a < view_b < requested_scale
        ):
            raise EvidenceError("pair_list contains an invalid view pair")
        edge = (view_a, view_b)
        if edge in pairs:
            raise EvidenceError("pair_list contains a duplicate pair")
        pairs.add(edge)
        if pair_type not in type_counts:
            raise EvidenceError("pair_list contains an unsupported pair type")
        type_counts[pair_type] += 1
        for field in ("attempted", "raw_matched", "spatially_verified"):
            if type(pair[field]) is not bool:
                raise EvidenceError(f"pair_list {field} must be boolean")
        if pair["raw_matched"] and not pair["attempted"]:
            raise EvidenceError("pair_list raw match was not attempted")
        if pair["spatially_verified"] and not pair["raw_matched"]:
            raise EvidenceError("pair_list verified pair was not raw matched")
        attempted_count += pair["attempted"]
        raw_matched_count += pair["raw_matched"]
        verified_count += pair["spatially_verified"]
        if pair["spatially_verified"]:
            adjacency[view_a].add(view_b)
            adjacency[view_b].add(view_a)

        query_view = pair["query_view"]
        if pair_type == "local":
            if query_view is not None or clip_ids[view_a] != clip_ids[view_b]:
                raise EvidenceError("pair_list local pair crosses a clip boundary")
            local_pairs.add(edge)
        elif pair_type == "retrieval":
            if query_view not in edge:
                raise EvidenceError("pair_list retrieval pair has an invalid query view")
            if query_view % candidate_configuration["vocabulary_query_stride"] != 0:
                raise EvidenceError("pair_list retrieval query violates the resolved stride")
            if topology == "continuous" and view_b - view_a < distance_minimum:
                raise EvidenceError("pair_list retrieval neighbor is not distant")
            target_view = view_b if query_view == view_a else view_a
            if pair["attempted"]:
                retrieval_targets_by_query.setdefault(query_view, set()).add(target_view)
            if pair["spatially_verified"]:
                verified_retrieval_by_query.setdefault(query_view, set()).add(target_view)
        elif pair_type == "loop":
            if query_view is not None or candidate_configuration["capture_path"] not in {
                "around_subject",
                "large_area",
            }:
                raise EvidenceError("pair_list loop closure is not valid for this capture path")
            if view_b - view_a < distance_minimum:
                raise EvidenceError("pair_list loop closure is not distant")
        else:
            if (
                topology != "unordered"
                or candidate_configuration["pairing_policy"] != "unordered_exhaustive"
                or candidate_configuration["vocabulary_candidate_count"] != 0
                or candidate_configuration["vocabulary_verified_neighbor_count"] != 0
                or requested_scale > 60
                or query_view is not None
                or pair["matcher_used"] != "faiss"
                or not pair["attempted"]
                or any(source_kind != "photo" for source_kind in source_kinds)
            ):
                raise EvidenceError("pair_list exhaustive pair is invalid for the resolved route")
            exhaustive_pairs.add(edge)

    offsets = set(candidate_configuration["temporal_offsets"])
    expected_local: set[tuple[int, int]] = set()
    if topology == "continuous":
        if len(set(clip_ids)) != 1:
            raise EvidenceError("pair_list continuous input must use one clip")
        expected_local = {
            (view_a, view_b)
            for view_a in range(requested_scale)
            for view_b in range(view_a + 1, requested_scale)
            if view_b - view_a in offsets
        }
    elif topology == "segmented_mixed":
        views_by_clip: dict[str, list[int]] = {}
        for view_index, clip_id in enumerate(clip_ids):
            views_by_clip.setdefault(clip_id, []).append(view_index)
        for clip_views in views_by_clip.values():
            expected_local.update(
                (clip_views[left], clip_views[right])
                for left in range(len(clip_views))
                for right in range(left + 1, len(clip_views))
                if right - left in offsets
            )
    if local_pairs != expected_local:
        raise EvidenceError("pair_list local edges do not match the resolved temporal policy")
    expected_exhaustive = (
        {
            (view_a, view_b)
            for view_a in range(requested_scale)
            for view_b in range(view_a + 1, requested_scale)
        }
        if candidate_configuration["pairing_policy"] == "unordered_exhaustive"
        else set()
    )
    if exhaustive_pairs != expected_exhaustive:
        raise EvidenceError("pair_list exhaustive edges do not form the exact all-pairs closure")

    candidate_limit = candidate_configuration["vocabulary_candidate_count"]
    neighbor_limit = candidate_configuration["vocabulary_verified_neighbor_count"]
    configured_retrieval = candidate_limit > 0 and neighbor_limit > 0
    if (candidate_limit > 0) != (neighbor_limit > 0):
        raise EvidenceError("pair_list retrieval policy has inconsistent candidate and neighbor limits")

    eligible_targets_by_query: dict[int, set[int]] = {}
    if configured_retrieval:
        stride = candidate_configuration["vocabulary_query_stride"]
        for query_view in range(0, requested_scale, stride):
            eligible_targets: set[int] = set()
            for target_view in range(requested_scale):
                if target_view == query_view:
                    continue
                edge = (min(query_view, target_view), max(query_view, target_view))
                if edge in expected_local:
                    continue
                if topology == "continuous" and abs(target_view - query_view) < distance_minimum:
                    continue
                if topology == "segmented_mixed" and (
                    clip_ids[target_view] == clip_ids[query_view]
                    and source_kinds[target_view] == source_kinds[query_view] == "video"
                ):
                    continue
                eligible_targets.add(target_view)
            if eligible_targets:
                eligible_targets_by_query[query_view] = eligible_targets

    retrieval = _mapping(pair_list["retrieval"], "pair_list.retrieval")
    _exact_keys(
        retrieval,
        {"eligible_query_count", "queries"},
        "pair_list.retrieval",
    )
    eligible_query_count = retrieval["eligible_query_count"]
    if type(eligible_query_count) is not int or eligible_query_count < 0:
        raise EvidenceError("pair_list retrieval eligible query count is invalid")
    if eligible_query_count != len(eligible_targets_by_query):
        raise EvidenceError("pair_list retrieval eligible query count does not match policy")
    raw_queries = retrieval["queries"]
    if not isinstance(raw_queries, list) or len(raw_queries) != eligible_query_count:
        raise EvidenceError("pair_list retrieval queries do not cover every eligible query")

    query_fields = {
        "query_view",
        "eligible_target_count",
        "attempted_candidate_count",
        "attempted_targets",
        "verified_retained_neighbors",
        "retry_outcome",
        "matcher_used",
        "fallback_reason",
    }
    allowed_retry_outcomes = {
        "not_needed",
        "normal_faiss_exhausted",
        "denser_faiss_retained",
        "denser_faiss_exhausted",
        "expanded_faiss_retained",
        "expanded_faiss_exhausted",
        "exhaustive_faiss_retained",
        "exhaustive_faiss_exhausted",
        "exact_recovery_retained",
        "exact_recovery_exhausted",
    }
    observed_queries: list[int] = []
    for index, raw_query in enumerate(raw_queries):
        query = _mapping(raw_query, f"pair_list.retrieval.queries[{index}]")
        _exact_keys(query, query_fields, f"pair_list.retrieval.queries[{index}]")
        query_view = query["query_view"]
        if type(query_view) is not int or query_view not in eligible_targets_by_query:
            raise EvidenceError("pair_list retrieval query is not eligible under the resolved policy")
        observed_queries.append(query_view)
        eligible_targets = eligible_targets_by_query[query_view]
        if query["eligible_target_count"] != len(eligible_targets):
            raise EvidenceError("pair_list retrieval eligible target count is incorrect")
        attempted_targets = query["attempted_targets"]
        retained_neighbors = query["verified_retained_neighbors"]
        for name, targets in (
            ("attempted targets", attempted_targets),
            ("verified retained neighbors", retained_neighbors),
        ):
            if (
                not isinstance(targets, list)
                or targets != sorted(targets)
                or len(targets) != len(set(targets))
                or any(type(target) is not int or target not in eligible_targets for target in targets)
            ):
                raise EvidenceError(f"pair_list retrieval {name} are invalid")
        if (
            type(query["attempted_candidate_count"]) is not int
            or query["attempted_candidate_count"] != len(attempted_targets)
            or not attempted_targets
        ):
            raise EvidenceError("pair_list retrieval attempted candidate count is invalid")
        if not set(retained_neighbors).issubset(attempted_targets):
            raise EvidenceError("pair_list retrieval retained neighbor was not attempted")
        if set(attempted_targets) != retrieval_targets_by_query.get(query_view, set()):
            raise EvidenceError("pair_list retrieval attempts do not match scheduled retrieval pairs")
        if set(retained_neighbors) != verified_retrieval_by_query.get(query_view, set()):
            raise EvidenceError("pair_list retrieval retained neighbors do not match verified pairs")

        retry_outcome = query["retry_outcome"]
        if retry_outcome not in allowed_retry_outcomes:
            raise EvidenceError("pair_list retrieval retry outcome is invalid")
        matcher_used = query["matcher_used"]
        fallback_reason = query["fallback_reason"]
        exact_recovery = retry_outcome.startswith("exact_recovery_")
        if exact_recovery:
            if matcher_used != "exact" or fallback_reason not in {
                "faiss_crash",
                "faiss_unsupported_operation",
                "faiss_geometry_rejected_after_retries",
            }:
                raise EvidenceError(
                    "pair_list retrieval exact matcher fallback reason is invalid"
                )
        elif retry_outcome == "not_needed":
            if matcher_used != "faiss" or fallback_reason is not None:
                raise EvidenceError("pair_list retrieval normal matcher outcome is invalid")
        elif retry_outcome == "normal_faiss_exhausted":
            if matcher_used != "faiss" or fallback_reason != "insufficient_verified_neighbors":
                raise EvidenceError("pair_list retrieval normal exhausted outcome is invalid")
        elif matcher_used != "faiss" or fallback_reason not in {
            "verified_graph_disconnected",
            "geometry_acceptance_failed",
            "insufficient_verified_neighbors",
        }:
            raise EvidenceError("pair_list retrieval FAISS retry fallback reason is invalid")
        normal_attempt_limit = min(candidate_limit, len(eligible_targets))
        denser_attempt_limit = min(max(40, candidate_limit * 2), len(eligible_targets))
        expanded_attempt_limit = min(80, len(eligible_targets))
        query_attempted_count = len(attempted_targets)
        if retry_outcome == "not_needed":
            if query_attempted_count > normal_attempt_limit:
                raise EvidenceError("pair_list retrieval normal attempt closure is incomplete")
        elif retry_outcome == "normal_faiss_exhausted":
            if (
                query_attempted_count != normal_attempt_limit
                or normal_attempt_limit != len(eligible_targets)
            ):
                raise EvidenceError("pair_list retrieval normal exhaustion is incomplete")
        elif retry_outcome.startswith("denser_faiss_"):
            if (
                query_attempted_count <= normal_attempt_limit
                or query_attempted_count > denser_attempt_limit
            ):
                raise EvidenceError("pair_list retrieval denser retry attempt count is invalid")
            if (
                retry_outcome.endswith("_exhausted")
                and query_attempted_count != denser_attempt_limit
            ):
                raise EvidenceError("pair_list retrieval denser retry exhaustion is incomplete")
        elif retry_outcome.startswith("expanded_faiss_"):
            if (
                requested_scale <= 250
                or query_attempted_count <= denser_attempt_limit
                or query_attempted_count > expanded_attempt_limit
            ):
                raise EvidenceError("pair_list retrieval expanded retry attempt count is invalid")
            if (
                retry_outcome.endswith("_exhausted")
                and query_attempted_count != expanded_attempt_limit
            ):
                raise EvidenceError("pair_list retrieval expanded retry exhaustion is incomplete")
        elif retry_outcome.startswith("exhaustive_faiss_"):
            if requested_scale > 250 or query_attempted_count != len(eligible_targets):
                raise EvidenceError("pair_list retrieval exhaustive fallback is incomplete")
        else:
            required_exact_closure = (
                len(eligible_targets)
                if requested_scale <= 250
                else min(80, len(eligible_targets))
            )
            if query_attempted_count != required_exact_closure:
                raise EvidenceError(
                    "pair_list retrieval exact recovery lacks the preceding FAISS closure"
                )

        resolved_neighbor_limit = (
            max(32, neighbor_limit * 4)
            if retry_outcome.startswith("expanded_")
            else max(16, neighbor_limit * 2)
            if retry_outcome.startswith(("denser_", "exhaustive_", "exact_"))
            else neighbor_limit
        )
        retained_target = min(resolved_neighbor_limit, len(eligible_targets))
        successful_outcome = retry_outcome == "not_needed" or retry_outcome.endswith(
            "_retained"
        )
        if successful_outcome and len(retained_neighbors) != retained_target:
            raise EvidenceError(
                "pair_list retrieval retained neighbor target is incomplete"
            )
        if not successful_outcome and len(retained_neighbors) >= retained_target:
            raise EvidenceError(
                "pair_list retrieval exhausted outcome already satisfies its neighbor target"
            )
    if observed_queries != sorted(eligible_targets_by_query):
        raise EvidenceError("pair_list retrieval queries do not use canonical complete order")
    if not configured_retrieval and (
        eligible_query_count != 0 or raw_queries or retrieval_targets_by_query
    ):
        raise EvidenceError("pair_list contains retrieval work when retrieval is disabled")
    if len(raw_pairs) != pipeline_metrics.get("scheduled_pairs"):
        raise EvidenceError("pair_list scheduled_pairs does not match pipeline metrics")
    derived_counts = {
        "attempted_pairs": attempted_count,
        "raw_matched_pairs": raw_matched_count,
        "spatially_verified_pairs": verified_count,
        "local_pairs": type_counts["local"],
        "retrieval_pairs": type_counts["retrieval"],
        "loop_pairs": type_counts["loop"],
    }
    for name, count in derived_counts.items():
        if pipeline_metrics.get(name) != count:
            raise EvidenceError(f"pair_list {name} does not match pipeline metrics")

    isolated_views = sum(not neighbors for neighbors in adjacency)
    visited: set[int] = set()
    connected_components = 0
    for start in range(requested_scale):
        if start in visited:
            continue
        connected_components += 1
        stack = [start]
        visited.add(start)
        while stack:
            current = stack.pop()
            for neighbor in adjacency[current]:
                if neighbor not in visited:
                    visited.add(neighbor)
                    stack.append(neighbor)
    if pipeline_metrics.get("connected_components") != connected_components:
        raise EvidenceError("pair_list connected component count does not match pipeline metrics")
    if pipeline_metrics.get("isolated_views") != isolated_views:
        raise EvidenceError("pair_list isolated view count does not match pipeline metrics")
    for name, count in _biconnected_robustness(adjacency).items():
        if pipeline_metrics.get(name) != count:
            raise EvidenceError(f"pair_list {name} does not match pipeline metrics")


def derive_attestation(
    request: Mapping[str, Any],
    observations: Mapping[str, Any],
    artifact_root: Path,
    output_path: Path,
    lane: str,
    measurement_runner: Mapping[str, Any],
    machine: Mapping[str, Any] | None = None,
    *,
    enforce_environment_policy: bool = True,
) -> dict[str, Any]:
    """Validate raw benchmark artifacts and derive an unsigned attestation."""
    request = validate_request(request)
    if request["binding"]["lane"] != lane:
        raise EvidenceError("request hardware lane does not match the attested lane")
    if output_path.parent.resolve() != artifact_root.resolve():
        raise EvidenceError("attestation output must be stored at the artifact root")
    if artifact_root.is_symlink() or not artifact_root.is_dir():
        raise EvidenceError("artifact root must be a real directory")
    machine = dict(machine or collect_machine_metadata())
    validate_machine_lane(machine, lane)
    runner_identity = validate_runner_identity(measurement_runner, lane)

    common_observation_keys = {
        "schema_version",
        "artifacts",
        "commands",
        "actual",
        "baseline",
    }
    observation_keys = set(common_observation_keys)
    scopes = set(request["gate_scopes"])
    if request["expected_outcome"]["kind"] == "valid":
        observation_keys.update({"timing", "memory", "resolved_compute", "pipeline_metrics"})
    if lane == LANE_REFERENCE and request["expected_outcome"]["kind"] == "valid":
        if "scene_quality" in scopes:
            observation_keys.update({"registration", "residual_pixels", "pose"})
        if "long_sequence" in scopes:
            observation_keys.add("long_sequence")
        if "stability" in scopes:
            observation_keys.add("stability")
        if "toolchain" in scopes:
            observation_keys.add("toolchain_scenarios")
    _exact_keys(observations, observation_keys, "observations")
    if observations["schema_version"] != 3:
        raise EvidenceError("observations.schema_version must be 3")

    baseline = _mapping(observations.get("baseline"), "observations.baseline")
    _exact_keys(
        baseline,
        {"git_commit", "toolchain_identity", "configuration_digest"},
        "observations.baseline",
    )
    expected_baseline = {
        "git_commit": request["binding"]["baseline_git_commit"],
        "toolchain_identity": request["binding"]["baseline_toolchain_identity"],
        "configuration_digest": request["binding"]["baseline_configuration_digest"],
    }
    if baseline != expected_baseline:
        raise EvidenceError("observations.baseline does not match the bound request")

    raw_artifacts = _mapping(observations.get("artifacts"), "observations.artifacts")
    orientation_required = (
        lane == LANE_REFERENCE
        and request["expected_outcome"]["kind"] == "valid"
        and "scene_quality" in scopes
    )
    if not orientation_required:
        unexpected_orientation_artifacts = sorted(
            name for name in raw_artifacts if name.startswith("orientation_")
        )
        if unexpected_orientation_artifacts:
            raise EvidenceError(
                "orientation artifacts require reference scene_quality evidence: "
                + ", ".join(unexpected_orientation_artifacts)
            )
    canonical_artifacts = {
        "command_log": "command.jsonl",
        "supervisor_run": "supervisor-run.json",
        "host_monitor": "host-monitor.json",
        "toolchain_scenarios": "toolchain-scenarios.jsonl",
        "normal_photo_toolchain": "normal-photo.zip",
        "normal_photo_toolchain_state": "normal-photo-toolchain-state.json",
        "large_area_toolchain": "large-area.zip",
        "large_area_toolchain_state": "large-area-toolchain-state.json",
        "stdout_log": "stdout.log",
        "stderr_log": "stderr.log",
        "output_ply": "splat.ply",
        "training_manifest": "training-manifest.json",
        "pair_list": "pair-list.json",
        "selection_manifest": "selection-manifest.json",
        "ground_truth_poses": "ground-truth-poses.json",
        "accurate_colmap_model": "accurate-colmap-model.json",
        "accurate_rendering_reference": "accurate-rendering-reference.json",
        "ground_truth_preparation": "ground-truth-preparation.json",
        "paired_baseline_rendering_reference": "paired-baseline-rendering-reference.json",
        "orientation_label": "orientation-label.json",
        "orientation_metrics": "orientation-metrics.json",
        "orientation_supervisor": "orientation-supervisor.json",
        "render_job": "render-job.json",
        "rendering_manifest": "rendering-manifest.json",
        "render_supervisor": "render-supervisor.json",
        "renderer_stdout_log": "renderer-stdout.log",
        "renderer_stderr_log": "renderer-stderr.log",
    }
    for name, expected_path in canonical_artifacts.items():
        if name in raw_artifacts and raw_artifacts[name] != expected_path:
            raise EvidenceError(
                f"observations.artifacts.{name} must be the supervisor-owned {expected_path}"
            )
    descriptors: dict[str, Any] = {}
    for name, raw_path in raw_artifacts.items():
        _token(name, f"observations.artifacts.{name}")
        if not isinstance(raw_path, str):
            raise EvidenceError(f"observations.artifacts.{name} must be a relative path")
        relative = PurePosixPath(raw_path)
        if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts) or "\\" in raw_path:
            raise EvidenceError(f"unsafe artifact path: {raw_path}")
        descriptors[name] = _artifact_descriptor(artifact_root / Path(*relative.parts), artifact_root)

    observation_path = artifact_root / "observations.json"
    if observation_path.is_symlink() or not observation_path.is_file():
        raise EvidenceError("artifact root must contain observations.json")
    descriptors["observations"] = _artifact_descriptor(observation_path, artifact_root)
    stored_observations = _load_bounded_json(observation_path, "observations.json")
    if stored_observations != observations:
        raise EvidenceError("in-memory observations do not match observations.json")
    required = {
        "command_log",
        "supervisor_run",
        "host_monitor",
        "stdout_log",
        "stderr_log",
        "observations",
    }
    if request["expected_outcome"]["kind"] == "valid":
        required.update({"output_ply", "training_manifest"})
    if lane == LANE_REFERENCE and "toolchain" in scopes:
        required.update(
            {
                "normal_photo_toolchain",
                "normal_photo_toolchain_state",
                "large_area_toolchain",
                "large_area_toolchain_state",
                "toolchain_scenarios",
            }
        )
    reference_descriptor_fields = {
        "selection_manifest": "selection_manifest_sha256",
        "ground_truth_poses": "ground_truth_poses_sha256",
        "accurate_colmap_model": "accurate_colmap_model_sha256",
        "accurate_rendering_reference": "accurate_rendering_reference_sha256",
        "ground_truth_preparation": "ground_truth_preparation_sha256",
        "paired_baseline_rendering_reference": "paired_baseline_rendering_reference_sha256",
        "orientation_label": "orientation_label_sha256",
    }
    if lane == LANE_REFERENCE and "scene_quality" in scopes:
        required.update(reference_descriptor_fields)
        required.update(
            {
                "pair_list",
                "orientation_metrics",
                "orientation_supervisor",
                "render_job",
                "rendering_manifest",
                "render_supervisor",
                "renderer_stdout_log",
                "renderer_stderr_log",
            }
        )
    missing = required - set(descriptors)
    if missing:
        raise EvidenceError("missing required evidence artifacts: " + ", ".join(sorted(missing)))
    if request["expected_outcome"]["kind"] == "invalid" and "output_ply" in descriptors:
        raise EvidenceError("invalid evidence must not publish output_ply")
    toolchain_package_sizes: dict[str, int] | None = None
    if lane == LANE_REFERENCE and "toolchain" in scopes:
        toolchain_package_sizes = _validate_toolchain_package_evidence(
            artifact_root,
            descriptors,
            request["binding"]["toolchain_identity"],
        )
        if _read_command_log(
            artifact_root / descriptors["toolchain_scenarios"]["path"]
        ) != observations.get("toolchain_scenarios"):
            raise EvidenceError(
                "toolchain_scenarios log does not match the bound scenario receipts"
            )
    rendering_evidence: RenderingEvidence | None = None
    if lane == LANE_REFERENCE and "scene_quality" in scopes:
        for artifact_name, request_field in reference_descriptor_fields.items():
            if descriptors[artifact_name]["sha256"] != request["reference_artifacts"][request_field]:
                raise EvidenceError(
                    f"{artifact_name} does not match the pinned reference artifact digest"
                )
        _validate_orientation_label(
            artifact_root / descriptors["orientation_label"]["path"]
        )
        orientation_descriptors = _validate_orientation_supervisor(
            artifact_root / descriptors["orientation_supervisor"]["path"],
            artifact_root / descriptors["orientation_metrics"]["path"],
            artifact_root,
            request,
            observations,
            request["rendering_driver_identity"],
        )
        for name, descriptor in orientation_descriptors.items():
            existing = descriptors.get(name)
            if existing is not None and existing != descriptor:
                raise EvidenceError(f"orientation artifact descriptor conflicts with {name}")
            descriptors[name] = descriptor
        _validate_pair_list(
            artifact_root / descriptors["pair_list"]["path"],
            artifact_root / descriptors["selection_manifest"]["path"],
            request["binding"]["scale"],
            request["candidate_run_configuration"],
            _mapping(observations.get("pipeline_metrics"), "observations.pipeline_metrics"),
        )
        rendering_evidence = validate_and_score_rendering(
            artifact_root=artifact_root,
            manifest_path=artifact_root / descriptors["rendering_manifest"]["path"],
            reference_path=artifact_root / descriptors["accurate_rendering_reference"]["path"],
            preparation_path=artifact_root
            / descriptors["ground_truth_preparation"]["path"],
            request=request,
            commands=observations.get("commands"),
            renderer_executable_sha256=request["rendering_driver_identity"][
                "executable_sha256"
            ],
        )
        _validate_render_supervisor(
            artifact_root / descriptors["render_supervisor"]["path"],
            artifact_root / descriptors["render_job"]["path"],
            artifact_root / descriptors["rendering_manifest"]["path"],
            request,
            request["rendering_driver_identity"],
        )
        for name, descriptor in rendering_evidence.artifacts.items():
            existing = descriptors.get(name)
            if existing is not None and existing != descriptor:
                raise EvidenceError(f"rendering artifact descriptor conflicts with {name}")
            descriptors[name] = descriptor
    output_splat_count: int | None = None
    if "output_ply" in descriptors:
        output_ply = artifact_root / descriptors["output_ply"]["path"]
        output_splat_count = _validate_splat_ply(output_ply)
        _validate_training_manifest(
            artifact_root / descriptors["training_manifest"]["path"],
            descriptors["output_ply"],
            output_splat_count,
            _mapping(observations.get("pipeline_metrics"), "observations.pipeline_metrics"),
            request["candidate_run_configuration"],
            _published_training_duration(
                observations.get("commands"),
                _mapping(observations.get("timing"), "observations.timing"),
            ),
        )

    actual = _validate_actual(
        observations.get("actual"),
        request["expected_outcome"],
    )
    artifact_sizes = {name: descriptor["bytes"] for name, descriptor in descriptors.items()}
    if toolchain_package_sizes is not None:
        artifact_sizes.update(toolchain_package_sizes)
    metrics = derive_metrics(
        observations,
        lane,
        machine,
        artifact_sizes,
        gate_scopes=request["gate_scopes"],
        valid_outcome=request["expected_outcome"]["kind"] == "valid",
        requested_scale=request["binding"]["scale"],
        holdout_count=len(request["holdout_indices"]),
        candidate_run_configuration=request["candidate_run_configuration"],
        holdout_indices=list(request["holdout_indices"]),
        expected_orientation_status=request["reference_artifacts"].get(
            "orientation_expected_status"
        ),
        request_binding=request["binding"],
        rendering_evidence=rendering_evidence,
    )
    commands = observations.get("commands")
    _validate_execution_receipts(
        commands,
        artifact_root / descriptors["command_log"]["path"],
        request,
        runner_identity,
        (
            _mapping(observations.get("timing"), "observations.timing")
            if request["expected_outcome"]["kind"] == "valid"
            else None
        ),
        actual,
        descriptors.get("output_ply", {}).get("sha256"),
    )
    _validate_supervisor_run(
        artifact_root / descriptors["supervisor_run"]["path"],
        request,
        runner_identity,
        commands,
        machine,
        enforce_environment_policy=enforce_environment_policy,
    )
    resolved_compute: dict[str, Any]
    if request["expected_outcome"]["kind"] == "valid":
        resolved_compute = _validate_resolved_compute(
            observations.get("resolved_compute"),
            request["candidate_run_configuration"],
        )
    else:
        resolved_compute = {"status": "not_applicable"}
    if output_splat_count is not None:
        metrics["output_splat_count"] = measured(output_splat_count)
    producer_path = Path(__file__).resolve()
    root = producer_path.parents[2]
    if producer_path != root / PRODUCER_RELATIVE_PATH:
        raise EvidenceError("protected producer is not running from the repository path")
    unsigned = {
        "schema_version": 3,
        "binding": dict(request["binding"]),
        "baseline_run_configuration": dict(request["baseline_run_configuration"]),
        "candidate_run_configuration": dict(request["candidate_run_configuration"]),
        "category": request["category"],
        "capture_traits": list(request["capture_traits"]),
        "holdout_indices": list(request["holdout_indices"]),
        "reference_artifacts": dict(request["reference_artifacts"]),
        "timing_basis": request["timing_basis"],
        "expected_outcome": dict(request["expected_outcome"]),
        "input_kind": request["input_kind"],
        "gate_scopes": list(request["gate_scopes"]),
        "rendering_driver_identity": dict(request["rendering_driver_identity"]),
        "scoring_runtime": (
            render_scoring_runtime()
            if "scene_quality" in request["gate_scopes"]
            else {"status": "not_used"}
        ),
        "lane": lane,
        "machine": machine,
        "producer": {
            "protocol_version": PROTOCOL_VERSION,
            "version": PRODUCER_VERSION,
            "executable": PRODUCER_RELATIVE_PATH,
            "sha256": sha256_file(producer_path),
        },
        "measurement_runner": runner_identity,
        "commands": commands,
        "resolved_compute": resolved_compute,
        "actual": dict(actual),
        "metrics": metrics,
        "artifacts": descriptors,
    }
    return unsigned


def validate_attestation_candidate(
    request: Mapping[str, Any],
    observations: Mapping[str, Any],
    artifact_root: Path,
    output_path: Path,
    lane: str,
    measurement_runner: Mapping[str, Any],
    machine: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate all runner output while deferring host-policy classification."""
    return derive_attestation(
        request,
        observations,
        artifact_root,
        output_path,
        lane,
        measurement_runner,
        machine,
        enforce_environment_policy=False,
    )


def validate_prepared_attestation_file(
    attestation_path: Path,
    expected_request: Mapping[str, Any],
    expected_lane: str,
    expected_measurement_runner: Mapping[str, Any],
) -> Mapping[str, Any]:
    try:
        metadata = attestation_path.lstat()
    except OSError as error:
        raise EvidenceError("attestation is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or attestation_path.is_symlink()
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > MAX_ATTESTATION_BYTES
    ):
        raise EvidenceError("attestation must be a bounded single-link regular file")
    value = _load_bounded_json(
        attestation_path,
        "attestation",
        maximum_bytes=MAX_ATTESTATION_BYTES,
    )
    attestation = _mapping(value, "attestation")
    _exact_keys(
        attestation,
        {
            "schema_version",
            "binding",
            "baseline_run_configuration",
            "candidate_run_configuration",
            "category",
            "capture_traits",
            "holdout_indices",
            "reference_artifacts",
            "timing_basis",
            "expected_outcome",
            "input_kind",
            "gate_scopes",
            "rendering_driver_identity",
            "scoring_runtime",
            "lane",
            "machine",
            "producer",
            "measurement_runner",
            "commands",
            "resolved_compute",
            "actual",
            "metrics",
            "artifacts",
        },
        "attestation",
    )
    if attestation["schema_version"] != 3 or attestation["lane"] != expected_lane:
        raise EvidenceError("attestation schema or lane is invalid")
    request = validate_request(expected_request)
    for field in (
        "binding",
        "baseline_run_configuration",
        "candidate_run_configuration",
        "category",
        "capture_traits",
        "holdout_indices",
        "reference_artifacts",
        "timing_basis",
        "expected_outcome",
        "input_kind",
        "gate_scopes",
        "rendering_driver_identity",
        "resolved_compute",
    ):
        if field == "resolved_compute":
            continue
        if attestation[field] != request[field]:
            raise EvidenceError(f"attestation {field} does not match its request")
    expected_scoring_runtime = (
        render_scoring_runtime()
        if "scene_quality" in request["gate_scopes"]
        else {"status": "not_used"}
    )
    if attestation["scoring_runtime"] != expected_scoring_runtime:
        raise EvidenceError("attestation render-scoring runtime is invalid")
    if request["expected_outcome"]["kind"] == "valid":
        _validate_resolved_compute(
            attestation["resolved_compute"],
            request["candidate_run_configuration"],
        )
    elif attestation["resolved_compute"] != {"status": "not_applicable"}:
        raise EvidenceError("invalid evidence must mark resolved compute not_applicable")

    producer = _mapping(attestation["producer"], "attestation.producer")
    _exact_keys(producer, {"protocol_version", "version", "executable", "sha256"}, "attestation.producer")
    if producer["protocol_version"] != PROTOCOL_VERSION or producer["version"] != PRODUCER_VERSION:
        raise EvidenceError("attestation producer version is not supported")
    if producer["executable"] != PRODUCER_RELATIVE_PATH:
        raise EvidenceError("attestation was not made by the protected producer")
    producer_path = Path(__file__).resolve()
    if producer["sha256"] != sha256_file(producer_path):
        raise EvidenceError("attestation producer digest does not match this checkout")
    expected_runner = validate_runner_identity(expected_measurement_runner, expected_lane)
    actual_runner = validate_runner_identity(attestation["measurement_runner"], expected_lane)
    if actual_runner != expected_runner:
        raise EvidenceError("attestation measurement runner does not match the approved request index")

    machine = _mapping(attestation["machine"], "attestation.machine")
    validate_machine_lane(machine, expected_lane)
    artifacts = _mapping(attestation["artifacts"], "attestation.artifacts")
    root = attestation_path.parent.resolve()
    for name, raw_descriptor in artifacts.items():
        _token(name, f"attestation.artifacts.{name}")
        descriptor = _mapping(raw_descriptor, f"attestation.artifacts.{name}")
        _exact_keys(descriptor, {"path", "sha256", "bytes"}, f"attestation.artifacts.{name}")
        raw_path = descriptor["path"]
        if not isinstance(raw_path, str):
            raise EvidenceError("artifact path must be relative")
        relative = PurePosixPath(raw_path)
        if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts) or "\\" in raw_path:
            raise EvidenceError(f"unsafe attestation artifact path: {raw_path}")
        path = attestation_path.parent / Path(*relative.parts)
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise EvidenceError(f"attestation artifact is missing: {raw_path}") from error
        if resolved.parent != root and root not in resolved.parents:
            raise EvidenceError(f"attestation artifact escapes its root: {raw_path}")
        if path.is_symlink() or not path.is_file():
            raise EvidenceError(f"attestation artifact must be a regular file: {raw_path}")
        if type(descriptor["bytes"]) is not int or descriptor["bytes"] != path.stat().st_size:
            raise EvidenceError(f"attestation artifact size mismatch: {raw_path}")
        _digest(descriptor["sha256"], f"attestation.artifacts.{name}.sha256")
        if descriptor["sha256"] != sha256_file(path):
            raise EvidenceError(f"attestation artifact digest mismatch: {raw_path}")
    return attestation
