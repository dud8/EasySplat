#!/usr/bin/env python3
"""Regression tests for durable multi-request lane continuation."""

from __future__ import annotations

import copy
import json
import os
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

from scripts.benchmark import easysplat_benchmark as benchmark
from scripts.benchmark import evidence_protocol as evidence
from scripts.benchmark import run_lane
from scripts.benchmark.tests.test_benchmark import (
    evidence_machine,
    evidence_request,
    runner_identities,
    valid_reference_config,
    valid_scene,
)


LANE = evidence.LANE_REFERENCE


class _RestartFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.output = root / "output"
        self.requests_root = root / "requests"
        self.corpus_path = root / "corpus" / "corpus.json"
        self.reference_config_path = root / "reference-config.json"
        self.index_path = root / "index.json"
        self.toolchain_root = root / "toolchain"
        self.baseline_checkout_root = root / "baseline-checkout"
        self.baseline_toolchain_root = root / "baseline-toolchain"
        self.runner_path = root / "runner"
        self.renderer_closure_path = root / "renderer-closure.json"
        self.commit = "4" * 40
        self.toolchain_identity = "sha256:" + "5" * 64
        self.contract_digest = "sha256:" + "6" * 64
        self.machine = evidence_machine(LANE)
        identities = runner_identities()
        self.runner_identity = identities[LANE]
        self.renderer_identity = identities[evidence.RENDERING_DRIVER_IDENTITY]

        scene = valid_scene(adapter="protected-evidence")
        scene["scale_lanes"] = [30]
        scene["aggregate_scale"] = 30
        self.corpus = {
            "schema_version": 1,
            "manifest_profile": "release",
            "scenes": [scene],
        }
        self.reference_config = valid_reference_config()
        corpus_digest = benchmark.sha256_json(self.corpus)
        thresholds_digest = benchmark.sha256_json(self.reference_config)

        media_path = self.corpus_path.parent / scene["input"]["media_path"]
        media_path.parent.mkdir(parents=True)
        media_path.write_bytes(b"restart fixture\n")
        input_digest = benchmark.digest_input(
            media_path,
            trusted_root=self.corpus_path.parent,
        )
        identity = benchmark.RunIdentity(
            profile="release",
            corpus_digest=corpus_digest,
            thresholds_digest=thresholds_digest,
            git_commit=self.commit,
            app_version=benchmark.APP_VERSION,
            toolchain_identity=self.toolchain_identity,
        )
        self.request = benchmark._evidence_request(
            scene,
            30,
            LANE,
            identity,
            input_digest,
            self.renderer_identity,
            self.contract_digest,
        )
        request_relative = Path("orbit-01/30") / f"{LANE}.request.json"
        request_path = self.requests_root / request_relative
        request_path.parent.mkdir(parents=True)
        request_path.write_bytes(evidence.canonical_json_bytes(self.request) + b"\n")

        baseline = benchmark.APPROVED_PAIRED_BASELINE
        self.index = {
            "schema_version": 2,
            "producer_protocol": evidence.PROTOCOL_VERSION,
            "producer_version": evidence.PRODUCER_VERSION,
            "producer_digest": evidence.sha256_file(
                Path(run_lane.__file__).resolve().with_name("evidence_protocol.py")
            ),
            "corpus_digest": corpus_digest,
            "thresholds_digest": thresholds_digest,
            "git_commit": self.commit,
            "app_version": benchmark.APP_VERSION,
            "toolchain_identity": self.toolchain_identity,
            "baseline_git_commit": baseline["git_commit"],
            "baseline_toolchain_identity": baseline["toolchain_identity"],
            "baseline_configuration_digest": benchmark.sha256_json(
                baseline["run_configuration"]
            ),
            "baseline_run_configuration": baseline["run_configuration"],
            "benchmark_contract_sha256": self.contract_digest,
            "corpus_manifest": "corpus.json",
            "corpus_manifest_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(self.corpus) + b"\n"
            ),
            "reference_config": "reference-config.json",
            "reference_config_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(self.reference_config) + b"\n"
            ),
            "runner_identities": identities,
            "requests": [
                {
                    "scene_id": "orbit-01",
                    "scale": 30,
                    "lane": LANE,
                    "request": request_relative.as_posix(),
                    "media_path": scene["input"]["media_path"],
                    "evidence_path": scene["adapter"]["evidence_path"],
                    "producer_command": ["restart-fixture"],
                }
            ],
        }
        self.corpus_path.parent.mkdir(parents=True, exist_ok=True)
        self.corpus_path.write_bytes(evidence.canonical_json_bytes(self.corpus) + b"\n")
        self.reference_config_path.write_bytes(
            evidence.canonical_json_bytes(self.reference_config) + b"\n"
        )
        self.index_path.write_bytes(evidence.canonical_json_bytes(self.index) + b"\n")

    @property
    def arguments(self) -> tuple[object, ...]:
        return (
            self.index_path,
            self.requests_root,
            self.corpus_path,
            self.reference_config_path,
            self.toolchain_root,
            self.baseline_checkout_root,
            self.baseline_toolchain_root,
            self.output,
            LANE,
            self.runner_path,
            self.renderer_closure_path,
        )

    def enter_preflight_patches(self, stack: ExitStack) -> None:
        stack.enter_context(mock.patch.object(benchmark, "validate_corpus"))
        stack.enter_context(mock.patch.object(benchmark, "validate_reference_config"))
        stack.enter_context(
            mock.patch.object(
                benchmark,
                "validate_request_index",
                return_value=self.index,
            )
        )
        stack.enter_context(
            mock.patch.object(
                benchmark,
                "collect_git_state",
                return_value={"commit": self.commit},
            )
        )
        stack.enter_context(
            mock.patch.object(
                benchmark,
                "resolved_toolchain_identity",
                return_value=self.toolchain_identity,
            )
        )
        stack.enter_context(
            mock.patch.object(
                evidence,
                "collect_machine_metadata",
                return_value=self.machine,
            )
        )
        stack.enter_context(
            mock.patch.object(run_lane, "_require_runner", return_value=self.runner_path)
        )
        stack.enter_context(
            mock.patch.object(
                run_lane,
                "_verify_candidate_checkout",
                return_value=self.root,
            )
        )
        stack.enter_context(
            mock.patch.object(
                run_lane,
                "_verify_baseline_checkout",
                return_value=self.baseline_checkout_root,
            )
        )
        stack.enter_context(
            mock.patch.object(
                run_lane,
                "_verify_baseline_toolchain",
                return_value=(
                    self.baseline_toolchain_root,
                    self.index["baseline_toolchain_identity"],
                ),
            )
        )
        stack.enter_context(mock.patch.object(run_lane, "_verify_runner_digest"))
        stack.enter_context(mock.patch.object(run_lane, "_verify_renderer_closure"))


class LaneContinuationTests(unittest.TestCase):
    def test_terminal_status_survives_process_restart_without_rerunning(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            fixture = _RestartFixture(Path(temporary))
            fixture.enter_preflight_patches(stack)
            original_prepare = run_lane._prepare_artifact_root
            executions = 0

            def interrupt_after_terminal_status(
                output_root: Path,
                relative: Path,
                scale: int,
                lane: str,
            ) -> Path:
                nonlocal executions
                artifact_root = original_prepare(output_root, relative, scale, lane)
                executions += 1
                run_lane._write_collector_outcome(
                    artifact_root=artifact_root,
                    request=fixture.request,
                    lane=lane,
                    runner_identity=fixture.runner_identity,
                    machine=fixture.machine,
                    kind="execution_failed",
                    reason="nonzero_exit",
                    exit_code=70,
                )
                raise SystemExit(99)

            stack.enter_context(
                mock.patch.object(
                    run_lane,
                    "_prepare_artifact_root",
                    side_effect=interrupt_after_terminal_status,
                )
            )
            with self.assertRaisesRegex(SystemExit, "99"):
                run_lane.run_lane(*fixture.arguments)

            result = run_lane.run_lane(*fixture.arguments)

            self.assertEqual(executions, 1)
            self.assertEqual(
                [
                    (item["scene_id"], item["scale"], item["lane"])
                    for item in result["collections"]
                ],
                [("orbit-01", 30, LANE)],
            )
            self.assertEqual(
                result["collections"][0]["collector_status"],
                (
                    Path("external/orbit-01.evidence/30")
                    / LANE
                    / "collector-status.json"
                ).as_posix(),
            )

    def test_restart_rejects_partial_foreign_and_stale_artifact_roots(self) -> None:
        mutations = (
            "partial",
            "foreign_lane",
            "foreign_runner",
            "foreign_machine",
            "foreign_collector",
            "stale_commit",
            "stale_corpus",
            "stale_input",
            "stale_thresholds",
            "stale_toolchain",
        )
        for mutation in mutations:
            with (
                self.subTest(mutation),
                tempfile.TemporaryDirectory() as temporary,
                ExitStack() as stack,
            ):
                fixture = _RestartFixture(Path(temporary))
                fixture.enter_preflight_patches(stack)
                original_prepare = run_lane._prepare_artifact_root
                executions = 0

                def interrupt_with_untrusted_root(
                    output_root: Path,
                    relative: Path,
                    scale: int,
                    lane: str,
                ) -> Path:
                    nonlocal executions
                    artifact_root = original_prepare(output_root, relative, scale, lane)
                    executions += 1
                    if mutation != "partial":
                        request = copy.deepcopy(fixture.request)
                        runner_identity = copy.deepcopy(fixture.runner_identity)
                        machine = copy.deepcopy(fixture.machine)
                        status_lane = lane
                        if mutation == "foreign_lane":
                            status_lane = evidence.LANE_CONSTRAINED
                        elif mutation == "foreign_runner":
                            runner_identity["sha256"] = "sha256:" + "7" * 64
                        elif mutation == "foreign_machine":
                            machine["hardware_model"] = "Mac16,6"
                        elif mutation.startswith("stale_"):
                            field = {
                                "stale_commit": "git_commit",
                                "stale_corpus": "corpus_digest",
                                "stale_input": "input_digest",
                                "stale_thresholds": "thresholds_digest",
                                "stale_toolchain": "toolchain_identity",
                            }[mutation]
                            request["binding"][field] = (
                                "8" * 40
                                if field == "git_commit"
                                else "sha256:" + "8" * 64
                            )

                        def write_status() -> None:
                            run_lane._write_collector_outcome(
                                artifact_root=artifact_root,
                                request=request,
                                lane=status_lane,
                                runner_identity=runner_identity,
                                machine=machine,
                                kind="execution_failed",
                                reason="nonzero_exit",
                                exit_code=70,
                            )

                        if mutation == "foreign_collector":
                            collector = run_lane._collector_identity()
                            collector["sha256"] = "sha256:" + "9" * 64
                            with mock.patch.object(
                                run_lane,
                                "_collector_identity",
                                return_value=collector,
                            ):
                                write_status()
                        else:
                            write_status()
                    raise SystemExit(99)

                stack.enter_context(
                    mock.patch.object(
                        run_lane,
                        "_prepare_artifact_root",
                        side_effect=interrupt_with_untrusted_root,
                    )
                )
                with self.assertRaises(SystemExit):
                    run_lane.run_lane(*fixture.arguments)
                with self.assertRaises(benchmark.ConfigError):
                    run_lane.run_lane(*fixture.arguments)
                self.assertEqual(executions, 1)

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

    def test_collector_status_rejects_descriptor_tamper_hardlink_and_symlink(self) -> None:
        mutations = ("descriptor", "tamper", "hardlink", "symlink")
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
                if mutation == "descriptor":
                    descriptor["sha256"] = "sha256:" + "0" * 64
                elif mutation == "tamper":
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

    def test_collector_status_rejects_symlinked_output_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "output"
            request = evidence_request(scene_id="orbit-01", scale=30, lane=LANE)
            runner = runner_identities()[LANE]
            measured_machine = evidence_machine(LANE)
            artifact = output / "evidence/orbit-01/30" / LANE
            artifact.mkdir(parents=True)
            run_lane._write_collector_outcome(
                artifact_root=artifact,
                request=request,
                lane=LANE,
                runner_identity=runner,
                machine=measured_machine,
                kind="execution_failed",
                reason="nonzero_exit",
                exit_code=70,
            )
            alias = root / "output-alias"
            alias.symlink_to(output, target_is_directory=True)
            expected = Path("evidence/orbit-01/30") / LANE / "collector-status.json"

            with self.assertRaisesRegex(benchmark.ConfigError, "output root"):
                run_lane._collection_from_status(
                    output_root=alias,
                    status_path=alias / expected,
                    scene_id="orbit-01",
                    scale=30,
                    lane=LANE,
                    request=request,
                    runner_identity=runner,
                    machine=measured_machine,
                    expected_relative=expected,
                )

    def test_duplicate_selected_keys_are_rejected_before_execution(self) -> None:
        entry = {"scene_id": "orbit-01", "scale": 30, "lane": LANE}
        with self.assertRaisesRegex(benchmark.ConfigError, "duplicates"):
            run_lane._selected_lane_entries([entry, dict(entry)], LANE)


if __name__ == "__main__":
    unittest.main()
