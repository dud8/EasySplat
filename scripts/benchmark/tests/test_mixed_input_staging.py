from __future__ import annotations

import contextlib
import ctypes
import errno
import hashlib
import io
import json
import os
import resource
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.benchmark import mixed_input_staging as staging


def digest(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def entry(
    source: Path,
    logical_name: str,
    media_type: str,
    group_id: str,
) -> dict[str, object]:
    return {
        "source_path": str(source),
        "logical_relative_path": logical_name,
        "media_type": media_type,
        "group_id": group_id,
    }


def write_descriptor(path: Path, entries: list[dict[str, object]]) -> None:
    path.write_bytes(canonical_json({"schema_version": 1, "entries": entries}))


def set_extended_attribute(path: Path, name: bytes, value: bytes) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        library = ctypes.CDLL(None, use_errno=True)
        setter = library.fsetxattr
        setter.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_uint32,
            ctypes.c_int,
        ]
        setter.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(value)
        ctypes.set_errno(0)
        if setter(descriptor, name, buffer, len(value), 0, 0) != 0:
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number))
    finally:
        os.close(descriptor)


def add_extended_acl(path: Path) -> None:
    subprocess.run(
        ["/bin/chmod", "+a", "everyone allow read", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )


def set_birthtime(path: Path, seconds: int) -> None:
    class AttributeList(ctypes.Structure):
        _fields_ = [
            ("bitmap_count", ctypes.c_uint16),
            ("reserved", ctypes.c_uint16),
            ("common_attributes", ctypes.c_uint32),
            ("volume_attributes", ctypes.c_uint32),
            ("directory_attributes", ctypes.c_uint32),
            ("file_attributes", ctypes.c_uint32),
            ("fork_attributes", ctypes.c_uint32),
        ]

    class TimeSpec(ctypes.Structure):
        _fields_ = [("seconds", ctypes.c_long), ("nanoseconds", ctypes.c_long)]

    descriptor = os.open(path, os.O_RDONLY)
    try:
        attributes = AttributeList(5, 0, 0x00000200, 0, 0, 0, 0)
        timestamp = TimeSpec(seconds, 0)
        library = ctypes.CDLL(None, use_errno=True)
        setter = library.fsetattrlist
        setter.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(AttributeList),
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_uint,
        ]
        setter.restype = ctypes.c_int
        ctypes.set_errno(0)
        if (
            setter(
                descriptor,
                ctypes.byref(attributes),
                ctypes.byref(timestamp),
                ctypes.sizeof(timestamp),
                0,
            )
            != 0
        ):
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number))
    finally:
        os.close(descriptor)


class MixedInputStagingTests(unittest.TestCase):
    def test_stages_a_deterministic_private_mixed_input_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "original portrait.JPG"
            first_video = sources / "first source.MP4"
            second_video = sources / "second source.mov"
            photo.write_bytes(b"photo")
            first_video.write_bytes(b"first-video")
            second_video.write_bytes(b"second-video")
            before = {
                path: (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns)
                for path in (photo, first_video, second_video)
            }
            descriptor = base / "sources.json"
            entries = [
                entry(second_video, "clip-002.mov", "video", "clip-002"),
                entry(photo, "photo-001.jpg", "photo", "native-photos"),
                entry(first_video, "clip-001.mp4", "video", "clip-001"),
            ]
            write_descriptor(descriptor, entries)

            first_output = base / "staged-one"
            first_summary = staging.stage(descriptor, first_output)
            reversed_descriptor = base / "reversed.json"
            write_descriptor(reversed_descriptor, list(reversed(entries)))
            second_output = base / "staged-two"
            second_summary = staging.stage(reversed_descriptor, second_output)

            first_manifest_bytes = (first_output / staging.MANIFEST_NAME).read_bytes()
            second_manifest_bytes = (second_output / staging.MANIFEST_NAME).read_bytes()
            self.assertEqual(first_manifest_bytes, second_manifest_bytes)
            manifest = json.loads(first_manifest_bytes)
            expected_entries = [
                {
                    "logical_relative_path": "clip-001.mp4",
                    "media_type": "video",
                    "group_id": "clip-001",
                    "bytes": len(b"first-video"),
                    "sha256": digest(b"first-video"),
                },
                {
                    "logical_relative_path": "clip-002.mov",
                    "media_type": "video",
                    "group_id": "clip-002",
                    "bytes": len(b"second-video"),
                    "sha256": digest(b"second-video"),
                },
                {
                    "logical_relative_path": "photo-001.jpg",
                    "media_type": "photo",
                    "group_id": "native-photos",
                    "bytes": len(b"photo"),
                    "sha256": digest(b"photo"),
                },
            ]
            self.assertEqual(
                manifest,
                {
                    "schema_version": 1,
                    "kind": "easysplat-private-mixed-input-staging",
                    "entry_count": 3,
                    "total_bytes": sum(item["bytes"] for item in expected_entries),
                    "aggregate_sha256": digest(canonical_json(expected_entries)),
                    "entries": expected_entries,
                },
            )
            encoded = first_manifest_bytes.decode("utf-8")
            self.assertNotIn(str(sources), encoded)
            self.assertNotIn("original portrait", encoded)
            self.assertEqual(stat.S_IMODE(first_output.stat().st_mode), 0o700)
            self.assertEqual(
                stat.S_IMODE((first_output / staging.MANIFEST_NAME).stat().st_mode),
                0o600,
            )
            for item in expected_entries:
                path = first_output / item["logical_relative_path"]
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(digest(path.read_bytes()), item["sha256"])
                self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(first_summary, second_summary)
            self.assertEqual(
                first_summary,
                {
                    "schema_version": 1,
                    "entry_count": 3,
                    "total_bytes": manifest["total_bytes"],
                    "manifest_sha256": digest(first_manifest_bytes),
                },
            )
            for path, identity in before.items():
                self.assertEqual(
                    (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns),
                    identity,
                )
            self.assertEqual(
                [
                    path.name
                    for path in base.iterdir()
                    if path.name.startswith(staging.TEMPORARY_PREFIX)
                ],
                [],
            )

    def test_rejects_invalid_descriptor_fields_and_ambiguous_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "source.jpg"
            other_photo = sources / "other.jpg"
            video = sources / "source.mp4"
            other_video = sources / "other.mov"
            photo.write_bytes(b"photo")
            other_photo.write_bytes(b"other-photo")
            video.write_bytes(b"video")
            other_video.write_bytes(b"other")

            def with_video(*items: dict[str, object]) -> dict[str, object]:
                return {
                    "schema_version": 1,
                    "entries": [
                        *items,
                        entry(video, "valid-clip.mp4", "video", "valid-clip"),
                    ],
                }

            invalid_cases: list[tuple[str, dict[str, object], str]] = [
                (
                    "unknown top-level field",
                    {"schema_version": 1, "entries": [], "extra": True},
                    "descriptor fields",
                ),
                (
                    "unknown entry field",
                    with_video(
                        {**entry(photo, "photo.jpg", "photo", "photos"), "extra": 1}
                    ),
                    "entry fields",
                ),
                (
                    "relative source",
                    with_video(
                        {
                            **entry(photo, "photo.jpg", "photo", "photos"),
                            "source_path": "relative.jpg",
                        },
                    ),
                    "source path",
                ),
                (
                    "traversal",
                    with_video(entry(photo, "../photo.jpg", "photo", "photos")),
                    "logical relative path",
                ),
                (
                    "nested runtime path",
                    with_video(entry(photo, "photos/photo.jpg", "photo", "photos")),
                    "logical relative path",
                ),
                (
                    "wrong extension",
                    with_video(entry(photo, "photo.mp4", "photo", "photos")),
                    "media extension",
                ),
                (
                    "untranscoded suffix change",
                    with_video(entry(photo, "photo.png", "photo", "photos")),
                    "preserve its source suffix",
                ),
                (
                    "bad group",
                    with_video(entry(photo, "photo.jpg", "photo", "Private Label")),
                    "group ID",
                ),
                (
                    "case-folded collision",
                    {
                        "schema_version": 1,
                        "entries": [
                            entry(photo, "Frame.JPG", "photo", "photos"),
                            entry(other_photo, "frame.jpg", "photo", "other-photos"),
                            entry(video, "clip.mp4", "video", "clip"),
                        ],
                    },
                    "ambiguous logical basename",
                ),
                (
                    "duplicate video group",
                    {
                        "schema_version": 1,
                        "entries": [
                            entry(video, "clip-001.mp4", "video", "clip"),
                            entry(other_video, "clip-002.mov", "video", "clip"),
                            entry(photo, "photo.jpg", "photo", "photos"),
                        ],
                    },
                    "video group ID",
                ),
                (
                    "multiple photo groups",
                    {
                        "schema_version": 1,
                        "entries": [
                            entry(photo, "photo-a.jpg", "photo", "photos-a"),
                            entry(other_photo, "photo-b.jpg", "photo", "photos-b"),
                            entry(video, "clip.mp4", "video", "clip"),
                        ],
                    },
                    "single photo group",
                ),
                (
                    "photo video group collision",
                    {
                        "schema_version": 1,
                        "entries": [
                            entry(photo, "photo.jpg", "photo", "capture"),
                            entry(video, "clip.mp4", "video", "capture"),
                        ],
                    },
                    "distinct from video groups",
                ),
            ]
            for label, value, message in invalid_cases:
                with self.subTest(label=label):
                    descriptor = base / f"{label.replace(' ', '-')}.json"
                    descriptor.write_bytes(canonical_json(value))
                    with self.assertRaisesRegex(staging.StagingError, message):
                        staging.stage(
                            descriptor, base / f"output-{label.replace(' ', '-')}"
                        )

    def test_rejects_symlinks_hardlinks_specials_and_duplicate_identities(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            companion = sources / "clip.mp4"
            companion.write_bytes(b"video")

            def mixed(*items: dict[str, object]) -> list[dict[str, object]]:
                return [
                    *items,
                    entry(companion, "clip.mp4", "video", "clip"),
                ]

            regular = sources / "regular.jpg"
            regular.write_bytes(b"regular")
            symlink = sources / "linked.jpg"
            symlink.symlink_to(regular)
            descriptor = base / "symlink.json"
            write_descriptor(
                descriptor,
                mixed(entry(symlink, "photo.jpg", "photo", "photos")),
            )
            with self.assertRaisesRegex(staging.StagingError, "symlink"):
                staging.stage(descriptor, base / "symlink-output")

            first_link = sources / "hardlink-a.jpg"
            second_link = sources / "hardlink-b.jpg"
            first_link.write_bytes(b"hardlink")
            os.link(first_link, second_link)
            descriptor = base / "hardlink.json"
            write_descriptor(
                descriptor,
                mixed(entry(first_link, "hardlink.jpg", "photo", "photos")),
            )
            with self.assertRaisesRegex(staging.StagingError, "hardlink"):
                staging.stage(descriptor, base / "hardlink-output")

            fifo = sources / "capture.jpg"
            os.mkfifo(fifo)
            try:
                descriptor = base / "special.json"
                write_descriptor(
                    descriptor,
                    mixed(entry(fifo, "fifo.jpg", "photo", "photos")),
                )
                with self.assertRaisesRegex(staging.StagingError, "special"):
                    staging.stage(descriptor, base / "special-output")
            finally:
                fifo.unlink()

            duplicate_a = sources / "duplicate-a.jpg"
            duplicate_b = sources / "duplicate-b.jpg"
            duplicate_a.write_bytes(b"duplicate")
            duplicate_b.write_bytes(b"duplicate")
            descriptor = base / "duplicate-content.json"
            write_descriptor(
                descriptor,
                mixed(
                    entry(duplicate_a, "a.jpg", "photo", "photos"),
                    entry(duplicate_b, "b.jpg", "photo", "photos"),
                ),
            )
            with self.assertRaisesRegex(staging.StagingError, "duplicate content"):
                staging.stage(descriptor, base / "duplicate-content-output")

            descriptor = base / "duplicate-source.json"
            write_descriptor(
                descriptor,
                mixed(
                    entry(regular, "a.jpg", "photo", "photos"),
                    entry(regular, "b.jpg", "photo", "photos"),
                ),
            )
            with self.assertRaisesRegex(
                staging.StagingError, "duplicate source identity"
            ):
                staging.stage(descriptor, base / "duplicate-source-output")

    def test_rejects_symlinked_ancestors_and_output_inside_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            real_source = base / "real-source"
            real_source.mkdir()
            photo = real_source / "photo.jpg"
            video = real_source / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            linked_source = base / "linked-source"
            linked_source.symlink_to(real_source, target_is_directory=True)
            descriptor = base / "source-link.json"
            write_descriptor(
                descriptor,
                [
                    entry(linked_source / "photo.jpg", "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            with self.assertRaisesRegex(staging.StagingError, "symlink component"):
                staging.stage(descriptor, base / "source-link-output")

            real_output_parent = base / "real-output-parent"
            real_output_parent.mkdir()
            linked_output_parent = base / "linked-output-parent"
            linked_output_parent.symlink_to(
                real_output_parent, target_is_directory=True
            )
            descriptor = base / "output-link.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            with self.assertRaisesRegex(staging.StagingError, "symlink component"):
                staging.stage(descriptor, linked_output_parent / "staged")

            descriptor_inside_source = real_source / "descriptor.json"
            write_descriptor(
                descriptor_inside_source,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            with self.assertRaisesRegex(
                staging.StagingError, "outside source directories"
            ):
                staging.stage(descriptor_inside_source, real_source / "staged")

    def test_rejects_source_changes_during_staging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"before")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            original = staging._clone_or_copy

            def mutate_after_copy(
                source_descriptor: int,
                destination_directory_descriptor: int,
                destination_name: str,
            ) -> tuple[int, int]:
                created = original(
                    source_descriptor,
                    destination_directory_descriptor,
                    destination_name,
                )
                if destination_name == "photo.jpg":
                    photo.write_bytes(b"after!")
                return created

            with (
                mock.patch.object(staging, "_clone_or_copy", mutate_after_copy),
                self.assertRaisesRegex(staging.StagingError, "source changed"),
            ):
                staging.stage(descriptor, base / "output")
            self.assertFalse((base / "output").exists())
            self.assertEqual(
                [
                    path
                    for path in base.iterdir()
                    if path.name.startswith(staging.TEMPORARY_PREFIX)
                ],
                [],
            )

    def test_rejects_source_changes_at_the_publication_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"before")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            original = staging._verify_staging_directory
            invocation_count = 0

            def mutate_after_first_verification(
                *args: object, **kwargs: object
            ) -> None:
                nonlocal invocation_count
                original(*args, **kwargs)
                invocation_count += 1
                if invocation_count == 1:
                    photo.write_bytes(b"after!")

            with (
                mock.patch.object(
                    staging,
                    "_verify_staging_directory",
                    mutate_after_first_verification,
                ),
                self.assertRaisesRegex(staging.StagingError, "source changed"),
            ):
                staging.stage(descriptor, base / "output")
            self.assertFalse((base / "output").exists())
            self.assertEqual(
                [
                    path
                    for path in base.iterdir()
                    if path.name.startswith(staging.TEMPORARY_PREFIX)
                ],
                [],
            )

    def test_exclusive_publication_preserves_existing_and_racing_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )

            existing = base / "existing"
            existing.mkdir()
            (existing / "marker").write_bytes(b"user")
            with self.assertRaisesRegex(staging.StagingError, "already exists"):
                staging.stage(descriptor, existing)
            self.assertEqual((existing / "marker").read_bytes(), b"user")

            racing = base / "racing"
            original = staging._rename_exclusive

            def publish_race(
                parent_descriptor: int,
                temporary_name: str,
                destination_name: str,
            ) -> None:
                racing.mkdir()
                (racing / "marker").write_bytes(b"replacement")
                original(parent_descriptor, temporary_name, destination_name)

            with (
                mock.patch.object(staging, "_rename_exclusive", publish_race),
                self.assertRaisesRegex(staging.StagingError, "already exists"),
            ):
                staging.stage(descriptor, racing)
            self.assertEqual((racing / "marker").read_bytes(), b"replacement")
            self.assertEqual(
                [
                    path
                    for path in base.iterdir()
                    if path.name.startswith(staging.TEMPORARY_PREFIX)
                ],
                [],
            )

    def test_cleanup_does_not_delete_a_replaced_temporary_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            original = staging._clone_or_copy

            def replace_after_copy(
                source_descriptor: int,
                destination_directory_descriptor: int,
                destination_name: str,
            ) -> tuple[int, int]:
                created = original(
                    source_descriptor,
                    destination_directory_descriptor,
                    destination_name,
                )
                if destination_name != "photo.jpg":
                    return created
                os.unlink(destination_name, dir_fd=destination_directory_descriptor)
                replacement = os.open(
                    destination_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=destination_directory_descriptor,
                )
                try:
                    os.write(replacement, b"user replacement")
                    os.fsync(replacement)
                finally:
                    os.close(replacement)
                return created

            with (
                mock.patch.object(staging, "_clone_or_copy", replace_after_copy),
                self.assertRaisesRegex(
                    staging.StagingError, "staged file identity changed"
                ),
            ):
                staging.stage(descriptor, base / "output")
            temporary_roots = [
                path
                for path in base.iterdir()
                if path.name.startswith(staging.TEMPORARY_PREFIX)
            ]
            self.assertEqual(len(temporary_roots), 1)
            self.assertEqual(
                (temporary_roots[0] / "photo.jpg").read_bytes(),
                b"user replacement",
            )

    def test_rejects_group_or_world_writable_output_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output_parent = base / "shared-output"
            output_parent.mkdir()
            for mode in (0o755, 0o777):
                with self.subTest(mode=oct(mode)):
                    output_parent.chmod(mode)
                    with self.assertRaisesRegex(
                        staging.StagingError, "output parent permissions"
                    ):
                        staging.stage(descriptor, output_parent / "staged")
                    self.assertEqual(list(output_parent.iterdir()), [])

            output_parent.chmod(0o700)
            add_extended_acl(output_parent)
            try:
                with self.assertRaisesRegex(staging.StagingError, "output parent.*ACL"):
                    staging.stage(descriptor, output_parent / "staged")
                self.assertEqual(list(output_parent.iterdir()), [])
            finally:
                subprocess.run(
                    ["/bin/chmod", "-N", str(output_parent)],
                    check=True,
                    capture_output=True,
                    text=True,
                )

    def test_preflights_source_and_aggregate_sizes_before_any_staging_write(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )

            for limit_name, limit, message in (
                ("MAXIMUM_SOURCE_FILE_BYTES", 4, "source size"),
                ("MAXIMUM_SOURCE_CLOSURE_BYTES", 9, "closure"),
            ):
                with self.subTest(limit_name=limit_name):
                    clone = mock.Mock(side_effect=AssertionError("copy must not start"))
                    with (
                        mock.patch.object(staging, limit_name, limit),
                        mock.patch.object(staging, "_clone_or_copy", clone),
                        self.assertRaisesRegex(staging.StagingError, message),
                    ):
                        staging.stage(descriptor, base / f"output-{limit_name}")
                    clone.assert_not_called()

    def test_revalidates_the_complete_preflight_set_before_first_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            original = staging._preflight_sources

            def mutate_after_preflight(*args: object, **kwargs: object) -> object:
                result = original(*args, **kwargs)
                photo.write_bytes(b"other")
                return result

            clone = mock.Mock(side_effect=AssertionError("copy must not start"))
            with (
                mock.patch.object(
                    staging, "_preflight_sources", mutate_after_preflight
                ),
                mock.patch.object(staging, "_clone_or_copy", clone),
                self.assertRaisesRegex(staging.StagingError, "source changed"),
            ):
                staging.stage(descriptor, base / "output")
            clone.assert_not_called()

    def test_clone_and_copy_paths_publish_the_same_canonical_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            set_extended_attribute(photo, b"user.easysplat-test", b"private metadata")
            set_extended_attribute(photo, b"com.apple.ResourceFork", b"resource fork")
            add_extended_acl(photo)
            source_timestamp_seconds = 946_684_800
            set_birthtime(photo, source_timestamp_seconds)
            os.utime(
                photo,
                ns=(
                    source_timestamp_seconds * 1_000_000_000,
                    source_timestamp_seconds * 1_000_000_000,
                ),
            )
            os.chflags(photo, stat.UF_HIDDEN | stat.UF_NODUMP)
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            cloned_output = base / "cloned"
            copied_output = base / "copied"
            try:
                staging.stage(descriptor, cloned_output)
                with mock.patch.object(
                    staging,
                    "_clone_or_copy",
                    side_effect=lambda source, destination, name: (
                        staging._copy_descriptor(
                            source,
                            destination,
                            name,
                        )
                    ),
                ):
                    staging.stage(descriptor, copied_output)
            finally:
                os.chflags(photo, 0)
                subprocess.run(
                    ["/bin/chmod", "-N", str(photo)],
                    check=True,
                    capture_output=True,
                    text=True,
                )

            self.assertEqual(
                (cloned_output / staging.MANIFEST_NAME).read_bytes(),
                (copied_output / staging.MANIFEST_NAME).read_bytes(),
            )
            xattrs_by_root: dict[Path, dict[str, tuple[bytes, ...]]] = {}
            for root in (cloned_output, copied_output):
                xattrs_by_root[root] = {}
                root_descriptor = os.open(root, os.O_RDONLY)
                try:
                    root_xattrs = staging._extended_attribute_names(root_descriptor)
                    xattrs_by_root[root]["."] = root_xattrs
                    self.assertEqual(
                        set(root_xattrs) - staging.SYSTEM_MANAGED_XATTRS,
                        set(),
                    )
                    self.assertFalse(staging._has_extended_acl(root_descriptor))
                    root_metadata = os.fstat(root_descriptor)
                    self.assertEqual(root_metadata.st_uid, os.geteuid())
                    self.assertEqual(root_metadata.st_gid, os.getegid())
                    self.assertEqual(stat.S_IMODE(root_metadata.st_mode), 0o700)
                    self.assertEqual(root_metadata.st_flags, 0)
                    self.assertEqual(
                        root_metadata.st_mtime_ns,
                        staging.CANONICAL_TIMESTAMP_NS,
                    )
                    self.assertEqual(
                        root_metadata.st_birthtime,
                        float(staging.CANONICAL_TIMESTAMP_SECONDS),
                    )
                finally:
                    os.close(root_descriptor)
                for child in root.iterdir():
                    descriptor_fd = os.open(child, os.O_RDONLY)
                    try:
                        child_xattrs = staging._extended_attribute_names(descriptor_fd)
                        xattrs_by_root[root][child.name] = child_xattrs
                        self.assertEqual(
                            set(child_xattrs) - staging.SYSTEM_MANAGED_XATTRS,
                            set(),
                        )
                        self.assertFalse(staging._has_extended_acl(descriptor_fd))
                        metadata = os.fstat(descriptor_fd)
                        self.assertEqual(metadata.st_uid, os.geteuid())
                        self.assertEqual(metadata.st_gid, os.getegid())
                        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
                        self.assertEqual(metadata.st_flags, 0)
                        self.assertEqual(
                            metadata.st_mtime_ns,
                            staging.CANONICAL_TIMESTAMP_NS,
                        )
                        self.assertEqual(
                            metadata.st_birthtime,
                            float(staging.CANONICAL_TIMESTAMP_SECONDS),
                        )
                    finally:
                        os.close(descriptor_fd)
            self.assertEqual(
                xattrs_by_root[cloned_output],
                xattrs_by_root[copied_output],
            )

    def test_parent_metadata_is_rechecked_after_the_durability_barrier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output_parent = base / "output-parent"
            output_parent.mkdir(mode=0o700)
            output = output_parent / "output"

            def weaken_after_fsync(parent_descriptor: int) -> None:
                os.fsync(parent_descriptor)
                output_parent.chmod(0o755)

            try:
                with (
                    mock.patch.object(staging, "_fsync_parent", weaken_after_fsync),
                    self.assertRaisesRegex(
                        staging.StagingError, "output parent permissions"
                    ),
                ):
                    staging.stage(descriptor, output)
            finally:
                output_parent.chmod(0o700)
            self.assertFalse(output.exists())

    def test_parent_metadata_is_rechecked_immediately_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output_parent = base / "output-parent"
            output_parent.mkdir(mode=0o700)
            output = output_parent / "output"
            original = staging._verify_staging_directory
            verification_count = 0

            def weaken_after_first_verification(
                *args: object, **kwargs: object
            ) -> None:
                nonlocal verification_count
                original(*args, **kwargs)
                verification_count += 1
                if verification_count == 1:
                    output_parent.chmod(0o755)

            rename = mock.Mock(side_effect=AssertionError("publication must not start"))
            try:
                with (
                    mock.patch.object(
                        staging,
                        "_verify_staging_directory",
                        weaken_after_first_verification,
                    ),
                    mock.patch.object(staging, "_rename_exclusive", rename),
                    self.assertRaisesRegex(
                        staging.StagingError, "output parent permissions"
                    ),
                ):
                    staging.stage(descriptor, output)
            finally:
                output_parent.chmod(0o700)
            rename.assert_not_called()
            self.assertFalse(output.exists())

    def test_parent_acl_is_rechecked_after_the_durability_barrier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output_parent = base / "output-parent"
            output_parent.mkdir(mode=0o700)
            output = output_parent / "output"

            def add_acl_after_fsync(parent_descriptor: int) -> None:
                os.fsync(parent_descriptor)
                add_extended_acl(output_parent)

            try:
                with (
                    mock.patch.object(staging, "_fsync_parent", add_acl_after_fsync),
                    self.assertRaisesRegex(staging.StagingError, "output parent.*ACL"),
                ):
                    staging.stage(descriptor, output)
            finally:
                subprocess.run(
                    ["/bin/chmod", "-N", str(output_parent)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            self.assertFalse(output.exists())

    def test_clone_fallback_preserves_an_unowned_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source.jpg"
            source.write_bytes(b"source")
            destination = base / "destination"
            destination.mkdir(mode=0o700)
            source_descriptor = os.open(source, os.O_RDONLY)
            destination_descriptor = os.open(destination, os.O_RDONLY)

            class FailingClone:
                argtypes: object = None
                restype: object = None

                def __call__(
                    self,
                    _source_descriptor: int,
                    destination_directory_descriptor: int,
                    destination_name: bytes,
                    _flags: int,
                ) -> int:
                    replacement = os.open(
                        os.fsdecode(destination_name),
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=destination_directory_descriptor,
                    )
                    try:
                        os.write(replacement, b"user replacement")
                    finally:
                        os.close(replacement)
                    ctypes.set_errno(errno.ENOTSUP)
                    return -1

            class FakeLibrary:
                fclonefileat = FailingClone()

            try:
                with (
                    mock.patch.object(
                        staging.ctypes, "CDLL", return_value=FakeLibrary()
                    ),
                    self.assertRaisesRegex(staging.StagingError, "unowned destination"),
                ):
                    staging._clone_or_copy(
                        source_descriptor,
                        destination_descriptor,
                        "staged.jpg",
                    )
            finally:
                os.close(destination_descriptor)
                os.close(source_descriptor)
            self.assertEqual(
                (destination / "staged.jpg").read_bytes(),
                b"user replacement",
            )

    def test_failed_copy_preserves_a_replacement_at_the_destination_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source.jpg"
            source.write_bytes(b"source")
            destination = base / "destination"
            destination.mkdir(mode=0o700)
            destination_path = destination / "staged.jpg"
            source_descriptor = os.open(source, os.O_RDONLY)
            destination_descriptor = os.open(destination, os.O_RDONLY)
            replaced = False

            def replace_and_fail(_descriptor: int, _value: object) -> int:
                nonlocal replaced
                if not replaced:
                    replaced = True
                    destination_path.unlink()
                    destination_path.write_bytes(b"user replacement")
                raise OSError(errno.EIO, "injected copy failure")

            try:
                with (
                    mock.patch.object(staging.os, "write", replace_and_fail),
                    self.assertRaises(OSError),
                ):
                    staging._copy_descriptor(
                        source_descriptor,
                        destination_descriptor,
                        destination_path.name,
                    )
            finally:
                os.close(destination_descriptor)
                os.close(source_descriptor)
            self.assertEqual(destination_path.read_bytes(), b"user replacement")

    def test_cleanup_quarantines_and_rechecks_each_owned_child_before_unlink(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "owned-root"
            root.mkdir(mode=0o700)
            owned_file = root / "owned.jpg"
            owned_file.write_bytes(b"owned")
            owned_file.chmod(0o600)
            root_metadata = root.stat()
            file_metadata = owned_file.stat()
            parent_descriptor = os.open(base, os.O_RDONLY)
            original = staging._rename_no_replace
            raced = False

            def replace_before_child_quarantine(
                source_directory_descriptor: int,
                source_name: str,
                destination_directory_descriptor: int,
                destination_name: str,
            ) -> None:
                nonlocal raced
                if source_name == "owned.jpg" and not raced:
                    raced = True
                    os.rename(
                        source_name,
                        "owned-before-race.jpg",
                        src_dir_fd=source_directory_descriptor,
                        dst_dir_fd=source_directory_descriptor,
                    )
                    replacement = os.open(
                        source_name,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=source_directory_descriptor,
                    )
                    try:
                        os.write(replacement, b"user replacement")
                    finally:
                        os.close(replacement)
                original(
                    source_directory_descriptor,
                    source_name,
                    destination_directory_descriptor,
                    destination_name,
                )

            try:
                with mock.patch.object(
                    staging,
                    "_rename_no_replace",
                    replace_before_child_quarantine,
                ):
                    staging._safe_cleanup_flat_directory(
                        parent_descriptor,
                        root.name,
                        (root_metadata.st_dev, root_metadata.st_ino),
                        {"owned.jpg": (file_metadata.st_dev, file_metadata.st_ino)},
                    )
            finally:
                os.close(parent_descriptor)
            self.assertTrue(raced)
            self.assertEqual((root / "owned.jpg").read_bytes(), b"user replacement")
            self.assertEqual((root / "owned-before-race.jpg").read_bytes(), b"owned")

    def test_final_unlink_helper_refuses_a_replaced_quarantine_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            quarantine = base / "quarantine"
            quarantine.write_bytes(b"owned")
            owned_metadata = quarantine.stat()
            quarantine.unlink()
            quarantine.write_bytes(b"user replacement")
            parent_descriptor = os.open(base, os.O_RDONLY)
            try:
                with self.assertRaisesRegex(staging.StagingError, "identity changed"):
                    staging._unlink_quarantined_name(
                        parent_descriptor,
                        quarantine.name,
                        directory=False,
                        expected_identity=(
                            owned_metadata.st_dev,
                            owned_metadata.st_ino,
                        ),
                    )
            finally:
                os.close(parent_descriptor)
            self.assertEqual(quarantine.read_bytes(), b"user replacement")

    def test_final_publication_rebind_rejects_and_preserves_a_replaced_root(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output = base / "output"
            moved_owned_root = base / "owned-after-race"
            swapped = False

            def replace_after_parent_fsync(parent_descriptor: int) -> None:
                nonlocal swapped
                os.fsync(parent_descriptor)
                if swapped:
                    return
                swapped = True
                output.rename(moved_owned_root)
                output.mkdir(mode=0o700)
                (output / "marker").write_bytes(b"user replacement")

            with (
                mock.patch.object(staging, "_fsync_parent", replace_after_parent_fsync),
                self.assertRaisesRegex(staging.StagingError, "identity changed"),
            ):
                staging.stage(descriptor, output)
            self.assertTrue(swapped)
            self.assertEqual((output / "marker").read_bytes(), b"user replacement")
            self.assertTrue((moved_owned_root / staging.MANIFEST_NAME).is_file())

    def test_final_publication_rebind_rejects_a_replaced_output_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output_parent = base / "output-parent"
            output_parent.mkdir(mode=0o700)
            output = output_parent / "output"
            moved_parent = base / "owned-parent-after-race"
            swapped = False

            def replace_parent_after_fsync(parent_descriptor: int) -> None:
                nonlocal swapped
                os.fsync(parent_descriptor)
                if swapped:
                    return
                swapped = True
                output_parent.rename(moved_parent)
                output_parent.mkdir(mode=0o700)
                (output_parent / "marker").write_bytes(b"user replacement")

            with (
                mock.patch.object(staging, "_fsync_parent", replace_parent_after_fsync),
                self.assertRaisesRegex(
                    staging.StagingError, "output parent identity changed"
                ),
            ):
                staging.stage(descriptor, output)
            self.assertTrue(swapped)
            self.assertEqual(
                (output_parent / "marker").read_bytes(),
                b"user replacement",
            )
            self.assertFalse((moved_parent / "output").exists())

    def test_post_rename_parent_fsync_failure_removes_only_owned_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output = base / "output"

            with (
                mock.patch.object(
                    staging,
                    "_fsync_parent",
                    side_effect=OSError(errno.EIO, "injected fsync failure"),
                ),
                self.assertRaisesRegex(
                    staging.StagingError, "publication could not be committed"
                ),
            ):
                staging.stage(descriptor, output)
            self.assertFalse(output.exists())
            self.assertEqual(
                [
                    path.name
                    for path in base.iterdir()
                    if path.name.startswith(staging.TEMPORARY_PREFIX)
                ],
                [],
            )

    def test_post_rename_failure_preserves_a_replacement_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output = base / "output"
            moved_owned_root = base / "owned-after-fsync-race"

            def replace_and_fail(_parent_descriptor: int) -> None:
                output.rename(moved_owned_root)
                output.mkdir(mode=0o700)
                (output / "marker").write_bytes(b"user replacement")
                raise OSError(errno.EIO, "injected fsync failure")

            with (
                mock.patch.object(staging, "_fsync_parent", replace_and_fail),
                self.assertRaisesRegex(
                    staging.StagingError, "publication could not be committed"
                ),
            ):
                staging.stage(descriptor, output)
            self.assertEqual((output / "marker").read_bytes(), b"user replacement")
            self.assertTrue((moved_owned_root / staging.MANIFEST_NAME).is_file())

    def test_downstream_verify_reopens_and_rehashes_the_exact_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output = base / "output"
            summary = staging.stage(descriptor, output)
            self.assertEqual(staging.verify(output), summary)

            payload = output / "clip.mp4"
            original_mtime = payload.stat().st_mtime_ns
            payload.write_bytes(b"evils")
            os.utime(payload, ns=(original_mtime, original_mtime))
            with self.assertRaisesRegex(staging.StagingError, "staged bytes"):
                staging.verify(output)

    def test_downstream_verify_rejects_manifest_and_membership_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            entries = [
                entry(photo, "photo.jpg", "photo", "photos"),
                entry(video, "clip.mp4", "video", "clip"),
            ]
            write_descriptor(descriptor, entries)

            extra_output = base / "extra-output"
            staging.stage(descriptor, extra_output)
            (extra_output / "unexpected").write_bytes(b"extra")
            with self.assertRaisesRegex(staging.StagingError, "contents"):
                staging.verify(extra_output)

            manifest_output = base / "manifest-output"
            staging.stage(descriptor, manifest_output)
            manifest_path = manifest_output / staging.MANIFEST_NAME
            manifest = json.loads(manifest_path.read_bytes())
            manifest["unexpected"] = True
            manifest_path.write_bytes(canonical_json(manifest))
            manifest_descriptor = os.open(manifest_path, os.O_RDONLY)
            try:
                staging._canonicalize_staged_metadata(manifest_descriptor, 0o600)
            finally:
                os.close(manifest_descriptor)
            with self.assertRaisesRegex(staging.StagingError, "manifest fields"):
                staging.verify(manifest_output)

    def test_downstream_verify_rejects_duplicate_payload_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output = base / "output"
            staging.stage(descriptor, output)
            duplicate_payload = b"same"
            for name in ("clip.mp4", "photo.jpg"):
                payload = output / name
                payload.write_bytes(duplicate_payload)
                payload_descriptor = os.open(payload, os.O_RDONLY)
                try:
                    staging._canonicalize_staged_metadata(payload_descriptor, 0o600)
                finally:
                    os.close(payload_descriptor)

            manifest_path = output / staging.MANIFEST_NAME
            manifest = json.loads(manifest_path.read_bytes())
            for item in manifest["entries"]:
                item["bytes"] = len(duplicate_payload)
                item["sha256"] = digest(duplicate_payload)
            manifest["total_bytes"] = len(duplicate_payload) * 2
            manifest["aggregate_sha256"] = digest(canonical_json(manifest["entries"]))
            manifest_path.write_bytes(canonical_json(manifest))
            manifest_descriptor = os.open(manifest_path, os.O_RDONLY)
            try:
                staging._canonicalize_staged_metadata(manifest_descriptor, 0o600)
            finally:
                os.close(manifest_descriptor)

            with self.assertRaisesRegex(staging.StagingError, "duplicate content"):
                staging.verify(output)

    def test_producer_calls_downstream_verification_before_return(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            original = staging.verify
            invocation_count = 0

            def observe(*args: object, **kwargs: object) -> dict[str, object]:
                nonlocal invocation_count
                invocation_count += 1
                return original(*args, **kwargs)

            with mock.patch.object(staging, "verify", observe):
                staging.stage(descriptor, base / "output")
            self.assertEqual(invocation_count, 1)

    def test_set_wide_rebind_detects_an_earlier_payload_changed_mid_verify(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo.jpg", "photo", "photos"),
                    entry(video, "clip.mp4", "video", "clip"),
                ],
            )
            output = base / "output"
            staging.stage(descriptor, output)
            first_payload = output / "clip.mp4"
            first_inode = first_payload.stat().st_ino
            original = staging._hash_descriptor
            first_hashed = False
            mutated = False

            def mutate_after_later_hash(*args: object, **kwargs: object) -> object:
                nonlocal first_hashed, mutated
                result = original(*args, **kwargs)
                descriptor_fd = args[0]
                inode = os.fstat(descriptor_fd).st_ino
                if first_hashed and inode != first_inode and not mutated:
                    first_payload.write_bytes(b"evils")
                    mutated = True
                elif inode == first_inode:
                    first_hashed = True
                return result

            with (
                mock.patch.object(staging, "_hash_descriptor", mutate_after_later_hash),
                self.assertRaisesRegex(
                    staging.StagingError, "changed during verification"
                ),
            ):
                staging.verify(output)
            self.assertTrue(mutated)

    def test_generation_bound_supports_more_than_two_hundred_photos(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            entries: list[dict[str, object]] = []
            for index in range(205):
                photo = sources / f"photo-{index:03d}.jpg"
                photo.write_bytes(f"photo-{index:03d}".encode("ascii"))
                entries.append(entry(photo, photo.name, "photo", "photos"))
            video = sources / "clip.mp4"
            video.write_bytes(b"video")
            entries.append(entry(video, "clip.mp4", "video", "clip"))
            descriptor = base / "sources.json"
            write_descriptor(descriptor, entries)
            output = base / "output"

            summary = staging.stage(descriptor, output)

            self.assertEqual(summary["entry_count"], 206)
            self.assertEqual(staging.verify(output), summary)

    def test_maximum_generation_raises_the_normal_macos_descriptor_limit(self) -> None:
        soft_limit, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
        if hard_limit < staging.MAXIMUM_ENTRY_COUNT + 128:
            self.skipTest("hard descriptor limit cannot support the staging contract")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            entries: list[dict[str, object]] = []
            for index in range(staging.MAXIMUM_ENTRY_COUNT - 1):
                photo = sources / f"photo-{index:03d}.jpg"
                photo.write_bytes(f"photo-{index:03d}".encode("ascii"))
                entries.append(entry(photo, photo.name, "photo", "photos"))
            video = sources / "clip.mp4"
            video.write_bytes(b"video")
            entries.append(entry(video, "clip.mp4", "video", "clip"))
            descriptor = base / "sources.json"
            write_descriptor(descriptor, entries)
            output = base / "output"

            try:
                resource.setrlimit(resource.RLIMIT_NOFILE, (256, hard_limit))
                summary = staging.stage(descriptor, output)
            finally:
                resource.setrlimit(resource.RLIMIT_NOFILE, (soft_limit, hard_limit))

            self.assertEqual(summary["entry_count"], staging.MAXIMUM_ENTRY_COUNT)
            self.assertEqual(staging.verify(output), summary)

    def test_cli_emits_a_path_free_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            sources = base / "sources"
            sources.mkdir()
            photo = sources / "photo.jpg"
            video = sources / "clip.mp4"
            photo.write_bytes(b"photo")
            video.write_bytes(b"video")
            descriptor = base / "sources.json"
            write_descriptor(
                descriptor,
                [
                    entry(photo, "photo-001.jpg", "photo", "native-photos"),
                    entry(video, "clip-001.mp4", "video", "clip-001"),
                ],
            )
            output = base / "staged"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = staging.main(
                    ["--descriptor", str(descriptor), "--output-root", str(output)]
                )
            self.assertEqual(result, 0)
            summary = json.loads(stdout.getvalue())
            self.assertEqual(summary["schema_version"], 1)
            self.assertEqual(summary["entry_count"], 2)
            self.assertNotIn(str(base), stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
