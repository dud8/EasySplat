from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "sign_macos_distribution.py"
SPEC = importlib.util.spec_from_file_location("sign_macos_distribution", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


CERTIFICATE_DER = b"EasySplat deterministic Developer ID certificate fixture"
FINGERPRINT = hashlib.sha1(CERTIFICATE_DER).hexdigest().upper()
TEAM_ID = "A1B2C3D4E5"
COMMON_NAME = f"Developer ID Application: Example ({TEAM_ID})"
SIGNING_TIME = datetime(2026, 7, 18, 23, 45, 0, tzinfo=timezone.utc)
MACHO_MAGICS = (
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
)
CERTIFICATE_PEM = (
    "-----BEGIN CERTIFICATE-----\n"
    + base64.b64encode(CERTIFICATE_DER).decode("ascii")
    + "\n-----END CERTIFICATE-----\n"
)


def identity_output(
    *,
    fingerprint: str = FINGERPRINT,
    team_id: str = TEAM_ID,
    suffix: str = "",
) -> str:
    return (
        f'  1) {fingerprint} "Developer ID Application: Example ({team_id})"'
        f"{suffix}\n"
        "     1 valid identities found\n"
    )


def metadata_output(
    *,
    team_id: str = TEAM_ID,
    runtime: bool = True,
    timestamp: str = "Jul 18, 2026 at 11:45:00 PM",
) -> str:
    flags = "0x10000(runtime)" if runtime else "0x0(none)"
    runtime_line = "Runtime Version=15.0.0\n" if runtime else ""
    timestamp_line = f"Timestamp={timestamp}\n" if timestamp else ""
    return (
        "Executable=/redacted/by-test\n"
        "Identifier=com.easysplat.fixture\n"
        "Format=Mach-O thin (arm64)\n"
        f"CodeDirectory v=20500 flags={flags} hashes=1+7 location=embedded\n"
        f"Authority=Developer ID Application: Example ({team_id})\n"
        "Authority=Developer ID Certification Authority\n"
        "Authority=Apple Root CA\n"
        f"TeamIdentifier={team_id}\n"
        f"{runtime_line}{timestamp_line}"
    )


class FakeCommandRunner:
    def __init__(
        self,
        *,
        identity: str | None = None,
        metadata: str | None = None,
        certificate_verification_returncode: int = 0,
    ):
        self.identity = identity if identity is not None else identity_output()
        self.metadata = metadata if metadata is not None else metadata_output()
        self.certificate_verification_returncode = certificate_verification_returncode
        self.commands: list[list[str]] = []
        self.signed_entitlements: dict[str, object] = {}

    def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(command.copy())
        if command[:4] == [
            "/usr/bin/security",
            "find-identity",
            "-v",
            "-p",
        ]:
            return subprocess.CompletedProcess(command, 0, self.identity, "")
        if command == [
            "/usr/bin/security",
            "find-certificate",
            "-a",
            "-c",
            COMMON_NAME,
            "-p",
        ]:
            return subprocess.CompletedProcess(command, 0, CERTIFICATE_PEM, "")
        if command[:2] == ["/usr/bin/security", "verify-cert"]:
            return subprocess.CompletedProcess(
                command,
                self.certificate_verification_returncode,
                "",
                "certificate verification failed"
                if self.certificate_verification_returncode
                else "",
            )
        if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]:
            target = Path(command[-1])
            if "--entitlements" in command:
                entitlement_path = Path(
                    command[command.index("--entitlements") + 1]
                )
                self.signed_entitlements[str(target)] = plistlib.loads(
                    entitlement_path.read_bytes()
                )
            if target.is_dir():
                signature = target / "Contents/_CodeSignature/CodeResources"
                signature.parent.mkdir(parents=True, exist_ok=True)
                signature.write_bytes(b"signed bundle\n")
            else:
                target.write_bytes(target.read_bytes() + b"signed\n")
            return subprocess.CompletedProcess(command, 0, "", "")
        if command[:3] == ["/usr/bin/codesign", "--verify", "--strict"]:
            return subprocess.CompletedProcess(command, 0, "", "valid on disk\n")
        if command[:3] == ["/usr/bin/codesign", "--display", "--verbose=4"]:
            return subprocess.CompletedProcess(command, 0, "", self.metadata)
        if command[:4] == [
            "/usr/bin/codesign",
            "--display",
            "--entitlements",
            ":-",
        ]:
            payload = self.signed_entitlements.get(command[-1])
            if payload is None:
                return subprocess.CompletedProcess(command, 1, "", "no entitlements")
            xml = plistlib.dumps(
                payload,
                fmt=plistlib.FMT_XML,
                sort_keys=True,
            ).decode("utf-8")
            return subprocess.CompletedProcess(
                command,
                0,
                "",
                f"Executable=/redacted/by-test\n{xml}",
            )
        raise AssertionError(f"unexpected command: {command!r}")


def write_macho(path: Path, magic: bytes = MACHO_MAGICS[0]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(magic + b"fixture payload\n")
    path.chmod(0o755)


def write_app(root: Path, executable_name: str = "EasySplat") -> Path:
    app = root / "EasySplat.app"
    executable = app / "Contents/MacOS" / executable_name
    write_macho(executable)
    info = {
        "CFBundleExecutable": executable_name,
        "CFBundleIdentifier": "com.easysplat.app",
    }
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=True)
    )
    return app


class SigningIdentityTests(unittest.TestCase):
    def test_requires_exact_sha1_fingerprint_and_team_id(self) -> None:
        with self.assertRaisesRegex(MODULE.SigningError, "40 hexadecimal"):
            MODULE.validate_signing_identity("Developer ID Application", TEAM_ID, FakeCommandRunner())
        with self.assertRaisesRegex(MODULE.SigningError, "10 uppercase"):
            MODULE.validate_signing_identity(FINGERPRINT, "team", FakeCommandRunner())

    def test_selects_one_exact_developer_id_application_identity(self) -> None:
        runner = FakeCommandRunner()
        identity = MODULE.validate_signing_identity(FINGERPRINT.lower(), TEAM_ID, runner)
        self.assertEqual(identity["fingerprint"], FINGERPRINT)
        self.assertEqual(identity["teamID"], TEAM_ID)
        self.assertEqual(
            runner.commands[0],
            ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        )
        self.assertEqual(
            runner.commands[1],
            [
                "/usr/bin/security",
                "find-certificate",
                "-a",
                "-c",
                COMMON_NAME,
                "-p",
            ],
        )
        certificate_path = runner.commands[2][3]
        self.assertEqual(
            runner.commands[2],
            [
                "/usr/bin/security",
                "verify-cert",
                "-c",
                certificate_path,
                "-p",
                "codeSign",
                "-R",
                "ocsp",
                "-R",
                "require",
                "-q",
            ],
        )
        self.assertFalse(Path(certificate_path).exists())

    def test_rejects_zero_or_duplicate_exact_identities(self) -> None:
        empty = FakeCommandRunner(identity="     0 valid identities found\n")
        with self.assertRaisesRegex(MODULE.SigningError, "not exactly one valid identity"):
            MODULE.validate_signing_identity(FINGERPRINT, TEAM_ID, empty)

        duplicate_text = identity_output().replace(
            "     1 valid identities found\n",
            f'  2) {FINGERPRINT} "Developer ID Application: Duplicate ({TEAM_ID})"\n'
            "     2 valid identities found\n",
        )
        duplicate = FakeCommandRunner(identity=duplicate_text)
        with self.assertRaisesRegex(MODULE.SigningError, "not exactly one valid identity"):
            MODULE.validate_signing_identity(FINGERPRINT, TEAM_ID, duplicate)

    def test_rejects_wrong_certificate_class_or_team(self) -> None:
        development = FakeCommandRunner(
            identity=identity_output().replace(
                "Developer ID Application", "Apple Development"
            )
        )
        with self.assertRaisesRegex(MODULE.SigningError, "Developer ID Application"):
            MODULE.validate_signing_identity(FINGERPRINT, TEAM_ID, development)

        wrong_team = FakeCommandRunner(identity=identity_output(team_id="Z9Y8X7W6V5"))
        with self.assertRaisesRegex(MODULE.SigningError, "Team ID"):
            MODULE.validate_signing_identity(FINGERPRINT, TEAM_ID, wrong_team)

    def test_rejects_expired_or_revoked_identity_annotations(self) -> None:
        for annotation in (
            " (CSSMERR_TP_CERT_EXPIRED)",
            " (CSSMERR_TP_CERT_REVOKED)",
        ):
            with self.subTest(annotation=annotation):
                runner = FakeCommandRunner(identity=identity_output(suffix=annotation))
                with self.assertRaisesRegex(MODULE.SigningError, "expired or revoked"):
                    MODULE.validate_signing_identity(FINGERPRINT, TEAM_ID, runner)

    def test_rejects_failed_certificate_trust_or_revocation_check(self) -> None:
        runner = FakeCommandRunner(certificate_verification_returncode=1)
        with self.assertRaisesRegex(MODULE.SigningError, "trust or revocation"):
            MODULE.validate_signing_identity(FINGERPRINT, TEAM_ID, runner)


class MachODiscoveryTests(unittest.TestCase):
    def test_recognizes_thin_and_fat_macho_in_both_byte_orders(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for index, magic in enumerate(MACHO_MAGICS):
                path = root / f"file-{index}"
                path.write_bytes(magic + b"body")
                self.assertTrue(MODULE.is_macho(path), magic.hex())
            non_macho = root / "script"
            non_macho.write_bytes(b"#!/bin/sh\n")
            self.assertFalse(MODULE.is_macho(non_macho))

    def test_rejects_relative_root_filesystem_root_and_symlink_root(self) -> None:
        runner = FakeCommandRunner()
        with self.assertRaisesRegex(MODULE.SigningError, "absolute"):
            MODULE.sign_distribution_tree(
                Path("relative"),
                kind="tree",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=Path("receipt.json"),
                run_command=runner,
                signing_time=lambda: SIGNING_TIME,
            )
        with self.assertRaisesRegex(MODULE.SigningError, "filesystem root"):
            MODULE.validate_signing_root(Path("/"), "tree")
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            target = base / "target"
            target.mkdir()
            alias = base / "alias"
            alias.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(MODULE.SigningError, "canonical|symlink"):
                MODULE.validate_signing_root(alias, "tree")

    def test_rejects_symlinks_and_special_files_anywhere_in_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            (root / "escape").symlink_to(root / "bin/tool")
            with self.assertRaisesRegex(MODULE.SigningError, "symlink"):
                MODULE.discover_macho_files(root)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "root"
            root.mkdir()
            os.mkfifo(root / "pipe")
            with self.assertRaisesRegex(MODULE.SigningError, "special file"):
                MODULE.discover_macho_files(root)

    def test_rejects_hard_linked_signing_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            outside = base / "outside-copy"
            write_macho(outside)
            os.link(outside, root / "linked-tool")
            with self.assertRaisesRegex(MODULE.SigningError, "hard link"):
                MODULE.discover_macho_files(root)

    def test_rejects_group_or_world_writable_signing_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "root"
            root.mkdir()
            tool = root / "bin/tool"
            write_macho(tool)
            tool.chmod(0o777)
            with self.assertRaisesRegex(MODULE.SigningError, "group- or world-writable"):
                MODULE.discover_macho_files(root)


class DistributionSigningTests(unittest.TestCase):
    def test_signs_nested_macho_inside_out_without_shell_or_deep(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "toolchain root"
            root.mkdir()
            top = root / "bin/main tool\nname"
            nested = root / "runtime/lib/deep library.dylib"
            sibling = root / "lib/shallow library.dylib"
            write_macho(top, MACHO_MAGICS[0])
            write_macho(nested, MACHO_MAGICS[4])
            write_macho(sibling, MACHO_MAGICS[2])
            (root / "README").write_text("not executable", encoding="utf-8")
            entitlement = base / "main.entitlements"
            entitlement.write_bytes(
                plistlib.dumps(
                    {"com.apple.security.cs.disable-library-validation": True},
                    sort_keys=True,
                )
            )
            receipt = base / "receipts/signing receipt.json"
            runner = FakeCommandRunner()

            payload = MODULE.sign_distribution_tree(
                root,
                kind="tree",
                identity_fingerprint=FINGERPRINT.lower(),
                team_id=TEAM_ID,
                receipt_path=receipt,
                entitlements={"bin/main tool\nname": entitlement},
                run_command=runner,
                signing_time=lambda: SIGNING_TIME,
            )

            signing_commands = [
                command
                for command in runner.commands
                if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]
            ]
            self.assertEqual(
                [Path(command[-1]).relative_to(root).as_posix() for command in signing_commands],
                [
                    "runtime/lib/deep library.dylib",
                    "lib/shallow library.dylib",
                    "bin/main tool\nname",
                ],
            )
            for command in signing_commands:
                self.assertNotIn("--deep", command)
                self.assertEqual(command[3], FINGERPRINT)
                self.assertIn("--options", command)
                self.assertIn("runtime", command)
                self.assertIn("--timestamp", command)
            self.assertIn("--entitlements", signing_commands[-1])
            self.assertNotIn("--entitlements", signing_commands[0])
            self.assertNotIn("--entitlements", signing_commands[1])
            self.assertEqual(signing_commands[-1][-1], str(top))

            self.assertEqual(payload, json.loads(receipt.read_text(encoding="utf-8")))
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertEqual(payload["identityFingerprintSHA1"], FINGERPRINT)
            self.assertEqual(payload["teamID"], TEAM_ID)
            self.assertEqual(payload["signedAt"], "2026-07-18T23:45:00Z")
            self.assertEqual([entry["relativePath"] for entry in payload["entries"]], [
                "runtime/lib/deep library.dylib",
                "lib/shallow library.dylib",
                "bin/main tool\nname",
            ])
            for entry in payload["entries"]:
                self.assertRegex(entry["preSignSHA256"], r"^[0-9a-f]{64}$")
                self.assertRegex(entry["postSignSHA256"], r"^[0-9a-f]{64}$")
                self.assertNotEqual(entry["preSignSHA256"], entry["postSignSHA256"])
                self.assertEqual(entry["mode"], "0755")
                self.assertEqual(entry["codesign"]["teamIdentifier"], TEAM_ID)
                self.assertTrue(entry["codesign"]["hardenedRuntime"])
                self.assertEqual(
                    entry["codesign"]["timestamp"],
                    "Jul 18, 2026 at 11:45:00 PM",
                )
            entitlement_digest = hashlib.sha256(entitlement.read_bytes()).hexdigest()
            embedded_digest = hashlib.sha256(
                plistlib.dumps(
                    plistlib.loads(entitlement.read_bytes()),
                    fmt=plistlib.FMT_XML,
                    sort_keys=True,
                )
            ).hexdigest()
            self.assertEqual(
                payload["entries"][-1]["entitlementsSourceSHA256"],
                entitlement_digest,
            )
            self.assertEqual(
                payload["entries"][-1]["embeddedEntitlementsSHA256"],
                embedded_digest,
            )
            self.assertIsNone(payload["entries"][0]["entitlementsSHA256"])
            self.assertEqual(payload["tree"]["preSignFileCount"], 4)
            self.assertEqual(payload["tree"]["postSignFileCount"], 4)
            self.assertRegex(
                payload["tree"]["preSignManifestSHA256"], r"^[0-9a-f]{64}$"
            )
            self.assertRegex(
                payload["tree"]["postSignManifestSHA256"], r"^[0-9a-f]{64}$"
            )
            self.assertFalse(any(path.name.startswith(".signing receipt.json.") for path in receipt.parent.iterdir()))
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o644)

    def test_signs_app_macho_then_bundle_and_revalidates_final_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            nested = app / "Contents/Frameworks/Engine.framework/Versions/A/Engine"
            write_macho(nested, MACHO_MAGICS[6])
            entitlement = base / "EasySplat.entitlements"
            entitlement.write_bytes(plistlib.dumps({"com.apple.security.network.client": True}))
            receipt = base / "app-signing.json"
            runner = FakeCommandRunner()

            payload = MODULE.sign_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
                entitlements={"Contents/MacOS/EasySplat": entitlement},
                run_command=runner,
                signing_time=lambda: SIGNING_TIME,
            )

            signing_targets = [
                Path(command[-1])
                for command in runner.commands
                if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]
            ]
            self.assertEqual(signing_targets[-1], app)
            self.assertEqual(signing_targets[:-1], [nested, app / "Contents/MacOS/EasySplat"])
            self.assertIn("--entitlements", [
                command for command in runner.commands if command[-1] == str(app)
            ][0])
            self.assertEqual(payload["rootKind"], "app")
            self.assertEqual(payload["entries"][-1]["kind"], "appBundle")
            self.assertEqual(payload["entries"][-1]["relativePath"], ".")
            self.assertRegex(payload["entries"][-1]["postSignSHA256"], r"^[0-9a-f]{64}$")

            verification_targets = [
                Path(command[-1])
                for command in runner.commands
                if command[:3] == ["/usr/bin/codesign", "--verify", "--strict"]
            ]
            self.assertEqual(verification_targets, [nested, app / "Contents/MacOS/EasySplat", app])

    def test_entitlements_are_limited_to_named_top_level_executables(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "tree"
            root.mkdir()
            nested = root / "lib/library.dylib"
            write_macho(nested)
            entitlement = base / "entitlements.plist"
            entitlement.write_bytes(plistlib.dumps({}))
            with self.assertRaisesRegex(MODULE.SigningError, "top-level executable"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "receipt.json",
                    entitlements={"lib/library.dylib": entitlement},
                    run_command=FakeCommandRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_rejects_writable_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "tree"
            root.mkdir()
            write_macho(root / "bin/tool")
            entitlement = base / "entitlements.plist"
            entitlement.write_bytes(plistlib.dumps({}))
            entitlement.chmod(0o666)
            with self.assertRaisesRegex(MODULE.SigningError, "must not be group- or world-writable"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "receipt.json",
                    entitlements={"bin/tool": entitlement},
                    run_command=FakeCommandRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_rejects_receipt_inside_signed_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            with self.assertRaisesRegex(MODULE.SigningError, "outside the signing root"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=root / "receipt.json",
                    run_command=FakeCommandRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_rejects_missing_runtime_team_or_timestamp_metadata(self) -> None:
        cases = (
            (metadata_output(runtime=False), "hardened runtime"),
            (metadata_output(team_id="Z9Y8X7W6V5"), "TeamIdentifier"),
            (metadata_output(timestamp=""), "secure timestamp"),
        )
        for metadata, expected_error in cases:
            with self.subTest(expected_error=expected_error), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                root = base / "root"
                root.mkdir()
                write_macho(root / "bin/tool")
                with self.assertRaisesRegex(MODULE.SigningError, expected_error):
                    MODULE.sign_distribution_tree(
                        root,
                        kind="tree",
                        identity_fingerprint=FINGERPRINT,
                        team_id=TEAM_ID,
                        receipt_path=base / "receipt.json",
                        run_command=FakeCommandRunner(metadata=metadata),
                        signing_time=lambda: SIGNING_TIME,
                    )

    def test_rejects_an_untrusted_or_mismatched_authority_chain(self) -> None:
        valid = metadata_output()
        cases = (
            (
                valid.replace(
                    f"Authority=Developer ID Application: Example ({TEAM_ID})\n", ""
                ),
                "Developer ID Application authority",
            ),
            (
                valid.replace(
                    f"Authority=Developer ID Application: Example ({TEAM_ID})",
                    "Authority=Developer ID Application: Example (Z9Y8X7W6V5)",
                ),
                "Developer ID Application authority",
            ),
            (
                valid.replace("Authority=Developer ID Certification Authority\n", ""),
                "Developer ID authority chain",
            ),
            (
                valid.replace("Authority=Apple Root CA\n", ""),
                "Developer ID authority chain",
            ),
        )
        for metadata, expected_error in cases:
            with self.subTest(expected_error=expected_error), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                root = base / "root"
                root.mkdir()
                write_macho(root / "bin/tool")
                with self.assertRaisesRegex(MODULE.SigningError, expected_error):
                    MODULE.sign_distribution_tree(
                        root,
                        kind="tree",
                        identity_fingerprint=FINGERPRINT,
                        team_id=TEAM_ID,
                        receipt_path=base / "receipt.json",
                        run_command=FakeCommandRunner(metadata=metadata),
                        signing_time=lambda: SIGNING_TIME,
                    )

    def test_codesign_uses_an_immutable_entitlements_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            entitlement = base / "entitlements.plist"
            entitlement.write_bytes(plistlib.dumps({"com.apple.security.network.client": True}))
            receipt = base / "receipt.json"

            class MutatingRunner(FakeCommandRunner):
                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]:
                        entitlement.write_bytes(plistlib.dumps({"changed": True}))
                    return super().__call__(command)

            runner = MutatingRunner()
            with self.assertRaisesRegex(MODULE.SigningError, "entitlements changed while signing"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    entitlements={"bin/tool": entitlement},
                    run_command=runner,
                    signing_time=lambda: SIGNING_TIME,
                )
            signing_command = next(
                command
                for command in runner.commands
                if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]
            )
            snapshot = Path(signing_command[signing_command.index("--entitlements") + 1])
            self.assertNotEqual(snapshot, entitlement)
            self.assertFalse(snapshot.exists())
            self.assertFalse(receipt.exists())

    def test_rejects_a_mutated_entitlements_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            entitlement = base / "entitlements.plist"
            entitlement.write_bytes(
                plistlib.dumps({"com.apple.security.network.client": True})
            )
            receipt = base / "receipt.json"

            class SnapshotMutatingRunner(FakeCommandRunner):
                snapshot_mode: int | None = None

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]:
                        snapshot = Path(
                            command[command.index("--entitlements") + 1]
                        )
                        self.snapshot_mode = stat.S_IMODE(snapshot.stat().st_mode)
                        snapshot.chmod(0o600)
                        snapshot.write_bytes(plistlib.dumps({"changed": True}))
                    return super().__call__(command)

            runner = SnapshotMutatingRunner()
            with self.assertRaisesRegex(MODULE.SigningError, "snapshot changed"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    entitlements={"bin/tool": entitlement},
                    run_command=runner,
                    signing_time=lambda: SIGNING_TIME,
                )
            self.assertEqual(runner.snapshot_mode, 0o400)
            self.assertFalse(receipt.exists())

    def test_rejects_embedded_entitlements_that_differ_semantically(self) -> None:
        class WrongEmbeddedEntitlementsRunner(FakeCommandRunner):
            def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[:4] == [
                    "/usr/bin/codesign",
                    "--display",
                    "--entitlements",
                    ":-",
                ]:
                    xml = plistlib.dumps(
                        {"com.apple.security.network.server": True},
                        fmt=plistlib.FMT_XML,
                    ).decode("utf-8")
                    return subprocess.CompletedProcess(command, 0, "", xml)
                return super().__call__(command)

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            entitlement = base / "entitlements.plist"
            entitlement.write_bytes(
                plistlib.dumps({"com.apple.security.network.client": True})
            )
            with self.assertRaisesRegex(MODULE.SigningError, "embedded entitlements"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "receipt.json",
                    entitlements={"bin/tool": entitlement},
                    run_command=WrongEmbeddedEntitlementsRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_rejects_non_macho_mutation_during_tree_signing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            model = root / "models/weights.safetensors"
            model.parent.mkdir()
            model.write_bytes(b"original model")

            class ModelMutatingRunner(FakeCommandRunner):
                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    result = super().__call__(command)
                    if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]:
                        model.write_bytes(b"substituted model")
                    return result

            with self.assertRaisesRegex(MODULE.SigningError, "non-Mach-O.*changed"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "receipt.json",
                    run_command=ModelMutatingRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_rejects_macho_replacement_after_signature_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            tool = root / "bin/tool"
            write_macho(tool)

            class PostVerificationMutatingRunner(FakeCommandRunner):
                changed = False

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    result = super().__call__(command)
                    if (
                        not self.changed
                        and command[:3]
                        == ["/usr/bin/codesign", "--display", "--verbose=4"]
                    ):
                        tool.write_bytes(tool.read_bytes() + b"unverified replacement\n")
                        self.changed = True
                    return result

            with self.assertRaisesRegex(MODULE.SigningError, "changed.*verification"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "receipt.json",
                    run_command=PostVerificationMutatingRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_rejects_symlinked_root_ancestor_and_ancestor_retargeting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            real = base / "real"
            root = real / "root"
            root.mkdir(parents=True)
            alias = base / "alias"
            alias.symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(MODULE.SigningError, "canonical|symlink"):
                MODULE.validate_signing_root(alias / "root", "tree")

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            stage = base / "stage"
            root = stage / "root"
            root.mkdir(parents=True)
            write_macho(root / "bin/tool")

            class RetargetingRunner(FakeCommandRunner):
                changed = False

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    result = super().__call__(command)
                    if (
                        not self.changed
                        and command[:3]
                        == ["/usr/bin/codesign", "--force", "--sign"]
                    ):
                        moved = base / "stage-original"
                        stage.rename(moved)
                        stage.symlink_to(moved, target_is_directory=True)
                        self.changed = True
                    return result

            with self.assertRaisesRegex(MODULE.SigningError, "ancestry changed"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "receipt.json",
                    run_command=RetargetingRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_command_failure_stops_before_writing_receipt(self) -> None:
        class FailingRunner(FakeCommandRunner):
            def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]:
                    self.commands.append(command.copy())
                    return subprocess.CompletedProcess(command, 1, "", "identity unavailable")
                return super().__call__(command)

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            receipt = base / "receipt.json"
            with self.assertRaisesRegex(MODULE.SigningError, "codesign signing failed"):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=FailingRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )
            self.assertFalse(receipt.exists())


if __name__ == "__main__":
    unittest.main()
