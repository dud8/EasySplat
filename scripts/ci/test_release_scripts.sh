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
grep -q -- '--private-key-file "$PRIV"' "$ROOT/scripts/release/build_dmg.sh"
grep -q 'scripts/toolchain/build_msplat.sh' "$ROOT/scripts/release/build_dmg.sh"
grep -q 'scripts/toolchain/build_da3_mps.sh' "$ROOT/scripts/release/build_dmg.sh"
grep -q 'scripts/toolchain/build_mapanything_mps.sh' "$ROOT/scripts/release/build_dmg.sh"
grep -q 'scripts/toolchain/build_msplat.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q 'MSPLAT_VERSION="${MSPLAT_VERSION:-1\.1\.3}"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'MSPLAT_PIP_SPEC="msplat\[cli\]==$MSPLAT_VERSION"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q '^numpy==2\.3\.5$' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -q 'rm -rf "$target"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q '/usr/bin/file -b "$python_bin"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'source_provenance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'pinned-git' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "msplat" "$MSPLAT_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'resolve_rpath_dependency_for' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "da3_mps" "$DA3_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "mapanything_mps" "$MAP_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "vggt_mps" "$PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "fastvggt_mps" "$FAST_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"

if [ -e "$app_bundle/Contents/lib/Sparkle.framework" ]; then
  echo "Release app unexpectedly bundled Sparkle.framework" >&2
  exit 1
fi
