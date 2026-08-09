#!/bin/bash -p
# Submit a signed Mac App Store package to App Store Connect.
#
# The App Store Connect key is the one credential this repository never reads:
# this script validates its metadata, then binds altool to that exact path.
set -euo pipefail

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE=""
EVIDENCE=""
KEY_ID=""
ISSUER_ID=""
APPLE_ID=""
BUNDLE_VERSION=""
BUNDLE_SHORT_VERSION=""
ACTION=""
PACKAGE_SNAPSHOT_ROOT=""
PACKAGE_SNAPSHOT=""
PACKAGE_SNAPSHOT_TOKEN=""
PACKAGE_SNAPSHOT_FD=9
PACKAGE_SNAPSHOT_OPEN=0
RESPONSE_ROOT=""
UPLOAD_RECEIPT=""
PROCESSING_RECEIPT=""
UPLOAD_ATTEMPT=""
UPLOAD_RESPONSE=""
PROCESSING_RESPONSE=""
DELIVERY_ID=""
UPLOAD_ACCEPTED=0
SUBMISSION_COMMITTED=0

PRIVATE_KEY_DIR="$HOME/.appstoreconnect/private_keys"
PRIVATE_KEY_PATH=""
XCRUN=/usr/bin/xcrun
umask 077

read_altool_version() {
  local version_output
  version_output="$("$XCRUN" altool --version 2>&1)" || return 1
  /usr/bin/printf '%s\n' "$version_output" \
    | /usr/bin/grep -E '^[0-9]+(\.[0-9]+){2} \([0-9]+\)$' \
    || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      PACKAGE="$2"
      shift 2
      ;;
    --evidence)
      EVIDENCE="$2"
      shift 2
      ;;
    --key-id)
      KEY_ID="$2"
      shift 2
      ;;
    --issuer-id)
      ISSUER_ID="$2"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="$2"
      shift 2
      ;;
    --bundle-version)
      BUNDLE_VERSION="$2"
      shift 2
      ;;
    --bundle-short-version)
      BUNDLE_SHORT_VERSION="$2"
      shift 2
      ;;
    --validate)
      if [ -n "$ACTION" ]; then
        echo "Choose exactly one of --validate or --upload." >&2
        exit 1
      fi
      ACTION=validate
      shift
      ;;
    --upload)
      if [ -n "$ACTION" ]; then
        echo "Choose exactly one of --validate or --upload." >&2
        exit 1
      fi
      ACTION=upload
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$PACKAGE" ] || [ -z "$KEY_ID" ] \
    || [ -z "$ISSUER_ID" ] || [ -z "$ACTION" ]; then
  echo "Usage: upload_mas_package.sh --package <signed.pkg> [--evidence <provenance.json>] --key-id <id> --issuer-id <uuid> (--validate | --upload --apple-id <id> --bundle-short-version <semver> --bundle-version <n[.n[.n]]>)" >&2
  exit 1
fi

if ! [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "App Store Connect key id must be exactly 10 uppercase letters or digits." >&2
  exit 1
fi
if ! [[ "$ISSUER_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "App Store Connect issuer id must be a lowercase UUID." >&2
  exit 1
fi
if [ "$ACTION" = upload ]; then
  if [ -z "$APPLE_ID" ] || [ -z "$BUNDLE_SHORT_VERSION" ] \
      || [ -z "$BUNDLE_VERSION" ]; then
    echo "--upload requires --apple-id, --bundle-short-version, and --bundle-version." >&2
    exit 1
  fi
  if ! [[ "$APPLE_ID" =~ ^[1-9][0-9]{5,19}$ ]]; then
    echo "App Store Connect Apple ID must be a positive decimal identifier." >&2
    exit 1
  fi
  if ! [[ "$BUNDLE_SHORT_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "App Store submission requires a stable semantic app version." >&2
    exit 1
  fi
  if ! [[ "$BUNDLE_VERSION" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$ ]]; then
    echo "App Store submission requires a build number of up to three dot-separated integers." >&2
    exit 1
  fi
elif [ -n "$APPLE_ID" ] || [ -n "$BUNDLE_SHORT_VERSION" ] \
    || [ -n "$BUNDLE_VERSION" ]; then
  echo "App identity arguments are used only with --upload." >&2
  exit 1
fi

# A caller-supplied command would defeat every check below it.
if [ -n "${EASYSPLAT_ALTOOL_BIN:-}" ]; then
  echo "Upload command overrides are not permitted." >&2
  exit 1
fi
unset GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN GITHUB_TOKEN
unset DEVELOPER_DIR SDKROOT TOOLCHAINS
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

PACKAGE="$(/usr/bin/python3 -I - "$PACKAGE" <<'PY'
import os
import stat
import sys

package = sys.argv[1]
if not os.path.isabs(package) or os.path.normpath(package) != package:
    raise SystemExit("Package path must be absolute and normalized.")
if os.path.realpath(package) != package:
    raise SystemExit("Package path must contain no symlink ancestry.")
if not package.endswith(".pkg"):
    raise SystemExit("App Store submission requires an installer package.")
try:
    metadata = os.lstat(package)
except FileNotFoundError:
    raise SystemExit(f"Package does not exist: {package}")
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
    raise SystemExit("Package must be an ordinary, non-hardlinked regular file.")
if metadata.st_size == 0:
    raise SystemExit("Package must not be empty.")
print(package)
PY
)" || exit 1
if [ -z "$EVIDENCE" ]; then
  EVIDENCE="$PACKAGE.provenance.json"
fi
UPLOAD_RECEIPT="$PACKAGE.upload.json"
PROCESSING_RECEIPT="$PACKAGE.processing.json"
UPLOAD_ATTEMPT="$PACKAGE.upload-attempt.json"

cleanup_snapshot() {
  local status=$?
  trap - EXIT
  if [ "$UPLOAD_ACCEPTED" -eq 1 ] && [ "$SUBMISSION_COMMITTED" -ne 1 ]; then
    echo "An upload was accepted but its receipt could not be committed. The durable attempt marker prevents an automatic re-upload: $UPLOAD_ATTEMPT" >&2
  fi
  if [ "$PACKAGE_SNAPSHOT_OPEN" -eq 1 ] \
      && [ -n "$PACKAGE_SNAPSHOT_TOKEN" ]; then
    if ! /usr/bin/python3 -I \
      "$ROOT/scripts/release/mas_release_evidence.py" cleanup-snapshot \
      --root "$PACKAGE_SNAPSHOT_ROOT" \
      --snapshot "$PACKAGE_SNAPSHOT" \
      --descriptor "$PACKAGE_SNAPSHOT_FD" \
      --token "$PACKAGE_SNAPSHOT_TOKEN" >/dev/null; then
      echo "Private package snapshot was retained because cleanup identity was uncertain: $PACKAGE_SNAPSHOT_ROOT" >&2
      if [ "$SUBMISSION_COMMITTED" -ne 1 ]; then
        status=1
      fi
    fi
    exec 9<&-
  elif [ -n "$PACKAGE_SNAPSHOT_ROOT" ]; then
    echo "Private package snapshot root was retained because ownership was not fully established: $PACKAGE_SNAPSHOT_ROOT" >&2
  fi
  if [ -n "$RESPONSE_ROOT" ]; then
    local -a response_cleanup_arguments
    response_cleanup_arguments=(cleanup-responses --root "$RESPONSE_ROOT")
    if [ -n "$PROCESSING_RESPONSE" ]; then
      response_cleanup_arguments+=(--response "$PROCESSING_RESPONSE")
    fi
    if ! /usr/bin/python3 -I \
      "$ROOT/scripts/release/mas_release_evidence.py" \
      "${response_cleanup_arguments[@]}" >/dev/null; then
      echo "Private App Store responses were retained because cleanup identity was uncertain: $RESPONSE_ROOT" >&2
      if [ "$SUBMISSION_COMMITTED" -ne 1 ]; then
        status=1
      fi
    fi
  fi
  exit "$status"
}
trap cleanup_snapshot EXIT

PRIVATE_KEY_PATH="$PRIVATE_KEY_DIR/AuthKey_${KEY_ID}.p8"
/usr/bin/python3 -I - "$PRIVATE_KEY_PATH" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
try:
    metadata = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(
        f"App Store Connect key {os.path.basename(path)} is not in "
        f"{os.path.dirname(path)}."
    )
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
    raise SystemExit("App Store Connect key must be an ordinary regular file.")
if metadata.st_uid != os.geteuid():
    raise SystemExit("App Store Connect key must be owned by the current user.")
if stat.S_IMODE(metadata.st_mode) & 0o077:
    raise SystemExit("App Store Connect key must not be group- or world-readable.")
if metadata.st_size == 0:
    raise SystemExit("App Store Connect key must not be empty.")
PY

# Copy once into a private, exclusive snapshot. Every gate and altool itself use
# only this immutable candidate; the caller-selected package is never reopened
# by the submission path.
PACKAGE_SNAPSHOT_ROOT="$(/usr/bin/mktemp -d -t easysplat-mas-upload)"
/bin/chmod 0700 "$PACKAGE_SNAPSHOT_ROOT"
PACKAGE_SNAPSHOT_ROOT="$(cd "$PACKAGE_SNAPSHOT_ROOT" && pwd -P)"
PACKAGE_SNAPSHOT="$PACKAGE_SNAPSHOT_ROOT/EasySplat.pkg"
PACKAGE_SNAPSHOT_TOKEN="$(
  /usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" snapshot-package \
    --package "$PACKAGE" \
    --output "$PACKAGE_SNAPSHOT"
)"
exec 9<"$PACKAGE_SNAPSHOT"
PACKAGE_SNAPSHOT_OPEN=1

# The installer signature is what the store checks first, so a package that
# cannot prove its own signature should never reach the upload endpoint.
if ! /usr/sbin/pkgutil --check-signature "$PACKAGE_SNAPSHOT" >/dev/null 2>&1; then
  echo "Package is not signed, so App Store Connect would reject it." >&2
  exit 1
fi
if ! /usr/sbin/pkgutil --check-signature "$PACKAGE_SNAPSHOT" 2>/dev/null \
  | /usr/bin/grep -Eq '(3rd Party Mac Developer Installer|Mac Installer Distribution):'; then
  echo "Package is not signed with a Mac Installer Distribution certificate." >&2
  exit 1
fi

# This fixed helper re-hashes the exact package, validates its strict evidence
# schema and source commit, and repeats installer-signature verification. It
# receives no key id, issuer id, credential path, or command override.
/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" verify \
  --repository "$ROOT" \
  --package "$PACKAGE_SNAPSHOT" \
  --evidence "$EVIDENCE"

/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" verify-snapshot \
  --snapshot "$PACKAGE_SNAPSHOT" \
  --descriptor "$PACKAGE_SNAPSHOT_FD" \
  --token "$PACKAGE_SNAPSHOT_TOKEN" >/dev/null

if [ "$ACTION" = validate ]; then
  altool_status=0
  /usr/bin/python3 -I \
    "$ROOT/scripts/release/run_bound_package_command.py" \
    --snapshot "$PACKAGE_SNAPSHOT" \
    --descriptor "$PACKAGE_SNAPSHOT_FD" \
    --token "$PACKAGE_SNAPSHOT_TOKEN" \
    -- "$XCRUN" altool --validate-app \
      --file "$PACKAGE_SNAPSHOT" \
      --type macos \
      --apiKey "$KEY_ID" \
      --apiIssuer "$ISSUER_ID" \
      --p8-file-path "$PRIVATE_KEY_PATH" || altool_status=$?
  /usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" verify-snapshot \
    --snapshot "$PACKAGE_SNAPSHOT" \
    --descriptor "$PACKAGE_SNAPSHOT_FD" \
    --token "$PACKAGE_SNAPSHOT_TOKEN" >/dev/null
  if [ "$altool_status" -ne 0 ]; then
    exit "$altool_status"
  fi
  echo "Validated $(/usr/bin/basename "$PACKAGE") against App Store Connect."
  exit 0
fi

submission_identity=(
  --repository "$ROOT"
  --package "$PACKAGE"
  --evidence "$EVIDENCE"
  --apple-id "$APPLE_ID"
  --expected-version "$BUNDLE_SHORT_VERSION"
  --expected-build "$BUNDLE_VERSION"
)

cleanup_superseded_upload_attempt() {
  if [ ! -e "$UPLOAD_ATTEMPT" ] && [ ! -L "$UPLOAD_ATTEMPT" ]; then
    return 0
  fi
  local response
  if ! response="$(/usr/bin/python3 -I \
    "$ROOT/scripts/release/mas_release_evidence.py" verify-upload-attempt \
    "${submission_identity[@]}" \
    --attempt "$UPLOAD_ATTEMPT" \
    --print-response-path)"; then
    echo "A superseded upload-attempt marker was retained because it did not validate: $UPLOAD_ATTEMPT" >&2
    return 0
  fi
  if ! /usr/bin/python3 -I \
    "$ROOT/scripts/release/mas_release_evidence.py" cleanup-upload-attempt \
    "${submission_identity[@]}" \
    --attempt "$UPLOAD_ATTEMPT" \
    --response "$response" \
    --upload-receipt "$UPLOAD_RECEIPT" >/dev/null; then
    echo "Superseded upload-attempt evidence was retained because cleanup identity was uncertain: $UPLOAD_ATTEMPT" >&2
    return 0
  fi
  UPLOAD_RESPONSE=""
}

if [ -e "$PROCESSING_RECEIPT" ] || [ -L "$PROCESSING_RECEIPT" ]; then
  /usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" verify-processing \
    "${submission_identity[@]}" \
    --upload-receipt "$UPLOAD_RECEIPT" \
    --processing-receipt "$PROCESSING_RECEIPT"
  SUBMISSION_COMMITTED=1
  cleanup_superseded_upload_attempt
  echo "$(/usr/bin/basename "$PACKAGE") already has verified terminal processing evidence."
  exit 0
fi

if [ -e "$UPLOAD_RECEIPT" ] || [ -L "$UPLOAD_RECEIPT" ]; then
  DELIVERY_ID="$(/usr/bin/python3 -I \
    "$ROOT/scripts/release/mas_release_evidence.py" verify-upload \
    "${submission_identity[@]}" \
    --receipt "$UPLOAD_RECEIPT" \
    --print-delivery-id)"
  SUBMISSION_COMMITTED=1
  cleanup_superseded_upload_attempt
  echo "Resuming App Store processing status without uploading again."
else
  if [ -e "$UPLOAD_ATTEMPT" ] || [ -L "$UPLOAD_ATTEMPT" ]; then
    echo "Recovering the accepted upload from its durable pending response."
    UPLOAD_RESPONSE="$(/usr/bin/python3 -I \
      "$ROOT/scripts/release/mas_release_evidence.py" verify-upload-attempt \
      "${submission_identity[@]}" \
      --attempt "$UPLOAD_ATTEMPT" \
      --print-response-path)"
    ALTOOL_VERSION="$(/usr/bin/python3 -I \
      "$ROOT/scripts/release/mas_release_evidence.py" verify-upload-attempt \
      "${submission_identity[@]}" \
      --attempt "$UPLOAD_ATTEMPT" \
      --print-altool-version)"
    if [ ! -e "$UPLOAD_RESPONSE" ] || [ -L "$UPLOAD_RESPONSE" ]; then
      echo "The prior upload may have reached Apple, but its response is unavailable. The attempt marker was retained and EasySplat will not upload this build again automatically." >&2
      exit 1
    fi
  else
    ALTOOL_VERSION="$(read_altool_version)"
    if ! [[ "$ALTOOL_VERSION" =~ ^[0-9]+(\.[0-9]+){2}[[:space:]]\([0-9]+\)$ ]]; then
      echo "Could not bind the altool version before the upload attempt." >&2
      exit 1
    fi
    UPLOAD_RESPONSE="$(/usr/bin/python3 -I \
      "$ROOT/scripts/release/mas_release_evidence.py" start-upload-attempt \
      "${submission_identity[@]}" \
      --altool-version "$ALTOOL_VERSION" \
      --output "$UPLOAD_ATTEMPT")"
    set +e
    /usr/bin/python3 -I \
      "$ROOT/scripts/release/run_bound_package_command.py" \
      --snapshot "$PACKAGE_SNAPSHOT" \
      --descriptor "$PACKAGE_SNAPSHOT_FD" \
      --token "$PACKAGE_SNAPSHOT_TOKEN" \
      -- "$XCRUN" altool --upload-app \
        --file "$PACKAGE_SNAPSHOT" \
        --type macos \
        --apiKey "$KEY_ID" \
        --apiIssuer "$ISSUER_ID" \
        --p8-file-path "$PRIVATE_KEY_PATH" \
        --output-format json \
      | /usr/bin/python3 -I \
        "$ROOT/scripts/release/mas_release_evidence.py" capture-response \
        --output "$UPLOAD_RESPONSE"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    altool_status="${pipeline_status[0]:-1}"
    capture_status="${pipeline_status[1]:-1}"
    /usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" verify-snapshot \
      --snapshot "$PACKAGE_SNAPSHOT" \
      --descriptor "$PACKAGE_SNAPSHOT_FD" \
      --token "$PACKAGE_SNAPSHOT_TOKEN" >/dev/null
    if [ "$altool_status" -eq 0 ]; then
      UPLOAD_ACCEPTED=1
    else
      exit "$altool_status"
    fi
    if [ "$capture_status" -ne 0 ]; then
      exit "$capture_status"
    fi
  fi
  if ! [[ "$ALTOOL_VERSION" =~ ^[0-9]+(\.[0-9]+){2}[[:space:]]\([0-9]+\)$ ]]; then
    echo "Could not bind the altool version that accepted the upload." >&2
    exit 1
  fi
  /usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" record-upload \
    "${submission_identity[@]}" \
    --altool-version "$ALTOOL_VERSION" \
    --response "$UPLOAD_RESPONSE" \
    --output "$UPLOAD_RECEIPT"
  DELIVERY_ID="$(/usr/bin/python3 -I \
    "$ROOT/scripts/release/mas_release_evidence.py" verify-upload \
    "${submission_identity[@]}" \
    --receipt "$UPLOAD_RECEIPT" \
    --print-delivery-id)"
  SUBMISSION_COMMITTED=1
  cleanup_superseded_upload_attempt
fi

if ! [[ "$DELIVERY_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "Could not bind the exact App Store delivery ID." >&2
  exit 1
fi

if [ -z "$RESPONSE_ROOT" ]; then
  RESPONSE_ROOT="$(/usr/bin/mktemp -d -t easysplat-mas-response)"
  /bin/chmod 0700 "$RESPONSE_ROOT"
  RESPONSE_ROOT="$(cd "$RESPONSE_ROOT" && pwd -P)"
fi
PROCESSING_RESPONSE="$RESPONSE_ROOT/processing-response.json"
status_result=0
"$XCRUN" altool --build-status \
  --delivery-id "$DELIVERY_ID" \
  --wait \
  --apiKey "$KEY_ID" \
  --apiIssuer "$ISSUER_ID" \
  --p8-file-path "$PRIVATE_KEY_PATH" \
  --output-format json >"$PROCESSING_RESPONSE" || status_result=$?
/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" verify-snapshot \
  --snapshot "$PACKAGE_SNAPSHOT" \
  --descriptor "$PACKAGE_SNAPSHOT_FD" \
  --token "$PACKAGE_SNAPSHOT_TOKEN" >/dev/null
if [ "$status_result" -ne 0 ]; then
  exit "$status_result"
fi
ALTOOL_VERSION="$(read_altool_version)"
if ! [[ "$ALTOOL_VERSION" =~ ^[0-9]+(\.[0-9]+){2}[[:space:]]\([0-9]+\)$ ]]; then
  echo "Could not bind the altool version that reported processing status." >&2
  exit 1
fi
/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" record-processing \
  "${submission_identity[@]}" \
  --upload-receipt "$UPLOAD_RECEIPT" \
  --altool-version "$ALTOOL_VERSION" \
  --response "$PROCESSING_RESPONSE" \
  --output "$PROCESSING_RECEIPT"
echo "Uploaded and processed $(/usr/bin/basename "$PACKAGE") in App Store Connect."
