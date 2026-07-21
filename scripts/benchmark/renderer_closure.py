#!/usr/bin/env python3
"""Build and verify the complete MetalSplatter benchmark renderer closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Mapping


SCHEMA_VERSION = 1
EXECUTABLE_NAME = "EasySplatBenchmarkDriver"
RESOURCE_BUNDLE_NAME = "MetalSplatter_MetalSplatter.bundle"
REQUIRED_SHADER_PATH = f"{RESOURCE_BUNDLE_NAME}/Shaders.metal"
MANIFEST_NAME = "closure-manifest.json"
IDENTITY_LABEL = "metal-splatter-benchmark-driver"
SHA256_PREFIX = "sha256:"


class ClosureError(ValueError):
    """The renderer closure is incomplete, unsafe, or not the approved build."""


@dataclass(frozen=True)
class VerifiedClosure:
    root: Path
    executable: Path
    resource_bundle: Path
    identity: dict[str, Any]


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return SHA256_PREFIX + hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return SHA256_PREFIX + digest.hexdigest()


def _regular_file(path: Path, label: str, *, executable: bool = False) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ClosureError(f"{label} is missing") from error
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise ClosureError(f"{label} must be a regular file")
    if executable and not os.access(path, os.X_OK):
        raise ClosureError(f"{label} must be executable")
    return path.resolve()


def _real_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ClosureError(f"{label} is missing") from error
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        raise ClosureError(f"{label} must be a real directory")
    return path.resolve()


def _safe_relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ClosureError(f"{label} must be a safe relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ClosureError(f"{label} must be a safe relative path")
    return value


def _contained_regular_file(
    root: Path,
    relative: str,
    label: str,
    *,
    executable: bool = False,
) -> Path:
    cursor = root
    parts = PurePosixPath(relative).parts
    for part in parts[:-1]:
        cursor /= part
        try:
            metadata = cursor.lstat()
        except OSError as error:
            raise ClosureError(f"{label} is missing") from error
        if not stat.S_ISDIR(metadata.st_mode) or cursor.is_symlink():
            raise ClosureError(f"{label} has an unsafe ancestor directory")
    candidate = cursor / parts[-1]
    regular = _regular_file(candidate, label, executable=executable)
    if regular.parent != root and root not in regular.parents:
        raise ClosureError(f"{label} escapes the renderer closure")
    return regular


def _digest(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 71
        or not value.startswith(SHA256_PREFIX)
        or any(character not in "0123456789abcdef" for character in value[7:])
    ):
        raise ClosureError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _manifest_entry(path: Path, relative: str, executable: bool) -> dict[str, Any]:
    regular = _regular_file(path, f"renderer closure file {relative}", executable=executable)
    return {
        "path": relative,
        "bytes": regular.stat().st_size,
        "sha256": sha256_file(regular),
        "executable": executable,
    }


def _copy_bundle(source: Path, destination: Path) -> None:
    source = _real_directory(source, "MetalSplatter resource bundle")
    for path in source.rglob("*"):
        if path.is_symlink():
            raise ClosureError("MetalSplatter resource bundle cannot contain symlinks")
        if not path.is_dir() and not path.is_file():
            raise ClosureError("MetalSplatter resource bundle contains an unsupported entry")
    shutil.copytree(source, destination, symlinks=False)


def _identity(manifest: Mapping[str, Any], manifest_bytes: bytes) -> dict[str, Any]:
    files = manifest["files"]
    executable = next(item for item in files if item["path"] == EXECUTABLE_NAME)
    return {
        "label": IDENTITY_LABEL,
        "sha256": sha256_bytes(canonical_json_bytes(manifest)),
        "executable_path": EXECUTABLE_NAME,
        "executable_sha256": executable["sha256"],
        "resource_bundle_path": RESOURCE_BUNDLE_NAME,
        "manifest_path": MANIFEST_NAME,
        "manifest_bytes": len(manifest_bytes),
        "manifest_sha256": sha256_bytes(manifest_bytes),
    }


def build_closure(
    executable: Path,
    resource_bundle: Path,
    output: Path,
    identity_output: Path,
) -> dict[str, Any]:
    executable = _regular_file(executable, "benchmark renderer", executable=True)
    _real_directory(resource_bundle, "MetalSplatter resource bundle")
    if resource_bundle.name != RESOURCE_BUNDLE_NAME:
        raise ClosureError(f"resource bundle must be named {RESOURCE_BUNDLE_NAME}")
    if not (resource_bundle / "Shaders.metal").is_file():
        raise ClosureError("MetalSplatter resource bundle is missing Shaders.metal")
    if output.exists() or output.is_symlink():
        raise ClosureError("renderer closure output must not already exist")

    output.mkdir(parents=True)
    destination_executable = output / EXECUTABLE_NAME
    shutil.copy2(executable, destination_executable)
    destination_executable.chmod(0o755)
    _copy_bundle(resource_bundle, output / RESOURCE_BUNDLE_NAME)

    entries = [_manifest_entry(destination_executable, EXECUTABLE_NAME, True)]
    for path in sorted((output / RESOURCE_BUNDLE_NAME).rglob("*")):
        if path.is_file():
            relative = path.relative_to(output).as_posix()
            entries.append(_manifest_entry(path, relative, False))
    entries.sort(key=lambda item: item["path"])
    if REQUIRED_SHADER_PATH not in {entry["path"] for entry in entries}:
        raise ClosureError("renderer closure is missing the MetalSplatter shader")
    manifest = {"schema_version": SCHEMA_VERSION, "files": entries}
    manifest_bytes = canonical_json_bytes(manifest) + b"\n"
    (output / MANIFEST_NAME).write_bytes(manifest_bytes)
    identity = _identity(manifest, manifest_bytes)
    identity_output.parent.mkdir(parents=True, exist_ok=True)
    identity_output.write_bytes(canonical_json_bytes(identity) + b"\n")
    verify_closure(output, identity)
    return identity


def load_identity(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(_regular_file(path, "renderer identity").read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ClosureError("renderer identity is not valid JSON") from error
    return validate_identity(value)


def validate_identity(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ClosureError("renderer identity must be an object")
    fields = {
        "label",
        "sha256",
        "executable_path",
        "executable_sha256",
        "resource_bundle_path",
        "manifest_path",
        "manifest_bytes",
        "manifest_sha256",
    }
    if set(value) != fields:
        raise ClosureError("renderer identity fields are invalid")
    if value["label"] != IDENTITY_LABEL:
        raise ClosureError("renderer identity label is invalid")
    if value["executable_path"] != EXECUTABLE_NAME:
        raise ClosureError("renderer executable path is invalid")
    if value["resource_bundle_path"] != RESOURCE_BUNDLE_NAME:
        raise ClosureError("renderer resource bundle path is invalid")
    if value["manifest_path"] != MANIFEST_NAME:
        raise ClosureError("renderer manifest path is invalid")
    if type(value["manifest_bytes"]) is not int or value["manifest_bytes"] <= 0:
        raise ClosureError("renderer manifest size is invalid")
    return {
        **dict(value),
        "sha256": _digest(value["sha256"], "renderer closure sha256"),
        "executable_sha256": _digest(
            value["executable_sha256"], "renderer executable sha256"
        ),
        "manifest_sha256": _digest(value["manifest_sha256"], "renderer manifest sha256"),
    }


def verify_closure(root: Path, expected_identity: Mapping[str, Any]) -> VerifiedClosure:
    root = _real_directory(root, "renderer closure")
    identity = validate_identity(expected_identity)
    manifest_path = _regular_file(root / MANIFEST_NAME, "renderer closure manifest")
    manifest_bytes = manifest_path.read_bytes()
    if len(manifest_bytes) != identity["manifest_bytes"]:
        raise ClosureError("renderer closure manifest size does not match its identity")
    if sha256_bytes(manifest_bytes) != identity["manifest_sha256"]:
        raise ClosureError("renderer closure manifest digest does not match its identity")
    try:
        manifest = json.loads(manifest_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ClosureError("renderer closure manifest is not valid JSON") from error
    if not isinstance(manifest, Mapping) or set(manifest) != {"schema_version", "files"}:
        raise ClosureError("renderer closure manifest fields are invalid")
    if manifest["schema_version"] != SCHEMA_VERSION or not isinstance(manifest["files"], list):
        raise ClosureError("renderer closure manifest schema is invalid")
    if sha256_bytes(canonical_json_bytes(manifest)) != identity["sha256"]:
        raise ClosureError("renderer closure digest does not match its identity")

    entries = manifest["files"]
    expected_paths: set[str] = set()
    previous_path = ""
    for position, raw_entry in enumerate(entries):
        if not isinstance(raw_entry, Mapping) or set(raw_entry) != {
            "path",
            "bytes",
            "sha256",
            "executable",
        }:
            raise ClosureError(f"renderer closure file {position} fields are invalid")
        relative = _safe_relative_path(raw_entry["path"], f"renderer closure file {position}")
        if relative <= previous_path or relative in expected_paths:
            raise ClosureError("renderer closure files must be unique and canonically ordered")
        previous_path = relative
        expected_paths.add(relative)
        executable = raw_entry["executable"]
        if type(executable) is not bool or executable != (relative == EXECUTABLE_NAME):
            raise ClosureError("renderer closure executable marker is invalid")
        path = _contained_regular_file(
            root,
            relative,
            f"renderer closure file {relative}",
            executable=executable,
        )
        size = raw_entry["bytes"]
        if type(size) is not int or size < 0 or path.stat().st_size != size:
            raise ClosureError(f"renderer closure file {relative} size is invalid")
        expected_digest = _digest(raw_entry["sha256"], f"renderer closure file {relative} sha256")
        if sha256_file(path) != expected_digest:
            raise ClosureError(f"renderer closure file {relative} digest is invalid")

    actual_paths: set[str] = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ClosureError("renderer closure cannot contain symlinks")
        if path.is_file():
            actual_paths.add(path.relative_to(root).as_posix())
        elif not path.is_dir():
            raise ClosureError("renderer closure contains an unsupported entry")
    if actual_paths != expected_paths | {MANIFEST_NAME}:
        raise ClosureError("renderer closure file set does not match its manifest")
    if REQUIRED_SHADER_PATH not in expected_paths:
        raise ClosureError("renderer closure file set is missing the MetalSplatter shader")

    executable = root / EXECUTABLE_NAME
    if sha256_file(executable) != identity["executable_sha256"]:
        raise ClosureError("renderer executable digest does not match its identity")
    return VerifiedClosure(
        root=root,
        executable=executable,
        resource_bundle=root / RESOURCE_BUNDLE_NAME,
        identity=identity,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--executable", type=Path, required=True)
    build.add_argument("--resource-bundle", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--identity-output", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--closure", type=Path, required=True)
    verify.add_argument("--identity", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            identity = build_closure(
                args.executable,
                args.resource_bundle,
                args.output,
                args.identity_output,
            )
            print(canonical_json_bytes(identity).decode("utf-8"))
        else:
            verified = verify_closure(args.closure, load_identity(args.identity))
            print(canonical_json_bytes(verified.identity).decode("utf-8"))
        return 0
    except ClosureError as error:
        print(f"renderer closure error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
