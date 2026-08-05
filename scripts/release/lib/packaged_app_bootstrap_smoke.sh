# shellcheck shell=bash
# Production packaged-app bootstrap smoke. The caller owns the cleanup trap and
# process globals; this helper owns the lifecycle of the process it launches.

report_packaged_app_verification_failure() {
  local message=$1
  if declare -F report_release_verification_log_failure >/dev/null; then
    report_release_verification_log_failure \
      "$APP_WIRING_LOG" "packaged-app-wiring.log" "$message"
  else
    printf '%s\n' "$message" >&2
  fi
}

cleanup_packaged_app_verification_processes() {
  local cleanup_status=0
  local audit_result=""
  if easysplat_cleanup_supervised_process_group \
    "${APP_WIRING_PID:-}" \
    "${APP_WIRING_GROUP_FILE:-}"; then
    APP_WIRING_PID=""
    APP_WIRING_GROUP_FILE=""
  else
    cleanup_status=1
  fi
  if [ -n "$APP_WIRING_TOKEN" ]; then
    if ! audit_result="$(
      easysplat_audit_and_drain_verification_processes "$APP_WIRING_TOKEN"
    )"; then
      echo "error: could not prove packaged-app process quiescence." >&2
      cleanup_status=1
    elif [ "$audit_result" != clean ] && [ "$audit_result" != contained ]; then
      echo "error: packaged-app cleanup returned invalid containment evidence." >&2
      cleanup_status=1
    fi
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    APP_WIRING_TOKEN=""
  fi
  return "$cleanup_status"
}

packaged_app_executable_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

supplied_path = Path(sys.argv[1])
path = Path(os.path.realpath(supplied_path))
flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
flags |= getattr(os, "O_CLOEXEC", 0)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    permissions = stat.S_IMODE(before.st_mode)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_size <= 0
        or not permissions & stat.S_IXUSR
        or permissions & 0o7022
    ):
        raise SystemExit("Packaged executable is not a private immutable executable file.")
    digest = hashlib.sha256()
    consumed = 0
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        consumed += len(chunk)
    after = os.fstat(descriptor)
    visible = path.lstat()
    supplied_visible = supplied_path.lstat()
finally:
    os.close(descriptor)

def identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )

if (
    consumed != before.st_size
    or identity(before) != identity(after)
    or identity(before) != identity(visible)
    or identity(before) != identity(supplied_visible)
):
    raise SystemExit("Packaged executable changed while it was authenticated.")
print(json.dumps({
    "schemaVersion": 1,
    "path": str(path),
    "device": before.st_dev,
    "inode": before.st_ino,
    "uid": before.st_uid,
    "mode": permissions,
    "links": before.st_nlink,
    "byteCount": consumed,
    "modifiedNs": before.st_mtime_ns,
    "changedNs": before.st_ctime_ns,
    "sha256": digest.hexdigest(),
}, sort_keys=True, separators=(",", ":")))
PY
}

packaged_app_snapshot_value() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

value = json.loads(sys.argv[1]).get(sys.argv[2])
if not isinstance(value, (str, int)):
    raise SystemExit("Packaged verification snapshot field is missing.")
print(value)
PY
}

packaged_app_input_closure_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])

def identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )

def stable_regular(path, relative):
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    flags |= getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size <= 0:
            raise SystemExit(f"Packaged verification input contains an unsafe file: {relative}")
        digest = hashlib.sha256()
        consumed = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            consumed += len(chunk)
        after = os.fstat(descriptor)
        visible = path.lstat()
    finally:
        os.close(descriptor)
    if consumed != before.st_size or identity(before) != identity(after) or identity(before) != identity(visible):
        raise SystemExit(f"Packaged verification input changed while it was read: {relative}")
    return (
        ["file", relative, consumed, digest.hexdigest()],
        ["file", relative, *identity(before)],
    )

root_before = root.lstat()
closure_rows = []
identity_rows = []
byte_count = 0
file_count = 0
if stat.S_ISREG(root_before.st_mode):
    closure, recorded_identity = stable_regular(root, ".")
    closure_rows.append(closure)
    identity_rows.append(recorded_identity)
    byte_count = closure[2]
    file_count = 1
    kind = "file"
elif stat.S_ISDIR(root_before.st_mode):
    kind = "directory"
    identity_rows.append(["directory", ".", *identity(root_before)])
    for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        directory_names.sort()
        file_names.sort()
        current_path = Path(current)
        for name in directory_names:
            child = current_path / name
            metadata = child.lstat()
            relative = child.relative_to(root).as_posix()
            if not stat.S_ISDIR(metadata.st_mode):
                raise SystemExit(f"Packaged verification input contains an unsafe directory: {relative}")
            closure_rows.append(["directory", relative])
            identity_rows.append(["directory", relative, *identity(metadata)])
        for name in file_names:
            child = current_path / name
            relative = child.relative_to(root).as_posix()
            closure, recorded_identity = stable_regular(child, relative)
            closure_rows.append(closure)
            identity_rows.append(recorded_identity)
            byte_count += closure[2]
            file_count += 1
else:
    raise SystemExit("Packaged verification input must be one ordinary file or directory.")
root_after = root.lstat()
if identity(root_before) != identity(root_after):
    raise SystemExit("Packaged verification input root changed while it was inspected.")

def digest(value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()

print(json.dumps({
    "schemaVersion": 1,
    "kind": kind,
    "fileCount": file_count,
    "byteCount": byte_count,
    "closureSHA256": digest([kind, closure_rows]),
    "identitySHA256": digest([kind, identity_rows]),
}, sort_keys=True, separators=(",", ":")))
PY
}

packaged_app_attestation_snapshot() {
  if [ "$#" -ne 10 ] || [ -z "${10}" ]; then
    echo "Packaged attestation validation requires an input manifest." >&2
    return 1
  fi
  python3 - "$@" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

if len(sys.argv) != 11:
    raise SystemExit("Packaged attestation validation received an invalid contract.")
attestation_path = Path(sys.argv[1])
marker_path = Path(sys.argv[2])
input_path = Path(sys.argv[3])
project_path = Path(sys.argv[4])
executable_path = Path(sys.argv[5])
expected_app_version = sys.argv[6]
expected_token_sha256 = sys.argv[7]
expected_executable_sha256 = sys.argv[8]
expected_executable_bytes = sys.argv[9]
input_manifest_path = Path(sys.argv[10])

identity_fields = (
    "st_dev", "st_ino", "st_uid", "st_mode", "st_nlink", "st_size",
    "st_mtime_ns", "st_ctime_ns",
)

def stable_read(path, maximum_bytes, private=False):
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    flags |= getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum_bytes
        ):
            raise SystemExit(f"Unsafe packaged attestation dependency: {path.name}")
        if private and (
            stat.S_IMODE(before.st_mode) != 0o600
            or before.st_uid != os.geteuid()
        ):
            raise SystemExit(f"Packaged attestation is not owner-only: {path.name}")
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
        after = os.fstat(descriptor)
        visible = path.lstat()
    finally:
        os.close(descriptor)
    if len(payload) != before.st_size:
        raise SystemExit(f"Packaged attestation dependency was not read completely: {path.name}")
    if any(getattr(before, key) != getattr(after, key) for key in identity_fields):
        raise SystemExit(f"Packaged attestation dependency changed while read: {path.name}")
    if any(getattr(after, key) != getattr(visible, key) for key in identity_fields):
        raise SystemExit(f"Packaged attestation dependency path changed while read: {path.name}")
    return bytes(payload)

attestation = stable_read(attestation_path, 1024 * 1024, private=True)
marker_data = stable_read(marker_path, 64 * 1024, private=True)
metadata_data = stable_read(project_path / "project.json", 16 * 1024 * 1024)
input_manifest_data = stable_read(input_manifest_path, 64 * 1024)
try:
    text = attestation.decode("utf-8")
    marker = json.loads(marker_data)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"Packaged attestation is not valid UTF-8/JSON evidence: {error}")
if not text.endswith("\n") or "\r" in text or "\x00" in text:
    raise SystemExit("Packaged attestation has a non-canonical text encoding.")
lines = text[:-1].split("\n")
if not lines or lines[0] != "# EasySplat Packaged-App Release Attestation":
    raise SystemExit("Packaged attestation has an invalid header.")
fields = {}
for line in lines[1:]:
    if ": " not in line:
        raise SystemExit("Packaged attestation has an invalid field row.")
    label, value = line.split(": ", 1)
    if not label or label in fields:
        raise SystemExit(f"Packaged attestation duplicates field {label!r}.")
    fields[label] = value

def digest(payload):
    return hashlib.sha256(payload).hexdigest()

def canonical_path(path):
    return str(path.resolve(strict=True))

def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

input_manifest_sha256 = digest(input_manifest_data)

expected = {
    "Schema": "1",
    "Status": "passed",
    "App version": expected_app_version,
    "Release verification token SHA-256": expected_token_sha256,
    "Executable path SHA-256": digest(canonical_path(executable_path).encode("utf-8")),
    "Executable bytes": expected_executable_bytes,
    "Executable SHA-256": expected_executable_sha256,
    "Marker SHA-256": digest(marker_data),
    "Project root path SHA-256": digest(canonical_path(project_path).encode("utf-8")),
    "Project metadata SHA-256": digest(metadata_data),
    "Input path SHA-256": digest(canonical_path(input_path).encode("utf-8")),
    "Input manifest SHA-256": input_manifest_sha256,
    "Output path SHA-256": digest(marker["outputPlyPath"].encode("utf-8")),
    "Toolchain version JSON": canonical_json(expected_app_version),
    "Integrity policy": "signedAppBundle",
    "Installed capabilities JSON": canonical_json(
        ["geometry.colmap", "runtime.core", "training.msplat"]
    ),
    "Output bytes": str(marker["outputBytes"]),
    "Output vertices": str(marker["outputVertices"]),
    "Output format": marker["outputFormat"],
    "Output SHA-256": marker["outputSHA256"],
}
if marker.get("inputManifestSHA256") != input_manifest_sha256:
    raise SystemExit("Packaged marker does not bind the authenticated input manifest.")
variable_digests = {
    "Input digest",
    "Installed closure SHA-256",
    "Installation identity SHA-256",
}
# The bundled closure digest is computed from the tree, so the attestation must
# name it consistently rather than repeat a value the shell already knows.
variable_json = {"Installed component JSON"}
declared = set(expected) | variable_digests | variable_json
if set(fields) != declared:
    missing = sorted(declared - set(fields))
    extra = sorted(set(fields) - declared)
    raise SystemExit(f"Packaged attestation field closure changed (missing={missing}, extra={extra}).")
for label, expected_value in expected.items():
    if fields[label] != expected_value:
        raise SystemExit(f"Packaged attestation field does not match {label!r}.")
for label in variable_digests:
    if re.fullmatch(r"[0-9a-f]{64}", fields[label]) is None:
        raise SystemExit(f"Packaged attestation has an invalid digest for {label!r}.")
if fields["Installed component JSON"] != canonical_json({
    "name": "bundled-helpers",
    "sha256": fields["Installed closure SHA-256"],
}):
    raise SystemExit("Packaged attestation does not attest exactly the bundled helper closure.")
print(digest(attestation))
PY
}

packaged_app_smoke_has_substantive_evidence() {
  local root=${1:-}
  [ -n "$root" ] || return 1
  [ -e "$root/ReleaseVerificationHome/release-verification-pipeline-passed.json" ] \
    || [ -n "$(find \
      "$root/ReleaseVerificationHome/Documents/EasySplat Projects" \
      -mindepth 1 -print -quit 2>/dev/null || true)" ]
}

validate_packaged_app_bootstrap_result() {
  if [ "$#" -ne 8 ] || [ -z "${8}" ]; then
    echo "Packaged app bootstrap validation requires an input manifest." >&2
    return 1
  fi
  local success_marker=$1
  local app_bundle=$2
  local input_path=$3
  local project_root=$4
  local expected_token_sha256=$5
  local expected_app_version=$6
  local expected_executable_snapshot=$7
  local input_manifest_path=${8}

  if ! python3 - "$success_marker" "$app_bundle" \
    "$input_path" "$project_root" \
    "$expected_token_sha256" "$expected_app_version" \
    "$expected_executable_snapshot" "$input_manifest_path" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

marker_path, app_bundle, input_path, project_root = map(Path, sys.argv[1:5])
expected_token_sha256 = sys.argv[5]
expected_app_version = sys.argv[6]
expected_executable = json.loads(sys.argv[7])
input_manifest_path = Path(sys.argv[8])
metadata = marker_path.lstat()
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
    raise SystemExit("Packaged app marker must be an ordinary, non-hardlinked regular file.")
if stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("Packaged app marker must use mode 0600.")
marker = json.loads(marker_path.read_text(encoding="utf-8"))
expected_marker_keys = {
    "schemaVersion",
    "releaseVerificationTokenSHA256",
    "appVersion",
    "executablePath",
    "executableBytes",
    "executableSHA256",
    "toolchainRoot",
    "requestedCapabilities",
    "inputPath",
    "inputManifestSHA256",
    "projectRoot",
    "outputPlyPath",
    "outputBytes",
    "outputVertices",
    "outputFormat",
    "outputSHA256",
}
if set(marker) != expected_marker_keys or marker.get("schemaVersion") != 3:
    raise SystemExit("Installed app wrote an unsupported release-verification marker.")
if marker.get("releaseVerificationTokenSHA256") != expected_token_sha256:
    raise SystemExit("Installed-app marker is not bound to this supervised verification run.")
if marker.get("appVersion") != expected_app_version:
    raise SystemExit("Installed-app marker does not record the expected app version.")
if marker.get("executablePath") != expected_executable.get("path"):
    raise SystemExit("Installed-app marker does not identify the supervised packaged executable.")
if marker.get("executableBytes") != expected_executable.get("byteCount"):
    raise SystemExit("Installed-app marker executable size does not match the supervised executable.")
if marker.get("executableSHA256") != expected_executable.get("sha256"):
    raise SystemExit("Installed-app marker executable digest does not match the supervised executable.")
# The app must have run the tools sealed inside its own bundle. Any other root
# means it found tools somewhere a user's install would not have them.
expected_helpers = (app_bundle / "Contents/Helpers").resolve()
if marker.get("toolchainRoot") != str(expected_helpers):
    raise SystemExit("Installed-app marker does not identify the bundled helper root.")
if marker.get("inputPath") != str(input_path.resolve()):
    raise SystemExit("Installed-app marker does not record the isolated verifier input.")
expected_input_manifest_sha256 = hashlib.sha256(
    input_manifest_path.read_bytes()
).hexdigest()
if marker.get("inputManifestSHA256") != expected_input_manifest_sha256:
    raise SystemExit("Installed-app marker does not bind the input manifest.")
bundled_capabilities = {"runtime.core", "geometry.colmap", "training.msplat"}
if not set(marker.get("requestedCapabilities", [])) <= bundled_capabilities:
    raise SystemExit("Installed app requested a capability its bundle does not carry.")

project = Path(marker.get("projectRoot", ""))
output = Path(marker.get("outputPlyPath", ""))
if project.parent.resolve() != project_root.resolve() or project.suffix != ".easysplatproj":
    raise SystemExit("Installed-app marker does not identify one isolated EasySplat project.")
if output != project / "Output" / "splat.ply":
    raise SystemExit("Installed-app marker does not identify the canonical project PLY.")
projects = list(project_root.glob("*.easysplatproj"))
if projects != [project] or not (project / "project.json").is_file():
    raise SystemExit("Installed app did not create exactly one durable current project.")

output_metadata = output.lstat()
if not stat.S_ISREG(output_metadata.st_mode) or output_metadata.st_nlink != 1:
    raise SystemExit("Installed-app output must be an ordinary single-link regular file.")
output_mode = stat.S_IMODE(output_metadata.st_mode)
if output_mode & 0o600 != 0o600 or output_mode & 0o7133:
    raise SystemExit(
        "Installed-app output must be owner-readable/writable and never "
        "group/world-writable, executable, or special-mode."
    )
payload = output.read_bytes()
if marker.get("outputBytes") != len(payload):
    raise SystemExit("Installed-app marker output size does not match the published PLY.")
if marker.get("outputSHA256") != hashlib.sha256(payload).hexdigest():
    raise SystemExit("Installed-app marker output digest does not match the published PLY.")
header_end = payload.find(b"end_header\n")
if header_end < 0 or header_end + len(b"end_header\n") > 64 * 1024:
    raise SystemExit("Installed-app output has no bounded PLY header.")
header = payload[:header_end + len(b"end_header\n")].decode("ascii")
format_rows = [line.split() for line in header.splitlines() if line.startswith("format ")]
vertex_rows = [line.split() for line in header.splitlines() if line.startswith("element vertex ")]
if len(format_rows) != 1 or len(vertex_rows) != 1:
    raise SystemExit("Installed-app output has ambiguous PLY header evidence.")
if marker.get("outputFormat") != format_rows[0][1]:
    raise SystemExit("Installed-app marker output format does not match the published PLY.")
if marker.get("outputVertices") != int(vertex_rows[0][2]) or marker["outputVertices"] <= 0:
    raise SystemExit("Installed-app marker vertex count does not match the published PLY.")
PY
  then
    return 1
  fi
}
run_packaged_app_bootstrap_smoke() {
  local source_input=${1:-}
  local verifier_home="$SMOKE_INSTALL_ROOT/ReleaseVerificationHome"
  local input_root="$SMOKE_INSTALL_ROOT/ReleaseVerificationInput"
  local input_path=""
  local staged_input_path=""
  local input_manifest=""
  local project_root="$verifier_home/Documents/EasySplat Projects"
  local project=""
  local success_marker="$verifier_home/release-verification-pipeline-passed.json"
  local packaged_attestation="$verifier_home/packaged-app-attestation.md"
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
  local verification_token=""
  local remaining_processes=""
  local app_status=0
  local network_probe_status=0
  local group_file=""
  local darwin_user_temp=""
  local first_executable_line=""
  local expected_executable_snapshot=""
  local final_executable_snapshot=""
  local expected_executable_sha256=""
  local expected_executable_bytes=""
  local verification_token_sha256=""
  local source_input_snapshot=""
  local staged_input_snapshot=""
  local final_source_input_snapshot=""
  local final_staged_input_snapshot=""
  local initial_packaged_attestation_snapshot=""
  local final_packaged_attestation_snapshot=""
  local preserved_packaged_attestation_snapshot=""
  local timeout_seconds="${EASYSPLAT_RELEASE_VERIFIER_TIMEOUT_SECONDS:-7200}"
  local deadline_epoch=0
  local current_epoch=0
  if [ -z "$source_input" ] || [ ! -e "$source_input" ]; then
    echo "Packaged-app verification requires a real release fixture." >&2
    return 1
  fi
  if [ -z "${PACKAGED_PROJECT_VERIFIER:-}" ] \
    || [ ! -f "$PACKAGED_PROJECT_VERIFIER" ] \
    || [ ! -x "$PACKAGED_PROJECT_VERIFIER" ]; then
    echo "Packaged-app verification requires an independent finished-project verifier." >&2
    return 1
  fi
  case "$timeout_seconds" in
    ''|0|0*|*[!0-9]*)
      echo "Packaged-app verification timeout must be a positive base-10 integer." >&2
      return 1
      ;;
  esac
  if [ "$timeout_seconds" -gt 86400 ]; then
    echo "Packaged-app verification timeout cannot exceed 86400 seconds." >&2
    return 1
  fi
  if ! declare -F easysplat_validate_release_verification_token >/dev/null \
    || ! declare -F easysplat_audit_and_drain_verification_processes >/dev/null \
    || ! declare -F easysplat_supervise_process_group >/dev/null \
    || ! declare -F easysplat_wait_for_supervised_process_group >/dev/null \
    || ! declare -F easysplat_cleanup_supervised_process_group >/dev/null; then
    echo "Packaged-app verification requires token-based process inspection." >&2
    return 1
  fi
  verification_token="easysplat-release-verify-$(uuidgen)"
  if ! easysplat_validate_release_verification_token "$verification_token"; then
    echo "Could not create a valid packaged-app verification token." >&2
    return 1
  fi
  APP_WIRING_TOKEN="$verification_token"
  PACKAGED_APP_ATTESTATION_PRESERVED=0

  if [ ! -x /usr/bin/sandbox-exec ]; then
    echo "Strict packaged-app verification requires /usr/bin/sandbox-exec." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! mkdir -p "$verifier_home/tmp" "$project_root" \
    || ! chmod 700 "$verifier_home"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! verifier_home="$(cd "$verifier_home" && pwd -P)" \
    || ! invoking_cwd="$(pwd -P)"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  project_root="$verifier_home/Documents/EasySplat Projects"
  project="$project_root/Release Verification.easysplatproj"
  success_marker="$verifier_home/release-verification-pipeline-passed.json"
  packaged_attestation="$verifier_home/packaged-app-attestation.md"
  sandbox_profile="$verifier_home/packaged-app-verifier.sb"
  input_path="$input_root"
  input_manifest="$input_root/release-input-manifest.json"
  if [ -d "$source_input" ]; then
    staged_input_path="$input_root/Photos"
    if ! mkdir -p "$input_root" \
      || ! /usr/bin/ditto "$source_input" "$staged_input_path"; then
      cleanup_packaged_app_verification_processes || true
      return 1
    fi
  elif [ -f "$source_input" ]; then
    local source_name
    source_name="$(basename "$source_input")"
    case "$source_name" in
      *.*) ;;
      *)
        echo "Packaged-app video fixture must retain its media extension." >&2
        cleanup_packaged_app_verification_processes || true
        return 1
        ;;
    esac
    if ! mkdir -p "$input_root"; then
      cleanup_packaged_app_verification_processes || true
      return 1
    fi
    staged_input_path="$input_root/$source_name"
    if ! /usr/bin/ditto "$source_input" "$staged_input_path"; then
      cleanup_packaged_app_verification_processes || true
      return 1
    fi
  else
    echo "Packaged-app release fixture must be an ordinary file or directory." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! python3 - "$input_manifest" "$staged_input_path" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
staged_input = Path(sys.argv[2])
if staged_input.is_dir():
    document = {"photoFolder": staged_input.name, "schemaVersion": 1, "videos": []}
else:
    document = {"photoFolder": None, "schemaVersion": 1, "videos": [staged_input.name]}
manifest_path.write_text(
    json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY
  then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! python3 - "$source_input" "$staged_input_path" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

def stable_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size <= 0:
            raise SystemExit(f"Release fixture contains an unsafe file: {path}")
        digest = hashlib.sha256()
        consumed = 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            consumed += len(chunk)
        after = os.fstat(fd)
        visible = os.lstat(path)
        identity = lambda value: (
            value.st_dev, value.st_ino, value.st_nlink, value.st_mode,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns,
        )
        if consumed != before.st_size or identity(before) != identity(after) or identity(before) != identity(visible):
            raise SystemExit(f"Release fixture changed while it was copied: {path}")
        return (before.st_size, digest.hexdigest())
    finally:
        os.close(fd)

def snapshot(root):
    root = Path(root)
    metadata = root.lstat()
    if stat.S_ISREG(metadata.st_mode):
        return ("file", stable_file(root))
    if not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit("Release fixture must be one ordinary file or directory.")
    rows = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        current_path = Path(current)
        for name in directories:
            child = current_path / name
            child_metadata = child.lstat()
            if not stat.S_ISDIR(child_metadata.st_mode):
                raise SystemExit(f"Release fixture contains a linked or special directory: {child}")
            rows.append(("directory", child.relative_to(root).as_posix()))
        for name in files:
            child = current_path / name
            rows.append(("file", child.relative_to(root).as_posix(), *stable_file(child)))
    return ("directory", tuple(rows))

if snapshot(sys.argv[1]) != snapshot(sys.argv[2]):
    raise SystemExit("Staged packaged-app input does not exactly match the release fixture.")
PY
  then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! source_input_snapshot="$(packaged_app_input_closure_snapshot "$source_input")" \
    || ! staged_input_snapshot="$(packaged_app_input_closure_snapshot "$staged_input_path")"; then
    echo "Could not record stable packaged-app input closure evidence." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if [ "$(packaged_app_snapshot_value "$source_input_snapshot" closureSHA256)" \
       != "$(packaged_app_snapshot_value "$staged_input_snapshot" closureSHA256)" ] \
    || [ "$(packaged_app_snapshot_value "$source_input_snapshot" byteCount)" \
         != "$(packaged_app_snapshot_value "$staged_input_snapshot" byteCount)" ] \
    || [ "$(packaged_app_snapshot_value "$source_input_snapshot" fileCount)" \
         != "$(packaged_app_snapshot_value "$staged_input_snapshot" fileCount)" ]; then
    echo "Staged packaged-app input does not exactly match the release fixture closure." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! darwin_user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" \
    || [ -z "$darwin_user_temp" ]; then
    echo "Could not resolve the Foundation replacement directory." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! developer_root="$(
    /usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p
  )" \
    || [ -z "$developer_root" ]; then
    echo "Could not resolve the active Apple developer toolchain." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! developer_root="$(cd "$developer_root" && pwd -P)" \
    || ! developer_root_owner="$(/usr/bin/stat -f '%u' "$developer_root")" \
    || ! developer_root_mode="$(/usr/bin/stat -f '%Lp' "$developer_root")"; then
    echo "Could not authenticate the active Apple developer toolchain path." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  case "$developer_root" in
    /Applications/Xcode*.app/Contents/Developer|/Library/Developer/CommandLineTools) ;;
    *)
      echo "The active Apple developer toolchain is outside an approved system location." >&2
      cleanup_packaged_app_verification_processes || true
      return 1
      ;;
  esac
  if [ "$developer_root_owner" -ne 0 ] \
    || [ $((8#$developer_root_mode & 8#22)) -ne 0 ]; then
    echo "The active Apple developer toolchain must be root-owned and not group- or world-writable." >&2
    cleanup_packaged_app_verification_processes || true
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
    cleanup_packaged_app_verification_processes || true
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
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  python_app_executable="$python_runtime_root/Resources/Python.app/Contents/MacOS/Python"
  if [ ! -f "$python_app_executable" ]; then
    python_app_executable=""
  fi
  if ! "$python_runtime_executable" -I - "$sandbox_profile" "$verifier_home" \
    "$darwin_user_temp" "$INSTALLED_EXECUTABLE" "$INSTALLED_APP" \
    "$python_runtime_root" "$python_runtime_executable" "$developer_root" \
    "$python_app_executable" "$invoking_cwd" "$invoking_home" "$input_path" \
    "$verification_token" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
verifier_home = os.path.realpath(sys.argv[2])
replacement_parent = os.path.realpath(sys.argv[3]).rstrip("/") + "/TemporaryItems"
executable = os.path.realpath(sys.argv[4])
installed_app = os.path.realpath(sys.argv[5])
python_runtime_root = os.path.realpath(sys.argv[6])
python_runtime_executable = os.path.realpath(sys.argv[7])
developer_root = os.path.realpath(sys.argv[8])
python_app_executable = os.path.realpath(sys.argv[9]) if sys.argv[9] else ""
invoking_cwd = os.path.realpath(sys.argv[10])
invoking_home = os.path.realpath(sys.argv[11]) if sys.argv[11] else ""
input_path = os.path.realpath(sys.argv[12])
verification_token = sys.argv[13]
if not re.fullmatch(
    r"easysplat-release-verify-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
    verification_token,
):
    raise SystemExit("Packaged-app sandbox marker is invalid.")
marker_suffix = verification_token.removeprefix("easysplat-release-verify-")
deny_marker = f"com.easysplat.releaseverify.{marker_suffix}.deny"
allow_marker = f"com.easysplat.releaseverify.{marker_suffix}.allow"
process_name = Path(executable).name
if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", process_name):
    raise SystemExit("Packaged-app executable has an unsafe process name.")
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

verifier_home = require_narrow_directory(verifier_home, "Packaged-app verifier home")
installed_app = require_narrow_directory(installed_app, "Installed app")
if os.path.isdir(input_path):
    input_path = require_narrow_directory(input_path, "Packaged-app input")
elif not os.path.isfile(input_path):
    raise SystemExit("Packaged-app input is not an ordinary file or directory.")
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
    raise SystemExit("Packaged-app verifier Python resolved outside an approved system toolchain.")
if not any(is_within(python_runtime_executable, root) for root in allowed_python_roots):
    raise SystemExit("Packaged-app verifier Python executable resolved outside an approved system toolchain.")
if python_app_executable:
    if not any(is_within(python_app_executable, root) for root in allowed_python_roots):
        raise SystemExit("Packaged-app verifier Python app helper resolved outside an approved system toolchain.")
    if not os.path.isfile(python_app_executable):
        raise SystemExit("Packaged-app verifier Python app helper is unavailable.")
if not os.path.isfile(executable):
    raise SystemExit("Packaged-app executable is not an ordinary file.")
if os.path.commonpath((executable, installed_app)) != installed_app:
    raise SystemExit("Packaged-app executable escaped its installed app bundle.")

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
    verifier_home,
    installed_app,
]
if os.path.isdir(input_path):
    read_subpaths.append(input_path)
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
if os.path.isfile(input_path):
    read_literals.append(input_path)
read_filters = [
    *(f"(subpath {json.dumps(path)})" for path in dict.fromkeys(read_subpaths)),
    *(f"(literal {json.dumps(path)})" for path in dict.fromkeys(read_literals)),
]
toolchain_bin = os.path.join(installed_app, "Contents", "Helpers", "bin")
process_executables = [
    "/bin/cat",
    "/usr/bin/env",
    "/usr/bin/file",
    "/usr/bin/touch",
    executable,
    python_runtime_executable,
    *(os.path.join(toolchain_bin, name)
      for name in ("colmap", "ffmpeg", "easysplat-train")),
]
if python_app_executable:
    process_executables.append(python_app_executable)
process_filters = " ".join(
    f"(literal {json.dumps(path)})"
    for path in dict.fromkeys(process_executables)
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
    f"(literal {json.dumps(path)})" for path in dict.fromkeys(metadata_paths)
)
profile_path.write_text(
    "\n".join([
        "(version 1)",
        "(deny default)",
        "(deny network* (with send-signal SIGKILL))",
        '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/syslog")))',
        "(allow process-fork)",
        f"(allow process-exec {process_filters})",
        # AMFI reads the root directory vnode while validating every launched
        # executable. This permits that one directory read, not descendants.
        '(allow file-read-data (literal "/"))',
        f"(allow file-read-metadata {metadata_filters})",
        f"(allow file-read* {' '.join(read_filters)})",
        f'(allow file-read* (regex #"{replacement_pattern}"))',
        f"(allow file-write* (subpath {json.dumps(verifier_home)}))",
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
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! chmod 600 "$sandbox_profile"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi

  if ! /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /usr/bin/touch "$verifier_home/write-probe"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! outside_read_probe="$(/usr/bin/mktemp \
    "$SMOKE_INSTALL_ROOT/outside-read.XXXXXX")" \
    || ! chmod 600 "$outside_read_probe" \
    || ! printf '%s\n' "packaged-app-secret-probe" >"$outside_read_probe"; then
    rm -f "$outside_read_probe"
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /bin/cat "$outside_read_probe" >/dev/null 2>&1; then
    rm -f "$outside_read_probe"
    echo "Packaged-app sandbox allowed a read outside its isolated verifier roots." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! rm -f "$outside_read_probe"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  outside_read_probe=""
  if /usr/bin/sandbox-exec -f "$sandbox_profile" \
    /usr/bin/touch "$SMOKE_INSTALL_ROOT/outside-write-probe" 2>/dev/null; then
    echo "Packaged-app sandbox allowed a write outside the isolated verifier home." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  set +e
  (
    cd "$verifier_home" || exit 1
    /usr/bin/sandbox-exec -f "$sandbox_profile" \
      "$python_runtime_executable" -I - >/dev/null 2>&1 <<'PY'
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
    echo "Packaged-app sandbox did not fail closed on a network attempt." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  APP_WIRING_LOG="$verifier_home/packaged-app-wiring.log"
  if ! : >"$APP_WIRING_LOG" || ! chmod 600 "$APP_WIRING_LOG"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  group_file="$SMOKE_INSTALL_ROOT/packaged-app-process-group"
  rm -f "$group_file"
  APP_WIRING_GROUP_FILE="$group_file"
  local -a app_command=("$INSTALLED_EXECUTABLE")
  if [ -f "$INSTALLED_EXECUTABLE" ]; then
    IFS= read -r first_executable_line <"$INSTALLED_EXECUTABLE" || true
    if [ "$first_executable_line" = '#!/usr/bin/python3' ]; then
      app_command=("$python_runtime_executable" -I "$INSTALLED_EXECUTABLE")
    fi
  fi
  if ! expected_executable_snapshot="$(
    packaged_app_executable_snapshot "$INSTALLED_EXECUTABLE"
  )"; then
    echo "Could not authenticate the installed executable immediately before supervision." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  expected_executable_sha256="$(
    packaged_app_snapshot_value "$expected_executable_snapshot" sha256
  )"
  expected_executable_bytes="$(
    packaged_app_snapshot_value "$expected_executable_snapshot" byteCount
  )"
  verification_token_sha256="$(
    printf '%s' "$verification_token" | shasum -a 256 | awk '{print $1}'
  )"
  easysplat_supervise_process_group \
    "$group_file" \
    /usr/bin/sandbox-exec -f "$sandbox_profile" \
      /usr/bin/env -C "$verifier_home" -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$verifier_home" \
      CFFIXED_USER_HOME="$verifier_home" \
      TMPDIR="$verifier_home/tmp" \
      DEVELOPER_DIR="$developer_root" \
      PYTHONNOUSERSITE=1 \
      xcrun_nocache=1 \
      EASYSPLAT_ISOLATED_UI_RUNNER=1 \
      EASYSPLAT_RELEASE_VERIFY_TOKEN="$verification_token" \
      EASYSPLAT_PROJECT_HOME_URL=https://release-verifier-poison.invalid/project \
      EASYSPLAT_LOCAL_TOOLCHAIN_ROOT=/release-verifier-poison/toolchain \
      EASYSPLAT_SKIP_TRAINING=1 \
      EASYSPLAT_STOP_AFTER_STAGE=sfmMapping \
      EASYSPLAT_CANDIDATE_ROUTE=da3 \
      EASYSPLAT_BENCHMARK_SEED=2147483647 \
      "${app_command[@]}" \
      --easysplat-release-verify-bundled-pipeline \
      --input-manifest "$input_manifest" \
      --input-root "$input_path" < /dev/null >"$APP_WIRING_LOG" 2>&1 &
  APP_WIRING_PID=$!
  if ! easysplat_wait_for_supervised_process_group \
    "$APP_WIRING_PID" "$group_file"; then
    echo "Packaged-app verifier could not publish its supervised process group." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi

  current_epoch="$(/bin/date +%s)"
  deadline_epoch=$((current_epoch + timeout_seconds))
  while true; do
    if [ -s "$success_marker" ]; then
      break
    fi
    if ! kill -0 "$APP_WIRING_PID" 2>/dev/null; then
      echo "Installed app exited before proving bundled-bootstrap production wiring." >&2
      report_packaged_app_verification_failure \
        "Packaged-app wiring smoke failed."
      cleanup_packaged_app_verification_processes || true
      return 1
    fi
    current_epoch="$(/bin/date +%s)"
    if [ "$current_epoch" -ge "$deadline_epoch" ]; then
      break
    fi
    sleep 0.25
  done
  if [ ! -s "$success_marker" ]; then
    echo "Installed app did not complete its packaged pipeline before the timeout." >&2
    report_packaged_app_verification_failure \
      "Packaged-app wiring smoke failed."
    cleanup_packaged_app_verification_processes || true
    return 1
  fi

  for _ in {1..120}; do
    kill -0 "$APP_WIRING_PID" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$APP_WIRING_PID" 2>/dev/null; then
    echo "Installed app did not terminate cleanly after completing its packaged pipeline." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  set +e
  wait "$APP_WIRING_PID"
  app_status=$?
  set -e
  APP_WIRING_PID=""
  if [ "$app_status" -ne 0 ]; then
    echo "Installed app exited unsuccessfully after writing its pipeline marker." >&2
    report_packaged_app_verification_failure \
      "Packaged-app wiring smoke failed."
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! final_executable_snapshot="$(
    packaged_app_executable_snapshot "$INSTALLED_EXECUTABLE"
  )" \
    || [ "$final_executable_snapshot" != "$expected_executable_snapshot" ]; then
    echo "Installed executable changed between supervision and clean exit." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! easysplat_cleanup_supervised_process_group "" "$group_file"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  APP_WIRING_GROUP_FILE=""

  if ! remaining_processes="$(
    easysplat_audit_and_drain_verification_processes "$APP_WIRING_TOKEN"
  )"; then
    echo "Packaged-app verification could not prove residual-process quiescence." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if [ "$remaining_processes" = contained ]; then
    echo "Packaged-app verification left a detached pipeline or toolchain worker process." >&2
    APP_WIRING_TOKEN=""
    return 1
  fi
  if [ "$remaining_processes" != clean ]; then
    echo "Packaged-app verification returned invalid residual-process evidence." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! validate_packaged_app_bootstrap_result \
    "$success_marker" \
    "$INSTALLED_APP" \
    "$input_path" \
    "$project_root" \
    "$verification_token_sha256" \
    "$EXPECTED_VERSION" \
    "$expected_executable_snapshot" \
    "$input_manifest"; then
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if [ -e "$packaged_attestation" ] \
    || [ -L "$packaged_attestation" ]; then
    echo "Packaged-app attestation destination must start absent." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! "$PACKAGED_PROJECT_VERIFIER" verify-packaged-project \
    --project "$project" \
    --input-manifest "$input_manifest" \
    --input-root "$input_path" \
    --marker "$success_marker" \
    --app-version "$EXPECTED_VERSION" \
    --expected-release-verification-token-sha256 "$verification_token_sha256" \
    --expected-executable "$INSTALLED_EXECUTABLE" \
    --expected-executable-sha256 "$expected_executable_sha256" \
    --expected-executable-bytes "$expected_executable_bytes" \
    --evidence "$packaged_attestation" \
    >>"$APP_WIRING_LOG" 2>&1; then
    echo "Independent verification rejected the packaged app's finished project." >&2
    report_packaged_app_verification_failure \
      "Packaged-app finished-project verification failed."
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! initial_packaged_attestation_snapshot="$(
    packaged_app_attestation_snapshot \
      "$packaged_attestation" "$success_marker" \
      "$input_path" "$project" "$INSTALLED_EXECUTABLE" \
      "$EXPECTED_VERSION" "$verification_token_sha256" \
      "$expected_executable_sha256" "$expected_executable_bytes" \
      "$input_manifest"
  )"; then
    echo "Independent packaged-app attestation is missing, unsafe, or unbound." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! final_source_input_snapshot="$(
    packaged_app_input_closure_snapshot "$source_input"
  )" \
    || ! final_staged_input_snapshot="$(
      packaged_app_input_closure_snapshot "$staged_input_path"
    )" \
    || [ "$final_source_input_snapshot" != "$source_input_snapshot" ] \
    || [ "$final_staged_input_snapshot" != "$staged_input_snapshot" ]; then
    echo "The release fixture or staged input changed during packaged-app verification." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if [ "$(packaged_app_snapshot_value "$final_source_input_snapshot" closureSHA256)" \
       != "$(packaged_app_snapshot_value "$final_staged_input_snapshot" closureSHA256)" ]; then
    echo "The release fixture or staged input changed during packaged-app verification." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! final_executable_snapshot="$(
    packaged_app_executable_snapshot "$INSTALLED_EXECUTABLE"
  )" \
    || [ "$final_executable_snapshot" != "$expected_executable_snapshot" ]; then
    echo "Installed executable changed during independent packaged-project verification." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if ! final_packaged_attestation_snapshot="$(
    packaged_app_attestation_snapshot \
      "$packaged_attestation" "$success_marker" \
      "$input_path" "$project" "$INSTALLED_EXECUTABLE" \
      "$EXPECTED_VERSION" "$verification_token_sha256" \
      "$expected_executable_sha256" "$expected_executable_bytes" \
      "$input_manifest"
  )" \
    || [ "$final_packaged_attestation_snapshot" \
         != "$initial_packaged_attestation_snapshot" ]; then
    echo "Independent packaged-app attestation changed after verification." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if [ -n "${EVIDENCE_DIR:-}" ]; then
    if ! declare -F preserve_release_verification_log >/dev/null \
      || ! preserve_release_verification_log \
        "$packaged_attestation" "packaged-app-attestation.md" required verbatim \
      || ! preserved_packaged_attestation_snapshot="$(
        packaged_app_attestation_snapshot \
          "$EVIDENCE_DIR/packaged-app-attestation.md" "$success_marker" \
          "$input_path" "$project" "$INSTALLED_EXECUTABLE" \
          "$EXPECTED_VERSION" "$verification_token_sha256" \
          "$expected_executable_sha256" "$expected_executable_bytes" \
          "$input_manifest"
      )" \
      || [ "$preserved_packaged_attestation_snapshot" \
           != "$initial_packaged_attestation_snapshot" ]; then
      echo "Could not durably preserve the independent packaged-app attestation." >&2
      cleanup_packaged_app_verification_processes || true
      return 1
    fi
    PACKAGED_APP_ATTESTATION_PRESERVED=1
  fi
  if [ -n "${EVIDENCE_DIR:-}" ] \
    && ! preserve_release_verification_log \
      "$APP_WIRING_LOG" "packaged-app-wiring.log"; then
    return 1
  fi
  if ! remaining_processes="$(
    easysplat_audit_and_drain_verification_processes "$APP_WIRING_TOKEN"
  )"; then
    echo "Packaged-app verification could not prove final process quiescence." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  if [ "$remaining_processes" = contained ]; then
    echo "Packaged-app verification left a detached pipeline or toolchain worker process." >&2
    APP_WIRING_TOKEN=""
    return 1
  fi
  if [ "$remaining_processes" != clean ]; then
    echo "Packaged-app verification returned invalid final process evidence." >&2
    cleanup_packaged_app_verification_processes || true
    return 1
  fi
  APP_WIRING_TOKEN=""
  if ! rm -f "$APP_WIRING_LOG"; then
    return 1
  fi
  APP_WIRING_LOG=""
  echo "Installed app bundled pipeline passed."
}

remove_packaged_app_smoke_installation() {
  if [ -n "$SMOKE_INSTALL_ROOT" ]; then
    if packaged_app_smoke_has_substantive_evidence "$SMOKE_INSTALL_ROOT" \
      && [ "${PACKAGED_APP_ATTESTATION_PRESERVED:-0}" -ne 1 ]; then
      echo "Refusing to remove packaged-app project evidence before attestation preservation." >&2
      return 1
    fi
    rm -rf "$SMOKE_INSTALL_ROOT"
    SMOKE_INSTALL_ROOT=""
  fi
}
