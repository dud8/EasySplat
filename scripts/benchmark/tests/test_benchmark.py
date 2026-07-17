from __future__ import annotations

import importlib.util
import base64
import hashlib
import io
import itertools
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from contextlib import ExitStack
from pathlib import Path
from typing import Callable
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
FIXTURE_GROUND_TRUTH_POSES = benchmark.canonical_json_bytes(
    {
        "schema_version": 1,
        "pose_convention": "world_to_camera",
        "quaternion_order": "wxyz",
        "handedness": "right_handed",
        "coordinate_space": "ground_truth_world",
        "image_coordinates": "normalized_display_pixels",
        "poses": [
            {
                "image_name": f"frame {index:04d}.jpg",
                "rcw_wxyz": {"w": 1.0, "x": 0.0, "y": 0.0, "z": 0.0},
            }
            for index in range(30)
        ],
    }
) + b"\n"
FIXTURE_HOST_MONITOR = b"{}\n"


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
FIXTURE_PREPARATION_VIEWS = []
for position, index in enumerate(FIXTURE_HOLDOUTS):
    image_bytes = FIXTURE_GROUND_TRUTH_IMAGES[index]
    camera_digest = evidence.render_camera_digest(fixture_render_camera(index))
    view = {
        "holdout_index": index,
        "source": {
            "path": f"rendering/source/{index:06d}.png",
            "sha256": evidence.sha256_bytes(image_bytes),
            "pixel_sha256": evidence.sha256_bytes(
                bytes([80 + position]) * 64 * 64 * 3
            ),
            "format": "png_rgb8",
            "width": 64,
            "height": 64,
            "native_decode_receipt_sha256": "sha256:" + "5" * 64,
            "native_decoded_rgb8_sha256": evidence.sha256_bytes(
                bytes([80 + position]) * 64 * 64 * 3
            ),
        },
        "source_camera": {
            "model": "PINHOLE",
            "width": 64,
            "height": 64,
            "parameters": [32.0, 32.0, 32.0, 32.0],
        },
        "transform": {"kind": "identity", "roi": [0, 0, 64, 64]},
        "target": {
            "path": f"rendering/ground-truth/{index:06d}.png",
            "sha256": evidence.sha256_bytes(image_bytes),
            "pixel_sha256": evidence.sha256_bytes(
                bytes([80 + position]) * 64 * 64 * 3
            ),
            "format": "png_rgb8",
            "width": 64,
            "height": 64,
        },
        "target_camera": {
            "model": "PINHOLE",
            "width": 64,
            "height": 64,
            "parameters": [32.0, 32.0, 32.0, 32.0],
        },
        "render_camera_digest": camera_digest,
    }
    view["preparation_view_sha256"] = evidence.sha256_bytes(
        evidence.canonical_json_bytes(view)
    )
    FIXTURE_PREPARATION_VIEWS.append(view)
FIXTURE_GROUND_TRUTH_PREPARATION = benchmark.canonical_json_bytes(
    {
        "schema_version": 2,
        "input_digest": "sha256:" + "1" * 64,
        "selection_manifest": {
            "path": "selection-manifest.json",
            "sha256": evidence.sha256_bytes(FIXTURE_SELECTION_MANIFEST),
        },
        "source_spec": {
            "path": "render-target-spec.json",
            "sha256": "sha256:" + "9" * 64,
        },
        "algorithm": {
            "id": "native_msplat_decode_brown_conrady_alpha0",
            "version": 2,
            "float_precision": "float32",
            "inverse_iterations": 20,
            "boundary_samples": 200,
            "interpolation": "bilinear",
            "boundary_mode": "clamp",
        },
        "producer": {
            "path": "scripts/benchmark/prepare_render_targets.py",
            "sha256": evidence.sha256_file(
                ROOT / "scripts" / "benchmark" / "prepare_render_targets.py"
            ),
            "runtime": {
                "implementation": "cpython",
                "python_version": "fixture",
                "numpy_version": "fixture",
                "pillow_version": "fixture",
            },
        },
        "native_decoder": {
            "contract": "native_coregraphics_imageio_rgb8_v1",
            "mode_version": 1,
            "executable_bytes": 1,
            "executable_sha256": "sha256:" + "2" * 64,
            "metallib_bytes": 1,
            "metallib_sha256": "sha256:" + "3" * 64,
            "trainer_build_digest": "sha256:" + "4" * 64,
            "msplat_source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
        },
        "views": FIXTURE_PREPARATION_VIEWS,
    }
) + b"\n"
FIXTURE_GROUND_TRUTH_PREPARATION_SHA256 = evidence.sha256_bytes(
    FIXTURE_GROUND_TRUTH_PREPARATION
)
FIXTURE_ACCURATE_RENDERING_REFERENCE = benchmark.canonical_json_bytes(
    {
        "schema_version": 2,
        "ground_truth_preparation_sha256": FIXTURE_GROUND_TRUTH_PREPARATION_SHA256,
        "views": [
            {
                "holdout_index": index,
                "camera": fixture_render_camera(index),
                "camera_digest": evidence.render_camera_digest(
                    fixture_render_camera(index)
                ),
                "ground_truth_sha256": evidence.sha256_bytes(
                    FIXTURE_GROUND_TRUTH_IMAGES[index]
                ),
                "preparation_view_sha256": FIXTURE_PREPARATION_VIEWS[position][
                    "preparation_view_sha256"
                ],
            }
            for position, index in enumerate(FIXTURE_HOLDOUTS)
        ],
    }
) + b"\n"

REFERENCE_ARTIFACT_CONTENTS = {
    "selection_manifest_sha256": ("selection-manifest.json", FIXTURE_SELECTION_MANIFEST),
    "ground_truth_poses_sha256": (
        "ground-truth-poses.json",
        FIXTURE_GROUND_TRUTH_POSES,
    ),
    "accurate_colmap_model_sha256": ("accurate-colmap-model.json", b"accurate COLMAP\n"),
    "accurate_rendering_reference_sha256": (
        "accurate-rendering-reference.json",
        FIXTURE_ACCURATE_RENDERING_REFERENCE,
    ),
    "ground_truth_preparation_sha256": (
        "ground-truth-preparation.json",
        FIXTURE_GROUND_TRUTH_PREPARATION,
    ),
    "paired_baseline_rendering_reference_sha256": (
        "paired-baseline-rendering-reference.json",
        b"paired baseline rendering reference\n",
    ),
    "orientation_label_sha256": (
        "orientation-label.json",
        b'{"coordinate_space":"ground_truth_world","physical_up":{"x":0,"y":1,"z":0},'
        b'"schema_version":1}\n',
    ),
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


def make_toolchain_manifest() -> dict[str, object]:
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


def make_toolchain_state(component_names: list[str]) -> dict[str, object]:
    manifest = make_toolchain_manifest()
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


def toolchain_identity_for_state(state: dict[str, object]) -> str:
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


TEST_NORMAL_TOOLCHAIN_STATE = make_toolchain_state(["macos-arm64-core"])
TEST_LARGE_AREA_TOOLCHAIN_STATE = make_toolchain_state(
    ["macos-arm64-core", "geometry-large-area"]
)
TEST_TOOLCHAIN_IDENTITY = toolchain_identity_for_state(TEST_LARGE_AREA_TOOLCHAIN_STATE)
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
                    "ba_global_frames_ratio": 1.1,
                    "ba_global_points_ratio": 1.1,
                    "ba_global_max_refinements": 5,
                    "ba_local_max_refinements": 2,
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
            "articulation_views": measured(0),
            "biconnected_blocks": measured(1),
            "largest_biconnected_block_views": measured(30),
            "second_largest_biconnected_block_views": measured(0),
            "local_pairs": measured(70),
            "retrieval_pairs": measured(10),
            "loop_pairs": measured(0),
            "matcher_seconds": measured(10.0),
            "mapping_seconds": measured(20.0),
            "matching_speedup": measured(10.0),
            "mapping_speedup": measured(1.5),
            "bundle_adjustment_cycles": measured(3),
            "orientation_status": measured("verified"),
            "orientation_physical_up_error_degrees": measured(0.75),
            "orientation_sign_correct": measured(True),
            "raster_fallback_count": measured(0),
            "raster_exact_fallback_elapsed_seconds": measured(0.0),
            "raster_exact_buffer_growth_count": measured(0),
            "raster_exact_buffer_bytes_added": measured(0),
            "raster_replay_elapsed_seconds": measured(0.0),
            "raster_peak_exact_intersection_capacity": measured(0),
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
    *,
    category: str = "object_orbit",
    input_kind: str = "video",
    capture_traits: list[str] | None = None,
) -> dict[str, object]:
    scene = valid_scene(scene_id=scene_id, category=category)
    scene["input"]["kind"] = input_kind
    scene["capture_traits"] = ["ordered"] if capture_traits is None else capture_traits
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
        "sha256:" + "9" * 64,
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
            "variant": "baseline",
            "discarded": True,
            "end_to_end_seconds": 251.0,
            "geometry_seconds": 101.0,
            "training_seconds": 60.0,
        },
        {
            "variant": "candidate",
            "discarded": True,
            "end_to_end_seconds": 101.0,
            "geometry_seconds": 41.0,
            "training_seconds": 60.0,
        }
    ]
    for pair_index, (
        baseline_end,
        candidate_end,
        baseline_geometry,
        candidate_geometry,
    ) in enumerate((
        (249.0, 99.0, 99.0, 39.0),
        (250.0, 100.0, 100.0, 40.0),
        (251.0, 101.0, 101.0, 41.0),
    )):
        pair = [
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
        ordinary.extend(pair if pair_index % 2 == 0 else reversed(pair))
    phase = [
        {
            "variant": "baseline",
            "discarded": True,
            "matcher_seconds": 127.0,
            "mapping_seconds": 32.0,
        },
        {
            "variant": "candidate",
            "discarded": True,
            "matcher_seconds": 13.0,
            "mapping_seconds": 21.0,
        }
    ]
    for pair_index, (
        baseline_matcher,
        candidate_matcher,
        baseline_mapping,
        candidate_mapping,
    ) in enumerate((
        (123.0, 12.3, 28.0, 18.0),
        (124.0, 12.4, 29.0, 19.0),
        (125.0, 12.5, 30.0, 20.0),
        (126.0, 12.6, 31.0, 21.0),
        (127.0, 12.7, 32.0, 22.0),
    )):
        pair = [
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
        phase.extend(pair if pair_index % 2 == 0 else reversed(pair))
    fast_profile = [
        {
            "variant": "accurate_reference",
            "discarded": True,
            "end_to_end_seconds": 201.0,
        },
        {
            "variant": "fast_candidate",
            "discarded": True,
            "end_to_end_seconds": 101.0,
        }
    ]
    for pair_index, (reference_seconds, fast_seconds) in enumerate(
        ((199.0, 99.0), (200.0, 100.0), (201.0, 101.0))
    ):
        pair = [
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
        fast_profile.extend(pair if pair_index % 2 == 0 else reversed(pair))
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


def mapper_argv_for_cadence(
    variant: str,
    cadence: tuple[float, float, int, int] | None,
) -> list[str]:
    argv = [
        (
            "baseline-toolchain://resolved/bin/colmap"
            if variant == "baseline"
            else "toolchain://resolved/bin/colmap"
        ),
        "mapper",
    ]
    if cadence is None:
        return argv
    return [
        *argv,
        "--Mapper.ba_global_frames_ratio",
        str(cadence[0]),
        "--Mapper.ba_global_points_ratio",
        str(cadence[1]),
        "--Mapper.ba_global_max_refinements",
        str(cadence[2]),
        "--Mapper.ba_local_max_refinements",
        str(cadence[3]),
        "--Mapper.ba_local_max_num_iterations",
        "10",
        "--Mapper.ba_local_function_tolerance",
        "0.001",
        "--Mapper.ba_global_function_tolerance",
        "1e-06",
        "--Mapper.ba_local_num_images",
        "6",
    ]


def mapper_invocation(
    variant: str,
    cadence: tuple[float, float, int, int] | None,
    outcome: str,
    *,
    matching_attempt: int,
    digest_character: str,
    descriptor_matcher: str,
) -> dict[str, object]:
    return {
        "argv": mapper_argv_for_cadence(variant, cadence),
        "outcome": outcome,
        "matching_attempt": matching_attempt,
        "pair_list_digest": "sha256:" + digest_character * 64,
        "descriptor_matcher": descriptor_matcher,
    }


def mapper_invocations_for_variant(
    variant: str,
    request: dict[str, object],
    *,
    fallback: bool = False,
) -> list[dict[str, object]]:
    if variant in {"baseline", "accurate_reference"}:
        return [
            mapper_invocation(
                variant,
                None,
                "accepted",
                matching_attempt=1,
                digest_character="b" if variant == "baseline" else "c",
                descriptor_matcher="exact",
            )
        ]
    topology = request["candidate_run_configuration"]["input_topology"]
    if topology != "continuous":
        return [
            mapper_invocation(
                variant,
                (1.1, 1.1, 5, 2),
                "accepted",
                matching_attempt=1,
                digest_character="a",
                descriptor_matcher="faiss",
            )
        ]
    fast = mapper_invocation(
        variant,
        (4.0, 4.0, 5, 1),
        "rejected_geometry_gate" if fallback else "accepted",
        matching_attempt=1,
        digest_character="a",
        descriptor_matcher="faiss",
    )
    if not fallback:
        return [fast]
    return [
        fast,
        mapper_invocation(
            variant,
            (1.4, 1.4, 5, 2),
            "accepted",
            matching_attempt=1,
            digest_character="a",
            descriptor_matcher="faiss",
        ),
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
                "mapper_invocations": mapper_invocations_for_variant(variant, request),
                "started_monotonic_seconds": cursor,
                "ended_monotonic_seconds": cursor + duration,
                "process_cpu_microseconds": {"user": 0, "system": 0},
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
            "mapper_invocations": [],
            "started_monotonic_seconds": 0.0,
            "ended_monotonic_seconds": 1.0,
            "process_cpu_microseconds": {"user": 0, "system": 0},
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
        "schema_version": 3,
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
        "measurement_environment": {
            "schema_version": 1,
            "monotonic_clock": "mach_absolute_time",
            "monitor_sha256": evidence.sha256_bytes(FIXTURE_HOST_MONITOR),
            "monitor_executable_sha256": runner_identity(
                evidence.RENDERING_DRIVER_IDENTITY,
                "e",
            )["executable_sha256"],
            "sample_interval_seconds": 1.0,
            "sample_count": 2,
            "maximum_sample_gap_seconds": 1.0,
            "first_monotonic_seconds": started,
            "last_monotonic_seconds": ended + 1.0,
            "state_change_events": [],
            "power_sources": ["ac_power"],
            "thermal_states": ["nominal"],
            "low_power_mode_observed": False,
            "vm_pageouts_delta": 0,
            "vm_swapouts_delta": 0,
            "outer_child_cpu_microseconds": {"user": 0, "system": 0},
            "supervisor_host_busy_fraction": 0.05,
            "supervisor_process_cpu_fraction": 0.0,
            "supervisor_external_cpu_fraction": 0.05,
            "unattributed_child_cpu_fraction": 0.0,
            "commands": [
                {
                    "run_id": command["run_id"],
                    "host_busy_fraction": 0.05,
                    "process_cpu_fraction": 0.0,
                    "external_cpu_fraction": 0.05,
                }
                for command in commands
            ],
        },
    }


def host_state(
    *,
    user: int,
    system: int,
    idle: int,
    nice: int = 0,
    thermal_state: str = "nominal",
    low_power_mode: bool = False,
    power_source: str = "ac_power",
    vm_pageouts: int = 10,
    vm_swapouts: int = 20,
) -> dict[str, object]:
    return {
        "cpu_ticks": {"user": user, "system": system, "idle": idle, "nice": nice},
        "vm_pageouts": vm_pageouts,
        "vm_swapouts": vm_swapouts,
        "thermal_state": thermal_state,
        "low_power_mode": low_power_mode,
        "power_source": power_source,
    }


def host_monitor_report(
    samples: list[tuple[float, dict[str, object]]],
    *,
    sample_interval_seconds: float = 1.0,
    events: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "monotonic_clock": "mach_absolute_time",
        "sample_interval_seconds": sample_interval_seconds,
        "samples": [
            {"monotonic_seconds": timestamp, "state": state}
            for timestamp, state in samples
        ],
        "events": events or [],
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
            "host_monitor": "host-monitor.json",
            "stdout_log": "stdout.log",
            "stderr_log": "stderr.log",
            "output_ply": "splat.ply",
            "training_manifest": "training-manifest.json",
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
            "articulation_views": 0,
            "biconnected_blocks": 1,
            "largest_biconnected_block_views": 30,
            "second_largest_biconnected_block_views": 0,
            "local_pairs": 119,
            "retrieval_pairs": 0,
            "loop_pairs": 0,
            "matcher_seconds": 12.5,
            "mapping_seconds": 20.0,
            "bundle_adjustment_cycles": 3,
            "orientation_status": "verified",
            "orientation_physical_up_error_degrees": 0.75,
            "orientation_sign_correct": True,
            "raster_fallback_count": 0,
            "raster_exact_fallback_elapsed_seconds": 0.0,
            "raster_exact_buffer_growth_count": 0,
            "raster_exact_buffer_bytes_added": 0,
            "raster_replay_elapsed_seconds": 0.0,
            "raster_peak_exact_intersection_capacity": 0,
            "maximum_tile_intersections": 4,
            "dropped_intersection_count": 0,
        },
    }
    if lane != evidence.LANE_REFERENCE:
        for name in (
            "orientation_status",
            "orientation_physical_up_error_degrees",
            "orientation_sign_correct",
        ):
            observations["pipeline_metrics"][name] = None
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


def orientation_metrics_for_observations(
    observations: dict[str, object],
    alignment_offset: float = 0.0,
) -> dict[str, object]:
    pipeline = observations["pipeline_metrics"]
    status = pipeline["orientation_status"]
    fixture_status = (
        status
        if status in {"verified", "axis_aligned_sign_unverified", "unresolved"}
        else "verified"
    )
    return {
        "alignment_median_residual_degrees": 0.1 + alignment_offset,
        "alignment_p90_residual_degrees": 0.2 + alignment_offset,
        "alignment_support_count": 30,
        "candidate_source_to_ground_truth_wxyz": [1.0, 0.0, 0.0, 0.0],
        "orientation_physical_up_error_degrees": pipeline[
            "orientation_physical_up_error_degrees"
        ],
        "orientation_sign_correct": pipeline["orientation_sign_correct"],
        "orientation_status": fixture_status,
    }


def write_orientation_evidence_artifacts(
    root: Path,
    observations: dict[str, object],
    request: dict[str, object],
) -> None:
    timing = observations["timing"]
    candidate_runs = [
        record
        for record in timing["ordinary_runs"]
        if record["variant"] == "candidate"
    ]
    published = [
        receipt
        for receipt in observations["commands"]
        if receipt["variant"] == "candidate" and receipt["published_output"]
    ]
    if len(published) != 1:
        raise AssertionError("orientation fixture requires one published candidate run")
    scoring_run_id = published[0]["run_id"]
    run_receipts = []
    aggregate_runs = []
    for index, record in enumerate(candidate_runs):
        run_id = record["run_id"]
        run_root = root / "orientation-runs" / run_id
        run_root.mkdir(parents=True)
        geometry_manifest = run_root / "geometry-manifest.json"
        candidate_images = run_root / "candidate-images.txt"
        metrics_path = run_root / "orientation-metrics.json"
        stdout_path = run_root / "orientation-stdout.log"
        stderr_path = run_root / "orientation-stderr.log"
        candidate_data = (
            f"# Image list for {run_id}\n"
            + "".join(
                f"{index + 1} 1 0 0 0 0 0 0 1 frame {index:04d}.jpg\n\n"
                for index in range(30)
            )
        ).encode("utf-8")
        candidate_images.write_bytes(candidate_data)
        pipeline = observations["pipeline_metrics"]
        status = pipeline["orientation_status"]
        fixture_status = (
            status
            if status in {"verified", "axis_aligned_sign_unverified", "unresolved"}
            else "verified"
        )
        manifest_status = {
            "verified": "verified",
            "axis_aligned_sign_unverified": "axisAlignedSignUnverified",
            "unresolved": "unresolved",
        }[fixture_status]
        orientation: dict[str, object] = {"status": manifest_status}
        if fixture_status != "unresolved":
            error_degrees = float(
                pipeline["orientation_physical_up_error_degrees"] or 0.0
            )
            half_angle = math.radians(error_degrees) / 2
            orientation["sourceToCanonicalQuaternionWXYZ"] = {
                "w": math.cos(half_angle),
                "x": math.sin(half_angle),
                "y": 0.0,
                "z": 0.0,
            }
        geometry_manifest.write_bytes(
            evidence.canonical_json_bytes(
                {
                    "canonicalOrientation": orientation,
                    "handedness": "right-handed",
                    "modelHashes": {
                        "cameras.txt": "1" * 64,
                        "images.txt": hashlib.sha256(candidate_data).hexdigest(),
                        "points3D.txt": "2" * 64,
                    },
                    "mapping": {
                        "acceptedRefinementInvocationCount": 1,
                        "acceptedRefinementKind": "incrementalGlobal",
                        "attemptCount": 1,
                        "incrementalCadence": {
                            "globalFramesRatio": 1.4,
                            "globalMaxRefinements": 5,
                            "globalPointsRatio": 1.4,
                            "localMaxRefinements": 2,
                        },
                        "largestModelRegisteredViewCount": 30,
                        "modelCount": 1,
                        "secondLargestModelRegisteredViewCount": 0,
                        "unionRegisteredViewCount": 30,
                    },
                    "poseConvention": "world-to-camera",
                    "quaternionOrder": "wxyz",
                    "schemaVersion": 14,
                }
            )
            + b"\n"
        )
        metrics = orientation_metrics_for_observations(observations, index * 0.01)
        metrics_path.write_bytes(evidence.canonical_json_bytes(metrics) + b"\n")
        stdout_path.write_text(f"orientation complete: {run_id}\n", encoding="utf-8")
        stderr_path.write_text(f"orientation diagnostics: {run_id}\n", encoding="utf-8")
        relative_root = Path("orientation-runs") / run_id
        aggregate_runs.append(
            {
                "metrics": metrics,
                "metrics_path": (relative_root / "orientation-metrics.json").as_posix(),
                "run_id": run_id,
            }
        )
        run_receipts.append(
            {
                "actual_argv_sha256": "sha256:" + str(index + 1) * 64,
                "argv": [
                    "approved-orientation-driver",
                    f"renderer-closure://{request['rendering_driver_identity']['sha256']}",
                    f"renderer-executable://{request['rendering_driver_identity']['executable_sha256']}",
                    "extract-orientation",
                    "--geometry-manifest",
                    f"evidence://{(relative_root / 'geometry-manifest.json').as_posix()}",
                    "--candidate-images",
                    f"evidence://{(relative_root / 'candidate-images.txt').as_posix()}",
                    "--ground-truth-poses",
                    "evidence://ground-truth-poses.json",
                    "--ground-truth-poses-sha256",
                    request["reference_artifacts"]["ground_truth_poses_sha256"],
                    "--orientation-label",
                    "evidence://orientation-label.json",
                    "--orientation-label-sha256",
                    request["reference_artifacts"]["orientation_label_sha256"],
                    "--output",
                    f"evidence://{(relative_root / 'orientation-metrics.json').as_posix()}",
                ],
                "candidate_images_path": (
                    relative_root / "candidate-images.txt"
                ).as_posix(),
                "candidate_images_sha256": evidence.sha256_file(candidate_images),
                "ended_monotonic_seconds": float(index + 1),
                "exit_code": 0,
                "geometry_manifest_path": (
                    relative_root / "geometry-manifest.json"
                ).as_posix(),
                "geometry_manifest_sha256": evidence.sha256_file(geometry_manifest),
                "metrics_path": (
                    relative_root / "orientation-metrics.json"
                ).as_posix(),
                "metrics_sha256": evidence.sha256_file(metrics_path),
                "run_id": run_id,
                "started_monotonic_seconds": float(index),
                "stderr_path": (relative_root / "orientation-stderr.log").as_posix(),
                "stderr_sha256": evidence.sha256_file(stderr_path),
                "stdout_path": (relative_root / "orientation-stdout.log").as_posix(),
                "stdout_sha256": evidence.sha256_file(stdout_path),
                "timed_out": False,
            }
        )
    aggregate = {
        "runs": aggregate_runs,
        "schema_version": 1,
        "scoring_run_id": scoring_run_id,
    }
    aggregate_path = root / "orientation-metrics.json"
    aggregate_path.write_bytes(evidence.canonical_json_bytes(aggregate) + b"\n")
    request_sha256 = evidence.sha256_bytes(
        evidence.canonical_json_bytes(request) + b"\n"
    )
    supervisor = {
        "candidate_git_commit": request["binding"]["git_commit"],
        "ground_truth_poses_sha256": request["reference_artifacts"][
            "ground_truth_poses_sha256"
        ],
        "lane": request["binding"]["lane"],
        "metrics_index_sha256": evidence.sha256_file(aggregate_path),
        "orientation_label_sha256": request["reference_artifacts"][
            "orientation_label_sha256"
        ],
        "renderer_closure_sha256": request["rendering_driver_identity"]["sha256"],
        "renderer_executable_sha256": request["rendering_driver_identity"][
            "executable_sha256"
        ],
        "request_sha256": request_sha256,
        "runs": run_receipts,
        "scale": request["binding"]["scale"],
        "scene_id": request["binding"]["scene_id"],
        "schema_version": 1,
        "scoring_run_id": scoring_run_id,
    }
    (root / "orientation-supervisor.json").write_bytes(
        evidence.canonical_json_bytes(supervisor) + b"\n"
    )
    observations["artifacts"].update(
        {
            "orientation_metrics": "orientation-metrics.json",
            "orientation_supervisor": "orientation-supervisor.json",
        }
    )


def training_manifest_for_observations(
    observations: dict[str, object],
    candidate_configuration: dict[str, object],
) -> dict[str, object]:
    pipeline = observations["pipeline_metrics"]
    return {
        "schemaVersion": 5,
        "trainerVersion": "1.1.3 (git 106499b)",
        "runtimeVersion": "native-metal-cli-v2",
        "trainerBuildDigest": "3" * 64,
        "inputDigest": "1" * 64,
        "geometryDigest": "2" * 64,
        "detailProfile": candidate_configuration["detail_profile"],
        "iterationLimit": candidate_configuration["trainer_iterations"],
        "plateauWindow": candidate_configuration["trainer_plateau_window"],
        "cameraOrderSeed": candidate_configuration["deterministic_seed"],
        "completedIteration": candidate_configuration["trainer_iterations"],
        "outputPath": "Output/splat.ply",
        "outputSHA256": hashlib.sha256(VALID_SPLAT_PLY.encode("utf-8")).hexdigest(),
        "outputBytes": len(VALID_SPLAT_PLY.encode("utf-8")),
        "gaussianCount": 1,
        "elapsedSeconds": 5.0,
        "peakMemoryBytes": 536_870_912,
        "memoryBudgetBytes": 8_589_934_592,
        "rasterFallbackCount": pipeline["raster_fallback_count"],
        "rasterExactFallbackElapsedSeconds": pipeline[
            "raster_exact_fallback_elapsed_seconds"
        ],
        "rasterExactBufferGrowthCount": pipeline["raster_exact_buffer_growth_count"],
        "rasterExactBufferBytesAdded": pipeline["raster_exact_buffer_bytes_added"],
        "rasterReplayElapsedSeconds": pipeline["raster_replay_elapsed_seconds"],
        "rasterPeakExactIntersectionCapacity": pipeline[
            "raster_peak_exact_intersection_capacity"
        ],
        "droppedIntersectionCount": pipeline["dropped_intersection_count"],
        "sceneBounds": {
            "center": {"x": 0.0, "y": 0.0, "z": 0.0},
            "radius": 2.5,
        },
        "completionStatus": "completed",
    }


def write_evidence_artifacts(
    root: Path,
    observations: dict[str, object],
    render_request: dict[str, object] | None = None,
) -> None:
    root.mkdir(parents=True, exist_ok=True)
    if render_request is None:
        candidate = next(
            receipt
            for receipt in observations["commands"]
            if receipt["variant"] in {"candidate", "fast_candidate"}
        )
        artifact_request = evidence_request(
            scale=candidate["scale"],
            lane=candidate["lane"],
        )
    else:
        artifact_request = render_request
    for name, content in (
        ("stdout.log", "complete\n"),
        ("stderr.log", ""),
        ("renderer-stdout.log", "render complete\n"),
        ("renderer-stderr.log", ""),
        ("splat.ply", VALID_SPLAT_PLY),
    ):
        (root / name).write_text(content, encoding="utf-8")
    if (
        "pipeline_metrics" in observations
        and "output_ply" in observations.get("artifacts", {})
    ):
        (root / "training-manifest.json").write_bytes(
            evidence.canonical_json_bytes(
                training_manifest_for_observations(
                    observations,
                    artifact_request["candidate_run_configuration"],
                )
            )
            + b"\n"
        )
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
    (root / "host-monitor.json").write_bytes(FIXTURE_HOST_MONITOR)
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
    if "registration" in observations:
        write_orientation_evidence_artifacts(
            root,
            observations,
            artifact_request,
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
        render_request = artifact_request
        renderer_identity = render_request["rendering_driver_identity"]
        renderer_digest = renderer_identity["executable_sha256"]
        renderer_closure_digest = renderer_identity["sha256"]
        scale = len(observations["registration"]["candidate"])
        holdouts = list(range(4, scale, 5))
        manifest_views = []
        render_operations = []
        for holdout_index in holdouts:
            preparation_view = next(
                view
                for view in FIXTURE_PREPARATION_VIEWS
                if view["holdout_index"] == holdout_index
            )
            ground_truth = FIXTURE_GROUND_TRUTH_IMAGES[holdout_index]
            source_path = Path(preparation_view["source"]["path"])
            (root / source_path).parent.mkdir(parents=True, exist_ok=True)
            (root / source_path).write_bytes(ground_truth)
            ground_truth_path = Path("rendering/ground-truth") / f"{holdout_index:06d}.png"
            (root / ground_truth_path).parent.mkdir(parents=True, exist_ok=True)
            (root / ground_truth_path).write_bytes(ground_truth)
            camera = fixture_render_camera(holdout_index)
            camera_digest = evidence.render_camera_digest(camera)
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
                        "source_path": source_path.as_posix(),
                        "source_sha256": evidence.sha256_bytes(ground_truth),
                        "preparation_view_sha256": preparation_view[
                            "preparation_view_sha256"
                        ],
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
            "schema_version": 2,
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
            "ground_truth_preparation_sha256": render_request[
                "reference_artifacts"
            ]["ground_truth_preparation_sha256"],
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
            "ground_truth_preparation_sha256": render_request[
                "reference_artifacts"
            ]["ground_truth_preparation_sha256"],
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
        contract = benchmark.benchmark_contract(corpus)
        self.assertEqual(len(contract["scenes"]), 26)
        self.assertEqual(
            sum(
                len(lanes)
                for scene in contract["scenes"]
                for lanes in scene["required_evidence_lanes"].values()
            ),
            65,
        )
        self.assertEqual(
            benchmark.validate_tracked_benchmark_contract(corpus),
            benchmark.benchmark_contract_sha256(corpus),
        )
        changed_contract = json.loads(json.dumps(corpus))
        changed_contract["scenes"][0]["aggregate_scale"] = 120
        with self.assertRaisesRegex(benchmark.ConfigError, "public structure"):
            benchmark.validate_tracked_benchmark_contract(changed_contract)
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
        self.assertEqual(baseline["run_configuration"]["ba_global_frames_ratio"], 1.1)
        self.assertEqual(baseline["run_configuration"]["ba_global_points_ratio"], 1.1)
        self.assertEqual(baseline["run_configuration"]["ba_global_max_refinements"], 5)
        self.assertEqual(baseline["run_configuration"]["ba_local_max_refinements"], 2)
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
            "articulation_views",
            "biconnected_blocks",
            "largest_biconnected_block_views",
            "second_largest_biconnected_block_views",
            "local_pairs",
            "retrieval_pairs",
            "loop_pairs",
            "matcher_seconds",
            "mapping_seconds",
            "matching_speedup",
            "mapping_speedup",
            "bundle_adjustment_cycles",
            "orientation_status",
            "orientation_physical_up_error_degrees",
            "orientation_sign_correct",
            "raster_fallback_count",
            "maximum_tile_intersections",
            "dropped_intersection_count",
        ):
            self.assertIn(name, schema["$defs"]["metrics"]["properties"])
        for name in (
            "orientation_seconds",
            "orientation_median_residual_degrees",
            "orientation_p90_residual_degrees",
            "orientation_bootstrap_p95_degrees",
        ):
            self.assertNotIn(name, schema["$defs"]["metrics"]["properties"])
        evidence_schema = json.loads(
            (ROOT / "scripts/benchmark/evidence.schema.json").read_text(encoding="utf-8")
        )
        self.assertIs(evidence_schema["additionalProperties"], False)
        self.assertIs(evidence_schema["properties"]["artifacts"]["additionalProperties"]["additionalProperties"], False)
        self.assertIn("measurement_runner", evidence_schema["required"])
        self.assertIn("gate_scopes", evidence_schema["required"])
        cpu_schema = evidence_schema["properties"]["commands"]["items"]["properties"][
            "process_cpu_microseconds"
        ]["properties"]
        self.assertEqual(cpu_schema["user"]["maximum"], (1 << 64) - 1)
        self.assertEqual(cpu_schema["system"]["maximum"], (1 << 64) - 1)
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
        self.assertEqual(evaluation["status"], "failed")
        self.assertTrue(any("primary" in item for item in evaluation["blocking_reasons"]))
        self.assertTrue(evaluation["failures"])


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
        evidence.LPIPS_DISTANCE_OVERRIDE = lambda first, second: float(
            abs(first.mean() - second.mean())
        )

    def test_request_pins_the_current_render_target_contract(self) -> None:
        request = evidence_request()

        self.assertEqual(request["schema_version"], 3)
        self.assertIn(
            "ground_truth_preparation_sha256",
            request["reference_artifacts"],
        )
        evidence.validate_request(request)

    def test_lane_outcome_distinguishes_execution_failure_from_environment(self) -> None:
        request = evidence_request()
        runner = runner_identity(evidence.LANE_REFERENCE)
        machine = evidence_machine(evidence.LANE_REFERENCE)
        for reason, exit_code in (
            ("launch_failed", None),
            ("timed_out", -15),
            ("timed_out", 0),
            ("nonzero_exit", 23),
        ):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "lane-outcome.json"
                receipt = evidence.derive_lane_outcome(
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                    machine,
                    kind="execution_failed",
                    reason=reason,
                    exit_code=exit_code,
                )
                path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
                verified = evidence.validate_prepared_lane_outcome_file(
                    path,
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                )
                self.assertEqual(verified["outcome"]["reason"], reason)

        for reason, stage, exit_code in (
            ("host_monitor_failed", "host_monitor", None),
            ("host_monitor_failed", "host_monitor", 0),
            ("postprocessing_failed", "postprocessing", 0),
        ):
            with self.subTest(reason=reason, exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "lane-outcome.json"
                receipt = evidence.derive_lane_outcome(
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                    machine,
                    kind="infrastructure_blocked",
                    reason=reason,
                    exit_code=exit_code,
                )
                path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
                verified = evidence.validate_prepared_lane_outcome_file(
                    path,
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                )
                self.assertEqual(verified["outcome"]["stage"], stage)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "host-monitor.json").write_bytes(FIXTURE_HOST_MONITOR)
            observations = raw_observations(evidence.LANE_REFERENCE)
            environment = supervisor_run(observations)["measurement_environment"]
            environment["low_power_mode_observed"] = True
            environment_receipt = {
                "schema_version": 1,
                "started_monotonic_seconds": min(
                    command["started_monotonic_seconds"]
                    for command in observations["commands"]
                ),
                "ended_monotonic_seconds": max(
                    command["ended_monotonic_seconds"]
                    for command in observations["commands"]
                )
                + 1.0,
                "commands": [
                    {
                        "run_id": command["run_id"],
                        "started_monotonic_seconds": command[
                            "started_monotonic_seconds"
                        ],
                        "ended_monotonic_seconds": command["ended_monotonic_seconds"],
                        "process_cpu_microseconds": command[
                            "process_cpu_microseconds"
                        ],
                    }
                    for command in observations["commands"]
                ],
                "measurement_environment": environment,
            }
            environment_path = root / "measurement-environment.json"
            environment_path.write_bytes(
                evidence.canonical_json_bytes(environment_receipt) + b"\n"
            )
            receipt = evidence.derive_lane_outcome(
                request,
                evidence.LANE_REFERENCE,
                runner,
                machine,
                kind="environment_rejected",
                reason="policy_violation",
                exit_code=0,
                environment_receipt_path=environment_path,
            )
            outcome_path = root / "lane-outcome.json"
            outcome_path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
            verified = evidence.validate_prepared_lane_outcome_file(
                outcome_path,
                request,
                evidence.LANE_REFERENCE,
                runner,
            )
            self.assertEqual(verified["outcome"]["kind"], "environment_rejected")

            environment["low_power_mode_observed"] = False
            environment_path.write_bytes(
                evidence.canonical_json_bytes(environment_receipt) + b"\n"
            )
            with self.assertRaisesRegex(evidence.EvidenceError, "does not prove"):
                evidence.derive_lane_outcome(
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                    machine,
                    kind="environment_rejected",
                    reason="policy_violation",
                    exit_code=0,
                    environment_receipt_path=environment_path,
                )

    def test_lane_outcome_shape_is_fail_closed(self) -> None:
        request = evidence_request()
        runner = runner_identity(evidence.LANE_REFERENCE)
        machine = evidence_machine(evidence.LANE_REFERENCE)
        receipt = evidence.derive_lane_outcome(
            request,
            evidence.LANE_REFERENCE,
            runner,
            machine,
            kind="execution_failed",
            reason="nonzero_exit",
            exit_code=23,
        )
        cases = (
            ("invalid fields", {**receipt, "unexpected": True}),
            ("invalid fields", {key: value for key, value in receipt.items() if key != "outcome"}),
        )
        for expected, changed in cases:
            with self.subTest(case=expected), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "lane-outcome.json"
                path.write_bytes(evidence.canonical_json_bytes(changed) + b"\n")
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.validate_prepared_lane_outcome_file(
                        path,
                        request,
                        evidence.LANE_REFERENCE,
                        runner,
                    )

        for reason, exit_code in (("timed_out", 256), ("nonzero_exit", -256)):
            with self.subTest(reason=reason, exit_code=exit_code):
                expected = "bounded exit code" if reason == "timed_out" else "bounded nonzero"
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.derive_lane_outcome(
                        request,
                        evidence.LANE_REFERENCE,
                        runner,
                        machine,
                        kind="execution_failed",
                        reason=reason,
                        exit_code=exit_code,
                    )
        for reason, exit_code in (
            ("host_monitor_failed", 1),
            ("postprocessing_failed", None),
        ):
            with self.subTest(reason=reason, exit_code=exit_code):
                with self.assertRaisesRegex(evidence.EvidenceError, "infrastructure"):
                    evidence.derive_lane_outcome(
                        request,
                        evidence.LANE_REFERENCE,
                        runner,
                        machine,
                        kind="infrastructure_blocked",
                        reason=reason,
                        exit_code=exit_code,
                    )

    def test_raw_processors_have_no_private_signing_surface(self) -> None:
        raw_processors = (
            ROOT / "scripts/benchmark/evidence_protocol.py",
            ROOT / "scripts/benchmark/easysplat_benchmark.py",
            ROOT / "scripts/benchmark/run_lane.py",
            ROOT / "scripts/benchmark/prepare_evidence.py",
        )
        forbidden = (
            "Ed25519PrivateKey",
            "from_private_bytes",
            "--private-key",
            "private_seed",
            "load_private_seed",
            "sign_attestation",
            "sign_lane_outcome",
            "_sign_ed25519",
        )
        for path in raw_processors:
            source = path.read_text(encoding="utf-8")
            for token in forbidden:
                with self.subTest(path=path.name, token=token):
                    self.assertNotIn(token, source)

        for name in (
            "main",
            "load_private_seed_bytes",
            "load_private_seed_from_stdin",
            "public_key_from_private_seed",
            "sign_attestation",
            "sign_lane_outcome",
            "produce_attestation",
            "produce_lane_outcome",
        ):
            with self.subTest(export=name):
                self.assertFalse(hasattr(evidence, name))

    def test_lane_outcome_malformed_json_is_classified_as_evidence_error(self) -> None:
        request = evidence_request()
        runner = runner_identity(evidence.LANE_REFERENCE)
        cases = (
            (b'{"machine":{"logical_cpus":1e999}}\n', "non-finite"),
            (b"\xff\xfe", "not valid JSON"),
            (b'{"value":' + b"9" * 5_000 + b"}\n", "not valid JSON"),
            (b"[" * 2_000 + b"0" + b"]" * 2_000, "must be an object"),
        )
        for payload, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "lane-outcome.json"
                path.write_bytes(payload)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.validate_prepared_lane_outcome_file(
                        path,
                        request,
                        evidence.LANE_REFERENCE,
                        runner,
                    )

    def test_attestation_must_be_bounded_and_single_link(self) -> None:
        request = evidence_request()
        observations = raw_observations(evidence.LANE_REFERENCE)
        runner = runner_identity(evidence.LANE_REFERENCE)
        machine = evidence_machine(evidence.LANE_REFERENCE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.derive_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
                evidence.LANE_REFERENCE,
                runner,
                machine=machine,
            )
            path = root / "attestation.json"
            path.write_bytes(evidence.canonical_json_bytes(attestation) + b"\n")
            alias = root / "attestation-hardlink.json"
            os.link(path, alias)
            with self.assertRaisesRegex(evidence.EvidenceError, "single-link"):
                evidence.validate_prepared_attestation_file(
                    path,
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "attestation.json"
            with path.open("wb") as handle:
                handle.truncate(evidence.MAX_ATTESTATION_BYTES + 1)
            with self.assertRaisesRegex(evidence.EvidenceError, "bounded"):
                evidence.validate_prepared_attestation_file(
                    path,
                    request,
                    evidence.LANE_REFERENCE,
                    runner,
                )

    def test_biconnected_robustness_is_iterative_and_component_safe(self) -> None:
        def graph(view_count: int, edges: list[tuple[int, int]]) -> list[set[int]]:
            adjacency = [set() for _ in range(view_count)]
            for left, right in edges:
                adjacency[left].add(right)
                adjacency[right].add(left)
            return adjacency

        cases = {
            "single edge": (
                graph(2, [(0, 1)]),
                {
                    "articulation_views": 0,
                    "biconnected_blocks": 1,
                    "largest_biconnected_block_views": 2,
                    "second_largest_biconnected_block_views": 0,
                },
            ),
            "bow tie": (
                graph(5, [(0, 1), (1, 2), (2, 0), (2, 3), (3, 4), (4, 2)]),
                {
                    "articulation_views": 1,
                    "biconnected_blocks": 2,
                    "largest_biconnected_block_views": 3,
                    "second_largest_biconnected_block_views": 3,
                },
            ),
            "disconnected cycles and singleton": (
                graph(8, [(0, 1), (1, 2), (2, 0), (3, 4), (4, 5), (5, 6), (6, 3)]),
                {
                    "articulation_views": 0,
                    "biconnected_blocks": 2,
                    "largest_biconnected_block_views": 4,
                    "second_largest_biconnected_block_views": 3,
                },
            ),
        }
        for label, (adjacency, expected) in cases.items():
            with self.subTest(case=label):
                self.assertEqual(evidence._biconnected_robustness(adjacency), expected)

        long_path = graph(3_000, [(index, index + 1) for index in range(2_999)])
        self.assertEqual(
            evidence._biconnected_robustness(long_path),
            {
                "articulation_views": 2_998,
                "biconnected_blocks": 2_999,
                "largest_biconnected_block_views": 2,
                "second_largest_biconnected_block_views": 2,
            },
        )

    def tearDown(self) -> None:
        evidence.LPIPS_DISTANCE_OVERRIDE = None

    def produce(self, root: Path, lane: str) -> tuple[Path, dict[str, object]]:
        observations = raw_observations(lane)
        write_evidence_artifacts(root, observations)
        output = root / "attestation.json"
        attestation = evidence.derive_attestation(
            evidence_request(lane=lane),
            observations,
            root,
            output,
            lane,
            runner_identity(lane),
            machine=evidence_machine(lane),
        )
        output.write_bytes(evidence.canonical_json_bytes(attestation) + b"\n")
        return output, attestation

    def test_attestation_derivation_is_directly_validatable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observations = raw_observations(evidence.LANE_REFERENCE)
            write_evidence_artifacts(root, observations)
            request = evidence_request()
            runner = runner_identity(evidence.LANE_REFERENCE)
            prepared = evidence.validate_attestation_candidate(
                request,
                observations,
                root,
                root / "attestation.json",
                evidence.LANE_REFERENCE,
                runner,
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
            self.assertNotIn("signature", prepared)
            output = root / "attestation.json"
            output.write_bytes(evidence.canonical_json_bytes(prepared) + b"\n")
            validated = evidence.validate_prepared_attestation_file(
                output,
                request,
                evidence.LANE_REFERENCE,
                runner,
            )
            self.assertEqual(validated["metrics"], prepared["metrics"])

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
            self.assertEqual(metrics["orientation_physical_up_error_degrees"], measured(0.75))
            self.assertEqual(
                attestation["measurement_runner"],
                runner_identity(evidence.LANE_REFERENCE),
            )
            verified = evidence.validate_prepared_attestation_file(
                output,
                evidence_request(),
                evidence.LANE_REFERENCE,
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
            "sha256:" + "9" * 64,
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
            if key
            in {"command_log", "supervisor_run", "host_monitor", "stdout_log", "stderr_log"}
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
            write_evidence_artifacts(root, observations, request)
            attestation = evidence.derive_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
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
            write_evidence_artifacts(root, observations, request)
            with self.assertRaisesRegex(evidence.EvidenceError, "invalid.*output_ply"):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
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
                    evidence.derive_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
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
                    evidence.derive_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_pair_list_binds_biconnected_robustness_metrics(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        for metric in (
            "articulation_views",
            "biconnected_blocks",
            "largest_biconnected_block_views",
            "second_largest_biconnected_block_views",
        ):
            with self.subTest(metric=metric), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                changed["pipeline_metrics"][metric] += 1
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, f"pair_list {metric}"):
                    evidence.derive_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
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
            write_evidence_artifacts(root, observations, request)
            with self.assertRaisesRegex(evidence.EvidenceError, "retrieval.*quer"):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
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
                    evidence.derive_attestation(
                        request,
                        observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )
                else:
                    with self.assertRaisesRegex(evidence.EvidenceError, "retrieval"):
                        evidence.derive_attestation(
                            request,
                            observations,
                            root,
                            root / "attestation.json",
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
            write_evidence_artifacts(root, observations, request)
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
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
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
                "ba_local_max_refinements": 2,
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
        preparation = json.loads(FIXTURE_GROUND_TRUTH_PREPARATION)
        preparation["selection_manifest"]["sha256"] = request["reference_artifacts"][
            "selection_manifest_sha256"
        ]
        preparation_bytes = evidence.canonical_json_bytes(preparation) + b"\n"
        request["reference_artifacts"]["ground_truth_preparation_sha256"] = (
            evidence.sha256_bytes(preparation_bytes)
        )
        rendering_reference = json.loads(FIXTURE_ACCURATE_RENDERING_REFERENCE)
        rendering_reference["ground_truth_preparation_sha256"] = request[
            "reference_artifacts"
        ]["ground_truth_preparation_sha256"]
        rendering_reference_bytes = (
            evidence.canonical_json_bytes(rendering_reference) + b"\n"
        )
        request["reference_artifacts"]["accurate_rendering_reference_sha256"] = (
            evidence.sha256_bytes(rendering_reference_bytes)
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
                (root / "ground-truth-preparation.json").write_bytes(
                    preparation_bytes
                )
                (root / "accurate-rendering-reference.json").write_bytes(
                    rendering_reference_bytes
                )
                (root / "pair-list.json").write_bytes(
                    evidence.canonical_json_bytes(pair_list) + b"\n"
                )
                if label == "valid":
                    evidence.derive_attestation(
                        request,
                        changed_observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )
                else:
                    with self.assertRaisesRegex(evidence.EvidenceError, "exhaustive|duplicate"):
                        evidence.derive_attestation(
                            request,
                            changed_observations,
                            root,
                            root / "attestation.json",
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
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_exact_fallback_elapsed_seconds": None,
                },
                "raster",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_fallback_count": 1,
                    "raster_exact_buffer_growth_count": 2,
                },
                "growth count",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_exact_fallback_elapsed_seconds": 0.1,
                },
                "zero raster fallbacks",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_fallback_count": 1,
                },
                "evidence",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_fallback_count": 1,
                    "raster_exact_fallback_elapsed_seconds": 0.1,
                    "raster_exact_buffer_growth_count": 1,
                    "raster_exact_buffer_bytes_added": 65_536,
                    "raster_replay_elapsed_seconds": 0.2,
                    "raster_peak_exact_intersection_capacity": 1 << 32,
                },
                "exceeds UInt32",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "maximum_tile_intersections": 4_096,
                },
                "overflow threshold",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_fallback_count": 1,
                    "raster_exact_fallback_elapsed_seconds": 0.1,
                    "raster_exact_buffer_growth_count": 1,
                    "raster_exact_buffer_bytes_added": 65_536,
                    "raster_replay_elapsed_seconds": 0.2,
                    "raster_peak_exact_intersection_capacity": 4_096,
                },
                "overflow threshold",
            ),
            (
                {
                    **observations["pipeline_metrics"],
                    "raster_fallback_count": 1,
                    "raster_exact_fallback_elapsed_seconds": 0.1,
                    "raster_exact_buffer_growth_count": 1,
                    "raster_exact_buffer_bytes_added": 65_536,
                    "raster_replay_elapsed_seconds": 0.2,
                    "raster_peak_exact_intersection_capacity": 4_096,
                    "maximum_tile_intersections": 8_192,
                },
                "peak exact capacity",
            ),
        )
        for raw_metrics, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(observations))
                changed["pipeline_metrics"] = raw_metrics
                root = Path(directory)
                write_evidence_artifacts(root, changed)
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence.derive_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_training_manifest_binds_raster_recovery_metrics_to_published_output(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["artifacts"]["training_manifest"] = "training-manifest.json"
        observations["pipeline_metrics"].update(
            {
                "raster_exact_fallback_elapsed_seconds": 1.25,
                "raster_exact_buffer_growth_count": 1,
                "raster_exact_buffer_bytes_added": 65_536,
                "raster_replay_elapsed_seconds": 2.5,
                "raster_peak_exact_intersection_capacity": 4_096,
                "raster_fallback_count": 3,
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            tampered = json.loads(json.dumps(observations))
            tampered["pipeline_metrics"]["raster_exact_buffer_bytes_added"] += 1
            (root / "observations.json").write_bytes(
                evidence.canonical_json_bytes(tampered) + b"\n"
            )
            with self.assertRaisesRegex(evidence.EvidenceError, "training manifest"):
                evidence.derive_attestation(
                    evidence_request(),
                    tampered,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_training_manifest_elapsed_is_bound_to_published_timing_run(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            manifest_path = root / "training-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["elapsedSeconds"] = 61.0
            manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

            with self.assertRaisesRegex(evidence.EvidenceError, "published timing run"):
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_training_manifest_matches_requested_training_contract(self) -> None:
        request = evidence_request(lane=evidence.LANE_CONSTRAINED)
        observations = raw_observations(evidence.LANE_CONSTRAINED)
        configuration = request["candidate_run_configuration"]
        descriptor = {
            "bytes": len(VALID_SPLAT_PLY.encode("utf-8")),
            "sha256": "sha256:"
            + hashlib.sha256(VALID_SPLAT_PLY.encode("utf-8")).hexdigest(),
        }
        cases = (
            ("detailProfile", "balanced"),
            ("iterationLimit", 7_000),
            ("plateauWindow", 800),
            ("cameraOrderSeed", 43),
        )
        for field, value in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                manifest = training_manifest_for_observations(observations, configuration)
                manifest[field] = value
                path = Path(directory) / "training-manifest.json"
                path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")
                with self.assertRaisesRegex(evidence.EvidenceError, "does not match request"):
                    evidence._validate_training_manifest(
                        path,
                        descriptor,
                        1,
                        observations["pipeline_metrics"],
                        configuration,
                        60.0,
                    )

        with tempfile.TemporaryDirectory() as directory:
            manifest = training_manifest_for_observations(observations, configuration)
            manifest["deterministicSeed"] = manifest.pop("cameraOrderSeed")
            path = Path(directory) / "training-manifest.json"
            path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")
            with self.assertRaisesRegex(evidence.EvidenceError, "fields"):
                evidence._validate_training_manifest(
                    path,
                    descriptor,
                    1,
                    observations["pipeline_metrics"],
                    configuration,
                    60.0,
                )

    def test_training_manifest_mirrors_swift_integer_and_resource_guards(self) -> None:
        request = evidence_request(lane=evidence.LANE_REFERENCE)
        observations = raw_observations(evidence.LANE_REFERENCE)
        configuration = request["candidate_run_configuration"]
        descriptor = {
            "bytes": len(VALID_SPLAT_PLY.encode("utf-8")),
            "sha256": "sha256:"
            + hashlib.sha256(VALID_SPLAT_PLY.encode("utf-8")).hexdigest(),
        }
        cases = (
            ("zero peak memory", {"peakMemoryBytes": 0}, "memory contract"),
            ("zero memory budget", {"memoryBudgetBytes": 0}, "memory contract"),
            ("zero output bytes", {"outputBytes": 0}, "output contract"),
            ("zero Gaussian count", {"gaussianCount": 0}, "output contract"),
            (
                "fallback beyond completed iterations",
                {"rasterFallbackCount": 7_001},
                "fallback count",
            ),
            (
                "growth beyond fallback count",
                {"rasterExactBufferGrowthCount": 1},
                "growth count",
            ),
            (
                "allocation evidence without growth",
                {"rasterExactBufferBytesAdded": 1},
                "allocation evidence exceeds",
            ),
            (
                "fallback without recovery evidence",
                {"rasterFallbackCount": 1},
                "fallback evidence",
            ),
            ("signed integer overflow", {"peakMemoryBytes": 1 << 63}, "nonnegative integer"),
            ("seed overflow", {"cameraOrderSeed": 1 << 64}, "outside UInt64"),
            (
                "malformed exact duration",
                {"rasterExactFallbackElapsedSeconds": "not-a-number"},
                "finite and nonnegative",
            ),
            (
                "malformed detail profile",
                {"detailProfile": []},
                "detail profile is invalid",
            ),
            (
                "peak capacity overflow",
                {"rasterPeakExactIntersectionCapacity": 1 << 32},
                "exceeds UInt32",
            ),
            (
                "allocation growth exceeds budget",
                {
                    "rasterFallbackCount": 1,
                    "rasterExactFallbackElapsedSeconds": 0.1,
                    "rasterExactBufferGrowthCount": 1,
                    "rasterExactBufferBytesAdded": 8_589_934_593,
                    "rasterReplayElapsedSeconds": 0.2,
                    "rasterPeakExactIntersectionCapacity": 4_096,
                },
                "allocation evidence exceeds",
            ),
        )
        for label, changes, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                manifest = training_manifest_for_observations(observations, configuration)
                manifest.update(changes)
                path = Path(directory) / "training-manifest.json"
                path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")
                with self.assertRaisesRegex(evidence.EvidenceError, expected):
                    evidence._validate_training_manifest(
                        path,
                        descriptor,
                        1,
                        observations["pipeline_metrics"],
                        configuration,
                        60.0,
                    )

    def test_timing_requires_warmup_alternation_and_declared_repetition_counts(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        cases = []
        missing_warmup = json.loads(json.dumps(observations["timing"]))
        missing_warmup["ordinary_runs"] = missing_warmup["ordinary_runs"][1:]
        cases.append((missing_warmup, "ordinary_runs"))
        wrong_order = json.loads(json.dumps(observations["timing"]))
        wrong_order["ordinary_runs"][3]["variant"] = "baseline"
        cases.append((wrong_order, "counterbalanced"))
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
                    evidence.derive_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_timing_repeatability_rejects_contaminated_measured_runs(self) -> None:
        for variant in ("baseline", "candidate"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                observations = raw_observations(evidence.LANE_REFERENCE)
                measured_runs = [
                    record
                    for record in observations["timing"]["phase_runs"]
                    if record["variant"] == variant and not record["discarded"]
                ]
                for record, matcher_seconds in zip(
                    measured_runs,
                    (18.946, 19.1, 390.861, 19.0, 19.2),
                ):
                    record["matcher_seconds"] = matcher_seconds
                    record["end_to_end_seconds"] = (
                        matcher_seconds + record["mapping_seconds"] + 1.0
                    )
                observations["commands"] = execution_receipts(
                    observations["timing"],
                    evidence.LANE_REFERENCE,
                )
                observations["memory"] = memory_observation(
                    observations["timing"],
                    evidence.LANE_REFERENCE,
                )
                root = Path(directory)
                write_evidence_artifacts(root, observations)
                with self.assertRaisesRegex(evidence.EvidenceError, "repeatability"):
                    evidence.derive_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )
                self.assertTrue((root / "supervisor-run.json").is_file())
                self.assertTrue((root / "command.jsonl").is_file())

    def test_timing_repeatability_covers_every_published_duration(self) -> None:
        for field in (
            "end_to_end_seconds",
            "geometry_seconds",
            "training_seconds",
            "matcher_seconds",
            "mapping_seconds",
        ):
            with self.subTest(field=field):
                grouped = {
                    "baseline": [{field: value} for value in (20.0, 20.5, 21.0)],
                    "candidate": [{field: value} for value in (18.946, 19.1, 390.861)],
                }
                with self.assertRaisesRegex(evidence.EvidenceError, field):
                    evidence._validate_timing_repeatability(
                        grouped,
                        "synthetic timing",
                        (field,),
                    )

    def test_timing_repeatability_rejects_unstable_short_measurements(self) -> None:
        for values in ((0.01, 2.0, 2.0), (0.01, 0.01, 2.0), (0.01, 0.04, 0.05)):
            with self.subTest(values=values), self.assertRaisesRegex(
                evidence.EvidenceError,
                "repeatability",
            ):
                evidence._validate_timing_repeatability(
                    {"candidate": [{"matcher_seconds": value} for value in values]},
                    "synthetic timing",
                    ("matcher_seconds",),
                )

    def test_timing_repeatability_ignores_discarded_warmup(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        warmup = observations["timing"]["phase_runs"][0]
        warmup["matcher_seconds"] = 390.861
        warmup["end_to_end_seconds"] = (
            warmup["matcher_seconds"] + warmup["mapping_seconds"] + 1.0
        )
        observations["commands"] = execution_receipts(
            observations["timing"],
            evidence.LANE_REFERENCE,
        )
        observations["memory"] = memory_observation(
            observations["timing"],
            evidence.LANE_REFERENCE,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.derive_attestation(
                evidence_request(),
                observations,
                root,
                root / "attestation.json",
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(attestation["metrics"]["matcher_seconds"], measured(12.5))

    def test_measurement_environment_blocks_contaminated_timing_evidence(self) -> None:
        def receipt_for(
            observations: dict[str, object],
            mutation: Callable[[dict[str, object]], None],
        ) -> dict[str, object]:
            receipt = supervisor_run(observations)
            mutation(receipt["measurement_environment"])
            return receipt

        def no_change(_: dict[str, object]) -> None:
            return

        def external_cpu(environment: dict[str, object], fraction: float) -> None:
            environment["commands"][0].update(
                {
                    "host_busy_fraction": fraction,
                    "external_cpu_fraction": fraction,
                }
            )

        cases: tuple[
            tuple[str, Callable[[dict[str, object]], None], str | None], ...
        ] = (
            ("stable", no_change, None),
            (
                "fair thermal state",
                lambda value: value.update({"thermal_states": ["fair"]}),
                None,
            ),
            ("external CPU at boundary", lambda value: external_cpu(value, 0.10), None),
            (
                "external CPU above boundary",
                lambda value: external_cpu(value, 0.100_001),
                "external CPU",
            ),
            (
                "low power mode",
                lambda value: value.update({"low_power_mode_observed": True}),
                "Low Power Mode",
            ),
            (
                "battery power",
                lambda value: value.update({"power_sources": ["battery_power"]}),
                "AC power",
            ),
            (
                "power source changed",
                lambda value: value.update(
                    {"power_sources": ["ac_power", "battery_power"]}
                ),
                "uninterrupted AC power",
            ),
            (
                "serious thermal state",
                lambda value: value.update({"thermal_states": ["nominal", "serious"]}),
                "thermal state",
            ),
            (
                "critical thermal state",
                lambda value: value.update({"thermal_states": ["critical"]}),
                "thermal state",
            ),
            (
                "pageouts",
                lambda value: value.update({"vm_pageouts_delta": 1}),
                "pageouts",
            ),
            (
                "swapouts",
                lambda value: value.update({"vm_swapouts_delta": 1}),
                "swapouts",
            ),
        )
        for label, mutation, rejection in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                observations = raw_observations(evidence.LANE_REFERENCE)
                root = Path(directory)
                write_evidence_artifacts(root, observations)
                receipt = receipt_for(observations, mutation)
                (root / "supervisor-run.json").write_bytes(
                    evidence.canonical_json_bytes(receipt) + b"\n"
                )
                if rejection is None:
                    attestation = evidence.derive_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )
                    self.assertEqual(
                        attestation["metrics"]["wall_time_seconds"],
                        measured(100.0),
                    )
                else:
                    with self.assertRaisesRegex(evidence.EvidenceError, rejection):
                        evidence.derive_attestation(
                            evidence_request(),
                            observations,
                            root,
                            root / "attestation.json",
                            evidence.LANE_REFERENCE,
                            runner_identity(evidence.LANE_REFERENCE),
                            machine=evidence_machine(evidence.LANE_REFERENCE),
                        )

    def test_host_monitor_attributes_external_cpu_to_each_execution(self) -> None:
        commands = [
            {
                "run_id": "baseline-1",
                "started_monotonic_seconds": 1.0,
                "ended_monotonic_seconds": 2.0,
                "process_cpu_microseconds": {"user": 0, "system": 0},
            },
            {
                "run_id": "candidate-1",
                "started_monotonic_seconds": 2.0,
                "ended_monotonic_seconds": 3.0,
                "process_cpu_microseconds": {"user": 0, "system": 0},
            },
        ]
        report = host_monitor_report(
            [
                (0.5, host_state(user=1_000, system=0, idle=9_000)),
                (1.0, host_state(user=1_050, system=0, idle=9_450)),
                (2.0, host_state(user=1_350, system=0, idle=10_150)),
                (3.0, host_state(user=1_450, system=0, idle=11_050)),
                (3.5, host_state(user=1_500, system=0, idle=11_500)),
            ]
        )
        summary = lane_runner._summarize_host_monitor(
            report,
            commands,
            evidence_machine(evidence.LANE_REFERENCE),
            supervisor_started=1.0,
            supervisor_ended=3.0,
            monitor_sha256="sha256:" + "1" * 64,
            monitor_executable_sha256="sha256:" + "2" * 64,
            outer_child_cpu_microseconds={"user": 0, "system": 0},
        )

        by_run = {item["run_id"]: item for item in summary["commands"]}
        self.assertAlmostEqual(by_run["baseline-1"]["external_cpu_fraction"], 0.3)
        self.assertAlmostEqual(by_run["candidate-1"]["external_cpu_fraction"], 0.1)
        self.assertEqual(summary["power_sources"], ["ac_power"])
        self.assertEqual(summary["thermal_states"], ["nominal"])
        self.assertEqual(summary["maximum_sample_gap_seconds"], 1.0)
        self.assertAlmostEqual(summary["supervisor_host_busy_fraction"], 0.2)
        self.assertAlmostEqual(summary["supervisor_external_cpu_fraction"], 0.2)
        self.assertEqual(summary["unattributed_child_cpu_fraction"], 0.0)

    def test_host_monitor_preserves_transient_disqualifying_states(self) -> None:
        commands = [
            {
                "run_id": "candidate-1",
                "started_monotonic_seconds": 1.0,
                "ended_monotonic_seconds": 2.0,
                "process_cpu_microseconds": {"user": 0, "system": 0},
            }
        ]
        report = host_monitor_report(
            [
                (0.5, host_state(user=1_000, system=0, idle=9_000)),
                (
                    1.0,
                    host_state(
                        user=1_010,
                        system=0,
                        idle=9_090,
                        low_power_mode=True,
                    ),
                ),
                (
                    1.1,
                    host_state(
                        user=1_020,
                        system=0,
                        idle=9_180,
                        thermal_state="serious",
                        power_source="battery_power",
                    ),
                ),
                (1.2, host_state(user=1_030, system=0, idle=9_270)),
                (2.0, host_state(user=1_050, system=0, idle=10_050)),
                (2.5, host_state(user=1_060, system=0, idle=10_540)),
            ]
        )
        summary = lane_runner._summarize_host_monitor(
            report,
            commands,
            evidence_machine(evidence.LANE_REFERENCE),
            supervisor_started=1.0,
            supervisor_ended=2.0,
            monitor_sha256="sha256:" + "1" * 64,
            monitor_executable_sha256="sha256:" + "2" * 64,
            outer_child_cpu_microseconds={"user": 0, "system": 0},
        )

        self.assertTrue(summary["low_power_mode_observed"])
        self.assertEqual(summary["power_sources"], ["ac_power", "battery_power"])
        self.assertEqual(summary["thermal_states"], ["nominal", "serious"])

    def test_host_monitor_event_only_transition_rejects_measurement(self) -> None:
        command = {
            "run_id": "candidate-1",
            "started_monotonic_seconds": 1.0,
            "ended_monotonic_seconds": 2.0,
            "process_cpu_microseconds": {"user": 0, "system": 0},
        }
        report = host_monitor_report(
            [
                (0.5, host_state(user=1_000, system=0, idle=9_000)),
                (1.0, host_state(user=1_050, system=0, idle=9_450)),
                (1.6, host_state(user=1_080, system=0, idle=10_020)),
                (2.0, host_state(user=1_100, system=0, idle=10_400)),
                (2.5, host_state(user=1_120, system=0, idle=10_880)),
            ],
            events=[{"monotonic_seconds": 1.5, "kind": "low_power_mode"}],
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor_path = root / "host-monitor.json"
            monitor_path.write_bytes(evidence.canonical_json_bytes(report) + b"\n")
            summary = lane_runner._summarize_host_monitor(
                report,
                [command],
                evidence_machine(evidence.LANE_REFERENCE),
                supervisor_started=1.0,
                supervisor_ended=2.0,
                monitor_sha256=evidence.sha256_file(monitor_path),
                monitor_executable_sha256="sha256:" + "2" * 64,
                outer_child_cpu_microseconds={"user": 0, "system": 0},
            )
            self.assertEqual(
                summary["state_change_events"],
                [{"monotonic_seconds": 1.5, "kind": "low_power_mode"}],
            )
            self.assertFalse(summary["low_power_mode_observed"])
            rejections = evidence.measurement_environment_rejections(
                summary,
                evidence_machine(evidence.LANE_REFERENCE),
                [command],
                1.0,
                2.0,
                root / "measurement-environment.json",
                "sha256:" + "2" * 64,
            )
        self.assertIn("host_state_change", rejections)

    def test_host_monitor_rejects_incomplete_or_overclaimed_measurements(self) -> None:
        command = {
            "run_id": "candidate-1",
            "started_monotonic_seconds": 1.0,
            "ended_monotonic_seconds": 2.0,
            "process_cpu_microseconds": {"user": 2_000_000, "system": 0},
        }
        base = host_monitor_report(
            [
                (0.5, host_state(user=1_000, system=0, idle=9_000)),
                (1.0, host_state(user=1_050, system=0, idle=9_450)),
                (2.0, host_state(user=1_150, system=0, idle=10_350)),
                (2.5, host_state(user=1_200, system=0, idle=10_800)),
            ]
        )
        cases = (
            ("CPU", base, {"user": 1_000_000, "system": 0}),
            (
                "sample gap",
                {
                    **base,
                    "samples": [
                        base["samples"][0],
                        {**base["samples"][-1], "monotonic_seconds": 3.5},
                    ],
                },
                {"user": 3_000_000, "system": 0},
            ),
            (
                "clock",
                {**base, "monotonic_clock": "system_uptime"},
                {"user": 3_000_000, "system": 0},
            ),
        )
        for expected, report, outer_cpu in cases:
            with self.subTest(case=expected), self.assertRaisesRegex(
                evidence.EvidenceError,
                expected,
            ):
                lane_runner._summarize_host_monitor(
                    report,
                    [command],
                    evidence_machine(evidence.LANE_REFERENCE),
                    supervisor_started=1.0,
                    supervisor_ended=2.0,
                    monitor_sha256="sha256:" + "1" * 64,
                    monitor_executable_sha256="sha256:" + "2" * 64,
                    outer_child_cpu_microseconds=outer_cpu,
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
                        if sample["run_id"] != "ordinary-1"
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
                    evidence.derive_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "command.jsonl").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "command_log"):
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    changed,
                    root,
                    root / "attestation.json",
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
                    evidence.derive_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_execution_receipts_require_bounded_process_cpu_time(self) -> None:
        for label, cpu_time in (
            ("negative", {"user": -1, "system": 0}),
            ("boolean", {"user": True, "system": 0}),
            ("unknown field", {"user": 0, "system": 0, "idle": 0}),
        ):
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                observations = raw_observations(evidence.LANE_REFERENCE)
                observations["commands"][0]["process_cpu_microseconds"] = cpu_time
                root = Path(directory)
                write_evidence_artifacts(root, observations)
                with self.assertRaisesRegex(evidence.EvidenceError, "process CPU"):
                    evidence.derive_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_published_training_duration_requires_candidate_end_to_end_run(self) -> None:
        for label, predicate in (
            ("baseline", lambda receipt: receipt["variant"] == "baseline"),
            (
                "discarded warm-up",
                lambda receipt: receipt["variant"] == "candidate"
                and receipt["run_id"] == "ordinary-1",
            ),
        ):
            with self.subTest(label=label):
                observations = raw_observations(evidence.LANE_REFERENCE)
                published = next(
                    receipt
                    for receipt in observations["commands"]
                    if receipt["published_output"]
                )
                published["published_output"] = False
                wrong_run = next(
                    receipt for receipt in observations["commands"] if predicate(receipt)
                )
                wrong_run["published_output"] = True

                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "candidate end-to-end run",
                ):
                    evidence._published_training_duration(
                        observations["commands"],
                        observations["timing"],
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
            "orientation_label",
            "render_job",
            "rendering_manifest",
            "render_supervisor",
            "renderer_stdout_log",
            "renderer_stderr_log",
        ):
            del observations["artifacts"][artifact]
        for field in evidence.ORIENTATION_PIPELINE_FIELDS:
            observations["pipeline_metrics"][field] = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.derive_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
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
                    evidence.derive_attestation(
                        request,
                        changed,
                        root,
                        root / "attestation.json",
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
            attestation = evidence.derive_attestation(
                evidence_request(),
                failed,
                root,
                root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    unbound,
                    root,
                    root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "large-area.zip").write_bytes((root / "normal-photo.zip").read_bytes())
            with self.assertRaisesRegex(evidence.EvidenceError, "toolchain.*distinct|closure"):
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "normal-photo.zip").write_text("not a ZIP", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "valid ZIP"):
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_toolchain_size_evidence_accepts_exact_signed_component_closures(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            attestation = evidence.derive_attestation(
                evidence_request(),
                observations,
                root,
                root / "attestation.json",
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
        request["binding"]["toolchain_identity"] = toolchain_identity_for_state(
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
            attestation = evidence.derive_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
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
                manifest = make_toolchain_manifest()
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
                        toolchain_identity_for_state(states["large"]),
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
                    evidence.derive_attestation(
                        evidence_request(),
                        observations,
                        root,
                        root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
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
                    evidence.derive_attestation(
                        evidence_request(),
                        changed,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_orientation_evidence_is_status_consistent(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        unresolved = json.loads(json.dumps(observations))
        unresolved["pipeline_metrics"]["orientation_status"] = "unresolved"
        unresolved["pipeline_metrics"]["orientation_physical_up_error_degrees"] = None
        unresolved["pipeline_metrics"]["orientation_sign_correct"] = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unresolved_request = evidence_request()
            unresolved_request["reference_artifacts"]["orientation_expected_status"] = "unresolved"
            write_evidence_artifacts(root, unresolved, unresolved_request)
            attestation = evidence.derive_attestation(
                unresolved_request,
                unresolved,
                root,
                root / "attestation.json",
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(attestation["metrics"]["orientation_status"], measured("unresolved"))

    def test_axis_aligned_sign_unverified_uses_undirected_error_without_sign_evidence(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["pipeline_metrics"]["orientation_status"] = (
            "axis_aligned_sign_unverified"
        )
        observations["pipeline_metrics"]["orientation_physical_up_error_degrees"] = 0.75
        observations["pipeline_metrics"]["orientation_sign_correct"] = None
        request = evidence_request()
        request["reference_artifacts"]["orientation_expected_status"] = (
            "axis_aligned_sign_unverified"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            attestation = evidence.derive_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
                evidence.LANE_REFERENCE,
                runner_identity(evidence.LANE_REFERENCE),
                machine=evidence_machine(evidence.LANE_REFERENCE),
            )
        self.assertEqual(
            attestation["metrics"]["orientation_status"],
            measured("axis_aligned_sign_unverified"),
        )
        self.assertEqual(
            attestation["metrics"]["orientation_physical_up_error_degrees"],
            measured(0.75),
        )
        self.assertEqual(
            attestation["metrics"]["orientation_sign_correct"],
            {"availability": "not_available", "reason": "not_measured"},
        )

        invalid = json.loads(json.dumps(observations))
        invalid["pipeline_metrics"]["orientation_sign_correct"] = True
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, invalid, request)
            with self.assertRaisesRegex(evidence.EvidenceError, "without a sign claim"):
                evidence.derive_attestation(
                    request,
                    invalid,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_orientation_label_uses_closed_ground_truth_world_physical_up_schema(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        request = evidence_request()
        malformed_label = (
            b'{"coordinate_space":"source_world","physical_up":{"x":0,"y":0,"z":0},'
            b'"schema_version":1}\n'
        )
        request["reference_artifacts"]["orientation_label_sha256"] = evidence.sha256_bytes(
            malformed_label
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            label = root / "orientation-label.json"
            label.write_bytes(malformed_label)
            with self.assertRaisesRegex(evidence.EvidenceError, "orientation label"):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_scene_quality_rejects_unbound_runner_orientation_claims(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        request = evidence_request()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            observations["artifacts"].pop("orientation_metrics")
            observations["artifacts"].pop("orientation_supervisor")
            (root / "orientation-metrics.json").unlink()
            (root / "orientation-supervisor.json").unlink()
            (root / "observations.json").write_bytes(
                evidence.canonical_json_bytes(observations) + b"\n"
            )
            with self.assertRaisesRegex(
                evidence.EvidenceError,
                "orientation.*artifacts|missing required evidence artifacts",
            ):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_removed_orientation_claims_are_rejected_by_closed_schemas(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        removed = (
            "orientation_seconds",
            "orientation_median_residual_degrees",
            "orientation_p90_residual_degrees",
            "orientation_bootstrap_p95_degrees",
        )
        for name in removed:
            with self.subTest(surface="pipeline", name=name):
                raw_pipeline = dict(observations["pipeline_metrics"])
                raw_pipeline[name] = 0.0
                with self.assertRaisesRegex(evidence.EvidenceError, "unknown "):
                    evidence._pipeline_metrics(raw_pipeline)

            with self.subTest(surface="orientation evidence", name=name):
                metrics = orientation_metrics_for_observations(observations)
                metrics[name] = 0.0
                with self.assertRaisesRegex(evidence.EvidenceError, "unknown "):
                    evidence.validate_orientation_metrics(metrics)

        timing = json.loads(json.dumps(observations["timing"]))
        candidate = next(
            record for record in timing["ordinary_runs"] if record["variant"] == "candidate"
        )
        candidate["orientation_seconds"] = 0.0
        with self.assertRaisesRegex(evidence.EvidenceError, "unknown "):
            evidence._timing_metrics(
                timing,
                evidence.LANE_REFERENCE,
                {"scene_quality", "suite_performance"},
            )

    def test_supervisor_orientation_rejects_swapped_run_artifacts(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        request = evidence_request()
        cases = (
            "geometry-manifest.json",
            "candidate-images.txt",
            "orientation-metrics.json",
            "orientation-stdout.log",
            "orientation-stderr.log",
        )
        for filename in cases:
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_evidence_artifacts(root, observations, request)
                first_run = next(
                    record["run_id"]
                    for record in observations["timing"]["ordinary_runs"]
                    if record["variant"] == "candidate"
                )
                second_run = next(
                    record["run_id"]
                    for record in observations["timing"]["ordinary_runs"]
                    if record["variant"] == "candidate" and record["run_id"] != first_run
                )
                first_path = root / "orientation-runs" / first_run / filename
                second_path = root / "orientation-runs" / second_run / filename
                first_bytes = first_path.read_bytes()
                first_path.write_bytes(second_path.read_bytes())
                second_path.write_bytes(first_bytes)
                with self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "orientation.*digest|orientation.*changed|orientation.*does not match",
                ):
                    evidence.derive_attestation(
                        request,
                        observations,
                        root,
                        root / "attestation.json",
                        evidence.LANE_REFERENCE,
                        runner_identity(evidence.LANE_REFERENCE),
                        machine=evidence_machine(evidence.LANE_REFERENCE),
                    )

    def test_supervisor_orientation_rejects_a_swapped_receipt(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        request = evidence_request()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            path = root / "orientation-supervisor.json"
            receipt = json.loads(path.read_text(encoding="utf-8"))
            receipt["runs"][0], receipt["runs"][1] = receipt["runs"][1], receipt["runs"][0]
            path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
            with self.assertRaisesRegex(
                evidence.EvidenceError,
                "orientation supervisor runs are not in candidate timing order",
            ):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

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
            write_evidence_artifacts(root, observations, request)
            with self.assertRaisesRegex(evidence.EvidenceError, "requested scale 250"):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

        malformed = evidence_request()
        malformed["holdout_indices"] = [4, 9, 14, 19, 24, 28]
        with self.assertRaisesRegex(evidence.EvidenceError, "every fifth"):
            evidence.validate_request(malformed)

    def test_mapper_cadence_is_derived_from_input_topology(self) -> None:
        cases = (
            ("ordered", evidence_request(
                category="object_orbit",
                input_kind="video",
                capture_traits=["ordered"],
            ), 4.0, 1),
            ("unordered", evidence_request(
                category="professional_photos",
                input_kind="photos",
                capture_traits=["unordered"],
            ), 1.1, 2),
            ("segmented", evidence_request(
                category="interior_walkthrough",
                input_kind="mixed",
                capture_traits=["segmented"],
            ), 1.1, 2),
        )
        for label, request, global_ratio, local_refinements in cases:
            with self.subTest(topology=label):
                configuration = request["candidate_run_configuration"]
                self.assertEqual(configuration["ba_global_frames_ratio"], global_ratio)
                self.assertEqual(configuration["ba_global_points_ratio"], global_ratio)
                self.assertEqual(configuration["ba_local_max_refinements"], local_refinements)
                self.assertEqual(configuration["ba_local_max_num_iterations"], 10)
                self.assertEqual(configuration["ba_local_function_tolerance"], 0.001)
                self.assertEqual(configuration["ba_global_function_tolerance"], 0.000001)
                self.assertEqual(configuration["ba_local_num_images"], 6)
                evidence.validate_request(request)

    def test_mapper_cadence_request_fails_closed(self) -> None:
        mutations = (
            (
                "missing local cadence",
                lambda configuration: configuration.pop("ba_local_max_refinements"),
                "missing.*ba_local_max_refinements",
            ),
            (
                "nonpositive local cadence",
                lambda configuration: configuration.update({"ba_local_max_refinements": 0}),
                "ba_local_max_refinements.*positive integer",
            ),
            (
                "ordered conservative cadence",
                lambda configuration: configuration.update(
                    {
                        "ba_global_frames_ratio": 1.4,
                        "ba_global_points_ratio": 1.4,
                        "ba_local_max_refinements": 2,
                    }
                ),
                "continuous.*4.0.*local.*1",
            ),
            (
                "wrong local iteration limit",
                lambda configuration: configuration.update({"ba_local_max_num_iterations": 11}),
                "ba_local_max_num_iterations.*10",
            ),
            (
                "wrong local tolerance",
                lambda configuration: configuration.update({"ba_local_function_tolerance": 0.002}),
                "ba_local_function_tolerance.*0.001",
            ),
            (
                "wrong global tolerance",
                lambda configuration: configuration.update({"ba_global_function_tolerance": 0.000002}),
                "ba_global_function_tolerance.*1e-06",
            ),
            (
                "wrong local image count",
                lambda configuration: configuration.update({"ba_local_num_images": 7}),
                "ba_local_num_images.*6",
            ),
        )
        for label, mutate, expected in mutations:
            request = evidence_request()
            configuration = request["candidate_run_configuration"]
            configuration["ba_global_frames_ratio"] = 4.0
            configuration["ba_global_points_ratio"] = 4.0
            configuration["ba_local_max_refinements"] = 1
            mutate(configuration)
            with self.subTest(case=label), self.assertRaisesRegex(
                evidence.EvidenceError,
                expected,
            ):
                evidence.validate_request(request)

    def test_evidence_schema_rejects_topology_mismatched_mapper_cadence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, attestation = self.produce(Path(directory), evidence.LANE_REFERENCE)
        attestation["candidate_run_configuration"].update(
            {
                "ba_global_frames_ratio": 1.1,
                "ba_global_points_ratio": 1.1,
                "ba_local_max_refinements": 2,
            }
        )
        with self.assertRaises(ValidationError):
            validate_attestation_schema(attestation)

    def test_unordered_mapper_cadence_rejects_ordered_values(self) -> None:
        request = evidence_request(
            category="professional_photos",
            input_kind="photos",
            capture_traits=["unordered"],
        )
        request["candidate_run_configuration"].update(
            {
                "ba_global_frames_ratio": 4.0,
                "ba_global_points_ratio": 4.0,
                "ba_local_max_refinements": 1,
            }
        )
        with self.assertRaisesRegex(
            evidence.EvidenceError,
            "unordered.*1.1.*local.*2",
        ):
            evidence.validate_request(request)

    def test_continuous_mapper_invocations_accept_fast_or_recovered_shape(self) -> None:
        request = evidence_request()
        for variant in ("candidate", "fast_candidate"):
            for fallback in (False, True):
                with self.subTest(variant=variant, fallback=fallback):
                    evidence._validate_mapper_invocations(
                        mapper_invocations_for_variant(
                            variant,
                            request,
                            fallback=fallback,
                        ),
                        variant,
                        request,
                        valid_outcome=True,
                    )

    def test_continuous_mapper_invocations_accept_repeated_graph_recovery(self) -> None:
        request = evidence_request()
        fast_rejected = mapper_invocation(
            "candidate",
            (4.0, 4.0, 5, 1),
            "rejected_geometry_gate",
            matching_attempt=1,
            digest_character="a",
            descriptor_matcher="faiss",
        )
        same_graph_rejected = mapper_invocation(
            "candidate",
            (1.4, 1.4, 5, 2),
            "rejected_geometry_gate",
            matching_attempt=1,
            digest_character="a",
            descriptor_matcher="faiss",
        )
        denser_faiss_accepted = mapper_invocation(
            "candidate",
            (1.4, 1.4, 5, 2),
            "accepted",
            matching_attempt=2,
            digest_character="b",
            descriptor_matcher="faiss",
        )
        evidence._validate_mapper_invocations(
            [fast_rejected, same_graph_rejected, denser_faiss_accepted],
            "candidate",
            request,
            valid_outcome=True,
        )

    def test_first_mapper_invocation_accepts_proven_exact_matching_recovery(self) -> None:
        cases = (
            ("continuous", evidence_request(), (4.0, 4.0, 5, 1)),
            (
                "segmented_mixed",
                evidence_request(
                    category="interior_walkthrough",
                    input_kind="mixed",
                    capture_traits=["segmented"],
                ),
                (1.1, 1.1, 5, 2),
            ),
            (
                "unordered",
                evidence_request(
                    category="professional_photos",
                    input_kind="photos",
                    capture_traits=["unordered"],
                ),
                (1.1, 1.1, 5, 2),
            ),
        )
        for topology, request, cadence in cases:
            with self.subTest(topology=topology):
                evidence._validate_mapper_invocations(
                    [
                        mapper_invocation(
                            "candidate",
                            cadence,
                            "accepted",
                            matching_attempt=2,
                            digest_character="a",
                            descriptor_matcher="exact",
                        )
                    ],
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_first_mapper_invocation_rejects_unproven_exact_matching(self) -> None:
        cases = (
            ("continuous", evidence_request(), (4.0, 4.0, 5, 1)),
            (
                "segmented_mixed",
                evidence_request(
                    category="interior_walkthrough",
                    input_kind="mixed",
                    capture_traits=["segmented"],
                ),
                (1.1, 1.1, 5, 2),
            ),
            (
                "unordered",
                evidence_request(
                    category="professional_photos",
                    input_kind="photos",
                    capture_traits=["unordered"],
                ),
                (1.1, 1.1, 5, 2),
            ),
        )
        for topology, request, cadence in cases:
            with self.subTest(topology=topology), self.assertRaisesRegex(
                evidence.EvidenceError,
                "exact.*prior FAISS",
            ):
                evidence._validate_mapper_invocations(
                    [
                        mapper_invocation(
                            "candidate",
                            cadence,
                            "accepted",
                            matching_attempt=1,
                            digest_character="a",
                            descriptor_matcher="exact",
                        )
                    ],
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_continuous_mapper_invocations_accept_exact_retry_of_same_pair_list(self) -> None:
        request = evidence_request()
        invocations = [
            mapper_invocation(
                "candidate",
                (4.0, 4.0, 5, 1),
                "rejected_geometry_gate",
                matching_attempt=1,
                digest_character="a",
                descriptor_matcher="faiss",
            ),
            mapper_invocation(
                "candidate",
                (1.4, 1.4, 5, 2),
                "rejected_geometry_gate",
                matching_attempt=1,
                digest_character="a",
                descriptor_matcher="faiss",
            ),
            mapper_invocation(
                "candidate",
                (1.4, 1.4, 5, 2),
                "rejected_geometry_gate",
                matching_attempt=2,
                digest_character="b",
                descriptor_matcher="faiss",
            ),
            mapper_invocation(
                "candidate",
                (1.4, 1.4, 5, 2),
                "accepted",
                matching_attempt=3,
                digest_character="b",
                descriptor_matcher="exact",
            ),
        ]
        evidence._validate_mapper_invocations(
            invocations,
            "candidate",
            request,
            valid_outcome=True,
        )

    def test_mapper_execution_receipt_cannot_omit_mapper_invocations(self) -> None:
        request = evidence_request()
        observations = raw_observations(evidence.LANE_REFERENCE)
        next(
            receipt for receipt in observations["commands"]
            if receipt["variant"] == "candidate"
        ).pop("mapper_invocations")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations, request)
            with self.assertRaisesRegex(
                evidence.EvidenceError,
                "missing mapper_invocations",
            ):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_continuous_mapper_invocation_shapes_fail_closed(self) -> None:
        request = evidence_request()
        fast = mapper_invocations_for_variant("candidate", request)
        recovered = mapper_invocations_for_variant("candidate", request, fallback=True)
        conservative = mapper_invocation(
            "candidate",
            (1.4, 1.4, 5, 2),
            "accepted",
            matching_attempt=1,
            digest_character="a",
            descriptor_matcher="faiss",
        )
        cases = (
            ("fallback missing accepted second", recovered[:1], "exactly one accepted"),
            (
                "accepted fast followed by extra retry",
                [*fast, {**conservative, "outcome": "rejected_geometry_gate"}],
                "accepted.*last",
            ),
            ("conservative only", [conservative], "fast 4.0/1"),
        )
        for label, invocations, expected in cases:
            with self.subTest(case=label), self.assertRaisesRegex(
                evidence.EvidenceError,
                expected,
            ):
                evidence._validate_mapper_invocations(
                    invocations,
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_candidate_mapper_invocation_cadence_arguments_fail_closed(self) -> None:
        request = evidence_request()
        option = "--Mapper.ba_global_frames_ratio"
        cases = {}
        missing = mapper_invocations_for_variant("candidate", request)
        index = missing[0]["argv"].index(option)
        del missing[0]["argv"][index : index + 2]
        cases["missing"] = missing
        duplicate = mapper_invocations_for_variant("candidate", request)
        duplicate[0]["argv"].extend((option, "4.0"))
        cases["duplicate"] = duplicate
        equals = mapper_invocations_for_variant("candidate", request)
        index = equals[0]["argv"].index(option)
        equals[0]["argv"][index : index + 2] = [f"{option}=4.0"]
        cases["equals"] = equals
        for label, invocations in cases.items():
            with self.subTest(case=label), self.assertRaisesRegex(
                evidence.EvidenceError,
                "cadence.*ba_global_frames_ratio",
            ):
                evidence._validate_mapper_invocations(
                    invocations,
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_candidate_mapper_invocation_requires_promoted_convergence_arguments(self) -> None:
        request = evidence_request()
        for option in (
            "--Mapper.ba_local_max_num_iterations",
            "--Mapper.ba_local_function_tolerance",
            "--Mapper.ba_global_function_tolerance",
            "--Mapper.ba_local_num_images",
        ):
            invocations = mapper_invocations_for_variant("candidate", request)
            index = invocations[0]["argv"].index(option)
            del invocations[0]["argv"][index : index + 2]
            with self.subTest(option=option), self.assertRaisesRegex(
                evidence.EvidenceError,
                option.removeprefix("--Mapper."),
            ):
                evidence._validate_mapper_invocations(
                    invocations,
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_mapper_invocation_requires_the_canonical_colmap_executable(self) -> None:
        request = evidence_request()
        for executable in (
            "toolchain://resolved/bin/not-colmap",
            "toolchain://spoof/resolved/bin/colmap",
        ):
            invocations = mapper_invocations_for_variant("candidate", request)
            invocations[0]["argv"][0] = executable
            with self.subTest(executable=executable), self.assertRaisesRegex(
                evidence.EvidenceError,
                "canonical.*COLMAP",
            ):
                evidence._validate_mapper_invocations(
                    invocations,
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_accurate_reference_mapper_receipt_rejects_production_cadence_options(self) -> None:
        request = evidence_request()
        options = (
            "--Mapper.ba_global_frames_ratio",
            "--Mapper.ba_global_points_ratio",
            "--Mapper.ba_global_max_refinements",
            "--Mapper.ba_local_max_refinements",
            "--Mapper.ba_local_max_num_iterations",
            "--Mapper.ba_local_function_tolerance",
            "--Mapper.ba_global_function_tolerance",
            "--Mapper.ba_local_num_images",
        )
        for option in options:
            for form in ("split", "equals"):
                invocations = mapper_invocations_for_variant("accurate_reference", request)
                argv = invocations[0]["argv"]
                if form == "split":
                    argv.extend((option, "1"))
                else:
                    argv.append(f"{option}=1")
                with self.subTest(option=option, form=form), self.assertRaisesRegex(
                    evidence.EvidenceError,
                    "accurate_reference.*production cadence",
                ):
                    evidence._validate_mapper_invocations(
                        invocations,
                        "accurate_reference",
                        request,
                        valid_outcome=True,
                    )

    def test_baseline_mapper_receipt_uses_frozen_implicit_defaults(self) -> None:
        request = evidence_request()
        baseline = next(
            receipt for receipt in execution_receipts(
                paired_timing(), evidence.LANE_REFERENCE, request
            )
            if receipt["variant"] == "baseline"
        )
        self.assertEqual(
            baseline["mapper_invocations"],
            [
                {
                    "argv": ["baseline-toolchain://resolved/bin/colmap", "mapper"],
                    "outcome": "accepted",
                    "matching_attempt": 1,
                    "pair_list_digest": "sha256:" + "b" * 64,
                    "descriptor_matcher": "exact",
                }
            ],
        )
        self.assertEqual(request["baseline_run_configuration"]["ba_global_frames_ratio"], 1.1)
        self.assertEqual(request["baseline_run_configuration"]["ba_global_points_ratio"], 1.1)
        self.assertEqual(request["baseline_run_configuration"]["ba_global_max_refinements"], 5)
        self.assertEqual(request["baseline_run_configuration"]["ba_local_max_refinements"], 2)

    def test_unordered_mapper_invocations_accept_denser_recovery_attempt(self) -> None:
        request = evidence_request(
            category="professional_photos",
            input_kind="photos",
            capture_traits=["unordered"],
        )
        invocations = mapper_invocations_for_variant("candidate", request)
        invocations[0]["outcome"] = "rejected_geometry_gate"
        invocations.append(
            mapper_invocation(
                "candidate",
                (1.1, 1.1, 5, 2),
                "accepted",
                matching_attempt=2,
                digest_character="b",
                descriptor_matcher="faiss",
            )
        )
        evidence._validate_mapper_invocations(
            invocations,
            "candidate",
            request,
            valid_outcome=True,
        )

    def test_candidate_mapper_recovery_graph_identity_fails_closed(self) -> None:
        request = evidence_request()
        fast_rejected = mapper_invocation(
            "candidate",
            (4.0, 4.0, 5, 1),
            "rejected_geometry_gate",
            matching_attempt=1,
            digest_character="a",
            descriptor_matcher="faiss",
        )
        same_graph_rejected = mapper_invocation(
            "candidate",
            (1.4, 1.4, 5, 2),
            "rejected_geometry_gate",
            matching_attempt=1,
            digest_character="a",
            descriptor_matcher="faiss",
        )
        cases = {
            "repeated conservative graph": [
                fast_rejected,
                same_graph_rejected,
                mapper_invocation(
                    "candidate",
                    (1.4, 1.4, 5, 2),
                    "accepted",
                    matching_attempt=1,
                    digest_character="a",
                    descriptor_matcher="faiss",
                ),
            ],
            "equal rematch attempt": [
                fast_rejected,
                same_graph_rejected,
                mapper_invocation(
                    "candidate",
                    (1.4, 1.4, 5, 2),
                    "accepted",
                    matching_attempt=1,
                    digest_character="b",
                    descriptor_matcher="faiss",
                ),
            ],
            "decreasing rematch attempt": [
                mapper_invocation(
                    "candidate",
                    (4.0, 4.0, 5, 1),
                    "rejected_geometry_gate",
                    matching_attempt=2,
                    digest_character="a",
                    descriptor_matcher="faiss",
                ),
                mapper_invocation(
                    "candidate",
                    (1.4, 1.4, 5, 2),
                    "rejected_geometry_gate",
                    matching_attempt=2,
                    digest_character="a",
                    descriptor_matcher="faiss",
                ),
                mapper_invocation(
                    "candidate",
                    (1.4, 1.4, 5, 2),
                    "accepted",
                    matching_attempt=1,
                    digest_character="b",
                    descriptor_matcher="faiss",
                ),
            ],
            "exact back to faiss": [
                fast_rejected,
                same_graph_rejected,
                mapper_invocation(
                    "candidate",
                    (1.4, 1.4, 5, 2),
                    "rejected_geometry_gate",
                    matching_attempt=2,
                    digest_character="b",
                    descriptor_matcher="exact",
                ),
                mapper_invocation(
                    "candidate",
                    (1.4, 1.4, 5, 2),
                    "accepted",
                    matching_attempt=3,
                    digest_character="c",
                    descriptor_matcher="faiss",
                ),
            ],
        }
        for label, invocations in cases.items():
            with self.subTest(case=label), self.assertRaises(evidence.EvidenceError):
                evidence._validate_mapper_invocations(
                    invocations,
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_mapper_invocation_graph_identity_fields_fail_closed(self) -> None:
        request = evidence_request()
        cases = {}
        missing = mapper_invocations_for_variant("candidate", request)
        missing[0].pop("matching_attempt")
        cases["missing"] = missing
        non_positive = mapper_invocations_for_variant("candidate", request)
        non_positive[0]["matching_attempt"] = 0
        cases["non-positive attempt"] = non_positive
        invalid_digest = mapper_invocations_for_variant("candidate", request)
        invalid_digest[0]["pair_list_digest"] = "sha256:not-a-digest"
        cases["invalid digest"] = invalid_digest
        invalid_matcher = mapper_invocations_for_variant("candidate", request)
        invalid_matcher[0]["descriptor_matcher"] = "flann"
        cases["invalid matcher"] = invalid_matcher
        for label, invocations in cases.items():
            with self.subTest(case=label), self.assertRaises(evidence.EvidenceError):
                evidence._validate_mapper_invocations(
                    invocations,
                    "candidate",
                    request,
                    valid_outcome=True,
                )

    def test_evidence_schema_accepts_unbounded_mapper_retries_with_graph_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, attestation = self.produce(Path(directory), evidence.LANE_REFERENCE)
        candidate = next(
            receipt for receipt in attestation["commands"]
            if receipt["variant"] == "candidate"
        )
        candidate["mapper_invocations"] = [
            mapper_invocation(
                "candidate",
                (4.0, 4.0, 5, 1),
                "rejected_geometry_gate",
                matching_attempt=1,
                digest_character="a",
                descriptor_matcher="faiss",
            ),
            mapper_invocation(
                "candidate",
                (1.4, 1.4, 5, 2),
                "rejected_geometry_gate",
                matching_attempt=1,
                digest_character="a",
                descriptor_matcher="faiss",
            ),
            mapper_invocation(
                "candidate",
                (1.4, 1.4, 5, 2),
                "accepted",
                matching_attempt=2,
                digest_character="b",
                descriptor_matcher="faiss",
            ),
        ]
        validate_attestation_schema(attestation)

    def test_evidence_schema_rejects_missing_or_invalid_mapper_graph_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, attestation = self.produce(Path(directory), evidence.LANE_REFERENCE)
        cases = {
            "missing": lambda item: item.pop("matching_attempt"),
            "non-positive attempt": lambda item: item.update(matching_attempt=0),
            "invalid digest": lambda item: item.update(pair_list_digest="sha256:no"),
            "invalid matcher": lambda item: item.update(descriptor_matcher="flann"),
        }
        for label, mutate in cases.items():
            invalid = json.loads(json.dumps(attestation))
            invalid_candidate = next(
                receipt for receipt in invalid["commands"]
                if receipt["variant"] == "candidate"
            )
            mutate(invalid_candidate["mapper_invocations"][0])
            with self.subTest(case=label), self.assertRaises(ValidationError):
                validate_attestation_schema(invalid)

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

    def test_orientation_physical_up_error_is_gated(self) -> None:
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
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
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
            attestation = evidence.derive_attestation(
                request,
                observations,
                root,
                root / "attestation.json",
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

    def test_orientation_pipeline_claims_require_the_reference_scene_quality_lane(self) -> None:
        observations = raw_observations(evidence.LANE_CONSTRAINED)
        observations["pipeline_metrics"].update(
            {
                "orientation_status": "verified",
                "orientation_physical_up_error_degrees": 0.75,
                "orientation_sign_correct": True,
            }
        )
        request = evidence_request(lane=evidence.LANE_CONSTRAINED)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(
                evidence.EvidenceError,
                "orientation pipeline metrics require reference scene_quality evidence",
            ):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_CONSTRAINED,
                    runner_identity(evidence.LANE_CONSTRAINED),
                    machine=evidence_machine(evidence.LANE_CONSTRAINED),
                )

    def test_orientation_artifacts_require_the_reference_scene_quality_lane(self) -> None:
        observations = raw_observations(evidence.LANE_CONSTRAINED)
        observations["artifacts"]["orientation_metrics"] = "orientation-metrics.json"
        request = evidence_request(lane=evidence.LANE_CONSTRAINED)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            (root / "orientation-metrics.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(
                evidence.EvidenceError,
                "orientation artifacts require reference scene_quality evidence",
            ):
                evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_CONSTRAINED,
                    runner_identity(evidence.LANE_CONSTRAINED),
                    machine=evidence_machine(evidence.LANE_CONSTRAINED),
                )

    def test_baseline_observations_must_match_the_bound_request(self) -> None:
        observations = raw_observations(evidence.LANE_REFERENCE)
        observations["baseline"]["git_commit"] = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_evidence_artifacts(root, observations)
            with self.assertRaisesRegex(evidence.EvidenceError, "baseline"):
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
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
                evidence.derive_attestation(
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_runner_or_artifact_tampering_breaks_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output, attestation = self.produce(root, evidence.LANE_REFERENCE)
            changed = json.loads(json.dumps(attestation))
            changed["measurement_runner"]["sha256"] = "sha256:" + "f" * 64
            output.write_bytes(evidence.canonical_json_bytes(changed) + b"\n")
            with self.assertRaisesRegex(evidence.EvidenceError, "approved request index"):
                evidence.validate_prepared_attestation_file(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                )
            changed = json.loads(json.dumps(attestation))
            del changed["measurement_runner"]
            output.write_bytes(evidence.canonical_json_bytes(changed) + b"\n")
            with self.assertRaisesRegex(evidence.EvidenceError, "missing measurement_runner"):
                evidence.validate_prepared_attestation_file(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
                    runner_identity(evidence.LANE_REFERENCE),
                )
            output.write_bytes(evidence.canonical_json_bytes(attestation) + b"\n")
            (root / "splat.ply").write_text("ply\nchanged\n", encoding="utf-8")
            with self.assertRaisesRegex(evidence.EvidenceError, "mismatch"):
                evidence.validate_prepared_attestation_file(
                    output,
                    evidence_request(),
                    evidence.LANE_REFERENCE,
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
                evidence.derive_attestation(
                    evidence_request(lane=evidence.LANE_CONSTRAINED),
                    observations,
                    root,
                    root / "attestation.json",
                    evidence.LANE_CONSTRAINED,
                    runner_identity(evidence.LANE_CONSTRAINED),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_reference_lane_requires_the_approved_48_gib_machine(self) -> None:
        machine = evidence_machine(evidence.LANE_REFERENCE)
        machine["physical_memory_bytes"] = 64 * 1024**3
        with self.assertRaisesRegex(evidence.EvidenceError, "exactly 48 GiB"):
            evidence.validate_machine_lane(machine, evidence.LANE_REFERENCE)

    def test_release_evidence_requires_xcode_16_4(self) -> None:
        for lane in (
            evidence.LANE_REFERENCE,
            evidence.LANE_CONSTRAINED,
            evidence.LANE_EIGHT_GB,
        ):
            with self.subTest(lane=lane):
                machine = evidence_machine(lane)
                machine["xcode_version"] = "Xcode 16.3\nBuild version 16E140"
                with self.assertRaisesRegex(evidence.EvidenceError, "Xcode 16.4"):
                    evidence.validate_machine_lane(machine, lane)

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

    def test_protected_low_memory_lanes_gate_the_larger_of_rss_and_metal(self) -> None:
        scene = valid_scene()
        scene["gate_scopes"] = ["scene_performance"]

        reference_metrics = passing_metrics()
        reference_metrics["memory_lane"] = measured("larger")
        reference_metrics["machine_memory_bytes"] = measured(
            evidence_machine(evidence.LANE_REFERENCE)["physical_memory_bytes"]
        )
        reference = {
            "actual": successful_actual(),
            "metrics": reference_metrics,
            "machine": evidence_machine(evidence.LANE_REFERENCE),
        }
        for lane, memory_lane, rss, metal in (
            (evidence.LANE_CONSTRAINED, "constrained", 1_000_000_000, 12_000_000_001),
            (evidence.LANE_EIGHT_GB, "eight_gb_fast", 1_000_000_000, 6_500_000_001),
        ):
            with self.subTest(lane=lane):
                attestation = {
                    "actual": successful_actual(),
                    "metrics": {
                        "memory_lane": measured(memory_lane),
                        "machine_memory_bytes": measured(
                            evidence_machine(lane)["physical_memory_bytes"]
                        ),
                        "peak_memory_bytes": measured(rss),
                        "peak_metal_allocated_bytes": measured(metal),
                    },
                    "machine": evidence_machine(lane),
                }
                evaluation, _ = benchmark._evaluate_protected_attestations(
                    scene,
                    30,
                    {
                        evidence.LANE_REFERENCE: reference,
                        lane: attestation,
                    },
                )
                self.assertEqual(evaluation["status"], "failed")
                self.assertTrue(
                    any("unified memory" in failure for failure in evaluation["failures"])
                )

                del attestation["metrics"]["peak_metal_allocated_bytes"]
                evaluation, _ = benchmark._evaluate_protected_attestations(
                    scene,
                    30,
                    {
                        evidence.LANE_REFERENCE: reference,
                        lane: attestation,
                    },
                )
                self.assertEqual(evaluation["status"], "blocked")
                self.assertTrue(
                    any(
                        "peak_metal_allocated_bytes" in reason
                        for reason in evaluation["blocking_reasons"]
                    )
                )

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
                attestation = evidence.derive_attestation(
                    evidence_request(lane=lane),
                    observations,
                    root,
                    root / "attestation.json",
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
                runner_identities(),
                "sha256:" + "9" * 64,
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
                wrong_index_identities,
                "sha256:" + "9" * 64,
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
                runner_identities(),
                "sha256:" + "9" * 64,
            )
            self.assertEqual(rejected["status"], "blocked")
            self.assertEqual(rejected["failures"], [])
            self.assertTrue(
                any("constrained" in item for item in rejected["blocking_reasons"])
            )
            missing_attestation = scale_root / evidence.LANE_CONSTRAINED / "attestation.json"
            missing_attestation.write_text("not-json\n", encoding="utf-8")
            malformed = benchmark._copy_protected_evidence(
                scene,
                30,
                corpus_root,
                identity,
                "sha256:" + "1" * 64,
                runner_identities(),
                "sha256:" + "9" * 64,
            )
            self.assertEqual(malformed["status"], "failed")
            self.assertTrue(any("constrained" in item for item in malformed["failures"]))
            missing_attestation.unlink()
            missing_attestation.symlink_to("absent-attestation.json")
            unsafe = benchmark._copy_protected_evidence(
                scene,
                30,
                corpus_root,
                identity,
                "sha256:" + "1" * 64,
                runner_identities(),
                "sha256:" + "9" * 64,
            )
            self.assertEqual(unsafe["status"], "failed")
            self.assertTrue(any("unsafe" in item for item in unsafe["failures"]))

    def test_protected_evidence_classifies_prepared_lane_outcomes(self) -> None:
        scene = valid_scene(adapter="protected-evidence")
        scene["scale_lanes"] = [250]
        scene["aggregate_scale"] = 250
        scene["split"]["holdout_by_scale"] = {"250": list(range(4, 250, 5))}
        pinned_reference = next(iter(scene["reference"]["by_scale"].values()))
        scene["reference"]["by_scale"] = {"250": pinned_reference}
        scene["gate_scopes"] = evidence_request(scale=250)["gate_scopes"]
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest="sha256:" + "2" * 64,
            thresholds_digest="sha256:" + "3" * 64,
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity=TEST_TOOLCHAIN_IDENTITY,
        )
        input_digest = "sha256:" + "1" * 64
        identities = runner_identities()
        lane = evidence.LANE_REFERENCE
        request = benchmark._evidence_request(
            scene,
            250,
            lane,
            identity,
            input_digest,
            identities[evidence.RENDERING_DRIVER_IDENTITY],
            "sha256:" + "9" * 64,
        )

        for case in (
            "execution",
            "environment",
            "infrastructure",
            "extra_field",
            "both",
            "neither",
            "symlinked_parent",
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                corpus_root = Path(directory) / "corpus"
                lane_root = (
                    corpus_root
                    / scene["adapter"]["evidence_path"]
                    / "250"
                    / lane
                )
                if case == "symlinked_parent":
                    outside = Path(directory) / "outside"
                    outside.mkdir(parents=True)
                    lane_root.parent.mkdir(parents=True)
                    lane_root.symlink_to(outside, target_is_directory=True)
                    receipt_root = outside
                else:
                    lane_root.mkdir(parents=True)
                    receipt_root = lane_root

                if case != "neither":
                    if case == "environment":
                        observations = raw_observations(lane)
                        (receipt_root / "host-monitor.json").write_bytes(
                            FIXTURE_HOST_MONITOR
                        )
                        environment = supervisor_run(observations)[
                            "measurement_environment"
                        ]
                        environment["low_power_mode_observed"] = True
                        commands = [
                            {
                                "run_id": command["run_id"],
                                "started_monotonic_seconds": command[
                                    "started_monotonic_seconds"
                                ],
                                "ended_monotonic_seconds": command[
                                    "ended_monotonic_seconds"
                                ],
                                "process_cpu_microseconds": command[
                                    "process_cpu_microseconds"
                                ],
                            }
                            for command in observations["commands"]
                        ]
                        environment_path = receipt_root / "measurement-environment.json"
                        environment_path.write_bytes(
                            evidence.canonical_json_bytes(
                                {
                                    "schema_version": 1,
                                    "started_monotonic_seconds": min(
                                        command["started_monotonic_seconds"]
                                        for command in commands
                                    ),
                                    "ended_monotonic_seconds": max(
                                        command["ended_monotonic_seconds"]
                                        for command in commands
                                    )
                                    + 1.0,
                                    "commands": commands,
                                    "measurement_environment": environment,
                                }
                            )
                            + b"\n"
                        )
                        receipt = evidence.derive_lane_outcome(
                            request,
                            lane,
                            identities[lane],
                            evidence_machine(lane),
                            kind="environment_rejected",
                            reason="policy_violation",
                            exit_code=0,
                            environment_receipt_path=environment_path,
                        )
                    elif case == "infrastructure":
                        receipt = evidence.derive_lane_outcome(
                            request,
                            lane,
                            identities[lane],
                            evidence_machine(lane),
                            kind="infrastructure_blocked",
                            reason="host_monitor_failed",
                            exit_code=0,
                        )
                    else:
                        receipt = evidence.derive_lane_outcome(
                            request,
                            lane,
                            identities[lane],
                            evidence_machine(lane),
                            kind="execution_failed",
                            reason="nonzero_exit",
                            exit_code=23,
                        )
                    if case == "extra_field":
                        receipt["unexpected"] = True
                    (receipt_root / "lane-outcome.json").write_bytes(
                        evidence.canonical_json_bytes(receipt) + b"\n"
                    )
                    if case == "both":
                        (receipt_root / "attestation.json").write_text(
                            "{}\n",
                            encoding="utf-8",
                        )

                result = benchmark._copy_protected_evidence(
                    scene,
                    250,
                    corpus_root,
                    identity,
                    input_digest,
                    identities,
                    "sha256:" + "9" * 64,
                )
                expected_status = (
                    "blocked"
                    if case in {"environment", "infrastructure", "neither"}
                    else "failed"
                )
                self.assertEqual(result["status"], expected_status)
                if case in {"environment", "infrastructure"}:
                    self.assertEqual(result["failures"], [])
                    self.assertTrue(result["blocking_reasons"])
                elif case == "neither":
                    self.assertEqual(result["failures"], [])
                    self.assertTrue(result["blocking_reasons"])
                else:
                    self.assertTrue(result["failures"])
                    if case == "symlinked_parent":
                        self.assertTrue(
                            any("unsafe parent" in failure for failure in result["failures"])
                        )

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
                    "resolved_public_beta_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(
                    benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(benchmark, "make_run_identity", return_value=identity),
                mock.patch.object(
                    benchmark,
                    "validate_tracked_benchmark_contract",
                    return_value="sha256:" + "9" * 64,
                ),
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
                lane = item["lane"]
                self.assertEqual(
                    item["producer_command"],
                    [
                        "python3",
                        "scripts/benchmark/prepare_evidence.py",
                        "--index",
                        "requests://index.json",
                        "--requests-root",
                        "requests://",
                        "--raw-evidence-root",
                        f"evidence://raw/{lane}",
                        "--output-root",
                        f"evidence://prepared/{lane}",
                        "--lane",
                        lane,
                    ],
                )
            missing_identity_index = json.loads(json.dumps(index))
            del missing_identity_index["runner_identities"][evidence.LANE_EIGHT_GB]
            with (
                mock.patch.object(
                    benchmark,
                    "benchmark_contract_sha256",
                    return_value="sha256:" + "9" * 64,
                ),
                self.assertRaisesRegex(benchmark.ConfigError, "runner identities"),
            ):
                benchmark.validate_request_index(
                    missing_identity_index,
                    identity,
                    corpus,
                    valid_reference_config(),
                )

    def test_lane_orchestrator_collects_raw_outputs_without_signing(self) -> None:
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
                benchmark.benchmark_contract_sha256(corpus),
            )
            requests_root = root / "requests"
            request_relative = Path("orbit-01/120/constrained_14_16gb.request.json")
            (requests_root / request_relative).parent.mkdir(parents=True)
            (requests_root / request_relative).write_bytes(
                benchmark.canonical_json_bytes(request) + b"\n"
            )
            (requests_root / "corpus.json").write_bytes(
                benchmark.canonical_json_bytes(corpus) + b"\n"
            )
            (requests_root / "reference-config.json").write_bytes(
                benchmark.canonical_json_bytes(config) + b"\n"
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
                "benchmark_contract_sha256": benchmark.benchmark_contract_sha256(
                    corpus
                ),
                "corpus_manifest": "corpus.json",
                "corpus_manifest_sha256": evidence.sha256_file(
                    requests_root / "corpus.json"
                ),
                "reference_config": "reference-config.json",
                "reference_config_sha256": evidence.sha256_file(
                    requests_root / "reference-config.json"
                ),
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
            training_manifest = training_manifest_for_observations(
                observations,
                request["candidate_run_configuration"],
            )
            training_manifest["elapsedSeconds"] = 0.0005
            (source / "training-manifest.json").write_bytes(
                evidence.canonical_json_bytes(training_manifest) + b"\n"
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
                "shutil.copy2(source/'splat.ply', root/'splat.ply')\n"
                "shutil.copy2(source/'training-manifest.json', root/'training-manifest.json')\n",
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
            baseline_checkout = root / "baseline-checkout"
            baseline_toolchain = root / "baseline-toolchain"
            host_states = supervisor_run(observations)["measurement_environment"]
            environment_events: list[str] = []
            monitor_report = host_monitor_report(
                [
                    (0.0, host_state(user=1_000, system=0, idle=9_000)),
                    (1.0, host_state(user=1_050, system=0, idle=9_950)),
                ]
            )

            def start_host_monitor(*_: object) -> object:
                environment_events.append("host-start")
                return object()

            def finish_host_monitor(_: object) -> dict[str, object]:
                environment_events.append("host-end")
                return monitor_report

            def summarize_host_monitor(
                _: object,
                __: object,
                ___: object,
                **values: object,
            ) -> dict[str, object]:
                summary = json.loads(json.dumps(host_states))
                summary["monitor_sha256"] = values["monitor_sha256"]
                summary["monitor_executable_sha256"] = values[
                    "monitor_executable_sha256"
                ]
                return summary

            def children_cpu_seconds() -> dict[str, float]:
                environment_events.append("child-cpu")
                return {"user": 0.0, "system": 0.0}

            def artifact_root(output: Path) -> Path:
                return (
                    output
                    / scene["adapter"]["evidence_path"]
                    / "120"
                    / evidence.LANE_CONSTRAINED
                )

            def assert_collector_status(
                output: Path,
                *,
                kind: str | None,
                stage: str | None = None,
                reason: str | None = None,
                exit_code: int | None = None,
                expected_runner: dict[str, str] | None = None,
            ) -> dict[str, object]:
                root_path = artifact_root(output)
                status_path = root_path / "collector-status.json"
                self.assertTrue(status_path.is_file())
                self.assertFalse((root_path / "attestation.json").exists())
                self.assertFalse((root_path / "lane-outcome.json").exists())
                status = json.loads(status_path.read_text(encoding="utf-8"))
                self.assertEqual(
                    set(status),
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
                )
                self.assertEqual(status["schema_version"], 1)
                self.assertEqual(
                    status["request_sha256"],
                    evidence.sha256_bytes(evidence.canonical_json_bytes(request)),
                )
                self.assertEqual(status["lane"], evidence.LANE_CONSTRAINED)
                self.assertEqual(
                    status["machine"],
                    evidence_machine(evidence.LANE_CONSTRAINED),
                )
                self.assertEqual(
                    status["measurement_runner"],
                    expected_runner
                    or approved_runners[evidence.LANE_CONSTRAINED],
                )
                self.assertEqual(
                    status["collector"],
                    {
                        "protocol_version": evidence.PROTOCOL_VERSION,
                        "version": lane_runner._COLLECTOR_VERSION,
                        "executable": lane_runner._COLLECTOR_RELATIVE_PATH,
                        "sha256": evidence.sha256_file(Path(lane_runner.__file__).resolve()),
                    },
                )
                if kind is None:
                    self.assertEqual(status["disposition"], "attestation_candidate")
                    self.assertIsNone(status["outcome"])
                else:
                    self.assertEqual(status["disposition"], "lane_outcome")
                    self.assertEqual(
                        status["outcome"],
                        {
                            "kind": kind,
                            "stage": stage,
                            "reason": reason,
                            "exit_code": exit_code,
                        },
                    )
                return status

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
                mock.patch.object(
                    lane_runner,
                    "_start_host_monitor",
                    side_effect=start_host_monitor,
                ),
                mock.patch.object(
                    lane_runner,
                    "_finish_host_monitor",
                    side_effect=finish_host_monitor,
                ),
                mock.patch.object(
                    lane_runner,
                    "_summarize_host_monitor",
                    side_effect=summarize_host_monitor,
                ),
                mock.patch.object(
                    lane_runner,
                    "_children_cpu_seconds",
                    side_effect=children_cpu_seconds,
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
                )
            self.assertEqual(len(result["collections"]), 1)
            self.assertEqual(
                environment_events,
                ["child-cpu", "host-start", "child-cpu", "host-end"],
            )
            successful_status = assert_collector_status(
                root / "evidence",
                kind=None,
            )
            collection = result["collections"][0]
            self.assertEqual(
                set(collection),
                {"scene_id", "scale", "lane", "collector_status", "sha256"},
            )
            self.assertEqual(
                collection["sha256"],
                evidence.sha256_file(artifact_root(root / "evidence") / "collector-status.json"),
            )
            self.assertEqual(collection["scene_id"], scene["id"])
            self.assertEqual(collection["scale"], 120)
            self.assertEqual(collection["lane"], evidence.LANE_CONSTRAINED)
            self.assertEqual(successful_status["outcome"], None)

            for (
                case_name,
                outcome_kind,
                outcome_stage,
                outcome_reason,
                expected_exit_code,
                process_result,
                _message,
            ) in (
                (
                    "launch_failed",
                    "execution_failed",
                    "measurement_runner",
                    "launch_failed",
                    None,
                    OSError(2, "fixture launch failure"),
                    "could not start",
                ),
                (
                    "timed_out",
                    "execution_failed",
                    "measurement_runner",
                    "timed_out",
                    0,
                    (subprocess.CompletedProcess([], 0), True),
                    "timed out",
                ),
                (
                    "nonzero_exit",
                    "execution_failed",
                    "measurement_runner",
                    "nonzero_exit",
                    23,
                    (subprocess.CompletedProcess([], 23), False),
                    "with exit 23",
                ),
                (
                    "process_isolation_failed",
                    "execution_failed",
                    "measurement_runner",
                    "process_isolation_failed",
                    None,
                    lane_runner.benchmark.ConfigError("fixture process isolation failure"),
                    "process isolation failed",
                ),
                (
                    "renderer-integrity-before-monitor",
                    "execution_failed",
                    "measurement_runner",
                    "integrity_failed",
                    None,
                    (subprocess.CompletedProcess([], 0), False),
                    "integrity verification failed",
                ),
                (
                    "runner-integrity-after-process",
                    "execution_failed",
                    "measurement_runner",
                    "integrity_failed",
                    None,
                    (subprocess.CompletedProcess([], 0), False),
                    "integrity verification failed",
                ),
                (
                    "renderer-integrity-after-process",
                    "execution_failed",
                    "measurement_runner",
                    "integrity_failed",
                    None,
                    (subprocess.CompletedProcess([], 0), False),
                    "integrity verification failed",
                ),
                (
                    "host-monitor-start",
                    "infrastructure_blocked",
                    "host_monitor",
                    "host_monitor_failed",
                    None,
                    (subprocess.CompletedProcess([], 0), False),
                    "infrastructure failed",
                ),
                (
                    "host-monitor-finalization",
                    "infrastructure_blocked",
                    "host_monitor",
                    "host_monitor_failed",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "infrastructure failed",
                ),
                (
                    "host-monitor-summary",
                    "infrastructure_blocked",
                    "host_monitor",
                    "host_monitor_failed",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "infrastructure failed",
                ),
                (
                    "host-monitor-policy",
                    "infrastructure_blocked",
                    "host_monitor",
                    "host_monitor_failed",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "infrastructure failed",
                ),
                (
                    "postprocessing-failure",
                    "infrastructure_blocked",
                    "postprocessing",
                    "postprocessing_failed",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "infrastructure failed",
                ),
                (
                    "postprocess-integrity",
                    "execution_failed",
                    "measurement_runner",
                    "integrity_failed",
                    None,
                    (subprocess.CompletedProcess([], 0), False),
                    "integrity verification failed",
                ),
                (
                    "invalid-output-missing",
                    "execution_failed",
                    "measurement_runner",
                    "invalid_output",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "invalid output",
                ),
                (
                    "invalid-output-malformed",
                    "execution_failed",
                    "measurement_runner",
                    "invalid_output",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "invalid output",
                ),
                (
                    "invalid-output-oversized",
                    "execution_failed",
                    "measurement_runner",
                    "invalid_output",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "invalid output",
                ),
                (
                    "invalid-output-with-host-rejection",
                    "execution_failed",
                    "measurement_runner",
                    "invalid_output",
                    0,
                    (subprocess.CompletedProcess([], 0), False),
                    "invalid output",
                ),
            ):
                with self.subTest(outcome=case_name):
                    failure_output = root / f"evidence-{case_name}"

                    def run_failure(*arguments: object) -> object:
                        if isinstance(process_result, BaseException):
                            raise process_result
                        command = arguments[0]
                        assert isinstance(command, list)
                        failure_artifact_root = Path(
                            command[command.index("--artifact-root") + 1]
                        )
                        if case_name == "invalid-output-malformed":
                            (failure_artifact_root / "observations.json").write_bytes(
                                evidence.canonical_json_bytes(
                                    {
                                        "commands": [{"run_id": "broken"}],
                                        "artifacts": {},
                                    }
                                )
                                + b"\n"
                            )
                        elif case_name == "invalid-output-oversized":
                            with (failure_artifact_root / "observations.json").open("wb") as handle:
                                handle.truncate(evidence.MAX_OBSERVATIONS_BYTES + 1)
                        elif case_name in {
                            "invalid-output-with-host-rejection",
                            "host-monitor-summary",
                            "host-monitor-policy",
                            "postprocessing-failure",
                            "postprocess-integrity",
                        }:
                            shutil.copy2(
                                source / "observations.json",
                                failure_artifact_root / "observations.json",
                            )
                        return process_result

                    def finish_failure_monitor(*_: object) -> object:
                        if case_name in {"nonzero_exit", "host-monitor-finalization"}:
                            raise lane_runner.benchmark.ConfigError(
                                "fixture monitor finalization failure"
                            )
                        return monitor_report

                    def start_failure_monitor(*_: object) -> object:
                        if case_name == "host-monitor-start":
                            raise lane_runner.benchmark.ConfigError(
                                "fixture monitor startup failure"
                            )
                        return object()

                    def summarize_failure_monitor(*args: object, **kwargs: object) -> object:
                        if case_name == "host-monitor-summary":
                            raise lane_runner.benchmark.ConfigError(
                                "fixture host monitor summary failure"
                            )
                        summary = summarize_host_monitor(*args, **kwargs)
                        if case_name == "invalid-output-with-host-rejection":
                            summary["low_power_mode_observed"] = True
                        return summary

                    def reject_failure_environment(*_: object, **__: object) -> object:
                        if case_name == "host-monitor-policy":
                            raise evidence.EvidenceError(
                                "fixture host monitor policy failure"
                            )
                        return ()

                    original_verify_runner = lane_runner._verify_runner_digest

                    def verify_failure_runner(*args: object, **kwargs: object) -> object:
                        phase = args[2]
                        if (
                            case_name == "runner-integrity-after-process"
                            and phase == "after subprocess completion"
                        ):
                            raise lane_runner.benchmark.ConfigError(
                                "fixture runner integrity failure"
                            )
                        return original_verify_runner(*args, **kwargs)

                    original_verify_renderer = lane_runner._verify_renderer_closure

                    def verify_failure_renderer(*args: object, **kwargs: object) -> object:
                        phase = args[2]
                        if (
                            case_name == "renderer-integrity-before-monitor"
                            and phase == "immediately before host monitoring"
                        ) or (
                            case_name == "renderer-integrity-after-process"
                            and phase == "after measurement completion"
                        ):
                            raise lane_runner.benchmark.ConfigError(
                                "fixture renderer integrity failure"
                            )
                        return original_verify_renderer(*args, **kwargs)

                    def execute_failure_rendering(*_: object, **__: object) -> None:
                        if case_name == "postprocessing-failure":
                            raise lane_runner._PostprocessingFailure(
                                "fixture postprocessing failure"
                            )
                        if case_name == "postprocess-integrity":
                            raise lane_runner._IntegrityFailure(
                                "protected rendering inputs changed"
                            )

                    patches = (
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
                                benchmark.APPROVED_PAIRED_BASELINE[
                                    "toolchain_identity"
                                ],
                            ),
                        ),
                        mock.patch.dict(
                            os.environ,
                            {"EASYSPLAT_TEST_OBSERVATIONS": str(source)},
                        ),
                        mock.patch.object(
                            lane_runner.time,
                            "monotonic",
                            side_effect=[0.0, 1.0],
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_start_host_monitor",
                            side_effect=start_failure_monitor,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_finish_host_monitor",
                            side_effect=finish_failure_monitor,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_summarize_host_monitor",
                            side_effect=summarize_failure_monitor,
                        ),
                        mock.patch.object(
                            lane_runner.evidence,
                            "measurement_environment_rejections",
                            side_effect=reject_failure_environment,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_children_cpu_seconds",
                            side_effect=[
                                {"user": 0.0, "system": 0.0},
                                {"user": 0.0, "system": 0.0},
                            ],
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_run_measurement_process",
                            side_effect=run_failure,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_verify_runner_digest",
                            side_effect=verify_failure_runner,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_verify_renderer_closure",
                            side_effect=verify_failure_renderer,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_rendering_required",
                            return_value=case_name
                            in {"postprocessing-failure", "postprocess-integrity"},
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_orientation_required",
                            return_value=False,
                        ),
                        mock.patch.object(
                            lane_runner,
                            "_execute_rendering_stage",
                            side_effect=execute_failure_rendering,
                        ),
                    )
                    with ExitStack() as stack:
                        for patch in patches:
                            stack.enter_context(patch)
                        failure_result = lane_runner.run_lane(
                            index_path,
                            requests_root,
                            corpus_path,
                            config_path,
                            toolchain,
                            baseline_checkout,
                            baseline_toolchain,
                            failure_output,
                            evidence.LANE_CONSTRAINED,
                            runner,
                            renderer_closure_root,
                        )

                    failure_status = assert_collector_status(
                        failure_output,
                        kind=outcome_kind,
                        stage=outcome_stage,
                        reason=outcome_reason,
                        exit_code=expected_exit_code,
                    )
                    self.assertEqual(len(failure_result["collections"]), 1)
                    failure_collection = failure_result["collections"][0]
                    self.assertEqual(failure_collection["scene_id"], scene["id"])
                    self.assertEqual(failure_collection["scale"], 120)
                    self.assertEqual(
                        failure_collection["lane"],
                        evidence.LANE_CONSTRAINED,
                    )
                    self.assertEqual(
                        failure_collection["sha256"],
                        evidence.sha256_file(
                            artifact_root(failure_output) / "collector-status.json"
                        ),
                    )
                    self.assertEqual(
                        json.loads(
                            (
                                failure_output
                                / f"lane-{evidence.LANE_CONSTRAINED}.json"
                            ).read_text(encoding="utf-8")
                        )["collections"],
                        failure_result["collections"],
                    )
                    self.assertEqual(failure_status["outcome"]["reason"], outcome_reason)

            original_runner = runner.read_text(encoding="utf-8")
            original_candidate_validator = evidence.validate_attestation_candidate

            def validate_then_mutate_runner(*args: object, **kwargs: object) -> object:
                candidate = original_candidate_validator(*args, **kwargs)
                runner.write_text(
                    original_runner + "\n# mutation after attestation validation\n",
                    encoding="utf-8",
                )
                return candidate

            publication_output = root / "evidence-publication-mutation"
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
                mock.patch.object(
                    lane_runner,
                    "_start_host_monitor",
                    return_value=object(),
                ),
                mock.patch.object(
                    lane_runner,
                    "_finish_host_monitor",
                    return_value=monitor_report,
                ),
                mock.patch.object(
                    lane_runner,
                    "_summarize_host_monitor",
                    side_effect=summarize_host_monitor,
                ),
                mock.patch.object(
                    lane_runner,
                    "_children_cpu_seconds",
                    side_effect=[
                        {"user": 0.0, "system": 0.0},
                        {"user": 0.0, "system": 0.0},
                    ],
                ),
                mock.patch.object(
                lane_runner.evidence,
                "validate_attestation_candidate",
                side_effect=validate_then_mutate_runner,
            ),
            mock.patch.object(lane_runner, "_PROCESS_GROUP_DRAIN_SECONDS", 0.0),
            self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "digest mismatch before the first scene",
            ),
            ):
                lane_runner.run_lane(
                    index_path,
                    requests_root,
                    corpus_path,
                    config_path,
                    toolchain,
                    baseline_checkout,
                    baseline_toolchain,
                    publication_output,
                    evidence.LANE_CONSTRAINED,
                    runner,
                    renderer_closure_root,
                )
            runner.write_text(original_runner, encoding="utf-8")
            runner.chmod(0o755)
            assert_collector_status(
                publication_output,
                kind="execution_failed",
                stage="measurement_runner",
                reason="integrity_failed",
                exit_code=None,
            )

            runner.write_text(original_runner + "\n# pre-run mutation\n", encoding="utf-8")
            pre_run_mutation_output = root / "evidence-pre-run-mutation"
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
                        pre_run_mutation_output,
                        evidence.LANE_CONSTRAINED,
                        runner,
                        renderer_closure_root,
                    )

            self_mutation_output = root / "evidence-runner-self-mutation"
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
                mock.patch.object(
                    lane_runner,
                    "_start_host_monitor",
                    return_value=object(),
                ),
                mock.patch.object(
                    lane_runner,
                    "_finish_host_monitor",
                    return_value=monitor_report,
                ),
                mock.patch.object(
                    lane_runner,
                    "_children_cpu_seconds",
                    side_effect=[
                        {"user": 0.0, "system": 0.0},
                        {"user": 0.0, "system": 0.0},
                    ],
                ),
            ):
                with self.assertRaisesRegex(
                    lane_runner.benchmark.ConfigError,
                    "digest mismatch before the first scene",
                ):
                    lane_runner.run_lane(
                        index_path,
                        requests_root,
                        corpus_path,
                        config_path,
                        toolchain,
                        baseline_checkout,
                        baseline_toolchain,
                        self_mutation_output,
                        evidence.LANE_CONSTRAINED,
                        runner,
                        renderer_closure_root,
                    )
            assert_collector_status(
                self_mutation_output,
                kind="execution_failed",
                stage="measurement_runner",
                reason="integrity_failed",
                exit_code=None,
                expected_runner=index["runner_identities"][evidence.LANE_CONSTRAINED],
            )


class RunnerIntegrityTests(unittest.TestCase):
    def test_real_host_monitor_receipt_matches_python_evidence_contract(self) -> None:
        build = subprocess.run(
            ["swift", "build", "--product", "EasySplatBenchmarkDriver"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(build.returncode, 0, build.stderr)
        binary_directory = subprocess.run(
            ["swift", "build", "--show-bin-path"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(binary_directory.returncode, 0, binary_directory.stderr)
        binary = Path(binary_directory.stdout.strip()) / "EasySplatBenchmarkDriver"
        self.assertTrue(binary.is_file())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            monitor = lane_runner._start_host_monitor(
                binary,
                lane_runner._isolated_environment(root, "monitor-contract"),
                2.0,
            )
            started = time.monotonic()
            time.sleep(0.2)
            ended = time.monotonic()
            report = lane_runner._finish_host_monitor(monitor)
            monitor_path = root / "host-monitor.json"
            monitor_path.write_bytes(evidence.canonical_json_bytes(report) + b"\n")
            command = {
                "run_id": "cross-language-contract",
                "started_monotonic_seconds": started,
                "ended_monotonic_seconds": ended,
                "process_cpu_microseconds": {"user": 0, "system": 0},
            }
            machine = evidence.collect_machine_metadata()
            summary = lane_runner._summarize_host_monitor(
                report,
                [command],
                machine,
                supervisor_started=started,
                supervisor_ended=ended,
                monitor_sha256=evidence.sha256_file(monitor_path),
                monitor_executable_sha256=evidence.sha256_file(binary),
                outer_child_cpu_microseconds={"user": 0, "system": 0},
            )
            evidence.measurement_environment_rejections(
                summary,
                machine,
                [command],
                started,
                ended,
                root / "measurement-environment.json",
                evidence.sha256_file(binary),
            )

        self.assertEqual(
            set(report),
            {
                "schema_version",
                "monotonic_clock",
                "sample_interval_seconds",
                "samples",
                "events",
            },
        )
        self.assertEqual(summary["monotonic_clock"], "mach_absolute_time")
        self.assertIsInstance(summary["state_change_events"], list)

    def _orientation_stage_fixture(
        self,
        root: Path,
    ) -> tuple[
        dict[str, object],
        dict[str, object],
        Path,
        dict[str, object],
        Path,
    ]:
        observations = raw_observations(evidence.LANE_REFERENCE)
        request = evidence_request()
        request_path = root / "request.json"
        request_path.write_bytes(evidence.canonical_json_bytes(request) + b"\n")
        for field in ("ground_truth_poses_sha256", "orientation_label_sha256"):
            filename, content = REFERENCE_ARTIFACT_CONTENTS[field]
            (root / filename).write_bytes(content)
        for record in observations["timing"]["ordinary_runs"]:
            if record["variant"] != "candidate":
                continue
            run_root = root / "orientation-runs" / record["run_id"]
            run_root.mkdir(parents=True)
            (run_root / "geometry-manifest.json").write_bytes(
                evidence.canonical_json_bytes(
                    {
                        "mapping": {
                            "acceptedRefinementInvocationCount": 1,
                            "acceptedRefinementKind": "incrementalGlobal",
                            "attemptCount": 1,
                            "incrementalCadence": {
                                "globalFramesRatio": 1.4,
                                "globalMaxRefinements": 5,
                                "globalPointsRatio": 1.4,
                                "localMaxRefinements": 2,
                            },
                            "largestModelRegisteredViewCount": 30,
                            "modelCount": 1,
                            "secondLargestModelRegisteredViewCount": 0,
                            "unionRegisteredViewCount": 30,
                        },
                        "schemaVersion": 14,
                    }
                )
                + b"\n"
            )
            (run_root / "candidate-images.txt").write_text(
                "# fixture candidate images\n",
                encoding="utf-8",
            )
        executable = root / "orientation-driver-source"
        executable.write_text(
            "#!/usr/bin/python3\n"
            "import json, pathlib, sys\n"
            "args=sys.argv\n"
            "def value(flag): return args[args.index(flag)+1]\n"
            "metrics={\n"
            "'alignment_median_residual_degrees':0.1,"
            "'alignment_p90_residual_degrees':0.2,"
            "'alignment_support_count':30,"
            "'candidate_source_to_ground_truth_wxyz':[1.0,0.0,0.0,0.0],"
            "'orientation_physical_up_error_degrees':0.75,"
            "'orientation_sign_correct':True,"
            "'orientation_status':'verified'}\n"
            "pathlib.Path(value('--output')).write_text(json.dumps(metrics,sort_keys=True)+'\\n')\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        bundle = root / "MetalSplatter_MetalSplatter.bundle"
        bundle.mkdir()
        (bundle / "Shaders.metal").write_text("kernel void draw() {}\n", encoding="utf-8")
        closure = root / "renderer-closure"
        renderer_identity = lane_runner.renderer_closure.build_closure(
            executable,
            bundle,
            closure,
            root / "renderer-identity.json",
        )
        request["rendering_driver_identity"] = renderer_identity
        request_path.write_bytes(evidence.canonical_json_bytes(request) + b"\n")
        return observations, request, request_path, renderer_identity, closure

    def test_orientation_stage_invokes_the_approved_driver_for_every_candidate_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observations, request, request_path, renderer_identity, closure = (
                self._orientation_stage_fixture(root)
            )
            lane_runner._execute_orientation_stage(
                artifact_root=root,
                request=request,
                request_path=request_path,
                request_digest=evidence.sha256_file(request_path),
                renderer_closure_path=closure,
                renderer_identity=renderer_identity,
                observations=observations,
                commands=observations["commands"],
                timeout_seconds=30.0,
            )

            aggregate = json.loads(
                (root / "orientation-metrics.json").read_text(encoding="utf-8")
            )
            candidate_run_ids = [
                record["run_id"]
                for record in observations["timing"]["ordinary_runs"]
                if record["variant"] == "candidate"
            ]
            self.assertEqual(
                [run["run_id"] for run in aggregate["runs"]],
                candidate_run_ids,
            )
            self.assertTrue((root / "orientation-supervisor.json").is_file())
            for run_id in candidate_run_ids:
                self.assertTrue(
                    (root / "orientation-runs" / run_id / "orientation-metrics.json").is_file()
                )

    def test_orientation_stage_rejects_precreated_supervisor_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observations, request, request_path, renderer_identity, closure = (
                self._orientation_stage_fixture(root)
            )
            first_run_id = next(
                record["run_id"]
                for record in observations["timing"]["ordinary_runs"]
                if record["variant"] == "candidate"
            )
            precreated = root / "orientation-runs" / first_run_id / "orientation-metrics.json"
            precreated.write_text("runner controlled\n", encoding="utf-8")
            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "cannot pre-create supervisor-owned orientation-metrics.json",
            ):
                lane_runner._execute_orientation_stage(
                    artifact_root=root,
                    request=request,
                    request_path=request_path,
                    request_digest=evidence.sha256_file(request_path),
                    renderer_closure_path=closure,
                    renderer_identity=renderer_identity,
                    observations=observations,
                    commands=observations["commands"],
                    timeout_seconds=30.0,
                )

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
            1,
            "prepare uploads one renderer package and later jobs bind its artifact ID",
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
        self.assertNotIn("--evidence-key-fd", workflow)
        self.assertNotIn('exec 9<"$RUNNER_TEMP/evidence.key"', workflow)
        self.assertNotIn("environment: benchmark-evidence-signing", workflow)
        self.assertIn("scripts/benchmark/prepare_evidence.py", workflow)
        self.assertNotIn("scripts/benchmark/seal_evidence.py", workflow)
        self.assertIn("scripts/benchmark/aggregate_evidence.py", workflow)
        self.assertNotIn("--evidence-public-key-file", workflow)
        self.assertNotIn("--evidence-key-file", workflow)
        self.assertNotIn("BENCHMARK_EVIDENCE_PUBLIC_KEY_BASE64", workflow)
        self.assertNotIn("BENCHMARK_EVIDENCE_PRIVATE_KEY_BASE64", workflow)
        aggregate_job = workflow.split("  aggregate:\n", 1)[1]
        self.assertNotIn("--raw-evidence-root", aggregate_job)
        self.assertEqual(aggregate_job.count("--prepared-root"), 3)
        self.assertIn("prepared_artifact_digest", aggregate_job)
        self.assertIn("actions/artifacts/$artifact_id", aggregate_job)

    def test_release_measurement_jobs_pin_and_verify_xcode_16_4(self) -> None:
        workflow = (ROOT / ".github/workflows/benchmark-release.yml").read_text(
            encoding="utf-8"
        )
        sections = {
            "prepare": workflow.split("  prepare:\n", 1)[1].split("  reference:\n", 1)[0],
            "reference": workflow.split("  reference:\n", 1)[1].split(
                "  constrained:\n", 1
            )[0],
            "constrained": workflow.split("  constrained:\n", 1)[1].split(
                "  eight-gb:\n", 1
            )[0],
            "eight-gb": workflow.split("  eight-gb:\n", 1)[1].split(
                "  derive-reference:\n", 1
            )[0],
        }
        for name, section in sections.items():
            with self.subTest(job=name):
                self.assertIn(
                    "DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer",
                    section,
                )
                self.assertIn("name: Verify Xcode 16.4", section)
                self.assertIn(
                    'test "$(xcodebuild -version | sed -n \'1p\')" = "Xcode 16.4"',
                    section,
                )

    def test_release_workflow_installs_heavy_render_scoring_only_where_used(self) -> None:
        workflow = (ROOT / ".github/workflows/benchmark-release.yml").read_text(
            encoding="utf-8"
        )
        reference = workflow.split("  reference:\n", 1)[1].split("  constrained:\n", 1)[0]
        constrained = workflow.split("  constrained:\n", 1)[1].split("  eight-gb:\n", 1)[0]
        eight_gb = workflow.split("  eight-gb:\n", 1)[1].split("  derive-reference:\n", 1)[0]
        reference_derivation = workflow.split("  derive-reference:\n", 1)[1].split(
            "  derive-constrained:\n", 1
        )[0]
        aggregate = workflow.split("  aggregate:\n", 1)[1]

        self.assertEqual(
            workflow.count("name: Install protected render-scoring dependencies"),
            1,
            "only no-secret reference derivation scores pixels",
        )
        self.assertNotIn("render-requirements.txt", reference)
        self.assertNotIn("render-requirements.txt", constrained)
        self.assertNotIn("render-requirements.txt", eight_gb)
        self.assertIn("render-requirements.txt", reference_derivation)
        self.assertNotIn("render-requirements.txt", aggregate)
        self.assertNotIn("signing-requirements.txt", workflow)

    def test_run_suite_requires_render_dependencies_only_when_verifying_evidence(self) -> None:
        launcher = (ROOT / "scripts/benchmark/run_suite.sh").read_text(encoding="utf-8")

        self.assertIn('if [ -n "$EVIDENCE_ROOT" ]; then', launcher)
        self.assertNotIn('if [ "$DRY_RUN" -eq 0 ]; then\n  dependency_locks+=', launcher)
        self.assertNotIn("--evidence-public-key-file", launcher)
        self.assertNotIn("EVIDENCE_PUBLIC_KEY_FILE", launcher)

    def _renderer_stage_fixture(
        self,
        root: Path,
        *,
        exit_code: int = 0,
        mutate_shader: bool = False,
        mutate_preparation: bool = False,
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
            + (
                "    (pathlib.Path(sys.argv[sys.argv.index('--artifact-root')+1]) / "
                "'ground-truth-preparation.json').write_text('tampered\\n', encoding='utf-8')\n"
                if mutate_preparation
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
        (artifact_root / "ground-truth-preparation.json").write_bytes(
            FIXTURE_GROUND_TRUTH_PREPARATION
        )
        (artifact_root / "selection-manifest.json").write_bytes(
            FIXTURE_SELECTION_MANIFEST
        )
        for holdout in holdouts:
            preparation_view = next(
                view
                for view in FIXTURE_PREPARATION_VIEWS
                if view["holdout_index"] == holdout
            )
            for image_kind in ("source", "target"):
                image_path = artifact_root / preparation_view[image_kind]["path"]
                image_path.parent.mkdir(parents=True, exist_ok=True)
                image_path.write_bytes(FIXTURE_GROUND_TRUTH_IMAGES[holdout])
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
        job = {
            "schema_version": 2,
            "scene_id": request["binding"]["scene_id"],
            "scale": request["binding"]["scale"],
            "request_digest": request_digest,
            "input_digest": request["binding"]["input_digest"],
            "renderer_closure_sha256": identity["sha256"],
            "renderer_executable_sha256": identity["executable_sha256"],
            "ground_truth_preparation": {
                "path": "ground-truth-preparation.json",
                "sha256": request["reference_artifacts"][
                    "ground_truth_preparation_sha256"
                ],
            },
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
                    "camera": fixture_render_camera(holdout),
                    "ground_truth": {
                        "path": f"rendering/ground-truth/{holdout:06d}.png",
                        "sha256": evidence.sha256_bytes(
                            FIXTURE_GROUND_TRUTH_IMAGES[holdout]
                        ),
                        "source_path": f"rendering/source/{holdout:06d}.png",
                        "source_sha256": evidence.sha256_bytes(
                            FIXTURE_GROUND_TRUTH_IMAGES[holdout]
                        ),
                        "preparation_view_sha256": next(
                            view["preparation_view_sha256"]
                            for view in FIXTURE_PREPARATION_VIEWS
                            if view["holdout_index"] == holdout
                        ),
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
                "protected rendering inputs changed",
            ):
                self._run_renderer_stage(fixture)
            self.assertTrue(fixture["invocation_marker"].is_file())

    def test_rendering_stage_rejects_preparation_mutation_after_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(
                Path(directory),
                mutate_preparation=True,
            )

            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "protected rendering inputs changed",
            ):
                self._run_renderer_stage(fixture)
            self.assertTrue(fixture["invocation_marker"].is_file())

    def test_render_job_rejects_preparation_binding_drift_before_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = self._renderer_stage_fixture(Path(directory))
            job_path = fixture["artifact_root"] / "render-job.json"
            job = json.loads(job_path.read_text(encoding="utf-8"))
            job["ground_truth_preparation"]["sha256"] = "sha256:" + "0" * 64
            job_path.write_bytes(evidence.canonical_json_bytes(job) + b"\n")

            with self.assertRaisesRegex(
                lane_runner.benchmark.ConfigError,
                "ground-truth preparation",
            ):
                self._run_renderer_stage(fixture)
            self.assertFalse(fixture["invocation_marker"].exists())

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

    def test_measurement_process_reaps_a_terminated_zombie_without_signalling_it_again(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (
                (root / "stdout").open("wb") as stdout_handle,
                (root / "stderr").open("wb") as stderr_handle,
                mock.patch.object(
                    lane_runner,
                    "_PROCESS_GROUP_TERMINATION_GRACE_SECONDS",
                    0.05,
                ),
            ):
                completed, timed_out = lane_runner._run_measurement_process(
                    ["/bin/sleep", "2"],
                    stdout_handle,
                    stderr_handle,
                    {"PATH": "/usr/bin:/bin"},
                    0.1,
                )
        self.assertTrue(timed_out)
        self.assertIn(completed.returncode, {-lane_runner.signal.SIGTERM, 0})

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
            self.assertEqual(
                benchmark.resolved_public_beta_toolchain_identity(
                    root,
                    public_key_base64=public_key_base64,
                ),
                identity,
            )

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
            undeclared = root / "bin/undeclared-helper"
            undeclared.write_bytes(b"not signed")
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(benchmark.ConfigError, "undeclared file"):
                benchmark.resolved_toolchain_identity(
                    root,
                    "release",
                    public_key_base64=public_key_base64,
                )
            undeclared.unlink()

            state["installedArtifacts"].pop("geometry-da3-small")
            state["installedCapabilities"].remove("fixture.geometry-da3-small")
            (root / "da3_mps/models/DA3-SMALL/model.safetensors").unlink()
            (root / "da3_mps/models/DA3-SMALL").rmdir()
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
            with self.assertRaisesRegex(benchmark.ConfigError, "public-beta component closure"):
                benchmark.resolved_public_beta_toolchain_identity(
                    root,
                    public_key_base64=public_key_base64,
                )

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

    def test_release_suite_keeps_failures_when_a_sibling_lane_is_missing(self) -> None:
        scene = valid_scene(adapter="protected-evidence")
        scene["scale_lanes"] = [120]
        scene["aggregate_scale"] = 120
        scene["split"]["holdout_by_scale"] = {"120": list(range(4, 120, 5))}
        pinned_reference = next(iter(scene["reference"]["by_scale"].values()))
        scene["reference"]["by_scale"] = {"120": pinned_reference}
        scene["gate_scopes"] = evidence_request(scale=120)["gate_scopes"]
        corpus = {
            "schema_version": 1,
            "manifest_profile": "release",
            "scenes": [scene],
        }
        config = valid_reference_config()
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest=benchmark.sha256_json(corpus),
            thresholds_digest=benchmark.sha256_json(config),
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity=TEST_TOOLCHAIN_IDENTITY,
        )
        identities = runner_identities()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = root / "corpus.json"
            config_path = root / "reference.json"
            corpus_path.write_bytes(benchmark.canonical_json_bytes(corpus) + b"\n")
            config_path.write_bytes(benchmark.canonical_json_bytes(config) + b"\n")
            media = root / scene["input"]["media_path"]
            media.parent.mkdir(parents=True)
            media.write_bytes(b"scene")
            evidence_root = root / "evidence"
            reference_root = (
                evidence_root
                / scene["adapter"]["evidence_path"]
                / "120"
                / evidence.LANE_REFERENCE
            )
            reference_root.mkdir(parents=True)
            malformed = reference_root / "attestation.json"
            malformed.write_text("not-json\n", encoding="utf-8")
            request_index = root / "request-index.json"
            request_index.write_text("{}\n", encoding="utf-8")

            patches = (
                mock.patch.object(benchmark, "validate_corpus"),
                mock.patch.object(
                    benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(
                    benchmark,
                    "collect_machine_metadata",
                    return_value=evidence_machine(evidence.LANE_REFERENCE),
                ),
                mock.patch.object(
                    benchmark,
                    "resolved_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(benchmark, "make_run_identity", return_value=identity),
                mock.patch.object(
                    benchmark,
                    "validate_request_index",
                    return_value={"runner_identities": identities},
                ),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
                failed_exit = benchmark.run_suite(
                    profile="release",
                    corpus_path=corpus_path,
                    reference_config_path=config_path,
                    toolchain_root=root / "toolchain",
                    output_directory=root / "failed-output",
                    dry_run=False,
                    stdout=io.StringIO(),
                    evidence_root=evidence_root,
                    request_index_path=request_index,
                )
            failed = json.loads(
                (root / "failed-output" / "suite.json").read_text(encoding="utf-8")
            )
            self.assertEqual(failed_exit, 1)
            self.assertEqual(failed["status"], "failed")
            self.assertEqual(failed["scene_results"][0]["status"], "failed")
            self.assertEqual(failed["aggregates"]["failed"], 1)
            self.assertTrue(
                any("reference_m4_max" in failure for failure in failed["failures"])
            )
            self.assertTrue(
                any("constrained_14_16gb" in reason for reason in failed["blocking_reasons"])
            )

            malformed.unlink()
            patches = (
                mock.patch.object(benchmark, "validate_corpus"),
                mock.patch.object(
                    benchmark,
                    "collect_git_state",
                    return_value={"commit": identity.git_commit, "dirty": False},
                ),
                mock.patch.object(
                    benchmark,
                    "collect_machine_metadata",
                    return_value=evidence_machine(evidence.LANE_REFERENCE),
                ),
                mock.patch.object(
                    benchmark,
                    "resolved_toolchain_identity",
                    return_value=identity.toolchain_identity,
                ),
                mock.patch.object(benchmark, "make_run_identity", return_value=identity),
                mock.patch.object(
                    benchmark,
                    "validate_request_index",
                    return_value={"runner_identities": identities},
                ),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
                blocked_exit = benchmark.run_suite(
                    profile="release",
                    corpus_path=corpus_path,
                    reference_config_path=config_path,
                    toolchain_root=root / "toolchain",
                    output_directory=root / "blocked-output",
                    dry_run=False,
                    stdout=io.StringIO(),
                    evidence_root=evidence_root,
                    request_index_path=request_index,
                )
            blocked = json.loads(
                (root / "blocked-output" / "suite.json").read_text(encoding="utf-8")
            )
            self.assertEqual(blocked_exit, 2)
            self.assertEqual(blocked["status"], "blocked")
            self.assertEqual(blocked["scene_results"][0]["status"], "blocked")
            self.assertEqual(blocked["aggregates"]["blocked"], 1)
            self.assertEqual(blocked["failures"], [])

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

    def test_final_suite_validation_enforces_failure_precedence(self) -> None:
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
            passed = json.loads((output / "suite.json").read_text(encoding="utf-8"))

        suite_mismatch = json.loads(json.dumps(passed))
        suite_mismatch["status"] = "blocked"
        suite_mismatch["failures"] = ["fixture failure"]
        with self.assertRaisesRegex(benchmark.ConfigError, "status contradicts"):
            benchmark.validate_suite_result(suite_mismatch)

        scene_mismatch = json.loads(json.dumps(passed))
        scene_mismatch["status"] = "failed"
        scene_mismatch["failures"] = ["fixture scene failure"]
        scene_mismatch["scene_results"][0]["status"] = "blocked"
        scene_mismatch["scene_results"][0]["failures"] = ["fixture failure"]
        with self.assertRaisesRegex(benchmark.ConfigError, "status contradicts"):
            benchmark.validate_suite_result(scene_mismatch)

        omitted_scene_failure = json.loads(json.dumps(passed))
        omitted_scene_failure["scene_results"][0]["status"] = "failed"
        omitted_scene_failure["scene_results"][0]["failures"] = ["fixture failure"]
        omitted_scene_failure["aggregates"]["passed"] = 0
        omitted_scene_failure["aggregates"]["failed"] = 1
        with self.assertRaisesRegex(benchmark.ConfigError, "omit scene failures"):
            benchmark.validate_suite_result(omitted_scene_failure)

        omitted_scene_blocker = json.loads(json.dumps(passed))
        omitted_scene_blocker["scene_results"][0]["status"] = "blocked"
        omitted_scene_blocker["scene_results"][0]["blocking_reasons"] = ["fixture unavailable"]
        omitted_scene_blocker["aggregates"]["passed"] = 0
        omitted_scene_blocker["aggregates"]["blocked"] = 1
        with self.assertRaisesRegex(benchmark.ConfigError, "omit scene blockers"):
            benchmark.validate_suite_result(omitted_scene_blocker)

        aggregate_mismatch = json.loads(json.dumps(passed))
        aggregate_mismatch["aggregates"]["passed"] = 0
        aggregate_mismatch["aggregates"]["blocked"] = 1
        with self.assertRaisesRegex(benchmark.ConfigError, "aggregates contradict"):
            benchmark.validate_suite_result(aggregate_mismatch)


if __name__ == "__main__":
    unittest.main()
