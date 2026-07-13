#!/usr/bin/env python3
"""Derive and seal benchmark evidence from raw measurements.

Release metrics are never accepted directly from a corpus manifest. A protected
runner records raw observations and command logs, then invokes this program to
derive the gate metrics and authenticate the resulting machine attestation.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping


PROTOCOL_VERSION = 1
PRODUCER_VERSION = "1.0.0"
PRODUCER_RELATIVE_PATH = "scripts/benchmark/evidence_protocol.py"
LANE_REFERENCE = "reference_m4_max"
LANE_CONSTRAINED = "constrained_14_16gb"
LANE_EIGHT_GB = "eight_gb_fast"
RELEASE_LANES = {LANE_REFERENCE, LANE_CONSTRAINED, LANE_EIGHT_GB}
RUNNER_LABELS = {
    LANE_REFERENCE: "reference-measurement-runner",
    LANE_CONSTRAINED: "constrained-measurement-runner",
    LANE_EIGHT_GB: "eight-gb-measurement-runner",
}
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
HMAC_PATTERN = re.compile(r"^hmac-sha256:[0-9a-f]{64}$")
SAFE_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")


class EvidenceError(ValueError):
    """Raw evidence is incomplete, inconsistent, or unsafe."""


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


def validate_runner_identity(value: Any, lane: str) -> dict[str, str]:
    identity = _mapping(value, f"{lane} measurement runner")
    _exact_keys(identity, {"label", "sha256"}, f"{lane} measurement runner")
    expected_label = RUNNER_LABELS.get(lane)
    if expected_label is None or identity["label"] != expected_label:
        raise EvidenceError(f"{lane} measurement runner label is invalid")
    return {
        "label": expected_label,
        "sha256": _digest(identity["sha256"], f"{lane} measurement runner sha256"),
    }


def validate_runner_identities(value: Any) -> dict[str, dict[str, str]]:
    identities = _mapping(value, "measurement runner identities")
    _exact_keys(identities, RELEASE_LANES, "measurement runner identities")
    return {lane: validate_runner_identity(identities[lane], lane) for lane in sorted(RELEASE_LANES)}


def _finite_numbers(value: Any, label: str, *, nonempty: bool = True) -> list[float]:
    if not isinstance(value, list) or (nonempty and not value):
        raise EvidenceError(f"{label} must be a nonempty array")
    result: list[float] = []
    for item in value:
        if isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item) or item < 0:
            raise EvidenceError(f"{label} must contain finite nonnegative numbers")
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


def measured(value: Any) -> dict[str, Any]:
    return {"availability": "measured", "value": value}


def unavailable(reason: str = "not_measured") -> dict[str, Any]:
    return {"availability": "not_available", "reason": reason}


def _paired_losses(
    records: Any,
    label: str,
) -> tuple[list[float], list[float], list[float]]:
    if not isinstance(records, list) or not records:
        raise EvidenceError(f"{label} must be a nonempty array")
    psnr: list[float] = []
    ssim: list[float] = []
    lpips: list[float] = []
    fields = {
        "candidate_psnr",
        "reference_psnr",
        "candidate_ssim",
        "reference_ssim",
        "candidate_lpips",
        "reference_lpips",
    }
    for index, raw in enumerate(records):
        record = _mapping(raw, f"{label}[{index}]")
        _exact_keys(record, fields, f"{label}[{index}]")
        values = {}
        for field in fields:
            number = record[field]
            if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number):
                raise EvidenceError(f"{label}[{index}].{field} must be finite")
            values[field] = float(number)
        psnr.append(max(0.0, values["reference_psnr"] - values["candidate_psnr"]))
        ssim.append(max(0.0, values["reference_ssim"] - values["candidate_ssim"]))
        lpips.append(max(0.0, values["candidate_lpips"] - values["reference_lpips"]))
    return psnr, ssim, lpips


def _timing_metrics(timing: Mapping[str, Any], lane: str) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    candidate = _finite_numbers(timing.get("candidate_end_to_end_seconds"), "timing.candidate_end_to_end_seconds")
    candidate_median = statistics.median(candidate)
    metrics["wall_time_seconds"] = measured(candidate_median)
    if lane == LANE_REFERENCE:
        baseline = _finite_numbers(timing.get("baseline_end_to_end_seconds"), "timing.baseline_end_to_end_seconds")
        candidate_geometry = _finite_numbers(timing.get("candidate_geometry_seconds"), "timing.candidate_geometry_seconds")
        baseline_geometry = _finite_numbers(timing.get("baseline_geometry_seconds"), "timing.baseline_geometry_seconds")
        metrics.update(
            {
                "m4_max_p50_seconds": measured(candidate_median),
                "fast_end_to_end_speedup": measured(statistics.median(baseline) / candidate_median),
                "balanced_geometry_speedup": measured(
                    statistics.median(baseline_geometry) / statistics.median(candidate_geometry)
                ),
                "geometry_seconds": measured(statistics.median(candidate_geometry)),
            }
        )
        training = timing.get("training_seconds")
        if training is not None:
            metrics["training_seconds"] = measured(
                statistics.median(_finite_numbers(training, "timing.training_seconds"))
            )
    elif lane == LANE_CONSTRAINED:
        metrics["constrained_fast_p50_seconds"] = measured(candidate_median)
    return metrics


def derive_metrics(
    observations: Mapping[str, Any],
    lane: str,
    machine: Mapping[str, Any],
    artifact_sizes: Mapping[str, int],
    *,
    full_reference: bool = True,
) -> dict[str, Any]:
    """Derive gate metrics from raw samples; aggregate metrics are not accepted."""
    if lane not in RELEASE_LANES:
        raise EvidenceError("unsupported benchmark lane")
    metrics = _timing_metrics(_mapping(observations.get("timing"), "observations.timing"), lane)
    memory = _finite_numbers(observations.get("memory_bytes"), "observations.memory_bytes")
    physical_memory = machine.get("physical_memory_bytes")
    if type(physical_memory) is not int or physical_memory <= 0:
        raise EvidenceError("machine physical memory is unavailable")
    metrics.update(
        {
            "peak_memory_bytes": measured(int(max(memory))),
            "machine_memory_bytes": measured(physical_memory),
            "memory_lane": measured(
                "larger"
                if lane == LANE_REFERENCE
                else "constrained"
                if lane == LANE_CONSTRAINED
                else "eight_gb_fast"
            ),
        }
    )
    if lane != LANE_REFERENCE or not full_reference:
        return metrics

    registration = _mapping(observations.get("registration"), "observations.registration")
    candidate_registered = _booleans(registration.get("candidate"), "registration.candidate")
    colmap_registered = _booleans(registration.get("colmap"), "registration.colmap")
    if len(candidate_registered) != len(colmap_registered):
        raise EvidenceError("registration sample counts must match")
    residuals = _finite_numbers(observations.get("residual_pixels"), "observations.residual_pixels")

    pose = _mapping(observations.get("pose"), "observations.pose")
    candidate_ate = _finite_numbers(pose.get("candidate_ate"), "pose.candidate_ate")
    colmap_ate = _finite_numbers(pose.get("colmap_ate"), "pose.colmap_ate")
    colmap_rms = math.sqrt(sum(value * value for value in colmap_ate) / len(colmap_ate))
    if colmap_rms == 0:
        raise EvidenceError("COLMAP ATE reference must be nonzero")
    candidate_rms = math.sqrt(sum(value * value for value in candidate_ate) / len(candidate_ate))

    candidate_rotation = _finite_numbers(
        pose.get("candidate_rotation_rpe_degrees"), "pose.candidate_rotation_rpe_degrees"
    )
    colmap_rotation = _finite_numbers(
        pose.get("colmap_rotation_rpe_degrees"), "pose.colmap_rotation_rpe_degrees"
    )
    candidate_translation = _finite_numbers(
        pose.get("candidate_translation_rpe_percentage_points"),
        "pose.candidate_translation_rpe_percentage_points",
    )
    colmap_translation = _finite_numbers(
        pose.get("colmap_translation_rpe_percentage_points"),
        "pose.colmap_translation_rpe_percentage_points",
    )

    rendering = _mapping(observations.get("rendering"), "observations.rendering")
    balanced_psnr, balanced_ssim, balanced_lpips = _paired_losses(
        rendering.get("balanced"), "rendering.balanced"
    )
    fast_psnr, fast_ssim, fast_lpips = _paired_losses(rendering.get("fast"), "rendering.fast")

    long_sequence = _mapping(observations.get("long_sequence"), "observations.long_sequence")
    frames = long_sequence.get("frames")
    seconds = long_sequence.get("seconds")
    if type(frames) is not int or frames <= 0:
        raise EvidenceError("long_sequence.frames must be a positive integer")
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds <= 0:
        raise EvidenceError("long_sequence.seconds must be positive and finite")

    stability = _mapping(observations.get("stability"), "observations.stability")
    _exact_keys(stability, {"runs", "deterministic_restart"}, "observations.stability")
    stability_runs = stability.get("runs")
    if not isinstance(stability_runs, list) or not stability_runs:
        raise EvidenceError("observations.stability.runs must be a nonempty array")
    crashes = 0
    corrupt_outputs = 0
    for index, raw in enumerate(stability_runs):
        sample = _mapping(raw, f"stability.runs[{index}]")
        _exact_keys(sample, {"crashed", "corrupt_output"}, f"stability.runs[{index}]")
        if not isinstance(sample["crashed"], bool) or not isinstance(sample["corrupt_output"], bool):
            raise EvidenceError("stability flags must be boolean")
        crashes += sample["crashed"]
        corrupt_outputs += sample["corrupt_output"]
    deterministic_restart = all(
        _booleans(stability.get("deterministic_restart"), "stability.deterministic_restart")
    )

    required_size_artifacts = {"normal_photo_toolchain", "large_area_toolchain"}
    missing_sizes = required_size_artifacts - set(artifact_sizes)
    if missing_sizes:
        raise EvidenceError("missing toolchain size artifacts: " + ", ".join(sorted(missing_sizes)))

    metrics.update(
        {
            "registered_views": measured(sum(candidate_registered)),
            "total_views": measured(len(candidate_registered)),
            "colmap_registered_views": measured(sum(colmap_registered)),
            "residual_provenance": measured("track_reprojection"),
            "residual_median_pixels": measured(statistics.median(residuals)),
            "residual_p90_pixels": measured(_percentile(residuals, 0.90)),
            "ate_colmap_ratio": measured(candidate_rms / colmap_rms),
            "rotation_rpe_delta_degrees": measured(
                max(0.0, statistics.median(candidate_rotation) - statistics.median(colmap_rotation))
            ),
            "translation_rpe_delta_percentage_points": measured(
                max(0.0, statistics.median(candidate_translation) - statistics.median(colmap_translation))
            ),
            "balanced_median_psnr_loss_db": measured(statistics.median(balanced_psnr)),
            "balanced_median_ssim_loss": measured(statistics.median(balanced_ssim)),
            "balanced_median_lpips_increase": measured(statistics.median(balanced_lpips)),
            "balanced_scene_psnr_loss_db": measured(max(balanced_psnr)),
            "balanced_scene_ssim_loss": measured(max(balanced_ssim)),
            "balanced_scene_lpips_increase": measured(max(balanced_lpips)),
            "fast_scene_psnr_loss_db": measured(max(fast_psnr)),
            "fast_scene_ssim_loss": measured(max(fast_ssim)),
            "fast_scene_lpips_increase": measured(max(fast_lpips)),
            "long_sequence_geometry_fps": measured(frames / float(seconds)),
            "long_sequence_frames": measured(frames),
            "repeat_runs": measured(len(stability_runs)),
            "crashes": measured(crashes),
            "corrupt_outputs": measured(corrupt_outputs),
            "deterministic_restart": measured(deterministic_restart),
            "normal_photo_toolchain_bytes": measured(artifact_sizes["normal_photo_toolchain"]),
            "large_area_toolchain_bytes": measured(artifact_sizes["large_area_toolchain"]),
        }
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
    memory = machine["physical_memory_bytes"]
    if type(memory) is not int:
        raise EvidenceError("machine physical memory is unavailable")
    gib = 1024**3
    if lane == LANE_REFERENCE:
        if "M4 Max" not in str(machine["chip"]) or not 40 * gib <= memory <= 64 * gib:
            raise EvidenceError("reference lane requires an M4 Max with 40-64 GiB memory")
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
    _exact_keys(value, {"schema_version", "binding", "expected_outcome", "input_kind"}, "request")
    if value["schema_version"] != 1:
        raise EvidenceError("request schema_version must be 1")
    binding = _mapping(value["binding"], "request.binding")
    _exact_keys(
        binding,
        {
            "profile",
            "scene_id",
            "scale",
            "input_digest",
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
        },
        "request.binding",
    )
    if binding["profile"] != "release":
        raise EvidenceError("protected evidence requests are release-only")
    _token(binding["scene_id"], "request.binding.scene_id")
    for field in ("input_digest", "corpus_digest", "thresholds_digest", "toolchain_identity"):
        _digest(binding[field], f"request.binding.{field}")
    if not isinstance(binding["git_commit"], str) or not re.fullmatch(r"[0-9a-f]{40}", binding["git_commit"]):
        raise EvidenceError("request.binding.git_commit is invalid")
    if type(binding["scale"]) is not int or binding["scale"] <= 0:
        raise EvidenceError("request.binding.scale is invalid")
    if value["input_kind"] not in {"video", "photos", "mixed"}:
        raise EvidenceError("request.input_kind is invalid")
    expected = _mapping(value["expected_outcome"], "request.expected_outcome")
    if expected.get("kind") == "valid":
        _exact_keys(expected, {"kind"}, "request.expected_outcome")
    elif expected.get("kind") == "invalid":
        _exact_keys(expected, {"kind", "failure_type"}, "request.expected_outcome")
        _token(expected["failure_type"], "request.expected_outcome.failure_type")
    else:
        raise EvidenceError("request.expected_outcome is invalid")
    return value


def load_key(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise EvidenceError("evidence key must be a regular file")
    key = path.read_bytes().rstrip(b"\r\n")
    if not 32 <= len(key) <= 4096:
        raise EvidenceError("evidence key must contain 32-4096 bytes")
    return key


def _artifact_descriptor(path: Path, root: Path) -> dict[str, Any]:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise EvidenceError(f"artifact escapes evidence root: {path.name}") from error
    if path.is_symlink() or not path.is_file():
        raise EvidenceError(f"artifact must be a regular file: {relative}")
    return {"path": relative, "sha256": sha256_file(path), "bytes": path.stat().st_size}


def produce_attestation(
    request: Mapping[str, Any],
    observations: Mapping[str, Any],
    artifact_root: Path,
    output_path: Path,
    key: bytes,
    lane: str,
    measurement_runner: Mapping[str, Any],
    machine: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    request = validate_request(request)
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
        "timing",
        "memory_bytes",
    }
    observation_keys = set(common_observation_keys)
    if lane == LANE_REFERENCE and request["expected_outcome"]["kind"] == "valid":
        observation_keys.update(
            {
                "registration",
                "residual_pixels",
                "pose",
                "rendering",
                "long_sequence",
                "stability",
            }
        )
    _exact_keys(observations, observation_keys, "observations")
    if observations["schema_version"] != 1:
        raise EvidenceError("observations.schema_version must be 1")

    raw_artifacts = _mapping(observations.get("artifacts"), "observations.artifacts")
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
    required = {"command_log", "stdout_log", "stderr_log", "observations"}
    if request["expected_outcome"]["kind"] == "valid":
        required.add("output_ply")
    missing = required - set(descriptors)
    if missing:
        raise EvidenceError("missing required evidence artifacts: " + ", ".join(sorted(missing)))
    if "output_ply" in descriptors:
        output_ply = artifact_root / descriptors["output_ply"]["path"]
        with output_ply.open("rb") as handle:
            header = handle.read(4096)
        if not header.startswith(b"ply\n") or b"end_header\n" not in header:
            raise EvidenceError("output_ply is not a recognizable PLY file")

    commands = observations.get("commands")
    if not isinstance(commands, list) or not commands:
        raise EvidenceError("observations.commands must be a nonempty array")
    for command_index, command in enumerate(commands):
        if not isinstance(command, list) or not command:
            raise EvidenceError(f"observations.commands[{command_index}] must be an argument array")
        for argument in command:
            if not isinstance(argument, str) or not argument or "/Users/" in argument or "/home/" in argument:
                raise EvidenceError("commands must use redacted corpus:// and toolchain:// paths")

    actual = _mapping(observations.get("actual"), "observations.actual")
    _exact_keys(
        actual,
        {"exit_code", "termination_reason", "cancelled", "failure_type", "corrupt_ply"},
        "observations.actual",
    )
    artifact_sizes = {name: descriptor["bytes"] for name, descriptor in descriptors.items()}
    metrics = derive_metrics(
        observations,
        lane,
        machine,
        artifact_sizes,
        full_reference=request["expected_outcome"]["kind"] == "valid",
    )
    producer_path = Path(__file__).resolve()
    root = producer_path.parents[2]
    if producer_path != root / PRODUCER_RELATIVE_PATH:
        raise EvidenceError("protected producer is not running from the repository path")
    unsigned = {
        "schema_version": 1,
        "binding": dict(request["binding"]),
        "expected_outcome": dict(request["expected_outcome"]),
        "input_kind": request["input_kind"],
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
        "actual": dict(actual),
        "metrics": metrics,
        "artifacts": descriptors,
    }
    signature = "hmac-sha256:" + hmac.new(key, canonical_json_bytes(unsigned), hashlib.sha256).hexdigest()
    return {**unsigned, "signature": signature}


def verify_attestation(
    attestation_path: Path,
    expected_request: Mapping[str, Any],
    expected_lane: str,
    key: bytes,
    expected_measurement_runner: Mapping[str, Any],
) -> Mapping[str, Any]:
    if attestation_path.is_symlink() or not attestation_path.is_file():
        raise EvidenceError("attestation must be a regular file")
    try:
        value = json.loads(attestation_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError("attestation is not valid JSON") from error
    attestation = _mapping(value, "attestation")
    _exact_keys(
        attestation,
        {
            "schema_version",
            "binding",
            "expected_outcome",
            "input_kind",
            "lane",
            "machine",
            "producer",
            "measurement_runner",
            "commands",
            "actual",
            "metrics",
            "artifacts",
            "signature",
        },
        "attestation",
    )
    if attestation["schema_version"] != 1 or attestation["lane"] != expected_lane:
        raise EvidenceError("attestation schema or lane is invalid")
    request = validate_request(expected_request)
    for field in ("binding", "expected_outcome", "input_kind"):
        if attestation[field] != request[field]:
            raise EvidenceError(f"attestation {field} does not match its request")

    producer = _mapping(attestation["producer"], "attestation.producer")
    _exact_keys(producer, {"protocol_version", "version", "executable", "sha256"}, "attestation.producer")
    if producer["protocol_version"] != PROTOCOL_VERSION or producer["version"] != PRODUCER_VERSION:
        raise EvidenceError("attestation producer version is not supported")
    if producer["executable"] != PRODUCER_RELATIVE_PATH:
        raise EvidenceError("attestation was not made by the protected producer")
    producer_path = Path(__file__).resolve()
    if producer["sha256"] != sha256_file(producer_path):
        raise EvidenceError("attestation producer digest does not match this checkout")
    signature = attestation["signature"]
    if not isinstance(signature, str) or not HMAC_PATTERN.fullmatch(signature):
        raise EvidenceError("attestation signature is invalid")
    unsigned = dict(attestation)
    del unsigned["signature"]
    expected_signature = hmac.new(key, canonical_json_bytes(unsigned), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature.removeprefix("hmac-sha256:"), expected_signature):
        raise EvidenceError("attestation signature verification failed")
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


def _load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"), parse_constant=lambda value: (_ for _ in ()).throw(EvidenceError(f"{label} contains {value}")))
    except FileNotFoundError as error:
        raise EvidenceError(f"{label} is missing") from error
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} is not valid JSON") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("produce", nargs="?")
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--observations", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lane", choices=sorted(RELEASE_LANES), required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--runner-label", required=True)
    parser.add_argument("--runner-sha256", required=True)
    args = parser.parse_args(argv)
    if args.produce != "produce":
        parser.error("the only supported operation is 'produce'")
    try:
        request = _load_json(args.request, "request")
        observations = _load_json(args.observations, "observations")
        if args.observations.resolve() != (args.artifact_root / "observations.json").resolve():
            raise EvidenceError("observations must be artifact-root/observations.json")
        attestation = produce_attestation(
            request,
            observations,
            args.artifact_root,
            args.output,
            load_key(args.key_file),
            args.lane,
            {"label": args.runner_label, "sha256": args.runner_sha256},
        )
        args.output.write_bytes(canonical_json_bytes(attestation) + b"\n")
        return 0
    except EvidenceError as error:
        print(f"evidence error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
