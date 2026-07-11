from __future__ import annotations

import importlib.util
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


def measured(value: object) -> dict[str, object]:
    return {"availability": "measured", "value": value}


def unavailable() -> dict[str, object]:
    return {"availability": "not_available"}


def valid_scene(
    scene_id: str = "orbit-01",
    category: str = "object_orbit",
    adapter: str = "external-result",
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
            "accurate_colmap": True,
            "rendering_reference": False,
        },
        "expected_outcome": {"kind": "valid"},
        "adapter": {
            "type": adapter,
            "result_path": f"external/{scene_id}.result.json",
        },
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
            scene = valid_scene(f"{category}-{index:02d}", category)
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
            "streaming": {"inference_fps_min": 5.0, "sustained_frames_min": 3000},
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
        "streaming_inference_fps": measured(5.0),
        "streaming_sustained_frames": measured(3000),
        "peak_memory_bytes": measured(6_500_000_000),
        "machine_memory_bytes": measured(8_000_000_000),
        "memory_lane": measured("eight_gb_fast"),
        "repeat_runs": measured(50),
        "crashes": measured(0),
        "corrupt_outputs": measured(0),
        "normal_photo_toolchain_bytes": measured(2_500_000_000),
        "streaming_toolchain_bytes": measured(6_000_000_000),
        "finished_v1_opens": measured(True),
        "valid_v1_geometry_retrains": measured(True),
        "deterministic_restart": measured(True),
    }


class ConfigurationValidationTests(unittest.TestCase):
    def test_tracked_release_contract_is_valid_and_complete(self) -> None:
        corpus = json.loads((ROOT / "scripts/benchmark/corpus.json").read_text(encoding="utf-8"))
        config = json.loads((ROOT / "scripts/benchmark/reference-config.json").read_text(encoding="utf-8"))
        benchmark.validate_corpus(corpus, expected_profile="release")
        benchmark.validate_reference_config(config)
        self.assertEqual(len(corpus["scenes"]), 26)
        self.assertTrue(all(scene["input"]["supplied"] is False for scene in corpus["scenes"]))

    def test_result_schema_closes_top_level_and_scene_contracts(self) -> None:
        schema = json.loads((ROOT / "scripts/benchmark/result.schema.json").read_text(encoding="utf-8"))
        self.assertIs(schema["additionalProperties"], False)
        self.assertIs(schema["$defs"]["sceneResult"]["additionalProperties"], False)
        self.assertIs(schema["$defs"]["metrics"]["additionalProperties"], False)

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


class TimeParserTests(unittest.TestCase):
    def test_parses_present_rss_and_footprint(self) -> None:
        parsed = benchmark.parse_time_l(
            "  12345  maximum resident set size\n  67890  peak memory footprint\n"
        )
        self.assertEqual(parsed["max_resident_set_size_bytes"], 12345)
        self.assertEqual(parsed["peak_memory_footprint_bytes"], 67890)

    def test_missing_values_remain_unavailable(self) -> None:
        parsed = benchmark.parse_time_l("no memory metrics here")
        self.assertEqual(parsed["max_resident_set_size_bytes"], unavailable())
        self.assertEqual(parsed["peak_memory_footprint_bytes"], unavailable())


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
            "streaming_inference_fps": measured(4.9999),
            "streaming_sustained_frames": measured(2999),
            "repeat_runs": measured(49),
            "crashes": measured(1),
            "corrupt_outputs": measured(1),
            "normal_photo_toolchain_bytes": measured(2_500_000_001),
            "streaming_toolchain_bytes": measured(6_000_000_001),
            "finished_v1_opens": measured(False),
            "valid_v1_geometry_retrains": measured(False),
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


class InvalidSceneTests(unittest.TestCase):
    def test_declared_failure_without_corrupt_ply_passes(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        actual = {"exit_code": 2, "failure_type": "disconnected_input", "corrupt_ply": False}
        self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "passed")

    def test_wrong_failure_or_corrupt_ply_fails(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        for actual in (
            {"exit_code": 0, "failure_type": None, "corrupt_ply": False},
            {"exit_code": 2, "failure_type": "other", "corrupt_ply": False},
            {"exit_code": 2, "failure_type": "disconnected_input", "corrupt_ply": True},
        ):
            with self.subTest(actual=actual):
                self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "failed")

    def test_missing_failure_type_blocks(self) -> None:
        expected = {"kind": "invalid", "failure_type": "disconnected_input"}
        actual = {"exit_code": 2, "corrupt_ply": False}
        self.assertEqual(benchmark.evaluate_invalid_scene(expected, actual)["status"], "blocked")


class MetadataAndPersistenceTests(unittest.TestCase):
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


class OrchestrationTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
