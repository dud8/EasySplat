#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

if [[ ${EASYSPLAT_RELEASE_FIXTURE+x} ]]; then
  echo "EASYSPLAT_RELEASE_FIXTURE is forbidden; use the checked-in hermetic fixture generator." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/token_process_cleanup.sh
source "$ROOT/scripts/release/lib/token_process_cleanup.sh"
# shellcheck source=lib/strict_semver.sh
source "$ROOT/scripts/release/lib/strict_semver.sh"
# shellcheck source=lib/packaged_app_bootstrap_smoke.sh
# Resolved from ROOT at runtime and checked separately.
# shellcheck disable=SC1091
source "$ROOT/scripts/release/lib/packaged_app_bootstrap_smoke.sh"
# shellcheck source=lib/e2e_verifier.sh
# Resolved from ROOT at runtime and checked separately.
# shellcheck disable=SC1091
source "$ROOT/scripts/release/lib/e2e_verifier.sh"
APP_PATH=""
DMG_PATH=""
EXPECTED_VERSION=""
RELEASE_MODE="development-unsigned"
APP_SIGNING_RECEIPT=""
APP_NOTARY_RECEIPT=""
DMG_SIGNING_RECEIPT=""
DMG_NOTARY_RECEIPT=""
RUN_PACKAGED_APP_SMOKE=0
VERIFY_ARTIFACTS=0
E2E_FIXTURE=""
E2E_FIXTURE_MEDIA=""
TOOLCHAIN_ROOT=""
E2E_RUNNER=""
OFFLINE_CACHE_ROOT=""
OFFLINE_RUNNER=""
CACHED_CACHE_ROOT=""
CACHED_RUNNER=""
EVIDENCE_DIR=""
MANIFEST_URL=""
PUBLIC_KEY_FILE=""
RELEASE_MANIFEST=""
CORE_ARCHIVE=""
DA3_BASE_ARCHIVE=""
DA3_SMALL_ARCHIVE=""
SOURCE_URL=""
SOURCE_COMMIT=""
ALLOW_INCOMPLETE=0
HDIUTIL_BIN="${EASYSPLAT_HDIUTIL_BIN:-hdiutil}"
CURL_BIN="${EASYSPLAT_CURL_BIN:-/usr/bin/curl}"
EXPECTED_RELEASE_RUNNER=""
PACKAGED_PROJECT_VERIFIER=""
MOUNT_DIR=""
MOUNT_DEVICE=""
MOUNT_ATTACHED=0
E2E_DIR=""
ACTIVE_LANE_NAME=""
ACTIVE_LANE_RAW_LOG=""
ACTIVE_LANE_DIAGNOSTIC=""
SMOKE_INSTALL_ROOT=""
# Consumed by packaged_app_bootstrap_smoke.sh.
# shellcheck disable=SC2034
APP_WIRING_PID=""
APP_WIRING_LOG=""
# shellcheck disable=SC2034
APP_WIRING_TOKEN=""
# shellcheck disable=SC2034
APP_WIRING_GROUP_FILE=""
PACKAGED_APP_ATTESTATION_PRESERVED=0
# Consumed by e2e_verifier.sh.
# shellcheck disable=SC2034
E2E_VERIFIER_TOKEN=""
# shellcheck disable=SC2034
E2E_VERIFIER_SUPERVISOR_PID=""
# shellcheck disable=SC2034
E2E_VERIFIER_GROUP_FILE=""
REMOTE_MANIFEST=""
MAX_PUBLISHED_MANIFEST_BYTES=8388608
FINAL_SUCCESS_MESSAGE=""
EFFECTIVE_MANIFEST_URL=""
EFFECTIVE_PUBLIC_KEY_FILE=""
VERIFIED_MANIFEST_SHA256=""
VERIFIED_TOOLCHAIN_KEY_ID=""
VERIFIED_TOOLCHAIN_SIGNATURE_SHA256=""
VERIFIED_FIXTURE_ATTESTATION=""
VERIFIED_FIXTURE_MANIFEST_SHA256=""
VERIFIED_FIXTURE_GENERATOR_SHA256=""
VERIFIED_FIXTURE_CLOSURE_SHA256=""
VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""

usage() {
  echo "Usage: verify_release.sh --app <app> --dmg <dmg> --expected-version <semver> [--release-mode development-unsigned|production] [--app-signing-receipt <json> --app-notarization-receipt <json> --dmg-signing-receipt <json> --dmg-notarization-receipt <json>] --artifacts --packaged-app-smoke --source-url <https-url> --source-commit <sha> --fixture <generated-fixture-root> --manifest-url <https-url> --public-key-file <file> --toolchain-root <dir> --e2e-runner <executable> --offline-cache-root <dir> --offline-runner <executable> --cached-cache-root <dir> --cached-runner <executable> --evidence-dir <dir>"
  /bin/cat <<'EOF'

Production artifact closure:
  --release-manifest <json>   Signed toolchain manifest to verify.
  --core-archive <zip>        Native core archive named by the manifest.
  --da3-base-archive <zip>    DA3 Base archive named by the manifest.
  --da3-small-archive <zip>   DA3 Small archive named by the manifest.

Use these four options with --artifacts to verify exact publication inputs.
When omitted, the verifier uses the matching paths under Toolchains/.
EOF
}

release_fixture_attestation() {
  /usr/bin/python3 -I "$ROOT/scripts/release/generate_release_fixture.py" verify \
    --root "$1"
}

release_fixture_attestation_digests() {
  /usr/bin/python3 -I - "$1" <<'PY'
import json
import re
import sys

record = json.loads(sys.argv[1])
if set(record) != {
    "fileCount",
    "fixtureClosureSHA256",
    "fixtureID",
    "fixtureManifestSHA256",
    "fixtureSchemaVersion",
    "generatorSHA256",
    "licenseSPDX",
    "schemaVersion",
    "status",
    "totalBytes",
}:
    raise SystemExit("Release fixture attestation has an unexpected schema.")
if (
    record["schemaVersion"] != 1
    or record["fixtureSchemaVersion"] != 1
    or record["fixtureID"] != "org.easysplat.release-smoke.v1"
    or record["status"] != "verified"
    or record["licenseSPDX"] != "MIT"
    or record["fileCount"] != 12
    or not isinstance(record["totalBytes"], int)
    or record["totalBytes"] <= 0
):
    raise SystemExit("Release fixture attestation has invalid contract values.")
digests = [
    record["fixtureManifestSHA256"],
    record["generatorSHA256"],
    record["fixtureClosureSHA256"],
]
if any(not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None for value in digests):
    raise SystemExit("Release fixture attestation has an invalid digest.")
print(*digests)
PY
}

release_variable_is_readonly() {
  local declaration=""
  declaration="$(declare -p "$1" 2>/dev/null)" || return 1
  [[ "$declaration" =~ ^declare\ -[^[:space:]]*r[^[:space:]]*\  ]]
}

bind_release_evidence_directory() {
  local identity=""
  if ! identity="$(/usr/bin/python3 -I - "$EVIDENCE_DIR" <<'PY'
import ctypes
import errno
import os
import stat
import sys
from pathlib import Path

ACL_TYPE_EXTENDED = 0x00000100
libc = ctypes.CDLL(None, use_errno=True)
libc.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
libc.acl_get_fd_np.restype = ctypes.c_void_p
libc.acl_free.argtypes = (ctypes.c_void_p,)
libc.acl_free.restype = ctypes.c_int

def has_extended_acl(descriptor):
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if acl:
        if libc.acl_free(acl) != 0:
            raise SystemExit("Could not release the evidence-directory ACL inspection.")
        return True
    if ctypes.get_errno() == errno.ENOENT:
        return False
    raise SystemExit("Could not inspect the evidence-directory ACL.")

path = Path(sys.argv[1])
if path.is_symlink():
    raise SystemExit("Release-verification evidence directory cannot be a symlink.")
path.mkdir(parents=True, exist_ok=True, mode=0o700)
flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    metadata = os.fstat(descriptor)
    visible = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_dev != visible.st_dev
        or metadata.st_ino != visible.st_ino
    ):
        raise SystemExit(
            "Release-verification evidence directory must be owned by the current user."
        )
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise SystemExit(
            "Release-verification evidence directory cannot be group- or world-writable."
        )
    if has_extended_acl(descriptor):
        raise SystemExit(
            "Release-verification evidence directory cannot have an extended ACL."
        )
    if os.listdir(descriptor):
        raise SystemExit("Release-verification evidence directory must start empty.")
    print(f"{metadata.st_dev}:{metadata.st_ino}")
finally:
    os.close(descriptor)
PY
    )"; then
    return 1
  fi
  readonly VERIFIED_EVIDENCE_DIRECTORY_IDENTITY="$identity"
}

bind_release_fixture() {
  local attestation=""
  local digests=""
  if ! attestation="$(release_fixture_attestation "$E2E_FIXTURE")"; then
    echo "Release verification requires the exact checked-in generated fixture closure." >&2
    return 1
  fi
  if ! digests="$(release_fixture_attestation_digests "$attestation")" \
      || ! read -r \
        VERIFIED_FIXTURE_MANIFEST_SHA256 \
        VERIFIED_FIXTURE_GENERATOR_SHA256 \
        VERIFIED_FIXTURE_CLOSURE_SHA256 <<<"$digests"; then
    echo "Release fixture attestation could not be bound to verified digests." >&2
    return 1
  fi
  readonly VERIFIED_FIXTURE_ATTESTATION="$attestation"
  E2E_FIXTURE_MEDIA="$(canonical_path "$E2E_FIXTURE/images")"
  if [ ! -d "$E2E_FIXTURE_MEDIA" ]; then
    echo "Release fixture has no authenticated image directory." >&2
    return 1
  fi
}

assert_release_fixture_unchanged() {
  local current=""
  local digests=""
  local manifest_sha256=""
  local generator_sha256=""
  local closure_sha256=""
  if ! current="$(release_fixture_attestation "$E2E_FIXTURE")" \
      || [ "$current" != "$VERIFIED_FIXTURE_ATTESTATION" ]; then
    echo "The generated release fixture changed during verification." >&2
    return 1
  fi
  if ! digests="$(release_fixture_attestation_digests "$current")" \
      || ! read -r manifest_sha256 generator_sha256 closure_sha256 <<<"$digests" \
      || [ "$manifest_sha256" != "$VERIFIED_FIXTURE_MANIFEST_SHA256" ] \
      || [ "$generator_sha256" != "$VERIFIED_FIXTURE_GENERATOR_SHA256" ] \
      || [ "$closure_sha256" != "$VERIFIED_FIXTURE_CLOSURE_SHA256" ]; then
    echo "Release fixture digests differ from the verified attestation." >&2
    return 1
  fi
}

preserve_release_fixture_attestation() {
  local current=""
  [ -n "$EVIDENCE_DIR" ] || return 0
  if ! current="$(/usr/bin/python3 -I \
      "$ROOT/scripts/release/generate_release_fixture.py" verify \
      --root "$E2E_FIXTURE" \
      --attestation "$EVIDENCE_DIR/release-fixture-attestation.json")" \
      || [ "$current" != "$VERIFIED_FIXTURE_ATTESTATION" ]; then
    echo "Could not bind the generated fixture closure into release evidence." >&2
    return 1
  fi
}

preserve_release_verification_log() {
  local source=$1
  local destination_name=$2
  local requirement=${3:-optional}
  local preservation_mode=${4:-sanitized}
  [ -n "$EVIDENCE_DIR" ] || return 0
  if [ ! -f "$source" ]; then
    if [ "$requirement" = "required" ]; then
      echo "Required release-verification evidence is missing: $destination_name" >&2
      return 1
    fi
    return 0
  fi
  python3 - "$source" "$EVIDENCE_DIR/$destination_name" "$preservation_mode" \
    "${HOME:-}" "${SMOKE_INSTALL_ROOT:-}" "${E2E_DIR:-}" \
    "${E2E_FIXTURE:-}" "${TOOLCHAIN_ROOT:-}" "${OFFLINE_CACHE_ROOT:-}" \
    "${CACHED_CACHE_ROOT:-}" <<'PY'
import os
import re
import stat
import sys
import tempfile
import urllib.parse
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
preservation_mode = sys.argv[3]
if preservation_mode not in {"sanitized", "verbatim"}:
    raise SystemExit("Release-verification evidence preservation mode is invalid.")
source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
try:
    metadata = os.fstat(source_fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit("Release-verification log must be an ordinary, non-hardlinked regular file.")
    maximum_bytes = 1024 * 1024
    if preservation_mode == "verbatim" and metadata.st_size > maximum_bytes:
        raise SystemExit("Verbatim release-verification evidence exceeds its size limit.")
    truncated = metadata.st_size > maximum_bytes

    def read_bytes(limit):
        result = bytearray()
        while len(result) < limit:
            chunk = os.read(source_fd, min(64 * 1024, limit - len(result)))
            if not chunk:
                break
            result.extend(chunk)
        return bytes(result)

    if truncated:
        head_bytes = 128 * 1024
        tail_bytes = maximum_bytes - head_bytes
        head = read_bytes(head_bytes)
        os.lseek(source_fd, max(metadata.st_size - tail_bytes, 0), os.SEEK_SET)
        tail = read_bytes(tail_bytes)
        if len(head) == head_bytes:
            newline = max(head.rfind(b"\n"), head.rfind(b"\r"))
            head = head[: newline + 1] if newline >= 0 else b""
        if metadata.st_size > tail_bytes:
            newline_candidates = [offset for offset in (tail.find(b"\n"), tail.find(b"\r")) if offset >= 0]
            tail = tail[min(newline_candidates) + 1 :] if newline_candidates else b""
        payload = head + b"[... middle truncated ...]\n" + tail
    else:
        payload = read_bytes(maximum_bytes)
    after = os.fstat(source_fd)
    visible = os.lstat(source)
    identity_fields = (
        "st_dev", "st_ino", "st_uid", "st_mode", "st_nlink", "st_size",
        "st_mtime_ns", "st_ctime_ns",
    )
    if any(getattr(metadata, key) != getattr(after, key) for key in identity_fields):
        raise SystemExit("Release-verification evidence changed while it was read.")
    if any(getattr(after, key) != getattr(visible, key) for key in identity_fields):
        raise SystemExit("Release-verification evidence path changed while it was read.")
    if not truncated and len(payload) != metadata.st_size:
        raise SystemExit("Release-verification evidence was not read completely.")
finally:
    os.close(source_fd)
text = payload.decode("utf-8", errors="replace")
if preservation_mode == "sanitized":
    replacements = set()
    for value in (item for item in sys.argv[4:] if item):
        canonical = os.path.realpath(value)
        for path in {value, canonical}:
            replacements.update({
                path,
                urllib.parse.quote(path),
                urllib.parse.quote(path, safe=""),
                path.replace(" ", r"\ "),
            })
    for value in sorted(replacements, key=len, reverse=True):
        text = text.replace(value, "<verification-path>")
    text = re.sub(
        r"(?i)\b((?:https?|s?ftp)://)[^/@\s]{1,2048}@",
        r"\1<credentials>@",
        text,
    )
    text = re.sub(
        r"(?i)([?&](?:access_token|api_key|auth|credential|key|signature|token)=)[^&#\s]+",
        r"\1<redacted>",
        text,
    )
    path_tail = r"(?:\\.|%[0-9a-fA-F]{2}|[^\s])+"
    text = re.sub(
        rf"(?i)file:(?://)?/(?:Users|Volumes)/{path_tail}",
        "file:<private-path>",
        text,
    )
    text = re.sub(rf"/(?:Users|Volumes)/{path_tail}", "<private-path>", text)
    text = re.sub(
        r"(?i)(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(?![0-9a-f])",
        "<uuid>",
        text,
    )
destination.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
published = False
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", closefd=True) as output:
        output.write(text)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, destination)
    published = True
    directory_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except BaseException:
    try:
        os.close(fd)
    except OSError:
        pass
    if published:
        try:
            os.unlink(destination)
            rollback_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(rollback_fd)
            finally:
                os.close(rollback_fd)
        except FileNotFoundError:
            pass
    else:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    raise
PY
}

report_release_verification_log_failure() {
  local source=$1
  local destination_name=$2
  local message=$3
  if [ -n "$EVIDENCE_DIR" ]; then
    preserve_release_verification_log "$source" "$destination_name" || return 1
    printf '%s Sanitized evidence was preserved.\n' "$message" >&2
  else
    printf '%s\n' "$message" >&2
  fi
}

validate_release_verifier_evidence() {
  local evidence=$1
  local expected_policy=$2
  local published_output=$3
  python3 - "$evidence" "$expected_policy" "$published_output" \
    "$VERIFIED_MANIFEST_SHA256" \
    "$VERIFIED_TOOLCHAIN_KEY_ID" "$VERIFIED_TOOLCHAIN_SIGNATURE_SHA256" <<'PY'
import hashlib
import os
import re
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
metadata = path.lstat()
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size <= 0:
    raise SystemExit("Release-verifier evidence is not an ordinary nonempty single-link file.")
if stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("Release-verifier evidence is not owner-only.")
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

def exact(prefix):
    matches = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    if len(matches) != 1:
        raise SystemExit(f"Release-verifier evidence has {len(matches)} values for {prefix!r}.")
    return matches[0]

if exact("Installation policy: ") != sys.argv[2] or exact("Status: ") != "passed":
    raise SystemExit("Release-verifier evidence does not attest the successful requested policy.")
if exact("Published manifest file SHA-256: ") != sys.argv[4]:
    raise SystemExit("Release-verifier evidence is not bound to the verified published manifest file.")
if exact("Toolchain key ID: ") != sys.argv[5]:
    raise SystemExit("Release-verifier evidence is not bound to the verified toolchain authority.")
if exact("Toolchain signature SHA-256: ") != sys.argv[6]:
    raise SystemExit("Release-verifier evidence is not bound to the verified manifest signature.")

for label in (
    "Signed payload SHA-256: ",
    "Installed closure SHA-256: ",
    "Installation identity SHA-256: ",
    "Output SHA-256: ",
):
    if re.fullmatch(r"[0-9a-f]{64}", exact(label)) is None:
        raise SystemExit(f"Release-verifier evidence has an invalid digest for {label!r}.")
if int(exact("Output bytes: ")) <= 0 or int(exact("Output vertices: ")) <= 0:
    raise SystemExit("Release-verifier evidence has an empty output.")
if exact("Output format: ") not in {"ascii", "binary_little_endian", "binary_big_endian"}:
    raise SystemExit("Release-verifier evidence has an unsupported output format.")
components = [line for line in lines if line.startswith("Installed component: ")]
if len(components) != 1 or re.fullmatch(
    r"Installed component: macos-arm64-core [0-9a-f]{64}", components[0]
) is None:
    raise SystemExit("Release-verifier evidence does not attest exactly the signed native core.")
capabilities = set(exact("Installed capabilities: ").split(", "))
required = {"runtime.core", "geometry.colmap", "training.msplat"}
if not required.issubset(capabilities):
    raise SystemExit("Release-verifier evidence is missing a required native-core capability.")

output_path = Path(sys.argv[3])
flags = os.O_RDONLY | os.O_NONBLOCK
flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(output_path, flags)
try:
    initial = os.fstat(descriptor)
    if (
        not stat.S_ISREG(initial.st_mode)
        or initial.st_nlink != 1
        or stat.S_IMODE(initial.st_mode) != 0o600
        or initial.st_size <= 0
    ):
        raise SystemExit("Published PLY is not an owner-only single-link regular file.")
    digest = hashlib.sha256()
    header = bytearray()
    byte_count = 0
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        byte_count += len(chunk)
        if len(header) < 64 * 1024:
            header.extend(chunk[: 64 * 1024 - len(header)])
    final = os.fstat(descriptor)
    path_metadata = output_path.lstat()
finally:
    os.close(descriptor)
identity_fields = (
    "st_dev", "st_ino", "st_nlink", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns"
)
if any(getattr(initial, field) != getattr(final, field) for field in identity_fields):
    raise SystemExit("Published PLY changed during final evidence validation.")
if any(getattr(final, field) != getattr(path_metadata, field) for field in identity_fields):
    raise SystemExit("Published PLY path no longer identifies the validated file.")
if byte_count != initial.st_size or int(exact("Output bytes: ")) != byte_count:
    raise SystemExit("Published PLY size differs from release evidence.")
if exact("Output SHA-256: ") != digest.hexdigest():
    raise SystemExit("Published PLY digest differs from release evidence.")
header_end = header.find(b"end_header\n")
if header_end < 0:
    raise SystemExit("Published PLY has no bounded header terminator.")
header_text = bytes(header[: header_end + len(b"end_header\n")]).decode("ascii")
format_rows = [line.split() for line in header_text.splitlines() if line.startswith("format ")]
vertex_rows = [line.split() for line in header_text.splitlines() if line.startswith("element vertex ")]
if len(format_rows) != 1 or len(vertex_rows) != 1:
    raise SystemExit("Published PLY header evidence is ambiguous.")
if exact("Output format: ") != format_rows[0][1]:
    raise SystemExit("Published PLY format differs from release evidence.")
if int(exact("Output vertices: ")) != int(vertex_rows[0][2]):
    raise SystemExit("Published PLY vertex count differs from release evidence.")
PY
}

preserve_active_release_verifier_evidence() {
  [ -n "$ACTIVE_LANE_NAME" ] || return 0
  if ! [[ "$ACTIVE_LANE_NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Active release-verification lane name is invalid." >&2
    return 1
  fi
  preserve_release_verification_log \
    "$ACTIVE_LANE_RAW_LOG" "$ACTIVE_LANE_NAME-console.log" required || return 1
  preserve_release_verification_log \
    "$ACTIVE_LANE_DIAGNOSTIC" "$ACTIVE_LANE_NAME-diagnostic.md"
}

clear_active_release_verifier_evidence() {
  ACTIVE_LANE_NAME=""
  ACTIVE_LANE_RAW_LOG=""
  ACTIVE_LANE_DIAGNOSTIC=""
}

run_captured_release_verifier() {
  local lane=$1
  local lane_root=$2
  local published_output=$3
  local lane_diagnostic="$lane_root/work/diagnostic.md"
  local preserved_diagnostic=""
  local raw_log="$E2E_DIR/raw-console/$lane.raw"
  local status=0
  if [ -z "$EVIDENCE_DIR" ]; then
    echo "Captured release verification requires a private evidence directory." >&2
    return 1
  fi
  shift 3
  mkdir -p "$lane_root/home" "$lane_root/work" "$E2E_DIR/raw-console"
  ACTIVE_LANE_NAME="$lane"
  ACTIVE_LANE_RAW_LOG="$raw_log"
  ACTIVE_LANE_DIAGNOSTIC="$lane_diagnostic"
  set +e
  run_release_verifier "$@" >"$raw_log" 2>&1
  status=$?
  set -e
  if ! preserve_release_verification_log "$raw_log" "$lane-console.log" required; then
    return 1
  fi
  if ! preserve_release_verification_log \
    "$lane_diagnostic" "$lane-diagnostic.md" required; then
    return 1
  fi
  preserved_diagnostic="$EVIDENCE_DIR/$lane-diagnostic.md"
  if [ "$status" -ne 0 ]; then
    printf '%s release-verification lane failed. Sanitized evidence was preserved.\n' \
      "$lane" >&2
  else
    local expected_policy="$lane"
    if [ "$lane" = "bundled-offline" ]; then
      expected_policy="bundled-bootstrap-only"
    fi
    if ! validate_release_verifier_evidence \
      "$preserved_diagnostic" "$expected_policy" "$published_output"; then
      return 1
    fi
    printf '%s release-verification lane passed.\n' "$lane"
  fi
  clear_active_release_verifier_evidence
  return "$status"
}

write_release_verification_status() {
  local status=$1
  local fixture_attestation="${VERIFIED_FIXTURE_ATTESTATION:-}"
  local fixture_digests=""
  local fixture_manifest_sha256=""
  local fixture_generator_sha256=""
  local fixture_closure_sha256=""
  case "$status" in
    passed|failed|incomplete) ;;
    *)
      echo "Release verification status is invalid." >&2
      return 1
      ;;
  esac
  [ -n "$EVIDENCE_DIR" ] || return 0
  if [ -n "$fixture_attestation" ]; then
    if ! release_variable_is_readonly VERIFIED_FIXTURE_ATTESTATION; then
      echo "Release fixture provenance attestation was not bound by the verifier." >&2
      return 1
    fi
    if ! fixture_digests="$(
        release_fixture_attestation_digests "$fixture_attestation"
      )" \
        || ! read -r \
          fixture_manifest_sha256 \
          fixture_generator_sha256 \
          fixture_closure_sha256 <<<"$fixture_digests"; then
      echo "Release fixture provenance attestation is invalid." >&2
      return 1
    fi
  fi
  if [ -z "${VERIFIED_EVIDENCE_DIRECTORY_IDENTITY:-}" ] \
      || ! release_variable_is_readonly VERIFIED_EVIDENCE_DIRECTORY_IDENTITY; then
    echo "Release-verification evidence directory is not bound." >&2
    return 1
  fi
  if [ "$status" = "passed" ]; then
    if [ -z "${E2E_FIXTURE:-}" ] \
        || [ -z "$fixture_attestation" ] \
        || [ -z "$fixture_manifest_sha256" ] \
        || [ -z "$fixture_generator_sha256" ] \
        || [ -z "$fixture_closure_sha256" ]; then
      echo "Release fixture provenance is not bound." >&2
      return 1
    fi
    assert_release_fixture_unchanged || return 1
  fi
  /usr/bin/python3 -I - "$EVIDENCE_DIR" \
    "$VERIFIED_EVIDENCE_DIRECTORY_IDENTITY" \
    "$EXPECTED_VERSION" "$status" "$SOURCE_URL" "$SOURCE_COMMIT" \
    "$VERIFIED_MANIFEST_SHA256" "$VERIFIED_TOOLCHAIN_KEY_ID" \
    "$VERIFIED_TOOLCHAIN_SIGNATURE_SHA256" \
    "$fixture_manifest_sha256" \
    "$fixture_generator_sha256" \
    "$fixture_closure_sha256" <<'PY'
import ctypes
import errno
import os
import secrets
import stat
import sys
import unicodedata

ACL_TYPE_EXTENDED = 0x00000100
libc = ctypes.CDLL(None, use_errno=True)
libc.acl_get_fd_np.argtypes = (ctypes.c_int, ctypes.c_int)
libc.acl_get_fd_np.restype = ctypes.c_void_p
libc.acl_free.argtypes = (ctypes.c_void_p,)
libc.acl_free.restype = ctypes.c_int

def has_extended_acl(descriptor):
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if acl:
        if libc.acl_free(acl) != 0:
            raise SystemExit("Could not release the release-evidence ACL inspection.")
        return True
    if ctypes.get_errno() == errno.ENOENT:
        return False
    raise SystemExit("Could not inspect a release-evidence ACL.")

evidence_directory = sys.argv[1]
expected_directory_identity = sys.argv[2]
destination_name = "release-verification-status.txt"
if sys.argv[4] not in {"passed", "failed", "incomplete"}:
    raise SystemExit("Release verification status is invalid.")
if any(
    unicodedata.category(character).startswith("C")
    or unicodedata.category(character) in {"Zl", "Zp"}
    for value in sys.argv[3:13]
    for character in value
):
    raise SystemExit("Release verification evidence contains a control character.")
lines = [
    "EasySplat release verification",
    f"Version: {sys.argv[3]}",
    f"Status: {sys.argv[4]}",
]
if sys.argv[4] == "passed" and not all(sys.argv[5:13]):
    raise SystemExit("Successful release evidence is missing source, toolchain, or fixture provenance.")
if sys.argv[5]:
    lines.append(f"Source URL: {sys.argv[5]}")
if sys.argv[6]:
    lines.append(f"Source commit: {sys.argv[6]}")
if sys.argv[7]:
    lines.append(f"Published manifest file SHA-256: {sys.argv[7]}")
if sys.argv[8]:
    lines.append(f"Toolchain key ID: {sys.argv[8]}")
if sys.argv[9]:
    lines.append(f"Toolchain signature SHA-256: {sys.argv[9]}")
if sys.argv[10]:
    lines.append(f"Release fixture manifest SHA-256: {sys.argv[10]}")
if sys.argv[11]:
    lines.append(f"Release fixture generator SHA-256: {sys.argv[11]}")
if sys.argv[12]:
    lines.append(f"Release fixture closure SHA-256: {sys.argv[12]}")
payload = "\n".join(lines) + "\n"

directory_flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
try:
    directory_fd = os.open(evidence_directory, directory_flags)
except OSError:
    raise SystemExit("Release-verification evidence directory changed after binding.")

temporary_name = None
fd = None
published = False
try:
    directory_metadata = os.fstat(directory_fd)
    visible_metadata = os.lstat(evidence_directory)
    identity = f"{directory_metadata.st_dev}:{directory_metadata.st_ino}"
    if (
        identity != expected_directory_identity
        or not stat.S_ISDIR(directory_metadata.st_mode)
        or directory_metadata.st_uid != os.getuid()
        or stat.S_IMODE(directory_metadata.st_mode) & 0o022
        or visible_metadata.st_dev != directory_metadata.st_dev
        or visible_metadata.st_ino != directory_metadata.st_ino
        or not stat.S_ISDIR(visible_metadata.st_mode)
    ):
        raise SystemExit("Release-verification evidence directory changed after binding.")
    if has_extended_acl(directory_fd):
        raise SystemExit(
            "Release-verification evidence directory gained an extended ACL."
        )
    try:
        os.stat(destination_name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit("Release verification status path already exists.")

    open_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW
    for _ in range(128):
        temporary_name = f".{destination_name}.{secrets.token_hex(12)}"
        try:
            fd = os.open(temporary_name, open_flags, 0o600, dir_fd=directory_fd)
            break
        except FileExistsError:
            temporary_name = None
    if fd is None or temporary_name is None:
        raise SystemExit("Could not allocate private release status staging.")
    with os.fdopen(fd, "w", encoding="utf-8", closefd=True) as output:
        fd = None
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
    try:
        os.link(
            temporary_name,
            destination_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except FileExistsError:
        raise SystemExit("Release verification status path already exists.")
    published = True
    os.unlink(temporary_name, dir_fd=directory_fd)
    temporary_name = None
    published_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    published_fd = os.open(destination_name, published_flags, dir_fd=directory_fd)
    try:
        published_metadata = os.fstat(published_fd)
        if has_extended_acl(published_fd):
            raise SystemExit(
                "Release verification status file inherited an extended ACL."
            )
    finally:
        os.close(published_fd)
    visible_metadata = os.lstat(evidence_directory)
    if has_extended_acl(directory_fd):
        raise SystemExit(
            "Release-verification evidence directory gained an extended ACL."
        )
    if (
        not stat.S_ISREG(published_metadata.st_mode)
        or stat.S_IMODE(published_metadata.st_mode) != 0o600
        or published_metadata.st_uid != os.getuid()
        or published_metadata.st_nlink != 1
        or visible_metadata.st_dev != directory_metadata.st_dev
        or visible_metadata.st_ino != directory_metadata.st_ino
        or not stat.S_ISDIR(visible_metadata.st_mode)
    ):
        raise SystemExit("Release-verification evidence directory changed after binding.")
    os.fsync(directory_fd)
except BaseException:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    if published:
        try:
            os.unlink(destination_name, dir_fd=directory_fd)
            os.fsync(directory_fd)
        except FileNotFoundError:
            pass
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
    raise
finally:
    os.close(directory_fd)
PY
}

detach_disk_image_once() {
  local detach_target="${MOUNT_DEVICE:-$MOUNT_DIR}"
  python3 - "$HDIUTIL_BIN" "$detach_target" <<'PY'
import os
import signal
import subprocess
import sys

try:
    process = subprocess.Popen(
        [sys.argv[1], "detach", sys.argv[2]],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
except OSError:
    raise SystemExit(127)

def terminate_process_group():
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=0.2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        pass

handled_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)

def abort_for_signal(signum, _frame):
    for handled_signal in handled_signals:
        signal.signal(handled_signal, signal.SIG_DFL)
    raise SystemExit(128 + signum)

for handled_signal in handled_signals:
    signal.signal(handled_signal, abort_for_signal)

try:
    return_code = process.wait(timeout=5.0)
except subprocess.TimeoutExpired:
    terminate_process_group()
    raise SystemExit(124)
except BaseException:
    terminate_process_group()
    raise

raise SystemExit(return_code)
PY
}

cleanup() {
  local status=$?
  local cleanup_signal_status=0
  local detached=0
  local cleanup_failed=0
  local packaged_process_cleanup_failed=0
  local release_process_cleanup_failed=0
  local active_evidence_preservation_failed=0
  local evidence_status="failed"
  trap - EXIT
  trap 'cleanup_signal_status=129' HUP
  trap 'cleanup_signal_status=130' INT
  trap 'cleanup_signal_status=143' TERM
  set +e
  if ! cleanup_packaged_app_verification_processes; then
    cleanup_failed=1
    packaged_process_cleanup_failed=1
  fi
  if ! cleanup_release_verifier_processes; then
    cleanup_failed=1
    release_process_cleanup_failed=1
  fi
  if ! preserve_active_release_verifier_evidence; then
    echo "error: could not preserve active release-verification lane evidence." >&2
    cleanup_failed=1
    active_evidence_preservation_failed=1
  fi
  if [ "$MOUNT_ATTACHED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    for _ in {1..3}; do
      [ "$cleanup_signal_status" -eq 0 ] || break
      if detach_disk_image_once; then
        detached=1
        MOUNT_ATTACHED=0
        break
      fi
      [ "$cleanup_signal_status" -eq 0 ] || break
      sleep 0.1
    done
    if [ "$detached" -eq 0 ]; then
      echo "error: could not detach release verification disk image: $MOUNT_DIR" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$MOUNT_ATTACHED" -eq 0 ] && [ -n "$MOUNT_DIR" ]; then
    if ! rm -rf "$MOUNT_DIR"; then
      echo "error: could not remove release verification mount directory: $MOUNT_DIR" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$release_process_cleanup_failed" -eq 0 ] \
    && [ "$active_evidence_preservation_failed" -eq 0 ] \
    && [ -n "$E2E_DIR" ] && ! rm -rf "$E2E_DIR"; then
    echo "error: could not remove release verification end-to-end directory: $E2E_DIR" >&2
    cleanup_failed=1
  fi
  if [ "$packaged_process_cleanup_failed" -eq 0 ] \
    && [ -n "$APP_WIRING_LOG" ] && [ -n "$EVIDENCE_DIR" ] \
    && ! preserve_release_verification_log \
      "$APP_WIRING_LOG" "packaged-app-wiring.log"; then
    echo "error: could not preserve packaged-app wiring log." >&2
    cleanup_failed=1
  fi
  if [ "$packaged_process_cleanup_failed" -eq 0 ] \
    && [ -n "$APP_WIRING_LOG" ] && ! rm -f "$APP_WIRING_LOG"; then
    echo "error: could not remove packaged-app wiring smoke log: $APP_WIRING_LOG" >&2
    cleanup_failed=1
  fi
  if [ "$packaged_process_cleanup_failed" -eq 0 ] \
    && [ -n "$SMOKE_INSTALL_ROOT" ]; then
    if packaged_app_smoke_has_substantive_evidence "$SMOKE_INSTALL_ROOT" \
      && [ "${PACKAGED_APP_ATTESTATION_PRESERVED:-0}" -ne 1 ]; then
      echo "error: retained packaged-app project evidence because attestation preservation did not complete: $SMOKE_INSTALL_ROOT" >&2
      cleanup_failed=1
    elif ! rm -rf "$SMOKE_INSTALL_ROOT"; then
      echo "error: could not remove release verification installed app: $SMOKE_INSTALL_ROOT" >&2
      cleanup_failed=1
    fi
  fi
  if [ -n "$REMOTE_MANIFEST" ] && ! rm -f "$REMOTE_MANIFEST"; then
    echo "error: could not remove release verification manifest: $REMOTE_MANIFEST" >&2
    cleanup_failed=1
  fi
  if [ "$status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then
    status=1
  fi
  if [ "$cleanup_signal_status" -ne 0 ]; then
    status=$cleanup_signal_status
  fi
  if [ "$status" -eq 0 ] && [ "$ALLOW_INCOMPLETE" -eq 1 ]; then
    evidence_status="incomplete"
  elif [ "$status" -eq 0 ]; then
    evidence_status="passed"
  fi
  if ! write_release_verification_status "$evidence_status"; then
    echo "error: could not preserve release verification status." >&2
    status=1
    if [ "$evidence_status" = "passed" ] \
        && ! write_release_verification_status failed; then
      echo "error: could not preserve failed release verification status." >&2
    fi
  fi
  if [ "$status" -eq 0 ] && [ -n "$FINAL_SUCCESS_MESSAGE" ]; then
    printf '%s\n' "$FINAL_SUCCESS_MESSAGE"
  fi
  exit "$status"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2 ;;
    --dmg) DMG_PATH="$2"; shift 2 ;;
    --expected-version) EXPECTED_VERSION="$2"; shift 2 ;;
    --release-mode) RELEASE_MODE="$2"; shift 2 ;;
    --app-signing-receipt) APP_SIGNING_RECEIPT="$2"; shift 2 ;;
    --app-notarization-receipt) APP_NOTARY_RECEIPT="$2"; shift 2 ;;
    --dmg-signing-receipt) DMG_SIGNING_RECEIPT="$2"; shift 2 ;;
    --dmg-notarization-receipt) DMG_NOTARY_RECEIPT="$2"; shift 2 ;;
    --artifacts) VERIFY_ARTIFACTS=1; shift ;;
    --packaged-app-smoke) RUN_PACKAGED_APP_SMOKE=1; shift ;;
    --skip-packaged-app-smoke) RUN_PACKAGED_APP_SMOKE=0; shift ;;
    --fixture) E2E_FIXTURE="$2"; shift 2 ;;
    --toolchain-root) TOOLCHAIN_ROOT="$2"; shift 2 ;;
    --e2e-runner) E2E_RUNNER="$2"; shift 2 ;;
    --offline-cache-root) OFFLINE_CACHE_ROOT="$2"; shift 2 ;;
    --offline-runner) OFFLINE_RUNNER="$2"; shift 2 ;;
    --cached-cache-root) CACHED_CACHE_ROOT="$2"; shift 2 ;;
    --cached-runner) CACHED_RUNNER="$2"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --public-key-file) PUBLIC_KEY_FILE="$2"; shift 2 ;;
    --release-manifest) RELEASE_MANIFEST="$2"; shift 2 ;;
    --core-archive) CORE_ARCHIVE="$2"; shift 2 ;;
    --da3-base-archive) DA3_BASE_ARCHIVE="$2"; shift 2 ;;
    --da3-small-archive) DA3_SMALL_ARCHIVE="$2"; shift 2 ;;
    --source-url) SOURCE_URL="$2"; shift 2 ;;
    --source-commit) SOURCE_COMMIT="$2"; shift 2 ;;
    --allow-incomplete) ALLOW_INCOMPLETE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$APP_PATH" ] || [ -z "$DMG_PATH" ] || [ -z "$EXPECTED_VERSION" ]; then
  usage >&2
  exit 1
fi
if [ ! -d "$APP_PATH" ] || [ ! -f "$DMG_PATH" ]; then
  echo "Missing app bundle or DMG." >&2
  exit 1
fi
if [ "$RELEASE_MODE" != development-unsigned ] && [ "$RELEASE_MODE" != production ]; then
  echo "Release mode must be development-unsigned or production." >&2
  exit 1
fi
if [ "$RELEASE_MODE" = production ]; then
  for receipt in \
    "$APP_SIGNING_RECEIPT" \
    "$APP_NOTARY_RECEIPT" \
    "$DMG_SIGNING_RECEIPT" \
    "$DMG_NOTARY_RECEIPT"; do
    if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
      echo "Production verification requires all four ordinary signing/notarization receipts." >&2
      exit 1
    fi
  done
elif [ -n "$APP_SIGNING_RECEIPT$APP_NOTARY_RECEIPT$DMG_SIGNING_RECEIPT$DMG_NOTARY_RECEIPT" ]; then
  echo "Developer ID receipts require --release-mode production." >&2
  exit 1
fi
if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
  [ "$VERIFY_ARTIFACTS" -eq 1 ] || { echo "Release verification requires --artifacts." >&2; exit 1; }
  [ "$RUN_PACKAGED_APP_SMOKE" -eq 1 ] || { echo "Release verification requires explicit --packaged-app-smoke." >&2; exit 1; }
fi
if [ "$VERIFY_ARTIFACTS" -eq 1 ] && { [ -z "$SOURCE_URL" ] || [ -z "$SOURCE_COMMIT" ]; }; then
  echo "Artifact verification requires --source-url and --source-commit." >&2
  exit 1
fi

canonical_path() {
  /usr/bin/python3 -I - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

APP_PATH="$(canonical_path "$APP_PATH")"
DMG_PATH="$(canonical_path "$DMG_PATH")"
if [ "$RELEASE_MODE" = production ]; then
  APP_SIGNING_RECEIPT="$(canonical_path "$APP_SIGNING_RECEIPT")"
  APP_NOTARY_RECEIPT="$(canonical_path "$APP_NOTARY_RECEIPT")"
  DMG_SIGNING_RECEIPT="$(canonical_path "$DMG_SIGNING_RECEIPT")"
  DMG_NOTARY_RECEIPT="$(canonical_path "$DMG_NOTARY_RECEIPT")"
  /usr/bin/python3 -I "$ROOT/scripts/release/verify_notarization_receipt.py" \
    --type app \
    --artifact "$APP_PATH" \
    --signing-receipt "$APP_SIGNING_RECEIPT" \
    --receipt "$APP_NOTARY_RECEIPT" >/dev/null
  /usr/bin/python3 -I "$ROOT/scripts/release/verify_notarization_receipt.py" \
    --type dmg \
    --artifact "$DMG_PATH" \
    --signing-receipt "$DMG_SIGNING_RECEIPT" \
    --receipt "$DMG_NOTARY_RECEIPT" >/dev/null
  read -r DEVELOPER_ID_FINGERPRINT DEVELOPER_TEAM_ID < <(
    /usr/bin/python3 -I - "$APP_SIGNING_RECEIPT" "$DMG_SIGNING_RECEIPT" <<'PY'
import json
import re
import sys
from pathlib import Path

rows = [json.loads(Path(value).read_text(encoding="utf-8")) for value in sys.argv[1:]]
identities = {
    (row.get("identityFingerprintSHA1"), row.get("teamID"))
    for row in rows
    if isinstance(row, dict)
}
if len(identities) != 1:
    raise SystemExit("App and DMG signing receipts use different identities.")
fingerprint, team_id = identities.pop()
if not isinstance(fingerprint, str) or re.fullmatch(r"[0-9A-F]{40}", fingerprint) is None:
    raise SystemExit("Signing receipt fingerprint is invalid.")
if not isinstance(team_id, str) or re.fullmatch(r"[A-Z0-9]{10}", team_id) is None:
    raise SystemExit("Signing receipt Team ID is invalid.")
print(fingerprint, team_id)
PY
  )
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --root "$APP_PATH" \
    --kind app \
    --identity-fingerprint "$DEVELOPER_ID_FINGERPRINT" \
    --team-id "$DEVELOPER_TEAM_ID" \
    --receipt "$APP_SIGNING_RECEIPT"
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --root "$DMG_PATH" \
    --kind dmg \
    --identity-fingerprint "$DEVELOPER_ID_FINGERPRINT" \
    --team-id "$DEVELOPER_TEAM_ID" \
    --receipt "$DMG_SIGNING_RECEIPT"
  /usr/bin/xcrun stapler validate "$DMG_PATH" >/dev/null
  /usr/sbin/spctl --assess --type open --context context:primary-signature \
    --verbose=4 "$DMG_PATH" >/dev/null
fi

if [ "$ALLOW_INCOMPLETE" -eq 0 ] && [ -z "$EVIDENCE_DIR" ]; then
  echo "Release verification requires --evidence-dir." >&2
  exit 1
fi
if [ -n "$EVIDENCE_DIR" ]; then
  if ! bind_release_evidence_directory; then
    exit 1
  fi
  EVIDENCE_DIR="$(canonical_path "$EVIDENCE_DIR")"
fi

manifest_component_url() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
matches = [row.get("url") for row in manifest.get("components", []) if row.get("name") == sys.argv[2]]
if len(matches) != 1 or not isinstance(matches[0], str) or not matches[0]:
    raise SystemExit(f"Signed manifest has no unique URL for {sys.argv[2]}.")
if "\n" in matches[0] or "\r" in matches[0]:
    raise SystemExit(f"Signed manifest URL contains a line break for {sys.argv[2]}.")
print(matches[0])
PY
}

verify_signed_toolchain_closure() {
  local toolchain_version=$1
  local core_url
  local base_url
  local small_url
  core_url="$(manifest_component_url "$RELEASE_MANIFEST" macos-arm64-core)"
  base_url="$(manifest_component_url "$RELEASE_MANIFEST" geometry-da3-base)"
  small_url="$(manifest_component_url "$RELEASE_MANIFEST" geometry-da3-small)"
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool verify-release \
    --manifest "$RELEASE_MANIFEST" \
    --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
    --toolchain-version "$toolchain_version" \
    --app-version "$EXPECTED_VERSION" \
    --core-zip "$CORE_ARCHIVE" \
    --core-url "$core_url" \
    --da3-base-zip "$DA3_BASE_ARCHIVE" \
    --da3-base-url "$base_url" \
    --da3-small-zip "$DA3_SMALL_ARCHIVE" \
    --da3-small-url "$small_url"
}

fetch_and_compare_published_manifest() {
  local http_status=""
  local size
  python3 - "$EFFECTIVE_MANIFEST_URL" <<'PY'
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
if url.scheme.lower() != "https" or not url.hostname or url.username is not None or url.password is not None:
    raise SystemExit("Published toolchain manifest URL must be credential-free HTTPS.")
PY
  REMOTE_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/easysplat-published-manifest.XXXXXX")"
  if ! http_status="$("$CURL_BIN" --disable \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --max-redirs 3 \
    --max-filesize "$MAX_PUBLISHED_MANIFEST_BYTES" \
    --request GET \
    --write-out '%{http_code}' \
    --output "$REMOTE_MANIFEST" \
    "$EFFECTIVE_MANIFEST_URL")"; then
    echo "Published toolchain manifest HTTPS GET failed (HTTP ${http_status:-unknown})." >&2
    return 1
  fi
  if [ "$http_status" != "200" ]; then
    echo "Published toolchain manifest HTTPS GET failed (HTTP $http_status)." >&2
    return 1
  fi
  size="$(wc -c <"$REMOTE_MANIFEST" | tr -d '[:space:]')"
  if [ "$size" -gt "$MAX_PUBLISHED_MANIFEST_BYTES" ]; then
    echo "Published toolchain manifest exceeds the 8 MiB release limit." >&2
    return 1
  fi
  if ! cmp -s "$REMOTE_MANIFEST" "$RELEASE_MANIFEST"; then
    echo "Published toolchain manifest bytes differ from the locally verified signed manifest." >&2
    return 1
  fi
}

if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
  if [ ! -d "$E2E_FIXTURE" ] || [ ! -d "$TOOLCHAIN_ROOT" ] || [ -z "$E2E_RUNNER" ] \
    || [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Release verification requires a generated fixture root, installed toolchain, and runner." >&2
    exit 1
  fi
  if [ ! -d "$OFFLINE_CACHE_ROOT" ] || [ -z "$OFFLINE_RUNNER" ] \
    || [ ! -d "$CACHED_CACHE_ROOT" ] || [ -z "$CACHED_RUNNER" ]; then
    echo "Release verification requires distinct bundled-offline and cached-only roots and runners." >&2
    exit 1
  fi

  swift build --package-path "$ROOT" -c release --product EasySplatReleaseVerifier >/dev/null
  EXPECTED_RELEASE_RUNNER="$(swift build --package-path "$ROOT" -c release --show-bin-path)/EasySplatReleaseVerifier"
  [ -x "$EXPECTED_RELEASE_RUNNER" ] || {
    echo "Repository-built EasySplatReleaseVerifier is missing after the release build." >&2
    exit 1
  }
  if [ "$(canonical_path "$E2E_RUNNER")" != "$(canonical_path "$EXPECTED_RELEASE_RUNNER")" ] \
    || [ "$(canonical_path "$OFFLINE_RUNNER")" != "$(canonical_path "$EXPECTED_RELEASE_RUNNER")" ] \
    || [ "$(canonical_path "$CACHED_RUNNER")" != "$(canonical_path "$EXPECTED_RELEASE_RUNNER")" ]; then
    echo "Strict release verification requires the repository-built EasySplatReleaseVerifier for all runs." >&2
    exit 1
  fi
  online_root="$(canonical_path "$TOOLCHAIN_ROOT")"
  offline_root="$(canonical_path "$OFFLINE_CACHE_ROOT")"
  cached_root="$(canonical_path "$CACHED_CACHE_ROOT")"
  E2E_FIXTURE="$(canonical_path "$E2E_FIXTURE")"
  bind_release_fixture
  if [ "$online_root" = "$offline_root" ] || [ "$online_root" = "$cached_root" ] \
    || [ "$offline_root" = "$cached_root" ]; then
    echo "Remote, bundled-offline, and cached-only verification must use distinct toolchain roots." >&2
    exit 1
  fi
  if ! python3 - "$EVIDENCE_DIR" "$E2E_FIXTURE" "$APP_PATH" "$ROOT" \
      "$online_root" "$offline_root" "$cached_root" <<'PY'
import os
import sys

evidence = os.path.realpath(sys.argv[1])
fixture = os.path.realpath(sys.argv[2])
protected = [os.path.realpath(value) for value in sys.argv[3:]]
for root in [evidence, *protected]:
    common = os.path.commonpath((fixture, root))
    if common in (fixture, root):
        raise SystemExit(
            "Generated release fixture must be disjoint from evidence, app, repository, and toolchain roots."
        )
for toolchain_root in protected[2:]:
    common = os.path.commonpath((evidence, toolchain_root))
    if common in (evidence, toolchain_root):
        raise SystemExit(
            "Release-verification evidence must be disjoint from every toolchain root."
        )
PY
  then
    exit 1
  fi
  for root in "$OFFLINE_CACHE_ROOT" "$TOOLCHAIN_ROOT" "$CACHED_CACHE_ROOT"; do
    if find "$root" -mindepth 1 -print -quit | grep -q .; then
      echo "Release verification must start with three empty toolchain roots." >&2
      exit 1
    fi
  done
  TOOLCHAIN_ROOT="$online_root"
  OFFLINE_CACHE_ROOT="$offline_root"
  CACHED_CACHE_ROOT="$cached_root"
  EXPECTED_RELEASE_RUNNER="$(canonical_path "$EXPECTED_RELEASE_RUNNER")"
  E2E_RUNNER="$EXPECTED_RELEASE_RUNNER"
  OFFLINE_RUNNER="$EXPECTED_RELEASE_RUNNER"
  CACHED_RUNNER="$EXPECTED_RELEASE_RUNNER"
  # Consumed by packaged_app_bootstrap_smoke.sh.
  # shellcheck disable=SC2034
  PACKAGED_PROJECT_VERIFIER="$EXPECTED_RELEASE_RUNNER"
  preserve_release_fixture_attestation
fi

if [ "$RELEASE_MODE" = production ] \
    && ! easysplat_is_strict_semver_stable "$EXPECTED_VERSION"; then
  echo "Production release version must be stable semantic versioning without build metadata: $EXPECTED_VERSION" >&2
  exit 1
fi
if [ "$RELEASE_MODE" = development-unsigned ] \
    && ! easysplat_is_strict_semver_without_build_metadata "$EXPECTED_VERSION"; then
  echo "Developer build version must be strict semantic versioning without build metadata: $EXPECTED_VERSION" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/EasySplatApp"
NUMERIC_VERSION="${EXPECTED_VERSION%%-*}"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"; }
read_optional_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}
verify_distribution_bundle() {
  local bundle=$1
  local signature
  /usr/bin/codesign --verify --deep --strict "$bundle"
  signature="$(/usr/bin/codesign --display --verbose=4 "$bundle" 2>&1)"
  grep -Fq 'Identifier=com.easysplat.app' <<<"$signature"
  if [ "$RELEASE_MODE" = production ]; then
    grep -Fq 'flags=0x10000(runtime)' <<<"$signature"
    grep -Fq 'Authority=Developer ID Application:' <<<"$signature"
    grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<<"$signature"
    if grep -Fq 'Signature=adhoc' <<<"$signature" \
        || grep -Fq 'TeamIdentifier=not set' <<<"$signature"; then
      echo "Production is not Developer ID signed: $bundle" >&2
      return 1
    fi
    /usr/bin/xcrun stapler validate "$bundle" >/dev/null
    /usr/sbin/spctl --assess --type execute --verbose=4 "$bundle" >/dev/null
  else
    grep -Fq 'Signature=adhoc' <<<"$signature"
    grep -Fq 'TeamIdentifier=not set' <<<"$signature"
    if grep -Eq '^Authority=' <<<"$signature"; then
      echo "Unsigned developer build unexpectedly carries a signing authority: $bundle" >&2
      return 1
    fi
  fi
}

verify_arm64_executable() {
  local label=$1
  local executable=$2
  local architectures
  if ! architectures="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)"; then
    echo "$label executable is not a valid Mach-O file: $executable" >&2
    return 1
  fi
  if [ "$architectures" != "arm64" ]; then
    echo "$label executable must contain exactly arm64 (found: $architectures)." >&2
    return 1
  fi
}

verify_matching_executable_hashes() {
  local release_executable=$1
  local mounted_executable=$2
  local release_sha256
  local mounted_sha256
  release_sha256="$(/usr/bin/shasum -a 256 "$release_executable" | awk '{ print $1 }')"
  mounted_sha256="$(/usr/bin/shasum -a 256 "$mounted_executable" | awk '{ print $1 }')"
  if [ "$release_sha256" != "$mounted_sha256" ]; then
    echo "Mounted app executable SHA-256 does not match release app executable." >&2
    return 1
  fi
}

macho_uuid_record() {
  local label=$1
  local path=$2
  local output
  local record_count
  if ! output="$(/usr/bin/xcrun dwarfdump --uuid "$path" 2>/dev/null)"; then
    echo "$label UUID could not be read: $path" >&2
    return 1
  fi
  record_count="$(awk '/^UUID: / { count += 1 } END { print count + 0 }' <<<"$output")"
  if [ "$record_count" -ne 1 ]; then
    echo "$label must contain exactly one Mach-O UUID (found: $record_count)." >&2
    return 1
  fi
  awk '/^UUID: / { print $2 " " $3 }' <<<"$output"
}

verify_dsym_matches_executable() {
  local executable=$1
  local dsym=$2
  local executable_record
  local dsym_record
  executable_record="$(macho_uuid_record "Release app executable" "$executable")" || return 1
  dsym_record="$(macho_uuid_record "Exported dSYM" "$dsym")" || return 1
  if [ "$executable_record" != "$dsym_record" ]; then
    echo "Exported dSYM UUID does not match app executable." >&2
    return 1
  fi
}

bundled_app_resource() {
  local app=$1
  local name=$2
  local module_bundle="$app/Contents/Resources/EasySplat_EasySplatApp.bundle"
  local resource_root="$module_bundle"
  if [ ! -d "$module_bundle" ] || [ -L "$module_bundle" ]; then
    echo "Bundled SwiftPM resource bundle is missing: $module_bundle" >&2
    return 1
  fi
  if [ -d "$module_bundle/Contents/Resources" ]; then
    resource_root="$module_bundle/Contents/Resources"
  fi
  if [ -L "$resource_root" ]; then
    echo "Bundled SwiftPM resource directory is not an ordinary directory: $resource_root" >&2
    return 1
  fi
  printf '%s/%s' "$resource_root" "$name"
}

validate_bundled_toolchain_contract() {
  local app=$1
  local manifest_path
  local public_key_path
  local bundled_manifest_url

  manifest_path="$(bundled_app_resource "$app" toolchain_manifest_url.txt)"
  public_key_path="$(bundled_app_resource "$app" public_key_ed25519.txt)"
  if [ ! -f "$manifest_path" ] || [ -L "$manifest_path" ] || [ ! -s "$manifest_path" ]; then
    echo "Bundled toolchain manifest URL is missing: $manifest_path" >&2
    return 1
  fi
  if [ ! -f "$public_key_path" ] || [ -L "$public_key_path" ] || [ ! -s "$public_key_path" ]; then
    echo "Bundled toolchain public key is missing: $public_key_path" >&2
    return 1
  fi
  bundled_manifest_url="$(cat "$manifest_path")"
  if [ "$bundled_manifest_url" != "$MANIFEST_URL" ]; then
    echo "Bundled toolchain manifest URL does not match --manifest-url." >&2
    return 1
  fi
  if ! cmp -s "$public_key_path" "$PUBLIC_KEY_FILE"; then
    echo "Bundled toolchain public key does not match --public-key-file." >&2
    return 1
  fi
}

run_bootstrap_verifier() {
  local manifest=$1
  local core_archive=$2
  local public_key=$3
  local url_policy=release
  if [ "$ALLOW_INCOMPLETE" -eq 1 ]; then
    url_policy=release-or-loopback-development
  fi
  local args=(
    verify-bootstrap
    --manifest "$manifest"
    --public-key-file "$public_key"
    --app-version "$EXPECTED_VERSION"
    --core-zip "$core_archive"
    --url-policy "$url_policy"
  )
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool "${args[@]}"
}

validate_bundled_bootstrap_contract() {
  local app=$1
  local bootstrap_dir="$app/Contents/Resources/ToolchainBootstrap"
  local bundled_manifest="$bootstrap_dir/manifest.json"
  local bundled_core="$bootstrap_dir/macos-arm64-core.zip"

  python3 - "$bootstrap_dir" "$bundled_manifest" "$bundled_core" <<'PY'
import os
import stat
import sys
from pathlib import Path

directory = Path(sys.argv[1])
try:
    directory_metadata = directory.lstat()
except FileNotFoundError:
    raise SystemExit(f"Bundled toolchain bootstrap directory is missing: {directory}")
if not stat.S_ISDIR(directory_metadata.st_mode):
    raise SystemExit(f"Bundled toolchain bootstrap path is not an ordinary directory: {directory}")

expected = {"manifest.json", "macos-arm64-core.zip"}
actual = {entry.name for entry in os.scandir(directory)}
if actual != expected:
    raise SystemExit("Bundled toolchain bootstrap must contain exactly manifest.json and macos-arm64-core.zip.")

for label, raw_path in (
    ("manifest", sys.argv[2]),
    ("core archive", sys.argv[3]),
):
    path = Path(raw_path)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(f"Bundled toolchain bootstrap {label} must be an ordinary, non-hardlinked regular file: {path}")
    if metadata.st_size == 0:
        raise SystemExit(f"Bundled toolchain bootstrap {label} must not be empty: {path}")
PY

  local authority_file
  if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
    authority_file="$PUBLIC_KEY_FILE"
  else
    authority_file="$(bundled_app_resource "$app" public_key_ed25519.txt)"
    if [ ! -f "$authority_file" ] || [ -L "$authority_file" ] || [ ! -s "$authority_file" ]; then
      echo "Bundled app public-key authority is missing: $authority_file" >&2
      return 1
    fi
  fi
  run_bootstrap_verifier "$bundled_manifest" "$bundled_core" "$authority_file"

  if [ -n "$RELEASE_MANIFEST" ] || [ -n "$CORE_ARCHIVE" ]; then
    if [ -z "$RELEASE_MANIFEST" ] || [ -z "$CORE_ARCHIVE" ]; then
      echo "Bootstrap byte verification requires --release-manifest and --core-archive together." >&2
      return 1
    fi
    if ! cmp -s "$bundled_manifest" "$RELEASE_MANIFEST"; then
      echo "Bundled bootstrap manifest bytes differ from the supplied verified release manifest." >&2
      return 1
    fi
    if ! cmp -s "$bundled_core" "$CORE_ARCHIVE"; then
      echo "Bundled bootstrap core bytes differ from the supplied verified core archive." >&2
      return 1
    fi
  fi
}


VERIFY_BUNDLED_TOOLCHAIN=0
if [ -n "$MANIFEST_URL" ] || [ -n "$PUBLIC_KEY_FILE" ]; then
  if [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Packaged toolchain verification requires --manifest-url and --public-key-file together." >&2
    exit 1
  fi
  VERIFY_BUNDLED_TOOLCHAIN=1
fi

plutil -lint "$INFO_PLIST" >/dev/null
[ "$(read_plist CFBundleIdentifier)" = "com.easysplat.app" ]
[ "$(read_plist CFBundleIconFile)" = "EasySplatAppIcon" ]
[ "$(read_plist CFBundleShortVersionString)" = "$NUMERIC_VERSION" ]
[ "$(read_plist CFBundleVersion)" = "$NUMERIC_VERSION" ]
[ "$(read_plist NSPrincipalClass)" = "NSApplication" ]
if [ "$(read_optional_plist LSUIElement)" = "true" ] || \
   [ "$(read_optional_plist LSBackgroundOnly)" = "true" ]; then
  echo "Release app must use the regular application activation policy." >&2
  exit 1
fi
[ "$(read_plist EasySplatReleaseVersion)" = "$EXPECTED_VERSION" ]
[ "$(read_plist EasySplatReleaseChannel)" = "$RELEASE_MODE" ]
[ -x "$EXECUTABLE" ]
verify_arm64_executable "Release app" "$EXECUTABLE"
verify_distribution_bundle "$APP_PATH"
[ -s "$APP_PATH/Contents/Resources/EasySplatAppIcon.icns" ]
[ -s "$APP_PATH/Contents/Resources/Licenses/EasySplat-LICENSE.txt" ]
[ -s "$APP_PATH/Contents/Resources/Licenses/EasySplat-NOTICE.md" ]
[ -s "$APP_PATH/Contents/Resources/Licenses/MetalSplatter-LICENSE.txt" ]
[ -d "$APP_PATH/Contents/_CodeSignature" ]
EXPORTED_DSYM="$(dirname "$APP_PATH")/EasySplat.app.dSYM"
[ -d "$EXPORTED_DSYM" ]
verify_dsym_matches_executable "$EXECUTABLE" "$EXPORTED_DSYM"
if [ "$RELEASE_MODE" = production ]; then
  [ "$(cat "$APP_PATH/Contents/Resources/release_channel.txt")" = "production release" ]
else
  [ "$(cat "$APP_PATH/Contents/Resources/release_channel.txt")" = "unsigned developer build" ]
fi
validate_bundled_bootstrap_contract "$APP_PATH"
if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
  validate_bundled_toolchain_contract "$APP_PATH"
fi

"$HDIUTIL_BIN" verify "$DMG_PATH" >/dev/null
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-mount.XXXXXX")"
ATTACH_OUTPUT="$("$HDIUTIL_BIN" attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH")"
MOUNT_ATTACHED=1
MOUNT_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -v mount="$MOUNT_DIR" '
  $1 ~ /^\/dev\/disk[0-9]+(s[0-9]+)*$/ &&
  length($0) > length(mount) &&
  substr($0, length($0) - length(mount) + 1) == mount &&
  substr($0, length($0) - length(mount), 1) ~ /[[:space:]]/ {
    print $1
    exit
  }
')"
DISTRIBUTED_APP="$MOUNT_DIR/EasySplat.app"
DISTRIBUTED_INFO_PLIST="$DISTRIBUTED_APP/Contents/Info.plist"
DISTRIBUTED_EXECUTABLE="$DISTRIBUTED_APP/Contents/MacOS/EasySplatApp"
[ -d "$DISTRIBUTED_APP" ] && [ -x "$DISTRIBUTED_EXECUTABLE" ]
verify_arm64_executable "Mounted app" "$DISTRIBUTED_EXECUTABLE"
verify_distribution_bundle "$DISTRIBUTED_APP"
[ -s "$DISTRIBUTED_APP/Contents/Resources/Licenses/EasySplat-LICENSE.txt" ]
[ -s "$DISTRIBUTED_APP/Contents/Resources/Licenses/EasySplat-NOTICE.md" ]
[ -s "$DISTRIBUTED_APP/Contents/Resources/Licenses/MetalSplatter-LICENSE.txt" ]
plutil -lint "$DISTRIBUTED_INFO_PLIST" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DISTRIBUTED_INFO_PLIST")" = "com.easysplat.app" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$DISTRIBUTED_INFO_PLIST" 2>/dev/null || true)" = "NSApplication" ] || {
  echo "Mounted app NSPrincipalClass must be NSApplication." >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseVersion' "$DISTRIBUTED_INFO_PLIST")" = "$EXPECTED_VERSION" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$DISTRIBUTED_INFO_PLIST")" = "$RELEASE_MODE" ]
if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$DISTRIBUTED_INFO_PLIST" 2>/dev/null || true)" = "true" ] || \
   [ "$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$DISTRIBUTED_INFO_PLIST" 2>/dev/null || true)" = "true" ]; then
  echo "Mounted app must use the regular application activation policy." >&2
  exit 1
fi
verify_matching_executable_hashes "$EXECUTABLE" "$DISTRIBUTED_EXECUTABLE"
EFFECTIVE_MANIFEST_URL=""
EFFECTIVE_PUBLIC_KEY_FILE=""
if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
  validate_bundled_toolchain_contract "$DISTRIBUTED_APP"
  EFFECTIVE_MANIFEST_URL="$(cat "$(bundled_app_resource "$DISTRIBUTED_APP" toolchain_manifest_url.txt)")"
  EFFECTIVE_PUBLIC_KEY_FILE="$(bundled_app_resource "$DISTRIBUTED_APP" public_key_ed25519.txt)"
fi
validate_bundled_bootstrap_contract "$DISTRIBUTED_APP"

if [ "$VERIFY_ARTIFACTS" -eq 1 ]; then
  if [ "$RELEASE_MODE" = production ]; then
    STEM="${DMG_PATH%.dmg}"
  else
    STEM="${DMG_PATH%-unsigned.dmg}"
  fi
  CHECKSUM="$DMG_PATH.sha256"
  PROVENANCE="$STEM.provenance.json"
  SBOM="$STEM.spdx.json"
  LICENSES="$STEM-licenses.zip"
  DSYM="$STEM-dSYM.zip"
  RELEASE_NOTES="$STEM-release-notes.txt"
  [ -f "$CHECKSUM" ] && [ -f "$PROVENANCE" ] && [ -f "$SBOM" ] && [ -f "$LICENSES" ]
  [ -f "$DSYM" ] && [ -f "$RELEASE_NOTES" ]
  (cd "$(dirname "$DMG_PATH")" && shasum -a 256 -c "$(basename "$CHECKSUM")")
  TOOLCHAIN_VERSION="$(python3 - "$PROVENANCE" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("toolchainVersion")
if not isinstance(value, str) or not value:
    raise SystemExit("Provenance has no toolchain version.")
print(value)
PY
)"
  RELEASE_MANIFEST="${RELEASE_MANIFEST:-$ROOT/Toolchains/manifest.json}"
  CORE_ARCHIVE="${CORE_ARCHIVE:-$ROOT/Toolchains/out/toolchain-macos-arm64-$TOOLCHAIN_VERSION-core.zip}"
  DA3_BASE_ARCHIVE="${DA3_BASE_ARCHIVE:-$ROOT/Toolchains/out/toolchain-geometry-da3-base-$TOOLCHAIN_VERSION.zip}"
  DA3_SMALL_ARCHIVE="${DA3_SMALL_ARCHIVE:-$ROOT/Toolchains/out/toolchain-geometry-da3-small-$TOOLCHAIN_VERSION.zip}"
  RELEASE_MANIFEST="$(canonical_path "$RELEASE_MANIFEST")"
  CORE_ARCHIVE="$(canonical_path "$CORE_ARCHIVE")"
  DA3_BASE_ARCHIVE="$(canonical_path "$DA3_BASE_ARCHIVE")"
  DA3_SMALL_ARCHIVE="$(canonical_path "$DA3_SMALL_ARCHIVE")"
  validate_bundled_bootstrap_contract "$APP_PATH"
  validate_bundled_bootstrap_contract "$DISTRIBUTED_APP"
  python3 "$ROOT/scripts/release/generate_release_metadata.py" verify \
    --app-version "$EXPECTED_VERSION" \
    --toolchain-version "$TOOLCHAIN_VERSION" \
    --release-mode "$RELEASE_MODE" \
    --source-url "$SOURCE_URL" \
    --source-commit "$SOURCE_COMMIT" \
    --dmg "$DMG_PATH" \
    --manifest "$RELEASE_MANIFEST" \
    --core "$CORE_ARCHIVE" \
    --da3-base "$DA3_BASE_ARCHIVE" \
    --da3-small "$DA3_SMALL_ARCHIVE" \
    --app-license "$ROOT/LICENSE" \
    --notice "$ROOT/NOTICE.md" \
    --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
    --provenance "$PROVENANCE" \
    --spdx "$SBOM" \
    --licenses "$LICENSES"
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    verify_signed_toolchain_closure "$TOOLCHAIN_VERSION"
    fetch_and_compare_published_manifest
    VERIFIED_MANIFEST_SHA256="$(shasum -a 256 "$RELEASE_MANIFEST" | awk '{print $1}')"
    VERIFIED_TOOLCHAIN_KEY_ID="$(python3 - "$EFFECTIVE_PUBLIC_KEY_FILE" <<'PY'
import base64
import hashlib
import sys
from pathlib import Path

encoded = "".join(Path(sys.argv[1]).read_text(encoding="utf-8").split())
decoded = base64.b64decode(encoded, validate=True)
if len(decoded) != 32:
    raise SystemExit("Mounted app has an invalid Ed25519 toolchain authority.")
print(hashlib.sha256(decoded).hexdigest())
PY
)"
    VERIFIED_TOOLCHAIN_SIGNATURE_SHA256="$(python3 - "$RELEASE_MANIFEST" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
signature = base64.b64decode(manifest.get("signatureEd25519", ""), validate=True)
if len(signature) != 64:
    raise SystemExit("Release manifest has an invalid Ed25519 signature.")
print(hashlib.sha256(signature).hexdigest())
PY
)"
  fi
  unzip -tq "$DSYM" >/dev/null
  if [ "$RELEASE_MODE" = production ]; then
    grep -Fqi 'Developer ID-signed and notarized release' "$RELEASE_NOTES"
  else
    grep -Fqi 'unsigned developer build' "$RELEASE_NOTES"
  fi
  if grep -Fqi 'production-ready' "$RELEASE_NOTES"; then
    echo "Unsigned developer build notes claim production readiness." >&2
    exit 1
  fi
fi

if [ "$RUN_PACKAGED_APP_SMOKE" -eq 1 ]; then
  SMOKE_INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-install.XXXXXX")"
  SMOKE_APPLICATIONS_DIR="$SMOKE_INSTALL_ROOT/Applications"
  INSTALLED_APP="$SMOKE_APPLICATIONS_DIR/EasySplat.app"
  INSTALLED_INFO_PLIST="$INSTALLED_APP/Contents/Info.plist"
  INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/EasySplatApp"
  mkdir -p "$SMOKE_APPLICATIONS_DIR"
  /usr/bin/ditto "$DISTRIBUTED_APP" "$INSTALLED_APP"
  [ -d "$INSTALLED_APP" ] && [ -x "$INSTALLED_EXECUTABLE" ]
  plutil -lint "$INSTALLED_INFO_PLIST" >/dev/null
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_INFO_PLIST")" = "com.easysplat.app" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseVersion' "$INSTALLED_INFO_PLIST")" = "$EXPECTED_VERSION" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$INSTALLED_INFO_PLIST")" = "$RELEASE_MODE" ]
  verify_arm64_executable "Installed app" "$INSTALLED_EXECUTABLE"
  verify_distribution_bundle "$INSTALLED_APP"
  verify_matching_executable_hashes "$DISTRIBUTED_EXECUTABLE" "$INSTALLED_EXECUTABLE"
  if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
    validate_bundled_toolchain_contract "$INSTALLED_APP"
  fi
  validate_bundled_bootstrap_contract "$INSTALLED_APP"
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    assert_release_fixture_unchanged
    run_packaged_app_bootstrap_smoke "$E2E_FIXTURE_MEDIA"
    assert_release_fixture_unchanged
  fi
  remove_packaged_app_smoke_installation
else
  echo "INCOMPLETE TEST MODE: packaged-app smoke disabled."
fi

if [ -n "$E2E_FIXTURE" ] || [ -n "$TOOLCHAIN_ROOT" ] || [ -n "$E2E_RUNNER" ] \
  || [ -n "$OFFLINE_CACHE_ROOT" ] || [ -n "$OFFLINE_RUNNER" ] \
  || [ -n "$CACHED_CACHE_ROOT" ] || [ -n "$CACHED_RUNNER" ]; then
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    [ -x "$EXPECTED_RELEASE_RUNNER" ] || {
      echo "Repository-built EasySplatReleaseVerifier is missing after the release build." >&2
      exit 1
    }
    E2E_RUNNER="$EXPECTED_RELEASE_RUNNER"
    OFFLINE_RUNNER="$EXPECTED_RELEASE_RUNNER"
    CACHED_RUNNER="$EXPECTED_RELEASE_RUNNER"
  fi
  if [ ! -d "$E2E_FIXTURE_MEDIA" ] || [ ! -d "$TOOLCHAIN_ROOT" ] || [ ! -x "$E2E_RUNNER" ] \
    || [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "End-to-end verification requires a fixture, manifest URL, public key, toolchain cache, and executable runner." >&2
    exit 1
  fi
  E2E_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-e2e.XXXXXX")"
  E2E_INPUT_MANIFEST="$E2E_DIR/release-input-manifest.json"
  printf '%s' '{"photoFolder":"images","schemaVersion":1,"videos":[]}' \
    >"$E2E_INPUT_MANIFEST"
  OFFLINE_LANE_ROOT="$E2E_DIR/offline"
  ONLINE_LANE_ROOT="$E2E_DIR/online"
  CACHED_LANE_ROOT="$E2E_DIR/cached"
  mkdir -p \
    "$OFFLINE_LANE_ROOT/home" "$OFFLINE_LANE_ROOT/work" \
    "$ONLINE_LANE_ROOT/home" "$ONLINE_LANE_ROOT/work" \
    "$CACHED_LANE_ROOT/home" "$CACHED_LANE_ROOT/work" \
    "$E2E_DIR/raw-console"
  BUNDLED_BOOTSTRAP_MANIFEST="$DISTRIBUTED_APP/Contents/Resources/ToolchainBootstrap/manifest.json"
  BUNDLED_BOOTSTRAP_CORE="$DISTRIBUTED_APP/Contents/Resources/ToolchainBootstrap/macos-arm64-core.zip"
  EFFECTIVE_PUBLIC_KEY_FILE="$(canonical_path "$EFFECTIVE_PUBLIC_KEY_FILE")"
  BUNDLED_BOOTSTRAP_MANIFEST="$(canonical_path "$BUNDLED_BOOTSTRAP_MANIFEST")"
  BUNDLED_BOOTSTRAP_CORE="$(canonical_path "$BUNDLED_BOOTSTRAP_CORE")"

  if [ -n "$OFFLINE_CACHE_ROOT" ] || [ -n "$OFFLINE_RUNNER" ]; then
    if [ ! -d "$OFFLINE_CACHE_ROOT" ] || [ ! -x "$OFFLINE_RUNNER" ] \
      || [ ! -d "$E2E_FIXTURE_MEDIA" ] || [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
      echo "Offline verification requires the fixture, manifest contract, empty bootstrap root, and executable runner." >&2
      exit 1
    fi
    OFFLINE_OUTPUT="$OFFLINE_LANE_ROOT/work/splat.ply"
    assert_release_fixture_unchanged
    run_captured_release_verifier bundled-offline "$OFFLINE_LANE_ROOT" "$OFFLINE_OUTPUT" \
      deny "$OFFLINE_LANE_ROOT/home" "$OFFLINE_LANE_ROOT/work" "$OFFLINE_CACHE_ROOT" \
      "$OFFLINE_RUNNER" \
      --input-manifest "$E2E_INPUT_MANIFEST" \
      --input-root "$E2E_FIXTURE" \
      --manifest-url "$EFFECTIVE_MANIFEST_URL" \
      --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
      --expected-manifest "$RELEASE_MANIFEST" \
      --expected-manifest-file-sha256 "$VERIFIED_MANIFEST_SHA256" \
      --bootstrap-manifest "$BUNDLED_BOOTSTRAP_MANIFEST" \
      --bootstrap-core-archive "$BUNDLED_BOOTSTRAP_CORE" \
      --cache-root "$OFFLINE_CACHE_ROOT" \
      --output "$OFFLINE_OUTPUT" \
      --evidence "$OFFLINE_LANE_ROOT/work/diagnostic.md" \
      --app-version "$EXPECTED_VERSION" \
      --installation-policy bundled-bootstrap-only \
      --offline
    assert_release_fixture_unchanged
    [ -s "$OFFLINE_OUTPUT" ]
    head -n 1 "$OFFLINE_OUTPUT" | grep -qx 'ply'
    grep -a -m1 -Eq '^element vertex [1-9][0-9]*$' "$OFFLINE_OUTPUT"
    OFFLINE_TOOLCHAIN_SNAPSHOT="$(cached_toolchain_snapshot "$OFFLINE_CACHE_ROOT")"
  elif [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    echo "Release verification requires a distinct offline bootstrap root and runner." >&2
    exit 1
  else
    :
  fi

  E2E_OUTPUT="$ONLINE_LANE_ROOT/work/splat.ply"
  assert_release_fixture_unchanged
  run_captured_release_verifier remote-only "$ONLINE_LANE_ROOT" "$E2E_OUTPUT" \
    allow "$ONLINE_LANE_ROOT/home" "$ONLINE_LANE_ROOT/work" "$TOOLCHAIN_ROOT" \
    "$E2E_RUNNER" \
    --input-manifest "$E2E_INPUT_MANIFEST" \
    --input-root "$E2E_FIXTURE" \
    --manifest-url "$EFFECTIVE_MANIFEST_URL" \
    --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
    --expected-manifest "$RELEASE_MANIFEST" \
    --expected-manifest-file-sha256 "$VERIFIED_MANIFEST_SHA256" \
    --cache-root "$TOOLCHAIN_ROOT" \
    --output "$E2E_OUTPUT" \
    --evidence "$ONLINE_LANE_ROOT/work/diagnostic.md" \
    --app-version "$EXPECTED_VERSION" \
    --installation-policy remote-only
  assert_release_fixture_unchanged
  [ -s "$E2E_OUTPUT" ]
  head -n 1 "$E2E_OUTPUT" | grep -qx 'ply'
  grep -a -m1 -Eq '^element vertex [1-9][0-9]*$' "$E2E_OUTPUT"
  ONLINE_TOOLCHAIN_SNAPSHOT="$(cached_toolchain_snapshot "$TOOLCHAIN_ROOT")"

  if [ -n "$CACHED_CACHE_ROOT" ] || [ -n "$CACHED_RUNNER" ]; then
    if [ ! -d "$CACHED_CACHE_ROOT" ] || [ ! -x "$CACHED_RUNNER" ]; then
      echo "Cached-only verification requires an empty isolated cache root and executable runner." >&2
      exit 1
    fi
    /usr/bin/ditto "$TOOLCHAIN_ROOT/" "$CACHED_CACHE_ROOT/"
    python3 - "$TOOLCHAIN_ROOT" "$CACHED_CACHE_ROOT" <<'PY'
import sys
from pathlib import Path

source_root, cached_root = map(Path, sys.argv[1:])
source_receipts = list(source_root.rglob(".easysplat_toolchain_state.json"))
cached_receipts = list(cached_root.rglob(".easysplat_toolchain_state.json"))
if len(source_receipts) != 1 or len(cached_receipts) != 1:
    raise SystemExit("Cached-only verification requires one remote-source and one copied receipt.")
if source_receipts[0].read_bytes() != cached_receipts[0].read_bytes():
    raise SystemExit("Cached-only verification did not preserve the remote signed receipt exactly.")
PY
    CACHED_TOOLCHAIN_SNAPSHOT="$(cached_toolchain_snapshot "$CACHED_CACHE_ROOT")"
    CACHED_OUTPUT="$CACHED_LANE_ROOT/work/splat.ply"
    assert_release_fixture_unchanged
    run_captured_release_verifier cached-only "$CACHED_LANE_ROOT" "$CACHED_OUTPUT" \
      deny "$CACHED_LANE_ROOT/home" "$CACHED_LANE_ROOT/work" "$CACHED_CACHE_ROOT" \
      "$CACHED_RUNNER" \
      --input-manifest "$E2E_INPUT_MANIFEST" \
      --input-root "$E2E_FIXTURE" \
      --manifest-url "https://127.0.0.1:1/easysplat-cached-only-verification.json" \
      --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
      --expected-manifest "$RELEASE_MANIFEST" \
      --expected-manifest-file-sha256 "$VERIFIED_MANIFEST_SHA256" \
      --cache-root "$CACHED_CACHE_ROOT" \
      --output "$CACHED_OUTPUT" \
      --evidence "$CACHED_LANE_ROOT/work/diagnostic.md" \
      --app-version "$EXPECTED_VERSION" \
      --installation-policy cached-only \
      --offline
    assert_release_fixture_unchanged
    [ -s "$CACHED_OUTPUT" ]
    head -n 1 "$CACHED_OUTPUT" | grep -qx 'ply'
    grep -a -m1 -Eq '^element vertex [1-9][0-9]*$' "$CACHED_OUTPUT"
    POST_RUN_CACHED_TOOLCHAIN_SNAPSHOT="$(cached_toolchain_snapshot "$CACHED_CACHE_ROOT")"
    if [ "$POST_RUN_CACHED_TOOLCHAIN_SNAPSHOT" != "$CACHED_TOOLCHAIN_SNAPSHOT" ]; then
      echo "Cached-only verification mutated or replaced the signed installed toolchain closure." >&2
      exit 1
    fi
    if [ "$(cached_toolchain_snapshot "$OFFLINE_CACHE_ROOT")" != "$OFFLINE_TOOLCHAIN_SNAPSHOT" ]; then
      echo "A later verification lane mutated the bundled-offline installed closure." >&2
      exit 1
    fi
    if [ "$(cached_toolchain_snapshot "$TOOLCHAIN_ROOT")" != "$ONLINE_TOOLCHAIN_SNAPSHOT" ]; then
      echo "A later verification lane mutated the remote installed closure." >&2
      exit 1
    fi
    echo "Cached-only offline reconstruction passed with network access denied."
  elif [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    echo "Release verification requires a distinct cached-only root and runner." >&2
    exit 1
  fi
else
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    echo "Release verification requires an end-to-end fixture, installed toolchain, and runner." >&2
    exit 1
  fi
  echo "INCOMPLETE TEST MODE: end-to-end splat not supplied."
fi
if [ -z "$OFFLINE_CACHE_ROOT" ] && [ -z "$OFFLINE_RUNNER" ] && [ "$ALLOW_INCOMPLETE" -eq 1 ]; then
  echo "INCOMPLETE TEST MODE: offline bootstrap run not supplied."
fi
if [ -z "$CACHED_CACHE_ROOT" ] && [ -z "$CACHED_RUNNER" ] && [ "$ALLOW_INCOMPLETE" -eq 1 ]; then
  echo "INCOMPLETE TEST MODE: cached-only offline reuse not supplied."
fi

if [ "$ALLOW_INCOMPLETE" -eq 1 ]; then
  FINAL_SUCCESS_MESSAGE="Inspection only: static checks completed for $EXPECTED_VERSION; release verification is incomplete."
else
  FINAL_SUCCESS_MESSAGE="Verified $RELEASE_MODE: $EXPECTED_VERSION"
fi
