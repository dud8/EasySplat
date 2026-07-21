#!/usr/bin/env python3
"""Extract a single-root source archive without following archive-created links."""

from __future__ import annotations

import os
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, Tuple


class ExtractionError(ValueError):
    pass


MemberPath = Tuple[str, ...]


def member_path(name: str) -> MemberPath:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise ExtractionError(f"archive path escapes extraction root: {name}")
    parts = tuple(part for part in path.parts if part not in ("", "."))
    if not parts:
        raise ExtractionError(f"archive path is empty: {name}")
    return parts


def resolve_link_path(parent: MemberPath, raw_target: str) -> MemberPath:
    target = PurePosixPath(raw_target)
    if target.is_absolute():
        raise ExtractionError(f"archive link escapes extraction root: {raw_target}")
    resolved = list(parent)
    for part in target.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise ExtractionError(
                    f"archive link escapes extraction root: {raw_target}"
                )
            resolved.pop()
        else:
            resolved.append(part)
    if not resolved:
        raise ExtractionError(f"archive link escapes extraction root: {raw_target}")
    return tuple(resolved)


def regular_parent(path: Path, extraction_root: Path) -> None:
    current = extraction_root
    for part in path.relative_to(extraction_root).parts[:-1]:
        current = current / part
        if current.is_symlink() or not current.is_dir():
            raise ExtractionError(f"archive parent is not a regular directory: {path}")


def validate_members(
    members: Iterable[tarfile.TarInfo],
) -> tuple[Dict[MemberPath, tarfile.TarInfo], MemberPath]:
    by_path: Dict[MemberPath, tarfile.TarInfo] = {}
    for member in members:
        path = member_path(member.name)
        if path in by_path:
            raise ExtractionError(f"archive contains a duplicate path: {member.name}")
        if member.islnk():
            raise ExtractionError(f"archive contains a hard link: {member.name}")
        if not (member.isdir() or member.isfile() or member.issym()):
            raise ExtractionError(f"archive contains a special file: {member.name}")
        by_path[path] = member

    roots = {path[0] for path in by_path}
    if len(roots) != 1:
        raise ExtractionError("source archive must contain one root directory")
    root_path = (next(iter(roots)),)
    root_member = by_path.get(root_path)
    if root_member is None or not root_member.isdir():
        raise ExtractionError("source archive root must be a regular directory")

    symlink_paths = {path for path, member in by_path.items() if member.issym()}
    for path in by_path:
        for length in range(1, len(path)):
            if path[:length] in symlink_paths:
                raise ExtractionError(
                    f"archive member descends through a symlink: {'/'.join(path)}"
                )

    def final_link_target(path: MemberPath, visited: set[MemberPath]) -> MemberPath:
        if path in visited:
            raise ExtractionError(f"archive contains a symlink cycle: {'/'.join(path)}")
        member = by_path.get(path)
        if member is None:
            raise ExtractionError(f"archive contains a dangling symlink: {'/'.join(path)}")
        if not member.issym():
            return path
        target = resolve_link_path(path[:-1], member.linkname)
        return final_link_target(target, visited | {path})

    for path in symlink_paths:
        target = final_link_target(path, set())
        if target[0] != root_path[0]:
            raise ExtractionError(
                f"archive link escapes extraction root: {'/'.join(path)}"
            )

    return by_path, root_path


def regular_files_in_archive_order(
    by_path: Dict[MemberPath, tarfile.TarInfo],
) -> list[tuple[MemberPath, tarfile.TarInfo]]:
    # Compressed tar streams must move forward; lexical sorting can repeatedly
    # rewind and decompress a large source archive.
    return [(path, member) for path, member in by_path.items() if member.isfile()]


def extract(archive_path: Path, destination: Path) -> Path:
    if destination.is_symlink() or not destination.is_dir():
        raise ExtractionError("extraction destination must be a regular directory")
    if any(destination.iterdir()):
        raise ExtractionError("extraction destination must be empty")
    extraction_root = destination.resolve(strict=True)

    with tarfile.open(archive_path, mode="r:*") as archive:
        members = archive.getmembers()
        if not members:
            raise ExtractionError("source archive is empty")
        by_path, root_path = validate_members(members)

        directories = sorted(
            (item for item in by_path.items() if item[1].isdir()),
            key=lambda item: (len(item[0]), item[0]),
        )
        for parts, member in directories:
            target = extraction_root.joinpath(*parts)
            regular_parent(target, extraction_root)
            target.mkdir(mode=(member.mode & 0o755) | 0o700)

        files = regular_files_in_archive_order(by_path)
        for parts, member in files:
            target = extraction_root.joinpath(*parts)
            regular_parent(target, extraction_root)
            source = archive.extractfile(member)
            if source is None:
                raise ExtractionError(f"archive file has no payload: {member.name}")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(target, flags, (member.mode & 0o755) | 0o600)
            with source, os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)

        links = sorted(
            (item for item in by_path.items() if item[1].issym()),
            key=lambda item: item[0],
        )
        for parts, member in links:
            target = extraction_root.joinpath(*parts)
            regular_parent(target, extraction_root)
            os.symlink(member.linkname, target)

        for parts, member in links:
            target = extraction_root.joinpath(*parts)
            if not target.exists():
                raise ExtractionError(f"archive contains a dangling symlink: {member.name}")

    root = extraction_root.joinpath(*root_path)
    if root.is_symlink() or not root.is_dir():
        raise ExtractionError("source archive root must be a regular directory")
    return root


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: safe_extract_source.py <archive> <empty-destination>", file=sys.stderr)
        return 2
    try:
        root = extract(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ExtractionError, OSError, tarfile.TarError) as error:
        print(f"safe extraction failed: {error}", file=sys.stderr)
        return 1
    print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
