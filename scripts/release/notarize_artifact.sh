#!/bin/bash -p
set -euo pipefail

umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset DEVELOPER_DIR SDKROOT TOOLCHAINS
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy
unset CURL_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
unset GIT_SSL_CAINFO GIT_SSL_CAPATH SSLKEYLOGFILE
unset GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN GITHUB_TOKEN

ARTIFACT_TYPE=""
ARTIFACT_PATH=""
KEYCHAIN_PROFILE=""
RECEIPT_PATH=""
DIAGNOSTICS_DIR=""

usage() {
  echo "Usage: notarize_artifact.sh --type app|zip|dmg --artifact <absolute-path> --keychain-profile <name> --receipt <absolute-json-path> --diagnostics-dir <absolute-directory>" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --type)
      ARTIFACT_TYPE="${2:-}"
      shift 2
      ;;
    --artifact)
      ARTIFACT_PATH="${2:-}"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="${2:-}"
      shift 2
      ;;
    --receipt)
      RECEIPT_PATH="${2:-}"
      shift 2
      ;;
    --diagnostics-dir)
      DIAGNOSTICS_DIR="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [ -z "$ARTIFACT_TYPE" ] || [ -z "$ARTIFACT_PATH" ] \
    || [ -z "$KEYCHAIN_PROFILE" ] || [ -z "$RECEIPT_PATH" ] \
    || [ -z "$DIAGNOSTICS_DIR" ]; then
  usage
  exit 64
fi

if ! [[ "$KEYCHAIN_PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "The notary keychain profile name is invalid." >&2
  exit 64
fi

path_has_safe_resolution() {
  /usr/bin/python3 -I - "$1" "$2" <<'PY' >/dev/null 2>&1
import os
import stat
import sys
from pathlib import Path

raw, kind = sys.argv[1:]
if not raw.startswith("/") or any(ord(character) < 32 for character in raw):
    raise SystemExit(1)
parts = raw.split("/")[1:]
if not parts or any(part in ("", ".", "..") for part in parts):
    raise SystemExit(1)

current = Path("/")
for index, part in enumerate(parts):
    current /= part
    final = index == len(parts) - 1
    if not os.path.lexists(current):
        if not final:
            raise SystemExit(1)
        if kind not in ("output-file", "output-directory"):
            raise SystemExit(1)
        continue
    metadata = current.lstat()
    mode = metadata.st_mode
    if stat.S_ISLNK(mode):
        raise SystemExit(1)
    if not final and not stat.S_ISDIR(mode):
        raise SystemExit(1)
    if final:
        expected = {
            "regular-file": stat.S_ISREG,
            "directory": stat.S_ISDIR,
            "output-file": stat.S_ISREG,
            "output-directory": stat.S_ISDIR,
        }[kind]
        if not expected(mode):
            raise SystemExit(1)
        if metadata.st_uid != os.geteuid():
            raise SystemExit(1)
        if mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise SystemExit(1)
        if stat.S_ISREG(mode) and (
            metadata.st_nlink != 1 or metadata.st_size <= 0
        ):
            raise SystemExit(1)
PY
}

if [ "$ARTIFACT_TYPE" != zip ] && [ "$ARTIFACT_TYPE" != app ] \
    && [ "$ARTIFACT_TYPE" != dmg ]; then
  echo "Unsupported notarization artifact type." >&2
  exit 64
fi
ARTIFACT_PATH_KIND=regular-file
if [ "$ARTIFACT_TYPE" = app ]; then
  ARTIFACT_PATH_KIND=directory
fi
if ! path_has_safe_resolution "$ARTIFACT_PATH" "$ARTIFACT_PATH_KIND"; then
  echo "The notarization artifact does not match its declared type." >&2
  exit 64
fi
if ! path_has_safe_resolution "$RECEIPT_PATH" output-file; then
  echo "The notarization receipt path is unsafe." >&2
  exit 64
fi
if ! path_has_safe_resolution "$DIAGNOSTICS_DIR" output-directory; then
  echo "The notarization diagnostics path is unsafe." >&2
  exit 64
fi

paths_are_disjoint() {
  /usr/bin/python3 -I - "$@" <<'PY' >/dev/null 2>&1
import os
import sys
import unicodedata
from pathlib import Path


def ownership_parts(raw):
    resolved = os.path.realpath(raw)
    return tuple(
        unicodedata.normalize("NFC", part).casefold()
        for part in Path(resolved).parts
    )


paths = [ownership_parts(raw) for raw in sys.argv[1:]]
for index, left in enumerate(paths):
    for right in paths[index + 1:]:
        shared = min(len(left), len(right))
        if left[:shared] == right[:shared]:
            raise SystemExit(1)
PY
}

if ! paths_are_disjoint "$ARTIFACT_PATH" "$RECEIPT_PATH" "$DIAGNOSTICS_DIR"; then
  echo "The notarization artifact, receipt, and diagnostics paths must be disjoint." >&2
  exit 64
fi

ARTIFACT_PARENT="${ARTIFACT_PATH%/*}"
RECEIPT_PARENT="${RECEIPT_PATH%/*}"
RECEIPT_NAME="${RECEIPT_PATH##*/}"
DIAGNOSTICS_PARENT="${DIAGNOSTICS_DIR%/*}"
DIAGNOSTICS_NAME="${DIAGNOSTICS_DIR##*/}"

# Keep capabilities for the exact artifact and output parents that passed
# preflight. External tools never inherit these descriptors. Publication uses
# the held directories, so a later pathname swap cannot redirect a receipt or
# diagnostic into the artifact.
exec 5<"$ARTIFACT_PARENT"
exec 6<"$ARTIFACT_PATH"
exec 7<"$RECEIPT_PARENT"
exec 8<"$DIAGNOSTICS_PARENT"

bound_path_state() {
  /usr/bin/python3 -I - \
    "$ARTIFACT_TYPE" "$ARTIFACT_PATH" "$ARTIFACT_PARENT" \
    "$RECEIPT_PARENT" "$DIAGNOSTICS_PARENT" <<'PY'
import json
import os
import stat
import sys


artifact_type, artifact_path, artifact_parent, receipt_parent, diagnostics_parent = (
    sys.argv[1:]
)


def record(metadata):
    return {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "kind": "directory" if stat.S_ISDIR(metadata.st_mode) else "file",
        "mode": stat.S_IMODE(metadata.st_mode),
        "uid": metadata.st_uid,
    }


def same_identity(left, right):
    return (
        left.st_dev,
        left.st_ino,
        stat.S_IFMT(left.st_mode),
        stat.S_IMODE(left.st_mode),
        left.st_uid,
    ) == (
        right.st_dev,
        right.st_ino,
        stat.S_IFMT(right.st_mode),
        stat.S_IMODE(right.st_mode),
        right.st_uid,
    )


def open_bound_path(path, final_kind):
    if not path.startswith("/"):
        raise SystemExit("bound path is not absolute")
    parts = path.split("/")[1:]
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise SystemExit("bound path has an unsafe component")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    entries = [{"name": "/", **record(os.fstat(descriptor))}]
    try:
        for index, part in enumerate(parts):
            final = index == len(parts) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW
            if not final or final_kind == "directory":
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=descriptor)
            try:
                opened = os.fstat(child)
                named = os.stat(part, dir_fd=descriptor, follow_symlinks=False)
                if not same_identity(opened, named):
                    raise SystemExit("bound path changed while it was opened")
                if final and final_kind == "file" and not stat.S_ISREG(opened.st_mode):
                    raise SystemExit("bound artifact is not a regular file")
                if final and final_kind == "directory" and not stat.S_ISDIR(
                    opened.st_mode
                ):
                    raise SystemExit("bound path is not a directory")
                entries.append({"name": part, **record(opened)})
            except Exception:
                os.close(child)
                raise
            os.close(descriptor)
            descriptor = child
        final_metadata = os.fstat(descriptor)
        if final_metadata.st_uid != os.geteuid() or final_metadata.st_mode & (
            stat.S_IWGRP | stat.S_IWOTH
        ):
            raise SystemExit("bound path has unsafe ownership or mode")
        if final_kind == "file" and final_metadata.st_nlink != 1:
            raise SystemExit("bound artifact is hard linked")
        return descriptor, entries
    except Exception:
        os.close(descriptor)
        raise


artifact_kind = "directory" if artifact_type == "app" else "file"
opened = []
try:
    artifact_fd, artifact_entries = open_bound_path(artifact_path, artifact_kind)
    opened.append(artifact_fd)
    artifact_parent_fd, artifact_parent_entries = open_bound_path(
        artifact_parent, "directory"
    )
    opened.append(artifact_parent_fd)
    receipt_parent_fd, receipt_parent_entries = open_bound_path(
        receipt_parent, "directory"
    )
    opened.append(receipt_parent_fd)
    diagnostics_parent_fd, diagnostics_parent_entries = open_bound_path(
        diagnostics_parent, "directory"
    )
    opened.append(diagnostics_parent_fd)
    expected_fds = {
        artifact_parent_fd: 5,
        artifact_fd: 6,
        receipt_parent_fd: 7,
        diagnostics_parent_fd: 8,
    }
    for opened_fd, inherited_fd in expected_fds.items():
        if not same_identity(os.fstat(opened_fd), os.fstat(inherited_fd)):
            raise SystemExit("held path descriptor no longer matches its pathname")
    payload = {
        "artifact": artifact_entries,
        "artifactParent": artifact_parent_entries,
        "diagnosticsParent": diagnostics_parent_entries,
        "receiptParent": receipt_parent_entries,
    }
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
finally:
    for descriptor in opened:
        os.close(descriptor)
PY
}

if ! BOUND_PATH_STATE="$(bound_path_state)"; then
  echo "The notarization path ancestry could not be bound safely." >&2
  exit 64
fi

require_bound_paths() {
  local current
  if ! current="$(bound_path_state)" || [ "$current" != "$BOUND_PATH_STATE" ]; then
    echo "A notarization path or parent changed after preflight." >&2
    return 1
  fi
}

XCRUN_BIN=/usr/bin/xcrun
CODESIGN_BIN=/usr/bin/codesign
SYSPOLICY_BIN=/usr/bin/syspolicy_check
SPCTL_BIN=/usr/sbin/spctl
DITTO_BIN=/usr/bin/ditto
if [ "${EASYSPLAT_NOTARY_TEST_MODE:-0}" = 1 ]; then
  XCRUN_BIN="${EASYSPLAT_NOTARY_XCRUN_BIN:-}"
  CODESIGN_BIN="${EASYSPLAT_NOTARY_CODESIGN_BIN:-}"
  SYSPOLICY_BIN="${EASYSPLAT_NOTARY_SYSPOLICY_BIN:-}"
  SPCTL_BIN="${EASYSPLAT_NOTARY_SPCTL_BIN:-}"
  DITTO_BIN="${EASYSPLAT_NOTARY_DITTO_BIN:-}"
fi
for command_path in \
  "$XCRUN_BIN" "$CODESIGN_BIN" "$SYSPOLICY_BIN" "$SPCTL_BIN" "$DITTO_BIN"; do
  if [[ "$command_path" != /* ]] || [ ! -f "$command_path" ] \
      || [ -L "$command_path" ] || [ ! -x "$command_path" ]; then
    echo "A notarization command path is invalid." >&2
    exit 64
  fi
done

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/easysplat-notary.XXXXXX)"
chmod 700 "$WORK_DIR"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

publish_bound_file() {
  local output_kind="$1"
  local source_path="$2"
  local output_name="$3"
  local maximum_bytes="$4"

  /usr/bin/python3 -I - \
    "$output_kind" "$source_path" "$output_name" "$DIAGNOSTICS_NAME" \
    "$maximum_bytes" <<'PY'
import hashlib
import os
import secrets
import stat
import sys
import unicodedata


output_kind, source_path, output_name, diagnostics_name, maximum_text = sys.argv[1:]
maximum_bytes = int(maximum_text)


def safe_name(value):
    return (
        value not in ("", ".", "..")
        and "/" not in value
        and "\\" not in value
        and all(ord(character) >= 32 for character in value)
        and unicodedata.normalize("NFC", value) == value
    )


if output_kind not in ("receipt", "diagnostic"):
    raise SystemExit("unsupported bound output kind")
if not safe_name(output_name) or not safe_name(diagnostics_name):
    raise SystemExit("bound output name is unsafe")
if maximum_bytes <= 0 or maximum_bytes > 8 * 1024 * 1024:
    raise SystemExit("bound output limit is unsafe")

source_fd = os.open(source_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
target_fd = -1
temporary_name = ""
try:
    source_before = os.fstat(source_fd)
    source_named = os.lstat(source_path)
    identity_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_uid",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(
        getattr(source_before, field) != getattr(source_named, field)
        for field in identity_fields
    ):
        raise SystemExit("bound output source changed before publication")
    if not stat.S_ISREG(source_before.st_mode):
        raise SystemExit("bound output source is not a regular file")
    if source_before.st_uid != os.geteuid():
        raise SystemExit("bound output source has the wrong owner")
    if source_before.st_nlink != 1:
        raise SystemExit("bound output source is hard linked")
    if source_before.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("bound output source is group- or world-writable")
    if source_before.st_size <= 0:
        raise SystemExit("bound output source is empty")
    if source_before.st_size > maximum_bytes:
        raise SystemExit("bound output source exceeds its limit")

    if output_kind == "receipt":
        target_fd = os.dup(7)
    else:
        try:
            os.mkdir(diagnostics_name, 0o700, dir_fd=8)
        except FileExistsError:
            pass
        target_fd = os.open(
            diagnostics_name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=8,
        )
        opened = os.fstat(target_fd)
        named = os.stat(diagnostics_name, dir_fd=8, follow_symlinks=False)
        if (
            (opened.st_dev, opened.st_ino, stat.S_IFMT(opened.st_mode))
            != (named.st_dev, named.st_ino, stat.S_IFMT(named.st_mode))
            or not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            raise SystemExit("bound diagnostics directory is unsafe")
        os.fchmod(target_fd, 0o700)

    target_metadata = os.fstat(target_fd)
    if (
        not stat.S_ISDIR(target_metadata.st_mode)
        or target_metadata.st_uid != os.geteuid()
        or target_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise SystemExit("bound output directory is unsafe")

    for _ in range(32):
        candidate = f".easysplat-notary-{secrets.token_hex(16)}"
        try:
            destination_fd = os.open(
                candidate,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | os.O_CLOEXEC
                | os.O_NOFOLLOW,
                0o600,
                dir_fd=target_fd,
            )
            temporary_name = candidate
            break
        except FileExistsError:
            continue
    else:
        raise SystemExit("unable to reserve a private bound output")

    digest = hashlib.sha256()
    total = 0
    try:
        while True:
            chunk = os.read(source_fd, min(1024 * 1024, maximum_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise SystemExit("bound output source exceeds its limit")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    raise SystemExit("bound output write was incomplete")
                view = view[written:]
        os.fchmod(destination_fd, 0o600)
        os.fsync(destination_fd)
    finally:
        os.close(destination_fd)

    source_after = os.fstat(source_fd)
    source_named_after = os.lstat(source_path)
    if any(
        getattr(source_before, field) != getattr(source_after, field)
        or getattr(source_before, field) != getattr(source_named_after, field)
        for field in identity_fields
    ):
        raise SystemExit("bound output source changed during publication")

    try:
        os.link(
            temporary_name,
            output_name,
            src_dir_fd=target_fd,
            dst_dir_fd=target_fd,
            follow_symlinks=False,
        )
    except FileExistsError:
        raise SystemExit("bound output already exists")
    os.unlink(temporary_name, dir_fd=target_fd)
    temporary_name = ""
    os.fsync(target_fd)

    published_fd = os.open(
        output_name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=target_fd,
    )
    try:
        published = os.fstat(published_fd)
        if (
            not stat.S_ISREG(published.st_mode)
            or stat.S_IMODE(published.st_mode) != 0o600
            or published.st_uid != os.geteuid()
            or published.st_nlink != 1
            or published.st_size != total
        ):
            raise SystemExit("published bound output has unsafe metadata")
        published_digest = hashlib.sha256()
        while True:
            chunk = os.read(published_fd, 1024 * 1024)
            if not chunk:
                break
            published_digest.update(chunk)
        if published_digest.hexdigest() != digest.hexdigest():
            raise SystemExit("published bound output bytes changed")
    finally:
        os.close(published_fd)
    print(digest.hexdigest())
finally:
    if temporary_name and target_fd >= 0:
        try:
            os.unlink(temporary_name, dir_fd=target_fd)
        except FileNotFoundError:
            pass
    if target_fd >= 0:
        os.close(target_fd)
    os.close(source_fd)
PY
}

remove_bound_receipt() {
  local expected_sha256="$1"
  /usr/bin/python3 -I - "$RECEIPT_NAME" "$expected_sha256" <<'PY'
import hashlib
import os
import stat
import sys


name, expected = sys.argv[1:]
descriptor = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=7)
try:
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise SystemExit("published receipt cannot be rolled back safely")
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    if digest.hexdigest() != expected:
        raise SystemExit("published receipt changed before rollback")
finally:
    os.close(descriptor)
os.unlink(name, dir_fd=7)
os.fsync(7)
PY
}

scrub_diagnostic() {
  # The single-quoted program is Perl, not shell.
  # shellcheck disable=SC2016
  /usr/bin/env -i \
    SCRUB_PROFILE="$KEYCHAIN_PROFILE" SCRUB_ARTIFACT="$ARTIFACT_PATH" \
    /usr/bin/perl -pe '
      BEGIN {
        $profile = quotemeta($ENV{"SCRUB_PROFILE"});
        $artifact = quotemeta($ENV{"SCRUB_ARTIFACT"});
      }
      s/$artifact/<artifact>/g if length $artifact;
      s/$profile/<profile>/g if length $profile;
      s{([A-Za-z][A-Za-z0-9+.-]*://)[^/\s:@]+:[^/\s@]*@}{$1<redacted>\@}g;
      s{/Users/[^/\s"\x27]+}{/Users/<redacted>}g;
      s{/Volumes/[^/\s"\x27]+}{/Volumes/<redacted>}g;
      s{(--(?:password|apple-id|team-id|issuer|key)\s+)[^\s]+}{$1<redacted>}g;
    ' "$1" >"$2" 5<&- 6<&- 7<&- 8<&-
}

write_scrubbed_diagnostic() {
  local diagnostic_source="$1"
  local diagnostic_name="$2"
  local diagnostic_temp
  local diagnostic_digest

  require_bound_paths
  diagnostic_temp="$(/usr/bin/mktemp "$WORK_DIR/.notary-diagnostic.XXXXXX")"
  scrub_diagnostic "$diagnostic_source" "$diagnostic_temp"
  if [ ! -s "$diagnostic_temp" ]; then
    printf '%s\n' 'The notarization command failed without a usable diagnostic.' \
      >"$diagnostic_temp"
  fi
  chmod 600 "$diagnostic_temp"
  diagnostic_digest="$(
    publish_bound_file diagnostic "$diagnostic_temp" "$diagnostic_name" 8388608
  )"
  if ! [[ "$diagnostic_digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "The diagnostic publication digest is invalid." >&2
    return 1
  fi
  require_bound_paths
}

run_bounded_process() {
  local stdout_path="$1"
  local stderr_path="$2"
  local stdout_limit="$3"
  local stderr_limit="$4"
  shift 4

  /usr/bin/python3 -I - \
    "$stdout_path" "$stderr_path" "$stdout_limit" "$stderr_limit" \
    "$@" <<'PY'
import os
import selectors
import signal
import stat
import subprocess
import sys


stdout_path, stderr_path, stdout_limit_text, stderr_limit_text, *command = sys.argv[1:]
stdout_limit = int(stdout_limit_text)
stderr_limit = int(stderr_limit_text)
if (
    not command
    or not os.path.isabs(command[0])
    or not 0 < stdout_limit <= 8 * 1024 * 1024
    or not 0 < stderr_limit <= 8 * 1024 * 1024
):
    raise SystemExit("bounded command contract is invalid")

child_environment = os.environ.copy()
for variable in (
    "DEVELOPER_DIR",
    "SDKROOT",
    "TOOLCHAINS",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
    "CURL_CA_BUNDLE",
    "REQUESTS_CA_BUNDLE",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "GIT_SSL_CAINFO",
    "GIT_SSL_CAPATH",
    "SSLKEYLOGFILE",
    "GITHUB_PERSONAL_ACCESS_TOKEN",
    "GH_TOKEN",
    "GITHUB_TOKEN",
):
    child_environment.pop(variable, None)


def open_capture(path):
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        raise SystemExit("bounded capture path is invalid")
    descriptor = os.open(
        path,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_CLOEXEC
        | os.O_NOFOLLOW,
        0o600,
    )
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_size != 0
    ):
        os.close(descriptor)
        raise SystemExit("bounded capture file is unsafe")
    return descriptor


def write_all(descriptor, data):
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("bounded capture write made no progress")
        view = view[written:]


stdout_fd = open_capture(stdout_path)
stderr_fd = open_capture(stderr_path)
process = None
try:
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            env=child_environment,
            start_new_session=True,
        )
    except OSError:
        write_all(stderr_fd, b"The bounded command could not be started.\n")
        raise SystemExit(127)

    if process.stdout is None or process.stderr is None:
        raise SystemExit("bounded command pipes are unavailable")
    selector = selectors.DefaultSelector()
    streams = {
        process.stdout: {"destination": stdout_fd, "limit": stdout_limit, "written": 0},
        process.stderr: {"destination": stderr_fd, "limit": stderr_limit, "written": 0},
    }
    for stream in streams:
        selector.register(stream, selectors.EVENT_READ)

    overflow = False
    killed = False
    while selector.get_map():
        for key, _ in selector.select(timeout=0.25):
            stream = key.fileobj
            chunk = os.read(stream.fileno(), 64 * 1024)
            if not chunk:
                selector.unregister(stream)
                stream.close()
                continue
            state = streams[stream]
            remaining = state["limit"] - state["written"]
            if remaining > 0:
                retained = chunk[:remaining]
                write_all(state["destination"], retained)
                state["written"] += len(retained)
            if len(chunk) > remaining:
                overflow = True
                if not killed:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    killed = True

    returncode = process.wait()
    if overflow:
        raise SystemExit(125)
    if returncode < 0:
        raise SystemExit(128 - returncode)
    raise SystemExit(returncode)
finally:
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    for descriptor in (stdout_fd, stderr_fd):
        os.fsync(descriptor)
        os.close(descriptor)
PY
}

run_private_command() {
  local label="$1"
  local stdout_path="$WORK_DIR/$label.stdout"
  local stderr_path="$WORK_DIR/$label.stderr"
  local command_exit
  local diagnostic_source
  shift

  require_bound_paths
  set +e
  (
    exec 5<&- 6<&- 7<&- 8<&-
    run_bounded_process \
      "$stdout_path" "$stderr_path" 2097152 2097152 "$@"
  )
  command_exit=$?
  set -e
  if ! require_bound_paths; then
    return 1
  fi
  if [ "$command_exit" -eq 0 ]; then
    return 0
  fi
  diagnostic_source="$stderr_path"
  if [ ! -s "$diagnostic_source" ]; then
    diagnostic_source="$stdout_path"
  fi
  write_scrubbed_diagnostic "$diagnostic_source" \
    "notarization-$label-failure.txt"
  echo "A notarization packaging or verification command failed." >&2
  return 1
}

artifact_sha256() {
  /usr/bin/python3 -I - "$1" <<'PY'
import hashlib
import os
import stat
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
if root.is_file() and not root.is_symlink():
    metadata = root.lstat()
    if (
        metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or metadata.st_size <= 0
    ):
        raise SystemExit("artifact file ownership, links, mode, or size is unsafe")
    digest = hashlib.sha256()
    with root.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    print(digest.hexdigest())
    raise SystemExit(0)

if not root.is_dir() or root.is_symlink():
    raise SystemExit("artifact must be a regular file or directory")

digest = hashlib.sha256()
paths = [
    root,
    *sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()),
]
for path in paths:
    metadata = path.lstat()
    relative = "." if path == root else path.relative_to(root).as_posix()
    if stat.S_ISLNK(metadata.st_mode) or not (
        stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
    ):
        raise SystemExit(f"unsupported artifact entry: {relative}")
    if metadata.st_uid != os.geteuid() or metadata.st_mode & (
        stat.S_IWGRP | stat.S_IWOTH
    ):
        raise SystemExit(f"unsafe artifact entry ownership or mode: {relative}")
    if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
        raise SystemExit(f"hard linked artifact entry: {relative}")
    relative_bytes = relative.encode("utf-8", errors="surrogateescape")
    digest.update(b"D" if stat.S_ISDIR(metadata.st_mode) else b"F")
    digest.update(struct.pack(">Q", len(relative_bytes)))
    digest.update(relative_bytes)
    digest.update(struct.pack(">I", stat.S_IMODE(metadata.st_mode)))
    if stat.S_ISREG(metadata.st_mode):
        file_digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                file_digest.update(chunk)
        digest.update(struct.pack(">Q", metadata.st_size))
        digest.update(file_digest.digest())
print(digest.hexdigest())
PY
}

artifact_binding() {
  /usr/bin/python3 -I - "$1" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def record(path):
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not (
        stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
    ):
        raise SystemExit("artifact binding contains an unsupported entry")
    if metadata.st_uid != os.geteuid() or metadata.st_mode & (
        stat.S_IWGRP | stat.S_IWOTH
    ):
        raise SystemExit("artifact binding contains unsafe ownership or mode")
    if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
        raise SystemExit("artifact binding contains a hard linked file")
    relative = "." if path == root else path.relative_to(root).as_posix()
    return {
        "ctimeNS": metadata.st_ctime_ns,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "kind": "directory" if stat.S_ISDIR(metadata.st_mode) else "file",
        "mode": stat.S_IMODE(metadata.st_mode),
        "mtimeNS": metadata.st_mtime_ns,
        "path": relative,
        "sha256": file_hash(path) if stat.S_ISREG(metadata.st_mode) else None,
        "size": metadata.st_size,
    }


if not root.exists() or root.is_symlink():
    raise SystemExit("artifact binding root is missing or unsafe")
paths = [root]
if root.is_dir():
    paths.extend(
        sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    )
before = [record(path) for path in paths]
after = [record(path) for path in paths]
if before != after:
    raise SystemExit("artifact changed while its identity was bound")
payload = json.dumps(before, sort_keys=True, separators=(",", ":")).encode("utf-8")
print(hashlib.sha256(b"EasySplat notarization source binding v1\0" + payload).hexdigest())
PY
}

copy_submission_file() {
  /usr/bin/python3 -I - "$1" "$2" <<'PY'
import os
import stat
import sys

source, destination = sys.argv[1:]
source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
destination_fd = -1
try:
    before = os.fstat(source_fd)
    named_before = os.lstat(source)
    fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_uid",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, key) != getattr(named_before, key) for key in fields):
        raise SystemExit("submission source changed before its private copy")
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or before.st_size <= 0
    ):
        raise SystemExit("submission source is unsafe")
    destination_fd = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o400,
    )
    while True:
        chunk = os.read(source_fd, 1024 * 1024)
        if not chunk:
            break
        view = memoryview(chunk)
        while view:
            written = os.write(destination_fd, view)
            if written <= 0:
                raise SystemExit("private submission copy was incomplete")
            view = view[written:]
    os.fsync(destination_fd)
    os.fchmod(destination_fd, 0o400)
    after = os.fstat(source_fd)
    named_after = os.lstat(source)
    if any(
        getattr(before, key) != getattr(after, key)
        or getattr(before, key) != getattr(named_after, key)
        for key in fields
    ):
        raise SystemExit("submission source changed during its private copy")
finally:
    if destination_fd >= 0:
        os.close(destination_fd)
    os.close(source_fd)
PY
}

submission_binding() {
  /usr/bin/python3 -I - "$1" "$2" <<'PY'
import hashlib
import json
import os
import stat
import sys

descriptor = int(sys.argv[1])
path = sys.argv[2]
parent = os.path.dirname(path)


def metadata_record(metadata):
    return {
        "ctimeNS": metadata.st_ctime_ns,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": stat.S_IMODE(metadata.st_mode),
        "mtimeNS": metadata.st_mtime_ns,
        "size": metadata.st_size,
    }


fd_metadata = os.fstat(descriptor)
path_metadata = os.lstat(path)
parent_metadata = os.lstat(parent)
if (
    not stat.S_ISREG(fd_metadata.st_mode)
    or not stat.S_ISREG(path_metadata.st_mode)
    or stat.S_ISLNK(path_metadata.st_mode)
    or fd_metadata.st_uid != os.geteuid()
    or path_metadata.st_uid != os.geteuid()
    or fd_metadata.st_nlink != 1
    or path_metadata.st_nlink != 1
    or fd_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    or path_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    or fd_metadata.st_size <= 0
    or not stat.S_ISDIR(parent_metadata.st_mode)
    or parent_metadata.st_uid != os.geteuid()
    or parent_metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    raise SystemExit("private submission binding is unsafe")
fd_record = metadata_record(fd_metadata)
path_record = metadata_record(path_metadata)
if fd_record != path_record:
    raise SystemExit("private submission descriptor and pathname differ")
digest = hashlib.sha256()
offset = 0
while offset < fd_metadata.st_size:
    chunk = os.pread(descriptor, min(1024 * 1024, fd_metadata.st_size - offset), offset)
    if not chunk:
        raise SystemExit("private submission descriptor ended early")
    digest.update(chunk)
    offset += len(chunk)
payload = {
    "file": fd_record,
    "parent": metadata_record(parent_metadata),
    "sha256": digest.hexdigest(),
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}

PRE_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
ORIGINAL_BINDING="$(artifact_binding "$ARTIFACT_PATH")"
if [ "$ARTIFACT_TYPE" = dmg ]; then
  run_private_command dmg-codesign-before "$CODESIGN_BIN" --verify --strict \
    --verbose=4 "$ARTIFACT_PATH"
  if [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$PRE_HASH" ]; then
    echo "The disk image changed during pre-notarization signature verification." >&2
    exit 1
  fi
fi
SUBMISSION_DIR="$WORK_DIR/submission"
mkdir "$SUBMISSION_DIR"
chmod 700 "$SUBMISSION_DIR"
if [ "$ARTIFACT_TYPE" = app ]; then
  SUBMIT_ARTIFACT="$SUBMISSION_DIR/EasySplat-notarization.zip"
  run_private_command app-archive "$DITTO_BIN" -c -k --keepParent \
    "$ARTIFACT_PATH" "$SUBMIT_ARTIFACT"
  if [ ! -f "$SUBMIT_ARTIFACT" ] || [ -L "$SUBMIT_ARTIFACT" ]; then
    echo "The private app submission archive was not created." >&2
    exit 1
  fi
else
  SUBMIT_ARTIFACT="$SUBMISSION_DIR/EasySplat-notarization.$ARTIFACT_TYPE"
  copy_submission_file "$ARTIFACT_PATH" "$SUBMIT_ARTIFACT"
fi
if [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$PRE_HASH" ] \
    || [ "$(artifact_binding "$ARTIFACT_PATH")" != "$ORIGINAL_BINDING" ]; then
  echo "The source artifact changed while its private submission snapshot was created." >&2
  exit 1
fi
exec 9<"$SUBMIT_ARTIFACT"
SUBMISSION_BINDING_BEFORE="$(submission_binding 9 "$SUBMIT_ARTIFACT")"
SUBMISSION_JSON="$WORK_DIR/submission.json"
SUBMISSION_STDERR="$WORK_DIR/submission.stderr"
require_bound_paths
set +e
(
  exec 5<&- 6<&- 7<&- 8<&-
  run_bounded_process \
    "$SUBMISSION_JSON" "$SUBMISSION_STDERR" 1048576 2097152 \
    "$XCRUN_BIN" notarytool submit "$SUBMIT_ARTIFACT" \
      --keychain-profile "$KEYCHAIN_PROFILE" --wait --timeout 45m \
      --output-format json
)
SUBMISSION_EXIT=$?
set -e
if ! require_bound_paths; then
  exec 9<&-
  exit 1
fi
if ! SUBMISSION_BINDING_AFTER="$(submission_binding 9 "$SUBMIT_ARTIFACT")"; then
  exec 9<&-
  echo "The private notarization submission changed while notarytool opened it." >&2
  exit 1
fi
exec 9<&-
if [ "$SUBMISSION_BINDING_AFTER" != "$SUBMISSION_BINDING_BEFORE" ]; then
  echo "The private notarization submission changed while notarytool opened it." >&2
  exit 1
fi

STATUS="$(/usr/bin/plutil -extract status raw -- "$SUBMISSION_JSON" 2>/dev/null || true)"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -- "$SUBMISSION_JSON" 2>/dev/null || true)"

stable_submission_id() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    && [ "$1" != 00000000-0000-0000-0000-000000000000 ]
}

write_failure_diagnostic() {
  local diagnostic_source="$SUBMISSION_STDERR"
  local diagnostic_name="notarization-submit-failure.txt"
  local log_stderr="$WORK_DIR/notary-log.stderr"
  local raw_log="$WORK_DIR/notary-log.json"
  if stable_submission_id "$SUBMISSION_ID"; then
    require_bound_paths
    set +e
    (
      exec 5<&- 6<&- 7<&- 8<&-
      ulimit -f 8192
      "$XCRUN_BIN" notarytool log "$SUBMISSION_ID" "$raw_log" \
        --keychain-profile "$KEYCHAIN_PROFILE"
    ) >/dev/null 2>"$log_stderr"
    local log_exit=$?
    set -e
    require_bound_paths
    if [ "$log_exit" -eq 0 ] && [ -f "$raw_log" ] \
        && [ "$(/usr/bin/stat -f %z "$raw_log")" -le 4194304 ]; then
      diagnostic_source="$raw_log"
      diagnostic_name="notarization-$SUBMISSION_ID.json"
    elif [ -s "$log_stderr" ]; then
      diagnostic_source="$log_stderr"
    fi
  fi

  write_scrubbed_diagnostic "$diagnostic_source" "$diagnostic_name"
}

SUBMISSION_BYTES="$(/usr/bin/stat -f %z "$SUBMISSION_JSON")"
if [ "$SUBMISSION_EXIT" -ne 0 ] || [ "$SUBMISSION_BYTES" -gt 1048576 ] \
    || [ "$STATUS" != Accepted ] || ! stable_submission_id "$SUBMISSION_ID"; then
  write_failure_diagnostic
  echo "Notarization failed. A scrubbed diagnostic was preserved." >&2
  exit 1
fi
if [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$PRE_HASH" ] \
    || [ "$(artifact_binding "$ARTIFACT_PATH")" != "$ORIGINAL_BINDING" ]; then
  echo "The source artifact changed during notarization submission." >&2
  exit 1
fi

STAPLED=false
DIGEST_FORMAT=sha256-file-v1
CODESIGN_VERIFICATION=notApplicable
SYSTEM_POLICY_VERIFICATION=notApplicable
STAPLER_VERIFICATION=notApplicable
GATEKEEPER_VERIFICATION=notApplicable
if [ "$ARTIFACT_TYPE" = app ]; then
  DIGEST_FORMAT=sha256-tree-v1
  if [ "$(artifact_binding "$ARTIFACT_PATH")" != "$ORIGINAL_BINDING" ]; then
    echo "The app changed before its accepted ticket was stapled." >&2
    exit 1
  fi
  run_private_command app-staple "$XCRUN_BIN" stapler staple "$ARTIFACT_PATH"
  POST_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
  if [ "$PRE_HASH" = "$POST_HASH" ]; then
    echo "Stapling did not change the app artifact." >&2
    exit 1
  fi
  run_private_command app-codesign "$CODESIGN_BIN" --verify --deep --strict \
    --verbose=4 "$ARTIFACT_PATH"
  run_private_command app-syspolicy "$SYSPOLICY_BIN" distribution \
    "$ARTIFACT_PATH"
  run_private_command app-ticket "$XCRUN_BIN" stapler validate "$ARTIFACT_PATH"
  run_private_command app-gatekeeper "$SPCTL_BIN" --assess --type execute \
    "$ARTIFACT_PATH"
  STAPLED=true
  CODESIGN_VERIFICATION=passed
  SYSTEM_POLICY_VERIFICATION=passed
  STAPLER_VERIFICATION=passed
  GATEKEEPER_VERIFICATION=passed
elif [ "$ARTIFACT_TYPE" = dmg ]; then
  if [ "$(artifact_binding "$ARTIFACT_PATH")" != "$ORIGINAL_BINDING" ]; then
    echo "The disk image changed before its accepted ticket was stapled." >&2
    exit 1
  fi
  run_private_command dmg-staple "$XCRUN_BIN" stapler staple "$ARTIFACT_PATH"
  POST_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
  if [ "$PRE_HASH" = "$POST_HASH" ]; then
    echo "Stapling did not change the disk image artifact." >&2
    exit 1
  fi
  run_private_command dmg-codesign-after "$CODESIGN_BIN" --verify --strict \
    --verbose=4 "$ARTIFACT_PATH"
  run_private_command dmg-ticket "$XCRUN_BIN" stapler validate "$ARTIFACT_PATH"
  run_private_command dmg-gatekeeper "$SPCTL_BIN" --assess --type open \
    --context context:primary-signature "$ARTIFACT_PATH"
  STAPLED=true
  CODESIGN_VERIFICATION=passed
  STAPLER_VERIFICATION=passed
  GATEKEEPER_VERIFICATION=passed
else
  POST_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
  if [ "$POST_HASH" != "$PRE_HASH" ]; then
    echo "The ZIP artifact changed after notarization submission." >&2
    exit 1
  fi
fi
if [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$POST_HASH" ]; then
  echo "The artifact changed during post-staple verification." >&2
  exit 1
fi
FINAL_ARTIFACT_BINDING="$(artifact_binding "$ARTIFACT_PATH")"
require_bound_paths
RECEIPT_TEMP="$WORK_DIR/notarization-receipt.json"
printf '{\n  "schemaVersion": 1,\n  "artifactType": "%s",\n  "artifactDigestFormat": "%s",\n  "submissionID": "%s",\n  "status": "Accepted",\n  "preStapleSHA256": "%s",\n  "postStapleSHA256": "%s",\n  "stapled": %s,\n  "verification": {\n    "codesign": "%s",\n    "systemPolicy": "%s",\n    "stapler": "%s",\n    "gatekeeper": "%s"\n  },\n  "downstreamChecksums": "generate-after-notarization"\n}\n' \
  "$ARTIFACT_TYPE" "$DIGEST_FORMAT" "$SUBMISSION_ID" "$PRE_HASH" \
  "$POST_HASH" "$STAPLED" "$CODESIGN_VERIFICATION" \
  "$SYSTEM_POLICY_VERIFICATION" "$STAPLER_VERIFICATION" \
  "$GATEKEEPER_VERIFICATION" \
  >"$RECEIPT_TEMP"
chmod 600 "$RECEIPT_TEMP"
RECEIPT_SHA256="$(
  publish_bound_file receipt "$RECEIPT_TEMP" "$RECEIPT_NAME" 1048576
)"
if ! [[ "$RECEIPT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || ! require_bound_paths \
    || [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$POST_HASH" ] \
    || [ "$(artifact_binding "$ARTIFACT_PATH")" != "$FINAL_ARTIFACT_BINDING" ]; then
  remove_bound_receipt "$RECEIPT_SHA256" || true
  echo "The artifact or publication path changed while the receipt was published." >&2
  exit 1
fi

echo "Notarization accepted and receipt written. Generate downstream checksums from this final artifact." >&2
