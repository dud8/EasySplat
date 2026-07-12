#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_VERSION=""
TOOLCHAIN_VERSION=""
MANIFEST_URL=""
CORE_ARTIFACT_URL=""
DA3_BASE_ARTIFACT_URL=""
DA3_SMALL_ARTIFACT_URL=""
PROJECT_URL=""
PORT="${EASYSPLAT_DEV_PORT:-8000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-version)
      APP_VERSION="$2"
      shift 2
      ;;
    --toolchain-version)
      TOOLCHAIN_VERSION="$2"
      shift 2
      ;;
    --manifest-url)
      MANIFEST_URL="$2"
      shift 2
      ;;
    --artifact-url)
      CORE_ARTIFACT_URL="$2"
      shift 2
      ;;
    --core-artifact-url)
      CORE_ARTIFACT_URL="$2"
      shift 2
      ;;
    --da3-base-artifact-url)
      DA3_BASE_ARTIFACT_URL="$2"
      shift 2
      ;;
    --da3-small-artifact-url)
      DA3_SMALL_ARTIFACT_URL="$2"
      shift 2
      ;;
    --project-url)
      PROJECT_URL="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$APP_VERSION" ] || [ -z "$TOOLCHAIN_VERSION" ]; then
  echo "Usage: build_dmg.sh --app-version <semver> --toolchain-version <semver> [--manifest-url <url>] [--core-artifact-url <url>] [--da3-base-artifact-url <url>] [--da3-small-artifact-url <url>] [--project-url <url>] [--port <port>]" >&2
  exit 1
fi

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
if ! [[ "$APP_VERSION" =~ $SEMVER_RE ]]; then
  echo "Invalid app semantic version: $APP_VERSION" >&2
  exit 1
fi
if ! [[ "$TOOLCHAIN_VERSION" =~ $SEMVER_RE ]]; then
  echo "Invalid toolchain semantic version: $TOOLCHAIN_VERSION" >&2
  exit 1
fi

case "${EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE:-0}" in
  ""|0|false|FALSE|no|NO|off|OFF) ;;
  *)
    echo "build_dmg.sh refuses EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE; release builds require pinned DA3 git provenance." >&2
    exit 1
    ;;
esac

if [ -z "$MANIFEST_URL" ]; then
  MANIFEST_URL="http://localhost:$PORT/manifest.json"
fi
if [ -z "$CORE_ARTIFACT_URL" ]; then
  CORE_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-macos-arm64-$TOOLCHAIN_VERSION-core.zip"
fi
if [ -z "$DA3_BASE_ARTIFACT_URL" ]; then
  DA3_BASE_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-geometry-da3-base-$TOOLCHAIN_VERSION.zip"
fi
if [ -z "$DA3_SMALL_ARTIFACT_URL" ]; then
  DA3_SMALL_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-geometry-da3-small-$TOOLCHAIN_VERSION.zip"
fi

APP_VERSION_MINIMUM="$APP_VERSION"
APP_RELEASE_VERSION="${APP_VERSION%%+*}"
APP_RELEASE_VERSION="${APP_RELEASE_VERSION%%-*}"
IFS='.' read -r APP_VERSION_MAJOR APP_VERSION_MINOR _ <<< "$APP_RELEASE_VERSION"
APP_VERSION_MAX_EXCLUSIVE="$APP_VERSION_MAJOR.$((10#$APP_VERSION_MINOR + 1)).0"

if command -v xcodebuild >/dev/null 2>&1; then
  if ! xcodebuild -license check >/dev/null 2>&1; then
    echo "Xcode license not accepted. Run: sudo xcodebuild -license accept" >&2
    exit 1
  fi
fi

TOOLCHAINS="$ROOT/Toolchains"
OUT="$TOOLCHAINS/out"
CORE_ZIP="$OUT/toolchain-macos-arm64-$TOOLCHAIN_VERSION-core.zip"
DA3_BASE_ZIP="$OUT/toolchain-geometry-da3-base-$TOOLCHAIN_VERSION.zip"
DA3_SMALL_ZIP="$OUT/toolchain-geometry-da3-small-$TOOLCHAIN_VERSION.zip"
MANIFEST="$TOOLCHAINS/manifest.json"
PUB="$TOOLCHAINS/public_key_ed25519.txt"
PRIV="$TOOLCHAINS/private_key_ed25519.txt"

"$ROOT/scripts/toolchain/build_openssl.sh"
"$ROOT/scripts/toolchain/build_colmap.sh"
"$ROOT/scripts/toolchain/build_msplat.sh"
"$ROOT/scripts/toolchain/build_da3_mps.sh"
"$ROOT/scripts/toolchain/package_toolchain.sh" --version "$TOOLCHAIN_VERSION"

if [ ! -f "$PUB" ] || [ ! -f "$PRIV" ]; then
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool generate-keypair \
    --public-key-out "$PUB" \
    --private-key-out "$PRIV"
fi
chmod 600 "$PRIV"

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool \
  --version "$TOOLCHAIN_VERSION" \
  --published-at "$PUBLISHED_AT" \
  --core-zip "$CORE_ZIP" \
  --core-url "$CORE_ARTIFACT_URL" \
  --da3-base-zip "$DA3_BASE_ZIP" \
  --da3-base-url "$DA3_BASE_ARTIFACT_URL" \
  --da3-small-zip "$DA3_SMALL_ZIP" \
  --da3-small-url "$DA3_SMALL_ARTIFACT_URL" \
  --app-version-minimum "$APP_VERSION_MINIMUM" \
  --app-version-maximum-exclusive "$APP_VERSION_MAX_EXCLUSIVE" \
  --private-key-file "$PRIV" \
  --manifest-out "$MANIFEST"

build_app_args=(
  --manifest-url "$MANIFEST_URL"
  --public-key-path "$PUB"
  --version "$APP_VERSION"
)
if [ -n "$PROJECT_URL" ]; then
  build_app_args+=(--project-url "$PROJECT_URL")
fi

"$ROOT/scripts/release/build_app.sh" "${build_app_args[@]}"

APP_PATH="$ROOT/build/Export/EasySplat.app"
OUT_DIR="$ROOT/release/DMG"
DMG_PATH="$OUT_DIR/EasySplat-$APP_VERSION.dmg"

mkdir -p "$OUT_DIR"

"$ROOT/scripts/release/create_dmg.sh" \
  --app-path "$APP_PATH" \
  --out "$DMG_PATH" \
  --volname "EasySplat"

echo "DMG ready: $DMG_PATH"
