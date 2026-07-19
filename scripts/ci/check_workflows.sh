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
require_job_count "$CODEQL" 4

require_line '^[[:space:]]+GOBIN=.*go install github\.com/rhysd/actionlint/cmd/actionlint@v[0-9]+\.[0-9]+\.[0-9]+$' "$SECURITY"
require_line '^[[:space:]]+.*shellcheck --severity=warning$' "$SECURITY"
require_line '^[[:space:]]+python -m pip_audit \\$' "$SECURITY"
require_line '^[[:space:]]+"\$RUNNER_TEMP/gitleaks" git --redact --no-banner .* \.$' "$SECURITY"
require_line '^[[:space:]]+- uses: actions/dependency-review-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$SECURITY"

for language in swift python c-cpp actions; do
  require_line "^  analyze-$language:$" "$CODEQL"
  require_line "^[[:space:]]+name: Analyze $language$" "$CODEQL"
  require_line "^[[:space:]]+languages: $language$" "$CODEQL"
  require_line "^[[:space:]]+category: /language:$language$" "$CODEQL"
done
if grep -Fq '${{ matrix.' "$CODEQL"; then
  fail "CodeQL required-check identities must not depend on matrix expansion"
fi
require_line '^[[:space:]]+security-events: write$' "$CODEQL"

require_job_count "$RELEASE_GATE" 3
require_line '^  workflow_dispatch:$' "$RELEASE_GATE"
require_line '^    if: github\.ref == '\''refs/heads/main'\'' && github\.event\.repository\.default_branch == '\''main'\''$' "$RELEASE_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-release, easysplat-ephemeral\]$' "$RELEASE_GATE"
require_line '^    runs-on: macos-15$' "$RELEASE_GATE"
require_line '^    environment: public-beta-verification$' "$RELEASE_GATE"
require_line '^    environment: public-beta-release$' "$RELEASE_GATE"
require_line '^[[:space:]]+scripts/release/build_dmg\.sh \\$' "$RELEASE_GATE"
require_line '^[[:space:]]+scripts/release/verify_beta\.sh \\$' "$RELEASE_GATE"
require_line '^[[:space:]]+scripts/release/verify_ui\.sh \\$' "$RELEASE_GATE"
require_line '^[[:space:]]+--artifacts \\$' "$RELEASE_GATE"
require_text 'EASYSPLAT_ISOLATED_UI_RUNNER: "1"' "$RELEASE_GATE"
require_text 'name: easysplat-ui-${{ github.sha }}' "$RELEASE_GATE"
require_text 'benchmark_run_id:' "$RELEASE_GATE"
require_text 'artifact-ids: ${{ steps.benchmark-identity.outputs.artifact_id }}' "$RELEASE_GATE"
require_text 'scripts/benchmark/aggregate_evidence.py' "$RELEASE_GATE"
require_text 'scripts/release/verify_publication_bundle.py create-build-closure' "$RELEASE_GATE"
require_text 'scripts/release/verify_publication_bundle.py verify-build' "$RELEASE_GATE"
require_text 'build_artifact_id:' "$RELEASE_GATE"
require_text 'build_artifact_digest:' "$RELEASE_GATE"
require_text 'benchmark_artifact_id:' "$RELEASE_GATE"
require_text 'benchmark_artifact_digest:' "$RELEASE_GATE"
require_text 'publication_artifact_id:' "$RELEASE_GATE"
require_text 'publication_artifact_digest:' "$RELEASE_GATE"
require_text 'source scripts/release/lib/strict_semver.sh' "$RELEASE_GATE"
require_text 'easysplat_is_strict_semver_prerelease_without_build_metadata' "$RELEASE_GATE"
require_text 'secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN' "$RELEASE_GATE"
require_text 'repos/$GITHUB_REPOSITORY/immutable-releases' "$RELEASE_GATE"
if grep -Fq 'EASYSPLAT_IMMUTABLE_RELEASES_ENABLED' "$RELEASE_GATE"; then
  fail "immutable release enforcement must query GitHub instead of trusting a repository variable"
fi
if grep -Fq 'BENCHMARK_EVIDENCE_PRIVATE_KEY_BASE64' "$RELEASE_GATE"; then
  fail "the app release job must never receive the benchmark private key"
fi
require_text 'GRYPE_VERSION: 0.115.0' "$RELEASE_GATE"
require_text 'GRYPE_DARWIN_ARM64_SHA256: a5faa957bca6f39e252a046b9431cd79745030c692dd400ab4c0c74266edc406' "$RELEASE_GATE"
require_text 'GRYPE_DB_REQUIRE_UPDATE_CHECK: "true"' "$RELEASE_GATE"
require_text '"$RUNNER_TEMP/grype" --config /dev/null \' "$RELEASE_GATE"
require_text '"sbom:release/DMG/EasySplat-$VERSION.spdx.json" \' "$RELEASE_GATE"
require_text '--only-fixed \' "$RELEASE_GATE"
require_line '^[[:space:]]+--fail-on high$' "$RELEASE_GATE"
spdx_validation_line="$(grep -n -m1 'name: Validate SPDX 2.3 output independently' "$RELEASE_GATE" | cut -d: -f1)"
vulnerability_scan_line="$(grep -n -m1 'name: Scan shipped SBOM for actionable vulnerabilities' "$RELEASE_GATE" | cut -d: -f1)"
draft_release_line="$(grep -n -m1 'name: Create draft and upload exact assets' "$RELEASE_GATE" | cut -d: -f1)"
test -n "$spdx_validation_line"
test -n "$vulnerability_scan_line"
test -n "$draft_release_line"
test "$spdx_validation_line" -lt "$vulnerability_scan_line"
test "$vulnerability_scan_line" -lt "$draft_release_line"
build_release_block="$(sed -n '/^  build-and-test:/,/^  verify-publication:/p' "$RELEASE_GATE")"
verify_release_block="$(sed -n '/^  verify-publication:/,/^  publish:/p' "$RELEASE_GATE")"
publish_release_block="$(sed -n '/^  publish:/,$p' "$RELEASE_GATE")"
if grep -Eq 'environment: public-beta-release|contents: write|EASYSPLAT_RELEASE_ADMIN_TOKEN' <<<"$build_release_block"; then
  fail "the self-hosted build job must stay inside verification authority"
fi
grep -Fq 'runs-on: macos-15' <<<"$verify_release_block" \
  || fail "publication verification must run on a fresh GitHub-hosted runner"
if grep -Eq '^[[:space:]]+environment:|contents: write|EASYSPLAT_RELEASE_ADMIN_TOKEN|verify_beta\.sh|verify_ui\.sh' <<<"$verify_release_block"; then
  fail "the clean publication verifier must be static and secret-free"
fi
grep -Fq 'contents: read' <<<"$publish_release_block" \
  || fail "the publish workflow token must remain read-only"
grep -Fq 'secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN' <<<"$publish_release_block" \
  || fail "the publish job must use protected explicit release authority"
grep -Fq 'environment: public-beta-release' <<<"$publish_release_block" \
  || fail "the publish job must use the protected release environment"
if grep -Eq 'actions/checkout@|scripts/|swift[[:space:]]|hdiutil|open[[:space:]].*EasySplat' <<<"$publish_release_block"; then
  fail "the publish job must not checkout or execute repository, app, or toolchain code"
fi
contents_write_count="$(grep -Ec '^[[:space:]]+contents: write[[:space:]]*$' "$RELEASE_GATE" || true)"
[ "$contents_write_count" -eq 0 ] \
  || fail "the GitHub workflow token must never receive release write permission"
if grep -Fq 'softprops/action-gh-release' "$RELEASE_GATE"; then
  fail "release publication must use the audited GitHub CLI path"
fi
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$RELEASE_GATE"; then
  fail "public beta gate must never run pull-request code"
fi

require_job_count "$TOOLCHAIN_GATE" 4
require_line '^  workflow_dispatch:$' "$TOOLCHAIN_GATE"
require_line '^  policy-preflight:$' "$TOOLCHAIN_GATE"
require_line '^  build:$' "$TOOLCHAIN_GATE"
require_line '^  policy-postflight:$' "$TOOLCHAIN_GATE"
require_line '^  derive-signing-request:$' "$TOOLCHAIN_GATE"
require_line '^    if: github\.ref == '\''refs/heads/main'\'' && github\.event\.repository\.default_branch == '\''main'\''$' "$TOOLCHAIN_GATE"
require_line '^    needs: policy-preflight$' "$TOOLCHAIN_GATE"
require_line '^    needs: build$' "$TOOLCHAIN_GATE"
require_line '^    needs: \[build, policy-postflight\]$' "$TOOLCHAIN_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-ephemeral\]$' "$TOOLCHAIN_GATE"
require_line '^    runs-on: macos-15$' "$TOOLCHAIN_GATE"
environment_count="$(grep -Ec '^    environment: toolchain-release$' "$TOOLCHAIN_GATE")"
[ "$environment_count" -eq 2 ] \
  || fail "toolchain policy preflight and postflight must use the protected environment"
require_text 'name: toolchain-components-${{ steps.release.outputs.version }}' "$TOOLCHAIN_GATE"
require_text 'name: toolchain-signing-request-${{ inputs.version }}' "$TOOLCHAIN_GATE"
require_text 'ManifestTool prepare-release' "$TOOLCHAIN_GATE"
require_text 'source scripts/release/lib/strict_semver.sh' "$TOOLCHAIN_GATE"
require_text 'test "$DEFAULT_BRANCH" = "main"' "$TOOLCHAIN_GATE"
require_text 'test "$GITHUB_REF" = "refs/heads/main"' "$TOOLCHAIN_GATE"
require_text '"repos/$GITHUB_REPOSITORY" --jq .default_branch' "$TOOLCHAIN_GATE"
require_text '"repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH"' "$TOOLCHAIN_GATE"
require_text '"repos/$GITHUB_REPOSITORY/rules/branches/main?per_page=100"' "$TOOLCHAIN_GATE"
require_text '"repos/$GITHUB_REPOSITORY/rulesets/$ruleset_id?includes_parents=true"' "$TOOLCHAIN_GATE"
require_text 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' "$TOOLCHAIN_GATE"
require_text 'artifact-ids: ${{ needs.build.outputs.artifact_id }}' "$TOOLCHAIN_GATE"
require_text 'actions/artifacts/$ARTIFACT_ID' "$TOOLCHAIN_GATE"
toolchain_preflight_block="$(sed -n '/^  policy-preflight:/,/^  build:/p' "$TOOLCHAIN_GATE")"
toolchain_build_block="$(sed -n '/^  build:/,/^  policy-postflight:/p' "$TOOLCHAIN_GATE")"
toolchain_postflight_block="$(sed -n '/^  policy-postflight:/,/^  derive-signing-request:/p' "$TOOLCHAIN_GATE")"
toolchain_derive_block="$(sed -n '/^  derive-signing-request:/,$p' "$TOOLCHAIN_GATE")"
grep -Fq 'easysplat-ephemeral' <<<"$toolchain_build_block" \
  || fail "toolchain compilation must use the isolated Apple Silicon builder"
grep -Fq 'runs-on: macos-15' <<<"$toolchain_derive_block" \
  || fail "toolchain signing-request derivation must use a fresh hosted runner"
for policy_block in "$toolchain_preflight_block" "$toolchain_postflight_block"; do
  grep -Fq 'runs-on: macos-15' <<<"$policy_block" \
    || fail "toolchain policy verification must use a GitHub-hosted runner"
  grep -Fq 'environment: toolchain-release' <<<"$policy_block" \
    || fail "toolchain policy verification must use the protected environment"
  grep -Fq 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' <<<"$policy_block" \
    || fail "toolchain policy verification must use protected policy authority"
  grep -Fq 'test "$DEFAULT_BRANCH" = "main"' <<<"$policy_block" \
    || fail "toolchain policy verification must require main as the event default"
  grep -Fq 'test "$GITHUB_REF" = "refs/heads/main"' <<<"$policy_block" \
    || fail "toolchain policy verification must require the main workflow ref"
  grep -Fq '"repos/$GITHUB_REPOSITORY" --jq .default_branch' <<<"$policy_block" \
    || fail "toolchain policy verification must query the live default branch"
  grep -Fq '"repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH" --jq .sha' <<<"$policy_block" \
    || fail "toolchain policy verification must require the current main head"
  grep -Fq '"repos/$GITHUB_REPOSITORY/rules/branches/main?per_page=100"' <<<"$policy_block" \
    || fail "toolchain policy verification must fetch effective main rules"
  grep -Fq '"repos/$GITHUB_REPOSITORY/rulesets/$ruleset_id?includes_parents=true"' <<<"$policy_block" \
    || fail "toolchain policy verification must inspect every effective ruleset"
  if grep -Eq 'actions/checkout@|^[[:space:]]+uses:|scripts/|swift[[:space:]]' <<<"$policy_block"; then
    fail "toolchain policy jobs must not checkout or execute repository code"
  fi
done
for unprivileged_block in "$toolchain_build_block" "$toolchain_derive_block"; do
  if grep -Eq 'EASYSPLAT_RELEASE_POLICY_TOKEN|environment: toolchain-release' <<<"$unprivileged_block"; then
    fail "the protected policy token must not reach build or signing-request derivation"
  fi
done
policy_token_count="$(grep -Fc 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' "$TOOLCHAIN_GATE")"
[ "$policy_token_count" -eq 2 ] \
  || fail "the protected policy token must appear only in preflight and postflight"
if grep -Eq 'contents: write|sign-release|gh release|TOOLCHAIN_PRIVATE_KEY|private[_-]key' "$TOOLCHAIN_GATE"; then
  fail "the source toolchain workflow must remain read-only and unable to sign or publish"
fi
postflight_head_line="$(grep -n -m1 'name: Reverify protected main policy after build' "$TOOLCHAIN_GATE" | cut -d: -f1)"
derive_job_line="$(grep -n -m1 '^  derive-signing-request:$' "$TOOLCHAIN_GATE" | cut -d: -f1)"
derive_head_line="$(grep -n -m1 'name: Reverify current main head before signing-request upload' "$TOOLCHAIN_GATE" | cut -d: -f1)"
signing_upload_line="$(grep -n -m1 'name: Upload exact prepared signing request' "$TOOLCHAIN_GATE" | cut -d: -f1)"
test -n "$postflight_head_line"
test -n "$derive_job_line"
test -n "$derive_head_line"
test -n "$signing_upload_line"
test "$postflight_head_line" -lt "$derive_job_line"
test "$derive_head_line" -lt "$signing_upload_line"
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$TOOLCHAIN_GATE"; then
  fail "toolchain build requests must never run pull-request code"
fi

TOOLCHAIN_WORKFLOW="$TOOLCHAIN_GATE" python3 - <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap

workflow = Path(os.environ["TOOLCHAIN_WORKFLOW"]).read_text(encoding="utf-8")
pattern = re.compile(
    r"^          # BEGIN TOOLCHAIN PROTECTED MAIN POLICY CHECKER\n"
    r"(?P<body>.*?)"
    r"^          # END TOOLCHAIN PROTECTED MAIN POLICY CHECKER$",
    re.MULTILINE | re.DOTALL,
)
checkers = [textwrap.dedent(match.group("body")) for match in pattern.finditer(workflow)]
if len(checkers) != 2 or checkers[0] != checkers[1]:
    raise SystemExit("toolchain preflight and postflight must embed the same tested policy checker")
checker = checkers[0]

expected_checks = [
    "Swift · macOS 15 arm64 · Xcode 16.4",
    "Real 8 GB-class policy lane",
    "Native Metal trainer",
    "Repository contracts",
    "DA3 bridge · Python 3.12",
    "Actions and shell lint",
    "Python dependency audit",
    "Full-history secret scan",
    "Pull request dependency review",
    "Analyze swift",
    "Analyze python",
    "Analyze c-cpp",
    "Analyze actions",
]


def effective_rule(ruleset_id, rule_type, parameters=None):
    rule = {
        "type": rule_type,
        "ruleset_id": ruleset_id,
        "ruleset_source_type": "Repository",
        "ruleset_source": "dud8/EasySplat",
    }
    if parameters is not None:
        rule["parameters"] = parameters
    return rule


def valid_policy():
    first_checks = [
        {"context": context, "integration_id": 15368}
        for context in expected_checks[:6]
    ]
    second_checks = [
        {"context": context, "integration_id": 15368}
        for context in expected_checks[6:]
    ]
    effective = [
        effective_rule(101, "deletion"),
        effective_rule(101, "required_linear_history"),
        effective_rule(
            101,
            "pull_request",
            {
                "allowed_merge_methods": ["squash", "rebase"],
                "dismiss_stale_reviews_on_push": True,
                "require_last_push_approval": False,
                "required_approving_review_count": 0,
                "required_review_thread_resolution": False,
            },
        ),
        effective_rule(
            101,
            "required_status_checks",
            {
                "strict_required_status_checks_policy": False,
                "required_status_checks": first_checks,
            },
        ),
        effective_rule(202, "non_fast_forward"),
        effective_rule(
            202,
            "pull_request",
            {
                "allowed_merge_methods": ["squash", "merge"],
                "dismiss_stale_reviews_on_push": False,
                "require_last_push_approval": True,
                "required_approving_review_count": 1,
                "required_review_thread_resolution": True,
            },
        ),
        effective_rule(
            202,
            "required_status_checks",
            {
                "strict_required_status_checks_policy": True,
                "required_status_checks": second_checks,
            },
        ),
    ]
    rulesets = {
        101: {
            "id": 101,
            "target": "branch",
            "enforcement": "active",
            "bypass_actors": [],
        },
        202: {
            "id": 202,
            "target": "branch",
            "enforcement": "active",
            "bypass_actors": [],
        },
    }
    return effective, rulesets


def run_policy(effective, rulesets, expect_success):
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        root.chmod(0o700)
        files = {"effective-rules.json": effective}
        files.update({f"ruleset-{ruleset_id}.json": value for ruleset_id, value in rulesets.items()})
        for name, value in files.items():
            path = root / name
            path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")
            path.chmod(0o600)
        result = subprocess.run(
            [sys.executable, "-c", checker, os.fspath(root)],
            check=False,
            capture_output=True,
            text=True,
        )
        if expect_success and result.returncode != 0:
            raise SystemExit(f"valid layered toolchain policy failed: {result.stderr}")
        if not expect_success and result.returncode == 0:
            raise SystemExit("invalid layered toolchain policy was accepted")


effective, rulesets = valid_policy()
run_policy(effective, rulesets, True)

with_bypass = copy.deepcopy(rulesets)
with_bypass[202]["bypass_actors"] = [{"actor_id": 1, "actor_type": "RepositoryRole"}]
run_policy(effective, with_bypass, False)

without_bypass_field = copy.deepcopy(rulesets)
del without_bypass_field[101]["bypass_actors"]
run_policy(effective, without_bypass_field, False)

incomplete_status_union = copy.deepcopy(effective)
incomplete_status_union[-1]["parameters"]["required_status_checks"].pop()
run_policy(incomplete_status_union, rulesets, False)
PY

require_job_count "$BENCHMARK_GATE" 8
require_line '^  workflow_dispatch:$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-reference, easysplat-ephemeral\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-constrained, easysplat-ephemeral\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-8gb, easysplat-ephemeral\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: macos-15$' "$BENCHMARK_GATE"
require_line '^    environment: benchmark-release$' "$BENCHMARK_GATE"
require_text 'scripts/benchmark/render-requirements.txt' "$BENCHMARK_GATE"
base_install_count="$(grep -Fc 'name: Install protected benchmark dependencies' "$BENCHMARK_GATE")"
[ "$base_install_count" -eq 8 ] \
  || fail "every benchmark job must install the base evidence dependencies"
render_install_count="$(grep -Fc 'name: Install protected render-scoring dependencies' "$BENCHMARK_GATE")"
[ "$render_install_count" -eq 1 ] \
  || fail "only no-secret reference derivation may install render scoring"
for required in \
  EASYSPLAT_BENCHMARK_REFERENCE_RUNNER \
  EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER \
  EASYSPLAT_BENCHMARK_8GB_RUNNER \
  EASYSPLAT_BENCHMARK_REFERENCE_RUNNER_SHA256 \
  EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER_SHA256 \
  EASYSPLAT_BENCHMARK_8GB_RUNNER_SHA256 \
  EASYSPLAT_BENCHMARK_BASELINE_TOOLCHAIN_ROOT \
  EASYSPLAT_BENCHMARK_LPIPS_BACKBONE \
  scripts/benchmark/run_lane.py \
  scripts/benchmark/prepare_evidence.py \
  scripts/benchmark/aggregate_evidence.py \
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
require_text '--prepared-root "$RUNNER_TEMP/prepared-reference"' "$BENCHMARK_GATE"
require_text '--prepared-root "$RUNNER_TEMP/prepared-constrained"' "$BENCHMARK_GATE"
require_text '--prepared-root "$RUNNER_TEMP/prepared-eight-gb"' "$BENCHMARK_GATE"
require_text 'artifact-ids: ${{ needs.prepare.outputs.requests_artifact_id }}' "$BENCHMARK_GATE"
require_text 'artifact-ids: ${{ needs.derive-reference.outputs.prepared_artifact_id }}' "$BENCHMARK_GATE"
require_text 'artifact-ids: ${{ needs.derive-constrained.outputs.prepared_artifact_id }}' "$BENCHMARK_GATE"
require_text 'artifact-ids: ${{ needs.derive-eight-gb.outputs.prepared_artifact_id }}' "$BENCHMARK_GATE"
require_text '${{ needs.derive-reference.outputs.prepared_artifact_digest }}' "$BENCHMARK_GATE"
require_text '${{ needs.derive-constrained.outputs.prepared_artifact_digest }}' "$BENCHMARK_GATE"
require_text '${{ needs.derive-eight-gb.outputs.prepared_artifact_digest }}' "$BENCHMARK_GATE"
require_text 'actions/artifacts/$artifact_id' "$BENCHMARK_GATE"
require_text 'artifact-digest' "$BENCHMARK_GATE"
if grep -Eq 'BENCHMARK_EVIDENCE_(PRIVATE|PUBLIC)_KEY|benchmark-evidence-signing|seal_evidence\.py|signing-requirements|benchmark/public_key_ed25519\.txt|--private-key-stdin|--sealed-root' "$BENCHMARK_GATE"; then
  fail "benchmark evidence must not claim a repository-controlled signing authority"
fi
aggregate_block="$(sed -n '/^  aggregate:/,$p' "$BENCHMARK_GATE")"
if grep -Eq '^[[:space:]]+environment:' <<<"$aggregate_block"; then
  fail "aggregate validation must not enter a secret-bearing environment"
fi
for derive_job in derive-reference derive-constrained derive-eight-gb; do
  derive_block="$(sed -n "/^  $derive_job:/,/^  [A-Za-z0-9_-]*:/p" "$BENCHMARK_GATE")"
  grep -Fq 'runs-on: macos-15' <<<"$derive_block" \
    || fail "$derive_job must run on a fresh GitHub-hosted runner"
done
self_hosted_count="$(grep -Ec '^    runs-on: \[self-hosted, macOS, ARM64, .*easysplat-ephemeral\]$' "$BENCHMARK_GATE")"
[ "$self_hosted_count" -eq 4 ] \
  || fail "every self-hosted benchmark job must require the ephemeral-runner label"
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$BENCHMARK_GATE"; then
  fail "release benchmark must never run pull-request code"
fi

for untrusted in "$TESTS" "$SECURITY" "$CODEQL"; do
  if grep -Fq '${{ secrets.' "$untrusted"; then
    fail "${untrusted#"$ROOT/"} exposes a secret to untrusted code"
  fi
done

echo "workflow contracts passed"
