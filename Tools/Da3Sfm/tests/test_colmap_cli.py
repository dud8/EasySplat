from __future__ import annotations

import contextlib
import io
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
        self.solver_options = types.SimpleNamespace()


class _Image:
    def __init__(self, image_id: int, name: str) -> None:
        self.image_id = image_id
        self.name = name


class _Database:
    def __init__(self) -> None:
        self.images = {
            "later.jpg": _Image(9, "later.jpg"),
            "earlier.jpg": _Image(3, "earlier.jpg"),
        }
        self.descriptors = {
            9: np.array([[1, 0], [0, 1]], dtype=np.uint8),
            3: np.array([[1, 0], [1, 1]], dtype=np.uint8),
        }
        self.writes: list[tuple[int, int, np.ndarray]] = []
        self.closed = False

    def read_image_with_name(self, name: str) -> _Image | None:
        return self.images.get(name)

    def read_descriptors(self, image_id: int) -> np.ndarray:
        return self.descriptors[image_id]

    def write_matches(
        self, image_id1: int, image_id2: int, matches: np.ndarray
    ) -> None:
        self.writes.append((image_id1, image_id2, matches.copy()))

    def exists_matches(self, image_id1: int, image_id2: int) -> bool:
        return False

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


def _reference_match_descriptors(
    descriptors1: np.ndarray,
    descriptors2: np.ndarray,
    *,
    max_ratio: float,
    max_distance: float,
    cross_check: bool,
    max_num_matches: int,
) -> np.ndarray:
    first = colmap_cli._normalized_descriptors(descriptors1)
    second = colmap_cli._normalized_descriptors(descriptors2)

    def ratio_matches(
        queries: np.ndarray, candidates: np.ndarray
    ) -> dict[int, tuple[int, float]]:
        if queries.shape[0] == 0 or candidates.shape[0] < 2:
            return {}
        distances = np.linalg.norm(
            queries[:, np.newaxis, :] - candidates[np.newaxis, :, :], axis=2
        )
        accepted: dict[int, tuple[int, float]] = {}
        candidate_indices = np.arange(candidates.shape[0])
        for query_index, row in enumerate(distances):
            order = np.lexsort((candidate_indices, row))
            best, runner_up = order[:2]
            if row[best] > max_distance or row[best] >= max_ratio * row[runner_up]:
                continue
            accepted[query_index] = (int(best), float(row[best]))
        return accepted

    forward = ratio_matches(first, second)
    reverse = ratio_matches(second, first) if cross_check else {}
    matches = [
        (query, train, distance)
        for query, (train, distance) in forward.items()
        if not cross_check or reverse.get(train, (-1, 0.0))[0] == query
    ]
    matches.sort(key=lambda match: (match[2], match[0], match[1]))
    if not matches:
        return np.empty((0, 2), dtype=np.uint32)
    return np.asarray(
        [(query, train) for query, train, _ in matches[:max_num_matches]],
        dtype=np.uint32,
    )


class ColmapCliTests(unittest.TestCase):
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
        self.assertEqual(kwargs["camera_model"], "PINHOLE")
        self.assertEqual(kwargs["device"], "cpu")
        self.assertEqual(kwargs["reader_options"].camera_model, "PINHOLE")
        extraction = kwargs["extraction_options"]
        self.assertFalse(extraction.use_gpu)
        self.assertEqual(extraction.max_image_size, 1600)
        self.assertEqual(extraction.num_threads, 4)
        self.assertEqual(extraction.sift.max_num_features, 4096)
        self.assertTrue(database.closed)

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

    def test_matches_importer_matches_only_listed_pairs_and_preserves_indices(
        self,
    ) -> None:
        database = _Database()
        verify_calls: list[tuple[str, str]] = []

        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> _Database:
                self.assertEqual(path, "/tmp/database.db")
                return database

        pycolmap = types.SimpleNamespace(
            Database=DatabaseFactory,
            FeatureMatchingOptions=_Options,
            TwoViewGeometryOptions=_Options,
            verify_matches=lambda database_path, pairs_path, options: (
                verify_calls.append((database_path, pairs_path))
            ),
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
                    "SiftMatching.cpu_brute_force_matcher": "1",
                },
                pycolmap_module=pycolmap,
            )

        self.assertTrue(database.closed)
        self.assertEqual(verify_calls, [("/tmp/database.db", str(pairs))])
        self.assertEqual(len(database.writes), 1)
        image_id1, image_id2, matches = database.writes[0]
        self.assertEqual((image_id1, image_id2), (3, 9))
        np.testing.assert_array_equal(matches, np.array([[0, 0]], dtype=np.uint32))

    def test_matches_importer_preserves_existing_pairs_and_matches_only_missing_pairs(
        self,
    ) -> None:
        class MixedDatabase(_Database):
            def __init__(self) -> None:
                super().__init__()
                self.images["new.jpg"] = _Image(5, "new.jpg")
                self.descriptors[5] = np.array([[1, 0], [1, 1]], dtype=np.uint8)
                self.exists_calls: list[tuple[int, int]] = []
                self.descriptor_reads: list[int] = []

            def exists_matches(self, image_id1: int, image_id2: int) -> bool:
                self.exists_calls.append((image_id1, image_id2))
                return (image_id1, image_id2) == (3, 9)

            def read_descriptors(self, image_id: int) -> np.ndarray:
                self.descriptor_reads.append(image_id)
                return super().read_descriptors(image_id)

        database = MixedDatabase()
        verify_calls: list[tuple[str, str]] = []

        class DatabaseFactory:
            @staticmethod
            def open(path: str) -> MixedDatabase:
                self.assertEqual(path, "/tmp/database.db")
                return database

        pycolmap = types.SimpleNamespace(
            Database=DatabaseFactory,
            FeatureMatchingOptions=_Options,
            TwoViewGeometryOptions=_Options,
            verify_matches=lambda database_path, pairs_path, options: (
                verify_calls.append((database_path, pairs_path))
            ),
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            pairs = Path(temp_dir) / "pairs.txt"
            pairs.write_text(
                "later.jpg earlier.jpg\nlater.jpg new.jpg\n",
                encoding="utf-8",
            )
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
        self.assertEqual(database.exists_calls, [(3, 9), (5, 9)])
        self.assertEqual(database.descriptor_reads, [9, 5])
        self.assertEqual(len(database.writes), 1)
        image_id1, image_id2, matches = database.writes[0]
        self.assertEqual((image_id1, image_id2), (5, 9))
        np.testing.assert_array_equal(matches, np.array([[0, 0]], dtype=np.uint32))
        self.assertEqual(verify_calls, [("/tmp/database.db", str(pairs))])

    def test_numpy_matcher_matches_full_matrix_reference_across_chunks(self) -> None:
        rng = np.random.default_rng(42)
        first = rng.integers(0, 256, size=(37, 32), dtype=np.uint8)
        second = rng.integers(0, 256, size=(43, 32), dtype=np.uint8)
        arguments = {
            "max_ratio": 0.97,
            "max_distance": 1.2,
            "cross_check": True,
            "max_num_matches": 11,
        }

        expected = _reference_match_descriptors(first, second, **arguments)
        actual = colmap_cli._match_descriptors(
            first,
            second,
            **arguments,
            working_memory_bytes=768,
        )

        np.testing.assert_array_equal(actual, expected)

    def test_numpy_matcher_handles_empty_and_single_candidate_inputs(self) -> None:
        descriptors = np.array([[1, 0], [0, 1]], dtype=np.uint8)
        empty = np.empty((0, 2), dtype=np.uint8)
        one = np.array([[1, 0]], dtype=np.uint8)
        arguments = {
            "max_ratio": 0.8,
            "max_distance": 0.7,
            "cross_check": True,
            "max_num_matches": 64,
        }

        for first, second in (
            (empty, descriptors),
            (descriptors, empty),
            (descriptors, one),
        ):
            with self.subTest(shape1=first.shape, shape2=second.shape):
                matches = colmap_cli._match_descriptors(first, second, **arguments)
                self.assertEqual(matches.shape, (0, 2))
                self.assertEqual(matches.dtype, np.uint32)

    def test_numpy_matcher_bounds_each_distance_block(self) -> None:
        rng = np.random.default_rng(7)
        first = rng.normal(size=(257, 24)).astype(np.float32)
        second = rng.normal(size=(263, 24)).astype(np.float32)
        working_memory_bytes = 4096
        calls: list[tuple[int, int]] = []
        real_matmul = np.matmul

        def recording_matmul(left: np.ndarray, right: np.ndarray) -> np.ndarray:
            calls.append((left.shape[0], right.shape[1]))
            return real_matmul(left, right)

        with mock.patch.object(colmap_cli.np, "matmul", side_effect=recording_matmul):
            colmap_cli._match_descriptors(
                first,
                second,
                max_ratio=0.99,
                max_distance=2.0,
                cross_check=False,
                max_num_matches=300,
                working_memory_bytes=working_memory_bytes,
            )

        self.assertGreater(len(calls), 1)
        self.assertTrue(
            all(rows * columns * 12 <= working_memory_bytes for rows, columns in calls)
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

    def test_standard_matchers_translate_pairing_options_and_force_cpu(self) -> None:
        calls: list[tuple[str, tuple[object, ...], dict[str, object]]] = []

        def record(name: str):
            return lambda *args, **kwargs: calls.append((name, args, kwargs))

        pycolmap = types.SimpleNamespace(
            Device=types.SimpleNamespace(cpu="cpu"),
            FeatureMatchingOptions=_Options,
            TwoViewGeometryOptions=_Options,
            SequentialPairingOptions=_Options,
            ExhaustivePairingOptions=_Options,
            match_sequential=record("sequential"),
            match_exhaustive=record("exhaustive"),
        )
        common = {
            "database_path": "/tmp/database.db",
            "FeatureMatching.use_gpu": "1",
            "FeatureMatching.num_threads": "3",
            "FeatureMatching.max_num_matches": "2048",
            "SiftMatching.cpu_brute_force_matcher": "1",
        }

        colmap_cli.run_command(
            "sequential_matcher",
            common | {"SequentialMatching.overlap": "12"},
            pycolmap_module=pycolmap,
        )
        colmap_cli.run_command(
            "exhaustive_matcher",
            common | {"ExhaustiveMatching.block_size": "18"},
            pycolmap_module=pycolmap,
        )

        self.assertEqual([call[0] for call in calls], ["sequential", "exhaustive"])
        sequential = calls[0][2]
        self.assertEqual(sequential["device"], "cpu")
        self.assertEqual(sequential["pairing_options"].overlap, 12)
        self.assertFalse(sequential["matching_options"].use_gpu)
        self.assertEqual(sequential["matching_options"].num_threads, 3)
        self.assertEqual(sequential["matching_options"].max_num_matches, 2048)
        self.assertTrue(sequential["matching_options"].sift.cpu_brute_force_matcher)
        exhaustive = calls[1][2]
        self.assertEqual(exhaustive["device"], "cpu")
        self.assertEqual(exhaustive["pairing_options"].block_size, 18)

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

    def test_mapper_uses_incremental_mapping_on_cpu(self) -> None:
        calls: list[dict[str, object]] = []
        pycolmap = types.SimpleNamespace(
            IncrementalPipelineOptions=_Options,
            incremental_mapping=lambda **kwargs: calls.append(kwargs) or {},
        )
        common = {
            "database_path": "/tmp/database.db",
            "image_path": "/tmp/images",
            "output_path": "/tmp/sparse",
        }

        colmap_cli.run_command(
            "mapper",
            common | {"Mapper.ba_global_max_num_iterations": "17"},
            pycolmap_module=pycolmap,
        )
        self.assertEqual(len(calls), 1)
        mapper = calls[0]["options"]
        self.assertEqual(mapper.ba_global_max_num_iterations, 17)
        self.assertFalse(mapper.ba_use_gpu)

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
            BundleAdjustmentOptions=_Options,
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
        self.assertFalse(adjustment.use_gpu)
        self.assertEqual(adjustment.solver_options.max_num_iterations, 31)
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
            CopyType=types.SimpleNamespace(copy="copy"),
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
