#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION=""
MANIFEST_URL=""
CORE_ARTIFACT_URL=""
MODELS_ARTIFACT_URL=""
PROJECT_URL=""
PORT="${EASYSPLAT_DEV_PORT:-8000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
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
    --models-artifact-url)
      MODELS_ARTIFACT_URL="$2"
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

if [ -z "$VERSION" ]; then
  echo "Usage: build_dmg.sh --version <semver> [--manifest-url <url>] [--core-artifact-url <url>] [--models-artifact-url <url>] [--project-url <url>] [--port <port>]" >&2
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
  CORE_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-macos-arm64-$VERSION-core.zip"
fi
if [ -z "$MODELS_ARTIFACT_URL" ]; then
  MODELS_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-macos-arm64-$VERSION-models.zip"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  if ! xcodebuild -license check >/dev/null 2>&1; then
    echo "Xcode license not accepted. Run: sudo xcodebuild -license accept" >&2
    exit 1
  fi
fi

TOOLCHAINS="$ROOT/Toolchains"
OUT="$TOOLCHAINS/out"
CORE_ZIP="$OUT/toolchain-macos-arm64-$VERSION-core.zip"
MODELS_ZIP="$OUT/toolchain-macos-arm64-$VERSION-models.zip"
MANIFEST="$TOOLCHAINS/manifest.json"
PUB="$TOOLCHAINS/public_key_ed25519.txt"
PRIV="$TOOLCHAINS/private_key_ed25519.txt"

"$ROOT/scripts/toolchain/build_colmap.sh"
"$ROOT/scripts/toolchain/build_openssl.sh"
"$ROOT/scripts/toolchain/build_brush.sh"
"$ROOT/scripts/toolchain/build_msplat.sh"
"$ROOT/scripts/toolchain/build_da3_mps.sh"
"$ROOT/scripts/toolchain/build_mapanything_mps.sh"
"$ROOT/scripts/toolchain/build_vggt_mps.sh"
"$ROOT/scripts/toolchain/build_fastvggt_mps.sh"
"$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"

if [ ! -f "$PUB" ] || [ ! -f "$PRIV" ]; then
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool generate-keypair \
    --public-key-out "$PUB" \
    --private-key-out "$PRIV"
fi
chmod 600 "$PRIV"

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool \
  --version "$VERSION" \
  --published-at "$PUBLISHED_AT" \
  --core-zip "$CORE_ZIP" \
  --core-url "$CORE_ARTIFACT_URL" \
  --models-zip "$MODELS_ZIP" \
  --models-url "$MODELS_ARTIFACT_URL" \
  --private-key-file "$PRIV" \
  --manifest-out "$MANIFEST"

build_app_args=(
  --manifest-url "$MANIFEST_URL"
  --public-key-path "$PUB"
  --version "$VERSION"
)
if [ -n "$PROJECT_URL" ]; then
  build_app_args+=(--project-url "$PROJECT_URL")
fi

"$ROOT/scripts/release/build_app.sh" "${build_app_args[@]}"

APP_PATH="$ROOT/build/Export/EasySplat.app"
OUT_DIR="$ROOT/release/DMG"
DMG_PATH="$OUT_DIR/EasySplat-$VERSION.dmg"

mkdir -p "$OUT_DIR"

"$ROOT/scripts/release/create_dmg.sh" \
  --app-path "$APP_PATH" \
  --out "$DMG_PATH" \
  --volname "EasySplat"

echo "DMG ready: $DMG_PATH"
