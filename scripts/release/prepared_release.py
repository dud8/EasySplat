#!/usr/bin/env python3
"""Create and verify the immutable, uncredentialed app-release handoff."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile
import unicodedata


MANIFEST_NAME = "prepared-release.json"
SCHEMA_VERSION = 2
MAX_FILES = 250_000
MAX_TOTAL_BYTES = 40 * 1024 * 1024 * 1024
MAX_ARCHIVE_BYTES = MAX_TOTAL_BYTES + 512 * 1024 * 1024
SHA1 = re.compile(r"[0-9a-f]{40}")
SEMVER = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


class PreparedReleaseError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise PreparedReleaseError(message)


def canonical_root(raw: Path) -> Path:
    if not raw.is_absolute() or os.path.normpath(os.fspath(raw)) != os.fspath(raw):
        fail("prepared release root must be an absolute normalized path")
    try:
        metadata = raw.lstat()
    except OSError as error:
        fail(f"cannot inspect prepared release root: {error}")
    if raw.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        fail("prepared release root must be a real directory")
    resolved = raw.resolve(strict=True)
    if resolved != raw:
        fail("prepared release root must contain no symlink ancestry")
    if metadata.st_uid != os.geteuid() or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("prepared release root must be owned and not group/world writable")
    return resolved


def validate_metadata(args: argparse.Namespace) -> dict[str, object]:
    values = {
        "appVersion": args.app_version,
        "releaseMode": "production-prepared",
        "runAttempt": args.run_attempt,
        "runID": args.run_id,
        "schemaVersion": SCHEMA_VERSION,
        "sourceCommit": args.source_commit,
        "sourceRepository": args.source_repository,
        "toolchainVersion": args.toolchain_version,
        "buildAuthority": {
            "environment": args.builder_environment,
            "macOSSDKVersion": args.macos_sdk_version,
            "xcodeBuild": args.xcode_build,
            "xcodeVersion": args.xcode_version,
        },
    }
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.source_repository):
        fail("source repository must be an owner/name pair")
    if not SHA1.fullmatch(args.source_commit):
        fail("source commit must be a lowercase 40-hex Git object ID")
    if not SEMVER.fullmatch(args.app_version) or "-" in args.app_version:
        fail("app version must be a stable semantic version")
    if not SEMVER.fullmatch(args.toolchain_version) or "-" in args.toolchain_version:
        fail("toolchain version must be a stable semantic version")
    if not re.fullmatch(r"[1-9][0-9]*", args.run_id):
        fail("run ID must be a positive decimal integer")
    if not re.fullmatch(r"[1-9][0-9]*", args.run_attempt):
        fail("run attempt must be a positive decimal integer")
    if args.builder_environment != "github-hosted":
        fail("prepared app authority must be a GitHub-hosted runner")
    if re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", args.xcode_version) is None:
        fail("Xcode version must be a dotted numeric version")
    if re.fullmatch(r"[0-9A-Za-z]{2,32}", args.xcode_build) is None:
        fail("Xcode build must be a compact alphanumeric build identifier")
    if re.fullmatch(r"[0-9]+\.[0-9]+", args.macos_sdk_version) is None:
        fail("macOS SDK version must be major.minor")
    return values


def safe_relative(path: Path, root: Path) -> str:
    relative = path.relative_to(root).as_posix()
    pure = PurePosixPath(relative)
    if (
        not relative
        or pure.is_absolute()
        or any(part in {"", ".", ".."} for part in pure.parts)
        or unicodedata.normalize("NFC", relative) != relative
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in relative)
    ):
        fail(f"unsafe prepared release path: {relative!r}")
    return relative


def digest_file(path: Path, before: os.stat_result) -> str:
    digest = hashlib.sha256()
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError as error:
        fail(f"cannot open prepared release file {path}: {error}")
    try:
        opened = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        opened_identity = (
            opened.st_dev,
            opened.st_ino,
            opened.st_size,
            opened.st_mtime_ns,
            opened.st_ctime_ns,
        )
        if opened_identity != identity:
            fail(f"prepared release file changed before hashing: {path}")
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        after_identity = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if after_identity != identity:
            fail(f"prepared release file changed while hashing: {path}")
    finally:
        os.close(descriptor)
    return digest.hexdigest()


# The signing runner rebuilds the release documents from the staged toolchain
# tree the app was built from, so the handoff carries that tree rather than the
# archives an installer once downloaded.
REQUIRED_PREPARED_FILES = (
    "product/EasySplat.app/Contents/MacOS/EasySplatApp",
    "product/EasySplat.app/Contents/Helpers/bin/colmap",
    "product/EasySplat.app/Contents/Helpers/bin/easysplat-train",
    "product/EasySplat.app/Contents/Helpers/lib/libomp.dylib",
    "product/EasySplat.app/Contents/Resources/Toolchain/default.metallib",
    "product/EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp",
    "toolchain/out/bin/colmap",
    "toolchain/out/bin/easysplat-train",
    "toolchain/out/bin/default.metallib",
    "toolchain/out/lib/libomp.dylib",
    "toolchain/out/supply-chain/components.json",
)


def require_data_only_path(relative: str, *, is_directory: bool) -> None:
    allowed_roots = (
        "product/EasySplat.app",
        "product/EasySplat.app.dSYM",
        "toolchain/out",
    )
    if relative in {"product", "toolchain"} or any(
        relative == prefix or relative.startswith(prefix + "/")
        for prefix in allowed_roots
    ):
        return
    fail(f"prepared release must be data-only; unexpected path: {relative}")


def closure_rows(root: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    total_bytes = 0
    folded_paths: set[str] = set()
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            fail(f"cannot enumerate prepared release directory {directory}: {error}")
        for child in children:
            path = Path(child.path)
            relative = safe_relative(path, root)
            if relative == MANIFEST_NAME:
                continue
            folded = unicodedata.normalize("NFC", relative).casefold()
            if folded in folded_paths:
                fail(f"case-folding path collision in prepared release: {relative}")
            folded_paths.add(folded)
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as error:
                fail(f"cannot inspect prepared release entry {relative}: {error}")
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"prepared release contains a symlink: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                require_data_only_path(relative, is_directory=True)
                rows.append({"kind": "directory", "mode": mode, "path": relative})
                pending.append(path)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                fail(f"prepared release contains a special file: {relative}")
            if metadata.st_nlink != 1:
                fail(f"prepared release contains a hardlink: {relative}")
            require_data_only_path(relative, is_directory=False)
            total_bytes += metadata.st_size
            if total_bytes > MAX_TOTAL_BYTES:
                fail("prepared release exceeds the total byte bound")
            rows.append(
                {
                    "kind": "file",
                    "mode": mode,
                    "path": relative,
                    "sha256": digest_file(path, metadata),
                    "size": metadata.st_size,
                }
            )
            if len(rows) > MAX_FILES:
                fail("prepared release exceeds the file-count bound")
    rows.sort(key=lambda row: str(row["path"]))
    paths = {str(row["path"]) for row in rows}
    missing = sorted(set(REQUIRED_PREPARED_FILES) - paths)
    if missing:
        fail(f"prepared release is missing required files: {missing}")
    return rows


def subject_digest(rows: list[dict[str, object]], prefix: str) -> str:
    selected = [
        row
        for row in rows
        if str(row["path"]) == prefix or str(row["path"]).startswith(prefix + "/")
    ]
    if not selected:
        fail(f"prepared release subject is empty: {prefix}")
    encoded = json.dumps(
        selected,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def subject_digests(rows: list[dict[str, object]]) -> dict[str, str]:
    return {
        "app": subject_digest(rows, "product/EasySplat.app"),
        "dSYM": subject_digest(rows, "product/EasySplat.app.dSYM"),
        "toolchain": subject_digest(rows, "toolchain"),
    }


def write_manifest(path: Path, payload: dict[str, object]) -> None:
    encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
    except OSError as error:
        fail(f"cannot create prepared release manifest: {error}")
    try:
        offset = 0
        while offset < len(encoded):
            offset += os.write(descriptor, encoded[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def read_manifest(
    path: Path,
    *,
    expected_sha256: str | None = None,
) -> dict[str, object]:
    if expected_sha256 is not None and re.fullmatch(
        r"[0-9a-f]{64}", expected_sha256
    ) is None:
        fail("expected prepared release manifest digest must be lowercase SHA-256")
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"prepared release manifest is missing: {error}")
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        fail("prepared release manifest must be a single-link regular file")
    if metadata.st_size <= 0 or metadata.st_size > 128 * 1024 * 1024:
        fail("prepared release manifest has an invalid size")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino, opened.st_size) != (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_size,
            ):
                fail("prepared release manifest changed before reading")
            chunks: list[bytes] = []
            while chunk := os.read(descriptor, 1024 * 1024):
                chunks.append(chunk)
            after = os.fstat(descriptor)
            if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
                opened.st_dev,
                opened.st_ino,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            ):
                fail("prepared release manifest changed while reading")
        finally:
            os.close(descriptor)
        encoded = b"".join(chunks)
        if (
            expected_sha256 is not None
            and hashlib.sha256(encoded).hexdigest() != expected_sha256
        ):
            fail("prepared release manifest digest does not match the trusted handoff")
        payload = json.loads(encoded)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"prepared release manifest is invalid: {error}")
    if not isinstance(payload, dict):
        fail("prepared release manifest must be a JSON object")
    return payload


def create(args: argparse.Namespace) -> None:
    root = canonical_root(args.root)
    manifest = root / MANIFEST_NAME
    if os.path.lexists(manifest):
        fail("prepared release manifest already exists")
    payload = validate_metadata(args)
    rows = closure_rows(root)
    payload["entries"] = rows
    payload["subjects"] = subject_digests(rows)
    write_manifest(manifest, payload)


def verify(args: argparse.Namespace) -> None:
    root = canonical_root(args.root)
    payload = read_manifest(
        root / MANIFEST_NAME,
        expected_sha256=args.expected_manifest_sha256,
    )
    authority_fields = (
        "source_repository",
        "source_commit",
        "app_version",
        "toolchain_version",
        "run_id",
        "run_attempt",
        "builder_environment",
        "xcode_version",
        "xcode_build",
        "macos_sdk_version",
    )
    if args.authority_from_manifest:
        if args.expected_manifest_sha256 is None:
            fail("manifest authority requires an expected manifest digest")
        for name in ("source_commit", "app_version", "toolchain_version"):
            if getattr(args, name) is None:
                fail(f"manifest authority requires --{name.replace('_', '-')}")
        if any(
            getattr(args, name) is not None
            for name in authority_fields
            if name not in {"source_commit", "app_version", "toolchain_version"}
        ):
            fail("manifest authority accepts only release identity constraints")
        build_authority = payload.get("buildAuthority")
        if not isinstance(build_authority, dict):
            build_authority = {}

        def text(value: object) -> str:
            return value if isinstance(value, str) else ""

        manifest_authority = argparse.Namespace(
            source_repository=text(payload.get("sourceRepository")),
            source_commit=text(payload.get("sourceCommit")),
            app_version=text(payload.get("appVersion")),
            toolchain_version=text(payload.get("toolchainVersion")),
            run_id=text(payload.get("runID")),
            run_attempt=text(payload.get("runAttempt")),
            builder_environment=text(build_authority.get("environment")),
            xcode_version=text(build_authority.get("xcodeVersion")),
            xcode_build=text(build_authority.get("xcodeBuild")),
            macos_sdk_version=text(build_authority.get("macOSSDKVersion")),
        )
        expected = validate_metadata(manifest_authority)
        for key, requested in (
            ("sourceCommit", args.source_commit),
            ("appVersion", args.app_version),
            ("toolchainVersion", args.toolchain_version),
        ):
            if payload.get(key) != requested:
                fail(f"prepared release {key} does not match the requested authority")
    else:
        if any(getattr(args, name) is None for name in authority_fields):
            fail("prepared release verification requires complete authority metadata")
        expected = validate_metadata(args)
    for key, value in expected.items():
        if payload.get(key) != value:
            fail(f"prepared release {key} does not match the requested authority")
    if set(payload) != set(expected) | {"entries", "subjects"}:
        fail("prepared release manifest contains unexpected fields")
    rows = payload.get("entries")
    actual_rows = closure_rows(root)
    if not isinstance(rows, list) or rows != actual_rows:
        fail("prepared release closure changed after preparation")
    if payload.get("subjects") != subject_digests(actual_rows):
        fail("prepared release subject digests changed after preparation")


def canonical_archive(raw: Path) -> tuple[Path, os.stat_result]:
    if not raw.is_absolute() or os.path.normpath(os.fspath(raw)) != os.fspath(raw):
        fail("prepared archive must be an absolute normalized path")
    resolved = raw.resolve(strict=True)
    if resolved != raw:
        fail("prepared archive must contain no symlink ancestry")
    metadata = raw.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > MAX_ARCHIVE_BYTES
    ):
        fail("prepared archive must be a bounded single-link regular file")
    return resolved, metadata


def canonical_new_destination(raw: Path) -> Path:
    if not raw.is_absolute() or os.path.normpath(os.fspath(raw)) != os.fspath(raw):
        fail("extraction destination must be an absolute normalized path")
    if os.path.lexists(raw):
        fail("extraction destination must not already exist")
    parent = raw.parent.resolve(strict=True)
    if parent != raw.parent:
        fail("extraction destination must contain no symlink ancestry")
    metadata = parent.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail("extraction parent must be owned and not group/world writable")
    return raw


def extract(args: argparse.Namespace) -> None:
    archive_path, archive_before = canonical_archive(args.archive)
    destination = canonical_new_destination(args.destination)
    descriptor = os.open(archive_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    created = False
    try:
        opened = os.fstat(descriptor)
        identity = (
            archive_before.st_dev,
            archive_before.st_ino,
            archive_before.st_size,
            archive_before.st_mtime_ns,
            archive_before.st_ctime_ns,
        )
        if (
            opened.st_dev,
            opened.st_ino,
            opened.st_size,
            opened.st_mtime_ns,
            opened.st_ctime_ns,
        ) != identity:
            fail("prepared archive changed before extraction")
        os.mkdir(destination, 0o700)
        created = True
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            with tarfile.open(fileobj=source, mode="r:") as archive:
                members = archive.getmembers()
                if not members or len(members) > MAX_FILES:
                    fail("prepared archive has an invalid entry count")
                by_name: dict[str, tarfile.TarInfo] = {}
                folded: set[str] = set()
                total = 0
                for member in members:
                    pure = PurePosixPath(member.name)
                    if (
                        pure.is_absolute()
                        or not pure.parts
                        or pure.parts[0] != "easysplat-prepared-release"
                        or any(part in {"", ".", ".."} for part in pure.parts)
                        or unicodedata.normalize("NFC", member.name) != member.name
                        or any(
                            ord(character) < 0x20 or ord(character) == 0x7F
                            for character in member.name
                        )
                        or member.name in by_name
                        or member.name.casefold() in folded
                        or not (member.isdir() or member.isfile())
                    ):
                        fail(f"unsafe prepared archive entry: {member.name}")
                    by_name[member.name] = member
                    folded.add(member.name.casefold())
                    total += member.size
                    if total > MAX_TOTAL_BYTES:
                        fail("prepared archive exceeds the total byte bound")
                root_member = by_name.get("easysplat-prepared-release")
                if root_member is None or not root_member.isdir():
                    fail("prepared archive has no unique root directory")
                for name, member in by_name.items():
                    if name == "easysplat-prepared-release":
                        continue
                    parent = PurePosixPath(name).parent.as_posix()
                    parent_member = by_name.get(parent)
                    if parent_member is None or not parent_member.isdir():
                        fail(f"prepared archive omits a parent directory: {name}")

                directories: list[tuple[Path, int]] = []
                for member in sorted(
                    members,
                    key=lambda row: (len(PurePosixPath(row.name).parts), row.name),
                ):
                    target = destination.joinpath(*PurePosixPath(member.name).parts)
                    if member.isdir():
                        target.mkdir(mode=0o700, parents=False, exist_ok=False)
                        directories.append((target, member.mode & 0o777))
                        continue
                    source_file = archive.extractfile(member)
                    if source_file is None:
                        fail(f"cannot read prepared archive entry: {member.name}")
                    output = os.open(
                        target,
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | os.O_CLOEXEC
                        | os.O_NOFOLLOW,
                        member.mode & 0o777,
                    )
                    try:
                        with os.fdopen(output, "wb", closefd=False) as handle:
                            shutil.copyfileobj(source_file, handle, 1024 * 1024)
                            handle.flush()
                            os.fsync(handle.fileno())
                    finally:
                        os.close(output)
                    os.chmod(target, member.mode & 0o777)
                for directory, mode in reversed(directories):
                    os.chmod(directory, mode)
        after = os.fstat(descriptor)
        rebound = archive_path.lstat()
        if (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ) != identity or (
            rebound.st_dev,
            rebound.st_ino,
            rebound.st_size,
            rebound.st_mtime_ns,
            rebound.st_ctime_ns,
        ) != identity:
            fail("prepared archive changed during extraction")
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot extract prepared archive: {error}")
    finally:
        os.close(descriptor)
        if created and sys.exc_info()[0] is not None:
            shutil.rmtree(destination, ignore_errors=True)


def add_authority_arguments(
    parser: argparse.ArgumentParser,
    *,
    required: bool = True,
) -> None:
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source-repository", required=required)
    parser.add_argument("--source-commit", required=required)
    parser.add_argument("--app-version", required=required)
    parser.add_argument("--toolchain-version", required=required)
    parser.add_argument("--run-id", required=required)
    parser.add_argument("--run-attempt", required=required)
    parser.add_argument("--builder-environment", required=required)
    parser.add_argument("--xcode-version", required=required)
    parser.add_argument("--xcode-build", required=required)
    parser.add_argument("--macos-sdk-version", required=required)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    add_authority_arguments(commands.add_parser("create"))
    verify_parser = commands.add_parser("verify")
    add_authority_arguments(verify_parser, required=False)
    verify_parser.add_argument("--authority-from-manifest", action="store_true")
    verify_parser.add_argument("--expected-manifest-sha256")
    extract_parser = commands.add_parser("extract")
    extract_parser.add_argument("--archive", type=Path, required=True)
    extract_parser.add_argument("--destination", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    try:
        args = parse_args()
        {"create": create, "verify": verify, "extract": extract}[args.command](args)
    except PreparedReleaseError as error:
        print(f"prepared release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
