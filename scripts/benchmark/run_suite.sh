#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE="release"
CORPUS=""
TOOLCHAIN_ROOT="${EASYSPLAT_LOCAL_TOOLCHAIN_ROOT:-$ROOT/Toolchains/out}"
OUTPUT="$ROOT/tmp/benchmark-results"
DRY_RUN=0
EMIT_REQUESTS=""
EVIDENCE_ROOT=""
REQUEST_INDEX=""
RUNNER_IDENTITIES=()
RENDERING_DRIVER_IDENTITY=""

usage() {
  /bin/cat <<'EOF'
Usage: scripts/benchmark/run_suite.sh [options]

Options:
  --profile smoke|release   Benchmark profile (default: release)
  --corpus PATH             Corpus manifest (profile default when omitted)
  --toolchain-root PATH     Resolved EasySplat toolchain
  --output DIRECTORY        Result directory (default: tmp/benchmark-results)
  --emit-requests DIRECTORY Write bound producer requests instead of verifying
  --evidence-root DIRECTORY Read protected attestations from this separate root
  --request-index PATH      Bound protected-producer request index
  --runner-identity VALUE   Approved lane=sha256:<digest>; repeat for all lanes
  --rendering-driver-identity PATH
                            Complete identity for the built renderer closure
  --dry-run                 Validate and print the deterministic run plan
  -h, --help                Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile requires a value" >&2; exit 64; }
      PROFILE="$2"
      shift 2
      ;;
    --corpus)
      [ "$#" -ge 2 ] || { echo "--corpus requires a path" >&2; exit 64; }
      CORPUS="$2"
      shift 2
      ;;
    --toolchain-root)
      [ "$#" -ge 2 ] || { echo "--toolchain-root requires a path" >&2; exit 64; }
      TOOLCHAIN_ROOT="$2"
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a directory" >&2; exit 64; }
      OUTPUT="$2"
      shift 2
      ;;
    --emit-requests)
      [ "$#" -ge 2 ] || { echo "--emit-requests requires a value" >&2; exit 64; }
      EMIT_REQUESTS="$2"
      shift 2
      ;;
    --evidence-root)
      [ "$#" -ge 2 ] || { echo "--evidence-root requires a value" >&2; exit 64; }
      EVIDENCE_ROOT="$2"
      shift 2
      ;;
    --request-index)
      [ "$#" -ge 2 ] || { echo "--request-index requires a value" >&2; exit 64; }
      REQUEST_INDEX="$2"
      shift 2
      ;;
    --runner-identity)
      [ "$#" -ge 2 ] || { echo "--runner-identity requires a value" >&2; exit 64; }
      RUNNER_IDENTITIES+=("$2")
      shift 2
      ;;
    --rendering-driver-identity)
      [ "$#" -ge 2 ] || { echo "--rendering-driver-identity requires a value" >&2; exit 64; }
      RENDERING_DRIVER_IDENTITY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$PROFILE" in
  smoke)
    if [ -z "$CORPUS" ]; then
      CORPUS="$ROOT/scripts/benchmark/fixtures/smoke-corpus.json"
    fi
    ;;
  release)
    if [ -z "$CORPUS" ]; then
      CORPUS="$ROOT/scripts/benchmark/corpus.json"
    fi
    ;;
  *)
    echo "--profile must be smoke or release" >&2
    exit 64
    ;;
esac

arguments=(
  "$ROOT/scripts/benchmark/easysplat_benchmark.py"
  --profile "$PROFILE"
  --corpus "$CORPUS"
  --reference-config "$ROOT/scripts/benchmark/reference-config.json"
  --toolchain-root "$TOOLCHAIN_ROOT"
  --output "$OUTPUT"
)
if [ "$DRY_RUN" -eq 1 ]; then
  arguments+=(--dry-run)
fi
if [ -n "$EMIT_REQUESTS" ]; then
  arguments+=(--emit-requests "$EMIT_REQUESTS")
fi
if [ -n "$EVIDENCE_ROOT" ]; then
  arguments+=(--evidence-root "$EVIDENCE_ROOT")
fi
if [ -n "$REQUEST_INDEX" ]; then
  arguments+=(--request-index "$REQUEST_INDEX")
fi
if [ "${#RUNNER_IDENTITIES[@]}" -gt 0 ]; then
  for runner_identity in "${RUNNER_IDENTITIES[@]}"; do
    arguments+=(--runner-identity "$runner_identity")
  done
fi
if [ -n "$RENDERING_DRIVER_IDENTITY" ]; then
  arguments+=(--rendering-driver-identity "$RENDERING_DRIVER_IDENTITY")
fi

dependency_locks=("$ROOT/scripts/benchmark/requirements.txt")
if [ -n "$EVIDENCE_ROOT" ]; then
  dependency_locks+=("$ROOT/scripts/benchmark/render-requirements.txt")
fi
dependency_error="$(
  /usr/bin/env python3 - "${dependency_locks[@]}" <<'PY'
import importlib
import importlib.metadata
import re
import sys
from pathlib import Path

issues = []
for lock in map(Path, sys.argv[1:]):
    for line in lock.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z0-9_.-]+)==([^ \\]+)", line)
        if match is None:
            continue
        name, expected = match.groups()
        try:
            actual = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            actual = "missing"
        if actual != expected:
            issues.append(f"{name}: expected {expected}, found {actual}")

modules = ["cryptography", "numpy", "PIL"]
if len(sys.argv) > 2:
    modules.extend(("torch", "torchvision", "lpips"))
for module in modules:
    try:
        importlib.import_module(module)
    except Exception as error:
        issues.append(f"{module}: installed but cannot be imported ({type(error).__name__})")

if issues:
    print("\n".join(issues))
    raise SystemExit(1)
PY
)" || {
  echo "Benchmark Python dependencies are missing or do not match the lock:" >&2
  echo "$dependency_error" >&2
  echo >&2
  echo "Install the hash-locked benchmark dependencies before retrying:" >&2
  echo "  python3 -m pip install --require-hashes -r scripts/benchmark/requirements.txt" >&2
  if [ -n "$EVIDENCE_ROOT" ]; then
    echo "  python3 -m pip install --require-hashes -r scripts/benchmark/render-requirements.txt" >&2
  fi
  exit 69
}

exec /usr/bin/env python3 "${arguments[@]}"
