#!/usr/bin/env python3
"""Validate the exact release shape of an EasySplat DA3 runtime payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import NoReturn


DA3_MODEL_LOCK = Path(__file__).resolve().with_name("da3-model-lock.json")
TOP_LEVEL_ENTRIES = {
    "app",
    "bin",
    "build_info.json",
    "licenses",
    "models",
    "python",
    "vendor",
}
APP_FILES = {"__init__.py", "alignment.py", "run.py"}
MODEL_FILES = {
    "LICENSE",
    "config.json",
    "easysplat_model_info.json",
    "model.safetensors",
}
LICENSE_ENTRIES = {
    "python-build-standalone",
    "python-package-upstream-notices.json",
    "python-packages-install-report.json",
    "python-packages-requirements.txt",
}
RECEIPT_FIELDS = {
    "toolchain_name",
    "source_repo",
    "source_ref",
    "source_commit",
    "source_path",
    "source_provenance",
    "expected_upstream_repo",
    "expected_upstream_ref",
    "base_checkpoint_repo",
    "base_checkpoint_revision",
    "base_checkpoint_commit",
    "small_checkpoint_repo",
    "small_checkpoint_revision",
    "small_checkpoint_commit",
    "model_lock",
    "model_lock_sha256",
    "python_version",
    "python_standalone_url",
    "python_standalone_sha256",
    "python_standalone_license_archive_url",
    "python_standalone_license_archive_sha256",
    "requirements_lock",
    "requirements_lock_sha256",
    "runtime_patch",
    "runtime_patch_sha256",
    "supplemental_license_manifest",
    "supplemental_license_manifest_sha256",
    "pip_install_report",
    "torch_version",
    "torchvision_version",
    "huggingface_hub_version",
}
FORBIDDEN_PATH_TOKENS = ("pycolmap", "colmap_cli", "easysplat_colmap")
FORBIDDEN_RUNTIME_TOKENS = (
    b"pycolmap",
    b"colmap_cli",
    b"easysplat_colmap",
    b"--self-check",
)
SHA256 = re.compile(r"[0-9a-f]{64}")
MODEL_INFO_FIELDS = {
    "repo_id",
    "requested_revision",
    "resolved_sha",
    "license",
    "artifacts",
}
MODEL_ARTIFACTS = {"config.json", "model.safetensors"}
MODEL_ARTIFACT_FIELDS = {"sha256", "size_bytes"}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"DA3 payload validation failed: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def exact_children(root: Path, expected: set[str], label: str) -> None:
    actual = {path.name for path in root.iterdir()}
    if actual != expected:
        fail(
            f"{label} must contain the exact reviewed entries; "
            f"expected {sorted(expected)}, got {sorted(actual)}"
        )


def require_directory(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        fail(f"{label} is missing or is not a directory: {path}")


def require_file(path: Path, label: str, *, executable: bool = False) -> None:
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        fail(f"{label} is missing, empty, or is not a regular file: {path}")
    if executable and not os.access(path, os.X_OK):
        fail(f"{label} is not executable: {path}")


def load_json(path: Path, label: str) -> dict:
    require_file(path, label)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label} is not valid JSON: {exc}")
    if not isinstance(payload, dict):
        fail(f"{label} must contain a JSON object")
    return payload


def load_model_lock() -> dict[str, dict]:
    lock = load_json(DA3_MODEL_LOCK, "DA3 model lock")
    if set(lock) != {"schema_version", "models"} or lock.get("schema_version") != 1:
        fail("DA3 model lock does not match schema 1")
    models = lock.get("models")
    if not isinstance(models, dict) or set(models) != {"DA3-BASE", "DA3-SMALL"}:
        fail("DA3 model lock must contain exactly DA3-BASE and DA3-SMALL")
    for model_name, model in models.items():
        if not isinstance(model, dict) or set(model) != MODEL_INFO_FIELDS:
            fail(f"{model_name} model lock fields do not match the reviewed contract")
        for field in ("repo_id", "requested_revision", "resolved_sha", "license"):
            if not isinstance(model[field], str) or not model[field]:
                fail(f"{model_name} model lock has an invalid {field}")
        if not re.fullmatch(r"[0-9a-f]{40}", model["requested_revision"]):
            fail(f"{model_name} model lock has an invalid requested_revision")
        if model["resolved_sha"] != model["requested_revision"]:
            fail(
                f"{model_name} model lock revision does not resolve to its pinned commit"
            )
        if model["license"] != "apache-2.0":
            fail(f"{model_name} model lock has an unreviewed license")
        artifacts = model["artifacts"]
        if not isinstance(artifacts, dict) or set(artifacts) != MODEL_ARTIFACTS:
            fail(f"{model_name} model lock has an incomplete artifact closure")
        for artifact_name, artifact in artifacts.items():
            if not isinstance(artifact, dict) or set(artifact) != MODEL_ARTIFACT_FIELDS:
                fail(
                    f"{model_name} {artifact_name} lock fields do not match the "
                    "reviewed contract"
                )
            digest = artifact["sha256"]
            size = artifact["size_bytes"]
            if not isinstance(digest, str) or not SHA256.fullmatch(digest):
                fail(f"{model_name} {artifact_name} has an invalid locked SHA-256")
            if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
                fail(f"{model_name} {artifact_name} has an invalid locked byte size")
    return models


def validate_model(model_root: Path, model_name: str, reviewed: dict) -> None:
    info = load_json(
        model_root / "easysplat_model_info.json", f"{model_name} model metadata"
    )
    if info != reviewed:
        fail(f"{model_name} model metadata does not match the reviewed model lock")
    for artifact_name in sorted(MODEL_ARTIFACTS):
        path = model_root / artifact_name
        expected = reviewed["artifacts"][artifact_name]
        if path.stat().st_size != expected["size_bytes"]:
            fail(
                f"{model_name} {artifact_name} artifact byte size does not match the lock"
            )
        if sha256(path) != expected["sha256"]:
            fail(
                f"{model_name} {artifact_name} artifact SHA-256 does not match the lock"
            )


def validate_no_links_or_special_files(root: Path) -> None:
    for path in (root, *sorted(root.rglob("*"))):
        relative = "." if path == root else path.relative_to(root).as_posix()
        try:
            metadata = path.lstat()
        except OSError as exc:
            fail(f"payload entry cannot be inspected: {relative}: {exc}")
        if stat.S_ISLNK(metadata.st_mode):
            fail(f"payload must not contain any symlink: {relative}")
        if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            fail(f"payload contains an unsupported filesystem entry: {relative}")


def validate_receipt(root: Path, reviewed_models: dict[str, dict]) -> None:
    receipt = load_json(root / "build_info.json", "DA3 build receipt")
    if set(receipt) != RECEIPT_FIELDS:
        fail(
            "DA3 build receipt fields must match the exact reviewed contract; "
            f"expected {sorted(RECEIPT_FIELDS)}, got {sorted(receipt)}"
        )
    if receipt.get("toolchain_name") != "da3_mps":
        fail("DA3 build receipt has the wrong toolchain_name")
    if receipt.get("source_provenance") not in {
        "pinned-git",
        "unverified-local-snapshot",
    }:
        fail("DA3 build receipt has an unsupported source_provenance")
    expected_paths = {
        "model_lock": "scripts/toolchain/da3-model-lock.json",
        "requirements_lock": "Tools/Da3Sfm/requirements.txt",
        "runtime_patch": "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
        "supplemental_license_manifest": (
            "licenses/python-package-upstream-notices.json"
        ),
        "pip_install_report": "licenses/python-packages-install-report.json",
    }
    for field, expected in expected_paths.items():
        if receipt.get(field) != expected:
            fail(f"DA3 build receipt has an unexpected {field}")
    for field in (
        "python_standalone_sha256",
        "python_standalone_license_archive_sha256",
        "requirements_lock_sha256",
        "runtime_patch_sha256",
        "supplemental_license_manifest_sha256",
        "model_lock_sha256",
    ):
        value = receipt.get(field)
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            fail(f"DA3 build receipt has an invalid {field}")

    checked_files = {
        "model_lock_sha256": DA3_MODEL_LOCK,
        "requirements_lock_sha256": root
        / "licenses"
        / "python-packages-requirements.txt",
        "supplemental_license_manifest_sha256": root
        / "licenses"
        / "python-package-upstream-notices.json",
    }
    for field, path in checked_files.items():
        if sha256(path) != receipt[field]:
            fail(f"DA3 payload does not match receipt field {field}")
    checkpoint_fields = {
        "DA3-BASE": (
            "base_checkpoint_repo",
            "base_checkpoint_revision",
            "base_checkpoint_commit",
        ),
        "DA3-SMALL": (
            "small_checkpoint_repo",
            "small_checkpoint_revision",
            "small_checkpoint_commit",
        ),
    }
    for model_name, (
        repo_field,
        revision_field,
        commit_field,
    ) in checkpoint_fields.items():
        reviewed = reviewed_models[model_name]
        if receipt.get(repo_field) != reviewed["repo_id"]:
            fail(f"DA3 build receipt has an unexpected {repo_field}")
        if receipt.get(revision_field) != reviewed["requested_revision"]:
            fail(f"DA3 build receipt has an unexpected {revision_field}")
        if receipt.get(commit_field) != reviewed["resolved_sha"]:
            fail(f"DA3 build receipt has an unexpected {commit_field}")


def validate(root: Path) -> None:
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        fail(f"payload root is missing or unsafe: {root}")
    validate_no_links_or_special_files(root)
    reviewed_models = load_model_lock()

    exact_children(root, TOP_LEVEL_ENTRIES, "DA3 payload root")
    require_directory(root / "bin", "DA3 bin directory")
    exact_children(root / "bin", {"easysplat_da3_sfm"}, "DA3 bin directory")
    require_file(
        root / "bin" / "easysplat_da3_sfm",
        "DA3 launcher",
        executable=True,
    )

    require_directory(root / "app", "DA3 app directory")
    exact_children(root / "app", {"easysplat_da3_sfm"}, "DA3 app directory")
    app = root / "app" / "easysplat_da3_sfm"
    require_directory(app, "DA3 app package")
    exact_children(app, APP_FILES, "DA3 app package")
    for name in APP_FILES:
        require_file(app / name, f"DA3 app file {name}")

    require_directory(root / "models", "DA3 models directory")
    exact_children(root / "models", {"DA3-BASE", "DA3-SMALL"}, "DA3 models directory")
    for model in ("DA3-BASE", "DA3-SMALL"):
        model_root = root / "models" / model
        require_directory(model_root, f"{model} directory")
        exact_children(model_root, MODEL_FILES, f"{model} payload")
        for name in MODEL_FILES:
            require_file(model_root / name, f"{model} file {name}")
        validate_model(model_root, model, reviewed_models[model])

    require_directory(root / "licenses", "DA3 licenses directory")
    exact_children(root / "licenses", LICENSE_ENTRIES, "DA3 licenses directory")
    for name in LICENSE_ENTRIES - {"python-build-standalone"}:
        require_file(root / "licenses" / name, f"DA3 license receipt {name}")
    python_notices = root / "licenses" / "python-build-standalone"
    require_directory(python_notices, "python-build-standalone license directory")
    require_file(python_notices / "PYTHON.json", "python-build-standalone receipt")
    require_directory(
        python_notices / "licenses", "python-build-standalone notices directory"
    )

    require_directory(root / "python", "DA3 Python runtime")
    require_file(
        root / "python" / "bin" / "python3",
        "DA3 Python executable",
        executable=True,
    )
    require_directory(root / "vendor", "DA3 vendor directory")
    exact_children(root / "vendor", {"depth-anything-3"}, "DA3 vendor directory")
    vendor = root / "vendor" / "depth-anything-3"
    require_directory(vendor, "DA3 vendored source")
    exact_children(vendor, {"LICENSE", "src"}, "DA3 vendored source")
    require_file(vendor / "LICENSE", "DA3 vendored source license")
    require_file(
        vendor / "src" / "depth_anything_3" / "api.py",
        "DA3 vendored API",
    )

    for path in root.rglob("*"):
        lowered = path.name.casefold()
        if any(token in lowered for token in FORBIDDEN_PATH_TOKENS):
            fail(
                f"retired Python COLMAP bridge entry is present: {path.relative_to(root)}"
            )

    runtime_files = [root / "bin" / "easysplat_da3_sfm"] + [
        app / name for name in sorted(APP_FILES)
    ]
    for path in runtime_files:
        data = path.read_bytes().lower()
        for token in FORBIDDEN_RUNTIME_TOKENS:
            if token in data:
                fail(
                    "forbidden runtime token "
                    f"{token.decode('ascii')} is present in {path.relative_to(root)}"
                )
    requirements = (root / "licenses" / "python-packages-requirements.txt").read_text(
        encoding="utf-8"
    )
    if "pycolmap" in requirements.casefold():
        fail("retired Python COLMAP distribution is present in the requirements lock")

    validate_receipt(root, reviewed_models)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    validate(args.root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
