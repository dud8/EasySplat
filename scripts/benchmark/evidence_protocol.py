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
import itertools
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


PROTOCOL_VERSION = 16
PRODUCER_VERSION = "16.0.0"
REQUEST_SCHEMA_VERSION = 11
ATTESTATION_SCHEMA_VERSION = 13
GEOMETRY_ARTIFACT_SCHEMA_VERSION = 35
GEOMETRY_CONDITIONING_SCHEMA_VERSION = 2
GEOMETRY_CONDITIONING_PROVENANCE = "colmap-text-conditioning-v2"
GEOMETRY_CONDITIONING_ACCEPTANCE_POLICY = "capture-agnostic-conditioning-v2"
GEOMETRY_CONDITIONING_MAXIMUM_RAY_PAIR_EVALUATIONS = 100_000_000
GEOMETRY_WORKER_EXECUTION_SCHEMA_VERSION = 13
MAXIMUM_MAPPING_ATTEMPT_ORDINAL = 10_000
MAXIMUM_EXACT_RECOVERY_PAIR_COUNT = 256
# GPU-to-CPU FAISS recovery can precede normal, expanded, maximum, and exact
# attempts. This is the protocol's closed upper bound, not an arbitrary fixture cap.
MAXIMUM_PAIR_GRAPH_MATCHER_ATTEMPTS = 5
EXACT_RECOVERY_REASONS = frozenset(
    {
        "faissCrash",
        "faissUnsupportedOperation",
        "faissGeometryRejectedAfterRetries",
    }
)
MAPPING_CADENCE_FALLBACK_TRIGGERS = frozenset(
    {
        "insufficientViewSupport",
        "collapsedCameraTrajectory",
        "insufficientParallax",
        "degeneratePointDistribution",
        "lowReconstructionQuality",
        "fragmentedReconstruction",
        "lowRegisteredViewCoverage",
        "sparseResidualCoverage",
        "excessiveResiduals",
    }
)
_MISSING = object()
PRODUCER_RELATIVE_PATH = "scripts/benchmark/evidence_protocol.py"
PHOTO_PERMUTATION_PRODUCER_RELATIVE_PATH = (
    "scripts/benchmark/photo_permutation_producer.py"
)
COLMAP_RUNTIME_COMPONENT_PATHS = ("bin/colmap", "lib/libomp.dylib")
SHIPPING_MACHINE_SOFTWARE = {
    "clang_version": "Apple clang version 21.0.0 (clang-2100.1.1.101)",
    "macos_build": "25F84",
    "macos_version": "26.5.2",
    "macos_sdk_build": "25F70",
    "macos_sdk_version": "26.5",
    "metal_version": "Apple metal version 32023.883 (metalfe-32023.883)",
    "swift_version": (
        "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"
    ),
    "xcode_version": "Xcode 26.6\nBuild version 17F113",
}
COLMAP_THREAD_ENVIRONMENT_KEYS = (
    "BLIS_NUM_THREADS",
    "GOMP_CPU_AFFINITY",
    "GOMP_SPINCOUNT",
    "GOMP_STACKSIZE",
    "GOTO_NUM_THREADS",
    "KMP_AFFINITY",
    "KMP_ALL_THREADS",
    "KMP_BLOCKTIME",
    "KMP_DETERMINISTIC_REDUCTION",
    "KMP_DEVICE_THREAD_LIMIT",
    "KMP_HW_SUBSET",
    "KMP_LIBRARY",
    "KMP_PLACE_THREADS",
    "KMP_SETTINGS",
    "KMP_STACKSIZE",
    "KMP_TEAMS_THREAD_LIMIT",
    "MKL_DOMAIN_NUM_THREADS",
    "MKL_DYNAMIC",
    "MKL_NUM_THREADS",
    "OMP_DYNAMIC",
    "OMP_MAX_ACTIVE_LEVELS",
    "OMP_NESTED",
    "OMP_NUM_THREADS",
    "OMP_PLACES",
    "OMP_PROC_BIND",
    "OMP_SCHEDULE",
    "OMP_STACKSIZE",
    "OMP_THREAD_LIMIT",
    "OMP_WAIT_POLICY",
    "OPENBLAS_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
)
COLMAP_THREAD_ENVIRONMENT_KEYS_SHA256 = (
    "sha256:"
    + hashlib.sha256(
        json.dumps(
            list(COLMAP_THREAD_ENVIRONMENT_KEYS),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ).hexdigest()
)
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
OPAQUE_SHA256_PATTERN = re.compile(r"^opaque-sha256:[0-9a-f]{64}$")
SAFE_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
PHOTO_PERMUTATION_FORMAL_VARIANT_COUNT = 20
PHOTO_PERMUTATION_FORMAL_SHUFFLE_COUNT = PHOTO_PERMUTATION_FORMAL_VARIANT_COUNT - 1
PHOTO_PERMUTATION_SOURCE_KINDS = frozenset(
    {
        "native_photos",
        "single_video_derived_stills",
        "multi_video_derived_stills",
        "mixed_derived_stills",
        "calibration_dataset_derived_stills",
    }
)
PHOTO_PERMUTATION_FORMAL_SEEDS = (
    4_831_724_571_275_814_301,
    299_878_011_999_028_456,
    2_844_834_447_830_983_243,
    6_231_082_215_795_779_454,
    4_800_438_096_911_084_048,
    2_716_919_709_073_054,
    6_182_739_618_928_064_372,
    1_890_503_712_009_985_873,
    1_568_370_770_626_313_518,
    5_229_953_635_493_634_764,
    2_975_060_197_054_291_650,
    8_734_660_529_696_552_112,
    5_732_113_024_416_928_989,
    7_080_989_793_255_452_606,
    3_391_660_995_046_289_640,
    1_455_629_253_019_862_542,
    4_421_409_204_413_149_686,
    1_852_296_383_023_932_283,
    5_338_892_799_857_249_680,
)
MAX_PHOTO_PERMUTATION_MAPPING_BYTES = 8 * 1024 * 1024
MAX_PHOTO_PERMUTATION_ATTESTATION_BUNDLE_BYTES = 16 * 1024 * 1024
PHOTO_PERMUTATION_ATTESTATION_REPOSITORY = "dud8/EasySplat"
PHOTO_PERMUTATION_ATTESTATION_WORKFLOW = (
    "dud8/EasySplat/.github/workflows/benchmark-release.yml"
)
MONOTONIC_TIMESTAMP_TOLERANCE_SECONDS = 1e-6
PINNED_TOOLCHAIN_PUBLIC_KEY_PATH = (
    Path(__file__).resolve().parents[2]
    / "scripts/release/toolchain_authority_public_key.txt"
)
PINNED_TOOLCHAIN_PUBLIC_KEY_BASE64_OVERRIDE: str | None = None
MAX_TOOLCHAIN_INSTALL_STATE_BYTES = 16 * 1024 * 1024
MAX_HOST_MONITOR_BYTES = 64 * 1024 * 1024
MAX_LANE_OUTCOME_BYTES = 1024 * 1024
MAX_ATTESTATION_BYTES = 16 * 1024 * 1024
MAX_OBSERVATIONS_BYTES = 256 * 1024 * 1024
MAX_WORKER_EXECUTION_ARTIFACT_BYTES = 2 * 1024 * 1024
MAX_GEOMETRY_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_CANONICAL_CAMERAS_BYTES = 16 * 1024 * 1024
MAX_WORKER_INVOCATIONS_PER_STAGE = 4_096
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
    f"lin{index}.model.1.weight" for index in range(7)
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


POSE_ALIGNMENT_NUMPY_VERSION = RENDER_SCORING_PACKAGE_VERSIONS["numpy"]


class PoseAlignmentError(EvidenceError):
    """Name-bound camera poses cannot produce trustworthy Sim(3) evidence."""

    def __init__(self, reason: str, detail: str | None = None):
        self.reason = reason
        message = reason if detail is None else f"{reason}: {detail}"
        super().__init__(message)


@dataclass(frozen=True)
class NameBoundCameraPose:
    image_name: str
    center_xyz: tuple[float, float, float]
    rotation_cw: tuple[
        tuple[float, float, float],
        tuple[float, float, float],
        tuple[float, float, float],
    ]


@dataclass(frozen=True)
class Sim3PoseDeviation:
    camera_center_p95_scene_radius_fraction: float
    rotation_p95_degrees: float


def _pose_number_vector(
    value: Any,
    *,
    count: int,
    label: str,
) -> tuple[float, ...]:
    if (
        not isinstance(value, (list, tuple))
        or len(value) != count
        or any(
            isinstance(component, bool)
            or not isinstance(component, (int, float))
            or not math.isfinite(float(component))
            for component in value
        )
    ):
        raise PoseAlignmentError(
            "pose_artifact_invalid",
            f"{label} must contain {count} finite numbers",
        )
    return tuple(float(component) for component in value)


def _pose_quaternion_rotation(
    value: Any,
    *,
    label: str,
) -> tuple[
    tuple[float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]:
    quaternion = _pose_number_vector(value, count=4, label=label)
    norm = math.sqrt(sum(component * component for component in quaternion))
    if not math.isfinite(norm) or abs(norm - 1.0) > 1e-6:
        raise PoseAlignmentError(
            "pose_artifact_invalid",
            f"{label} must be a unit quaternion in wxyz order",
        )
    w, x, y, z = (component / norm for component in quaternion)
    return (
        (
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
        ),
        (
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
        ),
        (
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
        ),
    )


def _pose_rotation_matrix(
    value: Any,
    *,
    label: str,
) -> tuple[
    tuple[float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise PoseAlignmentError(
            "pose_artifact_invalid", f"{label} must be a 3 by 3 matrix"
        )
    rows = tuple(
        _pose_number_vector(row, count=3, label=f"{label}[{index}]")
        for index, row in enumerate(value)
    )
    for first in range(3):
        for second in range(3):
            dot = sum(rows[row][first] * rows[row][second] for row in range(3))
            expected = 1.0 if first == second else 0.0
            if abs(dot - expected) > 1e-6:
                raise PoseAlignmentError(
                    "pose_artifact_invalid",
                    f"{label} must be an orthonormal rotation",
                )
    determinant = (
        rows[0][0] * (rows[1][1] * rows[2][2] - rows[1][2] * rows[2][1])
        - rows[0][1] * (rows[1][0] * rows[2][2] - rows[1][2] * rows[2][0])
        + rows[0][2] * (rows[1][0] * rows[2][1] - rows[1][1] * rows[2][0])
    )
    if abs(determinant - 1.0) > 1e-6:
        raise PoseAlignmentError(
            "pose_artifact_invalid", f"{label} must have determinant +1"
        )
    return rows


def name_bound_w2c_poses(
    records: Iterable[Mapping[str, Any]],
) -> dict[str, NameBoundCameraPose]:
    """Validate w2c pose records and bind each pose to its image name."""
    if isinstance(records, (str, bytes, Mapping)):
        raise PoseAlignmentError(
            "pose_artifact_invalid", "pose records must be an ordered collection"
        )
    result: dict[str, NameBoundCameraPose] = {}
    try:
        iterator = iter(records)
    except TypeError as error:
        raise PoseAlignmentError(
            "pose_artifact_invalid", "pose records must be an ordered collection"
        ) from error
    for index, raw in enumerate(iterator):
        if not isinstance(raw, Mapping):
            raise PoseAlignmentError(
                "pose_artifact_invalid", f"pose record {index} must be an object"
            )
        expected = {"image_name", "w2c_quaternion_wxyz"}
        coordinate_fields = {"translation_xyz", "center_xyz"} & set(raw)
        if len(coordinate_fields) != 1 or set(raw) != expected | coordinate_fields:
            raise PoseAlignmentError(
                "pose_artifact_invalid",
                "pose records require exactly one of translation_xyz or center_xyz",
            )
        image_name = raw["image_name"]
        if not isinstance(image_name, str) or not image_name:
            raise PoseAlignmentError(
                "pose_artifact_invalid", "pose image names must be nonempty strings"
            )
        if image_name in result:
            raise PoseAlignmentError(
                "pose_artifact_invalid", "pose names must be unique"
            )
        rotation = _pose_quaternion_rotation(
            raw["w2c_quaternion_wxyz"],
            label=f"pose record {image_name}.w2c_quaternion_wxyz",
        )
        if "center_xyz" in raw:
            center = _pose_number_vector(
                raw["center_xyz"], count=3, label=f"pose record {image_name}.center_xyz"
            )
        else:
            translation = _pose_number_vector(
                raw["translation_xyz"],
                count=3,
                label=f"pose record {image_name}.translation_xyz",
            )
            center = tuple(
                -sum(rotation[row][column] * translation[row] for row in range(3))
                for column in range(3)
            )
        result[image_name] = NameBoundCameraPose(image_name, center, rotation)
    if not result:
        raise PoseAlignmentError(
            "pose_artifact_invalid", "pose records must not be empty"
        )
    return result


def mapper_cadence_name_bound_poses(
    envelope: Mapping[str, Any],
) -> dict[str, NameBoundCameraPose]:
    """Bind the mapper-cadence parallel pose arrays before comparison."""
    if not isinstance(envelope, Mapping):
        raise PoseAlignmentError(
            "pose_artifact_invalid", "mapper cadence envelope must be an object"
        )
    names = envelope.get("registered_image_names")
    poses = envelope.get("camera_poses_wxyz_xyz")
    if (
        not isinstance(names, list)
        or not isinstance(poses, list)
        or not names
        or len(names) != len(poses)
    ):
        raise PoseAlignmentError(
            "pose_artifact_invalid",
            "mapper cadence pose arrays must have the same nonzero length",
        )
    records = []
    for index, (name, pose) in enumerate(zip(names, poses, strict=True)):
        if not isinstance(pose, (list, tuple)) or len(pose) != 7:
            raise PoseAlignmentError(
                "pose_artifact_invalid",
                f"mapper cadence pose {index} must contain seven values",
            )
        records.append(
            {
                "image_name": name,
                "w2c_quaternion_wxyz": pose[:4],
                "translation_xyz": pose[4:],
            }
        )
    return name_bound_w2c_poses(records)


def _coerce_name_bound_pose_mapping(
    value: Mapping[str, Any],
    *,
    label: str,
) -> dict[str, NameBoundCameraPose]:
    if not isinstance(value, Mapping) or not value:
        raise PoseAlignmentError(
            "pose_artifact_invalid", f"{label} must be a nonempty name-bound mapping"
        )
    if any(not isinstance(name, str) or not name for name in value):
        raise PoseAlignmentError(
            "pose_artifact_invalid", f"{label} names must be nonempty strings"
        )
    result: dict[str, NameBoundCameraPose] = {}
    for name in sorted(value):
        raw = value[name]
        if isinstance(raw, NameBoundCameraPose):
            if raw.image_name != name:
                raise PoseAlignmentError(
                    "pose_artifact_invalid",
                    f"{label} pose name does not match its mapping key",
                )
            center = _pose_number_vector(
                raw.center_xyz, count=3, label=f"{label}.{name}.center_xyz"
            )
            rotation = _pose_rotation_matrix(
                raw.rotation_cw, label=f"{label}.{name}.rotation_cw"
            )
            result[name] = NameBoundCameraPose(name, center, rotation)
            continue
        if not isinstance(raw, Mapping):
            raise PoseAlignmentError(
                "pose_artifact_invalid", f"{label}.{name} must be a pose object"
            )
        if set(raw) == {"center", "rotation_cw"}:
            center = _pose_number_vector(
                raw["center"], count=3, label=f"{label}.{name}.center"
            )
            rotation = _pose_rotation_matrix(
                raw["rotation_cw"], label=f"{label}.{name}.rotation_cw"
            )
            result[name] = NameBoundCameraPose(name, center, rotation)
            continue
        record = dict(raw)
        supplied_name = record.setdefault("image_name", name)
        if supplied_name != name:
            raise PoseAlignmentError(
                "pose_artifact_invalid",
                f"{label} pose name does not match its mapping key",
            )
        result[name] = name_bound_w2c_poses([record])[name]
    return result


def _pose_alignment_numpy() -> Any:
    try:
        import importlib.metadata
        import numpy

        version = importlib.metadata.version("numpy")
    except (ImportError, importlib.metadata.PackageNotFoundError) as error:
        raise PoseAlignmentError("pose_alignment_runtime_unavailable") from error
    if version != POSE_ALIGNMENT_NUMPY_VERSION:
        raise PoseAlignmentError("pose_alignment_runtime_unavailable")
    return numpy


def sim3_pose_deviation(
    reference_poses: Mapping[str, Any],
    candidate_poses: Mapping[str, Any],
) -> Sim3PoseDeviation:
    """Compare name-bound w2c poses after one proper Umeyama Sim(3)."""
    reference = _coerce_name_bound_pose_mapping(
        reference_poses, label="reference poses"
    )
    candidate = _coerce_name_bound_pose_mapping(
        candidate_poses, label="candidate poses"
    )
    common = sorted(set(reference) & set(candidate))
    if len(common) < 3:
        raise PoseAlignmentError("pose_alignment_unavailable")
    np = _pose_alignment_numpy()
    try:
        with np.errstate(over="raise", invalid="raise"):
            source = np.asarray(
                [candidate[name].center_xyz for name in common], dtype=float
            )
            target = np.asarray(
                [reference[name].center_xyz for name in common], dtype=float
            )
            source_mean = source.mean(axis=0)
            target_mean = target.mean(axis=0)
            source_centered = source - source_mean
            target_centered = target - target_mean
            source_variance = float(
                np.sum(source_centered * source_centered) / len(common)
            )
            target_variance = float(
                np.sum(target_centered * target_centered) / len(common)
            )
            source_rank = int(np.linalg.matrix_rank(source_centered))
            target_rank = int(np.linalg.matrix_rank(target_centered))
    except (FloatingPointError, np.linalg.LinAlgError) as error:
        raise PoseAlignmentError("pose_alignment_degenerate") from error
    if (
        not math.isfinite(source_variance)
        or not math.isfinite(target_variance)
        or min(source_variance, target_variance) <= 1e-12
        or source_rank < 2
        or target_rank < 2
    ):
        raise PoseAlignmentError("pose_alignment_degenerate")
    covariance = target_centered.T @ source_centered / len(common)
    try:
        left, singular_values, right_transpose = np.linalg.svd(covariance)
    except np.linalg.LinAlgError as error:
        raise PoseAlignmentError("pose_alignment_degenerate") from error
    correction = np.eye(3)
    if float(np.linalg.det(left @ right_transpose)) < 0.0:
        correction[-1, -1] = -1.0
    alignment_rotation = left @ correction @ right_transpose
    determinant = float(np.linalg.det(alignment_rotation))
    if not math.isfinite(determinant) or abs(determinant - 1.0) > 1e-8:
        raise PoseAlignmentError("pose_alignment_degenerate")
    alignment_scale = float(
        np.sum(singular_values * np.diag(correction)) / source_variance
    )
    if not math.isfinite(alignment_scale) or alignment_scale <= 0.0:
        raise PoseAlignmentError("pose_alignment_degenerate")
    translation = target_mean - alignment_scale * (alignment_rotation @ source_mean)
    aligned = (alignment_scale * (alignment_rotation @ source.T)).T + translation
    deviations = np.linalg.norm(aligned - target, axis=1)
    reference_center = np.median(target, axis=0)
    scene_radius = float(
        np.percentile(np.linalg.norm(target - reference_center, axis=1), 95)
    )
    if not math.isfinite(scene_radius) or scene_radius <= 1e-12:
        raise PoseAlignmentError("pose_alignment_degenerate")
    center_p95 = float(np.percentile(deviations, 95) / scene_radius)
    rotation_errors: list[float] = []
    for name in common:
        reference_rotation = np.asarray(reference[name].rotation_cw, dtype=float)
        candidate_rotation = np.asarray(candidate[name].rotation_cw, dtype=float)
        predicted_rotation = candidate_rotation @ alignment_rotation.T
        relative_rotation = reference_rotation @ predicted_rotation.T
        cosine = float(np.clip((np.trace(relative_rotation) - 1.0) / 2.0, -1.0, 1.0))
        rotation_errors.append(math.degrees(math.acos(cosine)))
    rotation_p95 = float(np.percentile(np.asarray(rotation_errors), 95))
    if not math.isfinite(center_p95) or not math.isfinite(rotation_p95):
        raise PoseAlignmentError("pose_alignment_degenerate")
    return Sim3PoseDeviation(center_p95, rotation_p95)


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


def colmap_runtime_closure_digest(components: Iterable[tuple[str, str]]) -> str:
    hasher = hashlib.sha256()

    def update(field: str) -> None:
        encoded = field.encode("utf-8")
        hasher.update(len(encoded).to_bytes(8, byteorder="big", signed=False))
        hasher.update(encoded)

    update("easysplat-colmap-runtime-closure-v1")
    for path, digest in components:
        update(path)
        update(digest)
    return hasher.hexdigest()


def geometry_model_closure_digest(model_hashes: Mapping[str, str]) -> str:
    """Mirror GeometryArtifactStore.modelClosureDigest for canonical text models."""
    expected_names = ("cameras.txt", "images.txt", "points3D.txt")
    if set(model_hashes) != set(expected_names) or any(
        not isinstance(model_hashes[name], str)
        or re.fullmatch(r"[0-9a-f]{64}", model_hashes[name]) is None
        for name in expected_names
    ):
        raise EvidenceError("geometry model closure hashes are invalid")
    hasher = hashlib.sha256()

    def update(field: str) -> None:
        encoded = field.encode("utf-8")
        hasher.update(len(encoded).to_bytes(8, byteorder="big", signed=False))
        hasher.update(encoded)

    update("easysplat-model-closure-v1")
    for name in sorted(expected_names):
        update(name)
        update(model_hashes[name])
    return hasher.hexdigest()


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


def _valid_exact_recovery_reason(value: Any) -> bool:
    return isinstance(value, str) and value in EXACT_RECOVERY_REASONS


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
    return {
        name: validate_runner_identity(identities[name], name)
        for name in sorted(required)
    }


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
    if (
        not isinstance(value, list)
        or not value
        or any(not isinstance(item, bool) for item in value)
    ):
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
            raise EvidenceError(
                "residual view_index must identify a candidate-registered view"
            )
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
            raise EvidenceError(
                "residual observations must be unique view and point pairs"
            )
        seen_observations.add(observation)
        covered_views.add(view_index)
        point_ids.add(point_id)
        residuals.append(float(residual))
    expected_views = {
        index for index, registered in enumerate(registered_views) if registered
    }
    if covered_views != expected_views:
        raise EvidenceError(
            "residual observations must cover every candidate-registered view"
        )
    return residuals, len(point_ids)


def _pose_samples(
    value: Any,
    candidate_registered: list[bool],
    colmap_registered: list[bool],
) -> tuple[
    list[float], list[float], list[float], list[float], list[float], list[float]
]:
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
        raise EvidenceError(
            "pose evidence requires at least two commonly registered views"
        )
    absolute = pose["absolute"]
    if not isinstance(absolute, list) or len(absolute) != len(common_views):
        raise EvidenceError("pose.absolute must cover every commonly registered view")
    candidate_ate: list[float] = []
    colmap_ate: list[float] = []
    for index, raw in enumerate(absolute):
        record = _mapping(raw, f"pose.absolute[{index}]")
        _exact_keys(
            record,
            {"view_index", "candidate_ate", "colmap_ate"},
            f"pose.absolute[{index}]",
        )
        if record["view_index"] != common_views[index]:
            raise EvidenceError(
                "pose.absolute view indices must match the common registration set"
            )
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
                raise EvidenceError(
                    f"pose.absolute[{index}].{field} must be finite and nonnegative"
                )
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
        if (record["from_view_index"], record["to_view_index"]) != expected_pairs[
            index
        ]:
            raise EvidenceError(
                "pose.relative pairs must match adjacent common registered views"
            )
        for field, destination in destinations:
            number = record[field]
            if (
                isinstance(number, bool)
                or not isinstance(number, (int, float))
                or not math.isfinite(number)
                or number < 0
            ):
                raise EvidenceError(
                    f"pose.relative[{index}].{field} must be finite and nonnegative"
                )
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
                raise EvidenceError(
                    f"observations.pipeline_metrics.{name} must be null or a nonnegative integer"
                )
            result[name] = measured(item)
        elif name in PIPELINE_NUMBER_METRICS:
            if (
                isinstance(item, bool)
                or not isinstance(item, (int, float))
                or not math.isfinite(item)
                or item < 0
            ):
                raise EvidenceError(
                    f"observations.pipeline_metrics.{name} must be null or finite and nonnegative"
                )
            result[name] = measured(float(item))
        elif name in PIPELINE_BOOLEAN_METRICS:
            if type(item) is not bool:
                raise EvidenceError(
                    f"observations.pipeline_metrics.{name} must be null or boolean"
                )
            result[name] = measured(item)
        elif item not in PIPELINE_ENUM_METRICS[name]:
            raise EvidenceError(
                f"observations.pipeline_metrics.{name} has an unsupported value"
            )
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
        raise EvidenceError(
            "raster recovery pipeline metrics must be measured together"
        )
    if measured_raster:
        fallback_count = raster_values["raster_fallback_count"]
        exact_elapsed = raster_values["raster_exact_fallback_elapsed_seconds"]
        growth_count = raster_values["raster_exact_buffer_growth_count"]
        bytes_added = raster_values["raster_exact_buffer_bytes_added"]
        replay_elapsed = raster_values["raster_replay_elapsed_seconds"]
        peak_capacity = raster_values["raster_peak_exact_intersection_capacity"]
        if peak_capacity > (1 << 32) - 1:
            raise EvidenceError(
                "raster peak exact capacity exceeds the native counter range"
            )
        if growth_count > fallback_count:
            raise EvidenceError("raster buffer growth count exceeds fallback count")
        if fallback_count == 0 and any(
            value != 0
            for value in (
                exact_elapsed,
                growth_count,
                bytes_added,
                replay_elapsed,
                peak_capacity,
            )
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
            raise EvidenceError(
                "zero raster buffer growth requires zero allocation evidence"
            )
        if growth_count > 0 and (bytes_added == 0 or peak_capacity <= 2_048):
            raise EvidenceError("raster buffer growth evidence is incomplete")
        maximum_tile_intersections = raw["maximum_tile_intersections"]
        if maximum_tile_intersections is not None:
            crossed_overflow_threshold = maximum_tile_intersections > 2_048
            if (fallback_count > 0) != crossed_overflow_threshold:
                raise EvidenceError(
                    "raster fallback evidence contradicts the measured overflow threshold"
                )
            if (
                crossed_overflow_threshold
                and peak_capacity < maximum_tile_intersections
            ):
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
            raise EvidenceError(f"orientation label physical_up.{name} must be finite")
        components.append(float(value))
    if math.sqrt(sum(value * value for value in components)) <= 1e-12:
        raise EvidenceError("orientation label physical_up must be nonzero")


def validate_orientation_metrics(
    value: Any, label: str = "orientation metrics"
) -> dict[str, Any]:
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
    if (
        result["alignment_p90_residual_degrees"]
        < result["alignment_median_residual_degrees"]
    ):
        raise EvidenceError(
            f"{label} alignment p90 residual cannot be below its median"
        )

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
    if (
        abs(
            math.sqrt(sum(component * component for component in normalized_quaternion))
            - 1
        )
        > 1e-6
    ):
        raise EvidenceError(
            f"{label} source-to-ground-truth quaternion must be normalized"
        )
    first_nonzero = next(
        (component for component in normalized_quaternion if component != 0),
        0.0,
    )
    if first_nonzero < 0:
        raise EvidenceError(
            f"{label} source-to-ground-truth quaternion must be sign-canonical"
        )
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
        if (
            result["orientation_physical_up_error_degrees"] is None
            or sign_correct is None
        ):
            raise EvidenceError(
                f"{label} verified orientation lacks directed up evidence"
            )
    elif status == "axis_aligned_sign_unverified":
        if (
            result["orientation_physical_up_error_degrees"] is None
            or sign_correct is not None
        ):
            raise EvidenceError(
                f"{label} axis_aligned_sign_unverified orientation requires physical-up "
                "error without a sign claim"
            )
    elif (
        result["orientation_physical_up_error_degrees"] is not None
        or sign_correct is not None
    ):
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
) -> tuple[
    list[float], list[float], list[float], list[float], list[float], list[float]
]:
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
            if (
                isinstance(number, bool)
                or not isinstance(number, (int, float))
                or not math.isfinite(number)
            ):
                raise EvidenceError(f"{label}[{index}].{field} must be finite")
            values[field] = float(number)
        for field, number in values.items():
            if field.endswith("_psnr") and number < 0:
                raise EvidenceError(
                    f"{label}[{index}].{field} is outside the rendering domain"
                )
            if field.endswith("_ssim") and not 0 <= number <= 1:
                raise EvidenceError(
                    f"{label}[{index}].{field} is outside the rendering domain"
                )
            if field.endswith("_lpips") and number < 0:
                raise EvidenceError(
                    f"{label}[{index}].{field} is outside the rendering domain"
                )
        psnr.append(max(0.0, values["reference_psnr"] - values["candidate_psnr"]))
        ssim.append(max(0.0, values["reference_ssim"] - values["candidate_ssim"]))
        lpips.append(max(0.0, values["candidate_lpips"] - values["reference_lpips"]))
        if include_paired_baseline:
            paired_psnr.append(
                max(0.0, values["baseline_psnr"] - values["candidate_psnr"])
            )
            paired_ssim.append(
                max(0.0, values["baseline_ssim"] - values["candidate_ssim"])
            )
            paired_lpips.append(
                max(0.0, values["candidate_lpips"] - values["baseline_lpips"])
            )
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


def _opaque_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not OPAQUE_SHA256_PATTERN.fullmatch(value):
        raise EvidenceError(f"{label} must be an opaque SHA-256 digest")
    return value


def _photo_pair_graph_digest(edges: list[str]) -> str:
    payload = canonical_json_bytes(edges)
    return (
        "opaque-sha256:"
        + hashlib.sha256(b"easysplat-photo-pair-graph-v1\0" + payload).hexdigest()
    )


def photo_permutation_release_seed(index: int) -> int:
    """Return the immutable public seed for one formal release permutation."""
    if (
        type(index) is not int
        or not 1 <= index <= PHOTO_PERMUTATION_FORMAL_SHUFFLE_COUNT
    ):
        raise EvidenceError("formal photo permutation index is invalid")
    digest = hashlib.sha256(
        b"easysplat-photo-permutation-release-seed-v1\0" + struct.pack(">I", index)
    ).digest()
    derived = int.from_bytes(digest[:8], "big") & ((1 << 63) - 1)
    reviewed = PHOTO_PERMUTATION_FORMAL_SEEDS[index - 1]
    if derived != reviewed:
        raise AssertionError("reviewed photo permutation seed table changed")
    return reviewed


def _photo_content_set_digest(content_ids: list[str]) -> str:
    return (
        "opaque-sha256:"
        + hashlib.sha256(
            b"easysplat-photo-content-set-v1\0" + canonical_json_bytes(content_ids)
        ).hexdigest()
    )


def _photo_pair_edge_id(content_a: str, content_b: str) -> str:
    return (
        "opaque-sha256:"
        + hashlib.sha256(
            b"easysplat-photo-pair-edge-v1\0"
            + canonical_json_bytes([content_a, content_b])
        ).hexdigest()
    )


def _photo_permutation_request_contract(
    request: Mapping[str, Any],
) -> tuple[int, int, str]:
    if request.get("input_kind") != "photos":
        raise EvidenceError("photo permutation evidence requires photo-only input")
    configuration = _mapping(
        request.get("candidate_run_configuration"),
        "photo permutation request candidate configuration",
    )
    if (
        configuration.get("input_topology") != "unordered"
        or configuration.get("capture_path") != "automatic"
        or configuration.get("photo_selection", "automatic") != "automatic"
    ):
        raise EvidenceError(
            "photo permutation evidence requires unordered automatic photo selection"
        )
    binding = _mapping(request.get("binding"), "photo permutation request binding")
    scale = binding.get("scale")
    seed = configuration.get("run_seed")
    if type(scale) is not int or scale < 2:
        raise EvidenceError("photo permutation request scale must be at least 2")
    if type(seed) is not int or seed < 0:
        raise EvidenceError("photo permutation request seed must be nonnegative")
    return scale, seed, sha256_bytes(canonical_json_bytes(configuration))


def photo_permutation_request_binding_sha256(request: Mapping[str, Any]) -> str:
    """Bind every identity-bearing request field without exposing source media."""
    value = {
        field: request.get(field)
        for field in (
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
            "video_source_count",
            "gate_scopes",
            "rendering_driver_identity",
        )
    }
    return sha256_bytes(canonical_json_bytes(value))


def photo_permutation_producer_implementation_sha256() -> str:
    """Return the exact checkout closure used by the photo evidence producer."""
    repository_root = Path(__file__).resolve().parents[2]
    records: list[dict[str, Any]] = []
    for label, relative_path in (
        ("photo_permutation_producer.py", PHOTO_PERMUTATION_PRODUCER_RELATIVE_PATH),
        ("evidence_protocol.py", PRODUCER_RELATIVE_PATH),
    ):
        path = repository_root / relative_path
        try:
            metadata = path.lstat()
            if (
                path.is_symlink()
                or not stat.S_ISREG(metadata.st_mode)
                or not 0 < metadata.st_size <= 64 * 1024 * 1024
            ):
                raise EvidenceError("photo permutation producer closure is unsafe")
            contents = path.read_bytes()
            after = path.lstat()
        except OSError as error:
            raise EvidenceError(
                "photo permutation producer closure is unavailable"
            ) from error
        if (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ) or len(contents) != metadata.st_size:
            raise EvidenceError(
                "photo permutation producer closure changed during read"
            )
        records.append(
            {
                "label": label,
                "bytes": len(contents),
                "sha256": sha256_bytes(contents),
            }
        )
    return sha256_bytes(canonical_json_bytes(records))


def _validate_photo_permutation_variant(
    value: Any,
    *,
    position: int,
    expected_scale: int,
    expected_seed: int,
    expected_plan_digest: str,
) -> dict[str, Any]:
    label = f"photo permutation variants[{position}]"
    record = _mapping(value, label)
    _exact_keys(
        record,
        {
            "group_id",
            "variant_id",
            "permutation",
            "order_commitment",
            "content_set_attestation",
            "canonical_observation_attestation",
            "source_kind",
            "selected_content_ids",
            "registered_content_ids",
            "selected_content_set_sha256",
            "registered_content_set_sha256",
            "normalized_pair_graph_sha256",
            "normalized_pair_edges",
            "requested_plan_sha256",
            "scale",
            "run_seed",
            "pairing_policy",
            "accepted_attempt",
            "scheduled_pair_count",
            "scheduled_pair_graph_sha256",
            "attempted_pair_count",
            "attempted_pair_graph_sha256",
            "raw_matched_pair_count",
            "raw_matched_pair_graph_sha256",
            "spatially_verified_pair_count",
            "retrieval_worker_executed",
            "pair_counts",
            "registered_views",
            "point_count",
            "observation_count",
            "residual_median_pixels",
            "residual_p90_pixels",
            "camera_center_p95_scene_radius_fraction",
            "rotation_p95_degrees",
        },
        label,
    )
    group_id = _token(record["group_id"], f"{label}.group_id")
    variant_id = _token(record["variant_id"], f"{label}.variant_id")
    permutation = _mapping(record["permutation"], f"{label}.permutation")
    kind = permutation.get("kind")
    if kind == "canonical":
        _exact_keys(permutation, {"kind"}, f"{label}.permutation")
        permutation_index: int | None = None
        permutation_seed: int | None = None
    elif kind == "shuffled":
        _exact_keys(
            permutation,
            {"kind", "index", "seed"},
            f"{label}.permutation",
        )
        permutation_index = permutation["index"]
        permutation_seed = permutation["seed"]
        if (
            type(permutation_index) is not int
            or permutation_index < 1
            or type(permutation_seed) is not int
            or permutation_seed < 0
        ):
            raise EvidenceError(
                f"{label}.permutation shuffled index and seed must be nonnegative integers"
            )
    else:
        raise EvidenceError(f"{label}.permutation kind is invalid")

    source_kind = record["source_kind"]
    if source_kind not in PHOTO_PERMUTATION_SOURCE_KINDS:
        raise EvidenceError(f"{label}.source_kind is invalid")
    scale = record["scale"]
    run_seed = record["run_seed"]
    if scale != expected_scale or run_seed != expected_seed:
        raise EvidenceError(
            "photo permutation variants must share the requested scale and run seed"
        )
    if record["requested_plan_sha256"] != expected_plan_digest:
        raise EvidenceError(
            "photo permutation variants must share the requested run plan"
        )
    _opaque_digest(record["order_commitment"], f"{label}.order_commitment")
    content_attestation = _opaque_digest(
        record["content_set_attestation"],
        f"{label}.content_set_attestation",
    )
    canonical_observation_attestation = _opaque_digest(
        record["canonical_observation_attestation"],
        f"{label}.canonical_observation_attestation",
    )
    selected_ids = record["selected_content_ids"]
    if (
        not isinstance(selected_ids, list)
        or len(selected_ids) != expected_scale
        or selected_ids != sorted(selected_ids)
        or len(selected_ids) != len(set(selected_ids))
    ):
        raise EvidenceError(
            f"{label}.selected_content_ids must bind every selected view exactly once"
        )
    normalized_selected_ids = [
        _opaque_digest(content_id, f"{label}.selected_content_ids[{index}]")
        for index, content_id in enumerate(selected_ids)
    ]
    registered_ids = record["registered_content_ids"]
    if (
        not isinstance(registered_ids, list)
        or registered_ids != sorted(registered_ids)
        or len(registered_ids) != len(set(registered_ids))
    ):
        raise EvidenceError(f"{label}.registered_content_ids must be sorted and unique")
    normalized_registered_ids = [
        _opaque_digest(content_id, f"{label}.registered_content_ids[{index}]")
        for index, content_id in enumerate(registered_ids)
    ]
    if not set(normalized_registered_ids).issubset(normalized_selected_ids):
        raise EvidenceError(
            f"{label}.registered content IDs must be selected content IDs"
        )
    selected_digest = _opaque_digest(
        record["selected_content_set_sha256"],
        f"{label}.selected_content_set_sha256",
    )
    registered_digest = _opaque_digest(
        record["registered_content_set_sha256"],
        f"{label}.registered_content_set_sha256",
    )
    if selected_digest != _photo_content_set_digest(normalized_selected_ids):
        raise EvidenceError(
            f"{label}.selected_content_set_sha256 does not match selected content IDs"
        )
    if registered_digest != _photo_content_set_digest(normalized_registered_ids):
        raise EvidenceError(
            f"{label}.registered_content_set_sha256 does not match registered content IDs"
        )
    pair_graph_digest = _opaque_digest(
        record["normalized_pair_graph_sha256"],
        f"{label}.normalized_pair_graph_sha256",
    )
    edges = record["normalized_pair_edges"]
    if not isinstance(edges, list) or not edges:
        raise EvidenceError(
            f"{label}.normalized_pair_edges must be a sorted unique nonempty array"
        )
    normalized_edges: list[dict[str, str]] = []
    selected_id_set = set(normalized_selected_ids)
    for index, raw_edge in enumerate(edges):
        edge_label = f"{label}.normalized_pair_edges[{index}]"
        edge = _mapping(raw_edge, edge_label)
        _exact_keys(edge, {"content_a", "content_b", "edge_id"}, edge_label)
        content_a = _opaque_digest(edge["content_a"], f"{edge_label}.content_a")
        content_b = _opaque_digest(edge["content_b"], f"{edge_label}.content_b")
        edge_id = _opaque_digest(edge["edge_id"], f"{edge_label}.edge_id")
        if (
            content_a >= content_b
            or content_a not in selected_id_set
            or content_b not in selected_id_set
        ):
            raise EvidenceError(
                f"{edge_label} must reference two ordered selected content IDs"
            )
        if edge_id != _photo_pair_edge_id(content_a, content_b):
            raise EvidenceError(f"{edge_label}.edge_id is not bound to its endpoints")
        normalized_edges.append(
            {"content_a": content_a, "content_b": content_b, "edge_id": edge_id}
        )
    edge_ids = [edge["edge_id"] for edge in normalized_edges]
    if edge_ids != sorted(edge_ids) or len(edge_ids) != len(set(edge_ids)):
        raise EvidenceError(
            f"{label}.normalized_pair_edges must be sorted and unique by edge_id"
        )
    if pair_graph_digest != _photo_pair_graph_digest(edge_ids):
        raise EvidenceError(
            f"{label}.normalized_pair_graph_sha256 does not match its opaque edge set"
        )
    adjacency = {content_id: set() for content_id in normalized_selected_ids}
    for edge in normalized_edges:
        adjacency[edge["content_a"]].add(edge["content_b"])
        adjacency[edge["content_b"]].add(edge["content_a"])
    reached = {normalized_selected_ids[0]}
    pending = [normalized_selected_ids[0]]
    while pending:
        current = pending.pop()
        for neighbor in adjacency[current]:
            if neighbor not in reached:
                reached.add(neighbor)
                pending.append(neighbor)
    if len(reached) != len(normalized_selected_ids):
        raise EvidenceError(
            f"{label} accepted pair graph must be connected across every selected photo"
        )

    pair_counts = _mapping(record["pair_counts"], f"{label}.pair_counts")
    count_fields = {
        "temporal",
        "vocabulary_retrieval",
        "loop_revisit",
        "exhaustive_primary",
        "exhaustive_recovery",
    }
    _exact_keys(pair_counts, count_fields, f"{label}.pair_counts")
    if any(
        type(pair_counts[field]) is not int or pair_counts[field] < 0
        for field in count_fields
    ):
        raise EvidenceError(f"{label}.pair_counts must be nonnegative integers")
    if sum(pair_counts.values()) != len(normalized_edges):
        raise EvidenceError(
            f"{label}.pair_counts must account for every normalized edge"
        )
    scheduled_pair_count = record["scheduled_pair_count"]
    scheduled_pair_graph = _opaque_digest(
        record["scheduled_pair_graph_sha256"],
        f"{label}.scheduled_pair_graph_sha256",
    )
    attempted_pair_count = record["attempted_pair_count"]
    attempted_pair_graph = _opaque_digest(
        record["attempted_pair_graph_sha256"],
        f"{label}.attempted_pair_graph_sha256",
    )
    raw_matched_pair_count = record["raw_matched_pair_count"]
    raw_matched_pair_graph = _opaque_digest(
        record["raw_matched_pair_graph_sha256"],
        f"{label}.raw_matched_pair_graph_sha256",
    )
    spatially_verified_pair_count = record["spatially_verified_pair_count"]
    retrieval_worker_executed = record["retrieval_worker_executed"]
    if (
        type(scheduled_pair_count) is not int
        or scheduled_pair_count <= 0
        or scheduled_pair_count < len(normalized_edges)
        or type(attempted_pair_count) is not int
        or attempted_pair_count != scheduled_pair_count
        or attempted_pair_graph != scheduled_pair_graph
        or type(raw_matched_pair_count) is not int
        or type(spatially_verified_pair_count) is not int
        or not spatially_verified_pair_count
        <= raw_matched_pair_count
        <= attempted_pair_count
        or spatially_verified_pair_count != len(normalized_edges)
        or type(retrieval_worker_executed) is not bool
    ):
        raise EvidenceError(f"{label} attempted pair closure is invalid")
    if pair_counts["temporal"] != 0:
        raise EvidenceError("unordered photo evidence cannot claim temporal pairs")
    if expected_scale > 250 and record["accepted_attempt"] == "exhaustive_recovery":
        raise EvidenceError("exhaustive recovery is unavailable above 250 views")
    if expected_scale <= 60:
        exhaustive_pair_count = expected_scale * (expected_scale - 1) // 2
        exhaustive_edge_ids = sorted(
            _photo_pair_edge_id(first, second)
            for first, second in itertools.combinations(
                normalized_selected_ids,
                2,
            )
        )
        if (
            record["pairing_policy"] != "unordered_exhaustive"
            or record["accepted_attempt"] != "exhaustive_primary"
            or scheduled_pair_count != exhaustive_pair_count
            or scheduled_pair_graph != _photo_pair_graph_digest(exhaustive_edge_ids)
            or retrieval_worker_executed
            or pair_counts["exhaustive_primary"] <= 0
            or pair_counts["vocabulary_retrieval"] != 0
            or pair_counts["exhaustive_recovery"] != 0
        ):
            raise EvidenceError(
                "unordered photo evidence at 60 or fewer views must use the complete "
                "exhaustive primary FAISS graph"
            )
    elif (
        record["pairing_policy"] != "unordered_retrieval"
        or record["accepted_attempt"] != "vocabulary_retrieval"
        or scheduled_pair_count < expected_scale
        or not retrieval_worker_executed
        or pair_counts["vocabulary_retrieval"] <= 0
        or pair_counts["exhaustive_primary"] != 0
    ):
        raise EvidenceError(
            "unordered photo evidence at more than 60 views must be accepted from vocabulary retrieval"
        )
    if expected_scale > 60 and pair_counts["exhaustive_recovery"] != 0:
        raise EvidenceError(
            "retrieval evidence requires zero exhaustive recovery pairs"
        )
    registered_views = record["registered_views"]
    if type(registered_views) is not int or registered_views != len(
        normalized_registered_ids
    ):
        raise EvidenceError(f"{label}.registered_views is invalid")
    if registered_views * 10 < expected_scale * 9:
        raise EvidenceError(
            f"{label} absolute registration coverage is below 90 percent"
        )
    point_count = record["point_count"]
    observation_count = record["observation_count"]
    if (
        type(point_count) is not int
        or point_count <= 0
        or type(observation_count) is not int
        or observation_count <= 0
    ):
        raise EvidenceError(f"{label} sparse geometry counts must be positive")
    residual_median = _nonnegative_number(
        record["residual_median_pixels"],
        f"{label}.residual_median_pixels",
    )
    residual_p90 = _nonnegative_number(
        record["residual_p90_pixels"],
        f"{label}.residual_p90_pixels",
    )
    if residual_p90 < residual_median:
        raise EvidenceError(f"{label} p90 residual cannot be below its median")
    if residual_median > 1.5 + 1e-12:
        raise EvidenceError(f"{label} median residual exceeds 1.5 px")
    if residual_p90 > 3.0 + 1e-12:
        raise EvidenceError(f"{label} p90 residual exceeds 3.0 px")
    camera_center_p95 = _nonnegative_number(
        record["camera_center_p95_scene_radius_fraction"],
        f"{label}.camera_center_p95_scene_radius_fraction",
    )
    rotation_p95 = _nonnegative_number(
        record["rotation_p95_degrees"],
        f"{label}.rotation_p95_degrees",
    )
    return {
        **dict(record),
        "group_id": group_id,
        "variant_id": variant_id,
        "permutation_index": permutation_index,
        "permutation_seed": permutation_seed,
        "source_kind": source_kind,
        "selected_content_ids": normalized_selected_ids,
        "registered_content_ids": normalized_registered_ids,
        "content_set_attestation": content_attestation,
        "canonical_observation_attestation": canonical_observation_attestation,
        "selected_content_set_sha256": selected_digest,
        "registered_content_set_sha256": registered_digest,
        "normalized_pair_graph_sha256": pair_graph_digest,
        "normalized_pair_edges": normalized_edges,
        "normalized_pair_edge_ids": edge_ids,
        "scheduled_pair_graph_sha256": scheduled_pair_graph,
        "attempted_pair_graph_sha256": attempted_pair_graph,
        "raw_matched_pair_graph_sha256": raw_matched_pair_graph,
        "registered_views": registered_views,
        "point_count": point_count,
        "observation_count": observation_count,
        "residual_median_pixels": residual_median,
        "residual_p90_pixels": residual_p90,
        "camera_center_p95_scene_radius_fraction": camera_center_p95,
        "rotation_p95_degrees": rotation_p95,
    }


def validate_photo_permutation_group(
    value: Any,
    request: Mapping[str, Any],
    *,
    formal_release: bool,
    execution_receipt: Any | None = None,
) -> dict[str, Any]:
    """Validate one logical unordered-photo scene across filename permutations."""
    scale, run_seed, plan_digest = _photo_permutation_request_contract(request)
    group = _mapping(value, "photo permutation evidence")
    _exact_keys(
        group,
        {
            "schema_version",
            "mode",
            "expected_variant_count",
            "closure_claims",
            "variants",
            "execution_provenance",
        },
        "photo permutation evidence",
    )
    if group["schema_version"] != 1:
        raise EvidenceError("photo permutation evidence schema_version must be 1")
    expected_count = group["expected_variant_count"]
    if type(expected_count) is not int or expected_count < 2 or expected_count > 100:
        raise EvidenceError("photo permutation expected variant count is invalid")
    mode = group["mode"]
    if formal_release:
        if (
            mode != "release"
            or expected_count != PHOTO_PERMUTATION_FORMAL_VARIANT_COUNT
        ):
            raise EvidenceError("formal release evidence requires exactly 20 variants")
    elif mode != "development":
        raise EvidenceError(
            "non-release permutation evidence must use explicit development mode"
        )
    claims = group["closure_claims"]
    allowed_claims = {"order_mechanics", "professional_photo", "raw_camera_metadata"}
    if (
        not isinstance(claims, list)
        or not claims
        or claims != sorted(claims)
        or len(claims) != len(set(claims))
        or any(claim not in allowed_claims for claim in claims)
        or "order_mechanics" not in claims
    ):
        raise EvidenceError("photo permutation closure claims are invalid")
    variants = group["variants"]
    if not isinstance(variants, list) or len(variants) != expected_count:
        raise EvidenceError(
            "photo permutation variants must match expected_variant_count"
        )
    normalized = [
        _validate_photo_permutation_variant(
            raw,
            position=index,
            expected_scale=scale,
            expected_seed=run_seed,
            expected_plan_digest=plan_digest,
        )
        for index, raw in enumerate(variants)
    ]
    provenance = _mapping(
        group["execution_provenance"],
        "photo permutation execution provenance",
    )
    provenance_fields = {
        "schema_version",
        "group_contract_sha256",
        "request_binding_sha256",
        "source_authorization_sha256",
        "source_kind",
        "source_provenance_commitment",
        "trust_boundary",
        "producer_implementation_sha256",
        "adapter_sha256",
        "toolchain_closure_sha256",
        "variant_schedule_sha256",
        "variant_receipts_sha256",
        "execution_receipt_sha256",
    }
    _exact_keys(
        provenance,
        provenance_fields,
        "photo permutation execution provenance",
    )
    if provenance["schema_version"] != 1:
        raise EvidenceError("photo permutation execution provenance schema is invalid")
    for field in provenance_fields - {
        "schema_version",
        "source_kind",
        "source_provenance_commitment",
        "trust_boundary",
    }:
        _digest(provenance[field], f"photo permutation execution provenance.{field}")
    if provenance["source_kind"] not in PHOTO_PERMUTATION_SOURCE_KINDS:
        raise EvidenceError(
            "photo permutation execution provenance source kind is invalid"
        )
    _opaque_digest(
        provenance["source_provenance_commitment"],
        "photo permutation execution provenance.source_provenance_commitment",
    )
    if provenance["trust_boundary"] != "requires_github_artifact_attestation":
        raise EvidenceError(
            "photo permutation execution provenance trust boundary is invalid"
        )
    if execution_receipt is None:
        raise EvidenceError("photo permutation execution receipt is required")
    receipt = _mapping(
        execution_receipt,
        "photo permutation execution receipt",
    )
    receipt_fields = {
        "schema_version",
        "kind",
        "group_contract_sha256",
        "request_binding_sha256",
        "source_authorization_sha256",
        "source_kind",
        "source_provenance_commitment",
        "trust_boundary",
        "producer_implementation_sha256",
        "adapter_sha256",
        "toolchain_closure_sha256",
        "variant_schedule_sha256",
        "variant_receipts",
        "variant_receipts_sha256",
        "group_payload_sha256",
    }
    _exact_keys(receipt, receipt_fields, "photo permutation execution receipt")
    if (
        receipt["schema_version"] != 1
        or receipt["kind"] != "easysplat-photo-permutation-execution-receipt"
    ):
        raise EvidenceError("photo permutation execution receipt schema is invalid")
    for field in receipt_fields - {
        "schema_version",
        "kind",
        "source_kind",
        "source_provenance_commitment",
        "trust_boundary",
        "variant_receipts",
    }:
        _digest(receipt[field], f"photo permutation execution receipt.{field}")
    if receipt["source_kind"] not in PHOTO_PERMUTATION_SOURCE_KINDS:
        raise EvidenceError(
            "photo permutation execution receipt source kind is invalid"
        )
    _opaque_digest(
        receipt["source_provenance_commitment"],
        "photo permutation execution receipt.source_provenance_commitment",
    )
    if receipt["trust_boundary"] != "requires_github_artifact_attestation":
        raise EvidenceError(
            "photo permutation execution receipt trust boundary is invalid"
        )
    receipt_digest = sha256_bytes(canonical_json_bytes(receipt) + b"\n")
    if provenance["execution_receipt_sha256"] != receipt_digest:
        raise EvidenceError("photo permutation execution receipt digest is invalid")
    for field in (
        "group_contract_sha256",
        "request_binding_sha256",
        "source_authorization_sha256",
        "source_kind",
        "source_provenance_commitment",
        "trust_boundary",
        "producer_implementation_sha256",
        "adapter_sha256",
        "toolchain_closure_sha256",
        "variant_schedule_sha256",
        "variant_receipts_sha256",
    ):
        if provenance[field] != receipt[field]:
            raise EvidenceError(
                "photo permutation execution provenance does not match its receipt"
            )
    if receipt["request_binding_sha256"] != photo_permutation_request_binding_sha256(
        request
    ):
        raise EvidenceError(
            "photo permutation execution receipt request binding is invalid"
        )
    if (
        receipt["producer_implementation_sha256"]
        != photo_permutation_producer_implementation_sha256()
    ):
        raise EvidenceError(
            "photo permutation producer implementation does not match this checkout"
        )
    if receipt["source_kind"] != normalized[0]["source_kind"]:
        raise EvidenceError(
            "photo permutation source provenance does not match its variants"
        )
    variant_ids = [record["variant_id"] for record in normalized]
    if len(variant_ids) != len(set(variant_ids)):
        raise EvidenceError("photo permutation variant IDs must be unique")
    group_payload = {key: group[key] for key in group if key != "execution_provenance"}
    if receipt["group_payload_sha256"] != sha256_bytes(
        canonical_json_bytes(group_payload)
    ):
        raise EvidenceError(
            "photo permutation execution receipt does not bind the group"
        )
    schedule = [
        {
            "variant_id": record["variant_id"],
            "permutation": record["permutation"],
        }
        for record in normalized
    ]
    if receipt["variant_schedule_sha256"] != sha256_bytes(
        canonical_json_bytes(schedule)
    ):
        raise EvidenceError("photo permutation execution receipt schedule is invalid")
    raw_slot_receipts = receipt["variant_receipts"]
    if not isinstance(raw_slot_receipts, list) or len(raw_slot_receipts) != len(
        normalized
    ):
        raise EvidenceError("photo permutation variant receipts are incomplete")
    slot_receipts: list[dict[str, str]] = []
    for index, (raw_slot, raw_variant) in enumerate(
        zip(raw_slot_receipts, variants, strict=True)
    ):
        slot = _mapping(
            raw_slot,
            f"photo permutation variant receipts[{index}]",
        )
        _exact_keys(
            slot,
            {"variant_id", "public_variant_sha256", "receipt_sha256"},
            f"photo permutation variant receipts[{index}]",
        )
        variant_id = _token(
            slot["variant_id"],
            f"photo permutation variant receipts[{index}].variant_id",
        )
        public_digest = _digest(
            slot["public_variant_sha256"],
            f"photo permutation variant receipts[{index}].public_variant_sha256",
        )
        receipt_file_digest = _digest(
            slot["receipt_sha256"],
            f"photo permutation variant receipts[{index}].receipt_sha256",
        )
        if variant_id != normalized[index][
            "variant_id"
        ] or public_digest != sha256_bytes(canonical_json_bytes(raw_variant)):
            raise EvidenceError(
                "photo permutation variant receipt does not bind its public payload"
            )
        slot_receipts.append(
            {
                "variant_id": variant_id,
                "public_variant_sha256": public_digest,
                "receipt_sha256": receipt_file_digest,
            }
        )
    if len({slot["receipt_sha256"] for slot in slot_receipts}) != len(slot_receipts):
        raise EvidenceError("photo permutation variant receipt digests must be unique")
    if receipt["variant_receipts_sha256"] != sha256_bytes(
        canonical_json_bytes(slot_receipts)
    ):
        raise EvidenceError("photo permutation variant receipt closure is invalid")
    if mode == "release":
        expected_schedule: list[tuple[str, int | None, int | None]] = [
            ("canonical", None, None)
        ] + [
            ("shuffled", index, photo_permutation_release_seed(index))
            for index in range(1, PHOTO_PERMUTATION_FORMAL_SHUFFLE_COUNT + 1)
        ]
        actual_schedule = [
            (
                record["permutation"]["kind"],
                record["permutation_index"],
                record["permutation_seed"],
            )
            for record in normalized
        ]
        if actual_schedule != expected_schedule:
            raise EvidenceError(
                "formal photo permutation evidence requires the fixed canonical and "
                "shuffled index/seed schedule"
            )
    order_commitments = [record["order_commitment"] for record in normalized]
    if len(order_commitments) != len(set(order_commitments)):
        raise EvidenceError("photo permutation order commitments must be unique")
    shuffled_coordinates = [
        (record["permutation_index"], record["permutation_seed"])
        for record in normalized
        if record["permutation"]["kind"] == "shuffled"
    ]
    if len(shuffled_coordinates) != len(set(shuffled_coordinates)):
        raise EvidenceError("photo permutation index and seed pairs must be unique")
    canonical = [
        record for record in normalized if record["permutation"]["kind"] == "canonical"
    ]
    if len(canonical) != 1:
        raise EvidenceError(
            "photo permutation evidence requires exactly one canonical variant"
        )
    reference = canonical[0]

    group_ids = {record["group_id"] for record in normalized}
    content_attestations = {record["content_set_attestation"] for record in normalized}
    canonical_observation_attestations = {
        record["canonical_observation_attestation"] for record in normalized
    }
    source_kinds = {record["source_kind"] for record in normalized}
    selected_sets = {record["selected_content_set_sha256"] for record in normalized}
    selected_id_sets = {tuple(record["selected_content_ids"]) for record in normalized}
    scheduled_pair_closures = {
        (
            record["scheduled_pair_count"],
            record["scheduled_pair_graph_sha256"],
            record["attempted_pair_count"],
            record["attempted_pair_graph_sha256"],
        )
        for record in normalized
    }
    if len(group_ids) != 1:
        raise EvidenceError("photo permutation variants must share one opaque group ID")
    if len(content_attestations) != 1:
        raise EvidenceError(
            "photo permutation variants have a mismatched protected content-set attestation"
        )
    if len(canonical_observation_attestations) != 1:
        raise EvidenceError(
            "photo permutation variants have a mismatched canonical observation attestation"
        )
    if len(source_kinds) != 1:
        raise EvidenceError("photo permutation variants must share one source kind")
    if len(selected_sets) != 1 or len(selected_id_sets) != 1:
        raise EvidenceError(
            "automatic photo selection changed the selected content set across permutations"
        )
    if scale <= 60 and len(scheduled_pair_closures) != 1:
        raise EvidenceError(
            "photo permutation scheduled or attempted pair closure changed"
        )
    source_kind = next(iter(source_kinds))
    category = request.get("category")
    professional_claim = category == "professional_photos" or bool(
        {"professional_photo", "raw_camera_metadata"} & set(claims)
    )
    if source_kind != "native_photos" and professional_claim:
        raise EvidenceError(
            "non-native still controls cannot satisfy professional photo or RAW metadata closure"
        )

    reference_edges = set(reference["normalized_pair_edge_ids"])
    reference_registered = set(reference["registered_content_ids"])
    jaccards: list[float] = []
    registered_losses: list[int] = []
    registered_content_lost: list[int] = []
    registered_content_gained: list[int] = []
    registered_content_symmetric_differences: list[int] = []
    median_deltas: list[float] = []
    p90_deltas: list[float] = []
    point_count_delta_fractions: list[float] = []
    observation_count_delta_fractions: list[float] = []
    for record in normalized:
        registered_loss = reference["registered_views"] - record["registered_views"]
        registered_losses.append(registered_loss)
        if registered_loss > 1:
            raise EvidenceError("photo permutation registered-view loss exceeds 1")
        registered = set(record["registered_content_ids"])
        lost_count = len(reference_registered - registered)
        gained_count = len(registered - reference_registered)
        symmetric_difference = lost_count + gained_count
        registered_content_lost.append(lost_count)
        registered_content_gained.append(gained_count)
        registered_content_symmetric_differences.append(symmetric_difference)
        if symmetric_difference != 0:
            raise EvidenceError(
                "photo permutation registered content set changed; filename-invariance "
                "evidence requires the same registered views"
            )
        median_delta = abs(
            record["residual_median_pixels"] - reference["residual_median_pixels"]
        )
        p90_delta = abs(
            record["residual_p90_pixels"] - reference["residual_p90_pixels"]
        )
        median_deltas.append(median_delta)
        p90_deltas.append(p90_delta)
        if median_delta > 0.05 + 1e-12:
            raise EvidenceError(
                "photo permutation median residual delta exceeds 0.05 px"
            )
        if p90_delta > 0.10 + 1e-12:
            raise EvidenceError("photo permutation p90 residual delta exceeds 0.10 px")
        for field, deltas, label in (
            ("point_count", point_count_delta_fractions, "point"),
            (
                "observation_count",
                observation_count_delta_fractions,
                "observation",
            ),
        ):
            reference_count = reference[field]
            count_delta = abs(record[field] - reference_count)
            delta_fraction = count_delta / reference_count
            deltas.append(delta_fraction)
            if count_delta * 100 > reference_count:
                raise EvidenceError(
                    f"photo permutation {label} count delta exceeds 1 percent"
                )
        if record["camera_center_p95_scene_radius_fraction"] > 0.01 + 1e-12:
            raise EvidenceError("photo permutation camera-center deviation exceeds 1%")
        if record["rotation_p95_degrees"] > 0.20 + 1e-12:
            raise EvidenceError(
                "photo permutation rotation deviation exceeds 0.2 degrees"
            )
        if scale > 60:
            edges = set(record["normalized_pair_edge_ids"])
            union = reference_edges | edges
            jaccard = len(reference_edges & edges) / len(union)
            jaccards.append(jaccard)
            if jaccard < 0.98 - 1e-12:
                raise EvidenceError(
                    "photo permutation pair-graph Jaccard is below 0.98"
                )
    return {
        "group_id": next(iter(group_ids)),
        "source_kind": source_kind,
        "variant_count": len(normalized),
        "scale": scale,
        "run_seed": run_seed,
        "requested_plan_sha256": plan_digest,
        "canonical_observation_attestation": next(
            iter(canonical_observation_attestations)
        ),
        "execution_receipt_sha256": receipt_digest,
        "minimum_pair_graph_jaccard": min(jaccards) if jaccards else None,
        "maximum_registered_view_loss": max(registered_losses),
        "maximum_registered_content_lost": max(registered_content_lost),
        "maximum_registered_content_gained": max(registered_content_gained),
        "maximum_registered_content_symmetric_difference": max(
            registered_content_symmetric_differences
        ),
        "maximum_median_residual_delta_pixels": max(median_deltas),
        "maximum_p90_residual_delta_pixels": max(p90_deltas),
        "maximum_point_count_delta_fraction": max(point_count_delta_fractions),
        "maximum_observation_count_delta_fraction": max(
            observation_count_delta_fractions
        ),
    }


def aggregate_photo_permutation_group(
    value: Any,
    request: Mapping[str, Any],
    *,
    formal_release: bool,
    execution_receipt: Any,
) -> dict[str, Any]:
    """Return the bounded cross-variant summary after validating the full group."""
    return validate_photo_permutation_group(
        value,
        request,
        formal_release=formal_release,
        execution_receipt=execution_receipt,
    )


def validate_photo_permutation_release_coverage(
    receipts: Iterable[Mapping[str, Any]],
) -> dict[str, Any]:
    """Require healthy native-photo order evidence for both pairing regimes."""
    native_groups: dict[str, dict[str, Any]] = {}
    execution_receipt_digests: set[str] = set()
    for position, raw_receipt in enumerate(receipts):
        receipt = _mapping(raw_receipt, f"release evidence receipts[{position}]")
        group = receipt.get("photo_permutation")
        execution_receipt = receipt.get("photo_permutation_execution_receipt")
        source_authorization = receipt.get("photo_permutation_source_authorization")
        if group is None and execution_receipt is None and source_authorization is None:
            continue
        if group is None or execution_receipt is None or source_authorization is None:
            raise EvidenceError(
                "release photo permutation evidence, execution receipt, and source "
                "authorization must be paired"
            )
        validated_source_authorization = (
            validate_photo_permutation_source_authorization(
                source_authorization,
                execution_receipt,
                receipt,
            )
        )
        validate_photo_permutation_supervisor_provenance(
            receipt.get("photo_permutation_supervisor_provenance"),
            execution_receipt,
            receipt,
            validated_source_authorization,
        )
        summary = validate_photo_permutation_group(
            group,
            receipt,
            formal_release=True,
            execution_receipt=execution_receipt,
        )
        execution_digest = summary["execution_receipt_sha256"]
        if execution_digest in execution_receipt_digests:
            raise EvidenceError(
                "release photo permutation execution receipts must be unique"
            )
        execution_receipt_digests.add(execution_digest)
        if summary["source_kind"] != "native_photos":
            continue
        if validated_source_authorization["source_kind"] != "native_photos":
            continue
        binding = _mapping(
            receipt.get("binding"),
            f"release evidence receipts[{position}].binding",
        )
        expected_outcome = _mapping(
            receipt.get("expected_outcome"),
            f"release evidence receipts[{position}].expected_outcome",
        )
        capture_traits = receipt.get("capture_traits")
        if (
            receipt.get("lane") != LANE_REFERENCE
            or binding.get("lane") != LANE_REFERENCE
            or binding.get("profile") != "release"
            or receipt.get("category") != "professional_photos"
            or receipt.get("input_kind") != "photos"
            or not isinstance(capture_traits, list)
            or "unordered" not in capture_traits
            or expected_outcome.get("kind") != "valid"
        ):
            continue
        if summary["scale"] == 30:
            regime = "small_exhaustive"
        elif summary["scale"] == 120:
            regime = "large_retrieval"
        else:
            continue
        native_groups.setdefault(
            regime,
            {
                "group_id": summary["group_id"],
                "scale": summary["scale"],
                "execution_receipt_sha256": execution_digest,
            },
        )

    missing = [
        label
        for regime, label in (
            ("small_exhaustive", "small native-photo exhaustive"),
            ("large_retrieval", "large native-photo retrieval"),
        )
        if regime not in native_groups
    ]
    if missing:
        raise EvidenceError(
            "release evidence requires "
            + " and ".join(missing)
            + " photo permutation groups"
        )
    return {
        "source_kind": "native_photos",
        "small_exhaustive": native_groups["small_exhaustive"],
        "large_retrieval": native_groups["large_retrieval"],
    }


def validate_photo_permutation_supervisor_provenance(
    value: Any,
    execution_receipt: Any,
    request: Mapping[str, Any],
    source_authorization: Any,
) -> dict[str, Any]:
    provenance = _mapping(value, "photo permutation supervisor provenance")
    fields = {
        "schema_version",
        "status",
        "repository",
        "signer_workflow",
        "source_commit",
        "source_ref",
        "subject_sha256",
        "bundle_sha256",
        "verified_attestation_count",
        "source_authorization_subject_sha256",
        "source_authorization_bundle_sha256",
        "verified_source_authorization_attestation_count",
    }
    _exact_keys(provenance, fields, "photo permutation supervisor provenance")
    binding = _mapping(request.get("binding"), "photo permutation request binding")
    if (
        provenance["schema_version"] != 1
        or provenance["status"] != "verified"
        or provenance["repository"] != PHOTO_PERMUTATION_ATTESTATION_REPOSITORY
        or provenance["signer_workflow"] != PHOTO_PERMUTATION_ATTESTATION_WORKFLOW
        or provenance["source_commit"] != binding.get("git_commit")
        or provenance["source_ref"] != "refs/heads/main"
        or type(provenance["verified_attestation_count"]) is not int
        or provenance["verified_attestation_count"] < 1
        or type(provenance["verified_source_authorization_attestation_count"])
        is not int
        or provenance["verified_source_authorization_attestation_count"] < 1
    ):
        raise EvidenceError("photo permutation supervisor provenance is invalid")
    subject_digest = _digest(
        provenance["subject_sha256"],
        "photo permutation supervisor provenance.subject_sha256",
    )
    _digest(
        provenance["bundle_sha256"],
        "photo permutation supervisor provenance.bundle_sha256",
    )
    source_authorization_subject = _digest(
        provenance["source_authorization_subject_sha256"],
        "photo permutation supervisor provenance.source_authorization_subject_sha256",
    )
    _digest(
        provenance["source_authorization_bundle_sha256"],
        "photo permutation supervisor provenance.source_authorization_bundle_sha256",
    )
    expected_subject = sha256_bytes(canonical_json_bytes(execution_receipt) + b"\n")
    if subject_digest != expected_subject:
        raise EvidenceError(
            "photo permutation supervisor provenance subject is invalid"
        )
    expected_source_authorization_subject = sha256_bytes(
        canonical_json_bytes(source_authorization) + b"\n"
    )
    if source_authorization_subject != expected_source_authorization_subject:
        raise EvidenceError(
            "photo permutation source authorization attestation subject is invalid"
        )
    return dict(provenance)


def validate_photo_permutation_source_authorization(
    value: Any,
    execution_receipt: Any,
    request: Mapping[str, Any],
) -> dict[str, Any]:
    authorization = _mapping(value, "photo permutation source authorization")
    fields = {
        "schema_version",
        "kind",
        "request_binding_sha256",
        "source_kind",
        "source_manifest_sha256",
        "source_content_set_sha256",
        "origin_evidence_sha256",
        "adapter_sha256",
        "toolchain_closure_sha256",
        "containment_supervisor_sha256",
        "containment_policy_sha256",
        "dedicated_uid",
        "gh_verifier_sha256",
        "source_commit",
        "source_ref",
    }
    _exact_keys(authorization, fields, "photo permutation source authorization")
    receipt = _mapping(execution_receipt, "photo permutation execution receipt")
    binding = _mapping(request.get("binding"), "photo permutation request binding")
    if (
        authorization["schema_version"] != 1
        or authorization["kind"] != "easysplat-photo-permutation-source-authorization"
        or authorization["request_binding_sha256"]
        != photo_permutation_request_binding_sha256(request)
        or authorization["source_kind"] != receipt.get("source_kind")
        or authorization["adapter_sha256"] != receipt.get("adapter_sha256")
        or authorization["toolchain_closure_sha256"]
        != receipt.get("toolchain_closure_sha256")
        or authorization["source_commit"] != binding.get("git_commit")
        or authorization["source_ref"] != "refs/heads/main"
        or type(authorization["dedicated_uid"]) is not int
        or authorization["dedicated_uid"] <= 0
    ):
        raise EvidenceError("photo permutation source authorization is invalid")
    for field in fields - {
        "schema_version",
        "kind",
        "source_kind",
        "dedicated_uid",
        "source_commit",
        "source_ref",
    }:
        _digest(authorization[field], f"photo permutation source authorization.{field}")
    artifact_digest = sha256_bytes(canonical_json_bytes(authorization) + b"\n")
    if receipt.get("source_authorization_sha256") != artifact_digest:
        raise EvidenceError(
            "photo permutation source authorization does not match its execution receipt"
        )
    return dict(authorization)


def _verify_photo_permutation_github_subject(
    subject: Any,
    subject_path: Path,
    bundle_path: Path,
    request: Mapping[str, Any],
    *,
    expected_subject_name: str,
    expected_bundle_name: str,
    gh_executable: Path | None,
    expected_gh_sha256: str | None,
) -> dict[str, Any]:
    binding = _mapping(request.get("binding"), "photo permutation request binding")
    source_commit = binding.get("git_commit")
    if (
        binding.get("profile") != "release"
        or binding.get("lane") != LANE_REFERENCE
        or not isinstance(source_commit, str)
        or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None
    ):
        raise EvidenceError(
            "GitHub-attested photo permutation evidence requires a release reference request"
        )
    if (
        subject_path.name != expected_subject_name
        or bundle_path.name != expected_bundle_name
        or subject_path.parent.resolve() != bundle_path.parent.resolve()
    ):
        raise EvidenceError("photo permutation attestation paths are not canonical")
    for path, label, maximum_bytes in (
        (
            subject_path,
            "photo permutation attestation subject artifact",
            MAX_ATTESTATION_BYTES,
        ),
        (
            bundle_path,
            "photo permutation attestation bundle",
            MAX_PHOTO_PERMUTATION_ATTESTATION_BUNDLE_BYTES,
        ),
    ):
        try:
            metadata = path.lstat()
        except OSError as error:
            raise EvidenceError(f"{label} is unavailable") from error
        if (
            path.is_symlink()
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or not 0 < metadata.st_size <= maximum_bytes
        ):
            raise EvidenceError(f"{label} is unsafe")
    stored_subject = _load_bounded_json(
        subject_path,
        "photo permutation attestation subject artifact",
        maximum_bytes=MAX_ATTESTATION_BYTES,
    )
    if stored_subject != subject:
        raise EvidenceError(
            "photo permutation attestation subject artifact does not match observations"
        )
    if sha256_file(subject_path) != sha256_bytes(canonical_json_bytes(subject) + b"\n"):
        raise EvidenceError(
            "photo permutation attestation subject artifact is not canonical JSON"
        )
    if gh_executable is None or expected_gh_sha256 is None:
        raise EvidenceError(
            "GitHub attestation verifier requires a protected executable and digest pin"
        )
    expected_digest = _digest(
        expected_gh_sha256,
        "photo permutation GitHub attestation verifier digest",
    )
    executable = Path(os.path.abspath(gh_executable))
    try:
        executable_metadata = executable.lstat()
    except OSError as error:
        raise EvidenceError("GitHub attestation verifier is unavailable") from error
    if (
        executable.is_symlink()
        or not stat.S_ISREG(executable_metadata.st_mode)
        or executable_metadata.st_nlink != 1
        or not os.access(executable, os.X_OK)
        or sha256_file(executable) != expected_digest
    ):
        raise EvidenceError("GitHub attestation verifier is unsafe")
    command = [
        str(executable),
        "attestation",
        "verify",
        str(subject_path),
        "--bundle",
        str(bundle_path),
        "--repo",
        PHOTO_PERMUTATION_ATTESTATION_REPOSITORY,
        "--signer-workflow",
        PHOTO_PERMUTATION_ATTESTATION_WORKFLOW,
        "--source-digest",
        source_commit,
        "--source-ref",
        "refs/heads/main",
        "--format",
        "json",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
            env={
                "HOME": os.environ.get("HOME", ""),
                "PATH": os.environ.get("PATH", ""),
                "GH_HOST": "github.com",
            },
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceError(
            "GitHub photo permutation attestation verification failed"
        ) from error
    if (
        completed.returncode != 0
        or len(completed.stdout.encode("utf-8")) > 8 * 1024 * 1024
    ):
        raise EvidenceError("GitHub photo permutation attestation verification failed")
    try:
        verified = json.loads(completed.stdout)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise EvidenceError(
            "GitHub photo permutation attestation verification output is invalid"
        ) from error
    if sha256_file(executable) != expected_digest:
        raise EvidenceError("GitHub attestation verifier changed during verification")
    subject_sha256 = sha256_file(subject_path)
    subject_hex = subject_sha256.removeprefix("sha256:")
    matching_attestations = 0
    if not isinstance(verified, list) or not verified:
        raise EvidenceError(
            "GitHub photo permutation attestation has no verified subject"
        )
    for raw in verified:
        if not isinstance(raw, dict):
            continue
        result = raw.get("verificationResult")
        statement = result.get("statement") if isinstance(result, dict) else None
        subjects = statement.get("subject") if isinstance(statement, dict) else None
        if not isinstance(subjects, list):
            continue
        if any(
            isinstance(subject, dict)
            and subject.get("name") == subject_path.name
            and isinstance(subject.get("digest"), dict)
            and subject["digest"].get("sha256") == subject_hex
            for subject in subjects
        ):
            matching_attestations += 1
    if matching_attestations < 1:
        raise EvidenceError(
            "GitHub photo permutation attestation subject does not match the execution receipt"
        )
    return {
        "subject_sha256": subject_sha256,
        "bundle_sha256": sha256_file(bundle_path),
        "verified_attestation_count": matching_attestations,
    }


def verify_photo_permutation_github_attestation(
    execution_receipt: Any,
    execution_receipt_path: Path,
    bundle_path: Path,
    request: Mapping[str, Any],
    *,
    gh_executable: Path | None = None,
    expected_gh_sha256: str | None = None,
) -> dict[str, Any]:
    """Verify the exact execution receipt with an externally pinned gh binary."""
    verified = _verify_photo_permutation_github_subject(
        execution_receipt,
        execution_receipt_path,
        bundle_path,
        request,
        expected_subject_name="photo-permutation-execution-receipt.json",
        expected_bundle_name="photo-permutation-attestation.jsonl",
        gh_executable=gh_executable,
        expected_gh_sha256=expected_gh_sha256,
    )
    binding = _mapping(request.get("binding"), "photo permutation request binding")
    return {
        "schema_version": 1,
        "status": "verified",
        "repository": PHOTO_PERMUTATION_ATTESTATION_REPOSITORY,
        "signer_workflow": PHOTO_PERMUTATION_ATTESTATION_WORKFLOW,
        "source_commit": binding["git_commit"],
        "source_ref": "refs/heads/main",
        **verified,
    }


def verify_photo_permutation_source_authorization_github_attestation(
    source_authorization: Any,
    source_authorization_path: Path,
    bundle_path: Path,
    request: Mapping[str, Any],
    *,
    gh_executable: Path | None = None,
    expected_gh_sha256: str | None = None,
) -> dict[str, Any]:
    """Verify the protected source classification and runtime authority artifact."""
    authorization = _mapping(
        source_authorization,
        "photo permutation source authorization",
    )
    if authorization.get("gh_verifier_sha256") != expected_gh_sha256:
        raise EvidenceError(
            "photo permutation source authorization does not bind the protected gh verifier"
        )
    return _verify_photo_permutation_github_subject(
        source_authorization,
        source_authorization_path,
        bundle_path,
        request,
        expected_subject_name="photo-permutation-source-authorization.json",
        expected_bundle_name=(
            "photo-permutation-source-authorization-attestation.jsonl"
        ),
        gh_executable=gh_executable,
        expected_gh_sha256=expected_gh_sha256,
    )


def verify_photo_permutation_github_attestations(
    execution_receipt: Any,
    execution_receipt_path: Path,
    execution_bundle_path: Path,
    source_authorization: Any,
    source_authorization_path: Path,
    source_authorization_bundle_path: Path,
    request: Mapping[str, Any],
    *,
    gh_executable: Path | None = None,
    expected_gh_sha256: str | None = None,
) -> dict[str, Any]:
    """Verify independently attested execution and source-authority subjects."""
    validated_authorization = validate_photo_permutation_source_authorization(
        source_authorization,
        execution_receipt,
        request,
    )
    execution = verify_photo_permutation_github_attestation(
        execution_receipt,
        execution_receipt_path,
        execution_bundle_path,
        request,
        gh_executable=gh_executable,
        expected_gh_sha256=expected_gh_sha256,
    )
    authorization = verify_photo_permutation_source_authorization_github_attestation(
        validated_authorization,
        source_authorization_path,
        source_authorization_bundle_path,
        request,
        gh_executable=gh_executable,
        expected_gh_sha256=expected_gh_sha256,
    )
    return {
        **execution,
        "source_authorization_subject_sha256": authorization["subject_sha256"],
        "source_authorization_bundle_sha256": authorization["bundle_sha256"],
        "verified_source_authorization_attestation_count": authorization[
            "verified_attestation_count"
        ],
    }


def _safe_photo_manifest_relative_path(value: Any, label: str) -> PurePosixPath:
    if not isinstance(value, str):
        raise EvidenceError(f"{label} must be a safe relative path")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or not path.parts
        or any(part in {"", ".", ".."} for part in path.parts)
        or value.startswith(("~", "\\"))
        or "\\" in value
    ):
        raise EvidenceError(f"{label} must be a safe relative path")
    return path


def build_photo_permutation_mapping(
    manifest: Any,
    *,
    scale: int,
    permutation_index: int,
    permutation_seed: int,
) -> dict[str, Any]:
    """Build a private mapping receipt without copying or modifying source media."""
    value = _mapping(manifest, "photo source manifest")
    _exact_keys(
        value,
        {"schema_version", "corpus_id", "entries"},
        "photo source manifest",
    )
    if value["schema_version"] != 1:
        raise EvidenceError("photo source manifest schema_version must be 1")
    corpus_id = _token(value["corpus_id"], "photo source manifest corpus_id")
    if (
        type(scale) is not int
        or scale < 2
        or type(permutation_index) is not int
        or permutation_index < 1
        or type(permutation_seed) is not int
        or permutation_seed < 0
    ):
        raise EvidenceError("photo permutation scale, index, and seed are invalid")
    entries = value["entries"]
    if not isinstance(entries, list) or not 2 <= len(entries) <= 100_000:
        raise EvidenceError("photo source manifest entries are invalid")
    source_paths: set[str] = set()
    source_digests: set[str] = set()
    ordered: list[tuple[str, str, str]] = []
    extension_aliases = {".jpeg": ".jpg", ".tiff": ".tif"}
    allowed_extensions = {
        ".arw",
        ".cr2",
        ".cr3",
        ".dng",
        ".heic",
        ".heif",
        ".jpg",
        ".jpeg",
        ".nef",
        ".orf",
        ".png",
        ".raf",
        ".rw2",
        ".tif",
        ".tiff",
    }
    for index, raw in enumerate(entries):
        label = f"photo source manifest entries[{index}]"
        entry = _mapping(raw, label)
        _exact_keys(entry, {"relative_path", "source_sha256"}, label)
        relative = _safe_photo_manifest_relative_path(
            entry["relative_path"], f"{label}.relative_path"
        )
        relative_string = relative.as_posix()
        if relative_string in source_paths:
            raise EvidenceError(
                "photo source manifest contains duplicate relative paths"
            )
        source_paths.add(relative_string)
        source_digest = _digest(entry["source_sha256"], f"{label}.source_sha256")
        if source_digest in source_digests:
            raise EvidenceError("photo source manifest source digest collision")
        source_digests.add(source_digest)
        extension = relative.suffix.lower()
        if extension not in allowed_extensions:
            raise EvidenceError(
                "photo source manifest contains an unsupported extension"
            )
        extension = extension_aliases.get(extension, extension)
        order_key = (
            "sha256:"
            + hashlib.sha256(
                b"easysplat-unordered-v1\0"
                + corpus_id.encode("utf-8")
                + b"\0"
                + str(scale).encode("ascii")
                + b"\0"
                + str(permutation_index).encode("ascii")
                + b"\0"
                + str(permutation_seed).encode("ascii")
                + b"\0"
                + source_digest.encode("ascii")
            ).hexdigest()
        )
        ordered.append((order_key, source_digest, extension))
    ordered.sort()
    mapped_entries = [
        {
            "source_sha256": source_digest,
            "order_key_sha256": order_key,
            "target_relative_path": f"photo-{position:06d}{extension}",
        }
        for position, (order_key, source_digest, extension) in enumerate(
            ordered, start=1
        )
    ]
    targets = [entry["target_relative_path"] for entry in mapped_entries]
    if len(targets) != len(set(targets)):
        raise EvidenceError("photo permutation target-name collision")
    order_manifest_sha256 = sha256_bytes(
        canonical_json_bytes(
            [
                {
                    "source_sha256": entry["source_sha256"],
                    "target_relative_path": entry["target_relative_path"],
                }
                for entry in mapped_entries
            ]
        )
    )
    receipt = {
        "schema_version": 1,
        "operation": "mapping_only",
        "corpus_id": corpus_id,
        "scale": scale,
        "permutation_index": permutation_index,
        "permutation_seed": permutation_seed,
        "order_manifest_sha256": order_manifest_sha256,
        "entries": mapped_entries,
    }
    if len(canonical_json_bytes(receipt)) + 1 > MAX_PHOTO_PERMUTATION_MAPPING_BYTES:
        raise EvidenceError("photo permutation mapping exceeds its bounded size")
    return receipt


def _validate_photo_permutation_mapping(value: Any) -> dict[str, Any]:
    receipt = _mapping(value, "photo permutation mapping")
    _exact_keys(
        receipt,
        {
            "schema_version",
            "operation",
            "corpus_id",
            "scale",
            "permutation_index",
            "permutation_seed",
            "order_manifest_sha256",
            "entries",
        },
        "photo permutation mapping",
    )
    if receipt["schema_version"] != 1 or receipt["operation"] != "mapping_only":
        raise EvidenceError("photo permutation mapping schema or operation is invalid")
    corpus_id = _token(receipt["corpus_id"], "photo permutation mapping corpus_id")
    scale = receipt["scale"]
    permutation_index = receipt["permutation_index"]
    permutation_seed = receipt["permutation_seed"]
    if (
        type(scale) is not int
        or scale < 2
        or type(permutation_index) is not int
        or permutation_index < 1
        or type(permutation_seed) is not int
        or permutation_seed < 0
    ):
        raise EvidenceError("photo permutation mapping coordinates are invalid")
    entries = receipt["entries"]
    if not isinstance(entries, list) or not 2 <= len(entries) <= 100_000:
        raise EvidenceError("photo permutation mapping entries are invalid")
    normalized_entries: list[dict[str, str]] = []
    seen_sources: set[str] = set()
    seen_targets: set[str] = set()
    previous_order_key = ""
    for position, raw in enumerate(entries, start=1):
        label = f"photo permutation mapping entries[{position - 1}]"
        entry = _mapping(raw, label)
        _exact_keys(
            entry,
            {"source_sha256", "order_key_sha256", "target_relative_path"},
            label,
        )
        source_digest = _digest(entry["source_sha256"], f"{label}.source_sha256")
        order_key = _digest(entry["order_key_sha256"], f"{label}.order_key_sha256")
        target = entry["target_relative_path"]
        if (
            not isinstance(target, str)
            or re.fullmatch(rf"photo-{position:06d}\.[a-z0-9]{{2,5}}", target) is None
        ):
            raise EvidenceError(f"{label}.target_relative_path is not canonical")
        expected_order_key = (
            "sha256:"
            + hashlib.sha256(
                b"easysplat-unordered-v1\0"
                + corpus_id.encode("utf-8")
                + b"\0"
                + str(scale).encode("ascii")
                + b"\0"
                + str(permutation_index).encode("ascii")
                + b"\0"
                + str(permutation_seed).encode("ascii")
                + b"\0"
                + source_digest.encode("ascii")
            ).hexdigest()
        )
        if order_key != expected_order_key or order_key <= previous_order_key:
            raise EvidenceError("photo permutation mapping order key is invalid")
        previous_order_key = order_key
        if source_digest in seen_sources:
            raise EvidenceError("photo permutation mapping source digest collision")
        if target in seen_targets:
            raise EvidenceError("photo permutation mapping target-name collision")
        seen_sources.add(source_digest)
        seen_targets.add(target)
        normalized_entries.append(dict(entry))
    expected_manifest = sha256_bytes(
        canonical_json_bytes(
            [
                {
                    "source_sha256": entry["source_sha256"],
                    "target_relative_path": entry["target_relative_path"],
                }
                for entry in normalized_entries
            ]
        )
    )
    if receipt["order_manifest_sha256"] != expected_manifest:
        raise EvidenceError("photo permutation order manifest digest is invalid")
    return dict(receipt)


def write_photo_permutation_mapping(path: Path, value: Any) -> None:
    """Atomically write a validated private permutation mapping receipt."""
    if path.is_symlink() or path.exists() and not path.is_file():
        raise EvidenceError("photo permutation output must be a regular file path")
    parent = path.parent.resolve(strict=True)
    if not parent.is_dir() or path.parent.is_symlink():
        raise EvidenceError("photo permutation output parent must be a real directory")
    validated = _validate_photo_permutation_mapping(value)
    data = canonical_json_bytes(validated) + b"\n"
    if len(data) > MAX_PHOTO_PERMUTATION_MAPPING_BYTES:
        raise EvidenceError("photo permutation mapping exceeds its bounded size")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


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
        if (
            type(record["discarded"]) is not bool
            or record["discarded"] != expected_discarded
        ):
            raise EvidenceError(f"{label} must discard exactly one warm-up per variant")
        measurements = {
            field: _positive_number(record[field], f"{label}[{index}].{field}")
            for field in measurement_fields
        }
        component_fields = set(measurement_fields) - {"end_to_end_seconds"}
        if (
            "end_to_end_seconds" in measurements
            and component_fields
            and measurements["end_to_end_seconds"] + 1e-9
            < sum(measurements[field] for field in component_fields)
        ):
            raise EvidenceError(
                f"{label}[{index}] end-to-end time is below its phase sum"
            )
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
        if (
            type(record["discarded"]) is not bool
            or record["discarded"] != expected_discarded
        ):
            raise EvidenceError(
                "timing.candidate_runs must mark only its first warm-up as discarded"
            )
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
            measurement_fields=(
                "end_to_end_seconds",
                "geometry_seconds",
                "training_seconds",
            ),
        )
        phases = _validate_timing_sequence(
            timing["phase_runs"],
            "timing.phase_runs",
            repetitions=5,
            measurement_fields=(
                "end_to_end_seconds",
                "matcher_seconds",
                "mapping_seconds",
            ),
        )
        fast_profile = _validate_timing_sequence(
            timing["fast_profile_runs"],
            "timing.fast_profile_runs",
            repetitions=3,
            measurement_fields=("end_to_end_seconds",),
            baseline_variant="accurate_reference",
            candidate_variant="fast_candidate",
        )
        candidate_end = [
            record["end_to_end_seconds"] for record in ordinary["candidate"]
        ]
        candidate_geometry = [
            record["geometry_seconds"] for record in ordinary["candidate"]
        ]
        baseline_geometry = [
            record["geometry_seconds"] for record in ordinary["baseline"]
        ]
        candidate_training = [
            record["training_seconds"] for record in ordinary["candidate"]
        ]
        candidate_matcher = [
            record["matcher_seconds"] for record in phases["candidate"]
        ]
        baseline_matcher = [record["matcher_seconds"] for record in phases["baseline"]]
        candidate_mapping = [
            record["mapping_seconds"] for record in phases["candidate"]
        ]
        baseline_mapping = [record["mapping_seconds"] for record in phases["baseline"]]
        fast_candidate_end = [
            record["end_to_end_seconds"] for record in fast_profile["fast_candidate"]
        ]
        accurate_reference_end = [
            record["end_to_end_seconds"]
            for record in fast_profile["accurate_reference"]
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
                    statistics.median(baseline_geometry)
                    / statistics.median(candidate_geometry)
                ),
                "geometry_seconds": measured(statistics.median(candidate_geometry)),
                "training_seconds": measured(statistics.median(candidate_training)),
                "matcher_seconds": measured(statistics.median(candidate_matcher)),
                "mapping_seconds": measured(statistics.median(candidate_mapping)),
                "matching_speedup": measured(
                    statistics.median(baseline_matcher)
                    / statistics.median(candidate_matcher)
                ),
                "mapping_speedup": measured(
                    statistics.median(baseline_mapping)
                    / statistics.median(candidate_mapping)
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
            measurement_fields=(
                "end_to_end_seconds",
                "geometry_seconds",
                "training_seconds",
            ),
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
            statistics.median(
                record["end_to_end_seconds"] for record in ordinary["candidate"]
            )
        )
        return metrics

    _exact_keys(timing, {"candidate_runs"}, "observations.timing")
    candidate_median = statistics.median(
        _validate_candidate_timing(timing["candidate_runs"])
    )
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
            run_id = _token(
                record.get("run_id"), f"timing.{group_name}[{index}].run_id"
            )
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
        raise EvidenceError(
            "valid evidence requires exactly one published training receipt"
        )
    receipt = published[0]
    run_id = _token(receipt.get("run_id"), "published training receipt run_id")
    phase = _token(receipt.get("phase"), "published training receipt phase")
    variant = _token(receipt.get("variant"), "published training receipt variant")
    expected_phase = "ordinary" if "ordinary_runs" in timing else "candidate"
    if variant != "candidate" or phase != expected_phase:
        raise EvidenceError(
            "published output must come from the candidate end-to-end run"
        )
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
        raise EvidenceError(
            "published training receipt does not resolve to one timing run"
        )
    record = matching[0]
    if record.get("discarded") is not False:
        raise EvidenceError(
            "published output must come from a measured candidate end-to-end run"
        )
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
    expected_ratio = 4.0 if topology == "continuous" else 1.4
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
    if (
        frames != expected_ratio
        or points != expected_ratio
        or local_refinements != expected_local
    ):
        raise EvidenceError(
            f"{topology} mapper cadence requires global ratios {expected_ratio} "
            f"and local refinements {expected_local}"
        )
    return float(frames), float(points), global_refinements, local_refinements


MAPPER_CADENCE_FIELDS = {
    "localMaxRefinements",
    "globalFramesRatio",
    "globalPointsRatio",
    "globalMaxRefinements",
    "localMaxNumIterations",
    "localFunctionTolerance",
    "globalFunctionTolerance",
    "localImageCount",
}


def _mapper_cadence(
    value: Any,
    label: str,
) -> dict[str, int | float]:
    cadence = _mapping(value, label)
    _exact_keys(cadence, MAPPER_CADENCE_FIELDS, label)
    for field in (
        "localMaxRefinements",
        "globalMaxRefinements",
        "localMaxNumIterations",
        "localImageCount",
    ):
        if type(cadence[field]) is not int or cadence[field] <= 0:
            raise EvidenceError(f"{label} is invalid")
    for field in (
        "globalFramesRatio",
        "globalPointsRatio",
        "localFunctionTolerance",
        "globalFunctionTolerance",
    ):
        number = cadence[field]
        if (
            isinstance(number, bool)
            or not isinstance(number, (int, float))
            or not math.isfinite(number)
            or number <= 0
            or (field in {"globalFramesRatio", "globalPointsRatio"} and number <= 1)
        ):
            raise EvidenceError(f"{label} is invalid")
    return dict(cadence)


def _cadence_from_tuple(
    cadence: tuple[float, float, int, int],
) -> dict[str, int | float]:
    return {
        "localMaxRefinements": cadence[3],
        "globalFramesRatio": cadence[0],
        "globalPointsRatio": cadence[1],
        "globalMaxRefinements": cadence[2],
        "localMaxNumIterations": 10,
        "localFunctionTolerance": 0.001,
        "globalFunctionTolerance": 0.000_001,
        "localImageCount": 6,
    }


def _candidate_mapper_cadence_contract(
    configuration: Mapping[str, Any],
) -> tuple[dict[str, int | float], dict[str, int | float]]:
    planned = _cadence_from_tuple(_candidate_mapper_cadence(configuration))
    fallback = _cadence_from_tuple(
        (1.4, 1.4, 5, 2)
        if configuration["input_topology"] == "continuous"
        else (1.1, 1.1, 5, 2)
    )
    return planned, fallback


MAPPER_CADENCE_OPTIONS = (
    "--Mapper.ba_global_frames_ratio",
    "--Mapper.ba_global_points_ratio",
    "--Mapper.ba_global_max_refinements",
    "--Mapper.ba_local_max_refinements",
    "--Mapper.ba_local_max_num_iterations",
    "--Mapper.ba_local_function_tolerance",
    "--Mapper.ba_global_function_tolerance",
    "--Mapper.ba_local_num_images",
    "--Mapper.ba_global_max_num_iterations",
    "--Mapper.random_seed",
    "--Mapper.min_num_matches",
    "--Mapper.ba_refine_focal_length",
)


def _validate_mapper_invocation_argv(
    raw: Any,
    variant: str,
    *,
    expected_cadence: tuple[float, float, int, int] | None,
    expected_options: Mapping[str, str] | None = None,
    label: str,
) -> None:
    if (
        not isinstance(raw, list)
        or len(raw) < 2
        or any(not isinstance(argument, str) or not argument for argument in raw)
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
        raise EvidenceError(
            f"{label} argv does not identify the canonical COLMAP mapper executable"
        )
    if expected_cadence is None:
        if any(
            argument == option or argument.startswith(option + "=")
            for argument in raw
            for option in MAPPER_CADENCE_OPTIONS
        ):
            raise EvidenceError(f"{label} cannot contain production cadence options")
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
    if expected_options is not None:
        expected.update(expected_options)
    for option, expected_value in expected.items():
        indices = [index for index, argument in enumerate(raw) if argument == option]
        ambiguous = any(argument.startswith(option + "=") for argument in raw)
        if len(indices) != 1 or ambiguous or indices[0] + 1 >= len(raw):
            raise EvidenceError(
                f"{label} cadence must contain one split {option} value"
            )
        if raw[indices[0] + 1] != expected_value:
            raise EvidenceError(
                f"{label} cadence {option} does not match the bound value"
            )


def _validate_mapper_invocations(
    raw: Any,
    variant: str,
    request: Mapping[str, Any],
    *,
    valid_outcome: bool,
    planned_mapper_cadence: Any = _MISSING,
    accepted_mapper_cadence: Any = _MISSING,
    cadence_fallback_trigger: Any = _MISSING,
    geometry_execution: Mapping[str, Any] | None = None,
) -> None:
    if not isinstance(raw, list):
        raise EvidenceError("mapper_invocations must be an ordered array")
    if planned_mapper_cadence is _MISSING:
        if variant in {"candidate", "fast_candidate"} and raw:
            planned_mapper_cadence = raw[0].get("incremental_cadence")
            accepted_mapper_cadence = raw[-1].get("incremental_cadence")
            cadence_fallback_trigger = (
                raw[0].get("evaluation", {}).get("fallback_trigger")
                if planned_mapper_cadence != accepted_mapper_cadence
                else None
            )
        else:
            planned_mapper_cadence = None
            accepted_mapper_cadence = None
            cadence_fallback_trigger = None
    if not valid_outcome:
        if raw or any(
            value is not None
            for value in (
                planned_mapper_cadence,
                accepted_mapper_cadence,
                cadence_fallback_trigger,
            )
        ):
            raise EvidenceError(
                "invalid-input execution receipts cannot claim mapper evidence"
            )
        return
    if variant in {"baseline", "accurate_reference"}:
        if any(
            value is not None
            for value in (
                planned_mapper_cadence,
                accepted_mapper_cadence,
                cadence_fallback_trigger,
            )
        ):
            raise EvidenceError(f"{variant} cannot claim production cadence evidence")
        if len(raw) != 1:
            raise EvidenceError(f"{variant} requires exactly one mapper invocation")
        invocation = _mapping(raw[0], f"{variant} mapper invocation")
        _exact_keys(
            invocation,
            {
                "argv",
                "outcome",
                "mapping_attempt_ordinal",
                "matching_attempt",
                "pair_list_digest",
                "descriptor_matcher",
            },
            f"{variant} mapper invocation",
        )
        if (
            invocation["outcome"] != "accepted"
            or invocation["mapping_attempt_ordinal"] != 1
            or invocation["matching_attempt"] != 1
            or invocation["descriptor_matcher"] != "exact"
        ):
            raise EvidenceError(
                f"{variant} mapper invocation must record one accepted exact mapping"
            )
        _digest(invocation["pair_list_digest"], f"{variant} pair-list digest")
        _validate_mapper_invocation_argv(
            invocation["argv"],
            variant,
            expected_cadence=None,
            label=f"{variant} mapper invocation",
        )
        return
    if variant not in {"candidate", "fast_candidate"}:
        raise EvidenceError(f"unsupported mapper receipt variant: {variant}")
    seeded = geometry_execution is not None and geometry_execution["refinement_kind"] == "seededBundleAdjustment"
    if not raw:
        if seeded and not geometry_execution["successful_mapper_attempt_ordinals"] and all(
            value is None
            for value in (
                planned_mapper_cadence,
                accepted_mapper_cadence,
                cadence_fallback_trigger,
            )
        ):
            return
        raise EvidenceError("candidate mapper evidence is missing")
    expected_planned, expected_fallback = _candidate_mapper_cadence_contract(
        request["candidate_run_configuration"]
    )
    if seeded:
        if any(
            value is not None
            for value in (
                planned_mapper_cadence,
                accepted_mapper_cadence,
                cadence_fallback_trigger,
            )
        ):
            raise EvidenceError("seeded geometry cannot claim accepted mapper cadence")
        planned: dict[str, int | float] = {}
        accepted_cadence: dict[str, int | float] = {}
    else:
        planned = _mapper_cadence(planned_mapper_cadence, "planned mapper cadence")
        accepted_cadence = _mapper_cadence(
            accepted_mapper_cadence,
            "accepted mapper cadence",
        )
        if planned != expected_planned:
            raise EvidenceError(
                "planned mapper cadence contradicts the protected request"
            )
        if accepted_cadence not in (expected_planned, expected_fallback):
            raise EvidenceError("accepted mapper cadence is not a production cadence")
        if cadence_fallback_trigger is not None and (
            cadence_fallback_trigger not in MAPPING_CADENCE_FALLBACK_TRIGGERS
        ):
            raise EvidenceError("mapper cadence fallback trigger is invalid")

    invocations: list[Mapping[str, Any]] = []
    for index, item in enumerate(raw):
        label = f"mapper_invocations[{index}]"
        invocation = _mapping(item, label)
        _exact_keys(
            invocation,
            {
                "argv",
                "mapping_attempt_ordinal",
                "incremental_cadence",
                "global_max_num_iterations",
                "random_seed",
                "refine_focal_length",
                "minimum_pair_inlier_count",
                "pair_graph_attempt_ordinal",
                "pair_list_digest",
                "descriptor_matcher",
                "matching_database_digest",
                "evaluation",
            },
            label,
        )
        mapping_ordinal = invocation["mapping_attempt_ordinal"]
        pair_ordinal = invocation["pair_graph_attempt_ordinal"]
        if (
            type(mapping_ordinal) is not int
            or not 1 <= mapping_ordinal <= MAXIMUM_MAPPING_ATTEMPT_ORDINAL
            or (invocations and mapping_ordinal <= invocations[-1]["mapping_attempt_ordinal"])
            or type(pair_ordinal) is not int
            or pair_ordinal <= 0
            or (invocations and pair_ordinal < invocations[-1]["pair_graph_attempt_ordinal"])
        ):
            raise EvidenceError("mapper invocation ordinals are invalid")
        cadence = _mapper_cadence(invocation["incremental_cadence"], f"{label}.incremental_cadence")
        _validate_mapper_invocation_argv(
            invocation["argv"],
            variant,
            expected_cadence=(
                float(cadence["globalFramesRatio"]),
                float(cadence["globalPointsRatio"]),
                int(cadence["globalMaxRefinements"]),
                int(cadence["localMaxRefinements"]),
            ),
            expected_options={
                "--Mapper.ba_global_max_num_iterations": str(
                    invocation["global_max_num_iterations"]
                ),
                "--Mapper.random_seed": str(invocation["random_seed"]),
                "--Mapper.min_num_matches": str(
                    invocation["minimum_pair_inlier_count"]
                ),
                "--Mapper.ba_refine_focal_length": "1",
            },
            label=label,
        )
        if (
            type(invocation["global_max_num_iterations"]) is not int
            or invocation["global_max_num_iterations"] <= 0
            or type(invocation["random_seed"]) is not int
            or not 0 <= invocation["random_seed"] <= 2_147_483_647
            or invocation["refine_focal_length"] is not True
            or type(invocation["minimum_pair_inlier_count"]) is not int
            or invocation["minimum_pair_inlier_count"] <= 0
            or invocation["descriptor_matcher"] not in {"faiss", "exact"}
        ):
            raise EvidenceError(f"{label} options are invalid")
        _digest(invocation["pair_list_digest"], f"{label}.pair_list_digest")
        _digest(
            invocation["matching_database_digest"],
            f"{label}.matching_database_digest",
        )
        evaluation = _mapping(invocation["evaluation"], f"{label}.evaluation")
        _exact_keys(evaluation, {"status", "fallback_trigger"}, f"{label}.evaluation")
        if evaluation["status"] not in {"accepted", "rejected", "interrupted", "failed"}:
            raise EvidenceError(f"{label} evaluation status is invalid")
        trigger = evaluation["fallback_trigger"]
        if trigger is not None and trigger not in MAPPING_CADENCE_FALLBACK_TRIGGERS:
            raise EvidenceError(f"{label} fallback trigger is invalid")
        if evaluation["status"] != "rejected" and trigger is not None:
            raise EvidenceError(f"{label} fallback trigger requires rejection")
        invocations.append(invocation)

    first_invocation = invocations[0]
    if (
        first_invocation["descriptor_matcher"]
        != request["candidate_run_configuration"]["descriptor_matcher"]
        and (
            first_invocation["descriptor_matcher"] != "exact"
            or first_invocation["pair_graph_attempt_ordinal"] <= 1
        )
    ):
        raise EvidenceError(
            "candidate first exact mapper invocation requires prior FAISS evidence"
        )

    accepted_indices = [
        index
        for index, invocation in enumerate(invocations)
        if invocation["evaluation"]["status"] == "accepted"
    ]
    if seeded:
        if accepted_indices or any(
            invocation["evaluation"]["status"] != "rejected"
            for invocation in invocations
        ):
            raise EvidenceError("seeded geometry cannot claim accepted mapper cadence")
        outer_ordinals = [item["mapping_attempt_ordinal"] for item in invocations]
        compact_outer = [
            {key: value for key, value in invocation.items() if key != "argv"}
            for invocation in invocations
        ]
        if (
            outer_ordinals
            != geometry_execution["successful_mapper_attempt_ordinals"]
            or compact_outer != geometry_execution["mapper_invocations"]
        ):
            raise EvidenceError("seeded mapper receipt does not bind worker history")
        return
    if accepted_indices != [len(invocations) - 1]:
        raise EvidenceError("the one accepted mapper invocation must be last")
    if any(
        invocation["evaluation"]["status"] != "rejected"
        for invocation in invocations[:-1]
    ):
        raise EvidenceError("successful mapper history may contain only rejected then accepted evaluations")

    cadences = [dict(invocation["incremental_cadence"]) for invocation in invocations]
    transitions = [
        index for index in range(1, len(cadences)) if cadences[index - 1] != cadences[index]
    ]
    if planned == accepted_cadence:
        if transitions or cadence_fallback_trigger is not None or any(
            cadence != planned for cadence in cadences
        ) or any(
            invocation["evaluation"]["fallback_trigger"] is not None
            for invocation in invocations
        ):
            raise EvidenceError("mapper cadence changed without an accepted fallback")
    else:
        transition_index = transitions[0] if len(transitions) == 1 else None
        if (
            accepted_cadence != expected_fallback
            or transition_index is None
            or cadence_fallback_trigger is None
            or any(cadence != planned for cadence in cadences[:transition_index])
            or any(
                cadence != accepted_cadence
                for cadence in cadences[transition_index:]
            )
            or any(
                invocation["evaluation"]["fallback_trigger"] is not None
                for index, invocation in enumerate(invocations)
                if index != transition_index - 1
            )
        ):
            raise EvidenceError("mapper cadence transition is invalid")
        assert transition_index is not None
        first = invocations[transition_index - 1]
        second = invocations[transition_index]
        if (
            first["evaluation"]["status"] != "rejected"
            or first["evaluation"]["fallback_trigger"] != cadence_fallback_trigger
            or any(
                first[field] != second[field]
                for field in (
                    "pair_graph_attempt_ordinal",
                    "pair_list_digest",
                    "descriptor_matcher",
                    "matching_database_digest",
                )
            )
        ):
            raise EvidenceError("mapper cadence fallback must reuse one rejected pair graph")

    final = invocations[-1]
    if dict(final["incremental_cadence"]) != accepted_cadence:
        raise EvidenceError("accepted mapper invocation cadence is invalid")
    if geometry_execution is not None:
        if (
            geometry_execution["refinement_kind"] != "incrementalGlobal"
            or geometry_execution["planned_incremental_cadence"] != planned
            or geometry_execution["incremental_cadence"] != accepted_cadence
            or geometry_execution["cadence_fallback_trigger"]
            != cadence_fallback_trigger
            or final["mapping_attempt_ordinal"]
            != geometry_execution["accepted_mapping_attempt_ordinal"]
            or final["pair_list_digest"] != geometry_execution["pair_list_digest"]
            or final["descriptor_matcher"] != geometry_execution["accepted_matcher"]
            or final["pair_graph_attempt_ordinal"]
            != geometry_execution["accepted_pair_graph_attempt_ordinal"]
            or final["matching_database_digest"]
            != geometry_execution["matching_database_digest"]
        ):
            raise EvidenceError("mapper receipt contradicts accepted geometry")
        outer_ordinals = [item["mapping_attempt_ordinal"] for item in invocations]
        if outer_ordinals != geometry_execution["successful_mapper_attempt_ordinals"]:
            raise EvidenceError("mapper receipt does not bind successful worker history")
        compact_outer = [
            {key: value for key, value in invocation.items() if key != "argv"}
            for invocation in invocations
        ]
        if geometry_execution["mapper_invocations"] != compact_outer:
            raise EvidenceError("mapper receipt does not match worker mapper evidence")


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
            _decode_json_text(line, "command_log") for line in lines if line.strip()
        ]
    except EvidenceError:
        raise
    except (OSError, UnicodeError, ValueError) as error:
        raise EvidenceError("command_log is not valid JSONL") from error


def _validate_mapper_evaluation(value: Any, label: str) -> Mapping[str, Any]:
    evaluation = _mapping(value, label)
    _exact_keys(evaluation, {"status", "fallbackTrigger"}, label)
    status = evaluation["status"]
    trigger = evaluation["fallbackTrigger"]
    if status not in {"accepted", "rejected", "interrupted", "failed"}:
        raise EvidenceError(f"{label} status is invalid")
    if trigger is not None and trigger not in MAPPING_CADENCE_FALLBACK_TRIGGERS:
        raise EvidenceError(f"{label} fallback trigger is invalid")
    if status != "rejected" and trigger is not None:
        raise EvidenceError(f"{label} fallback trigger requires rejection")
    return evaluation


def _validate_mapper_execution(
    value: Any,
    *,
    label: str,
    succeeded: bool,
) -> Mapping[str, Any]:
    execution = _mapping(value, label)
    _exact_keys(
        execution,
        {
            "incrementalCadence",
            "globalMaxNumIterations",
            "randomSeed",
            "refineFocalLength",
            "minimumPairInlierCount",
            "pairGraphAttemptOrdinal",
            "pairListDigest",
            "descriptorMatcher",
            "matchingDatabaseDigest",
            "evaluation",
        },
        label,
    )
    _mapper_cadence(execution["incrementalCadence"], f"{label}.incrementalCadence")
    if (
        type(execution["globalMaxNumIterations"]) is not int
        or execution["globalMaxNumIterations"] <= 0
        or type(execution["randomSeed"]) is not int
        or not 0 <= execution["randomSeed"] <= 2_147_483_647
        or execution["refineFocalLength"] is not True
        or type(execution["minimumPairInlierCount"]) is not int
        or execution["minimumPairInlierCount"] <= 0
        or type(execution["pairGraphAttemptOrdinal"]) is not int
        or execution["pairGraphAttemptOrdinal"] <= 0
        or execution["descriptorMatcher"] not in {"faiss", "exact"}
        or not isinstance(execution["pairListDigest"], str)
        or re.fullmatch(r"[0-9a-f]{64}", execution["pairListDigest"]) is None
        or not isinstance(execution["matchingDatabaseDigest"], str)
        or re.fullmatch(r"[0-9a-f]{64}", execution["matchingDatabaseDigest"])
        is None
    ):
        raise EvidenceError(f"{label} options or graph identity are invalid")
    evaluation = execution["evaluation"]
    if evaluation is None:
        if succeeded:
            raise EvidenceError(f"{label} successful mapper lacks evaluation")
        return execution
    validated_evaluation = _validate_mapper_evaluation(
        evaluation,
        f"{label}.evaluation",
    )
    status = validated_evaluation["status"]
    if succeeded != (status in {"accepted", "rejected"}):
        raise EvidenceError(f"{label} evaluation contradicts process status")
    return execution


def _validate_worker_invocations(
    value: Any,
    *,
    context: str,
    allowed_commands: frozenset[str],
    expected_policy: str,
    expected_worker_count: int | None,
    expects_mapping_attempt_ordinal: bool,
    required: bool,
) -> None:
    if not isinstance(value, list):
        raise EvidenceError(f"{context} must be an invocation array")
    if len(value) > MAX_WORKER_INVOCATIONS_PER_STAGE:
        raise EvidenceError(f"{context} contains too many invocations")
    if required and not value:
        raise EvidenceError(f"{context} is missing required execution evidence")
    invocation_fields = {
        "command",
        "mappingAttemptOrdinal",
        "threadPolicy",
        "argvWorkerCount",
        "explicitThreadEnvironment",
        "removedThreadEnvironmentKeysSHA256",
        "effectiveSanitizedThreadEnvironment",
        "pairExecution",
        "mapperExecution",
        "modelConversion",
        "exitStatus",
        "succeeded",
    }
    previous_mapping_attempt_ordinal = 0
    for index, raw in enumerate(value):
        invocation_context = f"{context}[{index}]"
        invocation = _mapping(raw, invocation_context)
        _exact_keys(invocation, invocation_fields, invocation_context)
        command = invocation["command"]
        if (
            not isinstance(command, str)
            or not command
            or len(command) > 64
            or re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", command) is None
        ):
            raise EvidenceError(f"{invocation_context} command is invalid")
        if command not in allowed_commands:
            raise EvidenceError(
                f"{invocation_context} command belongs to another stage"
            )
        mapping_attempt_ordinal = invocation["mappingAttemptOrdinal"]
        if expects_mapping_attempt_ordinal:
            if (
                type(mapping_attempt_ordinal) is not int
                or not 1 <= mapping_attempt_ordinal <= MAXIMUM_MAPPING_ATTEMPT_ORDINAL
                or mapping_attempt_ordinal < previous_mapping_attempt_ordinal
            ):
                raise EvidenceError(
                    f"{invocation_context} mapping-attempt ordinal is invalid"
                )
            previous_mapping_attempt_ordinal = mapping_attempt_ordinal
        elif mapping_attempt_ordinal is not None:
            raise EvidenceError(
                f"{invocation_context} cannot claim a mapping-attempt ordinal"
            )
        if invocation["threadPolicy"] != expected_policy:
            raise EvidenceError(f"{invocation_context} thread policy is invalid")
        exit_status = invocation["exitStatus"]
        succeeded = invocation["succeeded"]
        if (
            type(exit_status) is not int
            or not 0 <= exit_status <= 2_147_483_647
            or type(succeeded) is not bool
            or succeeded != (exit_status == 0)
        ):
            raise EvidenceError(f"{invocation_context} process status is inconsistent")
        pair_execution = invocation["pairExecution"]
        if command == "matchesImporter":
            _validate_pair_execution(
                pair_execution,
                context=f"{invocation_context}.pairExecution",
                kind="matching",
                succeeded=succeeded,
            )
        elif command == "localVocabularyRetriever":
            _validate_pair_execution(
                pair_execution,
                context=f"{invocation_context}.pairExecution",
                kind="retrieval",
                succeeded=succeeded,
            )
        elif pair_execution is not None:
            raise EvidenceError(f"{invocation_context} cannot claim pair execution")
        mapper_execution = invocation["mapperExecution"]
        if command == "mapper":
            _validate_mapper_execution(
                mapper_execution,
                label=f"{invocation_context}.mapperExecution",
                succeeded=succeeded,
            )
        elif mapper_execution is not None:
            raise EvidenceError(f"{invocation_context} cannot claim mapper execution")
        model_conversion = invocation["modelConversion"]
        if command == "modelConverter":
            conversion = _mapping(
                model_conversion,
                f"{invocation_context}.modelConversion",
            )
            _exact_keys(
                conversion,
                {
                    "executableComponentPath",
                    "executableSHA256",
                    "candidateProjectRelativePath",
                    "inputProjectRelativePath",
                    "outputProjectRelativePath",
                    "sourceModelDigest",
                    "convertedModelDigest",
                    "candidateIdentitySHA256",
                },
                f"{invocation_context}.modelConversion",
            )
            if conversion["executableComponentPath"] != "bin/colmap":
                raise EvidenceError(
                    f"{invocation_context} model-conversion executable path is invalid"
                )
            for field in (
                "candidateProjectRelativePath",
                "inputProjectRelativePath",
                "outputProjectRelativePath",
            ):
                raw_path = conversion[field]
                if not isinstance(raw_path, str):
                    raise EvidenceError(
                        f"{invocation_context} model-conversion path is invalid"
                    )
                relative = PurePosixPath(raw_path)
                if (
                    relative.is_absolute()
                    or not relative.parts
                    or any(part in {"", ".", ".."} for part in relative.parts)
                    or "\\" in raw_path
                ):
                    raise EvidenceError(
                        f"{invocation_context} model-conversion path is unsafe"
                    )
            if (
                conversion["inputProjectRelativePath"]
                == conversion["outputProjectRelativePath"]
            ):
                raise EvidenceError(
                    f"{invocation_context} model-conversion input and output paths must differ"
                )
            for field in (
                "executableSHA256",
                "sourceModelDigest",
                "candidateIdentitySHA256",
            ):
                raw_digest = conversion[field]
                if (
                    not isinstance(raw_digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", raw_digest) is None
                ):
                    raise EvidenceError(
                        f"{invocation_context} model-conversion digest is invalid"
                    )
            converted_digest = conversion["convertedModelDigest"]
            if succeeded:
                if (
                    not isinstance(converted_digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", converted_digest) is None
                ):
                    raise EvidenceError(
                        f"{invocation_context} successful model conversion lacks its digest"
                    )
            elif converted_digest is not None:
                raise EvidenceError(
                    f"{invocation_context} failed model conversion cannot claim an output digest"
                )
        elif model_conversion is not None:
            raise EvidenceError(f"{invocation_context} cannot claim model conversion")
        if (
            invocation["removedThreadEnvironmentKeysSHA256"]
            != COLMAP_THREAD_ENVIRONMENT_KEYS_SHA256
        ):
            raise EvidenceError(f"{invocation_context} sanitizer digest is invalid")
        explicit_environment = _mapping(
            invocation["explicitThreadEnvironment"],
            f"{invocation_context}.explicitThreadEnvironment",
        )
        effective_environment = _mapping(
            invocation["effectiveSanitizedThreadEnvironment"],
            f"{invocation_context}.effectiveSanitizedThreadEnvironment",
        )
        if expected_policy == "bounded":
            expected_environment = {
                "OMP_NUM_THREADS": str(expected_worker_count),
                "OPENBLAS_NUM_THREADS": str(expected_worker_count),
                "MKL_NUM_THREADS": str(expected_worker_count),
            }
            if (
                type(invocation["argvWorkerCount"]) is not int
                or invocation["argvWorkerCount"] != expected_worker_count
                or dict(explicit_environment) != expected_environment
                or dict(effective_environment) != expected_environment
            ):
                raise EvidenceError(
                    f"{invocation_context} bounded worker launch is invalid"
                )
        elif (
            invocation["argvWorkerCount"] is not None
            or explicit_environment
            or effective_environment
        ):
            raise EvidenceError(f"{invocation_context} native-auto launch is invalid")


def _validate_pair_execution(
    value: Any,
    *,
    context: str,
    kind: str,
    succeeded: bool,
) -> None:
    binding = _mapping(value, context)
    required_fields = {"attemptOrdinal", "descriptorMatcher"}
    optional_fields = {
        "scheduledPairCount",
        "pairListDigest",
        "exactRecoveryReason",
        "retrievalRequestDigest",
        "retrievalOutputDigest",
    }
    if not required_fields.issubset(binding) or not set(binding).issubset(
        required_fields | optional_fields
    ):
        raise EvidenceError(f"{context} has invalid fields")
    attempt_ordinal = binding["attemptOrdinal"]
    descriptor_matcher = binding["descriptorMatcher"]
    scheduled_pair_count = binding.get("scheduledPairCount")
    pair_list_digest = binding.get("pairListDigest")
    exact_recovery_reason = binding.get("exactRecoveryReason")
    request_digest = binding.get("retrievalRequestDigest")
    output_digest = binding.get("retrievalOutputDigest")
    if (
        type(attempt_ordinal) is not int
        or not 1 <= attempt_ordinal <= MAXIMUM_MAPPING_ATTEMPT_ORDINAL
        or not isinstance(descriptor_matcher, str)
        or descriptor_matcher not in {"faiss", "exact"}
    ):
        raise EvidenceError(f"{context} identity is invalid")

    def is_sha256(value: Any) -> bool:
        return (
            isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None
        )

    if kind == "matching":
        if (
            type(scheduled_pair_count) is not int
            or scheduled_pair_count <= 0
            or not is_sha256(pair_list_digest)
            or (descriptor_matcher == "exact")
            != _valid_exact_recovery_reason(exact_recovery_reason)
            or (
                descriptor_matcher == "exact"
                and scheduled_pair_count > MAXIMUM_EXACT_RECOVERY_PAIR_COUNT
            )
        ):
            raise EvidenceError(f"{context} pair-list digest is invalid")
        if (request_digest is None) != (output_digest is None):
            raise EvidenceError(f"{context} retrieval digests are incomplete")
        if request_digest is not None and (
            not is_sha256(request_digest) or not is_sha256(output_digest)
        ):
            raise EvidenceError(f"{context} retrieval digests are invalid")
        return
    if kind != "retrieval":
        raise AssertionError(f"unsupported pair-execution kind: {kind}")
    if (
        scheduled_pair_count is not None
        or pair_list_digest is not None
        or exact_recovery_reason is not None
        or not is_sha256(request_digest)
    ):
        raise EvidenceError(f"{context} retrieval request is invalid")
    if succeeded and not is_sha256(output_digest):
        raise EvidenceError(f"{context} successful retrieval output is invalid")
    if output_digest is not None and not is_sha256(output_digest):
        raise EvidenceError(f"{context} retrieval output is invalid")


def _canonical_string_digest(fields: Iterable[str]) -> str:
    hasher = hashlib.sha256()
    for field in fields:
        encoded = field.encode("utf-8")
        hasher.update(f"{len(encoded)}:".encode("utf-8"))
        hasher.update(encoded)
    return hasher.hexdigest()


def _validate_retrieval_contract(
    value: Any,
    *,
    image_names: list[str],
    context: str,
) -> tuple[str, str]:
    retrieval = _mapping(value, context)
    _exact_keys(
        retrieval,
        {
            "engine",
            "queryImageNames",
            "queryStride",
            "candidateCount",
            "returnedNeighborCount",
            "minimumFrameSeparation",
            "queryOutcomes",
            "directedPairLines",
            "outputDigest",
        },
        context,
    )
    image_name_set = set(image_names)
    if len(image_name_set) != len(image_names) or any(
        not isinstance(name, str)
        or not name
        or name in {".", ".."}
        or "/" in name
        or "\\" in name
        or "\0" in name
        or len(name.encode("utf-8")) > 255
        for name in image_names
    ):
        raise EvidenceError(f"{context} image identity is invalid")
    engine = retrieval["engine"]
    query_names = retrieval["queryImageNames"]
    query_stride = retrieval["queryStride"]
    candidate_count = retrieval["candidateCount"]
    neighbor_count = retrieval["returnedNeighborCount"]
    minimum_separation = retrieval["minimumFrameSeparation"]
    if (
        engine != "localSiftVocabularyV2"
        or not isinstance(query_names, list)
        or not query_names
        or len(query_names) != len(set(query_names))
        or any(name not in image_name_set for name in query_names)
        or type(query_stride) is not int
        or query_stride <= 0
        or type(candidate_count) is not int
        or candidate_count <= 0
        or type(neighbor_count) is not int
        or not 0 < neighbor_count <= candidate_count
        or type(minimum_separation) is not int
        or minimum_separation < 0
    ):
        raise EvidenceError(f"{context} request is invalid")

    raw_outcomes = retrieval["queryOutcomes"]
    if not isinstance(raw_outcomes, list) or len(raw_outcomes) != len(query_names):
        raise EvidenceError(f"{context} outcomes are invalid")
    outcomes: list[tuple[str, str, list[str]]] = []
    outcome_edges: set[tuple[str, str]] = set()
    for index, raw_outcome in enumerate(raw_outcomes):
        outcome_context = f"{context}.queryOutcomes[{index}]"
        outcome = _mapping(raw_outcome, outcome_context)
        _exact_keys(
            outcome,
            {"queryImageName", "status", "rankedNeighborImageNames"},
            outcome_context,
        )
        query_name = outcome["queryImageName"]
        status = outcome["status"]
        neighbors = outcome["rankedNeighborImageNames"]
        if (
            query_name != query_names[index]
            or status not in {"ranked", "noRankedNeighbors"}
            or not isinstance(neighbors, list)
            or len(neighbors) != len(set(neighbors))
            or neighbors != sorted(neighbors, key=lambda name: name.encode("utf-8"))
            or any(
                not isinstance(neighbor, str)
                or neighbor not in image_name_set
                or neighbor == query_name
                for neighbor in neighbors
            )
            or (status == "ranked") != bool(neighbors)
        ):
            raise EvidenceError(f"{outcome_context} is invalid")
        outcomes.append((query_name, status, neighbors))
        outcome_edges.update((query_name, neighbor) for neighbor in neighbors)

    directed_lines = retrieval["directedPairLines"]
    if (
        not isinstance(directed_lines, list)
        or len(directed_lines) != len(set(directed_lines))
        or directed_lines
        != sorted(directed_lines, key=lambda line: line.encode("utf-8"))
    ):
        raise EvidenceError(f"{context} directed pairs are invalid")
    for line in directed_lines:
        if not isinstance(line, str):
            raise EvidenceError(f"{context} directed pairs are invalid")
        fields = line.split()
        if len(fields) != 2 or (fields[0], fields[1]) not in outcome_edges:
            raise EvidenceError(f"{context} directed pairs are invalid")

    request_digest = _canonical_string_digest(
        [
            engine,
            str(query_stride),
            str(candidate_count),
            str(neighbor_count),
            str(minimum_separation),
            *query_names,
        ]
    )
    header = " ".join(
        [
            "EASYSPLAT_RETRIEVAL_OUTCOMES_V2",
            engine,
            str(query_stride),
            str(candidate_count),
            str(neighbor_count),
            str(minimum_separation),
            str(len(query_names)),
            request_digest,
        ]
    )
    contract_lines = [header]
    contract_lines.extend(
        " ".join(["Q", status, query, str(len(neighbors)), *neighbors])
        for query, status, neighbors in outcomes
    )
    contract_lines.extend(f"P {line}" for line in directed_lines)
    output_digest = retrieval["outputDigest"]
    expected_output_digest = _canonical_string_digest(contract_lines)
    if (
        not isinstance(output_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", output_digest) is None
        or output_digest != expected_output_digest
    ):
        raise EvidenceError(f"{context} output digest is invalid")
    return request_digest, output_digest


def _validate_rejected_retrieval_topology(
    *,
    retrieval: Mapping[str, Any],
    image_names: list[str],
    groups: list[dict[str, Any]],
    pairing_policy: str,
    temporal_pairing: str,
    temporal_offsets: list[int],
    recovery_level: str,
    context: str,
) -> None:
    image_index = {name: index for index, name in enumerate(image_names)}
    base_edges: set[tuple[int, int]] = set()
    if recovery_level == "maximum" and len(image_names) <= 250:
        base_edges.update(
            (first, second)
            for first in range(len(image_names) - 1)
            for second in range(first + 1, len(image_names))
        )
    elif temporal_pairing in {"linear", "multiscale"}:
        offsets = temporal_offsets
        if recovery_level != "normal" and pairing_policy != "segmentedMixed":
            offsets = sorted(set(offsets).union(range(1, 13)))
        for group in groups:
            if pairing_policy == "segmentedMixed" and not group["isVideo"]:
                continue
            indices = [image_index[name] for name in group["imageNames"]]
            for offset in offsets:
                for first in range(len(indices) - offset):
                    base_edges.add((indices[first], indices[first + offset]))
    elif temporal_pairing != "none":
        raise EvidenceError(f"{context} temporal pairing is invalid")

    expected_lines: list[str] = []
    retrieval_edges: set[tuple[int, int]] = set()
    minimum_separation = retrieval["minimumFrameSeparation"]
    maximum_neighbors = retrieval["returnedNeighborCount"]
    for index, raw_outcome in enumerate(retrieval["queryOutcomes"]):
        outcome = _mapping(raw_outcome, f"{context}.queryOutcomes[{index}]")
        query_name = outcome["queryImageName"]
        query_index = image_index[query_name]
        retained_neighbor_count = 0
        for neighbor_name in outcome["rankedNeighborImageNames"]:
            neighbor_index = image_index[neighbor_name]
            edge = (
                min(query_index, neighbor_index),
                max(query_index, neighbor_index),
            )
            if edge in base_edges:
                continue
            if abs(query_index - neighbor_index) < minimum_separation:
                raise EvidenceError(f"{context} retrieval separation is invalid")
            retained_neighbor_count += 1
            if retained_neighbor_count > maximum_neighbors:
                raise EvidenceError(f"{context} retrieval neighbor count is invalid")
            if edge not in retrieval_edges:
                retrieval_edges.add(edge)
                expected_lines.append(f"{query_name} {neighbor_name}")
    expected_lines.sort(key=lambda line: line.encode("utf-8"))
    if retrieval["directedPairLines"] != expected_lines:
        raise EvidenceError(f"{context} directed pairs do not match ranked outcomes")

    adjacency = [set() for _ in image_names]
    for first, second in base_edges.union(retrieval_edges):
        adjacency[first].add(second)
        adjacency[second].add(first)
    visited = {0}
    frontier = [0]
    while frontier:
        current = frontier.pop()
        for neighbor in adjacency[current]:
            if neighbor not in visited:
                visited.add(neighbor)
                frontier.append(neighbor)
    if len(visited) == len(image_names):
        raise EvidenceError(
            f"{context} does not prove a disconnected merged schedule"
        )


def _validate_rejected_vocabulary_retrieval_history(
    value: Any,
    *,
    accepted_invocations: list[Any],
    expected_worker_count: int,
    candidate_configuration: Mapping[str, Any],
    request: Mapping[str, Any],
    image_names: list[str],
) -> tuple[str, ...]:
    context = "runtime rejected vocabulary retrieval history"
    if not isinstance(value, list) or len(value) > 3:
        raise EvidenceError(f"{context} is invalid")
    if not value:
        return ()

    pairing_policy = {
        "generic_continuous": "orderedContinuous",
        "object_orbit": "orderedOrbit",
        "walkthrough": "orderedWalkthrough",
        "large_area": "orderedLargeArea",
        "segmented_mixed": "segmentedMixed",
        "unordered_exhaustive": "unorderedRetrieval",
        "unordered_retrieval": "unorderedRetrieval",
    }[candidate_configuration["pairing_policy"]]
    requires_cross_clip = _requires_cross_clip_retrieval(
        request,
        candidate_configuration,
    )
    expected_camera_model = _resolved_camera_model(candidate_configuration)
    expected_camera_grouping = _resolved_camera_grouping(
        candidate_configuration["camera_grouping"], request
    )
    expected_camera_recipe = (
        "sharedOpenCVFisheyeEquidistantDiagonal150V1"
        if expected_camera_model == "OPENCV_FISHEYE"
        and expected_camera_grouping == "sameCameraAndLens"
        else "colmapAutomatic"
    )
    expected_plan = {
        "pairingPolicy": pairing_policy,
        "geometryBackend": "colmap",
        "modelIdentifier": "none",
        "temporalPairing": candidate_configuration["temporal_pairing"],
        "temporalOffsets": candidate_configuration["temporal_offsets"],
        "retrievalEngine": "localSiftVocabularyV2",
        "retrievalCandidateCount": candidate_configuration[
            "vocabulary_candidate_count"
        ],
        "retrievalNeighborCount": candidate_configuration[
            "vocabulary_returned_neighbor_count"
        ],
        "retrievalQueryStride": candidate_configuration["vocabulary_query_stride"],
        "requiresCrossClipRetrieval": requires_cross_clip,
        "normalDescriptorMatcher": candidate_configuration["descriptor_matcher"],
        "cameraInitializationRecipe": expected_camera_recipe,
        "runSeed": candidate_configuration["run_seed"],
    }
    accepted_digest_pairs = {
        (
            invocation["pairExecution"].get("retrievalRequestDigest"),
            invocation["pairExecution"].get("retrievalOutputDigest"),
        )
        for invocation in accepted_invocations
        if invocation["succeeded"]
        and invocation["pairExecution"] is not None
        and invocation["pairExecution"].get("retrievalRequestDigest") is not None
        and invocation["pairExecution"].get("retrievalOutputDigest") is not None
    }
    recovery_indices = {"normal": 0, "expanded": 1, "maximum": 2}
    previous_recovery_index = -1
    previous_pair_attempt = 0
    bound_groups: list[Any] | None = None
    for index, raw_entry in enumerate(value, start=1):
        entry_context = f"{context}[{index - 1}]"
        entry = _mapping(raw_entry, entry_context)
        _exact_keys(
            entry,
            {
                "retrievalAttemptOrdinal",
                "pairingPolicy",
                "planBinding",
                "recoveryLevel",
                "imageNames",
                "groups",
                "invocation",
                "retrieval",
                "durationSeconds",
            },
            entry_context,
        )
        recovery_level = entry["recoveryLevel"]
        recovery_index = recovery_indices.get(recovery_level)
        duration = entry["durationSeconds"]
        if (
            type(entry["retrievalAttemptOrdinal"]) is not int
            or entry["retrievalAttemptOrdinal"] != index
            or not isinstance(entry["pairingPolicy"], str)
            or entry["pairingPolicy"] != pairing_policy
            or not isinstance(recovery_level, str)
            or recovery_index is None
            or recovery_index <= previous_recovery_index
            or isinstance(duration, bool)
            or not isinstance(duration, (int, float))
            or not math.isfinite(duration)
            or duration < 0
            or entry["imageNames"] != image_names
        ):
            raise EvidenceError(f"{entry_context} identity is invalid")

        plan = _mapping(entry["planBinding"], f"{entry_context}.planBinding")
        _exact_keys(plan, set(expected_plan), f"{entry_context}.planBinding")
        if (
            not isinstance(plan["pairingPolicy"], str)
            or not isinstance(plan["geometryBackend"], str)
            or not isinstance(plan["modelIdentifier"], str)
            or not isinstance(plan["temporalPairing"], str)
            or not isinstance(plan["temporalOffsets"], list)
            or any(type(offset) is not int for offset in plan["temporalOffsets"])
            or not isinstance(plan["retrievalEngine"], str)
            or type(plan["retrievalCandidateCount"]) is not int
            or type(plan["retrievalNeighborCount"]) is not int
            or type(plan["retrievalQueryStride"]) is not int
            or type(plan["requiresCrossClipRetrieval"]) is not bool
            or not isinstance(plan["normalDescriptorMatcher"], str)
            or not isinstance(plan["cameraInitializationRecipe"], str)
            or type(plan["runSeed"]) is not int
            or dict(plan) != expected_plan
        ):
            raise EvidenceError(f"{entry_context} plan binding is invalid")

        groups = entry["groups"]
        if not isinstance(groups, list) or not groups:
            raise EvidenceError(f"{entry_context} groups are invalid")
        normalized_groups: list[dict[str, Any]] = []
        for group_index, raw_group in enumerate(groups):
            group = _mapping(raw_group, f"{entry_context}.groups[{group_index}]")
            _exact_keys(
                group,
                {"imageNames", "isVideo"},
                f"{entry_context}.groups[{group_index}]",
            )
            if (
                not isinstance(group["imageNames"], list)
                or not group["imageNames"]
                or type(group["isVideo"]) is not bool
            ):
                raise EvidenceError(f"{entry_context} groups are invalid")
            normalized_groups.append(dict(group))
        if (
            [name for group in normalized_groups for name in group["imageNames"]]
            != image_names
            or (bound_groups is not None and normalized_groups != bound_groups)
            or (
                requires_cross_clip
                and (
                    len(normalized_groups) <= 1
                    or not all(group["isVideo"] for group in normalized_groups)
                )
            )
            or sum(group["isVideo"] for group in normalized_groups)
            != request["video_source_count"]
        ):
            raise EvidenceError(f"{entry_context} groups are invalid")

        retrieval = _mapping(entry["retrieval"], f"{entry_context}.retrieval")
        if requires_cross_clip:
            expected_queries = [
                name
                for group in normalized_groups
                for name in group["imageNames"][
                    :: candidate_configuration["vocabulary_query_stride"]
                ]
            ]
        else:
            expected_queries = image_names[
                :: candidate_configuration["vocabulary_query_stride"]
            ]
        expected_candidate_count = candidate_configuration["vocabulary_candidate_count"]
        expected_neighbor_count = candidate_configuration[
            "vocabulary_returned_neighbor_count"
        ]
        if recovery_level == "expanded" and pairing_policy in {
            "segmentedMixed",
            "unorderedRetrieval",
        }:
            expected_candidate_count, expected_neighbor_count = 40, 16
        elif recovery_level == "maximum":
            expected_candidate_count, expected_neighbor_count = 80, 32
        expected_minimum_separation = (
            0
            if requires_cross_clip
            or pairing_policy in {"segmentedMixed", "unorderedRetrieval"}
            else max(12, len(image_names) // 10)
        )
        retrieval_is_required = not (
            (recovery_level == "maximum" and len(image_names) <= 250)
            or (pairing_policy == "unorderedRetrieval" and len(image_names) <= 60)
        ) and (
            requires_cross_clip
            or pairing_policy
            in {
                "orderedOrbit",
                "orderedWalkthrough",
                "orderedLargeArea",
                "segmentedMixed",
                "unorderedRetrieval",
            }
            or (pairing_policy == "orderedContinuous" and len(image_names) >= 120)
        )
        if (
            not retrieval_is_required
            or retrieval.get("queryImageNames") != expected_queries
            or retrieval.get("queryStride")
            != candidate_configuration["vocabulary_query_stride"]
            or retrieval.get("candidateCount") != expected_candidate_count
            or retrieval.get("returnedNeighborCount") != expected_neighbor_count
            or retrieval.get("minimumFrameSeparation") != expected_minimum_separation
        ):
            raise EvidenceError(f"{entry_context} retrieval does not match its plan")
        request_digest, output_digest = _validate_retrieval_contract(
            retrieval,
            image_names=image_names,
            context=f"{entry_context}.retrieval",
        )
        _validate_rejected_retrieval_topology(
            retrieval=retrieval,
            image_names=image_names,
            groups=normalized_groups,
            pairing_policy=pairing_policy,
            temporal_pairing=plan["temporalPairing"],
            temporal_offsets=plan["temporalOffsets"],
            recovery_level=recovery_level,
            context=f"{entry_context}.retrieval",
        )

        invocation = entry["invocation"]
        _validate_worker_invocations(
            [invocation],
            context=f"{entry_context}.invocation",
            allowed_commands=frozenset({"localVocabularyRetriever"}),
            expected_policy="bounded",
            expected_worker_count=expected_worker_count,
            expects_mapping_attempt_ordinal=False,
            required=True,
        )
        binding = invocation["pairExecution"]
        digest_pair = (request_digest, output_digest)
        if (
            not invocation["succeeded"]
            or binding["attemptOrdinal"] < previous_pair_attempt
            or binding["descriptorMatcher"] != "faiss"
            or binding.get("scheduledPairCount") is not None
            or binding.get("pairListDigest") is not None
            or binding.get("exactRecoveryReason") is not None
            or binding.get("retrievalRequestDigest") != request_digest
            or binding.get("retrievalOutputDigest") != output_digest
            or digest_pair in accepted_digest_pairs
        ):
            raise EvidenceError(f"{entry_context} invocation is not bound")
        bound_groups = normalized_groups
        previous_recovery_index = recovery_index
        previous_pair_attempt = binding["attemptOrdinal"]
    return tuple(entry["recoveryLevel"] for entry in value)


def _validate_recovery_density_closure(
    matcher_attempts: list[Any],
    rejected_recovery_levels: tuple[str, ...],
) -> None:
    context = "runtime recovery density closure"
    level_index = {"normal": 0, "expanded": 1, "maximum": 2}
    if not matcher_attempts:
        raise EvidenceError(f"{context} is empty")
    attempt_levels = [
        level_index.get(
            _mapping(attempt, f"{context}.attempts[{index}]").get("recoveryLevel")
        )
        for index, attempt in enumerate(matcher_attempts)
    ]
    rejected_levels = [level_index.get(level) for level in rejected_recovery_levels]
    if (
        any(level is None for level in attempt_levels)
        or any(level is None for level in rejected_levels)
        or rejected_levels != sorted(set(rejected_levels))
    ):
        raise EvidenceError(f"{context} is invalid")
    missing_levels = set(range(attempt_levels[0]))
    for previous, current in zip(attempt_levels, attempt_levels[1:]):
        if current < previous:
            raise EvidenceError(f"{context} regressed")
        missing_levels.update(range(previous + 1, current))
    if missing_levels != set(rejected_levels):
        raise EvidenceError(
            f"{context} does not authenticate every skipped retrieval density"
        )


def _validate_pair_execution_bindings(
    artifact: Mapping[str, Any],
    *,
    matcher_attempts: list[Any],
    accepted_pair_list_digest: str,
) -> None:
    matching_invocations = artifact["matchingInvocations"]
    if len(matching_invocations) != len(matcher_attempts):
        raise EvidenceError(
            "runtime matcher execution does not bind every pair-graph attempt"
        )
    matching_bindings: dict[int, Mapping[str, Any]] = {}
    for index, (attempt, invocation) in enumerate(
        zip(matcher_attempts, matching_invocations)
    ):
        attempt = _mapping(attempt, f"geometry matcherAttempts[{index}]")
        binding = _mapping(
            invocation["pairExecution"],
            f"runtime matchingInvocations[{index}].pairExecution",
        )
        attempt_ordinal = binding["attemptOrdinal"]
        if (
            attempt_ordinal != attempt["attemptNumber"]
            or binding["descriptorMatcher"] != attempt["matcher"]
            or binding.get("scheduledPairCount") != attempt["scheduledPairCount"]
            or binding.get("exactRecoveryReason")
            != attempt.get("exactRecoveryReason")
            or attempt_ordinal in matching_bindings
        ):
            raise EvidenceError(
                "runtime matcher execution does not match its pair-graph attempt"
            )
        if attempt["outcome"] == "completed" and not invocation["succeeded"]:
            raise EvidenceError(
                "completed pair-graph attempt lacks successful matcher execution"
            )
        matching_bindings[attempt_ordinal] = binding
        if attempt["matcher"] == "exact":
            if index == 0:
                raise EvidenceError("runtime exact matcher lacks its FAISS predecessor")
            previous_attempt = _mapping(
                matcher_attempts[index - 1],
                f"geometry matcherAttempts[{index - 1}]",
            )
            previous_invocation = matching_invocations[index - 1]
            previous_binding = _mapping(
                previous_invocation["pairExecution"],
                f"runtime matchingInvocations[{index - 1}].pairExecution",
            )
            reason = attempt.get("exactRecoveryReason")
            predecessor_status_is_bound = (
                reason in ("faissCrash", "faissUnsupportedOperation")
                and not previous_invocation["succeeded"]
            ) or (
                reason == "faissGeometryRejectedAfterRetries"
                and previous_invocation["succeeded"]
            )
            if (
                previous_attempt["matcher"] != "faiss"
                or binding.get("pairListDigest")
                != previous_binding.get("pairListDigest")
                or binding.get("scheduledPairCount")
                != previous_binding.get("scheduledPairCount")
                or not predecessor_status_is_bound
            ):
                raise EvidenceError(
                    "runtime exact matcher is not bound to its FAISS predecessor"
                )
    accepted_binding = matching_bindings[matcher_attempts[-1]["attemptNumber"]]
    if accepted_binding.get("pairListDigest") != accepted_pair_list_digest:
        raise EvidenceError(
            "accepted matcher execution does not bind the published pair list"
        )

    seen_retrieval_attempts: set[int] = set()
    for index, invocation in enumerate(artifact["vocabularyRetrievalInvocations"]):
        binding = _mapping(
            invocation["pairExecution"],
            f"runtime vocabularyRetrievalInvocations[{index}].pairExecution",
        )
        attempt_ordinal = binding["attemptOrdinal"]
        matcher_binding = matching_bindings.get(attempt_ordinal)
        if (
            matcher_binding is None
            or attempt_ordinal in seen_retrieval_attempts
            or binding["descriptorMatcher"] != matcher_binding["descriptorMatcher"]
            or binding.get("retrievalRequestDigest")
            != matcher_binding.get("retrievalRequestDigest")
            or binding.get("retrievalOutputDigest")
            != matcher_binding.get("retrievalOutputDigest")
        ):
            raise EvidenceError(
                "runtime vocabulary retrieval does not bind its matcher attempt"
            )
        seen_retrieval_attempts.add(attempt_ordinal)


def _validate_unmeasured_matching_history(
    invocations: list[Any],
) -> None:
    if not 1 <= len(invocations) <= 2:
        raise EvidenceError(
            "unmeasured seeded geometry has invalid matching history"
        )
    first = invocations[0]
    first_binding = _mapping(
        first["pairExecution"],
        "unmeasured seeded geometry FAISS pair execution",
    )
    scheduled_pair_count = first_binding.get("scheduledPairCount")
    pair_list_digest = first_binding.get("pairListDigest")
    if (
        first_binding["attemptOrdinal"] != 1
        or first_binding["descriptorMatcher"] != "faiss"
        or first_binding.get("exactRecoveryReason") is not None
        or type(scheduled_pair_count) is not int
        or scheduled_pair_count <= 0
        or not isinstance(pair_list_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", pair_list_digest) is None
    ):
        raise EvidenceError(
            "unmeasured seeded geometry must begin with bound FAISS matching"
        )
    if len(invocations) == 1:
        if not first["succeeded"]:
            raise EvidenceError(
                "unmeasured seeded geometry lacks successful matching"
            )
        return

    exact = invocations[1]
    exact_binding = _mapping(
        exact["pairExecution"],
        "unmeasured seeded geometry exact pair execution",
    )
    if (
        first["succeeded"]
        or not exact["succeeded"]
        or exact_binding["attemptOrdinal"] != 2
        or exact_binding["descriptorMatcher"] != "exact"
        or exact_binding.get("scheduledPairCount") != scheduled_pair_count
        or exact_binding.get("pairListDigest") != pair_list_digest
        or exact_binding.get("exactRecoveryReason")
        not in ("faissCrash", "faissUnsupportedOperation")
        or scheduled_pair_count > MAXIMUM_EXACT_RECOVERY_PAIR_COUNT
    ):
        raise EvidenceError(
            "unmeasured seeded exact recovery is not bound to failed FAISS matching"
        )


def _load_runtime_json_artifact(
    artifact_root: Path,
    relative_path: PurePosixPath,
    expected_sha256: str,
    label: str,
    maximum_bytes: int,
) -> Any:
    encoded = _load_runtime_artifact_bytes(
        artifact_root,
        relative_path,
        expected_sha256,
        label,
        maximum_bytes,
    )
    try:
        decoded = _decode_json_text(encoded.decode("utf-8"), label)
    except UnicodeError as error:
        raise EvidenceError(f"{label} is not valid UTF-8 JSON") from error
    if encoded != canonical_json_bytes(decoded):
        raise EvidenceError(f"{label} is not canonical JSON")
    return decoded


def _load_runtime_artifact_bytes(
    artifact_root: Path,
    relative_path: PurePosixPath,
    expected_sha256: str,
    label: str,
    maximum_bytes: int,
) -> bytes:
    descriptor = _open_render_artifact(artifact_root, relative_path, label)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or not 0 < before.st_size <= maximum_bytes
        ):
            raise EvidenceError(f"{label} must be a bounded single-link regular file")
        chunks = []
        total = 0
        while True:
            try:
                chunk = os.read(descriptor, 256 * 1024)
            except InterruptedError:
                continue
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise EvidenceError(f"{label} exceeds its size limit")
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
        "st_nlink",
    )
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise EvidenceError(f"{label} changed while it was read")
    encoded = b"".join(chunks)
    if sha256_bytes(encoded) != expected_sha256:
        raise EvidenceError(f"{label} digest changed after artifact attestation")
    return encoded


_COLMAP_CAMERA_PARAMETER_COUNTS = {
    "SIMPLE_PINHOLE": 3,
    "PINHOLE": 4,
    "SIMPLE_RADIAL": 4,
    "RADIAL": 5,
    "OPENCV": 8,
    "OPENCV_FISHEYE": 8,
    "FULL_OPENCV": 12,
    "FOV": 5,
    "SIMPLE_RADIAL_FISHEYE": 4,
    "RADIAL_FISHEYE": 5,
    "THIN_PRISM_FISHEYE": 12,
    "RAD_TAN_THIN_PRISM_FISHEYE": 16,
    "SIMPLE_DIVISION": 4,
    "DIVISION": 5,
    "SIMPLE_FISHEYE": 3,
    "FISHEYE": 4,
    "EUCM": 6,
    "EQUIRECTANGULAR": 0,
}

_COLMAP_DUAL_FOCAL_CAMERA_MODELS = {
    "PINHOLE",
    "OPENCV",
    "OPENCV_FISHEYE",
    "FULL_OPENCV",
    "FOV",
    "THIN_PRISM_FISHEYE",
    "RAD_TAN_THIN_PRISM_FISHEYE",
    "DIVISION",
    "FISHEYE",
    "EUCM",
}


def _parse_colmap_cameras_text(contents: bytes, label: str) -> list[dict[str, Any]]:
    try:
        text = contents.decode("utf-8")
    except UnicodeError as error:
        raise EvidenceError(f"{label} is not valid UTF-8") from error
    cameras: list[dict[str, Any]] = []
    camera_ids: set[int] = set()
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 4:
            raise EvidenceError(f"{label} line {line_number} is malformed")
        integer_pattern = r"[+-]?[0-9]+"
        floating_pattern = (
            r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)"
            r"(?:[eE][+-]?[0-9]+)?"
        )
        if (
            any(
                re.fullmatch(integer_pattern, fields[index]) is None
                for index in (0, 2, 3)
            )
            or any(
                re.fullmatch(floating_pattern, value) is None
                for value in fields[4:]
            )
        ):
            raise EvidenceError(f"{label} line {line_number} is malformed")
        try:
            camera_id = int(fields[0], 10)
            width = int(fields[2], 10)
            height = int(fields[3], 10)
            parameters = [float(value) for value in fields[4:]]
        except ValueError as error:
            raise EvidenceError(f"{label} line {line_number} is malformed") from error
        model = fields[1]
        expected_count = _COLMAP_CAMERA_PARAMETER_COUNTS.get(model)
        if (
            camera_id <= 0
            or camera_id > (1 << 63) - 1
            or camera_id in camera_ids
            or width <= 0
            or width > (1 << 63) - 1
            or height <= 0
            or height > (1 << 63) - 1
            or expected_count is None
            or len(parameters) != expected_count
            or any(not math.isfinite(value) for value in parameters)
        ):
            raise EvidenceError(f"{label} line {line_number} is invalid")
        focal_count = (
            0
            if model == "EQUIRECTANGULAR"
            else 2
            if model in _COLMAP_DUAL_FOCAL_CAMERA_MODELS
            else 1
        )
        if any(parameters[index] <= 0 for index in range(focal_count)):
            raise EvidenceError(
                f"{label} line {line_number} has a nonpositive focal length"
            )
        camera_ids.add(camera_id)
        cameras.append(
            {
                "camera_id": camera_id,
                "model": model,
                "width": width,
                "height": height,
                "parameters": parameters,
            }
        )
    if not cameras:
        raise EvidenceError(f"{label} contains no cameras")
    return cameras


def _resolved_camera_model(candidate_configuration: Mapping[str, Any]) -> str:
    projection = candidate_configuration["lens_projection"]
    detail = candidate_configuration["detail_profile"]
    capture = candidate_configuration["capture_path"]
    if projection == "fisheye":
        return "OPENCV_FISHEYE"
    if projection == "perspective":
        return "OPENCV" if detail == "high_detail" else "SIMPLE_RADIAL"
    if projection == "automatic":
        return (
            "OPENCV"
            if detail == "high_detail"
            and capture in {"through_space", "large_area"}
            else "SIMPLE_RADIAL"
        )
    raise EvidenceError("camera initialization lens projection is invalid")


def _resolved_camera_grouping(
    requested_grouping: Any,
    request: Mapping[str, Any],
) -> str:
    if requested_grouping == "same_camera_and_lens":
        return "sameCameraAndLens"
    if requested_grouping != "automatic":
        raise EvidenceError("camera grouping request is invalid")
    return (
        "sameCameraAndLens"
        if request["input_kind"] == "video"
        and request["video_source_count"] == 1
        else "mixedCamerasOrLenses"
    )


def _validate_geometry_camera_contract(
    geometry: Mapping[str, Any],
    cameras: list[dict[str, Any]],
    candidate_configuration: Mapping[str, Any],
    request: Mapping[str, Any],
    selection: SelectionManifestSources,
    context: str,
) -> None:
    requested_grouping = candidate_configuration["camera_grouping"]
    expected_geometry_grouping = _resolved_camera_grouping(
        requested_grouping, request
    )
    expected_camera_model = _resolved_camera_model(candidate_configuration)
    if geometry["cameraGrouping"] != expected_geometry_grouping:
        raise EvidenceError(f"{context} camera grouping contradicts the request")
    if (
        geometry["cameraModel"] != expected_camera_model
        or any(camera["model"] != expected_camera_model for camera in cameras)
    ):
        raise EvidenceError(f"{context} camera model contradicts the request")

    receipt = _mapping(
        geometry.get("cameraGroupingReceipt"),
        f"{context}.cameraGroupingReceipt",
    )
    _exact_keys(
        receipt,
        {
            "mode",
            "cameraCountBefore",
            "cameraCountAfter",
            "groupedVideoSourceCount",
            "groups",
        },
        f"{context}.cameraGroupingReceipt",
    )
    groups_value = receipt["groups"]
    if not isinstance(groups_value, list):
        raise EvidenceError(f"{context} camera grouping receipt is invalid")
    groups: list[Mapping[str, Any]] = []
    for index, value in enumerate(groups_value):
        group_context = f"{context}.cameraGroupingReceipt.groups[{index}]"
        group = _mapping(value, group_context)
        _exact_keys(
            group,
            {"sourceGroupID", "memberCount", "canonicalCameraID"},
            group_context,
        )
        groups.append(group)
    count_fields = (
        "cameraCountBefore",
        "cameraCountAfter",
        "groupedVideoSourceCount",
    )
    camera_ids = {camera["camera_id"] for camera in cameras}
    registered_view_count = geometry.get(
        "registeredViewCount", geometry["totalViewCount"]
    )
    if (
        type(geometry["totalViewCount"]) is not int
        or not 1 <= geometry["totalViewCount"] <= (1 << 63) - 1
        or type(registered_view_count) is not int
        or not 1 <= registered_view_count <= geometry["totalViewCount"]
        or len(cameras) > registered_view_count
        or any(
            type(receipt[field]) is not int
            or not 0 <= receipt[field] <= (1 << 63) - 1
            for field in count_fields
        )
        or receipt["cameraCountBefore"] < 1
        or receipt["cameraCountAfter"] != len(cameras)
        or receipt["cameraCountAfter"] > receipt["cameraCountBefore"]
        or receipt["groupedVideoSourceCount"] < 0
        or any(
            not isinstance(group["sourceGroupID"], str)
            or not group["sourceGroupID"]
            or type(group["memberCount"]) is not int
            or not 0 < group["memberCount"] <= (1 << 63) - 1
            or type(group["canonicalCameraID"]) is not int
            or not 0 < group["canonicalCameraID"] <= (1 << 63) - 1
            or group["canonicalCameraID"] not in camera_ids
            for group in groups
        )
        or len({group["sourceGroupID"] for group in groups}) != len(groups)
        or len({group["canonicalCameraID"] for group in groups}) != len(groups)
    ):
        raise EvidenceError(f"{context} camera grouping receipt is invalid")

    mode = receipt["mode"]
    has_video = "video" in selection.source_kinds
    expected_mode = (
        "allSelectedImagesShared"
        if expected_geometry_grouping == "sameCameraAndLens"
        else "videoSourceGroups"
        if has_video
        else "preserveExisting"
    )
    if mode != expected_mode:
        raise EvidenceError(f"{context} camera grouping receipt contradicts the request")
    if mode == "preserveExisting":
        valid_grouping = (
            receipt["cameraCountBefore"] == receipt["cameraCountAfter"]
            and receipt["groupedVideoSourceCount"] == 0
            and not groups
        )
    elif mode == "videoSourceGroups":
        expected_video_groups: dict[str, int] = {}
        for clip_id, source_kind in zip(
            selection.clip_ids, selection.source_kinds, strict=True
        ):
            if source_kind == "video":
                expected_video_groups[clip_id] = (
                    expected_video_groups.get(clip_id, 0) + 1
                )
        actual_video_groups = {
            group["sourceGroupID"]: group["memberCount"] for group in groups
        }
        valid_grouping = (
            receipt["groupedVideoSourceCount"] == len(expected_video_groups)
            and actual_video_groups == expected_video_groups
            and [group["sourceGroupID"] for group in groups]
            == sorted(expected_video_groups)
            and receipt["cameraCountAfter"] >= len(groups)
        )
    elif mode == "allSelectedImagesShared":
        valid_grouping = (
            len(cameras) == 1
            and receipt["cameraCountAfter"] == 1
            and receipt["groupedVideoSourceCount"] == request["video_source_count"]
            and len(groups) == 1
            and groups[0]["sourceGroupID"] == "all-selected-images"
            and groups[0]["memberCount"] == geometry["totalViewCount"]
            and groups[0]["canonicalCameraID"] == cameras[0]["camera_id"]
        )
    else:
        valid_grouping = False
    if not valid_grouping:
        raise EvidenceError(f"{context} camera grouping receipt is invalid")

    initialization_context = f"{context}.cameraInitializationReceipt"
    initialization = _mapping(
        geometry.get("cameraInitializationReceipt"), initialization_context
    )
    _exact_keys(
        initialization,
        {
            "recipe",
            "cameraModel",
            "singleCamera",
            "pixelWidth",
            "pixelHeight",
            "diagonalFieldOfViewDegrees",
            "cameraParameters",
            "priorFocalLength",
        },
        initialization_context,
    )
    initialization_model = initialization["cameraModel"]
    if (
        not isinstance(initialization_model, str)
        or initialization_model != expected_camera_model
        or type(initialization["singleCamera"]) is not bool
        or initialization["singleCamera"] != (mode == "allSelectedImagesShared")
        or type(initialization["priorFocalLength"]) is not bool
    ):
        raise EvidenceError(f"{context} camera initialization receipt is invalid")
    expected_recipe = (
        "sharedOpenCVFisheyeEquidistantDiagonal150V1"
        if geometry["cameraModel"] == "OPENCV_FISHEYE"
        and mode == "allSelectedImagesShared"
        else "colmapAutomatic"
    )
    if initialization["recipe"] != expected_recipe:
        raise EvidenceError(f"{initialization_context} recipe is invalid")
    synthetic_fields = (
        "pixelWidth",
        "pixelHeight",
        "diagonalFieldOfViewDegrees",
        "cameraParameters",
    )
    if expected_recipe == "colmapAutomatic":
        if (
            any(initialization[field] is not None for field in synthetic_fields)
            or initialization["priorFocalLength"]
        ):
            raise EvidenceError(f"{initialization_context} automatic prior is invalid")
        return

    parameters = initialization["cameraParameters"]
    width = initialization["pixelWidth"]
    height = initialization["pixelHeight"]
    if (
        initialization_model != "OPENCV_FISHEYE"
        or initialization_model != geometry["cameraModel"]
        or type(width) is not int
        or not 1 <= width <= 1_000_000
        or type(height) is not int
        or not 1 <= height <= 1_000_000
        or len(cameras) != 1
        or width != cameras[0]["width"]
        or height != cameras[0]["height"]
        or not _finite_number(initialization["diagonalFieldOfViewDegrees"])
        or initialization["diagonalFieldOfViewDegrees"] != 150
        or not isinstance(parameters, list)
        or len(parameters) != 8
        or not all(_finite_number(parameter) for parameter in parameters)
        or not initialization["priorFocalLength"]
    ):
        raise EvidenceError(f"{initialization_context} shared fisheye prior is invalid")
    half_width = width / 2
    half_height = height / 2
    expected_focal = math.hypot(half_width, half_height) / (75 * math.pi / 180)
    tolerance = max(1, abs(expected_focal)) * 1e-12
    if (
        abs(parameters[0] - expected_focal) > tolerance
        or abs(parameters[1] - expected_focal) > tolerance
        or parameters[2] != half_width
        or parameters[3] != half_height
        or any(parameter != 0 for parameter in parameters[4:])
    ):
        raise EvidenceError(f"{initialization_context} shared fisheye prior is invalid")


def _finite_number(value: Any) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(value)
    )


def _validate_unit_direction(value: Any, context: str) -> None:
    direction = _mapping(value, context)
    _exact_keys(direction, {"x", "y", "z"}, context)
    components = [direction[field] for field in ("x", "y", "z")]
    if not all(
        _finite_number(component) for component in components
    ) or not math.isclose(
        sum(float(component) ** 2 for component in components),
        1.0,
        rel_tol=0,
        abs_tol=1e-6,
    ):
        raise EvidenceError(f"{context} is invalid")


def _validate_orientation_evidence(
    value: Any,
    *,
    registered_view_count: int,
    context: str,
) -> None:
    orientation_evidence = _mapping(value, context)
    required_fields = {
        "supportCount",
        "eigenvalue0",
        "eigenvalue1",
        "eigenvalue2",
        "eigengap",
        "medianResidualDegrees",
        "p90ResidualDegrees",
        "bootstrapP95VariationDegrees",
    }
    optional_fields = {
        "medianAbsoluteImageUpAgreement",
        "signAgreement",
        "trajectoryPlaneAgreementDegrees",
        "trajectoryLineConcentration",
        "cameraUpConcentration",
        "cameraUpMedianSpreadDegrees",
        "cameraUpP90SpreadDegrees",
    }
    missing = required_fields - set(orientation_evidence)
    extra = set(orientation_evidence) - required_fields - optional_fields
    if missing or extra:
        raise EvidenceError(f"{context} fields are invalid")
    support_count = orientation_evidence["supportCount"]
    finite_fields = required_fields - {"supportCount"}
    if (
        type(support_count) is not int
        or not 0 < support_count <= registered_view_count
        or any(
            not _finite_number(orientation_evidence[field]) for field in finite_fields
        )
    ):
        raise EvidenceError(f"{context} values are invalid")
    eigenvalues = [
        float(orientation_evidence[field])
        for field in ("eigenvalue0", "eigenvalue1", "eigenvalue2")
    ]
    if (
        not 0 <= eigenvalues[0] <= eigenvalues[1] <= eigenvalues[2]
        or not math.isclose(sum(eigenvalues), 1.0, rel_tol=0, abs_tol=1e-6)
        or float(orientation_evidence["eigengap"]) < 0
        or float(orientation_evidence["medianResidualDegrees"]) < 0
        or float(orientation_evidence["p90ResidualDegrees"])
        < float(orientation_evidence["medianResidualDegrees"])
        or float(orientation_evidence["bootstrapP95VariationDegrees"]) < 0
    ):
        raise EvidenceError(f"{context} values are invalid")
    unit_interval_fields = {
        "medianAbsoluteImageUpAgreement",
        "signAgreement",
        "trajectoryLineConcentration",
        "cameraUpConcentration",
    }
    degree_fields = {
        "trajectoryPlaneAgreementDegrees",
        "cameraUpMedianSpreadDegrees",
        "cameraUpP90SpreadDegrees",
    }
    for field in optional_fields:
        optional_value = orientation_evidence.get(field)
        if optional_value is None:
            continue
        if not _finite_number(optional_value):
            raise EvidenceError(f"{context}.{field} is invalid")
        number = float(optional_value)
        if (field in unit_interval_fields and not 0 <= number <= 1) or (
            field in degree_fields and not 0 <= number <= 180
        ):
            raise EvidenceError(f"{context}.{field} is invalid")


def _validate_canonical_orientation_artifact(
    value: Any,
    *,
    registered_view_count: int,
) -> None:
    context = "geometry manifest canonical orientation"
    orientation = _mapping(value, context)
    required_fields = {"status", "canonicalOpeningViewDirection"}
    optional_fields = {
        "method",
        "sourceToCanonicalQuaternionWXYZ",
        "evidence",
    }
    missing = required_fields - set(orientation)
    extra = set(orientation) - required_fields - optional_fields
    if missing or extra:
        raise EvidenceError(f"{context} fields are invalid")
    status = orientation["status"]
    if status not in {"verified", "axisAlignedSignUnverified", "unresolved"}:
        raise EvidenceError(f"{context} status is invalid")
    _validate_unit_direction(
        orientation["canonicalOpeningViewDirection"],
        f"{context}.canonicalOpeningViewDirection",
    )
    method = orientation.get("method")
    quaternion_value = orientation.get("sourceToCanonicalQuaternionWXYZ")
    orientation_evidence = orientation.get("evidence")
    if method is not None and method not in {
        "cameraRightNullspace",
        "cameraUpConsensus",
    }:
        raise EvidenceError(f"{context} method is invalid")
    if status == "unresolved":
        if quaternion_value is not None or (method is None) != (
            orientation_evidence is None
        ):
            raise EvidenceError(f"{context} unresolved shape is invalid")
        if orientation_evidence is not None:
            _validate_orientation_evidence(
                orientation_evidence,
                registered_view_count=registered_view_count,
                context=f"{context}.evidence",
            )
        return
    if method is None or quaternion_value is None or orientation_evidence is None:
        raise EvidenceError(f"{context} resolved shape is invalid")
    quaternion = _mapping(
        quaternion_value, f"{context}.sourceToCanonicalQuaternionWXYZ"
    )
    _exact_keys(
        quaternion,
        {"w", "x", "y", "z"},
        f"{context}.sourceToCanonicalQuaternionWXYZ",
    )
    components = [quaternion[field] for field in ("w", "x", "y", "z")]
    if not all(
        _finite_number(component) for component in components
    ) or not math.isclose(
        sum(float(component) ** 2 for component in components),
        1.0,
        rel_tol=0,
        abs_tol=1e-6,
    ):
        raise EvidenceError(f"{context} quaternion is invalid")
    first_nonzero = next(
        (float(component) for component in components if float(component) != 0),
        0.0,
    )
    if first_nonzero <= 0:
        raise EvidenceError(f"{context} quaternion is not canonical")
    _validate_orientation_evidence(
        orientation_evidence,
        registered_view_count=registered_view_count,
        context=f"{context}.evidence",
    )


def _validate_geometry_conditioning_artifact(
    value: Any,
    *,
    registered_view_count: int,
    point_count: int,
    observation_count: int,
    model_hashes: Mapping[str, str],
) -> None:
    context = "geometry manifest conditioning"
    conditioning = _mapping(value, context)
    _exact_keys(
        conditioning,
        {
            "schemaVersion",
            "measurementProvenance",
            "acceptancePolicy",
            "maximumRayPairEvaluations",
            "sourceModelClosureSHA256",
            "measurement",
        },
        context,
    )
    if (
        type(conditioning["schemaVersion"]) is not int
        or conditioning["schemaVersion"] != GEOMETRY_CONDITIONING_SCHEMA_VERSION
    ):
        raise EvidenceError("geometry manifest conditioning schema is invalid")
    if (
        conditioning["measurementProvenance"] != GEOMETRY_CONDITIONING_PROVENANCE
        or conditioning["acceptancePolicy"] != GEOMETRY_CONDITIONING_ACCEPTANCE_POLICY
        or type(conditioning["maximumRayPairEvaluations"]) is not int
        or conditioning["maximumRayPairEvaluations"]
        != GEOMETRY_CONDITIONING_MAXIMUM_RAY_PAIR_EVALUATIONS
        or conditioning["sourceModelClosureSHA256"]
        != geometry_model_closure_digest(model_hashes)
    ):
        raise EvidenceError("geometry manifest conditioning identity is invalid")

    measurement_context = f"{context} measurement"
    measurement = _mapping(conditioning["measurement"], measurement_context)
    integer_fields = {
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
    }
    numeric_fields = {
        "perViewObservationMedian",
        "distinctTrackLengthMedian",
        "medianObservedDepth",
        "cameraBaselineToMedianDepthRatio",
        "cameraCenterMergeToleranceToMedianDepthRatio",
        "adaptiveParallaxThresholdMedianDegrees",
        "adaptiveParallaxThresholdP90Degrees",
    }
    eigenvalue_fields = {"cameraCenterEigenvalues", "pointEigenvalues"}
    _exact_keys(
        measurement,
        integer_fields | numeric_fields | eigenvalue_fields,
        measurement_context,
    )
    if any(
        type(measurement[field]) is not int or measurement[field] < 0
        for field in integer_fields
    ) or any(not _finite_number(measurement[field]) for field in numeric_fields):
        raise EvidenceError(f"{measurement_context} values are invalid")
    for field in eigenvalue_fields:
        values = measurement[field]
        if (
            not isinstance(values, list)
            or len(values) != 3
            or not all(_finite_number(item) for item in values)
        ):
            raise EvidenceError(f"{measurement_context}.{field} is invalid")
        normalized = [float(item) for item in values]
        if not 0 <= normalized[0] <= normalized[1] <= normalized[
            2
        ] <= 1 or not math.isclose(sum(normalized), 1.0, rel_tol=0, abs_tol=1e-9):
            raise EvidenceError(f"{measurement_context}.{field} is invalid")

    registered_pairs = registered_view_count * (registered_view_count - 1) // 2
    effective_count = measurement["effectiveCameraCenterCount"]
    effective_pairs = effective_count * (effective_count - 1) // 2
    expected_camera_pairs = registered_pairs
    if measurement["largestCameraCenterClusterSize"] > 1:
        expected_camera_pairs += effective_pairs
    total_pair_evaluations = (
        measurement["cameraPairEvaluationCount"] + measurement["rayPairEvaluationCount"]
    )
    if (
        measurement["registeredViewCount"] != registered_view_count
        or measurement["pointCount"] != point_count
        or measurement["observationCount"] != observation_count
        or measurement["positiveDepthObservationCount"] != observation_count
        or not 0 <= measurement["stronglyMeasuredViewCount"] <= registered_view_count
        or not 0
        <= measurement["perViewObservationMinimum"]
        <= measurement["perViewObservationP10"]
        <= float(measurement["perViewObservationMedian"])
        <= measurement["perViewObservationP90"]
        <= observation_count
        or not 2
        <= measurement["distinctTrackLengthMinimum"]
        <= measurement["distinctTrackLengthP10"]
        <= float(measurement["distinctTrackLengthMedian"])
        <= measurement["distinctTrackLengthP90"]
        <= registered_view_count
        or not 0
        <= measurement["pointsAtLeast3Degrees"]
        <= measurement["pointsAtLeast2Degrees"]
        <= measurement["pointsAtLeast1Point5Degrees"]
        <= point_count
        or not 0
        <= measurement["observationsAtLeast3Degrees"]
        <= measurement["observationsAtLeast2Degrees"]
        <= measurement["observationsAtLeast1Point5Degrees"]
        <= observation_count
        or not min(3, registered_view_count) <= effective_count <= registered_view_count
        or not 0
        < measurement["largestCameraCenterClusterSize"]
        <= registered_view_count
        or float(measurement["cameraCenterMergeToleranceToMedianDepthRatio"]) != 1e-5
        or not point_count // 2 + point_count % 2
        <= measurement["numericallyConditionedPointCount"]
        <= point_count
        or not 0
        < measurement["numericallyConditionedObservationCount"]
        <= observation_count
        or float(measurement["medianObservedDepth"]) <= 0
        or float(measurement["cameraBaselineToMedianDepthRatio"])
        <= float(measurement["cameraCenterMergeToleranceToMedianDepthRatio"])
        or float(measurement["adaptiveParallaxThresholdMedianDegrees"]) < 0.05 - 1e-12
        or float(measurement["adaptiveParallaxThresholdP90Degrees"])
        < float(measurement["adaptiveParallaxThresholdMedianDegrees"])
        or measurement["cameraPairEvaluationCount"] != expected_camera_pairs
        or measurement["rayPairEvaluationCount"] <= 0
        or total_pair_evaluations > conditioning["maximumRayPairEvaluations"]
    ):
        raise EvidenceError(f"{measurement_context} is invalid")


def _validate_pair_graph_artifact(
    value: Any,
    *,
    total_view_count: int,
    candidate_configuration: Mapping[str, Any],
    requires_cross_clip_retrieval: bool = False,
) -> tuple[str, bool, bool]:
    context = "geometry manifest pair graph"
    pair_graph = _mapping(value, context)
    _exact_keys(
        pair_graph,
        {
            "status",
            "measurement",
            "requiresCrossClipRetrieval",
            "retrievalWasScheduled",
            "usedLocalVocabularyRetrieval",
        },
        context,
    )
    status = pair_graph["status"]
    recorded_cross_clip_requirement = pair_graph["requiresCrossClipRetrieval"]
    retrieval_was_scheduled = pair_graph["retrievalWasScheduled"]
    retrieval_used = pair_graph["usedLocalVocabularyRetrieval"]
    if (
        not isinstance(status, str)
        or status not in {"measured", "notEvaluated"}
        or type(recorded_cross_clip_requirement) is not bool
        or recorded_cross_clip_requirement != requires_cross_clip_retrieval
        or type(retrieval_was_scheduled) is not bool
        or type(retrieval_used) is not bool
        or (retrieval_used and not retrieval_was_scheduled)
    ):
        raise EvidenceError(f"{context} is invalid")
    if status == "notEvaluated":
        if (
            pair_graph["measurement"] is not None
            or recorded_cross_clip_requirement
            or retrieval_was_scheduled
            or retrieval_used
        ):
            raise EvidenceError(f"{context} is invalid")
        return status, retrieval_was_scheduled, retrieval_used

    retrieval_required = (
        _retrieval_required_by_plan(
            candidate_configuration,
            total_view_count=total_view_count,
        )
        or requires_cross_clip_retrieval
    )
    if retrieval_was_scheduled != retrieval_required:
        if retrieval_required:
            raise EvidenceError(
                f"{context} omitted vocabulary retrieval required by the resolved plan"
            )
        raise EvidenceError(
            f"{context} scheduled vocabulary retrieval outside the resolved plan"
        )

    measurement = _mapping(pair_graph["measurement"], f"{context} measurement")
    measurement_fields = {
        "pairingPolicy",
        "scheduledPairCount",
        "attemptedPairCount",
        "rawMatchedPairCount",
        "spatiallyVerifiedPairCount",
        "localPairCount",
        "retrievalPairCount",
        "loopRevisitPairCount",
        "connectedComponentCount",
        "isolatedViewCount",
        "descriptorlessViewCount",
        "componentViewCounts",
        "articulationViewCount",
        "biconnectedBlockCount",
        "largestBiconnectedBlockViewCount",
        "secondLargestBiconnectedBlockViewCount",
        "degreeP10",
        "degreeMedian",
        "degreeP90",
        "matcherAttempts",
        "pairListDigest",
        "featureDatabaseDigest",
        "matchingDatabaseDigest",
        "matchingDurationSeconds",
    }
    _exact_keys(measurement, measurement_fields, f"{context} measurement")
    if measurement["pairingPolicy"] not in {
        "unorderedRetrieval",
        "segmentedMixed",
        "orderedContinuous",
        "orderedOrbit",
        "orderedWalkthrough",
        "orderedLargeArea",
    }:
        raise EvidenceError(f"{context} measurement is invalid")
    count_fields = {
        "scheduledPairCount",
        "attemptedPairCount",
        "rawMatchedPairCount",
        "spatiallyVerifiedPairCount",
        "localPairCount",
        "retrievalPairCount",
        "loopRevisitPairCount",
        "connectedComponentCount",
        "isolatedViewCount",
        "descriptorlessViewCount",
        "articulationViewCount",
        "biconnectedBlockCount",
        "largestBiconnectedBlockViewCount",
        "secondLargestBiconnectedBlockViewCount",
        "degreeP10",
        "degreeMedian",
        "degreeP90",
    }
    if any(
        type(measurement[field]) is not int or measurement[field] < 0
        for field in count_fields
    ):
        raise EvidenceError(f"{context} measurement is invalid")
    scheduled = measurement["scheduledPairCount"]
    attempted = measurement["attemptedPairCount"]
    raw_matched = measurement["rawMatchedPairCount"]
    verified = measurement["spatiallyVerifiedPairCount"]
    role_count = (
        measurement["localPairCount"]
        + measurement["retrievalPairCount"]
        + measurement["loopRevisitPairCount"]
    )
    component_counts = measurement["componentViewCounts"]
    measured_isolated_view_count = (
        sum(count == 1 for count in component_counts)
        if isinstance(component_counts, list)
        else -1
    )
    has_minor_verified_component = (
        any(count > 1 for count in component_counts[1:])
        if isinstance(component_counts, list)
        else False
    )
    required_dominant_fraction = (
        0.95 if has_minor_verified_component else 0.90
    )
    if (
        not 0 <= verified <= raw_matched <= attempted <= scheduled
        or role_count != scheduled
        or not isinstance(component_counts, list)
        or not component_counts
        or any(type(count) is not int or count <= 0 for count in component_counts)
        or component_counts != sorted(component_counts, reverse=True)
        or sum(component_counts) != total_view_count
        or measured_isolated_view_count != measurement["isolatedViewCount"]
        or measurement["descriptorlessViewCount"]
        > measurement["isolatedViewCount"]
        or measurement["connectedComponentCount"] != len(component_counts)
        or component_counts[0] < 2
        or component_counts[0] / total_view_count < required_dominant_fraction
        or measurement["degreeP10"] > measurement["degreeMedian"]
        or measurement["degreeMedian"] > measurement["degreeP90"]
        or measurement["degreeP90"] >= max(component_counts)
    ):
        raise EvidenceError(f"{context} measurement is invalid")
    for digest_field in (
        "pairListDigest",
        "featureDatabaseDigest",
        "matchingDatabaseDigest",
    ):
        digest = measurement[digest_field]
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise EvidenceError(f"{context} measurement is invalid")
    duration = measurement["matchingDurationSeconds"]
    attempts = measurement["matcherAttempts"]
    if (
        isinstance(duration, bool)
        or not isinstance(duration, (int, float))
        or not math.isfinite(duration)
        or duration < 0
        or not isinstance(attempts, list)
        or not attempts
        or len(attempts) > MAXIMUM_PAIR_GRAPH_MATCHER_ATTEMPTS
    ):
        raise EvidenceError(f"{context} measurement is invalid")
    attempt_fields = {
        "attemptNumber",
        "matcher",
        "recoveryLevel",
        "outcome",
        "scheduledPairCount",
        "attemptedPairCount",
        "rawMatchedPairCount",
        "spatiallyVerifiedPairCount",
        "durationSeconds",
    }
    optional_attempt_fields = {"exactRecoveryReason"}
    measured_duration = 0.0
    for index, raw_attempt in enumerate(attempts, start=1):
        attempt = _mapping(raw_attempt, f"{context} matcher attempt {index}")
        if not attempt_fields.issubset(attempt) or not set(attempt).issubset(
            attempt_fields | optional_attempt_fields
        ):
            raise EvidenceError(f"{context} matcher attempt has invalid fields")
        attempt_duration = attempt["durationSeconds"]
        attempt_counts = [
            attempt["scheduledPairCount"],
            attempt["attemptedPairCount"],
            attempt["rawMatchedPairCount"],
            attempt["spatiallyVerifiedPairCount"],
        ]
        if (
            type(attempt["attemptNumber"]) is not int
            or attempt["attemptNumber"] != index
            or attempt["matcher"] not in {"faiss", "exact"}
            or (attempt["matcher"] == "exact")
            != _valid_exact_recovery_reason(attempt.get("exactRecoveryReason"))
            or attempt["recoveryLevel"] not in {"normal", "expanded", "maximum"}
            or attempt["outcome"] not in {"completed", "rejected", "failed"}
            or any(type(count) is not int or count < 0 for count in attempt_counts)
            or not 0
            <= attempt_counts[3]
            <= attempt_counts[2]
            <= attempt_counts[1]
            <= attempt_counts[0]
            or (
                attempt["outcome"] != "failed"
                and attempt["attemptedPairCount"] != attempt["scheduledPairCount"]
            )
            or isinstance(attempt_duration, bool)
            or not isinstance(attempt_duration, (int, float))
            or not math.isfinite(attempt_duration)
            or attempt_duration < 0
        ):
            raise EvidenceError(f"{context} matcher attempt is invalid")
        measured_duration += float(attempt_duration)
    accepted_attempt = attempts[-1]
    if (
        attempts[0]["matcher"] != "faiss"
        or accepted_attempt["outcome"] != "completed"
        or accepted_attempt["scheduledPairCount"] != scheduled
        or accepted_attempt["attemptedPairCount"] != attempted
        or accepted_attempt["rawMatchedPairCount"] != raw_matched
        or accepted_attempt["spatiallyVerifiedPairCount"] != verified
        or not math.isclose(
            measured_duration, float(duration), rel_tol=1e-12, abs_tol=1e-12
        )
    ):
        raise EvidenceError(f"{context} measurement is invalid")
    _validate_matcher_recovery_history(
        attempts,
        total_view_count=total_view_count,
        pairing_policy=measurement["pairingPolicy"],
    )
    return status, retrieval_was_scheduled, retrieval_used


def _retrieval_required_by_plan(
    candidate_configuration: Mapping[str, Any],
    *,
    total_view_count: int,
) -> bool:
    policy = candidate_configuration["pairing_policy"]
    if policy == "generic_continuous":
        return total_view_count >= 120
    if policy == "object_orbit":
        return True
    if policy == "unordered_exhaustive":
        return False
    return policy in {
        "walkthrough",
        "large_area",
        "segmented_mixed",
        "unordered_retrieval",
    }


def _requires_cross_clip_retrieval(
    request: Mapping[str, Any],
    candidate_configuration: Mapping[str, Any],
) -> bool:
    return (
        request["input_kind"] == "multi_video"
        and candidate_configuration["input_topology"]
        in {"continuous", "segmented_mixed"}
    )


def _validate_matcher_recovery_history(
    attempts: list[Any],
    *,
    total_view_count: int,
    pairing_policy: str,
    fallback_reason_count: int | None = None,
) -> None:
    level_index = {"normal": 0, "expanded": 1, "maximum": 2}
    if (
        not attempts
        or attempts[0]["matcher"] != "faiss"
        or attempts[0].get("exactRecoveryReason") is not None
    ):
        raise EvidenceError("pair-graph recovery must begin with FAISS")
    unordered_small_exhaustive = (
        pairing_policy == "unorderedRetrieval" and 2 <= total_view_count <= 60
    )
    if fallback_reason_count is not None and (
        type(fallback_reason_count) is not int or fallback_reason_count < 0
    ):
        raise EvidenceError("pair-graph fallback evidence is invalid")
    first_level = level_index[attempts[0]["recoveryLevel"]]
    maximum_initial_level = (
        2 if fallback_reason_count is None else min(2, fallback_reason_count)
    )
    if first_level > maximum_initial_level:
        raise EvidenceError("pair-graph recovery skipped unauthenticated densities")
    for index in range(1, len(attempts)):
        previous = attempts[index - 1]
        current = attempts[index]
        previous_level = level_index[previous["recoveryLevel"]]
        current_level = level_index[current["recoveryLevel"]]
        maximum_step = (
            2
            if fallback_reason_count is None
            else min(2, max(1, fallback_reason_count))
        )
        if (
            current_level < previous_level
            or current_level - previous_level > maximum_step
        ):
            raise EvidenceError("pair-graph recovery skipped unauthenticated densities")

        if current["matcher"] == "exact":
            reason = current.get("exactRecoveryReason")
            if (
                not _valid_exact_recovery_reason(reason)
                or not 1
                <= current["scheduledPairCount"]
                <= MAXIMUM_EXACT_RECOVERY_PAIR_COUNT
            ):
                raise EvidenceError(
                    "pair-graph exact recovery is untyped or exceeds the 256-pair limit"
                )
            exhaustive_pair_count = total_view_count * (total_view_count - 1) // 2
            faiss_exhausted = previous["outcome"] == "rejected" and (
                previous_level == level_index["maximum"]
                or (
                unordered_small_exhaustive
                and previous_level == level_index["normal"]
                and previous["scheduledPairCount"] == exhaustive_pair_count
                )
            )
            reason_is_bound = (
                reason in ("faissCrash", "faissUnsupportedOperation")
                and previous["outcome"] == "failed"
            ) or (
                reason == "faissGeometryRejectedAfterRetries" and faiss_exhausted
            )
            if (
                previous["matcher"] != "faiss"
                or current_level != previous_level
                or current["scheduledPairCount"] != previous["scheduledPairCount"]
                or not reason_is_bound
            ):
                raise EvidenceError("pair-graph exact recovery was premature")
            continue

        if current.get("exactRecoveryReason") is not None:
            raise EvidenceError("pair-graph FAISS attempt claims exact recovery")
        if previous["matcher"] != "faiss":
            raise EvidenceError("pair-graph recovery has an invalid matcher history")
        if current_level == previous_level:
            if (
                previous["outcome"] == "completed"
                or current["scheduledPairCount"] != previous["scheduledPairCount"]
            ):
                raise EvidenceError(
                    "pair-graph same-level recovery changed its schedule"
                )
            continue
        if unordered_small_exhaustive:
            raise EvidenceError(
                "pair-graph recovery expanded an already exhaustive graph"
            )
        repeated_planning_failure = (
            current["outcome"] == "failed"
            and current["attemptedPairCount"] == 0
            and current["rawMatchedPairCount"] == 0
            and current["spatiallyVerifiedPairCount"] == 0
        )
        if (
            current["scheduledPairCount"] == previous["scheduledPairCount"]
            and not repeated_planning_failure
        ):
            raise EvidenceError("pair-graph recovery did not expand its FAISS schedule")


def _validate_runtime_worker_evidence(
    value: Any,
    candidate_configuration: Mapping[str, Any],
    request: Mapping[str, Any],
    execution_variant: str,
    run_id: str,
    artifact_root: Path,
    descriptors: Mapping[str, Any],
    used_artifacts: set[str],
    context: str,
    pipeline_metrics: Mapping[str, Any] | None,
    selection_sources: SelectionManifestSources | None = None,
) -> dict[str, Any]:
    receipt = _mapping(value, context)
    _exact_keys(
        receipt,
        {
            "artifact_name",
            "artifact_sha256",
            "geometry_manifest_name",
            "geometry_manifest_sha256",
            "canonical_cameras_name",
            "canonical_cameras_sha256",
            "geometry_input_digest",
            "selected_frames_digest",
        },
        context,
    )
    artifact_name = _token(receipt["artifact_name"], f"{context}.artifact_name")
    receipt_digest = _digest(
        receipt["artifact_sha256"],
        f"{context}.artifact_sha256",
    )
    geometry_name = _token(
        receipt["geometry_manifest_name"],
        f"{context}.geometry_manifest_name",
    )
    geometry_digest = _digest(
        receipt["geometry_manifest_sha256"],
        f"{context}.geometry_manifest_sha256",
    )
    canonical_cameras_name = _token(
        receipt["canonical_cameras_name"],
        f"{context}.canonical_cameras_name",
    )
    canonical_cameras_digest = _digest(
        receipt["canonical_cameras_sha256"],
        f"{context}.canonical_cameras_sha256",
    )
    geometry_input_digest = _digest(
        receipt["geometry_input_digest"],
        f"{context}.geometry_input_digest",
    )
    selected_frames_digest = _digest(
        receipt["selected_frames_digest"],
        f"{context}.selected_frames_digest",
    )
    reference_artifacts = _mapping(
        request["reference_artifacts"],
        "request.reference_artifacts",
    )
    protected_geometry_input_digest = _digest(
        reference_artifacts["geometry_input_digest"],
        "request.reference_artifacts.geometry_input_digest",
    )
    selected_frame_digests = _mapping(
        reference_artifacts["selected_frames_digests"],
        "request.reference_artifacts.selected_frames_digests",
    )
    if execution_variant not in {"candidate", "fast_candidate"}:
        raise EvidenceError("runtime geometry execution variant is invalid")
    expected_selected_frames_digest = _digest(
        selected_frame_digests[execution_variant],
        "request.reference_artifacts selected-frame digest",
    )
    if geometry_input_digest != protected_geometry_input_digest:
        raise EvidenceError(
            "runtime geometry input digest does not match the protected input"
        )
    if selected_frames_digest != expected_selected_frames_digest:
        raise EvidenceError(
            "runtime geometry selected-frame digest does not match the protected selected frames"
        )
    if not isinstance(selection_sources, SelectionManifestSources):
        selection_descriptor = _mapping(
            descriptors.get("selection_manifest"),
            "artifacts.selection_manifest",
        )
        _exact_keys(
            selection_descriptor,
            {"path", "sha256", "bytes"},
            "artifacts.selection_manifest",
        )
        if (
            selection_descriptor["sha256"]
            != reference_artifacts["selection_manifest_sha256"]
        ):
            raise EvidenceError(
                "selection manifest does not match the protected reference"
            )
        selection_sources = _validate_selection_manifest_sources(
            artifact_root / selection_descriptor["path"],
            requested_scale=request["binding"]["scale"],
            input_kind=request["input_kind"],
            expected_video_source_count=request["video_source_count"],
        )
    artifact_tokens = {artifact_name, geometry_name, canonical_cameras_name}
    if len(artifact_tokens) != 3:
        raise EvidenceError(
            "worker, geometry, and canonical-camera artifacts must use distinct descriptors"
        )
    if artifact_tokens & used_artifacts:
        raise EvidenceError("runtime worker artifact cannot be reused across runs")
    used_artifacts.update(artifact_tokens)
    descriptor = _mapping(
        descriptors.get(artifact_name),
        f"artifacts.{artifact_name}",
    )
    _exact_keys(descriptor, {"path", "sha256", "bytes"}, f"artifacts.{artifact_name}")
    expected_path = (
        f"worker-runs/{run_id}/project.easysplatproj/SfM/worker_execution.json"
    )
    if descriptor["path"] != expected_path:
        raise EvidenceError(
            "runtime worker artifact path does not match its execution run"
        )
    if descriptor["sha256"] != receipt_digest:
        raise EvidenceError("runtime worker artifact digest does not match its receipt")
    if (
        type(descriptor["bytes"]) is not int
        or not 0 < descriptor["bytes"] <= MAX_WORKER_EXECUTION_ARTIFACT_BYTES
    ):
        raise EvidenceError("runtime worker artifact exceeds its size limit")
    relative_path = PurePosixPath(expected_path)
    artifact = _mapping(
        _load_runtime_json_artifact(
            artifact_root,
            relative_path,
            receipt_digest,
            f"runtime worker artifact {run_id}",
            MAX_WORKER_EXECUTION_ARTIFACT_BYTES,
        ),
        f"runtime worker artifact {run_id}",
    )

    geometry_descriptor = _mapping(
        descriptors.get(geometry_name),
        f"artifacts.{geometry_name}",
    )
    _exact_keys(
        geometry_descriptor,
        {"path", "sha256", "bytes"},
        f"artifacts.{geometry_name}",
    )
    expected_geometry_path = (
        f"worker-runs/{run_id}/project.easysplatproj/SfM/geometry_manifest.json"
    )
    if geometry_descriptor["path"] != expected_geometry_path:
        raise EvidenceError("geometry manifest path does not match its execution run")
    if geometry_descriptor["sha256"] != geometry_digest:
        raise EvidenceError("geometry manifest digest does not match its receipt")
    if (
        type(geometry_descriptor["bytes"]) is not int
        or not 0 < geometry_descriptor["bytes"] <= MAX_GEOMETRY_MANIFEST_BYTES
    ):
        raise EvidenceError("geometry manifest exceeds its size limit")
    geometry = _mapping(
        _load_runtime_json_artifact(
            artifact_root,
            PurePosixPath(expected_geometry_path),
            geometry_digest,
            f"geometry manifest {run_id}",
            MAX_GEOMETRY_MANIFEST_BYTES,
        ),
        f"geometry manifest {run_id}",
    )
    geometry_context = f"geometry manifest {run_id}"
    required_geometry_fields = {
        "schemaVersion",
        "solverVersion",
        "runtimeVersion",
        "modelVersion",
        "inputDigest",
        "selectedFramesDigest",
        "orderedImageNames",
        "orderedImageTimestamps",
        "sourceModelPath",
        "poseConvention",
        "quaternionOrder",
        "handedness",
        "scaleType",
        "cameraModel",
        "cameraGrouping",
        "registeredViewCount",
        "totalViewCount",
        "observationCount",
        "pointCount",
        "residualProvenance",
        "medianPixelResidual",
        "p90PixelResidual",
        "conditioning",
        "timings",
        "peakMemoryBytes",
        "modelHashes",
        "provenance",
        "pairGraph",
        "mapping",
        "workerExecution",
        "canonicalOrientation",
        "cameraGroupingReceipt",
        "cameraInitializationReceipt",
        "featureDatabaseDigest",
    }
    optional_geometry_fields = {
        "fallbackReason",
        "learnedPointInitializer",
    }
    missing_geometry_fields = required_geometry_fields - set(geometry)
    extra_geometry_fields = (
        set(geometry) - required_geometry_fields - optional_geometry_fields
    )
    if missing_geometry_fields or extra_geometry_fields:
        details = []
        if missing_geometry_fields:
            details.append("missing " + ", ".join(sorted(missing_geometry_fields)))
        if extra_geometry_fields:
            details.append("extra " + ", ".join(sorted(extra_geometry_fields)))
        raise EvidenceError(
            f"{geometry_context} fields are invalid: " + "; ".join(details)
        )
    if (
        type(geometry["schemaVersion"]) is not int
        or geometry["schemaVersion"] != GEOMETRY_ARTIFACT_SCHEMA_VERSION
    ):
        raise EvidenceError("geometry manifest schema is invalid")
    feature_database_digest = geometry["featureDatabaseDigest"]
    if (
        not isinstance(feature_database_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", feature_database_digest) is None
    ):
        raise EvidenceError("geometry manifest feature database digest is invalid")
    input_digest = geometry["inputDigest"]
    if (
        not isinstance(input_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", input_digest) is None
        or f"sha256:{input_digest}" != geometry_input_digest
    ):
        raise EvidenceError("geometry manifest input digest does not match its receipt")
    manifest_selected_digest = geometry["selectedFramesDigest"]
    if (
        not isinstance(manifest_selected_digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", manifest_selected_digest) is None
        or f"sha256:{manifest_selected_digest}" != selected_frames_digest
    ):
        raise EvidenceError("geometry manifest selected-frame digest is invalid")
    total_view_count = geometry["totalViewCount"]
    image_names = geometry["orderedImageNames"]
    image_timestamps = geometry["orderedImageTimestamps"]
    if (
        type(total_view_count) is not int
        or total_view_count != candidate_configuration["selected_frame_count"]
        or not isinstance(image_names, list)
        or len(image_names) != total_view_count
        or any(
            not isinstance(name, str)
            or not name
            or len(name.encode("utf-8")) > 255
            or "/" in name
            or "\\" in name
            or name in {".", ".."}
            for name in image_names
        )
        or len(set(image_names)) != total_view_count
        or tuple(image_names) != selection_sources.image_names
        or not isinstance(image_timestamps, list)
        or len(image_timestamps) != total_view_count
        or any(
            timestamp is not None
            and (
                isinstance(timestamp, bool)
                or not isinstance(timestamp, (int, float))
                or not math.isfinite(timestamp)
                or timestamp < 0
            )
            for timestamp in image_timestamps
        )
    ):
        raise EvidenceError("geometry manifest selected-frame identity is invalid")
    registered_view_count = geometry["registeredViewCount"]
    observation_count = geometry["observationCount"]
    point_count = geometry["pointCount"]
    median_residual = geometry["medianPixelResidual"]
    p90_residual = geometry["p90PixelResidual"]
    version_fields = ("solverVersion", "runtimeVersion", "modelVersion")
    timings = _mapping(geometry["timings"], f"{geometry_context}.timings")
    if (
        any(
            not isinstance(geometry[field], str)
            or not geometry[field].strip()
            or len(geometry[field].encode("utf-8")) > 1_024
            for field in version_fields
        )
        or geometry["sourceModelPath"] != "SfM/colmap/sparse/0"
        or geometry["poseConvention"] != "world-to-camera"
        or geometry["quaternionOrder"] != "wxyz"
        or geometry["handedness"] != "right-handed"
        or geometry["scaleType"] != "arbitrary-sim3"
        or not isinstance(geometry["cameraModel"], str)
        or not geometry["cameraModel"].strip()
        or geometry["cameraGrouping"]
        not in {"automatic", "sameCameraAndLens", "mixedCamerasOrLenses"}
        or type(registered_view_count) is not int
        or not 0 < registered_view_count <= total_view_count
        or type(observation_count) is not int
        or observation_count <= 0
        or type(point_count) is not int
        or point_count <= 0
        or geometry["residualProvenance"] != "colmap-text-tracks-v1"
        or not _finite_number(median_residual)
        or not _finite_number(p90_residual)
        or not 0 <= float(median_residual) <= float(p90_residual)
        or type(geometry["peakMemoryBytes"]) is not int
        or geometry["peakMemoryBytes"] <= 0
        or not timings
        or "orientation_estimation_seconds" not in timings
        or any(
            not isinstance(name, str)
            or not name.strip()
            or not _finite_number(duration)
            or float(duration) < 0
            for name, duration in timings.items()
        )
    ):
        raise EvidenceError("geometry manifest production fields are invalid")
    if canonical_json_bytes(geometry["workerExecution"]) != canonical_json_bytes(
        artifact
    ):
        raise EvidenceError(
            "geometry manifest embedded worker execution does not match the standalone artifact"
        )

    canonical_model_hashes = _mapping(
        geometry["modelHashes"],
        f"{geometry_context}.modelHashes",
    )
    _exact_keys(
        canonical_model_hashes,
        {"cameras.txt", "images.txt", "points3D.txt"},
        f"{geometry_context}.modelHashes",
    )
    if any(
        not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        for digest in canonical_model_hashes.values()
    ):
        raise EvidenceError("geometry manifest model hashes are invalid")
    if canonical_cameras_digest != "sha256:" + canonical_model_hashes["cameras.txt"]:
        raise EvidenceError(
            "canonical cameras digest does not match the geometry model hash"
        )
    cameras_descriptor = _mapping(
        descriptors.get(canonical_cameras_name),
        f"artifacts.{canonical_cameras_name}",
    )
    _exact_keys(
        cameras_descriptor,
        {"path", "sha256", "bytes"},
        f"artifacts.{canonical_cameras_name}",
    )
    expected_cameras_path = (
        f"worker-runs/{run_id}/project.easysplatproj/"
        "SfM/colmap/sparse/0/cameras.txt"
    )
    if cameras_descriptor["path"] != expected_cameras_path:
        raise EvidenceError("canonical cameras path does not match its execution run")
    if cameras_descriptor["sha256"] != canonical_cameras_digest:
        raise EvidenceError("canonical cameras digest does not match its receipt")
    if (
        type(cameras_descriptor["bytes"]) is not int
        or not 0 < cameras_descriptor["bytes"] <= MAX_CANONICAL_CAMERAS_BYTES
    ):
        raise EvidenceError("canonical cameras artifact exceeds its size limit")
    cameras = _parse_colmap_cameras_text(
        _load_runtime_artifact_bytes(
            artifact_root,
            PurePosixPath(expected_cameras_path),
            canonical_cameras_digest,
            f"canonical cameras {run_id}",
            MAX_CANONICAL_CAMERAS_BYTES,
        ),
        f"canonical cameras {run_id}",
    )
    _validate_geometry_camera_contract(
        geometry,
        cameras,
        candidate_configuration,
        request,
        selection_sources,
        geometry_context,
    )
    _validate_geometry_conditioning_artifact(
        geometry["conditioning"],
        registered_view_count=registered_view_count,
        point_count=point_count,
        observation_count=observation_count,
        model_hashes=canonical_model_hashes,
    )
    _validate_canonical_orientation_artifact(
        geometry["canonicalOrientation"],
        registered_view_count=registered_view_count,
    )
    artifact_fields = {
        "schemaVersion",
        "colmapRuntimeClosure",
        "resolvedBudget",
        "featureExtractionInvocations",
        "matchingInvocations",
        "vocabularyRetrievalInvocations",
        "rejectedVocabularyRetrievalInvocations",
        "mappingAndRefinementInvocations",
        "videoSourceAnalysis",
    }
    _exact_keys(artifact, artifact_fields, f"runtime worker artifact {run_id}")
    if (
        type(artifact["schemaVersion"]) is not int
        or artifact["schemaVersion"] != GEOMETRY_WORKER_EXECUTION_SCHEMA_VERSION
    ):
        raise EvidenceError("runtime worker artifact schema is invalid")

    runtime_closure = _mapping(
        artifact["colmapRuntimeClosure"],
        f"runtime worker artifact {run_id}.colmapRuntimeClosure",
    )
    _exact_keys(
        runtime_closure,
        {"components", "closureSHA256"},
        f"runtime worker artifact {run_id}.colmapRuntimeClosure",
    )
    raw_components = runtime_closure["components"]
    if not isinstance(raw_components, list) or len(raw_components) != len(
        COLMAP_RUNTIME_COMPONENT_PATHS
    ):
        raise EvidenceError("runtime worker COLMAP closure is invalid")
    components: list[tuple[str, str]] = []
    for index, raw_component in enumerate(raw_components):
        component = _mapping(
            raw_component,
            f"runtime worker artifact {run_id}.colmapRuntimeClosure.components[{index}]",
        )
        _exact_keys(
            component,
            {"toolchainRelativePath", "sha256"},
            f"runtime worker artifact {run_id}.colmapRuntimeClosure.components[{index}]",
        )
        path = component["toolchainRelativePath"]
        digest = component["sha256"]
        if (
            path != COLMAP_RUNTIME_COMPONENT_PATHS[index]
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise EvidenceError("runtime worker COLMAP closure component is invalid")
        components.append((path, digest))
    closure_digest = runtime_closure["closureSHA256"]
    if not isinstance(
        closure_digest, str
    ) or closure_digest != colmap_runtime_closure_digest(components):
        raise EvidenceError("runtime worker COLMAP closure digest is invalid")
    provenance = _mapping(geometry["provenance"], f"{geometry_context}.provenance")
    _exact_keys(
        provenance,
        {"toolchainVersion", "solver", "runtime", "model"},
        f"{geometry_context}.provenance",
    )
    provenance_component_fields = {
        "identifier",
        "version",
        "revision",
        "payloadSHA256",
    }

    def validated_provenance_component(value: Any, component: str) -> Mapping[str, Any]:
        component_context = f"{geometry_context}.provenance.{component}"
        result = _mapping(value, component_context)
        _exact_keys(result, provenance_component_fields, component_context)
        if (
            any(
                not isinstance(result[field], str)
                or not result[field].strip()
                or len(result[field].encode("utf-8")) > 1_024
                for field in ("identifier", "version", "revision")
            )
            or not isinstance(result["payloadSHA256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", result["payloadSHA256"]) is None
        ):
            raise EvidenceError("geometry manifest provenance is invalid")
        return result

    toolchain_version = provenance["toolchainVersion"]
    if (
        not isinstance(toolchain_version, str)
        or not toolchain_version.strip()
        or len(toolchain_version.encode("utf-8")) > 1_024
    ):
        raise EvidenceError("geometry manifest provenance is invalid")
    solver = validated_provenance_component(provenance["solver"], "solver")
    if solver["identifier"] != "colmap" or solver["payloadSHA256"] != closure_digest:
        raise EvidenceError(
            "geometry solver provenance does not bind the COLMAP closure"
        )
    expected_solver_suffix = (
        f"COLMAP {solver['version']} (git {solver['revision'][:7]})"
    )
    if not geometry["solverVersion"].endswith(expected_solver_suffix):
        raise EvidenceError("geometry manifest provenance is invalid")
    raw_runtime = provenance["runtime"]
    raw_model = provenance["model"]
    if (raw_runtime is None) != (raw_model is None):
        raise EvidenceError("geometry manifest provenance is invalid")
    if raw_runtime is None:
        if (
            geometry["modelVersion"] != "none"
            or geometry["runtimeVersion"] != f"toolchain {toolchain_version}"
        ):
            raise EvidenceError("geometry manifest provenance is invalid")
        model = None
    else:
        runtime = validated_provenance_component(raw_runtime, "runtime")
        model = validated_provenance_component(raw_model, "model")
        if (
            runtime["identifier"] != "da3_mps"
            or model["identifier"] not in {"DA3-BASE", "DA3-SMALL"}
            or geometry["runtimeVersion"]
            != (
                f"toolchain {toolchain_version}; {runtime['identifier']} "
                f"{runtime['version']} (git {runtime['revision'][:7]})"
            )
            or geometry["modelVersion"]
            != f"{model['identifier']}@{model['revision']}"
        ):
            raise EvidenceError("geometry manifest provenance is invalid")

    fallback_reason = geometry.get("fallbackReason")
    if fallback_reason is not None and (
        not isinstance(fallback_reason, str)
        or not fallback_reason.strip()
        or fallback_reason != fallback_reason.strip()
        or len(fallback_reason.encode("utf-8")) > 4_096
        or any(
            ord(character) < 32 or 127 <= ord(character) <= 159
            for character in fallback_reason
        )
    ):
        raise EvidenceError("geometry manifest fallback reason is invalid")

    learned_initializer = geometry.get("learnedPointInitializer")
    if model is None:
        if learned_initializer is not None:
            raise EvidenceError("geometry manifest learned point initializer is invalid")
    else:
        initializer_context = f"{geometry_context}.learnedPointInitializer"
        initializer = _mapping(learned_initializer, initializer_context)
        _exact_keys(
            initializer,
            {"path", "sha256", "pointCount"},
            initializer_context,
        )
        if (
            initializer["path"]
            != "SfM/colmap/seed/0/learned_points3D.txt"
            or not isinstance(initializer["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", initializer["sha256"]) is None
            or type(initializer["pointCount"]) is not int
            or not 0 < initializer["pointCount"] <= (1 << 63) - 1
        ):
            raise EvidenceError("geometry manifest learned point initializer is invalid")

    budget_fields = {
        "featureExtractionWorkers": "feature_extraction_workers",
        "coupledMatchingWorkers": "coupled_matching_workers",
        "vocabularyRetrievalWorkers": "vocabulary_retrieval_workers",
        "maximumConcurrentVideoSourceAnalysisTasks": (
            "maximum_concurrent_video_source_analysis_tasks"
        ),
    }
    resolved_budget = _mapping(
        artifact["resolvedBudget"],
        f"runtime worker artifact {run_id}.resolvedBudget",
    )
    _exact_keys(
        resolved_budget,
        set(budget_fields),
        f"runtime worker artifact {run_id}.resolvedBudget",
    )
    expected_budget = {
        artifact_field: candidate_configuration[configuration_field]
        for artifact_field, configuration_field in budget_fields.items()
    }
    if (
        any(
            type(resolved_budget[field]) is not int
            or not 1 <= resolved_budget[field] <= 64
            for field in budget_fields
        )
        or dict(resolved_budget) != expected_budget
    ):
        raise EvidenceError("runtime worker budget does not match the bound request")

    artifact_context = f"runtime worker artifact {run_id}"
    _validate_worker_invocations(
        artifact["featureExtractionInvocations"],
        context=f"{artifact_context}.featureExtractionInvocations",
        allowed_commands=frozenset({"featureExtractor", "featureImporter"}),
        expected_policy="bounded",
        expected_worker_count=expected_budget["featureExtractionWorkers"],
        expects_mapping_attempt_ordinal=False,
        required=False,
    )
    _validate_worker_invocations(
        artifact["matchingInvocations"],
        context=f"{artifact_context}.matchingInvocations",
        allowed_commands=frozenset({"matchesImporter"}),
        expected_policy="bounded",
        expected_worker_count=expected_budget["coupledMatchingWorkers"],
        expects_mapping_attempt_ordinal=False,
        required=False,
    )
    _validate_worker_invocations(
        artifact["vocabularyRetrievalInvocations"],
        context=f"{artifact_context}.vocabularyRetrievalInvocations",
        allowed_commands=frozenset({"localVocabularyRetriever"}),
        expected_policy="bounded",
        expected_worker_count=expected_budget["vocabularyRetrievalWorkers"],
        expects_mapping_attempt_ordinal=False,
        required=False,
    )
    rejected_recovery_levels = _validate_rejected_vocabulary_retrieval_history(
        artifact["rejectedVocabularyRetrievalInvocations"],
        accepted_invocations=artifact["vocabularyRetrievalInvocations"],
        expected_worker_count=expected_budget["vocabularyRetrievalWorkers"],
        candidate_configuration=candidate_configuration,
        request=request,
        image_names=image_names,
    )
    _validate_worker_invocations(
        artifact["mappingAndRefinementInvocations"],
        context=f"{artifact_context}.mappingAndRefinementInvocations",
        allowed_commands=frozenset(
            {
                "mapper",
                "pointTriangulator",
                "bundleAdjuster",
                "modelAnalyzer",
                "modelConverter",
            }
        ),
        expected_policy="nativeAuto",
        expected_worker_count=None,
        expects_mapping_attempt_ordinal=True,
        required=True,
    )
    colmap_executable_sha256 = components[0][1]
    for invocation in artifact["mappingAndRefinementInvocations"]:
        conversion = invocation["modelConversion"]
        if (
            conversion is not None
            and conversion["executableSHA256"] != colmap_executable_sha256
        ):
            raise EvidenceError(
                "model converter executable does not bind the COLMAP closure leaf"
            )
    for invocations in (
        artifact["featureExtractionInvocations"],
        artifact["matchingInvocations"],
        artifact["mappingAndRefinementInvocations"],
    ):
        if invocations and not any(item["succeeded"] for item in invocations):
            raise EvidenceError("required worker stage has no successful invocation")

    (
        pair_graph_status,
        retrieval_was_scheduled,
        retrieval_used,
    ) = _validate_pair_graph_artifact(
        geometry["pairGraph"],
        total_view_count=total_view_count,
        candidate_configuration=candidate_configuration,
        requires_cross_clip_retrieval=_requires_cross_clip_retrieval(
            request,
            candidate_configuration,
        ),
    )
    pair_graph_measurement: Mapping[str, Any] | None = None
    if pair_graph_status == "measured":
        pair_graph = _mapping(
            geometry["pairGraph"], f"{geometry_context}.pairGraph"
        )
        pair_graph_measurement = _mapping(
            pair_graph["measurement"], f"{geometry_context}.pairGraph.measurement"
        )
        _validate_recovery_density_closure(
            pair_graph_measurement["matcherAttempts"], rejected_recovery_levels
        )
    if pair_graph_status == "measured" and (
        not any(item["succeeded"] for item in artifact["featureExtractionInvocations"])
        or not any(item["succeeded"] for item in artifact["matchingInvocations"])
    ):
        raise EvidenceError(
            "measured COLMAP geometry requires successful feature and matching execution"
        )
    vocabulary_retrieval_invocations = artifact["vocabularyRetrievalInvocations"]
    retrieval_configured = (
        candidate_configuration["vocabulary_candidate_count"] > 0
        and candidate_configuration["vocabulary_returned_neighbor_count"] > 0
    )
    if pair_graph_status == "measured":
        if retrieval_was_scheduled and not retrieval_configured:
            raise EvidenceError(
                "runtime vocabulary retrieval does not match the resolved retrieval policy"
            )
        if not retrieval_was_scheduled and vocabulary_retrieval_invocations:
            raise EvidenceError("runtime vocabulary retrieval was unscheduled")
        assert pair_graph_measurement is not None
        accepted_attempt_number = pair_graph_measurement["matcherAttempts"][-1][
            "attemptNumber"
        ]
        accepted_matcher_invocations = [
            invocation
            for invocation in artifact["matchingInvocations"]
            if invocation["succeeded"]
            and invocation["pairExecution"]["attemptOrdinal"]
            == accepted_attempt_number
        ]
        if len(accepted_matcher_invocations) != 1:
            raise EvidenceError(
                "accepted pair graph lacks one successful matcher invocation"
            )
        accepted_binding = accepted_matcher_invocations[0]["pairExecution"]
        accepted_request_digest = accepted_binding.get("retrievalRequestDigest")
        accepted_output_digest = accepted_binding.get("retrievalOutputDigest")
        if (accepted_request_digest is None) != (accepted_output_digest is None):
            raise EvidenceError(
                "accepted matcher has an incomplete vocabulary retrieval binding"
            )
        accepted_uses_retrieval_receipt = accepted_request_digest is not None
        if retrieval_used != accepted_uses_retrieval_receipt:
            raise EvidenceError(
                "runtime vocabulary retrieval disagrees with the accepted pair graph"
            )
        if accepted_uses_retrieval_receipt and not any(
            invocation["succeeded"]
            and invocation["pairExecution"].get("retrievalRequestDigest")
            == accepted_request_digest
            and invocation["pairExecution"].get("retrievalOutputDigest")
            == accepted_output_digest
            for invocation in vocabulary_retrieval_invocations
        ):
            raise EvidenceError(
                "runtime vocabulary retrieval does not bind its matcher attempt"
            )
        if retrieval_was_scheduled and not retrieval_used:
            accepted_attempt = pair_graph_measurement["matcherAttempts"][-1]
            if not (
                accepted_attempt["recoveryLevel"] == "maximum"
                and total_view_count <= 250
            ):
                raise EvidenceError(
                    "scheduled runtime vocabulary retrieval was omitted outside exhaustive recovery"
                )
    elif retrieval_was_scheduled or retrieval_used or vocabulary_retrieval_invocations:
        raise EvidenceError(
            "unmeasured seeded geometry cannot claim vocabulary retrieval execution"
        )
    pair_measurement: Mapping[str, Any] | None = None
    accepted_matcher: str | None = None
    pair_list_digest: str | None = None
    if pair_graph_status == "measured":
        assert pair_graph_measurement is not None
        pair_measurement = pair_graph_measurement
        if feature_database_digest != pair_measurement["featureDatabaseDigest"]:
            raise EvidenceError(
                "geometry manifest feature database digest is invalid"
            )
        expected_pairing_policy = {
            "generic_continuous": "orderedContinuous",
            "object_orbit": "orderedOrbit",
            "walkthrough": "orderedWalkthrough",
            "large_area": "orderedLargeArea",
            "segmented_mixed": "segmentedMixed",
            "unordered_exhaustive": "unorderedRetrieval",
            "unordered_retrieval": "unorderedRetrieval",
        }[candidate_configuration["pairing_policy"]]
        if pair_measurement["pairingPolicy"] != expected_pairing_policy:
            raise EvidenceError(
                "geometry manifest pairing policy contradicts the protected request"
            )
        metric_fields = {
            "scheduledPairCount": "scheduled_pairs",
            "attemptedPairCount": "attempted_pairs",
            "rawMatchedPairCount": "raw_matched_pairs",
            "spatiallyVerifiedPairCount": "spatially_verified_pairs",
            "localPairCount": "local_pairs",
            "retrievalPairCount": "retrieval_pairs",
            "loopRevisitPairCount": "loop_pairs",
            "connectedComponentCount": "connected_components",
            "isolatedViewCount": "isolated_views",
            "articulationViewCount": "articulation_views",
            "biconnectedBlockCount": "biconnected_blocks",
            "largestBiconnectedBlockViewCount": "largest_biconnected_block_views",
            "secondLargestBiconnectedBlockViewCount": (
                "second_largest_biconnected_block_views"
            ),
        }
        if pipeline_metrics is not None:
            for manifest_field, metric_field in metric_fields.items():
                if pair_measurement[manifest_field] != pipeline_metrics.get(
                    metric_field
                ):
                    raise EvidenceError(
                        f"geometry pair graph {manifest_field} does not match pipeline evidence"
                    )
            if not math.isclose(
                float(pair_measurement["matchingDurationSeconds"]),
                float(pipeline_metrics.get("matcher_seconds", math.nan)),
                rel_tol=0,
                abs_tol=1e-6,
            ):
                raise EvidenceError(
                    "geometry pair graph matching duration does not match pipeline evidence"
                )
        accepted_attempt = pair_measurement["matcherAttempts"][-1]
        accepted_matcher = accepted_attempt["matcher"]
        pair_list_digest = "sha256:" + pair_measurement["pairListDigest"]
        _validate_pair_execution_bindings(
            artifact,
            matcher_attempts=pair_measurement["matcherAttempts"],
            accepted_pair_list_digest=pair_measurement["pairListDigest"],
        )
    else:
        _validate_unmeasured_matching_history(artifact["matchingInvocations"])

    mapping_context = "geometry manifest mapping"
    mapping = _mapping(geometry["mapping"], mapping_context)
    _exact_keys(
        mapping,
        {
            "modelCount",
            "largestModelRegisteredViewCount",
            "secondLargestModelRegisteredViewCount",
            "unionRegisteredViewCount",
            "attemptCount",
            "acceptedMappingAttemptOrdinal",
            "acceptedRefinementKind",
            "acceptedRefinementInvocationCount",
            "plannedIncrementalCadence",
            "incrementalCadence",
            "cadenceFallbackTrigger",
            "canonicalModelPublication",
            "fallbackReason",
        },
        mapping_context,
    )
    mapping_count_fields = (
        "modelCount",
        "largestModelRegisteredViewCount",
        "secondLargestModelRegisteredViewCount",
        "unionRegisteredViewCount",
        "attemptCount",
        "acceptedMappingAttemptOrdinal",
        "acceptedRefinementInvocationCount",
    )
    if any(type(mapping[field]) is not int for field in mapping_count_fields):
        raise EvidenceError("geometry manifest mapping is invalid")
    model_count = mapping["modelCount"]
    largest_model = mapping["largestModelRegisteredViewCount"]
    second_model = mapping["secondLargestModelRegisteredViewCount"]
    union_views = mapping["unionRegisteredViewCount"]
    accepted_mapping_attempt_ordinal = mapping["acceptedMappingAttemptOrdinal"]
    refinement_count = mapping["acceptedRefinementInvocationCount"]
    fallback_reason = mapping["fallbackReason"]
    cadence_fallback_trigger = mapping["cadenceFallbackTrigger"]
    if cadence_fallback_trigger is not None and (
        cadence_fallback_trigger not in MAPPING_CADENCE_FALLBACK_TRIGGERS
    ):
        raise EvidenceError("geometry mapper cadence fallback trigger is invalid")
    if refinement_count < 0:
        raise EvidenceError("geometry has an invalid accepted refinement count")
    if (
        not 1 <= model_count <= union_views <= total_view_count
        or largest_model < 1
        or largest_model > union_views
        or second_model < 0
        or second_model > largest_model
        or mapping["attemptCount"] < 1
        or not 1 <= accepted_mapping_attempt_ordinal <= MAXIMUM_MAPPING_ATTEMPT_ORDINAL
        or (
            fallback_reason is not None
            and (
                not isinstance(fallback_reason, str)
                or not fallback_reason
                or fallback_reason != fallback_reason.strip()
                or len(fallback_reason.encode("utf-8")) > 1_024
                or any(ord(character) < 32 for character in fallback_reason)
            )
        )
        or (mapping["attemptCount"] > 1 and fallback_reason is None)
    ):
        raise EvidenceError("geometry manifest mapping is invalid")
    refinement_kind = mapping["acceptedRefinementKind"]
    mapping_invocations = artifact["mappingAndRefinementInvocations"]
    maximum_mapping_attempt_ordinal = max(
        item["mappingAttemptOrdinal"] for item in mapping_invocations
    )
    if accepted_mapping_attempt_ordinal != maximum_mapping_attempt_ordinal:
        raise EvidenceError(
            "geometry accepted mapping-attempt ordinal is not the final recorded attempt"
        )
    accepted_invocations = [
        item
        for item in mapping_invocations
        if item["mappingAttemptOrdinal"] == accepted_mapping_attempt_ordinal
    ]
    accepted_commands = {item["command"] for item in accepted_invocations}
    successful_mapper_attempt_ordinals = [
        item["mappingAttemptOrdinal"]
        for item in mapping_invocations
        if item["command"] == "mapper" and item["succeeded"]
    ]
    if len(successful_mapper_attempt_ordinals) != len(
        set(successful_mapper_attempt_ordinals)
    ):
        raise EvidenceError(
            "worker evidence contains multiple successful mappers for one mapping attempt"
        )

    def successful_accepted_count(command: str) -> int:
        return sum(
            item["command"] == command and item["succeeded"]
            for item in accepted_invocations
        )

    publication = _mapping(
        mapping["canonicalModelPublication"],
        "geometry manifest canonical model publication",
    )
    _exact_keys(
        publication,
        {"kind", "sourceModelHashes", "conversion"},
        "geometry manifest canonical model publication",
    )
    source_hashes = _mapping(
        publication["sourceModelHashes"],
        "geometry manifest canonical source hashes",
    )
    if any(
        not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        for digest in source_hashes.values()
    ):
        raise EvidenceError("geometry canonical model publication is invalid")
    publication_kind = publication["kind"]
    raw_conversion = publication["conversion"]
    converter_invocations = [
        item for item in accepted_invocations if item["command"] == "modelConverter"
    ]
    if publication_kind == "convertedFromBinary":
        conversion = _mapping(
            raw_conversion,
            "geometry manifest canonical model conversion",
        )
        _exact_keys(
            conversion,
            {"invocationOrdinal", "workerEvidence"},
            "geometry manifest canonical model conversion",
        )
        converter_ordinal = conversion["invocationOrdinal"]
        if (
            set(source_hashes) != {"cameras.bin", "images.bin", "points3D.bin"}
            or type(converter_ordinal) is not int
            or converter_ordinal < 1
            or converter_ordinal > len(converter_invocations)
            or not converter_invocations[converter_ordinal - 1]["succeeded"]
            or conversion["workerEvidence"]
            != converter_invocations[converter_ordinal - 1]["modelConversion"]
        ):
            raise EvidenceError(
                "binary canonical publication lacks its successful model converter"
            )
    elif publication_kind in {"directText", "resumedCanonicalText"}:
        if (
            dict(source_hashes) != dict(canonical_model_hashes)
            or raw_conversion is not None
        ):
            raise EvidenceError("direct canonical text publication source is invalid")
    else:
        raise EvidenceError("geometry canonical model publication kind is invalid")

    if refinement_kind == "incrementalGlobal":
        if pair_graph_status != "measured":
            raise EvidenceError("incremental geometry has an invalid pair graph")
        cadence = _mapping(
            mapping["incrementalCadence"],
            "geometry manifest mapping incremental cadence",
        )
        cadence = _mapper_cadence(
            cadence,
            "geometry manifest mapping incremental cadence",
        )
        _mapper_cadence(
            mapping["plannedIncrementalCadence"],
            "geometry manifest mapping planned incremental cadence",
        )
        accepted_mapper_invocations = [
            item for item in accepted_invocations if item["command"] == "mapper"
        ]
        if (
            not accepted_commands.issubset(
                {"mapper", "modelAnalyzer", "modelConverter"}
            )
            or len(accepted_mapper_invocations) != 1
            or not accepted_mapper_invocations[0]["succeeded"]
            or successful_accepted_count("modelAnalyzer") < 1
        ):
            raise EvidenceError(
                "incremental geometry accepted attempt has invalid mapper or analysis evidence"
            )
    elif refinement_kind == "seededBundleAdjustment":
        if (
            pair_graph_status != "notEvaluated"
            or refinement_count != 1
            or model_count != 1
            or mapping["plannedIncrementalCadence"] is not None
            or mapping["incrementalCadence"] is not None
            or cadence_fallback_trigger is not None
        ):
            raise EvidenceError(
                "seeded geometry has an invalid pair graph or accepted refinement count"
            )
        accepted_triangulator_invocations = [
            item
            for item in accepted_invocations
            if item["command"] == "pointTriangulator"
        ]
        accepted_adjuster_invocations = [
            item for item in accepted_invocations if item["command"] == "bundleAdjuster"
        ]
        if (
            not accepted_commands.issubset(
                {
                    "pointTriangulator",
                    "bundleAdjuster",
                    "modelAnalyzer",
                    "modelConverter",
                }
            )
            or len(accepted_triangulator_invocations) != 1
            or not accepted_triangulator_invocations[0]["succeeded"]
            or len(accepted_adjuster_invocations) != 1
            or not accepted_adjuster_invocations[0]["succeeded"]
            or successful_accepted_count("modelAnalyzer") < 1
            or not any(
                item["succeeded"] for item in artifact["featureExtractionInvocations"]
            )
            or not any(item["succeeded"] for item in artifact["matchingInvocations"])
        ):
            raise EvidenceError(
                "seeded geometry accepted attempt has invalid triangulation, refinement, or analysis evidence"
            )
    else:
        raise EvidenceError("geometry manifest accepted refinement kind is invalid")

    successful_mapper_records = [
        item
        for item in mapping_invocations
        if item["command"] == "mapper" and item["succeeded"]
    ]
    normalized_mapper_records: list[dict[str, Any]] = []
    for index, invocation in enumerate(successful_mapper_records):
        execution = _mapping(
            invocation["mapperExecution"],
            f"successful mapper invocation {index}.mapperExecution",
        )
        evaluation = _mapping(
            execution["evaluation"],
            f"successful mapper invocation {index}.evaluation",
        )
        normalized_mapper_records.append(
            {
                "mapping_attempt_ordinal": invocation["mappingAttemptOrdinal"],
                "incremental_cadence": dict(execution["incrementalCadence"]),
                "global_max_num_iterations": execution["globalMaxNumIterations"],
                "random_seed": execution["randomSeed"],
                "refine_focal_length": execution["refineFocalLength"],
                "minimum_pair_inlier_count": execution["minimumPairInlierCount"],
                "pair_graph_attempt_ordinal": execution["pairGraphAttemptOrdinal"],
                "pair_list_digest": "sha256:" + execution["pairListDigest"],
                "descriptor_matcher": execution["descriptorMatcher"],
                "matching_database_digest": (
                    "sha256:" + execution["matchingDatabaseDigest"]
                ),
                "evaluation": {
                    "status": evaluation["status"],
                    "fallback_trigger": evaluation["fallbackTrigger"],
                },
            }
        )

    video = _mapping(
        artifact["videoSourceAnalysis"],
        f"{artifact_context}.videoSourceAnalysis",
    )
    _exact_keys(
        video,
        {
            "videoSourceCount",
            "startedAnalysisTaskCount",
            "peakInFlightAnalysisTaskCount",
        },
        f"{artifact_context}.videoSourceAnalysis",
    )
    if any(
        type(video[field]) is not int
        or not 0 <= video[field] <= 9_223_372_036_854_775_807
        for field in (
            "videoSourceCount",
            "startedAnalysisTaskCount",
            "peakInFlightAnalysisTaskCount",
        )
    ):
        raise EvidenceError("runtime video-analysis worker evidence is invalid")
    source_count = video["videoSourceCount"]
    task_count = video["startedAnalysisTaskCount"]
    observed_concurrency = video["peakInFlightAnalysisTaskCount"]
    expected_source_count = selection_sources.video_source_count
    if request["video_source_count"] != expected_source_count:
        raise EvidenceError(
            "protected request video source count does not match the selection manifest"
        )
    if source_count != expected_source_count:
        raise EvidenceError(
            "runtime video source count does not match the authenticated selection manifest"
        )
    if expected_source_count == 0:
        if (source_count, task_count, observed_concurrency) != (0, 0, 0):
            raise EvidenceError("photo input cannot claim video-analysis execution")
    elif (
        source_count < 1
        or not source_count <= task_count <= source_count * 2
        or not 1
        <= observed_concurrency
        <= min(
            source_count,
            expected_budget["maximumConcurrentVideoSourceAnalysisTasks"],
        )
    ):
        raise EvidenceError("runtime video-analysis worker evidence is invalid")
    return {
        "refinement_kind": refinement_kind,
        "accepted_mapping_attempt_ordinal": accepted_mapping_attempt_ordinal,
        "planned_incremental_cadence": mapping["plannedIncrementalCadence"],
        "incremental_cadence": mapping["incrementalCadence"],
        "cadence_fallback_trigger": cadence_fallback_trigger,
        "pair_list_digest": pair_list_digest,
        "accepted_matcher": accepted_matcher,
        "accepted_pair_graph_attempt_ordinal": (
            pair_measurement["matcherAttempts"][-1]["attemptNumber"]
            if pair_measurement is not None
            else None
        ),
        "matching_database_digest": (
            "sha256:" + pair_measurement["matchingDatabaseDigest"]
            if pair_measurement is not None
            else None
        ),
        "mapper_invocations": normalized_mapper_records,
        "successful_mapper_attempt_ordinals": successful_mapper_attempt_ordinals,
    }


def _validate_execution_receipts(
    commands: Any,
    command_log_path: Path,
    artifact_root: Path,
    descriptors: Mapping[str, Any],
    request: Mapping[str, Any],
    runner_identity: Mapping[str, Any],
    timing: Mapping[str, Any] | None,
    actual: Mapping[str, Any],
    published_output_sha256: str | None,
    pipeline_metrics: Mapping[str, Any] | None,
    expected_pair_list_digest: str | None,
    selection_sources: SelectionManifestSources | None,
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
        "planned_mapper_cadence",
        "accepted_mapper_cadence",
        "cadence_fallback_trigger",
        "runtime_worker_evidence",
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
    used_worker_artifacts: set[str] = set()
    for index, (raw, expected) in enumerate(zip(commands, expected_runs, strict=True)):
        receipt = _mapping(raw, f"commands[{index}]")
        _exact_keys(receipt, receipt_fields, f"commands[{index}]")
        if type(receipt["published_output"]) is not bool:
            raise EvidenceError("execution receipt published_output must be boolean")
        for field in ("run_id", "phase", "variant"):
            if receipt[field] != expected[field]:
                raise EvidenceError(
                    f"commands[{index}].{field} does not match its timing record"
                )
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
            raise EvidenceError(
                "execution receipt process CPU fields are invalid"
            ) from error
        if any(
            type(process_cpu[field]) is not int or not 0 <= process_cpu[field] < 1 << 64
            for field in ("user", "system")
        ):
            raise EvidenceError("execution receipt process CPU time is outside UInt64")
        if expected["duration"] is not None and not math.isclose(
            float(ended) - float(started),
            expected["duration"],
            rel_tol=0,
            abs_tol=1e-6,
        ):
            raise EvidenceError(
                "execution receipt duration does not match its timing record"
            )
        expected_exit = 0 if valid_outcome else actual["exit_code"]
        if (
            type(receipt["exit_code"]) is not int
            or receipt["exit_code"] != expected_exit
        ):
            raise EvidenceError(
                "execution receipt exit code does not match the run outcome"
            )
        checkout, toolchain, configuration_digest, prefixes = (
            _expected_variant_identity(
                receipt["variant"],
                request,
            )
        )
        if receipt["checkout_commit"] != checkout:
            raise EvidenceError("execution receipt checkout commit is invalid")
        if receipt["toolchain_identity"] != toolchain:
            raise EvidenceError("execution receipt toolchain identity is invalid")
        if receipt["run_configuration_digest"] != configuration_digest:
            raise EvidenceError("execution receipt configuration digest is invalid")
        geometry_execution: dict[str, Any] | None = None
        if valid_outcome and receipt["variant"] in {"candidate", "fast_candidate"}:
            configuration = dict(request["candidate_run_configuration"])
            if receipt["variant"] == "fast_candidate":
                configuration.update(
                    {
                        "detail_profile": "fast",
                        "trainer_iterations": 3000,
                        "trainer_plateau_window": 400,
                    }
                )
            if receipt["published_output"] and pipeline_metrics is None:
                raise EvidenceError(
                    "candidate worker evidence requires pipeline metrics"
                )
            geometry_execution = _validate_runtime_worker_evidence(
                receipt["runtime_worker_evidence"],
                configuration,
                request,
                receipt["variant"],
                receipt["run_id"],
                artifact_root,
                descriptors,
                used_worker_artifacts,
                f"commands[{index}].runtime_worker_evidence",
                pipeline_metrics if receipt["published_output"] else None,
                selection_sources,
            )
            if (
                receipt["published_output"]
                and expected_pair_list_digest is not None
                and geometry_execution["pair_list_digest"] != expected_pair_list_digest
            ):
                raise EvidenceError(
                    "published geometry pair-list digest does not match protected pair evidence"
                )
        elif receipt["runtime_worker_evidence"] is not None:
            raise EvidenceError(
                "noncandidate or invalid-input receipt cannot claim runtime worker evidence"
            )
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
        if receipt["published_output"]:
            published_receipts += 1
            if (
                published_output_sha256 is None
                or receipt["output_sha256"] != published_output_sha256
            ):
                raise EvidenceError(
                    "published execution receipt does not match output_ply"
                )
        argv = receipt["argv"]
        if not isinstance(argv, list) or not argv:
            raise EvidenceError(
                "execution receipt argv must be a nonempty argument array"
            )
        for argument in argv:
            if (
                not isinstance(argument, str)
                or not argument
                or "/Users/" in argument
                or "/home/" in argument
            ):
                raise EvidenceError("execution receipt argv must use redacted paths")
        if any(
            not any(argument.startswith(prefix) for argument in argv)
            for prefix in prefixes
        ):
            raise EvidenceError(
                "execution receipt argv does not identify its variant closure"
            )
        _validate_mapper_invocations(
            receipt["mapper_invocations"],
            receipt["variant"],
            request,
            valid_outcome=valid_outcome,
            planned_mapper_cadence=receipt["planned_mapper_cadence"],
            accepted_mapper_cadence=receipt["accepted_mapper_cadence"],
            cadence_fallback_trigger=receipt["cadence_fallback_trigger"],
            geometry_execution=geometry_execution,
        )
    if valid_outcome and published_receipts != 1:
        raise EvidenceError(
            "valid evidence requires exactly one receipt for the published output"
        )
    if not valid_outcome and published_receipts:
        raise EvidenceError("invalid evidence cannot claim a published output receipt")
    return expected_runs


def _validate_prepared_execution_receipts(
    commands: Any,
    request: Mapping[str, Any],
    runner_identity: Mapping[str, Any],
    actual: Any,
    published_output_sha256: str | None,
    *,
    artifact_root: Path | None = None,
    descriptors: Mapping[str, Any] | None = None,
) -> None:
    """Revalidate compact receipts without trusting the original derivation pass."""
    if not isinstance(commands, list) or not commands:
        raise EvidenceError("prepared commands must be a nonempty receipt array")
    valid_outcome = request["expected_outcome"]["kind"] == "valid"
    actual = _validate_actual(actual, request["expected_outcome"])
    receipt_fields = {
        "run_id",
        "phase",
        "variant",
        "argv",
        "mapper_invocations",
        "planned_mapper_cadence",
        "accepted_mapper_cadence",
        "cadence_fallback_trigger",
        "runtime_worker_evidence",
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
    scopes = set(request["gate_scopes"])
    lane = request["binding"]["lane"]
    if not valid_outcome:
        allowed_phases = {"invalid_input": frozenset({"candidate"})}
    elif lane == LANE_REFERENCE and "suite_performance" in scopes:
        allowed_phases = {
            "ordinary": frozenset({"baseline", "candidate"}),
            "phase": frozenset({"baseline", "candidate"}),
            "fast_profile": frozenset({"accurate_reference", "fast_candidate"}),
        }
    elif lane == LANE_REFERENCE and "scene_quality" in scopes:
        allowed_phases = {
            "ordinary": frozenset({"baseline", "candidate"}),
            "fast_profile": frozenset({"accurate_reference", "fast_candidate"}),
        }
    else:
        allowed_phases = {"candidate": frozenset({"candidate"})}

    if artifact_root is not None:
        if descriptors is None:
            raise EvidenceError(
                "prepared runtime validation requires artifact descriptors"
            )
        command_descriptor = _mapping(
            descriptors.get("command_log"),
            "attestation.artifacts.command_log",
        )
        command_path = artifact_root / Path(
            *_render_relative_path(
                command_descriptor["path"],
                "attestation.artifacts.command_log.path",
            ).parts
        )
        if _read_command_log(command_path) != commands:
            raise EvidenceError(
                "command_log does not match the prepared execution receipts"
            )

    seen_run_ids: set[str] = set()
    used_worker_artifacts: set[str] = set()
    previous_end = -math.inf
    published_count = 0
    for index, raw in enumerate(commands):
        context = f"commands[{index}]"
        receipt = _mapping(raw, context)
        _exact_keys(receipt, receipt_fields, context)
        run_id = _token(receipt["run_id"], f"{context}.run_id")
        if run_id in seen_run_ids:
            raise EvidenceError("prepared execution receipt run IDs must be unique")
        seen_run_ids.add(run_id)
        phase = receipt["phase"]
        variant = receipt["variant"]
        if phase not in allowed_phases or variant not in allowed_phases[phase]:
            raise EvidenceError(
                "prepared execution receipt phase or variant is invalid"
            )
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
            raise EvidenceError(
                "prepared execution receipt timestamps are invalid or overlap"
            )
        previous_end = float(ended)
        process_cpu = _mapping(
            receipt["process_cpu_microseconds"],
            f"{context}.process_cpu_microseconds",
        )
        _exact_keys(
            process_cpu,
            {"user", "system"},
            f"{context}.process_cpu_microseconds",
        )
        if any(
            type(process_cpu[field]) is not int or not 0 <= process_cpu[field] < 1 << 64
            for field in ("user", "system")
        ):
            raise EvidenceError(
                "prepared execution receipt process CPU time is invalid"
            )
        expected_exit = 0 if valid_outcome else actual["exit_code"]
        if (
            type(receipt["exit_code"]) is not int
            or receipt["exit_code"] != expected_exit
        ):
            raise EvidenceError("prepared execution receipt exit code is invalid")
        checkout, toolchain, configuration_digest, prefixes = (
            _expected_variant_identity(
                variant,
                request,
            )
        )
        if (
            receipt["checkout_commit"] != checkout
            or receipt["toolchain_identity"] != toolchain
            or receipt["run_configuration_digest"] != configuration_digest
            or receipt["executable_sha256"] != runner_identity["sha256"]
        ):
            raise EvidenceError("prepared execution receipt identity is invalid")
        for field, expected in (
            ("scene_id", request["binding"]["scene_id"]),
            ("input_digest", request["binding"]["input_digest"]),
            ("scale", request["binding"]["scale"]),
            ("lane", lane),
        ):
            if receipt[field] != expected:
                raise EvidenceError(f"prepared execution receipt {field} is invalid")
        _digest(receipt["output_sha256"], f"{context}.output_sha256")
        if type(receipt["published_output"]) is not bool:
            raise EvidenceError(
                "prepared execution receipt published_output must be boolean"
            )
        if receipt["published_output"]:
            published_count += 1
            if (
                published_output_sha256 is None
                or receipt["output_sha256"] != published_output_sha256
            ):
                raise EvidenceError(
                    "prepared published receipt does not match output_ply"
                )
        argv = receipt["argv"]
        if (
            not isinstance(argv, list)
            or not argv
            or any(
                not isinstance(argument, str)
                or not argument
                or "/Users/" in argument
                or "/home/" in argument
                for argument in argv
            )
            or any(
                not any(argument.startswith(prefix) for argument in argv)
                for prefix in prefixes
            )
        ):
            raise EvidenceError("prepared execution receipt argv is invalid")

        geometry_execution: Mapping[str, Any] | None = None
        if valid_outcome and variant in {"candidate", "fast_candidate"}:
            worker_receipt = _mapping(
                receipt["runtime_worker_evidence"],
                f"{context}.runtime_worker_evidence",
            )
            _exact_keys(
                worker_receipt,
                {
                    "artifact_name",
                    "artifact_sha256",
                    "geometry_manifest_name",
                    "geometry_manifest_sha256",
                    "canonical_cameras_name",
                    "canonical_cameras_sha256",
                    "geometry_input_digest",
                    "selected_frames_digest",
                },
                f"{context}.runtime_worker_evidence",
            )
            artifact_name = _token(
                worker_receipt["artifact_name"],
                f"{context}.runtime_worker_evidence.artifact_name",
            )
            geometry_name = _token(
                worker_receipt["geometry_manifest_name"],
                f"{context}.runtime_worker_evidence.geometry_manifest_name",
            )
            cameras_name = _token(
                worker_receipt["canonical_cameras_name"],
                f"{context}.runtime_worker_evidence.canonical_cameras_name",
            )
            if len({artifact_name, geometry_name, cameras_name}) != 3:
                raise EvidenceError(
                    "prepared worker, geometry, and camera artifacts must be distinct"
                )
            for field in (
                "artifact_sha256",
                "geometry_manifest_sha256",
                "canonical_cameras_sha256",
                "geometry_input_digest",
                "selected_frames_digest",
            ):
                _digest(
                    worker_receipt[field],
                    f"{context}.runtime_worker_evidence.{field}",
                )
            expected_selected_digest = request["reference_artifacts"][
                "selected_frames_digests"
            ][variant]
            if (
                worker_receipt["geometry_input_digest"]
                != request["reference_artifacts"]["geometry_input_digest"]
                or worker_receipt["selected_frames_digest"] != expected_selected_digest
            ):
                raise EvidenceError("prepared runtime worker input binding is invalid")
            if artifact_root is not None:
                assert descriptors is not None
                configuration = dict(request["candidate_run_configuration"])
                if variant == "fast_candidate":
                    configuration.update(
                        {
                            "detail_profile": "fast",
                            "trainer_iterations": 3_000,
                            "trainer_plateau_window": 400,
                        }
                    )
                geometry_execution = _validate_runtime_worker_evidence(
                    worker_receipt,
                    configuration,
                    request,
                    variant,
                    run_id,
                    artifact_root,
                    descriptors,
                    used_worker_artifacts,
                    f"{context}.runtime_worker_evidence",
                    None,
                )
        elif receipt["runtime_worker_evidence"] is not None:
            raise EvidenceError(
                "prepared noncandidate receipt cannot claim runtime worker evidence"
            )

        if geometry_execution is not None:
            _validate_mapper_invocations(
                receipt["mapper_invocations"],
                variant,
                request,
                valid_outcome=valid_outcome,
                planned_mapper_cadence=receipt["planned_mapper_cadence"],
                accepted_mapper_cadence=receipt["accepted_mapper_cadence"],
                cadence_fallback_trigger=receipt["cadence_fallback_trigger"],
                geometry_execution=geometry_execution,
            )
        elif valid_outcome and variant in {"candidate", "fast_candidate"}:
            mapper_invocations = receipt["mapper_invocations"]
            accepted_count = (
                sum(
                    isinstance(item, Mapping)
                    and isinstance(item.get("evaluation"), Mapping)
                    and item["evaluation"].get("status") == "accepted"
                    for item in mapper_invocations
                )
                if isinstance(mapper_invocations, list)
                else -1
            )
            seeded_hint = (
                {
                    "refinement_kind": "seededBundleAdjustment",
                    "successful_mapper_attempt_ordinals": [
                        item.get("mapping_attempt_ordinal")
                        for item in mapper_invocations
                        if isinstance(item, Mapping)
                    ],
                }
                if accepted_count == 0
                else None
            )
            _validate_mapper_invocations(
                mapper_invocations,
                variant,
                request,
                valid_outcome=True,
                planned_mapper_cadence=receipt["planned_mapper_cadence"],
                accepted_mapper_cadence=receipt["accepted_mapper_cadence"],
                cadence_fallback_trigger=receipt["cadence_fallback_trigger"],
                geometry_execution=seeded_hint,
            )
        else:
            _validate_mapper_invocations(
                receipt["mapper_invocations"],
                variant,
                request,
                valid_outcome=valid_outcome,
                planned_mapper_cadence=receipt["planned_mapper_cadence"],
                accepted_mapper_cadence=receipt["accepted_mapper_cadence"],
                cadence_fallback_trigger=receipt["cadence_fallback_trigger"],
            )
    if valid_outcome and published_count != 1:
        raise EvidenceError("prepared valid evidence requires one published receipt")
    if not valid_outcome:
        if len(commands) != 1 or published_count:
            raise EvidenceError(
                "prepared invalid evidence has an invalid receipt closure"
            )


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
        raise EvidenceError(
            "measurement environment monitor executable is not approved"
        )
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
        raise EvidenceError(
            "measurement environment sample interval exceeds one second"
        )
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
        raise EvidenceError(
            "measurement environment does not bracket the supervisor window"
        )

    state_change_events = environment["state_change_events"]
    if (
        not isinstance(state_change_events, list)
        or len(state_change_events) > sample_count
    ):
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
            raise EvidenceError(
                "measurement environment state-change events are not canonical"
            )
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
    if not isinstance(command_environment, list) or len(command_environment) != len(
        commands
    ):
        raise EvidenceError("measurement environment command closure is incomplete")
    process_cpu_total = 0
    for index, (raw, command) in enumerate(
        zip(command_environment, commands, strict=True)
    ):
        item = _mapping(raw, f"measurement environment commands[{index}]")
        _exact_keys(
            item,
            {
                "run_id",
                "host_busy_fraction",
                "process_cpu_fraction",
                "external_cpu_fraction",
            },
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
            raise EvidenceError(
                "measurement environment CPU fraction is outside its domain"
            )
        if not math.isclose(
            process_fraction, expected_process_fraction, rel_tol=0, abs_tol=1e-9
        ):
            raise EvidenceError(
                "measurement environment process CPU fraction is inconsistent"
            )
        if not math.isclose(
            external_fraction,
            max(0.0, host_busy - process_fraction),
            rel_tol=0,
            abs_tol=1e-9,
        ):
            raise EvidenceError(
                "measurement environment external CPU fraction is inconsistent"
            )
        if external_fraction > MAX_EXTERNAL_CPU_FRACTION + 1e-12:
            rejections.append("external_cpu")
    outer_cpu_total = child_cpu["user"] + child_cpu["system"]
    if process_cpu_total > outer_cpu_total + max(
        100_000, math.ceil(outer_cpu_total * 0.01)
    ):
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
        raise EvidenceError(
            "measurement environment supervisor CPU accounting is inconsistent"
        )
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
            raise EvidenceError(
                f"supervisor_run {field} does not match the protected request"
            )
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
    if not isinstance(argv, list) or any(
        not isinstance(item, str) or not item for item in argv
    ):
        raise EvidenceError(
            "supervisor_run argv must be a nonempty redacted argument array"
        )
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
        raise EvidenceError(
            "supervisor_run argv is not bound to the protected execution"
        )
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
            raise EvidenceError(
                "execution receipt falls outside the supervisor monotonic window"
            )

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
        raise EvidenceError(
            "execution receipts leave too much supervisor time unattributed"
        )


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
    if not isinstance(argv, list) or any(
        not isinstance(item, str) or not item for item in argv
    ):
        raise EvidenceError(
            "render_supervisor argv must be a nonempty redacted argument array"
        )
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
        raise EvidenceError(
            "render_supervisor argv is not bound to the protected rendering process"
        )


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
        raise EvidenceError(
            "orientation supervisor metrics index digest does not match"
        )
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
    commands = observations.get("commands")
    if not isinstance(commands, list):
        raise EvidenceError("orientation evidence requires execution receipts")
    execution_by_run: dict[str, Mapping[str, Any]] = {}
    for raw_command in commands:
        if not isinstance(raw_command, Mapping):
            continue
        run_id = raw_command.get("run_id")
        if (
            run_id in candidate_run_ids
            and raw_command.get("phase") == "ordinary"
            and raw_command.get("variant") == "candidate"
        ):
            if run_id in execution_by_run:
                raise EvidenceError("orientation execution run ids must be unique")
            execution_by_run[str(run_id)] = raw_command
    if set(execution_by_run) != set(candidate_run_ids):
        raise EvidenceError("orientation evidence is missing authenticated executions")
    if (
        supervisor["scoring_run_id"] != scoring_run_id
        or aggregate["scoring_run_id"] != scoring_run_id
    ):
        raise EvidenceError(
            "orientation scoring run does not match the published output"
        )
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
            raise EvidenceError(
                "orientation supervisor runs are not in candidate timing order"
            )
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
            raise EvidenceError(
                "orientation metrics runs are not in candidate timing order"
            )

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
            dynamic_descriptors[f"orientation_{descriptor_name}_{index:02d}"] = (
                descriptor
            )

        execution = execution_by_run[run_id]
        runtime = _mapping(
            execution.get("runtime_worker_evidence"),
            f"orientation runtime worker evidence for {run_id}",
        )
        if runtime.get("geometry_manifest_sha256") != receipt[
            "geometry_manifest_sha256"
        ]:
            raise EvidenceError(
                f"orientation geometry for {run_id} does not match the authenticated execution"
            )
        geometry_path = artifact_root / Path(*expected_paths["geometry_manifest_path"].parts)
        geometry = _mapping(
            _load_bounded_json(geometry_path, f"orientation geometry for {run_id}"),
            f"orientation geometry for {run_id}",
        )
        model_hashes = _mapping(
            geometry.get("modelHashes"),
            f"orientation geometry model hashes for {run_id}",
        )
        if model_hashes.get("images.txt") != receipt[
            "candidate_images_sha256"
        ].removeprefix("sha256:"):
            raise EvidenceError(
                f"orientation images for {run_id} do not match the authenticated geometry"
            )

        if aggregate_run["metrics_path"] != receipt["metrics_path"]:
            raise EvidenceError(
                "orientation metrics index path does not match its receipt"
            )
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
            raise EvidenceError(
                "orientation metrics index does not match the driver output"
            )
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
            raise EvidenceError(
                f"orientation supervisor execution for {run_id} is invalid"
            )
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
            "--geometry-manifest-sha256",
            receipt["geometry_manifest_sha256"],
            "--candidate-images",
            f"evidence://{expected_paths['candidate_images_path'].as_posix()}",
            "--candidate-images-sha256",
            receipt["candidate_images_sha256"],
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
        if run["variant"] in {"candidate", "fast_candidate"}
        and run["duration"] is not None
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
            raise EvidenceError(
                "memory sample is not bound to a candidate execution receipt"
            )
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
        raise EvidenceError(
            "memory samples do not cover every candidate execution receipt"
        )
    for run_id, run in candidate_runs.items():
        duration = float(run["duration"])
        run_samples = by_run[run_id]
        elapsed_values = [sample[0] for sample in run_samples]
        if elapsed_values != sorted(elapsed_values) or len(elapsed_values) != len(
            set(elapsed_values)
        ):
            raise EvidenceError(
                "memory sample timestamps must be strictly increasing per run"
            )
        if not math.isclose(elapsed_values[0], 0, abs_tol=1e-6) or not math.isclose(
            elapsed_values[-1], duration, rel_tol=0, abs_tol=1e-6
        ):
            raise EvidenceError(
                "memory samples must span each candidate run from launch to exit"
            )
        if any(
            later - earlier > interval * 1.25 + 1e-6
            for earlier, later in zip(elapsed_values, elapsed_values[1:], strict=False)
        ):
            raise EvidenceError("memory sampling cadence has an uncovered gap")
        # macOS exposes process-tree RSS but no stable public cross-process Metal
        # allocation counter. Zero preserves that unavailable measurement without
        # inventing a GPU-memory value; unified-memory release gates use RSS.
    physical_memory = machine.get("physical_memory_bytes")
    if type(physical_memory) is not int or physical_memory <= 0:
        raise EvidenceError("machine physical memory is unavailable")
    return {
        "peak_memory_bytes": measured(
            max(sample[1] for samples in by_run.values() for sample in samples)
        ),
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
    _exact_keys(
        compute, {"stages", "cpu_only_reasons"}, "observations.resolved_compute"
    )
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
        "matching": "faiss_metal_disabled_selected_indices_unsupported",
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
        raise EvidenceError(
            "CPU-only stage reasons do not match the supported backend closure"
        )
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
            raise EvidenceError(
                "valid evidence must report one clean successful process outcome"
            )
    else:
        if (
            type(actual["exit_code"]) is not int
            or actual["exit_code"] == 0
            or actual["termination_reason"] != "exit"
            or actual["cancelled"] is not False
            or actual["failure_type"] != expected_outcome["failure_type"]
            or actual["corrupt_ply"] is not False
        ):
            raise EvidenceError(
                "invalid-input evidence must report the expected clean rejection"
            )
    return dict(actual)


def _toolchain_scenario_metrics(
    value: Any,
    binding: Mapping[str, Any],
) -> dict[str, dict[str, Any]]:
    if not isinstance(value, list) or len(value) != len(TOOLCHAIN_SCENARIO_SPECS):
        raise EvidenceError(
            "toolchain_scenarios must contain the complete scenario closure"
        )
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
        if (
            record["fault"] != spec["fault"]
            or record["network_mode"] != spec["network_mode"]
        ):
            raise EvidenceError(
                "toolchain scenario fault injection does not match its name"
            )
        if record["toolchain_identity"] != binding["toolchain_identity"]:
            raise EvidenceError(
                "toolchain scenario is not bound to the requested toolchain"
            )
        if record["input_digest"] != binding["input_digest"]:
            raise EvidenceError(
                "toolchain scenario is not bound to the requested input"
            )
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
        if (
            not isinstance(record["result"], str)
            or type(record["post_state_verified"]) is not bool
        ):
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
    if isinstance(published_at, bool) or not isinstance(
        published_at, (int, float, str)
    ):
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
            raise EvidenceError(
                "toolchain manifest publication date is invalid"
            ) from error
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
        {
            "schemaVersion",
            "installedArtifacts",
            "installedCapabilities",
            "signedManifest",
        },
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
        "expandedClosureSHA256",
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
            or not isinstance(component["expandedClosureSHA256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", component["expandedClosureSHA256"]) is None
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
            if (
                relative not in contents
                or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            ):
                raise EvidenceError(f"{label} manifest critical file is invalid")
        components_by_name[name] = component
    for name, component in components_by_name.items():
        if any(
            dependency not in components_by_name
            for dependency in component["dependencies"]
        ):
            raise EvidenceError(f"{label} component dependency is unknown: {name}")

    installed_artifacts = _mapping(
        state["installedArtifacts"], f"{label}.installedArtifacts"
    )
    installed_names = set(installed_artifacts)
    if "macos-arm64-core" not in installed_names or not installed_names.issubset(
        components_by_name
    ):
        raise EvidenceError(f"{label} installed component closure is invalid")
    for name, digest in installed_artifacts.items():
        if digest != components_by_name[name]["sha256"]:
            raise EvidenceError(
                f"{label} installed component digest is invalid: {name}"
            )
        missing = set(components_by_name[name]["dependencies"]) - installed_names
        if missing:
            raise EvidenceError(
                f"{label} installed component is missing dependencies: {name}"
            )
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
        for component in sorted(
            components_by_name.values(), key=lambda value: value["name"]
        )
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
                raise EvidenceError(
                    f"{label} contents do not match the signed manifest"
                )
            if (
                sum(member.file_size for member in files.values())
                > component["expandedSizeBytes"]
            ):
                raise EvidenceError(
                    f"{label} expanded size exceeds the signed manifest"
                )
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
                raise EvidenceError(
                    f"{label} component closure does not match its install receipt"
                )
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
                    if (
                        copied != component["sizeBytes"]
                        or hasher.hexdigest() != component["sha256"]
                    ):
                        raise EvidenceError(
                            f"{label} component archive digest is invalid: {name}"
                        )
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
    normal_manifest, normal_components, normal_names, _ = (
        _validated_toolchain_install_state(
            artifact_root / descriptors["normal_photo_toolchain_state"]["path"],
            "normal photo toolchain install state",
        )
    )
    large_manifest, large_components, large_names, large_identity = (
        _validated_toolchain_install_state(
            artifact_root / descriptors["large_area_toolchain_state"]["path"],
            "large area toolchain install state",
        )
    )
    if canonical_json_bytes(normal_manifest) != canonical_json_bytes(large_manifest):
        raise EvidenceError(
            "toolchain package closures do not use the same signed manifest"
        )
    if large_identity != bound_toolchain_identity:
        raise EvidenceError(
            "large area toolchain closure does not match the bound toolchain identity"
        )
    if not normal_names.issubset(large_names):
        raise EvidenceError(
            "normal photo toolchain closure is not contained in large area closure"
        )
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
        raise EvidenceError(
            "normal photo toolchain closure unexpectedly selects streaming"
        )
    if large_has_streaming and normal_names == large_names:
        raise EvidenceError(
            "streaming toolchain closure must add its signed components"
        )
    if normal_names == large_names:
        if not same_archive:
            raise EvidenceError(
                "identical toolchain component closures must use the same archive"
            )
    elif same_archive:
        raise EvidenceError(
            "distinct toolchain component closures cannot share one archive"
        )
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
    raw_pipeline = _mapping(
        observations.get("pipeline_metrics"), "observations.pipeline_metrics"
    )
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
                }
            )
        if "suite_performance" in scopes:
            required_pipeline.update({"bundle_adjustment_cycles"})
        missing_pipeline = sorted(
            name for name in required_pipeline if raw_pipeline.get(name) is None
        )
        if missing_pipeline:
            raise EvidenceError(
                "required pipeline metrics are not measured: "
                + ", ".join(missing_pipeline)
            )
        if "scene_quality" in scopes:
            scheduled = raw_pipeline["scheduled_pairs"]
            local = raw_pipeline["local_pairs"]
            retrieval = raw_pipeline["retrieval_pairs"]
            loop = raw_pipeline["loop_pairs"]
            verified = raw_pipeline["spatially_verified_pairs"]
            if candidate_run_configuration["pairing_policy"] == "unordered_exhaustive":
                expected_exhaustive = requested_scale * (requested_scale - 1) // 2
                if (
                    scheduled != expected_exhaustive
                    or retrieval != expected_exhaustive
                    or local != 0
                    or loop != 0
                ):
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
        registration = _mapping(
            observations.get("registration"), "observations.registration"
        )
        _exact_keys(
            registration,
            {"candidate", "colmap", "baseline"},
            "observations.registration",
        )
        candidate_registered = _booleans(
            registration.get("candidate"), "registration.candidate"
        )
        colmap_registered = _booleans(registration.get("colmap"), "registration.colmap")
        baseline_registered = _booleans(
            registration.get("baseline"), "registration.baseline"
        )
        if len(candidate_registered) != len(colmap_registered):
            raise EvidenceError("registration sample counts must match")
        if len(candidate_registered) != len(baseline_registered):
            raise EvidenceError(
                "baseline registration sample count must match the candidate"
            )
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
        colmap_rms = math.sqrt(
            sum(value * value for value in colmap_ate) / len(colmap_ate)
        )
        if colmap_rms == 0:
            raise EvidenceError("COLMAP ATE reference must be nonzero")
        candidate_rms = math.sqrt(
            sum(value * value for value in candidate_ate) / len(candidate_ate)
        )
        if rendering_evidence is None:
            raise EvidenceError("scene quality requires rendered pixel evidence")
        balanced_records = rendering_evidence.balanced
        fast_records = rendering_evidence.fast
        if (
            not isinstance(balanced_records, list)
            or len(balanced_records) != holdout_count
        ):
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
                    max(
                        0.0,
                        statistics.median(candidate_rotation)
                        - statistics.median(colmap_rotation),
                    )
                ),
                "translation_rpe_delta_percentage_points": measured(
                    max(
                        0.0,
                        statistics.median(candidate_translation)
                        - statistics.median(colmap_translation),
                    )
                ),
                "balanced_median_psnr_loss_db": measured(
                    statistics.median(balanced_psnr)
                ),
                "balanced_median_ssim_loss": measured(statistics.median(balanced_ssim)),
                "balanced_median_lpips_increase": measured(
                    statistics.median(balanced_lpips)
                ),
                "balanced_scene_psnr_loss_db": measured(
                    statistics.median(balanced_psnr)
                ),
                "balanced_scene_ssim_loss": measured(statistics.median(balanced_ssim)),
                "balanced_scene_lpips_increase": measured(
                    statistics.median(balanced_lpips)
                ),
                "fast_scene_psnr_loss_db": measured(statistics.median(fast_psnr)),
                "fast_scene_ssim_loss": measured(statistics.median(fast_ssim)),
                "fast_scene_lpips_increase": measured(statistics.median(fast_lpips)),
                "paired_balanced_scene_psnr_loss_db": measured(
                    statistics.median(paired_psnr)
                ),
                "paired_balanced_scene_ssim_loss": measured(
                    statistics.median(paired_ssim)
                ),
                "paired_balanced_scene_lpips_increase": measured(
                    statistics.median(paired_lpips)
                ),
            }
        )

    if "long_sequence" in scopes:
        long_sequence = _mapping(
            observations.get("long_sequence"), "observations.long_sequence"
        )
        _exact_keys(
            long_sequence,
            {"processed_frames", "analysis_seconds", "rss_windows"},
            "observations.long_sequence",
        )
        frames = long_sequence.get("processed_frames")
        seconds = long_sequence.get("analysis_seconds")
        if type(frames) is not int or frames <= 0:
            raise EvidenceError(
                "long_sequence.processed_frames must be a positive integer"
            )
        if (
            isinstance(seconds, bool)
            or not isinstance(seconds, (int, float))
            or not math.isfinite(seconds)
            or seconds <= 0
        ):
            raise EvidenceError(
                "long_sequence.analysis_seconds must be positive and finite"
            )
        if frames != requested_scale:
            raise EvidenceError(
                "long_sequence.processed_frames must equal the requested scale"
            )
        raw_windows = long_sequence.get("rss_windows")
        expected_window_count = math.ceil(frames / 500)
        if (
            not isinstance(raw_windows, list)
            or len(raw_windows) != expected_window_count
        ):
            raise EvidenceError(
                "long_sequence.rss_windows must cover every 500-frame window"
            )
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
            if (
                window["start_frame"] != expected_start
                or window["end_frame"] != expected_end
            ):
                raise EvidenceError(
                    "long_sequence.rss_windows frame coverage is not contiguous"
                )
            rss = window["rss_bytes"]
            if type(rss) is not int or rss <= 0:
                raise EvidenceError(
                    "long_sequence.rss_windows rss_bytes must be positive"
                )
            windows.append(float(rss))
        if len(windows) < 2:
            raise EvidenceError(
                "long_sequence.rss_windows must include a second window"
            )
        growth = max(0.0, (windows[-1] - windows[1]) / windows[1])
        metrics["long_sequence_analysis_fps"] = measured(frames / float(seconds))
        metrics["long_sequence_frames"] = measured(frames)
        metrics["long_sequence_rss_growth_fraction"] = measured(growth)

    if "stability" in scopes:
        stability = _mapping(observations.get("stability"), "observations.stability")
        _exact_keys(stability, {"runs"}, "observations.stability")
        stability_runs = stability.get("runs")
        if not isinstance(stability_runs, list) or len(stability_runs) != 50:
            raise EvidenceError(
                "observations.stability.runs must contain exactly 50 runs"
            )
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
            if not isinstance(sample["crashed"], bool) or not isinstance(
                sample["corrupt_output"], bool
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
            if sample["recovery_action"] not in {
                "none",
                "cancel_resume",
                "relaunch_resume",
            }:
                raise EvidenceError("stability recovery action is invalid")
            is_uninterrupted = sample["interruption_stage"] == "none"
            if is_uninterrupted != (sample["recovery_action"] == "none"):
                raise EvidenceError(
                    "stability interruption none must pair only with recovery none"
                )
            if is_uninterrupted:
                if sample["recovery_succeeded"] is not None:
                    raise EvidenceError(
                        "uninterrupted stability runs must not report recovery"
                    )
            elif type(sample["recovery_succeeded"]) is not bool:
                raise EvidenceError(
                    "interrupted stability runs must report recovery success"
                )
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
            raise EvidenceError(
                "stability runs must cover every valid capture category"
            )
        if profiles != {"fast", "balanced", "high_detail"}:
            raise EvidenceError("stability runs must cover every detail profile")
        if not {"prepare", "reconstruct", "train", "finish"}.issubset(
            interruption_stages
        ):
            raise EvidenceError(
                "stability runs must cover every durable interruption stage"
            )
        if not {"cancel_resume", "relaunch_resume"}.issubset(recovery_actions):
            raise EvidenceError(
                "stability runs must cover cancel and relaunch recovery"
            )
        required_pairs = {
            (stage, action)
            for stage in ("prepare", "reconstruct", "train", "finish")
            for action in ("cancel_resume", "relaunch_resume")
        }
        if not required_pairs.issubset(stage_recovery_pairs):
            raise EvidenceError(
                "stability runs must cover every durable stage and recovery pair"
            )
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
            raise EvidenceError(
                "missing toolchain size artifacts: " + ", ".join(sorted(missing_sizes))
            )
        metrics["normal_photo_toolchain_bytes"] = measured(
            artifact_sizes["normal_photo_toolchain"]
        )
        metrics["large_area_toolchain_bytes"] = measured(
            artifact_sizes["large_area_toolchain"]
        )
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
            return subprocess.run(
                argv, check=True, capture_output=True, text=True, timeout=20
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return "not_available"

    def sysctl(name: str) -> str:
        return command(["/usr/sbin/sysctl", "-n", name])

    def integer_sysctl(name: str) -> int | None:
        try:
            return int(sysctl(name))
        except ValueError:
            return None

    clang_version = command(["/usr/bin/xcrun", "clang", "--version"]).splitlines()[0]
    swift_version = command(["/usr/bin/xcrun", "swift", "--version"]).splitlines()[0]
    metal_version = command(["/usr/bin/xcrun", "metal", "--version"]).splitlines()[0]
    return {
        "architecture": platform.machine(),
        "chip": sysctl("machdep.cpu.brand_string"),
        "clang_version": clang_version,
        "hardware_model": sysctl("hw.model"),
        "logical_cpus": integer_sysctl("hw.logicalcpu"),
        "macos_build": command(["/usr/bin/sw_vers", "-buildVersion"]),
        "macos_version": command(["/usr/bin/sw_vers", "-productVersion"]),
        "macos_sdk_build": command(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        ),
        "macos_sdk_version": command(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]
        ),
        "metal_version": metal_version,
        "physical_cpus": integer_sysctl("hw.physicalcpu"),
        "physical_memory_bytes": integer_sysctl("hw.memsize"),
        "swift_version": swift_version,
        "xcode_version": command(["/usr/bin/xcodebuild", "-version"]),
    }


def validate_machine_lane(machine: Mapping[str, Any], lane: str) -> None:
    required = {
        "architecture",
        "chip",
        "clang_version",
        "hardware_model",
        "logical_cpus",
        "macos_build",
        "macos_version",
        "macos_sdk_build",
        "macos_sdk_version",
        "metal_version",
        "physical_cpus",
        "physical_memory_bytes",
        "swift_version",
        "xcode_version",
    }
    _exact_keys(machine, required, "machine")
    if machine["architecture"] != "arm64":
        raise EvidenceError("release evidence must be measured on Apple Silicon")
    if any(
        machine.get(field) != expected
        for field, expected in SHIPPING_MACHINE_SOFTWARE.items()
    ):
        raise EvidenceError(
            "release evidence requires the exact shipping compiler, SDK, and Metal tuple"
        )
    memory = machine["physical_memory_bytes"]
    if type(memory) is not int:
        raise EvidenceError("machine physical memory is unavailable")
    gib = 1024**3
    if lane == LANE_REFERENCE:
        if "M4 Max" not in str(machine["chip"]) or memory != 48 * gib:
            raise EvidenceError(
                "reference lane requires an M4 Max with exactly 48 GiB memory"
            )
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
            "video_source_count",
            "gate_scopes",
            "rendering_driver_identity",
        },
        "request",
    )
    if value["schema_version"] != REQUEST_SCHEMA_VERSION:
        raise EvidenceError(f"request schema_version must be {REQUEST_SCHEMA_VERSION}")
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
    if (
        sha256_bytes(canonical_json_bytes(baseline_configuration))
        != binding["baseline_configuration_digest"]
    ):
        raise EvidenceError(
            "request baseline_run_configuration does not match its digest"
        )
    if not isinstance(binding["git_commit"], str) or not re.fullmatch(
        r"[0-9a-f]{40}", binding["git_commit"]
    ):
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
        or any(
            not isinstance(trait, str) or not SAFE_TOKEN_PATTERN.fullmatch(trait)
            for trait in capture_traits
        )
    ):
        raise EvidenceError(
            "request.capture_traits must be a sorted unique token array"
        )
    if value["input_kind"] not in {"video", "multi_video", "photos", "mixed"}:
        raise EvidenceError("request.input_kind is invalid")
    video_source_count = value["video_source_count"]
    if type(video_source_count) is not int or video_source_count < 0:
        raise EvidenceError("request.video_source_count is invalid")
    if value["input_kind"] == "photos" and video_source_count != 0:
        raise EvidenceError("photo input must bind zero video sources")
    if value["input_kind"] == "video" and video_source_count != 1:
        raise EvidenceError("video input must bind exactly one video source")
    if value["input_kind"] == "multi_video" and video_source_count < 2:
        raise EvidenceError("multi-video input must bind at least two video sources")
    if value["input_kind"] == "mixed" and video_source_count < 1:
        raise EvidenceError("mixed input must bind at least one video source")
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
            raise EvidenceError(
                "video holdout indices must contain every fifth selected frame"
            )
    elif holdout_indices != []:
        raise EvidenceError("invalid requests must not declare rendering holdouts")
    if value["timing_basis"] != "selected_view_count":
        raise EvidenceError("request timing_basis must be selected_view_count")
    reference_artifacts = _mapping(
        value["reference_artifacts"], "request.reference_artifacts"
    )
    reference_digest_fields = {
        "selection_manifest_sha256",
        "ground_truth_poses_sha256",
        "accurate_colmap_model_sha256",
        "accurate_rendering_reference_sha256",
        "ground_truth_preparation_sha256",
        "paired_baseline_rendering_reference_sha256",
        "orientation_label_sha256",
        "geometry_input_digest",
    }
    if expected["kind"] == "valid":
        _exact_keys(
            reference_artifacts,
            reference_digest_fields
            | {"orientation_expected_status", "selected_frames_digests"},
            "request.reference_artifacts",
        )
        for field in reference_digest_fields:
            _digest(reference_artifacts[field], f"request.reference_artifacts.{field}")
        if (
            reference_artifacts["orientation_expected_status"]
            not in PIPELINE_ENUM_METRICS["orientation_status"]
        ):
            raise EvidenceError("request orientation_expected_status is invalid")
        selected_frames_digests = _mapping(
            reference_artifacts["selected_frames_digests"],
            "request.reference_artifacts.selected_frames_digests",
        )
        _exact_keys(
            selected_frames_digests,
            {"candidate", "fast_candidate"},
            "request.reference_artifacts.selected_frames_digests",
        )
        for variant, digest in selected_frames_digests.items():
            _digest(
                digest,
                f"request.reference_artifacts.selected_frames_digests.{variant}",
            )
    else:
        _exact_keys(reference_artifacts, {"status"}, "request.reference_artifacts")
        if reference_artifacts["status"] != "not_applicable":
            raise EvidenceError(
                "invalid requests must mark reference artifacts not_applicable"
            )
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
            "vocabulary_returned_neighbor_count",
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
            "feature_extraction_workers",
            "coupled_matching_workers",
            "vocabulary_retrieval_workers",
            "maximum_concurrent_video_source_analysis_tasks",
            "run_seed",
        },
        "request.candidate_run_configuration",
    )
    expected_detail = "balanced" if binding["lane"] == LANE_REFERENCE else "fast"
    expected_resource = (
        "automatic" if binding["lane"] == LANE_REFERENCE else "conserve_memory"
    )
    if candidate_configuration["detail_profile"] != expected_detail:
        raise EvidenceError("candidate detail profile does not match its hardware lane")
    if candidate_configuration["resource_policy"] != expected_resource:
        raise EvidenceError(
            "candidate resource policy does not match its hardware lane"
        )
    if candidate_configuration["compute_policy"] != "metal_for_supported_stages":
        raise EvidenceError(
            "candidate compute policy must prefer Metal where supported"
        )
    if candidate_configuration["selected_frame_count"] != binding["scale"]:
        raise EvidenceError(
            "candidate selected frame count does not match request scale"
        )
    homogeneous_fisheye_photos = (
        value["input_kind"] == "photos"
        and "fisheye" in capture_traits
        and "mixed_intrinsics" not in capture_traits
    )
    expected_camera_grouping = (
        "same_camera_and_lens" if homogeneous_fisheye_photos else "automatic"
    )
    expected_lens_projection = (
        "fisheye" if "fisheye" in capture_traits else "automatic"
    )
    if candidate_configuration["camera_grouping"] != expected_camera_grouping:
        raise EvidenceError(
            "candidate camera grouping does not match the protected input traits"
        )
    if candidate_configuration["lens_projection"] != expected_lens_projection:
        raise EvidenceError(
            "candidate lens projection does not match the protected input traits"
        )
    topology = candidate_configuration["input_topology"]
    if topology == "segmented_mixed":
        expected_capture_path = (
            "large_area" if value["category"] == "large_area_exterior" else "automatic"
        )
    elif topology == "unordered":
        expected_capture_path = "automatic"
    else:
        expected_capture_path = {
            "object_orbit": "around_subject",
            "interior_walkthrough": "through_space",
            "large_area_exterior": "large_area",
        }.get(value["category"], "automatic")
    if candidate_configuration["capture_path"] != expected_capture_path:
        raise EvidenceError(
            "candidate capture path does not match its category and input topology"
        )
    if candidate_configuration["descriptor_matcher"] != "faiss":
        raise EvidenceError("candidate descriptor matcher must be faiss")
    worker_fields = (
        "feature_extraction_workers",
        "coupled_matching_workers",
        "vocabulary_retrieval_workers",
        "maximum_concurrent_video_source_analysis_tasks",
    )
    if any(
        type(candidate_configuration[field]) is not int
        or not 1 <= candidate_configuration[field] <= 64
        for field in worker_fields
    ):
        raise EvidenceError("candidate worker budget is invalid")
    expected_worker_budget = (
        {
            "feature_extraction_workers": 12,
            "coupled_matching_workers": 8,
            "vocabulary_retrieval_workers": 8,
        }
        if binding["lane"] == LANE_REFERENCE
        else {
            "feature_extraction_workers": 4,
            "coupled_matching_workers": 4,
            "vocabulary_retrieval_workers": 4,
        }
    )
    expected_worker_budget["maximum_concurrent_video_source_analysis_tasks"] = (
        1
        if value["input_kind"] == "photos"
        else (4 if binding["lane"] == LANE_REFERENCE else 2)
    )
    if any(
        candidate_configuration[field] != expected_worker_budget[field]
        for field in worker_fields
    ):
        raise EvidenceError("candidate worker budget does not match its hardware lane")
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
        raise EvidenceError(
            "request.gate_scopes must be a nonempty sorted list of supported scopes"
        )
    if expected["kind"] == "invalid" and gate_scopes != ["invalid_input"]:
        raise EvidenceError(
            "invalid requests must use only the invalid_input gate scope"
        )
    if expected["kind"] == "valid" and "invalid_input" in gate_scopes:
        raise EvidenceError("valid requests cannot use the invalid_input gate scope")
    if "long_sequence" in gate_scopes and binding["scale"] != 3000:
        raise EvidenceError(
            "long_sequence evidence must be bound to the 3000-frame scale"
        )
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
            if (
                type(exit_code) is not int
                or exit_code == 0
                or not -255 <= exit_code <= 255
            ):
                raise EvidenceError(
                    "nonzero outcome requires a bounded nonzero exit code"
                )
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
            or (reason == "host_monitor_failed" and exit_code not in {None, 0})
            or (reason == "postprocessing_failed" and exit_code != 0)
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
        raise EvidenceError(
            "environment lane outcome does not prove a policy rejection"
        )


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
        raise EvidenceError(
            f"{label} dimensions exceed the 4,194,304-pixel render limit"
        )
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
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
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
                    raise EvidenceError(
                        f"{label} is larger than its bound dimensions allow"
                    )
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
                    raise EvidenceError(
                        f"{label} dimensions do not match its bound camera"
                    )
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
    if (
        pixels.shape != (expected_height, expected_width, 3)
        or not numpy.isfinite(pixels).all()
    ):
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
    horizontal_source = numpy.pad(
        image, ((0, 0), (radius, radius), (0, 0)), mode="reflect"
    )
    horizontal = numpy.zeros_like(image)
    for offset, weight in enumerate(kernel):
        horizontal += horizontal_source[:, offset : offset + image.shape[1], :] * weight
    vertical_source = numpy.pad(
        horizontal, ((radius, radius), (0, 0), (0, 0)), mode="reflect"
    )
    result = numpy.zeros_like(image)
    for offset, weight in enumerate(kernel):
        result += vertical_source[offset : offset + image.shape[0], :, :] * weight
    return result


def _pixel_metrics(
    candidate: Any, target: Any, lpips_distance: Any
) -> tuple[float, float, float]:
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
    covariance = _separable_gaussian_blur(candidate * target) - mu_candidate * mu_target
    c1 = 0.01**2
    c2 = 0.03**2
    numerator = (2 * mu_candidate * mu_target + c1) * (2 * covariance + c2)
    denominator = (mu_candidate * mu_candidate + mu_target * mu_target + c1) * (
        variance_candidate + variance_target + c2
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
        key for key in model_state if re.fullmatch(r"lin\d+\.model\.\d+\.weight", key)
    }
    if model_head_keys != LPIPS_CALIBRATION_HEAD_KEYS:
        raise EvidenceError(
            "the constructed LPIPS linear heads do not match the calibration"
        )
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
        raise EvidenceError(
            "the pinned LPIPS SqueezeNet backbone is unavailable"
        ) from error
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
            raise EvidenceError(
                f"render scoring package {package} is not the pinned version"
            )
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
            raise EvidenceError(
                "the LPIPS calibration could not be loaded safely"
            ) from error
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
    candidate_tensor = (
        torch.from_numpy(numpy.ascontiguousarray(candidate.transpose(2, 0, 1)))
        .unsqueeze(0)
        .to(device)
    )
    target_tensor = (
        torch.from_numpy(numpy.ascontiguousarray(target.transpose(2, 0, 1)))
        .unsqueeze(0)
        .to(device)
    )
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
        native_decoder["contract"] != "native_coregraphics_imageio_srgb8_v2"
        or native_decoder["mode_version"] != 2
        or native_decoder["msplat_source_commit"]
        != "106499b0a53f82b0c92d013b0861fbebd341b17e"
    ):
        raise EvidenceError("ground-truth preparation native decoder is unsupported")
    for field in ("executable_sha256", "metallib_sha256", "trainer_build_digest"):
        _digest(
            native_decoder[field], f"ground-truth preparation.native_decoder.{field}"
        )
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
            raise EvidenceError(
                "ground-truth preparation views are not in holdout order"
            )
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
                raise EvidenceError(
                    "ground-truth preparation image paths must be unique"
                )
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
            _exact_keys(
                camera, {"model", "width", "height", "parameters"}, f"{label}.{kind}"
            )
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
                or camera["width"]
                != image_records["source" if kind == "source_camera" else "target"][
                    "width"
                ]
                or camera["height"]
                != image_records["source" if kind == "source_camera" else "target"][
                    "height"
                ]
            ):
                raise EvidenceError(f"{label}.{kind} is invalid")
            return camera

        source_camera = camera_record("source_camera")
        target_camera = camera_record("target_camera")
        if target_camera["model"] != "PINHOLE":
            raise EvidenceError(
                "ground-truth preparation target camera must be PINHOLE"
            )
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
                raise EvidenceError(
                    f"{label}.source radial coefficient is outside Float32"
                ) from error
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
    manifest = _mapping(
        _load_bounded_json(manifest_path, "rendering manifest"), "rendering manifest"
    )
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
        raise EvidenceError(
            "held-out views must be excluded from the training selection"
        )

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
    if (
        not isinstance(render_operations, list)
        or len(render_operations) != expected_render_operation_count
    ):
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
            raise EvidenceError(
                "render operations are not in canonical source-major order"
            )
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
        view_fields = {
            "holdout_index",
            "camera",
            "camera_digest",
            "ground_truth",
            "renders",
        }
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
        if (
            view["holdout_index"] != holdout_index
            or reference_view["holdout_index"] != holdout_index
        ):
            raise EvidenceError(
                "rendering views must be ordered by bound holdout index"
            )
        camera = _render_camera(
            view["camera"], f"rendering manifest.views[{position}].camera"
        )
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
            raise EvidenceError(
                "render camera does not match the pinned holdout camera"
            )
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
            raise EvidenceError(
                "ground-truth image is not bound to the requested input"
            )
        if (
            ground_truth["path"] != preparation_view["target"]["path"]
            or ground_truth["sha256"] != preparation_view["target"]["sha256"]
            or ground_truth["source_path"] != preparation_view["source"]["path"]
            or ground_truth["source_sha256"] != preparation_view["source"]["sha256"]
            or ground_truth["preparation_view_sha256"]
            != preparation_view["preparation_view_sha256"]
        ):
            raise EvidenceError(
                "ground-truth image does not match its preparation receipt"
            )
        ground_truth_relative = _render_relative_path(
            ground_truth["path"],
            f"rendering manifest.views[{position}].ground_truth.path",
        )
        if ground_truth_relative in image_paths:
            raise EvidenceError("rendering image paths must be unique")
        image_paths.add(ground_truth_relative)
        _digest(ground_truth["sha256"], "ground-truth image digest")
        if ground_truth["sha256"] != reference_view["ground_truth_sha256"]:
            raise EvidenceError(
                "ground-truth image digest does not match its pinned reference"
            )
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
        if not isinstance(render_records, list) or len(render_records) != len(
            RENDER_VARIANTS
        ):
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
            if render["source_run_id"] != source.get("run_id") or render_operation[
                "source_run_id"
            ] != source.get("run_id"):
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
                raise EvidenceError(
                    f"{variant} render is not bound to its camera and source PLY"
                )
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
                or render_operation["renderer_executable_sha256"]
                != renderer_executable_sha256
                or render_operation["source_run_id"] != source.get("run_id")
                or render_operation["source_checkout_commit"]
                != source.get("checkout_commit")
                or render_operation["source_toolchain_identity"]
                != source.get("toolchain_identity")
                or render_operation["source_executable_sha256"]
                != source.get("executable_sha256")
                or render_operation["input_ply_sha256"] != source.get("output_sha256")
                or render_operation["camera_digest"] != camera_digest
                or render_operation["output_sha256"] != descriptor["sha256"]
            ):
                raise EvidenceError(f"{variant} render operation receipt is invalid")
            artifacts[f"render_{variant}_{holdout_index:06d}"] = descriptor
            measured[variant] = _pixel_metrics(
                pixels, ground_truth_pixels, lpips_distance
            )

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
    published = [
        receipt for receipt in receipts if receipt.get("published_output") is True
    ]
    if len(published) != 1:
        raise EvidenceError(
            "candidate_balanced must bind the sole published output receipt"
        )

    selected: dict[str, Mapping[str, Any]] = {}
    for render_variant, (phase, execution_variant) in source_specs.items():
        matching = [
            receipt
            for receipt in receipts
            if receipt.get("phase") == phase
            and receipt.get("variant") == execution_variant
        ]
        if not matching:
            raise EvidenceError(
                f"{render_variant} source execution receipt is unavailable"
            )
        if render_variant == "candidate_balanced":
            source = published[0]
            if source not in matching:
                raise EvidenceError(
                    "candidate_balanced must bind the sole published output receipt"
                )
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
                    if (
                        len(fields) != 3
                        or fields[2] != "1.0"
                        or format_name is not None
                    ):
                        raise EvidenceError("output_ply format declaration is invalid")
                    format_name = fields[1]
                elif fields[0] == "element":
                    if len(fields) != 3:
                        raise EvidenceError("output_ply element declaration is invalid")
                    try:
                        count = int(fields[2])
                    except ValueError as error:
                        raise EvidenceError(
                            "output_ply element count is invalid"
                        ) from error
                    if count < 0:
                        raise EvidenceError("output_ply element count is invalid")
                    active_element = fields[1]
                    if active_element == "vertex":
                        if vertex_count is not None:
                            raise EvidenceError(
                                "output_ply declares vertex more than once"
                            )
                        vertex_count = count
                    else:
                        other_element_count += count
                elif fields[0] == "property":
                    if active_element != "vertex":
                        continue
                    if len(fields) != 3 or fields[1] == "list":
                        raise EvidenceError(
                            "output_ply has an unsupported vertex property"
                        )
                    property_type = fields[1].lower()
                    property_name = fields[2].lower()
                    if property_type not in scalar_types or any(
                        name == property_name for name, _ in vertex_properties
                    ):
                        raise EvidenceError("output_ply has an invalid vertex property")
                    vertex_properties.append((property_name, property_type))
                else:
                    raise EvidenceError(
                        "output_ply header contains an unsupported declaration"
                    )

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
                raise EvidenceError(
                    "output_ply is missing Gaussian properties: " + ", ".join(missing)
                )

            if format_name == "ascii":
                try:
                    body = handle.read().decode("ascii")
                except UnicodeDecodeError as error:
                    raise EvidenceError("output_ply ASCII body is invalid") from error
                rows = [line for line in body.splitlines() if line.strip()]
                if len(rows) != vertex_count:
                    raise EvidenceError(
                        "output_ply ASCII vertex count does not match its body"
                    )
                for row in rows:
                    values = row.split()
                    if len(values) != len(vertex_properties):
                        raise EvidenceError("output_ply ASCII vertex stride is invalid")
                    for value, (_, property_type) in zip(
                        values, vertex_properties, strict=True
                    ):
                        code, is_float = scalar_types[property_type]
                        try:
                            number = float(value) if is_float else int(value, 10)
                        except ValueError as error:
                            raise EvidenceError(
                                "output_ply contains an invalid numeric value"
                            ) from error
                        if is_float and not math.isfinite(number):
                            raise EvidenceError("output_ply contains a nonfinite value")
                        if not is_float:
                            try:
                                struct.pack("<" + code, number)
                            except struct.error as error:
                                raise EvidenceError(
                                    "output_ply integer value is out of range"
                                ) from error
            else:
                record = struct.Struct(
                    "<"
                    + "".join(scalar_types[kind][0] for _, kind in vertex_properties)
                )
                expected_size = body_offset + record.size * vertex_count
                if size != expected_size:
                    raise EvidenceError(
                        "output_ply binary payload size does not match its header"
                    )
                floating_indices = [
                    index
                    for index, (_, kind) in enumerate(vertex_properties)
                    if scalar_types[kind][1]
                ]
                with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                    body = memoryview(mapped)[body_offset:]
                    try:
                        for values in record.iter_unpack(body):
                            if any(
                                not math.isfinite(values[index])
                                for index in floating_indices
                            ):
                                raise EvidenceError(
                                    "output_ply contains a nonfinite value"
                                )
                    finally:
                        body.release()
    except OSError as error:
        raise EvidenceError("output_ply could not be read") from error
    return vertex_count


def _exact_keys_with_optional(
    value: Mapping[str, Any],
    required: Iterable[str],
    optional: Iterable[str],
    label: str,
) -> None:
    required_set = set(required)
    allowed_set = required_set | set(optional)
    missing = sorted(required_set - set(value))
    extra = sorted(set(value) - allowed_set)
    if missing or extra:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unknown " + ", ".join(extra))
        raise EvidenceError(f"{label} has invalid fields: {'; '.join(details)}")


def _shipping_training_uint(
    value: Any,
    label: str,
    *,
    maximum: int = (1 << 64) - 1,
) -> int:
    if type(value) is not int or not 0 <= value <= maximum:
        raise EvidenceError(f"{label} must be an unsigned integer")
    return value


def _shipping_training_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise EvidenceError(f"{label} is not a SHA-256 digest")
    return value


def _validate_training_dataset_derivation(
    value: Any,
    *,
    input_digest: str,
    geometry_digest: str,
) -> None:
    derivation = _mapping(value, "training manifest datasetDerivation")
    _exact_keys(
        derivation,
        {
            "schemaVersion",
            "sourceGeometryManifestSHA256",
            "sourceSelectedFramesDigest",
            "preparationKind",
            "maximumImageDimension",
            "toolchainVersion",
            "colmapProvenance",
            "registeredImageNames",
            "datasetInputDigest",
            "datasetGeometryDigest",
        },
        "training manifest datasetDerivation",
    )
    if type(derivation["schemaVersion"]) is not int or derivation["schemaVersion"] != 1:
        raise EvidenceError("training manifest datasetDerivation is not schema 1")
    for field in (
        "sourceGeometryManifestSHA256",
        "sourceSelectedFramesDigest",
        "datasetInputDigest",
        "datasetGeometryDigest",
    ):
        _shipping_training_digest(
            derivation[field],
            f"training manifest datasetDerivation {field}",
        )
    if not isinstance(derivation["preparationKind"], str) or derivation[
        "preparationKind"
    ] not in {"direct", "undistorted"}:
        raise EvidenceError("training manifest dataset preparation kind is invalid")
    maximum_dimension = derivation["maximumImageDimension"]
    if type(maximum_dimension) is not int or not 0 < maximum_dimension <= (1 << 63) - 1:
        raise EvidenceError(
            "training manifest dataset maximum image dimension is invalid"
        )
    toolchain_version = derivation["toolchainVersion"]
    if not isinstance(toolchain_version, str) or not toolchain_version.strip():
        raise EvidenceError("training manifest dataset toolchain version is invalid")

    provenance = _mapping(
        derivation["colmapProvenance"],
        "training manifest datasetDerivation colmapProvenance",
    )
    _exact_keys(
        provenance,
        {"identifier", "version", "revision", "payloadSHA256"},
        "training manifest datasetDerivation colmapProvenance",
    )
    if provenance["identifier"] != "colmap":
        raise EvidenceError("training manifest dataset COLMAP identifier is invalid")
    for field in ("version", "revision"):
        if not isinstance(provenance[field], str) or not provenance[field].strip():
            raise EvidenceError(f"training manifest dataset COLMAP {field} is invalid")
    _shipping_training_digest(
        provenance["payloadSHA256"],
        "training manifest dataset COLMAP payload digest",
    )

    image_names = derivation["registeredImageNames"]
    if (
        not isinstance(image_names, list)
        or not image_names
        or any(not isinstance(name, str) for name in image_names)
        or len(image_names) != len(set(image_names))
    ):
        raise EvidenceError("training manifest registered image names are invalid")
    for name in image_names:
        path = PurePosixPath(name)
        if (
            not name
            or name in {".", ".."}
            or path.name != name
            or path.suffix.lower() not in {".jpg", ".jpeg", ".png"}
        ):
            raise EvidenceError("training manifest registered image name is unsafe")
    if derivation["datasetInputDigest"] != input_digest:
        raise EvidenceError("training manifest dataset input digest is inconsistent")
    if derivation["datasetGeometryDigest"] != geometry_digest:
        raise EvidenceError("training manifest dataset geometry digest is inconsistent")


def _training_scaled_bytes(value: int, numerator: int, denominator: int) -> int:
    return (value // denominator) * numerator + (
        value % denominator
    ) * numerator // denominator


def _validate_training_resource_admission(
    value: Any,
    *,
    memory_budget_bytes: int,
    candidate_configuration: Mapping[str, Any],
) -> None:
    label = "training manifest resource admission"
    admission = _mapping(value, label)
    _exact_keys_with_optional(
        admission,
        {
            "schema_version",
            "observation",
            "resource_policy",
            "policy_headroom_bytes",
            "policy_capacity_bytes",
            "host_headroom_bytes",
            "host_capacity_bytes",
            "allowed_trainer_bytes",
        },
        {"metal_headroom_bytes", "metal_capacity_bytes"},
        label,
    )
    if type(admission["schema_version"]) is not int or admission["schema_version"] != 2:
        raise EvidenceError("training manifest resource admission is not schema-2")

    observation = _mapping(
        admission["observation"],
        "training manifest resource observation",
    )
    _exact_keys_with_optional(
        observation,
        {
            "clock",
            "installed_memory_bytes",
            "available_host_memory_bytes",
            "available_host_memory_source",
            "host_pages",
            "memory_pressure",
            "memory_pressure_source",
        },
        {
            "kernel_available_memory_percentage",
            "metal_recommended_working_set_bytes",
            "metal_current_allocated_bytes",
        },
        "training manifest resource observation",
    )
    clock = _mapping(
        observation["clock"],
        "training manifest resource clock",
    )
    _exact_keys(
        clock,
        {
            "wall_clock",
            "monotonic_ticks",
            "mach_timebase_numerator",
            "mach_timebase_denominator",
            "boot_time_seconds",
            "boot_time_microseconds",
        },
        "training manifest resource clock",
    )
    wall_clock = clock["wall_clock"]
    try:
        wall_clock_is_finite = (
            not isinstance(wall_clock, bool)
            and isinstance(wall_clock, (int, float))
            and math.isfinite(wall_clock)
        )
    except OverflowError:
        wall_clock_is_finite = False
    if not wall_clock_is_finite:
        raise EvidenceError("training manifest resource admission clock is invalid")
    if (
        _shipping_training_uint(
            clock["monotonic_ticks"],
            "training manifest resource admission monotonic ticks",
        )
        == 0
    ):
        raise EvidenceError("training manifest resource admission clock is invalid")
    for field in ("mach_timebase_numerator", "mach_timebase_denominator"):
        if (
            _shipping_training_uint(
                clock[field],
                f"training manifest resource admission {field}",
                maximum=(1 << 32) - 1,
            )
            == 0
        ):
            raise EvidenceError("training manifest resource admission clock is invalid")
    boot_seconds = clock["boot_time_seconds"]
    boot_microseconds = clock["boot_time_microseconds"]
    if (
        type(boot_seconds) is not int
        or not 0 < boot_seconds <= (1 << 63) - 1
        or type(boot_microseconds) is not int
        or not 0 <= boot_microseconds < 1_000_000
    ):
        raise EvidenceError("training manifest resource admission clock is invalid")

    installed_bytes = _shipping_training_uint(
        observation["installed_memory_bytes"],
        "training manifest resource admission installed memory",
    )
    available_bytes = _shipping_training_uint(
        observation["available_host_memory_bytes"],
        "training manifest resource admission available host memory",
    )
    if installed_bytes == 0 or available_bytes > installed_bytes:
        raise EvidenceError(
            "training manifest resource admission memory evidence is invalid"
        )

    pages = _mapping(
        observation["host_pages"],
        "training manifest resource host pages",
    )
    page_fields = {
        "page_size_bytes",
        "free_page_count",
        "inactive_page_count",
        "speculative_page_count",
        "purgeable_page_count",
        "compressed_page_count",
    }
    _exact_keys(pages, page_fields, "training manifest resource host pages")
    page_values = {
        field: _shipping_training_uint(
            pages[field],
            f"training manifest resource admission host pages {field}",
        )
        for field in page_fields
    }
    page_size = page_values["page_size_bytes"]
    if (
        page_size == 0
        or page_values["speculative_page_count"] > page_values["free_page_count"]
    ):
        raise EvidenceError(
            "training manifest resource admission host page evidence is invalid"
        )
    free_and_inactive = (
        page_values["free_page_count"] + page_values["inactive_page_count"]
    )
    if free_and_inactive > (1 << 64) - 1:
        raise EvidenceError(
            "training manifest resource admission host page evidence is invalid"
        )
    fallback_bytes = free_and_inactive * page_size
    if fallback_bytes > (1 << 64) - 1 or fallback_bytes > installed_bytes:
        raise EvidenceError(
            "training manifest resource admission host page evidence is invalid"
        )
    for field in (
        "speculative_page_count",
        "purgeable_page_count",
        "compressed_page_count",
    ):
        evidence_bytes = page_values[field] * page_size
        if evidence_bytes > (1 << 64) - 1 or evidence_bytes > installed_bytes:
            raise EvidenceError(
                "training manifest resource admission host page evidence is invalid"
            )

    available_source = observation["available_host_memory_source"]
    percentage = observation.get("kernel_available_memory_percentage")
    if available_source == "kernel_memorystatus_percentage":
        percentage = _shipping_training_uint(
            percentage,
            "training manifest resource admission kernel memory percentage",
            maximum=(1 << 32) - 1,
        )
        if percentage > 100:
            raise EvidenceError(
                "training manifest resource admission available host memory is inconsistent"
            )
        expected_available = (installed_bytes // 100) * percentage + (
            installed_bytes % 100
        ) * percentage // 100
    elif available_source == "mach_vm_free_inactive":
        if percentage is not None:
            raise EvidenceError(
                "training manifest resource admission available host memory is inconsistent"
            )
        expected_available = fallback_bytes
    else:
        raise EvidenceError(
            "training manifest resource admission available host memory source is invalid"
        )
    if available_bytes != expected_available:
        raise EvidenceError(
            "training manifest resource admission available host memory is inconsistent"
        )

    pressure = observation["memory_pressure"]
    pressure_source = observation["memory_pressure_source"]
    if not isinstance(pressure, str) or pressure not in {
        "normal",
        "warning",
        "critical",
        "unknown",
    }:
        raise EvidenceError(
            "training manifest resource admission memory pressure is invalid"
        )
    if not isinstance(pressure_source, str):
        raise EvidenceError(
            "training manifest resource admission memory pressure source is invalid"
        )
    if (pressure_source == "kernel_memorystatus" and pressure == "unknown") or (
        pressure_source == "unavailable" and pressure != "unknown"
    ):
        raise EvidenceError(
            "training manifest resource admission memory pressure is inconsistent"
        )
    if pressure_source not in {"kernel_memorystatus", "unavailable"}:
        raise EvidenceError(
            "training manifest resource admission memory pressure source is invalid"
        )

    metal_recommended = observation.get("metal_recommended_working_set_bytes")
    metal_allocated = observation.get("metal_current_allocated_bytes")
    if metal_recommended is None and metal_allocated is None:
        resolved_metal_recommended = None
        resolved_metal_allocated = None
    elif metal_recommended is not None and metal_allocated is not None:
        resolved_metal_recommended = _shipping_training_uint(
            metal_recommended,
            "training manifest resource admission Metal recommendation",
        )
        resolved_metal_allocated = _shipping_training_uint(
            metal_allocated,
            "training manifest resource admission Metal allocation",
        )
        if (
            resolved_metal_recommended == 0
            or resolved_metal_recommended > installed_bytes
            or resolved_metal_allocated > installed_bytes
        ):
            raise EvidenceError(
                "training manifest resource admission Metal evidence is invalid"
            )
    else:
        raise EvidenceError(
            "training manifest resource admission Metal evidence is unpaired"
        )

    requested_policy = admission["resource_policy"]
    if not isinstance(requested_policy, str) or requested_policy not in {
        "automatic",
        "conserveMemory",
        "maximumPerformance",
    }:
        raise EvidenceError("training manifest resource admission policy is invalid")
    expected_policy = {
        "automatic": "automatic",
        "conserve_memory": "conserveMemory",
        "maximum_performance": "maximumPerformance",
    }.get(candidate_configuration.get("resource_policy"))
    if expected_policy is None or requested_policy != expected_policy:
        raise EvidenceError(
            "training manifest resource admission policy does not match request"
        )

    gibibyte = 1_073_741_824
    mebibyte = 1_048_576
    policy_headroom = min(
        installed_bytes,
        max(2 * gibibyte, installed_bytes // 20),
    )
    policy_base = max(0, installed_bytes - policy_headroom)
    effective_policy = requested_policy
    if (
        requested_policy == "maximumPerformance"
        and installed_bytes <= 33 * gibibyte // 2
    ):
        effective_policy = "automatic"
    numerator, denominator = {
        "conserveMemory": (3, 5),
        "automatic": (9, 10),
        "maximumPerformance": (49, 50),
    }[effective_policy]
    policy_capacity = _training_scaled_bytes(policy_base, numerator, denominator)
    if installed_bytes <= 33 * gibibyte // 2:
        policy_capacity = min(policy_capacity, 12 * gibibyte)

    host_headroom = min(
        available_bytes,
        max(2 * gibibyte, installed_bytes // 20),
    )
    unpressured_host_capacity = max(0, available_bytes - host_headroom)
    host_numerator, host_denominator = {
        "normal": (1, 1),
        "warning": (3, 5),
        "critical": (1, 3),
        "unknown": (4, 5),
    }[pressure]
    host_capacity = _training_scaled_bytes(
        unpressured_host_capacity,
        host_numerator,
        host_denominator,
    )

    if resolved_metal_recommended is None:
        metal_headroom = None
        metal_capacity = None
    else:
        metal_headroom = min(
            resolved_metal_recommended,
            max(512 * mebibyte, resolved_metal_recommended // 20),
        )
        unallocated_metal = max(
            0,
            resolved_metal_recommended - resolved_metal_allocated,
        )
        metal_capacity = max(0, unallocated_metal - metal_headroom)
    allowed_trainer_bytes = min(policy_capacity, host_capacity)
    if metal_capacity is not None:
        allowed_trainer_bytes = min(allowed_trainer_bytes, metal_capacity)

    expected_fields = {
        "policy_headroom_bytes": policy_headroom,
        "policy_capacity_bytes": policy_capacity,
        "host_headroom_bytes": host_headroom,
        "host_capacity_bytes": host_capacity,
        "metal_headroom_bytes": metal_headroom,
        "metal_capacity_bytes": metal_capacity,
        "allowed_trainer_bytes": allowed_trainer_bytes,
    }
    for field, expected in expected_fields.items():
        actual = admission.get(field)
        if expected is not None:
            actual = _shipping_training_uint(
                actual,
                f"training manifest resource admission {field}",
            )
        elif actual is not None:
            raise EvidenceError(
                "training manifest resource admission derived capacities are inconsistent"
            )
        if actual != expected:
            raise EvidenceError(
                "training manifest resource admission derived capacities are inconsistent"
            )
    if memory_budget_bytes > allowed_trainer_bytes:
        raise EvidenceError(
            "training manifest memory budget exceeds admitted trainer bytes"
        )


def _validate_training_manifest(
    path: Path,
    output_descriptor: Mapping[str, Any],
    output_splat_count: int,
    pipeline_metrics: Mapping[str, Any],
    candidate_configuration: Mapping[str, Any],
    maximum_training_seconds: float,
    *,
    training_split_path: Path | None = None,
    training_split_descriptor: Mapping[str, Any] | None = None,
    geometry_manifest_descriptor: Mapping[str, Any] | None = None,
    request: Mapping[str, Any] | None = None,
) -> None:
    manifest = _mapping(
        _load_bounded_json(path, "training manifest", maximum_bytes=1024 * 1024),
        "training manifest",
    )
    if "schema_version" in manifest:
        if (
            training_split_path is None
            or training_split_descriptor is None
            or geometry_manifest_descriptor is None
            or request is None
        ):
            raise EvidenceError("measurement training manifest lacks bound artifacts")
        _validate_measurement_training_manifest(
            manifest,
            output_descriptor=output_descriptor,
            output_splat_count=output_splat_count,
            pipeline_metrics=pipeline_metrics,
            candidate_configuration=candidate_configuration,
            maximum_training_seconds=maximum_training_seconds,
            training_split_path=training_split_path,
            training_split_descriptor=training_split_descriptor,
            geometry_manifest_descriptor=geometry_manifest_descriptor,
            request=request,
        )
        return
    if (
        manifest.get("schemaVersion") != 7
        or manifest.get("completionStatus") != "completed"
    ):
        raise EvidenceError("training manifest is not a completed schema-7 artifact")
    _exact_keys_with_optional(
        manifest,
        {
            "schemaVersion",
            "trainerVersion",
            "runtimeVersion",
            "trainerBuildDigest",
            "inputDigest",
            "geometryDigest",
            "datasetDerivation",
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
            "resourceAdmission",
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
        {"checkpointPath", "checkpointDigest"},
        "training manifest",
    )
    if (
        manifest.get("checkpointPath") is not None
        or manifest.get("checkpointDigest") is not None
    ):
        raise EvidenceError("completed training manifest contains checkpoint evidence")
    if manifest["runtimeVersion"] != "native-metal-cli-v2":
        raise EvidenceError("training manifest runtime contract is unsupported")
    if not isinstance(manifest["detailProfile"], str) or manifest[
        "detailProfile"
    ] not in {"fast", "balanced", "highDetail"}:
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
            raise EvidenceError(
                f"training manifest {name} must be a nonnegative integer"
            )
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
            raise EvidenceError(
                f"training manifest {name} must be finite and nonnegative"
            )
    if manifest["rasterPeakExactIntersectionCapacity"] > (1 << 32) - 1:
        raise EvidenceError("training manifest raster peak capacity exceeds UInt32")
    if (
        manifest["rasterExactBufferBytesAdded"]
        > manifest["rasterExactBufferGrowthCount"] * manifest["memoryBudgetBytes"]
    ):
        raise EvidenceError(
            "training manifest raster allocation evidence exceeds its budget"
        )
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
        raise EvidenceError(
            "training manifest zero raster fallbacks have recovery evidence"
        )
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
        raise EvidenceError(
            "training manifest zero raster growth has allocation evidence"
        )
    if manifest["rasterExactBufferGrowthCount"] > 0 and (
        manifest["rasterExactBufferBytesAdded"] == 0
        or manifest["rasterPeakExactIntersectionCapacity"] <= 2_048
    ):
        raise EvidenceError("training manifest raster growth evidence is invalid")
    if manifest["outputBytes"] != output_descriptor["bytes"]:
        raise EvidenceError("training manifest output size does not match output_ply")
    if manifest["gaussianCount"] != output_splat_count:
        raise EvidenceError(
            "training manifest Gaussian count does not match output_ply"
        )
    if manifest["droppedIntersectionCount"] != 0:
        raise EvidenceError("training manifest reports dropped raster intersections")
    if (
        manifest["rasterExactFallbackElapsedSeconds"] > manifest["elapsedSeconds"]
        or manifest["rasterReplayElapsedSeconds"] > manifest["elapsedSeconds"]
    ):
        raise EvidenceError(
            "training manifest raster elapsed time exceeds training time"
        )
    if manifest["elapsedSeconds"] > maximum_training_seconds + 1e-6:
        raise EvidenceError(
            "training manifest elapsed time exceeds its published timing run"
        )
    for name in ("trainerBuildDigest", "inputDigest", "geometryDigest"):
        digest = manifest[name]
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise EvidenceError(f"training manifest {name} is not a SHA-256 digest")
    _validate_training_dataset_derivation(
        manifest["datasetDerivation"],
        input_digest=manifest["inputDigest"],
        geometry_digest=manifest["geometryDigest"],
    )
    _validate_training_resource_admission(
        manifest["resourceAdmission"],
        memory_budget_bytes=manifest["memoryBudgetBytes"],
        candidate_configuration=candidate_configuration,
    )
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


def _validate_measurement_training_manifest(
    manifest: Mapping[str, Any],
    *,
    output_descriptor: Mapping[str, Any],
    output_splat_count: int,
    pipeline_metrics: Mapping[str, Any],
    candidate_configuration: Mapping[str, Any],
    maximum_training_seconds: float,
    training_split_path: Path,
    training_split_descriptor: Mapping[str, Any],
    geometry_manifest_descriptor: Mapping[str, Any],
    request: Mapping[str, Any],
) -> None:
    _exact_keys(
        manifest,
        {
            "schema_version",
            "training_split_digest",
            "training_split_manifest_sha256",
            "training_image_digest",
            "dataset_input_digest",
            "dataset_geometry_digest",
            "source_model_digest",
            "filtered_model_digest",
            "geometry_manifest_sha256",
            "output_sha256",
            "output_bytes",
            "profile",
            "seed",
            "iteration_limit",
            "plateau_window",
            "completed_iteration",
            "gaussian_count",
            "elapsed_seconds",
            "input_digest",
            "geometry_digest",
            "trainer_build_digest",
            "completion_status",
            "training_split_manifest",
            "peak_memory_bytes",
            "memory_budget_bytes",
            "raster_fallback_count",
            "raster_exact_fallback_elapsed_seconds",
            "raster_exact_buffer_growth_count",
            "raster_exact_buffer_bytes_added",
            "raster_replay_elapsed_seconds",
            "raster_peak_exact_intersection_capacity",
            "dropped_intersection_count",
            "scene_bounds",
        },
        "measurement training manifest",
    )
    if manifest["schema_version"] != 1 or manifest["completion_status"] != "completed":
        raise EvidenceError("measurement training manifest is not completed schema 1")
    if manifest["training_split_manifest"] != "training-split.json":
        raise EvidenceError("measurement training manifest split path is not canonical")

    digest_fields = (
        "training_split_digest",
        "training_split_manifest_sha256",
        "training_image_digest",
        "dataset_input_digest",
        "dataset_geometry_digest",
        "source_model_digest",
        "filtered_model_digest",
        "geometry_manifest_sha256",
        "output_sha256",
        "input_digest",
        "geometry_digest",
        "trainer_build_digest",
    )
    for name in digest_fields:
        value = manifest[name]
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise EvidenceError(f"measurement training manifest {name} is not SHA-256")
    if (
        "sha256:" + manifest["training_split_manifest_sha256"]
        != training_split_descriptor["sha256"]
    ):
        raise EvidenceError("measurement training manifest split digest is stale")
    if (
        "sha256:" + manifest["geometry_manifest_sha256"]
        != geometry_manifest_descriptor["sha256"]
    ):
        raise EvidenceError(
            "measurement training manifest geometry model was substituted"
        )
    if "sha256:" + manifest["output_sha256"] != output_descriptor["sha256"]:
        raise EvidenceError("measurement training manifest PLY was substituted")

    split = _mapping(
        _load_bounded_json(
            training_split_path, "training split", maximum_bytes=1024 * 1024
        ),
        "training split",
    )
    _exact_keys(
        split,
        {
            "schema_version",
            "selected_image_names",
            "training_view_indices",
            "holdout_view_indices",
            "training_image_names",
            "holdout_image_names",
            "dataset_image_names",
            "training_image_digest",
            "closure_digest",
        },
        "training split",
    )
    if split["schema_version"] != 1:
        raise EvidenceError("training split schema is unsupported")
    scale = request["binding"]["scale"]
    selected = split["selected_image_names"]
    training_indices = split["training_view_indices"]
    holdout_indices = split["holdout_view_indices"]
    training_names = split["training_image_names"]
    holdout_names = split["holdout_image_names"]
    dataset_names = split["dataset_image_names"]
    arrays = (
        selected,
        training_indices,
        holdout_indices,
        training_names,
        holdout_names,
        dataset_names,
    )
    if any(not isinstance(value, list) for value in arrays):
        raise EvidenceError("training split arrays are invalid")
    if (
        len(selected) != scale
        or len(set(selected)) != len(selected)
        or any(not isinstance(name, str) or not name for name in selected)
    ):
        raise EvidenceError("training split selected image order is invalid")
    expected_holdouts = request["holdout_indices"]
    expected_training = [
        index for index in range(scale) if index not in set(expected_holdouts)
    ]
    if holdout_indices != expected_holdouts or training_indices != expected_training:
        raise EvidenceError("training split does not match the bound holdouts")
    if training_names != [selected[index] for index in expected_training]:
        raise EvidenceError("training split training image order was substituted")
    if holdout_names != [selected[index] for index in expected_holdouts]:
        raise EvidenceError("training split holdout image order was substituted")
    if dataset_names != training_names:
        raise EvidenceError(
            "training dataset contains a holdout or changed image order"
        )
    if set(training_names).intersection(holdout_names):
        raise EvidenceError("training and holdout image sets overlap")
    if split["training_image_digest"] != manifest["training_image_digest"]:
        raise EvidenceError("measurement training image digest is stale")

    unsigned_split = {
        key: split[key]
        for key in (
            "schema_version",
            "selected_image_names",
            "training_view_indices",
            "holdout_view_indices",
            "training_image_names",
            "holdout_image_names",
            "dataset_image_names",
            "training_image_digest",
        )
    }
    closure_digest = hashlib.sha256(canonical_json_bytes(unsigned_split)).hexdigest()
    if (
        split["closure_digest"] != closure_digest
        or manifest["training_split_digest"] != closure_digest
    ):
        raise EvidenceError("training split closure digest is stale")

    expected_profile = candidate_configuration["detail_profile"]
    if manifest["profile"] != expected_profile:
        raise EvidenceError("measurement training profile does not match request")
    expected_contract = {
        "iteration_limit": candidate_configuration["trainer_iterations"],
        "plateau_window": candidate_configuration["trainer_plateau_window"],
        "seed": candidate_configuration["run_seed"],
    }
    for name, expected in expected_contract.items():
        if manifest[name] != expected:
            raise EvidenceError(f"measurement training {name} does not match request")
    integer_fields = (
        "iteration_limit",
        "plateau_window",
        "completed_iteration",
        "gaussian_count",
        "output_bytes",
        "peak_memory_bytes",
        "memory_budget_bytes",
        "raster_fallback_count",
        "raster_exact_buffer_growth_count",
        "raster_exact_buffer_bytes_added",
        "raster_peak_exact_intersection_capacity",
        "dropped_intersection_count",
    )
    for name in integer_fields:
        value = manifest[name]
        if type(value) is not int or not 0 <= value <= (1 << 63) - 1:
            raise EvidenceError(
                f"measurement training {name} must be a nonnegative integer"
            )
    if not 0 < manifest["completed_iteration"] <= manifest["iteration_limit"]:
        raise EvidenceError("measurement training completion iteration is invalid")
    if (
        manifest["plateau_window"] == 0
        or manifest["plateau_window"] > manifest["iteration_limit"]
    ):
        raise EvidenceError("measurement training plateau window is invalid")
    if (
        manifest["output_bytes"] != output_descriptor["bytes"]
        or manifest["gaussian_count"] != output_splat_count
    ):
        raise EvidenceError("measurement training output identity is invalid")
    if manifest["peak_memory_bytes"] == 0 or manifest["memory_budget_bytes"] == 0:
        raise EvidenceError("measurement training memory evidence is invalid")
    if manifest["dropped_intersection_count"] != 0:
        raise EvidenceError("measurement training reports dropped intersections")

    for name in (
        "elapsed_seconds",
        "raster_exact_fallback_elapsed_seconds",
        "raster_replay_elapsed_seconds",
    ):
        value = manifest[name]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value < 0
        ):
            raise EvidenceError(
                f"measurement training {name} must be finite and nonnegative"
            )
    if manifest["elapsed_seconds"] > maximum_training_seconds + 1e-6:
        raise EvidenceError(
            "measurement training elapsed time exceeds its published timing run"
        )
    if (
        manifest["raster_exact_fallback_elapsed_seconds"] > manifest["elapsed_seconds"]
        or manifest["raster_replay_elapsed_seconds"] > manifest["elapsed_seconds"]
    ):
        raise EvidenceError("measurement training raster time exceeds training time")
    manifest_to_pipeline = {
        "raster_fallback_count": "raster_fallback_count",
        "raster_exact_fallback_elapsed_seconds": "raster_exact_fallback_elapsed_seconds",
        "raster_exact_buffer_growth_count": "raster_exact_buffer_growth_count",
        "raster_exact_buffer_bytes_added": "raster_exact_buffer_bytes_added",
        "raster_replay_elapsed_seconds": "raster_replay_elapsed_seconds",
        "raster_peak_exact_intersection_capacity": "raster_peak_exact_intersection_capacity",
        "dropped_intersection_count": "dropped_intersection_count",
    }
    for receipt_name, pipeline_name in manifest_to_pipeline.items():
        if manifest[receipt_name] != pipeline_metrics.get(pipeline_name):
            raise EvidenceError(
                f"measurement training {receipt_name} does not match pipeline metrics"
            )
    bounds = _mapping(manifest["scene_bounds"], "measurement training scene_bounds")
    _exact_keys(bounds, {"center", "radius"}, "measurement training scene_bounds")
    center = _mapping(bounds["center"], "measurement training scene center")
    _exact_keys(center, {"x", "y", "z"}, "measurement training scene center")
    coordinates = [center[axis] for axis in ("x", "y", "z")]
    if any(
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        for value in coordinates
    ):
        raise EvidenceError("measurement training scene center is invalid")
    radius = bounds["radius"]
    if (
        isinstance(radius, bool)
        or not isinstance(radius, (int, float))
        or not math.isfinite(radius)
        or radius <= 0
    ):
        raise EvidenceError("measurement training scene radius is invalid")


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


@dataclass(frozen=True)
class SelectionManifestSources:
    image_names: tuple[str, ...]
    clip_ids: tuple[str, ...]
    source_kinds: tuple[str, ...]
    video_source_count: int


def _validate_selection_manifest_sources(
    selection_manifest_path: Path,
    *,
    requested_scale: int,
    input_kind: str,
    expected_video_source_count: int,
) -> SelectionManifestSources:
    """Validate selected-view source identity.

    In selection schema 2, ``clip_id`` identifies one original input source. It
    must stay stable across every selected view from that source; decode chunks
    and analysis segments do not receive new IDs. Cross-checking the distinct
    video IDs with worker evidence prevents either splitting or merging inputs.
    """
    selection = _mapping(
        _load_bounded_json(selection_manifest_path, "selection_manifest"),
        "selection_manifest",
    )
    _exact_keys(selection, {"schema_version", "views"}, "selection_manifest")
    if selection["schema_version"] != 2:
        raise EvidenceError("selection_manifest schema is unsupported")
    raw_views = selection["views"]
    if not isinstance(raw_views, list) or len(raw_views) != requested_scale:
        raise EvidenceError(
            f"selection_manifest must cover the requested scale {requested_scale}"
        )

    clip_ids: list[str] = []
    image_names: list[str] = []
    source_kinds: list[str] = []
    clip_source_kinds: dict[str, str] = {}
    for index, raw_view in enumerate(raw_views):
        view = _mapping(raw_view, f"selection_manifest.views[{index}]")
        _exact_keys(
            view,
            {"view_index", "image_name", "clip_id", "source_kind"},
            f"selection_manifest.views[{index}]",
        )
        if view["view_index"] != index:
            raise EvidenceError("selection_manifest view indices must be contiguous")
        image_name = view["image_name"]
        if (
            not isinstance(image_name, str)
            or not image_name
            or len(image_name.encode("utf-8")) > 255
            or any(character.isspace() for character in image_name)
            or "/" in image_name
            or "\\" in image_name
            or image_name in {".", ".."}
        ):
            raise EvidenceError("selection_manifest image name is invalid")
        clip_id = _token(
            view["clip_id"],
            f"selection_manifest.views[{index}].clip_id",
        )
        source_kind = view["source_kind"]
        if source_kind not in {"video", "photo"}:
            raise EvidenceError("selection_manifest source kind is invalid")
        prior_source_kind = clip_source_kinds.setdefault(clip_id, source_kind)
        if prior_source_kind != source_kind:
            raise EvidenceError(
                "selection_manifest clip IDs cannot span multiple source kinds"
            )
        image_names.append(image_name)
        clip_ids.append(clip_id)
        source_kinds.append(source_kind)
    if len(set(image_names)) != len(image_names):
        raise EvidenceError("selection_manifest image names must be unique")

    represented_source_kinds = set(source_kinds)
    allowed_source_kind_sets = {
        "video": ({"video"},),
        "multi_video": ({"video"},),
        "photos": ({"photo"},),
        "mixed": ({"video"}, {"video", "photo"}),
    }.get(input_kind)
    if (
        allowed_source_kind_sets is None
        or represented_source_kinds not in allowed_source_kind_sets
    ):
        raise EvidenceError(
            "selection_manifest source representation does not match the input kind"
        )
    video_source_count = len(
        {
            clip_id
            for clip_id, source_kind in zip(clip_ids, source_kinds, strict=True)
            if source_kind == "video"
        }
    )
    if video_source_count != expected_video_source_count:
        raise EvidenceError(
            "selection_manifest video source count does not match the protected request"
        )
    return SelectionManifestSources(
        image_names=tuple(image_names),
        clip_ids=tuple(clip_ids),
        source_kinds=tuple(source_kinds),
        video_source_count=video_source_count,
    )


def _validate_pair_list(
    pair_list_path: Path,
    requested_scale: int,
    selection: SelectionManifestSources,
    candidate_configuration: Mapping[str, Any],
    pipeline_metrics: Mapping[str, Any],
    *,
    requires_cross_clip_retrieval: bool | None = None,
) -> str:
    image_names = list(selection.image_names)
    clip_ids = list(selection.clip_ids)
    source_kinds = list(selection.source_kinds)

    pair_list = _mapping(_load_bounded_json(pair_list_path, "pair_list"), "pair_list")
    _exact_keys(
        pair_list,
        {
            "schema_version",
            "selected_frame_count",
            "accepted_attempt_number",
            "pairs",
            "attempts",
            "fallback_reasons",
        },
        "pair_list",
    )
    if (
        pair_list["schema_version"] != 5
        or pair_list["selected_frame_count"] != requested_scale
    ):
        raise EvidenceError("pair_list does not match the bound selected frame count")

    topology = candidate_configuration["input_topology"]
    pairing_policy = candidate_configuration["pairing_policy"]
    normal_offsets = set(candidate_configuration["temporal_offsets"])
    views_by_clip: dict[str, list[int]] = {}
    source_kind_by_clip: dict[str, str] = {}
    for view_index, (clip_id, source_kind) in enumerate(
        zip(clip_ids, source_kinds, strict=True)
    ):
        views_by_clip.setdefault(clip_id, []).append(view_index)
        source_kind_by_clip[clip_id] = source_kind
    is_video_only_multi_clip = (
        selection.video_source_count > 1
        and len(views_by_clip) == selection.video_source_count
        and all(
            source_kind == "video"
            for source_kind in source_kind_by_clip.values()
        )
    )
    if requires_cross_clip_retrieval is None:
        requires_cross_clip_retrieval = (
            topology in {"continuous", "segmented_mixed"}
            and is_video_only_multi_clip
        )
    elif type(requires_cross_clip_retrieval) is not bool:
        raise EvidenceError("pair_list cross-clip requirement is invalid")
    if requires_cross_clip_retrieval and (
        topology not in {"continuous", "segmented_mixed"}
        or not is_video_only_multi_clip
    ):
        raise EvidenceError(
            "pair_list cross-clip requirement does not match the selected input"
        )
    if topology == "continuous":
        if requires_cross_clip_retrieval:
            if len(views_by_clip) <= 1 or any(
                source_kind != "video" for source_kind in source_kind_by_clip.values()
            ):
                raise EvidenceError(
                    "pair_list cross-clip continuous input must contain video clips"
                )
        elif len(views_by_clip) != 1:
            raise EvidenceError("pair_list continuous input must use one clip")

    def local_edges_for_recovery(recovery_index: int) -> set[tuple[int, int]]:
        if topology not in {"continuous", "segmented_mixed"}:
            return set()
        offsets = set(normal_offsets)
        if recovery_index != 0 and pairing_policy != "segmented_mixed":
            offsets.update(range(1, 13))
        temporal_groups = [
            views
            for clip_id, views in views_by_clip.items()
            if pairing_policy != "segmented_mixed"
            or source_kind_by_clip[clip_id] == "video"
        ]
        return {
            (clip_views[left], clip_views[right])
            for clip_views in temporal_groups
            for left in range(len(clip_views))
            for right in range(left + 1, len(clip_views))
            if right - left in offsets
        }

    candidate_limit = candidate_configuration["vocabulary_candidate_count"]
    neighbor_limit = candidate_configuration["vocabulary_returned_neighbor_count"]
    configured_retrieval = candidate_limit > 0 and neighbor_limit > 0
    if (candidate_limit > 0) != (neighbor_limit > 0):
        raise EvidenceError(
            "pair_list retrieval policy has inconsistent candidate and neighbor limits"
        )
    stride = candidate_configuration["vocabulary_query_stride"]
    distance_minimum = (
        0
        if requires_cross_clip_retrieval or topology != "continuous"
        else max(12, requested_scale // 10)
    )
    expected_query_views = (
        [
            view
            for clip_views in views_by_clip.values()
            for view in clip_views[::stride]
        ]
        if requires_cross_clip_retrieval
        else list(range(0, requested_scale, stride))
    )

    def receipt_digest(fields: list[str]) -> str:
        hasher = hashlib.sha256()
        for field in fields:
            encoded = field.encode("utf-8")
            hasher.update(f"{len(encoded)}:".encode("utf-8"))
            hasher.update(encoded)
        return "sha256:" + hasher.hexdigest()

    raw_attempts = pair_list["attempts"]
    if not isinstance(raw_attempts, list) or not raw_attempts:
        raise EvidenceError("pair_list attempts must be a non-empty list")
    fallback_reasons = pair_list["fallback_reasons"]
    if (
        not isinstance(fallback_reasons, list)
        or len(fallback_reasons) != len(set(fallback_reasons))
        or any(
            not isinstance(reason, str)
            or not reason
            or reason != reason.strip()
            or len(reason.encode("utf-8")) > 512
            for reason in fallback_reasons
        )
    ):
        raise EvidenceError("pair_list fallback reasons are invalid")
    accepted_attempt_number = pair_list["accepted_attempt_number"]
    if type(
        accepted_attempt_number
    ) is not int or not 1 <= accepted_attempt_number <= len(raw_attempts):
        raise EvidenceError("pair_list accepted attempt number is invalid")

    attempt_fields = {
        "attempt_number",
        "matcher_used",
        "exact_recovery_reason",
        "recovery_level",
        "outcome",
        "scheduled_pair_count",
        "attempted_pair_count",
        "raw_matched_pair_count",
        "spatially_verified_pair_count",
        "retrieval",
    }
    retrieval_fields = {
        "engine",
        "query_views",
        "query_stride",
        "candidate_count",
        "returned_neighbor_count",
        "minimum_frame_separation",
        "candidate_policy",
        "image_group_list_digest",
        "executed",
        "query_outcomes",
        "directed_pairs",
        "request_digest",
        "output_digest",
    }
    query_outcome_fields = {"query_view", "status", "ranked_neighbor_views"}
    directed_pair_fields = {"query_view", "target_view"}
    attempts: list[Mapping[str, Any]] = []
    exhaustive_attempts: list[bool] = []
    local_edges_by_attempt: list[set[tuple[int, int]]] = []
    prior_recovery_index = 0
    for index, raw_attempt in enumerate(raw_attempts):
        attempt = _mapping(raw_attempt, f"pair_list.attempts[{index}]")
        _exact_keys(attempt, attempt_fields, f"pair_list.attempts[{index}]")
        counts = [
            attempt["scheduled_pair_count"],
            attempt["attempted_pair_count"],
            attempt["raw_matched_pair_count"],
            attempt["spatially_verified_pair_count"],
        ]
        if (
            attempt["attempt_number"] != index + 1
            or attempt["matcher_used"] not in {"faiss", "exact"}
            or (attempt["matcher_used"] == "exact")
            != _valid_exact_recovery_reason(attempt["exact_recovery_reason"])
            or attempt["recovery_level"] not in {"normal", "expanded", "maximum"}
            or attempt["outcome"] not in {"completed", "rejected", "failed"}
            or any(type(count) is not int or count < 0 for count in counts)
            or not counts[0] >= counts[1] >= counts[2] >= counts[3]
        ):
            raise EvidenceError("pair_list attempt fields or counts are invalid")
        recovery_index = {"normal": 0, "expanded": 1, "maximum": 2}[
            attempt["recovery_level"]
        ]
        maximum_recovery_step = (
            min(2, len(fallback_reasons))
            if index == 0
            else min(2, max(1, len(fallback_reasons)))
        )
        if (
            recovery_index < prior_recovery_index
            or recovery_index - prior_recovery_index > maximum_recovery_step
        ):
            raise EvidenceError("pair_list attempt recovery order is invalid")
        prior_recovery_index = recovery_index

        raw_retrieval = attempt["retrieval"]
        uses_exhaustive = (
            candidate_configuration["pairing_policy"] == "unordered_exhaustive"
            and requested_scale <= 60
        ) or (recovery_index == 2 and requested_scale <= 250)
        attempt_local_edges = local_edges_for_recovery(recovery_index)
        retrieval_is_scheduled = requires_cross_clip_retrieval or (
            pairing_policy == "generic_continuous" and requested_scale >= 120
        ) or pairing_policy in {
            "object_orbit",
            "walkthrough",
            "large_area",
            "segmented_mixed",
            "unordered_retrieval",
        }
        retrieval_is_required = (
            configured_retrieval and retrieval_is_scheduled and not uses_exhaustive
        )
        expected_attempt_schedule_count = (
            requested_scale * (requested_scale - 1) // 2
            if uses_exhaustive
            else len(attempt_local_edges)
        )
        if not retrieval_is_required:
            if raw_retrieval is not None:
                raise EvidenceError(
                    "pair_list records retrieval when disabled or exhaustive pairing is active"
                )
        else:
            retrieval = _mapping(
                raw_retrieval, f"pair_list.attempts[{index}].retrieval"
            )
            _exact_keys(
                retrieval, retrieval_fields, f"pair_list.attempts[{index}].retrieval"
            )
            expected_queries = expected_query_views
            if recovery_index == 0:
                expected_candidate_limit = candidate_limit
                expected_neighbor_limit = neighbor_limit
            elif recovery_index == 1 and pairing_policy in {
                "segmented_mixed",
                "unordered_retrieval",
            }:
                expected_candidate_limit = 40
                expected_neighbor_limit = 16
            elif recovery_index == 2:
                expected_candidate_limit = 80
                expected_neighbor_limit = 32
            else:
                expected_candidate_limit = candidate_limit
                expected_neighbor_limit = neighbor_limit
            if (
                retrieval["engine"] != "localSiftVocabularyV2"
                or retrieval["query_views"] != expected_queries
                or retrieval["query_stride"] != stride
                or retrieval["candidate_count"] != expected_candidate_limit
                or retrieval["returned_neighbor_count"] != expected_neighbor_limit
                or retrieval["minimum_frame_separation"] != distance_minimum
                or type(retrieval["executed"]) is not bool
            ):
                raise EvidenceError("pair_list retrieval request does not match policy")
            expected_group_digest: str | None = None
            if requires_cross_clip_retrieval:
                group_index_by_clip = {
                    clip_id: group_index
                    for group_index, clip_id in enumerate(views_by_clip)
                }
                canonical_group_lines = sorted(
                    (
                        f"{image_names[view_index]}\t{group_index_by_clip[clip_ids[view_index]]}"
                        for view_index in range(requested_scale)
                    ),
                    key=lambda line: line.encode("utf-8"),
                )
                expected_group_digest = receipt_digest(
                    ["crossGroupV1", *canonical_group_lines]
                )
                if (
                    retrieval["candidate_policy"] != "crossGroupV1"
                    or retrieval["image_group_list_digest"]
                    != expected_group_digest
                ):
                    raise EvidenceError(
                        "pair_list cross-clip candidate policy is invalid"
                    )
            elif (
                retrieval["candidate_policy"] is not None
                or retrieval["image_group_list_digest"] is not None
            ):
                raise EvidenceError(
                    "pair_list non-cross-clip retrieval declares a group policy"
                )
            request_digest_fields = [
                retrieval["engine"],
                str(retrieval["query_stride"]),
                str(retrieval["candidate_count"]),
                str(retrieval["returned_neighbor_count"]),
                str(retrieval["minimum_frame_separation"]),
            ]
            if expected_group_digest is not None:
                request_digest_fields.extend(
                    ["crossGroupV1", expected_group_digest.removeprefix("sha256:")]
                )
            expected_request_digest = receipt_digest(
                request_digest_fields
                + [image_names[query] for query in expected_queries]
            )
            if retrieval["request_digest"] != expected_request_digest:
                raise EvidenceError("pair_list retrieval request digest is invalid")
            raw_query_outcomes = retrieval["query_outcomes"]
            if (
                not isinstance(raw_query_outcomes, list)
                or len(raw_query_outcomes) != len(expected_queries)
            ):
                raise EvidenceError("pair_list retrieval query outcomes are invalid")
            query_outcomes: list[Mapping[str, Any]] = []
            expected_directed_pairs: list[dict[str, int]] = []
            seen_retrieval_edges: set[tuple[int, int]] = set()
            for outcome_index, raw_outcome in enumerate(raw_query_outcomes):
                outcome = _mapping(
                    raw_outcome,
                    (
                        f"pair_list.attempts[{index}].retrieval."
                        f"query_outcomes[{outcome_index}]"
                    ),
                )
                _exact_keys(
                    outcome,
                    query_outcome_fields,
                    (
                        f"pair_list.attempts[{index}].retrieval."
                        f"query_outcomes[{outcome_index}]"
                    ),
                )
                query_view = outcome["query_view"]
                neighbors = outcome["ranked_neighbor_views"]
                if (
                    query_view != expected_queries[outcome_index]
                    or outcome["status"] not in {"ranked", "noRankedNeighbors"}
                    or not isinstance(neighbors, list)
                    or len(neighbors) != len(set(neighbors))
                    or any(
                        type(target) is not int
                        or not 0 <= target < requested_scale
                        or target == query_view
                        for target in neighbors
                    )
                    or neighbors
                    != sorted(neighbors, key=lambda target: image_names[target].encode("utf-8"))
                    or (outcome["status"] == "ranked") != bool(neighbors)
                ):
                    raise EvidenceError("pair_list retrieval query outcome is invalid")
                retained_neighbor_count = 0
                for target_view in neighbors:
                    if (
                        requires_cross_clip_retrieval
                        and clip_ids[query_view] == clip_ids[target_view]
                    ):
                        raise EvidenceError(
                            "pair_list cross-clip retrieval retained a same-clip neighbor"
                        )
                    edge = (
                        min(query_view, target_view),
                        max(query_view, target_view),
                    )
                    if edge in attempt_local_edges:
                        raise EvidenceError(
                            "pair_list retrieval outcome contains an excluded base edge"
                        )
                    if abs(query_view - target_view) < distance_minimum:
                        raise EvidenceError(
                            "pair_list retrieval neighbor violates minimum separation"
                        )
                    retained_neighbor_count += 1
                    if retained_neighbor_count > expected_neighbor_limit:
                        raise EvidenceError(
                            "pair_list retrieval retained too many neighbors"
                        )
                    if edge not in seen_retrieval_edges:
                        seen_retrieval_edges.add(edge)
                        expected_directed_pairs.append(
                            {"query_view": query_view, "target_view": target_view}
                        )
                query_outcomes.append(outcome)
            expected_directed_pairs.sort(
                key=lambda pair: (
                    f"{image_names[pair['query_view']]} "
                    f"{image_names[pair['target_view']]}"
                ).encode("utf-8")
            )
            expected_attempt_schedule_count += len(expected_directed_pairs)
            raw_directed_pairs = retrieval["directed_pairs"]
            if not isinstance(raw_directed_pairs, list):
                raise EvidenceError("pair_list retrieval directed pairs are invalid")
            directed_edges: set[tuple[int, int]] = set()
            directed_lines: list[str] = []
            for pair_index, raw_directed_pair in enumerate(raw_directed_pairs):
                directed_pair = _mapping(
                    raw_directed_pair,
                    f"pair_list.attempts[{index}].retrieval.directed_pairs[{pair_index}]",
                )
                _exact_keys(
                    directed_pair,
                    directed_pair_fields,
                    f"pair_list.attempts[{index}].retrieval.directed_pairs[{pair_index}]",
                )
                query_view = directed_pair["query_view"]
                target_view = directed_pair["target_view"]
                if (
                    type(query_view) is not int
                    or type(target_view) is not int
                    or query_view not in expected_queries
                    or not 0 <= target_view < requested_scale
                    or query_view == target_view
                    or (
                        min(query_view, target_view),
                        max(query_view, target_view),
                    )
                    in attempt_local_edges
                    or abs(query_view - target_view) < distance_minimum
                    or (
                        requires_cross_clip_retrieval
                        and clip_ids[query_view] == clip_ids[target_view]
                    )
                    or (query_view, target_view) in directed_edges
                ):
                    raise EvidenceError(
                        "pair_list retrieval directed pair is invalid or duplicated"
                    )
                directed_edges.add((query_view, target_view))
                directed_lines.append(
                    f"{image_names[query_view]} {image_names[target_view]}"
                )
            if raw_directed_pairs != expected_directed_pairs:
                raise EvidenceError(
                    "pair_list retrieval directed pairs do not match ranked outcomes"
                )
            contract_header = [
                (
                    "EASYSPLAT_RETRIEVAL_OUTCOMES_V3"
                    if expected_group_digest is not None
                    else "EASYSPLAT_RETRIEVAL_OUTCOMES_V2"
                ),
                retrieval["engine"],
                str(retrieval["query_stride"]),
                str(retrieval["candidate_count"]),
                str(retrieval["returned_neighbor_count"]),
                str(retrieval["minimum_frame_separation"]),
            ]
            if expected_group_digest is not None:
                contract_header.extend(
                    ["crossGroupV1", expected_group_digest.removeprefix("sha256:")]
                )
            contract_header.extend(
                [
                    str(len(expected_queries)),
                    expected_request_digest.removeprefix("sha256:"),
                ]
            )
            contract_lines = [" ".join(contract_header)]
            contract_lines.extend(
                " ".join(
                    [
                        "Q",
                        outcome["status"],
                        image_names[outcome["query_view"]],
                        str(len(outcome["ranked_neighbor_views"])),
                        *(
                            image_names[target]
                            for target in outcome["ranked_neighbor_views"]
                        ),
                    ]
                )
                for outcome in query_outcomes
            )
            contract_lines.extend(f"P {line}" for line in directed_lines)
            if retrieval["output_digest"] != receipt_digest(contract_lines):
                raise EvidenceError("pair_list retrieval output digest is invalid")
        if attempt["scheduled_pair_count"] != expected_attempt_schedule_count:
            raise EvidenceError(
                "pair_list attempt schedule count does not match its authenticated policy"
            )
        attempts.append(attempt)
        exhaustive_attempts.append(uses_exhaustive)
        local_edges_by_attempt.append(attempt_local_edges)

    for index, attempt in enumerate(attempts[1:], start=1):
        if attempt["matcher_used"] == "exact":
            predecessor = attempts[index - 1]
            current_retrieval = attempt["retrieval"]
            previous_retrieval = predecessor["retrieval"]
            retrieval_identity_matches = (
                current_retrieval is None and previous_retrieval is None
            ) or (
                isinstance(current_retrieval, Mapping)
                and isinstance(previous_retrieval, Mapping)
                and {key: value for key, value in current_retrieval.items() if key != "executed"}
                == {
                    key: value
                    for key, value in previous_retrieval.items()
                    if key != "executed"
                }
                and previous_retrieval["executed"] is True
                and current_retrieval["executed"] is False
            )
            if (
                attempt["scheduled_pair_count"]
                != predecessor["scheduled_pair_count"]
                or not retrieval_identity_matches
            ):
                raise EvidenceError(
                    "pair_list exact recovery changed its authenticated schedule"
                )

    normalized_attempts = [
        {
            "attemptNumber": attempt["attempt_number"],
            "matcher": attempt["matcher_used"],
            "exactRecoveryReason": attempt["exact_recovery_reason"],
            "recoveryLevel": attempt["recovery_level"],
            "outcome": attempt["outcome"],
            "scheduledPairCount": attempt["scheduled_pair_count"],
            "attemptedPairCount": attempt["attempted_pair_count"],
            "rawMatchedPairCount": attempt["raw_matched_pair_count"],
            "spatiallyVerifiedPairCount": attempt["spatially_verified_pair_count"],
            "durationSeconds": 0.0,
        }
        for attempt in attempts
    ]
    _validate_matcher_recovery_history(
        normalized_attempts,
        total_view_count=requested_scale,
        pairing_policy=(
            "unorderedRetrieval"
            if candidate_configuration["pairing_policy"] == "unordered_exhaustive"
            else candidate_configuration["pairing_policy"]
        ),
        fallback_reason_count=len(fallback_reasons),
    )

    accepted_attempt = attempts[accepted_attempt_number - 1]
    accepted_uses_exhaustive = exhaustive_attempts[accepted_attempt_number - 1]
    accepted_local_edges = local_edges_by_attempt[accepted_attempt_number - 1]
    if accepted_attempt["outcome"] != "completed":
        raise EvidenceError("pair_list accepted attempt did not complete")
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
    accepted_retrieval = accepted_attempt["retrieval"]
    accepted_directed_edges = (
        {
            (pair["query_view"], pair["target_view"])
            for pair in accepted_retrieval["directed_pairs"]
        }
        if isinstance(accepted_retrieval, Mapping)
        else set()
    )
    observed_directed_edges: set[tuple[int, int]] = set()
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
        elif pair_type in {"retrieval", "loop"}:
            expected_role = "loop" if topology == "continuous" else "retrieval"
            if pair_type != expected_role:
                raise EvidenceError(
                    "pair_list retrieval vocabulary pair role does not match the resolved topology"
                )
            if query_view not in edge:
                raise EvidenceError(
                    "pair_list retrieval pair has an invalid query view"
                )
            if not isinstance(accepted_retrieval, Mapping) or query_view not in set(
                accepted_retrieval["query_views"]
            ):
                raise EvidenceError(
                    "pair_list retrieval query violates the resolved stride"
                )
            if view_b - view_a < distance_minimum:
                raise EvidenceError("pair_list retrieval neighbor is not distant")
            target_view = view_b if query_view == view_a else view_a
            if (
                requires_cross_clip_retrieval
                and clip_ids[query_view] == clip_ids[target_view]
            ):
                raise EvidenceError(
                    "pair_list cross-clip retrieval pair stays inside one clip"
                )
            if not pair["attempted"]:
                raise EvidenceError(
                    "pair_list scheduled retrieval pair was not attempted"
                )
            observed_directed_edges.add((query_view, target_view))
        else:
            if (
                not accepted_uses_exhaustive
                or query_view is not None
                or pair["matcher_used"] != accepted_attempt["matcher_used"]
                or not pair["attempted"]
            ):
                raise EvidenceError(
                    "pair_list exhaustive pair is invalid for the resolved route"
                )
            exhaustive_pairs.add(edge)

    if local_pairs != (set() if accepted_uses_exhaustive else accepted_local_edges):
        raise EvidenceError(
            "pair_list local edges do not match the resolved temporal policy"
        )
    expected_exhaustive = (
        {
            (view_a, view_b)
            for view_a in range(requested_scale)
            for view_b in range(view_a + 1, requested_scale)
        }
        if accepted_uses_exhaustive
        else set()
    )
    if exhaustive_pairs != expected_exhaustive:
        raise EvidenceError(
            "pair_list exhaustive edges do not form the exact all-pairs closure"
        )

    if observed_directed_edges != accepted_directed_edges:
        raise EvidenceError(
            "pair_list accepted retrieval output does not match scheduled pairs"
        )
    accepted_counts = [
        accepted_attempt["scheduled_pair_count"],
        accepted_attempt["attempted_pair_count"],
        accepted_attempt["raw_matched_pair_count"],
        accepted_attempt["spatially_verified_pair_count"],
    ]
    if accepted_counts != [
        len(raw_pairs),
        attempted_count,
        raw_matched_count,
        verified_count,
    ]:
        raise EvidenceError("pair_list accepted attempt count/list disagreement")
    if len(raw_pairs) != pipeline_metrics.get("scheduled_pairs"):
        raise EvidenceError("pair_list scheduled_pairs does not match pipeline metrics")
    derived_counts = {
        "attempted_pairs": attempted_count,
        "raw_matched_pairs": raw_matched_count,
        "spatially_verified_pairs": verified_count,
        "local_pairs": type_counts["local"],
        "retrieval_pairs": type_counts["retrieval"] + type_counts["exhaustive"],
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
        raise EvidenceError(
            "pair_list connected component count does not match pipeline metrics"
        )
    if pipeline_metrics.get("isolated_views") != isolated_views:
        raise EvidenceError(
            "pair_list isolated view count does not match pipeline metrics"
        )
    for name, count in _biconnected_robustness(adjacency).items():
        if pipeline_metrics.get(name) != count:
            raise EvidenceError(f"pair_list {name} does not match pipeline metrics")
    serialized_pairs = "".join(
        f"{image_names[view_a]} {image_names[view_b]}\n"
        for view_a, view_b in sorted(pairs)
    ).encode("utf-8")
    return sha256_bytes(serialized_pairs)


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
    photo_permutation_gh_executable: Path | None = None,
    expected_photo_permutation_gh_sha256: str | None = None,
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
        observation_keys.update(
            {"timing", "memory", "resolved_compute", "pipeline_metrics"}
        )
    if lane == LANE_REFERENCE and request["expected_outcome"]["kind"] == "valid":
        if "scene_quality" in scopes:
            observation_keys.update({"registration", "residual_pixels", "pose"})
        if "long_sequence" in scopes:
            observation_keys.add("long_sequence")
        if "stability" in scopes:
            observation_keys.add("stability")
        if "toolchain" in scopes:
            observation_keys.add("toolchain_scenarios")
    photo_permutation = observations.get("photo_permutation")
    photo_permutation_receipt = observations.get("photo_permutation_execution_receipt")
    if (photo_permutation is None) != (photo_permutation_receipt is None):
        raise EvidenceError(
            "photo permutation evidence and execution receipt must be supplied together"
        )
    if photo_permutation is not None:
        if lane != LANE_REFERENCE or request["expected_outcome"]["kind"] != "valid":
            raise EvidenceError(
                "photo permutation evidence is restricted to the valid reference lane"
            )
        observation_keys.update(
            {"photo_permutation", "photo_permutation_execution_receipt"}
        )
        validate_photo_permutation_group(
            photo_permutation,
            request,
            formal_release=request["binding"]["profile"] == "release",
            execution_receipt=photo_permutation_receipt,
        )
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
        "training_split": "training-split.json",
        "geometry_manifest": "geometry-manifest.json",
        "pair_list": "pair-list.json",
        "selection_manifest": "selection-manifest.json",
        "ground_truth_poses": "ground-truth-poses.json",
        "accurate_colmap_model": "accurate-colmap-model.json",
        "accurate_rendering_reference": "accurate-rendering-reference.json",
        "ground_truth_preparation": "ground-truth-preparation.json",
        "paired_baseline_rendering_reference": "paired-baseline-rendering-reference.json",
        "photo_permutation_execution_receipt": (
            "photo-permutation-execution-receipt.json"
        ),
        "photo_permutation_attestation_bundle": ("photo-permutation-attestation.jsonl"),
        "photo_permutation_source_authorization": (
            "photo-permutation-source-authorization.json"
        ),
        "photo_permutation_source_authorization_attestation_bundle": (
            "photo-permutation-source-authorization-attestation.jsonl"
        ),
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
            raise EvidenceError(
                f"observations.artifacts.{name} must be a relative path"
            )
        relative = PurePosixPath(raw_path)
        if (
            relative.is_absolute()
            or any(part in {"", ".", ".."} for part in relative.parts)
            or "\\" in raw_path
        ):
            raise EvidenceError(f"unsafe artifact path: {raw_path}")
        descriptors[name] = _artifact_descriptor(
            artifact_root / Path(*relative.parts), artifact_root
        )

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
        required.update({"output_ply", "training_manifest", "selection_manifest"})
    if photo_permutation is not None:
        required.update(
            {
                "photo_permutation_execution_receipt",
                "photo_permutation_attestation_bundle",
                "photo_permutation_source_authorization",
                "photo_permutation_source_authorization_attestation_bundle",
            }
        )
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
        raise EvidenceError(
            "missing required evidence artifacts: " + ", ".join(sorted(missing))
        )
    if request["expected_outcome"]["kind"] == "invalid" and "output_ply" in descriptors:
        raise EvidenceError("invalid evidence must not publish output_ply")
    photo_permutation_source_authorization: dict[str, Any] | None = None
    photo_permutation_supervisor_provenance: dict[str, Any] | None = None
    if photo_permutation is not None:
        source_authorization_descriptor = descriptors[
            "photo_permutation_source_authorization"
        ]
        photo_permutation_source_authorization = (
            validate_photo_permutation_source_authorization(
                _load_bounded_json(
                    artifact_root / source_authorization_descriptor["path"],
                    "photo permutation source authorization",
                    maximum_bytes=MAX_ATTESTATION_BYTES,
                ),
                photo_permutation_receipt,
                request,
            )
        )
        photo_permutation_supervisor_provenance = (
            verify_photo_permutation_github_attestations(
                photo_permutation_receipt,
                artifact_root
                / descriptors["photo_permutation_execution_receipt"]["path"],
                artifact_root
                / descriptors["photo_permutation_attestation_bundle"]["path"],
                photo_permutation_source_authorization,
                artifact_root
                / descriptors["photo_permutation_source_authorization"]["path"],
                artifact_root
                / descriptors[
                    "photo_permutation_source_authorization_attestation_bundle"
                ]["path"],
                request,
                gh_executable=photo_permutation_gh_executable,
                expected_gh_sha256=expected_photo_permutation_gh_sha256,
            )
        )
    selection_sources: SelectionManifestSources | None = None
    if request["expected_outcome"]["kind"] == "valid":
        selection_descriptor = descriptors["selection_manifest"]
        if (
            selection_descriptor["sha256"]
            != request["reference_artifacts"]["selection_manifest_sha256"]
        ):
            raise EvidenceError(
                "selection_manifest does not match the pinned reference artifact digest"
            )
        selection_sources = _validate_selection_manifest_sources(
            artifact_root / selection_descriptor["path"],
            requested_scale=request["binding"]["scale"],
            input_kind=request["input_kind"],
            expected_video_source_count=request["video_source_count"],
        )
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
    protected_pair_list_digest: str | None = None
    if lane == LANE_REFERENCE and "scene_quality" in scopes:
        for artifact_name, request_field in reference_descriptor_fields.items():
            if (
                descriptors[artifact_name]["sha256"]
                != request["reference_artifacts"][request_field]
            ):
                raise EvidenceError(
                    f"{artifact_name} does not match the pinned reference artifact digest"
                )
        _validate_orientation_label(
            artifact_root / descriptors["orientation_label"]["path"]
        )
        assert selection_sources is not None
        protected_pair_list_digest = _validate_pair_list(
            artifact_root / descriptors["pair_list"]["path"],
            request["binding"]["scale"],
            selection_sources,
            request["candidate_run_configuration"],
            _mapping(
                observations.get("pipeline_metrics"), "observations.pipeline_metrics"
            ),
            requires_cross_clip_retrieval=_requires_cross_clip_retrieval(
                request,
                request["candidate_run_configuration"],
            ),
        )
    actual = _validate_actual(
        observations.get("actual"),
        request["expected_outcome"],
    )
    if request["expected_outcome"]["kind"] == "valid":
        _timing_metrics(
            _mapping(observations.get("timing"), "observations.timing"),
            lane,
            scopes,
        )
    commands = observations.get("commands")
    _validate_execution_receipts(
        commands,
        artifact_root / descriptors["command_log"]["path"],
        artifact_root,
        descriptors,
        request,
        runner_identity,
        (
            _mapping(observations.get("timing"), "observations.timing")
            if request["expected_outcome"]["kind"] == "valid"
            else None
        ),
        actual,
        descriptors.get("output_ply", {}).get("sha256"),
        (
            _mapping(
                observations.get("pipeline_metrics"), "observations.pipeline_metrics"
            )
            if request["expected_outcome"]["kind"] == "valid"
            else None
        ),
        protected_pair_list_digest,
        selection_sources,
    )
    if lane == LANE_REFERENCE and "scene_quality" in scopes:
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
                raise EvidenceError(
                    f"orientation artifact descriptor conflicts with {name}"
                )
            descriptors[name] = descriptor
        rendering_evidence = validate_and_score_rendering(
            artifact_root=artifact_root,
            manifest_path=artifact_root / descriptors["rendering_manifest"]["path"],
            reference_path=artifact_root
            / descriptors["accurate_rendering_reference"]["path"],
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
                raise EvidenceError(
                    f"rendering artifact descriptor conflicts with {name}"
                )
            descriptors[name] = descriptor
    output_splat_count: int | None = None
    if "output_ply" in descriptors:
        output_ply = artifact_root / descriptors["output_ply"]["path"]
        output_splat_count = _validate_splat_ply(output_ply)
        _validate_training_manifest(
            artifact_root / descriptors["training_manifest"]["path"],
            descriptors["output_ply"],
            output_splat_count,
            _mapping(
                observations.get("pipeline_metrics"), "observations.pipeline_metrics"
            ),
            request["candidate_run_configuration"],
            _published_training_duration(
                observations.get("commands"),
                _mapping(observations.get("timing"), "observations.timing"),
            ),
            training_split_path=(
                artifact_root / descriptors["training_split"]["path"]
                if "training_split" in descriptors
                else None
            ),
            training_split_descriptor=descriptors.get("training_split"),
            geometry_manifest_descriptor=descriptors.get("geometry_manifest"),
            request=request,
        )

    artifact_sizes = {
        name: descriptor["bytes"] for name, descriptor in descriptors.items()
    }
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
        raise EvidenceError(
            "protected producer is not running from the repository path"
        )
    unsigned = {
        "schema_version": ATTESTATION_SCHEMA_VERSION,
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
        "video_source_count": request["video_source_count"],
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
    if photo_permutation is not None:
        unsigned["photo_permutation"] = photo_permutation
        unsigned["photo_permutation_execution_receipt"] = photo_permutation_receipt
        unsigned["photo_permutation_source_authorization"] = (
            photo_permutation_source_authorization
        )
        unsigned["photo_permutation_supervisor_provenance"] = (
            photo_permutation_supervisor_provenance
        )
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
    *,
    photo_permutation_gh_executable: Path | None = None,
    expected_photo_permutation_gh_sha256: str | None = None,
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
    attestation_fields = {
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
        "video_source_count",
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
    }
    if "photo_permutation" in attestation:
        attestation_fields.update(
            {
                "photo_permutation",
                "photo_permutation_execution_receipt",
                "photo_permutation_source_authorization",
                "photo_permutation_supervisor_provenance",
            }
        )
    elif {
        "photo_permutation_execution_receipt",
        "photo_permutation_source_authorization",
        "photo_permutation_supervisor_provenance",
    } & set(attestation):
        raise EvidenceError(
            "photo permutation execution proof has no permutation evidence"
        )
    _exact_keys(attestation, attestation_fields, "attestation")
    if (
        attestation["schema_version"] != ATTESTATION_SCHEMA_VERSION
        or attestation["lane"] != expected_lane
    ):
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
        "video_source_count",
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
        raise EvidenceError(
            "invalid evidence must mark resolved compute not_applicable"
        )
    if "photo_permutation" in attestation:
        if (
            expected_lane != LANE_REFERENCE
            or request["expected_outcome"]["kind"] != "valid"
        ):
            raise EvidenceError(
                "prepared photo permutation evidence is restricted to the valid reference lane"
            )
        validate_photo_permutation_group(
            attestation["photo_permutation"],
            request,
            formal_release=request["binding"]["profile"] == "release",
            execution_receipt=attestation["photo_permutation_execution_receipt"],
        )
        validated_source_authorization = (
            validate_photo_permutation_source_authorization(
                attestation["photo_permutation_source_authorization"],
                attestation["photo_permutation_execution_receipt"],
                request,
            )
        )
        validate_photo_permutation_supervisor_provenance(
            attestation["photo_permutation_supervisor_provenance"],
            attestation["photo_permutation_execution_receipt"],
            request,
            validated_source_authorization,
        )

    producer = _mapping(attestation["producer"], "attestation.producer")
    _exact_keys(
        producer,
        {"protocol_version", "version", "executable", "sha256"},
        "attestation.producer",
    )
    if (
        producer["protocol_version"] != PROTOCOL_VERSION
        or producer["version"] != PRODUCER_VERSION
    ):
        raise EvidenceError("attestation producer version is not supported")
    if producer["executable"] != PRODUCER_RELATIVE_PATH:
        raise EvidenceError("attestation was not made by the protected producer")
    producer_path = Path(__file__).resolve()
    if producer["sha256"] != sha256_file(producer_path):
        raise EvidenceError("attestation producer digest does not match this checkout")
    expected_runner = validate_runner_identity(
        expected_measurement_runner, expected_lane
    )
    actual_runner = validate_runner_identity(
        attestation["measurement_runner"], expected_lane
    )
    if actual_runner != expected_runner:
        raise EvidenceError(
            "attestation measurement runner does not match the approved request index"
        )

    machine = _mapping(attestation["machine"], "attestation.machine")
    validate_machine_lane(machine, expected_lane)
    artifacts = _mapping(attestation["artifacts"], "attestation.artifacts")
    root = attestation_path.parent.resolve()
    for name, raw_descriptor in artifacts.items():
        _token(name, f"attestation.artifacts.{name}")
        descriptor = _mapping(raw_descriptor, f"attestation.artifacts.{name}")
        _exact_keys(
            descriptor, {"path", "sha256", "bytes"}, f"attestation.artifacts.{name}"
        )
        raw_path = descriptor["path"]
        if not isinstance(raw_path, str):
            raise EvidenceError("artifact path must be relative")
        relative = PurePosixPath(raw_path)
        if (
            relative.is_absolute()
            or any(part in {"", ".", ".."} for part in relative.parts)
            or "\\" in raw_path
        ):
            raise EvidenceError(f"unsafe attestation artifact path: {raw_path}")
        path = attestation_path.parent / Path(*relative.parts)
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise EvidenceError(
                f"attestation artifact is missing: {raw_path}"
            ) from error
        if resolved.parent != root and root not in resolved.parents:
            raise EvidenceError(f"attestation artifact escapes its root: {raw_path}")
        if path.is_symlink() or not path.is_file():
            raise EvidenceError(
                f"attestation artifact must be a regular file: {raw_path}"
            )
        if (
            type(descriptor["bytes"]) is not int
            or descriptor["bytes"] != path.stat().st_size
        ):
            raise EvidenceError(f"attestation artifact size mismatch: {raw_path}")
        _digest(descriptor["sha256"], f"attestation.artifacts.{name}.sha256")
        if descriptor["sha256"] != sha256_file(path):
            raise EvidenceError(f"attestation artifact digest mismatch: {raw_path}")
    if "photo_permutation" in attestation:
        try:
            receipt_descriptor = _mapping(
                artifacts["photo_permutation_execution_receipt"],
                "attestation photo permutation execution receipt descriptor",
            )
            bundle_descriptor = _mapping(
                artifacts["photo_permutation_attestation_bundle"],
                "attestation photo permutation bundle descriptor",
            )
            source_authorization_descriptor = _mapping(
                artifacts["photo_permutation_source_authorization"],
                "attestation photo permutation source authorization descriptor",
            )
            source_authorization_bundle_descriptor = _mapping(
                artifacts["photo_permutation_source_authorization_attestation_bundle"],
                "attestation photo permutation source authorization bundle descriptor",
            )
        except KeyError as error:
            raise EvidenceError(
                "attestation is missing photo permutation trust artifacts"
            ) from error
        verified_provenance = verify_photo_permutation_github_attestations(
            attestation["photo_permutation_execution_receipt"],
            attestation_path.parent / receipt_descriptor["path"],
            attestation_path.parent / bundle_descriptor["path"],
            attestation["photo_permutation_source_authorization"],
            attestation_path.parent / source_authorization_descriptor["path"],
            attestation_path.parent / source_authorization_bundle_descriptor["path"],
            request,
            gh_executable=photo_permutation_gh_executable,
            expected_gh_sha256=expected_photo_permutation_gh_sha256,
        )
        if (
            verified_provenance
            != attestation["photo_permutation_supervisor_provenance"]
        ):
            raise EvidenceError(
                "photo permutation supervisor provenance changed after preparation"
            )
    output_descriptor = artifacts.get("output_ply")
    _validate_prepared_execution_receipts(
        attestation["commands"],
        request,
        actual_runner,
        attestation["actual"],
        (
            _mapping(output_descriptor, "attestation.artifacts.output_ply")["sha256"]
            if output_descriptor is not None
            else None
        ),
        artifact_root=attestation_path.parent,
        descriptors=artifacts,
    )
    return attestation
