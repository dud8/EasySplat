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
    _colmap_text_stats,
    _default_models_dir,
    _list_images,
    _model_path,
    _plan_windows,
    _rotmat_to_quat_wxyz,
    _run_da3_export,
    _select_device,
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

    def test_parser_rejects_seed_refine_until_supported(self) -> None:
        parser = build_arg_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([
                "--images", "images",
                "--out-sparse", "sparse/0",
                "--models-dir", "models",
                "--mode", "seed_refine",
            ])

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
                return 7, 14, 2.0, 2

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
                point_count, observation_count, mean_track_length, registered_count = _run_da3_export(
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
