#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH=""
DMG_PATH=""
EXPECTED_VERSION=""
SKIP_LAUNCH_SMOKE=0
VERIFY_ARTIFACTS=0
E2E_FIXTURE=""
TOOLCHAIN_ROOT=""
E2E_RUNNER=""
OFFLINE_CACHE_ROOT=""
OFFLINE_RUNNER=""
MANIFEST_URL=""
PUBLIC_KEY_FILE=""
RELEASE_MANIFEST=""
CORE_ARCHIVE=""
DA3_BASE_ARCHIVE=""
DA3_SMALL_ARCHIVE=""
SOURCE_URL=""
SOURCE_COMMIT=""
ALLOW_INCOMPLETE=0
HDIUTIL_BIN="${EASYSPLAT_HDIUTIL_BIN:-hdiutil}"
MOUNT_DIR=""
MOUNT_ATTACHED=0
E2E_DIR=""
SMOKE_LOG=""

usage() {
  echo "Usage: verify_beta.sh --app <app> --dmg <dmg> --expected-version <semver> --artifacts --source-url <https-url> --source-commit <sha> --fixture <media> --manifest-url <https-url> --public-key-file <file> --toolchain-root <dir> --e2e-runner <executable> --offline-cache-root <dir> --offline-runner <executable>"
}

cleanup() {
  if [ "$MOUNT_ATTACHED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    "$HDIUTIL_BIN" detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  [ -z "$MOUNT_DIR" ] || rm -rf "$MOUNT_DIR"
  [ -z "$E2E_DIR" ] || rm -rf "$E2E_DIR"
  [ -z "$SMOKE_LOG" ] || rm -f "$SMOKE_LOG"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2 ;;
    --dmg) DMG_PATH="$2"; shift 2 ;;
    --expected-version) EXPECTED_VERSION="$2"; shift 2 ;;
    --artifacts) VERIFY_ARTIFACTS=1; shift ;;
    --skip-launch-smoke) SKIP_LAUNCH_SMOKE=1; shift ;;
    --fixture) E2E_FIXTURE="$2"; shift 2 ;;
    --toolchain-root) TOOLCHAIN_ROOT="$2"; shift 2 ;;
    --e2e-runner) E2E_RUNNER="$2"; shift 2 ;;
    --offline-cache-root) OFFLINE_CACHE_ROOT="$2"; shift 2 ;;
    --offline-runner) OFFLINE_RUNNER="$2"; shift 2 ;;
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --public-key-file) PUBLIC_KEY_FILE="$2"; shift 2 ;;
    --release-manifest) RELEASE_MANIFEST="$2"; shift 2 ;;
    --core-archive) CORE_ARCHIVE="$2"; shift 2 ;;
    --da3-base-archive) DA3_BASE_ARCHIVE="$2"; shift 2 ;;
    --da3-small-archive) DA3_SMALL_ARCHIVE="$2"; shift 2 ;;
    --source-url) SOURCE_URL="$2"; shift 2 ;;
    --source-commit) SOURCE_COMMIT="$2"; shift 2 ;;
    --allow-incomplete) ALLOW_INCOMPLETE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$APP_PATH" ] || [ -z "$DMG_PATH" ] || [ -z "$EXPECTED_VERSION" ]; then
  usage >&2
  exit 1
fi
if [ ! -d "$APP_PATH" ] || [ ! -f "$DMG_PATH" ]; then
  echo "Missing app bundle or DMG." >&2
  exit 1
fi
if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
  [ "$VERIFY_ARTIFACTS" -eq 1 ] || { echo "Release verification requires --artifacts." >&2; exit 1; }
  [ "$SKIP_LAUNCH_SMOKE" -eq 0 ] || { echo "Release verification cannot skip launch smoke." >&2; exit 1; }
fi
if [ "$VERIFY_ARTIFACTS" -eq 1 ] && { [ -z "$SOURCE_URL" ] || [ -z "$SOURCE_COMMIT" ]; }; then
  echo "Artifact verification requires --source-url and --source-commit." >&2
  exit 1
fi

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+(\+[0-9A-Za-z.-]+)?$'
if ! [[ "$EXPECTED_VERSION" =~ $SEMVER_RE ]]; then
  echo "Public beta version must be a semantic prerelease: $EXPECTED_VERSION" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/EasySplatApp"
NUMERIC_VERSION="${EXPECTED_VERSION%%+*}"
NUMERIC_VERSION="${NUMERIC_VERSION%%-*}"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"; }
verify_adhoc_bundle() {
  local bundle=$1
  local signature
  /usr/bin/codesign --verify --deep --strict "$bundle"
  signature="$(/usr/bin/codesign --display --verbose=4 "$bundle" 2>&1)"
  grep -Fq 'Signature=adhoc' <<<"$signature"
  grep -Fq 'TeamIdentifier=not set' <<<"$signature"
  if grep -Eq '^Authority=' <<<"$signature"; then
    echo "Unsigned beta unexpectedly carries a signing authority: $bundle" >&2
    return 1
  fi
}

verify_arm64_executable() {
  local label=$1
  local executable=$2
  local architectures
  if ! architectures="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)"; then
    echo "$label executable is not a valid Mach-O file: $executable" >&2
    return 1
  fi
  if [ "$architectures" != "arm64" ]; then
    echo "$label executable must contain exactly arm64 (found: $architectures)." >&2
    return 1
  fi
}

macho_uuid_record() {
  local label=$1
  local path=$2
  local output
  local record_count
  if ! output="$(/usr/bin/xcrun dwarfdump --uuid "$path" 2>/dev/null)"; then
    echo "$label UUID could not be read: $path" >&2
    return 1
  fi
  record_count="$(awk '/^UUID: / { count += 1 } END { print count + 0 }' <<<"$output")"
  if [ "$record_count" -ne 1 ]; then
    echo "$label must contain exactly one Mach-O UUID (found: $record_count)." >&2
    return 1
  fi
  awk '/^UUID: / { print $2 " " $3 }' <<<"$output"
}

verify_dsym_matches_executable() {
  local executable=$1
  local dsym=$2
  local executable_record
  local dsym_record
  executable_record="$(macho_uuid_record "Release app executable" "$executable")" || return 1
  dsym_record="$(macho_uuid_record "Exported dSYM" "$dsym")" || return 1
  if [ "$executable_record" != "$dsym_record" ]; then
    echo "Exported dSYM UUID does not match app executable." >&2
    return 1
  fi
}

bundled_app_resource() {
  local app=$1
  local name=$2
  local module_bundle="$app/Contents/Resources/EasySplat_EasySplatApp.bundle"
  local resource_root="$module_bundle"
  if [ ! -d "$module_bundle" ] || [ -L "$module_bundle" ]; then
    echo "Bundled SwiftPM resource bundle is missing: $module_bundle" >&2
    return 1
  fi
  if [ -d "$module_bundle/Contents/Resources" ]; then
    resource_root="$module_bundle/Contents/Resources"
  fi
  if [ -L "$resource_root" ]; then
    echo "Bundled SwiftPM resource directory is not an ordinary directory: $resource_root" >&2
    return 1
  fi
  printf '%s/%s' "$resource_root" "$name"
}

validate_bundled_toolchain_contract() {
  local app=$1
  local manifest_path
  local public_key_path
  local bundled_manifest_url

  manifest_path="$(bundled_app_resource "$app" toolchain_manifest_url.txt)"
  public_key_path="$(bundled_app_resource "$app" public_key_ed25519.txt)"
  if [ ! -f "$manifest_path" ] || [ -L "$manifest_path" ] || [ ! -s "$manifest_path" ]; then
    echo "Bundled toolchain manifest URL is missing: $manifest_path" >&2
    return 1
  fi
  if [ ! -f "$public_key_path" ] || [ -L "$public_key_path" ] || [ ! -s "$public_key_path" ]; then
    echo "Bundled toolchain public key is missing: $public_key_path" >&2
    return 1
  fi
  bundled_manifest_url="$(cat "$manifest_path")"
  if [ "$bundled_manifest_url" != "$MANIFEST_URL" ]; then
    echo "Bundled toolchain manifest URL does not match --manifest-url." >&2
    return 1
  fi
  if ! cmp -s "$public_key_path" "$PUBLIC_KEY_FILE"; then
    echo "Bundled toolchain public key does not match --public-key-file." >&2
    return 1
  fi
}

VERIFY_BUNDLED_TOOLCHAIN=0
if [ -n "$MANIFEST_URL" ] || [ -n "$PUBLIC_KEY_FILE" ]; then
  if [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Packaged toolchain verification requires --manifest-url and --public-key-file together." >&2
    exit 1
  fi
  VERIFY_BUNDLED_TOOLCHAIN=1
fi

plutil -lint "$INFO_PLIST" >/dev/null
[ "$(read_plist CFBundleIdentifier)" = "com.easysplat.app" ]
[ "$(read_plist CFBundleIconFile)" = "EasySplatAppIcon" ]
[ "$(read_plist CFBundleShortVersionString)" = "$NUMERIC_VERSION" ]
[ "$(read_plist CFBundleVersion)" = "$NUMERIC_VERSION" ]
[ "$(read_plist EasySplatReleaseVersion)" = "$EXPECTED_VERSION" ]
[ "$(read_plist EasySplatReleaseChannel)" = "unsigned-beta" ]
[ -x "$EXECUTABLE" ]
verify_arm64_executable "Release app" "$EXECUTABLE"
verify_adhoc_bundle "$APP_PATH"
[ -s "$APP_PATH/Contents/Resources/EasySplatAppIcon.icns" ]
[ -s "$APP_PATH/Contents/Resources/Licenses/EasySplat-LICENSE.txt" ]
[ -s "$APP_PATH/Contents/Resources/Licenses/EasySplat-NOTICE.md" ]
[ -s "$APP_PATH/Contents/Resources/Licenses/MetalSplatter-LICENSE.txt" ]
[ -d "$APP_PATH/Contents/_CodeSignature" ]
EXPORTED_DSYM="$(dirname "$APP_PATH")/EasySplat.app.dSYM"
[ -d "$EXPORTED_DSYM" ]
verify_dsym_matches_executable "$EXECUTABLE" "$EXPORTED_DSYM"
[ "$(cat "$APP_PATH/Contents/Resources/release_channel.txt")" = "unsigned public beta" ]
if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
  validate_bundled_toolchain_contract "$APP_PATH"
fi

"$HDIUTIL_BIN" verify "$DMG_PATH" >/dev/null
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-beta-mount.XXXXXX")"
"$HDIUTIL_BIN" attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNT_ATTACHED=1
DISTRIBUTED_APP="$MOUNT_DIR/EasySplat.app"
DISTRIBUTED_INFO_PLIST="$DISTRIBUTED_APP/Contents/Info.plist"
DISTRIBUTED_EXECUTABLE="$DISTRIBUTED_APP/Contents/MacOS/EasySplatApp"
[ -d "$DISTRIBUTED_APP" ] && [ -x "$DISTRIBUTED_EXECUTABLE" ]
verify_arm64_executable "Mounted app" "$DISTRIBUTED_EXECUTABLE"
verify_adhoc_bundle "$DISTRIBUTED_APP"
[ -s "$DISTRIBUTED_APP/Contents/Resources/Licenses/EasySplat-LICENSE.txt" ]
[ -s "$DISTRIBUTED_APP/Contents/Resources/Licenses/EasySplat-NOTICE.md" ]
[ -s "$DISTRIBUTED_APP/Contents/Resources/Licenses/MetalSplatter-LICENSE.txt" ]
plutil -lint "$DISTRIBUTED_INFO_PLIST" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DISTRIBUTED_INFO_PLIST")" = "com.easysplat.app" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseVersion' "$DISTRIBUTED_INFO_PLIST")" = "$EXPECTED_VERSION" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$DISTRIBUTED_INFO_PLIST")" = "unsigned-beta" ]
EFFECTIVE_MANIFEST_URL=""
EFFECTIVE_PUBLIC_KEY_FILE=""
if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
  validate_bundled_toolchain_contract "$DISTRIBUTED_APP"
  EFFECTIVE_MANIFEST_URL="$(cat "$(bundled_app_resource "$DISTRIBUTED_APP" toolchain_manifest_url.txt)")"
  EFFECTIVE_PUBLIC_KEY_FILE="$(bundled_app_resource "$DISTRIBUTED_APP" public_key_ed25519.txt)"
fi

if [ "$VERIFY_ARTIFACTS" -eq 1 ]; then
  STEM="${DMG_PATH%-unsigned.dmg}"
  CHECKSUM="$DMG_PATH.sha256"
  PROVENANCE="$STEM.provenance.json"
  SBOM="$STEM.spdx.json"
  LICENSES="$STEM-licenses.zip"
  DSYM="$STEM-dSYM.zip"
  RELEASE_NOTES="$STEM-release-notes.txt"
  [ -f "$CHECKSUM" ] && [ -f "$PROVENANCE" ] && [ -f "$SBOM" ] && [ -f "$LICENSES" ]
  [ -f "$DSYM" ] && [ -f "$RELEASE_NOTES" ]
  (cd "$(dirname "$DMG_PATH")" && shasum -a 256 -c "$(basename "$CHECKSUM")")
  TOOLCHAIN_VERSION="$(python3 - "$PROVENANCE" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("toolchainVersion")
if not isinstance(value, str) or not value:
    raise SystemExit("Provenance has no toolchain version.")
print(value)
PY
)"
  RELEASE_MANIFEST="${RELEASE_MANIFEST:-$ROOT/Toolchains/manifest.json}"
  CORE_ARCHIVE="${CORE_ARCHIVE:-$ROOT/Toolchains/out/toolchain-macos-arm64-$TOOLCHAIN_VERSION-core.zip}"
  DA3_BASE_ARCHIVE="${DA3_BASE_ARCHIVE:-$ROOT/Toolchains/out/toolchain-geometry-da3-base-$TOOLCHAIN_VERSION.zip}"
  DA3_SMALL_ARCHIVE="${DA3_SMALL_ARCHIVE:-$ROOT/Toolchains/out/toolchain-geometry-da3-small-$TOOLCHAIN_VERSION.zip}"
  python3 "$ROOT/scripts/release/generate_release_metadata.py" verify \
    --app-version "$EXPECTED_VERSION" \
    --toolchain-version "$TOOLCHAIN_VERSION" \
    --release-mode unsigned-beta \
    --source-url "$SOURCE_URL" \
    --source-commit "$SOURCE_COMMIT" \
    --dmg "$DMG_PATH" \
    --manifest "$RELEASE_MANIFEST" \
    --core "$CORE_ARCHIVE" \
    --da3-base "$DA3_BASE_ARCHIVE" \
    --da3-small "$DA3_SMALL_ARCHIVE" \
    --app-license "$ROOT/LICENSE" \
    --notice "$ROOT/NOTICE.md" \
    --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
    --provenance "$PROVENANCE" \
    --spdx "$SBOM" \
    --licenses "$LICENSES"
  unzip -tq "$DSYM" >/dev/null
  grep -Fqi 'unsigned public beta' "$RELEASE_NOTES"
  if grep -Fqi 'production-ready' "$RELEASE_NOTES"; then
    echo "Unsigned beta release notes claim production readiness." >&2
    exit 1
  fi
fi

if [ "$SKIP_LAUNCH_SMOKE" -eq 0 ]; then
  SMOKE_LOG="$(mktemp "${TMPDIR:-/tmp}/easysplat-launch-smoke.XXXXXX")"
  if ! python3 - "$DISTRIBUTED_EXECUTABLE" "${EASYSPLAT_SMOKE_SECONDS:-3}" "$SMOKE_LOG" <<'PY'
import math
import signal
import subprocess
import sys
from pathlib import Path

executable, raw_timeout, log_path = sys.argv[1:]
try:
    timeout = float(raw_timeout)
except ValueError as exc:
    raise SystemExit(f"Invalid launch-smoke duration: {raw_timeout!r}") from exc
if not math.isfinite(timeout) or timeout < 0:
    raise SystemExit(f"Invalid launch-smoke duration: {raw_timeout!r}")


def interrupted(_signal: int, _frame: object) -> None:
    raise KeyboardInterrupt


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)
with Path(log_path).open("wb") as log:
    process = subprocess.Popen([executable], stdout=log, stderr=subprocess.STDOUT)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        status = None
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
if status is not None:
    raise SystemExit(f"App exited during launch smoke (status {status}).")
PY
  then
    cat "$SMOKE_LOG" >&2
    exit 1
  fi
  rm -f "$SMOKE_LOG"
  SMOKE_LOG=""
else
  echo "INCOMPLETE TEST MODE: launch smoke disabled."
fi

if [ -n "$E2E_FIXTURE" ] || [ -n "$TOOLCHAIN_ROOT" ] || [ -n "$E2E_RUNNER" ]; then
  if [ ! -e "$E2E_FIXTURE" ] || [ ! -d "$TOOLCHAIN_ROOT" ] || [ ! -x "$E2E_RUNNER" ] \
    || [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "End-to-end verification requires a fixture, manifest URL, public key, toolchain cache, and executable runner." >&2
    exit 1
  fi
  E2E_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-beta-e2e.XXXXXX")"
  E2E_OUTPUT="$E2E_DIR/splat.ply"
  "$E2E_RUNNER" \
    --fixture "$E2E_FIXTURE" \
    --manifest-url "$EFFECTIVE_MANIFEST_URL" \
    --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
    --cache-root "$TOOLCHAIN_ROOT" \
    --output "$E2E_OUTPUT" \
    --app-version "$EXPECTED_VERSION"
  [ -s "$E2E_OUTPUT" ]
  head -n 1 "$E2E_OUTPUT" | grep -qx 'ply'
  grep -a -m1 -Eq '^element vertex [1-9][0-9]*$' "$E2E_OUTPUT"
else
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    echo "Release verification requires an end-to-end fixture, installed toolchain, and runner." >&2
    exit 1
  fi
  echo "INCOMPLETE TEST MODE: end-to-end splat not supplied."
fi

if [ -n "$OFFLINE_CACHE_ROOT" ] || [ -n "$OFFLINE_RUNNER" ]; then
  if [ ! -d "$OFFLINE_CACHE_ROOT" ] || [ ! -x "$OFFLINE_RUNNER" ] \
    || [ ! -e "$E2E_FIXTURE" ] || [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Offline verification requires the fixture, manifest contract, populated cache, and executable runner." >&2
    exit 1
  fi
  OFFLINE_OUTPUT="$E2E_DIR/offline-splat.ply"
  "$OFFLINE_RUNNER" \
    --fixture "$E2E_FIXTURE" \
    --manifest-url "$EFFECTIVE_MANIFEST_URL" \
    --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
    --cache-root "$OFFLINE_CACHE_ROOT" \
    --output "$OFFLINE_OUTPUT" \
    --app-version "$EXPECTED_VERSION" \
    --offline
  [ -s "$OFFLINE_OUTPUT" ]
  head -n 1 "$OFFLINE_OUTPUT" | grep -qx 'ply'
  grep -a -m1 -Eq '^element vertex [1-9][0-9]*$' "$OFFLINE_OUTPUT"
else
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    echo "Release verification requires a populated offline cache and runner." >&2
    exit 1
  fi
  echo "INCOMPLETE TEST MODE: cached offline run not supplied."
fi

echo "Verified unsigned public beta: $EXPECTED_VERSION"
