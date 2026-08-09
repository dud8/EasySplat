#!/usr/bin/env python3
"""Materialize the exact reviewed Git tree used by a release build."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import unicodedata
from pathlib import Path


GIT = "/usr/bin/git"
TAR = "/usr/bin/tar"
SAFE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
ALLOWED_BLOB_MODES = {"100644", "100755"}


class SourceExportError(RuntimeError):
    """The requested source cannot be bound to one reviewed Git tree."""


def _fail(message: str) -> None:
    raise SourceExportError(message)


def _git_environment() -> dict[str, str]:
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": "/var/empty",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": SAFE_PATH,
    }


def _git(
    repository: Path, arguments: list[str], *, binary: bool = False
) -> bytes | str:
    result = subprocess.run(
        [GIT, "-C", os.fspath(repository), *arguments],
        check=False,
        capture_output=True,
        env=_git_environment(),
        text=not binary,
    )
    if result.returncode != 0:
        _fail("Could not resolve the reviewed Git source.")
    if binary:
        assert isinstance(result.stdout, bytes)
        return result.stdout
    assert isinstance(result.stdout, str)
    return result.stdout.strip()


def _canonical_existing_directory(path: Path, label: str) -> Path:
    raw = os.fspath(path)
    if not os.path.isabs(raw) or os.path.normpath(raw) != raw:
        _fail(f"{label} path must be absolute and normalized.")
    if os.path.realpath(raw) != raw:
        _fail(f"{label} path must contain no symlink ancestry.")
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        _fail(f"{label} does not exist.")
    if not stat.S_ISDIR(metadata.st_mode):
        _fail(f"{label} must be a directory.")
    if metadata.st_uid != os.geteuid():
        _fail(f"{label} must be owned by the current user.")
    return path


def _validate_output(path: Path) -> Path:
    raw = os.fspath(path)
    if not os.path.isabs(raw) or os.path.normpath(raw) != raw:
        _fail("Source export path must be absolute and normalized.")
    parent = _canonical_existing_directory(path.parent, "Source export parent")
    parent_mode = stat.S_IMODE(os.lstat(parent).st_mode)
    if parent_mode & 0o022:
        _fail("Source export parent must not be group- or world-writable.")
    if os.path.lexists(path):
        _fail("Source export destination already exists.")
    return path


def _parse_tree(repository: Path, commit: str) -> tuple[dict[str, tuple[str, str]], str]:
    tree = str(_git(repository, ["rev-parse", f"{commit}^{{tree}}"])).lower()
    object_format = str(_git(repository, ["rev-parse", "--show-object-format"]))
    if object_format not in {"sha1", "sha256"}:
        _fail("Reviewed repository uses an unsupported Git object format.")
    listing = _git(
        repository,
        ["ls-tree", "-r", "-z", "--full-tree", commit],
        binary=True,
    )
    assert isinstance(listing, bytes)
    entries: dict[str, tuple[str, str]] = {}
    folded_entries: set[str] = set()
    for raw_entry in listing.split(b"\0"):
        if not raw_entry:
            continue
        try:
            metadata, raw_path = raw_entry.split(b"\t", 1)
            mode, object_type, object_id = metadata.decode("ascii").split(" ", 2)
            relative = os.fsdecode(raw_path)
        except (UnicodeDecodeError, ValueError):
            _fail("Reviewed Git tree contains malformed entries.")
        components = relative.split("/")
        if (
            object_type != "blob"
            or mode not in ALLOWED_BLOB_MODES
            or relative.startswith("/")
            or "\\" in relative
            or any(
                component in {"", ".", ".."}
                or component.casefold() == ".git"
                or any(ord(character) < 32 or ord(character) == 127 for character in component)
                for component in components
            )
        ):
            _fail("Reviewed source may contain only safe regular files.")
        normalized = "/".join(components)
        folded = unicodedata.normalize("NFC", normalized).casefold()
        if normalized in entries or folded in folded_entries:
            _fail("Reviewed source contains colliding paths.")
        entries[normalized] = (mode, object_id.lower())
        folded_entries.add(folded)
    if not entries:
        _fail("Reviewed source tree is empty.")
    return entries, object_format


def _same_directory(first: os.stat_result, second: os.stat_result) -> bool:
    return (
        first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_uid == second.st_uid
        and first.st_mode == second.st_mode
        and stat.S_ISDIR(second.st_mode)
    )


def _stable_blob_id(path: Path, object_format: str) -> tuple[str, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail("Exported source contains a linked or non-regular file.")
        digest = hashlib.new(object_format)
        digest.update(f"blob {before.st_size}\0".encode("ascii"))
        byte_count = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            byte_count += len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    visible = os.lstat(path)
    identity = (
        before.st_dev,
        before.st_ino,
        before.st_mode,
        before.st_nlink,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    if byte_count != before.st_size or identity != (
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_nlink,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    ) or identity != (
        visible.st_dev,
        visible.st_ino,
        visible.st_mode,
        visible.st_nlink,
        visible.st_size,
        visible.st_mtime_ns,
        visible.st_ctime_ns,
    ):
        _fail("Exported source changed while it was verified.")
    return digest.hexdigest(), after


def _verify_export(
    output: Path,
    root_identity: os.stat_result,
    expected: dict[str, tuple[str, str]],
    object_format: str,
) -> None:
    actual: set[str] = set()
    for current, directory_names, file_names in os.walk(output, followlinks=False):
        directory_names.sort(key=os.fsencode)
        file_names.sort(key=os.fsencode)
        current_path = Path(current)
        current_metadata = os.lstat(current_path)
        if not stat.S_ISDIR(current_metadata.st_mode):
            _fail("Exported source contains a non-directory path component.")
        for directory_name in directory_names:
            directory = current_path / directory_name
            if not stat.S_ISDIR(os.lstat(directory).st_mode):
                _fail("Exported source contains a linked directory.")
        for file_name in file_names:
            path = current_path / file_name
            relative = path.relative_to(output).as_posix()
            if relative not in expected:
                _fail("Exported source contains an unexpected file.")
            mode, object_id = expected[relative]
            actual_object_id, metadata = _stable_blob_id(path, object_format)
            if actual_object_id != object_id:
                _fail("Exported source bytes do not match the reviewed Git object.")
            executable = bool(metadata.st_mode & 0o111)
            if executable != (mode == "100755"):
                _fail("Exported source mode does not match the reviewed Git tree.")
            actual.add(relative)
    if actual != set(expected):
        _fail("Exported source is incomplete.")
    if not _same_directory(root_identity, os.lstat(output)):
        _fail("Exported source root changed while it was verified.")


def _remove_owned_output(path: Path, identity: os.stat_result | None) -> None:
    if identity is None:
        return
    try:
        current = os.lstat(path)
    except FileNotFoundError:
        return
    if not _same_directory(identity, current):
        return
    shutil.rmtree(path)


def export_reviewed_source(
    *, repository: Path, source_commit: str, output: Path
) -> dict[str, object]:
    """Export and verify one immutable Git tree into a new private directory."""

    repository = _canonical_existing_directory(repository, "Repository")
    output = _validate_output(output)
    if re.fullmatch(r"[0-9a-fA-F]{40}", source_commit) is None:
        _fail("Reviewed source commit must be an exact 40-hex object ID.")
    commit = str(_git(repository, ["rev-parse", f"{source_commit}^{{commit}}"]))
    if commit.lower() != source_commit.lower():
        _fail("Reviewed source commit did not resolve exactly.")
    commit = commit.lower()
    source_tree = str(_git(repository, ["rev-parse", f"{commit}^{{tree}}"])).lower()
    head_tree = str(_git(repository, ["rev-parse", "HEAD^{tree}"])).lower()
    if source_tree != head_tree:
        _fail("Reviewed source commit does not match the checked-out tree.")
    expected, object_format = _parse_tree(repository, commit)

    root_identity: os.stat_result | None = None
    try:
        os.mkdir(output, 0o700)
        root_identity = os.lstat(output)
        archive = subprocess.Popen(
            [GIT, "-C", os.fspath(repository), "archive", "--format=tar", commit],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_git_environment(),
        )
        assert archive.stdout is not None
        extraction = subprocess.run(
            [TAR, "-x", "-f", "-", "-C", os.fspath(output)],
            stdin=archive.stdout,
            check=False,
            capture_output=True,
        )
        archive.stdout.close()
        archive_stderr = archive.stderr.read() if archive.stderr is not None else b""
        if archive.stderr is not None:
            archive.stderr.close()
        archive_status = archive.wait()
        if archive_status != 0 or extraction.returncode != 0:
            detail = archive_stderr or extraction.stderr
            _fail(
                "Could not materialize the reviewed source"
                + (f": {detail.decode('utf-8', 'replace').strip()}" if detail else ".")
            )
        _verify_export(output, root_identity, expected, object_format)
    except BaseException:
        _remove_owned_output(output, root_identity)
        raise

    return {
        "fileCount": len(expected),
        "locked": False,
        "sourceCommit": commit,
        "sourceTreeObjectID": source_tree,
    }


def verify_reviewed_source(
    *,
    repository: Path,
    source_commit: str,
    output: Path,
    require_locked: bool,
) -> dict[str, object]:
    """Re-hash an existing export against the exact reviewed Git tree."""

    repository = _canonical_existing_directory(repository, "Repository")
    output = _canonical_existing_directory(output, "Source export")
    if re.fullmatch(r"[0-9a-fA-F]{40}", source_commit) is None:
        _fail("Reviewed source commit must be an exact 40-hex object ID.")
    commit = str(_git(repository, ["rev-parse", f"{source_commit}^{{commit}}"]))
    if commit.lower() != source_commit.lower():
        _fail("Reviewed source commit did not resolve exactly.")
    commit = commit.lower()
    source_tree = str(_git(repository, ["rev-parse", f"{commit}^{{tree}}"]))
    if str(_git(repository, ["rev-parse", "HEAD^{tree}"])) != source_tree:
        _fail("Reviewed source commit no longer matches the checked-out tree.")
    expected, object_format = _parse_tree(repository, commit)
    root_identity = os.lstat(output)
    _verify_export(output, root_identity, expected, object_format)

    locked = True
    for current, directory_names, file_names in os.walk(output, followlinks=False):
        current_path = Path(current)
        paths = [current_path]
        paths.extend(current_path / name for name in directory_names)
        paths.extend(current_path / name for name in file_names)
        for path in paths:
            metadata = os.lstat(path)
            if not metadata.st_flags & stat.UF_IMMUTABLE:
                locked = False
    if require_locked and not locked:
        _fail("Reviewed source export is no longer immutable.")
    return {
        "fileCount": len(expected),
        "locked": locked,
        "sourceCommit": commit,
        "sourceTreeObjectID": source_tree,
    }


def lock_reviewed_source(
    *, repository: Path, source_commit: str, output: Path
) -> dict[str, object]:
    """Make a verified export read-only and user-immutable for the build."""

    verify_reviewed_source(
        repository=repository,
        source_commit=source_commit,
        output=output,
        require_locked=False,
    )
    for current, directory_names, file_names in os.walk(
        output, topdown=False, followlinks=False
    ):
        current_path = Path(current)
        for file_name in file_names:
            path = current_path / file_name
            metadata = os.lstat(path)
            mode = 0o500 if metadata.st_mode & stat.S_IXUSR else 0o400
            os.chmod(path, mode, follow_symlinks=False)
            os.chflags(
                path,
                os.lstat(path).st_flags | stat.UF_IMMUTABLE,
                follow_symlinks=False,
            )
        for directory_name in directory_names:
            directory = current_path / directory_name
            os.chmod(directory, 0o500, follow_symlinks=False)
            os.chflags(
                directory,
                os.lstat(directory).st_flags | stat.UF_IMMUTABLE,
                follow_symlinks=False,
            )
    os.chmod(output, 0o500, follow_symlinks=False)
    os.chflags(
        output,
        os.lstat(output).st_flags | stat.UF_IMMUTABLE,
        follow_symlinks=False,
    )
    return verify_reviewed_source(
        repository=repository,
        source_commit=source_commit,
        output=output,
        require_locked=True,
    )


def unlock_reviewed_source(output: Path) -> None:
    """Unlock one exact temporary export so its owning build can clean it."""

    output = _canonical_existing_directory(output, "Source export")
    paths: list[Path] = [output]
    for current, directory_names, file_names in os.walk(output, followlinks=False):
        current_path = Path(current)
        paths.extend(current_path / name for name in directory_names)
        paths.extend(current_path / name for name in file_names)
    for path in paths:
        metadata = os.lstat(path)
        if stat.S_ISLNK(metadata.st_mode):
            _fail("Reviewed source cleanup contains a linked path.")
        os.chflags(
            path,
            metadata.st_flags & ~stat.UF_IMMUTABLE,
            follow_symlinks=False,
        )
        if stat.S_ISDIR(metadata.st_mode):
            os.chmod(path, 0o700, follow_symlinks=False)
        else:
            executable = bool(metadata.st_mode & stat.S_IXUSR)
            os.chmod(path, 0o700 if executable else 0o600, follow_symlinks=False)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--lock-existing", action="store_true")
    action.add_argument("--verify-existing", action="store_true")
    action.add_argument("--unlock-existing", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.lock_existing:
            receipt = lock_reviewed_source(
                repository=arguments.repository,
                source_commit=arguments.source_commit,
                output=arguments.output,
            )
        elif arguments.verify_existing:
            receipt = verify_reviewed_source(
                repository=arguments.repository,
                source_commit=arguments.source_commit,
                output=arguments.output,
                require_locked=True,
            )
        elif arguments.unlock_existing:
            unlock_reviewed_source(arguments.output)
            receipt = {"unlocked": True}
        else:
            receipt = export_reviewed_source(
                repository=arguments.repository,
                source_commit=arguments.source_commit,
                output=arguments.output,
            )
    except (OSError, SourceExportError, subprocess.SubprocessError) as error:
        print(f"Reviewed source export failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
