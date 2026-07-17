#!/usr/bin/env python3
"""Build and verify the inert artifact closure used to publish EasySplat."""

from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Iterator, NoReturn


BUILD_CLOSURE_NAME = "build-closure.json"
PUBLICATION_MANIFEST_NAME = "publication-manifest.json"
TOOLCHAIN_AUTHORITY_RECEIPT_NAME = "toolchain-authority-receipt.json"
TOOLCHAIN_AUTHORITY_ENVELOPE_NAME = "toolchain-authority-envelope.json"
TOOLCHAIN_RELEASE_REQUEST_NAME = "toolchain-release-request.json"
AUTHORITY_RECEIPT_SIGNATURE_DOMAIN = b"EasySplat Release Authority Receipt v1\n"
CANONICAL_SOURCE_REPOSITORY = "dud8/EasySplat"
CANONICAL_SOURCE_REPOSITORY_ID = 1_143_631_347
CANONICAL_SOURCE_WORKFLOW_ID = 227_648_955
CANONICAL_SOURCE_WORKFLOW_PATH = ".github/workflows/toolchain-build.yml"
CANONICAL_AUTHORITY_REPOSITORY = "dud8/easysplat-release-authority"
CANONICAL_AUTHORITY_REPOSITORY_ID = 1_301_851_745
METALSPLATTER_SOURCE = "https://github.com/scier/MetalSplatter"
METALSPLATTER_BASE_REVISION = "c0f066fb7146d46d9b68e5c76d7d0a6154facc5e"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAX_RELEASE_ASSET_BYTES = 2_147_483_648
MAX_HASH_BYTES = MAX_RELEASE_ASSET_BYTES
SHA256 = re.compile(r"[0-9a-f]{64}")
SHA256_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?"
)
UTC_RFC3339 = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z")
UUID_LINE = re.compile(
    r"UUID: ([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}) "
    r"\(arm64\) .+"
)
SYSTEM_TOOLS = {
    "hdiutil": "/usr/bin/hdiutil",
    "plutil": "/usr/bin/plutil",
    "lipo": "/usr/bin/lipo",
    "codesign": "/usr/bin/codesign",
    "dwarfdump": "/usr/bin/dwarfdump",
}
APP_TOOLCHAIN_RESOURCE_PATHS = (
    "Contents/Resources/public_key_ed25519.txt",
    "Contents/Resources/toolchain_manifest_url.txt",
    (
        "Contents/Resources/EasySplat_EasySplatApp.bundle/"
        "public_key_ed25519.txt"
    ),
    (
        "Contents/Resources/EasySplat_EasySplatApp.bundle/"
        "toolchain_manifest_url.txt"
    ),
    (
        "Contents/Resources/EasySplat_EasySplatApp.bundle/Contents/Resources/"
        "public_key_ed25519.txt"
    ),
    (
        "Contents/Resources/EasySplat_EasySplatApp.bundle/Contents/Resources/"
        "toolchain_manifest_url.txt"
    ),
)


class PublicationError(ValueError):
    pass


def fail(message: str) -> NoReturn:
    raise PublicationError(message)


def build_file_limits(app_version: str) -> dict[str, int]:
    stem = f"EasySplat-{app_version}"
    return {
        f"{stem}-unsigned.dmg": MAX_RELEASE_ASSET_BYTES,
        f"{stem}-unsigned.dmg.sha256": 1_024,
        f"{stem}.provenance.json": 8 * 1_024 * 1_024,
        f"{stem}.spdx.json": 64 * 1_024 * 1_024,
        f"{stem}-licenses.zip": MAX_RELEASE_ASSET_BYTES,
        f"{stem}-dSYM.zip": MAX_RELEASE_ASSET_BYTES,
        f"{stem}-release-notes.txt": 64 * 1_024,
        "toolchain-manifest.json": 64 * 1_024 * 1_024,
        TOOLCHAIN_AUTHORITY_RECEIPT_NAME: 1 * 1_024 * 1_024,
        TOOLCHAIN_AUTHORITY_ENVELOPE_NAME: 64 * 1_024 * 1_024,
        TOOLCHAIN_RELEASE_REQUEST_NAME: 64 * 1_024 * 1_024,
    }


def publication_payload_names(app_version: str) -> tuple[str, ...]:
    stem = f"EasySplat-{app_version}"
    return (
        f"{stem}-unsigned.dmg",
        f"{stem}-unsigned.dmg.sha256",
        f"{stem}.provenance.json",
        f"{stem}.spdx.json",
        f"{stem}-licenses.zip",
        f"{stem}-dSYM.zip",
        f"{stem}-benchmark.json",
        f"{stem}-release-notes.txt",
    )


def publication_file_limits(app_version: str) -> dict[str, int]:
    limits = build_file_limits(app_version)
    limits.pop("toolchain-manifest.json")
    limits.pop(TOOLCHAIN_AUTHORITY_RECEIPT_NAME)
    limits.pop(TOOLCHAIN_AUTHORITY_ENVELOPE_NAME)
    limits.pop(TOOLCHAIN_RELEASE_REQUEST_NAME)
    limits[f"EasySplat-{app_version}-benchmark.json"] = 128 * 1_024 * 1_024
    return limits


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")


def signature_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def sha256_stream(stream: BinaryIO, *, limit: int = MAX_HASH_BYTES) -> str:
    digest = hashlib.sha256()
    total = 0
    for chunk in iter(lambda: stream.read(1_024 * 1_024), b""):
        total += len(chunk)
        if total > limit:
            fail("file changed size or exceeded its hash limit while reading")
        digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: Path, *, limit: int = MAX_HASH_BYTES) -> str:
    with path.open("rb") as stream:
        return sha256_stream(stream, limit=limit)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    payload: dict[str, Any] = {}
    for key, value in pairs:
        if key in payload:
            fail(f"JSON contains duplicate key {key!r}")
        payload[key] = value
    return payload


def reject_json_constant(value: str) -> NoReturn:
    fail(f"JSON contains non-finite value {value}")


def load_json(
    path: Path, label: str, *, limit: int = 64 * 1_024 * 1_024
) -> dict[str, Any]:
    require_regular_file(path, label, maximum_size=limit)
    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    return payload


def load_compact_canonical_json(
    path: Path, label: str, *, limit: int = 1 * 1_024 * 1_024
) -> dict[str, Any]:
    require_regular_file(path, label, maximum_size=limit)
    try:
        raw = path.read_bytes()
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    if raw != signature_json_bytes(payload):
        fail(f"{label} is not canonical compact JSON")
    return payload


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        fail(f"{label} must contain exact keys {sorted(expected)}")


def validate_https_url(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a credential-free HTTPS URL")
    parsed = urllib.parse.urlparse(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        fail(f"{label} must be a credential-free HTTPS URL")
    return value


def validate_utc_timestamp(value: Any, label: str) -> str:
    if not isinstance(value, str) or not UTC_RFC3339.fullmatch(value):
        fail(f"{label} must be a UTC RFC 3339 timestamp")
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        fail(f"{label} must be a UTC RFC 3339 timestamp")
    return value


def validate_release_timestamps(
    provenance: dict[str, Any], manifest: dict[str, Any]
) -> None:
    created_at = validate_utc_timestamp(
        provenance.get("createdAt"), "release provenance createdAt"
    )
    published_at = validate_utc_timestamp(
        manifest.get("publishedAt"), "toolchain manifest publishedAt"
    )
    if created_at != published_at:
        fail("release provenance and signed manifest timestamps differ")


def require_regular_file(
    path: Path, label: str, *, maximum_size: int
) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail(f"{label} must be a regular file")
    if metadata.st_nlink != 1:
        fail(f"{label} must not be a hard link")
    if metadata.st_size <= 0 or metadata.st_size > maximum_size:
        fail(f"{label} exceeds its size limit or is empty")
    return metadata


def require_exact_directory(root: Path, limits: dict[str, int], *, label: str) -> None:
    try:
        metadata = root.lstat()
    except OSError as error:
        fail(f"cannot inspect {label}: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or root.is_symlink():
        fail(f"{label} must be a real directory")
    try:
        names = {entry.name for entry in root.iterdir()}
    except OSError as error:
        fail(f"cannot enumerate {label}: {error}")
    if names != set(limits):
        fail(f"{label} must contain the exact file set {sorted(limits)}")
    for name, maximum_size in limits.items():
        require_regular_file(
            root / name, f"{label} file {name}", maximum_size=maximum_size
        )


def file_record(path: Path, *, maximum_size: int) -> dict[str, Any]:
    metadata = require_regular_file(path, path.name, maximum_size=maximum_size)
    before = (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
    digest = sha256_file(path, limit=maximum_size)
    after_metadata = path.lstat()
    after = (
        after_metadata.st_dev,
        after_metadata.st_ino,
        after_metadata.st_size,
        after_metadata.st_mtime_ns,
    )
    if before != after or after_metadata.st_nlink != 1:
        fail(f"file changed while hashing: {path.name}")
    return {"name": path.name, "sha256": digest, "size_bytes": metadata.st_size}


def validate_identity(
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str,
    benchmark_artifact_id: str,
    benchmark_artifact_digest: str,
) -> None:
    try:
        _app_core, app_prerelease = parse_semver(app_version)
        parse_semver(toolchain_version)
    except PublicationError:
        fail("app and toolchain versions must use strict semantic versioning")
    if "+" in app_version or "+" in toolchain_version:
        fail(
            "public release versions must not contain semantic version build metadata"
        )
    if app_prerelease is None:
        fail("app version must be a semantic prerelease")
    if not REPOSITORY.fullmatch(source_repository):
        fail("source repository must be owner/name")
    if not COMMIT.fullmatch(source_commit):
        fail("source commit must be a lowercase full SHA")
    if tag != f"v{app_version}":
        fail("release tag does not match the app version")
    if not benchmark_run_id.isdecimal() or int(benchmark_run_id) <= 0:
        fail("benchmark run ID must be a positive integer")
    if not benchmark_artifact_id.isdecimal() or int(benchmark_artifact_id) <= 0:
        fail("benchmark artifact ID must be a positive integer")
    if not SHA256_DIGEST.fullmatch(benchmark_artifact_digest):
        fail("benchmark artifact digest must be sha256:<64 lowercase hex>")


def create_build_closure(
    bundle: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str,
    benchmark_artifact_id: str,
    benchmark_artifact_digest: str,
) -> dict[str, Any]:
    validate_identity(
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
    )
    limits = build_file_limits(app_version)
    require_exact_directory(bundle, limits, label="build bundle")
    payload = {
        "schema_version": 1,
        "app_version": app_version,
        "toolchain_version": toolchain_version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "tag": tag,
        "release_mode": "unsigned-beta",
        "benchmark": {
            "run_id": benchmark_run_id,
            "artifact_id": benchmark_artifact_id,
            "artifact_digest": benchmark_artifact_digest,
        },
        "files": [
            file_record(bundle / name, maximum_size=limits[name])
            for name in sorted(limits)
        ],
    }
    target = bundle / BUILD_CLOSURE_NAME
    try:
        with target.open("xb") as stream:
            stream.write(canonical_json_bytes(payload))
    except FileExistsError:
        fail(f"{BUILD_CLOSURE_NAME} already exists")
    return payload


def validate_file_records(
    value: Any, root: Path, limits: dict[str, int], label: str
) -> None:
    if not isinstance(value, list) or len(value) != len(limits):
        fail(f"{label} file records are incomplete")
    expected_records = [
        file_record(root / name, maximum_size=limits[name]) for name in sorted(limits)
    ]
    if value != expected_records:
        fail(f"{label} closure mismatch")


def validate_build_bundle(
    bundle: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str,
    benchmark_artifact_id: str,
    benchmark_artifact_digest: str,
) -> dict[str, Any]:
    validate_identity(
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
    )
    limits = build_file_limits(app_version)
    closure_limits = dict(limits)
    closure_limits[BUILD_CLOSURE_NAME] = 4 * 1_024 * 1_024
    require_exact_directory(bundle, closure_limits, label="build bundle")
    closure = load_json(
        bundle / BUILD_CLOSURE_NAME, "build closure", limit=4 * 1_024 * 1_024
    )
    require_exact_keys(
        closure,
        {
            "schema_version",
            "app_version",
            "toolchain_version",
            "source_repository",
            "source_commit",
            "tag",
            "release_mode",
            "benchmark",
            "files",
        },
        "build closure",
    )
    expected_scalars = {
        "schema_version": 1,
        "app_version": app_version,
        "toolchain_version": toolchain_version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "tag": tag,
        "release_mode": "unsigned-beta",
    }
    for key, expected in expected_scalars.items():
        if closure[key] != expected:
            fail(f"build closure {key} does not match the release")
    benchmark = closure["benchmark"]
    if not isinstance(benchmark, dict):
        fail("build closure benchmark identity must be an object")
    expected_benchmark = {
        "run_id": benchmark_run_id,
        "artifact_id": benchmark_artifact_id,
        "artifact_digest": benchmark_artifact_digest,
    }
    if benchmark != expected_benchmark:
        fail("build closure benchmark identity does not match")
    validate_file_records(closure["files"], bundle, limits, "build")
    return closure


def validate_dmg_checksum(dmg: Path, checksum: Path) -> None:
    expected = f"{sha256_file(dmg)}  {dmg.name}\n"
    try:
        actual = checksum.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot read DMG checksum: {error}")
    if actual != expected:
        fail("DMG checksum does not exactly name and hash the release image")


def vendored_viewer_source_identity() -> tuple[str, int]:
    root = REPOSITORY_ROOT / "ThirdParty/MetalSplatter"
    paths = [root / "Package.swift", root / "LICENSE"]
    for relative in ("MetalSplatter", "PLYIO/Sources", "SplatIO/Sources"):
        directory = root / relative
        if not directory.is_dir() or directory.is_symlink():
            fail(f"vendored MetalSplatter source directory is missing: {relative}")
        paths.extend(path for path in directory.rglob("*") if path.is_file())
    digest = hashlib.sha256()
    count = 0
    for path in sorted(set(paths), key=lambda value: value.relative_to(root).as_posix()):
        if path.is_symlink() or not path.is_file():
            fail("vendored MetalSplatter source closure contains an unsafe entry")
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(path)))
        count += 1
    if count < 4:
        fail("vendored MetalSplatter source closure is unexpectedly small")
    return digest.hexdigest(), count


def validate_provenance_shape(
    payload: dict[str, Any],
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
) -> None:
    require_exact_keys(
        payload,
        {
            "schemaVersion",
            "appVersion",
            "toolchainVersion",
            "releaseMode",
            "bundleIdentifier",
            "createdAt",
            "source",
            "sourceDependencies",
            "supplyChain",
            "artifacts",
        },
        "release provenance",
    )
    expected = {
        "schemaVersion": 2,
        "appVersion": app_version,
        "toolchainVersion": toolchain_version,
        "releaseMode": "unsigned-beta",
        "bundleIdentifier": "com.easysplat.app",
    }
    for key, value in expected.items():
        if payload[key] != value:
            fail(f"release provenance {key} is invalid")
    validate_utc_timestamp(payload["createdAt"], "release provenance createdAt")
    source = payload["source"]
    if not isinstance(source, dict):
        fail("release provenance source must be an object")
    require_exact_keys(
        source, {"buildCommand", "commit", "url"}, "release provenance source"
    )
    if source != {
        "buildCommand": "./scripts/release/build_app.sh",
        "commit": source_commit,
        "url": f"https://github.com/{source_repository}",
    }:
        fail("release provenance source identity is invalid")
    if (
        not isinstance(payload["sourceDependencies"], dict)
        or not isinstance(payload["supplyChain"], dict)
        or not isinstance(payload["artifacts"], dict)
    ):
        fail(
            "release provenance dependency, supply-chain, and artifact fields must be objects"
        )
    viewer_digest, viewer_file_count = vendored_viewer_source_identity()
    expected_source_dependencies = {
        "MetalSplatter": {
            "source": METALSPLATTER_SOURCE,
            "basedOnRevision": METALSPLATTER_BASE_REVISION,
            "vendoredTreeSHA256": viewer_digest,
            "sourceFileCount": viewer_file_count,
            "license": "MIT",
            "buildCommand": "./scripts/release/build_app.sh",
            "integration": "statically linked with EasySplat compatibility changes",
        }
    }
    if payload["sourceDependencies"] != expected_source_dependencies:
        fail("release provenance MetalSplatter identity is invalid")


def validate_provenance(
    path: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    dmg: Path,
    manifest: Path,
) -> dict[str, Any]:
    payload = load_json(path, "release provenance", limit=8 * 1_024 * 1_024)
    validate_provenance_shape(
        payload,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
    )
    artifacts = payload["artifacts"]
    expected_keys = {
        "dmg",
        "manifest",
        "core",
        "geometry-da3-base",
        "geometry-da3-small",
    }
    if set(artifacts) != expected_keys:
        fail("release provenance artifact allowlist is invalid")
    for identifier, row in artifacts.items():
        if not isinstance(row, dict):
            fail(f"release provenance artifact {identifier} must be an object")
        require_exact_keys(
            row, {"downloadURL", "file", "sha256", "size"}, f"artifact {identifier}"
        )
        if not isinstance(row["file"], str) or Path(row["file"]).name != row["file"]:
            fail(f"artifact {identifier} filename is invalid")
        if not isinstance(row["sha256"], str) or not SHA256.fullmatch(row["sha256"]):
            fail(f"artifact {identifier} digest is invalid")
        if not isinstance(row["size"], int) or not (
            0 < row["size"] <= MAX_RELEASE_ASSET_BYTES
        ):
            fail(f"artifact {identifier} size is invalid")
        expected_prefix = f"https://github.com/{source_repository}/releases/download/"
        if not isinstance(row["downloadURL"], str) or not row["downloadURL"].startswith(
            expected_prefix
        ):
            fail(f"artifact {identifier} URL is invalid")
    local_artifacts = {
        "dmg": (dmg, dmg.name),
        "manifest": (manifest, "manifest.json"),
    }
    for identifier, (local_path, expected_filename) in local_artifacts.items():
        row = artifacts[identifier]
        if (
            row["file"] != expected_filename
            or row["size"] != local_path.stat().st_size
            or row["sha256"] != sha256_file(local_path)
        ):
            fail(f"release provenance {identifier} does not match the build bundle")
    expected_download_urls = {
        "dmg": (
            f"https://github.com/{source_repository}/releases/download/"
            f"v{urllib.parse.quote(app_version, safe='.-')}/{dmg.name}"
        ),
        "manifest": (
            f"https://github.com/{source_repository}/releases/download/"
            f"toolchain-v{urllib.parse.quote(toolchain_version, safe='.-')}/manifest.json"
        ),
    }
    for identifier, expected_url in expected_download_urls.items():
        if artifacts[identifier]["downloadURL"] != expected_url:
            fail(f"release provenance {identifier} release URL is invalid")
    return payload


def spdx_component_id(component_id: str) -> str:
    label = re.sub(r"[^A-Za-z0-9.-]+", "-", component_id).strip("-") or "item"
    digest = hashlib.sha256(component_id.encode("utf-8")).hexdigest()[:8]
    return f"SPDXRef-Package-Component-{label}-{digest}"


def spdx_component_external_refs(component: dict[str, Any]) -> list[dict[str, str]]:
    source = component["source"]
    revision = component["revision"]
    references = [
        {
            "referenceCategory": "OTHER",
            "referenceType": "vcs",
            "referenceLocator": f"{source}#{revision}",
        }
    ]
    parsed = urllib.parse.urlparse(source)
    parts = [part for part in parsed.path.removesuffix(".git").split("/") if part]
    purl = ""
    if parsed.hostname == "github.com" and len(parts) == 2:
        purl = (
            f"pkg:github/{urllib.parse.quote(parts[0])}/{urllib.parse.quote(parts[1])}"
            f"@{urllib.parse.quote(revision, safe='.-:')}"
        )
    elif component["id"].startswith("python:"):
        purl = (
            f"pkg:pypi/{urllib.parse.quote(component['name'].lower())}"
            f"@{urllib.parse.quote(component['version'])}"
        )
    elif component["id"].startswith("homebrew:"):
        purl = (
            f"pkg:brew/{urllib.parse.quote(component['name'])}"
            f"@{urllib.parse.quote(component['version'])}"
        )
    if purl:
        references.insert(
            0,
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": purl,
            },
        )
    return references


def spdx_component_checksum(
    component: dict[str, Any], files: dict[str, dict[str, Any]]
) -> str:
    rows = [files[path] for path in component["files"]]
    material: Any = rows or {
        key: component[key]
        for key in ("id", "version", "revision", "source", "license", "licenseFiles")
    }
    return hashlib.sha256(canonical_json_bytes(material)).hexdigest()


def expected_spdx_document(
    *,
    provenance: dict[str, Any],
    license_closure: dict[str, Any],
    licenses_name: str,
) -> dict[str, Any]:
    source = provenance["source"]
    artifacts = provenance["artifacts"]
    viewer = provenance["sourceDependencies"]["MetalSplatter"]
    component_payload = license_closure["components"]
    components = {component["id"]: component for component in component_payload["components"]}
    files = {row["path"]: row for row in component_payload["files"]}
    archive_rows = {
        archive["id"]: archive["entries"]
        for archive in license_closure["archives"]["archives"]
    }
    app_id = "SPDXRef-Package-EasySplat"
    viewer_id = "SPDXRef-Package-MetalSplatter"
    artifact_ids = {
        "manifest": "SPDXRef-Package-Toolchain-Manifest",
        "core": "SPDXRef-Package-Toolchain-Core",
        "geometry-da3-base": "SPDXRef-Package-Geometry-DA3-Base",
        "geometry-da3-small": "SPDXRef-Package-Geometry-DA3-Small",
    }
    component_ids = {
        component_id: spdx_component_id(component_id) for component_id in components
    }

    app_purl = (
        f"pkg:github/dud8/EasySplat@{urllib.parse.quote(source['commit'])}"
        if source["url"].rstrip("/").removesuffix(".git")
        == "https://github.com/dud8/EasySplat"
        else f"pkg:generic/EasySplat@{urllib.parse.quote(provenance['appVersion'])}"
    )
    packages: list[dict[str, Any]] = [
        {
            "SPDXID": app_id,
            "name": "EasySplat",
            "versionInfo": provenance["appVersion"],
            "packageFileName": artifacts["dmg"]["file"],
            "downloadLocation": artifacts["dmg"]["downloadURL"],
            "homepage": source["url"],
            "sourceInfo": f"Build command: {source['buildCommand']}",
            "filesAnalyzed": False,
            "checksums": [
                {"algorithm": "SHA256", "checksumValue": artifacts["dmg"]["sha256"]}
            ],
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright (c) 2026 EasySplat contributors",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": app_purl,
                }
            ],
        },
        {
            "SPDXID": viewer_id,
            "name": "MetalSplatter",
            "versionInfo": viewer["basedOnRevision"],
            "downloadLocation": viewer["source"],
            "homepage": viewer["source"],
            "sourceInfo": (
                f"Based on upstream revision {viewer['basedOnRevision']} with reviewed EasySplat "
                f"compatibility changes; vendored source closure contains "
                f"{viewer['sourceFileCount']} files; build command: {viewer['buildCommand']}."
            ),
            "filesAnalyzed": False,
            "checksums": [
                {
                    "algorithm": "SHA256",
                    "checksumValue": viewer["vendoredTreeSHA256"],
                }
            ],
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright information is provided by MetalSplatter/LICENSE.",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": (
                        f"pkg:github/scier/MetalSplatter@{viewer['basedOnRevision']}"
                    ),
                },
                {
                    "referenceCategory": "OTHER",
                    "referenceType": "vcs",
                    "referenceLocator": f"{viewer['source']}#{viewer['basedOnRevision']}",
                },
            ],
        },
    ]
    artifact_licenses = {
        "manifest": "MIT",
        "core": "LicenseRef-EasySplat-Toolchain-Closure",
        "geometry-da3-base": "LicenseRef-EasySplat-Toolchain-Closure",
        "geometry-da3-small": "LicenseRef-EasySplat-Toolchain-Closure",
    }
    for identifier in (
        "manifest",
        "core",
        "geometry-da3-base",
        "geometry-da3-small",
    ):
        artifact = artifacts[identifier]
        license_id = artifact_licenses[identifier]
        packages.append(
            {
                "SPDXID": artifact_ids[identifier],
                "name": f"EasySplat-{identifier}",
                "versionInfo": provenance["toolchainVersion"],
                "packageFileName": artifact["file"],
                "downloadLocation": artifact["downloadURL"],
                "filesAnalyzed": False,
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": artifact["sha256"]}
                ],
                "licenseConcluded": license_id,
                "licenseDeclared": license_id,
                "copyrightText": (
                    "Copyright information is provided by the declared license files."
                ),
            }
        )
    for component_id in sorted(components):
        component = components[component_id]
        closure_checksum = spdx_component_checksum(component, files)
        packages.append(
            {
                "SPDXID": component_ids[component_id],
                "name": component["name"],
                "versionInfo": component["version"],
                "downloadLocation": component.get("artifact") or component["source"],
                "homepage": component["source"],
                "sourceInfo": (
                    f"Pinned revision: {component['revision']}; "
                    f"component closure SHA-256: {closure_checksum}; "
                    f"build command: {component['buildCommand']}"
                ),
                "filesAnalyzed": False,
                "checksums": [
                    {
                        "algorithm": "SHA256",
                        "checksumValue": component.get("artifactSha256")
                        or closure_checksum,
                    }
                ],
                "licenseConcluded": component["license"],
                "licenseDeclared": component["license"],
                "copyrightText": (
                    "Copyright information is provided by the declared license files."
                ),
                "externalRefs": spdx_component_external_refs(component),
            }
        )

    relationships: list[dict[str, str]] = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": app_id,
        },
        {
            "spdxElementId": app_id,
            "relationshipType": "STATIC_LINK",
            "relatedSpdxElement": viewer_id,
        },
    ]
    for identifier in (
        "manifest",
        "core",
        "geometry-da3-base",
        "geometry-da3-small",
    ):
        relationships.append(
            {
                "spdxElementId": app_id,
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": artifact_ids[identifier],
            }
        )
    for identifier in ("core", "geometry-da3-base", "geometry-da3-small"):
        owners = sorted({row["component"] for row in archive_rows[identifier]})
        for owner in owners:
            relationships.append(
                {
                    "spdxElementId": artifact_ids[identifier],
                    "relationshipType": "CONTAINS",
                    "relatedSpdxElement": component_ids[owner],
                }
            )
    for component_id in sorted(components):
        component = components[component_id]
        for dependency in component["dependencies"]:
            relationships.append(
                {
                    "spdxElementId": component_ids[component_id],
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": component_ids[dependency],
                }
            )
        for target in component.get("incorporatedInto", []):
            relationships.append(
                {
                    "spdxElementId": component_ids[target],
                    "relationshipType": "STATIC_LINK",
                    "relatedSpdxElement": component_ids[component_id],
                }
            )
    relationships.sort(
        key=lambda row: (
            row["spdxElementId"],
            row["relationshipType"],
            row["relatedSpdxElement"],
        )
    )

    license_ids = {"LicenseRef-EasySplat-Toolchain-Closure"}
    for component in components.values():
        license_ids.update(re.findall(r"LicenseRef-[A-Za-z0-9.-]+", component["license"]))
    extracted = [
        {
            "licenseId": identifier,
            "name": identifier.removeprefix("LicenseRef-").replace("-", " "),
            "extractedText": (
                f"Exact license texts and mappings are distributed in {licenses_name}; "
                "see Toolchain/supply-chain/components.json."
            ),
        }
        for identifier in sorted(license_ids)
    ]
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"EasySplat-{provenance['appVersion']}",
        "documentNamespace": (
            f"{source['url'].removesuffix('.git').rstrip('/')}/spdx/"
            f"{source['commit']}/{urllib.parse.quote(provenance['appVersion'], safe='.-')}"
        ),
        "creationInfo": {
            "created": provenance["createdAt"],
            "creators": ["Tool: EasySplat generate_release_metadata.py"],
        },
        "packages": packages,
        "relationships": relationships,
        "hasExtractedLicensingInfos": extracted,
    }


def validate_spdx(
    path: Path,
    *,
    provenance: dict[str, Any],
    license_closure: dict[str, Any],
    licenses_name: str,
) -> None:
    payload = load_json(path, "SPDX document", limit=64 * 1_024 * 1_024)
    require_exact_keys(
        payload,
        {
            "SPDXID",
            "spdxVersion",
            "dataLicense",
            "name",
            "documentNamespace",
            "creationInfo",
            "packages",
            "relationships",
            "hasExtractedLicensingInfos",
        },
        "SPDX document",
    )
    expected_name = f"EasySplat-{provenance['appVersion']}-licenses.zip"
    if licenses_name != expected_name:
        fail("SPDX license archive identity is invalid")
    expected = expected_spdx_document(
        provenance=provenance,
        license_closure=license_closure,
        licenses_name=licenses_name,
    )
    for field, label in (
        ("creationInfo", "creation information"),
        ("packages", "package closure"),
        ("relationships", "relationship closure"),
        ("hasExtractedLicensingInfos", "extracted-license closure"),
    ):
        if canonical_json_bytes(payload[field]) != canonical_json_bytes(expected[field]):
            fail(f"SPDX {label} does not match the validated release closure")
    remaining = {
        key: value
        for key, value in payload.items()
        if key
        not in {
            "creationInfo",
            "packages",
            "relationships",
            "hasExtractedLicensingInfos",
        }
    }
    expected_remaining = {
        key: value
        for key, value in expected.items()
        if key
        not in {
            "creationInfo",
            "packages",
            "relationships",
            "hasExtractedLicensingInfos",
        }
    }
    if canonical_json_bytes(remaining) != canonical_json_bytes(expected_remaining):
        fail("SPDX document identity does not match the validated release closure")


def safe_zip_name(raw: str, label: str) -> str:
    if not raw or "\\" in raw or "\x00" in raw:
        fail(f"unsafe {label}: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"unsafe {label}: {raw!r}")
    return path.as_posix()


def zip_entry_type(info: zipfile.ZipInfo) -> int:
    return stat.S_IFMT(info.external_attr >> 16)


def validate_zip(
    path: Path,
    *,
    label: str,
    allowed_prefixes: tuple[str, ...],
    required_files: set[str],
    maximum_expanded_size: int = 2 * 1_024 * 1_024 * 1_024,
    maximum_entry_size: int = 1_024 * 1_024 * 1_024,
) -> dict[str, zipfile.ZipInfo]:
    total = 0
    entries: dict[str, zipfile.ZipInfo] = {}
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                name = safe_zip_name(info.filename.rstrip("/"), f"{label} entry")
                if name in entries:
                    fail(f"{label} contains duplicate entry {name}")
                if not any(
                    name == prefix.rstrip("/") or name.startswith(prefix)
                    for prefix in allowed_prefixes
                ):
                    fail(f"{label} contains unallowlisted entry {name}")
                kind = zip_entry_type(info)
                if info.is_dir():
                    if kind not in {0, stat.S_IFDIR}:
                        fail(f"{label} directory has an invalid type: {name}")
                elif kind not in {0, stat.S_IFREG}:
                    fail(f"{label} contains a link or special file: {name}")
                if info.flag_bits & 0x1:
                    fail(f"{label} contains an encrypted entry: {name}")
                if info.file_size < 0 or info.file_size > maximum_entry_size:
                    fail(f"{label} entry exceeds its size limit: {name}")
                total += info.file_size
                if total > maximum_expanded_size:
                    fail(f"{label} expands beyond its size limit")
                entries[name] = info
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        fail(f"cannot inspect {label}: {error}")
    missing = required_files - set(entries)
    if missing:
        fail(f"{label} is missing required files: {sorted(missing)}")
    for required in sorted(required_files):
        info = entries[required]
        if info.is_dir() or zip_entry_type(info) not in {0, stat.S_IFREG} or info.file_size == 0:
            fail(f"{label} required file must be a nonempty regular file: {required}")
    return entries


def read_canonical_archive_json(
    archive: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    label: str,
    *,
    maximum_size: int = 64 * 1_024 * 1_024,
) -> tuple[dict[str, Any], bytes]:
    if info.file_size <= 0 or info.file_size > maximum_size:
        fail(f"{label} exceeds its size limit or is empty")
    try:
        raw = archive.read(info)
        payload = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_json_constant,
        )
    except (RuntimeError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a JSON object")
    if raw != canonical_json_bytes(payload):
        fail(f"{label} is not canonical JSON")
    return payload, raw


def supply_chain_archive_for_path(path: str) -> str:
    if path.startswith("da3_mps/models/DA3-BASE/"):
        return "geometry-da3-base"
    if path.startswith("da3_mps/models/DA3-SMALL/"):
        return "geometry-da3-small"
    return "core"


def validate_license_archive(
    path: Path,
    provenance: dict[str, Any],
    manifest: dict[str, Any],
    *,
    toolchain_version: str,
) -> dict[str, Any]:
    entries = validate_zip(
        path,
        label="license archive",
        allowed_prefixes=(
            "EasySplat/",
            "MetalSplatter/",
            "Toolchain/",
            "toolchain-closure.json",
        ),
        required_files={
            "EasySplat/LICENSE",
            "EasySplat/NOTICE.md",
            "MetalSplatter/LICENSE",
            "Toolchain/supply-chain/components.json",
            "toolchain-closure.json",
        },
        maximum_expanded_size=1_024 * 1_024 * 1_024,
        maximum_entry_size=256 * 1_024 * 1_024,
    )
    try:
        with zipfile.ZipFile(path) as archive:
            components_payload, components_raw = read_canonical_archive_json(
                archive,
                entries["Toolchain/supply-chain/components.json"],
                "toolchain component closure",
            )
            archive_closure, _ = read_canonical_archive_json(
                archive,
                entries["toolchain-closure.json"],
                "toolchain archive closure",
            )
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        fail(f"cannot read license archive closure: {error}")

    require_exact_keys(
        components_payload,
        {"schemaVersion", "toolchainVersion", "components", "files"},
        "toolchain component closure",
    )
    component_rows = components_payload["components"]
    file_rows = components_payload["files"]
    if (
        components_payload["schemaVersion"] != 1
        or components_payload["toolchainVersion"] != toolchain_version
        or not isinstance(component_rows, list)
        or not component_rows
        or not isinstance(file_rows, list)
        or not file_rows
    ):
        fail("toolchain component closure schema or contents are invalid")

    components: dict[str, dict[str, Any]] = {}
    component_ids: list[str] = []
    component_required = {
        "id",
        "name",
        "type",
        "version",
        "revision",
        "source",
        "buildCommand",
        "license",
        "linkage",
        "licenseFiles",
        "dependencies",
        "files",
    }
    component_optional = {"artifact", "artifactSha256", "incorporatedInto"}
    for index, component in enumerate(component_rows):
        if not isinstance(component, dict):
            fail(f"toolchain component {index} must be an object")
        if not component_required.issubset(component) or not set(component).issubset(
            component_required | component_optional
        ):
            fail(f"toolchain component {index} has invalid fields")
        component_id = component["id"]
        if (
            not isinstance(component_id, str)
            or not component_id
            or component_id in components
        ):
            fail("toolchain component identity is invalid")
        for field in (
            "name",
            "type",
            "version",
            "revision",
            "source",
            "buildCommand",
            "license",
            "linkage",
        ):
            if not isinstance(component[field], str) or not component[field]:
                fail(f"toolchain component {component_id} {field} is invalid")
        validate_https_url(
            component["source"], f"toolchain component {component_id} source"
        )
        for field in ("licenseFiles", "dependencies", "files"):
            values = component[field]
            if (
                not isinstance(values, list)
                or any(not isinstance(value, str) or not value for value in values)
                or values != sorted(set(values))
            ):
                fail(f"toolchain component {component_id} {field} is invalid")
        if not component["licenseFiles"]:
            fail(f"toolchain component {component_id} has no license files")
        incorporated = component.get("incorporatedInto", [])
        if (
            not isinstance(incorporated, list)
            or any(not isinstance(value, str) or not value for value in incorporated)
            or incorporated != sorted(set(incorporated))
        ):
            fail(f"toolchain component {component_id} incorporatedInto is invalid")
        artifact = component.get("artifact")
        artifact_sha = component.get("artifactSha256")
        if (artifact is None) != (artifact_sha is None) or (
            artifact_sha is not None
            and (not isinstance(artifact_sha, str) or not SHA256.fullmatch(artifact_sha))
        ):
            fail(f"toolchain component {component_id} artifact identity is invalid")
        if artifact is not None:
            validate_https_url(
                artifact, f"toolchain component {component_id} artifact"
            )
        components[component_id] = component
        component_ids.append(component_id)
    if component_ids != sorted(component_ids):
        fail("toolchain components must be sorted by id")

    files: dict[str, dict[str, Any]] = {}
    owned_files: dict[str, list[str]] = {component_id: [] for component_id in components}
    file_paths: list[str] = []
    for index, row in enumerate(file_rows):
        if not isinstance(row, dict):
            fail(f"toolchain closure file {index} must be an object")
        if not {"component", "kind", "path"}.issubset(row):
            fail(f"toolchain closure file {index} is incomplete")
        path_value = safe_zip_name(row["path"], "toolchain closure path")
        component_id = row["component"]
        kind = row["kind"]
        if path_value in files or component_id not in components:
            fail(f"toolchain closure file ownership is invalid: {path_value}")
        expected_keys = {"component", "kind", "path"}
        if kind in {"file", "mach-o"}:
            expected_keys |= {"sha256", "size"}
            if kind == "mach-o":
                expected_keys.add("dependencies")
            if (
                not isinstance(row.get("sha256"), str)
                or not SHA256.fullmatch(row["sha256"])
                or type(row.get("size")) is not int
                or row["size"] < 0
            ):
                fail(f"toolchain closure file digest or size is invalid: {path_value}")
        elif kind == "symlink":
            expected_keys.add("target")
            if not isinstance(row.get("target"), str) or not row["target"]:
                fail(f"toolchain closure symlink target is invalid: {path_value}")
        else:
            fail(f"toolchain closure file kind is invalid: {path_value}")
        if set(row) != expected_keys:
            fail(f"toolchain closure file fields are invalid: {path_value}")
        files[path_value] = row
        file_paths.append(path_value)
        owned_files[component_id].append(path_value)
    if file_paths != sorted(file_paths):
        fail("toolchain closure files must be sorted by path")

    mapped_license_paths: set[str] = set()
    for component_id, component in components.items():
        if component["files"] != sorted(owned_files[component_id]):
            fail(f"toolchain component {component_id} file ownership differs")
        for relation in (*component["dependencies"], *component.get("incorporatedInto", [])):
            if relation not in components or relation == component_id:
                fail(f"toolchain component {component_id} has an invalid relationship")
        for license_path in component["licenseFiles"]:
            file_row = files.get(license_path)
            archived_license = entries.get(f"Toolchain/{license_path}")
            if (
                file_row is None
                or file_row["kind"] == "symlink"
                or archived_license is None
                or archived_license.is_dir()
                or archived_license.file_size == 0
            ):
                fail(f"toolchain component {component_id} license closure is incomplete")
            mapped_license_paths.add(license_path)
    try:
        with zipfile.ZipFile(path) as archive:
            for license_path in sorted(mapped_license_paths):
                file_row = files[license_path]
                archived_license = entries[f"Toolchain/{license_path}"]
                with archive.open(archived_license) as stream:
                    digest = sha256_stream(stream, limit=256 * 1_024 * 1_024)
                if (
                    archived_license.file_size != file_row["size"]
                    or digest != file_row["sha256"]
                ):
                    fail(f"toolchain license bytes differ from the signed closure: {license_path}")
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        fail(f"cannot verify toolchain license bytes: {error}")

    components_sha = hashlib.sha256(components_raw).hexdigest()
    core_components = [
        component
        for component in manifest.get("components", [])
        if isinstance(component, dict) and component.get("name") == "macos-arm64-core"
    ]
    if len(core_components) != 1 or core_components[0].get("criticalFileHashes", {}).get(
        "supply-chain/components.json"
    ) != components_sha:
        fail("license archive does not match the signed component closure")
    supply_chain = provenance.get("supplyChain")
    if supply_chain != {
        "schemaVersion": 1,
        "componentsSHA256": components_sha,
        "componentCount": len(components),
        "fileCount": len(files),
    }:
        fail("release provenance supply-chain closure is invalid")

    require_exact_keys(
        archive_closure,
        {"schemaVersion", "toolchainVersion", "componentsSHA256", "archives"},
        "toolchain archive closure",
    )
    archive_rows = archive_closure["archives"]
    expected_archive_ids = ("core", "geometry-da3-base", "geometry-da3-small")
    if (
        archive_closure["schemaVersion"] != 1
        or archive_closure["toolchainVersion"] != toolchain_version
        or archive_closure["componentsSHA256"] != components_sha
        or not isinstance(archive_rows, list)
        or len(archive_rows) != len(expected_archive_ids)
    ):
        fail("toolchain archive closure identity is invalid")
    provenance_artifacts = provenance.get("artifacts")
    if not isinstance(provenance_artifacts, dict):
        fail("release provenance artifacts are invalid")
    for archive_row, archive_id in zip(archive_rows, expected_archive_ids):
        if not isinstance(archive_row, dict):
            fail("toolchain archive closure row must be an object")
        require_exact_keys(
            archive_row,
            {"id", "file", "sha256", "size", "entries"},
            f"toolchain archive closure {archive_id}",
        )
        artifact = provenance_artifacts.get(archive_id)
        expected_entries = [
            row
            for row in file_rows
            if supply_chain_archive_for_path(row["path"]) == archive_id
        ]
        if (
            not isinstance(artifact, dict)
            or archive_row["id"] != archive_id
            or archive_row["file"] != artifact.get("file")
            or archive_row["sha256"] != artifact.get("sha256")
            or archive_row["size"] != artifact.get("size")
            or archive_row["entries"] != expected_entries
        ):
            fail(f"toolchain archive closure differs for {archive_id}")
    return {
        "components": components_payload,
        "archives": archive_closure,
        "component_ids": tuple(component_ids),
    }


def run_static(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    if not arguments or arguments[0] not in SYSTEM_TOOLS.values():
        fail("publication verifier attempted a non-static subprocess")
    try:
        return subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        fail(f"static inspection command failed: {arguments[0]}: {error}")


def plist_value(path: Path, key: str) -> str | None:
    result = run_static(
        [SYSTEM_TOOLS["plutil"], "-extract", key, "raw", "-o", "-", str(path)]
    )
    value = result.stdout.strip()
    return value if value else None


def load_plist(path: Path, label: str) -> dict[str, Any]:
    result = run_static(
        [SYSTEM_TOOLS["plutil"], "-convert", "json", "-o", "-", str(path)]
    )
    try:
        payload = json.loads(result.stdout)
    except (json.JSONDecodeError, RecursionError) as error:
        fail(f"{label} is not a property-list object: {error}")
    if not isinstance(payload, dict):
        fail(f"{label} must be a property-list object")
    return payload


def expected_app_plist(app_version: str) -> tuple[tuple[str, str], ...]:
    base_version = app_version.split("-", 1)[0]
    return (
        ("CFBundleExecutable", "EasySplatApp"),
        ("CFBundleIdentifier", "com.easysplat.app"),
        ("CFBundleName", "EasySplat"),
        ("CFBundlePackageType", "APPL"),
        ("CFBundleShortVersionString", base_version),
        ("CFBundleVersion", base_version),
        ("EasySplatReleaseChannel", "unsigned-beta"),
        ("EasySplatReleaseVersion", app_version),
        ("LSMinimumSystemVersion", "15.0"),
    )


def validate_app_plist(path: Path, *, app_version: str) -> None:
    payload = load_plist(path, "app Info.plist")
    for key, expected in expected_app_plist(app_version):
        actual = payload.get(key)
        if actual != expected:
            fail(f"Info.plist {key} is {actual!r}, expected {expected!r}")
    for forbidden in ("LSUIElement", "LSBackgroundOnly"):
        if forbidden in payload:
            fail(f"Info.plist must not contain {forbidden}")


def validate_regular_tree(root: Path, *, maximum_bytes: int) -> None:
    total = 0
    for path in sorted(root.rglob("*")):
        metadata = path.lstat()
        if path.is_symlink():
            fail(f"app bundle contains a symbolic link: {path.relative_to(root)}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"app bundle contains a special file: {path.relative_to(root)}")
        if metadata.st_nlink != 1:
            fail(f"app bundle contains a hard-linked file: {path.relative_to(root)}")
        total += metadata.st_size
        if total > maximum_bytes:
            fail("app bundle exceeds its static inspection size limit")


def parse_uuid(output: str, label: str) -> str:
    lines = [line for line in output.splitlines() if line]
    if len(lines) != 1:
        fail(f"{label} must contain exactly one Mach-O UUID")
    match = UUID_LINE.fullmatch(lines[0])
    if match is None:
        fail(f"{label} is not one arm64 Mach-O UUID")
    return match.group(1)


def validate_app_toolchain_resources(
    app: Path,
    *,
    toolchain_version: str,
    source_repository: str,
    toolchain_public_key: Path,
) -> None:
    resource_names = {"public_key_ed25519.txt", "toolchain_manifest_url.txt"}
    found = {
        path.relative_to(app).as_posix()
        for path in app.rglob("*")
        if path.name in resource_names
    }
    expected = set(APP_TOOLCHAIN_RESOURCE_PATHS)
    if found != expected:
        fail("bundled toolchain resource closure is not exact")

    expected_public_key = file_record(
        toolchain_public_key,
        maximum_size=1_024,
    )
    expected_manifest_url = (
        f"https://github.com/{source_repository}/releases/download/"
        f"toolchain-v{toolchain_version}/manifest.json"
    ).encode("ascii")
    expected_records = {
        "public_key_ed25519.txt": (
            expected_public_key["size_bytes"],
            expected_public_key["sha256"],
        ),
        "toolchain_manifest_url.txt": (
            len(expected_manifest_url),
            hashlib.sha256(expected_manifest_url).hexdigest(),
        ),
    }

    for relative in APP_TOOLCHAIN_RESOURCE_PATHS:
        resource = app / relative
        actual = file_record(resource, maximum_size=1_024)
        if (actual["size_bytes"], actual["sha256"]) != expected_records[resource.name]:
            fail(
                "bundled toolchain resource does not match release authority: "
                f"{relative}"
            )


def validate_app_bundle(
    app: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    toolchain_public_key: Path,
) -> str:
    if app.is_symlink() or not app.is_dir():
        fail("DMG must contain a real EasySplat.app directory")
    contents = app / "Contents"
    expected = {"Info.plist", "MacOS", "Resources", "_CodeSignature"}
    if (
        not contents.is_dir()
        or {entry.name for entry in contents.iterdir()} != expected
    ):
        fail("app Contents allowlist is invalid")
    validate_regular_tree(app, maximum_bytes=4 * 1_024 * 1_024 * 1_024)
    validate_app_toolchain_resources(
        app,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        toolchain_public_key=toolchain_public_key,
    )
    plist = contents / "Info.plist"
    executable = contents / "MacOS/EasySplatApp"
    if not executable.is_file() or executable.is_symlink():
        fail("app executable is missing")
    if {entry.name for entry in executable.parent.iterdir()} != {"EasySplatApp"}:
        fail("app MacOS directory contains an unexpected executable")
    validate_app_plist(plist, app_version=app_version)
    architectures = run_static(
        [SYSTEM_TOOLS["lipo"], "-archs", str(executable)]
    ).stdout.strip()
    if architectures != "arm64":
        fail("release app executable must be arm64-only")
    run_static([SYSTEM_TOOLS["codesign"], "--verify", "--deep", "--strict", str(app)])
    signing = run_static([SYSTEM_TOOLS["codesign"], "-dvvv", str(app)])
    details = signing.stdout + signing.stderr
    for required in (
        "Identifier=com.easysplat.app",
        "Signature=adhoc",
        "TeamIdentifier=not set",
    ):
        if required not in details:
            fail(f"unsigned-beta signing state is missing {required}")
    return parse_uuid(
        run_static([SYSTEM_TOOLS["dwarfdump"], "--uuid", str(executable)]).stdout,
        "app executable",
    )


@contextlib.contextmanager
def mounted_dmg(path: Path) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(
        prefix="easysplat-publication-mount-"
    ) as temporary:
        mount = Path(temporary) / "volume"
        mount.mkdir()
        run_static([SYSTEM_TOOLS["hdiutil"], "verify", str(path)])
        run_static(
            [
                SYSTEM_TOOLS["hdiutil"],
                "attach",
                "-readonly",
                "-nobrowse",
                "-noautoopen",
                "-owners",
                "off",
                "-mountpoint",
                str(mount),
                str(path),
            ]
        )
        try:
            yield mount
        finally:
            run_static([SYSTEM_TOOLS["hdiutil"], "detach", str(mount)])


def validate_dsym_archive(path: Path, app_binary: Path | str) -> None:
    dwarf_name = "EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp"
    plist_name = "EasySplat.app.dSYM/Contents/Info.plist"
    entries = validate_zip(
        path,
        label="dSYM archive",
        allowed_prefixes=("EasySplat.app.dSYM/",),
        required_files={dwarf_name, plist_name},
        maximum_expanded_size=2 * 1_024 * 1_024 * 1_024,
        maximum_entry_size=1_024 * 1_024 * 1_024,
    )
    with tempfile.TemporaryDirectory(prefix="easysplat-publication-dsym-") as temporary:
        root = Path(temporary)
        extracted: dict[str, Path] = {}
        with zipfile.ZipFile(path) as archive:
            for name in (dwarf_name, plist_name):
                info = entries[name]
                target = root / Path(name).name
                with archive.open(info) as source, target.open("xb") as destination:
                    shutil.copyfileobj(source, destination, length=1_024 * 1_024)
                extracted[name] = target
        if plist_value(extracted[plist_name], "CFBundlePackageType") != "dSYM":
            fail("dSYM Info.plist package type is invalid")
        app_uuid = parse_uuid(
            run_static([SYSTEM_TOOLS["dwarfdump"], "--uuid", str(app_binary)]).stdout,
            "app executable",
        )
        dsym_uuid = parse_uuid(
            run_static(
                [SYSTEM_TOOLS["dwarfdump"], "--uuid", str(extracted[dwarf_name])]
            ).stdout,
            "dSYM",
        )
        if app_uuid != dsym_uuid:
            fail("dSYM UUID does not match the app executable")


# RFC 8032 verification. The release verifier intentionally carries no third-party runtime.
_Q = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _Q - 2, _Q)) % _Q
_I = pow(2, (_Q - 1) // 4, _Q)
_IDENTITY = (0, 1)


def _ed_xrecover(y: int, sign: int) -> int:
    xx = (y * y - 1) * pow(_D * y * y + 1, _Q - 2, _Q) % _Q
    x = pow(xx, (_Q + 3) // 8, _Q)
    if (x * x - xx) % _Q != 0:
        x = x * _I % _Q
    if (x * x - xx) % _Q != 0:
        fail("Ed25519 point is not on the curve")
    if x & 1 != sign:
        x = _Q - x
    return x


def _ed_decode(raw: bytes) -> tuple[int, int]:
    if len(raw) != 32:
        fail("Ed25519 point must be 32 bytes")
    encoded = int.from_bytes(raw, "little")
    sign = encoded >> 255
    y = encoded & ((1 << 255) - 1)
    if y >= _Q:
        fail("Ed25519 point encoding is not canonical")
    point = (_ed_xrecover(y, sign), y)
    if point[0] == 0 and sign:
        fail("Ed25519 point encoding is not canonical")
    return point


def _ed_add(left: tuple[int, int], right: tuple[int, int]) -> tuple[int, int]:
    x1, y1 = left
    x2, y2 = right
    product = _D * x1 * x2 * y1 * y2 % _Q
    x3 = (x1 * y2 + x2 * y1) * pow(1 + product, _Q - 2, _Q) % _Q
    y3 = (y1 * y2 + x1 * x2) * pow(1 - product, _Q - 2, _Q) % _Q
    return x3, y3


def _ed_scalar(point: tuple[int, int], scalar: int) -> tuple[int, int]:
    result = _IDENTITY
    addend = point
    while scalar:
        if scalar & 1:
            result = _ed_add(result, addend)
        addend = _ed_add(addend, addend)
        scalar >>= 1
    return result


_BASE = (_ed_xrecover(4 * pow(5, _Q - 2, _Q) % _Q, 0), 4 * pow(5, _Q - 2, _Q) % _Q)


def verify_ed25519(public_key: bytes, message: bytes, signature: bytes) -> bool:
    try:
        if len(public_key) != 32 or len(signature) != 64:
            return False
        encoded_r = signature[:32]
        scalar_s = int.from_bytes(signature[32:], "little")
        if scalar_s >= _L:
            return False
        public_point = _ed_decode(public_key)
        r_point = _ed_decode(encoded_r)
        if (
            _ed_scalar(public_point, 8) == _IDENTITY
            or _ed_scalar(r_point, 8) == _IDENTITY
        ):
            return False
        challenge = (
            int.from_bytes(
                hashlib.sha512(encoded_r + public_key + message).digest(), "little"
            )
            % _L
        )
        return _ed_scalar(_BASE, scalar_s) == _ed_add(
            r_point, _ed_scalar(public_point, challenge)
        )
    except PublicationError:
        return False


def decode_base64(value: str, label: str, expected_size: int) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        fail(f"{label} is not valid base64: {error}")
    if len(raw) != expected_size:
        fail(f"{label} must decode to {expected_size} bytes")
    return raw


def parse_semver(value: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None]:
    match = SEMVER.fullmatch(value)
    if match is None:
        fail(f"invalid semantic version: {value}")
    prerelease = match.group(4)
    build = match.group(5)
    for label, raw in (("prerelease", prerelease), ("build metadata", build)):
        if raw is not None and any(not identifier for identifier in raw.split(".")):
            fail(f"invalid semantic version {label}: {value}")
    identifiers = tuple(prerelease.split(".")) if prerelease is not None else None
    if identifiers is not None and any(
        identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0")
        for identifier in identifiers
    ):
        fail(f"invalid semantic version prerelease: {value}")
    return (
        (int(match.group(1)), int(match.group(2)), int(match.group(3))),
        identifiers,
    )


def compare_semver(left: str, right: str) -> int:
    left_core, left_prerelease = parse_semver(left)
    right_core, right_prerelease = parse_semver(right)
    if left_core != right_core:
        return -1 if left_core < right_core else 1
    if left_prerelease is None or right_prerelease is None:
        if left_prerelease is right_prerelease:
            return 0
        return 1 if left_prerelease is None else -1
    for left_identifier, right_identifier in zip(left_prerelease, right_prerelease):
        if left_identifier == right_identifier:
            continue
        left_numeric = left_identifier.isdigit()
        right_numeric = right_identifier.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_identifier) < int(right_identifier) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_identifier < right_identifier else 1
    if len(left_prerelease) == len(right_prerelease):
        return 0
    return -1 if len(left_prerelease) < len(right_prerelease) else 1


def validate_toolchain_manifest(
    path: Path,
    trust_root_path: Path,
    *,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
) -> dict[str, Any]:
    manifest = load_json(path, "toolchain manifest", limit=64 * 1_024 * 1_024)
    require_exact_keys(
        manifest,
        {
            "schemaVersion",
            "toolchainAPI",
            "keyID",
            "version",
            "publishedAt",
            "appVersionRange",
            "components",
            "signatureEd25519",
        },
        "toolchain manifest",
    )
    if manifest["schemaVersion"] != 2 or manifest["toolchainAPI"] != 2:
        fail("toolchain manifest schema or API is invalid")
    if manifest["version"] != toolchain_version:
        fail("toolchain manifest version does not match the release")
    validate_utc_timestamp(manifest["publishedAt"], "toolchain manifest publishedAt")
    require_regular_file(
        trust_root_path,
        "tracked toolchain public key",
        maximum_size=1_024,
    )
    public_key_text = trust_root_path.read_text(encoding="ascii").strip()
    public_key = decode_base64(public_key_text, "toolchain public key", 32)
    if manifest["keyID"] != hashlib.sha256(public_key).hexdigest():
        fail("toolchain manifest key identifier is invalid")
    signature = decode_base64(manifest["signatureEd25519"], "toolchain signature", 64)
    unsigned = dict(manifest)
    unsigned["signatureEd25519"] = ""
    if not verify_ed25519(public_key, signature_json_bytes(unsigned), signature):
        fail("toolchain manifest signature is invalid")
    app_range = manifest["appVersionRange"]
    if not isinstance(app_range, dict):
        fail("toolchain app version range must be an object")
    require_exact_keys(
        app_range, {"minimum", "maximumExclusive"}, "toolchain app version range"
    )
    if compare_semver(app_version, app_range["minimum"]) < 0:
        fail("toolchain manifest does not support this app version")
    maximum = app_range["maximumExclusive"]
    if maximum is not None and compare_semver(app_version, maximum) >= 0:
        fail("toolchain manifest does not support this app version")
    components = manifest["components"]
    if not isinstance(components, list) or len(components) != 3:
        fail("toolchain manifest must contain the three public-beta components")
    expected_names = {"macos-arm64-core", "geometry-da3-base", "geometry-da3-small"}
    seen: set[str] = set()
    for component in components:
        if not isinstance(component, dict):
            fail("toolchain component must be an object")
        require_exact_keys(
            component,
            {
                "name",
                "capabilities",
                "url",
                "sha256",
                "sizeBytes",
                "expandedSizeBytes",
                "contents",
                "criticalFileHashes",
                "dependencies",
                "requirement",
            },
            "toolchain component",
        )
        name = component["name"]
        if name not in expected_names or name in seen:
            fail("toolchain component set is invalid")
        seen.add(name)
        expected_file = {
            "macos-arm64-core": f"toolchain-macos-arm64-{toolchain_version}-core.zip",
            "geometry-da3-base": f"toolchain-geometry-da3-base-{toolchain_version}.zip",
            "geometry-da3-small": f"toolchain-geometry-da3-small-{toolchain_version}.zip",
        }[name]
        expected_url = (
            f"https://github.com/{source_repository}/releases/download/"
            f"toolchain-v{toolchain_version}/{expected_file}"
        )
        if component["url"] != expected_url:
            fail(f"toolchain component URL is invalid: {name}")
        if not isinstance(component["sha256"], str) or not SHA256.fullmatch(
            component["sha256"]
        ):
            fail(f"toolchain component digest is invalid: {name}")
        if not isinstance(component["sizeBytes"], int) or not (
            0 < component["sizeBytes"] <= MAX_RELEASE_ASSET_BYTES
        ):
            fail(f"toolchain component size is invalid: {name}")
    if seen != expected_names:
        fail("toolchain component set is incomplete")
    return manifest


def positive_integer(value: Any, label: str) -> int:
    if type(value) is not int or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def validate_source_artifacts(
    value: Any, *, toolchain_version: str, label: str
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) != 2:
        fail(f"{label} source artifact closure is invalid")
    expected_artifacts = (
        ("components", f"toolchain-components-{toolchain_version}"),
        ("signingRequest", f"toolchain-signing-request-{toolchain_version}"),
    )
    seen_artifact_ids: set[int] = set()
    validated: list[dict[str, Any]] = []
    for index, (artifact, (expected_kind, expected_name)) in enumerate(
        zip(value, expected_artifacts)
    ):
        if not isinstance(artifact, dict):
            fail(f"{label} source artifact must be an object")
        require_exact_keys(
            artifact,
            {
                "kind",
                "name",
                "artifactID",
                "artifactDigest",
                "payloadSHA256",
                "sizeBytes",
            },
            f"{label} sourceArtifacts[{index}]",
        )
        artifact_id = positive_integer(
            artifact["artifactID"], f"{label} sourceArtifacts[{index}].artifactID"
        )
        if artifact_id in seen_artifact_ids:
            fail(f"{label} reuses a source artifact")
        seen_artifact_ids.add(artifact_id)
        if (
            artifact["kind"] != expected_kind
            or artifact["name"] != expected_name
            or not isinstance(artifact["artifactDigest"], str)
            or not SHA256_DIGEST.fullmatch(artifact["artifactDigest"])
            or not isinstance(artifact["payloadSHA256"], str)
            or not SHA256.fullmatch(artifact["payloadSHA256"])
            or artifact["payloadSHA256"]
            != artifact["artifactDigest"].removeprefix("sha256:")
        ):
            fail(f"{label} source artifact identity is invalid")
        positive_integer(
            artifact["sizeBytes"], f"{label} sourceArtifacts[{index}].sizeBytes"
        )
        validated.append(dict(artifact))
    return validated


def validate_toolchain_release_request(
    path: Path,
    manifest: dict[str, Any],
    *,
    source_repository: str,
) -> dict[str, Any]:
    request = load_compact_canonical_json(
        path, "toolchain release request", limit=64 * 1_024 * 1_024
    )
    require_exact_keys(
        request,
        {
            "schemaVersion",
            "sourceRepository",
            "sourceCommit",
            "manifestSHA256",
            "manifest",
        },
        "toolchain release request",
    )
    if (
        request["schemaVersion"] != 1
        or source_repository != CANONICAL_SOURCE_REPOSITORY
        or request["sourceRepository"] != source_repository
        or not isinstance(request["sourceCommit"], str)
        or not COMMIT.fullmatch(request["sourceCommit"])
    ):
        fail("toolchain release request source identity is invalid")
    unsigned_manifest = dict(manifest)
    unsigned_manifest["signatureEd25519"] = ""
    unsigned_digest = hashlib.sha256(
        signature_json_bytes(unsigned_manifest)
    ).hexdigest()
    if (
        request["manifest"] != unsigned_manifest
        or request["manifestSHA256"] != unsigned_digest
    ):
        fail("toolchain release request does not bind the unsigned manifest")
    return request


def validate_toolchain_authority_envelope(
    path: Path,
    release_request_path: Path,
    release_request: dict[str, Any],
    *,
    source_repository: str,
    toolchain_version: str,
) -> dict[str, Any]:
    envelope = load_compact_canonical_json(
        path, "toolchain authority envelope", limit=64 * 1_024 * 1_024
    )
    require_exact_keys(
        envelope,
        {
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
            "manifest",
        },
        "toolchain authority envelope",
    )
    if (
        envelope["schemaVersion"] != 1
        or envelope["sourceRepository"] != source_repository
        or envelope["sourceRepositoryID"] != CANONICAL_SOURCE_REPOSITORY_ID
        or envelope["sourceCommit"] != release_request["sourceCommit"]
        or envelope["sourceWorkflowID"] != CANONICAL_SOURCE_WORKFLOW_ID
        or envelope["sourceWorkflowPath"] != CANONICAL_SOURCE_WORKFLOW_PATH
        or envelope["authorityRepository"] != CANONICAL_AUTHORITY_REPOSITORY
        or envelope["authorityRepositoryID"] != CANONICAL_AUTHORITY_REPOSITORY_ID
        or envelope["releaseTag"] != f"toolchain-v{toolchain_version}"
    ):
        fail("toolchain authority envelope identity is invalid")
    if not isinstance(envelope["authorityCommit"], str) or not COMMIT.fullmatch(
        envelope["authorityCommit"]
    ):
        fail("toolchain authority envelope authorityCommit is invalid")
    for field in (
        "sourceRunID",
        "sourceRunAttempt",
        "authorityRunID",
        "authorityRunAttempt",
    ):
        positive_integer(envelope[field], f"toolchain authority envelope {field}")
    validate_source_artifacts(
        envelope["sourceArtifacts"],
        toolchain_version=toolchain_version,
        label="toolchain authority envelope",
    )
    request_digest = sha256_file(release_request_path, limit=64 * 1_024 * 1_024)
    if (
        envelope["sourceReleaseRequestSHA256"] != request_digest
        or envelope["unsignedManifestSHA256"] != release_request["manifestSHA256"]
        or envelope["manifest"] != release_request["manifest"]
    ):
        fail("toolchain authority envelope does not bind the release request")
    return envelope


def validate_toolchain_authority_receipt(
    path: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    trust_root_path: Path,
    *,
    source_repository: str,
    toolchain_version: str,
) -> dict[str, Any]:
    receipt = load_compact_canonical_json(path, "toolchain authority receipt")
    require_exact_keys(
        receipt,
        {
            "schemaVersion",
            "keyID",
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
            "authorityEnvelopeSHA256",
            "sourceReleaseRequestSHA256",
            "unsignedManifestSHA256",
            "signedManifestFileSHA256",
            "releaseTag",
            "signedAt",
            "signatureEd25519",
        },
        "toolchain authority receipt",
    )
    if source_repository != CANONICAL_SOURCE_REPOSITORY:
        fail("toolchain authority is pinned to the canonical EasySplat repository")

    if (
        receipt["schemaVersion"] != 1
        or receipt["keyID"] != manifest["keyID"]
        or receipt["sourceRepository"] != source_repository
        or receipt["sourceRepositoryID"] != CANONICAL_SOURCE_REPOSITORY_ID
        or receipt["sourceWorkflowID"] != CANONICAL_SOURCE_WORKFLOW_ID
        or receipt["sourceWorkflowPath"] != CANONICAL_SOURCE_WORKFLOW_PATH
        or receipt["authorityRepository"] != CANONICAL_AUTHORITY_REPOSITORY
        or receipt["authorityRepositoryID"] != CANONICAL_AUTHORITY_REPOSITORY_ID
        or receipt["releaseTag"] != f"toolchain-v{toolchain_version}"
    ):
        fail("toolchain authority receipt identity is invalid")
    for field in ("sourceCommit", "authorityCommit"):
        if not isinstance(receipt[field], str) or not COMMIT.fullmatch(receipt[field]):
            fail(f"toolchain authority receipt {field} is invalid")
    for field in (
        "sourceRunID",
        "sourceRunAttempt",
        "authorityRunID",
        "authorityRunAttempt",
    ):
        positive_integer(receipt[field], f"toolchain authority receipt {field}")
    for field in (
        "authorityEnvelopeSHA256",
        "sourceReleaseRequestSHA256",
        "unsignedManifestSHA256",
        "signedManifestFileSHA256",
    ):
        if not isinstance(receipt[field], str) or not SHA256.fullmatch(receipt[field]):
            fail(f"toolchain authority receipt {field} is invalid")
    signed_at = receipt["signedAt"]
    if not isinstance(signed_at, str):
        fail("toolchain authority receipt signedAt is invalid")
    try:
        parsed_signed_at = datetime.strptime(signed_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        fail(f"toolchain authority receipt signedAt is invalid: {error}")
    if parsed_signed_at.strftime("%Y-%m-%dT%H:%M:%SZ") != signed_at:
        fail("toolchain authority receipt signedAt is not canonical UTC")

    validate_source_artifacts(
        receipt["sourceArtifacts"],
        toolchain_version=toolchain_version,
        label="toolchain authority receipt",
    )

    manifest_bytes = manifest_path.read_bytes()
    if manifest_bytes != signature_json_bytes(manifest):
        fail("signed toolchain manifest is not canonical compact JSON")
    unsigned_manifest = dict(manifest)
    unsigned_manifest["signatureEd25519"] = ""
    if (
        receipt["unsignedManifestSHA256"]
        != hashlib.sha256(signature_json_bytes(unsigned_manifest)).hexdigest()
        or receipt["signedManifestFileSHA256"]
        != hashlib.sha256(manifest_bytes).hexdigest()
    ):
        fail("toolchain authority receipt does not bind the signed manifest")

    require_regular_file(
        trust_root_path,
        "tracked toolchain public key",
        maximum_size=1_024,
    )
    public_key = decode_base64(
        trust_root_path.read_text(encoding="ascii").strip(),
        "toolchain public key",
        32,
    )
    if receipt["keyID"] != hashlib.sha256(public_key).hexdigest():
        fail("toolchain authority receipt key identifier is invalid")
    signature = decode_base64(
        receipt["signatureEd25519"], "toolchain authority receipt signature", 64
    )
    unsigned_receipt = dict(receipt)
    unsigned_receipt["signatureEd25519"] = ""
    if not verify_ed25519(
        public_key,
        AUTHORITY_RECEIPT_SIGNATURE_DOMAIN + signature_json_bytes(unsigned_receipt),
        signature,
    ):
        fail("toolchain authority receipt signature is invalid")
    return receipt


def validate_toolchain_authority_closure(
    release_request_path: Path,
    envelope_path: Path,
    receipt_path: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    trust_root_path: Path,
    *,
    source_repository: str,
    toolchain_version: str,
) -> dict[str, dict[str, Any]]:
    request = validate_toolchain_release_request(
        release_request_path,
        manifest,
        source_repository=source_repository,
    )
    envelope = validate_toolchain_authority_envelope(
        envelope_path,
        release_request_path,
        request,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
    )
    receipt = validate_toolchain_authority_receipt(
        receipt_path,
        manifest_path,
        manifest,
        trust_root_path,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
    )
    shared_fields = (
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
    if any(receipt[field] != envelope[field] for field in shared_fields):
        fail("toolchain authority receipt and envelope identity differ")
    if (
        receipt["sourceReleaseRequestSHA256"]
        != sha256_file(release_request_path, limit=64 * 1_024 * 1_024)
        or receipt["authorityEnvelopeSHA256"]
        != sha256_file(envelope_path, limit=64 * 1_024 * 1_024)
        or receipt["unsignedManifestSHA256"] != request["manifestSHA256"]
    ):
        fail("toolchain authority receipt does not bind its provenance closure")
    return {"request": request, "envelope": envelope, "receipt": receipt}


def api_json(url: str, token: str) -> dict[str, Any]:
    if not token:
        fail("a read-only GitHub token is required for publication verification")
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "EasySplat-publication-verifier",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) > 16 * 1_024 * 1_024:
                fail("GitHub API response is too large")
            raw = response.read(16 * 1_024 * 1_024 + 1)
    except (OSError, urllib.error.URLError, ValueError) as error:
        fail(f"GitHub API request failed: {error}")
    if len(raw) > 16 * 1_024 * 1_024:
        fail("GitHub API response is too large")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"GitHub API returned invalid JSON: {error}")
    if not isinstance(payload, dict):
        fail("GitHub API response must be an object")
    return payload


def validate_remote_toolchain_assets(
    manifest_path: Path,
    release_request_path: Path,
    authority_envelope_path: Path,
    authority_receipt_path: Path,
    manifest: dict[str, Any],
    *,
    source_repository: str,
    toolchain_version: str,
    github_token: str,
) -> None:
    quoted_repo = "/".join(
        urllib.parse.quote(part, safe="") for part in source_repository.split("/")
    )
    quoted_tag = urllib.parse.quote(f"toolchain-v{toolchain_version}", safe="")
    release = api_json(
        f"https://api.github.com/repos/{quoted_repo}/releases/tags/{quoted_tag}",
        github_token,
    )
    if (
        release.get("tag_name") != f"toolchain-v{toolchain_version}"
        or release.get("draft") is not False
        or release.get("immutable") is not True
    ):
        fail("published toolchain release identity is invalid")
    assets = release.get("assets")
    if not isinstance(assets, list):
        fail("published toolchain release assets are unavailable")
    by_name: dict[str, dict[str, Any]] = {}
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            fail("published toolchain asset record is invalid")
        name = asset["name"]
        if name in by_name:
            fail(f"published toolchain release has duplicate asset {name}")
        by_name[name] = asset
    expected: dict[str, tuple[int, str, str]] = {
        "manifest.json": (
            manifest_path.stat().st_size,
            sha256_file(manifest_path),
            f"https://github.com/{source_repository}/releases/download/toolchain-v{toolchain_version}/manifest.json",
        ),
        "authority-receipt.json": (
            authority_receipt_path.stat().st_size,
            sha256_file(authority_receipt_path),
            f"https://github.com/{source_repository}/releases/download/toolchain-v{toolchain_version}/authority-receipt.json",
        ),
        "authority-envelope.json": (
            authority_envelope_path.stat().st_size,
            sha256_file(authority_envelope_path),
            f"https://github.com/{source_repository}/releases/download/toolchain-v{toolchain_version}/authority-envelope.json",
        ),
        "toolchain-release-request.json": (
            release_request_path.stat().st_size,
            sha256_file(release_request_path),
            f"https://github.com/{source_repository}/releases/download/toolchain-v{toolchain_version}/toolchain-release-request.json",
        ),
    }
    for component in manifest["components"]:
        name = Path(component["url"]).name
        expected[name] = (component["sizeBytes"], component["sha256"], component["url"])
    for name, (size, digest, download_url) in expected.items():
        asset = by_name.get(name)
        if asset is None:
            fail(f"published toolchain asset is missing: {name}")
        if asset.get("size") != size or asset.get("digest") != f"sha256:{digest}":
            fail(f"published toolchain asset size or digest differs: {name}")
        if asset.get("browser_download_url") != download_url:
            fail(f"published toolchain asset URL differs: {name}")
    if set(by_name) != set(expected):
        fail("published toolchain release asset closure is not exact")


def full_toolchain_identity(manifest: dict[str, Any]) -> str:
    component_fields = (
        "name",
        "capabilities",
        "url",
        "sha256",
        "sizeBytes",
        "expandedSizeBytes",
        "contents",
        "criticalFileHashes",
        "dependencies",
        "requirement",
    )
    components = sorted(
        (
            {field: component[field] for field in component_fields}
            for component in manifest["components"]
        ),
        key=lambda component: component["name"],
    )
    closure = {
        "schema_version": 2,
        "toolchain_api": 2,
        "key_id": manifest["keyID"],
        "version": manifest["version"],
        "app_version_range": {
            "minimum": manifest["appVersionRange"]["minimum"],
            "maximum_exclusive": manifest["appVersionRange"]["maximumExclusive"],
        },
        "signature_ed25519": manifest["signatureEd25519"],
        "components": components,
        "installed_artifacts": {
            component["name"]: component["sha256"] for component in components
        },
        "installed_capabilities": sorted(
            {
                capability
                for component in components
                for capability in component["capabilities"]
            }
        ),
    }
    digest = hashlib.sha256()
    for value in (
        b"easysplat-benchmark-toolchain-v2",
        signature_json_bytes(closure),
    ):
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)
    return "sha256:" + digest.hexdigest()


def validate_release_notes(path: Path, *, app_version: str) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"release notes are invalid: {error}")
    expected = (
        f"EasySplat {app_version} is an unsigned public beta.\n"
        "macOS will require the user to confirm opening an app from an unidentified developer.\n"
    )
    if text != expected:
        fail("release notes do not exactly describe the unsigned public beta")


def validate_benchmark_suite(
    path: Path,
    *,
    app_version: str,
    source_commit: str,
    toolchain_identity: str,
) -> dict[str, Any]:
    payload = load_json(path, "verified benchmark suite", limit=128 * 1_024 * 1_024)
    expected_keys = {
        "schema_version",
        "run_id",
        "started_at_utc",
        "ended_at_utc",
        "profile",
        "status",
        "blocking_reasons",
        "failures",
        "scene_results",
        "aggregates",
        "machine",
        "app_version",
        "toolchain_identity",
        "thresholds_digest",
        "corpus_digest",
        "git",
        "raw_evidence_retention",
        "missing_requirements",
    }
    require_exact_keys(payload, expected_keys, "verified benchmark suite")
    if payload["schema_version"] != 1 or payload["profile"] != "release":
        fail("verified benchmark suite schema or profile is invalid")
    if (
        payload["status"] != "passed"
        or payload["blocking_reasons"] != []
        or payload["failures"] != []
    ):
        fail("verified benchmark suite did not pass")
    if payload["app_version"] != app_version:
        fail("verified benchmark suite app version differs")
    if payload["git"] != {"commit": source_commit, "dirty": False}:
        fail("verified benchmark suite source identity differs")
    if payload["raw_evidence_retention"] != "excluded":
        fail("verified benchmark suite must exclude raw evidence")
    missing = payload["missing_requirements"]
    if not isinstance(missing, dict) or any(
        value not in (None, []) for value in missing.values()
    ):
        fail("verified benchmark suite still has missing requirements")
    if payload["toolchain_identity"] != toolchain_identity:
        fail("verified benchmark suite used a different signed toolchain closure")
    return payload


def validate_publication_output_root(root: Path) -> None:
    if root.exists():
        if root.is_symlink() or not root.is_dir() or any(root.iterdir()):
            fail("publication output must be absent or an empty real directory")
    else:
        root.mkdir(parents=True)


def verify_and_prepare_publication(
    *,
    bundle: Path,
    output: Path,
    benchmark_suite: Path,
    toolchain_public_key: Path,
    app_version: str,
    toolchain_version: str,
    source_repository: str,
    source_commit: str,
    tag: str,
    benchmark_run_id: str,
    benchmark_artifact_id: str,
    benchmark_artifact_digest: str,
    github_token: str,
) -> None:
    validate_build_bundle(
        bundle,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        tag=tag,
        benchmark_run_id=benchmark_run_id,
        benchmark_artifact_id=benchmark_artifact_id,
        benchmark_artifact_digest=benchmark_artifact_digest,
    )
    stem = f"EasySplat-{app_version}"
    dmg = bundle / f"{stem}-unsigned.dmg"
    checksum = bundle / f"{stem}-unsigned.dmg.sha256"
    provenance_path = bundle / f"{stem}.provenance.json"
    spdx = bundle / f"{stem}.spdx.json"
    licenses = bundle / f"{stem}-licenses.zip"
    dsym = bundle / f"{stem}-dSYM.zip"
    notes = bundle / f"{stem}-release-notes.txt"
    manifest_path = bundle / "toolchain-manifest.json"
    release_request_path = bundle / TOOLCHAIN_RELEASE_REQUEST_NAME
    authority_envelope_path = bundle / TOOLCHAIN_AUTHORITY_ENVELOPE_NAME
    authority_receipt_path = bundle / TOOLCHAIN_AUTHORITY_RECEIPT_NAME

    validate_dmg_checksum(dmg, checksum)
    provenance = validate_provenance(
        provenance_path,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
        source_commit=source_commit,
        dmg=dmg,
        manifest=manifest_path,
    )
    validate_release_notes(notes, app_version=app_version)
    manifest = validate_toolchain_manifest(
        manifest_path,
        toolchain_public_key,
        app_version=app_version,
        toolchain_version=toolchain_version,
        source_repository=source_repository,
    )
    validate_release_timestamps(provenance, manifest)
    license_closure = validate_license_archive(
        licenses,
        provenance,
        manifest,
        toolchain_version=toolchain_version,
    )
    validate_spdx(
        spdx,
        provenance=provenance,
        license_closure=license_closure,
        licenses_name=licenses.name,
    )
    validate_toolchain_authority_closure(
        release_request_path,
        authority_envelope_path,
        authority_receipt_path,
        manifest_path,
        manifest,
        toolchain_public_key,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
    )
    validate_remote_toolchain_assets(
        manifest_path,
        release_request_path,
        authority_envelope_path,
        authority_receipt_path,
        manifest,
        source_repository=source_repository,
        toolchain_version=toolchain_version,
        github_token=github_token,
    )
    validate_benchmark_suite(
        benchmark_suite,
        app_version=app_version,
        source_commit=source_commit,
        toolchain_identity=full_toolchain_identity(manifest),
    )

    # The DMG is mounted read-only. Its binary is only parsed by system inspection tools.
    with mounted_dmg(dmg) as mount:
        if {entry.name for entry in mount.iterdir()} != {
            "EasySplat.app",
            "Applications",
        }:
            fail("DMG root allowlist is invalid")
        applications = mount / "Applications"
        if (
            not applications.is_symlink()
            or os.readlink(applications) != "/Applications"
        ):
            fail("DMG Applications link is invalid")
        app = mount / "EasySplat.app"
        app_uuid = validate_app_bundle(
            app,
            app_version=app_version,
            toolchain_version=toolchain_version,
            source_repository=source_repository,
            toolchain_public_key=toolchain_public_key,
        )
        app_binary = app / "Contents/MacOS/EasySplatApp"
        validate_dsym_archive(dsym, app_binary)
        if app_uuid != parse_uuid(
            run_static([SYSTEM_TOOLS["dwarfdump"], "--uuid", str(app_binary)]).stdout,
            "app executable",
        ):
            fail("app UUID changed during static verification")

    # Provenance toolchain records must agree with the signed manifest.
    manifest_records = {
        component["name"]: component for component in manifest["components"]
    }
    provenance_map = {
        "core": "macos-arm64-core",
        "geometry-da3-base": "geometry-da3-base",
        "geometry-da3-small": "geometry-da3-small",
    }
    for provenance_name, component_name in provenance_map.items():
        row = provenance["artifacts"][provenance_name]
        component = manifest_records[component_name]
        if (
            row["downloadURL"] != component["url"]
            or row["sha256"] != component["sha256"]
            or row["size"] != component["sizeBytes"]
        ):
            fail(f"provenance and signed manifest differ for {provenance_name}")

    validate_publication_output_root(output)
    public_names = publication_payload_names(app_version)
    benchmark_name = f"{stem}-benchmark.json"
    source_by_name = {
        name: bundle / name for name in public_names if name != benchmark_name
    }
    source_by_name[benchmark_name] = benchmark_suite
    for name in public_names:
        shutil.copyfile(source_by_name[name], output / name)
    limits = publication_file_limits(app_version)
    require_exact_directory(output, limits, label="publication payload")
    manifest_payload = {
        "schema_version": 1,
        "app_version": app_version,
        "toolchain_version": toolchain_version,
        "source_repository": source_repository,
        "source_commit": source_commit,
        "tag": tag,
        "release_mode": "unsigned-beta",
        "benchmark": {
            "run_id": benchmark_run_id,
            "artifact_id": benchmark_artifact_id,
            "artifact_digest": benchmark_artifact_digest,
            "suite_sha256": sha256_file(benchmark_suite, limit=128 * 1_024 * 1_024),
        },
        "files": [
            file_record(output / name, maximum_size=limits[name])
            for name in sorted(limits)
        ],
    }
    with (output / PUBLICATION_MANIFEST_NAME).open("xb") as stream:
        stream.write(canonical_json_bytes(manifest_payload))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    def add_identity(command: argparse.ArgumentParser) -> None:
        command.add_argument("--app-version", required=True)
        command.add_argument("--toolchain-version", required=True)
        command.add_argument("--source-repository", required=True)
        command.add_argument("--source-commit", required=True)
        command.add_argument("--tag", required=True)
        command.add_argument("--benchmark-run-id", required=True)
        command.add_argument("--benchmark-artifact-id", required=True)
        command.add_argument("--benchmark-artifact-digest", required=True)

    create = commands.add_parser("create-build-closure")
    create.add_argument("--bundle", type=Path, required=True)
    add_identity(create)

    verify = commands.add_parser("verify-build")
    verify.add_argument("--bundle", type=Path, required=True)
    verify.add_argument("--output", type=Path, required=True)
    verify.add_argument("--benchmark-suite", type=Path, required=True)
    verify.add_argument("--toolchain-public-key", type=Path, required=True)
    verify.add_argument("--github-token-env", default="GITHUB_TOKEN")
    add_identity(verify)
    return root


def main(arguments: list[str] | None = None) -> int:
    args = parser().parse_args(arguments)
    try:
        identity = {
            "app_version": args.app_version,
            "toolchain_version": args.toolchain_version,
            "source_repository": args.source_repository,
            "source_commit": args.source_commit,
            "tag": args.tag,
            "benchmark_run_id": args.benchmark_run_id,
            "benchmark_artifact_id": args.benchmark_artifact_id,
            "benchmark_artifact_digest": args.benchmark_artifact_digest,
        }
        if args.command == "create-build-closure":
            create_build_closure(args.bundle, **identity)
        else:
            verify_and_prepare_publication(
                bundle=args.bundle,
                output=args.output,
                benchmark_suite=args.benchmark_suite,
                toolchain_public_key=args.toolchain_public_key,
                github_token=os.environ.get(args.github_token_env, ""),
                **identity,
            )
    except PublicationError as error:
        print(f"Publication verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
