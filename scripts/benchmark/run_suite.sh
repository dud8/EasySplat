#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE="release"
CORPUS=""
TOOLCHAIN_ROOT="${EASYSPLAT_LOCAL_TOOLCHAIN_ROOT:-$ROOT/Toolchains/out}"
OUTPUT="$ROOT/tmp/benchmark-results"
DRY_RUN=0
EVIDENCE_KEY_FILE=""
EMIT_REQUESTS=""
EVIDENCE_ROOT=""
REQUEST_INDEX=""
RUNNER_IDENTITIES=()

usage() {
  /bin/cat <<'EOF'
Usage: scripts/benchmark/run_suite.sh [options]

Options:
  --profile smoke|release   Benchmark profile (default: release)
  --corpus PATH             Corpus manifest (profile default when omitted)
  --toolchain-root PATH     Resolved EasySplat toolchain
  --output DIRECTORY        Result directory (default: tmp/benchmark-results)
  --evidence-key-file PATH  Protected release-evidence authentication key
  --emit-requests DIRECTORY Write bound producer requests instead of verifying
  --evidence-root DIRECTORY Read protected attestations from this separate root
  --request-index PATH      Bound protected-producer request index
  --runner-identity VALUE   Approved lane=sha256:<digest>; repeat for all lanes
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
    --evidence-key-file)
      [ "$#" -ge 2 ] || { echo "--evidence-key-file requires a value" >&2; exit 64; }
      EVIDENCE_KEY_FILE="$2"
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
if [ -n "$EVIDENCE_KEY_FILE" ]; then
  arguments+=(--evidence-key-file "$EVIDENCE_KEY_FILE")
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

exec /usr/bin/env python3 "${arguments[@]}"
