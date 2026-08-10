#!/usr/bin/env python3
"""Hermetic tests for the MAS provisioning-profile validator."""

from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import io
import os
import plistlib
import stat
import subprocess
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Callable
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/release/validate_mas_provisioning_profile.py"
TEAM_ID = "A1B2C3D4E5"
BUNDLE_ID = "com.easysplat.app"
CERTIFICATE = b"fixture Apple Distribution certificate"
CERTIFICATE_SHA1 = hashlib.sha1(CERTIFICATE).hexdigest().upper()


class CMSRunner:
    def __init__(
        self,
        profile: object,
        *,
        before_return: Callable[[Path], None] | None = None,
    ) -> None:
        self.profile = profile
        self.before_return = before_return
        self.calls: list[list[str]] = []
        self.snapshot_bytes: bytes | None = None

    def __call__(self, arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
        self.calls.append(arguments)
        snapshot = Path(arguments[-1])
        self.snapshot_bytes = snapshot.read_bytes()
        if self.before_return is not None:
            self.before_return(snapshot)
        return subprocess.CompletedProcess(
            arguments,
            0,
            plistlib.dumps(self.profile),
            b"",
        )


class RawCMSRunner:
    def __init__(self, *, returncode: int = 0, stdout: bytes = b"") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.calls: list[list[str]] = []

    def __call__(self, arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
        self.calls.append(arguments)
        return subprocess.CompletedProcess(
            arguments,
            self.returncode,
            self.stdout,
            b"fixture security failure details that must not be exposed",
        )


class ValidateMasProvisioningProfileTests(unittest.TestCase):
    def load_module(self):
        self.assertTrue(MODULE_PATH.is_file(), "provisioning-profile validator is missing")
        spec = importlib.util.spec_from_file_location(
            "validate_mas_provisioning_profile", MODULE_PATH
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def valid_profile(self) -> dict[str, object]:
        return {
            "ApplicationIdentifierPrefix": [TEAM_ID],
            "DeveloperCertificates": [CERTIFICATE],
            "Entitlements": {
                "com.apple.application-identifier": f"{TEAM_ID}.{BUNDLE_ID}",
                "com.apple.developer.team-identifier": TEAM_ID,
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.user-selected.read-write": True,
            },
            "ExpirationDate": dt.datetime(2099, 1, 1),
            "Name": "Unknown harmless metadata is allowed",
            "Platform": ["OSX"],
            "TeamIdentifier": [TEAM_ID],
            "UUID": "00000000-0000-0000-0000-000000000000",
        }

    def assert_profile_rejected(
        self,
        module,
        profile: object,
        *,
        certificate_sha1: str = CERTIFICATE_SHA1,
        runner: Callable[[list[str]], subprocess.CompletedProcess[bytes]] | None = None,
    ) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            selected_runner = runner or CMSRunner(profile)

            with self.assertRaises(module.ProfileValidationError) as caught:
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=certificate_sha1,
                    command_runner=selected_runner,
                )

            self.assertFalse(output.exists(), "failed validation left its output behind")
            message = str(caught.exception)
            self.assertLessEqual(len(message), 100)
            self.assertNotIn(str(root), message)
            self.assertNotIn("fixture security failure details", message)

    def test_success_snapshots_exact_bytes_and_validates_private_output(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source_bytes = b"opaque caller-selected CMS bytes\x00\xff"
            source.write_bytes(source_bytes)
            runner = CMSRunner(self.valid_profile())

            module.validate_and_snapshot(
                input_profile=str(source),
                output_profile=str(output),
                expected_team_id=TEAM_ID,
                expected_bundle_identifier=BUNDLE_ID,
                certificate_sha1=CERTIFICATE_SHA1,
                command_runner=runner,
            )

            self.assertEqual(output.read_bytes(), source_bytes)
            self.assertEqual(runner.snapshot_bytes, source_bytes)
            self.assertEqual(
                runner.calls,
                [["/usr/bin/security", "cms", "-D", "-i", str(output)]],
            )
            metadata = output.lstat()
            self.assertTrue(stat.S_ISREG(metadata.st_mode))
            self.assertEqual(metadata.st_nlink, 1)
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
            self.assertEqual(metadata.st_uid, os.geteuid())

    def test_rejects_malformed_cms_and_plist_payloads(self) -> None:
        module = self.load_module()
        fixtures = {
            "cms command failure": RawCMSRunner(returncode=1),
            "malformed plist": RawCMSRunner(stdout=b"not a plist"),
            "plist array": CMSRunner([self.valid_profile()]),
        }
        for label, runner in fixtures.items():
            with self.subTest(label=label):
                self.assert_profile_rejected(module, {}, runner=runner)

    def test_default_verifier_rejects_a_self_signed_cms_profile(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            key = root / "forged-key.pem"
            certificate_pem = root / "forged-certificate.pem"
            certificate_der = root / "forged-certificate.der"
            payload = root / "forged-profile.plist"
            source = root / "forged.provisionprofile"
            output = root / "validated.provisionprofile"

            subprocess.run(
                [
                    "/usr/bin/openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-subj",
                    "/CN=Forged Provisioning Profile Signer",
                    "-keyout",
                    str(key),
                    "-out",
                    str(certificate_pem),
                    "-days",
                    "1",
                ],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [
                    "/usr/bin/openssl",
                    "x509",
                    "-in",
                    str(certificate_pem),
                    "-outform",
                    "DER",
                    "-out",
                    str(certificate_der),
                ],
                check=True,
                capture_output=True,
            )
            profile = self.valid_profile()
            forged_certificate = certificate_der.read_bytes()
            profile["DeveloperCertificates"] = [forged_certificate]
            payload.write_bytes(plistlib.dumps(profile))
            subprocess.run(
                [
                    "/usr/bin/openssl",
                    "cms",
                    "-sign",
                    "-binary",
                    "-nodetach",
                    "-in",
                    str(payload),
                    "-signer",
                    str(certificate_pem),
                    "-inkey",
                    str(key),
                    "-outform",
                    "DER",
                    "-out",
                    str(source),
                ],
                check=True,
                capture_output=True,
            )

            with self.assertRaisesRegex(
                module.ProfileValidationError,
                "signature|trusted|provisioning profile",
            ):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=hashlib.sha1(forged_certificate).hexdigest(),
                )

            self.assertFalse(output.exists())

    def test_rejects_expired_or_invalid_expiration(self) -> None:
        module = self.load_module()
        for label, expiration in {
            "expired": dt.datetime(2000, 1, 1),
            "missing": None,
            "wrong type": "2099-01-01T00:00:00Z",
        }.items():
            profile = self.valid_profile()
            if expiration is None:
                del profile["ExpirationDate"]
            else:
                profile["ExpirationDate"] = expiration
            with self.subTest(label=label):
                self.assert_profile_rejected(module, profile)

    def test_rejects_wrong_team_and_application_bindings(self) -> None:
        module = self.load_module()
        fixtures: dict[str, dict[str, object]] = {}

        missing_team = self.valid_profile()
        missing_team["TeamIdentifier"] = ["Z9Y8X7W6V5"]
        fixtures["TeamIdentifier"] = missing_team

        missing_prefix = self.valid_profile()
        missing_prefix["ApplicationIdentifierPrefix"] = ["Z9Y8X7W6V5"]
        fixtures["ApplicationIdentifierPrefix"] = missing_prefix

        wrong_application = self.valid_profile()
        wrong_application["Entitlements"] = {
            **wrong_application["Entitlements"],  # type: ignore[arg-type]
            "com.apple.application-identifier": f"{TEAM_ID}.com.example.wrong",
        }
        fixtures["application identifier"] = wrong_application

        wrong_entitlement_team = self.valid_profile()
        wrong_entitlement_team["Entitlements"] = {
            **wrong_entitlement_team["Entitlements"],  # type: ignore[arg-type]
            "com.apple.developer.team-identifier": "Z9Y8X7W6V5",
        }
        fixtures["entitlement team"] = wrong_entitlement_team

        for label, profile in fixtures.items():
            with self.subTest(label=label):
                self.assert_profile_rejected(module, profile)

    def test_rejects_wrong_certificate(self) -> None:
        module = self.load_module()
        self.assert_profile_rejected(
            module,
            self.valid_profile(),
            certificate_sha1="0" * 40,
        )

    def test_rejects_development_or_non_store_channels(self) -> None:
        module = self.load_module()
        provisioned = self.valid_profile()
        provisioned["ProvisionedDevices"] = ["device-id"]
        all_devices = self.valid_profile()
        all_devices["ProvisionsAllDevices"] = True
        malformed_channel = self.valid_profile()
        malformed_channel["ProvisionsAllDevices"] = "false"

        for label, profile in {
            "provisioned devices": provisioned,
            "all devices": all_devices,
            "malformed all-devices flag": malformed_channel,
        }.items():
            with self.subTest(label=label):
                self.assert_profile_rejected(module, profile)

    def test_rejects_wrong_platform(self) -> None:
        module = self.load_module()
        profile = self.valid_profile()
        profile["Platform"] = ["iOS"]
        self.assert_profile_rejected(module, profile)

    def test_accepts_macos_platform_spelling(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            profile = self.valid_profile()
            profile["Platform"] = ["macOS"]

            module.validate_and_snapshot(
                input_profile=str(source),
                output_profile=str(output),
                expected_team_id=TEAM_ID,
                expected_bundle_identifier=BUNDLE_ID,
                certificate_sha1=CERTIFICATE_SHA1.lower(),
                command_runner=CMSRunner(profile),
            )

            self.assertTrue(output.is_file())

    def test_rejects_unsafe_entitlements(self) -> None:
        module = self.load_module()
        fixtures: dict[str, dict[str, object]] = {}
        for label, key, value in (
            ("sandbox disabled", "com.apple.security.app-sandbox", False),
            (
                "file access disabled",
                "com.apple.security.files.user-selected.read-write",
                False,
            ),
            ("debugging enabled", "get-task-allow", True),
        ):
            profile = self.valid_profile()
            entitlements = dict(profile["Entitlements"])  # type: ignore[arg-type]
            if value is None:
                del entitlements[key]
            else:
                entitlements[key] = value
            profile["Entitlements"] = entitlements
            fixtures[label] = profile

        for label, profile in fixtures.items():
            with self.subTest(label=label):
                self.assert_profile_rejected(module, profile)

    def test_accepts_explicitly_false_get_task_allow(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            profile = self.valid_profile()
            entitlements = dict(profile["Entitlements"])  # type: ignore[arg-type]
            entitlements["get-task-allow"] = False
            profile["Entitlements"] = entitlements

            module.validate_and_snapshot(
                input_profile=str(source),
                output_profile=str(output),
                expected_team_id=TEAM_ID,
                expected_bundle_identifier=BUNDLE_ID,
                certificate_sha1=CERTIFICATE_SHA1,
                command_runner=CMSRunner(profile),
            )

            self.assertTrue(output.is_file())

    def test_accepts_store_profile_without_app_managed_entitlements(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            profile = self.valid_profile()
            entitlements = dict(profile["Entitlements"])  # type: ignore[arg-type]
            del entitlements["com.apple.security.app-sandbox"]
            del entitlements["com.apple.security.files.user-selected.read-write"]
            profile["Entitlements"] = entitlements

            module.validate_and_snapshot(
                input_profile=str(source),
                output_profile=str(output),
                expected_team_id=TEAM_ID,
                expected_bundle_identifier=BUNDLE_ID,
                certificate_sha1=CERTIFICATE_SHA1,
                command_runner=CMSRunner(profile),
            )

            self.assertTrue(output.is_file())

    def test_rejects_relative_or_lexically_unnormalized_paths(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            (root / "child").mkdir()

            cases = {
                "relative input": (source.name, str(root / "one.out")),
                "relative output": (str(source), "relative-output.provisionprofile"),
                "unnormalized input": (
                    str(root / "child" / ".." / source.name),
                    str(root / "two.out"),
                ),
                "unnormalized output": (
                    str(source),
                    str(root / "child" / ".." / "three.out"),
                ),
            }
            original_directory = Path.cwd()
            os.chdir(root)
            try:
                for label, (selected_source, selected_output) in cases.items():
                    output = Path(selected_output)
                    with self.subTest(label=label):
                        with self.assertRaises(module.ProfileValidationError):
                            module.validate_and_snapshot(
                                input_profile=selected_source,
                                output_profile=selected_output,
                                expected_team_id=TEAM_ID,
                                expected_bundle_identifier=BUNDLE_ID,
                                certificate_sha1=CERTIFICATE_SHA1,
                                command_runner=CMSRunner(self.valid_profile()),
                            )
                        self.assertFalse(output.exists())
            finally:
                os.chdir(original_directory)

    def test_rejects_symlinked_input_or_output_ancestry(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            real_input_parent = root / "real-input"
            real_input_parent.mkdir()
            source = real_input_parent / "selected.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            input_link = root / "input-link"
            input_link.symlink_to(real_input_parent, target_is_directory=True)

            output = root / "input-ancestor.out"
            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(input_link / source.name),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(self.valid_profile()),
                )
            self.assertFalse(output.exists())

            output_parent = root / "real-output"
            output_parent.mkdir()
            output_link = root / "output-link"
            output_link.symlink_to(output_parent, target_is_directory=True)
            linked_output = output_link / "validated.provisionprofile"
            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(linked_output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(self.valid_profile()),
                )
            self.assertFalse((output_parent / linked_output.name).exists())

    def test_rejects_symlink_hardlink_and_fifo_inputs(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            symlink_target = root / "symlink-target.provisionprofile"
            symlink_target.write_bytes(b"opaque symlink target")
            symlink = root / "symlink.provisionprofile"
            symlink.symlink_to(symlink_target)
            ordinary = root / "ordinary.provisionprofile"
            ordinary.write_bytes(b"opaque hardlink target")
            hardlink = root / "hardlink.provisionprofile"
            os.link(ordinary, hardlink)
            fifo = root / "fifo.provisionprofile"
            os.mkfifo(fifo, 0o600)

            fifo_guard = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            os.write(fifo_guard, b"fifo fixture")
            fifo_timer = threading.Timer(0.1, os.close, args=(fifo_guard,))
            fifo_timer.start()
            try:
                for label, source in {
                    "symlink": symlink,
                    "hardlink": hardlink,
                    "fifo": fifo,
                }.items():
                    output = root / f"{label}.out"
                    with self.subTest(label=label):
                        with self.assertRaises(module.ProfileValidationError):
                            module.validate_and_snapshot(
                                input_profile=str(source),
                                output_profile=str(output),
                                expected_team_id=TEAM_ID,
                                expected_bundle_identifier=BUNDLE_ID,
                                certificate_sha1=CERTIFICATE_SHA1,
                                command_runner=CMSRunner(self.valid_profile()),
                            )
                        self.assertFalse(output.exists())
            finally:
                fifo_timer.join()

    def test_rejects_input_larger_than_one_mibibyte(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"x" * (1024 * 1024 + 1))

            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(self.valid_profile()),
                )

            self.assertFalse(output.exists())

    def test_output_collision_is_rejected_without_touching_existing_file(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            output.write_bytes(b"existing owner data")

            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(self.valid_profile()),
                )

            self.assertEqual(output.read_bytes(), b"existing owner data")

    def test_rejects_source_swap_or_mutation_during_validation(self) -> None:
        module = self.load_module()
        for label in ("swap", "mutation"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                source = root / "selected.provisionprofile"
                output = root / "validated.provisionprofile"
                source.write_bytes(b"original profile bytes")

                def mutate_source(_: Path) -> None:
                    if label == "swap":
                        replacement = root / "replacement.provisionprofile"
                        replacement.write_bytes(b"replacement profile bytes")
                        os.replace(replacement, source)
                    else:
                        source.write_bytes(b"mutated! profile bytes")

                with self.assertRaises(module.ProfileValidationError):
                    module.validate_and_snapshot(
                        input_profile=str(source),
                        output_profile=str(output),
                        expected_team_id=TEAM_ID,
                        expected_bundle_identifier=BUNDLE_ID,
                        certificate_sha1=CERTIFICATE_SHA1,
                        command_runner=CMSRunner(
                            self.valid_profile(), before_return=mutate_source
                        ),
                    )

                self.assertFalse(output.exists())

    def test_rejects_output_mutation_during_validation(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"original profile bytes")

            def mutate_output(snapshot: Path) -> None:
                snapshot.write_bytes(b"different snapshot bytes")

            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(
                        self.valid_profile(), before_return=mutate_output
                    ),
                )

            self.assertFalse(output.exists())

    def test_stream_copy_handles_short_reads_and_writes(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source_bytes = b"short I/O must still preserve every byte"
            source.write_bytes(source_bytes)
            original_read = os.read
            original_write = os.write
            read_calls = 0
            write_calls = 0

            def short_read(descriptor: int, count: int) -> bytes:
                nonlocal read_calls
                read_calls += 1
                return original_read(descriptor, min(count, 3))

            def short_write(descriptor: int, data: bytes) -> int:
                nonlocal write_calls
                write_calls += 1
                return original_write(descriptor, data[:2])

            with mock.patch.object(module.os, "read", side_effect=short_read), mock.patch.object(
                module.os, "write", side_effect=short_write
            ):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(self.valid_profile()),
                )

            self.assertGreater(read_calls, 1)
            self.assertGreater(write_calls, 1)
            self.assertEqual(output.read_bytes(), source_bytes)

    def test_fsync_failure_removes_created_output(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            runner = CMSRunner(self.valid_profile())

            with mock.patch.object(module.os, "fsync", side_effect=OSError("fixture")):
                with self.assertRaises(module.ProfileValidationError):
                    module.validate_and_snapshot(
                        input_profile=str(source),
                        output_profile=str(output),
                        expected_team_id=TEAM_ID,
                        expected_bundle_identifier=BUNDLE_ID,
                        certificate_sha1=CERTIFICATE_SHA1,
                        command_runner=runner,
                    )

            self.assertFalse(output.exists())
            self.assertEqual(runner.calls, [])

    def test_privacy_setup_failure_removes_created_output(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")

            with mock.patch.object(module.os, "fchmod", side_effect=OSError("fixture")):
                with self.assertRaises(module.ProfileValidationError):
                    module.validate_and_snapshot(
                        input_profile=str(source),
                        output_profile=str(output),
                        expected_team_id=TEAM_ID,
                        expected_bundle_identifier=BUNDLE_ID,
                        certificate_sha1=CERTIFICATE_SHA1,
                        command_runner=CMSRunner(self.valid_profile()),
                    )

            self.assertFalse(output.exists())

    def test_accepts_input_exactly_one_mibibyte(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"x" * (1024 * 1024))

            module.validate_and_snapshot(
                input_profile=str(source),
                output_profile=str(output),
                expected_team_id=TEAM_ID,
                expected_bundle_identifier=BUNDLE_ID,
                certificate_sha1=CERTIFICATE_SHA1,
                command_runner=CMSRunner(self.valid_profile()),
            )

            self.assertEqual(output.stat().st_size, 1024 * 1024)

    def test_output_symlink_collision_does_not_touch_target(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            target = root / "target.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")
            target.write_bytes(b"target owner data")
            output.symlink_to(target)

            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(self.valid_profile()),
                )

            self.assertTrue(output.is_symlink())
            self.assertEqual(target.read_bytes(), b"target owner data")

    def test_rejects_ancestry_replacement_during_validation(self) -> None:
        module = self.load_module()
        for label in ("input", "output"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                source_parent = root / "input"
                output_parent = root / "output"
                source_parent.mkdir()
                output_parent.mkdir()
                source = source_parent / "selected.provisionprofile"
                output = output_parent / "validated.provisionprofile"
                source.write_bytes(b"opaque CMS fixture")

                def replace_ancestor(_: Path) -> None:
                    selected = source_parent if label == "input" else output_parent
                    moved = root / f"moved-{label}"
                    selected.rename(moved)
                    selected.symlink_to(moved, target_is_directory=True)

                with self.assertRaises(module.ProfileValidationError):
                    module.validate_and_snapshot(
                        input_profile=str(source),
                        output_profile=str(output),
                        expected_team_id=TEAM_ID,
                        expected_bundle_identifier=BUNDLE_ID,
                        certificate_sha1=CERTIFICATE_SHA1,
                        command_runner=CMSRunner(
                            self.valid_profile(), before_return=replace_ancestor
                        ),
                    )

                moved_output = (
                    root / "moved-output" / output.name
                    if label == "output"
                    else output
                )
                self.assertFalse(moved_output.exists())

    def test_failure_does_not_delete_foreign_output_replacement(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source.write_bytes(b"opaque CMS fixture")

            def replace_output(snapshot: Path) -> None:
                replacement = root / "foreign.provisionprofile"
                replacement.write_bytes(b"foreign replacement")
                os.replace(replacement, snapshot)

            with self.assertRaises(module.ProfileValidationError):
                module.validate_and_snapshot(
                    input_profile=str(source),
                    output_profile=str(output),
                    expected_team_id=TEAM_ID,
                    expected_bundle_identifier=BUNDLE_ID,
                    certificate_sha1=CERTIFICATE_SHA1,
                    command_runner=CMSRunner(
                        self.valid_profile(), before_return=replace_output
                    ),
                )

            self.assertEqual(output.read_bytes(), b"foreign replacement")

    def test_rejects_invalid_expected_selectors_before_creating_output(self) -> None:
        module = self.load_module()
        cases = {
            "short team": ("A1B2C3D4E", BUNDLE_ID, CERTIFICATE_SHA1),
            "lowercase team": ("a1b2c3d4e5", BUNDLE_ID, CERTIFICATE_SHA1),
            "empty bundle": (TEAM_ID, "", CERTIFICATE_SHA1),
            "malformed certificate": (TEAM_ID, BUNDLE_ID, "not-a-sha1"),
        }
        for label, (team_id, bundle_id, fingerprint) in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                source = root / "selected.provisionprofile"
                output = root / "validated.provisionprofile"
                source.write_bytes(b"opaque CMS fixture")
                runner = CMSRunner(self.valid_profile())

                with self.assertRaises(module.ProfileValidationError):
                    module.validate_and_snapshot(
                        input_profile=str(source),
                        output_profile=str(output),
                        expected_team_id=team_id,
                        expected_bundle_identifier=bundle_id,
                        certificate_sha1=fingerprint,
                        command_runner=runner,
                    )

                self.assertFalse(output.exists())
                self.assertEqual(runner.calls, [])

    def test_cli_uses_fixed_security_runner_and_has_no_command_override(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "selected.provisionprofile"
            output = root / "validated.provisionprofile"
            source_bytes = b"opaque CMS fixture"
            source.write_bytes(source_bytes)
            arguments = [
                "--input-profile",
                str(source),
                "--output-profile",
                str(output),
                "--team-identifier",
                TEAM_ID,
                "--bundle-identifier",
                BUNDLE_ID,
                "--certificate-sha1",
                CERTIFICATE_SHA1,
            ]
            with mock.patch.object(
                module,
                "_decode_trusted_cms",
                return_value=plistlib.dumps(self.valid_profile()),
            ) as verifier, redirect_stdout(io.StringIO()) as stdout:
                result = module.main(arguments)

            self.assertEqual(result, 0)
            self.assertEqual(output.read_bytes(), source_bytes)
            verifier.assert_called_once_with(source_bytes)
            self.assertEqual(stdout.getvalue(), "MAS provisioning profile validated.\n")

            with redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    module.parse_arguments(
                        arguments + ["--security-command", "/tmp/fake-security"]
                    )
            self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
