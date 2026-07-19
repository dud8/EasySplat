#!/usr/bin/env bash
set -euo pipefail

umask 077

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
  /usr/bin/python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
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
    mode = current.lstat().st_mode
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

scrub_diagnostic() {
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
    ' "$1" >"$2"
}

write_scrubbed_diagnostic() {
  local diagnostic_source="$1"
  local diagnostic_name="$2"
  local diagnostic_temp

  mkdir -p "$DIAGNOSTICS_DIR"
  chmod 700 "$DIAGNOSTICS_DIR"
  diagnostic_temp="$(/usr/bin/mktemp "$DIAGNOSTICS_DIR/.notary-diagnostic.XXXXXX")"
  scrub_diagnostic "$diagnostic_source" "$diagnostic_temp"
  chmod 600 "$diagnostic_temp"
  mv -f "$diagnostic_temp" "$DIAGNOSTICS_DIR/$diagnostic_name"
}

run_private_command() {
  local label="$1"
  local stdout_path="$WORK_DIR/$label.stdout"
  local stderr_path="$WORK_DIR/$label.stderr"
  local command_exit
  local diagnostic_source
  shift

  set +e
  (
    ulimit -f 2048
    "$@"
  ) >"$stdout_path" 2>"$stderr_path"
  command_exit=$?
  set -e
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
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import stat
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
if root.is_file() and not root.is_symlink():
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

PRE_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
SUBMIT_ARTIFACT="$ARTIFACT_PATH"
if [ "$ARTIFACT_TYPE" = app ]; then
  SUBMIT_ARTIFACT="$WORK_DIR/EasySplat-notarization.zip"
  run_private_command app-archive "$DITTO_BIN" -c -k --keepParent \
    "$ARTIFACT_PATH" "$SUBMIT_ARTIFACT"
  if [ ! -f "$SUBMIT_ARTIFACT" ] || [ -L "$SUBMIT_ARTIFACT" ]; then
    echo "The private app submission archive was not created." >&2
    exit 1
  fi
  if [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$PRE_HASH" ]; then
    echo "The app changed while its private submission archive was created." >&2
    exit 1
  fi
fi
SUBMISSION_JSON="$WORK_DIR/submission.json"
SUBMISSION_STDERR="$WORK_DIR/submission.stderr"
set +e
(
  ulimit -f 2048
  "$XCRUN_BIN" notarytool submit "$SUBMIT_ARTIFACT" \
    --keychain-profile "$KEYCHAIN_PROFILE" --wait --output-format json
) >"$SUBMISSION_JSON" 2>"$SUBMISSION_STDERR"
SUBMISSION_EXIT=$?
set -e

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
    set +e
    (
      ulimit -f 8192
      "$XCRUN_BIN" notarytool log "$SUBMISSION_ID" "$raw_log" \
        --keychain-profile "$KEYCHAIN_PROFILE"
    ) >/dev/null 2>"$log_stderr"
    local log_exit=$?
    set -e
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
if [ "$(artifact_sha256 "$ARTIFACT_PATH")" != "$PRE_HASH" ]; then
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
  run_private_command app-staple "$XCRUN_BIN" stapler staple "$ARTIFACT_PATH"
  POST_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
  if [ "$PRE_HASH" = "$POST_HASH" ]; then
    echo "Stapling did not change the app artifact." >&2
    exit 1
  fi
  run_private_command app-codesign "$CODESIGN_BIN" --verify --deep --strict \
    --verbose=4 "$ARTIFACT_PATH"
  run_private_command app-syspolicy "$SYSPOLICY_BIN" distribution --bundle \
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
  run_private_command dmg-staple "$XCRUN_BIN" stapler staple "$ARTIFACT_PATH"
  POST_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
  if [ "$PRE_HASH" = "$POST_HASH" ]; then
    echo "Stapling did not change the disk image artifact." >&2
    exit 1
  fi
  run_private_command dmg-ticket "$XCRUN_BIN" stapler validate "$ARTIFACT_PATH"
  run_private_command dmg-gatekeeper "$SPCTL_BIN" --assess --type open \
    --context context:primary-signature "$ARTIFACT_PATH"
  STAPLED=true
  STAPLER_VERIFICATION=passed
  GATEKEEPER_VERIFICATION=passed
else
  POST_HASH="$(artifact_sha256 "$ARTIFACT_PATH")"
  if [ "$POST_HASH" != "$PRE_HASH" ]; then
    echo "The ZIP artifact changed after notarization submission." >&2
    exit 1
  fi
fi
RECEIPT_PARENT="$(dirname "$RECEIPT_PATH")"
mkdir -p "$RECEIPT_PARENT"
RECEIPT_TEMP="$(/usr/bin/mktemp "$RECEIPT_PARENT/.notarization-receipt.XXXXXX")"
printf '{\n  "schemaVersion": 1,\n  "artifactType": "%s",\n  "artifactDigestFormat": "%s",\n  "submissionID": "%s",\n  "status": "Accepted",\n  "preStapleSHA256": "%s",\n  "postStapleSHA256": "%s",\n  "stapled": %s,\n  "verification": {\n    "codesign": "%s",\n    "systemPolicy": "%s",\n    "stapler": "%s",\n    "gatekeeper": "%s"\n  },\n  "downstreamChecksums": "generate-after-notarization"\n}\n' \
  "$ARTIFACT_TYPE" "$DIGEST_FORMAT" "$SUBMISSION_ID" "$PRE_HASH" \
  "$POST_HASH" "$STAPLED" "$CODESIGN_VERIFICATION" \
  "$SYSTEM_POLICY_VERIFICATION" "$STAPLER_VERIFICATION" \
  "$GATEKEEPER_VERIFICATION" \
  >"$RECEIPT_TEMP"
chmod 600 "$RECEIPT_TEMP"
mv -f "$RECEIPT_TEMP" "$RECEIPT_PATH"

echo "Notarization accepted and receipt written. Generate downstream checksums from this final artifact." >&2
