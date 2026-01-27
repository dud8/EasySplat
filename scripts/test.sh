#!/usr/bin/env bash
set -euo pipefail

if command -v xcrun >/dev/null 2>&1; then
  if ! xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    echo "Xcode is required to run tests (XCTest is not available in Command Line Tools)." >&2
    exit 1
  fi
  xcrun swift test --disable-swift-testing --enable-xctest
else
  swift test --disable-swift-testing --enable-xctest
fi
