#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible alias for the dev runner script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/dev_run.sh" "$@"

