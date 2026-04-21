#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

run_suite() {
  local pythonpath="$1"
  local module_path="$2"
  PYTHONPATH="$ROOT/$pythonpath" "$PYTHON_BIN" -m unittest "$module_path"
}

run_suite "Tools/MapAnythingSfm" "Tools/MapAnythingSfm/tests/test_run.py"
run_suite "Tools/FastVggtSfm" "Tools/FastVggtSfm/easysplat_fastvggt_sfm/tests/test_strict_coverage.py"
run_suite "Tools/VggtSfm" "Tools/VggtSfm/tests/test_run.py"
