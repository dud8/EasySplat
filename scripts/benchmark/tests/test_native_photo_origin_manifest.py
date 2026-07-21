from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.benchmark import native_photo_origin_manifest as origin
from scripts.benchmark import photo_permutation_producer as producer


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


class NativePhotoOriginManifestTests(unittest.TestCase):
    def test_manifest_is_exact_private_and_content_ordered(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "photos"
            (root / "nested").mkdir(parents=True)
            files = {
                "z.CR3": b"raw-z",
                "A.heic": b"heic-a",
                "nested/é.RAF": b"raw-e",
                "nested/frame.TIFF": b"tiff",
            }
            for relative_path, contents in files.items():
                (root / relative_path).write_bytes(contents)
            (root / ".DS_Store").write_bytes(b"ignored regular file")

            first = origin.build_manifest(root)
            with mock.patch.object(
                origin,
                "_scan_directory",
                wraps=lambda descriptor: reversed(
                    list(origin._scan_directory_unpatched(descriptor))
                ),
            ):
                second = origin.build_manifest(root)

            expected_sources = [
                {"kind": "native_photo", "source_sha256": value}
                for value in sorted(digest(contents) for contents in files.values())
            ]
            self.assertEqual(first, {"schema_version": 1, "sources": expected_sources})
            self.assertEqual(first, second)
            encoded = json.dumps(first, sort_keys=True)
            self.assertNotIn(str(root), encoded)
            self.assertNotIn("z.CR3", encoded)
            self.assertNotIn("nested", encoded)

    def test_rejects_empty_duplicate_symlink_hardlink_and_special_closures(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)

            empty = base / "empty"
            empty.mkdir()
            with self.assertRaisesRegex(origin.OriginManifestError, "no supported"):
                origin.build_manifest(empty)

            duplicate = base / "duplicate"
            duplicate.mkdir()
            (duplicate / "a.JPG").write_bytes(b"same")
            (duplicate / "b.DNG").write_bytes(b"same")
            with self.assertRaisesRegex(
                origin.OriginManifestError, "duplicate content"
            ):
                origin.build_manifest(duplicate)

            symlink = base / "symlink"
            symlink.mkdir()
            (symlink / "a.JPG").write_bytes(b"a")
            (symlink / "linked.JPG").symlink_to(symlink / "a.JPG")
            with self.assertRaisesRegex(origin.OriginManifestError, "symlink"):
                origin.build_manifest(symlink)

            hardlink = base / "hardlink"
            hardlink.mkdir()
            (hardlink / "a.JPG").write_bytes(b"a")
            os.link(hardlink / "a.JPG", hardlink / "b.JPG")
            with self.assertRaisesRegex(origin.OriginManifestError, "hardlink"):
                origin.build_manifest(hardlink)

            special = base / "special"
            special.mkdir()
            (special / "a.JPG").write_bytes(b"a")
            os.mkfifo(special / "capture.JPG")
            try:
                with self.assertRaisesRegex(origin.OriginManifestError, "special"):
                    origin.build_manifest(special)
            finally:
                (special / "capture.JPG").unlink()

    def test_rejects_source_mutation_between_inventory_and_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "photos"
            root.mkdir()
            mutable = root / "a.JPG"
            mutable.write_bytes(b"before")
            (root / "b.JPG").write_bytes(b"stable")
            real_attest = origin._attest_source_tree

            def mutate_then_attest(*args: object, **kwargs: object) -> None:
                mutable.write_bytes(b"after")
                real_attest(*args, **kwargs)

            with (
                mock.patch.object(origin, "_attest_source_tree", mutate_then_attest),
                self.assertRaisesRegex(
                    origin.OriginManifestError, "source tree changed"
                ),
            ):
                origin.build_manifest(root)

    def test_exclusive_atomic_write_preserves_existing_and_replacement_files(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output = base / "origins.json"

            summary = origin.generate(source, output)
            self.assertEqual(
                summary,
                {
                    "schema_version": 1,
                    "source_count": 1,
                    "manifest_sha256": digest(output.read_bytes()),
                },
            )
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(
                json.loads(output.read_text()),
                {
                    "schema_version": 1,
                    "sources": [
                        {"kind": "native_photo", "source_sha256": digest(b"a")}
                    ],
                },
            )
            self.assertEqual(list(base.glob(".native-photo-origin-*")), [])

            output.write_bytes(b"user replacement")
            with self.assertRaisesRegex(origin.OriginManifestError, "already exists"):
                origin.generate(source, output)
            self.assertEqual(output.read_bytes(), b"user replacement")

    def test_generated_receipt_is_consumed_by_native_photo_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "b.NEF").write_bytes(b"b")
            (source / "a.JPG").write_bytes(b"a")
            origin_path = base / "native-origins.json"
            origin.generate(source, origin_path)

            source_manifest = producer.inventory_source_manifest(
                source,
                corpus_id="native-photo-generator-fixture",
                source_kind="native_photos",
                origin_manifest=json.loads(origin_path.read_text()),
            )
            self.assertEqual(source_manifest["schema_version"], 2)
            self.assertEqual(
                source_manifest["provenance"],
                {
                    "source_kind": "native_photos",
                    "video_origin_count": 0,
                    "photo_origin_count": 2,
                    "origin_closure_sha256": producer.evidence.sha256_bytes(
                        producer.evidence.canonical_json_bytes(
                            [
                                {
                                    "kind": "native_photo",
                                    "source_sha256": value,
                                }
                                for value in sorted([digest(b"a"), digest(b"b")])
                            ]
                        )
                    ),
                },
            )

    def test_rejects_output_inside_source_and_non_plain_output_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            with self.assertRaisesRegex(origin.OriginManifestError, "outside source"):
                origin.generate(source, source / "origins.json")

            real_parent = base / "real"
            real_parent.mkdir()
            linked_parent = base / "linked"
            linked_parent.symlink_to(real_parent, target_is_directory=True)
            with self.assertRaisesRegex(origin.OriginManifestError, "plain directory"):
                origin.generate(source, linked_parent / "origins.json")

            real_parent_subdirectory = real_parent / "subdirectory"
            real_parent_subdirectory.mkdir()
            with self.assertRaisesRegex(
                origin.OriginManifestError, "symlink component"
            ):
                origin.generate(
                    source,
                    linked_parent / "subdirectory" / "origins.json",
                )

            real_source_parent = base / "real-source-parent"
            real_source = real_source_parent / "photos"
            real_source.mkdir(parents=True)
            (real_source / "a.JPG").write_bytes(b"a")
            linked_source_parent = base / "linked-source-parent"
            linked_source_parent.symlink_to(
                real_source_parent, target_is_directory=True
            )
            with self.assertRaisesRegex(
                origin.OriginManifestError, "symlink component"
            ):
                origin.build_manifest(linked_source_parent / "photos")

    def test_output_parent_replacement_before_publication_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output_parent = base / "publication"
            output_parent.mkdir()
            replacement = base / "replacement"
            replacement.mkdir()
            displaced = base / "displaced"
            real_attest = origin._attest_source_tree

            def replace_parent_then_attest(*args: object, **kwargs: object) -> None:
                output_parent.rename(displaced)
                replacement.rename(output_parent)
                real_attest(*args, **kwargs)

            with (
                mock.patch.object(
                    origin,
                    "_attest_source_tree",
                    replace_parent_then_attest,
                ),
                self.assertRaisesRegex(
                    origin.OriginManifestError, "output parent changed"
                ),
            ):
                origin.generate(source, output_parent / "origins.json")
            self.assertFalse((output_parent / "origins.json").exists())
            self.assertFalse((displaced / "origins.json").exists())

    def test_post_link_fsync_failure_removes_only_owned_visible_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output = base / "origins.json"
            real_fsync = os.fsync
            calls = 0

            def fail_post_link(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 4:
                    raise OSError("forced post-link durability failure")
                real_fsync(descriptor)

            with (
                mock.patch.object(origin.os, "fsync", fail_post_link),
                self.assertRaisesRegex(OSError, "forced post-link"),
            ):
                origin.generate(source, output)
            self.assertFalse(output.exists())

    def test_post_link_failure_preserves_a_raced_final_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output = base / "origins.json"
            real_fsync = os.fsync
            calls = 0

            def replace_then_fail(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 4:
                    output.unlink()
                    output.write_bytes(b"raced replacement")
                    raise OSError("forced post-link durability failure")
                real_fsync(descriptor)

            with (
                mock.patch.object(origin.os, "fsync", replace_then_fail),
                self.assertRaisesRegex(OSError, "forced post-link"),
            ):
                origin.generate(source, output)
            self.assertEqual(output.read_bytes(), b"raced replacement")

    def test_success_rejects_a_final_name_replaced_after_link(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output = base / "origins.json"
            real_link = os.link

            def link_then_replace(*args: object, **kwargs: object) -> None:
                real_link(*args, **kwargs)
                output.unlink()
                output.write_bytes(b"raced replacement")

            with (
                mock.patch.object(origin.os, "link", link_then_replace),
                self.assertRaisesRegex(
                    origin.OriginManifestError, "final output changed"
                ),
            ):
                origin.generate(source, output)
            self.assertEqual(output.read_bytes(), b"raced replacement")
            self.assertEqual(list(base.glob(".native-photo-origin-*")), [])

    def test_transaction_file_replacement_is_never_deleted_by_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output = base / "origins.json"
            real_link = os.link
            real_fsync = os.fsync
            calls = 0
            transaction_path: Path | None = None

            def link_then_replace(*args: object, **kwargs: object) -> None:
                nonlocal transaction_path
                real_link(*args, **kwargs)
                transaction_path = next(base.glob(".native-photo-origin-*"))
                manifest = transaction_path / "manifest"
                manifest.unlink()
                manifest.write_bytes(b"transaction replacement")

            def fail_post_link(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 4:
                    raise OSError("forced post-link durability failure")
                real_fsync(descriptor)

            with (
                mock.patch.object(origin.os, "link", link_then_replace),
                mock.patch.object(origin.os, "fsync", fail_post_link),
                self.assertRaisesRegex(OSError, "forced post-link"),
            ):
                origin.generate(source, output)
            self.assertFalse(output.exists())
            self.assertIsNotNone(transaction_path)
            assert transaction_path is not None
            self.assertEqual(
                (transaction_path / "manifest").read_bytes(),
                b"transaction replacement",
            )

    def test_rejects_excessive_depth_and_oversize_before_hashing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            deep = base / "deep"
            deep.mkdir()
            cursor = deep
            for index in range(origin.MAXIMUM_RECURSION_DEPTH + 1):
                cursor = cursor / f"d{index:03d}"
                cursor.mkdir()
            (cursor / "photo.JPG").write_bytes(b"a")
            with self.assertRaisesRegex(origin.OriginManifestError, "depth"):
                origin.build_manifest(deep)

            oversize = base / "oversize"
            oversize.mkdir()
            oversized_photo = oversize / "large.DNG"
            with oversized_photo.open("wb") as handle:
                handle.truncate(origin.MAXIMUM_FILE_BYTES + 1)
            with (
                mock.patch.object(
                    origin,
                    "_hash_descriptor",
                    side_effect=AssertionError("oversize file was hashed"),
                ),
                self.assertRaisesRegex(origin.OriginManifestError, "supported size"),
            ):
                origin.build_manifest(oversize)

    def test_rejects_group_or_world_writable_nonsticky_output_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "photos"
            source.mkdir()
            (source / "a.JPG").write_bytes(b"a")
            output_parent = base / "publication"
            output_parent.mkdir(mode=0o770)
            output_parent.chmod(0o770)
            with self.assertRaisesRegex(origin.OriginManifestError, "private"):
                origin.generate(source, output_parent / "origins.json")


if __name__ == "__main__":
    unittest.main()
