#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BASELINE="$ROOT/scripts/ci/release_reliability_m4_max_baseline.json"
WORKSPACE="/private/tmp"
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: scripts/ci/run_release_reliability_product_gate.sh [options]

Options:
  --baseline PATH   Host-bound performance baseline.
  --workspace PATH  Existing private workspace for temporary fixtures.
  --output PATH     Write canonical gate evidence to a new file.
  -h, --help        Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline)
      [ "$#" -ge 2 ] || { echo "Missing value for --baseline" >&2; exit 2; }
      BASELINE="$2"
      shift 2
      ;;
    --workspace)
      [ "$#" -ge 2 ] || { echo "Missing value for --workspace" >&2; exit 2; }
      WORKSPACE="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo "Missing value for --output" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

(
  cd "$ROOT"
  xcrun swift build -c release \
    -Xswiftc -DDEBUG \
    -Xswiftc -enable-testing \
    --build-tests \
    --disable-swift-testing \
    --enable-xctest
)

BIN_PATH="$(
  cd "$ROOT"
  xcrun swift build -c release -Xswiftc -DDEBUG --show-bin-path
)"
TEST_BINARY="$BIN_PATH/EasySplatPackageTests.xctest/Contents/MacOS/EasySplatPackageTests"

arguments=(
  --workspace "$WORKSPACE"
  --baseline "$BASELINE"
  --test-binary "$TEST_BINARY"
)
if [ -n "$OUTPUT" ]; then
  arguments+=(--output "$OUTPUT")
fi

exec /usr/bin/python3 -I \
  "$ROOT/scripts/ci/release_reliability_fixtures.py" product-gate \
  "${arguments[@]}"
