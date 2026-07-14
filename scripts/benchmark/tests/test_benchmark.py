from __future__ import annotations

import importlib.util
import base64
import hashlib
import io
import itertools
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from jsonschema import Draft202012Validator, ValidationError
from referencing import Registry, Resource
from PIL import Image


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts" / "benchmark" / "easysplat_benchmark.py"
SPEC = importlib.util.spec_from_file_location("easysplat_benchmark", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load benchmark module at {MODULE_PATH}")
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
evidence = benchmark.evidence
from scripts.benchmark import run_lane as lane_runner  # noqa: E402


FIXTURE_SELECTION_MANIFEST = benchmark.canonical_json_bytes(
    {
        "schema_version": 1,
        "views": [
            {
                "view_index": index,
                "clip_id": "clip-0",
                "source_kind": "video",
            }
            for index in range(30)
        ],
    }
) + b"\n"


def fixture_render_camera(index: int) -> dict[str, object]:
    return {
        "width": 64,
        "height": 64,
        "projection_matrix_column_major": [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ],
        "world_to_camera_matrix_column_major": [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            float(index), 0.0, 0.0, 1.0,
        ],
    }


def fixture_png(value: int) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (64, 64), (value, value, value)).save(buffer, format="PNG")
    return buffer.getvalue()


FIXTURE_HOLDOUTS = list(range(4, 30, 5))
FIXTURE_GROUND_TRUTH_IMAGES = {
    index: fixture_png(80 + position)
    for position, index in enumerate(FIXTURE_HOLDOUTS)
}
FIXTURE_ACCURATE_RENDERING_REFERENCE = benchmark.canonical_json_bytes(
    {
        "schema_version": 1,
        "views": [
            {
                "holdout_index": index,
                "camera": fixture_render_camera(index),
                "camera_digest": evidence.sha256_bytes(
                    evidence.canonical_json_bytes(fixture_render_camera(index))
                ),
                "ground_truth_sha256": evidence.sha256_bytes(
                    FIXTURE_GROUND_TRUTH_IMAGES[index]
                ),
            }
            for index in FIXTURE_HOLDOUTS
        ],
    }
) + b"\n"

REFERENCE_ARTIFACT_CONTENTS = {
    "selection_manifest_sha256": ("selection-manifest.json", FIXTURE_SELECTION_MANIFEST),
    "ground_truth_poses_sha256": ("ground-truth-poses.json", b"ground truth poses\n"),
    "accurate_colmap_model_sha256": ("accurate-colmap-model.json", b"accurate COLMAP\n"),
    "accurate_rendering_reference_sha256": (
        "accurate-rendering-reference.json",
        FIXTURE_ACCURATE_RENDERING_REFERENCE,
    ),
    "paired_baseline_rendering_reference_sha256": (
        "paired-baseline-rendering-reference.json",
        b"paired baseline rendering reference\n",
    ),
    "orientation_label_sha256": ("orientation-label.json", b"physical up label\n"),
}

VALID_SPLAT_PLY = """ply
format ascii 1.0
element vertex 1
property float x
property float y
property float z
property float f_dc_0
property float f_dc_1
property float f_dc_2
property float opacity
property float scale_0
property float scale_1
property float scale_2
property float rot_0
property float rot_1
property float rot_2
property float rot_3
end_header
0 0 0 0 0 0 1 0 0 0 1 0 0 0
"""


def deterministic_zip(member: str, content: bytes) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        info = zipfile.ZipInfo(member, (2020, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, content)
    return buffer.getvalue()


def deterministic_closure_zip(component_names: list[str]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for component_name in component_names:
            info = zipfile.ZipInfo(f"{component_name}.zip", (2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, TEST_TOOLCHAIN_COMPONENT_ARCHIVES[component_name])
    return buffer.getvalue()


TEST_TOOLCHAIN_PRIVATE_KEY = Ed25519PrivateKey.from_private_bytes(
    hashlib.sha256(b"EasySplat benchmark toolchain fixture key").digest()
)
TEST_TOOLCHAIN_PUBLIC_KEY = TEST_TOOLCHAIN_PRIVATE_KEY.public_key().public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw,
)
TEST_TOOLCHAIN_PUBLIC_KEY_BASE64 = base64.b64encode(TEST_TOOLCHAIN_PUBLIC_KEY).decode("ascii")
TEST_TOOLCHAIN_COMPONENT_ARCHIVES = {
    "macos-arm64-core": deterministic_zip("bin/easysplat-train", b"metal trainer\n"),
    "geometry-large-area": deterministic_zip("models/large-area.safetensors", b"weights\n"),
}


def test_toolchain_manifest() -> dict[str, object]:
    definitions = (
        (
            "macos-arm64-core",
            ["runtime.core", "geometry.colmap", "training.msplat"],
            [],
            "bin/easysplat-train",
            b"metal trainer\n",
        ),
        (
            "geometry-large-area",
            ["geometry.streaming.large-area"],
            ["macos-arm64-core"],
            "models/large-area.safetensors",
            b"weights\n",
        ),
    )
    components = []
    for name, capabilities, dependencies, content_path, content in definitions:
        archive = TEST_TOOLCHAIN_COMPONENT_ARCHIVES[name]
        components.append(
            {
                "name": name,
                "capabilities": capabilities,
                "url": f"https://example.invalid/{name}.zip",
                "sha256": hashlib.sha256(archive).hexdigest(),
                "sizeBytes": len(archive),
                "expandedSizeBytes": max(len(archive), len(content)),
                "contents": [content_path],
                "criticalFileHashes": {content_path: hashlib.sha256(content).hexdigest()},
                "dependencies": dependencies,
                "requirement": "required" if name == "macos-arm64-core" else "optional",
            }
        )
    manifest = {
        "schemaVersion": 2,
        "toolchainAPI": 2,
        "keyID": hashlib.sha256(TEST_TOOLCHAIN_PUBLIC_KEY).hexdigest(),
        "version": "2.0.0",
        "publishedAt": "2026-07-01T00:00:00Z",
        "appVersionRange": {"minimum": "0.2.0-beta.1"},
        "components": components,
        "signatureEd25519": "",
    }
    manifest["signatureEd25519"] = base64.b64encode(
        TEST_TOOLCHAIN_PRIVATE_KEY.sign(evidence.canonical_json_bytes(manifest))
    ).decode("ascii")
    return manifest


def test_toolchain_state(component_names: list[str]) -> dict[str, object]:
    manifest = test_toolchain_manifest()
    components = {
        component["name"]: component
        for component in manifest["components"]
    }
    selected = [components[name] for name in component_names]
    return {
        "schemaVersion": 2,
        "installedArtifacts": {
            component["name"]: component["sha256"] for component in selected
        },
        "installedCapabilities": sorted(
            capability for component in selected for capability in component["capabilities"]
        ),
        "signedManifest": manifest,
    }


def test_toolchain_identity(state: dict[str, object]) -> str:
    manifest = state["signedManifest"]
    closure = {
        "schema_version": 2,
        "toolchain_api": 2,
        "key_id": manifest["keyID"],
        "version": manifest["version"],
        "app_version_range": {
            "minimum": manifest["appVersionRange"]["minimum"],
            "maximum_exclusive": manifest["appVersionRange"].get("maximumExclusive"),
        },
        "signature_ed25519": manifest["signatureEd25519"],
        "components": sorted(manifest["components"], key=lambda item: item["name"]),
        "installed_artifacts": dict(sorted(state["installedArtifacts"].items())),
        "installed_capabilities": sorted(state["installedCapabilities"]),
    }
    hasher = hashlib.sha256()
    for value in (b"easysplat-benchmark-toolchain-v2", evidence.canonical_json_bytes(closure)):
        hasher.update(len(value).to_bytes(8, "big"))
        hasher.update(value)
    return "sha256:" + hasher.hexdigest()


TEST_NORMAL_TOOLCHAIN_STATE = test_toolchain_state(["macos-arm64-core"])
TEST_LARGE_AREA_TOOLCHAIN_STATE = test_toolchain_state(
    ["macos-arm64-core", "geometry-large-area"]
)
TEST_TOOLCHAIN_IDENTITY = test_toolchain_identity(TEST_LARGE_AREA_TOOLCHAIN_STATE)
evidence.PINNED_TOOLCHAIN_PUBLIC_KEY_BASE64_OVERRIDE = TEST_TOOLCHAIN_PUBLIC_KEY_BASE64


def measured(value: object) -> dict[str, object]:
    return {"availability": "measured", "value": value}


def unavailable() -> dict[str, object]:
    return {"availability": "not_available"}


def validate_attestation_schema(attestation: dict[str, object]) -> None:
    evidence_schema = json.loads(
        (ROOT / "scripts/benchmark/evidence.schema.json").read_text(encoding="utf-8")
    )
    result_schema = json.loads(
        (ROOT / "scripts/benchmark/result.schema.json").read_text(encoding="utf-8")
    )
    registry = Registry().with_resource(
        result_schema["$id"],
        Resource.from_contents(result_schema),
    )
    Draft202012Validator(evidence_schema, registry=registry).validate(attestation)


def valid_scene(
    scene_id: str = "orbit-01",
    category: str = "object_orbit",
    adapter: str = "fixture",
) -> dict[str, object]:
    scale_lanes = [30, 120]
    pinned_scales = scale_lanes
    return {
        "id": scene_id,
        "category": category,
        "scenario": "test_fixture",
        "capture_traits": ["ordered"],
        "gate_scopes": ["scene_performance", "scene_quality"],
        "license": {
            "name": "External consent required",
            "url": "https://example.invalid/license",
            "redistributable": False,
        },
        "provenance": {
            "source": "External benchmark corpus",
            "authorization_status": "documented_consent",
            "authorization_sha256": evidence.sha256_bytes(b"documented test consent"),
        },
        "input": {
            "kind": "video",
            "media_path": f"external/{scene_id}.mov",
            "supplied": True,
        },
        "scale_lanes": scale_lanes,
        "aggregate_scale": 120,
        "split": {
            "status": "pinned",
            "holdout_by_scale": {
                str(scale): list(range(4, scale, 5)) for scale in pinned_scales
            },
        },
        "reference": {
            "status": "pinned",
            "by_scale": {
                str(scale): {
                    **{
                        name: evidence.sha256_bytes(content)
                        for name, (_, content) in REFERENCE_ARTIFACT_CONTENTS.items()
                    },
                    "orientation_expected_status": "verified",
                }
                for scale in pinned_scales
            },
        },
        "expected_outcome": {"kind": "valid"},
        "adapter": (
            {
                "type": "protected-evidence",
                "evidence_path": f"external/{scene_id}.evidence",
            }
            if adapter == "protected-evidence"
            else {
                "type": "fixture",
                "result_path": f"external/{scene_id}.result.json",
            }
        ),
    }


def valid_corpus(profile: str = "smoke") -> dict[str, object]:
    return {
        "schema_version": 1,
        "manifest_profile": profile,
        "scenes": [valid_scene()],
    }


def release_corpus() -> dict[str, object]:
    counts = {
        "object_orbit": 6,
        "interior_walkthrough": 6,
        "professional_photos": 4,
        "large_area_exterior": 4,
        "low_light": 3,
        "invalid": 3,
    }
    scenes: list[dict[str, object]] = []
    for category, count in counts.items():
        scenarios = sorted(benchmark.RELEASE_CATEGORY_SCENARIOS[category])
        for index in range(1, count + 1):
            scene = valid_scene(f"{category}-{index:02d}", category, "protected-evidence")
            scene["scenario"] = scenarios[index - 1]
            scene["split"] = {"status": "pending"}
            scene["reference"] = {"status": "pending"}
            scene["input"]["supplied"] = False
            scene["provenance"] = {
                "source": f"External benchmark slot {scene['id']}",
                "authorization_status": "pending",
                "authorization_sha256": None,
            }
            scene["gate_scopes"] = ["scene_performance", "scene_quality", "suite_performance"]
            if category == "object_orbit" and index == count:
                scene["scale_lanes"] = [3000]
            elif category == "object_orbit" and index == 3:
                scene["scale_lanes"] = [250]
            elif category == "object_orbit" and index == 4:
                scene["scale_lanes"] = [500]
            if 3000 in scene["scale_lanes"]:
                scene["gate_scopes"].insert(0, "long_sequence")
            if category == "object_orbit" and index == 1:
                scene["gate_scopes"].insert(-1, "stability")
            if category == "professional_photos" and index == 1:
                scene["gate_scopes"].append("toolchain")
                scene["gate_scopes"].sort()
            if category == "large_area_exterior":
                scene["capture_traits"] = (
                    ["large_area", "loop", "ordered"]
                    if index in {1, 3}
                    else ["forward_motion", "large_area", "ordered"]
                    if index == 2
                    else ["large_area", "nadir", "ordered"]
                )
            if category == "invalid":
                scene["gate_scopes"] = ["invalid_input"]
                scene["split"] = {"status": "not_applicable"}
                scene["reference"] = {"status": "not_applicable"}
                scene["expected_outcome"] = {
                    "kind": "invalid",
                    "failure_type": (
                        "disconnected_input",
                        "multiple_scenes",
                        "insufficient_overlap",
                    )[index - 1],
                }
            scene["aggregate_scale"] = max(
                (scale for scale in scene["scale_lanes"] if scale <= 500),
                default=max(scene["scale_lanes"]),
            )
            scenes.append(scene)
    return {"schema_version": 1, "manifest_profile": "release", "scenes": scenes}


def valid_reference_config() -> dict[str, object]:
    return {
        "schema_version": 1,
        "references": {
            "paired_baseline": {
                "git_commit": "4f3c11735ad15e1318ee2043ce351e185c225d30",
                "toolchain_identity": "sha256:bd32d5868c5cb6a06a2ae5822d87753f08daf050ea7299c9e373c174be49116b",
                "run_configuration": {
                    "detail_profile": "balanced",
                    "selected_frame_count": "request_scale",
                    "geometry_route": "colmap",
                    "feature_type": "sift",
                    "feature_max_image_size": 1024,
                    "feature_max_count": 10000,
                    "descriptor_matcher": "exact_cpu_brute_force",
                    "maximum_match_count": 10000,
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
                    "trainer_iterations": 7000,
                    "trainer_plateau_window": 800,
                    "deterministic_seed": 42,
                },
            },
            "accurate_colmap": {
                "mapper": "mapper",
                "bundle_adjustment": "full",
            },
            "rendering": {"iterations": 30_000, "pose_source": "accurate_colmap"},
        },
        "thresholds": {
            "coverage": {"absolute_min": 0.90, "colmap_relative_min": 0.95},
            "residual_pixels": {"median_max": 1.5, "p90_max": 3.0},
            "pose": {
                "ate_colmap_ratio_max": 1.10,
                "rotation_rpe_delta_degrees_max": 0.2,
                "translation_rpe_delta_percentage_points_max": 2.0,
            },
            "orientation": {
                "median_residual_degrees_max": 3.0,
                "p90_residual_degrees_max": 8.0,
                "bootstrap_p95_degrees_max": 5.0,
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
                    "500": 1200.0,
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
                "sustained_frames_min": 3000,
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
        },
    }


def passing_metrics() -> dict[str, object]:
    metrics = {
        "registered_views": measured(95),
        "total_views": measured(100),
        "colmap_registered_views": measured(100),
        "baseline_registered_views": measured(95),
        "points": measured(100),
        "observations": measured(100),
        "output_splat_count": measured(1),
        "residual_provenance": measured("track_reprojection"),
        "residual_median_pixels": measured(1.5),
        "residual_p90_pixels": measured(3.0),
        "ate_colmap_ratio": measured(1.10),
        "rotation_rpe_delta_degrees": measured(0.2),
        "translation_rpe_delta_percentage_points": measured(2.0),
        "balanced_median_psnr_loss_db": measured(0.5),
        "balanced_median_ssim_loss": measured(0.01),
        "balanced_median_lpips_increase": measured(0.02),
        "balanced_scene_psnr_loss_db": measured(1.0),
        "balanced_scene_ssim_loss": measured(0.02),
        "balanced_scene_lpips_increase": measured(0.03),
        "fast_scene_psnr_loss_db": measured(1.0),
        "fast_scene_ssim_loss": measured(0.02),
        "fast_scene_lpips_increase": measured(0.03),
        "paired_balanced_scene_psnr_loss_db": measured(0.5),
        "paired_balanced_scene_ssim_loss": measured(0.01),
        "paired_balanced_scene_lpips_increase": measured(0.02),
        "fast_end_to_end_speedup": measured(2.0),
        "m4_max_p50_seconds": measured(120.0),
        "balanced_geometry_speedup": measured(2.0),
        "constrained_fast_p50_seconds": measured(300.0),
        "eight_gb_fast_p50_seconds": measured(300.0),
        "long_sequence_analysis_fps": measured(5.0),
        "long_sequence_frames": measured(3000),
        "long_sequence_rss_growth_fraction": measured(0.05),
        "peak_memory_bytes": measured(6_500_000_000),
        "peak_metal_allocated_bytes": measured(1_000_000_000),
        "machine_memory_bytes": measured(8_000_000_000),
        "memory_lane": measured("eight_gb_fast"),
        "repeat_runs": measured(50),
        "crashes": measured(0),
        "corrupt_outputs": measured(0),
        "normal_photo_toolchain_bytes": measured(2_500_000_000),
        "large_area_toolchain_bytes": measured(2_500_000_000),
        "deterministic_restart": measured(True),
        "toolchain_fresh_install": measured(True),
        "toolchain_cached_offline_run": measured(True),
        "toolchain_interrupted_download_recovered": measured(True),
        "toolchain_low_disk_rejected": measured(True),
        "toolchain_wrong_key_rejected": measured(True),
        "toolchain_corrupt_archive_rejected": measured(True),
        "toolchain_rollback_succeeded": measured(True),
        "toolchain_traversal_rejected": measured(True),
    }
    metrics.update(
        {
            "scheduled_pairs": measured(100),
            "attempted_pairs": measured(100),
            "raw_matched_pairs": measured(90),
            "spatially_verified_pairs": measured(80),
            "connected_components": measured(1),
            "isolated_views": measured(0),
            "local_pairs": measured(70),
            "retrieval_pairs": measured(10),
            "loop_pairs": measured(0),
            "matcher_seconds": measured(10.0),
            "mapping_seconds": measured(20.0),
            "matching_speedup": measured(10.0),
            "mapping_speedup": measured(1.5),
            "bundle_adjustment_cycles": measured(3),
            "orientation_status": measured("verified"),
            "orientation_median_residual_degrees": measured(0.5),
            "orientation_p90_residual_degrees": measured(1.0),
            "orientation_bootstrap_p95_degrees": measured(2.0),
            "orientation_physical_up_error_degrees": measured(0.75),
            "orientation_sign_correct": measured(True),
            "raster_fallback_count": measured(0),
            "maximum_tile_intersections": measured(100),
            "dropped_intersection_count": measured(0),
        }
    )
    return metrics


def successful_actual() -> dict[str, object]:
    return {
        "exit_code": 0,
        "termination_reason": "exit",
        "cancelled": False,
        "failure_type": None,
        "corrupt_ply": False,
    }


def evidence_machine(lane: str) -> dict[str, object]:
    memory = {
        evidence.LANE_REFERENCE: 48 * 1024**3,
        evidence.LANE_CONSTRAINED: 16 * 1024**3,
        evidence.LANE_EIGHT_GB: 8 * 1024**3,
    }[lane]
    return {
        "architecture": "arm64",
        "chip": "Apple M4 Max" if lane == evidence.LANE_REFERENCE else "Apple M4",
        "hardware_model": "Mac16,5",
        "logical_cpus": 16,
        "macos_build": "24F74",
        "macos_version": "15.5",
        "physical_cpus": 12,
        "physical_memory_bytes": memory,
        "swift_version": "Swift 6.1",
        "xcode_version": "Xcode 16.4",
    }


def runner_identity(lane: str, digest_character: str = "a") -> dict[str, object]:
    identity: dict[str, object] = {
        "label": evidence.RUNNER_LABELS[lane],
        "sha256": "sha256:" + digest_character * 64,
    }
    if lane == evidence.RENDERING_DRIVER_IDENTITY:
        identity.update(
            {
                "executable_path": "EasySplatBenchmarkDriver",
                "executable_sha256": "sha256:" + digest_character * 64,
                "resource_bundle_path": "MetalSplatter_MetalSplatter.bundle",
                "manifest_path": "closure-manifest.json",
                "manifest_bytes": 512,
                "manifest_sha256": "sha256:" + digest_character * 64,
            }
        )
    return identity


def runner_identities() -> dict[str, dict[str, object]]:
    names = evidence.RELEASE_LANES | {evidence.RENDERING_DRIVER_IDENTITY}
    return {
        name: runner_identity(name, "e" if name == evidence.RENDERING_DRIVER_IDENTITY else "a")
        for name in sorted(names)
    }


def evidence_request(
    scene_id: str = "orbit-01",
    scale: int = 30,
    lane: str = evidence.LANE_REFERENCE,
) -> dict[str, object]:
    scene = valid_scene(scene_id=scene_id)
    scene["scale_lanes"] = [scale]
    scene["aggregate_scale"] = scale
    scene["split"] = {
        "status": "pinned",
        "holdout_by_scale": {str(scale): list(range(4, scale, 5))},
    }
    pinned_reference = next(iter(scene["reference"]["by_scale"].values()))
    scene["reference"] = {
        "status": "pinned",
        "by_scale": {str(scale): pinned_reference},
    }
    scene["gate_scopes"] = [
        "scene_performance",
        "scene_quality",
        "stability",
        "suite_performance",
        "toolchain",
    ]
    identity = benchmark.RunIdentity(
        profile="release",
        corpus_digest="sha256:" + "2" * 64,
        thresholds_digest="sha256:" + "3" * 64,
        git_commit="4" * 40,
        app_version="0.2.0-beta.1",
        toolchain_identity=TEST_TOOLCHAIN_IDENTITY,
    )
    return benchmark._evidence_request(
        scene,
        scale,
        lane,
        identity,
        "sha256:" + "1" * 64,
        runner_identity(evidence.RENDERING_DRIVER_IDENTITY, "e"),
    )


def candidate_timing(seconds: float) -> dict[str, object]:
    return {
        "candidate_runs": [
            {
                "run_id": f"candidate-only-{index}",
                "variant": "candidate",
                "discarded": index == 0,
                "end_to_end_seconds": duration,
            }
            for index, duration in enumerate(
                (seconds + 1.0, seconds - 1.0, seconds, seconds + 1.0)
            )
        ]
    }


def paired_timing() -> dict[str, object]:
    ordinary = [
        {
            "variant": "candidate",
            "discarded": True,
            "end_to_end_seconds": 101.0,
            "geometry_seconds": 41.0,
            "training_seconds": 60.0,
        }
    ]
    for baseline_end, candidate_end, baseline_geometry, candidate_geometry in (
        (249.0, 99.0, 99.0, 39.0),
        (250.0, 100.0, 100.0, 40.0),
        (251.0, 101.0, 101.0, 41.0),
    ):
        ordinary.extend(
            [
                {
                    "variant": "baseline",
                    "discarded": False,
                    "end_to_end_seconds": baseline_end,
                    "geometry_seconds": baseline_geometry,
                    "training_seconds": 60.0,
                },
                {
                    "variant": "candidate",
                    "discarded": False,
                    "end_to_end_seconds": candidate_end,
                    "geometry_seconds": candidate_geometry,
                    "training_seconds": 60.0,
                },
            ]
        )
    phase = [
        {
            "variant": "candidate",
            "discarded": True,
            "matcher_seconds": 13.0,
            "mapping_seconds": 21.0,
        }
    ]
    for baseline_matcher, candidate_matcher, baseline_mapping, candidate_mapping in (
        (123.0, 12.3, 28.0, 18.0),
        (124.0, 12.4, 29.0, 19.0),
        (125.0, 12.5, 30.0, 20.0),
        (126.0, 12.6, 31.0, 21.0),
        (127.0, 12.7, 32.0, 22.0),
    ):
        phase.extend(
            [
                {
                    "variant": "baseline",
                    "discarded": False,
                    "matcher_seconds": baseline_matcher,
                    "mapping_seconds": baseline_mapping,
                },
                {
                    "variant": "candidate",
                    "discarded": False,
                    "matcher_seconds": candidate_matcher,
                    "mapping_seconds": candidate_mapping,
                },
            ]
        )
    fast_profile = [
        {
            "variant": "fast_candidate",
            "discarded": True,
            "end_to_end_seconds": 101.0,
        }
    ]
    for reference_seconds, fast_seconds in ((199.0, 99.0), (200.0, 100.0), (201.0, 101.0)):
        fast_profile.extend(
            [
                {
                    "variant": "accurate_reference",
                    "discarded": False,
                    "end_to_end_seconds": reference_seconds,
                },
                {
                    "variant": "fast_candidate",
                    "discarded": False,
                    "end_to_end_seconds": fast_seconds,
                },
            ]
        )
    for group, records in (
        ("ordinary", ordinary),
        ("phase", phase),
        ("fast-profile", fast_profile),
    ):
        for index, record in enumerate(records):
            record["run_id"] = f"{group}-{index}"
            if group == "phase":
                record["end_to_end_seconds"] = (
                    record["matcher_seconds"] + record["mapping_seconds"] + 1.0
                )
    return {
        "ordinary_runs": ordinary,
        "phase_runs": phase,
        "fast_profile_runs": fast_profile,
    }


def stability_runs() -> list[dict[str, object]]:
    matrix = [
        (stage, action)
        for stage in ("prepare", "reconstruct", "train", "finish")
        for action in ("cancel_resume", "relaunch_resume")
    ]
    runs = []
    for index in range(50):
        stage, action = ("none", "none") if index % 5 == 4 else matrix[index % len(matrix)]
        runs.append(
            {
                "category": (
                    "object_orbit",
                    "interior_walkthrough",
                    "professional_photos",
                    "large_area_exterior",
                    "low_light",
                )[index % 5],
                "detail_profile": ("fast", "balanced", "high_detail")[index % 3],
                "interruption_stage": stage,
                "recovery_action": action,
                "crashed": False,
                "corrupt_output": False,
                "resumed_deterministically": None if stage == "none" else True,
            }
        )
    return runs


def fixture_pair_list() -> dict[str, object]:
    pairs = []
    for offset in (1, 2, 4, 8, 16):
        for view_a in range(30 - offset):
            pairs.append(
                {
                    "view_a": view_a,
                    "view_b": view_a + offset,
                    "pair_type": "local",
                    "query_view": None,
                    "attempted": True,
                    "raw_matched": True,
                    "spatially_verified": True,
                }
            )
    return {
        "schema_version": 2,
        "selected_frame_count": 30,
        "pairs": pairs,
        "retrieval": {"eligible_query_count": 0, "queries": []},
    }


def fixture_pair_list_with_retrieval() -> dict[str, object]:
    pair_list = fixture_pair_list()
    retrieval_targets = {0: [13, 14], 10: [23, 24], 20: [7, 8]}
    for query, targets in retrieval_targets.items():
        for target in targets:
            pair_list["pairs"].append(
                {
                    "view_a": min(query, target),
                    "view_b": max(query, target),
                    "pair_type": "retrieval",
                    "query_view": query,
                    "attempted": True,
                    "raw_matched": True,
                    "spatially_verified": True,
                }
            )
    pair_list["retrieval"] = {
        "eligible_query_count": 3,
        "queries": [
            {
                "query_view": 0,
                "eligible_target_count": 17,
                "attempted_candidate_count": 2,
                "attempted_targets": [13, 14],
                "verified_retained_neighbors": [13, 14],
                "retry_outcome": "not_needed",
                "matcher_used": "faiss",
                "fallback_reason": None,
            },
            {
                "query_view": 10,
                "eligible_target_count": 7,
                "attempted_candidate_count": 2,
                "attempted_targets": [23, 24],
                "verified_retained_neighbors": [23, 24],
                "retry_outcome": "not_needed",
                "matcher_used": "faiss",
                "fallback_reason": None,
            },
            {
                "query_view": 20,
                "eligible_target_count": 8,
                "attempted_candidate_count": 2,
                "attempted_targets": [7, 8],
                "verified_retained_neighbors": [7, 8],
                "retry_outcome": "not_needed",
                "matcher_used": "faiss",
                "fallback_reason": None,
            },
        ],
    }
    return pair_list


def fixture_unordered_exhaustive_pair_list() -> dict[str, object]:
    return {
        "schema_version": 2,
        "selected_frame_count": 30,
        "pairs": [
            {
                "view_a": view_a,
                "view_b": view_b,
                "pair_type": "exhaustive",
                "query_view": None,
                "attempted": True,
                "raw_matched": True,
                "spatially_verified": True,
                "matcher_used": "faiss",
            }
            for view_a in range(30)
            for view_b in range(view_a + 1, 30)
        ],
        "retrieval": {"eligible_query_count": 0, "queries": []},
    }


def _timing_records(timing: dict[str, object]) -> list[tuple[str, dict[str, object]]]:
    return [
        (phase, record)
        for phase, records in timing.items()
        for record in records
    ]


def execution_receipts(
    timing: dict[str, object],
    lane: str,
    request: dict[str, object] | None = None,
) -> list[dict[str, object]]:
    request = request or evidence_request(lane=lane)
    candidate_configuration = request["candidate_run_configuration"]
    fast_configuration = {
        **candidate_configuration,
        "detail_profile": "fast",
        "trainer_iterations": 3000,
        "trainer_plateau_window": 400,
    }
    accurate_configuration = {
        "mapper": "mapper",
        "bundle_adjustment": "full",
        "render_iterations": 30000,
        "pose_source": "accurate_colmap",
    }
    configurations = {
        "baseline": request["baseline_run_configuration"],
        "candidate": candidate_configuration,
        "fast_candidate": fast_configuration,
        "accurate_reference": accurate_configuration,
    }
    prefixes = {
        "baseline": ["baseline://4f3c117", "baseline-toolchain://2.0.0"],
        "candidate": ["candidate://prepared-commit", "toolchain://resolved"],
        "fast_candidate": ["fast-candidate://prepared-commit", "toolchain://resolved"],
        "accurate_reference": ["accurate-reference://full-ba-30k", "toolchain://resolved"],
    }
    receipts = []
    cursor = 0.0
    timing_records = _timing_records(timing)
    publishable_indices = [
        index
        for index, (phase, record) in enumerate(timing_records)
        if phase in {"ordinary_runs", "candidate_runs"} and record["variant"] == "candidate"
    ]
    published_index = publishable_indices[-1]
    for record_index, (phase, record) in enumerate(timing_records):
        duration = float(record["end_to_end_seconds"])
        variant = str(record["variant"])
        published_output = record_index == published_index
        receipts.append(
            {
                "run_id": record["run_id"],
                "phase": phase.removesuffix("_runs"),
                "variant": variant,
                "argv": ["easysplat-benchmark", *prefixes[variant], "corpus://orbit-01"],
                "started_monotonic_seconds": cursor,
                "ended_monotonic_seconds": cursor + duration,
                "exit_code": 0,
                "checkout_commit": (
                    request["binding"]["baseline_git_commit"]
                    if variant == "baseline"
                    else request["binding"]["git_commit"]
                ),
                "toolchain_identity": (
                    request["binding"]["baseline_toolchain_identity"]
                    if variant == "baseline"
                    else request["binding"]["toolchain_identity"]
                ),
                "run_configuration_digest": evidence.sha256_bytes(
                    evidence.canonical_json_bytes(configurations[variant])
                ),
                "executable_sha256": runner_identity(lane)["sha256"],
                "output_sha256": (
                    evidence.sha256_bytes(VALID_SPLAT_PLY.encode("utf-8"))
                    if published_output
                    else evidence.sha256_bytes(f"{lane}:{record['run_id']}".encode("utf-8"))
                ),
                "scene_id": request["binding"]["scene_id"],
                "input_digest": request["binding"]["input_digest"],
                "scale": request["binding"]["scale"],
                "lane": request["binding"]["lane"],
                "published_output": published_output,
            }
        )
        cursor += duration
    return receipts


def memory_observation(
    timing: dict[str, object],
    lane: str,
) -> dict[str, object]:
    interval = 5.0
    rss = {
        evidence.LANE_REFERENCE: 6_000_000_000,
        evidence.LANE_CONSTRAINED: 10_000_000_000,
        evidence.LANE_EIGHT_GB: 6_000_000_000,
    }[lane]
    samples = []
    for phase, record in _timing_records(timing):
        if record["variant"] not in {"candidate", "fast_candidate"}:
            continue
        duration = float(record["end_to_end_seconds"])
        elapsed = 0.0
        times = []
        while elapsed < duration:
            times.append(elapsed)
            elapsed += interval
        times.append(duration)
        for elapsed in times:
            samples.append(
                {
                    "run_id": record["run_id"],
                    "elapsed_seconds": elapsed,
                    "process_tree_resident_bytes": rss,
                    "metal_allocated_bytes": 0 if phase == "phase_runs" else 1_000_000_000,
                }
            )
    return {"sample_interval_seconds": interval, "samples": samples}


def invalid_execution_receipt(
    request: dict[str, object],
    actual: dict[str, object],
    lane: str,
) -> list[dict[str, object]]:
    return [
        {
            "run_id": "invalid-input-0",
            "phase": "invalid_input",
            "variant": "candidate",
            "argv": ["candidate://invalid-input", "toolchain://current"],
            "started_monotonic_seconds": 0.0,
            "ended_monotonic_seconds": 1.0,
            "exit_code": actual["exit_code"],
            "checkout_commit": request["binding"]["git_commit"],
            "toolchain_identity": request["binding"]["toolchain_identity"],
            "run_configuration_digest": evidence.sha256_bytes(
                evidence.canonical_json_bytes(request["candidate_run_configuration"])
            ),
            "executable_sha256": runner_identity(lane)["sha256"],
            "output_sha256": evidence.sha256_bytes(b"invalid-input-output"),
            "scene_id": request["binding"]["scene_id"],
            "input_digest": request["binding"]["input_digest"],
            "scale": request["binding"]["scale"],
            "lane": request["binding"]["lane"],
            "published_output": False,
        }
    ]


def supervisor_run(observations: dict[str, object]) -> dict[str, object]:
    commands = observations["commands"]
    candidate = next(
        receipt
        for receipt in commands
        if receipt["variant"] in {"candidate", "fast_candidate"}
    )
    started = min(float(receipt["started_monotonic_seconds"]) for receipt in commands)
    ended = max(float(receipt["ended_monotonic_seconds"]) for receipt in commands)
    binding = {
        "scene_id": candidate["scene_id"],
        "scale": candidate["scale"],
        "lane": candidate["lane"],
        "input_digest": candidate["input_digest"],
        "candidate_git_commit": candidate["checkout_commit"],
        "baseline_git_commit": observations["baseline"]["git_commit"],
        "toolchain_identity": candidate["toolchain_identity"],
        "baseline_toolchain_identity": observations["baseline"]["toolchain_identity"],
        "runner_sha256": candidate["executable_sha256"],
    }
    return {
        "schema_version": 1,
        **binding,
        "argv": [
            "protected-measurement-runner",
            f"scene://{binding['scene_id']}",
            f"scale://{binding['scale']}",
            f"lane://{binding['lane']}",
            f"input://{binding['input_digest']}",
            f"candidate://{binding['candidate_git_commit']}",
            f"baseline://{binding['baseline_git_commit']}",
            f"toolchain://{binding['toolchain_identity']}",
            f"runner://{binding['runner_sha256']}",
        ],
        "started_monotonic_seconds": started,
        "ended_monotonic_seconds": ended + 1.0,
        "exit_code": 0,
    }


def toolchain_scenarios(request: dict[str, object]) -> list[dict[str, object]]:
    records = []
    for name, spec in evidence.TOOLCHAIN_SCENARIO_SPECS.items():
        records.append(
            {
                "schema_version": 1,
                "name": name,
                "fault": spec["fault"],
                "network_mode": spec["network_mode"],
                "toolchain_identity": request["binding"]["toolchain_identity"],
                "input_digest": request["binding"]["input_digest"],
                "argv": [
                    "easysplat-toolchain-check",
                    f"toolchain-scenario://{name}",
                    f"toolchain://{request['binding']['toolchain_identity']}",
                ],
                "initial_exit_code": spec["initial_exit_code"],
                "retry_exit_code": spec["retry_exit_code"],
                "result": spec["result"],
                "post_state_verified": True,
            }
        )
    return records


def raw_observations(
    lane: str,
    *,
    include_long_sequence: bool = False,
) -> dict[str, object]:
    timing = (
        paired_timing()
        if lane == evidence.LANE_REFERENCE
        else candidate_timing(250.0 if lane == evidence.LANE_CONSTRAINED else 300.0)
    )
    observations: dict[str, object] = {
        "schema_version": 2,
        "artifacts": {
            "command_log": "command.jsonl",
            "supervisor_run": "supervisor-run.json",
            "stdout_log": "stdout.log",
            "stderr_log": "stderr.log",
            "output_ply": "splat.ply",
        },
        "commands": execution_receipts(timing, lane),
        "actual": successful_actual(),
        "baseline": {
            "git_commit": "4f3c11735ad15e1318ee2043ce351e185c225d30",
            "toolchain_identity": "sha256:bd32d5868c5cb6a06a2ae5822d87753f08daf050ea7299c9e373c174be49116b",
            "configuration_digest": benchmark.sha256_json(
                valid_reference_config()["references"]["paired_baseline"]["run_configuration"]
            ),
        },
        "timing": timing,
        "memory": memory_observation(timing, lane),
        "resolved_compute": {
            "stages": {
                "feature_extraction": "cpu",
                "matching": "cpu",
                "mapping": "cpu",
                "training": "metal",
                "rendering": "metal",
            },
            "cpu_only_reasons": {
                "feature_extraction": "colmap_sift_has_no_supported_metal_backend",
                "matching": "faiss_has_no_supported_metal_backend",
                "mapping": "ceres_has_no_supported_metal_backend",
            },
        },
        "pipeline_metrics": {
            "scheduled_pairs": 119,
            "attempted_pairs": 119,
            "raw_matched_pairs": 119,
            "spatially_verified_pairs": 119,
            "connected_components": 1,
            "isolated_views": 0,
            "local_pairs": 119,
            "retrieval_pairs": 0,
            "loop_pairs": 0,
            "matcher_seconds": 12.5,
            "mapping_seconds": 20.0,
            "bundle_adjustment_cycles": 3,
            "orientation_status": "verified",
            "orientation_median_residual_degrees": 0.5,
            "orientation_p90_residual_degrees": 1.0,
            "orientation_bootstrap_p95_degrees": 2.0,
            "orientation_physical_up_error_degrees": 0.75,
            "orientation_sign_correct": True,
            "raster_fallback_count": 0,
            "maximum_tile_intersections": 4,
            "dropped_intersection_count": 0,
        },
    }
    if lane == evidence.LANE_REFERENCE:
        observations["artifacts"].update(
            {
                "pair_list": "pair-list.json",
                "render_job": "render-job.json",
                "rendering_manifest": "rendering-manifest.json",
                "render_supervisor": "render-supervisor.json",
                "renderer_stdout_log": "renderer-stdout.log",
                "renderer_stderr_log": "renderer-stderr.log",
                "normal_photo_toolchain": "normal-photo.zip",
                "normal_photo_toolchain_state": "normal-photo-toolchain-state.json",
                "large_area_toolchain": "large-area.zip",
                "large_area_toolchain_state": "large-area-toolchain-state.json",
                "toolchain_scenarios": "toolchain-scenarios.jsonl",
                **{
                    field.removesuffix("_sha256"): filename
                    for field, (filename, _) in REFERENCE_ARTIFACT_CONTENTS.items()
                },
            }
        )
        observations.update(
            {
                "registration": {
                    "candidate": [True] * 30,
                    "colmap": [True] * 30,
                    "baseline": [True] * 30,
                },
                "residual_pixels": [
                    {
                        "view_index": view_index,
                        "point_id": view_index,
                        "residual_pixels": 1.0 + (view_index % 3) * 0.5,
                    }
                    for view_index in range(30)
                ],
                "pose": {
                    "absolute": [
                        {"view_index": view_index, "candidate_ate": 1.0, "colmap_ate": 1.0}
                        for view_index in range(30)
                    ],
                    "relative": [
                        {
                            "from_view_index": view_index,
                            "to_view_index": view_index + 1,
                            "candidate_rotation_rpe_degrees": 0.2,
                            "colmap_rotation_rpe_degrees": 0.1,
                            "candidate_translation_rpe_percentage_points": 2.0,
                            "colmap_translation_rpe_percentage_points": 1.0,
                        }
                        for view_index in range(29)
                    ],
                },
                "stability": {
                    "runs": stability_runs(),
                },
                "toolchain_scenarios": toolchain_scenarios(
                    evidence_request(lane=evidence.LANE_REFERENCE)
                ),
            }
        )
        if include_long_sequence:
            observations["long_sequence"] = {
                "processed_frames": 3000,
                "analysis_seconds": 500.0,
                "rss_windows": [
                    {"start_frame": start, "end_frame": start + 499, "rss_bytes": value}
                    for start, value in zip(
                        range(0, 3000, 500),
                        (100, 100, 101, 102, 103, 105),
                        strict=True,
                    )
                ],
            }
    return observations


def write_evidence_artifacts(
    root: Path,
    observations: dict[str, object],
    render_request: dict[str, object] | None = None,
) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for name, content in (
        ("stdout.log", "complete\n"),
        ("stderr.log", ""),
        ("renderer-stdout.log", "render complete\n"),
        ("renderer-stderr.log", ""),
        ("splat.ply", VALID_SPLAT_PLY),
    ):
        (root / name).write_text(content, encoding="utf-8")
    (root / "normal-photo.zip").write_bytes(
        deterministic_closure_zip(["macos-arm64-core"])
    )
    (root / "large-area.zip").write_bytes(
        deterministic_closure_zip(["macos-arm64-core", "geometry-large-area"])
    )
    (root / "normal-photo-toolchain-state.json").write_bytes(
        evidence.canonical_json_bytes(TEST_NORMAL_TOOLCHAIN_STATE) + b"\n"
    )
    (root / "large-area-toolchain-state.json").write_bytes(
        evidence.canonical_json_bytes(TEST_LARGE_AREA_TOOLCHAIN_STATE) + b"\n"
    )
    (root / "command.jsonl").write_bytes(
        b"".join(
            evidence.canonical_json_bytes(receipt) + b"\n"
            for receipt in observations["commands"]
        )
    )
    (root / "supervisor-run.json").write_bytes(
        evidence.canonical_json_bytes(supervisor_run(observations)) + b"\n"
    )
    if "toolchain_scenarios" in observations:
        (root / "toolchain-scenarios.jsonl").write_bytes(
            b"".join(
                evidence.canonical_json_bytes(record) + b"\n"
                for record in observations["toolchain_scenarios"]
            )
            )
    if (
        "registration" in observations
        and observations.get("artifacts", {}).get("rendering_manifest")
        == "rendering-manifest.json"
    ):
        commands_by_source = {
            "accurate_reference": ("fast_profile", "accurate_reference"),
            "paired_baseline": ("ordinary", "baseline"),
            "candidate_balanced": ("ordinary", "candidate"),
            "candidate_fast": ("fast_profile", "fast_candidate"),
        }
        source_receipts = {}
        for render_variant, (phase, execution_variant) in commands_by_source.items():
            source_receipts[render_variant] = [
                command
                for command in observations["commands"]
                if command["phase"] == phase and command["variant"] == execution_variant
            ][-1]
        representative = source_receipts["candidate_balanced"]
        render_request = render_request or evidence_request(lane=evidence.LANE_REFERENCE)
        renderer_identity = render_request["rendering_driver_identity"]
        renderer_digest = renderer_identity["executable_sha256"]
        renderer_closure_digest = renderer_identity["sha256"]
        scale = len(observations["registration"]["candidate"])
        holdouts = list(range(4, scale, 5))
        manifest_views = []
        render_operations = []
        for holdout_index in holdouts:
            ground_truth = FIXTURE_GROUND_TRUTH_IMAGES[holdout_index]
            ground_truth_path = Path("rendering/ground-truth") / f"{holdout_index:06d}.png"
            (root / ground_truth_path).parent.mkdir(parents=True, exist_ok=True)
            (root / ground_truth_path).write_bytes(ground_truth)
            camera = fixture_render_camera(holdout_index)
            camera_digest = evidence.sha256_bytes(evidence.canonical_json_bytes(camera))
            render_records = []
            for variant in evidence.RENDER_VARIANTS:
                render_path = Path("rendering") / variant / f"{holdout_index:06d}.png"
                (root / render_path).parent.mkdir(parents=True, exist_ok=True)
                render_bytes = ground_truth
                (root / render_path).write_bytes(render_bytes)
                source = source_receipts[variant]
                render_digest = evidence.sha256_bytes(render_bytes)
                render_operation_id = f"render-{holdout_index:06d}-{variant}"
                render_records.append(
                    {
                        "variant": variant,
                        "path": render_path.as_posix(),
                        "sha256": render_digest,
                        "camera_digest": camera_digest,
                        "source_run_id": source["run_id"],
                        "ply_sha256": source["output_sha256"],
                        "renderer": "MetalSplatter",
                        "renderer_executable_sha256": renderer_digest,
                        "render_operation_id": render_operation_id,
                    }
                )
                started = float(len(render_operations))
                render_operations.append(
                    {
                        "operation_id": render_operation_id,
                        "holdout_index": holdout_index,
                        "variant": variant,
                        "renderer_executable_sha256": renderer_digest,
                        "source_run_id": source["run_id"],
                        "source_checkout_commit": source["checkout_commit"],
                        "source_toolchain_identity": source["toolchain_identity"],
                        "source_executable_sha256": source["executable_sha256"],
                        "input_ply_sha256": source["output_sha256"],
                        "camera_digest": camera_digest,
                        "output_sha256": render_digest,
                        "started_monotonic_seconds": started,
                        "ended_monotonic_seconds": started + 1.0,
                        "status": "completed",
                    }
                )
            manifest_views.append(
                {
                    "holdout_index": holdout_index,
                    "camera": camera,
                    "camera_digest": camera_digest,
                    "ground_truth": {
                        "path": ground_truth_path.as_posix(),
                        "sha256": evidence.sha256_bytes(ground_truth),
                        "input_digest": representative["input_digest"],
                    },
                    "renders": render_records,
                }
            )
        operations_by_key = {
            (operation["variant"], operation["holdout_index"]): operation
            for operation in render_operations
        }
        render_operations = [
            operations_by_key[(variant, holdout_index)]
            for variant in evidence.RENDER_VARIANTS
            for holdout_index in holdouts
        ]
        for index, operation in enumerate(render_operations):
            operation["started_monotonic_seconds"] = float(index)
            operation["ended_monotonic_seconds"] = float(index + 1)
        manifest = {
            "schema_version": 1,
            "scene_id": representative["scene_id"],
            "scale": scale,
            "request_digest": evidence.sha256_bytes(
                evidence.canonical_json_bytes(render_request) + b"\n"
            ),
            "input_digest": representative["input_digest"],
            "holdout_indices": holdouts,
            "training_view_indices": [
                index for index in range(scale) if index not in set(holdouts)
            ],
            "color_space": "srgb",
            "pixel_format": "png_rgb8",
            "renderer_closure_sha256": renderer_closure_digest,
            "renderer_executable_sha256": renderer_digest,
            "render_operations": render_operations,
            "views": manifest_views,
        }
        (root / "rendering-manifest.json").write_bytes(
            evidence.canonical_json_bytes(manifest) + b"\n"
        )
        (root / "render-job.json").write_bytes(
            evidence.canonical_json_bytes({"fixture": True}) + b"\n"
        )
        render_supervisor = {
            "schema_version": 1,
            "scene_id": representative["scene_id"],
            "scale": scale,
            "lane": render_request["binding"]["lane"],
            "request_sha256": manifest["request_digest"],
            "candidate_checkout_commit": render_request["binding"]["git_commit"],
            "baseline_checkout_commit": render_request["binding"]["baseline_git_commit"],
            "renderer_closure_sha256": renderer_identity["sha256"],
            "renderer_executable_sha256": renderer_identity["executable_sha256"],
            "job_sha256": evidence.sha256_file(root / "render-job.json"),
            "manifest_sha256": evidence.sha256_file(root / "rendering-manifest.json"),
            "stdout_sha256": evidence.sha256_file(root / "renderer-stdout.log"),
            "stderr_sha256": evidence.sha256_file(root / "renderer-stderr.log"),
            "argv": [
                "approved-rendering-driver",
                f"renderer-closure://{renderer_identity['sha256']}",
                f"renderer-executable://{renderer_identity['executable_sha256']}",
                "render",
                "--job",
                "evidence://render-job.json",
                "--artifact-root",
                "evidence://run",
                "--output",
                "evidence://rendering-manifest.json",
            ],
            "actual_argv_sha256": "sha256:" + "9" * 64,
            "started_monotonic_seconds": 0.0,
            "ended_monotonic_seconds": 1.0,
            "exit_code": 0,
            "timed_out": False,
        }
        (root / "render-supervisor.json").write_bytes(
            evidence.canonical_json_bytes(render_supervisor) + b"\n"
        )
    for _, (name, content) in REFERENCE_ARTIFACT_CONTENTS.items():
        (root / name).write_bytes(content)
    (root / "pair-list.json").write_bytes(
        evidence.canonical_json_bytes(fixture_pair_list()) + b"\n"
    )
    (root / "observations.json").write_bytes(evidence.canonical_json_bytes(observations) + b"\n")


def external_envelope(
    scene: dict[str, object],
    scale: int,
    input_digest: str,
    identity: object,
    *,
    actual: dict[str, object] | None = None,
    metrics: dict[str, object] | None = None,
    route: str = "fixture-route",
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "profile": identity.profile,
        "scene_id": scene["id"],
        "input_digest": input_digest,
        "corpus_digest": identity.corpus_digest,
        "thresholds_digest": identity.thresholds_digest,
        "git_commit": identity.git_commit,
        "app_version": identity.app_version,
        "toolchain_identity": identity.toolchain_identity,
        "scale_results": {
            str(scale): {
                "scale": scale,
                "route": route,
                "detail_profile": "balanced",
                "actual": actual or successful_actual(),
                "metrics": metrics or passing_metrics(),
                "artifacts": {},
            }
        },
    }


class ConfigurationValidationTests(unittest.TestCase):
    def test_tracked_release_contract_is_valid_and_complete(self) -> None:
        corpus = json.loads((ROOT / "scripts/benchmark/corpus.json").read_text(encoding="utf-8"))
        config = json.loads((ROOT / "scripts/benchmark/reference-config.json").read_text(encoding="utf-8"))
        benchmark.validate_corpus(corpus, expected_profile="release")
        benchmark.validate_reference_config(config)
        self.assertEqual(len(corpus["scenes"]), 26)
        self.assertTrue(all(scene["input"]["supplied"] is False for scene in corpus["scenes"]))
        self.assertTrue(
            all(
                scene["reference"]
                == (
                    {"status": "not_applicable"}
                    if scene["expected_outcome"]["kind"] == "invalid"
                    else {"status": "pending"}
                )
                for scene in corpus["scenes"]
            ),
            "release slots must distinguish pending references from invalid-scene nonrequirements",
        )
        self.assertTrue(
            all(
                scene["split"]
                == (
                    {"status": "not_applicable"}
                    if scene["expected_outcome"]["kind"] == "invalid"
                    else {"status": "pending"}
                )
                for scene in corpus["scenes"]
            ),
            "release slots must distinguish pending splits from invalid-scene nonrequirements",
        )
        self.assertTrue(
            all(scene["adapter"]["type"] == "protected-evidence" for scene in corpus["scenes"]),
            "release slots must never use a metrics fixture or geometry-only adapter",
        )
        self.assertEqual(
            {scene["category"] for scene in corpus["scenes"]},
            {
                "object_orbit",
                "interior_walkthrough",
                "professional_photos",
                "large_area_exterior",
                "low_light",
                "invalid",
            },
        )
        self.assertEqual(
            {scope for scene in corpus["scenes"] for scope in scene["gate_scopes"]},
            benchmark.ALLOWED_GATE_SCOPES,
        )
        self.assertTrue(
            any(
                scene["expected_outcome"] == {"kind": "valid"}
                and "segmented" in scene["capture_traits"]
                for scene in corpus["scenes"]
            ),
            "the release corpus must exercise a valid segmented or mixed capture",
        )

    def test_capture_traits_are_closed_sorted_and_nonempty(self) -> None:
        corpus = valid_corpus()
        for replacement in ([], ["ordered", "ordered"], ["unordered", "ordered"], ["unknown"]):
            corpus["scenes"][0]["capture_traits"] = replacement
            with self.subTest(replacement=replacement):
                with self.assertRaisesRegex(benchmark.ConfigError, "capture_traits"):
                    benchmark.validate_corpus(corpus, expected_profile="smoke")
        del corpus["scenes"][0]["capture_traits"]
        with self.assertRaisesRegex(benchmark.ConfigError, "capture_traits"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_large_area_release_slots_cover_ground_route_aerial_and_nadir(self) -> None:
        corpus = release_corpus()
        benchmark.validate_corpus(corpus, expected_profile="release")
        large_area = [scene for scene in corpus["scenes"] if scene["category"] == "large_area_exterior"]
        self.assertEqual(len(large_area), 4)
        self.assertTrue(all(scene["input"]["supplied"] is False for scene in large_area))
        self.assertEqual(
            [scene["capture_traits"] for scene in large_area],
            [
                ["large_area", "loop", "ordered"],
                ["forward_motion", "large_area", "ordered"],
                ["large_area", "loop", "ordered"],
                ["large_area", "nadir", "ordered"],
            ],
        )
        large_area[-1]["capture_traits"] = ["large_area", "ordered"]
        with self.assertRaisesRegex(benchmark.ConfigError, "large_area_exterior"):
            benchmark.validate_corpus(corpus, expected_profile="release")

    def test_gate_scopes_are_required_and_closed(self) -> None:
        for replacement in ([], ["scene_quality", "scene_quality"], ["unknown"]):
            corpus = valid_corpus()
            corpus["scenes"][0]["gate_scopes"] = replacement
            with self.subTest(replacement=replacement):
                with self.assertRaisesRegex(benchmark.ConfigError, "gate_scopes"):
                    benchmark.validate_corpus(corpus, expected_profile="smoke")
        corpus = valid_corpus()
        del corpus["scenes"][0]["gate_scopes"]
        with self.assertRaisesRegex(benchmark.ConfigError, "gate_scopes"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_gate_scopes_match_the_declared_outcome(self) -> None:
        valid = valid_corpus()
        valid["scenes"][0]["gate_scopes"] = ["invalid_input"]
        with self.assertRaisesRegex(benchmark.ConfigError, "invalid_input"):
            benchmark.validate_corpus(valid, expected_profile="smoke")

        invalid = valid_corpus()
        invalid["scenes"][0]["category"] = "invalid"
        invalid["scenes"][0]["expected_outcome"] = {
            "kind": "invalid",
            "failure_type": "disconnected_input",
        }
        invalid["scenes"][0]["gate_scopes"] = ["scene_quality"]
        invalid["scenes"][0]["split"] = {"status": "not_applicable"}
        invalid["scenes"][0]["reference"] = {"status": "not_applicable"}
        with self.assertRaisesRegex(benchmark.ConfigError, "invalid_input"):
            benchmark.validate_corpus(invalid, expected_profile="smoke")

    def test_release_manifest_cannot_omit_core_or_suite_level_gates(self) -> None:
        corpus = release_corpus()
        valid_scene_entry = next(
            scene for scene in corpus["scenes"] if scene["expected_outcome"] == {"kind": "valid"}
        )
        valid_scene_entry["gate_scopes"] = sorted(
            set(valid_scene_entry["gate_scopes"]) - {"scene_quality"}
        )
        with self.assertRaisesRegex(benchmark.ConfigError, "core gate scopes"):
            benchmark.validate_corpus(corpus, expected_profile="release")

        corpus = release_corpus()
        long_scene = next(scene for scene in corpus["scenes"] if 3000 in scene["scale_lanes"])
        long_scene["gate_scopes"] = sorted(set(long_scene["gate_scopes"]) - {"long_sequence"})
        with self.assertRaisesRegex(benchmark.ConfigError, "long_sequence"):
            benchmark.validate_corpus(corpus, expected_profile="release")

        for required_scope in ("stability", "toolchain"):
            corpus = release_corpus()
            for scene in corpus["scenes"]:
                scene["gate_scopes"] = [
                    scope for scope in scene["gate_scopes"] if scope != required_scope
                ]
            with self.subTest(required_scope=required_scope), self.assertRaisesRegex(
                benchmark.ConfigError,
                required_scope,
            ):
                benchmark.validate_corpus(corpus, expected_profile="release")

    def test_paired_baseline_identity_is_frozen(self) -> None:
        config = valid_reference_config()
        benchmark.validate_reference_config(config)
        baseline = config["references"]["paired_baseline"]
        self.assertEqual(
            baseline["git_commit"],
            "4f3c11735ad15e1318ee2043ce351e185c225d30",
        )
        self.assertEqual(baseline["run_configuration"]["descriptor_matcher"], "exact_cpu_brute_force")
        self.assertEqual(baseline["run_configuration"]["mapper"], "incremental")
        self.assertEqual(
            baseline["run_configuration"]["bundle_adjustment_max_iterations"],
            {"automatic": 75, "orbit": 75, "walkthrough": 75, "large_area": 94},
        )
        for replacement in ("0" * 40, None):
            changed = valid_reference_config()
            changed["references"]["paired_baseline"]["git_commit"] = replacement
            with self.subTest(replacement=replacement):
                with self.assertRaisesRegex(benchmark.ConfigError, "paired_baseline"):
                    benchmark.validate_reference_config(changed)
        changed = valid_reference_config()
        changed["references"]["paired_baseline"]["run_configuration"]["descriptor_matcher"] = "faiss"
        with self.assertRaisesRegex(benchmark.ConfigError, "paired_baseline"):
            benchmark.validate_reference_config(changed)

    def test_result_schema_closes_top_level_and_scene_contracts(self) -> None:
        schema = json.loads((ROOT / "scripts/benchmark/result.schema.json").read_text(encoding="utf-8"))
        self.assertIs(schema["additionalProperties"], False)
        self.assertIs(schema["$defs"]["sceneResult"]["additionalProperties"], False)
        self.assertIs(schema["$defs"]["metrics"]["additionalProperties"], False)
        metric_properties = schema["$defs"]["metrics"]["properties"]
        self.assertEqual(set(metric_properties), benchmark.ALLOWED_METRICS)
        boolean_metrics = {
            name
            for name, definition in metric_properties.items()
            if definition == {"$ref": "#/$defs/booleanMetric"}
        }
        self.assertEqual(boolean_metrics, benchmark.BOOLEAN_METRICS)
        self.assertIn("gate_scopes", schema["$defs"]["sceneResult"]["required"])
        self.assertIn("category", schema["$defs"]["sceneResult"]["required"])
        self.assertIn("capture_traits", schema["$defs"]["sceneResult"]["required"])
        self.assertEqual(
            schema["$defs"]["orientationStatusMetric"]["properties"]["value"]["enum"],
            ["verified", "axis_aligned_sign_unverified", "unresolved"],
        )
        for name in (
            "scheduled_pairs",
            "attempted_pairs",
            "raw_matched_pairs",
            "spatially_verified_pairs",
            "connected_components",
            "isolated_views",
            "local_pairs",
            "retrieval_pairs",
            "loop_pairs",
            "matcher_seconds",
            "mapping_seconds",
            "matching_speedup",
            "mapping_speedup",
            "bundle_adjustment_cycles",
            "orientation_status",
            "orientation_median_residual_degrees",
            "orientation_p90_residual_degrees",
            "orientation_bootstrap_p95_degrees",
            "raster_fallback_count",
            "maximum_tile_intersections",
            "dropped_intersection_count",
        ):
            self.assertIn(name, schema["$defs"]["metrics"]["properties"])
        evidence_schema = json.loads(
            (ROOT / "scripts/benchmark/evidence.schema.json").read_text(encoding="utf-8")
        )
        self.assertIs(evidence_schema["additionalProperties"], False)
        self.assertIs(evidence_schema["properties"]["artifacts"]["additionalProperties"]["additionalProperties"], False)
        self.assertIn("measurement_runner", evidence_schema["required"])
        self.assertIn("gate_scopes", evidence_schema["required"])
        self.assertIn("measurement_runner", schema["$defs"]["evidenceRecord"]["required"])

    def test_result_schema_reserves_exit_code_130_for_cancellation(self) -> None:
        schema = json.loads((ROOT / "scripts/benchmark/result.schema.json").read_text(encoding="utf-8"))
        exit_rules = schema["$defs"]["sceneResult"]["properties"]["exit"]["allOf"]
        self.assertIn(
            {
                "if": {"properties": {"code": {"const": 130}}, "required": ["code"]},
                "then": {"properties": {"reason": {"const": "cancelled"}, "cancelled": {"const": True}}},
            },
            exit_rules,
        )

    def test_valid_smoke_manifest_and_config_round_trip(self) -> None:
        corpus = valid_corpus()
        config = valid_reference_config()
        benchmark.validate_corpus(corpus, expected_profile="smoke")
        benchmark.validate_reference_config(config)
        encoded = benchmark.canonical_json_bytes({"corpus": corpus, "config": config})
        self.assertEqual(json.loads(encoded), {"config": config, "corpus": corpus})

    def test_release_manifest_requires_exact_category_counts(self) -> None:
        corpus = release_corpus()
        benchmark.validate_corpus(corpus, expected_profile="release")
        corpus["scenes"].pop()
        with self.assertRaisesRegex(benchmark.ConfigError, "category counts"):
            benchmark.validate_corpus(corpus, expected_profile="release")

    def test_supplied_media_requires_structured_commercial_authorization(self) -> None:
        cases = []
        pending = valid_corpus()
        pending["scenes"][0]["provenance"] = {
            "source": "External benchmark corpus",
            "authorization_status": "pending",
            "authorization_sha256": None,
        }
        cases.append((pending, "completed authorization"))

        false_redistributable = valid_corpus()
        false_redistributable["scenes"][0]["provenance"] = {
            "source": "External benchmark corpus",
            "authorization_status": "redistributable",
            "authorization_sha256": None,
        }
        cases.append((false_redistributable, "cannot claim redistributable"))

        missing_consent = valid_corpus()
        missing_consent["scenes"][0]["provenance"]["authorization_sha256"] = None
        cases.append((missing_consent, "documented consent requires"))

        for corpus, expected in cases:
            with self.subTest(expected=expected), self.assertRaisesRegex(
                benchmark.ConfigError,
                expected,
            ):
                benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_release_scenarios_and_supplied_inputs_cannot_be_duplicated(self) -> None:
        corpus = release_corpus()
        same_category = [
            scene for scene in corpus["scenes"] if scene["category"] == "object_orbit"
        ]
        same_category[1]["scenario"] = same_category[0]["scenario"]
        with self.assertRaisesRegex(benchmark.ConfigError, "object_orbit scenarios"):
            benchmark.validate_corpus(corpus, expected_profile="release")

        first = valid_scene("first-scene")
        second = valid_scene("second-scene")
        seen: dict[str, str] = {}
        digest = "sha256:" + "1" * 64
        benchmark._record_unique_release_input_digest(first, digest, seen)
        with self.assertRaisesRegex(benchmark.ConfigError, "same content digest"):
            benchmark._record_unique_release_input_digest(second, digest, seen)

    def test_release_manifest_freezes_scale_and_invalid_scenario_closure(self) -> None:
        corpus = release_corpus()
        for scene in corpus["scenes"]:
            if scene["scale_lanes"] == [500]:
                scene["scale_lanes"] = [250]
                scene["aggregate_scale"] = 250
        with self.assertRaisesRegex(benchmark.ConfigError, "scale closure"):
            benchmark.validate_corpus(corpus, expected_profile="release")

        corpus = release_corpus()
        for scene in corpus["scenes"]:
            if scene["category"] == "invalid":
                scene["expected_outcome"]["failure_type"] = "disconnected_input"
        with self.assertRaisesRegex(benchmark.ConfigError, "invalid scenario"):
            benchmark.validate_corpus(corpus, expected_profile="release")

    def test_duplicate_ids_are_rejected(self) -> None:
        corpus = valid_corpus()
        corpus["scenes"].append(valid_scene())
        with self.assertRaisesRegex(benchmark.ConfigError, "duplicate scene id"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_missing_license_and_provenance_are_rejected(self) -> None:
        for missing in ("license", "provenance"):
            corpus = valid_corpus()
            del corpus["scenes"][0][missing]
            with self.subTest(missing=missing):
                with self.assertRaises(benchmark.ConfigError):
                    benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_absolute_and_traversing_media_paths_are_rejected(self) -> None:
        for unsafe in ("/tmp/scene.mov", "../scene.mov", "external/../../scene.mov"):
            corpus = valid_corpus()
            corpus["scenes"][0]["input"]["media_path"] = unsafe
            with self.subTest(path=unsafe):
                with self.assertRaisesRegex(benchmark.ConfigError, "unsafe media path"):
                    benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_invalid_scale_and_duplicate_holdouts_are_rejected(self) -> None:
        corpus = valid_corpus()
        corpus["scenes"][0]["scale_lanes"] = [31]
        with self.assertRaisesRegex(benchmark.ConfigError, "scale lane"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")
        corpus = valid_corpus()
        corpus["scenes"][0]["split"]["holdout_by_scale"]["30"] = [4, 4]
        with self.assertRaisesRegex(benchmark.ConfigError, "holdouts"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_invalid_thresholds_are_rejected(self) -> None:
        config = valid_reference_config()
        config["thresholds"]["coverage"]["absolute_min"] = 1.01
        with self.assertRaisesRegex(benchmark.ConfigError, "coverage.absolute_min"):
            benchmark.validate_reference_config(config)

    def test_speed_thresholds_are_scale_and_capture_specific(self) -> None:
        speed = valid_reference_config()["thresholds"]["speed"]
        self.assertEqual(
            speed,
            {
                "m4_max_balanced_p50_seconds_max_by_scale": {
                    "30": 120.0,
                    "120": 300.0,
                    "250": 600.0,
                    "500": 1200.0,
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
        )

    def test_unsupplied_scene_cannot_claim_reference_availability(self) -> None:
        corpus = valid_corpus()
        corpus["scenes"][0]["input"]["supplied"] = False
        corpus["scenes"][0]["split"] = {"status": "pending"}
        with self.assertRaisesRegex(benchmark.ConfigError, "unsupplied.*reference"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_invalid_scenes_do_not_require_render_or_pose_references(self) -> None:
        corpus = valid_corpus()
        scene = corpus["scenes"][0]
        scene["category"] = "invalid"
        scene["expected_outcome"] = {
            "kind": "invalid",
            "failure_type": "disconnected_input",
        }
        scene["gate_scopes"] = ["invalid_input"]
        scene["split"] = {"status": "not_applicable"}
        scene["reference"] = {"status": "not_applicable"}
        benchmark.validate_corpus(corpus, expected_profile="smoke")

        scene["expected_outcome"] = {"kind": "valid"}
        scene["category"] = "object_orbit"
        scene["gate_scopes"] = ["scene_quality"]
        with self.assertRaisesRegex(benchmark.ConfigError, "not_applicable"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")


class GateEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.thresholds = valid_reference_config()["thresholds"]

    def test_every_threshold_accepts_the_exact_boundary(self) -> None:
        evaluation = benchmark.evaluate_gates(passing_metrics(), self.thresholds)
        self.assertEqual(evaluation, {"status": "passed", "blocking_reasons": [], "failures": []})

    def test_gate_scopes_only_require_their_own_metrics(self) -> None:
        metrics = passing_metrics()
        quality_names = benchmark.GATE_SCOPE_METRICS["scene_quality"] | {
            "orientation_median_residual_degrees",
            "orientation_p90_residual_degrees",
            "orientation_bootstrap_p95_degrees",
            "orientation_physical_up_error_degrees",
            "orientation_sign_correct",
        }
        quality_only = {name: metrics[name] for name in quality_names}
        self.assertEqual(
            benchmark.evaluate_gates(
                quality_only,
                self.thresholds,
                gate_scopes=["scene_quality"],
                scale=30,
            )["status"],
            "passed",
        )
        with self.assertRaisesRegex(benchmark.ConfigError, "gate_scopes"):
            benchmark.evaluate_gates(metrics, self.thresholds, gate_scopes=[])

    def test_colmap_relative_registration_ratio_is_enforced(self) -> None:
        metrics = passing_metrics()
        metrics["registered_views"] = measured(94)
        evaluation = benchmark.evaluate_gates(metrics, self.thresholds)
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("colmap_relative" in item for item in evaluation["failures"]))

    def test_each_threshold_miss_fails(self) -> None:
        misses = {
            "registered_views": measured(89),
            "residual_median_pixels": measured(1.5001),
            "residual_p90_pixels": measured(3.0001),
            "ate_colmap_ratio": measured(1.1001),
            "rotation_rpe_delta_degrees": measured(0.2001),
            "translation_rpe_delta_percentage_points": measured(2.0001),
            "balanced_scene_psnr_loss_db": measured(1.0001),
            "balanced_scene_ssim_loss": measured(0.0201),
            "balanced_scene_lpips_increase": measured(0.0301),
            "fast_scene_psnr_loss_db": measured(1.0001),
            "fast_scene_ssim_loss": measured(0.0201),
            "fast_scene_lpips_increase": measured(0.0301),
            "fast_end_to_end_speedup": measured(1.9999),
            "m4_max_p50_seconds": measured(120.0001),
            "long_sequence_analysis_fps": measured(4.9999),
            "long_sequence_frames": measured(2999),
            "long_sequence_rss_growth_fraction": measured(0.0501),
            "repeat_runs": measured(49),
            "crashes": measured(1),
            "corrupt_outputs": measured(1),
            "normal_photo_toolchain_bytes": measured(2_500_000_001),
            "large_area_toolchain_bytes": measured(2_500_000_001),
            "deterministic_restart": measured(False),
        }
        for key, value in misses.items():
            with self.subTest(metric=key):
                metrics = passing_metrics()
                metrics[key] = value
                self.assertEqual(benchmark.evaluate_gates(metrics, self.thresholds)["status"], "failed")

    def test_geometry_speedup_is_evaluated_across_the_suite_not_per_scene(self) -> None:
        metrics = passing_metrics()
        metrics["balanced_geometry_speedup"] = measured(1.0)
        self.assertEqual(
            benchmark.evaluate_gates(
                metrics,
                self.thresholds,
                gate_scopes=["suite_performance"],
                scale=30,
            )["status"],
            "passed",
        )

    def test_all_memory_tier_boundaries_and_misses(self) -> None:
        cases = (
            ("eight_gb_fast", 8_000_000_000, 6_500_000_000, True),
            ("eight_gb_fast", 8_000_000_000, 6_500_000_001, False),
            ("constrained", 16_000_000_000, 12_000_000_000, True),
            ("constrained", 16_000_000_000, 12_000_000_001, False),
            ("larger", 48_000_000_000, 36_000_000_000, True),
            ("larger", 48_000_000_000, 36_000_000_001, False),
        )
        for lane, total, peak, should_pass in cases:
            with self.subTest(lane=lane, peak=peak):
                metrics = passing_metrics()
                metrics["memory_lane"] = measured(lane)
                metrics["machine_memory_bytes"] = measured(total)
                metrics["peak_memory_bytes"] = measured(peak)
                status = benchmark.evaluate_gates(metrics, self.thresholds)["status"]
                self.assertEqual(status, "passed" if should_pass else "failed")

    def test_unified_memory_gate_uses_the_larger_of_rss_and_metal_allocation(self) -> None:
        metrics = passing_metrics()
        metrics["memory_lane"] = measured("larger")
        metrics["machine_memory_bytes"] = measured(48_000_000_000)
        metrics["peak_memory_bytes"] = measured(1_000_000_000)
        metrics["peak_metal_allocated_bytes"] = measured(999_000_000_000)

        evaluation = benchmark.evaluate_gates(
            metrics,
            self.thresholds,
            gate_scopes=["scene_performance"],
        )

        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("unified" in failure for failure in evaluation["failures"]))

        metrics["memory_lane"] = measured("eight_gb_fast")
        metrics["machine_memory_bytes"] = measured(8_000_000_000)
        metrics["peak_memory_bytes"] = measured(6_000_000_000)
        metrics["peak_metal_allocated_bytes"] = measured(6_000_000_000)
        self.assertEqual(
            benchmark.evaluate_gates(
                metrics,
                self.thresholds,
                gate_scopes=["scene_performance"],
            )["status"],
            "passed",
        )

    def test_missing_required_metric_blocks_instead_of_substituting_zero(self) -> None:
        metrics = passing_metrics()
        metrics["residual_median_pixels"] = unavailable()
        evaluation = benchmark.evaluate_gates(metrics, self.thresholds)
        self.assertEqual(evaluation["status"], "blocked")
        self.assertTrue(any("residual_median_pixels" in item for item in evaluation["blocking_reasons"]))

    def test_non_real_residual_provenance_fails(self) -> None:
        metrics = passing_metrics()
        metrics["residual_provenance"] = measured("mapper_summary")
        evaluation = benchmark.evaluate_gates(metrics, self.thresholds)
        self.assertEqual(evaluation["status"], "failed")

    def test_negative_nonfinite_and_cross_field_metrics_fail(self) -> None:
        cases = {
            "negative residual": {"residual_median_pixels": measured(-0.1)},
            "negative crashes": {"crashes": measured(-1)},
            "nonfinite": {"ate_colmap_ratio": measured(float("nan"))},
            "registered exceeds total": {
                "registered_views": measured(101),
                "total_views": measured(100),
            },
            "p90 below median": {
                "residual_median_pixels": measured(1.0),
                "residual_p90_pixels": measured(0.5),
            },
        }
        for label, replacements in cases.items():
            with self.subTest(case=label):
                metrics = passing_metrics()
                metrics.update(replacements)
                self.assertEqual(benchmark.evaluate_gates(metrics, self.thresholds)["status"], "failed")

    def test_unavailable_metric_reason_is_a_controlled_code(self) -> None:
        metrics = passing_metrics()
        metrics["residual_median_pixels"] = {
            "availability": "not_available",
            "reason": "alice-macbook-pro.local",
        }
        evaluation = benchmark.evaluate_gates(metrics, self.thresholds)
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("reason" in failure for failure in evaluation["failures"]))

    def test_valid_geometry_requires_connected_graph_and_lossless_rasterization(self) -> None:
        cases = {
            "missing graph": {"connected_components": unavailable()},
            "disconnected graph": {"connected_components": measured(2)},
            "isolated view": {"isolated_views": measured(1)},
            "dropped intersections": {"dropped_intersection_count": measured(1)},
            "verified exceeds raw": {
                "raw_matched_pairs": measured(80),
                "spatially_verified_pairs": measured(81),
            },
        }
        for label, replacements in cases.items():
            with self.subTest(case=label):
                metrics = passing_metrics()
                metrics.update(replacements)
                self.assertNotEqual(
                    benchmark.evaluate_gates(metrics, self.thresholds)["status"],
                    "passed",
                )

    def test_suite_speed_gates_are_enforced_by_category_and_topology(self) -> None:
        def scene(
            scene_id: str,
            category: str,
            traits: list[str],
            *,
            geometry: float = 2.0,
            matching: float = 10.0,
            mapping: float = 1.5,
            scale: int = 120,
        ) -> dict[str, object]:
            return {
                "scene_id": scene_id,
                "category": category,
                "capture_traits": traits,
                "gate_scopes": ["suite_performance"],
                "expected_outcome": {"kind": "valid"},
                "scale": scale,
                "aggregate_scale": scale,
                "metrics": {
                    "balanced_geometry_speedup": measured(geometry),
                    "matching_speedup": measured(matching),
                    "mapping_speedup": measured(mapping),
                },
            }

        def complete(rows: list[dict[str, object]]) -> list[dict[str, object]]:
            return rows + [
                scene(f"ordered-{scale}", "low_light", ["ordered"], scale=scale)
                for scale in (250, 500)
            ] + [
                scene(
                    f"unordered-{scale}",
                    "professional_photos",
                    ["unordered"],
                    mapping=1.0,
                    scale=scale,
                )
                for scale in (250, 500)
            ]

        passing = complete(
            [
                scene("ordered", "object_orbit", ["ordered"]),
                scene(
                    "unordered",
                    "professional_photos",
                    ["unordered"],
                    mapping=1.0 / 1.1,
                ),
            ]
        )
        self.assertEqual(
            benchmark.evaluate_suite_performance(passing, self.thresholds)["status"],
            "passed",
        )

        failures = {
            "category median": [
                scene("ordered", "object_orbit", ["ordered"], geometry=1.0),
                scene("unordered", "professional_photos", ["unordered"], geometry=4.0),
            ],
            "matching mean": [
                scene("ordered", "object_orbit", ["ordered"], matching=9.9),
                scene("unordered", "professional_photos", ["unordered"], matching=9.9),
            ],
            "matching regression": [
                scene("ordered", "object_orbit", ["ordered"], matching=0.99),
                scene("unordered", "professional_photos", ["unordered"], matching=101.1),
            ],
            "ordered mapping": [
                scene("ordered", "object_orbit", ["ordered"], mapping=1.49),
                scene("unordered", "professional_photos", ["unordered"], mapping=1.0),
            ],
            "unordered mapping": [
                scene("ordered", "object_orbit", ["ordered"]),
                scene(
                    "unordered",
                    "professional_photos",
                    ["unordered"],
                    mapping=1.0 / 1.1001,
                ),
            ],
        }
        for label, scenes in failures.items():
            with self.subTest(case=label):
                self.assertEqual(
                    benchmark.evaluate_suite_performance(complete(scenes), self.thresholds)["status"],
                    "failed",
                )

        incomplete = passing[:-1]
        incomplete = [item for item in incomplete if item["scale"] != 500]
        self.assertEqual(
            benchmark.evaluate_suite_performance(incomplete, self.thresholds)["status"],
            "blocked",
        )

    def test_suite_rendering_medians_pass_globally_and_per_capture_category(self) -> None:
        def scene(
            scene_id: str,
            category: str,
            *,
            psnr_loss: float,
            scale: int = 120,
            aggregate_scale: int = 120,
        ) -> dict[str, object]:
            metrics = passing_metrics()
            metrics["balanced_scene_psnr_loss_db"] = measured(psnr_loss)
            metrics["paired_balanced_scene_psnr_loss_db"] = measured(0.1)
            return {
                "scene_id": scene_id,
                "category": category,
                "gate_scopes": ["scene_quality"],
                "expected_outcome": {"kind": "valid"},
                "scale": scale,
                "aggregate_scale": aggregate_scale,
                "metrics": metrics,
            }

        category_regression = [
            scene("orbit", "object_orbit", psnr_loss=0.6),
            scene("photos", "professional_photos", psnr_loss=0.1),
        ]
        evaluation = benchmark.evaluate_suite_quality(category_regression, self.thresholds)
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("object_orbit" in item for item in evaluation["failures"]))

        missing_primary = [
            scene(
                "orbit",
                "object_orbit",
                psnr_loss=0.1,
                scale=30,
                aggregate_scale=120,
            ),
            scene("photos", "professional_photos", psnr_loss=0.1),
        ]
        evaluation = benchmark.evaluate_suite_quality(missing_primary, self.thresholds)
        self.assertEqual(evaluation["status"], "blocked")
        self.assertTrue(any("primary" in item for item in evaluation["blocking_reasons"]))


class InvalidSceneTests(unittest.TestCase):
    def test_declared_failure_without_corrupt_ply_passes(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        actual = {
            "exit_code": 2,
            "termination_reason": "exit",
            "cancelled": False,
            "failure_type": "disconnected_input",
            "corrupt_ply": False,
        }
        self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "passed")

    def test_wrong_failure_or_corrupt_ply_fails(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        for actual in (
            {**successful_actual(), "failure_type": None},
            {**successful_actual(), "exit_code": 2, "failure_type": "other"},
            {**successful_actual(), "exit_code": 2, "failure_type": "disconnected_input", "corrupt_ply": True},
            {
                **successful_actual(),
                "exit_code": 130,
                "termination_reason": "cancelled",
                "failure_type": "disconnected_input",
                "cancelled": True,
            },
        ):
            with self.subTest(actual=actual):
                self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "failed")

    def test_missing_failure_type_blocks(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        actual = {**successful_actual(), "exit_code": 2, "failure_type": None}
        self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "blocked")

    def test_missing_or_noninteger_exit_blocks(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        for exit_code in (None, "2", True):
            actual = {**successful_actual(), "exit_code": exit_code, "failure_type": "disconnected_input"}
            with self.subTest(exit_code=exit_code):
                self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "blocked")

    def test_contradictory_termination_evidence_blocks(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        contradictory_cases = (
            {
                **successful_actual(),
                "exit_code": 2,
                "termination_reason": "cancelled",
                "cancelled": False,
                "failure_type": "disconnected_input",
            },
            {
                **successful_actual(),
                "exit_code": 130,
                "termination_reason": "exit",
                "cancelled": False,
                "failure_type": "disconnected_input",
            },
        )
        for actual in contradictory_cases:
            with self.subTest(actual=actual):
                self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "blocked")


class MetadataAndPersistenceTests(unittest.TestCase):
    def test_canonical_json_rejects_nonfinite_numbers(self) -> None:
        with self.assertRaises(ValueError):
            benchmark.canonical_json_bytes({"metric": float("nan")})

    def test_json_loader_rejects_nonstandard_nan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"metric":NaN}\n', encoding="utf-8")
            with self.assertRaisesRegex(benchmark.ConfigError, "non-finite"):
                benchmark._load_json(path, "fixture")

    def test_machine_metadata_does_not_include_machine_identity(self) -> None:
        with mock.patch.dict(os.environ, {"USER": "private-user", "HOME": "/Users/private-user"}):
            metadata = benchmark.collect_machine_metadata(
                command_runner=lambda argv: "fixture-value",
                platform_data={
                    "macos_version": "15.5",
                    "macos_build": "24F74",
                    "hardware_model": "Mac16,5",
                    "chip": "Apple M4 Max",
                    "logical_cpus": 16,
                    "physical_cpus": 12,
                    "physical_memory_bytes": 48_000_000_000,
                },
            )
        encoded = json.dumps(metadata).lower()
        for forbidden in ("private-user", "/users/", "hostname", "serial", "username", "home"):
            self.assertNotIn(forbidden, encoded)

    def test_atomic_write_preserves_previous_result_when_interrupted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "suite.json"
            path.write_text('{"old":true}\n', encoding="utf-8")

            def interrupt(_: Path) -> None:
                raise RuntimeError("simulated interruption")

            with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                benchmark.atomic_write_json(path, {"new": True}, before_replace=interrupt)
            self.assertEqual(path.read_text(encoding="utf-8"), '{"old":true}\n')
            self.assertEqual(list(path.parent.glob(".suite.json.*.tmp")), [])


class EvidenceProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.key = b"release-evidence-test-key-material-32-bytes"
        evidence.LPIPS_DISTANCE_OVERRIDE = lambda first, second: float(
            abs(first.mean() - second.mean())
        )

    def tearDown(self) -> None:
        evidence.LPIPS_DISTANCE_OVERRIDE = None

    def produce(self, root: Path, lane: str) -> tuple[Path, dict[str, object]]:
        observations = raw_observations(lane)
        write_evidence_artifacts(root, observations)
        output = root / "attestation.json"
        attestation = evidence.produce_attestation(
            evidence_request(lane=lane),
            observations,
            root,
            output,
            self.key,
            lane,
            runner_identity(lane),
            machine=evidence_machine(lane),
        )
        output.write_bytes(evidence.canonical_json_bytes(attestation) + b"\n")
        return output, attestation

    def test_producer_derives_metrics_from_raw_samples(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output, attestation = self.produce(Path(directory), evidence.LANE_REFERENCE)
            metrics = attestation["metrics"]
            validate_attestation_schema(attestation)
            schema_invalid = json.loads(json.dumps(attestation))
            schema_invalid["gate_scopes"] = ["invalid_input"]
            with self.assertRaises(ValidationError):
                validate_attestation_schema(schema_invalid)
            self.assertEqual(metrics["registered_views"], measured(30))
            self.assertEqual(metrics["repeat_runs"], measured(50))
            self.assertEqual(metrics["deterministic_restart"], measured(True))
            self.assertEqual(metrics["m4_max_p50_seconds"], measured(100.0))
            self.assertEqual(metrics["fast_end_to_end_speedup"], measured(2.0))
            self.assertEqual(metrics["scheduled_pairs"], measured(119))
            self.assertEqual(metrics["matching_speedup"], measured(10.0))
            self.assertEqual(metrics["mapping_speedup"], measured(1.5))
            self.assertEqual(metrics["orientation_status"], measured("verified"))
            self.assertEqual(
                metrics["orientation_bootstrap_p95_degrees"],
                measured(2.0),
            )
            self.assertEqual(
                attestation["measurement_runner"],
                runner_identity(evidence.LANE_REFERENCE),
            )
            verified = evidence.verify_attestation(
                output,
                evidence_request(),
                evidence.LANE_REFERENCE,
                self.key,
                runner_identity(evidence.LANE_REFERENCE),
            )
            self.assertEqual(verified["metrics"], metrics)

    def test_invalid_attestation_does_not_require_quality_or_timing_references(self) -> None:
        scene = valid_scene(scene_id="invalid-01")
        scene["category"] = "invalid"
        scene["capture_traits"] = ["segmented"]
        scene["gate_scopes"] = ["invalid_input"]
        scene["split"] = {"status": "not_applicable"}
        scene["reference"] = {"status": "not_applicable"}
        scene["expected_outcome"] = {
            "kind": "invalid",
            "failure_type": "disconnected_input",
        }
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest="sha256:" + "2" * 64,
            thresholds_digest="sha256:" + "3" * 64,
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity=TEST_TOOLCHAIN_IDENTITY,
        )
        request = benchmark._evidence_request(
            scene,
            30,
            evidence.LANE_REFERENCE,
            identity,
            "sha256:" + "1" * 64,
            runner_identity(evidence.RENDERING_DRIVER_IDENTITY, "e"),
        )
        self.assertEqual(request["holdout_indices"], [])
        self.assertEqual(request["reference_artifacts"], {"status": "not_applicable"})

        observations = raw_observations(evidence.LANE_REFERENCE)
        observations = {
            key: observations[key]
            for key in ("schema_version", "artifacts", "commands", "actual", "baseline")
        }
        observations["artifacts"] = {
            key: value
            for key, value in observations["artifacts"].items()
            if key in {"command_log", "supervisor_run", "stdout_log", "stderr_log"}
        }
        observations["actual"] = {
            "exit_code": 2,
            "termination_reason": "exit",
            "cancelled": False,
            "failure_type": "disconnected_input",
            "corrupt_ply": False,
        }
        observations["commands"] = invalid_execution_receipt(
            request,
            observations["actual"],
            evidence.LANE_REFERENCE,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.produce_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(attestation["actual"]["failure_type"], "disconnected_input")
        validate_attestation_schema(attestation)
        self.assertEqual(
            attestation["metrics"]["registered_views"],
            {"availability": "not_available", "reason": "not_measured"},
        )

        observations["artifacts"]["output_ply"] = "splat.ply"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "invalid.*output_ply"):
                evidence.produce_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_output_ply_requires_nonempty_finite_complete_splat_payload(self) -> None:
        invalid_files = {
            "zero vertices": "ply\nformat ascii 1.0\nelement vertex 0\nend_header\n",
            "truncated body": VALID_SPLAT_PLY.rsplit("\n", 2)[0] + "\n",
            "nonfinite value": VALID_SPLAT_PLY.replace(
                "0 0 0 0 0 0 1 0 0 0 1 0 0 0",
                "nan 0 0 0 0 0 1 0 0 0 1 0 0 0",
            ),
            "extra body": VALID_SPLAT_PLY + "0 0 0 0 0 0 1 0 0 0 1 0 0 0\n",
        }
        for label, content in invalid_files.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                observations = raw_observations(evidence.LANE_REFERENCE)
                write_evidence_artifacts(root, observations)
                (root / "splat.ply").write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(evidence.EvidenceError, "output_ply"):
                    evidence.produce_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_runner_cannot_supply_rendering_scores(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["rendering"] = {
            "balanced": [{"candidate_psnr": 100.0}],
            "fast": [{"candidate_psnr": 100.0}],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "unknown rendering"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_scene_quality_rejects_self_reported_rendering_without_pixel_artifacts(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            observations["artifacts"].pop("rendering_manifest", None)
            (root / "rendering-manifest.json").unlink(missing_ok=True)
            (root / "observations.json").write_bytes(
                evidence.canonical_json_bytes(observations) + b"\n"
            )
            with self.assertRaisesRegex(evidence.EvidenceError, "rendering_manifest"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_pair_list_is_bound_to_the_resolved_policy_and_verified_graph(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        mutations = {
            "duplicate": lambda value: value["pairs"].append(dict(value["pairs"][0])),
            "wrong temporal edge": lambda value: value["pairs"][0].update({"view_b": 3}),
            "false verified count": lambda value: value["pairs"][0].update(
                {"spatially_verified": False}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_evidence_artifacts(root, observations)
                pair_list = fixture_pair_list()
                mutate(pair_list)
                (root / "pair-list.json").write_bytes(
                    evidence.canonical_json_bytes(pair_list) + b"\n"
                )
                with self.assertRaisesRegex(evidence.EvidenceError, "pair_list"):
                    evidence.produce_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_configured_retrieval_requires_query_level_closure(self) -> None:
        request = evidence_request()
        request["candidate_run_configuration"].update(
            {
                "vocabulary_candidate_count": 20,
                "vocabulary_verified_neighbor_count": 2,
                "vocabulary_query_stride": 10,
            }
        )
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "retrieval.*quer"):
                evidence.produce_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_retrieval_query_closure_binds_attempts_neighbors_and_retry_outcome(self) -> None:
        request = evidence_request()
        request["candidate_run_configuration"].update(
            {
                "vocabulary_candidate_count": 20,
                "vocabulary_verified_neighbor_count": 2,
                "vocabulary_query_stride": 10,
            }
        )
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        observations["pipeline_metrics"].update(
            {
                "scheduled_pairs": 125,
                "attempted_pairs": 125,
                "raw_matched_pairs": 125,
                "spatially_verified_pairs": 125,
                "retrieval_pairs": 6,
            }
        )
        mutations = {
            "valid": lambda value: None,
            "missing query": lambda value: value["retrieval"]["queries"].pop(),
            "unbounded attempt": lambda value: value["retrieval"]["queries"][0].update(
                {
                    "attempted_candidate_count": 21,
                    "attempted_targets": list(range(12, 30)) + [3, 5, 6],
                }
            ),
            "unretained verified neighbor": lambda value: value["retrieval"]["queries"][0][
                "verified_retained_neighbors"
            ].append(15),
            "false retry outcome": lambda value: value["retrieval"]["queries"][0].update(
                {"retry_outcome": "denser_faiss_exhausted"}
            ),
            "exact recovery without preceding closure": lambda value: value["retrieval"][
                "queries"
            ][0].update(
                {
                    "retry_outcome": "exact_recovery_retained",
                    "matcher_used": "exact",
                    "fallback_reason": "faiss_geometry_rejected_after_retries",
                }
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_evidence_artifacts(root, observations, request)
                pair_list = fixture_pair_list_with_retrieval()
                mutate(pair_list)
                (root / "pair-list.json").write_bytes(
                    evidence.canonical_json_bytes(pair_list) + b"\n"
                )
                if label == "valid":
                    evidence.produce_attestation(
                        request,
                        observations,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )
                else:
                    with self.assertRaisesRegex(evidence.EvidenceError, "retrieval"):
                        evidence.produce_attestation(
                            request,
                            observations,
                            root,
                            root / "attestation.json",
                            self.key,
                            evidence.LANE_REFERENCE,
                            runner_identity(evidence.LANE_REFERENCE),
                            machine=evidence_machine(evidence.LANE_REFERENCE),
                        )

    def test_retrieval_retained_outcome_requires_the_resolved_neighbor_target(self) -> None:
        request = evidence_request()
        request["candidate_run_configuration"].update(
            {
                "vocabulary_candidate_count": 20,
                "vocabulary_verified_neighbor_count": 2,
                "vocabulary_query_stride": 10,
            }
        )
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        observations["pipeline_metrics"].update(
            {
                "scheduled_pairs": 125,
                "attempted_pairs": 125,
                "raw_matched_pairs": 125,
                "spatially_verified_pairs": 124,
                "retrieval_pairs": 6,
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            pair_list = fixture_pair_list_with_retrieval()
            pair_list["retrieval"]["queries"][0]["verified_retained_neighbors"] = [13]
            for pair in pair_list["pairs"]:
                if (
                    pair["pair_type"] == "retrieval"
                    and pair["query_view"] == 0
                    and 14 in {pair["view_a"], pair["view_b"]}
                ):
                    pair["spatially_verified"] = False
            (root / "pair-list.json").write_bytes(
                evidence.canonical_json_bytes(pair_list) + b"\n"
            )
            with self.assertRaisesRegex(evidence.EvidenceError, "retained neighbor target"):
                evidence.produce_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_unordered_small_photo_route_requires_exact_exhaustive_faiss_closure(self) -> None:
        request = evidence_request()
        request["input_kind"] = "photos"
        request["capture_traits"] = ["unordered"]
        request["candidate_run_configuration"].update(
            {
                "input_topology": "unordered",
                "pairing_policy": "unordered_exhaustive",
                "temporal_pairing": "none",
                "temporal_offsets": [],
                "vocabulary_candidate_count": 0,
                "vocabulary_verified_neighbor_count": 0,
                "vocabulary_query_stride": 1,
                "ba_global_frames_ratio": 1.1,
                "ba_global_points_ratio": 1.1,
            }
        )
        selection = evidence.canonical_json_bytes(
            {
                "schema_version": 1,
                "views": [
                    {"view_index": index, "clip_id": f"photo-{index}", "source_kind": "photo"}
                    for index in range(30)
                ],
            }
        ) + b"\n"
        request["reference_artifacts"]["selection_manifest_sha256"] = evidence.sha256_bytes(
            selection
        )
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        observations["pipeline_metrics"].update(
            {
                "scheduled_pairs": 435,
                "attempted_pairs": 435,
                "raw_matched_pairs": 435,
                "spatially_verified_pairs": 435,
                "local_pairs": 0,
                "retrieval_pairs": 0,
                "loop_pairs": 0,
            }
        )
        mutations = {
            "valid": lambda value: None,
            "missing pair": lambda value: value["pairs"].pop(),
            "extra pair": lambda value: value["pairs"].append(dict(value["pairs"][0])),
            "wrong matcher": lambda value: value["pairs"][0].update(
                {"matcher_used": "exact"}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                changed_observations = json.loads(json.dumps(observations))
                pair_list = fixture_unordered_exhaustive_pair_list()
                mutate(pair_list)
                if label == "missing pair":
                    for metric in (
                        "scheduled_pairs",
                        "attempted_pairs",
                        "raw_matched_pairs",
                        "spatially_verified_pairs",
                    ):
                        changed_observations["pipeline_metrics"][metric] -= 1
                elif label == "extra pair":
                    changed_observations["pipeline_metrics"]["scheduled_pairs"] += 1
                root = Path(directory)
                write_evidence_artifacts(root, changed_observations, request)
                (root / "selection-manifest.json").write_bytes(selection)
                (root / "pair-list.json").write_bytes(
                    evidence.canonical_json_bytes(pair_list) + b"\n"
                )
                if label == "valid":
                    evidence.produce_attestation(
                        request,
                        changed_observations,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )
                else:
                    with self.assertRaisesRegex(evidence.EvidenceError, "exhaustive|duplicate"):
                        evidence.produce_attestation(
                            request,
                            changed_observations,
                            root,
                            root / "attestation.json",
                            self.key,
                            evidence.LANE_REFERENCE,
                            runner_identity(evidence.LANE_REFERENCE),
                            machine=evidence_machine(evidence.LANE_REFERENCE),
                        )

    def test_raw_pipeline_metrics_are_closed_nullable_and_typed(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        cases = (
            ({**observations["pipeline_metrics"], "unknown": 1}, "unknown"),
            ({**observations["pipeline_metrics"], "scheduled_pairs": -1}, "scheduled_pairs"),
            ({**observations["pipeline_metrics"], "orientation_status": "guessed"}, "orientation_status"),
        )
        for raw_metrics, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                changed["pipeline_metrics"] = raw_metrics
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.produce_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_timing_requires_warmup_alternation_and_declared_repetition_counts(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        cases = []
        missing_warmup = json.loads(json.dumps(observations["timing"]))
        missing_warmup["ordinary_runs"] = missing_warmup["ordinary_runs"][1:]
        cases.append((missing_warmup, "ordinary_runs"))
        wrong_order = json.loads(json.dumps(observations["timing"]))
        wrong_order["ordinary_runs"][2]["variant"] = "baseline"
        cases.append((wrong_order, "alternate"))
        too_few_phase_runs = json.loads(json.dumps(observations["timing"]))
        too_few_phase_runs["phase_runs"] = too_few_phase_runs["phase_runs"][:-2]
        cases.append((too_few_phase_runs, "phase_runs"))
        wrong_fast_profile = json.loads(json.dumps(observations["timing"]))
        wrong_fast_profile["fast_profile_runs"][1]["variant"] = "baseline"
        cases.append((wrong_fast_profile, "fast_profile_runs"))
        zero_candidate = json.loads(json.dumps(observations["timing"]))
        zero_candidate["ordinary_runs"][2]["end_to_end_seconds"] = 0
        cases.append((zero_candidate, "positive"))
        impossible_phase_sum = json.loads(json.dumps(observations["timing"]))
        impossible_phase_sum["ordinary_runs"][2]["end_to_end_seconds"] = 1
        cases.append((impossible_phase_sum, "phase sum"))
        for timing, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                changed["timing"] = timing
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.produce_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_execution_memory_and_metal_claims_are_bound_to_raw_receipts(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        cases = (
            (
                "receipt duration",
                lambda value: value["commands"][0].update(
                    {
                        "ended_monotonic_seconds": value["commands"][0][
                            "ended_monotonic_seconds"
                        ]
                        + 1
                    }
                ),
                "duration",
            ),
            (
                "configuration",
                lambda value: value["commands"][0].update(
                    {"run_configuration_digest": "sha256:" + "0" * 64}
                ),
                "configuration digest",
            ),
            (
                "scene binding",
                lambda value: value["commands"][0].update({"scene_id": "different-scene"}),
                "scene_id",
            ),
            (
                "published output",
                lambda value: next(
                    receipt for receipt in value["commands"] if receipt["published_output"]
                ).update({"output_sha256": "sha256:" + "f" * 64}),
                "does not match output_ply",
            ),
            (
                "memory closure",
                lambda value: value["memory"]["samples"].__setitem__(
                    slice(None),
                    [
                        sample
                        for sample in value["memory"]["samples"]
                        if sample["run_id"] != "ordinary-0"
                    ],
                ),
                "cover every candidate",
            ),
            (
                "metal allocation",
                lambda value: [
                    sample.update({"metal_allocated_bytes": 0})
                    for sample in value["memory"]["samples"]
                ],
                "positive Metal allocation",
            ),
            (
                "metal route",
                lambda value: value["resolved_compute"]["stages"].update(
                    {"training": "cpu"}
                ),
                "must use Metal",
            ),
        )
        for label, mutate, expected in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                mutate(changed)
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.produce_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "command.jsonl").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "command_log"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            changed = json.loads(json.dumps(observations))
            changed["pipeline_metrics"]["matcher_seconds"] = 99.0
            with self.assertRaisesRegex(evidence.EvidenceError, "observations.json"):
                evidence.produce_attestation(
                    evidence_request(),
                    changed,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        for field, value in (
            ("exit_code", 1),
            ("termination_reason", "signal"),
            ("cancelled", True),
            ("failure_type", "unexpected"),
            ("corrupt_ply", True),
        ):
            with self.subTest(actual_field=field), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                changed["actual"][field] = value
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, "clean successful"):
                    evidence.produce_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_long_sequence_samples_are_bound_to_the_3000_frame_request(self) -> None:
        request = evidence_request(scale=3000)
        request["gate_scopes"] = ["long_sequence"]
        observations = raw_observations(
            evidence.LANE_REFERENCE,
            include_long_sequence=True,
        )
        observations["timing"] = candidate_timing(500.0)
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        observations["memory"] = memory_observation(
            observations["timing"],
            evidence.LANE_REFERENCE,
        )
        del observations["stability"]
        del observations["toolchain_scenarios"]
        del observations["artifacts"]["toolchain_scenarios"]
        for key in ("registration", "residual_pixels", "pose"):
            del observations[key]
        for artifact in (
            "render_job",
            "rendering_manifest",
            "render_supervisor",
            "renderer_stdout_log",
            "renderer_stderr_log",
        ):
            del observations["artifacts"][artifact]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.produce_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
            self.assertEqual(attestation["metrics"]["long_sequence_frames"], measured(3000))

        for mutation, expected in (
            (("processed_frames", 2999), "requested scale"),
            (("rss_windows", observations["long_sequence"]["rss_windows"][:-1]), "windows"),
        ):
            changed = json.loads(json.dumps(observations))
            changed["long_sequence"][mutation[0]] = mutation[1]
            with self.subTest(field=mutation[0]), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.produce_attestation(
                        request,
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_toolchain_gates_are_derived_from_bound_scenario_receipts_and_real_archives(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        failed = json.loads(json.dumps(observations))
        failed["toolchain_scenarios"][0]["post_state_verified"] = False
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, failed)
            attestation = evidence.produce_attestation(
                evidence_request(),
                failed,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
            self.assertEqual(
                attestation["metrics"]["toolchain_fresh_install"],
                measured(False),
            )

        unbound = json.loads(json.dumps(observations))
        unbound["toolchain_scenarios"][0]["input_digest"] = "sha256:" + "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, unbound)
            with self.assertRaisesRegex(evidence.EvidenceError, "requested input"):
                evidence.produce_attestation(
                    evidence_request(),
                    unbound,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_toolchain_size_evidence_rejects_unrelated_or_aliased_archives(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "normal-photo.zip").write_bytes(
                deterministic_zip("unrelated.txt", b"not a toolchain component\n")
            )
            with self.assertRaisesRegex(evidence.EvidenceError, "toolchain|component"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "large-area.zip").write_bytes((root / "normal-photo.zip").read_bytes())
            with self.assertRaisesRegex(evidence.EvidenceError, "toolchain.*distinct|closure"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "normal-photo.zip").write_text("not a ZIP", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "valid ZIP"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_toolchain_size_evidence_accepts_exact_signed_component_closures(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.produce_attestation(
                evidence_request(),
                observations,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(
            attestation["metrics"]["normal_photo_toolchain_bytes"],
            measured(len(TEST_TOOLCHAIN_COMPONENT_ARCHIVES["macos-arm64-core"])),
        )
        self.assertEqual(
            attestation["metrics"]["large_area_toolchain_bytes"],
            measured(sum(map(len, TEST_TOOLCHAIN_COMPONENT_ARCHIVES.values()))),
        )

    def test_toolchain_size_evidence_allows_one_colmap_closure_without_streaming(self) -> None:
        request = evidence_request()
        request["binding"]["toolchain_identity"] = test_toolchain_identity(
            TEST_NORMAL_TOOLCHAIN_STATE
        )
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        for scenario in observations["toolchain_scenarios"]:
            scenario["toolchain_identity"] = request["binding"]["toolchain_identity"]
            scenario["argv"] = [
                argument
                if not argument.startswith("toolchain://")
                else f"toolchain://{request['binding']['toolchain_identity']}"
                for argument in scenario["argv"]
            ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            (root / "large-area-toolchain-state.json").write_bytes(
                evidence.canonical_json_bytes(TEST_NORMAL_TOOLCHAIN_STATE) + b"\n"
            )
            (root / "large-area.zip").write_bytes((root / "normal-photo.zip").read_bytes())
            (root / "toolchain-scenarios.jsonl").write_bytes(
                b"".join(
                    evidence.canonical_json_bytes(record) + b"\n"
                    for record in observations["toolchain_scenarios"]
                )
            )
            (root / "observations.json").write_bytes(
                evidence.canonical_json_bytes(observations) + b"\n"
            )
            attestation = evidence.produce_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        expected_bytes = len(TEST_TOOLCHAIN_COMPONENT_ARCHIVES["macos-arm64-core"])
        self.assertEqual(
            attestation["metrics"]["normal_photo_toolchain_bytes"],
            measured(expected_bytes),
        )
        self.assertEqual(
            attestation["metrics"]["large_area_toolchain_bytes"],
            measured(expected_bytes),
        )

    def test_normal_toolchain_closure_requires_runnable_colmap_and_training_capabilities(self) -> None:
        for removed_capability in ("geometry.colmap", "training.msplat"):
            with self.subTest(capability=removed_capability), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                observations = raw_observations(evidence.LANE_REFERENCE)
                write_evidence_artifacts(root, observations)
                manifest = test_toolchain_manifest()
                core = next(
                    component
                    for component in manifest["components"]
                    if component["name"] == "macos-arm64-core"
                )
                core["capabilities"].remove(removed_capability)
                manifest["signatureEd25519"] = ""
                manifest["signatureEd25519"] = base64.b64encode(
                    TEST_TOOLCHAIN_PRIVATE_KEY.sign(evidence.canonical_json_bytes(manifest))
                ).decode("ascii")

                states = {}
                for label, component_names in (
                    ("normal", ["macos-arm64-core"]),
                    ("large", ["macos-arm64-core", "geometry-large-area"]),
                ):
                    components = {
                        component["name"]: component for component in manifest["components"]
                    }
                    selected = [components[name] for name in component_names]
                    states[label] = {
                        "schemaVersion": 2,
                        "installedArtifacts": {
                            component["name"]: component["sha256"] for component in selected
                        },
                        "installedCapabilities": sorted(
                            capability
                            for component in selected
                            for capability in component["capabilities"]
                        ),
                        "signedManifest": manifest,
                    }
                (root / "normal-photo-toolchain-state.json").write_bytes(
                    evidence.canonical_json_bytes(states["normal"]) + b"\n"
                )
                (root / "large-area-toolchain-state.json").write_bytes(
                    evidence.canonical_json_bytes(states["large"]) + b"\n"
                )
                descriptors = {
                    name: evidence._artifact_descriptor(root / filename, root)
                    for name, filename in {
                        "normal_photo_toolchain": "normal-photo.zip",
                        "normal_photo_toolchain_state": "normal-photo-toolchain-state.json",
                        "large_area_toolchain": "large-area.zip",
                        "large_area_toolchain_state": "large-area-toolchain-state.json",
                    }.items()
                }
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "normal photo.*capabilit",
                ):
                    evidence._validate_toolchain_package_evidence(
                        root,
                        descriptors,
                        test_toolchain_identity(states["large"]),
                    )

    def test_supervisor_window_contains_every_execution_receipt(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        cases = {
            "entirely outside": (10_000.0, 20_000.0),
            "start endpoint overrun": (0.01, 20_000.0),
            "end endpoint overrun": (0.0, 1.0),
        }
        for label, (started, ended) in cases.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_evidence_artifacts(root, observations)
                receipt = supervisor_run(observations)
                receipt["started_monotonic_seconds"] = started
                receipt["ended_monotonic_seconds"] = ended
                (root / "supervisor-run.json").write_bytes(
                    evidence.canonical_json_bytes(receipt) + b"\n"
                )
                with self.assertRaisesRegex(evidence.EvidenceError, "supervisor.*window"):
                    evidence.produce_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_supervisor_attribution_counts_gaps_between_receipts(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        midpoint = len(observations["commands"]) // 2
        for receipt in observations["commands"][midpoint:]:
            receipt["started_monotonic_seconds"] += 10_000.0
            receipt["ended_monotonic_seconds"] += 10_000.0
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "unattributed"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )


    def test_stability_requires_each_stage_and_recovery_pair(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        invalid_none = json.loads(json.dumps(observations))
        none_run = next(
            run
            for run in invalid_none["stability"]["runs"]
            if run["interruption_stage"] == "none"
        )
        none_run["recovery_action"] = "relaunch_resume"
        none_run["resumed_deterministically"] = True

        missing_pair = json.loads(json.dumps(observations))
        for run in missing_pair["stability"]["runs"]:
            if (
                run["interruption_stage"] == "prepare"
                and run["recovery_action"] == "cancel_resume"
            ):
                run["recovery_action"] = "relaunch_resume"

        for changed, expected in (
            (invalid_none, "none.*none"),
            (missing_pair, "stage and recovery"),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.produce_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_orientation_evidence_is_status_consistent(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        cases = []
        verified_missing = json.loads(json.dumps(observations["pipeline_metrics"]))
        verified_missing["orientation_bootstrap_p95_degrees"] = None
        cases.append((verified_missing, "verified orientation"))
        unresolved_partial = json.loads(json.dumps(observations["pipeline_metrics"]))
        unresolved_partial["orientation_status"] = "unresolved"
        unresolved_partial["orientation_median_residual_degrees"] = None
        cases.append((unresolved_partial, "unresolved orientation"))
        for raw_metrics, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                changed["pipeline_metrics"] = raw_metrics
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.produce_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        self.key,
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

        unresolved = json.loads(json.dumps(observations))
        unresolved["pipeline_metrics"]["orientation_status"] = "unresolved"
        unresolved["pipeline_metrics"]["orientation_median_residual_degrees"] = None
        unresolved["pipeline_metrics"]["orientation_p90_residual_degrees"] = None
        unresolved["pipeline_metrics"]["orientation_bootstrap_p95_degrees"] = None
        unresolved["pipeline_metrics"]["orientation_physical_up_error_degrees"] = None
        unresolved["pipeline_metrics"]["orientation_sign_correct"] = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unresolved_request = evidence_request()
            unresolved_request["reference_artifacts"]["orientation_expected_status"] = "unresolved"
            write_evidence_artifacts(root, unresolved, unresolved_request)
            attestation = evidence.produce_attestation(
                unresolved_request,
                unresolved,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(attestation["metrics"]["orientation_status"], measured("unresolved"))

    def test_requested_scale_holdouts_and_pair_schedule_are_binding(self) -> None:
        request = evidence_request(scale=250)
        self.assertEqual(request["holdout_indices"], list(range(4, 250, 5)))
        self.assertEqual(
            sum(250 - offset for offset in request["candidate_run_configuration"]["temporal_offsets"]),
            1_745,
        )
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["pipeline_metrics"].update(
            {
                "scheduled_pairs": 1_745,
                "attempted_pairs": 1_745,
                "raw_matched_pairs": 1_000,
                "spatially_verified_pairs": 249,
                "local_pairs": 1_745,
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "requested scale 250"):
                evidence.produce_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        malformed = evidence_request()
        malformed["holdout_indices"] = [4, 9, 14, 19, 24, 28]
        with self.assertRaisesRegex(evidence.EvidenceError, "every fifth"):
            evidence.validate_request(malformed)

    def test_verified_orientation_rejects_wrong_sign_or_physical_up(self) -> None:
        metrics = passing_metrics()
        metrics["orientation_sign_correct"] = measured(False)
        self.assertEqual(
            benchmark.evaluate_gates(
                metrics,
                valid_reference_config()["thresholds"],
                gate_scopes=["scene_quality"],
            )["status"],
            "failed",
        )
        metrics = passing_metrics()
        metrics["orientation_physical_up_error_degrees"] = measured(5.001)
        self.assertEqual(
            benchmark.evaluate_gates(
                metrics,
                valid_reference_config()["thresholds"],
                gate_scopes=["scene_quality"],
            )["status"],
            "failed",
        )

    def test_supervisor_log_names_and_nested_artifact_paths_are_not_spoofable(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["artifacts"]["command_log"] = "fake.jsonl"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "fake.jsonl").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "supervisor-owned"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside"
            outside.mkdir()
            (outside / "splat.ply").write_text("external", encoding="utf-8")
            artifact_root = root / "artifacts"
            artifact_root.mkdir()
            (artifact_root / "nested").mkdir()
            (artifact_root / "nested" / "link").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(evidence.EvidenceError, "symlink"):
                evidence._artifact_descriptor(
                    artifact_root / "nested" / "link" / "splat.ply",
                    artifact_root,
                )

    def test_gate_scopes_limit_expensive_reference_evidence(self) -> None:
        request = evidence_request()
        request["gate_scopes"] = ["scene_quality"]
        observations = raw_observations(evidence.LANE_REFERENCE)
        full_timing = paired_timing()
        observations["timing"] = {
            "ordinary_runs": full_timing["ordinary_runs"],
            "fast_profile_runs": full_timing["fast_profile_runs"],
        }
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
            request,
        )
        observations["memory"] = memory_observation(
            observations["timing"],
            evidence.LANE_REFERENCE,
        )
        del observations["stability"]
        del observations["toolchain_scenarios"]
        del observations["artifacts"]["toolchain_scenarios"]
        del observations["artifacts"]["normal_photo_toolchain"]
        del observations["artifacts"]["large_area_toolchain"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            attestation = evidence.produce_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
                self.key,
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(
            attestation["metrics"]["long_sequence_frames"],
            {"availability": "not_available", "reason": "not_measured"},
        )
        self.assertEqual(
            attestation["metrics"]["repeat_runs"],
            {"availability": "not_available", "reason": "not_measured"},
        )
        self.assertEqual(
            attestation["metrics"]["normal_photo_toolchain_bytes"],
            {"availability": "not_available", "reason": "not_measured"},
        )

    def test_baseline_observations_must_match_the_signed_request(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["baseline"]["git_commit"] = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "baseline"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_prefilled_metrics_are_rejected_instead_of_trusted(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["metrics"] = passing_metrics()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "unknown metrics"):
                evidence.produce_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_metric_or_artifact_tampering_breaks_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output, attestation = self.produce(root, evidence.LANE_REFERENCE)
            changed = json.loads(json.dumps(attestation))
            changed["metrics"]["registered_views"] = measured(999)
            output.write_bytes(evidence.canonical_json_bytes(changed) + b"\n")
            with self.assertRaisesRegex(evidence.EvidenceError, "signature"):
                evidence.verify_attestation(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
                    self.key,
                    runner_identity(evidence.LANE_REFERENCE),
                )
            changed = json.loads(json.dumps(attestation))
            changed["measurement_runner"]["sha256"] = "sha256:" + "f" * 64
            output.write_bytes(evidence.canonical_json_bytes(changed) + b"\n")
            with self.assertRaisesRegex(evidence.EvidenceError, "signature"):
                evidence.verify_attestation(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
                    self.key,
                    runner_identity(evidence.LANE_REFERENCE),
                )
            changed = json.loads(json.dumps(attestation))
            del changed["measurement_runner"]
            output.write_bytes(evidence.canonical_json_bytes(changed) + b"\n")
            with self.assertRaisesRegex(evidence.EvidenceError, "missing measurement_runner"):
                evidence.verify_attestation(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
                    self.key,
                    runner_identity(evidence.LANE_REFERENCE),
                )
            output.write_bytes(evidence.canonical_json_bytes(attestation) + b"\n")
            (root / "splat.ply").write_text("ply\nchanged\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "mismatch"):
                evidence.verify_attestation(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
                    self.key,
                    runner_identity(evidence.LANE_REFERENCE),
                )

    def test_missing_or_malformed_runner_identities_are_rejected(self) -> None:
        missing = runner_identities()
        del missing[evidence.LANE_EIGHT_GB]
        with self.assertRaisesRegex(evidence.EvidenceError, "missing"):
            evidence.validate_runner_identities(missing)
        malformed = runner_identities()
        malformed[evidence.LANE_REFERENCE]["sha256"] = "sha256:" + "A" * 64
        with self.assertRaisesRegex(evidence.EvidenceError, "SHA-256"):
            evidence.validate_runner_identities(malformed)

    def test_lane_claim_must_match_real_machine_metadata(self) -> None:
        observations = raw_observations(evidence.LANE_CONSTRAINED)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "14-16 GiB"):
                evidence.produce_attestation(
                    evidence_request(lane=evidence.LANE_CONSTRAINED),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_CONSTRAINED,
                    runner_identity(evidence.LANE_CONSTRAINED),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_release_scales_require_only_the_declared_hardware_lanes(self) -> None:
        self.assertEqual(
            benchmark.required_evidence_lanes(valid_scene(), 250),
            (evidence.LANE_REFERENCE,),
        )
        self.assertEqual(
            benchmark.required_evidence_lanes(valid_scene(), 120),
            (evidence.LANE_REFERENCE, evidence.LANE_CONSTRAINED),
        )
        self.assertEqual(
            benchmark.required_evidence_lanes(valid_scene(), 30),
            (evidence.LANE_REFERENCE, evidence.LANE_CONSTRAINED, evidence.LANE_EIGHT_GB),
        )

    def test_low_memory_timing_limits_are_scale_specific(self) -> None:
        scene = valid_scene()
        scene["gate_scopes"] = ["suite_performance"]

        def attestation(lane: str, metric_name: str | None, seconds: float | None) -> dict[str, object]:
            metrics = passing_metrics() if lane == evidence.LANE_REFERENCE else {
                "memory_lane": measured(
                    "constrained" if lane == evidence.LANE_CONSTRAINED else "eight_gb_fast"
                ),
                "machine_memory_bytes": measured(evidence_machine(lane)["physical_memory_bytes"]),
                "peak_memory_bytes": measured(1_000_000_000),
            }
            if metric_name is not None:
                metrics[metric_name] = measured(seconds)
            return {
                "actual": successful_actual(),
                "metrics": metrics,
                "machine": evidence_machine(lane),
            }

        reference = attestation(evidence.LANE_REFERENCE, None, None)
        constrained_30 = attestation(
            evidence.LANE_CONSTRAINED,
            "constrained_fast_p50_seconds",
            300.0,
        )
        eight = attestation(evidence.LANE_EIGHT_GB, "eight_gb_fast_p50_seconds", 300.0)
        evaluation, _ = benchmark._evaluate_protected_attestations(
            scene,
            30,
            {
                evidence.LANE_REFERENCE: reference,
                evidence.LANE_CONSTRAINED: constrained_30,
                evidence.LANE_EIGHT_GB: eight,
            },
        )
        self.assertEqual(evaluation["status"], "passed")

        constrained_30["metrics"]["constrained_fast_p50_seconds"] = measured(300.001)
        evaluation, _ = benchmark._evaluate_protected_attestations(
            scene,
            30,
            {
                evidence.LANE_REFERENCE: reference,
                evidence.LANE_CONSTRAINED: constrained_30,
                evidence.LANE_EIGHT_GB: eight,
            },
        )
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("constrained" in failure for failure in evaluation["failures"]))

        constrained_120 = attestation(
            evidence.LANE_CONSTRAINED,
            "constrained_fast_p50_seconds",
            600.001,
        )
        evaluation, _ = benchmark._evaluate_protected_attestations(
            scene,
            120,
            {
                evidence.LANE_REFERENCE: reference,
                evidence.LANE_CONSTRAINED: constrained_120,
            },
        )
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("constrained" in failure for failure in evaluation["failures"]))

        constrained_120["metrics"]["constrained_fast_p50_seconds"] = measured(600.0)
        evaluation, _ = benchmark._evaluate_protected_attestations(
            scene,
            120,
            {
                evidence.LANE_REFERENCE: reference,
                evidence.LANE_CONSTRAINED: constrained_120,
            },
        )
        self.assertEqual(evaluation["status"], "passed")

        constrained_30["metrics"]["constrained_fast_p50_seconds"] = measured(300.0)
        eight["metrics"]["eight_gb_fast_p50_seconds"] = measured(300.001)
        evaluation, _ = benchmark._evaluate_protected_attestations(
            scene,
            30,
            {
                evidence.LANE_REFERENCE: reference,
                evidence.LANE_CONSTRAINED: constrained_30,
                evidence.LANE_EIGHT_GB: eight,
            },
        )
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("eight_gb" in failure for failure in evaluation["failures"]))

    def test_suite_accepts_only_complete_verified_multi_machine_evidence(self) -> None:
        scene = valid_scene(adapter="protected-evidence")
        scene["gate_scopes"] = evidence_request()["gate_scopes"]
        scene["input"]["supplied"] = True
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest="sha256:" + "2" * 64,
            thresholds_digest="sha256:" + "3" * 64,
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity=TEST_TOOLCHAIN_IDENTITY,
        )
        with tempfile.TemporaryDirectory() as directory:
            corpus_root = Path(directory)
            scale_root = corpus_root / scene["adapter"]["evidence_path"] / "30"
            for lane in benchmark.required_evidence_lanes(scene, 30):
                root = scale_root / lane
                observations = raw_observations(lane)
                write_evidence_artifacts(root, observations)
                attestation = evidence.produce_attestation(
                    evidence_request(lane=lane),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    lane,
                    runner_identity(lane),
                    machine=evidence_machine(lane),
                )
                (root / "attestation.json").write_bytes(
                    evidence.canonical_json_bytes(attestation) + b"\n"
                )
            result = benchmark._copy_protected_evidence(
                scene,
                30,
                corpus_root,
                identity,
                "sha256:" + "1" * 64,
                self.key,
                runner_identities(),
            )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(
                {item["lane"] for item in result["evidence"]},
                set(benchmark.required_evidence_lanes(scene, 30)),
            )
            wrong_index_identities = runner_identities()
            wrong_index_identities[evidence.LANE_REFERENCE] = runner_identity(
                evidence.LANE_REFERENCE,
                "f",
            )
            wrong_index = benchmark._copy_protected_evidence(
                scene,
                30,
                corpus_root,
                identity,
                "sha256:" + "1" * 64,
                self.key,
                wrong_index_identities,
            )
            self.assertEqual(wrong_index["status"], "failed")
            self.assertTrue(any("approved request index" in item for item in wrong_index["failures"]))
            (scale_root / evidence.LANE_CONSTRAINED / "attestation.json").unlink()
            rejected = benchmark._copy_protected_evidence(
                scene,
                30,
                corpus_root,
                identity,
                "sha256:" + "1" * 64,
                self.key,
                runner_identities(),
            )
            self.assertEqual(rejected["status"], "failed")
            self.assertTrue(any("constrained" in item for item in rejected["failures"]))

    def test_request_emitter_binds_each_machine_job_to_one_run_identity(self) -> None:
        scene = valid_scene(adapter="protected-evidence")
        scene["input"]["supplied"] = True
        scene["scale_lanes"] = [30]
        corpus = {"schema_version": 1, "manifest_profile": "release", "scenes": [scene]}
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest="sha256:" + "2" * 64,
            thresholds_digest="sha256:" + "3" * 64,
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity="sha256:" + "5" * 64,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = root / "corpus.json"
            media = root / scene["input"]["media_path"]
            media.parent.mkdir(parents=True)
            media.write_bytes(b"scene")
            with (
                mock.patch.object(
                    benchmark,
                    "resolved_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(
                    benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(benchmark, "make_run_identity", return_value=identity),
            ):
                index = benchmark.emit_evidence_requests(
                    corpus,
                    valid_reference_config(),
                    corpus_path,
                    root / "toolchain",
                    root / "requests",
                    runner_identities(),
                )
            self.assertEqual(len(index["requests"]), 3)
            self.assertEqual(index["runner_identities"], runner_identities())
            self.assertEqual(
                {item["lane"] for item in index["requests"]},
                set(benchmark.required_evidence_lanes(scene, 30)),
            )
            for item in index["requests"]:
                request = json.loads((root / "requests" / item["request"]).read_text(encoding="utf-8"))
                self.assertEqual(request["binding"]["git_commit"], identity.git_commit)
                self.assertEqual(request["binding"]["input_digest"], benchmark.digest_input(media))
            missing_identity_index = json.loads(json.dumps(index))
            del missing_identity_index["runner_identities"][evidence.LANE_EIGHT_GB]
            with self.assertRaisesRegex(benchmark.ConfigError, "runner identities"):
                benchmark.validate_request_index(missing_identity_index, identity, corpus)

    def test_lane_orchestrator_runs_measurement_and_seals_raw_outputs(self) -> None:
        scene = valid_scene(adapter="protected-evidence")
        scene["input"]["supplied"] = True
        scene["scale_lanes"] = [120]
        corpus = {"schema_version": 1, "manifest_profile": "release", "scenes": [scene]}
        config = valid_reference_config()
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest=benchmark.sha256_json(corpus),
            thresholds_digest=benchmark.sha256_json(config),
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity=TEST_TOOLCHAIN_IDENTITY,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = root / "corpus.json"
            config_path = root / "reference.json"
            corpus_path.write_bytes(benchmark.canonical_json_bytes(corpus) + b"\n")
            config_path.write_bytes(benchmark.canonical_json_bytes(config) + b"\n")
            media = root / scene["input"]["media_path"]
            media.parent.mkdir(parents=True)
            media.write_bytes(b"scene")
            renderer_source = root / "renderer-source"
            renderer_source.write_bytes(b"#!/bin/sh\nexit 0\n")
            renderer_source.chmod(0o755)
            renderer_bundle = root / "MetalSplatter_MetalSplatter.bundle"
            renderer_bundle.mkdir()
            (renderer_bundle / "Shaders.metal").write_text(
                "kernel void draw() {}\n",
                encoding="utf-8",
            )
            renderer_closure_root = root / "renderer-closure"
            renderer_identity = lane_runner.renderer_closure.build_closure(
                renderer_source,
                renderer_bundle,
                renderer_closure_root,
                root / "renderer-identity.json",
            )
            request = benchmark._evidence_request(
                scene,
                120,
                evidence.LANE_CONSTRAINED,
                identity,
                benchmark.digest_input(media),
                renderer_identity,
            )
            requests_root = root / "requests"
            request_relative = Path("orbit-01/120/constrained_14_16gb.request.json")
            (requests_root / request_relative).parent.mkdir(parents=True)
            (requests_root / request_relative).write_bytes(
                benchmark.canonical_json_bytes(request) + b"\n"
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
                "baseline_git_commit": benchmark.APPROVED_PAIRED_BASELINE["git_commit"],
                "baseline_toolchain_identity": benchmark.APPROVED_PAIRED_BASELINE[
                    "toolchain_identity"
                ],
                "baseline_configuration_digest": benchmark.sha256_json(
                    benchmark.APPROVED_PAIRED_BASELINE["run_configuration"]
                ),
                "baseline_run_configuration": benchmark.APPROVED_PAIRED_BASELINE[
                    "run_configuration"
                ],
                "requests": [
                    {
                        "scene_id": scene["id"],
                        "scale": 120,
                        "lane": evidence.LANE_CONSTRAINED,
                        "request": request_relative.as_posix(),
                        "media_path": scene["input"]["media_path"],
                        "evidence_path": scene["adapter"]["evidence_path"],
                        "producer_command": ["fixture"],
                    }
                ],
            }
            index_path = requests_root / "index.json"
            index_path.write_bytes(benchmark.canonical_json_bytes(index) + b"\n")
            source = root / "runner-source"
            source.mkdir()
            observations = raw_observations(evidence.LANE_CONSTRAINED)
            for record in observations["timing"]["candidate_runs"]:
                record["end_to_end_seconds"] = 0.001
            observations["commands"] = execution_receipts(
                observations["timing"],
                evidence.LANE_CONSTRAINED,
                request,
            )
            observations["memory"] = memory_observation(
                observations["timing"],
                evidence.LANE_CONSTRAINED,
            )
            (source / "observations.json").write_bytes(
                evidence.canonical_json_bytes(observations) + b"\n"
            )
            (source / "splat.ply").write_text(
                VALID_SPLAT_PLY,
                encoding="utf-8",
            )
            runner = root / "measurement-runner"
            runner.write_text(
                "#!/usr/bin/env python3\n"
                "import argparse, os, pathlib, shutil\n"
                "p=argparse.ArgumentParser()\n"
                "p.add_argument('--request'); p.add_argument('--input'); p.add_argument('--toolchain-root')\n"
                "p.add_argument('--candidate-checkout-root'); p.add_argument('--baseline-checkout-root')\n"
                "p.add_argument('--baseline-toolchain-root'); p.add_argument('--reference-config')\n"
                "p.add_argument('--artifact-root'); p.add_argument('--lane'); a=p.parse_args()\n"
                "source=pathlib.Path(__file__).parent/'runner-source'\n"
                "root=pathlib.Path(a.artifact_root)\n"
                "shutil.copy2(source/'observations.json', root/'observations.json')\n"
                "shutil.copy2(source/'splat.ply', root/'splat.ply')\n",
                encoding="utf-8",
            )
            runner.chmod(0o755)
            approved_runners = runner_identities()
            approved_runners[evidence.RENDERING_DRIVER_IDENTITY] = renderer_identity
            approved_runners[evidence.LANE_CONSTRAINED] = {
                "label": evidence.RUNNER_LABELS[evidence.LANE_CONSTRAINED],
                "sha256": evidence.sha256_file(runner),
            }
            for receipt in observations["commands"]:
                receipt["executable_sha256"] = approved_runners[evidence.LANE_CONSTRAINED][
                    "sha256"
                ]
            (source / "observations.json").write_bytes(
                evidence.canonical_json_bytes(observations) + b"\n"
            )
            reference_request = Path("orbit-01/120/reference_m4_max.request.json")
            (requests_root / reference_request).write_bytes(
                benchmark.canonical_json_bytes(request) + b"\n"
            )
            index["runner_identities"] = approved_runners
            index["requests"].append(
                {
                    "scene_id": scene["id"],
                    "scale": 120,
                    "lane": evidence.LANE_REFERENCE,
                    "request": reference_request.as_posix(),
                    "media_path": scene["input"]["media_path"],
                    "evidence_path": scene["adapter"]["evidence_path"],
                    "producer_command": ["fixture"],
                }
            )
            index_path.write_bytes(benchmark.canonical_json_bytes(index) + b"\n")
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / "manifest.json").write_text("{}\n", encoding="utf-8")
            key_path = root / "evidence.key"
            key_path.write_bytes(self.key)
            key_path.chmod(0o600)
            baseline_checkout = root / "baseline-checkout"
            baseline_toolchain = root / "baseline-toolchain"
            with (
                mock.patch.object(lane_runner.benchmark, "validate_corpus"),
                mock.patch.object(
                    lane_runner.benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(
                    lane_runner.benchmark,
                    "resolved_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(
                    lane_runner.evidence,
                    "collect_machine_metadata",
                    return_value=evidence_machine(evidence.LANE_CONSTRAINED),
                ),
                mock.patch.object(
                    lane_runner,
                    "_verify_baseline_checkout",
                    return_value=baseline_checkout,
                ),
                mock.patch.object(
                    lane_runner,
                    "_verify_baseline_toolchain",
                    return_value=(
                        baseline_toolchain,
                        benchmark.APPROVED_PAIRED_BASELINE["toolchain_identity"],
                    ),
                ),
                mock.patch.dict(
                    os.environ,
                    {"EASYSPLAT_TEST_OBSERVATIONS": str(source)},
                ),
                mock.patch.object(
                    lane_runner.time,
                    "monotonic",
                    side_effect=itertools.chain(
                        [0.0],
                        itertools.repeat(
                            max(
                                receipt["ended_monotonic_seconds"]
                                for receipt in observations["commands"]
                            )
                            + 1.0
                        ),
                    ),
                ),
                mock.patch.object(lane_runner, "_PROCESS_GROUP_DRAIN_SECONDS", 0.0),
            ):
                result = lane_runner.run_lane(
                    index_path,
                    requests_root,
                    corpus_path,
                    config_path,
                    toolchain,
                    baseline_checkout,
                    baseline_toolchain,
                    root / "evidence",
                    evidence.LANE_CONSTRAINED,
                    runner,
                    renderer_closure_root,
                    key_path,
                )
            self.assertEqual(len(result["attestations"]), 1)
            attestation_path = (
                root
                / "evidence"
                / scene["adapter"]["evidence_path"]
                / "120"
                / evidence.LANE_CONSTRAINED
                / "attestation.json"
            )
            self.assertTrue(attestation_path.is_file())
            original_runner = runner.read_text(encoding="utf-8")
            runner.write_text(original_runner + "\n# pre-run mutation\n", encoding="utf-8")
            with (
                mock.patch.object(lane_runner.benchmark, "validate_corpus"),
                mock.patch.object(
                    lane_runner.benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(
                    lane_runner.benchmark,
                    "resolved_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(
                    lane_runner,
                    "_verify_baseline_checkout",
                    return_value=baseline_checkout,
                ),
                mock.patch.object(
                    lane_runner,
                    "_verify_baseline_toolchain",
                    return_value=(
                        baseline_toolchain,
                        benchmark.APPROVED_PAIRED_BASELINE["toolchain_identity"],
                    ),
                ),
            ):
                with self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "before the first scene",
                ):
                    lane_runner.run_lane(
                        index_path,
                        requests_root,
                        corpus_path,
                        config_path,
                        toolchain,
                        baseline_checkout,
                        baseline_toolchain,
                        root / "evidence",
                        evidence.LANE_CONSTRAINED,
                        runner,
                        renderer_closure_root,
                        key_path,
                    )

            runner.write_text(
                original_runner + "\nwith open(__file__, 'a', encoding='utf-8') as handle: handle.write('# mutated')\n",
                encoding="utf-8",
            )
            runner.chmod(0o755)
            index["runner_identities"][evidence.LANE_CONSTRAINED]["sha256"] = evidence.sha256_file(runner)
            index_path.write_bytes(benchmark.canonical_json_bytes(index) + b"\n")
            with (
                mock.patch.object(lane_runner.benchmark, "validate_corpus"),
                mock.patch.object(
                    lane_runner.benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(
                    lane_runner.benchmark,
                    "resolved_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(
                    lane_runner.evidence,
                    "collect_machine_metadata",
                    return_value=evidence_machine(evidence.LANE_CONSTRAINED),
                ),
                mock.patch.object(
                    lane_runner,
                    "_verify_baseline_checkout",
                    return_value=baseline_checkout,
                ),
                mock.patch.object(
                    lane_runner,
                    "_verify_baseline_toolchain",
                    return_value=(
                        baseline_toolchain,
                        benchmark.APPROVED_PAIRED_BASELINE["toolchain_identity"],
                    ),
                ),
                mock.patch.dict(
                    os.environ,
                    {"EASYSPLAT_TEST_OBSERVATIONS": str(source)},
                ),
            ):
                with self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "after subprocess completion",
                ):
                    lane_runner.run_lane(
                        index_path,
                        requests_root,
                        corpus_path,
                        config_path,
                        toolchain,
                        baseline_checkout,
                        baseline_toolchain,
                        root / "evidence",
                        evidence.LANE_CONSTRAINED,
                        runner,
                        renderer_closure_root,
                        key_path,
                    )


class RunnerIntegrityTests(unittest.TestCase):
    def test_release_workflow_builds_and_distributes_the_renderer_closure(self) -> None:
        workflow = (ROOT / ".github/workflows/benchmark-release.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("EASYSPLAT_BENCHMARK_RENDERING_DRIVER_SHA256", workflow)
        self.assertIn("--product EasySplatBenchmarkDriver", workflow)
        self.assertIn("renderer_closure.py build", workflow)
        self.assertIn(
            '--rendering-driver-identity "$RENDERER_PACKAGE/identity.json"',
            workflow,
        )
        self.assertEqual(
            workflow.count("name: easysplat-benchmark-renderer-${{ github.sha }}"),
            4,
            "prepare must upload one renderer package and each measurement lane must download it",
        )
        self.assertEqual(
            workflow.count(
                '--rendering-driver-closure "$RUNNER_TEMP/renderer-package/closure"'
            ),
            3,
        )
        self.assertEqual(workflow.count('--baseline-checkout-root "$BASELINE_CHECKOUT"'), 3)
        self.assertEqual(
            workflow.count('--baseline-toolchain-root "$BASELINE_TOOLCHAIN_ROOT"'),
            3,
        )

    def test_release_workflow_installs_heavy_render_scoring_only_where_used(self) -> None:
        workflow = (ROOT / ".github/workflows/benchmark-release.yml").read_text(
            encoding="utf-8"
        )
        constrained = workflow.split("  constrained:\n", 1)[1].split("  eight-gb:\n", 1)[0]
        eight_gb = workflow.split("  eight-gb:\n", 1)[1].split("  aggregate:\n", 1)[0]

        self.assertEqual(
            workflow.count("name: Install protected render-scoring dependencies"),
            2,
            "only reference measurement and aggregate verification score pixels",
        )
        self.assertNotIn("render-requirements.txt", constrained)
        self.assertNotIn("render-requirements.txt", eight_gb)

    def test_run_suite_requires_render_dependencies_only_when_verifying_evidence(self) -> None:
        launcher = (ROOT / "scripts/benchmark/run_suite.sh").read_text(encoding="utf-8")

        self.assertIn('if [ -n "$EVIDENCE_ROOT" ]; then', launcher)
        self.assertNotIn('if [ "$DRY_RUN" -eq 0 ]; then\n  dependency_locks+=', launcher)

    def _renderer_stage_fixture(
        self,
        root: Path,
        *,
        exit_code: int = 0,
        mutate_shader: bool = False,
    ) -> dict[str, object]:
        root = root.resolve()
        artifact_root = root / "artifacts"
        artifact_root.mkdir()
        candidate = root / "candidate"
        baseline = root / "baseline"
        candidate.mkdir()
        baseline.mkdir()
        request = evidence_request(lane=evidence.LANE_REFERENCE)
        request_path = root / "request.json"
        request_path.write_bytes(evidence.canonical_json_bytes(request) + b"\n")
        executable = root / "renderer"
        invocation_marker = root / "renderer-invoked"
        executable.write_text(
            "#!/usr/bin/python3\n"
            "import pathlib, sys\n"
            f"status={exit_code}\n"
            f"pathlib.Path({str(invocation_marker)!r}).write_text('invoked\\n', encoding='utf-8')\n"
            "if status == 0:\n"
            "    output=pathlib.Path(sys.argv[sys.argv.index('--output')+1])\n"
            "    output.write_text('{}\\n', encoding='utf-8')\n"
            + (
                "    (pathlib.Path(__file__).parent / "
                "'MetalSplatter_MetalSplatter.bundle' / 'Shaders.metal').write_text("
                "'kernel void tampered() {}\\n', encoding='utf-8')\n"
                if mutate_shader
                else ""
            )
            +
            "raise SystemExit(status)\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        bundle = root / "MetalSplatter_MetalSplatter.bundle"
        bundle.mkdir()
        (bundle / "Shaders.metal").write_text("kernel void draw() {}\n", encoding="utf-8")
        closure = root / "renderer-closure"
        identity = lane_runner.renderer_closure.build_closure(
            executable,
            bundle,
            closure,
            root / "renderer-identity.json",
        )
        request["rendering_driver_identity"] = identity
        request_path.write_bytes(evidence.canonical_json_bytes(request) + b"\n")
        request_digest = evidence.sha256_file(request_path)
        holdouts = request["holdout_indices"]
        commands = [
            {
                "run_id": "baseline-run",
                "phase": "ordinary",
                "variant": "baseline",
                "output_sha256": "sha256:" + "a" * 64,
                "checkout_commit": request["binding"]["baseline_git_commit"],
                "toolchain_identity": request["binding"]["baseline_toolchain_identity"],
                "executable_sha256": "sha256:" + "1" * 64,
                "published_output": False,
            },
            {
                "run_id": "candidate-run",
                "phase": "ordinary",
                "variant": "candidate",
                "output_sha256": "sha256:" + "b" * 64,
                "checkout_commit": request["binding"]["git_commit"],
                "toolchain_identity": request["binding"]["toolchain_identity"],
                "executable_sha256": "sha256:" + "2" * 64,
                "published_output": True,
            },
            {
                "run_id": "reference-run",
                "phase": "fast_profile",
                "variant": "accurate_reference",
                "output_sha256": "sha256:" + "c" * 64,
                "checkout_commit": request["binding"]["git_commit"],
                "toolchain_identity": request["binding"]["toolchain_identity"],
                "executable_sha256": "sha256:" + "3" * 64,
                "published_output": False,
            },
            {
                "run_id": "fast-run",
                "phase": "fast_profile",
                "variant": "fast_candidate",
                "output_sha256": "sha256:" + "d" * 64,
                "checkout_commit": request["binding"]["git_commit"],
                "toolchain_identity": request["binding"]["toolchain_identity"],
                "executable_sha256": "sha256:" + "4" * 64,
                "published_output": False,
            },
        ]
        command_by_render_variant = {
            "accurate_reference": commands[2],
            "paired_baseline": commands[0],
            "candidate_balanced": commands[1],
            "candidate_fast": commands[3],
        }
        identity_matrix = [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ]
        job = {
            "schema_version": 1,
            "scene_id": request["binding"]["scene_id"],
            "scale": request["binding"]["scale"],
            "request_digest": request_digest,
            "input_digest": request["binding"]["input_digest"],
            "renderer_closure_sha256": identity["sha256"],
            "renderer_executable_sha256": identity["executable_sha256"],
            "holdout_indices": holdouts,
            "training_view_indices": [
                index for index in range(request["binding"]["scale"])
                if index not in set(holdouts)
            ],
            "candidate_checkout": {
                "path": str(candidate),
                "commit": request["binding"]["git_commit"],
            },
            "baseline_checkout": {
                "path": str(baseline),
                "commit": request["binding"]["baseline_git_commit"],
            },
            "views": [
                {
                    "holdout_index": holdout,
                    "camera": {
                        "width": 64,
                        "height": 64,
                        "projection_matrix_column_major": identity_matrix,
                        "world_to_camera_matrix_column_major": identity_matrix,
                    },
                    "ground_truth": {
                        "path": f"rendering/ground-truth/{holdout:06d}.png",
                        "sha256": "sha256:" + "e" * 64,
                    },
                    "sources": [
                        {
                            "variant": render_variant,
                            "run_id": command_by_render_variant[render_variant]["run_id"],
                            "checkout_commit": command_by_render_variant[render_variant]["checkout_commit"],
                            "toolchain_identity": command_by_render_variant[render_variant]["toolchain_identity"],
                            "source_executable_sha256": command_by_render_variant[render_variant]["executable_sha256"],
                            "ply_path": f"sources/{render_variant}.ply",
                            "ply_sha256": command_by_render_variant[render_variant]["output_sha256"],
                            "output_path": f"rendering/{render_variant}/{holdout:06d}.png",
                        }
                        for render_variant in (
                            "accurate_reference",
                            "paired_baseline",
                            "candidate_balanced",
                            "candidate_fast",
                        )
                    ],
                }
                for holdout in holdouts
            ],
        }
        (artifact_root / "render-job.json").write_bytes(
            evidence.canonical_json_bytes(job) + b"\n"
        )
        return {
            "artifact_root": artifact_root,
            "candidate": candidate,
            "baseline": baseline,
            "closure": closure,
            "identity": identity,
            "request": request,
            "request_path": request_path,
            "request_digest": request_digest,
            "invocation_marker": invocation_marker,
            "commands": commands,
        }

    def _run_renderer_stage(self, fixture: dict[str, object]) -> dict[str, object]:
        return lane_runner._execute_rendering_stage(
            artifact_root=fixture["artifact_root"],
            request=fixture["request"],
            request_path=fixture["request_path"],
            request_digest=fixture["request_digest"],
            renderer_closure_path=fixture["closure"],
            renderer_identity=fixture["identity"],
            candidate_checkout=fixture["candidate"],
            baseline_checkout=fixture["baseline"],
            commands=fixture["commands"],
            timeout_seconds=10.0,
        )

    def test_rendering_stage_rejects_nonpublished_candidate_source_before_launch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(Path(directory))
            alternate = {
                **fixture["commands"][1],
                "run_id": "candidate-earlier-run",
                "output_sha256": "sha256:" + "9" * 64,
                "published_output": False,
            }
            fixture["commands"].append(alternate)
            job_path = fixture["artifact_root"] / "render-job.json"
            job = json.loads(job_path.read_text(encoding="utf-8"))
            for view in job["views"]:
                source = view["sources"][2]
                source["run_id"] = alternate["run_id"]
                source["ply_sha256"] = alternate["output_sha256"]
            job_path.write_bytes(evidence.canonical_json_bytes(job) + b"\n")

            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "published output",
            ):
                self._run_renderer_stage(fixture)
            self.assertFalse(fixture["invocation_marker"].exists())

    def test_rendering_stage_is_launched_and_receipted_by_the_supervisor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(Path(directory))

            receipt = self._run_renderer_stage(fixture)

            artifact_root = fixture["artifact_root"]
            self.assertEqual(receipt["exit_code"], 0)
            self.assertEqual(receipt["renderer_closure_sha256"], fixture["identity"]["sha256"])
            self.assertEqual(
                receipt["manifest_sha256"],
                evidence.sha256_file(artifact_root / "rendering-manifest.json"),
            )
            self.assertEqual(receipt["request_sha256"], fixture["request_digest"])
            self.assertEqual(
                receipt["stdout_sha256"],
                evidence.sha256_file(artifact_root / "renderer-stdout.log"),
            )
            self.assertEqual(
                receipt["stderr_sha256"],
                evidence.sha256_file(artifact_root / "renderer-stderr.log"),
            )
            self.assertEqual(
                receipt["candidate_checkout_commit"],
                fixture["request"]["binding"]["git_commit"],
            )
            self.assertEqual(
                receipt["baseline_checkout_commit"],
                fixture["request"]["binding"]["baseline_git_commit"],
            )
            self.assertTrue((artifact_root / "render-supervisor.json").is_file())
            self.assertTrue((artifact_root / "renderer-stdout.log").is_file())
            self.assertTrue(fixture["invocation_marker"].is_file())

    def test_rendering_stage_rejects_non_invocation_precreation_and_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(Path(directory))
            (fixture["artifact_root"] / "render-job.json").unlink()
            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "render-job.json",
            ):
                self._run_renderer_stage(fixture)
            self.assertFalse(fixture["invocation_marker"].exists())

        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(Path(directory))
            (fixture["artifact_root"] / "rendering-manifest.json").write_text(
                "fabricated\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "cannot pre-create",
            ):
                self._run_renderer_stage(fixture)

        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(Path(directory), exit_code=7)
            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "failed with exit 7",
            ):
                self._run_renderer_stage(fixture)
            self.assertFalse((fixture["artifact_root"] / "render-supervisor.json").exists())

        for log_name in ("renderer-stdout.log", "renderer-stderr.log"):
            with self.subTest(log_name=log_name), tempfile.TemporaryDirectory() as directory:
                fixture = self._renderer_stage_fixture(Path(directory))
                outside = Path(directory).resolve() / "outside.log"
                outside.write_text("keep\n", encoding="utf-8")
                (fixture["artifact_root"] / log_name).symlink_to(outside)
                with self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "cannot pre-create",
                ):
                    self._run_renderer_stage(fixture)
                self.assertEqual(outside.read_text(encoding="utf-8"), "keep\n")
                self.assertFalse(fixture["invocation_marker"].exists())

    def test_rendering_stage_rejects_renderer_closure_tampering_after_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(
                Path(directory),
                mutate_shader=True,
            )

            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "closure mismatch after rendering",
            ):
                self._run_renderer_stage(fixture)
            self.assertTrue(fixture["invocation_marker"].is_file())

    def test_render_job_rejects_a_checkout_path_with_a_symlinked_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            fixture = self._renderer_stage_fixture(root)
            alias = root / "checkout-alias"
            alias.symlink_to(root, target_is_directory=True)
            job_path = fixture["artifact_root"] / "render-job.json"
            job = json.loads(job_path.read_text(encoding="utf-8"))
            job["candidate_checkout"]["path"] = str(alias / "candidate")
            job_path.write_bytes(evidence.canonical_json_bytes(job) + b"\n")

            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "symbolic link",
            ):
                self._run_renderer_stage(fixture)
            self.assertFalse(fixture["invocation_marker"].exists())

    def test_measurement_deadlines_are_scale_aware_bounded_and_strictly_parsed(self) -> None:
        self.assertEqual(lane_runner._measurement_timeout_seconds(30), 7200.0)
        self.assertEqual(lane_runner._measurement_timeout_seconds(120), 10800.0)
        self.assertEqual(lane_runner._measurement_timeout_seconds(3000), 86400.0)
        self.assertEqual(lane_runner._measurement_timeout_seconds(30, "0.1"), 0.1)
        for value in ("nan", "inf", "0", "-1", "604801", "not-a-number"):
            with self.subTest(value=value), self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "EASYSPLAT_INTERNAL_BENCHMARK_TIMEOUT_SECONDS",
            ):
                lane_runner._measurement_timeout_seconds(30, value)

    def test_measurement_process_runs_in_a_session_and_terminates_its_group_on_timeout(self) -> None:
        process = mock.Mock()
        process.wait.side_effect = subprocess.TimeoutExpired(["runner"], 1.0)
        environment = {"PATH": "/usr/bin"}
        with (
            tempfile.TemporaryDirectory() as directory,
            (Path(directory) / "stdout").open("wb") as stdout_handle,
            (Path(directory) / "stderr").open("wb") as stderr_handle,
            mock.patch.object(lane_runner.subprocess, "Popen", return_value=process) as popen,
            mock.patch.object(lane_runner, "_terminate_process_group", return_value=-9) as terminate,
        ):
            completed, timed_out = lane_runner._run_measurement_process(
                ["runner"],
                stdout_handle,
                stderr_handle,
                environment,
                1.0,
            )
        self.assertTrue(timed_out)
        self.assertEqual(completed.returncode, -9)
        popen.assert_called_once_with(
            ["runner"],
            stdin=subprocess.DEVNULL,
            stdout=mock.ANY,
            stderr=mock.ANY,
            env=mock.ANY,
            start_new_session=True,
        )
        protected_environment = popen.call_args.kwargs["env"]
        self.assertEqual(environment, {"PATH": "/usr/bin"})
        self.assertEqual(protected_environment["PATH"], "/usr/bin")
        self.assertRegex(
            protected_environment[lane_runner._PROCESS_TOKEN_ENVIRONMENT_KEY],
            r"^[0-9a-f]{64}$",
        )
        terminate.assert_called_once_with(process)

    def test_measurement_process_rejects_and_terminates_a_leaked_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "leaked-child-marker"
            command = [
                "/usr/bin/python3",
                "-c",
                (
                    "import os,time,pathlib; pid=os.fork(); "
                    f"path=pathlib.Path({str(marker)!r}); "
                    "(time.sleep(1),path.write_text('leaked')) if pid == 0 else None; "
                    "os._exit(0) if pid == 0 else None"
                ),
            ]
            with (
                (root / "stdout").open("wb") as stdout_handle,
                (root / "stderr").open("wb") as stderr_handle,
                self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "left live child processes",
                ),
            ):
                lane_runner._run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    {"PATH": "/usr/bin:/bin"},
                    10.0,
                )
            time.sleep(1.1)
            self.assertFalse(marker.exists())

    def test_measurement_process_rejects_a_child_that_creates_a_new_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "escaped-session-marker"
            child = (
                "import pathlib,time; "
                "time.sleep(1); "
                f"pathlib.Path({str(marker)!r}).write_text('escaped')"
            )
            command = [
                "/usr/bin/python3",
                "-c",
                (
                    "import subprocess,sys,time; "
                    f"subprocess.Popen([sys.executable, '-c', {child!r}], start_new_session=True); "
                    "time.sleep(0.25)"
                ),
            ]
            with (
                (root / "stdout").open("wb") as stdout_handle,
                (root / "stderr").open("wb") as stderr_handle,
                self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "left live child processes",
                ),
            ):
                lane_runner._run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    {"PATH": "/usr/bin:/bin"},
                    10.0,
                )
            time.sleep(1.1)
            self.assertFalse(marker.exists())

    def test_measurement_process_allows_a_child_to_finish_within_the_drain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            started = root / "drained-child-started"
            marker = root / "drained-child-marker"
            child = (
                "import pathlib,time; "
                f"pathlib.Path({str(started)!r}).write_text('started'); "
                "time.sleep(0.02); "
                f"pathlib.Path({str(marker)!r}).write_text('finished')"
            )
            command = [
                "/usr/bin/python3",
                "-c",
                (
                    "import pathlib,subprocess,sys,time\n"
                    f"started = pathlib.Path({str(started)!r})\n"
                    f"subprocess.Popen([sys.executable, '-c', {child!r}])\n"
                    "deadline = time.monotonic() + 1.0\n"
                    "while not started.exists() and time.monotonic() < deadline:\n"
                    "    time.sleep(0.001)\n"
                    "if not started.exists():\n"
                    "    raise RuntimeError('child did not start')\n"
                ),
            ]
            with (
                (root / "stdout").open("wb") as stdout_handle,
                (root / "stderr").open("wb") as stderr_handle,
            ):
                completed, timed_out = lane_runner._run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    {"PATH": "/usr/bin:/bin"},
                    10.0,
                )
            self.assertFalse(timed_out)
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "finished")

    def test_measurement_process_rejects_an_immediately_reparented_session_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "immediate-escaped-session-marker"
            child = (
                "import pathlib,time; "
                "time.sleep(0.5); "
                f"pathlib.Path({str(marker)!r}).write_text('escaped')"
            )
            command = [
                "/usr/bin/python3",
                "-c",
                (
                    "import subprocess,sys; "
                    f"subprocess.Popen([sys.executable, '-c', {child!r}], start_new_session=True)"
                ),
            ]
            with (
                (root / "stdout").open("wb") as stdout_handle,
                (root / "stderr").open("wb") as stderr_handle,
                self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "left live child processes",
                ),
            ):
                lane_runner._run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    {"PATH": "/usr/bin:/bin"},
                    10.0,
                )
            time.sleep(0.6)
            self.assertFalse(marker.exists())

    def test_descendant_drain_rechecks_for_a_late_process_token(self) -> None:
        child = lane_runner._ProcessRecord(101, 1, 101, os.getuid(), "", (20, 0))
        process_tree = mock.Mock()
        process_tree.live_descendants.side_effect = itertools.chain(
            [[]],
            itertools.repeat([child]),
        )
        with (
            mock.patch.object(lane_runner, "_process_group_exists", return_value=False),
            mock.patch.object(lane_runner, "_PROCESS_GROUP_DRAIN_SECONDS", 0.05),
            self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "left live child processes",
            ),
        ):
            lane_runner._reject_live_descendants(100, process_tree)
        self.assertGreaterEqual(process_tree.refresh_reparented_descendants.call_count, 2)
        process_tree.terminate_descendants.assert_called_once()

    def test_run_lane_import_does_not_load_libproc_off_macos(self) -> None:
        code = """
import ctypes
import sys
from unittest import mock
sys.platform = 'linux'
with mock.patch.object(ctypes, 'CDLL', side_effect=AssertionError('libproc loaded')):
    import scripts.benchmark.run_lane
"""
        completed = subprocess.run(
            [sys.executable, "-c", code],
            cwd=ROOT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(ROOT)},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_process_tree_tracker_does_not_follow_a_recycled_parent_pid(self) -> None:
        root = lane_runner._ProcessRecord(100, 1, 100, os.getuid(), "", (10, 0))
        child = lane_runner._ProcessRecord(101, 100, 100, os.getuid(), "", (11, 0))
        recycled_child = lane_runner._ProcessRecord(
            101,
            1,
            101,
            os.getuid(),
            "",
            (20, 0),
        )
        unrelated = lane_runner._ProcessRecord(
            102,
            101,
            101,
            os.getuid(),
            "",
            (21, 0),
        )
        records = {100: root, 101: child, 102: unrelated}
        children = {100: [101], 101: []}

        with (
            mock.patch.object(
                lane_runner,
                "_process_record",
                side_effect=lambda pid: records.get(pid),
            ),
            mock.patch.object(
                lane_runner,
                "_child_process_ids",
                side_effect=lambda pid: children.get(pid, []),
            ),
        ):
            tracker = lane_runner._ProcessTreeTracker(root.pid, "a" * 64)
            tracker._scan()
            self.assertIn(child.pid, tracker._tracked)

            records[child.pid] = recycled_child
            children[root.pid] = []
            children[child.pid] = [unrelated.pid]
            tracker._scan()

        self.assertNotIn(unrelated.pid, tracker._tracked)

    def test_artifact_cleanup_refuses_intermediate_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            outside = root / "outside"
            outside.mkdir()
            sentinel = outside / "keep.txt"
            sentinel.write_text("keep\n", encoding="utf-8")
            (output / "external").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(lane_runner.benchmark.ConfigError, "symlink"):
                lane_runner._prepare_artifact_root(
                    output,
                    Path("external/scene"),
                    30,
                    evidence.LANE_REFERENCE,
                )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")

    def test_evidence_key_permissions_are_restrictive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "evidence.key"
            key.write_bytes(b"x" * 32)
            key.chmod(0o644)
            with self.assertRaisesRegex(evidence.EvidenceError, "0600"):
                evidence.load_key(key)
            key.chmod(0o600)
            self.assertEqual(evidence.load_key(key), b"x" * 32)

    def test_baseline_checkout_must_be_exact_and_clean(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "fixture.txt").write_text("baseline\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "fixture.txt"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "-c",
                    "user.name=EasySplat Test",
                    "-c",
                    "user.email=test@easysplat.invalid",
                    "commit",
                    "-q",
                    "-m",
                    "test: baseline fixture",
                ],
                check=True,
            )
            commit = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.assertEqual(lane_runner._verify_baseline_checkout(root, commit), root.resolve())
            with self.assertRaisesRegex(lane_runner.benchmark.ConfigError, "approved commit"):
                lane_runner._verify_baseline_checkout(root, "0" * 40)
            (root / "untracked.txt").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(lane_runner.benchmark.ConfigError, "clean"):
                lane_runner._verify_baseline_checkout(root, commit)

    def test_baseline_checkout_rejects_a_symlinked_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            checkout = root / "checkout"
            checkout.mkdir()
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            (checkout / "fixture.txt").write_text("baseline\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(checkout), "add", "fixture.txt"], check=True)
            subprocess.run(
                [
                    "git", "-C", str(checkout),
                    "-c", "user.name=EasySplat Test",
                    "-c", "user.email=test@easysplat.invalid",
                    "commit", "-q", "-m", "test: baseline fixture",
                ],
                check=True,
            )
            commit = subprocess.run(
                ["git", "-C", str(checkout), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(root, target_is_directory=True)

            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "symbolic link",
            ):
                lane_runner._verify_baseline_checkout(
                    linked_parent / "checkout",
                    commit,
                )

    def test_pre_run_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner = Path(directory) / "runner"
            runner.write_bytes(b"approved")
            approved = runner_identity(evidence.LANE_REFERENCE, "0")
            with self.assertRaisesRegex(lane_runner.benchmark.ConfigError, "before the first scene"):
                lane_runner._verify_runner_digest(runner, approved, "before the first scene")

    def test_runner_mutation_between_or_after_runs_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runner = Path(directory) / "runner"
            runner.write_bytes(b"approved")
            approved = {
                "label": evidence.RUNNER_LABELS[evidence.LANE_CONSTRAINED],
                "sha256": evidence.sha256_file(runner),
            }
            lane_runner._verify_runner_digest(runner, approved, "before subprocess launch")
            runner.write_bytes(b"mutated")
            for phase in ("after subprocess completion", "before the next subprocess", "at lane completion"):
                with self.subTest(phase=phase):
                    with self.assertRaisesRegex(lane_runner.benchmark.ConfigError, phase):
                        lane_runner._verify_runner_digest(runner, approved, phase)


class OrchestrationTests(unittest.TestCase):
    def test_input_digest_rejects_symlinked_ancestors_inside_the_corpus(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            corpus_root = root / "corpus"
            outside = root / "outside"
            corpus_root.mkdir()
            outside.mkdir()
            (outside / "input.mp4").write_bytes(b"video")
            (corpus_root / "linked-media").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(benchmark.ConfigError, "symbolic link"):
                benchmark.digest_input(
                    corpus_root / "linked-media/input.mp4",
                    trusted_root=corpus_root,
                )

    def test_external_result_is_bound_to_scene_input_build_and_toolchain(self) -> None:
        scene = valid_scene()
        scene["input"]["supplied"] = True
        identity = benchmark.RunIdentity(
            profile="smoke",
            corpus_digest="sha256:" + "1" * 64,
            thresholds_digest="sha256:" + "2" * 64,
            git_commit="fixture",
            app_version="0.2.0-beta.1",
            toolchain_identity="fixture:smoke",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / scene["input"]["media_path"]
            media.parent.mkdir(parents=True)
            media.write_bytes(b"scene-a")
            input_digest = benchmark.digest_input(media)
            result_path = root / scene["adapter"]["result_path"]
            result_path.parent.mkdir(parents=True, exist_ok=True)
            payload = external_envelope(scene, 30, input_digest, identity)
            result_path.write_bytes(benchmark.canonical_json_bytes(payload) + b"\n")
            self.assertEqual(
                benchmark._copy_fixture_result(scene, 30, root, identity)["status"],
                "passed",
            )
            mismatches = {
                "scene_id": "different-scene",
                "input_digest": "sha256:" + "9" * 64,
                "corpus_digest": "sha256:" + "8" * 64,
                "thresholds_digest": "sha256:" + "7" * 64,
                "git_commit": "0" * 40,
                "app_version": "0.1.0",
                "toolchain_identity": "sha256:" + "6" * 64,
            }
            for key, mismatch in mismatches.items():
                with self.subTest(identity_field=key):
                    changed = dict(payload)
                    changed[key] = mismatch
                    result_path.write_bytes(benchmark.canonical_json_bytes(changed) + b"\n")
                    with self.assertRaisesRegex(benchmark.ConfigError, key):
                        benchmark._copy_fixture_result(scene, 30, root, identity)

    def test_failed_cancelled_or_identity_bearing_external_result_cannot_pass(self) -> None:
        scene = valid_scene()
        scene["input"]["supplied"] = True
        identity = benchmark.RunIdentity(
            profile="smoke",
            corpus_digest="sha256:" + "1" * 64,
            thresholds_digest="sha256:" + "2" * 64,
            git_commit="fixture",
            app_version="0.2.0-beta.1",
            toolchain_identity="fixture:smoke",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / scene["input"]["media_path"]
            media.parent.mkdir(parents=True)
            media.write_bytes(b"scene-a")
            input_digest = benchmark.digest_input(media)
            result_path = root / scene["adapter"]["result_path"]
            result_path.parent.mkdir(parents=True, exist_ok=True)
            cases = (
                ({**successful_actual(), "exit_code": 9}, "failed"),
                (
                    {
                        **successful_actual(),
                        "exit_code": 130,
                        "termination_reason": "cancelled",
                        "cancelled": True,
                    },
                    "failed",
                ),
            )
            for actual, expected_status in cases:
                with self.subTest(actual=actual):
                    payload = external_envelope(scene, 30, input_digest, identity, actual=actual)
                    result_path.write_bytes(benchmark.canonical_json_bytes(payload) + b"\n")
                    self.assertEqual(
                        benchmark._copy_fixture_result(scene, 30, root, identity)["status"],
                        expected_status,
                    )
            payload = external_envelope(scene, 30, input_digest, identity, route="/Users/private/model")
            result_path.write_bytes(benchmark.canonical_json_bytes(payload) + b"\n")
            with self.assertRaisesRegex(benchmark.ConfigError, "route"):
                benchmark._copy_fixture_result(scene, 30, root, identity)

            contradictory = {
                **successful_actual(),
                "termination_reason": "cancelled",
                "cancelled": False,
            }
            payload = external_envelope(scene, 30, input_digest, identity, actual=contradictory)
            result_path.write_bytes(benchmark.canonical_json_bytes(payload) + b"\n")
            with self.assertRaisesRegex(benchmark.ConfigError, "termination"):
                benchmark._copy_fixture_result(scene, 30, root, identity)

            payload = external_envelope(scene, 30, input_digest, identity)
            payload["scale_results"]["30"]["artifacts"] = {
                "mesh.ply": "sha256:" + "a" * 64,
            }
            result_path.write_bytes(benchmark.canonical_json_bytes(payload) + b"\n")
            with self.assertRaisesRegex(benchmark.ConfigError, "artifacts"):
                benchmark._copy_fixture_result(scene, 30, root, identity)

    def test_toolchain_identity_uses_complete_toolchain_manager_install_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_key = Ed25519PrivateKey.generate()
            public_key = private_key.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
            public_key_base64 = base64.b64encode(public_key).decode("ascii")
            files = {
                "bin/colmap": b"colmap",
                "da3_mps/models/DA3-BASE/model.safetensors": b"base",
                "da3_mps/models/DA3-SMALL/model.safetensors": b"small",
            }
            components = []
            installed_artifacts = {}
            for index, (name, path) in enumerate(
                zip(("macos-arm64-core", "geometry-da3-base", "geometry-da3-small"), files),
                start=1,
            ):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(files[path])
                digest = hashlib.sha256(files[path]).hexdigest()
                archive_digest = f"{index}" * 64
                installed_artifacts[name] = archive_digest
                components.append(
                    {
                        "name": name,
                        "capabilities": [f"fixture.{name}"],
                        "url": f"https://example.invalid/{name}.zip",
                        "sha256": archive_digest,
                        "sizeBytes": 100 + index,
                        "expandedSizeBytes": 200 + index,
                        "contents": [path],
                        "criticalFileHashes": {path: digest},
                        "dependencies": [] if index == 1 else ["macos-arm64-core"],
                        "requirement": "optional" if index == 3 else "required",
                    }
                )
            manifest = {
                "schemaVersion": 2,
                "toolchainAPI": 2,
                "keyID": hashlib.sha256(public_key).hexdigest(),
                "version": "2.0.0",
                "publishedAt": "2026-07-01T00:00:00Z",
                "appVersionRange": {"minimum": "0.2.0-beta.1"},
                "components": components,
                "signatureEd25519": "",
            }
            manifest["signatureEd25519"] = base64.b64encode(
                private_key.sign(benchmark.canonical_json_bytes(manifest))
            ).decode("ascii")
            state = {
                "schemaVersion": 2,
                "installedArtifacts": installed_artifacts,
                "installedCapabilities": sorted(
                    capability
                    for component in components
                    for capability in component["capabilities"]
                ),
                "signedManifest": manifest,
            }
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )

            identity = benchmark.resolved_toolchain_identity(
                root,
                "release",
                public_key_base64=public_key_base64,
            )
            self.assertRegex(identity or "", r"^sha256:[0-9a-f]{64}$")
            closure = benchmark._validated_toolchain_closure(root, public_key_base64)
            self.assertIsNotNone(closure)
            self.assertEqual(identity, evidence.toolchain_identity_from_closure(closure))

            forged = json.loads(json.dumps(state))
            forged["signedManifest"]["version"] = "9.9.9"
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(forged),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(benchmark.ConfigError, "signature"):
                benchmark.resolved_toolchain_identity(
                    root,
                    "release",
                    public_key_base64=public_key_base64,
                )
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )

            state["padding"] = "x" * (2 * 1024 * 1024)
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            identity = benchmark.resolved_toolchain_identity(
                root,
                "release",
                public_key_base64=public_key_base64,
            )
            self.assertRegex(identity or "", r"^sha256:[0-9a-f]{64}$")

            state["padding"] = "x" * benchmark.MAX_TOOLCHAIN_INSTALL_STATE_BYTES
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(benchmark.ConfigError, "size limit"):
                benchmark.resolved_toolchain_identity(
                    root,
                    "release",
                    public_key_base64=public_key_base64,
                )

            state.pop("padding")
            state["installedArtifacts"].pop("geometry-da3-small")
            state["installedCapabilities"].remove("fixture.geometry-da3-small")
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            identity = benchmark.resolved_toolchain_identity(
                root,
                "release",
                public_key_base64=public_key_base64,
            )
            self.assertRegex(identity or "", r"^sha256:[0-9a-f]{64}$")

            state["installedArtifacts"].pop("macos-arm64-core")
            state["installedCapabilities"].remove("fixture.macos-arm64-core")
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(benchmark.ConfigError, "core component"):
                benchmark.resolved_toolchain_identity(
                    root,
                    "release",
                    public_key_base64=public_key_base64,
                )

    def test_tracked_smoke_fixture_runs_without_a_toolchain(self) -> None:
        config_path = ROOT / "scripts/benchmark/reference-config.json"
        corpus_path = ROOT / "scripts/benchmark/fixtures/smoke-corpus.json"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            exit_code = benchmark.run_suite(
                profile="smoke",
                corpus_path=corpus_path,
                reference_config_path=config_path,
                toolchain_root=Path(directory) / "missing-toolchain",
                output_directory=output,
                dry_run=False,
                stdout=io.StringIO(),
            )
            result = json.loads((output / "suite.json").read_text(encoding="utf-8"))
        self.assertEqual(exit_code, 0)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["aggregates"]["passed"], 1)

    def test_dry_run_is_deterministic_and_never_launches_subprocesses(self) -> None:
        corpus = valid_corpus()
        config = valid_reference_config()
        with mock.patch.object(benchmark.subprocess, "run", side_effect=AssertionError("subprocess launched")):
            first = benchmark.build_dry_run_plan("smoke", corpus, config, Path("/toolchain"))
            second = benchmark.build_dry_run_plan("smoke", corpus, config, Path("/toolchain"))
        self.assertEqual(benchmark.canonical_json_bytes(first), benchmark.canonical_json_bytes(second))

    def test_missing_release_media_writes_blocked_result_and_returns_nonzero(self) -> None:
        corpus = release_corpus()
        config = valid_reference_config()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = root / "corpus.json"
            config_path = root / "reference.json"
            output = root / "output"
            corpus_path.write_bytes(benchmark.canonical_json_bytes(corpus) + b"\n")
            config_path.write_bytes(benchmark.canonical_json_bytes(config) + b"\n")
            exit_code = benchmark.run_suite(
                profile="release",
                corpus_path=corpus_path,
                reference_config_path=config_path,
                toolchain_root=root / "missing-toolchain",
                output_directory=output,
                dry_run=False,
                stdout=io.StringIO(),
            )
            result = json.loads((output / "suite.json").read_text(encoding="utf-8"))
        self.assertNotEqual(exit_code, 0)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["failures"], [])
        self.assertTrue(result["blocking_reasons"])
        self.assertTrue(result["missing_requirements"]["media"])
        self.assertIn("toolchain", result["missing_requirements"])
        self.assertEqual(result["missing_requirements"]["request_index"], "protected request index")

    def test_final_suite_validation_rejects_unknown_metrics_and_private_paths(self) -> None:
        config_path = ROOT / "scripts/benchmark/reference-config.json"
        corpus_path = ROOT / "scripts/benchmark/fixtures/smoke-corpus.json"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            self.assertEqual(
                benchmark.run_suite(
                    profile="smoke",
                    corpus_path=corpus_path,
                    reference_config_path=config_path,
                    toolchain_root=Path(directory) / "toolchain",
                    output_directory=output,
                    dry_run=False,
                    stdout=io.StringIO(),
                ),
                0,
            )
            result = json.loads((output / "suite.json").read_text(encoding="utf-8"))
        result["scene_results"][0]["metrics"]["unknown_metric"] = measured(1)
        with self.assertRaisesRegex(benchmark.ConfigError, "unknown metrics"):
            benchmark.validate_suite_result(result)
        del result["scene_results"][0]["metrics"]["unknown_metric"]
        result["scene_results"][0]["route"] = "/Users/private/route"
        with self.assertRaisesRegex(benchmark.ConfigError, "route"):
            benchmark.validate_suite_result(result)


if __name__ == "__main__":
    unittest.main()
