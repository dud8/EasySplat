#!/usr/bin/env bash
# Source-contract assertions intentionally match literal shell and Actions expressions.
# shellcheck disable=SC1003,SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS="$ROOT/.github/workflows/tests.yml"
SECURITY="$ROOT/.github/workflows/security.yml"
CODEQL="$ROOT/.github/workflows/codeql.yml"
RELEASE_GATE="$ROOT/.github/workflows/release-app.yml"
TOOLCHAIN_GATE="$ROOT/.github/workflows/toolchain-build.yml"
BENCHMARK_GATE="$ROOT/.github/workflows/benchmark-release.yml"

fail() {
  echo "workflow contract failed: $*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing ${1#"$ROOT/"}"
}

require_text() {
  local text="$1"
  local file="$2"
  grep -Fq -- "$text" "$file" || fail "${file#"$ROOT/"} is missing: $text"
}

require_line() {
  local pattern="$1"
  local file="$2"
  grep -Eq -- "$pattern" "$file" || fail "${file#"$ROOT/"} is missing an active contract line: $pattern"
}

require_single_job() {
  local file="$1"
  local count
  count="$(awk '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z0-9_-]+:$/ { count += 1 }
    END { print count + 0 }
  ' "$file")"
  [ "$count" -eq 1 ] || fail "${file#"$ROOT/"} must contain exactly one release job"
}

require_job_count() {
  local file="$1"
  local expected="$2"
  local count
  count="$(awk '
    /^jobs:$/ { in_jobs = 1; next }
    in_jobs && /^  [A-Za-z0-9_-]+:$/ { count += 1 }
    END { print count + 0 }
  ' "$file")"
  [ "$count" -eq "$expected" ] || fail "${file#"$ROOT/"} must contain exactly $expected jobs"
}

for workflow in "$TESTS" "$SECURITY" "$CODEQL" "$RELEASE_GATE" "$TOOLCHAIN_GATE" "$BENCHMARK_GATE"; do
  require_file "$workflow"
done

for workflow in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
  [ -f "$workflow" ] || continue
  while IFS= read -r use; do
    entry="${use#*uses:}"
    entry="${entry%%#*}"
    entry="${entry//[[:space:]]/}"
    entry="${entry//\"/}"
    entry="${entry//\'/}"
    [[ "$entry" == ./* ]] && continue
    reference="${entry##*@}"
    reference="${reference%% *}"
    [[ "$entry" != "$reference" && "$reference" =~ ^[0-9a-f]{40}$ ]] \
      || fail "action or reusable workflow is not pinned to a full commit SHA: $use"
  done < <(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$workflow")
done

require_line '^    runs-on: macos-15$' "$TESTS"
require_line '^[[:space:]]+test -d /Applications/Xcode_16\.4\.app$' "$TESTS"
require_line '^[[:space:]]+test "\$\(uname -m\)" = "arm64"$' "$TESTS"
require_line '^[[:space:]]+memory_bytes="\$\(sysctl -n hw\.memsize\)"$' "$TESTS"
require_line '^[[:space:]]+swift test --filter RunPlanResolverTests$' "$TESTS"
require_text 'cache-dependency-path: scripts/benchmark/requirements.txt' "$TESTS"
require_line '^[[:space:]]+--require-hashes --requirement scripts/benchmark/requirements\.txt$' "$TESTS"
if grep -Fq 'scripts/benchmark/render-requirements.txt' "$TESTS"; then
  fail "ordinary repository tests must not install the protected render-scoring closure"
fi
require_line '^  pull_request:$' "$CODEQL"

require_line '^[[:space:]]+GOBIN=.*go install github\.com/rhysd/actionlint/cmd/actionlint@v[0-9]+\.[0-9]+\.[0-9]+$' "$SECURITY"
require_line '^[[:space:]]+.*shellcheck --severity=warning$' "$SECURITY"
require_line '^[[:space:]]+python -m pip_audit \\$' "$SECURITY"
require_line '^[[:space:]]+"\$RUNNER_TEMP/gitleaks" git --redact --no-banner .* \.$' "$SECURITY"
require_line '^[[:space:]]+- uses: actions/dependency-review-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$SECURITY"

for language in swift python c-cpp actions; do
  require_line "^[[:space:]]+- language: $language$" "$CODEQL"
done
require_line '^[[:space:]]+security-events: write$' "$CODEQL"

require_single_job "$RELEASE_GATE"
require_line '^  workflow_dispatch:$' "$RELEASE_GATE"
require_line '^    if: github\.ref == format\('\''refs/heads/\{0\}'\'', github\.event\.repository\.default_branch\)$' "$RELEASE_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-release\]$' "$RELEASE_GATE"
require_line '^    environment: public-beta-release$' "$RELEASE_GATE"
require_line '^[[:space:]]+scripts/release/build_dmg\.sh \\$' "$RELEASE_GATE"
require_line '^[[:space:]]+scripts/release/verify_beta\.sh \\$' "$RELEASE_GATE"
require_line '^[[:space:]]+scripts/release/verify_ui\.sh \\$' "$RELEASE_GATE"
require_line '^[[:space:]]+--artifacts \\$' "$RELEASE_GATE"
require_text 'EASYSPLAT_ISOLATED_UI_RUNNER: "1"' "$RELEASE_GATE"
require_text 'name: easysplat-ui-${{ github.sha }}' "$RELEASE_GATE"
require_text 'benchmark_run_id:' "$RELEASE_GATE"
require_text 'gh run download "$INPUT_BENCHMARK_RUN_ID"' "$RELEASE_GATE"
require_text '--evidence-root "$BENCHMARK_ARTIFACT/evidence"' "$RELEASE_GATE"
require_text '--evidence-key-file "$RUNNER_TEMP/evidence.key"' "$RELEASE_GATE"
require_text '--request-index "$BENCHMARK_ARTIFACT/requests/index.json"' "$RELEASE_GATE"
require_text 'GRYPE_VERSION: 0.115.0' "$RELEASE_GATE"
require_text 'GRYPE_DARWIN_ARM64_SHA256: a5faa957bca6f39e252a046b9431cd79745030c692dd400ab4c0c74266edc406' "$RELEASE_GATE"
require_text 'GRYPE_DB_REQUIRE_UPDATE_CHECK: "true"' "$RELEASE_GATE"
require_text '"$RUNNER_TEMP/grype" --config /dev/null \' "$RELEASE_GATE"
require_text '"sbom:release/DMG/EasySplat-$VERSION.spdx.json" \' "$RELEASE_GATE"
require_text '--only-fixed \' "$RELEASE_GATE"
require_line '^[[:space:]]+--fail-on high$' "$RELEASE_GATE"
spdx_validation_line="$(grep -n -m1 'name: Validate SPDX 2.3 output independently' "$RELEASE_GATE" | cut -d: -f1)"
vulnerability_scan_line="$(grep -n -m1 'name: Scan shipped SBOM for actionable vulnerabilities' "$RELEASE_GATE" | cut -d: -f1)"
draft_release_line="$(grep -n -m1 'name: Create immutable draft prerelease' "$RELEASE_GATE" | cut -d: -f1)"
test -n "$spdx_validation_line"
test -n "$vulnerability_scan_line"
test -n "$draft_release_line"
test "$spdx_validation_line" -lt "$vulnerability_scan_line"
test "$vulnerability_scan_line" -lt "$draft_release_line"
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$RELEASE_GATE"; then
  fail "public beta gate must never run pull-request code"
fi

require_single_job "$TOOLCHAIN_GATE"
require_line '^  workflow_dispatch:$' "$TOOLCHAIN_GATE"
require_line '^    if: github\.ref == format\('\''refs/heads/\{0\}'\'', github\.event\.repository\.default_branch\)$' "$TOOLCHAIN_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-release\]$' "$TOOLCHAIN_GATE"
require_line '^    environment: toolchain-release$' "$TOOLCHAIN_GATE"
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$TOOLCHAIN_GATE"; then
  fail "toolchain release must never run pull-request code"
fi

require_job_count "$BENCHMARK_GATE" 5
require_line '^  workflow_dispatch:$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-reference\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-constrained\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-8gb\]$' "$BENCHMARK_GATE"
require_line '^    environment: benchmark-release$' "$BENCHMARK_GATE"
require_text 'scripts/benchmark/render-requirements.txt' "$BENCHMARK_GATE"
base_install_count="$(grep -Fc 'name: Install protected benchmark dependencies' "$BENCHMARK_GATE")"
[ "$base_install_count" -eq 5 ] \
  || fail "all release benchmark jobs must install the base evidence dependencies"
render_install_count="$(grep -Fc 'name: Install protected render-scoring dependencies' "$BENCHMARK_GATE")"
[ "$render_install_count" -eq 2 ] \
  || fail "only reference measurement and aggregate verification may install render scoring"
for required in \
  EASYSPLAT_BENCHMARK_REFERENCE_RUNNER \
  EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER \
  EASYSPLAT_BENCHMARK_8GB_RUNNER \
  EASYSPLAT_BENCHMARK_REFERENCE_RUNNER_SHA256 \
  EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER_SHA256 \
  EASYSPLAT_BENCHMARK_8GB_RUNNER_SHA256 \
  EASYSPLAT_BENCHMARK_BASELINE_TOOLCHAIN_ROOT \
  EASYSPLAT_BENCHMARK_LPIPS_BACKBONE \
  BENCHMARK_EVIDENCE_KEY_BASE64 \
  scripts/benchmark/run_lane.py \
  reference_m4_max \
  constrained_14_16gb \
  eight_gb_fast \
  'easysplat-benchmark-${{ github.sha }}'; do
  require_text "$required" "$BENCHMARK_GATE"
done
if grep -Fq 'EASYSPLAT_BENCHMARK_RENDERING_DRIVER_SHA256' "$BENCHMARK_GATE"; then
  fail "the protected renderer identity must be derived from the exact source build"
fi
require_text '--product EasySplatBenchmarkDriver' "$BENCHMARK_GATE"
require_text 'renderer_closure.py build' "$BENCHMARK_GATE"
require_text '--rendering-driver-identity "$RENDERER_PACKAGE/identity.json"' "$BENCHMARK_GATE"
require_text 'easysplat-benchmark-renderer-${{ github.sha }}' "$BENCHMARK_GATE"
require_text '--rendering-driver-closure "$RUNNER_TEMP/renderer-package/closure"' "$BENCHMARK_GATE"
require_text '--baseline-checkout-root "$BASELINE_CHECKOUT"' "$BENCHMARK_GATE"
require_text '--baseline-toolchain-root "$BASELINE_TOOLCHAIN_ROOT"' "$BENCHMARK_GATE"
require_text '--request-index "$RUNNER_TEMP/requests/index.json"' "$BENCHMARK_GATE"
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$BENCHMARK_GATE"; then
  fail "release benchmark must never run pull-request code"
fi

for untrusted in "$TESTS" "$SECURITY" "$CODEQL"; do
  if grep -Fq '${{ secrets.' "$untrusted"; then
    fail "${untrusted#"$ROOT/"} exposes a secret to untrusted code"
  fi
done

echo "workflow contracts passed"
