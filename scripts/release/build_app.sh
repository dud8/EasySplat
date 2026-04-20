#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_URL=""
PUBLIC_KEY_PATH=""
PROJECT_URL=""
VERSION=""
XCODEBUILD_BIN="${EASYSPLAT_XCODEBUILD_BIN:-xcodebuild}"

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
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$MANIFEST_URL" ] || [ -z "$PUBLIC_KEY_PATH" ] || [ -z "$VERSION" ]; then
  echo "Usage: build_app.sh --manifest-url <url> --public-key-path <path> --version <semver> [--project-url <url>]" >&2
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

DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Export"
BIN_PATH="$DERIVED/Build/Products/Release/EasySplatApp"
APP_BUNDLE="$OUT/EasySplat.app"
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
  build

if [ ! -f "$BIN_PATH" ]; then
  echo "Missing built binary at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/EasySplatApp"
chmod +x "$MACOS_DIR/EasySplatApp"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>EasySplatApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.easysplat.app</string>
  <key>CFBundleName</key>
  <string>EasySplat</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

# Copy direct resources used by Bundle.main
if [ -d "$ROOT/EasySplatApp/Resources" ]; then
  cp -R "$ROOT/EasySplatApp/Resources/." "$RES_DIR/"
fi

mkdir -p "$OVERRIDE_RES_DIR"
printf "%s" "$MANIFEST_URL" > "$OVERRIDE_RES_DIR/toolchain_manifest_url.txt"
cp "$PUBLIC_KEY_PATH" "$OVERRIDE_RES_DIR/public_key_ed25519.txt"
printf "%s" "$PROJECT_URL" > "$OVERRIDE_RES_DIR/project_home_url.txt"
cp -R "$OVERRIDE_RES_DIR/." "$RES_DIR/"

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

echo "Built app at: $APP_BUNDLE"
