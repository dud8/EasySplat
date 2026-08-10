from __future__ import annotations

import base64
import errno
import importlib.util
import hashlib
import json
import os
import shutil
import stat
import subprocess
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

PRODUCTION_FIXTURE_SCRIPT = Path(__file__).with_name("create_toolchain_fixture.py")
PRODUCTION_FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "production_toolchain_fixture", PRODUCTION_FIXTURE_SCRIPT
)
assert PRODUCTION_FIXTURE_SPEC and PRODUCTION_FIXTURE_SPEC.loader
PRODUCTION_FIXTURE = importlib.util.module_from_spec(PRODUCTION_FIXTURE_SPEC)
PRODUCTION_FIXTURE_SPEC.loader.exec_module(PRODUCTION_FIXTURE)


VERSION = "0.2.0"
TOOLCHAIN_VERSION = "2.0.0"
REPOSITORY = "dud8/EasySplat"
COMMIT = "a" * 40
TAG = f"v{VERSION}"
PUBLIC_KEY_BYTES = base64.b64encode(bytes(range(32))) + b"\n"
MANIFEST_URL = (
    f"https://github.com/{REPOSITORY}/releases/download/"
    f"toolchain-v{TOOLCHAIN_VERSION}/manifest.json"
)
PRODUCTION_RELEASE_NOTES = (
    f"EasySplat {VERSION} is a Developer ID-signed and notarized release.\n"
    "Install the Developer ID-signed, notarized, and stapled DMG on an Apple "
    "Silicon Mac running macOS 15 or later.\n"
    "\n"
    "EasySplat turns video, photo folders, or mixed inputs into static 3D "
    "Gaussian splats locally. Input media stays on your Mac. Capture-aware "
    "native COLMAP reconstruction uses FAISS matching, and the native Metal "
    "trainer writes a validated PLY. When the geometry is conclusive, "
    "EasySplat aligns the scene upright. The viewer supports orbit, pan, zoom, "
    "fit, reset, export, and system Share. Work can stop and resume at durable "
    "stages. EasySplat has no cloud processing, telemetry, or analytics.\n"
    "\n"
    "One reconstruction runs at a time. PLY is the only export format. Moving "
    "subjects, reflections, water, foliage, and large lighting changes can "
    "leave artifacts.\n"
    "\n"
    "Release files include the DMG SHA-256 checksum, provenance record, SPDX "
    "SBOM, third-party license bundle, and dSYM archive.\n"
).encode("utf-8")
APP_BUNDLED_HELPERS = (
    "Contents/Helpers/bin/colmap",
    "Contents/Helpers/bin/easysplat-train",
)
APP_BUNDLED_PAYLOAD = (
    "Contents/Helpers/lib/libomp.dylib",
    "Contents/Resources/Toolchain/default.metallib",
    "Contents/Resources/Toolchain/supply-chain/components.json",
)


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


def write_app_fixture(root: Path) -> tuple[Path, Path]:
    app = root / "EasySplat.app"
    executable = app / "Contents/MacOS/EasySplatApp"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"binary")
    (app / "Contents/Info.plist").write_bytes(b"plist")
    (app / "Contents/_CodeSignature").mkdir()
    for relative in APP_BUNDLED_HELPERS:
        helper = app / relative
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_bytes(b"helper")
        helper.chmod(0o755)
    for relative in APP_BUNDLED_PAYLOAD:
        payload = app / relative
        payload.parent.mkdir(parents=True, exist_ok=True)
        payload.write_bytes(b"payload")
        payload.chmod(0o644)
    public_key = root / "expected-public-key.txt"
    public_key.write_bytes(PUBLIC_KEY_BYTES)
    return app, public_key


def replace_zip_entry(path: Path, name: str, data: bytes) -> None:
    replacement = path.with_suffix(".replacement.zip")
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(replacement, "w") as output:
        found = False
        for info in source.infolist():
            if info.filename == name:
                output.writestr(info, data)
                found = True
            else:
                output.writestr(info, source.read(info))
    if not found:
        raise AssertionError(f"fixture archive entry is missing: {name}")
    replacement.replace(path)


def bind_publication_files(
    root: Path,
    names: set[str],
) -> dict[str, object]:
    return {
        name: MODULE.bind_bounded_regular_file(
            root / name,
            f"test publication file {name}",
            limit=max((root / name).stat().st_size, 1),
        )
        for name in names
    }


DSYM_DIRECTORIES = (
    "EasySplat.app.dSYM/",
    "EasySplat.app.dSYM/Contents/",
    "EasySplat.app.dSYM/Contents/Resources/",
    "EasySplat.app.dSYM/Contents/Resources/DWARF/",
    "EasySplat.app.dSYM/Contents/Resources/Relocations/",
    "EasySplat.app.dSYM/Contents/Resources/Relocations/aarch64/",
)


def write_dsym_fixture(path: Path, *, include_extra: bool = False) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for directory in DSYM_DIRECTORIES:
            info = zipfile.ZipInfo(directory)
            info.create_system = 3
            info.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, b"")

        def write_file(name: str, data: bytes) -> None:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)

        write_file("EasySplat.app.dSYM/Contents/Info.plist", b"plist")
        write_file(
            "EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp",
            b"dwarf",
        )
        write_file(
            (
                "EasySplat.app.dSYM/Contents/Resources/Relocations/"
                "aarch64/EasySplatApp.yml"
            ),
            b"relocations",
        )
        if include_extra:
            write_file(
                "EasySplat.app.dSYM/Contents/Resources/extra.bin",
                b"unbound",
            )


def valid_app_static_result(command: list[str]) -> mock.Mock:
    if command[0] == MODULE.SYSTEM_TOOLS["lipo"]:
        return mock.Mock(stdout="arm64\n", stderr="", returncode=0)
    if command[0] == MODULE.SYSTEM_TOOLS["dwarfdump"]:
        return mock.Mock(
            stdout=(
                "UUID: 11111111-1111-1111-1111-111111111111 "
                "(arm64) EasySplatApp\n"
            ),
            stderr="",
            returncode=0,
        )
    if command[0] == MODULE.SYSTEM_TOOLS["codesign"] and "-dvvv" in command:
        return mock.Mock(
            stdout="",
            stderr=(
                "Identifier=com.easysplat.app\n"
                "Signature=adhoc\n"
                "TeamIdentifier=not set\n"
            ),
            returncode=0,
        )
    return mock.Mock(stdout="", stderr="", returncode=0)


def validate_app_fixture(app: Path, public_key: Path) -> str:
    return MODULE.validate_app_bundle(
        app,
        app_version=VERSION,
        toolchain_version=TOOLCHAIN_VERSION,
        source_repository=REPOSITORY,
        toolchain_public_key=public_key,
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
        "schemaVersion": 2,
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
        "releaseMode": "development-unsigned",
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
        "schemaVersion": 2,
        "toolchainVersion": TOOLCHAIN_VERSION,
        "componentsSHA256": component_sha,
        "embedded": [
            {
                "id": archive_id,
                "entries": [row for row in files if row["component"] == component_id],
            }
            for archive_id, _path, component_id in archives
            if archive_id == "core"
        ],
    }
    archive_path = root / "licenses.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(
            "EasySplat/LICENSE",
            (MODULE.REPOSITORY_ROOT / "LICENSE").read_bytes(),
        )
        archive.writestr(
            "EasySplat/NOTICE.md",
            (MODULE.REPOSITORY_ROOT / "NOTICE.md").read_bytes(),
        )
        archive.writestr(
            "MetalSplatter/LICENSE",
            (
                MODULE.REPOSITORY_ROOT
                / "ThirdParty/MetalSplatter/LICENSE"
            ).read_bytes(),
        )
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


def production_supply_chain_fixture(
    root: Path,
    *,
    source_artifact_tamper: str | None = None,
    put_da3_runtime_in_core: bool = False,
) -> dict[str, object]:
    toolchain_root = root / "toolchain"
    roots, colmap, trainer_metallib = PRODUCTION_FIXTURE.create_files(toolchain_root)
    PRODUCTION_FIXTURE.native_receipts(roots, colmap, trainer_metallib)
    components = PRODUCTION_FIXTURE.supply_components(roots)
    component_by_id = {row["id"]: row for row in components}

    all_files: dict[str, tuple[str, Path]] = {}
    archive_id_by_root = {
        "core": "core",
        "base": "geometry-da3-base",
        "small": "geometry-da3-small",
    }
    for root_name, archive_root in roots.items():
        for path in archive_root.rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(archive_root).as_posix()
            if relative == "supply-chain/components.json":
                continue
            if relative in all_files:
                raise AssertionError(f"duplicate fixture path: {relative}")
            all_files[relative] = (archive_id_by_root[root_name], path)

    files: list[dict[str, object]] = []
    archive_entries: dict[str, list[dict[str, object]]] = {
        "core": [],
        "geometry-da3-base": [],
        "geometry-da3-small": [],
    }
    for relative in sorted(all_files):
        archive_id, path = all_files[relative]
        data = path.read_bytes()
        component_id = PRODUCTION_FIXTURE.owner(relative)
        component_by_id[component_id]["files"].append(relative)
        kind = PRODUCTION_FIXTURE.fixture_file_kind(relative)
        row: dict[str, object] = {
            "component": component_id,
            "kind": kind,
            "path": relative,
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data),
        }
        if kind == "mach-o":
            row["dependencies"] = []
        files.append(row)
        if put_da3_runtime_in_core and archive_id == "geometry-da3-base" and not relative.startswith(
            "da3_mps/models/DA3-BASE/"
        ):
            archive_id = "core"
        archive_entries[archive_id].append(row)

    if source_artifact_tamper is not None:
        source_artifacts = component_by_id["model:da3-base"]["sourceArtifacts"]
        if source_artifact_tamper == "extra-field":
            source_artifacts[0]["unexpected"] = True
        elif source_artifact_tamper == "missing":
            component_by_id["model:da3-base"].pop("sourceArtifacts")
        elif source_artifact_tamper == "duplicate":
            source_artifacts.append(dict(source_artifacts[0]))
        elif source_artifact_tamper == "credentials":
            source_artifacts[0]["url"] = "https://user:secret@example.com/model"
        elif source_artifact_tamper == "query-credentials":
            source_artifacts[0]["url"] = "https://example.com/model?token=secret"
        elif source_artifact_tamper == "digest":
            source_artifacts[0]["sha256"] = "not-a-digest"
        elif source_artifact_tamper == "size":
            source_artifacts[0]["size"] = True
        elif source_artifact_tamper == "name":
            source_artifacts[0]["name"] = "../config.json"
        elif source_artifact_tamper == "control-name":
            source_artifacts[0]["name"] = "config\n.json"
        elif source_artifact_tamper == "binding-digest":
            source_artifacts[0]["sha256"] = "0" * 64
        elif source_artifact_tamper == "binding-size":
            source_artifacts[0]["size"] += 1
        elif source_artifact_tamper == "missing-binding":
            missing_path = "da3_mps/models/DA3-BASE/config.json"
            files[:] = [row for row in files if row["path"] != missing_path]
            component_by_id["model:da3-base"]["files"].remove(missing_path)
            for entries_for_archive in archive_entries.values():
                entries_for_archive[:] = [
                    row for row in entries_for_archive if row["path"] != missing_path
                ]
        elif source_artifact_tamper == "extra-binding":
            source_artifacts.insert(
                1,
                {
                    "name": "extra.bin",
                    "sha256": "0" * 64,
                    "size": 1,
                    "url": "https://example.com/extra.bin",
                },
            )
        else:
            raise AssertionError(f"unknown source artifact tamper: {source_artifact_tamper}")

    components.sort(key=lambda row: row["id"])
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
            "downloadURL": (
                f"https://github.com/{REPOSITORY}/releases/download/"
                f"toolchain-v{TOOLCHAIN_VERSION}/{archive_id}.zip"
            ),
            "sha256": str(index) * 64,
            "size": index,
        }
        for index, archive_id in enumerate(archive_entries, start=1)
    }
    provenance = {
        "schemaVersion": 2,
        "releaseMode": "development-unsigned",
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
        "artifacts": {
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
                "downloadURL": MANIFEST_URL,
                "sha256": "e" * 64,
                "size": 5,
            },
            **artifact_rows,
        },
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
        "schemaVersion": 2,
        "toolchainVersion": TOOLCHAIN_VERSION,
        "componentsSHA256": component_sha,
        "embedded": [
            {
                "id": archive_id,
                "entries": archive_entries[archive_id],
            }
            for archive_id in archive_entries
            if archive_id == "core"
        ],
    }
    archive_path = root / "licenses.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(
            "EasySplat/LICENSE",
            (MODULE.REPOSITORY_ROOT / "LICENSE").read_bytes(),
        )
        archive.writestr(
            "EasySplat/NOTICE.md",
            (MODULE.REPOSITORY_ROOT / "NOTICE.md").read_bytes(),
        )
        archive.writestr(
            "MetalSplatter/LICENSE",
            (
                MODULE.REPOSITORY_ROOT
                / "ThirdParty/MetalSplatter/LICENSE"
            ).read_bytes(),
        )
        archive.writestr("Toolchain/supply-chain/components.json", component_bytes)
        archive.writestr(
            "toolchain-closure.json", MODULE.canonical_json_bytes(closure_payload)
        )
        license_paths = {
            license_path
            for component in components
            for license_path in component["licenseFiles"]
        }
        for license_path in sorted(license_paths):
            archive.writestr(
                f"Toolchain/{license_path}", all_files[license_path][1].read_bytes()
            )
    return {
        "archive_path": archive_path,
        "components": component_payload,
        "provenance": provenance,
        "manifest": manifest,
        "closure": closure_payload,
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
        archive_rows={row["id"]: row["entries"] for row in closure_payload["embedded"]},
    )
    return GENERATOR.build_spdx(
        supply_chain["provenance"],
        closure,
        f"EasySplat-{VERSION}-licenses.zip",
    )


class BundleBoundaryTests(unittest.TestCase):
    @staticmethod
    def _generic_file_readers() -> tuple[tuple[str, object], ...]:
        return (
            (
                "load_json",
                lambda path, limit: MODULE.load_json(
                    path, "generic publication JSON", limit=limit
                ),
            ),
            (
                "load_compact_canonical_json",
                lambda path, limit: MODULE.load_compact_canonical_json(
                    path, "generic compact publication JSON", limit=limit
                ),
            ),
            (
                "sha256_file",
                lambda path, limit: MODULE.sha256_file(path, limit=limit),
            ),
            (
                "file_record",
                lambda path, limit: MODULE.file_record(
                    path, maximum_size=limit
                ),
            ),
        )

    def test_generic_publication_readers_reject_path_swap(self) -> None:
        original = b'{"value":"original"}'
        replacement = b'{"value":"mutation"}'
        self.assertEqual(len(original), len(replacement))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, reader in self._generic_file_readers():
                with self.subTest(reader=name):
                    case = root / name
                    case.mkdir()
                    path = case / "input.json"
                    moved = case / "opened-input.json"
                    path.write_bytes(original)
                    real_read = os.read
                    swapped = False

                    def swap_after_open(descriptor: int, count: int) -> bytes:
                        nonlocal swapped
                        if not swapped:
                            path.rename(moved)
                            path.write_bytes(replacement)
                            swapped = True
                        return real_read(descriptor, count)

                    with mock.patch.object(
                        MODULE.os, "read", side_effect=swap_after_open
                    ):
                        with self.assertRaisesRegex(
                            MODULE.PublicationError, "changed"
                        ):
                            reader(path, 1_024)
                    self.assertTrue(swapped)

    def test_generic_publication_readers_reject_inplace_mutation_with_restored_mtime(
        self,
    ) -> None:
        original = b'{"value":"original"}'
        replacement = b'{"value":"mutation"}'
        self.assertEqual(len(original), len(replacement))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, reader in self._generic_file_readers():
                with self.subTest(reader=name):
                    case = root / name
                    case.mkdir()
                    path = case / "input.json"
                    path.write_bytes(original)
                    before = path.stat()
                    real_read = os.read
                    mutated = False

                    def mutate_after_open(descriptor: int, count: int) -> bytes:
                        nonlocal mutated
                        if not mutated:
                            with path.open("r+b") as stream:
                                self.assertEqual(
                                    stream.write(replacement), len(replacement)
                                )
                                stream.flush()
                                os.fsync(stream.fileno())
                            os.utime(
                                path,
                                ns=(before.st_atime_ns, before.st_mtime_ns),
                                follow_symlinks=False,
                            )
                            after = path.stat()
                            self.assertEqual(
                                after.st_mtime_ns, before.st_mtime_ns
                            )
                            self.assertNotEqual(
                                after.st_ctime_ns, before.st_ctime_ns
                            )
                            mutated = True
                        return real_read(descriptor, count)

                    with mock.patch.object(
                        MODULE.os, "read", side_effect=mutate_after_open
                    ):
                        with self.assertRaisesRegex(
                            MODULE.PublicationError, "changed"
                        ):
                            reader(path, 1_024)
                    self.assertTrue(mutated)

    def test_generic_publication_readers_reject_unsafe_file_types_and_size(
        self,
    ) -> None:
        canonical = b'{"value":"original"}'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, reader in self._generic_file_readers():
                with self.subTest(reader=name, attack="symlink"):
                    case = root / f"{name}-symlink"
                    case.mkdir()
                    target = case / "target.json"
                    target.write_bytes(canonical)
                    link = case / "input.json"
                    link.symlink_to(target)
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, "safely open|regular file"
                    ):
                        reader(link, 1_024)

                with self.subTest(reader=name, attack="hardlink"):
                    case = root / f"{name}-hardlink"
                    case.mkdir()
                    path = case / "input.json"
                    path.write_bytes(canonical)
                    os.link(path, case / "second-link.json")
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, "single-link|hard link"
                    ):
                        reader(path, 1_024)

                with self.subTest(reader=name, attack="oversize"):
                    case = root / f"{name}-oversize"
                    case.mkdir()
                    path = case / "input.json"
                    path.write_bytes(canonical + b"x")
                    with self.assertRaisesRegex(
                        MODULE.PublicationError,
                        "size limit|bounded|exceeded",
                    ):
                        reader(path, len(canonical))

    def test_bounded_copy_rejects_source_swap_and_removes_partial_output(self) -> None:
        original = b"original publication bytes"
        replacement = b"mutated publication bytes!"
        self.assertEqual(len(original), len(replacement))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.bin"
            moved = root / "opened-source.bin"
            destination = root / "destination.bin"
            source.write_bytes(original)
            real_read = os.read
            swapped = False

            def swap_after_open(descriptor: int, count: int) -> bytes:
                nonlocal swapped
                if not swapped:
                    source.rename(moved)
                    source.write_bytes(replacement)
                    swapped = True
                return real_read(descriptor, count)

            with mock.patch.object(MODULE.os, "read", side_effect=swap_after_open):
                with self.assertRaisesRegex(MODULE.PublicationError, "changed"):
                    MODULE.copy_bounded_regular_file(
                        source,
                        destination,
                        "publication source",
                        limit=1_024,
                    )

            self.assertTrue(swapped)
            self.assertFalse(destination.exists())

    def test_bounded_copy_never_removes_a_preexisting_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.bin"
            destination = root / "destination.bin"
            source.write_bytes(b"source")
            destination.write_bytes(b"user-owned destination")

            with self.assertRaisesRegex(
                MODULE.PublicationError,
                "cannot create bounded copy",
            ):
                MODULE.copy_bounded_regular_file(
                    source,
                    destination,
                    "publication source",
                    limit=1_024,
                )

            self.assertEqual(destination.read_bytes(), b"user-owned destination")

    def test_bounded_copy_rejects_destination_swap_without_deleting_replacement(
        self,
    ) -> None:
        original = b"source publication bytes"
        replacement = b"other publication bytes!"
        self.assertEqual(len(original), len(replacement))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.bin"
            destination = root / "destination.bin"
            moved = root / "opened-destination.bin"
            source.write_bytes(original)
            real_fsync = os.fsync
            swapped = False

            def swap_after_flush(descriptor: int) -> None:
                nonlocal swapped
                real_fsync(descriptor)
                if not swapped:
                    destination.rename(moved)
                    destination.write_bytes(replacement)
                    swapped = True

            with mock.patch.object(MODULE.os, "fsync", side_effect=swap_after_flush):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "destination changed",
                ):
                    MODULE.copy_bounded_regular_file(
                        source,
                        destination,
                        "publication source",
                        limit=1_024,
                    )

            self.assertTrue(swapped)
            self.assertEqual(destination.read_bytes(), replacement)
            self.assertEqual(moved.read_bytes(), original)

    def test_exact_directory_staging_rejects_file_swap(self) -> None:
        original = b"original staged bytes"
        replacement = b"mutated staged bytes!"
        self.assertEqual(len(original), len(replacement))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            path = source / "artifact.bin"
            moved = source / "opened-artifact.bin"
            path.write_bytes(original)
            real_read = os.read
            swapped = False

            def swap_after_open(descriptor: int, count: int) -> bytes:
                nonlocal swapped
                if not swapped:
                    path.rename(moved)
                    path.write_bytes(replacement)
                    swapped = True
                return real_read(descriptor, count)

            with mock.patch.object(MODULE.os, "read", side_effect=swap_after_open):
                with self.assertRaisesRegex(MODULE.PublicationError, "changed"):
                    MODULE.stage_exact_directory(
                        source,
                        destination,
                        {"artifact.bin": 1_024},
                        label="publication input",
                    )

            self.assertTrue(swapped)

    def test_exact_directory_staging_rejects_mixed_file_generations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            first = source / "a.bin"
            second = source / "b.bin"
            first.write_bytes(b"AAAA")
            second.write_bytes(b"BBBB")
            real_open = os.open
            mutated = False

            def mutate_before_second_open(
                path: object,
                flags: int,
                _mode: int = 0o600,
                *,
                dir_fd: int | None = None,
            ) -> int:
                nonlocal mutated
                if path == "b.bin" and dir_fd is not None and not mutated:
                    first.write_bytes(b"CCCC")
                    second.write_bytes(b"EVIL")
                    mutated = True
                if flags & os.O_CREAT:
                    return real_open(path, flags, 0o600, dir_fd=dir_fd)
                return real_open(path, flags, dir_fd=dir_fd)

            with mock.patch.object(
                MODULE.os,
                "open",
                side_effect=mutate_before_second_open,
            ):
                with self.assertRaisesRegex(MODULE.PublicationError, "changed"):
                    MODULE.stage_exact_directory(
                        source,
                        destination,
                        {"a.bin": 1_024, "b.bin": 1_024},
                        label="publication input",
                    )

            self.assertTrue(mutated)

    def test_publication_verification_uses_private_input_snapshots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            output = root / "output"
            benchmark = root / "benchmark.json"
            public_key = root / "public-key.txt"
            write_build_payload(bundle)
            write_build_closure(bundle)
            benchmark.write_bytes(b"benchmark\n")
            public_key.write_bytes(b"public-key\n")
            source_name = build_names()[0]
            original = (bundle / source_name).read_bytes()
            staged_paths: list[Path] = []

            def inspect_staged_inputs(**arguments: object) -> None:
                staged_bundle = arguments["bundle"]
                staged_benchmark = arguments["benchmark_suite"]
                staged_public_key = arguments["toolchain_public_key"]
                self.assertIsInstance(staged_bundle, Path)
                self.assertIsInstance(staged_benchmark, Path)
                self.assertIsInstance(staged_public_key, Path)
                assert isinstance(staged_bundle, Path)
                assert isinstance(staged_benchmark, Path)
                assert isinstance(staged_public_key, Path)
                self.assertNotEqual(staged_bundle, bundle)
                self.assertNotEqual(staged_benchmark, benchmark)
                self.assertNotEqual(staged_public_key, public_key)
                (bundle / source_name).write_bytes(b"source changed after staging")
                benchmark.write_bytes(b"benchmark changed after staging")
                public_key.write_bytes(b"key changed after staging")
                self.assertEqual((staged_bundle / source_name).read_bytes(), original)
                self.assertEqual(staged_benchmark.read_bytes(), b"benchmark\n")
                self.assertEqual(staged_public_key.read_bytes(), b"public-key\n")
                staged_paths.extend(
                    (staged_bundle, staged_benchmark, staged_public_key)
                )
                staged_output = arguments["output"]
                self.assertIsInstance(staged_output, Path)
                assert isinstance(staged_output, Path)
                self.assertNotEqual(staged_output, output)
                for name in MODULE.publication_payload_names(
                    VERSION,
                    "development-unsigned",
                ):
                    (staged_output / name).write_bytes(b"fixture\n")
                (staged_output / MODULE.PUBLICATION_MANIFEST_NAME).write_bytes(
                    b"{}\n"
                )
                return bind_publication_files(
                    staged_output,
                    {
                        *MODULE.publication_payload_names(
                            VERSION,
                            "development-unsigned",
                        ),
                        MODULE.PUBLICATION_MANIFEST_NAME,
                    },
                )

            with mock.patch.object(
                MODULE,
                "_verify_staged_publication",
                side_effect=inspect_staged_inputs,
            ):
                MODULE.verify_and_prepare_publication(
                    bundle=bundle,
                    output=output,
                    benchmark_suite=benchmark,
                    toolchain_public_key=public_key,
                    app_version=VERSION,
                    toolchain_version=TOOLCHAIN_VERSION,
                    source_repository=REPOSITORY,
                    source_commit=COMMIT,
                    tag=TAG,
                    benchmark_run_id="1234",
                    benchmark_artifact_id="5678",
                    benchmark_artifact_digest="sha256:" + "b" * 64,
                    github_token="read-only-token",
                )

            self.assertEqual(len(staged_paths), 3)
            self.assertTrue(all(not path.exists() for path in staged_paths))
            self.assertEqual(
                (output / MODULE.PUBLICATION_MANIFEST_NAME).read_bytes(),
                b"{}\n",
            )
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)

    def test_publication_transaction_rejects_a_preexisting_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            output.mkdir()

            with self.assertRaisesRegex(
                MODULE.PublicationError,
                "must not exist",
            ):
                with MODULE.transactional_publication_output(
                    output,
                    expected_names={MODULE.PUBLICATION_MANIFEST_NAME},
                    commit_bindings={},
                ):
                    self.fail("a preexisting output must not be reused")

    def test_publication_transaction_does_not_replace_a_raced_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "output"
            real_rename = MODULE.rename_directory_exclusive
            raced = False
            commit_bindings: dict[str, object] = {}

            def create_destination_before_rename(
                parent_descriptor: int,
                source_name: str,
                destination_name: str,
            ) -> None:
                nonlocal raced
                os.mkdir(destination_name, dir_fd=parent_descriptor)
                raced = True
                real_rename(
                    parent_descriptor,
                    source_name,
                    destination_name,
                )

            with mock.patch.object(
                MODULE,
                "rename_directory_exclusive",
                side_effect=create_destination_before_rename,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "appeared|exclusively|transaction",
                ):
                    with MODULE.transactional_publication_output(
                        output,
                        expected_names={MODULE.PUBLICATION_MANIFEST_NAME},
                        commit_bindings=commit_bindings,
                    ) as stage:
                        (stage / MODULE.PUBLICATION_MANIFEST_NAME).write_bytes(
                            b"{}\n"
                        )
                        commit_bindings.update(
                            bind_publication_files(
                                stage,
                                {MODULE.PUBLICATION_MANIFEST_NAME},
                            )
                        )

            self.assertTrue(raced)
            self.assertTrue(output.is_dir())
            self.assertEqual(list(output.iterdir()), [])

    def test_publication_transaction_rejects_manifest_payload_mismatch_before_commit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "output"
            payload_name = "payload.bin"
            original = b"original publication payload"
            replacement = b"mutated publication payload!"
            self.assertEqual(len(original), len(replacement))
            manifest = {
                "files": [
                    {
                        "name": payload_name,
                        "sha256": hashlib.sha256(original).hexdigest(),
                        "size_bytes": len(original),
                    }
                ]
            }
            commit_bindings: dict[str, object] = {}

            with self.assertRaisesRegex(
                MODULE.PublicationError,
                "changed|digest|manifest|payload",
            ):
                with MODULE.transactional_publication_output(
                    output,
                    expected_names={
                        payload_name,
                        MODULE.PUBLICATION_MANIFEST_NAME,
                    },
                    commit_bindings=commit_bindings,
                ) as stage:
                    (stage / payload_name).write_bytes(original)
                    (stage / MODULE.PUBLICATION_MANIFEST_NAME).write_bytes(
                        MODULE.canonical_json_bytes(manifest)
                    )
                    commit_bindings.update(
                        bind_publication_files(
                            stage,
                            {
                                payload_name,
                                MODULE.PUBLICATION_MANIFEST_NAME,
                            },
                        )
                    )
                    (stage / payload_name).write_bytes(replacement)

            self.assertFalse(output.exists())

    def test_publication_transaction_rolls_back_owned_output_after_durability_failure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            parent_identity = output.parent.lstat()
            real_fsync = os.fsync
            commit_bindings: dict[str, object] = {}

            def fail_parent_fsync(descriptor: int) -> None:
                metadata = os.fstat(descriptor)
                if (
                    metadata.st_dev,
                    metadata.st_ino,
                ) == (
                    parent_identity.st_dev,
                    parent_identity.st_ino,
                ):
                    raise OSError(errno.EIO, "forced durability failure")
                real_fsync(descriptor)

            with (
                mock.patch.object(
                    MODULE.os,
                    "fsync",
                    side_effect=fail_parent_fsync,
                ),
                self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "commit|durability|forced",
                ),
            ):
                with MODULE.transactional_publication_output(
                    output,
                    expected_names={MODULE.PUBLICATION_MANIFEST_NAME},
                    commit_bindings=commit_bindings,
                ) as stage:
                    (stage / MODULE.PUBLICATION_MANIFEST_NAME).write_bytes(
                        b"{}\n"
                    )
                    commit_bindings.update(
                        bind_publication_files(
                            stage,
                            {MODULE.PUBLICATION_MANIFEST_NAME},
                        )
                    )

            self.assertFalse(output.exists())

    def test_publication_failure_never_exposes_a_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            output = root / "output"
            benchmark = root / "benchmark.json"
            public_key = root / "public-key.txt"
            write_build_payload(bundle)
            write_build_closure(bundle)
            benchmark.write_bytes(b"benchmark\n")
            public_key.write_bytes(b"public-key\n")

            def fail_after_payload_copy(**arguments: object) -> None:
                staged_output = arguments["output"]
                assert isinstance(staged_output, Path)
                staged_output.mkdir(exist_ok=True)
                (staged_output / "partial-publication.bin").write_bytes(b"partial")
                raise MODULE.PublicationError("manifest creation failed")

            with mock.patch.object(
                MODULE,
                "_verify_staged_publication",
                side_effect=fail_after_payload_copy,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "manifest creation failed",
                ):
                    MODULE.verify_and_prepare_publication(
                        bundle=bundle,
                        output=output,
                        benchmark_suite=benchmark,
                        toolchain_public_key=public_key,
                        app_version=VERSION,
                        toolchain_version=TOOLCHAIN_VERSION,
                        source_repository=REPOSITORY,
                        source_commit=COMMIT,
                        tag=TAG,
                        benchmark_run_id="1234",
                        benchmark_artifact_id="5678",
                        benchmark_artifact_digest="sha256:" + "b" * 64,
                        github_token="read-only-token",
                    )

            self.assertFalse(output.exists())

    def test_publication_copy_rejects_staged_generation_mismatch(self) -> None:
        original = b"acquired publication bytes"
        replacement = b"mutated publication bytes!"
        self.assertEqual(len(original), len(replacement))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "artifact.bin"
            output = root / "output"
            source.write_bytes(original)
            expected = MODULE.snapshot_bounded_regular_file(
                source,
                "staged artifact",
                limit=1_024,
                capture_bytes=False,
            )
            source.write_bytes(replacement)

            with self.assertRaisesRegex(
                MODULE.PublicationError,
                "changed after acquisition",
            ):
                MODULE.copy_staged_publication_payload(
                    sources={"artifact.bin": source},
                    expected={"artifact.bin": expected},
                    output=output,
                    limits={"artifact.bin": 1_024},
                )

            self.assertTrue(output.is_dir())
            self.assertFalse((output / "artifact.bin").exists())
            self.assertTrue(
                all(
                    entry.name.startswith(".artifact.bin.abandoned-")
                    for entry in output.iterdir()
                )
            )

    def test_publication_copy_records_the_acquired_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = {
                "a.bin": root / "a.bin",
                "b.bin": root / "b.bin",
            }
            sources["a.bin"].write_bytes(b"a")
            sources["b.bin"].write_bytes(b"second")
            limits = {name: 1_024 for name in sources}
            expected = {
                name: MODULE.snapshot_bounded_regular_file(
                    path,
                    f"staged {name}",
                    limit=limits[name],
                    capture_bytes=False,
                )
                for name, path in sources.items()
            }
            output = root / "output"

            payload = MODULE.copy_staged_publication_payload(
                sources=sources,
                expected=expected,
                output=output,
                limits=limits,
            )

            self.assertEqual(
                payload.records,
                [
                    {
                        "name": name,
                        "sha256": expected[name].sha256,
                        "size_bytes": expected[name].size_bytes,
                    }
                    for name in sorted(expected)
                ],
            )
            self.assertEqual(set(payload.bindings), set(expected))
            for name, path in sources.items():
                self.assertEqual((output / name).read_bytes(), path.read_bytes())

    def test_publication_copy_rollback_never_deletes_a_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = {
                "a.bin": root / "a.bin",
                "b.bin": root / "b.bin",
            }
            sources["a.bin"].write_bytes(b"first")
            sources["b.bin"].write_bytes(b"second")
            limits = {name: 1_024 for name in sources}
            expected = {
                name: MODULE.snapshot_bounded_regular_file(
                    path,
                    f"staged {name}",
                    limit=limits[name],
                    capture_bytes=False,
                )
                for name, path in sources.items()
            }
            expected["b.bin"] = MODULE.BoundedRegularFileSnapshot(
                data=None,
                sha256="0" * 64,
                size_bytes=expected["b.bin"].size_bytes,
            )
            output = root / "output"
            moved = root / "owned-a.bin"
            replacement = b"replacement owned by another process"
            real_copy = MODULE.copy_bounded_regular_file_with_identity
            replaced = False

            def replace_first_destination(
                source: Path | str,
                destination: Path,
                label: str,
                **kwargs: object,
            ) -> MODULE.BoundedRegularFileCopy:
                nonlocal replaced
                snapshot = real_copy(source, destination, label, **kwargs)
                if destination.name == "a.bin" and not replaced:
                    destination.rename(moved)
                    destination.write_bytes(replacement)
                    replaced = True
                return snapshot

            with mock.patch.object(
                MODULE,
                "copy_bounded_regular_file_with_identity",
                side_effect=replace_first_destination,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "changed after acquisition",
                ):
                    MODULE.copy_staged_publication_payload(
                        sources=sources,
                        expected=expected,
                        output=output,
                        limits=limits,
                    )

            self.assertTrue(replaced)
            self.assertEqual((output / "a.bin").read_bytes(), replacement)
            self.assertEqual(moved.read_bytes(), b"first")

    def test_regular_file_cleanup_cannot_delete_a_replacement_raced_after_identity_check(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "owned.bin"
            moved = root / "opened-owned.bin"
            replacement_source = root / "replacement.bin"
            destination.write_bytes(b"owned bytes")
            replacement_source.write_bytes(b"replacement bytes")
            owned_identity = MODULE.bounded_regular_file_identity(
                destination.lstat()
            )
            real_unlink = Path.unlink
            raced = False

            def replace_before_unlink(
                path: Path,
                *args: object,
                **kwargs: object,
            ) -> None:
                nonlocal raced
                if path == destination and not raced:
                    destination.rename(moved)
                    replacement_source.rename(destination)
                    raced = True
                real_unlink(path, *args, **kwargs)

            with mock.patch.object(Path, "unlink", new=replace_before_unlink):
                MODULE.remove_owned_regular_file(destination, owned_identity)

            surviving_replacement = (
                destination.exists()
                and destination.read_bytes() == b"replacement bytes"
            ) or (
                replacement_source.exists()
                and replacement_source.read_bytes() == b"replacement bytes"
            )
            self.assertTrue(surviving_replacement)

    def test_transaction_cleanup_cannot_delete_a_replacement_raced_after_identity_check(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "output"
            replacement_source = root / "replacement-stage"
            replacement_source.mkdir()
            (replacement_source / "keep.txt").write_text(
                "replacement data",
                encoding="utf-8",
            )
            moved_stage = root / "opened-stage"
            real_rmtree = shutil.rmtree
            raced = False

            def replace_before_rmtree(
                path: Path | str,
                *args: object,
                **kwargs: object,
            ) -> None:
                nonlocal raced
                candidate = Path(path)
                if not raced:
                    candidate.rename(moved_stage)
                    replacement_source.rename(candidate)
                    raced = True
                real_rmtree(candidate, *args, **kwargs)

            with mock.patch.object(
                MODULE.shutil,
                "rmtree",
                side_effect=replace_before_rmtree,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "forced transaction failure",
                ):
                    with MODULE.transactional_publication_output(
                        output,
                        expected_names={MODULE.PUBLICATION_MANIFEST_NAME},
                        commit_bindings={},
                    ) as stage:
                        (stage / MODULE.PUBLICATION_MANIFEST_NAME).write_bytes(
                            b"{}\n"
                        )
                        raise MODULE.PublicationError(
                            "forced transaction failure"
                        )

            surviving_replacement = (
                replacement_source / "keep.txt"
            ).is_file() or any(
                path.name == "keep.txt" and path.read_text(encoding="utf-8") == "replacement data"
                for path in root.rglob("keep.txt")
            )
            self.assertTrue(surviving_replacement)

    def test_zip_validator_rejects_archive_path_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "fixture.zip"
            moved = root / "opened-fixture.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("required", b"original")

            real_infolist = MODULE.zipfile.ZipFile.infolist
            swapped = False

            def swap_during_inspection(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
                nonlocal swapped
                entries = real_infolist(archive)
                if not swapped:
                    archive_path.rename(moved)
                    with zipfile.ZipFile(archive_path, "w") as replacement:
                        replacement.writestr("required", b"mutation")
                    swapped = True
                return entries

            with mock.patch.object(
                MODULE.zipfile.ZipFile,
                "infolist",
                new=swap_during_inspection,
            ):
                with self.assertRaisesRegex(MODULE.PublicationError, "changed"):
                    MODULE.validate_zip(
                        archive_path,
                        label="fixture archive",
                        allowed_prefixes=("required",),
                        required_files={"required"},
                    )

            self.assertTrue(swapped)

    def test_zip_validator_caps_entry_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "fixture.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("one", b"1")
                archive.writestr("two", b"2")

            with mock.patch.object(
                MODULE.zipfile,
                "ZipFile",
                side_effect=AssertionError(
                    "over-count ZIP reached the parser"
                ),
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "entry count",
                ):
                    MODULE.validate_zip(
                        archive_path,
                        label="bounded ZIP",
                        allowed_prefixes=("",),
                        required_files={"one"},
                        maximum_entries=1,
                    )

    def test_partial_hdiutil_attach_is_cleaned_up(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dmg = Path(temporary) / "fixture.dmg"
            dmg.write_bytes(b"dmg")
            commands: list[list[str]] = []

            def partial_attach(arguments: list[str]) -> mock.Mock:
                commands.append(arguments)
                if "attach" in arguments:
                    raise MODULE.PublicationError(
                        "attach reported failure\n"
                        "/dev/disk42          GUID_partition_scheme"
                    )
                if "detach" in arguments and not arguments[-1].startswith(
                    "/dev/disk"
                ):
                    raise MODULE.PublicationError(
                        "partial attachment has no mounted path"
                    )
                return mock.Mock(stdout="", stderr="", returncode=0)

            with mock.patch.object(
                MODULE,
                "run_static",
                side_effect=partial_attach,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "attach reported failure",
                ):
                    with MODULE.mounted_dmg(dmg):
                        self.fail("a failed attach must not yield a mount")

            self.assertTrue(
                any(
                    "detach" in command and "/dev/disk42" in command
                    for command in commands
                )
            )

    def test_partial_hdiutil_attach_prefers_the_whole_disk_device(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dmg = Path(temporary) / "fixture.dmg"
            dmg.write_bytes(b"dmg")
            commands: list[list[str]] = []

            def partial_attach(arguments: list[str]) -> mock.Mock:
                commands.append(arguments)
                if "attach" in arguments:
                    raise MODULE.PublicationError(
                        "attach reported failure\n"
                        "/dev/disk44          GUID_partition_scheme\n"
                        "/dev/disk44s1        Apple_APFS"
                    )
                if "detach" in arguments and arguments[-1].startswith(
                    "/dev/disk"
                ):
                    return mock.Mock(stdout="", stderr="", returncode=0)
                if "detach" in arguments:
                    raise MODULE.PublicationError(
                        "partial attachment has no mounted path"
                    )
                return mock.Mock(stdout="", stderr="", returncode=0)

            with mock.patch.object(
                MODULE,
                "run_static",
                side_effect=partial_attach,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "attach reported failure",
                ):
                    with MODULE.mounted_dmg(dmg):
                        self.fail("a failed attach must not yield a mount")

            device_detaches = [
                command[-1]
                for command in commands
                if "detach" in command and command[-1].startswith("/dev/disk")
            ]
            self.assertEqual(device_detaches, ["/dev/disk44"])

    def test_timed_out_hdiutil_attach_detaches_the_reported_device(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dmg = Path(temporary) / "fixture.dmg"
            dmg.write_bytes(b"dmg")
            commands: list[list[str]] = []

            def timed_out_attach(
                arguments: list[str],
                **_kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                commands.append(arguments)
                if "attach" in arguments:
                    raise subprocess.TimeoutExpired(
                        arguments,
                        120,
                        output=(
                            "/dev/disk43          GUID_partition_scheme\n"
                        ),
                        stderr="attach timed out",
                    )
                if "detach" in arguments and not arguments[-1].startswith(
                    "/dev/disk"
                ):
                    raise subprocess.CalledProcessError(
                        1,
                        arguments,
                        output="",
                        stderr="mount point is absent",
                    )
                return subprocess.CompletedProcess(
                    arguments,
                    0,
                    stdout="",
                    stderr="",
                )

            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=timed_out_attach,
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "timed out|timeout",
                ):
                    with MODULE.mounted_dmg(dmg):
                        self.fail("a timed-out attach must not yield a mount")

            self.assertTrue(
                any(
                    "detach" in command and "/dev/disk43" in command
                    for command in commands
                )
            )

    def test_production_uses_official_dmg_names_and_requires_all_receipts(self) -> None:
        limits = MODULE.build_file_limits(VERSION, "production")

        self.assertIn(f"EasySplat-{VERSION}.dmg", limits)
        self.assertIn(f"EasySplat-{VERSION}.dmg.sha256", limits)
        self.assertNotIn(f"EasySplat-{VERSION}-unsigned.dmg", limits)
        for suffix in (
            ".app-signing.json",
            ".app-notarization.json",
            ".dmg-signing.json",
            ".dmg-notarization.json",
        ):
            self.assertIn(f"EasySplat-{VERSION}{suffix}", limits)
        public = MODULE.publication_payload_names(VERSION, "production")
        self.assertIn(f"EasySplat-{VERSION}.dmg", public)
        self.assertFalse(any("unsigned" in name for name in public))

    def test_manifest_loader_accepts_eight_mib_and_rejects_one_byte_more(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            limit = 8 * 1_024 * 1_024
            exact = root / "manifest-exact.json"
            exact.write_bytes(b"{}" + b" " * (limit - 2))

            self.assertEqual(
                MODULE.load_json(exact, "toolchain manifest", limit=limit), {}
            )

            oversized = root / "manifest-oversized.json"
            oversized.write_bytes(b"{}" + b" " * (limit - 1))
            with self.assertRaisesRegex(MODULE.PublicationError, "size limit"):
                MODULE.load_json(oversized, "toolchain manifest", limit=limit)

    def test_canonical_request_loader_accepts_eight_mib_and_rejects_one_byte_more(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            limit = 8 * 1_024 * 1_024
            prefix = b'{"padding":"'
            suffix = b'"}'
            exact = root / "request-exact.json"
            exact.write_bytes(prefix + b"x" * (limit - len(prefix) - len(suffix)) + suffix)

            payload = MODULE.load_compact_canonical_json(
                exact, "toolchain release request", limit=limit
            )
            self.assertEqual(len(payload["padding"]), limit - len(prefix) - len(suffix))

            oversized = root / "request-oversized.json"
            oversized.write_bytes(
                prefix + b"x" * (limit + 1 - len(prefix) - len(suffix)) + suffix
            )
            with self.assertRaisesRegex(MODULE.PublicationError, "size limit"):
                MODULE.load_compact_canonical_json(
                    oversized, "toolchain release request", limit=limit
                )

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

            self.assertEqual(closure["release_mode"], "development-unsigned")
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
    def test_embedded_toolchain_receipts_have_distinct_bounded_sizes(self) -> None:
        cases = (
            (
                "Toolchain/supply-chain/components.json",
                16 * 1_024 * 1_024,
                "toolchain component closure",
            ),
            ("toolchain-closure.json", 1 * 1_024 * 1_024, "archive closure"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index, (entry_name, limit, expected_error) in enumerate(cases):
                with self.subTest(entry=entry_name):
                    fixture = supply_chain_fixture(root / str(index))
                    replace_zip_entry(
                        fixture["archive_path"], entry_name, b"x" * (limit + 1)
                    )
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, expected_error
                    ):
                        MODULE.validate_license_archive(
                            fixture["archive_path"],
                            fixture["provenance"],
                            fixture["manifest"],
                            toolchain_version=TOOLCHAIN_VERSION,
                        )

    def test_production_toolchain_license_closure_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = production_supply_chain_fixture(Path(temporary))

            closure = MODULE.validate_license_archive(
                fixture["archive_path"],
                fixture["provenance"],
                fixture["manifest"],
                toolchain_version=TOOLCHAIN_VERSION,
            )

            self.assertEqual(len(closure["components"]["components"]), 63)
            core = next(
                row
                for row in closure["archives"]["embedded"]
                if row["id"] == "core"
            )
            self.assertIn(
                "bin/colmap",
                {row["path"] for row in core["entries"]},
            )

    def test_license_archive_rejects_forged_public_legal_files(self) -> None:
        for index, entry in enumerate(
            (
                "EasySplat/LICENSE",
                "EasySplat/NOTICE.md",
                "MetalSplatter/LICENSE",
            )
        ):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as temporary:
                fixture = supply_chain_fixture(Path(temporary) / str(index))
                replace_zip_entry(
                    fixture["archive_path"],
                    entry,
                    b"forged legal text\n",
                )

                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "public legal|trusted source|legal file",
                ):
                    MODULE.validate_license_archive(
                        fixture["archive_path"],
                        fixture["provenance"],
                        fixture["manifest"],
                        toolchain_version=TOOLCHAIN_VERSION,
                    )

    def test_license_archive_rejects_unbound_files_and_wrapping_bytes(self) -> None:
        attacks = (
            "extra",
            "closure-suffix",
            "prefix",
            "suffix",
            "comment",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for attack in attacks:
                with self.subTest(attack=attack):
                    fixture = supply_chain_fixture(root / attack)
                    archive_path = fixture["archive_path"]
                    if attack == "extra":
                        with zipfile.ZipFile(archive_path, "a") as archive:
                            archive.writestr("EasySplat/extra.txt", b"unbound\n")
                    elif attack == "closure-suffix":
                        with zipfile.ZipFile(archive_path, "a") as archive:
                            archive.writestr(
                                "toolchain-closure.json.evil",
                                b"unbound\n",
                            )
                    elif attack == "prefix":
                        archive_path.write_bytes(
                            b"unbound-prefix" + archive_path.read_bytes()
                        )
                    elif attack == "suffix":
                        archive_path.write_bytes(
                            archive_path.read_bytes() + b"unbound-suffix"
                        )
                    else:
                        with zipfile.ZipFile(archive_path, "a") as archive:
                            archive.comment = b"unbound-comment"

                    with self.assertRaisesRegex(
                        MODULE.PublicationError,
                        "exact|structure|unbound|unallowlisted|trailing|prefix",
                    ):
                        MODULE.validate_license_archive(
                            archive_path,
                            fixture["provenance"],
                            fixture["manifest"],
                            toolchain_version=TOOLCHAIN_VERSION,
                        )

    def test_license_archive_never_reopens_validated_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = supply_chain_fixture(Path(temporary))
            real_zip_file = MODULE.zipfile.ZipFile

            def descriptor_only_zip(source: object, *args: object, **kwargs: object):
                if isinstance(source, (str, os.PathLike)):
                    raise AssertionError("license archive was reopened by path")
                return real_zip_file(source, *args, **kwargs)

            with mock.patch.object(
                MODULE.zipfile,
                "ZipFile",
                side_effect=descriptor_only_zip,
            ):
                closure = MODULE.validate_license_archive(
                    fixture["archive_path"],
                    fixture["provenance"],
                    fixture["manifest"],
                    toolchain_version=TOOLCHAIN_VERSION,
                )

            self.assertEqual(closure["components"], fixture["components"])

    def test_model_source_artifacts_are_strictly_validated(self) -> None:
        expected_errors = {
            "extra-field": "exact keys",
            "missing": "sourceArtifacts are missing",
            "duplicate": "sourceArtifacts",
            "credentials": "credential-free HTTPS",
            "query-credentials": "credential-free HTTPS",
            "digest": "sourceArtifacts",
            "size": "sourceArtifacts",
            "name": "sourceArtifacts",
            "control-name": "sourceArtifacts",
            "binding-digest": "model payload",
            "binding-size": "model payload",
            "missing-binding": "model payload",
            "extra-binding": "model payload",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for tamper, expected_error in expected_errors.items():
                with self.subTest(tamper=tamper):
                    fixture = production_supply_chain_fixture(
                        root / tamper,
                        source_artifact_tamper=tamper,
                    )
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, expected_error
                    ):
                        MODULE.validate_license_archive(
                            fixture["archive_path"],
                            fixture["provenance"],
                            fixture["manifest"],
                            toolchain_version=TOOLCHAIN_VERSION,
                        )

    def test_archive_classifier_matches_the_packaging_contract(self) -> None:
        expected = {
            "bin/colmap": "core",
            "lib/libomp.dylib": "core",
            "licenses/EasySplat/LICENSE": "core",
            "provenance/colmap.json": "core",
            "supply-chain/components.json": "core",
            "msplat/build_info.json": "core",
            "msplat/LICENSE": "core",
            "da3_mps/bin/easysplat_da3_sfm": "geometry-da3-base",
            "da3_mps/python/bin/python3": "geometry-da3-base",
            "da3_mps/app/easysplat_da3_sfm/run.py": "geometry-da3-base",
            "da3_mps/vendor/depth-anything-3/LICENSE": "geometry-da3-base",
            "da3_mps/licenses/python-packages-requirements.txt": (
                "geometry-da3-base"
            ),
            "da3_mps/build_info.json": "geometry-da3-base",
            "da3_mps/models/DA3-BASE/model.safetensors": "geometry-da3-base",
            "da3_mps/models/DA3-SMALL/model.safetensors": "geometry-da3-small",
        }
        for path, archive_id in expected.items():
            with self.subTest(path=path):
                self.assertEqual(
                    MODULE.supply_chain_archive_for_path(path), archive_id
                )
        with self.assertRaisesRegex(
            MODULE.PublicationError, "no unique production archive"
        ):
            MODULE.supply_chain_archive_for_path("unexpected/payload.bin")

    def test_archive_closure_rejects_missing_and_colliding_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for mutation in ("missing", "collision"):
                with self.subTest(mutation=mutation):
                    fixture = production_supply_chain_fixture(root / mutation)
                    closure = fixture["closure"]
                    (core,) = closure["embedded"]
                    runtime = next(
                        row for row in core["entries"] if row["path"] == "bin/colmap"
                    )
                    if mutation == "missing":
                        core["entries"].remove(runtime)
                    else:
                        core["entries"].append(dict(runtime))
                    replace_zip_entry(
                        fixture["archive_path"],
                        "toolchain-closure.json",
                        MODULE.canonical_json_bytes(closure),
                    )
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, "archive closure differs"
                    ):
                        MODULE.validate_license_archive(
                            fixture["archive_path"],
                            fixture["provenance"],
                            fixture["manifest"],
                            toolchain_version=TOOLCHAIN_VERSION,
                        )

    def test_da3_runtime_cannot_be_claimed_by_the_core_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = production_supply_chain_fixture(
                Path(temporary), put_da3_runtime_in_core=True
            )

            with self.assertRaisesRegex(
                MODULE.PublicationError, "archive closure differs for core"
            ):
                MODULE.validate_license_archive(
                    fixture["archive_path"],
                    fixture["provenance"],
                    fixture["manifest"],
                    toolchain_version=TOOLCHAIN_VERSION,
                )

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

    def test_release_timestamps_are_strict_utc_and_ordered(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = supply_chain_fixture(Path(temporary))
            for invalid in (
                "2026-07-15Z",
                "2026-13-15T12:00:00Z",
                "2026-07-15T12:00:00+00:00",
                "2026-07-15T12:00:00.123Z",
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
            MODULE.validate_release_timestamps(
                {"createdAt": "2026-07-15T12:00:01Z"},
                {"publishedAt": "2026-07-15T12:00:00Z"},
            )
            with self.assertRaisesRegex(MODULE.PublicationError, "predates"):
                MODULE.validate_release_timestamps(
                    {"createdAt": "2026-07-15T12:00:00Z"},
                    {"publishedAt": "2026-07-15T12:00:01Z"},
                )

    def test_release_metadata_creation_time_is_truncated_to_whole_seconds(self) -> None:
        created_at = GENERATOR.release_created_at(
            now=GENERATOR.datetime(
                2026,
                7,
                15,
                12,
                0,
                1,
                987_654,
                tzinfo=GENERATOR.timezone.utc,
            ),
        )
        self.assertEqual(created_at, "2026-07-15T12:00:01Z")

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

    def test_publication_identity_rejects_semver_build_metadata(self) -> None:
        identity = {
            "app_version": VERSION,
            "toolchain_version": TOOLCHAIN_VERSION,
            "source_repository": REPOSITORY,
            "source_commit": COMMIT,
            "tag": TAG,
            "benchmark_run_id": "1234",
            "benchmark_artifact_id": "5678",
            "benchmark_artifact_digest": "sha256:" + "b" * 64,
            "release_mode": "production",
        }
        for field, value in (
            ("app_version", f"{VERSION}+builder.1"),
            ("toolchain_version", f"{TOOLCHAIN_VERSION}+builder.1"),
        ):
            with self.subTest(field=field):
                candidate = dict(identity)
                candidate[field] = value
                if field == "app_version":
                    candidate["tag"] = f"v{value}"
                with self.assertRaisesRegex(
                    MODULE.PublicationError, "build metadata"
                ):
                    MODULE.validate_identity(**candidate)

    def test_production_identity_rejects_prerelease_versions(self) -> None:
        identity = {
            "app_version": VERSION,
            "toolchain_version": TOOLCHAIN_VERSION,
            "source_repository": REPOSITORY,
            "source_commit": COMMIT,
            "tag": TAG,
            "benchmark_run_id": None,
            "benchmark_artifact_id": None,
            "benchmark_artifact_digest": None,
            "release_mode": "production",
        }
        for field in ("app_version", "toolchain_version"):
            with self.subTest(field=field):
                candidate = dict(identity)
                candidate[field] = f"{candidate[field]}-rc.1"
                if field == "app_version":
                    candidate["tag"] = f"v{candidate[field]}"
                with self.assertRaisesRegex(
                    MODULE.PublicationError, "must be stable"
                ):
                    MODULE.validate_identity(**candidate)

    def test_metadata_generation_rejects_semver_build_metadata(self) -> None:
        with self.assertRaisesRegex(GENERATOR.MetadataError, "build metadata"):
            GENERATOR.release_asset_url(
                f"https://github.com/{REPOSITORY}",
                f"{VERSION}+builder.1",
                f"EasySplat-{VERSION}+builder.1-unsigned.dmg",
            )
        with self.assertRaisesRegex(GENERATOR.MetadataError, "build metadata"):
            GENERATOR.validate_toolchain_tree(
                Path("/nonexistent"), f"{TOOLCHAIN_VERSION}+builder.1"
            )

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
            "releaseMode": "development-unsigned",
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
            "releaseMode": "development-unsigned",
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

    def test_provenance_requires_the_exact_app_release_url(self) -> None:
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
                "releaseMode": "development-unsigned",
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
            app, public_key = write_app_fixture(Path(temporary))

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
                    validate_app_fixture(app, public_key)

    def test_app_bundle_requires_every_bundled_helper_and_payload(self) -> None:
        for relative in (*APP_BUNDLED_HELPERS, *APP_BUNDLED_PAYLOAD):
            with (
                self.subTest(resource=relative),
                tempfile.TemporaryDirectory() as temporary,
            ):
                app, public_key = write_app_fixture(Path(temporary))
                (app / relative).unlink()
                with (
                    mock.patch.object(
                        MODULE,
                        "load_plist",
                        return_value=dict(MODULE.expected_app_plist(VERSION)),
                    ),
                    mock.patch.object(
                        MODULE, "run_static", side_effect=valid_app_static_result
                    ),
                ):
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, "bundled (helper|toolchain payload)"
                    ):
                        validate_app_fixture(app, public_key)

    def test_app_bundle_rejects_a_non_executable_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app, public_key = write_app_fixture(Path(temporary))
            (app / APP_BUNDLED_HELPERS[0]).chmod(0o644)
            with (
                mock.patch.object(
                    MODULE,
                    "load_plist",
                    return_value=dict(MODULE.expected_app_plist(VERSION)),
                ),
                mock.patch.object(
                    MODULE, "run_static", side_effect=valid_app_static_result
                ),
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError, "bundled helper has an unsafe mode"
                ):
                    validate_app_fixture(app, public_key)

    def test_app_bundle_rejects_a_retained_download_resource(self) -> None:
        for relative in (
            "Contents/Resources/public_key_ed25519.txt",
            "Contents/Resources/EasySplat_EasySplatApp.bundle/toolchain_manifest_url.txt",
        ):
            with (
                self.subTest(resource=relative),
                tempfile.TemporaryDirectory() as temporary,
            ):
                app, public_key = write_app_fixture(Path(temporary))
                stale = app / relative
                stale.parent.mkdir(parents=True, exist_ok=True)
                stale.write_bytes(PUBLIC_KEY_BYTES)
                with (
                    mock.patch.object(
                        MODULE,
                        "load_plist",
                        return_value=dict(MODULE.expected_app_plist(VERSION)),
                    ),
                    mock.patch.object(
                        MODULE, "run_static", side_effect=valid_app_static_result
                    ),
                ):
                    with self.assertRaisesRegex(
                        MODULE.PublicationError, "download-era toolchain resource"
                    ):
                        validate_app_fixture(app, public_key)

    def test_app_bundle_rejects_a_retained_bootstrap_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app, public_key = write_app_fixture(Path(temporary))
            (app / "Contents/Resources/ToolchainBootstrap").mkdir(parents=True)
            with (
                mock.patch.object(
                    MODULE,
                    "load_plist",
                    return_value=dict(MODULE.expected_app_plist(VERSION)),
                ),
                mock.patch.object(
                    MODULE, "run_static", side_effect=valid_app_static_result
                ),
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError, "toolchain bootstrap directory"
                ):
                    validate_app_fixture(app, public_key)

    def test_app_bundle_rejects_a_symlinked_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, public_key = write_app_fixture(root)
            helper = app / APP_BUNDLED_HELPERS[0]
            helper.unlink()
            helper.symlink_to(public_key)
            with self.assertRaisesRegex(MODULE.PublicationError, "symbolic link"):
                validate_app_fixture(app, public_key)

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

    def test_app_tree_validation_caps_entry_count_before_materializing_tree(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "EasySplat.app"
            root.mkdir()
            for index in range(3):
                (root / f"entry-{index}").write_bytes(b"x")

            with self.assertRaisesRegex(
                MODULE.PublicationError,
                "entry count",
            ):
                MODULE.validate_regular_tree(
                    root,
                    maximum_bytes=1_024,
                    maximum_entries=2,
                )

    def test_dsym_uuid_must_match_app_uuid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "symbols.zip"
            write_dsym_fixture(archive_path)
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

    def test_dsym_archive_never_reopens_validated_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "symbols.zip"
            write_dsym_fixture(archive_path)
            app_binary = root / "EasySplatApp"
            app_binary.write_bytes(b"app")
            real_zip_file = MODULE.zipfile.ZipFile

            def descriptor_only_zip(source: object, *args: object, **kwargs: object):
                if isinstance(source, (str, os.PathLike)):
                    raise AssertionError("dSYM archive was reopened by path")
                return real_zip_file(source, *args, **kwargs)

            with (
                mock.patch.object(
                    MODULE.zipfile,
                    "ZipFile",
                    side_effect=descriptor_only_zip,
                ),
                mock.patch.object(
                    MODULE,
                    "run_static",
                    return_value=mock.Mock(
                        stdout=(
                            "UUID: 11111111-1111-1111-1111-111111111111 "
                            "(arm64) binary\n"
                        ),
                        stderr="",
                        returncode=0,
                    ),
                ),
                mock.patch.object(MODULE, "plist_value", return_value="dSYM"),
            ):
                MODULE.validate_dsym_archive(archive_path, app_binary)

    def test_dsym_archive_rejects_unbound_files_and_wrapping_bytes(self) -> None:
        attacks = ("extra", "prefix", "suffix")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for attack in attacks:
                with self.subTest(attack=attack):
                    case = root / attack
                    case.mkdir()
                    archive_path = case / "symbols.zip"
                    write_dsym_fixture(
                        archive_path,
                        include_extra=attack == "extra",
                    )
                    if attack == "prefix":
                        archive_path.write_bytes(
                            b"unbound-prefix" + archive_path.read_bytes()
                        )
                    elif attack == "suffix":
                        archive_path.write_bytes(
                            archive_path.read_bytes() + b"unbound-suffix"
                        )
                    app_binary = case / "EasySplatApp"
                    app_binary.write_bytes(b"app")

                    with (
                        mock.patch.object(
                            MODULE,
                            "run_static",
                            return_value=mock.Mock(
                                stdout=(
                                    "UUID: 11111111-1111-1111-1111-111111111111 "
                                    "(arm64) binary\n"
                                ),
                                stderr="",
                                returncode=0,
                            ),
                        ),
                        mock.patch.object(
                            MODULE,
                            "plist_value",
                            return_value="dSYM",
                        ),
                    ):
                        with self.assertRaisesRegex(
                            MODULE.PublicationError,
                            "exact|structure|unbound|trailing|prefix",
                        ):
                            MODULE.validate_dsym_archive(
                                archive_path,
                                app_binary,
                            )


class BenchmarkSuiteTests(unittest.TestCase):
    def _write_suite(self, path: Path, *, raw_retention: str = "excluded") -> None:
        payload = {
            "schema_version": 2,
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


class SignedArtifactEvidenceTests(unittest.TestCase):
    def test_validated_receipts_are_rebound_to_their_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "EasySplat.app"
            artifact.mkdir()
            fingerprint = "A" * 40
            team_id = "AB12CD34EF"
            final_artifact_sha256 = "2" * 64
            signing = {
                "identityFingerprintSHA1": fingerprint,
                "teamID": team_id,
            }
            notarization = {"postStapleSHA256": final_artifact_sha256}
            signing_path = root / "app-signing.json"
            notarization_path = root / "app-notarization.json"
            signing_path.write_bytes(MODULE.canonical_json_bytes(signing))
            notarization_path.write_bytes(MODULE.canonical_json_bytes(notarization))
            with (
                mock.patch.object(
                    MODULE.SIGNING_HELPER,
                    "validate_signing_receipt",
                    return_value=signing,
                ),
                mock.patch.object(
                    MODULE.NOTARY_HELPER,
                    "validate_notarization_receipt",
                    return_value=notarization,
                ),
            ):
                evidence = MODULE.validate_signed_artifact_evidence(
                    artifact,
                    artifact_type="app",
                    signing_receipt=signing_path,
                    notarization_receipt=notarization_path,
                )

            self.assertEqual(
                evidence,
                {
                    "identity_fingerprint_sha1": fingerprint,
                    "team_id": team_id,
                    "signing_receipt_sha256": MODULE.sha256_file(signing_path),
                    "notarization_receipt_sha256": MODULE.sha256_file(
                        notarization_path
                    ),
                    "post_staple_sha256": final_artifact_sha256,
                },
            )


class ReleaseNotesTests(unittest.TestCase):
    def test_production_release_notes_accept_the_exact_stable_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            notes = Path(temporary) / "release-notes.txt"
            notes.write_bytes(PRODUCTION_RELEASE_NOTES)

            MODULE.validate_release_notes(
                notes,
                app_version=VERSION,
                release_mode="production",
            )

    def test_production_release_notes_reject_one_byte_of_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            notes = Path(temporary) / "release-notes.txt"
            notes.write_bytes(
                PRODUCTION_RELEASE_NOTES.replace(b"static", b"Static", 1)
            )

            with self.assertRaisesRegex(
                MODULE.PublicationError,
                "release notes do not exactly describe the production",
            ):
                MODULE.validate_release_notes(
                    notes,
                    app_version=VERSION,
                    release_mode="production",
                )


class SignedBuildPublicationTests(unittest.TestCase):
    def test_signed_manifest_binds_the_producing_artifact_and_workflow(self) -> None:
        signed_build = {
            "artifact_id": "1234567",
            "artifact_digest": "sha256:" + "9" * 64,
            "workflow_run_id": "24681012",
            "workflow_run_attempt": "2",
            "source_commit": COMMIT,
        }
        manifest = MODULE.build_publication_manifest_payload(
            app_version=VERSION,
            toolchain_version=TOOLCHAIN_VERSION,
            source_repository=REPOSITORY,
            source_commit=COMMIT,
            tag=TAG,
            release_mode="production",
            benchmark_run_id="1234",
            benchmark_artifact_id="5678",
            benchmark_artifact_digest="sha256:" + "b" * 64,
            benchmark_suite_sha256="c" * 64,
            files=[],
            signed_build=signed_build,
        )
        self.assertEqual(manifest["signed_build"], signed_build)

    def test_unsigned_manifest_rejects_a_signed_build_record(self) -> None:
        with self.assertRaisesRegex(MODULE.PublicationError, "development-unsigned"):
            MODULE.build_publication_manifest_payload(
                app_version=VERSION,
                toolchain_version=TOOLCHAIN_VERSION,
                source_repository=REPOSITORY,
                source_commit=COMMIT,
                tag=TAG,
                release_mode="development-unsigned",
                benchmark_run_id="1234",
                benchmark_artifact_id="5678",
                benchmark_artifact_digest="sha256:" + "b" * 64,
                benchmark_suite_sha256="c" * 64,
                files=[],
                signed_build={
                    "artifact_id": "1234567",
                    "artifact_digest": "sha256:" + "9" * 64,
                    "workflow_run_id": "24681012",
                    "workflow_run_attempt": "2",
                    "source_commit": COMMIT,
                },
            )

    def test_verify_build_parser_preserves_signed_build_identity(self) -> None:
        arguments = MODULE.parser().parse_args(
            [
                "verify-build",
                "--release-mode",
                "production",
                "--bundle",
                "/tmp/bundle",
                "--output",
                "/tmp/output",
                "--benchmark-suite",
                "/tmp/benchmark.json",
                "--toolchain-public-key",
                "/tmp/public-key.txt",
                "--app-version",
                VERSION,
                "--toolchain-version",
                TOOLCHAIN_VERSION,
                "--source-repository",
                REPOSITORY,
                "--source-commit",
                COMMIT,
                "--tag",
                TAG,
                "--benchmark-run-id",
                "1234",
                "--benchmark-artifact-id",
                "5678",
                "--benchmark-artifact-digest",
                "sha256:" + "b" * 64,
                "--signed-artifact-id",
                "1234567",
                "--signed-artifact-digest",
                "sha256:" + "9" * 64,
                "--workflow-run-id",
                "24681012",
                "--workflow-run-attempt",
                "2",
            ]
        )
        self.assertEqual(arguments.signed_artifact_id, "1234567")
        self.assertEqual(arguments.signed_artifact_digest, "sha256:" + "9" * 64)
        self.assertEqual(arguments.workflow_run_id, "24681012")
        self.assertEqual(arguments.workflow_run_attempt, "2")


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

    def test_authority_closure_hashes_the_admitted_request_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = authority_fixture(root)
            request_path = fixture["request_path"]
            moved = root / "opened-request.json"
            replacement_request = dict(fixture["request"])
            replacement_request["sourceCommit"] = "c" * 40
            replacement_bytes = MODULE.signature_json_bytes(replacement_request)
            replacement_digest = hashlib.sha256(replacement_bytes).hexdigest()
            fixture["envelope"]["sourceReleaseRequestSHA256"] = replacement_digest
            envelope_bytes = MODULE.signature_json_bytes(fixture["envelope"])
            fixture["envelope_path"].write_bytes(envelope_bytes)
            fixture["receipt"]["sourceReleaseRequestSHA256"] = replacement_digest
            fixture["receipt"]["authorityEnvelopeSHA256"] = hashlib.sha256(
                envelope_bytes
            ).hexdigest()
            fixture["receipt_path"].write_bytes(
                MODULE.signature_json_bytes(fixture["receipt"])
            )
            real_validator = MODULE.validate_toolchain_release_request
            swapped = False

            def swap_after_validation(*args: object, **kwargs: object):
                nonlocal swapped
                result = real_validator(*args, **kwargs)
                request_path.rename(moved)
                request_path.write_bytes(replacement_bytes)
                swapped = True
                return result

            with (
                mock.patch.object(
                    MODULE,
                    "validate_toolchain_release_request",
                    side_effect=swap_after_validation,
                ),
                mock.patch.object(MODULE, "verify_ed25519", return_value=True),
            ):
                with self.assertRaisesRegex(
                    MODULE.PublicationError,
                    "does not bind the release request|provenance closure",
                ):
                    MODULE.validate_toolchain_authority_closure(
                        request_path,
                        fixture["envelope_path"],
                        fixture["receipt_path"],
                        fixture["manifest_path"],
                        fixture["manifest"],
                        fixture["public_key_path"],
                        source_repository=REPOSITORY,
                        toolchain_version=TOOLCHAIN_VERSION,
                    )
            self.assertTrue(swapped)


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
        benchmark_evidence_path: Path,
        manifest: dict[str, object],
    ) -> dict[str, object]:
        assets = []
        for name, path in (
            ("manifest.json", manifest_path),
            ("toolchain-release-request.json", request_path),
            ("toolchain-authority-envelope.json", envelope_path),
            ("toolchain-authority-receipt.json", receipt_path),
            ("toolchain-benchmark-evidence.json", benchmark_evidence_path),
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
            "target_commitish": COMMIT,
            "draft": False,
            "prerelease": False,
            "immutable": True,
            "assets": assets,
        }

    def test_immutable_release_with_exact_assets_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            closure = authority_fixture(root)
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}\n", encoding="utf-8")
            benchmark_evidence_path = root / "toolchain-benchmark-evidence.json"
            benchmark_evidence_path.write_text("{}\n", encoding="utf-8")
            manifest = self._manifest()
            release = self._release(
                manifest_path,
                closure["request_path"],
                closure["envelope_path"],
                closure["receipt_path"],
                benchmark_evidence_path,
                manifest,
            )

            with mock.patch.object(MODULE, "api_json", return_value=release) as api:
                MODULE.validate_remote_toolchain_assets(
                    manifest_path,
                    closure["request_path"],
                    closure["envelope_path"],
                    closure["receipt_path"],
                    benchmark_evidence_path,
                    manifest,
                    source_repository=REPOSITORY,
                    toolchain_version=TOOLCHAIN_VERSION,
                    authority_source_commit=COMMIT,
                    github_token="read-only-token",
                )
            self.assertEqual(api.call_count, 1)

    def test_release_identity_mutations_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            closure = authority_fixture(root)
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}\n", encoding="utf-8")
            benchmark_evidence_path = root / "toolchain-benchmark-evidence.json"
            benchmark_evidence_path.write_text("{}\n", encoding="utf-8")
            manifest = self._manifest()
            mutations = (
                ("immutable", False),
                ("target_commitish", "f" * 40),
                ("target_commitish", None),
                ("prerelease", True),
                ("prerelease", None),
            )
            for field, value in mutations:
                with self.subTest(field=field, value=value):
                    release = self._release(
                        manifest_path,
                        closure["request_path"],
                        closure["envelope_path"],
                        closure["receipt_path"],
                        benchmark_evidence_path,
                        manifest,
                    )
                    if value is None:
                        release.pop(field)
                    else:
                        release[field] = value

                    with mock.patch.object(MODULE, "api_json", return_value=release):
                        with self.assertRaisesRegex(
                            MODULE.PublicationError, "release identity"
                        ):
                            MODULE.validate_remote_toolchain_assets(
                                manifest_path,
                                closure["request_path"],
                                closure["envelope_path"],
                                closure["receipt_path"],
                                benchmark_evidence_path,
                                manifest,
                                source_repository=REPOSITORY,
                                toolchain_version=TOOLCHAIN_VERSION,
                                authority_source_commit=COMMIT,
                                github_token="read-only-token",
                            )

if __name__ == "__main__":
    unittest.main()
