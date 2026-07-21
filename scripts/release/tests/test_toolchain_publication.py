#!/usr/bin/env python3
"""Contract tests for the post-sign toolchain publication verifier."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "toolchain_publication.py"
SPEC = importlib.util.spec_from_file_location("toolchain_publication", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

VERSION = "2.0.0"
APP_VERSION = "0.2.0"
REPOSITORY = "dud8/EasySplat"
COMMIT = "a" * 40
AUTHORITY_COMMIT = "b" * 40
PUBLIC_KEY = bytes(range(32))
SUITE_RUN_ID = "12345678-1234-5678-9234-567812345678"


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.producer = root / "producer"
        self.producer.mkdir()
        self.request_dir = root / "request"
        self.request_dir.mkdir()
        self.authority = root / "authority-handoff"
        self.authority.mkdir()
        self.benchmark = root / "benchmark"
        self.benchmark.mkdir()
        self.public_key = root / "public-key.txt"
        self.public_key.write_text(base64.b64encode(PUBLIC_KEY).decode("ascii"))

        self.archive_names = {
            "macos-arm64-core": f"toolchain-macos-arm64-{VERSION}-core.zip",
            "geometry-da3-base": f"toolchain-geometry-da3-base-{VERSION}.zip",
            "geometry-da3-small": f"toolchain-geometry-da3-small-{VERSION}.zip",
        }
        self.components = []
        final_archives = []
        for index, (name, filename) in enumerate(self.archive_names.items(), start=1):
            path = self.producer / filename
            member_name = f"fixture/{name}.txt"
            member_payload = f"payload-{index}\n".encode()
            with zipfile.ZipFile(path, "w") as archive:
                member = zipfile.ZipInfo(member_name)
                member.create_system = 3
                member.external_attr = 0o100644 << 16
                archive.writestr(member, member_payload)
            payload = path.read_bytes()
            self.components.append(
                {
                    "name": name,
                    "capabilities": [f"fixture.{index}"],
                    "url": (
                        f"https://github.com/{REPOSITORY}/releases/download/"
                        f"toolchain-v{VERSION}/{filename}"
                    ),
                    "sha256": digest(payload),
                    "sizeBytes": len(payload),
                    "expandedSizeBytes": len(member_payload),
                    "expandedClosureSHA256": digest(member_payload),
                    "contents": [member_name],
                    "criticalFileHashes": {member_name: digest(member_payload)},
                    "dependencies": [],
                    "requirement": "required" if index == 1 else "optional",
                }
            )
            final_archives.append(
                {
                    "component": {1: "core", 2: "base", 3: "small"}[index],
                    "name": filename,
                    "sha256": digest(payload),
                    "size": len(payload),
                }
            )

        (self.producer / "toolchain-build-host.json").write_bytes(
            canonical({"schemaVersion": 1, "hostRole": "identity-free-production-builder"})
        )
        self.finalization = {
            "schemaVersion": 1,
            "kind": "easysplat-signed-toolchain-finalization",
            "toolchainVersion": VERSION,
            "identityFingerprintSHA1": "C" * 40,
            "teamID": "D3HAX9G357",
            "signedAt": "2026-07-19T12:00:00Z",
            "sourceCommit": COMMIT,
            "sourceInputs": [],
            "unsignedComponentArchives": [],
            "builderAttestedUnsignedReleaseRequest": {
                "name": "toolchain-release-request.json",
                "sha256": "d" * 64,
                "manifestSHA256": "e" * 64,
            },
            "builderArtifactAuthority": {
                "repository": REPOSITORY,
                "workflowRunID": 90,
                "sourceCommit": COMMIT,
                "unsignedArtifactID": 91,
                "unsignedArtifactDigest": "sha256:" + "1" * 64,
                "requestArtifactID": 92,
                "requestArtifactDigest": "sha256:" + "2" * 64,
            },
            "distributionSigningReceipt": {
                "path": "provenance/distribution-signing.json",
                "sha256": "f" * 64,
            },
            "supplyChain": {
                "path": "supply-chain/components.json",
                "sha256": "3" * 64,
            },
            "finalArchives": final_archives,
        }
        (self.producer / "distribution-signing-finalization.json").write_bytes(
            canonical(self.finalization)
        )
        for name in ("core-notarization.json", "da3-base-notarization.json"):
            (self.producer / name).write_bytes(canonical({"fixture": name}))

        unsigned_manifest = {
            "schemaVersion": 2,
            "toolchainAPI": 2,
            "keyID": digest(PUBLIC_KEY),
            "version": VERSION,
            "publishedAt": "2026-07-19T12:30:00Z",
            "appVersionRange": {"minimum": APP_VERSION, "maximumExclusive": "0.3.0"},
            "components": self.components,
            "signatureEd25519": "",
        }
        self.request = {
            "schemaVersion": 2,
            "sourceRepository": REPOSITORY,
            "sourceCommit": COMMIT,
            "manifestSHA256": digest(canonical(unsigned_manifest)),
            "manifest": unsigned_manifest,
        }
        self.request_path = self.request_dir / "toolchain-release-request.json"
        self.request_path.write_bytes(canonical(self.request))
        self.request_sha = digest(self.request_path.read_bytes())

        self.manifest = dict(unsigned_manifest)
        self.manifest["signatureEd25519"] = base64.b64encode(bytes(64)).decode("ascii")
        manifest_bytes = canonical(self.manifest)
        envelope = {
            "schemaVersion": 2,
            "kind": "easysplat-toolchain-authority-envelope",
            "sourceRepository": REPOSITORY,
            "sourceCommit": COMMIT,
            "sourceWorkflowPath": ".github/workflows/toolchain-build.yml",
            "sourceRunID": 100,
            "sourceRunAttempt": 2,
            "producerArtifact": {
                "id": 101,
                "name": f"toolchain-final-producer-{VERSION}",
                "digest": "sha256:" + "4" * 64,
            },
            "requestArtifact": {
                "id": 102,
                "name": f"toolchain-post-sign-request-{VERSION}",
                "digest": "sha256:" + "5" * 64,
                "requestSHA256": self.request_sha,
            },
            "authorityRepository": "dud8/easysplat-release-authority",
            "authorityCommit": AUTHORITY_COMMIT,
            "authorityRunID": 200,
            "authorityRunAttempt": 3,
            "releaseTag": f"toolchain-v{VERSION}",
            "keyID": digest(PUBLIC_KEY),
            "signedManifestSHA256": digest(manifest_bytes),
            "manifest": self.manifest,
        }
        envelope_bytes = canonical(envelope)
        receipt = {
            "schemaVersion": 2,
            "kind": "easysplat-toolchain-authority-receipt",
            "keyID": digest(PUBLIC_KEY),
            "sourceRepository": REPOSITORY,
            "sourceCommit": COMMIT,
            "sourceRunID": 100,
            "sourceRunAttempt": 2,
            "producerArtifact": envelope["producerArtifact"],
            "requestArtifact": envelope["requestArtifact"],
            "authorityRepository": "dud8/easysplat-release-authority",
            "authorityCommit": AUTHORITY_COMMIT,
            "authorityRunID": 200,
            "authorityRunAttempt": 3,
            "authorityPayloadArtifact": {
                "id": 201,
                "name": f"toolchain-authority-payload-{VERSION}",
                "digest": "sha256:" + "6" * 64,
            },
            "authorityEnvelopeSHA256": digest(envelope_bytes),
            "signedManifestSHA256": digest(manifest_bytes),
            "sourceReleaseRequestSHA256": self.request_sha,
            "signedAt": "2026-07-19T12:45:00Z",
            "signatureEd25519": base64.b64encode(bytes(64)).decode("ascii"),
        }
        receipt_bytes = canonical(receipt)
        self.payload_zip = self.authority / "toolchain-authority-payload.zip"
        with zipfile.ZipFile(self.payload_zip, "w") as archive:
            archive.writestr("manifest.json", manifest_bytes)
            archive.writestr("toolchain-authority-envelope.json", envelope_bytes)
        self.receipt_zip = self.authority / "toolchain-authority-receipt.zip"
        with zipfile.ZipFile(self.receipt_zip, "w") as archive:
            archive.writestr("toolchain-authority-receipt.json", receipt_bytes)
        self.transport = {
            "schemaVersion": 1,
            "sourceRepository": REPOSITORY,
            "sourceCommit": COMMIT,
            "handoffRunID": 300,
            "handoffRunAttempt": 1,
            "authorityRepository": "dud8/easysplat-release-authority",
            "authorityCommit": AUTHORITY_COMMIT,
            "authorityRunID": 200,
            "authorityRunAttempt": 3,
            "payloadArtifact": {
                "id": 201,
                "name": f"toolchain-authority-payload-{VERSION}",
                "digest": "sha256:" + "6" * 64,
                "downloadSHA256": digest(self.payload_zip.read_bytes()),
            },
            "receiptArtifact": {
                "id": 202,
                "name": f"toolchain-authority-receipt-{VERSION}",
                "digest": "sha256:" + "7" * 64,
                "downloadSHA256": digest(self.receipt_zip.read_bytes()),
            },
        }
        self.transport_path = self.authority / "authority-transport.json"
        self.transport_path.write_bytes(canonical(self.transport))

        self.identity = MODULE.ExpectedIdentity(
            version=VERSION,
            app_version=APP_VERSION,
            source_repository=REPOSITORY,
            source_commit=COMMIT,
            producer_run_id=100,
            producer_run_attempt=2,
            producer_artifact_id=101,
            producer_artifact_name=f"toolchain-final-producer-{VERSION}",
            producer_artifact_digest="sha256:" + "4" * 64,
            request_artifact_id=102,
            request_artifact_name=f"toolchain-post-sign-request-{VERSION}",
            request_artifact_digest="sha256:" + "5" * 64,
            request_sha256=self.request_sha,
            authority_repository="dud8/easysplat-release-authority",
            authority_commit=AUTHORITY_COMMIT,
            authority_run_id=200,
            authority_run_attempt=3,
            authority_payload_artifact_id=201,
            authority_payload_artifact_name=f"toolchain-authority-payload-{VERSION}",
            authority_payload_artifact_digest="sha256:" + "6" * 64,
            authority_receipt_artifact_id=202,
            authority_receipt_artifact_name=f"toolchain-authority-receipt-{VERSION}",
            authority_receipt_artifact_digest="sha256:" + "7" * 64,
            handoff_run_id=300,
            handoff_run_attempt=1,
        )

    def write_benchmark(
        self, toolchain_identity: str, *, run_id: str = SUITE_RUN_ID
    ) -> Path:
        payload = {
            "schema_version": 2,
            "run_id": run_id,
            "started_at_utc": "2026-07-19T13:00:00Z",
            "ended_at_utc": "2026-07-19T14:00:00Z",
            "profile": "release",
            "status": "passed",
            "blocking_reasons": [],
            "failures": [],
            "scene_results": [],
            "aggregates": {},
            "machine": {},
            "app_version": APP_VERSION,
            "toolchain_identity": toolchain_identity,
            "thresholds_digest": "sha256:" + "8" * 64,
            "corpus_digest": "sha256:" + "9" * 64,
            "git": {"commit": COMMIT, "dirty": False},
            "raw_evidence_retention": "excluded",
            "missing_requirements": {},
        }
        path = self.benchmark / "verified-suite.json"
        path.write_bytes(json.dumps(payload, sort_keys=True).encode("utf-8"))
        return path

    def write_benchmark_evidence(
        self,
        benchmark_path: Path,
        *,
        run_id: int = 400,
        run_attempt: int = 2,
        artifact_id: int = 401,
        artifact_name: str | None = None,
        artifact_digest: str = "sha256:" + "a" * 64,
    ) -> Path:
        payload = {
            "schemaVersion": 1,
            "sourceRepository": REPOSITORY,
            "sourceCommit": COMMIT,
            "benchmarkRunID": run_id,
            "benchmarkRunAttempt": run_attempt,
            "benchmarkArtifact": {
                "id": artifact_id,
                "name": artifact_name or f"easysplat-benchmark-{COMMIT}",
                "digest": artifact_digest,
                "verifiedSuiteSHA256": digest(benchmark_path.read_bytes()),
            },
        }
        path = self.benchmark / "benchmark-transport.json"
        path.write_bytes(canonical(payload))
        return path


class ToolchainPublicationTests(unittest.TestCase):
    def test_verified_components_install_atomically_with_signed_file_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            install = Path(temporary) / "installed"
            MODULE.install_verified_toolchain(
                install,
                producer=fixture.producer,
                manifest=fixture.manifest,
            )
            for index, component_name in enumerate(
                (
                    "macos-arm64-core",
                    "geometry-da3-base",
                    "geometry-da3-small",
                ),
                start=1,
            ):
                self.assertEqual(
                    (install / f"fixture/{component_name}.txt").read_bytes(),
                    f"payload-{index}\n".encode(),
                )
            state = json.loads(
                (install / ".easysplat_toolchain_state.json").read_bytes()
            )
            self.assertEqual(state["schemaVersion"], 2)
            self.assertEqual(state["signedManifest"], fixture.manifest)

    def test_install_rejects_archive_path_replacement_with_different_member_mode(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = Fixture(root)
            install = root / "installed"
            source = fixture.producer / fixture.archive_names["macos-arm64-core"]
            hostile = root / "same-members-different-mode.zip"
            member_name = "fixture/macos-arm64-core.txt"
            with zipfile.ZipFile(hostile, "w") as archive:
                member = zipfile.ZipInfo(member_name)
                member.create_system = 3
                member.external_attr = 0o100755 << 16
                archive.writestr(member, b"payload-1\n")

            real_zip_file = zipfile.ZipFile
            replaced = False

            def replace_before_zip_open(file: object, *args: object, **kwargs: object):
                nonlocal replaced
                if not replaced:
                    replaced = True
                    os.replace(hostile, source)
                return real_zip_file(file, *args, **kwargs)

            with mock.patch.object(
                MODULE.zipfile, "ZipFile", side_effect=replace_before_zip_open
            ):
                with self.assertRaisesRegex(
                    MODULE.ToolchainPublicationError, "changed after it was staged"
                ):
                    MODULE.install_verified_toolchain(
                        install,
                        producer=fixture.producer,
                        manifest=fixture.manifest,
                    )
            self.assertFalse(install.exists())

    def test_valid_post_sign_closure_produces_exact_public_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output = Path(temporary) / "publication"
            with mock.patch.object(MODULE.BASE, "verify_ed25519", return_value=True):
                authority = MODULE.validate_authority_closure(
                    producer=fixture.producer,
                    request_path=fixture.request_path,
                    authority_handoff=fixture.authority,
                    public_key_path=fixture.public_key,
                    expected=fixture.identity,
                    notary_validator=lambda *_args: None,
                )
                manifest = authority.manifest
                benchmark = fixture.write_benchmark(MODULE.full_toolchain_identity(manifest))
                benchmark_evidence = fixture.write_benchmark_evidence(benchmark)
                validated_benchmark_evidence = MODULE.validate_benchmark_binding(
                    benchmark,
                    evidence_path=benchmark_evidence,
                    manifest=manifest,
                    expected=fixture.identity,
                    benchmark_run_id=400,
                    benchmark_run_attempt=2,
                    benchmark_artifact_id=401,
                    benchmark_artifact_name=f"easysplat-benchmark-{COMMIT}",
                    benchmark_artifact_digest="sha256:" + "a" * 64,
                )
                MODULE.prepare_publication_output(
                    output,
                    producer=fixture.producer,
                    request_path=fixture.request_path,
                    authority=authority,
                    manifest=manifest,
                    expected_request_sha256=fixture.request_sha,
                    benchmark_evidence=validated_benchmark_evidence,
                )
            published_benchmark = json.loads(
                (output / "toolchain-benchmark-evidence.json").read_bytes()
            )
            self.assertEqual(
                published_benchmark["fullToolchainIdentity"],
                MODULE.full_toolchain_identity(manifest),
            )
            self.assertEqual(published_benchmark["benchmarkRunID"], 400)
            self.assertEqual(published_benchmark["benchmarkSuiteRunID"], SUITE_RUN_ID)
            self.assertEqual(published_benchmark["benchmarkArtifact"]["id"], 401)
            self.assertEqual(
                published_benchmark["benchmarkArtifact"]["digest"],
                "sha256:" + "a" * 64,
            )
            self.assertEqual(
                {path.name for path in output.iterdir()},
                {
                    *fixture.archive_names.values(),
                    "manifest.json",
                    "toolchain-release-request.json",
                    "toolchain-authority-envelope.json",
                    "toolchain-authority-receipt.json",
                    "toolchain-benchmark-evidence.json",
                },
            )

    def test_benchmark_transport_identity_mismatches_fail_closed(self) -> None:
        cases = {
            "run": {"benchmark_run_id": 999},
            "run attempt": {"benchmark_run_attempt": 999},
            "artifact id": {"benchmark_artifact_id": 999},
            "artifact name": {"benchmark_artifact_name": "wrong"},
            "artifact digest": {
                "benchmark_artifact_digest": "sha256:" + "f" * 64
            },
        }
        for label, override in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                fixture = Fixture(Path(temporary))
                benchmark = fixture.write_benchmark(
                    MODULE.full_toolchain_identity(fixture.manifest)
                )
                evidence = fixture.write_benchmark_evidence(benchmark)
                arguments = {
                    "benchmark_run_id": 400,
                    "benchmark_run_attempt": 2,
                    "benchmark_artifact_id": 401,
                    "benchmark_artifact_name": f"easysplat-benchmark-{COMMIT}",
                    "benchmark_artifact_digest": "sha256:" + "a" * 64,
                    **override,
                }
                with self.assertRaisesRegex(
                    MODULE.ToolchainPublicationError, "benchmark transport identity"
                ):
                    MODULE.validate_benchmark_binding(
                        benchmark,
                        evidence_path=evidence,
                        manifest=fixture.manifest,
                        expected=fixture.identity,
                        **arguments,
                    )

    def test_benchmark_transport_must_hash_verified_suite_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            benchmark = fixture.write_benchmark(
                MODULE.full_toolchain_identity(fixture.manifest)
            )
            evidence = fixture.write_benchmark_evidence(benchmark)
            benchmark.write_bytes(benchmark.read_bytes() + b"\n")
            with self.assertRaisesRegex(
                MODULE.ToolchainPublicationError,
                "verified benchmark suite does not match its verified digest",
            ):
                MODULE.validate_benchmark_binding(
                    benchmark,
                    evidence_path=evidence,
                    manifest=fixture.manifest,
                    expected=fixture.identity,
                    benchmark_run_id=400,
                    benchmark_run_attempt=2,
                    benchmark_artifact_id=401,
                    benchmark_artifact_name=f"easysplat-benchmark-{COMMIT}",
                    benchmark_artifact_digest="sha256:" + "a" * 64,
                )

    def test_descriptor_staging_rejects_pathname_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.bin"
            destination = root / "staged.bin"
            displaced = root / "displaced.bin"
            source.write_bytes(b"trusted bytes")
            trusted_digest = digest(source.read_bytes())
            original_read = MODULE.os.read
            replaced = False

            def replace_pathname(fd: int, count: int) -> bytes:
                nonlocal replaced
                if not replaced:
                    replaced = True
                    source.replace(displaced)
                    source.write_bytes(b"hostile replacement")
                return original_read(fd, count)

            with mock.patch.object(MODULE.os, "read", side_effect=replace_pathname):
                with self.assertRaisesRegex(
                    MODULE.ToolchainPublicationError, "changed while being staged"
                ):
                    MODULE._stage_regular_snapshot(
                        source,
                        destination,
                        maximum=1024,
                        label="fixture source",
                        expected_sha256=trusted_digest,
                    )
            self.assertFalse(destination.exists())

    def test_request_must_hash_final_signed_producer_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            archive = fixture.producer / fixture.archive_names["macos-arm64-core"]
            archive.write_bytes(archive.read_bytes() + b"tamper")
            with self.assertRaisesRegex(MODULE.ToolchainPublicationError, "final signed archive"):
                MODULE.validate_producer(
                    fixture.producer,
                    fixture.request_path,
                    version=VERSION,
                    source_repository=REPOSITORY,
                    source_commit=COMMIT,
                    notary_validator=lambda *_args: None,
                )

    def test_publication_uses_validated_authority_zip_snapshot_after_path_replacement(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output = Path(temporary) / "publication"
            with mock.patch.object(MODULE.BASE, "verify_ed25519", return_value=True):
                closure = MODULE.validate_authority_closure(
                    producer=fixture.producer,
                    request_path=fixture.request_path,
                    authority_handoff=fixture.authority,
                    public_key_path=fixture.public_key,
                    expected=fixture.identity,
                    notary_validator=lambda *_args: None,
                )

            fixture.payload_zip.unlink()
            with zipfile.ZipFile(fixture.payload_zip, "w") as archive:
                archive.writestr("manifest.json", canonical({"hostile": True}))
                archive.writestr(
                    "toolchain-authority-envelope.json", canonical({"hostile": True})
                )
            fixture.receipt_zip.unlink()
            with zipfile.ZipFile(fixture.receipt_zip, "w") as archive:
                archive.writestr(
                    "toolchain-authority-receipt.json", canonical({"hostile": True})
                )

            MODULE.prepare_publication_output(
                output,
                producer=fixture.producer,
                request_path=fixture.request_path,
                authority=closure,
                manifest=closure.manifest,
                expected_request_sha256=fixture.request_sha,
                benchmark_evidence={"fixture": True},
            )
            self.assertEqual(
                (output / "manifest.json").read_bytes(), closure.manifest_raw
            )
            self.assertEqual(
                (output / "toolchain-authority-envelope.json").read_bytes(),
                closure.envelope_raw,
            )
            self.assertEqual(
                (output / "toolchain-authority-receipt.json").read_bytes(),
                closure.receipt_raw,
            )

    def test_authority_identity_mismatch_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            wrong = MODULE.ExpectedIdentity(
                **{**fixture.identity.__dict__, "producer_artifact_id": 999}
            )
            with mock.patch.object(MODULE.BASE, "verify_ed25519", return_value=True):
                with self.assertRaisesRegex(
                    MODULE.ToolchainPublicationError, "producer artifact identity"
                ):
                    MODULE.validate_authority_closure(
                        producer=fixture.producer,
                        request_path=fixture.request_path,
                        authority_handoff=fixture.authority,
                        public_key_path=fixture.public_key,
                        expected=wrong,
                        notary_validator=lambda *_args: None,
                    )

    def test_obsolete_unsigned_source_artifacts_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            with zipfile.ZipFile(fixture.payload_zip) as archive:
                manifest = archive.read("manifest.json")
                envelope = json.loads(archive.read("toolchain-authority-envelope.json"))
            envelope["sourceArtifacts"] = []
            with zipfile.ZipFile(fixture.payload_zip, "w") as archive:
                archive.writestr("manifest.json", manifest)
                archive.writestr("toolchain-authority-envelope.json", canonical(envelope))
            fixture.transport["payloadArtifact"]["downloadSHA256"] = digest(
                fixture.payload_zip.read_bytes()
            )
            fixture.transport_path.write_bytes(canonical(fixture.transport))
            with mock.patch.object(MODULE.BASE, "verify_ed25519", return_value=True):
                with self.assertRaisesRegex(
                    MODULE.ToolchainPublicationError, "authority envelope fields"
                ):
                    MODULE.validate_authority_closure(
                        producer=fixture.producer,
                        request_path=fixture.request_path,
                        authority_handoff=fixture.authority,
                        public_key_path=fixture.public_key,
                        expected=fixture.identity,
                        notary_validator=lambda *_args: None,
                    )

    def test_benchmark_must_bind_final_signed_full_toolchain_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            benchmark = fixture.write_benchmark("sha256:" + "0" * 64)
            evidence = fixture.write_benchmark_evidence(benchmark)
            with self.assertRaisesRegex(
                MODULE.ToolchainPublicationError, "different signed toolchain closure"
            ):
                MODULE.validate_benchmark_binding(
                    benchmark,
                    evidence_path=evidence,
                    manifest=fixture.manifest,
                    expected=fixture.identity,
                    benchmark_run_id=400,
                    benchmark_run_attempt=2,
                    benchmark_artifact_id=401,
                    benchmark_artifact_name=f"easysplat-benchmark-{COMMIT}",
                    benchmark_artifact_digest="sha256:" + "a" * 64,
                )


if __name__ == "__main__":
    unittest.main()
