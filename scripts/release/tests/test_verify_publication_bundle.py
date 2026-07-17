import base64
import importlib.util
import hashlib
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "verify_publication_bundle.py"
SPEC = importlib.util.spec_from_file_location("verify_publication_bundle", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

GENERATOR_SCRIPT = Path(__file__).resolve().parents[1] / "generate_release_metadata.py"
GENERATOR_SPEC = importlib.util.spec_from_file_location(
    "release_metadata_fixture_generator", GENERATOR_SCRIPT
)
assert GENERATOR_SPEC and GENERATOR_SPEC.loader
GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
sys.modules[GENERATOR_SPEC.name] = GENERATOR
GENERATOR_SPEC.loader.exec_module(GENERATOR)


VERSION = "0.2.0-beta.1"
TOOLCHAIN_VERSION = "2.0.0"
REPOSITORY = "dud8/EasySplat"
COMMIT = "a" * 40
TAG = f"v{VERSION}"


def build_names() -> tuple[str, ...]:
    return tuple(MODULE.build_file_limits(VERSION))


def write_build_payload(root: Path) -> None:
    root.mkdir()
    for index, name in enumerate(build_names(), start=1):
        (root / name).write_bytes(f"fixture-{index}\n".encode())


def write_build_closure(root: Path) -> None:
    MODULE.create_build_closure(
        root,
        app_version=VERSION,
        toolchain_version=TOOLCHAIN_VERSION,
        source_repository=REPOSITORY,
        source_commit=COMMIT,
        tag=TAG,
        benchmark_run_id="1234",
        benchmark_artifact_id="5678",
        benchmark_artifact_digest="sha256:" + "b" * 64,
    )


def authority_fixture(root: Path) -> dict[str, object]:
    public_key = bytes(range(32))
    public_key_path = root / "public-key.txt"
    public_key_path.write_text(
        base64.b64encode(public_key).decode("ascii"), encoding="ascii"
    )
    manifest: dict[str, object] = {
        "keyID": hashlib.sha256(public_key).hexdigest(),
        "signatureEd25519": base64.b64encode(bytes(64)).decode("ascii"),
    }
    manifest_path = root / "manifest.json"
    manifest_bytes = MODULE.signature_json_bytes(manifest)
    manifest_path.write_bytes(manifest_bytes)
    unsigned_manifest = dict(manifest)
    unsigned_manifest["signatureEd25519"] = ""
    unsigned_manifest_sha = hashlib.sha256(
        MODULE.signature_json_bytes(unsigned_manifest)
    ).hexdigest()
    request: dict[str, object] = {
        "schemaVersion": 1,
        "sourceRepository": REPOSITORY,
        "sourceCommit": COMMIT,
        "manifestSHA256": unsigned_manifest_sha,
        "manifest": unsigned_manifest,
    }
    request_path = root / "toolchain-release-request.json"
    request_bytes = MODULE.signature_json_bytes(request)
    request_path.write_bytes(request_bytes)
    source_artifacts = [
        {
            "kind": "components",
            "name": f"toolchain-components-{TOOLCHAIN_VERSION}",
            "artifactID": 401,
            "artifactDigest": "sha256:" + "4" * 64,
            "payloadSHA256": "4" * 64,
            "sizeBytes": 41,
        },
        {
            "kind": "signingRequest",
            "name": f"toolchain-signing-request-{TOOLCHAIN_VERSION}",
            "artifactID": 402,
            "artifactDigest": "sha256:" + "5" * 64,
            "payloadSHA256": "5" * 64,
            "sizeBytes": 42,
        },
    ]
    request_sha = hashlib.sha256(request_bytes).hexdigest()
    envelope: dict[str, object] = {
        "schemaVersion": 1,
        "sourceRepository": REPOSITORY,
        "sourceRepositoryID": MODULE.CANONICAL_SOURCE_REPOSITORY_ID,
        "sourceCommit": COMMIT,
        "sourceWorkflowID": MODULE.CANONICAL_SOURCE_WORKFLOW_ID,
        "sourceWorkflowPath": MODULE.CANONICAL_SOURCE_WORKFLOW_PATH,
        "sourceRunID": 400,
        "sourceRunAttempt": 1,
        "sourceArtifacts": source_artifacts,
        "authorityRepository": MODULE.CANONICAL_AUTHORITY_REPOSITORY,
        "authorityRepositoryID": MODULE.CANONICAL_AUTHORITY_REPOSITORY_ID,
        "authorityCommit": "b" * 40,
        "authorityRunID": 500,
        "authorityRunAttempt": 1,
        "releaseTag": f"toolchain-v{TOOLCHAIN_VERSION}",
        "sourceReleaseRequestSHA256": request_sha,
        "unsignedManifestSHA256": unsigned_manifest_sha,
        "manifest": unsigned_manifest,
    }
    envelope_path = root / "authority-envelope.json"
    envelope_bytes = MODULE.signature_json_bytes(envelope)
    envelope_path.write_bytes(envelope_bytes)
    receipt: dict[str, object] = {
        key: envelope[key]
        for key in (
            "schemaVersion",
            "sourceRepository",
            "sourceRepositoryID",
            "sourceCommit",
            "sourceWorkflowID",
            "sourceWorkflowPath",
            "sourceRunID",
            "sourceRunAttempt",
            "sourceArtifacts",
            "authorityRepository",
            "authorityRepositoryID",
            "authorityCommit",
            "authorityRunID",
            "authorityRunAttempt",
            "releaseTag",
            "sourceReleaseRequestSHA256",
            "unsignedManifestSHA256",
        )
    }
    receipt.update(
        {
            "keyID": manifest["keyID"],
            "authorityEnvelopeSHA256": hashlib.sha256(envelope_bytes).hexdigest(),
            "signedManifestFileSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
            "signedAt": "2026-07-15T12:00:00Z",
            "signatureEd25519": base64.b64encode(bytes(64)).decode("ascii"),
        }
    )
    receipt_path = root / "authority-receipt.json"
    receipt_path.write_bytes(MODULE.signature_json_bytes(receipt))
    return {
        "public_key_path": public_key_path,
        "manifest_path": manifest_path,
        "request_path": request_path,
        "envelope_path": envelope_path,
        "receipt_path": receipt_path,
        "manifest": manifest,
        "request": request,
        "envelope": envelope,
        "receipt": receipt,
    }


def supply_chain_fixture(
    root: Path,
    *,
    archived_license: bytes = b"MIT\n",
    invalid_source: bool = False,
    invalid_artifact: bool = False,
) -> dict[str, object]:
    root.mkdir(parents=True, exist_ok=True)
    archives = (
        ("core", "licenses/core.txt", "core-component"),
        ("geometry-da3-base", "da3_mps/models/DA3-BASE/LICENSE", "base-component"),
        ("geometry-da3-small", "da3_mps/models/DA3-SMALL/LICENSE", "small-component"),
    )
    components = []
    files = []
    for archive_id, path, component_id in archives:
        component = {
            "id": component_id,
            "name": component_id,
            "type": "fixture",
            "version": "1.0.0",
            "revision": "a" * 40,
            "source": f"https://example.invalid/{component_id}",
            "buildCommand": "fixture",
            "license": "MIT",
            "linkage": "dynamic",
            "licenseFiles": [path],
            "dependencies": [],
            "files": [path],
        }
        if not components and invalid_source:
            component["source"] = "http://example.invalid/insecure"
        if not components and invalid_artifact:
            component["artifact"] = 42
            component["artifactSha256"] = "f" * 64
        row = {
            "component": component_id,
            "kind": "file",
            "path": path,
            "sha256": hashlib.sha256(b"MIT\n").hexdigest(),
            "size": len(b"MIT\n"),
        }
        components.append(component)
        files.append(row)
    components.sort(key=lambda row: row["id"])
    files.sort(key=lambda row: row["path"])
    component_payload = {
        "schemaVersion": 1,
        "toolchainVersion": TOOLCHAIN_VERSION,
        "components": components,
        "files": files,
    }
    component_bytes = MODULE.canonical_json_bytes(component_payload)
    component_sha = hashlib.sha256(component_bytes).hexdigest()
    artifact_rows = {
        archive_id: {
            "file": f"{archive_id}.zip",
            "downloadURL": f"https://github.com/{REPOSITORY}/releases/download/toolchain-v{TOOLCHAIN_VERSION}/{archive_id}.zip",
            "sha256": str(index) * 64,
            "size": index,
        }
        for index, (archive_id, _path, _component_id) in enumerate(archives, start=1)
    }
    artifacts = {
        "dmg": {
            "file": f"EasySplat-{VERSION}-unsigned.dmg",
            "downloadURL": (
                f"https://github.com/{REPOSITORY}/releases/download/"
                f"v{VERSION}/EasySplat-{VERSION}-unsigned.dmg"
            ),
            "sha256": "d" * 64,
            "size": 4,
        },
        "manifest": {
            "file": "manifest.json",
            "downloadURL": (
                f"https://github.com/{REPOSITORY}/releases/download/"
                f"toolchain-v{TOOLCHAIN_VERSION}/manifest.json"
            ),
            "sha256": "e" * 64,
            "size": 5,
        },
        **artifact_rows,
    }
    provenance = {
        "schemaVersion": 2,
        "releaseMode": "unsigned-beta",
        "appVersion": VERSION,
        "toolchainVersion": TOOLCHAIN_VERSION,
        "bundleIdentifier": "com.easysplat.app",
        "source": {
            "url": f"https://github.com/{REPOSITORY}",
            "commit": COMMIT,
            "buildCommand": "./scripts/release/build_app.sh",
        },
        "sourceDependencies": {
            "MetalSplatter": {
                "source": MODULE.METALSPLATTER_SOURCE,
                "basedOnRevision": MODULE.METALSPLATTER_BASE_REVISION,
                "vendoredTreeSHA256": "f" * 64,
                "sourceFileCount": 12,
                "license": "MIT",
                "buildCommand": "./scripts/release/build_app.sh",
                "integration": "statically linked with EasySplat compatibility changes",
            }
        },
        "createdAt": "2026-07-15T12:00:00Z",
        "supplyChain": {
            "schemaVersion": 1,
            "componentsSHA256": component_sha,
            "componentCount": len(components),
            "fileCount": len(files),
        },
        "artifacts": artifacts,
    }
    manifest = {
        "components": [
            {
                "name": "macos-arm64-core",
                "criticalFileHashes": {
                    "supply-chain/components.json": component_sha,
                },
            }
        ]
    }
    closure_payload = {
        "schemaVersion": 1,
        "toolchainVersion": TOOLCHAIN_VERSION,
        "componentsSHA256": component_sha,
        "archives": [
            {
                "id": archive_id,
                "file": artifact_rows[archive_id]["file"],
                "sha256": artifact_rows[archive_id]["sha256"],
                "size": artifact_rows[archive_id]["size"],
                "entries": [row for row in files if row["component"] == component_id],
            }
            for archive_id, _path, component_id in archives
        ],
    }
    archive_path = root / "licenses.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("EasySplat/LICENSE", b"MIT\n")
        archive.writestr("EasySplat/NOTICE.md", b"Notice\n")
        archive.writestr("MetalSplatter/LICENSE", b"MIT\n")
        archive.writestr(
            "Toolchain/supply-chain/components.json", component_bytes
        )
        archive.writestr(
            "toolchain-closure.json", MODULE.canonical_json_bytes(closure_payload)
        )
        for component in components:
            for license_path in component["licenseFiles"]:
                archive.writestr(f"Toolchain/{license_path}", archived_license)
    return {
        "archive_path": archive_path,
        "components": component_payload,
        "provenance": provenance,
        "manifest": manifest,
        "closure": closure_payload,
        "component_bytes": component_bytes,
    }


def spdx_fixture(supply_chain: dict[str, object]) -> dict[str, object]:
    component_payload = supply_chain["components"]
    closure_payload = supply_chain["closure"]
    closure = GENERATOR.ValidatedClosure(
        payload=component_payload,
        raw=supply_chain["component_bytes"],
        components={row["id"]: row for row in component_payload["components"]},
        files={row["path"]: row for row in component_payload["files"]},
        license_bytes={},
        archive_rows={row["id"]: row["entries"] for row in closure_payload["archives"]},
    )
    return GENERATOR.build_spdx(
        supply_chain["provenance"],
        closure,
        f"EasySplat-{VERSION}-licenses.zip",
    )


class BundleBoundaryTests(unittest.TestCase):
    def test_exact_build_bundle_and_closure_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            write_build_closure(root)

            closure = MODULE.validate_build_bundle(
                root,
                app_version=VERSION,
                toolchain_version=TOOLCHAIN_VERSION,
                source_repository=REPOSITORY,
                source_commit=COMMIT,
                tag=TAG,
                benchmark_run_id="1234",
                benchmark_artifact_id="5678",
                benchmark_artifact_digest="sha256:" + "b" * 64,
            )

            self.assertEqual(closure["release_mode"], "unsigned-beta")
            self.assertEqual(
                [row["name"] for row in closure["files"]], sorted(build_names())
            )

    def test_tampered_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            write_build_closure(root)
            (root / build_names()[0]).write_bytes(b"tampered")

            with self.assertRaisesRegex(MODULE.PublicationError, "closure mismatch"):
                MODULE.validate_build_bundle(
                    root,
                    app_version=VERSION,
                    toolchain_version=TOOLCHAIN_VERSION,
                    source_repository=REPOSITORY,
                    source_commit=COMMIT,
                    tag=TAG,
                    benchmark_run_id="1234",
                    benchmark_artifact_id="5678",
                    benchmark_artifact_digest="sha256:" + "b" * 64,
                )

    def test_extra_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            (root / "surprise.txt").write_text("extra", encoding="utf-8")

            with self.assertRaisesRegex(MODULE.PublicationError, "exact file set"):
                write_build_closure(root)

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            victim = root / build_names()[0]
            victim.unlink()
            victim.symlink_to(root / build_names()[1])

            with self.assertRaisesRegex(MODULE.PublicationError, "regular file"):
                write_build_closure(root)

    def test_hardlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            outside = Path(temporary) / "outside"
            os.link(root / build_names()[0], outside)

            with self.assertRaisesRegex(MODULE.PublicationError, "hard link"):
                write_build_closure(root)

    def test_oversize_file_is_rejected_before_hashing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            notes = root / f"EasySplat-{VERSION}-release-notes.txt"
            with notes.open("wb") as stream:
                stream.truncate(MODULE.build_file_limits(VERSION)[notes.name] + 1)

            with self.assertRaisesRegex(MODULE.PublicationError, "size limit"):
                write_build_closure(root)

    def test_malformed_closure_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bundle"
            write_build_payload(root)
            (root / MODULE.BUILD_CLOSURE_NAME).write_text("[]", encoding="utf-8")

            with self.assertRaisesRegex(MODULE.PublicationError, "JSON object"):
                MODULE.validate_build_bundle(
                    root,
                    app_version=VERSION,
                    toolchain_version=TOOLCHAIN_VERSION,
                    source_repository=REPOSITORY,
                    source_commit=COMMIT,
                    tag=TAG,
                    benchmark_run_id="1234",
                    benchmark_artifact_id="5678",
                    benchmark_artifact_digest="sha256:" + "b" * 64,
                )


class ArtifactContentTests(unittest.TestCase):
    def test_license_archive_is_bound_to_signed_components_and_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = supply_chain_fixture(Path(temporary))
            closure = MODULE.validate_license_archive(
                fixture["archive_path"],
                fixture["provenance"],
                fixture["manifest"],
                toolchain_version=TOOLCHAIN_VERSION,
            )
            self.assertEqual(closure["components"], fixture["components"])

            fixture["manifest"]["components"][0]["criticalFileHashes"][
                "supply-chain/components.json"
            ] = "0" * 64
            with self.assertRaisesRegex(MODULE.PublicationError, "signed component"):
                MODULE.validate_license_archive(
                    fixture["archive_path"],
                    fixture["provenance"],
                    fixture["manifest"],
                    toolchain_version=TOOLCHAIN_VERSION,
                )

            tampered = supply_chain_fixture(
                Path(temporary), archived_license=b"Not the mapped license\n"
            )
            with self.assertRaisesRegex(MODULE.PublicationError, "license bytes"):
                MODULE.validate_license_archive(
                    tampered["archive_path"],
                    tampered["provenance"],
                    tampered["manifest"],
                    toolchain_version=TOOLCHAIN_VERSION,
                )

    def test_license_archive_rejects_unsafe_component_urls(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for label, fixture in (
                ("source", supply_chain_fixture(root / "source", invalid_source=True)),
                ("artifact", supply_chain_fixture(root / "artifact", invalid_artifact=True)),
            ):
                with self.subTest(field=label):
                    with self.assertRaisesRegex(MODULE.PublicationError, "HTTPS"):
                        MODULE.validate_license_archive(
                            fixture["archive_path"],
                            fixture["provenance"],
                            fixture["manifest"],
                            toolchain_version=TOOLCHAIN_VERSION,
                        )

    def test_spdx_covers_the_exact_signed_component_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = supply_chain_fixture(Path(temporary))
            closure = MODULE.validate_license_archive(
                fixture["archive_path"],
                fixture["provenance"],
                fixture["manifest"],
                toolchain_version=TOOLCHAIN_VERSION,
            )
            spdx = spdx_fixture(fixture)
            spdx_path = Path(temporary) / "release.spdx.json"
            spdx_path.write_bytes(MODULE.canonical_json_bytes(spdx))
            MODULE.validate_spdx(
                spdx_path,
                provenance=fixture["provenance"],
                license_closure=closure,
                licenses_name=f"EasySplat-{VERSION}-licenses.zip",
            )

            spdx["packages"].pop()
            spdx_path.write_bytes(MODULE.canonical_json_bytes(spdx))
            with self.assertRaisesRegex(MODULE.PublicationError, "package closure"):
                MODULE.validate_spdx(
                    spdx_path,
                    provenance=fixture["provenance"],
                    license_closure=closure,
                    licenses_name=f"EasySplat-{VERSION}-licenses.zip",
                )

    def test_spdx_rejects_false_package_and_creation_details(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = supply_chain_fixture(Path(temporary))
            closure = MODULE.validate_license_archive(
                fixture["archive_path"],
                fixture["provenance"],
                fixture["manifest"],
                toolchain_version=TOOLCHAIN_VERSION,
            )
            spdx_path = Path(temporary) / "release.spdx.json"

            def validate(value: dict[str, object]) -> None:
                spdx_path.write_bytes(MODULE.canonical_json_bytes(value))
                MODULE.validate_spdx(
                    spdx_path,
                    provenance=fixture["provenance"],
                    license_closure=closure,
                    licenses_name=f"EasySplat-{VERSION}-licenses.zip",
                )

            mutations = (
                (
                    "creation timestamp",
                    lambda value: value["creationInfo"].__setitem__(
                        "created", "2026-07-15T12:00:01Z"
                    ),
                    "creation information",
                ),
                (
                    "app download",
                    lambda value: value["packages"][0].__setitem__(
                        "downloadLocation", "https://example.invalid/wrong.dmg"
                    ),
                    "package closure",
                ),
                (
                    "artifact checksum",
                    lambda value: value["packages"][2]["checksums"][0].__setitem__(
                        "checksumValue", "0" * 64
                    ),
                    "package closure",
                ),
                (
                    "viewer source",
                    lambda value: value["packages"][1]["externalRefs"][0].__setitem__(
                        "referenceLocator", "pkg:github/example/wrong@deadbeef"
                    ),
                    "package closure",
                ),
                (
                    "component checksum",
                    lambda value: value["packages"][-1]["checksums"][0].__setitem__(
                        "checksumValue", "0" * 64
                    ),
                    "package closure",
                ),
                (
                    "JSON type confusion",
                    lambda value: value["packages"][0].__setitem__(
                        "filesAnalyzed", 0
                    ),
                    "package closure",
                ),
                (
                    "extracted license text",
                    lambda value: value["hasExtractedLicensingInfos"][0].__setitem__(
                        "extractedText", "wrong archive"
                    ),
                    "extracted-license closure",
                ),
            )
            for label, mutate, expected_error in mutations:
                with self.subTest(field=label):
                    spdx = spdx_fixture(fixture)
                    mutate(spdx)
                    with self.assertRaisesRegex(MODULE.PublicationError, expected_error):
                        validate(spdx)

    def test_release_timestamps_are_strict_utc_and_cross_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = supply_chain_fixture(Path(temporary))
            for invalid in (
                "2026-07-15Z",
                "2026-13-15T12:00:00Z",
                "2026-07-15T12:00:00+00:00",
                "2026-07-15T12:00:00Zjunk",
            ):
                with self.subTest(timestamp=invalid), mock.patch.object(
                    MODULE,
                    "vendored_viewer_source_identity",
                    return_value=("f" * 64, 12),
                ):
                    fixture["provenance"]["createdAt"] = invalid
                    with self.assertRaisesRegex(MODULE.PublicationError, "UTC RFC 3339"):
                        MODULE.validate_provenance_shape(
                            fixture["provenance"],
                            app_version=VERSION,
                            toolchain_version=TOOLCHAIN_VERSION,
                            source_repository=REPOSITORY,
                            source_commit=COMMIT,
                        )
            with self.assertRaisesRegex(MODULE.PublicationError, "timestamp.*differ"):
                MODULE.validate_release_timestamps(
                    {"createdAt": "2026-07-15T12:00:00Z"},
                    {"publishedAt": "2026-07-15T12:00:01Z"},
                )

    def test_semver_comparison_honors_prerelease_precedence(self) -> None:
        ordered = (
            "0.2.0-alpha",
            "0.2.0-alpha.1",
            "0.2.0-alpha.beta",
            "0.2.0-beta",
            "0.2.0-beta.1",
            "0.2.0-beta.2",
            "0.2.0-beta.11",
            "0.2.0-rc.1",
            "0.2.0",
        )
        for lower, upper in zip(ordered, ordered[1:]):
            with self.subTest(lower=lower, upper=upper):
                self.assertLess(MODULE.compare_semver(lower, upper), 0)
                self.assertGreater(MODULE.compare_semver(upper, lower), 0)
        self.assertEqual(MODULE.compare_semver("0.2.0+one", "0.2.0+two"), 0)
        for invalid in ("0.2.0-01", "0.2.0-beta..1", "0.2.0-"):
            with self.subTest(invalid=invalid):
                with self.assertRaises(MODULE.PublicationError):
                    MODULE.compare_semver(invalid, "0.2.0")

    def test_required_zip_entries_must_be_nonempty_regular_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, writer in (
                (
                    "directory.zip",
                    lambda archive: archive.writestr("required/", b""),
                ),
                (
                    "empty.zip",
                    lambda archive: archive.writestr("required", b""),
                ),
            ):
                archive_path = root / name
                with zipfile.ZipFile(archive_path, "w") as archive:
                    writer(archive)
                with self.subTest(name=name):
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, "required file.*nonempty regular"
                    ):
                        MODULE.validate_zip(
                            archive_path,
                            label="fixture archive",
                            allowed_prefixes=("required",),
                            required_files={"required"},
                        )

    def test_checksum_must_name_and_hash_the_dmg_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dmg = root / f"EasySplat-{VERSION}-unsigned.dmg"
            checksum = root / f"{dmg.name}.sha256"
            dmg.write_bytes(b"dmg")
            checksum.write_text("0" * 64 + f"  {dmg.name}\n", encoding="ascii")

            with self.assertRaisesRegex(MODULE.PublicationError, "checksum"):
                MODULE.validate_dmg_checksum(dmg, checksum)

    def test_provenance_rejects_unreviewed_top_level_fields(self) -> None:
        payload = {
            "schemaVersion": 2,
            "appVersion": VERSION,
            "toolchainVersion": TOOLCHAIN_VERSION,
            "releaseMode": "unsigned-beta",
            "bundleIdentifier": "com.easysplat.app",
            "createdAt": "2026-07-15T12:00:00Z",
            "source": {
                "buildCommand": "./scripts/release/build_app.sh",
                "commit": COMMIT,
                "url": f"https://github.com/{REPOSITORY}",
            },
            "sourceDependencies": {},
            "supplyChain": {},
            "artifacts": {},
            "unexpected": True,
        }

        with self.assertRaisesRegex(MODULE.PublicationError, "exact keys"):
            MODULE.validate_provenance_shape(
                payload,
                app_version=VERSION,
                toolchain_version=TOOLCHAIN_VERSION,
                source_repository=REPOSITORY,
                source_commit=COMMIT,
            )

    def test_provenance_requires_the_exact_vendored_viewer_identity(self) -> None:
        payload = {
            "schemaVersion": 2,
            "appVersion": VERSION,
            "toolchainVersion": TOOLCHAIN_VERSION,
            "releaseMode": "unsigned-beta",
            "bundleIdentifier": "com.easysplat.app",
            "createdAt": "2026-07-15T12:00:00Z",
            "source": {
                "buildCommand": "./scripts/release/build_app.sh",
                "commit": COMMIT,
                "url": f"https://github.com/{REPOSITORY}",
            },
            "sourceDependencies": {},
            "supplyChain": {},
            "artifacts": {},
        }
        with mock.patch.object(
            MODULE,
            "vendored_viewer_source_identity",
            return_value=("f" * 64, 12),
        ):
            with self.assertRaisesRegex(MODULE.PublicationError, "MetalSplatter"):
                MODULE.validate_provenance_shape(
                    payload,
                    app_version=VERSION,
                    toolchain_version=TOOLCHAIN_VERSION,
                    source_repository=REPOSITORY,
                    source_commit=COMMIT,
                )

            payload["sourceDependencies"] = {
                "MetalSplatter": {
                    "source": MODULE.METALSPLATTER_SOURCE,
                    "basedOnRevision": MODULE.METALSPLATTER_BASE_REVISION,
                    "vendoredTreeSHA256": "f" * 64,
                    "sourceFileCount": 12,
                    "license": "MIT",
                    "buildCommand": "./scripts/release/build_app.sh",
                    "integration": "statically linked with EasySplat compatibility changes",
                }
            }
            MODULE.validate_provenance_shape(
                payload,
                app_version=VERSION,
                toolchain_version=TOOLCHAIN_VERSION,
                source_repository=REPOSITORY,
                source_commit=COMMIT,
            )

    def test_provenance_requires_exact_app_and_manifest_release_urls(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dmg = root / f"EasySplat-{VERSION}-unsigned.dmg"
            manifest = root / "toolchain-manifest.json"
            dmg.write_bytes(b"dmg")
            manifest.write_bytes(b"manifest")

            def artifact(file: str, url: str, data: bytes = b"x") -> dict[str, object]:
                return {
                    "file": file,
                    "downloadURL": url,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "size": len(data),
                }

            source_prefix = f"https://github.com/{REPOSITORY}/releases/download"
            payload = {
                "schemaVersion": 2,
                "appVersion": VERSION,
                "toolchainVersion": TOOLCHAIN_VERSION,
                "releaseMode": "unsigned-beta",
                "bundleIdentifier": "com.easysplat.app",
                "createdAt": "2026-07-15T12:00:00Z",
                "source": {
                    "buildCommand": "./scripts/release/build_app.sh",
                    "commit": COMMIT,
                    "url": f"https://github.com/{REPOSITORY}",
                },
                "sourceDependencies": {
                    "MetalSplatter": {
                        "source": MODULE.METALSPLATTER_SOURCE,
                        "basedOnRevision": MODULE.METALSPLATTER_BASE_REVISION,
                        "vendoredTreeSHA256": "f" * 64,
                        "sourceFileCount": 12,
                        "license": "MIT",
                        "buildCommand": "./scripts/release/build_app.sh",
                        "integration": "statically linked with EasySplat compatibility changes",
                    }
                },
                "supplyChain": {},
                "artifacts": {
                    "dmg": artifact(
                        dmg.name,
                        f"{source_prefix}/v{VERSION}/wrong.dmg",
                        dmg.read_bytes(),
                    ),
                    "manifest": artifact(
                        "manifest.json",
                        f"{source_prefix}/toolchain-v{TOOLCHAIN_VERSION}/manifest.json",
                        manifest.read_bytes(),
                    ),
                    "core": artifact("core.zip", f"{source_prefix}/toolchain-v{TOOLCHAIN_VERSION}/core.zip"),
                    "geometry-da3-base": artifact("base.zip", f"{source_prefix}/toolchain-v{TOOLCHAIN_VERSION}/base.zip"),
                    "geometry-da3-small": artifact("small.zip", f"{source_prefix}/toolchain-v{TOOLCHAIN_VERSION}/small.zip"),
                },
            }
            provenance_path = root / "provenance.json"
            provenance_path.write_bytes(MODULE.canonical_json_bytes(payload))
            with mock.patch.object(
                MODULE,
                "vendored_viewer_source_identity",
                return_value=("f" * 64, 12),
            ):
                with self.assertRaisesRegex(MODULE.PublicationError, "release URL"):
                    MODULE.validate_provenance(
                        provenance_path,
                        app_version=VERSION,
                        toolchain_version=TOOLCHAIN_VERSION,
                        source_repository=REPOSITORY,
                        source_commit=COMMIT,
                        dmg=dmg,
                        manifest=manifest,
                    )

    def test_non_arm64_app_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "EasySplat.app"
            executable = app / "Contents/MacOS/EasySplatApp"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"binary")
            (app / "Contents/Info.plist").write_bytes(b"plist")
            (app / "Contents/Resources").mkdir()
            (app / "Contents/_CodeSignature").mkdir()

            plist_values = dict(MODULE.expected_app_plist(VERSION))
            with (
                mock.patch.object(MODULE, "load_plist", return_value=plist_values),
                mock.patch.object(
                    MODULE,
                    "run_static",
                    return_value=mock.Mock(stdout="x86_64\n", stderr="", returncode=0),
                ),
            ):
                with self.assertRaisesRegex(MODULE.PublicationError, "arm64-only"):
                    MODULE.validate_app_bundle(app, app_version=VERSION)

    def test_info_plist_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "EasySplat.app"
            executable = app / "Contents/MacOS/EasySplatApp"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"binary")
            plist = app / "Contents/Info.plist"
            plist.write_bytes(b"plist")

            values = dict(MODULE.expected_app_plist(VERSION))
            values["CFBundleIdentifier"] = "invalid.bundle"
            with mock.patch.object(MODULE, "load_plist", return_value=values):
                with self.assertRaisesRegex(
                    MODULE.PublicationError, "CFBundleIdentifier"
                ):
                    MODULE.validate_app_plist(plist, app_version=VERSION)

    def test_dsym_uuid_must_match_app_uuid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "symbols.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("EasySplat.app.dSYM/Contents/Info.plist", b"plist")
                archive.writestr(
                    "EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp",
                    b"dwarf",
                )
            app_binary = root / "EasySplatApp"
            app_binary.write_bytes(b"app")
            outputs = iter(
                (
                    "UUID: 11111111-1111-1111-1111-111111111111 (arm64) app\n",
                    "UUID: 22222222-2222-2222-2222-222222222222 (arm64) dsym\n",
                )
            )
            with (
                mock.patch.object(
                    MODULE,
                    "run_static",
                    side_effect=lambda *_args, **_kwargs: mock.Mock(
                        stdout=next(outputs), stderr="", returncode=0
                    ),
                ),
                mock.patch.object(MODULE, "plist_value", return_value="dSYM"),
            ):
                with self.assertRaisesRegex(MODULE.PublicationError, "dSYM UUID"):
                    MODULE.validate_dsym_archive(archive_path, app_binary)


class BenchmarkSuiteTests(unittest.TestCase):
    def _write_suite(self, path: Path, *, raw_retention: str = "excluded") -> None:
        payload = {
            "schema_version": 1,
            "run_id": "12345678-1234-5678-9234-567812345678",
            "started_at_utc": "2026-07-15T12:00:00Z",
            "ended_at_utc": "2026-07-15T12:30:00Z",
            "profile": "release",
            "status": "passed",
            "blocking_reasons": [],
            "failures": [],
            "scene_results": [],
            "aggregates": {},
            "machine": {},
            "app_version": VERSION,
            "toolchain_identity": "sha256:" + "c" * 64,
            "thresholds_digest": "sha256:" + "d" * 64,
            "corpus_digest": "sha256:" + "e" * 64,
            "git": {"commit": COMMIT, "dirty": False},
            "raw_evidence_retention": raw_retention,
            "missing_requirements": {
                "media": [],
                "evidence": [],
                "toolchain": None,
                "request_index": None,
            },
        }
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    def test_release_accepts_only_a_compact_suite_without_raw_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            suite = Path(temporary) / "suite.json"
            self._write_suite(suite)
            validated = MODULE.validate_benchmark_suite(
                suite,
                app_version=VERSION,
                source_commit=COMMIT,
                toolchain_identity="sha256:" + "c" * 64,
            )
            self.assertEqual(validated["raw_evidence_retention"], "excluded")

            self._write_suite(suite, raw_retention="local_only")
            with self.assertRaisesRegex(MODULE.PublicationError, "raw evidence"):
                MODULE.validate_benchmark_suite(
                    suite,
                    app_version=VERSION,
                    source_commit=COMMIT,
                    toolchain_identity="sha256:" + "c" * 64,
                )


class SignatureTests(unittest.TestCase):
    def test_ed25519_rfc8032_empty_message_vector(self) -> None:
        public_key = bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
        )
        signature = bytes.fromhex(
            "e5564300c360ac729086e2cc806e828a"
            "84877f1eb8e5d974d873e06522490155"
            "5fb8821590a33bacc61e39701cf9b46b"
            "d25bf5f0595bbe24655141438e7a100b"
        )

        self.assertTrue(MODULE.verify_ed25519(public_key, b"", signature))
        self.assertFalse(MODULE.verify_ed25519(public_key, b"changed", signature))


class ToolchainAuthorityReceiptTests(unittest.TestCase):
    def test_exact_signed_receipt_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = authority_fixture(Path(temporary))
            with mock.patch.object(MODULE, "verify_ed25519", return_value=True):
                validated = MODULE.validate_toolchain_authority_receipt(
                    fixture["receipt_path"],
                    fixture["manifest_path"],
                    fixture["manifest"],
                    fixture["public_key_path"],
                    source_repository=REPOSITORY,
                    toolchain_version=TOOLCHAIN_VERSION,
                )
            self.assertEqual(validated, fixture["receipt"])

    def test_receipt_rejects_artifact_tampering_and_noncanonical_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = authority_fixture(Path(temporary))
            receipt = fixture["receipt"]
            receipt["sourceArtifacts"][0]["payloadSHA256"] = "7" * 64
            fixture["receipt_path"].write_bytes(MODULE.signature_json_bytes(receipt))
            with mock.patch.object(MODULE, "verify_ed25519", return_value=True):
                with self.assertRaisesRegex(MODULE.PublicationError, "artifact identity"):
                    MODULE.validate_toolchain_authority_receipt(
                        fixture["receipt_path"],
                        fixture["manifest_path"],
                        fixture["manifest"],
                        fixture["public_key_path"],
                        source_repository=REPOSITORY,
                        toolchain_version=TOOLCHAIN_VERSION,
                    )

            fixture = authority_fixture(Path(temporary))
            fixture["receipt_path"].write_bytes(
                fixture["receipt_path"].read_bytes() + b"\n"
            )
            with self.assertRaisesRegex(MODULE.PublicationError, "canonical compact"):
                MODULE.validate_toolchain_authority_receipt(
                    fixture["receipt_path"],
                    fixture["manifest_path"],
                    fixture["manifest"],
                    fixture["public_key_path"],
                    source_repository=REPOSITORY,
                    toolchain_version=TOOLCHAIN_VERSION,
                )

    def test_invalid_receipt_signature_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = authority_fixture(Path(temporary))
            with mock.patch.object(MODULE, "verify_ed25519", return_value=False):
                with self.assertRaisesRegex(MODULE.PublicationError, "signature"):
                    MODULE.validate_toolchain_authority_receipt(
                        fixture["receipt_path"],
                        fixture["manifest_path"],
                        fixture["manifest"],
                        fixture["public_key_path"],
                        source_repository=REPOSITORY,
                        toolchain_version=TOOLCHAIN_VERSION,
                    )

    def test_request_envelope_and_receipt_form_one_canonical_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = authority_fixture(Path(temporary))
            with mock.patch.object(MODULE, "verify_ed25519", return_value=True):
                closure = MODULE.validate_toolchain_authority_closure(
                    fixture["request_path"],
                    fixture["envelope_path"],
                    fixture["receipt_path"],
                    fixture["manifest_path"],
                    fixture["manifest"],
                    fixture["public_key_path"],
                    source_repository=REPOSITORY,
                    toolchain_version=TOOLCHAIN_VERSION,
                )
            self.assertEqual(closure["request"], fixture["request"])
            self.assertEqual(closure["envelope"], fixture["envelope"])
            self.assertEqual(closure["receipt"], fixture["receipt"])

    def test_authority_closure_rejects_tampered_or_noncanonical_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = authority_fixture(root)
            request = fixture["request"]
            request["sourceCommit"] = "c" * 40
            fixture["request_path"].write_bytes(MODULE.signature_json_bytes(request))
            with mock.patch.object(MODULE, "verify_ed25519", return_value=True):
                with self.assertRaisesRegex(MODULE.PublicationError, "request|envelope"):
                    MODULE.validate_toolchain_authority_closure(
                        fixture["request_path"],
                        fixture["envelope_path"],
                        fixture["receipt_path"],
                        fixture["manifest_path"],
                        fixture["manifest"],
                        fixture["public_key_path"],
                        source_repository=REPOSITORY,
                        toolchain_version=TOOLCHAIN_VERSION,
                    )

            fixture = authority_fixture(root)
            fixture["envelope_path"].write_bytes(
                fixture["envelope_path"].read_bytes() + b"\n"
            )
            with self.assertRaisesRegex(MODULE.PublicationError, "canonical compact"):
                MODULE.validate_toolchain_authority_closure(
                    fixture["request_path"],
                    fixture["envelope_path"],
                    fixture["receipt_path"],
                    fixture["manifest_path"],
                    fixture["manifest"],
                    fixture["public_key_path"],
                    source_repository=REPOSITORY,
                    toolchain_version=TOOLCHAIN_VERSION,
                )


class RemoteToolchainReleaseTests(unittest.TestCase):
    def _manifest(self) -> dict[str, object]:
        components = []
        filenames = {
            "macos-arm64-core": f"toolchain-macos-arm64-{TOOLCHAIN_VERSION}-core.zip",
            "geometry-da3-base": f"toolchain-geometry-da3-base-{TOOLCHAIN_VERSION}.zip",
            "geometry-da3-small": f"toolchain-geometry-da3-small-{TOOLCHAIN_VERSION}.zip",
        }
        for index, (name, filename) in enumerate(filenames.items(), start=1):
            components.append(
                {
                    "name": name,
                    "url": (
                        f"https://github.com/{REPOSITORY}/releases/download/"
                        f"toolchain-v{TOOLCHAIN_VERSION}/{filename}"
                    ),
                    "sizeBytes": index,
                    "sha256": str(index) * 64,
                }
            )
        return {"components": components}

    def _release(
        self,
        manifest_path: Path,
        request_path: Path,
        envelope_path: Path,
        receipt_path: Path,
        manifest: dict[str, object],
    ) -> dict[str, object]:
        assets = []
        for name, path in (
            ("manifest.json", manifest_path),
            ("toolchain-release-request.json", request_path),
            ("authority-envelope.json", envelope_path),
            ("authority-receipt.json", receipt_path),
        ):
            assets.append(
                {
                    "name": name,
                    "size": path.stat().st_size,
                    "digest": f"sha256:{MODULE.sha256_file(path)}",
                    "browser_download_url": (
                        f"https://github.com/{REPOSITORY}/releases/download/"
                        f"toolchain-v{TOOLCHAIN_VERSION}/{name}"
                    ),
                }
            )
        for component in manifest["components"]:
            assert isinstance(component, dict)
            assets.append(
                {
                    "name": Path(component["url"]).name,
                    "size": component["sizeBytes"],
                    "digest": f"sha256:{component['sha256']}",
                    "browser_download_url": component["url"],
                }
            )
        return {
            "tag_name": f"toolchain-v{TOOLCHAIN_VERSION}",
            "draft": False,
            "immutable": True,
            "assets": assets,
        }

    def test_immutable_release_with_exact_assets_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            closure = authority_fixture(root)
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}\n", encoding="utf-8")
            manifest = self._manifest()
            release = self._release(
                manifest_path,
                closure["request_path"],
                closure["envelope_path"],
                closure["receipt_path"],
                manifest,
            )

            with mock.patch.object(MODULE, "api_json", return_value=release) as api:
                MODULE.validate_remote_toolchain_assets(
                    manifest_path,
                    closure["request_path"],
                    closure["envelope_path"],
                    closure["receipt_path"],
                    manifest,
                    source_repository=REPOSITORY,
                    toolchain_version=TOOLCHAIN_VERSION,
                    github_token="read-only-token",
                )
            self.assertEqual(api.call_count, 1)

    def test_mutable_release_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            closure = authority_fixture(root)
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}\n", encoding="utf-8")
            manifest = self._manifest()
            release = self._release(
                manifest_path,
                closure["request_path"],
                closure["envelope_path"],
                closure["receipt_path"],
                manifest,
            )
            release["immutable"] = False

            with mock.patch.object(MODULE, "api_json", return_value=release):
                with self.assertRaisesRegex(
                    MODULE.PublicationError, "release identity"
                ):
                    MODULE.validate_remote_toolchain_assets(
                        manifest_path,
                        closure["request_path"],
                        closure["envelope_path"],
                        closure["receipt_path"],
                        manifest,
                        source_repository=REPOSITORY,
                        toolchain_version=TOOLCHAIN_VERSION,
                        github_token="read-only-token",
                    )


if __name__ == "__main__":
    unittest.main()
