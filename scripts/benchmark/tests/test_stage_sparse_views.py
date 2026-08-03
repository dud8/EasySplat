"""The sparse staging has to reproduce nerfbaselines' selection exactly, and it has
to round-trip COLMAP's binary image records without disturbing anything the trainer
or a later tool reads.

A selection that is off by one view, or a writer that drops the 2D correspondences,
would both produce a dataset that trains fine and is not the benchmark.
"""

from __future__ import annotations

import importlib.util
import pathlib
import struct
import sys
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "stage_sparse_views.py"
_spec = importlib.util.spec_from_file_location("stage_sparse_views", MODULE_PATH)
stage = importlib.util.module_from_spec(_spec)
sys.modules["stage_sparse_views"] = stage
_spec.loader.exec_module(stage)


def make_image(image_id: int, name: str, points: int = 2) -> stage.ColmapImage:
    blob = b"".join(
        struct.pack("<ddq", float(i), float(i) + 0.5, i) for i in range(points)
    )
    return stage.ColmapImage(
        image_id,
        (0.1 * image_id, 0.2, 0.3, 0.4),
        (1.0 * image_id, 2.0, 3.0),
        7,
        name,
        (points, blob),
    )


class SparseSelectionTests(unittest.TestCase):
    def test_split_matches_the_llff_hold_rule(self):
        names = [f"{i:03d}.jpg" for i in range(40)]
        train, test = stage.sparse_train_names(names, num_views=40)
        self.assertEqual(test, [f"{i:03d}.jpg" for i in range(0, 40, 8)])
        self.assertEqual(len(train) + len(test), 40)
        self.assertFalse(set(train) & set(test))

    def test_selection_spans_the_full_train_range(self):
        """linspace, not a prefix: a sparse set clustered at one end of the
        trajectory would be a different and much easier problem."""
        names = [f"{i:03d}.jpg" for i in range(200)]
        for count in (12, 24):
            train, _ = stage.sparse_train_names(names, num_views=count)
            self.assertEqual(len(train), count)
            full, _ = stage.sparse_train_names(names, num_views=200)
            self.assertEqual(train[0], full[0])
            self.assertEqual(train[-1], full[-1])

    def test_selection_is_sorted_and_unique(self):
        names = [f"{i:03d}.jpg" for i in range(97)]
        train, _ = stage.sparse_train_names(names, num_views=24)
        self.assertEqual(train, sorted(train))
        self.assertEqual(len(set(train)), len(train))

    def test_unsorted_input_selects_the_same_views(self):
        """The trainer sorts by filename before splitting, so a caller passing
        COLMAP's own order must not get a different answer."""
        names = [f"{i:03d}.jpg" for i in range(64)]
        ordered, _ = stage.sparse_train_names(names, num_views=12)
        shuffled, _ = stage.sparse_train_names(list(reversed(names)), num_views=12)
        self.assertEqual(ordered, shuffled)

    def test_asking_for_more_views_than_exist_returns_all(self):
        names = [f"{i:03d}.jpg" for i in range(16)]
        train, _ = stage.sparse_train_names(names, num_views=1000)
        self.assertEqual(len(train), 14)


class ImagesBinRoundTripTests(unittest.TestCase):
    def test_round_trip_preserves_every_field(self):
        images = [make_image(i, f"IMG_{i:04d}.JPG", points=i % 5) for i in range(1, 12)]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "images.bin"
            stage.write_images_bin(path, images)
            restored = stage.read_images_bin(path)

        self.assertEqual(len(restored), len(images))
        for original, copy in zip(images, restored):
            self.assertEqual(copy.image_id, original.image_id)
            self.assertEqual(copy.name, original.name)
            self.assertEqual(copy.camera_id, original.camera_id)
            self.assertEqual(copy.quat, original.quat)
            self.assertEqual(copy.translation, original.translation)
            self.assertEqual(copy.points2d, original.points2d)

    def test_filtering_keeps_the_selected_records_intact(self):
        images = [make_image(i, f"{i:03d}.jpg") for i in range(24)]
        keep = {image.name for image in images[::3]}
        kept = [image for image in images if image.name in keep]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "images.bin"
            stage.write_images_bin(path, kept)
            restored = stage.read_images_bin(path)
        self.assertEqual([i.name for i in restored], [i.name for i in kept])
        self.assertEqual([i.image_id for i in restored], [i.image_id for i in kept])

    def test_empty_point_lists_survive(self):
        """COLMAP images with no registered 2D points are legal and the variable
        length section is where an off-by-one in the reader would show up."""
        images = [make_image(1, "a.jpg", points=0), make_image(2, "b.jpg", points=3)]
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "images.bin"
            stage.write_images_bin(path, images)
            restored = stage.read_images_bin(path)
        self.assertEqual(restored[0].points2d[0], 0)
        self.assertEqual(restored[1].points2d[0], 3)
        self.assertEqual(restored[1].name, "b.jpg")


if __name__ == "__main__":
    unittest.main()
