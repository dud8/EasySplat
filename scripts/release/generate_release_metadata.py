#!/usr/bin/env python3
"""Generate and verify EasySplat release provenance, SPDX, and licenses."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import struct
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, NoReturn
from urllib.parse import quote, urlparse


COMPONENTS_PATH = "supply-chain/components.json"
LICENSE_COMPONENTS_PATH = "Toolchain/supply-chain/components.json"
ARCHIVE_CLOSURE_PATH = "toolchain-closure.json"
ARCHIVE_ORDER = ("core", "geometry-da3-base", "geometry-da3-small")
MANIFEST_COMPONENT_NAMES = {
    "core": "macos-arm64-core",
    "geometry-da3-base": "geometry-da3-base",
    "geometry-da3-small": "geometry-da3-small",
}
PLACEHOLDER = re.compile(r"(?:^|[^A-Za-z])(unknown|noassertion|none)(?:$|[^A-Za-z])", re.I)
SHA256 = re.compile(r"[0-9a-f]{64}")
SOURCE_REVISION = re.compile(r"[0-9a-f]{7,64}")
LICENSE_REF = re.compile(r"LicenseRef-[A-Za-z0-9.-]+")
METALSPLATTER_SOURCE = "https://github.com/scier/MetalSplatter"
METALSPLATTER_BASE_REVISION = "c0f066fb7146d46d9b68e5c76d7d0a6154facc5e"
METALSPLATTER_SOURCE_ROOTS = (
    "MetalSplatter",
    "PLYIO/Sources",
    "SplatIO/Sources",
)
MAX_CORE_DOWNLOAD_BYTES = 2_500_000_000
MAX_FULL_TOOLCHAIN_DOWNLOAD_BYTES = 6_000_000_000
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64_ALL = 0
THIN_64_MACHO_ENDIAN = {
    b"\xcf\xfa\xed\xfe": "<",
    b"\xfe\xed\xfa\xcf": ">",
}


class MetadataError(ValueError):
    pass


def fail(message: str) -> NoReturn:
    raise MetadataError(message)


def reject_semver_build_metadata(value: str, label: str) -> None:
    if "+" in value:
        fail(f"{label} must not contain semantic version build metadata")


def sha256_stream(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def validate_thin_arm64_macho_header(header: bytes, path: str) -> None:
    if len(header) < 12:
        fail(f"Mach-O archive entry has a truncated header: {path}")
    endian = THIN_64_MACHO_ENDIAN.get(header[:4])
    if endian is None:
        fail(f"Mach-O archive entry is not a thin 64-bit binary: {path}")
    cpu_type, cpu_subtype = struct.unpack(f"{endian}II", header[4:12])
    if cpu_type != CPU_TYPE_ARM64 or (cpu_subtype & 0x00FFFFFF) != CPU_SUBTYPE_ARM64_ALL:
        fail(f"Mach-O archive entry must be arm64-only: {path}")


def sha256_arm64_macho_stream(stream: BinaryIO, path: str) -> str:
    header = stream.read(12)
    validate_thin_arm64_macho_header(header, path)
    digest = hashlib.sha256(header)
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: Path) -> str:
    try:
        with path.open("rb") as stream:
            return sha256_stream(stream)
    except OSError as exc:
        fail(f"cannot hash {path}: {exc}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def vendored_viewer_source(viewer_license: Path) -> tuple[str, int]:
    root = viewer_license.parent
    paths = [root / "Package.swift", root / "LICENSE"]
    for source_root in METALSPLATTER_SOURCE_ROOTS:
        directory = root / source_root
        if not directory.is_dir():
            fail(f"MetalSplatter source directory is missing: {directory}")
        paths.extend(path for path in directory.rglob("*") if path.is_file())

    digest = hashlib.sha256()
    count = 0
    for path in sorted(set(paths), key=lambda candidate: candidate.relative_to(root).as_posix()):
        if path.is_symlink() or not path.is_file():
            fail(f"MetalSplatter source entry must be a regular file: {path}")
        relative = safe_archive_path(path.relative_to(root).as_posix(), "MetalSplatter source path")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(path)))
        count += 1
    if count < 4:
        fail("MetalSplatter source closure is unexpectedly small")
    return digest.hexdigest(), count


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def validate_normal_photo_install_size(sizes: dict[str, int]) -> None:
    if set(sizes) != set(ARCHIVE_ORDER):
        fail("normal photo install size requires all release archives")
    if any(not isinstance(size, int) or size <= 0 for size in sizes.values()):
        fail("normal photo install archive sizes must be positive integers")
    core_size = sizes["core"]
    if core_size > MAX_CORE_DOWNLOAD_BYTES:
        fail(f"core-only toolchain download exceeds 2.5 GB: {core_size} bytes")
    total = sum(sizes.values())
    if total > MAX_FULL_TOOLCHAIN_DOWNLOAD_BYTES:
        fail(f"full optional toolchain download exceeds 6 GB: {total} bytes")


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid {label} at {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or PLACEHOLDER.fullmatch(value.strip()):
        fail(f"{label} is empty or uses a placeholder")
    return value.strip()


def require_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        fail(f"{label} must be a string array")
    if value != sorted(value) or len(value) != len(set(value)):
        fail(f"{label} must be sorted and unique")
    return value


def validate_https_url(value: Any, label: str, *, allow_loopback: bool = False) -> str:
    url = require_text(value, label)
    parsed = urlparse(url)
    loopback = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if not parsed.hostname or parsed.username or parsed.password:
        fail(f"{label} is not a credential-free URL")
    if parsed.scheme != "https" and not (allow_loopback and parsed.scheme == "http" and loopback):
        fail(f"{label} must use HTTPS")
    return url


def safe_archive_path(raw: str, label: str) -> str:
    if not raw or "\\" in raw or "\x00" in raw:
        fail(f"unsafe {label}: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or raw.startswith("./") or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"unsafe {label}: {raw!r}")
    return path.as_posix()


def validate_symlink_target(path: str, target: Any) -> str:
    if not isinstance(target, str) or not target or "\\" in target or "\x00" in target:
        fail(f"unsafe symlink target for {path}")
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        fail(f"absolute symlink target for {path}")
    resolved: list[str] = []
    for part in (*PurePosixPath(path).parent.parts, *target_path.parts):
        if part in {"", "."}:
            continue
        if part == "..":
            if not resolved:
                fail(f"escaping symlink target for {path}")
            resolved.pop()
        else:
            resolved.append(part)
    if not resolved:
        fail(f"empty resolved symlink target for {path}")
    return target


def is_zip_symlink(info: zipfile.ZipInfo) -> bool:
    return stat.S_IFMT(info.external_attr >> 16) == stat.S_IFLNK


def archive_for_path(path: str) -> str:
    if path.startswith("da3_mps/models/DA3-SMALL/"):
        return "geometry-da3-small"
    if path.startswith("da3_mps/"):
        return "geometry-da3-base"
    return "core"


def archive_expanded_size(path: Path) -> int:
    total = 0
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                if is_zip_symlink(info):
                    fail(f"release archive contains a symbolic link: {info.filename}")
                total += info.file_size
                if total > 16 * 1024 * 1024 * 1024:
                    fail(f"release archive expands beyond 16 GiB: {path}")
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        fail(f"cannot inspect expanded archive size for {path}: {exc}")
    if total <= 0:
        fail(f"release archive has no regular file payload: {path}")
    return total


@dataclass(frozen=True)
class ArchiveSpec:
    identifier: str
    path: Path
    download_url: str


@dataclass
class ValidatedClosure:
    payload: dict[str, Any]
    raw: bytes
    components: dict[str, dict[str, Any]]
    files: dict[str, dict[str, Any]]
    license_bytes: dict[str, bytes]
    archive_rows: dict[str, list[dict[str, Any]]]


def read_components(core: Path) -> tuple[dict[str, Any], bytes]:
    try:
        with zipfile.ZipFile(core) as archive:
            matches = [entry for entry in archive.infolist() if entry.filename == COMPONENTS_PATH]
            if len(matches) != 1 or matches[0].is_dir() or is_zip_symlink(matches[0]):
                fail(f"core archive must contain one regular {COMPONENTS_PATH}")
            if matches[0].file_size > 64 * 1024 * 1024:
                fail("components.json is unreasonably large")
            raw = archive.read(matches[0])
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        fail(f"cannot read core archive {core}: {exc}")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid {COMPONENTS_PATH}: {exc}")
    if not isinstance(payload, dict):
        fail("components.json must be an object")
    return payload, raw


def validate_component_payload(
    payload: dict[str, Any], expected_version: str
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], set[str]]:
    if payload.get("schemaVersion") != 1 or payload.get("toolchainVersion") != expected_version:
        fail("components.json has the wrong schema or toolchain version")
    component_rows = payload.get("components")
    file_rows = payload.get("files")
    if not isinstance(component_rows, list) or not component_rows:
        fail("components.json has no components")
    if not isinstance(file_rows, list) or not file_rows:
        fail("components.json has no files")

    components: dict[str, dict[str, Any]] = {}
    component_ids: list[str] = []
    for index, component in enumerate(component_rows):
        if not isinstance(component, dict):
            fail(f"component {index} is not an object")
        component_id = require_text(component.get("id"), f"component {index} id")
        if component_id in components:
            fail(f"duplicate component id: {component_id}")
        component_ids.append(component_id)
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
            require_text(component.get(field), f"component {component_id} {field}")
        validate_https_url(component["source"], f"component {component_id} source")
        license_files = require_string_list(
            component.get("licenseFiles"), f"component {component_id} licenseFiles"
        )
        if not license_files:
            fail(f"component {component_id} has no mapped license file")
        require_string_list(component.get("dependencies"), f"component {component_id} dependencies")
        require_string_list(component.get("files"), f"component {component_id} files")
        if "incorporatedInto" in component:
            require_string_list(
                component["incorporatedInto"], f"component {component_id} incorporatedInto"
            )
        artifact = component.get("artifact")
        artifact_sha = component.get("artifactSha256")
        if artifact is not None or artifact_sha is not None:
            validate_https_url(artifact, f"component {component_id} artifact")
            if not isinstance(artifact_sha, str) or not SHA256.fullmatch(artifact_sha):
                fail(f"component {component_id} artifact SHA-256 is invalid")
        components[component_id] = component
    if component_ids != sorted(component_ids):
        fail("components must be sorted by id")

    files: dict[str, dict[str, Any]] = {}
    file_paths: list[str] = []
    owned: dict[str, list[str]] = {component_id: [] for component_id in components}
    for index, row in enumerate(file_rows):
        if not isinstance(row, dict):
            fail(f"file row {index} is not an object")
        path = safe_archive_path(require_text(row.get("path"), f"file row {index} path"), "closure path")
        if path == COMPONENTS_PATH:
            fail(f"{COMPONENTS_PATH} is self-describing and must not hash itself")
        if path in files:
            fail(f"duplicate closure file: {path}")
        component_id = require_text(row.get("component"), f"file {path} component")
        if component_id not in components:
            fail(f"file {path} maps to missing component {component_id}")
        kind = row.get("kind")
        if kind == "symlink":
            validate_symlink_target(path, row.get("target"))
            if "sha256" in row or "size" in row:
                fail(f"symlink closure row must not claim file bytes: {path}")
        elif kind in {"file", "mach-o"}:
            digest = row.get("sha256")
            size = row.get("size")
            if not isinstance(digest, str) or not SHA256.fullmatch(digest):
                fail(f"file {path} has an invalid SHA-256")
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                fail(f"file {path} has an invalid size")
            if kind == "mach-o":
                dependencies = row.get("dependencies")
                if not isinstance(dependencies, list) or any(
                    not isinstance(dependency, str) or not dependency for dependency in dependencies
                ):
                    fail(f"Mach-O {path} has invalid dependency metadata")
        else:
            fail(f"file {path} has unsupported kind {kind!r}")
        files[path] = row
        file_paths.append(path)
        owned[component_id].append(path)
    if file_paths != sorted(file_paths):
        fail("closure files must be sorted by path")

    license_paths: set[str] = set()
    for component_id, component in components.items():
        if component["files"] != sorted(owned[component_id]):
            fail(f"component {component_id} file list does not match closure ownership")
        for dependency in component["dependencies"]:
            if dependency not in components:
                fail(f"component {component_id} depends on missing component {dependency}")
            if dependency == component_id:
                fail(f"component {component_id} depends on itself")
        for target in component.get("incorporatedInto", []):
            if target not in components or target == component_id:
                fail(f"component {component_id} has invalid incorporatedInto target {target}")
        for license_path in component["licenseFiles"]:
            safe_archive_path(license_path, "license path")
            file_row = files.get(license_path)
            if file_row is None or file_row.get("kind") == "symlink":
                fail(f"component {component_id} license is not a mapped regular file: {license_path}")
            license_paths.add(license_path)
    return components, files, license_paths


def inspect_archive(
    spec: ArchiveSpec,
    expected: dict[str, dict[str, Any]],
    license_paths: set[str],
) -> tuple[list[dict[str, Any]], dict[str, bytes]]:
    expected_paths = set(expected)
    if spec.identifier == "core":
        expected_paths.add(COMPONENTS_PATH)
    seen: set[str] = set()
    rows: list[dict[str, Any]] = []
    licenses: dict[str, bytes] = {}
    try:
        with zipfile.ZipFile(spec.path) as archive:
            for info in archive.infolist():
                raw_name = info.filename[:-1] if info.is_dir() and info.filename.endswith("/") else info.filename
                path = safe_archive_path(raw_name, f"{spec.identifier} archive entry")
                if info.is_dir():
                    continue
                if info.flag_bits & 0x1:
                    fail(f"encrypted archive entry is forbidden: {path}")
                if path in seen:
                    fail(f"duplicate archive entry in {spec.identifier}: {path}")
                seen.add(path)
                if path == COMPONENTS_PATH:
                    if spec.identifier != "core" or is_zip_symlink(info):
                        fail(f"unexpected {COMPONENTS_PATH} entry")
                    continue
                row = expected.get(path)
                if row is None:
                    fail(f"unmapped archive file in {spec.identifier}: {path}")
                kind = row["kind"]
                if kind == "symlink":
                    if not is_zip_symlink(info):
                        fail(f"archive materialized closure symlink as a file: {path}")
                    target_bytes = archive.read(info)
                    try:
                        target = target_bytes.decode("utf-8")
                    except UnicodeDecodeError:
                        fail(f"symlink target is not UTF-8: {path}")
                    validate_symlink_target(path, target)
                    if target != row["target"]:
                        fail(f"symlink target mismatch: {path}")
                else:
                    if is_zip_symlink(info):
                        fail(f"archive replaced regular file with a symlink: {path}")
                    if info.file_size != row["size"]:
                        fail(f"size mismatch for {path}")
                    with archive.open(info) as stream:
                        if kind == "mach-o":
                            digest = sha256_arm64_macho_stream(stream, path)
                        else:
                            digest = sha256_stream(stream)
                    if digest != row["sha256"]:
                        fail(f"checksum mismatch for {path}")
                    if path in license_paths:
                        licenses[path] = archive.read(info)
                rows.append(dict(row))
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        fail(f"cannot inspect {spec.identifier} archive {spec.path}: {exc}")
    if seen != expected_paths:
        missing = sorted(expected_paths - seen)
        extra = sorted(seen - expected_paths)
        fail(f"{spec.identifier} archive closure mismatch; missing={missing[:5]} extra={extra[:5]}")
    return sorted(rows, key=lambda row: row["path"]), licenses


def validate_archives(specs: dict[str, ArchiveSpec], expected_version: str) -> ValidatedClosure:
    reject_semver_build_metadata(expected_version, "toolchain version")
    if set(specs) != set(ARCHIVE_ORDER):
        fail("release requires core, DA3 Base, and DA3 Small archives")
    validate_normal_photo_install_size({
        identifier: specs[identifier].path.stat().st_size for identifier in ARCHIVE_ORDER
    })
    payload, raw = read_components(specs["core"].path)
    components, files, license_paths = validate_component_payload(payload, expected_version)
    archive_rows: dict[str, list[dict[str, Any]]] = {}
    license_bytes: dict[str, bytes] = {}
    for identifier in ARCHIVE_ORDER:
        expected = {
            path: row for path, row in files.items() if archive_for_path(path) == identifier
        }
        rows, archive_licenses = inspect_archive(specs[identifier], expected, license_paths)
        archive_rows[identifier] = rows
        for path, data in archive_licenses.items():
            if path in license_bytes:
                fail(f"license file appears in multiple archives: {path}")
            license_bytes[path] = data
    if set(license_bytes) != license_paths:
        fail(f"license closure is incomplete: {sorted(license_paths - set(license_bytes))[:5]}")
    return ValidatedClosure(payload, raw, components, files, license_bytes, archive_rows)


def validate_manifest(
    path: Path, toolchain_version: str, specs: dict[str, ArchiveSpec]
) -> str:
    manifest = load_json(path, "signed toolchain manifest")
    if manifest.get("schemaVersion") != 2 or manifest.get("toolchainAPI") != 2:
        fail("toolchain manifest must use schema and API 2")
    if manifest.get("version") != toolchain_version:
        fail("toolchain manifest version does not match the release")
    published_at = require_text(manifest.get("publishedAt"), "manifest publishedAt")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", published_at):
        fail("manifest publishedAt must be a UTC ISO-8601 timestamp")
    require_text(manifest.get("keyID"), "manifest keyID")
    require_text(manifest.get("signatureEd25519"), "manifest signature")
    rows = manifest.get("components")
    if not isinstance(rows, list):
        fail("toolchain manifest components are missing")
    by_name: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            fail("toolchain manifest component is not an object")
        name = require_text(row.get("name"), "manifest component name")
        if name in by_name:
            fail(f"duplicate manifest component: {name}")
        by_name[name] = row
    expected_names = set(MANIFEST_COMPONENT_NAMES.values())
    if set(by_name) != expected_names:
        fail("toolchain manifest component set does not match release archives")
    for identifier, component_name in MANIFEST_COMPONENT_NAMES.items():
        row = by_name[component_name]
        spec = specs[identifier]
        url = validate_https_url(row.get("url"), f"manifest {component_name} URL", allow_loopback=True)
        if url != spec.download_url:
            fail(f"manifest URL mismatch for {component_name}")
        if (
            row.get("sha256") != sha256_file(spec.path)
            or row.get("sizeBytes") != spec.path.stat().st_size
            or row.get("expandedSizeBytes") != archive_expanded_size(spec.path)
        ):
            fail(f"manifest checksum or size mismatch for {component_name}")
    return published_at


def artifact_row(path: Path, download_url: str) -> dict[str, Any]:
    validate_https_url(download_url, f"download URL for {path.name}", allow_loopback=True)
    return {
        "file": path.name,
        "downloadURL": download_url,
        "sha256": sha256_file(path),
        "size": path.stat().st_size,
    }


def release_asset_url(source_url: str, app_version: str, file_name: str) -> str:
    reject_semver_build_metadata(app_version, "app version")
    root = source_url.removesuffix(".git").rstrip("/")
    return f"{root}/releases/download/v{quote(app_version, safe='.-')}/{quote(file_name)}"


def build_provenance(
    *,
    app_version: str,
    toolchain_version: str,
    release_mode: str,
    source_url: str,
    source_commit: str,
    created_at: str,
    dmg: Path,
    manifest: Path,
    manifest_url: str,
    specs: dict[str, ArchiveSpec],
    closure: ValidatedClosure,
    viewer_license: Path,
) -> dict[str, Any]:
    source_url = validate_https_url(source_url, "source URL")
    if not SOURCE_REVISION.fullmatch(source_commit):
        fail("source commit must be a hexadecimal revision")
    artifacts = {
        "dmg": artifact_row(dmg, release_asset_url(source_url, app_version, dmg.name)),
        "manifest": artifact_row(manifest, manifest_url),
        "core": artifact_row(specs["core"].path, specs["core"].download_url),
        "geometry-da3-base": artifact_row(
            specs["geometry-da3-base"].path, specs["geometry-da3-base"].download_url
        ),
        "geometry-da3-small": artifact_row(
            specs["geometry-da3-small"].path, specs["geometry-da3-small"].download_url
        ),
    }
    viewer_digest, viewer_file_count = vendored_viewer_source(viewer_license)
    return {
        "schemaVersion": 2,
        "releaseMode": release_mode,
        "appVersion": app_version,
        "toolchainVersion": toolchain_version,
        "bundleIdentifier": "com.easysplat.app",
        "source": {
            "url": source_url,
            "commit": source_commit,
            "buildCommand": "./scripts/release/build_app.sh",
        },
        "sourceDependencies": {
            "MetalSplatter": {
                "source": METALSPLATTER_SOURCE,
                "basedOnRevision": METALSPLATTER_BASE_REVISION,
                "vendoredTreeSHA256": viewer_digest,
                "sourceFileCount": viewer_file_count,
                "license": "MIT",
                "buildCommand": "./scripts/release/build_app.sh",
                "integration": "statically linked with EasySplat compatibility changes",
            }
        },
        "createdAt": created_at,
        "supplyChain": {
            "schemaVersion": 1,
            "componentsSHA256": sha256_bytes(closure.raw),
            "componentCount": len(closure.components),
            "fileCount": len(closure.files),
        },
        "artifacts": artifacts,
    }


def spdx_id(prefix: str, value: str) -> str:
    label = re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-") or "item"
    return f"SPDXRef-{prefix}-{label}-{sha256_bytes(value.encode())[:8]}"


def external_refs(component: dict[str, Any]) -> list[dict[str, str]]:
    source = component["source"]
    revision = component["revision"]
    refs = [{
        "referenceCategory": "OTHER",
        "referenceType": "vcs",
        "referenceLocator": f"{source}#{revision}",
    }]
    parsed = urlparse(source)
    parts = [part for part in parsed.path.removesuffix(".git").split("/") if part]
    purl = ""
    if parsed.hostname == "github.com" and len(parts) == 2:
        purl = f"pkg:github/{quote(parts[0])}/{quote(parts[1])}@{quote(revision, safe='.-:')}"
    elif component["id"].startswith("python:"):
        purl = f"pkg:pypi/{quote(component['name'].lower())}@{quote(component['version'])}"
    elif component["id"].startswith("homebrew:"):
        purl = f"pkg:brew/{quote(component['name'])}@{quote(component['version'])}"
    if purl:
        refs.insert(0, {
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": purl,
        })
    return refs


def component_checksum(component: dict[str, Any], closure: ValidatedClosure) -> str:
    rows = [closure.files[path] for path in component["files"]]
    material: Any = rows or {
        key: component[key]
        for key in ("id", "version", "revision", "source", "license", "licenseFiles")
    }
    return sha256_bytes(canonical_json_bytes(material))


def build_spdx(
    provenance: dict[str, Any], closure: ValidatedClosure, licenses_name: str
) -> dict[str, Any]:
    source = provenance["source"]
    artifacts = provenance["artifacts"]
    app_id = "SPDXRef-Package-EasySplat"
    viewer_id = "SPDXRef-Package-MetalSplatter"
    viewer = provenance["sourceDependencies"]["MetalSplatter"]
    artifact_ids = {
        "manifest": "SPDXRef-Package-Toolchain-Manifest",
        "core": "SPDXRef-Package-Toolchain-Core",
        "geometry-da3-base": "SPDXRef-Package-Geometry-DA3-Base",
        "geometry-da3-small": "SPDXRef-Package-Geometry-DA3-Small",
    }
    component_ids = {
        component_id: spdx_id("Package-Component", component_id)
        for component_id in closure.components
    }
    packages: list[dict[str, Any]] = [{
        "SPDXID": app_id,
        "name": "EasySplat",
        "versionInfo": provenance["appVersion"],
        "packageFileName": artifacts["dmg"]["file"],
        "downloadLocation": artifacts["dmg"]["downloadURL"],
        "homepage": source["url"],
        "sourceInfo": f"Build command: {source['buildCommand']}",
        "filesAnalyzed": False,
        "checksums": [{"algorithm": "SHA256", "checksumValue": artifacts["dmg"]["sha256"]}],
        "licenseConcluded": "MIT",
        "licenseDeclared": "MIT",
        "copyrightText": "Copyright (c) 2026 EasySplat contributors",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": (
                f"pkg:github/dud8/EasySplat@{quote(source['commit'])}"
                if source["url"].rstrip("/").removesuffix(".git") == "https://github.com/dud8/EasySplat"
                else f"pkg:generic/EasySplat@{quote(provenance['appVersion'])}"
            ),
        }],
    }, {
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
        "checksums": [{
            "algorithm": "SHA256",
            "checksumValue": viewer["vendoredTreeSHA256"],
        }],
        "licenseConcluded": "MIT",
        "licenseDeclared": "MIT",
        "copyrightText": "Copyright information is provided by MetalSplatter/LICENSE.",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": (
                f"pkg:github/scier/MetalSplatter@{viewer['basedOnRevision']}"
            ),
        }, {
            "referenceCategory": "OTHER",
            "referenceType": "vcs",
            "referenceLocator": (
                f"{viewer['source']}#{viewer['basedOnRevision']}"
            ),
        }],
    }]
    artifact_licenses = {
        "manifest": "MIT",
        "core": "LicenseRef-EasySplat-Toolchain-Closure",
        "geometry-da3-base": "LicenseRef-EasySplat-Toolchain-Closure",
        "geometry-da3-small": "LicenseRef-EasySplat-Toolchain-Closure",
    }
    for identifier in ("manifest", *ARCHIVE_ORDER):
        row = artifacts[identifier]
        packages.append({
            "SPDXID": artifact_ids[identifier],
            "name": f"EasySplat-{identifier}",
            "versionInfo": provenance["toolchainVersion"],
            "packageFileName": row["file"],
            "downloadLocation": row["downloadURL"],
            "filesAnalyzed": False,
            "checksums": [{"algorithm": "SHA256", "checksumValue": row["sha256"]}],
            "licenseConcluded": artifact_licenses[identifier],
            "licenseDeclared": artifact_licenses[identifier],
            "copyrightText": "Copyright information is provided by the declared license files.",
        })
    for component_id in sorted(closure.components):
        component = closure.components[component_id]
        closure_checksum = component_checksum(component, closure)
        artifact_url = component.get("artifact")
        artifact_checksum = component.get("artifactSha256")
        packages.append({
            "SPDXID": component_ids[component_id],
            "name": component["name"],
            "versionInfo": component["version"],
            "downloadLocation": artifact_url or component["source"],
            "homepage": component["source"],
            "sourceInfo": (
                f"Pinned revision: {component['revision']}; "
                f"component closure SHA-256: {closure_checksum}; "
                f"build command: {component['buildCommand']}"
            ),
            "filesAnalyzed": False,
            "checksums": [{
                "algorithm": "SHA256",
                "checksumValue": artifact_checksum or closure_checksum,
            }],
            "licenseConcluded": component["license"],
            "licenseDeclared": component["license"],
            "copyrightText": "Copyright information is provided by the declared license files.",
            "externalRefs": external_refs(component),
        })

    relationships: list[dict[str, str]] = [{
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": app_id,
    }, {
        "spdxElementId": app_id,
        "relationshipType": "STATIC_LINK",
        "relatedSpdxElement": viewer_id,
    }]
    for identifier in ("manifest", *ARCHIVE_ORDER):
        relationships.append({
            "spdxElementId": app_id,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": artifact_ids[identifier],
        })
    for identifier in ARCHIVE_ORDER:
        owners = sorted({row["component"] for row in closure.archive_rows[identifier]})
        for owner in owners:
            relationships.append({
                "spdxElementId": artifact_ids[identifier],
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": component_ids[owner],
            })
    for component_id in sorted(closure.components):
        component = closure.components[component_id]
        for dependency in component["dependencies"]:
            relationships.append({
                "spdxElementId": component_ids[component_id],
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": component_ids[dependency],
            })
        for target in component.get("incorporatedInto", []):
            relationships.append({
                "spdxElementId": component_ids[target],
                "relationshipType": "STATIC_LINK",
                "relatedSpdxElement": component_ids[component_id],
            })
    relationships.sort(key=lambda row: (
        row["spdxElementId"], row["relationshipType"], row["relatedSpdxElement"]
    ))

    license_refs = {"LicenseRef-EasySplat-Toolchain-Closure"}
    for component in closure.components.values():
        license_refs.update(LICENSE_REF.findall(component["license"]))
    extracted = [{
        "licenseId": identifier,
        "name": identifier.removeprefix("LicenseRef-").replace("-", " "),
        "extractedText": (
            f"Exact license texts and mappings are distributed in {licenses_name}; "
            f"see {LICENSE_COMPONENTS_PATH}."
        ),
    } for identifier in sorted(license_refs)]

    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"EasySplat-{provenance['appVersion']}",
        "documentNamespace": (
            f"{source['url'].removesuffix('.git').rstrip('/')}/spdx/"
            f"{source['commit']}/{quote(provenance['appVersion'], safe='.-')}"
        ),
        "creationInfo": {
            "created": provenance["createdAt"],
            "creators": ["Tool: EasySplat generate_release_metadata.py"],
        },
        "packages": packages,
        "relationships": relationships,
        "hasExtractedLicensingInfos": extracted,
    }


def build_archive_closure(
    specs: dict[str, ArchiveSpec], closure: ValidatedClosure
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "toolchainVersion": closure.payload["toolchainVersion"],
        "componentsSHA256": sha256_bytes(closure.raw),
        "archives": [{
            "id": identifier,
            "file": specs[identifier].path.name,
            "sha256": sha256_file(specs[identifier].path),
            "size": specs[identifier].path.stat().st_size,
            "entries": closure.archive_rows[identifier],
        } for identifier in ARCHIVE_ORDER],
    }


def license_payload(
    closure: ValidatedClosure,
    specs: dict[str, ArchiveSpec],
    app_license: Path,
    notice: Path,
    viewer_license: Path,
) -> dict[str, bytes]:
    try:
        payload = {
            "EasySplat/LICENSE": app_license.read_bytes(),
            "EasySplat/NOTICE.md": notice.read_bytes(),
            "MetalSplatter/LICENSE": viewer_license.read_bytes(),
            LICENSE_COMPONENTS_PATH: closure.raw,
            ARCHIVE_CLOSURE_PATH: canonical_json_bytes(build_archive_closure(specs, closure)),
        }
    except OSError as exc:
        fail(f"cannot read application license material: {exc}")
    for path in sorted(closure.license_bytes):
        destination = f"Toolchain/{path}"
        if destination in payload:
            fail(f"duplicate release license destination: {destination}")
        payload[destination] = closure.license_bytes[path]
    return payload


def zip_timestamp() -> tuple[int, int, int, int, int, int]:
    raw = os.environ.get("SOURCE_DATE_EPOCH")
    if not raw:
        return (1980, 1, 1, 0, 0, 0)
    try:
        from datetime import datetime, timezone

        value = datetime.fromtimestamp(max(int(raw), 315532800), tz=timezone.utc)
    except (OverflowError, ValueError):
        fail("SOURCE_DATE_EPOCH must be a valid integer timestamp")
    return (value.year, value.month, value.day, value.hour, value.minute, value.second)


def write_license_zip(path: Path, payload: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.unlink(missing_ok=True)
    timestamp = zip_timestamp()
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name in sorted(payload):
                safe_archive_path(name, "license ZIP entry")
                info = zipfile.ZipInfo(name, timestamp)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, payload[name], compresslevel=9)
        temporary.replace(path)
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        temporary.unlink(missing_ok=True)
        fail(f"cannot write license ZIP {path}: {exc}")


def verify_license_zip(path: Path, expected: dict[str, bytes]) -> None:
    seen: set[str] = set()
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                name = safe_archive_path(info.filename, "license ZIP entry")
                if info.is_dir() or is_zip_symlink(info):
                    fail(f"license ZIP entry must be a regular file: {name}")
                if name in seen:
                    fail(f"duplicate license ZIP entry: {name}")
                seen.add(name)
                if name not in expected:
                    fail(f"unexpected license ZIP entry: {name}")
                if archive.read(info) != expected[name]:
                    fail(f"license ZIP entry does not match declared source: {name}")
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        fail(f"cannot verify license ZIP {path}: {exc}")
    if seen != set(expected):
        fail(f"license ZIP is missing entries: {sorted(set(expected) - seen)[:5]}")


def common_args(parser: argparse.ArgumentParser, *, require_urls: bool) -> None:
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--toolchain-version", required=True)
    parser.add_argument(
        "--release-mode",
        choices=("development-unsigned", "production"),
        required=True,
    )
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--manifest-url", required=require_urls)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--core-url", required=require_urls)
    parser.add_argument("--da3-base", type=Path, required=True)
    parser.add_argument("--da3-base-url", required=require_urls)
    parser.add_argument("--da3-small", type=Path, required=True)
    parser.add_argument("--da3-small-url", required=require_urls)
    parser.add_argument("--app-license", type=Path, required=True)
    parser.add_argument("--notice", type=Path, required=True)
    parser.add_argument("--viewer-license", type=Path, required=True)


def specs_from_args(args: argparse.Namespace) -> dict[str, ArchiveSpec]:
    return {
        "core": ArchiveSpec("core", args.core, args.core_url),
        "geometry-da3-base": ArchiveSpec(
            "geometry-da3-base", args.da3_base, args.da3_base_url
        ),
        "geometry-da3-small": ArchiveSpec(
            "geometry-da3-small", args.da3_small, args.da3_small_url
        ),
    }


def generate(args: argparse.Namespace) -> None:
    specs = specs_from_args(args)
    closure = validate_archives(specs, args.toolchain_version)
    created_at = validate_manifest(args.manifest, args.toolchain_version, specs)
    provenance = build_provenance(
        app_version=args.app_version,
        toolchain_version=args.toolchain_version,
        release_mode=args.release_mode,
        source_url=args.source_url,
        source_commit=args.source_commit,
        created_at=created_at,
        dmg=args.dmg,
        manifest=args.manifest,
        manifest_url=args.manifest_url,
        specs=specs,
        closure=closure,
        viewer_license=args.viewer_license,
    )
    spdx = build_spdx(provenance, closure, args.licenses_out.name)
    args.provenance_out.write_bytes(canonical_json_bytes(provenance))
    args.spdx_out.write_bytes(canonical_json_bytes(spdx))
    write_license_zip(
        args.licenses_out,
        license_payload(closure, specs, args.app_license, args.notice, args.viewer_license),
    )


def verify(args: argparse.Namespace) -> None:
    provenance = load_json(args.provenance, "release provenance")
    artifact_claims = provenance.get("artifacts")
    if not isinstance(artifact_claims, dict):
        fail("release provenance artifacts are missing")
    try:
        args.manifest_url = artifact_claims["manifest"]["downloadURL"]
        args.core_url = artifact_claims["core"]["downloadURL"]
        args.da3_base_url = artifact_claims["geometry-da3-base"]["downloadURL"]
        args.da3_small_url = artifact_claims["geometry-da3-small"]["downloadURL"]
    except (KeyError, TypeError):
        fail("release provenance artifact download URLs are incomplete")
    specs = specs_from_args(args)
    closure = validate_archives(specs, args.toolchain_version)
    created_at = validate_manifest(args.manifest, args.toolchain_version, specs)
    expected_provenance = build_provenance(
        app_version=args.app_version,
        toolchain_version=args.toolchain_version,
        release_mode=args.release_mode,
        source_url=args.source_url,
        source_commit=args.source_commit,
        created_at=created_at,
        dmg=args.dmg,
        manifest=args.manifest,
        manifest_url=args.manifest_url,
        specs=specs,
        closure=closure,
        viewer_license=args.viewer_license,
    )
    if provenance != expected_provenance:
        fail("release provenance does not exactly match shipped artifacts")
    expected_spdx = build_spdx(expected_provenance, closure, args.licenses.name)
    if load_json(args.spdx, "SPDX document") != expected_spdx:
        fail("SPDX document does not exactly match the release closure")
    verify_license_zip(
        args.licenses,
        license_payload(closure, specs, args.app_license, args.notice, args.viewer_license),
    )


def verify_toolchain(args: argparse.Namespace) -> None:
    specs = specs_from_args(args)
    validate_archives(specs, args.toolchain_version)
    validate_manifest(args.manifest, args.toolchain_version, specs)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    common_args(generate_parser, require_urls=True)
    generate_parser.add_argument("--source-url", required=True)
    generate_parser.add_argument("--source-commit", required=True)
    generate_parser.add_argument("--provenance-out", type=Path, required=True)
    generate_parser.add_argument("--spdx-out", type=Path, required=True)
    generate_parser.add_argument("--licenses-out", type=Path, required=True)
    generate_parser.set_defaults(operation=generate)
    verify_parser = subparsers.add_parser("verify")
    common_args(verify_parser, require_urls=False)
    verify_parser.add_argument("--source-url", required=True)
    verify_parser.add_argument("--source-commit", required=True)
    verify_parser.add_argument("--provenance", type=Path, required=True)
    verify_parser.add_argument("--spdx", type=Path, required=True)
    verify_parser.add_argument("--licenses", type=Path, required=True)
    verify_parser.set_defaults(operation=verify)
    toolchain_parser = subparsers.add_parser("verify-toolchain")
    toolchain_parser.add_argument("--toolchain-version", required=True)
    toolchain_parser.add_argument("--manifest", type=Path, required=True)
    toolchain_parser.add_argument("--core", type=Path, required=True)
    toolchain_parser.add_argument("--core-url", required=True)
    toolchain_parser.add_argument("--da3-base", type=Path, required=True)
    toolchain_parser.add_argument("--da3-base-url", required=True)
    toolchain_parser.add_argument("--da3-small", type=Path, required=True)
    toolchain_parser.add_argument("--da3-small-url", required=True)
    toolchain_parser.set_defaults(operation=verify_toolchain)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        args.operation(args)
    except (MetadataError, OSError) as exc:
        print(f"release metadata failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
