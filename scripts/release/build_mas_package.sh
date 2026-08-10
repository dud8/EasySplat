#!/bin/bash -p
# Wrap a store-signed app in the installer package App Store Connect accepts.
#
# The app must already be signed for the store: this step only wraps it, so it
# refuses anything it cannot prove is a store artifact rather than producing a
# package that fails on submission.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/strict_semver.sh
source "$ROOT/scripts/release/lib/strict_semver.sh"

APP=""
APP_SIGNING_RECEIPT=""
APP_VERSION=""
APP_BUILD=""
IDENTITY_FINGERPRINT=""
TEAM_ID=""
SOURCE_COMMIT=""
OUT_DIR="$ROOT/release/MAS"

PRODUCTBUILD=/usr/bin/productbuild
PKGUTIL=/usr/sbin/pkgutil
CODESIGN=/usr/bin/codesign

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP="$2"
      shift 2
      ;;
    --app-signing-receipt)
      APP_SIGNING_RECEIPT="$2"
      shift 2
      ;;
    --app-version)
      APP_VERSION="$2"
      shift 2
      ;;
    --app-build)
      APP_BUILD="$2"
      shift 2
      ;;
    --identity-fingerprint)
      IDENTITY_FINGERPRINT="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    --source-commit)
      SOURCE_COMMIT="$2"
      shift 2
      ;;
    --output-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$APP" ] || [ -z "$APP_VERSION" ] \
    || [ -z "$IDENTITY_FINGERPRINT" ] || [ -z "$TEAM_ID" ]; then
  echo "Usage: build_mas_package.sh --app <EasySplat.app> [--app-signing-receipt <json>] --app-version <semver> [--app-build <n[.n[.n]]>] --identity-fingerprint <sha1> --team-id <id> [--source-commit <40-hex>] [--output-dir <absolute-path>]" >&2
  exit 1
fi
if ! [[ "$IDENTITY_FINGERPRINT" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "Store packaging requires an exact 40-hex installer identity fingerprint." >&2
  exit 1
fi
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Store packaging requires an exact 10-character Team ID." >&2
  exit 1
fi
if ! easysplat_is_strict_semver_stable "$APP_VERSION"; then
  echo "Store packaging requires a stable semantic version: $APP_VERSION" >&2
  exit 1
fi
if [ -n "$APP_BUILD" ] \
    && ! [[ "$APP_BUILD" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$ ]]; then
  echo "Store packaging requires a build number of up to three dot-separated integers." >&2
  exit 1
fi
if [ -n "$SOURCE_COMMIT" ] && ! [[ "$SOURCE_COMMIT" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "Reviewed source commit must be exactly 40 hexadecimal characters." >&2
  exit 1
fi
# Every check below reads the app through these commands, so a caller-supplied
# replacement would decide the answer instead of the artifact.
if [ -n "${EASYSPLAT_PRODUCTBUILD_BIN:-}" ] || [ -n "${EASYSPLAT_PKGUTIL_BIN:-}" ]; then
  echo "Store packaging command overrides are not permitted." >&2
  exit 1
fi
unset GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN GITHUB_TOKEN
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

APP="$(/usr/bin/python3 -I - "$APP" <<'PY'
import os
import stat
import sys

app = sys.argv[1]
if not os.path.isabs(app) or os.path.normpath(app) != app:
    raise SystemExit("App path must be absolute and normalized.")
if os.path.realpath(app) != app:
    raise SystemExit("App path must contain no symlink ancestry.")
if not app.endswith(".app"):
    raise SystemExit("Store packaging expects an app bundle.")
try:
    metadata = os.lstat(app)
except FileNotFoundError:
    raise SystemExit(f"App bundle does not exist: {app}")
if not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit("App bundle must be an ordinary directory.")
for relative in (
    "Contents/embedded.provisionprofile",
    "Contents/MacOS/EasySplatApp",
    "Contents/Helpers/bin/colmap",
    "Contents/Helpers/bin/easysplat-train",
    "Contents/Helpers/lib/libomp.dylib",
    "Contents/Resources/Toolchain/default.metallib",
):
    path = os.path.join(app, relative)
    entry = os.lstat(path) if os.path.lexists(path) else None
    if entry is None or not stat.S_ISREG(entry.st_mode) or entry.st_nlink != 1:
        raise SystemExit(f"Store app is missing a sealed file: {relative}")
print(app)
PY
)" || exit 1

if [ -z "$APP_SIGNING_RECEIPT" ]; then
  APP_SIGNING_RECEIPT="${APP}-signing.json"
fi
if [ ! -f "$APP_SIGNING_RECEIPT" ] || [ -L "$APP_SIGNING_RECEIPT" ]; then
  echo "Store packaging requires the app signing receipt: $APP_SIGNING_RECEIPT" >&2
  exit 1
fi

OUT_DIR="$(/usr/bin/python3 -I - "$OUT_DIR" <<'PY'
import os
import sys

out = sys.argv[1]
if not os.path.isabs(out) or os.path.normpath(out) != out:
    raise SystemExit("Output directory must be absolute and normalized.")
if os.path.realpath(out) != out:
    raise SystemExit("Output directory path must contain no symlink ancestry.")
print(out)
PY
)" || exit 1

# A store app carries the sandbox on itself and inheritance on each helper. If
# that is not what is inside the signature, the package would be rejected after
# upload rather than here.
SEALED_ENTITLEMENTS="$(/usr/bin/mktemp -t easysplat-sealed-entitlements)"
PREPARED_EVIDENCE_DIRECTORY=""
PREPARED_EVIDENCE=""
STAGED_PACKAGE=""
STAGED_EVIDENCE=""
STAGED_CHECKSUM=""
cleanup() {
  local status=$?
  trap - EXIT
  /bin/rm -f -- "$SEALED_ENTITLEMENTS"
  if [ -n "$PREPARED_EVIDENCE_DIRECTORY" ]; then
    for staged in \
      "$PREPARED_EVIDENCE" "$STAGED_PACKAGE" "$STAGED_EVIDENCE" "$STAGED_CHECKSUM"; do
      if [ -n "$staged" ] && [ -f "$staged" ] && [ ! -L "$staged" ]; then
        /bin/rm -f -- "$staged"
      fi
    done
    if [ -d "$PREPARED_EVIDENCE_DIRECTORY" ] \
        && ! /bin/rmdir -- "$PREPARED_EVIDENCE_DIRECTORY" 2>/dev/null; then
      echo "Retained non-empty MAS staging directory: $PREPARED_EVIDENCE_DIRECTORY" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
sealed_entitlements() {
  "$CODESIGN" -d --entitlements - --xml "$1" 2>/dev/null || true
}
{
  sealed_entitlements "$APP"
  for helper in bin/colmap bin/easysplat-train; do
    sealed_entitlements "$APP/Contents/Helpers/$helper"
  done
} >"$SEALED_ENTITLEMENTS"
/usr/bin/python3 -I - "$SEALED_ENTITLEMENTS" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

documents = re.findall(
    rb"<\?xml.*?</plist>", Path(sys.argv[1]).read_bytes(), re.DOTALL
)
if len(documents) != 3:
    raise SystemExit(
        "Store packaging expects sealed entitlements on the app and both helper "
        f"executables; found {len(documents)}."
    )
app, *helpers = [plistlib.loads(document) for document in documents]
if app.get("com.apple.security.app-sandbox") is not True:
    raise SystemExit("App is not sandboxed, so it is not a store build.")
if not str(app.get("com.apple.application-identifier", "")).strip():
    raise SystemExit("App does not claim the identifier its profile issues.")
for index, helper in enumerate(helpers):
    if helper != {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.inherit": True,
    }:
        raise SystemExit(
            f"Bundled helper {index} does not inherit the sandbox and nothing else."
        )
PY
if [ -n "$(sealed_entitlements "$APP/Contents/Helpers/lib/libomp.dylib")" ]; then
  echo "A bundled library must not claim entitlements it cannot carry." >&2
  exit 1
fi
"$CODESIGN" --verify --deep --strict "$APP"

# The store rejects a package containing any quarantined file (ITMS-91109), and
# it does so after the upload, so the refusal belongs here.
quarantined="$(
  /usr/bin/find "$APP" -type f \
    -exec /usr/bin/xattr -p com.apple.quarantine {} \; -print 2>/dev/null \
    | /usr/bin/grep "^$APP" || true
)"
if [ -n "$quarantined" ]; then
  echo "App carries quarantined files, which the store refuses:" >&2
  printf '%s\n' "$quarantined" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
PACKAGE="$OUT_DIR/EasySplat-$APP_VERSION.pkg"
PACKAGE_SHA256="$PACKAGE.sha256"
EVIDENCE="$PACKAGE.provenance.json"
if [ -e "$PACKAGE" ] || [ -L "$PACKAGE" ] \
    || [ -e "$PACKAGE_SHA256" ] || [ -L "$PACKAGE_SHA256" ] \
    || [ -e "$EVIDENCE" ] || [ -L "$EVIDENCE" ]; then
  echo "Refusing to replace existing MAS package output." >&2
  exit 1
fi

PREPARED_EVIDENCE_DIRECTORY="$(
  /usr/bin/mktemp -d "$OUT_DIR/.easysplat-mas-package.XXXXXX"
)"
/bin/chmod 0700 "$PREPARED_EVIDENCE_DIRECTORY"
PREPARED_EVIDENCE_DIRECTORY="$(
  cd "$PREPARED_EVIDENCE_DIRECTORY" && pwd -P
)"
PREPARED_EVIDENCE="$PREPARED_EVIDENCE_DIRECTORY/prepared.json"
STAGED_PACKAGE="$PREPARED_EVIDENCE_DIRECTORY/EasySplat.pkg"
STAGED_EVIDENCE="$PREPARED_EVIDENCE_DIRECTORY/EasySplat.pkg.provenance.json"
STAGED_CHECKSUM="$PREPARED_EVIDENCE_DIRECTORY/EasySplat.pkg.sha256"
source_commit_arguments=()
if [ -n "$SOURCE_COMMIT" ]; then
  source_commit_arguments+=(--source-commit "$SOURCE_COMMIT")
fi
app_build_arguments=()
if [ -n "$APP_BUILD" ]; then
  app_build_arguments+=(--expected-build "$APP_BUILD")
fi
/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" prepare \
  --repository "$ROOT" \
  --app "$APP" \
  --app-signing-receipt "$APP_SIGNING_RECEIPT" \
  --expected-version "$APP_VERSION" \
  "${app_build_arguments[@]}" \
  --expected-bundle-id com.easysplat.app \
  --expected-team-id "$TEAM_ID" \
  "${source_commit_arguments[@]}" \
  --output "$PREPARED_EVIDENCE"

"$PRODUCTBUILD" \
  --component "$APP" /Applications \
  --sign "$IDENTITY_FINGERPRINT" \
  "$STAGED_PACKAGE"
/bin/chmod 0600 "$STAGED_PACKAGE"

if ! "$PKGUTIL" --check-signature "$STAGED_PACKAGE" \
  | /usr/bin/grep -Eq '(3rd Party Mac Developer Installer|Mac Installer Distribution):'; then
  echo "Package was not signed by a Mac Installer Distribution certificate." >&2
  exit 1
fi
if ! "$PKGUTIL" --check-signature "$STAGED_PACKAGE" | /usr/bin/grep -Fq "$TEAM_ID"; then
  echo "Package installer certificate does not carry the expected Team ID." >&2
  exit 1
fi

/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" finalize \
  --repository "$ROOT" \
  --app "$APP" \
  --app-signing-receipt "$APP_SIGNING_RECEIPT" \
  --package "$STAGED_PACKAGE" \
  --prepared "$PREPARED_EVIDENCE" \
  --expected-team-id "$TEAM_ID" \
  --output "$STAGED_EVIDENCE"
/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" publish-checksum \
  --package "$STAGED_PACKAGE" \
  --output "$STAGED_CHECKSUM" >/dev/null
/bin/rm -f -- "$PREPARED_EVIDENCE"
PREPARED_EVIDENCE=""
/usr/bin/python3 -I "$ROOT/scripts/release/mas_release_evidence.py" publish-release-set \
  --staging-directory "$PREPARED_EVIDENCE_DIRECTORY" \
  --package-output "$PACKAGE" \
  --evidence-output "$EVIDENCE" \
  --checksum-output "$PACKAGE_SHA256"
echo "Store package ready: $PACKAGE"
echo "Store package evidence ready: $EVIDENCE"
