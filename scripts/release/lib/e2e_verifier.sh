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
  local cache_root=$4
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
  if ! mkdir -p "$verifier_home/tmp" "$writable_root" "$cache_root" \
    || ! chmod 700 "$verifier_home" "$verifier_home/tmp"; then
    cleanup_release_verifier_processes || true
    return 1
  fi
  if ! verifier_home="$(cd "$verifier_home" && pwd -P)" \
    || ! writable_root="$(cd "$writable_root" && pwd -P)" \
    || ! cache_root="$(cd "$cache_root" && pwd -P)" \
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
    "$sandbox_profile" "$network_rule" "$verifier_home" "$writable_root" "$cache_root" \
    "$darwin_user_temp" "$python_runtime_root" "$python_runtime_executable" \
    "$python_app_executable" "$developer_root" "$invoking_cwd" "$invoking_home" \
    "$verification_token" "$@" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
network_rule = sys.argv[2]
isolated_roots = [os.path.realpath(value) for value in sys.argv[3:6]]
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

for index, value in enumerate(isolated_roots):
    isolated_roots[index] = require_narrow_directory(value, "Release-verifier isolated root")
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
    *isolated_roots,
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
    "--public-key-file": "file",
    "--bootstrap-manifest": "file",
    "--bootstrap-core-archive": "file",
    "--expected-manifest": "file",
}
scalar_options = {"--expected-manifest-file-sha256"}
seen_options = set()
index = 1
while index < len(command):
    option = command[index]
    kind = path_options.get(option)
    if kind is None and option not in scalar_options:
        index += 1
        continue
    if option in seen_options:
        raise SystemExit(f"Release-verifier option appears more than once: {option}")
    seen_options.add(option)
    if index + 1 >= len(command):
        raise SystemExit(f"Release-verifier option has no value: {option}")
    if option in scalar_options:
        value = command[index + 1]
        if not re.fullmatch(r"[0-9A-Fa-f]{64}", value):
            raise SystemExit(
                "Release-verifier expected-manifest digest must be a SHA-256 hex value."
            )
        index += 2
        continue
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
    if stat.S_ISDIR(metadata.st_mode):
        read_subpaths.append(require_narrow_directory(path, option))
    elif stat.S_ISREG(metadata.st_mode):
        read_literals.append(path)
    else:
        raise SystemExit(f"Release-verifier input has an unsupported file type: {option}")
    index += 2

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
    "/usr/bin/unzip",
    "/usr/bin/zipinfo",
    executable,
    python_runtime_executable,
]
if python_app_executable:
    process_executables.append(python_app_executable)
expected_manifest_path = None
expected_manifest_sha256 = None
index = 1
while index < len(command):
    if command[index] == "--expected-manifest" and index + 1 < len(command):
        expected_manifest_path = os.path.realpath(command[index + 1])
    elif (
        command[index] == "--expected-manifest-file-sha256"
        and index + 1 < len(command)
    ):
        expected_manifest_sha256 = command[index + 1].lower()
    index += 1
if expected_manifest_path is not None and expected_manifest_sha256 is not None:
    try:
        manifest_data = Path(expected_manifest_path).read_bytes()
        if hashlib.sha256(manifest_data).hexdigest() != expected_manifest_sha256:
            raise ValueError("file digest does not match the authenticated release input")
        manifest = json.loads(manifest_data)
        toolchain_version = manifest["version"]
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
    ) as error:
        raise SystemExit(
            f"Release-verifier expected manifest cannot define process rights: {error}"
        ) from error
    if not isinstance(toolchain_version, str) or not re.fullmatch(
        r"[0-9A-Za-z][0-9A-Za-z.+-]{0,63}", toolchain_version
    ):
        raise SystemExit("Release-verifier toolchain version is unsafe for process rights.")
    toolchain_bin = os.path.join(isolated_roots[2], toolchain_version, "bin")
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
write_filters = " ".join(
    f"(subpath {json.dumps(path)})" for path in isolated_roots
)
profile_path.write_text(
    "\n".join([
        "(version 1)",
        "(deny default)",
        network_rule,
        '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/syslog")))',
        "(allow process-fork)",
        f"(allow process-exec {process_filters})",
        # AMFI reads the root directory vnode while validating every launched
        # executable. This permits that one directory read, not descendants.
        '(allow file-read-data (literal "/"))',
        f"(allow file-read-metadata {metadata_filters})",
        f"(allow file-read* {' '.join(read_filters)})",
        f'(allow file-read* (regex #"{replacement_pattern}"))',
        f"(allow file-write* {write_filters})",
        '(allow file-write-data (literal "/dev/null"))',
        f'(allow file-write-create file-write-unlink (regex #"{replacement_pattern}"))',
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

cached_toolchain_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1]).resolve(strict=True)
receipts = list(root.rglob(".easysplat_toolchain_state.json"))
if len(receipts) != 1:
    raise SystemExit(f"Cached-only verification requires exactly one signed receipt (found {len(receipts)}).")
receipt = receipts[0]
receipt_metadata = receipt.lstat()
if not stat.S_ISREG(receipt_metadata.st_mode) or receipt_metadata.st_nlink != 1:
    raise SystemExit("Cached-only receipt must be an ordinary, non-hardlinked regular file.")
if stat.S_IMODE(receipt_metadata.st_mode) != 0o600:
    raise SystemExit("Cached-only receipt must use mode 0600.")

state = json.loads(receipt.read_text(encoding="utf-8"))
if state.get("schemaVersion") != 2:
    raise SystemExit("Cached-only receipt must use toolchain schema 2.")
manifest = state.get("signedManifest") or {}
manifest_version = manifest.get("version")
if not isinstance(manifest_version, str) or receipt.parent.parent != root or receipt.parent.name != manifest_version:
    raise SystemExit("Cached-only receipt is not stored under its exact signed toolchain version.")
core = [row for row in manifest.get("components", []) if row.get("name") == "macos-arm64-core"]
if len(core) != 1:
    raise SystemExit("Cached-only receipt has no unique signed core component.")
component = core[0]
if state.get("installedArtifacts") != {"macos-arm64-core": component.get("sha256")}:
    raise SystemExit("Cached-only receipt must attest exactly the signed core component.")
if set(state.get("installedCapabilities", [])) != set(component.get("capabilities", [])):
    raise SystemExit("Cached-only receipt capabilities do not match the signed core component.")
critical_hashes = component.get("criticalFileHashes")
contents = component.get("contents")
if not isinstance(critical_hashes, dict) or not isinstance(contents, list):
    raise SystemExit("Cached-only signed core lacks exact contents or critical hashes.")
if set(critical_hashes) != set(contents):
    raise SystemExit("Cached-only signed core does not hash every expected file exactly once.")

version_prefix = receipt.parent.relative_to(root).as_posix()
receipt_relative = receipt.relative_to(root).as_posix()
expected_files = {f"{version_prefix}/{relative}" for relative in contents} | {receipt_relative}
actual_files = set()
directory_records = {}
file_records = {}

def metadata_record(metadata):
    return {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": stat.S_IMODE(metadata.st_mode),
        "links": metadata.st_nlink,
        "size": metadata.st_size,
        "mtimeNs": metadata.st_mtime_ns,
        "ctimeNs": metadata.st_ctime_ns,
    }

for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
    current_path = Path(current)
    current_relative = current_path.relative_to(root).as_posix()
    current_metadata = current_path.lstat()
    if not stat.S_ISDIR(current_metadata.st_mode):
        raise SystemExit(f"Cached toolchain path is not a directory: {current_relative}")
    directory_records[current_relative] = metadata_record(current_metadata)
    for name in directory_names:
        child = current_path / name
        if child.is_symlink():
            raise SystemExit(f"Cached toolchain contains a symlinked directory: {child.relative_to(root)}")
    for name in file_names:
        path = current_path / name
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise SystemExit(f"Cached toolchain file is not ordinary and single-link: {relative}")
        actual_files.add(relative)
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        file_records[relative] = {**metadata_record(metadata), "sha256": digest.hexdigest()}

if actual_files != expected_files:
    missing = sorted(expected_files - actual_files)
    extra = sorted(actual_files - expected_files)
    raise SystemExit(f"Cached toolchain file closure changed (missing={missing}, extra={extra}).")
for relative, expected_digest in critical_hashes.items():
    parts = PurePosixPath(relative).parts
    if not parts or relative.startswith("/") or any(part in ("", ".", "..") for part in parts):
        raise SystemExit(f"Cached signed core contains an unsafe path: {relative}")
    installed_relative = f"{version_prefix}/{relative}"
    if file_records[installed_relative]["sha256"] != expected_digest:
        raise SystemExit(f"Cached critical-file hash differs from the signed manifest: {relative}")
for executable in ("bin/colmap", "bin/easysplat-train"):
    installed_relative = f"{version_prefix}/{executable}"
    if file_records[installed_relative]["mode"] != 0o755:
        raise SystemExit(f"Cached core executable does not use mode 0755: {executable}")

print(json.dumps({
    "schemaVersion": 1,
    "receipt": receipt_relative,
    "directories": directory_records,
    "files": file_records,
}, sort_keys=True, separators=(",", ":")))
PY
}
