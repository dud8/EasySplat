#!/usr/bin/env bash
# Source-contract assertions intentionally match literal shell and Actions expressions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
release_test_build_root="$TMP_DIR/app-build"
default_export="$ROOT/build/Export"

tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = hashlib.sha256()
if not os.path.lexists(root):
    digest.update(b"absent\0")
    print(digest.hexdigest())
    raise SystemExit(0)

paths = [root]
if root.is_dir() and not root.is_symlink():
    paths.extend(sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()))

for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    metadata = path.lstat()
    digest.update(relative.encode("utf-8", errors="surrogateescape"))
    digest.update(b"\0")
    digest.update(f"{metadata.st_mode}:{metadata.st_size}:{metadata.st_mtime_ns}".encode())
    digest.update(b"\0")
    if stat.S_ISLNK(metadata.st_mode):
        digest.update(os.readlink(path).encode("utf-8", errors="surrogateescape"))
    elif stat.S_ISREG(metadata.st_mode):
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
print(digest.hexdigest())
PY
}

default_export_before="$(tree_digest "$default_export")"
cleanup() {
  local status=$?
  local default_export_after
  trap - EXIT
  default_export_after="$(tree_digest "$default_export")" || status=1
  if [ "$default_export_after" != "$default_export_before" ]; then
    echo "Release-script tests modified the default app export at $default_export" >&2
    status=1
  fi
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

python3 "$ROOT/scripts/toolchain/tests/test_generate_supply_chain_manifest.py"
python3 "$ROOT/scripts/toolchain/tests/test_da3_payload.py"
python3 "$ROOT/scripts/toolchain/tests/test_create_reproducible_zip.py"
python3 "$ROOT/scripts/toolchain/tests/test_colmap_support_builder.py" \
  SourceContractTests ArchiveSafetyTests ReleaseArchiveMetadataTests AtomicPromotionTests
python3 "$ROOT/scripts/toolchain/tests/test_ceres_builder.py"
python3 "$ROOT/scripts/toolchain/tests/test_openimageio_builder.py"
python3 "$ROOT/scripts/toolchain/tests/test_native_colmap_retriever.py" SourceContractTests
swift test --package-path "$ROOT/Tools/ManifestTool"
python3 "$ROOT/scripts/release/tests/test_verify_publication_bundle.py"

unsafe_toolchain_root="$TMP_DIR/unsafe-toolchain-root"
mkdir -p "$unsafe_toolchain_root"
printf '%s' 'preserve' >"$unsafe_toolchain_root/sentinel"
unsafe_toolchain_error="$TMP_DIR/unsafe-toolchain-root.stderr"
if "$ROOT/scripts/run.sh" \
  --fast \
  --toolchain-root "$unsafe_toolchain_root" \
  >/dev/null 2>"$unsafe_toolchain_error"; then
  echo "Local launcher accepted an unsafe destructive toolchain root." >&2
  exit 1
fi
grep -Fqi 'Refusing unsafe toolchain root' "$unsafe_toolchain_error"
test "$(cat "$unsafe_toolchain_root/sentinel")" = preserve

signature_fixture="$TMP_DIR/rewritten-macho"
cp "$(command -v rg)" "$signature_fixture"
chmod +x "$signature_fixture"
install_name_tool -add_rpath '@executable_path/../lib' "$signature_fixture"
/usr/bin/codesign --force --sign - --timestamp=none "$signature_fixture"
/usr/bin/codesign --verify --strict "$signature_fixture"
"$signature_fixture" --version >/dev/null

mock_xcodebuild="$TMP_DIR/mock-xcodebuild.sh"
cat >"$mock_xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

derived=""
if [ -n "${EASYSPLAT_TEST_XCODEBUILD_LOG:-}" ]; then
  printf '%s\n' "$*" >"$EASYSPLAT_TEST_XCODEBUILD_LOG"
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -derivedDataPath)
      derived="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle"
mock_source="$derived/mock-app.c"
cat >"$mock_source" <<'SOURCE'
int main(void) {
    return 0;
}
SOURCE
if [ "${EASYSPLAT_TEST_ENABLE_COVERAGE:-}" = "1" ]; then
  for index in $(jot 10000 1); do
    printf '__attribute__((noinline,used)) int coverage_fixture_%s(void) { return %s; }\n' \
      "$index" "$index" >>"$mock_source"
  done
fi
mock_object="$derived/mock-app.o"
build_mock_binary() {
  xcrun clang \
    "$@" \
    -arch "${EASYSPLAT_TEST_BINARY_ARCH:-arm64}" \
    -g \
    -c \
    "$mock_source" \
    -o "$mock_object"
  xcrun clang \
    "$@" \
    -arch "${EASYSPLAT_TEST_BINARY_ARCH:-arm64}" \
    "$mock_object" \
    -o "$derived/Build/Products/Release/EasySplatApp"
}
if [ "${EASYSPLAT_TEST_ENABLE_COVERAGE:-}" = "1" ]; then
  build_mock_binary -fprofile-instr-generate -fcoverage-mapping
else
  build_mock_binary
fi
xcrun dsymutil \
  "$derived/Build/Products/Release/EasySplatApp" \
  -o "$derived/Build/Products/Release/EasySplatApp.dSYM"
/usr/bin/codesign --force --sign - --timestamp=none \
  "$derived/Build/Products/Release/EasySplatApp"
printf '%s' 'DEFAULT_MANIFEST_URL' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/toolchain_manifest_url.txt"
printf '%s' 'DEFAULT_PROJECT_URL' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/project_home_url.txt"
printf '%s' 'DEFAULT_PUBLIC_KEY' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt"
if [ -n "${EASYSPLAT_TEST_BUILD_WAIT_PATH:-}" ]; then
  : >"$EASYSPLAT_TEST_BUILD_WAIT_PATH.ready"
  while [ ! -e "$EASYSPLAT_TEST_BUILD_WAIT_PATH.release" ]; do
    sleep 0.05
  done
fi
EOF
chmod +x "$mock_xcodebuild"

manifest_before="$(cat "$ROOT/EasySplatApp/Resources/toolchain_manifest_url.txt")"
project_before="$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")"
public_before="$(cat "$ROOT/EasySplatApp/Resources/public_key_ed25519.txt")"

manifest_url="https://example.com/releases/download/toolchain-v1.2.3/manifest.json"
project_url="https://example.com/EasySplat"
public_key_path="$TMP_DIR/public_key.txt"
private_key_path="$TMP_DIR/private_key.txt"
swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool generate-keypair \
  --public-key-out "$public_key_path" \
  --private-key-out "$private_key_path"
xcodebuild_log="$TMP_DIR/xcodebuild.log"

missing_build_root_error="$TMP_DIR/missing-build-root.stderr"
if "$ROOT/scripts/release/build_app.sh" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --version "0.2.0-beta.1" \
  --unsigned-beta \
  --build-root >/dev/null 2>"$missing_build_root_error"; then
  echo "Release app build accepted --build-root without a value" >&2
  exit 1
fi
grep -Fqi -- '--build-root requires an absolute path' "$missing_build_root_error"

assert_unsafe_build_root_rejected() {
  local candidate="$1"
  local expected_error="$2"
  local error_path="$3"
  if "$ROOT/scripts/release/build_app.sh" \
    --build-root "$candidate" \
    --manifest-url "$manifest_url" \
    --public-key-path "$public_key_path" \
    --version "0.2.0-beta.1" \
    --unsigned-beta >/dev/null 2>"$error_path"; then
    echo "Release app build accepted unsafe build root: $candidate" >&2
    exit 1
  fi
  grep -Fqi "$expected_error" "$error_path"
}

assert_unsafe_build_root_rejected \
  "relative-build" "must be an absolute path" "$TMP_DIR/relative-build-root.stderr"
assert_unsafe_build_root_rejected \
  "/" "unsafe build root" "$TMP_DIR/filesystem-root.stderr"
assert_unsafe_build_root_rejected \
  "$ROOT" "unsafe build root" "$TMP_DIR/repository-root.stderr"
assert_unsafe_build_root_rejected \
  "$(dirname "$ROOT")" "unsafe build root" "$TMP_DIR/repository-parent.stderr"
assert_unsafe_build_root_rejected \
  "$TMP_DIR/app-build/../app-build" "must be normalized" \
  "$TMP_DIR/non-normalized-build-root.stderr"
root_build_link="$TMP_DIR/root-build-link"
ln -s / "$root_build_link"
assert_unsafe_build_root_rejected \
  "$root_build_link" "unsafe build root" "$TMP_DIR/symlinked-root.stderr"

insecure_app_url_error="$TMP_DIR/insecure-app-url.stderr"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "http://localhost:8000/manifest.json" \
  --public-key-path "$public_key_path" \
  --version "0.2.0-beta.1" \
  --unsigned-beta >/dev/null 2>"$insecure_app_url_error"; then
  echo "Release app build accepted an HTTP manifest URL" >&2
  exit 1
fi
grep -Fqi 'must use HTTPS' "$insecure_app_url_error"

x86_build_error="$TMP_DIR/build-app-x86.stderr"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_BINARY_ARCH=x86_64 \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "0.2.0-beta.1" \
  --unsigned-beta >/dev/null 2>"$x86_build_error"; then
  echo "Release app build accepted an x86_64-only executable" >&2
  exit 1
fi
if ! grep -Fqi 'Release app executable must contain exactly arm64' "$x86_build_error"; then
  cat "$x86_build_error" >&2
  exit 1
fi

profiled_build_error="$TMP_DIR/build-app-profiled.stderr"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_ENABLE_COVERAGE=1 \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "0.2.0-beta.1" \
  --unsigned-beta >/dev/null 2>"$profiled_build_error"; then
  echo "Release app build accepted a code-coverage-instrumented executable" >&2
  exit 1
fi
if ! grep -Fqi 'code-coverage instrumentation' "$profiled_build_error"; then
  cat "$profiled_build_error" >&2
  exit 1
fi

EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
EASYSPLAT_TEST_XCODEBUILD_LOG="$xcodebuild_log" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "0.2.0-beta.1" \
  --unsigned-beta
grep -Eq '(^| )ARCHS=arm64( |$)' "$xcodebuild_log"
grep -Eq '(^| )ONLY_ACTIVE_ARCH=YES( |$)' "$xcodebuild_log"
grep -Eq '(^| )ENABLE_CODE_COVERAGE=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )CLANG_ENABLE_CODE_COVERAGE=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )CLANG_COVERAGE_MAPPING=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO( |$)' "$xcodebuild_log"

app_bundle="$release_test_build_root/Export/EasySplat.app"
app_dsym="$release_test_build_root/Export/EasySplat.app.dSYM"
resources_dir="$app_bundle/Contents/Resources"

test "$(cat "$ROOT/EasySplatApp/Resources/toolchain_manifest_url.txt")" = "$manifest_before"
test "$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")" = "$project_before"
test "$(cat "$ROOT/EasySplatApp/Resources/public_key_ed25519.txt")" = "$public_before"

test "$(cat "$resources_dir/toolchain_manifest_url.txt")" = "$manifest_url"
test "$(cat "$resources_dir/project_home_url.txt")" = "$project_url"
cmp -s "$resources_dir/public_key_ed25519.txt" "$public_key_path"

module_resources_dir="$resources_dir/EasySplat_EasySplatApp.bundle"
test "$(cat "$module_resources_dir/toolchain_manifest_url.txt")" = "$manifest_url"
test "$(cat "$module_resources_dir/project_home_url.txt")" = "$project_url"
cmp -s "$module_resources_dir/public_key_ed25519.txt" "$public_key_path"

info_plist="$app_bundle/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" = "com.easysplat.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" = "EasySplatAppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$info_plist")" = "NSApplication"
test "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$info_plist")" = "unsigned-beta"
test -d "$app_dsym"
test -s "$resources_dir/EasySplatAppIcon.icns"
test -s "$resources_dir/Licenses/EasySplat-LICENSE.txt"
test -s "$resources_dir/Licenses/EasySplat-NOTICE.md"
test -s "$resources_dir/Licenses/MetalSplatter-LICENSE.txt"
test -d "$app_bundle/Contents/_CodeSignature"
/usr/bin/codesign --verify --deep --strict "$app_bundle"
/usr/bin/codesign --display --verbose=4 "$app_bundle" 2>&1 | grep -F 'Signature=adhoc' >/dev/null
test "$(cat "$resources_dir/release_channel.txt")" = "unsigned public beta"

early_exit_fixture="$TMP_DIR/early-exit-fixture"
mkdir -p "$early_exit_fixture"
cp -R "$app_bundle" "$early_exit_fixture/EasySplat.app"
xcrun dsymutil \
  "$early_exit_fixture/EasySplat.app/Contents/MacOS/EasySplatApp" \
  -o "$early_exit_fixture/EasySplat.app.dSYM"

smoke_fixture_source="$TMP_DIR/smoke-fixture.m"
cat >"$smoke_fixture_source" <<'EOF'
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
EOF
smoke_fixture_object="$TMP_DIR/smoke-fixture-arm64.o"
xcrun clang -arch arm64 -g -fobjc-arc -c \
  "$smoke_fixture_source" -o "$smoke_fixture_object"
xcrun clang -arch arm64 \
  "$smoke_fixture_object" \
  -framework AppKit \
  -o "$app_bundle/Contents/MacOS/EasySplatApp"
rm -rf "$app_dsym"
xcrun dsymutil \
  "$app_bundle/Contents/MacOS/EasySplatApp" \
  -o "$app_dsym"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$app_bundle"

production_error="$TMP_DIR/production.stderr"
production_xcodebuild_log="$TMP_DIR/production-xcodebuild.log"
rm -f "$production_xcodebuild_log"
if EASYSPLAT_DEVELOPER_ID_APPLICATION="Developer ID Application: Test" \
  EASYSPLAT_NOTARY_KEYCHAIN_PROFILE="test-notary-profile" \
  EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_XCODEBUILD_LOG="$production_xcodebuild_log" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "1.0.0" \
  --production >/dev/null 2>"$production_error"; then
  echo "Production app build succeeded even though production distribution is blocked" >&2
  exit 1
fi
grep -Fqi 'Production app builds are not available' "$production_error"
if [ -e "$production_xcodebuild_log" ]; then
  echo "Production app build reached xcodebuild instead of failing closed" >&2
  exit 1
fi
if rg -n 'EASYSPLAT_DEVELOPER_ID_APPLICATION|EASYSPLAT_NOTARY_KEYCHAIN_PROFILE|--options runtime|printf .*production.*release_channel' \
  "$ROOT/scripts/release/build_app.sh" >/dev/null; then
  echo "build_app.sh retains unreachable production implementation branches" >&2
  exit 1
fi

mode_error="$TMP_DIR/mode.stderr"
if "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --version "0.2.0-beta.1" \
  --unsigned-beta \
  --production >/dev/null 2>"$mode_error"; then
  echo "App build accepted conflicting release modes" >&2
  exit 1
fi
grep -Fqi 'exactly one release mode' "$mode_error"

missing_release_urls_error="$TMP_DIR/missing-release-urls.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0-beta.1" \
  --toolchain-version "2.0.0" \
  --use-existing-toolchain \
  --unsigned-beta >/dev/null 2>"$missing_release_urls_error"; then
  echo "Unsigned beta packaging accepted implicit release URLs" >&2
  exit 1
fi
grep -Fqi 'requires explicit HTTPS manifest and component URLs' "$missing_release_urls_error"

missing_existing_toolchain_error="$TMP_DIR/missing-existing-toolchain.stderr"
if EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE=1 \
  "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0-beta.1" \
  --toolchain-version "2.0.0" \
  --manifest-url "https://example.com/toolchain/manifest.json" \
  --core-artifact-url "https://example.com/toolchain/core.zip" \
  --da3-base-artifact-url "https://example.com/toolchain/da3-base.zip" \
  --da3-small-artifact-url "https://example.com/toolchain/da3-small.zip" \
  --unsigned-beta >/dev/null 2>"$missing_existing_toolchain_error"; then
  echo "Unsigned beta packaging rebuilt or signed a toolchain locally" >&2
  exit 1
fi
grep -Fqi 'requires --use-existing-toolchain' "$missing_existing_toolchain_error"
grep -Fq \
  'Toolchain Build creates unsigned archives and a signing request; the independent release authority signs and publishes the closure.' \
  "$missing_existing_toolchain_error"

insecure_release_url_error="$TMP_DIR/insecure-release-url.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0-beta.1" \
  --toolchain-version "2.0.0" \
  --manifest-url "https://example.com/toolchain/manifest.json" \
  --core-artifact-url "http://localhost:8000/toolchain/core.zip" \
  --da3-base-artifact-url "https://example.com/toolchain/da3-base.zip" \
  --da3-small-artifact-url "https://example.com/toolchain/da3-small.zip" \
  --use-existing-toolchain \
  --unsigned-beta >/dev/null 2>"$insecure_release_url_error"; then
  echo "Unsigned beta packaging accepted an HTTP component URL" >&2
  exit 1
fi
grep -Fqi 'must use HTTPS' "$insecure_release_url_error"

mock_hdiutil="$TMP_DIR/mock-hdiutil.sh"
cat >"$mock_hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$EASYSPLAT_TEST_HDIUTIL_LOG"
case "$1" in
  create)
    out="${!#}"
    printf '%s' 'mock dmg' >"$out"
    ;;
  verify) test -f "$2" ;;
  attach)
    mountpoint=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -mountpoint)
          mountpoint="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    test -n "$mountpoint"
    test -d "$mountpoint"
    test -d "$EASYSPLAT_TEST_APP_PATH"
    cp -R "$EASYSPLAT_TEST_APP_PATH" "$mountpoint/EasySplat.app"
    ;;
  detach)
    test -d "$2"
    if [[ -n "${EASYSPLAT_TEST_HDIUTIL_PID_FILE:-}" ]]; then
      printf '%s\n' "$$" >"$EASYSPLAT_TEST_HDIUTIL_PID_FILE"
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_ALWAYS_FAIL:-}" == "1" ]]; then
      exit 1
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_BLOCK:-}" == "1" ]]; then
      sleep 30
      exit 1
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_DELAY:-}" == "1" ]]; then
      sleep 2
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_FAIL_ONCE:-}" == "1" ]]; then
      test -n "${EASYSPLAT_TEST_HDIUTIL_DETACH_STATE:-}"
      if [[ ! -e "$EASYSPLAT_TEST_HDIUTIL_DETACH_STATE" ]]; then
        : >"$EASYSPLAT_TEST_HDIUTIL_DETACH_STATE"
        exit 1
      fi
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_LOCK_MOUNT_PARENT:-}" == "1" ]]; then
      chmod a-w "$(dirname "$2")"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$mock_hdiutil"
hdiutil_log="$TMP_DIR/hdiutil.log"
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  "$ROOT/scripts/release/create_dmg.sh" \
  --app-path "$app_bundle" \
  --out "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --volname "EasySplat"
grep -q '^create ' "$hdiutil_log"
grep -q '^verify ' "$hdiutil_log"

test -x "$ROOT/scripts/release/verify_beta.sh"
"$ROOT/scripts/release/verify_beta.sh" --help | grep -F 'Usage: verify_beta.sh' >/dev/null
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke

detach_retry_log="$TMP_DIR/hdiutil-detach-retry.log"
detach_retry_state="$TMP_DIR/hdiutil-detach-retry.state"
detach_retry_tmp="$TMP_DIR/hdiutil-detach-retry-tmp"
mkdir -p "$detach_retry_tmp"
TMPDIR="$detach_retry_tmp" \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$detach_retry_log" \
EASYSPLAT_TEST_HDIUTIL_DETACH_FAIL_ONCE=1 \
EASYSPLAT_TEST_HDIUTIL_DETACH_STATE="$detach_retry_state" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null
if [[ "$(grep -c '^detach ' "$detach_retry_log")" -ne 2 ]]; then
  echo "Beta verifier did not retry a transient disk-image detach failure" >&2
  exit 1
fi
if find "$detach_retry_tmp" -maxdepth 1 -name 'easysplat-beta-mount.*' -print -quit | grep -q .; then
  echo "Beta verifier left a mount directory after detach retry" >&2
  exit 1
fi

detach_delay_log="$TMP_DIR/hdiutil-detach-delay.log"
detach_delay_tmp="$TMP_DIR/hdiutil-detach-delay-tmp"
mkdir -p "$detach_delay_tmp"
TMPDIR="$detach_delay_tmp" \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$detach_delay_log" \
EASYSPLAT_TEST_HDIUTIL_DETACH_DELAY=1 \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null
if [[ "$(grep -c '^detach ' "$detach_delay_log")" -ne 1 ]]; then
  echo "Beta verifier killed a healthy slow disk-image detach" >&2
  exit 1
fi
if find "$detach_delay_tmp" -maxdepth 1 -name 'easysplat-beta-mount.*' -print -quit | grep -q .; then
  echo "Beta verifier left a mount directory after a healthy slow detach" >&2
  exit 1
fi

detach_failure_log="$TMP_DIR/hdiutil-detach-failure.log"
detach_failure_error="$TMP_DIR/hdiutil-detach-failure.stderr"
detach_failure_output="$TMP_DIR/hdiutil-detach-failure.stdout"
detach_failure_tmp="$TMP_DIR/hdiutil-detach-failure-tmp"
mkdir -p "$detach_failure_tmp"
if TMPDIR="$detach_failure_tmp" \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$detach_failure_log" \
  EASYSPLAT_TEST_HDIUTIL_DETACH_ALWAYS_FAIL=1 \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >"$detach_failure_output" 2>"$detach_failure_error"; then
  echo "Beta verifier accepted a persistent disk-image detach failure" >&2
  exit 1
fi
grep -Fq 'could not detach beta verification disk image' "$detach_failure_error"
if grep -Eiq 'Verified unsigned public beta|Inspection only|static checks completed' \
  "$detach_failure_output"; then
  echo "Beta verifier claimed success before a persistent detach failure" >&2
  exit 1
fi
if [[ "$(grep -c '^detach ' "$detach_failure_log")" -ne 3 ]]; then
  echo "Beta verifier did not exhaust its bounded detach retries" >&2
  exit 1
fi
detach_failure_mount_count=$(find "$detach_failure_tmp" -maxdepth 1 \
  -name 'easysplat-beta-mount.*' -type d | wc -l | tr -d ' ')
if [[ "$detach_failure_mount_count" -ne 1 ]]; then
  echo "Beta verifier removed or duplicated a mount directory after detach failure" >&2
  exit 1
fi
detach_failure_mount=$(find "$detach_failure_tmp" -maxdepth 1 \
  -name 'easysplat-beta-mount.*' -type d -print -quit)
if [[ ! -d "$detach_failure_mount/EasySplat.app" ]]; then
  echo "Beta verifier removed mounted contents after detach failure" >&2
  exit 1
fi

detach_block_log="$TMP_DIR/hdiutil-detach-block.log"
detach_block_error="$TMP_DIR/hdiutil-detach-block.stderr"
detach_block_output="$TMP_DIR/hdiutil-detach-block.stdout"
detach_block_tmp="$TMP_DIR/hdiutil-detach-block-tmp"
mkdir -p "$detach_block_tmp"
detach_block_started=$(python3 -c 'import time; print(time.monotonic())')
if TMPDIR="$detach_block_tmp" \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$detach_block_log" \
  EASYSPLAT_TEST_HDIUTIL_DETACH_BLOCK=1 \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >"$detach_block_output" 2>"$detach_block_error"; then
  echo "Beta verifier accepted a hung disk-image detach" >&2
  exit 1
fi
detach_block_finished=$(python3 -c 'import time; print(time.monotonic())')
python3 - "$detach_block_started" "$detach_block_finished" <<'PY'
import sys

elapsed = float(sys.argv[2]) - float(sys.argv[1])
if not 0 < elapsed < 28:
    raise SystemExit(f"Beta verifier detach timeout was not bounded: {elapsed:.3f}s")
PY
grep -Fq 'could not detach beta verification disk image' "$detach_block_error"
if [[ "$(grep -c '^detach ' "$detach_block_log")" -ne 3 ]]; then
  echo "Beta verifier did not bound every hung detach attempt" >&2
  exit 1
fi
if grep -Eiq 'Verified unsigned public beta|Inspection only|static checks completed' \
  "$detach_block_output"; then
  echo "Beta verifier claimed success after a hung detach" >&2
  exit 1
fi
detach_block_mount_count=$(find "$detach_block_tmp" -maxdepth 1 \
  -name 'easysplat-beta-mount.*' -type d | wc -l | tr -d ' ')
if [[ "$detach_block_mount_count" -ne 1 ]]; then
  echo "Beta verifier removed or duplicated a mount directory after a hung detach" >&2
  exit 1
fi
detach_block_mount=$(find "$detach_block_tmp" -maxdepth 1 \
  -name 'easysplat-beta-mount.*' -type d -print -quit)
if [[ ! -d "$detach_block_mount/EasySplat.app" ]]; then
  echo "Beta verifier removed mounted contents after a hung detach" >&2
  exit 1
fi

detach_signal_tmp="$TMP_DIR/hdiutil-detach-signal-tmp"
detach_signal_pid="$TMP_DIR/hdiutil-detach-signal.pid"
mkdir -p "$detach_signal_tmp"
python3 - \
  "$ROOT/scripts/release/verify_beta.sh" \
  "$mock_hdiutil" \
  "$app_bundle" \
  "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  "$detach_signal_tmp" \
  "$detach_signal_pid" <<'PY'
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

verifier, hdiutil, app, dmg, temp_dir, pid_path_raw = sys.argv[1:]
pid_path = Path(pid_path_raw)
environment = os.environ.copy()
environment.update(
    {
        "TMPDIR": temp_dir,
        "EASYSPLAT_HDIUTIL_BIN": hdiutil,
        "EASYSPLAT_TEST_HDIUTIL_DETACH_BLOCK": "1",
        "EASYSPLAT_TEST_HDIUTIL_LOG": f"{pid_path}.log",
        "EASYSPLAT_TEST_HDIUTIL_PID_FILE": str(pid_path),
        "EASYSPLAT_TEST_APP_PATH": app,
    }
)
process = subprocess.Popen(
    [
        verifier,
        "--app",
        app,
        "--dmg",
        dmg,
        "--expected-version",
        "0.2.0-beta.1",
        "--allow-incomplete",
        "--skip-launch-smoke",
    ],
    env=environment,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
mock_pid = None
try:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not pid_path.exists():
        if process.poll() is not None:
            raise SystemExit("Beta verifier exited before its detach helper started")
        time.sleep(0.05)
    if not pid_path.exists():
        raise SystemExit("Beta verifier did not start its detach helper")
    mock_pid = int(pid_path.read_text(encoding="utf-8").strip())

    os.killpg(process.pid, signal.SIGTERM)
    try:
        return_code = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise SystemExit("Interrupted beta verifier did not exit promptly")
    if return_code == 0:
        raise SystemExit("Interrupted beta verifier reported success")

    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(mock_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        os.killpg(mock_pid, signal.SIGKILL)
        raise SystemExit("Interrupted beta verifier orphaned its hdiutil process group")
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    if mock_pid is not None:
        try:
            os.killpg(mock_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY

cleanup_failure_log="$TMP_DIR/hdiutil-cleanup-failure.log"
cleanup_failure_error="$TMP_DIR/hdiutil-cleanup-failure.stderr"
cleanup_failure_output="$TMP_DIR/hdiutil-cleanup-failure.stdout"
cleanup_failure_tmp="$TMP_DIR/hdiutil-cleanup-failure-tmp"
mkdir -p "$cleanup_failure_tmp"
if TMPDIR="$cleanup_failure_tmp" \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$cleanup_failure_log" \
  EASYSPLAT_TEST_HDIUTIL_LOCK_MOUNT_PARENT=1 \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >"$cleanup_failure_output" 2>"$cleanup_failure_error"; then
  chmod u+w "$cleanup_failure_tmp"
  echo "Beta verifier accepted a mount-directory cleanup failure" >&2
  exit 1
fi
chmod u+w "$cleanup_failure_tmp"
grep -Fq 'could not remove beta verification mount directory' "$cleanup_failure_error"
if grep -Eiq 'Verified unsigned public beta|Inspection only|static checks completed' \
  "$cleanup_failure_output"; then
  echo "Beta verifier claimed success after a cleanup failure" >&2
  exit 1
fi

bundled_contract_only_output="$TMP_DIR/release-verifier-bundled-contract-only.stdout"
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --allow-incomplete \
  --skip-launch-smoke >"$bundled_contract_only_output"
grep -Fq 'INCOMPLETE TEST MODE: end-to-end splat not supplied.' "$bundled_contract_only_output"
grep -Fq 'INCOMPLETE TEST MODE: cached offline run not supplied.' "$bundled_contract_only_output"
grep -Fq 'Inspection only:' "$bundled_contract_only_output"
grep -Fq 'release verification is incomplete' "$bundled_contract_only_output"
if grep -Eiq 'Verified unsigned public beta|usable|distributable' "$bundled_contract_only_output"; then
  echo "Incomplete beta inspection made a release-readiness claim" >&2
  exit 1
fi

x86_fixture_object="$TMP_DIR/smoke-fixture-x86_64.o"
x86_fixture_binary="$TMP_DIR/EasySplatApp-x86_64"
xcrun clang -arch x86_64 -g -fobjc-arc -c \
  "$smoke_fixture_source" -o "$x86_fixture_object"
xcrun clang -arch x86_64 "$x86_fixture_object" \
  -framework AppKit -o "$x86_fixture_binary"
x86_app_fixture="$TMP_DIR/x86-app-fixture"
mkdir -p "$x86_app_fixture"
cp -R "$app_bundle" "$x86_app_fixture/EasySplat.app"
cp "$x86_fixture_binary" "$x86_app_fixture/EasySplat.app/Contents/MacOS/EasySplatApp"
xcrun dsymutil "$x86_fixture_binary" -o "$x86_app_fixture/EasySplat.app.dSYM"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$x86_app_fixture/EasySplat.app"
x86_app_error="$TMP_DIR/release-verifier-x86-app.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$x86_app_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$x86_app_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$x86_app_error"; then
  echo "Beta verification accepted an x86_64-only app executable" >&2
  exit 1
fi
grep -Fqi 'must contain exactly arm64' "$x86_app_error"

universal_fixture="$TMP_DIR/universal-fixture"
mkdir -p "$universal_fixture"
cp -R "$app_bundle" "$universal_fixture/EasySplat.app"
/usr/bin/lipo -create \
  "$app_bundle/Contents/MacOS/EasySplatApp" \
  "$x86_fixture_binary" \
  -output "$universal_fixture/EasySplat.app/Contents/MacOS/EasySplatApp"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$universal_fixture/EasySplat.app"
universal_error="$TMP_DIR/release-verifier-universal.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$universal_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$universal_error"; then
  echo "Beta verification accepted a universal app executable" >&2
  exit 1
fi
grep -Fqi 'must contain exactly arm64' "$universal_error"

mismatched_dsym_fixture="$TMP_DIR/mismatched-dsym-fixture"
mkdir -p "$mismatched_dsym_fixture"
cp -R "$app_bundle" "$mismatched_dsym_fixture/EasySplat.app"
xcrun dsymutil "$x86_fixture_binary" \
  -o "$mismatched_dsym_fixture/EasySplat.app.dSYM"
mismatched_dsym_error="$TMP_DIR/release-verifier-mismatched-dsym.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$mismatched_dsym_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$mismatched_dsym_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$mismatched_dsym_error"; then
  echo "Beta verification accepted a dSYM from another executable" >&2
  exit 1
fi
grep -Fqi 'Exported dSYM UUID does not match app executable' "$mismatched_dsym_error"

mismatched_distributed_error="$TMP_DIR/release-verifier-mismatched-distributed.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$early_exit_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$mismatched_distributed_error"; then
  echo "Beta verification accepted a DMG executable that differed from the release app" >&2
  exit 1
fi
grep -Fqi 'Mounted app executable SHA-256 does not match release app executable' \
  "$mismatched_distributed_error"

missing_distributed_principal_fixture="$TMP_DIR/missing-distributed-principal-fixture"
mkdir -p "$missing_distributed_principal_fixture"
cp -R "$app_bundle" "$missing_distributed_principal_fixture/EasySplat.app"
/usr/libexec/PlistBuddy -c 'Delete :NSPrincipalClass' \
  "$missing_distributed_principal_fixture/EasySplat.app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$missing_distributed_principal_fixture/EasySplat.app"
missing_distributed_principal_error="$TMP_DIR/release-verifier-missing-distributed-principal.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$missing_distributed_principal_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$missing_distributed_principal_error"; then
  echo "Beta verification accepted a distributed app without NSPrincipalClass" >&2
  exit 1
fi
if ! grep -Fqi 'NSPrincipalClass' "$missing_distributed_principal_error"; then
  cat "$missing_distributed_principal_error" >&2
  exit 1
fi

early_exit_error="$TMP_DIR/release-verifier-early-exit.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$early_exit_fixture/EasySplat.app" \
  EASYSPLAT_SMOKE_SECONDS=2 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$early_exit_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete >/dev/null 2>"$early_exit_error"; then
  echo "Beta verification accepted an app that exited before the smoke interval" >&2
  exit 1
fi
if ! grep -Fqi 'exited during launch smoke' "$early_exit_error"; then
  cat "$early_exit_error" >&2
  exit 1
fi

headless_error="$TMP_DIR/release-verifier-headless.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  EASYSPLAT_SMOKE_SECONDS=1 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete >/dev/null 2>"$headless_error"; then
  echo "Beta verification accepted an app that opened without a window" >&2
  exit 1
fi
if ! grep -Fqi 'without a normal app window' "$headless_error"; then
  cat "$headless_error" >&2
  exit 1
fi

window_fixture_source="$TMP_DIR/window-fixture.m"
cat >"$window_fixture_source" <<'EOF'
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        BOOL accessory = getenv("EASYSPLAT_TEST_ACCESSORY_FIXTURE") != NULL;
        [application setActivationPolicy:(accessory
            ? NSApplicationActivationPolicyAccessory
            : NSApplicationActivationPolicyRegular)];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 640, 480)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered
            defer:NO];
        window.title = @"EasySplat launch fixture";
        [window center];
        [window makeKeyAndOrderFront:nil];
        [application activateIgnoringOtherApps:YES];
        [application run];
    }
    return 0;
}
EOF
window_fixture_binary="$TMP_DIR/EasySplatApp-window"
window_fixture_object="$TMP_DIR/window-fixture.o"
xcrun clang -arch arm64 -g -fobjc-arc -c \
  "$window_fixture_source" -o "$window_fixture_object"
xcrun clang -arch arm64 "$window_fixture_object" \
  -framework AppKit -o "$window_fixture_binary"
window_app_fixture="$TMP_DIR/window-app-fixture"
mkdir -p "$window_app_fixture"
cp -R "$app_bundle" "$window_app_fixture/EasySplat.app"
cp "$window_fixture_binary" "$window_app_fixture/EasySplat.app/Contents/MacOS/EasySplatApp"
xcrun dsymutil "$window_fixture_binary" -o "$window_app_fixture/EasySplat.app.dSYM"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$window_app_fixture/EasySplat.app"
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$window_app_fixture/EasySplat.app" \
EASYSPLAT_SMOKE_SECONDS=3 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$window_app_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete >/dev/null

accessory_error="$TMP_DIR/release-verifier-accessory.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$window_app_fixture/EasySplat.app" \
  EASYSPLAT_TEST_ACCESSORY_FIXTURE=1 \
  EASYSPLAT_SMOKE_SECONDS=1 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$window_app_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete >/dev/null 2>"$accessory_error"; then
  echo "Beta verification accepted an accessory app with a window" >&2
  exit 1
fi
if ! grep -Fqi 'regular application activation policy' "$accessory_error"; then
  cat "$accessory_error" >&2
  exit 1
fi

missing_public_key_fixture="$TMP_DIR/missing-public-key-fixture"
mkdir -p "$missing_public_key_fixture"
cp -R "$app_bundle" "$missing_public_key_fixture/EasySplat.app"
rm "$missing_public_key_fixture/EasySplat.app/Contents/Resources/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$missing_public_key_fixture/EasySplat.app"
cp -R "$app_dsym" \
  "$missing_public_key_fixture/EasySplat.app.dSYM"
missing_public_key_error="$TMP_DIR/release-verifier-missing-public-key.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$missing_public_key_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$missing_public_key_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$missing_public_key_error"; then
  echo "Beta verification accepted a missing bundled public key" >&2
  exit 1
fi
grep -Fqi 'bundled toolchain public key is missing' "$missing_public_key_error"

mismatched_manifest_fixture="$TMP_DIR/mismatched-manifest-fixture"
mkdir -p "$mismatched_manifest_fixture"
cp -R "$app_bundle" "$mismatched_manifest_fixture/EasySplat.app"
printf '%s' 'https://downloads.example.com/wrong-manifest.json' \
  >"$mismatched_manifest_fixture/EasySplat.app/Contents/Resources/EasySplat_EasySplatApp.bundle/toolchain_manifest_url.txt"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$mismatched_manifest_fixture/EasySplat.app"
cp -R "$app_dsym" \
  "$mismatched_manifest_fixture/EasySplat.app.dSYM"
mismatched_manifest_error="$TMP_DIR/release-verifier-mismatched-manifest.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$mismatched_manifest_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$mismatched_manifest_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$mismatched_manifest_error"; then
  echo "Beta verification accepted a mismatched bundled manifest URL" >&2
  exit 1
fi
grep -Fqi 'bundled toolchain manifest URL does not match' "$mismatched_manifest_error"

grep -Fq -- '--unsigned-beta)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--production)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'EasySplat-$APP_VERSION-unsigned.dmg' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq '.sha256' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq '.provenance.json' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq '.spdx.json' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '-licenses.zip' "$ROOT/scripts/release/build_dmg.sh"

metadata_fixture="$TMP_DIR/release-metadata"
mkdir -p \
  "$metadata_fixture/core/bin" \
  "$metadata_fixture/core/lib" \
  "$metadata_fixture/core/provenance" \
  "$metadata_fixture/core/msplat" \
  "$metadata_fixture/core/licenses/example" \
  "$metadata_fixture/base/da3_mps/bin" \
  "$metadata_fixture/base/da3_mps/python/bin" \
  "$metadata_fixture/base/da3_mps/app/easysplat_da3_sfm" \
  "$metadata_fixture/base/da3_mps/vendor/depth-anything-3/src/depth_anything_3" \
  "$metadata_fixture/base/da3_mps/models/DA3-BASE" \
  "$metadata_fixture/small/da3_mps/models/DA3-SMALL"
printf 'Apache-2.0 test license\n' >"$metadata_fixture/core/licenses/example/LICENSE"
ln -s ../licenses/example/LICENSE "$metadata_fixture/core/bin/license-link"
for path in \
  bin/colmap \
  bin/easysplat-train \
  bin/default.metallib \
  lib/libomp.dylib \
  provenance/colmap.json \
  provenance/colmap-support.json \
  provenance/ceres.json \
  provenance/openimageio.json \
  msplat/build_info.json \
  msplat/LICENSE; do
  printf 'release fixture: %s\n' "$path" >"$metadata_fixture/core/$path"
done
for path in \
  da3_mps/bin/easysplat_da3_sfm \
  da3_mps/python/bin/python3 \
  da3_mps/app/easysplat_da3_sfm/run.py \
  da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py \
  da3_mps/build_info.json; do
  printf 'release fixture: %s\n' "$path" >"$metadata_fixture/base/$path"
done
for model in DA3-BASE DA3-SMALL; do
  case "$model" in
    DA3-BASE) model_root="$metadata_fixture/base/da3_mps/models/$model" ;;
    DA3-SMALL) model_root="$metadata_fixture/small/da3_mps/models/$model" ;;
  esac
  printf '{}\n' >"$model_root/config.json"
  printf '%s-weights' "$model" >"$model_root/model.safetensors"
  printf '{"model":"%s"}\n' "$model" >"$model_root/easysplat_model_info.json"
  printf 'Apache-2.0 test license\n' >"$model_root/LICENSE"
done
python3 - "$metadata_fixture" <<'PY'
import hashlib
import json
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
locations = {
    "bin/license-link": root / "core/bin/license-link",
    "bin/colmap": root / "core/bin/colmap",
    "bin/default.metallib": root / "core/bin/default.metallib",
    "bin/easysplat-train": root / "core/bin/easysplat-train",
    "lib/libomp.dylib": root / "core/lib/libomp.dylib",
    "provenance/colmap.json": root / "core/provenance/colmap.json",
    "provenance/colmap-support.json": root / "core/provenance/colmap-support.json",
    "provenance/ceres.json": root / "core/provenance/ceres.json",
    "provenance/openimageio.json": root / "core/provenance/openimageio.json",
    "da3_mps/app/easysplat_da3_sfm/run.py": root / "base/da3_mps/app/easysplat_da3_sfm/run.py",
    "da3_mps/bin/easysplat_da3_sfm": root / "base/da3_mps/bin/easysplat_da3_sfm",
    "da3_mps/build_info.json": root / "base/da3_mps/build_info.json",
    "da3_mps/python/bin/python3": root / "base/da3_mps/python/bin/python3",
    "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py": root / "base/da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
    "msplat/build_info.json": root / "core/msplat/build_info.json",
    "msplat/LICENSE": root / "core/msplat/LICENSE",
    "licenses/example/LICENSE": root / "core/licenses/example/LICENSE",
}
for model, archive in (("DA3-BASE", "base"), ("DA3-SMALL", "small")):
    for filename in ("LICENSE", "config.json", "easysplat_model_info.json", "model.safetensors"):
        path = f"da3_mps/models/{model}/{filename}"
        locations[path] = root / archive / path
paths = sorted(locations)
component = {
    "id": "test:closure",
    "name": "EasySplat release fixture",
    "type": "fixture",
    "version": "1.0.0",
    "revision": "deadbeef",
    "source": "https://example.com/easysplat-release-fixture",
    "buildCommand": "./scripts/ci/test_release_scripts.sh",
    "license": "Apache-2.0",
    "linkage": "runtime",
    "licenseFiles": ["licenses/example/LICENSE"],
    "dependencies": [],
    "files": paths,
}
files = []
for path in paths:
    location = locations[path]
    data = location.read_bytes()
    files.append({
        "path": path,
        "component": component["id"],
        "kind": "file",
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    })
payload = {
    "schemaVersion": 1,
    "toolchainVersion": "2.0.0",
    "components": [component],
    "files": files,
}
components_path = root / "core/supply-chain/components.json"
components_path.parent.mkdir(parents=True)
components_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
(cd "$metadata_fixture/core" && zip -qr "$metadata_fixture/core.zip" .)
(cd "$metadata_fixture/base" && zip -qr "$metadata_fixture/base.zip" .)
(cd "$metadata_fixture/small" && zip -qr "$metadata_fixture/small.zip" .)
python3 - "$metadata_fixture/core.zip" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert not any(stat.S_ISLNK(info.external_attr >> 16) for info in archive.infolist())
    assert archive.read("bin/license-link") == archive.read("licenses/example/LICENSE")
PY
swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool \
  --core-zip "$metadata_fixture/core.zip" \
  --core-url https://example.com/core.zip \
  --da3-base-zip "$metadata_fixture/base.zip" \
  --da3-base-url https://example.com/base.zip \
  --da3-small-zip "$metadata_fixture/small.zip" \
  --da3-small-url https://example.com/small.zip \
  --version 2.0.0 \
  --published-at 2026-07-11T00:00:00Z \
  --app-version-minimum 0.2.0-beta.1 \
  --app-version-maximum-exclusive 0.3.0 \
  --private-key-file "$private_key_path" \
  --manifest-out "$metadata_fixture/manifest.json"

beta_dmg="$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg"
beta_stem="${beta_dmg%-unsigned.dmg}"
metadata_tool="$ROOT/scripts/release/generate_release_metadata.py"
python3 - "$metadata_tool" "$TMP_DIR" <<'PY'
import hashlib
import importlib.util
import struct
import sys
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_metadata", Path(sys.argv[1]))
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.validate_normal_photo_install_size({
    "core": 2_000_000_000,
    "geometry-da3-base": 1_999_999_999,
    "geometry-da3-small": 1_999_999_999,
})
try:
    module.validate_normal_photo_install_size({
        "core": 2_500_000_001,
        "geometry-da3-base": 1,
        "geometry-da3-small": 1,
    })
except module.MetadataError:
    pass
else:
    raise AssertionError("core-only size gate accepted more than 2.5 GB")
try:
    module.validate_normal_photo_install_size({
        "core": 2_000_000_000,
        "geometry-da3-base": 2_000_000_000,
        "geometry-da3-small": 2_000_000_001,
    })
except module.MetadataError:
    pass
else:
    raise AssertionError("full optional size gate accepted more than 6 GB")

wheel_url = "https://files.pythonhosted.org/packages/addict-2.4.0-py3-none-any.whl"
assert module.validate_https_url(wheel_url, "wheel URL") == wheel_url
protobuf_path = "torch/include/google/protobuf/unknown_field_set.h"
assert module.require_text(protobuf_path, "runtime path") == protobuf_path
for placeholder in ("unknown", "NOASSERTION", "none"):
    try:
        module.validate_https_url(placeholder, "placeholder URL")
    except module.MetadataError:
        pass
    else:
        raise AssertionError(f"release metadata accepted placeholder URL: {placeholder}")

arm64 = b"\xcf\xfa\xed\xfe" + struct.pack("<II", module.CPU_TYPE_ARM64, 0) + b"payload"
module.validate_thin_arm64_macho_header(arm64[:12], "bin/native")
for label, header in {
    "x86_64": b"\xcf\xfa\xed\xfe" + struct.pack("<II", 0x01000007, 3),
    "arm64e": b"\xcf\xfa\xed\xfe" + struct.pack("<II", module.CPU_TYPE_ARM64, 2),
    "universal": b"\xca\xfe\xba\xbe" + b"\x00" * 8,
}.items():
    try:
        module.validate_thin_arm64_macho_header(header, label)
    except module.MetadataError:
        pass
    else:
        raise AssertionError(f"accepted {label} Mach-O header")

archive_path = Path(sys.argv[2]) / "arm64-archive-contract.zip"
row = {
    "path": "bin/native",
    "component": "fixture",
    "kind": "mach-o",
    "size": len(arm64),
    "sha256": hashlib.sha256(arm64).hexdigest(),
    "dependencies": [],
}
with zipfile.ZipFile(archive_path, "w") as archive:
    archive.writestr(row["path"], arm64)
module.inspect_archive(
    module.ArchiveSpec("geometry-da3-base", archive_path, "https://example.com/native.zip"),
    {row["path"]: row},
    set(),
)
x86 = b"\xcf\xfa\xed\xfe" + struct.pack("<II", 0x01000007, 3) + b"payload"
row["size"] = len(x86)
row["sha256"] = hashlib.sha256(x86).hexdigest()
with zipfile.ZipFile(archive_path, "w") as archive:
    archive.writestr(row["path"], x86)
try:
    module.inspect_archive(
        module.ArchiveSpec("geometry-da3-base", archive_path, "https://example.com/native.zip"),
        {row["path"]: row},
        set(),
    )
except module.MetadataError:
    pass
else:
    raise AssertionError("release archive inspection accepted an x86_64 Mach-O")
PY
python3 "$metadata_tool" verify-toolchain \
  --toolchain-version 2.0.0 \
  --manifest "$metadata_fixture/manifest.json" \
  --core "$metadata_fixture/core.zip" \
  --core-url https://example.com/core.zip \
  --da3-base "$metadata_fixture/base.zip" \
  --da3-base-url https://example.com/base.zip \
  --da3-small "$metadata_fixture/small.zip" \
  --da3-small-url https://example.com/small.zip
python3 "$metadata_tool" generate \
  --app-version 0.2.0-beta.1 \
  --toolchain-version 2.0.0 \
  --release-mode unsigned-beta \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef \
  --dmg "$beta_dmg" \
  --manifest "$metadata_fixture/manifest.json" \
  --manifest-url https://example.com/manifest.json \
  --core "$metadata_fixture/core.zip" \
  --core-url https://example.com/core.zip \
  --da3-base "$metadata_fixture/base.zip" \
  --da3-base-url https://example.com/base.zip \
  --da3-small "$metadata_fixture/small.zip" \
  --da3-small-url https://example.com/small.zip \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$beta_stem.provenance.json" \
  --spdx-out "$beta_stem.spdx.json" \
  --licenses-out "$beta_stem-licenses.zip"
metadata_verify_args=(
  --app-version 0.2.0-beta.1 \
  --toolchain-version 2.0.0 \
  --release-mode unsigned-beta \
  --dmg "$beta_dmg" \
  --manifest "$metadata_fixture/manifest.json" \
  --core "$metadata_fixture/core.zip" \
  --da3-base "$metadata_fixture/base.zip" \
  --da3-small "$metadata_fixture/small.zip" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance "$beta_stem.provenance.json" \
  --spdx "$beta_stem.spdx.json" \
  --licenses "$beta_stem-licenses.zip"
)
python3 "$metadata_tool" verify \
  "${metadata_verify_args[@]}" \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef

mismatched_source_commit_error="$TMP_DIR/mismatched-source-commit.stderr"
if python3 "$metadata_tool" verify \
  "${metadata_verify_args[@]}" \
  --source-url https://example.com/EasySplat \
  --source-commit cafebabe >/dev/null 2>"$mismatched_source_commit_error"; then
  echo "Release metadata accepted provenance for a different source commit" >&2
  exit 1
fi
grep -Fqi 'release provenance does not exactly match shipped artifacts' \
  "$mismatched_source_commit_error"

mismatched_source_url_error="$TMP_DIR/mismatched-source-url.stderr"
if python3 "$metadata_tool" verify \
  "${metadata_verify_args[@]}" \
  --source-url https://example.com/AnotherRepository \
  --source-commit deadbeef >/dev/null 2>"$mismatched_source_url_error"; then
  echo "Release metadata accepted provenance for a different source repository" >&2
  exit 1
fi
grep -Fqi 'release provenance does not exactly match shipped artifacts' \
  "$mismatched_source_url_error"
python3 -m json.tool "$beta_stem.provenance.json" >/dev/null
python3 -m json.tool "$beta_stem.spdx.json" >/dev/null
python3 - "$beta_stem.provenance.json" "$beta_stem.spdx.json" <<'PY'
import json
import sys
from pathlib import Path

provenance = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
spdx = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
viewer = provenance["sourceDependencies"]["MetalSplatter"]
assert provenance["source"]["buildCommand"] == "./scripts/release/build_app.sh"
assert viewer["source"] == "https://github.com/scier/MetalSplatter"
assert viewer["basedOnRevision"] == "c0f066fb7146d46d9b68e5c76d7d0a6154facc5e"
assert viewer["buildCommand"] == "./scripts/release/build_app.sh"
assert len(viewer["vendoredTreeSHA256"]) == 64

packages = {package["SPDXID"]: package for package in spdx["packages"]}
viewer_package = packages["SPDXRef-Package-MetalSplatter"]
assert viewer_package["licenseDeclared"] == "MIT"
assert viewer_package["checksums"] == [
    {"algorithm": "SHA256", "checksumValue": viewer["vendoredTreeSHA256"]}
]
assert {
    "spdxElementId": "SPDXRef-Package-EasySplat",
    "relationshipType": "STATIC_LINK",
    "relatedSpdxElement": "SPDXRef-Package-MetalSplatter",
} in spdx["relationships"]
PY
unzip -tq "$beta_stem-licenses.zip" >/dev/null
unzip -Z1 "$beta_stem-licenses.zip" | grep -Fx 'toolchain-closure.json' >/dev/null
(cd "$TMP_DIR" && shasum -a 256 "$(basename "$beta_dmg")" >"$(basename "$beta_dmg").sha256")
(cd "$release_test_build_root/Export" && zip -qry "$beta_stem-dSYM.zip" EasySplat.app.dSYM)
printf '%s\n' 'EasySplat 0.2.0-beta.1 is an unsigned public beta.' >"$beta_stem-release-notes.txt"
release_metadata_args=(
  --release-manifest "$metadata_fixture/manifest.json"
  --core-archive "$metadata_fixture/core.zip"
  --da3-base-archive "$metadata_fixture/base.zip"
  --da3-small-archive "$metadata_fixture/small.zip"
)
release_source_args=(
  --source-url https://example.com/EasySplat
  --source-commit deadbeef
)
missing_release_source_error="$TMP_DIR/release-verifier-missing-source.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$missing_release_source_error"; then
  echo "Beta verification accepted artifacts without trusted source identity" >&2
  exit 1
fi
grep -Fqi 'requires --source-url and --source-commit' "$missing_release_source_error"

EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  "${release_source_args[@]}" \
  --allow-incomplete \
  --skip-launch-smoke

fixture="$TMP_DIR/release-verifier-fixture.mov"
online_cache="$TMP_DIR/release-verifier-online-cache"
offline_cache="$TMP_DIR/release-verifier-offline-cache"
printf '%s' 'fixture' >"$fixture"
mkdir -p "$online_cache" "$offline_cache"

online_runner="$TMP_DIR/arbitrary-release-runner"
cat >"$online_runner" <<'EOF'
#!/usr/bin/env bash
echo "Arbitrary release runner was invoked." >&2
exit 97
EOF
chmod +x "$online_runner"

run_strict_verifier() {
  local dmg=$1
  local release_manifest=$2
  local cache=$3
  local offline_cache=$4
  local runner=$5
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
    EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
    EASYSPLAT_TEST_APP_PATH="$app_bundle" \
    EASYSPLAT_SMOKE_SECONDS=0 \
    "$ROOT/scripts/release/verify_beta.sh" \
    --app "$app_bundle" \
    --dmg "$dmg" \
    --expected-version "0.2.0-beta.1" \
    --artifacts \
    --source-url https://example.com/EasySplat \
    --source-commit deadbeef \
    --release-manifest "$release_manifest" \
    --core-archive "$metadata_fixture/core.zip" \
    --da3-base-archive "$metadata_fixture/base.zip" \
    --da3-small-archive "$metadata_fixture/small.zip" \
    --fixture "$fixture" \
    --manifest-url "$manifest_url" \
    --public-key-file "$public_key_path" \
    --toolchain-root "$cache" \
    --e2e-runner "$runner" \
    --offline-cache-root "$offline_cache" \
    --offline-runner "$runner"
}

partial_e2e_error="$TMP_DIR/release-verifier-partial-e2e.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --fixture "$fixture" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --allow-incomplete \
  --skip-launch-smoke >/dev/null 2>"$partial_e2e_error"; then
  echo "Incomplete beta verification accepted partial end-to-end inputs" >&2
  exit 1
fi
grep -Fqi 'End-to-end verification requires' "$partial_e2e_error"

missing_e2e_error="$TMP_DIR/release-verifier-missing-e2e.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  EASYSPLAT_SMOKE_SECONDS=0 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  "${release_source_args[@]}" >/dev/null 2>"$missing_e2e_error"; then
  echo "Strict beta verification accepted a release without end-to-end inputs" >&2
  exit 1
fi
grep -Fqi 'requires an end-to-end fixture' "$missing_e2e_error"

missing_offline_error="$TMP_DIR/release-verifier-missing-offline.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  EASYSPLAT_SMOKE_SECONDS=0 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  "${release_source_args[@]}" \
  --fixture "$fixture" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --toolchain-root "$online_cache" \
  --e2e-runner "$online_runner" >/dev/null 2>"$missing_offline_error"; then
  echo "Strict beta verification accepted a release without cached-offline inputs" >&2
  exit 1
fi
grep -Fqi 'requires a shared offline cache and runner' "$missing_offline_error"

arbitrary_runner_error="$TMP_DIR/release-verifier-arbitrary-runner.stderr"
if run_strict_verifier \
  "$beta_dmg" "$metadata_fixture/manifest.json" \
  "$online_cache" "$online_cache" "$online_runner" \
  >/dev/null 2>"$arbitrary_runner_error"; then
  echo "Strict beta verification accepted an arbitrary end-to-end runner" >&2
  exit 1
fi
grep -Fqi 'repository-built EasySplatReleaseVerifier' "$arbitrary_runner_error"

repository_runner="$(swift build --package-path "$ROOT" -c release --show-bin-path)/EasySplatReleaseVerifier"
mismatched_cache_error="$TMP_DIR/release-verifier-mismatched-cache.stderr"
if run_strict_verifier \
  "$beta_dmg" "$metadata_fixture/manifest.json" \
  "$online_cache" "$offline_cache" "$repository_runner" \
  >/dev/null 2>"$mismatched_cache_error"; then
  echo "Strict beta verification accepted separate online and offline caches" >&2
  exit 1
fi
grep -Fqi 'exact same toolchain cache' "$mismatched_cache_error"

dirty_cache="$TMP_DIR/release-verifier-dirty-cache"
mkdir -p "$dirty_cache"
printf '%s' stale >"$dirty_cache/stale"
dirty_cache_error="$TMP_DIR/release-verifier-dirty-cache.stderr"
if run_strict_verifier \
  "$beta_dmg" "$metadata_fixture/manifest.json" \
  "$dirty_cache" "$dirty_cache" "$repository_runner" \
  >/dev/null 2>"$dirty_cache_error"; then
  echo "Strict beta verification accepted a pre-populated toolchain cache" >&2
  exit 1
fi
grep -Fqi 'must start with an empty toolchain cache' "$dirty_cache_error"

tampered_manifest="$TMP_DIR/tampered-manifest.json"
python3 - "$metadata_fixture/manifest.json" "$tampered_manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
manifest["signatureEd25519"] = "AAAA"
Path(sys.argv[2]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
tampered_dmg="$TMP_DIR/EasySplat-tampered-unsigned.dmg"
tampered_stem="${tampered_dmg%-unsigned.dmg}"
cp "$beta_dmg" "$tampered_dmg"
python3 "$metadata_tool" generate \
  --app-version 0.2.0-beta.1 \
  --toolchain-version 2.0.0 \
  --release-mode unsigned-beta \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef \
  --dmg "$tampered_dmg" \
  --manifest "$tampered_manifest" \
  --manifest-url "$manifest_url" \
  --core "$metadata_fixture/core.zip" \
  --core-url https://example.com/core.zip \
  --da3-base "$metadata_fixture/base.zip" \
  --da3-base-url https://example.com/base.zip \
  --da3-small "$metadata_fixture/small.zip" \
  --da3-small-url https://example.com/small.zip \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$tampered_stem.provenance.json" \
  --spdx-out "$tampered_stem.spdx.json" \
  --licenses-out "$tampered_stem-licenses.zip"
(cd "$TMP_DIR" && shasum -a 256 "$(basename "$tampered_dmg")" >"$(basename "$tampered_dmg").sha256")
(cd "$release_test_build_root/Export" && zip -qry "$tampered_stem-dSYM.zip" EasySplat.app.dSYM)
printf '%s\n' 'EasySplat 0.2.0-beta.1 is an unsigned public beta.' >"$tampered_stem-release-notes.txt"
tampered_cache="$TMP_DIR/release-verifier-tampered-cache"
mkdir -p "$tampered_cache"
tampered_manifest_error="$TMP_DIR/release-verifier-tampered-manifest.stderr"
if run_strict_verifier \
  "$tampered_dmg" "$tampered_manifest" \
  "$tampered_cache" "$tampered_cache" "$repository_runner" \
  >/dev/null 2>"$tampered_manifest_error"; then
  echo "Strict beta verification accepted a manifest with an invalid signature" >&2
  exit 1
fi
grep -Fqi 'manifest signature or key identifier is invalid' "$tampered_manifest_error"

mock_curl="$TMP_DIR/mock-curl.sh"
cat >"$mock_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$EASYSPLAT_TEST_CURL_LOG"
output=""
previous=""
for argument in "$@"; do
  case "$argument" in
    -H|-H?*|--header|--header=*|-u|-u?*|--user|--user=*|--netrc|--netrc-*|--oauth2-bearer|--oauth2-bearer=*)
      echo "Manifest request supplied authentication material." >&2
      exit 3
      ;;
  esac
  if [ "$previous" = "--output" ]; then
    output="$argument"
  fi
  previous="$argument"
done
test -n "$output"
test "${!#}" = "$EASYSPLAT_TEST_EXPECTED_MANIFEST_URL"
case "$EASYSPLAT_TEST_CURL_MODE" in
  missing)
    printf '404'
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
    ;;
  mismatch)
    printf '%s' '{"different":true}' >"$output"
    printf '200'
    ;;
  oversize)
    dd if=/dev/zero of="$output" bs=16777217 count=1 2>/dev/null
    printf '200'
    ;;
  *) exit 4 ;;
esac
EOF
chmod +x "$mock_curl"
curl_log="$TMP_DIR/release-verifier-curl.log"
remote_cache="$TMP_DIR/release-verifier-remote-cache"
mkdir -p "$remote_cache"
run_strict_manifest_probe() {
  local mode=$1
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
    EASYSPLAT_CURL_BIN="$mock_curl" \
    EASYSPLAT_TEST_CURL_LOG="$curl_log" \
    EASYSPLAT_TEST_CURL_MODE="$mode" \
    EASYSPLAT_TEST_EXPECTED_MANIFEST_URL="$manifest_url" \
    run_strict_verifier \
    "$beta_dmg" "$metadata_fixture/manifest.json" \
    "$remote_cache" "$remote_cache" "$repository_runner"
}
missing_remote_manifest_error="$TMP_DIR/release-verifier-remote-404.stderr"
if run_strict_manifest_probe missing >/dev/null 2>"$missing_remote_manifest_error"; then
  echo "Strict beta verification accepted a missing published manifest" >&2
  exit 1
fi
grep -Fqi 'Published toolchain manifest HTTPS GET failed (HTTP 404)' "$missing_remote_manifest_error"
grep -Fq -- '--disable' "$curl_log"
grep -Fq -- '--proto =https' "$curl_log"
grep -Fq -- '--max-filesize 16777216' "$curl_log"
grep -Fq "$manifest_url" "$curl_log"

mismatched_remote_manifest_error="$TMP_DIR/release-verifier-remote-mismatch.stderr"
if run_strict_manifest_probe mismatch >/dev/null 2>"$mismatched_remote_manifest_error"; then
  echo "Strict beta verification accepted different published manifest bytes" >&2
  exit 1
fi
grep -Fqi 'bytes differ from the locally verified signed manifest' "$mismatched_remote_manifest_error"

oversized_remote_manifest_error="$TMP_DIR/release-verifier-remote-oversize.stderr"
if run_strict_manifest_probe oversize >/dev/null 2>"$oversized_remote_manifest_error"; then
  echo "Strict beta verification accepted a published manifest larger than 16 MiB" >&2
  exit 1
fi
grep -Fqi 'exceeds the 16 MiB release limit' "$oversized_remote_manifest_error"
grep -q '^attach ' "$hdiutil_log"
grep -q '^detach ' "$hdiutil_log"

grep -Fq 'detailProfile: .balanced,' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'resourcePolicy: .automatic,' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'option == "--allow-insecure-loopback-http"' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'allowInsecureLoopbackHTTP: arguments.allowInsecureLoopbackHTTP' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
if rg -n 'detailProfile: \.fast|resourcePolicy: \.conserveMemory' \
  "$ROOT/Tools/ReleaseVerifier/main.swift" >/dev/null; then
  echo "Release verifier still exercises a reduced profile instead of the app default." >&2
  exit 1
fi

app_workflow="$ROOT/.github/workflows/release-app.yml"
grep -Fq 'workflow_dispatch:' "$app_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-release, easysplat-ephemeral]' "$app_workflow"
grep -Fq 'runs-on: macos-15' "$app_workflow"
grep -Fq 'test "$(uname -m)" = "arm64"' "$app_workflow"
grep -Fq 'environment: public-beta-release' "$app_workflow"
grep -Fq 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$app_workflow"
grep -Fq 'uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1' "$app_workflow"
grep -Fq 'python-version: "3.12"' "$app_workflow"
if grep -Fq 'softprops/action-gh-release' "$app_workflow"; then
  echo "App release workflow restored an unaudited release action." >&2
  exit 1
fi
grep -Fq 'CURRENT_HEAD="$(gh api -H "X-GitHub-Api-Version: 2026-03-10" "repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH" --jq .sha)"' "$app_workflow"
grep -Fq 'test "$GITHUB_SHA" = "$CURRENT_HEAD"' "$app_workflow"
grep -Fq -- '--prerelease' "$app_workflow"
grep -Fq 'scripts/release/verify_beta.sh' "$app_workflow"
grep -Fq 'scripts/release/verify_ui.sh' "$app_workflow"
grep -Fq -- '--manifest-url "$BASE_URL/manifest.json"' "$app_workflow"
grep -Fq -- '--core-artifact-url "$BASE_URL/toolchain-macos-arm64-$TOOLCHAIN_VERSION-core.zip"' "$app_workflow"
grep -Fq -- '--da3-base-artifact-url "$BASE_URL/toolchain-geometry-da3-base-$TOOLCHAIN_VERSION.zip"' "$app_workflow"
grep -Fq -- '--da3-small-artifact-url "$BASE_URL/toolchain-geometry-da3-small-$TOOLCHAIN_VERSION.zip"' "$app_workflow"
grep -Fq -- '--use-existing-toolchain' "$app_workflow"
grep -Fq 'EASYSPLAT_ISOLATED_UI_RUNNER: "1"' "$app_workflow"
grep -Fq 'name: easysplat-ui-${{ github.sha }}' "$app_workflow"
grep -Fq 'rm -rf "$OUTPUT_DIR/results" "$OUTPUT_DIR/screenshots"' "$ROOT/scripts/release/verify_ui.sh"
grep -Fq 'captureWorkspace(' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq '            .result,' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq '            .failure,' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'captureViewerShortcutEvidence(' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'normalizedPixelDistance:' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'metadata.width == expectedWidth' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/UIHarnessSuiteValidator.swift"
grep -Fq 'workspaceHashes[key]?.count == UIVerificationWorkspace.allCases.count' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/UIHarnessSuiteValidator.swift"
grep -Fq 'Required accessibility element \(required) does not have a visible frame contained by the window.' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/AccessibilityAudit.swift"
grep -Fq 'pressAdvertisedAccessibilityAction(identifier: readyRowIdentifier)' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'pressAndCancelSavePanel(' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'pressAndCancelConfirmation(' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'keeping technical failure details collapsed' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'UIVerificationWorkspace.allCases.count' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/UIHarnessSuiteValidator.swift"
grep -Fq 'scripts/benchmark/aggregate_evidence.py' "$app_workflow"
grep -Fq 'scripts/release/verify_publication_bundle.py create-build-closure' "$app_workflow"
grep -Fq 'scripts/release/verify_publication_bundle.py verify-build' "$app_workflow"
grep -Fq 'benchmark_run_id:' "$app_workflow"
grep -Fq 'artifact-ids: ${{ steps.benchmark-identity.outputs.artifact_id }}' "$app_workflow"
grep -Fq 'artifact-ids: ${{ needs.build-and-test.outputs.benchmark_artifact_id }}' "$app_workflow"
grep -Fq 'secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN' "$app_workflow"
grep -Fq 'repos/$GITHUB_REPOSITORY/immutable-releases' "$app_workflow"
if grep -Fq 'EASYSPLAT_IMMUTABLE_RELEASES_ENABLED' "$app_workflow"; then
  echo "App release workflow trusts a variable instead of the live immutable-release policy." >&2
  exit 1
fi
if grep -Fq 'BENCHMARK_EVIDENCE_PRIVATE_KEY_BASE64' "$app_workflow"; then
  echo "App release workflow must never receive the benchmark private key." >&2
  exit 1
fi
python3 - "$app_workflow" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
build_marker = "  build-and-test:"
verify_marker = "  verify-publication:"
publish_marker = "  publish:"
assert workflow.index(build_marker) < workflow.index(verify_marker) < workflow.index(publish_marker)
build_block = workflow.split(build_marker, 1)[1].split(verify_marker, 1)[0]
verify_block = workflow.split(verify_marker, 1)[1].split(publish_marker, 1)[0]
publish_block = workflow.split(publish_marker, 1)[1]
assert "environment:" not in build_block
assert "contents: write" not in build_block
assert "EASYSPLAT_RELEASE_ADMIN_TOKEN" not in build_block
assert "runs-on: macos-15" in verify_block
assert "environment:" not in verify_block
assert "contents: write" not in verify_block
assert "EASYSPLAT_RELEASE_ADMIN_TOKEN" not in verify_block
assert "scripts/release/verify_beta.sh" not in verify_block
assert "scripts/release/verify_ui.sh" not in verify_block
assert "contents: write" in publish_block
assert "environment: public-beta-release" in publish_block
assert publish_block.count("secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN") == 1
assert "actions/checkout@" not in publish_block
assert "scripts/" not in publish_block
assert workflow.count("contents: write") == 1
assert workflow.count("secrets.BENCHMARK_EVIDENCE_PRIVATE_KEY_BASE64") == 0
assert "build_artifact_id:" in workflow and "build_artifact_digest:" in workflow
assert "publication_artifact_id:" in workflow and "publication_artifact_digest:" in workflow
assert "touch \"$RUNNER_TEMP/easysplat-draft-created\"" in publish_block
assert "Remove an incomplete release" in publish_block
expected_assets = (
    "EasySplat-$VERSION-unsigned.dmg",
    "EasySplat-$VERSION-unsigned.dmg.sha256",
    "EasySplat-$VERSION.provenance.json",
    "EasySplat-$VERSION.spdx.json",
    "EasySplat-$VERSION-licenses.zip",
    "EasySplat-$VERSION-dSYM.zip",
    "EasySplat-$VERSION-benchmark.json",
)
for asset in expected_assets:
    assert asset in publish_block, f"publication allowlist omits {asset}"
assert "Validate inert publication manifest" in publish_block
assert "Verify remote draft assets without executing them" in publish_block
assert "Publish and confirm immutable prerelease" in publish_block
PY
if rg -n '^  push:|uses: [^ ]+@(v[0-9]+|main|master)$' "$app_workflow" >/dev/null; then
  echo "App release workflow must be manual and pin actions to commit SHAs" >&2
  exit 1
fi

benchmark_workflow="$ROOT/.github/workflows/benchmark-release.yml"
grep -Fq 'workflow_dispatch:' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-reference, easysplat-ephemeral]' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-constrained, easysplat-ephemeral]' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-8gb, easysplat-ephemeral]' "$benchmark_workflow"
grep -Fq 'environment: benchmark-release' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/run_lane.py' "$benchmark_workflow"
grep -Fq -- '--lane reference_m4_max' "$benchmark_workflow"
grep -Fq -- '--lane constrained_14_16gb' "$benchmark_workflow"
grep -Fq -- '--lane eight_gb_fast' "$benchmark_workflow"
grep -Fq 'runs-on: macos-15' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/prepare_evidence.py' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/aggregate_evidence.py' "$benchmark_workflow"
if rg -n 'BENCHMARK_EVIDENCE_(PRIVATE|PUBLIC)_KEY|benchmark-evidence-signing|seal_evidence\.py|signing-requirements|benchmark/public_key_ed25519\.txt|--private-key-stdin|--sealed-root' "$benchmark_workflow" >/dev/null; then
  echo "Benchmark workflow contains a misleading signing authority." >&2
  exit 1
fi
grep -Fq 'EASYSPLAT_BENCHMARK_REFERENCE_RUNNER_SHA256' "$benchmark_workflow"
grep -Fq 'EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER_SHA256' "$benchmark_workflow"
grep -Fq 'EASYSPLAT_BENCHMARK_8GB_RUNNER_SHA256' "$benchmark_workflow"
grep -Fq -- '--runner-identity "reference_m4_max=$REFERENCE_RUNNER_SHA256"' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.prepare.outputs.requests_artifact_id }}' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.derive-reference.outputs.prepared_artifact_id }}' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.derive-constrained.outputs.prepared_artifact_id }}' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.derive-eight-gb.outputs.prepared_artifact_id }}' "$benchmark_workflow"
grep -Fq '${{ needs.derive-reference.outputs.prepared_artifact_digest }}' "$benchmark_workflow"
grep -Fq '${{ needs.derive-constrained.outputs.prepared_artifact_digest }}' "$benchmark_workflow"
grep -Fq '${{ needs.derive-eight-gb.outputs.prepared_artifact_digest }}' "$benchmark_workflow"
grep -Fq 'actions/artifacts/$artifact_id' "$benchmark_workflow"
test "$(grep -Fc -- '--prepared-root' "$benchmark_workflow")" -eq 3
grep -Fq 'name: easysplat-benchmark-${{ github.sha }}' "$benchmark_workflow"
grep -Fq 'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' "$benchmark_workflow"
grep -Fq 'uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c' "$benchmark_workflow"
if rg -n '^  (push|pull_request|pull_request_target):|uses: [^ ]+@(v[0-9]+|main|master)$' "$benchmark_workflow" >/dev/null; then
  echo "Release benchmark workflow must be manual and pin actions to commit SHAs" >&2
  exit 1
fi

grep -Fq -- '--app-version)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--toolchain-version)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--manifest-url)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--core-artifact-url)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--da3-base-artifact-url)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--da3-small-artifact-url)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--use-existing-toolchain)' "$ROOT/scripts/release/build_dmg.sh"
if grep -Fq -- '    --version)' "$ROOT/scripts/release/build_dmg.sh"; then
  echo "build_dmg.sh still accepts the ambiguous legacy --version option" >&2
  exit 1
fi
grep -Fq -- '--version "$APP_VERSION"' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'DMG_PATH="$OUT_DIR/EasySplat-$APP_VERSION-unsigned.dmg"' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'requires explicit HTTPS manifest and component URLs' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'requires --use-existing-toolchain' "$ROOT/scripts/release/build_dmg.sh"
if rg -n 'http://localhost|generate-keypair|private_key_ed25519|--private-key-file|scripts/toolchain/(build_|package_toolchain)|notarytool|stapler|EASYSPLAT_DEVELOPER_ID_APPLICATION|EASYSPLAT_NOTARY_KEYCHAIN_PROFILE' \
  "$ROOT/scripts/release/build_dmg.sh" >/dev/null; then
  echo "build_dmg.sh retains a local toolchain build, release key, or production-signing path" >&2
  exit 1
fi
metadata_verify_line="$(grep -n -m1 'generate_release_metadata.py" verify-toolchain' "$ROOT/scripts/release/build_dmg.sh" | cut -d: -f1)"
app_build_line="$(grep -n -m1 'build_app.sh"' "$ROOT/scripts/release/build_dmg.sh" | cut -d: -f1)"
test -n "$metadata_verify_line"
test "$metadata_verify_line" -lt "$app_build_line"
grep -q 'scripts/toolchain/build_msplat.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'scripts/toolchain/build_da3_mps.sh' "$ROOT/.github/workflows/toolchain-build.yml"
toolchain_workflow="$ROOT/.github/workflows/toolchain-build.yml"
if rg -n 'Homebrew|verify_homebrew_lock|build_suitesparse\.sh' \
  "$toolchain_workflow" "$ROOT/scripts/run.sh" >/dev/null; then
  echo "Release and local launch paths still require Homebrew or the retired SuiteSparse builder." >&2
  exit 1
fi
python3 - "$toolchain_workflow" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
builders = [
    "build_colmap_support.sh",
    "build_ceres.sh",
    "build_openimageio.sh",
    "build_colmap.sh",
    "build_msplat.sh",
    "build_da3_mps.sh",
    "package_toolchain.sh",
]
positions = [workflow.index(f"scripts/toolchain/{builder}") for builder in builders]
assert positions == sorted(positions), "native toolchain builders run out of dependency order"
PY

assert_dirty_toolchain_source_rejected() {
  local relative_path="$1"
  local fixture_name="${relative_path//\//-}"
  local fixture="$TMP_DIR/dirty-toolchain-source-$fixture_name"
  local error_path="$fixture/package.stderr"

  mkdir -p "$fixture/scripts/toolchain" "$(dirname "$fixture/$relative_path")"
  install -m 0755 \
    "$ROOT/scripts/toolchain/package_toolchain.sh" \
    "$fixture/scripts/toolchain/package_toolchain.sh"
  printf '%s\n' fixture >"$fixture/$relative_path"
  git -C "$fixture" init -q
  git -C "$fixture" add .
  git -C "$fixture" \
    -c user.name='EasySplat release test' \
    -c user.email='release-test@easysplat.invalid' \
    commit -qm 'test fixture'

  printf '%s\n' dirty >>"$fixture/$relative_path"
  if "$fixture/scripts/toolchain/package_toolchain.sh" --version 2.0.0 \
    >/dev/null 2>"$error_path"; then
    echo "Toolchain packaging accepted dirty source input: $relative_path" >&2
    exit 1
  fi
  if ! grep -Fq 'Toolchain source inputs must be committed before release packaging.' \
    "$error_path"; then
    cat "$error_path" >&2
    echo "Toolchain packaging did not reject dirty source input: $relative_path" >&2
    exit 1
  fi
  grep -Fq "$relative_path" "$error_path"
}

for dirty_toolchain_source in \
  Tools/NativeColmap/local_vocab_retriever.cc \
  scripts/ci/generate_msplat_sparse_fixtures.py \
  scripts/toolchain/da3-model-lock.json \
  scripts/toolchain/safe_extract_source.py \
  scripts/toolchain/atomic_swap_install.py \
  scripts/toolchain/tests/test_colmap_support_builder.py \
  scripts/toolchain/tests/test_ceres_builder.py \
  scripts/toolchain/tests/test_openimageio_builder.py \
  scripts/toolchain/tests/test_native_colmap_retriever.py; do
  assert_dirty_toolchain_source_rejected "$dirty_toolchain_source"
done

grep -Fq 'feature_extractor matches_importer local_vocab_retriever mapper' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'point_triangulator bundle_adjuster model_analyzer image_undistorter model_converter' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Native COLMAP does not expose the exact reviewed command surface.' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$BIN/colmap" "$command" -h' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_frames_ratio' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_max_refinements' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_points_ratio' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_max_refinements' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_max_num_iterations' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_function_tolerance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_function_tolerance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_num_images' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.random_seed' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.min_num_matches' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'returned_neighbor_count' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'minimum_frame_separation' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'max_training_descriptors' "$ROOT/scripts/toolchain/package_toolchain.sh"
if rg -n 'pycolmap|--self-check|EASYSPLAT_REQUIRE_REAL_PYCOLMAP|test_real_pycolmap|easysplat[_-]colmap[_-]bridge|global_mapper' \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "Core packaging retains a Python COLMAP bridge, self-check, or unreviewed command." >&2
  exit 1
fi
for retired_source in \
  "$ROOT/Tools/Da3Sfm/colmap_launcher.c" \
  "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm/colmap_cli.py" \
  "$ROOT/Tools/Da3Sfm/tests/test_colmap_cli.py"; do
  if [ -e "$retired_source" ]; then
    echo "Retired DA3 Python COLMAP bridge source still exists: $retired_source" >&2
    exit 1
  fi
done
if rg -n 'pycolmap|PYCOLMAP|easysplat_colmap|colmap_launcher|colmap_cli\.py|--self-check' \
  "$ROOT/Tools/Da3Sfm/requirements.in" \
  "$ROOT/Tools/Da3Sfm/requirements.txt" \
  "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm" \
  "$ROOT/scripts/toolchain/build_da3_mps.sh" \
  "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "Release runtime retains a retired DA3 Python COLMAP bridge surface." >&2
  exit 1
fi
grep -q 'DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q 'MSPLAT_COMMIT="106499b0a53f82b0c92d013b0861fbebd341b17e"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'MSPLAT_VERSION="1\.1\.3"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'NLOHMANN_JSON_SHA256="04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'NANOFLANN_SHA256="57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'CLI11_SHA256="43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'FETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'FETCHCONTENT_SOURCE_DIR_NANOFLANN' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'FETCHCONTENT_SOURCE_DIR_CLI11' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'promote_install' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'easysplat-train' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'msplat-1.1.3-checkpoint.patch' "$ROOT/scripts/toolchain/build_msplat.sh"
if grep -Eqi 'pip install|python-build-standalone|site-packages|_core\.so|core_extension_path\.txt|(^|[^[:alnum:]])msplat-train' "$ROOT/scripts/toolchain/build_msplat.sh"; then
  echo "Native msplat builder still contains packaged-Python or legacy CLI remnants" >&2
  exit 1
fi
grep -q '^numpy==2\.3\.5$' "$ROOT/Tools/Da3Sfm/requirements.in"
if rg -n 'opencv-python-headless|\bcv2\b' \
  "$ROOT/Tools/Da3Sfm/requirements.in" \
  "$ROOT/Tools/Da3Sfm/requirements.txt" \
  "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "Lean DA3/COLMAP runtime still includes OpenCV." >&2
  exit 1
fi
# This asserts the requirements continuation backslash.
# shellcheck disable=SC1003
grep -q '^numpy==2\.3\.5 \\' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -q -- '--hash=sha256:' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -Fq -- '--require-hashes' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--only-binary=:all:' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--no-binary=antlr4-python3-runtime' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--report "$PIP_INSTALL_REPORT"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'export PYTHONDONTWRITEBYTECODE=1' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q 'rm -rf "$target"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq '/usr/bin/lipo -archs "$binary"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$desc" != *"universal binary"*' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'require_arm64_only_macho "Packaged native file $relative" "$file"' \
  "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '/usr/bin/vtool -show-build "$binary"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq "grep -Fx 'Signature=adhoc'" "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq "'@rpath/libomp.dylib'" "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"@executable_path/../lib"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'validate_arm64_only(source)' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -q 'source_provenance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'pinned-git' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'PYTHON_STANDALONE_SHA256="718a87bf84d81cb81355488ca37be1f66c2252304be2090721016948de96e7ca"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'PYTHON_STANDALONE_FULL_SHA256="ff7e2bb25f1f29067a0663af42b32980b0da295b948238d5e3fc09d2b27228a6"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq '"$DA3_SOURCE/src/depth_anything_3/" "$DA3_VENDOR/src/depth_anything_3/"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
if grep -Fq '"$DA3_SOURCE/" "$DA3_VENDOR/"' "$ROOT/scripts/toolchain/build_da3_mps.sh"; then
  echo "DA3 builder must not package the full upstream tree or streaming submodules." >&2
  exit 1
fi
grep -Fq 'test ! -e "$DA3_VENDOR/da3_streaming"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'install -m 0755 "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0755 "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib" "$LIB/libomp.dylib"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$COLMAP_INSTALL/build_info.json" "$PROVENANCE/colmap.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$COLMAP_SUPPORT_INSTALL/build_info.json" "$PROVENANCE/colmap-support.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$CERES_INSTALL/build_info.json" "$PROVENANCE/ceres.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$OPENIMAGEIO_INSTALL/build_info.json" "$PROVENANCE/openimageio.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'inputs.get("dependency_receipt_sha256")' "$ROOT/scripts/toolchain/package_toolchain.sh"
if grep -Fq 'dependency_receipt_canonical_sha256' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging still expects the superseded canonical dependency receipt field." >&2
  exit 1
fi
if grep -Fq 'EIGEN_INSTALL' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging still expects a separate Eigen prefix instead of the Ceres-bound dependency tree." >&2
  exit 1
fi
grep -Fq 'find "$OUT/da3_mps/python" -type f -name '\''*.pyc'\'' -delete' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'find "$OUT/da3_mps/python" -type d -name '\''__pycache__'\'' -empty -delete' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '/usr/bin/codesign --verify --strict "$file"' "$ROOT/scripts/toolchain/package_toolchain.sh"
if grep -Fq '/usr/bin/codesign --force' "$ROOT/scripts/toolchain/package_toolchain.sh" || \
   grep -Fq 'lipo -thin' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging mutates signed wheel Mach-Os and invalidates RECORD hashes." >&2
  exit 1
fi
receipt_line="$(grep -n -m1 '^validate_native_receipts$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
launch_line="$(grep -n -m1 '^validate_native_colmap_cli$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
native_line="$(grep -n -m1 '^validate_packaged_native_files$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
supply_line="$(grep -n -m1 '^"$SUPPLY_CHAIN_GENERATOR" --toolchain-root' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
test "$receipt_line" -lt "$launch_line"
test "$launch_line" -lt "$native_line"
test "$native_line" -lt "$supply_line"
grep -Fq 'REPRODUCIBLE_ZIP="$ROOT/scripts/toolchain/create_reproducible_zip.py"' \
  "$ROOT/scripts/toolchain/package_toolchain.sh"
test "$(grep -Fc 'python3 "$REPRODUCIBLE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh")" -eq 3
if grep -Fq 'zip -q -r' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging still uses host-metadata-dependent ZIP construction." >&2
  exit 1
fi
grep -Fq -- '--output "$CORE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--output "$DA3_BASE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "da3_mps/models/DA3-BASE"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--output "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "da3_mps/models/DA3-SMALL"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'rm -rf "$target/.cache"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'assert_exact_da3_model_payload "$DA3_ROOT/models/$model"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_RELEASE_ASSET_BYTES=2147483648' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_CORE_DOWNLOAD_BYTES=2500000000' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_FULL_DOWNLOAD_BYTES=6000000000' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$CORE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$DA3_BASE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_download_closure_size "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "supply-chain/components.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"bin/colmap": "colmap"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"lib/libomp.dylib": "colmap-support:libomp"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"easysplat-da3-runner"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
if rg -n 'homebrewBuild|SUITESPARSE_INSTALL|colmap:poissonrecon|easysplat[_-]colmap[_-]bridge' \
  "$ROOT/scripts/toolchain/package_toolchain.sh" \
  "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py" >/dev/null; then
  echo "Lean native toolchain packaging references a forbidden closure." >&2
  exit 1
fi
grep -Fq -- '--da3-base-zip "$DA3_BASE_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq -- '--da3-small-zip "$DA3_SMALL_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq 'ensure_msplat_bundle' "$ROOT/scripts/run.sh"
grep -Fq 'ensure_da3_mps_bundle' "$ROOT/scripts/run.sh"

workflow="$ROOT/.github/workflows/toolchain-build.yml"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-ephemeral]' "$workflow"
grep -Fq 'runs-on: macos-15' "$workflow"
grep -Fq 'if: github.ref == format(' "$workflow"
grep -Fq 'fetch-depth: 0' "$workflow"
grep -Fq 'test "$GITHUB_SHA" = "$(gh api -H "X-GitHub-Api-Version: 2026-03-10" "repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH" --jq .sha)"' "$workflow"
grep -Fq 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$workflow"
grep -Fq 'name: toolchain-components-${{ steps.release.outputs.version }}' "$workflow"
grep -Fq 'name: toolchain-signing-request-${{ inputs.version }}' "$workflow"
grep -Fq 'artifact-ids: ${{ needs.build.outputs.artifact_id }}' "$workflow"
grep -Fq 'actions/artifacts/$ARTIFACT_ID' "$workflow"
grep -Fq 'ManifestTool prepare-release' "$workflow"
grep -Fq -- '--da3-base-zip "$BUILD/toolchain-geometry-da3-base-$VERSION.zip"' "$workflow"
grep -Fq -- '--da3-small-zip "$BUILD/toolchain-geometry-da3-small-$VERSION.zip"' "$workflow"
grep -Fq -- '--app-version-minimum "$APP_VERSION_MINIMUM"' "$workflow"
grep -Fq -- '--app-version-maximum-exclusive "$APP_VERSION_MAXIMUM_EXCLUSIVE"' "$workflow"
if rg -n '^[[:space:]]+environment:|contents: write|\$\{\{ secrets\.|sign-release|gh release|TOOLCHAIN_PRIVATE_KEY|private[_-]key' "$workflow" >/dev/null; then
  echo "Source toolchain workflow can access a secret, sign, or publish." >&2
  exit 1
fi
if rg -n -- '--models-(zip|url)|MODELS_(ZIP|URL)|toolchain-macos-arm64-.*-models\.zip' \
  "$ROOT/scripts/release/build_dmg.sh" \
  "$ROOT/scripts/run.sh" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" \
  "$workflow" >/dev/null; then
  echo "Release paths still reference the removed combined models component" >&2
  exit 1
fi
if rg -n 'uses: [^ ]+@(v[0-9]+|main|master)$' "$workflow" >/dev/null; then
  echo "Toolchain workflow actions must be pinned to full commit SHAs" >&2
  exit 1
fi
if rg -n '^  push:|toolchain-v\*' "$workflow" >/dev/null; then
  echo "Toolchain release workflow must run manually from protected main, not writable tags" >&2
  exit 1
fi

legacy_runtime_pattern='brush|mapanything|fastvggt|vggt|glomap'
for path in \
  "$ROOT/scripts/toolchain/package_toolchain.sh" \
  "$ROOT/scripts/run.sh" \
  "$ROOT/scripts/release/build_dmg.sh" \
  "$ROOT/.github/workflows/toolchain-build.yml"; do
  if rg -n -i "$legacy_runtime_pattern" "$path" >/dev/null; then
    echo "Release path still references a removed runtime: $path" >&2
    exit 1
  fi
done

msplat_validator="$ROOT/scripts/toolchain/validate_native_msplat.sh"
[ -x "$msplat_validator" ] || {
  echo "Missing executable native msplat validator: $msplat_validator" >&2
  exit 1
}

grep -Fq '"$MSPLAT_VALIDATOR" --source "$MSPLAT_INSTALL/msplat"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --packaged "$OUT"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "msplat/build_info.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "msplat/LICENSE"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'find "$ROOT/Tools/MsplatNative" -type f -newer "$CORE_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq 'find "$ROOT/Tools/MsplatNative" -type f -newer "$MSPLAT_BUNDLE/build_info.json"' "$ROOT/scripts/run.sh"
grep -Fq '[ "$MSPLAT_BUILD" -nt "$MSPLAT_BUNDLE/build_info.json" ]' "$ROOT/scripts/run.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --archive "$CORE_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --source "$MSPLAT_BUNDLE"' "$ROOT/scripts/run.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --packaged "$root"' "$ROOT/scripts/run.sh"

for script in "$ROOT/scripts/toolchain/package_toolchain.sh" "$ROOT/scripts/run.sh"; do
  if grep -Eqi 'site-packages/msplat|_core\.so|core_extension_path\.txt|msplat/python|(^|[^[:alnum:]-])msplat-train([^[:alnum:]-]|$)' "$script"; then
    echo "$script still contains packaged-Python or legacy msplat layout assumptions" >&2
    exit 1
  fi
done

if grep -E '^[A-Z0-9_]+_URL="http://' "$ROOT/scripts/toolchain/build_msplat.sh"; then
  echo "Native msplat dependency URLs must use HTTPS" >&2
  exit 1
fi

msplat_source="$ROOT/Toolchains/build/msplat/install/msplat"
if [ -d "$msplat_source" ] && \
   "$msplat_validator" --source "$msplat_source" >/dev/null 2>&1; then

  packaged_fixture="$TMP_DIR/native-msplat-packaged"
  mkdir -p "$packaged_fixture/bin" "$packaged_fixture/msplat"
  cp "$msplat_source/bin/easysplat-train" "$packaged_fixture/bin/easysplat-train"
  cp "$msplat_source/bin/default.metallib" "$packaged_fixture/bin/default.metallib"
  cp "$msplat_source/build_info.json" "$packaged_fixture/msplat/build_info.json"
  cp "$msplat_source/LICENSE" "$packaged_fixture/msplat/LICENSE"
  chmod +x "$packaged_fixture/bin/easysplat-train"
  "$msplat_validator" --packaged "$packaged_fixture"

  archive_fixture="$TMP_DIR/native-msplat.zip"
  (cd "$packaged_fixture" && zip -q "$archive_fixture" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  "$msplat_validator" --archive "$archive_fixture"

  tampered_fixture="$TMP_DIR/native-msplat-tampered"
  cp -R "$packaged_fixture" "$tampered_fixture"
  printf 'tamper\n' >>"$tampered_fixture/bin/default.metallib"
  if "$msplat_validator" --packaged "$tampered_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a tampered metallib" >&2
    exit 1
  fi

  license_fixture="$TMP_DIR/native-msplat-license-tampered"
  cp -R "$packaged_fixture" "$license_fixture"
  printf 'tamper\n' >>"$license_fixture/msplat/LICENSE"
  if "$msplat_validator" --packaged "$license_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a tampered upstream license" >&2
    exit 1
  fi

  tampered_archive="$TMP_DIR/native-msplat-tampered.zip"
  (cd "$tampered_fixture" && zip -q "$tampered_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  if "$msplat_validator" --archive "$tampered_archive" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a tampered cached archive" >&2
    exit 1
  fi

  extra_fixture="$TMP_DIR/native-msplat-extra"
  cp -R "$packaged_fixture" "$extra_fixture"
  : >"$extra_fixture/msplat/unexpected.txt"
  if "$msplat_validator" --packaged "$extra_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted an unexpected file" >&2
    exit 1
  fi

  symlink_fixture="$TMP_DIR/native-msplat-symlink"
  cp -R "$packaged_fixture" "$symlink_fixture"
  rm "$symlink_fixture/msplat/LICENSE"
  ln -s "$msplat_source/LICENSE" "$symlink_fixture/msplat/LICENSE"
  if "$msplat_validator" --packaged "$symlink_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a symlink" >&2
    exit 1
  fi

  legacy_fixture="$TMP_DIR/native-msplat-legacy"
  cp -R "$packaged_fixture" "$legacy_fixture"
  mkdir -p "$legacy_fixture/msplat/python/bin"
  : >"$legacy_fixture/msplat/python/bin/python3"
  if "$msplat_validator" --packaged "$legacy_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted the legacy Python layout" >&2
    exit 1
  fi

  legacy_archive="$TMP_DIR/native-msplat-legacy.zip"
  (cd "$legacy_fixture" && zip -q "$legacy_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE \
    msplat/python/bin/python3)
  if "$msplat_validator" --archive "$legacy_archive" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a legacy cached archive" >&2
    exit 1
  fi

  provenance_fixture="$TMP_DIR/native-msplat-unexpected-provenance"
  cp -R "$packaged_fixture" "$provenance_fixture"
  python3 - "$provenance_fixture/msplat/build_info.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["unexpected"] = "not allowed"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if "$msplat_validator" --packaged "$provenance_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted unexpected provenance keys" >&2
    exit 1
  fi

  overlay_fixture="$TMP_DIR/native-msplat-overlay-tampered"
  cp -R "$packaged_fixture" "$overlay_fixture"
  python3 - "$overlay_fixture/msplat/build_info.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["overlay_sha256"] = "d" * 64
payload["patch_sha256"] = "e" * 64
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if "$msplat_validator" --packaged "$overlay_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted unpinned overlay provenance" >&2
    exit 1
  fi

  partial_archive="$TMP_DIR/native-msplat-partial.zip"
  (cd "$packaged_fixture" && zip -q "$partial_archive" \
    bin/easysplat-train msplat/build_info.json msplat/LICENSE)
  if "$msplat_validator" --archive "$partial_archive" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a partial cached archive" >&2
    exit 1
  fi

  oversized_fixture="$TMP_DIR/native-msplat-oversized"
  cp -R "$packaged_fixture" "$oversized_fixture"
  dd if=/dev/zero of="$oversized_fixture/bin/default.metallib" bs=1048576 count=17 2>/dev/null
  oversized_archive="$TMP_DIR/native-msplat-oversized.zip"
  (cd "$oversized_fixture" && zip -q "$oversized_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  oversized_error="$TMP_DIR/native-msplat-oversized.stderr"
  if "$msplat_validator" --archive "$oversized_archive" >/dev/null 2>"$oversized_error"; then
    echo "Native msplat validator accepted an oversized required entry" >&2
    exit 1
  fi
  grep -qi 'size limit' "$oversized_error" || {
    echo "Oversized archive was not rejected before extraction and hashing" >&2
    exit 1
  }

  compressed_fixture="$TMP_DIR/native-msplat-compressed"
  cp -R "$packaged_fixture" "$compressed_fixture"
  dd if=/dev/zero of="$compressed_fixture/bin/default.metallib" bs=1048576 count=2 2>/dev/null
  compressed_archive="$TMP_DIR/native-msplat-compressed.zip"
  (cd "$compressed_fixture" && zip -q "$compressed_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  compressed_error="$TMP_DIR/native-msplat-compressed.stderr"
  if "$msplat_validator" --archive "$compressed_archive" >/dev/null 2>"$compressed_error"; then
    echo "Native msplat validator accepted a high-ratio compressed entry" >&2
    exit 1
  fi
  grep -qi 'compression ratio' "$compressed_error" || {
    echo "Compressed archive was not rejected before extraction and hashing" >&2
    exit 1
  }

  unrelated_bomb_fixture="$TMP_DIR/native-msplat-unrelated-bomb"
  cp -R "$packaged_fixture" "$unrelated_bomb_fixture"
  mkdir -p "$unrelated_bomb_fixture/da3_mps/vendor"
  dd if=/dev/zero of="$unrelated_bomb_fixture/da3_mps/vendor/bomb.bin" \
    bs=1048576 count=32 2>/dev/null
  unrelated_bomb_archive="$TMP_DIR/native-msplat-unrelated-bomb.zip"
  (cd "$unrelated_bomb_fixture" && zip -qr "$unrelated_bomb_archive" .)
  unrelated_bomb_error="$TMP_DIR/native-msplat-unrelated-bomb.stderr"
  if "$msplat_validator" --archive "$unrelated_bomb_archive" \
    >/dev/null 2>"$unrelated_bomb_error"; then
    echo "Native msplat validator accepted a compressed bomb outside its own payload" >&2
    exit 1
  fi
  grep -qi 'compression ratio' "$unrelated_bomb_error" || {
    echo "Unrelated compressed bomb was not rejected during whole-archive preflight" >&2
    exit 1
  }
fi

if [ -e "$app_bundle/Contents/lib/Sparkle.framework" ]; then
  echo "Release app unexpectedly bundled Sparkle.framework" >&2
  exit 1
fi

build_wait_path="$TMP_DIR/build-app-lock"
first_build_log="$TMP_DIR/first-build.log"
EASYSPLAT_TEST_BUILD_WAIT_PATH="$build_wait_path" \
EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "0.2.0-beta.1" \
  --unsigned-beta >"$first_build_log" 2>&1 &
first_build_pid=$!

for _ in {1..200}; do
  [ -e "$build_wait_path.ready" ] && break
  sleep 0.05
done
if [ ! -e "$build_wait_path.ready" ]; then
  kill "$first_build_pid" 2>/dev/null || true
  wait "$first_build_pid" 2>/dev/null || true
  echo "Timed out waiting for the first app build" >&2
  exit 1
fi

second_build_error="$TMP_DIR/second-build.stderr"
second_build_succeeded=0
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "0.2.0-beta.1" \
  --unsigned-beta >/dev/null 2>"$second_build_error"; then
  second_build_succeeded=1
fi
: >"$build_wait_path.release"
wait "$first_build_pid"

if [ "$second_build_succeeded" -eq 1 ]; then
  echo "Concurrent app builds were allowed to corrupt shared release output" >&2
  exit 1
fi
if ! grep -Fqi 'app build is already in progress' "$second_build_error"; then
  echo "Concurrent-build rejection did not report the active build lock" >&2
  cat "$second_build_error" >&2
  exit 1
fi
