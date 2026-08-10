#!/usr/bin/env python3
"""Hermetic tests for the MAS/TestFlight provenance gate."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/release/mas_release_evidence.py"
SIGNING_MODULE_PATH = ROOT / "scripts/release/sign_macos_distribution.py"
BUILD_SCRIPT = ROOT / "scripts/release/build_mas_package.sh"
BUILD_APP_SCRIPT = ROOT / "scripts/release/build_app.sh"
TEAM_ID = "A1B2C3D4E5"
BUNDLE_ID = "com.easysplat.app"
APP_VERSION = "0.2.0"
APP_BUILD = "0.2.7"
CDHASH = "0123456789abcdef0123456789abcdef01234567"
APP_IDENTITY_FINGERPRINT = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
SOURCE_SEAL_RELATIVE = "Contents/Resources/release_source.json"


class FixtureCommandRunner:
    """Returns production-shaped inspection output without signing credentials."""

    def __init__(self) -> None:
        self.app_entitlement_variant = 0
        self.architectures_by_suffix: dict[str, str] = {}
        self.entitlements_by_suffix: dict[str, dict[str, object] | None] = {}
        self.signature_teams_by_suffix: dict[str, str] = {}
        self.calls: list[list[str]] = []
        self.package_authority_name = "EasySplat Test"
        self.package_team_id = TEAM_ID
        self.package_layout_mutation: str | None = None
        self.signature_authority = f"Apple Distribution: EasySplat Test ({TEAM_ID})"
        self.store_requirement_failure_target: str | None = None

    def __call__(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        self.calls.append(arguments)
        target = arguments[-1]
        if arguments[:2] == ["/usr/bin/lipo", "-archs"]:
            architecture = next(
                (
                    value
                    for suffix, value in self.architectures_by_suffix.items()
                    if target.endswith(suffix)
                ),
                "arm64",
            )
            return subprocess.CompletedProcess(arguments, 0, architecture + "\n", "")
        if arguments[:2] == ["/usr/bin/codesign", "--verify"]:
            if (
                "--test-requirement" in arguments
                and self.store_requirement_failure_target is not None
                and self.store_requirement_failure_target in target
            ):
                return subprocess.CompletedProcess(
                    arguments, 1, "", "store requirement rejected\n"
                )
            return subprocess.CompletedProcess(arguments, 0, "", "")
        if arguments[:3] == ["/usr/bin/codesign", "--display", "--verbose=4"]:
            team = next(
                (
                    value
                    for suffix, value in self.signature_teams_by_suffix.items()
                    if target.endswith(suffix)
                ),
                TEAM_ID,
            )
            metadata = (
                f"Executable={target}\n"
                f"Identifier={BUNDLE_ID}\n"
                f"CDHash={CDHASH}\n"
                f"Authority={self.signature_authority}\n"
                f"TeamIdentifier={team}\n"
            )
            return subprocess.CompletedProcess(arguments, 0, "", metadata)
        if arguments[:3] == ["/usr/bin/codesign", "--display", "--entitlements"]:
            override = next(
                (
                    value
                    for suffix, value in self.entitlements_by_suffix.items()
                    if target.endswith(suffix)
                ),
                ...,
            )
            if override is not ...:
                entitlements = override
            elif target.endswith(("/colmap", "/easysplat-train")):
                entitlements = {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.inherit": True,
                }
            elif target.endswith((".app", "/EasySplatApp")):
                entitlements = {
                    "com.apple.application-identifier": f"{TEAM_ID}.{BUNDLE_ID}",
                    "com.apple.developer.team-identifier": TEAM_ID,
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.files.user-selected.read-write": True,
                }
                if self.app_entitlement_variant:
                    entitlements["com.apple.security.network.client"] = True
            else:
                entitlements = None
            if entitlements is None:
                return subprocess.CompletedProcess(
                    arguments, 0, "", f"Executable={target}\n"
                )
            return subprocess.CompletedProcess(
                arguments,
                0,
                plistlib.dumps(entitlements, fmt=plistlib.FMT_XML).decode("utf-8"),
                "",
            )
        if arguments[:2] == ["/usr/sbin/pkgutil", "--expand-full"]:
            package = Path(arguments[-2])
            app = package.with_name("EasySplat.app")
            destination = Path(arguments[-1])
            component = destination / "com.easysplat.app.pkg"
            payload = component / "Payload"
            payload.mkdir(parents=True)
            (destination / "Distribution").write_text(
                "<?xml version=\"1.0\"?><installer-gui-script minSpecVersion=\"1\"/>\n",
                encoding="utf-8",
            )
            (component / "Bom").write_bytes(b"fixture bom\n")
            (component / "PackageInfo").write_text(
                "<?xml version=\"1.0\"?><pkg-info format-version=\"2\" "
                "identifier=\"com.easysplat.app\" version=\"0.2.0\" "
                f"install-location=\"{'/tmp' if self.package_layout_mutation == 'wrong-location' else '/Applications'}\" "
                "auth=\"root\"/>\n",
                encoding="utf-8",
            )
            shutil.copytree(app, payload / app.name, symlinks=True)
            if self.package_layout_mutation == "extra-payload":
                (payload / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
            elif self.package_layout_mutation == "scripts":
                scripts = component / "Scripts"
                scripts.mkdir()
                (scripts / "postinstall").write_text("#!/bin/sh\n", encoding="utf-8")
            elif self.package_layout_mutation == "extra-component":
                extra = destination / "other.pkg"
                extra.mkdir()
                (extra / "PackageInfo").write_text("<pkg-info/>\n", encoding="utf-8")
            elif self.package_layout_mutation == "extra-root":
                (destination / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
            return subprocess.CompletedProcess(arguments, 0, "", "")
        if arguments[:2] == ["/usr/sbin/pkgutil", "--check-signature"]:
            output = (
                f'Package "{target}":\n'
                "   Status: signed by a certificate trusted by macOS\n"
                "   Certificate Chain:\n"
                "    1. 3rd Party Mac Developer Installer: "
                f"{self.package_authority_name} ({self.package_team_id})\n"
                "    2. Apple Worldwide Developer Relations Certification Authority\n"
            )
            return subprocess.CompletedProcess(arguments, 0, output, "")
        raise AssertionError(f"Unexpected fixture command: {arguments!r}")


class MasReleaseEvidenceTests(unittest.TestCase):
    def load_module(self):
        self.assertTrue(MODULE_PATH.is_file(), "MAS release evidence helper is missing")
        spec = importlib.util.spec_from_file_location("mas_release_evidence", MODULE_PATH)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def load_signing_module(self):
        spec = importlib.util.spec_from_file_location(
            "sign_macos_distribution_fixture", SIGNING_MODULE_PATH
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def make_repository(self, root: Path) -> tuple[Path, str]:
        repository = root / "repository"
        repository.mkdir()
        subprocess.run(["/usr/bin/git", "init", "-q", str(repository)], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "config", "user.name", "Fixture"],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/git",
                "-C",
                str(repository),
                "config",
                "user.email",
                "fixture@example.invalid",
            ],
            check=True,
        )
        (repository / "tracked.txt").write_text("reviewed\n", encoding="utf-8")
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "add", "tracked.txt"], check=True
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "commit", "-qm", "baseline"],
            check=True,
        )
        commit = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return repository, commit

    def make_app(self, root: Path, repository: Path) -> Path:
        app = root / "EasySplat.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Helpers/bin").mkdir(parents=True)
        (contents / "Helpers/lib").mkdir(parents=True)
        (contents / "Resources/Toolchain/supply-chain").mkdir(parents=True)
        plist = {
            "CFBundleExecutable": "EasySplatApp",
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleShortVersionString": APP_VERSION,
            "CFBundleVersion": APP_BUILD,
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(plist))
        executable = lambda marker: struct.pack("<IIII", 0xFEEDFACF, 0, 0, 2) + marker
        dynamic_library = lambda marker: struct.pack("<IIII", 0xFEEDFACF, 0, 0, 6) + marker
        for relative, payload in {
            "MacOS/EasySplatApp": executable(b"main-arm64"),
            "Helpers/bin/colmap": executable(b"colmap-arm64"),
            "Helpers/bin/easysplat-train": executable(b"trainer-arm64"),
            "Helpers/lib/libomp.dylib": dynamic_library(b"libomp-arm64"),
            "Resources/Toolchain/default.metallib": b"metallib",
            "Resources/Toolchain/supply-chain/components.json": b'{"schemaVersion":1}\n',
            "embedded.provisionprofile": b"fixture-profile",
        }.items():
            path = contents / relative
            path.write_bytes(payload)
            path.chmod(0o700 if "/bin/" in relative or relative.startswith("MacOS/") else 0o600)
        commit = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        tree = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD^{tree}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        source_seal = {
            "recordType": "easysplatSignedAppSource",
            "schemaVersion": 1,
            "sourceCommit": commit,
            "sourceTreeObjectID": tree,
        }
        seal_path = app / SOURCE_SEAL_RELATIVE
        seal_path.write_text(
            json.dumps(source_seal, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        seal_path.chmod(0o600)
        self.write_app_signing_receipt(app)
        return app

    def write_app_signing_receipt(self, app: Path, *, channel: str = "mas") -> Path:
        signing = self.load_signing_module()
        tree = signing.snapshot_tree(app)
        entitlement_digest = "1" * 64
        codesign = {
            "hardenedRuntime": True,
            "leafCertificateSHA1": APP_IDENTITY_FINGERPRINT,
            "teamIdentifier": TEAM_ID,
            "timestamp": "Aug 9, 2026 at 12:00:00 PM",
        }
        common = {
            "codesign": codesign,
            "embeddedEntitlementsPresent": True,
            "embeddedEntitlementsSHA256": entitlement_digest,
            "entitlementsSHA256": entitlement_digest,
            "entitlementsSourceSHA256": entitlement_digest,
            "identityFingerprintSHA1": APP_IDENTITY_FINGERPRINT,
            "teamID": TEAM_ID,
        }
        main_relative = "Contents/MacOS/EasySplatApp"
        payload = {
            "artifactDigest": {
                "format": "sha256-tree-v1",
                "postSignSHA256": signing.artifact_sha256(app),
            },
            "binaryPolicy": signing.APP_BINARY_POLICY,
            "channel": channel,
            "entitlementPolicy": signing._empty_entitlement_policy(),
            "entries": [
                {
                    **common,
                    "kind": "machO",
                    "relativePath": main_relative,
                },
                {
                    **common,
                    "kind": "appBundle",
                    "mainExecutableRelativePath": main_relative,
                    "postSignSHA256": tree.manifest_sha256,
                    "relativePath": ".",
                },
            ],
            "identityFingerprintSHA1": APP_IDENTITY_FINGERPRINT,
            "mainExecutableRelativePath": main_relative,
            "rootKind": "app",
            "schemaVersion": 1,
            "signedAt": "2026-08-09T16:00:00Z",
            "teamID": TEAM_ID,
            "tree": {
                "postSignManifestSHA256": tree.manifest_sha256,
            },
        }
        receipt = app.with_name(f"{app.name}-signing.json")
        receipt.write_text(
            json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        receipt.chmod(0o600)
        return receipt

    def prepare_fixture(
        self,
        module,
        *,
        root: Path,
        repository: Path,
        app: Path,
        runner: FixtureCommandRunner,
        source_commit: str | None = None,
    ) -> Path:
        prepared = root / "prepared.json"
        module.prepare_evidence(
            repository=repository,
            app=app,
            expected_version=APP_VERSION,
            expected_build=APP_BUILD,
            expected_bundle_id=BUNDLE_ID,
            expected_team_id=TEAM_ID,
            expected_source_commit=source_commit,
            output=prepared,
            command_runner=runner,
        )
        return prepared

    def finalize_fixture(
        self,
        module,
        *,
        root: Path,
        repository: Path,
        app: Path,
        runner: FixtureCommandRunner,
    ) -> tuple[Path, Path]:
        prepared = self.prepare_fixture(
            module,
            root=root,
            repository=repository,
            app=app,
            runner=runner,
        )
        package = root / "EasySplat.pkg"
        package.write_bytes(b"fixture signed installer package\n")
        evidence = root / "EasySplat.pkg.provenance.json"
        module.finalize_evidence(
            repository=repository,
            app=app,
            package=package,
            prepared=prepared,
            expected_team_id=TEAM_ID,
            output=evidence,
            command_runner=runner,
        )
        return package, evidence

    def stage_valid_release_set(
        self,
        module,
        *,
        root: Path,
        repository: Path,
        app: Path,
        runner: FixtureCommandRunner,
    ) -> tuple[Path, Path, dict[str, bytes]]:
        package, evidence = self.finalize_fixture(
            module,
            root=root,
            repository=repository,
            app=app,
            runner=runner,
        )
        output = root / "release"
        output.mkdir(mode=0o700)
        staging = output / ".easysplat-mas-package.fixture"
        staging.mkdir(mode=0o700)
        package_bytes = package.read_bytes()
        staged = {
            "EasySplat.pkg": package_bytes,
            "EasySplat.pkg.provenance.json": evidence.read_bytes(),
            "EasySplat.pkg.sha256": (
                hashlib.sha256(package_bytes).hexdigest() + "\n"
            ).encode("ascii"),
        }
        for name, payload in staged.items():
            (staging / name).write_bytes(payload)
        return output, staging, staged

    def test_prepare_binds_clean_head_and_canonical_app_evidence(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, commit = self.make_repository(root)
            app = self.make_app(root, repository)
            snapshot = root / "prepared.json"
            payload = module.prepare_evidence(
                repository=repository,
                app=app,
                expected_version=APP_VERSION,
                expected_build=None,
                expected_bundle_id=BUNDLE_ID,
                expected_team_id=TEAM_ID,
                expected_source_commit=None,
                output=snapshot,
                command_runner=FixtureCommandRunner(),
            )

            self.assertEqual(payload["source"]["commit"], commit)
            self.assertEqual(payload["app"]["version"], APP_VERSION)
            self.assertEqual(payload["app"]["build"], APP_BUILD)
            self.assertEqual(payload["app"]["bundleID"], BUNDLE_ID)
            self.assertEqual(payload["app"]["architectures"], ["arm64"])
            self.assertEqual(payload["app"]["cdhash"], CDHASH)
            self.assertEqual(payload["app"]["signatureTeamID"], TEAM_ID)
            self.assertRegex(payload["app"]["closureSHA256"], r"^[0-9a-f]{64}$")
            self.assertRegex(payload["toolchain"]["closureSHA256"], r"^[0-9a-f]{64}$")
            self.assertRegex(payload["toolchain"]["provenanceSHA256"], r"^[0-9a-f]{64}$")
            expected_bytes = (
                json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                + "\n"
            ).encode("utf-8")
            self.assertEqual(snapshot.read_bytes(), expected_bytes)
            self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o600)
            self.assertEqual(snapshot.stat().st_nlink, 1)

    def test_prepare_requires_the_canonical_app_signing_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            app.with_name(f"{app.name}-signing.json").unlink()

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "signing receipt"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "prepared.json",
                    command_runner=FixtureCommandRunner(),
                )

    def test_prepare_accepts_an_explicit_app_signing_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            explicit = root / "reviewed-app-signing.json"
            app.with_name(f"{app.name}-signing.json").rename(explicit)

            payload = module.prepare_evidence(
                repository=repository,
                app=app,
                app_signing_receipt=explicit,
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                expected_bundle_id=BUNDLE_ID,
                expected_team_id=TEAM_ID,
                expected_source_commit=None,
                output=root / "prepared.json",
                command_runner=FixtureCommandRunner(),
            )

            self.assertEqual(
                payload["appSigningReceiptSHA256"],
                hashlib.sha256(explicit.read_bytes()).hexdigest(),
            )

    def test_prepare_rejects_a_non_mas_app_signing_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            self.write_app_signing_receipt(app, channel="developer-id")

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "MAS|channel"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "prepared.json",
                    command_runner=FixtureCommandRunner(),
                )

    def test_prepare_requires_the_apple_distribution_certificate_policy(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            runner.store_requirement_failure_target = str(app)

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "signature verification"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "prepared.json",
                    command_runner=runner,
                )

            requirements = [
                call[call.index("--test-requirement") + 1]
                for call in runner.calls
                if "--test-requirement" in call
            ]
            self.assertTrue(requirements)
            self.assertTrue(
                all("1.2.840.113635.100.6.2.1" in value for value in requirements)
            )
            self.assertTrue(
                all("1.2.840.113635.100.6.1.7" in value for value in requirements)
            )
            self.assertTrue(all(TEAM_ID in value for value in requirements))

    def test_authority_label_is_only_a_summary_after_crypto_verification(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            runner.signature_authority = "Non-authoritative display label"

            payload = module.prepare_evidence(
                repository=repository,
                app=app,
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                expected_bundle_id=BUNDLE_ID,
                expected_team_id=TEAM_ID,
                expected_source_commit=None,
                output=root / "prepared.json",
                command_runner=runner,
            )

            self.assertEqual(
                payload["app"]["authorities"], [runner.signature_authority]
            )
            self.assertTrue(
                all(
                    "--test-requirement" in call
                    for call in runner.calls
                    if call[:2] == ["/usr/bin/codesign", "--verify"]
                )
            )

    def test_prepare_requires_the_sealed_app_source_to_match_reviewed_source(self) -> None:
        module = self.load_module()
        for mutation in ("missing", "wrong-commit", "wrong-tree"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, commit = self.make_repository(root)
                app = self.make_app(root, repository)
                seal = app / SOURCE_SEAL_RELATIVE
                if mutation == "missing":
                    seal.unlink()
                else:
                    payload = json.loads(seal.read_text(encoding="utf-8"))
                    key = "sourceCommit" if mutation == "wrong-commit" else "sourceTreeObjectID"
                    payload[key] = "f" * 40
                    seal.write_text(
                        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
                        encoding="utf-8",
                    )
                self.write_app_signing_receipt(app)
                with self.assertRaisesRegex(module.ReleaseEvidenceError, "sealed|source"):
                    module.prepare_evidence(
                        repository=repository,
                        app=app,
                        expected_version=APP_VERSION,
                        expected_build=APP_BUILD,
                        expected_bundle_id=BUNDLE_ID,
                        expected_team_id=TEAM_ID,
                        expected_source_commit=commit,
                        output=root / "prepared.json",
                        command_runner=FixtureCommandRunner(),
                    )

    def test_prepare_enumerates_every_macho_and_enforces_its_policy(self) -> None:
        module = self.load_module()
        mutations = (
            "wrong-architecture",
            "wrong-signer",
            "helper-without-entitlements",
            "dylib-entitlements",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, commit = self.make_repository(root)
                app = self.make_app(root, repository)
                runner = FixtureCommandRunner()
                if mutation == "helper-without-entitlements":
                    relative = "Contents/Helpers/bin/extra-helper"
                    file_type = 2
                    mode = 0o700
                else:
                    relative = "Contents/Helpers/lib/extra.dylib"
                    file_type = 6
                    mode = 0o600
                target = app / relative
                target.write_bytes(
                    struct.pack("<IIII", 0xFEEDFACF, 0, 0, file_type) + b"extra-arm64"
                )
                target.chmod(mode)
                if mutation == "wrong-architecture":
                    runner.architectures_by_suffix["/extra.dylib"] = "x86_64"
                elif mutation == "wrong-signer":
                    runner.signature_teams_by_suffix["/extra.dylib"] = "Z9Y8X7W6V5"
                elif mutation == "dylib-entitlements":
                    runner.entitlements_by_suffix["/extra.dylib"] = {
                        "com.apple.security.app-sandbox": True
                    }
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.prepare_evidence(
                        repository=repository,
                        app=app,
                        expected_version=APP_VERSION,
                        expected_build=APP_BUILD,
                        expected_bundle_id=BUNDLE_ID,
                        expected_team_id=TEAM_ID,
                        expected_source_commit=commit,
                        output=root / "prepared.json",
                        command_runner=runner,
                    )

    def test_prepare_records_the_complete_signed_code_closure(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, commit = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            payload = module.prepare_evidence(
                repository=repository,
                app=app,
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                expected_bundle_id=BUNDLE_ID,
                expected_team_id=TEAM_ID,
                expected_source_commit=commit,
                output=root / "prepared.json",
                command_runner=runner,
            )
            self.assertEqual(
                [row["relativePath"] for row in payload["app"].get("code", [])],
                [
                    "Contents/Helpers/bin/colmap",
                    "Contents/Helpers/bin/easysplat-train",
                    "Contents/Helpers/lib/libomp.dylib",
                    "Contents/MacOS/EasySplatApp",
                ],
            )
            strict_targets = {
                Path(call[-1]).relative_to(app).as_posix()
                for call in runner.calls
                if call[:3] == ["/usr/bin/codesign", "--verify", "--strict"]
                and Path(call[-1]) != app
            }
            self.assertEqual(
                strict_targets,
                {
                    "Contents/Helpers/bin/colmap",
                    "Contents/Helpers/bin/easysplat-train",
                    "Contents/Helpers/lib/libomp.dylib",
                    "Contents/MacOS/EasySplatApp",
                },
            )

    def test_source_seal_requires_an_explicit_clean_reviewed_commit(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, commit = self.make_repository(root)
            output = root / "release_source.json"
            payload = module.seal_source(
                repository=repository,
                source_commit=commit,
                output=output,
            )
            self.assertEqual(
                payload,
                {
                    "recordType": "easysplatSignedAppSource",
                    "schemaVersion": 1,
                    "sourceCommit": commit,
                    "sourceTreeObjectID": subprocess.run(
                        ["/usr/bin/git", "-C", str(repository), "rev-parse", "HEAD^{tree}"],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout.strip(),
                },
            )
            self.assertEqual(
                output.read_bytes(),
                (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode(),
            )
            (repository / "tracked.txt").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "clean"):
                module.seal_source(
                    repository=repository,
                    source_commit=commit,
                    output=root / "dirty.json",
                )

    def test_signed_app_build_requires_the_reviewed_source_commit_before_work(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            result = subprocess.run(
                [
                    str(BUILD_APP_SCRIPT),
                    "--toolchain-dir",
                    str(root / "missing-toolchain"),
                    "--version",
                    APP_VERSION,
                    "--build-root",
                    str(root / "build"),
                    "--app-store",
                    "--provisioning-profile",
                    str(root / "missing-profile"),
                    "--identity-fingerprint",
                    "0" * 40,
                    "--team-id",
                    TEAM_ID,
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("reviewed source commit", result.stderr.lower())
        source = BUILD_APP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'INPUT_SNAPSHOT_DIR="$(cd "$INPUT_SNAPSHOT_DIR" && pwd -P)"',
            source,
        )
        self.assertIn(
            'mktemp -d "/private/tmp/easysplat-release-inputs.XXXXXX"',
            source,
        )
        self.assertIn("--lock-existing", source)
        self.assertGreaterEqual(source.count("--verify-existing"), 2)
        self.assertIn("-file-prefix-map", source)
        self.assertIn("xcodebuild_arguments=(", source)
        self.assertIn('xcodebuild_arguments+=(build)', source)
        self.assertNotIn('${source_mapping_settings[@]}', source)
        self.assertLess(
            source.index("mas_release_evidence.py\" seal-source"),
            source.index("sign_macos_distribution.py"),
        )

    def test_prepare_rejects_a_dirty_checkout(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            (repository / "tracked.txt").write_text("changed\n", encoding="utf-8")

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "must be clean"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "prepared.json",
                    command_runner=FixtureCommandRunner(),
                )

    def test_evidence_publication_never_replaces_a_concurrent_file(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            output = root / "prepared.json"
            real_link = os.link

            def racing_link(source, destination, *args, **kwargs):
                output.write_bytes(b"foreign evidence\n")
                return real_link(source, destination, *args, **kwargs)

            with mock.patch.object(module.os, "link", side_effect=racing_link):
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.prepare_evidence(
                        repository=repository,
                        app=app,
                        expected_version=APP_VERSION,
                        expected_build=APP_BUILD,
                        expected_bundle_id=BUNDLE_ID,
                        expected_team_id=TEAM_ID,
                        expected_source_commit=None,
                        output=output,
                        command_runner=FixtureCommandRunner(),
                    )
            self.assertEqual(output.read_bytes(), b"foreign evidence\n")

    def test_release_set_rejects_sidecars_that_do_not_bind_the_staged_package(self) -> None:
        module = self.load_module()
        for mutation in ("package", "checksum", "evidence"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                output, staging, _ = self.stage_valid_release_set(
                    module,
                    root=root,
                    repository=repository,
                    app=app,
                    runner=FixtureCommandRunner(),
                )
                if mutation == "package":
                    (staging / "EasySplat.pkg").write_bytes(b"different package\n")
                elif mutation == "checksum":
                    (staging / "EasySplat.pkg.sha256").write_bytes(b"0" * 64 + b"\n")
                else:
                    evidence = json.loads(
                        (staging / "EasySplat.pkg.provenance.json").read_text(
                            encoding="utf-8"
                        )
                    )
                    evidence["package"]["sha256"] = "0" * 64
                    (staging / "EasySplat.pkg.provenance.json").write_text(
                        json.dumps(evidence, sort_keys=True, separators=(",", ":")) + "\n",
                        encoding="utf-8",
                    )

                with self.assertRaisesRegex(
                    module.ReleaseEvidenceError,
                    "checksum|evidence|package|release set",
                ):
                    module.publish_release_set(
                        staging_directory=staging,
                        package_output=output / "EasySplat-0.2.0.pkg",
                        evidence_output=output
                        / "EasySplat-0.2.0.pkg.provenance.json",
                        checksum_output=output / "EasySplat-0.2.0.pkg.sha256",
                    )

                self.assertFalse((output / "EasySplat-0.2.0.pkg").exists())
                self.assertFalse(
                    (output / "EasySplat-0.2.0.pkg.provenance.json").exists()
                )
                self.assertFalse((output / "EasySplat-0.2.0.pkg.sha256").exists())

    def test_release_set_fsyncs_bytes_and_sidecars_before_package_commit(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            output, staging, _ = self.stage_valid_release_set(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=FixtureCommandRunner(),
            )
            events: list[tuple[str, str]] = []
            real_fsync = os.fsync
            real_link = os.link

            def recording_fsync(descriptor):
                kind = "directory" if stat.S_ISDIR(os.fstat(descriptor).st_mode) else "file"
                events.append(("fsync", kind))
                return real_fsync(descriptor)

            def recording_link(source, destination, *args, **kwargs):
                events.append(("link", str(destination)))
                return real_link(source, destination, *args, **kwargs)

            with mock.patch.object(module.os, "fsync", side_effect=recording_fsync), mock.patch.object(
                module.os, "link", side_effect=recording_link
            ):
                module.publish_release_set(
                    staging_directory=staging,
                    package_output=output / "EasySplat-0.2.0.pkg",
                    evidence_output=output / "EasySplat-0.2.0.pkg.provenance.json",
                    checksum_output=output / "EasySplat-0.2.0.pkg.sha256",
                )

            package_link = events.index(("link", "EasySplat-0.2.0.pkg"))
            sidecar_links = [
                events.index(("link", "EasySplat-0.2.0.pkg.provenance.json")),
                events.index(("link", "EasySplat-0.2.0.pkg.sha256")),
            ]
            self.assertGreaterEqual(
                sum(event == ("fsync", "file") for event in events[: min(sidecar_links)]),
                3,
            )
            self.assertTrue(
                any(
                    event == ("fsync", "directory")
                    for event in events[max(sidecar_links) + 1 : package_link]
                ),
                events,
            )
            self.assertTrue(
                any(event == ("fsync", "directory") for event in events[package_link + 1 :]),
                events,
            )

    def test_release_set_publishes_the_package_last_and_removes_owned_staging(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            output, staging, staged = self.stage_valid_release_set(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=FixtureCommandRunner(),
            )

            link_order: list[str] = []
            real_link = os.link

            def recording_link(source, destination, *args, **kwargs):
                link_order.append(str(destination))
                return real_link(source, destination, *args, **kwargs)

            with mock.patch.object(module.os, "link", side_effect=recording_link):
                cleaned = module.publish_release_set(
                    staging_directory=staging,
                    package_output=output / "EasySplat-0.2.0.pkg",
                    evidence_output=output / "EasySplat-0.2.0.pkg.provenance.json",
                    checksum_output=output / "EasySplat-0.2.0.pkg.sha256",
                )

            self.assertTrue(cleaned)
            self.assertEqual(link_order[-1], "EasySplat-0.2.0.pkg")
            self.assertFalse(staging.exists())
            for source_name, output_name in (
                ("EasySplat.pkg", "EasySplat-0.2.0.pkg"),
                (
                    "EasySplat.pkg.provenance.json",
                    "EasySplat-0.2.0.pkg.provenance.json",
                ),
                ("EasySplat.pkg.sha256", "EasySplat-0.2.0.pkg.sha256"),
            ):
                published = output / output_name
                self.assertEqual(published.read_bytes(), staged[source_name])
                self.assertEqual(published.stat().st_nlink, 1)

    def test_release_set_rolls_back_owned_sidecars_when_package_appears(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            output, staging, _ = self.stage_valid_release_set(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=FixtureCommandRunner(),
            )

            package = output / "EasySplat-0.2.0.pkg"
            real_link = os.link

            def racing_link(source, destination, *args, **kwargs):
                if destination == package.name:
                    descriptor = os.open(
                        destination,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=kwargs["dst_dir_fd"],
                    )
                    try:
                        os.write(descriptor, b"foreign package\n")
                    finally:
                        os.close(descriptor)
                return real_link(source, destination, *args, **kwargs)

            with mock.patch.object(module.os, "link", side_effect=racing_link):
                with self.assertRaisesRegex(
                    module.ReleaseEvidenceError, "appeared during publication"
                ):
                    module.publish_release_set(
                        staging_directory=staging,
                        package_output=package,
                        evidence_output=output
                        / "EasySplat-0.2.0.pkg.provenance.json",
                        checksum_output=output / "EasySplat-0.2.0.pkg.sha256",
                    )

            self.assertEqual(package.read_bytes(), b"foreign package\n")
            self.assertFalse(
                (output / "EasySplat-0.2.0.pkg.provenance.json").exists()
            )
            self.assertFalse((output / "EasySplat-0.2.0.pkg.sha256").exists())

    def test_release_set_rolls_back_when_directory_sync_fails_after_linking(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            output, staging, _ = self.stage_valid_release_set(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=FixtureCommandRunner(),
            )

            real_fsync = os.fsync
            failed = False

            def failing_fsync(descriptor):
                nonlocal failed
                if stat.S_ISDIR(os.fstat(descriptor).st_mode) and not failed:
                    failed = True
                    raise OSError("fixture fsync failure")
                return real_fsync(descriptor)

            with mock.patch.object(module.os, "fsync", side_effect=failing_fsync):
                with self.assertRaisesRegex(
                    module.ReleaseEvidenceError, "directory sync failed"
                ):
                    module.publish_release_set(
                        staging_directory=staging,
                        package_output=output / "EasySplat-0.2.0.pkg",
                        evidence_output=output
                        / "EasySplat-0.2.0.pkg.provenance.json",
                        checksum_output=output / "EasySplat-0.2.0.pkg.sha256",
                    )

            self.assertFalse((output / "EasySplat-0.2.0.pkg").exists())
            self.assertFalse(
                (output / "EasySplat-0.2.0.pkg.provenance.json").exists()
            )
            self.assertFalse((output / "EasySplat-0.2.0.pkg.sha256").exists())

    def test_release_set_retains_unknown_staging_entries_without_failing_commit(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            output, staging, _ = self.stage_valid_release_set(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=FixtureCommandRunner(),
            )
            (staging / "foreign.txt").write_text("preserve\n", encoding="utf-8")

            cleaned = module.publish_release_set(
                staging_directory=staging,
                package_output=output / "EasySplat-0.2.0.pkg",
                evidence_output=output / "EasySplat-0.2.0.pkg.provenance.json",
                checksum_output=output / "EasySplat-0.2.0.pkg.sha256",
            )

            self.assertFalse(cleaned)
            self.assertEqual(
                (staging / "foreign.txt").read_text(encoding="utf-8"), "preserve\n"
            )
            self.assertTrue((output / "EasySplat-0.2.0.pkg").is_file())

    def test_finalize_and_verify_bind_the_unchanged_app_to_the_exact_package(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, commit = self.make_repository(root)
            app = self.make_app(root, repository)
            prepared = root / "prepared.json"
            evidence = root / "EasySplat.pkg.provenance.json"
            package = root / "EasySplat.pkg"
            package_bytes = b"fixture signed installer package\n"
            package.write_bytes(package_bytes)
            runner = FixtureCommandRunner()
            module.prepare_evidence(
                repository=repository,
                app=app,
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                expected_bundle_id=BUNDLE_ID,
                expected_team_id=TEAM_ID,
                expected_source_commit=commit,
                output=prepared,
                command_runner=runner,
            )

            payload = module.finalize_evidence(
                repository=repository,
                app=app,
                package=package,
                prepared=prepared,
                expected_team_id=TEAM_ID,
                output=evidence,
                command_runner=runner,
            )

            self.assertEqual(payload["recordType"], "masReleaseEvidence")
            self.assertEqual(payload["source"]["commit"], commit)
            self.assertEqual(
                payload["package"]["sha256"], hashlib.sha256(package_bytes).hexdigest()
            )
            self.assertEqual(payload["package"]["byteCount"], len(package_bytes))
            self.assertEqual(payload["package"]["signatureTeamID"], TEAM_ID)
            receipt = app.with_name(f"{app.name}-signing.json")
            self.assertEqual(
                payload["appSigningReceiptSHA256"],
                hashlib.sha256(receipt.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                payload["appStoreConnect"], {"buildID": None, "status": "pending"}
            )
            receipt.unlink()
            self.assertEqual(
                module.verify_evidence(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    command_runner=runner,
                ),
                payload,
            )

    def test_finalize_rejects_a_changed_app_signing_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            prepared = self.prepare_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            receipt = app.with_name(f"{app.name}-signing.json")
            changed = json.loads(receipt.read_text(encoding="utf-8"))
            changed["signedAt"] = "2026-08-09T16:00:01Z"
            receipt.write_text(
                json.dumps(changed, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            package = root / "EasySplat.pkg"
            package.write_bytes(b"fixture signed installer package\n")

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "signing receipt"):
                module.finalize_evidence(
                    repository=repository,
                    app=app,
                    package=package,
                    prepared=prepared,
                    expected_team_id=TEAM_ID,
                    output=root / "evidence.json",
                    command_runner=runner,
                )

    def test_finalize_cryptographically_rechecks_the_expanded_store_app(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            prepared = self.prepare_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            package = root / "EasySplat.pkg"
            package.write_bytes(b"fixture signed installer package\n")
            runner.store_requirement_failure_target = "easysplat-mas-package-"

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "signature verification"):
                module.finalize_evidence(
                    repository=repository,
                    app=app,
                    package=package,
                    prepared=prepared,
                    expected_team_id=TEAM_ID,
                    output=root / "evidence.json",
                    command_runner=runner,
                )

    def test_evidence_schema_requires_source_to_match_the_signed_app_seal(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            package, evidence = self.finalize_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            payload = json.loads(evidence.read_text(encoding="utf-8"))
            payload["app"]["sealedSource"]["sourceCommit"] = "f" * 40
            evidence.unlink()
            module._write_new_json(evidence, payload)

            with self.assertRaisesRegex(module.ReleaseEvidenceError, "sealed app source"):
                module.verify_evidence(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    command_runner=runner,
                )

    def test_checksum_publication_is_exclusive_nofollow_and_descriptor_validated(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            package = root / "EasySplat.pkg"
            package.write_bytes(b"signed package bytes\n")
            checksum = root / "EasySplat.pkg.sha256"
            expected = hashlib.sha256(package.read_bytes()).hexdigest()

            self.assertEqual(module.publish_checksum(package, checksum), expected)
            self.assertEqual(checksum.read_text(encoding="ascii"), expected + "\n")
            metadata = checksum.stat()
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
            self.assertEqual(metadata.st_nlink, 1)

            checksum.unlink()
            foreign = root / "foreign.txt"
            foreign.write_text("preserve\n", encoding="utf-8")
            checksum.symlink_to(foreign.name)
            with self.assertRaises(module.ReleaseEvidenceError):
                module.publish_checksum(package, checksum)
            self.assertEqual(foreign.read_text(encoding="utf-8"), "preserve\n")

            checksum.unlink()
            os.mkfifo(checksum)
            with self.assertRaises(module.ReleaseEvidenceError):
                module.publish_checksum(package, checksum)
            self.assertTrue(stat.S_ISFIFO(os.lstat(checksum).st_mode))

            checksum.unlink()
            os.link(foreign, checksum)
            with self.assertRaises(module.ReleaseEvidenceError):
                module.publish_checksum(package, checksum)
            self.assertEqual(foreign.read_text(encoding="utf-8"), "preserve\n")

    def test_upload_snapshot_is_private_bound_and_detects_path_replacement(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            package = root / "EasySplat.pkg"
            package.write_bytes(b"signed package bytes\n")
            private_root = root / "private"
            private_root.mkdir(mode=0o700)
            snapshot = private_root / "EasySplat.pkg"

            token = module.snapshot_package(package, snapshot)
            descriptor = os.open(snapshot, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                module.verify_package_snapshot(snapshot, descriptor, token)
                self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o600)
                self.assertEqual(snapshot.stat().st_nlink, 1)
                displaced = private_root / "displaced.pkg"
                snapshot.rename(displaced)
                snapshot.write_bytes(b"foreign package\n")
                snapshot.chmod(0o600)
                with self.assertRaisesRegex(module.ReleaseEvidenceError, "identity"):
                    module.verify_package_snapshot(snapshot, descriptor, token)
                self.assertEqual(displaced.read_bytes(), package.read_bytes())
            finally:
                os.close(descriptor)

    def test_upload_snapshot_rejects_in_place_source_mutation(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            package = root / "EasySplat.pkg"
            package.write_bytes(b"a" * (2 * 1024 * 1024))
            private_root = root / "private"
            private_root.mkdir(mode=0o700)
            snapshot = private_root / "EasySplat.pkg"
            real_read = module.os.read
            mutated = False

            def mutating_read(descriptor, count):
                nonlocal mutated
                chunk = real_read(descriptor, count)
                if chunk and not mutated:
                    mutated = True
                    with package.open("r+b") as target:
                        target.seek(-1, os.SEEK_END)
                        target.write(b"b")
                        target.flush()
                        os.fsync(target.fileno())
                return chunk

            with mock.patch.object(module.os, "read", side_effect=mutating_read):
                with self.assertRaisesRegex(module.ReleaseEvidenceError, "changed"):
                    module.snapshot_package(package, snapshot)
            self.assertTrue(mutated)
            self.assertFalse(snapshot.exists())

    def test_snapshot_cli_holds_the_descriptor_across_verification_and_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            package = root / "EasySplat.pkg"
            package.write_bytes(b"signed package bytes\n")
            private_root = root / "private"
            private_root.mkdir(mode=0o700)
            snapshot = private_root / "EasySplat.pkg"
            script = """
set -euo pipefail
token="$(/usr/bin/python3 -I "$1" snapshot-package --package "$2" --output "$3")"
exec 9<"$3"
/usr/bin/python3 -I "$1" verify-snapshot --snapshot "$3" --descriptor 9 --token "$token" >/dev/null
/usr/bin/python3 -I "$1" cleanup-snapshot --root "$4" --snapshot "$3" --descriptor 9 --token "$token" >/dev/null
exec 9<&-
test ! -e "$4"
"""
            result = subprocess.run(
                [
                    "/bin/bash",
                    "--noprofile",
                    "--norc",
                    "-c",
                    script,
                    "fixture",
                    str(MODULE_PATH),
                    str(package),
                    str(snapshot),
                    str(private_root),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_upload_snapshot_cleanup_removes_bound_response_files(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            private_root = root / "private"
            private_root.mkdir(mode=0o700)
            upload_response = private_root / "upload-response.json"
            processing_response = private_root / "processing-response.json"

            upload_response.write_text('{"upload":true}\n', encoding="utf-8")
            upload_response.chmod(0o600)
            processing_response.write_text('{"processed":true}\n', encoding="utf-8")
            processing_response.chmod(0o600)
            module.cleanup_submission_responses(
                private_root, [upload_response, processing_response]
            )
            self.assertFalse(private_root.exists())

    def test_upload_snapshot_cleanup_preserves_unknown_entries(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            private_root = root / "private"
            private_root.mkdir(mode=0o700)
            response = private_root / "upload-response.json"
            unknown = private_root / "foreign.txt"

            response.write_text('{"upload":true}\n', encoding="utf-8")
            response.chmod(0o600)
            unknown.write_text("preserve\n", encoding="utf-8")
            unknown.chmod(0o600)
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "unknown"):
                module.cleanup_submission_responses(private_root, [response])
            self.assertEqual(unknown.read_text(encoding="utf-8"), "preserve\n")
            self.assertTrue(response.exists())

    def test_owned_tree_cleanup_quarantines_a_final_window_replacement(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            root = parent / "easysplat-owned"
            root.mkdir(mode=0o700)
            original = os.lstat(root)
            replacement = parent / "replacement"
            replacement.mkdir(mode=0o700)
            sentinel = replacement / "preserve.txt"
            sentinel.write_text("preserve\n", encoding="utf-8")
            displaced = parent / "displaced"
            real_rename = os.rename
            swapped = False

            def swapping_rename(source, destination, *args, **kwargs):
                nonlocal swapped
                if not swapped and source == root.name:
                    swapped = True
                    real_rename(root, displaced)
                    real_rename(replacement, root)
                return real_rename(source, destination, *args, **kwargs)

            with mock.patch.object(module.os, "rename", side_effect=swapping_rename):
                with self.assertRaisesRegex(module.ReleaseEvidenceError, "retained|identity"):
                    module._remove_owned_tree(root, original, label="Test tree")

            self.assertTrue(swapped)
            retained = list(parent.rglob("preserve.txt"))
            self.assertEqual(len(retained), 1)
            self.assertEqual(retained[0].read_text(encoding="utf-8"), "preserve\n")
            self.assertTrue(displaced.is_dir())

    def test_explicit_reviewed_commit_requires_the_same_clean_tree(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, reviewed_commit = self.make_repository(root)
            app = self.make_app(root, repository)
            subprocess.run(
                [
                    "/usr/bin/git",
                    "-C",
                    str(repository),
                    "commit",
                    "--allow-empty",
                    "-qm",
                    "same tree",
                ],
                check=True,
            )
            accepted = module.prepare_evidence(
                repository=repository,
                app=app,
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                expected_bundle_id=BUNDLE_ID,
                expected_team_id=TEAM_ID,
                expected_source_commit=reviewed_commit,
                output=root / "accepted.json",
                command_runner=FixtureCommandRunner(),
            )
            self.assertEqual(accepted["source"]["commit"], reviewed_commit)

            (repository / "tracked.txt").write_text("new tree\n", encoding="utf-8")
            subprocess.run(
                ["/usr/bin/git", "-C", str(repository), "commit", "-qam", "different tree"],
                check=True,
            )
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "does not match"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=reviewed_commit,
                    output=root / "rejected.json",
                    command_runner=FixtureCommandRunner(),
                )

    def test_source_verification_ignores_git_environment_overrides(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            reviewed_root = root / "reviewed"
            foreign_root = root / "foreign"
            reviewed_root.mkdir()
            foreign_root.mkdir()
            repository, commit = self.make_repository(reviewed_root)
            foreign, _ = self.make_repository(foreign_root)
            app = self.make_app(root, repository)
            with mock.patch.dict(
                os.environ,
                {
                    "GIT_DIR": str(foreign / ".git"),
                    "GIT_WORK_TREE": str(foreign),
                    "GIT_INDEX_FILE": str(foreign / ".git/index"),
                },
            ):
                payload = module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "prepared.json",
                    command_runner=FixtureCommandRunner(),
                )
            self.assertEqual(payload["source"]["commit"], commit)

    def test_prepare_rejects_wrong_version_and_broad_entitlements(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "CFBundleVersion"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build="0.2.8",
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "wrong-version.json",
                    command_runner=FixtureCommandRunner(),
                )
            runner = FixtureCommandRunner()
            runner.app_entitlement_variant = 1
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "broader"):
                module.prepare_evidence(
                    repository=repository,
                    app=app,
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    expected_bundle_id=BUNDLE_ID,
                    expected_team_id=TEAM_ID,
                    expected_source_commit=None,
                    output=root / "broad-entitlements.json",
                    command_runner=runner,
                )

    def test_finalize_rejects_app_toolchain_and_entitlement_changes(self) -> None:
        module = self.load_module()
        mutations = ("app", "toolchain", "entitlements")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                runner = FixtureCommandRunner()
                prepared = self.prepare_fixture(
                    module,
                    root=root,
                    repository=repository,
                    app=app,
                    runner=runner,
                )
                package = root / "EasySplat.pkg"
                package.write_bytes(b"fixture signed installer package\n")
                if mutation == "app":
                    (app / "Contents/MacOS/EasySplatApp").write_bytes(b"changed-main")
                elif mutation == "toolchain":
                    (app / "Contents/Resources/Toolchain/default.metallib").write_bytes(
                        b"changed-metallib"
                    )
                else:
                    runner.app_entitlement_variant = 1
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.finalize_evidence(
                        repository=repository,
                        app=app,
                        package=package,
                        prepared=prepared,
                        expected_team_id=TEAM_ID,
                        output=root / "evidence.json",
                        command_runner=runner,
                    )

    def test_finalize_parses_the_exact_installer_authority_team(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            prepared = self.prepare_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            package = root / "EasySplat.pkg"
            package.write_bytes(b"fixture signed installer package\n")
            runner.package_authority_name = f"EasySplat {TEAM_ID}"
            runner.package_team_id = "Z9Y8X7W6V5"
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "wrong distribution"):
                module.finalize_evidence(
                    repository=repository,
                    app=app,
                    package=package,
                    prepared=prepared,
                    expected_team_id=TEAM_ID,
                    output=root / "evidence.json",
                    command_runner=runner,
                )

    def test_finalize_requires_the_exact_application_payload_structure(self) -> None:
        module = self.load_module()
        for mutation in (
            "wrong-location",
            "extra-payload",
            "scripts",
            "extra-component",
            "extra-root",
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                runner = FixtureCommandRunner()
                prepared = self.prepare_fixture(
                    module,
                    root=root,
                    repository=repository,
                    app=app,
                    runner=runner,
                )
                package = root / "EasySplat.pkg"
                package.write_bytes(b"fixture signed installer package\n")
                runner.package_layout_mutation = mutation
                with self.assertRaisesRegex(
                    module.ReleaseEvidenceError,
                    "package|payload|install|structure|script",
                ):
                    module.finalize_evidence(
                        repository=repository,
                        app=app,
                        package=package,
                        prepared=prepared,
                        expected_team_id=TEAM_ID,
                        output=root / "evidence.json",
                        command_runner=runner,
                    )

    def test_verify_rejects_package_digest_mismatch_and_unknown_or_future_keys(self) -> None:
        module = self.load_module()
        for mutation in (
            "package",
            "app-evidence",
            "unknown-top",
            "unknown-nested",
            "missing-receipt-binding",
            "future",
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                runner = FixtureCommandRunner()
                package, evidence = self.finalize_fixture(
                    module,
                    root=root,
                    repository=repository,
                    app=app,
                    runner=runner,
                )
                if mutation == "package":
                    package.write_bytes(b"foreign package bytes\n")
                else:
                    payload = json.loads(evidence.read_text(encoding="utf-8"))
                    if mutation == "app-evidence":
                        payload["app"]["closureSHA256"] = "f" * 64
                    elif mutation == "unknown-top":
                        payload["unexpected"] = True
                    elif mutation == "unknown-nested":
                        payload["package"]["unexpected"] = True
                    elif mutation == "missing-receipt-binding":
                        payload.pop("appSigningReceiptSHA256")
                    else:
                        payload["schemaVersion"] = 2
                    evidence.write_text(
                        json.dumps(
                            payload,
                            ensure_ascii=False,
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.verify_evidence(
                        repository=repository,
                        package=package,
                        evidence=evidence,
                        command_runner=runner,
                    )

    def test_prepare_rejects_symlink_hardlink_and_fifo_artifacts(self) -> None:
        module = self.load_module()
        for unsafe_type in ("symlink", "hardlink", "fifo"):
            with self.subTest(unsafe_type=unsafe_type), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                target = app / "Contents/Resources/Toolchain/unsafe"
                if unsafe_type == "symlink":
                    target.symlink_to("default.metallib")
                elif unsafe_type == "hardlink":
                    os.link(app / "Contents/Resources/Toolchain/default.metallib", target)
                else:
                    os.mkfifo(target)
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.prepare_evidence(
                        repository=repository,
                        app=app,
                        expected_version=APP_VERSION,
                        expected_build=APP_BUILD,
                        expected_bundle_id=BUNDLE_ID,
                        expected_team_id=TEAM_ID,
                        expected_source_commit=None,
                        output=root / "prepared.json",
                        command_runner=FixtureCommandRunner(),
                    )

    def test_verify_rejects_symlink_hardlink_and_fifo_evidence_or_packages(self) -> None:
        module = self.load_module()
        for target_kind in ("evidence", "package"):
            for unsafe_type in ("symlink", "hardlink", "fifo"):
                with (
                    self.subTest(target_kind=target_kind, unsafe_type=unsafe_type),
                    tempfile.TemporaryDirectory() as scratch,
                ):
                    root = Path(scratch).resolve()
                    repository, _ = self.make_repository(root)
                    app = self.make_app(root, repository)
                    runner = FixtureCommandRunner()
                    package, evidence = self.finalize_fixture(
                        module,
                        root=root,
                        repository=repository,
                        app=app,
                        runner=runner,
                    )
                    target = evidence if target_kind == "evidence" else package
                    preserved = root / f"preserved-{target.name}"
                    target.rename(preserved)
                    if unsafe_type == "symlink":
                        target.symlink_to(preserved.name)
                    elif unsafe_type == "hardlink":
                        os.link(preserved, target)
                    else:
                        os.mkfifo(target)
                    with self.assertRaises(module.ReleaseEvidenceError):
                        module.verify_evidence(
                            repository=repository,
                            package=package,
                            evidence=evidence,
                            command_runner=runner,
                        )

    def test_submission_receipts_bind_upload_then_terminal_processing(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            package, evidence = self.finalize_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            upload_response = root / "upload-response.json"
            upload_response.write_text(
                json.dumps(
                    {
                        "delivery-id": "be9c5d83-4150-40cb-91a1-739cf69a6f35",
                        "success-message": "Upload accepted.",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            upload_receipt = root / "EasySplat.pkg.upload.json"
            upload = module.record_upload_submission(
                repository=repository,
                package=package,
                evidence=evidence,
                apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                altool_version="26.40.1 (174001)",
                response=upload_response,
                output=upload_receipt,
                command_runner=runner,
            )

            self.assertEqual(upload["recordType"], "masUploadSubmission")
            self.assertEqual(upload["state"], "uploadedAwaitingProcessing")
            self.assertEqual(upload["app"]["appleID"], "1234567890")
            self.assertEqual(upload["app"]["version"], APP_VERSION)
            self.assertEqual(upload["app"]["build"], APP_BUILD)
            self.assertEqual(upload["package"]["sha256"], hashlib.sha256(package.read_bytes()).hexdigest())
            self.assertEqual(
                module.verify_upload_submission(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    receipt=upload_receipt,
                    expected_apple_id="1234567890",
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    command_runner=runner,
                ),
                upload,
            )

            processing_response = root / "processing-response.json"
            processing_response.write_text(
                json.dumps(
                    {
                        "internal-build-state": "READY_TO_TEST",
                        "is-on-app-store-connect": True,
                        "processing-errors": [],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            processing_receipt = root / "EasySplat.pkg.processing.json"
            processing = module.record_processing_submission(
                repository=repository,
                package=package,
                evidence=evidence,
                upload_receipt=upload_receipt,
                expected_apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                altool_version="26.40.1 (174001)",
                response=processing_response,
                output=processing_receipt,
                command_runner=runner,
            )

            self.assertEqual(processing["recordType"], "masProcessingSubmission")
            self.assertEqual(processing["state"], "processed")
            self.assertEqual(
                module.verify_processing_submission(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    upload_receipt=upload_receipt,
                    processing_receipt=processing_receipt,
                    expected_apple_id="1234567890",
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    command_runner=runner,
                ),
                processing,
            )

    def test_upload_attempt_recovers_and_cleans_only_after_a_durable_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            package, evidence = self.finalize_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            attempt = package.with_name(f"{package.name}.upload-attempt.json")
            response = module.start_upload_attempt(
                repository=repository,
                package=package,
                evidence=evidence,
                apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                altool_version="26.40.1 (174001)",
                output=attempt,
                command_runner=runner,
            )
            response_payload = {
                "delivery-id": "be9c5d83-4150-40cb-91a1-739cf69a6f35",
                "success-message": "accepted",
            }
            response_bytes = (json.dumps(response_payload) + "\n").encode("utf-8")
            module.capture_submission_response(response, response_bytes)

            attempt_payload, resolved_response = module.verify_upload_attempt(
                repository=repository,
                package=package,
                evidence=evidence,
                attempt=attempt,
                expected_apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                command_runner=runner,
            )
            self.assertEqual(resolved_response, response)
            self.assertEqual(attempt_payload["altoolVersion"], "26.40.1 (174001)")
            upload_receipt = root / "EasySplat.pkg.upload.json"
            module.record_upload_submission(
                repository=repository,
                package=package,
                evidence=evidence,
                apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                altool_version=str(attempt_payload["altoolVersion"]),
                response=response,
                output=upload_receipt,
                command_runner=runner,
            )
            module.cleanup_upload_attempt(
                repository=repository,
                package=package,
                evidence=evidence,
                attempt=attempt,
                response=response,
                upload_receipt=upload_receipt,
                expected_apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                command_runner=runner,
            )

            self.assertFalse(attempt.exists())
            self.assertFalse(response.exists())
            self.assertTrue(upload_receipt.is_file())

    def test_upload_attempt_cleanup_preserves_a_foreign_response(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            package, evidence = self.finalize_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            attempt = package.with_name(f"{package.name}.upload-attempt.json")
            response = module.start_upload_attempt(
                repository=repository,
                package=package,
                evidence=evidence,
                apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                altool_version="26.40.1 (174001)",
                output=attempt,
                command_runner=runner,
            )
            accepted = (
                b'{"delivery-id":"be9c5d83-4150-40cb-91a1-739cf69a6f35",'
                b'"success-message":"accepted"}\n'
            )
            module.capture_submission_response(response, accepted)
            upload_receipt = root / "EasySplat.pkg.upload.json"
            module.record_upload_submission(
                repository=repository,
                package=package,
                evidence=evidence,
                apple_id="1234567890",
                expected_version=APP_VERSION,
                expected_build=APP_BUILD,
                altool_version="26.40.1 (174001)",
                response=response,
                output=upload_receipt,
                command_runner=runner,
            )
            replacement = root / "foreign-response.json"
            replacement.write_bytes(b'{"foreign":true}\n')
            os.replace(replacement, response)

            with self.assertRaises(module.ReleaseEvidenceError):
                module.cleanup_upload_attempt(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    attempt=attempt,
                    response=response,
                    upload_receipt=upload_receipt,
                    expected_apple_id="1234567890",
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    command_runner=runner,
                )

            self.assertEqual(response.read_bytes(), b'{"foreign":true}\n')
            self.assertTrue(attempt.is_file())

    def test_bound_package_command_detects_a_transient_swap_and_restore(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = root / "source.pkg"
            source.write_bytes(b"authenticated package\n")
            snapshot_root = root / "snapshot"
            snapshot_root.mkdir(mode=0o700)
            snapshot = snapshot_root / "EasySplat.pkg"
            token = module.snapshot_package(source, snapshot)
            descriptor = os.open(snapshot, os.O_RDONLY)
            try:
                self.assertEqual(
                    module.run_bound_package_command(
                        snapshot=snapshot,
                        descriptor=descriptor,
                        token=token,
                        arguments=["/usr/bin/true"],
                    ),
                    0,
                )
                script = (
                    "import os,sys;"
                    "path=sys.argv[1];moved=path+'.held';"
                    "os.rename(path,moved);"
                    "open(path,'wb').write(b'foreign package\\n');"
                    "open(path,'rb').read();"
                    "os.unlink(path);"
                    "os.rename(moved,path)"
                )
                with self.assertRaisesRegex(
                    module.ReleaseEvidenceError,
                    "identity|changed while App Store Connect opened",
                ):
                    module.run_bound_package_command(
                        snapshot=snapshot,
                        descriptor=descriptor,
                        token=token,
                        arguments=[
                            "/usr/bin/python3",
                            "-c",
                            script,
                            str(snapshot),
                        ],
                    )
                self.assertEqual(snapshot.read_bytes(), b"authenticated package\n")
            finally:
                os.close(descriptor)

    def test_submission_receipts_require_a_delivery_id_and_successful_terminal_state(self) -> None:
        module = self.load_module()
        invalid_processing_responses = {
            "still processing": {
                "internal-build-state": "PROCESSING",
                "is-on-app-store-connect": True,
                "processing-errors": [],
            },
            "failed": {
                "internal-build-state": "FAILED",
                "is-on-app-store-connect": True,
                "processing-errors": [{"message": "invalid binary"}],
            },
            "not visible": {
                "internal-build-state": "READY_TO_TEST",
                "is-on-app-store-connect": False,
                "processing-errors": [],
            },
            "reported errors": {
                "internal-build-state": "READY_TO_TEST",
                "is-on-app-store-connect": True,
                "processing-errors": [{"message": "rejected"}],
            },
            "unknown schema": {"status": "Complete"},
        }
        for label, processing_payload in invalid_processing_responses.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                runner = FixtureCommandRunner()
                package, evidence = self.finalize_fixture(
                    module,
                    root=root,
                    repository=repository,
                    app=app,
                    runner=runner,
                )
                upload_response = root / "upload-response.json"
                upload_response.write_text(
                    '{"delivery-id":"be9c5d83-4150-40cb-91a1-739cf69a6f35","success-message":"accepted"}\n',
                    encoding="utf-8",
                )
                upload_receipt = root / "EasySplat.pkg.upload.json"
                module.record_upload_submission(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    apple_id="1234567890",
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    altool_version="26.40.1 (174001)",
                    response=upload_response,
                    output=upload_receipt,
                    command_runner=runner,
                )
                processing_response = root / "processing-response.json"
                processing_response.write_text(
                    json.dumps(processing_payload) + "\n", encoding="utf-8"
                )
                processing_receipt = root / "EasySplat.pkg.processing.json"

                with self.assertRaisesRegex(
                    module.ReleaseEvidenceError,
                    "processing|terminal|ready|delivery|response",
                ):
                    module.record_processing_submission(
                        repository=repository,
                        package=package,
                        evidence=evidence,
                        upload_receipt=upload_receipt,
                        expected_apple_id="1234567890",
                        expected_version=APP_VERSION,
                        expected_build=APP_BUILD,
                        altool_version="26.40.1 (174001)",
                        response=processing_response,
                        output=processing_receipt,
                        command_runner=runner,
                    )
                self.assertFalse(processing_receipt.exists())

        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            repository, _ = self.make_repository(root)
            app = self.make_app(root, repository)
            runner = FixtureCommandRunner()
            package, evidence = self.finalize_fixture(
                module,
                root=root,
                repository=repository,
                app=app,
                runner=runner,
            )
            response = root / "upload-response.json"
            response.write_text('{"success-message":"accepted"}\n', encoding="utf-8")
            with self.assertRaisesRegex(module.ReleaseEvidenceError, "delivery"):
                module.record_upload_submission(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    apple_id="1234567890",
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    altool_version="26.40.1 (174001)",
                    response=response,
                    output=root / "EasySplat.pkg.upload.json",
                    command_runner=runner,
                )

    def test_submission_receipts_fail_closed_on_mismatch_tamper_and_unknown_schema(self) -> None:
        module = self.load_module()
        for mutation in ("wrong-build", "package", "receipt", "response"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch).resolve()
                repository, _ = self.make_repository(root)
                app = self.make_app(root, repository)
                runner = FixtureCommandRunner()
                package, evidence = self.finalize_fixture(
                    module,
                    root=root,
                    repository=repository,
                    app=app,
                    runner=runner,
                )
                response = root / "upload-response.json"
                response.write_text(
                    '{"delivery-id":"be9c5d83-4150-40cb-91a1-739cf69a6f35","success-message":"accepted"}\n',
                    encoding="utf-8",
                )
                receipt = root / "EasySplat.pkg.upload.json"
                if mutation == "wrong-build":
                    with self.assertRaises(module.ReleaseEvidenceError):
                        module.record_upload_submission(
                            repository=repository,
                            package=package,
                            evidence=evidence,
                            apple_id="1234567890",
                            expected_version=APP_VERSION,
                            expected_build="99",
                            altool_version="26.40.1 (174001)",
                            response=response,
                            output=receipt,
                            command_runner=runner,
                        )
                    continue
                module.record_upload_submission(
                    repository=repository,
                    package=package,
                    evidence=evidence,
                    apple_id="1234567890",
                    expected_version=APP_VERSION,
                    expected_build=APP_BUILD,
                    altool_version="26.40.1 (174001)",
                    response=response,
                    output=receipt,
                    command_runner=runner,
                )
                if mutation == "package":
                    package.write_bytes(b"foreign package\n")
                elif mutation == "receipt":
                    payload = json.loads(receipt.read_text(encoding="utf-8"))
                    payload["unexpected"] = True
                    receipt.write_text(
                        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
                        encoding="utf-8",
                    )
                else:
                    payload = json.loads(receipt.read_text(encoding="utf-8"))
                    payload["altool"]["response"]["success-message"] = "changed"
                    receipt.write_text(
                        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
                        encoding="utf-8",
                    )
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.verify_upload_submission(
                        repository=repository,
                        package=package,
                        evidence=evidence,
                        receipt=receipt,
                        expected_apple_id="1234567890",
                        expected_version=APP_VERSION,
                        expected_build=APP_BUILD,
                        command_runner=runner,
                    )

    def test_submission_response_rejects_duplicate_nonfinite_and_oversized_json(self) -> None:
        module = self.load_module()
        for name, contents in (
            ("duplicate", b'{"state":"ready","state":"failed"}\n'),
            ("nonfinite", b'{"value":NaN}\n'),
            ("oversized", b'{"value":"' + b"x" * (1024 * 1024) + b'"}\n'),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as scratch:
                response = Path(scratch).resolve() / "response.json"
                response.write_bytes(contents)
                with self.assertRaises(module.ReleaseEvidenceError):
                    module.load_altool_response(response)

    def test_cli_exposes_prepare_finalize_and_verify_without_command_overrides(self) -> None:
        help_result = subprocess.run(
            ["/usr/bin/python3", "-I", str(MODULE_PATH), "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("prepare", help_result.stdout)
        self.assertIn("finalize", help_result.stdout)
        self.assertIn("verify", help_result.stdout)
        self.assertIn("record-upload", help_result.stdout)
        self.assertIn("verify-upload", help_result.stdout)
        self.assertIn("record-processing", help_result.stdout)
        self.assertIn("verify-processing", help_result.stdout)
        unknown = subprocess.run(
            ["/usr/bin/python3", "-I", str(MODULE_PATH), "unknown"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("invalid choice", unknown.stderr)

    def test_package_entrypoint_defaults_authenticated_build_and_keeps_gate_order(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            result = subprocess.run(
                [
                    str(BUILD_SCRIPT),
                    "--app",
                    str(root / "EasySplat.app"),
                    "--app-version",
                    APP_VERSION,
                    "--identity-fingerprint",
                    "0" * 40,
                    "--team-id",
                    TEAM_ID,
                    "--output-dir",
                    str(root),
                ],
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App bundle does not exist", result.stderr)
        self.assertNotIn("--app-build", result.stderr)

        source = BUILD_SCRIPT.read_text(encoding="utf-8")
        prepare = source.index("mas_release_evidence.py\" prepare")
        productbuild = source.index('"$PRODUCTBUILD"')
        finalize = source.index("mas_release_evidence.py\" finalize")
        self.assertLess(prepare, productbuild)
        self.assertLess(productbuild, finalize)
        self.assertIn("publish-checksum", source)
        self.assertNotIn('>"$PACKAGE_SHA256"', source)
        self.assertIn("Mac Installer Distribution", source)
        self.assertNotIn("EASYSPLAT_MAS_EVIDENCE_BIN", source)
        self.assertIn("--app-signing-receipt", source)
        self.assertGreaterEqual(source.count('"$APP_SIGNING_RECEIPT"'), 3)
        self.assertIn(
            'STAGED_PACKAGE="$PREPARED_EVIDENCE_DIRECTORY/EasySplat.pkg"',
            source,
        )
        self.assertIn('"$STAGED_PACKAGE"', source)
        self.assertNotIn('  "$PACKAGE"\n\nif ! "$PKGUTIL"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
