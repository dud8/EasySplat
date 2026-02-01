#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
TOOLCHAIN_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --toolchain-root)
      TOOLCHAIN_ROOT="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$TOOLCHAIN_ROOT" ]; then
  TOOLCHAIN_ROOT="$HOME/Library/Application Support/EasySplat/Toolchains/$VERSION"
fi

if [ ! -x "$TOOLCHAIN_ROOT/bin/colmap" ] || \
   [ ! -x "$TOOLCHAIN_ROOT/bin/glomap" ] || \
   [ ! -x "$TOOLCHAIN_ROOT/bin/brush" ]; then
  echo "Local toolchain not found or incomplete at: $TOOLCHAIN_ROOT" >&2
  echo "Run ./scripts/dev_run.sh once to build/install the toolchain, then retry." >&2
  exit 1
fi

if head -c 2 "$TOOLCHAIN_ROOT/bin/brush" 2>/dev/null | grep -q "#!"; then
  if [ ! -x "$TOOLCHAIN_ROOT/bin/brush.real" ]; then
    echo "Local toolchain brush wrapper is missing brush.real at: $TOOLCHAIN_ROOT/bin/brush.real" >&2
    echo "Run ./scripts/dev_run.sh once to rebuild/install the toolchain, then retry." >&2
    exit 1
  fi
fi

export EASYSPLAT_LOCAL_TOOLCHAIN_ROOT="$TOOLCHAIN_ROOT"

swift run --package-path "$ROOT" EasySplatApp
