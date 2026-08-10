#!/usr/bin/env python3
"""Snapshot and validate a Mac App Store provisioning profile."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import os
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Callable, NamedTuple, NoReturn


CommandRunner = Callable[[list[str]], subprocess.CompletedProcess[bytes]]
TEAM_ID_PATTERN = re.compile(r"[A-Z0-9]{10}")
CERTIFICATE_SHA1_PATTERN = re.compile(r"[0-9A-Fa-f]{40}")
MAX_PROFILE_BYTES = 1024 * 1024
COPY_BUFFER_BYTES = 64 * 1024
DIRECTORY_OPEN_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
SOURCE_OPEN_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
OUTPUT_OPEN_FLAGS = os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_CREAT | os.O_EXCL
APPLE_PROVISIONING_PROFILE_SIGNING_OID_DER = (
    b"\x06\x09\x2a\x86\x48\x86\xf7\x63\x64\x04\x0b"
)


class ProfileValidationError(RuntimeError):
    """The selected provisioning profile is not safe for this MAS build."""


class BoundParent(NamedTuple):
    path: Path
    leaf: str
    descriptors: tuple[int, ...]
    components: tuple[str, ...]
    identities: tuple[tuple[int, int, int, int], ...]


def _run_security(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(arguments, check=False, capture_output=True, timeout=30)


def _fail(message: str) -> NoReturn:
    raise ProfileValidationError(message)


def _directory_identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_uid,
    )


def _file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _file_object(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def _require_normalized_absolute_path(raw_path: str, *, label: str) -> Path:
    if (
        not isinstance(raw_path, str)
        or not os.path.isabs(raw_path)
        or os.path.normpath(raw_path) != raw_path
        or raw_path == os.path.sep
    ):
        _fail(f"{label} path must be absolute and normalized")
    return Path(raw_path)


def _bind_parent(raw_path: str, *, label: str) -> BoundParent:
    path = _require_normalized_absolute_path(raw_path, label=label)
    parts = path.parts
    if len(parts) < 2 or parts[-1] in {"", ".", ".."}:
        _fail(f"{label} path is invalid")

    descriptors: list[int] = []
    components: list[str] = []
    identities: list[tuple[int, int, int, int]] = []
    try:
        descriptor = os.open(os.path.sep, DIRECTORY_OPEN_FLAGS)
        descriptors.append(descriptor)
        identities.append(_directory_identity(os.fstat(descriptor)))
        for component in parts[1:-1]:
            named = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISDIR(named.st_mode):
                _fail(f"{label} path contains a symlink or non-directory")
            child = os.open(component, DIRECTORY_OPEN_FLAGS, dir_fd=descriptor)
            opened = os.fstat(child)
            if _directory_identity(named) != _directory_identity(opened):
                os.close(child)
                _fail(f"{label} path changed while it was bound")
            components.append(component)
            descriptors.append(child)
            identities.append(_directory_identity(opened))
            descriptor = child
        return BoundParent(
            path=path,
            leaf=parts[-1],
            descriptors=tuple(descriptors),
            components=tuple(components),
            identities=tuple(identities),
        )
    except ProfileValidationError:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        raise
    except (OSError, ValueError):
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        _fail(f"{label} path is missing or unsafe")


def _close_parent(binding: BoundParent | None) -> None:
    if binding is None:
        return
    for descriptor in reversed(binding.descriptors):
        try:
            os.close(descriptor)
        except OSError:
            pass


def _require_parent_stable(binding: BoundParent, *, label: str) -> None:
    try:
        for index, descriptor in enumerate(binding.descriptors):
            if _directory_identity(os.fstat(descriptor)) != binding.identities[index]:
                _fail(f"{label} path changed during validation")
            if index > 0:
                named = os.stat(
                    binding.components[index - 1],
                    dir_fd=binding.descriptors[index - 1],
                    follow_symlinks=False,
                )
                if _directory_identity(named) != binding.identities[index]:
                    _fail(f"{label} path changed during validation")
    except (OSError, ValueError):
        _fail(f"{label} path changed during validation")


def _open_source(binding: BoundParent) -> tuple[int, tuple[int, ...]]:
    parent_descriptor = binding.descriptors[-1]
    try:
        named = os.stat(
            binding.leaf,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISREG(named.st_mode)
            or named.st_nlink != 1
            or named.st_size > MAX_PROFILE_BYTES
        ):
            _fail("input profile must be a single-link regular file no larger than 1 MiB")
        descriptor = os.open(
            binding.leaf,
            SOURCE_OPEN_FLAGS,
            dir_fd=parent_descriptor,
        )
        opened = os.fstat(descriptor)
        if _file_identity(opened) != _file_identity(named):
            os.close(descriptor)
            _fail("input profile changed before it was opened")
        return descriptor, _file_identity(opened)
    except ProfileValidationError:
        raise
    except (OSError, ValueError):
        _fail("input profile is missing or unsafe")


def _create_output(binding: BoundParent) -> tuple[int, tuple[int, int]]:
    try:
        descriptor = os.open(
            binding.leaf,
            OUTPUT_OPEN_FLAGS,
            0o600,
            dir_fd=binding.descriptors[-1],
        )
    except (OSError, ValueError):
        _fail("output profile already exists or cannot be created")
    created_object: tuple[int, int] | None = None
    try:
        created_object = _file_object(os.fstat(descriptor))
        os.fchmod(descriptor, 0o600)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_uid != os.geteuid()
        ):
            _fail("output profile is not a private single-link regular file")
        return descriptor, _file_object(metadata)
    except ProfileValidationError:
        os.close(descriptor)
        _cleanup_created_output(binding, created_object)
        raise
    except OSError:
        os.close(descriptor)
        _cleanup_created_output(binding, created_object)
        _fail("output profile could not be secured")


def _read(descriptor: int, count: int) -> bytes:
    while True:
        try:
            return os.read(descriptor, count)
        except InterruptedError:
            continue


def _write_all(descriptor: int, block: bytes) -> None:
    remaining = memoryview(block)
    while remaining:
        try:
            written = os.write(descriptor, remaining)
        except InterruptedError:
            continue
        if written <= 0 or written > len(remaining):
            _fail("output profile could not be written")
        remaining = remaining[written:]


def _copy_bounded(source: int, output: int) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    while True:
        remaining = MAX_PROFILE_BYTES + 1 - total
        if remaining <= 0:
            _fail("input profile exceeds the 1 MiB limit")
        block = _read(source, min(COPY_BUFFER_BYTES, remaining))
        if not block:
            break
        total += len(block)
        if total > MAX_PROFILE_BYTES:
            _fail("input profile exceeds the 1 MiB limit")
        digest.update(block)
        _write_all(output, block)
    os.fsync(output)
    return digest.hexdigest(), total


def _digest_descriptor(descriptor: int) -> tuple[str, int]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    total = 0
    while True:
        remaining = MAX_PROFILE_BYTES + 1 - total
        if remaining <= 0:
            _fail("provisioning profile changed or exceeds its size limit")
        block = _read(descriptor, min(COPY_BUFFER_BYTES, remaining))
        if not block:
            break
        total += len(block)
        if total > MAX_PROFILE_BYTES:
            _fail("provisioning profile changed or exceeds its size limit")
        digest.update(block)
    return digest.hexdigest(), total


def _read_descriptor_bytes(descriptor: int) -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    blocks: list[bytes] = []
    total = 0
    while True:
        remaining = MAX_PROFILE_BYTES + 1 - total
        if remaining <= 0:
            _fail("provisioning profile exceeds its size limit")
        block = _read(descriptor, min(COPY_BUFFER_BYTES, remaining))
        if not block:
            break
        blocks.append(block)
        total += len(block)
        if total > MAX_PROFILE_BYTES:
            _fail("provisioning profile exceeds its size limit")
    return b"".join(blocks)


def _decode_trusted_cms(message: bytes) -> bytes:
    """Verify one CMS signer with macOS trust services and return its content."""

    security_path = "/System/Library/Frameworks/Security.framework/Security"
    core_foundation_path = (
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    )
    decoder = ctypes.c_void_p()
    policy = ctypes.c_void_p()
    trust = ctypes.c_void_p()
    certificate = ctypes.c_void_p()
    certificate_data = ctypes.c_void_p()
    content = ctypes.c_void_p()
    try:
        security = ctypes.CDLL(security_path)
        core_foundation = ctypes.CDLL(core_foundation_path)
        void_pointer = ctypes.c_void_p

        security.CMSDecoderCreate.argtypes = [ctypes.POINTER(void_pointer)]
        security.CMSDecoderCreate.restype = ctypes.c_int32
        security.CMSDecoderUpdateMessage.argtypes = [
            void_pointer,
            void_pointer,
            ctypes.c_size_t,
        ]
        security.CMSDecoderUpdateMessage.restype = ctypes.c_int32
        security.CMSDecoderFinalizeMessage.argtypes = [void_pointer]
        security.CMSDecoderFinalizeMessage.restype = ctypes.c_int32
        security.CMSDecoderGetNumSigners.argtypes = [
            void_pointer,
            ctypes.POINTER(ctypes.c_size_t),
        ]
        security.CMSDecoderGetNumSigners.restype = ctypes.c_int32
        security.SecPolicyCreateBasicX509.argtypes = []
        security.SecPolicyCreateBasicX509.restype = void_pointer
        security.CMSDecoderCopySignerStatus.argtypes = [
            void_pointer,
            ctypes.c_size_t,
            void_pointer,
            ctypes.c_bool,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(void_pointer),
            ctypes.POINTER(ctypes.c_int32),
        ]
        security.CMSDecoderCopySignerStatus.restype = ctypes.c_int32
        security.CMSDecoderCopySignerCert.argtypes = [
            void_pointer,
            ctypes.c_size_t,
            ctypes.POINTER(void_pointer),
        ]
        security.CMSDecoderCopySignerCert.restype = ctypes.c_int32
        security.SecCertificateCopyData.argtypes = [void_pointer]
        security.SecCertificateCopyData.restype = void_pointer
        security.CMSDecoderCopyContent.argtypes = [
            void_pointer,
            ctypes.POINTER(void_pointer),
        ]
        security.CMSDecoderCopyContent.restype = ctypes.c_int32
        core_foundation.CFDataGetLength.argtypes = [void_pointer]
        core_foundation.CFDataGetLength.restype = ctypes.c_long
        core_foundation.CFDataGetBytePtr.argtypes = [void_pointer]
        core_foundation.CFDataGetBytePtr.restype = ctypes.POINTER(ctypes.c_ubyte)
        core_foundation.CFRelease.argtypes = [void_pointer]
        core_foundation.CFRelease.restype = None

        if security.CMSDecoderCreate(ctypes.byref(decoder)) != 0 or not decoder:
            _fail("provisioning profile signature could not be verified")
        message_buffer = ctypes.create_string_buffer(message)
        if (
            security.CMSDecoderUpdateMessage(
                decoder,
                ctypes.cast(message_buffer, void_pointer),
                len(message),
            )
            != 0
            or security.CMSDecoderFinalizeMessage(decoder) != 0
        ):
            _fail("provisioning profile signature could not be verified")

        signer_count = ctypes.c_size_t()
        if (
            security.CMSDecoderGetNumSigners(
                decoder, ctypes.byref(signer_count)
            )
            != 0
            or signer_count.value != 1
        ):
            _fail("provisioning profile must contain one trusted signer")
        policy = ctypes.c_void_p(security.SecPolicyCreateBasicX509())
        if not policy:
            _fail("provisioning profile trust policy is unavailable")
        signer_status = ctypes.c_uint32()
        verification_result = ctypes.c_int32()
        if (
            security.CMSDecoderCopySignerStatus(
                decoder,
                0,
                policy,
                True,
                ctypes.byref(signer_status),
                ctypes.byref(trust),
                ctypes.byref(verification_result),
            )
            != 0
            or signer_status.value != 1
        ):
            _fail("provisioning profile does not have a trusted valid signature")

        if (
            security.CMSDecoderCopySignerCert(
                decoder, 0, ctypes.byref(certificate)
            )
            != 0
            or not certificate
        ):
            _fail("provisioning profile signer certificate is unavailable")
        certificate_data = ctypes.c_void_p(
            security.SecCertificateCopyData(certificate)
        )
        if not certificate_data:
            _fail("provisioning profile signer certificate is unavailable")
        certificate_length = core_foundation.CFDataGetLength(certificate_data)
        certificate_pointer = core_foundation.CFDataGetBytePtr(certificate_data)
        if certificate_length <= 0 or not certificate_pointer:
            _fail("provisioning profile signer certificate is invalid")
        certificate_bytes = ctypes.string_at(
            certificate_pointer, certificate_length
        )
        if APPLE_PROVISIONING_PROFILE_SIGNING_OID_DER not in certificate_bytes:
            _fail("provisioning profile was not signed by Apple profile services")

        if (
            security.CMSDecoderCopyContent(decoder, ctypes.byref(content)) != 0
            or not content
        ):
            _fail("provisioning profile content could not be decoded")
        content_length = core_foundation.CFDataGetLength(content)
        content_pointer = core_foundation.CFDataGetBytePtr(content)
        if (
            content_length <= 0
            or content_length > MAX_PROFILE_BYTES
            or not content_pointer
        ):
            _fail("provisioning profile content is invalid")
        return ctypes.string_at(content_pointer, content_length)
    except ProfileValidationError:
        raise
    except (AttributeError, OSError, TypeError, ValueError):
        _fail("provisioning profile signature could not be verified")
    finally:
        release = locals().get("core_foundation")
        if release is not None:
            for reference in (
                content,
                certificate_data,
                certificate,
                trust,
                policy,
                decoder,
            ):
                if reference:
                    release.CFRelease(reference)


def _named_file_metadata(binding: BoundParent) -> os.stat_result:
    return os.stat(
        binding.leaf,
        dir_fd=binding.descriptors[-1],
        follow_symlinks=False,
    )


def _require_source_stable(
    binding: BoundParent,
    descriptor: int,
    initial_identity: tuple[int, ...],
    expected_digest: str,
    expected_size: int,
) -> None:
    try:
        before = os.fstat(descriptor)
        named_before = _named_file_metadata(binding)
        if (
            _file_identity(before) != initial_identity
            or _file_identity(named_before) != initial_identity
        ):
            _fail("input profile changed during validation")
        digest, size = _digest_descriptor(descriptor)
        after = os.fstat(descriptor)
        named_after = _named_file_metadata(binding)
        if (
            digest != expected_digest
            or size != expected_size
            or _file_identity(after) != initial_identity
            or _file_identity(named_after) != initial_identity
        ):
            _fail("input profile changed during validation")
    except ProfileValidationError:
        raise
    except (OSError, ValueError):
        _fail("input profile changed during validation")


def _require_output_stable(
    binding: BoundParent,
    descriptor: int,
    stable_identity: tuple[int, ...],
    expected_digest: str,
    expected_size: int,
) -> None:
    try:
        before = os.fstat(descriptor)
        named_before = _named_file_metadata(binding)
        if (
            _file_identity(before) != stable_identity
            or _file_identity(named_before) != stable_identity
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_uid != os.geteuid()
        ):
            _fail("output profile changed during validation")
        digest, size = _digest_descriptor(descriptor)
        after = os.fstat(descriptor)
        named_after = _named_file_metadata(binding)
        if (
            digest != expected_digest
            or size != expected_size
            or _file_identity(after) != stable_identity
            or _file_identity(named_after) != stable_identity
        ):
            _fail("output profile changed during validation")
    except ProfileValidationError:
        raise
    except (OSError, ValueError):
        _fail("output profile changed during validation")


def _cleanup_created_output(
    binding: BoundParent | None,
    created_object: tuple[int, int] | None,
) -> None:
    if binding is None or created_object is None:
        return
    try:
        named = _named_file_metadata(binding)
        if _file_object(named) == created_object:
            os.unlink(binding.leaf, dir_fd=binding.descriptors[-1])
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _validate_profile(
    profile: object,
    *,
    expected_team_id: str,
    expected_bundle_identifier: str,
    certificate_sha1: str,
) -> None:
    if not isinstance(profile, dict):
        _fail("decoded provisioning profile must be a dictionary")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        _fail("provisioning profile expiration is invalid")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    else:
        expiration = expiration.astimezone(dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        _fail("provisioning profile is expired")

    for key in ("TeamIdentifier", "ApplicationIdentifierPrefix"):
        identifiers = profile.get(key)
        if not isinstance(identifiers, list) or expected_team_id not in identifiers:
            _fail("provisioning profile team does not match")

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        _fail("provisioning profile entitlements are invalid")
    expected_application_identifier = (
        f"{expected_team_id}.{expected_bundle_identifier}"
    )
    if (
        entitlements.get("com.apple.application-identifier")
        != expected_application_identifier
        or entitlements.get("com.apple.developer.team-identifier")
        != expected_team_id
    ):
        _fail("provisioning profile application does not match")
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        _fail("provisioning profile does not require the app sandbox")
    if (
        entitlements.get("com.apple.security.files.user-selected.read-write")
        is not True
    ):
        _fail("provisioning profile does not allow selected file access")
    if "get-task-allow" in entitlements and entitlements["get-task-allow"] is not False:
        _fail("provisioning profile allows debugging")

    if "ProvisionedDevices" in profile:
        _fail("provisioning profile is not for App Store distribution")
    if "ProvisionsAllDevices" in profile and profile["ProvisionsAllDevices"] is not False:
        _fail("provisioning profile is not for App Store distribution")

    platforms = profile.get("Platform")
    if (
        not isinstance(platforms, list)
        or not platforms
        or any(platform not in {"macOS", "OSX"} for platform in platforms)
    ):
        _fail("provisioning profile is not for macOS")

    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not any(
        isinstance(certificate, bytes)
        and hashlib.sha1(certificate).hexdigest().lower() == certificate_sha1.lower()
        for certificate in certificates
    ):
        _fail("provisioning profile does not contain the signing certificate")


def validate_and_snapshot(
    *,
    input_profile: str,
    output_profile: str,
    expected_team_id: str,
    expected_bundle_identifier: str,
    certificate_sha1: str,
    command_runner: CommandRunner | None = None,
) -> None:
    if TEAM_ID_PATTERN.fullmatch(expected_team_id) is None:
        _fail("expected team identifier is invalid")
    if not expected_bundle_identifier:
        _fail("expected bundle identifier is invalid")
    if CERTIFICATE_SHA1_PATTERN.fullmatch(certificate_sha1) is None:
        _fail("signing certificate SHA-1 is invalid")

    source_parent: BoundParent | None = None
    output_parent: BoundParent | None = None
    source_descriptor = -1
    output_descriptor = -1
    created_object: tuple[int, int] | None = None
    try:
        source_parent = _bind_parent(input_profile, label="input profile")
        output_parent = _bind_parent(output_profile, label="output profile")
        _require_parent_stable(source_parent, label="input profile")
        _require_parent_stable(output_parent, label="output profile")

        source_descriptor, source_identity = _open_source(source_parent)
        output_descriptor, created_object = _create_output(output_parent)
        copied_digest, copied_size = _copy_bounded(
            source_descriptor, output_descriptor
        )
        output_identity = _file_identity(os.fstat(output_descriptor))

        _require_source_stable(
            source_parent,
            source_descriptor,
            source_identity,
            copied_digest,
            copied_size,
        )
        _require_output_stable(
            output_parent,
            output_descriptor,
            output_identity,
            copied_digest,
            copied_size,
        )
        _require_parent_stable(source_parent, label="input profile")
        _require_parent_stable(output_parent, label="output profile")

        if command_runner is None:
            profile_bytes = _decode_trusted_cms(
                _read_descriptor_bytes(output_descriptor)
            )
        else:
            arguments = ["/usr/bin/security", "cms", "-D", "-i", output_profile]
            try:
                result = command_runner(arguments)
            except (OSError, subprocess.SubprocessError):
                _fail("provisioning profile could not be decoded")
            if (
                result.returncode != 0
                or not isinstance(result.stdout, bytes)
                or not result.stdout
                or len(result.stdout) > MAX_PROFILE_BYTES
            ):
                _fail("provisioning profile could not be decoded")
            profile_bytes = result.stdout
        try:
            profile = plistlib.loads(profile_bytes)
        except (ValueError, plistlib.InvalidFileException):
            _fail("provisioning profile could not be decoded")
        _validate_profile(
            profile,
            expected_team_id=expected_team_id,
            expected_bundle_identifier=expected_bundle_identifier,
            certificate_sha1=certificate_sha1,
        )
        _require_source_stable(
            source_parent,
            source_descriptor,
            source_identity,
            copied_digest,
            copied_size,
        )
        _require_output_stable(
            output_parent,
            output_descriptor,
            output_identity,
            copied_digest,
            copied_size,
        )
        _require_parent_stable(source_parent, label="input profile")
        _require_parent_stable(output_parent, label="output profile")
    except ProfileValidationError:
        _cleanup_created_output(output_parent, created_object)
        raise
    except (OSError, ValueError):
        _cleanup_created_output(output_parent, created_object)
        _fail("provisioning profile files changed or could not be read")
    finally:
        if output_descriptor >= 0:
            try:
                os.close(output_descriptor)
            except OSError:
                pass
        if source_descriptor >= 0:
            try:
                os.close(source_descriptor)
            except OSError:
                pass
        _close_parent(output_parent)
        _close_parent(source_parent)


def parse_arguments(arguments: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and privately snapshot a MAS provisioning profile."
    )
    parser.add_argument("--input-profile", required=True)
    parser.add_argument("--output-profile", required=True)
    parser.add_argument("--team-identifier", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--certificate-sha1", required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_arguments(arguments)
    try:
        validate_and_snapshot(
            input_profile=options.input_profile,
            output_profile=options.output_profile,
            expected_team_id=options.team_identifier,
            expected_bundle_identifier=options.bundle_identifier,
            certificate_sha1=options.certificate_sha1,
        )
    except ProfileValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("MAS provisioning profile validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
