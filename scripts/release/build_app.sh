#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST_URL=""
PUBLIC_KEY_PATH=""
VERSION=""

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
  echo "Usage: build_app.sh --manifest-url <url> --public-key-path <path> --version <semver>" >&2
  exit 1
fi

if [ ! -f "$PUBLIC_KEY_PATH" ]; then
  echo "Missing public key at $PUBLIC_KEY_PATH" >&2
  exit 1
fi

MANIFEST_RESOURCE="$ROOT/EasySplatApp/Resources/toolchain_manifest_url.txt"
PUBLIC_KEY_RESOURCE="$ROOT/EasySplatApp/Resources/public_key_ed25519.txt"

ORIG_MANIFEST_TMP=""
ORIG_MANIFEST_PRESENT=0
ORIG_PUBLIC_TMP=""
ORIG_PUBLIC_PRESENT=0

if [ -f "$MANIFEST_RESOURCE" ]; then
  ORIG_MANIFEST_PRESENT=1
  ORIG_MANIFEST_TMP="$(mktemp "${TMPDIR:-/tmp}/easysplat_manifest.XXXXXX")"
  cp "$MANIFEST_RESOURCE" "$ORIG_MANIFEST_TMP"
fi

if [ -f "$PUBLIC_KEY_RESOURCE" ]; then
  ORIG_PUBLIC_PRESENT=1
  ORIG_PUBLIC_TMP="$(mktemp "${TMPDIR:-/tmp}/easysplat_public.XXXXXX")"
  cp "$PUBLIC_KEY_RESOURCE" "$ORIG_PUBLIC_TMP"
fi

cleanup() {
  if [ "$ORIG_MANIFEST_PRESENT" -eq 1 ] && [ -n "$ORIG_MANIFEST_TMP" ]; then
    cp "$ORIG_MANIFEST_TMP" "$MANIFEST_RESOURCE"
    rm -f "$ORIG_MANIFEST_TMP"
  else
    rm -f "$MANIFEST_RESOURCE"
  fi

  if [ "$ORIG_PUBLIC_PRESENT" -eq 1 ] && [ -n "$ORIG_PUBLIC_TMP" ]; then
    cp "$ORIG_PUBLIC_TMP" "$PUBLIC_KEY_RESOURCE"
    rm -f "$ORIG_PUBLIC_TMP"
  else
    rm -f "$PUBLIC_KEY_RESOURCE"
  fi
}
trap cleanup EXIT

printf "%s" "$MANIFEST_URL" > "$MANIFEST_RESOURCE"
cp "$PUBLIC_KEY_PATH" "$PUBLIC_KEY_RESOURCE"

DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Export"
BIN_PATH="$DERIVED/Build/Products/Release/EasySplatApp"
APP_BUNDLE="$OUT/EasySplat.app"
RES_DIR="$APP_BUNDLE/Contents/Resources"
LIB_DIR="$APP_BUNDLE/Contents/lib"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

rm -rf "$DERIVED" "$OUT"

xcodebuild \
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
mkdir -p "$MACOS_DIR" "$RES_DIR" "$LIB_DIR"

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

# Copy SwiftPM resource bundles (if present)
if [ -d "$DERIVED/Build/Products/Release/EasySplat_EasySplatApp.bundle" ]; then
  cp -R "$DERIVED/Build/Products/Release/EasySplat_EasySplatApp.bundle" "$RES_DIR/"
fi
if [ -d "$DERIVED/Build/Products/Release/MetalSplatter_MetalSplatter.bundle" ]; then
  cp -R "$DERIVED/Build/Products/Release/MetalSplatter_MetalSplatter.bundle" "$RES_DIR/"
fi

# Copy Sparkle framework into rpath @executable_path/../lib
if [ -d "$DERIVED/Build/Products/Release/Sparkle.framework" ]; then
  cp -R "$DERIVED/Build/Products/Release/Sparkle.framework" "$LIB_DIR/"
fi

echo "Built app at: $APP_BUNDLE"
