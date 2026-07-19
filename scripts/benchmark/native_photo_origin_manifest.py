#!/usr/bin/env python3
"""Create a private, content-bound origin receipt for native photo folders."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SUPPORTED_STILL_EXTENSIONS = frozenset(
    {
        ".arw",
        ".cr2",
        ".cr3",
        ".dng",
        ".heic",
        ".heif",
        ".jpg",
        ".jpeg",
        ".nef",
        ".orf",
        ".png",
        ".raf",
        ".rw2",
        ".tif",
        ".tiff",
    }
)
MAXIMUM_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAXIMUM_CLOSURE_BYTES = 64 * 1024 * 1024 * 1024
MAXIMUM_TREE_ENTRIES = 100_000
MAXIMUM_RECURSION_DEPTH = 64


class OriginManifestError(RuntimeError):
    pass


@dataclass(frozen=True)
class _Metadata:
    device: int
    inode: int
    mode: int
    size: int
    mtime_ns: int
    ctime_ns: int
    link_count: int

    @classmethod
    def from_stat(cls, value: os.stat_result) -> _Metadata:
        return cls(
            device=value.st_dev,
            inode=value.st_ino,
            mode=value.st_mode,
            size=value.st_size,
            mtime_ns=value.st_mtime_ns,
            ctime_ns=value.st_ctime_ns,
            link_count=value.st_nlink,
        )


@dataclass(frozen=True)
class _Photo:
    relative_path_bytes: bytes
    source_sha256: str
    metadata: _Metadata


@dataclass(frozen=True)
class _Directory:
    relative_path_bytes: bytes
    metadata: _Metadata


@dataclass(frozen=True)
class _TreeSnapshot:
    root_metadata: _Metadata
    photos: tuple[_Photo, ...]
    directories: tuple[_Directory, ...]


def _scan_directory_unpatched(descriptor: int) -> Iterable[os.DirEntry[str]]:
    return os.scandir(descriptor)


def _scan_directory(descriptor: int) -> Iterable[os.DirEntry[str]]:
    return _scan_directory_unpatched(descriptor)


def _reject_symlink_ancestors(path: Path, label: str) -> None:
    absolute = Path(os.path.abspath(os.fspath(path)))
    ancestors = list(absolute.parents)
    for ancestor in reversed(ancestors[:-1]):
        try:
            metadata = os.lstat(ancestor)
        except OSError as error:
            raise OriginManifestError(f"{label} is unavailable") from error
        if stat.S_ISLNK(metadata.st_mode):
            parent_metadata = os.lstat(ancestor.parent)
            immutable_system_alias = (
                metadata.st_uid == 0
                and parent_metadata.st_uid == 0
                and stat.S_IMODE(parent_metadata.st_mode) & 0o022 == 0
            )
            if not immutable_system_alias:
                raise OriginManifestError(f"{label} contains a symlink component")


def _plain_directory(path: Path, label: str) -> os.stat_result:
    _reject_symlink_ancestors(path, label)
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise OriginManifestError(f"{label} is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise OriginManifestError(f"{label} must be a plain directory")
    return metadata


def _open_directory(path: Path, label: str) -> int:
    _plain_directory(path, label)
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise OriginManifestError(f"{label} is unavailable") from error
    opened = os.fstat(descriptor)
    current = os.lstat(path)
    if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        os.close(descriptor)
        raise OriginManifestError("source tree changed during inventory")
    return descriptor


def _hash_descriptor(descriptor: int) -> tuple[str, int]:
    hasher = hashlib.sha256()
    byte_count = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        byte_count += len(chunk)
        if byte_count > MAXIMUM_FILE_BYTES:
            raise OriginManifestError("native photo exceeds the supported size")
        hasher.update(chunk)
    return "sha256:" + hasher.hexdigest(), byte_count


def _capture_source_tree(source_root: Path) -> _TreeSnapshot:
    root_descriptor = _open_directory(source_root, "source root")
    root_metadata = _Metadata.from_stat(os.fstat(root_descriptor))
    photos: list[_Photo] = []
    directories: list[_Directory] = []
    total_bytes = 0
    visited_entries = 0
    seen_content: set[str] = set()

    def walk(descriptor: int, relative_parts: tuple[bytes, ...]) -> None:
        nonlocal total_bytes, visited_entries
        if len(relative_parts) > MAXIMUM_RECURSION_DEPTH:
            raise OriginManifestError("source tree exceeds the supported depth")
        directory_before = _Metadata.from_stat(os.fstat(descriptor))
        try:
            children = sorted(
                list(_scan_directory(descriptor)),
                key=lambda child: os.fsencode(child.name),
            )
        except OSError as error:
            raise OriginManifestError("source directory could not be read") from error
        for child in children:
            visited_entries += 1
            if visited_entries > MAXIMUM_TREE_ENTRIES:
                raise OriginManifestError("source tree is too large")
            name_bytes = os.fsencode(child.name)
            if name_bytes in {b".", b".."} or b"/" in name_bytes or b"\0" in name_bytes:
                raise OriginManifestError("source entry name is unsafe")
            try:
                before_stat = child.stat(follow_symlinks=False)
            except OSError as error:
                raise OriginManifestError(
                    "source tree changed during inventory"
                ) from error
            before = _Metadata.from_stat(before_stat)
            relative = (*relative_parts, name_bytes)
            relative_bytes = b"/".join(relative)
            if stat.S_ISLNK(before.mode):
                raise OriginManifestError("source tree contains a symlink")
            if stat.S_ISDIR(before.mode):
                try:
                    child_descriptor = os.open(
                        child.name,
                        os.O_RDONLY
                        | os.O_CLOEXEC
                        | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    raise OriginManifestError(
                        "source tree changed during inventory"
                    ) from error
                try:
                    if _Metadata.from_stat(os.fstat(child_descriptor)) != before:
                        raise OriginManifestError(
                            "source tree changed during inventory"
                        )
                    directories.append(_Directory(relative_bytes, before))
                    walk(child_descriptor, relative)
                finally:
                    os.close(child_descriptor)
            elif stat.S_ISREG(before.mode):
                if before.link_count != 1:
                    raise OriginManifestError("source tree contains a hardlink")
                suffix = os.path.splitext(child.name)[1].lower()
                if suffix not in SUPPORTED_STILL_EXTENSIONS:
                    continue
                if before.size > MAXIMUM_FILE_BYTES:
                    raise OriginManifestError("native photo exceeds the supported size")
                try:
                    file_descriptor = os.open(
                        child.name,
                        os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=descriptor,
                    )
                except OSError as error:
                    raise OriginManifestError(
                        "source tree changed during inventory"
                    ) from error
                try:
                    opened = _Metadata.from_stat(os.fstat(file_descriptor))
                    if opened != before or not stat.S_ISREG(opened.mode):
                        raise OriginManifestError(
                            "source tree changed during inventory"
                        )
                    source_sha256, byte_count = _hash_descriptor(file_descriptor)
                    after_hash = _Metadata.from_stat(os.fstat(file_descriptor))
                    if after_hash != opened or byte_count != opened.size:
                        raise OriginManifestError(
                            "source tree changed during inventory"
                        )
                finally:
                    os.close(file_descriptor)
                try:
                    after = _Metadata.from_stat(
                        os.stat(
                            child.name,
                            dir_fd=descriptor,
                            follow_symlinks=False,
                        )
                    )
                except OSError as error:
                    raise OriginManifestError(
                        "source tree changed during inventory"
                    ) from error
                if after != before:
                    raise OriginManifestError("source tree changed during inventory")
                if source_sha256 in seen_content:
                    raise OriginManifestError("source tree contains duplicate content")
                seen_content.add(source_sha256)
                total_bytes += byte_count
                if total_bytes > MAXIMUM_CLOSURE_BYTES:
                    raise OriginManifestError("source closure is too large")
                photos.append(_Photo(relative_bytes, source_sha256, before))
            else:
                raise OriginManifestError("source tree contains a special file")
        if _Metadata.from_stat(os.fstat(descriptor)) != directory_before:
            raise OriginManifestError("source tree changed during inventory")

    try:
        walk(root_descriptor, ())
        if _Metadata.from_stat(os.fstat(root_descriptor)) != root_metadata:
            raise OriginManifestError("source tree changed during inventory")
    finally:
        os.close(root_descriptor)
    if not photos:
        raise OriginManifestError("source tree contains no supported still photos")
    return _TreeSnapshot(
        root_metadata=root_metadata,
        photos=tuple(sorted(photos, key=lambda photo: photo.relative_path_bytes)),
        directories=tuple(
            sorted(directories, key=lambda directory: directory.relative_path_bytes)
        ),
    )


def _attest_source_tree(source_root: Path, expected: _TreeSnapshot) -> None:
    if _capture_source_tree(source_root) != expected:
        raise OriginManifestError("source tree changed before publication")


def _manifest(snapshot: _TreeSnapshot) -> dict[str, object]:
    return {
        "schema_version": 1,
        "sources": [
            {"kind": "native_photo", "source_sha256": source_sha256}
            for source_sha256 in sorted(
                photo.source_sha256 for photo in snapshot.photos
            )
        ],
    }


def _canonical_bytes(value: dict[str, object]) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def build_manifest(source_root: Path) -> dict[str, object]:
    snapshot = _capture_source_tree(source_root)
    manifest = _manifest(snapshot)
    _attest_source_tree(source_root, snapshot)
    return manifest


def _output_location(
    source_root: Path, output: Path
) -> tuple[Path, str, int, _Metadata]:
    if output.name in {"", ".", ".."} or output.parent == output:
        raise OriginManifestError("output path is invalid")
    parent = output.parent
    parent_stat = _plain_directory(parent, "output parent")
    if (
        parent_stat.st_uid != os.geteuid()
        or stat.S_IMODE(parent_stat.st_mode) & 0o022 != 0
    ):
        raise OriginManifestError(
            "output parent must be owned by the current user and private"
        )
    try:
        source_resolved = source_root.resolve(strict=True)
        parent_resolved = parent.resolve(strict=True)
    except OSError as error:
        raise OriginManifestError("output parent is unavailable") from error
    if parent_resolved == source_resolved or source_resolved in parent_resolved.parents:
        raise OriginManifestError("output must be outside source tree")
    parent_descriptor = _open_directory(parent, "output parent")
    return (
        parent,
        output.name,
        parent_descriptor,
        _Metadata.from_stat(os.fstat(parent_descriptor)),
    )


def _require_same_output_parent(
    parent: Path,
    descriptor: int,
    expected: _Metadata,
) -> None:
    try:
        path_metadata = _Metadata.from_stat(os.lstat(parent))
    except OSError as error:
        raise OriginManifestError("output parent changed before publication") from error
    descriptor_metadata = _Metadata.from_stat(os.fstat(descriptor))
    expected_identity = (expected.device, expected.inode, expected.mode)
    if (
        path_metadata.device,
        path_metadata.inode,
        path_metadata.mode,
    ) != expected_identity or (
        descriptor_metadata.device,
        descriptor_metadata.inode,
        descriptor_metadata.mode,
    ) != expected_identity:
        raise OriginManifestError("output parent changed before publication")


def _same_inode(metadata: os.stat_result, expected: _Metadata) -> bool:
    return (
        metadata.st_dev == expected.device
        and metadata.st_ino == expected.inode
        and stat.S_IFMT(metadata.st_mode) == stat.S_IFMT(expected.mode)
    )


def _stat_entry(descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _rollback_owned_final(
    parent_descriptor: int,
    transaction_descriptor: int,
    leaf: str,
    expected: _Metadata,
) -> None:
    visible = _stat_entry(parent_descriptor, leaf)
    if visible is None or not _same_inode(visible, expected):
        return
    quarantine = ".rollback-" + secrets.token_hex(16)
    try:
        os.rename(
            leaf,
            quarantine,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=transaction_descriptor,
        )
    except FileNotFoundError:
        return
    moved = _stat_entry(transaction_descriptor, quarantine)
    if moved is not None and _same_inode(moved, expected):
        os.unlink(quarantine, dir_fd=transaction_descriptor)
        os.fsync(transaction_descriptor)
        os.fsync(parent_descriptor)
        return


def _open_and_verify_final(
    parent_descriptor: int,
    leaf: str,
    expected: _Metadata,
    expected_data: bytes,
) -> int:
    try:
        descriptor = os.open(
            leaf,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
    except OSError as error:
        raise OriginManifestError("final output changed after publication") from error
    try:
        opened = os.fstat(descriptor)
        expected_digest = "sha256:" + hashlib.sha256(expected_data).hexdigest()
        if (
            not _same_inode(opened, expected)
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_size != len(expected_data)
        ):
            raise OriginManifestError("final output changed after publication")
        actual_digest, actual_size = _hash_descriptor(descriptor)
        after_hash = os.fstat(descriptor)
        path_after = _stat_entry(parent_descriptor, leaf)
        if (
            actual_digest != expected_digest
            or actual_size != len(expected_data)
            or _Metadata.from_stat(after_hash) != _Metadata.from_stat(opened)
            or path_after is None
            or not _same_inode(path_after, expected)
            or stat.S_IMODE(path_after.st_mode) != 0o600
            or path_after.st_size != len(expected_data)
        ):
            raise OriginManifestError("final output changed after publication")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _cleanup_owned_transaction(
    parent_descriptor: int,
    transaction_descriptor: int,
    transaction_leaf: str,
    transaction_metadata: _Metadata,
    manifest_metadata: _Metadata | None,
) -> None:
    if manifest_metadata is None:
        return
    manifest = _stat_entry(transaction_descriptor, "manifest")
    if manifest is None or not _same_inode(manifest, manifest_metadata):
        return
    quarantine = ".cleanup-" + secrets.token_hex(16)
    try:
        os.rename(
            "manifest",
            quarantine,
            src_dir_fd=transaction_descriptor,
            dst_dir_fd=transaction_descriptor,
        )
    except OSError:
        return
    moved_manifest = _stat_entry(transaction_descriptor, quarantine)
    if moved_manifest is None or not _same_inode(moved_manifest, manifest_metadata):
        return
    try:
        os.unlink(quarantine, dir_fd=transaction_descriptor)
    except OSError:
        return
    transaction_at_name = _stat_entry(parent_descriptor, transaction_leaf)
    if transaction_at_name is None or not _same_inode(
        transaction_at_name, transaction_metadata
    ):
        return
    directory_quarantine = ".cleanup-dir-" + secrets.token_hex(16)
    try:
        os.rename(
            transaction_leaf,
            directory_quarantine,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
    except OSError:
        return
    moved_directory = _stat_entry(parent_descriptor, directory_quarantine)
    if moved_directory is None or not _same_inode(
        moved_directory, transaction_metadata
    ):
        return
    try:
        os.rmdir(directory_quarantine, dir_fd=parent_descriptor)
    except OSError:
        return


def _publish_exclusive(
    parent: Path,
    leaf: str,
    data: bytes,
    *,
    parent_descriptor: int,
    parent_metadata: _Metadata,
) -> None:
    transaction_leaf = ".native-photo-origin-" + secrets.token_hex(16)
    transaction_descriptor: int | None = None
    file_descriptor: int | None = None
    transaction_metadata: _Metadata | None = None
    manifest_metadata: _Metadata | None = None
    final_descriptor: int | None = None
    try:
        _require_same_output_parent(parent, parent_descriptor, parent_metadata)
        try:
            os.mkdir(transaction_leaf, mode=0o700, dir_fd=parent_descriptor)
        except OSError as error:
            raise OriginManifestError("could not create output transaction") from error
        transaction_descriptor = os.open(
            transaction_leaf,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        transaction_metadata = _Metadata.from_stat(os.fstat(transaction_descriptor))
        file_descriptor = os.open(
            "manifest",
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=transaction_descriptor,
        )
        view = memoryview(data)
        while view:
            written = os.write(file_descriptor, view)
            if written <= 0:
                raise OriginManifestError("manifest write made no progress")
            view = view[written:]
        os.fsync(file_descriptor)
        manifest_metadata = _Metadata.from_stat(os.fstat(file_descriptor))
        os.close(file_descriptor)
        file_descriptor = None
        os.fsync(transaction_descriptor)
        os.fsync(parent_descriptor)
        _require_same_output_parent(parent, parent_descriptor, parent_metadata)
        try:
            os.link(
                "manifest",
                leaf,
                src_dir_fd=transaction_descriptor,
                dst_dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            raise OriginManifestError("output already exists") from error
        except OSError as error:
            raise OriginManifestError("manifest publication failed") from error
        try:
            os.fsync(parent_descriptor)
            assert manifest_metadata is not None
            final_descriptor = _open_and_verify_final(
                parent_descriptor,
                leaf,
                manifest_metadata,
                data,
            )
        except BaseException:
            assert manifest_metadata is not None
            _rollback_owned_final(
                parent_descriptor,
                transaction_descriptor,
                leaf,
                manifest_metadata,
            )
            raise
    finally:
        if file_descriptor is not None:
            os.close(file_descriptor)
        if transaction_descriptor is not None and transaction_metadata is not None:
            _cleanup_owned_transaction(
                parent_descriptor,
                transaction_descriptor,
                transaction_leaf,
                transaction_metadata,
                manifest_metadata,
            )
            os.close(transaction_descriptor)
        if final_descriptor is not None:
            os.close(final_descriptor)


def generate(source_root: Path, output: Path) -> dict[str, object]:
    parent, leaf, parent_descriptor, parent_metadata = _output_location(
        source_root, output
    )
    try:
        snapshot = _capture_source_tree(source_root)
        manifest = _manifest(snapshot)
        data = _canonical_bytes(manifest)
        _attest_source_tree(source_root, snapshot)
        _publish_exclusive(
            parent,
            leaf,
            data,
            parent_descriptor=parent_descriptor,
            parent_metadata=parent_metadata,
        )
    finally:
        os.close(parent_descriptor)
    return {
        "schema_version": 1,
        "source_count": len(snapshot.photos),
        "manifest_sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Create a private native-photo origin manifest."
    )
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        summary = generate(arguments.source_root, arguments.output)
    except OriginManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
