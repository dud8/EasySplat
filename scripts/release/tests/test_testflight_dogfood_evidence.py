#!/usr/bin/env python3
"""Tests for exact-build TestFlight dogfood result authority."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/release/testflight_dogfood_evidence.py"
SOURCE = "a" * 40
PACKAGE_DIGEST = "b" * 64
ARTIFACT_DIGEST = "sha256:" + "c" * 64


def load_module():
    spec = importlib.util.spec_from_file_location("testflight_dogfood_evidence", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("dogfood evidence helper is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestFlightDogfoodEvidenceTests(unittest.TestCase):
    def result(
        self,
        module,
        container: str,
        fingerprint: str,
        *,
        package_digest: str = PACKAGE_DIGEST,
    ) -> dict[str, object]:
        return {
            "app": {"appleID": "1234567890", "build": "207", "version": "0.2.0"},
            "artifacts": [
                {"byteCount": 10, "name": "app-events.jsonl", "sha256": "d" * 64},
                {"byteCount": 20, "name": "screen-recording.mov", "sha256": "e" * 64},
            ],
            "checks": {name: True for name in module.CHECKS},
            "completedAt": "2026-08-09T16:00:00Z",
            "container": container,
            "host": {
                "containerFingerprintSHA256": fingerprint,
                "macOSBuild": "25G88",
                "machineModel": "Mac16,9",
                "testFlightBuild": "4.0.0 (900)",
            },
            "metrics": {
                "activeShareSessionsAfter": 0,
                "cancellationMaxSeconds": 1.5,
                "shareCleanupMaxSeconds": 0.5,
                "shareCycles": 10,
                "shareTemporaryBytesAfter": 100,
                "shareTemporaryBytesBefore": 100,
            },
            "packageSHA256": package_digest,
            "recordType": "testflightDogfoodResult",
            "schemaVersion": 1,
            "sourceCommit": SOURCE,
            "submissionArtifact": {"digest": ARTIFACT_DIGEST, "id": "12345"},
            "tester": "release-tester",
        }

    def validate(self, module, value, container):
        return module.validate_result(
            value,
            container=container,
            source_commit=SOURCE,
            apple_id="1234567890",
            version="0.2.0",
            build="207",
            package_sha256=PACKAGE_DIGEST,
            submission_artifact_id="12345",
            submission_artifact_digest=ARTIFACT_DIGEST,
        )

    def test_result_requires_every_check_and_measured_cleanup_bounds(self) -> None:
        module = load_module()
        valid = self.result(module, "fresh", "1" * 64)
        self.assertEqual(self.validate(module, valid, "fresh"), valid)
        for mutation in ("missing", "failed", "slow-cancel", "slow-share", "leak", "few-cycles"):
            with self.subTest(mutation=mutation):
                value = json.loads(json.dumps(valid))
                if mutation == "missing":
                    value["checks"].pop(next(iter(module.CHECKS)))
                elif mutation == "failed":
                    value["checks"][next(iter(module.CHECKS))] = False
                elif mutation == "slow-cancel":
                    value["metrics"]["cancellationMaxSeconds"] = 2.01
                elif mutation == "slow-share":
                    value["metrics"]["shareCleanupMaxSeconds"] = 1.01
                elif mutation == "leak":
                    value["metrics"]["shareTemporaryBytesAfter"] = 101
                else:
                    value["metrics"]["shareCycles"] = 9
                with self.assertRaises(module.DogfoodEvidenceError):
                    self.validate(module, value, "fresh")

    def test_result_is_bound_to_exact_source_package_submission_and_container(self) -> None:
        module = load_module()
        valid = self.result(module, "affectedInternal", "2" * 64)
        for key in ("container", "sourceCommit", "packageSHA256", "submissionArtifact"):
            with self.subTest(key=key):
                value = json.loads(json.dumps(valid))
                if key == "container":
                    value[key] = "fresh"
                elif key == "submissionArtifact":
                    value[key]["id"] = "999"
                else:
                    value[key] = "f" * (40 if key == "sourceCommit" else 64)
                with self.assertRaises(module.DogfoodEvidenceError):
                    self.validate(module, value, "affectedInternal")

    def test_gate_embeds_distinct_full_results_and_exact_file_evidence(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            package = root / "EasySplat.pkg"
            package.write_bytes(b"package bytes")
            package_digest = hashlib.sha256(package.read_bytes()).hexdigest()
            fresh = root / "fresh.json"
            affected = root / "affected.json"
            fresh.write_bytes(
                module._canonical(
                    self.result(module, "fresh", "1" * 64, package_digest=package_digest)
                )
            )
            affected.write_bytes(
                module._canonical(
                    self.result(
                        module,
                        "affectedInternal",
                        "2" * 64,
                        package_digest=package_digest,
                    )
                )
            )
            evidence = root / "evidence.json"
            upload = root / "upload.json"
            processing = root / "processing.json"
            for path in (evidence, upload, processing):
                path.write_text("{}\n", encoding="utf-8")
            output = root / "gate.json"
            options = argparse.Namespace(
                package=package,
                evidence=evidence,
                upload_receipt=upload,
                processing_receipt=processing,
                fresh_result=fresh,
                affected_result=affected,
                output=output,
                source_commit=SOURCE,
                apple_id="1234567890",
                version="0.2.0",
                build="207",
                submission_artifact_id="12345",
                submission_artifact_digest=ARTIFACT_DIGEST,
                workflow_run_id="777",
                workflow_run_attempt="1",
            )
            payload = module.build_gate(options)
            self.assertEqual(payload["dogfood"]["freshContainer"]["container"], "fresh")
            self.assertEqual(
                payload["dogfood"]["affectedInternalContainer"]["container"],
                "affectedInternal",
            )
            self.assertEqual(output.read_bytes(), module._canonical(payload))

    def test_result_is_read_and_authenticated_from_one_descriptor(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as scratch:
            path = (Path(scratch).resolve() / "result.json")
            path.write_bytes(module._canonical(self.result(module, "fresh", "1" * 64)))
            real_open = os.open
            opened_result = 0

            def counting_open(target, *args, **kwargs):
                nonlocal opened_result
                if Path(target) == path:
                    opened_result += 1
                return real_open(target, *args, **kwargs)

            with mock.patch.object(module.os, "open", side_effect=counting_open):
                loaded = module._load_result(path, "result")

            self.assertEqual(loaded["container"], "fresh")
            self.assertEqual(opened_result, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
