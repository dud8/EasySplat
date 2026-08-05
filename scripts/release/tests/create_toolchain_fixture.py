#!/usr/bin/env python3
"""Create a small, production-shaped toolchain closure for release-script tests."""

from __future__ import annotations

import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


VERSION = "2.0.0"
REPOSITORY = "dud8/EasySplat"
SOURCE_ARCHIVE_SHA256 = "4" * 64
ROOT = Path(__file__).resolve().parents[3]
MACHO_FIXTURE_PATHS = frozenset({
    "bin/colmap",
    "bin/easysplat-train",
    "da3_mps/python/bin/python3",
    "lib/libomp.dylib",
})
REGULAR_BIN_FIXTURE_PATHS = frozenset({"bin/default.metallib"})


_MACHO_CACHE: dict[tuple[bytes, str, bytes | None], bytes] = {}


def thin_arm64_macho(
    payload: bytes,
    *,
    kind: str = "executable",
    rpath: bytes | None = None,
) -> bytes:
    """A real arm64 Mach-O whose bytes are distinct per payload.

    The app build signs the helpers it stages and verifies the bundle
    strictly, and it proves colmap's rpath with otool, so a truncated header
    is no longer enough to stand in for a native tool. `-no_uuid` keeps
    repeated fixture runs byte-identical.
    """
    key = (payload, kind, rpath)
    cached = _MACHO_CACHE.get(key)
    if cached is not None:
        return cached
    marker = payload.decode("ascii")
    with tempfile.TemporaryDirectory() as scratch:
        directory = Path(scratch)
        source = directory / "fixture.c"
        if kind == "dylib":
            source.write_text(
                f'const char easysplat_fixture[] = "{marker}";\n', encoding="ascii"
            )
        else:
            source.write_text(
                f'const char easysplat_fixture[] = "{marker}";\n'
                "int main(void) { return 0; }\n",
                encoding="ascii",
            )
        binary = directory / "fixture"
        command = ["xcrun", "clang", "-arch", "arm64", "-Wl,-no_uuid"]
        if kind == "dylib":
            command += ["-dynamiclib", "-install_name", "@rpath/libomp.dylib"]
        if rpath is not None:
            command += ["-Wl,-rpath," + rpath.decode("ascii")]
        command += [str(source), "-o", str(binary)]
        subprocess.run(command, check=True, capture_output=True)
        data = binary.read_bytes()
    _MACHO_CACHE[key] = data
    return data


def fixture_file_kind(path: str) -> str:
    if path in MACHO_FIXTURE_PATHS:
        return "mach-o"
    if path.startswith("bin/") and path not in REGULAR_BIN_FIXTURE_PATHS:
        raise RuntimeError(f"untyped root-bin fixture path: {path}")
    return "file"


def shell_value(path: str, name: str) -> str:
    prefix = f'{name}="'
    for line in (ROOT / path).read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix) and line.endswith('"'):
            return line[len(prefix):-1]
    raise RuntimeError(f"missing reviewed shell value: {path}:{name}")


def lock(path: str) -> dict[str, Any]:
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


COLMAP_REPO = shell_value("scripts/toolchain/build_colmap_impl.sh", "COLMAP_REPO")
COLMAP_COMMIT = shell_value("scripts/toolchain/build_colmap_impl.sh", "COLMAP_COMMIT")
COLMAP_VERSION = shell_value("scripts/toolchain/build_colmap_impl.sh", "COLMAP_VERSION")
FAISS_URL = shell_value("scripts/toolchain/build_colmap_impl.sh", "FAISS_URL")
FAISS_VERSION = shell_value("scripts/toolchain/build_colmap_impl.sh", "FAISS_VERSION")
FAISS_COMMIT = shell_value("scripts/toolchain/build_colmap_impl.sh", "FAISS_COMMIT")
FAISS_SHA256 = shell_value("scripts/toolchain/build_colmap_impl.sh", "FAISS_SHA256")
POSELIB_URL = shell_value("scripts/toolchain/build_colmap_impl.sh", "POSELIB_URL")
POSELIB_COMMIT = shell_value("scripts/toolchain/build_colmap_impl.sh", "POSELIB_COMMIT")
POSELIB_SHA256 = shell_value("scripts/toolchain/build_colmap_impl.sh", "POSELIB_SHA256")
MSPLAT_REPO = shell_value("scripts/toolchain/build_msplat.sh", "MSPLAT_REPO")
MSPLAT_COMMIT = shell_value("scripts/toolchain/build_msplat.sh", "MSPLAT_COMMIT")
MSPLAT_VERSION = shell_value("scripts/toolchain/build_msplat.sh", "MSPLAT_VERSION")
NLOHMANN_JSON_SHA256 = shell_value("scripts/toolchain/build_msplat.sh", "NLOHMANN_JSON_SHA256")
NANOFLANN_SHA256 = shell_value("scripts/toolchain/build_msplat.sh", "NANOFLANN_SHA256")
CLI11_SHA256 = shell_value("scripts/toolchain/build_msplat.sh", "CLI11_SHA256")
DA3_REPO = shell_value("scripts/toolchain/build_da3_mps.sh", "DA3_REPO")
DA3_COMMIT = shell_value("scripts/toolchain/build_da3_mps.sh", "DA3_REF")
PYTHON_STANDALONE_VERSION = shell_value(
    "scripts/toolchain/build_da3_mps.sh", "PYTHON_STANDALONE_VERSION"
)
PYTHON_STANDALONE_TAG = shell_value(
    "scripts/toolchain/build_da3_mps.sh", "PYTHON_STANDALONE_TAG"
)
PYTHON_STANDALONE_ASSET = (
    f"cpython-{PYTHON_STANDALONE_VERSION}+{PYTHON_STANDALONE_TAG}"
    "-aarch64-apple-darwin-install_only_stripped.tar.gz"
)
PYTHON_STANDALONE_FULL_ASSET = (
    f"cpython-{PYTHON_STANDALONE_VERSION}+{PYTHON_STANDALONE_TAG}"
    "-aarch64-apple-darwin-pgo+lto-full.tar.zst"
)
PYTHON_STANDALONE_SHA256 = shell_value(
    "scripts/toolchain/build_da3_mps.sh", "PYTHON_STANDALONE_SHA256"
)
PYTHON_STANDALONE_FULL_SHA256 = shell_value(
    "scripts/toolchain/build_da3_mps.sh", "PYTHON_STANDALONE_FULL_SHA256"
)
DA3_RUNTIME_PATCH_SHA256 = shell_value(
    "scripts/toolchain/build_da3_mps.sh", "DA3_RUNTIME_PATCH_SHA256"
)
CERES_LOCK = lock("scripts/toolchain/ceres-lock.json")["dependencies"]
OPENIMAGEIO_LOCK = lock("scripts/toolchain/openimageio-lock.json")["dependencies"]
SUPPORT_LOCK = lock("scripts/toolchain/colmap-support-lock.json")["dependencies"]
MODEL_LOCK = lock("scripts/toolchain/da3-model-lock.json")["models"]
REQUIREMENTS_DATA = (ROOT / "Tools/Da3Sfm/requirements.txt").read_bytes()
CERES_COMMIT = CERES_LOCK["ceres"]["commit"]
BASE_MODEL_COMMIT = MODEL_LOCK["DA3-BASE"]["resolved_sha"]
SMALL_MODEL_COMMIT = MODEL_LOCK["DA3-SMALL"]["resolved_sha"]


def requirement_hashes(requirements: bytes) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    package: str | None = None
    for raw_line in requirements.decode("utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "==" in line:
            package = line.split("==", 1)[0]
            result.setdefault(package, [])
        if "--hash=sha256:" in line:
            if package is None:
                raise RuntimeError("requirements hash appeared before a package")
            result.setdefault(package, []).append(line.rsplit(":", 1)[1])
    return result


REQUIREMENT_HASHES = requirement_hashes(REQUIREMENTS_DATA)

PYTHON_PACKAGES: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("addict", "2.4.0", ()),
    ("annotated-doc", "0.0.4", ()),
    ("antlr4-python3-runtime", "4.9.3", ()),
    ("anyio", "4.14.1", ("idna", "typing-extensions")),
    ("certifi", "2026.6.17", ()),
    ("einops", "0.8.2", ()),
    ("filelock", "3.29.7", ()),
    ("fsspec", "2026.6.0", ("jinja2", "numpy", "tqdm")),
    ("h11", "0.16.0", ()),
    ("hf-xet", "1.5.1", ()),
    ("httpcore", "1.0.9", ("anyio", "certifi", "h11")),
    ("httpx", "0.28.1", ("anyio", "certifi", "httpcore", "idna", "pygments", "rich")),
    (
        "huggingface-hub",
        "1.14.0",
        (
            "filelock", "fsspec", "hf-xet", "httpx", "jinja2", "numpy",
            "packaging", "pillow", "pyyaml", "torch", "tqdm", "typer",
            "typing-extensions",
        ),
    ),
    ("idna", "3.18", ()),
    ("jinja2", "3.1.6", ("markupsafe",)),
    ("markdown-it-py", "4.2.0", ("mdurl", "pyyaml")),
    ("markupsafe", "3.0.3", ()),
    ("mdurl", "0.1.2", ()),
    ("mpmath", "1.3.0", ()),
    ("networkx", "3.6.1", ("numpy", "pillow", "sympy")),
    ("numpy", "2.3.5", ()),
    ("omegaconf", "2.3.0", ("antlr4-python3-runtime", "pyyaml")),
    ("packaging", "26.2", ()),
    ("pillow", "12.3.0", ("packaging",)),
    ("pygments", "2.20.0", ()),
    ("pyyaml", "6.0.3", ()),
    ("rich", "15.0.0", ("markdown-it-py", "pygments")),
    ("safetensors", "0.7.0", ("huggingface-hub", "numpy", "packaging", "torch")),
    ("setuptools", "83.0.0", ("filelock", "packaging")),
    ("shellingham", "1.5.4", ()),
    ("sympy", "1.14.0", ("mpmath",)),
    (
        "torch",
        "2.13.0",
        ("filelock", "fsspec", "jinja2", "networkx", "pyyaml", "setuptools", "sympy", "typing-extensions"),
    ),
    ("torchvision", "0.28.0", ("numpy", "pillow", "torch")),
    ("tqdm", "4.68.4", ()),
    ("typer", "0.26.8", ("annotated-doc", "rich", "shellingham")),
    ("typing-extensions", "4.16.0", ()),
)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write(root: Path, relative: str, data: bytes | str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.encode() if isinstance(data, str) else data)


def dependency(
    name: str,
    version: str,
    license_id: str,
    *,
    commit: str | None = None,
    digest: str = SOURCE_ARCHIVE_SHA256,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "source_url": f"https://example.com/{name}-{version}.tar.gz",
        "source_version": version,
        "source_sha256": digest,
        "license": license_id,
        "license_files": [f"licenses/{name}/LICENSE"],
        "linkage": "compiled-in",
    }
    if commit is not None:
        result["source_commit"] = commit
    return result


def lock_dependency(name: str, entry: dict[str, Any]) -> dict[str, Any]:
    result = {
        "source_url": entry["source"]["url"],
        "source_version": entry["version"],
        "source_sha256": entry["source"]["sha256"],
        "license": entry["license"],
        "license_files": [f"licenses/{name}/LICENSE"],
        "linkage": "compiled-in",
    }
    if "commit" in entry:
        result["source_commit"] = entry["commit"]
    return result


def component(
    component_id: str,
    name: str,
    component_type: str,
    version: str,
    revision: str,
    source: str,
    build_command: str,
    license_id: str,
    license_files: list[str],
    linkage: str,
    dependencies: list[str],
    *,
    incorporated_into: list[str] | None = None,
    artifact: str | None = None,
    artifact_sha256: str | None = None,
    source_artifacts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": component_id,
        "name": name,
        "type": component_type,
        "version": version,
        "revision": revision,
        "source": source,
        "buildCommand": build_command,
        "license": license_id,
        "licenseFiles": sorted(license_files),
        "linkage": linkage,
        "dependencies": sorted(dependencies),
        "files": [],
    }
    if incorporated_into is not None:
        result["incorporatedInto"] = sorted(incorporated_into)
    if artifact is not None:
        result["artifact"] = artifact
    if artifact_sha256 is not None:
        result["artifactSha256"] = artifact_sha256
    if source_artifacts is not None:
        result["sourceArtifacts"] = source_artifacts
    return result


def static_dependency_component(
    component_id: str,
    name: str,
    version: str,
    revision: str,
    source: str,
    license_id: str,
    license_file: str,
    build_command: str,
    incorporated_into: str,
    *,
    artifact_sha256: str | None,
) -> dict[str, Any]:
    return component(
        component_id,
        name,
        "static-dependency",
        version,
        revision,
        source,
        build_command,
        license_id,
        [license_file],
        "compiled-in",
        [],
        incorporated_into=[incorporated_into],
        artifact=source if artifact_sha256 is not None else None,
        artifact_sha256=artifact_sha256,
    )


def owner(path: str) -> str:
    if path.startswith("licenses/python-packages/"):
        return f"python:{path.split('/')[2]}"
    for slug, version, _dependencies in PYTHON_PACKAGES:
        module = slug.replace("-", "_")
        if f"/site-packages/{module}/" in path or f"/site-packages/{module}-{version}.dist-info/" in path:
            return f"python:{slug}"
    if (
        path.startswith("da3_mps/python/")
        or path.startswith("da3_mps/licenses/python-build-standalone/")
        or path in {
            "da3_mps/licenses/python-packages-install-report.json",
            "da3_mps/licenses/python-packages-requirements.txt",
        }
    ):
        return "python-build-standalone"
    if path.startswith("da3_mps/models/DA3-BASE/"):
        return "model:da3-base"
    if path.startswith("da3_mps/models/DA3-SMALL/"):
        return "model:da3-small"
    if path.startswith("da3_mps/vendor/"):
        return "da3"
    if path.startswith("da3_mps/") or path.startswith("licenses/EasySplat/"):
        return "easysplat-da3-runner"
    if path == "bin/colmap" or path.startswith("licenses/COLMAP/") or path == "provenance/colmap.json":
        return "colmap"
    if path in {"bin/easysplat-train", "bin/default.metallib"} or path.startswith("msplat/"):
        return "msplat"
    if path.startswith("licenses/msplat/CLI11/"):
        return "msplat:cli11"
    if path.startswith("licenses/msplat/nanoflann/"):
        return "msplat:nanoflann"
    if path.startswith("licenses/msplat/nlohmann-json/"):
        return "msplat:nlohmann-json"
    if path == "provenance/ceres.json" or path.startswith("licenses/ceres/"):
        return "ceres"
    if path.startswith("licenses/eigen/"):
        return "ceres:eigen"
    if path == "provenance/openimageio.json" or path.startswith("licenses/openimageio/"):
        return "openimageio"
    for name in ("boost", "fmt", "imath", "libjpeg-turbo", "libpng", "robin-map"):
        if path.startswith(f"licenses/{name}/"):
            return f"openimageio:{name}"
    for name in ("faiss", "poselib", "vlfeat"):
        if path.startswith(f"licenses/{name}/"):
            return f"colmap:{name}"
    for name in ("gflags", "glog", "libomp"):
        if path.startswith(f"licenses/{name}/"):
            return f"colmap-support:{name}"
    return "colmap-support"


def create_files(root: Path) -> tuple[dict[str, Path], bytes, bytes]:
    roots = {name: root / name for name in ("core", "base", "small")}
    colmap = thin_arm64_macho(b"native-colmap", rpath=b"@executable_path/../lib")
    trainer = thin_arm64_macho(b"native-msplat")
    metallib = b"native-metallib"
    for relative, data in {
        "bin/colmap": colmap,
        "bin/easysplat-train": trainer,
        "bin/default.metallib": metallib,
        "lib/libomp.dylib": thin_arm64_macho(b"libomp", kind="dylib"),
        "msplat/LICENSE": b"Apache-2.0",
        "licenses/COLMAP/COPYING.txt": b"BSD-3-Clause",
        "licenses/ceres/LICENSE": b"BSD-3-Clause",
        "licenses/openimageio/LICENSE": b"Apache-2.0",
        "licenses/EasySplat/LICENSE": b"MIT",
    }.items():
        write(roots["core"], relative, data)

    base_files = (
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
        "da3_mps/build_info.json",
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/model.safetensors",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
        "da3_mps/models/DA3-BASE/LICENSE",
    )
    for relative in base_files:
        payload = (
            thin_arm64_macho(b"python3")
            if relative == "da3_mps/python/bin/python3"
            else f"base:{relative}"
        )
        write(roots["base"], relative, payload)
    for relative in (
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/model.safetensors",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
        "da3_mps/models/DA3-SMALL/LICENSE",
    ):
        write(roots["small"], relative, f"small:{relative}")

    native_names = {
        "faiss", "poselib", "vlfeat", "boost", "gflags", "glog", "libomp",
        "ceres", "eigen", "fmt", "imath", "libjpeg-turbo", "libpng",
        "openimageio", "robin-map",
    }
    for name in native_names:
        write(roots["core"], f"licenses/{name}/LICENSE", f"fixture license for {name}")
    write(roots["core"], "licenses/msplat/CLI11/LICENSE", "BSD-3-Clause")
    write(roots["core"], "licenses/msplat/nanoflann/COPYING", "BSD-2-Clause")
    write(roots["core"], "licenses/msplat/nlohmann-json/LICENSE.MIT", "MIT")
    write(roots["base"], "da3_mps/vendor/depth-anything-3/LICENSE", "Apache-2.0")
    write(
        roots["base"],
        "da3_mps/licenses/python-build-standalone/PYTHON.json",
        canonical_json({"name": "python-build-standalone", "version": "3.13.11"}),
    )
    write(
        roots["base"],
        "da3_mps/licenses/python-build-standalone/licenses/LICENSE.cpython.txt",
        "Python-2.0",
    )
    supplemental = canonical_json({"schemaVersion": 1, "notices": []})
    write(roots["base"], "da3_mps/licenses/python-package-upstream-notices.json", supplemental)

    installs: list[dict[str, Any]] = []
    for slug, package_version, package_dependencies in PYTHON_PACKAGES:
        module = slug.replace("-", "_")
        dist_info = f"{module}-{package_version}.dist-info"
        metadata = "\n".join(
            (
                "Metadata-Version: 2.4",
                f"Name: {slug}",
                f"Version: {package_version}",
                "License-Expression: MIT",
                f"Project-URL: Source, https://example.com/python/{slug}",
                *(f"Requires-Dist: {dependency_name}" for dependency_name in package_dependencies),
                "",
            )
        ).encode()
        prefix = "da3_mps/python/lib/python3.13/site-packages"
        write(roots["base"], f"{prefix}/{dist_info}/METADATA", metadata)
        write(
            roots["base"],
            f"{prefix}/{dist_info}/RECORD",
            f"{module}/__init__.py,,\n{dist_info}/METADATA,,\n",
        )
        write(roots["base"], f"{prefix}/{module}/__init__.py", "__all__ = []\n")
        write(roots["core"], f"licenses/python-packages/{slug}/METADATA", metadata)
        write(roots["core"], f"licenses/python-packages/{slug}/LICENSE", "MIT")
        artifact_hash = REQUIREMENT_HASHES[slug][0]
        installs.append(
            {
                "download_info": {
                    "url": f"https://files.pythonhosted.org/fixture/{slug}-{package_version}.whl",
                    "archive_info": {"hashes": {"sha256": artifact_hash}},
                },
                "metadata": {"name": slug, "version": package_version},
            }
        )
    requirements_data = REQUIREMENTS_DATA
    write(
        roots["base"],
        "da3_mps/licenses/python-packages-install-report.json",
        canonical_json({"version": "1", "pip_version": "26.1", "install": installs}),
    )
    write(roots["base"], "da3_mps/licenses/python-packages-requirements.txt", requirements_data)

    for model, revision, archive in (
        ("DA3-BASE", BASE_MODEL_COMMIT, "base"),
        ("DA3-SMALL", SMALL_MODEL_COMMIT, "small"),
    ):
        prefix = f"da3_mps/models/{model}"
        config = (roots[archive] / f"{prefix}/config.json").read_bytes()
        weights = (roots[archive] / f"{prefix}/model.safetensors").read_bytes()
        write(
            roots[archive],
            f"{prefix}/easysplat_model_info.json",
            canonical_json(
                {
                    "repo_id": f"depth-anything/{model}",
                    "requested_revision": revision,
                    "resolved_sha": revision,
                    "license": "apache-2.0",
                    "artifacts": {
                        "config.json": {"sha256": sha256(config), "size_bytes": len(config)},
                        "model.safetensors": {"sha256": sha256(weights), "size_bytes": len(weights)},
                    },
                }
            ),
        )

    write(
        roots["base"],
        "da3_mps/build_info.json",
        canonical_json(
            {
                "toolchain_name": "da3_mps",
                "source_repo": DA3_REPO,
                "source_ref": DA3_COMMIT,
                "source_commit": DA3_COMMIT,
                "source_path": f"git:{DA3_REPO}@{DA3_COMMIT}",
                "source_provenance": "pinned-git",
                "expected_upstream_repo": DA3_REPO,
                "expected_upstream_ref": DA3_COMMIT,
                "base_checkpoint_repo": "depth-anything/DA3-BASE",
                "base_checkpoint_revision": BASE_MODEL_COMMIT,
                "base_checkpoint_commit": BASE_MODEL_COMMIT,
                "small_checkpoint_repo": "depth-anything/DA3-SMALL",
                "small_checkpoint_revision": SMALL_MODEL_COMMIT,
                "small_checkpoint_commit": SMALL_MODEL_COMMIT,
                "model_lock": "scripts/toolchain/da3-model-lock.json",
                "model_lock_sha256": sha256(
                    (ROOT / "scripts/toolchain/da3-model-lock.json").read_bytes()
                ),
                "python_version": PYTHON_STANDALONE_VERSION,
                "python_standalone_url": (
                    "https://github.com/indygreg/python-build-standalone/releases/download/"
                    f"{PYTHON_STANDALONE_TAG}/{PYTHON_STANDALONE_ASSET}"
                ),
                "python_standalone_sha256": PYTHON_STANDALONE_SHA256,
                "python_standalone_license_archive_url": (
                    "https://github.com/indygreg/python-build-standalone/releases/download/"
                    f"{PYTHON_STANDALONE_TAG}/{PYTHON_STANDALONE_FULL_ASSET}"
                ),
                "python_standalone_license_archive_sha256": PYTHON_STANDALONE_FULL_SHA256,
                "requirements_lock": "Tools/Da3Sfm/requirements.txt",
                "requirements_lock_sha256": sha256(requirements_data),
                "runtime_patch": "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
                "runtime_patch_sha256": DA3_RUNTIME_PATCH_SHA256,
                "supplemental_license_manifest": "licenses/python-package-upstream-notices.json",
                "supplemental_license_manifest_sha256": sha256(supplemental),
                "pip_install_report": "licenses/python-packages-install-report.json",
                "torch_version": "2.13.0",
                "torchvision_version": "0.28.0",
                "huggingface_hub_version": "1.14.0",
            }
        ),
    )
    return roots, colmap, trainer + metallib


def native_receipts(roots: dict[str, Path], colmap: bytes, trainer_metallib: bytes) -> None:
    trainer = thin_arm64_macho(b"native-msplat")
    metallib = trainer_metallib[len(trainer):]
    colmap_dependencies = {
        "faiss": {
            "source_url": FAISS_URL,
            "source_version": FAISS_VERSION,
            "source_commit": FAISS_COMMIT,
            "source_sha256": FAISS_SHA256,
            "license": "MIT",
            "license_files": ["licenses/faiss/LICENSE"],
            "linkage": "compiled-in",
        },
        "poselib": {
            "source_url": POSELIB_URL,
            "source_version": POSELIB_COMMIT,
            "source_commit": POSELIB_COMMIT,
            "source_sha256": POSELIB_SHA256,
            "license": "BSD-3-Clause",
            "license_files": ["licenses/poselib/LICENSE"],
            "linkage": "compiled-in",
        },
        "vlfeat": {
            "source_url": f"{COLMAP_REPO.removesuffix('.git')}/tree/{COLMAP_COMMIT}/src/thirdparty/VLFeat",
            "source_version": f"vendored-at-colmap-{COLMAP_VERSION}",
            "source_commit": COLMAP_COMMIT,
            "source_tree_sha256": "6" * 64,
            "license": "BSD-2-Clause",
            "license_files": ["licenses/vlfeat/LICENSE"],
            "linkage": "compiled-in",
        },
    }
    write(
        roots["core"],
        "provenance/colmap.json",
        canonical_json(
            {
                "schema_version": 2,
                "toolchain_name": "colmap",
                "source_url": COLMAP_REPO,
                "source_version": COLMAP_VERSION,
                "source_commit": COLMAP_COMMIT,
                "source_tree_sha256": "5" * 64,
                "license": "BSD-3-Clause",
                "executable_sha256": sha256(colmap),
                "dependencies": colmap_dependencies,
            }
        ),
    )
    support_dependencies = {
        name: lock_dependency(name, SUPPORT_LOCK[name])
        for name in ("boost", "gflags", "glog", "libomp")
    }
    write(
        roots["core"],
        "provenance/colmap-support.json",
        canonical_json(
            {
                "schema_version": 1,
                "toolchain_name": "colmap-support",
                "source_lock_sha256": sha256(
                    (ROOT / "scripts/toolchain/colmap-support-lock.json").read_bytes()
                ),
                "library_sha256": {
                    "lib/libomp.dylib": sha256(thin_arm64_macho(b"libomp", kind="dylib"))
                },
                "dependencies": support_dependencies,
            }
        ),
    )
    ceres_dependency = lock_dependency("ceres", CERES_LOCK["ceres"])
    write(
        roots["core"],
        "provenance/ceres.json",
        canonical_json(
            {
                "schema_version": 1,
                "toolchain_name": "ceres-static",
                "source_url": ceres_dependency["source_url"],
                "source_version": ceres_dependency["source_version"],
                "source_commit": ceres_dependency["source_commit"],
                "source_sha256": ceres_dependency["source_sha256"],
                "license": ceres_dependency["license"],
                "dependencies": {
                    "ceres": ceres_dependency,
                    "eigen": lock_dependency("eigen", CERES_LOCK["eigen"]),
                },
            }
        ),
    )
    oiio_dependencies = {
        "boost": lock_dependency("boost", SUPPORT_LOCK["boost"]),
        **{
            name: lock_dependency(name, OPENIMAGEIO_LOCK[name])
            for name in (
                "fmt", "imath", "libjpeg-turbo", "libpng", "openimageio", "robin-map"
            )
        },
    }
    write(
        roots["core"],
        "provenance/openimageio.json",
        canonical_json(
            {
                "schema_version": 1,
                "toolchain_name": "openimageio-static",
                "dependencies": oiio_dependencies,
            }
        ),
    )
    write(
        roots["core"],
        "msplat/build_info.json",
        canonical_json(
            {
                "toolchain_name": "msplat",
                "source_url": MSPLAT_REPO,
                "source_version": MSPLAT_VERSION,
                "source_commit": MSPLAT_COMMIT,
                "source_tree_sha256": "b" * 64,
                "executable_sha256": sha256(trainer),
                "metallib_sha256": sha256(metallib),
                "deployment_target": "macOS 15.0",
                "build_configuration": "Release",
                "build_timestamp": "2026-07-18T00:00:00Z",
                "compiler": "Apple clang",
                "cmake": "cmake 4.0",
                "ninja": "1.13.0",
                "cmake_arguments": ["-G Ninja"],
                "dependencies": {
                    "cli11_v2.4.2_sha256": CLI11_SHA256,
                    "nanoflann_v1.5.5_sha256": NANOFLANN_SHA256,
                    "nlohmann_json_v3.11.3_sha256": NLOHMANN_JSON_SHA256,
                },
            }
        ),
    )


def supply_components(roots: dict[str, Path]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    native_groups = (
        (
            "colmap",
            "./scripts/toolchain/build_colmap.sh",
            (("faiss", "1.14.1", "6" * 40, "MIT"), ("poselib", "2.0.5", "7" * 40, "BSD-3-Clause"), ("vlfeat", "vendored-at-colmap-4.1.1", COLMAP_COMMIT, "BSD-2-Clause")),
        ),
        (
            "colmap-support",
            "./scripts/toolchain/build_colmap_support.sh",
            (("boost", "1.90.0", SOURCE_ARCHIVE_SHA256, "BSL-1.0"), ("gflags", "2.3.0", SOURCE_ARCHIVE_SHA256, "BSD-3-Clause"), ("glog", "0.7.1", SOURCE_ARCHIVE_SHA256, "BSD-3-Clause"), ("libomp", "22.1.8", SOURCE_ARCHIVE_SHA256, "Apache-2.0 WITH LLVM-exception")),
        ),
        (
            "openimageio",
            "./scripts/toolchain/build_openimageio.sh",
            (("boost", "1.90.0", SOURCE_ARCHIVE_SHA256, "BSL-1.0"), ("fmt", "10.0.0", SOURCE_ARCHIVE_SHA256, "MIT"), ("imath", "3.2.2", SOURCE_ARCHIVE_SHA256, "BSD-3-Clause"), ("libjpeg-turbo", "3.2.0", SOURCE_ARCHIVE_SHA256, "BSD-3-Clause"), ("libpng", "1.6.58", SOURCE_ARCHIVE_SHA256, "libpng-2.0"), ("robin-map", "0.6.2", SOURCE_ARCHIVE_SHA256, "MIT")),
        ),
    )
    for prefix, command, entries in native_groups:
        for name, dependency_version, revision, license_id in entries:
            result.append(
                static_dependency_component(
                    f"{prefix}:{name}",
                    name,
                    dependency_version,
                    revision,
                    f"https://example.com/{name}-{dependency_version}.tar.gz",
                    license_id,
                    f"licenses/{name}/LICENSE",
                    command,
                    prefix,
                    artifact_sha256=SOURCE_ARCHIVE_SHA256,
                )
            )
    result.extend(
        (
            component(
                "colmap", "COLMAP", "executable", "4.1.1", COLMAP_COMMIT,
                "https://github.com/colmap/colmap.git", "./scripts/toolchain/build_colmap.sh",
                "BSD-3-Clause", ["licenses/COLMAP/COPYING.txt"], "native-executable",
                ["ceres", "colmap-support", "colmap:faiss", "colmap:poselib", "colmap:vlfeat", "openimageio"],
            ),
            component(
                "colmap-support", "EasySplat COLMAP support closure", "native-build-input", "1", "8" * 64,
                f"https://github.com/{REPOSITORY}", "./scripts/toolchain/build_colmap_support.sh",
                "LicenseRef-Dependency-Closure", ["licenses/EasySplat/LICENSE"], "build-input",
                ["colmap-support:boost", "colmap-support:gflags", "colmap-support:glog", "colmap-support:libomp"],
            ),
            static_dependency_component(
                "ceres:eigen", "Eigen", "3.4.0", "9" * 40,
                "https://example.com/eigen-3.4.0.tar.gz", "MPL-2.0", "licenses/eigen/LICENSE",
                "./scripts/toolchain/build_ceres.sh", "ceres", artifact_sha256=SOURCE_ARCHIVE_SHA256,
            ),
            component(
                "ceres", "Ceres Solver", "static-library", "2.2.0", CERES_COMMIT,
                "https://example.com/ceres-2.2.0.tar.gz", "./scripts/toolchain/build_ceres.sh",
                "BSD-3-Clause", ["licenses/ceres/LICENSE"], "compiled-in", ["ceres:eigen"],
                incorporated_into=["colmap"], artifact="https://example.com/ceres-2.2.0.tar.gz",
                artifact_sha256=SOURCE_ARCHIVE_SHA256,
            ),
            component(
                "openimageio", "OpenImageIO", "static-library", "2.5.19.1", SOURCE_ARCHIVE_SHA256,
                "https://example.com/openimageio-2.5.19.1.tar.gz", "./scripts/toolchain/build_openimageio.sh",
                "Apache-2.0 AND BSD-3-Clause", ["licenses/openimageio/LICENSE"], "compiled-in",
                ["openimageio:boost", "openimageio:fmt", "openimageio:imath", "openimageio:libjpeg-turbo", "openimageio:libpng", "openimageio:robin-map"],
                incorporated_into=["colmap"], artifact="https://example.com/openimageio-2.5.19.1.tar.gz",
                artifact_sha256=SOURCE_ARCHIVE_SHA256,
            ),
        )
    )
    for suffix, name, dependency_version, source, license_id, license_path, digest in (
        ("cli11", "CLI11", "2.4.2", "https://github.com/CLIUtils/CLI11", "BSD-3-Clause", "licenses/msplat/CLI11/LICENSE", "c" * 64),
        ("nanoflann", "nanoflann", "1.5.5", "https://github.com/jlblancoc/nanoflann", "BSD-2-Clause", "licenses/msplat/nanoflann/COPYING", "d" * 64),
        ("nlohmann-json", "nlohmann-json", "3.11.3", "https://github.com/nlohmann/json", "MIT", "licenses/msplat/nlohmann-json/LICENSE.MIT", "e" * 64),
    ):
        result.append(
            static_dependency_component(
                f"msplat:{suffix}", name, dependency_version, f"sha256:{digest}", source,
                license_id, license_path, "./scripts/toolchain/build_msplat.sh", "msplat",
                artifact_sha256=None,
            )
        )
    result.extend(
        (
            component(
                "msplat", "msplat", "executable", "1.1.3", MSPLAT_COMMIT,
                "https://github.com/rayanht/msplat.git", "./scripts/toolchain/build_msplat.sh",
                "Apache-2.0", ["msplat/LICENSE"], "executable",
                ["msplat:cli11", "msplat:nanoflann", "msplat:nlohmann-json"],
            ),
            component(
                "da3", "Depth Anything 3", "python-source", DA3_COMMIT, DA3_COMMIT,
                "https://github.com/ByteDance-Seed/Depth-Anything-3.git", "./scripts/toolchain/build_da3_mps.sh",
                "Apache-2.0", ["da3_mps/vendor/depth-anything-3/LICENSE"], "python", [],
            ),
            component(
                "easysplat-da3-runner", "EasySplat DA3 runner", "script", VERSION, "a" * 40,
                f"https://github.com/{REPOSITORY}", "./scripts/toolchain/build_da3_mps.sh", "MIT",
                ["licenses/EasySplat/LICENSE"], "python", ["da3", "python-build-standalone"],
            ),
            component(
                "python-build-standalone", "python-build-standalone", "runtime", "3.13.11",
                f"sha256:{sha256(b'python-build-standalone')}",
                "https://github.com/indygreg/python-build-standalone/releases/download/fixture/python.tar.gz",
                "./scripts/toolchain/build_da3_mps.sh", "LicenseRef-Python-Build-Standalone-Closure",
                ["da3_mps/licenses/python-build-standalone/PYTHON.json", "da3_mps/licenses/python-build-standalone/licenses/LICENSE.cpython.txt"],
                "runtime", [],
            ),
        )
    )
    for model, revision, archive in (("DA3-BASE", BASE_MODEL_COMMIT, "base"), ("DA3-SMALL", SMALL_MODEL_COMMIT, "small")):
        prefix = f"da3_mps/models/{model}"
        result.append(
            component(
                f"model:{model.lower()}", model, "model", revision, revision,
                f"https://huggingface.co/depth-anything/{model}", "./scripts/toolchain/build_da3_mps.sh",
                "Apache-2.0", [f"{prefix}/LICENSE"], "model-data", ["da3"],
                source_artifacts=[
                    {
                        "name": filename,
                        "sha256": sha256((roots[archive] / f"{prefix}/{filename}").read_bytes()),
                        "size": (roots[archive] / f"{prefix}/{filename}").stat().st_size,
                        "url": f"https://huggingface.co/depth-anything/{model}/resolve/{revision}/{filename}",
                    }
                    for filename in ("config.json", "model.safetensors")
                ],
            )
        )
    for slug, package_version, package_dependencies in PYTHON_PACKAGES:
        artifact_hash = sha256(f"artifact:{slug}:{package_version}".encode())
        result.append(
            component(
                f"python:{slug}", slug, "python-package", package_version, package_version,
                f"https://example.com/python/{slug}", "./scripts/toolchain/build_da3_mps.sh", "MIT",
                [f"licenses/python-packages/{slug}/LICENSE", f"licenses/python-packages/{slug}/METADATA"],
                "python", [f"python:{dependency_name}" for dependency_name in package_dependencies],
                artifact=f"https://files.pythonhosted.org/fixture/{slug}-{package_version}.whl",
                artifact_sha256=artifact_hash,
            )
        )
    assert len(result) == 63
    return result


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: create_toolchain_fixture.py <fixture-root>")
    root = Path(sys.argv[1]).resolve()
    roots, colmap, trainer_metallib = create_files(root)
    native_receipts(roots, colmap, trainer_metallib)
    components = supply_components(roots)
    by_id = {row["id"]: row for row in components}
    all_files: dict[str, Path] = {}
    for archive_root in roots.values():
        for path in archive_root.rglob("*"):
            if path.is_symlink() or path.is_file():
                relative = path.relative_to(archive_root).as_posix()
                if relative == "supply-chain/components.json":
                    continue
                if relative in all_files:
                    raise RuntimeError(f"duplicate fixture path: {relative}")
                all_files[relative] = path
    files: list[dict[str, Any]] = []
    for relative in sorted(all_files):
        path = all_files[relative]
        component_id = owner(relative)
        by_id[component_id]["files"].append(relative)
        # A closure describes a link by where it points, never by the bytes on
        # the other end.
        if path.is_symlink():
            files.append({
                "path": relative,
                "component": component_id,
                "kind": "symlink",
                "target": os.readlink(path),
            })
            continue
        data = path.read_bytes()
        row: dict[str, Any] = {
            "path": relative,
            "component": component_id,
            "kind": fixture_file_kind(relative),
            "size": len(data),
            "sha256": sha256(data),
        }
        if row["kind"] == "mach-o":
            row["dependencies"] = []
        files.append(row)
    write(
        roots["core"],
        "supply-chain/components.json",
        canonical_json(
            {
                "schemaVersion": 1,
                "toolchainVersion": VERSION,
                "components": sorted(components, key=lambda row: row["id"]),
                "files": files,
            }
        ),
    )


if __name__ == "__main__":
    main()
