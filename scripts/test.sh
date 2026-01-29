#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_BASE="$ROOT/build/.swiftpm"

mkdir -p "$CACHE_BASE/cache" "$CACHE_BASE/configuration" "$CACHE_BASE/security" "$CACHE_BASE/clang-module-cache"

export SWIFTPM_CACHE_PATH="$CACHE_BASE/cache"
export SWIFTPM_CONFIG_PATH="$CACHE_BASE/configuration"
export SWIFTPM_SECURITY_PATH="$CACHE_BASE/security"
export CLANG_MODULE_CACHE_PATH="$CACHE_BASE/clang-module-cache"

if command -v xcrun >/dev/null 2>&1; then
  if ! xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    echo "Xcode is required to run tests (XCTest is not available in Command Line Tools)." >&2
    exit 1
  fi
  xcrun swift test --disable-swift-testing --enable-xctest
else
  swift test --disable-swift-testing --enable-xctest
fi
