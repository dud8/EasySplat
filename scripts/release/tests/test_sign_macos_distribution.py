from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "sign_macos_distribution.py"
SPEC = importlib.util.spec_from_file_location("sign_macos_distribution", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
BUILD_DMG_SCRIPT = SCRIPT.parent / "build_dmg.sh"
BUILD_APP_SCRIPT = SCRIPT.parent / "build_app.sh"
CREATE_DMG_SCRIPT = SCRIPT.parent / "create_dmg.sh"
NOTARIZE_SCRIPT = SCRIPT.parent / "notarize_artifact.sh"
PUBLISH_SCRIPT = SCRIPT.parent / "publish_release_files.py"
NOTARY_RECEIPT_VERIFIER = SCRIPT.parent / "verify_notarization_receipt.py"
VERIFY_RELEASE_SCRIPT = SCRIPT.parent / "verify_release.sh"
NOTARY_SPEC = importlib.util.spec_from_file_location(
    "verify_notarization_receipt_for_signing_tests", NOTARY_RECEIPT_VERIFIER
)
assert NOTARY_SPEC and NOTARY_SPEC.loader
NOTARY_MODULE = importlib.util.module_from_spec(NOTARY_SPEC)
NOTARY_SPEC.loader.exec_module(NOTARY_MODULE)


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


def otool_listing_output(
    path: Path,
    *,
    loads: tuple[str, ...] = ("/usr/lib/libSystem.B.dylib",),
    install_name: str | None = None,
) -> str:
    paths = (() if install_name is None else (install_name,)) + loads
    return f"{path}:\n" + "".join(
        f"\t{load} (compatibility version 1.0.0, current version 1.0.0)\n"
        for load in paths
    )


def otool_load_commands_output(
    path: Path,
    *,
    loads: tuple[str, ...] = ("/usr/lib/libSystem.B.dylib",),
    rpaths: tuple[str, ...] = (),
    install_name: str | None = None,
) -> str:
    commands: list[tuple[str, str, str]] = []
    if install_name is not None:
        commands.append(("LC_ID_DYLIB", "name", install_name))
    commands.extend(("LC_RPATH", "path", value) for value in rpaths)
    commands.extend(("LC_LOAD_DYLIB", "name", value) for value in loads)
    lines = [f"{path}:\n"]
    for index, (command, field, value) in enumerate(commands):
        lines.extend(
            (
                f"Load command {index}\n",
                f"          cmd {command}\n",
                "      cmdsize 64\n",
                f"         {field} {value} (offset 24)\n",
            )
        )
    return "".join(lines)


class FakeCommandRunner:
    def __init__(
        self,
        *,
        identity: str | None = None,
        metadata: str | None = None,
        embedded_certificate_der: bytes = CERTIFICATE_DER,
        certificate_verification_returncode: int = 0,
        dependency_specs: dict[Path, dict[str, object]] | None = None,
    ):
        self.identity = identity if identity is not None else identity_output()
        self.metadata = metadata if metadata is not None else metadata_output()
        self.embedded_certificate_der = embedded_certificate_der
        self.certificate_verification_returncode = certificate_verification_returncode
        self.dependency_specs = {
            str(path): spec for path, spec in (dependency_specs or {}).items()
        }
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
        if command[:3] == ["/usr/bin/lipo", "-archs", command[-1]]:
            return subprocess.CompletedProcess(command, 0, "arm64\n", "")
        if command[:3] == ["/usr/bin/vtool", "-show-build", command[-1]]:
            return subprocess.CompletedProcess(
                command,
                0,
                (
                    f"{command[-1]}:\n"
                    "Load command 10\n"
                    "      cmd LC_BUILD_VERSION\n"
                    "  cmdsize 32\n"
                    " platform MACOS\n"
                    "    minos 15.0\n"
                    "      sdk 26.5\n"
                ),
                "",
            )
        if command[:2] == ["/usr/bin/otool", "-L"]:
            target = Path(command[-1])
            spec = self.dependency_specs.get(str(target), {})
            return subprocess.CompletedProcess(
                command,
                0,
                otool_listing_output(
                    target,
                    loads=spec.get("loads", ("/usr/lib/libSystem.B.dylib",)),
                    install_name=spec.get("install_name"),
                ),
                "",
            )
        if command[:2] == ["/usr/bin/otool", "-l"]:
            target = Path(command[-1])
            spec = self.dependency_specs.get(str(target), {})
            return subprocess.CompletedProcess(
                command,
                0,
                otool_load_commands_output(
                    target,
                    loads=spec.get("loads", ("/usr/lib/libSystem.B.dylib",)),
                    rpaths=spec.get("rpaths", ()),
                    install_name=spec.get("install_name"),
                ),
                "",
            )
        if command[:3] == ["/usr/bin/codesign", "--display", "--verbose=4"]:
            certificate_option = next(
                (
                    value
                    for value in command
                    if value.startswith("--extract-certificates=")
                ),
                None,
            )
            if certificate_option is not None:
                prefix = Path(certificate_option.split("=", 1)[1])
                prefix.with_name(prefix.name + "0").write_bytes(
                    self.embedded_certificate_der
                )
            return subprocess.CompletedProcess(command, 0, "", self.metadata)
        if command[:4] == [
            "/usr/bin/codesign",
            "--display",
            "--entitlements",
            "-",
        ]:
            payload = self.signed_entitlements.get(command[-1])
            if payload is None:
                return subprocess.CompletedProcess(
                    command,
                    0,
                    "",
                    "Executable=/redacted/by-test\n",
                )
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
    def test_system_signing_commands_receive_a_minimal_environment(self) -> None:
        completed = subprocess.CompletedProcess(["/usr/bin/true"], 0, "", "")
        inherited = {
            "HOME": "/Users/example",
            "USER": "example",
            "LOGNAME": "example",
            "PATH": "/tmp/attacker",
            "TMPDIR": "/tmp/attacker",
            "DEVELOPER_DIR": "/tmp/attacker-xcode",
            "SDKROOT": "/tmp/attacker-sdk",
            "TOOLCHAINS": "attacker",
            "CC": "/tmp/attacker-cc",
            "DYLD_INSERT_LIBRARIES": "/tmp/attacker.dylib",
            "HTTPS_PROXY": "http://attacker.invalid",
            "SSL_CERT_FILE": "/tmp/attacker-ca",
            "GITHUB_PERSONAL_ACCESS_TOKEN": "must-not-reach-child",
            "GH_TOKEN": "must-not-reach-child",
            "GITHUB_TOKEN": "must-not-reach-child",
        }
        with mock.patch.dict(os.environ, inherited, clear=True), mock.patch.object(
            MODULE.subprocess, "run", return_value=completed
        ) as run:
            self.assertIs(MODULE.run_command(["/usr/bin/true"]), completed)

        environment = run.call_args.kwargs["env"]
        self.assertEqual(
            environment,
            {
                "HOME": "/Users/example",
                "LANG": "C",
                "LC_ALL": "C",
                "LOGNAME": "example",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/private/tmp",
                "USER": "example",
            },
        )

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


class MachODependencyClosureTests(unittest.TestCase):
    def test_binds_valid_framework_closure_into_app_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            main = app / "Contents/MacOS/EasySplat"
            engine = app / "Contents/Frameworks/Engine.framework/Versions/A/Engine"
            write_macho(engine)
            engine_load = "@rpath/Engine.framework/Versions/A/Engine"
            runner = FakeCommandRunner(
                dependency_specs={
                    main: {
                        "loads": (engine_load, "/usr/lib/libSystem.B.dylib"),
                        "rpaths": (
                            "/usr/lib/swift",
                            "@executable_path/../Frameworks",
                        ),
                    },
                    engine: {
                        "install_name": engine_load,
                        "loads": (
                            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
                        ),
                    },
                }
            )

            payload = MODULE.sign_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=base / "app-signing.json",
                run_command=runner,
                signing_time=lambda: SIGNING_TIME,
            )

            closure = payload.get("dependencyClosure")
            self.assertIsInstance(closure, dict)
            self.assertEqual(closure.get("format"), "macho-dependency-closure-v1")
            self.assertRegex(str(closure.get("manifestSHA256")), r"^[0-9a-f]{64}$")
            self.assertEqual(closure.get("imageCount"), 2)
            self.assertEqual(closure.get("dependencyCount"), 3)
            self.assertEqual(
                closure.get("images"),
                [
                    {
                        "dependencies": [
                            {
                                "kind": "system",
                                "loadPath": (
                                    "/System/Library/Frameworks/Foundation.framework/"
                                    "Versions/C/Foundation"
                                ),
                                "resolvedPath": (
                                    "/System/Library/Frameworks/Foundation.framework/"
                                    "Versions/C/Foundation"
                                ),
                            }
                        ],
                        "installName": engine_load,
                        "relativePath": (
                            "Contents/Frameworks/Engine.framework/Versions/A/Engine"
                        ),
                        "rpaths": [],
                    },
                    {
                        "dependencies": [
                            {
                                "kind": "system",
                                "loadPath": "/usr/lib/libSystem.B.dylib",
                                "resolvedPath": "/usr/lib/libSystem.B.dylib",
                            },
                            {
                                "kind": "bundle",
                                "loadPath": engine_load,
                                "resolvedPath": (
                                    "Contents/Frameworks/Engine.framework/Versions/A/Engine"
                                ),
                            },
                        ],
                        "installName": None,
                        "relativePath": "Contents/MacOS/EasySplat",
                        "rpaths": [
                            "/usr/lib/swift",
                            "@executable_path/../Frameworks",
                        ],
                    },
                ],
            )

    def test_rejects_absolute_non_system_dependency_before_signing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            receipt = base / "app-signing.json"
            runner = FakeCommandRunner(
                dependency_specs={
                    app / "Contents/MacOS/EasySplat": {
                        "loads": ("/usr/local/lib/libInjected.dylib",),
                    }
                }
            )

            with self.assertRaisesRegex(
                MODULE.SigningError,
                "absolute non-system Mach-O dependency",
            ):
                MODULE.sign_distribution_tree(
                    app,
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=runner,
                    signing_time=lambda: SIGNING_TIME,
                )

            self.assertFalse(receipt.exists())
            self.assertFalse(
                any(
                    command[:3] == ["/usr/bin/codesign", "--force", "--sign"]
                    for command in runner.commands
                )
            )

    def test_rejects_dependency_closure_changes_after_signing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            main = app / "Contents/MacOS/EasySplat"
            engine = app / "Contents/Frameworks/Engine.framework/Versions/A/Engine"
            write_macho(engine)
            engine_load = "@rpath/Engine.framework/Versions/A/Engine"

            class MutatingDependencyRunner(FakeCommandRunner):
                signed = False

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    if command[:2] in ([MODULE.OTOOL, "-l"], [MODULE.OTOOL, "-L"]):
                        loads = (
                            (engine_load, "/usr/lib/libSystem.B.dylib")
                            if not self.signed
                            else ("/usr/lib/libSystem.B.dylib",)
                        )
                        target = Path(command[-1])
                        if target == main:
                            if command[:2] == [MODULE.OTOOL, "-L"]:
                                return subprocess.CompletedProcess(
                                    command,
                                    0,
                                    otool_listing_output(target, loads=loads),
                                    "",
                                )
                            return subprocess.CompletedProcess(
                                command,
                                0,
                                otool_load_commands_output(
                                    target,
                                    loads=loads,
                                    rpaths=("@executable_path/../Frameworks",),
                                ),
                                "",
                            )
                    result = super().__call__(command)
                    if command[:3] == [MODULE.CODESIGN, "--force", "--sign"]:
                        self.signed = True
                    return result

            with self.assertRaisesRegex(
                MODULE.SigningError,
                "Mach-O dependency closure changed after signing",
            ):
                MODULE.sign_distribution_tree(
                    app,
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "app-signing.json",
                    run_command=MutatingDependencyRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

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
    def test_app_requires_an_explicit_empty_entitlement_closure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            nested = app / "Contents/Frameworks/Engine.framework/Versions/A/Engine"
            write_macho(nested)
            receipt = base / "app-signing.json"

            payload = MODULE.sign_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
                run_command=FakeCommandRunner(),
                signing_time=lambda: SIGNING_TIME,
            )

            self.assertEqual(
                payload["entitlementPolicy"],
                {
                    "allowlist": {},
                    "forbiddenKeys": [
                        "com.apple.security.cs.allow-jit",
                        "com.apple.security.cs.allow-unsigned-executable-memory",
                        "com.apple.security.cs.debugger",
                        "com.apple.security.cs.disable-executable-page-protection",
                        "com.apple.security.cs.disable-library-validation",
                        "com.apple.security.get-task-allow",
                    ],
                    "policy": "empty",
                },
            )
            for entry in payload["entries"]:
                self.assertFalse(entry["embeddedEntitlementsPresent"])
                self.assertIsNone(entry["embeddedEntitlementsSHA256"])

    def test_app_rejects_an_unrequested_embedded_entitlement(self) -> None:
        class InjectingRunner(FakeCommandRunner):
            def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[:4] == [
                    "/usr/bin/codesign",
                    "--display",
                    "--entitlements",
                    "-",
                ]:
                    payload = plistlib.dumps(
                        {"com.apple.security.get-task-allow": True},
                        fmt=plistlib.FMT_XML,
                        sort_keys=True,
                    ).decode("utf-8")
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        "",
                        f"Executable=/redacted/by-test\n{payload}",
                    )
                return super().__call__(command)

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            receipt = base / "app-signing.json"

            with self.assertRaisesRegex(
                MODULE.SigningError,
                "empty entitlement allowlist",
            ):
                MODULE.sign_distribution_tree(
                    app,
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=InjectingRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )
            self.assertFalse(receipt.exists())

    def test_app_receipt_binds_arm64_macos_15_for_every_macho(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            nested = app / "Contents/Frameworks/Engine.framework/Versions/A/Engine"
            write_macho(nested)

            payload = MODULE.sign_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=base / "app-signing.json",
                run_command=FakeCommandRunner(),
                signing_time=lambda: SIGNING_TIME,
            )

            self.assertEqual(
                payload["binaryPolicy"],
                {
                    "architectures": ["arm64"],
                    "minimumOS": "15.0",
                    "platform": "macOS",
                },
            )
            self.assertEqual(
                payload["artifactDigest"],
                {
                    "format": "sha256-tree-v1",
                    "postSignSHA256": NOTARY_MODULE.artifact_sha256(app),
                },
            )
            macho_entries = [
                entry for entry in payload["entries"] if entry["kind"] == "machO"
            ]
            self.assertEqual(len(macho_entries), 2)
            for entry in macho_entries:
                self.assertEqual(
                    entry["machO"],
                    {
                        "architectures": ["arm64"],
                        "minimumOS": "15.0",
                        "platform": "macOS",
                        "sdk": "26.5",
                    },
                )

    def test_app_declared_executable_must_be_the_signed_executable_macho(self) -> None:
        cases = ("missing", "script", "not-executable", "invalid-name")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve()
                app = write_app(base)
                declared = app / "Contents/MacOS/EasySplat"
                write_macho(app / "Contents/MacOS/UnrelatedHelper")
                if case == "missing":
                    declared.unlink()
                elif case == "script":
                    declared.write_bytes(b"#!/bin/sh\nexit 0\n")
                    declared.chmod(0o755)
                elif case == "not-executable":
                    declared.chmod(0o644)
                else:
                    info = app / "Contents/Info.plist"
                    payload = plistlib.loads(info.read_bytes())
                    payload["CFBundleExecutable"] = "."
                    info.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_BINARY))

                receipt = base / "app-signing.json"
                with self.assertRaisesRegex(
                    MODULE.SigningError,
                    "CFBundleExecutable|declared app executable",
                ):
                    MODULE.sign_distribution_tree(
                        app,
                        kind="app",
                        identity_fingerprint=FINGERPRINT,
                        team_id=TEAM_ID,
                        receipt_path=receipt,
                        run_command=FakeCommandRunner(),
                        signing_time=lambda: SIGNING_TIME,
                    )
                self.assertFalse(receipt.exists())

    def test_entitlements_are_read_from_one_stably_bound_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            source = base / "entitlements.plist"
            original_payload = {"com.apple.security.network.client": True}
            attacker_payload = {"com.apple.security.network.server": True}
            source.write_bytes(plistlib.dumps(original_payload))
            attacker = base / "attacker.plist"
            attacker.write_bytes(plistlib.dumps(attacker_payload))
            original = base / "original.plist"

            class SwappingReadPath(type(source)):
                def read_bytes(self) -> bytes:
                    Path(self).rename(original)
                    attacker.rename(Path(self))
                    try:
                        return super().read_bytes()
                    finally:
                        Path(self).rename(attacker)
                        original.rename(Path(self))

            loaded = MODULE._load_entitlements(SwappingReadPath(source))
            self.assertEqual(loaded.payload, original_payload)
            self.assertEqual(
                loaded.source_sha256,
                hashlib.sha256(source.read_bytes()).hexdigest(),
            )

    def test_declared_executable_and_info_digest_come_from_the_same_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            write_macho(app / "Contents/MacOS/UnrelatedHelper")
            tree = MODULE.snapshot_tree(app)
            macho_paths = {
                relative
                for relative, entry in tree.entries.items()
                if entry.kind == "file" and entry.is_macho
            }
            actual = (app / "Contents/Info.plist").read_bytes()
            attacker = plistlib.dumps(
                {
                    "CFBundleExecutable": "UnrelatedHelper",
                    "CFBundleIdentifier": "com.easysplat.app",
                },
                fmt=plistlib.FMT_BINARY,
            )
            reads = iter((attacker, actual))

            with mock.patch.object(
                MODULE,
                "_stable_regular_file_bytes",
                side_effect=lambda *args, **kwargs: next(reads),
            ):
                with self.assertRaisesRegex(
                    MODULE.SigningError,
                    "Info.plist changed|CFBundleExecutable",
                ):
                    MODULE._validate_app_main_executable(
                        app,
                        tree,
                        macho_paths,
                    )

    def test_app_rejects_a_non_arm64_only_macho(self) -> None:
        class UniversalRunner(FakeCommandRunner):
            def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[:2] == ["/usr/bin/lipo", "-archs"]:
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        "x86_64 arm64\n",
                        "",
                    )
                return super().__call__(command)

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            with self.assertRaisesRegex(MODULE.SigningError, "exactly arm64"):
                MODULE.sign_distribution_tree(
                    write_app(base),
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "app-signing.json",
                    run_command=UniversalRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_app_rejects_a_macho_above_the_macos_15_floor(self) -> None:
        class NewerMinimumRunner(FakeCommandRunner):
            def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[:2] == ["/usr/bin/vtool", "-show-build"]:
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        (
                            f"{command[-1]}:\n"
                            "Load command 10\n"
                            "      cmd LC_BUILD_VERSION\n"
                            " platform MACOS\n"
                            "    minos 15.1\n"
                            "      sdk 26.5\n"
                        ),
                        "",
                    )
                return super().__call__(command)

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            with self.assertRaisesRegex(MODULE.SigningError, "minimum macOS 15.0"):
                MODULE.sign_distribution_tree(
                    write_app(base),
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=base / "app-signing.json",
                    run_command=NewerMinimumRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

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
            receipt = base / "app-signing.json"
            runner = FakeCommandRunner()

            payload = MODULE.sign_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
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
            self.assertFalse(
                any(
                    command[:3]
                    == ["/usr/bin/codesign", "--force", "--sign"]
                    and "--entitlements" in command
                    for command in runner.commands
                )
            )
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

    def test_app_receipt_parent_swap_cannot_replace_bundle_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            artifacts = base / "artifacts"
            artifacts.mkdir()
            app = write_app(artifacts)
            info = app / "Contents/Info.plist"
            original_info = info.read_bytes()
            receipts = base / "receipts"
            receipts.mkdir()
            displaced = base / "receipts-original"
            receipt = receipts / "Info.plist"

            class SwappingRunner(FakeCommandRunner):
                swapped = False

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    result = super().__call__(command)
                    if (
                        not self.swapped
                        and command[:3]
                        == ["/usr/bin/codesign", "--display", "--verbose=4"]
                        and Path(command[-1]) == app
                    ):
                        receipts.rename(displaced)
                        receipts.symlink_to(app / "Contents", target_is_directory=True)
                        self.swapped = True
                    return result

            runner = SwappingRunner()
            with self.assertRaisesRegex(MODULE.SigningError, "receipt|changed"):
                MODULE.sign_distribution_tree(
                    app,
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=runner,
                    signing_time=lambda: SIGNING_TIME,
                )
            self.assertTrue(runner.swapped)
            self.assertEqual(info.read_bytes(), original_info)

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

    def test_accepts_changed_authority_labels_after_semantic_requirement_passes(self) -> None:
        metadata = metadata_output().replace(
            f"Authority=Developer ID Application: Example ({TEAM_ID})\n"
            "Authority=Developer ID Certification Authority\n"
            "Authority=Apple Root CA\n",
            "Authority=Future Developer ID Leaf Label\n"
            "Authority=Future Developer ID Intermediate Label\n"
            "Authority=Future Apple Trust Anchor Label\n"
            "Authority=Additional Cross-Signing Label\n",
        )
        requirement = (
            "=anchor apple generic and "
            "certificate 1[field.1.2.840.113635.100.6.2.6] and "
            "certificate leaf[field.1.2.840.113635.100.6.1.13] and "
            f'certificate leaf[subject.OU] = "{TEAM_ID}"'
        )
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            executable = root / "bin/tool"
            write_macho(executable)
            runner = FakeCommandRunner(metadata=metadata)

            payload = MODULE.sign_distribution_tree(
                root,
                kind="tree",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=base / "receipt.json",
                run_command=runner,
                signing_time=lambda: SIGNING_TIME,
            )

            self.assertIn(
                [
                    "/usr/bin/codesign",
                    "--verify",
                    "--strict",
                    "--verbose=4",
                    "--test-requirement",
                    requirement,
                    str(executable),
                ],
                runner.commands,
            )
            self.assertEqual(
                payload["entries"][0]["codesign"]["authorities"],
                [
                    "Future Developer ID Leaf Label",
                    "Future Developer ID Intermediate Label",
                    "Future Apple Trust Anchor Label",
                    "Additional Cross-Signing Label",
                ],
            )

    def test_rejects_a_failed_semantic_developer_id_requirement(self) -> None:
        class FailingRequirementRunner(FakeCommandRunner):
            def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                if command[:3] == [
                    "/usr/bin/codesign",
                    "--verify",
                    "--strict",
                ] and "--test-requirement" in command:
                    self.commands.append(command.copy())
                    return subprocess.CompletedProcess(command, 3, "", "rejected")
                return super().__call__(command)

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            root = base / "root"
            root.mkdir()
            write_macho(root / "bin/tool")
            receipt = base / "receipt.json"

            with self.assertRaisesRegex(
                MODULE.SigningError,
                "semantic Developer ID requirement",
            ):
                MODULE.sign_distribution_tree(
                    root,
                    kind="tree",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=FailingRequirementRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )
            self.assertFalse(receipt.exists())

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
                    "-",
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


class DiskImageSigningTests(unittest.TestCase):
    def test_signs_one_dmg_with_the_exact_identity_and_atomic_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            disk_image = base / "EasySplat-0.2.0.dmg"
            disk_image.write_bytes(b"unsigned disk image")
            receipt = base / "receipts/dmg-signing.json"
            runner = FakeCommandRunner(metadata=metadata_output(runtime=False))

            payload = MODULE.sign_distribution_dmg(
                disk_image,
                identity_fingerprint=FINGERPRINT.lower(),
                team_id=TEAM_ID,
                receipt_path=receipt,
                run_command=runner,
                signing_time=lambda: SIGNING_TIME,
            )

            signing_command = next(
                command
                for command in runner.commands
                if command[:3] == ["/usr/bin/codesign", "--force", "--sign"]
            )
            self.assertEqual(
                signing_command,
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--sign",
                    FINGERPRINT,
                    "--timestamp",
                    str(disk_image),
                ],
            )
            self.assertNotIn("--deep", signing_command)
            requirement_command = next(
                command
                for command in runner.commands
                if "--test-requirement" in command
            )
            self.assertEqual(requirement_command[-1], str(disk_image))
            self.assertIn(
                f'certificate leaf[subject.OU] = "{TEAM_ID}"',
                requirement_command[-2],
            )
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertEqual(payload["rootKind"], "dmg")
            self.assertEqual(payload["identityFingerprintSHA1"], FINGERPRINT)
            self.assertEqual(payload["teamID"], TEAM_ID)
            self.assertEqual(payload["signedAt"], "2026-07-18T23:45:00Z")
            self.assertEqual(
                payload["artifactDigest"],
                {
                    "format": "sha256-file-v1",
                    "postSignSHA256": hashlib.sha256(
                        disk_image.read_bytes()
                    ).hexdigest(),
                },
            )
            self.assertEqual(len(payload["entries"]), 1)
            entry = payload["entries"][0]
            self.assertEqual(entry["kind"], "diskImage")
            self.assertEqual(entry["relativePath"], disk_image.name)
            self.assertNotEqual(entry["preSignSHA256"], entry["postSignSHA256"])
            self.assertEqual(entry["identityFingerprintSHA1"], FINGERPRINT)
            self.assertEqual(entry["teamID"], TEAM_ID)
            self.assertFalse(entry["codesign"]["hardenedRuntime"])
            self.assertEqual(json.loads(receipt.read_text(encoding="utf-8")), payload)
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o644)

    def test_rejects_unsafe_or_ineligible_dmg_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            regular = base / "source.dmg"
            regular.write_bytes(b"disk image")
            cases: list[tuple[Path, str]] = []

            wrong_suffix = base / "source.zip"
            wrong_suffix.write_bytes(b"archive")
            cases.append((wrong_suffix, "must end in .dmg"))

            directory_input = base / "directory.dmg"
            directory_input.mkdir()
            cases.append((directory_input, "regular file"))

            symlink_input = base / "symlink.dmg"
            symlink_input.symlink_to(regular)
            cases.append((symlink_input, "symlink|canonical"))

            hardlink_input = base / "hardlink.dmg"
            os.link(regular, hardlink_input)
            cases.append((hardlink_input, "hard linked"))

            for index, (path, error) in enumerate(cases):
                with self.subTest(path=path):
                    with self.assertRaisesRegex(MODULE.SigningError, error):
                        MODULE.sign_distribution_dmg(
                            path,
                            identity_fingerprint=FINGERPRINT,
                            team_id=TEAM_ID,
                            receipt_path=base / f"receipt-{index}.json",
                            run_command=FakeCommandRunner(),
                            signing_time=lambda: SIGNING_TIME,
                        )

    def test_rejects_dmg_mutation_after_signature_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            disk_image = base / "EasySplat.dmg"
            disk_image.write_bytes(b"unsigned disk image")
            receipt = base / "receipt.json"

            class MutatingRunner(FakeCommandRunner):
                changed = False

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    result = super().__call__(command)
                    if (
                        not self.changed
                        and command[:3]
                        == ["/usr/bin/codesign", "--display", "--verbose=4"]
                    ):
                        disk_image.write_bytes(
                            disk_image.read_bytes() + b"post-verification mutation"
                        )
                        self.changed = True
                    return result

            with self.assertRaisesRegex(MODULE.SigningError, "changed during signature verification"):
                MODULE.sign_distribution_dmg(
                    disk_image,
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=MutatingRunner(),
                    signing_time=lambda: SIGNING_TIME,
                )

    def test_receipt_parent_swap_cannot_replace_the_signed_disk_image(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            artifacts = base / "artifacts"
            artifacts.mkdir()
            disk_image = artifacts / "EasySplat.dmg"
            disk_image.write_bytes(b"unsigned disk image")
            receipts = base / "receipts"
            receipts.mkdir()
            displaced = base / "receipts-original"
            receipt = receipts / disk_image.name

            class SwappingRunner(FakeCommandRunner):
                swapped = False

                def __call__(self, command: list[str]) -> subprocess.CompletedProcess[str]:
                    result = super().__call__(command)
                    if (
                        not self.swapped
                        and command[:3]
                        == ["/usr/bin/codesign", "--display", "--verbose=4"]
                    ):
                        receipts.rename(displaced)
                        receipts.symlink_to(artifacts, target_is_directory=True)
                        self.swapped = True
                    return result

            runner = SwappingRunner(metadata=metadata_output(runtime=False))
            with self.assertRaisesRegex(MODULE.SigningError, "receipt|changed"):
                MODULE.sign_distribution_dmg(
                    disk_image,
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    receipt_path=receipt,
                    run_command=runner,
                    signing_time=lambda: SIGNING_TIME,
                )
            self.assertTrue(runner.swapped)
            self.assertFalse(disk_image.read_bytes().lstrip().startswith(b"{"))
            self.assertFalse((displaced / disk_image.name).exists())


class DistributionSignatureVerificationTests(unittest.TestCase):
    def test_receipt_internal_artifact_digests_are_exactly_cross_linked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            app_receipt = base / "app-signing.json"
            app_payload = MODULE.sign_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=app_receipt,
                run_command=FakeCommandRunner(),
                signing_time=lambda: SIGNING_TIME,
            )
            app_bundle = next(
                entry for entry in app_payload["entries"] if entry["kind"] == "appBundle"
            )
            self.assertRegex(
                app_payload["artifactDigest"]["postSignSHA256"], r"^[0-9a-f]{64}$"
            )
            self.assertEqual(
                app_bundle["postSignSHA256"],
                app_payload["tree"]["postSignManifestSHA256"],
            )

            for field in ("bundle", "tree"):
                with self.subTest(kind="app", field=field):
                    changed = json.loads(json.dumps(app_payload))
                    if field == "bundle":
                        next(
                            entry
                            for entry in changed["entries"]
                            if entry["kind"] == "appBundle"
                        )["postSignSHA256"] = "f" * 64
                    else:
                        changed["tree"]["postSignManifestSHA256"] = "f" * 64
                    app_receipt.write_text(json.dumps(changed), encoding="utf-8")
                    with self.assertRaisesRegex(MODULE.SigningError, "digest"):
                        MODULE.validate_signing_receipt(
                            app_receipt,
                            kind="app",
                            identity_fingerprint=FINGERPRINT,
                            team_id=TEAM_ID,
                        )

            dmg = base / "EasySplat.dmg"
            dmg.write_bytes(b"unsigned")
            dmg_receipt = base / "dmg-signing.json"
            dmg_payload = MODULE.sign_distribution_dmg(
                dmg,
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=dmg_receipt,
                run_command=FakeCommandRunner(metadata=metadata_output(runtime=False)),
                signing_time=lambda: SIGNING_TIME,
            )
            self.assertEqual(
                dmg_payload["artifactDigest"]["postSignSHA256"],
                dmg_payload["entries"][0]["postSignSHA256"],
            )
            dmg_payload["artifactDigest"]["postSignSHA256"] = "f" * 64
            dmg_receipt.write_text(json.dumps(dmg_payload), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.SigningError, "digest"):
                MODULE.validate_signing_receipt(
                    dmg_receipt,
                    kind="dmg",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                )

    def test_pre_staple_receipt_binding_rejects_stale_artifact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            dmg = base / "EasySplat.dmg"
            dmg.write_bytes(b"unsigned")
            receipt = base / "dmg-signing.json"
            MODULE.sign_distribution_dmg(
                dmg,
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
                run_command=FakeCommandRunner(metadata=metadata_output(runtime=False)),
                signing_time=lambda: SIGNING_TIME,
            )
            MODULE.validate_signing_receipt(
                receipt,
                kind="dmg",
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                current_artifact=dmg,
            )
            dmg.write_bytes(dmg.read_bytes() + b"stale receipt")
            with self.assertRaisesRegex(MODULE.SigningError, "current artifact"):
                MODULE.validate_signing_receipt(
                    receipt,
                    kind="dmg",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    current_artifact=dmg,
                )

    def test_signing_receipt_swap_and_restore_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            dmg = base / "EasySplat.dmg"
            dmg.write_bytes(b"unsigned")
            receipt = base / "dmg-signing.json"
            payload = MODULE.sign_distribution_dmg(
                dmg,
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
                run_command=FakeCommandRunner(metadata=metadata_output(runtime=False)),
                signing_time=lambda: SIGNING_TIME,
            )
            attacker = base / "attacker.json"
            attacker.write_text(json.dumps(payload), encoding="utf-8")
            original = base / "original.json"
            real_open = MODULE.os.open
            swapped = False

            def swapping_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
                nonlocal swapped
                if not swapped and Path(path) == receipt:
                    swapped = True
                    receipt.rename(original)
                    attacker.rename(receipt)
                    descriptor = real_open(path, flags, *args, **kwargs)
                    receipt.rename(attacker)
                    original.rename(receipt)
                    return descriptor
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(MODULE.os, "open", side_effect=swapping_open):
                with self.assertRaisesRegex(MODULE.SigningError, "changed|identity"):
                    MODULE.validate_signing_receipt(
                        receipt,
                        kind="dmg",
                        identity_fingerprint=FINGERPRINT,
                        team_id=TEAM_ID,
                    )
            self.assertTrue(swapped)
            self.assertTrue(receipt.exists())

    def test_current_artifact_file_swap_and_restore_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            dmg = base / "EasySplat.dmg"
            dmg.write_bytes(b"unsigned")
            receipt = base / "dmg-signing.json"
            MODULE.sign_distribution_dmg(
                dmg,
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
                run_command=FakeCommandRunner(metadata=metadata_output(runtime=False)),
                signing_time=lambda: SIGNING_TIME,
            )
            attacker = base / "attacker.dmg"
            attacker.write_bytes(dmg.read_bytes())
            original = base / "original.dmg"
            real_open = MODULE.os.open
            swapped = False

            def swapping_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
                nonlocal swapped
                if not swapped and Path(path) == dmg:
                    swapped = True
                    dmg.rename(original)
                    attacker.rename(dmg)
                    descriptor = real_open(path, flags, *args, **kwargs)
                    dmg.rename(attacker)
                    original.rename(dmg)
                    return descriptor
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(MODULE.os, "open", side_effect=swapping_open):
                with self.assertRaisesRegex(MODULE.SigningError, "identity|changed"):
                    MODULE.validate_signing_receipt(
                        receipt,
                        kind="dmg",
                        identity_fingerprint=FINGERPRINT,
                        team_id=TEAM_ID,
                        current_artifact=dmg,
                    )
            self.assertTrue(swapped)

    def test_current_app_tree_addition_during_hash_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = write_app(root)
            real_scandir = MODULE.os.scandir
            added = False

            def adding_scandir(path: object):
                nonlocal added
                entries = list(real_scandir(path))
                if not added and (isinstance(path, int) or Path(path) == app):
                    added = True
                    (app / "late-file").write_bytes(b"late")
                return entries

            with mock.patch.object(MODULE.os, "scandir", side_effect=adding_scandir):
                with self.assertRaisesRegex(MODULE.SigningError, "changed"):
                    MODULE.artifact_sha256(app)
            self.assertTrue(added)

    def test_current_app_digest_cannot_hash_a_swapped_root_twice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            expected = MODULE.artifact_sha256(app)
            attacker_parent = base / "attacker-root"
            attacker_parent.mkdir()
            attacker = base / "Attacker.app"
            write_app(attacker_parent, executable_name="Attacker").rename(attacker)
            (attacker / "Contents/MacOS/Attacker").write_bytes(
                MACHO_MAGICS[0] + b"different attacker app\n"
            )
            original = base / "Original.app"
            real_snapshot = MODULE.snapshot_tree
            calls = 0

            def swapping_snapshot(root: Path):
                nonlocal calls
                if Path(root) != app:
                    return real_snapshot(root)
                if calls == 0:
                    app.rename(original)
                    attacker.rename(app)
                snapshot = real_snapshot(root)
                calls += 1
                if calls == 2:
                    app.rename(attacker)
                    original.rename(app)
                return snapshot

            with mock.patch.object(MODULE, "snapshot_tree", side_effect=swapping_snapshot):
                self.assertEqual(MODULE.artifact_sha256(app), expected)
            self.assertEqual(app.name, "EasySplat.app")
            self.assertEqual(calls, 0)

    def test_validates_signing_receipt_identity_and_rejects_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            disk_image = base / "EasySplat.dmg"
            disk_image.write_bytes(b"unsigned disk image")
            receipt = base / "dmg-signing.json"
            MODULE.sign_distribution_dmg(
                disk_image,
                identity_fingerprint=FINGERPRINT,
                team_id=TEAM_ID,
                receipt_path=receipt,
                run_command=FakeCommandRunner(metadata=metadata_output(runtime=False)),
                signing_time=lambda: SIGNING_TIME,
            )

            payload = MODULE.validate_signing_receipt(
                receipt,
                kind="dmg",
                identity_fingerprint=FINGERPRINT.lower(),
                team_id=TEAM_ID,
            )
            self.assertEqual(payload["identityFingerprintSHA1"], FINGERPRINT)
            self.assertEqual(
                payload["entries"][0]["codesign"]["leafCertificateSHA1"],
                FINGERPRINT,
            )

            payload["entries"][0]["identityFingerprintSHA1"] = "F" * 40
            receipt.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.SigningError, "requested identity"):
                MODULE.validate_signing_receipt(
                    receipt,
                    kind="dmg",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                )

    def test_verifies_the_exact_embedded_leaf_and_team_without_resigning(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            nested = app / "Contents/Frameworks/Engine.framework/Versions/A/Engine"
            write_macho(nested)
            runner = FakeCommandRunner()

            payload = MODULE.verify_distribution_tree(
                app,
                kind="app",
                identity_fingerprint=FINGERPRINT.lower(),
                team_id=TEAM_ID,
                run_command=runner,
            )

            self.assertEqual(payload["identityFingerprintSHA1"], FINGERPRINT)
            self.assertEqual(payload["teamID"], TEAM_ID)
            self.assertEqual(payload["rootKind"], "app")
            self.assertEqual(
                [entry["relativePath"] for entry in payload["entries"]],
                [
                    "Contents/Frameworks/Engine.framework/Versions/A/Engine",
                    "Contents/MacOS/EasySplat",
                    ".",
                ],
            )
            self.assertFalse(
                any(
                    command[:3] == ["/usr/bin/codesign", "--force", "--sign"]
                    for command in runner.commands
                )
            )
            display_commands = [
                command
                for command in runner.commands
                if command[:3]
                == ["/usr/bin/codesign", "--display", "--verbose=4"]
            ]
            self.assertEqual(len(display_commands), 3)
            for command in display_commands:
                certificate_options = [
                    value
                    for value in command
                    if value.startswith("--extract-certificates")
                ]
                self.assertEqual(len(certificate_options), 1)
                self.assertRegex(
                    certificate_options[0], r"^--extract-certificates=/.+"
                )
                self.assertNotIn("--extract-certificates", command)
            for entry in payload["entries"]:
                self.assertEqual(
                    entry["codesign"]["leafCertificateSHA1"], FINGERPRINT
                )

    def test_rejects_a_valid_signature_from_another_leaf_certificate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = write_app(base)
            runner = FakeCommandRunner(
                embedded_certificate_der=b"different valid leaf certificate"
            )

            with self.assertRaisesRegex(
                MODULE.SigningError, "leaf certificate fingerprint"
            ):
                MODULE.verify_distribution_tree(
                    app,
                    kind="app",
                    identity_fingerprint=FINGERPRINT,
                    team_id=TEAM_ID,
                    run_command=runner,
                )


class SignedPackagingScriptTrustTests(unittest.TestCase):
    def test_production_mode_requires_distribution_identity_before_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_build = root / "app-build"
            dmg_build = root / "dmg-build"
            dmg_output = root / "dmg-output"

            app_result = subprocess.run(
                [
                    str(BUILD_APP_SCRIPT),
                    "--manifest-url",
                    "https://example.test/manifest.json",
                    "--public-key-path",
                    "/tmp/missing-public-key",
                    "--version",
                    "0.2.0",
                    "--bootstrap-manifest",
                    "/tmp/missing-manifest",
                    "--bootstrap-core-archive",
                    "/tmp/missing-core.zip",
                    "--build-root",
                    str(app_build),
                    "--production",
                ],
                cwd=BUILD_APP_SCRIPT.parents[2],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(app_result.returncode, 0)
            self.assertIn(
                "Production builds require an exact 40-hex Developer ID fingerprint.",
                app_result.stderr,
            )
            self.assertFalse(app_build.exists())

            dmg_result = subprocess.run(
                [
                    str(BUILD_DMG_SCRIPT),
                    "--app-version",
                    "0.2.0",
                    "--toolchain-version",
                    "2.0.0",
                    "--manifest-url",
                    "https://example.test/manifest.json",
                    "--core-artifact-url",
                    "https://example.test/core.zip",
                    "--da3-base-artifact-url",
                    "https://example.test/base.zip",
                    "--da3-small-artifact-url",
                    "https://example.test/small.zip",
                    "--use-existing-toolchain",
                    "--build-root",
                    str(dmg_build),
                    "--output-dir",
                    str(dmg_output),
                    "--production",
                ],
                cwd=BUILD_DMG_SCRIPT.parents[2],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(dmg_result.returncode, 0)
            self.assertIn(
                "Production packaging requires an exact 40-hex Developer ID fingerprint.",
                dmg_result.stderr,
            )
            self.assertFalse(dmg_build.exists())
            self.assertFalse(dmg_output.exists())

    def test_app_build_pins_xcode_and_macos_15_without_inherited_selectors(self) -> None:
        source = BUILD_APP_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("unset DEVELOPER_DIR SDKROOT TOOLCHAINS", source)
        self.assertIn("MACOSX_DEPLOYMENT_TARGET=15.0", source)
        self.assertIn("SDKROOT=macosx", source)
        self.assertIn("XCRUN_BIN=/usr/bin/xcrun", source)
        self.assertIn("/usr/bin/swift run", source)
        self.assertNotIn("if ! xcrun -sdk macosx metal", source)

        dmg_source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("unset DEVELOPER_DIR SDKROOT TOOLCHAINS", dmg_source)
        self.assertIn("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer", dmg_source)
        self.assertIn("MACOSX_DEPLOYMENT_TARGET=15.0", dmg_source)

    def test_prepared_release_keeps_nonfinal_metadata_until_signing(self) -> None:
        source = BUILD_APP_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("--prepare-release", source)
        self.assertIn('RELEASE_MODE="prepare-release"', source)
        self.assertNotIn('APP_RELEASE_CHANNEL="production"', source)
        self.assertIn("prepared release candidate", source)
        prepared_branch = source.split(
            'if [ "$RELEASE_MODE" = prepare-release ]; then', 1
        )[1].split("fi\n", 1)[0]
        self.assertNotIn("IDENTITY_FINGERPRINT", prepared_branch)
        self.assertNotIn("NOTARY", prepared_branch)

        dmg_source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")
        prepared_check = dmg_source.index(
            "Prepared app must remain labeled prepare-release"
        )
        final_channel = dmg_source.index(
            '/usr/bin/plutil -replace EasySplatReleaseChannel -string production'
        )
        developer_id_sign = dmg_source.index(
            '"$ROOT/scripts/release/sign_macos_distribution.py" \\\n'
            '    --root "$PACKAGE_BUILD_ROOT/Export/EasySplat.app"'
        )
        self.assertLess(prepared_check, final_channel)
        self.assertLess(final_channel, developer_id_sign)

    def test_signed_entrypoints_use_fixed_shell_and_reject_build_overrides(self) -> None:
        for script in (
            BUILD_APP_SCRIPT,
            BUILD_DMG_SCRIPT,
            CREATE_DMG_SCRIPT,
            NOTARIZE_SCRIPT,
        ):
            with self.subTest(script=script.name):
                self.assertEqual(
                    script.read_text(encoding="utf-8").splitlines()[0],
                    "#!/bin/bash -p",
                )

        environment = os.environ.copy()
        environment["EASYSPLAT_XCODEBUILD_BIN"] = "/tmp/attacker-xcodebuild"
        app_result = subprocess.run(
            [
                str(BUILD_APP_SCRIPT),
                "--manifest-url",
                "https://example.test/manifest.json",
                "--public-key-path",
                "/tmp/missing-public-key",
                "--version",
                "0.2.0",
                "--bootstrap-manifest",
                "/tmp/missing-manifest",
                "--bootstrap-core-archive",
                "/tmp/missing-core.zip",
                "--production",
                "--identity-fingerprint",
                FINGERPRINT,
                "--team-id",
                TEAM_ID,
            ],
            cwd=BUILD_APP_SCRIPT.parents[2],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(app_result.returncode, 0)
        self.assertIn("build command overrides are not permitted", app_result.stderr)
        self.assertNotIn("attacker-xcodebuild", app_result.stderr)

        environment = os.environ.copy()
        environment["EASYSPLAT_HDIUTIL_BIN"] = "/tmp/attacker-hdiutil"
        dmg_result = subprocess.run(
            [
                str(BUILD_DMG_SCRIPT),
                "--app-version",
                "0.2.0",
                "--toolchain-version",
                "2.0.0",
                "--manifest-url",
                "https://example.test/manifest.json",
                "--core-artifact-url",
                "https://example.test/core.zip",
                "--da3-base-artifact-url",
                "https://example.test/base.zip",
                "--da3-small-artifact-url",
                "https://example.test/small.zip",
                "--use-existing-toolchain",
                "--production",
                "--identity-fingerprint",
                FINGERPRINT,
                "--team-id",
                TEAM_ID,
                "--notary-keychain-profile",
                "easysplat-release",
            ],
            cwd=BUILD_DMG_SCRIPT.parents[2],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(dmg_result.returncode, 0)
        self.assertIn("build command overrides are not permitted", dmg_result.stderr)
        self.assertNotIn("attacker-hdiutil", dmg_result.stderr)

    def test_signed_shell_entrypoints_ignore_bash_env_startup_code(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            startup = base / "startup.sh"
            marker = base / "bash-env-executed"
            startup.write_text(
                'printf "executed\\n" >"$EASYSPLAT_BASH_ENV_MARKER"\n',
                encoding="utf-8",
            )
            startup.chmod(0o600)
            environment = os.environ.copy()
            environment["BASH_ENV"] = str(startup)
            environment["EASYSPLAT_BASH_ENV_MARKER"] = str(marker)

            for script in (
                BUILD_APP_SCRIPT,
                BUILD_DMG_SCRIPT,
                CREATE_DMG_SCRIPT,
                NOTARIZE_SCRIPT,
            ):
                with self.subTest(script=script.name):
                    marker.unlink(missing_ok=True)
                    result = subprocess.run(
                        [str(script)],
                        cwd=SCRIPT.parents[2],
                        env=environment,
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(marker.exists())

    def test_release_packaging_uses_fixed_isolated_system_python(self) -> None:
        dmg_source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        trusted_invocation = (
            '/usr/bin/python3 -I '
            '"$ROOT/scripts/release/generate_release_metadata.py"'
        )
        self.assertEqual(dmg_source.count(trusted_invocation), 2)
        self.assertNotIn(
            'python3 "$ROOT/scripts/release/generate_release_metadata.py"',
            dmg_source.replace(trusted_invocation, ""),
        )
        for script in (BUILD_APP_SCRIPT, BUILD_DMG_SCRIPT):
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                self.assertIsNone(
                    re.search(r"(?<![/A-Za-z0-9_])python3(?:\s|$)", source)
                )
        notary_source = NOTARIZE_SCRIPT.read_text(encoding="utf-8")
        self.assertEqual(
            notary_source.count("/usr/bin/python3 "),
            notary_source.count("/usr/bin/python3 -I "),
        )
        self.assertNotIn("shasum", dmg_source)
        self.assertIn("hashlib.sha256", dmg_source)
        self.assertIn("ZIPOPT='' /usr/bin/zip", dmg_source)
        self.assertIn("ZIPOPT='' /usr/bin/zip -qryX", dmg_source)

    def test_signed_dmg_reverifies_exact_app_identity_after_stapling(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        app_notary = source.index(
            'EASYSPLAT_NOTARY_TEST_MODE=0 '
            '"$ROOT/scripts/release/notarize_artifact.sh"'
        )
        exact_verification = source.index("--verify-only", app_notary)
        dmg_creation = source.index('"$ROOT/scripts/release/create_dmg.sh"')
        self.assertLess(app_notary, exact_verification)
        self.assertLess(exact_verification, dmg_creation)

    def test_signed_app_reverifies_exact_identity_before_success(self) -> None:
        source = BUILD_APP_SCRIPT.read_text(encoding="utf-8")

        self.assertEqual(source.count("--verify-only"), 1)
        exact_verification = source.index("--verify-only")
        completion = source.index("SIGNED_BUILD_COMPLETE=1")
        self.assertLess(exact_verification, completion)

    def test_signed_dmg_uses_transactional_publication_helper(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            '/usr/bin/python3 -I '
            '"$ROOT/scripts/release/publish_release_files.py"',
            source,
        )
        self.assertNotIn('mv -f "$source" "$destination"', source)
        self.assertTrue(PUBLISH_SCRIPT.is_file())

    def test_dmg_build_uses_a_run_private_app_build_root(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('PACKAGE_BUILD_ROOT="$(mktemp -d ', source)
        self.assertIn('--build-root "$PACKAGE_BUILD_ROOT"', source)
        self.assertIn('APP_PATH="$PACKAGE_BUILD_ROOT/Export/EasySplat.app"', source)
        self.assertNotIn('APP_PATH="$BUILD_ROOT/Export/EasySplat.app"', source)

    def test_credentialed_packaging_can_only_consume_a_prepared_product_without_compiling(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("--prepared-release-root", source)
        self.assertIn('PREPARED_APP="$PREPARED_RELEASE_ROOT/product/EasySplat.app"', source)
        self.assertIn('PREPARED_DSYM="$PREPARED_RELEASE_ROOT/product/EasySplat.app.dSYM"', source)
        self.assertIn('--manifest-tool-bin', source)
        self.assertIn('manifest_tool=("$MANIFEST_TOOL_BIN")', source)
        self.assertIn(
            'Trusted ManifestTool must be outside the prepared artifact.', source
        )
        self.assertNotIn(
            'PREPARED_MANIFEST_TOOL="$PREPARED_RELEASE_ROOT/product/ManifestTool"',
            source,
        )
        self.assertIn('if [ -n "$PREPARED_RELEASE_ROOT" ]; then', source)
        self.assertIn('SOURCE_COMMIT="$SOURCE_COMMIT_OVERRIDE"', source)

    def test_credentialed_packaging_reverifies_the_pinned_prepared_closure_before_copy(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")
        invocation = (
            '/usr/bin/python3 -I '
            '"$ROOT/scripts/release/prepared_release.py" verify'
        )

        self.assertIn(invocation, source)
        self.assertIn(
            '--expected-manifest-sha256 "$PREPARED_MANIFEST_SHA256"',
            source,
        )
        verification = source.index(invocation)
        prepared_copy = source.index(
            '/usr/bin/ditto --noqtn',
            source.index('PREPARED_INFO_PLIST="$PREPARED_APP/Contents/Info.plist"'),
        )
        self.assertLess(verification, prepared_copy)

    def test_signed_dmg_is_verified_after_stapling_before_checksum_publication(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")
        final_verification = '/usr/bin/hdiutil verify "$DMG_PATH"'

        self.assertIn(final_verification, source)
        notarization = source.rindex(
            '"$ROOT/scripts/release/verify_notarization_receipt.py"'
        )
        disk_image_verification = source.index(final_verification, notarization)
        checksum = source.index('CHECKSUM_PATH="$DMG_PATH.sha256"')
        self.assertLess(notarization, disk_image_verification)
        self.assertLess(disk_image_verification, checksum)

    def test_dmg_build_recovers_interrupted_publication_before_packaging(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        recovery = source.index("--recover-only")
        app_build = source.index('"$ROOT/scripts/release/build_app.sh"')
        self.assertLess(recovery, app_build)

    def test_signed_dmg_binds_notary_receipts_through_publication(self) -> None:
        source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        invocation = (
            '/usr/bin/python3 -I '
            '"$ROOT/scripts/release/verify_notarization_receipt.py"'
        )
        self.assertEqual(source.count(invocation), 2)
        self.assertIn('--signing-receipt "$APP_SIGNING_RECEIPT"', source)
        self.assertIn('--signing-receipt "$DMG_SIGNING_RECEIPT"', source)
        self.assertIn('--expected-sha256 "$FINAL_DMG_NAME=$FINAL_DMG_SHA256"', source)
        self.assertTrue(NOTARY_RECEIPT_VERIFIER.is_file())

    def test_release_verifier_requires_signed_receipts_without_adhoc_fallback(self) -> None:
        source = VERIFY_RELEASE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('--release-mode) RELEASE_MODE="$2"', source)
        self.assertIn('if [ "$RELEASE_MODE" = production ]; then', source)
        for option in (
            "--app-signing-receipt",
            "--app-notarization-receipt",
            "--dmg-signing-receipt",
            "--dmg-notarization-receipt",
        ):
            self.assertIn(option, source)
        self.assertIn('flags=0x10000(runtime)', source)
        self.assertIn('Authority=Developer ID Application:', source)
        self.assertIn('--context context:primary-signature', source)
        self.assertIn('--release-mode "$RELEASE_MODE"', source)

    def test_dmg_creation_uses_private_staging_and_binds_the_stapled_app(self) -> None:
        source = CREATE_DMG_SCRIPT.read_text(encoding="utf-8")
        build_source = BUILD_DMG_SCRIPT.read_text(encoding="utf-8")

        self.assertNotIn("$ROOT/build/dmg_staging", source)
        self.assertIn(".EasySplat-dmg-staging.XXXXXX", source)
        self.assertIn("verify_app_receipt \"$APP_PATH\"", source)
        self.assertIn("verify_app_receipt \"$STAGED_APP\"", source)
        self.assertGreaterEqual(source.count("verify_app_receipt \"$app_path\""), 5)
        self.assertIn(
            '--app-notarization-receipt "$APP_NOTARY_RECEIPT"', build_source
        )

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            app = base / "EasySplat.app"
            executable = app / "Contents/MacOS/EasySplatApp"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"signed and stapled app")
            digest = NOTARY_MODULE.artifact_sha256(app)
            receipt = base / "app-notarization.json"
            receipt.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "artifactType": "app",
                        "artifactDigestFormat": "sha256-tree-v1",
                        "submissionID": "a2a4ed8f-4d52-47d5-bf09-0c682d8146c9",
                        "status": "Accepted",
                        "preStapleSHA256": "0" * 64,
                        "postStapleSHA256": digest,
                        "stapled": True,
                        "verification": {
                            "codesign": "passed",
                            "systemPolicy": "passed",
                            "stapler": "passed",
                            "gatekeeper": "passed",
                        },
                        "downstreamChecksums": "generate-after-notarization",
                    }
                ),
                encoding="utf-8",
            )
            log = base / "hdiutil.log"
            bin_dir = base / "bin"
            bin_dir.mkdir()
            passthrough = "#!/bin/bash -p\nset -euo pipefail\nexit 0\n"
            for name in ("codesign", "xcrun", "spctl", "syspolicy_check"):
                shim = bin_dir / name
                shim.write_text(passthrough, encoding="utf-8")
                shim.chmod(0o700)
            hdiutil = base / "hdiutil"
            hdiutil.write_text(
                "#!/bin/bash -p\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$*\" >>\"$EASYSPLAT_TEST_HDIUTIL_LOG\"\n"
                "if [ \"$1\" = create ]; then printf 'dmg' >\"${@: -1}\"; fi\n",
                encoding="utf-8",
            )
            hdiutil.chmod(0o700)
            output = base / "EasySplat.dmg"
            environment = os.environ.copy()
            for name in ("GITHUB_PERSONAL_ACCESS_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
                environment.pop(name, None)
            environment.update(
                {
                    "EASYSPLAT_NOTARY_TEST_MODE": "1",
                    "EASYSPLAT_NOTARY_CODESIGN_BIN": str(bin_dir / "codesign"),
                    "EASYSPLAT_NOTARY_XCRUN_BIN": str(bin_dir / "xcrun"),
                    "EASYSPLAT_NOTARY_SPCTL_BIN": str(bin_dir / "spctl"),
                    "EASYSPLAT_NOTARY_SYSPOLICY_BIN": str(
                        bin_dir / "syspolicy_check"
                    ),
                    "EASYSPLAT_HDIUTIL_BIN": str(hdiutil),
                    "EASYSPLAT_TEST_HDIUTIL_LOG": str(log),
                }
            )

            result = subprocess.run(
                [
                    str(CREATE_DMG_SCRIPT),
                    "--app-path",
                    str(app),
                    "--out",
                    str(output),
                    "--app-notarization-receipt",
                    str(receipt),
                ],
                cwd=SCRIPT.parents[2],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            create_line = log.read_text(encoding="utf-8").splitlines()[0]
            arguments = create_line.split()
            staging = Path(arguments[arguments.index("-srcfolder") + 1])
            self.assertEqual(staging.parent, output.parent)
            self.assertFalse(staging.exists())


if __name__ == "__main__":
    unittest.main()
