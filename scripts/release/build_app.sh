#!/bin/bash -p
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/strict_semver.sh
source "$ROOT/scripts/release/lib/strict_semver.sh"
MANIFEST_URL=""
PUBLIC_KEY_PATH=""
PROJECT_URL=""
VERSION=""
RELEASE_MODE=""
IDENTITY_FINGERPRINT=""
TEAM_ID=""
IDENTITY_FINGERPRINT_SET=0
TEAM_ID_SET=0
BOOTSTRAP_MANIFEST=""
BOOTSTRAP_CORE_ARCHIVE=""
PREPARED_BOOTSTRAP_VERIFIER=""
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
    --manifest-url)
      MANIFEST_URL="$2"
      shift 2
      ;;
    --public-key-path)
      PUBLIC_KEY_PATH="$2"
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
    --bootstrap-manifest)
      if [ -n "$BOOTSTRAP_MANIFEST" ]; then
        echo "--bootstrap-manifest may be supplied only once." >&2
        exit 1
      fi
      BOOTSTRAP_MANIFEST="$2"
      shift 2
      ;;
    --bootstrap-core-archive)
      if [ -n "$BOOTSTRAP_CORE_ARCHIVE" ]; then
        echo "--bootstrap-core-archive may be supplied only once." >&2
        exit 1
      fi
      BOOTSTRAP_CORE_ARCHIVE="$2"
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
    --manifest-tool-bin)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--manifest-tool-bin requires an absolute executable path." >&2
        exit 1
      fi
      PREPARED_BOOTSTRAP_VERIFIER="$2"
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

if [ -z "$MANIFEST_URL" ] || [ -z "$PUBLIC_KEY_PATH" ] || [ -z "$VERSION" ] || [ -z "$RELEASE_MODE" ]; then
  echo "Usage: build_app.sh --manifest-url <url> --public-key-path <path> --version <semver> --bootstrap-manifest <path> --bootstrap-core-archive <path> [--project-url <url>] [--build-root <absolute-path>] (--development-unsigned | --prepare-release | --production --identity-fingerprint <sha1> --team-id <id>)" >&2
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
if { [ -n "$BOOTSTRAP_MANIFEST" ] && [ -z "$BOOTSTRAP_CORE_ARCHIVE" ]; } \
  || { [ -z "$BOOTSTRAP_MANIFEST" ] && [ -n "$BOOTSTRAP_CORE_ARCHIVE" ]; }; then
  echo "--bootstrap-manifest and --bootstrap-core-archive must be supplied together." >&2
  exit 1
fi
if [ -z "$BOOTSTRAP_MANIFEST" ]; then
  echo "Release app builds require --bootstrap-manifest and --bootstrap-core-archive." >&2
  exit 1
fi
if [ -n "$PREPARED_BOOTSTRAP_VERIFIER" ]; then
  if [ "$RELEASE_MODE" != prepare-release ] \
      || [ ! -x "$PREPARED_BOOTSTRAP_VERIFIER" ] \
      || [ -L "$PREPARED_BOOTSTRAP_VERIFIER" ]; then
    echo "A prebuilt ManifestTool is only accepted for a prepared production build." >&2
    exit 1
  fi
  PREPARED_BOOTSTRAP_VERIFIER="$(/usr/bin/python3 -I - "$PREPARED_BOOTSTRAP_VERIFIER" <<'PY'
import os
import sys

value = sys.argv[1]
if not os.path.isabs(value) or os.path.normpath(value) != value:
    raise SystemExit("ManifestTool path must be absolute and normalized.")
resolved = os.path.realpath(value)
if resolved != value:
    raise SystemExit("ManifestTool path must contain no symlink ancestry.")
print(resolved)
PY
)" || exit 1
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

/usr/bin/python3 -I - "$MANIFEST_URL" "$PROJECT_URL" <<'PY'
import sys
from urllib.parse import urlparse

for label, value in (("Manifest URL", sys.argv[1]), ("Project URL", sys.argv[2])):
    if not value and label == "Project URL":
        continue
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit(f"{label} must use HTTPS and contain no credentials.")
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

/usr/bin/python3 -I - "$PUBLIC_KEY_PATH" "$BOOTSTRAP_MANIFEST" "$BOOTSTRAP_CORE_ARCHIVE" <<'PY'
import os
import stat
import sys

for label, value in (
    ("Public key", sys.argv[1]),
    ("Bootstrap manifest", sys.argv[2]),
    ("Bootstrap core archive", sys.argv[3]),
):
    try:
        metadata = os.lstat(value)
    except FileNotFoundError:
        raise SystemExit(f"{label} is missing: {value}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(f"{label} must be an ordinary, non-hardlinked regular file: {value}")
    if metadata.st_size == 0:
        raise SystemExit(f"{label} must not be empty: {value}")
PY

INPUT_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-inputs.XXXXXX")"
chmod 0700 "$INPUT_SNAPSHOT_DIR"
SNAPSHOT_PUBLIC_KEY="$INPUT_SNAPSHOT_DIR/public_key_ed25519.txt"
SNAPSHOT_BOOTSTRAP_MANIFEST="$INPUT_SNAPSHOT_DIR/manifest.json"
SNAPSHOT_BOOTSTRAP_CORE="$INPUT_SNAPSHOT_DIR/macos-arm64-core.zip"
install -m 0600 "$PUBLIC_KEY_PATH" "$SNAPSHOT_PUBLIC_KEY"
install -m 0600 "$BOOTSTRAP_MANIFEST" "$SNAPSHOT_BOOTSTRAP_MANIFEST"
install -m 0600 "$BOOTSTRAP_CORE_ARCHIVE" "$SNAPSHOT_BOOTSTRAP_CORE"

verify_bootstrap() {
  local public_key=$1
  local manifest=$2
  local core_archive=$3
  local args=(
    verify-bootstrap
    --manifest "$manifest"
    --public-key-file "$public_key"
    --app-version "$VERSION"
    --core-zip "$core_archive"
    --url-policy "$BOOTSTRAP_URL_POLICY"
  )
  if [ -n "$PREPARED_BOOTSTRAP_VERIFIER" ]; then
    "$PREPARED_BOOTSTRAP_VERIFIER" "${args[@]}"
  else
    /usr/bin/swift run --package-path "$ROOT/Tools/ManifestTool" ManifestTool "${args[@]}"
  fi
}
BOOTSTRAP_URL_POLICY=release
if [ "$RELEASE_MODE" = development-unsigned ]; then
  BOOTSTRAP_URL_POLICY=loopback-development
fi
verify_bootstrap \
  "$SNAPSHOT_PUBLIC_KEY" \
  "$SNAPSHOT_BOOTSTRAP_MANIFEST" \
  "$SNAPSHOT_BOOTSTRAP_CORE"

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

if [ -z "$PROJECT_URL" ]; then
  if [[ "$MANIFEST_URL" == *"/releases/"* ]]; then
    PROJECT_URL="${MANIFEST_URL%/releases/*}"
  elif [ -f "$ROOT/EasySplatApp/Resources/project_home_url.txt" ]; then
    PROJECT_URL="$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")"
  fi
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
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

# Copy direct resources used by Bundle.main
if [ -d "$ROOT/EasySplatApp/Resources" ]; then
  cp -R "$ROOT/EasySplatApp/Resources/." "$RES_DIR/"
fi
BOOTSTRAP_RES_DIR="$RES_DIR/ToolchainBootstrap"
rm -rf "$BOOTSTRAP_RES_DIR"
mkdir -p "$BOOTSTRAP_RES_DIR"
install -m 0644 "$SNAPSHOT_BOOTSTRAP_MANIFEST" "$BOOTSTRAP_RES_DIR/manifest.json"
install -m 0644 "$SNAPSHOT_BOOTSTRAP_CORE" "$BOOTSTRAP_RES_DIR/macos-arm64-core.zip"
if ! cmp -s "$SNAPSHOT_BOOTSTRAP_MANIFEST" "$BOOTSTRAP_RES_DIR/manifest.json" \
  || ! cmp -s "$SNAPSHOT_BOOTSTRAP_CORE" "$BOOTSTRAP_RES_DIR/macos-arm64-core.zip"; then
  echo "Copied bootstrap bytes changed while the app bundle was being assembled." >&2
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
printf "%s" "$MANIFEST_URL" > "$OVERRIDE_RES_DIR/toolchain_manifest_url.txt"
install -m 0644 "$SNAPSHOT_PUBLIC_KEY" "$OVERRIDE_RES_DIR/public_key_ed25519.txt"
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

BUNDLED_PUBLIC_KEY="$RES_DIR/public_key_ed25519.txt"
authority_files=("$BUNDLED_PUBLIC_KEY")
if [ -d "$RES_DIR/EasySplat_EasySplatApp.bundle" ]; then
  authority_files+=("$RES_DIR/EasySplat_EasySplatApp.bundle/public_key_ed25519.txt")
  if [ -d "$RES_DIR/EasySplat_EasySplatApp.bundle/Contents/Resources" ]; then
    authority_files+=("$RES_DIR/EasySplat_EasySplatApp.bundle/Contents/Resources/public_key_ed25519.txt")
  fi
fi
for authority_file in "${authority_files[@]}"; do
  if ! cmp -s "$SNAPSHOT_PUBLIC_KEY" "$authority_file"; then
    echo "Bundled app authority differs from the verified release input snapshot: $authority_file" >&2
    exit 1
  fi
done
verify_bootstrap "$BUNDLED_PUBLIC_KEY" \
  "$BOOTSTRAP_RES_DIR/manifest.json" \
  "$BOOTSTRAP_RES_DIR/macos-arm64-core.zip"

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
  "$CODESIGN_BIN" --force --deep --sign - --timestamp=none "$APP_BUNDLE"
  "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

echo "Built app at: $APP_BUNDLE"
echo "Preserved dSYM at: $EXPORTED_DSYM_PATH"
