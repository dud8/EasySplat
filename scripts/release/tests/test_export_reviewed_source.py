#!/usr/bin/env python3
"""Tests for exporting the exact reviewed source tree used by release builds."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/release/export_reviewed_source.py"


def load_module():
    spec = importlib.util.spec_from_file_location("export_reviewed_source", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ExportReviewedSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir(mode=0o700)
        self.git("init", "-q")
        self.git("config", "user.name", "EasySplat Tests")
        self.git("config", "user.email", "tests@example.invalid")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(self.repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def commit_fixture(self) -> str:
        (self.repository / ".gitignore").write_text(
            "Sources/Unreviewed.swift\n", encoding="utf-8"
        )
        source = self.repository / "Sources"
        scripts = self.repository / "scripts"
        source.mkdir()
        scripts.mkdir()
        (source / "Reviewed.swift").write_text("let reviewed = true\n", encoding="utf-8")
        executable = scripts / "build.sh"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        self.git("add", ".")
        self.git("commit", "-q", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_export_uses_only_reviewed_git_bytes_and_preserves_modes(self) -> None:
        module = load_module()
        commit = self.commit_fixture()
        ignored = self.repository / "Sources/Unreviewed.swift"
        ignored.write_text("fatalError(\"must never compile\")\n", encoding="utf-8")
        self.assertEqual(self.git("status", "--short"), "")

        destination = self.root / "exported"
        result = module.export_reviewed_source(
            repository=self.repository,
            source_commit=commit,
            output=destination,
        )

        self.assertEqual((destination / "Sources/Reviewed.swift").read_text(), "let reviewed = true\n")
        self.assertFalse(destination.joinpath("Sources/Unreviewed.swift").exists())
        self.assertTrue(os.lstat(destination / "scripts/build.sh").st_mode & stat.S_IXUSR)
        self.assertEqual(result["sourceCommit"], commit)
        self.assertEqual(result["sourceTreeObjectID"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual(result["fileCount"], 3)

    def test_export_rejects_a_commit_that_is_not_the_checked_out_tree(self) -> None:
        module = load_module()
        first = self.commit_fixture()
        (self.repository / "Sources/Reviewed.swift").write_text(
            "let reviewed = false\n", encoding="utf-8"
        )
        self.git("add", ".")
        self.git("commit", "-q", "-m", "different tree")

        with self.assertRaisesRegex(module.SourceExportError, "checked-out tree"):
            module.export_reviewed_source(
                repository=self.repository,
                source_commit=first,
                output=self.root / "exported",
            )

    def test_export_rejects_symlink_entries_and_leaves_no_output(self) -> None:
        module = load_module()
        self.commit_fixture()
        os.symlink("Reviewed.swift", self.repository / "Sources/Linked.swift")
        self.git("add", "Sources/Linked.swift")
        self.git("commit", "-q", "-m", "linked source")
        commit = self.git("rev-parse", "HEAD")
        destination = self.root / "exported"

        with self.assertRaisesRegex(module.SourceExportError, "regular files"):
            module.export_reviewed_source(
                repository=self.repository,
                source_commit=commit,
                output=destination,
            )
        self.assertFalse(destination.exists())

    def test_export_refuses_existing_or_noncanonical_outputs(self) -> None:
        module = load_module()
        commit = self.commit_fixture()
        existing = self.root / "existing"
        existing.mkdir()
        with self.assertRaisesRegex(module.SourceExportError, "already exists"):
            module.export_reviewed_source(
                repository=self.repository,
                source_commit=commit,
                output=existing,
            )
        with self.assertRaisesRegex(module.SourceExportError, "normalized"):
            module.export_reviewed_source(
                repository=self.repository,
                source_commit=commit,
                output=Path(f"{self.root}/nested/../exported"),
            )

    def test_cli_emits_canonical_receipt(self) -> None:
        commit = self.commit_fixture()
        destination = self.root / "exported"
        result = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                str(SCRIPT),
                "--repository",
                str(self.repository),
                "--source-commit",
                commit,
                "--output",
                str(destination),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["sourceCommit"], commit)
        self.assertEqual(result.stdout, json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")

    def test_locked_export_is_immutable_and_reverifies_the_reviewed_tree(self) -> None:
        module = load_module()
        commit = self.commit_fixture()
        destination = self.root / "exported"
        module.export_reviewed_source(
            repository=self.repository,
            source_commit=commit,
            output=destination,
        )
        try:
            module.lock_reviewed_source(
                repository=self.repository,
                source_commit=commit,
                output=destination,
            )
            reviewed = destination / "Sources/Reviewed.swift"
            self.assertTrue(os.lstat(reviewed).st_flags & stat.UF_IMMUTABLE)
            self.assertTrue(os.lstat(destination).st_flags & stat.UF_IMMUTABLE)
            with self.assertRaises(PermissionError):
                reviewed.write_text("let reviewed = false\n", encoding="utf-8")
            receipt = module.verify_reviewed_source(
                repository=self.repository,
                source_commit=commit,
                output=destination,
                require_locked=True,
            )
            self.assertEqual(receipt["sourceCommit"], commit)
            self.assertTrue(receipt["locked"])
        finally:
            module.unlock_reviewed_source(destination)

    def test_reverification_detects_a_changed_export(self) -> None:
        module = load_module()
        commit = self.commit_fixture()
        destination = self.root / "exported"
        module.export_reviewed_source(
            repository=self.repository,
            source_commit=commit,
            output=destination,
        )
        (destination / "Sources/Reviewed.swift").write_text(
            "let reviewed = false\n", encoding="utf-8"
        )

        with self.assertRaisesRegex(module.SourceExportError, "reviewed Git object"):
            module.verify_reviewed_source(
                repository=self.repository,
                source_commit=commit,
                output=destination,
                require_locked=False,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
