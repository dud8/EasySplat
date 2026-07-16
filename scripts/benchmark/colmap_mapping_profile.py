#!/usr/bin/env python3
"""Profile solver activity in a complete COLMAP incremental-mapper log."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
ROUNDING_TOLERANCE_SECONDS = 0.001

POSE_REFINEMENT = "pose_refinement"
LOCAL_BUNDLE_ADJUSTMENT = "local_bundle_adjustment"
GLOBAL_BUNDLE_ADJUSTMENT = "global_bundle_adjustment"
REPORT_KINDS = (
    POSE_REFINEMENT,
    LOCAL_BUNDLE_ADJUSTMENT,
    GLOBAL_BUNDLE_ADJUSTMENT,
)

INITIAL_GLOBAL_MARKER = "Global bundle adjustment"
ITERATIVE_GLOBAL_MARKER = "Retriangulation and Global bundle adjustment"
POSE_REPORT_MARKER = "Pose refinement report"
BUNDLE_REPORT_MARKER = "Bundle adjustment report"

_TIMESTAMP_RE = re.compile(
    r"^[IWEF](?P<date>\d{8}) "
    r"(?P<time>\d{2}:\d{2}:\d{2}\.\d{1,6}) "
    r"\S+ [^]]+\] ?(?P<message>.*)$"
)
_TIMESTAMP_LIKE_RE = re.compile(r"^[IWEF]\d{8}\s")
_INTEGER_RE = re.compile(r"[+-]?\d+")
_TERMINATION_RE = re.compile(r"[A-Za-z][A-Za-z -]*")
_ELAPSED_MARKER_RE = re.compile(
    r"^Elapsed time: (?:0|[1-9]\d*)(?:\.\d+)? \[minutes\]$"
)
_FIELD_PATTERNS = {
    "residuals": re.compile(r"^\s*Residuals\s*:\s*(\S+)\s*$"),
    "parameters": re.compile(r"^\s*Parameters\s*:\s*(\S+)\s*$"),
    "iterations": re.compile(r"^\s*Iterations\s*:\s*(\S+)\s*$"),
    "solver_seconds": re.compile(r"^\s*Time\s*:\s*(\S+)\s*\[s\]\s*$"),
    "initial_cost": re.compile(r"^\s*Initial cost\s*:\s*(\S+)\s*\[px\]\s*$"),
    "final_cost": re.compile(r"^\s*Final cost\s*:\s*(\S+)\s*\[px\]\s*$"),
    "termination": re.compile(r"^\s*Termination\s*:\s*(.*?)\s*$"),
}
_REQUIRED_REPORT_FIELDS = frozenset(_FIELD_PATTERNS)


class ProfileError(ValueError):
    """The mapper log cannot produce a trustworthy aggregate profile."""


def _scan_timestamps(
    lines: list[str],
) -> tuple[dict[int, tuple[datetime, str]], datetime, datetime, int]:
    events: dict[int, tuple[datetime, str]] = {}
    first_timestamp: datetime | None = None
    previous_timestamp: datetime | None = None
    final_elapsed_line: int | None = None

    for line_number, line in enumerate(lines, start=1):
        match = _TIMESTAMP_RE.fullmatch(line)
        if match is None:
            if _TIMESTAMP_LIKE_RE.match(line):
                raise ProfileError(f"invalid log timestamp at line {line_number}")
            continue
        try:
            timestamp = datetime.strptime(
                match.group("date") + match.group("time"),
                "%Y%m%d%H:%M:%S.%f",
            )
        except ValueError as error:
            raise ProfileError(
                f"invalid log timestamp at line {line_number}"
            ) from error
        if previous_timestamp is not None and timestamp < previous_timestamp:
            raise ProfileError(f"backwards log timestamp at line {line_number}")

        message = match.group("message").strip()
        events[line_number] = (timestamp, message)
        first_timestamp = first_timestamp or timestamp
        previous_timestamp = timestamp
        if message.startswith("Elapsed time:"):
            if _ELAPSED_MARKER_RE.fullmatch(message) is None:
                raise ProfileError(
                    f"invalid mapper elapsed marker at line {line_number}"
                )
            final_elapsed_line = line_number

    if first_timestamp is None or previous_timestamp is None:
        raise ProfileError("log contains no timestamps")
    if final_elapsed_line is None:
        raise ProfileError("log is missing the final mapper elapsed marker")
    if final_elapsed_line != max(events):
        raise ProfileError("final mapper elapsed marker is not the last timestamp")
    if previous_timestamp <= first_timestamp:
        raise ProfileError("observed mapper span must be positive")
    return events, first_timestamp, previous_timestamp, final_elapsed_line


def _parse_nonnegative_integer(token: str, line_number: int) -> int:
    if _INTEGER_RE.fullmatch(token) is None:
        raise ProfileError(f"invalid integer report field at line {line_number}")
    value = int(token)
    if value < 0:
        raise ProfileError(f"negative report field at line {line_number}")
    return value


def _parse_nonnegative_float(token: str, line_number: int) -> float:
    try:
        value = float(token)
    except ValueError as error:
        raise ProfileError(f"invalid numeric report field at line {line_number}") from error
    if not math.isfinite(value):
        raise ProfileError(f"nonfinite report field at line {line_number}")
    if value < 0:
        raise ProfileError(f"negative report field at line {line_number}")
    return value


def _parse_report_field(line: str, line_number: int) -> tuple[str, int | float | str]:
    for field, pattern in _FIELD_PATTERNS.items():
        match = pattern.fullmatch(line)
        if match is None:
            continue
        token = match.group(1)
        if field in {"residuals", "parameters", "iterations"}:
            return field, _parse_nonnegative_integer(token, line_number)
        if field == "termination":
            if _TERMINATION_RE.fullmatch(token) is None:
                raise ProfileError(f"invalid termination field at line {line_number}")
            return field, token
        return field, _parse_nonnegative_float(token, line_number)
    raise ProfileError(f"invalid report field at line {line_number}")


def _empty_report_totals() -> dict[str, dict[str, int | float]]:
    return {
        kind: {
            "calls": 0,
            "iterations": 0,
            "parameters": 0,
            "residuals": 0,
            "solver_seconds": 0.0,
        }
        for kind in REPORT_KINDS
    }


def _record_report(
    report: dict[str, Any],
    totals: dict[str, dict[str, int | float]],
    line_number: int,
) -> None:
    fields = report["fields"]
    if set(fields) != _REQUIRED_REPORT_FIELDS:
        raise ProfileError(f"incomplete report ending at line {line_number}")
    bucket = totals[report["kind"]]
    bucket["calls"] += 1
    bucket["iterations"] += fields["iterations"]
    bucket["parameters"] += fields["parameters"]
    bucket["residuals"] += fields["residuals"]
    bucket["solver_seconds"] += fields["solver_seconds"]


def _share(numerator: float, denominator: float, label: str) -> float:
    ratio = numerator / denominator
    if 0.0 <= ratio <= 1.0:
        return ratio
    if numerator <= denominator + ROUNDING_TOLERANCE_SECONDS:
        return 1.0
    raise ProfileError(f"impossible {label} share")


def _validated_wall_seconds(
    wall_seconds: float | None,
    observed_span_seconds: float,
) -> float:
    if wall_seconds is None:
        return observed_span_seconds
    if (
        isinstance(wall_seconds, bool)
        or not isinstance(wall_seconds, (int, float))
        or not math.isfinite(wall_seconds)
        or wall_seconds <= 0
    ):
        raise ProfileError("wall time must be finite and positive")
    value = float(wall_seconds)
    if value + ROUNDING_TOLERANCE_SECONDS < observed_span_seconds:
        raise ProfileError("wall time is shorter than the observed mapper span")
    return value


def parse_mapping_profile(
    log_text: str,
    wall_seconds: float | None = None,
) -> dict[str, Any]:
    """Parse a complete mapper log into privacy-safe aggregate measurements."""

    if not isinstance(log_text, str) or not log_text.strip():
        raise ProfileError("mapper log is empty")
    lines = log_text.splitlines()
    events, first_timestamp, last_timestamp, final_elapsed_line = _scan_timestamps(
        lines
    )

    totals = _empty_report_totals()
    marker_counts = {
        "initial_global_markers": 0,
        "iterative_global_refinement_markers": 0,
        "registration_attempts": 0,
    }
    bundle_mode: str | None = None
    active_report: dict[str, Any] | None = None
    global_region_start: datetime | None = None
    global_region_seconds = 0.0
    saw_reconstruction_end = False

    for line_number, line in enumerate(lines, start=1):
        event = events.get(line_number)
        if event is not None:
            timestamp, message = event
            if active_report is not None:
                if message in {POSE_REPORT_MARKER, BUNDLE_REPORT_MARKER}:
                    raise ProfileError(
                        f"nested or duplicate report start at line {line_number}"
                    )
                raise ProfileError(f"incomplete report before line {line_number}")

            if message in {INITIAL_GLOBAL_MARKER, ITERATIVE_GLOBAL_MARKER}:
                if global_region_start is None:
                    global_region_start = timestamp
                bundle_mode = GLOBAL_BUNDLE_ADJUSTMENT
                if message == INITIAL_GLOBAL_MARKER:
                    marker_counts["initial_global_markers"] += 1
                else:
                    marker_counts["iterative_global_refinement_markers"] += 1
                continue

            if message.startswith("Registering image "):
                marker_counts["registration_attempts"] += 1
                if global_region_start is not None:
                    global_region_seconds += (
                        timestamp - global_region_start
                    ).total_seconds()
                    global_region_start = None
                bundle_mode = LOCAL_BUNDLE_ADJUSTMENT
                continue

            is_reconstruction_end = message.startswith(
                "Keeping successful reconstruction"
            ) or message.startswith("Discarding reconstruction")
            if is_reconstruction_end or line_number == final_elapsed_line:
                saw_reconstruction_end = saw_reconstruction_end or is_reconstruction_end
                if global_region_start is not None:
                    global_region_seconds += (
                        timestamp - global_region_start
                    ).total_seconds()
                    global_region_start = None
                bundle_mode = None
                continue

            if message == POSE_REPORT_MARKER:
                active_report = {"kind": POSE_REFINEMENT, "fields": {}}
                continue

            if message == BUNDLE_REPORT_MARKER:
                if bundle_mode is None:
                    raise ProfileError(
                        f"bundle report has unknown classification at line {line_number}"
                    )
                active_report = {"kind": bundle_mode, "fields": {}}
                continue

            continue

        if active_report is None:
            if line.strip() in {POSE_REPORT_MARKER, BUNDLE_REPORT_MARKER} or any(
                pattern.fullmatch(line) for pattern in _FIELD_PATTERNS.values()
            ):
                raise ProfileError(f"report content outside a report at line {line_number}")
            continue

        if not line.strip():
            continue
        field, value = _parse_report_field(line, line_number)
        fields = active_report["fields"]
        if field in fields:
            raise ProfileError(f"duplicate report field at line {line_number}")
        fields[field] = value
        if field == "termination":
            _record_report(active_report, totals, line_number)
            active_report = None

    if active_report is not None:
        raise ProfileError("mapper log ends inside a report")
    if global_region_start is not None:
        raise ProfileError("mapper log ends inside a global region")
    if not saw_reconstruction_end:
        raise ProfileError("log is missing a reconstruction completion marker")

    expected_global_reports = (
        marker_counts["initial_global_markers"]
        + marker_counts["iterative_global_refinement_markers"]
    )
    actual_global_reports = int(totals[GLOBAL_BUNDLE_ADJUSTMENT]["calls"])
    if actual_global_reports != expected_global_reports:
        raise ProfileError("global refinement markers and reports do not match")

    observed_span_seconds = (last_timestamp - first_timestamp).total_seconds()
    mapper_wall_seconds = _validated_wall_seconds(
        wall_seconds,
        observed_span_seconds,
    )
    pose_solver_seconds = float(totals[POSE_REFINEMENT]["solver_seconds"])
    local_solver_seconds = float(totals[LOCAL_BUNDLE_ADJUSTMENT]["solver_seconds"])
    global_solver_seconds = float(totals[GLOBAL_BUNDLE_ADJUSTMENT]["solver_seconds"])
    bundle_solver_seconds = local_solver_seconds + global_solver_seconds
    all_solver_seconds = pose_solver_seconds + bundle_solver_seconds

    if all_solver_seconds > (
        mapper_wall_seconds + ROUNDING_TOLERANCE_SECONDS
    ):
        raise ProfileError("reported solver time exceeds mapper wall time")
    if global_solver_seconds > (
        global_region_seconds + ROUNDING_TOLERANCE_SECONDS
    ):
        raise ProfileError("global solver time exceeds global refinement regions")

    bundle_solver_share = _share(
        bundle_solver_seconds,
        mapper_wall_seconds,
        "bundle-adjustment solver",
    )
    global_region_share = _share(
        global_region_seconds,
        mapper_wall_seconds,
        "global-region",
    )
    non_bundle_share = 1.0 - bundle_solver_share
    amdahl = {
        f"solver_replacement_{factor}x_speedup": 1.0
        / (non_bundle_share + bundle_solver_share / factor)
        for factor in (2, 5, 10)
    }
    amdahl["infinite_solver_ceiling_speedup"] = (
        "unbounded" if bundle_solver_share == 1.0 else 1.0 / non_bundle_share
    )

    return {
        "amdahl": amdahl,
        "marker_counts": marker_counts,
        "report_totals": totals,
        "schema_version": SCHEMA_VERSION,
        "timing": {
            "bundle_adjustment_solver_seconds": bundle_solver_seconds,
            "bundle_adjustment_solver_share": bundle_solver_share,
            "global_refinement_region_seconds": global_region_seconds,
            "global_refinement_region_share": global_region_share,
            "mapper_wall_seconds": mapper_wall_seconds,
            "observed_mapper_span_seconds": observed_span_seconds,
        },
    }


def serialize_profile(profile: dict[str, Any]) -> str:
    """Serialize a profile deterministically with exactly one trailing newline."""

    return (
        json.dumps(
            profile,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Profile solver activity in a COLMAP incremental-mapper log."
    )
    parser.add_argument("--log", required=True)
    parser.add_argument("--wall-seconds", type=float)
    parser.add_argument("--output")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        log_text = Path(args.log).read_text(encoding="utf-8")
        serialized = serialize_profile(
            parse_mapping_profile(log_text, wall_seconds=args.wall_seconds)
        )
        if args.output is None:
            sys.stdout.write(serialized)
        else:
            Path(args.output).write_text(serialized, encoding="utf-8")
    except ProfileError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except (OSError, UnicodeError):
        print("error: unable to read or write the requested file", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
