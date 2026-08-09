#!/usr/bin/env python3
"""Static release-policy tests for the protected TestFlight lane."""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
TESTFLIGHT = ROOT / ".github/workflows/release-testflight.yml"
RELEASE = ROOT / ".github/workflows/release-app.yml"


class TestFlightWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(TESTFLIGHT.is_file(), "protected TestFlight workflow is missing")
        self.workflow = TESTFLIGHT.read_text(encoding="utf-8")
        self.release = RELEASE.read_text(encoding="utf-8")

    def job(self, name: str, next_name: str | None) -> str:
        body = self.workflow.split(f"  {name}:\n", 1)[1]
        return body if next_name is None else body.split(f"  {next_name}:\n", 1)[0]

    def test_dispatch_is_exact_main_source_with_unique_store_build(self) -> None:
        self.assertIn("name: Release TestFlight", self.workflow)
        self.assertIn("workflow_dispatch:", self.workflow)
        self.assertNotIn("pull_request:", self.workflow)
        self.assertNotIn("push:", self.workflow)
        for name in ("version", "build_number", "toolchain_version"):
            self.assertIn(f"      {name}:\n", self.workflow)
        self.assertIn("group: testflight-publication", self.workflow)
        self.assertIn("cancel-in-progress: false", self.workflow)
        self.assertIn("github.ref == 'refs/heads/main'", self.workflow)
        self.assertIn('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', self.workflow)
        self.assertIn('test "$(git rev-parse "v$VERSION^{commit}")" = "$GITHUB_SHA"', self.workflow)

    def test_signing_job_builds_reviewed_arm64_mas_package(self) -> None:
        signing = self.job("build-store-package", "submit-testflight")
        self.assertIn("environment: testflight-signing", signing)
        self.assertIn("runs-on: [self-hosted, macOS, ARM64, easysplat-signing, easysplat-ephemeral]", signing)
        self.assertIn('test "$(/usr/bin/uname -m)" = "arm64"', signing)
        self.assertIn("EASYSPLAT_APPLE_DISTRIBUTION_SHA1", signing)
        self.assertIn("EASYSPLAT_MAC_INSTALLER_DISTRIBUTION_SHA1", signing)
        self.assertIn("EASYSPLAT_MAS_PROVISIONING_PROFILE_BASE64", signing)
        self.assertIn("EASYSPLAT_MAS_TEAM_ID", signing)
        self.assertIn("scripts/release/build_app.sh", signing)
        self.assertIn("--app-store", signing)
        self.assertIn('--source-commit "$GITHUB_SHA"', signing)
        self.assertIn('--build-number "${{ inputs.build_number }}"', signing)
        self.assertIn("scripts/release/build_mas_package.sh", signing)
        self.assertIn('EVIDENCE="$PACKAGE.provenance.json"', signing)
        self.assertIn('CHECKSUM="$PACKAGE.sha256"', signing)

    def test_submission_job_uploads_once_waits_and_preserves_terminal_receipts(self) -> None:
        submission = self.job("submit-testflight", "approve-dogfood")
        self.assertIn("environment: testflight-submission", submission)
        self.assertIn("EASYSPLAT_ASC_KEY_ID", submission)
        self.assertIn("EASYSPLAT_ASC_ISSUER_ID", submission)
        self.assertIn("EASYSPLAT_ASC_PRIVATE_KEY_BASE64", submission)
        self.assertIn('--apple-id "${{ inputs.apple_id }}"', submission)
        self.assertIn("scripts/release/upload_mas_package.sh", submission)
        self.assertIn("--upload", submission)
        self.assertIn('--bundle-version "${{ inputs.build_number }}"', submission)
        self.assertIn('--bundle-short-version "${{ inputs.version }}"', submission)
        self.assertIn('"$PACKAGE.upload.json"', submission)
        self.assertIn('"$PACKAGE.processing.json"', submission)
        self.assertIn("verify-processing", submission)

    def test_manual_dogfood_approval_is_bound_to_the_processed_artifact(self) -> None:
        approval = self.job("approve-dogfood", None)
        self.assertIn("needs: submit-testflight", approval)
        self.assertIn("environment: testflight-dogfood", approval)
        self.assertNotIn("secrets.", approval)
        self.assertIn("verify-processing", approval)
        self.assertIn("EASYSPLAT_TESTFLIGHT_FRESH_RESULT_BASE64", approval)
        self.assertIn("EASYSPLAT_TESTFLIGHT_AFFECTED_RESULT_BASE64", approval)
        self.assertIn("testflight_dogfood_evidence.py materialize", approval)
        self.assertIn("testflight_dogfood_evidence.py build-gate", approval)
        self.assertIn("fresh-container-result.json", approval)
        self.assertIn("affected-internal-container-result.json", approval)
        self.assertNotIn('"freshContainer": True', approval)
        self.assertNotIn('"affectedInternalContainer": True', approval)
        self.assertIn("easysplat-testflight-gate-", approval)

    def test_release_draft_requires_successful_exact_testflight_gate(self) -> None:
        self.assertIn("      testflight_run_id:\n", self.release)
        self.assertIn("      testflight_build_number:\n", self.release)
        self.assertIn(".github/workflows/release-testflight.yml", self.release)
        self.assertIn("easysplat-testflight-gate-", self.release)
        self.assertIn("testflight_artifact_id", self.release)
        self.assertIn("testflight_artifact_digest", self.release)
        self.assertIn("testflightBuildNumber", self.release)
        self.assertIn("testflightRunID", self.release)
        prepare = self.release.split("  prepare-release:\n", 1)[1].split(
            "  sign-and-notarize:\n", 1
        )[0]
        self.assertIn("Download exact approved TestFlight gate", prepare)
        self.assertIn("testflight-gate.json", prepare)
        self.assertIn(
            'payload["recordType"] == "testflightDogfoodGate"', prepare
        )
        self.assertIn(
            'dogfood["approvalEnvironment"] == "testflight-dogfood"', prepare
        )
        self.assertIn("REQUIRED_DOGFOOD_CHECKS", prepare)
        self.assertIn('container="fresh"', prepare)
        self.assertIn('container="affectedInternal"', prepare)
        self.assertNotIn('"freshContainer": True', prepare)
        self.assertNotIn('"affectedInternalContainer": True', prepare)
        self.assertIn('"sourceCommit": os.environ["EXPECTED_SOURCE"]', prepare)
        self.assertIn('"build": os.environ["INPUT_TESTFLIGHT_BUILD_NUMBER"]', prepare)

    def test_store_credentials_are_confined_to_their_protected_jobs(self) -> None:
        signing = self.job("build-store-package", "submit-testflight")
        submission = self.job("submit-testflight", "approve-dogfood")
        approval = self.job("approve-dogfood", None)
        for secret in (
            "EASYSPLAT_APPLE_DISTRIBUTION_SHA1",
            "EASYSPLAT_MAC_INSTALLER_DISTRIBUTION_SHA1",
            "EASYSPLAT_MAS_PROVISIONING_PROFILE_BASE64",
            "EASYSPLAT_MAS_TEAM_ID",
        ):
            self.assertIn(secret, signing)
            self.assertNotIn(secret, submission)
            self.assertNotIn(secret, approval)
        for secret in (
            "EASYSPLAT_ASC_KEY_ID",
            "EASYSPLAT_ASC_ISSUER_ID",
            "EASYSPLAT_ASC_PRIVATE_KEY_BASE64",
        ):
            self.assertNotIn(secret, signing)
            self.assertIn(secret, submission)
            self.assertNotIn(secret, approval)
        self.assertNotIn("EASYSPLAT_ASC_PRIVATE_KEY_BASE64", self.release)


if __name__ == "__main__":
    unittest.main(verbosity=2)
