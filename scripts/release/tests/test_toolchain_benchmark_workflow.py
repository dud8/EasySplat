#!/usr/bin/env python3
"""Contract tests for benchmarking the final signed toolchain closure."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = (ROOT / ".github/workflows/benchmark-release.yml").read_text(encoding="utf-8")


def job_block(name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n.*?(?=^  [A-Za-z0-9_-]+:|\Z)",
        WORKFLOW,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing workflow job: {name}")
    return match.group(0)


class ToolchainBenchmarkWorkflowTests(unittest.TestCase):
    def test_dispatch_binds_final_producer_request_and_two_stage_authority(self) -> None:
        inputs = WORKFLOW.split("permissions:", 1)[0]
        for name in (
            "version:",
            "app_version:",
            "producer_run_id:",
            "producer_run_attempt:",
            "producer_artifact_id:",
            "producer_artifact_name:",
            "producer_artifact_digest:",
            "request_artifact_id:",
            "request_artifact_name:",
            "request_artifact_digest:",
            "request_sha256:",
            "authority_commit:",
            "authority_run_id:",
            "authority_run_attempt:",
            "authority_payload_artifact_id:",
            "authority_payload_artifact_name:",
            "authority_payload_artifact_digest:",
            "authority_receipt_artifact_id:",
            "authority_receipt_artifact_name:",
            "authority_receipt_artifact_digest:",
        ):
            self.assertIn(name, inputs)

    def test_checkout_free_binding_job_collects_only_inert_artifacts(self) -> None:
        block = job_block("bind-toolchain")
        self.assertIn("environment: benchmark-release", block)
        self.assertIn("secrets.EASYSPLAT_RELEASE_POLICY_TOKEN", block)
        self.assertIn("toolchain-benchmark-handoff-${{ github.run_id }}-${{ github.run_attempt }}", block)
        self.assertIn("authority-transport.json", block)
        self.assertNotRegex(block, r"actions/checkout@|scripts/|swift\s|python3 scripts/")

    def test_prepare_verifies_and_installs_final_signed_closure_without_token(self) -> None:
        block = job_block("prepare")
        for required in (
            "needs: bind-toolchain",
            "artifact-ids: ${{ needs.bind-toolchain.outputs.artifact_id }}",
            "toolchain_publication.py verify-authority",
            "ManifestTool verify-release",
            "signed-toolchain-root",
            "full_toolchain_identity",
        ):
            self.assertIn(required, block)
        self.assertNotRegex(
            block,
            r"secrets\.|github-token:|GH_TOKEN|GITHUB_TOKEN|EASYSPLAT_BENCHMARK_REFERENCE_TOOLCHAIN_ROOT",
        )

    def test_all_current_lanes_consume_the_verified_signed_toolchain(self) -> None:
        for name in ("reference", "constrained", "eight-gb"):
            block = job_block(name)
            self.assertIn("needs: [prepare]", block)
            self.assertIn("signed_toolchain_artifact_id", block)
            self.assertIn("$RUNNER_TEMP/signed-toolchain-root", block)
            self.assertNotIn("EASYSPLAT_BENCHMARK_REFERENCE_TOOLCHAIN_ROOT", block)
        aggregate = job_block("aggregate")
        self.assertIn("verified-suite.json", aggregate)


if __name__ == "__main__":
    unittest.main()
