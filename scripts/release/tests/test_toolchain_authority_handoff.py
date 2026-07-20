#!/usr/bin/env python3
"""Static trust-boundary tests for the external toolchain authority handoff."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
PRODUCER = (ROOT / ".github/workflows/toolchain-build.yml").read_text(encoding="utf-8")
PUBLISH_PATH = ROOT / ".github/workflows/toolchain-publish.yml"
PUBLISH = PUBLISH_PATH.read_text(encoding="utf-8") if PUBLISH_PATH.exists() else ""
BENCHMARK = (ROOT / ".github/workflows/benchmark-release.yml").read_text(
    encoding="utf-8"
)


def job_block(source: str, name: str) -> str:
    match = re.search(rf"^  {re.escape(name)}:\n", source, re.MULTILINE)
    if match is None:
        raise AssertionError(f"workflow is missing job: {name}")
    next_match = re.search(
        r"^  [A-Za-z0-9_-]+:\n", source[match.end() :], re.MULTILINE
    )
    end = len(source) if next_match is None else match.end() + next_match.start()
    return source[match.start() : end]


class ToolchainAuthorityHandoffTests(unittest.TestCase):
    def test_producer_has_no_external_authority_or_benchmark_dependency(self) -> None:
        inputs = PRODUCER.split("permissions:", 1)[0]
        self.assertNotRegex(inputs, r"authority_|benchmark_")
        for forbidden in (
            "dud8/easysplat-release-authority",
            "verify-external-authority",
            "stage-draft-release",
        ):
            self.assertNotIn(forbidden, PRODUCER)

    def test_publish_inputs_bind_two_stage_authority_transport(self) -> None:
        inputs = PUBLISH.split("permissions:", 1)[0]
        for required in (
            "producer_run_id:",
            "producer_run_attempt:",
            "producer_artifact_id:",
            "producer_artifact_digest:",
            "request_artifact_id:",
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
            "benchmark_run_id:",
            "benchmark_artifact_id:",
            "benchmark_artifact_digest:",
        ):
            self.assertIn(required, inputs)

    def test_authority_consumers_require_the_sign_only_workflow(self) -> None:
        sign_only = ".github/workflows/sign-toolchain-authority.yml"
        publishing = ".github/workflows/release-toolchain.yml"
        self.assertIn(sign_only, PUBLISH)
        self.assertIn(sign_only, BENCHMARK)
        self.assertNotIn(publishing, PUBLISH)
        self.assertNotIn(publishing, BENCHMARK)

    def test_preflight_downloads_private_bytes_but_executes_no_repo_code(self) -> None:
        block = job_block(PUBLISH, "metadata-preflight")
        for required in (
            "secrets.EASYSPLAT_RELEASE_POLICY_TOKEN",
            "repos/$repository/actions/runs/$run_id",
            "repos/$AUTHORITY_REPOSITORY/actions/artifacts/$AUTHORITY_PAYLOAD_ARTIFACT_ID",
            "repos/$AUTHORITY_REPOSITORY/actions/artifacts/$AUTHORITY_RECEIPT_ARTIFACT_ID",
            "repos/$GITHUB_REPOSITORY/actions/artifacts/$PRODUCER_ARTIFACT_ID",
            "repos/$GITHUB_REPOSITORY/actions/artifacts/$REQUEST_ARTIFACT_ID",
            "repos/$GITHUB_REPOSITORY/actions/artifacts/$BENCHMARK_ARTIFACT_ID",
            "toolchain-authority-payload.zip",
            "toolchain-authority-receipt.zip",
            "authority-transport.json",
            "benchmark-transport.json",
            "verifiedSuiteSHA256",
        ):
            self.assertIn(required, block)
        self.assertNotRegex(block, r"actions/checkout@|scripts/|swift\s|python3 scripts/")

    def test_external_schema_is_validated_only_after_secret_is_gone(self) -> None:
        verifier = job_block(PUBLISH, "verify-publication")
        for required in (
            "--authority-handoff \"$HANDOFF/authority-handoff\"",
            "--authority-payload-artifact-id",
            "--authority-receipt-artifact-id",
            "scripts/release/toolchain_publication.py verify",
            "EasySplatApp/Resources/public_key_ed25519.txt",
        ):
            self.assertIn(required, verifier)
        self.assertNotRegex(
            verifier,
            r"EASYSPLAT_RELEASE_POLICY_TOKEN|secrets\.|github-token:|GH_TOKEN|GITHUB_TOKEN",
        )

    def test_publication_requires_post_sign_benchmark_identity(self) -> None:
        verifier = job_block(PUBLISH, "verify-publication")
        for required in (
            "--benchmark-suite",
            "--benchmark-evidence",
            "--benchmark-run-id",
            "--benchmark-run-attempt",
            "--benchmark-artifact-id",
            "--benchmark-artifact-name",
            "--benchmark-artifact-digest",
            "full_toolchain_identity",
        ):
            self.assertIn(required, verifier)
        producer_inputs = PRODUCER.split("permissions:", 1)[0]
        self.assertNotIn("benchmark", producer_inputs)

    def test_no_obsolete_app_or_unsigned_authority_contract_remains(self) -> None:
        combined = PRODUCER + PUBLISH
        for forbidden in (
            "verify_publication_bundle.py verify-build",
            "sourceArtifacts",
            "unsignedManifestSHA256",
            "toolchain-authority-producer.json",
        ):
            self.assertNotIn(forbidden, combined)


if __name__ == "__main__":
    unittest.main()
