#!/usr/bin/env python3

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepared_release.py"


class PreparedReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.temporary.name) / "prepared"
        (self.root / "product/EasySplat.app/Contents/MacOS").mkdir(parents=True)
        (self.root / "product/EasySplat.app/Contents/MacOS/EasySplatApp").write_bytes(
            b"app fixture"
        )
        (self.root / "product/EasySplat.app.dSYM/Contents/Resources/DWARF").mkdir(
            parents=True
        )
        (self.root / "product/EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp").write_bytes(
            b"symbols"
        )
        (self.root / "toolchain/out").mkdir(parents=True)
        (self.root / "toolchain/manifest.json").write_text("{}\n", encoding="utf-8")
        (self.root / "toolchain/public_key_ed25519.txt").write_text(
            "authority\n", encoding="utf-8"
        )
        for name in (
            "toolchain-macos-arm64-2.0.0-core.zip",
            "toolchain-geometry-da3-base-2.0.0.zip",
            "toolchain-geometry-da3-small-2.0.0.zip",
            "toolchain-release-request.json",
            "toolchain-authority-envelope.json",
            "toolchain-authority-receipt.json",
            "toolchain-benchmark-evidence.json",
        ):
            (self.root / "toolchain/out" / name).write_bytes(name.encode("utf-8"))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_script(
        self,
        command: str,
        *,
        expect_success: bool = True,
        extra_arguments: tuple[str, ...] = (),
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                os.fspath(SCRIPT),
                command,
                "--root",
                os.fspath(self.root),
                "--source-repository",
                "dud8/EasySplat",
                "--source-commit",
                "a" * 40,
                "--app-version",
                "0.2.0",
                "--toolchain-version",
                "2.0.0",
                "--run-id",
                "1234",
                "--run-attempt",
                "2",
                "--builder-environment",
                "github-hosted",
                "--xcode-version",
                "26.6",
                "--xcode-build",
                "17F113",
                "--macos-sdk-version",
                "26.5",
                *extra_arguments,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if expect_success and result.returncode != 0:
            self.fail(result.stderr)
        if not expect_success and result.returncode == 0:
            self.fail("invalid prepared release was accepted")
        return result

    def create(self) -> dict[str, object]:
        self.run_script("create")
        return json.loads((self.root / "prepared-release.json").read_text(encoding="utf-8"))

    def test_create_and_verify_exact_closure(self) -> None:
        manifest = self.create()
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["releaseMode"], "production-prepared")
        self.assertEqual(manifest["sourceCommit"], "a" * 40)
        self.assertEqual(manifest["runID"], "1234")
        paths = [row["path"] for row in manifest["entries"]]
        self.assertEqual(paths, sorted(paths))
        self.assertNotIn("prepared-release.json", paths)
        self.assertFalse(any(path.startswith("source/") for path in paths))
        self.assertNotIn("product/ManifestTool", paths)
        self.assertNotIn("product/EasySplatReleaseVerifier", paths)
        self.assertEqual(
            set(manifest["subjects"]), {"app", "dSYM", "toolchain"}
        )
        self.run_script("verify")

    def test_verify_can_bind_the_exact_prepared_manifest_bytes(self) -> None:
        self.create()
        manifest = self.root / "prepared-release.json"
        digest = hashlib.sha256(manifest.read_bytes()).hexdigest()

        self.run_script(
            "verify",
            extra_arguments=("--expected-manifest-sha256", digest),
        )
        rejected = self.run_script(
            "verify",
            expect_success=False,
            extra_arguments=("--expected-manifest-sha256", "0" * 64),
        )

        self.assertIn("digest", rejected.stderr)

    def test_pinned_verify_reuses_manifest_authority_and_binds_release_identity(self) -> None:
        self.create()
        manifest = self.root / "prepared-release.json"
        digest = hashlib.sha256(manifest.read_bytes()).hexdigest()

        def verify(source_commit: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [
                    sys.executable,
                    "-I",
                    os.fspath(SCRIPT),
                    "verify",
                    "--root",
                    os.fspath(self.root),
                    "--authority-from-manifest",
                    "--expected-manifest-sha256",
                    digest,
                    "--source-commit",
                    source_commit,
                    "--app-version",
                    "0.2.0",
                    "--toolchain-version",
                    "2.0.0",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        accepted = verify("a" * 40)
        rejected = verify("b" * 40)

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("sourceCommit", rejected.stderr)

    def test_changed_file_is_rejected(self) -> None:
        self.create()
        (self.root / "product/EasySplat.app/Contents/MacOS/EasySplatApp").write_bytes(
            b"changed app fixture"
        )
        self.assertIn("changed", self.run_script("verify", expect_success=False).stderr)

    def test_added_file_is_rejected(self) -> None:
        self.create()
        (self.root / "product/extra").write_text("unexpected\n", encoding="utf-8")
        self.assertIn("data-only", self.run_script("verify", expect_success=False).stderr)

    def test_metadata_mismatch_is_rejected(self) -> None:
        self.create()
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                os.fspath(SCRIPT),
                "verify",
                "--root",
                os.fspath(self.root),
                "--source-repository",
                "dud8/EasySplat",
                "--source-commit",
                "b" * 40,
                "--app-version",
                "0.2.0",
                "--toolchain-version",
                "2.0.0",
                "--run-id",
                "1234",
                "--run-attempt",
                "2",
                "--builder-environment",
                "github-hosted",
                "--xcode-version",
                "26.6",
                "--xcode-build",
                "17F113",
                "--macos-sdk-version",
                "26.5",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sourceCommit", result.stderr)

    def test_symlink_is_rejected(self) -> None:
        (self.root / "product/link").symlink_to("EasySplat.app")
        self.assertIn("symlink", self.run_script("create", expect_success=False).stderr)

    def test_executable_helper_surface_is_rejected(self) -> None:
        (self.root / "source/scripts/release").mkdir(parents=True)
        (self.root / "source/scripts/release/build_dmg.sh").write_text(
            "#!/bin/bash\nexit 0\n", encoding="utf-8"
        )
        self.assertIn("data-only", self.run_script("create", expect_success=False).stderr)

    def test_hardlink_is_rejected(self) -> None:
        source = self.root / "toolchain/manifest.json"
        os.link(source, self.root / "toolchain/manifest-copy.json")
        self.assertIn("hardlink", self.run_script("create", expect_success=False).stderr)

    def test_manifest_must_be_single_link_regular_file(self) -> None:
        self.create()
        manifest = self.root / "prepared-release.json"
        os.link(manifest, self.root / "manifest-copy.json")
        self.assertIn("single-link", self.run_script("verify", expect_success=False).stderr)

    def test_extracts_safe_data_only_handoff(self) -> None:
        self.create()
        archive = Path(self.temporary.name) / "prepared.tar"
        with tarfile.open(archive, "w:") as output:
            output.add(self.root, arcname="easysplat-prepared-release")
        destination = Path(self.temporary.name) / "extracted"
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                os.fspath(SCRIPT),
                "extract",
                "--archive",
                os.fspath(archive),
                "--destination",
                os.fspath(destination),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        extracted = destination / "easysplat-prepared-release"
        self.assertTrue((extracted / "prepared-release.json").is_file())
        self.assertFalse((extracted / "source").exists())

    def test_extract_rejects_link_and_traversal_entries(self) -> None:
        for name, configure in (
            (
                "link",
                lambda member: setattr(member, "type", tarfile.SYMTYPE),
            ),
            (
                "traversal",
                lambda member: setattr(
                    member, "name", "easysplat-prepared-release/../escape"
                ),
            ),
        ):
            with self.subTest(name=name):
                archive = Path(self.temporary.name) / f"unsafe-{name}.tar"
                member = tarfile.TarInfo("easysplat-prepared-release/unsafe")
                member.mode = 0o600
                member.size = 0
                configure(member)
                with tarfile.open(archive, "w:") as output:
                    output.addfile(member)
                destination = Path(self.temporary.name) / f"unsafe-{name}-out"
                result = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        os.fspath(SCRIPT),
                        "extract",
                        "--archive",
                        os.fspath(archive),
                        "--destination",
                        os.fspath(destination),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
