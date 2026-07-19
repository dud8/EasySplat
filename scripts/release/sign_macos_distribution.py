#!/usr/bin/env python3
"""Sign a macOS app or toolchain tree with one exact Developer ID identity."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, NamedTuple, NoReturn


SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
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


def fail(message: str) -> NoReturn:
    raise SigningError(message)


def run_command(command: list[str]) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    for name in tuple(environment):
        if name.startswith(("DYLD_", "LD_")) or name == "CODESIGN_ALLOCATE":
            environment.pop(name, None)
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


def validate_signing_identity(
    fingerprint: str,
    team_id: str,
    command_runner: CommandRunner = run_command,
) -> dict[str, str]:
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
    if not common_name.startswith("Developer ID Application:"):
        fail("the selected identity is not a Developer ID Application certificate")
    common_name_team = re.search(r"\(([A-Z0-9]{10})\)\s*$", common_name)
    if common_name_team is None or common_name_team.group(1) != team_id:
        fail("the Developer ID Application identity has the wrong Team ID")
    _verify_identity_certificate(
        normalized_fingerprint, common_name, command_runner
    )
    return {"fingerprint": normalized_fingerprint, "teamID": team_id}


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1_024 * 1_024), b""):
                digest.update(chunk)
    except OSError:
        fail(f"unable to hash signing input: {path.name}")
    return digest.hexdigest()


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
        data = path.read_bytes()
        payload = plistlib.loads(data)
    except (OSError, plistlib.InvalidFileException):
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


def _app_main_executable(root: Path) -> str:
    try:
        payload = plistlib.loads((root / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException):
        fail("app Info.plist is invalid")
    executable = payload.get("CFBundleExecutable") if isinstance(payload, dict) else None
    if not isinstance(executable, str) or not executable or "/" in executable:
        fail("app Info.plist has an invalid CFBundleExecutable")
    return f"Contents/MacOS/{executable}"


def validate_entitlements(
    root: Path,
    kind: str,
    macho_paths: list[Path],
    entitlements: dict[str, Path],
) -> dict[str, EntitlementInput]:
    available = {_relative_path(path, root) for path in macho_paths}
    app_main = _app_main_executable(root) if kind == "app" else None
    validated: dict[str, EntitlementInput] = {}
    for relative, source in entitlements.items():
        if relative not in available:
            fail(f"entitlements target is not a discovered Mach-O file: {relative}")
        parts = Path(relative).parts
        is_top_level = (
            (kind == "tree" and len(parts) == 2 and parts[0] == "bin")
            or (kind == "app" and relative == app_main)
        )
        if not is_top_level:
            fail(f"entitlements target is not a named top-level executable: {relative}")
        validated[relative] = _load_entitlements(source)
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
        [CODESIGN, "--display", "--entitlements", ":-", str(target)]
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


def _sign(
    target: Path,
    fingerprint: str,
    entitlement: EntitlementSnapshot | None,
    command_runner: CommandRunner,
) -> str | None:
    command = [
        CODESIGN,
        "--force",
        "--sign",
        fingerprint,
        "--options",
        "runtime",
        "--timestamp",
    ]
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
    expected_team_id: str,
    command_runner: CommandRunner,
) -> dict[str, object]:
    verification = command_runner(
        [CODESIGN, "--verify", "--strict", "--verbose=4", str(target)]
    )
    require_command_success(verification, "strict codesign verification")
    display = command_runner([CODESIGN, "--display", "--verbose=4", str(target)])
    require_command_success(display, "codesign metadata inspection")

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
    if "(runtime)" not in code_directory or not values.get("Runtime Version"):
        fail("codesign metadata does not prove the hardened runtime")
    timestamp = values.get("Timestamp", "")
    if not timestamp or timestamp.lower() in {"none", "not set"}:
        fail("codesign metadata does not contain a secure timestamp")
    expected_leaf = re.compile(
        rf"Developer ID Application: .+ \({re.escape(expected_team_id)}\)"
    )
    if not authorities or expected_leaf.fullmatch(authorities[0]) is None:
        fail("codesign metadata has no matching Developer ID Application authority")
    if authorities[1:] != [
        "Developer ID Certification Authority",
        "Apple Root CA",
    ]:
        fail("codesign metadata has an invalid Developer ID authority chain")
    return {
        "identifier": values.get("Identifier"),
        "format": values.get("Format"),
        "codeDirectory": code_directory.removeprefix("CodeDirectory "),
        "teamIdentifier": values["TeamIdentifier"],
        "hardenedRuntime": True,
        "runtimeVersion": values["Runtime Version"],
        "timestamp": timestamp,
        "authorities": authorities,
    }


def _prepare_receipt_path(receipt_path: Path, root: Path) -> Path:
    if not receipt_path.is_absolute():
        fail("signing receipt path must be absolute")
    resolved_root = root.resolve(strict=True)
    resolved_receipt = receipt_path.resolve(strict=False)
    try:
        resolved_receipt.relative_to(resolved_root)
    except ValueError:
        pass
    else:
        fail("signing receipt must be outside the signing root")
    try:
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        fail("unable to create signing receipt directory")
    if receipt_path.exists() or receipt_path.is_symlink():
        try:
            status = receipt_path.lstat()
        except OSError:
            fail("unable to inspect existing signing receipt")
        if not stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode):
            fail("existing signing receipt must be a regular file, not a symlink")
    return receipt_path


def _atomic_write_json(path: Path, payload: dict[str, object]) -> None:
    data = (
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    descriptor = -1
    temporary_name = ""
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.", dir=path.parent
        )
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
        temporary_name = ""
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError:
        fail("unable to write signing receipt atomically")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


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
) -> dict[str, object]:
    root = validate_signing_root(root, kind)
    ancestry = _snapshot_root_ancestry(root)
    receipt_path = _prepare_receipt_path(receipt_path, root)
    pre_tree = snapshot_tree(root)
    identity = validate_signing_identity(identity_fingerprint, team_id, run_command)
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
    entitlement_map = validate_entitlements(
        root, kind, macho_paths, entitlements or {}
    )
    snapshot_directory = tempfile.TemporaryDirectory(
        prefix="easysplat-entitlements-"
    )
    try:
        entitlement_snapshots = snapshot_entitlements(
            entitlement_map, Path(snapshot_directory.name)
        )
        app_main = _app_main_executable(root) if kind == "app" else None
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

        entries: list[dict[str, object]] = []
        verified_macho_bindings: dict[str, FileBinding] = {}
        for path in final_paths:
            relative = _relative_path(path, root)
            original = pre_tree.entries[relative]
            entitlement = entitlement_map.get(relative)
            before_verification = _file_binding(path)
            metadata = _codesign_metadata(path, team_id, run_command)
            after_verification = _file_binding(path)
            if before_verification != after_verification:
                fail(f"signed Mach-O changed during signature verification: {relative}")
            verified_macho_bindings[relative] = after_verification
            entries.append(
                {
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
            )
            _require_unchanged_root_ancestry(ancestry)

        verified_app_tree: TreeSnapshot | None = None
        if kind == "app":
            app_entitlement = entitlement_map.get(app_main or "")
            before_app_verification = snapshot_tree(root)
            app_metadata = _codesign_metadata(root, team_id, run_command)
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
        }
        _require_unchanged_root_ancestry(ancestry)
        publication_tree = snapshot_tree(root)
        if publication_tree.entries != post_tree.entries:
            fail("signing tree changed after signature verification")
        _atomic_write_json(receipt_path, payload)
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
    parser.add_argument("--kind", required=True, choices=("app", "tree"))
    parser.add_argument("--identity-fingerprint", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--receipt", required=True, type=Path)
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
        sign_distribution_tree(
            args.root,
            kind=args.kind,
            identity_fingerprint=args.identity_fingerprint,
            team_id=args.team_id,
            receipt_path=args.receipt,
            entitlements=entitlements,
        )
    except SigningError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Developer ID signing receipt written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
