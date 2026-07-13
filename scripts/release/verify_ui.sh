#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release/verify_ui.sh --app /absolute/path/EasySplat.app --output-dir /absolute/path/ui-verification

Runs the packaged-app Home, Processing, Result, and Failure UI release gate at every supported
verification size. It changes global keyboard and accessibility preferences temporarily,
so EASYSPLAT_ISOLATED_UI_RUNNER=1 is required. Run it only from the dedicated interactive
macOS 15 arm64/Xcode 16.4 release account. The built EasySplatUIVerifier executable needs
Accessibility and Screen Recording permission.
EOF
}

APP_PATH=""
OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      APP_PATH=$2
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT_DIR=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$APP_PATH" && -n "$OUTPUT_DIR" ]] || { usage >&2; exit 2; }
[[ "$APP_PATH" = /* && "$OUTPUT_DIR" = /* ]] || {
  printf 'error: --app and --output-dir must be absolute paths.\n' >&2
  exit 2
}
[[ "${EASYSPLAT_ISOLATED_UI_RUNNER:-}" == "1" ]] || {
  printf 'error: EASYSPLAT_ISOLATED_UI_RUNNER=1 is required; this gate changes global user preferences.\n' >&2
  exit 1
}
[[ -d "$APP_PATH" && "${APP_PATH##*.}" == "app" ]] || {
  printf 'error: packaged app not found: %s\n' "$APP_PATH" >&2
  exit 1
}
[[ ! -L "$APP_PATH" ]] || {
  printf 'error: --app must not be a symbolic link: %s\n' "$APP_PATH" >&2
  exit 1
}
if [[ -e "$OUTPUT_DIR" && ( ! -d "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ) ]]; then
  printf 'error: --output-dir must be a plain directory: %s\n' "$OUTPUT_DIR" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" && ! -L "$INFO_PLIST" ]] || {
  printf 'error: packaged app Info.plist is missing or unsafe: %s\n' "$INFO_PLIST" >&2
  exit 1
}
APP_EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")
BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
[[ "$APP_EXECUTABLE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'error: packaged app has an invalid CFBundleExecutable.\n' >&2
  exit 1
}
[[ "$BUNDLE_IDENTIFIER" == "com.easysplat.app" ]] || {
  printf 'error: packaged app bundle identifier must be com.easysplat.app.\n' >&2
  exit 1
}
APP_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
[[ -f "$APP_EXECUTABLE_PATH" && -x "$APP_EXECUTABLE_PATH" && ! -L "$APP_EXECUTABLE_PATH" ]] || {
  printf 'error: packaged app executable is missing or unsafe: %s\n' "$APP_EXECUTABLE_PATH" >&2
  exit 1
}
if /usr/bin/pgrep -x "$APP_EXECUTABLE_NAME" >/dev/null 2>&1; then
  printf 'error: %s is already running; the isolated UI lane must start clean.\n' "$APP_EXECUTABLE_NAME" >&2
  exit 1
fi

architecture=$(uname -m)
macos_version=$(sw_vers -productVersion)
xcode_line=$(xcodebuild -version | sed -n '1p')
xcode_version=${xcode_line#Xcode }
[[ "$architecture" == "arm64" ]] || {
  printf 'error: UI verification requires arm64, found %s.\n' "$architecture" >&2
  exit 1
}
[[ "${macos_version%%.*}" == "15" ]] || {
  printf 'error: UI verification requires macOS 15.x, found %s.\n' "$macos_version" >&2
  exit 1
}
[[ "$xcode_version" == "16.4" ]] || {
  printf 'error: UI verification requires Xcode 16.4, found %s.\n' "$xcode_version" >&2
  exit 1
}
[[ "$(stat -f '%Su' /dev/console)" == "$(id -un)" ]] || {
  printf 'error: UI verification requires an interactive console session owned by the current account.\n' >&2
  exit 1
}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
rm -rf "$OUTPUT_DIR/results" "$OUTPUT_DIR/screenshots"
mkdir -p "$OUTPUT_DIR/results" "$OUTPUT_DIR/screenshots"

swift build --package-path "$ROOT_DIR" -c release --product EasySplatUIVerifier
BIN_DIR=$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)
VERIFIER="$BIN_DIR/EasySplatUIVerifier"
[[ -x "$VERIFIER" ]] || {
  printf 'error: verifier executable was not built: %s\n' "$VERIFIER" >&2
  exit 1
}

PREFERENCE_BACKUP=$(mktemp -d "${TMPDIR:-/tmp}/easysplat-ui-preferences.XXXXXX")
defaults export NSGlobalDomain "$PREFERENCE_BACKUP/global.plist" >/dev/null
defaults export com.apple.universalaccess "$PREFERENCE_BACKUP/universalaccess.plist" >/dev/null

restore_preferences() {
  status=$?
  trap - EXIT
  set +e
  terminate_packaged_app
  rm -rf "$OUTPUT_DIR/screenshots"/harness-home-*
  defaults import NSGlobalDomain "$PREFERENCE_BACKUP/global.plist" >/dev/null
  defaults import com.apple.universalaccess "$PREFERENCE_BACKUP/universalaccess.plist" >/dev/null
  killall cfprefsd >/dev/null 2>&1
  rm -rf "$PREFERENCE_BACKUP"
  exit "$status"
}
trap restore_preferences EXIT
trap 'exit 130' INT TERM

terminate_packaged_app() {
  /usr/bin/pkill -TERM -x "$APP_EXECUTABLE_NAME" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    /usr/bin/pgrep -x "$APP_EXECUTABLE_NAME" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  /usr/bin/pkill -KILL -x "$APP_EXECUTABLE_NAME" >/dev/null 2>&1 || true
}

configure_scenario() {
  scenario=$1
  defaults write NSGlobalDomain AppleKeyboardUIMode -int 3
  defaults write com.apple.universalaccess reduceMotion -bool false
  defaults write com.apple.universalaccess increaseContrast -bool false
  defaults write com.apple.universalaccess differentiateWithoutColor -bool false
  case "$scenario" in
    dark|light)
      ;;
    reduce-motion)
      defaults write com.apple.universalaccess reduceMotion -bool true
      ;;
    increase-contrast)
      defaults write com.apple.universalaccess increaseContrast -bool true
      ;;
    differentiate-without-color)
      defaults write com.apple.universalaccess differentiateWithoutColor -bool true
      ;;
    *)
      printf 'error: unsupported scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac
  killall cfprefsd >/dev/null 2>&1 || true
  sleep 2
}

export EASYSPLAT_UI_RUNNER_ARCHITECTURE=$architecture
export EASYSPLAT_UI_RUNNER_MACOS_VERSION=$macos_version
export EASYSPLAT_UI_RUNNER_XCODE_VERSION=$xcode_version

failed=0
result_arguments=()
for scenario in light dark reduce-motion increase-contrast differentiate-without-color; do
  configure_scenario "$scenario"
  result="$OUTPUT_DIR/results/$scenario.json"
  screenshots="$OUTPUT_DIR/screenshots/$scenario"
  mkdir "$screenshots"
  rm -f "$result"
  if ! "$VERIFIER" run \
    --app "$APP_PATH" \
    --scenario "$scenario" \
    --output "$result" \
    --screenshots "$screenshots"; then
    if [[ ! -s "$result" ]]; then
      printf 'error: %s scenario failed before producing a result; permissions or launch setup are unavailable.\n' "$scenario" >&2
      exit 1
    fi
    failed=1
  fi
  terminate_packaged_app
  result_arguments+=(--result "$result")
done

if ! "$VERIFIER" summarize \
  "${result_arguments[@]}" \
  --output "$OUTPUT_DIR/ui-suite.json"; then
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  printf 'error: packaged-app UI verification failed; inspect %s.\n' "$OUTPUT_DIR" >&2
  exit 1
fi
printf 'Packaged-app UI verification passed: %s\n' "$OUTPUT_DIR/ui-suite.json"
