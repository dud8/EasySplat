#!/usr/bin/env python3
"""Behavior tests for release ZIP construction."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
ARCHIVER = ROOT / "scripts" / "toolchain" / "create_reproducible_zip.py"
PACKAGE_SCRIPT = ROOT / "scripts" / "toolchain" / "package_toolchain.sh"
FIXED_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_archiver_module():
    spec = importlib.util.spec_from_file_location("create_reproducible_zip", ARCHIVER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def portable_tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()),
    ]
    for path in paths:
        relative = "." if path == root else path.relative_to(root).as_posix()
        if relative == "build_info.json":
            continue
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            kind, content = "directory", ""
        elif stat.S_ISREG(metadata.st_mode):
            kind, content = "file", sha256(path)
        else:
            raise AssertionError(f"unsupported fixture entry: {path}")
        for value in (
            relative,
            kind,
            f"{stat.S_IMODE(metadata.st_mode):o}",
            str(metadata.st_mtime_ns),
            content,
        ):
            digest.update(value.encode())
            digest.update(b"\0")
    return digest.hexdigest()


class ReproducibleZipTests(unittest.TestCase):
    def run_archiver(
        self,
        root: Path,
        output: Path,
        *paths: str,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(ARCHIVER),
            "--root",
            str(root),
            "--output",
            str(output),
        ]
        for path in paths:
            command.extend(("--path", path))
        return subprocess.run(command, capture_output=True, text=True, check=False)

    def populate_tree(self, root: Path, reverse: bool) -> None:
        entries = (
            ("bin/tool", b"#!/bin/sh\nprintf 'tool\\n'\n", 0o700 if reverse else 0o775),
            ("licenses/EasySplat/LICENSE", b"license\n", 0o600 if reverse else 0o664),
            ("provenance/build.json", b'{"version":1}\n', 0o640 if reverse else 0o604),
        )
        for relative, content, mode in reversed(entries) if reverse else entries:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            path.chmod(mode)
            timestamp = 1_700_000_000 if reverse else 1_600_000_000
            os.utime(path, (timestamp, timestamp))

    def test_semantically_identical_trees_produce_identical_zip_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            first_root = base / "first"
            second_root = base / "second"
            self.populate_tree(first_root, reverse=False)
            self.populate_tree(second_root, reverse=True)
            first = base / "first.zip"
            second = base / "second.zip"

            first_result = self.run_archiver(
                first_root,
                first,
                "provenance",
                "bin",
                "licenses",
            )
            second_result = self.run_archiver(
                second_root,
                second,
                "licenses",
                "bin",
                "provenance",
            )

            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertEqual(sha256(first), sha256(second))
            self.assertEqual(first.read_bytes(), second.read_bytes())

            with zipfile.ZipFile(first) as archive:
                members = archive.infolist()
                self.assertEqual(
                    [member.filename for member in members],
                    [
                        "bin/tool",
                        "licenses/EasySplat/LICENSE",
                        "provenance/build.json",
                    ],
                )
                for member in members:
                    self.assertFalse(member.is_dir())
                    self.assertEqual(member.date_time, FIXED_ZIP_TIMESTAMP)
                    self.assertEqual(member.create_system, 3)
                    self.assertEqual(member.compress_type, zipfile.ZIP_DEFLATED)
                    self.assertEqual(member.extra, b"")
                    self.assertEqual(member.comment, b"")
                    mode = member.external_attr >> 16
                    self.assertTrue(stat.S_ISREG(mode))
                    expected_mode = 0o755 if member.filename == "bin/tool" else 0o644
                    self.assertEqual(stat.S_IMODE(mode), expected_mode)

    def test_rejects_unsafe_archive_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            for label in ("symlink", "fifo", "control", "backslash", "non_nfc"):
                with self.subTest(label=label):
                    root = base / label
                    payload = root / "payload"
                    payload.mkdir(parents=True)
                    (payload / "regular").write_text("safe\n", encoding="utf-8")
                    if label == "symlink":
                        (payload / "unsafe").symlink_to("regular")
                        expected = "symlink"
                    elif label == "fifo":
                        os.mkfifo(payload / "unsafe")
                        expected = "unsupported file type"
                    elif label == "control":
                        (payload / "unsafe\nname").write_text("bad\n", encoding="utf-8")
                        expected = "control character"
                    elif label == "backslash":
                        (payload / "unsafe\\name").write_text("bad\n", encoding="utf-8")
                        expected = "backslash"
                    else:
                        (payload / "unsafe-e\u0301").write_text(
                            "bad\n", encoding="utf-8"
                        )
                        expected = "not nfc"
                    output = base / f"{label}.zip"
                    output.write_bytes(b"preserve-existing-archive")

                    result = self.run_archiver(root, output, "payload")

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr.lower())
                    self.assertEqual(output.read_bytes(), b"preserve-existing-archive")
                    self.assertEqual(list(base.glob(f".{output.name}.*.tmp")), [])

    def test_rejects_surrogate_archive_names(self) -> None:
        module = load_archiver_module()

        with self.assertRaisesRegex(module.ArchiveError, "surrogate code point"):
            module.validate_archive_name("unsafe-\udcff")

    def test_rejects_a_selected_file_beneath_a_symlinked_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            root.mkdir()
            outside = base / "outside"
            outside.mkdir()
            (outside / "file").write_text("must not be archived\n", encoding="utf-8")
            (root / "linked-parent").symlink_to(outside, target_is_directory=True)
            output = base / "archive.zip"

            result = self.run_archiver(root, output, "linked-parent/file")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr.lower())
            self.assertFalse(output.exists())

    def test_rejects_source_escape_and_output_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            payload = root / "payload"
            payload.mkdir(parents=True)
            (payload / "input").write_text("input\n", encoding="utf-8")
            outside = base / "outside"
            outside.write_text("outside\n", encoding="utf-8")

            escape = self.run_archiver(root, base / "escape.zip", "../outside")
            self.assertNotEqual(escape.returncode, 0)
            self.assertIn("relative path", escape.stderr.lower())
            self.assertFalse((base / "escape.zip").exists())

            output = payload / "archive.zip"
            output.write_bytes(b"preserve")
            overlap = self.run_archiver(root, output, "payload")
            self.assertNotEqual(overlap.returncode, 0)
            self.assertIn("overlaps selected input", overlap.stderr.lower())
            self.assertEqual(output.read_bytes(), b"preserve")

    def test_fsyncs_the_output_directory_after_atomic_replace(self) -> None:
        module = load_archiver_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            root.mkdir()
            (root / "input").write_text("input\n", encoding="utf-8")
            output = base / "archive.zip"
            events = []
            original_fsync = module.os.fsync
            original_replace = module.os.replace

            def recording_fsync(descriptor):
                events.append(("fsync", stat.S_ISDIR(os.fstat(descriptor).st_mode)))
                return original_fsync(descriptor)

            def recording_replace(source, destination):
                events.append(("replace", Path(destination)))
                return original_replace(source, destination)

            with (
                mock.patch.object(module.os, "fsync", side_effect=recording_fsync),
                mock.patch.object(module.os, "replace", side_effect=recording_replace),
            ):
                module.create_archive(str(root), str(output), ["input"])

            self.assertTrue(output.is_file())
            self.assertEqual(
                events,
                [
                    ("fsync", False),
                    ("replace", output.resolve()),
                    ("fsync", True),
                ],
            )

    def test_rejects_an_in_place_source_mutation_after_collection(self) -> None:
        module = load_archiver_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            root.mkdir()
            source = root / "input"
            source.write_bytes(b"AAAA")
            os.utime(source, (1_600_000_000, 1_600_000_000))
            selections = module.selected_paths(root.resolve(), ["input"])
            files = module.collect_files(root.resolve(), selections)
            output = base / "archive.zip"
            output.write_bytes(b"preserve-existing-archive")

            source.write_bytes(b"BBBB")

            with self.assertRaisesRegex(
                module.ArchiveError, "changed while being read"
            ):
                module.write_archive(output, files)
            self.assertEqual(output.read_bytes(), b"preserve-existing-archive")
            self.assertEqual(list(base.glob(f".{output.name}.*.tmp")), [])


class PackageScriptTests(unittest.TestCase):
    def native_receipt_validator(self) -> str:
        source = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        shell_body = source.split("validate_native_receipts() {", 1)[1].split(
            "\nPY\n}", 1
        )[0]
        return shell_body.split("<<'PY'\n", 1)[1]

    def test_all_component_archives_use_the_reproducible_writer(self) -> None:
        source = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'REPRODUCIBLE_ZIP="$ROOT/scripts/toolchain/create_reproducible_zip.py"',
            source,
        )
        self.assertEqual(source.count('python3 "$REPRODUCIBLE_ZIP"'), 3)
        self.assertNotIn("zip -q -r", source)
        for path in (
            "bin",
            "lib",
            "licenses",
            "provenance",
            "supply-chain/components.json",
            "msplat/build_info.json",
            "msplat/LICENSE",
            "da3_mps/bin",
            "da3_mps/python",
            "da3_mps/app",
            "da3_mps/vendor",
            "da3_mps/licenses",
            "da3_mps/build_info.json",
            "da3_mps/models/DA3-BASE",
            "da3_mps/models/DA3-SMALL",
        ):
            self.assertIn(f'--path "{path}"', source)

    def test_release_clean_guard_covers_the_writer_and_all_toolchain_tests(self) -> None:
        source = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("scripts/toolchain/create_reproducible_zip.py", source)
        self.assertIn("scripts/toolchain/tests", source)

    def test_dependency_tree_identity_does_not_encode_numeric_ownership(self) -> None:
        source = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        receipt_validation = source.split("validate_native_receipts() {", 1)[1].split(
            "\nPY\n}", 1
        )[0]
        self.assertIn(
            'receipt.get("ownership_policy") '
            '!= "invoking-build-user-and-primary-group"',
            receipt_validation,
        )
        self.assertIn('"normalized_owner_uid" in receipt', receipt_validation)
        self.assertIn('"normalized_owner_gid" in receipt', receipt_validation)
        self.assertNotIn("str(metadata.st_uid)", receipt_validation)
        self.assertNotIn("str(metadata.st_gid)", receipt_validation)
        self.assertIn("os.getuid()", receipt_validation)
        self.assertIn("os.getgid()", receipt_validation)

    def test_native_receipt_validator_rejects_ownership_contract_violations(
        self,
    ) -> None:
        capabilities = [
            "feature_extractor",
            "matches_importer",
            "local_vocab_retriever",
            "mapper",
            "point_triangulator",
            "bundle_adjuster",
            "model_analyzer",
            "image_undistorter",
            "model_converter",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            validator = base / "validate.py"
            validator.write_text(self.native_receipt_validator(), encoding="utf-8")
            colmap = base / "colmap"
            binary = colmap / "bin" / "colmap"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"native colmap fixture\n")

            roots = {}
            names = {
                "colmap-support": "colmap-support",
                "ceres": "ceres-static",
                "openimageio": "openimageio-static",
            }
            for component, toolchain_name in names.items():
                root = base / component
                library = root / "lib" / f"lib{component}.a"
                library.parent.mkdir(parents=True)
                library.write_bytes(f"{component} bytes\n".encode())
                receipt = {
                    "toolchain_name": toolchain_name,
                    "architecture": "arm64",
                    "deployment_target": "macOS 15.0",
                    "ownership_policy": "invoking-build-user-and-primary-group",
                    "library_sha256": {library.name: sha256(library)},
                }
                (root / "build_info.json").write_text(
                    json.dumps(receipt, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                roots[component] = root

            dependency_receipt_hashes = {
                name: sha256(root / "build_info.json") for name, root in roots.items()
            }
            dependency_library_hashes = {
                name: {f"lib/lib{name}.a": sha256(root / "lib" / f"lib{name}.a")}
                for name, root in roots.items()
            }
            dependency_tree_hashes = {
                name: portable_tree_sha256(root) for name, root in roots.items()
            }
            colmap_receipt = {
                "toolchain_name": "colmap",
                "schema_version": 2,
                "executable_sha256": sha256(binary),
                "enabled_capabilities": capabilities,
                "build_options": {
                    "architecture": "arm64",
                    "deployment_target": "15.0",
                    "gpu": False,
                    "mvs": False,
                },
                "build_inputs": {
                    "dependency_receipt_sha256": dependency_receipt_hashes,
                    "dependency_library_sha256": dependency_library_hashes,
                    "dependency_tree_sha256": dependency_tree_hashes,
                },
            }
            (colmap / "build_info.json").write_text(
                json.dumps(colmap_receipt, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            command = [
                sys.executable,
                str(validator),
                str(colmap),
                str(roots["colmap-support"]),
                str(roots["ceres"]),
                str(roots["openimageio"]),
            ]

            def invoke() -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                )

            accepted = invoke()
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            support_receipt_path = roots["colmap-support"] / "build_info.json"
            original_receipt = json.loads(support_receipt_path.read_text())
            for mutation, expected in (
                ({"ownership_policy": "numeric-owner-encoded"}, "ownership policy"),
                ({"normalized_owner_uid": os.getuid()}, "numeric ownership"),
                ({"normalized_owner_gid": os.getgid()}, "numeric ownership"),
            ):
                support_receipt_path.write_text(
                    json.dumps(original_receipt | mutation, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                rejected = invoke()
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(expected, rejected.stderr)
            support_receipt_path.write_text(
                json.dumps(original_receipt, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            alternate_groups = [
                group for group in os.getgroups() if group != os.getgid()
            ]
            if alternate_groups:
                library = roots["colmap-support"] / "lib" / "libcolmap-support.a"
                os.chown(library, os.getuid(), alternate_groups[0])
                try:
                    rejected = invoke()
                finally:
                    os.chown(library, os.getuid(), os.getgid())
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("noncanonical ownership", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
