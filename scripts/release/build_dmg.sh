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
RELEASE_MODE=""
USE_EXISTING_TOOLCHAIN=0

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
    --unsigned-beta)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      RELEASE_MODE="unsigned-beta"
      shift
      ;;
    --production)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      echo "Production packaging is not available until signing, notarization, Gatekeeper, and clean-Mac installation gates are complete." >&2
      exit 1
      ;;
    --use-existing-toolchain)
      USE_EXISTING_TOOLCHAIN=1
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$APP_VERSION" ] || [ -z "$TOOLCHAIN_VERSION" ] || [ -z "$RELEASE_MODE" ]; then
  echo "Usage: build_dmg.sh --app-version <semver> --toolchain-version <semver> --manifest-url <https-url> --core-artifact-url <https-url> --da3-base-artifact-url <https-url> --da3-small-artifact-url <https-url> --use-existing-toolchain --unsigned-beta [--project-url <https-url>]" >&2
  exit 1
fi
if [ "$USE_EXISTING_TOOLCHAIN" -ne 1 ]; then
  echo "Unsigned beta packaging requires --use-existing-toolchain. Toolchain Build creates unsigned archives and a signing request; the independent release authority signs and publishes the closure." >&2
  exit 1
fi
if [ -z "$MANIFEST_URL" ] || [ -z "$CORE_ARTIFACT_URL" ] || [ -z "$DA3_BASE_ARTIFACT_URL" ] || [ -z "$DA3_SMALL_ARTIFACT_URL" ]; then
  echo "Unsigned beta packaging requires explicit HTTPS manifest and component URLs." >&2
  exit 1
fi

python3 - \
  "$MANIFEST_URL" \
  "$CORE_ARTIFACT_URL" \
  "$DA3_BASE_ARTIFACT_URL" \
  "$DA3_SMALL_ARTIFACT_URL" <<'PY'
import sys
from urllib.parse import urlparse

labels = ("Manifest URL", "Core artifact URL", "DA3 Base artifact URL", "DA3 Small artifact URL")
for label, value in zip(labels, sys.argv[1:]):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit(f"{label} must use HTTPS and contain no credentials.")
PY

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
if ! [[ "$APP_VERSION" =~ $SEMVER_RE ]]; then
  echo "Invalid app semantic version: $APP_VERSION" >&2
  exit 1
fi
if ! [[ "$TOOLCHAIN_VERSION" =~ $SEMVER_RE ]]; then
  echo "Invalid toolchain semantic version: $TOOLCHAIN_VERSION" >&2
  exit 1
fi
if [[ "$APP_VERSION" != *-* ]]; then
  echo "Unsigned public beta versions must include a prerelease suffix." >&2
  exit 1
fi

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
TRACKED_APP_AUTHORITY="$ROOT/EasySplatApp/Resources/public_key_ed25519.txt"
for required in "$PUB" "$MANIFEST" "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"; do
  if [ ! -f "$required" ]; then
    echo "Missing existing signed toolchain artifact: $required" >&2
    exit 1
  fi
done
if [ ! -f "$TRACKED_APP_AUTHORITY" ]; then
  echo "Missing tracked app authority: $TRACKED_APP_AUTHORITY" >&2
  exit 1
fi

python3 - "$PUB" "$TRACKED_APP_AUTHORITY" <<'PY'
import base64
import binascii
import sys
from pathlib import Path


def read_ed25519_public_key(path_value: str, label: str) -> bytes:
    path = Path(path_value)
    try:
        encoded = path.read_text(encoding="ascii").strip()
        decoded = base64.b64decode(encoded, validate=True)
    except (OSError, UnicodeError, binascii.Error, ValueError) as error:
        raise SystemExit(f"{label} is not a valid base64 Ed25519 public key: {path}") from error
    if len(decoded) != 32:
        raise SystemExit(f"{label} must decode to exactly 32 bytes: {path}")
    return decoded


toolchain_authority = read_ed25519_public_key(
    sys.argv[1], "Signed toolchain authority"
)
tracked_app_authority = read_ed25519_public_key(
    sys.argv[2], "Tracked app authority"
)
if toolchain_authority != tracked_app_authority:
    raise SystemExit(
        "Signed toolchain authority does not match the tracked app authority."
    )
PY

swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool verify-release \
  --manifest "$MANIFEST" \
  --public-key-file "$PUB" \
  --toolchain-version "$TOOLCHAIN_VERSION" \
  --app-version "$APP_VERSION" \
  --core-zip "$CORE_ZIP" \
  --core-url "$CORE_ARTIFACT_URL" \
  --da3-base-zip "$DA3_BASE_ZIP" \
  --da3-base-url "$DA3_BASE_ARTIFACT_URL" \
  --da3-small-zip "$DA3_SMALL_ZIP" \
  --da3-small-url "$DA3_SMALL_ARTIFACT_URL"

python3 "$ROOT/scripts/release/generate_release_metadata.py" verify-toolchain \
  --toolchain-version "$TOOLCHAIN_VERSION" \
  --manifest "$MANIFEST" \
  --core "$CORE_ZIP" \
  --core-url "$CORE_ARTIFACT_URL" \
  --da3-base "$DA3_BASE_ZIP" \
  --da3-base-url "$DA3_BASE_ARTIFACT_URL" \
  --da3-small "$DA3_SMALL_ZIP" \
  --da3-small-url "$DA3_SMALL_ARTIFACT_URL"

build_app_args=(
  --manifest-url "$MANIFEST_URL"
  --public-key-path "$PUB"
  --version "$APP_VERSION"
  --unsigned-beta
)
if [ -n "$PROJECT_URL" ]; then
  build_app_args+=(--project-url "$PROJECT_URL")
fi

"$ROOT/scripts/release/build_app.sh" "${build_app_args[@]}"

APP_PATH="$ROOT/build/Export/EasySplat.app"
OUT_DIR="$ROOT/release/DMG"
DMG_PATH="$OUT_DIR/EasySplat-$APP_VERSION-unsigned.dmg"

mkdir -p "$OUT_DIR"

"$ROOT/scripts/release/create_dmg.sh" \
  --app-path "$APP_PATH" \
  --out "$DMG_PATH" \
  --volname "EasySplat"

ARTIFACT_STEM="$OUT_DIR/EasySplat-$APP_VERSION"
CHECKSUM_PATH="$DMG_PATH.sha256"
PROVENANCE_PATH="$ARTIFACT_STEM.provenance.json"
SBOM_PATH="$ARTIFACT_STEM.spdx.json"
LICENSES_PATH="$ARTIFACT_STEM-licenses.zip"
RELEASE_NOTES_PATH="$ARTIFACT_STEM-release-notes.txt"
DSYM_PATH="$ROOT/build/Export/EasySplat.app.dSYM"
DSYM_ZIP="$ARTIFACT_STEM-dSYM.zip"

(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" >"$(basename "$CHECKSUM_PATH")")
rm -f "$DSYM_ZIP"
(cd "$(dirname "$DSYM_PATH")" && zip -qry "$DSYM_ZIP" "$(basename "$DSYM_PATH")")

printf '%s\n' \
  "EasySplat $APP_VERSION is an unsigned public beta." \
  "macOS will require the user to confirm opening an app from an unidentified developer." \
  >"$RELEASE_NOTES_PATH"

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_URL="${PROJECT_URL:-https://github.com/${GITHUB_REPOSITORY:-dud8/EasySplat}}"
python3 "$ROOT/scripts/release/generate_release_metadata.py" generate \
  --app-version "$APP_VERSION" \
  --toolchain-version "$TOOLCHAIN_VERSION" \
  --release-mode unsigned-beta \
  --source-commit "$SOURCE_COMMIT" \
  --source-url "$SOURCE_URL" \
  --dmg "$DMG_PATH" \
  --manifest "$MANIFEST" \
  --manifest-url "$MANIFEST_URL" \
  --core "$CORE_ZIP" \
  --core-url "$CORE_ARTIFACT_URL" \
  --da3-base "$DA3_BASE_ZIP" \
  --da3-base-url "$DA3_BASE_ARTIFACT_URL" \
  --da3-small "$DA3_SMALL_ZIP" \
  --da3-small-url "$DA3_SMALL_ARTIFACT_URL" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$PROVENANCE_PATH" \
  --spdx-out "$SBOM_PATH" \
  --licenses-out "$LICENSES_PATH"

echo "DMG ready: $DMG_PATH"
