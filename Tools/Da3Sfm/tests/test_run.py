from __future__ import annotations

import gc
import json
import os
import sys
import tempfile
import types
import unittest
import weakref
from pathlib import Path
from unittest import mock

import numpy as np
from PIL import Image

from easysplat_da3_sfm.run import (
    _align_w2c_poses,
    _camera_params,
    _colmap_text_stats,
    _default_models_dir,
    _estimate_sim3,
    _exact_prediction_geometry,
    _list_images,
    _model_path,
    _plan_continuous_batches,
    _plan_unordered_batches,
    _plan_windows,
    _rotmat_to_quat_wxyz,
    _run_da3_export,
    _select_anchor_indices,
    _select_device,
    _validate_common_view_rotations,
    _write_seed_colmap,
    _write_colmap_from_prediction,
    _write_manifest,
    build_arg_parser,
    main,
)


class Da3RunTests(unittest.TestCase):
    def test_list_images_filters_supported_extensions(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in ["b.png", "a.jpg", "notes.txt"]:
                (root / name).write_text("x", encoding="utf-8")
            self.assertEqual([path.name for path in _list_images(root)], ["a.jpg", "b.png"])

    def test_list_images_rejects_heic_without_decoder_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in ["a.heic", "b.heif", "c.png"]:
                (root / name).write_text("x", encoding="utf-8")
            self.assertEqual([path.name for path in _list_images(root)], ["c.png"])

    def test_default_models_dir_honors_env(self) -> None:
        with mock.patch.dict(os.environ, {"EASYSPLAT_DA3_MODELS_DIR": "/tmp/da3-models"}):
            self.assertEqual(_default_models_dir(), "/tmp/da3-models")

    def test_model_path_requires_local_config_and_weights(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model = Path(temp_dir) / "DA3-BASE"
            model.mkdir()
            (model / "config.json").write_text("{}", encoding="utf-8")
            (model / "model.safetensors").write_bytes(b"0")
            self.assertEqual(_model_path(Path(temp_dir), "DA3-BASE"), model)

    def test_select_device_falls_back_from_cuda(self) -> None:
        self.assertEqual(_select_device("cuda"), "cpu")

    def test_parser_exposes_offline_bridge_arguments(self) -> None:
        parser = build_arg_parser()
        args = parser.parse_args([
            "--images", "images",
            "--out-sparse", "sparse/0",
            "--models-dir", "models",
            "--device", "mps",
            "--mode", "direct",
            "--model-subdir", "DA3-BASE",
            "--fallback-model-subdir", "DA3-SMALL",
            "--process-res", "504",
            "--max-points", "120000",
            "--camera-type", "PINHOLE",
            "--shared-camera",
            "--window-size", "6",
            "--window-overlap", "2",
            "--manifest-out", "manifest.json",
        ])
        self.assertEqual(args.model_subdir, "DA3-BASE")
        self.assertEqual(args.fallback_model_subdir, "DA3-SMALL")
        self.assertTrue(args.shared_camera)

    def test_parser_accepts_seed_refine_and_input_ordering(self) -> None:
        parser = build_arg_parser()
        args = parser.parse_args([
            "--images", "images",
            "--out-sparse", "sparse/0",
            "--models-dir", "models",
            "--mode", "seed_refine",
            "--input-ordering", "continuous",
        ])
        self.assertEqual(args.mode, "seed_refine")
        self.assertEqual(args.input_ordering, "continuous")

    def test_requirements_pin_runtime_sensitive_dependencies(self) -> None:
        requirements = (Path(__file__).resolve().parents[1] / "requirements.txt").read_text(encoding="utf-8")
        lines = {
            line.strip()
            for line in requirements.splitlines()
            if line.strip() and not line.strip().startswith("#")
        }
        self.assertIn("torch==2.10.0", lines)
        self.assertIn("torchvision==0.25.0", lines)
        self.assertIn("numpy==2.3.5", lines)
        self.assertIn("opencv-python-headless==4.10.0.84", lines)
        self.assertIn("pillow==12.1.0", lines)
        self.assertIn("safetensors==0.7.0", lines)
        self.assertIn("huggingface_hub==1.14.0", lines)
        self.assertIn("transformers==5.8.1", lines)
        self.assertIn("einops==0.8.2", lines)
        self.assertIn("omegaconf==2.3.0", lines)
        self.assertIn("pycolmap==3.13.0", lines)

    def test_plan_windows_keeps_memory_bounded_overlap(self) -> None:
        self.assertEqual(_plan_windows(1, 6, 2), [(0, 1)])
        self.assertEqual(_plan_windows(6, 6, 2), [(0, 6)])
        self.assertEqual(_plan_windows(10, 4, 1), [(0, 4), (3, 7), (6, 10)])

    def test_continuous_planner_covers_large_inputs_exactly(self) -> None:
        for image_count in (30, 120, 250):
            batches = _plan_continuous_batches(image_count, window_size=8, overlap=3)
            flattened = {index for batch in batches for index in batch}
            self.assertEqual(flattened, set(range(image_count)))
            self.assertTrue(all(len(batch) <= 8 for batch in batches))
            for previous, current in zip(batches, batches[1:]):
                self.assertGreaterEqual(len(set(previous) & set(current)), 3)

    def test_unordered_planner_covers_large_inputs_exactly(self) -> None:
        anchors = [0, 2, 5]
        for image_count in (30, 120, 250):
            batches = _plan_unordered_batches(image_count, window_size=8, anchor_indices=anchors)
            flattened = {index for batch in batches for index in batch}
            self.assertEqual(flattened, set(range(image_count)))
            self.assertEqual(batches[0], list(range(8)))
            self.assertTrue(all(len(batch) <= 8 for batch in batches))
            for batch in batches[1:]:
                self.assertEqual(batch[:3], anchors)

    def test_unordered_anchor_selection_rejects_collinear_centers(self) -> None:
        centers = np.array([[float(index), 0.0, 0.0] for index in range(8)])
        with self.assertRaisesRegex(ValueError, "non-collinear"):
            _select_anchor_indices(centers)

    def test_umeyama_recovers_known_sim3_and_transforms_w2c(self) -> None:
        angle = np.deg2rad(25.0)
        rotation = np.array([
            [np.cos(angle), -np.sin(angle), 0.0],
            [np.sin(angle), np.cos(angle), 0.0],
            [0.0, 0.0, 1.0],
        ])
        scale = 2.5
        translation = np.array([3.0, -4.0, 1.5])
        source = np.array([
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 2.0, 0.0],
            [0.5, 0.5, 1.0],
        ])
        target = (scale * (rotation @ source.T)).T + translation

        solved_scale, solved_rotation, solved_translation, normalized_rmse = _estimate_sim3(source, target)
        self.assertAlmostEqual(solved_scale, scale, places=8)
        np.testing.assert_allclose(solved_rotation, rotation, atol=1e-8)
        np.testing.assert_allclose(solved_translation, translation, atol=1e-8)
        self.assertLess(normalized_rmse, 1e-10)

        local_w2c = np.repeat(np.eye(4)[None, ...], source.shape[0], axis=0)
        local_w2c[:, :3, 3] = -source
        aligned = _align_w2c_poses(local_w2c, solved_scale, solved_rotation, solved_translation)
        aligned_centers = np.stack([-pose[:3, :3].T @ pose[:3, 3] for pose in aligned])
        np.testing.assert_allclose(aligned_centers, target, atol=1e-8)
        np.testing.assert_allclose(aligned[:, :3, :3], np.repeat(rotation.T[None, ...], 4, axis=0), atol=1e-8)

    def test_umeyama_rejects_reflection_degenerate_nonfinite_and_high_rmse(self) -> None:
        source = np.array([
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
            [0.0, 0.0, 1.0],
        ])
        reflected = source.copy()
        reflected[:, 0] *= -1.0
        with self.assertRaisesRegex(ValueError, "reflection"):
            _estimate_sim3(source, reflected)
        with self.assertRaisesRegex(ValueError, "rank"):
            _estimate_sim3(source[:3] * np.array([1.0, 0.0, 0.0]), source[:3])
        nonfinite = source.copy()
        nonfinite[0, 0] = np.nan
        with self.assertRaisesRegex(ValueError, "finite"):
            _estimate_sim3(nonfinite, source)
        noisy = source.copy()
        noisy[-1] = [8.0, -5.0, 3.0]
        with self.assertRaisesRegex(ValueError, "RMSE"):
            _estimate_sim3(source, noisy)

    def test_three_anchor_mirror_is_rejected_by_camera_orientation(self) -> None:
        source_centers = np.array([
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
        ])
        target_centers = source_centers.copy()
        target_centers[:, 0] *= -1.0
        scale, rotation, translation, _ = _estimate_sim3(source_centers, target_centers)

        local_w2c = np.repeat(np.eye(4)[None, ...], 3, axis=0)
        local_w2c[:, :3, 3] = -source_centers
        accepted_global_w2c = np.repeat(np.eye(4)[None, ...], 3, axis=0)
        accepted_global_w2c[:, :3, 3] = -target_centers
        aligned = _align_w2c_poses(local_w2c, scale, rotation, translation)

        with self.assertRaisesRegex(ValueError, "camera orientation"):
            _validate_common_view_rotations(aligned, accepted_global_w2c)

    def test_seed_export_has_stable_ids_and_no_points_or_observations(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(4):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (16, 12), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            poses = np.repeat(np.eye(4)[None, ...], 4, axis=0)
            poses[:, 0, 3] = -np.arange(4)
            intrinsics = np.repeat(
                np.array([[8.0, 0.0, 8.0], [0.0, 8.0, 6.0], [0.0, 0.0, 1.0]])[None, ...],
                4,
                axis=0,
            )
            sparse = root / "sparse" / "0"
            _write_seed_colmap(poses, intrinsics, images, sparse, "PINHOLE", shared_camera=False)

            pose_lines = [
                line for line in (sparse / "images.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual([int(line.split()[0]) for line in pose_lines], [1, 2, 3, 4])
            self.assertEqual([line.split(maxsplit=9)[-1] for line in pose_lines], [path.name for path in images])
            image_lines = (sparse / "images.txt").read_text(encoding="utf-8").splitlines()
            for pose_line in pose_lines:
                self.assertEqual(image_lines[image_lines.index(pose_line) + 1], "")
            self.assertFalse(any(
                line and not line.startswith("#")
                for line in (sparse / "points3D.txt").read_text(encoding="utf-8").splitlines()
            ))

    def test_seed_export_rejects_missing_prediction_view_instead_of_padding(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(4):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8)).save(path)
                images.append(path)
            with self.assertRaisesRegex(ValueError, "pose count 3 did not match image count 4"):
                _write_seed_colmap(
                    np.repeat(np.eye(4)[None, ...], 3, axis=0),
                    np.repeat(np.eye(3)[None, ...], 4, axis=0),
                    images,
                    root / "sparse" / "0",
                    "PINHOLE",
                    shared_camera=False,
                )

    def test_seed_geometry_rejects_nonrigid_pose_matrix(self) -> None:
        pose = np.eye(4)[None, ...]
        pose[0, 0, 1] = 0.5
        with self.assertRaisesRegex(ValueError, "non-rigid"):
            _exact_prediction_geometry(
                {
                    "extrinsics": pose,
                    "intrinsics": np.eye(3)[None, ...],
                },
                1,
            )

    def test_seed_geometry_requires_canonical_pinhole_intrinsics(self) -> None:
        malformed = {
            "skew": np.array([[2.0, 0.2, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]]),
            "lower_off_diagonal": np.array([[2.0, 0.0, 1.0], [0.2, 2.0, 1.0], [0.0, 0.0, 1.0]]),
            "bottom_row": np.array([[2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.1, 0.0, 1.0]]),
            "non_unit_homogeneous": np.array([[2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 2.0]]),
            "negative_focal": np.array([[-2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]]),
            "nonfinite_principal_point": np.array([[2.0, 0.0, np.nan], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]]),
        }
        for label, intrinsics in malformed.items():
            with self.subTest(label=label):
                with self.assertRaisesRegex(ValueError, "intrinsics"):
                    _exact_prediction_geometry(
                        {
                            "extrinsics": np.eye(4)[None, ...],
                            "intrinsics": intrinsics[None, ...],
                        },
                        1,
                    )

    def test_camera_params_rejects_nonfinite_scaled_values(self) -> None:
        intrinsics = np.array([
            [1e308, 0.0, 1.0],
            [0.0, 1e308, 1.0],
            [0.0, 0.0, 1.0],
        ])
        with self.assertRaisesRegex(ValueError, "scaled camera parameters"):
            _camera_params(
                intrinsics,
                (16, 12),
                "PINHOLE",
                source_size=(1, 1),
            )

    def test_camera_params_supports_colmap_fisheye_schema(self) -> None:
        intrinsics = np.array([
            [500.0, 0.0, 320.0],
            [0.0, 490.0, 240.0],
            [0.0, 0.0, 1.0],
        ])

        self.assertEqual(
            _camera_params(intrinsics, (640, 480), "OPENCV_FISHEYE"),
            [500.0, 490.0, 320.0, 240.0, 0.0, 0.0, 0.0, 0.0],
        )
        self.assertEqual(
            build_arg_parser().parse_args(
                [
                    "--images", "/tmp/images",
                    "--out-sparse", "/tmp/sparse",
                    "--camera-type", "OPENCV_FISHEYE",
                ]
            ).camera_type,
            "OPENCV_FISHEYE",
        )

    def test_rotmat_to_quat_handles_negative_trace_rotation(self) -> None:
        quat = _rotmat_to_quat_wxyz(np.array([
            [1.0, 0.0, 0.0],
            [0.0, -1.0, 0.0],
            [0.0, 0.0, -1.0],
        ]))
        np.testing.assert_allclose(np.abs(quat), np.array([0.0, 1.0, 0.0, 0.0]))

    def test_write_colmap_from_prediction_emits_text_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(2):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (16, 12), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            prediction = {
                "extrinsics": np.repeat(np.eye(4)[None, ...], repeats=2, axis=0),
                "intrinsics": np.repeat(
                    np.array([[4.0, 0.0, 2.0], [0.0, 3.0, 1.5], [0.0, 0.0, 1.0]])[None, ...],
                    repeats=2,
                    axis=0,
                ),
                "depth": np.ones((2, 4, 4), dtype=np.float32),
                "conf": np.ones((2, 4, 4), dtype=np.float32),
            }
            out = root / "sparse" / "0"
            point_count, observation_count, mean_track_length = _write_colmap_from_prediction(
                prediction,
                images,
                out,
                camera_type="PINHOLE",
                shared_camera=True,
                max_points=8,
            )
            self.assertTrue((out / "cameras.txt").exists())
            self.assertTrue((out / "images.txt").exists())
            self.assertTrue((out / "points3D.txt").exists())
            cameras_txt = (out / "cameras.txt").read_text(encoding="utf-8")
            images_txt = (out / "images.txt").read_text(encoding="utf-8")
            points_txt = (out / "points3D.txt").read_text(encoding="utf-8")
            self.assertIn("img0.jpg", images_txt)
            self.assertIn("1 PINHOLE 16 12 16.0 9.0 8.0 4.5", cameras_txt)
            self.assertEqual(point_count, 8)
            self.assertEqual(observation_count, 16)
            self.assertEqual(mean_track_length, 2.0)
            self.assertIn("mean track length: 2.00", points_txt)
            first_point = next(line for line in points_txt.splitlines() if line and not line.startswith("#"))
            self.assertGreaterEqual(len(first_point.split()), 12)

    def test_write_colmap_from_prediction_accepts_prediction_object_and_3x4_pose(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(2):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            pose = np.repeat(np.eye(4, dtype=np.float32)[None, :3, :], repeats=2, axis=0)
            pose[1, 0, 3] = 1.25
            prediction = types.SimpleNamespace(
                extrinsics=pose,
                intrinsics=np.repeat(np.eye(3, dtype=np.float32)[None, ...], 2, axis=0),
                depth=np.ones((2, 2, 2), dtype=np.float32),
                conf=np.ones((2, 2, 2), dtype=np.float32),
            )
            out = root / "sparse" / "0"
            _write_colmap_from_prediction(
                prediction,
                images,
                out,
                camera_type="PINHOLE",
                shared_camera=False,
                max_points=4,
            )
            images_txt = (out / "images.txt").read_text(encoding="utf-8")
            self.assertIn("1.25", images_txt)

    def test_write_colmap_from_prediction_rejects_short_depth_axis(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(2):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            prediction = {
                "intrinsics": np.repeat(np.eye(3, dtype=np.float32)[None, ...], 2, axis=0),
                "depth": np.ones((1, 2, 2), dtype=np.float32),
            }
            with self.assertRaisesRegex(ValueError, "depth count 1 did not match image count 2"):
                _write_colmap_from_prediction(
                    prediction,
                    images,
                    root / "sparse" / "0",
                    camera_type="PINHOLE",
                    shared_camera=False,
                    max_points=4,
                )

    def test_write_colmap_from_prediction_reuses_single_camera_prediction(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(2):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (20, 10), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            prediction = {
                "extrinsics": np.eye(4, dtype=np.float32)[None, ...],
                "intrinsics": np.array([[[5.0, 0.0, 2.5], [0.0, 2.5, 1.25], [0.0, 0.0, 1.0]]], dtype=np.float32),
                "depth": np.ones((2, 5, 5), dtype=np.float32),
            }
            out = root / "sparse" / "0"
            _write_colmap_from_prediction(
                prediction,
                images,
                out,
                camera_type="PINHOLE",
                shared_camera=False,
                max_points=4,
            )

            cameras = [
                line
                for line in (out / "cameras.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual(len(cameras), 2)
            self.assertTrue(cameras[0].startswith("1 PINHOLE 20 10 "))
            self.assertTrue(cameras[1].startswith("2 PINHOLE 20 10 "))

    def test_write_manifest_records_da3_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "da3_coverage_manifest.json"
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "sparse" / "0"),
                "--models-dir", str(root / "models"),
                "--manifest-out", str(manifest),
            ])
            _write_manifest(
                manifest,
                args=args,
                image_paths=[Path("a.jpg"), Path("b.jpg"), Path("c.jpg")],
                selected_device="mps",
                model_subdir="DA3-BASE",
                native_colmap_export=True,
                raw_point_count=12,
                final_observation_count=24,
                mean_track_length=2.0,
            )
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["mode"], "direct")
            self.assertEqual(payload["model_subdir"], "DA3-BASE")
            self.assertEqual(payload["fallback_model_subdir"], "DA3-SMALL")
            self.assertTrue(payload["native_colmap_export"])
            self.assertEqual(payload["export_strategy"], "native_colmap")
            self.assertEqual(payload["raw_point_sample_count"], 12)
            self.assertEqual(payload["final_observation_count"], 24)
            self.assertEqual(payload["mean_track_length"], 2.0)
            self.assertEqual(payload["windows"][0]["images"], ["a.jpg", "b.jpg", "c.jpg"])

    def test_seed_manifest_records_complete_alignment_without_fake_points(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "da3_coverage_manifest.json"
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "sparse" / "0"),
                "--models-dir", str(root / "models"),
                "--mode", "seed_refine",
                "--input-ordering", "unordered",
                "--window-size", "6",
                "--window-overlap", "3",
            ])
            image_paths = [Path(f"img{index}.jpg") for index in range(10)]
            batches = [list(range(6)), [0, 2, 5, 6, 7, 8], [0, 2, 5, 9]]
            _write_manifest(
                manifest,
                args=args,
                image_paths=image_paths,
                selected_device="mps",
                model_subdir="DA3-BASE",
                native_colmap_export=False,
                export_strategy="aligned_pose_seed",
                registered_image_count=10,
                alignment_evidence={
                    "batches": batches,
                    "anchor_indices": [0, 2, 5],
                    "alignment_edge_count": 2,
                    "max_alignment_rmse": 0.012,
                    "alignment_complete": True,
                },
            )
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["export_strategy"], "aligned_pose_seed")
            self.assertFalse(payload["native_colmap_export"])
            self.assertEqual(payload["input_ordering"], "unordered")
            self.assertEqual(payload["anchor_image_names"], ["img0.jpg", "img2.jpg", "img5.jpg"])
            self.assertEqual(payload["alignment_edge_count"], 2)
            self.assertTrue(payload["alignment_complete"])
            self.assertNotIn("raw_point_sample_count", payload)
            self.assertNotIn("fused_sparse_point_count", payload)
            self.assertNotIn("final_observation_count", payload)

    def test_colmap_text_stats_reads_registered_images_and_tracks(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            sparse = Path(temp_dir)
            (sparse / "images.txt").write_text(
                "# Image list\n"
                "1 1 0 0 0 0 0 0 1 a.jpg\n"
                "1 2 3\n"
                "2 1 0 0 0 0 0 0 1 b.jpg\n"
                "\n",
                encoding="utf-8",
            )
            (sparse / "points3D.txt").write_text(
                "# Points\n"
                "1 0 0 1 128 128 128 1.0 1 0 2 0\n"
                "2 0 0 2 128 128 128 1.0 1 1\n",
                encoding="utf-8",
            )
            self.assertEqual(_colmap_text_stats(sparse), (2, 2, 3, 1.5))

    def test_main_forces_offline_env_and_retries_small_on_oom(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            out_sparse = root / "sparse" / "0"
            manifest = root / "da3_coverage_manifest.json"
            images.mkdir()
            for index in range(2):
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(images / f"img{index}.jpg")
            for model_name in ["DA3-BASE", "DA3-SMALL"]:
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            calls: list[Path] = []

            def fake_run(args, image_paths, model_dir, selected_device, sparse_path):
                calls.append(model_dir)
                self.assertEqual(selected_device, "cpu")
                self.assertEqual(len(image_paths), 2)
                self.assertEqual(sparse_path, out_sparse)
                if model_dir.name == "DA3-BASE":
                    raise RuntimeError("MPS backend out of memory")
                return 7, 14, 2.0, 2, None

            with mock.patch("easysplat_da3_sfm.run._run_da3_export", side_effect=fake_run):
                with mock.patch.dict(os.environ, {}, clear=True):
                    exit_code = main([
                        "--images", str(images),
                        "--out-sparse", str(out_sparse),
                        "--models-dir", str(models),
                        "--manifest-out", str(manifest),
                        "--device", "cpu",
                    ])

            self.assertEqual(exit_code, 0)
            self.assertEqual([call.name for call in calls], ["DA3-BASE", "DA3-SMALL"])
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["selected_device"], "cpu")
            self.assertEqual(payload["model_subdir"], "DA3-SMALL")
            self.assertEqual(payload["raw_point_sample_count"], 7)
            self.assertEqual(payload["final_observation_count"], 14)
            self.assertEqual(payload["mean_track_length"], 2.0)
            self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
            self.assertEqual(os.environ["TRANSFORMERS_OFFLINE"], "1")
            self.assertEqual(os.environ["HF_HUB_DISABLE_TELEMETRY"], "1")
            self.assertEqual(os.environ["DO_NOT_TRACK"], "1")
            self.assertEqual(os.environ["PYTORCH_ENABLE_MPS_FALLBACK"], "1")

    def test_main_oom_discards_partial_seed_before_restart_on_small(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            out_sparse = root / "sparse" / "0"
            manifest = root / "da3_coverage_manifest.json"
            images.mkdir()
            for index in range(7):
                Image.new("RGB", (8, 8)).save(images / f"img{index}.jpg")
            for model_name in ("DA3-BASE", "DA3-SMALL"):
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            attempts: list[str] = []

            def fake_run(args, image_paths, model_dir, selected_device, sparse_path):
                attempts.append(model_dir.name)
                if model_dir.name == "DA3-BASE":
                    sparse_path.mkdir(parents=True)
                    (sparse_path / "partial.txt").write_text("mixed model output", encoding="utf-8")
                    manifest.write_text("partial", encoding="utf-8")
                    raise RuntimeError("MPS backend out of memory")
                self.assertFalse((sparse_path / "partial.txt").exists())
                self.assertFalse(manifest.exists())
                sparse_path.mkdir(parents=True)
                for name in ("cameras.txt", "images.txt", "points3D.txt"):
                    (sparse_path / name).write_text("# empty\n", encoding="utf-8")
                return 0, 0, None, len(image_paths), {
                    "batches": [list(range(4)), [0, 1, 2, 4, 5, 6]],
                    "anchor_indices": [0, 1, 2],
                    "alignment_edge_count": 1,
                    "max_alignment_rmse": 0.0,
                    "alignment_complete": True,
                }

            with mock.patch("easysplat_da3_sfm.run._run_da3_export", side_effect=fake_run):
                exit_code = main([
                    "--images", str(images),
                    "--out-sparse", str(out_sparse),
                    "--models-dir", str(models),
                    "--device", "cpu",
                    "--mode", "seed_refine",
                    "--input-ordering", "continuous",
                    "--window-size", "4",
                    "--window-overlap", "3",
                    "--manifest-out", str(manifest),
                ])

            self.assertEqual(exit_code, 0)
            self.assertEqual(attempts, ["DA3-BASE", "DA3-SMALL"])
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["model_subdir"], "DA3-SMALL")
            self.assertEqual(payload["export_strategy"], "aligned_pose_seed")

    def test_seed_oom_restarts_every_batch_with_small_model(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            out_sparse = root / "seed" / "0"
            manifest = root / "manifest.json"
            images.mkdir()
            for index in range(7):
                Image.new("RGB", (8, 8)).save(images / f"img{index}.jpg")
            for model_name in ("DA3-BASE", "DA3-SMALL"):
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            calls: dict[str, list[list[str]]] = {"DA3-BASE": [], "DA3-SMALL": []}
            loads: list[str] = []
            base_model_ref: weakref.ReferenceType[object] | None = None

            class FakeModel:
                def __init__(self, name: str):
                    self.name = name

                def to(self, device):
                    return self

                def inference(self, **kwargs):
                    names = [Path(value).name for value in kwargs["image"]]
                    calls[self.name].append(names)
                    if self.name == "DA3-BASE" and len(calls[self.name]) == 2:
                        raise RuntimeError("MPS backend out of memory")
                    centers = []
                    for name in names:
                        index = int(name.removeprefix("img").removesuffix(".jpg"))
                        centers.append(np.array([float(index % 3), float(index // 3), float((index * index) % 5) * 0.1]))
                    poses = np.repeat(np.eye(4)[None, ...], len(names), axis=0)
                    poses[:, :3, 3] = -np.stack(centers)
                    return {
                        "extrinsics": poses,
                        "intrinsics": np.repeat(np.eye(3)[None, ...], len(names), axis=0),
                        "depth": np.ones((len(names), 2, 2)),
                    }

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    nonlocal base_model_ref
                    name = Path(path).name
                    loads.append(name)
                    if name == "DA3-SMALL":
                        gc.collect()
                        if base_model_ref is not None and base_model_ref() is not None:
                            raise AssertionError("BASE model remained live when SMALL started loading")
                    model = FakeModel(name)
                    if name == "DA3-BASE":
                        base_model_ref = weakref.ref(model)
                    return model

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                exit_code = main([
                    "--images", str(images),
                    "--out-sparse", str(out_sparse),
                    "--models-dir", str(models),
                    "--device", "cpu",
                    "--mode", "seed_refine",
                    "--input-ordering", "continuous",
                    "--window-size", "4",
                    "--window-overlap", "3",
                    "--manifest-out", str(manifest),
                ])

            self.assertEqual(exit_code, 0)
            self.assertEqual(loads, ["DA3-BASE", "DA3-SMALL"])
            self.assertEqual(calls["DA3-BASE"], [
                ["img0.jpg", "img1.jpg", "img2.jpg", "img3.jpg"],
                ["img1.jpg", "img2.jpg", "img3.jpg", "img4.jpg"],
            ])
            self.assertEqual(calls["DA3-SMALL"][0], ["img0.jpg", "img1.jpg", "img2.jpg", "img3.jpg"])
            self.assertEqual(len(calls["DA3-SMALL"]), 4)
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["model_subdir"], "DA3-SMALL")
            self.assertEqual(payload["registered_image_count"], 7)

    def test_main_does_not_retry_non_memory_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            images.mkdir()
            for index in range(2):
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(images / f"img{index}.jpg")
            for model_name in ["DA3-BASE", "DA3-SMALL"]:
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            with mock.patch("easysplat_da3_sfm.run._run_da3_export", side_effect=RuntimeError("bad geometry")) as run_mock:
                with self.assertRaisesRegex(RuntimeError, "bad geometry"):
                    main([
                        "--images", str(images),
                        "--out-sparse", str(root / "sparse" / "0"),
                        "--models-dir", str(models),
                        "--device", "cpu",
                    ])

            self.assertEqual(run_mock.call_count, 1)

    def test_run_da3_export_rejects_inputs_that_need_unsafe_windowed_colmap_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(5):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            model_dir = root / "models" / "DA3-BASE"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "model.safetensors").write_bytes(b"0")

            calls: list[list[str]] = []

            class FakeModel:
                def inference(self, **kwargs):
                    calls.append([Path(path).name for path in kwargs["image"]])
                    count = len(kwargs["image"])
                    return {
                        "extrinsics": np.repeat(np.eye(4, dtype=np.float32)[None, ...], count, axis=0),
                        "intrinsics": np.repeat(np.eye(3, dtype=np.float32)[None, ...], count, axis=0),
                        "depth": np.ones((count, 2, 2), dtype=np.float32),
                        "conf": np.ones((count, 2, 2), dtype=np.float32),
                    }

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    self.assertEqual(Path(path), model_dir)
                    self.assertTrue(local_files_only)
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "sparse" / "0"),
                "--models-dir", str(model_dir.parent),
                "--window-size", "2",
                "--window-overlap", "1",
                "--max-points", "10",
            ])

            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                with self.assertRaisesRegex(RuntimeError, "native COLMAP export"):
                    _run_da3_export(
                        args,
                        images,
                        model_dir,
                        "cpu",
                        root / "sparse" / "0",
                    )

            self.assertEqual(calls, [])

    def test_seed_refine_loads_one_model_and_aligns_every_selected_view(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(7):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8)).save(path)
                images.append(path)
            model_dir = root / "models" / "DA3-BASE"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "model.safetensors").write_bytes(b"0")

            global_centers = {
                index: np.array([float(index % 3), float(index // 3), float((index * index) % 5) * 0.1])
                for index in range(7)
            }
            inference_calls: list[list[str]] = []
            load_count = 0

            class FakeModel:
                def to(self, device):
                    return self

                def inference(self, **kwargs):
                    names = [Path(value).name for value in kwargs["image"]]
                    inference_calls.append(names)
                    call_index = len(inference_calls) - 1
                    angle = np.deg2rad(0.0 if call_index == 0 else 10.0 * call_index)
                    local_to_global_rotation = np.array([
                        [np.cos(angle), -np.sin(angle), 0.0],
                        [np.sin(angle), np.cos(angle), 0.0],
                        [0.0, 0.0, 1.0],
                    ])
                    scale = 1.0 if call_index == 0 else 1.0 + 0.2 * call_index
                    translation = np.array([0.3 * call_index, -0.2 * call_index, 0.1 * call_index])
                    poses = []
                    for name in names:
                        image_index = int(name.removeprefix("img").removesuffix(".jpg"))
                        center = global_centers[image_index]
                        local_center = local_to_global_rotation.T @ ((center - translation) / scale)
                        pose = np.eye(4)
                        pose[:3, :3] = local_to_global_rotation
                        pose[:3, 3] = -local_to_global_rotation @ local_center
                        poses.append(pose)
                    return {
                        "extrinsics": np.stack(poses),
                        "intrinsics": np.repeat(np.eye(3)[None, ...], len(names), axis=0),
                        "depth": np.ones((len(names), 2, 2)),
                    }

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    nonlocal load_count
                    load_count += 1
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "seed" / "0"),
                "--models-dir", str(model_dir.parent),
                "--mode", "seed_refine",
                "--input-ordering", "continuous",
                "--window-size", "4",
                "--window-overlap", "3",
            ])

            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                point_count, observations, mean_track, registered, evidence = _run_da3_export(
                    args,
                    images,
                    model_dir,
                    "cpu",
                    root / "seed" / "0",
                )

            self.assertEqual(load_count, 1)
            self.assertEqual(len(inference_calls), 4)
            self.assertEqual((point_count, observations, mean_track, registered), (0, 0, None, 7))
            self.assertEqual(evidence["alignment_edge_count"], 3)
            self.assertTrue(evidence["alignment_complete"])
            self.assertLess(evidence["max_alignment_rmse"], 1e-8)
            image_lines = [
                line for line in (root / "seed" / "0" / "images.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual(len(image_lines), 7)

    def test_seed_refine_avoids_mutating_colmap_export_and_scales_intrinsics_once(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(4):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8)).save(path)
                images.append(path)
            model_dir = root / "models" / "DA3-BASE"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "model.safetensors").write_bytes(b"0")
            captured_kwargs: list[dict[str, object]] = []

            class FakeModel:
                def inference(self, **kwargs):
                    captured_kwargs.append(dict(kwargs))
                    count = len(kwargs["image"])
                    centers = np.array([
                        [0.0, 0.0, 0.0],
                        [1.0, 0.0, 0.0],
                        [0.0, 1.0, 0.0],
                        [1.0, 1.0, 0.0],
                    ])
                    poses = np.repeat(np.eye(4)[None, ...], count, axis=0)
                    poses[:, :3, 3] = -centers[:count]
                    intrinsics = np.repeat(
                        np.array([[2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]])[None, ...],
                        count,
                        axis=0,
                    )
                    if "export_dir" in kwargs:
                        # The pinned COLMAP exporter performs this original-size
                        # conversion in place before returning Prediction.
                        intrinsics[:, :2, :] *= 4.0
                    return {
                        "extrinsics": poses,
                        "intrinsics": intrinsics,
                        "depth": np.ones((count, 2, 2)),
                    }

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "seed" / "0"),
                "--models-dir", str(model_dir.parent),
                "--mode", "seed_refine",
                "--input-ordering", "continuous",
                "--window-size", "4",
                "--window-overlap", "3",
            ])
            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                result = _run_da3_export(args, images, model_dir, "cpu", root / "seed" / "0")

            self.assertEqual(len(captured_kwargs), 1)
            self.assertNotIn("export_dir", captured_kwargs[0])
            self.assertNotIn("export_format", captured_kwargs[0])
            alignment_evidence = result[-1]
            self.assertIsNotNone(alignment_evidence)
            self.assertEqual(len(alignment_evidence["anchor_indices"]), 3)
            camera_row = next(
                line
                for line in (root / "seed" / "0" / "cameras.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            )
            self.assertEqual([float(value) for value in camera_row.split()[4:]], [8.0, 8.0, 4.0, 4.0])

    def test_seed_refine_rejects_missing_prediction_view(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(5):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8)).save(path)
                images.append(path)
            model_dir = root / "models" / "DA3-BASE"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "model.safetensors").write_bytes(b"0")

            class FakeModel:
                def inference(self, **kwargs):
                    count = len(kwargs["image"]) - 1
                    return {
                        "extrinsics": np.repeat(np.eye(4)[None, ...], count, axis=0),
                        "intrinsics": np.repeat(np.eye(3)[None, ...], count, axis=0),
                    }

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "seed" / "0"),
                "--models-dir", str(model_dir.parent),
                "--mode", "seed_refine",
                "--input-ordering", "continuous",
                "--window-size", "4",
                "--window-overlap", "3",
            ])
            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                with self.assertRaisesRegex(ValueError, "pose count 3 did not match image count 4"):
                    _run_da3_export(args, images, model_dir, "cpu", root / "seed" / "0")

    def test_run_da3_export_moves_model_to_selected_device(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(2):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            model_dir = root / "models" / "DA3-BASE"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "model.safetensors").write_bytes(b"0")
            devices: list[str] = []

            class FakeModel:
                def to(self, device):
                    devices.append(device)
                    return self

                def inference(self, **kwargs):
                    return types.SimpleNamespace(
                        extrinsics=np.repeat(np.eye(4, dtype=np.float32)[None, ...], 2, axis=0),
                        intrinsics=np.repeat(np.eye(3, dtype=np.float32)[None, ...], 2, axis=0),
                        depth=np.ones((2, 2, 2), dtype=np.float32),
                        conf=np.ones((2, 2, 2), dtype=np.float32),
                    )

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "sparse" / "0"),
                "--models-dir", str(model_dir.parent),
            ])

            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                with self.assertRaisesRegex(RuntimeError, "native COLMAP export"):
                    _run_da3_export(args, images, model_dir, "mps", root / "sparse" / "0")

            self.assertEqual(devices, ["mps"])

    def test_run_da3_export_uses_native_colmap_stats(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(2):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(path)
                images.append(path)
            model_dir = root / "models" / "DA3-BASE"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "model.safetensors").write_bytes(b"0")

            class FakeModel:
                def inference(self, **kwargs):
                    if kwargs.get("export_format") != "colmap" or "export_dir" not in kwargs:
                        raise AssertionError("direct mode must request native COLMAP export")
                    sparse = Path(kwargs["export_dir"])
                    sparse.mkdir(parents=True)
                    (sparse / "cameras.txt").write_text("1 PINHOLE 8 8 1 1 4 4\n", encoding="utf-8")
                    (sparse / "images.txt").write_text(
                        "1 1 0 0 0 0 0 0 1 img0.jpg\n\n",
                        encoding="utf-8",
                    )
                    (sparse / "points3D.txt").write_text(
                        "1 0 0 1 128 128 128 1.0 1 0\n",
                        encoding="utf-8",
                    )
                    return types.SimpleNamespace()

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "sparse" / "0"),
                "--models-dir", str(model_dir.parent),
            ])

            with mock.patch.dict(sys.modules, {
                "depth_anything_3": depth_anything_module,
                "depth_anything_3.api": api_module,
            }):
                point_count, observation_count, mean_track_length, registered_count, evidence = _run_da3_export(
                    args,
                    images,
                    model_dir,
                    "cpu",
                    root / "sparse" / "0",
                )

            self.assertEqual(point_count, 1)
            self.assertEqual(observation_count, 1)
            self.assertEqual(mean_track_length, 1.0)
            self.assertEqual(registered_count, 1)
            self.assertIsNone(evidence)

    def test_write_manifest_keeps_counts_in_sync_with_sparse_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "da3_coverage_manifest.json"
            args = build_arg_parser().parse_args([
                "--images", str(root),
                "--out-sparse", str(root / "sparse" / "0"),
                "--models-dir", str(root / "models"),
                "--max-points", "2",
                "--manifest-out", str(manifest),
            ])
            _write_manifest(
                manifest,
                args=args,
                image_paths=[Path("a.jpg"), Path("b.jpg")],
                selected_device="mps",
                model_subdir="DA3-BASE",
                native_colmap_export=True,
                raw_point_count=5,
                final_observation_count=9,
                mean_track_length=1.8,
            )

            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["raw_point_sample_count"], 5)
            self.assertEqual(payload["fused_sparse_point_count"], 5)
            self.assertEqual(payload["final_observation_count"], 9)


if __name__ == "__main__":
    unittest.main()
