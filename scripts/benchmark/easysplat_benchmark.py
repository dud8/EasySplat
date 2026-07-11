#!/usr/bin/env python3
"""Machine-readable Apple Silicon benchmark and release-gate harness."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Mapping, NamedTuple, TextIO


ROOT = Path(__file__).resolve().parents[2]
ALLOWED_CATEGORIES = {
    "object_orbit",
    "interior_walkthrough",
    "professional_photos",
    "exterior_drone",
    "low_light",
    "invalid",
}
RELEASE_CATEGORY_COUNTS = {
    "object_orbit": 6,
    "interior_walkthrough": 6,
    "professional_photos": 4,
    "exterior_drone": 4,
    "low_light": 3,
    "invalid": 3,
}
ALLOWED_SCALE_LANES = {30, 120, 250, 500, 3_000}
ALLOWED_ADAPTERS = {"da3", "external-result"}
APP_VERSION = "0.2.0-beta.1"
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
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
    "points",
    "observations",
    "streaming_sustained_frames",
    "peak_memory_bytes",
    "machine_memory_bytes",
    "repeat_runs",
    "crashes",
    "corrupt_outputs",
    "normal_photo_toolchain_bytes",
    "streaming_toolchain_bytes",
    "max_resident_set_size_bytes",
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
    "fast_end_to_end_speedup",
    "m4_max_p50_seconds",
    "balanced_geometry_speedup",
    "constrained_fast_p50_seconds",
    "streaming_inference_fps",
    "wall_time_seconds",
    "geometry_seconds",
    "training_seconds",
}
BOOLEAN_METRICS = {
    "finished_v1_opens",
    "valid_v1_geometry_retrains",
    "deterministic_restart",
}
ENUM_METRICS = {
    "residual_provenance": {"track_reprojection"},
    "memory_lane": {"eight_gb_fast", "constrained", "larger"},
}
ALLOWED_METRICS = (
    NONNEGATIVE_INTEGER_METRICS
    | NONNEGATIVE_NUMBER_METRICS
    | BOOLEAN_METRICS
    | set(ENUM_METRICS)
)

APPROVED_THRESHOLDS: dict[str, Any] = {
    "coverage": {"absolute_min": 0.90, "colmap_relative_min": 0.95},
    "residual_pixels": {"median_max": 1.5, "p90_max": 3.0},
    "pose": {
        "ate_colmap_ratio_max": 1.10,
        "rotation_rpe_delta_degrees_max": 0.2,
        "translation_rpe_delta_percentage_points_max": 2.0,
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
    "speed": {
        "m4_max_p50_seconds_max": 120.0,
        "balanced_speedup_min": 2.0,
        "constrained_fast_p50_seconds_max": 300.0,
    },
    "streaming": {"inference_fps_min": 5.0, "sustained_frames_min": 3_000},
    "memory": {
        "eight_gb_fast_bytes_max": 6_500_000_000,
        "constrained_bytes_max": 12_000_000_000,
        "larger_fraction_max": 0.75,
    },
    "stability": {"repeat_runs_min": 50, "crashes_max": 0, "corrupt_outputs_max": 0},
    "toolchain": {
        "normal_photo_bytes_max": 2_500_000_000,
        "streaming_bytes_max": 6_000_000_000,
    },
    "compatibility": {
        "finished_v1_opens_required": True,
        "valid_v1_geometry_retrains_required": True,
        "deterministic_restart_required": True,
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
                "license",
                "provenance",
                "input",
                "scale_lanes",
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

        license_info = _require_mapping(scene["license"], f"{label}.license")
        _require_exact_keys(license_info, {"name", "url", "redistributable"}, f"{label}.license")
        _require_nonempty_string(license_info["name"], f"{label}.license.name")
        license_url = _require_nonempty_string(license_info["url"], f"{label}.license.url")
        if not license_url.startswith("https://"):
            raise ConfigError(f"{label}.license.url must use HTTPS")
        if not isinstance(license_info["redistributable"], bool):
            raise ConfigError(f"{label}.license.redistributable must be boolean")

        provenance = _require_mapping(scene["provenance"], f"{label}.provenance")
        _require_exact_keys(provenance, {"source", "consent"}, f"{label}.provenance")
        _require_nonempty_string(provenance["source"], f"{label}.provenance.source")
        _require_nonempty_string(provenance["consent"], f"{label}.provenance.consent")

        input_info = _require_mapping(scene["input"], f"{label}.input")
        _require_exact_keys(input_info, {"kind", "media_path", "supplied"}, f"{label}.input")
        if input_info["kind"] not in {"video", "photos", "mixed"}:
            raise ConfigError(f"{label}.input.kind is unsupported")
        _safe_relative_path(input_info["media_path"], "media path")
        if not isinstance(input_info["supplied"], bool):
            raise ConfigError(f"{label}.input.supplied must be boolean")

        lanes = scene["scale_lanes"]
        if (
            not isinstance(lanes, list)
            or not lanes
            or any(type(value) is not int or value not in ALLOWED_SCALE_LANES for value in lanes)
            or len(lanes) != len(set(lanes))
            or lanes != sorted(lanes)
        ):
            raise ConfigError(f"{label}.scale lane list is invalid")

        split = _require_mapping(scene["split"], f"{label}.split")
        _require_exact_keys(split, {"train", "holdout"}, f"{label}.split")
        train = split["train"]
        holdout = split["holdout"]
        for split_name, values in (("train", train), ("holdout", holdout)):
            if (
                not isinstance(values, list)
                or not values
                or any(type(value) is not int or value < 0 for value in values)
                or len(values) != len(set(values))
            ):
                raise ConfigError(f"{label}.split.{split_name} is invalid")
        if set(train) & set(holdout):
            raise ConfigError(f"{label}.split train/holdout overlap")

        reference = _require_mapping(scene["reference"], f"{label}.reference")
        _require_exact_keys(
            reference,
            {"ground_truth_poses", "accurate_colmap", "rendering_reference"},
            f"{label}.reference",
        )
        if any(not isinstance(value, bool) for value in reference.values()):
            raise ConfigError(f"{label}.reference values must be boolean")
        if not input_info["supplied"] and any(reference.values()):
            raise ConfigError(f"{label} unsupplied input cannot claim reference availability")

        expected = _require_mapping(scene["expected_outcome"], f"{label}.expected_outcome")
        kind = expected.get("kind")
        if kind == "valid":
            _require_exact_keys(expected, {"kind"}, f"{label}.expected_outcome")
            if category == "invalid":
                raise ConfigError(f"{label} invalid category must declare an invalid outcome")
        elif kind == "invalid":
            _require_exact_keys(expected, {"kind", "failure_type"}, f"{label}.expected_outcome")
            _require_nonempty_string(expected["failure_type"], f"{label}.expected_outcome.failure_type")
            if category != "invalid":
                raise ConfigError(f"{label} valid category cannot declare an invalid outcome")
        else:
            raise ConfigError(f"{label}.expected_outcome.kind is invalid")

        adapter = _require_mapping(scene["adapter"], f"{label}.adapter")
        adapter_type = adapter.get("type")
        if adapter_type not in ALLOWED_ADAPTERS:
            raise ConfigError(f"{label}.adapter type is unsupported")
        if adapter_type == "external-result":
            _require_exact_keys(adapter, {"type", "result_path"}, f"{label}.adapter")
            _safe_relative_path(adapter["result_path"], "result path")
        else:
            _require_exact_keys(adapter, {"type"}, f"{label}.adapter")
            if input_info["kind"] != "video":
                raise ConfigError(f"{label}.adapter da3 requires video input")

    if expected_profile == "release" and counts != RELEASE_CATEGORY_COUNTS:
        raise ConfigError(f"release category counts must be {RELEASE_CATEGORY_COUNTS}, got {counts}")


def validate_reference_config(config: Any) -> None:
    root = _require_mapping(config, "reference config")
    _require_exact_keys(root, {"schema_version", "references", "thresholds"}, "reference config")
    if root["schema_version"] != 1:
        raise ConfigError("reference config schema_version must be 1")
    references = _require_mapping(root["references"], "references")
    _require_exact_keys(references, {"accurate_colmap", "rendering"}, "references")
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
            if reason is not None:
                try:
                    _require_public_text(reason, f"{name}.reason")
                except ConfigError as error:
                    failures.append(str(error))
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


def parse_time_l(stderr: str) -> dict[str, Any]:
    def parse(label: str) -> Any:
        match = re.search(rf"^\s*(\d+)\s+{re.escape(label)}\s*$", stderr, re.MULTILINE | re.IGNORECASE)
        return int(match.group(1)) if match else unavailable()

    return {
        "max_resident_set_size_bytes": parse("maximum resident set size"),
        "peak_memory_footprint_bytes": parse("peak memory footprint"),
    }


def _metric(metrics: Mapping[str, Any], name: str, blocking: list[str]) -> Any:
    raw = metrics.get(name)
    if not isinstance(raw, Mapping) or raw.get("availability") != "measured" or "value" not in raw:
        blocking.append(f"required metric not available: {name}")
        return None
    return raw["value"]


def evaluate_gates(metrics: Mapping[str, Any], thresholds: Mapping[str, Any]) -> dict[str, Any]:
    blocking: list[str] = []
    failures = metric_validation_failures(metrics)
    if failures:
        return {"status": "failed", "blocking_reasons": [], "failures": failures}
    values = {name: _metric(metrics, name, blocking) for name in (
        "registered_views",
        "total_views",
        "colmap_registered_views",
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
        "fast_end_to_end_speedup",
        "m4_max_p50_seconds",
        "balanced_geometry_speedup",
        "constrained_fast_p50_seconds",
        "streaming_inference_fps",
        "streaming_sustained_frames",
        "peak_memory_bytes",
        "machine_memory_bytes",
        "memory_lane",
        "repeat_runs",
        "crashes",
        "corrupt_outputs",
        "normal_photo_toolchain_bytes",
        "streaming_toolchain_bytes",
        "finished_v1_opens",
        "valid_v1_geometry_retrains",
        "deterministic_restart",
    )}
    if blocking:
        return {"status": "blocked", "blocking_reasons": blocking, "failures": failures}

    def maximum(name: str, limit: float) -> None:
        if not isinstance(values[name], (int, float)) or isinstance(values[name], bool) or values[name] > limit:
            failures.append(f"{name} exceeds maximum {limit}")

    def minimum(name: str, limit: float) -> None:
        if not isinstance(values[name], (int, float)) or isinstance(values[name], bool) or values[name] < limit:
            failures.append(f"{name} is below minimum {limit}")

    total = values["total_views"]
    registered = values["registered_views"]
    colmap_registered = values["colmap_registered_views"]
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
        ("balanced_median_psnr_loss_db", "median_psnr_loss_db_max"),
        ("balanced_median_ssim_loss", "median_ssim_loss_max"),
        ("balanced_median_lpips_increase", "median_lpips_increase_max"),
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
    minimum("fast_end_to_end_speedup", thresholds["fast_rendering"]["end_to_end_speedup_min"])
    maximum("m4_max_p50_seconds", thresholds["speed"]["m4_max_p50_seconds_max"])
    minimum("balanced_geometry_speedup", thresholds["speed"]["balanced_speedup_min"])
    maximum("constrained_fast_p50_seconds", thresholds["speed"]["constrained_fast_p50_seconds_max"])
    minimum("streaming_inference_fps", thresholds["streaming"]["inference_fps_min"])
    minimum("streaming_sustained_frames", thresholds["streaming"]["sustained_frames_min"])

    lane = values["memory_lane"]
    if lane == "eight_gb_fast":
        maximum("peak_memory_bytes", thresholds["memory"]["eight_gb_fast_bytes_max"])
    elif lane == "constrained":
        maximum("peak_memory_bytes", thresholds["memory"]["constrained_bytes_max"])
    elif lane == "larger":
        maximum(
            "peak_memory_bytes",
            values["machine_memory_bytes"] * thresholds["memory"]["larger_fraction_max"],
        )
    else:
        failures.append("memory_lane is unsupported")
    if values["peak_memory_bytes"] > values["machine_memory_bytes"]:
        failures.append("peak_memory_bytes exceeds machine_memory_bytes")

    minimum("repeat_runs", thresholds["stability"]["repeat_runs_min"])
    maximum("crashes", thresholds["stability"]["crashes_max"])
    maximum("corrupt_outputs", thresholds["stability"]["corrupt_outputs_max"])
    if values["crashes"] > values["repeat_runs"]:
        failures.append("crashes exceeds repeat_runs")
    if values["corrupt_outputs"] > values["repeat_runs"]:
        failures.append("corrupt_outputs exceeds repeat_runs")
    maximum("normal_photo_toolchain_bytes", thresholds["toolchain"]["normal_photo_bytes_max"])
    maximum("streaming_toolchain_bytes", thresholds["toolchain"]["streaming_bytes_max"])
    for name in ("finished_v1_opens", "valid_v1_geometry_retrains", "deterministic_restart"):
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
    if adapter == "da3":
        return [
            "scripts/benchmark_da3.sh",
            "--video",
            f"corpus://{scene['id']}",
            "--frame-count",
            str(scale),
            "--profile",
            "single",
            "--da3-tool",
            "toolchain://da3",
            "--da3-models-dir",
            "toolchain://da3-models",
            "--colmap-bin",
            "toolchain://colmap",
        ]
    return ["external-result", f"corpus://{scene['id']}", "--scale", str(scale)]


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


def _sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def _hash_length_prefixed(hasher: Any, value: bytes) -> None:
    hasher.update(len(value).to_bytes(8, "big"))
    hasher.update(value)


def digest_input(path: Path) -> str:
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


def resolved_toolchain_identity(toolchain_root: Path, profile: str) -> str | None:
    if profile == "smoke":
        return "fixture:smoke"
    for name in ("signed_receipt.json", "toolchain_receipt.json", "manifest.json"):
        candidate = toolchain_root / name
        if candidate.is_file() and not candidate.is_symlink():
            return _sha256_file(candidate)
    return None


def make_run_identity(
    profile: str,
    corpus: Mapping[str, Any],
    config: Mapping[str, Any],
    toolchain_root: Path,
) -> RunIdentity:
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


def _requirements(
    corpus: Mapping[str, Any],
    corpus_directory: Path,
    toolchain_root: Path,
    profile: str,
) -> dict[str, Any]:
    missing_media = []
    missing_results = []
    requires_toolchain = False
    for scene in corpus["scenes"]:
        media = corpus_directory / scene["input"]["media_path"]
        if not scene["input"]["supplied"] or not media.exists():
            missing_media.append({"scene_id": scene["id"], "path": scene["input"]["media_path"]})
        if scene["adapter"]["type"] == "external-result":
            result = corpus_directory / scene["adapter"]["result_path"]
            if not result.is_file() or result.is_symlink():
                missing_results.append({"scene_id": scene["id"], "path": scene["adapter"]["result_path"]})
        else:
            requires_toolchain = True
    missing_toolchain = []
    if requires_toolchain:
        required = [
            toolchain_root / "bin/colmap",
            toolchain_root / "da3_mps/bin/easysplat_da3_sfm",
            toolchain_root / "da3_mps/models",
        ]
        missing_toolchain.extend(path.relative_to(toolchain_root).as_posix() for path in required if not path.exists())
    if profile == "release" and resolved_toolchain_identity(toolchain_root, profile) is None:
        missing_toolchain.append("signed receipt or manifest identity")
    toolchain = (
        {"label": "toolchain://resolved", "missing": sorted(set(missing_toolchain))}
        if missing_toolchain
        else None
    )
    return {"media": missing_media, "external_results": missing_results, "toolchain": toolchain}


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
        "missing_requirements": {"media": [], "external_results": [], "toolchain": None},
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
        "scale",
        "adapter",
        "status",
        "blocking_reasons",
        "failures",
        "input_kind",
        "expected_outcome",
        "route",
        "detail_profile",
        "exit",
        "command",
        "metrics",
        "artifacts",
    }
    for index, raw_scene in enumerate(scene_results):
        label = f"suite result.scene_results[{index}]"
        scene = _require_mapping(raw_scene, label)
        _require_exact_keys(scene, scene_keys, label)
        _require_safe_token(scene["scene_id"], f"{label}.scene_id")
        if scene["scale"] not in ALLOWED_SCALE_LANES:
            raise ConfigError(f"{label}.scale is invalid")
        if scene["adapter"] not in ALLOWED_ADAPTERS or scene["status"] not in {"passed", "failed", "blocked"}:
            raise ConfigError(f"{label} adapter or status is invalid")
        if scene["input_kind"] not in {"video", "photos", "mixed"}:
            raise ConfigError(f"{label}.input_kind is invalid")
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
    _require_exact_keys(missing, {"media", "external_results", "toolchain"}, "suite result.missing_requirements")
    for key in ("media", "external_results"):
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
    return value


def _validate_artifacts(artifacts: Any, label: str) -> Mapping[str, str]:
    value = _require_mapping(artifacts, label)
    for name, digest in value.items():
        _require_safe_token(name, f"{label} key")
        if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
            raise ConfigError(f"{label}.{name} must be a SHA-256 digest")
    return value


def _validate_external_envelope(
    payload: Any,
    scene: Mapping[str, Any],
    identity: RunIdentity,
    input_digest: str,
) -> Mapping[str, Any]:
    label = f"external result for {scene['id']}"
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


def _copy_external_result(
    scene: Mapping[str, Any],
    scale: int,
    corpus_directory: Path,
    identity: RunIdentity,
    input_digest: str | None = None,
) -> dict[str, Any]:
    source = corpus_directory / scene["adapter"]["result_path"]
    payload = _load_json(source, f"external result for {scene['id']}")
    if input_digest is None:
        input_digest = digest_input(corpus_directory / scene["input"]["media_path"])
    payload = _validate_external_envelope(payload, scene, identity, input_digest)
    scale_results = payload["scale_results"]
    raw = scale_results.get(str(scale))
    if not isinstance(raw, Mapping):
        return {
            "scene_id": scene["id"],
            "scale": scale,
            "adapter": "external-result",
            "status": "blocked",
            "blocking_reasons": [f"external result is missing scale {scale}"],
            "failures": [],
            "input_kind": scene["input"]["kind"],
            "expected_outcome": scene["expected_outcome"],
            "route": "external-result",
            "detail_profile": "benchmark",
            "exit": {"code": None, "reason": "not_available", "cancelled": False},
            "command": _redacted_scene_command(scene, scale),
            "metrics": {},
            "artifacts": {},
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
            evaluation = evaluate_gates(metrics, APPROVED_THRESHOLDS)
            if identity.profile == "release" and "output_ply" not in artifacts:
                evaluation["status"] = "failed"
                evaluation["failures"].append("release evidence is missing output_ply digest")
    return {
        "scene_id": scene["id"],
        "scale": scale,
        "adapter": "external-result",
        "status": evaluation["status"],
        "blocking_reasons": evaluation["blocking_reasons"],
        "failures": evaluation["failures"],
        "input_kind": scene["input"]["kind"],
        "expected_outcome": scene["expected_outcome"],
        "route": raw.get("route", "external-result"),
        "detail_profile": raw.get("detail_profile", "benchmark"),
        "exit": {
            "code": actual.get("exit_code") if isinstance(actual, Mapping) else None,
            "reason": actual.get("termination_reason", "exit") if isinstance(actual, Mapping) else "not_available",
            "cancelled": actual.get("cancelled", False) if isinstance(actual, Mapping) else False,
        },
        "command": _redacted_scene_command(scene, scale),
        "metrics": dict(metrics) if isinstance(metrics, Mapping) else {},
        "artifacts": dict(artifacts) if isinstance(artifacts, Mapping) else {},
    }


def _run_da3(
    scene: Mapping[str, Any],
    scale: int,
    corpus_directory: Path,
    toolchain_root: Path,
    raw_directory: Path,
    expected_input_digest: str,
) -> dict[str, Any]:
    scene_directory = raw_directory / scene["id"] / f"{scale}-frames"
    scene_directory.mkdir(parents=True, exist_ok=True)
    media = corpus_directory / scene["input"]["media_path"]
    command = [
        "/usr/bin/time",
        "-l",
        str(ROOT / "scripts/benchmark_da3.sh"),
        "--video",
        str(media),
        "--out",
        str(scene_directory),
        "--frame-count",
        str(scale),
        "--profile",
        "single",
        "--da3-tool",
        str(toolchain_root / "da3_mps/bin/easysplat_da3_sfm"),
        "--da3-models-dir",
        str(toolchain_root / "da3_mps/models"),
        "--colmap-bin",
        str(toolchain_root / "bin/colmap"),
    ]
    started = time.monotonic()
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    wall = time.monotonic() - started
    termination_reason = (
        "cancelled" if completed.returncode == 130 else "signal" if completed.returncode < 0 else "exit"
    )
    (scene_directory / "stdout.log").write_text(completed.stdout, encoding="utf-8")
    (scene_directory / "stderr.log").write_text(completed.stderr, encoding="utf-8")
    atomic_write_json(
        scene_directory / "command.json",
        {"argv": _redacted_scene_command(scene, scale), "exit_code": completed.returncode},
    )
    time_metrics = parse_time_l(completed.stderr)
    summary_path = scene_directory / f"{scale}-frames/summary.json"
    summary = _load_json(summary_path, "DA3 summary") if summary_path.is_file() else {}
    metrics = {
        "wall_time_seconds": measured(wall),
        "max_resident_set_size_bytes": measured(time_metrics["max_resident_set_size_bytes"])
        if isinstance(time_metrics["max_resident_set_size_bytes"], int)
        else unavailable(),
        "peak_memory_bytes": measured(time_metrics["peak_memory_footprint_bytes"])
        if isinstance(time_metrics["peak_memory_footprint_bytes"], int)
        else unavailable(),
        "registered_views": measured(summary["registered_images"])
        if isinstance(summary, Mapping) and isinstance(summary.get("registered_images"), int)
        else unavailable(),
        "total_views": measured(scale),
        "points": measured(summary["points"])
        if isinstance(summary, Mapping) and isinstance(summary.get("points"), int)
        else unavailable(),
        "observations": measured(summary["observations"])
        if isinstance(summary, Mapping) and isinstance(summary.get("observations"), int)
        else unavailable(),
    }
    if scene["expected_outcome"]["kind"] == "invalid":
        failure_type = None
        for line in reversed((completed.stdout + "\n" + completed.stderr).splitlines()):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, Mapping) and isinstance(event.get("failure_type"), str):
                candidate = event["failure_type"]
                if SAFE_TOKEN_PATTERN.fullmatch(candidate):
                    failure_type = candidate
                    break
        ply_exists = any(path.is_file() for path in scene_directory.rglob("*.ply"))
        actual = {
            "exit_code": completed.returncode,
            "termination_reason": termination_reason,
            "cancelled": completed.returncode == 130,
            "failure_type": failure_type,
            "corrupt_ply": ply_exists,
        }
        evaluation = evaluate_invalid_scene(scene["expected_outcome"], actual)
    elif completed.returncode != 0:
        evaluation = {
            "status": "failed",
            "blocking_reasons": [],
            "failures": [f"DA3 adapter exited {completed.returncode}"],
        }
    else:
        evaluation = {
            "status": "blocked",
            "blocking_reasons": ["DA3 adapter does not yet provide all release metrics"],
            "failures": [],
        }
    if digest_input(media) != expected_input_digest:
        evaluation["status"] = "failed"
        evaluation["blocking_reasons"] = []
        evaluation["failures"].append("benchmark input changed during the DA3 run")
    return {
        "scene_id": scene["id"],
        "scale": scale,
        "adapter": "da3",
        "status": evaluation["status"],
        "blocking_reasons": evaluation["blocking_reasons"],
        "failures": evaluation["failures"],
        "input_kind": scene["input"]["kind"],
        "expected_outcome": scene["expected_outcome"],
        "route": "da3-anchored",
        "detail_profile": "geometry-only",
        "exit": {
            "code": completed.returncode,
            "reason": termination_reason,
            "cancelled": completed.returncode == 130,
        },
        "command": _redacted_scene_command(scene, scale),
        "metrics": metrics,
        "artifacts": {},
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
        geometric_mean = math.exp(sum(math.log(value) for value in wall_values) / len(wall_values))
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
) -> int:
    corpus = _load_json(corpus_path, "corpus")
    config = _load_json(reference_config_path, "reference config")
    validate_corpus(corpus, expected_profile=profile)
    validate_reference_config(config)
    if dry_run:
        stdout.write(canonical_json_bytes(build_dry_run_plan(profile, corpus, config, toolchain_root)).decode("utf-8") + "\n")
        return 0

    started_at = datetime.now(timezone.utc)
    output_directory.mkdir(parents=True, exist_ok=True)
    raw_directory = output_directory / "raw"
    raw_directory.mkdir(parents=True, exist_ok=True)
    result = _result_shell(profile, corpus, config, output_directory, started_at)
    result["toolchain_identity"] = resolved_toolchain_identity(toolchain_root, profile)
    requirements = _requirements(corpus, corpus_path.parent, toolchain_root, profile)
    result["missing_requirements"] = requirements
    missing_labels = []
    if requirements["media"]:
        missing_labels.append(f"missing media for {len(requirements['media'])} scene(s)")
    if requirements["external_results"]:
        missing_labels.append(f"missing external results for {len(requirements['external_results'])} scene(s)")
    if requirements["toolchain"]:
        missing_labels.append("resolved toolchain is unavailable")
    if profile == "release" and result["git"]["dirty"]:
        missing_labels.append("release benchmark requires a clean Git worktree")
    if missing_labels:
        result["blocking_reasons"] = missing_labels
        _finish_result(result, "blocked")
        write_suite_result(output_directory / "suite.json", result)
        stdout.write(canonical_json_bytes({"status": "blocked", "result": str(output_directory / "suite.json")}).decode("utf-8") + "\n")
        return 2

    scene_results = []
    identity = make_run_identity(profile, corpus, config, toolchain_root)
    result["toolchain_identity"] = identity.toolchain_identity
    input_digests: dict[str, str] = {}
    for scene in corpus["scenes"]:
        input_digests[scene["id"]] = digest_input(corpus_path.parent / scene["input"]["media_path"])
        for scale in scene["scale_lanes"]:
            if scene["adapter"]["type"] == "external-result":
                scene_result = _copy_external_result(
                    scene,
                    scale,
                    corpus_path.parent,
                    identity,
                    input_digests[scene["id"]],
                )
            else:
                scene_result = _run_da3(
                    scene,
                    scale,
                    corpus_path.parent,
                    toolchain_root,
                    raw_directory,
                    input_digests[scene["id"]],
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
        )
    except ConfigError as error:
        print(f"benchmark configuration error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
