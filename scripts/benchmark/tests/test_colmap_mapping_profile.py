from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

try:
    from scripts.benchmark import colmap_mapping_profile
except ImportError:
    colmap_mapping_profile = None


def _profiler():
    if colmap_mapping_profile is None:
        raise AssertionError("COLMAP mapping profiler is not implemented")
    return colmap_mapping_profile


def _line(second: str, message: str) -> str:
    return (
        f"I20260102 03:04:{second} 0xabc synthetic_mapper.cc:7] "
        f"{message}"
    )


def _report(
    second: str,
    title: str,
    *,
    residuals: object = 10,
    parameters: object = 4,
    iterations: object = 2,
    solver_seconds: object = 0.5,
    initial_cost: object = 1.25,
    final_cost: object = 0.5,
    termination: object = "Convergence",
) -> list[str]:
    return [
        _line(second, title),
        f"    Residuals : {residuals}",
        f"   Parameters : {parameters}",
        f"   Iterations : {iterations}",
        f"         Time : {solver_seconds} [s]",
        f" Initial cost : {initial_cost} [px]",
        f"   Final cost : {final_cost} [px]",
        f"  Termination : {termination}",
    ]


def _valid_log(*extra_lines: str) -> str:
    return "\n".join(
        [
            _line("00.000000", "Loading database"),
            *extra_lines,
            _line("01.000000", "Global bundle adjustment"),
            *_report(
                "01.100000",
                "Bundle adjustment report",
                residuals=10,
                parameters=4,
                iterations=2,
                solver_seconds=0.5,
            ),
            _line("02.000000", "Registering image #7 (num_reg_frames=2)"),
            *_report(
                "02.100000",
                "Pose refinement report",
                residuals=6,
                parameters=6,
                iterations=3,
                solver_seconds=0.1,
            ),
            *_report(
                "02.300000",
                "Bundle adjustment report",
                residuals=20,
                parameters=8,
                iterations=4,
                solver_seconds=0.4,
            ),
            _line(
                "03.000000",
                "Retriangulation and Global bundle adjustment",
            ),
            *_report(
                "03.100000",
                "Bundle adjustment report",
                residuals=30,
                parameters=10,
                iterations=5,
                solver_seconds=0.75,
            ),
            _line("05.000000", "Keeping successful reconstruction"),
            _line("06.000000", "Global bundle adjustment"),
            *_report(
                "06.100000",
                "Bundle adjustment report",
                residuals=40,
                parameters=12,
                iterations=7,
                solver_seconds=0.35,
            ),
            _line("08.000000", "Elapsed time: 0.133 [minutes]"),
        ]
    )


def _single_local_report(report: list[str]) -> str:
    return "\n".join(
        [
            _line("00.000000", "Loading database"),
            _line("01.000000", "Registering image #2 (num_reg_frames=2)"),
            *report,
            _line("08.000000", "Elapsed time: 0.133 [minutes]"),
        ]
    )


class ColmapMappingProfileTests(unittest.TestCase):
    def test_classifies_reports_and_accumulates_multiple_global_cycles(self) -> None:
        profile = _profiler().parse_mapping_profile(_valid_log())

        self.assertEqual(
            profile["marker_counts"],
            {
                "initial_global_markers": 2,
                "iterative_global_refinement_markers": 1,
                "registration_attempts": 1,
            },
        )
        self.assertEqual(
            profile["report_totals"],
            {
                "global_bundle_adjustment": {
                    "calls": 3,
                    "iterations": 14,
                    "parameters": 26,
                    "residuals": 80,
                    "solver_seconds": 1.6,
                },
                "local_bundle_adjustment": {
                    "calls": 1,
                    "iterations": 4,
                    "parameters": 8,
                    "residuals": 20,
                    "solver_seconds": 0.4,
                },
                "pose_refinement": {
                    "calls": 1,
                    "iterations": 3,
                    "parameters": 6,
                    "residuals": 6,
                    "solver_seconds": 0.1,
                },
            },
        )
        self.assertEqual(profile["schema_version"], 1)
        self.assertEqual(profile["timing"]["observed_mapper_span_seconds"], 8.0)
        self.assertEqual(profile["timing"]["mapper_wall_seconds"], 8.0)
        self.assertEqual(profile["timing"]["global_refinement_region_seconds"], 5.0)
        self.assertEqual(profile["timing"]["bundle_adjustment_solver_seconds"], 2.0)
        self.assertEqual(profile["timing"]["global_refinement_region_share"], 0.625)
        self.assertEqual(profile["timing"]["bundle_adjustment_solver_share"], 0.25)

    def test_amdahl_math_excludes_pose_refinement(self) -> None:
        profile = _profiler().parse_mapping_profile(_valid_log())

        share = 0.25
        self.assertEqual(profile["timing"]["bundle_adjustment_solver_share"], share)
        self.assertAlmostEqual(
            profile["amdahl"]["solver_replacement_2x_speedup"],
            1 / ((1 - share) + share / 2),
        )
        self.assertAlmostEqual(
            profile["amdahl"]["solver_replacement_5x_speedup"],
            1 / ((1 - share) + share / 5),
        )
        self.assertAlmostEqual(
            profile["amdahl"]["solver_replacement_10x_speedup"],
            1 / ((1 - share) + share / 10),
        )
        self.assertAlmostEqual(
            profile["amdahl"]["infinite_solver_ceiling_speedup"],
            1 / (1 - share),
        )

    def test_external_wall_time_is_validated_with_one_millisecond_tolerance(self) -> None:
        profiler = _profiler()
        profile = profiler.parse_mapping_profile(_valid_log(), wall_seconds=7.9995)
        self.assertEqual(profile["timing"]["mapper_wall_seconds"], 7.9995)

        full_span_global_log = "\n".join(
            [
                _line("00.000000", "Global bundle adjustment"),
                *_report("01.000000", "Bundle adjustment report"),
                _line("08.000000", "Keeping successful reconstruction"),
                _line("08.000000", "Elapsed time: 0.133 [minutes]"),
            ]
        )
        rounded_profile = profiler.parse_mapping_profile(
            full_span_global_log,
            wall_seconds=7.9995,
        )
        self.assertEqual(
            rounded_profile["timing"]["global_refinement_region_share"],
            1.0,
        )

        rounded_solver_log = full_span_global_log.replace(
            "Time : 0.5 [s]",
            "Time : 7.9998 [s]",
        )
        rounded_solver_profile = profiler.parse_mapping_profile(
            rounded_solver_log,
            wall_seconds=7.9995,
        )
        self.assertEqual(
            rounded_solver_profile["timing"]["bundle_adjustment_solver_share"],
            1.0,
        )

        for wall_seconds in (True, 0.0, -1.0, math.nan, math.inf, 7.998):
            with self.subTest(wall_seconds=wall_seconds):
                with self.assertRaises(profiler.ProfileError):
                    profiler.parse_mapping_profile(
                        _valid_log(),
                        wall_seconds=wall_seconds,
                    )

    def test_reconstruction_keep_and_discard_markers_close_global_regions(self) -> None:
        profiler = _profiler()
        for marker in (
            "Keeping successful reconstruction",
            "Discarding reconstruction due to no initial pair",
        ):
            with self.subTest(marker=marker):
                log = "\n".join(
                    [
                        _line("00.000000", "Loading database"),
                        _line("01.000000", "Global bundle adjustment"),
                        *_report("01.100000", "Bundle adjustment report"),
                        _line("03.000000", marker),
                        _line("04.000000", "Elapsed time: 0.067 [minutes]"),
                    ]
                )
                profile = profiler.parse_mapping_profile(log)
                self.assertEqual(
                    profile["timing"]["global_refinement_region_seconds"],
                    2.0,
                )

    def test_consecutive_global_refinements_share_one_contiguous_region(self) -> None:
        log = "\n".join(
            [
                _line("00.000000", "Loading database"),
                _line(
                    "01.000000",
                    "Retriangulation and Global bundle adjustment",
                ),
                *_report("01.100000", "Bundle adjustment report"),
                _line(
                    "03.000000",
                    "Retriangulation and Global bundle adjustment",
                ),
                *_report("03.100000", "Bundle adjustment report"),
                _line("05.000000", "Keeping successful reconstruction"),
                _line("06.000000", "Elapsed time: 0.100 [minutes]"),
            ]
        )

        profile = _profiler().parse_mapping_profile(log)

        self.assertEqual(
            profile["marker_counts"]["iterative_global_refinement_markers"],
            2,
        )
        self.assertEqual(
            profile["report_totals"]["global_bundle_adjustment"]["calls"],
            2,
        )
        self.assertEqual(
            profile["timing"]["global_refinement_region_seconds"],
            4.0,
        )

    def test_accepts_ceres_termination_enum_names(self) -> None:
        log = "\n".join(
            [
                _line("00.000000", "Loading database"),
                _line("01.000000", "Global bundle adjustment"),
                *_report(
                    "01.100000",
                    "Bundle adjustment report",
                    termination="NO_CONVERGENCE",
                ),
                _line("03.000000", "Keeping successful reconstruction"),
                _line("04.000000", "Elapsed time: 0.067 [minutes]"),
            ]
        )

        profile = _profiler().parse_mapping_profile(log)

        self.assertEqual(
            profile["report_totals"]["global_bundle_adjustment"]["calls"],
            1,
        )

    def test_accepts_multiple_global_reports_for_one_refinement_marker(self) -> None:
        log = "\n".join(
            [
                _line("00.000000", "Loading database"),
                _line("01.000000", "Global bundle adjustment"),
                *_report("01.100000", "Bundle adjustment report"),
                *_report("02.100000", "Bundle adjustment report"),
                _line("04.000000", "Keeping successful reconstruction"),
                _line("05.000000", "Elapsed time: 0.083 [minutes]"),
            ]
        )

        profile = _profiler().parse_mapping_profile(log)

        self.assertEqual(
            profile["report_totals"]["global_bundle_adjustment"]["calls"],
            2,
        )
        self.assertEqual(profile["marker_counts"]["initial_global_markers"], 1)

    def test_rejects_malformed_incomplete_and_backwards_logs(self) -> None:
        profiler = _profiler()
        complete = _report("02.000000", "Bundle adjustment report")
        duplicate_field = complete[:2] + ["Residuals : 11"] + complete[2:]
        missing_time = [line for line in complete if "Time :" not in line]
        invalid_integer = [
            line.replace("Iterations : 2", "Iterations : many")
            for line in complete
        ]
        negative_time = [
            line.replace("Time : 0.5", "Time : -0.5") for line in complete
        ]
        nonfinite_cost = [
            line.replace("Initial cost : 1.25", "Initial cost : nan")
            for line in complete
        ]
        cases = {
            "empty": "",
            "whitespace": " \n\t",
            "unknown classification": "\n".join(
                [
                    _line("00.000000", "Loading database"),
                    *complete,
                    _line("08.000000", "Elapsed time: 0.133 [minutes]"),
                ]
            ),
            "incomplete": _single_local_report(complete[:-1]),
            "missing field": _single_local_report(missing_time),
            "duplicate field": _single_local_report(duplicate_field),
            "invalid field": _single_local_report(invalid_integer),
            "negative field": _single_local_report(negative_time),
            "nonfinite field": _single_local_report(nonfinite_cost),
            "nested report": "\n".join(
                [
                    _line("00.000000", "Registering image #2 (num_reg_frames=2)"),
                    _line("01.000000", "Pose refinement report"),
                    "Residuals : 10",
                    _line("02.000000", "Bundle adjustment report"),
                    _line("08.000000", "Elapsed time: 0.133 [minutes]"),
                ]
            ),
            "backwards timestamp": "\n".join(
                [
                    _line("05.000000", "Loading database"),
                    _line("04.000000", "Registering image #2 (num_reg_frames=2)"),
                ]
            ),
            "internal elapsed marker only": "\n".join(
                [
                    _line("00.000000", "Loading database"),
                    _line("01.000000", "Elapsed time: 0.017 [minutes]"),
                ]
            ),
            "timestamp after final elapsed marker": "\n".join(
                [
                    _line("00.000000", "Loading database"),
                    _line("01.000000", "Discarding reconstruction"),
                    _line("02.000000", "Elapsed time: 0.033 [minutes]"),
                    _line("03.000000", "Unexpected trailing work"),
                ]
            ),
            "malformed final elapsed marker": "\n".join(
                [
                    _line("00.000000", "Loading database"),
                    _line("01.000000", "Discarding reconstruction"),
                    _line("02.000000", "Elapsed time: unknown [minutes]"),
                ]
            ),
            "open global region": "\n".join(
                [
                    _line("00.000000", "Loading database"),
                    _line("01.000000", "Global bundle adjustment"),
                    *_report("02.000000", "Bundle adjustment report"),
                ]
            ),
            "nonverbose global region": "\n".join(
                [
                    _line("00.000000", "Loading database"),
                    _line("01.000000", "Global bundle adjustment"),
                    _line("03.000000", "Keeping successful reconstruction"),
                    _line("04.000000", "Elapsed time: 0.067 [minutes]"),
                ]
            ),
        }

        for name, log in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(profiler.ProfileError):
                    profiler.parse_mapping_profile(log)

    def test_nonverbose_native_log_explains_how_to_capture_solver_reports(self) -> None:
        log = "\n".join(
            [
                _line("00.000000", "Loading database"),
                _line("01.000000", "Global bundle adjustment"),
                _line("03.000000", "Keeping successful reconstruction"),
                _line("04.000000", "Elapsed time: 0.067 [minutes]"),
            ]
        )

        with self.assertRaisesRegex(
            _profiler().ProfileError,
            r"rerun .* --log_level 1",
        ):
            _profiler().parse_mapping_profile(log)

    def test_rejects_impossible_solver_and_region_shares(self) -> None:
        profiler = _profiler()
        too_much_total_solver_time = _valid_log().replace(
            "Time : 0.4 [s]",
            "Time : 9.0 [s]",
        )
        global_solver_longer_than_region = _valid_log().replace(
            "Time : 0.5 [s]",
            "Time : 6.0 [s]",
            1,
        )

        for log in (too_much_total_solver_time, global_solver_longer_than_region):
            with self.subTest():
                with self.assertRaises(profiler.ProfileError):
                    profiler.parse_mapping_profile(log)

    def test_serialized_profile_does_not_reveal_log_identifiers(self) -> None:
        profiler = _profiler()
        secret_path = "/private/example/session/capture-secret.jpg"
        secret_thread = "0xfeedface"
        extra = (
            f"I20260102 03:04:00.100000 {secret_thread} synthetic.cc:8] "
            f"Opening {secret_path}"
        )
        serialized = profiler.serialize_profile(
            profiler.parse_mapping_profile(_valid_log(extra))
        )

        self.assertNotIn(secret_path, serialized)
        self.assertNotIn("capture-secret.jpg", serialized)
        self.assertNotIn(secret_thread, serialized)
        self.assertNotIn("20260102", serialized)
        self.assertNotIn("Opening", serialized)

    def test_serialization_and_cli_stdout_and_file_output_are_deterministic(self) -> None:
        profiler = _profiler()
        log = _valid_log()
        profile = profiler.parse_mapping_profile(log, wall_seconds=12.0)
        serialized = profiler.serialize_profile(profile)
        canonical = json.dumps(
            profile,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        self.assertEqual(serialized, canonical + "\n")
        self.assertEqual(serialized.count("\n"), 1)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log_path = root / "mapper.log"
            output_path = root / "profile.json"
            log_path.write_text(log, encoding="utf-8")
            command = [
                sys.executable,
                str(Path(profiler.__file__)),
                "--log",
                str(log_path),
                "--wall-seconds",
                "12",
            ]
            stdout_run = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(stdout_run.returncode, 0, stdout_run.stderr)
            self.assertEqual(stdout_run.stderr, "")
            self.assertEqual(stdout_run.stdout, serialized)
            self.assertNotIn(str(log_path), stdout_run.stdout)

            file_run = subprocess.run(
                [*command, "--output", str(output_path)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(file_run.returncode, 0, file_run.stderr)
            self.assertEqual(file_run.stderr, "")
            self.assertEqual(file_run.stdout, "")
            self.assertEqual(output_path.read_text(encoding="utf-8"), serialized)
            self.assertNotIn(str(output_path), serialized)


if __name__ == "__main__":
    unittest.main()
