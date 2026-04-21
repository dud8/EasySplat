import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from easysplat_fastvggt_sfm import run as fast_run


class FastVggtStrictCoverageTests(unittest.TestCase):
    def _write_image(self, path: Path, value: int) -> None:
        image = Image.new("RGB", (64, 48), color=(value, value, value))
        image.save(path)

    def test_auto_planner_prefers_temporal_for_ordered_names(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = []
            for idx in range(12):
                path = root / f"frame_{idx:04d}.jpg"
                self._write_image(path, idx)
                paths.append(path)

            planner, confidence = fast_run._resolve_planner_mode(paths, "auto")
            self.assertEqual(planner, "temporal")
            self.assertGreaterEqual(confidence, 0.65)

    def test_list_images_preserves_mixed_extension_filename_order(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in ["frame_000000.png", "frame_000001.jpg", "frame_000002.png"]:
                (root / name).write_bytes(b"image")

            self.assertEqual(
                [path.name for path in fast_run._list_images(root)],
                ["frame_000000.png", "frame_000001.jpg", "frame_000002.png"],
            )

    def test_auto_planner_prefers_appearance_for_unordered_names(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            names = ["apple.jpg", "city.jpg", "zebra.jpg", "kite.jpg", "water.jpg"]
            paths = []
            for idx, name in enumerate(names):
                path = root / name
                self._write_image(path, idx * 30)
                paths.append(path)

            planner, confidence = fast_run._resolve_planner_mode(paths, "auto")
            self.assertEqual(planner, "appearance")
            self.assertLess(confidence, 0.65)

    def test_window_plan_covers_all_frames_without_dropping(self):
        order = list(range(27))
        windows = fast_run._plan_windows_from_order(order, window_size=8, overlap=0.5)
        covered = set(idx for window in windows for idx in window)

        self.assertEqual(covered, set(order))
        self.assertTrue(all(len(window) >= 3 for window in windows))

    def test_manifest_payload_and_strict_exit_contract(self):
        paths = [Path(f"frame_{idx:04d}.jpg") for idx in range(4)]
        statuses = ["registered", "registered", "processed_unregistered", "registered"]
        unresolved = [2]

        payload = fast_run._coverage_manifest_payload(
            image_paths=paths,
            statuses=statuses,
            rounds_used=3,
            planner_mode="temporal",
            planner_confidence=0.9,
            window_size=6,
            unresolved=unresolved,
        )

        self.assertEqual(payload["total_frames"], 4)
        self.assertEqual(payload["registered_frames"], 3)
        self.assertEqual(payload["unresolved_frames"], ["frame_0002.jpg"])
        self.assertEqual(fast_run._coverage_exit_code(True, unresolved_count=1), 2)
        self.assertEqual(fast_run._coverage_exit_code(False, unresolved_count=1), 0)
        self.assertEqual(fast_run._coverage_exit_code(True, unresolved_count=0), 0)

    def test_fill_unresolved_intrinsics_marks_unreadable_frames(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            good = root / "good.jpg"
            bad = root / "bad.jpg"
            self._write_image(good, 30)
            bad.write_text("not-an-image", encoding="utf-8")

            image_paths = [good, bad]
            state = fast_run.CoverageState(
                image_paths=image_paths,
                registered_mask=np.array([False, False], dtype=bool),
                statuses=["processed_unregistered", "processed_unregistered"],
                attempts=np.zeros(2, dtype=np.int32),
                extrinsics=np.stack([np.eye(4, dtype=np.float32) for _ in image_paths], axis=0),
                intrinsics=np.stack([np.eye(3, dtype=np.float32) for _ in image_paths], axis=0),
                camera_votes=np.zeros(2, dtype=np.int32),
                points3d_chunks=[],
                points_xyf_chunks=[],
                points_rgb_chunks=[],
                relative_edges=[],
            )

            fast_run._fill_unresolved_intrinsics(state=state, image_paths=image_paths)

            self.assertEqual(state.statuses[1], "unreadable")
            self.assertNotEqual(float(state.intrinsics[0][0, 0]), 1.0)
            self.assertTrue(np.array_equal(state.intrinsics[1], np.eye(3, dtype=np.float32)))

    def test_registered_export_subset_omits_unresolved_and_remaps_points(self):
        image_paths = [Path(f"frame_{idx:04d}.jpg") for idx in range(4)]
        registered_indices = [0, 2, 3]

        extrinsics = np.stack([np.eye(4, dtype=np.float32) for _ in image_paths], axis=0)
        intrinsics = np.stack([np.eye(3, dtype=np.float32) for _ in image_paths], axis=0)
        points3d = np.array(
            [
                [0.0, 0.0, 0.0],
                [1.0, 1.0, 1.0],
                [2.0, 2.0, 2.0],
            ],
            dtype=np.float32,
        )
        points_xyf = np.array(
            [
                [10.0, 10.0, 0.0],
                [20.0, 20.0, 1.0],
                [30.0, 30.0, 3.0],
            ],
            dtype=np.float32,
        )
        points_rgb = np.array(
            [
                [10, 20, 30],
                [40, 50, 60],
                [70, 80, 90],
            ],
            dtype=np.uint8,
        )
        original_coords = np.array(
            [
                [0.0, 0.0, 64.0, 48.0, 64.0, 48.0],
                [0.0, 0.0, 64.0, 48.0, 64.0, 48.0],
                [0.0, 0.0, 64.0, 48.0, 64.0, 48.0],
                [0.0, 0.0, 64.0, 48.0, 64.0, 48.0],
            ],
            dtype=np.float32,
        )

        (
            export_paths,
            export_extrinsics,
            export_intrinsics,
            export_points3d,
            export_points_xyf,
            export_points_rgb,
            export_original_coords,
        ) = fast_run._build_registered_export_subset(
            image_paths=image_paths,
            registered_indices=registered_indices,
            extrinsics=extrinsics,
            intrinsics=intrinsics,
            points3d=points3d,
            points_xyf=points_xyf,
            points_rgb=points_rgb,
            original_coords=original_coords,
        )

        self.assertEqual([path.name for path in export_paths], ["frame_0000.jpg", "frame_0002.jpg", "frame_0003.jpg"])
        self.assertEqual(export_extrinsics.shape[0], 3)
        self.assertEqual(export_intrinsics.shape[0], 3)
        self.assertEqual(export_original_coords.shape[0], 3)

        self.assertEqual(export_points3d.shape[0], 2)
        self.assertEqual(export_points_rgb.shape[0], 2)
        self.assertEqual(export_points_xyf[:, 2].tolist(), [0.0, 2.0])

    def test_colmap_export_keeps_non_square_points_in_bounds(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            image_specs = [
                ("landscape.jpg", (64, 48)),
                ("portrait.jpg", (48, 64)),
                ("square.jpg", (56, 56)),
            ]
            image_paths = []
            for idx, (name, size) in enumerate(image_specs):
                path = root / name
                Image.new("RGB", size, color=(idx * 40, idx * 40, idx * 40)).save(path)
                image_paths.append(path)

            original_coords = fast_run._compute_original_coords(image_paths, target_width=56)
            extrinsics = np.stack([np.eye(4, dtype=np.float32) for _ in image_paths], axis=0)
            intrinsics = np.stack([np.eye(3, dtype=np.float32) for _ in image_paths], axis=0)
            points3d = np.array(
                [
                    [0.0, 0.0, 1.0],
                    [1.0, 0.0, 1.0],
                    [2.0, 0.0, 1.0],
                ],
                dtype=np.float32,
            )
            points_xyf = np.array(
                [
                    [0.0, 0.0, 0.0],
                    [0.0, 0.0, 1.0],
                    [0.0, 0.0, 2.0],
                ],
                dtype=np.float32,
            )
            points_rgb = np.array(
                [
                    [10, 20, 30],
                    [40, 50, 60],
                    [70, 80, 90],
                ],
                dtype=np.uint8,
            )

            out_sparse = root / "sparse"
            fast_run._write_colmap_text_model(
                out_sparse,
                points3d,
                points_xyf,
                points_rgb,
                extrinsics,
                intrinsics,
                image_paths,
                original_coords,
                img_size=56,
                shared_camera=False,
                camera_type="SIMPLE_PINHOLE",
            )

            lines = [
                line.strip()
                for line in (out_sparse / "images.txt").read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.startswith("#")
            ]
            point_lines = lines[1::2]
            self.assertEqual(len(point_lines), len(image_specs))
            for point_line, (_, (width, height)) in zip(point_lines, image_specs):
                fields = point_line.split()
                x = float(fields[0])
                y = float(fields[1])
                self.assertGreaterEqual(x, 0.0)
                self.assertGreaterEqual(y, 0.0)
                self.assertLessEqual(x, float(width - 1))
                self.assertLessEqual(y, float(height - 1))


if __name__ == "__main__":
    unittest.main()
