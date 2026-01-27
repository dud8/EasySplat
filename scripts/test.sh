#!/usr/bin/env bash
set -euo pipefail

if command -v xcrun >/dev/null 2>&1; then
  xcrun swift test --allow-unsafe-flags
else
  swift test --allow-unsafe-flags
fi
