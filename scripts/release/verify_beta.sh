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
CURL_BIN="${EASYSPLAT_CURL_BIN:-/usr/bin/curl}"
EXPECTED_RELEASE_RUNNER=""
MOUNT_DIR=""
MOUNT_DEVICE=""
MOUNT_ATTACHED=0
E2E_DIR=""
SMOKE_LOG=""
SMOKE_INSTALL_ROOT=""
REMOTE_MANIFEST=""
MAX_PUBLISHED_MANIFEST_BYTES=16777216
FINAL_SUCCESS_MESSAGE=""

usage() {
  echo "Usage: verify_beta.sh --app <app> --dmg <dmg> --expected-version <semver> --artifacts --source-url <https-url> --source-commit <sha> --fixture <media> --manifest-url <https-url> --public-key-file <file> --toolchain-root <dir> --e2e-runner <executable> --offline-cache-root <dir> --offline-runner <executable>"
}

detach_disk_image_once() {
  local detach_target="${MOUNT_DEVICE:-$MOUNT_DIR}"
  python3 - "$HDIUTIL_BIN" "$detach_target" <<'PY'
import os
import signal
import subprocess
import sys

try:
    process = subprocess.Popen(
        [sys.argv[1], "detach", sys.argv[2]],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
except OSError:
    raise SystemExit(127)

def terminate_process_group():
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=0.2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        pass

handled_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)

def abort_for_signal(signum, _frame):
    for handled_signal in handled_signals:
        signal.signal(handled_signal, signal.SIG_DFL)
    raise SystemExit(128 + signum)

for handled_signal in handled_signals:
    signal.signal(handled_signal, abort_for_signal)

try:
    return_code = process.wait(timeout=5.0)
except subprocess.TimeoutExpired:
    terminate_process_group()
    raise SystemExit(124)
except BaseException:
    terminate_process_group()
    raise

raise SystemExit(return_code)
PY
}

cleanup() {
  local status=$?
  local detached=0
  local cleanup_failed=0
  trap - EXIT
  set +e
  if [ "$MOUNT_ATTACHED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    for _ in {1..3}; do
      if detach_disk_image_once; then
        detached=1
        MOUNT_ATTACHED=0
        break
      fi
      sleep 0.1
    done
    if [ "$detached" -eq 0 ]; then
      echo "error: could not detach beta verification disk image: $MOUNT_DIR" >&2
      cleanup_failed=1
    fi
  fi
  if [ "$MOUNT_ATTACHED" -eq 0 ] && [ -n "$MOUNT_DIR" ]; then
    if ! rm -rf "$MOUNT_DIR"; then
      echo "error: could not remove beta verification mount directory: $MOUNT_DIR" >&2
      cleanup_failed=1
    fi
  fi
  if [ -n "$E2E_DIR" ] && ! rm -rf "$E2E_DIR"; then
    echo "error: could not remove beta verification end-to-end directory: $E2E_DIR" >&2
    cleanup_failed=1
  fi
  if [ -n "$SMOKE_LOG" ] && ! rm -f "$SMOKE_LOG"; then
    echo "error: could not remove beta verification smoke log: $SMOKE_LOG" >&2
    cleanup_failed=1
  fi
  if [ -n "$SMOKE_INSTALL_ROOT" ] && ! rm -rf "$SMOKE_INSTALL_ROOT"; then
    echo "error: could not remove beta verification installed app: $SMOKE_INSTALL_ROOT" >&2
    cleanup_failed=1
  fi
  if [ -n "$REMOTE_MANIFEST" ] && ! rm -f "$REMOTE_MANIFEST"; then
    echo "error: could not remove beta verification manifest: $REMOTE_MANIFEST" >&2
    cleanup_failed=1
  fi
  if [ "$status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -n "$FINAL_SUCCESS_MESSAGE" ]; then
    printf '%s\n' "$FINAL_SUCCESS_MESSAGE"
  fi
  exit "$status"
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

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

manifest_component_url() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
matches = [row.get("url") for row in manifest.get("components", []) if row.get("name") == sys.argv[2]]
if len(matches) != 1 or not isinstance(matches[0], str) or not matches[0]:
    raise SystemExit(f"Signed manifest has no unique URL for {sys.argv[2]}.")
if "\n" in matches[0] or "\r" in matches[0]:
    raise SystemExit(f"Signed manifest URL contains a line break for {sys.argv[2]}.")
print(matches[0])
PY
}

verify_signed_toolchain_closure() {
  local toolchain_version=$1
  local core_url
  local base_url
  local small_url
  core_url="$(manifest_component_url "$RELEASE_MANIFEST" macos-arm64-core)"
  base_url="$(manifest_component_url "$RELEASE_MANIFEST" geometry-da3-base)"
  small_url="$(manifest_component_url "$RELEASE_MANIFEST" geometry-da3-small)"
  swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool verify-release \
    --manifest "$RELEASE_MANIFEST" \
    --public-key-file "$EFFECTIVE_PUBLIC_KEY_FILE" \
    --toolchain-version "$toolchain_version" \
    --app-version "$EXPECTED_VERSION" \
    --core-zip "$CORE_ARCHIVE" \
    --core-url "$core_url" \
    --da3-base-zip "$DA3_BASE_ARCHIVE" \
    --da3-base-url "$base_url" \
    --da3-small-zip "$DA3_SMALL_ARCHIVE" \
    --da3-small-url "$small_url"
}

fetch_and_compare_published_manifest() {
  local http_status=""
  local size
  python3 - "$EFFECTIVE_MANIFEST_URL" <<'PY'
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
if url.scheme.lower() != "https" or not url.hostname or url.username is not None or url.password is not None:
    raise SystemExit("Published toolchain manifest URL must be credential-free HTTPS.")
PY
  REMOTE_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/easysplat-published-manifest.XXXXXX")"
  if ! http_status="$("$CURL_BIN" --disable \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --max-redirs 3 \
    --max-filesize "$MAX_PUBLISHED_MANIFEST_BYTES" \
    --request GET \
    --write-out '%{http_code}' \
    --output "$REMOTE_MANIFEST" \
    "$EFFECTIVE_MANIFEST_URL")"; then
    echo "Published toolchain manifest HTTPS GET failed (HTTP ${http_status:-unknown})." >&2
    return 1
  fi
  if [ "$http_status" != "200" ]; then
    echo "Published toolchain manifest HTTPS GET failed (HTTP $http_status)." >&2
    return 1
  fi
  size="$(wc -c <"$REMOTE_MANIFEST" | tr -d '[:space:]')"
  if [ "$size" -gt "$MAX_PUBLISHED_MANIFEST_BYTES" ]; then
    echo "Published toolchain manifest exceeds the 16 MiB release limit." >&2
    return 1
  fi
  if ! cmp -s "$REMOTE_MANIFEST" "$RELEASE_MANIFEST"; then
    echo "Published toolchain manifest bytes differ from the locally verified signed manifest." >&2
    return 1
  fi
}

if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
  if [ ! -e "$E2E_FIXTURE" ] || [ ! -d "$TOOLCHAIN_ROOT" ] || [ -z "$E2E_RUNNER" ] \
    || [ -z "$MANIFEST_URL" ] || [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Release verification requires an end-to-end fixture, installed toolchain, and runner." >&2
    exit 1
  fi
  if [ ! -d "$OFFLINE_CACHE_ROOT" ] || [ -z "$OFFLINE_RUNNER" ]; then
    echo "Release verification requires a shared offline cache and runner." >&2
    exit 1
  fi

  EXPECTED_RELEASE_RUNNER="$(swift build --package-path "$ROOT" -c release --show-bin-path)/EasySplatReleaseVerifier"
  if [ "$(canonical_path "$E2E_RUNNER")" != "$(canonical_path "$EXPECTED_RELEASE_RUNNER")" ] \
    || [ "$(canonical_path "$OFFLINE_RUNNER")" != "$(canonical_path "$EXPECTED_RELEASE_RUNNER")" ]; then
    echo "Strict release verification requires the repository-built EasySplatReleaseVerifier for both runs." >&2
    exit 1
  fi
  if [ "$(canonical_path "$TOOLCHAIN_ROOT")" != "$(canonical_path "$OFFLINE_CACHE_ROOT")" ]; then
    echo "Online and offline release verification must use the exact same toolchain cache." >&2
    exit 1
  fi
  if find "$TOOLCHAIN_ROOT" -mindepth 1 -print -quit | grep -q .; then
    echo "Release verification must start with an empty toolchain cache." >&2
    exit 1
  fi
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
read_optional_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}
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

verify_matching_executable_hashes() {
  local release_executable=$1
  local mounted_executable=$2
  local release_sha256
  local mounted_sha256
  release_sha256="$(/usr/bin/shasum -a 256 "$release_executable" | awk '{ print $1 }')"
  mounted_sha256="$(/usr/bin/shasum -a 256 "$mounted_executable" | awk '{ print $1 }')"
  if [ "$release_sha256" != "$mounted_sha256" ]; then
    echo "Mounted app executable SHA-256 does not match release app executable." >&2
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
[ "$(read_plist NSPrincipalClass)" = "NSApplication" ]
if [ "$(read_optional_plist LSUIElement)" = "true" ] || \
   [ "$(read_optional_plist LSBackgroundOnly)" = "true" ]; then
  echo "Release app must use the regular application activation policy." >&2
  exit 1
fi
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
ATTACH_OUTPUT="$("$HDIUTIL_BIN" attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH")"
MOUNT_ATTACHED=1
MOUNT_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -v mount="$MOUNT_DIR" '
  $1 ~ /^\/dev\/disk[0-9]+(s[0-9]+)*$/ &&
  length($0) > length(mount) &&
  substr($0, length($0) - length(mount) + 1) == mount &&
  substr($0, length($0) - length(mount), 1) ~ /[[:space:]]/ {
    print $1
    exit
  }
')"
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
[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$DISTRIBUTED_INFO_PLIST" 2>/dev/null || true)" = "NSApplication" ] || {
  echo "Mounted app NSPrincipalClass must be NSApplication." >&2
  exit 1
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseVersion' "$DISTRIBUTED_INFO_PLIST")" = "$EXPECTED_VERSION" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$DISTRIBUTED_INFO_PLIST")" = "unsigned-beta" ]
if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$DISTRIBUTED_INFO_PLIST" 2>/dev/null || true)" = "true" ] || \
   [ "$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$DISTRIBUTED_INFO_PLIST" 2>/dev/null || true)" = "true" ]; then
  echo "Mounted app must use the regular application activation policy." >&2
  exit 1
fi
verify_matching_executable_hashes "$EXECUTABLE" "$DISTRIBUTED_EXECUTABLE"
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
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    verify_signed_toolchain_closure "$TOOLCHAIN_VERSION"
    fetch_and_compare_published_manifest
  fi
  unzip -tq "$DSYM" >/dev/null
  grep -Fqi 'unsigned public beta' "$RELEASE_NOTES"
  if grep -Fqi 'production-ready' "$RELEASE_NOTES"; then
    echo "Unsigned beta release notes claim production readiness." >&2
    exit 1
  fi
fi

if [ "$SKIP_LAUNCH_SMOKE" -eq 0 ]; then
  SMOKE_INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-beta-install.XXXXXX")"
  SMOKE_APPLICATIONS_DIR="$SMOKE_INSTALL_ROOT/Applications"
  INSTALLED_APP="$SMOKE_APPLICATIONS_DIR/EasySplat.app"
  INSTALLED_INFO_PLIST="$INSTALLED_APP/Contents/Info.plist"
  INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/EasySplatApp"
  mkdir -p "$SMOKE_APPLICATIONS_DIR"
  /usr/bin/ditto "$DISTRIBUTED_APP" "$INSTALLED_APP"
  [ -d "$INSTALLED_APP" ] && [ -x "$INSTALLED_EXECUTABLE" ]
  plutil -lint "$INSTALLED_INFO_PLIST" >/dev/null
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_INFO_PLIST")" = "com.easysplat.app" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseVersion' "$INSTALLED_INFO_PLIST")" = "$EXPECTED_VERSION" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$INSTALLED_INFO_PLIST")" = "unsigned-beta" ]
  verify_arm64_executable "Installed app" "$INSTALLED_EXECUTABLE"
  verify_adhoc_bundle "$INSTALLED_APP"
  verify_matching_executable_hashes "$DISTRIBUTED_EXECUTABLE" "$INSTALLED_EXECUTABLE"
  if [ "$VERIFY_BUNDLED_TOOLCHAIN" -eq 1 ]; then
    validate_bundled_toolchain_contract "$INSTALLED_APP"
  fi
  SMOKE_LOG="$(mktemp "${TMPDIR:-/tmp}/easysplat-launch-smoke.XXXXXX")"
  if ! /usr/bin/xcrun swift - "$INSTALLED_APP" "${EASYSPLAT_SMOKE_SECONDS:-3}" \
    >"$SMOKE_LOG" 2>&1 <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func runLoopBriefly() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

func stop(_ application: NSRunningApplication) {
    guard !application.isTerminated else { return }
    _ = application.terminate()
    let deadline = Date().addingTimeInterval(2)
    while !application.isTerminated && Date() < deadline {
        runLoopBriefly()
    }
    if !application.isTerminated {
        _ = application.forceTerminate()
    }
}

func hasAppWindow(processIdentifier: pid_t) -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    return windows.contains { window in
        let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
        let isOnScreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
        let rawBounds = window[kCGWindowBounds as String] as? NSDictionary
        let bounds = rawBounds.flatMap(CGRect.init(dictionaryRepresentation:))
        return owner == processIdentifier
            && layer == 0
            && isOnScreen == true
            && alpha > 0
            && bounds.map { $0.width > 0 && $0.height > 0 } == true
    }
}

guard CommandLine.arguments.count == 3 else {
    fail("Launch smoke requires an app bundle and timeout.")
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let timeout = Double(CommandLine.arguments[2]), timeout.isFinite, timeout > 0 else {
    fail("Invalid launch-smoke duration: \(CommandLine.arguments[2]).")
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.addsToRecentItems = false
configuration.createsNewApplicationInstance = true
if ProcessInfo.processInfo.environment["EASYSPLAT_TEST_ACCESSORY_FIXTURE"] == "1" {
    configuration.environment = ["EASYSPLAT_TEST_ACCESSORY_FIXTURE": "1"]
}

var launchedApplication: NSRunningApplication?
var launchError: Error?
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
    launchedApplication = application
    launchError = error
}

let deadline = Date().addingTimeInterval(timeout)
while launchedApplication == nil && launchError == nil && Date() < deadline {
    runLoopBriefly()
}
if let launchError {
    fail("LaunchServices could not open the app during launch smoke: \(launchError.localizedDescription)")
}
guard let application = launchedApplication else {
    fail("App exited during launch smoke, or LaunchServices did not return it before the timeout.")
}

var foundAppWindow = false
var sawAnyAppWindow = false
let windowDeadline = Date().addingTimeInterval(timeout)
while Date() < windowDeadline {
    if application.isTerminated {
        fail("App exited during launch smoke.")
    }
    if !application.isHidden && hasAppWindow(processIdentifier: application.processIdentifier) {
        sawAnyAppWindow = true
        if application.activationPolicy == .regular {
            foundAppWindow = true
            break
        }
    }
    runLoopBriefly()
}
let finalActivationPolicy = application.activationPolicy
stop(application)
if !foundAppWindow && sawAnyAppWindow && finalActivationPolicy != .regular {
    fail("App did not use the regular application activation policy during launch smoke.")
}
if !foundAppWindow {
    fail("App opened without a normal app window during launch smoke.")
}
SWIFT
  then
    cat "$SMOKE_LOG" >&2
    exit 1
  fi
  rm -f "$SMOKE_LOG"
  SMOKE_LOG=""
  rm -rf "$SMOKE_INSTALL_ROOT"
  SMOKE_INSTALL_ROOT=""
else
  echo "INCOMPLETE TEST MODE: launch smoke disabled."
fi

if [ -n "$E2E_FIXTURE" ] || [ -n "$TOOLCHAIN_ROOT" ] || [ -n "$E2E_RUNNER" ]; then
  if [ "$ALLOW_INCOMPLETE" -eq 0 ]; then
    swift build --package-path "$ROOT" -c release --product EasySplatReleaseVerifier >/dev/null
    [ -x "$EXPECTED_RELEASE_RUNNER" ] || {
      echo "Repository-built EasySplatReleaseVerifier is missing after the release build." >&2
      exit 1
    }
    E2E_RUNNER="$EXPECTED_RELEASE_RUNNER"
    OFFLINE_RUNNER="$EXPECTED_RELEASE_RUNNER"
  fi
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
    echo "Release verification requires a shared offline cache and runner." >&2
    exit 1
  fi
  echo "INCOMPLETE TEST MODE: cached offline run not supplied."
fi

if [ "$ALLOW_INCOMPLETE" -eq 1 ]; then
  FINAL_SUCCESS_MESSAGE="Inspection only: static checks completed for $EXPECTED_VERSION; release verification is incomplete."
else
  FINAL_SUCCESS_MESSAGE="Verified unsigned public beta: $EXPECTED_VERSION"
fi
