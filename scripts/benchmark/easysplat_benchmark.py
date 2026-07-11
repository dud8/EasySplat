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
from typing import Any, Callable, Iterable, Mapping, TextIO


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


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


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
    failures: list[str] = []
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
    if not isinstance(colmap_registered, (int, float)) or colmap_registered <= 0:
        failures.append("colmap_registered_views must be positive")
    elif registered / colmap_registered < thresholds["coverage"]["colmap_relative_min"]:
        failures.append("coverage.colmap_relative is below minimum")

    if values["residual_provenance"] != "track_reprojection":
        failures.append("residual_provenance is not real track reprojection")
    maximum("residual_median_pixels", thresholds["residual_pixels"]["median_max"])
    maximum("residual_p90_pixels", thresholds["residual_pixels"]["p90_max"])
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

    minimum("repeat_runs", thresholds["stability"]["repeat_runs_min"])
    maximum("crashes", thresholds["stability"]["crashes_max"])
    maximum("corrupt_outputs", thresholds["stability"]["corrupt_outputs_max"])
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
    if "failure_type" not in actual:
        return {"status": "blocked", "blocking_reasons": ["typed failure outcome is unavailable"], "failures": []}
    failures: list[str] = []
    if actual.get("exit_code") == 0:
        failures.append("invalid scene unexpectedly succeeded")
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
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"{label} not found: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise ConfigError(f"{label} is not valid JSON: {path}: {error}") from error


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
            if not result.is_file():
                missing_results.append({"scene_id": scene["id"], "path": scene["adapter"]["result_path"]})
        else:
            requires_toolchain = True
    toolchain = None
    if requires_toolchain:
        required = [
            toolchain_root / "bin/colmap",
            toolchain_root / "da3_mps/bin/easysplat_da3_sfm",
            toolchain_root / "da3_mps/models",
        ]
        absent = [path.relative_to(toolchain_root).as_posix() for path in required if not path.exists()]
        if absent:
            toolchain = {"label": "toolchain://resolved", "missing": absent}
    elif profile == "release" and not toolchain_root.exists():
        toolchain = {"label": "toolchain://resolved", "missing": ["root"]}
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
        "thresholds_digest": sha256_json(config),
        "corpus_digest": sha256_json(corpus),
        "git": collect_git_state(),
        "raw_artifact_directory": "raw",
        "missing_requirements": {"media": [], "external_results": [], "toolchain": None},
    }


def _finish_result(result: dict[str, Any], status: str) -> None:
    result["status"] = status
    result["ended_at_utc"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _copy_external_result(scene: Mapping[str, Any], scale: int, corpus_directory: Path) -> dict[str, Any]:
    source = corpus_directory / scene["adapter"]["result_path"]
    payload = _load_json(source, f"external result for {scene['id']}")
    if not isinstance(payload, Mapping) or payload.get("schema_version") != 1:
        raise ConfigError(f"external result for {scene['id']} must use schema_version 1")
    scale_results = payload.get("scale_results")
    if not isinstance(scale_results, Mapping):
        raise ConfigError(f"external result for {scene['id']} has no scale_results")
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
        if not isinstance(metrics, Mapping):
            evaluation = {"status": "blocked", "blocking_reasons": ["metrics are unavailable"], "failures": []}
            metrics = {}
        else:
            evaluation = evaluate_gates(metrics, APPROVED_THRESHOLDS)
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
        actual = {
            "exit_code": completed.returncode,
            "failure_type": "disconnected_input" if completed.returncode else None,
            "corrupt_ply": False,
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
        "exit": {"code": completed.returncode, "reason": "exit", "cancelled": completed.returncode == 130},
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
    requirements = _requirements(corpus, corpus_path.parent, toolchain_root, profile)
    result["missing_requirements"] = requirements
    missing_labels = []
    if requirements["media"]:
        missing_labels.append(f"missing media for {len(requirements['media'])} scene(s)")
    if requirements["external_results"]:
        missing_labels.append(f"missing external results for {len(requirements['external_results'])} scene(s)")
    if requirements["toolchain"]:
        missing_labels.append("resolved toolchain is unavailable")
    if missing_labels:
        result["blocking_reasons"] = missing_labels
        _finish_result(result, "blocked")
        atomic_write_json(output_directory / "suite.json", result)
        stdout.write(canonical_json_bytes({"status": "blocked", "result": str(output_directory / "suite.json")}).decode("utf-8") + "\n")
        return 2

    scene_results = []
    for scene in corpus["scenes"]:
        for scale in scene["scale_lanes"]:
            if scene["adapter"]["type"] == "external-result":
                scene_result = _copy_external_result(scene, scale, corpus_path.parent)
            else:
                scene_result = _run_da3(scene, scale, corpus_path.parent, toolchain_root, raw_directory)
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
    atomic_write_json(output_directory / "suite.json", result)
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
