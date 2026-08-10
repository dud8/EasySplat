"""The scorer decides every benchmark number, and the parts that would corrupt one
silently are all geometric: which cameras are held out, how intrinsics are rescaled when
`cameras.bin` and the image on disk disagree, and the axis flip between COLMAP and the
renderer. None of those raise when they are wrong -- they just move the score.

The perceptual half is not tested here. It is a thin call into `lpips`, and pulling torch
into this suite would cost more than it protects.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

import numpy as np

BENCH_PATH = pathlib.Path(__file__).resolve().parents[1] / "mipnerf360" / "bench.py"
STAGE_PATH = pathlib.Path(__file__).resolve().parents[1] / "stage_sparse_views.py"


def _load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


bench = _load("mipnerf360_bench", BENCH_PATH)
stage = _load("stage_sparse_views", STAGE_PATH)

IDENTITY_QUATERNION = (1.0, 0.0, 0.0, 0.0)


class HoldOutSplitTests(unittest.TestCase):
    def test_the_scorer_and_the_sparse_stager_agree_on_the_test_set(self):
        """These two derive the split independently -- one to render, one to withhold from
        training. If they ever drift, a sparse run trains on views it is scored against and
        nothing else in the pipeline would notice."""
        for count in (16, 97, 194, 311):
            names = [f"IMG_{index:04d}.JPG" for index in range(count)]
            self.assertEqual(
                bench.held_out_names(names, 8),
                stage.sparse_train_names(names, num_views=count, holdout_every=8)[1],
                f"{count} cameras",
            )

    def test_the_split_is_every_eighth_starting_at_zero(self):
        names = [f"{index:03d}.jpg" for index in range(40)]
        self.assertEqual(bench.held_out_names(names, 8), [f"{i:03d}.jpg" for i in range(0, 40, 8)])

    def test_unsorted_input_selects_the_same_views(self):
        """The trainer sorts by filename before splitting, so a caller handing over COLMAP's
        own order must not get a different test set."""
        names = [f"{index:03d}.jpg" for index in range(64)]
        self.assertEqual(
            bench.held_out_names(names, 8),
            bench.held_out_names(list(reversed(names)), 8),
        )


class IntrinsicRescaleTests(unittest.TestCase):
    def rescaled(self, camera_size, image_size):
        projection, _ = bench.view_matrices(
            IDENTITY_QUATERNION,
            (0.0, 0.0, 0.0),
            (100.0, 100.0, 50.0, 40.0),
            camera_size,
            image_size,
            near=0.1,
            far=100.0,
        )
        return projection

    def test_a_camera_record_at_half_the_image_size_doubles_the_intrinsics(self):
        """mip-NeRF 360 ships pre-downscaled images whose `cameras.bin` still describes the
        originals. Getting this backwards halves the field of view and every score with it."""
        # 2*fx/W is invariant when fx and W scale together, so compare against the
        # unrescaled case rather than to a bare constant.
        matched = self.rescaled((100, 80), (100, 80))
        doubled = self.rescaled((100, 80), (200, 160))
        np.testing.assert_allclose(doubled[0, 0], matched[0, 0])
        np.testing.assert_allclose(doubled[0, 2], matched[0, 2])

        # A rescale that is not applied at all: the field of view collapses by the ratio.
        unscaled_fx = 2.0 * 100.0 / 200.0
        self.assertNotAlmostEqual(doubled[0, 0], unscaled_fx)
        np.testing.assert_allclose(doubled[0, 0], 2.0 * 200.0 / 200.0)

    def test_anisotropic_rescale_uses_each_axis_separately(self):
        projection = self.rescaled((100, 80), (200, 80))
        np.testing.assert_allclose(projection[0, 0], 2.0 * 200.0 / 200.0)
        np.testing.assert_allclose(projection[1, 1], 2.0 * 100.0 / 80.0)


class WorldToCameraTests(unittest.TestCase):
    def test_a_point_in_front_of_the_camera_lands_at_negative_z(self):
        """COLMAP looks down +Z, the renderer down -Z. If the flip is inverted the scene
        renders empty rather than wrong, but only for a camera that is not at the origin --
        so this checks the sign directly."""
        _, world_to_camera = bench.view_matrices(
            IDENTITY_QUATERNION,
            (0.0, 0.0, 0.0),
            (100.0, 100.0, 50.0, 40.0),
            (100, 80),
            (100, 80),
            near=0.1,
            far=100.0,
        )
        ahead_in_colmap = np.array([0.0, 0.0, 5.0, 1.0])
        camera_space = world_to_camera @ ahead_in_colmap
        self.assertAlmostEqual(camera_space[2], -5.0)
        # +Y is down in COLMAP and up in the renderer.
        below_in_colmap = np.array([0.0, 3.0, 5.0, 1.0])
        self.assertAlmostEqual((world_to_camera @ below_in_colmap)[1], -3.0)

    def test_translation_is_applied_before_the_flip(self):
        _, world_to_camera = bench.view_matrices(
            IDENTITY_QUATERNION,
            (1.0, 2.0, 3.0),
            (100.0, 100.0, 50.0, 40.0),
            (100, 80),
            (100, 80),
            near=0.1,
            far=100.0,
        )
        origin = world_to_camera @ np.array([0.0, 0.0, 0.0, 1.0])
        np.testing.assert_allclose(origin[:3], [1.0, -2.0, -3.0])


class CameraModelTests(unittest.TestCase):
    def test_pinhole_models_map_to_their_parameters(self):
        self.assertEqual(
            bench.pinhole_intrinsics({"model": "PINHOLE", "params": [1.0, 2.0, 3.0, 4.0]}),
            (1.0, 2.0, 3.0, 4.0),
        )
        self.assertEqual(
            bench.pinhole_intrinsics({"model": "SIMPLE_PINHOLE", "params": [1.0, 3.0, 4.0]}),
            (1.0, 1.0, 3.0, 4.0),
        )

    def test_distorted_models_are_not_silently_treated_as_pinholes(self):
        """The renderer has no lens model. A SIMPLE_RADIAL camera would render a warp-free
        image against warped ground truth and score the difference as quality loss."""
        self.assertNotIn("SIMPLE_RADIAL", bench.UNDISTORTED_MODELS)
        self.assertNotIn("OPENCV", bench.UNDISTORTED_MODELS)
        self.assertNotIn("RADIAL", bench.UNDISTORTED_MODELS)
        self.assertEqual(set(bench.UNDISTORTED_MODELS), {"PINHOLE", "SIMPLE_PINHOLE"})

    def test_every_colmap_model_id_has_a_parameter_count(self):
        self.assertEqual(set(bench.CAMERA_MODEL_NAME), set(bench.CAMERA_PARAM_COUNT))


if __name__ == "__main__":
    unittest.main()
