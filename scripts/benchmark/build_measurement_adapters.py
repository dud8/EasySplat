#!/usr/bin/env python3
"""Compile the identical pipeline adapter against two exact EasySplat checkouts."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path


COMMIT = re.compile(r"[0-9a-f]{40}")
SWIFT_SETTINGS = {
    "CURRENT_ADAPTER": ', swiftSettings: [.define("CURRENT_ADAPTER")]',
    "BASELINE_ADAPTER": ', swiftSettings: [.define("BASELINE_ADAPTER")]',
    "ACCURATE_REFERENCE": ', swiftSettings: [.define("ACCURATE_REFERENCE")]',
}


class BuildError(RuntimeError):
    pass


def git(checkout: Path, *arguments: str) -> str:
    try:
        return git_bytes(checkout, *arguments).decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise BuildError(f"Git returned invalid UTF-8 for {checkout.name}") from error


def git_bytes(checkout: Path, *arguments: str) -> bytes:
    completed = subprocess.run(
        ["/usr/bin/git", "-C", str(checkout), *arguments],
        capture_output=True,
        check=False,
        env={"PATH": "/usr/bin:/bin"},
    )
    if completed.returncode != 0:
        raise BuildError(f"Git could not verify {checkout.name}")
    return completed.stdout


def update_digest(digest, label: bytes, value: bytes) -> None:
    digest.update(label)
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def update_untracked_file_digest(
    digest, checkout: Path, relative_name: bytes
) -> None:
    relative = Path(os.fsdecode(relative_name))
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise BuildError("Git reported an unsafe untracked path")
    path = checkout / relative
    before = path.lstat()
    update_digest(digest, b"untracked-path\0", relative_name)
    update_digest(
        digest,
        b"untracked-mode\0",
        stat.S_IMODE(before.st_mode).to_bytes(4, "big"),
    )
    if stat.S_ISLNK(before.st_mode):
        update_digest(
            digest,
            b"untracked-symlink\0",
            os.fsencode(os.readlink(path)),
        )
        after = path.lstat()
    elif stat.S_ISREG(before.st_mode):
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_dev != before.st_dev
                or opened.st_ino != before.st_ino
            ):
                raise BuildError("an untracked source changed while it was inspected")
            file_digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                file_digest.update(chunk)
            update_digest(digest, b"untracked-sha256\0", file_digest.digest())
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    else:
        raise BuildError("untracked adapter sources must be regular files or symlinks")
    if (
        after.st_dev != before.st_dev
        or after.st_ino != before.st_ino
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
    ):
        raise BuildError("an untracked source changed while it was inspected")


def dirty_checkout_digest(checkout: Path, status: bytes) -> str:
    digest = hashlib.sha256()
    update_digest(digest, b"status-v1-z\0", status)
    update_digest(
        digest,
        b"tracked-diff\0",
        git_bytes(
            checkout,
            "diff",
            "--binary",
            "--no-ext-diff",
            "--no-textconv",
            "HEAD",
            "--",
        ),
    )
    untracked = git_bytes(
        checkout, "ls-files", "--others", "--exclude-standard", "-z"
    )
    names = sorted(name for name in untracked.split(b"\0") if name)
    update_digest(digest, b"untracked-names\0", b"\0".join(names))
    for name in names:
        update_untracked_file_digest(digest, checkout, name)
    return digest.hexdigest()


def require_checkout(
    checkout: Path, expected_commit: str, *, allow_dirty: bool = False
) -> str:
    if checkout.is_symlink() or not checkout.is_dir():
        raise BuildError(f"{checkout} is not a plain checkout directory")
    if COMMIT.fullmatch(expected_commit) is None:
        raise BuildError("expected commit is invalid")
    if git(checkout, "rev-parse", "HEAD") != expected_commit:
        raise BuildError(f"{checkout.name} is not at the expected commit")
    status = git_bytes(
        checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all"
    )
    if status and not allow_dirty:
        raise BuildError(f"{checkout.name} must be clean")
    if not status:
        return "clean"
    return f"dirty:{dirty_checkout_digest(checkout, status)}"


def require_unchanged_checkout(
    checkout: Path,
    expected_commit: str,
    *,
    expected_state: str,
    allow_dirty: bool = False,
) -> None:
    actual_state = require_checkout(
        checkout, expected_commit, allow_dirty=allow_dirty
    )
    if actual_state != expected_state:
        raise BuildError(f"{checkout.name} changed during adapter build")


def swift_literal(path: Path) -> str:
    value = str(path.resolve())
    if '"' in value or "\\" in value or any(ord(character) < 32 for character in value):
        raise BuildError("checkout path cannot be represented in a Swift manifest")
    return value


def build_one(
    *,
    checkout: Path,
    adapter_source: Path,
    support_source: Path,
    scratch: Path,
    output: Path,
    product_name: str = "PipelineMeasurementAdapter",
    compile_time_variant: str,
) -> None:
    overlay = scratch / "overlay"
    source_directory = overlay / f"Sources/{product_name}"
    source_directory.mkdir(parents=True)
    try:
        swift_settings = SWIFT_SETTINGS[compile_time_variant]
    except KeyError as error:
        raise BuildError("unknown compile-time adapter variant") from error
    manifest = f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "EasySplatPipelineMeasurementOverlay",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "EasySplat", path: "{swift_literal(checkout)}")],
    targets: [.executableTarget(
        name: "{product_name}",
        dependencies: [.product(name: "EasySplatCore", package: "EasySplat")]{swift_settings}
    )]
)
'''
    (overlay / "Package.swift").write_text(manifest, encoding="utf-8")
    shutil.copyfile(
        adapter_source,
        source_directory / "PipelineMeasurementAdapter.swift",
        follow_symlinks=False,
    )
    shutil.copyfile(
        support_source,
        source_directory / "MeasurementAdapterSupport.swift",
        follow_symlinks=False,
    )
    build_root = scratch / "build"
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(scratch / "home"),
        "TMPDIR": str(scratch / "tmp"),
        "CLANG_MODULE_CACHE_PATH": str(scratch / "clang-cache"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(scratch / "swift-cache"),
    }
    for directory in (Path(environment["HOME"]), Path(environment["TMPDIR"])):
        directory.mkdir(parents=True)
    command = [
        "/usr/bin/swift",
        "build",
        "--disable-sandbox",
        "--configuration",
        "release",
        "--package-path",
        str(overlay),
        "--scratch-path",
        str(build_root),
        "--product",
        product_name,
    ]
    command.extend(["-Xswiftc", "-enable-testing"])
    subprocess.run(command, check=True, env=environment)
    bin_path_command = [
        "/usr/bin/swift",
        "build",
        "--disable-sandbox",
        "--configuration",
        "release",
        "--package-path",
        str(overlay),
        "--scratch-path",
        str(build_root),
        "--show-bin-path",
    ]
    bin_path_command.extend(["-Xswiftc", "-enable-testing"])
    bin_path = subprocess.run(
        bin_path_command,
        check=True,
        text=True,
        capture_output=True,
        env=environment,
    ).stdout.strip()
    source_binary = Path(bin_path) / product_name
    metadata = source_binary.lstat()
    if not stat.S_ISREG(metadata.st_mode) or not os.access(source_binary, os.X_OK):
        raise BuildError("SwiftPM did not produce the adapter executable")
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source_binary, output, follow_symlinks=False)
    output.chmod(0o755)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-checkout", type=Path, required=True)
    parser.add_argument("--current-commit", required=True)
    parser.add_argument("--baseline-checkout", type=Path, required=True)
    parser.add_argument("--baseline-commit", required=True)
    parser.add_argument("--adapter-source", type=Path, required=True)
    parser.add_argument("--support-source", type=Path, required=True)
    parser.add_argument("--scratch-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--allow-dirty-current-checkout", action="store_true")
    arguments = parser.parse_args()
    try:
        current_checkout = arguments.current_checkout.resolve()
        baseline_checkout = arguments.baseline_checkout.resolve()
        source = arguments.adapter_source.resolve()
        support = arguments.support_source.resolve()
        for path, label in ((source, "adapter"), (support, "adapter support")):
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise BuildError(f"{label} source must be a plain regular file")
        current_state = require_checkout(
            current_checkout,
            arguments.current_commit,
            allow_dirty=arguments.allow_dirty_current_checkout,
        )
        require_checkout(baseline_checkout, arguments.baseline_commit)
        print(f"current checkout evidence: {current_state}")
        if arguments.scratch_root.exists() or arguments.output_root.exists():
            raise BuildError("adapter build destinations must not already exist")
        build_one(
            checkout=current_checkout,
            adapter_source=source,
            support_source=support,
            scratch=arguments.scratch_root / "current",
            output=arguments.output_root / "PipelineMeasurementAdapter-current",
            compile_time_variant="CURRENT_ADAPTER",
        )
        require_unchanged_checkout(
            current_checkout,
            arguments.current_commit,
            expected_state=current_state,
            allow_dirty=arguments.allow_dirty_current_checkout,
        )
        require_checkout(baseline_checkout, arguments.baseline_commit)
        build_one(
            checkout=baseline_checkout,
            adapter_source=source,
            support_source=support,
            scratch=arguments.scratch_root / "baseline",
            output=arguments.output_root / "PipelineMeasurementAdapter-baseline",
            compile_time_variant="BASELINE_ADAPTER",
        )
        require_unchanged_checkout(
            current_checkout,
            arguments.current_commit,
            expected_state=current_state,
            allow_dirty=arguments.allow_dirty_current_checkout,
        )
        require_checkout(baseline_checkout, arguments.baseline_commit)
        build_one(
            checkout=current_checkout,
            adapter_source=source,
            support_source=support,
            scratch=arguments.scratch_root / "accurate-reference",
            output=arguments.output_root / "AccurateReferenceMeasurementAdapter",
            product_name="AccurateReferenceMeasurementAdapter",
            compile_time_variant="ACCURATE_REFERENCE",
        )
        require_unchanged_checkout(
            current_checkout,
            arguments.current_commit,
            expected_state=current_state,
            allow_dirty=arguments.allow_dirty_current_checkout,
        )
        require_checkout(baseline_checkout, arguments.baseline_commit)
        return 0
    except (BuildError, OSError, subprocess.SubprocessError) as error:
        print(f"measurement adapter build: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
