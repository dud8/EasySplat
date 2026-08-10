#!/usr/bin/env bash
# Source-contract assertions intentionally match literal shell and Actions expressions.
# shellcheck disable=SC1003,SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS="$ROOT/.github/workflows/tests.yml"
SECURITY="$ROOT/.github/workflows/security.yml"
CODEQL="$ROOT/.github/workflows/codeql.yml"
RELEASE_GATE="$ROOT/.github/workflows/release-app.yml"
TESTFLIGHT_GATE="$ROOT/.github/workflows/release-testflight.yml"
TOOLCHAIN_GATE="$ROOT/.github/workflows/toolchain-build.yml"
TOOLCHAIN_PUBLISH="$ROOT/.github/workflows/toolchain-publish.yml"
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

for workflow in "$TESTS" "$SECURITY" "$CODEQL" "$RELEASE_GATE" "$TESTFLIGHT_GATE" "$TOOLCHAIN_GATE" "$TOOLCHAIN_PUBLISH" "$BENCHMARK_GATE"; do
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
require_line '^[[:space:]]+--require-hashes --requirement scripts/benchmark/requirements\.txt$' "$TESTS"
native_msplat_block="$(awk '
  /^  native-msplat:$/ { in_job = 1 }
  in_job { print }
  in_job && /^  repo-health:$/ { exit }
' "$TESTS")"
for contract in \
  '      - uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1 # v6' \
  '          python-version: "3.12"' \
  '          python -m pip install --disable-pip-version-check --no-input \' \
  '            --require-hashes --requirement scripts/benchmark/requirements.txt'; do
  grep -Fq "$contract" <<<"$native_msplat_block" \
    || fail "native Metal validation must install its hash-locked Python fixture dependencies: $contract"
done
for contract in \
  'RIPGREP_VERSION: "15.2.0"' \
  'RIPGREP_SHA256: "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"' \
  'https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-aarch64-apple-darwin.tar.gz' \
  'echo "$RIPGREP_SHA256  $archive" | /usr/bin/shasum -a 256 -c -' \
  'printf '\''%s\n'\'' "$ripgrep_root" >> "$GITHUB_PATH"'; do
  grep -Fq "$contract" <<<"$native_msplat_block" \
    || fail "native Metal release integration must install verified arm64 ripgrep: $contract"
done
if grep -Fq '          cache: pip' <<<"$native_msplat_block"; then
  fail "native Metal validation must not depend on a mutable pip cache"
fi
repo_health_block="$(awk '
  /^  repo-health:$/ { in_job = 1 }
  in_job { print }
  in_job && /^  python-tools:$/ { exit }
' "$TESTS")"
grep -Fq '    runs-on: macos-15' <<<"$repo_health_block" \
  || fail "repository contracts must run on the supported macOS host"
grep -Fq '          test "$(uname -m)" = "arm64"' <<<"$repo_health_block" \
  || fail "repository contracts must require an Apple Silicon host"
grep -Fq '          sudo xcode-select -s /Applications/Xcode_16.4.app' <<<"$repo_health_block" \
  || fail "repository contracts must use the pinned Xcode toolchain"
for contract in \
  'RIPGREP_VERSION: "15.2.0"' \
  'RIPGREP_SHA256: "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"' \
  'https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-aarch64-apple-darwin.tar.gz' \
  'echo "$RIPGREP_SHA256  $archive" | /usr/bin/shasum -a 256 -c -' \
  'printf '\''%s\n'\'' "$ripgrep_root" >> "$GITHUB_PATH"'; do
  grep -Fq "$contract" <<<"$repo_health_block" \
    || fail "repository contracts must install verified arm64 ripgrep: $contract"
done
if grep -Fq 'command -v rg >/dev/null' <<<"$repo_health_block"; then
  fail "repository contracts must not assume ripgrep is preinstalled on a fresh macOS host"
fi
if grep -Fq '          cache: pip' <<<"$repo_health_block"; then
  fail "repository contracts must not enable setup-python's empty pip cache on a fresh macOS host"
fi
if grep -Fq '          cache-dependency-path:' <<<"$repo_health_block"; then
  fail "repository contracts must not configure a pip cache before the fresh macOS host has created it"
fi
if grep -Fq 'apt-get' <<<"$repo_health_block"; then
  fail "repository contracts must not install Linux dependencies on the macOS host"
fi
if grep -Fq 'scripts/benchmark/render-requirements.txt' "$TESTS"; then
  fail "ordinary repository tests must not install the protected render-scoring closure"
fi
require_line '^  pull_request:$' "$CODEQL"
require_job_count "$CODEQL" 4

require_line '^[[:space:]]+GOBIN=.*go install github\.com/rhysd/actionlint/cmd/actionlint@v[0-9]+\.[0-9]+\.[0-9]+$' "$SECURITY"
require_line '^[[:space:]]+.*shellcheck --severity=warning$' "$SECURITY"
for lock in \
  Tools/Da3Sfm/requirements.txt \
  scripts/benchmark/requirements.txt \
  scripts/benchmark/render-requirements.txt; do
  require_text "$lock" "$SECURITY"
  require_line "^[[:space:]]+--requirement $lock \\\\$" "$SECURITY"
done
require_line '^[[:space:]]+"\$RUNNER_TEMP/gitleaks" git --redact --no-banner .* \.$' "$SECURITY"
require_line '^[[:space:]]+- uses: actions/dependency-review-action@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$SECURITY"

for language in swift python c-cpp actions; do
  require_line "^  analyze-$language:$" "$CODEQL"
  require_line "^[[:space:]]+name: Analyze $language$" "$CODEQL"
  require_line "^[[:space:]]+languages: $language$" "$CODEQL"
  require_line "^[[:space:]]+category: /language:$language$" "$CODEQL"
done
require_line '^  workflow_dispatch:$' "$CODEQL"
if grep -Fq '${{ matrix.' "$CODEQL"; then
  fail "CodeQL required-check identities must not depend on matrix expansion"
fi
require_line '^[[:space:]]+security-events: write$' "$CODEQL"

require_job_count "$RELEASE_GATE" 8
require_job_count "$TESTFLIGHT_GATE" 4
require_line '^  workflow_dispatch:$' "$RELEASE_GATE"
for job in \
  live-policy-preflight \
  minimum-macos-compatibility \
  prepare-release \
  sign-and-notarize \
  quarantined-install \
  macos15-signed-compatibility \
  verify-publication \
  publish; do
  require_line "^  $job:$" "$RELEASE_GATE"
done
require_line '^    if: github\.ref == '\''refs/heads/main'\'' && github\.event\.repository\.default_branch == '\''main'\''$' "$RELEASE_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-signing, easysplat-ephemeral\]$' "$RELEASE_GATE"
require_line '^    runs-on: macos-15$' "$RELEASE_GATE"
require_line '^    runs-on: macos-26$' "$RELEASE_GATE"
require_line '^    runs-on: ubuntu-24\.04$' "$RELEASE_GATE"
require_line '^    environment: release-verification$' "$RELEASE_GATE"
require_line '^    environment: release-signing$' "$RELEASE_GATE"
require_line '^    environment: release-publication$' "$RELEASE_GATE"
require_text '"$GITHUB_WORKSPACE/scripts/release/build_dmg.sh" \' "$RELEASE_GATE"
require_text '"$GITHUB_WORKSPACE/scripts/release/verify_release.sh" \' "$RELEASE_GATE"
require_line '^[[:space:]]+--artifacts \\$' "$RELEASE_GATE"
require_text 'benchmark_run_id:' "$RELEASE_GATE"
require_text 'artifact-ids: ${{ steps.bind-authority.outputs.benchmark_artifact_id }}' "$RELEASE_GATE"
require_text 'scripts/benchmark/aggregate_evidence.py' "$RELEASE_GATE"
require_text 'closure_args=(' "$RELEASE_GATE"
require_text 'create-build-closure' "$RELEASE_GATE"
require_text 'verify_args=(' "$RELEASE_GATE"
require_text 'verify-build' "$RELEASE_GATE"
require_text 'scripts/release/verify_publication_bundle.py' "$RELEASE_GATE"
if grep -Fq 'EASYSPLAT_RELEASE_FIXTURE' "$RELEASE_GATE"; then
  fail "app release verification must not depend on a caller or repository fixture variable"
fi
require_text 'signed_artifact_id:' "$RELEASE_GATE"
require_text 'signed_artifact_digest:' "$RELEASE_GATE"
require_text 'prepared_artifact_id:' "$RELEASE_GATE"
require_text 'prepared_artifact_digest:' "$RELEASE_GATE"
require_text 'quarantine_artifact_id:' "$RELEASE_GATE"
require_text 'quarantine_artifact_digest:' "$RELEASE_GATE"
require_text 'compatibility_artifact_id:' "$RELEASE_GATE"
require_text 'compatibility_artifact_digest:' "$RELEASE_GATE"
require_text 'benchmark_artifact_id:' "$RELEASE_GATE"
require_text 'benchmark_artifact_digest:' "$RELEASE_GATE"
require_text 'publication_artifact_id:' "$RELEASE_GATE"
require_text 'publication_artifact_digest:' "$RELEASE_GATE"
release_source_gate_block="$(sed -n '/name: Run source gates/,/name: Fetch signed toolchain closure/p' "$RELEASE_GATE")"
for contract in \
  'XCTEST_LOG="$RUNNER_TEMP/easysplat-release-xctest.log"' \
  'test ! -e "$XCTEST_LOG"' \
  'umask 077' \
  ': >"$XCTEST_LOG"' \
  'umask "$original_umask"' \
  './scripts/test.sh 2>&1 | tee -a "$XCTEST_LOG"' \
  'pipeline_status=("${PIPESTATUS[@]}")' \
  'xctest_status="${pipeline_status[0]}"' \
  'tee_status="${pipeline_status[1]}"' \
  'test "$(stat -f '\''%Lp'\'' "$XCTEST_LOG")" = "600"' \
  "grep -Fq 'Test skipped' \"\$XCTEST_LOG\"" \
  'exit "$xctest_status"'; do
  grep -Fq -- "$contract" <<<"$release_source_gate_block" \
    || fail "physical release source gate is missing zero-skip contract: $contract"
done
if grep -Fq 'Test skipped' "$TESTS"; then
  fail "ordinary pull-request tests must not inherit the physical release zero-skip policy"
fi
require_text 'app version must be stable semantic versioning without build metadata' "$RELEASE_GATE"
require_text 'toolchain version must be stable semantic versioning without build metadata' "$RELEASE_GATE"
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
require_text '"sbom:$RUNNER_TEMP/easysplat-publication/EasySplat-${{ inputs.version }}.spdx.json" \' "$RELEASE_GATE"
require_text '--only-fixed \' "$RELEASE_GATE"
require_line '^[[:space:]]+--fail-on high$' "$RELEASE_GATE"
spdx_validation_line="$(grep -n -m1 'name: Validate SPDX 2.3 output independently' "$RELEASE_GATE" | cut -d: -f1)"
vulnerability_scan_line="$(grep -n -m1 'name: Scan shipped SBOM for actionable vulnerabilities' "$RELEASE_GATE" | cut -d: -f1)"
draft_release_line="$(grep -n -m1 'name: Reverify policy, create or resume draft, and upload exact assets' "$RELEASE_GATE" | cut -d: -f1)"
test -n "$spdx_validation_line"
test -n "$vulnerability_scan_line"
test -n "$draft_release_line"
test "$spdx_validation_line" -lt "$vulnerability_scan_line"
test "$vulnerability_scan_line" -lt "$draft_release_line"
minimum_release_block="$(sed -n '/^  minimum-macos-compatibility:/,/^  prepare-release:/p' "$RELEASE_GATE")"
preflight_release_block="$(sed -n '/^  live-policy-preflight:/,/^  minimum-macos-compatibility:/p' "$RELEASE_GATE")"
prepare_release_block="$(sed -n '/^  prepare-release:/,/^  sign-and-notarize:/p' "$RELEASE_GATE")"
signing_release_block="$(sed -n '/^  sign-and-notarize:/,/^  quarantined-install:/p' "$RELEASE_GATE")"
quarantine_release_block="$(sed -n '/^  quarantined-install:/,/^  verify-publication:/p' "$RELEASE_GATE")"
quarantine_fixture_block="$(sed -n '/^  quarantined-install:/,/^  macos15-signed-compatibility:/p' "$RELEASE_GATE")"
macos15_fixture_block="$(sed -n '/^  macos15-signed-compatibility:/,/^  verify-publication:/p' "$RELEASE_GATE")"
verify_release_block="$(sed -n '/^  verify-publication:/,/^  publish:/p' "$RELEASE_GATE")"
publish_release_block="$(sed -n '/^  publish:/,$p' "$RELEASE_GATE")"
grep -Fq 'runs-on: ubuntu-24.04' <<<"$preflight_release_block" \
  || fail "live release preflight must run on a fresh GitHub-hosted runner"
grep -Fq 'environment: release-verification' <<<"$preflight_release_block" \
  || fail "live release authority must use the protected verification environment"
if grep -Eq 'actions/(checkout|setup-python)@|scripts/|swift[[:space:]]|secrets\.' <<<"$preflight_release_block"; then
  fail "live release preflight must not checkout or execute repository code or receive secrets"
fi
for contract in \
  'source_commit=' \
  'authority_artifact_id:' \
  'authority_artifact_digest:' \
  'release-authority.json' \
  'benchmark_artifact_id=' \
  'benchmark_artifact_digest=' \
  'testflight_artifact_id=' \
  'testflight_artifact_digest=' \
  'easysplat-testflight-gate-' \
  'repos/$GITHUB_REPOSITORY/branches/main' \
  'repos/$GITHUB_REPOSITORY/commits/main' \
  '.github/workflows/benchmark-release.yml' \
  '.github/workflows/release-testflight.yml'; do
  grep -Fq -- "$contract" <<<"$preflight_release_block" \
    || fail "live release preflight is missing: $contract"
done
grep -Fq 'needs: live-policy-preflight' <<<"$minimum_release_block" \
  || fail "minimum compatibility must wait for live protected-main preflight"
grep -Fq 'runs-on: macos-15' <<<"$minimum_release_block" \
  || fail "minimum deployment compatibility must run on macOS 15"
grep -Fq 'ref: ${{ github.sha }}' <<<"$minimum_release_block" \
  || fail "minimum compatibility checkout must use the workflow invocation SHA"
grep -Fq 'needs: [live-policy-preflight, minimum-macos-compatibility]' <<<"$prepare_release_block" \
  || fail "release preparation must wait for hosted policy and compatibility"
grep -Fq 'ref: ${{ github.sha }}' <<<"$prepare_release_block" \
  || fail "build-authority checkout must use the workflow invocation SHA"
if grep -Fq 'ref: ${{ needs.live-policy-preflight.outputs.source_commit }}' \
    <<<"$minimum_release_block$prepare_release_block"; then
  fail "hosted release checkouts must not consume a job output as their source ref"
fi
if grep -Eq '^[[:space:]]+environment:' <<<"$prepare_release_block"; then
  fail "release preparation must not inherit protected environment authority"
fi
grep -Fq 'runs-on: macos-26' <<<"$prepare_release_block" \
  || fail "release preparation must use the clean GitHub-hosted macOS authority"
for contract in \
  'RUNNER_ENVIRONMENT: ${{ runner.environment }}' \
  'test "$RUNNER_ENVIRONMENT" = "github-hosted"' \
  '/Applications/Xcode_26.6.app/Contents/Developer' \
  'xcrun --sdk macosx --show-sdk-version' \
  'authority_artifact_id' \
  'authority_artifact_digest' \
  'release-authority.json' \
  'Download exact approved TestFlight gate' \
  'payload["recordType"] == "testflightDogfoodGate"' \
  'REQUIRED_DOGFOOD_CHECKS' \
  'container="fresh"' \
  'container="affectedInternal"' \
  '0valididentitiesfound'; do
  grep -Fq -- "$contract" <<<"$prepare_release_block" \
    || fail "identity-free builder attestation is missing: $contract"
done
if grep -Eq 'environment: release-(signing|release)|contents: write|EASYSPLAT_(RELEASE_ADMIN_TOKEN|DEVELOPER_ID_APPLICATION_SHA1|DEVELOPER_TEAM_ID|NOTARY_KEYCHAIN_PROFILE)' <<<"$prepare_release_block"; then
  fail "uncredentialed release preparation must not enter signing or publication authority"
fi

testflight_authorize_block="$(sed -n '/^  authorize-source:/,/^  build-store-package:/p' "$TESTFLIGHT_GATE")"
testflight_build_block="$(sed -n '/^  build-store-package:/,/^  submit-testflight:/p' "$TESTFLIGHT_GATE")"
testflight_submission_block="$(sed -n '/^  submit-testflight:/,/^  approve-dogfood:/p' "$TESTFLIGHT_GATE")"
testflight_dogfood_block="$(sed -n '/^  approve-dogfood:/,$p' "$TESTFLIGHT_GATE")"
for contract in \
  'workflow_dispatch:' \
  'group: testflight-publication' \
  'cancel-in-progress: false'; do
  require_text "$contract" "$TESTFLIGHT_GATE"
done
if grep -Eq '^[[:space:]]+(push|pull_request):' "$TESTFLIGHT_GATE"; then
  fail "TestFlight publication must be manually dispatched from protected main"
fi
for contract in \
  "github.ref == 'refs/heads/main'" \
  'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"' \
  'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' \
  'test "$(git rev-parse "v$VERSION^{commit}")" = "$GITHUB_SHA"' \
  'repos/$GITHUB_REPOSITORY/branches/main'; do
  grep -Fq -- "$contract" <<<"$testflight_authorize_block" \
    || fail "TestFlight source authorization is missing: $contract"
done
for contract in \
  'environment: testflight-signing' \
  'runs-on: [self-hosted, macOS, ARM64, easysplat-signing, easysplat-ephemeral]' \
  'test "$(/usr/bin/uname -m)" = "arm64"' \
  'scripts/release/build_app.sh' \
  '--app-store' \
  '--source-commit "$GITHUB_SHA"' \
  'scripts/release/build_mas_package.sh' \
  'mas_release_evidence.py verify'; do
  grep -Fq -- "$contract" <<<"$testflight_build_block" \
    || fail "TestFlight Store package production is missing: $contract"
done
for secret in \
  EASYSPLAT_APPLE_DISTRIBUTION_SHA1 \
  EASYSPLAT_MAC_INSTALLER_DISTRIBUTION_SHA1 \
  EASYSPLAT_MAS_PROVISIONING_PROFILE_BASE64 \
  EASYSPLAT_MAS_TEAM_ID; do
  [ "$(grep -Fc "secrets.$secret" <<<"$testflight_build_block")" -eq 1 ] \
    || fail "$secret must enter exactly one TestFlight signing step"
  if grep -Fq "secrets.$secret" <<<"$testflight_submission_block$testflight_dogfood_block"; then
    fail "$secret escaped the TestFlight signing job"
  fi
done
for contract in \
  'environment: testflight-submission' \
  'scripts/release/upload_mas_package.sh' \
  '--upload' \
  '--apple-id "${{ inputs.apple_id }}"' \
  '--bundle-version "${{ inputs.build_number }}"' \
  'mas_release_evidence.py verify-processing' \
  '"$PACKAGE.upload.json"' \
  '"$PACKAGE.processing.json"'; do
  grep -Fq -- "$contract" <<<"$testflight_submission_block" \
    || fail "TestFlight terminal submission is missing: $contract"
done
for secret in \
  EASYSPLAT_ASC_KEY_ID \
  EASYSPLAT_ASC_ISSUER_ID \
  EASYSPLAT_ASC_PRIVATE_KEY_BASE64; do
  [ "$(grep -Fc "secrets.$secret" <<<"$testflight_submission_block")" -eq 1 ] \
    || fail "$secret must enter exactly one TestFlight submission step"
  if grep -Fq "secrets.$secret" <<<"$testflight_build_block$testflight_dogfood_block" \
      || grep -Fq "secrets.$secret" "$RELEASE_GATE"; then
    fail "$secret escaped the TestFlight submission job"
  fi
done
for contract in \
  'needs: submit-testflight' \
  'environment: testflight-dogfood' \
  'EASYSPLAT_TESTFLIGHT_FRESH_RESULT_BASE64' \
  'EASYSPLAT_TESTFLIGHT_AFFECTED_RESULT_BASE64' \
  'mas_release_evidence.py verify-processing' \
  'testflight_dogfood_evidence.py materialize' \
  'testflight_dogfood_evidence.py build-gate' \
  'fresh-container-result.json' \
  'affected-internal-container-result.json' \
  'easysplat-testflight-gate-${{ github.sha }}-${{ inputs.build_number }}'; do
  grep -Fiq -- "$contract" <<<"$testflight_dogfood_block" \
    || fail "TestFlight dogfood authority is missing: $contract"
done
if grep -Fq '"freshContainer": True' <<<"$testflight_dogfood_block" \
    || grep -Fq '"affectedInternalContainer": True' <<<"$testflight_dogfood_block"; then
  fail "TestFlight dogfood authority must not accept hard-coded approval booleans"
fi
if grep -Eq 'secrets\.|contents: write|EASYSPLAT_RELEASE_ADMIN_TOKEN|EASYSPLAT_DEVELOPER_ID_APPLICATION_SHA1|EASYSPLAT_NOTARY_KEYCHAIN_PROFILE' <<<"$testflight_dogfood_block"; then
  fail "TestFlight dogfood approval must remain secret-free and read-only"
fi
if grep -Eq 'contents: write|EASYSPLAT_RELEASE_ADMIN_TOKEN|EASYSPLAT_DEVELOPER_ID_APPLICATION_SHA1|EASYSPLAT_NOTARY_KEYCHAIN_PROFILE' "$TESTFLIGHT_GATE"; then
  fail "TestFlight production must not receive Developer ID publication authority"
fi
grep -Fq 'environment: release-signing' <<<"$signing_release_block" \
  || fail "Developer ID production must use the protected signing environment"
grep -Fq 'easysplat-signing' <<<"$signing_release_block" \
  || fail "Developer ID production must use the isolated signing runner"
grep -Fq 'shell: /bin/bash --noprofile --norc -p -e -u -o pipefail {0}' <<<"$signing_release_block" \
  || fail "credentialed app signing must reject inherited Bash startup code"
for secret in \
  EASYSPLAT_DEVELOPER_ID_APPLICATION_SHA1 \
  EASYSPLAT_DEVELOPER_TEAM_ID \
  EASYSPLAT_NOTARY_KEYCHAIN_PROFILE; do
  count="$(grep -Fc "secrets.$secret" <<<"$signing_release_block")"
  [ "$count" -eq 1 ] \
    || fail "$secret must enter exactly one signing step"
done
for contract in \
  '/usr/bin/env -i' \
  'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
  '/bin/bash --noprofile --norc -p' \
  '"$GITHUB_WORKSPACE/scripts/release/build_dmg.sh"' \
  '--prepared-release-root "$PREPARED_ROOT"'; do
  grep -Fq -- "$contract" <<<"$signing_release_block" \
    || fail "credentialed app signing is missing: $contract"
done
for contract in \
  'test "$RUNNER_ENVIRONMENT" = "self-hosted"' \
  'Prepare protected-main signing authority' \
  'ref: ${{ needs.live-policy-preflight.outputs.source_commit }}' \
  'test ! -e "$PREPARED_ROOT/source"' \
  'test ! -e "$PREPARED_ROOT/product/ManifestTool"' \
  'repos/$GITHUB_REPOSITORY/branches/main' \
  'repos/$GITHUB_REPOSITORY/commits/main'; do
  grep -Fq -- "$contract" <<<"$signing_release_block" \
    || fail "last-moment signing authority is missing: $contract"
done
signing_live_check_line="$(grep -n -m1 'repos/\$GITHUB_REPOSITORY/commits/main' <<<"$signing_release_block" | cut -d: -f1)"
signing_command_line="$(grep -n -m1 '\$GITHUB_WORKSPACE/scripts/release/build_dmg\.sh' <<<"$signing_release_block" | cut -d: -f1)"
test -n "$signing_live_check_line" && test -n "$signing_command_line"
test "$signing_live_check_line" -lt "$signing_command_line" \
  || fail "protected-main freshness must be checked immediately before signing"
if grep -Eq 'EASYSPLAT_RELEASE_ADMIN_TOKEN|contents: write' <<<"$signing_release_block"; then
  fail "the signing producer must not receive publication authority"
fi
grep -Fq 'runs-on: macos-26' <<<"$quarantine_release_block" \
  || fail "quarantined install proof must run on a fresh macOS 26 host"
grep -Fq 'verify_release.sh' <<<"$quarantine_release_block" \
  || fail "the quarantined host must run the full packaged-app verifier"
for block in "$quarantine_fixture_block" "$macos15_fixture_block"; do
  for contract in \
    'FIXTURE_ROOT="$RUNNER_TEMP/easysplat-release-fixture"' \
    'generate_release_fixture.py" generate \' \
    '--output "$FIXTURE_ROOT"' \
    'generate_release_fixture.py" verify \' \
    '--root "$FIXTURE_ROOT"' \
    '--fixture "$FIXTURE_ROOT"'; do
    grep -Fq -- "$contract" <<<"$block" \
      || fail "hosted release verification is missing hermetic fixture contract: $contract"
  done
done
fixture_generation_count="$(grep -Fc 'generate_release_fixture.py" generate \' "$RELEASE_GATE")"
[ "$fixture_generation_count" -eq 2 ] \
  || fail "each hosted release-verification job must generate its fixture exactly once"
if grep -Eq '^[[:space:]]+environment:|secrets\.|contents: write' <<<"$quarantine_release_block"; then
  fail "the quarantine verifier must remain secret-free"
fi
grep -Fq 'runs-on: macos-26' <<<"$verify_release_block" \
  || fail "publication verification must run on a fresh macOS 26 host"
for contract in \
  'signed_artifact_id: ${{ needs.sign-and-notarize.outputs.signed_artifact_id }}' \
  'signed_artifact_digest: ${{ needs.sign-and-notarize.outputs.signed_artifact_digest }}'; do
  grep -Fq -- "$contract" <<<"$verify_release_block" \
    || fail "publication verification is missing final signed-artifact binding: $contract"
done
if grep -Eq '^[[:space:]]+environment:|contents: write|EASYSPLAT_RELEASE_ADMIN_TOKEN|verify_release\.sh' <<<"$verify_release_block"; then
  fail "the clean publication verifier must be static and secret-free"
fi
grep -Fq 'contents: read' <<<"$publish_release_block" \
  || fail "the publish workflow token must remain read-only"
grep -Fq 'secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN' <<<"$publish_release_block" \
  || fail "the publish job must use protected explicit release authority"
grep -Fq 'environment: release-publication' <<<"$publish_release_block" \
  || fail "the publish job must use the protected release environment"
for contract in \
  'SIGNED_ARTIFACT_ID: ${{ needs.verify-publication.outputs.signed_artifact_id }}' \
  'SIGNED_ARTIFACT_DIGEST: ${{ needs.verify-publication.outputs.signed_artifact_digest }}' \
  'SIGNED_API="repos/$GITHUB_REPOSITORY/actions/artifacts/$SIGNED_ARTIFACT_ID"' \
  '"artifact_id": os.environ["SIGNED_ARTIFACT_ID"]' \
  '"artifact_digest": os.environ["SIGNED_ARTIFACT_DIGEST"]' \
  '"workflow_run_id": os.environ["GITHUB_RUN_ID"]' \
  '"workflow_run_attempt": os.environ["GITHUB_RUN_ATTEMPT"]'; do
  grep -Fq -- "$contract" <<<"$publish_release_block" \
    || fail "publication is missing final signed-artifact revalidation: $contract"
done
release_admin_count="$(grep -Fc 'secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN' <<<"$publish_release_block")"
[ "$release_admin_count" -eq 2 ] \
  || fail "publication authority must enter exactly two fixed phases"
if grep -Fq 'name: Verify live release policy' <<<"$publish_release_block"; then
  fail "publication must not spend a separate early admin-token phase"
fi
for contract in \
  'easysplat-release-owner:v3:${GITHUB_REPOSITORY}:${TAG}:${GITHUB_SHA}' \
  'name: Reverify policy, create or resume draft, and upload exact assets' \
  'existing asset differs from the publication manifest'; do
  grep -Fq -- "$contract" <<<"$publish_release_block" \
    || fail "idempotent draft publication is missing: $contract"
done
if grep -Fq 'easysplat-release-owner:v2:' "$RELEASE_GATE"; then
  fail "app release drafts must not be owned by one workflow run"
fi
[ "$(grep -Fc 'f"easysplat-release-owner:v3:' <<<"$publish_release_block")" -eq 4 ] \
  || fail "every app draft verifier must recompute repository/tag/commit ownership"
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
  fail "release gate must never run pull-request code"
fi

require_job_count "$TOOLCHAIN_GATE" 4
require_line '^  workflow_dispatch:$' "$TOOLCHAIN_GATE"
for input in version app_version_minimum app_version_maximum_exclusive; do
  require_line "^      $input:$" "$TOOLCHAIN_GATE"
done
for job in metadata-preflight build-unsigned sign-and-notarize derive-post-sign-request; do
  require_line "^  $job:$" "$TOOLCHAIN_GATE"
done
require_line '^    if: github\.ref == '\''refs/heads/main'\'' && github\.event\.repository\.default_branch == '\''main'\''$' "$TOOLCHAIN_GATE"
require_line '^    needs: metadata-preflight$' "$TOOLCHAIN_GATE"
require_line '^    needs: \[metadata-preflight, build-unsigned\]$' "$TOOLCHAIN_GATE"
require_line '^    needs: \[metadata-preflight, sign-and-notarize\]$' "$TOOLCHAIN_GATE"
require_line '^    environment: toolchain-release$' "$TOOLCHAIN_GATE"
require_line '^    environment: toolchain-signing$' "$TOOLCHAIN_GATE"
require_line '^    runs-on: ubuntu-latest$' "$TOOLCHAIN_GATE"
require_line '^    runs-on: macos-15$' "$TOOLCHAIN_GATE"
require_text '"self-hosted","macOS","ARM64","easysplat-toolchain-builder","easysplat-ephemeral"' "$TOOLCHAIN_GATE"
require_text '"self-hosted","macOS","ARM64","easysplat-toolchain-signing","easysplat-ephemeral"' "$TOOLCHAIN_GATE"
require_text 'concurrency:' "$TOOLCHAIN_GATE"
require_text 'cancel-in-progress: false' "$TOOLCHAIN_GATE"

toolchain_preflight_block="$(sed -n '/^  metadata-preflight:/,/^  build-unsigned:/p' "$TOOLCHAIN_GATE")"
toolchain_builder_block="$(sed -n '/^  build-unsigned:/,/^  sign-and-notarize:/p' "$TOOLCHAIN_GATE")"
toolchain_signing_block="$(sed -n '/^  sign-and-notarize:/,/^  derive-post-sign-request:/p' "$TOOLCHAIN_GATE")"
toolchain_post_sign_block="$(sed -n '/^  derive-post-sign-request:/,$p' "$TOOLCHAIN_GATE")"

for contract in \
  'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' \
  'repos/$GITHUB_REPOSITORY/branches/main' \
  'repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG' \
  'refs/tags/$TAG' \
  'repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2F$TAG'; do
  grep -Fq -- "$contract" <<<"$toolchain_preflight_block" \
    || fail "toolchain metadata preflight is missing: $contract"
done
if grep -Eq 'actions/checkout@|scripts/|swift[[:space:]]' <<<"$toolchain_preflight_block"; then
  fail "toolchain metadata preflight must not checkout or execute repository code"
fi

for contract in \
  'identity-free-production-builder' \
  'security find-identity -v -p codesigning' \
  'scripts/benchmark/verify_shipping_host.sh' \
  'scripts/toolchain/build_colmap.sh' \
  'scripts/toolchain/build_msplat.sh' \
  'scripts/toolchain/build_da3_mps.sh' \
  'ManifestTool prepare-release' \
  'toolchain-unsigned-components-${{ inputs.version }}' \
  'toolchain-unsigned-request-${{ inputs.version }}' \
  'compression-level: 0'; do
  grep -Fq -- "$contract" <<<"$toolchain_builder_block" \
    || fail "identity-free toolchain builder is missing: $contract"
done
if grep -Eq '^[[:space:]]+environment:|secrets\.|EASYSPLAT_TOOLCHAIN_DEVELOPER|notarytool|contents: write|gh release' <<<"$toolchain_builder_block"; then
  fail "identity-free toolchain builder received signing or publication authority"
fi

for variable in \
  EASYSPLAT_TOOLCHAIN_DEVELOPER_ID_APPLICATION_SHA1 \
  EASYSPLAT_TOOLCHAIN_DEVELOPER_TEAM_ID \
  EASYSPLAT_TOOLCHAIN_NOTARY_KEYCHAIN_PROFILE; do
  count="$(grep -Fc "$variable" <<<"$toolchain_signing_block")"
  [ "$count" -ge 2 ] \
    || fail "$variable must be validated and used inside the protected signing job"
done
for contract in \
  'Authenticate builder artifacts before repository checkout' \
  '/usr/bin/python3 -I' \
  'urllib.request.ProxyHandler({})' \
  'github-authority.json' \
  'scripts/release/finalize_signed_toolchain.py' \
  '--github-authority-receipt "$RUNNER_TEMP/toolchain-builder-authority/github-authority.json"' \
  'scripts/release/notarize_artifact.sh' \
  'toolchain-signed-intermediate-${{ inputs.version }}'; do
  grep -Fq -- "$contract" <<<"$toolchain_signing_block" \
    || fail "protected toolchain signing is missing: $contract"
done
if grep -Eq 'EASYSPLAT_RELEASE_POLICY_TOKEN|EASYSPLAT_TOOLCHAIN_PUBLICATION_TOKEN|authority_|contents: write|gh release' <<<"$toolchain_signing_block"; then
  fail "protected toolchain signer received authority or publication access"
fi
signer_token_line="$(grep -n -m1 'GH_TOKEN: \${{ github.token }}' <<<"$toolchain_signing_block" | cut -d: -f1)"
signer_checkout_line="$(grep -n -m1 'actions/checkout@' <<<"$toolchain_signing_block" | cut -d: -f1)"
signer_execution_line="$(grep -n -m1 'Developer ID sign and notarize exact producer bytes' <<<"$toolchain_signing_block" | cut -d: -f1)"
test -n "$signer_token_line" && test -n "$signer_checkout_line" && test -n "$signer_execution_line"
test "$signer_token_line" -lt "$signer_checkout_line" && test "$signer_checkout_line" -lt "$signer_execution_line" \
  || fail "GitHub authority must be captured before repository code reaches the signing runner"
signer_before_checkout="$(sed -n "1,${signer_checkout_line}p" <<<"$toolchain_signing_block")"
if grep -Fq 'gh api' <<<"$signer_before_checkout"; then
  fail "the signing token must only enter the immutable system Python authority capture"
fi
signer_after_checkout="$(sed -n "${signer_checkout_line},\$p" <<<"$toolchain_signing_block")"
if grep -Eq 'GH_TOKEN|GITHUB_TOKEN' <<<"$signer_after_checkout"; then
  fail "repository code must not receive a GitHub token on the signing runner"
fi

for contract in \
  'artifact-ids: ${{ needs.sign-and-notarize.outputs.artifact_id }}' \
  'ManifestTool prepare-release' \
  '--core-zip "$FINAL/toolchain-macos-arm64-$VERSION-core.zip"' \
  '--da3-base-zip "$FINAL/toolchain-geometry-da3-base-$VERSION.zip"' \
  '--da3-small-zip "$FINAL/toolchain-geometry-da3-small-$VERSION.zip"' \
  'scripts/release/toolchain_publication.py validate-producer' \
  'toolchain-final-producer-${{ inputs.version }}' \
  'toolchain-post-sign-request-${{ inputs.version }}'; do
  grep -Fq -- "$contract" <<<"$toolchain_post_sign_block" \
    || fail "post-sign toolchain derivation is missing: $contract"
done
if grep -Eq '^[[:space:]]+environment:|secrets\.|codesign|notarytool|contents: write|gh release' <<<"$toolchain_post_sign_block"; then
  fail "post-sign request derivation must remain identity-free and secretless"
fi

producer_policy_token_count="$(grep -Fc 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' "$TOOLCHAIN_GATE")"
[ "$producer_policy_token_count" -eq 1 ] \
  || fail "toolchain producer policy token must appear only in metadata preflight"
if grep -Eq 'EASYSPLAT_TOOLCHAIN_PUBLICATION_TOKEN|TOOLCHAIN_PRIVATE_KEY|private[_-]key|sourceArtifacts|softprops/action-gh-release|contents: write|^[[:space:]]*(pull_request|pull_request_target):' "$TOOLCHAIN_GATE"; then
  fail "toolchain producer must not contain authority keys, legacy sourceArtifacts, or publication behavior"
fi

require_job_count "$TOOLCHAIN_PUBLISH" 4
require_line '^  workflow_dispatch:$' "$TOOLCHAIN_PUBLISH"
for input in \
  version app_version app_version_minimum app_version_maximum_exclusive \
  producer_run_id producer_run_attempt producer_artifact_id producer_artifact_digest \
  request_artifact_id request_artifact_digest request_sha256 \
  authority_commit authority_run_id authority_run_attempt \
  authority_payload_artifact_id authority_payload_artifact_name authority_payload_artifact_digest \
  authority_receipt_artifact_id authority_receipt_artifact_name authority_receipt_artifact_digest \
  benchmark_run_id benchmark_run_attempt benchmark_artifact_id benchmark_artifact_name benchmark_artifact_digest; do
  require_line "^      $input:$" "$TOOLCHAIN_PUBLISH"
done
for job in metadata-preflight verify-publication minimum-macos-compatibility stage-draft-release; do
  require_line "^  $job:$" "$TOOLCHAIN_PUBLISH"
done
require_line '^    needs: metadata-preflight$' "$TOOLCHAIN_PUBLISH"
require_line '^    needs: verify-publication$' "$TOOLCHAIN_PUBLISH"
require_line '^    needs: \[verify-publication, minimum-macos-compatibility\]$' "$TOOLCHAIN_PUBLISH"
require_line '^    runs-on: ubuntu-latest$' "$TOOLCHAIN_PUBLISH"
require_line '^    runs-on: macos-15$' "$TOOLCHAIN_PUBLISH"
require_line '^    environment: toolchain-release$' "$TOOLCHAIN_PUBLISH"
require_line '^    environment: toolchain-publication$' "$TOOLCHAIN_PUBLISH"
require_text '"self-hosted","macOS","ARM64","easysplat-toolchain-verifier","easysplat-ephemeral"' "$TOOLCHAIN_PUBLISH"

toolchain_publish_preflight_block="$(sed -n '/^  metadata-preflight:/,/^  verify-publication:/p' "$TOOLCHAIN_PUBLISH")"
toolchain_verifier_block="$(sed -n '/^  verify-publication:/,/^  minimum-macos-compatibility:/p' "$TOOLCHAIN_PUBLISH")"
minimum_toolchain_block="$(sed -n '/^  minimum-macos-compatibility:/,/^  stage-draft-release:/p' "$TOOLCHAIN_PUBLISH")"
stage_draft_block="$(sed -n '/^  stage-draft-release:/,$p' "$TOOLCHAIN_PUBLISH")"

for contract in \
  'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' \
  'repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG' \
  'refs/tags/$TAG' \
  'repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2F$TAG' \
  'actions/artifacts/$PRODUCER_ARTIFACT_ID/zip' \
  'actions/artifacts/$REQUEST_ARTIFACT_ID/zip' \
  'actions/artifacts/$BENCHMARK_ARTIFACT_ID/zip' \
  'actions/artifacts/$AUTHORITY_PAYLOAD_ARTIFACT_ID/zip' \
  'actions/artifacts/$AUTHORITY_RECEIPT_ARTIFACT_ID/zip' \
  '.github/workflows/sign-toolchain-authority.yml' \
  'benchmark-transport.json' \
  'verifiedSuiteSHA256' \
  'toolchain-authority-handoff-${{ github.run_id }}-${{ github.run_attempt }}'; do
  grep -Fq -- "$contract" <<<"$toolchain_publish_preflight_block" \
    || fail "toolchain publication metadata preflight is missing: $contract"
done
if grep -Eq 'actions/checkout@|scripts/|swift[[:space:]]' <<<"$toolchain_publish_preflight_block"; then
  fail "toolchain publication preflight must not checkout or execute repository code"
fi

for contract in \
  'artifact-ids: ${{ needs.metadata-preflight.outputs.handoff_artifact_id }}' \
  'scripts/release/toolchain_publication.py verify' \
  '--producer-run-attempt "${{ inputs.producer_run_attempt }}"' \
  '--request-sha256 "${{ inputs.request_sha256 }}"' \
  '--benchmark-evidence "$HANDOFF/benchmark/benchmark-transport.json"' \
  '--benchmark-run-attempt "${{ inputs.benchmark_run_attempt }}"' \
  '--benchmark-artifact-name "${{ inputs.benchmark_artifact_name }}"' \
  '--benchmark-artifact-digest "${{ inputs.benchmark_artifact_digest }}"' \
  'verified-toolchain-publication-${{ inputs.version }}-${{ github.run_id }}-${{ github.run_attempt }}'; do
  grep -Fq -- "$contract" <<<"$toolchain_verifier_block" \
    || fail "secretless toolchain publication verification is missing: $contract"
done
if grep -Eq '^[[:space:]]+environment:|secrets\.|github-token:|GH_TOKEN|GITHUB_TOKEN|contents: write|codesign|notarytool|gh release' <<<"$toolchain_verifier_block"; then
  fail "toolchain publication verifier must remain secretless"
fi

for contract in \
  'runs-on: macos-15' \
  'artifact-ids: ${{ needs.verify-publication.outputs.artifact_id }}' \
  'colmap" help' \
  'easysplat-train" --self-check'; do
  grep -Fq -- "$contract" <<<"$minimum_toolchain_block" \
    || fail "minimum macOS toolchain compatibility is missing: $contract"
done
if grep -Eq '^[[:space:]]+environment:|secrets\.|contents: write' <<<"$minimum_toolchain_block"; then
  fail "minimum macOS compatibility must remain secret-free"
fi

for contract in \
  'environment: toolchain-publication' \
  'contents: read' \
  'secrets.EASYSPLAT_TOOLCHAIN_PUBLICATION_TOKEN' \
  'Create or resume the exact draft release' \
  'draft=true' \
  'prerelease=false' \
  'releases?per_page=100&page=1' \
  'response.headers.get("Link")' \
  'multiple releases claim the toolchain tag' \
  'easysplat-toolchain-release-owner:v1:' \
  'release.get("target_commitish") != commit' \
  'release.get("body") != owner' \
  'require_protected_source_refs()' \
  'protected main moved during toolchain publication' \
  'toolchain tag moved during publication' \
  'require_immutable_release_policy()' \
  'f"{api}/immutable-releases"' \
  'state == "starter"' \
  'state != "uploaded"' \
  'releases/assets/{asset['\''id'\'']}' \
  'toolchain draft contains a duplicate asset' \
  'toolchain-release-request.json' \
  'toolchain-authority-envelope.json' \
  'toolchain-authority-receipt.json' \
  'toolchain-benchmark-evidence.json' \
  'manual-publication-request.json' \
  '"resolved_tag_commit": resolved_tag_commit' \
  '"retention_days": 45' \
  'independent_human_exact_id_refetch' \
  'toolchain-manual-publication-${{ github.sha }}' \
  'Report the preserved owned draft' \
  'every remote asset ID, size, and SHA-256 digest' \
  'http.client.HTTPSConnection'; do
  grep -Fq -- "$contract" <<<"$stage_draft_block" \
    || fail "toolchain draft publication is missing: $contract"
done
[ "$(grep -Fc '          require_immutable_release_policy()' <<<"$stage_draft_block")" -eq 2 ] \
  || fail "toolchain publication must recheck immutable-release policy before and after mutation"
[ "$(grep -Fc '          resolved_tag_commit = require_protected_source_refs()' <<<"$stage_draft_block")" -eq 2 ] \
  || fail "toolchain publication must resolve protected source refs before mutation and before handoff"
grep -Fq '          retention-days: 45' "$TOOLCHAIN_PUBLISH" \
  || fail "verified toolchain publication must outlive the 30-day manual handoff"
if grep -Eq 'actions/checkout@|scripts/|swift[[:space:]]|notarize_artifact|finalize_signed_toolchain|read_bytes\(' <<<"$stage_draft_block"; then
  fail "toolchain publication must only stream the exact verified artifact closure"
fi
if grep -Eq 'contents: write|git tag|git push|gh release edit|prerelease=true' <<<"$stage_draft_block"; then
  fail "toolchain publication must stage, but never publish, the stable draft"
fi
if grep -Fq '/releases/tags/' <<<"$stage_draft_block"; then
  fail "toolchain publication must discover authenticated drafts through the paginated release listing"
fi

publisher_policy_token_count="$(grep -Fc 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' "$TOOLCHAIN_PUBLISH")"
[ "$publisher_policy_token_count" -eq 1 ] \
  || fail "toolchain publication policy token must appear only in metadata preflight"
publication_token_count="$(grep -Fc 'secrets.EASYSPLAT_TOOLCHAIN_PUBLICATION_TOKEN' "$TOOLCHAIN_PUBLISH")"
[ "$publication_token_count" -eq 1 ] \
  || fail "toolchain publication token must appear only in draft staging"
if grep -Eq 'TOOLCHAIN_PRIVATE_KEY|private[_-]key|sourceArtifacts|softprops/action-gh-release|contents: write|^[[:space:]]*(pull_request|pull_request_target):' "$TOOLCHAIN_PUBLISH"; then
  fail "toolchain publisher must not contain private authority keys, legacy sourceArtifacts, or GitHub-token write authority"
fi

require_job_count "$BENCHMARK_GATE" 9
require_line '^  workflow_dispatch:$' "$BENCHMARK_GATE"
for job in bind-toolchain prepare reference constrained eight-gb derive-reference derive-constrained derive-eight-gb aggregate; do
  require_line "^  $job:$" "$BENCHMARK_GATE"
done
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-reference, easysplat-ephemeral\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-constrained, easysplat-ephemeral\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: \[self-hosted, macOS, ARM64, easysplat-benchmark-8gb, easysplat-ephemeral\]$' "$BENCHMARK_GATE"
require_line '^    runs-on: macos-15$' "$BENCHMARK_GATE"
require_line '^    environment: benchmark-release$' "$BENCHMARK_GATE"
require_text 'scripts/benchmark/render-requirements.txt' "$BENCHMARK_GATE"
benchmark_bind_block="$(sed -n '/^  bind-toolchain:/,/^  prepare:/p' "$BENCHMARK_GATE")"
benchmark_prepare_block="$(sed -n '/^  prepare:/,/^  reference:/p' "$BENCHMARK_GATE")"
for contract in \
  'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' \
  'repos/$GITHUB_REPOSITORY/git/ref/tags/toolchain-v$VERSION' \
  'refs/tags/toolchain-v$VERSION' \
  'repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2Ftoolchain-v$VERSION' \
  'toolchain-benchmark-handoff-${{ github.run_id }}-${{ github.run_attempt }}' \
  '.github/workflows/sign-toolchain-authority.yml' \
  'authority-transport.json'; do
  grep -Fq -- "$contract" <<<"$benchmark_bind_block" \
    || fail "signed toolchain benchmark binding is missing: $contract"
done
if grep -Eq 'actions/checkout@|scripts/|swift[[:space:]]' <<<"$benchmark_bind_block"; then
  fail "signed toolchain benchmark binding must remain checkout-free"
fi
for contract in \
  'needs: bind-toolchain' \
  'artifact-ids: ${{ needs.bind-toolchain.outputs.artifact_id }}' \
  'scripts/release/toolchain_publication.py verify-authority' \
  'ManifestTool verify-release' \
  'full_toolchain_identity' \
  'signed-toolchain-root'; do
  grep -Fq -- "$contract" <<<"$benchmark_prepare_block" \
    || fail "benchmark prepare does not bind the final signed toolchain: $contract"
done
if grep -Eq 'secrets\.|github-token:|GH_TOKEN|GITHUB_TOKEN|EASYSPLAT_BENCHMARK_REFERENCE_TOOLCHAIN_ROOT' <<<"$benchmark_prepare_block"; then
  fail "benchmark prepare must verify the final signed closure without a token or alternate candidate toolchain"
fi
base_install_count="$(grep -Fc 'name: Install protected benchmark dependencies' "$BENCHMARK_GATE")"
[ "$base_install_count" -eq 8 ] \
  || fail "every benchmark job must install the base evidence dependencies"
render_install_count="$(grep -Fc 'name: Install protected render-scoring dependencies' "$BENCHMARK_GATE")"
[ "$render_install_count" -eq 1 ] \
  || fail "only no-secret reference derivation may install render scoring"
for required in \
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
for removed in \
  EASYSPLAT_BENCHMARK_REFERENCE_RUNNER \
  EASYSPLAT_BENCHMARK_CONSTRAINED_RUNNER \
  EASYSPLAT_BENCHMARK_8GB_RUNNER; do
  if grep -Fq "$removed" "$BENCHMARK_GATE"; then
    fail "measurement runner must be built from protected source: $removed"
  fi
done
if grep -Fq 'EASYSPLAT_BENCHMARK_RENDERING_DRIVER_SHA256' "$BENCHMARK_GATE"; then
  fail "the protected renderer identity must be derived from the exact source build"
fi
require_text '--product EasySplatBenchmarkDriver' "$BENCHMARK_GATE"
require_text 'renderer_closure.py build' "$BENCHMARK_GATE"
require_text '--product EasySplatMeasurementRunner' "$BENCHMARK_GATE"
require_text 'measurement_runner_closure.py build' "$BENCHMARK_GATE"
require_text 'measurement_runner_closure.py verify' "$BENCHMARK_GATE"
require_text 'easysplat-measurement-runner-${{ github.sha }}' "$BENCHMARK_GATE"
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
require_text 'verified-suite.json' "$BENCHMARK_GATE"
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
for lane_job in reference constrained eight-gb; do
  lane_block="$(sed -n "/^  $lane_job:/,/^  [A-Za-z0-9_-]*:/p" "$BENCHMARK_GATE")"
  if grep -Eq 'secrets\.|github-token:|GH_TOKEN|GITHUB_TOKEN' <<<"$lane_block"; then
    fail "$lane_job must not expose a GitHub token to self-hosted repository code"
  fi
done
benchmark_policy_token_count="$(grep -Fc 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' "$BENCHMARK_GATE")"
[ "$benchmark_policy_token_count" -eq 1 ] \
  || fail "benchmark policy token must appear only in checkout-free toolchain binding"
if grep -Eq '^[[:space:]]*(pull_request|pull_request_target):' "$BENCHMARK_GATE"; then
  fail "release benchmark must never run pull-request code"
fi

for workflow in "$TOOLCHAIN_GATE" "$TOOLCHAIN_PUBLISH" "$BENCHMARK_GATE"; do
  if grep -Fq -- '--jq .object.sha' "$workflow"; then
    fail "toolchain release workflows must compare the peeled tag commit, not a raw tag object"
  fi
done

for untrusted in "$TESTS" "$SECURITY" "$CODEQL"; do
  if grep -Fq '${{ secrets.' "$untrusted"; then
    fail "${untrusted#"$ROOT/"} exposes a secret to untrusted code"
  fi
done

echo "workflow contracts passed"
