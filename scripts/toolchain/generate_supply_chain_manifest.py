#!/usr/bin/env python3
"""Build the fail-closed license, provenance, and file closure for a toolchain."""

from __future__ import annotations

import argparse
import csv
import email
import hashlib
import json
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, NoReturn

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_homebrew_lock import LockError as HomebrewLockError  # noqa: E402
from verify_homebrew_lock import load_homebrew_provenance  # noqa: E402


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
LICENSE_NAME = re.compile(r"^(license|licence|copying|notice)([._-].*)?$", re.IGNORECASE)
KNOWN_LICENSE_ALIASES = {
    "apache 2.0": "Apache-2.0",
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
    "isc license (iscl)": "ISC",
    "boost software license": "BSL-1.0",
    "bsl-1.0": "BSL-1.0",
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
PINNED_RECEIPTS: dict[str, dict[str, str]] = {
    "colmap": {
        "source_url": "https://github.com/colmap/colmap.git",
        "source_commit": "fa8e3b3ff591552855f8ad2806723c80f963f69c",
        "source_version": "4.1.0",
        "license": "BSD-3-Clause",
    },
    "openimageio": {
        "source_url": "https://github.com/AcademySoftwareFoundation/OpenImageIO.git",
        "source_commit": "f32bf6e6f8de38ab6d197a72fd72366b66fd30a3",
        "source_version": "2.5.19.1",
        "license": "Apache-2.0 AND BSD-3-Clause AND BSD-2-Clause AND MIT",
    },
    "openimageio:fmt": {
        "source_url": "https://github.com/fmtlib/fmt.git",
        "source_commit": "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
        "source_version": "10.0.0",
        "license": "MIT",
    },
    "openimageio:robin-map": {
        "source_url": "https://github.com/Tessil/robin-map.git",
        "source_commit": "908ccf9f039a0e50813544c0444ca664ca292d7c",
        "source_version": "0.6.2",
        "license": "MIT",
    },
    "openimageio:pugixml": {
        "source_url": "https://github.com/AcademySoftwareFoundation/OpenImageIO/tree/f32bf6e6f8de38ab6d197a72fd72366b66fd30a3/src/include/OpenImageIO/detail/pugixml",
        "source_commit": "f32bf6e6f8de38ab6d197a72fd72366b66fd30a3",
        "source_version": "1.12",
        "source_tree_sha256": "316f7a67b75417c9cad506a4e14fac8488528b24e66e9fbf7cbe4fe88bbd1ed8",
        "upstream_source_url": "https://github.com/zeux/pugixml.git",
        "upstream_source_commit": "314baf6605143f1e837209008f490e8559529e1c",
        "upstream_source_tree_sha256": "fbd994ba2b46894d2a643f6fc19acb412554e297a0880666f402219b6aaf8864",
        "license": "MIT",
    },
    "colmap:poselib": {
        "source_url": "https://github.com/PoseLib/PoseLib/archive/fa7280fee27f97aff31ae7f98bab7f583fac7d08.zip",
        "source_commit": "fa7280fee27f97aff31ae7f98bab7f583fac7d08",
        "source_archive_sha256": "5408d4ae8ce367cb2f076bc6c5f0f6f78abd3573d2c015304b04e46f23455f5b",
        "license": "BSD-3-Clause",
    },
    "colmap:faiss": {
        "source_url": "https://github.com/facebookresearch/faiss/archive/refs/tags/v1.14.1.zip",
        "source_commit": "5622e93733b64b2e033362dbdfda019b2ab33ef0",
        "source_version": "1.14.1",
        "source_archive_sha256": "4b1ae7e7a0a46385b4084f0e3945623a15fcf99d793bf44d82aae8e24f11e5f5",
        "license": "MIT",
    },
    "colmap:poissonrecon": {
        "source_url": "https://github.com/colmap/colmap/tree/fa8e3b3ff591552855f8ad2806723c80f963f69c/src/thirdparty/PoissonRecon",
        "source_commit": "fa8e3b3ff591552855f8ad2806723c80f963f69c",
        "source_version": "vendored-at-colmap-4.1.0",
        "source_tree_sha256": "7aacb04853a3fece0d6b2eb3bbaaffe3c2014467ae3c73750c5dba1c6b2e835e",
        "license": "MIT",
    },
    "colmap:vlfeat": {
        "source_url": "https://github.com/colmap/colmap/tree/fa8e3b3ff591552855f8ad2806723c80f963f69c/src/thirdparty/VLFeat",
        "source_commit": "fa8e3b3ff591552855f8ad2806723c80f963f69c",
        "source_version": "vendored-at-colmap-4.1.0",
        "source_tree_sha256": "c1f3020a96d78e2f105aafa63f41b14cdf0a3886196f42f2dbc9c817ccd1d61e",
        "license": "BSD-2-Clause",
    },
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"supply-chain closure failed: {message}")


def require_pinned_receipt(
    receipt: dict[str, Any], expected: dict[str, str], component_id: str
) -> None:
    for key, value in expected.items():
        if receipt.get(key) != value:
            fail(
                f"{component_id} receipt {key} mismatch: "
                f"expected {value!r}, got {receipt.get(key)!r}"
            )


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
    versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$", output, re.MULTILINE)
    if not versions:
        versions = re.findall(r"^\s*version\s+(\d+(?:\.\d+){0,2})\s*$", output, re.MULTILINE)
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


def normalize_license(value: Any) -> str:
    if isinstance(value, str):
        normalized = KNOWN_LICENSE_ALIASES.get(value.strip().lower(), value.strip())
    elif isinstance(value, dict):
        if "all_of" in value:
            normalized = " AND ".join(f"({normalize_license(item)})" for item in value["all_of"])
        elif "any_of" in value:
            normalized = " OR ".join(f"({normalize_license(item)})" for item in value["any_of"])
        elif "with" in value and isinstance(value["with"], dict):
            entry = value["with"]
            normalized = f"{normalize_license(entry.get('license'))} WITH {entry.get('exception', '')}"
        else:
            fail(f"unsupported Homebrew license expression: {value!r}")
    else:
        fail(f"missing or unsupported license expression: {value!r}")
    if not normalized or normalized.upper() in {"UNKNOWN", "NOASSERTION", "NONE"}:
        fail(f"unknown license expression: {value!r}")
    if FORBIDDEN_LICENSE.search(normalized):
        fail(f"forbidden release license: {normalized}")
    return normalized


def metadata_license(metadata: email.message.Message) -> str:
    expression = metadata.get("License-Expression", "").strip()
    if expression:
        return normalize_license(expression)
    legacy = metadata.get("License", "").strip()
    if legacy and len(legacy) <= 160 and "\n" not in legacy:
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
    fail(f"Python package {metadata.get('Name', '<unknown>')} has no unambiguous license metadata")


def read_origins(path: Path) -> dict[str, Path]:
    origins: dict[str, Path] = {}
    try:
        rows = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail(f"cannot read dependency origin map: {exc}")
    for line_number, row in enumerate(rows, 1):
        fields = row.split("\t")
        if len(fields) != 2 or not fields[0] or not fields[1]:
            fail(f"malformed dependency origin at line {line_number}")
        destination, source = fields
        if destination in origins and origins[destination] != Path(source):
            fail(f"conflicting origins for {destination}")
        origins[destination] = Path(source)
    return origins


def formula_origin(path: Path) -> tuple[str, str] | None:
    match = re.search(r"/(?:homebrew/)?Cellar/([^/]+)/([^/]+)/", path.as_posix())
    return (match.group(1), match.group(2)) if match else None


def homebrew_component_id(formula: str) -> str:
    if formula == "xz":
        return "homebrew:xz:liblzma"
    if formula == "zstd":
        return "homebrew:zstd:libzstd"
    return f"homebrew:{formula}"


def component_build_command(component_id: str, component: dict[str, Any]) -> str:
    if component_id == "colmap" or component_id.startswith("colmap:"):
        return "./scripts/toolchain/build_colmap.sh"
    if component_id in {"ceres", "eigen"}:
        return "./scripts/toolchain/build_ceres.sh"
    if component_id == "suitesparse":
        return "./scripts/toolchain/build_suitesparse.sh"
    if component_id == "openimageio" or component_id.startswith("openimageio:"):
        return "./scripts/toolchain/build_openimageio.sh"
    if component_id == "msplat" or component_id.startswith("msplat:"):
        return "./scripts/toolchain/build_msplat.sh"
    if component_id in {"da3", "easysplat-da3-bridge", "python-build-standalone"} \
            or component_id.startswith(("model:", "python:")):
        return "./scripts/toolchain/build_da3_mps.sh"
    if component_id.startswith("homebrew:"):
        formula = component.get("formula")
        if isinstance(formula, str) and re.fullmatch(r"[A-Za-z0-9@+._-]+", formula):
            return f"brew install --build-from-source {formula}"
    fail(f"component has no reviewed build command: {component_id}")


def validate_homebrew_runtime_member(formula: str, destination: str) -> None:
    basename = PurePosixPath(destination).name
    if formula == "xz" and not (basename.startswith("liblzma") and basename.endswith(".dylib")):
        fail(f"xz contributes a non-liblzma runtime file: {destination}")
    if formula == "zstd" and not (basename.startswith("libzstd") and basename.endswith(".dylib")):
        fail(f"zstd contributes a non-libzstd runtime file: {destination}")


def homebrew_runtime_license(formula: str, declared: Any) -> str:
    if formula == "xz":
        return "0BSD"
    if formula == "zstd":
        return "BSD-3-Clause AND MIT"
    return normalize_license(declared)


def archive_license_members(archive: Path) -> list[tuple[str, bytes]]:
    candidates: list[tuple[int, str, bytes]] = []

    def accept(name: str, data: bytes) -> None:
        pure = PurePosixPath(name)
        if pure.is_absolute() or ".." in pure.parts or len(data) > 2 * 1024 * 1024:
            return
        parts = tuple(part for part in pure.parts if part not in {"", "."})
        if not parts or not LICENSE_NAME.match(parts[-1]):
            return
        depth = len(parts) - 1
        candidates.append((depth, "__".join(parts), data))

    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as handle:
            for info in handle.infolist():
                if info.is_dir() or (info.external_attr >> 16) & stat.S_IFLNK == stat.S_IFLNK:
                    continue
                if LICENSE_NAME.match(PurePosixPath(info.filename).name):
                    accept(info.filename, handle.read(info))
    else:
        try:
            with tarfile.open(archive, "r:*") as handle:
                for member in handle.getmembers():
                    if not member.isfile() or not LICENSE_NAME.match(PurePosixPath(member.name).name):
                        continue
                    stream = handle.extractfile(member)
                    if stream is not None:
                        accept(member.name, stream.read(2 * 1024 * 1024 + 1))
        except tarfile.TarError as exc:
            fail(f"cannot inspect source archive {archive}: {exc}")
    if not candidates:
        fail(f"source archive has no license or notice file: {archive}")
    shallowest = min(depth for depth, _, _ in candidates)
    return [(name, data) for depth, name, data in candidates if depth <= min(shallowest + 1, 3)]


def archive_member_with_suffix(archive: Path, suffix: str) -> tuple[str, bytes]:
    matches: list[tuple[str, bytes]] = []
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as handle:
            for info in handle.infolist():
                if not info.is_dir() and info.filename.endswith(suffix):
                    matches.append((info.filename, handle.read(info)))
    else:
        try:
            with tarfile.open(archive, "r:*") as handle:
                for member in handle.getmembers():
                    if member.isfile() and member.name.endswith(suffix):
                        stream = handle.extractfile(member)
                        if stream is not None:
                            matches.append((member.name, stream.read(2 * 1024 * 1024 + 1)))
        except tarfile.TarError as exc:
            fail(f"cannot inspect source archive {archive}: {exc}")
    if len(matches) != 1 or len(matches[0][1]) > 2 * 1024 * 1024:
        fail(f"source archive must contain one bounded {suffix} notice source")
    return matches[0]


def homebrew_components(
    root: Path,
    origins: dict[str, Path],
    homebrew_lock: dict[str, Any],
    homebrew_provenance: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    formulas: dict[str, set[str]] = defaultdict(set)
    file_component: dict[str, str] = {}
    for destination, source in origins.items():
        if "/Toolchains/build/ceres/install/" in source.as_posix():
            file_component[destination] = "ceres"
        elif "/Toolchains/build/suitesparse/install/" in source.as_posix():
            file_component[destination] = "suitesparse"
        elif "/Toolchains/build/openimageio/install/" in source.as_posix():
            file_component[destination] = "openimageio"
        else:
            identity = formula_origin(source)
            if identity is None:
                fail(f"non-system Mach-O has no pinned builder or Homebrew formula: {source}")
            formula, installed_version = identity
            if formula not in homebrew_lock["formulae"]:
                fail(f"copied Homebrew origin is outside the reviewed lock: {formula}")
            validate_homebrew_runtime_member(formula, destination)
            formulas[formula].add(installed_version)
            file_component[destination] = homebrew_component_id(formula)

    components: dict[str, dict[str, Any]] = {}

    with tempfile.TemporaryDirectory(prefix="easysplat-licenses-") as temporary:
        temp = Path(temporary)
        for formula in sorted(formulas):
            versions = formulas[formula]
            if len(versions) != 1:
                fail(f"multiple installed versions of Homebrew formula {formula}: {sorted(versions)}")
            installed_version = next(iter(versions))
            locked = homebrew_lock["formulae"][formula]
            receipt_entry = homebrew_provenance["formulae"].get(formula)
            if not isinstance(receipt_entry, dict):
                fail(f"{formula} has no verified source-build receipt")
            if installed_version != locked["installedVersion"]:
                fail(
                    f"{formula} runtime is {installed_version}, but the reviewed lock requires "
                    f"{locked['installedVersion']}"
                )
            if receipt_entry.get("installedVersion") != installed_version:
                fail(f"{formula} runtime and verified install receipt disagree")
            source_url = str(locked["source"]["url"])
            source_sha = str(locked["source"]["sha256"])
            if not source_url.startswith("https://") or not re.fullmatch(r"[0-9a-f]{64}", source_sha):
                fail(f"{formula} reviewed source provenance is incomplete")

            archive = temp / f"{formula.replace('@', '-')}.source"
            request = urllib.request.Request(source_url, headers={"User-Agent": "EasySplat-release/2"})
            try:
                with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as output:
                    shutil.copyfileobj(response, output)
            except OSError as exc:
                fail(f"could not download {formula} source license archive: {exc}")
            if sha256(archive) != source_sha:
                fail(f"source checksum mismatch for Homebrew formula {formula}")

            license_dir = root / "licenses" / "homebrew" / formula
            license_dir.mkdir(parents=True, exist_ok=True)
            license_paths: list[str] = []
            for index, (name, data) in enumerate(archive_license_members(archive), 1):
                safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", name) or f"LICENSE-{index}"
                destination = license_dir / safe_name
                destination.write_bytes(data)
                license_paths.append(relative(destination, root))
            if formula == "zstd":
                _, divsufsort_source = archive_member_with_suffix(
                    archive,
                    "/lib/dictBuilder/divsufsort.c",
                )
                divsufsort_notice = license_dir / "divsufsort.c"
                divsufsort_notice.write_bytes(divsufsort_source)
                license_paths.append(relative(divsufsort_notice, root))
            expression = homebrew_runtime_license(formula, locked["license"])
            component_id = homebrew_component_id(formula)
            install_receipt = receipt_entry["receipt"]
            components[component_id] = {
                "id": component_id,
                "name": (
                    "xz liblzma runtime" if formula == "xz"
                    else "zstd libzstd runtime" if formula == "zstd"
                    else formula
                ),
                "type": "dynamic-library",
                "version": installed_version,
                "revision": (
                    f"homebrew/core@{homebrew_lock['core']['commit']}:"
                    f"{locked['formulaSha256']}"
                ),
                "source": source_url,
                "sourceArchiveSha256": source_sha,
                "formulaPath": locked["formulaPath"],
                "formula": formula,
                "formulaSha256": locked["formulaSha256"],
                "license": expression,
                "licenseFiles": sorted(license_paths),
                "linkage": "dynamic",
                "dependencies": [],
                "buildMode": homebrew_provenance["buildMode"],
                "installReceipt": {
                    "sha256": receipt_entry["receiptSha256"],
                    "homebrewVersion": str(install_receipt.get("homebrew_version") or ""),
                    "compiler": str(install_receipt.get("compiler") or ""),
                    "arch": str(install_receipt.get("arch") or ""),
                    "sourceModifiedTime": install_receipt.get("source_modified_time"),
                    "builtOn": install_receipt.get("built_on"),
                },
            }
    return components, file_component


def python_components(
    root: Path,
) -> tuple[dict[str, dict[str, Any]], dict[Path, str]]:
    python_root = root / "da3_mps" / "python"
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
        if not name or not version or not source_url.startswith("https://") \
                or not re.fullmatch(r"[0-9a-f]{64}", artifact_hash):
            fail(f"pip install report contains incomplete artifact provenance for {name or '<unknown>'}")
        slug = re.sub(r"[-_.]+", "-", name).lower()
        if slug in installed_artifacts:
            fail(f"pip install report contains duplicate distribution: {name}")
        installed_artifacts[slug] = (version, source_url, artifact_hash)

    components: dict[str, dict[str, Any]] = {}
    ownership: dict[Path, str] = {}
    for metadata_path in sorted(python_root.rglob("*.dist-info/METADATA")):
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

        receipt_dir = root / "licenses" / "python-packages" / slug
        receipt_dir.mkdir(parents=True, exist_ok=True)
        receipt = receipt_dir / "METADATA"
        shutil.copy2(metadata_path, receipt)
        license_paths = [relative(receipt, root)]
        for declared in metadata.get_all("License-File", []):
            candidates = [metadata_path.parent / declared, metadata_path.parent / "licenses" / declared]
            source_license = next((candidate for candidate in candidates if candidate.is_file()), None)
            if source_license is None:
                fail(f"{name} declares a missing license file: {declared}")
            destination = receipt_dir / re.sub(r"[^A-Za-z0-9._-]", "_", Path(declared).name)
            shutil.copy2(source_license, destination)
            license_paths.append(relative(destination, root))

        dependencies = []
        for requirement in metadata.get_all("Requires-Dist", []):
            dependency = re.split(r"[ (;<>=!~]", requirement, maxsplit=1)[0]
            if dependency:
                dependencies.append(f"python:{re.sub(r'[-_.]+', '-', dependency).lower()}")
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
            artifact_version, artifact_url, artifact_hash = installed_artifacts.pop(slug)
            if artifact_version != version:
                fail(f"pip install report version mismatch for {name}: {artifact_version} != {version}")
            components[component_id]["artifact"] = artifact_url
            components[component_id]["artifactSha256"] = artifact_hash
        elif slug != "pip":
            fail(f"installed Python distribution has no hashed pip report entry: {name}")

        site_packages = metadata_path.parent.parent
        record = metadata_path.parent / "RECORD"
        if not record.is_file():
            fail(f"Python distribution has no RECORD: {name}")
        with record.open(newline="", encoding="utf-8") as stream:
            for row in csv.reader(stream):
                if not row:
                    continue
                candidate = (site_packages / row[0]).resolve(strict=False)
                try:
                    candidate.relative_to(python_root.resolve())
                except ValueError:
                    continue
                if candidate.exists() or candidate.is_symlink():
                    ownership[candidate] = component_id
        for path in metadata_path.parent.rglob("*"):
            if path.is_file() or path.is_symlink():
                ownership[path.resolve(strict=False)] = component_id
    if installed_artifacts:
        fail(f"pip install report packages are missing from the runtime: {sorted(installed_artifacts)}")
    return components, ownership


def builder_components(root: Path, version: str) -> dict[str, dict[str, Any]]:
    colmap = load_json(root / "provenance" / "colmap.json")
    ceres = load_json(root / "provenance" / "ceres.json")
    suitesparse = load_json(root / "provenance" / "suitesparse.json")
    openimageio = load_json(root / "provenance" / "openimageio.json")
    msplat = load_json(root / "msplat" / "build_info.json")
    da3 = load_json(root / "da3_mps" / "build_info.json")
    repo = root.parents[1]
    repository_revision = run("git", "rev-parse", "HEAD", cwd=repo).strip()
    lock_path = root / "da3_mps" / "licenses" / "python-packages-requirements.txt"
    lock_hash = str(da3.get("requirements_lock_sha256") or "")
    if not lock_path.is_file() or not re.fullmatch(r"[0-9a-f]{64}", lock_hash) \
            or sha256(lock_path) != lock_hash:
        fail("DA3 Python requirements lock is missing or does not match its builder receipt")
    require_pinned_receipt(colmap, PINNED_RECEIPTS["colmap"], "colmap")
    require_pinned_receipt(
        openimageio,
        PINNED_RECEIPTS["openimageio"],
        "openimageio",
    )

    def receipt_license_paths(receipt: dict[str, Any], component_id: str) -> list[Path]:
        values = receipt.get("license_files")
        if not isinstance(values, list) or not values:
            fail(f"{component_id} receipt has no license_files")
        paths: list[Path] = []
        for value in values:
            pure = PurePosixPath(str(value))
            if pure.is_absolute() or ".." in pure.parts:
                fail(f"{component_id} receipt has unsafe license path: {value!r}")
            path = root.joinpath(*pure.parts)
            if not path.is_file():
                fail(f"{component_id} receipt license is missing: {value}")
            paths.append(path)
        return paths

    def native(
        component_id: str,
        receipt: dict[str, Any],
        kind: str,
        license_files: Iterable[Path],
        dependencies: Iterable[str] = (),
    ) -> dict[str, Any]:
        source = receipt.get("source_url") or receipt.get("source_repo")
        revision = receipt.get("source_commit")
        version_value = receipt.get("source_version")
        expression = normalize_license(receipt.get("license"))
        files = [relative(path, root) for path in license_files if path.is_file()]
        if not source or not revision or not version_value or not files:
            fail(f"{component_id} builder receipt or staged license closure is incomplete")
        return {
            "id": component_id,
            "name": component_id,
            "type": kind,
            "version": str(version_value),
            "revision": str(revision),
            "source": str(source),
            "license": expression,
            "licenseFiles": sorted(files),
            "linkage": "dynamic" if kind == "dynamic-library" else "executable",
            "dependencies": sorted(set(dependencies)),
        }

    components = {
        "colmap": native(
            "colmap",
            colmap,
            "executable",
            [root / "licenses" / "COLMAP" / "COPYING.txt"],
            (
                "ceres",
                "suitesparse",
                "openimageio",
                "colmap:faiss",
                "colmap:poissonrecon",
                "colmap:poselib",
                "colmap:vlfeat",
            ),
        ),
        "ceres": native(
            "ceres",
            ceres,
            "dynamic-library",
            (root / "licenses" / "Ceres").rglob("*"),
            ("eigen",),
        ),
        "suitesparse": native(
            "suitesparse",
            suitesparse,
            "dynamic-library",
            (root / "licenses" / "SuiteSparse").rglob("*"),
        ),
        "openimageio": native(
            "openimageio",
            openimageio,
            "dynamic-library",
            receipt_license_paths(openimageio, "openimageio"),
            (
                "openimageio:fmt",
                "openimageio:pugixml",
                "openimageio:robin-map",
            ),
        ),
        "msplat": native(
            "msplat",
            {**msplat, "license": "Apache-2.0"},
            "executable",
            [root / "msplat" / "LICENSE"],
            ("msplat:cli11", "msplat:nanoflann", "msplat:nlohmann-json"),
        ),
    }
    oiio_tree_hash = str(openimageio.get("source_tree_sha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", oiio_tree_hash):
        fail("OpenImageIO receipt has no exact source-tree SHA-256")
    components["openimageio"]["sourceTreeSha256"] = oiio_tree_hash

    if openimageio.get("enabled_formats") != ["JPEG", "OpenEXR", "PNG", "TIFF"]:
        fail("OpenImageIO receipt does not describe the reviewed minimal format set")
    if set(openimageio.get("disabled_dependencies") or []) != {
        "DCMTK",
        "FFmpeg",
        "Freetype",
        "GIF",
        "JPEG XL",
        "LibRaw",
        "Libheif",
        "Nuke",
        "OpenColorIO",
        "OpenCV",
        "OpenJPEG",
        "OpenVDB",
        "PTex",
        "Qt",
        "R3DSDK",
        "TBB",
        "WebP",
    }:
        fail("OpenImageIO receipt does not describe the reviewed disabled dependency set")
    oiio_dependencies = openimageio.get("dependencies")
    if not isinstance(oiio_dependencies, dict) or set(oiio_dependencies) != {
        "fmt",
        "pugixml",
        "robin-map",
    }:
        fail("OpenImageIO helper receipt closure is incomplete or unexpected")
    for dependency_name, display_name, expected_linkage in (
        ("fmt", "fmt", "header-only"),
        ("pugixml", "PugiXML", "compiled-in"),
        ("robin-map", "robin-map", "header-only"),
    ):
        component_id = f"openimageio:{dependency_name}"
        receipt = oiio_dependencies[dependency_name]
        if not isinstance(receipt, dict):
            fail(f"{component_id} receipt must be an object")
        require_pinned_receipt(receipt, PINNED_RECEIPTS[component_id], component_id)
        if receipt.get("linkage") != expected_linkage:
            fail(f"{component_id} receipt linkage mismatch")
        tree_hash = str(receipt.get("source_tree_sha256") or "")
        if not re.fullmatch(r"[0-9a-f]{64}", tree_hash):
            fail(f"{component_id} receipt has no exact source-tree SHA-256")
        components[component_id] = {
            "id": component_id,
            "name": display_name,
            "type": "static-dependency",
            "version": str(receipt.get("source_version") or ""),
            "revision": str(receipt.get("source_commit") or ""),
            "source": str(receipt.get("source_url") or ""),
            "sourceTreeSha256": tree_hash,
            "license": normalize_license(receipt.get("license")),
            "licenseFiles": [
                relative(path, root)
                for path in receipt_license_paths(receipt, component_id)
            ],
            "linkage": expected_linkage,
            "dependencies": [],
            "incorporatedInto": ["openimageio"],
        }

    colmap_dependencies = colmap.get("dependencies")
    if not isinstance(colmap_dependencies, dict) or set(colmap_dependencies) != {
        "faiss",
        "poissonrecon",
        "poselib",
        "vlfeat",
    }:
        fail("COLMAP compiled-in dependency receipt closure is incomplete or unexpected")
    for dependency_name, display_name, digest_field, manifest_field in (
        ("faiss", "FAISS", "source_archive_sha256", "sourceArchiveSha256"),
        ("poselib", "PoseLib", "source_archive_sha256", "sourceArchiveSha256"),
        ("poissonrecon", "PoissonRecon", "source_tree_sha256", "sourceTreeSha256"),
        ("vlfeat", "VLFeat", "source_tree_sha256", "sourceTreeSha256"),
    ):
        component_id = f"colmap:{dependency_name}"
        receipt = colmap_dependencies[dependency_name]
        if not isinstance(receipt, dict):
            fail(f"{component_id} receipt must be an object")
        require_pinned_receipt(receipt, PINNED_RECEIPTS[component_id], component_id)
        if receipt.get("linkage") != "compiled-in":
            fail(f"{component_id} receipt linkage mismatch")
        source_digest = str(receipt.get(digest_field) or "")
        if not re.fullmatch(r"[0-9a-f]{64}", source_digest):
            fail(f"{component_id} receipt has no exact {digest_field}")
        components[component_id] = {
            "id": component_id,
            "name": display_name,
            "type": "static-dependency",
            "version": str(receipt.get("source_version") or receipt.get("source_commit") or ""),
            "revision": str(receipt.get("source_commit") or ""),
            "source": str(receipt.get("source_url") or ""),
            manifest_field: source_digest,
            "license": normalize_license(receipt.get("license")),
            "licenseFiles": [
                relative(path, root)
                for path in receipt_license_paths(receipt, component_id)
            ],
            "linkage": "compiled-in",
            "dependencies": [],
            "incorporatedInto": ["colmap"],
        }

    eigen = ceres.get("dependencies", {}).get("eigen", {})
    components["eigen"] = {
        "id": "eigen",
        "name": "Eigen",
        "type": "static-dependency",
        "version": str(eigen.get("source_version") or ""),
        "revision": str(eigen.get("source_commit") or ""),
        "source": str(eigen.get("source_url") or ""),
        "license": normalize_license(eigen.get("license")),
        "licenseFiles": sorted(
            relative(path, root) for path in (root / "licenses" / "Ceres").glob("Eigen-*.txt")
        ),
        "linkage": "compiled-in",
        "dependencies": [],
        "incorporatedInto": ["ceres"],
    }

    static_dependencies = [
        ("msplat:cli11", "CLI11", "2.4.2", "https://github.com/CLIUtils/CLI11", "BSD-3-Clause", "CLI11/LICENSE"),
        ("msplat:nanoflann", "nanoflann", "1.5.5", "https://github.com/jlblancoc/nanoflann", "BSD-2-Clause", "nanoflann/COPYING"),
        ("msplat:nlohmann-json", "nlohmann-json", "3.11.3", "https://github.com/nlohmann/json", "MIT", "nlohmann-json/LICENSE.MIT"),
    ]
    dependency_hashes = msplat.get("dependencies", {})
    dependency_receipt_keys = {
        "msplat:cli11": "cli11_v2.4.2_sha256",
        "msplat:nanoflann": "nanoflann_v1.5.5_sha256",
        "msplat:nlohmann-json": "nlohmann_json_v3.11.3_sha256",
    }
    for component_id, name, dep_version, source, expression, license_path in static_dependencies:
        path = root / "licenses" / "msplat" / license_path
        if not path.is_file():
            fail(f"missing static dependency license: {path}")
        dependency_hash = str(dependency_hashes.get(dependency_receipt_keys[component_id]) or "")
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
    python_receipt = root / "da3_mps" / "licenses" / "python-build-standalone" / "PYTHON.json"
    python_notices = root / "da3_mps" / "licenses" / "python-build-standalone" / "licenses"
    if not python_receipt.is_file() or not python_notices.is_dir():
        fail("python-build-standalone license closure is missing")
    components["python-build-standalone"] = {
        "id": "python-build-standalone",
        "name": "python-build-standalone",
        "type": "runtime",
        "version": str(da3.get("python_version") or ""),
        "revision": f"sha256:{da3.get('python_standalone_sha256', '')}",
        "source": str(da3.get("python_standalone_url") or ""),
        "license": "LicenseRef-Python-Build-Standalone-Closure",
        "licenseFiles": [relative(python_receipt, root)]
        + sorted(relative(path, root) for path in python_notices.rglob("*") if path.is_file()),
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
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain-root", type=Path, required=True)
    parser.add_argument("--dependency-origins", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--homebrew-lock",
        type=Path,
        default=Path(__file__).with_name("homebrew-lock.json"),
    )
    parser.add_argument(
        "--homebrew-provenance",
        type=Path,
        default=repository_root / "Toolchains" / "build" / "homebrew" / "homebrew-provenance.json",
    )
    args = parser.parse_args()
    root = args.toolchain_root.resolve()
    origins = read_origins(args.dependency_origins)
    try:
        homebrew_lock, homebrew_provenance = load_homebrew_provenance(
            args.homebrew_lock,
            args.homebrew_provenance,
        )
    except HomebrewLockError as exc:
        fail(str(exc))

    # Reject incompatible bottles before downloading their verified source notices.
    for candidate in root.rglob("*"):
        source = materialized_source(candidate, root)
        if is_macho(source):
            validate_arm64_only(source)
            validate_macos_15_compatibility(source)

    components = builder_components(root, args.version)
    brew_components, native_ownership = homebrew_components(
        root,
        origins,
        homebrew_lock,
        homebrew_provenance,
    )
    components.update(brew_components)
    distributions, python_ownership = python_components(root)
    components.update(distributions)
    installed_component_ids = set(components)
    for component in components.values():
        component["dependencies"] = [
            dependency
            for dependency in component.get("dependencies", [])
            if dependency in installed_component_ids
        ]

    ownership: dict[str, str] = {
        "bin/colmap": "colmap",
        "bin/easysplat-train": "msplat",
        "bin/default.metallib": "msplat",
    }
    ownership.update(native_ownership)
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
        if path_text == "licenses/COLMAP/FAISS-LICENSE":
            return "colmap:faiss"
        if path_text == "licenses/COLMAP/PoseLib-LICENSE":
            return "colmap:poselib"
        if path_text == "licenses/COLMAP/PoissonRecon-LICENSE":
            return "colmap:poissonrecon"
        if path_text == "licenses/COLMAP/VLFeat-LICENSE":
            return "colmap:vlfeat"
        if path_text.startswith("licenses/COLMAP/") or path_text == "provenance/colmap.json":
            return "colmap"
        if path_text.startswith("licenses/Ceres/") or path_text == "provenance/ceres.json":
            return "ceres"
        if path_text.startswith("licenses/SuiteSparse/") or path_text == "provenance/suitesparse.json":
            return "suitesparse"
        if path_text.startswith("licenses/OpenImageIO/"):
            if path_text.endswith("/fmt-LICENSE.rst"):
                return "openimageio:fmt"
            if path_text.endswith("/pugixml-LICENSE.md"):
                return "openimageio:pugixml"
            if path_text.endswith("/robin-map-LICENSE"):
                return "openimageio:robin-map"
            return "openimageio"
        if path_text == "provenance/openimageio.json":
            return "openimageio"
        if path_text.startswith("licenses/EasySplat/"):
            return "easysplat-da3-bridge"
        if path_text.startswith("licenses/homebrew/"):
            formula = path_text.split("/", 3)[2]
            return homebrew_component_id(formula)
        if path_text.startswith("licenses/python-packages/"):
            slug = path_text.split("/", 3)[2]
            return f"python:{slug}"
        fail(f"packaged file has no component owner: {path_text}")

    manifest_path = root / "supply-chain" / "components.json"
    for path in sorted(root.rglob("*")):
        if path == manifest_path or path == args.dependency_origins or path.name.endswith(".zip"):
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
            for dependency in raw_dependencies:
                if dependency.startswith("/") and not dependency.startswith(
                    ("/usr/lib/", "/System/Library/")
                ):
                    fail(f"{path_text} has an unportable dependency: {dependency}")
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
        missing = [key for key in required if not component.get(key) and key not in {"dependencies"}]
        if missing:
            fail(f"component {component_id} is missing: {', '.join(missing)}")
        for license_file in component["licenseFiles"]:
            if not (root / license_file).is_file():
                fail(f"component {component_id} refers to a missing license file: {license_file}")
        dependencies = set(component.get("dependencies", []))
        missing_dependencies = dependencies.difference(components)
        if missing_dependencies and component.get("type") != "python-package":
            fail(f"component {component_id} refers to missing dependencies: {sorted(missing_dependencies)}")
        # Python METADATA includes inactive platform markers and optional extras.
        # The signed closure records only distributions that are actually present.
        component["dependencies"] = sorted(dependencies.intersection(components))
        component["files"] = sorted(component_files.get(component_id, []))

    payload = {
        "schemaVersion": 1,
        "toolchainVersion": args.version,
        "homebrewBuild": {
            "lockFileSha256": homebrew_provenance["lockFileSha256"],
            "homebrewCommit": homebrew_provenance["homebrewCommit"],
            "coreCommit": homebrew_provenance["coreCommit"],
            "mode": homebrew_provenance["buildMode"],
            "brewConfig": homebrew_provenance["brewConfig"],
            "installReceipts": {
                name: {
                    "installedVersion": entry["installedVersion"],
                    "sha256": entry["receiptSha256"],
                    "receipt": entry["receipt"],
                }
                for name, entry in sorted(homebrew_provenance["formulae"].items())
            },
        },
        "components": [components[key] for key in sorted(components)],
        "files": files,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Supply-chain closure: {len(components)} components, {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
