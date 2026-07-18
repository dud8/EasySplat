#!/usr/bin/env python3
"""Promote a staged directory without making an existing install disappear."""

from __future__ import annotations

import ctypes
import os
import stat
import sys
from pathlib import Path


RENAME_SWAP = 0x00000002


def require_directory(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"{label} is not a regular directory: {path}")


def sync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise ValueError(f"path is not a directory: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_regular_file(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"path is not a regular file: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_tree(root: Path) -> None:
    require_directory(root, "staged install")
    files = []
    directories = [root]
    for current_raw, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_raw)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            if path.is_symlink() or not stat.S_ISDIR(path.lstat().st_mode):
                raise ValueError(f"staged install contains a non-directory entry: {path}")
            directories.append(path)
        for name in file_names:
            path = current / name
            if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
                raise ValueError(f"staged install contains a non-regular file: {path}")
            files.append(path)

    for path in files:
        sync_regular_file(path)
    for path in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        sync_directory(path)


def swap_directories(left: Path, right: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renamex = libc.renamex_np
    renamex.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    renamex.restype = ctypes.c_int
    result = renamex(os.fsencode(left), os.fsencode(right), RENAME_SWAP)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), f"{left} <-> {right}")


def promote(stage: Path, install: Path) -> None:
    require_directory(stage, "staged install")
    parent = stage.parent.resolve(strict=True)
    if install.parent.resolve(strict=True) != parent:
        raise ValueError("stage and install must have the same parent directory")
    if install.is_symlink():
        raise ValueError(f"install path is a symlink: {install}")

    sync_tree(stage)
    if not install.exists():
        os.rename(stage, install)
        try:
            sync_directory(parent)
        except BaseException:
            os.rename(install, stage)
            try:
                sync_directory(parent)
            except OSError:
                pass
            raise
        return

    require_directory(install, "current install")
    swap_directories(stage, install)
    try:
        sync_directory(parent)
    except BaseException:
        swap_directories(stage, install)
        try:
            sync_directory(parent)
        except OSError:
            pass
        raise


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: atomic_swap_install.py <stage> <install>", file=sys.stderr)
        return 2
    try:
        promote(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError) as error:
        print(f"atomic promotion failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
