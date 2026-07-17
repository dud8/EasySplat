#!/usr/bin/env python3
"""Run one protected benchmark lane and collect its raw evidence."""

from __future__ import annotations

import argparse
import bisect
import ctypes
import json
import math
import os
import resource
import select
import secrets
import signal
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Mapping, MutableMapping, NoReturn, Sequence

try:
    from scripts.benchmark import easysplat_benchmark as benchmark
    from scripts.benchmark import evidence_protocol as evidence
    from scripts.benchmark import renderer_closure
except ModuleNotFoundError:
    import easysplat_benchmark as benchmark
    import evidence_protocol as evidence
    import renderer_closure


_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY = "EASYSPLAT_INTERNAL_BENCHMARK_TIMEOUT_SECONDS"
_MINIMUM_TIMEOUT_OVERRIDE_SECONDS = 0.1
_MAXIMUM_TIMEOUT_OVERRIDE_SECONDS = 24 * 60 * 60
_PROCESS_GROUP_TERMINATION_GRACE_SECONDS = 5.0
_PROCESS_GROUP_DRAIN_SECONDS = 0.25
_PROCESS_TREE_SCAN_SECONDS = 0.01
_PROCESS_TOKEN_ENVIRONMENT_KEY = "EASYSPLAT_INTERNAL_BENCHMARK_PROCESS_TOKEN"
_ORIENTATION_EXTRACTION_TIMEOUT_SECONDS = 60.0
_HOST_MONITOR_MAXIMUM_SAMPLES = 100_000
_HOST_MONITOR_MAXIMUM_INTERVAL_SECONDS = 1.0
_HOST_MONITOR_TIMESTAMP_TOLERANCE_SECONDS = 0.05
_HOST_MONITOR_READY_TIMEOUT_SECONDS = 10.0
_HOST_MONITOR_STOP_TIMEOUT_SECONDS = 30.0
_HOST_MONITOR_MAXIMUM_OUTPUT_BYTES = 64 * 1024 * 1024
_HOST_MONITOR_EVENT_SAMPLE_HEADROOM = 4_096
_COLLECTOR_VERSION = "1.0.0"
_COLLECTOR_RELATIVE_PATH = "scripts/benchmark/run_lane.py"


class _PostprocessingFailure(benchmark.ConfigError):
    """A pinned supervisor-side evidence tool failed after runner preflight."""


class _IntegrityFailure(benchmark.ConfigError):
    """A protected input or executable changed during evidence collection."""


class _CollectedOutcome(benchmark.ConfigError):
    """A terminal lane outcome was durably collected for later preparation."""

    def __init__(
        self,
        message: str,
        *,
        scene_id: str,
        scale: int,
        lane: str,
        status_path: Path,
        request: Mapping[str, Any],
        runner_identity: Mapping[str, Any],
        machine: Mapping[str, Any],
    ) -> None:
        super().__init__(message)
        self.scene_id = scene_id
        self.scale = scale
        self.lane = lane
        self.status_path = status_path
        self.request = dict(request)
        self.runner_identity = dict(runner_identity)
        self.machine = dict(machine)


def _load(path: Path, label: str) -> Any:
    return benchmark._load_json(path, label)


def _relative(value: Any, label: str) -> Path:
    raw = benchmark._safe_relative_path(value, label)
    return Path(*PurePosixPath(raw).parts)


def _require_runner(path: Path) -> Path:
    if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
        raise benchmark.ConfigError("measurement runner must be a regular executable")
    return path.resolve()


def _verify_runner_digest(path: Path, expected: Mapping[str, str], phase: str) -> None:
    actual = evidence.sha256_file(path)
    if actual != expected["sha256"]:
        raise benchmark.ConfigError(
            f"{expected['label']} digest mismatch {phase}; refusing protected measurement"
        )


def _verify_renderer_closure(
    path: Path,
    expected: Mapping[str, Any],
    phase: str,
) -> renderer_closure.VerifiedClosure:
    try:
        return renderer_closure.verify_closure(path, expected)
    except renderer_closure.ClosureError as error:
        raise benchmark.ConfigError(
            f"rendering driver closure mismatch {phase}; refusing protected measurement: {error}"
        ) from error


def _canonical_real_directory(path: Path, label: str) -> Path:
    absolute = Path(os.path.abspath(path))
    try:
        metadata = absolute.lstat()
        resolved = absolute.resolve(strict=True)
    except OSError as error:
        raise benchmark.ConfigError(f"{label} is missing") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise benchmark.ConfigError(f"{label} must be a real directory")
    if absolute != resolved:
        raise benchmark.ConfigError(f"{label} path contains a symbolic link")
    return resolved


def _verify_baseline_checkout(path: Path, expected_commit: str) -> Path:
    resolved = _canonical_real_directory(path, "baseline checkout")

    def git(*arguments: str) -> str:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(resolved), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if completed.returncode != 0:
            raise benchmark.ConfigError("baseline checkout is not a readable Git worktree")
        return completed.stdout.strip()

    top_level = Path(git("rev-parse", "--show-toplevel")).resolve()
    if top_level != resolved:
        raise benchmark.ConfigError("baseline checkout must point to its worktree root")
    if git("rev-parse", "HEAD") != expected_commit:
        raise benchmark.ConfigError("baseline checkout is not the approved commit")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise benchmark.ConfigError("baseline checkout must be clean")
    return resolved


def _verify_baseline_toolchain(path: Path, expected_identity: str) -> tuple[Path, str]:
    if path.is_symlink() or not path.is_dir():
        raise benchmark.ConfigError("baseline toolchain must be a real directory")
    resolved = path.resolve()
    identity = benchmark.resolved_toolchain_identity(resolved, "release")
    if identity != expected_identity:
        raise benchmark.ConfigError("baseline toolchain does not match the approved closure")
    return resolved, identity


def _verify_candidate_checkout(expected_commit: str) -> Path:
    resolved = _canonical_real_directory(benchmark.ROOT, "candidate checkout")
    state = benchmark.collect_git_state()
    if state["dirty"] or state["commit"] != expected_commit:
        raise benchmark.ConfigError("candidate checkout changed during lane measurement")
    return resolved


def _verify_file_digest(path: Path, expected_digest: str, label: str) -> None:
    if evidence.sha256_file(path) != expected_digest:
        raise benchmark.ConfigError(f"{label} changed during lane measurement")


def _prepare_artifact_root(output_root: Path, relative: Path, scale: int, lane: str) -> Path:
    if output_root.exists() and (output_root.is_symlink() or not output_root.is_dir()):
        raise benchmark.ConfigError("benchmark output root must be a real directory")
    output_root.mkdir(parents=True, exist_ok=True)
    canonical_output = output_root.resolve(strict=True)
    artifact_root = output_root / relative / str(scale) / lane
    cursor = output_root
    for part in artifact_root.relative_to(output_root).parts:
        cursor /= part
        if cursor.is_symlink():
            raise benchmark.ConfigError("benchmark artifact path contains a symlink")
    parent = artifact_root.parent
    parent.mkdir(parents=True, exist_ok=True)
    resolved_parent = parent.resolve(strict=True)
    if resolved_parent != canonical_output and canonical_output not in resolved_parent.parents:
        raise benchmark.ConfigError("benchmark artifact path escapes the output root")
    if artifact_root.exists() or artifact_root.is_symlink():
        raise benchmark.ConfigError("benchmark artifact root already exists; refusing untrusted output")
    artifact_root.mkdir()
    return artifact_root


def _isolated_environment(artifact_root: Path, namespace: str) -> dict[str, str]:
    home = artifact_root / f"{namespace}-home"
    temporary = artifact_root / f"{namespace}-tmp"
    cache = artifact_root / f"{namespace}-cache"
    for directory in (home, temporary, cache):
        directory.mkdir()
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "XDG_CACHE_HOME": str(cache),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    }


def _measurement_environment(artifact_root: Path) -> dict[str, str]:
    return _isolated_environment(artifact_root, "runner")


def _children_cpu_seconds() -> dict[str, float]:
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {"user": float(usage.ru_utime), "system": float(usage.ru_stime)}


@dataclass
class _HostMonitorProcess:
    process: subprocess.Popen[bytes]
    stop_file_descriptor: int
    ready_bracket_started: float
    ready_bracket_ended: float


def _start_host_monitor(
    executable: Path,
    environment: Mapping[str, str],
    timeout_seconds: float,
) -> _HostMonitorProcess:
    ready_read, ready_write = os.pipe()
    stop_read, stop_write = os.pipe()
    process: subprocess.Popen[bytes] | None = None
    started_ok = False
    ready_started = time.monotonic()
    maximum_samples = min(
        _HOST_MONITOR_MAXIMUM_SAMPLES,
        max(
            2,
            math.ceil(timeout_seconds / _HOST_MONITOR_MAXIMUM_INTERVAL_SECONDS)
            + _HOST_MONITOR_EVENT_SAMPLE_HEADROOM,
        ),
    )
    try:
        process = subprocess.Popen(
            [
                str(executable),
                "monitor-host-state",
                "--sample-interval",
                str(_HOST_MONITOR_MAXIMUM_INTERVAL_SECONDS),
                "--max-samples",
                str(maximum_samples),
                "--ready-fd",
                str(ready_write),
                "--stop-fd",
                str(stop_read),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(environment),
            pass_fds=(ready_write, stop_read),
        )
        os.close(ready_write)
        ready_write = -1
        os.close(stop_read)
        stop_read = -1
        readable, _, _ = select.select(
            [ready_read],
            [],
            [],
            _HOST_MONITOR_READY_TIMEOUT_SECONDS,
        )
        if not readable or os.read(ready_read, 1) != b"\x01":
            raise benchmark.ConfigError("host monitor did not become ready")
        ready_ended = time.monotonic()
        if process.poll() is not None:
            raise benchmark.ConfigError("host monitor exited during startup")
        monitor = _HostMonitorProcess(
            process=process,
            stop_file_descriptor=stop_write,
            ready_bracket_started=ready_started,
            ready_bracket_ended=ready_ended,
        )
        started_ok = True
        return monitor
    except (OSError, subprocess.SubprocessError) as error:
        raise benchmark.ConfigError("host monitor could not start") from error
    finally:
        os.close(ready_read)
        if ready_write >= 0:
            os.close(ready_write)
        if stop_read >= 0:
            os.close(stop_read)
        if process is not None and process.poll() is None and not started_ok:
            process.kill()
            process.wait()
        if not started_ok:
            os.close(stop_write)


def _finish_host_monitor(monitor: _HostMonitorProcess) -> dict[str, Any]:
    try:
        os.close(monitor.stop_file_descriptor)
    except OSError as error:
        monitor.process.kill()
        monitor.process.wait()
        raise benchmark.ConfigError("host monitor stop signal failed") from error
    try:
        stdout, stderr = monitor.process.communicate(
            timeout=_HOST_MONITOR_STOP_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        monitor.process.kill()
        monitor.process.communicate()
        raise benchmark.ConfigError("host monitor did not stop") from error
    if monitor.process.returncode != 0:
        raise benchmark.ConfigError("host monitor failed")
    if stderr:
        raise benchmark.ConfigError("host monitor wrote unexpected diagnostics")
    if not stdout or len(stdout) > _HOST_MONITOR_MAXIMUM_OUTPUT_BYTES:
        raise benchmark.ConfigError("host monitor output is missing or too large")
    try:
        report = evidence._decode_json_text(
            stdout.decode("utf-8"),
            "host monitor output",
        )
    except (UnicodeError, ValueError) as error:
        raise benchmark.ConfigError("host monitor output is not valid JSON") from error
    if not isinstance(report, Mapping):
        raise benchmark.ConfigError("host monitor output must be an object")
    samples = report.get("samples")
    if not isinstance(samples, list) or not samples:
        raise benchmark.ConfigError("host monitor output has no samples")
    initial = samples[0]
    if not isinstance(initial, Mapping):
        raise benchmark.ConfigError("host monitor initial sample is invalid")
    initial_timestamp = initial.get("monotonic_seconds")
    if (
        isinstance(initial_timestamp, bool)
        or not isinstance(initial_timestamp, (int, float))
        or not math.isfinite(initial_timestamp)
        or initial_timestamp < monitor.ready_bracket_started
        - _HOST_MONITOR_TIMESTAMP_TOLERANCE_SECONDS
        or initial_timestamp > monitor.ready_bracket_ended
        + _HOST_MONITOR_TIMESTAMP_TOLERANCE_SECONDS
    ):
        raise benchmark.ConfigError("host monitor ready clock bracket is invalid")
    return dict(report)


def _summarize_host_monitor(
    report: Any,
    commands: Sequence[Mapping[str, Any]],
    machine: Mapping[str, Any],
    *,
    supervisor_started: float,
    supervisor_ended: float,
    monitor_sha256: str,
    monitor_executable_sha256: str,
    outer_child_cpu_microseconds: Mapping[str, int],
) -> dict[str, Any]:
    monitor = evidence._mapping(report, "host monitor")
    evidence._exact_keys(
        monitor,
        {
            "schema_version",
            "monotonic_clock",
            "sample_interval_seconds",
            "samples",
            "events",
        },
        "host monitor",
    )
    if monitor["schema_version"] != 1:
        raise evidence.EvidenceError("host monitor schema is invalid")
    if monitor["monotonic_clock"] != "mach_absolute_time":
        raise evidence.EvidenceError("host monitor clock is not mach_absolute_time")
    interval = monitor["sample_interval_seconds"]
    if (
        isinstance(interval, bool)
        or not isinstance(interval, (int, float))
        or not math.isfinite(interval)
        or not 0.05 <= interval <= _HOST_MONITOR_MAXIMUM_INTERVAL_SECONDS
    ):
        raise evidence.EvidenceError("host monitor sample interval is invalid")
    if (
        isinstance(supervisor_started, bool)
        or isinstance(supervisor_ended, bool)
        or not math.isfinite(supervisor_started)
        or not math.isfinite(supervisor_ended)
        or supervisor_started < 0
        or supervisor_ended <= supervisor_started
    ):
        raise evidence.EvidenceError("host monitor supervisor window is invalid")

    raw_samples = monitor["samples"]
    if (
        not isinstance(raw_samples, list)
        or not 2 <= len(raw_samples) <= _HOST_MONITOR_MAXIMUM_SAMPLES
    ):
        raise evidence.EvidenceError("host monitor sample closure is incomplete")
    samples: list[tuple[float, dict[str, Any]]] = []
    previous_timestamp = -math.inf
    for index, raw_sample in enumerate(raw_samples):
        sample = evidence._mapping(raw_sample, f"host monitor samples[{index}]")
        evidence._exact_keys(
            sample,
            {"monotonic_seconds", "state"},
            f"host monitor samples[{index}]",
        )
        timestamp = sample["monotonic_seconds"]
        if (
            isinstance(timestamp, bool)
            or not isinstance(timestamp, (int, float))
            or not math.isfinite(timestamp)
            or timestamp < 0
            or timestamp <= previous_timestamp
        ):
            raise evidence.EvidenceError("host monitor timestamps are invalid")
        state = evidence._host_state_snapshot(
            sample["state"],
            f"host monitor samples[{index}].state",
        )
        samples.append((float(timestamp), state))
        previous_timestamp = float(timestamp)

    timestamps = [timestamp for timestamp, _ in samples]
    gaps = [right - left for left, right in zip(timestamps, timestamps[1:])]
    maximum_gap = max(gaps)
    if maximum_gap > max(2.5 * float(interval), 0.125) + 1e-9:
        raise evidence.EvidenceError("host monitor sample gap exceeds the allowed interval")
    first_timestamp = timestamps[0]
    last_timestamp = timestamps[-1]
    tolerance = _HOST_MONITOR_TIMESTAMP_TOLERANCE_SECONDS
    if (
        first_timestamp > supervisor_started + tolerance
        or last_timestamp < supervisor_ended - tolerance
        or supervisor_started - first_timestamp > maximum_gap + tolerance
        or last_timestamp - supervisor_ended > maximum_gap + tolerance
    ):
        raise evidence.EvidenceError("host monitor does not bracket the supervisor clock window")

    raw_events = monitor["events"]
    if not isinstance(raw_events, list) or len(raw_events) > len(samples):
        raise evidence.EvidenceError("host monitor event closure is invalid")
    state_change_events = []
    previous_event_key: tuple[float, str] | None = None
    for index, raw_event in enumerate(raw_events):
        event = evidence._mapping(raw_event, f"host monitor events[{index}]")
        evidence._exact_keys(
            event,
            {"monotonic_seconds", "kind"},
            f"host monitor events[{index}]",
        )
        event_timestamp = event["monotonic_seconds"]
        event_kind = event["kind"]
        if (
            isinstance(event_timestamp, bool)
            or not isinstance(event_timestamp, (int, float))
            or not math.isfinite(event_timestamp)
            or event_timestamp < first_timestamp - tolerance
            or event_timestamp > last_timestamp + tolerance
            or not isinstance(event_kind, str)
            or event_kind not in {"thermal_state", "low_power_mode", "power_source"}
        ):
            raise evidence.EvidenceError("host monitor event is invalid")
        event_key = (float(event_timestamp), event_kind)
        if previous_event_key is not None and event_key < previous_event_key:
            raise evidence.EvidenceError("host monitor events are not canonical")
        previous_event_key = event_key
        if supervisor_started <= float(event_timestamp) <= supervisor_ended:
            state_change_events.append(
                {
                    "monotonic_seconds": float(event_timestamp),
                    "kind": event_kind,
                }
            )

    tick_fields = ("user", "system", "idle", "nice")
    cumulative: list[dict[str, float]] = [{field: 0.0 for field in tick_fields}]
    for (_, previous), (_, current) in zip(samples, samples[1:]):
        cumulative.append(
            {
                field: cumulative[-1][field]
                + evidence._wrapped_cpu_tick_delta(
                    previous["cpu_ticks"][field],
                    current["cpu_ticks"][field],
                )
                for field in tick_fields
            }
        )

    def interpolated_ticks(timestamp: float) -> dict[str, float]:
        if timestamp < first_timestamp - tolerance or timestamp > last_timestamp + tolerance:
            raise evidence.EvidenceError("execution receipt falls outside host monitoring")
        if timestamp <= first_timestamp:
            return dict(cumulative[0])
        if timestamp >= last_timestamp:
            return dict(cumulative[-1])
        lower_index = bisect.bisect_right(timestamps, timestamp) - 1
        upper_index = lower_index + 1
        span = timestamps[upper_index] - timestamps[lower_index]
        ratio = (timestamp - timestamps[lower_index]) / span
        return {
            field: cumulative[lower_index][field]
            + ratio * (cumulative[upper_index][field] - cumulative[lower_index][field])
            for field in tick_fields
        }

    logical_cpus = machine.get("logical_cpus")
    if type(logical_cpus) is not int or logical_cpus <= 0:
        raise evidence.EvidenceError("host monitor logical CPU count is unavailable")
    evidence._digest(monitor_sha256, "host monitor sha256")
    evidence._digest(monitor_executable_sha256, "host monitor executable sha256")
    evidence._exact_keys(
        outer_child_cpu_microseconds,
        {"user", "system"},
        "outer child CPU",
    )
    if any(
        type(outer_child_cpu_microseconds[field]) is not int
        or not 0 <= outer_child_cpu_microseconds[field] < 1 << 64
        for field in ("user", "system")
    ):
        raise evidence.EvidenceError("outer child CPU is outside UInt64")

    command_environment = []
    process_cpu_total = 0
    for index, command in enumerate(commands):
        run_id = command.get("run_id")
        if not isinstance(run_id, str) or not run_id:
            raise evidence.EvidenceError(f"commands[{index}] run_id is invalid")
        started = command.get("started_monotonic_seconds")
        ended = command.get("ended_monotonic_seconds")
        if (
            isinstance(started, bool)
            or isinstance(ended, bool)
            or not isinstance(started, (int, float))
            or not isinstance(ended, (int, float))
            or not math.isfinite(started)
            or not math.isfinite(ended)
            or ended <= started
        ):
            raise evidence.EvidenceError(f"commands[{index}] monitor timestamps are invalid")
        process_cpu = evidence._mapping(
            command.get("process_cpu_microseconds"),
            f"commands[{index}].process_cpu_microseconds",
        )
        evidence._exact_keys(
            process_cpu,
            {"user", "system"},
            f"commands[{index}].process_cpu_microseconds",
        )
        if any(
            type(process_cpu[field]) is not int
            or not 0 <= process_cpu[field] < 1 << 64
            for field in ("user", "system")
        ):
            raise evidence.EvidenceError("execution receipt process CPU is outside UInt64")
        duration = float(ended) - float(started)
        command_process_cpu = process_cpu["user"] + process_cpu["system"]
        if command_process_cpu > duration * logical_cpus * 1_000_000 * 1.05:
            raise evidence.EvidenceError("execution receipt process CPU exceeds its wall-time bound")
        process_cpu_total += command_process_cpu
        start_ticks = interpolated_ticks(float(started))
        end_ticks = interpolated_ticks(float(ended))
        deltas = {field: end_ticks[field] - start_ticks[field] for field in tick_fields}
        total_ticks = sum(deltas.values())
        if total_ticks <= 0:
            raise evidence.EvidenceError("host monitor CPU ticks did not advance")
        host_busy = (deltas["user"] + deltas["system"] + deltas["nice"]) / total_ticks
        process_fraction = command_process_cpu / (duration * logical_cpus * 1_000_000)
        command_environment.append(
            {
                "run_id": run_id,
                "host_busy_fraction": host_busy,
                "process_cpu_fraction": process_fraction,
                "external_cpu_fraction": max(0.0, host_busy - process_fraction),
            }
        )

    outer_cpu_total = sum(outer_child_cpu_microseconds.values())
    accounting_tolerance = max(100_000, math.ceil(outer_cpu_total * 0.01))
    if process_cpu_total > outer_cpu_total + accounting_tolerance:
        raise evidence.EvidenceError("execution receipt process CPU exceeds outer child CPU")

    supervisor_start_ticks = interpolated_ticks(supervisor_started)
    supervisor_end_ticks = interpolated_ticks(supervisor_ended)
    supervisor_tick_deltas = {
        field: supervisor_end_ticks[field] - supervisor_start_ticks[field]
        for field in tick_fields
    }
    supervisor_total_ticks = sum(supervisor_tick_deltas.values())
    if supervisor_total_ticks <= 0:
        raise evidence.EvidenceError("host monitor supervisor CPU ticks did not advance")
    supervisor_duration = supervisor_ended - supervisor_started
    supervisor_host_busy = (
        supervisor_tick_deltas["user"]
        + supervisor_tick_deltas["system"]
        + supervisor_tick_deltas["nice"]
    ) / supervisor_total_ticks
    supervisor_process_fraction = outer_cpu_total / (
        supervisor_duration * logical_cpus * 1_000_000
    )
    if supervisor_process_fraction > 1.05 + 1e-12:
        raise evidence.EvidenceError("outer child CPU exceeds its wall-time bound")
    unattributed_child_cpu = max(0, outer_cpu_total - process_cpu_total)
    unattributed_child_fraction = unattributed_child_cpu / (
        supervisor_duration * logical_cpus * 1_000_000
    )

    first_state = samples[0][1]
    last_state = samples[-1][1]
    for field in ("vm_pageouts", "vm_swapouts"):
        if last_state[field] < first_state[field]:
            raise evidence.EvidenceError(f"host monitor {field} counter moved backwards")
    return {
        "schema_version": 1,
        "monotonic_clock": "mach_absolute_time",
        "monitor_sha256": monitor_sha256,
        "monitor_executable_sha256": monitor_executable_sha256,
        "sample_interval_seconds": float(interval),
        "sample_count": len(samples),
        "maximum_sample_gap_seconds": maximum_gap,
        "first_monotonic_seconds": first_timestamp,
        "last_monotonic_seconds": last_timestamp,
        "state_change_events": state_change_events,
        "power_sources": sorted({state["power_source"] for _, state in samples}),
        "thermal_states": sorted({state["thermal_state"] for _, state in samples}),
        "low_power_mode_observed": any(state["low_power_mode"] for _, state in samples),
        "vm_pageouts_delta": last_state["vm_pageouts"] - first_state["vm_pageouts"],
        "vm_swapouts_delta": last_state["vm_swapouts"] - first_state["vm_swapouts"],
        "outer_child_cpu_microseconds": dict(outer_child_cpu_microseconds),
        "supervisor_host_busy_fraction": supervisor_host_busy,
        "supervisor_process_cpu_fraction": supervisor_process_fraction,
        "supervisor_external_cpu_fraction": max(
            0.0,
            supervisor_host_busy - supervisor_process_fraction,
        ),
        "unattributed_child_cpu_fraction": unattributed_child_fraction,
        "commands": command_environment,
    }


def _measurement_timeout_seconds(scale: int, override: str | None = None) -> float:
    if type(scale) is not int or scale <= 0:
        raise benchmark.ConfigError("benchmark scale must be a positive integer")
    if override is not None:
        try:
            seconds = float(override)
        except (TypeError, ValueError) as error:
            raise benchmark.ConfigError(
                f"{_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY} must be a finite number of seconds"
            ) from error
        if (
            not math.isfinite(seconds)
            or seconds < _MINIMUM_TIMEOUT_OVERRIDE_SECONDS
            or seconds > _MAXIMUM_TIMEOUT_OVERRIDE_SECONDS
        ):
            raise benchmark.ConfigError(
                f"{_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY} must be between "
                f"{_MINIMUM_TIMEOUT_OVERRIDE_SECONDS:g} and "
                f"{_MAXIMUM_TIMEOUT_OVERRIDE_SECONDS:g} seconds"
            )
        return seconds

    # A protected lane can include warm-ups, alternating baseline/candidate runs,
    # accurate references, and artifact validation. Keep the ceiling generous
    # enough for those real workloads while still bounding a wedged runner.
    return min(24 * 60 * 60.0, max(2 * 60 * 60.0, scale * 90.0))


def _signal_process_group(process: subprocess.Popen[bytes], signal_number: int) -> None:
    try:
        os.killpg(process.pid, signal_number)
    except ProcessLookupError:
        return
    except OSError as error:
        raise benchmark.ConfigError("could not terminate the measurement process group") from error


def _terminate_process_group(
    process: subprocess.Popen[bytes],
    grace_seconds: float | None = None,
) -> int:
    if grace_seconds is None:
        grace_seconds = _PROCESS_GROUP_TERMINATION_GRACE_SECONDS
    _signal_process_group(process, signal.SIGTERM)
    # Do not reap the session leader before the final group signal. Keeping it
    # unreaped prevents its process-group ID from being reused for unrelated work.
    time.sleep(grace_seconds)
    if _process_group_exists(process.pid):
        _signal_process_group(process, signal.SIGKILL)
    try:
        return process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired as error:
        raise benchmark.ConfigError(
            "measurement runner did not exit after process-group termination"
        ) from error


def _process_group_exists(process_group_id: int) -> bool:
    try:
        completed = subprocess.run(
            ["/bin/ps", "-axo", "pid=,pgid=,state="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            text=True,
        )
        if completed.returncode == 0:
            for line in completed.stdout.splitlines():
                fields = line.split()
                if len(fields) >= 3 and int(fields[1]) == process_group_id:
                    if not fields[2].startswith("Z"):
                        return True
            return False
    except (OSError, ValueError):
        pass
    try:
        os.killpg(process_group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


@dataclass(frozen=True)
class _ProcessRecord:
    pid: int
    parent_pid: int
    process_group_id: int
    real_user_id: int
    state: str
    started: tuple[int, int]


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32),
        ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("open_files", ctypes.c_uint32),
        ("process_group_id", ctypes.c_uint32),
        ("job_control_count", ctypes.c_uint32),
        ("controlling_device", ctypes.c_uint32),
        ("terminal_process_group", ctypes.c_uint32),
        ("nice", ctypes.c_int32),
        ("started_seconds", ctypes.c_uint64),
        ("started_microseconds", ctypes.c_uint64),
    ]


_LIBPROC = None
_LIBC = None
if sys.platform == "darwin":
    _LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
    _LIBPROC.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    _LIBPROC.proc_listallpids.restype = ctypes.c_int
    _LIBPROC.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    _LIBPROC.proc_listchildpids.restype = ctypes.c_int
    _LIBPROC.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    _LIBPROC.proc_pidinfo.restype = ctypes.c_int
    _LIBC = ctypes.CDLL(None, use_errno=True)
    _LIBC.sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    _LIBC.sysctl.restype = ctypes.c_int
_PROC_PIDTBSDINFO = 3
_CTL_KERN = 1
_KERN_PROCARGS2 = 49
_SZOMB = 5
_CHILD_PID_CAPACITY = 4096
_MAXIMUM_PROCESS_ENVIRONMENT_BYTES = 16 * 1024 * 1024


def _process_record(pid: int) -> _ProcessRecord | None:
    if _LIBPROC is None:
        if not sys.platform.startswith("linux"):
            return None
        process_root = Path("/proc") / str(pid)
        try:
            raw = (process_root / "stat").read_text(encoding="utf-8")
            closing_parenthesis = raw.rfind(")")
            fields = raw[closing_parenthesis + 2 :].split()
            if closing_parenthesis < 0 or len(fields) < 20:
                return None
            return _ProcessRecord(
                pid=pid,
                parent_pid=int(fields[1]),
                process_group_id=int(fields[2]),
                real_user_id=process_root.stat().st_uid,
                state=fields[0],
                started=(int(fields[19]), 0),
            )
        except (OSError, UnicodeError, ValueError):
            return None
    info = _ProcBSDInfo()
    copied = _LIBPROC.proc_pidinfo(
        pid,
        _PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if copied != ctypes.sizeof(info) or info.pid != pid:
        return None
    return _ProcessRecord(
        pid=pid,
        parent_pid=int(info.ppid),
        process_group_id=int(info.process_group_id),
        real_user_id=int(info.ruid),
        state="Z" if info.status == _SZOMB else "",
        started=(int(info.started_seconds), int(info.started_microseconds)),
    )


def _child_process_ids(pid: int) -> list[int]:
    if _LIBPROC is None:
        if not sys.platform.startswith("linux"):
            return []
        try:
            children = (Path("/proc") / str(pid) / "task" / str(pid) / "children").read_text(
                encoding="utf-8"
            )
            return [int(child) for child in children.split() if int(child) > 0]
        except (OSError, UnicodeError, ValueError):
            return []
    children = (ctypes.c_int32 * _CHILD_PID_CAPACITY)()
    count = _LIBPROC.proc_listchildpids(pid, children, ctypes.sizeof(children))
    if count <= 0:
        return []
    return [int(child) for child in children[: min(count, _CHILD_PID_CAPACITY)] if child > 0]


def _all_process_ids() -> list[int]:
    if _LIBPROC is None:
        if not sys.platform.startswith("linux"):
            return []
        try:
            return [int(entry.name) for entry in Path("/proc").iterdir() if entry.name.isdigit()]
        except OSError:
            return []
    reported = _LIBPROC.proc_listallpids(None, 0)
    capacity = max(1024, reported + 64 if reported > 0 else 1024)
    while capacity <= 131_072:
        pids = (ctypes.c_int32 * capacity)()
        count = _LIBPROC.proc_listallpids(pids, ctypes.sizeof(pids))
        if count <= 0:
            return []
        if count < capacity:
            return [int(pid) for pid in pids[:count] if pid > 0]
        capacity *= 2
    return []


def _process_environment(pid: int) -> bytes | None:
    if _LIBC is None:
        if not sys.platform.startswith("linux"):
            return None
        try:
            value = (Path("/proc") / str(pid) / "environ").read_bytes()
        except OSError:
            return None
        return value if len(value) <= _MAXIMUM_PROCESS_ENVIRONMENT_BYTES else None
    mib = (ctypes.c_int * 3)(_CTL_KERN, _KERN_PROCARGS2, pid)
    size = ctypes.c_size_t()
    if _LIBC.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    if size.value <= 0 or size.value > _MAXIMUM_PROCESS_ENVIRONMENT_BYTES:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    actual = ctypes.c_size_t(size.value)
    if _LIBC.sysctl(mib, 3, buffer, ctypes.byref(actual), None, 0) != 0:
        return None
    return buffer.raw[: actual.value]


def _process_has_token(pid: int, token: str) -> bool:
    environment = _process_environment(pid)
    if environment is None:
        return False
    expected = f"{_PROCESS_TOKEN_ENVIRONMENT_KEY}={token}".encode("utf-8")
    return expected in environment.split(b"\0")


def _tagged_process_records(token: str) -> list[_ProcessRecord]:
    records = []
    for pid in _all_process_ids():
        record = _process_record(pid)
        if (
            record is not None
            and record.real_user_id == os.getuid()
            and not record.state.startswith("Z")
            and _process_has_token(pid, token)
        ):
            records.append(record)
    return records


class _ProcessTreeTracker:
    """Track trusted descendants across reparenting and new sessions.

    Token discovery is a cleanup backstop for the pinned runner, not a sandbox:
    a process that deliberately scrubs its environment is outside this contract.
    """

    def __init__(self, root_pid: int, process_token: str) -> None:
        self.root_pid = root_pid
        self.process_token = process_token
        self._root = _process_record(root_pid)
        self._tracked: dict[int, _ProcessRecord] = {}
        self._tagged_identities: set[tuple[int, tuple[int, int]]] = set()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._watch, daemon=True)

    def start(self) -> None:
        self._scan()
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)
        self._scan()
        self._scan_tagged()

    def refresh_reparented_descendants(self) -> None:
        self._scan_tagged()

    def live_descendants(self) -> list[_ProcessRecord]:
        with self._lock:
            tracked = tuple(self._tracked.values())
        live = []
        for expected in tracked:
            current = _process_record(expected.pid)
            if (
                current is None
                or current.real_user_id != expected.real_user_id
                or current.started != expected.started
                or current.state.startswith("Z")
            ):
                continue
            identity = (expected.pid, expected.started)
            if identity in self._tagged_identities and not _process_has_token(
                expected.pid,
                self.process_token,
            ):
                continue
            live.append(current)
        return live

    def terminate_descendants(
        self,
        grace_seconds: float = _PROCESS_GROUP_TERMINATION_GRACE_SECONDS,
    ) -> None:
        self._scan_tagged()
        self._signal_live(signal.SIGTERM)
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            self._scan_tagged()
            if not self.live_descendants():
                return
            time.sleep(0.05)
        self._scan_tagged()
        self._signal_live(signal.SIGKILL)

    def _signal_live(self, signal_number: int) -> None:
        self._scan_tagged()
        for expected in self.live_descendants():
            current = _process_record(expected.pid)
            identity = (expected.pid, expected.started)
            if (
                current is None
                or current.real_user_id != expected.real_user_id
                or current.started != expected.started
                or current.state.startswith("Z")
                or (
                    identity in self._tagged_identities
                    and not _process_has_token(expected.pid, self.process_token)
                )
            ):
                continue
            try:
                os.kill(current.pid, signal_number)
            except (ProcessLookupError, PermissionError):
                continue

    def _watch(self) -> None:
        while not self._stop.wait(_PROCESS_TREE_SCAN_SECONDS):
            self._scan()

    def _scan(self) -> None:
        with self._lock:
            pending = ([self._root] if self._root is not None else []) + list(
                self._tracked.values()
            )
            inspected: set[int] = set()
            while pending:
                expected_parent = pending.pop()
                if expected_parent.pid in inspected:
                    continue
                inspected.add(expected_parent.pid)
                current_parent = _process_record(expected_parent.pid)
                if (
                    current_parent is None
                    or current_parent.real_user_id != expected_parent.real_user_id
                    or current_parent.started != expected_parent.started
                    or current_parent.state.startswith("Z")
                ):
                    continue
                for child_pid in _child_process_ids(current_parent.pid):
                    record = _process_record(child_pid)
                    if (
                        record is None
                        or record.parent_pid != current_parent.pid
                        or record.real_user_id != os.getuid()
                    ):
                        continue
                    tracked = self._tracked.get(child_pid)
                    if tracked is None:
                        self._tracked[child_pid] = record
                        tracked = record
                    elif (
                        tracked.real_user_id != record.real_user_id
                        or tracked.started != record.started
                    ):
                        continue
                    pending.append(tracked)

    def _scan_tagged(self) -> None:
        tagged = _tagged_process_records(self.process_token)
        with self._lock:
            for record in tagged:
                if record.pid == self.root_pid:
                    continue
                tracked = self._tracked.get(record.pid)
                if tracked is not None and (
                    tracked.real_user_id != record.real_user_id
                    or tracked.started != record.started
                ):
                    current = _process_record(tracked.pid)
                    if (
                        current is not None
                        and current.real_user_id == tracked.real_user_id
                        and current.started == tracked.started
                    ):
                        continue
                self._tracked[record.pid] = record
                self._tagged_identities.add((record.pid, record.started))


def _terminate_reaped_leader_group(
    process_group_id: int,
    grace_seconds: float = _PROCESS_GROUP_TERMINATION_GRACE_SECONDS,
) -> None:
    # A surviving process still owns this PGID, so it cannot be reused while
    # these signals are sent. Never signal the ID after the group disappears.
    if not _process_group_exists(process_group_id):
        return
    try:
        os.killpg(process_group_id, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + grace_seconds
    while _process_group_exists(process_group_id) and time.monotonic() < deadline:
        time.sleep(0.05)
    if not _process_group_exists(process_group_id):
        return
    try:
        os.killpg(process_group_id, signal.SIGKILL)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + grace_seconds
    while _process_group_exists(process_group_id) and time.monotonic() < deadline:
        time.sleep(0.05)


def _reject_live_descendants(
    process_group_id: int,
    process_tree: _ProcessTreeTracker | None = None,
) -> None:
    deadline = time.monotonic() + _PROCESS_GROUP_DRAIN_SECONDS
    while True:
        if process_tree is not None:
            process_tree.refresh_reparented_descendants()
        group_live = _process_group_exists(process_group_id)
        tree_live = process_tree.live_descendants() if process_tree is not None else []
        now = time.monotonic()
        if now >= deadline:
            break
        time.sleep(min(0.01, deadline - now))
    if not group_live and not tree_live:
        return
    if group_live:
        _terminate_reaped_leader_group(process_group_id)
    if process_tree is not None and tree_live:
        process_tree.terminate_descendants()
    raise benchmark.ConfigError(
        "protected subprocess left live child processes after its session leader exited"
    )


def _run_measurement_process(
    command: Sequence[str],
    stdout_handle: BinaryIO,
    stderr_handle: BinaryIO,
    environment: Mapping[str, str],
    timeout_seconds: float,
) -> tuple[subprocess.CompletedProcess[bytes], bool]:
    process_token = secrets.token_hex(32)
    protected_environment = dict(environment)
    protected_environment[_PROCESS_TOKEN_ENVIRONMENT_KEY] = process_token
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=stdout_handle,
        stderr=stderr_handle,
        env=protected_environment,
        start_new_session=True,
    )
    process_tree = (
        _ProcessTreeTracker(process.pid, process_token)
        if isinstance(process.pid, int)
        else None
    )
    if process_tree is not None:
        process_tree.start()
    try:
        return_code = process.wait(timeout=timeout_seconds)
        if process_tree is not None:
            process_tree.stop()
        _reject_live_descendants(process.pid, process_tree)
        return subprocess.CompletedProcess(command, return_code), False
    except subprocess.TimeoutExpired:
        return_code = _terminate_process_group(process)
        if process_tree is not None:
            process_tree.stop()
            process_tree.terminate_descendants()
        return subprocess.CompletedProcess(command, return_code), True
    except BaseException:
        try:
            if process_tree is not None:
                process_tree.stop()
            if process.poll() is None:
                _terminate_process_group(process)
            else:
                _terminate_reaped_leader_group(process.pid)
            if process_tree is not None:
                process_tree.terminate_descendants()
        except Exception:
            pass
        raise


def _require_owned_artifact(path: Path, artifact_root: Path, label: str) -> Path:
    if path.parent != artifact_root or path.is_symlink() or not path.is_file():
        raise benchmark.ConfigError(f"{label} must be a supervisor-visible regular artifact")
    return path


def _rendering_required(request: Mapping[str, Any], lane: str) -> bool:
    return (
        lane == evidence.LANE_REFERENCE
        and request["expected_outcome"]["kind"] == "valid"
        and "scene_quality" in request["gate_scopes"]
    )


def _orientation_required(request: Mapping[str, Any], lane: str) -> bool:
    return _rendering_required(request, lane)


def _require_single_link_artifact(
    path: Path,
    artifact_root: Path,
    label: str,
) -> Path:
    try:
        relative = path.relative_to(artifact_root)
    except ValueError as error:
        raise benchmark.ConfigError(f"{label} escapes the benchmark artifact root") from error
    cursor = artifact_root
    for part in relative.parts[:-1]:
        cursor /= part
        try:
            metadata = cursor.lstat()
        except OSError as error:
            raise benchmark.ConfigError(f"{label} has a missing parent directory") from error
        if not stat.S_ISDIR(metadata.st_mode) or cursor.is_symlink():
            raise benchmark.ConfigError(f"{label} has an unsafe parent directory")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
        root = artifact_root.resolve(strict=True)
    except OSError as error:
        raise benchmark.ConfigError(f"{label} is missing") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or path.is_symlink()
        or (resolved != root and root not in resolved.parents)
    ):
        raise benchmark.ConfigError(f"{label} must be a contained single-link regular file")
    return path


def _orientation_candidate_records(
    observations: Mapping[str, Any],
) -> list[Mapping[str, Any]]:
    timing = benchmark._require_mapping(observations.get("timing"), "observations timing")
    ordinary = timing.get("ordinary_runs")
    expected_variants = [
        "baseline",
        "candidate",
        "baseline",
        "candidate",
        "candidate",
        "baseline",
        "baseline",
        "candidate",
    ]
    if not isinstance(ordinary, list) or len(ordinary) != len(expected_variants):
        raise benchmark.ConfigError(
            "orientation extraction requires the bounded ordinary timing sequence"
        )
    records: list[Mapping[str, Any]] = []
    run_ids: set[str] = set()
    for index, (raw_record, expected_variant) in enumerate(
        zip(ordinary, expected_variants, strict=True)
    ):
        record = benchmark._require_mapping(
            raw_record,
            f"ordinary timing run {index}",
        )
        if (
            record.get("variant") != expected_variant
            or record.get("discarded") is not (index < 2)
        ):
            raise benchmark.ConfigError(
                "orientation extraction requires the canonical ordinary timing sequence"
            )
        if expected_variant != "candidate":
            continue
        run_id = benchmark._require_safe_token(record.get("run_id"), "candidate run id")
        if run_id in run_ids:
            raise benchmark.ConfigError("candidate orientation timing record is invalid")
        run_ids.add(run_id)
        records.append(record)
    if not records:
        raise benchmark.ConfigError("orientation extraction requires candidate timing runs")
    return records


def _published_orientation_run_id(
    commands: Sequence[Mapping[str, Any]],
    candidate_run_ids: set[str],
) -> str:
    published = [
        command
        for command in commands
        if command.get("variant") == "candidate"
        and command.get("published_output") is True
    ]
    if len(published) != 1 or published[0].get("run_id") not in candidate_run_ids:
        raise benchmark.ConfigError(
            "orientation extraction requires one published candidate ordinary run"
        )
    return str(published[0]["run_id"])


def _write_exclusive_json(path: Path, value: Mapping[str, Any], label: str) -> None:
    try:
        with path.open("xb") as handle:
            handle.write(evidence.canonical_json_bytes(value) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        directory_descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except FileExistsError as error:
        raise benchmark.ConfigError(
            f"measurement runner cannot pre-create supervisor-owned {label}"
        ) from error


def _collector_identity() -> dict[str, Any]:
    collector_path = Path(__file__).resolve()
    root = collector_path.parents[2]
    if collector_path != root / _COLLECTOR_RELATIVE_PATH:
        raise benchmark.ConfigError("evidence collector is not running from the repository path")
    return {
        "protocol_version": evidence.PROTOCOL_VERSION,
        "version": _COLLECTOR_VERSION,
        "executable": _COLLECTOR_RELATIVE_PATH,
        "sha256": evidence.sha256_file(collector_path),
    }


def _write_collector_status(
    *,
    artifact_root: Path,
    request: Mapping[str, Any],
    lane: str,
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
    disposition: str,
    outcome: Mapping[str, Any] | None,
) -> Path:
    status_path = artifact_root / "collector-status.json"
    for path, label in (
        (artifact_root / "attestation.json", "attestation.json"),
        (artifact_root / "lane-outcome.json", "lane-outcome.json"),
        (status_path, "collector-status.json"),
    ):
        if path.exists() or path.is_symlink():
            raise benchmark.ConfigError(
                f"measurement runner cannot pre-create supervisor-owned {label}"
            )
    if disposition not in {"attestation_candidate", "lane_outcome"}:
        raise benchmark.ConfigError("collector disposition is invalid")
    if (disposition == "attestation_candidate") != (outcome is None):
        raise benchmark.ConfigError("collector disposition does not match its outcome")
    status = {
        "schema_version": 1,
        "request_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(evidence.validate_request(request))
        ),
        "lane": lane,
        "machine": dict(machine),
        "measurement_runner": dict(runner_identity),
        "collector": _collector_identity(),
        "disposition": disposition,
        "outcome": dict(outcome) if outcome is not None else None,
    }
    _write_exclusive_json(status_path, status, "collector-status.json")
    return status_path


def _collector_outcome_payload(
    *,
    kind: str,
    reason: str,
    exit_code: int | None,
) -> dict[str, Any]:
    stage = (
        "measurement_environment"
        if kind == "environment_rejected"
        else {
            "host_monitor_failed": "host_monitor",
            "postprocessing_failed": "postprocessing",
        }.get(reason, "measurement_runner")
    )
    return {
        "kind": kind,
        "stage": stage,
        "reason": reason,
        "exit_code": exit_code,
    }


def _write_collector_outcome(
    *,
    artifact_root: Path,
    request: Mapping[str, Any],
    lane: str,
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
    kind: str,
    reason: str,
    exit_code: int | None,
) -> Path:
    return _write_collector_status(
        artifact_root=artifact_root,
        request=request,
        lane=lane,
        runner_identity=runner_identity,
        machine=machine,
        disposition="lane_outcome",
        outcome=_collector_outcome_payload(
            kind=kind,
            reason=reason,
            exit_code=exit_code,
        ),
    )


def _selected_lane_entries(
    requests: Sequence[Any],
    lane: str,
) -> list[Mapping[str, Any]]:
    selected: list[Mapping[str, Any]] = []
    seen: set[tuple[str, int, str]] = set()
    for raw_entry in requests:
        if not isinstance(raw_entry, Mapping) or raw_entry.get("lane") != lane:
            continue
        entry = benchmark._require_mapping(raw_entry, "request index entry")
        scene_id = benchmark._require_safe_token(entry.get("scene_id"), "request scene_id")
        scale = entry.get("scale")
        if type(scale) is not int or scale <= 0:
            raise benchmark.ConfigError("request index entry scale is invalid")
        key = (scene_id, scale, lane)
        if key in seen:
            raise benchmark.ConfigError("request index duplicates a scene-scale-lane key")
        seen.add(key)
        selected.append(entry)
    return selected


def _canonical_collector_status_bytes(path: Path, output_root: Path) -> tuple[bytes, Mapping[str, Any], Path]:
    try:
        output_metadata = output_root.lstat()
        canonical_output = output_root.resolve(strict=True)
        relative = path.relative_to(output_root)
    except (OSError, ValueError) as error:
        raise benchmark.ConfigError("collector status escapes the benchmark output root") from error
    if output_root.is_symlink() or not stat.S_ISDIR(output_metadata.st_mode):
        raise benchmark.ConfigError("benchmark output root must be a real directory")
    if relative.as_posix() != PurePosixPath(relative.as_posix()).as_posix():
        raise benchmark.ConfigError("collector status path is not canonical")
    cursor = output_root
    for component in relative.parts[:-1]:
        cursor /= component
        try:
            metadata = cursor.lstat()
        except OSError as error:
            raise benchmark.ConfigError("collector status parent is missing") from error
        if cursor.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise benchmark.ConfigError("collector status path contains an unsafe parent")
    try:
        metadata = path.lstat()
        resolved_parent = path.parent.resolve(strict=True)
    except OSError as error:
        raise benchmark.ConfigError("collector status is missing") from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > evidence.MAX_LANE_OUTCOME_BYTES
        or (resolved_parent != canonical_output and canonical_output not in resolved_parent.parents)
    ):
        raise benchmark.ConfigError("collector status must be a bounded single-link regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            opened = os.fstat(handle.fileno())
            data = handle.read(evidence.MAX_LANE_OUTCOME_BYTES + 1)
            after = os.fstat(handle.fileno())
    except OSError as error:
        raise benchmark.ConfigError("collector status could not be read safely") from error
    stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_nlink")
    if (
        len(data) > evidence.MAX_LANE_OUTCOME_BYTES
        or not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or any(getattr(opened, field) != getattr(metadata, field) for field in stable_fields)
        or any(getattr(after, field) != getattr(opened, field) for field in stable_fields)
    ):
        raise benchmark.ConfigError("collector status changed while it was read")
    try:
        value = json.loads(data.decode("utf-8"))
        canonical = evidence.canonical_json_bytes(value) + b"\n"
    except (UnicodeError, ValueError, TypeError, RecursionError) as error:
        raise benchmark.ConfigError("collector status is not strict JSON") from error
    if data != canonical or not isinstance(value, Mapping):
        raise benchmark.ConfigError("collector status is not canonical JSON")
    return data, value, relative


def _collection_from_status(
    *,
    output_root: Path,
    status_path: Path,
    scene_id: str,
    scale: int,
    lane: str,
    request: Mapping[str, Any],
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
    expected_relative: Path | None = None,
) -> dict[str, Any]:
    data, raw_status, relative = _canonical_collector_status_bytes(status_path, output_root)
    if expected_relative is not None and relative != expected_relative:
        raise benchmark.ConfigError("collector status path does not match its request index entry")
    status = benchmark._require_mapping(raw_status, "collector status")
    benchmark._require_exact_keys(
        status,
        {
            "schema_version",
            "request_sha256",
            "lane",
            "machine",
            "measurement_runner",
            "collector",
            "disposition",
            "outcome",
        },
        "collector status",
    )
    expected_request_digest = evidence.sha256_bytes(
        evidence.canonical_json_bytes(evidence.validate_request(request))
    )
    if (
        status["schema_version"] != 1
        or status["request_sha256"] != expected_request_digest
        or status["lane"] != lane
        or status["machine"] != dict(machine)
        or status["measurement_runner"] != dict(runner_identity)
        or status["collector"] != _collector_identity()
    ):
        raise benchmark.ConfigError("collector status identity does not match its protected request")
    disposition = status["disposition"]
    outcome = status["outcome"]
    if disposition == "attestation_candidate":
        if outcome is not None:
            raise benchmark.ConfigError("attestation candidate collector status carries an outcome")
    elif disposition == "lane_outcome":
        try:
            evidence._validate_lane_outcome_payload(outcome)
        except evidence.EvidenceError as error:
            raise benchmark.ConfigError(f"collector lane outcome is invalid: {error}") from error
    else:
        raise benchmark.ConfigError("collector status disposition is invalid")
    return {
        "scene_id": scene_id,
        "scale": scale,
        "lane": lane,
        "collector_status": relative.as_posix(),
        "sha256": evidence.sha256_bytes(data),
    }


def _validate_completed_collection(
    descriptor: Mapping[str, Any],
    *,
    output_root: Path,
    expected_relative: Path,
    scene_id: str,
    scale: int,
    lane: str,
    request: Mapping[str, Any],
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
) -> dict[str, Any]:
    collection = benchmark._require_mapping(descriptor, "completed lane collection")
    benchmark._require_exact_keys(
        collection,
        {"scene_id", "scale", "lane", "collector_status", "sha256"},
        "completed lane collection",
    )
    if (
        collection["scene_id"] != scene_id
        or collection["scale"] != scale
        or collection["lane"] != lane
        or collection["collector_status"] != expected_relative.as_posix()
    ):
        raise benchmark.ConfigError("completed lane collection does not match request order")
    current = _collection_from_status(
        output_root=output_root,
        status_path=output_root / expected_relative,
        scene_id=scene_id,
        scale=scale,
        lane=lane,
        request=request,
        runner_identity=runner_identity,
        machine=machine,
        expected_relative=expected_relative,
    )
    if current != dict(collection):
        raise benchmark.ConfigError("completed collector status digest changed")
    return current


def _raise_invalid_runner_output(
    *,
    artifact_root: Path,
    request: Mapping[str, Any],
    lane: str,
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
    scene_id: str,
    scale: int,
    cause: BaseException,
) -> NoReturn:
    status_path = _write_collector_outcome(
        artifact_root=artifact_root,
        request=request,
        lane=lane,
        runner_identity=runner_identity,
        machine=machine,
        kind="execution_failed",
        reason="invalid_output",
        exit_code=0,
    )
    raise _CollectedOutcome(
        f"{lane} measurement runner emitted invalid output for {scene_id}@{scale}",
        scene_id=scene_id,
        scale=scale,
        lane=lane,
        status_path=status_path,
        request=request,
        runner_identity=runner_identity,
        machine=machine,
    ) from cause


def _raise_infrastructure_blocked(
    *,
    artifact_root: Path,
    request: Mapping[str, Any],
    lane: str,
    runner_identity: Mapping[str, Any],
    machine: Mapping[str, Any],
    scene_id: str,
    scale: int,
    reason: str,
    exit_code: int | None,
    cause: BaseException,
) -> NoReturn:
    status_path = _write_collector_outcome(
        artifact_root=artifact_root,
        request=request,
        lane=lane,
        runner_identity=runner_identity,
        machine=machine,
        kind="infrastructure_blocked",
        reason=reason,
        exit_code=exit_code,
    )
    raise _CollectedOutcome(
        f"{lane} protected evidence infrastructure failed for {scene_id}@{scale}",
        scene_id=scene_id,
        scale=scale,
        lane=lane,
        status_path=status_path,
        request=request,
        runner_identity=runner_identity,
        machine=machine,
    ) from cause


def _execute_orientation_stage(
    *,
    artifact_root: Path,
    request: Mapping[str, Any],
    request_path: Path,
    request_digest: str,
    renderer_closure_path: Path,
    renderer_identity: Mapping[str, Any],
    observations: Mapping[str, Any],
    commands: Sequence[Mapping[str, Any]],
    timeout_seconds: float,
) -> dict[str, Any]:
    metrics_index_path = artifact_root / "orientation-metrics.json"
    supervisor_path = artifact_root / "orientation-supervisor.json"
    for path, label in (
        (metrics_index_path, "orientation-metrics.json"),
        (supervisor_path, "orientation-supervisor.json"),
    ):
        if path.exists() or path.is_symlink():
            raise benchmark.ConfigError(
                f"measurement runner cannot pre-create supervisor-owned {label}"
            )

    ground_truth_path = _require_single_link_artifact(
        artifact_root / "ground-truth-poses.json",
        artifact_root,
        "ground-truth-poses.json",
    )
    orientation_label_path = _require_single_link_artifact(
        artifact_root / "orientation-label.json",
        artifact_root,
        "orientation-label.json",
    )
    ground_truth_digest = evidence.sha256_file(ground_truth_path)
    label_digest = evidence.sha256_file(orientation_label_path)
    if ground_truth_digest != request["reference_artifacts"]["ground_truth_poses_sha256"]:
        raise benchmark.ConfigError("ground-truth poses do not match the protected request")
    if label_digest != request["reference_artifacts"]["orientation_label_sha256"]:
        raise benchmark.ConfigError("orientation label does not match the protected request")

    candidate_records = _orientation_candidate_records(observations)
    candidate_run_ids = {str(record["run_id"]) for record in candidate_records}
    scoring_run_id = _published_orientation_run_id(commands, candidate_run_ids)
    receipts: list[dict[str, Any]] = []
    aggregate_runs: list[dict[str, Any]] = []
    orientation_timeout = min(timeout_seconds, _ORIENTATION_EXTRACTION_TIMEOUT_SECONDS)
    for record in candidate_records:
        run_id = str(record["run_id"])
        relative_root = Path("orientation-runs") / run_id
        run_root = artifact_root / relative_root
        geometry_manifest = _require_single_link_artifact(
            run_root / "geometry-manifest.json",
            artifact_root,
            f"geometry manifest for {run_id}",
        )
        candidate_images = _require_single_link_artifact(
            run_root / "candidate-images.txt",
            artifact_root,
            f"candidate images for {run_id}",
        )
        metrics_path = run_root / "orientation-metrics.json"
        stdout_path = run_root / "orientation-stdout.log"
        stderr_path = run_root / "orientation-stderr.log"
        for path, label in (
            (metrics_path, "orientation-metrics.json"),
            (stdout_path, "orientation-stdout.log"),
            (stderr_path, "orientation-stderr.log"),
        ):
            if path.exists() or path.is_symlink():
                raise benchmark.ConfigError(
                    f"measurement runner cannot pre-create supervisor-owned {label}"
                )

        try:
            verified = _verify_renderer_closure(
                renderer_closure_path,
                renderer_identity,
                f"immediately before orientation extraction for {run_id}",
            )
        except Exception as error:
            raise _IntegrityFailure(
                f"renderer closure changed before orientation extraction for {run_id}"
            ) from error
        immutable_digests = {
            geometry_manifest: evidence.sha256_file(geometry_manifest),
            candidate_images: evidence.sha256_file(candidate_images),
            ground_truth_path: ground_truth_digest,
            orientation_label_path: label_digest,
        }
        relative_geometry = (relative_root / "geometry-manifest.json").as_posix()
        relative_images = (relative_root / "candidate-images.txt").as_posix()
        relative_metrics = (relative_root / "orientation-metrics.json").as_posix()
        redacted_command = [
            "approved-orientation-driver",
            f"renderer-closure://{renderer_identity['sha256']}",
            f"renderer-executable://{renderer_identity['executable_sha256']}",
            "extract-orientation",
            "--geometry-manifest",
            f"evidence://{relative_geometry}",
            "--candidate-images",
            f"evidence://{relative_images}",
            "--ground-truth-poses",
            "evidence://ground-truth-poses.json",
            "--ground-truth-poses-sha256",
            ground_truth_digest,
            "--orientation-label",
            "evidence://orientation-label.json",
            "--orientation-label-sha256",
            label_digest,
            "--output",
            f"evidence://{relative_metrics}",
        ]
        command = [
            str(verified.executable),
            "extract-orientation",
            "--geometry-manifest",
            str(geometry_manifest),
            "--candidate-images",
            str(candidate_images),
            "--ground-truth-poses",
            str(ground_truth_path),
            "--ground-truth-poses-sha256",
            ground_truth_digest,
            "--orientation-label",
            str(orientation_label_path),
            "--orientation-label-sha256",
            label_digest,
            "--output",
            str(metrics_path),
        ]
        completed: subprocess.CompletedProcess[bytes] | None = None
        launch_error: OSError | None = None
        timed_out = False
        started_monotonic = time.monotonic()
        try:
            with stdout_path.open("xb") as stdout_handle, stderr_path.open("xb") as stderr_handle:
                completed, timed_out = _run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    _isolated_environment(artifact_root, f"orientation-{len(receipts):02d}"),
                    orientation_timeout,
                )
        except OSError as error:
            launch_error = error
        finally:
            ended_monotonic = time.monotonic()
            try:
                _verify_renderer_closure(
                    renderer_closure_path,
                    renderer_identity,
                    f"after orientation extraction for {run_id}",
                )
                for path, digest in immutable_digests.items():
                    _verify_file_digest(path, digest, f"orientation input {path.name}")
                _verify_file_digest(request_path, request_digest, "evidence request")
            except Exception as error:
                raise _IntegrityFailure(
                    f"protected orientation inputs changed during {run_id}"
                ) from error
        if completed is None:
            detail = launch_error.strerror if launch_error is not None else "unknown launch failure"
            raise _PostprocessingFailure(
                f"orientation driver could not start for {run_id}: {detail}"
            )
        if timed_out:
            raise _PostprocessingFailure(
                f"orientation driver timed out for {run_id} after {orientation_timeout:g} seconds"
            )
        if completed.returncode != 0:
            raise _PostprocessingFailure(
                f"orientation driver failed for {run_id} with exit {completed.returncode}"
            )
        try:
            _require_single_link_artifact(
                metrics_path,
                artifact_root,
                f"orientation metrics for {run_id}",
            )
            raw_metrics = _load(metrics_path, f"orientation metrics for {run_id}")
            metrics = evidence.validate_orientation_metrics(
                raw_metrics,
                f"orientation metrics for {run_id}",
            )
        except (benchmark.ConfigError, evidence.EvidenceError) as error:
            raise _PostprocessingFailure(str(error)) from error
        metrics_digest = evidence.sha256_file(metrics_path)
        aggregate_runs.append(
            {
                "metrics": metrics,
                "metrics_path": relative_metrics,
                "run_id": run_id,
            }
        )
        receipts.append(
            {
                "actual_argv_sha256": evidence.sha256_bytes(
                    evidence.canonical_json_bytes(command)
                ),
                "argv": redacted_command,
                "candidate_images_path": relative_images,
                "candidate_images_sha256": immutable_digests[candidate_images],
                "ended_monotonic_seconds": ended_monotonic,
                "exit_code": completed.returncode,
                "geometry_manifest_path": relative_geometry,
                "geometry_manifest_sha256": immutable_digests[geometry_manifest],
                "metrics_path": relative_metrics,
                "metrics_sha256": metrics_digest,
                "run_id": run_id,
                "started_monotonic_seconds": started_monotonic,
                "stderr_path": (relative_root / "orientation-stderr.log").as_posix(),
                "stderr_sha256": evidence.sha256_file(stderr_path),
                "stdout_path": (relative_root / "orientation-stdout.log").as_posix(),
                "stdout_sha256": evidence.sha256_file(stdout_path),
                "timed_out": False,
            }
        )

    aggregate = {
        "runs": aggregate_runs,
        "schema_version": 1,
        "scoring_run_id": scoring_run_id,
    }
    _write_exclusive_json(metrics_index_path, aggregate, "orientation-metrics.json")
    supervisor = {
        "candidate_git_commit": request["binding"]["git_commit"],
        "ground_truth_poses_sha256": ground_truth_digest,
        "lane": request["binding"]["lane"],
        "metrics_index_sha256": evidence.sha256_file(metrics_index_path),
        "orientation_label_sha256": label_digest,
        "renderer_closure_sha256": renderer_identity["sha256"],
        "renderer_executable_sha256": renderer_identity["executable_sha256"],
        "request_sha256": request_digest,
        "runs": receipts,
        "scale": request["binding"]["scale"],
        "scene_id": request["binding"]["scene_id"],
        "schema_version": 1,
        "scoring_run_id": scoring_run_id,
    }
    _write_exclusive_json(supervisor_path, supervisor, "orientation-supervisor.json")
    return supervisor


def _validate_render_job(
    job_path: Path,
    artifact_root: Path,
    request: Mapping[str, Any],
    request_digest: str,
    renderer_identity: Mapping[str, Any],
    candidate_checkout: Path,
    baseline_checkout: Path,
    commands: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    _require_owned_artifact(job_path, artifact_root, "render-job.json")
    job = benchmark._require_mapping(_load(job_path, "render job"), "render job")
    benchmark._require_exact_keys(
        job,
        {
            "schema_version",
            "scene_id",
            "scale",
            "request_digest",
            "input_digest",
            "renderer_closure_sha256",
            "renderer_executable_sha256",
            "holdout_indices",
            "training_view_indices",
            "candidate_checkout",
            "baseline_checkout",
            "views",
        },
        "render job",
    )
    binding = request["binding"]
    expected = {
        "schema_version": 1,
        "scene_id": binding["scene_id"],
        "scale": binding["scale"],
        "request_digest": request_digest,
        "input_digest": binding["input_digest"],
        "renderer_closure_sha256": renderer_identity["sha256"],
        "renderer_executable_sha256": renderer_identity["executable_sha256"],
        "holdout_indices": request["holdout_indices"],
        "training_view_indices": [
            index
            for index in range(binding["scale"])
            if index not in set(request["holdout_indices"])
        ],
    }
    for field, expected_value in expected.items():
        if job.get(field) != expected_value:
            raise benchmark.ConfigError(f"render job {field} does not match the protected request")
    checkout_expectations = (
        ("candidate_checkout", candidate_checkout, binding["git_commit"]),
        ("baseline_checkout", baseline_checkout, binding["baseline_git_commit"]),
    )
    for field, root, commit in checkout_expectations:
        checkout = benchmark._require_mapping(job.get(field), f"render job {field}")
        benchmark._require_exact_keys(checkout, {"path", "commit"}, f"render job {field}")
        try:
            supplied_root = _canonical_real_directory(
                Path(checkout["path"]),
                f"render job {field}",
            )
        except (OSError, TypeError) as error:
            raise benchmark.ConfigError(f"render job {field} path is invalid") from error
        if supplied_root != root.resolve(strict=True) or checkout["commit"] != commit:
            raise benchmark.ConfigError(
                f"render job {field} does not match the verified checkout root"
            )
    views = job.get("views")
    if not isinstance(views, list) or len(views) != len(request["holdout_indices"]):
        raise benchmark.ConfigError("render job does not cover every protected holdout")
    try:
        selected_sources = evidence.select_render_source_receipts(list(commands))
    except evidence.EvidenceError as error:
        raise benchmark.ConfigError(str(error)) from error
    source_fields = {
        "variant",
        "run_id",
        "checkout_commit",
        "toolchain_identity",
        "source_executable_sha256",
        "ply_path",
        "ply_sha256",
        "output_path",
    }
    immutable_paths: dict[str, str] = {}
    output_paths: set[Path] = set()
    for position, (raw_view, holdout_index) in enumerate(
        zip(views, request["holdout_indices"], strict=True)
    ):
        view = benchmark._require_mapping(raw_view, f"render job views[{position}]")
        benchmark._require_exact_keys(
            view,
            {"holdout_index", "camera", "ground_truth", "sources"},
            f"render job views[{position}]",
        )
        if view.get("holdout_index") != holdout_index:
            raise benchmark.ConfigError("render job views are not in bound holdout order")
        sources = view.get("sources")
        if not isinstance(sources, list) or len(sources) != len(evidence.RENDER_VARIANTS):
            raise benchmark.ConfigError("render job sources are incomplete")
        for source_position, (raw_source, variant) in enumerate(
            zip(sources, evidence.RENDER_VARIANTS, strict=True)
        ):
            source = benchmark._require_mapping(
                raw_source,
                f"render job views[{position}].sources[{source_position}]",
            )
            benchmark._require_exact_keys(
                source,
                source_fields,
                f"render job views[{position}].sources[{source_position}]",
            )
            selected = selected_sources[variant]
            if source.get("run_id") != selected.get("run_id"):
                if variant == "candidate_balanced":
                    raise benchmark.ConfigError(
                        "candidate_balanced must bind the sole published output receipt"
                    )
                raise benchmark.ConfigError(
                    f"{variant} does not use the deterministic source execution receipt"
                )
            expected_identity = {
                "variant": variant,
                "checkout_commit": selected.get("checkout_commit"),
                "toolchain_identity": selected.get("toolchain_identity"),
                "source_executable_sha256": selected.get("executable_sha256"),
                "ply_sha256": selected.get("output_sha256"),
            }
            if any(source.get(field) != value for field, value in expected_identity.items()):
                raise benchmark.ConfigError(
                    f"{variant} source identity does not match its protected execution receipt"
                )
            ply_path = _relative(
                source.get("ply_path"),
                f"render job views[{position}].sources[{source_position}].ply_path",
            ).as_posix()
            if variant in immutable_paths and immutable_paths[variant] != ply_path:
                raise benchmark.ConfigError(
                    f"{variant} must use one immutable PLY across all holdouts"
                )
            immutable_paths[variant] = ply_path
            output_path = _relative(
                source.get("output_path"),
                f"render job views[{position}].sources[{source_position}].output_path",
            )
            if output_path in output_paths:
                raise benchmark.ConfigError("render job output paths must be unique")
            output_paths.add(output_path)
    return dict(job)


def _execute_rendering_stage(
    *,
    artifact_root: Path,
    request: Mapping[str, Any],
    request_path: Path,
    request_digest: str,
    renderer_closure_path: Path,
    renderer_identity: Mapping[str, Any],
    candidate_checkout: Path,
    baseline_checkout: Path,
    commands: Sequence[Mapping[str, Any]],
    timeout_seconds: float,
) -> dict[str, Any]:
    job_path = artifact_root / "render-job.json"
    manifest_path = artifact_root / "rendering-manifest.json"
    supervisor_path = artifact_root / "render-supervisor.json"
    renderer_stdout = artifact_root / "renderer-stdout.log"
    renderer_stderr = artifact_root / "renderer-stderr.log"
    for path, label in (
        (manifest_path, "rendering-manifest.json"),
        (supervisor_path, "render-supervisor.json"),
        (renderer_stdout, "renderer-stdout.log"),
        (renderer_stderr, "renderer-stderr.log"),
    ):
        if path.exists() or path.is_symlink():
            raise benchmark.ConfigError(
                f"measurement runner cannot pre-create supervisor-owned {label}"
            )

    try:
        verified = _verify_renderer_closure(
            renderer_closure_path,
            renderer_identity,
            "immediately before rendering",
        )
    except Exception as error:
        raise _IntegrityFailure("renderer closure changed before rendering") from error
    _validate_render_job(
        job_path,
        artifact_root,
        request,
        request_digest,
        renderer_identity,
        candidate_checkout,
        baseline_checkout,
        commands,
    )
    job_digest = evidence.sha256_file(job_path)
    redacted_command = [
        "approved-rendering-driver",
        f"renderer-closure://{renderer_identity['sha256']}",
        f"renderer-executable://{renderer_identity['executable_sha256']}",
        "render",
        "--job",
        "evidence://render-job.json",
        "--artifact-root",
        "evidence://run",
        "--output",
        "evidence://rendering-manifest.json",
    ]
    command = [
        str(verified.executable),
        "render",
        "--job",
        str(job_path),
        "--artifact-root",
        str(artifact_root),
        "--output",
        str(manifest_path),
    ]
    completed: subprocess.CompletedProcess[bytes] | None = None
    launch_error: OSError | None = None
    timed_out = False
    started_monotonic = time.monotonic()
    try:
        with renderer_stdout.open("wb") as stdout_handle, renderer_stderr.open("wb") as stderr_handle:
            completed, timed_out = _run_measurement_process(
                command,
                stdout_handle,
                stderr_handle,
                _isolated_environment(artifact_root, "renderer"),
                timeout_seconds,
            )
    except OSError as error:
        launch_error = error
    finally:
        ended_monotonic = time.monotonic()
        try:
            _verify_renderer_closure(
                renderer_closure_path,
                renderer_identity,
                "after rendering",
            )
            _verify_file_digest(job_path, job_digest, "render job")
            _verify_file_digest(request_path, request_digest, "evidence request")
        except Exception as error:
            raise _IntegrityFailure("protected rendering inputs changed") from error
    if completed is None:
        detail = launch_error.strerror if launch_error is not None else "unknown launch failure"
        raise _PostprocessingFailure(f"rendering driver could not start: {detail}")
    if timed_out:
        raise _PostprocessingFailure(
            f"rendering driver timed out after {timeout_seconds:g} seconds"
        )
    if completed.returncode != 0:
        raise _PostprocessingFailure(
            f"rendering driver failed with exit {completed.returncode}"
        )
    try:
        _require_owned_artifact(manifest_path, artifact_root, "rendering-manifest.json")
        if supervisor_path.exists() or supervisor_path.is_symlink():
            raise benchmark.ConfigError(
                "rendering driver cannot pre-create render-supervisor.json"
            )
    except benchmark.ConfigError as error:
        raise _PostprocessingFailure(str(error)) from error
    manifest_digest = evidence.sha256_file(manifest_path)
    actual_argv_digest = evidence.sha256_bytes(evidence.canonical_json_bytes(command))
    receipt = {
        "schema_version": 1,
        "scene_id": request["binding"]["scene_id"],
        "scale": request["binding"]["scale"],
        "lane": request["binding"]["lane"],
        "request_sha256": request_digest,
        "candidate_checkout_commit": request["binding"]["git_commit"],
        "baseline_checkout_commit": request["binding"]["baseline_git_commit"],
        "renderer_closure_sha256": renderer_identity["sha256"],
        "renderer_executable_sha256": renderer_identity["executable_sha256"],
        "job_sha256": job_digest,
        "manifest_sha256": manifest_digest,
        "stdout_sha256": evidence.sha256_file(renderer_stdout),
        "stderr_sha256": evidence.sha256_file(renderer_stderr),
        "argv": redacted_command,
        "actual_argv_sha256": actual_argv_digest,
        "started_monotonic_seconds": started_monotonic,
        "ended_monotonic_seconds": ended_monotonic,
        "exit_code": completed.returncode,
        "timed_out": False,
    }
    supervisor_path.write_bytes(evidence.canonical_json_bytes(receipt) + b"\n")
    return receipt


def _run_lane_attempt(
    index_path: Path,
    requests_root: Path,
    corpus_path: Path,
    reference_config_path: Path,
    toolchain_root: Path,
    baseline_checkout_root: Path,
    baseline_toolchain_root: Path,
    output_root: Path,
    lane: str,
    runner_path: Path,
    renderer_closure_path: Path,
    *,
    completed_collections: MutableMapping[tuple[str, int, str], dict[str, Any]],
) -> dict[str, Any]:
    if lane not in evidence.RELEASE_LANES:
        raise benchmark.ConfigError("unsupported benchmark lane")
    runner = _require_runner(runner_path)
    index = benchmark._require_mapping(_load(index_path, "request index"), "request index")
    benchmark._require_exact_keys(
        index,
        {
            "schema_version",
            "producer_protocol",
            "producer_version",
            "producer_digest",
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "baseline_git_commit",
            "baseline_toolchain_identity",
            "baseline_configuration_digest",
            "baseline_run_configuration",
            "benchmark_contract_sha256",
            "corpus_manifest",
            "corpus_manifest_sha256",
            "reference_config",
            "reference_config_sha256",
            "runner_identities",
            "requests",
        },
        "request index",
    )
    corpus = _load(corpus_path, "corpus")
    config = _load(reference_config_path, "reference config")
    protected_file_digests = {
        "request index": evidence.sha256_file(index_path),
        "corpus": evidence.sha256_file(corpus_path),
        "reference config": evidence.sha256_file(reference_config_path),
    }
    benchmark.validate_corpus(corpus, expected_profile="release")
    benchmark.validate_reference_config(config)
    if benchmark.sha256_json(corpus) != index["corpus_digest"]:
        raise benchmark.ConfigError("lane corpus does not match the prepared request index")
    if benchmark.sha256_json(config) != index["thresholds_digest"]:
        raise benchmark.ConfigError("lane thresholds do not match the prepared request index")
    candidate_checkout = _verify_candidate_checkout(index["git_commit"])
    git = benchmark.collect_git_state()
    toolchain_identity = benchmark.resolved_toolchain_identity(toolchain_root, "release")
    if toolchain_identity != index["toolchain_identity"]:
        raise benchmark.ConfigError("lane toolchain does not match the prepared request index")
    baseline_checkout = _verify_baseline_checkout(
        baseline_checkout_root,
        index["baseline_git_commit"],
    )
    baseline_toolchain, baseline_toolchain_identity = _verify_baseline_toolchain(
        baseline_toolchain_root,
        index["baseline_toolchain_identity"],
    )
    identity = benchmark.RunIdentity(
        profile="release",
        corpus_digest=benchmark.sha256_json(corpus),
        thresholds_digest=benchmark.sha256_json(config),
        git_commit=git["commit"],
        app_version=benchmark.APP_VERSION,
        toolchain_identity=toolchain_identity,
    )
    index = benchmark.validate_request_index(index, identity, corpus, config)
    approved_runner = index["runner_identities"][lane]
    renderer_identity = index["runner_identities"][evidence.RENDERING_DRIVER_IDENTITY]
    _verify_runner_digest(runner, approved_runner, "before the first scene")
    _verify_renderer_closure(
        renderer_closure_path,
        renderer_identity,
        "before the first scene",
    )

    machine = evidence.collect_machine_metadata()
    evidence.validate_machine_lane(machine, lane)
    requests = index["requests"]
    if not isinstance(requests, list):
        raise benchmark.ConfigError("request index requests must be an array")
    selected = _selected_lane_entries(requests, lane)
    if not selected:
        raise benchmark.ConfigError(f"request index contains no {lane} work")

    results = []
    for raw_entry in selected:
        _verify_candidate_checkout(index["git_commit"])
        for label, digest in protected_file_digests.items():
            _verify_file_digest(
                {"request index": index_path, "corpus": corpus_path, "reference config": reference_config_path}[label],
                digest,
                label,
            )
        _verify_runner_digest(runner, approved_runner, "before subprocess launch")
        _verify_renderer_closure(
            renderer_closure_path,
            renderer_identity,
            "before measurement launch",
        )
        entry = benchmark._require_mapping(raw_entry, "request index entry")
        request_path = requests_root / _relative(entry.get("request"), "request path")
        request = _load(request_path, "evidence request")
        evidence.validate_request(request)
        scene_id = benchmark._require_safe_token(entry.get("scene_id"), "request scene_id")
        scale = entry.get("scale")
        if (
            type(scale) is not int
            or request["binding"]["scene_id"] != scene_id
            or request["binding"]["scale"] != scale
            or request["binding"]["lane"] != lane
        ):
            raise benchmark.ConfigError("request index entry does not match its request")
        scene = next((item for item in corpus["scenes"] if item["id"] == scene_id), None)
        if scene is None:
            raise benchmark.ConfigError("request scene is absent from the corpus")
        expected_request = benchmark._evidence_request(
            scene,
            scale,
            lane,
            identity,
            request["binding"]["input_digest"],
            index["runner_identities"][evidence.RENDERING_DRIVER_IDENTITY],
            index["benchmark_contract_sha256"],
        )
        if request != expected_request:
            raise benchmark.ConfigError("request policy does not match the prepared corpus and lane")
        request_digest = evidence.sha256_file(request_path)
        for field in (
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "baseline_git_commit",
            "baseline_toolchain_identity",
            "baseline_configuration_digest",
            "benchmark_contract_sha256",
        ):
            if request["binding"][field] != index[field]:
                raise benchmark.ConfigError(f"request {field} does not match its approved index")
        if request["baseline_run_configuration"] != index["baseline_run_configuration"]:
            raise benchmark.ConfigError("request baseline run configuration does not match its approved index")
        media_relative = _relative(entry.get("media_path"), "request media path")
        media = corpus_path.parent / media_relative
        expected_input_digest = request["binding"]["input_digest"]
        if benchmark.digest_input(
            media,
            trusted_root=corpus_path.parent,
        ) != expected_input_digest:
            raise benchmark.ConfigError(f"{scene_id} input does not match the prepared request")

        evidence_relative = _relative(entry.get("evidence_path"), "request evidence path")
        key = (scene_id, scale, lane)
        expected_status_relative = (
            evidence_relative / str(scale) / lane / "collector-status.json"
        )
        if key in completed_collections:
            results.append(
                _validate_completed_collection(
                    completed_collections[key],
                    output_root=output_root,
                    expected_relative=expected_status_relative,
                    scene_id=scene_id,
                    scale=scale,
                    lane=lane,
                    request=request,
                    runner_identity=approved_runner,
                    machine=machine,
                )
            )
            continue
        artifact_root = output_root / evidence_relative / str(scale) / lane
        if artifact_root.exists() or artifact_root.is_symlink():
            collection = _collection_from_status(
                output_root=output_root,
                status_path=output_root / expected_status_relative,
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
                expected_relative=expected_status_relative,
            )
            completed_collections[key] = collection
            results.append(collection)
            continue
        artifact_root = _prepare_artifact_root(output_root, evidence_relative, scale, lane)
        command_log = artifact_root / "command.jsonl"
        supervisor_log = artifact_root / "supervisor-command.jsonl"
        stdout_log = artifact_root / "stdout.log"
        stderr_log = artifact_root / "stderr.log"
        timeout_seconds = _measurement_timeout_seconds(
            scale,
            os.environ.get(_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY),
        )
        redacted_command = [
            "protected-measurement-runner",
            f"scene://{scene_id}",
            f"scale://{scale}",
            f"lane://{lane}",
            f"input://{expected_input_digest}",
            f"candidate://{index['git_commit']}",
            f"baseline://{index['baseline_git_commit']}",
            f"toolchain://{index['toolchain_identity']}",
            f"runner://{approved_runner['sha256']}",
            "--request",
            f"requests://{entry['request']}",
            "--input",
            f"corpus://{entry['media_path']}",
            "--toolchain-root",
            "toolchain://resolved",
            "--candidate-checkout-root",
            f"candidate://{index['git_commit']}",
            "--baseline-checkout-root",
            f"baseline://{index['baseline_git_commit']}",
            "--baseline-toolchain-root",
            "baseline-toolchain://resolved",
            "--reference-config",
            "config://reference",
            "--artifact-root",
            "evidence://run",
            "--lane",
            lane,
        ]
        command = [
            str(runner),
            "--request",
            str(request_path),
            "--input",
            str(media),
            "--toolchain-root",
            str(toolchain_root),
            "--candidate-checkout-root",
            str(candidate_checkout),
            "--baseline-checkout-root",
            str(baseline_checkout),
            "--baseline-toolchain-root",
            str(baseline_toolchain),
            "--reference-config",
            str(reference_config_path),
            "--artifact-root",
            str(artifact_root),
            "--lane",
            lane,
        ]
        started = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        supervisor_log.write_bytes(
            evidence.canonical_json_bytes({"event": "started", "at": started, "argv": redacted_command})
            + b"\n"
        )
        try:
            _verify_runner_digest(
                runner,
                approved_runner,
                "immediately before subprocess launch",
            )
        except Exception as error:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="integrity_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement integrity verification failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from error
        completed: subprocess.CompletedProcess[bytes] | None = None
        launch_error: OSError | None = None
        process_error: benchmark.ConfigError | None = None
        monitor_error: Exception | None = None
        integrity_error: Exception | None = None
        timed_out = False
        runner_environment = _measurement_environment(artifact_root)
        try:
            child_cpu_start = _children_cpu_seconds()
        except Exception as error:
            _raise_infrastructure_blocked(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                reason="host_monitor_failed",
                exit_code=None,
                cause=error,
            )
        try:
            verified_renderer = _verify_renderer_closure(
                renderer_closure_path,
                renderer_identity,
                "immediately before host monitoring",
            )
        except Exception as error:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="integrity_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement integrity verification failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from error
        try:
            host_monitor = _start_host_monitor(
                verified_renderer.executable,
                runner_environment,
                timeout_seconds,
            )
        except Exception as error:
            _raise_infrastructure_blocked(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                reason="host_monitor_failed",
                exit_code=None,
                cause=error,
            )
        started_monotonic = time.monotonic()
        host_monitor_report: dict[str, Any] | None = None
        child_cpu_end: dict[str, float] | None = None
        try:
            with stdout_log.open("wb") as stdout_handle, stderr_log.open("wb") as stderr_handle:
                completed, timed_out = _run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    runner_environment,
                    timeout_seconds,
                )
        except OSError as error:
            launch_error = error
        except benchmark.ConfigError as error:
            process_error = error
        finally:
            ended_monotonic = time.monotonic()
            try:
                child_cpu_end = _children_cpu_seconds()
            except Exception as error:
                monitor_error = error
            try:
                host_monitor_report = _finish_host_monitor(host_monitor)
            except Exception as error:
                monitor_error = monitor_error or error
            try:
                _verify_runner_digest(runner, approved_runner, "after subprocess completion")
                _verify_candidate_checkout(index["git_commit"])
                for label, digest in protected_file_digests.items():
                    _verify_file_digest(
                        {"request index": index_path, "corpus": corpus_path, "reference config": reference_config_path}[label],
                        digest,
                        label,
                    )
                _verify_file_digest(request_path, request_digest, "evidence request")
                _verify_renderer_closure(
                    renderer_closure_path,
                    renderer_identity,
                    "after measurement completion",
                )
            except Exception as error:
                integrity_error = error
        if integrity_error is not None:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="integrity_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement integrity verification failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from integrity_error
        if process_error is not None:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="process_isolation_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement process isolation failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from process_error
        if completed is None:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="launch_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement runner could not start for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from launch_error
        ended = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with supervisor_log.open("ab") as handle:
            handle.write(
                evidence.canonical_json_bytes(
                    {"event": "finished", "at": ended, "exit_code": completed.returncode}
                )
                + b"\n"
            )
        if timed_out:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="timed_out",
                exit_code=completed.returncode,
            )
            raise _CollectedOutcome(
                f"{lane} measurement runner timed out for {scene_id}@{scale} "
                f"after {timeout_seconds:g} seconds",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            )
        if completed.returncode != 0:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="nonzero_exit",
                exit_code=completed.returncode,
            )
            raise _CollectedOutcome(
                f"{lane} measurement runner failed for {scene_id}@{scale} with exit {completed.returncode}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            )
        if monitor_error is not None or host_monitor_report is None or child_cpu_end is None:
            _raise_infrastructure_blocked(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                reason="host_monitor_failed",
                exit_code=0,
                cause=monitor_error
                or benchmark.ConfigError("measurement environment receipt is incomplete"),
            )
        host_monitor_path = artifact_root / "host-monitor.json"
        _write_exclusive_json(host_monitor_path, host_monitor_report, "host-monitor.json")
        host_monitor_digest = evidence.sha256_file(host_monitor_path)
        outer_child_cpu_microseconds = {
            field: max(0, round((child_cpu_end[field] - child_cpu_start[field]) * 1_000_000))
            for field in ("user", "system")
        }

        observations_path = artifact_root / "observations.json"
        try:
            observations = evidence._load_bounded_json(
                observations_path,
                "raw observations",
                maximum_bytes=evidence.MAX_OBSERVATIONS_BYTES,
            )
            if not isinstance(observations, Mapping):
                raise benchmark.ConfigError(
                    "measurement runner observations must be an object"
                )
            raw_receipts = observations.get("commands")
            if (
                not isinstance(raw_receipts, list)
                or not raw_receipts
                or any(not isinstance(receipt, Mapping) for receipt in raw_receipts)
            ):
                raise benchmark.ConfigError(
                    "measurement runner did not emit execution receipts"
                )
            raw_artifacts = observations.get("artifacts")
            if not isinstance(raw_artifacts, dict):
                raise benchmark.ConfigError(
                    "measurement runner artifacts must be an object"
                )
            environment_commands = []
            logical_cpus = machine.get("logical_cpus")
            if type(logical_cpus) is not int or logical_cpus <= 0:
                raise benchmark.ConfigError("measurement machine CPU count is unavailable")
            declared_process_cpu = 0
            for receipt in raw_receipts:
                run_id = receipt.get("run_id")
                receipt_started = receipt.get("started_monotonic_seconds")
                receipt_ended = receipt.get("ended_monotonic_seconds")
                process_cpu = receipt.get("process_cpu_microseconds")
                if (
                    not isinstance(run_id, str)
                    or not run_id
                    or isinstance(receipt_started, bool)
                    or isinstance(receipt_ended, bool)
                    or not isinstance(receipt_started, (int, float))
                    or not isinstance(receipt_ended, (int, float))
                    or not math.isfinite(receipt_started)
                    or not math.isfinite(receipt_ended)
                    or receipt_ended <= receipt_started
                    or receipt_started
                    < started_monotonic - _HOST_MONITOR_TIMESTAMP_TOLERANCE_SECONDS
                    or receipt_ended
                    > ended_monotonic + _HOST_MONITOR_TIMESTAMP_TOLERANCE_SECONDS
                    or not isinstance(process_cpu, Mapping)
                    or set(process_cpu) != {"user", "system"}
                    or any(
                        type(process_cpu[field]) is not int
                        or not 0 <= process_cpu[field] < 1 << 64
                        for field in ("user", "system")
                    )
                ):
                    raise benchmark.ConfigError(
                        "measurement runner emitted an invalid execution receipt"
                    )
                process_cpu_total = process_cpu["user"] + process_cpu["system"]
                if process_cpu_total > (
                    (receipt_ended - receipt_started)
                    * logical_cpus
                    * 1_000_000
                    * 1.05
                ):
                    raise benchmark.ConfigError(
                        "measurement runner execution receipt exceeds its wall-time CPU bound"
                    )
                declared_process_cpu += process_cpu_total
                environment_commands.append(
                    {
                        "run_id": run_id,
                        "started_monotonic_seconds": receipt_started,
                        "ended_monotonic_seconds": receipt_ended,
                        "process_cpu_microseconds": dict(process_cpu),
                    }
                )
            outer_child_cpu = sum(outer_child_cpu_microseconds.values())
            if declared_process_cpu > outer_child_cpu + max(
                100_000,
                math.ceil(outer_child_cpu * 0.01),
            ):
                raise benchmark.ConfigError(
                    "measurement runner execution receipts exceed outer child CPU"
                )
        except (benchmark.ConfigError, OSError, UnicodeError, ValueError) as error:
            _raise_invalid_runner_output(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                cause=error,
            )
        try:
            measurement_environment = _summarize_host_monitor(
                host_monitor_report,
                raw_receipts,
                machine,
                supervisor_started=started_monotonic,
                supervisor_ended=ended_monotonic,
                monitor_sha256=host_monitor_digest,
                monitor_executable_sha256=renderer_identity["executable_sha256"],
                outer_child_cpu_microseconds=outer_child_cpu_microseconds,
            )
            environment_rejections = evidence.measurement_environment_rejections(
                measurement_environment,
                machine,
                environment_commands,
                started_monotonic,
                ended_monotonic,
                artifact_root / "measurement-environment.json",
                renderer_identity["executable_sha256"],
            )
        except (benchmark.ConfigError, evidence.EvidenceError) as error:
            _raise_infrastructure_blocked(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                reason="host_monitor_failed",
                exit_code=0,
                cause=error,
            )

        oriented = _orientation_required(request, lane)
        rendered = _rendering_required(request, lane)
        try:
            if oriented:
                _execute_orientation_stage(
                    artifact_root=artifact_root,
                    request=request,
                    request_path=request_path,
                    request_digest=request_digest,
                    renderer_closure_path=renderer_closure_path,
                    renderer_identity=renderer_identity,
                    observations=observations,
                    commands=raw_receipts,
                    timeout_seconds=timeout_seconds,
                )
                try:
                    _verify_candidate_checkout(index["git_commit"])
                except Exception as error:
                    raise _IntegrityFailure(
                        "candidate checkout changed during orientation extraction"
                    ) from error

            if rendered:
                _execute_rendering_stage(
                    artifact_root=artifact_root,
                    request=request,
                    request_path=request_path,
                    request_digest=request_digest,
                    renderer_closure_path=renderer_closure_path,
                    renderer_identity=renderer_identity,
                    candidate_checkout=candidate_checkout,
                    baseline_checkout=baseline_checkout,
                    commands=raw_receipts,
                    timeout_seconds=timeout_seconds,
                )
                try:
                    _verify_candidate_checkout(index["git_commit"])
                except Exception as error:
                    raise _IntegrityFailure(
                        "candidate checkout changed during rendering"
                    ) from error
        except _IntegrityFailure as error:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="integrity_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement integrity verification failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from error
        except _PostprocessingFailure as error:
            _raise_infrastructure_blocked(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                reason="postprocessing_failed",
                exit_code=0,
                cause=error,
            )
        except (benchmark.ConfigError, evidence.EvidenceError) as error:
            _raise_invalid_runner_output(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                cause=error,
            )

        command_log.write_bytes(
            b"".join(evidence.canonical_json_bytes(receipt) + b"\n" for receipt in raw_receipts)
        )
        raw_artifacts["supervisor_run"] = "supervisor-run.json"
        raw_artifacts["host_monitor"] = "host-monitor.json"
        if oriented:
            raw_artifacts.update(
                {
                    "orientation_metrics": "orientation-metrics.json",
                    "orientation_supervisor": "orientation-supervisor.json",
                }
            )
        if rendered:
            raw_artifacts.update(
                {
                    "render_job": "render-job.json",
                    "rendering_manifest": "rendering-manifest.json",
                    "render_supervisor": "render-supervisor.json",
                    "renderer_stdout_log": "renderer-stdout.log",
                    "renderer_stderr_log": "renderer-stderr.log",
                }
            )
        supervisor_run = {
            "schema_version": 3,
            "scene_id": scene_id,
            "scale": scale,
            "lane": lane,
            "input_digest": expected_input_digest,
            "candidate_git_commit": index["git_commit"],
            "baseline_git_commit": index["baseline_git_commit"],
            "toolchain_identity": index["toolchain_identity"],
            "baseline_toolchain_identity": index["baseline_toolchain_identity"],
            "runner_sha256": approved_runner["sha256"],
            "argv": redacted_command,
            "started_monotonic_seconds": started_monotonic,
            "ended_monotonic_seconds": ended_monotonic,
            "exit_code": completed.returncode,
            "measurement_environment": measurement_environment,
        }
        _write_exclusive_json(
            artifact_root / "supervisor-run.json",
            supervisor_run,
            "supervisor-run.json",
        )
        observations_path.write_bytes(evidence.canonical_json_bytes(observations) + b"\n")
        for path, label in (
            (artifact_root / "attestation.json", "attestation.json"),
            (artifact_root / "lane-outcome.json", "lane-outcome.json"),
            (artifact_root / "collector-status.json", "collector-status.json"),
        ):
            if path.exists() or path.is_symlink():
                raise benchmark.ConfigError(
                    f"measurement runner cannot pre-create supervisor-owned {label}"
                )

        def verify_publication_integrity(phase: str) -> None:
            _verify_runner_digest(runner, approved_runner, phase)
            _verify_renderer_closure(renderer_closure_path, renderer_identity, phase)
            _verify_candidate_checkout(index["git_commit"])
            for label, digest in protected_file_digests.items():
                _verify_file_digest(
                    {
                        "request index": index_path,
                        "corpus": corpus_path,
                        "reference config": reference_config_path,
                    }[label],
                    digest,
                    label,
                )
            _verify_file_digest(request_path, request_digest, "evidence request")
            if benchmark.digest_input(
                media,
                trusted_root=corpus_path.parent,
            ) != expected_input_digest:
                raise benchmark.ConfigError(
                    f"{scene_id} input changed during measurement"
                )
            if (
                benchmark.resolved_toolchain_identity(toolchain_root, "release")
                != toolchain_identity
            ):
                raise benchmark.ConfigError("toolchain changed during lane measurement")
            _verify_baseline_checkout(
                baseline_checkout,
                index["baseline_git_commit"],
            )
            _, current_baseline_toolchain_identity = _verify_baseline_toolchain(
                baseline_toolchain,
                baseline_toolchain_identity,
            )
            if current_baseline_toolchain_identity != baseline_toolchain_identity:
                raise benchmark.ConfigError(
                    "baseline toolchain changed during lane measurement"
                )

        try:
            verify_publication_integrity("before attestation validation")
        except Exception as error:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="integrity_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement integrity verification failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from error

        try:
            evidence.validate_attestation_candidate(
                request,
                observations,
                artifact_root,
                artifact_root / "attestation.json",
                lane,
                approved_runner,
                machine=machine,
            )
        except evidence.EvidenceError as error:
            _raise_invalid_runner_output(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                scene_id=scene_id,
                scale=scale,
                cause=error,
            )

        try:
            verify_publication_integrity("immediately before evidence publication")
        except Exception as error:
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="execution_failed",
                reason="integrity_failed",
                exit_code=None,
            )
            raise _CollectedOutcome(
                f"{lane} measurement integrity verification failed for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            ) from error

        if environment_rejections:
            environment_receipt_path = artifact_root / "measurement-environment.json"
            _write_exclusive_json(
                environment_receipt_path,
                {
                    "schema_version": 1,
                    "started_monotonic_seconds": started_monotonic,
                    "ended_monotonic_seconds": ended_monotonic,
                    "commands": environment_commands,
                    "measurement_environment": measurement_environment,
                },
                "measurement-environment.json",
            )
            status_path = _write_collector_outcome(
                artifact_root=artifact_root,
                request=request,
                lane=lane,
                runner_identity=approved_runner,
                machine=machine,
                kind="environment_rejected",
                reason="policy_violation",
                exit_code=0,
            )
            raise _CollectedOutcome(
                f"{lane} measurement environment was rejected for {scene_id}@{scale}",
                scene_id=scene_id,
                scale=scale,
                lane=lane,
                status_path=status_path,
                request=request,
                runner_identity=approved_runner,
                machine=machine,
            )

        status_path = _write_collector_status(
            artifact_root=artifact_root,
            request=request,
            lane=lane,
            runner_identity=approved_runner,
            machine=machine,
            disposition="attestation_candidate",
            outcome=None,
        )
        collection = _collection_from_status(
            output_root=output_root,
            status_path=status_path,
            scene_id=scene_id,
            scale=scale,
            lane=lane,
            request=request,
            runner_identity=approved_runner,
            machine=machine,
            expected_relative=expected_status_relative,
        )
        if key in completed_collections:
            raise benchmark.ConfigError("lane request was collected more than once")
        completed_collections[key] = collection
        results.append(collection)

    lane_result = {
        "schema_version": 1,
        "lane": lane,
        "machine": machine,
        "git_commit": index["git_commit"],
        "corpus_digest": index["corpus_digest"],
        "thresholds_digest": index["thresholds_digest"],
        "toolchain_identity": index["toolchain_identity"],
        "producer_digest": index["producer_digest"],
        "runner_identity": approved_runner,
        "rendering_driver_identity": renderer_identity,
        "collections": results,
    }
    return lane_result


def run_lane(
    index_path: Path,
    requests_root: Path,
    corpus_path: Path,
    reference_config_path: Path,
    toolchain_root: Path,
    baseline_checkout_root: Path,
    baseline_toolchain_root: Path,
    output_root: Path,
    lane: str,
    runner_path: Path,
    renderer_closure_path: Path,
) -> dict[str, Any]:
    collection_started_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    lane_path = output_root / f"lane-{lane}.json"
    if lane_path.exists() or lane_path.is_symlink():
        raise benchmark.ConfigError("benchmark lane result already exists; refusing untrusted output")
    completed: dict[tuple[str, int, str], dict[str, Any]] = {}
    while True:
        try:
            result = _run_lane_attempt(
                index_path,
                requests_root,
                corpus_path,
                reference_config_path,
                toolchain_root,
                baseline_checkout_root,
                baseline_toolchain_root,
                output_root,
                lane,
                runner_path,
                renderer_closure_path,
                completed_collections=completed,
            )
        except _CollectedOutcome as outcome:
            key = (outcome.scene_id, outcome.scale, outcome.lane)
            if outcome.lane != lane or key in completed:
                raise benchmark.ConfigError(
                    "collector produced a duplicate or wrong-lane terminal outcome"
                ) from outcome
            collection = _collection_from_status(
                output_root=output_root,
                status_path=outcome.status_path,
                scene_id=outcome.scene_id,
                scale=outcome.scale,
                lane=outcome.lane,
                request=outcome.request,
                runner_identity=outcome.runner_identity,
                machine=outcome.machine,
            )
            completed[key] = collection
            continue

        collections = result.get("collections")
        if not isinstance(collections, list):
            raise benchmark.ConfigError("completed lane result has no collection list")
        actual: dict[tuple[str, int, str], Mapping[str, Any]] = {}
        for raw_collection in collections:
            collection = benchmark._require_mapping(raw_collection, "lane collection")
            key = (
                collection.get("scene_id"),
                collection.get("scale"),
                collection.get("lane"),
            )
            if (
                not isinstance(key[0], str)
                or type(key[1]) is not int
                or key[2] != lane
                or key in actual
            ):
                raise benchmark.ConfigError("lane collections are duplicated or malformed")
            actual[key] = collection
        if set(actual) != set(completed) or any(
            actual.get(key) != descriptor for key, descriptor in completed.items()
        ):
            raise benchmark.ConfigError(
                "completed lane result does not contain the exact durable collection closure"
            )
        completed_result = {
            **result,
            "collection_started_at_utc": collection_started_at,
            "collection_ended_at_utc": datetime.now(timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
        }
        _write_exclusive_json(lane_path, completed_result, lane_path.name)
        return completed_result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--requests-root", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--reference-config", type=Path, required=True)
    parser.add_argument("--toolchain-root", type=Path, required=True)
    parser.add_argument("--baseline-checkout-root", type=Path, required=True)
    parser.add_argument("--baseline-toolchain-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lane", choices=sorted(evidence.RELEASE_LANES), required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--rendering-driver-closure", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = run_lane(
            args.index,
            args.requests_root,
            args.corpus,
            args.reference_config,
            args.toolchain_root,
            args.baseline_checkout_root,
            args.baseline_toolchain_root,
            args.output,
            args.lane,
            args.runner,
            args.rendering_driver_closure,
        )
        print(
            evidence.canonical_json_bytes(
                {"status": "collected", "count": len(result["collections"])}
            ).decode()
        )
        return 0
    except (benchmark.ConfigError, evidence.EvidenceError) as error:
        print(f"benchmark lane error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
