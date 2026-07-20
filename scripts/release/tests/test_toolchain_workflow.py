#!/usr/bin/env python3
"""Focused policy tests for the toolchain producer and publication workflows."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


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


def embedded_draft_publisher() -> str:
    draft = job_block(PUBLISH, "stage-draft-release")
    match = re.search(
        r"python3 -I - <<'PY'\n(?P<script>.*?)^          PY$",
        draft,
        flags=re.M | re.S,
    )
    if match is None:
        raise AssertionError("missing embedded toolchain draft publisher")
    return textwrap.dedent(match.group("script"))


class FakeJSONResponse:
    def __init__(self, payload: object, *, link: str | None = None) -> None:
        self.payload = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.headers = {} if link is None else {"Link": link}

    def __enter__(self) -> FakeJSONResponse:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self, _: int = -1) -> bytes:
        return self.payload


class FakeUploadResponse:
    status = 201

    def __init__(self, payload: object) -> None:
        self.payload = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    def read(self, _: int = -1) -> bytes:
        return self.payload


class FakeEmptyResponse:
    status = 204
    headers: dict[str, str] = {}

    def __enter__(self) -> FakeEmptyResponse:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self, _: int = -1) -> bytes:
        return b""


class FakeUploadConnection:
    def __init__(self, api: FakeReleaseAPI) -> None:
        self.api = api
        self.response: FakeUploadResponse | None = None

    def request(
        self,
        method: str,
        target: str,
        *,
        body: object,
        headers: dict[str, str],
    ) -> None:
        parsed = urllib.parse.urlsplit(target)
        query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
        name = query["name"][0]
        data = body.read()
        if method != "POST" or int(headers["Content-Length"]) != len(data):
            raise AssertionError("invalid fake upload request")
        asset = self.api.asset(name, data)
        self.api.release["assets"].append(asset)
        self.api.uploaded.append(name)
        self.response = FakeUploadResponse(asset)

    def getresponse(self) -> FakeUploadResponse:
        if self.response is None:
            raise AssertionError("upload response requested before upload")
        return self.response

    def close(self) -> None:
        return None


class FakeReleaseAPI:
    repository = "dud8/EasySplat"
    version = "2.0.0"
    commit = "a" * 40
    release_id = 321

    def __init__(self, root: Path) -> None:
        self.root = root
        self.publication = root / "publication"
        self.runner_temp = root / "runner"
        self.evidence_root = self.runner_temp / "manual-publication-evidence"
        self.release_id_file = self.runner_temp / "draft-release-id"
        self.publication.mkdir(mode=0o700)
        self.runner_temp.mkdir(mode=0o700)
        self.tag = f"toolchain-v{self.version}"
        self.owner = (
            f"<!-- easysplat-toolchain-release-owner:v1:{self.repository}:"
            f"{self.tag}:{self.commit} -->"
        )
        self.release: dict[str, object] = {
            "id": self.release_id,
            "tag_name": self.tag,
            "target_commitish": self.commit,
            "name": self.tag,
            "body": self.owner,
            "draft": True,
            "prerelease": False,
            "immutable": False,
            "upload_url": (
                f"https://uploads.github.com/repos/{self.repository}/releases/"
                f"{self.release_id}/assets{{?name,label}}"
            ),
            "assets": [],
        }
        self.pages: list[list[object]] = [[self.release]]
        self.created = 0
        self.deleted: list[int] = []
        self.uploaded: list[str] = []
        self.immutable_policy_calls = 0
        self.immutable_policy_states = [True]
        self.main_ref_calls = 0
        self.main_ref_states = [self.commit]
        self.tag_ref_calls = 0
        self.tag_ref_states = [self.commit]

    @property
    def names(self) -> list[str]:
        return [
            f"toolchain-macos-arm64-{self.version}-core.zip",
            f"toolchain-geometry-da3-base-{self.version}.zip",
            f"toolchain-geometry-da3-small-{self.version}.zip",
            "manifest.json",
            "toolchain-release-request.json",
            "toolchain-authority-envelope.json",
            "toolchain-authority-receipt.json",
            "toolchain-benchmark-evidence.json",
        ]

    def asset(self, name: str, data: bytes | None = None) -> dict[str, object]:
        payload = (self.publication / name).read_bytes() if data is None else data
        return {
            "id": self.names.index(name) + 1001,
            "name": name,
            "state": "uploaded",
            "size": len(payload),
            "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
        }

    def write_assets(self) -> None:
        for name in self.names:
            (self.publication / name).write_bytes(name.encode("utf-8"))

    def urlopen(self, call: object, *, timeout: int) -> FakeJSONResponse:
        if timeout != 120:
            raise AssertionError("unexpected API timeout")
        url = call.full_url
        method = call.get_method()
        parsed = urllib.parse.urlsplit(url)
        releases_path = f"/repos/{self.repository}/releases"
        if method == "GET" and parsed.path == f"/repos/{self.repository}/branches/main":
            commit = self.main_ref_states[
                min(self.main_ref_calls, len(self.main_ref_states) - 1)
            ]
            self.main_ref_calls += 1
            return FakeJSONResponse({"protected": True, "commit": {"sha": commit}})
        if method == "GET" and parsed.path == (
            f"/repos/{self.repository}/commits/refs%2Ftags%2F{self.tag}"
        ):
            commit = self.tag_ref_states[
                min(self.tag_ref_calls, len(self.tag_ref_states) - 1)
            ]
            self.tag_ref_calls += 1
            return FakeJSONResponse({"sha": commit})
        if method == "GET" and parsed.path == f"/repos/{self.repository}/immutable-releases":
            state = self.immutable_policy_states[
                min(self.immutable_policy_calls, len(self.immutable_policy_states) - 1)
            ]
            self.immutable_policy_calls += 1
            return FakeJSONResponse({"enabled": state})
        if method == "GET" and parsed.path == releases_path:
            query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
            page = int(query["page"][0])
            payload = self.pages[page - 1]
            link = None
            if page < len(self.pages):
                link = (
                    f'<https://api.github.com{releases_path}?per_page=100&page={page + 1}>; '
                    'rel="next"'
                )
            return FakeJSONResponse(payload, link=link)
        if method == "POST" and parsed.path == releases_path:
            fields = json.loads(call.data.decode("utf-8"))
            self.created += 1
            self.release.update(fields)
            self.release["id"] = self.release_id
            self.release["immutable"] = False
            self.release["upload_url"] = (
                f"https://uploads.github.com/repos/{self.repository}/releases/"
                f"{self.release_id}/assets{{?name,label}}"
            )
            self.release["assets"] = []
            return FakeJSONResponse(self.release)
        if method == "DELETE" and parsed.path.startswith(f"{releases_path}/assets/"):
            asset_id = int(parsed.path.rsplit("/", 1)[1])
            assets = self.release["assets"]
            matches = [asset for asset in assets if asset["id"] == asset_id]
            if len(matches) != 1:
                raise AssertionError("fake asset deletion is not exact")
            self.release["assets"] = [
                asset for asset in assets if asset["id"] != asset_id
            ]
            self.deleted.append(asset_id)
            return FakeEmptyResponse()
        if method == "GET" and parsed.path == f"{releases_path}/{self.release_id}":
            return FakeJSONResponse(self.release)
        raise AssertionError(f"unexpected fake GitHub request: {method} {url}")

    def connection(self, host: str, port: int | None, *, timeout: int) -> FakeUploadConnection:
        if host != "uploads.github.com" or port is not None or timeout != 300:
            raise AssertionError("invalid fake upload connection")
        return FakeUploadConnection(self)

    def run(self) -> None:
        environment = {
            "GITHUB_REPOSITORY": self.repository,
            "GITHUB_SHA": self.commit,
            "GH_TOKEN": "fixture-token",
            "VERSION": self.version,
            "PUBLICATION": str(self.publication),
            "EVIDENCE_ROOT": str(self.evidence_root),
            "RELEASE_ID_FILE": str(self.release_id_file),
            "VERIFIED_PUBLICATION_ARTIFACT_ID": "777",
            "VERIFIED_PUBLICATION_ARTIFACT_DIGEST": "sha256:" + "b" * 64,
            "GITHUB_RUN_ID": "888",
            "GITHUB_RUN_ATTEMPT": "2",
        }
        self.evidence_root.mkdir(mode=0o700)
        with (
            mock.patch.dict(os.environ, environment, clear=False),
            mock.patch("urllib.request.urlopen", side_effect=self.urlopen),
            mock.patch("http.client.HTTPSConnection", side_effect=self.connection),
        ):
            exec(compile(embedded_draft_publisher(), "<draft-publisher>", "exec"), {})


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

    def test_preflight_peels_annotated_or_lightweight_tag_to_commit(self) -> None:
        block = job_block(PRODUCER, "metadata-preflight")
        self.assertIn('"repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG" --jq .ref', block)
        self.assertIn(
            '"repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2F$TAG" --jq .sha',
            block,
        )
        self.assertNotIn("--jq .object.sha", block)

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

    def test_preflight_peels_annotated_or_lightweight_tag_to_commit(self) -> None:
        preflight = job_block(PUBLISH, "metadata-preflight")
        self.assertIn('"repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG" --jq .ref', preflight)
        self.assertIn(
            '"repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2F$TAG" --jq .sha',
            preflight,
        )
        self.assertNotIn("--jq .object.sha", preflight)

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
            'f"{api}/releases?per_page=100&page=1"',
            'response.headers.get("Link")',
            "next_page_url(link)",
            'f"{api}/releases/{release_id}"',
            "multiple releases claim the toolchain tag",
            "easysplat-toolchain-release-owner:v1:",
            'release.get("target_commitish") != commit',
            'release.get("name") != tag',
            'release.get("body") != owner',
            'release.get("immutable") is not False',
            'f"{api}/immutable-releases"',
            "require_immutable_release_policy()",
            "require_protected_source_refs()",
            "protected main moved during toolchain publication",
            "toolchain tag moved during publication",
            'state == "starter"',
            'state != "uploaded"',
            'f"{api}/releases/assets/{asset[\'id\']}"',
            "duplicate asset",
            "manual-publication-request.json",
            '"resolved_tag_commit": resolved_tag_commit',
            '"retention_days": 45',
            "VERIFIED_PUBLICATION_ARTIFACT_ID",
            "publication_boundary",
            "independent_human_exact_id_refetch",
            "Preserve manual publication evidence",
            "toolchain-manual-publication-${{ github.sha }}",
            "Report the preserved owned draft",
        ):
            self.assertIn(required, draft)
        for forbidden in (
            "immutable == true",
            "--latest",
            "prerelease=true",
            "gh release edit",
            "git tag",
            "git push",
            "scripts/",
            "actions/checkout@",
            "/releases/tags/",
        ):
            self.assertNotIn(forbidden, draft)
        self.assertEqual(draft.count("          require_immutable_release_policy()"), 2)
        self.assertEqual(
            draft.count(
                "          resolved_tag_commit = require_protected_source_refs()"
            ),
            2,
        )

        first_ref_check = draft.index(
            "          resolved_tag_commit = require_protected_source_refs()"
        )
        first_mutation = draft.index("              created = request(")
        final_ref_check = draft.rindex(
            "          resolved_tag_commit = require_protected_source_refs()"
        )
        evidence = draft.index("          evidence = {")
        self.assertLess(first_ref_check, first_mutation)
        self.assertLess(final_ref_check, evidence)

    def test_draft_publisher_requires_immutable_releases_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            api = FakeReleaseAPI(root)
            api.write_assets()
            api.pages = [[]]
            api.immutable_policy_states = [False]

            with self.assertRaises(SystemExit):
                api.run()

            self.assertEqual(api.created, 0)
            self.assertEqual(api.deleted, [])
            self.assertEqual(api.uploaded, [])

    def test_draft_publisher_rechecks_immutable_releases_after_upload(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            api = FakeReleaseAPI(root)
            api.write_assets()
            api.pages = [[]]
            api.immutable_policy_states = [True, False]

            with self.assertRaises(SystemExit):
                api.run()

            self.assertEqual(api.created, 1)
            self.assertEqual(set(api.uploaded), set(api.names))
            self.assertEqual(api.immutable_policy_calls, 2)

    def test_draft_publisher_creates_an_owned_exact_release(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            api = FakeReleaseAPI(root)
            api.write_assets()
            api.pages = [[]]

            api.run()

            self.assertEqual(api.created, 1)
            self.assertEqual(set(api.uploaded), set(api.names))
            self.assertEqual(api.release["body"], api.owner)
            self.assertEqual(
                {asset["name"] for asset in api.release["assets"]}, set(api.names)
            )
            evidence = json.loads(
                (api.evidence_root / "manual-publication-request.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(
                set(evidence),
                {
                    "assets",
                    "body",
                    "current_release_state",
                    "owner",
                    "publication_boundary",
                    "publication_request",
                    "release_id",
                    "repository",
                    "resolved_tag_commit",
                    "schema_version",
                    "source_commit",
                    "tag",
                    "verified_publication_artifact",
                    "workflow_run_attempt",
                    "workflow_run_id",
                },
            )
            self.assertEqual(evidence["release_id"], api.release_id)
            self.assertEqual(evidence["repository"], api.repository)
            self.assertEqual(evidence["source_commit"], api.commit)
            self.assertEqual(evidence["tag"], api.tag)
            self.assertEqual(evidence["resolved_tag_commit"], api.commit)
            self.assertEqual(evidence["owner"], api.owner)
            self.assertEqual(
                evidence["current_release_state"],
                {"draft": True, "immutable": False, "prerelease": False},
            )
            self.assertEqual(
                evidence["publication_request"],
                {"draft": False, "make_latest": "false", "prerelease": False},
            )
            self.assertEqual(
                evidence["verified_publication_artifact"],
                {
                    "digest": "sha256:" + "b" * 64,
                    "id": 777,
                    "retention_days": 45,
                },
            )
            self.assertEqual(
                evidence["assets"],
                sorted(
                    [
                        {
                            "digest": asset["digest"],
                            "id": asset["id"],
                            "name": asset["name"],
                            "size_bytes": asset["size"],
                        }
                        for asset in api.release["assets"]
                    ],
                    key=lambda asset: asset["name"],
                ),
            )
            self.assertEqual(api.release_id_file.read_text(encoding="utf-8"), "321\n")

    def test_draft_publisher_rejects_moved_source_refs_before_mutation(self) -> None:
        for ref in ("main", "tag"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as raw:
                api = FakeReleaseAPI(Path(raw))
                api.write_assets()
                api.pages = [[]]
                if ref == "main":
                    api.main_ref_states = ["c" * 40]
                else:
                    api.tag_ref_states = ["c" * 40]

                with self.assertRaises(SystemExit):
                    api.run()

                self.assertEqual(api.created, 0)
                self.assertEqual(api.deleted, [])
                self.assertEqual(api.uploaded, [])

    def test_draft_publisher_rejects_moved_source_refs_before_handoff(self) -> None:
        for ref in ("main", "tag"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as raw:
                api = FakeReleaseAPI(Path(raw))
                api.write_assets()
                api.pages = [[]]
                if ref == "main":
                    api.main_ref_states = [api.commit, "c" * 40]
                else:
                    api.tag_ref_states = [api.commit, "c" * 40]

                with self.assertRaises(SystemExit):
                    api.run()

                self.assertEqual(api.created, 1)
                self.assertEqual(set(api.uploaded), set(api.names))
                self.assertFalse(
                    (api.evidence_root / "manual-publication-request.json").exists()
                )

    def test_draft_publisher_resumes_a_later_page_and_only_uploads_missing_assets(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            api = FakeReleaseAPI(root)
            api.write_assets()
            present = api.names[:4]
            starter = {
                **api.asset(api.names[4]),
                "state": "starter",
                "size": 0,
                "digest": None,
            }
            api.release["assets"] = [api.asset(name) for name in present] + [starter]
            api.pages = [[{"id": 999, "tag_name": "unrelated"}], [api.release]]

            api.run()

            self.assertEqual(api.created, 0)
            self.assertEqual(api.deleted, [starter["id"]])
            self.assertEqual(set(api.uploaded), set(api.names[4:]))
            self.assertEqual(
                {asset["name"] for asset in api.release["assets"]}, set(api.names)
            )

    def test_draft_publisher_rejects_foreign_or_corrupt_release_state(self) -> None:
        cases = (
            "duplicate-tag",
            "invalid-id",
            "foreign-owner",
            "wrong-commit",
            "published",
            "prerelease",
            "immutable",
            "malformed-asset",
            "duplicate-asset",
            "duplicate-asset-id",
            "unexpected-asset",
            "non-uploaded-asset",
            "nonempty-starter-asset",
            "wrong-digest",
        )
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                api = FakeReleaseAPI(root)
                api.write_assets()
                assets = [api.asset(name) for name in api.names]
                api.release["assets"] = assets
                if case == "duplicate-tag":
                    api.pages = [[api.release, {**api.release, "id": 322}]]
                elif case == "invalid-id":
                    api.pages = [[{"id": False, "tag_name": api.tag}]]
                elif case == "foreign-owner":
                    api.release["body"] = "<!-- foreign -->"
                elif case == "wrong-commit":
                    api.release["target_commitish"] = "b" * 40
                elif case == "published":
                    api.release["draft"] = False
                elif case == "prerelease":
                    api.release["prerelease"] = True
                elif case == "immutable":
                    api.release["immutable"] = True
                elif case == "malformed-asset":
                    api.release["assets"] = ["not-an-asset"]
                elif case == "duplicate-asset":
                    api.release["assets"] = [assets[0], assets[0]]
                elif case == "duplicate-asset-id":
                    api.release["assets"] = [assets[0], {**assets[1], "id": assets[0]["id"]}]
                elif case == "unexpected-asset":
                    api.release["assets"] = [{**assets[0], "name": "unexpected.zip"}]
                elif case == "non-uploaded-asset":
                    api.release["assets"] = [{**assets[0], "state": "new"}]
                elif case == "nonempty-starter-asset":
                    api.release["assets"] = [
                        {**assets[0], "state": "starter", "digest": None}
                    ]
                elif case == "wrong-digest":
                    api.release["assets"] = [{**assets[0], "digest": "sha256:" + "0" * 64}]

                with self.assertRaises(SystemExit):
                    api.run()


if __name__ == "__main__":
    unittest.main()
