#!/usr/bin/env python3
"""Machine-readable Apple Silicon benchmark and release-gate harness."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import platform
import re
import stat
import statistics
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Mapping, NamedTuple, TextIO

try:
    from scripts.benchmark import evidence_protocol as evidence
except ModuleNotFoundError:
    import evidence_protocol as evidence


ROOT = Path(__file__).resolve().parents[2]
ALLOWED_CATEGORIES = {
    "object_orbit",
    "interior_walkthrough",
    "professional_photos",
    "large_area_exterior",
    "low_light",
    "invalid",
}
RELEASE_CATEGORY_COUNTS = {
    "object_orbit": 6,
    "interior_walkthrough": 6,
    "professional_photos": 4,
    "large_area_exterior": 4,
    "low_light": 3,
    "invalid": 3,
}
RELEASE_CATEGORY_SCENARIOS = {
    "object_orbit": {
        "camera",
        "complete_loop",
        "glossy",
        "low_texture",
        "partial_orbit",
        "phone",
    },
    "interior_walkthrough": {
        "multi_room_loop",
        "narrow_hall",
        "open_room",
        "repeated_doors",
        "stairs_or_elevation",
        "windows_and_mirrors",
    },
    "professional_photos": {
        "curated_property_set",
        "fisheye_or_action_camera",
        "mixed_cameras_or_lenses",
        "shared_lens",
    },
    "large_area_exterior": {
        "ground_level_building_or_campus_perimeter",
        "long_facade_block_or_grounds_traversal",
        "nadir_or_steep_down_aerial_capture",
        "oblique_aerial_orbit_or_loop",
    },
    "low_light": {
        "dim_interior",
        "dusk_exterior",
        "night_or_high_iso",
    },
    "invalid": {
        "disconnected_captures",
        "dynamic_dominated_or_inconsistent_input",
        "pan_only_or_near_zero_parallax",
    },
}
ALLOWED_AUTHORIZATION_STATUSES = {
    "documented_consent",
    "pending",
    "redistributable",
}
ALLOWED_CAPTURE_TRAITS = {
    "ordered",
    "unordered",
    "segmented",
    "loop",
    "forward_motion",
    "mixed_intrinsics",
    "fisheye",
    "large_area",
    "low_texture",
    "low_light",
    "nadir",
}
ALLOWED_GATE_SCOPES = {
    "scene_quality",
    "scene_performance",
    "suite_performance",
    "long_sequence",
    "stability",
    "invalid_input",
    "toolchain",
}
ALLOWED_SCALE_LANES = {30, 120, 250, 500, 3_000}
ALLOWED_ADAPTERS = {"fixture", "protected-evidence"}
APP_VERSION = "0.2.0-beta.1"
APPROVED_PAIRED_BASELINE = {
    "git_commit": "4f3c11735ad15e1318ee2043ce351e185c225d30",
    "toolchain_identity": "sha256:bd32d5868c5cb6a06a2ae5822d87753f08daf050ea7299c9e373c174be49116b",
    "run_configuration": {
        "detail_profile": "balanced",
        "selected_frame_count": "request_scale",
        "geometry_route": "colmap",
        "feature_type": "sift",
        "feature_max_image_size": 1_024,
        "feature_max_count": 10_000,
        "descriptor_matcher": "exact_cpu_brute_force",
        "maximum_match_count": 10_000,
        "matcher_threads": 8,
        "sequential_overlap": {
            "automatic": 8,
            "orbit": 8,
            "walkthrough": 8,
            "large_area": 16,
        },
        "exhaustive_block_size": 25,
        "mapper": "incremental",
        "bundle_adjustment_max_iterations": {
            "automatic": 75,
            "orbit": 75,
            "walkthrough": 75,
            "large_area": 94,
        },
        "trainer": "native_msplat",
        "trainer_iterations": 7_000,
        "trainer_plateau_window": 800,
        "deterministic_seed": 42,
    },
}
MAX_TOOLCHAIN_INSTALL_STATE_BYTES = 16 * 1024 * 1024
PINNED_TOOLCHAIN_PUBLIC_KEY_PATH = ROOT / "EasySplatApp/Resources/public_key_ed25519.txt"
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
ARTIFACT_NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")
UNAVAILABLE_REASON_CODES = {
    "adapter_incomplete",
    "not_measured",
    "reference_unavailable",
    "tool_unavailable",
    "unsupported",
}
PRIVATE_TEXT_PATTERNS = (
    re.compile(r"/Users/", re.IGNORECASE),
    re.compile(r"/home/", re.IGNORECASE),
    re.compile(r"[A-Za-z]:\\"),
    re.compile(r"https?://[^/\s:@]+:[^/\s@]+@", re.IGNORECASE),
)

NONNEGATIVE_INTEGER_METRICS = {
    "registered_views",
    "total_views",
    "colmap_registered_views",
    "baseline_registered_views",
    "points",
    "observations",
    "output_splat_count",
    "long_sequence_frames",
    "peak_memory_bytes",
    "peak_metal_allocated_bytes",
    "machine_memory_bytes",
    "repeat_runs",
    "crashes",
    "corrupt_outputs",
    "normal_photo_toolchain_bytes",
    "large_area_toolchain_bytes",
    "max_resident_set_size_bytes",
    "scheduled_pairs",
    "attempted_pairs",
    "raw_matched_pairs",
    "spatially_verified_pairs",
    "connected_components",
    "isolated_views",
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
NONNEGATIVE_NUMBER_METRICS = {
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
    "fast_end_to_end_speedup",
    "m4_max_p50_seconds",
    "balanced_geometry_speedup",
    "constrained_fast_p50_seconds",
    "eight_gb_fast_p50_seconds",
    "long_sequence_analysis_fps",
    "long_sequence_rss_growth_fraction",
    "wall_time_seconds",
    "geometry_seconds",
    "training_seconds",
    "matcher_seconds",
    "mapping_seconds",
    "orientation_physical_up_error_degrees",
    "raster_exact_fallback_elapsed_seconds",
    "raster_replay_elapsed_seconds",
    "matching_speedup",
    "mapping_speedup",
}
BOOLEAN_METRICS = {
    "deterministic_restart",
    "orientation_sign_correct",
    "toolchain_fresh_install",
    "toolchain_cached_offline_run",
    "toolchain_interrupted_download_recovered",
    "toolchain_low_disk_rejected",
    "toolchain_wrong_key_rejected",
    "toolchain_corrupt_archive_rejected",
    "toolchain_rollback_succeeded",
    "toolchain_traversal_rejected",
}
ENUM_METRICS = {
    "residual_provenance": {"track_reprojection"},
    "memory_lane": {"eight_gb_fast", "constrained", "larger"},
    "orientation_status": {"verified", "axis_aligned_sign_unverified", "unresolved"},
}
ALLOWED_METRICS = (
    NONNEGATIVE_INTEGER_METRICS
    | NONNEGATIVE_NUMBER_METRICS
    | BOOLEAN_METRICS
    | set(ENUM_METRICS)
)

GATE_SCOPE_METRICS = {
    "scene_quality": {
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
        "balanced_scene_psnr_loss_db",
        "balanced_scene_ssim_loss",
        "balanced_scene_lpips_increase",
        "fast_scene_psnr_loss_db",
        "fast_scene_ssim_loss",
        "fast_scene_lpips_increase",
        "paired_balanced_scene_psnr_loss_db",
        "paired_balanced_scene_ssim_loss",
        "paired_balanced_scene_lpips_increase",
        "scheduled_pairs",
        "attempted_pairs",
        "raw_matched_pairs",
        "spatially_verified_pairs",
        "connected_components",
        "isolated_views",
        "local_pairs",
        "retrieval_pairs",
        "loop_pairs",
        "orientation_status",
        "dropped_intersection_count",
    },
    "scene_performance": {
        "peak_memory_bytes",
        "peak_metal_allocated_bytes",
        "machine_memory_bytes",
        "memory_lane",
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
    },
    "suite_performance": {
        "m4_max_p50_seconds",
        "balanced_geometry_speedup",
        "fast_end_to_end_speedup",
        "matching_speedup",
        "mapping_speedup",
    },
    "long_sequence": {
        "long_sequence_analysis_fps",
        "long_sequence_frames",
        "long_sequence_rss_growth_fraction",
    },
    "stability": {"repeat_runs", "crashes", "corrupt_outputs", "deterministic_restart"},
    "invalid_input": set(),
    "toolchain": {
        "normal_photo_toolchain_bytes",
        "large_area_toolchain_bytes",
        "toolchain_fresh_install",
        "toolchain_cached_offline_run",
        "toolchain_interrupted_download_recovered",
        "toolchain_low_disk_rejected",
        "toolchain_wrong_key_rejected",
        "toolchain_corrupt_archive_rejected",
        "toolchain_rollback_succeeded",
        "toolchain_traversal_rejected",
    },
}

APPROVED_THRESHOLDS: dict[str, Any] = {
    "coverage": {"absolute_min": 0.90, "colmap_relative_min": 0.95},
    "residual_pixels": {"median_max": 1.5, "p90_max": 3.0},
    "pose": {
        "ate_colmap_ratio_max": 1.10,
        "rotation_rpe_delta_degrees_max": 0.2,
        "translation_rpe_delta_percentage_points_max": 2.0,
    },
    "orientation": {
        "physical_up_error_degrees_max": 5.0,
    },
    "balanced_rendering": {
        "median_psnr_loss_db_max": 0.5,
        "median_ssim_loss_max": 0.01,
        "median_lpips_increase_max": 0.02,
        "scene_psnr_loss_db_max": 1.0,
        "scene_ssim_loss_max": 0.02,
        "scene_lpips_increase_max": 0.03,
    },
    "fast_rendering": {
        "scene_psnr_loss_db_max": 1.0,
        "scene_ssim_loss_max": 0.02,
        "scene_lpips_increase_max": 0.03,
        "end_to_end_speedup_min": 2.0,
    },
    "paired_baseline_rendering": {
        "median_psnr_loss_db_max": 0.2,
        "median_ssim_loss_max": 0.005,
        "median_lpips_increase_max": 0.01,
        "scene_psnr_loss_db_max": 0.5,
        "scene_ssim_loss_max": 0.01,
        "scene_lpips_increase_max": 0.02,
    },
    "speed": {
        "m4_max_balanced_p50_seconds_max_by_scale": {
            "30": 120.0,
            "120": 300.0,
            "250": 600.0,
            "500": 1_200.0,
        },
        "constrained_fast_p50_seconds_max_by_scale": {
            "30": 300.0,
            "120": 600.0,
        },
        "eight_gb_fast_p50_seconds_max_by_scale": {"30": 300.0},
        "geometry_geometric_mean_speedup_min": 2.0,
        "category_median_geometry_speedup_min": 1.5,
        "matching_geometric_mean_speedup_min": 10.0,
        "matching_speedup_scales": [120, 250, 500],
        "ordered_mapping_speedup_min": 1.5,
        "unordered_mapping_regression_max_fraction": 0.10,
    },
    "long_sequence": {
        "analysis_fps_min": 5.0,
        "sustained_frames_min": 3_000,
        "rss_growth_fraction_max": 0.05,
    },
    "memory": {
        "eight_gb_fast_bytes_max": 6_500_000_000,
        "constrained_bytes_max": 12_000_000_000,
        "larger_fraction_max": 0.75,
    },
    "stability": {
        "repeat_runs_min": 50,
        "crashes_max": 0,
        "corrupt_outputs_max": 0,
        "deterministic_restart_required": True,
    },
    "toolchain": {
        "normal_photo_bytes_max": 2_500_000_000,
        "large_area_bytes_max": 2_500_000_000,
    },
}


class ConfigError(ValueError):
    """The benchmark contract is malformed or no longer matches release policy."""


class RunIdentity(NamedTuple):
    profile: str
    corpus_digest: str
    thresholds_digest: str
    git_commit: str
    app_version: str
    toolchain_identity: str


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def sha256_json(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def _require_mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ConfigError(f"{label} must be an object")
    return value


def _require_exact_keys(value: Mapping[str, Any], keys: Iterable[str], label: str) -> None:
    expected = set(keys)
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if unknown:
            details.append("unknown " + ", ".join(unknown))
        raise ConfigError(f"{label} has invalid fields: {'; '.join(details)}")


def _require_nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{label} must be a nonempty string")
    return value.strip()


def _require_public_text(value: Any, label: str) -> str:
    text = _require_nonempty_string(value, label)
    if any(pattern.search(text) for pattern in PRIVATE_TEXT_PATTERNS):
        raise ConfigError(f"{label} contains private machine identity or URL credentials")
    return text


def _require_safe_token(value: Any, label: str) -> str:
    token = _require_public_text(value, label)
    if not SAFE_TOKEN_PATTERN.fullmatch(token):
        raise ConfigError(f"{label} must be a lowercase token, not a path")
    return token


def _safe_relative_path(value: Any, label: str) -> str:
    raw = _require_nonempty_string(value, label)
    path = PurePosixPath(raw)
    if path.is_absolute() or raw.startswith(("~", "\\")) or any(part in {"", ".", ".."} for part in path.parts):
        raise ConfigError(f"unsafe {label}: {raw}")
    if "\\" in raw:
        raise ConfigError(f"unsafe {label}: {raw}")
    return raw


def validate_corpus(corpus: Any, expected_profile: str) -> None:
    root = _require_mapping(corpus, "corpus")
    _require_exact_keys(root, {"schema_version", "manifest_profile", "scenes"}, "corpus")
    if root["schema_version"] != 1:
        raise ConfigError("corpus.schema_version must be 1")
    if expected_profile not in {"smoke", "release"}:
        raise ConfigError("expected profile must be smoke or release")
    if root["manifest_profile"] != expected_profile:
        raise ConfigError(f"corpus manifest_profile must be {expected_profile}")
    scenes = root["scenes"]
    if not isinstance(scenes, list) or not scenes:
        raise ConfigError("corpus.scenes must be a nonempty array")

    ids: set[str] = set()
    counts = {category: 0 for category in ALLOWED_CATEGORIES}
    for index, raw_scene in enumerate(scenes):
        label = f"corpus.scenes[{index}]"
        scene = _require_mapping(raw_scene, label)
        _require_exact_keys(
            scene,
            {
                "id",
                "category",
                "scenario",
                "capture_traits",
                "gate_scopes",
                "license",
                "provenance",
                "input",
                "scale_lanes",
                "aggregate_scale",
                "split",
                "reference",
                "expected_outcome",
                "adapter",
            },
            label,
        )
        scene_id = _require_nonempty_string(scene["id"], f"{label}.id")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{1,63}", scene_id):
            raise ConfigError(f"{label}.id must be a stable lowercase slug")
        if scene_id in ids:
            raise ConfigError(f"duplicate scene id: {scene_id}")
        ids.add(scene_id)

        category = scene["category"]
        if category not in ALLOWED_CATEGORIES:
            raise ConfigError(f"unknown category: {category}")
        counts[category] += 1

        _require_safe_token(scene["scenario"], f"{label}.scenario")

        capture_traits = scene["capture_traits"]
        if (
            not isinstance(capture_traits, list)
            or not capture_traits
            or any(trait not in ALLOWED_CAPTURE_TRAITS for trait in capture_traits)
            or len(capture_traits) != len(set(capture_traits))
            or capture_traits != sorted(capture_traits)
        ):
            raise ConfigError(f"{label}.capture_traits must be a nonempty sorted list of supported traits")

        gate_scopes = scene["gate_scopes"]
        if (
            not isinstance(gate_scopes, list)
            or not gate_scopes
            or any(scope not in ALLOWED_GATE_SCOPES for scope in gate_scopes)
            or len(gate_scopes) != len(set(gate_scopes))
            or gate_scopes != sorted(gate_scopes)
        ):
            raise ConfigError(f"{label}.gate_scopes must be a nonempty sorted list of supported scopes")

        license_info = _require_mapping(scene["license"], f"{label}.license")
        _require_exact_keys(license_info, {"name", "url", "redistributable"}, f"{label}.license")
        _require_nonempty_string(license_info["name"], f"{label}.license.name")
        license_url = _require_nonempty_string(license_info["url"], f"{label}.license.url")
        if not license_url.startswith("https://"):
            raise ConfigError(f"{label}.license.url must use HTTPS")
        if not isinstance(license_info["redistributable"], bool):
            raise ConfigError(f"{label}.license.redistributable must be boolean")

        provenance = _require_mapping(scene["provenance"], f"{label}.provenance")
        _require_exact_keys(
            provenance,
            {"source", "authorization_status", "authorization_sha256"},
            f"{label}.provenance",
        )
        _require_public_text(provenance["source"], f"{label}.provenance.source")
        authorization_status = provenance["authorization_status"]
        if authorization_status not in ALLOWED_AUTHORIZATION_STATUSES:
            raise ConfigError(f"{label}.provenance.authorization_status is invalid")
        authorization_digest = provenance["authorization_sha256"]
        if authorization_status == "documented_consent":
            if not isinstance(authorization_digest, str) or not SHA256_PATTERN.fullmatch(
                authorization_digest
            ):
                raise ConfigError(
                    f"{label}.provenance documented consent requires an authorization SHA-256"
                )
        elif authorization_digest is not None:
            raise ConfigError(
                f"{label}.provenance authorization_sha256 is reserved for documented consent"
            )
        if authorization_status == "redistributable" and not license_info["redistributable"]:
            raise ConfigError(
                f"{label}.provenance cannot claim redistributable authorization "
                "for a non-redistributable license"
            )

        input_info = _require_mapping(scene["input"], f"{label}.input")
        _require_exact_keys(input_info, {"kind", "media_path", "supplied"}, f"{label}.input")
        if input_info["kind"] not in {"video", "photos", "mixed"}:
            raise ConfigError(f"{label}.input.kind is unsupported")
        _safe_relative_path(input_info["media_path"], "media path")
        if not isinstance(input_info["supplied"], bool):
            raise ConfigError(f"{label}.input.supplied must be boolean")
        if input_info["supplied"] and authorization_status == "pending":
            raise ConfigError(f"{label} supplied input requires completed authorization")
        if expected_profile == "release" and input_info["supplied"]:
            commercially_authorized = (
                authorization_status == "redistributable" and license_info["redistributable"]
            ) or authorization_status == "documented_consent"
            if not commercially_authorized:
                raise ConfigError(
                    f"{label} supplied release media requires redistributable licensing "
                    "or documented consent"
                )

        lanes = scene["scale_lanes"]
        if (
            not isinstance(lanes, list)
            or not lanes
            or any(type(value) is not int or value not in ALLOWED_SCALE_LANES for value in lanes)
            or len(lanes) != len(set(lanes))
            or lanes != sorted(lanes)
        ):
            raise ConfigError(f"{label}.scale lane list is invalid")
        if type(scene["aggregate_scale"]) is not int or scene["aggregate_scale"] not in lanes:
            raise ConfigError(f"{label}.aggregate_scale must select one declared scale lane")
        if "long_sequence" in gate_scopes and lanes != [3000]:
            raise ConfigError(f"{label}.long_sequence must use only the 3000-frame scale")

        split = _require_mapping(scene["split"], f"{label}.split")
        split_status = split.get("status")
        if split_status == "pending":
            _require_exact_keys(split, {"status"}, f"{label}.split")
            if category == "invalid":
                raise ConfigError(f"{label}.split must be not_applicable for invalid input")
            if input_info["supplied"]:
                raise ConfigError(f"{label} supplied input cannot retain a pending split")
        elif split_status == "fixture":
            _require_exact_keys(split, {"status"}, f"{label}.split")
            if category == "invalid":
                raise ConfigError(f"{label}.split must be not_applicable for invalid input")
            if expected_profile != "smoke":
                raise ConfigError(f"{label}.split fixture is smoke-only")
        elif split_status == "pinned":
            if category == "invalid":
                raise ConfigError(f"{label}.split must be not_applicable for invalid input")
            if not input_info["supplied"]:
                raise ConfigError(f"{label} unsupplied input cannot claim a pinned split")
            _require_exact_keys(split, {"status", "holdout_by_scale"}, f"{label}.split")
            holdout_by_scale = _require_mapping(
                split["holdout_by_scale"],
                f"{label}.split.holdout_by_scale",
            )
            if set(holdout_by_scale) != {str(scale) for scale in lanes}:
                raise ConfigError(f"{label}.split must pin the exact declared scale closure")
            for scale in lanes:
                holdout = holdout_by_scale[str(scale)]
                if (
                    not isinstance(holdout, list)
                    or not holdout
                    or holdout != sorted(holdout)
                    or len(holdout) != len(set(holdout))
                    or any(type(value) is not int or value < 0 or value >= scale for value in holdout)
                    or len(holdout) >= scale
                ):
                    raise ConfigError(f"{label}.split holdouts are invalid at scale {scale}")
                if input_info["kind"] == "video" and holdout != list(range(4, scale, 5)):
                    raise ConfigError(
                        f"{label}.split video holdouts must contain every fifth selected frame"
                    )
        elif split_status == "not_applicable":
            _require_exact_keys(split, {"status"}, f"{label}.split")
            if category != "invalid":
                raise ConfigError(f"{label}.split not_applicable is reserved for invalid input")
        else:
            raise ConfigError(f"{label}.split status is invalid")

        reference = _require_mapping(scene["reference"], f"{label}.reference")
        reference_status = reference.get("status")
        if reference_status == "pending":
            _require_exact_keys(reference, {"status"}, f"{label}.reference")
            if category == "invalid":
                raise ConfigError(f"{label}.reference must be not_applicable for invalid input")
            if input_info["supplied"]:
                raise ConfigError(f"{label} supplied input cannot retain pending references")
        elif reference_status == "fixture":
            _require_exact_keys(reference, {"status"}, f"{label}.reference")
            if category == "invalid":
                raise ConfigError(f"{label}.reference must be not_applicable for invalid input")
            if expected_profile != "smoke":
                raise ConfigError(f"{label}.reference fixture is smoke-only")
        elif reference_status == "pinned":
            if category == "invalid":
                raise ConfigError(f"{label}.reference must be not_applicable for invalid input")
            if not input_info["supplied"]:
                raise ConfigError(f"{label} unsupplied input cannot claim pinned references")
            _require_exact_keys(reference, {"status", "by_scale"}, f"{label}.reference")
            by_scale = _require_mapping(reference["by_scale"], f"{label}.reference.by_scale")
            if set(by_scale) != {str(scale) for scale in lanes}:
                raise ConfigError(f"{label}.reference must pin the exact declared scale closure")
            digest_fields = {
                "selection_manifest_sha256",
                "ground_truth_poses_sha256",
                "accurate_colmap_model_sha256",
                "accurate_rendering_reference_sha256",
                "paired_baseline_rendering_reference_sha256",
                "orientation_label_sha256",
            }
            for scale in lanes:
                pinned = _require_mapping(by_scale[str(scale)], f"{label}.reference.{scale}")
                _require_exact_keys(
                    pinned,
                    digest_fields | {"orientation_expected_status"},
                    f"{label}.reference.{scale}",
                )
                for field in digest_fields:
                    if not isinstance(pinned[field], str) or not SHA256_PATTERN.fullmatch(pinned[field]):
                        raise ConfigError(f"{label}.reference.{scale}.{field} is not a SHA-256 digest")
                if pinned["orientation_expected_status"] not in {
                    "verified",
                    "axis_aligned_sign_unverified",
                    "unresolved",
                }:
                    raise ConfigError(f"{label}.reference.{scale} orientation expectation is invalid")
        elif reference_status == "not_applicable":
            _require_exact_keys(reference, {"status"}, f"{label}.reference")
            if category != "invalid":
                raise ConfigError(f"{label}.reference not_applicable is reserved for invalid input")
        else:
            raise ConfigError(f"{label}.reference status is invalid")

        expected = _require_mapping(scene["expected_outcome"], f"{label}.expected_outcome")
        kind = expected.get("kind")
        if kind == "valid":
            _require_exact_keys(expected, {"kind"}, f"{label}.expected_outcome")
            if category == "invalid":
                raise ConfigError(f"{label} invalid category must declare an invalid outcome")
            if "invalid_input" in gate_scopes:
                raise ConfigError(f"{label} valid outcomes cannot use the invalid_input gate scope")
        elif kind == "invalid":
            _require_exact_keys(expected, {"kind", "failure_type"}, f"{label}.expected_outcome")
            _require_nonempty_string(expected["failure_type"], f"{label}.expected_outcome.failure_type")
            if category != "invalid":
                raise ConfigError(f"{label} valid category cannot declare an invalid outcome")
            if gate_scopes != ["invalid_input"]:
                raise ConfigError(f"{label} invalid outcomes must use only the invalid_input gate scope")
        else:
            raise ConfigError(f"{label}.expected_outcome.kind is invalid")

        adapter = _require_mapping(scene["adapter"], f"{label}.adapter")
        adapter_type = adapter.get("type")
        if adapter_type not in ALLOWED_ADAPTERS:
            raise ConfigError(f"{label}.adapter type is unsupported")
        if adapter_type == "fixture":
            _require_exact_keys(adapter, {"type", "result_path"}, f"{label}.adapter")
            _safe_relative_path(adapter["result_path"], "result path")
            if expected_profile != "smoke":
                raise ConfigError(f"{label}.adapter fixture is smoke-only")
        else:
            _require_exact_keys(adapter, {"type", "evidence_path"}, f"{label}.adapter")
            _safe_relative_path(adapter["evidence_path"], "evidence path")
            if expected_profile != "release":
                raise ConfigError(f"{label}.adapter protected-evidence is release-only")

    if expected_profile == "release" and counts != RELEASE_CATEGORY_COUNTS:
        raise ConfigError(f"release category counts must be {RELEASE_CATEGORY_COUNTS}, got {counts}")
    if expected_profile == "release":
        for category in sorted(ALLOWED_CATEGORIES):
            actual_scenarios = {
                scene["scenario"] for scene in scenes if scene["category"] == category
            }
            expected_scenarios = RELEASE_CATEGORY_SCENARIOS[category]
            if actual_scenarios != expected_scenarios:
                raise ConfigError(
                    f"release {category} scenarios must be {sorted(expected_scenarios)}, "
                    f"got {sorted(actual_scenarios)}"
                )
        scale_closure = {scale for scene in scenes for scale in scene["scale_lanes"]}
        if scale_closure != ALLOWED_SCALE_LANES:
            raise ConfigError(
                f"release scale closure must be {sorted(ALLOWED_SCALE_LANES)}, "
                f"got {sorted(scale_closure)}"
            )
        invalid_failure_types = {
            scene["expected_outcome"]["failure_type"]
            for scene in scenes
            if scene["category"] == "invalid"
        }
        if invalid_failure_types != {
            "disconnected_input",
            "multiple_scenes",
            "insufficient_overlap",
        }:
            raise ConfigError("release invalid scenario closure must retain three distinct failures")
        valid_scenes = [scene for scene in scenes if scene["expected_outcome"] == {"kind": "valid"}]
        core_scopes = {"scene_quality", "scene_performance", "suite_performance"}
        for scene in valid_scenes:
            if not core_scopes.issubset(scene["gate_scopes"]):
                raise ConfigError(
                    f"{scene['id']} must retain the scene_quality, scene_performance, "
                    "and suite_performance core gate scopes"
                )
            if 3_000 in scene["scale_lanes"] and "long_sequence" not in scene["gate_scopes"]:
                raise ConfigError(f"{scene['id']} 3000-frame lane must retain long_sequence gates")
        for suite_scope in ("stability", "toolchain"):
            if not any(suite_scope in scene["gate_scopes"] for scene in valid_scenes):
                raise ConfigError(f"release corpus must retain at least one {suite_scope} gate owner")

        large_area_traits = [
            scene["capture_traits"]
            for scene in scenes
            if scene["category"] == "large_area_exterior"
        ]
        expected_large_area_traits = [
            ["large_area", "loop", "ordered"],
            ["forward_motion", "large_area", "ordered"],
            ["large_area", "loop", "ordered"],
            ["large_area", "nadir", "ordered"],
        ]
        if large_area_traits != expected_large_area_traits:
            raise ConfigError(
                "large_area_exterior slots must cover a ground loop, forward route, "
                "oblique loop, and nadir route in manifest order"
            )


def validate_reference_config(config: Any) -> None:
    root = _require_mapping(config, "reference config")
    _require_exact_keys(root, {"schema_version", "references", "thresholds"}, "reference config")
    if root["schema_version"] != 1:
        raise ConfigError("reference config schema_version must be 1")
    references = _require_mapping(root["references"], "references")
    _require_exact_keys(
        references,
        {"paired_baseline", "accurate_colmap", "rendering"},
        "references",
    )
    baseline = _require_mapping(references["paired_baseline"], "references.paired_baseline")
    _require_exact_keys(
        baseline,
        {"git_commit", "toolchain_identity", "run_configuration"},
        "references.paired_baseline",
    )
    if baseline != APPROVED_PAIRED_BASELINE:
        raise ConfigError("references.paired_baseline must remain frozen to the approved baseline")
    colmap = _require_mapping(references["accurate_colmap"], "references.accurate_colmap")
    _require_exact_keys(colmap, {"mapper", "bundle_adjustment"}, "references.accurate_colmap")
    if colmap != {"mapper": "mapper", "bundle_adjustment": "full"}:
        raise ConfigError("references.accurate_colmap must remain the frozen accurate configuration")
    rendering = _require_mapping(references["rendering"], "references.rendering")
    _require_exact_keys(rendering, {"iterations", "pose_source"}, "references.rendering")
    if rendering != {"iterations": 30_000, "pose_source": "accurate_colmap"}:
        raise ConfigError("references.rendering must remain the frozen 30K accurate-pose configuration")

    thresholds = root["thresholds"]
    if thresholds != APPROVED_THRESHOLDS:
        for section, approved in APPROVED_THRESHOLDS.items():
            actual = thresholds.get(section) if isinstance(thresholds, Mapping) else None
            if actual != approved:
                if isinstance(actual, Mapping):
                    for key, value in approved.items():
                        if actual.get(key) != value:
                            raise ConfigError(f"{section}.{key} must remain {value!r}")
                raise ConfigError(f"{section} thresholds must remain frozen")
        raise ConfigError("thresholds must match the approved release gates")


def measured(value: Any) -> dict[str, Any]:
    return {"availability": "measured", "value": value}


def unavailable(reason: str | None = None) -> dict[str, Any]:
    value: dict[str, Any] = {"availability": "not_available"}
    if reason:
        if reason not in UNAVAILABLE_REASON_CODES:
            raise ValueError(f"unsupported metric-unavailability reason: {reason}")
        value["reason"] = reason
    return value


def metric_validation_failures(metrics: Any) -> list[str]:
    if not isinstance(metrics, Mapping):
        return ["metrics must be an object"]
    failures: list[str] = []
    unknown = sorted(set(metrics) - ALLOWED_METRICS)
    if unknown:
        failures.append("unknown metrics: " + ", ".join(unknown))
    for name, raw in metrics.items():
        if name not in ALLOWED_METRICS:
            continue
        if not isinstance(raw, Mapping):
            failures.append(f"{name} must be an availability object")
            continue
        availability = raw.get("availability")
        if availability == "not_available":
            if set(raw) - {"availability", "reason"}:
                failures.append(f"{name} not_available has unknown fields")
            reason = raw.get("reason")
            if reason is not None and reason not in UNAVAILABLE_REASON_CODES:
                failures.append(f"{name}.reason must be a controlled reason code")
            continue
        if availability != "measured" or set(raw) != {"availability", "value"}:
            failures.append(f"{name} must be measured with one value or explicitly not_available")
            continue
        value = raw["value"]
        if name in NONNEGATIVE_INTEGER_METRICS:
            if type(value) is not int or value < 0:
                failures.append(f"{name} must be a nonnegative integer")
        elif name in NONNEGATIVE_NUMBER_METRICS:
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                or value < 0
            ):
                failures.append(f"{name} must be a finite nonnegative number")
        elif name in BOOLEAN_METRICS:
            if not isinstance(value, bool):
                failures.append(f"{name} must be boolean")
        elif name in ENUM_METRICS and value not in ENUM_METRICS[name]:
            failures.append(f"{name} has an unsupported value")
    return failures


def _metric(metrics: Mapping[str, Any], name: str, blocking: list[str]) -> Any:
    raw = metrics.get(name)
    if not isinstance(raw, Mapping) or raw.get("availability") != "measured" or "value" not in raw:
        blocking.append(f"required metric not available: {name}")
        return None
    return raw["value"]


def evaluate_gates(
    metrics: Mapping[str, Any],
    thresholds: Mapping[str, Any],
    *,
    gate_scopes: Iterable[str] | None = None,
    scale: int = 30,
) -> dict[str, Any]:
    if gate_scopes is None:
        selected_scopes = sorted(ALLOWED_GATE_SCOPES - {"invalid_input"})
    else:
        selected_scopes = list(gate_scopes)
        if (
            not selected_scopes
            or any(scope not in ALLOWED_GATE_SCOPES for scope in selected_scopes)
            or len(selected_scopes) != len(set(selected_scopes))
        ):
            raise ConfigError("gate_scopes must be a nonempty list of supported scopes")
    if "invalid_input" in selected_scopes:
        raise ConfigError("invalid_input scenes must use evaluate_invalid_scene")

    blocking: list[str] = []
    failures = metric_validation_failures(metrics)
    if failures:
        return {"status": "failed", "blocking_reasons": [], "failures": failures}
    required_metrics = set().union(*(GATE_SCOPE_METRICS[scope] for scope in selected_scopes))
    orientation_status = metrics.get("orientation_status")
    if "scene_quality" in selected_scopes and isinstance(orientation_status, Mapping):
        if orientation_status.get("availability") == "measured" and orientation_status.get("value") in {
            "verified",
            "axis_aligned_sign_unverified",
        }:
            required_metrics.update(
                {
                    "orientation_physical_up_error_degrees",
                }
            )
            if orientation_status.get("value") == "verified":
                required_metrics.add("orientation_sign_correct")
    values = {name: _metric(metrics, name, blocking) for name in sorted(required_metrics)}
    if blocking:
        return {"status": "blocked", "blocking_reasons": blocking, "failures": failures}

    def maximum(name: str, limit: float) -> None:
        if not isinstance(values[name], (int, float)) or isinstance(values[name], bool) or values[name] > limit:
            failures.append(f"{name} exceeds maximum {limit}")

    def minimum(name: str, limit: float) -> None:
        if not isinstance(values[name], (int, float)) or isinstance(values[name], bool) or values[name] < limit:
            failures.append(f"{name} is below minimum {limit}")

    if "scene_quality" in selected_scopes:
        total = values["total_views"]
        registered = values["registered_views"]
        colmap_registered = values["colmap_registered_views"]
        baseline_registered = values["baseline_registered_views"]
        if not isinstance(total, (int, float)) or total <= 0:
            failures.append("total_views must be positive")
        elif registered / total < thresholds["coverage"]["absolute_min"]:
            failures.append("coverage.absolute is below minimum")
        if isinstance(registered, int) and isinstance(total, int) and registered > total:
            failures.append("registered_views exceeds total_views")
        if not isinstance(colmap_registered, (int, float)) or colmap_registered <= 0:
            failures.append("colmap_registered_views must be positive")
        elif registered / colmap_registered < thresholds["coverage"]["colmap_relative_min"]:
            failures.append("coverage.colmap_relative is below minimum")
        if not isinstance(baseline_registered, int) or baseline_registered <= 0:
            failures.append("baseline_registered_views must be positive")
        elif isinstance(registered, int):
            allowed_loss = min(2, math.floor(baseline_registered * 0.01))
            if registered < baseline_registered - allowed_loss:
                failures.append("coverage.paired_baseline loses too many registered views")

        if values["residual_provenance"] != "track_reprojection":
            failures.append("residual_provenance is not real track reprojection")
        maximum("residual_median_pixels", thresholds["residual_pixels"]["median_max"])
        maximum("residual_p90_pixels", thresholds["residual_pixels"]["p90_max"])
        if values["residual_p90_pixels"] < values["residual_median_pixels"]:
            failures.append("residual_p90_pixels is below residual_median_pixels")
        maximum("ate_colmap_ratio", thresholds["pose"]["ate_colmap_ratio_max"])
        maximum("rotation_rpe_delta_degrees", thresholds["pose"]["rotation_rpe_delta_degrees_max"])
        maximum(
            "translation_rpe_delta_percentage_points",
            thresholds["pose"]["translation_rpe_delta_percentage_points_max"],
        )
        for name, key in (
            ("balanced_scene_psnr_loss_db", "scene_psnr_loss_db_max"),
            ("balanced_scene_ssim_loss", "scene_ssim_loss_max"),
            ("balanced_scene_lpips_increase", "scene_lpips_increase_max"),
        ):
            maximum(name, thresholds["balanced_rendering"][key])
        for name, key in (
            ("fast_scene_psnr_loss_db", "scene_psnr_loss_db_max"),
            ("fast_scene_ssim_loss", "scene_ssim_loss_max"),
            ("fast_scene_lpips_increase", "scene_lpips_increase_max"),
        ):
            maximum(name, thresholds["fast_rendering"][key])
        for name, key in (
            ("paired_balanced_scene_psnr_loss_db", "scene_psnr_loss_db_max"),
            ("paired_balanced_scene_ssim_loss", "scene_ssim_loss_max"),
            ("paired_balanced_scene_lpips_increase", "scene_lpips_increase_max"),
        ):
            maximum(name, thresholds["paired_baseline_rendering"][key])
        if values["attempted_pairs"] > values["scheduled_pairs"]:
            failures.append("attempted_pairs exceeds scheduled_pairs")
        if values["raw_matched_pairs"] > values["attempted_pairs"]:
            failures.append("raw_matched_pairs exceeds attempted_pairs")
        if values["spatially_verified_pairs"] > values["raw_matched_pairs"]:
            failures.append("spatially_verified_pairs exceeds raw_matched_pairs")
        if values["connected_components"] != 1:
            failures.append("verified pair graph is disconnected")
        if values["isolated_views"] != 0:
            failures.append("verified pair graph contains isolated views")
        if values["dropped_intersection_count"] != 0:
            failures.append("rasterization dropped intersections")
        minimum("output_splat_count", 1)
        if values["orientation_status"] in {"verified", "axis_aligned_sign_unverified"}:
            maximum(
                "orientation_physical_up_error_degrees",
                thresholds["orientation"]["physical_up_error_degrees_max"],
            )
        if values["orientation_status"] == "verified" and values["orientation_sign_correct"] is not True:
            failures.append("verified orientation has the wrong upright sign")

    if "suite_performance" in selected_scopes:
        minimum("fast_end_to_end_speedup", thresholds["fast_rendering"]["end_to_end_speedup_min"])
        scale_limit = thresholds["speed"]["m4_max_balanced_p50_seconds_max_by_scale"].get(str(scale))
        if scale_limit is not None:
            maximum("m4_max_p50_seconds", scale_limit)

    if "long_sequence" in selected_scopes:
        minimum("long_sequence_analysis_fps", thresholds["long_sequence"]["analysis_fps_min"])
        minimum("long_sequence_frames", thresholds["long_sequence"]["sustained_frames_min"])
        maximum(
            "long_sequence_rss_growth_fraction",
            thresholds["long_sequence"]["rss_growth_fraction_max"],
        )

    if "scene_performance" in selected_scopes:
        lane = values["memory_lane"]
        unified_memory_peak = max(
            values["peak_memory_bytes"],
            values["peak_metal_allocated_bytes"],
        )
        if lane == "eight_gb_fast":
            unified_memory_limit = thresholds["memory"]["eight_gb_fast_bytes_max"]
        elif lane == "constrained":
            unified_memory_limit = thresholds["memory"]["constrained_bytes_max"]
        elif lane == "larger":
            unified_memory_limit = (
                values["machine_memory_bytes"] * thresholds["memory"]["larger_fraction_max"]
            )
        else:
            failures.append("memory_lane is unsupported")
            unified_memory_limit = None
        if unified_memory_limit is not None and unified_memory_peak > unified_memory_limit:
            failures.append(f"unified memory peak exceeds maximum {unified_memory_limit}")
        if unified_memory_peak > values["machine_memory_bytes"]:
            failures.append("unified memory peak exceeds machine_memory_bytes")

    if "stability" in selected_scopes:
        minimum("repeat_runs", thresholds["stability"]["repeat_runs_min"])
        maximum("crashes", thresholds["stability"]["crashes_max"])
        maximum("corrupt_outputs", thresholds["stability"]["corrupt_outputs_max"])
        if values["crashes"] > values["repeat_runs"]:
            failures.append("crashes exceeds repeat_runs")
        if values["corrupt_outputs"] > values["repeat_runs"]:
            failures.append("corrupt_outputs exceeds repeat_runs")
        if (
            thresholds["stability"]["deterministic_restart_required"]
            and values["deterministic_restart"] is not True
        ):
            failures.append("deterministic_restart must be true")

    if "toolchain" in selected_scopes:
        maximum("normal_photo_toolchain_bytes", thresholds["toolchain"]["normal_photo_bytes_max"])
        maximum("large_area_toolchain_bytes", thresholds["toolchain"]["large_area_bytes_max"])
        for name in (
            "toolchain_fresh_install",
            "toolchain_cached_offline_run",
            "toolchain_interrupted_download_recovered",
            "toolchain_low_disk_rejected",
            "toolchain_wrong_key_rejected",
            "toolchain_corrupt_archive_rejected",
            "toolchain_rollback_succeeded",
            "toolchain_traversal_rejected",
        ):
            if values[name] is not True:
                failures.append(f"{name} must be true")

    return {
        "status": "failed" if failures else "passed",
        "blocking_reasons": blocking,
        "failures": failures,
    }


def evaluate_invalid_scene(expected: Mapping[str, Any], actual: Mapping[str, Any]) -> dict[str, Any]:
    required = {"exit_code", "termination_reason", "cancelled", "failure_type", "corrupt_ply"}
    if not isinstance(actual, Mapping) or set(actual) != required:
        return {"status": "blocked", "blocking_reasons": ["complete invalid-scene evidence is unavailable"], "failures": []}
    try:
        _validate_actual_evidence(actual, "invalid-scene evidence")
    except ConfigError:
        return {"status": "blocked", "blocking_reasons": ["invalid-scene termination evidence is contradictory"], "failures": []}
    exit_code = actual["exit_code"]
    if type(exit_code) is not int:
        return {"status": "blocked", "blocking_reasons": ["integer exit evidence is unavailable"], "failures": []}
    if exit_code == 0:
        return {"status": "failed", "blocking_reasons": [], "failures": ["invalid scene unexpectedly succeeded"]}
    if actual["cancelled"] is True:
        return {"status": "failed", "blocking_reasons": [], "failures": ["invalid-scene run was cancelled"]}
    if not isinstance(actual["failure_type"], str) or not actual["failure_type"].strip():
        return {"status": "blocked", "blocking_reasons": ["typed failure outcome is unavailable"], "failures": []}
    if not isinstance(actual["corrupt_ply"], bool) or not isinstance(actual["cancelled"], bool):
        return {"status": "blocked", "blocking_reasons": ["output or cancellation evidence is unavailable"], "failures": []}
    if actual["termination_reason"] not in {"exit", "signal", "cancelled"}:
        return {"status": "blocked", "blocking_reasons": ["termination reason is unavailable"], "failures": []}
    failures: list[str] = []
    if actual.get("failure_type") != expected.get("failure_type"):
        failures.append("invalid scene returned the wrong failure type")
    if actual.get("corrupt_ply") is not False:
        failures.append("invalid scene left a corrupt PLY")
    return {"status": "failed" if failures else "passed", "blocking_reasons": [], "failures": failures}


def _run_text(argv: list[str]) -> str:
    try:
        return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "not_available"


def _sysctl_value(name: str) -> str:
    return _run_text(["/usr/sbin/sysctl", "-n", name])


def collect_machine_metadata(
    command_runner: Callable[[list[str]], str] = _run_text,
    platform_data: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if platform_data is None:
        def integer_sysctl(name: str) -> int | None:
            raw = _sysctl_value(name)
            try:
                return int(raw)
            except ValueError:
                return None

        platform_data = {
            "macos_version": command_runner(["/usr/bin/sw_vers", "-productVersion"]),
            "macos_build": command_runner(["/usr/bin/sw_vers", "-buildVersion"]),
            "hardware_model": _sysctl_value("hw.model"),
            "chip": _sysctl_value("machdep.cpu.brand_string"),
            "logical_cpus": integer_sysctl("hw.logicalcpu"),
            "physical_cpus": integer_sysctl("hw.physicalcpu"),
            "physical_memory_bytes": integer_sysctl("hw.memsize"),
        }
    allowed = {
        "macos_version",
        "macos_build",
        "hardware_model",
        "chip",
        "logical_cpus",
        "physical_cpus",
        "physical_memory_bytes",
    }
    metadata = {key: platform_data.get(key) for key in sorted(allowed)}
    metadata["architecture"] = platform.machine()
    metadata["xcode_version"] = command_runner(["/usr/bin/xcodebuild", "-version"])
    metadata["swift_version"] = command_runner(["/usr/bin/xcrun", "swift", "--version"])
    return metadata


def collect_git_state() -> dict[str, Any]:
    commit = _run_text(["/usr/bin/git", "-C", str(ROOT), "rev-parse", "HEAD"])
    dirty_output = _run_text(["/usr/bin/git", "-C", str(ROOT), "status", "--porcelain"])
    return {"commit": commit, "dirty": bool(dirty_output and dirty_output != "not_available")}


def atomic_write_json(
    path: Path,
    value: Any,
    before_replace: Callable[[Path], None] | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(canonical_json_bytes(value))
            handle.write(b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        if before_replace:
            before_replace(temporary)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary.exists():
            temporary.unlink()


def _redacted_scene_command(scene: Mapping[str, Any], scale: int) -> list[str]:
    adapter = scene["adapter"]["type"]
    if adapter == "fixture":
        return ["verify-fixture", f"corpus://{scene['id']}", "--scale", str(scale)]
    return ["verify-protected-evidence", f"corpus://{scene['id']}", "--scale", str(scale)]


def build_dry_run_plan(
    profile: str,
    corpus: Mapping[str, Any],
    config: Mapping[str, Any],
    toolchain_root: Path,
) -> dict[str, Any]:
    validate_corpus(corpus, expected_profile=profile)
    validate_reference_config(config)
    return {
        "schema_version": 1,
        "profile": profile,
        "corpus_digest": sha256_json(corpus),
        "thresholds_digest": sha256_json(config),
        "scenes": [
            {
                "id": scene["id"],
                "category": scene["category"],
                "scenario": scene["scenario"],
                "capture_traits": scene["capture_traits"],
                "gate_scopes": scene["gate_scopes"],
                "expected_outcome": scene["expected_outcome"],
                "runs": [
                    {
                        "scale": scale,
                        "adapter": scene["adapter"]["type"],
                        "command": _redacted_scene_command(scene, scale),
                    }
                    for scale in scene["scale_lanes"]
                ],
            }
            for scene in corpus["scenes"]
        ],
    }


def _load_json(path: Path, label: str) -> Any:
    def reject_constant(value: str) -> None:
        raise ConfigError(f"{label} contains non-finite JSON number {value}")

    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)
    except FileNotFoundError as error:
        raise ConfigError(f"{label} not found: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise ConfigError(f"{label} is not valid JSON: {path}: {error}") from error


def _hash_length_prefixed(hasher: Any, value: bytes) -> None:
    hasher.update(len(value).to_bytes(8, "big"))
    hasher.update(value)


def _reject_symlinked_input_ancestors(path: Path, trusted_root: Path) -> None:
    root = Path(os.path.abspath(trusted_root))
    candidate = Path(os.path.abspath(path))
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise ConfigError("benchmark input escapes its corpus root") from error
    cursor = root
    for component in (Path("."), *relative.parts):
        if component != Path("."):
            cursor /= component
        try:
            metadata = cursor.lstat()
        except OSError as error:
            raise ConfigError(f"benchmark input is missing: {path.name}") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise ConfigError("benchmark input path contains a symbolic link")


def digest_input(path: Path, *, trusted_root: Path | None = None) -> str:
    if trusted_root is not None:
        _reject_symlinked_input_ancestors(path, trusted_root)
    if not path.exists():
        raise ConfigError(f"benchmark input is missing: {path.name}")
    if path.is_symlink():
        raise ConfigError("benchmark input must not be a symlink")
    if path.is_file():
        files = [("input", path)]
    elif path.is_dir():
        files = []
        for candidate in sorted(path.rglob("*"), key=lambda value: value.relative_to(path).as_posix()):
            if candidate.is_symlink():
                raise ConfigError("benchmark input tree must not contain symlinks")
            if candidate.is_file():
                files.append((candidate.relative_to(path).as_posix(), candidate))
        if not files:
            raise ConfigError("benchmark input directory is empty")
    else:
        raise ConfigError("benchmark input must be a regular file or directory")

    hasher = hashlib.sha256()
    _hash_length_prefixed(hasher, b"easysplat-benchmark-input-v1")
    for relative_path, file_path in files:
        _hash_length_prefixed(hasher, relative_path.encode("utf-8"))
        with file_path.open("rb") as handle:
            before = os.fstat(handle.fileno())
            hasher.update(before.st_size.to_bytes(8, "big"))
            bytes_read = 0
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
                bytes_read += len(chunk)
            after = os.fstat(handle.fileno())
        if (
            bytes_read != before.st_size
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ino != after.st_ino
        ):
            raise ConfigError("benchmark input changed while it was being hashed")
    return "sha256:" + hasher.hexdigest()


def _record_unique_release_input_digest(
    scene: Mapping[str, Any],
    input_digest: str,
    seen: dict[str, str],
) -> None:
    """Reject one capture presented as multiple release-corpus scenes."""
    if not scene["input"]["supplied"]:
        return
    previous_scene = seen.get(input_digest)
    if previous_scene is not None:
        raise ConfigError(
            f"release inputs {previous_scene} and {scene['id']} have the same content digest"
        )
    seen[input_digest] = scene["id"]


def _stable_file_sha256(path: Path, label: str) -> str:
    with path.open("rb") as handle:
        before = os.fstat(handle.fileno())
        hasher = hashlib.sha256()
        bytes_read = 0
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
            bytes_read += len(chunk)
        after = os.fstat(handle.fileno())
    if (
        bytes_read != before.st_size
        or before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before.st_ino != after.st_ino
        or before.st_mode != after.st_mode
    ):
        raise ConfigError(f"{label} changed while it was being hashed")
    return hasher.hexdigest()


def _semantic_version(value: Any, label: str) -> tuple[int, int, int, tuple[str, ...] | None]:
    if not isinstance(value, str):
        raise ConfigError(f"{label} is not a semantic version")
    match = re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?",
        value,
    )
    if match is None:
        raise ConfigError(f"{label} is not a semantic version")
    prerelease = tuple(match.group(4).split(".")) if match.group(4) else None
    if prerelease is not None and any(
        not token or (token.isdigit() and len(token) > 1 and token.startswith("0"))
        for token in prerelease
    ):
        raise ConfigError(f"{label} is not a semantic version")
    return int(match.group(1)), int(match.group(2)), int(match.group(3)), prerelease


def _compare_semantic_versions(left: str, right: str) -> int:
    left_major, left_minor, left_patch, left_pre = _semantic_version(left, "version")
    right_major, right_minor, right_patch, right_pre = _semantic_version(right, "version")
    left_core = (left_major, left_minor, left_patch)
    right_core = (right_major, right_minor, right_patch)
    if left_core != right_core:
        return -1 if left_core < right_core else 1
    if left_pre is None or right_pre is None:
        return 0 if left_pre is right_pre else 1 if left_pre is None else -1
    for left_token, right_token in zip(left_pre, right_pre, strict=False):
        if left_token == right_token:
            continue
        left_numeric = left_token.isdigit()
        right_numeric = right_token.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_token) < int(right_token) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_token < right_token else 1
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))


def _verify_toolchain_manifest_signature(
    manifest: Mapping[str, Any],
    public_key_base64: str,
) -> None:
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError as error:
        raise ConfigError(
            "release toolchain signature verification requires the pinned benchmark environment"
        ) from error
    try:
        public_key = base64.b64decode(public_key_base64, validate=True)
        signature = base64.b64decode(str(manifest.get("signatureEd25519", "")), validate=True)
    except (ValueError, TypeError) as error:
        raise ConfigError("toolchain signed manifest signature is invalid") from error
    if len(public_key) != 32 or len(signature) != 64:
        raise ConfigError("toolchain signed manifest signature is invalid")
    if manifest.get("keyID") != hashlib.sha256(public_key).hexdigest():
        raise ConfigError("toolchain signed manifest key identifier is invalid")
    unsigned = dict(manifest)
    unsigned["signatureEd25519"] = ""
    published_at = unsigned.get("publishedAt")
    if isinstance(published_at, bool) or not isinstance(published_at, (int, float, str)):
        raise ConfigError("toolchain signed manifest publication date is invalid")
    if isinstance(published_at, (int, float)):
        if not math.isfinite(float(published_at)):
            raise ConfigError("toolchain signed manifest publication date is invalid")
        apple_reference_unix_seconds = 978_307_200
        published_date = datetime.fromtimestamp(
            apple_reference_unix_seconds + float(published_at),
            tz=timezone.utc,
        )
    else:
        try:
            published_date = datetime.fromisoformat(published_at.replace("Z", "+00:00"))
        except ValueError as error:
            raise ConfigError("toolchain signed manifest publication date is invalid") from error
        if published_date.tzinfo is None:
            raise ConfigError("toolchain signed manifest publication date is invalid")
        published_date = published_date.astimezone(timezone.utc)
    unsigned["publishedAt"] = published_date.strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            signature,
            canonical_json_bytes(unsigned),
        )
    except (InvalidSignature, ValueError) as error:
        raise ConfigError("toolchain signed manifest signature is invalid") from error


def _validated_toolchain_closure(
    toolchain_root: Path,
    public_key_base64: str,
) -> Mapping[str, Any] | None:
    state_path = toolchain_root / ".easysplat_toolchain_state.json"
    if not state_path.is_file() or state_path.is_symlink():
        return None
    if state_path.stat().st_size > MAX_TOOLCHAIN_INSTALL_STATE_BYTES:
        raise ConfigError("toolchain install state exceeds its size limit")
    state = _load_json(state_path, "toolchain install state")
    if not isinstance(state, dict):
        raise ConfigError("toolchain install state must be an object")
    required_state_fields = {
        "schemaVersion",
        "installedArtifacts",
        "installedCapabilities",
        "signedManifest",
    }
    if not required_state_fields.issubset(state):
        raise ConfigError("toolchain install state is incomplete")
    manifest = state.get("signedManifest")
    installed_artifacts = state.get("installedArtifacts")
    installed_capabilities = state.get("installedCapabilities")
    if state.get("schemaVersion") != 2:
        raise ConfigError("toolchain install state schema is unsupported")

    if not isinstance(manifest, dict):
        raise ConfigError("toolchain install state has no signed manifest")
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
    if (
        set(manifest) != manifest_fields
        or manifest.get("schemaVersion") != 2
        or manifest.get("toolchainAPI") != 2
        or not isinstance(manifest.get("version"), str)
        or not isinstance(manifest.get("signatureEd25519"), str)
        or not manifest["signatureEd25519"]
        or not isinstance(manifest.get("keyID"), str)
        or re.fullmatch(r"[0-9a-f]{64}", manifest["keyID"]) is None
    ):
        raise ConfigError("toolchain signed manifest identity is invalid")
    _semantic_version(manifest["version"], "toolchain version")
    _verify_toolchain_manifest_signature(manifest, public_key_base64)
    components = manifest.get("components")
    if not isinstance(components, list) or not components:
        raise ConfigError("toolchain signed manifest has no components")
    if not isinstance(installed_artifacts, dict) or not isinstance(installed_capabilities, list):
        raise ConfigError("toolchain install state component closure is invalid")
    normalized_installed = {
        key: value.lower() if isinstance(value, str) else value
        for key, value in installed_artifacts.items()
    }
    if (
        not normalized_installed
        or any(
            not isinstance(name, str)
            or SAFE_TOKEN_PATTERN.fullmatch(name) is None
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            for name, digest in normalized_installed.items()
        )
        or any(
            not isinstance(capability, str) or SAFE_TOKEN_PATTERN.fullmatch(capability) is None
            for capability in installed_capabilities
        )
        or len(installed_capabilities) != len(set(installed_capabilities))
    ):
        raise ConfigError("toolchain install state component closure is invalid")
    installed_names = set(normalized_installed)

    normalized_components: list[dict[str, Any]] = []
    component_names: set[str] = set()
    manifest_artifacts: dict[str, str] = {}
    components_by_name: dict[str, Mapping[str, Any]] = {}
    canonical_root = toolchain_root.resolve()
    for component in components:
        if not isinstance(component, dict):
            raise ConfigError("toolchain manifest component must be an object")
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
        name = component.get("name")
        capabilities = component.get("capabilities")
        digest = component.get("sha256")
        critical_hashes = component.get("criticalFileHashes")
        contents = component.get("contents")
        dependencies = component.get("dependencies")
        if (
            set(component) != component_fields
            or not isinstance(name, str)
            or SAFE_TOKEN_PATTERN.fullmatch(name) is None
            or name in component_names
            or not isinstance(capabilities, list)
            or not capabilities
            or len(capabilities) != len(set(capabilities))
            or not all(isinstance(value, str) and SAFE_TOKEN_PATTERN.fullmatch(value) for value in capabilities)
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or not isinstance(critical_hashes, dict)
            or not critical_hashes
            or not isinstance(contents, list)
            or not contents
            or len(contents) != len(set(contents))
            or not isinstance(dependencies, list)
            or len(dependencies) != len(set(dependencies))
            or not all(
                isinstance(value, str) and SAFE_TOKEN_PATTERN.fullmatch(value)
                for value in dependencies
            )
            or component.get("requirement") not in {"required", "optional"}
            or type(component.get("sizeBytes")) is not int
            or component["sizeBytes"] <= 0
            or type(component.get("expandedSizeBytes")) is not int
            or component["expandedSizeBytes"] < component["sizeBytes"]
            or not isinstance(component.get("url"), str)
            or not component["url"].startswith("https://")
        ):
            raise ConfigError("toolchain manifest component identity is invalid")
        component_names.add(name)
        manifest_artifacts[name] = digest
        components_by_name[name] = component
        for relative in contents:
            if not isinstance(relative, str):
                raise ConfigError(f"toolchain content path is invalid: {name}")
            content_path = PurePosixPath(relative)
            if (
                content_path.is_absolute()
                or "\\" in relative
                or any(part in {"", ".", ".."} for part in content_path.parts)
            ):
                raise ConfigError(f"toolchain content path is unsafe: {relative}")
        for relative, expected_hash in critical_hashes.items():
            if (
                not isinstance(relative, str)
                or not isinstance(expected_hash, str)
                or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None
            ):
                raise ConfigError(f"toolchain critical-file record is invalid: {name}")
            path = PurePosixPath(relative)
            if path.is_absolute() or "\\" in relative or any(part in {"", ".", ".."} for part in path.parts):
                raise ConfigError(f"toolchain critical-file path is unsafe: {relative}")
            if name in installed_names:
                target = toolchain_root.joinpath(*path.parts)
                if target.is_symlink() or not target.is_file():
                    raise ConfigError(f"toolchain critical file is missing or unsafe: {relative}")
                resolved = target.resolve(strict=True)
                if resolved != canonical_root and canonical_root not in resolved.parents:
                    raise ConfigError(f"toolchain critical file escapes its root: {relative}")
                if (
                    _stable_file_sha256(target, f"toolchain critical file {relative}")
                    != expected_hash
                ):
                    raise ConfigError(
                        f"toolchain critical file does not match its signed digest: {relative}"
                    )
        normalized_components.append(
            {
                key: component.get(key)
                for key in (
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
                )
            }
        )

    if not installed_names.issubset(component_names):
        raise ConfigError("toolchain install state contains an unknown component")
    if "macos-arm64-core" not in installed_names:
        raise ConfigError("toolchain install state is missing its core component")
    for name in installed_names:
        if normalized_installed[name] != manifest_artifacts[name]:
            raise ConfigError(f"toolchain installed artifact digest is invalid: {name}")
        missing_dependencies = set(components_by_name[name]["dependencies"]) - installed_names
        if missing_dependencies:
            raise ConfigError(
                f"toolchain installed component {name} is missing dependencies: "
                + ", ".join(sorted(missing_dependencies))
            )
    selected_capabilities = {
        capability
        for name in installed_names
        for capability in components_by_name[name]["capabilities"]
    }
    if set(installed_capabilities) != selected_capabilities:
        raise ConfigError("toolchain installed capability receipt does not match its components")
    app_range = manifest.get("appVersionRange")
    if (
        not isinstance(app_range, dict)
        or set(app_range) - {"minimum", "maximumExclusive"}
        or "minimum" not in app_range
        or not isinstance(app_range.get("minimum"), str)
        or (
            app_range.get("maximumExclusive") is not None
            and not isinstance(app_range.get("maximumExclusive"), str)
        )
    ):
        raise ConfigError("toolchain app-version range is invalid")
    _semantic_version(app_range["minimum"], "toolchain minimum app version")
    maximum = app_range.get("maximumExclusive")
    if maximum is not None:
        _semantic_version(maximum, "toolchain maximum app version")
    if _compare_semantic_versions(APP_VERSION, app_range["minimum"]) < 0 or (
        maximum is not None and _compare_semantic_versions(APP_VERSION, maximum) >= 0
    ):
        raise ConfigError("toolchain signed manifest is incompatible with this app version")
    return {
        "schema_version": 2,
        "toolchain_api": 2,
        "key_id": manifest["keyID"],
        "version": manifest["version"],
        "app_version_range": {
            "minimum": app_range["minimum"],
            "maximum_exclusive": app_range.get("maximumExclusive"),
        },
        "signature_ed25519": manifest["signatureEd25519"],
        "components": sorted(normalized_components, key=lambda value: value["name"]),
        "installed_artifacts": dict(sorted(normalized_installed.items())),
        "installed_capabilities": sorted(selected_capabilities),
    }


def resolved_toolchain_identity(
    toolchain_root: Path,
    profile: str,
    *,
    public_key_base64: str | None = None,
) -> str | None:
    if profile == "smoke":
        return "fixture:smoke"
    if not toolchain_root.is_dir() or toolchain_root.is_symlink():
        return None
    if public_key_base64 is None:
        try:
            public_key_base64 = PINNED_TOOLCHAIN_PUBLIC_KEY_PATH.read_text(
                encoding="utf-8"
            ).strip()
        except OSError as error:
            raise ConfigError("pinned toolchain public key is unavailable") from error
    closure = _validated_toolchain_closure(toolchain_root, public_key_base64)
    if closure is None:
        return None
    return evidence.toolchain_identity_from_closure(closure)


def make_run_identity(
    profile: str,
    corpus: Mapping[str, Any],
    config: Mapping[str, Any],
    toolchain_root: Path,
    toolchain_identity: str | None = None,
) -> RunIdentity:
    if toolchain_identity is None:
        toolchain_identity = resolved_toolchain_identity(toolchain_root, profile)
    if toolchain_identity is None:
        raise ConfigError("resolved toolchain identity is unavailable")
    if profile == "smoke":
        git_commit = "fixture"
    else:
        git_commit = collect_git_state()["commit"]
        if not isinstance(git_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", git_commit):
            raise ConfigError("release Git commit identity is unavailable")
    return RunIdentity(
        profile=profile,
        corpus_digest=sha256_json(corpus),
        thresholds_digest=sha256_json(config),
        git_commit=git_commit,
        app_version=APP_VERSION,
        toolchain_identity=toolchain_identity,
    )


def required_evidence_lanes(scene: Mapping[str, Any], scale: int) -> tuple[str, ...]:
    lanes = [evidence.LANE_REFERENCE]
    if scene["expected_outcome"] == {"kind": "valid"} and scale <= 120:
        lanes.append(evidence.LANE_CONSTRAINED)
    if (
        scene["expected_outcome"] == {"kind": "valid"}
        and scale == 30
        and scene["category"] in {"object_orbit", "interior_walkthrough", "low_light"}
    ):
        lanes.append(evidence.LANE_EIGHT_GB)
    return tuple(lanes)


def parse_runner_identities(
    values: list[str] | None,
    rendering_driver_identity_path: Path | None = None,
) -> dict[str, dict[str, Any]] | None:
    if not values and rendering_driver_identity_path is None:
        return None
    identities: dict[str, dict[str, Any]] = {}
    for raw in values or []:
        lane, separator, digest = raw.partition("=")
        if not separator or lane in identities:
            raise ConfigError("--runner-identity must contain one unique lane=sha256:<digest> value")
        if lane == evidence.RENDERING_DRIVER_IDENTITY:
            raise ConfigError(
                "the rendering driver requires --rendering-driver-identity with its complete closure identity"
            )
        identities[lane] = {"label": evidence.RUNNER_LABELS.get(lane, ""), "sha256": digest}
    if rendering_driver_identity_path is not None:
        rendering_identity = _load_json(
            rendering_driver_identity_path,
            "rendering driver identity",
        )
        identities[evidence.RENDERING_DRIVER_IDENTITY] = dict(rendering_identity)
    try:
        return evidence.validate_runner_identities(identities)
    except evidence.EvidenceError as error:
        raise ConfigError(str(error)) from error


def validate_request_index(
    value: Any,
    identity: RunIdentity,
    corpus: Mapping[str, Any],
) -> dict[str, Any]:
    index = _require_mapping(value, "request index")
    _require_exact_keys(
        index,
        {
            "schema_version",
            "producer_protocol",
            "producer_version",
            "producer_digest",
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "baseline_git_commit",
            "baseline_toolchain_identity",
            "baseline_configuration_digest",
            "baseline_run_configuration",
            "runner_identities",
            "requests",
        },
        "request index",
    )
    expected = {
        "schema_version": 1,
        "producer_protocol": evidence.PROTOCOL_VERSION,
        "producer_version": evidence.PRODUCER_VERSION,
        "producer_digest": evidence.sha256_file(ROOT / evidence.PRODUCER_RELATIVE_PATH),
        "corpus_digest": identity.corpus_digest,
        "thresholds_digest": identity.thresholds_digest,
        "git_commit": identity.git_commit,
        "app_version": identity.app_version,
        "toolchain_identity": identity.toolchain_identity,
        "baseline_git_commit": APPROVED_PAIRED_BASELINE["git_commit"],
        "baseline_toolchain_identity": APPROVED_PAIRED_BASELINE["toolchain_identity"],
        "baseline_configuration_digest": sha256_json(APPROVED_PAIRED_BASELINE["run_configuration"]),
        "baseline_run_configuration": APPROVED_PAIRED_BASELINE["run_configuration"],
    }
    for field, expected_value in expected.items():
        if index[field] != expected_value:
            raise ConfigError(f"request index {field} does not match this run")
    try:
        runner_identities = evidence.validate_runner_identities(index["runner_identities"])
    except evidence.EvidenceError as error:
        raise ConfigError(f"request index runner identities are invalid: {error}") from error

    scenes = {scene["id"]: scene for scene in corpus["scenes"]}
    requests = index["requests"]
    if not isinstance(requests, list):
        raise ConfigError("request index requests must be an array")
    actual_runs: set[tuple[str, int, str]] = set()
    for request_number, raw_request in enumerate(requests):
        label = f"request index requests[{request_number}]"
        entry = _require_mapping(raw_request, label)
        _require_exact_keys(
            entry,
            {
                "scene_id",
                "scale",
                "lane",
                "request",
                "media_path",
                "evidence_path",
                "producer_command",
            },
            label,
        )
        scene_id = _require_safe_token(entry["scene_id"], f"{label}.scene_id")
        scene = scenes.get(scene_id)
        scale = entry["scale"]
        lane = entry["lane"]
        if scene is None or type(scale) is not int or scale not in scene["scale_lanes"]:
            raise ConfigError(f"{label} scene or scale is not declared by the corpus")
        if lane not in required_evidence_lanes(scene, scale):
            raise ConfigError(f"{label}.lane is not required for this scale")
        run = (scene_id, scale, lane)
        if run in actual_runs:
            raise ConfigError(f"{label} duplicates a scene, scale, and lane")
        actual_runs.add(run)
        expected_request_path = f"{scene_id}/{scale}/{lane}.request.json"
        if entry["request"] != expected_request_path:
            raise ConfigError(f"{label}.request is not canonical")
        if entry["media_path"] != scene["input"]["media_path"]:
            raise ConfigError(f"{label}.media_path does not match the corpus")
        if entry["evidence_path"] != scene["adapter"]["evidence_path"]:
            raise ConfigError(f"{label}.evidence_path does not match the corpus")
        if not isinstance(entry["producer_command"], list) or not entry["producer_command"]:
            raise ConfigError(f"{label}.producer_command is invalid")
        for argument in entry["producer_command"]:
            _require_public_text(argument, f"{label}.producer_command argument")
    expected_runs = {
        (scene["id"], scale, lane)
        for scene in corpus["scenes"]
        for scale in scene["scale_lanes"]
        for lane in required_evidence_lanes(scene, scale)
    }
    if actual_runs != expected_runs:
        raise ConfigError("request index does not contain the exact corpus lane closure")
    return {**dict(index), "runner_identities": runner_identities}


def _requirements(
    corpus: Mapping[str, Any],
    corpus_directory: Path,
    evidence_directory: Path,
    toolchain_root: Path,
    profile: str,
    toolchain_identity: str | None,
    evidence_key_path: Path | None,
    request_index_path: Path | None,
) -> dict[str, Any]:
    missing_media = []
    missing_evidence = []
    for scene in corpus["scenes"]:
        media = corpus_directory / scene["input"]["media_path"]
        if not scene["input"]["supplied"] or not media.exists():
            missing_media.append({"scene_id": scene["id"], "path": scene["input"]["media_path"]})
        if scene["adapter"]["type"] == "fixture":
            result = corpus_directory / scene["adapter"]["result_path"]
            if not result.is_file() or result.is_symlink():
                missing_evidence.append({"scene_id": scene["id"], "path": scene["adapter"]["result_path"]})
        else:
            for scale in scene["scale_lanes"]:
                for lane in required_evidence_lanes(scene, scale):
                    relative = (
                        PurePosixPath(scene["adapter"]["evidence_path"])
                        / str(scale)
                        / lane
                        / "attestation.json"
                    ).as_posix()
                    attestation = evidence_directory / Path(*PurePosixPath(relative).parts)
                    if not attestation.is_file() or attestation.is_symlink():
                        missing_evidence.append({"scene_id": scene["id"], "path": relative})
    missing_toolchain = []
    if profile == "release" and toolchain_identity is None:
        missing_toolchain.append("signed receipt or manifest identity")
    toolchain = (
        {"label": "toolchain://resolved", "missing": sorted(set(missing_toolchain))}
        if missing_toolchain
        else None
    )
    missing_key = None
    if profile == "release" and (
        evidence_key_path is None
        or evidence_key_path.is_symlink()
        or not evidence_key_path.is_file()
    ):
        missing_key = "protected evidence key file"
    missing_index = None
    if profile == "release" and (
        request_index_path is None
        or request_index_path.is_symlink()
        or not request_index_path.is_file()
    ):
        missing_index = "protected request index"
    return {
        "media": missing_media,
        "evidence": missing_evidence,
        "toolchain": toolchain,
        "evidence_key": missing_key,
        "request_index": missing_index,
    }


def _result_shell(
    profile: str,
    corpus: Mapping[str, Any],
    config: Mapping[str, Any],
    output_directory: Path,
    started_at: datetime,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "run_id": str(uuid.uuid4()),
        "started_at_utc": started_at.isoformat().replace("+00:00", "Z"),
        "ended_at_utc": None,
        "profile": profile,
        "status": "blocked",
        "blocking_reasons": [],
        "failures": [],
        "scene_results": [],
        "aggregates": {},
        "machine": collect_machine_metadata(),
        "app_version": APP_VERSION,
        "toolchain_identity": None,
        "thresholds_digest": sha256_json(config),
        "corpus_digest": sha256_json(corpus),
        "git": collect_git_state(),
        "raw_artifact_directory": "raw",
        "missing_requirements": {
            "media": [],
            "evidence": [],
            "toolchain": None,
            "evidence_key": None,
            "request_index": None,
        },
    }


def _finish_result(result: dict[str, Any], status: str) -> None:
    result["status"] = status
    result["ended_at_utc"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _validate_string_list(value: Any, label: str) -> None:
    if not isinstance(value, list):
        raise ConfigError(f"{label} must be an array")
    for index, item in enumerate(value):
        _require_public_text(item, f"{label}[{index}]")


def validate_suite_result(result: Any) -> None:
    root = _require_mapping(result, "suite result")
    _require_exact_keys(
        root,
        {
            "schema_version",
            "run_id",
            "started_at_utc",
            "ended_at_utc",
            "profile",
            "status",
            "blocking_reasons",
            "failures",
            "scene_results",
            "aggregates",
            "machine",
            "app_version",
            "toolchain_identity",
            "thresholds_digest",
            "corpus_digest",
            "git",
            "raw_artifact_directory",
            "missing_requirements",
        },
        "suite result",
    )
    if root["schema_version"] != 1 or root["profile"] not in {"smoke", "release"}:
        raise ConfigError("suite result schema or profile is invalid")
    if root["status"] not in {"passed", "failed", "blocked"}:
        raise ConfigError("suite result status is invalid")
    try:
        uuid.UUID(root["run_id"])
    except (AttributeError, TypeError, ValueError) as error:
        raise ConfigError("suite result run_id is invalid") from error
    for key in ("started_at_utc", "ended_at_utc"):
        _require_public_text(root[key], f"suite result.{key}")
    if root["app_version"] != APP_VERSION:
        raise ConfigError("suite result app_version is invalid")
    toolchain_identity = root["toolchain_identity"]
    if toolchain_identity is not None and not (
        toolchain_identity == "fixture:smoke"
        or isinstance(toolchain_identity, str) and SHA256_PATTERN.fullmatch(toolchain_identity)
    ):
        raise ConfigError("suite result toolchain_identity is invalid")
    for key in ("thresholds_digest", "corpus_digest"):
        if not isinstance(root[key], str) or not SHA256_PATTERN.fullmatch(root[key]):
            raise ConfigError(f"suite result.{key} is invalid")
    _validate_string_list(root["blocking_reasons"], "suite result.blocking_reasons")
    _validate_string_list(root["failures"], "suite result.failures")
    if root["raw_artifact_directory"] != "raw":
        raise ConfigError("suite result raw_artifact_directory is invalid")

    git = _require_mapping(root["git"], "suite result.git")
    _require_exact_keys(git, {"commit", "dirty"}, "suite result.git")
    if not isinstance(git["commit"], str) or not re.fullmatch(r"not_available|[0-9a-f]{40}", git["commit"]):
        raise ConfigError("suite result.git.commit is invalid")
    if not isinstance(git["dirty"], bool):
        raise ConfigError("suite result.git.dirty must be boolean")

    machine = _require_mapping(root["machine"], "suite result.machine")
    machine_keys = {
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
    _require_exact_keys(machine, machine_keys, "suite result.machine")
    for key, value in machine.items():
        if isinstance(value, str):
            _require_public_text(value, f"suite result.machine.{key}")
    for key in ("logical_cpus", "physical_cpus", "physical_memory_bytes"):
        if machine[key] is not None and (type(machine[key]) is not int or machine[key] < 0):
            raise ConfigError(f"suite result.machine.{key} is invalid")

    scene_results = root["scene_results"]
    if not isinstance(scene_results, list):
        raise ConfigError("suite result.scene_results must be an array")
    scene_keys = {
        "scene_id",
        "category",
        "capture_traits",
        "scale",
        "aggregate_scale",
        "adapter",
        "status",
        "blocking_reasons",
        "failures",
        "input_kind",
        "expected_outcome",
        "gate_scopes",
        "route",
        "detail_profile",
        "exit",
        "command",
        "metrics",
        "artifacts",
        "evidence",
    }
    for index, raw_scene in enumerate(scene_results):
        label = f"suite result.scene_results[{index}]"
        scene = _require_mapping(raw_scene, label)
        _require_exact_keys(scene, scene_keys, label)
        _require_safe_token(scene["scene_id"], f"{label}.scene_id")
        if scene["category"] not in ALLOWED_CATEGORIES:
            raise ConfigError(f"{label}.category is invalid")
        capture_traits = scene["capture_traits"]
        if (
            not isinstance(capture_traits, list)
            or not capture_traits
            or any(trait not in ALLOWED_CAPTURE_TRAITS for trait in capture_traits)
            or len(capture_traits) != len(set(capture_traits))
            or capture_traits != sorted(capture_traits)
        ):
            raise ConfigError(f"{label}.capture_traits is invalid")
        if scene["scale"] not in ALLOWED_SCALE_LANES:
            raise ConfigError(f"{label}.scale is invalid")
        if scene["aggregate_scale"] not in ALLOWED_SCALE_LANES:
            raise ConfigError(f"{label}.aggregate_scale is invalid")
        if scene["adapter"] not in ALLOWED_ADAPTERS or scene["status"] not in {"passed", "failed", "blocked"}:
            raise ConfigError(f"{label} adapter or status is invalid")
        if scene["input_kind"] not in {"video", "photos", "mixed"}:
            raise ConfigError(f"{label}.input_kind is invalid")
        gate_scopes = scene["gate_scopes"]
        if (
            not isinstance(gate_scopes, list)
            or not gate_scopes
            or any(scope not in ALLOWED_GATE_SCOPES for scope in gate_scopes)
            or len(gate_scopes) != len(set(gate_scopes))
            or gate_scopes != sorted(gate_scopes)
        ):
            raise ConfigError(f"{label}.gate_scopes is invalid")
        expected_outcome = _require_mapping(scene["expected_outcome"], f"{label}.expected_outcome")
        if expected_outcome.get("kind") == "valid":
            _require_exact_keys(expected_outcome, {"kind"}, f"{label}.expected_outcome")
        elif expected_outcome.get("kind") == "invalid":
            _require_exact_keys(expected_outcome, {"kind", "failure_type"}, f"{label}.expected_outcome")
            _require_safe_token(expected_outcome["failure_type"], f"{label}.expected_outcome.failure_type")
        else:
            raise ConfigError(f"{label}.expected_outcome is invalid")
        _require_safe_token(scene["route"], f"{label}.route")
        _require_safe_token(scene["detail_profile"], f"{label}.detail_profile")
        _validate_string_list(scene["blocking_reasons"], f"{label}.blocking_reasons")
        _validate_string_list(scene["failures"], f"{label}.failures")
        exit_evidence = _require_mapping(scene["exit"], f"{label}.exit")
        _require_exact_keys(exit_evidence, {"code", "reason", "cancelled"}, f"{label}.exit")
        _validate_actual_evidence(
            {
                "exit_code": exit_evidence["code"],
                "termination_reason": exit_evidence["reason"],
                "cancelled": exit_evidence["cancelled"],
                "failure_type": None,
                "corrupt_ply": None,
            },
            f"{label}.exit",
        )
        if not isinstance(scene["command"], list) or not scene["command"]:
            raise ConfigError(f"{label}.command is invalid")
        for command_index, argument in enumerate(scene["command"]):
            _require_public_text(argument, f"{label}.command[{command_index}]")
        metric_errors = metric_validation_failures(scene["metrics"])
        if metric_errors:
            raise ConfigError(f"{label}.metrics is invalid: {'; '.join(metric_errors)}")
        _validate_artifacts(scene["artifacts"], f"{label}.artifacts")
        evidence_records = scene["evidence"]
        if not isinstance(evidence_records, list):
            raise ConfigError(f"{label}.evidence must be an array")
        seen_lanes: set[str] = set()
        for evidence_index, raw_evidence in enumerate(evidence_records):
            evidence_label = f"{label}.evidence[{evidence_index}]"
            record = _require_mapping(raw_evidence, evidence_label)
            _require_exact_keys(
                record,
                {"lane", "machine", "producer", "measurement_runner", "attestation_digest"},
                evidence_label,
            )
            lane = record["lane"]
            if lane not in evidence.RELEASE_LANES or lane in seen_lanes:
                raise ConfigError(f"{evidence_label}.lane is invalid")
            seen_lanes.add(lane)
            producer = _require_mapping(record["producer"], f"{evidence_label}.producer")
            _require_exact_keys(
                producer,
                {"protocol_version", "version", "executable", "sha256"},
                f"{evidence_label}.producer",
            )
            if producer["protocol_version"] != evidence.PROTOCOL_VERSION:
                raise ConfigError(f"{evidence_label}.producer protocol is invalid")
            _require_safe_token(producer["version"], f"{evidence_label}.producer.version")
            if producer["executable"] != evidence.PRODUCER_RELATIVE_PATH:
                raise ConfigError(f"{evidence_label}.producer executable is invalid")
            for digest_field, digest_value in (
                ("producer.sha256", producer["sha256"]),
                ("attestation_digest", record["attestation_digest"]),
            ):
                if not isinstance(digest_value, str) or not SHA256_PATTERN.fullmatch(digest_value):
                    raise ConfigError(f"{evidence_label}.{digest_field} is invalid")
            try:
                evidence.validate_runner_identity(record["measurement_runner"], lane)
            except evidence.EvidenceError as error:
                raise ConfigError(f"{evidence_label}.measurement_runner is invalid: {error}") from error
            machine_record = _require_mapping(record["machine"], f"{evidence_label}.machine")
            try:
                evidence.validate_machine_lane(machine_record, lane)
            except evidence.EvidenceError as error:
                raise ConfigError(f"{evidence_label}.machine is invalid: {error}") from error

    aggregates = _require_mapping(root["aggregates"], "suite result.aggregates")
    if aggregates:
        _require_exact_keys(
            aggregates,
            {"scene_scale_runs", "passed", "failed", "blocked", "wall_time_geometric_mean_seconds"},
            "suite result.aggregates",
        )
        for key in ("scene_scale_runs", "passed", "failed", "blocked"):
            if type(aggregates[key]) is not int or aggregates[key] < 0:
                raise ConfigError(f"suite result.aggregates.{key} is invalid")
        errors = metric_validation_failures(
            {"wall_time_seconds": aggregates["wall_time_geometric_mean_seconds"]}
        )
        if errors:
            raise ConfigError("suite result aggregate wall time is invalid")

    missing = _require_mapping(root["missing_requirements"], "suite result.missing_requirements")
    _require_exact_keys(
        missing,
        {"media", "evidence", "toolchain", "evidence_key", "request_index"},
        "suite result.missing_requirements",
    )
    for key in ("media", "evidence"):
        if not isinstance(missing[key], list):
            raise ConfigError(f"suite result.missing_requirements.{key} must be an array")
        for item in missing[key]:
            entry = _require_mapping(item, f"suite result.missing_requirements.{key} entry")
            _require_exact_keys(entry, {"scene_id", "path"}, f"suite result.missing_requirements.{key} entry")
            _require_safe_token(entry["scene_id"], "missing requirement scene_id")
            _safe_relative_path(entry["path"], "missing requirement path")
    if missing["toolchain"] is not None:
        toolchain = _require_mapping(missing["toolchain"], "suite result.missing_requirements.toolchain")
        _require_exact_keys(toolchain, {"label", "missing"}, "suite result.missing_requirements.toolchain")
        if toolchain["label"] != "toolchain://resolved":
            raise ConfigError("suite result toolchain label is invalid")
        _validate_string_list(toolchain["missing"], "suite result.missing_requirements.toolchain.missing")
    if missing["evidence_key"] is not None:
        if missing["evidence_key"] != "protected evidence key file":
            raise ConfigError("suite result missing evidence key label is invalid")
    if missing["request_index"] is not None:
        if missing["request_index"] != "protected request index":
            raise ConfigError("suite result missing request index label is invalid")

    if root["status"] == "passed" and (root["blocking_reasons"] or root["failures"]):
        raise ConfigError("passed suite result contains blockers or failures")
    canonical_json_bytes(root)


def write_suite_result(path: Path, result: Mapping[str, Any]) -> None:
    validate_suite_result(result)
    atomic_write_json(path, result)


def _validate_actual_evidence(actual: Any, label: str) -> Mapping[str, Any]:
    value = _require_mapping(actual, label)
    _require_exact_keys(
        value,
        {"exit_code", "termination_reason", "cancelled", "failure_type", "corrupt_ply"},
        label,
    )
    if value["exit_code"] is not None and type(value["exit_code"]) is not int:
        raise ConfigError(f"{label}.exit_code must be an integer or null")
    if value["termination_reason"] not in {"exit", "signal", "cancelled", "not_available"}:
        raise ConfigError(f"{label}.termination_reason is invalid")
    if not isinstance(value["cancelled"], bool):
        raise ConfigError(f"{label}.cancelled must be boolean")
    if value["failure_type"] is not None:
        _require_safe_token(value["failure_type"], f"{label}.failure_type")
    if value["corrupt_ply"] is not None and not isinstance(value["corrupt_ply"], bool):
        raise ConfigError(f"{label}.corrupt_ply must be boolean or null")
    exit_code = value["exit_code"]
    reason = value["termination_reason"]
    cancelled = value["cancelled"]
    if exit_code is None:
        if reason != "not_available" or cancelled:
            raise ConfigError(f"{label} termination evidence is contradictory")
    elif exit_code == 0:
        if reason != "exit" or cancelled:
            raise ConfigError(f"{label} successful termination evidence is contradictory")
    elif exit_code == 130:
        if reason != "cancelled" or not cancelled:
            raise ConfigError(f"{label} cancellation evidence is contradictory")
    elif cancelled:
        if reason != "cancelled" or exit_code != 130:
            raise ConfigError(f"{label} cancellation evidence is contradictory")
    elif reason == "cancelled" or reason == "not_available":
        raise ConfigError(f"{label} termination evidence is contradictory")
    elif reason == "signal" and exit_code >= 0:
        raise ConfigError(f"{label} signal termination requires a negative exit code")
    elif reason == "exit" and exit_code < 0:
        raise ConfigError(f"{label} normal exit cannot use a negative exit code")
    return value


def _validate_artifacts(artifacts: Any, label: str) -> Mapping[str, str]:
    value = _require_mapping(artifacts, label)
    for name, digest in value.items():
        if not isinstance(name, str) or not ARTIFACT_NAME_PATTERN.fullmatch(name):
            raise ConfigError(f"{label} key must contain only lowercase letters, digits, and underscores")
        if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
            raise ConfigError(f"{label}.{name} must be a SHA-256 digest")
    return value


def _validate_fixture_envelope(
    payload: Any,
    scene: Mapping[str, Any],
    identity: RunIdentity,
    input_digest: str,
) -> Mapping[str, Any]:
    if identity.profile != "smoke":
        raise ConfigError("fixture evidence is smoke-only")
    label = f"fixture result for {scene['id']}"
    value = _require_mapping(payload, label)
    _require_exact_keys(
        value,
        {
            "schema_version",
            "profile",
            "scene_id",
            "input_digest",
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "scale_results",
        },
        label,
    )
    if value["schema_version"] != 1:
        raise ConfigError(f"{label} must use schema_version 1")
    expected = {
        "profile": identity.profile,
        "scene_id": scene["id"],
        "input_digest": input_digest,
        "corpus_digest": identity.corpus_digest,
        "thresholds_digest": identity.thresholds_digest,
        "git_commit": identity.git_commit,
        "app_version": identity.app_version,
        "toolchain_identity": identity.toolchain_identity,
    }
    for key, expected_value in expected.items():
        if value[key] != expected_value:
            raise ConfigError(f"{label} {key} does not match this run")
    scale_results = _require_mapping(value["scale_results"], f"{label}.scale_results")
    unknown_scales = sorted(set(scale_results) - {str(scale) for scale in scene["scale_lanes"]})
    if unknown_scales:
        raise ConfigError(f"{label} contains undeclared scales: {', '.join(unknown_scales)}")
    for scale_key, raw_value in scale_results.items():
        raw_label = f"{label}.scale_results.{scale_key}"
        raw = _require_mapping(raw_value, raw_label)
        _require_exact_keys(
            raw,
            {"scale", "route", "detail_profile", "actual", "metrics", "artifacts"},
            raw_label,
        )
        if raw["scale"] != int(scale_key):
            raise ConfigError(f"{raw_label}.scale does not match its key")
        _require_safe_token(raw["route"], f"{raw_label}.route")
        _require_safe_token(raw["detail_profile"], f"{raw_label}.detail_profile")
        _validate_actual_evidence(raw["actual"], f"{raw_label}.actual")
        metric_errors = metric_validation_failures(raw["metrics"])
        if metric_errors:
            raise ConfigError(f"{raw_label}.metrics is invalid: {'; '.join(metric_errors)}")
        _validate_artifacts(raw["artifacts"], f"{raw_label}.artifacts")
    return value


def _copy_fixture_result(
    scene: Mapping[str, Any],
    scale: int,
    corpus_directory: Path,
    identity: RunIdentity,
    input_digest: str | None = None,
) -> dict[str, Any]:
    source = corpus_directory / scene["adapter"]["result_path"]
    payload = _load_json(source, f"fixture result for {scene['id']}")
    if input_digest is None:
        input_digest = digest_input(
            corpus_directory / scene["input"]["media_path"],
            trusted_root=corpus_directory,
        )
    payload = _validate_fixture_envelope(payload, scene, identity, input_digest)
    scale_results = payload["scale_results"]
    raw = scale_results.get(str(scale))
    if not isinstance(raw, Mapping):
        return {
            "scene_id": scene["id"],
            "category": scene["category"],
            "capture_traits": scene["capture_traits"],
            "scale": scale,
            "aggregate_scale": scene["aggregate_scale"],
            "adapter": "fixture",
            "status": "blocked",
            "blocking_reasons": [f"external result is missing scale {scale}"],
            "failures": [],
            "input_kind": scene["input"]["kind"],
            "expected_outcome": scene["expected_outcome"],
            "gate_scopes": scene["gate_scopes"],
            "route": "fixture",
            "detail_profile": "benchmark",
            "exit": {"code": None, "reason": "not_available", "cancelled": False},
            "command": _redacted_scene_command(scene, scale),
            "metrics": {},
            "artifacts": {},
            "evidence": [],
        }
    actual = raw.get("actual")
    metrics = raw.get("metrics")
    artifacts = raw.get("artifacts", {})
    if scene["expected_outcome"]["kind"] == "invalid":
        evaluation = evaluate_invalid_scene(scene["expected_outcome"], actual if isinstance(actual, Mapping) else {})
    else:
        if actual["exit_code"] is None:
            evaluation = {"status": "blocked", "blocking_reasons": ["exit evidence is unavailable"], "failures": []}
        elif (
            actual["exit_code"] != 0
            or actual["cancelled"]
            or actual["failure_type"] is not None
            or actual["corrupt_ply"] is not False
        ):
            evaluation = {
                "status": "failed",
                "blocking_reasons": [],
                "failures": ["external run did not complete successfully with a valid output"],
            }
        else:
            evaluation = evaluate_gates(
                metrics,
                APPROVED_THRESHOLDS,
                gate_scopes=scene["gate_scopes"],
                scale=scale,
            )
            if identity.profile == "release" and "output_ply" not in artifacts:
                evaluation["status"] = "failed"
                evaluation["failures"].append("release evidence is missing output_ply digest")
    return {
        "scene_id": scene["id"],
        "category": scene["category"],
        "capture_traits": scene["capture_traits"],
        "scale": scale,
        "aggregate_scale": scene["aggregate_scale"],
        "adapter": "fixture",
        "status": evaluation["status"],
        "blocking_reasons": evaluation["blocking_reasons"],
        "failures": evaluation["failures"],
        "input_kind": scene["input"]["kind"],
        "expected_outcome": scene["expected_outcome"],
        "gate_scopes": scene["gate_scopes"],
        "route": raw.get("route", "fixture"),
        "detail_profile": raw.get("detail_profile", "benchmark"),
        "exit": {
            "code": actual.get("exit_code") if isinstance(actual, Mapping) else None,
            "reason": actual.get("termination_reason", "exit") if isinstance(actual, Mapping) else "not_available",
            "cancelled": actual.get("cancelled", False) if isinstance(actual, Mapping) else False,
        },
        "command": _redacted_scene_command(scene, scale),
        "metrics": dict(metrics) if isinstance(metrics, Mapping) else {},
        "artifacts": dict(artifacts) if isinstance(artifacts, Mapping) else {},
        "evidence": [],
    }


def _evidence_request(
    scene: Mapping[str, Any],
    scale: int,
    lane: str,
    identity: RunIdentity,
    input_digest: str,
    rendering_driver_identity: Mapping[str, str],
) -> dict[str, Any]:
    if lane not in required_evidence_lanes(scene, scale):
        raise ConfigError(f"{scene['id']}@{scale} does not support the {lane} evidence lane")

    traits = set(scene["capture_traits"])
    input_kind = scene["input"]["kind"]
    if input_kind == "photos" or "unordered" in traits:
        topology = "unordered"
        capture_path = "automatic"
        temporal_pairing = "none"
        temporal_offsets: list[int] = []
        pairing_policy = "unordered_exhaustive" if scale <= 60 else "unordered_retrieval"
        vocabulary_candidates = 0 if scale <= 60 else 20
        vocabulary_neighbors = 0 if scale <= 60 else 8
        vocabulary_stride = 1
        ba_ratio = 1.1
    elif input_kind == "mixed" or "segmented" in traits:
        topology = "segmented_mixed"
        capture_path = "automatic"
        temporal_pairing = "linear"
        temporal_offsets = [1, 2, 3, 4, 5, 6]
        pairing_policy = "segmented_mixed"
        vocabulary_candidates = 20
        vocabulary_neighbors = 8
        vocabulary_stride = 1
        ba_ratio = 1.1
    elif scene["category"] == "object_orbit":
        topology = "continuous"
        capture_path = "around_subject"
        temporal_pairing = "multiscale"
        temporal_offsets = [offset for offset in (1, 2, 4, 8, 16, 32, 64, 128) if offset < scale]
        pairing_policy = "object_orbit"
        vocabulary_candidates = 20 if scale >= 120 else 0
        vocabulary_neighbors = 2 if scale >= 120 else 0
        vocabulary_stride = 5
        ba_ratio = 1.4
    elif scene["category"] == "interior_walkthrough":
        topology = "continuous"
        capture_path = "through_space"
        temporal_pairing = "linear"
        temporal_offsets = [offset for offset in range(1, 7) if offset < scale]
        pairing_policy = "walkthrough"
        vocabulary_candidates = 20
        vocabulary_neighbors = 2
        vocabulary_stride = 10
        ba_ratio = 1.4
    elif scene["category"] == "large_area_exterior":
        topology = "continuous"
        capture_path = "large_area"
        temporal_pairing = "multiscale"
        temporal_offsets = [offset for offset in (1, 2, 4, 8, 16, 32, 64, 128) if offset < scale]
        pairing_policy = "large_area"
        vocabulary_candidates = 20
        vocabulary_neighbors = 4
        vocabulary_stride = 10
        ba_ratio = 1.4
    else:
        topology = "continuous"
        capture_path = "automatic"
        temporal_pairing = "multiscale"
        temporal_offsets = [offset for offset in (1, 2, 4, 8, 16, 32, 64, 128) if offset < scale]
        pairing_policy = "generic_continuous"
        vocabulary_candidates = 20 if scale >= 120 else 0
        vocabulary_neighbors = 2 if scale >= 120 else 0
        vocabulary_stride = 10
        ba_ratio = 1.4

    detail_profile = "balanced" if lane == evidence.LANE_REFERENCE else "fast"
    split = scene["split"]
    references = scene["reference"]
    if scene["expected_outcome"]["kind"] == "invalid":
        if split != {"status": "not_applicable"} or references != {
            "status": "not_applicable"
        }:
            raise ConfigError(
                f"{scene['id']} invalid evidence must not claim rendering or pose references"
            )
        holdout_indices: list[int] = []
        reference_artifacts = {"status": "not_applicable"}
    else:
        if split.get("status") != "pinned" or references.get("status") != "pinned":
            raise ConfigError(f"{scene['id']} cannot emit protected evidence with pending references")
        holdout_indices = list(split["holdout_by_scale"][str(scale)])
        reference_artifacts = dict(references["by_scale"][str(scale)])
    candidate_configuration = {
        "detail_profile": detail_profile,
        "selected_frame_count": scale,
        "capture_path": capture_path,
        "input_topology": topology,
        "camera_grouping": "automatic",
        "lens_projection": "fisheye" if "fisheye" in traits else "automatic",
        "resource_policy": "automatic" if lane == evidence.LANE_REFERENCE else "conserve_memory",
        "compute_policy": "metal_for_supported_stages",
        "pairing_policy": pairing_policy,
        "temporal_pairing": temporal_pairing,
        "temporal_offsets": temporal_offsets,
        "vocabulary_candidate_count": vocabulary_candidates,
        "vocabulary_verified_neighbor_count": vocabulary_neighbors,
        "vocabulary_query_stride": vocabulary_stride,
        "descriptor_matcher": "faiss",
        "ba_global_frames_ratio": ba_ratio,
        "ba_global_points_ratio": ba_ratio,
        "ba_global_max_refinements": 5,
        "trainer_iterations": 7_000 if detail_profile == "balanced" else 3_000,
        "trainer_plateau_window": 800 if detail_profile == "balanced" else 400,
        "deterministic_seed": 42,
    }
    return {
        "schema_version": 2,
        "binding": {
            "profile": identity.profile,
            "scene_id": scene["id"],
            "scale": scale,
            "lane": lane,
            "input_digest": input_digest,
            "corpus_digest": identity.corpus_digest,
            "thresholds_digest": identity.thresholds_digest,
            "git_commit": identity.git_commit,
            "app_version": identity.app_version,
            "toolchain_identity": identity.toolchain_identity,
            "baseline_git_commit": APPROVED_PAIRED_BASELINE["git_commit"],
            "baseline_toolchain_identity": APPROVED_PAIRED_BASELINE["toolchain_identity"],
            "baseline_configuration_digest": sha256_json(APPROVED_PAIRED_BASELINE["run_configuration"]),
        },
        "baseline_run_configuration": APPROVED_PAIRED_BASELINE["run_configuration"],
        "candidate_run_configuration": candidate_configuration,
        "category": scene["category"],
        "capture_traits": scene["capture_traits"],
        "holdout_indices": holdout_indices,
        "reference_artifacts": reference_artifacts,
        "timing_basis": "selected_view_count",
        "expected_outcome": scene["expected_outcome"],
        "input_kind": scene["input"]["kind"],
        "gate_scopes": scene["gate_scopes"],
        "rendering_driver_identity": evidence.validate_runner_identity(
            rendering_driver_identity,
            evidence.RENDERING_DRIVER_IDENTITY,
        ),
    }


def _required_lane_metric(metrics: Mapping[str, Any], name: str, blocking: list[str]) -> Any:
    raw = metrics.get(name)
    if not isinstance(raw, Mapping) or raw.get("availability") != "measured":
        blocking.append(f"required {name} evidence is unavailable")
        return None
    return raw.get("value")


def _evaluate_protected_attestations(
    scene: Mapping[str, Any],
    scale: int,
    attestations: Mapping[str, Mapping[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    expected = scene["expected_outcome"]
    reference = attestations[evidence.LANE_REFERENCE]
    if expected["kind"] == "invalid":
        evaluations = [evaluate_invalid_scene(expected, item["actual"]) for item in attestations.values()]
        failures = [failure for item in evaluations for failure in item["failures"]]
        blocking = [reason for item in evaluations for reason in item["blocking_reasons"]]
        return (
            {
                "status": "blocked" if blocking else "failed" if failures else "passed",
                "blocking_reasons": blocking,
                "failures": failures,
            },
            dict(reference["metrics"]),
        )

    failures: list[str] = []
    blocking: list[str] = []
    for lane, attestation in attestations.items():
        actual = attestation["actual"]
        try:
            _validate_actual_evidence(actual, f"{lane} actual evidence")
        except ConfigError:
            blocking.append(f"{lane} termination evidence is invalid")
            continue
        if (
            actual["exit_code"] != 0
            or actual["cancelled"]
            or actual["failure_type"] is not None
            or actual["corrupt_ply"] is not False
        ):
            failures.append(f"{lane} run did not complete with a valid output")

    reference_metrics = dict(reference["metrics"])
    gate_evaluation = evaluate_gates(
        reference_metrics,
        APPROVED_THRESHOLDS,
        gate_scopes=scene["gate_scopes"],
        scale=scale,
    )
    failures.extend(gate_evaluation["failures"])
    blocking.extend(gate_evaluation["blocking_reasons"])

    if "suite_performance" in scene["gate_scopes"]:
        low_memory_timing_contracts = (
            (
                evidence.LANE_CONSTRAINED,
                "constrained_fast_p50_seconds",
                APPROVED_THRESHOLDS["speed"]["constrained_fast_p50_seconds_max_by_scale"],
            ),
            (
                evidence.LANE_EIGHT_GB,
                "eight_gb_fast_p50_seconds",
                APPROVED_THRESHOLDS["speed"]["eight_gb_fast_p50_seconds_max_by_scale"],
            ),
        )
        for lane, metric_name, limits in low_memory_timing_contracts:
            limit = limits.get(str(scale))
            if limit is None:
                continue
            attestation = attestations.get(lane)
            if attestation is None:
                blocking.append(f"required {lane} timing attestation is unavailable")
                continue
            value = _required_lane_metric(attestation["metrics"], metric_name, blocking)
            if value is not None and value > limit:
                failures.append(f"{lane} {metric_name} exceeds {limit}")

    if "scene_performance" in scene["gate_scopes"]:
        lane_contracts = (
            (
                evidence.LANE_REFERENCE,
                "larger",
                None,
            ),
        )
        if evidence.LANE_CONSTRAINED in attestations:
            lane_contracts += (
                (
                    evidence.LANE_CONSTRAINED,
                    "constrained",
                    APPROVED_THRESHOLDS["memory"]["constrained_bytes_max"],
                ),
            )
        if evidence.LANE_EIGHT_GB in attestations:
            lane_contracts += (
                (
                    evidence.LANE_EIGHT_GB,
                    "eight_gb_fast",
                    APPROVED_THRESHOLDS["memory"]["eight_gb_fast_bytes_max"],
                ),
            )
        for lane, expected_memory_lane, maximum_peak in lane_contracts:
            attestation = attestations[lane]
            metrics = attestation["metrics"]
            memory_lane = _required_lane_metric(metrics, "memory_lane", blocking)
            machine_memory = _required_lane_metric(metrics, "machine_memory_bytes", blocking)
            peak_memory = _required_lane_metric(metrics, "peak_memory_bytes", blocking)
            if memory_lane is not None and memory_lane != expected_memory_lane:
                failures.append(f"{lane} reports the wrong memory lane")
            physical_memory = attestation["machine"].get("physical_memory_bytes")
            if machine_memory is not None and machine_memory != physical_memory:
                failures.append(f"{lane} memory metric does not match the attested machine")
            if maximum_peak is not None and peak_memory is not None and peak_memory > maximum_peak:
                failures.append(f"{lane} peak memory exceeds {maximum_peak}")

    return (
        {
            "status": "blocked" if blocking else "failed" if failures else "passed",
            "blocking_reasons": blocking,
            "failures": failures,
        },
        reference_metrics,
    )


def _copy_protected_evidence(
    scene: Mapping[str, Any],
    scale: int,
    corpus_directory: Path,
    identity: RunIdentity,
    input_digest: str,
    key: bytes,
    runner_identities: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    evidence_root = corpus_directory / scene["adapter"]["evidence_path"] / str(scale)
    attestations: dict[str, Mapping[str, Any]] = {}
    summaries = []
    artifacts: dict[str, str] = {}
    verification_failures = []
    for lane in required_evidence_lanes(scene, scale):
        request = _evidence_request(
            scene,
            scale,
            lane,
            identity,
            input_digest,
            runner_identities[evidence.RENDERING_DRIVER_IDENTITY],
        )
        path = evidence_root / lane / "attestation.json"
        try:
            attestation = evidence.verify_attestation(
                path,
                request,
                lane,
                key,
                runner_identities[lane],
            )
        except evidence.EvidenceError as error:
            verification_failures.append(f"{lane} evidence rejected: {error}")
            continue
        metric_errors = metric_validation_failures(attestation["metrics"])
        if metric_errors:
            verification_failures.append(f"{lane} metrics invalid: {'; '.join(metric_errors)}")
            continue
        attestations[lane] = attestation
        summaries.append(
            {
                "lane": lane,
                "machine": dict(attestation["machine"]),
                "producer": dict(attestation["producer"]),
                "measurement_runner": dict(attestation["measurement_runner"]),
                "attestation_digest": evidence.sha256_file(path),
            }
        )
        for name, descriptor in attestation["artifacts"].items():
            output_name = f"{lane}_{name}".replace(".", "_").replace("-", "_")
            if ARTIFACT_NAME_PATTERN.fullmatch(output_name):
                artifacts[output_name] = descriptor["sha256"]

    if verification_failures:
        evaluation = {"status": "failed", "blocking_reasons": [], "failures": verification_failures}
        metrics: dict[str, Any] = {}
    else:
        evaluation, metrics = _evaluate_protected_attestations(scene, scale, attestations)
    reference = attestations.get(evidence.LANE_REFERENCE)
    actual = reference.get("actual", {}) if isinstance(reference, Mapping) else {}
    try:
        _validate_actual_evidence(actual, "reference evidence")
    except ConfigError:
        actual = {}
    return {
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
        "command": _redacted_scene_command(scene, scale),
        "metrics": metrics,
        "artifacts": artifacts,
        "evidence": summaries,
    }


def emit_evidence_requests(
    corpus: Mapping[str, Any],
    config: Mapping[str, Any],
    corpus_path: Path,
    toolchain_root: Path,
    destination: Path,
    runner_identities: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    try:
        approved_runners = evidence.validate_runner_identities(runner_identities)
    except evidence.EvidenceError as error:
        raise ConfigError(f"cannot emit requests without complete runner identities: {error}") from error
    toolchain_identity = resolved_toolchain_identity(toolchain_root, "release")
    if toolchain_identity is None:
        raise ConfigError("cannot emit evidence requests without a resolved toolchain identity")
    git = collect_git_state()
    if git["dirty"]:
        raise ConfigError("cannot emit release evidence requests from a dirty Git worktree")
    identity = make_run_identity("release", corpus, config, toolchain_root, toolchain_identity)
    input_digests: dict[str, str] = {}
    input_digest_owners: dict[str, str] = {}
    for scene in corpus["scenes"]:
        media = corpus_path.parent / scene["input"]["media_path"]
        if not scene["input"]["supplied"] or not media.exists():
            raise ConfigError(f"cannot emit evidence request without media for {scene['id']}")
        input_digests[scene["id"]] = digest_input(
            media,
            trusted_root=corpus_path.parent,
        )
        _record_unique_release_input_digest(
            scene,
            input_digests[scene["id"]],
            input_digest_owners,
        )

    destination.mkdir(parents=True, exist_ok=True)
    requests = []
    for scene in corpus["scenes"]:
        for scale in scene["scale_lanes"]:
            for lane in required_evidence_lanes(scene, scale):
                request = _evidence_request(
                    scene,
                    scale,
                    lane,
                    identity,
                    input_digests[scene["id"]],
                    approved_runners[evidence.RENDERING_DRIVER_IDENTITY],
                )
                relative = Path(scene["id"]) / str(scale) / f"{lane}.request.json"
                atomic_write_json(destination / relative, request)
                requests.append(
                    {
                        "scene_id": scene["id"],
                        "scale": scale,
                        "lane": lane,
                        "request": relative.as_posix(),
                        "media_path": scene["input"]["media_path"],
                        "evidence_path": scene["adapter"]["evidence_path"],
                        "producer_command": [
                            "python3",
                            evidence.PRODUCER_RELATIVE_PATH,
                            "produce",
                            "--request",
                            f"requests://{relative.as_posix()}",
                            "--observations",
                            "evidence://observations.json",
                            "--artifact-root",
                            "evidence://run",
                            "--output",
                            f"evidence://{lane}/attestation.json",
                            "--lane",
                            lane,
                            "--runner-label",
                            approved_runners[lane]["label"],
                            "--runner-sha256",
                            approved_runners[lane]["sha256"],
                            "--key-file",
                            "protected://evidence-key",
                        ],
                    }
                )
    index = {
        "schema_version": 1,
        "producer_protocol": evidence.PROTOCOL_VERSION,
        "producer_version": evidence.PRODUCER_VERSION,
        "producer_digest": evidence.sha256_file(ROOT / evidence.PRODUCER_RELATIVE_PATH),
        "corpus_digest": identity.corpus_digest,
        "thresholds_digest": identity.thresholds_digest,
        "git_commit": identity.git_commit,
        "app_version": identity.app_version,
        "toolchain_identity": identity.toolchain_identity,
        "baseline_git_commit": APPROVED_PAIRED_BASELINE["git_commit"],
        "baseline_toolchain_identity": APPROVED_PAIRED_BASELINE["toolchain_identity"],
        "baseline_configuration_digest": sha256_json(APPROVED_PAIRED_BASELINE["run_configuration"]),
        "baseline_run_configuration": APPROVED_PAIRED_BASELINE["run_configuration"],
        "runner_identities": approved_runners,
        "requests": requests,
    }
    atomic_write_json(destination / "index.json", index)
    return index


def _geometric_mean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def evaluate_suite_performance(
    results: Iterable[Mapping[str, Any]],
    thresholds: Mapping[str, Any],
) -> dict[str, Any]:
    selected = [
        result
        for result in results
        if result.get("expected_outcome") == {"kind": "valid"}
        and "suite_performance" in result.get("gate_scopes", [])
    ]
    if not selected:
        return {
            "status": "blocked",
            "blocking_reasons": ["suite performance has no valid scoped runs"],
            "failures": [],
        }

    blocking: list[str] = []
    failures: list[str] = []

    def speedup(result: Mapping[str, Any], name: str) -> float | None:
        label = f"{result.get('scene_id', 'unknown')}@{result.get('scale', 'unknown')}"
        metrics = result.get("metrics")
        raw = metrics.get(name) if isinstance(metrics, Mapping) else None
        if not isinstance(raw, Mapping) or raw.get("availability") != "measured":
            blocking.append(f"{label}: required suite metric not available: {name}")
            return None
        value = raw.get("value")
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value <= 0
        ):
            failures.append(f"{label}: {name} must be positive and finite")
            return None
        return float(value)

    primary = [result for result in selected if result.get("scale") == result.get("aggregate_scale")]
    if len(primary) != len({result.get("scene_id") for result in selected}):
        blocking.append("suite performance is missing an exact primary scale for one or more scenes")
    geometry_by_category: dict[str, list[float]] = {}
    geometry_values: list[float] = []
    matching_values: list[float] = []
    ordered_mapping: list[float] = []
    unordered_mapping: list[tuple[str, float]] = []
    matching_scales = set(thresholds["speed"]["matching_speedup_scales"])
    matching_scales_present: set[int] = set()
    for result in selected:
        category = result.get("category")
        traits = result.get("capture_traits")
        if category not in ALLOWED_CATEGORIES or not isinstance(traits, list):
            blocking.append("suite performance result is missing category or capture traits")
            continue
        geometry = (
            speedup(result, "balanced_geometry_speedup")
            if result.get("scale") == result.get("aggregate_scale")
            else None
        )
        if geometry is not None:
            geometry_values.append(geometry)
            geometry_by_category.setdefault(str(category), []).append(geometry)
        if result.get("scale") in matching_scales:
            matching_scales_present.add(result["scale"])
            matching = speedup(result, "matching_speedup")
            if matching is not None:
                matching_values.append(matching)
                if matching < 1.0:
                    failures.append(
                        f"{result.get('scene_id')}@{result.get('scale')}: matching is slower than baseline"
                    )
        if result.get("scale") != result.get("aggregate_scale"):
            continue
        mapping = speedup(result, "mapping_speedup")
        if mapping is None:
            continue
        if "unordered" in traits or "segmented" in traits:
            unordered_mapping.append((str(result.get("scene_id")), mapping))
        elif "ordered" in traits:
            ordered_mapping.append(mapping)
        else:
            blocking.append(
                f"{result.get('scene_id')}@{result.get('scale')}: mapping topology is not declared"
            )

    speed = thresholds["speed"]
    if geometry_values and _geometric_mean(geometry_values) < speed["geometry_geometric_mean_speedup_min"]:
        failures.append("suite geometry geometric-mean speedup is below minimum")
    for category, values in geometry_by_category.items():
        if statistics.median(values) < speed["category_median_geometry_speedup_min"]:
            failures.append(f"{category} median geometry speedup is below minimum")
    if matching_scales_present != matching_scales:
        blocking.append(
            "matching speedup evidence must cover exactly scales "
            + ", ".join(str(value) for value in sorted(matching_scales))
        )
    if not matching_values:
        blocking.append("matching speedup evidence is unavailable at required scales")
    elif _geometric_mean(matching_values) < speed["matching_geometric_mean_speedup_min"]:
        failures.append("matching geometric-mean speedup is below minimum")
    if not ordered_mapping:
        blocking.append("ordered mapping speedup evidence is unavailable")
    elif _geometric_mean(ordered_mapping) < speed["ordered_mapping_speedup_min"]:
        failures.append("ordered mapping geometric-mean speedup is below minimum")
    minimum_unordered_speedup = 1.0 / (1.0 + speed["unordered_mapping_regression_max_fraction"])
    if not unordered_mapping:
        blocking.append("unordered or segmented mapping speedup evidence is unavailable")
    for scene_id, mapping in unordered_mapping:
        if mapping < minimum_unordered_speedup:
            failures.append(f"{scene_id}: unordered mapping regresses more than allowed")

    return {
        "status": "blocked" if blocking else "failed" if failures else "passed",
        "blocking_reasons": blocking,
        "failures": failures,
    }


def evaluate_suite_quality(
    results: Iterable[Mapping[str, Any]],
    thresholds: Mapping[str, Any],
) -> dict[str, Any]:
    scoped = [
        result
        for result in results
        if result.get("expected_outcome") == {"kind": "valid"}
        and "scene_quality" in result.get("gate_scopes", [])
    ]
    if not scoped:
        return {
            "status": "blocked",
            "blocking_reasons": ["suite quality has no scoped scene evidence"],
            "failures": [],
        }
    blocking: list[str] = []
    failures: list[str] = []
    selected = [
        result for result in scoped if result.get("scale") == result.get("aggregate_scale")
    ]
    primary_counts: dict[str, int] = {}
    for result in selected:
        scene_id = str(result.get("scene_id"))
        primary_counts[scene_id] = primary_counts.get(scene_id, 0) + 1
    scoped_scene_ids = {str(result.get("scene_id")) for result in scoped}
    invalid_primary = sorted(
        scene_id for scene_id in scoped_scene_ids if primary_counts.get(scene_id) != 1
    )
    if invalid_primary:
        blocking.append(
            "suite quality requires exactly one primary scale for: " + ", ".join(invalid_primary)
        )

    def values(name: str) -> tuple[list[float], dict[str, list[float]]]:
        measured_values: list[float] = []
        by_category: dict[str, list[float]] = {}
        for result in selected:
            category = result.get("category")
            if category not in ALLOWED_CATEGORIES or category == "invalid":
                blocking.append(
                    f"{result.get('scene_id')}: suite quality category is unavailable"
                )
                continue
            raw = result.get("metrics", {}).get(name)
            if not isinstance(raw, Mapping) or raw.get("availability") != "measured":
                blocking.append(f"{result.get('scene_id')}: suite quality metric unavailable: {name}")
                continue
            value = raw.get("value")
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or value < 0
            ):
                failures.append(f"{result.get('scene_id')}: {name} must be finite and nonnegative")
                continue
            numeric = float(value)
            measured_values.append(numeric)
            by_category.setdefault(str(category), []).append(numeric)
        return measured_values, by_category

    checks = (
        ("balanced_scene_psnr_loss_db", thresholds["balanced_rendering"]["median_psnr_loss_db_max"]),
        ("balanced_scene_ssim_loss", thresholds["balanced_rendering"]["median_ssim_loss_max"]),
        ("balanced_scene_lpips_increase", thresholds["balanced_rendering"]["median_lpips_increase_max"]),
        (
            "paired_balanced_scene_psnr_loss_db",
            thresholds["paired_baseline_rendering"]["median_psnr_loss_db_max"],
        ),
        (
            "paired_balanced_scene_ssim_loss",
            thresholds["paired_baseline_rendering"]["median_ssim_loss_max"],
        ),
        (
            "paired_balanced_scene_lpips_increase",
            thresholds["paired_baseline_rendering"]["median_lpips_increase_max"],
        ),
    )
    for name, limit in checks:
        metric_values, category_values = values(name)
        if metric_values and statistics.median(metric_values) > limit:
            failures.append(f"suite median {name} exceeds maximum {limit}")
        for category, measured_values in sorted(category_values.items()):
            if statistics.median(measured_values) > limit:
                failures.append(f"{category} median {name} exceeds maximum {limit}")
    return {
        "status": "blocked" if blocking else "failed" if failures else "passed",
        "blocking_reasons": blocking,
        "failures": failures,
    }


def _aggregate_scene_results(results: list[Mapping[str, Any]]) -> dict[str, Any]:
    wall_values = []
    for result in results:
        metric = result.get("metrics", {}).get("wall_time_seconds") if isinstance(result.get("metrics"), Mapping) else None
        if isinstance(metric, Mapping) and metric.get("availability") == "measured":
            value = metric.get("value")
            if isinstance(value, (int, float)) and value > 0:
                wall_values.append(float(value))
    geometric_mean = None
    if wall_values:
        geometric_mean = _geometric_mean(wall_values)
    return {
        "scene_scale_runs": len(results),
        "passed": sum(result.get("status") == "passed" for result in results),
        "failed": sum(result.get("status") == "failed" for result in results),
        "blocked": sum(result.get("status") == "blocked" for result in results),
        "wall_time_geometric_mean_seconds": measured(geometric_mean) if geometric_mean is not None else unavailable(),
    }


def run_suite(
    profile: str,
    corpus_path: Path,
    reference_config_path: Path,
    toolchain_root: Path,
    output_directory: Path,
    dry_run: bool,
    stdout: TextIO = sys.stdout,
    evidence_key_path: Path | None = None,
    emit_requests_directory: Path | None = None,
    evidence_root: Path | None = None,
    request_index_path: Path | None = None,
    runner_identities: Mapping[str, Mapping[str, Any]] | None = None,
) -> int:
    corpus = _load_json(corpus_path, "corpus")
    config = _load_json(reference_config_path, "reference config")
    validate_corpus(corpus, expected_profile=profile)
    validate_reference_config(config)
    if emit_requests_directory is not None:
        if profile != "release" or dry_run:
            raise ConfigError("--emit-requests requires a non-dry-run release profile")
        index = emit_evidence_requests(
            corpus,
            config,
            corpus_path,
            toolchain_root,
            emit_requests_directory,
            runner_identities or {},
        )
        stdout.write(
            canonical_json_bytes(
                {"status": "requests_emitted", "count": len(index["requests"]), "index": "index.json"}
            ).decode("utf-8")
            + "\n"
        )
        return 0
    if dry_run:
        stdout.write(canonical_json_bytes(build_dry_run_plan(profile, corpus, config, toolchain_root)).decode("utf-8") + "\n")
        return 0

    started_at = datetime.now(timezone.utc)
    output_directory.mkdir(parents=True, exist_ok=True)
    raw_directory = output_directory / "raw"
    raw_directory.mkdir(parents=True, exist_ok=True)
    result = _result_shell(profile, corpus, config, output_directory, started_at)
    toolchain_identity = resolved_toolchain_identity(toolchain_root, profile)
    result["toolchain_identity"] = toolchain_identity
    requirements = _requirements(
        corpus,
        corpus_path.parent,
        evidence_root or corpus_path.parent,
        toolchain_root,
        profile,
        toolchain_identity,
        evidence_key_path,
        request_index_path,
    )
    result["missing_requirements"] = requirements
    missing_labels = []
    if requirements["media"]:
        missing_labels.append(f"missing media for {len(requirements['media'])} scene(s)")
    if requirements["evidence"]:
        missing_labels.append(f"missing protected evidence for {len(requirements['evidence'])} run(s)")
    if requirements["toolchain"]:
        missing_labels.append("resolved toolchain is unavailable")
    if requirements["evidence_key"]:
        missing_labels.append("protected evidence key is unavailable")
    if requirements["request_index"]:
        missing_labels.append("protected request index is unavailable")
    if profile == "release" and result["git"]["dirty"]:
        missing_labels.append("release benchmark requires a clean Git worktree")
    if missing_labels:
        result["blocking_reasons"] = missing_labels
        _finish_result(result, "blocked")
        write_suite_result(output_directory / "suite.json", result)
        stdout.write(canonical_json_bytes({"status": "blocked", "result": str(output_directory / "suite.json")}).decode("utf-8") + "\n")
        return 2

    scene_results = []
    identity = make_run_identity(
        profile,
        corpus,
        config,
        toolchain_root,
        toolchain_identity,
    )
    result["toolchain_identity"] = identity.toolchain_identity
    evidence_key = evidence.load_key(evidence_key_path) if profile == "release" and evidence_key_path else None
    approved_runners: dict[str, dict[str, str]] = {}
    if profile == "release":
        if request_index_path is None:
            raise ConfigError("protected request index is unavailable")
        request_index = validate_request_index(
            _load_json(request_index_path, "request index"),
            identity,
            corpus,
        )
        approved_runners = request_index["runner_identities"]
    input_digests: dict[str, str] = {}
    input_digest_owners: dict[str, str] = {}
    for scene in corpus["scenes"]:
        input_digests[scene["id"]] = digest_input(
            corpus_path.parent / scene["input"]["media_path"],
            trusted_root=corpus_path.parent,
        )
        if profile == "release":
            _record_unique_release_input_digest(
                scene,
                input_digests[scene["id"]],
                input_digest_owners,
            )
        for scale in scene["scale_lanes"]:
            if scene["adapter"]["type"] == "fixture":
                scene_result = _copy_fixture_result(
                    scene,
                    scale,
                    corpus_path.parent,
                    identity,
                    input_digests[scene["id"]],
                )
            else:
                if evidence_key is None:
                    raise ConfigError("protected evidence key is unavailable")
                scene_result = _copy_protected_evidence(
                    scene,
                    scale,
                    evidence_root or corpus_path.parent,
                    identity,
                    input_digests[scene["id"]],
                    evidence_key,
                    approved_runners,
                )
            scene_results.append(scene_result)
    result["scene_results"] = scene_results
    result["aggregates"] = _aggregate_scene_results(scene_results)
    result["blocking_reasons"] = [
        f"{item['scene_id']}@{item['scale']}: {reason}"
        for item in scene_results
        for reason in item["blocking_reasons"]
    ]
    result["failures"] = [
        f"{item['scene_id']}@{item['scale']}: {failure}"
        for item in scene_results
        for failure in item["failures"]
    ]
    if profile == "release":
        suite_performance = evaluate_suite_performance(scene_results, APPROVED_THRESHOLDS)
        suite_quality = evaluate_suite_quality(scene_results, APPROVED_THRESHOLDS)
        result["blocking_reasons"].extend(
            f"suite performance: {reason}" for reason in suite_performance["blocking_reasons"]
        )
        result["failures"].extend(
            f"suite performance: {failure}" for failure in suite_performance["failures"]
        )
        result["blocking_reasons"].extend(
            f"suite quality: {reason}" for reason in suite_quality["blocking_reasons"]
        )
        result["failures"].extend(
            f"suite quality: {failure}" for failure in suite_quality["failures"]
        )
    status = "blocked" if result["blocking_reasons"] else "failed" if result["failures"] else "passed"
    _finish_result(result, status)
    write_suite_result(output_directory / "suite.json", result)
    stdout.write(canonical_json_bytes({"status": status, "result": str(output_directory / "suite.json")}).decode("utf-8") + "\n")
    return 0 if status == "passed" else 2 if status == "blocked" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("smoke", "release"), required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--reference-config", type=Path, required=True)
    parser.add_argument("--toolchain-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-key-file", type=Path)
    parser.add_argument("--emit-requests", type=Path)
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--request-index", type=Path)
    parser.add_argument("--runner-identity", action="append")
    parser.add_argument("--rendering-driver-identity", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_suite(
            profile=args.profile,
            corpus_path=args.corpus,
            reference_config_path=args.reference_config,
            toolchain_root=args.toolchain_root,
            output_directory=args.output,
            dry_run=args.dry_run,
            evidence_key_path=args.evidence_key_file,
            emit_requests_directory=args.emit_requests,
            evidence_root=args.evidence_root,
            request_index_path=args.request_index,
            runner_identities=parse_runner_identities(
                args.runner_identity,
                args.rendering_driver_identity,
            ),
        )
    except (ConfigError, evidence.EvidenceError) as error:
        print(f"benchmark configuration error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
