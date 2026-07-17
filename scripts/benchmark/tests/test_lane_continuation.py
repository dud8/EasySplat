#!/usr/bin/env python3
"""Regression tests for durable multi-request lane continuation."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.benchmark import easysplat_benchmark as benchmark
from scripts.benchmark import evidence_protocol as evidence
from scripts.benchmark import run_lane
from scripts.benchmark.tests.test_benchmark import (
    evidence_machine,
    evidence_request,
    runner_identities,
)


LANE = evidence.LANE_REFERENCE


class LaneContinuationTests(unittest.TestCase):
    def test_first_outcome_does_not_prevent_later_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            requests = {
                ("orbit-01", 30, LANE): evidence_request(
                    scene_id="orbit-01", scale=30, lane=LANE
                ),
                ("orbit-02", 30, LANE): evidence_request(
                    scene_id="orbit-02", scale=30, lane=LANE
                ),
            }
            runner = runner_identities()[LANE]
            measured_machine = evidence_machine(LANE)
            executions: list[tuple[str, int, str]] = []

            def attempt(*_: object, completed_collections: dict[tuple[str, int, str], dict[str, object]]) -> dict[str, object]:
                for key, request in requests.items():
                    if key in completed_collections:
                        continue
                    executions.append(key)
                    scene_id, scale, lane = key
                    artifact_root = output / "evidence" / scene_id / str(scale) / lane
                    artifact_root.mkdir(parents=True)
                    if scene_id == "orbit-01":
                        status_path = run_lane._write_collector_outcome(
                            artifact_root=artifact_root,
                            request=request,
                            lane=lane,
                            runner_identity=runner,
                            machine=measured_machine,
                            kind="execution_failed",
                            reason="nonzero_exit",
                            exit_code=70,
                        )
                        raise run_lane._CollectedOutcome(
                            "first request failed",
                            scene_id=scene_id,
                            scale=scale,
                            lane=lane,
                            status_path=status_path,
                            request=request,
                            runner_identity=runner,
                            machine=measured_machine,
                        )
                    status_path = run_lane._write_collector_status(
                        artifact_root=artifact_root,
                        request=request,
                        lane=lane,
                        runner_identity=runner,
                        machine=measured_machine,
                        disposition="attestation_candidate",
                        outcome=None,
                    )
                    second = run_lane._collection_from_status(
                        output_root=output,
                        status_path=status_path,
                        scene_id=scene_id,
                        scale=scale,
                        lane=lane,
                        request=request,
                        runner_identity=runner,
                        machine=measured_machine,
                        expected_relative=Path("evidence") / scene_id / str(scale) / lane / "collector-status.json",
                    )
                    completed_collections[key] = second
                    return {
                        "schema_version": 1,
                        "lane": lane,
                        "machine": measured_machine,
                        "git_commit": request["binding"]["git_commit"],
                        "corpus_digest": request["binding"]["corpus_digest"],
                        "thresholds_digest": request["binding"]["thresholds_digest"],
                        "toolchain_identity": request["binding"]["toolchain_identity"],
                        "producer_digest": evidence.sha256_file(
                            Path(run_lane.__file__).resolve().with_name("evidence_protocol.py")
                        ),
                        "runner_identity": runner,
                        "rendering_driver_identity": request["rendering_driver_identity"],
                        "collections": [completed_collections[("orbit-01", 30, LANE)], second],
                    }
                raise AssertionError("attempt had no uncompleted request")

            arguments = [Path("unused")] * 7 + [output, LANE, Path("runner"), Path("renderer")]
            with mock.patch.object(run_lane, "_run_lane_attempt", side_effect=attempt):
                result = run_lane.run_lane(*arguments)

            self.assertEqual(
                executions,
                [("orbit-01", 30, LANE), ("orbit-02", 30, LANE)],
                "each selected request must execute exactly once",
            )
            self.assertEqual(
                [(item["scene_id"], item["scale"], item["lane"]) for item in result["collections"]],
                [("orbit-01", 30, LANE), ("orbit-02", 30, LANE)],
            )
            lane_path = output / f"lane-{LANE}.json"
            self.assertTrue(lane_path.is_file())
            stored = json.loads(lane_path.read_text(encoding="utf-8"))
            self.assertEqual(stored["collections"], result["collections"])

    def test_success_prefix_survives_a_later_outcome_and_keeps_exact_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            keys = [(f"orbit-{index:02d}", 30, LANE) for index in range(1, 4)]
            requests = {
                key: evidence_request(scene_id=key[0], scale=key[1], lane=key[2])
                for key in keys
            }
            runner = runner_identities()[LANE]
            measured_machine = evidence_machine(LANE)
            executions: list[tuple[str, int, str]] = []

            def attempt(*_: object, completed_collections: dict[tuple[str, int, str], dict[str, object]]) -> dict[str, object]:
                for key in keys:
                    if key in completed_collections:
                        continue
                    executions.append(key)
                    scene_id, scale, lane = key
                    request = requests[key]
                    artifact_root = output / "evidence" / scene_id / str(scale) / lane
                    artifact_root.mkdir(parents=True)
                    if scene_id == "orbit-02":
                        status_path = run_lane._write_collector_outcome(
                            artifact_root=artifact_root,
                            request=request,
                            lane=lane,
                            runner_identity=runner,
                            machine=measured_machine,
                            kind="execution_failed",
                            reason="nonzero_exit",
                            exit_code=70,
                        )
                        raise run_lane._CollectedOutcome(
                            "middle request failed",
                            scene_id=scene_id,
                            scale=scale,
                            lane=lane,
                            status_path=status_path,
                            request=request,
                            runner_identity=runner,
                            machine=measured_machine,
                        )
                    status_path = run_lane._write_collector_status(
                        artifact_root=artifact_root,
                        request=request,
                        lane=lane,
                        runner_identity=runner,
                        machine=measured_machine,
                        disposition="attestation_candidate",
                        outcome=None,
                    )
                    relative = Path("evidence") / scene_id / str(scale) / lane / "collector-status.json"
                    completed_collections[key] = run_lane._collection_from_status(
                        output_root=output,
                        status_path=status_path,
                        scene_id=scene_id,
                        scale=scale,
                        lane=lane,
                        request=request,
                        runner_identity=runner,
                        machine=measured_machine,
                        expected_relative=relative,
                    )
                last_request = requests[keys[-1]]
                return {
                    "schema_version": 1,
                    "lane": LANE,
                    "machine": measured_machine,
                    "git_commit": last_request["binding"]["git_commit"],
                    "corpus_digest": last_request["binding"]["corpus_digest"],
                    "thresholds_digest": last_request["binding"]["thresholds_digest"],
                    "toolchain_identity": last_request["binding"]["toolchain_identity"],
                    "producer_digest": evidence.sha256_file(
                        Path(run_lane.__file__).resolve().with_name("evidence_protocol.py")
                    ),
                    "runner_identity": runner,
                    "rendering_driver_identity": last_request["rendering_driver_identity"],
                    "collections": [completed_collections[key] for key in keys],
                }

            arguments = [Path("unused")] * 7 + [output, LANE, Path("runner"), Path("renderer")]
            with mock.patch.object(run_lane, "_run_lane_attempt", side_effect=attempt):
                result = run_lane.run_lane(*arguments)

            self.assertEqual(executions, keys)
            self.assertEqual(
                [(item["scene_id"], item["scale"], item["lane"]) for item in result["collections"]],
                keys,
            )
            stored = json.loads(
                (output / f"lane-{LANE}.json").read_text(encoding="utf-8")
            )
            self.assertEqual(stored["collections"], result["collections"])

    def test_preexisting_artifact_root_fails_closed_without_deletion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            artifact = output / "evidence/scene/30" / LANE
            artifact.mkdir(parents=True)
            marker = artifact / "untrusted.txt"
            marker.write_text("keep for inspection", encoding="utf-8")
            with self.assertRaisesRegex(benchmark.ConfigError, "already exists"):
                run_lane._prepare_artifact_root(output, Path("evidence/scene"), 30, LANE)
            self.assertEqual(marker.read_text(encoding="utf-8"), "keep for inspection")

    def test_collector_status_rejects_tamper_hardlink_and_symlink(self) -> None:
        mutations = ("tamper", "hardlink", "symlink")
        for mutation in mutations:
            with self.subTest(mutation), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "output"
                request = evidence_request(scene_id="orbit-01", scale=30, lane=LANE)
                runner = runner_identities()[LANE]
                measured_machine = evidence_machine(LANE)
                artifact = output / "evidence/orbit-01/30" / LANE
                artifact.mkdir(parents=True)
                status = run_lane._write_collector_outcome(
                    artifact_root=artifact,
                    request=request,
                    lane=LANE,
                    runner_identity=runner,
                    machine=measured_machine,
                    kind="execution_failed",
                    reason="nonzero_exit",
                    exit_code=70,
                )
                expected = Path("evidence/orbit-01/30") / LANE / "collector-status.json"
                descriptor = run_lane._collection_from_status(
                    output_root=output,
                    status_path=status,
                    scene_id="orbit-01",
                    scale=30,
                    lane=LANE,
                    request=request,
                    runner_identity=runner,
                    machine=measured_machine,
                    expected_relative=expected,
                )
                if mutation == "tamper":
                    status.write_bytes(status.read_bytes() + b" ")
                elif mutation == "hardlink":
                    os.link(status, Path(temporary) / "status-link")
                else:
                    original = Path(temporary) / "status-original"
                    status.rename(original)
                    status.symlink_to(original)
                with self.assertRaises(benchmark.ConfigError):
                    run_lane._validate_completed_collection(
                        descriptor,
                        output_root=output,
                        expected_relative=expected,
                        scene_id="orbit-01",
                        scale=30,
                        lane=LANE,
                        request=request,
                        runner_identity=runner,
                        machine=measured_machine,
                    )

    def test_duplicate_selected_keys_are_rejected_before_execution(self) -> None:
        entry = {"scene_id": "orbit-01", "scale": 30, "lane": LANE}
        with self.assertRaisesRegex(benchmark.ConfigError, "duplicates"):
            run_lane._selected_lane_entries([entry, dict(entry)], LANE)


if __name__ == "__main__":
    unittest.main()
