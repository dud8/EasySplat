#!/usr/bin/env python3
"""Focused policy tests for the toolchain producer and publication workflows."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
PRODUCER_PATH = ROOT / ".github/workflows/toolchain-build.yml"
PUBLISH_PATH = ROOT / ".github/workflows/toolchain-publish.yml"
RELEASE_APP_PATH = ROOT / ".github/workflows/release-app.yml"
PRODUCER = PRODUCER_PATH.read_text(encoding="utf-8")
PUBLISH = PUBLISH_PATH.read_text(encoding="utf-8") if PUBLISH_PATH.exists() else ""
RELEASE_APP = RELEASE_APP_PATH.read_text(encoding="utf-8")


def job_block(source: str, name: str) -> str:
    pattern = re.compile(
        rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)",
        re.M | re.S,
    )
    match = pattern.search(source)
    if not match:
        raise AssertionError(f"missing workflow job: {name}")
    return match.group(0)


def workflow_jobs(source: str) -> list[str]:
    jobs = source.split("\njobs:\n", 1)[1]
    return re.findall(r"^  ([A-Za-z0-9_-]+):$", jobs, flags=re.M)


def assert_embedded_semver_validator(
    test: unittest.TestCase,
    source: str,
    job: str,
    *,
    includes_app_version: bool = False,
    stable_only: bool = False,
) -> None:
    block = job_block(source, job)
    test.assertNotRegex(block, r"actions/checkout@|scripts/|swift\s")
    app_version = r' "\$APP_VERSION"' if includes_app_version else ""
    match = re.search(
        r'python3 - "\$VERSION"'
        + app_version
        + r' "\$APP_VERSION_MINIMUM" '
        r'"\$APP_VERSION_MAXIMUM_EXCLUSIVE" <<\'PY\'\n(?P<script>.*?)^          PY$',
        block,
        flags=re.M | re.S,
    )
    test.assertIsNotNone(match)
    script = textwrap.dedent(match.group("script"))
    valid_versions = (
        (("2.0.0", "0.2.0", "0.2.0", "0.3.0"),)
        if includes_app_version and stable_only
        else (
            ("2.0.0", "0.2.0-beta.1", "0.3.0"),
            ("2.0.0-rc.1", "1.0.0-0", "3.4.5-alpha-1"),
        )
    )
    for versions in valid_versions:
        result = subprocess.run(
            [sys.executable, "-I", "-", *versions],
            input=script,
            text=True,
            capture_output=True,
            check=False,
        )
        test.assertEqual(result.returncode, 0, result.stderr)
    for invalid in (
        "2.0.0-alpha..1",
        "2.0.0-.alpha",
        "2.0.0-alpha.",
        "2.0.0-01",
        "2.0.0+build.1",
        "02.0.0",
        *(("2.0.0-rc.1", "0.2.0-rc.1") if stable_only else ()),
    ):
        trailing = (
            ("0.2.0", "0.2.0", "0.3.0")
            if includes_app_version
            else ("0.2.0", "0.3.0")
        )
        result = subprocess.run(
            [sys.executable, "-I", "-", invalid, *trailing],
            input=script,
            text=True,
            capture_output=True,
            check=False,
        )
        test.assertNotEqual(result.returncode, 0, invalid)


class ToolchainProducerWorkflowTests(unittest.TestCase):
    def test_inputs_are_only_version_and_app_compatibility(self) -> None:
        inputs = PRODUCER.split("permissions:", 1)[0]
        for required in (
            "version:",
            "app_version_minimum:",
            "app_version_maximum_exclusive:",
        ):
            self.assertIn(required, inputs)
        for forbidden in ("benchmark", "authority", "producer_run"):
            self.assertNotIn(forbidden, inputs)

    def test_graph_ends_after_post_sign_producer_and_request_uploads(self) -> None:
        self.assertEqual(
            workflow_jobs(PRODUCER),
            [
                "metadata-preflight",
                "build-unsigned",
                "sign-and-notarize",
                "derive-post-sign-request",
            ],
        )
        derive = job_block(PRODUCER, "derive-post-sign-request")
        self.assertIn("needs: [metadata-preflight, sign-and-notarize]", derive)
        self.assertIn("toolchain-final-producer-${{ inputs.version }}", derive)
        self.assertIn("toolchain-post-sign-request-${{ inputs.version }}", derive)
        self.assertNotRegex(PRODUCER, r"stage-draft|gh release|contents: write")

    def test_preflight_is_checkout_free_and_validates_strict_semver(self) -> None:
        block = job_block(PRODUCER, "metadata-preflight")
        self.assertIn("environment: toolchain-release", block)
        self.assertIn("secrets.EASYSPLAT_RELEASE_POLICY_TOKEN", block)
        self.assertIn("repos/$GITHUB_REPOSITORY/branches/main", block)
        self.assertIn("repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG", block)
        assert_embedded_semver_validator(self, PRODUCER, "metadata-preflight")

    def test_builder_is_identity_free_and_uploads_only_unsigned_handoff(self) -> None:
        build = job_block(PRODUCER, "build-unsigned")
        for required in (
            "easysplat-toolchain-builder",
            "identity-free-production-builder",
            "security find-identity -v -p codesigning",
            "toolchain-unsigned-components-${{ inputs.version }}",
            "toolchain-unsigned-request-${{ inputs.version }}",
            "ManifestTool prepare-release",
        ):
            self.assertIn(required, build)
        self.assertNotRegex(
            build,
            r"environment:|secrets\.|EASYSPLAT_TOOLCHAIN_|/usr/bin/codesign|notarytool|gh release",
        )

    def test_builder_identity_gate_accepts_exactly_zero_identities(self) -> None:
        build = job_block(PRODUCER, "build-unsigned")
        match = re.search(
            r"(?P<gate>^[ ]{10}identity_count=.*?"
            r'^[ ]{10}test "\$identity_count" = "0"$)',
            build,
            flags=re.M | re.S,
        )
        self.assertIsNotNone(match)
        gate = textwrap.dedent(match.group("gate"))

        with tempfile.TemporaryDirectory() as raw:
            fixture_root = Path(raw)
            security = fixture_root / "security"
            security.write_text(
                "#!/bin/sh\n"
                'test "$*" = "find-identity -v -p codesigning"\n'
                'printf "%s\\n" "$SECURITY_FIND_IDENTITY_OUTPUT"\n',
                encoding="utf-8",
            )
            security.chmod(0o700)

            for count, expected_status in ((0, 0), (1, 1)):
                output = (
                    "     0 valid identities found"
                    if count == 0
                    else (
                        '  1) 0123456789ABCDEF "Developer ID Application: Example"\n'
                        "     1 valid identities found"
                    )
                )
                result = subprocess.run(
                    ["/bin/bash", "-euo", "pipefail", "-c", gate],
                    check=False,
                    capture_output=True,
                    text=True,
                    env={
                        "PATH": f"{fixture_root}:/usr/bin:/bin",
                        "SECURITY_FIND_IDENTITY_OUTPUT": output,
                    },
                )
                self.assertEqual(result.returncode, expected_status, result.stderr)

    def test_signer_is_isolated_and_has_no_authority_or_publication_access(self) -> None:
        signer = job_block(PRODUCER, "sign-and-notarize")
        for required in (
            "easysplat-toolchain-signing",
            "environment: toolchain-signing",
            "EASYSPLAT_TOOLCHAIN_DEVELOPER_ID_APPLICATION_SHA1",
            "EASYSPLAT_TOOLCHAIN_DEVELOPER_TEAM_ID",
            "EASYSPLAT_TOOLCHAIN_NOTARY_KEYCHAIN_PROFILE",
            "Authenticate builder artifacts before repository checkout",
            "/usr/bin/python3 -I",
            "urllib.request.ProxyHandler({})",
            "github-authority.json",
            "scripts/release/finalize_signed_toolchain.py",
            '--github-authority-receipt "$RUNNER_TEMP/toolchain-builder-authority/github-authority.json"',
            "scripts/release/notarize_artifact.sh",
            "toolchain-signed-intermediate-${{ inputs.version }}",
        ):
            self.assertIn(required, signer)
        self.assertNotRegex(
            signer,
            r"EASYSPLAT_RELEASE_POLICY_TOKEN|EASYSPLAT_TOOLCHAIN_PUBLICATION_TOKEN|authority_|gh release|contents: write",
        )
        authority_step = signer.index("GH_TOKEN: ${{ github.token }}")
        checkout_step = signer.index("actions/checkout@")
        signing_step = signer.index("Developer ID sign and notarize exact producer bytes")
        self.assertLess(authority_step, checkout_step)
        self.assertLess(checkout_step, signing_step)
        self.assertNotIn("gh api", signer[:checkout_step])
        self.assertNotIn("GH_TOKEN", signer[checkout_step:])

    def test_post_sign_request_hashes_the_final_signed_archives(self) -> None:
        derive = job_block(PRODUCER, "derive-post-sign-request")
        for required in (
            "artifact-ids: ${{ needs.sign-and-notarize.outputs.artifact_id }}",
            "ManifestTool prepare-release",
            '--core-zip "$FINAL/toolchain-macos-arm64-$VERSION-core.zip"',
            '--da3-base-zip "$FINAL/toolchain-geometry-da3-base-$VERSION.zip"',
            '--da3-small-zip "$FINAL/toolchain-geometry-da3-small-$VERSION.zip"',
            '--request-out "$REQUEST/toolchain-release-request.json"',
            "scripts/release/toolchain_publication.py validate-producer",
            "source_run_id=${{ github.run_id }}",
            "source_run_attempt=${{ github.run_attempt }}",
        ):
            self.assertIn(required, derive)
        self.assertNotRegex(derive, r"environment:|secrets\.|codesign|notarytool|gh release")


class ToolchainPublicationWorkflowTests(unittest.TestCase):
    def test_public_toolchain_and_benchmark_names_match_app_release_consumers(
        self,
    ) -> None:
        for name in (
            "toolchain-authority-envelope.json",
            "toolchain-authority-receipt.json",
            "toolchain-benchmark-evidence.json",
        ):
            self.assertIn(name, PUBLISH)
            self.assertIn(name, RELEASE_APP)
        self.assertNotIn("--pattern authority-envelope.json", RELEASE_APP)
        self.assertNotIn("--pattern authority-receipt.json", RELEASE_APP)
        self.assertNotIn("toolchain/out/authority-envelope.json", RELEASE_APP)
        self.assertNotIn("toolchain/out/authority-receipt.json", RELEASE_APP)
        self.assertIn("$RUNNER_TEMP/bound-benchmark/verified-suite.json", RELEASE_APP)
        self.assertIn(
            "$RUNNER_TEMP/prepared-benchmark/verified-suite.json", RELEASE_APP
        )
        self.assertNotIn("$RUNNER_TEMP/bound-benchmark/suite.json", RELEASE_APP)
        self.assertNotIn("$RUNNER_TEMP/prepared-benchmark/suite.json", RELEASE_APP)

    def test_publish_graph_separates_handoff_verification_smoke_and_draft(self) -> None:
        self.assertEqual(
            workflow_jobs(PUBLISH),
            [
                "metadata-preflight",
                "verify-publication",
                "minimum-macos-compatibility",
                "stage-draft-release",
            ],
        )
        self.assertIn(
            "needs: [verify-publication, minimum-macos-compatibility]",
            job_block(PUBLISH, "stage-draft-release"),
        )

    def test_private_authority_token_is_confined_to_checkout_free_preflight(self) -> None:
        preflight = job_block(PUBLISH, "metadata-preflight")
        self.assertIn("environment: toolchain-release", preflight)
        self.assertIn("secrets.EASYSPLAT_RELEASE_POLICY_TOKEN", preflight)
        self.assertIn("repos/$AUTHORITY_REPOSITORY", preflight)
        self.assertIn("actions/artifacts/$PRODUCER_ARTIFACT_ID/zip", preflight)
        self.assertIn("actions/artifacts/$REQUEST_ARTIFACT_ID/zip", preflight)
        self.assertIn("actions/artifacts/$BENCHMARK_ARTIFACT_ID/zip", preflight)
        self.assertIn("actions/artifacts/$AUTHORITY_PAYLOAD_ARTIFACT_ID/zip", preflight)
        self.assertIn("actions/artifacts/$AUTHORITY_RECEIPT_ARTIFACT_ID/zip", preflight)
        self.assertIn("/usr/bin/shasum -a 256", preflight)
        self.assertIn("benchmark-transport.json", preflight)
        self.assertIn("verifiedSuiteSHA256", preflight)
        self.assertIn("toolchain-authority-handoff-${{ github.run_id }}-${{ github.run_attempt }}", preflight)
        self.assertNotRegex(preflight, r"actions/checkout@|scripts/|swift\s")
        self.assertEqual(PUBLISH.count("secrets.EASYSPLAT_RELEASE_POLICY_TOKEN"), 1)
        assert_embedded_semver_validator(
            self,
            PUBLISH,
            "metadata-preflight",
            includes_app_version=True,
            stable_only=True,
        )

    def test_secretless_verifier_consumes_local_producer_and_same_run_handoff(self) -> None:
        verifier = job_block(PUBLISH, "verify-publication")
        for required in (
            "easysplat-toolchain-verifier",
            "artifact-ids: ${{ needs.metadata-preflight.outputs.handoff_artifact_id }}",
            "scripts/release/toolchain_publication.py verify",
            "--producer-run-attempt \"${{ inputs.producer_run_attempt }}\"",
            "--producer-artifact-id \"${{ inputs.producer_artifact_id }}\"",
            "--producer-artifact-digest \"${{ inputs.producer_artifact_digest }}\"",
            "--request-artifact-id \"${{ inputs.request_artifact_id }}\"",
            "--request-artifact-digest \"${{ inputs.request_artifact_digest }}\"",
            "--benchmark-artifact-id \"${{ inputs.benchmark_artifact_id }}\"",
            "--benchmark-artifact-name \"${{ inputs.benchmark_artifact_name }}\"",
            "--benchmark-artifact-digest \"${{ inputs.benchmark_artifact_digest }}\"",
            "--benchmark-run-attempt \"${{ inputs.benchmark_run_attempt }}\"",
            '--benchmark-evidence "$HANDOFF/benchmark/benchmark-transport.json"',
        ):
            self.assertIn(required, verifier)
        self.assertNotIn("verify_publication_bundle.py verify-build", verifier)
        self.assertNotRegex(
            verifier,
            r"environment:|secrets\.|github-token:|GH_TOKEN|GITHUB_TOKEN|contents: write|codesign|notarytool|gh release",
        )

    def test_macos15_smoke_consumes_only_verified_publication(self) -> None:
        smoke = job_block(PUBLISH, "minimum-macos-compatibility")
        self.assertIn("needs: verify-publication", smoke)
        self.assertIn("runs-on: macos-15", smoke)
        self.assertIn(
            "artifact-ids: ${{ needs.verify-publication.outputs.artifact_id }}", smoke
        )
        self.assertIn('"$RUNNER_TEMP/core/bin/colmap" help', smoke)
        self.assertIn('"$RUNNER_TEMP/core/bin/easysplat-train" --self-check', smoke)
        self.assertNotRegex(smoke, r"environment:|secrets\.|contents: write")

    def test_draft_stage_uploads_exact_public_asset_set_without_publishing(self) -> None:
        draft = job_block(PUBLISH, "stage-draft-release")
        for required in (
            "environment: toolchain-publication",
            "contents: read",
            "secrets.EASYSPLAT_TOOLCHAIN_PUBLICATION_TOKEN",
            'f"toolchain-macos-arm64-{version}-core.zip"',
            'f"toolchain-geometry-da3-base-{version}.zip"',
            'f"toolchain-geometry-da3-small-{version}.zip"',
            "manifest.json",
            "toolchain-release-request.json",
            "toolchain-authority-envelope.json",
            "toolchain-authority-receipt.json",
            "toolchain-benchmark-evidence.json",
            "draft=true",
            "prerelease=false",
        ):
            self.assertIn(required, draft)
        for forbidden in (
            "immutable == true",
            "immutable-releases",
            "--latest",
            "prerelease=true",
            "gh release edit",
            "git tag",
            "git push",
            "scripts/",
            "actions/checkout@",
        ):
            self.assertNotIn(forbidden, draft)


if __name__ == "__main__":
    unittest.main()
