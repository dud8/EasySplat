#!/bin/bash
set -euo pipefail
umask 077

expected_xcode=$'Xcode 26.6\nBuild version 17F113'
expected_swift='Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)'
expected_clang='Apple clang version 21.0.0 (clang-2100.1.1.101)'
expected_metal='Apple metal version 32023.883 (metalfe-32023.883)'

test "${DEVELOPER_DIR:-}" = /Applications/Xcode.app/Contents/Developer
test -d "$DEVELOPER_DIR"
test "$(/usr/bin/uname -m)" = arm64
test "$(/usr/bin/sw_vers -productVersion)" = 26.5.2
test "$(/usr/bin/sw_vers -buildVersion)" = 25F84
test "$(/usr/bin/xcodebuild -version)" = "$expected_xcode"
test "$(/usr/bin/xcrun --sdk macosx --show-sdk-version)" = 26.5
test "$(/usr/bin/xcrun --sdk macosx --show-sdk-build-version)" = 25F70
test "$(/usr/bin/xcrun swift --version 2>/dev/null | /usr/bin/sed -n '1p')" = "$expected_swift"
test "$(/usr/bin/xcrun clang --version | /usr/bin/sed -n '1p')" = "$expected_clang"
test "$(/usr/bin/xcrun metal --version 2>&1 | /usr/bin/sed -n '1p')" = "$expected_metal"

while (($# > 0)); do
  case "$1" in
    --binary)
      test "$#" -ge 2
      binary=$2
      shift 2
      test -f "$binary"
      test ! -L "$binary"
      test "$(/usr/bin/lipo -archs "$binary")" = arm64
      build=$(/usr/bin/vtool -show-build "$binary")
      test "$(printf '%s\n' "$build" | /usr/bin/grep -Ec '^[[:space:]]+platform MACOS$')" = 1
      test "$(printf '%s\n' "$build" | /usr/bin/grep -Ec '^[[:space:]]+minos 15\.0$')" = 1
      test "$(printf '%s\n' "$build" | /usr/bin/grep -Ec '^[[:space:]]+sdk 26\.5$')" = 1
      ;;
    *)
      printf 'error: unsupported shipping-host argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
