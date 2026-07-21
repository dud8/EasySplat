#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "$(uname -m)" != "arm64" ]; then
  echo "DA3 lock generation requires Apple Silicon." >&2
  exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
  echo "Install uv to update the DA3 dependency lock." >&2
  exit 1
fi

uv pip compile \
  "$ROOT/Tools/Da3Sfm/requirements.in" \
  --output-file "$ROOT/Tools/Da3Sfm/requirements.txt" \
  --python-version 3.13 \
  --generate-hashes \
  --no-annotate \
  --custom-compile-command './scripts/toolchain/update_da3_lock.sh'
