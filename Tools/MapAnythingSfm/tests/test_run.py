from __future__ import annotations

import argparse
import json
import os
import tempfile
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest import mock

import numpy as np
import torch

from easysplat_mapanything_sfm.run import (
    _build_camera_params,
    _camera_centers_from_extrinsics_w2c,
    _default_models_dir,
    _downsample_paths_uniform,
    _estimate_similarity_from_overlap,
    _fuse_point_samples,
    _install_offline_dinov2_loader,
    _normalize_resolution_set,
    _plan_windows,
    _replace_output_dir_atomically,
    _transform_extrinsics_w2c,
    _transform_points_xyz,
    _validate_args,
    _write_manifest,
    _write_colmap_text_model,
    build_arg_parser,
)


class MapAnythingRunTests(unittest.TestCase):
    def test_downsample_paths_uniform_preserves_endpoints(self) -> None:
        paths = [Path(f"frame_{index:03d}.jpg") for index in range(10)]
        selected = _downsample_paths_uniform(paths, target_count=4)
        self.assertEqual(selected[0], paths[0])
        self.assertEqual(selected[-1], paths[-1])
        self.assertEqual(len(selected), 4)

    def test_plan_windows_uses_overlap_stride(self) -> None:
        self.assertEqual(_plan_windows(8, window_size=4, window_overlap=1), [(0, 4), (3, 7), (6, 8)])

    def test_build_camera_params_supports_simple_radial(self) -> None:
        intrinsics = np.array([[300.0, 0.0, 150.0], [0.0, 290.0, 120.0], [0.0, 0.0, 1.0]])
        params = _build_camera_params(
            intrinsics,
            original_size=(1200, 900),
            processed_size=(600, 450),
            camera_type="SIMPLE_RADIAL",
        )
        self.assertEqual(len(params), 4)
        self.assertAlmostEqual(params[0], 590.0)
        self.assertAlmostEqual(params[1], 600.0)
        self.assertAlmostEqual(params[2], 450.0)
        self.assertAlmostEqual(params[3], 0.0)

    def test_normalize_resolution_set_clamps_to_supported_values(self) -> None:
        self.assertEqual(_normalize_resolution_set(518), 518)
        self.assertEqual(_normalize_resolution_set(512), 512)
        self.assertEqual(_normalize_resolution_set(500), 512)
        self.assertEqual(_normalize_resolution_set(999), 518)

    def test_write_colmap_text_model_emits_expected_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            out_dir = Path(temp_dir) / "sparse" / "0"
            image_paths = [Path("a.jpg"), Path("b.jpg")]
            extrinsics = np.repeat(np.eye(4)[None, ...], repeats=2, axis=0)
            intrinsics = np.repeat(np.eye(3)[None, ...], repeats=2, axis=0)
            points_xyz = np.array([[0.0, 0.0, 1.0]], dtype=np.float32)
            points_rgb = np.array([[255, 128, 64]], dtype=np.uint8)

            _write_colmap_text_model(
                out_dir=out_dir,
                image_paths=image_paths,
                extrinsics_w2c=extrinsics,
                intrinsics_3x3=intrinsics,
                original_sizes_wh=[(100, 80), (100, 80)],
                processed_sizes_wh=[(50, 40), (50, 40)],
                camera_type="SIMPLE_RADIAL",
                shared_camera=False,
                points_xyz=points_xyz,
                points_rgb=points_rgb,
                point_tracks=[[(0, np.array([10.0, 5.0], dtype=np.float32))]],
            )

            self.assertTrue((out_dir / "cameras.txt").exists())
            self.assertTrue((out_dir / "images.txt").exists())
            self.assertTrue((out_dir / "points3D.txt").exists())
            images_text = (out_dir / "images.txt").read_text(encoding="utf-8")
            self.assertIn("a.jpg", images_text)
            self.assertIn("b.jpg", images_text)
            self.assertIn("21.0 11.0 1", images_text)
            points_text = (out_dir / "points3D.txt").read_text(encoding="utf-8")
            self.assertIn("1 0", points_text)

    def test_write_colmap_text_model_downgrades_shared_camera_when_sizes_differ(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            out_dir = Path(temp_dir) / "sparse" / "0"
            image_paths = [Path("a.jpg"), Path("b.jpg")]
            extrinsics = np.repeat(np.eye(4)[None, ...], repeats=2, axis=0)
            intrinsics = np.repeat(np.eye(3)[None, ...], repeats=2, axis=0)

            _write_colmap_text_model(
                out_dir=out_dir,
                image_paths=image_paths,
                extrinsics_w2c=extrinsics,
                intrinsics_3x3=intrinsics,
                original_sizes_wh=[(100, 80), (120, 80)],
                processed_sizes_wh=[(50, 40), (60, 40)],
                camera_type="SIMPLE_RADIAL",
                shared_camera=True,
                points_xyz=np.array([[0.0, 0.0, 1.0]], dtype=np.float32),
                points_rgb=np.array([[255, 255, 255]], dtype=np.uint8),
                point_tracks=[[(0, np.array([4.0, 4.0], dtype=np.float32))]],
            )

            cameras_lines = [
                line
                for line in (out_dir / "cameras.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]
            self.assertEqual(len(cameras_lines), 2)

    def test_validate_args_rejects_invalid_seed_refine_overlap(self) -> None:
        args = argparse.Namespace(
            minibatch_size=1,
            max_points=10,
            camera_type="SIMPLE_RADIAL",
            mode="seed_refine",
            anchor_max_views=4,
            window_size=4,
            window_overlap=4,
        )
        with self.assertRaisesRegex(ValueError, "window-overlap"):
            _validate_args(args, image_count=4)

    def test_validate_args_requires_at_least_two_images(self) -> None:
        args = argparse.Namespace(
            minibatch_size=1,
            max_points=10,
            camera_type="SIMPLE_RADIAL",
            mode="direct",
            anchor_max_views=4,
            window_size=4,
            window_overlap=1,
        )
        with self.assertRaisesRegex(ValueError, "at least 2 supported images"):
            _validate_args(args, image_count=1)

    def test_write_manifest_records_effective_window_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "coverage.json"
            anchor_paths = [Path("a.jpg"), Path("b.jpg"), Path("c.jpg")]
            _write_manifest(
                manifest_path,
                mode="seed_refine",
                requested_device="mps",
                selected_device="cpu",
                resolution=518,
                camera_type="SIMPLE_RADIAL",
                shared_camera=True,
                seed=42,
                max_points=120000,
                total_images=9,
                anchor_paths=anchor_paths,
                windows=[(0, 2), (1, 3)],
                requested_window_size=6,
                requested_window_overlap=2,
                window_size=3,
                window_overlap=1,
                window_reduction_count=2,
            )

            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["mode"], "seed_refine")
            self.assertEqual(payload["requested_device"], "mps")
            self.assertEqual(payload["selected_device"], "cpu")
            self.assertEqual(payload["window_size"], 3)
            self.assertEqual(payload["requested_window_size"], 6)
            self.assertEqual(payload["window_reduction_count"], 2)
            self.assertEqual(payload["anchors"], ["a.jpg", "b.jpg", "c.jpg"])
            self.assertEqual(payload["windows"][1]["images"], ["b.jpg", "c.jpg"])

    def test_write_manifest_records_final_sparse_stats_when_available(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "coverage.json"
            anchor_paths = [Path("a.jpg"), Path("b.jpg")]
            _write_manifest(
                manifest_path,
                mode="direct",
                requested_device="mps",
                selected_device="mps",
                resolution=518,
                camera_type="SIMPLE_RADIAL",
                shared_camera=False,
                seed=42,
                max_points=120000,
                total_images=2,
                anchor_paths=anchor_paths,
                windows=[(0, 2)],
                requested_window_size=2,
                requested_window_overlap=0,
                window_size=2,
                window_overlap=0,
                window_reduction_count=0,
                raw_point_sample_count=1000,
                fused_sparse_point_count=400,
                final_observation_count=620,
                mean_track_length=1.55,
                registered_image_count=2,
            )

            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["raw_point_sample_count"], 1000)
            self.assertEqual(payload["fused_sparse_point_count"], 400)
            self.assertEqual(payload["final_observation_count"], 620)
            self.assertAlmostEqual(payload["mean_track_length"], 1.55)
            self.assertEqual(payload["registered_image_count"], 2)

    def test_replace_output_dir_atomically_replaces_stale_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            existing = root / "sparse" / "0"
            staging = root / "staging"
            existing.mkdir(parents=True)
            staging.mkdir(parents=True)
            (existing / "old.txt").write_text("old", encoding="utf-8")
            (staging / "new.txt").write_text("new", encoding="utf-8")

            _replace_output_dir_atomically(staging, existing)

            self.assertFalse((existing / "old.txt").exists())
            self.assertEqual((existing / "new.txt").read_text(encoding="utf-8"), "new")

    def test_fuse_point_samples_merges_cross_view_duplicates(self) -> None:
        points_xyz = np.array(
            [
                [0.0, 0.0, 1.0],
                [0.0004, -0.0003, 1.0002],
                [2.0, 0.0, 1.0],
            ],
            dtype=np.float32,
        )
        points_rgb = np.array(
            [
                [255, 0, 0],
                [250, 10, 0],
                [0, 255, 0],
            ],
            dtype=np.uint8,
        )
        point_image_indices = np.array([0, 1, 2], dtype=np.int32)
        point_xys_processed = np.array(
            [
                [10.0, 10.0],
                [12.0, 10.0],
                [5.0, 7.0],
            ],
            dtype=np.float32,
        )
        point_confidences = np.array([0.9, 0.8, 0.7], dtype=np.float32)

        fused_xyz, fused_rgb, fused_tracks = _fuse_point_samples(
            points_xyz=points_xyz,
            points_rgb=points_rgb,
            point_image_indices=point_image_indices,
            point_xys_processed=point_xys_processed,
            point_confidences=point_confidences,
            max_points=8,
        )

        self.assertEqual(fused_xyz.shape[0], 2)
        self.assertEqual(fused_rgb.shape[0], 2)
        self.assertEqual(len(fused_tracks), 2)
        self.assertEqual(sorted(len(track) for track in fused_tracks), [1, 2])

    def test_default_models_dir_prefers_environment_override(self) -> None:
        with mock.patch.dict(os.environ, {"EASYSPLAT_MAPANYTHING_MODELS_DIR": "/tmp/models"}, clear=False):
            self.assertEqual(_default_models_dir(), "/tmp/models")

    def test_arg_parser_accepts_coverage_manifest_alias(self) -> None:
        with mock.patch.dict(os.environ, {"EASYSPLAT_MAPANYTHING_MODELS_DIR": "/tmp/models"}, clear=False):
            parser = build_arg_parser()
            args = parser.parse_args(
                [
                    "--images", "/tmp/images",
                    "--out-sparse", "/tmp/sparse/0",
                    "--coverage-manifest", "/tmp/coverage.json",
                ]
            )

        self.assertEqual(args.models_dir, "/tmp/models")
        self.assertEqual(args.manifest_out, "/tmp/coverage.json")
        self.assertTrue(args.memory_efficient_inference)

    def test_arg_parser_allows_disabling_memory_efficient_inference(self) -> None:
        with mock.patch.dict(os.environ, {"EASYSPLAT_MAPANYTHING_MODELS_DIR": "/tmp/models"}, clear=False):
            parser = build_arg_parser()
            args = parser.parse_args(
                [
                    "--images", "/tmp/images",
                    "--out-sparse", "/tmp/sparse/0",
                    "--no-memory-efficient-inference",
                ]
            )

        self.assertFalse(args.memory_efficient_inference)

    def test_offline_dinov2_loader_intercepts_torch_hub_and_restores(self) -> None:
        original_hub_load = torch.hub.load
        original_state_dict_loader = torch.hub.load_state_dict_from_url

        sentinel = object()

        def fake_builder(*args, **kwargs):
            return {"builder_args": args, "builder_kwargs": kwargs, "sentinel": sentinel}

        with mock.patch("importlib.import_module", return_value=SimpleNamespace(dinov2_vitg14=fake_builder)):
            restore = _install_offline_dinov2_loader(Path("/tmp/dinov2"))
            try:
                loaded = torch.hub.load("facebookresearch/dinov2", "dinov2_vitg14", pretrained=True)
                self.assertIs(loaded["sentinel"], sentinel)
                self.assertEqual(loaded["builder_kwargs"]["pretrained"], True)
            finally:
                restore()

        self.assertIs(torch.hub.load, original_hub_load)
        self.assertIs(torch.hub.load_state_dict_from_url, original_state_dict_loader)

    def test_overlap_similarity_alignment_recovers_known_transform(self) -> None:
        def extrinsic_from_center(center: np.ndarray, rotation: np.ndarray) -> np.ndarray:
            extrinsic = np.eye(4, dtype=np.float64)
            extrinsic[:3, :3] = rotation
            extrinsic[:3, 3] = -(rotation @ center)
            return extrinsic

        rotation_align = np.array(
            [
                [0.0, -1.0, 0.0],
                [1.0, 0.0, 0.0],
                [0.0, 0.0, 1.0],
            ],
            dtype=np.float64,
        )
        scale = 2.5
        translation = np.array([3.0, -2.0, 0.5], dtype=np.float64)
        global_centers = np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 0.5, 0.0],
            ],
            dtype=np.float64,
        )
        chunk_centers = np.stack(
            [rotation_align.T @ ((center - translation) / scale) for center in global_centers],
            axis=0,
        )

        chunk_extrinsics = np.stack(
            [extrinsic_from_center(center, rotation_align) for center in chunk_centers],
            axis=0,
        )
        global_extrinsics = np.stack(
            [extrinsic_from_center(center, np.eye(3, dtype=np.float64)) for center in global_centers],
            axis=0,
        )

        est_scale, est_rotation, est_translation = _estimate_similarity_from_overlap(
            chunk_extrinsics,
            global_extrinsics,
        )
        transformed_extrinsics = _transform_extrinsics_w2c(
            chunk_extrinsics,
            scale=est_scale,
            rotation_align=est_rotation,
            translation_align=est_translation,
        )
        transformed_points = _transform_points_xyz(
            np.array([[[1.0, 2.0, 3.0]]], dtype=np.float64),
            scale=est_scale,
            rotation_align=est_rotation,
            translation_align=est_translation,
        )

        np.testing.assert_allclose(
            _camera_centers_from_extrinsics_w2c(transformed_extrinsics),
            global_centers,
            atol=1e-6,
        )
        np.testing.assert_allclose(
            transformed_extrinsics[:, :3, :3],
            np.repeat(np.eye(3)[None, ...], repeats=2, axis=0),
            atol=1e-6,
        )
        np.testing.assert_allclose(
            transformed_points,
            np.array([[[-2.0, 0.5, 8.0]]], dtype=np.float64),
            atol=1e-6,
        )


if __name__ == "__main__":
    unittest.main()
