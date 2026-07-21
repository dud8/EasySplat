#!/usr/bin/env python3
"""Build the fail-closed license, provenance, and file closure for a toolchain."""

from __future__ import annotations

import argparse
import base64
import csv
import email
import hashlib
import json
import re
import shutil
import subprocess
import sys
import unicodedata
import urllib.parse
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn


DA3_MODEL_LOCK = Path(__file__).resolve().with_name("da3-model-lock.json")
FORBIDDEN_LICENSE = re.compile(r"AGPL|(?<!L)GPL|NON.?COMMERCIAL", re.IGNORECASE)
MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
}
THIN_64_MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
LICENSE_NAME = re.compile(
    r"^(license|licence|copying|notice)([._-].*)?$", re.IGNORECASE
)
KNOWN_LICENSE_ALIASES = {
    "apache 2.0": "Apache-2.0",
    "apache 2.0 license": "Apache-2.0",
    "apache-2.0": "Apache-2.0",
    "apache software license": "Apache-2.0",
    "bsd": "BSD-3-Clause",
    "bsd-3-clause": "BSD-3-Clause",
    "bsd license": "BSD-3-Clause",
    "mit": "MIT",
    "mit license": "MIT",
    "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0",
    "mpl-2.0": "MPL-2.0",
    "python software foundation license": "Python-2.0",
    "python-2.0": "Python-2.0",
    "isc": "ISC",
    "isc license": "ISC",
    "isc license (iscl)": "ISC",
    "boost software license": "BSL-1.0",
    "bsl-1.0": "BSL-1.0",
}
REVIEWED_LICENSE_IDENTIFIERS = {
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "BSL-1.0",
    "CNRI-Python",
    "ISC",
    "MIT",
    "MIT-CMU",
    "MPL-2.0",
    "PSF-2.0",
    "Python-2.0",
    "IJG",
    "Zlib",
    "libpng-2.0",
}
REVIEWED_LICENSE_EXCEPTIONS = {"LLVM-exception"}
REVIEWED_SUPPLEMENTAL_LICENSES = {
    "antlr4-python3-runtime": {
        "package": "antlr4-python3-runtime",
        "version": "4.9.3",
        "license": "BSD-3-Clause",
        "source": "https://github.com/antlr/antlr4",
        "sourceCommit": "e4c1a74c66bd5290364ea2b36c97cd724b247357",
        "artifact": "https://raw.githubusercontent.com/antlr/antlr4/e4c1a74c66bd5290364ea2b36c97cd724b247357/LICENSE.txt",
        "artifactSha256": "b1b379fcaf3219593a4c433feb1b35c780bed23fafaae440b1ae2771a9521e3a",
        "distInfo": "antlr4_python3_runtime-4.9.3.dist-info",
        "filename": "UPSTREAM_LICENSE.txt",
    },
}
CLASSIFIER_LICENSES = {
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD-3-Clause",
    "Boost Software License 1.0 (BSL-1.0)": "BSL-1.0",
    "ISC License (ISCL)": "ISC",
    "MIT License": "MIT",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "Python-2.0",
}
MAX_DISTRIBUTION_SIGNING_RECEIPT_BYTES = 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
DISTRIBUTION_SIGNING_SOURCE_INPUTS = {
    "Tools/NativeColmap/local_vocab_retriever.cc",
    "Tools/NativeColmap/local_vocab_retriever.h",
    "scripts/release/finalize_signed_toolchain.py",
    "scripts/release/notarize_artifact.sh",
    "scripts/release/sign_macos_distribution.py",
    "scripts/toolchain/atomic_swap_install.py",
    "scripts/toolchain/build_colmap.sh",
    "scripts/toolchain/build_colmap_impl.sh",
    "scripts/toolchain/secure_colmap_build.py",
    "scripts/toolchain/create_reproducible_zip.py",
    "scripts/toolchain/generate_supply_chain_manifest.py",
    "scripts/toolchain/package_toolchain.sh",
    "scripts/toolchain/patches/colmap-4.1.1-easysplat.patch",
    "scripts/toolchain/validate_da3_payload.py",
    "scripts/toolchain/validate_native_msplat.sh",
    "scripts/toolchain/colmap-support-lock.json",
    "scripts/toolchain/ceres-lock.json",
    "scripts/toolchain/openimageio-lock.json",
    "scripts/toolchain/da3-model-lock.json",
}
PYTHON_STANDALONE_SITE_PACKAGES_FILES = {"README.txt"}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"supply-chain closure failed: {message}")


def run(*command: str, cwd: Path | None = None) -> str:
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        stderr = getattr(exc, "stderr", "")
        fail(f"{' '.join(command)} failed: {str(stderr).strip() or exc}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid JSON receipt {path}: {exc}")
    if not isinstance(payload, dict):
        fail(f"receipt must be an object: {path}")
    return payload


def load_da3_model_lock() -> dict[str, dict[str, Any]]:
    lock = load_json(DA3_MODEL_LOCK)
    if set(lock) != {"schema_version", "models"} or lock.get("schema_version") != 1:
        fail("DA3 model lock does not match schema 1")
    models = lock.get("models")
    if not isinstance(models, dict) or set(models) != {"DA3-BASE", "DA3-SMALL"}:
        fail("DA3 model lock must contain exactly DA3-BASE and DA3-SMALL")
    expected_fields = {
        "repo_id",
        "requested_revision",
        "resolved_sha",
        "license",
        "artifacts",
    }
    for model_name, model in models.items():
        if not isinstance(model, dict) or set(model) != expected_fields:
            fail(f"{model_name} model lock fields do not match the reviewed contract")
        if model.get("license") != "apache-2.0":
            fail(f"{model_name} model lock has an unreviewed license")
        revision = model.get("requested_revision")
        if (
            not isinstance(revision, str)
            or not re.fullmatch(r"[0-9a-f]{40}", revision)
            or model.get("resolved_sha") != revision
        ):
            fail(f"{model_name} model lock has an invalid revision")
        repo_id = model.get("repo_id")
        if not isinstance(repo_id, str) or not repo_id:
            fail(f"{model_name} model lock has an invalid repo_id")
        artifacts = model.get("artifacts")
        if not isinstance(artifacts, dict) or set(artifacts) != {
            "config.json",
            "model.safetensors",
        }:
            fail(f"{model_name} model lock has an incomplete artifact closure")
        for filename, artifact in artifacts.items():
            if not isinstance(artifact, dict) or set(artifact) != {
                "sha256",
                "size_bytes",
            }:
                fail(f"{model_name} {filename} lock fields are invalid")
            size = artifact.get("size_bytes")
            digest = artifact.get("sha256")
            if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
                fail(f"{model_name} {filename} has an invalid locked byte size")
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                fail(f"{model_name} {filename} has an invalid locked SHA-256")
    return models


def relative(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        fail(f"path escapes toolchain root: {path}")


def materialized_source(path: Path, root: Path) -> Path:
    if not path.is_symlink():
        return path
    try:
        resolved = path.resolve(strict=True)
        resolved.relative_to(root.resolve())
    except (OSError, ValueError) as exc:
        fail(f"symlink cannot be materialized inside the toolchain: {path}: {exc}")
    if not resolved.is_file():
        fail(f"toolchain symlink does not resolve to a regular file: {path}")
    return resolved


def is_macho(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with path.open("rb") as stream:
            return stream.read(4) in MACHO_MAGICS
    except OSError as exc:
        fail(f"cannot inspect {path}: {exc}")


def validate_macos_15_compatibility(path: Path) -> None:
    output = run("xcrun", "vtool", "-show-build", str(path))
    versions: list[str] = []
    for block in re.split(r"(?=^Load command \d+\s*$)", output, flags=re.MULTILINE):
        command = re.search(r"^\s*cmd\s+(LC_[A-Z0-9_]+)\s*$", block, re.MULTILINE)
        if not command:
            continue
        command_name = command.group(1)
        if command_name == "LC_BUILD_VERSION":
            platform = re.search(r"^\s*platform\s+(\S+)\s*$", block, re.MULTILINE)
            if not platform or platform.group(1) != "MACOS":
                rendered = platform.group(1) if platform else "unknown"
                fail(
                    f"{path} targets unsupported Apple platform {rendered}; expected MACOS"
                )
            minimum = re.search(
                r"^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$", block, re.MULTILINE
            )
            if minimum:
                versions.append(minimum.group(1))
        elif command_name == "LC_VERSION_MIN_MACOSX":
            minimum = re.search(
                r"^\s*version\s+(\d+(?:\.\d+){0,2})\s*$", block, re.MULTILINE
            )
            if minimum:
                versions.append(minimum.group(1))
        elif command_name.startswith("LC_VERSION_MIN_"):
            fail(f"{path} targets unsupported Apple platform via {command_name}")
    if not versions:
        fail(f"{path} has no readable macOS minimum deployment target")
    for value in versions:
        parts = tuple(int(part) for part in value.split("."))
        padded = parts + (0,) * (3 - len(parts))
        if padded > (15, 0, 0):
            fail(f"{path} requires macOS {value}; EasySplat supports macOS 15.0+")


def validate_arm64_only(path: Path) -> None:
    try:
        with path.open("rb") as stream:
            magic = stream.read(4)
    except OSError as exc:
        fail(f"cannot inspect {path} architecture: {exc}")
    if magic not in THIN_64_MACHO_MAGICS:
        fail(f"{path} must be a thin 64-bit arm64 Mach-O binary")
    architectures = run("/usr/bin/lipo", "-archs", str(path)).strip().split()
    if architectures != ["arm64"]:
        rendered = " ".join(architectures) or "unreadable architecture"
        fail(f"{path} must be an arm64-only Mach-O binary; found {rendered}")


def macho_install_id(path: Path) -> str | None:
    try:
        result = subprocess.run(
            ["otool", "-D", str(path)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        fail(f"otool -D failed for {path}: {exc}")
    if result.returncode != 0:
        return None
    lines = [line.strip() for line in result.stdout.splitlines()[1:] if line.strip()]
    return lines[0] if lines else None


def validate_macho_dependencies(
    path_text: str,
    dependencies: list[str],
    install_id: str | None,
    *,
    root: Path | None = None,
    source: Path | None = None,
    packaged_machos: set[Path] | None = None,
) -> None:
    for dependency in dependencies:
        if dependency == install_id or dependency.startswith(
            ("/usr/lib/", "/System/Library/")
        ):
            continue
        token = next(
            (
                candidate
                for candidate in ("@loader_path", "@executable_path", "@rpath")
                if dependency.startswith(f"{candidate}/")
            ),
            None,
        )
        if token:
            suffix = PurePosixPath(dependency.removeprefix(f"{token}/"))
            if suffix.is_absolute() or ".." in suffix.parts:
                fail(f"{path_text} has dependency path traversal: {dependency}")
            if root is None or source is None or packaged_machos is None:
                continue
            candidates: list[Path]
            if token == "@loader_path":
                candidates = [source.parent.joinpath(*suffix.parts)]
            elif token == "@executable_path":
                executable_roots = [root / "bin"]
                if path_text.startswith("da3_mps/python/"):
                    executable_roots.append(root / "da3_mps/python/bin")
                candidates = [base.joinpath(*suffix.parts) for base in executable_roots]
            else:
                candidates = [
                    candidate
                    for candidate in packaged_machos
                    if candidate.name == suffix.name
                ]
            resolved: list[Path] = []
            for candidate in candidates:
                try:
                    materialized = candidate.resolve(strict=True)
                    materialized.relative_to(root.resolve(strict=True))
                except (OSError, ValueError):
                    continue
                if materialized in packaged_machos:
                    resolved.append(materialized)
            if not resolved:
                fail(f"{path_text} has a missing packaged dependency: {dependency}")
            continue
        fail(f"{path_text} has an unportable dependency: {dependency}")


def normalize_license(value: Any) -> str:
    if isinstance(value, str):
        normalized = KNOWN_LICENSE_ALIASES.get(value.strip().lower(), value.strip())
    elif isinstance(value, dict):
        if "all_of" in value:
            normalized = " AND ".join(
                f"({normalize_license(item)})" for item in value["all_of"]
            )
        elif "any_of" in value:
            normalized = " OR ".join(
                f"({normalize_license(item)})" for item in value["any_of"]
            )
        elif "with" in value and isinstance(value["with"], dict):
            entry = value["with"]
            normalized = f"{normalize_license(entry.get('license'))} WITH {entry.get('exception', '')}"
        else:
            fail(f"unsupported license expression: {value!r}")
    else:
        fail(f"missing or unsupported license expression: {value!r}")
    if not normalized or normalized.upper() in {"UNKNOWN", "NOASSERTION", "NONE"}:
        fail(f"unknown license expression: {value!r}")
    if FORBIDDEN_LICENSE.search(normalized):
        fail(f"forbidden release license: {normalized}")
    compact = re.sub(r"\s+", "", normalized)
    tokens = re.findall(
        r"\(|\)|AND|OR|WITH|[A-Za-z0-9][A-Za-z0-9.+-]*", normalized
    )
    if "".join(tokens) != compact:
        fail(f"unreviewed license expression: {normalized}")

    position = 0

    def parse_primary() -> None:
        nonlocal position
        if position >= len(tokens):
            fail(f"unreviewed license expression: {normalized}")
        token = tokens[position]
        if token == "(":
            position += 1
            parse_or_expression()
            if position >= len(tokens) or tokens[position] != ")":
                fail(f"unreviewed license expression: {normalized}")
            position += 1
            return
        if token not in REVIEWED_LICENSE_IDENTIFIERS:
            fail(f"unreviewed license identifier: {token}")
        position += 1
        if position < len(tokens) and tokens[position] == "WITH":
            position += 1
            if (
                position >= len(tokens)
                or tokens[position] not in REVIEWED_LICENSE_EXCEPTIONS
            ):
                fail(f"unreviewed license exception: {normalized}")
            position += 1

    def parse_and_expression() -> None:
        nonlocal position
        parse_primary()
        while position < len(tokens) and tokens[position] == "AND":
            position += 1
            parse_primary()

    def parse_or_expression() -> None:
        nonlocal position
        parse_and_expression()
        while position < len(tokens) and tokens[position] == "OR":
            position += 1
            parse_and_expression()

    parse_or_expression()
    if position != len(tokens):
        fail(f"unreviewed license expression: {normalized}")
    return normalized


def validate_public_https_url(value: Any, *, label: str) -> str:
    if not isinstance(value, str):
        fail(f"{label} URL is not a string")
    if (
        any(ord(character) <= 0x20 or ord(character) >= 0x7F for character in value)
        or "\\" in value
    ):
        fail(f"{label} URL contains unsafe characters")
    try:
        parsed = urllib.parse.urlsplit(value)
        hostname = parsed.hostname
    except ValueError:
        fail(f"{label} URL is malformed")
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        fail(f"{label} must be a public HTTPS URL without credentials, query, or fragment")
    return value


def validate_component_urls(components: dict[str, dict[str, Any]]) -> None:
    for component_id, component in components.items():
        validate_public_https_url(component.get("source"), label=f"{component_id} source")
        if "artifact" in component:
            validate_public_https_url(
                component.get("artifact"), label=f"{component_id} artifact"
            )
        source_artifacts = component.get("sourceArtifacts", [])
        if not isinstance(source_artifacts, list):
            fail(f"{component_id} sourceArtifacts is not an array")
        for index, row in enumerate(source_artifacts):
            if not isinstance(row, dict):
                fail(f"{component_id} source artifact is not an object")
            validate_public_https_url(
                row.get("url"), label=f"{component_id} source artifact {index}"
            )


def metadata_license(metadata: email.message.Message) -> str:
    expression = metadata.get("License-Expression", "").strip()
    if expression:
        return normalize_license(expression)
    legacy = metadata.get("License", "").strip()
    if (
        legacy
        and legacy.upper() not in {"UNKNOWN", "NOASSERTION", "NONE"}
        and len(legacy) <= 160
        and "\n" not in legacy
    ):
        return normalize_license(legacy)
    candidates: set[str] = set()
    for classifier in metadata.get_all("Classifier", []):
        prefix = "License :: OSI Approved :: "
        if classifier.startswith(prefix):
            name = classifier[len(prefix) :]
            if name in CLASSIFIER_LICENSES:
                candidates.add(CLASSIFIER_LICENSES[name])
    if len(candidates) == 1:
        return normalize_license(candidates.pop())
    fail(
        f"Python package {metadata.get('Name', '<unknown>')} has no unambiguous license metadata"
    )


def component_build_command(component_id: str, component: dict[str, Any]) -> str:
    if component_id == "easysplat-distribution-signing":
        return "./scripts/release/finalize_signed_toolchain.py"
    if component_id == "colmap" or component_id.startswith("colmap:"):
        return "./scripts/toolchain/build_colmap.sh"
    if component_id == "colmap-support" or component_id.startswith(
        "colmap-support:"
    ):
        return "./scripts/toolchain/build_colmap_support.sh"
    if component_id == "ceres" or component_id.startswith("ceres:"):
        return "./scripts/toolchain/build_ceres.sh"
    if component_id == "openimageio" or component_id.startswith("openimageio:"):
        return "./scripts/toolchain/build_openimageio.sh"
    if component_id == "msplat" or component_id.startswith("msplat:"):
        return "./scripts/toolchain/build_msplat.sh"
    if component_id in {
        "da3",
        "easysplat-da3-runner",
        "python-build-standalone",
    } or component_id.startswith(("model:", "python:")):
        return "./scripts/toolchain/build_da3_mps.sh"
    fail(f"component has no reviewed build command: {component_id}")


def resolve_installed_dependencies(components: dict[str, dict[str, Any]]) -> None:
    installed = set(components)
    for component_id, component in components.items():
        dependencies = set(component.get("dependencies", []))
        missing = dependencies.difference(installed)
        if missing and component.get("type") != "python-package":
            fail(
                f"component {component_id} refers to missing dependencies: {sorted(missing)}"
            )
        # Python METADATA includes inactive platform markers and optional extras.
        # Record only distributions that are actually installed in this closure.
        component["dependencies"] = sorted(dependencies.intersection(installed))


def distribution_metadata_paths(python_root: Path) -> list[Path]:
    return sorted(
        metadata
        for site_packages in python_root.glob("lib/python*/site-packages")
        for metadata in site_packages.glob("*.dist-info/METADATA")
    )


def normalized_distribution_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def locked_python_distributions(
    lock_path: Path,
) -> dict[str, tuple[str, frozenset[str]]]:
    try:
        raw = lock_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"unable to read Python requirements lock: {exc}")
    logical = raw.replace("\\\n", " ")
    locked: dict[str, tuple[str, frozenset[str]]] = {}
    for line in logical.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z0-9_.-]+)==([^\s;]+)", stripped)
        hashes = re.findall(r"--hash=sha256:([0-9a-f]{64})(?:\s|$)", stripped)
        if match is None or not hashes:
            fail(f"Python requirements lock has an unreviewed row: {stripped[:120]}")
        slug = normalized_distribution_name(match.group(1))
        if slug in locked:
            fail(f"Python requirements lock contains a duplicate package: {slug}")
        locked[slug] = (match.group(2), frozenset(hashes))
    if not locked:
        fail("Python requirements lock contains no hashed packages")
    return locked


def reported_python_distributions(
    report: dict[str, Any],
) -> dict[str, tuple[str, str, str]]:
    installed: dict[str, tuple[str, str, str]] = {}
    rows = report.get("install")
    if not isinstance(rows, list):
        fail("pip install report has no install array")
    for entry in rows:
        if not isinstance(entry, dict):
            fail("pip install report contains a non-object entry")
        metadata = entry.get("metadata", {})
        download = entry.get("download_info", {})
        archive_info = download.get("archive_info", {}) if isinstance(download, dict) else {}
        hashes = archive_info.get("hashes", {}) if isinstance(archive_info, dict) else {}
        name = str(metadata.get("name") or "") if isinstance(metadata, dict) else ""
        version = str(metadata.get("version") or "") if isinstance(metadata, dict) else ""
        source_url = str(download.get("url") or "") if isinstance(download, dict) else ""
        artifact_hash = str(hashes.get("sha256") or "") if isinstance(hashes, dict) else ""
        if not artifact_hash:
            raw_hash = str(archive_info.get("hash") or "") if isinstance(archive_info, dict) else ""
            if raw_hash.startswith("sha256="):
                artifact_hash = raw_hash.removeprefix("sha256=")
        if (
            not name
            or not version
            or not source_url.startswith("https://")
            or not SHA256_PATTERN.fullmatch(artifact_hash)
        ):
            fail(
                f"pip install report contains incomplete artifact provenance for {name or '<unknown>'}"
            )
        slug = normalized_distribution_name(name)
        if slug in installed:
            fail(f"pip install report contains duplicate distribution: {name}")
        installed[slug] = (version, source_url, artifact_hash)
    return installed


def validate_record_member(
    path: Path,
    encoded_hash: str,
    encoded_size: str,
    *,
    python_root: Path,
    distribution: str,
) -> bool:
    try:
        path.resolve(strict=False).relative_to(python_root.resolve(strict=True))
    except (OSError, ValueError) as exc:
        fail(f"Python RECORD member escapes the runtime: {distribution}: {path}: {exc}")
    if not (path.exists() or path.is_symlink()):
        if path.suffix == ".pyc" and not encoded_hash and not encoded_size:
            return False
        fail(f"Python RECORD member is missing: {distribution}: {path}")
    source = materialized_source(path, python_root)
    if encoded_size:
        try:
            expected_size = int(encoded_size)
        except ValueError:
            fail(f"Python RECORD has an invalid size: {distribution}: {path}")
        if source.stat().st_size != expected_size:
            fail(f"Python RECORD size mismatch: {distribution}: {path}")
    if encoded_hash:
        algorithm, separator, value = encoded_hash.partition("=")
        if separator != "=" or algorithm != "sha256" or not value:
            fail(f"Python RECORD uses an unsupported hash: {distribution}: {path}")
        try:
            expected = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        except (ValueError, TypeError) as exc:
            fail(f"Python RECORD has an invalid hash: {distribution}: {path}: {exc}")
        actual = hashlib.sha256(source.read_bytes()).digest()
        if actual != expected:
            fail(f"Python RECORD hash mismatch: {distribution}: {path}")
    return True


def reset_python_license_receipts(root: Path) -> Path:
    receipt_root = root / "licenses" / "python-packages"
    if receipt_root.is_symlink():
        fail(f"Python license receipt directory must not be a symlink: {receipt_root}")
    if receipt_root.exists() and not receipt_root.is_dir():
        fail(f"Python license receipt path is not a directory: {receipt_root}")
    if receipt_root.is_dir():
        shutil.rmtree(receipt_root)
    receipt_root.mkdir(parents=True)
    return receipt_root


def validate_supplemental_license_receipts(
    root: Path,
    *,
    reviewed: dict[str, dict[str, str]] = REVIEWED_SUPPLEMENTAL_LICENSES,
) -> dict[Path, str]:
    manifest_path = (
        root / "da3_mps" / "licenses" / "python-package-upstream-notices.json"
    )
    payload = load_json(manifest_path)
    notices = payload.get("notices")
    if payload.get("schemaVersion") != 1 or not isinstance(notices, list):
        fail("supplemental Python license manifest has an unsupported schema")
    by_package: dict[str, dict[str, Any]] = {}
    for notice in notices:
        if not isinstance(notice, dict):
            fail("supplemental Python license manifest contains a non-object notice")
        package = str(notice.get("package") or "")
        if not package or package in by_package:
            fail(
                f"supplemental Python license manifest has a duplicate package: {package}"
            )
        by_package[package] = notice
    if set(by_package) != set(reviewed):
        fail(
            "supplemental Python license manifest package set does not match the reviewed closure"
        )

    ownership: dict[Path, str] = {}
    for package, expected in reviewed.items():
        notice = by_package[package]
        expected_keys = set(expected) | {"installedPath"}
        if set(notice) != expected_keys:
            fail(
                f"supplemental Python license receipt has unexpected fields: {package}"
            )
        for key, value in expected.items():
            if notice.get(key) != value:
                fail(
                    f"supplemental Python license receipt has unreviewed {key}: {package}"
                )
        installed_text = str(notice.get("installedPath") or "")
        installed = PurePosixPath(installed_text)
        if installed.is_absolute() or ".." in installed.parts:
            fail(f"supplemental Python license path is unsafe: {installed_text}")
        if (
            len(installed.parts) < 7
            or installed.parts[:2] != ("da3_mps", "python")
            or installed.parts[-4] != "site-packages"
            or installed.parts[-3] != expected["distInfo"]
            or installed.parts[-2] != "licenses"
            or installed.parts[-1] != expected["filename"]
        ):
            fail(
                f"supplemental Python license is installed in the wrong distribution: {package}"
            )
        path = root.joinpath(*installed.parts)
        if path.is_symlink() or not path.is_file():
            fail(
                f"supplemental Python license file is missing or unsafe: {installed_text}"
            )
        try:
            path.resolve(strict=True).relative_to(root.resolve(strict=True))
        except (OSError, ValueError) as exc:
            fail(f"supplemental Python license escapes the toolchain: {path}: {exc}")
        if sha256(path) != expected["artifactSha256"]:
            fail(f"supplemental Python license artifact hash mismatch: {package}")
        ownership[path.resolve(strict=True)] = (
            f"python:{normalized_distribution_name(package)}"
        )
    return ownership


def distribution_license_sources(
    metadata_path: Path,
    metadata: email.message.Message,
) -> list[Path]:
    dist_info = metadata_path.parent
    candidates: set[Path] = {
        path
        for path in dist_info.iterdir()
        if LICENSE_NAME.match(path.name) and (path.is_file() or path.is_symlink())
    }

    licenses_dir = dist_info / "licenses"
    if licenses_dir.is_symlink():
        fail(
            f"Python distribution license directory must not be a symlink: {licenses_dir}"
        )
    if licenses_dir.is_dir():
        candidates.update(path for path in licenses_dir.rglob("*") if path.is_file())

    for declared in metadata.get_all("License-File", []):
        pure = PurePosixPath(declared)
        if pure.is_absolute() or ".." in pure.parts:
            fail(
                f"{metadata.get('Name', '<unknown>')} declares an unsafe license path: {declared}"
            )
        locations = [
            dist_info.joinpath(*pure.parts),
            licenses_dir.joinpath(*pure.parts),
        ]
        source = next((path for path in locations if path.is_file()), None)
        if source is None:
            fail(
                f"{metadata.get('Name', '<unknown>')} declares a missing license file: {declared}"
            )
        candidates.add(source)

    sources: list[Path] = []
    for path in sorted(candidates, key=lambda candidate: candidate.as_posix()):
        if path.is_symlink():
            fail(f"Python distribution license must not be a symlink: {path}")
        try:
            path.resolve(strict=True).relative_to(dist_info.resolve(strict=True))
        except (OSError, ValueError) as exc:
            fail(
                f"Python distribution license escapes its dist-info directory: {path}: {exc}"
            )
        if path.stat().st_size > 2 * 1024 * 1024:
            fail(f"Python distribution license is unexpectedly large: {path}")
        sources.append(path)
    if not sources:
        fail(
            f"Python package {metadata.get('Name', '<unknown>')} has no physical license notice"
        )
    return sources


def python_components(
    root: Path,
    *,
    supplemental_ownership: dict[Path, str] | None = None,
) -> tuple[dict[str, dict[str, Any]], dict[Path, str]]:
    python_root = root / "da3_mps" / "python"
    python_license_root = reset_python_license_receipts(root)
    report_path = root / "da3_mps" / "licenses" / "python-packages-install-report.json"
    report = load_json(report_path)
    installed_artifacts = reported_python_distributions(report)
    lock_path = root / "da3_mps" / "licenses" / "python-packages-requirements.txt"
    locked = locked_python_distributions(lock_path)
    metadata_paths = distribution_metadata_paths(python_root)
    metadata_versions: dict[str, str] = {}
    for metadata_path in metadata_paths:
        metadata = email.message_from_bytes(metadata_path.read_bytes())
        name = metadata.get("Name", "").strip()
        version = metadata.get("Version", "").strip()
        slug = normalized_distribution_name(name)
        if not name or not version or slug in metadata_versions:
            fail(f"installed Python dist-info metadata is incomplete or duplicated: {metadata_path}")
        metadata_versions[slug] = version
    locked_versions = {slug: row[0] for slug, row in locked.items()}
    report_versions = {slug: artifact[0] for slug, artifact in installed_artifacts.items()}
    if locked_versions != report_versions or locked_versions != metadata_versions:
        fail(
            "Python requirements lock, pip report, and installed dist-info set must match exactly"
        )
    for slug, (_version, _source_url, artifact_hash) in installed_artifacts.items():
        if artifact_hash not in locked[slug][1]:
            fail(f"pip report artifact hash is not allowed by the lock: {slug}")

    supplemental_ownership = supplemental_ownership or {}
    components: dict[str, dict[str, Any]] = {}
    ownership: dict[Path, str] = {}
    record_ownership: dict[Path, str] = {}
    site_package_roots: set[Path] = set()
    for metadata_path in metadata_paths:
        metadata = email.message_from_bytes(metadata_path.read_bytes())
        name = metadata.get("Name", "").strip()
        version = metadata.get("Version", "").strip()
        if not name or not version:
            fail(f"incomplete Python package metadata: {metadata_path}")
        slug = normalized_distribution_name(name)
        component_id = f"python:{slug}"
        if component_id in components:
            fail(f"duplicate Python distribution metadata for {name}")
        expression = metadata_license(metadata)
        project_urls: dict[str, str] = {}
        for entry in metadata.get_all("Project-URL", []):
            label, separator, url = entry.partition(",")
            if separator:
                project_urls[label.strip().lower()] = url.strip()
        source = next(
            (
                project_urls[key]
                for key in ("source", "repository", "homepage")
                if project_urls.get(key, "").startswith("https://")
            ),
            (metadata.get("Home-page") or "").strip(),
        )
        if not source.startswith("https://"):
            source = f"https://pypi.org/project/{name}/{version}/"

        receipt_dir = python_license_root / slug
        receipt_dir.mkdir(parents=True, exist_ok=True)
        receipt = receipt_dir / "METADATA"
        shutil.copy2(metadata_path, receipt)
        license_paths = [relative(receipt, root)]
        for source_license in distribution_license_sources(metadata_path, metadata):
            source_relative = source_license.relative_to(metadata_path.parent)
            destination_name = "__".join(source_relative.parts)
            destination = receipt_dir / re.sub(
                r"[^A-Za-z0-9._-]", "_", destination_name
            )
            shutil.copy2(source_license, destination)
            license_paths.append(relative(destination, root))

        dependencies = []
        for requirement in metadata.get_all("Requires-Dist", []):
            dependency = re.split(r"[ (;<>=!~]", requirement, maxsplit=1)[0]
            if dependency:
                dependencies.append(
                    f"python:{normalized_distribution_name(dependency)}"
                )
        components[component_id] = {
            "id": component_id,
            "name": name,
            "type": "python-package",
            "version": version,
            "revision": version,
            "source": source,
            "license": expression,
            "licenseFiles": sorted(set(license_paths)),
            "linkage": "python",
            "dependencies": sorted(set(dependencies)),
        }
        if slug in installed_artifacts:
            artifact_version, artifact_url, artifact_hash = installed_artifacts.pop(
                slug
            )
            if artifact_version != version:
                fail(
                    f"pip install report version mismatch for {name}: {artifact_version} != {version}"
                )
            components[component_id]["artifact"] = artifact_url
            components[component_id]["artifactSha256"] = artifact_hash
        else:
            fail(
                f"installed Python distribution has no hashed pip report entry: {name}"
            )

        site_packages = metadata_path.parent.parent
        site_package_roots.add(site_packages)
        record = metadata_path.parent / "RECORD"
        if not record.is_file():
            fail(f"Python distribution has no RECORD: {name}")
        with record.open(newline="", encoding="utf-8") as stream:
            for row in csv.reader(stream):
                if not row:
                    continue
                if len(row) != 3:
                    fail(f"Python RECORD row must have exactly three columns: {name}")
                raw_member = row[0]
                pure_member = PurePosixPath(raw_member)
                if (
                    not raw_member
                    or "\\" in raw_member
                    or "\x00" in raw_member
                    or unicodedata.normalize("NFC", raw_member) != raw_member
                    or any(
                        unicodedata.category(character) in {"Cc", "Cs"}
                        for character in raw_member
                    )
                    or pure_member.is_absolute()
                    or pure_member.as_posix() != raw_member
                    or any(part in {"", "."} for part in pure_member.parts)
                ):
                    fail(f"Python RECORD member path is unsafe or non-normalized: {name}")
                candidate = site_packages.joinpath(*pure_member.parts).resolve(
                    strict=False
                )
                encoded_hash = row[1]
                encoded_size = row[2]
                is_record_self = candidate == record.resolve(strict=True)
                is_stripped_bytecode = (
                    candidate.suffix == ".pyc"
                    and not candidate.exists()
                    and not candidate.is_symlink()
                )
                if is_record_self:
                    if encoded_hash or encoded_size:
                        fail(f"Python RECORD self row must have empty hash and size: {name}")
                elif is_stripped_bytecode:
                    if encoded_hash or encoded_size:
                        fail(
                            f"missing Python bytecode has a retained hash or size: {name}: {row[0]}"
                        )
                elif not encoded_hash or not encoded_size:
                    fail(f"Python RECORD member lacks a hash or size: {name}: {row[0]}")
                if validate_record_member(
                    candidate,
                    encoded_hash,
                    encoded_size,
                    python_root=python_root,
                    distribution=name,
                ):
                    if candidate in record_ownership:
                        fail(
                            f"Python RECORD member has multiple owners: {candidate}"
                        )
                    record_ownership[candidate] = component_id
                    ownership[candidate] = component_id
        for path in metadata_path.parent.rglob("*"):
            if path.is_file() or path.is_symlink():
                ownership[path.resolve(strict=False)] = component_id
    if installed_artifacts:
        fail(
            f"pip install report packages are missing from the runtime: {sorted(installed_artifacts)}"
        )
    for site_packages in site_package_roots:
        for path in site_packages.rglob("*"):
            if not (path.is_file() or path.is_symlink()):
                continue
            resolved = path.resolve(strict=False)
            if resolved not in record_ownership:
                supplemental_owner = supplemental_ownership.get(resolved)
                if supplemental_owner is not None:
                    ownership[resolved] = supplemental_owner
                    continue
                runtime_relative = path.relative_to(site_packages).as_posix()
                if runtime_relative in PYTHON_STANDALONE_SITE_PACKAGES_FILES:
                    ownership[resolved] = "python-build-standalone"
                    continue
                fail(f"site-packages file has no exact Python RECORD owner: {path}")
    return components, ownership


def receipt_dependency_component(
    component_id: str,
    name: str,
    entry: dict[str, Any],
    *,
    incorporated_into: str,
) -> dict[str, Any]:
    source = str(entry.get("source_url") or "")
    version = str(entry.get("source_version") or "")
    revision = str(
        entry.get("source_commit")
        or entry.get("source_sha256")
        or entry.get("source_tree_sha256")
        or version
    )
    license_files = entry.get("license_files", [])
    if (
        not source.startswith("https://")
        or not version
        or not revision
        or not isinstance(license_files, list)
        or not license_files
    ):
        fail(f"native dependency receipt is incomplete: {component_id}")
    component: dict[str, Any] = {
        "id": component_id,
        "name": name,
        "type": "static-dependency",
        "version": version,
        "revision": revision,
        "source": source,
        "license": normalize_license(entry.get("license")),
        "licenseFiles": sorted(str(path) for path in license_files),
        "linkage": str(entry.get("linkage") or "compiled-in"),
        "dependencies": [],
        "incorporatedInto": [incorporated_into],
    }
    artifact = str(entry.get("artifact_url") or entry.get("source_archive_url") or "")
    artifact_sha256 = str(
        entry.get("artifact_sha256") or entry.get("source_archive_sha256") or ""
    )
    if not artifact and artifact_sha256:
        artifact = source
    if not artifact and re.search(
        r"\.(?:zip|tar|tar\.gz|tar\.xz|tgz|txz)(?:$|[?#])", source, re.IGNORECASE
    ):
        source_sha256 = str(entry.get("source_sha256") or "")
        if source_sha256:
            artifact = source
            artifact_sha256 = source_sha256
    if artifact:
        if not artifact.startswith("https://") or not re.fullmatch(
            r"[0-9a-f]{64}", artifact_sha256
        ):
            fail(f"native dependency artifact is incomplete: {component_id}")
        component["artifact"] = artifact
        component["artifactSha256"] = artifact_sha256
    return component


def signed_macho_bridge(
    distribution_signing: dict[str, Any] | None,
    relative_path: str,
) -> dict[str, Any] | None:
    if distribution_signing is None:
        return None
    rows = distribution_signing.get("machOFiles")
    if not isinstance(rows, list):
        fail("distribution-signing receipt has no Mach-O bridge array")
    matches = [
        row
        for row in rows
        if isinstance(row, dict) and row.get("path") == relative_path
    ]
    if len(matches) != 1:
        fail(f"distribution-signing receipt has no unique bridge: {relative_path}")
    return matches[0]


def native_colmap_components(
    root: Path,
    distribution_signing: dict[str, Any] | None = None,
) -> dict[str, dict[str, Any]]:
    receipt = load_json(root / "provenance" / "colmap.json")
    executable = root / "bin" / "colmap"
    if not executable.is_file():
        fail("native COLMAP executable is missing")
    if receipt.get("schema_version") != 2 or receipt.get("toolchain_name") != "colmap":
        fail("native COLMAP receipt has the wrong schema or toolchain_name")
    source = str(receipt.get("source_url") or "")
    source_version = str(receipt.get("source_version") or "")
    source_commit = str(receipt.get("source_commit") or "")
    if not source.startswith("https://") or not source_version or not source_commit:
        fail("native COLMAP receipt has incomplete source provenance")
    build_digest = receipt.get("executable_sha256")
    installed_digest = sha256(executable)
    if build_digest != installed_digest:
        bridge = signed_macho_bridge(distribution_signing, "bin/colmap")
        if (
            bridge is None
            or bridge.get("preSignSHA256") != build_digest
            or bridge.get("postSignSHA256") != installed_digest
        ):
            fail("native COLMAP receipt does not match the installed executable")
    main_license = root / "licenses" / "COLMAP" / "COPYING.txt"
    if not main_license.is_file():
        fail("native COLMAP license is missing")
    dependencies = receipt.get("dependencies")
    if not isinstance(dependencies, dict) or set(dependencies) != {
        "faiss",
        "poselib",
        "vlfeat",
    }:
        fail("native COLMAP receipt has an unexpected static dependency closure")
    components: dict[str, dict[str, Any]] = {}
    dependency_ids = []
    for name, entry in sorted(dependencies.items()):
        component_id = f"colmap:{name}"
        dependency_ids.append(component_id)
        components[component_id] = receipt_dependency_component(
            component_id,
            name,
            entry,
            incorporated_into="colmap",
        )
    components["colmap"] = {
        "id": "colmap",
        "name": "COLMAP",
        "type": "executable",
        "version": source_version,
        "revision": source_commit,
        "source": source,
        "license": normalize_license(receipt.get("license")),
        "licenseFiles": [relative(main_license, root)],
        "linkage": "native-executable",
        "dependencies": dependency_ids,
    }
    return components


def aggregate_native_components(
    root: Path,
    distribution_signing: dict[str, Any] | None = None,
) -> dict[str, dict[str, Any]]:
    components = native_colmap_components(root, distribution_signing)
    project_license = root / "licenses" / "EasySplat" / "LICENSE"
    if not project_license.is_file():
        fail("EasySplat license is missing")

    support = load_json(root / "provenance" / "colmap-support.json")
    if support.get("toolchain_name") != "colmap-support":
        fail("COLMAP support receipt has the wrong toolchain_name")
    support_dependencies = support.get("dependencies")
    if not isinstance(support_dependencies, dict) or set(support_dependencies) != {
        "boost",
        "gflags",
        "glog",
        "libomp",
    }:
        fail("COLMAP support receipt has an unexpected dependency closure")
    support_ids = []
    for name, entry in sorted(support_dependencies.items()):
        component_id = f"colmap-support:{name}"
        support_ids.append(component_id)
        components[component_id] = receipt_dependency_component(
            component_id,
            name,
            entry,
            incorporated_into="colmap-support",
        )
    components["colmap-support"] = {
        "id": "colmap-support",
        "name": "EasySplat COLMAP support closure",
        "type": "native-build-input",
        "version": str(support.get("schema_version") or "1"),
        "revision": str(support.get("source_lock_sha256") or ""),
        "source": "https://github.com/dud8/EasySplat",
        "license": "LicenseRef-Dependency-Closure",
        "licenseFiles": [relative(project_license, root)],
        "linkage": "build-input",
        "dependencies": support_ids,
    }

    ceres = load_json(root / "provenance" / "ceres.json")
    ceres_dependencies = ceres.get("dependencies")
    if ceres.get("toolchain_name") != "ceres-static" or not isinstance(
        ceres_dependencies, dict
    ) or set(ceres_dependencies) != {"ceres", "eigen"}:
        fail("Ceres receipt has an unexpected dependency closure")
    components["ceres"] = receipt_dependency_component(
        "ceres", "Ceres Solver", ceres_dependencies["ceres"], incorporated_into="colmap"
    )
    components["ceres"]["type"] = "static-library"
    components["ceres"]["dependencies"] = ["ceres:eigen"]
    components["ceres:eigen"] = receipt_dependency_component(
        "ceres:eigen", "Eigen", ceres_dependencies["eigen"], incorporated_into="ceres"
    )

    openimageio = load_json(root / "provenance" / "openimageio.json")
    oiio_dependencies = openimageio.get("dependencies")
    if openimageio.get("toolchain_name") != "openimageio-static" or not isinstance(
        oiio_dependencies, dict
    ) or "openimageio" not in oiio_dependencies:
        fail("OpenImageIO receipt has an unexpected dependency closure")
    components["openimageio"] = receipt_dependency_component(
        "openimageio",
        "OpenImageIO",
        oiio_dependencies["openimageio"],
        incorporated_into="colmap",
    )
    components["openimageio"]["type"] = "static-library"
    oiio_ids = []
    for name, entry in sorted(oiio_dependencies.items()):
        if name == "openimageio":
            continue
        component_id = f"openimageio:{name}"
        oiio_ids.append(component_id)
        components[component_id] = receipt_dependency_component(
            component_id,
            name,
            entry,
            incorporated_into="openimageio",
        )
    components["openimageio"]["dependencies"] = oiio_ids
    components["colmap"]["dependencies"].extend(
        ["colmap-support", "ceres", "openimageio"]
    )
    return components


def builder_components(
    root: Path,
    version: str,
    python_components: dict[str, dict[str, Any]],
    distribution_signing: dict[str, Any] | None = None,
    *,
    repository_root: Path | None = None,
    repository_revision: str | None = None,
) -> dict[str, dict[str, Any]]:
    msplat = load_json(root / "msplat" / "build_info.json")
    da3 = load_json(root / "da3_mps" / "build_info.json")
    repository_root = repository_root or Path(__file__).resolve().parents[2]
    repository_revision = repository_revision or run(
        "git", "rev-parse", "HEAD", cwd=repository_root
    ).strip()
    lock_path = root / "da3_mps" / "licenses" / "python-packages-requirements.txt"
    lock_hash = str(da3.get("requirements_lock_sha256") or "")
    if (
        not lock_path.is_file()
        or not re.fullmatch(r"[0-9a-f]{64}", lock_hash)
        or sha256(lock_path) != lock_hash
    ):
        fail(
            "DA3 Python requirements lock is missing or does not match its builder receipt"
        )
    reviewed_models = load_da3_model_lock()
    model_lock_hash = str(da3.get("model_lock_sha256") or "")
    if (
        da3.get("model_lock") != "scripts/toolchain/da3-model-lock.json"
        or not re.fullmatch(r"[0-9a-f]{64}", model_lock_hash)
        or sha256(DA3_MODEL_LOCK) != model_lock_hash
    ):
        fail("DA3 model lock is missing or does not match its builder receipt")

    msplat_source = str(msplat.get("source_url") or msplat.get("source_repo") or "")
    msplat_revision = str(msplat.get("source_commit") or "")
    msplat_version = str(msplat.get("source_version") or "")
    msplat_license = root / "msplat" / "LICENSE"
    if (
        not msplat_source
        or not msplat_revision
        or not msplat_version
        or not msplat_license.is_file()
    ):
        fail("msplat builder receipt or license is incomplete")

    if "python:opencv-python-headless" in python_components:
        fail("opencv-python-headless is forbidden from the lean release toolchain")

    components = aggregate_native_components(root, distribution_signing)
    components.update({
        "msplat": {
            "id": "msplat",
            "name": "msplat",
            "type": "executable",
            "version": msplat_version,
            "revision": msplat_revision,
            "source": msplat_source,
            "license": "Apache-2.0",
            "licenseFiles": [relative(msplat_license, root)],
            "linkage": "executable",
            "dependencies": [
                "msplat:cli11",
                "msplat:nanoflann",
                "msplat:nlohmann-json",
            ],
        },
    })

    static_dependencies = [
        (
            "msplat:cli11",
            "CLI11",
            "2.4.2",
            "https://github.com/CLIUtils/CLI11",
            "BSD-3-Clause",
            "CLI11/LICENSE",
        ),
        (
            "msplat:nanoflann",
            "nanoflann",
            "1.5.5",
            "https://github.com/jlblancoc/nanoflann",
            "BSD-2-Clause",
            "nanoflann/COPYING",
        ),
        (
            "msplat:nlohmann-json",
            "nlohmann-json",
            "3.11.3",
            "https://github.com/nlohmann/json",
            "MIT",
            "nlohmann-json/LICENSE.MIT",
        ),
    ]
    dependency_hashes = msplat.get("dependencies", {})
    dependency_receipt_keys = {
        "msplat:cli11": "cli11_v2.4.2_sha256",
        "msplat:nanoflann": "nanoflann_v1.5.5_sha256",
        "msplat:nlohmann-json": "nlohmann_json_v3.11.3_sha256",
    }
    for (
        component_id,
        name,
        dep_version,
        source,
        expression,
        license_path,
    ) in static_dependencies:
        path = root / "licenses" / "msplat" / license_path
        if not path.is_file():
            fail(f"missing static dependency license: {path}")
        dependency_hash = str(
            dependency_hashes.get(dependency_receipt_keys[component_id]) or ""
        )
        if not re.fullmatch(r"[0-9a-f]{64}", dependency_hash):
            fail(f"msplat receipt is missing the verified archive hash for {name}")
        components[component_id] = {
            "id": component_id,
            "name": name,
            "type": "static-dependency",
            "version": dep_version,
            "revision": f"sha256:{dependency_hash}",
            "source": source,
            "license": normalize_license(expression),
            "licenseFiles": [relative(path, root)],
            "linkage": "compiled-in",
            "dependencies": [],
            "incorporatedInto": ["msplat"],
        }

    da3_source = str(da3.get("source_repo") or da3.get("expected_upstream_repo") or "")
    da3_revision = str(da3.get("source_commit") or "")
    vendor_license = root / "da3_mps" / "vendor" / "depth-anything-3" / "LICENSE"
    if not da3_source or not da3_revision or not vendor_license.is_file():
        fail("DA3 source receipt or vendor license is incomplete")
    components["da3"] = {
        "id": "da3",
        "name": "Depth Anything 3",
        "type": "python-source",
        "version": str(da3.get("source_ref") or da3_revision),
        "revision": da3_revision,
        "source": da3_source,
        "license": "Apache-2.0",
        "licenseFiles": [relative(vendor_license, root)],
        "linkage": "python",
        "dependencies": [],
    }

    project_license = root / "licenses" / "EasySplat" / "LICENSE"
    components["easysplat-da3-runner"] = {
        "id": "easysplat-da3-runner",
        "name": "EasySplat DA3 runner",
        "type": "script",
        "version": version,
        "revision": repository_revision,
        "source": "https://github.com/dud8/EasySplat",
        "license": "MIT",
        "licenseFiles": [relative(project_license, root)],
        "linkage": "python",
        "dependencies": ["da3", "python-build-standalone"],
    }

    python_receipt = (
        root / "da3_mps" / "licenses" / "python-build-standalone" / "PYTHON.json"
    )
    python_notices = (
        root / "da3_mps" / "licenses" / "python-build-standalone" / "licenses"
    )
    python_sha256 = str(da3.get("python_standalone_sha256") or "")
    if (
        not python_receipt.is_file()
        or not python_notices.is_dir()
        or not re.fullmatch(r"[0-9a-f]{64}", python_sha256)
    ):
        fail("python-build-standalone license or provenance closure is missing")
    components["python-build-standalone"] = {
        "id": "python-build-standalone",
        "name": "python-build-standalone",
        "type": "runtime",
        "version": str(da3.get("python_version") or ""),
        "revision": f"sha256:{python_sha256}",
        "source": str(da3.get("python_standalone_url") or ""),
        "license": "LicenseRef-Python-Build-Standalone-Closure",
        "licenseFiles": [relative(python_receipt, root)]
        + sorted(
            relative(path, root) for path in python_notices.rglob("*") if path.is_file()
        ),
        "linkage": "runtime",
        "dependencies": [],
    }

    for model_name in ("DA3-BASE", "DA3-SMALL"):
        model_root = root / "da3_mps" / "models" / model_name
        info = load_json(model_root / "easysplat_model_info.json")
        reviewed = reviewed_models[model_name]
        if info != reviewed:
            fail(f"{model_name} model metadata does not match the reviewed model lock")
        model_license = model_root / "LICENSE"
        if not model_license.is_file():
            fail(f"{model_name} license is missing")
        source_artifacts = []
        for filename in ("config.json", "model.safetensors"):
            path = model_root / filename
            artifact = reviewed["artifacts"][filename]
            if not path.is_file() or path.is_symlink():
                fail(f"{model_name} model artifact is missing or unsafe: {filename}")
            if path.stat().st_size != artifact["size_bytes"]:
                fail(
                    f"{model_name} {filename} artifact byte size does not match the lock"
                )
            if sha256(path) != artifact["sha256"]:
                fail(
                    f"{model_name} {filename} artifact SHA-256 does not match the lock"
                )
            source_artifacts.append(
                {
                    "name": filename,
                    "sha256": artifact["sha256"],
                    "size": artifact["size_bytes"],
                    "url": (
                        f"https://huggingface.co/{reviewed['repo_id']}/resolve/"
                        f"{reviewed['resolved_sha']}/{filename}"
                    ),
                }
            )
        component_id = f"model:{model_name.lower()}"
        components[component_id] = {
            "id": component_id,
            "name": model_name,
            "type": "model",
            "version": str(info.get("requested_revision") or ""),
            "revision": str(info.get("resolved_sha") or ""),
            "source": f"https://huggingface.co/{info.get('repo_id', '')}",
            "license": normalize_license(info.get("license")),
            "licenseFiles": [relative(model_license, root)],
            "linkage": "model-data",
            "dependencies": ["da3"],
            "sourceArtifacts": source_artifacts,
        }
    return components


def load_distribution_signing_receipt(
    root: Path,
    receipt_path: Path,
    version: str,
    packaged_machos: set[Path],
    *,
    repository_root: Path | None = None,
    repository_commit: str | None = None,
) -> dict[str, Any]:
    expected_path = root / "provenance" / "distribution-signing.json"
    try:
        if receipt_path.resolve(strict=True) != expected_path.resolve(strict=True):
            fail(
                "distribution-signing receipt must be the canonical internal provenance file"
            )
        metadata = expected_path.lstat()
    except OSError as exc:
        fail(f"distribution-signing receipt is missing or unsafe: {exc}")
    if (
        expected_path.is_symlink()
        or not expected_path.is_file()
        or metadata.st_nlink != 1
        or metadata.st_size > MAX_DISTRIBUTION_SIGNING_RECEIPT_BYTES
    ):
        fail("distribution-signing receipt is unsafe or exceeds 1 MiB")
    receipt = load_json(expected_path)
    required = {
        "schemaVersion",
        "kind",
        "toolchainVersion",
        "identityFingerprintSHA1",
        "teamID",
        "signedAt",
        "sourceCommit",
        "sourceInputs",
        "unsignedComponentArchives",
        "builderAttestedUnsignedRequestSHA256",
        "builderAttestedUnsignedManifestSHA256",
        "unsignedSupplyChainSHA256",
        "machOFiles",
        "recordRepairs",
    }
    if set(receipt) != required:
        fail("distribution-signing receipt fields do not match schema 1")
    if (
        receipt.get("schemaVersion") != 1
        or receipt.get("kind") != "easysplat-distribution-signing"
        or receipt.get("toolchainVersion") != version
        or not re.fullmatch(
            r"[0-9A-F]{40}", str(receipt.get("identityFingerprintSHA1") or "")
        )
        or not re.fullmatch(r"[A-Z0-9]{10}", str(receipt.get("teamID") or ""))
        or not re.fullmatch(r"[0-9a-f]{40}", str(receipt.get("sourceCommit") or ""))
        or not SHA256_PATTERN.fullmatch(
            str(receipt.get("unsignedSupplyChainSHA256") or "")
        )
        or not SHA256_PATTERN.fullmatch(
            str(receipt.get("builderAttestedUnsignedRequestSHA256") or "")
        )
        or not SHA256_PATTERN.fullmatch(
            str(receipt.get("builderAttestedUnsignedManifestSHA256") or "")
        )
        or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",
            str(receipt.get("signedAt") or ""),
        )
    ):
        fail("distribution-signing receipt identity or version fields are invalid")
    repository_root = repository_root or Path(__file__).resolve().parents[2]
    repository_commit = repository_commit or run(
        "git", "rev-parse", "HEAD", cwd=repository_root
    ).strip()
    if receipt["sourceCommit"] != repository_commit:
        fail("distribution-signing receipt is not bound to the current source commit")
    source_inputs = receipt.get("sourceInputs")
    if not isinstance(source_inputs, list) or not source_inputs:
        fail("distribution-signing receipt has no tracked source-input closure")
    bound_inputs: set[str] = set()
    for row in source_inputs:
        if not isinstance(row, dict) or set(row) != {"path", "sha256"}:
            fail("distribution-signing source-input row is invalid")
        relative = str(row.get("path") or "")
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts or relative in bound_inputs:
            fail("distribution-signing source-input path is unsafe or duplicated")
        source = repository_root.joinpath(*pure.parts)
        if (
            not source.is_file()
            or source.is_symlink()
            or row.get("sha256") != sha256(source)
        ):
            fail(f"distribution-signing source input does not match tracked bytes: {relative}")
        bound_inputs.add(relative)
    if bound_inputs != DISTRIBUTION_SIGNING_SOURCE_INPUTS:
        fail("distribution-signing tracked source-input closure is incomplete")

    unsigned_archives = receipt.get("unsignedComponentArchives")
    if not isinstance(unsigned_archives, list) or len(unsigned_archives) != 3:
        fail("distribution-signing receipt has an invalid source archive closure")
    archive_components: set[str] = set()
    for row in unsigned_archives:
        if not isinstance(row, dict) or set(row) != {
            "component",
            "name",
            "sha256",
            "size",
        }:
            fail("distribution-signing source archive row is invalid")
        component = str(row.get("component") or "")
        name = str(row.get("name") or "")
        size = row.get("size")
        if (
            component in archive_components
            or component not in {"core", "base", "small"}
            or PurePosixPath(name).name != name
            or any(ord(character) <= 0x20 or ord(character) >= 0x7F for character in name)
            or not name.endswith(".zip")
            or not SHA256_PATTERN.fullmatch(str(row.get("sha256") or ""))
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size <= 0
            or size >= 2 * 1024 * 1024 * 1024
        ):
            fail("distribution-signing source archive identity is invalid")
        archive_components.add(component)
    if archive_components != {"core", "base", "small"}:
        fail("distribution-signing source archive component set is incomplete")

    source_manifest = root / "supply-chain" / "components.json"
    if (
        not source_manifest.is_file()
        or source_manifest.is_symlink()
        or source_manifest.stat().st_size > 16 * 1024 * 1024
        or sha256(source_manifest) != receipt["unsignedSupplyChainSHA256"]
    ):
        fail("distribution-signing receipt does not bind the unsigned supply-chain manifest")
    source_payload = load_json(source_manifest)
    source_file_rows = source_payload.get("files")
    if not isinstance(source_file_rows, list):
        fail("unsigned supply-chain manifest has no file closure")
    source_files: dict[str, dict[str, Any]] = {}
    for row in source_file_rows:
        if not isinstance(row, dict):
            fail("unsigned supply-chain manifest contains a non-object file row")
        relative = str(row.get("path") or "")
        if relative in source_files:
            fail("unsigned supply-chain manifest contains duplicate file rows")
        source_files[relative] = row

    raw_machos = receipt.get("machOFiles")
    if not isinstance(raw_machos, list):
        fail("distribution-signing receipt has no Mach-O file closure")
    receipt_paths: set[str] = set()
    python_record_provenance: dict[str, tuple[str, str]] = {}
    for row in raw_machos:
        if not isinstance(row, dict) or set(row) != {
            "path",
            "component",
            "preSignSHA256",
            "postSignSHA256",
            "preSignProvenance",
            "codesign",
        }:
            fail("distribution-signing receipt contains a non-object Mach-O row")
        relative = str(row.get("path") or "")
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts or relative in receipt_paths:
            fail("distribution-signing receipt has unsafe or duplicate Mach-O paths")
        path = root.joinpath(*pure.parts)
        source_row = source_files.get(relative)
        provenance = row.get("preSignProvenance")
        if (
            not path.is_file()
            or path.is_symlink()
            or path.resolve(strict=True) not in packaged_machos
            or not SHA256_PATTERN.fullmatch(str(row.get("preSignSHA256") or ""))
            or row.get("postSignSHA256") != sha256(path)
            or not isinstance(provenance, list)
            or source_row is None
            or source_row.get("kind") != "mach-o"
            or source_row.get("sha256") != row.get("preSignSHA256")
            or source_row.get("component") != row.get("component")
            or not isinstance(row.get("codesign"), dict)
            or row["codesign"].get("teamIdentifier") != receipt["teamID"]
            or row["codesign"].get("hardenedRuntime") is not True
        ):
            fail(f"distribution-signing Mach-O bridge is stale or invalid: {relative}")
        supply_rows = [
            item
            for item in provenance
            if isinstance(item, dict) and item.get("kind") == "supply-chain"
        ]
        if supply_rows != [
            {
                "kind": "supply-chain",
                "path": "supply-chain/components.json",
                "component": row["component"],
                "sha256": row["preSignSHA256"],
            }
        ]:
            fail(f"distribution-signing Mach-O lacks exact source provenance: {relative}")
        record_rows = [
            item
            for item in provenance
            if isinstance(item, dict) and item.get("kind") == "python-record"
        ]
        if len(record_rows) > 1:
            fail(f"distribution-signing Mach-O has ambiguous RECORD provenance: {relative}")
        if record_rows:
            record_row = record_rows[0]
            if set(record_row) != {"kind", "path", "member", "sha256"} or record_row.get(
                "sha256"
            ) != row.get("preSignSHA256"):
                fail(f"distribution-signing Python RECORD provenance is invalid: {relative}")
            python_record_provenance[relative] = (
                str(record_row.get("path") or ""),
                str(record_row.get("member") or ""),
            )
        for item in provenance:
            if not isinstance(item, dict) or item.get("kind") not in {
                "supply-chain",
                "build-receipt",
                "python-record",
            }:
                fail(f"distribution-signing Mach-O has unknown provenance: {relative}")
        receipt_paths.add(relative)
    actual_paths = {
        path.relative_to(root).as_posix() for path in packaged_machos
    }
    if receipt_paths != actual_paths:
        fail("distribution-signing receipt has a missing or extra Mach-O bridge")

    repairs = receipt.get("recordRepairs")
    if not isinstance(repairs, list):
        fail("distribution-signing receipt has no RECORD repair closure")
    repaired_paths: set[str] = set()
    repaired_members: set[str] = set()
    for row in repairs:
        if not isinstance(row, dict):
            fail("distribution-signing receipt contains a non-object RECORD repair")
        relative = str(row.get("path") or "")
        path = root.joinpath(*PurePosixPath(relative).parts)
        members = row.get("signedMembers")
        source_record = source_files.get(relative)
        if (
            relative in repaired_paths
            or not relative.endswith(".dist-info/RECORD")
            or not path.is_file()
            or path.is_symlink()
            or not SHA256_PATTERN.fullmatch(str(row.get("preRepairSHA256") or ""))
            or row.get("postRepairSHA256") != sha256(path)
            or source_record is None
            or source_record.get("sha256") != row.get("preRepairSHA256")
            or not isinstance(members, list)
            or not members
        ):
            fail(f"distribution-signing RECORD repair is stale or invalid: {relative}")
        for member in members:
            if not isinstance(member, dict) or set(member) != {
                "path",
                "preSignSHA256",
                "postSignSHA256",
            }:
                fail(f"distribution-signing RECORD repair member is invalid: {relative}")
            member_path = str(member.get("path") or "")
            macho_row = next(
                (
                    candidate
                    for candidate in raw_machos
                    if isinstance(candidate, dict) and candidate.get("path") == member_path
                ),
                None,
            )
            provenance_path = python_record_provenance.get(member_path, ("", ""))[0]
            if (
                member_path in repaired_members
                or macho_row is None
                or provenance_path != relative
                or member.get("preSignSHA256") != macho_row.get("preSignSHA256")
                or member.get("postSignSHA256") != macho_row.get("postSignSHA256")
            ):
                fail(f"distribution-signing RECORD repair member is stale: {member_path}")
            repaired_members.add(member_path)
        repaired_paths.add(relative)
    if repaired_members != set(python_record_provenance):
        fail("distribution-signing RECORD repair member closure is incomplete")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain-root", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--distribution-signing-receipt", type=Path)
    parser.add_argument("--reviewed-source-root", type=Path)
    parser.add_argument("--reviewed-source-commit")
    args = parser.parse_args()
    root = args.toolchain_root.resolve()
    if (args.reviewed_source_root is None) != (
        args.reviewed_source_commit is None
    ):
        fail("reviewed source root and commit must be supplied together")
    if args.reviewed_source_root is None:
        repository_root = Path(__file__).resolve().parents[2]
        repository_commit = run(
            "git", "rev-parse", "HEAD", cwd=repository_root
        ).strip()
    else:
        repository_root = args.reviewed_source_root.resolve(strict=True)
        repository_commit = str(args.reviewed_source_commit)
        if not re.fullmatch(r"[0-9a-f]{40}", repository_commit):
            fail("reviewed source commit must be a full Git commit")

    packaged_machos: set[Path] = set()
    for candidate in root.rglob("*"):
        source = materialized_source(candidate, root)
        if is_macho(source):
            packaged_machos.add(source.resolve(strict=True))
            validate_arm64_only(source)
            validate_macos_15_compatibility(source)

    distribution_signing = None
    if args.distribution_signing_receipt is not None:
        distribution_signing = load_distribution_signing_receipt(
            root,
            args.distribution_signing_receipt,
            args.version,
            packaged_machos,
            repository_root=repository_root,
            repository_commit=repository_commit,
        )

    supplemental_ownership = validate_supplemental_license_receipts(root)
    distributions, python_ownership = python_components(
        root, supplemental_ownership=supplemental_ownership
    )
    components = builder_components(
        root,
        args.version,
        distributions,
        distribution_signing,
        repository_root=repository_root,
        repository_revision=repository_commit,
    )
    components.update(distributions)
    if distribution_signing is not None:
        components["easysplat-distribution-signing"] = {
            "id": "easysplat-distribution-signing",
            "name": "EasySplat distribution signing",
            "type": "distribution-signing",
            "version": args.version,
            "revision": f"sha256:{sha256(root / 'provenance/distribution-signing.json')}",
            "source": "https://github.com/dud8/EasySplat",
            "license": "MIT",
            "licenseFiles": ["licenses/EasySplat/LICENSE"],
            "linkage": "distribution-process",
            "dependencies": [],
        }

    ownership: dict[str, str] = {
        "bin/colmap": "colmap",
        "bin/easysplat-train": "msplat",
        "bin/default.metallib": "msplat",
        "lib/libomp.dylib": "colmap-support:libomp",
        "provenance/colmap.json": "colmap",
        "provenance/colmap-support.json": "colmap-support",
        "provenance/ceres.json": "ceres",
        "provenance/openimageio.json": "openimageio",
    }
    if distribution_signing is not None:
        ownership["provenance/distribution-signing.json"] = (
            "easysplat-distribution-signing"
        )
    license_ownership: dict[str, str] = {}
    for component_id, component in components.items():
        for license_file in component.get("licenseFiles", []):
            if str(license_file).startswith("licenses/EasySplat/"):
                continue
            license_ownership.setdefault(str(license_file), component_id)
    files: list[dict[str, Any]] = []
    component_files: dict[str, list[str]] = defaultdict(list)
    macho_owner_by_name: dict[str, set[str]] = defaultdict(set)

    def owner_for(path: Path, path_text: str) -> str:
        if path_text in ownership:
            return ownership[path_text]
        if path_text in license_ownership:
            return license_ownership[path_text]
        resolved = path.resolve(strict=False)
        if resolved in python_ownership:
            return python_ownership[resolved]
        if path_text.startswith("da3_mps/python/"):
            return "python-build-standalone"
        if path_text.startswith("da3_mps/models/DA3-BASE/"):
            return "model:da3-base"
        if path_text.startswith("da3_mps/models/DA3-SMALL/"):
            return "model:da3-small"
        if path_text.startswith("da3_mps/vendor/"):
            return "da3"
        if path_text in {
            "da3_mps/licenses/python-packages-install-report.json",
            "da3_mps/licenses/python-packages-requirements.txt",
        }:
            return "python-build-standalone"
        if path_text.startswith("da3_mps/licenses/python-build-standalone/"):
            return "python-build-standalone"
        if path_text.startswith("da3_mps/"):
            return "easysplat-da3-runner"
        if path_text.startswith(("msplat/", "licenses/msplat/")):
            if "/CLI11/" in f"/{path_text}":
                return "msplat:cli11"
            if "/nanoflann/" in f"/{path_text}":
                return "msplat:nanoflann"
            if "/nlohmann-json/" in f"/{path_text}":
                return "msplat:nlohmann-json"
            return "msplat"
        if path_text.startswith("licenses/EasySplat/"):
            return "easysplat-da3-runner"
        if path_text.startswith("licenses/python-packages/"):
            slug = path_text.split("/", 3)[2]
            return f"python:{slug}"
        fail(f"packaged file has no component owner: {path_text}")

    manifest_path = root / "supply-chain" / "components.json"
    for path in sorted(root.rglob("*")):
        if path == manifest_path:
            continue
        if not (path.is_file() or path.is_symlink()):
            continue
        path_text = relative(path, root)
        component_id = owner_for(path, path_text)
        if component_id not in components:
            fail(f"file owner has no component receipt: {path_text} -> {component_id}")
        source = materialized_source(path, root)
        entry: dict[str, Any] = {
            "path": path_text,
            "component": component_id,
            "kind": "file",
            "sha256": sha256(source),
            "size": source.stat().st_size,
        }
        if is_macho(source):
            entry["kind"] = "mach-o"
            raw_dependencies = [
                line.split()[0]
                for line in run("otool", "-L", str(source)).splitlines()[1:]
                if line.strip()
            ]
            validate_macho_dependencies(
                path_text,
                raw_dependencies,
                macho_install_id(source),
                root=root,
                source=source.resolve(strict=True),
                packaged_machos=packaged_machos,
            )
            entry["dependencies"] = raw_dependencies
            macho_owner_by_name[path.name].add(component_id)
        files.append(entry)
        component_files[component_id].append(path_text)

    for entry in files:
        if entry.get("kind") != "mach-o":
            continue
        owner = entry["component"]
        for dependency in entry.get("dependencies", []):
            name = PurePosixPath(dependency).name
            candidates = macho_owner_by_name.get(name, set())
            if len(candidates) == 1:
                dependency_owner = next(iter(candidates))
                if dependency_owner != owner:
                    components[owner]["dependencies"].append(dependency_owner)

    resolve_installed_dependencies(components)
    validate_component_urls(components)
    for component_id, component in components.items():
        component["buildCommand"] = component_build_command(component_id, component)
        required = (
            "version",
            "revision",
            "source",
            "buildCommand",
            "license",
            "licenseFiles",
            "linkage",
            "dependencies",
        )
        missing = [
            key
            for key in required
            if not component.get(key) and key not in {"dependencies"}
        ]
        if missing:
            fail(f"component {component_id} is missing: {', '.join(missing)}")
        for license_file in component["licenseFiles"]:
            if not (root / license_file).is_file():
                fail(
                    f"component {component_id} refers to a missing license file: {license_file}"
                )
        component["files"] = sorted(component_files.get(component_id, []))

    files.sort(key=lambda entry: entry["path"])
    payload = {
        "schemaVersion": 1,
        "toolchainVersion": args.version,
        "components": [components[key] for key in sorted(components)],
        "files": files,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"Supply-chain closure: {len(components)} components, {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
