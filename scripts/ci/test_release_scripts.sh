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
if grep -Eqi 'pip install|python-build-standalone|site-packages|_core\.so|core_extension_path\.txt|(^|[^[:alnum:]])msplat-train' "$ROOT/scripts/toolchain/build_msplat.sh"; then
  echo "Native msplat builder still contains packaged-Python or legacy CLI remnants" >&2
  exit 1
fi
grep -q '^numpy==2\.3\.5$' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -q 'rm -rf "$target"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q '/usr/bin/file -b "$python_bin"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'source_provenance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'pinned-git' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'resolve_rpath_dependency_for' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "da3_mps" "$DA3_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "mapanything_mps" "$MAP_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "vggt_mps" "$PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'require_bundled_arm64_python "fastvggt_mps" "$FAST_PY_BIN"' "$ROOT/scripts/toolchain/package_toolchain.sh"

msplat_validator="$ROOT/scripts/toolchain/validate_native_msplat.sh"
[ -x "$msplat_validator" ] || {
  echo "Missing executable native msplat validator: $msplat_validator" >&2
  exit 1
}

grep -Fq '"$MSPLAT_VALIDATOR" --source "$MSPLAT_INSTALL/msplat"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --packaged "$OUT"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '[ "$file" = "$BIN/easysplat-train" ]' "$ROOT/scripts/toolchain/package_toolchain.sh"
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
fi

if [ -e "$app_bundle/Contents/lib/Sparkle.framework" ]; then
  echo "Release app unexpectedly bundled Sparkle.framework" >&2
  exit 1
fi
