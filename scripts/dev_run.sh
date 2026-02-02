#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible alias for the unified dev runner.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run.sh" "$@"
