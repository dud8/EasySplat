#!/usr/bin/env bash

easysplat_validate_release_verification_token() {
  local token="${1:-}"
  [[ "$token" =~ ^easysplat-release-verify-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

_easysplat_sandbox_marker_process_action() {
  local action="${1:-}"
  local token="${2:-}"
  local signal_name="${3:-}"
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to inspect sandboxed processes for an invalid release-verification token." >&2
    return 2
  fi
  case "$action" in
    list|drain|audit) ;;
    *) return 2 ;;
  esac
  [ -z "$signal_name" ] || return 2
  /usr/bin/python3 -I - "$action" "$$" "$signal_name" \
    3<<<"$token" <<'PY'
import ctypes
from collections import deque
import errno
import os
import signal
import struct
import sys
import time

action, shell_pid, signal_name = sys.argv[1:]
token_payload = os.read(3, 129)
if len(token_payload) >= 129 or os.read(3, 1):
    raise SystemExit("Release-process audit token exceeded its size bound.")
os.close(3)
if token_payload.count(b"\n") != 1 or not token_payload.endswith(b"\n"):
    raise SystemExit("Release-process audit token framing is invalid.")
try:
    token = token_payload[:-1].decode("ascii")
except UnicodeDecodeError as error:
    raise SystemExit("Release-process audit token is not ASCII.") from error
suffix = token.removeprefix("easysplat-release-verify-")
deny_marker = f"com.easysplat.releaseverify.{suffix}.deny".encode()
allow_marker = f"com.easysplat.releaseverify.{suffix}.allow".encode()
expected_assignment = f"EASYSPLAT_RELEASE_VERIFY_TOKEN={token}".encode()
excluded = {int(shell_pid), os.getpid()}

PROC_PIDTBSDINFO = 3
SZOMB = 5
SSTOP = 4
TASK_AUDIT_TOKEN = 15
TASK_AUDIT_TOKEN_COUNT = 8
CTL_KERN = 1
KERN_PROCARGS2 = 49

class AuditToken(ctypes.Structure):
    _fields_ = [("val", ctypes.c_uint32 * TASK_AUDIT_TOKEN_COUNT)]

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
proc_pidinfo = libproc.proc_pidinfo
proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
proc_pidinfo.restype = ctypes.c_int
proc_listallpids = libproc.proc_listallpids
proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
proc_listallpids.restype = ctypes.c_int
proc_signal_with_audittoken = libproc.proc_signal_with_audittoken
proc_signal_with_audittoken.argtypes = [ctypes.POINTER(AuditToken), ctypes.c_int]
proc_signal_with_audittoken.restype = ctypes.c_int

libsystem = ctypes.CDLL(None, use_errno=True)
sysctl = libsystem.sysctl
sysctl.argtypes = [
    ctypes.POINTER(ctypes.c_int),
    ctypes.c_uint,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_size_t),
    ctypes.c_void_p,
    ctypes.c_size_t,
]
sysctl.restype = ctypes.c_int
mach_task_self = ctypes.c_uint32.in_dll(libsystem, "mach_task_self_").value
task_name_for_pid = libsystem.task_name_for_pid
task_name_for_pid.argtypes = [
    ctypes.c_uint32,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_uint32),
]
task_name_for_pid.restype = ctypes.c_int
task_info = libsystem.task_info
task_info.argtypes = [
    ctypes.c_uint32,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_uint32),
]
task_info.restype = ctypes.c_int
mach_port_deallocate = libsystem.mach_port_deallocate
mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
mach_port_deallocate.restype = ctypes.c_int

sandbox = ctypes.CDLL(
    "/usr/lib/system/libsystem_sandbox.dylib",
    use_errno=True,
)
sandbox_check_by_audit_token = sandbox.sandbox_check_by_audit_token
# sandbox_check_by_audit_token is variadic. Declaring only its three fixed
# parameters is required on arm64 so ctypes places the filter value correctly.
sandbox_check_by_audit_token.argtypes = [
    AuditToken,
    ctypes.c_char_p,
    ctypes.c_int,
]
sandbox_check_by_audit_token.restype = ctypes.c_int
sandbox_check = sandbox.sandbox_check
sandbox_check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
sandbox_check.restype = ctypes.c_int
no_report = ctypes.c_int.in_dll(sandbox, "SANDBOX_CHECK_NO_REPORT").value
filter_global_name = 2

def process_record(pid):
    info = ProcBSDInfo()
    size = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if size != ctypes.sizeof(info) or info.pbi_pid != pid:
        return None
    return (
        info.pbi_pid,
        info.pbi_uid,
        info.pbi_start_tvsec,
        info.pbi_start_tvusec,
        info.pbi_status,
    )

def process_identity(pid):
    record = process_record(pid)
    if record is None or record[1] != os.getuid():
        return None
    return (record[0], record[2], record[3])

def process_snapshot_records():
    # Darwin's PID ceiling is 99,999. A fixed buffer avoids a sizing race.
    storage = (ctypes.c_int * 100_000)()
    count = proc_listallpids(storage, ctypes.sizeof(storage))
    if count <= 0 or count >= len(storage):
        raise OSError("Could not capture a bounded process snapshot.")
    pids = sorted({pid for pid in storage[:count] if 2 <= pid <= 99_999})
    if os.getpid() not in pids or process_record(os.getpid()) is None:
        raise OSError("Process snapshot does not contain the sandbox-marker inspector.")
    records = []
    for pid in pids:
        record = process_record(pid)
        if record is not None and record[1] == os.getuid():
            records.append(record)
    return sorted(
        records,
        key=lambda record: (record[2], record[3], record[0]),
        reverse=True,
    )

def process_environment(pid, identity):
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    for _ in range(3):
        size = ctypes.c_size_t()
        ctypes.set_errno(0)
        if sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
            if process_identity(pid) != identity:
                return "gone", ()
            return "unavailable", ()
        if not 4 <= size.value <= 2 * 1024 * 1024:
            if process_identity(pid) != identity:
                return "gone", ()
            return "unavailable", ()
        storage = ctypes.create_string_buffer(size.value)
        ctypes.set_errno(0)
        if sysctl(mib, 3, storage, ctypes.byref(size), None, 0) == 0:
            break
        if process_identity(pid) != identity:
            return "gone", ()
        if ctypes.get_errno() != errno.ENOMEM:
            return "unavailable", ()
    else:
        if process_identity(pid) != identity:
            return "gone", ()
        return "unavailable", ()
    if process_identity(pid) != identity:
        return "gone", ()
    data = storage.raw[:size.value]
    if len(data) < 4:
        return "unavailable", ()
    argument_count = struct.unpack_from("=i", data)[0]
    if not 0 <= argument_count <= 131_072:
        return "unavailable", ()
    cursor = 4
    executable_end = data.find(b"\0", cursor)
    if executable_end < 0:
        return "unavailable", ()
    cursor = executable_end + 1
    while cursor < len(data) and data[cursor] == 0:
        cursor += 1
    for _ in range(argument_count):
        argument_end = data.find(b"\0", cursor)
        if argument_end < 0:
            return "unavailable", ()
        cursor = argument_end + 1
    while cursor < len(data) and data[cursor] == 0:
        cursor += 1
    environment = []
    while cursor < len(data):
        value_end = data.find(b"\0", cursor)
        if value_end < 0:
            return "unavailable", ()
        if value_end == cursor:
            break
        environment.append(data[cursor:value_end])
        cursor = value_end + 1
    if process_identity(pid) != identity:
        return "gone", ()
    return "readable", tuple(environment)

def process_audit_token(pid):
    task_name = ctypes.c_uint32()
    result = task_name_for_pid(mach_task_self, pid, ctypes.byref(task_name))
    if result != 0:
        raise OSError(result, f"task_name_for_pid failed for process {pid}")
    try:
        audit_token = AuditToken()
        count = ctypes.c_uint32(TASK_AUDIT_TOKEN_COUNT)
        result = task_info(
            task_name.value,
            TASK_AUDIT_TOKEN,
            ctypes.cast(ctypes.byref(audit_token), ctypes.POINTER(ctypes.c_int)),
            ctypes.byref(count),
        )
        if result != 0 or count.value != TASK_AUDIT_TOKEN_COUNT:
            raise OSError(result, f"TASK_AUDIT_TOKEN failed for process {pid}")
        if audit_token.val[5] != pid:
            raise OSError(f"Audit token did not identify process {pid}")
        return audit_token
    finally:
        deallocation_result = mach_port_deallocate(mach_task_self, task_name.value)
        if deallocation_result != 0:
            raise OSError(
                deallocation_result,
                f"Could not release the task-name port for process {pid}",
            )

def marker_decision(audit_token, marker):
    ctypes.set_errno(0)
    result = sandbox_check_by_audit_token(
        audit_token,
        b"mach-lookup",
        filter_global_name | no_report,
        ctypes.c_char_p(marker),
    )
    if result not in (0, 1):
        error = ctypes.get_errno()
        raise OSError(error, "sandbox_check_by_audit_token failed")
    return result

def sampled_marker_decision(pid, marker):
    ctypes.set_errno(0)
    result = sandbox_check(
        pid,
        b"mach-lookup",
        filter_global_name | no_report,
        ctypes.c_char_p(marker),
    )
    if result not in (0, 1):
        error = ctypes.get_errno()
        raise OSError(error, f"sandbox_check failed for process {pid}")
    return result

def sampled_process_is_marked(pid):
    return (
        sampled_marker_decision(pid, deny_marker) == 1
        and sampled_marker_decision(pid, allow_marker) == 0
    )

def is_marked(pid, identity):
    audit_token = process_audit_token(pid)
    denied = marker_decision(audit_token, deny_marker)
    allowed = marker_decision(audit_token, allow_marker)
    if process_identity(pid) != identity:
        return None
    if denied == 1 and allowed == 0:
        return audit_token
    return None

def require_trusted_unmarked(pid, label):
    identity = process_identity(pid)
    if identity is None:
        raise OSError(f"Could not validate the {label} process identity.")
    audit_token = process_audit_token(pid)
    if (
        process_identity(pid) != identity
        or marker_decision(audit_token, deny_marker) != 0
        or marker_decision(audit_token, allow_marker) != 0
    ):
        raise OSError(f"The {label} is not outside the labeled verifier sandbox.")

# Sampled marker and environment reads are only discovery evidence. Every
# signal is bound to a TASK_AUDIT_TOKEN after a second exact selector check and
# a start-identity recheck.
def signal_exact_process(pid, audit_token, signum):
    result = proc_signal_with_audittoken(ctypes.byref(audit_token), signum)
    if result not in (0, errno.ESRCH):
        raise OSError(result, "Audit-token signal failed")
    return result == 0

def exact_environment_match(pid, identity):
    audit_token = process_audit_token(pid)
    if process_identity(pid) != identity:
        return None
    state, environment = process_environment(pid, identity)
    if state == "gone":
        return None
    if state != "readable":
        raise OSError("Owned process environment became unreadable")
    if expected_assignment not in environment:
        if process_identity(pid) != identity:
            return None
        raise OSError("Owned process changed its verification token")
    if process_identity(pid) != identity:
        return None
    return audit_token

def discover_scoped_processes(known_owned, signum=None, deadline=None):
    matches = {}
    coarse_observed = False
    inspected = set()
    candidates = deque(process_snapshot_records())
    queued = {
        (record[0], record[2], record[3])
        for record in candidates
    }
    inspected_since_refresh = 0
    while candidates:
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError("Sandbox-marker audit exceeded its containment deadline.")
        record = candidates.popleft()
        pid = record[0]
        identity = (record[0], record[2], record[3])
        queued.discard(identity)
        if identity in inspected:
            continue
        inspected.add(identity)
        inspected_since_refresh += 1
        if inspected_since_refresh >= 16:
            inspected_since_refresh = 0
            fresh = []
            for fresh_record in process_snapshot_records():
                fresh_identity = (
                    fresh_record[0],
                    fresh_record[2],
                    fresh_record[3],
                )
                if fresh_identity not in inspected and fresh_identity not in queued:
                    fresh.append(fresh_record)
                    queued.add(fresh_identity)
            candidates.extendleft(reversed(fresh))
        current_record = process_record(pid)
        if (
            current_record is None
            or current_record[:4] != record[:4]
            or pid in excluded
            or record[1] != os.getuid()
            or record[4] == SZOMB
        ):
            continue
        try:
            sampled_marked = sampled_process_is_marked(pid)
            if sampled_marked:
                if process_identity(pid) != identity:
                    continue
                coarse_observed = True
                known_owned.add(identity)
                audit_token = is_marked(pid, identity)
                if audit_token is None and process_identity(pid) == identity:
                    raise OSError("Exact sandbox-marker identity could not be bound")
            else:
                state, environment = process_environment(pid, identity)
                if state == "gone":
                    continue
                if state != "readable":
                    if identity in known_owned:
                        raise OSError("Owned process environment became unreadable")
                    continue
                if expected_assignment not in environment:
                    if identity in known_owned and process_identity(pid) == identity:
                        raise OSError("Owned process changed its verification token")
                    continue
                if process_identity(pid) != identity:
                    continue
                coarse_observed = True
                known_owned.add(identity)
                audit_token = exact_environment_match(pid, identity)
        except OSError:
            if process_identity(pid) != identity:
                continue
            raise
        if audit_token is None:
            continue
        current_record = process_record(pid)
        if current_record is None or current_record[:4] != record[:4]:
            continue
        token_identity = tuple(audit_token.val)
        matches[token_identity] = (pid, current_record[4], audit_token)
        if signum is not None and not (
            signum == signal.SIGSTOP and current_record[4] == SSTOP
        ):
            # Stop an exact owned identity as soon as it is discovered. Waiting
            # for a full process-table scan would leave rotating parents free to
            # fork forever.
            signal_exact_process(pid, audit_token, signum)
    return matches, coarse_observed

def repeated_scope_scan():
    matches = {}
    known_owned = set()
    for sample in range(8):
        discovered, _ = discover_scoped_processes(known_owned)
        matches.update(discovered)
        if sample != 7:
            time.sleep(0.01)
    return matches

def audit_and_drain_scope():
    deadline = time.monotonic() + 10.0
    quiet_since = None
    empty_passes = 0
    observed = False
    known_owned = set()
    while time.monotonic() < deadline:
        matches, coarse_observed = discover_scoped_processes(
            known_owned,
            signal.SIGSTOP,
            deadline,
        )
        if coarse_observed:
            observed = True
        for pid, _, audit_token in matches.values():
            signal_exact_process(pid, audit_token, signal.SIGKILL)
        if coarse_observed or matches:
            quiet_since = None
            empty_passes = 0
        else:
            now = time.monotonic()
            if quiet_since is None:
                quiet_since = now
            empty_passes += 1
            if empty_passes >= 8 and now - quiet_since >= 0.25:
                return observed
        time.sleep(0.005)
    raise TimeoutError(
        "Could not prove release-process quiescence after exact-identity cleanup."
    )

def main():
    require_trusted_unmarked(os.getpid(), "release-process inspector")
    require_trusted_unmarked(int(shell_pid), "release-verification harness")
    if action == "list":
        matching_pids = {match[0] for match in repeated_scope_scan().values()}
        for pid in sorted(matching_pids):
            print(pid)
        return
    observed = audit_and_drain_scope()
    if action == "audit":
        print("contained" if observed else "clean")

try:
    main()
except Exception:
    print(
        "Release-process audit could not prove exact-identity quiescence.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

easysplat_sandbox_marker_process_action() {
  local action="${1:-}"
  local token="${2:-}"
  local signal_name="${3:-}"
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to inspect sandboxed processes for an invalid release-verification token." >&2
    return 2
  fi
  [ "$action" = list ] && [ -z "$signal_name" ] || return 2
  _easysplat_sandbox_marker_process_action list "$token" ""
}

easysplat_sandbox_marker_process_ids() {
  easysplat_sandbox_marker_process_action list "${1:-}" ""
}

easysplat_audit_and_drain_sandbox_marker_processes() {
  local token="${1:-}"
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing release-process audit for an invalid verification token." >&2
    return 2
  fi
  _easysplat_sandbox_marker_process_action audit "$token" ""
}

easysplat_cleanup_sandbox_marker_processes() {
  local token="${1:-}"
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to clean sandboxed processes for an invalid release-verification token." >&2
    return 2
  fi
  if ! _easysplat_sandbox_marker_process_action drain "$token" ""; then
    echo "Release verification could not stop every sandbox-labeled process by exact audit token." >&2
    return 1
  fi
  return 0
}


easysplat_supervise_process_group() {
  local group_file="${1:-}"
  shift || true
  [ -n "$group_file" ] && [ "$#" -gt 0 ] || return 2
  if [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then
    echo "The release-verification process supervisor must run as a background job." >&2
    return 2
  fi
  exec /usr/bin/python3 -I - "$group_file" "$@" <<'PY'
import ctypes
import os
import secrets
import select
import signal
import stat
import struct
import sys
import time
from pathlib import Path

group_file = Path(sys.argv[1])
request_file = group_file.with_name(f"{group_file.name}.request")
command = sys.argv[2:]
handled_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
supervisor_pid = os.getpid()
request_nonce = secrets.token_hex(32)
process_pid = None
process_exited = False
process_reaped = False
command_completed = False
command_wait_status = None
command_status_buffer = bytearray()
group_drained = False
state_published = False
stop_requested = False
stop_signal = None
event_queue = None
status_read = None
anchor_exit_write = None

PROC_PIDTBSDINFO = 3
SZOMB = 5
SSTOP = 4

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
proc_pidinfo = libproc.proc_pidinfo
proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
proc_pidinfo.restype = ctypes.c_int
proc_listallpids = libproc.proc_listallpids
proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
proc_listallpids.restype = ctypes.c_int

def process_record(pid):
    info = ProcBSDInfo()
    size = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if size != ctypes.sizeof(info) or info.pbi_pid != pid:
        return None
    return info

def process_identity(pid):
    info = process_record(pid)
    if info is None or info.pbi_uid != os.getuid():
        return None
    return (info.pbi_start_tvsec, info.pbi_start_tvusec)

def group_member_records(*, include_anchor=False):
    if process_pid is None:
        return {}
    storage = (ctypes.c_int * 100_000)()
    count = proc_listallpids(storage, ctypes.sizeof(storage))
    if count <= 0 or count >= len(storage):
        raise OSError("Could not capture a bounded process-group snapshot.")
    members = {}
    for pid in storage[:count]:
        if pid < 2 or (pid == process_pid and not include_anchor):
            continue
        info = process_record(pid)
        if (
            info is not None
            and info.pbi_uid == os.getuid()
            and info.pbi_pgid == process_pid
            and (
                info.pbi_status != SZOMB
                or (include_anchor and pid == process_pid)
            )
        ):
            members[pid] = info
    return members

def live_group_members():
    return tuple(sorted(group_member_records()))

def group_is_fully_stopped():
    members = group_member_records(include_anchor=True)
    anchor = members.get(process_pid)
    anchor_is_held = (
        anchor is not None and anchor.pbi_status == SSTOP
    ) or (
        anchor is None and process_exited and not process_reaped
    )
    if not anchor_is_held:
        return False
    return all(
        pid == process_pid or info.pbi_status == SSTOP
        for pid, info in members.items()
    )

def write_state(payload, *, replace):
    staging_file = group_file.with_name(
        f".{group_file.name}.{os.getpid()}.{time.monotonic_ns()}.tmp"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(staging_file, flags, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("Could not publish the supervised process group.")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        if replace:
            os.replace(staging_file, group_file)
        else:
            os.link(staging_file, group_file, follow_symlinks=False)
            staging_file.unlink()
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        directory = os.open(group_file.parent, directory_flags)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            staging_file.unlink()
        except FileNotFoundError:
            pass

def consume_stop_request():
    global stop_requested, stop_signal
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("Safe process-supervisor request reads require O_NOFOLLOW.")
    flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(request_file, flags)
    except FileNotFoundError:
        return
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size > 128
        ):
            raise OSError("Process-supervisor request is not an authenticated file.")
        payload = os.read(descriptor, 129)
        if os.read(descriptor, 1):
            raise OSError("Process-supervisor request exceeded its size bound.")
        path_metadata = request_file.lstat()
        if (path_metadata.st_dev, path_metadata.st_ino) != (
            metadata.st_dev,
            metadata.st_ino,
        ):
            raise OSError("Process-supervisor request changed while it was read.")
    finally:
        os.close(descriptor)
    if payload != f"stop {request_nonce}\n".encode():
        raise OSError("Process-supervisor request did not carry the active nonce.")
    request_file.unlink()
    stop_requested = True
    if stop_signal is None:
        stop_signal = signal.SIGTERM

def mark_quiescent():
    if state_published and process_reaped and group_drained:
        write_state(
            f"quiescent {supervisor_pid} {supervisor_identity[0]} "
            f"{supervisor_identity[1]} {request_nonce}\n".encode(),
            replace=True,
        )

def signal_group(signum):
    if process_pid is None or process_reaped:
        return
    try:
        os.killpg(process_pid, signum)
    except ProcessLookupError:
        pass

def read_command_status():
    global command_completed, command_wait_status, command_status_buffer, status_read
    if status_read is None or command_completed:
        return
    try:
        chunk = os.read(status_read, 4 - len(command_status_buffer))
    except BlockingIOError:
        return
    if not chunk:
        return
    command_status_buffer.extend(chunk)
    if len(command_status_buffer) == 4:
        command_wait_status = struct.unpack("=I", command_status_buffer)[0]
        command_completed = True
        try:
            event_queue.control(
                [
                    select.kevent(
                        status_read,
                        filter=select.KQ_FILTER_READ,
                        flags=select.KQ_EV_DELETE,
                    )
                ],
                0,
                0,
            )
        except OSError:
            pass
        os.close(status_read)
        status_read = None

def observe_events(timeout):
    global process_exited
    for event in event_queue.control(None, 4, timeout):
        if (
            event.filter == select.KQ_FILTER_PROC
            and event.ident == process_pid
            and event.fflags & select.KQ_NOTE_EXIT
        ):
            process_exited = True
        elif (
            status_read is not None
            and event.filter == select.KQ_FILTER_READ
            and event.ident == status_read
        ):
            read_command_status()

def release_anchor():
    global anchor_exit_write
    if process_exited:
        return not live_group_members()
    try:
        os.write(anchor_exit_write, b"X")
    except BrokenPipeError:
        return False
    finally:
        os.close(anchor_exit_write)
        anchor_exit_write = None
    deadline = time.monotonic() + 2.0
    while not process_exited and time.monotonic() < deadline:
        observe_events(0.05)
    return process_exited and not live_group_members()

def drain_group():
    observe_events(0)
    if process_exited and not live_group_members():
        return True
    signal_group(signal.SIGTERM)
    term_deadline = time.monotonic() + 1.0
    while time.monotonic() < term_deadline:
        observe_events(0.05)
        if command_completed and not live_group_members():
            return release_anchor()

    stopped_samples = 0
    stop_deadline = time.monotonic() + 2.0
    while time.monotonic() < stop_deadline:
        signal_group(signal.SIGSTOP)
        time.sleep(0.05)
        if group_is_fully_stopped():
            stopped_samples += 1
            if stopped_samples >= 3:
                break
        else:
            stopped_samples = 0
    if stopped_samples < 3:
        return False

    signal_group(signal.SIGKILL)
    quiet_samples = 0
    kill_deadline = time.monotonic() + 2.0
    while time.monotonic() < kill_deadline:
        observe_events(0.05)
        if process_exited and not live_group_members():
            quiet_samples += 1
            if quiet_samples >= 3:
                return True
        else:
            quiet_samples = 0
    return False

def drain_owned_group_after_failure():
    failure_reported = False
    while True:
        try:
            if drain_group():
                return
        except Exception as error:
            if not failure_reported:
                print(
                    f"Release-verification process-group cleanup will keep retrying: {error}",
                    file=sys.stderr,
                )
                failure_reported = True
        else:
            if not failure_reported:
                print(
                    "Release-verification process group survived bounded cleanup; "
                    "the owning controller will keep retrying.",
                    file=sys.stderr,
                )
                failure_reported = True
        time.sleep(0.1)

def reap_process():
    global process_reaped
    while True:
        try:
            reaped_pid, wait_status = os.waitpid(process_pid, 0)
            if reaped_pid != process_pid:
                raise OSError("Wait returned an unexpected process identifier.")
            process_reaped = True
            return wait_status
        except InterruptedError:
            continue

def request_stop_for_signal(signum, _frame):
    global stop_requested, stop_signal
    stop_requested = True
    if stop_signal is None:
        stop_signal = signum

for handled_signal in handled_signals:
    signal.signal(handled_signal, request_stop_for_signal)

supervisor_identity = process_identity(supervisor_pid)
if supervisor_identity is None:
    raise OSError("Could not bind the process supervisor to its start identity.")

previous_signal_mask = None
if hasattr(signal, "pthread_sigmask"):
    previous_signal_mask = signal.pthread_sigmask(signal.SIG_BLOCK, handled_signals)

ready_read = ready_write = release_read = release_write = None
status_write = anchor_exit_read = None
command_released = False
try:
    if os.path.lexists(request_file):
        raise FileExistsError(
            f"Process-supervisor request path already exists: {request_file}"
        )
    ready_read, ready_write = os.pipe()
    release_read, release_write = os.pipe()
    status_read, status_write = os.pipe()
    anchor_exit_read, anchor_exit_write = os.pipe()
    process_pid = os.fork()
    if process_pid == 0:
        try:
            os.close(ready_read)
            os.close(release_write)
            os.close(status_read)
            os.close(anchor_exit_write)
            os.setsid()
            os.write(ready_write, b"R")
            os.close(ready_write)
            if os.read(release_read, 1) != b"G":
                raise OSError("The process controller did not release the child.")
            os.close(release_read)
            command_pid = os.fork()
            if command_pid == 0:
                os.close(status_write)
                os.close(anchor_exit_read)
                restored_signals = set(handled_signals)
                for signal_name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
                    restored_signal = getattr(signal, signal_name, None)
                    if restored_signal is not None:
                        restored_signals.add(restored_signal)
                for restored_signal in restored_signals:
                    signal.signal(restored_signal, signal.SIG_DFL)
                if hasattr(signal, "pthread_sigmask"):
                    signal.pthread_sigmask(signal.SIG_SETMASK, ())
                try:
                    os.execvpe(command[0], command, os.environ.copy())
                except BaseException as error:
                    try:
                        os.write(
                            2,
                            f"Could not launch supervised command: {error}\n".encode(),
                        )
                    except OSError:
                        pass
                    os._exit(126)
            while True:
                try:
                    _, command_status = os.waitpid(command_pid, 0)
                    break
                except InterruptedError:
                    continue
            os.write(status_write, struct.pack("=I", command_status))
            os.close(status_write)
            if os.read(anchor_exit_read, 1) != b"X":
                raise OSError("The process controller did not release its anchor.")
            os.close(anchor_exit_read)
            os._exit(0)
        except BaseException as error:
            try:
                os.write(2, f"Could not launch supervised command: {error}\n".encode())
            except OSError:
                pass
            os._exit(126)
    os.close(ready_write)
    ready_write = None
    os.close(release_read)
    release_read = None
    os.close(status_write)
    status_write = None
    os.close(anchor_exit_read)
    anchor_exit_read = None
    if os.read(ready_read, 1) != b"R":
        raise OSError("The supervised child did not establish its process group.")
    os.close(ready_read)
    ready_read = None
    process_identity_value = process_identity(process_pid)
    if process_identity_value is None:
        raise OSError("Could not bind the supervised process to its start identity.")
    event_queue = select.kqueue()
    os.set_blocking(status_read, False)
    event_queue.control(
        [
            select.kevent(
                process_pid,
                filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
                fflags=select.KQ_NOTE_EXIT,
            ),
            select.kevent(
                status_read,
                filter=select.KQ_FILTER_READ,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
            ),
        ],
        0,
        0,
    )
    write_state(
        f"active {process_pid} {process_identity_value[0]} "
        f"{process_identity_value[1]} {supervisor_pid} "
        f"{supervisor_identity[0]} {supervisor_identity[1]} "
        f"{request_nonce}\n".encode(),
        replace=False,
    )
    state_published = True
    os.write(release_write, b"G")
    command_released = True
    os.close(release_write)
    release_write = None
except BaseException:
    if process_pid is not None:
        if command_released:
            drain_owned_group_after_failure()
            group_drained = True
            reap_process()
            mark_quiescent()
        else:
            try:
                os.kill(process_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(process_pid, 0)
            except ChildProcessError:
                pass
    raise
finally:
    for descriptor in (
        ready_read,
        ready_write,
        release_read,
        release_write,
        status_write,
        anchor_exit_read,
    ):
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    if previous_signal_mask is not None:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

controller_error = None
exit_status = None
try:
    while not command_completed and not stop_requested:
        observe_events(0.05)
        consume_stop_request()
        if process_exited and not command_completed:
            raise OSError("The process-group anchor exited before reporting command status.")
    if process_exited:
        raise OSError("The process-group anchor exited before controller release.")
except BaseException as error:
    controller_error = error

if controller_error is not None:
    print(f"Release-verification process supervisor failed: {controller_error}", file=sys.stderr)
    drain_owned_group_after_failure()
    group_drained = True
    reap_process()
    mark_quiescent()
    exit_status = 126
elif stop_requested:
    try:
        drain_succeeded = drain_group()
    except Exception:
        drain_succeeded = False
    if not drain_succeeded:
        drain_owned_group_after_failure()
        exit_status = 126
    else:
        exit_status = 128 + (stop_signal or signal.SIGTERM)
    group_drained = True
    reap_process()
    mark_quiescent()
else:
    try:
        had_lingering_members = bool(live_group_members())
        if had_lingering_members:
            drain_succeeded = drain_group()
        else:
            drain_succeeded = release_anchor()
    except Exception:
        had_lingering_members = True
        drain_succeeded = False
    if not drain_succeeded:
        drain_owned_group_after_failure()
        exit_status = 126
    try:
        group_changed = bool(live_group_members())
    except Exception:
        group_changed = True
    if group_changed:
        drain_owned_group_after_failure()
        exit_status = 126
    group_drained = True
    reap_process()
    mark_quiescent()
    if exit_status == 126:
        pass
    elif had_lingering_members:
        print(
            "Release verification left a detached pipeline or toolchain worker process.",
            file=sys.stderr,
        )
        exit_status = 125
    elif os.WIFEXITED(command_wait_status):
        exit_status = os.WEXITSTATUS(command_wait_status)
    elif os.WIFSIGNALED(command_wait_status):
        exit_status = 128 + os.WTERMSIG(command_wait_status)
    else:
        exit_status = 124

event_queue.close()
if status_read is not None:
    os.close(status_read)
if anchor_exit_write is not None:
    os.close(anchor_exit_write)
try:
    request_file.unlink()
except FileNotFoundError:
    pass
raise SystemExit(exit_status)
PY
}

easysplat_read_supervised_process_group_state() {
  local group_file="${1:-}"
  [ -n "$group_file" ] || return 2
  /usr/bin/python3 - "$group_file" <<'PY'
import os
import re
import stat
import sys
path = sys.argv[1]
flags = os.O_RDONLY | os.O_CLOEXEC
if not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit(1)
flags |= os.O_NOFOLLOW
try:
    descriptor = os.open(path, flags)
except OSError:
    raise SystemExit(1)
try:
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(1)
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit(1)
    payload = os.read(descriptor, 256)
    if os.read(descriptor, 1):
        raise SystemExit(1)
finally:
    os.close(descriptor)
active_match = re.fullmatch(
    rb"active ([1-9][0-9]{0,4}) ([1-9][0-9]{0,19}) ([0-9]{1,6}) "
    rb"([1-9][0-9]{0,4}) ([1-9][0-9]{0,19}) ([0-9]{1,6}) "
    rb"([0-9a-f]{64})\n",
    payload,
)
quiescent_match = re.fullmatch(
    rb"quiescent ([1-9][0-9]{0,4}) ([1-9][0-9]{0,19}) ([0-9]{1,6}) "
    rb"([0-9a-f]{64})\n",
    payload,
)
if active_match is not None:
    numeric_fields = tuple(map(int, active_match.groups()[:6]))
    pid, start_seconds, start_microseconds, supervisor_pid, supervisor_seconds, supervisor_microseconds = numeric_fields
    nonce = active_match.group(7).decode("ascii")
    state = "active"
elif quiescent_match is not None:
    supervisor_pid, supervisor_seconds, supervisor_microseconds = map(
        int,
        quiescent_match.groups()[:3],
    )
    nonce = quiescent_match.group(4).decode("ascii")
    pid = start_seconds = start_microseconds = None
    state = "quiescent"
else:
    raise SystemExit(1)
# Darwin allocates process IDs in the inclusive 2...99999 range.
if (
    not 2 <= supervisor_pid <= 99_999
    or supervisor_microseconds >= 1_000_000
):
    raise SystemExit(1)
if state == "active":
    if not 2 <= pid <= 99_999 or start_microseconds >= 1_000_000:
        raise SystemExit(1)
    print(
        f"active:{pid}:{start_seconds}:{start_microseconds}:"
        f"{supervisor_pid}:{supervisor_seconds}:{supervisor_microseconds}:{nonce}"
    )
else:
    print(
        f"quiescent:{supervisor_pid}:{supervisor_seconds}:"
        f"{supervisor_microseconds}:{nonce}"
    )
PY
}

easysplat_read_supervised_process_group_id() {
  local state=""
  state="$(easysplat_read_supervised_process_group_state "${1:-}")" || return $?
  [[ "$state" == active:* ]] || return 1
  printf '%s\n' "${state#active:}" | cut -d: -f1
}

easysplat_supervised_process_group_identity_matches() {
  local group_pid="${1:-}"
  local start_seconds="${2:-}"
  local start_microseconds="${3:-}"
  /usr/bin/python3 - "$group_pid" "$start_seconds" "$start_microseconds" <<'PY'
import ctypes
import os
import sys

try:
    expected = tuple(map(int, sys.argv[1:]))
except ValueError:
    raise SystemExit(1)
pid, expected_seconds, expected_microseconds = expected
if not 2 <= pid <= 99_999 or expected_seconds <= 0 or not 0 <= expected_microseconds < 1_000_000:
    raise SystemExit(1)

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
proc_pidinfo = libproc.proc_pidinfo
proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
proc_pidinfo.restype = ctypes.c_int
info = ProcBSDInfo()
size = proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
if size != ctypes.sizeof(info) or info.pbi_pid != pid or info.pbi_uid != os.getuid():
    raise SystemExit(1)
if (info.pbi_start_tvsec, info.pbi_start_tvusec) != (expected_seconds, expected_microseconds):
    raise SystemExit(1)
PY
}


easysplat_wait_for_supervised_process_group() {
  local supervisor_pid="${1:-}"
  local group_file="${2:-}"
  local state=""
  [[ "$supervisor_pid" =~ ^[1-9][0-9]*$ ]] && [ -n "$group_file" ] || return 2
  for _ in {1..200}; do
    if state="$(easysplat_read_supervised_process_group_state "$group_file" 2>/dev/null)"; then
      return 0
    fi
    kill -0 "$supervisor_pid" 2>/dev/null || return 1
    sleep 0.01
  done
  return 1
}

easysplat_reap_supervisor_with_identity() {
  local supervisor_pid="${1:-}"
  local start_seconds="${2:-}"
  local start_microseconds="${3:-}"
  local disposition=""
  disposition="$(
    /usr/bin/python3 - "$supervisor_pid" "$start_seconds" "$start_microseconds" <<'PY'
import ctypes
import os
import sys
import time

try:
    pid, expected_seconds, expected_microseconds = map(int, sys.argv[1:])
except ValueError:
    raise SystemExit(2)
if (
    not 2 <= pid <= 99_999
    or expected_seconds <= 0
    or not 0 <= expected_microseconds < 1_000_000
):
    raise SystemExit(2)

PROC_PIDTBSDINFO = 3
SZOMB = 5

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
proc_pidinfo = libproc.proc_pidinfo
proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
proc_pidinfo.restype = ctypes.c_int

def process_record():
    info = ProcBSDInfo()
    size = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if size != ctypes.sizeof(info) or info.pbi_pid != pid:
        return None
    return info

deadline = time.monotonic() + 2.0
while True:
    record = process_record()
    if record is None:
        print("gone")
        raise SystemExit(0)
    if (
        record.pbi_uid != os.getuid()
        or (record.pbi_start_tvsec, record.pbi_start_tvusec)
        != (expected_seconds, expected_microseconds)
    ):
        print("Process supervisor PID was reused before reap.", file=sys.stderr)
        raise SystemExit(1)
    if record.pbi_status == SZOMB:
        print("reap")
        raise SystemExit(0)
    if time.monotonic() >= deadline:
        print("Process supervisor did not exit after publishing quiescence.", file=sys.stderr)
        raise SystemExit(1)
    time.sleep(0.02)
PY
  )" || return 1
  if [ "$disposition" = reap ]; then
    wait "$supervisor_pid" 2>/dev/null || true
  elif [ "$disposition" != gone ]; then
    return 1
  fi
}

easysplat_request_supervised_process_stop() {
  local group_file="${1:-}"
  local request_nonce="${2:-}"
  [ -n "$group_file" ] && [[ "$request_nonce" =~ ^[0-9a-f]{64}$ ]] || return 2
  /usr/bin/python3 -I - "$group_file" "$request_nonce" <<'PY'
import os
import stat
import sys
import time
from pathlib import Path

group_file = Path(sys.argv[1])
nonce = sys.argv[2]
request_file = group_file.with_name(f"{group_file.name}.request")
expected = f"stop {nonce}\n".encode()

def validate_existing():
    flags = os.O_RDONLY | os.O_CLOEXEC
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("Safe process-supervisor requests require O_NOFOLLOW.")
    flags |= os.O_NOFOLLOW
    descriptor = os.open(request_file, flags)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size != len(expected)
        ):
            raise OSError("Existing process-supervisor request is not authenticated.")
        payload = os.read(descriptor, len(expected) + 1)
        path_metadata = request_file.lstat()
        if (path_metadata.st_dev, path_metadata.st_ino) != (
            metadata.st_dev,
            metadata.st_ino,
        ):
            raise OSError("Process-supervisor request changed during validation.")
    finally:
        os.close(descriptor)
    if payload != expected:
        raise OSError("Existing process-supervisor request has the wrong nonce.")

if os.path.lexists(request_file):
    validate_existing()
    raise SystemExit(0)

staging_file = request_file.with_name(
    f".{request_file.name}.{os.getpid()}.{time.monotonic_ns()}.tmp"
)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
if not hasattr(os, "O_NOFOLLOW"):
    raise OSError("Safe process-supervisor requests require O_NOFOLLOW.")
flags |= os.O_NOFOLLOW
descriptor = os.open(staging_file, flags, 0o600)
try:
    offset = 0
    while offset < len(expected):
        written = os.write(descriptor, expected[offset:])
        if written <= 0:
            raise OSError("Could not publish the process-supervisor request.")
        offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
try:
    try:
        os.link(staging_file, request_file, follow_symlinks=False)
    except FileExistsError:
        validate_existing()
    directory_flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        directory_flags |= os.O_DIRECTORY
    directory = os.open(request_file.parent, directory_flags)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    staging_file.unlink(missing_ok=True)
PY
}

easysplat_cleanup_supervised_process_group() {
  local supervisor_pid="${1:-}"
  local group_file="${2:-}"
  local state=""
  local state_supervisor_pid=""
  local supervisor_start_seconds=""
  local supervisor_start_microseconds=""
  local quiescent_supervisor_pid=""
  local quiescent_start_seconds=""
  local quiescent_start_microseconds=""
  local request_nonce=""
  local request_file=""

  [ -n "$group_file" ] || {
    [ -z "$supervisor_pid" ] && return 0
    return 2
  }
  request_file="${group_file}.request"

  if [ ! -e "$group_file" ] && [ ! -L "$group_file" ]; then
    if [ -z "$supervisor_pid" ]; then
      return 0
    fi
    easysplat_wait_for_supervised_process_group \
      "$supervisor_pid" "$group_file" >/dev/null 2>&1 || {
        echo "Could not bind the process supervisor to validated state." >&2
        return 1
      }
  fi
  if ! state="$(easysplat_read_supervised_process_group_state "$group_file" 2>/dev/null)"; then
    echo "Refusing to clean invalid release-verification process-group state." >&2
    return 1
  fi

  if [[ "$state" == active:* ]]; then
    IFS=: read -r _ _ _ _ state_supervisor_pid \
      supervisor_start_seconds supervisor_start_microseconds \
      request_nonce <<<"$state"
    if ! [[ "$supervisor_pid" =~ ^[1-9][0-9]*$ ]] \
      || [ "$state_supervisor_pid" != "$supervisor_pid" ]; then
      echo "Process-group state does not identify the active supervisor." >&2
      return 1
    fi
    if ! easysplat_supervised_process_group_identity_matches \
      "$supervisor_pid" \
      "$supervisor_start_seconds" \
      "$supervisor_start_microseconds"; then
      echo "The active process supervisor no longer matches its recorded identity." >&2
      return 1
    fi
    if ! easysplat_request_supervised_process_stop \
      "$group_file" "$request_nonce"; then
      echo "Could not publish the authenticated process-supervisor stop request." >&2
      return 1
    fi
    for _ in {1..70}; do
      if ! state="$(
        easysplat_read_supervised_process_group_state "$group_file" 2>/dev/null
      )"; then
        echo "Process-group state became invalid during cleanup." >&2
        return 1
      fi
      [[ "$state" == quiescent:* ]] && break
      sleep 0.05
    done
    if [[ "$state" != quiescent:* ]]; then
      echo "Process supervisor did not acknowledge its bounded stop request." >&2
      return 1
    fi
    IFS=: read -r _ quiescent_supervisor_pid quiescent_start_seconds \
      quiescent_start_microseconds _ <<<"$state"
    if [ "$quiescent_supervisor_pid" != "$supervisor_pid" ] \
      || [ "$quiescent_start_seconds" != "$supervisor_start_seconds" ] \
      || [ "$quiescent_start_microseconds" != "$supervisor_start_microseconds" ]; then
      echo "Quiescent state no longer identifies the active supervisor." >&2
      return 1
    fi
    if ! easysplat_reap_supervisor_with_identity \
      "$supervisor_pid" \
      "$supervisor_start_seconds" \
      "$supervisor_start_microseconds"; then
      return 1
    fi
  elif [ -n "$supervisor_pid" ]; then
    IFS=: read -r _ state_supervisor_pid supervisor_start_seconds \
      supervisor_start_microseconds _ <<<"$state"
    if [ "$state_supervisor_pid" != "$supervisor_pid" ]; then
      echo "Quiescent state does not identify the supplied supervisor." >&2
      return 1
    fi
    if ! easysplat_reap_supervisor_with_identity \
      "$supervisor_pid" \
      "$supervisor_start_seconds" \
      "$supervisor_start_microseconds"; then
      return 1
    fi
  fi

  if ! state="$(easysplat_read_supervised_process_group_state "$group_file" 2>/dev/null)" \
    || [[ "$state" != quiescent:* ]]; then
    echo "Process supervisor did not publish authenticated quiescence." >&2
    return 1
  fi
  if [ -e "$request_file" ] || [ -L "$request_file" ]; then
    echo "Process supervisor left its stop request behind." >&2
    return 1
  fi
  rm -f "$group_file"
}

easysplat_token_process_action() {
  local action="${1:-}"
  local token="${2:-}"
  local signal_name="${3:-}"
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to inspect processes for an invalid release-verification token." >&2
    return 2
  fi
  case "$action" in
    list|audit) ;;
    *) return 2 ;;
  esac
  [ -z "$signal_name" ] || return 2
  _easysplat_sandbox_marker_process_action "$action" "$token" ""
}

easysplat_token_process_ids() {
  easysplat_token_process_action list "${1:-}" ""
}

easysplat_cleanup_token_processes() {
  local token="${1:-}"
  local result=""
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to clean processes for an invalid release-verification token." >&2
    return 2
  fi
  if ! result="$(
    easysplat_audit_and_drain_verification_processes "$token"
  )"; then
    echo "Release verification could not prove residual-process quiescence." >&2
    return 1
  fi
  case "$result" in
    clean|contained) return 0 ;;
    *)
      echo "Release verification returned invalid containment evidence." >&2
      return 1
      ;;
  esac
}

easysplat_audit_and_drain_verification_processes() {
  local token="${1:-}"
  local result=""
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing release-process audit for an invalid verification token." >&2
    return 2
  fi
  if ! result="$(
    _easysplat_sandbox_marker_process_action audit "$token" ""
  )"; then
    return 1
  fi
  case "$result" in
    clean|contained) printf '%s\n' "$result" ;;
    *)
      echo "Release-process audit returned invalid containment evidence." >&2
      return 1
      ;;
  esac
}
