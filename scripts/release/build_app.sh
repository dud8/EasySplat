#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_URL=""
PUBLIC_KEY_PATH=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-url)
      MANIFEST_URL="$2"
      shift 2
      ;;
    --public-key-path)
      PUBLIC_KEY_PATH="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$MANIFEST_URL" ] || [ -z "$PUBLIC_KEY_PATH" ] || [ -z "$VERSION" ]; then
  echo "Usage: build_app.sh --manifest-url <url> --public-key-path <path> --version <semver>" >&2
  exit 1
fi

if [ ! -f "$PUBLIC_KEY_PATH" ]; then
  echo "Missing public key at $PUBLIC_KEY_PATH" >&2
  exit 1
fi

MANIFEST_RESOURCE="$ROOT/EasySplatApp/Resources/toolchain_manifest_url.txt"
PUBLIC_KEY_RESOURCE="$ROOT/EasySplatApp/Resources/public_key_ed25519.txt"

ORIG_MANIFEST=""
ORIG_PUBLIC=""

if [ -f "$MANIFEST_RESOURCE" ]; then
  ORIG_MANIFEST="$(cat "$MANIFEST_RESOURCE")"
fi

if [ -f "$PUBLIC_KEY_RESOURCE" ]; then
  ORIG_PUBLIC="$(cat "$PUBLIC_KEY_RESOURCE")"
fi

cleanup() {
  if [ -n "$ORIG_MANIFEST" ]; then
    printf "%s" "$ORIG_MANIFEST" > "$MANIFEST_RESOURCE"
  fi
  if [ -n "$ORIG_PUBLIC" ]; then
    printf "%s" "$ORIG_PUBLIC" > "$PUBLIC_KEY_RESOURCE"
  fi
}
trap cleanup EXIT

printf "%s" "$MANIFEST_URL" > "$MANIFEST_RESOURCE"
cp "$PUBLIC_KEY_PATH" "$PUBLIC_KEY_RESOURCE"

DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Export"
APP_PATH="$DERIVED/Build/Products/Release/EasySplatApp.app"

rm -rf "$DERIVED" "$OUT"

xcodebuild \
  -scheme EasySplatApp \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  build

mkdir -p "$OUT"
cp -R "$APP_PATH" "$OUT/EasySplatApp.app"

echo "Built app at: $OUT/EasySplatApp.app"
