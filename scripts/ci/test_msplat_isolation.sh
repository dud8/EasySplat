#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_SOURCE="$ROOT/Tools/MsplatNative/isolation_tests.cpp"
IMPLEMENTATION="$ROOT/Tools/MsplatNative/isolation.cpp"
INCLUDE_ROOT="$ROOT/Tools/MsplatNative"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-isolation-tests.XXXXXX")"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

xcrun clang++ \
  -std=c++17 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$INCLUDE_ROOT" \
  "$TEST_SOURCE" \
  "$IMPLEMENTATION" \
  -o "$BUILD_DIR/isolation-tests"

"$BUILD_DIR/isolation-tests"
