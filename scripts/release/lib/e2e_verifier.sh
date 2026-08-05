# shellcheck shell=bash

cleanup_release_verifier_processes() {
  local token="${E2E_VERIFIER_TOKEN:-}"
  local cleanup_status=0
  local audit_result=""
  if easysplat_cleanup_supervised_process_group \
    "${E2E_VERIFIER_SUPERVISOR_PID:-}" \
    "${E2E_VERIFIER_GROUP_FILE:-}"; then
    E2E_VERIFIER_SUPERVISOR_PID=""
    E2E_VERIFIER_GROUP_FILE=""
  else
    cleanup_status=1
  fi
  if [ -n "$token" ]; then
    if ! audit_result="$(
      easysplat_audit_and_drain_verification_processes "$token"
    )"; then
      echo "error: could not prove release-verifier process quiescence." >&2
      cleanup_status=1
    elif [ "$audit_result" != clean ] && [ "$audit_result" != contained ]; then
      echo "error: release-verifier cleanup returned invalid containment evidence." >&2
      cleanup_status=1
    fi
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    E2E_VERIFIER_TOKEN=""
  fi
  return "$cleanup_status"
}

run_release_verifier() {
  local network_policy=$1
  local verifier_home=$2
  local writable_root=$3
  local bundle_root=$4
  local sandbox_profile=""
  local developer_root=""
  local developer_root_mode=""
  local developer_root_owner=""
  local python_runtime_executable=""
  local python_app_executable=""
  local python_runtime_root=""
  local invoking_cwd=""
  local invoking_home="${HOME:-}"
  local outside_read_probe=""
  local outside_write_probe=""
  local bundle_write_probe=""
  local network_probe_status=0
  local network_rule=""
  local command_status=0
  local current_epoch=0
  local deadline_epoch=0
  local remaining_processes=""
  local supervisor_state=""
  local timed_out=0
  local timeout_seconds="${EASYSPLAT_RELEASE_VERIFIER_TIMEOUT_SECONDS:-7200}"
  local verification_token=""
  local group_file=""
  local darwin_user_temp=""
  local first_executable_line=""
  shift 4

  if [ "$#" -eq 0 ]; then
    echo "Release verification requires an executable command." >&2
    return 1
  fi

  if ! declare -F easysplat_validate_release_verification_token >/dev/null \
    || ! declare -F easysplat_audit_and_drain_verification_processes >/dev/null \
    || ! declare -F easysplat_supervise_process_group >/dev/null \
    || ! declare -F easysplat_wait_for_supervised_process_group >/dev/null \
    || ! declare -F easysplat_read_supervised_process_group_state >/dev/null \
    || ! declare -F easysplat_cleanup_supervised_process_group >/dev/null; then
    echo "Release verification requires token-based process inspection." >&2
    return 1
  fi
  case "$timeout_seconds" in
    ''|0|0*|*[!0-9]*)
      echo "Release-verifier timeout must be a positive base-10 integer." >&2
      return 1
      ;;
  esac
  if [ "$timeout_seconds" -gt 86400 ]; then
    echo "Release-verifier timeout cannot exceed 86400 seconds." >&2
    return 1
  fi
  verification_token="easysplat-release-verify-$(uuidgen)"
  if ! easysplat_validate_release_verification_token "$verification_token"; then
    echo "Could not create a valid release-verifier process token." >&2
    return 1
  fi
  E2E_VERIFIER_TOKEN="$verification_token"
  if ! mkdir -p "$verifier_home/tmp" "$writable_root" \
    || ! chmod 700 "$verifier_home" "$verifier_home/tmp"; then
    cleanup_release_verifier_processes || true
    return 1
  fi
  if [ ! -d "$bundle_root" ]; then
    echo "Release verification requires the packaged app bundle it attests." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! verifier_home="$(cd "$verifier_home" && pwd -P)" \
    || ! writable_root="$(cd "$writable_root" && pwd -P)" \
    || ! bundle_root="$(cd "$bundle_root" && pwd -P)" \
    || ! invoking_cwd="$(pwd -P)"; then
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! darwin_user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" \
    || [ -z "$darwin_user_temp" ]; then
    echo "Could not resolve the Foundation replacement directory." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! developer_root="$(
    /usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p
  )" \
    || [ -z "$developer_root" ]; then
    echo "Could not resolve the active Apple developer toolchain." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! developer_root="$(cd "$developer_root" && pwd -P)" \
    || ! developer_root_owner="$(/usr/bin/stat -f '%u' "$developer_root")" \
    || ! developer_root_mode="$(/usr/bin/stat -f '%Lp' "$developer_root")"; then
    echo "Could not authenticate the active Apple developer toolchain path." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  case "$developer_root" in
    /Applications/Xcode*.app/Contents/Developer|/Library/Developer/CommandLineTools) ;;
    *)
      echo "The active Apple developer toolchain is outside an approved system location." >&2
      cleanup_release_verifier_processes || true
      return 1
      ;;
  esac
  if [ "$developer_root_owner" -ne 0 ] \
    || [ $((8#$developer_root_mode & 8#22)) -ne 0 ]; then
    echo "The active Apple developer toolchain must be root-owned and not group- or world-writable." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! python_runtime_root="$(
    DEVELOPER_DIR="$developer_root" PYTHONNOUSERSITE=1 /usr/bin/python3 -I - <<'PY'
import os
import sys

print(os.path.realpath(sys.base_prefix))
PY
)" || [ -z "$python_runtime_root" ]; then
    echo "Could not resolve the system Python runtime." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! python_runtime_executable="$(
    DEVELOPER_DIR="$developer_root" PYTHONNOUSERSITE=1 /usr/bin/python3 -I - <<'PY'
import os
import sys

print(os.path.realpath(sys.executable))
PY
)" || [ -z "$python_runtime_executable" ]; then
    echo "Could not resolve the system Python executable." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  python_app_executable="$python_runtime_root/Resources/Python.app/Contents/MacOS/Python"
  if [ ! -f "$python_app_executable" ]; then
    python_app_executable=""
  fi
  local -a executable_command=("$@")
  if [ -f "$1" ]; then
    IFS= read -r first_executable_line <"$1" || true
    if [ "$first_executable_line" = '#!/usr/bin/python3' ]; then
      executable_command=("$python_runtime_executable" -I "$@")
    fi
  fi
  local -a command=(
    /usr/bin/env -C "$writable_root" -i
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    HOME="$verifier_home"
    CFFIXED_USER_HOME="$verifier_home"
    TMPDIR="$verifier_home/tmp/"
    LANG=en_US.UTF-8
    DEVELOPER_DIR="$developer_root"
    PYTHONNOUSERSITE=1
    xcrun_nocache=1
    EASYSPLAT_RELEASE_VERIFY_TOKEN="$verification_token"
    "${executable_command[@]}"
  )

  case "$network_policy" in
    allow) network_rule="(allow network*)" ;;
    deny) network_rule="(deny network* (with send-signal SIGKILL))" ;;
    *)
      echo "Unknown release-verifier network policy: $network_policy" >&2
      cleanup_release_verifier_processes || true
      return 1
      ;;
  esac
  if [ ! -x /usr/bin/sandbox-exec ]; then
    echo "Strict release verification requires /usr/bin/sandbox-exec." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  sandbox_profile="$verifier_home/release-verifier.sb"
  if ! "$python_runtime_executable" -I - \
    "$sandbox_profile" "$network_rule" "$verifier_home" "$writable_root" "$bundle_root" \
    "$darwin_user_temp" "$python_runtime_root" "$python_runtime_executable" \
    "$python_app_executable" "$developer_root" "$invoking_cwd" "$invoking_home" \
    "$verification_token" "$@" <<'PY'
import json
import os
import re
import stat
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
network_rule = sys.argv[2]
writable_roots = [os.path.realpath(value) for value in sys.argv[3:5]]
bundle_root = os.path.realpath(sys.argv[5])
replacement_parent = os.path.realpath(sys.argv[6]).rstrip("/") + "/TemporaryItems"
python_runtime_root = os.path.realpath(sys.argv[7])
python_runtime_executable = os.path.realpath(sys.argv[8])
python_app_executable = os.path.realpath(sys.argv[9]) if sys.argv[9] else ""
developer_root = os.path.realpath(sys.argv[10])
invoking_cwd = os.path.realpath(sys.argv[11])
invoking_home = os.path.realpath(sys.argv[12]) if sys.argv[12] else ""
verification_token = sys.argv[13]
command = sys.argv[14:]
if not re.fullmatch(
    r"easysplat-release-verify-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
    verification_token,
):
    raise SystemExit("Release-verifier sandbox marker is invalid.")
marker_suffix = verification_token.removeprefix("easysplat-release-verify-")
deny_marker = f"com.easysplat.releaseverify.{marker_suffix}.deny"
allow_marker = f"com.easysplat.releaseverify.{marker_suffix}.allow"
if not command:
    raise SystemExit("Release-verifier sandbox has no executable command.")
executable = os.path.realpath(command[0])
process_name = Path(executable).name
if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", process_name):
    raise SystemExit("Release-verifier executable has an unsafe process name.")
replacement_pattern = (
    "^" + re.escape(replacement_parent) + "/NSIRD_" + re.escape(process_name) + "_.*$"
)
hex_character = r"[0-9A-Fa-f]"
uuid_pattern = (
    hex_character * 8 + "-" + hex_character * 4 + "-"
    + hex_character * 4 + "-" + hex_character * 4 + "-"
    + hex_character * 12
)
verification_scratch_patterns = [
    "^" + re.escape(os.path.dirname(replacement_parent))
    + "/" + re.escape(prefix)
    + uuid_pattern + r"(/.*)?$"
    for prefix in (
        "EasySplat-selected-lineage-",
        "EasySplat-video-lineage-",
        "EasySplat-finished-dataset-replay-",
    )
]
verification_scratch_filters = " ".join(
    f'(regex #"{pattern}")' for pattern in verification_scratch_patterns
)

blocked_directory_roots = {
    "/",
    "/Applications",
    "/Library",
    "/Users",
    "/Volumes",
    "/private",
    "/private/etc",
    "/private/var",
    "/private/var/db",
    "/private/var/folders",
    "/private/tmp",
    "/etc",
    "/tmp",
    "/var",
}
if invoking_home:
    blocked_directory_roots.add(invoking_home)
    blocked_directory_roots.update(
        os.path.join(invoking_home, name)
        for name in ("Desktop", "Documents", "Downloads", "Library")
    )

def require_narrow_directory(path, label):
    resolved = os.path.realpath(path)
    if resolved in blocked_directory_roots:
        raise SystemExit(f"{label} would expose an unsafe broad filesystem root: {resolved}")
    return resolved

for index, value in enumerate(writable_roots):
    writable_roots[index] = require_narrow_directory(value, "Release-verifier isolated root")
bundle_root = require_narrow_directory(bundle_root, "Release-verifier app bundle")
if not bundle_root.endswith(".app"):
    raise SystemExit("Release-verifier app bundle is not an app bundle.")
python_runtime_root = require_narrow_directory(
    python_runtime_root,
    "System Python runtime",
)
def is_within(path, root):
    return os.path.commonpath((path, root)) == root

allowed_python_roots = (
    developer_root,
    "/System",
    "/Library/Apple",
)
if not any(is_within(python_runtime_root, root) for root in allowed_python_roots):
    raise SystemExit("Release-verifier Python resolved outside an approved system toolchain.")
if not any(is_within(python_runtime_executable, root) for root in allowed_python_roots):
    raise SystemExit("Release-verifier Python executable resolved outside an approved system toolchain.")
if python_app_executable:
    if not any(is_within(python_app_executable, root) for root in allowed_python_roots):
        raise SystemExit("Release-verifier Python app helper resolved outside an approved system toolchain.")
    if not os.path.isfile(python_app_executable):
        raise SystemExit("Release-verifier Python app helper is unavailable.")
if not os.path.isfile(executable):
    raise SystemExit("Release-verifier executable is not an ordinary file.")

read_subpaths = [
    "/System",
    "/usr/bin",
    "/usr/lib",
    "/usr/libexec",
    "/usr/share",
    "/usr/sbin",
    "/bin",
    "/sbin",
    "/dev/fd",
    "/Library/Apple/usr",
    "/private/var/db/timezone",
    python_runtime_root,
    bundle_root,
    *writable_roots,
]
read_literals = [
    "/dev/null",
    "/dev/autofs_nowait",
    "/dev/random",
    "/dev/urandom",
    "/private/etc/group",
    "/private/etc/hosts",
    "/private/etc/localtime",
    "/private/etc/passwd",
    "/private/etc/protocols",
    "/private/etc/resolv.conf",
    "/private/etc/services",
    "/private/etc/ssl/cert.pem",
    "/private/var/select/sh",
    "/private/var/run/resolv.conf",
    "/var/select/sh",
    executable,
    python_runtime_executable,
]
if python_app_executable:
    read_literals.append(python_app_executable)

path_options = {
    "--input-manifest": "file",
    "--input-root": "input",
    "--app-bundle": "input",
}
seen_options = set()
index = 1
while index < len(command):
    option = command[index]
    kind = path_options.get(option)
    if kind is None:
        index += 1
        continue
    if option in seen_options:
        raise SystemExit(f"Release-verifier option appears more than once: {option}")
    seen_options.add(option)
    if index + 1 >= len(command):
        raise SystemExit(f"Release-verifier option has no value: {option}")
    raw_path = command[index + 1]
    if not os.path.isabs(raw_path):
        raise SystemExit(f"Release-verifier input path must be absolute: {option}")
    path = os.path.realpath(raw_path)
    try:
        metadata = os.stat(path)
    except OSError as error:
        raise SystemExit(f"Release-verifier input is unavailable: {option}: {error}") from error
    if kind == "file" and not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"Release-verifier input must be a regular file: {option}")
    if option == "--app-bundle" and path != bundle_root:
        raise SystemExit(
            "Release-verifier app bundle does not match the sandboxed read-only root."
        )
    if stat.S_ISDIR(metadata.st_mode):
        read_subpaths.append(require_narrow_directory(path, option))
    elif stat.S_ISREG(metadata.st_mode):
        read_literals.append(path)
    else:
        raise SystemExit(f"Release-verifier input has an unsupported file type: {option}")
    index += 2
if "--app-bundle" not in seen_options:
    raise SystemExit("Release-verifier command does not name the app bundle it attests.")

def unique(values):
    return list(dict.fromkeys(values))

read_filters = [
    *(f"(subpath {json.dumps(path)})" for path in unique(read_subpaths)),
    *(f"(literal {json.dumps(path)})" for path in unique(read_literals)),
]
process_executables = [
    "/bin/cat",
    "/usr/bin/env",
    "/usr/bin/file",
    "/usr/bin/touch",
    executable,
    python_runtime_executable,
]
if python_app_executable:
    process_executables.append(python_app_executable)
# The helpers live at a fixed path inside the bundle, so the profile names them
# directly rather than deriving them from a document the run supplied.
toolchain_bin = os.path.join(bundle_root, "Contents", "Helpers", "bin")
process_executables.extend(
    os.path.join(toolchain_bin, name)
    for name in ("colmap", "ffmpeg", "easysplat-train")
)
process_filters = " ".join(
    f"(literal {json.dumps(path)})" for path in unique(process_executables)
)
metadata_paths = ["/tmp", "/var"]
metadata_directories = {*read_subpaths, replacement_parent, invoking_cwd}
for path in [*read_subpaths, *read_literals, replacement_parent, invoking_cwd]:
    current = Path(path) if path in metadata_directories else Path(path).parent
    while True:
        metadata_paths.append(str(current))
        if current.parent == current:
            break
        current = current.parent
metadata_filters = " ".join(
    f"(literal {json.dumps(path)})" for path in unique(metadata_paths)
)
directory_data_paths = ["/"]
for path in read_subpaths:
    current = Path(path)
    while True:
        directory_data_paths.append(str(current))
        if current.parent == current:
            break
        current = current.parent
for path in read_literals:
    current = Path(path).parent
    while True:
        directory_data_paths.append(str(current))
        if current.parent == current:
            break
        current = current.parent
directory_data_filters = " ".join(
    f"(literal {json.dumps(path)})" for path in unique(directory_data_paths)
)
write_filters = " ".join(
    f"(subpath {json.dumps(path)})" for path in writable_roots
)
profile_path.write_text(
    "\n".join([
        "(version 1)",
        "(deny default)",
        network_rule,
        '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/syslog")))',
        "(allow process-fork)",
        f"(allow process-exec {process_filters})",
        # Descriptor-bound project publication and runtime loading open each
        # declared directory chain without following links. Directory-data
        # rights remain literal, so sibling file contents stay unreadable.
        f"(allow file-read-data {directory_data_filters})",
        f"(allow file-read-metadata {metadata_filters})",
        f"(allow file-read* {' '.join(read_filters)})",
        f'(allow file-read* (regex #"{replacement_pattern}"))',
        f"(allow file-read* {verification_scratch_filters})",
        f"(allow file-write* {write_filters})",
        '(allow file-write-data (literal "/dev/null"))',
        f'(allow file-write-create file-write-unlink (regex #"{replacement_pattern}"))',
        f"(allow file-write* {verification_scratch_filters})",
        "(allow mach-lookup)",
        f"(deny mach-lookup (global-name {json.dumps(deny_marker)}))",
        f"(allow mach-lookup (global-name {json.dumps(allow_marker)}))",
        '(deny mach-lookup (global-name "com.apple.cfprefsd.agent"))',
        '(deny mach-lookup (global-name "com.apple.cfprefsd.daemon"))',
        '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))',
        '(deny mach-lookup (global-name "com.apple.lsd.mapdb"))',
        '(deny mach-lookup (global-name "com.apple.lsd.modifydb"))',
        '(deny mach-lookup (global-name "com.apple.runningboard"))',
        '(deny mach-lookup (global-name "com.apple.runningboardd"))',
        "(allow ipc-posix*)",
        "(allow sysctl-read)",
        "(allow iokit-open)",
        "(allow signal)",
        "",
    ]),
    encoding="utf-8",
)
PY
  then
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! chmod 600 "$sandbox_profile"; then
    cleanup_release_verifier_processes || true
    return 1
  fi

  if ! /usr/bin/sandbox-exec -f "$sandbox_profile" /usr/bin/touch \
    "$verifier_home/tmp/write-probe"; then
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! outside_read_probe="$(/usr/bin/mktemp \
    "/private/tmp/easysplat-release-verifier-read.XXXXXX")" \
    || ! chmod 600 "$outside_read_probe" \
    || ! printf '%s\n' "release-verifier-secret-probe" >"$outside_read_probe"; then
    rm -f "$outside_read_probe"
    cleanup_release_verifier_processes || true
    return 1
  fi
  if /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /bin/cat "$outside_read_probe" >/dev/null 2>&1; then
    rm -f "$outside_read_probe"
    echo "Release-verifier sandbox allowed a read outside its isolated roots." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! rm -f "$outside_read_probe"; then
    cleanup_release_verifier_processes || true
    return 1
  fi
  outside_read_probe=""
  outside_write_probe="/private/tmp/easysplat-release-verifier-outside-${PPID}-$$-${RANDOM}"
  rm -f "$outside_write_probe"
  if /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /usr/bin/touch "$outside_write_probe" 2>/dev/null; then
    rm -f "$outside_write_probe"
    echo "Release-verifier sandbox allowed a write outside its isolated roots." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if [ -e "$outside_write_probe" ]; then
    rm -f "$outside_write_probe"
    echo "Release-verifier sandbox left an outside-root write probe." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  bundle_write_probe="$bundle_root/Contents/.easysplat-release-verifier-probe"
  if /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /usr/bin/touch "$bundle_write_probe" 2>/dev/null || [ -e "$bundle_write_probe" ]; then
    rm -f "$bundle_write_probe"
    echo "Release-verifier sandbox allowed a write into the attested app bundle." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi

  if [ "$network_policy" = "deny" ]; then
    set +e
    (
      cd "$verifier_home" || exit 1
      /usr/bin/sandbox-exec -f "$sandbox_profile" "$python_runtime_executable" -I - \
        >/dev/null 2>&1 <<'PY'
import socket

probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.connect(("127.0.0.1", 9))
except OSError:
    pass
finally:
    probe.close()
PY
    ) >/dev/null 2>&1
    network_probe_status=$?
    set -e
    if [ "$network_probe_status" -ne 137 ]; then
      echo "Offline release-verifier sandbox did not fail closed on a network attempt." >&2
      cleanup_release_verifier_processes || true
      return 1
    fi
  fi

  group_file="/private/tmp/${verification_token}.process-group"
  rm -f "$group_file"
  E2E_VERIFIER_GROUP_FILE="$group_file"
  easysplat_supervise_process_group \
    "$group_file" \
    /usr/bin/sandbox-exec -f "$sandbox_profile" "${command[@]}" &
  E2E_VERIFIER_SUPERVISOR_PID=$!
  if ! easysplat_wait_for_supervised_process_group \
    "$E2E_VERIFIER_SUPERVISOR_PID" "$group_file"; then
    echo "Release verifier could not publish its supervised process group." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  current_epoch="$(/bin/date +%s)"
  deadline_epoch=$((current_epoch + timeout_seconds))
  while kill -0 "$E2E_VERIFIER_SUPERVISOR_PID" 2>/dev/null; do
    if supervisor_state="$(
      easysplat_read_supervised_process_group_state "$group_file" 2>/dev/null
    )" && [[ "$supervisor_state" == quiescent:* ]]; then
      break
    fi
    current_epoch="$(/bin/date +%s)"
    if [ "$current_epoch" -ge "$deadline_epoch" ]; then
      timed_out=1
      break
    fi
    /bin/sleep 0.25
  done
  if [ "$timed_out" -eq 1 ]; then
    echo "Release verifier exceeded its ${timeout_seconds}-second lane timeout." >&2
    if ! cleanup_release_verifier_processes; then
      return 1
    fi
    return 124
  fi
  set +e
  wait "$E2E_VERIFIER_SUPERVISOR_PID"
  command_status=$?
  set -e
  E2E_VERIFIER_SUPERVISOR_PID=""
  if ! easysplat_cleanup_supervised_process_group "" "$group_file"; then
    cleanup_release_verifier_processes || true
    return 1
  fi
  E2E_VERIFIER_GROUP_FILE=""

  if ! remaining_processes="$(
    easysplat_audit_and_drain_verification_processes "$E2E_VERIFIER_TOKEN"
  )"; then
    echo "Release verification could not prove residual-process quiescence." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  if [ "$remaining_processes" = contained ]; then
    echo "Release verification left a detached pipeline or toolchain worker process." >&2
    E2E_VERIFIER_TOKEN=""
    return 1
  fi
  if [ "$remaining_processes" != clean ]; then
    echo "Release verification returned invalid residual-process evidence." >&2
    cleanup_release_verifier_processes || true
    return 1
  fi
  E2E_VERIFIER_TOKEN=""
  return "$command_status"
}
