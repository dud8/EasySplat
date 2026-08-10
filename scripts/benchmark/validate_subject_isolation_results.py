#!/usr/bin/env python3
"""Validate the manually collected subject-isolation release results."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any, NamedTuple


MINIMUM_CAPTURE_COUNT = 15
MAXIMUM_REFERENCE_GAUSSIAN_COUNT = 500_000
MINIMUM_MEAN_HELD_OUT_IOU = 0.80
MINIMUM_P10_HELD_OUT_IOU = 0.65
MINIMUM_MEAN_BOUNDARY_F1 = 0.75
MAXIMUM_P50_SECONDS = 15.0
MAXIMUM_P95_SECONDS = 30.0
MAXIMUM_INCREMENTAL_UNIFIED_MEMORY_BYTES = 8 * 1024**3

ACCEPTED_OUTCOMES = frozenset({"automatic_correct", "user_selected"})
ALLOWED_OUTCOMES = ACCEPTED_OUTCOMES | frozenset(
    {"asked", "refused", "wrong_automatic"}
)
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")


class ResultFormatError(ValueError):
    """The results file is malformed and cannot support a release decision."""


class GateFailure(ValueError):
    """The results are valid, but a release threshold was not met."""


class GateSummary(NamedTuple):
    capture_count: int
    accepted_count: int
    mean_held_out_iou: float
    p10_held_out_iou: float
    mean_boundary_f1: float
    p50_seconds: float | None
    p95_seconds: float | None
    max_incremental_unified_memory_bytes: int | None


def _require_exact_keys(
    value: dict[str, Any],
    *,
    required: set[str],
    optional: set[str] = frozenset(),
    context: str,
) -> None:
    keys = set(value)
    missing = required - keys
    unexpected = keys - required - optional
    if missing:
        raise ResultFormatError(
            f"{context} is missing: {', '.join(sorted(missing))}"
        )
    if unexpected:
        raise ResultFormatError(
            f"{context} has unexpected fields: {', '.join(sorted(unexpected))}"
        )


def _require_dict(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ResultFormatError(f"{field} must be an object")
    return value


def _require_integer(value: Any, field: str, *, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ResultFormatError(f"{field} must be an integer >= {minimum}")
    return value


def _require_number(
    value: Any,
    field: str,
    *,
    minimum: float,
    maximum: float | None = None,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ResultFormatError(f"{field} must be a number")
    number = float(value)
    if not math.isfinite(number):
        raise ResultFormatError(f"{field} must be finite")
    if number < minimum or (maximum is not None and number > maximum):
        range_description = (
            f"between {minimum} and {maximum}"
            if maximum is not None
            else f">= {minimum}"
        )
        raise ResultFormatError(f"{field} must be {range_description}")
    return number


def _require_identity(value: Any, field: str) -> tuple[str, int]:
    identity = _require_dict(value, field)
    _require_exact_keys(
        identity,
        required={"sha256", "byte_count"},
        context=field,
    )
    digest = identity["sha256"]
    if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
        raise ResultFormatError(
            f"{field}.sha256 must use sha256: followed by 64 lowercase hex digits"
        )
    byte_count = _require_integer(
        identity["byte_count"], f"{field}.byte_count", minimum=1
    )
    return digest, byte_count


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def validate_results(value: Any) -> GateSummary:
    root = _require_dict(value, "results")
    _require_exact_keys(
        root,
        required={
            "schema_version",
            "hardware",
            "timings_exclude_first_toolchain_installation",
            "captures",
        },
        context="results",
    )
    schema_version = _require_integer(
        root["schema_version"], "schema_version", minimum=1
    )
    if schema_version != 1:
        raise ResultFormatError("schema_version must be 1")
    hardware = _require_dict(root["hardware"], "hardware")
    _require_exact_keys(
        hardware,
        required={"chip", "memory_bytes"},
        context="hardware",
    )
    if hardware["chip"] != "Apple M4 Max":
        raise ResultFormatError("hardware.chip must be Apple M4 Max")
    memory_bytes = _require_integer(
        hardware["memory_bytes"], "hardware.memory_bytes", minimum=1
    )
    if memory_bytes != 48 * 1024**3:
        raise ResultFormatError("hardware.memory_bytes must describe 48 GiB")
    if root["timings_exclude_first_toolchain_installation"] is not True:
        raise ResultFormatError(
            "timings must exclude the first toolchain installation"
        )
    captures = root["captures"]
    if not isinstance(captures, list):
        raise ResultFormatError("captures must be an array")
    if len(captures) < MINIMUM_CAPTURE_COUNT:
        raise GateFailure(
            f"subject isolation requires at least 15 captures; found {len(captures)}"
        )

    accepted_ious: list[float] = []
    accepted_boundary_scores: list[float] = []
    reference_times: list[float] = []
    reference_memory: list[int] = []
    capture_ids: set[str] = set()
    wrong_automatic_ids: list[str] = []

    required_capture_keys = {
        "capture_id",
        "outcome",
        "source_gaussian_count",
        "isolation_seconds",
        "incremental_unified_memory_bytes",
        "canonical_ply_before",
        "canonical_ply_after",
    }
    optional_capture_keys = {"held_out_iou", "boundary_f1"}

    for index, untyped_capture in enumerate(captures):
        context = f"captures[{index}]"
        capture = _require_dict(untyped_capture, context)
        _require_exact_keys(
            capture,
            required=required_capture_keys,
            optional=optional_capture_keys,
            context=context,
        )
        capture_id = capture["capture_id"]
        if not isinstance(capture_id, str) or not capture_id.strip():
            raise ResultFormatError(f"{context}.capture_id must be a nonempty string")
        if capture_id in capture_ids:
            raise ResultFormatError(f"duplicate capture_id: {capture_id}")
        capture_ids.add(capture_id)

        outcome = capture["outcome"]
        if not isinstance(outcome, str) or outcome not in ALLOWED_OUTCOMES:
            raise ResultFormatError(
                f"{context}.outcome must be one of: "
                + ", ".join(sorted(ALLOWED_OUTCOMES))
            )

        gaussian_count = _require_integer(
            capture["source_gaussian_count"],
            f"{context}.source_gaussian_count",
            minimum=1,
        )
        elapsed = _require_number(
            capture["isolation_seconds"],
            f"{context}.isolation_seconds",
            minimum=0.0,
        )
        memory_bytes = _require_integer(
            capture["incremental_unified_memory_bytes"],
            f"{context}.incremental_unified_memory_bytes",
            minimum=0,
        )
        identity_before = _require_identity(
            capture["canonical_ply_before"], f"{context}.canonical_ply_before"
        )
        identity_after = _require_identity(
            capture["canonical_ply_after"], f"{context}.canonical_ply_after"
        )
        if identity_before != identity_after:
            raise GateFailure(f"{capture_id}: canonical PLY changed during isolation")

        if "held_out_iou" in capture:
            held_out_iou = _require_number(
                capture["held_out_iou"],
                f"{context}.held_out_iou",
                minimum=0.0,
                maximum=1.0,
            )
        else:
            held_out_iou = None
        if "boundary_f1" in capture:
            boundary_f1 = _require_number(
                capture["boundary_f1"],
                f"{context}.boundary_f1",
                minimum=0.0,
                maximum=1.0,
            )
        else:
            boundary_f1 = None

        if outcome in ACCEPTED_OUTCOMES:
            if held_out_iou is None or boundary_f1 is None:
                raise ResultFormatError(
                    f"{context} accepted output requires held_out_iou and boundary_f1"
                )
            accepted_ious.append(held_out_iou)
            accepted_boundary_scores.append(boundary_f1)
        elif outcome == "wrong_automatic":
            wrong_automatic_ids.append(capture_id)

        if gaussian_count <= MAXIMUM_REFERENCE_GAUSSIAN_COUNT:
            reference_times.append(elapsed)
            reference_memory.append(memory_bytes)

    if wrong_automatic_ids:
        raise GateFailure(
            "wrong automatic selection recorded for: "
            + ", ".join(wrong_automatic_ids)
        )
    if not accepted_ious:
        raise GateFailure("subject isolation requires at least one accepted output")
    if not reference_times:
        raise GateFailure(
            "subject isolation requires at least one performance capture "
            "with no more than 500,000 Gaussians"
        )

    mean_iou = sum(accepted_ious) / len(accepted_ious)
    p10_iou = _percentile(accepted_ious, 0.10)
    mean_boundary_f1 = sum(accepted_boundary_scores) / len(
        accepted_boundary_scores
    )
    if mean_iou < MINIMUM_MEAN_HELD_OUT_IOU:
        raise GateFailure(
            f"mean held-out IoU {mean_iou:.3f} is below "
            f"{MINIMUM_MEAN_HELD_OUT_IOU:.2f}"
        )
    if p10_iou < MINIMUM_P10_HELD_OUT_IOU:
        raise GateFailure(
            f"10th-percentile held-out IoU {p10_iou:.3f} is below "
            f"{MINIMUM_P10_HELD_OUT_IOU:.2f}"
        )
    if mean_boundary_f1 < MINIMUM_MEAN_BOUNDARY_F1:
        raise GateFailure(
            f"mean boundary F1 {mean_boundary_f1:.3f} is below "
            f"{MINIMUM_MEAN_BOUNDARY_F1:.2f}"
        )

    p50_seconds = None
    p95_seconds = None
    maximum_memory = None
    p50_seconds = _percentile(reference_times, 0.50)
    p95_seconds = _percentile(reference_times, 0.95)
    maximum_memory = max(reference_memory)
    if p50_seconds > MAXIMUM_P50_SECONDS:
        raise GateFailure(
            f"p50 isolation time {p50_seconds:.3f}s exceeds "
            f"{MAXIMUM_P50_SECONDS:.0f}s"
        )
    if p95_seconds > MAXIMUM_P95_SECONDS:
        raise GateFailure(
            f"p95 isolation time {p95_seconds:.3f}s exceeds "
            f"{MAXIMUM_P95_SECONDS:.0f}s"
        )
    if maximum_memory > MAXIMUM_INCREMENTAL_UNIFIED_MEMORY_BYTES:
        raise GateFailure(
            "incremental unified memory "
            f"{maximum_memory} bytes exceeds "
            f"{MAXIMUM_INCREMENTAL_UNIFIED_MEMORY_BYTES} bytes"
        )

    return GateSummary(
        capture_count=len(captures),
        accepted_count=len(accepted_ious),
        mean_held_out_iou=mean_iou,
        p10_held_out_iou=p10_iou,
        mean_boundary_f1=mean_boundary_f1,
        p50_seconds=p50_seconds,
        p95_seconds=p95_seconds,
        max_incremental_unified_memory_bytes=maximum_memory,
    )


def _reject_nonfinite_constant(value: str) -> None:
    raise ResultFormatError(f"JSON contains non-finite number: {value}")


def load_results(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, parse_constant=_reject_nonfinite_constant)
    except OSError as error:
        raise ResultFormatError(f"cannot read results: {error}") from error
    except json.JSONDecodeError as error:
        raise ResultFormatError(f"invalid JSON: {error}") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate automatic subject-isolation release results."
    )
    parser.add_argument("results", type=Path, help="JSON results file")
    arguments = parser.parse_args(argv)
    try:
        summary = validate_results(load_results(arguments.results))
    except (ResultFormatError, GateFailure) as error:
        print(f"Subject isolation release gate failed: {error}", file=sys.stderr)
        return 1

    performance = ""
    if summary.p50_seconds is not None and summary.p95_seconds is not None:
        performance = (
            f", p50 {summary.p50_seconds:.2f}s, "
            f"p95 {summary.p95_seconds:.2f}s"
        )
    print(
        "Subject isolation release gates passed: "
        f"{summary.capture_count} captures, "
        f"{summary.accepted_count} accepted, "
        f"mean IoU {summary.mean_held_out_iou:.3f}, "
        f"p10 IoU {summary.p10_held_out_iou:.3f}, "
        f"mean boundary F1 {summary.mean_boundary_f1:.3f}"
        f"{performance}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
