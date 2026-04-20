#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mock_xcodebuild="$TMP_DIR/mock-xcodebuild.sh"
cat >"$mock_xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

derived=""
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
cat >"$derived/Build/Products/Release/EasySplatApp" <<'APP'
#!/usr/bin/env bash
echo "mock EasySplat app"
APP
chmod +x "$derived/Build/Products/Release/EasySplatApp"
printf '%s' 'DEFAULT_MANIFEST_URL' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/toolchain_manifest_url.txt"
printf '%s' 'DEFAULT_PROJECT_URL' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/project_home_url.txt"
printf '%s' 'DEFAULT_PUBLIC_KEY' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt"
EOF
chmod +x "$mock_xcodebuild"

manifest_before="$(cat "$ROOT/EasySplatApp/Resources/toolchain_manifest_url.txt")"
project_before="$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")"
public_before="$(cat "$ROOT/EasySplatApp/Resources/public_key_ed25519.txt")"

manifest_url="https://example.com/releases/download/toolchain-v1.2.3/manifest.json"
project_url="https://example.com/EasySplat"
public_key_path="$TMP_DIR/public_key.txt"
printf '%s' 'PUBLIC_KEY_TEST_VALUE' >"$public_key_path"

EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --manifest-url "$manifest_url" \
  --public-key-path "$public_key_path" \
  --project-url "$project_url" \
  --version "1.2.3"

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

grep -q 'CORE_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-macos-arm64-$VERSION-core.zip"' "$ROOT/scripts/release/build_dmg.sh"
grep -q 'MODELS_ARTIFACT_URL="http://localhost:$PORT/out/toolchain-macos-arm64-$VERSION-models.zip"' "$ROOT/scripts/release/build_dmg.sh"

if [ -e "$app_bundle/Contents/lib/Sparkle.framework" ]; then
  echo "Release app unexpectedly bundled Sparkle.framework" >&2
  exit 1
fi
