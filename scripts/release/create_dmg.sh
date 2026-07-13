#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
OUT_PATH=""
VOLNAME="EasySplat"

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
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$APP_PATH" ] || [ -z "$OUT_PATH" ]; then
  echo "Usage: create_dmg.sh --app-path <path> --out <path>" >&2
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi

HDIUTIL_BIN="${EASYSPLAT_HDIUTIL_BIN:-hdiutil}"
if ! command -v "$HDIUTIL_BIN" >/dev/null 2>&1 && [ ! -x "$HDIUTIL_BIN" ]; then
  echo "hdiutil is required to create the disk image." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGING="$ROOT/build/dmg_staging"
trap 'rm -rf "$STAGING"' EXIT

rm -rf "$STAGING"
mkdir -p "$STAGING"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUT_PATH")"
rm -f "$OUT_PATH"

"$HDIUTIL_BIN" create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT_PATH"
"$HDIUTIL_BIN" verify "$OUT_PATH"

echo "Created DMG at: $OUT_PATH"
