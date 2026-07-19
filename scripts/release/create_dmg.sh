#!/bin/bash -p
set -euo pipefail

APP_PATH=""
OUT_PATH=""
VOLNAME="EasySplat"
APP_NOTARIZATION_RECEIPT=""
STAGING=""

cleanup() {
  if [ -n "$STAGING" ]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --out)
      OUT_PATH="$2"
      shift 2
      ;;
    --volname)
      VOLNAME="$2"
      shift 2
      ;;
    --app-notarization-receipt)
      APP_NOTARIZATION_RECEIPT="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$APP_PATH" ] || [ -z "$OUT_PATH" ]; then
  echo "Usage: create_dmg.sh --app-path <path> --out <path> [--app-notarization-receipt <path>]" >&2
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi

TEST_MODE="${EASYSPLAT_NOTARY_TEST_MODE:-0}"
if [ "$TEST_MODE" != 0 ] && [ "$TEST_MODE" != 1 ]; then
  echo "EASYSPLAT_NOTARY_TEST_MODE must be 0 or 1." >&2
  exit 64
fi

CODESIGN_BIN=/usr/bin/codesign
XCRUN_BIN=/usr/bin/xcrun
SPCTL_BIN=/usr/sbin/spctl
SYSPOLICY_BIN=/usr/bin/syspolicy_check
HDIUTIL_BIN=/usr/bin/hdiutil
if [ "$TEST_MODE" = 1 ]; then
  CODESIGN_BIN="${EASYSPLAT_NOTARY_CODESIGN_BIN:-}"
  XCRUN_BIN="${EASYSPLAT_NOTARY_XCRUN_BIN:-}"
  SPCTL_BIN="${EASYSPLAT_NOTARY_SPCTL_BIN:-}"
  SYSPOLICY_BIN="${EASYSPLAT_NOTARY_SYSPOLICY_BIN:-}"
  HDIUTIL_BIN="${EASYSPLAT_HDIUTIL_BIN:-}"
elif [ -n "${EASYSPLAT_NOTARY_CODESIGN_BIN:-}" ] \
    || [ -n "${EASYSPLAT_NOTARY_XCRUN_BIN:-}" ] \
    || [ -n "${EASYSPLAT_NOTARY_SPCTL_BIN:-}" ] \
    || [ -n "${EASYSPLAT_NOTARY_SYSPOLICY_BIN:-}" ] \
    || { [ -n "${EASYSPLAT_HDIUTIL_BIN:-}" ] \
      && [ "$EASYSPLAT_HDIUTIL_BIN" != /usr/bin/hdiutil ]; }; then
  echo "Test command overrides require EASYSPLAT_NOTARY_TEST_MODE=1." >&2
  exit 64
fi

for command_path in \
  "$CODESIGN_BIN" "$XCRUN_BIN" "$SPCTL_BIN" "$SYSPOLICY_BIN" "$HDIUTIL_BIN"; do
  if [[ "$command_path" != /* ]] || [ ! -f "$command_path" ] \
      || [ -L "$command_path" ] || [ ! -x "$command_path" ]; then
    echo "A DMG admission command path is invalid." >&2
    exit 64
  fi
done

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_PARENT="$(/usr/bin/dirname "$OUT_PATH")"
mkdir -p "$OUT_PARENT"
STAGING="$(/usr/bin/mktemp -d "$OUT_PARENT/.EasySplat-dmg-staging.XXXXXX")"
chmod 0700 "$STAGING"
STAGED_APP="$STAGING/$(/usr/bin/basename "$APP_PATH")"

verify_app_receipt() {
  local app_path="$1"
  /usr/bin/python3 -I "$ROOT/scripts/release/verify_notarization_receipt.py" \
    --type app \
    --artifact "$app_path" \
    --receipt "$APP_NOTARIZATION_RECEIPT" >/dev/null
}

require_live_apple_admission() {
  local app_path="$1"

  verify_app_receipt "$app_path"
  if ! "$CODESIGN_BIN" --verify --deep --strict "$app_path"; then
    echo "Apple codesign admission failed for the notarized app." >&2
    return 1
  fi
  verify_app_receipt "$app_path"
  if ! "$XCRUN_BIN" stapler validate "$app_path"; then
    echo "Apple stapler admission failed for the notarized app." >&2
    return 1
  fi
  verify_app_receipt "$app_path"
  if ! "$SPCTL_BIN" --assess --type execute "$app_path"; then
    echo "Apple spctl admission failed for the notarized app." >&2
    return 1
  fi
  verify_app_receipt "$app_path"
  if ! "$SYSPOLICY_BIN" distribution "$app_path"; then
    echo "Apple syspolicy_check admission failed for the notarized app." >&2
    return 1
  fi
  verify_app_receipt "$app_path"
}

if [ -n "$APP_NOTARIZATION_RECEIPT" ]; then
  verify_app_receipt "$APP_PATH"
fi
/usr/bin/ditto "$APP_PATH" "$STAGED_APP"
if [ -n "$APP_NOTARIZATION_RECEIPT" ]; then
  require_live_apple_admission "$STAGED_APP"
fi
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT_PATH"

"$HDIUTIL_BIN" create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT_PATH"
"$HDIUTIL_BIN" verify "$OUT_PATH"
if [ -n "$APP_NOTARIZATION_RECEIPT" ]; then
  verify_app_receipt "$APP_PATH"
  verify_app_receipt "$STAGED_APP"
fi

echo "Created DMG at: $OUT_PATH"
