#!/usr/bin/env python3
"""The App Store submitter must refuse everything before it reaches Apple."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/release/upload_mas_package.sh"
KEY_ID = "N5GX84DZ8U"
ISSUER_ID = "602c0cb4-35d6-4fe0-876a-189570deab1e"


class UploadMasPackageTests(unittest.TestCase):
    def run_script(self, *arguments: str, home: Path | None = None):
        environment = dict(os.environ)
        if home is not None:
            environment["HOME"] = str(home)
        return subprocess.run(
            [str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            env=environment,
        )

    def package(self, directory: Path, name: str = "EasySplat.pkg") -> Path:
        path = directory / name
        path.write_bytes(b"not really a package")
        return path

    def key_home(self, directory: Path, key_id: str = KEY_ID) -> Path:
        keys = directory / ".appstoreconnect/private_keys"
        keys.mkdir(parents=True)
        key = keys / f"AuthKey_{key_id}.p8"
        key.write_text("-----BEGIN PRIVATE KEY-----\n", encoding="ascii")
        key.chmod(0o600)
        return directory

    def test_script_is_executable(self) -> None:
        self.assertTrue(os.access(SCRIPT, os.X_OK))

    def test_usage_requires_every_input(self) -> None:
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage: upload_mas_package.sh", result.stderr)

    def test_unknown_option_is_rejected(self) -> None:
        result = self.run_script("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown arg", result.stderr)

    def test_exactly_one_action_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            result = self.run_script(
                "--package", str(self.package(directory)),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                "--upload",
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one of --validate or --upload", result.stderr)

    def test_key_and_issuer_shapes_are_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            package = str(self.package(Path(scratch).resolve()))
            lowercase_key = self.run_script(
                "--package", package,
                "--key-id", "n5gx84dz8u",
                "--issuer-id", ISSUER_ID,
                "--validate",
            )
            uppercase_issuer = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID.upper(),
                "--validate",
            )
        self.assertIn("10 uppercase letters or digits", lowercase_key.stderr)
        self.assertIn("lowercase UUID", uppercase_issuer.stderr)

    def test_command_override_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            environment = dict(os.environ)
            environment["EASYSPLAT_ALTOOL_BIN"] = "/bin/echo"
            result = subprocess.run(
                [
                    str(SCRIPT),
                    "--package", str(self.package(directory)),
                    "--key-id", KEY_ID,
                    "--issuer-id", ISSUER_ID,
                    "--validate",
                ],
                capture_output=True,
                text=True,
                env=environment,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overrides are not permitted", result.stderr)

    def test_package_must_be_an_ordinary_absolute_installer(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            home = self.key_home(directory / "home")
            archive = directory / "EasySplat.zip"
            archive.write_bytes(b"zip")
            wrong_suffix = self.run_script(
                "--package", str(archive),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
            absent = self.run_script(
                "--package", str(directory / "absent.pkg"),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
            linked = directory / "linked.pkg"
            linked.symlink_to(self.package(directory))
            symlinked = self.run_script(
                "--package", str(linked),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
            relative = self.run_script(
                "--package", "EasySplat.pkg",
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
        self.assertIn("requires an installer package", wrong_suffix.stderr)
        self.assertIn("does not exist", absent.stderr)
        self.assertIn("symlink ancestry", symlinked.stderr)
        self.assertIn("absolute and normalized", relative.stderr)

    def test_missing_or_readable_key_stops_the_submission(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            package = str(self.package(directory))
            empty_home = directory / "empty-home"
            empty_home.mkdir()
            missing = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=empty_home,
            )
            home = self.key_home(directory / "home")
            (home / f".appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8").chmod(0o644)
            readable = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
        self.assertIn(f"AuthKey_{KEY_ID}.p8 is not in", missing.stderr)
        self.assertIn("group- or world-readable", readable.stderr)

    def test_unsigned_package_never_reaches_app_store_connect(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            home = self.key_home(directory / "home")
            result = self.run_script(
                "--package", str(self.package(directory)),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not signed", result.stderr)

    def test_submission_never_names_the_private_key_path(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--apiKey", source)
        self.assertIn("--apiIssuer", source)
        # altool resolves the key by id; the file itself is never passed or read.
        self.assertNotIn("--apiKeyPath", source)
        self.assertNotIn("cat ", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
