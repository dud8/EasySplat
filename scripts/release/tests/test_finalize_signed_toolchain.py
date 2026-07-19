from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from typing import Any, Callable
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "finalize_signed_toolchain.py"
SPEC = importlib.util.spec_from_file_location("finalize_signed_toolchain", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
GENERATOR_SCRIPT = SCRIPT.parents[1] / "toolchain/generate_supply_chain_manifest.py"
GENERATOR_SPEC = importlib.util.spec_from_file_location(
    "generate_supply_chain_manifest_for_finalizer_test", GENERATOR_SCRIPT
)
assert GENERATOR_SPEC is not None and GENERATOR_SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
GENERATOR_SPEC.loader.exec_module(GENERATOR)

MACHO = b"\xcf\xfa\xed\xfe" + b"unsigned-macho"
FINGERPRINT = "A" * 40
TEAM_ID = "TEAMID1234"
VERSION = "2.0.0"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def record_hash(data: bytes) -> str:
    encoded = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode("ascii")
    return f"sha256={encoded.rstrip('=')}"


def canonical_json(payload: object) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()


def compact_json(payload: object) -> bytes:
    return json.dumps(
        payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode()


def zip_bytes(files: dict[str, tuple[bytes, int]]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(files):
            data, mode = files[name]
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, data)
    return output.getvalue()


class Fixture:
    def __init__(self, root: Path) -> None:
        root.mkdir(parents=True, exist_ok=True)
        self.root = root.resolve()
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        site = "da3_mps/python/lib/python3.13/site-packages"
        extension = f"{site}/sample/native.so"
        dist = f"{site}/sample-1.0.dist-info"
        metadata = b"Metadata-Version: 2.4\nName: sample\nVersion: 1.0\n\n"
        package_init = b"__all__ = []\n"
        record = (
            f"sample/native.so,{record_hash(MACHO)},{len(MACHO)}\n"
            f"sample/__init__.py,{record_hash(package_init)},{len(package_init)}\n"
            "sample/__pycache__/__init__.cpython-313.pyc,,\n"
            f"sample-1.0.dist-info/METADATA,{record_hash(metadata)},{len(metadata)}\n"
            "sample-1.0.dist-info/RECORD,,\n"
        ).encode()

        colmap_receipt = {
            "schema_version": 2,
            "toolchain_name": "colmap",
            "executable_sha256": digest(MACHO),
        }
        support_receipt = {
            "schema_version": 1,
            "toolchain_name": "colmap-support",
            "library_sha256": {"lib/libomp.dylib": digest(MACHO)},
        }
        msplat_receipt = {
            "schema_version": 1,
            "toolchain_name": "msplat",
            "executable_sha256": digest(MACHO),
        }
        self.core: dict[str, tuple[bytes, int]] = {
            "bin/colmap": (MACHO, 0o755),
            "bin/easysplat-train": (MACHO, 0o755),
            "bin/default.metallib": (b"metal", 0o644),
            "lib/libomp.dylib": (MACHO, 0o755),
            "licenses/EasySplat/LICENSE": (b"MIT\n", 0o644),
            "msplat/LICENSE": (b"Apache-2.0\n", 0o644),
            "msplat/build_info.json": (canonical_json(msplat_receipt), 0o644),
            "provenance/colmap.json": (canonical_json(colmap_receipt), 0o644),
            "provenance/colmap-support.json": (
                canonical_json(support_receipt),
                0o644,
            ),
        }
        self.base: dict[str, tuple[bytes, int]] = {
            "da3_mps/bin/easysplat_da3_sfm": (b"#!/bin/sh\n", 0o755),
            "da3_mps/app/easysplat_da3_sfm/run.py": (b"pass\n", 0o644),
            "da3_mps/vendor/depth-anything-3/LICENSE": (b"Apache-2.0\n", 0o644),
            "da3_mps/licenses/runtime.json": (b"{}\n", 0o644),
            "da3_mps/build_info.json": (b"{}\n", 0o644),
            "da3_mps/python/bin/python3": (MACHO, 0o755),
            f"{site}/README.txt": (b"Python site-packages runtime directory.\n", 0o644),
            extension: (MACHO, 0o755),
            f"{site}/sample/__init__.py": (package_init, 0o644),
            f"{dist}/METADATA": (metadata, 0o644),
            f"{dist}/RECORD": (record, 0o644),
            "da3_mps/models/DA3-BASE/config.json": (b"{}\n", 0o644),
            "da3_mps/models/DA3-BASE/model.safetensors": (b"base", 0o644),
        }
        self.small: dict[str, tuple[bytes, int]] = {
            "da3_mps/models/DA3-SMALL/config.json": (b"{}\n", 0o644),
            "da3_mps/models/DA3-SMALL/model.safetensors": (b"small", 0o644),
        }
        self.refresh_manifest()
        self.core_zip = self.inputs / f"toolchain-macos-arm64-{VERSION}-core.zip"
        self.base_zip = self.inputs / f"toolchain-geometry-da3-base-{VERSION}.zip"
        self.small_zip = self.inputs / f"toolchain-geometry-da3-small-{VERSION}.zip"
        self.release_request = self.inputs / "toolchain-release-request.json"
        self.write_archives()
        self.write_release_request()

    def refresh_manifest(self) -> None:
        all_files = {**self.core, **self.base, **self.small}
        rows = []
        for path, (data, _) in sorted(all_files.items()):
            if path == "supply-chain/components.json":
                continue
            rows.append(
                {
                    "component": self.owner(path),
                    "kind": "mach-o" if data[:4] in MODULE.MACHO_MAGICS else "file",
                    "path": path,
                    "sha256": digest(data),
                    "size": len(data),
                }
            )
        component_ids = sorted({row["component"] for row in rows})
        components = [
            {
                "id": component_id,
                "name": component_id,
                "type": "fixture",
                "version": "1",
                "revision": "fixture",
                "source": "https://example.com/source",
                "buildCommand": "./fixture",
                "license": "MIT",
                "licenseFiles": ["licenses/EasySplat/LICENSE"],
                "linkage": "fixture",
                "dependencies": [],
                "files": [
                    row["path"] for row in rows if row["component"] == component_id
                ],
            }
            for component_id in component_ids
        ]
        for component in components:
            if component["id"] == "easysplat-da3-runner":
                component.update(
                    {
                        "name": "EasySplat DA3 runner",
                        "type": "script",
                        "version": VERSION,
                        "revision": MODULE.source_bindings()["sourceCommit"],
                        "source": "https://github.com/dud8/EasySplat",
                    }
                )
        self.core["supply-chain/components.json"] = (
            canonical_json(
                {
                    "schemaVersion": 1,
                    "toolchainVersion": VERSION,
                    "components": components,
                    "files": rows,
                }
            ),
            0o644,
        )

    @staticmethod
    def owner(path: str) -> str:
        if path in {
            "da3_mps/bin/easysplat_da3_sfm",
            "da3_mps/app/easysplat_da3_sfm/run.py",
            "da3_mps/build_info.json",
            "licenses/EasySplat/LICENSE",
        }:
            return "easysplat-da3-runner"
        if path.startswith("licenses/shape-"):
            return path.split("/", 2)[1]
        if path.endswith("/site-packages/README.txt"):
            return "python-build-standalone"
        if path == "bin/colmap":
            return "colmap"
        if path == "bin/easysplat-train" or path.startswith("msplat/"):
            return "msplat"
        if path == "lib/libomp.dylib":
            return "colmap-support:libomp"
        if "site-packages/sample" in path:
            return "python:sample"
        return "fixture"

    def write_archives(self) -> None:
        self.core_zip.write_bytes(zip_bytes(self.core))
        self.base_zip.write_bytes(zip_bytes(self.base))
        self.small_zip.write_bytes(zip_bytes(self.small))

    def write_release_request(self) -> None:
        archives = (
            ("macos-arm64-core", self.core_zip, self.core),
            ("geometry-da3-base", self.base_zip, self.base),
            ("geometry-da3-small", self.small_zip, self.small),
        )
        components = []
        for name, path, files in archives:
            closure = hashlib.sha256()
            closure.update(b"EasySplat expanded component closure v1\n")
            file_hashes = {}
            for relative in sorted(files):
                data, mode = files[relative]
                file_hash = digest(data)
                file_hashes[relative] = file_hash
                closure.update(relative.encode())
                closure.update(b"\0")
                closure.update(str(mode).encode())
                closure.update(b"\0")
                closure.update(str(len(data)).encode())
                closure.update(b"\0")
                closure.update(file_hash.encode())
                closure.update(b"\n")
            capabilities = {
                "macos-arm64-core": [
                    "runtime.core",
                    "geometry.colmap",
                    "training.msplat",
                ],
                "geometry-da3-base": ["geometry.da3.runtime", "geometry.da3.base"],
                "geometry-da3-small": ["geometry.da3.small"],
            }[name]
            components.append(
                {
                    "name": name,
                    "capabilities": capabilities,
                    "url": (
                        "https://github.com/dud8/EasySplat/releases/download/"
                        f"toolchain-v{VERSION}/{path.name}"
                    ),
                    "sha256": digest(path.read_bytes()),
                    "sizeBytes": path.stat().st_size,
                    "expandedSizeBytes": sum(
                        len(data) for data, _mode in files.values()
                    ),
                    "expandedClosureSHA256": closure.hexdigest(),
                    "contents": sorted(files),
                    "criticalFileHashes": file_hashes,
                    "dependencies": {
                        "macos-arm64-core": [],
                        "geometry-da3-base": ["macos-arm64-core"],
                        "geometry-da3-small": ["geometry-da3-base"],
                    }[name],
                    "requirement": (
                        "required" if name == "macos-arm64-core" else "optional"
                    ),
                }
            )
        manifest = {
            "schemaVersion": 2,
            "toolchainAPI": 2,
            "keyID": "a" * 64,
            "version": VERSION,
            "publishedAt": "2026-07-18T00:00:00Z",
            "appVersionRange": {
                "minimum": "0.2.0",
                "maximumExclusive": "0.3.0",
            },
            "components": components,
            "signatureEd25519": "",
        }
        request = {
            "schemaVersion": 2,
            "sourceRepository": "dud8/EasySplat",
            "sourceCommit": MODULE.source_bindings()["sourceCommit"],
            "manifestSHA256": digest(compact_json(manifest)),
            "manifest": manifest,
        }
        self.release_request.write_bytes(compact_json(request))

    def output(self, name: str = "signed") -> tuple[Path, Path]:
        output = self.root / name
        return output, output / "distribution-signing-finalization.json"


def fake_signer(
    root: Path,
    fingerprint: str,
    team_id: str,
    receipt: Path,
) -> None:
    pre_sign_manifest = MODULE.signer_tree_manifest_digest(root)
    entries = []
    file_count = sum(path.is_file() for path in root.rglob("*"))
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.read_bytes()[:4] not in MODULE.MACHO_MAGICS:
            continue
        relative = path.relative_to(root).as_posix()
        before = digest(path.read_bytes())
        path.write_bytes(path.read_bytes() + b"|developer-id-signature")
        after = digest(path.read_bytes())
        entries.append(
            {
                "kind": "machO",
                "relativePath": relative,
                "mode": "0755",
                "preSignSHA256": before,
                "postSignSHA256": after,
                "identityFingerprintSHA1": fingerprint,
                "teamID": team_id,
                "entitlementsSHA256": None,
                "entitlementsSourceSHA256": None,
                "embeddedEntitlementsSHA256": None,
                "signedAt": "2026-07-18T00:00:00Z",
                "codesign": {
                    "identifier": "com.easysplat.fixture",
                    "format": "Mach-O thin (arm64)",
                    "codeDirectory": "v=20500 size=1 flags=0x10000(runtime)",
                    "teamIdentifier": team_id,
                    "hardenedRuntime": True,
                    "runtimeVersion": "15.0.0",
                    "timestamp": "Jul 18, 2026",
                    "leafCertificateSHA1": fingerprint,
                    "authorities": [
                        f"Developer ID Application: Fixture ({team_id})",
                        "Developer ID Certification Authority",
                        "Apple Root CA",
                    ],
                },
            }
        )
    post_sign_manifest = MODULE.signer_tree_manifest_digest(root)
    receipt.write_bytes(
        canonical_json(
            {
                "schemaVersion": 1,
                "rootKind": "tree",
                "identityFingerprintSHA1": fingerprint,
                "teamID": team_id,
                "signedAt": "2026-07-18T00:00:00Z",
                "tree": {
                    "preSignManifestSHA256": pre_sign_manifest,
                    "postSignManifestSHA256": post_sign_manifest,
                    "preSignFileCount": file_count,
                    "postSignFileCount": file_count,
                },
                "entries": entries,
            }
        )
    )


def fake_supply_chain(root: Path, version: str, receipt: Path) -> None:
    manifest_path = root / "supply-chain/components.json"
    payload = json.loads(manifest_path.read_text())
    signing_component = {
        "id": "easysplat-distribution-signing",
        "name": "EasySplat distribution signing",
        "type": "distribution-signing",
        "version": version,
        "revision": digest(receipt.read_bytes()),
        "source": "https://github.com/dud8/EasySplat",
        "buildCommand": "./scripts/release/finalize_signed_toolchain.py",
        "license": "MIT",
        "licenseFiles": ["licenses/EasySplat/LICENSE"],
        "linkage": "distribution-process",
        "dependencies": [],
        "files": ["provenance/distribution-signing.json"],
    }
    payload["components"] = [
        row
        for row in payload["components"]
        if row["id"] != "easysplat-distribution-signing"
    ] + [signing_component]
    rows = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path == manifest_path:
            continue
        relative = path.relative_to(root).as_posix()
        old = next((row for row in payload["files"] if row["path"] == relative), None)
        owner = (
            "easysplat-distribution-signing"
            if relative == "provenance/distribution-signing.json"
            else old["component"]
        )
        data = path.read_bytes()
        rows.append(
            {
                "component": owner,
                "kind": "mach-o" if data[:4] in MODULE.MACHO_MAGICS else "file",
                "path": relative,
                "sha256": digest(data),
                "size": len(data),
            }
        )
    payload["components"].sort(key=lambda row: row["id"])
    payload["files"] = rows
    manifest_path.write_bytes(canonical_json(payload))


def fake_archive(root: Path, output: Path, paths: tuple[str, ...]) -> None:
    MODULE.production_archive(root, output, paths)


class FinalizerTests(unittest.TestCase):
    def test_github_authority_binds_one_exact_producer_artifact(self) -> None:
        commit = "a" * 40
        evidence = MODULE.GitHubArtifactEvidence(
            repository="dud8/EasySplat",
            workflow_run_id=123,
            source_commit=commit,
            artifact_id=456,
            artifact_digest=f"sha256:{'1' * 64}",
            artifact_name=f"toolchain-developer-id-producer-{VERSION}",
        )

        def response(path: str) -> dict[str, Any]:
            if path.endswith(f"/actions/runs/{evidence.workflow_run_id}"):
                return {
                    "id": evidence.workflow_run_id,
                    "event": "workflow_dispatch",
                    "path": ".github/workflows/toolchain-build.yml@main",
                    "head_branch": "main",
                    "head_sha": commit,
                    "repository": {"full_name": evidence.repository},
                }
            if path.endswith("/branches/main"):
                return {
                    "name": "main",
                    "protected": True,
                    "commit": {"sha": commit},
                }
            return {
                "id": evidence.artifact_id,
                "name": evidence.artifact_name,
                "digest": evidence.artifact_digest,
                "expired": False,
                "workflow_run": {
                    "id": evidence.workflow_run_id,
                    "head_branch": "main",
                    "head_sha": commit,
                },
            }

        MODULE.validate_single_github_artifact_authority(
            evidence, fetch_json=response
        )
        with self.assertRaisesRegex(
            MODULE.FinalizationError, "GitHub artifact authority"
        ):
            MODULE.validate_single_github_artifact_authority(
                evidence._replace(artifact_digest=f"sha256:{'2' * 64}"),
                fetch_json=response,
            )

    def test_verify_github_artifact_cli_uses_hardened_authority(self) -> None:
        with mock.patch.object(
            MODULE, "production_single_github_artifact_authority"
        ) as verify:
            result = MODULE.main(
                [
                    "verify-github-artifact",
                    "--repository",
                    "dud8/EasySplat",
                    "--workflow-run-id",
                    "123",
                    "--source-commit",
                    "a" * 40,
                    "--artifact-id",
                    "456",
                    "--artifact-digest",
                    f"sha256:{'1' * 64}",
                    "--artifact-name",
                    f"toolchain-developer-id-producer-{VERSION}",
                ]
            )

        self.assertEqual(result, 0)
        verify.assert_called_once_with(
            MODULE.GitHubArtifactEvidence(
                repository="dud8/EasySplat",
                workflow_run_id=123,
                source_commit="a" * 40,
                artifact_id=456,
                artifact_digest=f"sha256:{'1' * 64}",
                artifact_name=f"toolchain-developer-id-producer-{VERSION}",
            )
        )

    def test_github_authority_binds_both_artifacts_run_and_current_main(self) -> None:
        commit = "a" * 40
        evidence = MODULE.BuilderArtifactEvidence(
            repository="dud8/EasySplat",
            workflow_run_id=123,
            source_commit=commit,
            unsigned_artifact_id=456,
            unsigned_artifact_digest=f"sha256:{'1' * 64}",
            request_artifact_id=789,
            request_artifact_digest=f"sha256:{'2' * 64}",
            request_sha256="3" * 64,
        )

        def response(path: str) -> dict[str, Any]:
            if path.endswith(f"/actions/runs/{evidence.workflow_run_id}"):
                return {
                    "id": evidence.workflow_run_id,
                    "event": "workflow_dispatch",
                    "path": ".github/workflows/toolchain-build.yml@main",
                    "head_branch": "main",
                    "head_sha": commit,
                    "repository": {"full_name": evidence.repository},
                }
            if path.endswith("/branches/main"):
                return {
                    "name": "main",
                    "protected": True,
                    "commit": {"sha": commit},
                }
            artifact_id = int(path.rsplit("/", 1)[1])
            is_unsigned = artifact_id == evidence.unsigned_artifact_id
            return {
                "id": artifact_id,
                "name": (
                    f"toolchain-unsigned-components-{VERSION}"
                    if is_unsigned
                    else f"toolchain-unsigned-request-{VERSION}"
                ),
                "digest": (
                    evidence.unsigned_artifact_digest
                    if is_unsigned
                    else evidence.request_artifact_digest
                ),
                "expired": False,
                "workflow_run": {
                    "id": evidence.workflow_run_id,
                    "head_branch": "main",
                    "head_sha": commit,
                },
            }

        MODULE.validate_github_artifact_authority(
            evidence, VERSION, fetch_json=response
        )

        def documented_workflow_path(path: str) -> dict[str, Any]:
            payload = response(path)
            if path.endswith(f"/actions/runs/{evidence.workflow_run_id}"):
                payload = dict(payload)
                payload["path"] = ".github/workflows/toolchain-build.yml"
            return payload

        MODULE.validate_github_artifact_authority(
            evidence, VERSION, fetch_json=documented_workflow_path
        )

        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / "github-authority.json"
            paths = MODULE.github_authority_paths(evidence)
            receipt.write_bytes(
                compact_json(
                    {
                        "schemaVersion": 1,
                        "responses": {path: response(path) for path in paths},
                    }
                )
            )
            MODULE.validate_github_artifact_authority_receipt(
                receipt, evidence, VERSION
            )
            payload = json.loads(receipt.read_bytes())
            payload["responses"]["repos/dud8/EasySplat/unexpected"] = {}
            receipt.write_bytes(compact_json(payload))
            with self.assertRaisesRegex(
                MODULE.FinalizationError, "authority receipt response set"
            ):
                MODULE.validate_github_artifact_authority_receipt(
                    receipt, evidence, VERSION
                )
        wrong_head = evidence._replace(source_commit="b" * 40)
        with self.assertRaisesRegex(
            MODULE.FinalizationError, "GitHub artifact authority"
        ):
            MODULE.validate_github_artifact_authority(
                wrong_head, VERSION, fetch_json=response
            )

        def wrong_workflow(path: str) -> dict[str, Any]:
            payload = response(path)
            if path.endswith(f"/actions/runs/{evidence.workflow_run_id}"):
                payload = dict(payload)
                payload["path"] = ".github/workflows/untrusted.yml@main"
            return payload

        with self.assertRaisesRegex(
            MODULE.FinalizationError, "workflow run"
        ):
            MODULE.validate_github_artifact_authority(
                evidence, VERSION, fetch_json=wrong_workflow
            )

        for wrong_ref in ("release", "refs/heads/main", "main/extra"):
            with self.subTest(wrong_ref=wrong_ref):
                def wrong_workflow_ref(path: str) -> dict[str, Any]:
                    payload = response(path)
                    if path.endswith(f"/actions/runs/{evidence.workflow_run_id}"):
                        payload = dict(payload)
                        payload["path"] = (
                            f".github/workflows/toolchain-build.yml@{wrong_ref}"
                        )
                    return payload

                with self.assertRaisesRegex(
                    MODULE.FinalizationError, "workflow run"
                ):
                    MODULE.validate_github_artifact_authority(
                        evidence, VERSION, fetch_json=wrong_workflow_ref
                    )

        def unprotected_main(path: str) -> dict[str, Any]:
            payload = response(path)
            if path.endswith("/branches/main"):
                payload = dict(payload)
                payload["protected"] = False
            return payload

        with self.assertRaisesRegex(
            MODULE.FinalizationError, "protected main"
        ):
            MODULE.validate_github_artifact_authority(
                evidence, VERSION, fetch_json=unprotected_main
            )

    def test_github_authority_transport_ignores_proxy_and_custom_ca_environment(
        self,
    ) -> None:
        fake_context = mock.Mock()
        sentinel = object()
        with (
            mock.patch.dict(
                os.environ,
                {
                    "HTTPS_PROXY": "https://attacker.invalid:4443",
                    "https_proxy": "https://attacker.invalid:4443",
                    "HTTP_PROXY": "http://attacker.invalid:8080",
                    "ALL_PROXY": "socks5://attacker.invalid:1080",
                    "NO_PROXY": "",
                    "GH_HOST": "attacker.invalid",
                    "GITHUB_API_URL": "https://attacker.invalid/api",
                    "CURL_CA_BUNDLE": "/tmp/attacker-curl-ca.pem",
                    "REQUESTS_CA_BUNDLE": "/tmp/attacker-requests-ca.pem",
                    "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
                    "SSL_CERT_DIR": "/tmp/attacker-ca-directory",
                },
            ),
            mock.patch.object(
                MODULE.ssl, "SSLContext", return_value=fake_context
            ) as context_type,
            mock.patch.object(
                MODULE.urllib.request, "build_opener", return_value=sentinel
            ) as build_opener,
        ):
            self.assertIs(MODULE.build_github_api_opener(), sentinel)

        context_type.assert_called_once_with(MODULE.ssl.PROTOCOL_TLS_CLIENT)
        fake_context.load_verify_locations.assert_called_once_with(
            cafile="/private/etc/ssl/cert.pem"
        )
        self.assertTrue(fake_context.check_hostname)
        self.assertEqual(fake_context.verify_mode, MODULE.ssl.CERT_REQUIRED)
        handlers = build_opener.call_args.args
        proxy = next(
            handler
            for handler in handlers
            if isinstance(handler, MODULE.urllib.request.ProxyHandler)
        )
        self.assertEqual(proxy.proxies, {})

    def test_noncanonical_receipts_reject_duplicate_and_nonfinite_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, data in (
                ("duplicate.json", b'{"schemaVersion":1,"schemaVersion":2}'),
                ("nonfinite.json", b'{"value":NaN}'),
            ):
                with self.subTest(name=name):
                    path = root / name
                    path.write_bytes(data)
                    with self.assertRaisesRegex(
                        MODULE.FinalizationError, "not valid JSON"
                    ):
                        MODULE.load_json(path, maximum=1024, label="test receipt")

    def test_finalizer_and_generator_bind_the_same_tracked_sources(self) -> None:
        self.assertEqual(
            set(MODULE.SOURCE_BINDING_PATHS),
            GENERATOR.DISTRIBUTION_SIGNING_SOURCE_INPUTS,
        )

    def test_production_unsigned_validator_dispatch_uses_supported_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_root = root / "source"
            source_root.mkdir()
            with (
                mock.patch.object(MODULE, "validate_colmap_tracked_inputs") as colmap,
                mock.patch.object(MODULE, "run_checked_with_source_guard") as run,
            ):
                MODULE.run_unsigned_validator(
                    MODULE.production_unsigned_validator,
                    root,
                    tracked_inputs=None,
                    source_root=source_root,
                )

            colmap.assert_called_once_with(root, source_root=source_root)
            self.assertEqual(run.call_count, 2)
            native_command = run.call_args_list[0].args[0]
            self.assertIn("--packaged-static", native_command)
            self.assertNotIn("--packaged", native_command)

    def test_production_supply_chain_dispatch_binds_reviewed_source_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_root = root / "source"
            source_root.mkdir()
            receipt = root / "distribution-signing.json"
            commit = "a" * 40
            with mock.patch.object(
                MODULE, "run_checked_with_source_guard"
            ) as run:
                MODULE.run_supply_chain_generator(
                    MODULE.production_supply_chain,
                    root,
                    VERSION,
                    receipt,
                    tracked_inputs=None,
                    source_root=source_root,
                    source_commit=commit,
                )

            command = run.call_args.args[0]
            self.assertEqual(
                command[-4:],
                [
                    "--reviewed-source-root",
                    str(source_root),
                    "--reviewed-source-commit",
                    commit,
                ],
            )

    def run_fixture(
        self,
        fixture: Fixture,
        *,
        signer: Callable[[Path, str, str, Path], None] = fake_signer,
        archive: Callable[[Path, Path, tuple[str, ...]], None] = fake_archive,
        output_name: str = "signed",
        refresh_release_request: bool = True,
    ) -> dict[str, Any]:
        if refresh_release_request:
            fixture.write_release_request()
        output, receipt = fixture.output(output_name)
        request_sha256 = digest(fixture.release_request.read_bytes())
        source_commit = MODULE.source_bindings()["sourceCommit"]
        evidence = MODULE.BuilderArtifactEvidence(
            repository="dud8/EasySplat",
            workflow_run_id=100,
            source_commit=source_commit,
            unsigned_artifact_id=101,
            unsigned_artifact_digest=f"sha256:{'1' * 64}",
            request_artifact_id=102,
            request_artifact_digest=f"sha256:{'2' * 64}",
            request_sha256=request_sha256,
        )
        return MODULE.finalize_signed_toolchain(
            version=VERSION,
            core_zip=fixture.core_zip,
            base_zip=fixture.base_zip,
            small_zip=fixture.small_zip,
            unsigned_release_request=fixture.release_request,
            builder_attested_unsigned_request_sha256=request_sha256,
            builder_artifact_evidence=evidence,
            output_directory=output,
            identity_fingerprint=FINGERPRINT,
            team_id=TEAM_ID,
            receipt_path=receipt,
            signer_runner=signer,
            supply_chain_runner=fake_supply_chain,
            archive_runner=archive,
            unsigned_validator=lambda _root: None,
            artifact_authority_verifier=lambda _evidence, _version: None,
        )

    def test_happy_path_bridges_native_and_python_machos(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            result = self.run_fixture(fixture)
            output, receipt_path = fixture.output()
            self.assertEqual(result, json.loads(receipt_path.read_text()))
            self.assertEqual(result["schemaVersion"], 1)
            self.assertEqual(result["kind"], "easysplat-signed-toolchain-finalization")
            self.assertEqual(len(result["finalArchives"]), 3)
            self.assertNotIn("developerIDSignerReceipt", result)
            internal = result["distributionSigningReceipt"]
            self.assertEqual(internal["path"], "provenance/distribution-signing.json")

            core_name = f"toolchain-macos-arm64-{VERSION}-core.zip"
            base_name = f"toolchain-geometry-da3-base-{VERSION}.zip"
            with zipfile.ZipFile(output / core_name) as archive:
                internal_payload = json.loads(
                    archive.read("provenance/distribution-signing.json")
                )
                supply = json.loads(archive.read("supply-chain/components.json"))
            with zipfile.ZipFile(output / base_name) as archive:
                repaired = archive.read(
                    "da3_mps/python/lib/python3.13/site-packages/"
                    "sample-1.0.dist-info/RECORD"
                ).decode()
            self.assertEqual(internal_payload["schemaVersion"], 1)
            self.assertEqual(
                internal_payload["builderAttestedUnsignedRequestSHA256"],
                digest(fixture.release_request.read_bytes()),
            )
            request = json.loads(fixture.release_request.read_text())
            self.assertEqual(
                internal_payload["builderAttestedUnsignedManifestSHA256"],
                request["manifestSHA256"],
            )
            requested_by_name = {
                row["name"]: row for row in request["manifest"]["components"]
            }
            for row in internal_payload["unsignedComponentArchives"]:
                requested = requested_by_name[
                    {
                        "core": "macos-arm64-core",
                        "base": "geometry-da3-base",
                        "small": "geometry-da3-small",
                    }[row["component"]]
                ]
                self.assertEqual(row["name"], Path(requested["url"]).name)
                self.assertEqual(row["sha256"], requested["sha256"])
                self.assertEqual(row["size"], requested["sizeBytes"])
            by_path = {row["path"]: row for row in internal_payload["machOFiles"]}
            for native in ("bin/colmap", "bin/easysplat-train", "lib/libomp.dylib"):
                kinds = {row["kind"] for row in by_path[native]["preSignProvenance"]}
                self.assertEqual(kinds, {"build-receipt", "supply-chain"})
            self.assertIn(
                "record",
                by_path["da3_mps/python/lib/python3.13/site-packages/sample/native.so"][
                    "preSignProvenance"
                ][-1]["kind"],
            )
            self.assertIn("sample/native.so,sha256=", repaired)
            signing_components = [
                row
                for row in supply["components"]
                if row["id"] == "easysplat-distribution-signing"
            ]
            self.assertEqual(len(signing_components), 1)
            self.assertEqual(
                signing_components[0]["files"],
                ["provenance/distribution-signing.json"],
            )

    def test_final_archive_payload_must_match_the_signed_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def tamper_archive(
                root: Path, output: Path, paths: tuple[str, ...]
            ) -> None:
                fake_archive(root, output, paths)
                with zipfile.ZipFile(output, "r") as source:
                    entries = [
                        (info, source.read(info.filename))
                        for info in source.infolist()
                    ]
                with zipfile.ZipFile(
                    output, "w", zipfile.ZIP_DEFLATED, compresslevel=9
                ) as destination:
                    for info, data in entries:
                        if info.filename == "bin/default.metallib":
                            data = b"substituted-metallib"
                        destination.writestr(info, data)

            with self.assertRaisesRegex(
                MODULE.FinalizationError, "archive payload|signed tree"
            ):
                self.run_fixture(fixture, archive=tamper_archive)
            self.assertFalse(fixture.output()[0].exists())

    def test_inputs_are_immutable_and_outputs_are_reproducible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            before = {path: path.read_bytes() for path in fixture.inputs.iterdir()}
            first = self.run_fixture(fixture, output_name="signed-one")
            second = self.run_fixture(fixture, output_name="signed-two")
            self.assertEqual(
                before, {path: path.read_bytes() for path in fixture.inputs.iterdir()}
            )
            self.assertEqual(first, second)
            one, _ = fixture.output("signed-one")
            two, _ = fixture.output("signed-two")
            for row in first["finalArchives"]:
                self.assertEqual(
                    (one / row["name"]).read_bytes(), (two / row["name"]).read_bytes()
                )

    def test_failure_leaves_no_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def failing(*_args: object) -> None:
                raise MODULE.FinalizationError("injected signer failure")

            with self.assertRaisesRegex(MODULE.FinalizationError, "injected"):
                self.run_fixture(fixture, signer=failing)
            self.assertFalse(fixture.output()[0].exists())

    def test_wrong_signer_identity_or_team_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def wrong(root: Path, fingerprint: str, team: str, receipt: Path) -> None:
                fake_signer(root, fingerprint, team, receipt)
                payload = json.loads(receipt.read_text())
                payload["teamID"] = "WRONGID123"
                receipt.write_bytes(canonical_json(payload))

            with self.assertRaisesRegex(MODULE.FinalizationError, "identity|Team"):
                self.run_fixture(fixture, signer=wrong)

    def test_signer_receipt_leaf_certificate_must_match_the_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def wrong_leaf(
                root: Path, fingerprint: str, team: str, receipt: Path
            ) -> None:
                fake_signer(root, fingerprint, team, receipt)
                payload = json.loads(receipt.read_text())
                payload["entries"][0]["codesign"]["leafCertificateSHA1"] = "F" * 40
                receipt.write_bytes(canonical_json(payload))

            with self.assertRaisesRegex(
                MODULE.FinalizationError, "does not bridge Mach-O bytes"
            ):
                self.run_fixture(fixture, signer=wrong_leaf)

    def test_signer_receipt_authority_labels_are_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def renamed_authorities(
                root: Path, fingerprint: str, team: str, receipt: Path
            ) -> None:
                fake_signer(root, fingerprint, team, receipt)
                payload = json.loads(receipt.read_text())
                for entry in payload["entries"]:
                    entry["codesign"]["authorities"] = [
                        "Future Developer ID Leaf Label",
                        "Future Developer ID Intermediate Label",
                        "Future Apple Trust Anchor Label",
                        "Additional Cross-Signing Label",
                    ]
                receipt.write_bytes(canonical_json(payload))

            result = self.run_fixture(fixture, signer=renamed_authorities)

            self.assertEqual(
                result["kind"],
                "easysplat-signed-toolchain-finalization",
            )

    def test_missing_or_extra_signed_macho_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for mode in ("missing", "extra"):
                with self.subTest(mode=mode):
                    fixture = Fixture(Path(temporary) / mode)

                    def corrupt(
                        root: Path, fingerprint: str, team: str, receipt: Path
                    ) -> None:
                        fake_signer(root, fingerprint, team, receipt)
                        payload = json.loads(receipt.read_text())
                        if mode == "missing":
                            payload["entries"].pop()
                        else:
                            payload["entries"].append(
                                dict(payload["entries"][0], relativePath="bin/extra")
                            )
                        receipt.write_bytes(canonical_json(payload))

                    with self.assertRaisesRegex(MODULE.FinalizationError, "Mach-O"):
                        self.run_fixture(fixture, signer=corrupt)

    def test_signer_mutation_outside_macho_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def mutate(root: Path, fingerprint: str, team: str, receipt: Path) -> None:
                fake_signer(root, fingerprint, team, receipt)
                (root / "bin/default.metallib").write_bytes(b"tampered")

            with self.assertRaisesRegex(MODULE.FinalizationError, "non-Mach-O|changed"):
                self.run_fixture(fixture, signer=mutate)

    def test_bad_record_hash_ownership_or_extra_site_package_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for mode in ("hash", "ownership", "extra"):
                with self.subTest(mode=mode):
                    fixture = Fixture(Path(temporary) / mode)
                    record_path = next(
                        path for path in fixture.base if path.endswith("/RECORD")
                    )
                    if mode == "hash":
                        fixture.base[record_path] = (
                            b"sample/native.so,sha256=AAAA,18\n",
                            0o644,
                        )
                    elif mode == "ownership":
                        fixture.base[record_path] = (b"sample/__init__.py,,\n", 0o644)
                    else:
                        fixture.base[
                            "da3_mps/python/lib/python3.13/site-packages/evil.py"
                        ] = (b"evil\n", 0o644)
                    fixture.refresh_manifest()
                    fixture.write_archives()
                    with self.assertRaisesRegex(
                        MODULE.FinalizationError, "RECORD|site-packages"
                    ):
                        self.run_fixture(fixture)

    def test_archive_traversal_symlink_special_duplicate_and_bomb_are_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cases = ("traversal", "symlink", "hardlink", "special", "duplicate", "bomb")
            for case in cases:
                with self.subTest(case=case):
                    fixture = Fixture(Path(temporary) / case)
                    with zipfile.ZipFile(
                        fixture.small_zip, "w", zipfile.ZIP_DEFLATED
                    ) as archive:
                        if case == "traversal":
                            archive.writestr("../escape", b"x")
                        elif case == "duplicate":
                            with warnings.catch_warnings():
                                warnings.simplefilter("ignore", UserWarning)
                                archive.writestr(
                                    "da3_mps/models/DA3-SMALL/config.json", b"a"
                                )
                                archive.writestr(
                                    "da3_mps/models/DA3-SMALL/config.json", b"b"
                                )
                        else:
                            info = zipfile.ZipInfo("da3_mps/models/DA3-SMALL/bad")
                            info.create_system = 3
                            if case == "symlink":
                                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                                archive.writestr(info, b"target")
                            elif case == "hardlink":
                                info.external_attr = (stat.S_IFREG | 0o644) << 16
                                info.extra = b"\x0d\x00\x04\x00link"
                                archive.writestr(info, b"target")
                            elif case == "special":
                                info.external_attr = (stat.S_IFIFO | 0o644) << 16
                                archive.writestr(info, b"x")
                            else:
                                info.external_attr = (stat.S_IFREG | 0o644) << 16
                                archive.writestr(info, b"0" * 10_000_000)
                                archive.writestr(
                                    "da3_mps/models/DA3-SMALL/model.safetensors",
                                    b"small",
                                )
                    old_limit = MODULE.MAX_COMPRESSION_RATIO
                    if case == "bomb":
                        MODULE.MAX_COMPRESSION_RATIO = 10
                    try:
                        with self.assertRaisesRegex(
                            MODULE.FinalizationError,
                            "archive|ZIP|duplicate|compression",
                        ):
                            self.run_fixture(fixture)
                    finally:
                        MODULE.MAX_COMPRESSION_RATIO = old_limit

    def test_base_component_rejects_every_small_model_member(self) -> None:
        for member in ("config.json", "model.safetensors", "LICENSE"):
            with self.subTest(member=member):
                with self.assertRaisesRegex(
                    MODULE.FinalizationError, "out-of-component"
                ):
                    MODULE.validate_component_path(
                        "base", f"da3_mps/models/DA3-SMALL/{member}"
                    )

    def test_tree_magic_probe_does_not_read_large_file_into_memory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            large = root / "model.safetensors"
            with large.open("wb") as stream:
                stream.seek(32 * 1024 * 1024 - 1)
                stream.write(b"\0")
            with mock.patch.object(
                Path, "read_bytes", side_effect=AssertionError("unbounded prefix read")
            ):
                state = MODULE.scan_tree(root)
            self.assertFalse(state.files["model.safetensors"].is_macho)
            self.assertEqual(state.files["model.safetensors"].size, 32 * 1024 * 1024)

    def test_source_archive_mutation_is_rejected_without_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def mutate_source(
                root: Path, fingerprint: str, team: str, receipt: Path
            ) -> None:
                fake_signer(root, fingerprint, team, receipt)
                fixture.core_zip.write_bytes(
                    fixture.core_zip.read_bytes() + b"mutation"
                )

            with self.assertRaisesRegex(
                MODULE.FinalizationError, "source archive changed"
            ):
                self.run_fixture(fixture, signer=mutate_source)
            self.assertFalse(fixture.output()[0].exists())

    def test_source_archives_must_match_authenticated_release_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.core_zip.write_bytes(fixture.core_zip.read_bytes() + b"substitute")
            with self.assertRaisesRegex(
                MODULE.FinalizationError, "authenticated release request"
            ):
                self.run_fixture(fixture, refresh_release_request=False)
            self.assertFalse(fixture.output()[0].exists())

    def test_unsigned_runner_must_come_from_authenticated_source_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            manifest_path = "supply-chain/components.json"
            manifest = json.loads(fixture.core[manifest_path][0])
            runner = next(
                component
                for component in manifest["components"]
                if component["id"] == "easysplat-da3-runner"
            )
            runner["revision"] = "f" * 40
            fixture.core[manifest_path] = (canonical_json(manifest), 0o644)
            fixture.write_archives()
            fixture.write_release_request()

            with self.assertRaisesRegex(
                MODULE.FinalizationError, "authenticated source commit"
            ):
                self.run_fixture(fixture, refresh_release_request=False)
            self.assertFalse(fixture.output()[0].exists())

    def test_release_request_requires_an_independent_expected_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, receipt = fixture.output()
            with self.assertRaisesRegex(
                MODULE.FinalizationError, "release request SHA-256"
            ):
                MODULE.finalize_signed_toolchain(
                    version=VERSION,
                    core_zip=fixture.core_zip,
                    base_zip=fixture.base_zip,
                    small_zip=fixture.small_zip,
                    unsigned_release_request=fixture.release_request,
                    builder_attested_unsigned_request_sha256="0" * 64,
                    output_directory=output,
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    signer_runner=fake_signer,
                    supply_chain_runner=fake_supply_chain,
                    archive_runner=fake_archive,
                    unsigned_validator=lambda _root: None,
                )

    def test_authenticated_request_expanded_closure_is_recomputed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            request = json.loads(fixture.release_request.read_text())
            request["manifest"]["components"][0]["expandedClosureSHA256"] = "f" * 64
            request["manifestSHA256"] = digest(compact_json(request["manifest"]))
            fixture.release_request.write_bytes(compact_json(request))

            with self.assertRaisesRegex(
                MODULE.FinalizationError, "expanded closure is stale"
            ):
                self.run_fixture(fixture, refresh_release_request=False)

    def test_authenticated_request_mutation_during_signing_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def mutate_request(
                root: Path, fingerprint: str, team: str, receipt: Path
            ) -> None:
                fake_signer(root, fingerprint, team, receipt)
                fixture.release_request.write_bytes(
                    fixture.release_request.read_bytes() + b" "
                )

            with self.assertRaisesRegex(
                MODULE.FinalizationError, "authenticated release request changed"
            ):
                self.run_fixture(fixture, signer=mutate_request)
            self.assertFalse(fixture.output()[0].exists())

    def test_archive_swap_and_restore_cannot_change_the_authenticated_snapshot(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            held = fixture.root / "held-core.zip"
            forged = fixture.root / "forged-core.zip"
            forged_files = dict(fixture.core)
            forged_files["licenses/EasySplat/LICENSE"] = (b"forged\n", 0o644)
            forged.write_bytes(zip_bytes(forged_files))
            original_extract = MODULE.safe_extract_archive
            swapped = False
            snapshot_was_original = False

            def swap_while_extracting(*args: Any, **kwargs: Any):
                nonlocal snapshot_was_original, swapped
                if not swapped:
                    swapped = True
                    os.replace(fixture.core_zip, held)
                    os.replace(forged, fixture.core_zip)
                    try:
                        stream = args[0]
                        stream.seek(0)
                        with zipfile.ZipFile(stream) as archive:
                            snapshot_was_original = (
                                archive.read("licenses/EasySplat/LICENSE") == b"MIT\n"
                            )
                        return original_extract(*args, **kwargs)
                    finally:
                        os.replace(fixture.core_zip, forged)
                        os.replace(held, fixture.core_zip)
                return original_extract(*args, **kwargs)

            with mock.patch.object(
                MODULE, "safe_extract_archive", side_effect=swap_while_extracting
            ), self.assertRaisesRegex(MODULE.FinalizationError, "source archive changed"):
                self.run_fixture(fixture)

            self.assertTrue(snapshot_was_original)
            self.assertFalse(fixture.output()[0].exists())

    @unittest.skipUnless(
        os.environ.get("EASYSPLAT_RUN_PRODUCTION_SHAPE_TEST") == "1",
        "set EASYSPLAT_RUN_PRODUCTION_SHAPE_TEST=1 for the 19,536-file release shape",
    )
    def test_production_shaped_unsigned_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            existing_owners = {
                fixture.owner(path)
                for path in {**fixture.core, **fixture.base, **fixture.small}
                if path != "supply-chain/components.json"
            }
            needed_owners = 63 - len(existing_owners)
            for index in range(needed_owners):
                fixture.core[f"licenses/shape-{index:02d}/file-00000.txt"] = (
                    f"shape owner {index}\n".encode(),
                    0o644,
                )
            current_rows = (
                len(fixture.core) + len(fixture.base) + len(fixture.small) - 1
            )
            for index in range(19_536 - current_rows):
                owner = index % needed_owners
                fixture.core[f"licenses/shape-{owner:02d}/file-{index + 1:05d}.txt"] = (
                    f"shape file {index}\n".encode(),
                    0o644,
                )
            fixture.refresh_manifest()
            fixture.write_archives()
            manifest = json.loads(fixture.core["supply-chain/components.json"][0])
            self.assertEqual(len(manifest["components"]), 63)
            self.assertEqual(len(manifest["files"]), 19_536)
            result = self.run_fixture(fixture)
            self.assertEqual(len(result["finalArchives"]), 3)

    def test_overlapping_component_and_unsafe_output_relationship_are_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            fixture.base["bin/colmap"] = (MACHO, 0o755)
            fixture.write_archives()
            with self.assertRaisesRegex(
                MODULE.FinalizationError, "overlap|out-of-component"
            ):
                self.run_fixture(fixture)

            nested_output = fixture.inputs / "signed"
            with self.assertRaisesRegex(MODULE.FinalizationError, "output"):
                MODULE.finalize_signed_toolchain(
                    version=VERSION,
                    core_zip=fixture.core_zip,
                    base_zip=fixture.base_zip,
                    small_zip=fixture.small_zip,
                    unsigned_release_request=fixture.release_request,
                    builder_attested_unsigned_request_sha256=digest(
                        fixture.release_request.read_bytes()
                    ),
                    output_directory=nested_output,
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=nested_output / "receipt.json",
                    signer_runner=fake_signer,
                    supply_chain_runner=fake_supply_chain,
                    archive_runner=fake_archive,
                    unsigned_validator=lambda _root: None,
                )

    def test_external_receipt_cannot_overwrite_a_final_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, _ = fixture.output()
            for name in (
                f"toolchain-macos-arm64-{VERSION}-core.zip",
                f"TOOLCHAIN-MACOS-ARM64-{VERSION}-CORE.ZIP",
            ):
                with self.subTest(name=name):
                    with self.assertRaisesRegex(MODULE.FinalizationError, "collides"):
                        MODULE.finalize_signed_toolchain(
                            version=VERSION,
                            core_zip=fixture.core_zip,
                            base_zip=fixture.base_zip,
                            small_zip=fixture.small_zip,
                            unsigned_release_request=fixture.release_request,
                            builder_attested_unsigned_request_sha256=digest(
                                fixture.release_request.read_bytes()
                            ),
                            output_directory=output,
                            identity_fingerprint=FINGERPRINT,
                            team_id=TEAM_ID,
                            receipt_path=output / name,
                            signer_runner=fake_signer,
                            supply_chain_runner=fake_supply_chain,
                            archive_runner=fake_archive,
                            unsigned_validator=lambda _root: None,
                        )

    def test_final_archives_are_reverified_after_receipt_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, receipt = fixture.output()
            original_atomic_write = MODULE.atomic_write

            def mutate_archive_after_receipt(
                path: Path, data: bytes, *, maximum: int
            ) -> None:
                original_atomic_write(path, data, maximum=maximum)
                if path.name == receipt.name:
                    archive = path.parent / f"toolchain-macos-arm64-{VERSION}-core.zip"
                    archive.write_bytes(archive.read_bytes() + b"tampered")

            with (
                mock.patch.object(
                    MODULE, "atomic_write", side_effect=mutate_archive_after_receipt
                ),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "changed after receipt|cannot be verified"
                ),
            ):
                self.run_fixture(fixture)
            self.assertFalse(output.exists())

    def test_archive_path_swap_after_zip_walk_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            original_close = zipfile.ZipFile.close
            swapped = False

            def swap_after_close(archive: zipfile.ZipFile) -> None:
                nonlocal swapped
                original_close(archive)
                if swapped:
                    return
                candidates = list(
                    fixture.root.glob(
                        ".easysplat-signed-toolchain-*/artifacts/"
                        f"toolchain-macos-arm64-{VERSION}-core.zip"
                    )
                )
                if len(candidates) == 1:
                    swapped = True
                    candidate = candidates[0]
                    candidate.write_bytes(candidate.read_bytes() + b"forged-tail")

            with (
                mock.patch.object(zipfile.ZipFile, "close", swap_after_close),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "changed during verification"
                ),
            ):
                self.run_fixture(fixture)
            self.assertTrue(swapped)
            self.assertFalse(fixture.output()[0].exists())

    def test_artifact_directory_swap_during_promotion_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, _ = fixture.output()
            original_replace = os.replace
            swapped = False

            def swap_before_replace(
                source: Any,
                destination: Any,
                *args: Any,
                **kwargs: Any,
            ) -> None:
                nonlocal swapped
                source_path = Path(source)
                if not swapped and source_path.name == "artifacts":
                    swapped = True
                    source_directory = kwargs.get("src_dir_fd")
                    if source_directory is None:
                        held = source_path.with_name("verified-artifacts-held")
                        original_replace(source_path, held)
                        source_path.mkdir()
                        (source_path / "forged.txt").write_text(
                            "forged\n", encoding="utf-8"
                        )
                    else:
                        original_replace(
                            source,
                            "verified-artifacts-held",
                            src_dir_fd=source_directory,
                            dst_dir_fd=source_directory,
                        )
                        os.mkdir("artifacts", mode=0o700, dir_fd=source_directory)
                        forged_directory = os.open(
                            "artifacts",
                            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                            dir_fd=source_directory,
                        )
                        try:
                            forged = os.open(
                                "forged.txt",
                                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                0o600,
                                dir_fd=forged_directory,
                            )
                            try:
                                os.write(forged, b"forged\n")
                            finally:
                                os.close(forged)
                        finally:
                            os.close(forged_directory)
                original_replace(source, destination, *args, **kwargs)

            with (
                mock.patch.object(os, "replace", side_effect=swap_before_replace),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "published output directory differs"
                ),
            ):
                self.run_fixture(fixture)
            self.assertTrue(swapped)
            self.assertFalse(output.exists())

    def test_output_parent_descriptor_must_match_validated_ancestry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, _ = fixture.output()
            original_open = os.open
            swapped = False

            def open_decoy_parent(
                path: Any,
                flags: int,
                mode: int = 0o777,
                *,
                dir_fd: int | None = None,
            ) -> int:
                nonlocal swapped
                if (
                    not swapped
                    and dir_fd is None
                    and Path(path) == fixture.root
                    and flags & getattr(os, "O_DIRECTORY", 0)
                    and list(fixture.root.glob(".easysplat-signed-toolchain-*"))
                ):
                    swapped = True
                    held = fixture.root.with_name(f"{fixture.root.name}-held")
                    os.rename(fixture.root, held)
                    fixture.root.mkdir(mode=0o700)
                    try:
                        descriptor = original_open(path, flags, mode)
                    finally:
                        fixture.root.rmdir()
                        os.rename(held, fixture.root)
                    return descriptor
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            with (
                mock.patch.object(os, "open", side_effect=open_decoy_parent),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "output parent descriptor"
                ),
            ):
                self.run_fixture(fixture)
            self.assertTrue(swapped)
            self.assertFalse(output.exists())

    def test_every_post_promotion_failure_removes_the_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, _ = fixture.output()
            original_verify = MODULE.require_bound_file_at

            def fail_after_promotion(
                directory_descriptor: int,
                name: str,
                expected: Any,
                *,
                label: str,
            ) -> None:
                if label == "published core archive":
                    raise MODULE.FinalizationError("injected post-promotion failure")
                original_verify(
                    directory_descriptor,
                    name,
                    expected,
                    label=label,
                )

            with (
                mock.patch.object(
                    MODULE, "require_bound_file_at", side_effect=fail_after_promotion
                ),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "injected post-promotion failure"
                ),
            ):
                self.run_fixture(fixture)
            self.assertFalse(output.exists())

    def test_unexpected_staged_output_entry_is_never_published(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, _ = fixture.output()
            original_verify = MODULE.require_bound_file_at
            injected = False

            def inject_extra_entry(
                directory_descriptor: int,
                name: str,
                expected: Any,
                *,
                label: str,
            ) -> None:
                nonlocal injected
                original_verify(
                    directory_descriptor,
                    name,
                    expected,
                    label=label,
                )
                if label == "external finalization receipt" and not injected:
                    injected = True
                    descriptor = os.open(
                        "unexpected.txt",
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=directory_descriptor,
                    )
                    try:
                        os.write(descriptor, b"unexpected\n")
                    finally:
                        os.close(descriptor)

            with (
                mock.patch.object(
                    MODULE, "require_bound_file_at", side_effect=inject_extra_entry
                ),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "unexpected directory entries"
                ),
            ):
                self.run_fixture(fixture)
            self.assertTrue(injected)
            self.assertFalse(output.exists())

    def test_source_archives_are_reverified_after_receipt_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            output, receipt = fixture.output()
            original_atomic_write = MODULE.atomic_write

            def mutate_source_after_receipt(
                path: Path, data: bytes, *, maximum: int
            ) -> None:
                original_atomic_write(path, data, maximum=maximum)
                if path.name == receipt.name:
                    fixture.core_zip.write_bytes(
                        fixture.core_zip.read_bytes() + b"tampered"
                    )

            with (
                mock.patch.object(
                    MODULE, "atomic_write", side_effect=mutate_source_after_receipt
                ),
                self.assertRaisesRegex(
                    MODULE.FinalizationError, "source archive changed"
                ),
            ):
                self.run_fixture(fixture)
            self.assertFalse(output.exists())

    def test_record_repair_resolves_console_script_member_inside_python_runtime(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))
            console_path = "da3_mps/python/bin/sample-tool"
            fixture.base[console_path] = (MACHO, 0o755)
            record_path = next(
                path for path in fixture.base if path.endswith("/RECORD")
            )
            record = fixture.base[record_path][0].decode()
            fixture.base[record_path] = (
                (
                    f"../../../bin/sample-tool,{record_hash(MACHO)},{len(MACHO)}\n"
                    + record
                ).encode(),
                0o644,
            )
            fixture.refresh_manifest()
            fixture.write_archives()

            self.run_fixture(fixture)

            output, _receipt = fixture.output()
            with zipfile.ZipFile(
                output / f"toolchain-geometry-da3-base-{VERSION}.zip"
            ) as archive:
                repaired = archive.read(record_path).decode()
            self.assertIn("../../../bin/sample-tool,sha256=", repaired)

    def test_signer_tree_counts_are_verified_but_digests_are_not_republished(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def wrong_count(
                root: Path, fingerprint: str, team: str, receipt: Path
            ) -> None:
                fake_signer(root, fingerprint, team, receipt)
                payload = json.loads(receipt.read_text())
                payload["tree"]["preSignFileCount"] += 1
                receipt.write_bytes(canonical_json(payload))

            with self.assertRaisesRegex(MODULE.FinalizationError, "file count"):
                self.run_fixture(fixture, signer=wrong_count)

    def test_signer_tree_manifest_digests_must_match_the_verified_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Fixture(Path(temporary))

            def wrong_digest(
                root: Path, fingerprint: str, team: str, receipt: Path
            ) -> None:
                fake_signer(root, fingerprint, team, receipt)
                payload = json.loads(receipt.read_text())
                payload["tree"]["postSignManifestSHA256"] = "0" * 64
                receipt.write_bytes(canonical_json(payload))

            with self.assertRaisesRegex(MODULE.FinalizationError, "tree digest"):
                self.run_fixture(fixture, signer=wrong_digest)

    def test_production_runner_rechecks_tracked_source_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_root = root / "source"
            relative = "scripts/release/sign_macos_distribution.py"
            source = source_root / relative
            source.parent.mkdir(parents=True)
            source.write_text("print('signed')\n", encoding="utf-8")
            tracked = MODULE.tracked_source_input_bindings(source_root, (relative,))

            def mutate_source(
                _command: list[str],
                _label: str,
                *,
                timeout: int = 3600,
                pass_fds: tuple[int, ...] = (),
            ) -> None:
                del pass_fds, timeout
                source.write_text("print('substituted')\n", encoding="utf-8")

            with (
                mock.patch.object(MODULE, "run_checked", side_effect=mutate_source),
                self.assertRaisesRegex(
                    MODULE.FinalizationError,
                    "tracked distribution-signing inputs changed",
                ),
            ):
                MODULE.production_signer(
                    root,
                    FINGERPRINT,
                    TEAM_ID,
                    root / "signer.json",
                    tracked_inputs=tracked,
                    source_root=source_root,
                )

    def test_tracked_sources_match_authenticated_git_blobs_despite_git_env_poison(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repository = root / "repository"
            repository.mkdir()
            subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "init", "--quiet"],
                check=True,
            )
            relative = "scripts/reviewed.py"
            source = repository / relative
            source.parent.mkdir(parents=True)
            source.write_text("print('reviewed')\n", encoding="utf-8")
            subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "add", relative],
                check=True,
            )
            subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(repository),
                    "-c",
                    "user.name=EasySplat Test",
                    "-c",
                    "user.email=test@invalid.example",
                    "commit",
                    "--quiet",
                    "-m",
                    "fixture",
                ],
                check=True,
            )
            commit = subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            reviewed = MODULE.tracked_source_input_bindings(repository, (relative,))
            decoy = root / "decoy-worktree"
            decoy.mkdir()
            (decoy / relative).parent.mkdir(parents=True)
            (decoy / relative).write_text("print('reviewed')\n", encoding="utf-8")
            clean_git_environment = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GIT_")
            }

            with mock.patch.dict(
                os.environ,
                {
                    "GIT_WORK_TREE": str(decoy),
                    "GIT_INDEX_FILE": str(root / "forged-index"),
                    "GIT_CONFIG_GLOBAL": str(root / "forged-gitconfig"),
                },
            ):
                MODULE.require_tracked_sources_match_commit(
                    reviewed,
                    commit,
                    root=repository,
                )

                source.write_text("print('substituted')\n", encoding="utf-8")
                subprocess.run(
                    ["/usr/bin/git", "-C", str(repository), "add", relative],
                    check=True,
                    env=clean_git_environment,
                )
                subprocess.run(
                    [
                        "/usr/bin/git",
                        "-C",
                        str(repository),
                        "-c",
                        "user.name=EasySplat Test",
                        "-c",
                        "user.email=test@invalid.example",
                        "commit",
                        "--quiet",
                        "-m",
                        "substitute",
                    ],
                    check=True,
                    env=clean_git_environment,
                )
                substitute_commit = subprocess.run(
                    [
                        "/usr/bin/git",
                        "-C",
                        str(repository),
                        "rev-parse",
                        "HEAD",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                    env=clean_git_environment,
                ).stdout.strip()
                subprocess.run(
                    [
                        "/usr/bin/git",
                        "-C",
                        str(repository),
                        "replace",
                        commit,
                        substitute_commit,
                    ],
                    check=True,
                    env=clean_git_environment,
                )
                substituted = MODULE.tracked_source_input_bindings(
                    repository, (relative,)
                )
                with self.assertRaisesRegex(
                    MODULE.FinalizationError, "authenticated Git commit"
                ):
                    MODULE.require_tracked_sources_match_commit(
                        substituted,
                        commit,
                        root=repository,
                    )

    def test_production_runner_executes_the_reviewed_script_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_root = root / "source"
            relative = "scripts/release/sign_macos_distribution.py"
            source = source_root / relative
            source.parent.mkdir(parents=True)
            reviewed = b"print('reviewed signer')\n"
            source.write_bytes(reviewed)
            tracked = MODULE.tracked_source_input_bindings(source_root, (relative,))

            def inspect_descriptor(
                command: list[str],
                _label: str,
                *,
                timeout: int = 3600,
                pass_fds: tuple[int, ...] = (),
            ) -> None:
                del timeout
                self.assertEqual(command[:3], ["/usr/bin/python3", "-I", "-c"])
                self.assertEqual(len(pass_fds), 1)
                descriptor = pass_fds[0]
                self.assertEqual(os.pread(descriptor, len(reviewed), 0), reviewed)
                self.assertNotEqual(command[2], str(source))

            with mock.patch.object(
                MODULE, "run_checked", side_effect=inspect_descriptor
            ):
                MODULE.production_signer(
                    root,
                    FINGERPRINT,
                    TEAM_ID,
                    root / "signer.json",
                    tracked_inputs=tracked,
                    source_root=source_root,
                )

    def test_production_runner_executes_an_anonymous_reviewed_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_root = root / "source"
            relative = "scripts/release/sign_macos_distribution.py"
            source = source_root / relative
            source.parent.mkdir(parents=True)
            reviewed = b"print('reviewed signer')\n"
            source.write_bytes(reviewed)
            tracked = MODULE.tracked_source_input_bindings(source_root, (relative,))
            observed = b""

            def mutate_after_snapshot(
                _command: list[str],
                _label: str,
                *,
                timeout: int = 3600,
                pass_fds: tuple[int, ...] = (),
            ) -> None:
                nonlocal observed
                del timeout
                source.write_bytes(b"print('substituted signer')\n")
                self.assertEqual(len(pass_fds), 1)
                observed = os.pread(pass_fds[0], 4096, 0)

            with (
                mock.patch.object(MODULE, "run_checked", side_effect=mutate_after_snapshot),
                self.assertRaisesRegex(
                    MODULE.FinalizationError,
                    "tracked distribution-signing inputs changed",
                ),
            ):
                MODULE.production_signer(
                    root,
                    FINGERPRINT,
                    TEAM_ID,
                    root / "signer.json",
                    tracked_inputs=tracked,
                    source_root=source_root,
                )

            self.assertEqual(observed, reviewed)

    def test_production_subprocesses_drop_interpreter_startup_injection(self) -> None:
        completed = subprocess.CompletedProcess(["/usr/bin/true"], 0, "", "")
        with (
            mock.patch.dict(
                os.environ,
                {
                    "BASH_ENV": "/tmp/injected.sh",
                    "DEVELOPER_DIR": "/tmp/substitute-xcode.app/Contents/Developer",
                    "ENV": "/tmp/injected.sh",
                    "PYTHONHOME": "/tmp/python",
                    "PYTHONPATH": "/tmp/modules",
                    "PYTHONSTARTUP": "/tmp/startup.py",
                    "SDKROOT": "/tmp/substitute-sdk",
                    "TOOLCHAINS": "substitute-toolchain",
                    "GITHUB_TOKEN": "must-not-reach-signing-tools",
                },
            ),
            mock.patch.object(subprocess, "run", return_value=completed) as run,
        ):
            MODULE.run_checked(["/usr/bin/true"], "fixture")

        environment = run.call_args.kwargs["env"]
        forbidden = {
            "BASH_ENV",
            "DEVELOPER_DIR",
            "ENV",
            "PYTHONHOME",
            "PYTHONPATH",
            "PYTHONSTARTUP",
            "SDKROOT",
            "TOOLCHAINS",
            "GITHUB_TOKEN",
        }
        self.assertFalse(forbidden.intersection(environment))
        self.assertEqual(
            environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin"
        )


if __name__ == "__main__":
    unittest.main()
