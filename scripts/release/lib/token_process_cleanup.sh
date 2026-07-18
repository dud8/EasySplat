#!/usr/bin/env bash

easysplat_validate_release_verification_token() {
  local token="${1:-}"
  [[ "$token" =~ ^easysplat-release-verify-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

easysplat_token_process_ids() {
  local token="${1:-}"
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to inspect processes for an invalid release-verification token." >&2
    return 2
  fi
  python3 - "$token" "$$" <<'PY'
import os
import re
import subprocess
import sys

token, shell_pid = sys.argv[1:]
assignment = re.compile(
    rf"(?:^|\s)EASYSPLAT_RELEASE_VERIFY_TOKEN={re.escape(token)}(?:\s|$)"
)
snapshot = subprocess.run(
    ["/bin/ps", "eww", "-axo", "pid=,command="],
    check=True,
    stdout=subprocess.PIPE,
    text=True,
).stdout
excluded = {shell_pid, str(os.getpid())}
for line in snapshot.splitlines():
    fields = line.lstrip().split(maxsplit=1)
    if len(fields) != 2 or not fields[0].isdigit() or fields[0] in excluded:
        continue
    if assignment.search(fields[1]):
        print(fields[0])
PY
}

easysplat_cleanup_token_processes() {
  local token="${1:-}"
  local signal_name=""
  local pids=""
  local pid=""
  if ! easysplat_validate_release_verification_token "$token"; then
    echo "Refusing to clean processes for an invalid release-verification token." >&2
    return 2
  fi

  for signal_name in TERM KILL; do
    pids="$(easysplat_token_process_ids "$token")" || return 1
    [ -n "$pids" ] || return 0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -"$signal_name" "$pid" 2>/dev/null || true
    done <<<"$pids"
    for _ in {1..20}; do
      pids="$(easysplat_token_process_ids "$token")" || return 1
      [ -n "$pids" ] || return 0
      sleep 0.05
    done
  done

  pids="$(easysplat_token_process_ids "$token")" || return 1
  if [ -n "$pids" ]; then
    echo "Release-verification token processes survived TERM and KILL: $pids" >&2
    return 1
  fi
}
