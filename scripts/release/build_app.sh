#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_URL=""
PUBLIC_KEY_PATH=""
PROJECT_URL=""
VERSION=""
RELEASE_MODE=""
BUILD_ROOT="$ROOT/build"
XCODEBUILD_BIN="${EASYSPLAT_XCODEBUILD_BIN:-xcodebuild}"
CODESIGN_BIN="${EASYSPLAT_CODESIGN_BIN:-codesign}"

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
    --build-root)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        echo "--build-root requires an absolute path." >&2
        exit 1
      fi
      BUILD_ROOT="$2"
      shift 2
      ;;
    --unsigned-beta)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      RELEASE_MODE="unsigned-beta"
      shift
      ;;
    --production)
      if [ -n "$RELEASE_MODE" ]; then
        echo "Choose exactly one release mode." >&2
        exit 1
      fi
      echo "Production app builds are not available until signing, notarization, Gatekeeper, and clean-Mac installation gates are complete." >&2
      exit 1
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$MANIFEST_URL" ] || [ -z "$PUBLIC_KEY_PATH" ] || [ -z "$VERSION" ] || [ -z "$RELEASE_MODE" ]; then
  echo "Usage: build_app.sh --manifest-url <url> --public-key-path <path> --version <semver> [--project-url <url>] [--build-root <absolute-path>] --unsigned-beta" >&2
  exit 1
fi

validated_build_root="$(python3 - "$BUILD_ROOT" "$ROOT" <<'PY'
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

python3 - "$MANIFEST_URL" "$PROJECT_URL" <<'PY'
import sys
from urllib.parse import urlparse

for label, value in (("Manifest URL", sys.argv[1]), ("Project URL", sys.argv[2])):
    if not value and label == "Project URL":
        continue
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit(f"{label} must use HTTPS and contain no credentials.")
PY

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
if ! [[ "$VERSION" =~ $SEMVER_RE ]]; then
  echo "Invalid app semantic version: $VERSION" >&2
  exit 1
fi

NUMERIC_VERSION="${VERSION%%+*}"
NUMERIC_VERSION="${NUMERIC_VERSION%%-*}"
if [[ "$VERSION" != *-* ]]; then
  echo "Unsigned public beta versions must include a prerelease suffix." >&2
  exit 1
fi

if [ ! -f "$PUBLIC_KEY_PATH" ]; then
  echo "Missing public key at $PUBLIC_KEY_PATH" >&2
  exit 1
fi

if [ "${XCODEBUILD_BIN##*/}" = "xcodebuild" ]; then
  if ! "$XCODEBUILD_BIN" -license check >/dev/null 2>&1; then
    echo "Xcode license not accepted. Run: sudo xcodebuild -license accept" >&2
    exit 1
  fi
fi

if [ "${EASYSPLAT_SKIP_METAL_TOOLCHAIN_CHECK:-}" != "1" ] && [ "${XCODEBUILD_BIN##*/}" = "xcodebuild" ]; then
  if ! xcrun -sdk macosx metal -v >/dev/null 2>&1; then
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
printf '%s\n' "$$" >"$BUILD_LOCK/pid"
release_build_lock() {
  rm -f "$BUILD_LOCK/pid"
  rmdir "$BUILD_LOCK" 2>/dev/null || true
}
trap release_build_lock EXIT

DERIVED="$BUILD_ROOT/DerivedData"
OUT="$BUILD_ROOT/Export"
BIN_PATH="$DERIVED/Build/Products/Release/EasySplatApp"
BUILT_DSYM_PATH="$DERIVED/Build/Products/Release/EasySplatApp.dSYM"
APP_BUNDLE="$OUT/EasySplat.app"
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
  <string>$RELEASE_MODE</string>
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
cp "$PUBLIC_KEY_PATH" "$OVERRIDE_RES_DIR/public_key_ed25519.txt"
printf "%s" "$PROJECT_URL" > "$OVERRIDE_RES_DIR/project_home_url.txt"
cp -R "$OVERRIDE_RES_DIR/." "$RES_DIR/"
printf '%s' 'unsigned public beta' >"$RES_DIR/release_channel.txt"

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
"$CODESIGN_BIN" --force --deep --sign - --timestamp=none "$APP_BUNDLE"
"$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Built app at: $APP_BUNDLE"
echo "Preserved dSYM at: $EXPORTED_DSYM_PATH"
