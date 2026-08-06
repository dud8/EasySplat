#!/usr/bin/env python3
"""Sign a macOS app, toolchain tree, or DMG with one Developer ID identity."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import posixpath
import re
import secrets
import stat
import struct
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, NamedTuple, NoReturn


SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"
VTOOL = "/usr/bin/vtool"
OTOOL = "/usr/bin/otool"
SHA1 = re.compile(r"[0-9A-Fa-f]{40}")
TEAM_ID = re.compile(r"[A-Z0-9]{10}")
IDENTITY_LINE = re.compile(
    r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"(.*)$'
)
PEM_CERTIFICATE = re.compile(
    r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----",
    re.DOTALL,
)
MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
FORBIDDEN_APP_ENTITLEMENTS = (
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.debugger",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.get-task-allow",
)
# Read from the team's own leaf certificates rather than a published table:
# Developer ID Application carries 6.1.13 under the 6.2.6 intermediate, while
# Apple Distribution -- the current Mac App Store application certificate --
# carries 6.1.7 under the WWDR 6.2.1 intermediate that G3, G5 and G6 all share.
CHANNELS: dict[str, dict[str, str]] = {
    "developer-id": {
        "commonNamePrefix": "Developer ID Application:",
        "label": "Developer ID Application",
        "intermediateOID": "1.2.840.113635.100.6.2.6",
        "leafOID": "1.2.840.113635.100.6.1.13",
    },
    "mas": {
        "commonNamePrefix": "Apple Distribution:",
        "label": "Apple Distribution",
        "intermediateOID": "1.2.840.113635.100.6.2.1",
        "leafOID": "1.2.840.113635.100.6.1.7",
    },
}
DEFAULT_CHANNEL = "developer-id"
# The store sandboxes the app and its helpers inherit that sandbox, so a store
# build is the one case where entitlements are required rather than forbidden.
MAS_HELPER_PREFIX = "Contents/Helpers/"
APP_BINARY_POLICY = {
    "architectures": ["arm64"],
    "minimumOS": "15.0",
    "platform": "macOS",
}
MACHO_DEPENDENCY_LOAD_COMMANDS = {
    "LC_LAZY_LOAD_DYLIB",
    "LC_LOAD_DYLIB",
    "LC_LOAD_UPWARD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
}
CommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]


class SigningError(ValueError):
    pass


class PathIdentity(NamedTuple):
    device: int
    inode: int
    mode: int


class TreeEntry(NamedTuple):
    relative_path: str
    kind: str
    mode: int
    size: int
    sha256: str | None
    identity: PathIdentity
    is_macho: bool


class TreeSnapshot(NamedTuple):
    entries: dict[str, TreeEntry]
    manifest_sha256: str
    file_count: int


class FileBinding(NamedTuple):
    identity: PathIdentity
    size: int
    sha256: str


class EntitlementInput(NamedTuple):
    source: Path
    source_sha256: str
    data: bytes
    payload: dict[str, object]
    canonical_sha256: str


class EntitlementSnapshot(NamedTuple):
    path: Path
    source: Path
    source_sha256: str
    payload: dict[str, object]
    canonical_sha256: str


class MachODependencyImage(NamedTuple):
    install_name: str | None
    rpaths: tuple[str, ...]
    loads: tuple[str, ...]


class DirectoryBinding(NamedTuple):
    path: Path
    parent_descriptor: int
    descriptor: int
    parent_identity: tuple[int, int, int, int]
    identity: tuple[int, int, int, int]


class ReceiptDestination(NamedTuple):
    path: Path
    parent: Path
    parent_descriptor: int
    parent_identity: tuple[int, int, int, int]
    parent_ancestry: dict[Path, PathIdentity]
    name: str


def fail(message: str) -> NoReturn:
    raise SigningError(message)


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    environment = {
        "HOME": os.environ.get("HOME", "/var/empty"),
        "LANG": "C",
        "LC_ALL": "C",
        "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "nobody")),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/private/tmp",
        "USER": os.environ.get("USER", os.environ.get("LOGNAME", "nobody")),
    }
    try:
        return subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=environment,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"unable to run required macOS signing command: {type(error).__name__}")


def require_command_success(
    result: subprocess.CompletedProcess[str], label: str
) -> None:
    if result.returncode != 0:
        fail(f"{label} failed with exit status {result.returncode}")


def channel_policy(channel: str) -> dict[str, str]:
    policy = CHANNELS.get(channel)
    if policy is None:
        fail(f"unknown distribution channel: {channel}")
    return policy


def validate_signing_identity(
    fingerprint: str,
    team_id: str,
    command_runner: CommandRunner = run_command,
    *,
    channel: str = DEFAULT_CHANNEL,
) -> dict[str, str]:
    policy = channel_policy(channel)
    if not SHA1.fullmatch(fingerprint):
        fail("signing identity fingerprint must be exactly 40 hexadecimal characters")
    if not TEAM_ID.fullmatch(team_id):
        fail("Team ID must be exactly 10 uppercase letters or digits")

    normalized_fingerprint = fingerprint.upper()
    result = command_runner(
        [SECURITY, "find-identity", "-v", "-p", "codesigning"]
    )
    require_command_success(result, "Developer ID identity lookup")

    matches: list[tuple[str, str]] = []
    invalid_target = False
    for line in f"{result.stdout}\n{result.stderr}".splitlines():
        match = IDENTITY_LINE.fullmatch(line)
        if match is None or match.group(1).upper() != normalized_fingerprint:
            continue
        annotation = match.group(3).upper()
        if "EXPIRED" in annotation or "REVOKED" in annotation:
            invalid_target = True
            continue
        matches.append((match.group(2), annotation))

    if invalid_target:
        fail("the selected Developer ID identity is expired or revoked")
    if len(matches) != 1:
        fail("the exact fingerprint is not exactly one valid identity")

    common_name = matches[0][0]
    if not common_name.startswith(policy["commonNamePrefix"]):
        fail(f"the selected identity is not the expected {policy['label']} certificate")
    common_name_team = re.search(r"\(([A-Z0-9]{10})\)\s*$", common_name)
    if common_name_team is None or common_name_team.group(1) != team_id:
        fail(f"the {policy['label']} identity has the wrong Team ID")
    _verify_identity_certificate(
        normalized_fingerprint, common_name, command_runner
    )
    return {
        "fingerprint": normalized_fingerprint,
        "teamID": team_id,
        "channel": channel,
    }


def _verify_identity_certificate(
    fingerprint: str,
    common_name: str,
    command_runner: CommandRunner,
) -> None:
    lookup = command_runner(
        [SECURITY, "find-certificate", "-a", "-c", common_name, "-p"]
    )
    require_command_success(lookup, "Developer ID certificate lookup")
    matching_certificates: list[str] = []
    for match in PEM_CERTIFICATE.finditer(f"{lookup.stdout}\n{lookup.stderr}"):
        body = "".join(match.group(1).split())
        try:
            der = base64.b64decode(body, validate=True)
        except (ValueError, binascii.Error):
            fail("security returned an invalid PEM certificate")
        if hashlib.sha1(der).hexdigest().upper() == fingerprint:
            matching_certificates.append(match.group(0) + "\n")
    if len(matching_certificates) != 1:
        fail("the exact Developer ID certificate was not found exactly once")

    with tempfile.TemporaryDirectory(prefix="easysplat-developer-id-") as directory:
        certificate_path = Path(directory) / "certificate.pem"
        try:
            descriptor = os.open(
                certificate_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "w", encoding="ascii", closefd=True) as stream:
                stream.write(matching_certificates[0])
                stream.flush()
                os.fsync(stream.fileno())
        except OSError:
            fail("unable to create the Developer ID certificate verification snapshot")
        verification = command_runner(
            [
                SECURITY,
                "verify-cert",
                "-c",
                str(certificate_path),
                "-p",
                "codeSign",
                "-R",
                "ocsp",
                "-R",
                "require",
                "-q",
            ]
        )
        if verification.returncode != 0:
            fail("the Developer ID certificate failed trust or revocation verification")


def validate_signing_root(root: Path, kind: str) -> Path:
    if kind not in {"app", "tree"}:
        fail("signing root kind must be 'app' or 'tree'")
    if not root.is_absolute():
        fail("signing root must be an absolute path")
    if ".." in root.parts:
        fail("signing root must not contain parent traversal")
    if root == Path(root.anchor):
        fail("refusing to use the filesystem root as a signing root")
    if Path(os.path.normpath(str(root))) != root:
        fail("signing root must be a normalized canonical path")
    try:
        resolved_root = root.resolve(strict=True)
    except OSError:
        fail("signing root does not exist")
    if resolved_root != root:
        fail("signing root ancestry contains a symlink or is not canonical")
    _snapshot_root_ancestry(root)
    try:
        root_status = root.lstat()
    except OSError:
        fail("signing root does not exist")
    if stat.S_ISLNK(root_status.st_mode):
        fail("signing root must not be a symlink")
    if not stat.S_ISDIR(root_status.st_mode):
        fail("signing root must be a directory")
    if root_status.st_uid != os.geteuid():
        fail("signing root must be owned by the current user")
    if root_status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("signing root must not be group- or world-writable")

    if kind == "app":
        if root.suffix != ".app":
            fail("an app signing root must end in .app")
        info_plist = root / "Contents/Info.plist"
        macos_directory = root / "Contents/MacOS"
        if not info_plist.is_file() or info_plist.is_symlink():
            fail("app signing root has no regular Contents/Info.plist")
        if not macos_directory.is_dir() or macos_directory.is_symlink():
            fail("app signing root has no safe Contents/MacOS directory")
    return root


def _snapshot_root_ancestry(root: Path) -> dict[Path, PathIdentity]:
    identities: dict[Path, PathIdentity] = {}
    current = Path(root.anchor)
    components = root.parts[1:]
    for component in (None, *components):
        if component is not None:
            current /= component
        try:
            status = current.lstat()
        except OSError:
            fail("signing root ancestry changed while signing")
        if stat.S_ISLNK(status.st_mode):
            fail("signing root ancestry contains a symlink")
        if not stat.S_ISDIR(status.st_mode):
            fail("signing root ancestry contains a non-directory component")
        identities[current] = PathIdentity(
            status.st_dev,
            status.st_ino,
            stat.S_IMODE(status.st_mode),
        )
    return identities


def _require_unchanged_root_ancestry(
    expected: dict[Path, PathIdentity],
) -> None:
    for path, identity in expected.items():
        try:
            status = path.lstat()
        except OSError:
            fail("signing root ancestry changed while signing")
        current = PathIdentity(
            status.st_dev,
            status.st_ino,
            stat.S_IMODE(status.st_mode),
        )
        if stat.S_ISLNK(status.st_mode) or not stat.S_ISDIR(status.st_mode):
            fail("signing root ancestry changed while signing")
        if current != identity:
            fail("signing root ancestry changed while signing")


def _relative_path(path: Path, root: Path) -> str:
    relative = path.relative_to(root).as_posix()
    try:
        relative.encode("utf-8")
    except UnicodeEncodeError:
        fail("signing tree contains a path that is not valid UTF-8")
    return relative


def _scan_tree_entries(root: Path) -> dict[str, TreeEntry]:
    scanned: dict[str, TreeEntry] = {}
    pending = [root]
    while pending:
        path = pending.pop()
        relative = "." if path == root else _relative_path(path, root)
        try:
            status = path.lstat()
        except OSError:
            fail(f"unable to inspect signing tree entry: {relative}")
        if stat.S_ISLNK(status.st_mode):
            fail(f"signing tree contains a symlink: {relative}")
        if status.st_uid != os.geteuid():
            fail(f"signing tree entry is not owned by the current user: {relative}")
        identity = PathIdentity(
            status.st_dev,
            status.st_ino,
            stat.S_IMODE(status.st_mode),
        )
        if stat.S_ISDIR(status.st_mode):
            if status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"signing tree directory is group- or world-writable: {relative}")
            scanned[relative] = TreeEntry(
                relative,
                "directory",
                stat.S_IMODE(status.st_mode),
                status.st_size,
                None,
                identity,
                False,
            )
            try:
                children = sorted(
                    os.scandir(path),
                    key=lambda item: os.fsencode(item.name),
                    reverse=True,
                )
            except OSError:
                fail(f"unable to inspect signing tree directory: {relative}")
            pending.extend(Path(child.path) for child in children)
        elif stat.S_ISREG(status.st_mode):
            if status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail(f"signing tree file is group- or world-writable: {relative}")
            if status.st_nlink != 1:
                fail(f"signing tree contains a hard linked file: {relative}")
            scanned[relative] = TreeEntry(
                relative,
                "file",
                stat.S_IMODE(status.st_mode),
                status.st_size,
                sha256_file(path),
                identity,
                is_macho(path),
            )
        else:
            fail(f"signing tree contains a special file: {relative}")
    return scanned


def _tree_manifest_digest(entries: dict[str, TreeEntry]) -> str:
    digest = hashlib.sha256()
    digest.update(b"EasySplat macOS signing tree manifest v1\0")
    for relative in sorted(entries, key=os.fsencode):
        entry = entries[relative]
        payload = json.dumps(
            {
                "device": entry.identity.device,
                "inode": entry.identity.inode,
                "kind": entry.kind,
                "mode": f"{entry.mode:04o}",
                "relativePath": entry.relative_path,
                "sha256": entry.sha256,
                "size": entry.size,
            },
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def snapshot_tree(root: Path) -> TreeSnapshot:
    entries = _scan_tree_entries(root)
    return TreeSnapshot(
        entries,
        _tree_manifest_digest(entries),
        sum(entry.kind == "file" for entry in entries.values()),
    )


def validate_tree_transition(
    before: TreeSnapshot,
    after: TreeSnapshot,
    *,
    kind: str,
    macho_paths: set[str],
) -> None:
    before_paths = set(before.entries)
    after_paths = set(after.entries)
    allowed_signature_paths = {
        "Contents/_CodeSignature",
        "Contents/_CodeSignature/CodeResources",
    }
    allowed_additions = allowed_signature_paths - before_paths if kind == "app" else set()
    if before_paths - after_paths:
        fail("signing deleted files or directories from the input tree")
    unexpected_additions = after_paths - before_paths - allowed_additions
    if unexpected_additions:
        fail("signing added unexpected files or directories to the input tree")
    if kind == "app":
        signature_directory = after.entries.get("Contents/_CodeSignature")
        signature_file = after.entries.get("Contents/_CodeSignature/CodeResources")
        if signature_directory is None or signature_directory.kind != "directory":
            fail("app signing did not produce the expected signature directory")
        if signature_file is None or signature_file.kind != "file":
            fail("app signing did not produce the expected CodeResources file")

    for relative, original in before.entries.items():
        current = after.entries[relative]
        if original.kind != current.kind:
            fail(f"signing changed the tree entry type: {relative}")
        if original.kind == "directory":
            if original.mode != current.mode or original.identity != current.identity:
                fail(f"signing tree directory changed while signing: {relative}")
            continue
        if relative in macho_paths:
            if original.mode != current.mode:
                fail(f"Mach-O file mode changed while signing: {relative}")
            continue
        if kind == "app" and relative == "Contents/_CodeSignature/CodeResources":
            continue
        if original != current:
            fail(f"non-Mach-O file changed while signing: {relative}")


def _walk_regular_tree(root: Path) -> list[Path]:
    snapshot = snapshot_tree(root)
    return [
        root / relative
        for relative, entry in snapshot.entries.items()
        if entry.kind == "file"
    ]


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) in MACHO_MAGICS
    except OSError:
        fail(f"unable to read possible Mach-O file: {path.name}")


def discover_macho_files(root: Path) -> list[Path]:
    files = [path for path in _walk_regular_tree(root) if is_macho(path)]

    return _order_macho_paths(root, files)


def _order_macho_paths(root: Path, files: list[Path]) -> list[Path]:
    ordered = files.copy()

    def signing_order(path: Path) -> tuple[int, int, bytes]:
        relative = path.relative_to(root)
        parent = relative.parent.as_posix()
        is_top_level_executable = parent in {"bin", "Contents/MacOS"}
        return (
            -len(relative.parts),
            1 if is_top_level_executable else 0,
            os.fsencode(relative.as_posix()),
        )

    ordered.sort(key=signing_order)
    return ordered


def _stable_regular_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _directory_identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
    )


def _open_bound_directory(root: Path, *, label: str) -> DirectoryBinding:
    if (
        not root.is_absolute()
        or ".." in root.parts
        or Path(os.path.normpath(str(root))) != root
        or root == Path(root.anchor)
    ):
        fail(f"{label} must use an absolute normalized non-root path")
    try:
        if root.resolve(strict=True) != root or root.parent.resolve(strict=True) != root.parent:
            fail(f"{label} must be canonical and must not contain symlinks")
        parent_initial = root.parent.lstat()
        root_initial = root.lstat()
    except OSError:
        fail(f"{label} is missing")
    if (
        not stat.S_ISDIR(parent_initial.st_mode)
        or stat.S_ISLNK(parent_initial.st_mode)
        or not stat.S_ISDIR(root_initial.st_mode)
        or stat.S_ISLNK(root_initial.st_mode)
        or root_initial.st_uid != os.geteuid()
        or root_initial.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail(f"{label} must be a safe owned directory")
    parent_identity = _directory_identity(parent_initial)
    root_identity = _directory_identity(root_initial)
    parent_descriptor = -1
    descriptor = -1
    completed = False
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        parent_descriptor = os.open(root.parent, directory_flags)
        if _directory_identity(os.fstat(parent_descriptor)) != parent_identity:
            fail(f"{label} parent changed before binding")
        descriptor = os.open(root.name, directory_flags, dir_fd=parent_descriptor)
        if _directory_identity(os.fstat(descriptor)) != root_identity:
            fail(f"{label} changed before binding")
        named = os.stat(
            root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if _directory_identity(named) != root_identity:
            fail(f"{label} pathname changed before binding")
        binding = DirectoryBinding(
            root,
            parent_descriptor,
            descriptor,
            parent_identity,
            root_identity,
        )
        completed = True
        return binding
    except OSError:
        fail(f"{label} changed before binding")
    finally:
        if not completed:
            if descriptor >= 0:
                os.close(descriptor)
            if parent_descriptor >= 0:
                os.close(parent_descriptor)


def _close_bound_directory(binding: DirectoryBinding) -> None:
    os.close(binding.descriptor)
    os.close(binding.parent_descriptor)


def _require_bound_directory(binding: DirectoryBinding, *, label: str) -> None:
    try:
        if _directory_identity(os.fstat(binding.parent_descriptor)) != binding.parent_identity:
            fail(f"{label} parent binding changed")
        if _directory_identity(os.fstat(binding.descriptor)) != binding.identity:
            fail(f"{label} binding changed")
        if _directory_identity(binding.path.parent.lstat()) != binding.parent_identity:
            fail(f"{label} parent pathname changed")
        named = os.stat(
            binding.path.name,
            dir_fd=binding.parent_descriptor,
            follow_symlinks=False,
        )
        if _directory_identity(named) != binding.identity:
            fail(f"{label} pathname changed")
    except OSError:
        fail(f"{label} pathname changed")


def _fd_tree_snapshot(root: DirectoryBinding) -> dict[str, tuple[object, ...]]:
    rows: dict[str, tuple[object, ...]] = {}
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY

    def stable_identity(metadata: os.stat_result) -> tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_uid,
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )

    def scan(directory_descriptor: int, relative: str) -> None:
        initial_directory = os.fstat(directory_descriptor)
        if (
            not stat.S_ISDIR(initial_directory.st_mode)
            or stat.S_ISLNK(initial_directory.st_mode)
            or initial_directory.st_uid != os.geteuid()
            or initial_directory.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            fail("artifact tree contains an unsafe directory")
        directory_identity = stable_identity(initial_directory)
        rows[relative] = ("directory", directory_identity, None)
        scan_descriptor = -1
        iterator: object | None = None
        try:
            scan_descriptor = os.open(".", directory_flags, dir_fd=directory_descriptor)
            iterator = os.scandir(scan_descriptor)
            names = sorted(
                (entry.name for entry in iterator),
                key=os.fsencode,
            )
        except OSError:
            fail("artifact tree changed while enumerating")
        finally:
            close_iterator = getattr(iterator, "close", None)
            if close_iterator is not None:
                close_iterator()
            if scan_descriptor >= 0:
                os.close(scan_descriptor)

        for name in names:
            try:
                name.encode("utf-8")
            except UnicodeEncodeError:
                fail("artifact tree contains a path that is not valid UTF-8")
            child_relative = name if relative == "." else f"{relative}/{name}"
            try:
                initial = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except OSError:
                fail("artifact tree changed while enumerating")
            identity = stable_identity(initial)
            if stat.S_ISLNK(initial.st_mode):
                fail("artifact tree contains a symlink")
            if initial.st_uid != os.geteuid():
                fail("artifact tree contains an entry owned by another user")
            if initial.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail("artifact tree contains a group- or world-writable entry")
            if stat.S_ISDIR(initial.st_mode):
                child_descriptor = -1
                try:
                    child_descriptor = os.open(
                        name,
                        directory_flags,
                        dir_fd=directory_descriptor,
                    )
                    if stable_identity(os.fstat(child_descriptor)) != identity:
                        fail("artifact tree directory changed before opening")
                    scan(child_descriptor, child_relative)
                    if stable_identity(os.fstat(child_descriptor)) != identity:
                        fail("artifact tree directory changed while scanning")
                    if stable_identity(
                        os.stat(
                            name,
                            dir_fd=directory_descriptor,
                            follow_symlinks=False,
                        )
                    ) != identity:
                        fail("artifact tree directory pathname changed while scanning")
                except OSError:
                    fail("artifact tree directory changed while scanning")
                finally:
                    if child_descriptor >= 0:
                        os.close(child_descriptor)
                continue
            if not stat.S_ISREG(initial.st_mode):
                fail("artifact tree contains a special file")
            if initial.st_nlink != 1:
                fail("artifact tree contains a hard linked file")
            descriptor = -1
            digest = hashlib.sha256()
            try:
                descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory_descriptor,
                )
                if stable_identity(os.fstat(descriptor)) != identity:
                    fail("artifact tree file changed before opening")
                while chunk := os.read(descriptor, 1024 * 1024):
                    digest.update(chunk)
                if stable_identity(os.fstat(descriptor)) != identity:
                    fail("artifact tree file changed while hashing")
                if stable_identity(
                    os.stat(
                        name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                ) != identity:
                    fail("artifact tree file pathname changed while hashing")
            except OSError:
                fail("artifact tree file changed while hashing")
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
            rows[child_relative] = ("file", identity, digest.hexdigest())

        if stable_identity(os.fstat(directory_descriptor)) != directory_identity:
            fail("artifact tree directory changed while scanning")

    _require_bound_directory(root, label="artifact digest root")
    scan(root.descriptor, ".")
    _require_bound_directory(root, label="artifact digest root")
    return rows


def sha256_file(path: Path) -> str:
    try:
        initial = path.lstat()
    except OSError:
        fail(f"unable to inspect signing input: {path.name}")
    if (
        not stat.S_ISREG(initial.st_mode)
        or stat.S_ISLNK(initial.st_mode)
        or initial.st_uid != os.geteuid()
        or initial.st_nlink != 1
        or initial.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail(f"signing input is not a safe regular file: {path.name}")
    binding = _stable_regular_identity(initial)
    digest = hashlib.sha256()
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        if _stable_regular_identity(os.fstat(descriptor)) != binding:
            fail(f"signing input identity changed before hashing: {path.name}")
        while chunk := os.read(descriptor, 1_024 * 1_024):
            digest.update(chunk)
        if _stable_regular_identity(os.fstat(descriptor)) != binding:
            fail(f"signing input changed while hashing: {path.name}")
        if _stable_regular_identity(path.lstat()) != binding:
            fail(f"signing input pathname changed while hashing: {path.name}")
    except OSError:
        fail(f"unable to hash signing input: {path.name}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def artifact_sha256(root: Path) -> str:
    metadata = root.lstat()
    if stat.S_ISREG(metadata.st_mode):
        return sha256_file(root)
    if not stat.S_ISDIR(metadata.st_mode):
        fail("artifact digest root must be a regular file or directory")
    binding = _open_bound_directory(root, label="artifact digest root")
    try:
        before = _fd_tree_snapshot(binding)
        digest = hashlib.sha256()
        for relative in sorted(before, key=os.fsencode):
            kind, identity, file_digest = before[relative]
            relative_bytes = relative.encode("utf-8", errors="surrogateescape")
            digest.update(b"D" if kind == "directory" else b"F")
            digest.update(struct.pack(">Q", len(relative_bytes)))
            digest.update(relative_bytes)
            digest.update(struct.pack(">I", identity[2]))
            if kind == "file":
                digest.update(struct.pack(">Q", identity[5]))
                digest.update(bytes.fromhex(str(file_digest)))
        if _fd_tree_snapshot(binding) != before:
            fail("artifact digest tree changed while hashing")
        _require_bound_directory(binding, label="artifact digest root")
        return digest.hexdigest()
    finally:
        _close_bound_directory(binding)


def _file_binding(path: Path) -> FileBinding:
    try:
        status = path.lstat()
    except OSError:
        fail("signed Mach-O changed during signature verification")
    if (
        not stat.S_ISREG(status.st_mode)
        or stat.S_ISLNK(status.st_mode)
        or status.st_nlink != 1
        or status.st_uid != os.geteuid()
    ):
        fail("signed Mach-O changed during signature verification")
    return FileBinding(
        PathIdentity(
            status.st_dev,
            status.st_ino,
            stat.S_IMODE(status.st_mode),
        ),
        status.st_size,
        sha256_file(path),
    )


def _load_entitlements(path: Path) -> EntitlementInput:
    if not path.is_absolute():
        fail("entitlements path must be absolute")
    try:
        status = path.lstat()
    except OSError:
        fail("entitlements file does not exist")
    if not stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode):
        fail("entitlements must be a regular file, not a symlink")
    if status.st_uid != os.geteuid():
        fail("entitlements file must be owned by the current user")
    if status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("entitlements file must not be group- or world-writable")
    if status.st_nlink != 1:
        fail("entitlements file must not be hard linked")
    if status.st_size > 1_048_576:
        fail("entitlements file exceeds the 1 MiB safety limit")
    try:
        data = _stable_regular_file_bytes(
            path,
            maximum_size=1_048_576,
            label="entitlements file",
        )
        payload = plistlib.loads(data)
    except plistlib.InvalidFileException:
        fail("entitlements file is not a valid property list")
    if not isinstance(payload, dict):
        fail("entitlements property list must contain a dictionary")
    canonical = plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True)
    return EntitlementInput(
        path,
        hashlib.sha256(data).hexdigest(),
        data,
        payload,
        hashlib.sha256(canonical).hexdigest(),
    )


def _app_main_executable_and_info_digest(root: Path) -> tuple[str, str]:
    try:
        data = _stable_regular_file_bytes(
            root / "Contents/Info.plist",
            maximum_size=4 * 1024 * 1024,
            label="app Info.plist",
        )
        payload = plistlib.loads(data)
    except plistlib.InvalidFileException:
        fail("app Info.plist is invalid")
    executable = payload.get("CFBundleExecutable") if isinstance(payload, dict) else None
    if (
        not isinstance(executable, str)
        or not executable
        or executable in {".", ".."}
        or Path(executable).name != executable
        or "/" in executable
        or "\0" in executable
    ):
        fail("app Info.plist has an invalid CFBundleExecutable")
    return (
        f"Contents/MacOS/{executable}",
        hashlib.sha256(data).hexdigest(),
    )


def _app_main_executable(root: Path) -> str:
    return _app_main_executable_and_info_digest(root)[0]


def _validate_app_main_executable(
    root: Path,
    tree: TreeSnapshot,
    macho_paths: set[str],
) -> str:
    main, current_info_digest = _app_main_executable_and_info_digest(root)
    info = tree.entries.get("Contents/Info.plist")
    if info is None or info.kind != "file" or info.sha256 != current_info_digest:
        fail("app Info.plist changed while validating CFBundleExecutable")
    entry = tree.entries.get(main)
    if (
        entry is None
        or entry.kind != "file"
        or not entry.is_macho
        or not (entry.mode & stat.S_IXUSR)
        or main not in macho_paths
    ):
        fail(
            "declared app executable from CFBundleExecutable must be an executable Mach-O"
        )
    return main


def validate_entitlements(
    root: Path,
    kind: str,
    macho_paths: list[Path],
    entitlements: dict[str, Path],
    app_main: str | None = None,
    channel: str = DEFAULT_CHANNEL,
) -> dict[str, EntitlementInput]:
    channel_policy(channel)
    store_app = kind == "app" and channel == "mas"
    if kind == "app" and not store_app and entitlements:
        fail("the distribution app uses an empty entitlement allowlist")
    available = {_relative_path(path, root) for path in macho_paths}
    if kind == "app" and app_main is None:
        app_main = _app_main_executable(root)
    validated: dict[str, EntitlementInput] = {}
    for relative, source in entitlements.items():
        if relative not in available:
            fail(f"entitlements target is not a discovered Mach-O file: {relative}")
        parts = Path(relative).parts
        is_top_level = (
            (kind == "tree" and len(parts) == 2 and parts[0] == "bin")
            or (kind == "app" and relative == app_main)
            # The store sandbox reaches a helper only if that helper is signed
            # to inherit it, so every bundled executable is a legitimate target.
            or (
                store_app
                and relative.startswith(MAS_HELPER_PREFIX)
                and ((root / relative).lstat().st_mode & stat.S_IXUSR)
            )
        )
        if not is_top_level:
            fail(f"entitlements target is not a named top-level executable: {relative}")
        validated[relative] = _load_entitlements(source)
    if store_app:
        # Entitlements describe a process, so codesign seals them onto
        # executables and silently drops them from libraries. Requiring one on a
        # dylib would demand something the format cannot carry.
        expected = {app_main or ""} | {
            _relative_path(path, root)
            for path in macho_paths
            if _relative_path(path, root).startswith(MAS_HELPER_PREFIX)
            and (path.lstat().st_mode & stat.S_IXUSR)
        }
        if set(validated) != expected:
            missing = sorted(expected - set(validated))
            fail(
                "a store app must carry entitlements on its main executable and "
                f"every bundled helper; missing: {missing[:5]}"
            )
    return validated


def snapshot_entitlements(
    entitlements: dict[str, EntitlementInput], snapshot_root: Path
) -> dict[str, EntitlementSnapshot]:
    snapshots: dict[str, EntitlementSnapshot] = {}
    for index, relative in enumerate(sorted(entitlements, key=os.fsencode)):
        source = entitlements[relative]
        snapshot = snapshot_root / f"{index:04d}.plist"
        try:
            descriptor = os.open(
                snapshot,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "wb", closefd=True) as stream:
                stream.write(source.data)
                stream.flush()
                os.fchmod(stream.fileno(), 0o400)
                os.fsync(stream.fileno())
        except OSError:
            fail("unable to create an immutable entitlements snapshot")
        snapshots[relative] = EntitlementSnapshot(
            snapshot,
            source.source,
            source.source_sha256,
            source.payload,
            source.canonical_sha256,
        )
    return snapshots


def require_unchanged_entitlements(
    entitlements: dict[str, EntitlementInput],
) -> None:
    for original in entitlements.values():
        try:
            current = _load_entitlements(original.source)
        except SigningError:
            fail("entitlements changed while signing")
        if current.source_sha256 != original.source_sha256:
            fail("entitlements changed while signing")


def _extract_embedded_entitlements(
    target: Path,
    expected: EntitlementSnapshot,
    command_runner: CommandRunner,
) -> str:
    result = command_runner(
        [CODESIGN, "--display", "--entitlements", "-", str(target)]
    )
    require_command_success(result, "embedded entitlements inspection")
    output = f"{result.stdout}\n{result.stderr}"
    start = output.find("<?xml")
    end = output.find("</plist>", start)
    if start < 0 or end < 0:
        fail("codesign did not return parseable embedded entitlements")
    xml = output[start : end + len("</plist>")].encode("utf-8")
    try:
        payload = plistlib.loads(xml)
    except plistlib.InvalidFileException:
        fail("codesign returned invalid embedded entitlements")
    if payload != expected.payload:
        fail("embedded entitlements differ from the approved property list")
    canonical = plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True)
    digest = hashlib.sha256(canonical).hexdigest()
    if digest != expected.canonical_sha256:
        fail("embedded entitlements canonical digest is inconsistent")
    return digest


def _require_empty_embedded_entitlements(
    target: Path,
    command_runner: CommandRunner,
) -> None:
    result = command_runner(
        [CODESIGN, "--display", "--entitlements", "-", str(target)]
    )
    require_command_success(result, "empty entitlement inspection")
    output = f"{result.stdout}\n{result.stderr}"
    has_start = "<?xml" in output or "<plist" in output
    has_end = "</plist>" in output
    if has_start != has_end:
        fail("codesign returned malformed embedded entitlement evidence")
    if has_start:
        fail("the distribution app's empty entitlement allowlist forbids blobs")


def _empty_entitlement_policy() -> dict[str, object]:
    return {
        "allowlist": {},
        "forbiddenKeys": list(FORBIDDEN_APP_ENTITLEMENTS),
        "policy": "empty",
    }


def _app_macho_build_contract(
    target: Path,
    command_runner: CommandRunner,
) -> dict[str, object]:
    architectures = command_runner([LIPO, "-archs", str(target)])
    require_command_success(architectures, "Mach-O architecture inspection")
    architecture_values = architectures.stdout.split()
    if architecture_values != ["arm64"]:
        fail("every distribution app Mach-O must contain exactly arm64")

    build = command_runner([VTOOL, "-show-build", str(target)])
    require_command_success(build, "Mach-O deployment inspection")
    platform_values: list[str] = []
    minimum_values: list[str] = []
    sdk_values: list[str] = []
    build_version_count = 0
    for raw_line in f"{build.stdout}\n{build.stderr}".splitlines():
        line = raw_line.strip()
        if line == "cmd LC_BUILD_VERSION":
            build_version_count += 1
        elif line.startswith("platform "):
            platform_values.append(line.removeprefix("platform "))
        elif line.startswith("minos "):
            minimum_values.append(line.removeprefix("minos "))
        elif line.startswith("sdk "):
            sdk_values.append(line.removeprefix("sdk "))
    if (
        build_version_count != 1
        or platform_values != ["MACOS"]
        or minimum_values != ["15.0"]
        or len(sdk_values) != 1
        or re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", sdk_values[0]) is None
    ):
        fail("every distribution app Mach-O must declare platform macOS and minimum macOS 15.0")
    return {
        "architectures": ["arm64"],
        "minimumOS": "15.0",
        "platform": "macOS",
        "sdk": sdk_values[0],
    }


def _macho_dependency_image(
    target: Path,
    command_runner: CommandRunner,
) -> MachODependencyImage:
    before = _file_binding(target)
    listing = command_runner([OTOOL, "-L", str(target)])
    require_command_success(listing, "Mach-O dependency listing")
    load_commands = command_runner([OTOOL, "-l", str(target)])
    require_command_success(load_commands, "Mach-O load-command inspection")
    if _file_binding(target) != before:
        fail(f"Mach-O changed during dependency inspection: {target.name}")

    current_command: str | None = None
    loads: list[str] = []
    rpaths: list[str] = []
    install_names: list[str] = []
    for raw_line in load_commands.stdout.splitlines():
        line = raw_line.strip()
        if line.startswith("cmd "):
            current_command = line.removeprefix("cmd ")
            continue
        if current_command == "LC_RPATH":
            match = re.fullmatch(r"path (.+) \(offset [0-9]+\)", line)
            if match is not None:
                rpaths.append(match.group(1))
                current_command = None
            continue
        if current_command not in MACHO_DEPENDENCY_LOAD_COMMANDS | {"LC_ID_DYLIB"}:
            continue
        match = re.fullmatch(r"name (.+) \(offset [0-9]+\)", line)
        if match is None:
            continue
        if current_command == "LC_ID_DYLIB":
            install_names.append(match.group(1))
        else:
            loads.append(match.group(1))
        current_command = None
    unique_install_names = sorted(set(install_names), key=os.fsencode)
    if len(unique_install_names) > 1:
        fail(f"Mach-O has inconsistent install names: {target.name}")
    return MachODependencyImage(
        unique_install_names[0] if unique_install_names else None,
        tuple(rpaths),
        tuple(loads),
    )


def _is_apple_system_path(value: str) -> bool:
    return (
        posixpath.normpath(value) == value
        and (
            value.startswith("/System/Library/")
            or value.startswith("/usr/lib/")
        )
    )


def _safe_macho_path_value(value: str, *, label: str) -> None:
    if (
        not value
        or "\x00" in value
        or "\n" in value
        or "\r" in value
        or "\ufffd" in value
    ):
        fail(f"Mach-O {label} is malformed")


def _expand_macho_token(
    value: str,
    *,
    image_relative: str,
    executable_relative: str,
    label: str,
) -> str:
    _safe_macho_path_value(value, label=label)
    token: str
    base: str
    if value == "@loader_path" or value.startswith("@loader_path/"):
        token = "@loader_path"
        base = posixpath.dirname(image_relative)
    elif value == "@executable_path" or value.startswith("@executable_path/"):
        token = "@executable_path"
        base = posixpath.dirname(executable_relative)
    elif value.startswith("/"):
        if _is_apple_system_path(value):
            return value
        fail(f"absolute non-system Mach-O {label}: {value}")
    elif value.startswith("@"):
        fail(f"unresolved Mach-O path token in {label}: {value}")
    else:
        fail(f"relative Mach-O {label} is not loader anchored: {value}")
    suffix = value[len(token) :].lstrip("/")
    expanded = posixpath.normpath(posixpath.join(base, suffix))
    if expanded in {"", ".", ".."} or expanded.startswith("../") or expanded.startswith("/"):
        fail(f"Mach-O {label} escapes the signing root: {value}")
    return expanded


def _dependency_closure_digest(images: list[dict[str, object]]) -> str:
    canonical = json.dumps(
        images,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    digest = hashlib.sha256()
    digest.update(b"EasySplat Mach-O dependency closure v1\0")
    digest.update(canonical)
    return digest.hexdigest()


def validate_macho_dependency_closure(
    root: Path,
    macho_paths: list[Path],
    command_runner: CommandRunner,
    *,
    main_executable: str | None = None,
) -> dict[str, object]:
    discovered = {
        _relative_path(path, root): path
        for path in macho_paths
    }
    inspected = {
        relative: _macho_dependency_image(path, command_runner)
        for relative, path in discovered.items()
    }
    if main_executable is not None:
        executable_relatives = [main_executable]
    else:
        executable_relatives = sorted(
            (
                relative
                for relative in discovered
                if len(Path(relative).parts) == 2
                and Path(relative).parts[0] == "bin"
            ),
            key=os.fsencode,
        )
        if not executable_relatives:
            executable_relatives = sorted(discovered, key=os.fsencode)

    for relative, image in inspected.items():
        if image.install_name is not None:
            install_name = image.install_name
            _safe_macho_path_value(install_name, label="install name")
            if install_name.startswith("/"):
                fail(f"absolute Mach-O install name is not bundle portable: {install_name}")
            if not install_name.startswith(
                ("@rpath/", "@loader_path/", "@executable_path/")
            ):
                fail(f"unresolved Mach-O install name: {install_name}")
            if install_name.startswith("@rpath/"):
                tail = posixpath.normpath(install_name.removeprefix("@rpath/"))
                if tail in {"", ".", ".."} or tail.startswith("../"):
                    fail(f"Mach-O install name escapes its run path: {install_name}")

        dependencies: list[dict[str, str]] = []
        for load_path in image.loads:
            _safe_macho_path_value(load_path, label="dependency")
            if load_path.startswith("/"):
                if not _is_apple_system_path(load_path):
                    fail(f"absolute non-system Mach-O dependency: {load_path}")
                dependencies.append(
                    {
                        "kind": "system",
                        "loadPath": load_path,
                        "resolvedPath": load_path,
                    }
                )
                continue

            candidates: set[str] = set()
            non_macho_candidates: set[str] = set()
            if load_path.startswith("@rpath/"):
                tail = posixpath.normpath(load_path.removeprefix("@rpath/"))
                if tail in {"", ".", ".."} or tail.startswith("../"):
                    fail(f"Mach-O dependency escapes its run path: {load_path}")
                rpath_owners = [(relative, value) for value in image.rpaths]
                for executable_relative in executable_relatives:
                    executable_image = inspected[executable_relative]
                    rpath_owners.extend(
                        (executable_relative, value)
                        for value in executable_image.rpaths
                    )
                for executable_relative in executable_relatives:
                    for owner_relative, rpath in rpath_owners:
                        expanded_rpath = _expand_macho_token(
                            rpath,
                            image_relative=owner_relative,
                            executable_relative=executable_relative,
                            label="run path",
                        )
                        if _is_apple_system_path(expanded_rpath):
                            continue
                        candidate = posixpath.normpath(
                            posixpath.join(expanded_rpath, tail)
                        )
                        if candidate in discovered:
                            candidates.add(candidate)
                        elif (root / candidate).exists():
                            non_macho_candidates.add(candidate)
            else:
                for executable_relative in executable_relatives:
                    candidate = _expand_macho_token(
                        load_path,
                        image_relative=relative,
                        executable_relative=executable_relative,
                        label="dependency",
                    )
                    if candidate in discovered:
                        candidates.add(candidate)
                    elif (root / candidate).exists():
                        non_macho_candidates.add(candidate)
            if non_macho_candidates:
                fail(f"Mach-O dependency resolves to a non-Mach-O target: {load_path}")
            if not candidates:
                fail(f"Mach-O dependency target is missing: {load_path}")
            if len(candidates) != 1:
                fail(f"Mach-O dependency target is ambiguous: {load_path}")
            dependencies.append(
                {
                    "kind": "bundle",
                    "loadPath": load_path,
                    "resolvedPath": next(iter(candidates)),
                }
            )
        image_dependencies = sorted(
            dependencies,
            key=lambda item: (
                os.fsencode(item["loadPath"]),
                os.fsencode(item["kind"]),
                os.fsencode(item["resolvedPath"]),
            ),
        )
        inspected[relative] = MachODependencyImage(
            image.install_name,
            tuple(sorted(set(image.rpaths), key=os.fsencode)),
            image.loads,
        )
        discovered[relative] = image_dependencies  # type: ignore[assignment]

    images: list[dict[str, object]] = []
    for relative in sorted(inspected, key=os.fsencode):
        image = inspected[relative]
        images.append(
            {
                "dependencies": discovered[relative],
                "installName": image.install_name,
                "relativePath": relative,
                "rpaths": list(image.rpaths),
            }
        )
    dependency_count = sum(
        len(image["dependencies"])  # type: ignore[arg-type]
        for image in images
    )
    return {
        "format": "macho-dependency-closure-v1",
        "manifestSHA256": _dependency_closure_digest(images),
        "imageCount": len(images),
        "dependencyCount": dependency_count,
        "images": images,
    }


def _sign(
    target: Path,
    fingerprint: str,
    entitlement: EntitlementSnapshot | None,
    command_runner: CommandRunner,
    *,
    hardened_runtime: bool = True,
) -> str | None:
    command = [
        CODESIGN,
        "--force",
        "--sign",
        fingerprint,
    ]
    if hardened_runtime:
        command.extend(["--options", "runtime"])
    command.append("--timestamp")
    if entitlement is not None:
        try:
            status = entitlement.path.lstat()
        except OSError:
            fail("entitlements snapshot changed before signing")
        if (
            not stat.S_ISREG(status.st_mode)
            or stat.S_IMODE(status.st_mode) != 0o400
            or status.st_nlink != 1
            or status.st_uid != os.geteuid()
        ):
            fail("entitlements snapshot changed before signing")
        before_digest = sha256_file(entitlement.path)
        if before_digest != entitlement.source_sha256:
            fail("entitlements snapshot changed before signing")
        command.extend(["--entitlements", str(entitlement.path)])
    command.append(str(target))
    result = command_runner(command)
    if entitlement is not None:
        try:
            status = entitlement.path.lstat()
        except OSError:
            fail("entitlements snapshot changed while signing")
        if (
            not stat.S_ISREG(status.st_mode)
            or stat.S_IMODE(status.st_mode) != 0o400
            or status.st_nlink != 1
            or status.st_uid != os.geteuid()
            or sha256_file(entitlement.path) != before_digest
        ):
            fail("entitlements snapshot changed while signing")
    require_command_success(result, "codesign signing")
    if entitlement is None:
        return None
    return _extract_embedded_entitlements(target, entitlement, command_runner)


def _codesign_metadata(
    target: Path,
    expected_identity_fingerprint: str,
    expected_team_id: str,
    command_runner: CommandRunner,
    *,
    require_hardened_runtime: bool = True,
    channel: str = DEFAULT_CHANNEL,
) -> dict[str, object]:
    policy = channel_policy(channel)
    developer_id_requirement = (
        "=anchor apple generic and "
        f"certificate 1[field.{policy['intermediateOID']}] and "
        f"certificate leaf[field.{policy['leafOID']}] and "
        f'certificate leaf[subject.OU] = "{expected_team_id}"'
    )
    verification = command_runner(
        [
            CODESIGN,
            "--verify",
            "--strict",
            "--verbose=4",
            "--test-requirement",
            developer_id_requirement,
            str(target),
        ]
    )
    require_command_success(
        verification,
        f"semantic {policy['label']} requirement verification",
    )
    with tempfile.TemporaryDirectory(prefix="easysplat-signing-certificate-") as directory:
        certificate_prefix = Path(directory) / "certificate"
        display = command_runner(
            [
                CODESIGN,
                "--display",
                "--verbose=4",
                f"--extract-certificates={certificate_prefix}",
                str(target),
            ]
        )
        require_command_success(display, "codesign metadata inspection")
        leaf_certificate = certificate_prefix.with_name(
            f"{certificate_prefix.name}0"
        )
        try:
            certificate_status = leaf_certificate.lstat()
        except OSError:
            fail("codesign did not extract the embedded leaf certificate")
        if (
            not stat.S_ISREG(certificate_status.st_mode)
            or stat.S_ISLNK(certificate_status.st_mode)
            or certificate_status.st_nlink != 1
            or certificate_status.st_uid != os.geteuid()
            or certificate_status.st_size <= 0
            or certificate_status.st_size > 1024 * 1024
        ):
            fail("codesign extracted an unsafe embedded leaf certificate")
        leaf_fingerprint = hashlib.sha1(
            leaf_certificate.read_bytes(), usedforsecurity=False
        ).hexdigest().upper()
        if leaf_fingerprint != expected_identity_fingerprint.upper():
            fail("codesign metadata has the wrong leaf certificate fingerprint")

    lines = f"{display.stdout}\n{display.stderr}".splitlines()
    values: dict[str, str] = {}
    authorities: list[str] = []
    code_directory = ""
    for line in lines:
        if line.startswith("CodeDirectory "):
            code_directory = line
        elif line.startswith("Authority="):
            authorities.append(line.removeprefix("Authority="))
        elif "=" in line:
            key, value = line.split("=", 1)
            if key in {"Identifier", "Format", "TeamIdentifier", "Runtime Version", "Timestamp"}:
                values[key] = value

    if values.get("TeamIdentifier") != expected_team_id:
        fail("codesign metadata has the wrong TeamIdentifier")
    has_hardened_runtime = (
        "(runtime)" in code_directory and bool(values.get("Runtime Version"))
    )
    if require_hardened_runtime and not has_hardened_runtime:
        fail("codesign metadata does not prove the hardened runtime")
    timestamp = values.get("Timestamp", "")
    if not timestamp or timestamp.lower() in {"none", "not set"}:
        fail("codesign metadata does not contain a secure timestamp")
    return {
        "identifier": values.get("Identifier"),
        "format": values.get("Format"),
        "codeDirectory": code_directory.removeprefix("CodeDirectory "),
        "teamIdentifier": values["TeamIdentifier"],
        "hardenedRuntime": has_hardened_runtime,
        "runtimeVersion": values.get("Runtime Version"),
        "timestamp": timestamp,
        "leafCertificateSHA1": leaf_fingerprint,
        "authorities": authorities,
    }


def _prepare_receipt_path(
    receipt_path: Path,
    root: Path,
) -> ReceiptDestination:
    if (
        not receipt_path.is_absolute()
        or ".." in receipt_path.parts
        or Path(os.path.normpath(str(receipt_path))) != receipt_path
        or receipt_path.name in {"", ".", ".."}
    ):
        fail("signing receipt path must be absolute")
    resolved_root = root.resolve(strict=True)
    try:
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        fail("unable to create signing receipt directory")
    try:
        resolved_parent = receipt_path.parent.resolve(strict=True)
        parent_status = receipt_path.parent.lstat()
    except OSError:
        fail("unable to inspect signing receipt directory")
    if resolved_parent != receipt_path.parent or stat.S_ISLNK(parent_status.st_mode):
        fail("signing receipt directory must be canonical and not a symlink")
    if (
        not stat.S_ISDIR(parent_status.st_mode)
        or parent_status.st_uid != os.geteuid()
        or parent_status.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail("signing receipt directory must be a safe owned directory")
    resolved_receipt = resolved_parent / receipt_path.name
    if resolved_receipt == resolved_root:
        fail("signing receipt must be outside the signing root")
    if stat.S_ISDIR(root.lstat().st_mode):
        try:
            resolved_receipt.relative_to(resolved_root)
        except ValueError:
            pass
        else:
            fail("signing receipt must be outside the signing root")

    parent_identity = _directory_identity(parent_status)
    parent_ancestry = _snapshot_root_ancestry(receipt_path.parent)
    descriptor = -1
    try:
        descriptor = os.open(
            receipt_path.parent,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
        )
        if _directory_identity(os.fstat(descriptor)) != parent_identity:
            fail("signing receipt directory changed before binding")
        try:
            os.stat(
                receipt_path.name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            fail("signing receipt destination already exists")
        return ReceiptDestination(
            receipt_path,
            receipt_path.parent,
            descriptor,
            parent_identity,
            parent_ancestry,
            receipt_path.name,
        )
    except SigningError:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        fail("unable to bind signing receipt directory")


def _close_receipt_destination(destination: ReceiptDestination) -> None:
    os.close(destination.parent_descriptor)


def _validate_receipt_destination(receipt_path: Path, root: Path) -> None:
    destination = _prepare_receipt_path(receipt_path, root)
    _close_receipt_destination(destination)


def _require_receipt_destination_parent(
    destination: ReceiptDestination,
) -> None:
    try:
        if (
            _directory_identity(os.fstat(destination.parent_descriptor))
            != destination.parent_identity
            or _directory_identity(destination.parent.lstat())
            != destination.parent_identity
        ):
            fail("signing receipt directory changed while publishing")
        _require_unchanged_root_ancestry(destination.parent_ancestry)
    except OSError:
        fail("signing receipt directory changed while publishing")


def _atomic_write_json(
    destination: ReceiptDestination,
    payload: dict[str, object],
) -> None:
    data = (
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    descriptor = -1
    temporary_name = f".{destination.name}.{secrets.token_hex(16)}"
    published = False
    completed = False
    try:
        _require_receipt_destination_parent(destination)
        descriptor = os.open(
            temporary_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination.parent_descriptor,
        )
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                fail("unable to write signing receipt atomically")
            offset += written
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
        staged = os.fstat(descriptor)
        if (
            not stat.S_ISREG(staged.st_mode)
            or staged.st_uid != os.geteuid()
            or staged.st_nlink != 1
            or staged.st_size != len(data)
        ):
            fail("unable to validate staged signing receipt")
        _require_receipt_destination_parent(destination)
        os.link(
            temporary_name,
            destination.name,
            src_dir_fd=destination.parent_descriptor,
            dst_dir_fd=destination.parent_descriptor,
            follow_symlinks=False,
        )
        published = True
        os.unlink(temporary_name, dir_fd=destination.parent_descriptor)
        temporary_name = ""
        final_status = os.stat(
            destination.name,
            dir_fd=destination.parent_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(final_status.st_mode)
            or final_status.st_dev != staged.st_dev
            or final_status.st_ino != staged.st_ino
            or final_status.st_uid != os.geteuid()
            or final_status.st_nlink != 1
            or stat.S_IMODE(final_status.st_mode) != 0o644
            or final_status.st_size != len(data)
        ):
            fail("published signing receipt has the wrong identity")
        os.fsync(destination.parent_descriptor)
        _require_receipt_destination_parent(destination)
        completed = True
    except OSError:
        fail("unable to write signing receipt atomically")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(
                    temporary_name,
                    dir_fd=destination.parent_descriptor,
                )
            except FileNotFoundError:
                pass
        if published and not completed:
            try:
                os.unlink(
                    destination.name,
                    dir_fd=destination.parent_descriptor,
                )
                os.fsync(destination.parent_descriptor)
            except FileNotFoundError:
                pass
        _close_receipt_destination(destination)


def _normalized_expected_identity(
    fingerprint: str, team_id: str
) -> tuple[str, str]:
    if not SHA1.fullmatch(fingerprint):
        fail("signing identity fingerprint must be exactly 40 hexadecimal characters")
    if not TEAM_ID.fullmatch(team_id):
        fail("Team ID must be exactly 10 uppercase letters or digits")
    return fingerprint.upper(), team_id


def _stable_regular_file_bytes(
    path: Path, *, maximum_size: int, label: str
) -> bytes:
    if not path.is_absolute():
        fail(f"{label} must use an absolute path")
    try:
        resolved = path.resolve(strict=True)
        initial = path.lstat()
    except OSError:
        fail(f"{label} is missing")
    if resolved != path or stat.S_ISLNK(initial.st_mode):
        fail(f"{label} path must be canonical and must not be a symlink")
    if (
        not stat.S_ISREG(initial.st_mode)
        or initial.st_uid != os.geteuid()
        or initial.st_nlink != 1
        or initial.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or initial.st_size <= 0
        or initial.st_size > maximum_size
    ):
        fail(f"{label} must be a safe ordinary regular file")
    ancestry = _snapshot_root_ancestry(path.parent)

    def identity(metadata: os.stat_result) -> tuple[int, ...]:
        return (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_uid,
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )

    initial_identity = identity(initial)
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        opened = os.fstat(descriptor)
        if identity(opened) != initial_identity:
            fail(f"{label} identity changed before reading")
        chunks: list[bytes] = []
        total = 0
        while chunk := os.read(descriptor, min(1024 * 1024, maximum_size + 1 - total)):
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum_size:
                fail(f"{label} exceeds its size limit")
        if identity(os.fstat(descriptor)) != initial_identity:
            fail(f"{label} changed while reading")
        current = path.lstat()
        if identity(current) != initial_identity:
            fail(f"{label} pathname changed while reading")
        _require_unchanged_root_ancestry(ancestry)
        return b"".join(chunks)
    except OSError:
        fail(f"{label} changed while reading")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def validate_signing_receipt(
    receipt_path: Path,
    *,
    kind: str,
    identity_fingerprint: str,
    team_id: str,
    current_artifact: Path | None = None,
) -> dict[str, object]:
    fingerprint, team_id = _normalized_expected_identity(
        identity_fingerprint, team_id
    )
    try:
        payload = json.loads(
            _stable_regular_file_bytes(
                receipt_path,
                maximum_size=4 * 1024 * 1024,
                label="signing receipt",
            ).decode("utf-8")
        )
    except (UnicodeError, json.JSONDecodeError):
        fail("signing receipt is not valid UTF-8 JSON")
    if not isinstance(payload, dict):
        fail("signing receipt must contain a JSON object")
    if (
        payload.get("schemaVersion") != 1
        or payload.get("rootKind") != kind
        or payload.get("channel", DEFAULT_CHANNEL) not in CHANNELS
        or payload.get("identityFingerprintSHA1") != fingerprint
        or payload.get("teamID") != team_id
    ):
        fail("signing receipt does not match the requested identity and artifact kind")
    entries = payload.get("entries")
    if not isinstance(entries, list) or not entries:
        fail("signing receipt has no signed entries")
    for entry in entries:
        if not isinstance(entry, dict):
            fail("signing receipt has an invalid signed entry")
        codesign = entry.get("codesign")
        if (
            entry.get("identityFingerprintSHA1") != fingerprint
            or entry.get("teamID") != team_id
            or not isinstance(codesign, dict)
            or codesign.get("leafCertificateSHA1") != fingerprint
            or codesign.get("teamIdentifier") != team_id
            or not isinstance(codesign.get("timestamp"), str)
            or not codesign["timestamp"]
        ):
            fail("signing receipt entry does not match the requested identity")
        if kind != "dmg" and codesign.get("hardenedRuntime") is not True:
            fail("signing receipt entry does not prove the hardened runtime")
    if kind == "app":
        if payload.get("entitlementPolicy") != _empty_entitlement_policy():
            fail("app signing receipt does not prove the empty entitlement policy")
        if payload.get("binaryPolicy") != APP_BINARY_POLICY:
            fail("app signing receipt does not prove the binary policy")
        main_executable = payload.get("mainExecutableRelativePath")
        if (
            not isinstance(main_executable, str)
            or not main_executable.startswith("Contents/MacOS/")
            or Path(main_executable).parts
            != ("Contents", "MacOS", Path(main_executable).name)
            or Path(main_executable).name in {"", ".", ".."}
        ):
            fail("app signing receipt has no valid declared main executable")
        artifact_digest = payload.get("artifactDigest")
        if (
            not isinstance(artifact_digest, dict)
            or artifact_digest.get("format") != "sha256-tree-v1"
            or re.fullmatch(
                r"[0-9a-f]{64}",
                str(artifact_digest.get("postSignSHA256", "")),
            )
            is None
        ):
            fail("app signing receipt has no shared post-sign artifact digest")
        store_app = payload.get("channel") == "mas"
        for entry in entries:
            present = entry.get("embeddedEntitlementsPresent")
            if present is not store_app:
                fail("app signing receipt disagrees with its channel on entitlements")
            if store_app:
                # A store entry proves which entitlements were sealed; a
                # Developer ID entry proves that none were.
                if not all(
                    isinstance(entry.get(field), str)
                    and re.fullmatch(r"[0-9a-f]{64}", str(entry.get(field)))
                    for field in (
                        "embeddedEntitlementsSHA256",
                        "entitlementsSHA256",
                        "entitlementsSourceSHA256",
                    )
                ):
                    fail("store signing receipt has no entitlement evidence")
            elif (
                entry.get("embeddedEntitlementsSHA256") is not None
                or entry.get("entitlementsSHA256") is not None
                or entry.get("entitlementsSourceSHA256") is not None
            ):
                fail("app signing receipt contains forbidden entitlement evidence")
            if entry.get("kind") == "machO":
                macho = entry.get("machO")
                if (
                    not isinstance(macho, dict)
                    or macho.get("architectures") != ["arm64"]
                    or macho.get("platform") != "macOS"
                    or macho.get("minimumOS") != "15.0"
                    or not isinstance(macho.get("sdk"), str)
                    or re.fullmatch(
                        r"[0-9]+(?:\.[0-9]+){1,2}",
                        str(macho.get("sdk")),
                    )
                    is None
                ):
                    fail("app signing receipt contains invalid Mach-O deployment evidence")
        if not any(
            entry.get("kind") == "appBundle"
            and entry.get("relativePath") == "."
            for entry in entries
        ):
            fail("app signing receipt has no final bundle entry")
        main_entries = [
            entry
            for entry in entries
            if entry.get("kind") == "machO"
            and entry.get("relativePath") == main_executable
        ]
        if len(main_entries) != 1:
            fail("app signing receipt does not bind the declared main executable")
        tree = payload.get("tree")
        if not isinstance(tree, dict) or re.fullmatch(
            r"[0-9a-f]{64}", str(tree.get("postSignManifestSHA256", ""))
        ) is None:
            fail("app signing receipt has no final tree digest")
        app_entries = [
            entry
            for entry in entries
            if entry.get("kind") == "appBundle"
            and entry.get("relativePath") == "."
        ]
        if (
            len(app_entries) != 1
            or app_entries[0].get("postSignSHA256")
            != tree.get("postSignManifestSHA256")
            or app_entries[0].get("mainExecutableRelativePath")
            != main_executable
        ):
            fail("app signing receipt digest fields are not exactly cross-linked")
    elif kind == "dmg":
        artifact_digest = payload.get("artifactDigest")
        if (
            not isinstance(artifact_digest, dict)
            or artifact_digest.get("format") != "sha256-file-v1"
            or re.fullmatch(
                r"[0-9a-f]{64}",
                str(artifact_digest.get("postSignSHA256", "")),
            )
            is None
        ):
            fail("disk image signing receipt has no shared post-sign artifact digest")
        if len(entries) != 1 or entries[0].get("kind") != "diskImage":
            fail("disk image signing receipt has an invalid entry set")
        if entries[0].get("postSignSHA256") != artifact_digest["postSignSHA256"]:
            fail("disk image signing receipt digest fields are not exactly cross-linked")
    if current_artifact is not None:
        if kind == "dmg":
            current_artifact = validate_dmg_signing_input(current_artifact)
        else:
            current_artifact = validate_signing_root(current_artifact, kind)
            if kind == "app":
                current_tree = snapshot_tree(current_artifact)
                current_macho_paths = {
                    relative
                    for relative, entry in current_tree.entries.items()
                    if entry.kind == "file" and entry.is_macho
                }
                if (
                    _validate_app_main_executable(
                        current_artifact,
                        current_tree,
                        current_macho_paths,
                    )
                    != payload.get("mainExecutableRelativePath")
                ):
                    fail(
                        "signing receipt declared main executable does not match the current app"
                    )
        current_digest = artifact_sha256(current_artifact)
        artifact_digest = payload.get("artifactDigest")
        if (
            not isinstance(artifact_digest, dict)
            or artifact_digest.get("postSignSHA256") != current_digest
        ):
            fail("signing receipt does not bind the current artifact bytes")
    return payload


def verify_distribution_tree(
    root: Path,
    *,
    kind: str,
    identity_fingerprint: str,
    team_id: str,
    run_command: CommandRunner = run_command,
    channel: str = DEFAULT_CHANNEL,
) -> dict[str, object]:
    store_app = kind == "app" and channel == "mas"
    fingerprint, team_id = _normalized_expected_identity(
        identity_fingerprint, team_id
    )
    root = validate_signing_root(root, kind)
    ancestry = _snapshot_root_ancestry(root)
    before = snapshot_tree(root)
    macho_paths = _order_macho_paths(
        root,
        [
            root / relative
            for relative, entry in before.entries.items()
            if entry.kind == "file" and entry.is_macho
        ],
    )
    if not macho_paths:
        fail("signing root contains no Mach-O files")
    macho_relative_paths = {_relative_path(path, root) for path in macho_paths}
    app_main = (
        _validate_app_main_executable(root, before, macho_relative_paths)
        if kind == "app"
        else None
    )

    entries: list[dict[str, object]] = []
    for path in macho_paths:
        relative = _relative_path(path, root)
        binding = _file_binding(path)
        metadata = _codesign_metadata(
            path, fingerprint, team_id, run_command, channel=channel
        )
        if kind == "app":
            if not store_app:
                _require_empty_embedded_entitlements(path, run_command)
            macho_contract = _app_macho_build_contract(path, run_command)
        if _file_binding(path) != binding:
            fail(f"signed Mach-O changed during exact identity verification: {relative}")
        entry: dict[str, object] = {
                "kind": "machO",
                "relativePath": relative,
                "sha256": binding.sha256,
                "codesign": metadata,
            }
        if kind == "app":
            entry["embeddedEntitlementsPresent"] = store_app
            entry["machO"] = macho_contract
        entries.append(entry)
        _require_unchanged_root_ancestry(ancestry)

    if kind == "app":
        app_metadata = _codesign_metadata(
            root, fingerprint, team_id, run_command, channel=channel
        )
        if not store_app:
            _require_empty_embedded_entitlements(root, run_command)
        entries.append(
            {
                "kind": "appBundle",
                "relativePath": ".",
                "sha256": before.manifest_sha256,
                "embeddedEntitlementsPresent": store_app,
                "mainExecutableRelativePath": app_main,
                "codesign": app_metadata,
            }
        )
        _require_unchanged_root_ancestry(ancestry)

    after = snapshot_tree(root)
    if after.entries != before.entries:
        fail("signing tree changed during exact identity verification")
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "rootKind": kind,
        "channel": channel,
        "identityFingerprintSHA1": fingerprint,
        "teamID": team_id,
        "treeManifestSHA256": before.manifest_sha256,
        "entries": entries,
    }
    if kind == "app":
        payload["entitlementPolicy"] = _empty_entitlement_policy()
        payload["binaryPolicy"] = APP_BINARY_POLICY
        payload["mainExecutableRelativePath"] = app_main
        payload["artifactDigest"] = {
            "format": "sha256-tree-v1",
            "postSignSHA256": artifact_sha256(root),
        }
    return payload


def validate_dmg_signing_input(path: Path) -> Path:
    if not path.is_absolute():
        fail("disk image signing input must be an absolute path")
    if ".." in path.parts or Path(os.path.normpath(str(path))) != path:
        fail("disk image signing input must be a normalized canonical path")
    if path.suffix != ".dmg":
        fail("disk image signing input must end in .dmg")
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        fail("disk image signing input does not exist")
    if resolved != path:
        fail("disk image signing input ancestry contains a symlink or is not canonical")
    _snapshot_root_ancestry(path.parent)
    try:
        status = path.lstat()
    except OSError:
        fail("disk image signing input does not exist")
    if stat.S_ISLNK(status.st_mode) or not stat.S_ISREG(status.st_mode):
        fail("disk image signing input must be a regular file, not a symlink")
    if status.st_nlink != 1:
        fail("disk image signing input must not be hard linked")
    if status.st_uid != os.geteuid():
        fail("disk image signing input must be owned by the current user")
    if status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("disk image signing input must not be group- or world-writable")
    if status.st_size <= 0:
        fail("disk image signing input must not be empty")
    return path


def verify_distribution_dmg(
    path: Path,
    *,
    identity_fingerprint: str,
    team_id: str,
    run_command: CommandRunner = run_command,
) -> dict[str, object]:
    fingerprint, team_id = _normalized_expected_identity(
        identity_fingerprint, team_id
    )
    path = validate_dmg_signing_input(path)
    ancestry = _snapshot_root_ancestry(path.parent)
    before = _file_binding(path)
    metadata = _codesign_metadata(
        path,
        fingerprint,
        team_id,
        run_command,
        require_hardened_runtime=False,
    )
    _require_unchanged_root_ancestry(ancestry)
    if _file_binding(path) != before:
        fail("disk image changed during exact identity verification")
    return {
        "schemaVersion": 1,
        "rootKind": "dmg",
        "identityFingerprintSHA1": fingerprint,
        "teamID": team_id,
        "sha256": before.sha256,
        "codesign": metadata,
    }


def sign_distribution_dmg(
    path: Path,
    *,
    identity_fingerprint: str,
    team_id: str,
    receipt_path: Path,
    run_command: CommandRunner = run_command,
    signing_time: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
) -> dict[str, object]:
    path = validate_dmg_signing_input(path)
    ancestry = _snapshot_root_ancestry(path.parent)
    _validate_receipt_destination(receipt_path, path)
    pre_sign = _file_binding(path)
    identity = validate_signing_identity(
        identity_fingerprint,
        team_id,
        run_command,
    )
    _require_unchanged_root_ancestry(ancestry)
    if _file_binding(path) != pre_sign:
        fail("disk image changed before signing began")

    fingerprint = identity["fingerprint"]
    _sign(
        path,
        fingerprint,
        None,
        run_command,
        hardened_runtime=False,
    )
    _require_unchanged_root_ancestry(ancestry)
    signed = _file_binding(path)
    if signed.identity != pre_sign.identity:
        fail("disk image identity or mode changed while signing")
    if signed.sha256 == pre_sign.sha256:
        fail("disk image signing did not change the artifact")

    before_verification = _file_binding(path)
    metadata = _codesign_metadata(
        path,
        fingerprint,
        team_id,
        run_command,
        require_hardened_runtime=False,
    )
    after_verification = _file_binding(path)
    if after_verification != before_verification:
        fail("disk image changed during signature verification")
    _require_unchanged_root_ancestry(ancestry)
    publication_binding = _file_binding(path)
    if publication_binding != after_verification:
        fail("disk image changed after signature verification")

    moment = signing_time()
    if moment.tzinfo is None:
        fail("signing time must include a timezone")
    signed_at = (
        moment.astimezone(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "rootKind": "dmg",
        "identityFingerprintSHA1": fingerprint,
        "teamID": team_id,
        "signedAt": signed_at,
        "entries": [
            {
                "kind": "diskImage",
                "relativePath": path.name,
                "mode": f"{pre_sign.identity.mode:04o}",
                "preSignSHA256": pre_sign.sha256,
                "postSignSHA256": publication_binding.sha256,
                "preSignSize": pre_sign.size,
                "postSignSize": publication_binding.size,
                "identityFingerprintSHA1": fingerprint,
                "teamID": team_id,
                "entitlementsSHA256": None,
                "entitlementsSourceSHA256": None,
                "embeddedEntitlementsSHA256": None,
                "signedAt": signed_at,
                "codesign": metadata,
            }
        ],
        "artifactDigest": {
            "format": "sha256-file-v1",
            "postSignSHA256": publication_binding.sha256,
        },
    }
    if _file_binding(path) != publication_binding:
        fail("disk image changed after signature verification")
    destination = _prepare_receipt_path(receipt_path, path)
    _atomic_write_json(destination, payload)
    _require_unchanged_root_ancestry(ancestry)
    if _file_binding(path) != publication_binding:
        fail("disk image changed while publishing its signing receipt")
    return payload


def sign_distribution_tree(
    root: Path,
    *,
    kind: str,
    identity_fingerprint: str,
    team_id: str,
    receipt_path: Path,
    entitlements: dict[str, Path] | None = None,
    run_command: CommandRunner = run_command,
    signing_time: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
    channel: str = DEFAULT_CHANNEL,
) -> dict[str, object]:
    store_app = kind == "app" and channel == "mas"
    root = validate_signing_root(root, kind)
    ancestry = _snapshot_root_ancestry(root)
    _validate_receipt_destination(receipt_path, root)
    pre_tree = snapshot_tree(root)
    identity = validate_signing_identity(
        identity_fingerprint, team_id, run_command, channel=channel
    )
    _require_unchanged_root_ancestry(ancestry)
    if snapshot_tree(root).entries != pre_tree.entries:
        fail("signing tree changed before signing began")
    fingerprint = identity["fingerprint"]
    macho_paths = _order_macho_paths(
        root,
        [
            root / relative
            for relative, entry in pre_tree.entries.items()
            if entry.kind == "file" and entry.is_macho
        ],
    )
    if not macho_paths:
        fail("signing root contains no Mach-O files")
    macho_relative_paths = {_relative_path(path, root) for path in macho_paths}
    app_main = (
        _validate_app_main_executable(root, pre_tree, macho_relative_paths)
        if kind == "app"
        else None
    )
    pre_sign_dependency_closure = validate_macho_dependency_closure(
        root,
        macho_paths,
        run_command,
        main_executable=app_main,
    )
    pre_sign_macho_contracts = (
        {
            _relative_path(path, root): _app_macho_build_contract(path, run_command)
            for path in macho_paths
        }
        if kind == "app"
        else {}
    )
    entitlement_map = validate_entitlements(
        root,
        kind,
        macho_paths,
        entitlements or {},
        app_main=app_main,
        channel=channel,
    )
    snapshot_directory = tempfile.TemporaryDirectory(
        prefix="easysplat-entitlements-"
    )
    try:
        entitlement_snapshots = snapshot_entitlements(
            entitlement_map, Path(snapshot_directory.name)
        )
        embedded_entitlement_digests: dict[str, str | None] = {}

        for path in macho_paths:
            relative = _relative_path(path, root)
            entitlement = entitlement_snapshots.get(relative)
            _require_unchanged_root_ancestry(ancestry)
            embedded_entitlement_digests[relative] = _sign(
                path,
                fingerprint,
                entitlement,
                run_command,
            )
            _require_unchanged_root_ancestry(ancestry)
        app_embedded_entitlement_digest: str | None = None
        if kind == "app":
            app_entitlement = entitlement_snapshots.get(app_main or "")
            _require_unchanged_root_ancestry(ancestry)
            app_embedded_entitlement_digest = _sign(
                root,
                fingerprint,
                app_entitlement,
                run_command,
            )
            _require_unchanged_root_ancestry(ancestry)
            if app_main is not None:
                embedded_entitlement_digests[app_main] = (
                    app_embedded_entitlement_digest
                )

        signed_tree = snapshot_tree(root)
        validate_tree_transition(
            pre_tree,
            signed_tree,
            kind=kind,
            macho_paths=macho_relative_paths,
        )
        final_paths = _order_macho_paths(
            root,
            [
                root / relative
                for relative, entry in signed_tree.entries.items()
                if entry.kind == "file" and entry.is_macho
            ],
        )
        if {_relative_path(path, root) for path in final_paths} != macho_relative_paths:
            fail("Mach-O contents changed while signing")
        post_sign_dependency_closure = validate_macho_dependency_closure(
            root,
            final_paths,
            run_command,
            main_executable=app_main,
        )
        if post_sign_dependency_closure != pre_sign_dependency_closure:
            fail("Mach-O dependency closure changed after signing")

        entries: list[dict[str, object]] = []
        verified_macho_bindings: dict[str, FileBinding] = {}
        for path in final_paths:
            relative = _relative_path(path, root)
            original = pre_tree.entries[relative]
            entitlement = entitlement_map.get(relative)
            before_verification = _file_binding(path)
            metadata = _codesign_metadata(
                path, fingerprint, team_id, run_command, channel=channel
            )
            if kind == "app":
                if not store_app:
                    _require_empty_embedded_entitlements(path, run_command)
                macho_contract = _app_macho_build_contract(path, run_command)
                if macho_contract != pre_sign_macho_contracts[relative]:
                    fail(f"Mach-O deployment contract changed while signing: {relative}")
            after_verification = _file_binding(path)
            if before_verification != after_verification:
                fail(f"signed Mach-O changed during signature verification: {relative}")
            verified_macho_bindings[relative] = after_verification
            entry: dict[str, object] = {
                    "kind": "machO",
                    "relativePath": relative,
                    "mode": f"{original.mode:04o}",
                    "preSignSHA256": original.sha256,
                    "postSignSHA256": "",
                    "identityFingerprintSHA1": fingerprint,
                    "teamID": team_id,
                    "entitlementsSHA256": embedded_entitlement_digests.get(relative),
                    "entitlementsSourceSHA256": (
                        entitlement.source_sha256 if entitlement else None
                    ),
                    "embeddedEntitlementsSHA256": (
                        embedded_entitlement_digests.get(relative)
                    ),
                    "signedAt": "",
                    "codesign": metadata,
                }
            if kind == "app":
                entry["embeddedEntitlementsPresent"] = store_app
                entry["machO"] = macho_contract
            entries.append(entry)
            _require_unchanged_root_ancestry(ancestry)

        verified_app_tree: TreeSnapshot | None = None
        if kind == "app":
            app_entitlement = entitlement_map.get(app_main or "")
            before_app_verification = snapshot_tree(root)
            app_metadata = _codesign_metadata(
                root, fingerprint, team_id, run_command, channel=channel
            )
            if not store_app:
                _require_empty_embedded_entitlements(root, run_command)
            verified_app_tree = snapshot_tree(root)
            if before_app_verification.entries != verified_app_tree.entries:
                fail("signed app changed during signature verification")
            entries.append(
                {
                    "kind": "appBundle",
                    "relativePath": ".",
                    "mode": f"{pre_tree.entries['.'].mode:04o}",
                    "preSignSHA256": pre_tree.manifest_sha256,
                    "postSignSHA256": "",
                    "identityFingerprintSHA1": fingerprint,
                    "teamID": team_id,
                    "entitlementsSHA256": app_embedded_entitlement_digest,
                    "entitlementsSourceSHA256": (
                        app_entitlement.source_sha256 if app_entitlement else None
                    ),
                    "embeddedEntitlementsSHA256": app_embedded_entitlement_digest,
                    "embeddedEntitlementsPresent": store_app,
                    "mainExecutableRelativePath": app_main,
                    "signedAt": "",
                    "codesign": app_metadata,
                }
            )
            _require_unchanged_root_ancestry(ancestry)

        require_unchanged_entitlements(entitlement_map)
        _require_unchanged_root_ancestry(ancestry)
        post_tree = snapshot_tree(root)
        validate_tree_transition(
            pre_tree,
            post_tree,
            kind=kind,
            macho_paths=macho_relative_paths,
        )
        for relative, binding in verified_macho_bindings.items():
            final_entry = post_tree.entries[relative]
            final_binding = FileBinding(
                final_entry.identity,
                final_entry.size,
                final_entry.sha256 or "",
            )
            if final_binding != binding:
                fail(f"signed Mach-O changed after signature verification: {relative}")
        if verified_app_tree is not None and verified_app_tree.entries != post_tree.entries:
            fail("signed app changed after signature verification")
        for entry in entries:
            relative = entry["relativePath"]
            if relative == ".":
                entry["postSignSHA256"] = post_tree.manifest_sha256
            else:
                entry["postSignSHA256"] = post_tree.entries[str(relative)].sha256

        moment = signing_time()
        if moment.tzinfo is None:
            fail("signing time must include a timezone")
        signed_at = (
            moment.astimezone(timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z")
        )
        for entry in entries:
            entry["signedAt"] = signed_at
        payload: dict[str, object] = {
            "schemaVersion": 1,
            "rootKind": kind,
            "channel": channel,
            "identityFingerprintSHA1": fingerprint,
            "teamID": team_id,
            "signedAt": signed_at,
            "tree": {
                "preSignManifestSHA256": pre_tree.manifest_sha256,
                "postSignManifestSHA256": post_tree.manifest_sha256,
                "preSignFileCount": pre_tree.file_count,
                "postSignFileCount": post_tree.file_count,
            },
            "entries": entries,
            "dependencyClosure": pre_sign_dependency_closure,
        }
        if kind == "app":
            app_artifact_digest = artifact_sha256(root)
            payload["entitlementPolicy"] = _empty_entitlement_policy()
            payload["binaryPolicy"] = APP_BINARY_POLICY
            payload["mainExecutableRelativePath"] = app_main
            payload["artifactDigest"] = {
                "format": "sha256-tree-v1",
                "postSignSHA256": app_artifact_digest,
            }
        _require_unchanged_root_ancestry(ancestry)
        publication_tree = snapshot_tree(root)
        if publication_tree.entries != post_tree.entries:
            fail("signing tree changed after signature verification")
        if kind == "app" and artifact_sha256(root) != payload["artifactDigest"]["postSignSHA256"]:
            fail("signed app changed while its receipt was assembled")
        destination = _prepare_receipt_path(receipt_path, root)
        _atomic_write_json(destination, payload)
        _require_unchanged_root_ancestry(ancestry)
        if snapshot_tree(root).entries != publication_tree.entries:
            fail("signing tree changed while publishing its signing receipt")
        if (
            kind == "app"
            and artifact_sha256(root)
            != payload["artifactDigest"]["postSignSHA256"]
        ):
            fail("signed app changed while publishing its signing receipt")
        return payload
    finally:
        snapshot_directory.cleanup()


def parse_entitlement_arguments(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        relative, separator, source = value.partition("=")
        if not separator or not relative or not source:
            fail("--entitlements must use RELATIVE_EXECUTABLE=PLIST_PATH")
        if relative in result:
            fail(f"duplicate entitlements target: {relative}")
        result[relative] = Path(source)
    return result


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--kind", required=True, choices=("app", "tree", "dmg"))
    parser.add_argument(
        "--channel", default=DEFAULT_CHANNEL, choices=tuple(CHANNELS)
    )
    parser.add_argument("--identity-fingerprint", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--bind-receipt-to-current-artifact", action="store_true")
    parser.add_argument(
        "--entitlements",
        action="append",
        default=[],
        metavar="RELATIVE_EXECUTABLE=PLIST_PATH",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        entitlements = parse_entitlement_arguments(args.entitlements)
        if args.verify_only:
            if entitlements:
                fail("exact identity verification does not accept entitlements")
            if args.bind_receipt_to_current_artifact and args.receipt is None:
                fail("current artifact binding requires a signing receipt")
            receipt_payload = None
            if args.receipt is not None:
                receipt_payload = validate_signing_receipt(
                    args.receipt,
                    kind=args.kind,
                    identity_fingerprint=args.identity_fingerprint,
                    team_id=args.team_id,
                    current_artifact=(
                        args.root if args.bind_receipt_to_current_artifact else None
                    ),
                )
            if args.kind == "dmg":
                verify_distribution_dmg(
                    args.root,
                    identity_fingerprint=args.identity_fingerprint,
                    team_id=args.team_id,
                )
            else:
                verify_distribution_tree(
                    args.root,
                    kind=args.kind,
                    identity_fingerprint=args.identity_fingerprint,
                    team_id=args.team_id,
                    channel=args.channel,
                )
            if args.receipt is not None and validate_signing_receipt(
                args.receipt,
                kind=args.kind,
                identity_fingerprint=args.identity_fingerprint,
                team_id=args.team_id,
                current_artifact=(
                    args.root if args.bind_receipt_to_current_artifact else None
                ),
            ) != receipt_payload:
                fail("signing receipt changed during exact identity verification")
            print(f"{channel_policy(args.channel)['label']} artifact identity verified.")
            return 0
        if args.receipt is None:
            fail("distribution signing requires --receipt")
        if args.bind_receipt_to_current_artifact:
            fail("receipt binding is only valid with --verify-only")
        if args.kind == "dmg":
            if entitlements:
                fail("disk images do not accept executable entitlements")
            if args.channel != DEFAULT_CHANNEL:
                fail("disk images ship outside the store and use Developer ID")
            sign_distribution_dmg(
                args.root,
                identity_fingerprint=args.identity_fingerprint,
                team_id=args.team_id,
                receipt_path=args.receipt,
            )
        else:
            sign_distribution_tree(
                args.root,
                kind=args.kind,
                identity_fingerprint=args.identity_fingerprint,
                team_id=args.team_id,
                receipt_path=args.receipt,
                entitlements=entitlements,
                channel=args.channel,
            )
    except SigningError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"{channel_policy(args.channel)['label']} signing receipt written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
