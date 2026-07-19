from __future__ import annotations

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from PIL import Image

from easysplat_da3_sfm.run import (
    _align_w2c_poses,
    _build_retrieval_graph,
    _compute_image_descriptors,
    _camera_params,
    _default_models_dir,
    _estimate_sim3,
    _estimate_oriented_sim3,
    _exact_prediction_geometry,
    _fuse_depth_points,
    _list_images,
    _model_path,
    _plan_continuous_batches,
    _plan_unordered_batches,
    _rotmat_to_quat_wxyz,
    _run_da3_model,
    _run_da3_seed_refine,
    _sample_depth_points,
    _select_anchor_indices,
    _select_device,
    _validate_common_view_rotations,
    _write_seed_colmap,
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
            self.assertEqual(
                [path.name for path in _list_images(root)], ["a.jpg", "b.png"]
            )

    def test_list_images_rejects_heic_without_decoder_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in ["a.heic", "b.heif", "c.png"]:
                (root / name).write_text("x", encoding="utf-8")
            self.assertEqual([path.name for path in _list_images(root)], ["c.png"])

    def test_default_models_dir_honors_env(self) -> None:
        with mock.patch.dict(
            os.environ, {"EASYSPLAT_DA3_MODELS_DIR": "/tmp/da3-models"}
        ):
            self.assertEqual(_default_models_dir(), "/tmp/da3-models")

    def test_model_path_requires_local_config_and_weights(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            model = Path(temp_dir) / "DA3-BASE"
            model.mkdir()
            (model / "config.json").write_text("{}", encoding="utf-8")
            (model / "model.safetensors").write_bytes(b"0")
            self.assertEqual(_model_path(Path(temp_dir), "DA3-BASE"), model)

    def test_select_device_rejects_non_mps_execution(self) -> None:
        for requested in ("cuda", "cpu", ""):
            with self.subTest(requested=requested):
                with self.assertRaisesRegex(RuntimeError, "requires MPS"):
                    _select_device(requested)

    def test_select_device_rejects_unavailable_requested_mps(self) -> None:
        fake_torch = types.SimpleNamespace(
            backends=types.SimpleNamespace(
                mps=types.SimpleNamespace(is_available=lambda: False)
            )
        )
        with mock.patch.dict(sys.modules, {"torch": fake_torch}):
            with self.assertRaisesRegex(RuntimeError, "MPS is unavailable"):
                _select_device("mps")

    def test_parser_exposes_offline_bridge_arguments(self) -> None:
        parser = build_arg_parser()
        args = parser.parse_args(
            [
                "--images",
                "images",
                "--out-sparse",
                "sparse/0",
                "--models-dir",
                "models",
                "--device",
                "mps",
                "--model-subdir",
                "DA3-BASE",
                "--process-res",
                "504",
                "--max-points",
                "120000",
                "--camera-type",
                "PINHOLE",
                "--shared-camera",
                "--window-size",
                "6",
                "--window-overlap",
                "2",
                "--manifest-out",
                "manifest.json",
            ]
        )
        self.assertEqual(args.model_subdir, "DA3-BASE")
        self.assertTrue(args.shared_camera)

    def test_parser_accepts_input_ordering(self) -> None:
        parser = build_arg_parser()
        args = parser.parse_args(
            [
                "--images",
                "images",
                "--out-sparse",
                "sparse/0",
                "--models-dir",
                "models",
                "--input-ordering",
                "continuous",
            ]
        )
        self.assertEqual(args.input_ordering, "continuous")

    def test_requirements_pin_runtime_sensitive_dependencies(self) -> None:
        root = Path(__file__).resolve().parents[1]
        requirements = (root / "requirements.in").read_text(encoding="utf-8")
        lines = {
            line.strip()
            for line in requirements.splitlines()
            if line.strip() and not line.strip().startswith("#")
        }
        self.assertIn("torch==2.13.0", lines)
        self.assertIn("torchvision==0.28.0", lines)
        self.assertIn("numpy==2.3.5", lines)
        self.assertNotIn("opencv-python-headless==4.10.0.84", lines)
        self.assertIn("pillow==12.3.0", lines)
        self.assertIn("setuptools==83.0.0", lines)
        self.assertIn("safetensors==0.7.0", lines)
        self.assertIn("huggingface_hub==1.14.0", lines)
        self.assertNotIn("transformers==5.8.1", lines)
        self.assertIn("einops==0.8.2", lines)
        self.assertIn("omegaconf==2.3.0", lines)
        self.assertNotIn("pycolmap==4.1.0", lines)
        self.assertIn("addict==2.4.0", lines)

        lock = (root / "requirements.txt").read_text(encoding="utf-8")
        for requirement in lines:
            name, version = requirement.split("==", maxsplit=1)
            normalized = name.replace("_", "-")
            self.assertIn(f"{normalized}=={version} \\", lock)
        self.assertIn("antlr4-python3-runtime==4.9.3 \\", lock)
        self.assertNotIn("opencv-python-headless", lock)
        self.assertNotIn("pycolmap", lock)
        self.assertNotIn("transformers==", lock)
        self.assertNotIn("==unknown", lock)
        self.assertGreaterEqual(lock.count("--hash=sha256:"), len(lines) + 1)

    def test_runtime_patch_removes_input_processor_opencv_dependency(self) -> None:
        root = Path(__file__).resolve().parents[1]
        patch = (root / "patches/da3-api-lazy-export.patch").read_text(
            encoding="utf-8"
        )

        self.assertIn("utils/io/input_processor.py", patch)
        self.assertIn("-import cv2", patch)
        self.assertNotIn("+import cv2", patch)
        self.assertEqual(patch.count("Image.Resampling.BICUBIC"), 3)
        self.assertEqual(patch.count("Image.Resampling.BOX"), 3)

    def test_continuous_planner_covers_large_inputs_exactly(self) -> None:
        for image_count in (30, 120, 250):
            batches = _plan_continuous_batches(image_count, window_size=8, overlap=3)
            flattened = {index for batch in batches for index in batch}
            self.assertEqual(flattened, set(range(image_count)))
            self.assertTrue(all(len(batch) <= 8 for batch in batches))
            for previous, current in zip(batches, batches[1:]):
                self.assertGreaterEqual(len(set(previous) & set(current)), 3)

    def test_constrained_continuous_planner_advances_two_views_per_full_batch(
        self,
    ) -> None:
        batches = _plan_continuous_batches(250, window_size=4, overlap=3)

        self.assertLessEqual(len(batches), 124)
        self.assertTrue(all(len(batch) <= 4 for batch in batches))
        for previous, current in zip(batches, batches[1:-1]):
            self.assertEqual(len(set(current) - set(previous)), 2)
            self.assertEqual(len(set(previous) & set(current)), 2)

    def test_constrained_continuous_seed_keeps_three_reference_anchors(self) -> None:
        centers = np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 1.0, 0.1],
                [2.0, 0.0, 0.1],
                [3.0, 1.0, 0.0],
            ]
        )

        class FakeModel:
            def inference(self, **kwargs):
                names = [Path(value).name for value in kwargs["image"]]
                poses = np.repeat(np.eye(4)[None, ...], len(names), axis=0)
                for local_index, name in enumerate(names):
                    image_index = int(name.removeprefix("img").removesuffix(".jpg"))
                    center = np.array(
                        [
                            float(image_index),
                            float(image_index % 2),
                            float((image_index * image_index) % 3) * 0.1,
                        ]
                    )
                    poses[local_index, :3, 3] = -center
                return {
                    "extrinsics": poses,
                    "intrinsics": np.repeat(np.eye(3)[None, ...], len(names), axis=0),
                    "depth": np.ones((len(names), 2, 2)),
                    "conf": np.ones((len(names), 2, 2)),
                }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "unused"),
                    "--input-ordering",
                    "continuous",
                    "--window-size",
                    "4",
                    "--window-overlap",
                    "3",
                    "--max-points",
                    "32",
                ]
            )
            for image_count in (5, 6, 7):
                images: list[Path] = []
                for index in range(image_count):
                    image = root / f"img{index}.jpg"
                    Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(image)
                    images.append(image)

                _, evidence = _run_da3_seed_refine(
                    args,
                    FakeModel(),
                    images,
                    "cpu",
                    root / f"seed-{image_count}" / "0",
                )

                anchors = evidence["anchor_indices"]
                first_batch = evidence["batches"][0]
                expected_local = _select_anchor_indices(centers)
                expected_global = [first_batch[index] for index in expected_local]
                self.assertEqual(len(anchors), 3)
                self.assertEqual(len(set(anchors)), 3)
                self.assertTrue(set(anchors).issubset(first_batch))
                self.assertEqual(anchors, expected_global)

    def test_seed_rejects_collinear_reference_anchors(self) -> None:
        class FakeModel:
            def inference(self, **kwargs):
                count = len(kwargs["image"])
                poses = np.repeat(np.eye(4)[None, ...], count, axis=0)
                poses[:, 0, 3] = -np.arange(count, dtype=np.float64)
                return {
                    "extrinsics": poses,
                    "intrinsics": np.repeat(np.eye(3)[None, ...], count, axis=0),
                    "depth": np.ones((count, 2, 2)),
                    "conf": np.ones((count, 2, 2)),
                }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(5):
                image = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8)).save(image)
                images.append(image)
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "unused"),
                    "--input-ordering",
                    "continuous",
                    "--window-size",
                    "4",
                    "--window-overlap",
                    "3",
                    "--max-points",
                    "32",
                ]
            )

            with self.assertRaisesRegex(ValueError, "non-collinear"):
                _run_da3_seed_refine(
                    args, FakeModel(), images, "cpu", root / "seed" / "0"
                )

    def test_unordered_planner_follows_chain_without_first_window_anchors(self) -> None:
        graph = {
            index: [
                neighbor for neighbor in (index - 1, index + 1) if 0 <= neighbor < 12
            ]
            for index in range(12)
        }
        batches = _plan_unordered_batches(
            12, window_size=4, neighbor_graph=graph, overlap=2
        )

        self.assertEqual(batches[0], [0, 1, 2, 3])
        self.assertEqual(batches[1], [2, 3, 4, 5])
        self.assertEqual(batches[2], [4, 5, 6, 7])
        self.assertTrue(set(batches[0]).isdisjoint(batches[2]))
        self.assertEqual(
            {index for batch in batches for index in batch}, set(range(12))
        )

    def test_unordered_planner_covers_large_inputs_with_bounded_calls(self) -> None:
        for image_count in (30, 120, 250):
            graph = {
                index: [
                    neighbor
                    for neighbor in (index - 1, index + 1)
                    if 0 <= neighbor < image_count
                ]
                for index in range(image_count)
            }
            batches = _plan_unordered_batches(
                image_count,
                window_size=4,
                neighbor_graph=graph,
                overlap=2,
            )
            flattened = {index for batch in batches for index in batch}
            self.assertEqual(flattened, set(range(image_count)))
            self.assertTrue(all(len(batch) <= 4 for batch in batches))
            self.assertLessEqual(len(batches), 1 + (image_count - 4 + 1) // 2)
            for previous, current in zip(batches, batches[1:]):
                self.assertGreaterEqual(len(set(previous) & set(current)), 2)

    def test_unordered_planner_rejects_disconnected_retrieval_graph(self) -> None:
        graph = {
            0: [1],
            1: [0, 2],
            2: [1],
            3: [4],
            4: [3, 5],
            5: [4],
        }

        with self.assertRaisesRegex(ValueError, "retrieval graph was disconnected"):
            _plan_unordered_batches(6, window_size=4, neighbor_graph=graph, overlap=2)

    def test_retrieval_graph_is_deterministic_and_rejects_unrelated_components(
        self,
    ) -> None:
        chain = np.array(
            [
                [1.0, 0.00, 0.0],
                [0.98, 0.20, 0.0],
                [0.92, 0.39, 0.0],
                [0.83, 0.56, 0.0],
            ]
        )
        first = _build_retrieval_graph(chain, max_neighbors=2, minimum_similarity=0.92)
        second = _build_retrieval_graph(chain, max_neighbors=2, minimum_similarity=0.92)
        self.assertEqual(first, second)

        disconnected = np.concatenate(
            [
                chain[:3],
                np.array([[0.0, 0.0, 1.0], [0.0, 0.2, 0.98], [0.0, 0.39, 0.92]]),
            ]
        )
        graph = _build_retrieval_graph(
            disconnected, max_neighbors=2, minimum_similarity=0.92
        )
        with self.assertRaisesRegex(ValueError, "retrieval graph was disconnected"):
            _plan_unordered_batches(6, window_size=4, neighbor_graph=graph, overlap=2)

    def test_image_descriptors_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = []
            for index, color in enumerate(
                ((240, 10, 10), (220, 20, 20), (10, 10, 240))
            ):
                path = root / f"img{index}.png"
                Image.new("RGB", (32, 24), color=color).save(path)
                paths.append(path)

            first = _compute_image_descriptors(paths)
            second = _compute_image_descriptors(paths)
            np.testing.assert_allclose(first, second, atol=0.0, rtol=0.0)
            self.assertEqual(first.shape[0], 3)

    def test_unordered_anchor_selection_rejects_collinear_centers(self) -> None:
        centers = np.array([[float(index), 0.0, 0.0] for index in range(8)])
        with self.assertRaisesRegex(ValueError, "non-collinear"):
            _select_anchor_indices(centers)

    def test_umeyama_recovers_known_sim3_and_transforms_w2c(self) -> None:
        angle = np.deg2rad(25.0)
        rotation = np.array(
            [
                [np.cos(angle), -np.sin(angle), 0.0],
                [np.sin(angle), np.cos(angle), 0.0],
                [0.0, 0.0, 1.0],
            ]
        )
        scale = 2.5
        translation = np.array([3.0, -4.0, 1.5])
        source = np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
                [0.0, 2.0, 0.0],
                [0.5, 0.5, 1.0],
            ]
        )
        target = (scale * (rotation @ source.T)).T + translation

        solved_scale, solved_rotation, solved_translation, normalized_rmse = (
            _estimate_sim3(source, target)
        )
        self.assertAlmostEqual(solved_scale, scale, places=8)
        np.testing.assert_allclose(solved_rotation, rotation, atol=1e-8)
        np.testing.assert_allclose(solved_translation, translation, atol=1e-8)
        self.assertLess(normalized_rmse, 1e-10)

        local_w2c = np.repeat(np.eye(4)[None, ...], source.shape[0], axis=0)
        local_w2c[:, :3, 3] = -source
        aligned = _align_w2c_poses(
            local_w2c, solved_scale, solved_rotation, solved_translation
        )
        aligned_centers = np.stack([-pose[:3, :3].T @ pose[:3, 3] for pose in aligned])
        np.testing.assert_allclose(aligned_centers, target, atol=1e-8)
        np.testing.assert_allclose(
            aligned[:, :3, :3], np.repeat(rotation.T[None, ...], 4, axis=0), atol=1e-8
        )

    def test_oriented_sim3_recovers_transform_from_two_views(self) -> None:
        angle = np.deg2rad(20.0)
        rotation = np.array(
            [
                [np.cos(angle), -np.sin(angle), 0.0],
                [np.sin(angle), np.cos(angle), 0.0],
                [0.0, 0.0, 1.0],
            ]
        )
        scale = 1.8
        translation = np.array([2.0, -1.0, 0.5])
        local_centers = np.array([[0.0, 0.0, 0.0], [2.0, 0.5, 0.0]])
        global_centers = (scale * (rotation @ local_centers.T)).T + translation
        local = np.repeat(np.eye(4)[None, ...], 2, axis=0)
        local[:, :3, 3] = -local_centers
        global_poses = np.repeat(np.eye(4)[None, ...], 2, axis=0)
        global_poses[:, :3, :3] = rotation.T
        global_poses[:, :3, 3] = np.stack(
            [-rotation.T @ center for center in global_centers]
        )

        solved_scale, solved_rotation, solved_translation, rmse = (
            _estimate_oriented_sim3(local, global_poses)
        )

        self.assertAlmostEqual(solved_scale, scale, places=8)
        np.testing.assert_allclose(solved_rotation, rotation, atol=1e-8)
        np.testing.assert_allclose(solved_translation, translation, atol=1e-8)
        self.assertLess(rmse, 1e-10)

    def test_oriented_sim3_uses_camera_baseline_when_rotations_are_noisy(self) -> None:
        local_centers = np.array([[0.0, 0.0, 0.0], [2.0, 0.0, 0.0]])
        target_centers = local_centers + np.array([3.0, -2.0, 1.0])
        angle = np.deg2rad(8.0)
        noisy_rotation = np.array(
            [
                [np.cos(angle), -np.sin(angle), 0.0],
                [np.sin(angle), np.cos(angle), 0.0],
                [0.0, 0.0, 1.0],
            ]
        )
        local = np.repeat(np.eye(4)[None, ...], 2, axis=0)
        local[:, :3, :3] = noisy_rotation
        local[:, :3, 3] = np.stack(
            [-noisy_rotation @ center for center in local_centers]
        )
        target = np.repeat(np.eye(4)[None, ...], 2, axis=0)
        target[:, :3, 3] = -target_centers

        scale, rotation, translation, rmse = _estimate_oriented_sim3(local, target)

        self.assertAlmostEqual(scale, 1.0, places=8)
        np.testing.assert_allclose(rotation, np.eye(3), atol=1e-8)
        np.testing.assert_allclose(translation, [3.0, -2.0, 1.0], atol=1e-8)
        self.assertLess(rmse, 1e-10)

    def test_umeyama_rejects_reflection_degenerate_nonfinite_and_high_rmse(
        self,
    ) -> None:
        source = np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
                [0.0, 1.0, 0.0],
                [0.0, 0.0, 1.0],
            ]
        )
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
        source_centers = np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 0.0, 0.0],
                [0.0, 1.0, 0.0],
            ]
        )
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
                np.array([[8.0, 0.0, 8.0], [0.0, 8.0, 6.0], [0.0, 0.0, 1.0]])[
                    None, ...
                ],
                4,
                axis=0,
            )
            sparse = root / "sparse" / "0"
            _write_seed_colmap(
                poses, intrinsics, images, sparse, "PINHOLE", shared_camera=False
            )

            pose_lines = [
                line
                for line in (sparse / "images.txt")
                .read_text(encoding="utf-8")
                .splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual(
                [int(line.split()[0]) for line in pose_lines], [1, 2, 3, 4]
            )
            self.assertEqual(
                [line.split(maxsplit=9)[-1] for line in pose_lines],
                [path.name for path in images],
            )
            image_lines = (
                (sparse / "images.txt").read_text(encoding="utf-8").splitlines()
            )
            for pose_line in pose_lines:
                self.assertEqual(image_lines[image_lines.index(pose_line) + 1], "")
            self.assertFalse(
                any(
                    line and not line.startswith("#")
                    for line in (sparse / "points3D.txt")
                    .read_text(encoding="utf-8")
                    .splitlines()
                )
            )

    def test_seed_export_writes_learned_points_as_untracked_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            image = root / "img.jpg"
            Image.new("RGB", (4, 4), color=(12, 34, 56)).save(image)
            sparse = root / "sparse" / "0"
            _write_seed_colmap(
                np.eye(4)[None, ...],
                np.array([[[2.0, 0.0, 2.0], [0.0, 2.0, 2.0], [0.0, 0.0, 1.0]]]),
                [image],
                sparse,
                "PINHOLE",
                shared_camera=False,
                learned_points=(
                    np.array([[1.0, 2.0, 3.0], [-1.0, 0.5, 2.0]]),
                    np.array([[12, 34, 56], [100, 110, 120]], dtype=np.uint8),
                ),
            )

            learned_rows = [
                line
                for line in (sparse / "learned_points3D.txt")
                .read_text(encoding="utf-8")
                .splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual(len(learned_rows), 2)
            self.assertEqual(
                learned_rows[0].split()[:8],
                ["1", "1.0", "2.0", "3.0", "12", "34", "56", "-1.0"],
            )
            self.assertFalse(
                any(
                    line and not line.startswith("#")
                    for line in (sparse / "points3D.txt")
                    .read_text(encoding="utf-8")
                    .splitlines()
                )
            )

    def test_depth_samples_use_confidence_and_world_pose(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            image = Path(temp_dir) / "image.png"
            pixels = np.zeros((2, 2, 3), dtype=np.uint8)
            pixels[0, 0] = [255, 0, 0]
            pixels[0, 1] = [0, 255, 0]
            pixels[1, 0] = [0, 0, 255]
            pixels[1, 1] = [255, 255, 255]
            Image.fromarray(pixels).save(image)
            w2c = np.eye(4)
            w2c[0, 3] = -10.0
            points, colors, confidence = _sample_depth_points(
                image,
                np.full((2, 2), 2.0),
                np.array([[10.0, 1.0], [9.0, 8.0]]),
                np.array([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]),
                w2c,
                maximum_samples=4,
                confidence_percentile=40.0,
            )

            self.assertEqual(points.shape, (2, 3))
            self.assertTrue(np.all(points[:, 0] >= 10.0))
            self.assertFalse(
                any(np.array_equal(color, [0, 255, 0]) for color in colors)
            )
            self.assertTrue(np.all(confidence >= 9.0))

    def test_depth_fusion_merges_duplicate_voxels_and_respects_cap(self) -> None:
        points, colors = _fuse_depth_points(
            np.array([[0.01, 0.01, 0.01], [0.02, 0.02, 0.02], [1.0, 1.0, 1.0]]),
            np.array([[255, 0, 0], [0, 0, 255], [0, 255, 0]], dtype=np.uint8),
            np.array([1.0, 3.0, 2.0]),
            maximum_points=2,
            voxel_size=0.1,
        )

        self.assertEqual(points.shape, (2, 3))
        merged_index = int(np.argmin(np.linalg.norm(points, axis=1)))
        np.testing.assert_allclose(points[merged_index], [0.0175, 0.0175, 0.0175])
        np.testing.assert_array_equal(colors[merged_index], [64, 0, 191])

    def test_seed_export_rejects_missing_prediction_view_instead_of_padding(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(4):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8)).save(path)
                images.append(path)
            with self.assertRaisesRegex(
                ValueError, "pose count 3 did not match image count 4"
            ):
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
            "lower_off_diagonal": np.array(
                [[2.0, 0.0, 1.0], [0.2, 2.0, 1.0], [0.0, 0.0, 1.0]]
            ),
            "bottom_row": np.array([[2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.1, 0.0, 1.0]]),
            "non_unit_homogeneous": np.array(
                [[2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 2.0]]
            ),
            "negative_focal": np.array(
                [[-2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]]
            ),
            "nonfinite_principal_point": np.array(
                [[2.0, 0.0, np.nan], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]]
            ),
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
        intrinsics = np.array(
            [
                [1e308, 0.0, 1.0],
                [0.0, 1e308, 1.0],
                [0.0, 0.0, 1.0],
            ]
        )
        with self.assertRaisesRegex(ValueError, "scaled camera parameters"):
            _camera_params(
                intrinsics,
                (16, 12),
                "PINHOLE",
                source_size=(1, 1),
            )

    def test_camera_params_supports_colmap_fisheye_schema(self) -> None:
        intrinsics = np.array(
            [
                [500.0, 0.0, 320.0],
                [0.0, 490.0, 240.0],
                [0.0, 0.0, 1.0],
            ]
        )

        self.assertEqual(
            _camera_params(intrinsics, (640, 480), "OPENCV_FISHEYE"),
            [500.0, 490.0, 320.0, 240.0, 0.0, 0.0, 0.0, 0.0],
        )
        self.assertEqual(
            build_arg_parser()
            .parse_args(
                [
                    "--images",
                    "/tmp/images",
                    "--out-sparse",
                    "/tmp/sparse",
                    "--camera-type",
                    "OPENCV_FISHEYE",
                ]
            )
            .camera_type,
            "OPENCV_FISHEYE",
        )

    def test_rotmat_to_quat_handles_negative_trace_rotation(self) -> None:
        quat = _rotmat_to_quat_wxyz(
            np.array(
                [
                    [1.0, 0.0, 0.0],
                    [0.0, -1.0, 0.0],
                    [0.0, 0.0, -1.0],
                ]
            )
        )
        np.testing.assert_allclose(np.abs(quat), np.array([0.0, 1.0, 0.0, 0.0]))

    def test_seed_manifest_records_complete_alignment_and_learned_points(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "da3_coverage_manifest.json"
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "sparse" / "0"),
                    "--models-dir",
                    str(root / "models"),
                    "--input-ordering",
                    "unordered",
                    "--window-size",
                    "6",
                    "--window-overlap",
                    "3",
                ]
            )
            image_paths = [Path(f"img{index}.jpg") for index in range(10)]
            batches = [list(range(6)), [0, 2, 5, 6, 7, 8], [0, 2, 5, 9]]
            _write_manifest(
                manifest,
                args=args,
                image_paths=image_paths,
                selected_device="mps",
                model_subdir="DA3-BASE",
                registered_image_count=10,
                alignment_evidence={
                    "batches": batches,
                    "anchor_indices": [0, 2, 5],
                    "alignment_edge_count": 2,
                    "max_alignment_rmse": 0.012,
                    "alignment_complete": True,
                    "raw_point_sample_count": 20_000,
                    "fused_sparse_point_count": 12_000,
                },
            )
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["export_strategy"], "aligned_pose_depth_seed")
            self.assertFalse(payload["native_colmap_export"])
            self.assertEqual(payload["input_ordering"], "unordered")
            self.assertEqual(
                payload["anchor_image_names"], ["img0.jpg", "img2.jpg", "img5.jpg"]
            )
            self.assertEqual(payload["alignment_edge_count"], 2)
            self.assertTrue(payload["alignment_complete"])
            self.assertEqual(payload["raw_point_sample_count"], 20_000)
            self.assertEqual(payload["fused_sparse_point_count"], 12_000)
            self.assertNotIn("final_observation_count", payload)

    def test_main_rejects_a_second_inference_window_before_loading_a_model(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            images.mkdir()
            for index in range(30):
                Image.new("RGB", (8, 8)).save(images / f"img{index:02d}.jpg")

            with mock.patch("easysplat_da3_sfm.run._select_device") as select_device:
                with mock.patch("easysplat_da3_sfm.run._run_da3_model") as run_model:
                    with self.assertRaisesRegex(
                        SystemExit,
                        "one coherent batch of at most 29 images",
                    ):
                        main(
                            [
                                "--images",
                                str(images),
                                "--out-sparse",
                                str(root / "sparse" / "0"),
                                "--models-dir",
                                str(root / "models"),
                                "--window-size",
                                "29",
                                "--window-overlap",
                                "0",
                            ]
                        )

            select_device.assert_not_called()
            run_model.assert_not_called()

    def test_main_oom_does_not_switch_models_or_publish_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            out_sparse = root / "sparse" / "0"
            manifest = root / "da3_coverage_manifest.json"
            images.mkdir()
            for index in range(4):
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(
                    images / f"img{index}.jpg"
                )
            for model_name in ["DA3-BASE", "DA3-SMALL"]:
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            calls: list[Path] = []

            def fake_run(args, image_paths, model_dir, selected_device, sparse_path):
                calls.append(model_dir)
                self.assertEqual(selected_device, "mps")
                self.assertEqual(len(image_paths), 4)
                self.assertEqual(sparse_path, out_sparse)
                self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
                self.assertEqual(os.environ["TRANSFORMERS_OFFLINE"], "1")
                self.assertEqual(os.environ["HF_HUB_DISABLE_TELEMETRY"], "1")
                self.assertEqual(os.environ["DO_NOT_TRACK"], "1")
                self.assertEqual(os.environ["PYTORCH_ENABLE_MPS_FALLBACK"], "0")
                sparse_path.mkdir(parents=True)
                (sparse_path / "partial.txt").write_text("partial", encoding="utf-8")
                manifest.write_text("partial", encoding="utf-8")
                raise RuntimeError("MPS backend out of memory")

            with mock.patch(
                "easysplat_da3_sfm.run._run_da3_model", side_effect=fake_run
            ), mock.patch(
                "easysplat_da3_sfm.run._select_device", return_value="mps"
            ):
                with mock.patch.dict(os.environ, {}, clear=True):
                    with self.assertRaisesRegex(RuntimeError, "out of memory"):
                        main(
                            [
                                "--images",
                                str(images),
                                "--out-sparse",
                                str(out_sparse),
                                "--models-dir",
                                str(models),
                                "--manifest-out",
                                str(manifest),
                                "--device",
                                "mps",
                            ]
                        )

            self.assertEqual([call.name for call in calls], ["DA3-BASE"])
            self.assertFalse(out_sparse.exists())
            self.assertFalse(manifest.exists())

    def test_main_runs_explicit_small_model_as_the_only_model(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            out_sparse = root / "sparse" / "0"
            manifest = root / "da3_coverage_manifest.json"
            images.mkdir()
            for index in range(4):
                Image.new("RGB", (8, 8)).save(images / f"img{index}.jpg")
            for model_name in ("DA3-BASE", "DA3-SMALL"):
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            attempts: list[str] = []

            def fake_run(args, image_paths, model_dir, selected_device, sparse_path):
                attempts.append(model_dir.name)
                sparse_path.mkdir(parents=True)
                for name in ("cameras.txt", "images.txt", "points3D.txt"):
                    (sparse_path / name).write_text("# empty\n", encoding="utf-8")
                return len(image_paths), {
                    "batches": [list(range(4))],
                    "anchor_indices": [0, 1, 2],
                    "alignment_edge_count": 0,
                    "max_alignment_rmse": 0.0,
                    "alignment_complete": True,
                    "raw_point_sample_count": 16,
                    "fused_sparse_point_count": 8,
                }

            with mock.patch(
                "easysplat_da3_sfm.run._run_da3_model", side_effect=fake_run
            ), mock.patch(
                "easysplat_da3_sfm.run._select_device", return_value="mps"
            ):
                exit_code = main(
                    [
                        "--images",
                        str(images),
                        "--out-sparse",
                        str(out_sparse),
                        "--models-dir",
                        str(models),
                        "--device",
                        "mps",
                        "--model-subdir",
                        "DA3-SMALL",
                        "--input-ordering",
                        "continuous",
                        "--window-size",
                        "4",
                        "--window-overlap",
                        "3",
                        "--manifest-out",
                        str(manifest),
                    ]
                )

            self.assertEqual(exit_code, 0)
            self.assertEqual(attempts, ["DA3-SMALL"])
            payload = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(payload["model_subdir"], "DA3-SMALL")
            self.assertNotIn("fallback_model_subdir", payload)
            self.assertEqual(payload["export_strategy"], "aligned_pose_depth_seed")

    def test_main_does_not_retry_non_memory_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = root / "images"
            models = root / "models"
            images.mkdir()
            for index in range(4):
                Image.new("RGB", (8, 8), color=(index * 10, 0, 0)).save(
                    images / f"img{index}.jpg"
                )
            for model_name in ["DA3-BASE", "DA3-SMALL"]:
                model = models / model_name
                model.mkdir(parents=True)
                (model / "config.json").write_text("{}", encoding="utf-8")
                (model / "model.safetensors").write_bytes(b"0")

            with mock.patch(
                "easysplat_da3_sfm.run._run_da3_model",
                side_effect=RuntimeError("bad geometry"),
            ) as run_mock, mock.patch(
                "easysplat_da3_sfm.run._select_device", return_value="mps"
            ):
                with self.assertRaisesRegex(RuntimeError, "bad geometry"):
                    main(
                        [
                            "--images",
                            str(images),
                            "--out-sparse",
                            str(root / "sparse" / "0"),
                            "--models-dir",
                            str(models),
                            "--device",
                            "mps",
                        ]
                    )

            self.assertEqual(run_mock.call_count, 1)

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
                index: np.array(
                    [
                        float(index % 3),
                        float(index // 3),
                        float((index * index) % 5) * 0.1,
                    ]
                )
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
                    local_to_global_rotation = np.array(
                        [
                            [np.cos(angle), -np.sin(angle), 0.0],
                            [np.sin(angle), np.cos(angle), 0.0],
                            [0.0, 0.0, 1.0],
                        ]
                    )
                    scale = 1.0 if call_index == 0 else 1.0 + 0.2 * call_index
                    translation = np.array(
                        [0.3 * call_index, -0.2 * call_index, 0.1 * call_index]
                    )
                    poses = []
                    for name in names:
                        image_index = int(name.removeprefix("img").removesuffix(".jpg"))
                        center = global_centers[image_index]
                        local_center = local_to_global_rotation.T @ (
                            (center - translation) / scale
                        )
                        pose = np.eye(4)
                        pose[:3, :3] = local_to_global_rotation
                        pose[:3, 3] = -local_to_global_rotation @ local_center
                        poses.append(pose)
                    return {
                        "extrinsics": np.stack(poses),
                        "intrinsics": np.repeat(
                            np.eye(3)[None, ...], len(names), axis=0
                        ),
                        "depth": np.ones((len(names), 2, 2)),
                        "conf": np.ones((len(names), 2, 2)),
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
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "seed" / "0"),
                    "--models-dir",
                    str(model_dir.parent),
                    "--input-ordering",
                    "continuous",
                    "--window-size",
                    "4",
                    "--window-overlap",
                    "3",
                ]
            )

            with mock.patch.dict(
                sys.modules,
                {
                    "depth_anything_3": depth_anything_module,
                    "depth_anything_3.api": api_module,
                },
            ):
                registered, evidence = _run_da3_model(
                    args,
                    images,
                    model_dir,
                    "cpu",
                    root / "seed" / "0",
                )

            self.assertEqual(load_count, 1)
            self.assertEqual(len(inference_calls), 3)
            self.assertEqual(registered, 7)
            self.assertEqual(evidence["alignment_edge_count"], 2)
            self.assertTrue(evidence["alignment_complete"])
            self.assertLess(evidence["max_alignment_rmse"], 1e-8)
            image_lines = [
                line
                for line in (root / "seed" / "0" / "images.txt")
                .read_text(encoding="utf-8")
                .splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual(len(image_lines), 7)

    def test_seed_refine_avoids_mutating_colmap_export_and_scales_intrinsics_once(
        self,
    ) -> None:
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
                    centers = np.array(
                        [
                            [0.0, 0.0, 0.0],
                            [1.0, 0.0, 0.0],
                            [0.0, 1.0, 0.0],
                            [1.0, 1.0, 0.0],
                        ]
                    )
                    poses = np.repeat(np.eye(4)[None, ...], count, axis=0)
                    poses[:, :3, 3] = -centers[:count]
                    intrinsics = np.repeat(
                        np.array([[2.0, 0.0, 1.0], [0.0, 2.0, 1.0], [0.0, 0.0, 1.0]])[
                            None, ...
                        ],
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
                        "conf": np.ones((count, 2, 2)),
                    }

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "seed" / "0"),
                    "--models-dir",
                    str(model_dir.parent),
                    "--input-ordering",
                    "continuous",
                    "--window-size",
                    "4",
                    "--window-overlap",
                    "3",
                ]
            )
            with mock.patch.dict(
                sys.modules,
                {
                    "depth_anything_3": depth_anything_module,
                    "depth_anything_3.api": api_module,
                },
            ):
                result = _run_da3_model(
                    args, images, model_dir, "cpu", root / "seed" / "0"
                )

            self.assertEqual(len(captured_kwargs), 1)
            self.assertNotIn("export_dir", captured_kwargs[0])
            self.assertNotIn("export_format", captured_kwargs[0])
            alignment_evidence = result[-1]
            self.assertIsNotNone(alignment_evidence)
            self.assertEqual(len(alignment_evidence["anchor_indices"]), 3)
            camera_row = next(
                line
                for line in (root / "seed" / "0" / "cameras.txt")
                .read_text(encoding="utf-8")
                .splitlines()
                if line and not line.startswith("#")
            )
            self.assertEqual(
                [float(value) for value in camera_row.split()[4:]], [8.0, 8.0, 4.0, 4.0]
            )

    def test_seed_refine_single_batch_accepts_collinear_camera_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(5):
                path = root / f"img{index}.jpg"
                Image.new("RGB", (8, 8), color=(index * 20, 0, 0)).save(path)
                images.append(path)

            class FakeModel:
                def inference(self, **kwargs):
                    count = len(kwargs["image"])
                    poses = np.repeat(np.eye(4)[None, ...], count, axis=0)
                    poses[:, 0, 3] = -np.arange(count, dtype=np.float64)
                    intrinsics = np.repeat(
                        np.array(
                            [[4.0, 0.0, 1.0], [0.0, 4.0, 1.0], [0.0, 0.0, 1.0]]
                        )[None, ...],
                        count,
                        axis=0,
                    )
                    return {
                        "extrinsics": poses,
                        "intrinsics": intrinsics,
                        "depth": np.ones((count, 2, 2)),
                        "conf": np.ones((count, 2, 2)),
                    }

            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "seed" / "0"),
                    "--input-ordering",
                    "continuous",
                    "--window-size",
                    "5",
                    "--window-overlap",
                    "3",
                ]
            )

            registered, evidence = _run_da3_seed_refine(
                args,
                FakeModel(),
                images,
                "cpu",
                root / "seed" / "0",
            )

            self.assertEqual(registered, 5)
            self.assertEqual(evidence["batches"], [[0, 1, 2, 3, 4]])
            self.assertEqual(evidence["anchor_indices"], [0, 2, 4])
            self.assertEqual(evidence["alignment_edge_count"], 0)

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
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "seed" / "0"),
                    "--models-dir",
                    str(model_dir.parent),
                    "--input-ordering",
                    "continuous",
                    "--window-size",
                    "4",
                    "--window-overlap",
                    "3",
                ]
            )
            with mock.patch.dict(
                sys.modules,
                {
                    "depth_anything_3": depth_anything_module,
                    "depth_anything_3.api": api_module,
                },
            ):
                with self.assertRaisesRegex(
                    ValueError, "pose count 3 did not match image count 4"
                ):
                    _run_da3_model(args, images, model_dir, "cpu", root / "seed" / "0")

    def test_run_da3_model_moves_model_to_selected_device(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            images = []
            for index in range(4):
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
                    poses = np.repeat(np.eye(4, dtype=np.float32)[None, ...], 4, axis=0)
                    poses[:, :3, 3] = -np.array(
                        [
                            [0.0, 0.0, 0.0],
                            [1.0, 0.0, 0.0],
                            [0.0, 1.0, 0.0],
                            [1.0, 1.0, 0.0],
                        ]
                    )
                    return types.SimpleNamespace(
                        extrinsics=poses,
                        intrinsics=np.repeat(
                            np.eye(3, dtype=np.float32)[None, ...], 4, axis=0
                        ),
                        depth=np.ones((4, 2, 2), dtype=np.float32),
                        conf=np.ones((4, 2, 2), dtype=np.float32),
                    )

            class FakeDepthAnything3:
                @staticmethod
                def from_pretrained(path, local_files_only=False):
                    return FakeModel()

            depth_anything_module = types.ModuleType("depth_anything_3")
            api_module = types.ModuleType("depth_anything_3.api")
            api_module.DepthAnything3 = FakeDepthAnything3
            args = build_arg_parser().parse_args(
                [
                    "--images",
                    str(root),
                    "--out-sparse",
                    str(root / "sparse" / "0"),
                    "--models-dir",
                    str(model_dir.parent),
                ]
            )

            with mock.patch.dict(
                sys.modules,
                {
                    "depth_anything_3": depth_anything_module,
                    "depth_anything_3.api": api_module,
                },
            ):
                registered, _ = _run_da3_model(
                    args, images, model_dir, "mps", root / "sparse" / "0"
                )

            self.assertEqual(devices, ["mps"])
            self.assertEqual(registered, 4)


if __name__ == "__main__":
    unittest.main()
