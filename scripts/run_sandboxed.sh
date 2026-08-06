#!/usr/bin/env bash
# Builds and launches EasySplat with the App Sandbox turned on, locally.
#
# `scripts/run.sh` produces a bare executable, which is never sandboxed, and a
# store-signed build cannot launch here at all because its provisioning profile
# lists no devices. Between the two there was no way to exercise sandbox
# behaviour without shipping to TestFlight and waiting for review of the build.
#
# An ad-hoc signature carrying the sandbox entitlements closes that gap: the app
# gets a real container, the real refusals, and launches straight from disk. The
# only thing it cannot reproduce is what the provisioning profile grants, which
# is the App Store identity rather than any file-system behaviour.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT/build/sandboxed"
APP="$BUILD_ROOT/Export/EasySplat.app"
VERSION="${VERSION:-0.2.0}"
SANDBOXED_BUNDLE_ID="com.easysplat.app.sandboxed"
LAUNCH=1

log() {
  printf '[sandboxed] %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/run_sandboxed.sh [--build-only]

Builds a locally runnable, app-sandboxed EasySplat and launches it.

Options:
  --build-only   Build and sign, but do not launch.
  -h, --help     Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) LAUNCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ ! -x "$ROOT/Toolchains/out/bin/colmap" ]; then
  echo "Build the toolchain first: Toolchains/out/bin/colmap is missing." >&2
  exit 1
fi

ENTITLEMENTS="$BUILD_ROOT/sandbox-app.plist"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

# The store build also claims an application identifier and a team, both of
# which need a provisioning profile. Neither affects what the sandbox allows, so
# a local build asks for the sandbox and the one grant the app relies on.
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
</dict>
</plist>
PLIST

log "Building the app bundle."
"$ROOT/scripts/release/build_app.sh" \
  --toolchain-dir "$ROOT/Toolchains/out" \
  --version "$VERSION" \
  --build-root "$BUILD_ROOT" \
  --development-unsigned

# A sandboxed app's container follows its bundle identifier. Left as the shipped
# one, this build would share Documents, preferences, and staging with an
# installed EasySplat and could scribble on real projects while it is being
# debugged. Give it an identity of its own before anything signs or launches it.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SANDBOXED_BUNDLE_ID" \
  "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName EasySplat (Sandboxed)" \
  "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName EasySplat (Sandboxed)" \
  "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

log "Signing inside out with the sandbox entitlements."
for helper in bin/colmap bin/easysplat-train; do
  /usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/scripts/release/entitlements/mas-helper-inherit.plist" \
    "$APP/Contents/Helpers/$helper"
done
/usr/bin/codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/lib/libomp.dylib"
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

# plutil -extract reads a dot as a key-path separator, so it can never name an
# entitlement key. Read the sealed document as a plist instead.
sandbox_state="$(
  /usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | /usr/bin/python3 -c '
import plistlib
import sys

payload = sys.stdin.buffer.read()
start = payload.find(b"<?xml")
end = payload.find(b"</plist>", start)
if start < 0 or end < 0:
    raise SystemExit("no entitlements")
document = plistlib.loads(payload[start : end + len(b"</plist>")])
print("true" if document.get("com.apple.security.app-sandbox") else "false")
'
)"
if [ "$sandbox_state" != "true" ]; then
  echo "The built app is not sandboxed; there is no point launching it." >&2
  exit 1
fi

built_identifier="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
)"
if [ "$built_identifier" != "$SANDBOXED_BUNDLE_ID" ]; then
  echo "Refusing to launch: this build would use the shipping app's container." >&2
  exit 1
fi

log "App: $APP"
log "Container: ~/Library/Containers/$SANDBOXED_BUNDLE_ID"
if [ "$LAUNCH" -eq 1 ]; then
  log "Launching. Watch refusals with:"
  log "  log stream --predicate 'eventMessage CONTAINS \"EasySplatApp\" AND eventMessage CONTAINS \"deny\"'"
  /usr/bin/open -n "$APP"
fi
