#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

required_files=(
  "$ROOT/LICENSE"
  "$ROOT/CONTRIBUTING.md"
  "$ROOT/SECURITY.md"
  "$ROOT/CODE_OF_CONDUCT.md"
  "$ROOT/NOTICE.md"
  "$ROOT/.github/pull_request_template.md"
  "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml"
  "$ROOT/.github/ISSUE_TEMPLATE/feature_request.yml"
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

if ! rg -n 'build_mapanything_mps\.sh' "$ROOT/.github/workflows/toolchain-build.yml" >/dev/null; then
  echo "Toolchain release workflow no longer builds MapAnything before packaging." >&2
  exit 1
fi
