from __future__ import annotations

import math
import unittest
from unittest import mock

from scripts.benchmark import evidence_protocol as evidence


def _rotate_transpose(
    rotation: tuple[tuple[float, float, float], ...],
    value: tuple[float, float, float],
) -> tuple[float, float, float]:
    return tuple(
        sum(rotation[row][column] * value[row] for row in range(3))
        for column in range(3)
    )


def _z_rotation(
    angle_degrees: float,
) -> tuple[
    tuple[tuple[float, float, float], ...],
    tuple[float, float, float, float],
]:
    angle = math.radians(angle_degrees)
    half = angle / 2
    return (
        (
            (math.cos(angle), -math.sin(angle), 0.0),
            (math.sin(angle), math.cos(angle), 0.0),
            (0.0, 0.0, 1.0),
        ),
        (math.cos(half), 0.0, 0.0, math.sin(half)),
    )


class Sim3PoseDeviationTests(unittest.TestCase):
    def test_removes_one_proper_global_sim3_from_centers_and_rotations(self) -> None:
        alignment, candidate_quaternion = _z_rotation(37.0)
        translation = (4.0, -2.0, 3.0)
        scale = 2.5
        reference_centers = {
            "d": (0.2, 0.3, 1.0),
            "a": (0.0, 0.0, 0.0),
            "c": (0.0, 1.0, 0.0),
            "b": (1.0, 0.0, 0.0),
        }
        reference = evidence.name_bound_w2c_poses(
            [
                {
                    "image_name": name,
                    "w2c_quaternion_wxyz": (1.0, 0.0, 0.0, 0.0),
                    "center_xyz": center,
                }
                for name, center in reference_centers.items()
            ]
        )
        candidate_records = []
        for name, center in reversed(tuple(reference_centers.items())):
            translated = tuple(
                (center[index] - translation[index]) / scale for index in range(3)
            )
            candidate_records.append(
                {
                    "image_name": name,
                    "w2c_quaternion_wxyz": candidate_quaternion,
                    "center_xyz": _rotate_transpose(alignment, translated),
                }
            )
        candidate = evidence.name_bound_w2c_poses(candidate_records)

        first = evidence.sim3_pose_deviation(reference, candidate)
        second = evidence.sim3_pose_deviation(reference, candidate)

        self.assertEqual(first, second)
        self.assertLess(first.camera_center_p95_scene_radius_fraction, 1e-12)
        self.assertLess(first.rotation_p95_degrees, 3e-6)

    def test_mapper_cadence_adapter_binds_parallel_poses_by_image_name(self) -> None:
        reference = evidence.mapper_cadence_name_bound_poses(
            {
                "registered_image_names": ["a.jpg", "b.jpg", "c.jpg"],
                "camera_poses_wxyz_xyz": [
                    [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                    [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0],
                    [1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0],
                ],
            }
        )
        candidate = evidence.mapper_cadence_name_bound_poses(
            {
                "registered_image_names": ["c.jpg", "a.jpg", "b.jpg"],
                "camera_poses_wxyz_xyz": [
                    [1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0],
                    [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                    [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0],
                ],
            }
        )

        result = evidence.sim3_pose_deviation(reference, candidate)

        self.assertLess(result.camera_center_p95_scene_radius_fraction, 1e-12)
        self.assertLess(result.rotation_p95_degrees, 3e-6)

    def test_name_bound_pose_records_reject_ambiguous_or_invalid_values(self) -> None:
        valid = {
            "image_name": "a.jpg",
            "w2c_quaternion_wxyz": [1.0, 0.0, 0.0, 0.0],
            "center_xyz": [0.0, 0.0, 0.0],
        }
        cases = (
            (
                [valid, dict(valid)],
                "pose names must be unique",
            ),
            (
                [dict(valid, w2c_quaternion_wxyz=[2.0, 0.0, 0.0, 0.0])],
                "unit quaternion",
            ),
            (
                [dict(valid, center_xyz=[math.inf, 0.0, 0.0])],
                "finite",
            ),
            (
                [dict(valid, translation_xyz=[0.0, 0.0, 0.0])],
                "exactly one",
            ),
        )
        for records, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(evidence.PoseAlignmentError, message):
                    evidence.name_bound_w2c_poses(records)

    def test_requires_three_common_names_and_noncollinear_reference_centers(
        self,
    ) -> None:
        def poses(centers: dict[str, tuple[float, float, float]]):
            return evidence.name_bound_w2c_poses(
                [
                    {
                        "image_name": name,
                        "w2c_quaternion_wxyz": [1.0, 0.0, 0.0, 0.0],
                        "center_xyz": center,
                    }
                    for name, center in centers.items()
                ]
            )

        with self.assertRaisesRegex(
            evidence.PoseAlignmentError, "pose_alignment_unavailable"
        ):
            evidence.sim3_pose_deviation(
                poses({"a": (0.0, 0.0, 0.0), "b": (1.0, 0.0, 0.0)}),
                poses({"a": (0.0, 0.0, 0.0), "b": (1.0, 0.0, 0.0)}),
            )

        collinear = poses(
            {
                "a": (0.0, 0.0, 0.0),
                "b": (1.0, 0.0, 0.0),
                "c": (2.0, 0.0, 0.0),
            }
        )
        with self.assertRaisesRegex(
            evidence.PoseAlignmentError, "pose_alignment_degenerate"
        ):
            evidence.sim3_pose_deviation(collinear, collinear)

    def test_proper_alignment_does_not_hide_a_reflected_trajectory(self) -> None:
        reference_centers = {
            "a": (0.0, 0.0, 0.0),
            "b": (1.0, 0.0, 0.0),
            "c": (0.0, 1.0, 0.0),
            "d": (0.0, 0.0, 1.0),
        }
        reference = evidence.name_bound_w2c_poses(
            [
                {
                    "image_name": name,
                    "w2c_quaternion_wxyz": [1.0, 0.0, 0.0, 0.0],
                    "center_xyz": center,
                }
                for name, center in reference_centers.items()
            ]
        )
        reflected = evidence.name_bound_w2c_poses(
            [
                {
                    "image_name": name,
                    "w2c_quaternion_wxyz": [1.0, 0.0, 0.0, 0.0],
                    "center_xyz": (-center[0], center[1], center[2]),
                }
                for name, center in reference_centers.items()
            ]
        )

        result = evidence.sim3_pose_deviation(reference, reflected)

        self.assertGreater(result.camera_center_p95_scene_radius_fraction, 0.1)

    def test_rejects_an_unpinned_numpy_runtime(self) -> None:
        poses = evidence.name_bound_w2c_poses(
            [
                {
                    "image_name": name,
                    "w2c_quaternion_wxyz": [1.0, 0.0, 0.0, 0.0],
                    "center_xyz": center,
                }
                for name, center in {
                    "a": (0.0, 0.0, 0.0),
                    "b": (1.0, 0.0, 0.0),
                    "c": (0.0, 1.0, 0.0),
                }.items()
            ]
        )
        with mock.patch("importlib.metadata.version", return_value="0.0.0"):
            with self.assertRaisesRegex(
                evidence.PoseAlignmentError,
                "pose_alignment_runtime_unavailable",
            ):
                evidence.sim3_pose_deviation(poses, poses)


if __name__ == "__main__":
    unittest.main()
