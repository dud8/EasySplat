#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SELF_PATH="$ROOT/scripts/ci/test_hostile_process_supervision.sh"
# shellcheck source=../release/lib/token_process_cleanup.sh
source "$ROOT/scripts/release/lib/token_process_cleanup.sh"

run_inner_fixture() {
  local fixture_kind="$1"
  local fixture_root="$2"
  local supervisor_pid=""
  local group_file="$fixture_root/$fixture_kind.group"

  # shellcheck disable=SC2329 # Invoked by the EXIT trap.
  cleanup_inner_fixture() {
    local status=$?
    trap - EXIT
    if [ -n "$supervisor_pid" ] || [ -e "$group_file" ]; then
      easysplat_cleanup_supervised_process_group \
        "$supervisor_pid" "$group_file" >/dev/null 2>&1 || status=1
    fi
    exit "$status"
  }
  trap cleanup_inner_fixture EXIT

  case "$fixture_kind" in
    parent-kill-probe)
      /usr/bin/python3 -I -c \
        'import os, signal, time; os.kill(os.getppid(), signal.SIGKILL); time.sleep(1)'
      echo "The parent-kill containment probe returned to its sacrificial shell." >&2
      return 1
      ;;
    lost-anchor)
      local fixture="$fixture_root/lost-anchor-fixture.py"
      local worker="$fixture_root/lost-anchor.worker"
      local error_log="$fixture_root/lost-anchor.stderr"
      cat >"$fixture" <<'PY'
#!/usr/bin/python3
import os
import signal
import sys
import time
from pathlib import Path

worker_path = Path(sys.argv[1])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
worker_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
os.kill(os.getppid(), signal.SIGKILL)
time.sleep(30)
PY
      chmod 700 "$fixture"
      easysplat_supervise_process_group \
        "$group_file" "$fixture" "$worker" 2>"$error_log" &
      supervisor_pid=$!
      easysplat_wait_for_supervised_process_group "$supervisor_pid" "$group_file"
      set +e
      wait "$supervisor_pid"
      local supervisor_status=$?
      set -e
      supervisor_pid=""
      if [ "$supervisor_status" -ne 126 ]; then
        echo "Controller returned $supervisor_status after losing its anchor, expected 126." >&2
        return 1
      fi
      local worker_pid
      worker_pid="$(cat "$worker")"
      for _ in {1..200}; do
        kill -0 "$worker_pid" 2>/dev/null || break
        sleep 0.01
      done
      if kill -0 "$worker_pid" 2>/dev/null; then
        echo "Controller exited while a worker from its anchored process group remained alive." >&2
        return 1
      fi
      [[ "$(easysplat_read_supervised_process_group_state "$group_file")" == \
        quiescent:* ]]
      easysplat_cleanup_supervised_process_group "" "$group_file"
      ;;
    post-status-anchor)
      local fixture="$fixture_root/post-status-anchor-fixture.py"
      local attacker="$fixture_root/post-status-anchor.attacker"
      local error_log="$fixture_root/post-status-anchor.stderr"
      cat >"$fixture" <<'PY'
#!/usr/bin/python3
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

attacker_path = Path(sys.argv[1])
anchor_pid = os.getppid()
supervisor_pid = int(subprocess.check_output(
    ["/bin/ps", "-o", "ppid=", "-p", str(anchor_pid)],
    text=True,
).strip())
ready_read, ready_write = os.pipe()
attacker_pid = os.fork()
if attacker_pid == 0:
    os.close(ready_read)
    os.setsid()
    attacker_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
    os.kill(supervisor_pid, signal.SIGSTOP)
    os.write(ready_write, b"R")
    os.close(ready_write)
    time.sleep(0.2)
    os.kill(anchor_pid, signal.SIGKILL)
    os.kill(supervisor_pid, signal.SIGCONT)
    os._exit(0)

os.close(ready_write)
if os.read(ready_read, 1) != b"R":
    raise SystemExit("The anchor attacker did not stop the controller.")
os.close(ready_read)
os._exit(0)
PY
      chmod 700 "$fixture"
      easysplat_supervise_process_group \
        "$group_file" "$fixture" "$attacker" 2>"$error_log" &
      supervisor_pid=$!
      easysplat_wait_for_supervised_process_group "$supervisor_pid" "$group_file"
      for _ in {1..400}; do
        kill -0 "$supervisor_pid" 2>/dev/null || break
        sleep 0.01
      done
      if kill -0 "$supervisor_pid" 2>/dev/null; then
        kill -KILL "$supervisor_pid" 2>/dev/null || true
        wait "$supervisor_pid" 2>/dev/null || true
        supervisor_pid=""
        echo "Controller did not bound cleanup after its anchor exited post-status." >&2
        return 1
      fi
      set +e
      wait "$supervisor_pid"
      local supervisor_status=$?
      set -e
      supervisor_pid=""
      if [ "$supervisor_status" -ne 126 ]; then
        echo "Controller returned $supervisor_status after its anchor exited post-status, expected 126." >&2
        return 1
      fi
      local attacker_pid
      attacker_pid="$(cat "$attacker")"
      for _ in {1..200}; do
        kill -0 "$attacker_pid" 2>/dev/null || break
        sleep 0.01
      done
      if kill -0 "$attacker_pid" 2>/dev/null; then
        echo "Post-status attacker remained alive after the supervisor fixture completed." >&2
        return 1
      fi
      [[ "$(easysplat_read_supervised_process_group_state "$group_file")" == \
        quiescent:* ]]
      easysplat_cleanup_supervised_process_group "" "$group_file"
      ;;
    *)
      echo "Unknown hostile process-supervision fixture: $fixture_kind" >&2
      return 2
      ;;
  esac

  trap - EXIT
}

if [ "${1:-}" = "--inner" ]; then
  [ "$#" -eq 3 ] || exit 2
  run_inner_fixture "$2" "$3"
  exit 0
fi

[ "$#" -le 1 ] || exit 2
fixture_root="${1:-}"
owns_fixture_root=0
if [ -z "$fixture_root" ]; then
  fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-hostile-supervisor-test.XXXXXX")"
  owns_fixture_root=1
else
  mkdir -p "$fixture_root"
fi
fixture_root="$(cd "$fixture_root" && pwd -P)"
if [ ! -d "$fixture_root" ] || [ -L "$fixture_root" ]; then
  echo "Hostile process-supervision fixture root is unsafe." >&2
  exit 2
fi
chmod 700 "$fixture_root"

cleanup_outer_fixture() {
  local status=$?
  trap - EXIT
  local group_file
  for group_file in \
    "$fixture_root/lost-anchor/lost-anchor.group" \
    "$fixture_root/post-status-anchor/post-status-anchor.group"; do
    if [ -e "$group_file" ]; then
      easysplat_cleanup_supervised_process_group "" "$group_file" \
        >/dev/null 2>&1 || status=1
    fi
  done
  if [ "$owns_fixture_root" -eq 1 ]; then
    rm -rf "$fixture_root"
  fi
  exit "$status"
}
trap cleanup_outer_fixture EXIT

outer_pid="${EASYSPLAT_RELEASE_TEST_OUTER_PID:-$$}"
if ! [[ "$outer_pid" =~ ^[1-9][0-9]{0,4}$ ]]; then
  echo "Hostile process-supervision test received an invalid outer PID." >&2
  exit 2
fi
outer_session="${EASYSPLAT_RELEASE_TEST_OUTER_SESSION:-}"
if [ -z "$outer_session" ]; then
  outer_session="$(/usr/bin/python3 -I - "$outer_pid" <<'PY'
import os
import sys

print(os.getsid(int(sys.argv[1])))
PY
)"
fi
if ! [[ "$outer_session" =~ ^[1-9][0-9]{0,9}$ ]]; then
  echo "Hostile process-supervision test received an invalid outer session." >&2
  exit 2
fi

run_sacrificial_fixture() {
  local fixture_kind="$1"
  local expected_status="$2"
  local case_root="$fixture_root/$fixture_kind"
  mkdir -m 700 "$case_root"
  /usr/bin/python3 -I - \
    "$SELF_PATH" "$fixture_kind" "$case_root" \
    "$expected_status" "$outer_pid" "$outer_session" <<'PY'
import os
import signal
import subprocess
import sys

script, fixture_kind, fixture_root, expected_raw, outer_raw, session_raw = sys.argv[1:]
expected = int(expected_raw)
outer_pid = int(outer_raw)
outer_session = int(session_raw)

def require_outer_identity():
    os.kill(outer_pid, 0)
    if os.getsid(outer_pid) != outer_session:
        raise SystemExit("The outer release-test session changed during a hostile fixture.")

require_outer_identity()
process = subprocess.Popen(
    ["/bin/bash", "--noprofile", "--norc", script, "--inner", fixture_kind, fixture_root],
    start_new_session=True,
)
try:
    return_code = process.wait(timeout=30)
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    raise SystemExit(f"Hostile supervisor fixture timed out: {fixture_kind}")
require_outer_identity()
if return_code != expected:
    raise SystemExit(
        f"Hostile supervisor fixture {fixture_kind} returned {return_code}; "
        f"expected {expected}."
    )
PY
}

run_sacrificial_fixture parent-kill-probe -9
run_sacrificial_fixture lost-anchor 0
run_sacrificial_fixture post-status-anchor 0

/usr/bin/python3 -I - "$outer_pid" "$outer_session" <<'PY'
import os
import sys

pid, expected_session = map(int, sys.argv[1:])
os.kill(pid, 0)
if os.getsid(pid) != expected_session:
    raise SystemExit("The outer release-test session changed after hostile fixtures.")
PY

trap - EXIT
if [ "$owns_fixture_root" -eq 1 ]; then
  rm -rf "$fixture_root"
fi
