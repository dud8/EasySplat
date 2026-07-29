#!/usr/bin/env python3
"""Compare two arms of a training experiment against the research-quality contract.

Every A/B this project has run was compared by a throwaway script, and none of them
survive. `contracts/research-quality-v1.json` has declared the replication rule, the
equal-weight median and the per-view veto since it was written, and nothing has ever
executed it. This does.

No threshold appears in this file. Only key paths do, and a contract missing one of them
is an error rather than a default -- a policy change should break the tool, not be quietly
absorbed by it. Every verdict records the contract's digest, which is the binding the
contract's own immutability clause asks for.

Three statistics are easy to get wrong here and are therefore spelled out rather than
inlined:

  * The headline median is over per-scene deltas, equally weighted. Held-out view counts
    run from 16 (stump) to 39 (room), so a median over pooled per-view deltas would weight
    scenes by view count and is forbidden by the contract.
  * The pooled repeat SD is the two-sample pool of the within-arm sample SDs. The standard
    error of a delta is smaller by sqrt(1/Ra + 1/Rb), and both are reported, but the gate
    reads SD because that is what the contract says and it is the harder bar.
  * The per-view SD used by the veto takes the larger of the per-view pool and the
    scene-wide pool. At three replicates a per-view estimate has four degrees of freedom
    and can collapse toward zero by chance, which would turn an ordinary delta into a
    twenty-sigma hard veto.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import statistics
import sys

CONTRACT_NAME = "research-quality-v1"
CONTRACT_SCHEMA_VERSION = 1

# Every value read from the contract, as a path. Walked before anything else runs so a
# renamed or removed key names itself instead of silently defaulting.
REQUIRED_CONTRACT_PATHS = (
    ("statistics", "median_definition"),
    ("statistics", "sd_definition"),
    ("statistics", "stochastic_replication", "minimum_runs_per_arm"),
    ("statistics", "stochastic_replication", "runs_per_arm_near_a_gate"),
    ("gates", "advance_to_consideration", "median_lpips_improvement_min"),
    ("gates", "advance_to_consideration", "sd_multiple_min"),
    ("gates", "advance_to_consideration", "lpips_backbone"),
    ("gates", "metric_preserving_acceptance", "median_psnr_loss_db_max"),
    ("gates", "metric_preserving_acceptance", "median_ssim_loss_max"),
    ("gates", "perceptual_trade_acceptance", "blinded_human_preference_min"),
    ("gates", "reject", "median_psnr_loss_db_above"),
    ("gates", "reject", "median_ssim_loss_above"),
    ("gates", "per_view_veto_stochastic", "paired_per_view_median_psnr_loss_db_max"),
    ("gates", "per_view_veto_stochastic", "paired_per_view_median_ssim_loss_max"),
    ("gates", "per_view_veto_stochastic", "require_beyond_pooled_per_view_sd"),
    ("relationship_to_release_gate", "dual_verdict_required"),
    ("scope", "suite"),
    ("scope", "profile"),
    ("scope", "seed"),
    ("scope", "holdout"),
)

# LPIPS is lower-better, so its "improvement" has the opposite sign to PSNR and SSIM.
LOWER_IS_BETTER = frozenset({"lpips_vgg", "lpips_squeeze"})
METRICS = ("psnr", "ssim", "lpips_vgg", "lpips_squeeze")


class ContractError(RuntimeError):
    pass


class ArmError(RuntimeError):
    pass


def load_contract(path: pathlib.Path) -> tuple[dict, str]:
    raw = path.read_bytes()
    contract = json.loads(raw)
    if contract.get("contract") != CONTRACT_NAME:
        raise ContractError(f"{path}: not {CONTRACT_NAME}")
    if contract.get("schema_version") != CONTRACT_SCHEMA_VERSION:
        raise ContractError(f"{path}: schema_version is not {CONTRACT_SCHEMA_VERSION}")
    for keys in REQUIRED_CONTRACT_PATHS:
        node = contract
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                raise ContractError(f"{path}: missing {'.'.join(keys)}")
            node = node[key]
    return contract, "sha256:" + hashlib.sha256(raw).hexdigest()


def at(contract: dict, *keys):
    node = contract
    for key in keys:
        node = node[key]
    return node


def load_run(path: pathlib.Path) -> dict:
    """One run record plus the per-view rows from its metrics sibling."""
    record = json.loads(path.read_text(encoding="utf-8"))
    metrics_path = path.with_name(path.stem + ".metrics.json")
    if not metrics_path.is_file():
        raise ArmError(f"{path.name}: no metrics file beside it")
    raw = metrics_path.read_bytes()
    declared = record.get("metrics_sha256")
    actual = "sha256:" + hashlib.sha256(raw).hexdigest()
    # Required, not merely checked when present. A record without a digest is one of the
    # receipts written before this existed, and admitting it would let a hand-edited
    # metrics file produce an ordinary verdict.
    if not declared:
        raise ArmError(f"{path.name}: no metrics_sha256; the receipt cannot be bound")
    if declared != actual:
        raise ArmError(f"{path.name}: metrics file does not match its recorded digest")
    metrics = json.loads(raw)
    views = metrics["views"]
    rows = {row["name"]: row for row in views}
    if not rows:
        raise ArmError(f"{path.name}: no per-view rows")
    if len(rows) != len(views):
        raise ArmError(f"{path.name}: a held-out view name is repeated")
    # The scorer emits inf for a bit-exact render. It has never happened, but an infinite
    # candidate PSNR would satisfy every loss comparison rather than being unevaluable.
    for name, row in rows.items():
        for metric in METRICS:
            value = row.get(metric)
            if value is not None and not math.isfinite(value):
                raise ArmError(f"{path.name}: {name} has a non-finite {metric}")
    return {
        "path": str(path),
        "scene": record["scene"],
        "arm": record.get("arm"),
        "replicate": record.get("replicate"),
        "started_at": record.get("started_at"),
        "profile": record.get("profile"),
        "iterations": record.get("iteration_override"),
        "seed": record.get("seed"),
        "holdout_every": record.get("holdout_every"),
        "provenance": record.get("rendering", {}).get("provenance", {}),
        "trainer_sha256": record.get("trainer_sha256"),
        "trainer_environment": record.get("trainer_environment", {}),
        "memory_budget_bytes": record.get("memory_budget_bytes"),
        "rows": rows,
        # Recomputed from the rows rather than trusted: a mismatch means the summary and
        # the rows describe different renders.
        "scene_mean": {
            metric: statistics.fmean(row[metric] for row in rows.values())
            for metric in METRICS if metric in next(iter(rows.values()))
        },
    }


def pooled_sd(a: list[float], b: list[float]) -> float | None:
    """Two-sample pooled sample SD. None when neither arm has a second replicate."""
    degrees = (len(a) - 1) + (len(b) - 1)
    if degrees <= 0:
        return None
    total = 0.0
    for values in (a, b):
        if len(values) > 1:
            total += (len(values) - 1) * statistics.variance(values)
    return (total / degrees) ** 0.5


def scene_statistics(baseline: list[dict], candidate: list[dict]) -> dict:
    """Per-scene deltas, pooled SDs, and the SD multiple, for one scene."""
    result: dict = {"baseline_runs": len(baseline), "candidate_runs": len(candidate)}
    for metric in METRICS:
        if metric not in baseline[0]["scene_mean"]:
            continue
        a = [run["scene_mean"][metric] for run in baseline]
        b = [run["scene_mean"][metric] for run in candidate]
        delta = statistics.fmean(b) - statistics.fmean(a)
        sd = pooled_sd(a, b)
        result[metric] = {
            "baseline": statistics.fmean(a),
            "candidate": statistics.fmean(b),
            "delta": delta,
            "pooled_repeat_sd": sd,
            "delta_standard_error": None if sd is None
            else sd * (1 / len(a) + 1 / len(b)) ** 0.5,
            "sd_multiple": None if not sd else abs(delta) / sd,
        }
    return result


def per_view_statistics(baseline: list[dict], candidate: list[dict], names: list[str]) -> dict:
    """Per-view deltas and the SD the veto divides by.

    Two delta estimators, because the contract asks for both by name: the mean difference
    feeds the scene means, and the paired median under the recorded run order is what the
    veto key is called. The paired form needs equal replicate counts and an alternating
    schedule; without either it is reported as unevaluable rather than approximated.
    """
    paired = len(baseline) == len(candidate) and is_alternating(baseline, candidate)
    # Zip by recorded start time, not by the order the paths arrived on the command line:
    # the alternation check reads timestamps, so pairing by argv could subtract unrelated
    # repetitions from each other while still reporting the comparison as paired.
    if paired:
        baseline = sorted(baseline, key=lambda run: run["started_at"])
        candidate = sorted(candidate, key=lambda run: run["started_at"])
    views: dict[str, dict] = {}
    scene_pool: dict[str, tuple[float, int]] = {}

    for metric in ("psnr", "ssim"):
        total, degrees = 0.0, 0
        for name in names:
            for arm in (baseline, candidate):
                values = [run["rows"][name][metric] for run in arm]
                if len(values) > 1:
                    total += (len(values) - 1) * statistics.variance(values)
                    degrees += len(values) - 1
        scene_pool[metric] = ((total / degrees) ** 0.5 if degrees else 0.0, degrees)

    for name in names:
        entry: dict = {}
        for metric in ("psnr", "ssim"):
            a = [run["rows"][name][metric] for run in baseline]
            b = [run["rows"][name][metric] for run in candidate]
            local = pooled_sd(a, b)
            entry[metric] = {
                "mean_delta": statistics.fmean(b) - statistics.fmean(a),
                "paired_median_delta": statistics.median(
                    y - x for x, y in zip(a, b)
                ) if paired else None,
                # The larger of the two pools. A per-view estimate at three replicates has
                # four degrees of freedom and can land near zero by chance; the scene pool
                # cannot, and vetoing on a fluke-small denominator is the failure mode the
                # contract's own note warns against.
                "veto_sd": max(local or 0.0, scene_pool[metric][0]),
            }
        views[name] = entry
    return {"paired": paired, "views": views,
            "scene_pool_degrees_of_freedom": {k: v[1] for k, v in scene_pool.items()}}


def is_alternating(baseline: list[dict], candidate: list[dict]) -> bool:
    """Whether the runs were interleaved rather than run as two blocks.

    The contract's pairing clause says alternating fresh processes on a quiet host. It only
    has teeth if the runner stamps a start time and something checks it; this is that check.
    """
    stamps = [(run["started_at"], "a") for run in baseline]
    stamps += [(run["started_at"], "b") for run in candidate]
    if any(stamp is None for stamp, _ in stamps):
        return False
    order = [side for _, side in sorted(stamps)]
    return all(first != second for first, second in zip(order, order[1:]))


def median_or_none(values: list[float | None]) -> float | None:
    present = [value for value in values if value is not None]
    return statistics.median(present) if present else None


def evaluate(contract: dict, scenes: dict, per_view: dict) -> dict:
    """The verdict, in the contract's own precedence."""
    def headline(metric: str) -> float | None:
        return median_or_none([scenes[s].get(metric, {}).get("delta") for s in scenes])

    def multiples(metric: str) -> float | None:
        # Median of the per-scene ratios, not a ratio of medians: a median has no closed
        # form SD, and the contract's equal weighting applies to scenes either way.
        return median_or_none([scenes[s].get(metric, {}).get("sd_multiple") for s in scenes])

    psnr, ssim = headline("psnr"), headline("ssim")
    gating = "lpips_" + at(contract, "gates", "advance_to_consideration", "lpips_backbone")
    gating = {"lpips_squeezenet": "lpips_squeeze"}.get(gating, gating)
    lpips = headline(gating)

    veto = []
    veto_limits = at(contract, "gates", "per_view_veto_stochastic")
    multiple_min = veto_limits["require_beyond_pooled_per_view_sd"]
    for name, entry in per_view["views"].items():
        for metric, key in (
            ("psnr", "paired_per_view_median_psnr_loss_db_max"),
            ("ssim", "paired_per_view_median_ssim_loss_max"),
        ):
            delta = entry[metric]["paired_median_delta"]
            sd = entry[metric]["veto_sd"]
            if delta is None or delta > -veto_limits[key]:
                continue
            if sd and abs(delta) <= multiple_min * sd:
                continue
            veto.append({"view": name, "metric": metric, "paired_median_delta": delta,
                         "veto_sd": sd, "limit": -veto_limits[key]})

    not_evaluable = {}
    if lpips is None:
        not_evaluable["advance_to_consideration"] = (
            f"no {gating} in the per-view rows; the contract gates on "
            f"{at(contract, 'gates', 'advance_to_consideration', 'lpips_backbone')}"
        )
    not_evaluable["perceptual_trade_acceptance"] = (
        "blinded_human_preference has no source in this pipeline, so the tier is unreachable"
    )

    advance = None
    if lpips is not None:
        gate = at(contract, "gates", "advance_to_consideration")
        multiple = multiples(gating)
        advance = bool(
            -lpips >= gate["median_lpips_improvement_min"]
            and multiple is not None and multiple >= gate["sd_multiple_min"]
        )

    if veto:
        verdict = "veto"
    elif psnr is None or ssim is None or advance is None:
        verdict = "not_evaluable"
    elif not advance:
        # "A candidate that does not clear this is not evaluated further." The acceptance
        # tiers below carry only loss maxima and no gain criterion, so they only mean
        # anything once this gate has established that something improved. This is how the
        # ramped tail cull was adjudicated: its LPIPS delta was 0.0000 and it was rejected
        # without the PSNR column being weighed at all.
        verdict = "does_not_advance"
    else:
        preserving = at(contract, "gates", "metric_preserving_acceptance")
        rejecting = at(contract, "gates", "reject")
        if (-psnr <= preserving["median_psnr_loss_db_max"]
                and -ssim <= preserving["median_ssim_loss_max"]):
            verdict = "accept"
        else:
            # Everything short of metric-preserving is a rejection under v1. The
            # perceptual-trade tier that sits between them needs a blinded human
            # preference, which this pipeline has no source for, so it is reported
            # unreachable rather than silently skipped.
            verdict = "reject"
            report_rejecting = (
                -psnr > rejecting["median_psnr_loss_db_above"]
                or -ssim > rejecting["median_ssim_loss_above"]
            )
            verdict = "reject" if report_rejecting else "reject"

    return {
        "medians": {"psnr": psnr, "ssim": ssim, gating: lpips,
                    "lpips_vgg": headline("lpips_vgg")},
        "sd_multiples": {metric: multiples(metric) for metric in METRICS},
        "sd_multiple_interpretation":
            "median over scenes of |per-scene delta| / pooled per-scene repeat SD",
        "advance_to_consideration": advance,
        "veto": veto,
        "not_evaluable": not_evaluable,
        "research_verdict": verdict,
        "current_release_gate_verdict": "not_evaluated",
        "current_release_gate_reason":
            "the release gate runs easysplat_benchmark.py over a different corpus; this "
            "tool cannot produce it, and the contract requires both verdicts to be stated",
        "dual_verdict_required": at(
            contract, "relationship_to_release_gate", "dual_verdict_required"
        ),
    }


def declares(text: str, value) -> bool:
    """Whether the contract's prose names this exact value.

    On word boundaries rather than as a substring: 4,000 iterations is a substring of
    "40000 iterations" and would otherwise pass as in scope. An ordinal suffix is allowed
    because the contract spells the holdout rule "every 8th filename-sorted camera".
    """
    pattern = rf"(?<![\w.]){re.escape(str(value))}(?:st|nd|rd|th)?(?![\w.])"
    return re.search(pattern, text) is not None


def scenes_required(contract: dict) -> int | None:
    """How many scenes the contract's suite is, read from its own prose.

    `scope.suite` reads "mip-NeRF 360, 7 public scenes". The count is the only part this
    tool needs and hardcoding it here would put a threshold back in the Python.
    """
    match = re.search(r"(\d+)\s+\w*\s*scenes", str(at(contract, "scope", "suite")))
    return int(match.group(1)) if match else None


def check_scope(contract: dict, runs: list[dict]) -> list[str]:
    scope = at(contract, "scope")
    problems = []
    # The suite is the seven scenes, not whichever subset was run. A single-scene
    # comparison is a screen and can be a perfectly good one, but it is not the
    # contract's acceptance and must not be reported as it.
    required = scenes_required(contract)
    present = {run["scene"] for run in runs}
    if required is not None and len(present) < required:
        problems.append(
            f"{len(present)} of {required} suite scenes: {sorted(present)}"
        )
    for run in runs:
        # Absent is out of scope, not exempt. A receipt that does not say what it ran is
        # exactly the receipt that must not reach an acceptance.
        for field in ("profile", "iterations", "seed", "holdout_every"):
            if run[field] is None:
                problems.append(f"{run['path']}: does not declare {field}")
        if run["profile"] and not declares(str(scope["profile"]), run["profile"]):
            problems.append(f"{run['path']}: profile {run['profile']} is outside scope")
        if run["iterations"] and not declares(str(scope["profile"]), run["iterations"]):
            problems.append(f"{run['path']}: {run['iterations']} iterations is outside scope")
        if run["seed"] is not None and run["seed"] != scope["seed"]:
            problems.append(f"{run['path']}: seed {run['seed']} is outside scope")
        if (run["holdout_every"] is not None
                and not declares(str(scope["holdout"]), run["holdout_every"])):
            problems.append(
                f"{run['path']}: holdout every {run['holdout_every']} is outside scope"
            )
    return problems


def arms_differ_by(baseline: list[dict], candidate: list[dict]) -> list[str] | str:
    """What actually distinguishes the two arms.

    The trainer reads experiment toggles from the environment, so an arm can be
    misconfigured -- an unexported variable, a typo -- and still produce a complete,
    well-formed receipt. The comparison then reads as "no effect" when what happened is
    "the experiment did not run". Stating the difference makes the two distinguishable,
    and a genuinely null comparison says so rather than looking like a failed one.
    """
    differences = []
    for label, key in (("trainer binary", "trainer_sha256"),
                       ("memory budget", "memory_budget_bytes")):
        if {run[key] for run in baseline} != {run[key] for run in candidate}:
            differences.append(label)
    environments = [
        {frozenset(run["trainer_environment"].items()) for run in arm}
        for arm in (baseline, candidate)
    ]
    if environments[0] != environments[1]:
        keys = set()
        for arm in (baseline, candidate):
            for run in arm:
                keys |= set(run["trainer_environment"])
        differing = sorted(
            key for key in keys
            if {run["trainer_environment"].get(key) for run in baseline}
            != {run["trainer_environment"].get(key) for run in candidate}
        )
        differences.append("environment: " + ", ".join(differing))
    return differences or "nothing -- the arms are identically configured, so this is a null"


def refuse(runs: list[dict], minimum: int, renderer_mismatch_is_fatal: bool) -> str | None:
    """The refusals, in precedence order. Returns a reason, or None to proceed."""
    paths = [run["path"] for run in runs]
    if len(set(paths)) != len(paths):
        repeated = sorted({path for path in paths if paths.count(path) > 1})
        return f"duplicate_receipt: {repeated} supplied more than once"
    identities = [(run["arm"], run["scene"], run["replicate"]) for run in runs]
    if len(set(identities)) != len(identities):
        # The contract's replicate unit is a whole training run. Counting entries rather
        # than run identities would let one run stand in for three.
        repeated = sorted({f"{a}/{s}/r{r}" for a, s, r in identities
                           if identities.count((a, s, r)) > 1})
        return f"duplicate_replicate: {repeated} appears more than once"
    for run in runs:
        missing = [k for k in ("sort_ordering", "metalsplatter_source_sha256")
                   if not run["provenance"].get(k)]
        if missing:
            return f"missing_provenance: {run['path']} has no {', '.join(missing)}"
    orderings = {run["provenance"]["sort_ordering"] for run in runs}
    sources = {run["provenance"]["metalsplatter_source_sha256"] for run in runs}
    if len(orderings) > 1 or len(sources) > 1:
        if renderer_mismatch_is_fatal:
            return (f"renderer_mismatch: sort orderings {sorted(orderings)}, "
                    f"{len(sources)} distinct MetalSplatter trees")
    if any(run["trainer_sha256"] is None for run in runs):
        return "missing_provenance: a run does not record trainer_sha256"
    trainers = {run["trainer_sha256"] for run in runs}
    if len(trainers) > 1:
        # Two arms built from different trainers is not a trainer A/B, it is two
        # experiments. The shipped toolchain and the tree under test are different
        # binaries, and defaulting to the wrong one costs about 0.3 dB on stump.
        return f"trainer_mismatch: {len(trainers)} distinct trainer binaries"
    by_arm: dict[str, set[str]] = {}
    for run in runs:
        by_arm.setdefault(run["arm"] or "?", set()).add(run["scene"])
    if len(set(map(frozenset, by_arm.values()))) > 1:
        return f"scene_set_mismatch: {({k: sorted(v) for k, v in by_arm.items()})}"
    counts: dict[tuple[str, str], int] = {}
    for run in runs:
        counts[(run["arm"] or "?", run["scene"])] = counts.get(
            (run["arm"] or "?", run["scene"]), 0
        ) + 1
    short = {f"{arm}/{scene}": n for (arm, scene), n in counts.items() if n < minimum}
    if short:
        return f"insufficient_replication: {short} against minimum {minimum}"
    by_scene: dict[str, set[frozenset]] = {}
    for run in runs:
        by_scene.setdefault(run["scene"], set()).add(frozenset(run["rows"]))
    for scene, sets in by_scene.items():
        if len(sets) > 1:
            # Taking the view list from one run would drop a candidate-only view from the
            # veto entirely, which is the direction that hides a regression.
            union, common = set().union(*sets), set.intersection(*map(set, sets))
            return (f"view_set_mismatch: {scene} replicates disagree on "
                    f"{sorted(union - common)}")
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", nargs="+", required=True, type=pathlib.Path)
    parser.add_argument("--candidate", nargs="+", required=True, type=pathlib.Path)
    parser.add_argument("--contract", required=True, type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument(
        "--renderer-mismatch", choices=("refuse", "report-only"), default="refuse",
        help="report-only forces out_of_scope; it can never produce an accept"
    )
    arguments = parser.parse_args()

    contract, digest = load_contract(arguments.contract)
    baseline = [load_run(path) for path in arguments.baseline]
    candidate = [load_run(path) for path in arguments.candidate]
    for run, arm in [(r, "baseline") for r in baseline] + [(r, "candidate") for r in candidate]:
        run["arm"] = arm
    runs = baseline + candidate

    minimum = at(contract, "statistics", "stochastic_replication", "minimum_runs_per_arm")
    reason = refuse(runs, minimum, arguments.renderer_mismatch == "refuse")
    scope_problems = check_scope(contract, runs)

    report: dict = {
        "contract": CONTRACT_NAME,
        "arms_differ_by": arms_differ_by(baseline, candidate),
        "research_contract_sha256": digest,
        "research_contract_path": str(arguments.contract),
        "arms": {
            arm: [{k: run[k] for k in
                   ("path", "scene", "replicate", "started_at", "seed", "holdout_every")}
                  for run in group]
            for arm, group in (("baseline", baseline), ("candidate", candidate))
        },
        "scope_check": scope_problems or "in scope",
    }

    if reason:
        report["research_verdict"] = reason.split(":", 1)[0]
        report["refusal"] = reason
    else:
        scenes = {}
        per_view: dict = {"views": {}, "paired": True}
        for scene in sorted({run["scene"] for run in runs}):
            a = [run for run in baseline if run["scene"] == scene]
            b = [run for run in candidate if run["scene"] == scene]
            scenes[scene] = scene_statistics(a, b)
            view_stats = per_view_statistics(a, b, sorted(a[0]["rows"]))
            per_view["paired"] = per_view["paired"] and view_stats["paired"]
            for name, entry in view_stats["views"].items():
                per_view["views"][f"{scene}/{name}"] = entry
        report["statistics"] = {"per_scene": scenes,
                                "paired_per_view": per_view["paired"]}
        report.update(evaluate(contract, scenes, per_view))
        report["per_view_tail"] = tail(per_view)
        if scope_problems and report["research_verdict"] == "accept":
            report["research_verdict"] = "out_of_scope"
        if arguments.renderer_mismatch == "report-only":
            report["research_verdict"] = "out_of_scope"
            report["refusal"] = "renderer mismatch reported rather than refused"

    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(text, encoding="utf-8")
    print(summarize(report))
    return 0


def tail(per_view: dict) -> dict:
    """The worst per-view deltas, per scene as well as pooled.

    Pooled alone would be a room list: room has 39 held-out views and stump 16.
    """
    rows = [
        {"view": name, "psnr_delta": entry["psnr"]["mean_delta"],
         "ssim_delta": entry["ssim"]["mean_delta"],
         "veto_sd": entry["psnr"]["veto_sd"]}
        for name, entry in per_view["views"].items()
    ]
    rows.sort(key=lambda row: row["psnr_delta"])
    per_scene = {}
    for row in rows:
        scene = row["view"].split("/", 1)[0]
        per_scene.setdefault(scene, row)
    deltas = sorted(row["psnr_delta"] for row in rows)
    return {
        "worst_ten": rows[:10],
        "worst_per_scene": per_scene,
        "count_below_half_db": sum(1 for value in deltas if value < -0.5),
        "count_below_one_db": sum(1 for value in deltas if value < -1.0),
        "quantiles": {
            name: deltas[min(len(deltas) - 1, int(len(deltas) * fraction))]
            for name, fraction in (("p01", 0.01), ("p05", 0.05), ("p10", 0.10))
        },
    }


def summarize(report: dict) -> str:
    differ = report["arms_differ_by"]
    lines = [f"contract {report['research_contract_sha256'][:19]}",
             f"scope    {report['scope_check']}",
             f"arms     {differ if isinstance(differ, str) else ', '.join(differ)}"]
    if "statistics" in report:
        lines.append("")
        lines.append(f"{'scene':<10s} {'base':>9s} {'cand':>9s} {'delta':>8s} "
                     f"{'sd':>7s} {'k':>6s}")
        for scene, entry in report["statistics"]["per_scene"].items():
            psnr = entry.get("psnr", {})
            sd, k = psnr.get("pooled_repeat_sd"), psnr.get("sd_multiple")
            lines.append(
                f"{scene:<10s} {psnr.get('baseline', 0):9.4f} {psnr.get('candidate', 0):9.4f} "
                f"{psnr.get('delta', 0):+8.4f} "
                f"{'--' if sd is None else format(sd, '7.4f')} "
                f"{'--' if k is None else format(k, '6.2f')}"
            )
        medians = report["medians"]
        lines.append(f"{'median':<10s} {'':>9s} {'':>9s} {medians['psnr']:+8.4f}")
        if report["veto"]:
            lines.append(f"VETO on {len(report['veto'])} view(s)")
    lines.append("")
    lines.append(f"research verdict:     {report['research_verdict']}")
    if "refusal" in report:
        lines.append(f"  {report['refusal']}")
    lines.append(f"release gate verdict: {report.get('current_release_gate_verdict', 'n/a')}")
    return "\n".join(lines)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, ArmError) as error:
        print(f"paired_ab: {error}", file=sys.stderr)
        raise SystemExit(2)
