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
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn


PYCOLMAP_VERSION = "4.1.0"
PYCOLMAP_SOURCE_COMMIT = "fa8e3b3ff591552855f8ad2806723c80f963f69c"
FAISS_VERSION = "1.14.1"
FAISS_SOURCE_COMMIT = "5622e93733b64b2e033362dbdfda019b2ab33ef0"
FAISS_SOURCE_ARCHIVE_URL = (
    "https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.1.zip"
)
FAISS_SOURCE_ARCHIVE_SHA256 = (
    "4b1ae7e7a0a46385b4084f0e3945623a15fcf99d793bf44d82aae8e24f11e5f5"
)
FAISS_LICENSE_SHA256 = (
    "52412d7bc7ce4157ea628bbaacb8829e0a9cb3c58f57f99176126bc8cf2bfc85"
)
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
}
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
    "faiss": {
        "package": "faiss",
        "version": FAISS_VERSION,
        "license": "MIT",
        "source": "https://github.com/facebookresearch/faiss",
        "sourceCommit": FAISS_SOURCE_COMMIT,
        "artifact": (
            "https://raw.githubusercontent.com/facebookresearch/faiss/"
            f"{FAISS_SOURCE_COMMIT}/LICENSE"
        ),
        "artifactSha256": FAISS_LICENSE_SHA256,
        "distInfo": f"pycolmap-{PYCOLMAP_VERSION}.dist-info",
        "filename": "FAISS-LICENSE",
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
            fail(f"{path} requires macOS {value}; public beta minimum is macOS 15.0")


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
    tokens = re.findall(r"\(|\)|AND|OR|[A-Za-z0-9][A-Za-z0-9.+-]*", normalized)
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
    if component_id == "msplat" or component_id.startswith("msplat:"):
        return "./scripts/toolchain/build_msplat.sh"
    if component_id in {
        "da3",
        "easysplat-colmap-bridge",
        "easysplat-da3-bridge",
        "faiss",
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
        if path.suffix == ".pyc":
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
) -> None:
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
) -> tuple[dict[str, dict[str, Any]], dict[Path, str]]:
    python_root = root / "da3_mps" / "python"
    python_license_root = reset_python_license_receipts(root)
    report_path = root / "da3_mps" / "licenses" / "python-packages-install-report.json"
    report = load_json(report_path)
    installed_artifacts: dict[str, tuple[str, str, str]] = {}
    for entry in report.get("install", []):
        metadata = entry.get("metadata", {})
        name = str(metadata.get("name") or "").strip()
        version = str(metadata.get("version") or "").strip()
        download = entry.get("download_info", {})
        source_url = str(download.get("url") or "")
        archive_info = download.get("archive_info", {})
        hashes = archive_info.get("hashes", {})
        artifact_hash = str(hashes.get("sha256") or "")
        if not artifact_hash:
            raw_hash = str(archive_info.get("hash") or "")
            if raw_hash.startswith("sha256="):
                artifact_hash = raw_hash.removeprefix("sha256=")
        if (
            not name
            or not version
            or not source_url.startswith("https://")
            or not re.fullmatch(r"[0-9a-f]{64}", artifact_hash)
        ):
            fail(
                f"pip install report contains incomplete artifact provenance for {name or '<unknown>'}"
            )
        slug = re.sub(r"[-_.]+", "-", name).lower()
        if slug in installed_artifacts:
            fail(f"pip install report contains duplicate distribution: {name}")
        installed_artifacts[slug] = (version, source_url, artifact_hash)

    components: dict[str, dict[str, Any]] = {}
    ownership: dict[Path, str] = {}
    for metadata_path in distribution_metadata_paths(python_root):
        metadata = email.message_from_bytes(metadata_path.read_bytes())
        name = metadata.get("Name", "").strip()
        version = metadata.get("Version", "").strip()
        if not name or not version:
            fail(f"incomplete Python package metadata: {metadata_path}")
        slug = re.sub(r"[-_.]+", "-", name).lower()
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
                    f"python:{re.sub(r'[-_.]+', '-', dependency).lower()}"
                )
        if slug == "pycolmap":
            dependencies.append("faiss")
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
        elif slug != "pip":
            fail(
                f"installed Python distribution has no hashed pip report entry: {name}"
            )

        site_packages = metadata_path.parent.parent
        record = metadata_path.parent / "RECORD"
        if not record.is_file():
            fail(f"Python distribution has no RECORD: {name}")
        with record.open(newline="", encoding="utf-8") as stream:
            for row in csv.reader(stream):
                if not row:
                    continue
                candidate = (site_packages / row[0]).resolve(strict=False)
                encoded_hash = row[1] if len(row) > 1 else ""
                encoded_size = row[2] if len(row) > 2 else ""
                if validate_record_member(
                    candidate,
                    encoded_hash,
                    encoded_size,
                    python_root=python_root,
                    distribution=name,
                ):
                    ownership[candidate] = component_id
        for path in metadata_path.parent.rglob("*"):
            if path.is_file() or path.is_symlink():
                ownership[path.resolve(strict=False)] = component_id
    if installed_artifacts:
        fail(
            f"pip install report packages are missing from the runtime: {sorted(installed_artifacts)}"
        )
    return components, ownership


def faiss_component(root: Path) -> dict[str, Any]:
    notice = REVIEWED_SUPPLEMENTAL_LICENSES["faiss"]
    candidates = sorted(
        root.glob(
            "da3_mps/python/lib/python*/site-packages/"
            f"{notice['distInfo']}/licenses/{notice['filename']}"
        )
    )
    if len(candidates) != 1 or not candidates[0].is_file():
        fail("FAISS compiled-in dependency notice is missing or ambiguous")
    return {
        "id": "faiss",
        "name": "FAISS",
        "type": "static-dependency",
        "version": FAISS_VERSION,
        "revision": FAISS_SOURCE_COMMIT,
        "source": "https://github.com/facebookresearch/faiss",
        "artifact": FAISS_SOURCE_ARCHIVE_URL,
        "artifactSha256": FAISS_SOURCE_ARCHIVE_SHA256,
        "license": "MIT",
        "licenseFiles": [relative(candidates[0], root)],
        "linkage": "compiled-in",
        "dependencies": [],
        "incorporatedInto": ["python:pycolmap"],
    }


def colmap_bridge_component(
    root: Path,
    version: str,
    repository_revision: str,
    python_components: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    receipt = load_json(root / "provenance" / "colmap.json")
    executable = root / "bin" / "colmap"
    if not executable.is_file():
        fail("EasySplat COLMAP bridge executable is missing")

    pycolmap = python_components.get("python:pycolmap")
    if not isinstance(pycolmap, dict):
        fail("EasySplat COLMAP bridge requires PyCOLMAP")
    if "python:opencv-python-headless" in python_components:
        fail("opencv-python-headless is forbidden from the lean release toolchain")

    wheel_sha256 = str(pycolmap.get("artifactSha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", wheel_sha256):
        fail("PyCOLMAP has no exact wheel SHA-256")
    expected_source = "https://github.com/colmap/colmap"
    if receipt.get("toolchain_name") != "colmap":
        fail("COLMAP bridge receipt has the wrong toolchain_name")
    if (
        receipt.get("source_url") != expected_source
        or receipt.get("source_repo") != expected_source
    ):
        fail("COLMAP bridge receipt has the wrong source repository")
    if (
        receipt.get("source_version") != PYCOLMAP_VERSION
        or pycolmap.get("version") != PYCOLMAP_VERSION
    ):
        fail(
            f"COLMAP bridge receipt does not identify PyCOLMAP {PYCOLMAP_VERSION}"
        )
    if receipt.get("source_commit") != PYCOLMAP_SOURCE_COMMIT:
        fail("COLMAP bridge receipt has an unreviewed PyCOLMAP source revision")
    if receipt.get("artifact_sha256") != wheel_sha256:
        fail("COLMAP bridge receipt is not bound to the PyCOLMAP wheel")
    if receipt.get("license") != "BSD-3-Clause":
        fail("COLMAP bridge receipt has the wrong PyCOLMAP license")
    if (
        receipt.get("backend") != "pycolmap"
        or receipt.get("runtime") != "bundled-python"
    ):
        fail("COLMAP bridge receipt does not identify its runtime")
    if receipt.get("executable_sha256") != sha256(executable):
        fail("COLMAP bridge receipt does not match the installed executable")
    da3_receipt = load_json(root / "da3_mps" / "build_info.json")
    if (
        receipt.get("bridge_source") != da3_receipt.get("colmap_bridge_source")
        or receipt.get("bridge_source_sha256")
        != da3_receipt.get("colmap_bridge_source_sha256")
        or receipt.get("supplemental_license_manifest_sha256")
        != da3_receipt.get("supplemental_license_manifest_sha256")
    ):
        fail("COLMAP bridge provenance does not match the DA3 builder receipt")

    project_license = root / "licenses" / "EasySplat" / "LICENSE"
    if not project_license.is_file():
        fail("EasySplat license is missing")
    return {
        "id": "easysplat-colmap-bridge",
        "name": "EasySplat COLMAP bridge",
        "type": "executable-wrapper",
        "version": version,
        "revision": repository_revision,
        "source": "https://github.com/dud8/EasySplat",
        "runtimeVersion": PYCOLMAP_VERSION,
        "runtimeRevision": PYCOLMAP_SOURCE_COMMIT,
        "license": "MIT",
        "licenseFiles": [relative(project_license, root)],
        "linkage": "python-launcher",
        "dependencies": [
            "python-build-standalone",
            "python:pycolmap",
        ],
    }


def validate_da3_bridge_receipt(root: Path, receipt: dict[str, Any]) -> None:
    bindings = (
        (
            "launcher hash",
            root / "da3_mps/bin/easysplat_colmap",
            "colmap_launcher_sha256",
        ),
        (
            "bridge source hash",
            root / "da3_mps/app/easysplat_da3_sfm/colmap_cli.py",
            "colmap_bridge_source_sha256",
        ),
        (
            "supplemental license manifest hash",
            root / "da3_mps/licenses/python-package-upstream-notices.json",
            "supplemental_license_manifest_sha256",
        ),
    )
    for label, path, field in bindings:
        expected = str(receipt.get(field) or "")
        if not re.fullmatch(r"[0-9a-f]{64}", expected) or not path.is_file():
            fail(f"DA3 build receipt has no valid {label}")
        if sha256(path) != expected:
            fail(f"DA3 build receipt {label} does not match the packaged file")


def builder_components(
    root: Path,
    version: str,
    python_components: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    msplat = load_json(root / "msplat" / "build_info.json")
    da3 = load_json(root / "da3_mps" / "build_info.json")
    validate_da3_bridge_receipt(root, da3)
    repository_revision = run("git", "rev-parse", "HEAD", cwd=root.parents[1]).strip()
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

    components: dict[str, dict[str, Any]] = {
        "easysplat-colmap-bridge": colmap_bridge_component(
            root,
            version,
            repository_revision,
            python_components,
        ),
        "faiss": faiss_component(root),
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
    }

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
    components["easysplat-da3-bridge"] = {
        "id": "easysplat-da3-bridge",
        "name": "EasySplat DA3 bridge",
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
        model_license = model_root / "LICENSE"
        if not model_license.is_file():
            fail(f"{model_name} license is missing")
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
        }
    return components


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain-root", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    root = args.toolchain_root.resolve()

    packaged_machos: set[Path] = set()
    for candidate in root.rglob("*"):
        source = materialized_source(candidate, root)
        if is_macho(source):
            packaged_machos.add(source.resolve(strict=True))
            validate_arm64_only(source)
            validate_macos_15_compatibility(source)

    validate_supplemental_license_receipts(root)
    distributions, python_ownership = python_components(root)
    components = builder_components(root, args.version, distributions)
    components.update(distributions)

    ownership: dict[str, str] = {
        "bin/colmap": "easysplat-colmap-bridge",
        "bin/easysplat-train": "msplat",
        "bin/default.metallib": "msplat",
        "da3_mps/bin/easysplat_colmap": "easysplat-colmap-bridge",
        "provenance/colmap.json": "easysplat-colmap-bridge",
    }
    files: list[dict[str, Any]] = []
    component_files: dict[str, list[str]] = defaultdict(list)
    macho_owner_by_name: dict[str, set[str]] = defaultdict(set)

    def owner_for(path: Path, path_text: str) -> str:
        if path_text in ownership:
            return ownership[path_text]
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
            return "easysplat-da3-bridge"
        if path_text.startswith(("msplat/", "licenses/msplat/")):
            if "/CLI11/" in f"/{path_text}":
                return "msplat:cli11"
            if "/nanoflann/" in f"/{path_text}":
                return "msplat:nanoflann"
            if "/nlohmann-json/" in f"/{path_text}":
                return "msplat:nlohmann-json"
            return "msplat"
        if path_text.startswith("licenses/EasySplat/"):
            return "easysplat-da3-bridge"
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
