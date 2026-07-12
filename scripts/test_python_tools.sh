#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

python_help() {
  echo "Python bridge tests need a prepared Python with numpy, Pillow, and torch installed." >&2
  echo "Set PYTHON_BIN to that interpreter, for example:" >&2
  echo "  PYTHON_BIN=/opt/homebrew/bin/python3 ./scripts/test_python_tools.sh" >&2
}

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Python interpreter not found: $PYTHON_BIN" >&2
  python_help
  exit 1
fi

if ! "$PYTHON_BIN" - <<'PY'
import importlib.util
import sys

required_modules = {
    "numpy": "numpy",
    "PIL": "Pillow",
    "torch": "torch",
}
missing = [package for module, package in required_modules.items() if importlib.util.find_spec(module) is None]
if missing:
    sys.stderr.write("Missing Python dependencies: " + ", ".join(missing) + "\n")
    raise SystemExit(1)
PY
then
  python_help
  exit 1
fi

run_suite() {
  local pythonpath="$1"
  local module_path="$2"
  if ! PYTHONPATH="$ROOT/$pythonpath" "$PYTHON_BIN" -m unittest "$module_path"; then
    echo "Python bridge test failed: $module_path" >&2
    echo "If the failure mentions missing modules, rerun with PYTHON_BIN pointing at a prepared Python." >&2
    exit 1
  fi
}

run_suite "Tools/Da3Sfm" "Tools/Da3Sfm/tests/test_run.py"
