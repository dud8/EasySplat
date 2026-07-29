#!/usr/bin/env python3
"""Train one Mip-NeRF 360 scene, render its held-out views, and score them.

One invocation is one replicate of one arm. That is the unit the research contract
replicates over, and it is why `--arm` and `--replicate` are not optional decoration: the
tag they build is what keeps two runs of the same configuration from overwriting each
other. Without them `minimum_runs_per_arm` is unreachable, which is what it had been.

The run record is written to be readable in a month without shell history, so it carries
the resolved trainer argv verbatim, the seed, the holdout rule, digests of the trainer and
the scored metrics, and the renderer provenance the driver reports about itself. A run
missing any of that cannot enter a paired comparison -- see `paired_ab.py` -- which is the
mechanism that quarantines every number produced before this existed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import resource
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BENCH = Path(__file__).resolve().parent / "bench.py"

# Flags this script owns. A `--trainer-arg` naming one of them would be resolved by the
# trainer's last-wins parsing, and the run record would then disagree with what ran.
MANAGED_TRAINER_FLAGS = frozenset({
    "--dataset", "--output", "--checkpoint", "--profile", "--holdout-every",
    "--seed", "--memory-budget-bytes", "--events-fd", "--iteration-limit",
    "--plateau-window",
})


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def trainer_arguments(
    trainer: Path,
    dataset: Path,
    ply: Path,
    checkpoint: Path,
    profile: str,
    seed: int,
    holdout_every: int,
    budget: int,
    iterations: int | None,
    plateau_window: int | None,
    extra: list[str],
) -> list[str]:
    """The trainer command line, as a pure function so a change to it is a test failure.

    Kept separate from `train` because the defaults here reproduce every historical run:
    seed 42, holdout every 8th camera, and a plateau window of a tenth of the iteration
    budget. A silent change to any of them moves every number without failing anything.
    """
    for value in extra:
        flag = value.split("=", 1)[0]
        if flag in MANAGED_TRAINER_FLAGS:
            raise SystemExit(f"--trainer-arg {flag} collides with a flag this runner sets")

    arguments = [
        "caffeinate", "-dimsu",
        str(trainer),
        "--dataset", str(dataset),
        "--output", str(ply),
        "--checkpoint", str(checkpoint),
        "--profile", profile,
        "--holdout-every", str(holdout_every),
        "--seed", str(seed),
        "--memory-budget-bytes", str(budget),
        "--events-fd", "1",
    ]
    if iterations is not None:
        arguments += [
            "--iteration-limit", str(iterations),
            "--plateau-window", str(plateau_window or max(1, iterations // 10)),
        ]
    elif plateau_window is not None:
        arguments += ["--plateau-window", str(plateau_window)]
    return arguments + extra


def train(tag: str, arguments: list[str], events_path: Path, checkpoint: Path) -> dict:
    if checkpoint.exists():
        shutil.rmtree(checkpoint)
    checkpoint.mkdir(parents=True)
    events_path.parent.mkdir(parents=True, exist_ok=True)

    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    spawned = time.monotonic()
    events: list[dict] = []
    with open(events_path, "w", encoding="utf-8") as sink:
        process = subprocess.Popen(
            arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        for line in process.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            event = json.loads(line)
            event["_t"] = time.monotonic() - spawned
            events.append(event)
            sink.write(json.dumps(event) + "\n")
            if event["event"] in ("progress", "holdout_eval", "completed"):
                print(f"    [{event['_t']:7.1f}s] {event['event']:<13s} "
                      f"iter {event.get('iteration', '-')} "
                      f"gaussians {event.get('gaussian_count', '-')} "
                      f"psnr {event.get('holdout_psnr', '-')}", flush=True)
        stderr = process.stderr.read()
        code = process.wait()
    wall = time.monotonic() - spawned
    after = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if code != 0:
        raise SystemExit(f"{tag}: trainer exited {code}\n{stderr}")

    shutil.rmtree(checkpoint, ignore_errors=True)

    def first(name: str) -> dict | None:
        return next((event for event in events if event["event"] == name), None)

    def last(name: str) -> dict | None:
        return next((event for event in reversed(events) if event["event"] == name), None)

    started = first("started")
    final_progress = last("progress")
    holdout = last("holdout_eval")
    completed = last("completed")

    return {
        "stages": {
            "dataset_load_and_init_seconds": started["_t"] if started else None,
            "training_seconds": (final_progress["_t"] - started["_t"])
            if started and final_progress else None,
            "export_and_holdout_seconds": (holdout["_t"] - final_progress["_t"])
            if holdout and final_progress else None,
            "trainer_wall_seconds": wall,
        },
        "trainer_elapsed_seconds": completed["elapsed_seconds"],
        "iterations": completed["iteration"],
        "stop_reason": completed["stop_reason"],
        "gaussian_count": completed["gaussian_count"],
        "peak_resident_bytes": completed["peak_memory_bytes"],
        # RUSAGE_CHILDREN.ru_maxrss is a running high-water mark, not a sum; it is only
        # meaningful when it moved during this run.
        "child_max_rss_bytes": after if after > before else None,
        # Absent when holdout is disabled: the trainer emits no evaluation without a
        # held-out set, so this is None on an oracle or sparse run rather than zero.
        "trainer_holdout_psnr": completed.get("holdout_psnr"),
        "training_camera_count": started["camera_count"],
        "holdout_camera_count": completed.get("holdout_camera_count"),
        "ply_bytes": completed["output_bytes"],
        "scene_radius": completed["scene_radius"],
        "raster_fallback_count": completed["raster_fallback_count"],
        "stderr": stderr.strip()[:2000],
    }


def build_tag(arguments: argparse.Namespace) -> str:
    parts = [arguments.scene, arguments.profile]
    if arguments.iterations:
        parts.append(str(arguments.iterations))
    parts.append(arguments.arm)
    parts.append(f"r{arguments.replicate}")
    return "-".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--workspace", required=True,
                        help="directory holding datasets/, out/, logs/, results/")
    parser.add_argument("--arm", default="baseline",
                        help="which side of a comparison this run belongs to")
    parser.add_argument("--replicate", type=int, default=1,
                        help="which repeat of this arm; replicates must not share a tag")
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--plateau-window", type=int)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--holdout-every", type=int, default=8,
                        help="0 disables holdout; the trainer rejects 1")
    parser.add_argument("--budget", type=int, default=36_000_000_000)
    parser.add_argument("--trainer", type=Path, default=Path.home() / (
        "Library/Application Support/EasySplat/Toolchains/3.0.0/bin/easysplat-train"))
    parser.add_argument("--checkout", type=Path,
                        default=Path(__file__).resolve().parents[3])
    parser.add_argument("--renderer", type=Path,
                        help="defaults to .build/release/EasySplatBenchmarkDriver "
                             "under --checkout")
    parser.add_argument("--trainer-arg", action="append", default=[],
                        help="passed to the trainer verbatim; repeatable")
    parser.add_argument("--keep-renders", action="store_true")
    arguments = parser.parse_args()

    workspace = arguments.workspace and Path(arguments.workspace).resolve()
    renderer = arguments.renderer or (
        arguments.checkout / ".build/release/EasySplatBenchmarkDriver"
    )
    tag = build_tag(arguments)
    dataset = workspace / "datasets" / arguments.scene
    ply = workspace / "out" / f"{tag}.ply"
    result_path = workspace / "results" / f"{tag}.json"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    ply.parent.mkdir(parents=True, exist_ok=True)
    if ply.exists():
        ply.unlink()

    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    command = trainer_arguments(
        trainer=arguments.trainer,
        dataset=dataset,
        ply=ply,
        checkpoint=workspace / "ckpt" / tag,
        profile=arguments.profile,
        seed=arguments.seed,
        holdout_every=arguments.holdout_every,
        budget=arguments.budget,
        iterations=arguments.iterations,
        plateau_window=arguments.plateau_window,
        extra=arguments.trainer_arg,
    )

    print(f"[{tag}] training", flush=True)
    training = train(
        tag, command, workspace / "logs" / f"{tag}.events.jsonl", workspace / "ckpt" / tag
    )

    print(f"[{tag}] rendering held-out views", flush=True)
    request = workspace / "logs" / f"{tag}.request.json"
    manifest = workspace / "logs" / f"{tag}.manifest.json"
    renders = workspace / "renders" / tag
    subprocess.run([
        sys.executable, str(BENCH), "cameras",
        "--dataset", str(dataset),
        "--ply", str(ply),
        "--output-dir", str(renders),
        "--output", str(request),
        # The same rule on both sides. These default independently, and setting only the
        # trainer's would score views the model had trained on.
        "--holdout-every", str(arguments.holdout_every if arguments.holdout_every > 1 else 8),
    ], check=True)
    render_start = time.monotonic()
    subprocess.run([
        str(renderer), "render-views",
        "--request", str(request),
        "--checkout", str(arguments.checkout),
        "--manifest", str(manifest),
    ], check=True)
    render_wall = time.monotonic() - render_start

    print(f"[{tag}] scoring", flush=True)
    metrics_path = workspace / "results" / f"{tag}.metrics.json"
    score_start = time.monotonic()
    subprocess.run([
        sys.executable, str(BENCH), "metrics",
        "--manifest", str(manifest),
        "--ground-truth", str(dataset / "images"),
        "--output", str(metrics_path),
    ], check=True)
    score_wall = time.monotonic() - score_start

    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
    first_view = json.loads(request.read_text(encoding="utf-8"))["views"][0]
    training["stages"]["render_heldout_seconds"] = render_wall
    training["stages"]["scoring_seconds"] = score_wall
    record = {
        "scene": arguments.scene,
        "profile": arguments.profile,
        "arm": arguments.arm,
        "replicate": arguments.replicate,
        "started_at": started_at,
        "iteration_override": arguments.iterations,
        "seed": arguments.seed,
        "holdout_every": arguments.holdout_every,
        "memory_budget_bytes": arguments.budget,
        "trainer_argv": command,
        "trainer_sha256": sha256(arguments.trainer),
        "metrics_sha256": sha256(metrics_path),
        "image_source": os.path.basename(os.path.realpath(dataset / "images")),
        "resolution": [first_view["width"], first_view["height"]],
        "training": training,
        "quality": {
            "psnr": metrics["psnr"],
            "ssim": metrics["ssim"],
            "lpips_vgg": metrics["lpips_vgg"],
            "lpips_squeeze": metrics["lpips_squeeze"],
            "trainer_rasterizer_psnr": training["trainer_holdout_psnr"],
            "view_count": metrics["view_count"],
        },
        "rendering": {
            "splat_count": metrics["splat_count"],
            "ply_load_seconds": metrics["ply_load_seconds"],
            "mean_render_seconds": metrics["render_seconds_mean"],
            "peak_metal_allocated_bytes": metrics["peak_metal_allocated_bytes"],
            "provenance": metrics.get("renderer", {}),
        },
    }
    result_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

    if not arguments.keep_renders:
        shutil.rmtree(renders, ignore_errors=True)
    print(f"[{tag}] done: psnr {metrics['psnr']:.2f} ssim {metrics['ssim']:.4f} "
          f"lpips {metrics['lpips_vgg']:.4f} "
          f"train {training['stages']['training_seconds']:.0f}s "
          f"peak {training['peak_resident_bytes'] / 1e9:.1f} GB", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
