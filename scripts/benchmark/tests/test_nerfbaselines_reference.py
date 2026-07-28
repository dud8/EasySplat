"""The published reference table has to stay self-consistent and correctly subset.

A transcribed table is a liability the moment nobody rechecks it. Two things are
worth asserting: that the per-scene numbers actually average to the figures the
leaderboard publishes, which catches a mis-copied cell, and that the seven-scene
subset is derived rather than assumed, which is the comparison EasySplat can
actually make.
"""

from __future__ import annotations

import json
import pathlib
import unittest

REFERENCE = (
    pathlib.Path(__file__).resolve().parents[1]
    / "references"
    / "nerfbaselines-mipnerf360.json"
)

METRICS = ("psnr", "ssim", "lpips_vgg")


def load() -> dict:
    return json.loads(REFERENCE.read_text(encoding="utf-8"))


def mean(per_scene: dict, scenes, metric: str) -> float:
    return sum(per_scene[scene][metric] for scene in scenes) / len(scenes)


class NerfBaselinesReferenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.reference = load()
        self.methods = self.reference["methods"]

    def test_per_scene_tables_reproduce_the_published_averages(self):
        """A mis-transcribed cell shows up here and nowhere else."""
        for name, method in self.methods.items():
            per_scene = method["per_scene"]
            self.assertEqual(len(per_scene), 9, f"{name}: expected all nine scenes")
            for metric in METRICS:
                published = method["published_average_9"][metric]
                derived = mean(per_scene, per_scene.keys(), metric)
                # The site publishes two decimals for PSNR and three for the rest,
                # so the derived mean can only be checked to rounding: a half-unit on
                # each input and another on the average they must reproduce.
                tolerance = 0.01 if metric == "psnr" else 0.001
                self.assertAlmostEqual(
                    derived,
                    published,
                    delta=tolerance,
                    msg=f"{name} {metric}: per-scene mean {derived:.4f} does not "
                    f"reproduce the published {published}",
                )

    def test_every_method_covers_the_same_scenes(self):
        expected = set(self.reference["scene_availability"]["public"]) | set(
            self.reference["scene_availability"]["restricted"]
        )
        for name, method in self.methods.items():
            self.assertEqual(
                set(method["per_scene"]), expected, f"{name}: scene list differs"
            )

    def test_restricted_scenes_are_the_two_hardest(self):
        """The warning in the file rests on this, so it should be checked rather
        than trusted: dropping flowers and treehill has to raise the mean."""
        availability = self.reference["scene_availability"]
        for name, method in self.methods.items():
            per_scene = method["per_scene"]
            nine = mean(per_scene, per_scene.keys(), "psnr")
            seven = mean(per_scene, availability["public"], "psnr")
            self.assertGreater(
                seven,
                nine,
                f"{name}: the seven public scenes should score above the nine-scene "
                "mean, which is why they cannot be compared against each other",
            )

    def test_the_seven_scene_gap_is_large_enough_to_matter(self):
        """Guards the specific claim the file makes about 3DGS."""
        per_scene = self.methods["gaussian-splatting"]["per_scene"]
        public = self.reference["scene_availability"]["public"]
        gap = mean(per_scene, public, "psnr") - mean(per_scene, per_scene.keys(), "psnr")
        self.assertAlmostEqual(gap, 1.55, delta=0.01)

    def test_easysplat_protocol_differences_are_enumerated(self):
        """Every protocol axis the comparison depends on gets an explicit verdict,
        so a silent mismatch cannot hide in an unlisted field."""
        match = self.reference["easysplat_protocol_match"]
        for axis in ("downscale", "holdout", "psnr", "ssim", "lpips", "poses", "sort_key"):
            self.assertIn(axis, match)
            self.assertTrue(match[axis].strip(), f"{axis}: empty verdict")


class SparseReferenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.reference = load()
        self.sparse = self.reference["sparse"]

    def test_per_scene_tables_reproduce_the_published_averages(self):
        """The sparse leaderboard averages over eighteen rows -- nine scenes at both
        view counts -- so a table transcribed for only one count would still look
        plausible while being half the benchmark."""
        for name, method in self.sparse["methods"].items():
            rows = list(method["n12"].values()) + list(method["n24"].values())
            self.assertEqual(len(rows), 18, f"{name}: expected nine scenes at both counts")
            for metric in METRICS:
                derived = sum(row[metric] for row in rows) / len(rows)
                published = method["published_average_18"][metric]
                # Every input cell is rounded to the published precision and so is
                # the average, so the bound is two half-units in the last place.
                tolerance = 0.01 if metric == "psnr" else 0.001
                self.assertAlmostEqual(
                    derived,
                    published,
                    delta=tolerance,
                    msg=f"{name} {metric}: eighteen-row mean {derived:.4f} does not "
                    f"reproduce the published {published}",
                )

    def test_more_views_score_better_on_every_scene(self):
        """Cheap monotonicity check: 24 views cannot be worse than 12 anywhere, so a
        swapped pair of columns shows up immediately."""
        for name, method in self.sparse["methods"].items():
            for scene, twelve in method["n12"].items():
                self.assertGreater(
                    method["n24"][scene]["psnr"],
                    twelve["psnr"],
                    f"{name} {scene}: 24 views scored below 12",
                )

    def test_sparse_and_dense_cover_the_same_scenes(self):
        dense = set(self.reference["methods"]["gaussian-splatting"]["per_scene"])
        for name, method in self.sparse["methods"].items():
            self.assertEqual(set(method["n12"]), dense, f"{name}: n12 scene list differs")
            self.assertEqual(set(method["n24"]), dense, f"{name}: n24 scene list differs")

    def test_dense_ranking_does_not_carry_over(self):
        """The file claims sparse is a different problem; this is the claim.
        Zip-NeRF leads the dense board and comes last here."""
        averages = self.sparse["leaderboard_averages_18_row"]
        self.assertEqual(min(averages, key=averages.get), "zipnerf")
        # The dense block carries a prose note alongside the numbers.
        dense = {
            k: v
            for k, v in self.reference["leaderboard_averages_9_scene_only"].items()
            if isinstance(v, (int, float))
        }
        self.assertEqual(max(dense, key=dense.get), "zipnerf")


if __name__ == "__main__":
    unittest.main()
