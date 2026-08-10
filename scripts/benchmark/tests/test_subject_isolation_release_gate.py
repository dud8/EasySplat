from __future__ import annotations

import copy
import importlib.util
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = (
    ROOT / "scripts" / "benchmark" / "validate_subject_isolation_results.py"
)
SPEC = importlib.util.spec_from_file_location(
    "validate_subject_isolation_results", MODULE_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load subject isolation validator at {MODULE_PATH}")
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)


def valid_results() -> dict[str, object]:
    captures: list[dict[str, object]] = []
    for index in range(15):
        digest = f"sha256:{index + 1:064x}"
        identity = {"sha256": digest, "byte_count": 1_000_000 + index}
        captures.append(
            {
                "capture_id": f"capture-{index + 1:02d}",
                "outcome": "automatic_correct",
                "source_gaussian_count": 500_000,
                "isolation_seconds": 10.0,
                "incremental_unified_memory_bytes": 4_000_000_000,
                "held_out_iou": 0.85,
                "boundary_f1": 0.80,
                "canonical_ply_before": identity,
                "canonical_ply_after": copy.deepcopy(identity),
            }
        )
    return {
        "schema_version": 1,
        "hardware": {
            "chip": "Apple M4 Max",
            "memory_bytes": 48 * 1024**3,
        },
        "timings_exclude_first_toolchain_installation": True,
        "captures": captures,
    }


class SubjectIsolationReleaseGateTests(unittest.TestCase):
    def test_accepts_results_that_clear_every_release_gate(self) -> None:
        summary = subject.validate_results(valid_results())

        self.assertEqual(summary.capture_count, 15)
        self.assertEqual(summary.accepted_count, 15)
        self.assertAlmostEqual(summary.mean_held_out_iou, 0.85)
        self.assertAlmostEqual(summary.p10_held_out_iou, 0.85)
        self.assertAlmostEqual(summary.mean_boundary_f1, 0.80)
        self.assertAlmostEqual(summary.p50_seconds, 10.0)
        self.assertAlmostEqual(summary.p95_seconds, 10.0)

    def test_requires_at_least_fifteen_captures_and_one_accepted_output(self) -> None:
        too_small = valid_results()
        too_small["captures"] = too_small["captures"][:14]
        with self.assertRaisesRegex(subject.GateFailure, "at least 15 captures"):
            subject.validate_results(too_small)

        no_accepted = valid_results()
        for capture in no_accepted["captures"]:
            capture["outcome"] = "refused"
            capture.pop("held_out_iou")
            capture.pop("boundary_f1")
        with self.assertRaisesRegex(subject.GateFailure, "accepted output"):
            subject.validate_results(no_accepted)

    def test_rejects_any_wrong_automatic_selection(self) -> None:
        results = valid_results()
        results["captures"][4]["outcome"] = "wrong_automatic"

        with self.assertRaisesRegex(
            subject.GateFailure, "wrong automatic selection"
        ):
            subject.validate_results(results)

    def test_enforces_quality_gates_for_accepted_outputs(self) -> None:
        cases = (
            ("mean held-out IoU", "held_out_iou", [0.79] * 15),
            (
                "10th-percentile held-out IoU",
                "held_out_iou",
                [0.60, 0.60, 0.60] + [0.90] * 12,
            ),
            ("mean boundary F1", "boundary_f1", [0.74] * 15),
        )
        for expected, field, values in cases:
            with self.subTest(expected=expected):
                results = valid_results()
                for capture, value in zip(results["captures"], values):
                    capture[field] = value
                with self.assertRaisesRegex(subject.GateFailure, expected):
                    subject.validate_results(results)

    def test_enforces_performance_gates_only_up_to_five_hundred_thousand_gaussians(
        self,
    ) -> None:
        cases = (
            ("p50 isolation time", "isolation_seconds", [16.0] * 15),
            (
                "p95 isolation time",
                "isolation_seconds",
                [10.0] * 13 + [31.0, 31.0],
            ),
            (
                "incremental unified memory",
                "incremental_unified_memory_bytes",
                [8 * 1024**3 + 1] + [4_000_000_000] * 14,
            ),
        )
        for expected, field, values in cases:
            with self.subTest(expected=expected):
                results = valid_results()
                for capture, value in zip(results["captures"], values):
                    capture[field] = value
                with self.assertRaisesRegex(subject.GateFailure, expected):
                    subject.validate_results(results)

        oversized = valid_results()
        for capture in oversized["captures"]:
            capture["source_gaussian_count"] = 500_001
            capture["isolation_seconds"] = 90.0
            capture["incremental_unified_memory_bytes"] = 12 * 1024**3
        with self.assertRaisesRegex(subject.GateFailure, "performance capture"):
            subject.validate_results(oversized)

    def test_requires_canonical_ply_digest_and_byte_identity_for_every_case(
        self,
    ) -> None:
        for field, value in (
            ("sha256", "sha256:" + "f" * 64),
            ("byte_count", 999),
        ):
            with self.subTest(field=field):
                results = valid_results()
                results["captures"][7]["canonical_ply_after"][field] = value
                with self.assertRaisesRegex(
                    subject.GateFailure, "canonical PLY changed"
                ):
                    subject.validate_results(results)

    def test_requires_the_reference_host_and_excludes_first_installation(self) -> None:
        mutations = (
            (
                "Apple M4 Max",
                lambda results: results["hardware"].update(chip="Apple M3 Max"),
            ),
            (
                "48 GiB",
                lambda results: results["hardware"].update(
                    memory_bytes=36 * 1024**3
                ),
            ),
            (
                "first toolchain installation",
                lambda results: results.update(
                    timings_exclude_first_toolchain_installation=False
                ),
            ),
        )
        for expected, mutate in mutations:
            with self.subTest(expected=expected):
                results = valid_results()
                mutate(results)
                with self.assertRaisesRegex(subject.ResultFormatError, expected):
                    subject.validate_results(results)

    def test_rejects_invalid_schema_types_and_nonfinite_numbers(self) -> None:
        mutations = (
            ("schema_version", lambda results: results.update(schema_version=True)),
            (
                "source_gaussian_count",
                lambda results: results["captures"][0].update(
                    source_gaussian_count=True
                ),
            ),
            (
                "isolation_seconds",
                lambda results: results["captures"][0].update(
                    isolation_seconds=math.nan
                ),
            ),
            (
                "held_out_iou",
                lambda results: results["captures"][0].update(
                    held_out_iou=math.inf
                ),
            ),
            (
                "sha256",
                lambda results: results["captures"][0][
                    "canonical_ply_before"
                ].update(sha256="not-a-digest"),
            ),
        )
        for expected, mutate in mutations:
            with self.subTest(expected=expected):
                results = valid_results()
                mutate(results)
                with self.assertRaisesRegex(subject.ResultFormatError, expected):
                    subject.validate_results(results)

    def test_cli_reports_success_and_gate_failures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "results.json"
            path.write_text(json.dumps(valid_results()), encoding="utf-8")
            passed = subprocess.run(
                [sys.executable, str(MODULE_PATH), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn("Subject isolation release gates passed", passed.stdout)

            failed_results = valid_results()
            failed_results["captures"][0]["outcome"] = "wrong_automatic"
            path.write_text(json.dumps(failed_results), encoding="utf-8")
            failed = subprocess.run(
                [sys.executable, str(MODULE_PATH), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(failed.returncode, 1)
            self.assertIn("wrong automatic selection", failed.stderr)


if __name__ == "__main__":
    unittest.main()
