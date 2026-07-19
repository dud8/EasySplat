#!/usr/bin/python3
"""Publish one complete, flat release-asset set with rollback on failure."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Callable, NamedTuple, NoReturn, Union


LOCK_NAME = ".easysplat-release-publication.lock"
BACKUP_NAME = ".publication-backup"
JOURNAL_NAME = "transaction.json"
JOURNAL_SCHEMA_VERSION = 1
PathValue = Union[str, os.PathLike[str]]
Replace = Callable[[PathValue, PathValue], None]


class PublicationError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise PublicationError(message)


class FileBinding(NamedTuple):
    device: int
    inode: int
    mode: int
    owner: int
    links: int
    size: int
    modified_ns: int
    sha256: str


def _canonical_directory(path: Path, label: str) -> Path:
    if not path.is_absolute() or Path(os.path.normpath(str(path))) != path:
        fail(f"{label} must be an absolute normalized path")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError:
        fail(f"{label} does not exist")
    if resolved != path or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be canonical and contain no symlink ancestry")
    if not stat.S_ISDIR(metadata.st_mode):
        fail(f"{label} must be a directory")
    if metadata.st_uid != os.geteuid():
        fail(f"{label} must be owned by the current user")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(f"{label} must not be group- or world-writable")
    return path


def _validated_name(name: str) -> str:
    if (
        not name
        or name in {".", "..", LOCK_NAME, BACKUP_NAME}
        or Path(name).name != name
        or any(ord(character) < 32 for character in name)
    ):
        fail("release asset names must be safe basenames")
    try:
        name.encode("utf-8")
    except UnicodeEncodeError:
        fail("release asset names must be valid UTF-8")
    return name


def _file_binding(path: Path) -> FileBinding:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError:
        fail("release asset must be an ordinary regular file")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or before.st_size <= 0
        ):
            fail("release asset must be an ordinary regular file")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        before_identity = (
            before.st_dev,
            before.st_ino,
            stat.S_IMODE(before.st_mode),
            before.st_uid,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
        )
        after_identity = (
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_uid,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
        )
        if before_identity != after_identity:
            fail("release asset changed while it was validated")
        return FileBinding(*after_identity, digest.hexdigest())
    finally:
        os.close(descriptor)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _binding_payload(binding: FileBinding) -> dict[str, int | str]:
    return {
        "device": binding.device,
        "inode": binding.inode,
        "mode": binding.mode,
        "owner": binding.owner,
        "links": binding.links,
        "size": binding.size,
        "modifiedNS": binding.modified_ns,
        "sha256": binding.sha256,
    }


def _binding_from_payload(value: object) -> FileBinding:
    expected_keys = {
        "device",
        "inode",
        "mode",
        "owner",
        "links",
        "size",
        "modifiedNS",
        "sha256",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        fail("publication journal contains an invalid file binding")
    integer_keys = expected_keys - {"sha256"}
    if any(
        not isinstance(value[key], int) or isinstance(value[key], bool)
        for key in integer_keys
    ):
        fail("publication journal contains an invalid file binding")
    digest = value["sha256"]
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        fail("publication journal contains an invalid file binding")
    if (
        value["device"] < 0
        or value["inode"] <= 0
        or value["mode"] < 0
        or value["mode"] > 0o7777
        or value["owner"] != os.geteuid()
        or value["links"] != 1
        or value["size"] <= 0
        or value["modifiedNS"] < 0
        or value["mode"] & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        fail("publication journal contains an unsafe file binding")
    return FileBinding(
        value["device"],
        value["inode"],
        value["mode"],
        value["owner"],
        value["links"],
        value["size"],
        value["modifiedNS"],
        digest,
    )


def _journal_payload(
    *,
    state: str,
    process_id: int,
    stage: Path,
    output: Path,
    names: list[str],
    source_bindings: dict[str, FileBinding] | None = None,
    old_bindings: dict[str, FileBinding] | None = None,
) -> dict[str, object]:
    source = source_bindings or {}
    old = old_bindings or {}
    return {
        "schemaVersion": JOURNAL_SCHEMA_VERSION,
        "state": state,
        "processID": process_id,
        "stageDirectory": str(stage),
        "outputDirectory": str(output),
        "files": [
            {
                "name": name,
                "new": _binding_payload(source[name]) if name in source else None,
                "old": _binding_payload(old[name]) if name in old else None,
            }
            for name in names
        ],
    }


def _write_journal(lock: Path, payload: dict[str, object]) -> None:
    encoded = (
        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    temporary = lock / f".{JOURNAL_NAME}.{os.getpid()}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, 0o600)
        written = 0
        while written < len(encoded):
            written += os.write(descriptor, encoded[written:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, lock / JOURNAL_NAME)
        _fsync_directory(lock)
    except OSError:
        fail("unable to persist the release publication journal")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _read_journal(lock: Path) -> dict[str, object]:
    journal = lock / JOURNAL_NAME
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(journal, flags)
    except OSError:
        fail("publication lock has no recoverable transaction journal")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or before.st_size <= 0
            or before.st_size > 1024 * 1024
        ):
            fail("publication journal must be a safe regular file")
        data = bytearray()
        while len(data) <= 1024 * 1024:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(descriptor)
        before_identity = (
            before.st_dev,
            before.st_ino,
            stat.S_IMODE(before.st_mode),
            before.st_uid,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
        )
        after_identity = (
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_uid,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
        )
        if len(data) > 1024 * 1024 or before_identity != after_identity:
            fail("publication journal changed while it was read")
    finally:
        os.close(descriptor)
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        fail("publication journal is not valid UTF-8 JSON")
    if not isinstance(payload, dict) or set(payload) != {
        "schemaVersion",
        "state",
        "processID",
        "stageDirectory",
        "outputDirectory",
        "files",
    }:
        fail("publication journal has an invalid schema")
    state = payload["state"]
    process_id = payload["processID"]
    if (
        payload["schemaVersion"] != JOURNAL_SCHEMA_VERSION
        or state not in {"initializing", "prepared", "committed"}
        or not isinstance(process_id, int)
        or isinstance(process_id, bool)
        or process_id <= 0
        or not isinstance(payload["stageDirectory"], str)
        or not isinstance(payload["outputDirectory"], str)
        or not isinstance(payload["files"], list)
        or not payload["files"]
    ):
        fail("publication journal has invalid transaction metadata")
    names: list[str] = []
    for entry in payload["files"]:
        if not isinstance(entry, dict) or set(entry) != {"name", "new", "old"}:
            fail("publication journal contains an invalid file entry")
        name = entry["name"]
        if not isinstance(name, str):
            fail("publication journal contains an invalid file name")
        names.append(_validated_name(name))
        if state == "initializing":
            if entry["new"] is not None or entry["old"] is not None:
                fail("initializing publication journal contains file bindings")
        else:
            entry["new"] = _binding_from_payload(entry["new"])
            if entry["old"] is not None:
                entry["old"] = _binding_from_payload(entry["old"])
    if len(set(names)) != len(names):
        fail("publication journal contains duplicate file names")
    return payload


def _process_is_alive(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _repair_mode_and_bind(path: Path, expected: FileBinding) -> FileBinding:
    try:
        metadata = path.lstat()
    except OSError:
        fail("release transaction contains a missing file")
    unchanged_object = (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_dev == expected.device
        and metadata.st_ino == expected.inode
        and metadata.st_uid == expected.owner
        and metadata.st_nlink == expected.links
        and metadata.st_size == expected.size
        and metadata.st_mtime_ns == expected.modified_ns
    )
    if not unchanged_object:
        fail("release transaction contains an unexpected file")
    try:
        os.chmod(path, expected.mode)
    except OSError:
        fail("release transaction file permissions could not be restored")
    binding = _file_binding(path)
    if binding != expected:
        fail("release transaction file no longer matches its journal binding")
    return binding


def _binding_at(path: Path, candidates: tuple[FileBinding, ...]) -> FileBinding | None:
    if not path.exists() and not path.is_symlink():
        return None
    try:
        return _file_binding(path)
    except PublicationError:
        for candidate in candidates:
            try:
                return _repair_mode_and_bind(path, candidate)
            except PublicationError:
                continue
        fail("release transaction contains an unsafe or changed file")


def _payload_bindings(
    payload: dict[str, object],
) -> tuple[list[str], dict[str, FileBinding], dict[str, FileBinding]]:
    names: list[str] = []
    source_bindings: dict[str, FileBinding] = {}
    old_bindings: dict[str, FileBinding] = {}
    for entry in payload["files"]:
        name = entry["name"]
        new_binding = entry["new"]
        names.append(name)
        if not isinstance(new_binding, FileBinding):
            fail("publication journal is missing a staged file binding")
        source_bindings[name] = new_binding
        old_binding = entry["old"]
        if isinstance(old_binding, FileBinding):
            old_bindings[name] = old_binding
    return names, source_bindings, old_bindings


def _validate_journal_paths(
    payload: dict[str, object], output: Path
) -> tuple[Path, Path]:
    recorded_output = Path(payload["outputDirectory"])
    if recorded_output != output:
        fail("publication journal targets a different release output")
    stage = _canonical_directory(
        Path(payload["stageDirectory"]), "publication recovery stage"
    )
    if stage.parent != output or stage.stat().st_dev != output.stat().st_dev:
        fail("publication recovery stage is outside the release output")
    return stage, stage / BACKUP_NAME


def _clear_journal_lock(output: Path, lock: Path) -> None:
    retired = output / (
        f"{LOCK_NAME}.retired.{os.getpid()}.{os.urandom(8).hex()}"
    )
    try:
        os.replace(lock, retired)
        _fsync_directory(output)
        (retired / JOURNAL_NAME).unlink()
        _fsync_directory(retired)
        retired.rmdir()
        _fsync_directory(output)
    except OSError:
        fail("publication recovery lock could not be removed")


def _rollback_prepared_transaction(
    payload: dict[str, object], output: Path, *, replace: Replace = os.replace
) -> None:
    stage, backup = _validate_journal_paths(payload, output)
    names, source_bindings, old_bindings = _payload_bindings(payload)
    for name in names:
        source = stage / name
        destination = output / name
        backup_path = backup / name
        new_binding = source_bindings[name]
        old_binding = old_bindings.get(name)
        destination_candidates = (
            (new_binding, old_binding) if old_binding is not None else (new_binding,)
        )
        source_state = _binding_at(source, (new_binding,))
        destination_state = _binding_at(destination, destination_candidates)
        backup_state = _binding_at(
            backup_path, (old_binding,) if old_binding is not None else ()
        )
        if destination_state == new_binding:
            if source_state is not None:
                fail("staged release asset exists in two transaction locations")
            replace(destination, source)
            if _binding_at(source, (new_binding,)) != new_binding:
                fail("staged release asset could not be restored")
            destination_state = None
        elif source_state != new_binding:
            fail("staged release asset is missing from the transaction")

        if old_binding is None:
            if destination_state is not None or backup_state is not None:
                fail("unexpected prior release output blocks rollback")
            continue
        if destination_state == old_binding:
            if backup_state is not None:
                fail("prior release output exists in two transaction locations")
        elif backup_state == old_binding and destination_state is None:
            replace(backup_path, destination)
            if _binding_at(destination, (old_binding,)) != old_binding:
                fail("prior release output could not be restored")
        else:
            fail("prior release output is missing from the transaction")

    for name, binding in source_bindings.items():
        if _binding_at(stage / name, (binding,)) != binding:
            fail("staged release asset was not restored")
    for name, binding in old_bindings.items():
        if _binding_at(output / name, (binding,)) != binding:
            fail("prior release output was not restored")
    for name in names:
        if name not in old_bindings and (output / name).exists():
            fail("new release output remained after rollback")
    if backup.exists():
        try:
            backup.rmdir()
        except OSError:
            fail("publication rollback left an unexpected backup entry")
    _fsync_directory(stage)
    _fsync_directory(output)


def _finish_committed_transaction(
    payload: dict[str, object], output: Path
) -> None:
    stage, backup = _validate_journal_paths(payload, output)
    names, source_bindings, old_bindings = _payload_bindings(payload)
    for name in names:
        source = stage / name
        destination = output / name
        new_binding = source_bindings[name]
        old_binding = old_bindings.get(name)
        if source.exists() or source.is_symlink():
            fail("committed release still contains a staged asset")
        candidates = (
            (new_binding, old_binding) if old_binding is not None else (new_binding,)
        )
        if _binding_at(destination, candidates) != new_binding:
            fail("committed release output no longer matches its journal")
        backup_path = backup / name
        backup_state = _binding_at(
            backup_path, (old_binding,) if old_binding is not None else ()
        )
        if backup_state is not None:
            if old_binding is None or backup_state != old_binding:
                fail("committed release contains an unexpected backup")
            try:
                backup_path.unlink()
            except OSError:
                fail("committed release backup could not be removed")
    if backup.exists():
        try:
            backup.rmdir()
        except OSError:
            fail("committed release left an unexpected backup entry")
    _fsync_directory(stage)
    _fsync_directory(output)


def recover_interrupted_publication(output_directory: Path) -> bool:
    output = _canonical_directory(output_directory, "release output")
    lock = output / LOCK_NAME
    if not lock.exists() and not lock.is_symlink():
        return False
    lock = _canonical_directory(lock, "publication recovery lock")
    payload = _read_journal(lock)
    process_id = payload["processID"]
    if _process_is_alive(process_id):
        fail(f"release publication process {process_id} is still running")
    state = payload["state"]
    stage, backup = _validate_journal_paths(payload, output)
    if state == "initializing":
        if backup.exists() or backup.is_symlink():
            fail("initializing publication unexpectedly contains a backup")
    elif state == "prepared":
        _rollback_prepared_transaction(payload, output)
    else:
        _finish_committed_transaction(payload, output)
    _clear_journal_lock(output, lock)
    return True


def publish_release_files(
    stage_directory: Path,
    output_directory: Path,
    names: list[str],
    *,
    replace: Replace = os.replace,
    expected_sha256: dict[str, str] | None = None,
) -> None:
    stage = _canonical_directory(stage_directory, "publication stage")
    output = _canonical_directory(output_directory, "release output")
    if stage.parent != output:
        fail("publication stage must be a direct child of the release output")
    if stage.stat().st_dev != output.stat().st_dev:
        fail("publication stage and release output must share one filesystem")
    validated_names = [_validated_name(name) for name in names]
    if not validated_names or len(set(validated_names)) != len(validated_names):
        fail("release asset names must be nonempty and unique")
    expected = expected_sha256 or {}
    if not set(expected).issubset(validated_names) or any(
        re.fullmatch(r"[0-9a-f]{64}", digest) is None
        for digest in expected.values()
    ):
        fail("expected release digests must name staged assets and use SHA-256")

    lock = output / LOCK_NAME
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        fail("another release publication is already in progress")
    except OSError:
        fail("unable to acquire the release publication lock")

    backup = stage / BACKUP_NAME
    source_bindings: dict[str, FileBinding] = {}
    old_bindings: dict[str, FileBinding] = {}
    initial_payload = _journal_payload(
        state="initializing",
        process_id=os.getpid(),
        stage=stage,
        output=output,
        names=validated_names,
    )
    journal_written = False
    try:
        _write_journal(lock, initial_payload)
        journal_written = True
        for name in validated_names:
            source = stage / name
            source_bindings[name] = _file_binding(source)
            if (
                name in expected
                and source_bindings[name].sha256 != expected[name]
            ):
                fail("release asset does not match its expected digest")
            destination = output / name
            if destination.exists() or destination.is_symlink():
                old_bindings[name] = _file_binding(destination)

        prepared_payload = _journal_payload(
            state="prepared",
            process_id=os.getpid(),
            stage=stage,
            output=output,
            names=validated_names,
            source_bindings=source_bindings,
            old_bindings=old_bindings,
        )
        _fsync_directory(stage)
        _fsync_directory(output)
        _write_journal(lock, prepared_payload)
        backup.mkdir(mode=0o700)
        for name in validated_names:
            destination = output / name
            if name not in old_bindings:
                continue
            backup_path = backup / name
            replace(destination, backup_path)
            if _file_binding(backup_path) != old_bindings[name]:
                fail("existing release output changed while it was backed up")

        for name in validated_names:
            source = stage / name
            destination = output / name
            replace(source, destination)
            if _file_binding(destination) != source_bindings[name]:
                fail("published release asset differs from its staged bytes")
        _fsync_directory(output)
        committed_payload = dict(prepared_payload)
        committed_payload["state"] = "committed"
        _write_journal(lock, committed_payload)
        committed_payload = _read_journal(lock)
    except BaseException as error:
        try:
            if not journal_written:
                lock.rmdir()
                raise
            persisted = _read_journal(lock)
            state = persisted["state"]
            if state == "initializing":
                if backup.exists():
                    backup.rmdir()
                _clear_journal_lock(output, lock)
            elif state == "prepared":
                _rollback_prepared_transaction(persisted, output, replace=replace)
                _clear_journal_lock(output, lock)
            else:
                raise PublicationError(
                    "release publication committed but cleanup requires recovery"
                ) from error
        except BaseException as rollback_error:
            if rollback_error is error:
                raise
            raise PublicationError(
                "release publication failed and recovery state was preserved"
            ) from rollback_error
        if not isinstance(error, Exception):
            raise
        if isinstance(error, PublicationError) and state == "initializing":
            raise error
        raise PublicationError("release publication failed and was rolled back") from error

    _finish_committed_transaction(committed_payload, output)
    _clear_journal_lock(output, lock)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage-dir", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--file", action="append", default=[])
    parser.add_argument("--expected-sha256", action="append", default=[])
    parser.add_argument("--recover-only", action="store_true")
    return parser.parse_args(argv)


def _parse_expected_digests(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        name, separator, digest = value.partition("=")
        if not separator or name in result:
            fail("expected release digests must use unique NAME=SHA256 values")
        result[name] = digest
    return result


def main(argv: list[str]) -> int:
    arguments = parse_args(argv)
    try:
        if arguments.recover_only:
            if arguments.stage_dir or arguments.file or arguments.expected_sha256:
                fail("--recover-only accepts only --output-dir")
            recovered = recover_interrupted_publication(arguments.output_dir)
            print(
                "Interrupted release publication recovered."
                if recovered
                else "No interrupted release publication found."
            )
            return 0
        if arguments.stage_dir is None:
            fail("--stage-dir is required when publishing release assets")
        publish_release_files(
            arguments.stage_dir,
            arguments.output_dir,
            arguments.file,
            expected_sha256=_parse_expected_digests(arguments.expected_sha256),
        )
    except PublicationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Release assets published transactionally.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
