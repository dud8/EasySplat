from __future__ import annotations

import importlib.util
import hashlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts" / "benchmark" / "easysplat_benchmark.py"
SPEC = importlib.util.spec_from_file_location("easysplat_benchmark", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load benchmark module at {MODULE_PATH}")
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
evidence = benchmark.evidence
from scripts.benchmark import run_lane as lane_runner


def measured(value: object) -> dict[str, object]:
    return {"availability": "measured", "value": value}


def unavailable() -> dict[str, object]:
    return {"availability": "not_available"}


def valid_scene(
    scene_id: str = "orbit-01",
    category: str = "object_orbit",
    adapter: str = "fixture",
) -> dict[str, object]:
    return {
        "id": scene_id,
        "category": category,
        "license": {
            "name": "External consent required",
            "url": "https://example.invalid/license",
            "redistributable": False,
        },
        "provenance": {
            "source": "External benchmark corpus",
            "consent": "Must be documented before release use",
        },
        "input": {
            "kind": "video",
            "media_path": f"external/{scene_id}.mov",
            "supplied": False,
        },
        "scale_lanes": [30, 120],
        "split": {"train": [0, 2, 4], "holdout": [1, 3]},
        "reference": {
            "ground_truth_poses": False,
            "accurate_colmap": False,
            "rendering_reference": False,
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
        "exterior_drone": 4,
        "low_light": 3,
        "invalid": 3,
    }
    scenes: list[dict[str, object]] = []
    for category, count in counts.items():
        for index in range(1, count + 1):
            scene = valid_scene(f"{category}-{index:02d}", category, "protected-evidence")
            if category == "invalid":
                scene["expected_outcome"] = {
                    "kind": "invalid",
                    "failure_type": "disconnected_input",
                }
            scenes.append(scene)
    return {"schema_version": 1, "manifest_profile": "release", "scenes": scenes}


def valid_reference_config() -> dict[str, object]:
    return {
        "schema_version": 1,
        "references": {
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
            "long_sequence": {"inference_fps_min": 5.0, "sustained_frames_min": 3000},
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
    return {
        "registered_views": measured(95),
        "total_views": measured(100),
        "colmap_registered_views": measured(100),
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
        "fast_end_to_end_speedup": measured(2.0),
        "m4_max_p50_seconds": measured(120.0),
        "balanced_geometry_speedup": measured(2.0),
        "constrained_fast_p50_seconds": measured(300.0),
        "long_sequence_geometry_fps": measured(5.0),
        "long_sequence_frames": measured(3000),
        "peak_memory_bytes": measured(6_500_000_000),
        "machine_memory_bytes": measured(8_000_000_000),
        "memory_lane": measured("eight_gb_fast"),
        "repeat_runs": measured(50),
        "crashes": measured(0),
        "corrupt_outputs": measured(0),
        "normal_photo_toolchain_bytes": measured(2_500_000_000),
        "large_area_toolchain_bytes": measured(2_500_000_000),
        "deterministic_restart": measured(True),
    }


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


def runner_identity(lane: str, digest_character: str = "a") -> dict[str, str]:
    return {
        "label": evidence.RUNNER_LABELS[lane],
        "sha256": "sha256:" + digest_character * 64,
    }


def runner_identities() -> dict[str, dict[str, str]]:
    return {lane: runner_identity(lane) for lane in sorted(evidence.RELEASE_LANES)}


def evidence_request(scene_id: str = "orbit-01", scale: int = 30) -> dict[str, object]:
    return {
        "schema_version": 1,
        "binding": {
            "profile": "release",
            "scene_id": scene_id,
            "scale": scale,
            "input_digest": "sha256:" + "1" * 64,
            "corpus_digest": "sha256:" + "2" * 64,
            "thresholds_digest": "sha256:" + "3" * 64,
            "git_commit": "4" * 40,
            "app_version": "0.2.0-beta.1",
            "toolchain_identity": "sha256:" + "5" * 64,
        },
        "expected_outcome": {"kind": "valid"},
        "input_kind": "video",
    }


def raw_observations(lane: str) -> dict[str, object]:
    observations: dict[str, object] = {
        "schema_version": 1,
        "artifacts": {
            "command_log": "command.jsonl",
            "stdout_log": "stdout.log",
            "stderr_log": "stderr.log",
            "output_ply": "splat.ply",
        },
        "commands": [["easysplat-benchmark", "corpus://orbit-01", "toolchain://2.0.0"]],
        "actual": successful_actual(),
        "timing": {"candidate_end_to_end_seconds": [100.0]},
        "memory_bytes": [6_000_000_000],
    }
    if lane == evidence.LANE_REFERENCE:
        observations["artifacts"].update(
            {
                "normal_photo_toolchain": "normal-photo.zip",
                "large_area_toolchain": "large-area.zip",
            }
        )
        observations.update(
            {
                "registration": {"candidate": [True] * 30, "colmap": [True] * 30},
                "residual_pixels": [1.0, 1.5, 2.0],
                "pose": {
                    "candidate_ate": [1.0, 1.0],
                    "colmap_ate": [1.0, 1.0],
                    "candidate_rotation_rpe_degrees": [0.2],
                    "colmap_rotation_rpe_degrees": [0.1],
                    "candidate_translation_rpe_percentage_points": [2.0],
                    "colmap_translation_rpe_percentage_points": [1.0],
                },
                "rendering": {
                    "balanced": [
                        {
                            "candidate_psnr": 29.8,
                            "reference_psnr": 30.0,
                            "candidate_ssim": 0.99,
                            "reference_ssim": 0.995,
                            "candidate_lpips": 0.05,
                            "reference_lpips": 0.04,
                        }
                    ],
                    "fast": [
                        {
                            "candidate_psnr": 29.5,
                            "reference_psnr": 30.0,
                            "candidate_ssim": 0.98,
                            "reference_ssim": 0.99,
                            "candidate_lpips": 0.05,
                            "reference_lpips": 0.04,
                        }
                    ],
                },
                "timing": {
                    "candidate_end_to_end_seconds": [100.0],
                    "baseline_end_to_end_seconds": [250.0],
                    "candidate_geometry_seconds": [40.0],
                    "baseline_geometry_seconds": [100.0],
                    "training_seconds": [60.0],
                },
                "long_sequence": {"frames": 3000, "seconds": 500.0},
                "stability": {
                    "runs": [{"crashed": False, "corrupt_output": False}] * 50,
                    "deterministic_restart": [True],
                },
            }
        )
    elif lane == evidence.LANE_CONSTRAINED:
        observations["timing"] = {"candidate_end_to_end_seconds": [250.0]}
        observations["memory_bytes"] = [10_000_000_000]
    return observations


def write_evidence_artifacts(root: Path, observations: dict[str, object]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for name, content in (
        ("command.jsonl", '{"event":"run"}\n'),
        ("stdout.log", "complete\n"),
        ("stderr.log", ""),
        ("splat.ply", "ply\nformat ascii 1.0\nelement vertex 0\nend_header\n"),
        ("normal-photo.zip", "photo toolchain"),
        ("large-area.zip", "large-area toolchain"),
    ):
        (root / name).write_text(content, encoding="utf-8")
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
            all(not any(scene["reference"].values()) for scene in corpus["scenes"]),
            "unsupplied release slots must not claim reference availability",
        )
        self.assertTrue(
            all(scene["adapter"]["type"] == "protected-evidence" for scene in corpus["scenes"]),
            "release slots must never use a metrics fixture or geometry-only adapter",
        )

    def test_result_schema_closes_top_level_and_scene_contracts(self) -> None:
        schema = json.loads((ROOT / "scripts/benchmark/result.schema.json").read_text(encoding="utf-8"))
        self.assertIs(schema["additionalProperties"], False)
        self.assertIs(schema["$defs"]["sceneResult"]["additionalProperties"], False)
        self.assertIs(schema["$defs"]["metrics"]["additionalProperties"], False)
        boolean_metrics = {
            name
            for name, definition in schema["$defs"]["metrics"]["properties"].items()
            if definition == {"$ref": "#/$defs/booleanMetric"}
        }
        self.assertEqual(boolean_metrics, {"deterministic_restart"})
        evidence_schema = json.loads(
            (ROOT / "scripts/benchmark/evidence.schema.json").read_text(encoding="utf-8")
        )
        self.assertIs(evidence_schema["additionalProperties"], False)
        self.assertIs(evidence_schema["properties"]["artifacts"]["additionalProperties"]["additionalProperties"], False)
        self.assertIn("measurement_runner", evidence_schema["required"])
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

    def test_invalid_scale_and_split_overlap_are_rejected(self) -> None:
        corpus = valid_corpus()
        corpus["scenes"][0]["scale_lanes"] = [31]
        with self.assertRaisesRegex(benchmark.ConfigError, "scale lane"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")
        corpus = valid_corpus()
        corpus["scenes"][0]["split"] = {"train": [0, 1], "holdout": [1, 2]}
        with self.assertRaisesRegex(benchmark.ConfigError, "overlap"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")

    def test_invalid_thresholds_are_rejected(self) -> None:
        config = valid_reference_config()
        config["thresholds"]["coverage"]["absolute_min"] = 1.01
        with self.assertRaisesRegex(benchmark.ConfigError, "coverage.absolute_min"):
            benchmark.validate_reference_config(config)

    def test_unsupplied_scene_cannot_claim_reference_availability(self) -> None:
        corpus = valid_corpus()
        corpus["scenes"][0]["reference"]["ground_truth_poses"] = True
        with self.assertRaisesRegex(benchmark.ConfigError, "unsupplied.*reference"):
            benchmark.validate_corpus(corpus, expected_profile="smoke")


class GateEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.thresholds = valid_reference_config()["thresholds"]

    def test_every_threshold_accepts_the_exact_boundary(self) -> None:
        evaluation = benchmark.evaluate_gates(passing_metrics(), self.thresholds)
        self.assertEqual(evaluation, {"status": "passed", "blocking_reasons": [], "failures": []})

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
            "balanced_median_psnr_loss_db": measured(0.5001),
            "balanced_median_ssim_loss": measured(0.0101),
            "balanced_median_lpips_increase": measured(0.0201),
            "balanced_scene_psnr_loss_db": measured(1.0001),
            "balanced_scene_ssim_loss": measured(0.0201),
            "balanced_scene_lpips_increase": measured(0.0301),
            "fast_scene_psnr_loss_db": measured(1.0001),
            "fast_scene_ssim_loss": measured(0.0201),
            "fast_scene_lpips_increase": measured(0.0301),
            "fast_end_to_end_speedup": measured(1.9999),
            "m4_max_p50_seconds": measured(120.0001),
            "balanced_geometry_speedup": measured(1.9999),
            "constrained_fast_p50_seconds": measured(300.0001),
            "long_sequence_geometry_fps": measured(4.9999),
            "long_sequence_frames": measured(2999),
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

    def produce(self, root: Path, lane: str) -> tuple[Path, dict[str, object]]:
        observations = raw_observations(lane)
        write_evidence_artifacts(root, observations)
        output = root / "attestation.json"
        attestation = evidence.produce_attestation(
            evidence_request(),
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
            self.assertEqual(metrics["registered_views"], measured(30))
            self.assertEqual(metrics["repeat_runs"], measured(50))
            self.assertEqual(metrics["deterministic_restart"], measured(True))
            self.assertEqual(metrics["m4_max_p50_seconds"], measured(100.0))
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
                    evidence_request(),
                    observations,
                    root,
                    root / "attestation.json",
                    self.key,
                    evidence.LANE_CONSTRAINED,
                    runner_identity(evidence.LANE_CONSTRAINED),
                    machine=evidence_machine(evidence.LANE_REFERENCE),
                )

    def test_release_scales_require_reference_and_constrained_attestations(self) -> None:
        self.assertEqual(
            benchmark.required_evidence_lanes(250),
            (evidence.LANE_REFERENCE, evidence.LANE_CONSTRAINED),
        )
        self.assertEqual(
            benchmark.required_evidence_lanes(120),
            (evidence.LANE_REFERENCE, evidence.LANE_CONSTRAINED, evidence.LANE_EIGHT_GB),
        )

    def test_suite_accepts_only_complete_verified_multi_machine_evidence(self) -> None:
        scene = valid_scene(adapter="protected-evidence")
        scene["input"]["supplied"] = True
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest="sha256:" + "2" * 64,
            thresholds_digest="sha256:" + "3" * 64,
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity="sha256:" + "5" * 64,
        )
        with tempfile.TemporaryDirectory() as directory:
            corpus_root = Path(directory)
            scale_root = corpus_root / scene["adapter"]["evidence_path"] / "30"
            for lane in benchmark.required_evidence_lanes(30):
                root = scale_root / lane
                observations = raw_observations(lane)
                write_evidence_artifacts(root, observations)
                attestation = evidence.produce_attestation(
                    evidence_request(),
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
                set(benchmark.required_evidence_lanes(30)),
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
                set(benchmark.required_evidence_lanes(30)),
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
        scene["scale_lanes"] = [250]
        corpus = {"schema_version": 1, "manifest_profile": "release", "scenes": [scene]}
        config = valid_reference_config()
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest=benchmark.sha256_json(corpus),
            thresholds_digest=benchmark.sha256_json(config),
            git_commit="4" * 40,
            app_version="0.2.0-beta.1",
            toolchain_identity="sha256:" + "5" * 64,
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
            request = benchmark._evidence_request(
                scene,
                250,
                identity,
                benchmark.digest_input(media),
            )
            requests_root = root / "requests"
            request_relative = Path("orbit-01/250/constrained_14_16gb.request.json")
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
                "requests": [
                    {
                        "scene_id": scene["id"],
                        "scale": 250,
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
            (source / "observations.json").write_bytes(
                evidence.canonical_json_bytes(observations) + b"\n"
            )
            (source / "splat.ply").write_text(
                "ply\nformat ascii 1.0\nelement vertex 0\nend_header\n",
                encoding="utf-8",
            )
            runner = root / "measurement-runner"
            runner.write_text(
                "#!/usr/bin/env python3\n"
                "import argparse, os, pathlib, shutil\n"
                "p=argparse.ArgumentParser()\n"
                "p.add_argument('--request'); p.add_argument('--input'); p.add_argument('--toolchain-root')\n"
                "p.add_argument('--artifact-root'); p.add_argument('--lane'); a=p.parse_args()\n"
                "source=pathlib.Path(os.environ['EASYSPLAT_TEST_OBSERVATIONS'])\n"
                "root=pathlib.Path(a.artifact_root)\n"
                "shutil.copy2(source/'observations.json', root/'observations.json')\n"
                "shutil.copy2(source/'splat.ply', root/'splat.ply')\n",
                encoding="utf-8",
            )
            runner.chmod(0o755)
            approved_runners = runner_identities()
            approved_runners[evidence.LANE_CONSTRAINED] = {
                "label": evidence.RUNNER_LABELS[evidence.LANE_CONSTRAINED],
                "sha256": evidence.sha256_file(runner),
            }
            reference_request = Path("orbit-01/250/reference_m4_max.request.json")
            (requests_root / reference_request).write_bytes(
                benchmark.canonical_json_bytes(request) + b"\n"
            )
            index["runner_identities"] = approved_runners
            index["requests"].append(
                {
                    "scene_id": scene["id"],
                    "scale": 250,
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
                mock.patch.dict(
                    os.environ,
                    {"EASYSPLAT_TEST_OBSERVATIONS": str(source)},
                ),
            ):
                result = lane_runner.run_lane(
                    index_path,
                    requests_root,
                    corpus_path,
                    config_path,
                    toolchain,
                    root / "evidence",
                    evidence.LANE_CONSTRAINED,
                    runner,
                    key_path,
                )
            self.assertEqual(len(result["attestations"]), 1)
            attestation_path = (
                root
                / "evidence"
                / scene["adapter"]["evidence_path"]
                / "250"
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
                        root / "evidence",
                        evidence.LANE_CONSTRAINED,
                        runner,
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
                        root / "evidence",
                        evidence.LANE_CONSTRAINED,
                        runner,
                        key_path,
                    )


class RunnerIntegrityTests(unittest.TestCase):
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
                "keyID": "a" * 64,
                "version": "2.0.0",
                "publishedAt": "2026-07-01T00:00:00Z",
                "appVersionRange": {"minimum": "0.2.0-beta.1"},
                "components": components,
                "signatureEd25519": "c2lnbmF0dXJl",
            }
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

            identity = benchmark.resolved_toolchain_identity(root, "release")
            self.assertRegex(identity or "", r"^sha256:[0-9a-f]{64}$")

            state["padding"] = "x" * (2 * 1024 * 1024)
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            identity = benchmark.resolved_toolchain_identity(root, "release")
            self.assertRegex(identity or "", r"^sha256:[0-9a-f]{64}$")

            state["padding"] = "x" * benchmark.MAX_TOOLCHAIN_INSTALL_STATE_BYTES
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(benchmark.ConfigError, "size limit"):
                benchmark.resolved_toolchain_identity(root, "release")

            state.pop("padding")
            state["installedArtifacts"].pop("geometry-da3-base")
            (root / ".easysplat_toolchain_state.json").write_text(
                json.dumps(state),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(benchmark.ConfigError, "complete component closure"):
                benchmark.resolved_toolchain_identity(root, "release")

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
