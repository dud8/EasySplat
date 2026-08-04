#!/bin/bash -p
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/strict_semver.sh
source "$ROOT/scripts/release/lib/strict_semver.sh"
APP_VERSION=""
TOOLCHAIN_DIR="$ROOT/Toolchains/out"
TOOLCHAIN_VERSION=""
PROJECT_URL=""
RELEASE_MODE=""
IDENTITY_FINGERPRINT=""
TEAM_ID=""
NOTARY_KEYCHAIN_PROFILE=""
IDENTITY_FINGERPRINT_SET=0
TEAM_ID_SET=0
NOTARY_KEYCHAIN_PROFILE_SET=0
BUILD_ROOT="$ROOT/build"
PACKAGE_BUILD_ROOT=""
PACKAGE_STAGE=""
OUT_DIR="$ROOT/release/DMG"
PREPARED_RELEASE_ROOT=""
PREPARED_MANIFEST_SHA256=""
SOURCE_COMMIT_OVERRIDE=""
PUBLICATION_ACTIVE=0
FINAL_DMG_SHA256=""
FINAL_DMG_NAME=""

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$PACKAGE_STAGE" ]; then
    if [ "$PUBLICATION_ACTIVE" -eq 1 ] \
        && [ -d "$OUT_DIR/.easysplat-release-publication.lock" ]; then
      echo "Publication recovery state was preserved at: $PACKAGE_STAGE" >&2
    else
      rm -rf "$PACKAGE_STAGE"
    fi
  fi
  if [ -n "$PACKAGE_BUILD_ROOT" ]; then
    rm -rf "$PACKAGE_BUILD_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT

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
    --toolchain-dir)
      TOOLCHAIN_DIR="$2"
      shift 2
      ;;
    --project-url)
      PROJECT_URL="$2"
      shift 2
      ;;
    --development-unsigned)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      RELEASE_MODE="development-unsigned"
      shift
      ;;
    --production)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      RELEASE_MODE="production"
      shift
      ;;
    --identity-fingerprint)
      if [ "$IDENTITY_FINGERPRINT_SET" -eq 1 ]; then
        echo "--identity-fingerprint may be supplied only once." >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--identity-fingerprint requires a 40-hex value." >&2
        exit 1
      fi
      IDENTITY_FINGERPRINT="$2"
      IDENTITY_FINGERPRINT_SET=1
      shift 2
      ;;
    --team-id)
      if [ "$TEAM_ID_SET" -eq 1 ]; then
        echo "--team-id may be supplied only once." >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--team-id requires a 10-character value." >&2
        exit 1
      fi
      TEAM_ID="$2"
      TEAM_ID_SET=1
      shift 2
      ;;
    --notary-keychain-profile)
      if [ "$NOTARY_KEYCHAIN_PROFILE_SET" -eq 1 ]; then
        echo "--notary-keychain-profile may be supplied only once." >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--notary-keychain-profile requires a profile name." >&2
        exit 1
      fi
      NOTARY_KEYCHAIN_PROFILE="$2"
      NOTARY_KEYCHAIN_PROFILE_SET=1
      shift 2
      ;;
    --build-root)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--build-root requires an absolute path." >&2
        exit 1
      fi
      BUILD_ROOT="$2"
      shift 2
      ;;
    --output-dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--output-dir requires an absolute path." >&2
        exit 1
      fi
      OUT_DIR="$2"
      shift 2
      ;;
    --prepared-release-root)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--prepared-release-root requires an absolute path." >&2
        exit 1
      fi
      PREPARED_RELEASE_ROOT="$2"
      shift 2
      ;;
    --prepared-manifest-sha256)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--prepared-manifest-sha256 requires a lowercase SHA-256 digest." >&2
        exit 1
      fi
      PREPARED_MANIFEST_SHA256="$2"
      shift 2
      ;;
    --source-commit)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--source-commit requires a lowercase 40-hex object ID." >&2
        exit 1
      fi
      SOURCE_COMMIT_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

unset GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN GITHUB_TOKEN

if [ -z "$APP_VERSION" ] || [ -z "$TOOLCHAIN_VERSION" ] || [ -z "$TOOLCHAIN_DIR" ] || [ -z "$RELEASE_MODE" ]; then
  echo "Usage: build_dmg.sh --app-version <semver> --toolchain-version <semver> --toolchain-dir <absolute-path> (--development-unsigned | --production --identity-fingerprint <sha1> --team-id <id> --notary-keychain-profile <name> --prepared-release-root <absolute-path> --prepared-manifest-sha256 <sha256> --source-commit <sha1>) [--project-url <https-url>] [--build-root <absolute-path>] [--output-dir <absolute-path>]" >&2
  exit 1
fi
if [ "$RELEASE_MODE" = production ]; then
  if ! [[ "$IDENTITY_FINGERPRINT" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "Production packaging requires an exact 40-hex Developer ID fingerprint." >&2
    exit 1
  fi
  if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Production packaging requires an exact 10-character Team ID." >&2
    exit 1
  fi
  if ! [[ "$NOTARY_KEYCHAIN_PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "Production packaging requires a safe 1-64 character notary keychain profile name." >&2
    exit 1
  fi
  if [ -n "${EASYSPLAT_XCODEBUILD_BIN:-}" ] \
      || [ -n "${EASYSPLAT_CODESIGN_BIN:-}" ] \
      || [ -n "${EASYSPLAT_SKIP_METAL_TOOLCHAIN_CHECK:-}" ] \
      || [ -n "${EASYSPLAT_HDIUTIL_BIN:-}" ] \
      || [ -n "${EASYSPLAT_NOTARY_TEST_MODE:-}" ]; then
    echo "Production build command overrides are not permitted." >&2
    exit 1
  fi
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  export PATH
  unset DEVELOPER_DIR SDKROOT TOOLCHAINS
  unset CC CXX LD AR AS NM STRIP LIBTOOL SWIFT_EXEC
  unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS
  while IFS='=' read -r inherited_name _; do
    case "$inherited_name" in
      DYLD_*|LD_*) unset "$inherited_name" ;;
    esac
  done < <(/usr/bin/env)
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  MACOSX_DEPLOYMENT_TARGET=15.0
  export DEVELOPER_DIR MACOSX_DEPLOYMENT_TARGET
elif [ -n "$IDENTITY_FINGERPRINT" ] || [ -n "$TEAM_ID" ] \
  || [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
  echo "Signing and notarization arguments require --production." >&2
  exit 1
fi
if [ "$RELEASE_MODE" = production ]; then
  if [ -z "$PREPARED_RELEASE_ROOT" ] \
      || ! [[ "$PREPARED_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
      || ! [[ "$SOURCE_COMMIT_OVERRIDE" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Production packaging requires a prepared release root, its lowercase SHA-256 manifest digest, and a lowercase 40-hex source commit." >&2
    exit 1
  fi
elif [ -n "$PREPARED_RELEASE_ROOT" ] \
    || [ -n "$PREPARED_MANIFEST_SHA256" ] \
    || [ -n "$SOURCE_COMMIT_OVERRIDE" ]; then
  echo "Prepared release inputs require production mode." >&2
  exit 1
fi

if ! easysplat_is_strict_semver_without_build_metadata "$APP_VERSION"; then
  echo "App version must be strict semantic versioning without build metadata: $APP_VERSION" >&2
  exit 1
fi
if ! easysplat_is_strict_semver_without_build_metadata "$TOOLCHAIN_VERSION"; then
  echo "Toolchain version must be strict semantic versioning without build metadata: $TOOLCHAIN_VERSION" >&2
  exit 1
fi
if [ "$RELEASE_MODE" = production ]; then
  if ! easysplat_is_strict_semver_stable "$APP_VERSION"; then
    echo "Production releases require a stable app version without build metadata: $APP_VERSION" >&2
    exit 1
  fi
  if ! easysplat_is_strict_semver_stable "$TOOLCHAIN_VERSION"; then
    echo "Production releases require a stable toolchain version without build metadata: $TOOLCHAIN_VERSION" >&2
    exit 1
  fi
fi

if command -v xcodebuild >/dev/null 2>&1; then
  if ! xcodebuild -license check >/dev/null 2>&1; then
    echo "Xcode license not accepted. Run: sudo xcodebuild -license accept" >&2
    exit 1
  fi
fi

if [ -n "$PREPARED_RELEASE_ROOT" ] && [ "$TOOLCHAIN_DIR" = "$ROOT/Toolchains/out" ]; then
  TOOLCHAIN_DIR="$PREPARED_RELEASE_ROOT/toolchain/out"
fi

BUILD_ROOT="$(/usr/bin/python3 -I - "$BUILD_ROOT" "$ROOT" <<'PY'

import os
import stat
import sys

candidate, repository = sys.argv[1:]
if not os.path.isabs(candidate) or os.path.normpath(candidate) != candidate:
    raise SystemExit("Build root must be an absolute normalized path.")
resolved = os.path.realpath(candidate)
repository = os.path.realpath(repository)
protected_roots = {
    os.path.sep,
    "/Applications",
    "/Library",
    "/System",
    "/Users",
    "/Volumes",
    "/private",
    "/private/tmp",
    "/private/var",
    "/usr",
    "/opt",
}
if resolved != candidate:
    raise SystemExit("Build root must contain no symlink ancestry.")
if resolved in protected_roots or os.path.commonpath((resolved, repository)) == resolved:
    raise SystemExit(f"Refusing unsafe build root: {candidate}")
os.makedirs(resolved, mode=0o700, exist_ok=True)
metadata = os.lstat(resolved)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    raise SystemExit("Build root must be an owned, non-writable directory.")
print(resolved)
PY
)" || exit 1

OUT_DIR="$(/usr/bin/python3 -I - "$OUT_DIR" <<'PY'
import os
import stat
import sys

candidate = sys.argv[1]
if not os.path.isabs(candidate) or os.path.normpath(candidate) != candidate:
    raise SystemExit("Output directory must be an absolute normalized path.")
resolved = os.path.realpath(candidate)
if resolved != candidate:
    raise SystemExit("Output directory must contain no symlink ancestry.")
if resolved in {
    os.path.sep,
    "/Applications",
    "/Library",
    "/System",
    "/Users",
    "/Volumes",
    "/private",
    "/private/tmp",
    "/private/var",
    "/usr",
    "/opt",
}:
    raise SystemExit(f"Refusing unsafe output directory: {candidate}")
os.makedirs(resolved, mode=0o700, exist_ok=True)
metadata = os.lstat(resolved)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    raise SystemExit("Output directory must be owned and not group/world writable.")
print(resolved)
PY
)" || exit 1

/usr/bin/python3 -I "$ROOT/scripts/release/publish_release_files.py" \
  --recover-only \
  --output-dir "$OUT_DIR"
PACKAGE_BUILD_ROOT="$(mktemp -d "$BUILD_ROOT/.EasySplat-$APP_VERSION.package.XXXXXX")"
chmod 0700 "$PACKAGE_BUILD_ROOT"

if [ -n "$PREPARED_RELEASE_ROOT" ]; then
  PREPARED_RELEASE_ROOT="$(/usr/bin/python3 -I - "$PREPARED_RELEASE_ROOT" <<'PY'
import os
import stat
import sys

candidate = sys.argv[1]
if not os.path.isabs(candidate) or os.path.normpath(candidate) != candidate:
    raise SystemExit("Prepared release root must be an absolute normalized path.")
resolved = os.path.realpath(candidate)
if resolved != candidate:
    raise SystemExit("Prepared release root must contain no symlink ancestry.")
metadata = os.lstat(resolved)
if (
    not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
    or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    raise SystemExit("Prepared release root must be owned and not group/world writable.")
print(resolved)
PY
)" || exit 1
  PREPARED_APP="$PREPARED_RELEASE_ROOT/product/EasySplat.app"
  PREPARED_DSYM="$PREPARED_RELEASE_ROOT/product/EasySplat.app.dSYM"
  for required in \
    "$PREPARED_APP" \
    "$PREPARED_DSYM" \
    "$PREPARED_RELEASE_ROOT/prepared-release.json"; do
    if [ ! -e "$required" ] || [ -L "$required" ]; then
      echo "Prepared release product is missing or linked: $required" >&2
      exit 1
    fi
  done
fi

if [ -n "$PREPARED_RELEASE_ROOT" ]; then
  /usr/bin/python3 -I "$ROOT/scripts/release/prepared_release.py" verify \
    --root "$PREPARED_RELEASE_ROOT" \
    --authority-from-manifest \
    --expected-manifest-sha256 "$PREPARED_MANIFEST_SHA256" \
    --source-commit "$SOURCE_COMMIT_OVERRIDE" \
    --app-version "$APP_VERSION" \
    --toolchain-version "$TOOLCHAIN_VERSION"
  PREPARED_INFO_PLIST="$PREPARED_APP/Contents/Info.plist"
  PREPARED_CHANNEL_FILE="$PREPARED_APP/Contents/Resources/release_channel.txt"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$PREPARED_INFO_PLIST")" != "prepare-release" ] \
      || [ "$(cat "$PREPARED_CHANNEL_FILE")" != "prepared release candidate" ]; then
    echo "Prepared app must remain labeled prepare-release until the signing authority promotes it." >&2
    exit 1
  fi
  mkdir -p "$PACKAGE_BUILD_ROOT/Export"
  /usr/bin/ditto --noqtn \
    "$PREPARED_APP" \
    "$PACKAGE_BUILD_ROOT/Export/EasySplat.app"
  /usr/bin/ditto --noqtn \
    "$PREPARED_DSYM" \
    "$PACKAGE_BUILD_ROOT/Export/EasySplat.app.dSYM"
  /bin/chmod -R u+w \
    "$PACKAGE_BUILD_ROOT/Export/EasySplat.app" \
    "$PACKAGE_BUILD_ROOT/Export/EasySplat.app.dSYM"
  /usr/bin/plutil -replace EasySplatReleaseChannel -string production \
    "$PACKAGE_BUILD_ROOT/Export/EasySplat.app/Contents/Info.plist"
  printf '%s' 'production release' \
    >"$PACKAGE_BUILD_ROOT/Export/EasySplat.app/Contents/Resources/release_channel.txt"
  /usr/bin/plutil -lint \
    "$PACKAGE_BUILD_ROOT/Export/EasySplat.app/Contents/Info.plist" >/dev/null
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --root "$PACKAGE_BUILD_ROOT/Export/EasySplat.app" \
    --kind app \
    --identity-fingerprint "$IDENTITY_FINGERPRINT" \
    --team-id "$TEAM_ID" \
    --receipt "$PACKAGE_BUILD_ROOT/Export/EasySplat.app-signing.json"
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --bind-receipt-to-current-artifact \
    --root "$PACKAGE_BUILD_ROOT/Export/EasySplat.app" \
    --kind app \
    --identity-fingerprint "$IDENTITY_FINGERPRINT" \
    --team-id "$TEAM_ID" \
    --receipt "$PACKAGE_BUILD_ROOT/Export/EasySplat.app-signing.json"
else
for required in bin/colmap bin/easysplat-train bin/default.metallib lib/libomp.dylib; do
  if [ ! -f "$TOOLCHAIN_DIR/$required" ]; then
    echo "Missing toolchain artifact: $TOOLCHAIN_DIR/$required" >&2
    exit 1
  fi
done

  build_app_args=(
    --version "$APP_VERSION"
    --toolchain-dir "$TOOLCHAIN_DIR"
    --build-root "$PACKAGE_BUILD_ROOT"
  )
  if [ -n "$PROJECT_URL" ]; then
    build_app_args+=(--project-url "$PROJECT_URL")
  fi
  build_app_args+=(--development-unsigned)
  "$ROOT/scripts/release/build_app.sh" "${build_app_args[@]}"
fi

APP_PATH="$PACKAGE_BUILD_ROOT/Export/EasySplat.app"
APP_SIGNING_RECEIPT="$PACKAGE_BUILD_ROOT/Export/EasySplat.app-signing.json"

if [ "$RELEASE_MODE" = production ]; then
  PACKAGE_STAGE="$(mktemp -d "$OUT_DIR/.EasySplat-$APP_VERSION.release.XXXXXX")"
  chmod 0700 "$PACKAGE_STAGE"
  ARTIFACT_STEM="$PACKAGE_STAGE/EasySplat-$APP_VERSION"
  DMG_PATH="$ARTIFACT_STEM.dmg"
  APP_NOTARY_RECEIPT="$ARTIFACT_STEM.app-notarization.json"
  DMG_SIGNING_RECEIPT="$ARTIFACT_STEM.dmg-signing.json"
  DMG_NOTARY_RECEIPT="$ARTIFACT_STEM.dmg-notarization.json"
  NOTARY_DIAGNOSTICS="$PACKAGE_BUILD_ROOT/NotarizationDiagnostics"

  EASYSPLAT_NOTARY_TEST_MODE=0 "$ROOT/scripts/release/notarize_artifact.sh" \
    --type app \
    --artifact "$APP_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --receipt "$APP_NOTARY_RECEIPT" \
    --diagnostics-dir "$NOTARY_DIAGNOSTICS"
  /usr/bin/python3 -I "$ROOT/scripts/release/verify_notarization_receipt.py" \
    --type app \
    --artifact "$APP_PATH" \
    --signing-receipt "$APP_SIGNING_RECEIPT" \
    --receipt "$APP_NOTARY_RECEIPT" >/dev/null
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --root "$APP_PATH" \
    --kind app \
    --identity-fingerprint "$IDENTITY_FINGERPRINT" \
    --team-id "$TEAM_ID" \
    --receipt "$APP_SIGNING_RECEIPT"
  if [ ! -f "$APP_SIGNING_RECEIPT" ] || [ -L "$APP_SIGNING_RECEIPT" ]; then
    echo "The signed app receipt is missing after notarization." >&2
    exit 1
  fi
  cp "$APP_SIGNING_RECEIPT" "$ARTIFACT_STEM.app-signing.json"
else
  ARTIFACT_STEM="$OUT_DIR/EasySplat-$APP_VERSION"
  DMG_PATH="$OUT_DIR/EasySplat-$APP_VERSION-unsigned.dmg"
fi

create_dmg_args=(
  --app-path "$APP_PATH"
  --out "$DMG_PATH"
  --volname "EasySplat"
)
if [ "$RELEASE_MODE" = production ]; then
  create_dmg_args+=(
    --app-notarization-receipt "$APP_NOTARY_RECEIPT"
  )
fi
EASYSPLAT_HDIUTIL_BIN=/usr/bin/hdiutil "$ROOT/scripts/release/create_dmg.sh" \
  "${create_dmg_args[@]}"

if [ "$RELEASE_MODE" = production ]; then
  signing_args=(
    --root "$DMG_PATH"
    --kind dmg
    --identity-fingerprint "$IDENTITY_FINGERPRINT"
    --team-id "$TEAM_ID"
    --receipt "$DMG_SIGNING_RECEIPT"
  )
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    "${signing_args[@]}"
  /usr/bin/python3 -I - "$DMG_SIGNING_RECEIPT" "$IDENTITY_FINGERPRINT" "$TEAM_ID" \
    "$DMG_PATH" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

receipt = Path(sys.argv[1])
fingerprint = sys.argv[2].upper()
team_id = sys.argv[3]
artifact = Path(sys.argv[4])
try:
    metadata = receipt.lstat()
    payload = json.loads(receipt.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit("Signed disk image receipt is missing or invalid.") from error
if not receipt.is_file() or receipt.is_symlink() or metadata.st_nlink != 1:
    raise SystemExit("Signed disk image receipt must be an ordinary regular file.")
if payload.get("schemaVersion") != 1 or payload.get("rootKind") != "dmg":
    raise SystemExit("Signed disk image receipt has the wrong artifact contract.")
if payload.get("identityFingerprintSHA1") != fingerprint or payload.get("teamID") != team_id:
    raise SystemExit("Signed disk image receipt does not match the requested identity.")
entries = payload.get("entries")
artifact_digest = payload.get("artifactDigest")
if not isinstance(entries, list) or len(entries) != 1:
    raise SystemExit("Signed disk image receipt has an invalid entry set.")
entry = entries[0]
if not (
    isinstance(entry, dict)
    and entry.get("kind") == "diskImage"
    and entry.get("identityFingerprintSHA1") == fingerprint
    and entry.get("teamID") == team_id
    and isinstance(entry.get("postSignSHA256"), str)
    and re.fullmatch(r"[0-9a-f]{64}", entry["postSignSHA256"])
    and isinstance(entry.get("codesign"), dict)
    and entry["codesign"].get("teamIdentifier") == team_id
    and isinstance(entry["codesign"].get("timestamp"), str)
    and bool(entry["codesign"]["timestamp"])
):
    raise SystemExit("Signed disk image receipt does not prove the final signature.")
if not (
    isinstance(artifact_digest, dict)
    and artifact_digest.get("format") == "sha256-file-v1"
    and artifact_digest.get("postSignSHA256") == entry["postSignSHA256"]
):
    raise SystemExit("Signed disk image receipt has no shared post-sign digest.")
hasher = hashlib.sha256()
with artifact.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        hasher.update(chunk)
digest = hasher.hexdigest()
if entry["postSignSHA256"] != digest:
    raise SystemExit("Signed disk image receipt does not bind the staged artifact bytes.")
PY
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --bind-receipt-to-current-artifact \
    --root "$DMG_PATH" \
    --kind dmg \
    --identity-fingerprint "$IDENTITY_FINGERPRINT" \
    --team-id "$TEAM_ID" \
    --receipt "$DMG_SIGNING_RECEIPT"
  EASYSPLAT_NOTARY_TEST_MODE=0 "$ROOT/scripts/release/notarize_artifact.sh" \
    --type dmg \
    --artifact "$DMG_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --receipt "$DMG_NOTARY_RECEIPT" \
    --diagnostics-dir "$NOTARY_DIAGNOSTICS"
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --root "$DMG_PATH" \
    --kind dmg \
    --identity-fingerprint "$IDENTITY_FINGERPRINT" \
    --team-id "$TEAM_ID" \
    --receipt "$DMG_SIGNING_RECEIPT"
  FINAL_DMG_SHA256="$(
    /usr/bin/python3 -I "$ROOT/scripts/release/verify_notarization_receipt.py" \
      --type dmg \
      --artifact "$DMG_PATH" \
      --signing-receipt "$DMG_SIGNING_RECEIPT" \
      --receipt "$DMG_NOTARY_RECEIPT"
  )"
  /usr/bin/hdiutil verify "$DMG_PATH"
fi

CHECKSUM_PATH="$DMG_PATH.sha256"
PROVENANCE_PATH="$ARTIFACT_STEM.provenance.json"
SBOM_PATH="$ARTIFACT_STEM.spdx.json"
LICENSES_PATH="$ARTIFACT_STEM-licenses.zip"
RELEASE_NOTES_PATH="$ARTIFACT_STEM-release-notes.txt"
DSYM_PATH="$PACKAGE_BUILD_ROOT/Export/EasySplat.app.dSYM"
DSYM_ZIP="$ARTIFACT_STEM-dSYM.zip"

/usr/bin/python3 -I - "$DMG_PATH" "$CHECKSUM_PATH" <<'PY'
import hashlib
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
digest = hashlib.sha256()
with source.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
destination.write_text(
    f"{digest.hexdigest()}  {source.name}\n",
    encoding="ascii",
)
PY
rm -f "$DSYM_ZIP"
(cd "$(/usr/bin/dirname "$DSYM_PATH")" \
  && ZIPOPT='' /usr/bin/zip -qryX "$DSYM_ZIP" "$(/usr/bin/basename "$DSYM_PATH")")

if [ "$RELEASE_MODE" = production ]; then
  /bin/cat >"$RELEASE_NOTES_PATH" <<EOF
EasySplat $APP_VERSION is a Developer ID-signed and notarized release.
Install the Developer ID-signed, notarized, and stapled DMG on an Apple Silicon Mac running macOS 15 or later.

EasySplat turns video, photo folders, or mixed inputs into static 3D Gaussian splats locally. Input media stays on your Mac. Capture-aware native COLMAP reconstruction uses FAISS matching, and the native Metal trainer writes a validated PLY. When the geometry is conclusive, EasySplat aligns the scene upright. The viewer supports orbit, pan, zoom, fit, reset, export, and system Share. Work can stop and resume at durable stages. EasySplat has no cloud processing, telemetry, or analytics.

One reconstruction runs at a time. PLY is the only export format. Moving subjects, reflections, water, foliage, and large lighting changes can leave artifacts.

Release files include the DMG SHA-256 checksum, provenance record, SPDX SBOM, third-party license bundle, and dSYM archive.
EOF
else
  printf '%s\n' \
    "EasySplat $APP_VERSION is an unsigned developer build, not a release artifact." \
    "macOS will require the user to confirm opening an app from an unidentified developer." \
    >"$RELEASE_NOTES_PATH"
fi

if [ -n "$PREPARED_RELEASE_ROOT" ]; then
  SOURCE_COMMIT="$SOURCE_COMMIT_OVERRIDE"
else
  SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
fi
SOURCE_URL="${PROJECT_URL:-https://github.com/${GITHUB_REPOSITORY:-dud8/EasySplat}}"
/usr/bin/python3 -I "$ROOT/scripts/release/generate_release_metadata.py" generate \
  --app-version "$APP_VERSION" \
  --toolchain-version "$TOOLCHAIN_VERSION" \
  --release-mode "$RELEASE_MODE" \
  --source-commit "$SOURCE_COMMIT" \
  --source-url "$SOURCE_URL" \
  --dmg "$DMG_PATH" \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$PROVENANCE_PATH" \
  --spdx-out "$SBOM_PATH" \
  --licenses-out "$LICENSES_PATH"

if [ "$RELEASE_MODE" = production ]; then
  publication_files=(
    "$DMG_PATH"
    "$CHECKSUM_PATH"
    "$PROVENANCE_PATH"
    "$SBOM_PATH"
    "$LICENSES_PATH"
    "$RELEASE_NOTES_PATH"
    "$DSYM_ZIP"
    "$ARTIFACT_STEM.app-signing.json"
    "$APP_NOTARY_RECEIPT"
    "$DMG_SIGNING_RECEIPT"
    "$DMG_NOTARY_RECEIPT"
  )
  publication_args=(
    --stage-dir "$PACKAGE_STAGE"
    --output-dir "$OUT_DIR"
  )
  FINAL_DMG_NAME="$(basename "$DMG_PATH")"
  publication_args+=(
    --expected-sha256 "$FINAL_DMG_NAME=$FINAL_DMG_SHA256"
  )
  for source in "${publication_files[@]}"; do
    publication_args+=(--file "$(basename "$source")")
  done
  PUBLICATION_ACTIVE=1
  /usr/bin/python3 -I "$ROOT/scripts/release/publish_release_files.py" \
    "${publication_args[@]}"
  PUBLICATION_ACTIVE=0
  rmdir "$PACKAGE_STAGE"
  PACKAGE_STAGE=""
  DMG_PATH="$OUT_DIR/EasySplat-$APP_VERSION.dmg"
fi

echo "DMG ready: $DMG_PATH"
