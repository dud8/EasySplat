#!/bin/bash -p
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/strict_semver.sh
source "$ROOT/scripts/release/lib/strict_semver.sh"
TOOLCHAIN_DIR=""
PROJECT_URL=""
VERSION=""
RELEASE_MODE=""
IDENTITY_FINGERPRINT=""
TEAM_ID=""
IDENTITY_FINGERPRINT_SET=0
TEAM_ID_SET=0
BUILD_ROOT="$ROOT/build"
XCODEBUILD_BIN="${EASYSPLAT_XCODEBUILD_BIN:-xcodebuild}"
CODESIGN_BIN="${EASYSPLAT_CODESIGN_BIN:-codesign}"
XCRUN_BIN="${EASYSPLAT_XCRUN_BIN:-xcrun}"
INPUT_SNAPSHOT_DIR=""
BUILD_LOCK=""
BUILD_LOCK_HELD=0
APP_BUNDLE=""
SIGNING_RECEIPT=""
SIGNED_BUILD_COMPLETE=0

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$BUILD_LOCK_HELD" -eq 1 ] && [ -n "$BUILD_LOCK" ]; then
    rm -f "$BUILD_LOCK/pid"
    rmdir "$BUILD_LOCK" 2>/dev/null || true
  fi
  if [ -n "$INPUT_SNAPSHOT_DIR" ]; then
    rm -rf "$INPUT_SNAPSHOT_DIR"
  fi
  if [ "$RELEASE_MODE" = production ] && [ "$SIGNED_BUILD_COMPLETE" -ne 1 ]; then
    [ -z "$APP_BUNDLE" ] || rm -rf "$APP_BUNDLE"
    [ -z "$SIGNING_RECEIPT" ] || rm -f "$SIGNING_RECEIPT"
  fi
  exit "$status"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchain-dir)
      if [ -n "$TOOLCHAIN_DIR" ]; then
        echo "--toolchain-dir may be supplied only once." >&2
        exit 1
      fi
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--toolchain-dir requires an absolute path." >&2
        exit 1
      fi
      TOOLCHAIN_DIR="$2"
      shift 2
      ;;
    --project-url)
      PROJECT_URL="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
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
    --prepare-release)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      RELEASE_MODE="prepare-release"
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
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

unset GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN GITHUB_TOKEN

if [ -z "$TOOLCHAIN_DIR" ] || [ -z "$VERSION" ] || [ -z "$RELEASE_MODE" ]; then
  echo "Usage: build_app.sh --toolchain-dir <path> --version <semver> [--project-url <url>] [--build-root <absolute-path>] (--development-unsigned | --prepare-release | --production --identity-fingerprint <sha1> --team-id <id>)" >&2
  exit 1
fi
if [ "$RELEASE_MODE" = production ]; then
  if ! [[ "$IDENTITY_FINGERPRINT" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "Production builds require an exact 40-hex Developer ID fingerprint." >&2
    exit 1
  fi
  if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Production builds require an exact 10-character Team ID." >&2
    exit 1
  fi
  if [ -n "${EASYSPLAT_XCODEBUILD_BIN:-}" ] \
      || [ -n "${EASYSPLAT_CODESIGN_BIN:-}" ] \
      || [ -n "${EASYSPLAT_SKIP_METAL_TOOLCHAIN_CHECK:-}" ]; then
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
  XCODEBUILD_BIN=/usr/bin/xcodebuild
  CODESIGN_BIN=/usr/bin/codesign
  XCRUN_BIN=/usr/bin/xcrun
elif [ -n "$IDENTITY_FINGERPRINT" ] || [ -n "$TEAM_ID" ]; then
  echo "Signing identity arguments require --production." >&2
  exit 1
fi
if [ "$RELEASE_MODE" = prepare-release ]; then
  if [ -n "${EASYSPLAT_XCODEBUILD_BIN:-}" ] \
      || [ -n "${EASYSPLAT_CODESIGN_BIN:-}" ] \
      || [ -n "${EASYSPLAT_SKIP_METAL_TOOLCHAIN_CHECK:-}" ]; then
    echo "Prepared production build command overrides are not permitted." >&2
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
  XCODEBUILD_BIN=/usr/bin/xcodebuild
  CODESIGN_BIN=/usr/bin/codesign
  XCRUN_BIN=/usr/bin/xcrun
fi
validated_build_root="$(/usr/bin/python3 -I - "$BUILD_ROOT" "$ROOT" <<'PY'
import os
import sys

candidate, repository = sys.argv[1:]
if not os.path.isabs(candidate):
    raise SystemExit("Build root must be an absolute path.")
if os.path.normpath(candidate) != candidate:
    raise SystemExit("Build root must be normalized (no trailing slash, '.' or '..' segments).")

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
is_repository_ancestor = os.path.commonpath((resolved, repository)) == resolved
if resolved in protected_roots or is_repository_ancestor:
    raise SystemExit(f"Refusing unsafe build root: {candidate}")
if os.path.lexists(resolved) and not os.path.isdir(resolved):
    raise SystemExit(f"Build root is not a directory: {candidate}")

print(resolved)
PY
)" || exit 1
BUILD_ROOT="$validated_build_root"

/usr/bin/python3 -I - "$PROJECT_URL" <<'PY'
import sys
from urllib.parse import urlparse

value = sys.argv[1]
if value:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit("Project URL must use HTTPS and contain no credentials.")
PY

if ! easysplat_is_strict_semver_without_build_metadata "$VERSION"; then
  echo "App version must be strict semantic versioning without build metadata: $VERSION" >&2
  exit 1
fi
if [ "$RELEASE_MODE" != development-unsigned ] \
    && ! easysplat_is_strict_semver_stable "$VERSION"; then
  echo "Prepared and production releases require a stable semantic version without build metadata: $VERSION" >&2
  exit 1
fi
NUMERIC_VERSION="${VERSION%%-*}"

TOOLCHAIN_DIR="$(/usr/bin/python3 -I - "$TOOLCHAIN_DIR" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
if not os.path.isabs(root) or os.path.normpath(root) != root:
    raise SystemExit("Toolchain directory must be an absolute, normalized path.")
if os.path.realpath(root) != root:
    raise SystemExit("Toolchain directory must contain no symlink ancestry.")

required = (
    "bin/colmap",
    "bin/easysplat-train",
    "bin/default.metallib",
    "lib/libomp.dylib",
    "msplat/build_info.json",
    "msplat/LICENSE",
    "provenance/colmap.json",
    "supply-chain/components.json",
)
for relative in required:
    path = os.path.join(root, relative)
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        raise SystemExit(f"Toolchain directory is missing {relative}: {path}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(f"{relative} must be an ordinary, non-hardlinked regular file")
    if metadata.st_size == 0:
        raise SystemExit(f"{relative} must not be empty")

print(root)
PY
)" || exit 1

INPUT_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-inputs.XXXXXX")"
chmod 0700 "$INPUT_SNAPSHOT_DIR"

# The build validates the toolchain tree and then reads it again to stage and to
# compare the staged bytes. Taking a private copy first is what makes those the
# same bytes: whatever happens to the caller's tree afterwards, the product is
# built from what was checked here.
/usr/bin/ditto --noqtn "$TOOLCHAIN_DIR" "$INPUT_SNAPSHOT_DIR/toolchain"
TOOLCHAIN_DIR="$INPUT_SNAPSHOT_DIR/toolchain"

if [ "${XCODEBUILD_BIN##*/}" = "xcodebuild" ]; then
  if ! "$XCODEBUILD_BIN" -license check >/dev/null 2>&1; then
    echo "Xcode license not accepted. Run: sudo xcodebuild -license accept" >&2
    exit 1
  fi
fi

if [ "${EASYSPLAT_SKIP_METAL_TOOLCHAIN_CHECK:-}" != "1" ] && [ "${XCODEBUILD_BIN##*/}" = "xcodebuild" ]; then
  if ! "$XCRUN_BIN" -sdk macosx metal -v >/dev/null 2>&1; then
    echo "Metal Toolchain not installed. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
fi

BUILD_LOCK="$BUILD_ROOT/.build-app.lock"
mkdir -p "$BUILD_ROOT"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
  lock_owner=""
  if [ -r "$BUILD_LOCK/pid" ]; then
    lock_owner=" (PID $(cat "$BUILD_LOCK/pid"))"
  fi
  echo "An app build is already in progress$lock_owner. If no build is running, remove $BUILD_LOCK." >&2
  exit 1
fi
BUILD_LOCK_HELD=1
printf '%s\n' "$$" >"$BUILD_LOCK/pid"

DERIVED="$BUILD_ROOT/DerivedData"
OUT="$BUILD_ROOT/Export"
BIN_PATH="$DERIVED/Build/Products/Release/EasySplatApp"
BUILT_DSYM_PATH="$DERIVED/Build/Products/Release/EasySplatApp.dSYM"
APP_BUNDLE="$OUT/EasySplat.app"
SIGNING_RECEIPT="$OUT/EasySplat.app-signing.json"
EXPORTED_DSYM_PATH="$OUT/EasySplat.app.dSYM"
RES_DIR="$APP_BUNDLE/Contents/Resources"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
OVERRIDE_RES_DIR="$OUT/AppResourcesOverride"

if [ -z "$PROJECT_URL" ] \
  && [ -f "$ROOT/EasySplatApp/Resources/project_home_url.txt" ]; then
  PROJECT_URL="$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")"
fi

rm -rf "$DERIVED" "$OUT"

"$XCODEBUILD_BIN" \
  -scheme EasySplatApp \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  MACOSX_DEPLOYMENT_TARGET=15.0 \
  SDKROOT=macosx \
  build

if [ ! -f "$BIN_PATH" ]; then
  echo "Missing built binary at $BIN_PATH" >&2
  exit 1
fi
if [ "$(/usr/bin/lipo -archs "$BIN_PATH" 2>/dev/null)" != "arm64" ]; then
  echo "Release app executable must contain exactly arm64: $BIN_PATH" >&2
  exit 1
fi
if /usr/bin/nm -m "$BIN_PATH" 2>/dev/null \
  | grep '___llvm_profile' >/dev/null; then
  echo "Release app executable contains code-coverage instrumentation: $BIN_PATH" >&2
  exit 1
fi
if [ ! -d "$BUILT_DSYM_PATH" ]; then
  echo "Missing Release dSYM at $BUILT_DSYM_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/EasySplatApp"
chmod +x "$MACOS_DIR/EasySplatApp"
"$CODESIGN_BIN" --verify --strict "$MACOS_DIR/EasySplatApp"

APP_RELEASE_CHANNEL="$RELEASE_MODE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>EasySplatApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.easysplat.app</string>
  <key>CFBundleIconFile</key>
  <string>EasySplatAppIcon</string>
  <key>CFBundleName</key>
  <string>EasySplat</string>
  <key>CFBundleDisplayName</key>
  <string>EasySplat</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$NUMERIC_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$NUMERIC_VERSION</string>
  <key>EasySplatReleaseChannel</key>
  <string>$APP_RELEASE_CHANNEL</string>
  <key>EasySplatReleaseVersion</key>
  <string>$VERSION</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Gaussian Splat</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.polygon-file-format</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Splat</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>splat</string>
      </array>
    </dict>
  </array>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.graphics-design</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 EasySplat contributors. MIT License.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

# Copy direct resources used by Bundle.main
if [ -d "$ROOT/EasySplatApp/Resources" ]; then
  cp -R "$ROOT/EasySplatApp/Resources/." "$RES_DIR/"
fi
# Code signing treats every plain file under Contents/Helpers as unsigned nested
# code, so only Mach-Os live there; the payload is sealed as ordinary resources.
HELPERS_DIR="$APP_BUNDLE/Contents/Helpers"
TOOLCHAIN_RES_DIR="$RES_DIR/Toolchain"
rm -rf "$HELPERS_DIR" "$TOOLCHAIN_RES_DIR"
mkdir -p "$HELPERS_DIR/bin" "$HELPERS_DIR/lib" "$TOOLCHAIN_RES_DIR"
for helper in colmap easysplat-train; do
  install -m 0755 "$TOOLCHAIN_DIR/bin/$helper" "$HELPERS_DIR/bin/$helper"
done
install -m 0755 "$TOOLCHAIN_DIR/lib/libomp.dylib" "$HELPERS_DIR/lib/libomp.dylib"
install -m 0644 "$TOOLCHAIN_DIR/bin/default.metallib" "$TOOLCHAIN_RES_DIR/default.metallib"
for payload in msplat provenance supply-chain licenses; do
  if [ -d "$TOOLCHAIN_DIR/$payload" ]; then
    cp -R "$TOOLCHAIN_DIR/$payload" "$TOOLCHAIN_RES_DIR/$payload"
  fi
done
/usr/bin/find "$TOOLCHAIN_RES_DIR" -type d -exec chmod 0755 {} +
/usr/bin/find "$TOOLCHAIN_RES_DIR" -type f -exec chmod 0644 {} +
for staged in \
  "bin/colmap:$HELPERS_DIR/bin/colmap" \
  "bin/easysplat-train:$HELPERS_DIR/bin/easysplat-train" \
  "lib/libomp.dylib:$HELPERS_DIR/lib/libomp.dylib" \
  "bin/default.metallib:$TOOLCHAIN_RES_DIR/default.metallib"; do
  if ! cmp -s "$TOOLCHAIN_DIR/${staged%%:*}" "${staged#*:}"; then
    echo "Staged toolchain bytes differ from the source tree: ${staged%%:*}" >&2
    exit 1
  fi
done
if /usr/bin/find "$HELPERS_DIR" "$TOOLCHAIN_RES_DIR" \
  \( -type l -o \( -type f -a ! -links 1 \) \) -print | /usr/bin/grep -q .; then
  echo "Staged toolchain must contain no symlinks and no hard links." >&2
  exit 1
fi
# colmap finds libomp through its own rpath; nothing is rewritten at package time.
if ! /usr/bin/otool -l "$HELPERS_DIR/bin/colmap" \
  | /usr/bin/grep -q "@executable_path/../lib"; then
  echo "colmap no longer carries the rpath the bundled layout depends on." >&2
  exit 1
fi
if [ ! -s "$RES_DIR/EasySplatAppIcon.icns" ]; then
  echo "Missing bundled app icon at $RES_DIR/EasySplatAppIcon.icns" >&2
  exit 1
fi
LICENSE_DIR="$RES_DIR/Licenses"
mkdir -p "$LICENSE_DIR"
install -m 0644 "$ROOT/LICENSE" "$LICENSE_DIR/EasySplat-LICENSE.txt"
install -m 0644 "$ROOT/NOTICE.md" "$LICENSE_DIR/EasySplat-NOTICE.md"
install -m 0644 "$ROOT/ThirdParty/MetalSplatter/LICENSE" "$LICENSE_DIR/MetalSplatter-LICENSE.txt"

mkdir -p "$OVERRIDE_RES_DIR"
printf "%s" "$PROJECT_URL" > "$OVERRIDE_RES_DIR/project_home_url.txt"
cp -R "$OVERRIDE_RES_DIR/." "$RES_DIR/"
if [ "$RELEASE_MODE" = production ]; then
  printf '%s' 'production release' >"$RES_DIR/release_channel.txt"
elif [ "$RELEASE_MODE" = prepare-release ]; then
  printf '%s' 'prepared release candidate' >"$RES_DIR/release_channel.txt"
else
  printf '%s' 'unsigned developer build' >"$RES_DIR/release_channel.txt"
fi

# Copy SwiftPM resource bundles (if present)
if [ -d "$DERIVED/Build/Products/Release/EasySplat_EasySplatApp.bundle" ]; then
  cp -R "$DERIVED/Build/Products/Release/EasySplat_EasySplatApp.bundle" "$RES_DIR/"
  cp -R "$OVERRIDE_RES_DIR/." "$RES_DIR/EasySplat_EasySplatApp.bundle/"
  if [ -d "$RES_DIR/EasySplat_EasySplatApp.bundle/Contents/Resources" ]; then
    cp -R "$OVERRIDE_RES_DIR/." "$RES_DIR/EasySplat_EasySplatApp.bundle/Contents/Resources/"
  fi
fi
if [ -d "$DERIVED/Build/Products/Release/MetalSplatter_MetalSplatter.bundle" ]; then
  cp -R "$DERIVED/Build/Products/Release/MetalSplatter_MetalSplatter.bundle" "$RES_DIR/"
fi

rm -rf "$EXPORTED_DSYM_PATH"
cp -R "$BUILT_DSYM_PATH" "$EXPORTED_DSYM_PATH"

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
if [ "$RELEASE_MODE" = production ]; then
  signing_args=(
    --root "$APP_BUNDLE"
    --kind app
    --identity-fingerprint "$IDENTITY_FINGERPRINT"
    --team-id "$TEAM_ID"
    --receipt "$SIGNING_RECEIPT"
  )
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    "${signing_args[@]}"
  /usr/bin/python3 -I "$ROOT/scripts/release/sign_macos_distribution.py" \
    --verify-only \
    --bind-receipt-to-current-artifact \
    --root "$APP_BUNDLE" \
    --kind app \
    --identity-fingerprint "$IDENTITY_FINGERPRINT" \
    --team-id "$TEAM_ID" \
    --receipt "$SIGNING_RECEIPT"
  SIGNED_BUILD_COMPLETE=1
else
  # Sign inside out. --deep is unsupported for distribution and would hide a
  # broken nesting order here that then fails in the signed lane.
  "$CODESIGN_BIN" --force --sign - --timestamp=none "$HELPERS_DIR/lib/libomp.dylib"
  for helper in colmap easysplat-train; do
    "$CODESIGN_BIN" --force --sign - --timestamp=none "$HELPERS_DIR/bin/$helper"
  done
  "$CODESIGN_BIN" --force --sign - --timestamp=none "$APP_BUNDLE"
  "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

echo "Built app at: $APP_BUNDLE"
echo "Preserved dSYM at: $EXPORTED_DSYM_PATH"
