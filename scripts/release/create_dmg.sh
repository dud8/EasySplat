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

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install with: brew install create-dmg" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGING="$ROOT/build/dmg_staging"
DMG_HDIUTIL_RETRIES="${EASYSPLAT_DMG_HDIUTIL_RETRIES:-20}"
DMG_SKIP_JENKINS="${EASYSPLAT_DMG_SKIP_JENKINS:-}"
DMG_SANDBOX_SAFE="${EASYSPLAT_DMG_SANDBOX_SAFE:-}"

rm -rf "$STAGING"
mkdir -p "$STAGING"

cp -R "$APP_PATH" "$STAGING/"

rm -f "$OUT_PATH"

CREATE_DMG_ARGS=(
  --volname "$VOLNAME"
  --window-size 600 400
  --icon-size 120
  --icon "$(basename "$APP_PATH")" 170 200
  --app-drop-link 430 200
  --hdiutil-retries "$DMG_HDIUTIL_RETRIES"
)

if [ -n "$DMG_SKIP_JENKINS" ] || [ -n "${CI:-}" ]; then
  CREATE_DMG_ARGS+=(--skip-jenkins)
fi

if [ -n "$DMG_SANDBOX_SAFE" ] || [ -n "${CI:-}" ]; then
  CREATE_DMG_ARGS+=(--sandbox-safe)
fi

create-dmg \
  "${CREATE_DMG_ARGS[@]}" \
  "$OUT_PATH" \
  "$STAGING"

echo "Created DMG at: $OUT_PATH"
