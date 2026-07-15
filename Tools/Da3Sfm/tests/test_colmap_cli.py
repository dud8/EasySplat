from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from easysplat_da3_sfm import colmap_cli


class _Options:
    def __init__(self) -> None:
        self.sift = types.SimpleNamespace()


class _SolverOptions:
    __slots__ = ("max_num_iterations",)

    def __init__(self) -> None:
        self.max_num_iterations = 100


class _CeresBundleAdjustmentOptions:
    __slots__ = ("use_gpu", "solver_options")

    def __init__(self) -> None:
        self.use_gpu = False
        self.solver_options = _SolverOptions()


class _BundleAdjustmentOptions:
    __slots__ = (
        "refine_focal_length",
        "refine_principal_point",
        "refine_extra_params",
        "ceres",
    )

    def __init__(self) -> None:
        self.refine_focal_length = True
        self.refine_principal_point = False
        self.refine_extra_params = True
        self.ceres = _CeresBundleAdjustmentOptions()


class _IncrementalPipelineOptions:
    __slots__ = (
        "ba_global_frames_ratio",
        "ba_global_points_ratio",
        "ba_global_max_refinements",
        "ba_global_max_num_iterations",
        "random_seed",
        "ba_refine_focal_length",
        "ba_use_gpu",
    )

    def __init__(self) -> None:
        self.ba_global_frames_ratio = 1.1
        self.ba_global_points_ratio = 1.1
        self.ba_global_max_refinements = 5
        self.ba_global_max_num_iterations = 50
        self.random_seed = -1
        self.ba_refine_focal_length = True
        self.ba_use_gpu = False


class _Image:
    def __init__(
        self,
        image_id: int,
        name: str,
        camera_id: int = 1,
    ) -> None:
        self.image_id = image_id
        self.name = name
        self.camera_id = camera_id


class _FeatureDescriptors:
    def __init__(self, feature_type: object, data: np.ndarray) -> None:
        self.feature_type = feature_type
        self.data = np.asarray(data)

    def to_float(self) -> "_FeatureDescriptors":
        return self


class _RetrievalDatabase:
    def __init__(self) -> None:
        self.closed = False
        self.cameras: list[object] = []
        self.images: list[_Image] = []
        self.keypoints: dict[int, np.ndarray] = {}
        self.descriptors: dict[int, np.ndarray] = {}

    def write_camera(self, camera: object, *, use_camera_id: bool) -> None:
        if not use_camera_id:
            raise AssertionError("camera ID must be preserved")
        self.cameras.append(camera)

    def write_image(self, image: _Image, *, use_image_id: bool) -> None:
        if not use_image_id:
            raise AssertionError("image ID must be preserved")
        self.images.append(image)

    def write_keypoints(self, image_id: int, keypoints: np.ndarray) -> None:
        self.keypoints[image_id] = np.asarray(keypoints)

    def write_descriptors(
        self,
        image_id: int,
        descriptors: _FeatureDescriptors,
    ) -> None:
        self.descriptors[image_id] = np.asarray(descriptors.data)

    def close(self) -> None:
        self.closed = True


class _Database:
    def __init__(self) -> None:
        self.images = {
            "later.jpg": _Image(9, "later.jpg"),
            "earlier.jpg": _Image(3, "earlier.jpg"),
        }
        self.closed = False

    def read_image_with_name(self, name: str) -> _Image | None:
        return self.images.get(name)

    def close(self) -> None:
        self.closed = True


class _FeatureDatabase:
    def __init__(
        self,
        image_names: list[str],
        *,
        empty_keypoints: set[str] | None = None,
        empty_descriptors: set[str] | None = None,
    ) -> None:
        self.images = [
            _Image(image_id, name) for image_id, name in enumerate(image_names, start=1)
        ]
        self.empty_keypoints = empty_keypoints or set()
        self.empty_descriptors = empty_descriptors or set()
        self.closed = False

    def read_all_images(self) -> list[_Image]:
        return self.images

    def read_keypoints(self, image_id: int) -> np.ndarray:
        image = self.images[image_id - 1]
        rows = 0 if image.name in self.empty_keypoints else 1
        return np.ones((rows, 4), dtype=np.float32)

    def read_descriptors(self, image_id: int) -> np.ndarray:
        image = self.images[image_id - 1]
        rows = 0 if image.name in self.empty_descriptors else 1
        return np.ones((rows, 128), dtype=np.uint8)

    def close(self) -> None:
        self.closed = True


class ColmapCliTests(unittest.TestCase):
    @staticmethod
    def _runtime_with_required_api() -> types.SimpleNamespace:
        runtime = types.SimpleNamespace(__version__="4.1.0")
        for path in colmap_cli._REQUIRED_PYCOLMAP_API_PATHS:
            parent = runtime
            parts = path.split(".")
            for part in parts[:-1]:
                child = getattr(parent, part, None)
                if child is None:
                    child = types.SimpleNamespace()
                    setattr(parent, part, child)
                parent = child
            setattr(parent, parts[-1], lambda: None)

        def option_factory(fields: tuple[str, ...]) -> object:
            root = types.SimpleNamespace()
            for field in fields:
                parent = root
                parts = field.split(".")
                for part in parts[:-1]:
                    child = getattr(parent, part, None)
                    if child is None:
                        child = types.SimpleNamespace()
                        setattr(parent, part, child)
                    parent = child
                setattr(parent, parts[-1], 0)
            return root

        for constructor_path, fields in colmap_cli._REQUIRED_OPTION_FIELDS.items():
            parent = runtime
            parts = constructor_path.split(".")
            for part in parts[:-1]:
                parent = getattr(parent, part)
            setattr(
                parent,
                parts[-1],
                lambda fields=fields: option_factory(fields),
            )
        runtime.VisualIndex.create = lambda *args: types.SimpleNamespace(
            build=lambda *args: None,
            write=lambda *args: None,
        )
        return runtime

    def _write_retrieval_source(
        self,
        path: Path,
        images: list[_Image],
        *,
        feature_rows: int = 130,
        blank_images: set[str] | None = None,
        shared_descriptors: bool = False,
    ) -> None:
        blank_images = blank_images or set()
        database = sqlite3.connect(path)
        try:
            database.executescript(
                """
                CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE keypoints(
                    image_id INTEGER PRIMARY KEY,
                    rows INTEGER NOT NULL,
                    cols INTEGER NOT NULL,
                    data BLOB
                );
                CREATE TABLE descriptors(
                    image_id INTEGER PRIMARY KEY,
                    rows INTEGER NOT NULL,
                    cols INTEGER NOT NULL,
                    data BLOB
                );
                PRAGMA user_version = 3900;
                """
            )
            for image in images:
                image_feature_rows = 0 if image.name in blank_images else feature_rows
                keypoints = np.asarray(
                    [
                        [0.0, 0.0, float(row + 1), 0.0]
                        for row in range(image_feature_rows)
                    ],
                    dtype=np.float32,
                ).reshape(image_feature_rows, 4)
                if shared_descriptors:
                    rows = np.arange(image_feature_rows, dtype=np.uint16)[:, None]
                    columns = np.arange(128, dtype=np.uint16)[None, :]
                    descriptors = ((rows * 17 + columns * 13) % 256).astype(
                        np.uint8
                    )
                else:
                    descriptors = np.full(
                        (image_feature_rows, 128),
                        image.image_id,
                        dtype=np.uint8,
                    )
                database.execute(
                    "INSERT INTO images(image_id, name) VALUES (?, ?)",
                    (image.image_id, image.name),
                )
                database.execute(
                    "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (?, ?, ?, ?)",
                    (
                        image.image_id,
                        keypoints.shape[0],
                        keypoints.shape[1],
                        keypoints.tobytes(),
                    ),
                )
                database.execute(
                    "INSERT INTO descriptors(image_id, rows, cols, data) VALUES (?, ?, ?, ?)",
                    (
                        image.image_id,
                        descriptors.shape[0],
                        descriptors.shape[1],
                        descriptors.tobytes(),
                    ),
                )
            database.commit()
        finally:
            database.close()

    def _retrieval_pycolmap(
        self,
        database: _RetrievalDatabase,
        *,
        visual_index: object,
        pair_generator: object,
    ) -> object:
        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> _RetrievalDatabase:
                if path != ":memory:":
                    raise AssertionError(f"canonical database was opened by PyCOLMAP: {path}")
                return database

        return types.SimpleNamespace(
            Database=DatabaseFactory,
            Camera=lambda **values: types.SimpleNamespace(**values),
            Image=lambda **values: _Image(
                values["image_id"],
                values["name"],
                values["camera_id"],
            ),
            FeatureDescriptors=_FeatureDescriptors,
            FeatureExtractorType=types.SimpleNamespace(SIFT="sift"),
            VisualIndex=visual_index,
            VocabTreePairingOptions=_Options,
            VocabTreePairGenerator=pair_generator,
        )

    def test_real_pycolmap_local_vocab_retrieval_is_deterministic(self) -> None:
        try:
            import pycolmap
        except ImportError:
            if os.environ.get("EASYSPLAT_REQUIRE_REAL_PYCOLMAP") == "1":
                self.fail("the packaged toolchain is missing PyCOLMAP")
            self.skipTest("real PyCOLMAP is exercised while packaging the toolchain")

        self.assertEqual(pycolmap.__version__, "4.1.0")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "database.db"
            images = [
                _Image(index + 1, f"image_{index:02d}.jpg")
                for index in range(4)
            ]
            self._write_retrieval_source(
                source,
                images,
                feature_rows=32,
                shared_descriptors=True,
            )
            queries = root / "queries.txt"
            queries.write_text("image_00.jpg\n", encoding="utf-8")

            outputs: list[bytes] = []
            for run in range(2):
                output = root / f"pairs_{run}.txt"
                report = colmap_cli.run_command(
                    "local_vocab_retriever",
                    {
                        "database_path": str(source),
                        "output_pair_list_path": str(output),
                        "query_image_list_path": str(queries),
                        "num_images": "3",
                        "returned_neighbor_count": "2",
                        "minimum_frame_separation": "0",
                        "num_visual_words": "8",
                        "max_features_per_image": "32",
                        "max_training_descriptors": "512",
                        "num_iterations": "5",
                        "num_rounds": "1",
                        "num_checks": "8",
                        "num_threads": "2",
                    },
                    pycolmap_module=pycolmap,
                )
                outputs.append(output.read_bytes())
                self.assertEqual(report, "Retrieved image pairs: 2")

            self.assertTrue(outputs[0])
            self.assertEqual(outputs[0], outputs[1])

    def test_real_pycolmap_feature_extraction_uses_reviewed_signature(self) -> None:
        try:
            import pycolmap
            from PIL import Image
        except ImportError:
            if os.environ.get("EASYSPLAT_REQUIRE_REAL_PYCOLMAP") == "1":
                self.fail("the packaged toolchain is missing PyCOLMAP or Pillow")
            self.skipTest("real PyCOLMAP is exercised while packaging the toolchain")

        self.assertEqual(pycolmap.__version__, "4.1.0")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image_path = root / "images"
            image_path.mkdir()
            random = np.random.default_rng(42)
            for index in range(2):
                pixels = random.integers(
                    0,
                    256,
                    size=(256, 256, 3),
                    dtype=np.uint8,
                )
                Image.fromarray(pixels).save(image_path / f"image_{index}.png")

            database_path = root / "database.db"
            colmap_cli.run_command(
                "feature_extractor",
                {
                    "database_path": str(database_path),
                    "image_path": str(image_path),
                    "ImageReader.single_camera": "1",
                    "ImageReader.camera_model": "SIMPLE_RADIAL",
                    "SiftExtraction.max_image_size": "256",
                    "SiftExtraction.max_num_features": "1024",
                    "FeatureExtraction.num_threads": "2",
                },
                pycolmap_module=pycolmap,
            )

            database = pycolmap.Database.open(database_path)
            try:
                images = list(database.read_all_images())
                self.assertEqual(len(images), 2)
                feature_counts = [
                    database.read_keypoints(image.image_id).shape[0]
                    for image in images
                ]
                self.assertTrue(all(count > 0 for count in feature_counts))
            finally:
                database.close()

    def test_local_vocab_retriever_options_are_explicit_and_offline(self) -> None:
        parsed = colmap_cli._parse_options(
            "local_vocab_retriever",
            [
                "--database_path",
                "/tmp/database.db",
                "--output_pair_list_path",
                "/tmp/pairs.txt",
                "--query_image_list_path",
                "/tmp/queries.txt",
                "--excluded_pair_list_path",
                "/tmp/excluded.txt",
                "--num_images",
                "40",
                "--returned_neighbor_count",
                "16",
                "--minimum_frame_separation",
                "25",
                "--num_visual_words",
                "1024",
                "--max_features_per_image",
                "768",
                "--max_training_descriptors",
                "131072",
                "--num_iterations",
                "20",
                "--num_rounds",
                "2",
                "--num_checks",
                "128",
                "--num_threads",
                "8",
            ],
        )

        self.assertEqual(parsed["returned_neighbor_count"], "16")
        self.assertEqual(parsed["minimum_frame_separation"], "25")
        self.assertEqual(parsed["excluded_pair_list_path"], "/tmp/excluded.txt")
        self.assertNotIn("vocab_tree_path", parsed)

        stderr = io.StringIO()
        with (
            mock.patch.object(
                colmap_cli,
                "_load_pycolmap",
                side_effect=AssertionError("invalid options imported pycolmap"),
            ),
            contextlib.redirect_stderr(stderr),
        ):
            result = colmap_cli.main(
                [
                    "local_vocab_retriever",
                    "--database_path",
                    "/tmp/database.db",
                    "--output_pair_list_path",
                    "/tmp/pairs.txt",
                    "--vocab_tree_path",
                    "https://example.invalid/tree.bin",
                ]
            )
        self.assertEqual(result, 2)
        self.assertIn("unrecognized option", stderr.getvalue())

    def test_largest_scale_selection_is_stable_when_scales_tie(self) -> None:
        keypoints = np.asarray(
            [
                [0.0, 0.0, 2.0, 0.0],
                [0.0, 0.0, 3.0, 0.0],
                [0.0, 0.0, 3.0, 0.0],
                [0.0, 0.0, 1.0, 0.0],
            ],
            dtype=np.float32,
        )

        rows = colmap_cli._largest_scale_rows(keypoints, 3)

        np.testing.assert_array_equal(rows, np.asarray([1, 2, 0]))

    def test_in_memory_retrieval_database_is_capped_and_evenly_sampled(self) -> None:
        images = [_Image(20, "z.jpg"), _Image(10, "a.jpg")]
        with tempfile.TemporaryDirectory() as temp_dir:
            source_path = Path(temp_dir) / "database.db"
            self._write_retrieval_source(source_path, images, feature_rows=4)
            source = colmap_cli._readonly_feature_database(source_path)
            retrieval = _RetrievalDatabase()
            try:
                with mock.patch.object(
                    colmap_cli.np,
                    "concatenate",
                    side_effect=AssertionError("training collection exceeded its cap"),
                ):
                    populated_images, training = colmap_cli._populate_retrieval_database(
                        types.SimpleNamespace(
                            Camera=lambda **values: types.SimpleNamespace(**values),
                            Image=lambda **values: _Image(
                                values["image_id"],
                                values["name"],
                                values["camera_id"],
                            ),
                            FeatureDescriptors=_FeatureDescriptors,
                            FeatureExtractorType=types.SimpleNamespace(SIFT="sift"),
                        ),
                        source,
                        retrieval,
                        max_features_per_image=3,
                        max_training_descriptors=4,
                    )
            finally:
                source.close()

        self.assertEqual([image.name for image in populated_images], ["a.jpg", "z.jpg"])
        self.assertEqual(retrieval.keypoints[10].shape, (3, 4))
        self.assertEqual(retrieval.descriptors[20].shape, (3, 128))
        np.testing.assert_array_equal(training[:, 0], np.asarray([10, 10, 20, 20]))

    def test_in_memory_retrieval_database_types_blank_image_features(self) -> None:
        images = [
            _Image(1, "a.jpg"),
            _Image(2, "blank.jpg"),
            _Image(3, "c.jpg"),
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            source_path = Path(temp_dir) / "database.db"
            self._write_retrieval_source(
                source_path,
                images,
                feature_rows=4,
                blank_images={"blank.jpg"},
            )
            source = colmap_cli._readonly_feature_database(source_path)
            retrieval = _RetrievalDatabase()
            try:
                populated_images, training = colmap_cli._populate_retrieval_database(
                    types.SimpleNamespace(
                        Camera=lambda **values: types.SimpleNamespace(**values),
                        Image=lambda **values: _Image(
                            values["image_id"],
                            values["name"],
                            values["camera_id"],
                        ),
                        FeatureDescriptors=_FeatureDescriptors,
                        FeatureExtractorType=types.SimpleNamespace(SIFT="sift"),
                    ),
                    source,
                    retrieval,
                    max_features_per_image=3,
                    max_training_descriptors=6,
                )
            finally:
                source.close()

        self.assertEqual(
            [image.name for image in populated_images],
            ["a.jpg", "blank.jpg", "c.jpg"],
        )
        self.assertEqual(retrieval.keypoints[2].shape, (0, 4))
        self.assertEqual(retrieval.descriptors[2].shape, (0, 128))
        self.assertEqual(training.shape, (6, 128))

    def test_missing_blank_keypoint_row_normalizes_to_colmap_shape(self) -> None:
        image = _Image(2, "blank.jpg")
        with tempfile.TemporaryDirectory() as temp_dir:
            source_path = Path(temp_dir) / "database.db"
            self._write_retrieval_source(
                source_path,
                [image, _Image(3, "usable.jpg")],
                feature_rows=4,
                blank_images={"blank.jpg"},
            )
            with contextlib.closing(sqlite3.connect(source_path)) as database:
                database.execute("DELETE FROM keypoints WHERE image_id = 2")
                database.commit()

            source = colmap_cli._readonly_feature_database(source_path)
            try:
                keypoints, descriptors = colmap_cli._selected_retrieval_features(
                    source,
                    image,
                    descriptor_has_type=False,
                    max_features_per_image=3,
                )
            finally:
                source.close()

        self.assertEqual(keypoints.shape, (0, 4))
        self.assertEqual(descriptors.shape, (0, 128))

    def test_local_vocab_retriever_builds_local_index_and_atomically_writes_pairs(
        self,
    ) -> None:
        images = [
            _Image(4, "d.jpg"),
            _Image(2, "b.jpg"),
            _Image(5, "e.jpg"),
            _Image(1, "a.jpg"),
            _Image(3, "c.jpg"),
        ]

        database = _RetrievalDatabase()
        test_case = self
        build_calls: list[tuple[object, _FeatureDescriptors]] = []
        pairing_calls: list[tuple[object, list[int]]] = []

        class VisualIndex:
            BuildOptions = _Options

            @staticmethod
            def create(descriptor_dimension: int, embedding_dimension: int) -> "VisualIndex":
                self.assertEqual((descriptor_dimension, embedding_dimension), (128, 64))
                return VisualIndex()

            def build(self, options: object, descriptors: _FeatureDescriptors) -> None:
                build_calls.append((options, descriptors))

            def write(self, path: str | Path) -> None:
                Path(path).write_bytes(b"local visual index")

        class PairGenerator:
            def __init__(
                self,
                options: object,
                opened_database: _RetrievalDatabase,
                query_image_ids: list[int],
            ) -> None:
                test_case.assertIs(opened_database, database)
                test_case.assertTrue(Path(options.vocab_tree_path).is_file())
                test_case.assertNotIn("://", str(options.vocab_tree_path))
                pairing_calls.append((options, list(query_image_ids)))

            def all_pairs(self) -> list[tuple[int, int]]:
                return [
                    (4, 4),
                    (4, 1),  # excluded; must not consume a retained slot
                    (4, 2),
                    (4, 5),
                    (1, 1),
                    (1, 5),
                    (1, 4),  # excluded; must not consume a retained slot
                    (1, 3),
                ]

        pycolmap = self._retrieval_pycolmap(
            database,
            visual_index=VisualIndex,
            pair_generator=PairGenerator,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            database_path = root / "database.db"
            self._write_retrieval_source(database_path, images)
            source_bytes = database_path.read_bytes()
            source_stat = database_path.stat()
            queries = root / "queries.txt"
            queries.write_text("d.jpg\na.jpg\n", encoding="utf-8")
            exclusions = root / "excluded.txt"
            exclusions.write_text("a.jpg d.jpg\n", encoding="utf-8")
            output = root / "pairs.txt"
            output.write_text("old output\n", encoding="utf-8")
            real_replace = os.replace
            replacements: list[tuple[Path, Path]] = []

            def replace(source: str | Path, destination: str | Path) -> None:
                replacements.append((Path(source), Path(destination)))
                self.assertEqual(Path(source).parent, output.parent)
                self.assertEqual(Path(destination), output)
                real_replace(source, destination)

            with mock.patch.object(colmap_cli.os, "replace", side_effect=replace):
                report = colmap_cli.run_command(
                    "local_vocab_retriever",
                    {
                        "database_path": str(database_path),
                        "output_pair_list_path": str(output),
                        "query_image_list_path": str(queries),
                        "excluded_pair_list_path": str(exclusions),
                        "num_images": "3",
                        "returned_neighbor_count": "2",
                        "minimum_frame_separation": "1",
                    },
                    pycolmap_module=pycolmap,
                )

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "a.jpg c.jpg\na.jpg e.jpg\nd.jpg b.jpg\nd.jpg e.jpg\n",
            )
            self.assertEqual(len(replacements), 1)
            self.assertEqual(database_path.read_bytes(), source_bytes)
            self.assertEqual(database_path.stat().st_mtime_ns, source_stat.st_mtime_ns)
            with contextlib.closing(sqlite3.connect(database_path)) as source:
                self.assertEqual(source.execute("PRAGMA user_version").fetchone(), (3900,))

        self.assertTrue(database.closed)
        self.assertEqual(report, "Retrieved image pairs: 4")
        self.assertEqual(len(build_calls), 1)
        build_options, training = build_calls[0]
        self.assertEqual(build_options.num_visual_words, 512)
        self.assertEqual(build_options.num_iterations, 10)
        self.assertEqual(build_options.num_rounds, 1)
        self.assertEqual(build_options.num_checks, 64)
        self.assertEqual(build_options.num_threads, -1)
        self.assertEqual(training.feature_type, "sift")
        self.assertEqual(training.data.shape, (650, 128))
        pairing_options, query_ids = pairing_calls[0]
        self.assertEqual(query_ids, [4, 1])
        # Retrieval overfetches the requested candidate pool so excluded and
        # nearby images cannot crowd every useful revisit out of the raw result.
        self.assertEqual(pairing_options.num_images, 5)
        self.assertEqual(pairing_options.num_images_after_verification, 0)
        self.assertEqual(pairing_options.max_num_features, 512)
        self.assertEqual(pairing_options.num_checks, 64)

    def test_local_vocab_retriever_emits_mutual_pair_only_once(self) -> None:
        images = [_Image(1, "a.jpg"), _Image(2, "b.jpg"), _Image(3, "c.jpg")]
        database = _RetrievalDatabase()

        class VisualIndex:
            BuildOptions = _Options

            @staticmethod
            def create(*args: object) -> "VisualIndex":
                return VisualIndex()

            def build(self, *args: object) -> None:
                pass

            def write(self, path: str | Path) -> None:
                Path(path).write_bytes(b"vocab")

        class PairGenerator:
            def __init__(self, *args: object) -> None:
                pass

            def all_pairs(self) -> list[tuple[int, int]]:
                return [(1, 2), (2, 1), (2, 3)]

        pycolmap = self._retrieval_pycolmap(
            database,
            visual_index=VisualIndex,
            pair_generator=PairGenerator,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            database_path = root / "database.db"
            self._write_retrieval_source(database_path, images)
            output = root / "pairs.txt"

            colmap_cli.run_command(
                "local_vocab_retriever",
                {
                    "database_path": str(database_path),
                    "output_pair_list_path": str(output),
                    "num_images": "2",
                    "returned_neighbor_count": "2",
                },
                pycolmap_module=pycolmap,
            )

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "a.jpg b.jpg\nb.jpg c.jpg\n",
            )

    def test_local_vocab_retriever_preserves_old_output_when_retrieval_fails(
        self,
    ) -> None:
        database = _RetrievalDatabase()

        class VisualIndex:
            BuildOptions = _Options

            @staticmethod
            def create(*args: object) -> "VisualIndex":
                return VisualIndex()

            def build(self, *args: object) -> None:
                pass

            def write(self, path: str | Path) -> None:
                Path(path).write_bytes(b"vocab")

        class PairGenerator:
            def __init__(self, *args: object) -> None:
                pass

            def all_pairs(self) -> list[tuple[int, int]]:
                raise RuntimeError("retrieval failed")

        pycolmap = self._retrieval_pycolmap(
            database,
            visual_index=VisualIndex,
            pair_generator=PairGenerator,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            database_path = root / "database.db"
            self._write_retrieval_source(
                database_path,
                [_Image(1, "a.jpg"), _Image(2, "b.jpg")],
                feature_rows=300,
            )
            output = root / "pairs.txt"
            output.write_text("prior\n", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "retrieval failed"):
                colmap_cli.run_command(
                    "local_vocab_retriever",
                    {
                        "database_path": str(database_path),
                        "output_pair_list_path": str(output),
                    },
                    pycolmap_module=pycolmap,
                )

            self.assertEqual(output.read_text(encoding="utf-8"), "prior\n")
            self.assertEqual(
                sorted(path.name for path in root.iterdir()),
                ["database.db", "pairs.txt"],
            )

        self.assertTrue(database.closed)

    def test_local_vocab_retriever_rejects_unsafe_bounds_and_missing_api(self) -> None:
        common = {
            "database_path": "/tmp/database.db",
            "output_pair_list_path": "/tmp/pairs.txt",
        }
        cases = {
            "num_images": ("0", "257"),
            "returned_neighbor_count": ("0", "65"),
            "minimum_frame_separation": ("-1", "1000001"),
            "num_visual_words": ("1", "8193"),
            "max_features_per_image": ("1", "8193"),
            "max_training_descriptors": ("511", "262145"),
            "num_iterations": ("0", "101"),
            "num_rounds": ("0", "4"),
            "num_checks": ("0", "1025"),
            "num_threads": ("0", "-2", "65"),
        }
        pycolmap = types.SimpleNamespace()

        for name, values in cases.items():
            for value in values:
                with (
                    self.subTest(name=name, value=value),
                    self.assertRaisesRegex(colmap_cli.ColmapCliError, name),
                ):
                    colmap_cli.run_command(
                        "local_vocab_retriever",
                        common | {name: value},
                        pycolmap_module=pycolmap,
                    )

        with self.assertRaisesRegex(
            colmap_cli.ColmapCliError,
            "PyCOLMAP VisualIndex and VocabTreePairGenerator APIs are required",
        ):
            colmap_cli.run_command(
                "local_vocab_retriever",
                common,
                pycolmap_module=types.SimpleNamespace(Database=object()),
            )

    def test_local_vocab_retriever_rejects_pending_wal_and_unknown_exclusion(
        self,
    ) -> None:
        class NeverVisualIndex:
            BuildOptions = _Options

            @staticmethod
            def create(*args: object) -> object:
                raise AssertionError("invalid input reached vocabulary construction")

        database = _RetrievalDatabase()
        pycolmap = self._retrieval_pycolmap(
            database,
            visual_index=NeverVisualIndex,
            pair_generator=object,
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            database_path = root / "database.db"
            self._write_retrieval_source(
                database_path,
                [_Image(1, "a.jpg"), _Image(2, "b.jpg")],
            )
            output = root / "pairs.txt"
            output.write_text("prior\n", encoding="utf-8")
            wal = Path(f"{database_path}-wal")
            wal.write_bytes(b"pending")

            with self.assertRaisesRegex(colmap_cli.ColmapCliError, "pending SQLite wal"):
                colmap_cli.run_command(
                    "local_vocab_retriever",
                    {
                        "database_path": str(database_path),
                        "output_pair_list_path": str(output),
                    },
                    pycolmap_module=pycolmap,
                )
            self.assertEqual(output.read_text(encoding="utf-8"), "prior\n")

            wal.unlink()
            exclusions = root / "excluded.txt"
            exclusions.write_text("a.jpg missing.jpg\n", encoding="utf-8")
            with self.assertRaisesRegex(colmap_cli.ColmapCliError, "absent from the database"):
                colmap_cli.run_command(
                    "local_vocab_retriever",
                    {
                        "database_path": str(database_path),
                        "output_pair_list_path": str(output),
                        "excluded_pair_list_path": str(exclusions),
                    },
                    pycolmap_module=pycolmap,
                )
            self.assertEqual(output.read_text(encoding="utf-8"), "prior\n")

    def test_runtime_requires_reviewed_pycolmap_release(self) -> None:
        reviewed = types.SimpleNamespace(__version__="4.1.0")
        with mock.patch.dict(sys.modules, {"pycolmap": reviewed}):
            self.assertIs(colmap_cli._load_pycolmap(), reviewed)

        stale = types.SimpleNamespace(__version__="3.13.0")
        with (
            mock.patch.dict(sys.modules, {"pycolmap": stale}),
            self.assertRaisesRegex(colmap_cli.ColmapCliError, "4.1.0 is required"),
        ):
            colmap_cli._load_pycolmap()

    def test_help_probes_do_not_import_pycolmap(self) -> None:
        for argv in (["-h"], ["--help"], ["mapper", "-h"]):
            stdout = io.StringIO()
            with (
                mock.patch.object(
                    colmap_cli,
                    "_load_pycolmap",
                    side_effect=AssertionError("help imported pycolmap"),
                ),
                contextlib.redirect_stdout(stdout),
            ):
                self.assertEqual(colmap_cli.main(argv), 0)
            self.assertIn("pycolmap", stdout.getvalue())

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(colmap_cli.main(["--help"]), 0)
        self.assertNotIn("global_mapper", stdout.getvalue())

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(colmap_cli.main(["global_mapper"]), 2)
        self.assertIn("unrecognized command", stderr.getvalue())

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(colmap_cli.main(["feature_importer", "--help"]), 0)
        self.assertIn("not supported", stdout.getvalue())

    def test_runtime_self_check_imports_pycolmap_and_reports_reviewed_contract(self) -> None:
        runtime = self._runtime_with_required_api()
        stdout = io.StringIO()
        with (
            mock.patch.object(colmap_cli, "_load_pycolmap", return_value=runtime),
            contextlib.redirect_stdout(stdout),
        ):
            self.assertEqual(colmap_cli.main(["--self-check"]), 0)

        self.assertEqual(
            json.loads(stdout.getvalue()),
            {
                "runtime": "pycolmap",
                "runtime_version": "4.1.0",
                "schema_version": 1,
                "status": "ok",
            },
        )

    def test_runtime_self_check_rejects_missing_production_api(self) -> None:
        runtime = self._runtime_with_required_api()
        del runtime.VisualIndex
        stderr = io.StringIO()
        with (
            mock.patch.object(colmap_cli, "_load_pycolmap", return_value=runtime),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(colmap_cli.main(["--self-check"]), 2)
        self.assertIn("VisualIndex", stderr.getvalue())

    def test_runtime_self_check_rejects_missing_option_field(self) -> None:
        runtime = self._runtime_with_required_api()
        options = runtime.IncrementalPipelineOptions()
        del options.ba_global_frames_ratio
        runtime.IncrementalPipelineOptions = lambda: options
        stderr = io.StringIO()
        with (
            mock.patch.object(colmap_cli, "_load_pycolmap", return_value=runtime),
            contextlib.redirect_stderr(stderr),
        ):
            self.assertEqual(colmap_cli.main(["--self-check"]), 2)
        self.assertIn(
            "IncrementalPipelineOptions.ba_global_frames_ratio",
            stderr.getvalue(),
        )

    def test_feature_extractor_translates_flags_and_validates_complete_output(
        self,
    ) -> None:
        calls: list[tuple[tuple[object, ...], dict[str, object]]] = []
        database = _FeatureDatabase(["first.jpg", "nested/second.PNG"])

        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> _FeatureDatabase:
                self.assertEqual(path, "/tmp/database.db")
                return database

        with tempfile.TemporaryDirectory() as temp_dir:
            image_path = Path(temp_dir) / "images"
            (image_path / "nested").mkdir(parents=True)
            (image_path / "first.jpg").touch()
            (image_path / "nested/second.PNG").touch()
            (image_path / "notes.txt").touch()
            (image_path / "album.jpg").mkdir()
            (image_path / "linked.jpg").symlink_to(image_path / "first.jpg")
            pycolmap = types.SimpleNamespace(
                Device=types.SimpleNamespace(cpu="cpu"),
                CameraMode=types.SimpleNamespace(SINGLE="single", AUTO="auto"),
                ImageReaderOptions=_Options,
                FeatureExtractionOptions=_Options,
                Database=DatabaseFactory,
                extract_features=lambda *args, **kwargs: calls.append((args, kwargs)),
            )

            colmap_cli.run_command(
                "feature_extractor",
                {
                    "database_path": "/tmp/database.db",
                    "image_path": str(image_path),
                    "ImageReader.single_camera": "1",
                    "ImageReader.camera_model": "PINHOLE",
                    "SiftExtraction.max_image_size": "1600",
                    "SiftExtraction.max_num_features": "4096",
                    "FeatureExtraction.use_gpu": "1",
                    "FeatureExtraction.num_threads": "4",
                },
                pycolmap_module=pycolmap,
            )

        self.assertEqual(len(calls), 1)
        _, kwargs = calls[0]
        self.assertEqual(kwargs["database_path"], "/tmp/database.db")
        self.assertEqual(kwargs["image_path"], str(image_path))
        self.assertEqual(kwargs["camera_mode"], "single")
        self.assertNotIn("camera_model", kwargs)
        self.assertEqual(kwargs["device"], "cpu")
        self.assertEqual(kwargs["reader_options"].camera_model, "PINHOLE")
        extraction = kwargs["extraction_options"]
        self.assertFalse(extraction.use_gpu)
        self.assertEqual(extraction.max_image_size, 1600)
        self.assertEqual(extraction.num_threads, 4)
        self.assertEqual(extraction.sift.max_num_features, 4096)
        self.assertTrue(database.closed)

    def test_feature_descriptor_wrapper_reports_its_matrix_rows(self) -> None:
        descriptors = _FeatureDescriptors(
            "sift",
            np.ones((3, 128), dtype=np.uint8),
        )

        self.assertEqual(colmap_cli._matrix_rows(descriptors), 3)

    def test_feature_extractor_rejects_missing_or_mismatched_database_results(self) -> None:
        cases = {
            "missing": _FeatureDatabase(["first.jpg"]),
            "empty": _FeatureDatabase(
                ["first.jpg", "nested/second.png"],
                empty_descriptors={"nested/second.png"},
            ),
        }
        for failure, database in cases.items():
            with (
                self.subTest(failure=failure),
                tempfile.TemporaryDirectory() as temp_dir,
            ):
                image_path = Path(temp_dir) / "images"
                (image_path / "nested").mkdir(parents=True)
                (image_path / "first.jpg").touch()
                (image_path / "nested/second.png").touch()

                class DatabaseFactory:
                    @staticmethod
                    def open(path: str) -> _FeatureDatabase:
                        return database

                pycolmap = types.SimpleNamespace(
                    Device=types.SimpleNamespace(cpu="cpu"),
                    CameraMode=types.SimpleNamespace(SINGLE="single", AUTO="auto"),
                    ImageReaderOptions=_Options,
                    FeatureExtractionOptions=_Options,
                    Database=DatabaseFactory,
                    extract_features=lambda *args, **kwargs: None,
                )
                with self.assertRaisesRegex(
                    colmap_cli.ColmapCliError,
                    r"2 input images.*nested/second\.png",
                ):
                    colmap_cli.run_command(
                        "feature_extractor",
                        {
                            "database_path": "/tmp/database.db",
                            "image_path": str(image_path),
                        },
                        pycolmap_module=pycolmap,
                    )
                self.assertTrue(database.closed)

    def test_feature_extractor_allows_blank_frames_when_two_views_have_features(
        self,
    ) -> None:
        database = _FeatureDatabase(
            ["first.jpg", "blank.jpg", "third.jpg"],
            empty_keypoints={"blank.jpg"},
            empty_descriptors={"blank.jpg"},
        )

        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> _FeatureDatabase:
                return database

        with tempfile.TemporaryDirectory() as temp_dir:
            image_path = Path(temp_dir) / "images"
            image_path.mkdir()
            for name in ("first.jpg", "blank.jpg", "third.jpg"):
                (image_path / name).touch()
            pycolmap = types.SimpleNamespace(
                Device=types.SimpleNamespace(cpu="cpu"),
                CameraMode=types.SimpleNamespace(SINGLE="single", AUTO="auto"),
                ImageReaderOptions=_Options,
                FeatureExtractionOptions=_Options,
                Database=DatabaseFactory,
                extract_features=lambda *args, **kwargs: None,
            )

            colmap_cli.run_command(
                "feature_extractor",
                {
                    "database_path": "/tmp/database.db",
                    "image_path": str(image_path),
                },
                pycolmap_module=pycolmap,
            )

        self.assertTrue(database.closed)

    def test_feature_extractor_requires_two_usable_views(self) -> None:
        names = ["usable.jpg", "blank-a.jpg", "blank-b.jpg"]
        blank = {"blank-a.jpg", "blank-b.jpg"}
        database = _FeatureDatabase(
            names,
            empty_keypoints=blank,
            empty_descriptors=blank,
        )

        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> _FeatureDatabase:
                return database

        with tempfile.TemporaryDirectory() as temp_dir:
            image_path = Path(temp_dir) / "images"
            image_path.mkdir()
            for name in names:
                (image_path / name).touch()
            pycolmap = types.SimpleNamespace(
                Device=types.SimpleNamespace(cpu="cpu"),
                CameraMode=types.SimpleNamespace(SINGLE="single", AUTO="auto"),
                ImageReaderOptions=_Options,
                FeatureExtractionOptions=_Options,
                Database=DatabaseFactory,
                extract_features=lambda *args, **kwargs: None,
            )

            with self.assertRaisesRegex(
                colmap_cli.ColmapCliError,
                "fewer than two images with usable features",
            ):
                colmap_cli.run_command(
                    "feature_extractor",
                    {
                        "database_path": "/tmp/database.db",
                        "image_path": str(image_path),
                    },
                    pycolmap_module=pycolmap,
                )

        self.assertTrue(database.closed)

    def test_matches_importer_delegates_pair_schedule_and_matcher_mode_to_colmap(
        self,
    ) -> None:
        for brute_force in ("0", "1"):
            with self.subTest(brute_force=brute_force):
                database = _Database()
                calls: list[dict[str, object]] = []

                class DatabaseFactory:
                    @staticmethod
                    def open(path: str) -> _Database:
                        self.assertEqual(path, "/tmp/database.db")
                        return database

                pycolmap = types.SimpleNamespace(
                    Device=types.SimpleNamespace(cpu="cpu"),
                    Database=DatabaseFactory,
                    FeatureMatchingOptions=_Options,
                    ImportedPairingOptions=_Options,
                    TwoViewGeometryOptions=_Options,
                    match_image_pairs=lambda *args, **kwargs: calls.append(kwargs),
                )
                with tempfile.TemporaryDirectory() as temp_dir:
                    pairs = Path(temp_dir) / "pairs.txt"
                    pairs.write_text("later.jpg earlier.jpg\n", encoding="utf-8")
                    colmap_cli.run_command(
                        "matches_importer",
                        {
                            "database_path": "/tmp/database.db",
                            "match_list_path": str(pairs),
                            "match_type": "pairs",
                            "FeatureMatching.max_num_matches": "64",
                            "FeatureMatching.num_threads": "2",
                            "FeatureMatching.use_gpu": "0",
                            "SiftMatching.cpu_brute_force_matcher": brute_force,
                        },
                        pycolmap_module=pycolmap,
                    )

                self.assertTrue(database.closed)
                self.assertEqual(len(calls), 1)
                call = calls[0]
                self.assertEqual(call["database_path"], "/tmp/database.db")
                self.assertEqual(call["device"], "cpu")
                self.assertEqual(call["pairing_options"].match_list_path, str(pairs))
                self.assertEqual(call["matching_options"].num_threads, 2)
                self.assertEqual(call["matching_options"].max_num_matches, 64)
                self.assertEqual(
                    call["matching_options"].sift.cpu_brute_force_matcher,
                    brute_force == "1",
                )

    def test_model_analyzer_rejects_nonfinite_residuals_with_observations(self) -> None:
        class Reconstruction:
            def read(self, path: str) -> None:
                self.path = path

            def num_cameras(self) -> int:
                return 1

            def num_images(self) -> int:
                return 1

            def num_reg_images(self) -> int:
                return 1

            def num_points3D(self) -> int:
                return 1

            def compute_num_observations(self) -> int:
                return 2

            def compute_mean_track_length(self) -> float:
                return 2.0

            def compute_mean_reprojection_error(self) -> float:
                return float("nan")

        pycolmap = types.SimpleNamespace(Reconstruction=Reconstruction)

        with self.assertRaisesRegex(colmap_cli.ColmapCliError, "non-finite"):
            colmap_cli.run_command(
                "model_analyzer",
                {"path": "/tmp/sparse"},
                pycolmap_module=pycolmap,
            )

    def test_matches_importer_rejects_bad_pair_files_before_verification(self) -> None:
        database = _Database()

        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> _Database:
                return database

        pycolmap = types.SimpleNamespace(
            Database=DatabaseFactory,
            FeatureMatchingOptions=_Options,
            TwoViewGeometryOptions=_Options,
            verify_matches=mock.Mock(),
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            pairs = Path(temp_dir) / "pairs.txt"
            pairs.write_text("later.jpg missing.jpg\n", encoding="utf-8")
            with self.assertRaisesRegex(colmap_cli.ColmapCliError, "missing.jpg"):
                colmap_cli.run_command(
                    "matches_importer",
                    {
                        "database_path": "/tmp/database.db",
                        "match_list_path": str(pairs),
                        "match_type": "pairs",
                    },
                    pycolmap_module=pycolmap,
                )
        self.assertTrue(database.closed)
        pycolmap.verify_matches.assert_not_called()

    def test_mapper_propagates_bounded_refinement_options_on_cpu(self) -> None:
        calls: list[dict[str, object]] = []
        pycolmap = types.SimpleNamespace(
            IncrementalPipelineOptions=_IncrementalPipelineOptions,
            incremental_mapping=lambda **kwargs: calls.append(kwargs) or {},
        )
        common = {
            "database_path": "/tmp/database.db",
            "image_path": "/tmp/images",
            "output_path": "/tmp/sparse",
        }

        colmap_cli.run_command(
            "mapper",
            common
            | {
                "Mapper.ba_global_frames_ratio": "1.4",
                "Mapper.ba_global_points_ratio": "1.25",
                "Mapper.ba_global_max_refinements": "4",
                "Mapper.ba_global_max_num_iterations": "17",
                "Mapper.random_seed": "42",
                "Mapper.ba_refine_focal_length": "0",
            },
            pycolmap_module=pycolmap,
        )
        self.assertEqual(len(calls), 1)
        mapper = calls[0]["options"]
        self.assertEqual(mapper.ba_global_frames_ratio, 1.4)
        self.assertEqual(mapper.ba_global_points_ratio, 1.25)
        self.assertEqual(mapper.ba_global_max_refinements, 4)
        self.assertEqual(mapper.ba_global_max_num_iterations, 17)
        self.assertEqual(mapper.random_seed, 42)
        self.assertFalse(mapper.ba_refine_focal_length)
        self.assertFalse(mapper.ba_use_gpu)

    def test_mapper_help_exposes_supported_refinement_controls(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(colmap_cli.main(["mapper", "--help"]), 0)

        help_text = stdout.getvalue()
        for name in (
            "Mapper.ba_global_frames_ratio",
            "Mapper.ba_global_points_ratio",
            "Mapper.ba_global_max_refinements",
            "Mapper.ba_global_max_num_iterations",
            "Mapper.random_seed",
            "Mapper.ba_refine_focal_length",
        ):
            with self.subTest(name=name):
                self.assertIn(f"--{name} <value>", help_text)

    def test_mapper_uses_deterministic_defaults(self) -> None:
        calls: list[dict[str, object]] = []
        pycolmap = types.SimpleNamespace(
            IncrementalPipelineOptions=_IncrementalPipelineOptions,
            incremental_mapping=lambda **kwargs: calls.append(kwargs) or {},
        )

        colmap_cli.run_command(
            "mapper",
            {
                "database_path": "/tmp/database.db",
                "image_path": "/tmp/images",
                "output_path": "/tmp/sparse",
            },
            pycolmap_module=pycolmap,
        )

        options = calls[0]["options"]
        self.assertEqual(options.ba_global_frames_ratio, 1.1)
        self.assertEqual(options.ba_global_points_ratio, 1.1)
        self.assertEqual(options.ba_global_max_refinements, 5)
        self.assertEqual(options.ba_global_max_num_iterations, 50)
        self.assertEqual(options.random_seed, 42)
        self.assertTrue(options.ba_refine_focal_length)

    def test_mapper_rejects_unsafe_refinement_options(self) -> None:
        pycolmap = types.SimpleNamespace(
            IncrementalPipelineOptions=_IncrementalPipelineOptions,
            incremental_mapping=mock.Mock(),
        )
        common = {
            "database_path": "/tmp/database.db",
            "image_path": "/tmp/images",
            "output_path": "/tmp/sparse",
        }
        cases = {
            "Mapper.ba_global_frames_ratio": ("1", "nan", "inf", "-inf"),
            "Mapper.ba_global_points_ratio": ("0.99", "nan", "infinity"),
            "Mapper.ba_global_max_refinements": ("0", "-1", "1.5"),
            "Mapper.ba_global_max_num_iterations": ("0", "-1", "1.5"),
            "Mapper.random_seed": ("-1", "2147483648", "1.5"),
            "Mapper.ba_refine_focal_length": ("true", "false", "2"),
        }

        for name, values in cases.items():
            for value in values:
                with (
                    self.subTest(name=name, value=value),
                    self.assertRaisesRegex(colmap_cli.ColmapCliError, name),
                ):
                    colmap_cli.run_command(
                        "mapper",
                        common | {name: value},
                        pycolmap_module=pycolmap,
                    )

        pycolmap.incremental_mapping.assert_not_called()

    def test_triangulator_bundle_adjuster_converter_and_analyzer_round_trip(
        self,
    ) -> None:
        reconstructions: list[FakeReconstruction] = []
        triangulate_calls: list[dict[str, object]] = []
        adjustment_calls: list[tuple[FakeReconstruction, object]] = []

        class FakeReconstruction:
            def __init__(self) -> None:
                self.read_path: str | None = None
                self.writes: list[tuple[str, str]] = []
                self.points3D = {
                    **{
                        point_id: types.SimpleNamespace(error=0.5 + point_id * 0.01)
                        for point_id in range(1, 12)
                    },
                    99: types.SimpleNamespace(error=1e154),
                }
                self.updated_point_errors = 0
                self.deleted_point_ids: list[int] = []
                reconstructions.append(self)

            def read(self, path: str) -> None:
                self.read_path = path

            def write(self, path: str) -> None:
                self.writes.append(("BIN", path))

            def write_text(self, path: str) -> None:
                self.writes.append(("TXT", path))

            def update_point_3d_errors(self) -> None:
                self.updated_point_errors += 1

            def delete_point3D(self, point_id: int) -> None:
                self.deleted_point_ids.append(point_id)
                del self.points3D[point_id]

            def num_cameras(self) -> int:
                return 2

            def num_images(self) -> int:
                return 8

            def num_reg_images(self) -> int:
                return 7

            def num_points3D(self) -> int:
                return 10

            def compute_num_observations(self) -> int:
                return 24

            def compute_mean_track_length(self) -> float:
                return 2.4

            def compute_mean_reprojection_error(self) -> float:
                return 0.75

        pycolmap = types.SimpleNamespace(
            Reconstruction=FakeReconstruction,
            IncrementalPipelineOptions=_Options,
            BundleAdjustmentOptions=_BundleAdjustmentOptions,
            triangulate_points=lambda *args, **kwargs: triangulate_calls.append(kwargs),
            bundle_adjustment=lambda reconstruction, options: adjustment_calls.append(
                (reconstruction, options)
            ),
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            colmap_cli.run_command(
                "point_triangulator",
                {
                    "database_path": str(root / "database.db"),
                    "image_path": str(root / "images"),
                    "input_path": str(root / "seed"),
                    "output_path": str(root / "triangulated"),
                },
                pycolmap_module=pycolmap,
            )
            colmap_cli.run_command(
                "bundle_adjuster",
                {
                    "input_path": str(root / "triangulated"),
                    "output_path": str(root / "adjusted"),
                    "BundleAdjustment.refine_focal_length": "0",
                    "BundleAdjustment.refine_principal_point": "1",
                    "BundleAdjustment.refine_extra_params": "0",
                    "BundleAdjustmentCeres.max_num_iterations": "31",
                },
                pycolmap_module=pycolmap,
            )
            report = colmap_cli.run_command(
                "model_analyzer",
                {"path": str(root / "adjusted")},
                pycolmap_module=pycolmap,
            )
            colmap_cli.run_command(
                "model_converter",
                {
                    "input_path": str(root / "adjusted"),
                    "output_path": str(root / "text"),
                    "output_type": "TXT",
                },
                pycolmap_module=pycolmap,
            )

        self.assertEqual(triangulate_calls[0]["clear_points"], True)
        self.assertEqual(triangulate_calls[0]["refine_intrinsics"], False)
        adjustment = adjustment_calls[0][1]
        self.assertFalse(adjustment.refine_focal_length)
        self.assertTrue(adjustment.refine_principal_point)
        self.assertFalse(adjustment.refine_extra_params)
        self.assertFalse(adjustment.ceres.use_gpu)
        self.assertEqual(adjustment.ceres.solver_options.max_num_iterations, 31)
        adjusted = adjustment_calls[0][0]
        self.assertEqual(adjusted.updated_point_errors, 2)
        self.assertEqual(adjusted.deleted_point_ids, [99])
        self.assertEqual(adjusted.writes, [("BIN", str(root / "adjusted"))])
        self.assertIn("Registered images: 7 / 8", report)
        self.assertIn("Points: 10", report)
        self.assertIn("Observations: 24", report)
        self.assertIn("Mean track length: 2.4", report)
        self.assertIn("Mean reprojection error: 0.75", report)
        self.assertEqual(reconstructions[-1].writes, [("TXT", str(root / "text"))])

    def test_image_undistorter_uses_copy_and_requested_size(self) -> None:
        calls: list[dict[str, object]] = []
        pycolmap = types.SimpleNamespace(
            FileCopyType=types.SimpleNamespace(copy="copy"),
            UndistortCameraOptions=_Options,
            undistort_images=lambda **kwargs: calls.append(kwargs),
        )

        colmap_cli.run_command(
            "image_undistorter",
            {
                "image_path": "/tmp/images",
                "input_path": "/tmp/sparse/0",
                "output_path": "/tmp/dataset",
                "output_type": "COLMAP",
                "copy_policy": "COPY",
                "max_image_size": "2048",
            },
            pycolmap_module=pycolmap,
        )

        self.assertEqual(calls[0]["copy_policy"], "copy")
        self.assertEqual(calls[0]["undistort_options"].max_image_size, 2048)

    def test_feature_importer_fails_with_a_specific_message(self) -> None:
        with self.assertRaisesRegex(
            colmap_cli.ColmapCliError, "feature_importer is not supported"
        ):
            colmap_cli.run_command("feature_importer", {}, pycolmap_module=object())

    def test_cli_rejects_unknown_options_without_loading_pycolmap(self) -> None:
        stderr = io.StringIO()
        with (
            mock.patch.object(
                colmap_cli,
                "_load_pycolmap",
                side_effect=AssertionError("invalid options imported pycolmap"),
            ),
            contextlib.redirect_stderr(stderr),
        ):
            result = colmap_cli.main(
                [
                    "model_analyzer",
                    "--path",
                    "/tmp/sparse",
                    "--invented",
                    "1",
                ]
            )
        self.assertEqual(result, 2)
        self.assertIn("unrecognized option", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
