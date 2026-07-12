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
  "$ROOT/scripts/benchmark/result.schema.json"
  "$ROOT/scripts/benchmark/corpus.json"
  "$ROOT/scripts/benchmark/reference-config.json"
  "$ROOT/scripts/benchmark/tests/test_benchmark.py"
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

if rg -n 'github.com/dud8/EasySplat|http://localhost:8000' \
  "$ROOT/EasySplatApp/AppConfig.swift" \
  "$ROOT/EasySplatApp/AppModel.swift" \
  "$ROOT/EasySplatApp/Resources" >/dev/null; then
  echo "Shipped app sources/resources still contain personal or localhost defaults." >&2
  exit 1
fi

for path in "$ROOT/scripts/release/build_dmg.sh" "$ROOT/.github/workflows/toolchain-build.yml"; do
  for builder in build_colmap.sh build_openssl.sh build_msplat.sh build_da3_mps.sh; do
    if ! rg -n "scripts/toolchain/$builder" "$path" >/dev/null; then
      echo "Release path no longer runs required toolchain builder $builder: $path" >&2
      exit 1
    fi
  done
done

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

for path in "$ROOT/scripts/release/build_dmg.sh" "$ROOT/.github/workflows/toolchain-build.yml"; do
  if ! rg -n 'refuses EASYSPLAT_ALLOW_UNPINNED_DA3_SOURCE' "$path" >/dev/null; then
    echo "Release path no longer rejects unpinned DA3 source overrides: $path" >&2
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

if git -C "$ROOT" ls-files scripts/benchmark | rg '(^|/)suite\.json$|(^|/)raw/|\.(mov|mp4|m4v|heic|jpe?g|png|tiff?)$' >/dev/null; then
  echo "Generated benchmark results or corpus media are tracked in Git." >&2
  exit 1
fi

python3 -m unittest discover -s "$ROOT/scripts/benchmark/tests" -p 'test_*.py' >/dev/null
"$ROOT/scripts/benchmark/run_suite.sh" --profile release --dry-run >/dev/null
