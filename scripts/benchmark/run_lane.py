#!/usr/bin/env python3
"""Run one protected benchmark lane and seal its raw evidence."""

from __future__ import annotations

import argparse
import ctypes
import math
import os
import secrets
import signal
import shutil
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Mapping, Sequence

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
_MAXIMUM_TIMEOUT_OVERRIDE_SECONDS = 7 * 24 * 60 * 60
_PROCESS_GROUP_TERMINATION_GRACE_SECONDS = 5.0
_PROCESS_GROUP_DRAIN_SECONDS = 0.25
_PROCESS_TREE_SCAN_SECONDS = 0.01
_PROCESS_TOKEN_ENVIRONMENT_KEY = "EASYSPLAT_INTERNAL_BENCHMARK_PROCESS_TOKEN"


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
    if artifact_root.exists():
        if artifact_root.is_symlink() or not artifact_root.is_dir():
            raise benchmark.ConfigError("benchmark artifact root must be a real directory")
        shutil.rmtree(artifact_root)
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
            raise benchmark.ConfigError("render job views are not in signed holdout order")
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

    verified = _verify_renderer_closure(
        renderer_closure_path,
        renderer_identity,
        "immediately before rendering",
    )
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
        _verify_renderer_closure(
            renderer_closure_path,
            renderer_identity,
            "after rendering",
        )
        _verify_file_digest(job_path, job_digest, "render job")
        _verify_file_digest(request_path, request_digest, "evidence request")
    if completed is None:
        detail = launch_error.strerror if launch_error is not None else "unknown launch failure"
        raise benchmark.ConfigError(f"rendering driver could not start: {detail}")
    if timed_out:
        raise benchmark.ConfigError(
            f"rendering driver timed out after {timeout_seconds:g} seconds"
        )
    if completed.returncode != 0:
        raise benchmark.ConfigError(
            f"rendering driver failed with exit {completed.returncode}"
        )
    _require_owned_artifact(manifest_path, artifact_root, "rendering-manifest.json")
    if supervisor_path.exists() or supervisor_path.is_symlink():
        raise benchmark.ConfigError("rendering driver cannot pre-create render-supervisor.json")
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
    evidence_key_path: Path,
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
    index = benchmark.validate_request_index(index, identity, corpus)
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
    key = evidence.load_key(evidence_key_path)
    requests = index["requests"]
    if not isinstance(requests, list):
        raise benchmark.ConfigError("request index requests must be an array")
    selected = [entry for entry in requests if isinstance(entry, Mapping) and entry.get("lane") == lane]
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
        _verify_runner_digest(runner, approved_runner, "immediately before subprocess launch")
        completed: subprocess.CompletedProcess[bytes] | None = None
        launch_error: OSError | None = None
        timed_out = False
        started_monotonic = time.monotonic()
        try:
            with stdout_log.open("wb") as stdout_handle, stderr_log.open("wb") as stderr_handle:
                completed, timed_out = _run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    _measurement_environment(artifact_root),
                    timeout_seconds,
                )
        except OSError as error:
            launch_error = error
        finally:
            ended_monotonic = time.monotonic()
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
        if completed is None:
            detail = launch_error.strerror if launch_error is not None else "unknown launch failure"
            raise benchmark.ConfigError(
                f"{lane} measurement runner could not start for {scene_id}@{scale}: {detail}"
            )
        ended = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with supervisor_log.open("ab") as handle:
            handle.write(
                evidence.canonical_json_bytes(
                    {"event": "finished", "at": ended, "exit_code": completed.returncode}
                )
                + b"\n"
            )
        if timed_out:
            raise benchmark.ConfigError(
                f"{lane} measurement runner timed out for {scene_id}@{scale} "
                f"after {timeout_seconds:g} seconds"
            )
        if completed.returncode != 0:
            raise benchmark.ConfigError(
                f"{lane} measurement runner failed for {scene_id}@{scale} with exit {completed.returncode}"
            )

        observations_path = artifact_root / "observations.json"
        observations = _load(observations_path, "raw observations")
        if not isinstance(observations, Mapping):
            raise benchmark.ConfigError("measurement runner observations must be an object")
        raw_receipts = observations.get("commands")
        if not isinstance(raw_receipts, list) or any(
            not isinstance(receipt, Mapping) for receipt in raw_receipts
        ):
            raise benchmark.ConfigError("measurement runner did not emit execution receipts")

        rendered = _rendering_required(request, lane)
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

        command_log.write_bytes(
            b"".join(evidence.canonical_json_bytes(receipt) + b"\n" for receipt in raw_receipts)
        )
        raw_artifacts = observations.get("artifacts")
        if not isinstance(raw_artifacts, dict):
            raise benchmark.ConfigError("measurement runner artifacts must be an object")
        raw_artifacts["supervisor_run"] = "supervisor-run.json"
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
            "schema_version": 1,
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
        }
        (artifact_root / "supervisor-run.json").write_bytes(
            evidence.canonical_json_bytes(supervisor_run) + b"\n"
        )
        observations_path.write_bytes(evidence.canonical_json_bytes(observations) + b"\n")
        attestation = evidence.produce_attestation(
            request,
            observations,
            artifact_root,
            artifact_root / "attestation.json",
            key,
            lane,
            approved_runner,
            machine=machine,
        )
        attestation_path = artifact_root / "attestation.json"
        benchmark.atomic_write_json(attestation_path, attestation)
        if benchmark.digest_input(
            media,
            trusted_root=corpus_path.parent,
        ) != expected_input_digest:
            raise benchmark.ConfigError(f"{scene_id} input changed during measurement")
        results.append(
            {
                "scene_id": scene_id,
                "scale": scale,
                "lane": lane,
                "attestation": (evidence_relative / str(scale) / lane / "attestation.json").as_posix(),
                "sha256": evidence.sha256_file(attestation_path),
            }
        )

    _verify_runner_digest(runner, approved_runner, "at lane completion")
    _verify_renderer_closure(
        renderer_closure_path,
        renderer_identity,
        "at lane completion",
    )
    _verify_candidate_checkout(index["git_commit"])
    for label, digest in protected_file_digests.items():
        _verify_file_digest(
            {"request index": index_path, "corpus": corpus_path, "reference config": reference_config_path}[label],
            digest,
            label,
        )
    if benchmark.resolved_toolchain_identity(toolchain_root, "release") != toolchain_identity:
        raise benchmark.ConfigError("toolchain changed during lane measurement")
    _verify_baseline_checkout(baseline_checkout, index["baseline_git_commit"])
    _, final_baseline_toolchain_identity = _verify_baseline_toolchain(
        baseline_toolchain,
        baseline_toolchain_identity,
    )
    if final_baseline_toolchain_identity != baseline_toolchain_identity:
        raise benchmark.ConfigError("baseline toolchain changed during lane measurement")
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
        "attestations": results,
    }
    benchmark.atomic_write_json(output_root / f"lane-{lane}.json", lane_result)
    return lane_result


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
    parser.add_argument("--evidence-key-file", type=Path, required=True)
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
            args.evidence_key_file,
        )
        print(evidence.canonical_json_bytes({"status": "attested", "count": len(result["attestations"])}).decode())
        return 0
    except (benchmark.ConfigError, evidence.EvidenceError) as error:
        print(f"benchmark lane error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
