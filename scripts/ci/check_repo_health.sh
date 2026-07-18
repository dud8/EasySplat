#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  echo "Repo health requires ripgrep (rg); install it and rerun this check." >&2
  exit 1
fi

required_files=(
  "$ROOT/LICENSE"
  "$ROOT/CONTRIBUTING.md"
  "$ROOT/SECURITY.md"
  "$ROOT/CODE_OF_CONDUCT.md"
  "$ROOT/NOTICE.md"
  "$ROOT/.github/pull_request_template.md"
  "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml"
  "$ROOT/.github/ISSUE_TEMPLATE/feature_request.yml"
  "$ROOT/scripts/benchmark/run_suite.sh"
  "$ROOT/scripts/benchmark/easysplat_benchmark.py"
  "$ROOT/scripts/benchmark/evidence_protocol.py"
  "$ROOT/scripts/benchmark/run_lane.py"
  "$ROOT/scripts/benchmark/prepare_evidence.py"
  "$ROOT/scripts/benchmark/aggregate_evidence.py"
  "$ROOT/scripts/benchmark/result.schema.json"
  "$ROOT/scripts/benchmark/evidence.schema.json"
  "$ROOT/scripts/benchmark/corpus.json"
  "$ROOT/scripts/benchmark/reference-config.json"
  "$ROOT/scripts/benchmark/tests/test_benchmark.py"
  "$ROOT/scripts/benchmark/tests/test_aggregate_evidence.py"
  "$ROOT/scripts/release/verify_publication_bundle.py"
  "$ROOT/scripts/release/tests/test_verify_publication_bundle.py"
  "$ROOT/scripts/toolchain/validate_da3_payload.py"
  "$ROOT/scripts/toolchain/tests/test_da3_payload.py"
  "$ROOT/.github/workflows/benchmark-release.yml"
)

for path in "${required_files[@]}"; do
  if [ ! -f "$path" ]; then
    echo "Missing required public repo file: $path" >&2
    exit 1
  fi
done

public_text_files=(
  "$ROOT/README.md"
  "$ROOT/CONTRIBUTING.md"
  "$ROOT/SECURITY.md"
  "$ROOT/CODE_OF_CONDUCT.md"
  "$ROOT/NOTICE.md"
  "$ROOT/ONBOARDING.md"
  "$ROOT/.github/pull_request_template.md"
  "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml"
  "$ROOT/.github/ISSUE_TEMPLATE/feature_request.yml"
)

# The final alternative intentionally matches a Windows path prefix.
# shellcheck disable=SC1003
if rg -n '/Users/|/home/|C:\\\\' "${public_text_files[@]}" >/dev/null; then
  echo "Public repo docs/templates contain machine-specific absolute paths." >&2
  exit 1
fi

if rg -n -- '(^|[[:space:]])--private-key([[:space:]]|=)' "${public_text_files[@]}" >/dev/null; then
  echo "Public repo docs/templates pass private keys inline; use --private-key-file or --private-key-env instead." >&2
  exit 1
fi

if rg -n 'sparkle-project/Sparkle|Sparkle.framework' \
  "$ROOT/Package.swift" \
  "$ROOT/scripts/release/build_app.sh" >/dev/null; then
  echo "Dormant Sparkle references remain in first-party build metadata." >&2
  exit 1
fi

if rg -n 'github.com/EasySplat/EasySplat|http://localhost:8000' \
  "$ROOT/EasySplatApp/AppConfig.swift" \
  "$ROOT/EasySplatApp/AppModel.swift" \
  "$ROOT/EasySplatApp/Resources" >/dev/null; then
  echo "Shipped app sources/resources contain a stale or localhost release default." >&2
  exit 1
fi

if rg -n 'activate\s*\(\s*ignoringOtherApps\s*:' "$ROOT/EasySplatApp" >/dev/null; then
  echo "Shipped app sources use the deprecated focus-stealing activation API." >&2
  exit 1
fi

toolchain_workflow="$ROOT/.github/workflows/toolchain-build.yml"
for builder in \
  build_colmap_support.sh \
  build_ceres.sh \
  build_openimageio.sh \
  build_colmap.sh \
  build_msplat.sh \
  build_da3_mps.sh; do
  if ! rg -n "scripts/toolchain/$builder" "$toolchain_workflow" >/dev/null; then
    echo "Toolchain workflow no longer runs required builder $builder: $toolchain_workflow" >&2
    exit 1
  fi
done

if rg -n 'scripts/toolchain/build_suitesparse\.sh' "$toolchain_workflow" >/dev/null; then
  echo "Toolchain workflow restored retired native SuiteSparse builder: $toolchain_workflow" >&2
  exit 1
fi

python3 - "$toolchain_workflow" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
builders = [
    "build_colmap_support.sh",
    "build_ceres.sh",
    "build_openimageio.sh",
    "build_colmap.sh",
    "build_msplat.sh",
    "build_da3_mps.sh",
    "package_toolchain.sh",
]
positions = [workflow.index(f"scripts/toolchain/{builder}") for builder in builders]
if positions != sorted(positions):
    raise SystemExit("Toolchain workflow build order is not the reviewed native release order.")
PY

for retired_source in \
  "$ROOT/Tools/Da3Sfm/colmap_launcher.c" \
  "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm/colmap_cli.py" \
  "$ROOT/Tools/Da3Sfm/tests/test_colmap_cli.py"; do
  if [ -e "$retired_source" ]; then
    echo "Retired DA3 Python COLMAP bridge source still exists: $retired_source" >&2
    exit 1
  fi
done
if rg -n 'pycolmap|PYCOLMAP|easysplat_colmap|colmap_launcher|colmap_cli\.py|--self-check' \
  "$ROOT/Tools/Da3Sfm/requirements.in" \
  "$ROOT/Tools/Da3Sfm/requirements.txt" \
  "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm" \
  "$ROOT/scripts/toolchain/build_da3_mps.sh" \
  "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "Release runtime retains a retired DA3 Python COLMAP bridge surface." >&2
  exit 1
fi

if rg -n 'brew install .*\b(suitesparse|ceres-solver|cgal|freeimage|qt)\b' \
  "$ROOT/.github/workflows/toolchain-build.yml" >/dev/null; then
  echo "Toolchain workflow installs a forbidden prebuilt or disabled COLMAP dependency." >&2
  exit 1
fi

legacy_runtime_pattern='brush|mapanything|fastvggt|vggt|glomap'
for path in \
  "$ROOT/scripts/toolchain/package_toolchain.sh" \
  "$ROOT/scripts/run.sh" \
  "$ROOT/scripts/release/build_dmg.sh" \
  "$ROOT/.github/workflows/toolchain-build.yml"; do
  if rg -n -i "$legacy_runtime_pattern" "$path" >/dev/null; then
    echo "Release path still references a removed runtime: $path" >&2
    exit 1
  fi
done

for contract in \
  "case \"\${EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE:-0}\" in" \
  '""|0|false|FALSE|no|NO|off|OFF) ;;' \
  'scripts/toolchain/build_da3_mps.sh'; do
  if ! rg -n -F "$contract" "$toolchain_workflow" >/dev/null; then
    echo "Toolchain workflow no longer rejects unpinned DA3 source overrides: $toolchain_workflow" >&2
    exit 1
  fi
done

if rg -n '(^|[^A-Za-z0-9_])(xformers|flash[-_]attn|triton|torch[-_]scatter)([^A-Za-z0-9_]|$)' \
  "$ROOT/Tools/Da3Sfm" \
  "$ROOT/scripts/toolchain/build_da3_mps.sh" >/dev/null; then
  echo "DA3 default path references a banned CUDA-oriented dependency." >&2
  exit 1
fi

if rg -n 'DA3-(LARGE|GIANT)|DA3-NESTED|DA3NESTED|DA3-GIANT|DA3-LARGE|CC-BY-NC' \
  "$ROOT/Tools/Da3Sfm" \
  "$ROOT/scripts/toolchain/build_da3_mps.sh" \
  "$ROOT/README.md" \
  "$ROOT/ONBOARDING.md" >/dev/null; then
  echo "DA3 default path references non-commercial weights." >&2
  exit 1
fi

if rg -n -i 'global_mapper|globalmapper|global mapper' \
  "$ROOT/EasySplatCore/Sources" \
  "$ROOT/EasySplatApp" \
  "$ROOT/scripts/toolchain/build_colmap.sh" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "The rejected COLMAP global-mapper candidate remains in a runtime surface." >&2
  exit 1
fi

if git -C "$ROOT" ls-files scripts/benchmark | rg '(^|/)suite\.json$|(^|/)raw/|\.(mov|mp4|m4v|heic|jpe?g|png|tiff?)$' >/dev/null; then
  echo "Generated benchmark results or corpus media are tracked in Git." >&2
  exit 1
fi

python3 -m unittest discover -s "$ROOT/scripts/benchmark/tests" -p 'test_*.py' >/dev/null
python3 "$ROOT/scripts/toolchain/tests/test_da3_payload.py" >/dev/null
"$ROOT/scripts/benchmark/run_suite.sh" --profile release --dry-run >/dev/null
