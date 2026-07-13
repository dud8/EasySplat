#!/usr/bin/env bash
# Source-contract assertions intentionally match literal shell and Actions expressions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py" "$TMP_DIR" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("supply_chain", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.homebrew_component_id("xz") == "homebrew:xz:liblzma"
assert module.homebrew_component_id("zstd") == "homebrew:zstd:libzstd"
assert module.component_build_command("colmap", {}) == "./scripts/toolchain/build_colmap.sh"
assert module.component_build_command("model:da3-base", {}) == "./scripts/toolchain/build_da3_mps.sh"
assert module.component_build_command("python:numpy", {}) == "./scripts/toolchain/build_da3_mps.sh"
assert module.component_build_command("homebrew:xz:liblzma", {"formula": "xz"}) == \
    "brew install --build-from-source xz"
try:
    module.component_build_command("unreviewed-component", {})
except SystemExit:
    pass
else:
    raise AssertionError("unreviewed component received an implicit build command")
assert module.homebrew_runtime_license("xz", "0BSD AND GPL-2.0-or-later") == "0BSD"
assert module.homebrew_runtime_license(
    "zstd",
    "(BSD-3-Clause OR GPL-2.0-only) AND BSD-2-Clause AND MIT",
) == "BSD-3-Clause AND MIT"
for component_id in (
    "colmap",
    "openimageio",
    "openimageio:fmt",
    "openimageio:robin-map",
    "openimageio:pugixml",
    "colmap:poselib",
    "colmap:faiss",
    "colmap:poissonrecon",
    "colmap:vlfeat",
):
    expected = module.PINNED_RECEIPTS[component_id]
    module.require_pinned_receipt(dict(expected), expected, component_id)
    tampered = dict(expected)
    first_key = next(iter(tampered))
    tampered[first_key] = "tampered"
    try:
        module.require_pinned_receipt(tampered, expected, component_id)
    except SystemExit:
        pass
    else:
        raise AssertionError(f"accepted tampered pinned receipt: {component_id}")
pugixml = module.PINNED_RECEIPTS["openimageio:pugixml"]
assert pugixml["source_commit"] == "f32bf6e6f8de38ab6d197a72fd72366b66fd30a3"
assert pugixml["source_tree_sha256"] == "316f7a67b75417c9cad506a4e14fac8488528b24e66e9fbf7cbe4fe88bbd1ed8"
assert pugixml["upstream_source_commit"] == "314baf6605143f1e837209008f490e8559529e1c"
assert pugixml["upstream_source_tree_sha256"] == "fbd994ba2b46894d2a643f6fc19acb412554e297a0880666f402219b6aaf8864"
assert module.PINNED_RECEIPTS["colmap:poissonrecon"]["source_tree_sha256"] == \
    "7aacb04853a3fece0d6b2eb3bbaaffe3c2014467ae3c73750c5dba1c6b2e835e"
assert module.PINNED_RECEIPTS["colmap:vlfeat"]["source_tree_sha256"] == \
    "c1f3020a96d78e2f105aafa63f41b14cdf0a3886196f42f2dbc9c817ccd1d61e"
module.validate_homebrew_runtime_member("xz", "lib/liblzma.5.dylib")
module.validate_homebrew_runtime_member("zstd", "lib/libzstd.1.dylib")
for formula, path in (("xz", "bin/xz"), ("zstd", "bin/zstd")):
    try:
        module.validate_homebrew_runtime_member(formula, path)
    except SystemExit:
        pass
    else:
        raise AssertionError(f"accepted forbidden {formula} payload: {path}")
try:
    module.normalize_license("GPL-3.0-only")
except SystemExit:
    pass
else:
    raise AssertionError("generic GPL rejection was weakened")

fixture = Path(sys.argv[2]) / "materialized-symlink"
root = fixture / "root"
root.mkdir(parents=True)
target = root / "python3.13"
target.write_bytes(b"python-runtime")
alias = root / "python3"
alias.symlink_to("python3.13")
assert module.materialized_source(alias, root) == target.resolve()
outside = fixture / "outside"
outside.write_bytes(b"outside")
escaping = root / "escaping"
escaping.symlink_to(outside)
try:
    module.materialized_source(escaping, root)
except SystemExit:
    pass
else:
    raise AssertionError("accepted a symlink that escapes the toolchain")
PY

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
printf '%s' 'PUBLIC_KEY_TEST_VALUE' >"$public_key_path"
xcodebuild_log="$TMP_DIR/xcodebuild.log"

insecure_app_url_error="$TMP_DIR/insecure-app-url.stderr"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
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

app_bundle="$ROOT/build/Export/EasySplat.app"
resources_dir="$app_bundle/Contents/Resources"

test "$(cat "$ROOT/EasySplatApp/Resources/toolchain_manifest_url.txt")" = "$manifest_before"
test "$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")" = "$project_before"
test "$(cat "$ROOT/EasySplatApp/Resources/public_key_ed25519.txt")" = "$public_before"

test "$(cat "$resources_dir/toolchain_manifest_url.txt")" = "$manifest_url"
test "$(cat "$resources_dir/project_home_url.txt")" = "$project_url"
test "$(cat "$resources_dir/public_key_ed25519.txt")" = 'PUBLIC_KEY_TEST_VALUE'

module_resources_dir="$resources_dir/EasySplat_EasySplatApp.bundle"
test "$(cat "$module_resources_dir/toolchain_manifest_url.txt")" = "$manifest_url"
test "$(cat "$module_resources_dir/project_home_url.txt")" = "$project_url"
test "$(cat "$module_resources_dir/public_key_ed25519.txt")" = 'PUBLIC_KEY_TEST_VALUE'

info_plist="$app_bundle/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" = "com.easysplat.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" = "EasySplatAppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$info_plist")" = "unsigned-beta"
test -d "$ROOT/build/Export/EasySplat.app.dSYM"
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

smoke_fixture_source="$TMP_DIR/smoke-fixture.c"
cat >"$smoke_fixture_source" <<'EOF'
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void stop(int signal) {
    (void)signal;
    running = 0;
}

int main(void) {
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    while (running) pause();
    return 0;
}
EOF
smoke_fixture_object="$TMP_DIR/smoke-fixture-arm64.o"
xcrun clang -arch arm64 -g -c "$smoke_fixture_source" -o "$smoke_fixture_object"
xcrun clang -arch arm64 \
  "$smoke_fixture_object" \
  -o "$app_bundle/Contents/MacOS/EasySplatApp"
rm -rf "$ROOT/build/Export/EasySplat.app.dSYM"
xcrun dsymutil \
  "$app_bundle/Contents/MacOS/EasySplatApp" \
  -o "$ROOT/build/Export/EasySplat.app.dSYM"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$app_bundle"

production_error="$TMP_DIR/production.stderr"
production_xcodebuild_log="$TMP_DIR/production-xcodebuild.log"
rm -f "$production_xcodebuild_log"
if EASYSPLAT_DEVELOPER_ID_APPLICATION="Developer ID Application: Test" \
  EASYSPLAT_NOTARY_KEYCHAIN_PROFILE="test-notary-profile" \
  EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_XCODEBUILD_LOG="$production_xcodebuild_log" \
  "$ROOT/scripts/release/build_app.sh" \
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
  detach) test -d "$2" ;;
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
grep -Fq 'Verified unsigned public beta: 0.2.0-beta.1' "$bundled_contract_only_output"

x86_fixture_object="$TMP_DIR/smoke-fixture-x86_64.o"
x86_fixture_binary="$TMP_DIR/EasySplatApp-x86_64"
xcrun clang -arch x86_64 -g -c "$smoke_fixture_source" -o "$x86_fixture_object"
xcrun clang -arch x86_64 "$x86_fixture_object" -o "$x86_fixture_binary"
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

early_exit_error="$TMP_DIR/release-verifier-early-exit.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$early_exit_fixture/EasySplat.app" \
  EASYSPLAT_SMOKE_SECONDS=0.2 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg" \
  --expected-version "0.2.0-beta.1" \
  --allow-incomplete >/dev/null 2>"$early_exit_error"; then
  echo "Beta verification accepted an app that exited before the smoke interval" >&2
  exit 1
fi
grep -Fqi 'exited during launch smoke' "$early_exit_error"

missing_public_key_fixture="$TMP_DIR/missing-public-key-fixture"
mkdir -p "$missing_public_key_fixture"
cp -R "$app_bundle" "$missing_public_key_fixture/EasySplat.app"
rm "$missing_public_key_fixture/EasySplat.app/Contents/Resources/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$missing_public_key_fixture/EasySplat.app"
missing_public_key_error="$TMP_DIR/release-verifier-missing-public-key.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$missing_public_key_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
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
mismatched_manifest_error="$TMP_DIR/release-verifier-mismatched-manifest.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$mismatched_manifest_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
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
  "$metadata_fixture/core/licenses/example" \
  "$metadata_fixture/base/da3_mps/models/DA3-BASE" \
  "$metadata_fixture/small/da3_mps/models/DA3-SMALL"
printf 'Apache-2.0 test license\n' >"$metadata_fixture/core/licenses/example/LICENSE"
ln -s ../licenses/example/LICENSE "$metadata_fixture/core/bin/license-link"
printf 'base-weights' >"$metadata_fixture/base/da3_mps/models/DA3-BASE/weights.bin"
printf 'small-weights' >"$metadata_fixture/small/da3_mps/models/DA3-SMALL/weights.bin"
python3 - "$metadata_fixture" <<'PY'
import hashlib
import json
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
locations = {
    "bin/license-link": root / "core/bin/license-link",
    "licenses/example/LICENSE": root / "core/licenses/example/LICENSE",
    "da3_mps/models/DA3-BASE/weights.bin": root / "base/da3_mps/models/DA3-BASE/weights.bin",
    "da3_mps/models/DA3-SMALL/weights.bin": root / "small/da3_mps/models/DA3-SMALL/weights.bin",
}
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
python3 - "$metadata_fixture" <<'PY'
import hashlib
import json
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
rows = []
for name, filename in (
    ("macos-arm64-core", "core.zip"),
    ("geometry-da3-base", "base.zip"),
    ("geometry-da3-small", "small.zip"),
):
    path = root / filename
    with zipfile.ZipFile(path) as archive:
        expanded_size = sum(info.file_size for info in archive.infolist() if not info.is_dir())
    rows.append({
        "name": name,
        "url": f"https://example.com/{filename}",
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "sizeBytes": path.stat().st_size,
        "expandedSizeBytes": expanded_size,
    })
manifest = {
    "schemaVersion": 2,
    "toolchainAPI": 2,
    "version": "2.0.0",
    "publishedAt": "2026-07-11T00:00:00Z",
    "keyID": "release-test-key",
    "signatureEd25519": "release-test-signature",
    "components": rows,
}
(root / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

beta_dmg="$TMP_DIR/EasySplat-0.2.0-beta.1-unsigned.dmg"
beta_stem="${beta_dmg%-unsigned.dmg}"
metadata_tool="$ROOT/scripts/release/generate_release_metadata.py"
python3 - "$metadata_tool" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_metadata", Path(sys.argv[1]))
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.validate_normal_photo_install_size({
    "core": 1_000_000_000,
    "geometry-da3-base": 1_000_000_000,
    "geometry-da3-small": 500_000_000,
})
try:
    module.validate_normal_photo_install_size({
        "core": 1_000_000_001,
        "geometry-da3-base": 1_000_000_000,
        "geometry-da3-small": 500_000_000,
    })
except module.MetadataError:
    pass
else:
    raise AssertionError("normal photo install size gate accepted more than 2.5 GB")
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
python3 "$metadata_tool" verify \
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
(cd "$ROOT/build/Export" && zip -qry "$beta_stem-dSYM.zip" EasySplat.app.dSYM)
printf '%s\n' 'EasySplat 0.2.0-beta.1 is an unsigned public beta.' >"$beta_stem-release-notes.txt"
release_metadata_args=(
  --release-manifest "$metadata_fixture/manifest.json"
  --core-archive "$metadata_fixture/core.zip"
  --da3-base-archive "$metadata_fixture/base.zip"
  --da3-small-archive "$metadata_fixture/small.zip"
)
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  --allow-incomplete \
  --skip-launch-smoke

fixture="$TMP_DIR/release-verifier-fixture.mov"
online_cache="$TMP_DIR/release-verifier-online-cache"
offline_cache="$TMP_DIR/release-verifier-offline-cache"
runner_log="$TMP_DIR/release-verifier-runners.log"
printf '%s' 'fixture' >"$fixture"
mkdir -p "$online_cache" "$offline_cache"

mock_runner="$TMP_DIR/mock-release-runner"
cat >"$mock_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture=""
manifest_url=""
public_key_file=""
cache_root=""
output=""
app_version=""
offline=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture) fixture="$2"; shift 2 ;;
    --manifest-url) manifest_url="$2"; shift 2 ;;
    --public-key-file) public_key_file="$2"; shift 2 ;;
    --cache-root) cache_root="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --app-version) app_version="$2"; shift 2 ;;
    --offline) offline=1; shift ;;
    *) echo "Unknown mock runner argument: $1" >&2; exit 2 ;;
  esac
done

mode="$(basename "$0")"
test -f "$fixture"
test -f "$public_key_file"
test "$(cat "$public_key_file")" = 'PUBLIC_KEY_TEST_VALUE'
test -d "$cache_root"
test -n "$output"
test "$app_version" = "0.2.0-beta.1"
case "$manifest_url" in
  https://*) ;;
  *) echo "Mock runner requires an HTTPS manifest URL." >&2; exit 2 ;;
esac
case "$mode" in
  mock-online-runner) test "$offline" -eq 0 ;;
  mock-offline-runner) test "$offline" -eq 1 ;;
  *) echo "Unexpected mock runner name: $mode" >&2; exit 2 ;;
esac

printf '%s|%s|%s|%s|%s|version=%s|offline=%s|%s\n' \
  "$mode" "$fixture" "$manifest_url" "$public_key_file" "$cache_root" "$app_version" "$offline" "$output" \
  >>"$EASYSPLAT_TEST_RUNNER_LOG"
{
  printf '%s\n' \
    'ply' \
    'format binary_little_endian 1.0' \
    'element vertex 1' \
    'property float x' \
    'property float y' \
    'property float z' \
    'property float nx' \
    'property float ny' \
    'property float nz' \
    'property float f_dc_0' \
    'property float f_dc_1' \
    'property float f_dc_2' \
    'property float opacity' \
    'property float scale_0' \
    'property float scale_1' \
    'property float scale_2' \
    'property float rot_0' \
    'property float rot_1' \
    'property float rot_2' \
    'property float rot_3' \
    'end_header'
  dd if=/dev/zero bs=68 count=1 2>/dev/null
} >"$output"
EOF
chmod +x "$mock_runner"
online_runner="$TMP_DIR/mock-online-runner"
offline_runner="$TMP_DIR/mock-offline-runner"
cp "$mock_runner" "$online_runner"
cp "$mock_runner" "$offline_runner"

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
  "${release_metadata_args[@]}" >/dev/null 2>"$missing_e2e_error"; then
  echo "Strict beta verification accepted a release without end-to-end inputs" >&2
  exit 1
fi
grep -Fqi 'requires an end-to-end fixture' "$missing_e2e_error"

missing_offline_error="$TMP_DIR/release-verifier-missing-offline.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  EASYSPLAT_TEST_RUNNER_LOG="$runner_log" \
  EASYSPLAT_SMOKE_SECONDS=0 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  --fixture "$fixture" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --toolchain-root "$online_cache" \
  --e2e-runner "$online_runner" >/dev/null 2>"$missing_offline_error"; then
  echo "Strict beta verification accepted a release without cached-offline inputs" >&2
  exit 1
fi
grep -Fqi 'requires a populated offline cache and runner' "$missing_offline_error"

: >"$runner_log"
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
EASYSPLAT_TEST_RUNNER_LOG="$runner_log" \
EASYSPLAT_SMOKE_SECONDS=0 \
  "$ROOT/scripts/release/verify_beta.sh" \
  --app "$app_bundle" \
  --dmg "$beta_dmg" \
  --expected-version "0.2.0-beta.1" \
  --artifacts \
  "${release_metadata_args[@]}" \
  --fixture "$fixture" \
  --manifest-url "$manifest_url" \
  --public-key-file "$public_key_path" \
  --toolchain-root "$online_cache" \
  --e2e-runner "$online_runner" \
  --offline-cache-root "$offline_cache" \
  --offline-runner "$offline_runner"
grep -F "mock-online-runner|$fixture|$manifest_url|" "$runner_log" \
  | grep -F "|$online_cache|version=0.2.0-beta.1|offline=0|" \
  | grep -Fq '/EasySplat.app/Contents/Resources/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt'
grep -F "mock-offline-runner|$fixture|$manifest_url|" "$runner_log" \
  | grep -F "|$offline_cache|version=0.2.0-beta.1|offline=1|" \
  | grep -Fq '/EasySplat.app/Contents/Resources/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt'
grep -q '^attach ' "$hdiutil_log"
grep -q '^detach ' "$hdiutil_log"

app_workflow="$ROOT/.github/workflows/release-app.yml"
grep -Fq 'workflow_dispatch:' "$app_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-release]' "$app_workflow"
grep -Fq 'test "$(uname -m)" = "arm64"' "$app_workflow"
grep -Fq 'environment: public-beta-release' "$app_workflow"
grep -Fq 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$app_workflow"
grep -Fq 'uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1' "$app_workflow"
grep -Fq 'python-version: "3.12"' "$app_workflow"
grep -Fq 'uses: softprops/action-gh-release@b4309332981a82ec1c5618f44dd2e27cc8bfbfda' "$app_workflow"
grep -Fq 'CURRENT_HEAD="$(gh api "repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH" --jq .sha)"' "$app_workflow"
grep -Fq 'if [ "$GITHUB_SHA" != "$CURRENT_HEAD" ]; then' "$app_workflow"
grep -Fq 'prerelease: true' "$app_workflow"
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
grep -Fq 'pressAndCancelDialog(' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'keeping technical failure details collapsed' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/PackagedAppVerifier.swift"
grep -Fq 'UIVerificationWorkspace.allCases.count' "$ROOT/Tools/UIVerifier/Sources/UIVerifierCore/UIHarnessSuiteValidator.swift"
grep -Fq 'scripts/benchmark/run_suite.sh' "$app_workflow"
grep -Fq -- '--profile release' "$app_workflow"
grep -Fq 'EASYSPLAT_RELEASE_CORPUS' "$app_workflow"
grep -Fq 'benchmark_run_id:' "$app_workflow"
grep -Fq 'gh run download "$INPUT_BENCHMARK_RUN_ID"' "$app_workflow"
grep -Fq -- '--evidence-root "$BENCHMARK_ARTIFACT/evidence"' "$app_workflow"
grep -Fq -- '--evidence-key-file "$RUNNER_TEMP/evidence.key"' "$app_workflow"
grep -Fq -- '--request-index "$BENCHMARK_ARTIFACT/requests/index.json"' "$app_workflow"
if rg -n '^  push:|uses: [^ ]+@(v[0-9]+|main|master)$' "$app_workflow" >/dev/null; then
  echo "App release workflow must be manual and pin actions to commit SHAs" >&2
  exit 1
fi

benchmark_workflow="$ROOT/.github/workflows/benchmark-release.yml"
grep -Fq 'workflow_dispatch:' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-reference]' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-constrained]' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-8gb]' "$benchmark_workflow"
grep -Fq 'environment: benchmark-release' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/run_lane.py' "$benchmark_workflow"
grep -Fq -- '--lane reference_m4_max' "$benchmark_workflow"
grep -Fq -- '--lane constrained_14_16gb' "$benchmark_workflow"
grep -Fq -- '--lane eight_gb_fast' "$benchmark_workflow"
grep -Fq 'BENCHMARK_EVIDENCE_KEY_BASE64' "$benchmark_workflow"
grep -Fq 'EASYSPLAT_BENCHMARK_REFERENCE_RUNNER_SHA256' "$benchmark_workflow"
grep -Fq 'EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER_SHA256' "$benchmark_workflow"
grep -Fq 'EASYSPLAT_BENCHMARK_8GB_RUNNER_SHA256' "$benchmark_workflow"
grep -Fq -- '--runner-identity "reference_m4_max=$REFERENCE_RUNNER_SHA256"' "$benchmark_workflow"
grep -Fq -- '--request-index "$RUNNER_TEMP/requests/index.json"' "$benchmark_workflow"
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
grep -q 'scripts/toolchain/build_colmap.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'scripts/toolchain/build_suitesparse.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'scripts/toolchain/build_ceres.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'scripts/toolchain/build_openimageio.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -Fq 'SUITESPARSE_COMMIT="42151688813c45846a597edcb601435a0e38f3dd"' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq 'SUITESPARSE_VERSION="7.12.2"' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DSUITESPARSE_ENABLE_PROJECTS=suitesparse_config;amd;colamd;cholmod' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DCHOLMOD_GPL=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DCHOLMOD_CAMD=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DCHOLMOD_PARTITION=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DSUITESPARSE_USE_CUDA=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DSUITESPARSE_USE_FORTRAN=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq 'prune_forbidden_sources' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DSUITESPARSE_DEMOS=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DBUILD_SHARED_LIBS=ON' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq -- '-DBUILD_STATIC_LIBS=OFF' "$ROOT/scripts/toolchain/build_suitesparse.sh"
grep -Fq 'CERES_COMMIT="85331393dc0dff09f6fb9903ab0c4bfa3e134b01"' "$ROOT/scripts/toolchain/build_ceres.sh"
grep -Fq 'CERES_VERSION="2.2.0"' "$ROOT/scripts/toolchain/build_ceres.sh"
grep -Fq 'EIGEN_COMMIT="3147391d946bb4b6c68edd901f2add6ac1f31f8c"' "$ROOT/scripts/toolchain/build_ceres.sh"
grep -Fq 'EIGEN_VERSION="3.4.0"' "$ROOT/scripts/toolchain/build_ceres.sh"
for option in \
  '-DSUITESPARSE=OFF' \
  '-DACCELERATESPARSE=ON' \
  '-DEIGENSPARSE=ON' \
  '-DUSE_CUDA=OFF' \
  '-DMINIGLOG=ON' \
  '-DGFLAGS=OFF' \
  '-DBUILD_EXAMPLES=OFF' \
  '-DBUILD_BENCHMARKS=OFF' \
  '-DBUILD_SHARED_LIBS=ON'; do
  grep -Fq -- "$option" "$ROOT/scripts/toolchain/build_ceres.sh"
done
grep -Fq 'OIIO_COMMIT="f32bf6e6f8de38ab6d197a72fd72366b66fd30a3"' "$ROOT/scripts/toolchain/build_openimageio.sh"
grep -Fq 'OIIO_VERSION="2.5.19.1"' "$ROOT/scripts/toolchain/build_openimageio.sh"
grep -Fq 'FMT_COMMIT="a0b8a92e3d1532361c2f7feb63babc5c18d00ef2"' "$ROOT/scripts/toolchain/build_openimageio.sh"
grep -Fq 'ROBINMAP_COMMIT="908ccf9f039a0e50813544c0444ca664ca292d7c"' "$ROOT/scripts/toolchain/build_openimageio.sh"
grep -Fq 'PUGIXML_COMMIT="314baf6605143f1e837209008f490e8559529e1c"' "$ROOT/scripts/toolchain/build_openimageio.sh"
for option in \
  '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0' \
  '-DCMAKE_CXX_STANDARD:STRING=17' \
  '-DBUILD_SHARED_LIBS:BOOL=ON' \
  '-DEMBEDPLUGINS:BOOL=ON' \
  '-DOIIO_BUILD_TOOLS:BOOL=OFF' \
  '-DOIIO_BUILD_TESTS:BOOL=OFF' \
  '-DBUILD_DOCS:BOOL=OFF' \
  '-DINSTALL_FONTS:BOOL=OFF' \
  '-DUSE_PYTHON:BOOL=OFF' \
  '-DUSE_OPENCOLORIO:BOOL=OFF' \
  '-DUSE_OPENCV:BOOL=OFF' \
  '-DUSE_TBB:BOOL=OFF' \
  '-DUSE_FFMPEG:BOOL=OFF' \
  '-DUSE_LIBHEIF:BOOL=OFF' \
  '-DUSE_LIBRAW:BOOL=OFF' \
  '-DUSE_OPENJPEG:BOOL=OFF' \
  '-DUSE_OPENVDB:BOOL=OFF' \
  '-DUSE_PTEX:BOOL=OFF' \
  '-DUSE_WEBP:BOOL=OFF' \
  '-DUSE_FREETYPE:BOOL=OFF'; do
  grep -Fq -- "$option" "$ROOT/scripts/toolchain/build_openimageio.sh"
done
grep -Fq 'allowed = {"jpeg", "openexr", "png", "tiff"}' "$ROOT/scripts/toolchain/build_openimageio.sh"
grep -Fq 'COLMAP_COMMIT="fa8e3b3ff591552855f8ad2806723c80f963f69c"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq 'COLMAP_VERSION="4.1.0"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq 'git -C "$SRC" checkout --detach --force "$COLMAP_COMMIT"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq 'install -m 0644 "$SRC/COPYING.txt" "$INSTALL/licenses/COLMAP/COPYING.txt"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq 'POSELIB_SHA256="5408d4ae8ce367cb2f076bc6c5f0f6f78abd3573d2c015304b04e46f23455f5b"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq 'FAISS_SHA256="4b1ae7e7a0a46385b4084f0e3945623a15fcf99d793bf44d82aae8e24f11e5f5"' "$ROOT/scripts/toolchain/build_colmap.sh"
for option in \
  '-DGUI_ENABLED=OFF' \
  '-DCUDA_ENABLED=OFF' \
  '-DOPENGL_ENABLED=OFF' \
  '-DMVS_ENABLED=OFF' \
  '-DCGAL_ENABLED=OFF' \
  '-DLSD_ENABLED=OFF' \
  '-DONNX_ENABLED=OFF' \
  '-DFETCH_ONNX=OFF' \
  '-DDOWNLOAD_ENABLED=OFF' \
  '-DCASPAR_ENABLED=OFF' \
  '-DTESTS_ENABLED=OFF'; do
  grep -Fq -- "$option" "$ROOT/scripts/toolchain/build_colmap.sh"
done
grep -Fq -- '-DCeres_DIR="$CERES_INSTALL/lib/cmake/Ceres"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq -- '-DCHOLMOD_LIBRARY_DIR_HINTS="$SUITESPARSE_INSTALL/lib"' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -Fq 'assert_permissive_closure' "$ROOT/scripts/toolchain/build_colmap.sh"
grep -q 'scripts/toolchain/build_msplat.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'scripts/toolchain/build_da3_mps.sh' "$ROOT/.github/workflows/toolchain-build.yml"
toolchain_workflow="$ROOT/.github/workflows/toolchain-build.yml"
suitesparse_line="$(grep -n -m1 'scripts/toolchain/build_suitesparse.sh' "$toolchain_workflow" | cut -d: -f1)"
ceres_line="$(grep -n -m1 'scripts/toolchain/build_ceres.sh' "$toolchain_workflow" | cut -d: -f1)"
openimageio_line="$(grep -n -m1 'scripts/toolchain/build_openimageio.sh' "$toolchain_workflow" | cut -d: -f1)"
colmap_line="$(grep -n -m1 'scripts/toolchain/build_colmap.sh' "$toolchain_workflow" | cut -d: -f1)"
test "$suitesparse_line" -lt "$ceres_line"
test "$ceres_line" -lt "$colmap_line"
test "$openimageio_line" -lt "$colmap_line"
if rg -n 'brew install .*\b(suitesparse|ceres-solver|cgal|freeimage|openimageio|qt)\b' \
  "$ROOT/.github/workflows/toolchain-build.yml" >/dev/null; then
  echo "Toolchain workflow must not install prebuilt native builders or disabled dependencies." >&2
  exit 1
fi
grep -Fq 'python3 scripts/toolchain/verify_homebrew_lock.py source' \
  "$ROOT/.github/workflows/toolchain-build.yml"
grep -Fq 'brew install --build-from-source "$formula"' \
  "$ROOT/.github/workflows/toolchain-build.yml"
grep -Fq 'brew reinstall --build-from-source "$formula"' \
  "$ROOT/.github/workflows/toolchain-build.yml"
grep -Fq 'python3 scripts/toolchain/verify_homebrew_lock.py installed' \
  "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'colmap" global_mapper -h' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'colmap" image_undistorter -h' "$ROOT/scripts/toolchain/package_toolchain.sh"
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
# This asserts the requirements continuation backslash.
# shellcheck disable=SC1003
grep -q '^numpy==2\.3\.5 \\' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -q -- '--hash=sha256:' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -Fq -- '--require-hashes' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--only-binary=:all:' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--no-binary=antlr4-python3-runtime' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--report "$PIP_INSTALL_REPORT"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q 'rm -rf "$target"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q '/usr/bin/file -b "$python_bin"' "$ROOT/scripts/toolchain/package_toolchain.sh"
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
grep -q 'resolve_rpath_dependency_for' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "da3_mps" "$DA3_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'cp "$OPENIMAGEIO_INSTALL/build_info.json" "$PROVENANCE/openimageio.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'cp -R "$OPENIMAGEIO_INSTALL/licenses/." "$LICENSES/"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'copy_dependency_to_lib "$OPENIMAGEIO_INSTALL/lib/libOpenImageIO.2.5.dylib" "$BIN/colmap"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'copy_dependency_to_lib "$OPENIMAGEIO_INSTALL/lib/libOpenImageIO_Util.2.5.dylib" "$BIN/colmap"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'normalize_bundle_rpaths' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'reject_forbidden_image_dependencies' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '/usr/bin/codesign --force --sign - --timestamp=none "$file"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '/usr/bin/codesign --verify --strict "$file"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'done < <(find "$OUT" -type f -print0)' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'for file in "${dylibs[@]}" "${other_machos[@]}"; do' "$ROOT/scripts/toolchain/package_toolchain.sh"
for dependency in x264 x265 aom dav1d vpx svtav1 theora vorbis; do
  grep -Fq "$dependency" "$ROOT/scripts/toolchain/package_toolchain.sh"
done
grep -Fq 'refresh_packaged_msplat_hash' "$ROOT/scripts/toolchain/package_toolchain.sh"
bundle_line="$(grep -n -m1 '^bundle_toolchain_dependency_closure$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
normalize_line="$(grep -n -m1 '^normalize_bundle_rpaths$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
sign_line="$(grep -n -m1 '^ad_hoc_sign_packaged_machos$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
validate_line="$(grep -n -m1 '^validate_portable_dependency_references$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
launch_line="$(grep -n -m1 '^"$BIN/colmap" global_mapper -h' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
# This asserts the command continuation backslash.
# shellcheck disable=SC1003
supply_line="$(grep -n -m1 '^"$SUPPLY_CHAIN_GENERATOR" \\' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
test "$bundle_line" -lt "$normalize_line"
test "$normalize_line" -lt "$sign_line"
test "$sign_line" -lt "$validate_line"
test "$validate_line" -lt "$launch_line"
test "$launch_line" -lt "$supply_line"
grep -Fq 'zip -r "$CORE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'zip -r "$DA3_BASE_ZIP" da3_mps/models/DA3-BASE' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'zip -r "$DA3_SMALL_ZIP" da3_mps/models/DA3-SMALL' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_RELEASE_ASSET_BYTES=2147483648' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_NORMAL_PHOTO_INSTALL_BYTES=2500000000' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$CORE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$DA3_BASE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_normal_photo_install_size "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'licenses provenance supply-chain/components.json' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"openimageio": native(' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"openimageio:fmt"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"openimageio:pugixml"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"openimageio:robin-map"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"colmap:faiss"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"colmap:poselib"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"colmap:poissonrecon"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"colmap:vlfeat"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '/Toolchains/build/openimageio/install/' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
if grep -Fq 'colmap:vendored-static' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"; then
  echo "Supply-chain inventory still collapses COLMAP dependencies into one component." >&2
  exit 1
fi
grep -Fq -- '--da3-base-zip "$DA3_BASE_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq -- '--da3-small-zip "$DA3_SMALL_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq 'test -x "$ROOT/Toolchains/build/colmap/install/bin/colmap" || "$ROOT/scripts/toolchain/build_colmap.sh"' "$ROOT/scripts/run.sh"
grep -Fq 'ensure_msplat_bundle' "$ROOT/scripts/run.sh"
grep -Fq 'ensure_da3_mps_bundle' "$ROOT/scripts/run.sh"

workflow="$ROOT/.github/workflows/toolchain-build.yml"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-release]' "$workflow"
grep -Fq 'environment: toolchain-release' "$workflow"
grep -Fq 'if: github.ref == format(' "$workflow"
grep -Fq 'fetch-depth: 0' "$workflow"
grep -Fq 'CURRENT_HEAD="$(gh api "repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH" --jq .sha)"' "$workflow"
grep -Fq 'if [ "$GITHUB_SHA" != "$CURRENT_HEAD" ]; then' "$workflow"
grep -Fq 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$workflow"
grep -Fq 'uses: softprops/action-gh-release@b4309332981a82ec1c5618f44dd2e27cc8bfbfda' "$workflow"
grep -Fq -- '--da3-base-zip "$DA3_BASE_ZIP"' "$workflow"
grep -Fq -- '--da3-small-zip "$DA3_SMALL_ZIP"' "$workflow"
grep -Fq -- '--app-version-minimum "$APP_VERSION_MINIMUM"' "$workflow"
grep -Fq -- '--app-version-maximum-exclusive "$APP_VERSION_MAXIMUM_EXCLUSIVE"' "$workflow"
grep -Fq 'Toolchains/out/toolchain-geometry-da3-base-${{ env.VERSION }}.zip' "$workflow"
grep -Fq 'Toolchains/out/toolchain-geometry-da3-small-${{ env.VERSION }}.zip' "$workflow"
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
grep -Fq 'msplat/build_info.json msplat/LICENSE' "$ROOT/scripts/toolchain/package_toolchain.sh"
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
if [ -d "$msplat_source" ]; then
  "$msplat_validator" --source "$msplat_source"

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
grep -Fqi 'app build is already in progress' "$second_build_error"
