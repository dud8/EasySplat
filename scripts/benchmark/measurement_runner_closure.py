#!/usr/bin/env python3
"""Build and verify the protected measurement-runner closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
from pathlib import Path
from typing import Any


SHA256 = re.compile(r"[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
EXECUTABLE_NAME = "EasySplatMeasurementRunner"
ADAPTER_NAME = "PipelineMeasurementAdapter.swift"
SUPPORT_NAME = "MeasurementAdapterSupport.swift"
CANDIDATE_ADAPTER_NAME = "PipelineMeasurementAdapter-current"
BASELINE_ADAPTER_NAME = "PipelineMeasurementAdapter-baseline"
REFERENCE_ADAPTER_NAME = "AccurateReferenceMeasurementAdapter"
EXPECTED_FILES = (
    EXECUTABLE_NAME,
    ADAPTER_NAME,
    SUPPORT_NAME,
    CANDIDATE_ADAPTER_NAME,
    BASELINE_ADAPTER_NAME,
    REFERENCE_ADAPTER_NAME,
)
MAXIMUM_FILE_BYTES = 64 * 1024 * 1024


class ClosureError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular(path: Path, label: str, *, executable: bool = False) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ClosureError(f"{label} is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise ClosureError(f"{label} must not be a symlink")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ClosureError(f"{label} must be a single-link regular file")
    if not 0 < metadata.st_size <= MAXIMUM_FILE_BYTES:
        raise ClosureError(f"{label} has an invalid size")
    if executable and not os.access(path, os.X_OK):
        raise ClosureError(f"{label} must be executable")


def reject_output_aliases(
    output: Path,
    identity_output: Path,
    source_inputs: tuple[Path, ...],
) -> None:
    output_identity = output.resolve(strict=False)
    identity_identity = identity_output.resolve(strict=False)
    if identity_identity == output_identity or output_identity in identity_identity.parents:
        raise ClosureError("identity output must not alias the closure output")
    if any(identity_identity == source.resolve(strict=True) for source in source_inputs):
        raise ClosureError("identity output must not alias a closure input")
    if identity_output.exists() or identity_output.is_symlink():
        raise ClosureError("identity output already exists")


def write_new_regular(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise ClosureError("identity output could not be created safely") from error
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as error:
        path.unlink(missing_ok=True)
        raise ClosureError("identity output could not be written safely") from error


def closure_identity(
    closure: Path,
    *,
    source_commit: str,
    xcode_version: str,
    swift_version: str,
) -> dict[str, Any]:
    files: dict[str, dict[str, Any]] = {}
    for name in EXPECTED_FILES:
        path = closure / name
        require_regular(
            path,
            name,
            executable=name in {
                EXECUTABLE_NAME,
                CANDIDATE_ADAPTER_NAME,
                BASELINE_ADAPTER_NAME,
                REFERENCE_ADAPTER_NAME,
            },
        )
        files[name] = {
            "bytes": path.stat().st_size,
            "sha256": file_digest(path),
        }
    payload: dict[str, Any] = {
        "schema_version": 1,
        "label": "tracked-measurement-runner",
        "source_commit": source_commit,
        "xcode_version": xcode_version,
        "swift_version": swift_version,
        "files": files,
    }
    payload["sha256"] = hashlib.sha256(canonical_json(payload)).hexdigest()
    return payload


def build(arguments: argparse.Namespace) -> None:
    executable = arguments.executable.resolve()
    adapter = arguments.adapter_source.resolve()
    support = arguments.support_source.resolve()
    candidate_adapter = arguments.candidate_adapter.resolve()
    baseline_adapter = arguments.baseline_adapter.resolve()
    reference_adapter = arguments.reference_adapter.resolve()
    require_regular(executable, "measurement runner", executable=True)
    require_regular(adapter, "pipeline adapter source")
    require_regular(support, "pipeline adapter support source")
    require_regular(candidate_adapter, "candidate pipeline adapter", executable=True)
    require_regular(baseline_adapter, "baseline pipeline adapter", executable=True)
    require_regular(reference_adapter, "accurate reference adapter", executable=True)
    if COMMIT.fullmatch(arguments.source_commit) is None:
        raise ClosureError("source commit must be a lowercase 40-character Git hash")
    if not arguments.xcode_version.startswith("Xcode "):
        raise ClosureError("Xcode build identity is invalid")
    if not arguments.swift_version.startswith("Swift version "):
        raise ClosureError("Swift build identity is invalid")
    output = arguments.output
    identity_output = arguments.identity_output
    if output.exists() or output.is_symlink():
        raise ClosureError("closure output already exists")
    reject_output_aliases(
        output,
        identity_output,
        (
            executable,
            adapter,
            support,
            candidate_adapter,
            baseline_adapter,
            reference_adapter,
        ),
    )
    output.mkdir(parents=True, mode=0o700)
    shutil.copyfile(executable, output / EXECUTABLE_NAME, follow_symlinks=False)
    os.chmod(output / EXECUTABLE_NAME, 0o700)
    shutil.copyfile(adapter, output / ADAPTER_NAME, follow_symlinks=False)
    os.chmod(output / ADAPTER_NAME, 0o600)
    shutil.copyfile(support, output / SUPPORT_NAME, follow_symlinks=False)
    os.chmod(output / SUPPORT_NAME, 0o600)
    for source, name in (
        (candidate_adapter, CANDIDATE_ADAPTER_NAME),
        (baseline_adapter, BASELINE_ADAPTER_NAME),
        (reference_adapter, REFERENCE_ADAPTER_NAME),
    ):
        shutil.copyfile(source, output / name, follow_symlinks=False)
        os.chmod(output / name, 0o700)
    identity = closure_identity(
        output,
        source_commit=arguments.source_commit,
        xcode_version=arguments.xcode_version,
        swift_version=arguments.swift_version,
    )
    write_new_regular(identity_output, canonical_json(identity))


def load_identity(path: Path) -> dict[str, Any]:
    require_regular(path, "measurement runner identity")
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ClosureError("measurement runner identity is invalid JSON") from error
    if raw != canonical_json(value) or not isinstance(value, dict):
        raise ClosureError("measurement runner identity must be canonical JSON")
    if set(value) != {
        "schema_version",
        "label",
        "source_commit",
        "xcode_version",
        "swift_version",
        "files",
        "sha256",
    }:
        raise ClosureError("measurement runner identity fields are invalid")
    return value


def verify(arguments: argparse.Namespace) -> None:
    closure = arguments.closure
    if closure.is_symlink() or not closure.is_dir():
        raise ClosureError("measurement runner closure must be a plain directory")
    actual_names = sorted(path.name for path in closure.iterdir())
    if actual_names != sorted(EXPECTED_FILES):
        raise ClosureError("measurement runner closure contents are invalid")
    expected = load_identity(arguments.identity)
    if (
        expected["schema_version"] != 1
        or expected["label"] != "tracked-measurement-runner"
        or not isinstance(expected["source_commit"], str)
        or COMMIT.fullmatch(expected["source_commit"]) is None
        or not isinstance(expected["xcode_version"], str)
        or not isinstance(expected["swift_version"], str)
        or not isinstance(expected["files"], dict)
        or not isinstance(expected["sha256"], str)
        or SHA256.fullmatch(expected["sha256"]) is None
    ):
        raise ClosureError("measurement runner identity values are invalid")
    actual = closure_identity(
        closure,
        source_commit=expected["source_commit"],
        xcode_version=expected["xcode_version"],
        swift_version=expected["swift_version"],
    )
    if actual != expected:
        raise ClosureError("measurement runner closure digest mismatch")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--executable", type=Path, required=True)
    build_parser.add_argument("--adapter-source", type=Path, required=True)
    build_parser.add_argument("--support-source", type=Path, required=True)
    build_parser.add_argument("--candidate-adapter", type=Path, required=True)
    build_parser.add_argument("--baseline-adapter", type=Path, required=True)
    build_parser.add_argument("--reference-adapter", type=Path, required=True)
    build_parser.add_argument("--source-commit", required=True)
    build_parser.add_argument("--xcode-version", required=True)
    build_parser.add_argument("--swift-version", required=True)
    build_parser.add_argument("--output", type=Path, required=True)
    build_parser.add_argument("--identity-output", type=Path, required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--closure", type=Path, required=True)
    verify_parser.add_argument("--identity", type=Path, required=True)
    return root


def main() -> int:
    try:
        arguments = parser().parse_args()
        if arguments.command == "build":
            build(arguments)
        else:
            verify(arguments)
        return 0
    except ClosureError as error:
        print(f"measurement runner closure: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
