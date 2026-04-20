import tempfile
import unittest
from pathlib import Path

import numpy as np

from easysplat_vggt_sfm.run import (
    _list_images,
    _rotmat_to_quat_wxyz,
    _supported_image_exts,
    _torch_dtype_for_device,
    _write_colmap_text_model,
)


class VggtRunTests(unittest.TestCase):
    def test_supported_image_exts_are_stable(self):
        self.assertEqual(_supported_image_exts(), {".jpg", ".jpeg", ".png"})

    def test_list_images_filters_and_sorts_supported_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "b.png").write_bytes(b"b")
            (root / "a.jpg").write_bytes(b"a")
            (root / "ignore.txt").write_text("x", encoding="utf-8")

            self.assertEqual([path.name for path in _list_images(root)], ["a.jpg", "b.png"])

    def test_rotmat_to_quat_normalizes_identity_rotation(self):
        quat = _rotmat_to_quat_wxyz(np.eye(3, dtype=np.float32))
        self.assertAlmostEqual(float(quat[0]), 1.0)
        self.assertAlmostEqual(float(np.linalg.norm(quat)), 1.0)

    def test_torch_dtype_for_cpu_defaults_to_float32(self):
        import torch

        self.assertEqual(_torch_dtype_for_device(torch.device("cpu")), torch.float32)

    def test_write_colmap_text_model_emits_expected_files(self):
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
                vggt_resolution=64,
                points_xyz=points_xyz,
                points_rgb=points_rgb,
            )

            self.assertTrue((out_dir / "cameras.txt").exists())
            self.assertTrue((out_dir / "images.txt").exists())
            self.assertTrue((out_dir / "points3D.txt").exists())
            self.assertIn("a.jpg", (out_dir / "images.txt").read_text(encoding="utf-8"))

    def test_write_colmap_text_model_honors_shared_simple_pinhole_camera(self):
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
                original_sizes_wh=[(100, 80), (100, 80)],
                vggt_resolution=64,
                points_xyz=np.zeros((0, 3), dtype=np.float32),
                points_rgb=np.zeros((0, 3), dtype=np.uint8),
                camera_type="SIMPLE_PINHOLE",
                shared_camera=True,
            )

            camera_rows = [
                line
                for line in (out_dir / "cameras.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]
            image_rows = [
                line
                for line in (out_dir / "images.txt").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            ]

            self.assertEqual(len(camera_rows), 1)
            self.assertTrue(camera_rows[0].startswith("1 SIMPLE_PINHOLE "))
            self.assertEqual([row.split()[8] for row in image_rows], ["1", "1"])


if __name__ == "__main__":
    unittest.main()
