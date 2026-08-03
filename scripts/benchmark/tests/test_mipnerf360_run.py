"""The runner's command line is the experiment. Everything here tests it without a
trainer, because the failures that matter are silent: a changed default moves every
number, a colliding flag makes the run record disagree with what ran, and a tag that does
not separate replicates makes the second run of an arm delete the first.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import sys
import unittest

RUN_PATH = pathlib.Path(__file__).resolve().parents[1] / "mipnerf360" / "run.py"
_spec = importlib.util.spec_from_file_location("mipnerf360_run", RUN_PATH)
run = importlib.util.module_from_spec(_spec)
sys.modules["mipnerf360_run"] = run
_spec.loader.exec_module(run)

TRAINER = pathlib.Path("/opt/easysplat/easysplat-train")
DATASET = pathlib.Path("/data/bicycle")
PLY = pathlib.Path("/work/out/bicycle.ply")
CHECKPOINT = pathlib.Path("/work/ckpt/bicycle")


def arguments(**overrides) -> list[str]:
    defaults = dict(
        trainer=TRAINER,
        dataset=DATASET,
        ply=PLY,
        checkpoint=CHECKPOINT,
        profile="high-detail",
        seed=42,
        holdout_every=8,
        budget=36_000_000_000,
        iterations=None,
        plateau_window=None,
        extra=[],
    )
    defaults.update(overrides)
    return run.trainer_arguments(**defaults)


def value_after(argv: list[str], flag: str) -> str | None:
    return argv[argv.index(flag) + 1] if flag in argv else None


class DefaultCommandLineTests(unittest.TestCase):
    def test_the_defaults_reproduce_every_historical_run(self):
        """Seed 42, every eighth camera held out, a 36 GB budget, events on stdout. If any
        of these drifts, past and future numbers stop being comparable and nothing else in
        the pipeline would say so."""
        argv = arguments(iterations=40_000)
        self.assertEqual(value_after(argv, "--seed"), "42")
        self.assertEqual(value_after(argv, "--holdout-every"), "8")
        self.assertEqual(value_after(argv, "--memory-budget-bytes"), "36000000000")
        self.assertEqual(value_after(argv, "--events-fd"), "1")
        self.assertEqual(value_after(argv, "--profile"), "high-detail")
        self.assertEqual(value_after(argv, "--iteration-limit"), "40000")
        # A tenth of the budget, as the external harness derived it.
        self.assertEqual(value_after(argv, "--plateau-window"), "4000")

    def test_the_trainer_runs_under_caffeinate(self):
        """A display sleep mid-run changes GPU scheduling, and these runs are hours long."""
        argv = arguments()
        self.assertEqual(argv[:2], ["caffeinate", "-dimsu"])
        self.assertEqual(argv[2], str(TRAINER))

    def test_no_iteration_limit_leaves_the_profile_to_decide(self):
        argv = arguments()
        self.assertNotIn("--iteration-limit", argv)
        self.assertNotIn("--plateau-window", argv)

    def test_an_explicit_plateau_window_overrides_the_derived_one(self):
        argv = arguments(iterations=40_000, plateau_window=999)
        self.assertEqual(value_after(argv, "--plateau-window"), "999")

    def test_a_plateau_window_without_an_iteration_limit_still_reaches_the_trainer(self):
        argv = arguments(plateau_window=250)
        self.assertEqual(value_after(argv, "--plateau-window"), "250")


class HoldoutTests(unittest.TestCase):
    def test_holdout_can_be_disabled_with_zero(self):
        """The trainer's spelling of no holdout is 0. It rejects 1, which would ask it to
        hold out every camera."""
        self.assertEqual(value_after(arguments(holdout_every=0), "--holdout-every"), "0")

    def test_a_changed_holdout_rule_reaches_the_trainer(self):
        self.assertEqual(value_after(arguments(holdout_every=4), "--holdout-every"), "4")


class TrainerArgPassthroughTests(unittest.TestCase):
    def test_extra_arguments_are_appended_verbatim(self):
        argv = arguments(extra=["--densify-grad-threshold", "0.0004"])
        self.assertEqual(argv[-2:], ["--densify-grad-threshold", "0.0004"])

    def test_a_collision_with_a_managed_flag_is_refused_by_name(self):
        """Last-wins parsing would accept a duplicate silently, and the recorded argv would
        then not describe the run."""
        for flag in ("--seed", "--holdout-every", "--profile", "--iteration-limit"):
            with self.assertRaises(SystemExit) as raised:
                arguments(extra=[flag, "7"])
            self.assertIn(flag, str(raised.exception))

    def test_a_collision_written_with_an_equals_sign_is_also_refused(self):
        with self.assertRaises(SystemExit):
            arguments(extra=["--seed=7"])

    def test_every_flag_the_runner_emits_is_declared_managed(self):
        """The guard is a hardcoded set; this is what keeps it in step with the argv."""
        argv = arguments(iterations=1000, plateau_window=100)
        emitted = {token for token in argv if token.startswith("--")}
        self.assertEqual(emitted - run.MANAGED_TRAINER_FLAGS, set())


class TagTests(unittest.TestCase):
    def tag(self, **overrides) -> str:
        defaults = dict(
            scene="bicycle", profile="high-detail", iterations=40_000,
            arm="baseline", replicate=1,
        )
        defaults.update(overrides)
        return run.build_tag(argparse.Namespace(**defaults))

    def test_replicates_of_one_arm_never_share_a_tag(self):
        """Every output path derives from the tag. Sharing one means the second run
        overwrites the first, which is why three runs per arm had been unreachable."""
        tags = {self.tag(replicate=n) for n in range(1, 4)}
        self.assertEqual(len(tags), 3)

    def test_arms_of_one_configuration_never_share_a_tag(self):
        self.assertNotEqual(self.tag(arm="baseline"), self.tag(arm="candidate"))

    def test_the_tag_carries_everything_that_distinguishes_a_run(self):
        self.assertEqual(self.tag(), "bicycle-high-detail-40000-baseline-r1")
        self.assertEqual(
            self.tag(iterations=None), "bicycle-high-detail-baseline-r1"
        )


if __name__ == "__main__":
    unittest.main()
