#!/usr/bin/env python3
"""Adversarial tests for compact, unsigned benchmark aggregation."""

from __future__ import annotations

import copy
import contextlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.benchmark import aggregate_evidence as aggregate
from scripts.benchmark import easysplat_benchmark as benchmark
from scripts.benchmark import evidence_protocol as evidence
from scripts.benchmark.tests.test_benchmark import (
    evidence_machine,
    evidence_request,
    raw_observations,
    runner_identity,
    runner_identities,
    write_evidence_artifacts,
)


DIGEST = "sha256:" + "1" * 64
COMMIT = "1" * 40


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(evidence.canonical_json_bytes(value) + b"\n")


def descriptor(path: Path, root: Path) -> dict[str, object]:
    metadata = path.stat()
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": evidence.sha256_file(path),
        "bytes": metadata.st_size,
    }


class PreparedRootFixture:
    def __init__(self, base: Path, lane: str) -> None:
        self.root = base / lane
        self.lane = lane
        self.root.mkdir(parents=True)
        request_relative = Path("scene-01") / "30" / f"{lane}.request.json"
        artifact_relative = Path("external/scene-01/evidence") / "30" / lane
        self.request_path = self.root / "requests" / request_relative
        self.prepared_path = self.root / artifact_relative / "evidence.json"
        for name, value in (
            ("requests/index.json", {}),
            ("requests/corpus.json", {}),
            ("requests/reference-config.json", {}),
            ((Path("requests") / request_relative).as_posix(), {}),
            ((artifact_relative / "evidence.json").as_posix(), {}),
        ):
            write_json(self.root / name, value)
        self.record: dict[str, object] = {
            "scene_id": "scene-01",
            "scale": 30,
            "lane": lane,
            "request": descriptor(self.request_path, self.root),
            "request_sha256": evidence.sha256_file(self.request_path),
            "artifact_root": artifact_relative.as_posix(),
            "collector_status_sha256": DIGEST,
            "machine": evidence_machine(lane),
            "measurement_runner": runner_identity(lane),
            "disposition": "attestation_candidate",
            "outcome": None,
            "prepared": descriptor(self.prepared_path, self.prepared_path.parent),
        }
        self.lane_result = {
            "schema_version": 1,
            "lane": lane,
            "machine": evidence_machine(lane),
            "git_commit": COMMIT,
            "corpus_digest": DIGEST,
            "thresholds_digest": DIGEST,
            "toolchain_identity": DIGEST,
            "producer_digest": DIGEST,
            "runner_identity": runner_identity(lane),
            "rendering_driver_identity": runner_identity(
                evidence.RENDERING_DRIVER_IDENTITY
            ),
            "collections": [
                {
                    "scene_id": "scene-01",
                    "scale": 30,
                    "lane": lane,
                    "collector_status": (artifact_relative / "collector-status.json").as_posix(),
                    "sha256": DIGEST,
                }
            ],
            "collection_started_at_utc": "2026-07-15T12:00:00Z",
            "collection_ended_at_utc": "2026-07-15T12:01:00Z",
        }
        write_json(self.root / "lane-result.json", self.lane_result)
        self.index: dict[str, object] = {
            "schema_version": 2,
            "lane": lane,
            "git_commit": COMMIT,
            "protocol_version": evidence.PROTOCOL_VERSION,
            "app_version": benchmark.APP_VERSION,
            "toolchain_identity": DIGEST,
            "benchmark_contract_sha256": DIGEST,
            "collection_started_at_utc": "2026-07-15T12:00:00Z",
            "collection_ended_at_utc": "2026-07-15T12:01:00Z",
            "sources": {
                "evidence_protocol": aggregate._source_identity(
                    evidence.PRODUCER_RELATIVE_PATH,
                    evidence.PRODUCER_VERSION,
                ),
                "collector": aggregate._source_identity(
                    aggregate.COLLECTOR_RELATIVE_PATH,
                    aggregate.COLLECTOR_VERSION,
                ),
                "preparer": aggregate._source_identity(
                    aggregate.PREPARER_RELATIVE_PATH,
                    aggregate.PREPARER_VERSION,
                ),
            },
            "request_index": descriptor(self.root / "requests/index.json", self.root),
            "corpus_manifest": descriptor(self.root / "requests/corpus.json", self.root),
            "reference_config": descriptor(
                self.root / "requests/reference-config.json", self.root
            ),
            "lane_result": descriptor(self.root / "lane-result.json", self.root),
            "records": [self.record],
        }
        self.write_index()

    def write_index(self) -> None:
        path = self.root / aggregate.PREPARED_INDEX_NAME
        if path.exists() or path.is_symlink():
            path.unlink()
        write_json(path, self.index)


class AggregateEvidenceTests(unittest.TestCase):
    def make_roots(self, base: Path) -> dict[str, PreparedRootFixture]:
        return {lane: PreparedRootFixture(base, lane) for lane in aggregate.RELEASE_LANES}

    def test_release_aggregation_requires_a_clean_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            subprocess.run(
                ["/usr/bin/git", "init", "--quiet", str(repository)],
                check=True,
            )
            tracked = repository / "tracked.txt"
            tracked.write_text("clean\n", encoding="utf-8")
            subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "add", "tracked.txt"],
                check=True,
            )
            subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(repository),
                    "-c",
                    "user.name=EasySplat Tests",
                    "-c",
                    "user.email=tests@easysplat.invalid",
                    "commit",
                    "--quiet",
                    "-m",
                    "fixture",
                ],
                check=True,
            )
            aggregate._require_clean_worktree(repository)

            untracked = repository / "untracked.txt"
            untracked.write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(aggregate.AggregationError, "dirty Git worktree"):
                aggregate._require_clean_worktree(repository)
            untracked.unlink()

            tracked.write_text("changed\n", encoding="utf-8")
            with self.assertRaisesRegex(aggregate.AggregationError, "dirty Git worktree"):
                aggregate._require_clean_worktree(repository)

    def test_prepared_roots_require_exact_distinct_lane_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixtures = self.make_roots(Path(temporary))
            roots, indexes = aggregate._load_prepared_roots(
                [fixture.root for fixture in fixtures.values()]
            )
            self.assertEqual(set(roots), set(aggregate.RELEASE_LANES))
            self.assertEqual(set(indexes), set(aggregate.RELEASE_LANES))

            with self.assertRaisesRegex(aggregate.AggregationError, "exactly one"):
                aggregate._load_prepared_roots(list(roots.values())[:2])

            duplicate = fixtures[evidence.LANE_EIGHT_GB]
            duplicate.index["lane"] = evidence.LANE_REFERENCE
            duplicate.record["lane"] = evidence.LANE_REFERENCE
            duplicate.lane_result["lane"] = evidence.LANE_REFERENCE
            duplicate.lane_result["collections"][0]["lane"] = evidence.LANE_REFERENCE
            write_json(duplicate.root / "lane-result.json", duplicate.lane_result)
            duplicate.index["lane_result"] = descriptor(
                duplicate.root / "lane-result.json", duplicate.root
            )
            duplicate.write_index()
            with self.assertRaisesRegex(aggregate.AggregationError, "duplicate lane"):
                aggregate._load_prepared_roots(
                    [fixture.root for fixture in fixtures.values()]
                )

    def test_compact_tree_rejects_extra_file_symlink_and_hardlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = PreparedRootFixture(Path(temporary), evidence.LANE_REFERENCE)
            expected = aggregate._expected_tree_files(fixture.index)
            aggregate._scan_compact_tree(fixture.root, expected)

            extra = fixture.root / "raw-output.ply"
            extra.write_bytes(b"ply\n")
            with self.assertRaisesRegex(aggregate.AggregationError, "unexpected"):
                aggregate._scan_compact_tree(fixture.root, expected)
            extra.unlink()

            hardlink = fixture.root / "linked.json"
            os.link(fixture.root / aggregate.PREPARED_INDEX_NAME, hardlink)
            with self.assertRaisesRegex(aggregate.AggregationError, "unsafe file"):
                aggregate._scan_compact_tree(fixture.root, expected | {Path("linked.json")})
            hardlink.unlink()

            target = fixture.root / "target.json"
            write_json(target, {})
            symlink = fixture.root / "symlink.json"
            symlink.symlink_to(target)
            with self.assertRaisesRegex(aggregate.AggregationError, "symbolic link"):
                aggregate._scan_compact_tree(
                    fixture.root,
                    expected | {Path("target.json"), Path("symlink.json")},
                )

    def test_record_lookup_rejects_missing_duplicate_and_reordered_requests(self) -> None:
        runners = runner_identities()
        entries = []
        indexes: dict[str, dict[str, object]] = {}
        with tempfile.TemporaryDirectory() as temporary:
            fixtures = self.make_roots(Path(temporary))
            for lane, fixture in fixtures.items():
                entries.append(
                    {
                        "scene_id": "scene-01",
                        "scale": 30,
                        "lane": lane,
                        "request": f"scene-01/30/{lane}.request.json",
                        "evidence_path": "external/scene-01/evidence",
                    }
                )
                fixture.record["measurement_runner"] = runners[lane]
                fixture.index["records"] = [fixture.record]
                indexes[lane] = fixture.index
            request_index = {"runner_identities": runners, "requests": entries}
            records = aggregate._record_lookup(indexes, request_index)
            self.assertEqual(len(records), 3)

            missing = copy.deepcopy(indexes)
            missing[evidence.LANE_CONSTRAINED]["records"] = []
            with self.assertRaisesRegex(aggregate.AggregationError, "request closure"):
                aggregate._record_lookup(missing, request_index)

            duplicate = copy.deepcopy(indexes)
            duplicate[evidence.LANE_REFERENCE]["records"] = [
                duplicate[evidence.LANE_REFERENCE]["records"][0],
                duplicate[evidence.LANE_REFERENCE]["records"][0],
            ]
            with self.assertRaisesRegex(aggregate.AggregationError, "request closure"):
                aggregate._record_lookup(duplicate, request_index)

            reordered = copy.deepcopy(indexes)
            reordered[evidence.LANE_REFERENCE]["records"][0]["scene_id"] = "scene-02"
            with self.assertRaisesRegex(aggregate.AggregationError, "exact request-index order"):
                aggregate._record_lookup(reordered, request_index)

    def test_prepared_metrics_and_digest_tampering_are_rejected(self) -> None:
        lane = evidence.LANE_REFERENCE
        request = evidence_request(scene_id="orbit-01", scale=30, lane=lane)
        observations = raw_observations(lane)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_evidence_artifacts(root, observations)
            with mock.patch.object(evidence, "_lpips_distance", return_value=0.0):
                prepared = evidence.derive_attestation(
                    request,
                    observations,
                    root,
                    root / "evidence.json",
                    lane,
                    runner_identity(lane),
                    evidence_machine(lane),
                    enforce_environment_policy=True,
                )
            aggregate._validate_prepared_attestation(
                prepared, request, lane, runner_identity(lane)
            )
            tampered = copy.deepcopy(prepared)
            tampered["metrics"]["registered_views"]["value"] = -1
            with self.assertRaisesRegex(aggregate.AggregationError, "metrics are invalid"):
                aggregate._validate_prepared_attestation(
                    tampered, request, lane, runner_identity(lane)
                )

            evidence_path = root / "prepared.json"
            write_json(evidence_path, prepared)
            expected_digest = evidence.sha256_file(evidence_path)
            tampered["metrics"]["registered_views"]["value"] = 1
            write_json(root / "tampered.json", tampered)
            self.assertNotEqual(
                expected_digest,
                evidence.sha256_file(root / "tampered.json"),
                "metric mutation must change the prepared evidence digest",
            )

    def test_workflow_has_no_benchmark_signing_authority_or_secret_path(self) -> None:
        paths = [
            aggregate.REPOSITORY_ROOT / ".github/workflows/benchmark-release.yml",
            aggregate.REPOSITORY_ROOT / "scripts/benchmark/prepare_evidence.py",
            aggregate.REPOSITORY_ROOT / "scripts/benchmark/aggregate_evidence.py",
        ]
        workflow = paths[0].read_text(encoding="utf-8")
        combined = "\n".join(path.read_text(encoding="utf-8") for path in paths)
        for forbidden in (
            "BENCHMARK_EVIDENCE_PRIVATE_KEY",
            "benchmark-evidence-signing",
            "seal_evidence.py",
            "signing-requirements",
            "scripts/benchmark/public_key_ed25519.txt",
            "--private-key-stdin",
            "--sealed-root",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, combined)
        self.assertEqual(workflow.count("--prepared-root"), 3)
        self.assertIn("prepared_artifact_digest", combined)
        self.assertIn("actions/artifacts/$artifact_id", combined)

        aggregate_job = workflow.split("  aggregate:\n", 1)[1]
        self.assertIn('cp "$RUNNER_TEMP/verified-benchmark/suite.json" "$FINAL/suite.json"', aggregate_job)
        self.assertIn('"$FINAL/evidence/reference_m4_max"', aggregate_job)
        self.assertIn('"$FINAL/evidence/constrained_14_16gb"', aggregate_job)
        self.assertIn('"$FINAL/evidence/eight_gb_fast"', aggregate_job)
        for forbidden in ("raw-reference", "raw-constrained", "raw-eight-gb", "private key", "signature"):
            self.assertNotIn(forbidden, aggregate_job.lower())

    def test_output_rejects_overlap_and_nonempty_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "prepared"
            root.mkdir()
            with self.assertRaisesRegex(aggregate.AggregationError, "must not overlap"):
                aggregate._prepare_output(root / "output", [root.resolve()])
            output = Path(temporary) / "output"
            output.mkdir()
            (output / "existing").write_text("no", encoding="utf-8")
            with self.assertRaisesRegex(aggregate.AggregationError, "absent or empty"):
                aggregate._prepare_output(output, [root.resolve()])

    def test_aggregation_is_byte_deterministic_for_the_same_prepared_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            fixtures = self.make_roots(base / "prepared")
            scene = {
                "id": "scene-01",
                "category": "object_orbit",
                "capture_traits": ["ordered"],
                "scale_lanes": [30],
                "aggregate_scale": 30,
                "input": {"kind": "video"},
                "expected_outcome": {"kind": "valid"},
                "gate_scopes": ["scene_performance"],
            }
            corpus = {"scenes": [scene]}
            for fixture in fixtures.values():
                write_json(fixture.root / "requests/corpus.json", corpus)
                fixture.index["corpus_manifest"] = descriptor(
                    fixture.root / "requests/corpus.json", fixture.root
                )
            request_index = {
                "git_commit": COMMIT,
                "app_version": benchmark.APP_VERSION,
                "toolchain_identity": DIGEST,
                "benchmark_contract_sha256": DIGEST,
                "corpus_manifest_sha256": evidence.sha256_file(
                    fixtures[evidence.LANE_REFERENCE].root / "requests/corpus.json"
                ),
                "reference_config_sha256": evidence.sha256_file(
                    fixtures[evidence.LANE_REFERENCE].root
                    / "requests/reference-config.json"
                ),
                "thresholds_digest": DIGEST,
                "corpus_digest": DIGEST,
                "runner_identities": runner_identities(),
                "requests": [],
            }
            scene_result = {
                "scene_id": "scene-01",
                "category": "object_orbit",
                "capture_traits": ["ordered"],
                "scale": 30,
                "aggregate_scale": 30,
                "adapter": "protected-evidence",
                "status": "passed",
                "blocking_reasons": [],
                "failures": [],
                "input_kind": "video",
                "expected_outcome": {"kind": "valid"},
                "gate_scopes": ["scene_performance"],
                "route": "protected-evidence",
                "detail_profile": "release",
                "exit": {"code": 0, "reason": "exit", "cancelled": False},
                "command": ["fixture"],
                "metrics": {},
                "artifacts": {},
                "evidence": [],
            }
            roots = {lane: fixture.root.resolve() for lane, fixture in fixtures.items()}
            indexes = {lane: fixture.index for lane, fixture in fixtures.items()}
            patches = (
                mock.patch.object(aggregate, "_load_prepared_roots", return_value=(roots, indexes)),
                mock.patch.object(aggregate, "EXPECTED_SCENE_COUNT", 1),
                mock.patch.object(aggregate, "EXPECTED_RECORD_COUNT", 1),
                mock.patch.object(aggregate, "_current_git_commit", return_value=COMMIT),
                mock.patch.object(aggregate, "_require_clean_worktree"),
                mock.patch.object(benchmark, "validate_corpus"),
                mock.patch.object(benchmark, "validate_reference_config"),
                mock.patch.object(benchmark, "validate_tracked_benchmark_contract", return_value=DIGEST),
                mock.patch.object(benchmark, "validate_request_index", return_value=request_index),
                mock.patch.object(aggregate, "_record_lookup", return_value={}),
                mock.patch.object(aggregate, "_load_and_validate_requests", return_value=({}, {})),
                mock.patch.object(aggregate, "_scene_result", return_value=(scene_result, [{"machine": evidence_machine(evidence.LANE_REFERENCE)}])),
                mock.patch.object(benchmark, "evaluate_suite_performance", return_value={"blocking_reasons": [], "failures": []}),
                mock.patch.object(benchmark, "evaluate_suite_quality", return_value={"blocking_reasons": [], "failures": []}),
                mock.patch.object(benchmark, "validate_suite_result"),
                mock.patch.object(aggregate.Draft202012Validator, "validate"),
            )

            outputs = [base / "first", base / "second"]
            for output in outputs:
                with contextlib.ExitStack() as stack:
                    for patcher in patches:
                        stack.enter_context(patcher)
                    aggregate.aggregate_evidence(
                        prepared_roots=roots.values(),
                        output=output,
                    )
            self.assertEqual(
                (outputs[0] / "suite.json").read_bytes(),
                (outputs[1] / "suite.json").read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()
