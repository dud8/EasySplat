#!/usr/bin/env python3
"""Create a release ZIP with canonical ordering and metadata."""

from __future__ import annotations

import argparse
import os
import stat
import sys
import tempfile
import unicodedata
import zipfile
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
COMPRESSION_LEVEL = 9
COPY_BUFFER_BYTES = 1024 * 1024


class ArchiveError(Exception):
    pass


def validate_relative_path(raw_path: str) -> Tuple[str, ...]:
    parts = tuple(raw_path.split("/"))
    if (
        not raw_path
        or raw_path.startswith("/")
        or "\\" in raw_path
        or any(part in ("", ".", "..") for part in parts)
    ):
        raise ArchiveError(
            f"archive input must be a normalized relative path: {raw_path!r}"
        )
    validate_archive_name(raw_path)
    return parts


def validate_archive_name(name: str) -> None:
    if "\\" in name:
        raise ArchiveError(f"archive path contains a backslash: {name!r}")
    if any(unicodedata.category(character) == "Cs" for character in name):
        raise ArchiveError(f"archive path contains a surrogate code point: {name!r}")
    if any(unicodedata.category(character) == "Cc" for character in name):
        raise ArchiveError(f"archive path contains a control character: {name!r}")
    if unicodedata.normalize("NFC", name) != name:
        raise ArchiveError(f"archive path is not NFC-normalized: {name!r}")


def selected_paths(root: Path, raw_paths: Sequence[str]) -> List[Tuple[Path, str]]:
    selections: List[Tuple[Path, str]] = []
    for raw_path in raw_paths:
        parts = validate_relative_path(raw_path)
        selections.append((root.joinpath(*parts), raw_path))
    return selections


def output_overlaps_selection(output: Path, selection: Path) -> bool:
    return output == selection or selection in output.parents


def collect_files(
    root: Path,
    selections: Sequence[Tuple[Path, str]],
) -> List[Tuple[str, Path, os.stat_result]]:
    files: Dict[str, Tuple[Path, os.stat_result]] = {}

    def visit(path: Path) -> None:
        relative = path.relative_to(root).as_posix()
        validate_archive_name(relative)
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError as error:
            raise ArchiveError(f"archive input does not exist: {relative}") from error
        if resolved != path:
            raise ArchiveError(
                f"archive input traverses a symlink or non-canonical path: {relative}"
            )
        try:
            resolved.relative_to(root)
        except ValueError as error:
            raise ArchiveError(
                f"archive input resolves outside its root: {relative}"
            ) from error
        try:
            metadata = path.lstat()
        except FileNotFoundError as error:
            raise ArchiveError(f"archive input does not exist: {path}") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise ArchiveError(f"archive input contains a symlink: {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            for child in path.iterdir():
                visit(child)
            return
        if not stat.S_ISREG(metadata.st_mode):
            raise ArchiveError(
                f"archive input has an unsupported file type: {relative}"
            )
        if relative in files:
            raise ArchiveError(f"archive input contains a duplicate file: {relative}")
        files[relative] = (path, metadata)

    for path, raw_path in selections:
        if not path.exists() and not path.is_symlink():
            raise ArchiveError(f"archive input does not exist: {raw_path}")
        visit(path)
    if not files:
        raise ArchiveError("archive input contains no regular files")
    return [
        (relative, *files[relative])
        for relative in sorted(files, key=lambda value: value.encode("utf-8"))
    ]


def normalized_mode(metadata: os.stat_result) -> int:
    return 0o755 if metadata.st_mode & 0o111 else 0o644


def zip_info(relative: str, metadata: os.stat_result) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(relative, date_time=FIXED_TIMESTAMP)
    info.create_system = 3
    info.create_version = 20
    info.extract_version = 20
    info.compress_type = zipfile.ZIP_DEFLATED
    info.comment = b""
    info.extra = b""
    info.internal_attr = 0
    info.external_attr = (stat.S_IFREG | normalized_mode(metadata)) << 16
    info.file_size = metadata.st_size
    return info


def copy_regular_file(
    source: Path,
    expected: os.stat_result,
    destination,
) -> None:
    def stable_metadata(
        metadata: os.stat_result,
    ) -> Tuple[int, int, int, int, int, int]:
        return (
            metadata.st_mode,
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(source, flags)
    try:
        actual = os.fstat(descriptor)
        if not stat.S_ISREG(actual.st_mode) or stable_metadata(
            actual
        ) != stable_metadata(expected):
            raise ArchiveError(f"archive input changed while being read: {source}")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            remaining = expected.st_size
            while remaining:
                block = handle.read(min(COPY_BUFFER_BYTES, remaining))
                if not block:
                    raise ArchiveError(
                        f"archive input changed while being read: {source}"
                    )
                destination.write(block)
                remaining -= len(block)
            if handle.read(1):
                raise ArchiveError(f"archive input changed while being read: {source}")
        if stable_metadata(os.fstat(descriptor)) != stable_metadata(expected):
            raise ArchiveError(f"archive input changed while being read: {source}")
    finally:
        os.close(descriptor)


def write_archive(
    output: Path,
    files: Sequence[Tuple[str, Path, os.stat_result]],
) -> None:
    output_parent = output.parent
    if output_parent.is_symlink() or not output_parent.is_dir():
        raise ArchiveError(
            f"archive output parent is not a regular directory: {output_parent}"
        )
    if os.path.lexists(output):
        metadata = output.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise ArchiveError(f"archive output is not a regular file: {output}")

    descriptor, temporary_name = tempfile.mkstemp(
        dir=output_parent,
        prefix=f".{output.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w+b") as handle:
            with zipfile.ZipFile(
                handle,
                mode="w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=COMPRESSION_LEVEL,
                allowZip64=True,
                strict_timestamps=True,
            ) as archive:
                archive.comment = b""
                for relative, source, metadata in files:
                    with archive.open(zip_info(relative, metadata), mode="w") as member:
                        copy_regular_file(source, metadata, member)
            os.fchmod(handle.fileno(), 0o644)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
        directory_descriptor = os.open(output_parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def create_archive(
    root_argument: str, output_argument: str, paths: Sequence[str]
) -> None:
    root_path = Path(root_argument)
    if root_path.is_symlink() or not root_path.is_dir():
        raise ArchiveError(f"archive root is not a regular directory: {root_path}")
    root = root_path.resolve(strict=True)

    output_path = Path(output_argument)
    validate_archive_name(output_path.name)
    output_parent = output_path.parent.resolve(strict=True)
    output = output_parent / output_path.name
    selections = selected_paths(root, paths)
    for selection, raw_path in selections:
        if output_overlaps_selection(output, selection):
            raise ArchiveError(f"archive output overlaps selected input: {raw_path}")

    files = collect_files(root, selections)
    write_archive(output, files)


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--path", action="append", required=True, dest="paths")
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    options = parse_args(arguments)
    try:
        create_archive(options.root, options.output, options.paths)
    except (ArchiveError, OSError, zipfile.BadZipFile) as error:
        print(f"Cannot create release archive: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
