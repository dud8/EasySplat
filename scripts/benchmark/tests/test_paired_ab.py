"""The differ decides whether an experiment counts, so its failures are the expensive
kind: a hardcoded threshold that ignores a policy change, a median that weights scenes by
view count, a veto that fires on a fluke-small denominator, or one that fails to fire on a
real regression. Each of those is tested directly.

Ordered roughly by how much a silent failure would cost.
"""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest

MODULE = pathlib.Path(__file__).resolve().parents[1] / "paired_ab.py"
CONTRACT = (
    pathlib.Path(__file__).resolve().parents[1] / "contracts" / "research-quality-v1.json"
)
_spec = importlib.util.spec_from_file_location("paired_ab", MODULE)
paired = importlib.util.module_from_spec(_spec)
sys.modules["paired_ab"] = paired
_spec.loader.exec_module(paired)

# The real held-out view counts. room has 39 and stump 16, which is the whole reason the
# contract forbids a median over pooled per-view deltas.
VIEW_COUNTS = {
    "bicycle": 25, "garden": 24, "stump": 16, "room": 39,
    "counter": 30, "kitchen": 35, "bonsai": 37,
}
PROVENANCE = {
    "sort_ordering": "camera_forward_depth",
    "metalsplatter_source_sha256": "sha256:" + "a" * 64,
}


class Workspace:
    """Writes run records and their metrics siblings the way `run.py` does."""

    def __init__(self, directory: pathlib.Path):
        self.directory = directory

    def write(
        self,
        scene: str,
        arm: str,
        replicate: int,
        psnr: list[float],
        ssim: list[float] | None = None,
        lpips_squeeze: list[float] | None = None,
        started_at: str | None = None,
        provenance: dict | None = None,
        include_squeeze: bool = True,
        seed: int = 42,
        jitter: float = 0.01,
        iterations: int | None = 40000,
        profile: str | None = "high-detail",
        holdout_every: int | None = 8,
        names: list[str] | None = None,
        digest: str | bool | None = None,
        trainer: str = "sha256:" + "c" * 64,
        environment: dict | None = None,
    ) -> pathlib.Path:
        # A small per-replicate offset, so the pooled repeat SD is not zero. Without it
        # every SD multiple is undefined and the advance gate can never be cleared, which
        # is a property of the fixture rather than of the differ.
        offset = jitter * (replicate - 2)
        views = []
        for index, value in enumerate(psnr):
            row = {
                "name": (names or [f"{scene}_{i:03d}.JPG" for i in range(len(psnr))])[index],
                "psnr": value + offset,
                "ssim": (ssim or [0.9] * len(psnr))[index],
                "lpips_vgg": 0.2,
                "render_seconds": 0.1,
            }
            if include_squeeze:
                row["lpips_squeeze"] = (
                    (lpips_squeeze or [0.15] * len(psnr))[index] + offset * 0.05
                )
            views.append(row)
        metrics = {"view_count": len(views), "views": views}
        tag = f"{scene}-high-detail-40000-{arm}-r{replicate}"
        metrics_path = self.directory / f"{tag}.metrics.json"
        raw = (json.dumps(metrics, indent=2) + "\n").encode("utf-8")
        metrics_path.write_bytes(raw)
        record = {
            "scene": scene,
            "profile": profile,
            "arm": arm,
            "replicate": replicate,
            "started_at": started_at or f"2026-07-28T{10 + replicate:02d}:00:00+00:00",
            "iteration_override": iterations,
            "seed": seed,
            "holdout_every": holdout_every,
            # `digest=False` omits the key, which is what a pre-runner receipt looks like.
            # Not `digest or ...`: a falsy value has to mean absent, not "use the default".
            "metrics_sha256": ("sha256:" + hashlib.sha256(raw).hexdigest())
            if digest is None else digest,
            "trainer_sha256": trainer,
            "trainer_environment": environment or {},
            "memory_budget_bytes": 36_000_000_000,
            # Not `provenance or PROVENANCE`: an explicitly empty block is the case under
            # test, and a falsy default would quietly restore it.
            "rendering": {"provenance": PROVENANCE if provenance is None else provenance},
        }
        if record["metrics_sha256"] is False:
            del record["metrics_sha256"]
        path = self.directory / f"{tag}.json"
        path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        return path


def flat(value: float, count: int) -> list[float]:
    return [value] * count


class PairedABTestCase(unittest.TestCase):
    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self._temporary.name)
        self.workspace = Workspace(self.directory)
        self.contract_path = self.directory / "contract.json"
        self.contract_path.write_bytes(CONTRACT.read_bytes())

    def tearDown(self):
        self._temporary.cleanup()

    def compare(self, baseline, candidate, contract=None, extra=None) -> dict:
        output = self.directory / "verdict.json"
        argv = [
            "paired_ab.py",
            "--baseline", *[str(p) for p in baseline],
            "--candidate", *[str(p) for p in candidate],
            "--contract", str(contract or self.contract_path),
            "--output", str(output),
        ] + (extra or [])
        saved = sys.argv
        sys.argv = argv
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                paired.main()
        finally:
            sys.argv = saved
        return json.loads(output.read_text(encoding="utf-8"))

    def arm(self, arm: str, scenes: dict[str, float], replicates=3, lpips=0.15, **kwargs):
        return [
            self.workspace.write(
                scene, arm, replicate, flat(value, VIEW_COUNTS[scene]),
                lpips_squeeze=flat(lpips, VIEW_COUNTS[scene]), **kwargs
            )
            for scene, value in scenes.items()
            for replicate in range(1, replicates + 1)
        ]

    def advancing(self, scenes: dict[str, float], **kwargs):
        """A candidate that clears advance_to_consideration: LPIPS better by 0.02, well
        outside the fixture's repeat noise."""
        return self.arm("candidate", scenes, lpips=0.13, **kwargs)


class ContractConsumptionTests(PairedABTestCase):
    def test_a_changed_threshold_changes_the_verdict(self):
        """The only test that proves no threshold is hardcoded. Nothing else would catch a
        policy amendment being ignored."""
        scenes = {name: 30.0 for name in VIEW_COUNTS}
        baseline = self.arm("baseline", scenes)
        candidate = self.advancing({k: v - 0.1 for k, v in scenes.items()})

        self.assertEqual(self.compare(baseline, candidate)["research_verdict"], "accept")

        amended = json.loads(CONTRACT.read_text())
        amended["gates"]["metric_preserving_acceptance"]["median_psnr_loss_db_max"] = 0.0
        strict = self.directory / "strict.json"
        strict.write_text(json.dumps(amended), encoding="utf-8")
        self.assertEqual(
            self.compare(baseline, candidate, contract=strict)["research_verdict"],
            "reject",
        )

    def test_a_contract_missing_a_key_is_an_error_not_a_default(self):
        broken = json.loads(CONTRACT.read_text())
        del broken["gates"]["per_view_veto_stochastic"]["require_beyond_pooled_per_view_sd"]
        path = self.directory / "broken.json"
        path.write_text(json.dumps(broken), encoding="utf-8")
        with self.assertRaises(paired.ContractError) as raised:
            paired.load_contract(path)
        self.assertIn("require_beyond_pooled_per_view_sd", str(raised.exception))

    def test_a_different_contract_is_refused(self):
        for mutation in ({"contract": "research-quality-v2"}, {"schema_version": 2}):
            body = json.loads(CONTRACT.read_text())
            body.update(mutation)
            path = self.directory / "other.json"
            path.write_text(json.dumps(body), encoding="utf-8")
            with self.assertRaises(paired.ContractError):
                paired.load_contract(path)

    def test_every_verdict_records_the_contract_digest(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm("candidate", {"bicycle": 25.0})
        report = self.compare(baseline, candidate)
        expected = "sha256:" + hashlib.sha256(CONTRACT.read_bytes()).hexdigest()
        self.assertEqual(report["research_contract_sha256"], expected)


class MedianDefinitionTests(PairedABTestCase):
    def test_the_headline_is_the_equal_weight_scene_median(self):
        """Constructed so the equal-weight scene median and a pooled per-view median have
        opposite signs. Four small scenes improve, three large ones regress harder; pooling
        by view count would report a loss where the contract reports a gain."""
        improve = {"stump": 16, "garden": 24, "bicycle": 25, "counter": 30}
        regress = {"kitchen": 35, "bonsai": 37, "room": 39}
        baseline, candidate = [], []
        for scene in improve:
            baseline += self.arm("baseline", {scene: 30.0})
            candidate += self.arm("candidate", {scene: 30.2})
        for scene in regress:
            baseline += self.arm("baseline", {scene: 30.0})
            candidate += self.arm("candidate", {scene: 29.7})

        report = self.compare(baseline, candidate)
        median = report["medians"]["psnr"]

        pooled_weight_gain = sum(VIEW_COUNTS[s] * 0.2 for s in improve)
        pooled_weight_loss = sum(VIEW_COUNTS[s] * 0.3 for s in regress)
        self.assertLess(pooled_weight_gain, pooled_weight_loss, "fixture is not diagnostic")
        self.assertGreater(median, 0, "the headline must be the equal-weight scene median")


class PooledStandardDeviationTests(unittest.TestCase):
    def test_the_pool_matches_the_closed_form(self):
        a, b = [1.0, 2.0, 3.0], [10.0, 12.0, 14.0]
        # variance(a) = 1, variance(b) = 4; pooled = sqrt((2*1 + 2*4)/4)
        self.assertAlmostEqual(paired.pooled_sd(a, b), (10 / 4) ** 0.5, places=12)

    def test_a_single_replicate_per_arm_has_no_pooled_sd(self):
        self.assertIsNone(paired.pooled_sd([1.0], [2.0]))

    def test_one_arm_with_replicates_still_pools(self):
        self.assertAlmostEqual(paired.pooled_sd([1.0, 3.0], [5.0]), 2.0 ** 0.5, places=12)


class VetoTests(PairedABTestCase):
    def scene_with_one_bad_view(self, arm: str, base: float, bad: float | None,
                                jitter: float, replicates=3):
        paths = []
        for replicate in range(1, replicates + 1):
            values = [base + jitter * replicate] * VIEW_COUNTS["bicycle"]
            if bad is not None:
                values[0] = bad + jitter * replicate
            paths.append(
                self.workspace.write("bicycle", arm, replicate, values)
            )
        return paths

    def test_a_real_regression_vetoes_and_overrides_acceptance(self):
        """The shape that correctly rejected MCMC: the median is fine, one view is not."""
        baseline = self.scene_with_one_bad_view("baseline", 30.0, 30.0, jitter=0.02)
        candidate = self.scene_with_one_bad_view("candidate", 30.0, 28.5, jitter=0.02)
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "veto")
        self.assertEqual(len(report["veto"]), 1)
        self.assertLess(report["veto"][0]["paired_median_delta"], -1.0)

    def test_a_noisy_view_inside_four_sd_does_not_veto(self):
        """The contract's own note: do not veto from a single noisy run. A 1.5 dB drop
        against a 0.6 dB pooled SD is 2.5 SD and must not fire."""
        baseline, candidate = [], []
        for replicate, (a, b) in enumerate(
            [(30.0, 28.5), (30.9, 29.4), (29.1, 27.6)], start=1
        ):
            values_a = [30.0] * VIEW_COUNTS["bicycle"]
            values_b = [30.0] * VIEW_COUNTS["bicycle"]
            values_a[0], values_b[0] = a, b
            baseline.append(self.workspace.write("bicycle", "baseline", replicate, values_a))
            candidate.append(self.workspace.write("bicycle", "candidate", replicate, values_b))
        report = self.compare(baseline, candidate)
        self.assertEqual(report["veto"], [])

    def test_a_degenerate_per_view_sd_cannot_manufacture_a_veto(self):
        """Three replicates landing on the same value for one view is unremarkable. Using
        that view's own SD as the denominator would turn a 1.1 dB delta into a hundred-sigma
        hard veto, so the scene-wide pool is the floor."""
        baseline, candidate = [], []
        for replicate in range(1, 4):
            values_a = [30.0 + 0.5 * replicate] * VIEW_COUNTS["bicycle"]
            values_b = [30.0 + 0.5 * replicate] * VIEW_COUNTS["bicycle"]
            values_a[0], values_b[0] = 30.0, 28.9  # identical across replicates
            baseline.append(self.workspace.write("bicycle", "baseline", replicate, values_a))
            candidate.append(self.workspace.write("bicycle", "candidate", replicate, values_b))
        report = self.compare(baseline, candidate)
        entry = report["per_view_tail"]["worst_ten"][0]
        self.assertGreater(entry["veto_sd"], 0.0, "the scene pool must floor the per-view SD")
        self.assertEqual(report["veto"], [], "a 1.1 dB delta inside 4 scene-pool SD")


class VetoWithoutReplicatesTests(PairedABTestCase):
    def test_a_single_run_loss_is_a_candidate_not_a_veto(self):
        """At n=1 there is no per-view SD, so the contract's 4-SD requirement cannot be
        evaluated. Firing anyway contradicts its own note not to veto from a single noisy
        run -- and the worst such view on room turned out to be that scene's noisiest, at
        6x the median view's spread."""
        loud = flat(30.0, VIEW_COUNTS["bicycle"])
        quiet = list(loud)
        quiet[0] = 26.0
        baseline = [self.workspace.write("bicycle", "baseline", 1, loud)]
        candidate = [self.workspace.write("bicycle", "candidate", 1, quiet,
                                          lpips_squeeze=flat(0.13, VIEW_COUNTS["bicycle"]))]
        report = self.compare(baseline, candidate)
        self.assertEqual(report["veto"], [], "no SD means no veto verdict")
        self.assertEqual(len(report["veto_candidates"]), 1)
        self.assertIn("per_view_veto_stochastic", report["not_evaluable"])

    def test_with_replicates_the_same_loss_does_veto(self):
        """The guard is about missing evidence, not about tolerating regressions."""
        baseline, candidate = [], []
        for replicate in range(1, 4):
            loud = flat(30.0, VIEW_COUNTS["bicycle"])
            quiet = list(loud)
            quiet[0] = 26.0
            baseline.append(self.workspace.write("bicycle", "baseline", replicate, loud))
            candidate.append(self.workspace.write(
                "bicycle", "candidate", replicate, quiet,
                lpips_squeeze=flat(0.13, VIEW_COUNTS["bicycle"])))
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "veto")
        self.assertEqual(len(report["veto"]), 1)


class NullComparisonTests(PairedABTestCase):
    def test_identical_arms_do_not_advance_rather_than_being_accepted(self):
        """A change that improves nothing has not earned consideration. This is how the
        ramped tail cull was adjudicated -- LPIPS delta 0.0000, rejected without the PSNR
        column being weighed -- so the differ has to reach the same verdict."""
        baseline = self.arm("baseline", {name: 30.0 for name in VIEW_COUNTS})
        candidate = self.arm("candidate", {name: 30.0 for name in VIEW_COUNTS})
        report = self.compare(baseline, candidate)
        self.assertEqual(report["medians"]["psnr"], 0.0)
        self.assertEqual(report["veto"], [])
        self.assertIs(report["advance_to_consideration"], False)
        self.assertEqual(report["research_verdict"], "does_not_advance")

    def test_a_zero_variance_arm_reports_an_undefined_sd_multiple(self):
        baseline = self.arm("baseline", {"bicycle": 30.0}, jitter=0.0)
        candidate = self.arm("candidate", {"bicycle": 30.0}, jitter=0.0)
        report = self.compare(baseline, candidate)
        for scene in report["statistics"]["per_scene"].values():
            self.assertIsNone(scene["psnr"]["sd_multiple"], "k is undefined, not infinite")

    def test_the_same_inputs_produce_the_same_output(self):
        baseline = self.arm("baseline", {"bicycle": 25.0, "room": 30.0})
        candidate = self.arm("candidate", {"bicycle": 25.1, "room": 30.1})
        first = self.compare(baseline, candidate)
        second = self.compare(baseline, candidate)
        self.assertEqual(json.dumps(first, sort_keys=True), json.dumps(second, sort_keys=True))


class RefusalTests(PairedABTestCase):
    def test_two_replicates_are_insufficient_but_still_reported(self):
        """Underpowered is not invalid. A screen's numbers are the best estimate available
        and are often the whole point of running it; what it cannot have is a verdict."""
        baseline = self.arm("baseline", {"bicycle": 25.0}, replicates=2)
        candidate = self.advancing({"bicycle": 25.0}, replicates=2)
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "insufficient_replication")
        self.assertIn("statistics", report, "the screen's numbers are still reported")
        self.assertEqual(report["under_replicated"], {"baseline/bicycle": 2,
                                                      "candidate/bicycle": 2})

    def test_an_invalid_comparison_still_refuses_outright(self):
        """The distinction being drawn: a renderer mismatch makes the numbers meaningless,
        so unlike under-replication it reports none."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing(
            {"bicycle": 25.0},
            provenance={**PROVENANCE, "sort_ordering": "euclidean_camera_distance"},
        )
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "renderer_mismatch")
        self.assertNotIn("statistics", report)

    def test_a_missing_scene_is_refused_rather_than_averaged_over_what_is_present(self):
        baseline = self.arm("baseline", {"bicycle": 25.0, "room": 30.0})
        candidate = self.arm("candidate", {"bicycle": 25.0})
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "scene_set_mismatch")

    def test_arms_rendered_with_different_orderings_are_not_a_trainer_ab(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm(
            "candidate", {"bicycle": 25.0},
            provenance={**PROVENANCE, "sort_ordering": "euclidean_camera_distance"},
        )
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "renderer_mismatch")

    def test_arms_built_from_different_metalsplatter_trees_are_refused(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm(
            "candidate", {"bicycle": 25.0},
            provenance={**PROVENANCE, "metalsplatter_source_sha256": "sha256:" + "b" * 64},
        )
        self.assertEqual(
            self.compare(baseline, candidate)["research_verdict"], "renderer_mismatch"
        )

    def test_report_only_downgrades_a_mismatch_but_cannot_produce_an_accept(self):
        """An escape hatch that could reach `accept` is how the sort-ordering bug survived
        four hundred runs."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm(
            "candidate", {"bicycle": 25.0},
            provenance={**PROVENANCE, "sort_ordering": "euclidean_camera_distance"},
        )
        report = self.compare(
            baseline, candidate, extra=["--renderer-mismatch", "report-only"]
        )
        self.assertEqual(report["research_verdict"], "out_of_scope")
        self.assertIn("statistics", report, "statistics are still reported")

    def test_a_run_without_provenance_is_quarantined_by_name(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm("candidate", {"bicycle": 25.0}, provenance={})
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "missing_provenance")
        self.assertIn("sort_ordering", report["refusal"])

    def test_a_tampered_metrics_file_is_refused(self):
        path = self.workspace.write("bicycle", "baseline", 1, flat(25.0, 25))
        metrics = path.with_name(path.stem + ".metrics.json")
        metrics.write_text(metrics.read_text() + " ", encoding="utf-8")
        with self.assertRaises(paired.ArmError):
            paired.load_run(path)

    def test_an_out_of_scope_run_reports_statistics_without_accepting(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing({"bicycle": 25.0}, seed=7)
        report = self.compare(baseline, candidate)
        self.assertNotEqual(report["scope_check"], "in scope")
        self.assertEqual(report["research_verdict"], "out_of_scope")
        self.assertIn("statistics", report)


class AdvanceGateTests(PairedABTestCase):
    def test_a_psnr_only_improvement_does_not_advance(self):
        """The acceptance tiers carry only loss maxima and no gain criterion, so they mean
        nothing until this gate has established that something improved. A change that
        buys PSNR while leaving LPIPS flat is not accepted under v1."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm("candidate", {"bicycle": 25.5})
        report = self.compare(baseline, candidate)
        self.assertGreater(report["medians"]["psnr"], 0)
        self.assertEqual(report["research_verdict"], "does_not_advance")

    def test_an_lpips_gain_inside_four_sd_does_not_advance(self):
        baseline = self.arm("baseline", {"bicycle": 25.0}, lpips=0.15, jitter=0.4)
        candidate = self.arm("candidate", {"bicycle": 25.0}, lpips=0.13, jitter=0.4)
        self.assertEqual(
            self.compare(baseline, candidate)["research_verdict"], "does_not_advance"
        )

    def test_a_veto_still_outranks_the_advance_gate(self):
        baseline, candidate = [], []
        for replicate in range(1, 4):
            good = flat(30.0, VIEW_COUNTS["bicycle"])
            bad = list(good)
            bad[0] = 28.0
            baseline.append(self.workspace.write(
                "bicycle", "baseline", replicate, good,
                lpips_squeeze=flat(0.15, VIEW_COUNTS["bicycle"])))
            candidate.append(self.workspace.write(
                "bicycle", "candidate", replicate, bad,
                lpips_squeeze=flat(0.13, VIEW_COUNTS["bicycle"])))
        self.assertEqual(self.compare(baseline, candidate)["research_verdict"], "veto")


class ReceiptIntegrityTests(PairedABTestCase):
    def test_a_receipt_without_a_metrics_digest_is_refused(self):
        """Every receipt written before the runner existed lacks one. Admitting them would
        let a hand-edited metrics file produce an ordinary verdict."""
        path = self.workspace.write("bicycle", "baseline", 1, flat(25.0, 25), digest=False)
        with self.assertRaises(paired.ArmError) as raised:
            paired.load_run(path)
        self.assertIn("metrics_sha256", str(raised.exception))

    def test_a_non_finite_metric_is_refused(self):
        """The scorer emits inf for a bit-exact render. An infinite candidate PSNR would
        satisfy every loss comparison rather than being unevaluable."""
        path = self.workspace.write("bicycle", "baseline", 1, [float("inf")] * 25)
        with self.assertRaises(paired.ArmError) as raised:
            paired.load_run(path)
        self.assertIn("non-finite", str(raised.exception))

    def test_the_same_receipt_supplied_three_times_is_not_three_replicates(self):
        """The contract's replicate unit is a whole training run. Counting command-line
        entries would let one run stand in for three."""
        one = self.workspace.write("bicycle", "baseline", 1, flat(25.0, 25))
        two = self.workspace.write("bicycle", "candidate", 1, flat(25.0, 25))
        report = self.compare([one, one, one], [two, two, two])
        self.assertEqual(report["research_verdict"], "duplicate_receipt")

    def test_distinct_files_claiming_the_same_replicate_are_refused(self):
        first = self.workspace.write("bicycle", "baseline", 1, flat(25.0, 25))
        copied = first.with_name("copy.json")
        copied.write_text(first.read_text(), encoding="utf-8")
        (copied.with_name("copy.metrics.json")).write_text(
            first.with_name(first.stem + ".metrics.json").read_text(), encoding="utf-8"
        )
        candidate = self.arm("candidate", {"bicycle": 25.0})
        report = self.compare([first, copied, first.with_name(first.name)], candidate)
        self.assertIn(report["research_verdict"], {"duplicate_receipt", "duplicate_replicate"})


class TrainerProvenanceTests(PairedABTestCase):
    def test_arms_built_from_different_trainers_are_refused(self):
        """The shipped toolchain and the tree under test are different binaries, and
        benchmarking the wrong one costs about 0.3 dB on stump. Two arms that do not share
        a trainer are two experiments, not an A/B."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing({"bicycle": 25.0}, trainer="sha256:" + "d" * 64)
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "trainer_mismatch")

    def test_a_run_that_does_not_name_its_trainer_is_refused(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing({"bicycle": 25.0}, trainer=None)
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "missing_provenance")
        self.assertIn("trainer_sha256", report["refusal"])


class SuiteScopeTests(PairedABTestCase):
    def test_a_single_scene_screen_cannot_be_reported_as_an_acceptance(self):
        """The contract's suite is seven scenes. One scene is a screen -- often the right
        thing to run -- but reporting it as `accept` claims a contract verdict it does not
        have, and that is exactly what this tool existed to stop."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing({"bicycle": 25.1})
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "out_of_scope")
        self.assertIn("1 of 7 suite scenes", str(report["scope_check"]))
        self.assertIn("statistics", report, "the screen's numbers are still reported")

    def test_the_full_suite_can_accept(self):
        scenes = {name: 30.0 for name in VIEW_COUNTS}
        baseline = self.arm("baseline", scenes)
        candidate = self.advancing({k: v - 0.1 for k, v in scenes.items()})
        report = self.compare(baseline, candidate)
        self.assertEqual(report["scope_check"], "in scope")
        self.assertEqual(report["research_verdict"], "accept")

    def test_the_scene_count_comes_from_the_contract(self):
        self.assertEqual(paired.scenes_required(json.loads(CONTRACT.read_text())), 7)


class ArmDifferenceTests(PairedABTestCase):
    def test_an_environment_only_experiment_is_reported_as_such(self):
        """The trainer takes experiment toggles from the environment, so the argv and the
        binary can be identical across arms and the run still be a real experiment."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing({"bicycle": 25.0},
                                   environment={"EASYSPLAT_SPLIT_FRACTION": "65"})
        report = self.compare(baseline, candidate)
        self.assertEqual(report["arms_differ_by"], ["environment: EASYSPLAT_SPLIT_FRACTION"])

    def test_identically_configured_arms_say_so(self):
        """An unexported variable produces two identical arms and a delta of nothing. That
        has to read as "the experiment did not run", not as "the change had no effect"."""
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm("candidate", {"bicycle": 25.0})
        report = self.compare(baseline, candidate)
        self.assertIn("null", report["arms_differ_by"])

    def test_a_budget_difference_is_named(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.advancing({"bicycle": 25.0})
        for path in candidate:
            body = json.loads(path.read_text())
            body["memory_budget_bytes"] = 46_000_000_000
            path.write_text(json.dumps(body, indent=2), encoding="utf-8")
        self.assertEqual(self.compare(baseline, candidate)["arms_differ_by"], ["memory budget"])


class ViewSetTests(PairedABTestCase):
    def test_arms_that_disagree_on_the_view_set_are_refused(self):
        """Taking the view list from one run would drop a candidate-only view from the
        veto entirely, which is the direction that hides a regression."""
        names = [f"v{i:03d}.JPG" for i in range(25)]
        baseline = [
            self.workspace.write("bicycle", "baseline", r, flat(30.0, 25), names=names)
            for r in range(1, 4)
        ]
        candidate = [
            self.workspace.write("bicycle", "candidate", r, flat(30.0, 26),
                                 names=names + ["extra.JPG"])
            for r in range(1, 4)
        ]
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "view_set_mismatch")
        self.assertIn("extra.JPG", report["refusal"])


class ScopeMatchTests(PairedABTestCase):
    def test_a_substring_of_the_scope_iteration_count_is_out_of_scope(self):
        """4000 is a substring of "40000 iterations" and must not pass as in scope."""
        baseline = self.arm("baseline", {"bicycle": 25.0}, iterations=4000)
        candidate = self.advancing({"bicycle": 25.0}, iterations=4000)
        report = self.compare(baseline, candidate)
        self.assertNotEqual(report["scope_check"], "in scope")
        self.assertEqual(report["research_verdict"], "out_of_scope")

    def test_a_receipt_that_declares_nothing_is_out_of_scope_not_exempt(self):
        baseline = self.arm("baseline", {"bicycle": 25.0},
                            profile=None, iterations=None, holdout_every=None)
        candidate = self.advancing({"bicycle": 25.0},
                                   profile=None, iterations=None, holdout_every=None)
        report = self.compare(baseline, candidate)
        self.assertEqual(report["research_verdict"], "out_of_scope")


class PairingTests(PairedABTestCase):
    def test_block_scheduled_runs_are_not_treated_as_paired(self):
        """Three baselines then three candidates is not the alternating schedule the
        contract asks for, so the paired median is unavailable and cannot veto."""
        baseline = [
            self.workspace.write("bicycle", "baseline", r, flat(30.0, 25),
                                 started_at=f"2026-07-28T0{r}:00:00+00:00")
            for r in range(1, 4)
        ]
        candidate = [
            self.workspace.write("bicycle", "candidate", r, flat(28.0, 25),
                                 started_at=f"2026-07-28T1{r}:00:00+00:00")
            for r in range(1, 4)
        ]
        report = self.compare(baseline, candidate)
        self.assertFalse(report["statistics"]["paired_per_view"])
        self.assertEqual(report["veto"], [], "no paired median means no veto verdict")

    def test_alternating_runs_are_paired(self):
        baseline, candidate = [], []
        for replicate in range(1, 4):
            baseline.append(self.workspace.write(
                "bicycle", "baseline", replicate, flat(30.0, 25),
                started_at=f"2026-07-28T{2 * replicate:02d}:00:00+00:00"))
            candidate.append(self.workspace.write(
                "bicycle", "candidate", replicate, flat(30.0, 25),
                started_at=f"2026-07-28T{2 * replicate + 1:02d}:00:00+00:00"))
        self.assertTrue(self.compare(baseline, candidate)["statistics"]["paired_per_view"])


class GatingBackboneTests(PairedABTestCase):
    def test_without_squeezenet_the_advance_gate_is_unevaluable_not_vgg(self):
        """The contract gates on SqueezeNet precisely so a candidate cannot be accepted by
        the features it optimizes. Falling back to VGG would defeat that."""
        baseline = self.arm("baseline", {"bicycle": 25.0}, include_squeeze=False)
        candidate = self.arm("candidate", {"bicycle": 25.0}, include_squeeze=False)
        report = self.compare(baseline, candidate)
        self.assertIsNone(report["advance_to_consideration"])
        self.assertIn("advance_to_consideration", report["not_evaluable"])

    def test_the_unreachable_human_preference_tier_is_reported_not_skipped(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm("candidate", {"bicycle": 25.0})
        report = self.compare(baseline, candidate)
        self.assertIn("perceptual_trade_acceptance", report["not_evaluable"])

    def test_both_verdicts_are_stated(self):
        baseline = self.arm("baseline", {"bicycle": 25.0})
        candidate = self.arm("candidate", {"bicycle": 25.0})
        report = self.compare(baseline, candidate)
        self.assertTrue(report["dual_verdict_required"])
        self.assertEqual(report["current_release_gate_verdict"], "not_evaluated")


if __name__ == "__main__":
    unittest.main()
